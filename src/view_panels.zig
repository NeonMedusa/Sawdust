//! 左右列表面板（操作历史 / 样式）+ 状态栏。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const model = @import("model.zig");
const util = @import("view_util.zig");

pub fn drawHistory(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    ui.panelTitled(x, y, w, h, "操作历史");

    const item_h: i32 = @as(i32, @intFromFloat(ui.font.lineHeight())) + 8;
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;
    const n: usize = app.history.items.len;

    // 裁剪（列表滚动时不画出边界）
    {
        const saved_clip = ui.renderer.pushClip(x + 1, list_y, w - 2, list_h);
        defer ui.renderer.popClip(saved_clip);

        var i: usize = 0;
        var iy = list_y - app.panels.history_scroll;
        while (i < n) : (i += 1) {
            if (iy + item_h > list_y and iy < list_y + list_h) {
                const is_current = i == app.history_current;
                const is_saved = i == app.history_saved_index;
                // 条目文本：`<序号>. <操作名>`（保存点加 `*` 前缀；当前条目高亮）
                var buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s}{d}. {s}", .{
                    if (is_saved) "*" else "",
                    i + 1,
                    app.history.items[i].label,
                }) catch app.history.items[i].label;
                if (ui.listItem(1000 + i, label, x + 1, iy, w - 2, item_h, is_current, i % 2 == 1, null)) {
                    // 点击条目 = 跳转到该状态（等价于连续撤销/重做）
                    if (app.jumpHistory(i)) {
                        app.setToastWith("历史：{s}", .{app.historyLabel()});
                    }
                }
            }
            iy += item_h;
            if (iy > list_y + list_h) break;
        }

        // 滚动（滚轮）
        const content_h: i32 = @intCast(n * @as(usize, @intCast(item_h)));
        if (ui.hitRect(x, list_y, w, list_h)) {
            app.panels.history_scroll = std.math.clamp(app.panels.history_scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
        }
        ui.drawScrollbar(x + w - 6, list_y, 5, list_h, app.panels.history_scroll, content_h, list_h);
    }

    // 自动跟随：**当前条目变化时**滚到它（新操作/撤销后立即可见）。
    // 注：不能每帧跟随——否则用户手动滚动查看时会被强制拉回。
    if (n > 0 and app.history_current != app.panels.history_follow) {
        app.panels.history_follow = app.history_current;
        const cur_y: i32 = @as(i32, @intCast(app.history_current)) * item_h;
        if (cur_y < app.panels.history_scroll) {
            app.panels.history_scroll = cur_y;
        } else if (cur_y + item_h > app.panels.history_scroll + list_h) {
            app.panels.history_scroll = cur_y + item_h - list_h;
        }
    }
}

pub fn drawPatterns(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    ui.panelTitled(x, y, w, h, "样式 (Patterns)");

    const item_h: i32 = @as(i32, @intFromFloat(ui.font.lineHeight())) + 10;
    const list_y = y + util.title_h;
    // 列表下方预留“添加样式”按钮行
    const add_row_h: i32 = item_h + 4;
    const list_h = h - util.title_h - add_row_h;
    const pat_count: usize = app.pattern_items.items.len;

    // 列表 + 滚动条：**作用域块内** pushClip/popClip——
    // defer 是函数级作用域，若挂到函数末尾会把“添加样式”按钮也裁掉（实测 bug：按钮不可见，
    // 且命中判定不受裁剪影响 → 隐形可点）。参照 view_rack.zig 的写法。
    {
        const saved_clip = ui.renderer.pushClip(x + 1, list_y, w - 2, list_h);
        defer ui.renderer.popClip(saved_clip);

        var i: usize = 0;
        var iy = list_y - app.panels.pattern_scroll;
        while (i < pat_count) : (i += 1) {
            if (iy + item_h > list_y and iy < list_y + list_h) {
                const selected = app.sel.pattern == @as(i32, @intCast(i));
                if (ui.listItem(2000 + i, app.pattern_items.items[i], x + 1, iy, w - 2, item_h, selected, i % 2 == 1, null)) {
                    app.sel.pattern = @intCast(i);
                    // 钢琴卷帘开着时，点击样式 = 切换编辑对象（与“点片段→选样式”闭环）
                    if (app.piano.pattern != null) app.piano.pattern = @intCast(i);
                }
                // 双击样式 → 打开钢琴卷帘
                if (ui.mouse_double and ui.hitRect(x + 1, iy, w - 2, item_h)) {
                    app.sel.pattern = @intCast(i);
                    app.openPiano(@intCast(i));
                }
            }
            iy += item_h;
            if (iy > list_y + list_h) break;
        }

        const content_h: i32 = @intCast(pat_count * @as(usize, @intCast(item_h)));
        if (ui.hitRect(x, list_y, w, list_h)) {
            app.panels.pattern_scroll = std.math.clamp(app.panels.pattern_scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
        }
        ui.drawScrollbar(x + w - 6, list_y, 5, list_h, app.panels.pattern_scroll, content_h, list_h);
    }

    // 底部：“＋ 添加样式”按钮（列表满时显示提示文本）
    const btn_y = y + h - add_row_h + 2;
    const btn_w = w - 10;
    if (pat_count < model.max_patterns) {
        if (ui.button(2100, "＋ 添加样式", x + 5, btn_y, btn_w, item_h)) {
            const ni = app.addPattern();
            if (ni >= 0) {
                app.sel.pattern = ni;
                if (app.piano.pattern != null) app.piano.pattern = ni;
                app.commitHistory("添加样式"); // 原子操作：立即提交
            }
        }
    } else {
        ui.label("样式已达上限", x + 8, btn_y + 4, ui.theme.text_dim);
    }
}

pub fn drawStatusBar(ui: *Ui, app: *App, w: i32, h: i32) void {
    const y = h - util.status_h;
    ui.renderer.fillRect(0, y, w, util.status_h, ui.theme.toolbar);
    ui.renderer.hline(0, y, w, ui.theme.panel_border);

    var buf: [128]u8 = undefined;
    const left = std.fmt.bufPrint(&buf, "{s} · 样式 {d} · 轨道 {d} · {s}", .{
        if (app.sel.song_mode) "SONG" else "PAT",
        app.sel.pattern + 1,
        app.sel.track + 1,
        if (app.playing) "播放中" else "已停止",
    }) catch "";
    ui.label(left, 8, y + 4, ui.theme.text_dim);

    // 保存/加载提示优先；无提示时显示操作说明
    if (app.toast) |t| {
        ui.label(t, w - 620, y + 4, ui.theme.accent);
    } else if (app.piano.pattern != null) {
        ui.label("左键放置/拖动 · Ctrl+拖 框选 · Del 删除 · Ctrl+A 全选 · Ctrl+B 克隆 · Ctrl+C/V · Ctrl+Z 撤销", w - 620, y + 4, ui.theme.text_dim);
    } else {
        ui.label("左键放置/拖动 · Ctrl+拖 框选 · Del 删除 · Ctrl+A 全选 · Ctrl+B 克隆 · Ctrl+C/V · Ctrl+Z 撤销", w - 620, y + 4, ui.theme.text_dim);
    }
}
