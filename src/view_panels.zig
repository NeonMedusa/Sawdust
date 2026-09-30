//! 左右列表面板（操作历史 / 样式）+ 状态栏。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const util = @import("view_util.zig");

pub fn drawHistory(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    ui.panelTitled(x, y, w, h, "操作历史");

    const item_h: i32 = @as(i32, @intFromFloat(ui.font.lineHeight())) + 8;
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;

    // 裁剪（列表滚动时不画出边界）
    const saved_clip = ui.renderer.pushClip(x + 1, list_y, w - 2, list_h);
    defer ui.renderer.popClip(saved_clip);

    var i: usize = 0;
    var iy = list_y - app.panels.history_scroll;
    while (i < app.history_items.len) : (i += 1) {
        if (iy + item_h > list_y and iy < list_y + list_h) {
            _ = ui.listItem(1000 + i, app.history_items[i], x + 1, iy, w - 2, item_h, false, i % 2 == 1, null);
        }
        iy += item_h;
        if (iy > list_y + list_h) break;
    }

    // 滚动
    const content_h: i32 = @intCast(app.history_items.len * @as(usize, @intCast(item_h)));
    if (ui.hitRect(x, list_y, w, list_h)) {
        app.panels.history_scroll = std.math.clamp(app.panels.history_scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
    }
    ui.drawScrollbar(x + w - 6, list_y, 5, list_h, app.panels.history_scroll, content_h, list_h);
}

pub fn drawPatterns(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    ui.panelTitled(x, y, w, h, "样式 (Patterns)");

    const item_h: i32 = @as(i32, @intFromFloat(ui.font.lineHeight())) + 10;
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;

    // 裁剪（列表滚动时不画出边界）
    const saved_clip = ui.renderer.pushClip(x + 1, list_y, w - 2, list_h);
    defer ui.renderer.popClip(saved_clip);

    var i: usize = 0;
    var iy = list_y - app.panels.pattern_scroll;
    while (i < app.pattern_items.len) : (i += 1) {
        if (iy + item_h > list_y and iy < list_y + list_h) {
            const selected = app.sel.pattern == @as(i32, @intCast(i));
            if (ui.listItem(2000 + i, app.pattern_items[i], x + 1, iy, w - 2, item_h, selected, i % 2 == 1, null)) {
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

    const content_h: i32 = @intCast(app.pattern_items.len * @as(usize, @intCast(item_h)));
    if (ui.hitRect(x, list_y, w, list_h)) {
        app.panels.pattern_scroll = std.math.clamp(app.panels.pattern_scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
    }
    ui.drawScrollbar(x + w - 6, list_y, 5, list_h, app.panels.pattern_scroll, content_h, list_h);
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

    if (app.piano.pattern != null) {
        ui.label("左键放置/拖动音符 · 边缘拉伸 · 右键擦除 · Ctrl+滚轮 横向缩放", w - 620, y + 4, ui.theme.text_dim);
    } else {
        ui.label("点击放置/拖动片段 · 边缘拉伸 · 右键擦除 · 双击进入钢琴卷帘 · Ctrl+滚轮 横向缩放", w - 620, y + 4, ui.theme.text_dim);
    }
}
