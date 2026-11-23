//! 通道机架浮动窗口：乐器行（静音/旋钮/混音/名称/minimap）+ 添加按钮 + 下拉菜单。
//!
//! 输入分层：本窗口的命中检测全部用 `util.inRect`（直接坐标，不受 input_blocked 影响）
//! 或 `util.hitUI`（尊重 input_blocked，供非菜单控件用）。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const model = @import("model.zig");
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");

/// 通道机架（浮动窗口）：乐器行 + 添加按钮；可拖动标题、右下角缩放、关闭。
/// `menu_was_open`：帧首是否有任何下拉菜单展开（本帧窗口控件应全部让位，
/// 防止“关闭菜单的点击”穿透到窗口控件上）。
/// 输入屏蔽由层系统负责（`ui.beginLayer`）——本函数不再手写 input_blocked。
/// 返回 true = 鼠标被窗口消费（屏蔽底层控件交互）。
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32, menu_was_open: bool) bool {
    if (!app.rack.open) return false;
    const rk = &app.rack;
    // 约束在屏幕内（与机架/混音台/帮助页共用 `util.clampWindow`）
    util.clampWindow(w, h, &rk.x, &rk.y, &rk.w, &rk.h, util.rack_min_w, util.rack_min_h);

    const x = rk.x;
    const y = rk.y;
    const ww = rk.w;
    const hh = rk.h;
    const body_y = y + util.rack_title_h;
    const body_h = hh - util.rack_title_h;
    const add_btn_h = util.rack_add_h;
    const add_pad: i32 = 5; // 添加按钮四周留白（列表可视区与按钮都按它让位）
    const list_y = body_y + 1;
    // 列表可视区：**完全让开**添加按钮（按钮高 + 留白 + 1px 缝隙）——
    // 旧式 `- add_btn_h - 2` 比按钮顶低 4px：滚到底时最后一行底部被按钮
    // 盖住一小条（实测；虽还能点，视觉上不干净）。
    const list_h = @max(0, body_h - add_btn_h - add_pad - 2);

    // 菜单模态：任何下拉菜单展开（或帧首展开）时，窗口自身的非菜单控件全部让位
    // （否则菜单项点击会穿透到下面的行/按钮）。
    // 注意：**不覆盖**“被上层窗口屏蔽”的状态（那是 beginLayer 算的；
    // 上面用 or 合幷而不直接赋值）。
    const menu_modal = menu_was_open or app.rack.ctx_instrument != null or app.rack.ctx_pan != null;
    if (menu_modal) ui.input_blocked = true;

    // ── 窗口外壳（阴影/边框/标题栏/关闭/拖动/缩放柄，共享 `util.windowChrome`）──
    // 关闭：本窗口的收尾 = 顺手关乐器菜单（调用方语义，外壳不管）
    if (util.windowChrome(ui, 3000, 3001, "乐器（通道机架）", util.rack_title_h, 24, &rk.x, &rk.y, &rk.w, &rk.h, &rk.grab_dx, &rk.grab_dy, &rk.resize_w0, &rk.resize_h0, &rk.resize_mx, &rk.resize_my, true)) {
        rk.open = false;
        app.rack.ctx_instrument = null;
        return true;
    }

    // ── 乐器行（可滚动；右侧滚动条，溢出时显示——与效果器链面板同款）──
    const content_h: i32 = @intCast(app.instruments.items.len * @as(usize, @intCast(util.rack_row_h)));
    const max_scroll = @max(0, content_h - list_h);
    const rack_sb_w: i32 = if (max_scroll > 0) 7 else 0; // 滚动条让出宽度（6+1 缝隙）
    if (util.hitUI(ui, x + 1, list_y, ww - 2, list_h)) {
        rk.scroll = std.math.clamp(rk.scroll - ui.wheel * 24, 0, max_scroll);
    }
    rk.scroll = std.math.clamp(rk.scroll, 0, max_scroll);

    {
        const saved = ui.renderer.pushClip(x + 1, list_y, ww - 2 - rack_sb_w, list_h);
        defer ui.renderer.popClip(saved);
        // 按**显示顺序**（`order`）逐行画：上下移只改这个顺序，物理槽位不变
        app.ensureOrder();
        var row: usize = 0;
        var ry = list_y - rk.scroll;
        while (row < app.order.items.len) : (row += 1) {
            if (ry + util.rack_row_h > list_y and ry < list_y + list_h) {
                if (app.slotAt(row)) |slot| drawRow(ui, app, slot, row, x + 1, ry, ww - 2 - rack_sb_w, list_y, list_y + list_h);
            }
            ry += util.rack_row_h;
        }
    }
    if (max_scroll > 0) {
        ui.drawScrollbar(x + ww - 7, list_y, 5, list_h, rk.scroll, content_h, list_h);
    }

    // ── 添加按钮：直接打开**预设面板**（统一插件+预设选择器）──
    // 四周留白 = `add_pad`（布局段声明；列表可视区已按它让位）
    const add_x = x + add_pad;
    const add_y = y + hh - add_btn_h - add_pad;
    const add_w = ww - add_pad * 2;
    {
        const hovered = util.hitUI(ui, add_x, add_y, add_w, add_btn_h);
        ui.renderer.fillRect(add_x, add_y, add_w, add_btn_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(add_x, add_y, add_w, add_btn_h, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure("+ 添加乐器"));
        ui.label("+ 添加乐器", add_x + @divTrunc(add_w - tw, 2), add_y + @divTrunc(add_btn_h - 10, 2), ui.theme.text);
        if (hovered and ui.mouse_pressed) app.openPresetBrowser(.create_instrument);
    }
    // 注：VST3 乐器的「浏览文件」入口已移入**插件管理**（单文件条目）——
    // 预设面板中的 VST3 分类来自扫描缓存（用户拍板，2026-10）

    // 右键菜单（打开 / 自动化 / 重命名 / 更换乐器… / 删除乐器 …）——同理：仅在展开时取消屏蔽
    if (app.rack.ctx_instrument != null or app.rack.ctx_pan != null or app.rack.ctx_vol != null) ui.input_blocked = false;
    if (app.rack.ctx_instrument) |ci| {
        if (ci < app.instruments.items.len) {
            const is_vst3 = app.instruments.items[ci].kind == .vst3;
            // **顺序**（两平台一致）：打开 → 自动化 →（VST3 多一项：重新定位插件…）→ …
            // 用枚举分发而不是下标位移（以前靠 `items.len - 2`/`- 1` 算，加项容易误触）
            const Act = enum { open, auto, relocate, rename, change, remove, up, down };
            const Entry = struct { label: []const u8, act: Act };
            const items: []const Entry = if (is_vst3) &.{
                .{ .label = "打开", .act = .open },
                .{ .label = "自动化", .act = .auto },
                .{ .label = "重新定位插件…", .act = .relocate },
                .{ .label = "重命名", .act = .rename },
                .{ .label = "更换乐器…", .act = .change },
                .{ .label = "删除乐器", .act = .remove },
                .{ .label = "上移", .act = .up },
                .{ .label = "下移", .act = .down },
            } else &.{
                .{ .label = "打开", .act = .open },
                .{ .label = "自动化", .act = .auto },
                .{ .label = "重命名", .act = .rename },
                .{ .label = "更换乐器…", .act = .change },
                .{ .label = "删除乐器", .act = .remove },
                .{ .label = "上移", .act = .up },
                .{ .label = "下移", .act = .down },
            };
            const mw: i32 = 160;
            // 走共享 `util.menuPanel`：固定位置（打开时快照进 `ctx_x/ctx_y`，不跟鼠标跑）
            var labels: [8][]const u8 = undefined;
            for (items, 0..) |e, i| labels[i] = e.label;
            var mx = app.rack.ctx_x;
            var my = app.rack.ctx_y;
            var open = true;
            const bounds: @import("ui.zig").Rect = .{ .x = 0, .y = 0, .w = ui.renderer.logicalWidth(), .h = ui.renderer.logicalHeight() };
            const clicked = util.menuPanel(ui, &mx, &my, &open, false, .{ .cursor = {} }, bounds, labels[0..items.len], mw, null);
            if (clicked) |k| {
                const act = items[k].act;
                switch (act) {
                    // 「打开」= 双击打开（同一个 `openInstrumentEditor`）
                    .open => app.openInstrumentEditor(ci),
                    // 「自动化」= 自动化**参数表**（内置乐器只有 MIDI 段；空曲时也能建链）
                    .auto => app.openAutoWinForInstrument(app.instruments.items[ci].uid),
                    .relocate => app.pending_relocate_instrument = ci,
                    // 重命名：输入框弹在乐器名位置（行内就地）
                    .rename => app.beginRenameInstrument(ci, mx + 4, my + 4),
                    // 更换乐器 → 打开预设面板（任意插件；选中即换，保留属性）
                    .change => app.openPresetBrowser(.{ .change_instrument = @intCast(ci) }),
                    .remove => {
                        app.removeInstrument(ci);
                        app.commitHistory("删除乐器"); // 原子操作：立即提交
                    },
                    // 上移/下移：只交换显示顺序（物理槽位/音符引用不变）——已到边界则无效
                    .up => {
                        if (app.moveInstrument(ci, true)) app.commitHistory("移动乐器");
                    },
                    .down => {
                        if (app.moveInstrument(ci, false)) app.commitHistory("移动乐器");
                    },
                }
                app.rack.ctx_instrument = null;
            } else if (!open) {
                // 点外部关闭（`menuPanel` 已判定）
                app.rack.ctx_instrument = null;
            }
        } else {
            app.rack.ctx_instrument = null;
        }
    }

    // 旋钮右键菜单（乐器 音量 / 声像 共用）：**恢复默认值 > 输入值… > 自动化…**
    // （全项目右键菜单统一这个上下顺序）
    if (app.rack.ctx_vol != null or app.rack.ctx_pan != null) {
        const is_vol = app.rack.ctx_vol != null;
        const pi = app.rack.ctx_vol orelse app.rack.ctx_pan.?;
        if (pi < app.instruments.items.len) {
            const items = [_][]const u8{ "恢复默认值", "输入值…", "自动化…" };
            const mw2: i32 = 140;
            var mx = app.rack.ctx_x; // 固定位置（打开时快照，不跟鼠标跑）
            var my = app.rack.ctx_y;
            var open = true;
            const bounds: @import("ui.zig").Rect = .{ .x = 0, .y = 0, .w = ui.renderer.logicalWidth(), .h = ui.renderer.logicalHeight() };
            const clicked = util.menuPanel(ui, &mx, &my, &open, false, .{ .cursor = {} }, bounds, &items, mw2, null);
            if (clicked) |k| {
                const inst = &app.instruments.items[pi];
                if (k == 0) {
                    if (is_vol) {
                        if (inst.volume != 0.75) {
                            inst.volume = 0.75; // 0 dB（推子位置 0.75 = unity）
                            app.commitHistory("恢复乐器音量");
                        }
                    } else if (inst.pan != 0.5) {
                        inst.pan = 0.5; // 居中
                        app.commitHistory("恢复乐器声像");
                    }
                } else if (k == 1) {
                    // **输入值…**（音量按 0..1 小数；声像按 L/R/C 或数字）
                    var vb: [16]u8 = undefined;
                    if (is_vol) {
                        // **dB**（与推子/混音台读数同一映射）；直输 0 = 满刻度，≤−60 = 静音
                        const pre = view_lane.formatValue(.db, inst.volume, &vb);
                        app.beginEditInstVol(pi, pre, mx + 4, my + 4, mw2 - 8);
                    } else {
                        const pre = view_lane.formatValue(.pan, inst.pan, &vb);
                        app.beginEditInstPan(pi, pre, mx + 4, my + 4, mw2 - 8);
                    }
                } else {
                    const tgt = view_lane.Target{
                        .kind = if (is_vol) .inst_vol else .inst_pan,
                        .uid = inst.uid,
                    };
                    app.openAutoWin(tgt);
                }
                app.rack.ctx_vol = null;
                app.rack.ctx_pan = null;
            } else if (!open) {
                // 点外部关闭（`menuPanel` 已判定）
                app.rack.ctx_vol = null;
                app.rack.ctx_pan = null;
            }
        } else {
            app.rack.ctx_vol = null;
            app.rack.ctx_pan = null;
        }
    }

    // 鼠标在窗口内：屏蔽底层控件
    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}

/// 通道机架的一行乐器：静音 / 声像旋钮 / 音量旋钮 / 混音通道 / 名称 / 音符 minimap
/// `clip_top`/`clip_bot`：列表可视区（行可能部分滚出，可视区外的部分不应响应点击——
/// 否则会与标题栏拖动/添加按钮重叠）
fn drawRow(ui: *Ui, app: *App, idx: usize, row: usize, x: i32, y: i32, w: i32, clip_top: i32, clip_bot: i32) void {
    // 鼠标不在列表可视区（含纵向）：屏蔽本行所有交互（绘制照常）
    const prev_blocked = ui.input_blocked;
    if (!(ui.mouse_y >= clip_top and ui.mouse_y < clip_bot)) ui.input_blocked = true;
    defer ui.input_blocked = prev_blocked;

    const inst = &app.instruments.items[idx];
    const selected = app.sel.instrument == @as(i32, @intCast(idx));
    const bg = if (selected) ui.theme.item_selected else if (row % 2 == 1) ui.theme.item_alt else ui.theme.panel;
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

    // 静音开关（开关：开=绿/关=灰）
    if (ui.toggleSquare(!inst.muted, cx, cy, util.rack_mute_w)) { // 蓝=发声 / 灰=静音
        inst.muted = !inst.muted;
        app.commitHistory("切换静音"); // 开关：原子提交
    }
    cx += util.rack_mute_w + 8;

    // 声像旋钮 / 音量旋钮（拖动中 coalesce，松手时提交）
    // **显示值 = 基准 + 曲线贡献**（与混音台同一套：自动化时旋钮跟着真实值走，拖动改的是基准）
    const ky = y + @divTrunc(util.rack_row_h - util.rack_knob_size, 2);
    const cur_step: f32 = @floatFromInt(app.playback.cursorStep(true));
    const pan_tgt = view_lane.Target{ .kind = .inst_pan, .uid = inst.uid };
    const vol_tgt = view_lane.Target{ .kind = .inst_vol, .uid = inst.uid };
    // 声像旋钮（x = cx）——自动化激活 → 进度弧/中心点变绿
    {
        const pan_eff = app.autoValueFor(pan_tgt, cur_step, inst.pan);
        var pan = pan_eff;
        // 自动化状态着色（§11.48）：绿 = 曲线在驱动；**橙 = 本场被手动接管**；无色 = 无自动化
        if (ui.knobAutoState(4000 + @as(u64, idx) * 2, &pan, cx, ky, util.rack_knob_size, app.isAutoActive(pan_tgt), app.isAutoTakeover(pan_tgt))) {
            // 拖动期间手动接管；**写回 = 旋钮显示值本身**（不是“旧静态值 + 增量” → 起手跳一大下 = 爆音）
            inst.pan = app.dragWriteback(pan_tgt, pan);
            app.history_pending = "调整声像";
        }
    }
    if (util.hitUI(ui, cx, ky, util.rack_knob_size, util.rack_knob_size) and ui.mouse_right_pressed) {
        app.rack.ctx_pan = idx;
        app.rack.ctx_vol = null;
        app.rack.ctx_instrument = null; // 互斥
        app.rack.ctx_x = ui.mouse_x;
        app.rack.ctx_y = ui.mouse_y;
    }
    cx += util.rack_knob_size + 6;
    // 音量旋钮（x = 前进后的 cx）——右键菜单用**音量旋钮自己的 x**（原来误用了声像的 x：
    // 右键声像弹出音量菜单、右键音量没反应，实测 bug）
    {
        const vol_eff = app.autoValueFor(vol_tgt, cur_step, inst.volume);
        var vol = vol_eff;
        if (ui.knobAutoState(4000 + @as(u64, idx) * 2 + 1, &vol, cx, ky, util.rack_knob_size, app.isAutoActive(vol_tgt), app.isAutoTakeover(vol_tgt))) {
            inst.volume = app.dragWriteback(vol_tgt, vol);
            app.history_pending = "调整乐器音量";
        }
    }
    if (util.hitUI(ui, cx, ky, util.rack_knob_size, util.rack_knob_size) and ui.mouse_right_pressed) {
        app.rack.ctx_vol = idx;
        app.rack.ctx_pan = null;
        app.rack.ctx_instrument = null;
        app.rack.ctx_x = ui.mouse_x;
        app.rack.ctx_y = ui.mouse_y;
    }
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

    // 名称（点击选中；双击打开编辑器；右键乐器菜单）
    const name_w = @min(util.rack_name_w, w - (cx - x) - 10);
    const name_hovered = util.hitUI(ui, cx, y + 2, name_w, util.rack_row_h - 4);
    const name_col = if (inst.load_failed) ui.theme.danger else if (selected) ui.theme.text else ui.theme.text_dim;
    ui.labelClipped(inst.name, cx + 4, y + @divTrunc(util.rack_row_h - 10, 2), name_w - 8, name_col);
    if (name_hovered and ui.mouse_pressed) {
        app.setInstrument(@intCast(idx)); // 切换清选区（防跨乐器孤儿选区）
        app.rack.ctx_instrument = null;
    }
    // 双击名称 → 打开编辑器（合成器 → 合成器窗口；鼓组 → 鼓组编辑器）
    if (ui.mouse_double and name_hovered) app.openInstrumentEditor(idx);
    // 右键（名称 + 音符 minimap）：乐器菜单（打开 / 自动化 / 重命名 …）
    if (util.hitUI(ui, cx, y + 2, (x + w) - cx, util.rack_row_h - 4) and ui.mouse_right_pressed) {
        app.rack.ctx_instrument = idx;
        app.rack.ctx_pan = null; // 互斥（声像/音量旋钮菜单）
        app.rack.ctx_vol = null;
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
    // 统计 + 位图均走缓存（key 含像素尺寸）：每行预览不再每帧扫 `notes`
    const pv = app.rackPreviewFor(@intCast(idx), pattern, mm_w, mm_h);
    // 绘制：按**置位像素**点亮（与横向 minimap 同一套语义；成本与音符数无关）
    if (pv.cols > 0 and pv.rows > 0) {
        const wpr: usize = (@as(usize, @intCast(pv.cols)) + 63) / 64;
        const need = wpr * @as(usize, @intCast(pv.rows));
        if (pv.words.len >= need) {
            var r: i32 = 0;
            while (r < pv.rows) : (r += 1) {
                const py = mm_y + @divTrunc(r * (mm_h - 2), pv.rows) + 1;
                const base = @as(usize, @intCast(r)) * wpr;
                var col: i32 = 0;
                while (col < pv.cols) : (col += 1) {
                    const ci: usize = @intCast(col);
                    if ((pv.words[base + ci / 64] >> @intCast(ci % 64)) & 1 == 0) continue;
                    const px = mm_x + @divTrunc(col * mm_w, pv.cols);
                    const pw = @max(1, @divTrunc((col + 1) * mm_w, pv.cols) - @divTrunc(col * mm_w, pv.cols));
                    ui.renderer.fillRect(px, py, pw, 1, ui.theme.waveform);
                }
            }
        }
    }
}
