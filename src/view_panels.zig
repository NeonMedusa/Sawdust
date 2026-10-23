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
                if (ui.listItem(1000 + i, label, x + 1, iy, w - 2, item_h, is_current, i % 2 == 1, null, null)) {
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
    // 页签直接占满标题行（用户拍板：去掉“样式 (Patterns)”文字，音符|音频一左一右各半）
    ui.panelTitled(x, y, w, h, "");
    {
        const tab_h = util.title_h - 2;
        const tw = @divTrunc(w - 4, 2);
        if (ui.listItem(3100, "音符", x + 2, y + 1, tw, tab_h, !app.panels.patterns_tab_audio, false, null, null)) app.panels.patterns_tab_audio = false;
        if (ui.listItem(3101, "音频", x + 2 + tw, y + 1, w - 4 - tw, tab_h, app.panels.patterns_tab_audio, false, null, null)) {
            app.panels.patterns_tab_audio = true;
            // 首次切到音频页且没有任何选中 → 自动选第一个（否则“放置”无目标）
            if (app.audio_style_sel < 0 and app.audio_styles.items.len > 0) app.audio_style_sel = 0;
        }
    }
    const audio_tab = app.panels.patterns_tab_audio;

    const item_h: i32 = @as(i32, @intFromFloat(ui.font.lineHeight())) + 10;
    const list_y = y + util.title_h;
    // 底部“＋ 添加样式”按钮行（下/左/右贴边；高度 = 一行）——**仅音符页**
    const add_row_h: i32 = if (audio_tab) 0 else item_h;
    const list_h = h - util.title_h - add_row_h;
    const add_btn_y = y + h - 1 - item_h;
    const pat_count: usize = app.pattern_items.items.len;
    const n_items: usize = if (audio_tab) app.audio_styles.items.len else pat_count;
    const scroll: *i32 = if (audio_tab) &app.panels.audio_scroll else &app.panels.pattern_scroll;

    // 列表 + 滚动条：**作用域块内** pushClip/popClip——
    // defer 是函数级作用域，若挂到函数末尾会把“添加样式”按钮也裁掉（实测 bug：按钮不可见，
    // 且命中判定不受裁剪影响 → 隐形可点）。参照 view_rack.zig 的写法。
    {
        const saved_clip = ui.renderer.pushClip(x + 1, list_y, w - 2, list_h);
        defer ui.renderer.popClip(saved_clip);

        // 底部“＋ 添加样式”按钮行会压住列表底部半截行的**不可见部分**；而命中判定不看
        // 裁剪 → 点“＋”会同时命中那半截行（穿透：点添加却选中了被压住的样式，实测）。
        // 鼠标在按钮行内时，列表行的动作一律不响应（listItem 照画）。
        // 音频页没有添加行 → in_add_row 恒 false（否则列表底部被误封）
        const in_add_row = !audio_tab and util.inRect(ui.mouse_x, ui.mouse_y, x + 1, add_btn_y, w - 2, item_h);

        var i: usize = 0;
        var iy = list_y - scroll.*;
        while (i < n_items) : (i += 1) {
            if (iy + item_h > list_y and iy < list_y + list_h) {
                if (audio_tab) {
                    // 音频样式行（只读展示——推子/波形走采样器窗口）——与音符样式行**同一 listItem 观感**
                    // （不加符号前缀：字体里没有，会渲染成空心方块）
                    const ast = app.audio_styles.items[i];
                    const asel = app.audio_style_sel == @as(i32, @intCast(i));
                    var ab: [128]u8 = undefined;
                    const txt = std.fmt.bufPrint(&ab, "{s}", .{ast.name}) catch ast.name;
                    {
                        const prev_my = ui.mouse_y;
                        if (in_add_row) ui.mouse_y = -100000;
                        defer ui.mouse_y = prev_my;
                        if (ui.listItem(3000 + i, txt, x + 1, iy, w - 2, item_h, asel, false, null, null) and !in_add_row) {
                            app.audio_style_sel = @intCast(i); // 单击选中待放置
                        }
                        if (util.hitUI(ui, x + 1, iy, w - 2, item_h) and ui.mouse_double and !in_add_row) app.openWaveForStyle(i);
                        // 右键 → 重命名/删除菜单（与音符样式同款）
                        if (util.hitUI(ui, x + 1, iy, w - 2, item_h) and ui.mouse_right_pressed and !in_add_row) {
                            app.panels.ctx_audio_style = i;
                            app.panels.ctx_aud_x = ui.mouse_x;
                            app.panels.ctx_aud_y = ui.mouse_y;
                        }
                    }
                    iy += item_h;
                    continue;
                }
                // 音符样式行：选中高亮只看 `sel.pattern`（与音频样式互不干扰）
                // 底栏按钮盖住的半截行：hover/点击一起抑制——`listItem` 的高亮
                // 来自它自己的命中判定（不看渲染裁剪），只挡动作会“hover 穿透”（实测）；
                // 临时把鼠标 y 挪出屏内最省事。
                const selected = app.sel.pattern == @as(i32, @intCast(i));
                {
                    const prev_my = ui.mouse_y;
                    if (in_add_row) ui.mouse_y = -100000;
                    defer ui.mouse_y = prev_my;
                    if (ui.listItem(2000 + i, app.pattern_items.items[i], x + 1, iy, w - 2, item_h, selected, i % 2 == 1, null, null) and !in_add_row) {
                        app.sel.pattern = @intCast(i);
                        // 钢琴卷帘开着时，点击样式 = 切换编辑对象（与“点片段→选样式”闭环）
                        // 换样式 = 规则 2 v2：锚 = 离游标最近（窗随游标）；点同一样式不动锚
                        if (app.piano.pattern) |pp| {
                            const pi: i32 = @intCast(i);
                            if (pp != pi) {
                                app.piano.pattern = pi;
                                app.piano.origin = app.nearestAnchorForPattern(pi);
                            }
                        }
                    }
                }
                // 双击样式 → 打开钢琴卷帘（按钮行内不响应）
                if (!in_add_row and ui.mouse_double and ui.hitRect(x + 1, iy, w - 2, item_h)) {
                    app.sel.pattern = @intCast(i);
                    // 锚：换样式 → 离游标最近；同一样式 → 保留（openPiano 内部）
                    app.openPiano(@intCast(i));
                }
                // 右键样式 → 重命名/删除菜单（位置快照；与机架右键同一模式）
                if (!in_add_row and ui.mouse_right_pressed and ui.hitRect(x + 1, iy, w - 2, item_h)) {
                    app.panels.ctx_pattern = i;
                    app.panels.ctx_pat_x = ui.mouse_x;
                    app.panels.ctx_pat_y = ui.mouse_y;
                }
            }
            iy += item_h;
            if (iy > list_y + list_h) break;
        }

        const content_h: i32 = @intCast(n_items * @as(usize, @intCast(item_h)));
        if (ui.hitRect(x, list_y, w, list_h)) {
            scroll.* = std.math.clamp(scroll.* - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
        }
        ui.drawScrollbar(x + w - 6, list_y, 5, list_h, scroll.*, content_h, list_h);
    }

    // 底部：“＋ 添加样式”按钮（仅音符页；下/左/右贴边；列表满时显示提示文本）
    if (audio_tab) {
        // 音频页没有添加行：底部给拖入提示（用户拍板）
        ui.label("将音频文件拖放到此", x + 8, add_btn_y + 4, ui.theme.text_dim);
    } else if (pat_count < model.max_patterns) {
        if (ui.button(2100, "＋ 添加样式", x + 1, add_btn_y, w - 2, item_h)) {
            const ni = app.addPattern();
            if (ni >= 0) {
                app.sel.pattern = ni;
                if (app.piano.pattern != null) app.piano.pattern = ni;
                app.commitHistory("添加样式"); // 原子操作：立即提交
            }
        }
    } else {
        ui.label("样式已达上限", x + 8, add_btn_y + 4, ui.theme.text_dim);
    }
}

pub fn drawStatusBar(ui: *Ui, app: *App, w: i32, h: i32) void {
    const y = h - util.status_h;
    ui.renderer.fillRect(0, y, w, util.status_h, ui.theme.toolbar);
    ui.renderer.hline(0, y, w, ui.theme.panel_border);

    var buf: [160]u8 = undefined;
    const db: f32 = if (app.out_peak > 0.000001) 20.0 * std.math.log10(app.out_peak) else -60.0;
    const left = std.fmt.bufPrint(&buf, "{s} · 样式 {d} · 轨道 {d} · {s} · 峰 {d:.1} dB", .{
        if (app.sel.song_mode) "SONG" else "PAT",
        app.sel.pattern + 1,
        app.sel.track + 1,
        if (app.playing) "播放中" else "已停止",
        db,
    }) catch "";
    ui.label(left, 8, y + 4, if (app.out_over_hold > 0) ui.theme.danger else ui.theme.text_dim);
    if (app.toast) |t| {
        ui.label(t, w - 620, y + 4, ui.theme.accent);
    } else if (app.piano.pattern != null) {
        ui.label("左键放置/拖动 · Ctrl+拖 框选 · Del 删除 · Ctrl+A 全选 · Ctrl+B 克隆 · Ctrl+C/V · Ctrl+Z 撤销", w - 620, y + 4, ui.theme.text_dim);
    } else {
        ui.label("左键放置/拖动 · Ctrl+拖 框选 · Del 删除 · Ctrl+A 全选 · Ctrl+B 克隆 · Ctrl+C/V · Ctrl+Z 撤销", w - 620, y + 4, ui.theme.text_dim);
    }
}

/// 样式右键菜单（重命名/删除）。
///
/// 在**所有浮动窗口之后**绘制（main 末尾、与文件菜单同一位置约定——
/// 否则会被浮动窗口盖住）；`App.menuIsOpen()` 已计入 `panels.ctx_pattern`
/// → 展开时有全屏模态层屏蔽下层交互。
/// 音频样式右键菜单（重命名/删除）。与 `drawPatternCtxMenu` 同一绘制/命中约定：
/// 在**所有浮动窗口之后**绘制（main 末尾）。
pub fn drawAudioStyleCtxMenu(ui: *Ui, app: *App) void {
    const idx = app.panels.ctx_audio_style orelse return;
    if (idx >= app.audio_styles.items.len) {
        app.panels.ctx_audio_style = null; // 目标已不存在（撤销/删除）→ 关闭
        return;
    }
    const items = [_][]const u8{ "重命名", "删除样式" };
    const menu_w: i32 = 130;
    const menu_h: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const mx = app.panels.ctx_aud_x;
    const my = app.panels.ctx_aud_y;
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h); // 遮挡插件子窗口

    var clicked: ?usize = null;
    var inside = false;
    for (items, 0..) |item, ii| {
        const iy = my + 2 + @as(i32, @intCast(ii)) * util.menu_item_h;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (hovered) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, ui.theme.text);
        if (hovered and ui.mouse_pressed) clicked = ii;
    }
    if (clicked) |ci| {
        switch (ci) {
            0 => {
                app.beginRenameAudioStyle(idx, mx + 6, my + 4); // 复用文本输入基建（中文 IME）
                app.panels.ctx_audio_style = null;
            },
            1 => {
                if (app.removeAudioStyle(idx)) |dropped| {
                    if (dropped > 0) {
                        app.setToastWith("已删除音频样式（连带 {d} 个片段）", .{dropped});
                    } else {
                        app.setToast("已删除音频样式");
                    }
                    app.commitHistory("删除音频样式");
                }
                app.panels.ctx_audio_style = null;
            },
            else => {},
        }
        return;
    }
    // 点菜单外 → 关闭（与其它右键菜单一致）
    if (ui.mouse_pressed and !inside and !util.inRect(ui.mouse_x, ui.mouse_y, mx, my, menu_w, menu_h)) {
        app.panels.ctx_audio_style = null;
    }
}
pub fn drawPatternCtxMenu(ui: *Ui, app: *App) void {
    const idx = app.panels.ctx_pattern orelse return;
    if (idx >= app.pattern_items.items.len) {
        app.panels.ctx_pattern = null; // 目标已不存在（撤销/删除）→ 关闭
        return;
    }
    const items = [_][]const u8{ "重命名", "删除样式" };
    const menu_w: i32 = 130;
    const menu_h: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const mx = app.panels.ctx_pat_x;
    const my = app.panels.ctx_pat_y;
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h); // 遮挡插件子窗口

    var clicked: ?usize = null;
    var inside = false;
    for (items, 0..) |item, ii| {
        const iy = my + 2 + @as(i32, @intCast(ii)) * util.menu_item_h;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (hovered) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, ui.theme.text);
        if (hovered and ui.mouse_pressed) clicked = ii;
    }
    if (clicked) |ci| {
        switch (ci) {
            0 => {
                // 重命名：输入框弹在菜单位置（复用文本输入基建——支持中文 IME）
                app.beginRenamePattern(idx, mx + 6, my + 4);
                app.panels.ctx_pattern = null;
            },
            1 => {
                if (app.pattern_items.items.len <= 1) {
                    app.setToast("至少保留一个样式");
                } else if (app.patternUsage(idx).notes == 0 and app.patternUsage(idx).clips == 0) {
                    // 空样式：直接删
                    if (app.removePattern(idx)) app.commitHistory("删除样式");
                } else {
                    // 非空：弹确认框（删除 + 撤销兜底）
                    app.modal = .pattern_delete;
                    app.struct_del_req = .{ .pattern = idx };
                }
                app.panels.ctx_pattern = null;
            },
            else => {},
        }
    } else if (ui.mouse_pressed and !inside) {
        app.panels.ctx_pattern = null;
    }
}
