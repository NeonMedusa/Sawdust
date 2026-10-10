//! 通道机架浮动窗口：乐器行（静音/旋钮/混音/名称/minimap）+ 添加按钮 + 下拉菜单。
//!
//! 输入分层：本窗口的命中检测全部用 `util.inRect`（直接坐标，不受 input_blocked 影响）
//! 或 `util.hitUI`（尊重 input_blocked，供非菜单控件用）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const model = @import("model.zig");
const util = @import("view_util.zig");

/// 通道机架（浮动窗口）：乐器行 + 添加按钮；可拖动标题、右下角缩放、关闭。
/// `menu_was_open`：帧首是否有任何下拉菜单展开（本帧窗口控件应全部让位，
/// 防止“关闭菜单的点击”穿透到窗口控件上）。
/// 输入屏蔽由层系统负责（`ui.beginLayer`）——本函数不再手写 input_blocked。
/// 返回 true = 鼠标被窗口消费（屏蔽底层控件交互）。
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32, menu_was_open: bool) bool {
    if (!app.rack.open) return false;
    const rk = &app.rack;
    // 约束在屏幕内
    rk.w = std.math.clamp(rk.w, util.rack_min_w, @max(util.rack_min_w, w - 20));
    rk.h = std.math.clamp(rk.h, util.rack_min_h, @max(util.rack_min_h, h - 20));
    rk.x = std.math.clamp(rk.x, 0, @max(0, w - rk.w));
    rk.y = std.math.clamp(rk.y, 0, @max(0, h - rk.h));

    const x = rk.x;
    const y = rk.y;
    const ww = rk.w;
    const hh = rk.h;
    const title_y = y;
    const body_y = y + util.rack_title_h;
    const body_h = hh - util.rack_title_h;
    const add_btn_h = util.rack_add_h;
    const list_y = body_y + 1;
    const list_h = @max(0, body_h - add_btn_h - 2);

    // 菜单模态：任何下拉菜单展开（或帧首展开）时，窗口自身的非菜单控件全部让位
    // （否则菜单项点击会穿透到下面的行/按钮）。
    // 注意：**不覆盖**“被上层窗口屏蔽”的状态（那是 beginLayer 算的；
    // 上面用 or 合幷而不直接赋值）。
    const menu_modal = menu_was_open or app.rack.menu_open or app.rack.ctx_instrument != null;
    if (menu_modal) ui.input_blocked = true;

    // 窗口阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    // 亮蓝描边（与合成器/调音台/效果器面板一致）
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, title_y + 1, ww - 2, util.rack_title_h - 1, ui.theme.toolbar);
    ui.label("乐器（通道机架）", x + 8, title_y + 4, ui.theme.text);
    // 关闭按钮（右上角 ×）
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, title_y + 2, 20, util.rack_title_h - 4);
    ui.renderer.fillRect(close_x, title_y + 2, 20, util.rack_title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, title_y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        rk.open = false;
        app.rack.menu_open = false;
        app.rack.ctx_instrument = null;
        return true;
    }

    // 点窗口内任意处 → 置顶（“点谁谁在上”；在层系统判定前提升，本帧即生效）
    if (rk.open and util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&rk.z);
    }

    // 标题拖动
    const title_hovered = util.hitUI(ui, x, title_y, ww - 24, util.rack_title_h);
    if (title_hovered and ui.mouse_pressed) {
        ui.active_id = 3000;
        rk.grab_dx = ui.mouse_x - x;
        rk.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 3000) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            rk.x = ui.mouse_x - rk.grab_dx;
            rk.y = ui.mouse_y - rk.grab_dy;
        }
    }

    // 右下角缩放柄（三角形区）
    const grip = 14;
    const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
    if (grip_hovered) ui.cursor = .resize_h;
    if (grip_hovered and ui.mouse_pressed) {
        ui.active_id = 3001;
        rk.resize_w0 = ww;
        rk.resize_h0 = hh;
        rk.resize_mx = ui.mouse_x;
        rk.resize_my = ui.mouse_y;
    }
    if (ui.active_id == 3001) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            rk.w = rk.resize_w0 + (ui.mouse_x - rk.resize_mx);
            rk.h = rk.resize_h0 + (ui.mouse_y - rk.resize_my);
        }
    }
    ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);
    ui.renderer.line(x + ww - 6, y + hh - 2, x + ww - 2, y + hh - 6, ui.theme.panel_border);

    // ── 乐器行（可滚动）──
    const content_h: i32 = @intCast(app.instruments.items.len * @as(usize, @intCast(util.rack_row_h)));
    const max_scroll = @max(0, content_h - list_h);
    if (util.hitUI(ui, x + 1, list_y, ww - 2, list_h)) {
        rk.scroll = std.math.clamp(rk.scroll - ui.wheel * 24, 0, max_scroll);
    }
    rk.scroll = std.math.clamp(rk.scroll, 0, max_scroll);

    {
        const saved = ui.renderer.pushClip(x + 1, list_y, ww - 2, list_h);
        defer ui.renderer.popClip(saved);
        var i: usize = 0;
        var ry = list_y - rk.scroll;
        while (i < app.instruments.items.len) : (i += 1) {
            if (ry + util.rack_row_h > list_y and ry < list_y + list_h) {
                drawRow(ui, app, i, x + 1, ry, ww - 2, list_y, list_y + list_h);
            }
            ry += util.rack_row_h;
        }
    }

    // 帧首：清“刚打开”标记（共享下拉控件；必须逐帧做）
    util.menuFrameBegin(&app.rack.menu_just_opened);

    // ── 添加按钮（共享下拉控件：按钮 + 菜单）──
    // 左右各留 5px 边距（原 1px）
    const add_pad: i32 = 5;
    const add_x = x + add_pad;
    const add_y = y + hh - add_btn_h - add_pad;
    const add_w = ww - add_pad * 2;
    util.menuButton(ui, "+ 添加乐器", add_x, add_y, add_w, add_btn_h, &app.rack.menu_open, &app.rack.menu_just_opened);

    // 下拉菜单（插件列表；菜单层：展开时取消屏蔽——菜单项用直接坐标命中）
    if (app.rack.menu_open) {
        ui.input_blocked = false;
        const menu_items = [_][]const u8{ "减法合成器 (Subtractive)", "采样器 (Sampler)", "FM 合成器" };
        const ok = [_]bool{ true, false, false };
        if (util.menuPanel(ui, &app.rack.menu_x, &app.rack.menu_y, &app.rack.menu_open, app.rack.menu_just_opened, .{ .button = .{ .x = add_x + 8, .y = add_y, .w = add_w, .h = add_btn_h } }, .{ .x = x, .y = y, .w = ww, .h = hh }, &menu_items, 240, &ok)) |mi| {
            if (mi == 0) {
                _ = app.addInstrument("减法合成器");
                app.commitHistory("添加乐器"); // 原子操作：立即提交
            }
        }
    }

    // 右键菜单（重命名 / 删除乐器）——同理：仅在展开时取消屏蔽
    if (app.rack.ctx_instrument != null) ui.input_blocked = false;
    if (app.rack.ctx_instrument) |ci| {
        if (ci < app.instruments.items.len) {
            const items = [_][]const u8{ "重命名", "删除乐器" };
            const mw: i32 = 140;
            const mh: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
            const mx = app.rack.ctx_x; // 固定位置（打开时记录，不跟鼠标跑）
            const my = app.rack.ctx_y;
            ui.renderer.fillRect(mx, my, mw, mh, ui.theme.panel);
            ui.renderer.strokeRect(mx, my, mw, mh, ui.theme.accent);
            var clicked: ?usize = null;
            var inside = false;
            for (items, 0..) |item, i| {
                const iy = my + 2 + @as(i32, @intCast(i)) * util.menu_item_h;
                const ih = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, mw - 2, util.menu_item_h);
                if (ih) {
                    inside = true;
                    ui.renderer.fillRect(mx + 1, iy, mw - 2, util.menu_item_h, ui.theme.item_hover);
                }
                ui.label(item, mx + 8, iy + 2, ui.theme.text);
                if (ih and ui.mouse_pressed) clicked = i;
            }
            if (clicked) |ic| {
                switch (ic) {
                    0 => {
                        // 重命名：输入框弹在乐器名位置（行内就地）
                        app.beginRenameInstrument(ci, mx + 4, my + 4);
                    },
                    1 => {
                        app.removeInstrument(ci);
                        app.commitHistory("删除乐器"); // 原子操作：立即提交
                    },
                    else => {},
                }
                app.rack.ctx_instrument = null;
            } else if (ui.mouse_pressed and !inside) {
                app.rack.ctx_instrument = null;
            }
        } else {
            app.rack.ctx_instrument = null;
        }
    }

    // 鼠标在窗口内：屏蔽底层控件
    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}

/// 通道机架的一行乐器：静音 / 声像旋钮 / 音量旋钮 / 混音通道 / 名称 / 音符 minimap
/// `clip_top`/`clip_bot`：列表可视区（行可能部分滚出，可视区外的部分不应响应点击——
/// 否则会与标题栏拖动/添加按钮重叠）
fn drawRow(ui: *Ui, app: *App, idx: usize, x: i32, y: i32, w: i32, clip_top: i32, clip_bot: i32) void {
    // 鼠标不在列表可视区（含纵向）：屏蔽本行所有交互（绘制照常）
    const prev_blocked = ui.input_blocked;
    if (!(ui.mouse_y >= clip_top and ui.mouse_y < clip_bot)) ui.input_blocked = true;
    defer ui.input_blocked = prev_blocked;

    const inst = &app.instruments.items[idx];
    const selected = app.sel.instrument == @as(i32, @intCast(idx));
    const bg = if (selected) ui.theme.item_selected else if (idx % 2 == 1) ui.theme.item_alt else ui.theme.panel;
    ui.renderer.fillRect(x, y, w, util.rack_row_h, bg);
    ui.renderer.hline(x, y + util.rack_row_h - 1, w, ui.theme.panel_border);

    // **整行命中兜底**：点行内任何位置（含控件间的缝隙）→ 选中该乐器。
    // 视觉上行是满的，但各控件的命中区之间有空隙（“看起来无缝、点上去有缝”）。
    // 放在控件之前：控件自己也会处理点击（不冲突——两边都只是“选中”而已）。
    if (util.hitUI(ui, x, y, w, util.rack_row_h) and ui.mouse_pressed) {
        app.setInstrument(@intCast(idx));
    }

    var cx = x + 6;
    const cy = y + @divTrunc(util.rack_row_h - util.rack_mute_w, 2);

    // 静音开关
    const mute_hovered = util.hitUI(ui, cx, cy, util.rack_mute_w, util.rack_mute_w);
    ui.renderer.fillRect(cx, cy, util.rack_mute_w, util.rack_mute_w, if (inst.muted) ui.theme.mute_on else ui.theme.slider_track);
    ui.renderer.strokeRect(cx, cy, util.rack_mute_w, util.rack_mute_w, ui.theme.panel_border);
    if (mute_hovered and ui.mouse_pressed) {
        inst.muted = !inst.muted;
        app.commitHistory("切换静音"); // 开关：原子提交
    }
    cx += util.rack_mute_w + 8;

    // 声像旋钮 / 音量旋钮（拖动中 coalesce，松手时提交）
    const ky = y + @divTrunc(util.rack_row_h - util.rack_knob_size, 2);
    if (ui.knob(4000 + @as(u64, idx) * 2, &inst.pan, cx, ky, util.rack_knob_size)) app.history_pending = "调整声像";
    cx += util.rack_knob_size + 6;
    if (ui.knob(4000 + @as(u64, idx) * 2 + 1, &inst.volume, cx, ky, util.rack_knob_size)) app.history_pending = "调整乐器音量";
    cx += util.rack_knob_size + 10;

    // 混音通道（**推子式**：上下拖动改路由通道 0..n-1；点击不拖动 = 平推）
    // 上界 = **实际通道数 - 1**（不再固定 8——否则通道只有 0..3 时能拖到 4，实测 bug）
    {
        const mix_x = cx;
        const mix_y = y + 4;
        const mix_h = util.rack_row_h - 8;
        const hovered = util.hitUI(ui, mix_x, mix_y, util.rack_mix_w, mix_h);
        const active = ui.active_id == 4100 + @as(u64, idx);
        ui.renderer.fillRect(mix_x, mix_y, util.rack_mix_w, mix_h, if (active) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(mix_x, mix_y, util.rack_mix_w, mix_h, ui.theme.panel_border);
        // 通道号（**0 起**，与调音台标尺/默认通道名同一编号；0 = 主通道）
        var buf: [8]u8 = undefined;
        const mix_t = std.fmt.bufPrint(&buf, "{d}", .{inst.mixer}) catch "";
        const tw: i32 = @intFromFloat(ui.font.measure(mix_t));
        ui.label(mix_t, mix_x + @divTrunc(util.rack_mix_w - tw, 2), mix_y + @divTrunc(mix_h - 10, 2), ui.theme.text);
        // 推子交互：按下 → 捕获；上下拖动 = 通道增减（**上拖增大、下拖减小**）
        if (hovered and ui.mouse_pressed) {
            ui.active_id = 4100 + @as(u64, idx);
            ui.mouse_capture = true; // 隐藏/冻结鼠标（推子手感）
            ui.zoom_last_dy = ui.frozen_dy;
            ui.zoom_rem = 0; // 余数清零（防上一控件残留的不足一单位余数带来首帧误步）
        }
        if (ui.active_id == 4100 + @as(u64, idx)) {
            if (!ui.mouse_down) {
                ui.active_id = 0;
                ui.mouse_capture = false;
            } else {
                const dd = ui.frozen_dy - ui.zoom_last_dy;
                ui.zoom_last_dy = ui.frozen_dy;
                const n_mixer: i32 = @intCast(app.mixer_channels_state.items.len);
                // 用 `zoomStep`：**跨帧累积余数**（慢拖不丢步）。
                // 旧实现 `@divTrunc(dd, 20)` 每帧截断且**丢弃余数**——慢拖
                // （每帧位移 < 20px）永远无响应、快拖单帧跳 4-5 格（实测手感 bug）。
                // 40px/通道（再降一半——8 通道全推完约 280px）；方向与
                // dragNumber/zoomSquare 一致（上拖增大）。
                const r = Ui.zoomStep(inst.mixer, dd, ui.zoom_rem, 40, 0, @max(0, n_mixer - 1));
                ui.zoom_rem = r.rem;
                if (r.v != inst.mixer) inst.mixer = r.v; // 拖动中实时生效
            }
        }
        // 松开时统一提交历史（拖动中 coalesce）
        if (hovered and ui.mouse_released) app.history_pending = "调整混音通道";
        if (active and !ui.mouse_down) app.history_pending = "调整混音通道";
    }
    cx += util.rack_mix_w + 8;

    // 名称（点击选中；双击打开合成器；右键删除）
    const name_w = @min(util.rack_name_w, w - (cx - x) - 10);
    const name_hovered = util.hitUI(ui, cx, y + 2, name_w, util.rack_row_h - 4);
    ui.labelClipped(inst.name, cx + 4, y + @divTrunc(util.rack_row_h - 10, 2), name_w - 8, if (selected) ui.theme.text else ui.theme.text_dim);
    if (name_hovered and ui.mouse_pressed) {
        app.setInstrument(@intCast(idx)); // 切换清选区（防跨乐器孤儿选区）
        app.rack.ctx_instrument = null;
    }
    // 双击名称 → 打开合成器编辑器（编辑该乐器），并**置顶**（最上层）
    if (ui.mouse_double and name_hovered) {
        app.setInstrument(@intCast(idx));
        app.synth_win.instrument = @intCast(idx);
        app.synth_win.open = true;
        app.bringToFront(&app.synth_win.z); // 即时反馈：打开即置顶
    }
    if (name_hovered and ui.mouse_right_pressed) {
        app.rack.ctx_instrument = idx;
        app.rack.ctx_x = ui.mouse_x; // 固定菜单位置
        app.rack.ctx_y = ui.mouse_y;
    }

    // 音符 minimap（仅该乐器 + 当前 pattern 的音符）
    const mm_x = cx + name_w + 8;
    const mm_w = @max(20, x + w - mm_x - 6);
    const mm_h = util.rack_row_h - 10;
    const mm_y = y + 5;
    ui.renderer.fillRect(mm_x, mm_y, mm_w, mm_h, ui.theme.bg);
    ui.renderer.strokeRect(mm_x, mm_y, mm_w, mm_h, ui.theme.panel_border);
    const pattern = app.piano.pattern orelse app.sel.pattern;
    var max_step: i32 = 64; // minimap 总长（步）：至少 4 小节
    var min_pitch: i32 = 127;
    var max_pitch: i32 = 0;
    for (app.notes.items) |n| {
        if (n.pattern != pattern or n.instrument != @as(i32, @intCast(idx))) continue;
        max_step = @max(max_step, n.step + n.len);
        min_pitch = @min(min_pitch, n.pitch);
        max_pitch = @max(max_pitch, n.pitch);
    }
    // 纵向：按实际音域映射（与横向 minimap 同一规则：保底 1 个八度、中点居中）
    const range = model.rangeMap(min_pitch, max_pitch, 12);
    for (app.notes.items) |n| {
        if (n.pattern != pattern or n.instrument != @as(i32, @intCast(idx))) continue;
        const nx = mm_x + @divTrunc(n.step * mm_w, max_step);
        const nw = @max(1, @divTrunc(n.len * mm_w, max_step));
        const y_norm = range.yOf(n.pitch);
        const ny = mm_y + mm_h - 1 - @as(i32, @intFromFloat(y_norm * @as(f32, @floatFromInt(mm_h - 2))));
        const nyc = std.math.clamp(ny, mm_y + 1, mm_y + mm_h - 2);
        ui.renderer.fillRect(nx, nyc, nw, 1, ui.theme.waveform);
    }
}
