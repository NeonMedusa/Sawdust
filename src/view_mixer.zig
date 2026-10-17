//! 调音台（浮动窗口）：**纵向编号标尺 + 横向通道条 + 右侧效果器链**。
//!
//! 布局：
//! - **左**：纵向编号标尺（`0`、`1`、`2`… 与各通道条行对齐；末行 `+` = 添加通道）；
//! - **中**：横向通道条，每行 = `[M][S]` · 声像旋钮 · 通道名（**定宽**，超出裁剪——
//!   将来做省略号）· 音量推子 · 数值；
//! - **右**：选中通道的效果器链（**较窄**）：抬头 + 效果行 + 空槽 + 添加按钮。
//!
//! 行数多 / 窗口矮时**纵向滚动**（滚轮）。
//! 通道名目前是占位（“主通道 / 通道#N”）；右键重命名与通道增删是未来计划。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");
const model = @import("model.zig");

const win_title_h: i32 = 22;
/// 窗口最小宽 = 两区最小宽 + 分割条 + 内边距（`left_min_w + fx_panel_min_w + sp_w + pad_x`）
/// ——**与分割条拖动同一极限**：窗口缩到最小 ⇔ 分割条拖到最左。
const win_min_w: i32 = 544;
const win_min_h: i32 = 240;

// ── 通道条（横向）──
const row_h: i32 = 26; // 行高
/// 行间距 = 2（视觉留缝）
const row_gap: i32 = 2;
/// **命中区扩展**：行命中区上下各扩这么多像素（盖住行间缝隙——
/// 视觉留缝但手感无缝，实测反馈：点缝里“挫败感强”）
const row_hit_ext: i32 = row_gap / 2;
const ruler_w: i32 = 22; // 编号标尺列宽
const mute_size: i32 = 18;
const knob_size: i32 = 20;
// ── 两区宽度的**共同约束**（分割条拖动与窗口缩放共用——否则两个交互的极限不一致）──
/// 左区（标尺 + 通道条）最小宽（放得下：标尺 22 + [M][S] + 旋钮 + 名字 110 + 推子 60 + 数值）
const left_min_w: i32 = 330;
/// 右区（效果器链）最小宽（能放下“EQ 参量均衡”+ 干湿旋钮）
const fx_panel_min_w: i32 = 198;
/// 分割条宽
const sp_w: i32 = 4;
/// **分区内边距**（两个添加按钮/效果行 相对各自分区背景的左右边距——统一值）
const pad_inner: i32 = 6;
/// 通道条在左区内的水平留白（**左右视觉留白均 5px**）：
/// - 左：标尺分隔线占 1px（在 `left_x + ruler_w + 1`）→ 条 x = `left_x + ruler_w + 7`
/// - 右：左区背景边框占 1px（在 `left_x + left_w - 1`）→ 条宽 = `left_w - ruler_w - 13`
/// （实测反馈：修前左侧留白 4px、右侧 5px——分隔线/边框各占 1px 导致的偏差）
const strip_pad_l: i32 = 7;
const strip_pad_r: i32 = 6;
/// 水平内边距总开销：左侧 6 + 右侧 6（两区背景块的内边距）
const pad_x: i32 = 12;
/// 通道名定宽（超出裁剪；省略号待做——“总长度固定”）
const name_w: i32 = 110;
/// 音量数值列宽
const value_w: i32 = 34;

// ── 右区（效果器链）──
const fx_row_h: i32 = 26;
const fx_knob: i32 = 18;

// ── 本窗口控件 id（**全应用唯一**——撞 id 会串场，见 docs/pitfalls.md）──
// 全部控件统一占 **8100-8711 独占段**（避开其它视图：钢琴卷帘
// 7100/7200/7300/7500、播放列表 7000/7400/7501、效果窗 7600-7809 等）。
// 实测 bug：旧值 7200+ci 与钢琴卷帘 PAT 标尺 7200 撞车——点主通道声像
// 旋钮会跳播放游标、点标尺会改声像（7300/7500 两个控件同理）。
const id_pan_base: u64 = 8100; // 声像旋钮：+ 通道号（0-31）
const id_vol_base: u64 = 8150; // 音量推子：+ 通道号（0-31）
const id_fx_mix_base: u64 = 8200; // 干湿旋钮：+ 通道号×16 + 槽位

/// 右键菜单弹出位置：鼠标处 → **鉗制到窗口内**（方案 C）。
///
/// 动机（实测隐患）：窗口层只屏蔽窗口矩形——菜单超出窗口的部分
/// 点击会**穿透到下层**。鉗制后菜单永远在窗口内，现有层矩形已覆盖，
/// 不必改层系统；顺带避免“右键靠边时菜单探出窗口”的观感问题。
/// （主流软件的右键菜单也是这么做的：靠边时向内让位。）
fn ctxMenuPos(mw: *const app_mod.MixerWindow, menu_w: i32, menu_h: i32) [2]i32 {
    const max_x: i32 = @max(mw.x, mw.x + mw.w - menu_w);
    const max_y: i32 = @max(mw.y, mw.y + mw.h - menu_h);
    return .{
        std.math.clamp(mw.ctx_menu_x, mw.x, max_x),
        std.math.clamp(mw.ctx_menu_y, mw.y, max_y),
    };
}

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const mw = &app.mixer_win;
    if (!mw.open) return false;

    // 约束在屏幕内
    mw.w = std.math.clamp(mw.w, win_min_w, @max(win_min_w, w - 20));
    mw.h = std.math.clamp(mw.h, win_min_h, @max(win_min_h, h - 20));
    mw.x = std.math.clamp(mw.x, 0, @max(0, w - mw.w));
    mw.y = std.math.clamp(mw.y, 0, @max(0, h - mw.h));

    const x = mw.x;
    const y = mw.y;
    const ww = mw.w;
    const hh = mw.h;
    const body_y = y + win_title_h;

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, win_title_h - 1, ui.theme.toolbar);
    ui.label("调音台 (Mixer)", x + 8, y + 4, ui.theme.text);

    // 点窗口内任意处 → 置顶（“点谁谁在上”——与其他浮动窗口一致）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&mw.z);
    }

    // 关闭按钮
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, win_title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, win_title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        mw.open = false;
        mw.ctx_effect = null;
        return true;
    }

    // 标题拖动
    if (util.hitUI(ui, x, y, ww - 24, win_title_h) and ui.mouse_pressed) {
        ui.active_id = 7160; // 独立 id 段（7100 与钢琴卷帘 SONG 标尺撞车；7150 = 分割条）
        mw.grab_dx = ui.mouse_x - x;
        mw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 7160) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            mw.x = ui.mouse_x - mw.grab_dx;
            mw.y = ui.mouse_y - mw.grab_dy;
        }
    }

    // 右下角缩放柄
    const grip = 14;
    const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
    if (grip_hovered) ui.cursor = .resize_h;
    if (grip_hovered and ui.mouse_pressed) {
        ui.active_id = 7161;
        mw.resize_w0 = ww;
        mw.resize_h0 = hh;
        mw.resize_mx = ui.mouse_x;
        mw.resize_my = ui.mouse_y;
    }
    if (ui.active_id == 7161) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            mw.w = mw.resize_w0 + (ui.mouse_x - mw.resize_mx);
            mw.h = mw.resize_h0 + (ui.mouse_y - mw.resize_my);
        }
    }
    ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);
    ui.renderer.line(x + ww - 6, y + hh - 2, x + ww - 2, y + hh - 6, ui.theme.panel_border);

    // ── 分区：左块（标尺 + 通道条）/ 右区（效果器链）──
    // 右区宽度 = `fx_w`（可拖动分割条调整）。分割条拖动改的是**左区宽**
    // （与主面板两段式一致：拖谁改谁），再由它反推 `fx_w`。
    //
    // **共同约束**：分割条拖动与窗口缩放共用同一组边界
    // （左区 ≥ `left_min_w`、右区 ≥ `fx_panel_min_w`）——否则两个交互的极限
    // 不一致（实测反馈：分割条只能把通道条缩到 A，窗口缩放能缩到 B）。
    const n_ch: i32 = @intCast(app.mixer_channels_state.items.len);
    const left_x = x + 6;
    const left_y = body_y + 6;
    const left_h = hh - win_title_h - 12;

    // 可用总宽（两区 + 分割条）——**两侧各留 6px**（`left_x = x+6`，右区右缘 = `x+ww-6`）
    const avail_w: i32 = ww - pad_x - sp_w;
    // 右区合法区间：下限 = 最小宽；上限 = 可用总宽 − 左区最小宽
    // （窗口够宽时右区可以很宽——不再是固定上限）
    const right_min: i32 = fx_panel_min_w;
    const right_max: i32 = @max(right_min, avail_w - left_min_w);
    if (mw.fx_w == 0) mw.fx_w = std.math.clamp(@divTrunc(ww, 4), right_min, right_max);
    mw.fx_w = std.math.clamp(mw.fx_w, right_min, right_max);

    // 左区宽（由 fx_w 反推）
    const left_w0: i32 = avail_w - mw.fx_w;
    // 分割条 x：**紧贴左区背景右缘**（无额外间隙——三者相接，两侧边距才对称）
    const sp_x = left_x + left_w0;
    // 拖动分割条 → 改左区宽 → 反推 fx_w（**与窗口缩放同一组边界**）
    {
        var lw: i32 = left_w0;
        if (ui.splitterV(7150, &lw, sp_x, left_y, left_h, sp_w, left_min_w, @max(left_min_w, avail_w - right_min))) {
            mw.fx_w = std.math.clamp(avail_w - lw, right_min, right_max);
        }
    }
    // 拖动后重算（保证分割条/两区都在**本帧新位置**绘制，不滞后一帧）
    const left_w: i32 = avail_w - mw.fx_w;
    const right_w: i32 = mw.fx_w;
    // 右区左缘 = 分割条右缘（紧接）；右缘 = `x+ww-6`（与左区左边距 6 对称）
    const right_x = left_x + left_w + sp_w;
    const right_y = left_y;
    const right_h = left_h;

    // 背景块
    ui.renderer.fillRect(left_x, left_y, left_w, left_h, ui.theme.bg);
    ui.renderer.strokeRect(left_x, left_y, left_w, left_h, ui.theme.panel_border);
    ui.renderer.fillRect(right_x, right_y, right_w, right_h, ui.theme.bg);
    ui.renderer.strokeRect(right_x, right_y, right_w, right_h, ui.theme.panel_border);

    // ── 行列表（标尺 + 通道条；纵向滚动）；底部固定“+ 添加通道”──
    // 垂直留白：条顶距框线 5px（框线占 1px → 起点用 `pad_inner`）、
    // 条底距按钮 5px、按钮底距框线 5px（实测反馈：修前顶 1px / 底 4px）
    const add_ch_h: i32 = 20;
    const list_top: i32 = left_y + pad_inner; // 条列表起点（框线 1px + 5px 留白）
    const btn_bot_gap: i32 = pad_inner; // 按钮底距框线
    const list_btn_gap: i32 = 5; // 条底距按钮（**纯空白**——无框线占位，直接用 5px）
    const btn_y: i32 = left_y + left_h - btn_bot_gap - add_ch_h - 1; // 按钮顶（-1 = 底框线）
    const list_view_h = @max(0, btn_y - list_btn_gap - list_top);
    const content_h: i32 = n_ch * (row_h + row_gap);
    const scroll_max: i32 = @max(0, content_h - list_view_h);
    const ch_sb_w: i32 = if (scroll_max > 0) 7 else 0; // 右侧滚动条占位（溢出时）
    mw.strips_scroll = std.math.clamp(mw.strips_scroll, 0, scroll_max);
    if (util.hitUI(ui, left_x, left_y, left_w, left_h)) {
        mw.strips_scroll = std.math.clamp(mw.strips_scroll - ui.wheel * 30, 0, scroll_max);
    }
    // 标尺列（固定背景 + 右侧分隔线；**也覆盖底部按钮行**，保持竖线连续）
    ui.renderer.fillRect(left_x + 1, left_y + 1, ruler_w, left_h - 2, ui.theme.toolbar);
    ui.renderer.vline(left_x + ruler_w + 1, left_y + 1, left_h - 2, ui.theme.panel_border);
    // 列表裁剪区：从框线下方一直到按钮上方（高度 = `list_view_h` 再含上留白）
    const list_clip_h: i32 = list_view_h + (list_top - left_y) + 1; // 含上留白 + 下到按钮
    {
        const saved = ui.renderer.pushClip(left_x + ruler_w + 2, left_y + 1, left_w - ruler_w - 3, list_clip_h);
        defer ui.renderer.popClip(saved);
        var ci: i32 = 0;
        while (ci < n_ch) : (ci += 1) {
            const ry = list_top + ci * (row_h + row_gap) - mw.strips_scroll;
            if (ry + row_h < left_y or ry > list_top + list_view_h) continue;
            drawStrip(ui, app, @intCast(ci), left_x + ruler_w + strip_pad_l, ry, left_w - ruler_w - strip_pad_l - strip_pad_r - ch_sb_w, row_h);
        }
    }
    // 标尺数字（单独一层：在条左边缘，不被条裁剪）
    {
        const saved = ui.renderer.pushClip(left_x + 1, left_y + 1, ruler_w, list_clip_h);
        defer ui.renderer.popClip(saved);
        var ci: i32 = 0;
        while (ci < n_ch) : (ci += 1) {
            const ry = list_top + ci * (row_h + row_gap) - mw.strips_scroll;
            if (ry + row_h < left_y or ry > list_top + list_view_h) continue;
            var b: [8]u8 = undefined;
            const t = std.fmt.bufPrint(&b, "{d}", .{ci}) catch "";
            const tw: i32 = @intFromFloat(ui.font.measure(t));
            ui.label(t, left_x + 1 + @divTrunc(ruler_w - tw, 2), ry + @divTrunc(row_h - 10, 2), ui.theme.text_dim);
            // 点标尺数字 → 选中该通道（**命中区同条一样无缝**：上下各扩 row_hit_ext）
            if (util.hitUI(ui, left_x + 1, ry - row_hit_ext, ruler_w, row_h + row_hit_ext * 2) and ui.mouse_pressed) {
                app.mixer_win.selected_channel = ci;
            }
        }
    }
    // 右侧滚动条（通道列表溢出时；与效果器链面板同款）
    if (scroll_max > 0) {
        ui.drawScrollbar(left_x + left_w - 7, list_top, 5, list_view_h, mw.strips_scroll, content_h, list_view_h);
    }
    // 底部固定：“+ 添加通道”
    {
        const by = btn_y;
        // 水平位置与通道条**完全对齐**（含左右留白）
        const bx = left_x + ruler_w + strip_pad_l;
        const bw = left_w - ruler_w - strip_pad_l - strip_pad_r - ch_sb_w;
        const hovered = util.hitUI(ui, bx, by, bw, add_ch_h);
        ui.renderer.fillRect(bx, by, bw, add_ch_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(bx, by, bw, add_ch_h, ui.theme.panel_border);
        const lbl = "+ 添加通道";
        const tw: i32 = @intFromFloat(ui.font.measure(lbl));
        ui.label(lbl, bx + @divTrunc(bw - tw, 2), by + 3, ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            if (app.addMixerChannel()) |ni| {
                app.mixer_win.selected_channel = @intCast(ni);
                app.commitHistory("添加通道");
            } else {
                app.setToast("无法添加通道（内存不足）");
            }
        }
    }

    // ── 右区：选中通道的效果器链 ──
    const sel_ch: usize = if (mw.selected_channel >= 0 and mw.selected_channel < n_ch) @intCast(mw.selected_channel) else 0;
    drawEffectPanel(ui, app, sel_ch, right_x, right_y, right_w, right_h);

    // 本窗右键菜单展开：解除全局屏蔽，让菜单项可点（同机架模式：
    // 上方控件用 hitUI 已被 menuIsOpen 屏蔽；菜单本体用裸 inRect 接收）
    if (mw.ctx_effect != null or mw.ctx_channel != null or mw.ctx_pan != null) ui.input_blocked = false;
    // ── 效果器右键菜单 ──
    if (mw.ctx_effect) |ctx| {
        drawCtxMenu(ui, app, ctx);
    }
    // ── 通道右键菜单（重命名/删除/上移/下移；**主通道不可移动**）──
    if (mw.ctx_channel) |cc| {
        const items = [_][]const u8{ "重命名", "删除通道", "上移", "下移" };
        const ch_ok = [_]bool{ true, cc != 0, cc != 0, cc != 0 };
        drawCtxMenuGeneric(ui, app, cc, null, &items, &ch_ok, false);
    }
    // ── 声像旋钮右键菜单（恢复默认值）──
    if (mw.ctx_pan) |pc| {
        drawPanCtxMenu(ui, app, pc);
    }

    return true;
}

/// 横向通道条：`[声音开关][S]` · 声像旋钮 · 通道名（定宽）· 音量推子 · 数值。
/// 点条任意处（除控件）= 选中该通道。
fn drawStrip(ui: *Ui, app: *App, ci: usize, x: i32, y: i32, w: i32, h: i32) void {
    const mc = &app.mixer_channels_state.items[ci];
    const selected = app.mixer_win.selected_channel == @as(i32, @intCast(ci));
    const bg = if (selected)
        ui.theme.item_selected
    else if (ci % 2 == 1)
        ui.theme.item_alt
    else
        ui.theme.toolbar;
    ui.renderer.fillRect(x, y, w, h, bg);
    ui.renderer.strokeRect(x, y, w, h, if (selected) ui.theme.accent else ui.theme.panel_border);

    // 点条（非控件区）= 选中
    // **命中区无缝**：向上/下各扩 `row_hit_ext` 盖住行间缝隙（视觉仍留缝，手感无缝）
    const bar_clicked = util.hitUI(ui, x, y - row_hit_ext, w, h + row_hit_ext * 2) and ui.mouse_pressed;
    var consumed = false;
    // 控件的右键已处理（如声像旋钮菜单）——条级右键不再覆盖
    var right_consumed = false;
    var cx = x + 5;

    // 声音开关（蓝=发声 / 灰=静音；方块无字母——语义已非“M 静音”，用户要求去字）
    {
        const my = y + @divTrunc(h - mute_size, 2);
        if (ui.toggleSquare(!mc.muted, cx, my, mute_size)) {
            mc.muted = !mc.muted;
            app.commitHistory("切换通道静音");
            consumed = true;
        }
        cx += mute_size + 4;
    }
    // [S] 独奏（占位，暂未接音频）
    {
        const my = y + @divTrunc(h - mute_size, 2);
        const hovered = util.hitUI(ui, cx, my, mute_size, mute_size);
        ui.renderer.fillRect(cx, my, mute_size, mute_size, ui.theme.slider_track);
        ui.renderer.strokeRect(cx, my, mute_size, mute_size, ui.theme.panel_border);
        ui.label("S", cx + 5, my + 2, ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) {
            app.setToast("独奏：计划中");
            consumed = true;
        }
        cx += mute_size + 8;
    }
    // 声像旋钮
    {
        const ky = y + @divTrunc(h - knob_size, 2);
        var pan = mc.pan;
        if (ui.knob(id_pan_base + @as(u64, ci), &pan, cx, ky, knob_size)) {
            mc.pan = pan;
            app.history_pending = "调整通道声像";
            consumed = true;
        }
        // 右键 → 恢复默认值菜单（居中 0.5）。
        // 注：置 `right_consumed`——否则条级右键（选中/通道菜单）同帧又盖一遍。
        if (util.hitUI(ui, cx, ky, knob_size, knob_size) and ui.mouse_right_pressed) {
            app.mixer_win.selected_channel = @intCast(ci);
            app.mixer_win.ctx_pan = ci;
            app.mixer_win.ctx_channel = null;
            app.mixer_win.ctx_effect = null;
            app.mixer_win.ctx_menu_x = ui.mouse_x;
            app.mixer_win.ctx_menu_y = ui.mouse_y;
            right_consumed = true;
        }
        cx += knob_size + 8;
    }
    // 通道名（**定宽**；超出裁剪——省略号待做）。自定义名优先
    {
        var nb: [24]u8 = undefined;
        const name = if (ci < app.mixer_channels_state.items.len)
            app.mixer_channels_state.items[ci].displayName(ci, &nb)
        else
            app_mod.defaultChannelName(ci, &nb);
        ui.labelClipped(name, cx + 2, y + 4, name_w, if (selected) ui.theme.text else ui.theme.text_dim);
        cx += name_w + 10;
    }
    // 音量推子（横向；占剩余宽度）
    {
        const val_x = x + w - value_w - 6;
        const slider_w = @max(60, val_x - cx - 8);
        const sy = y + @divTrunc(h - 18, 2);
        var vol = mc.volume;
        if (ui.slider(id_vol_base + @as(u64, ci), &vol, cx, sy, slider_w, 18)) {
            mc.volume = vol;
            app.history_pending = "调整通道音量";
            consumed = true;
        }
        // 数值（右对齐）
        var vb: [16]u8 = undefined;
        const vt = std.fmt.bufPrint(&vb, "{d:.2}", .{mc.volume}) catch "";
        const vtw: i32 = @intFromFloat(ui.font.measure(vt));
        ui.label(vt, x + w - vtw - 6, y + 4, ui.theme.text_dim);
    }

    // 未点控件 → 选中该通道
    if (bar_clicked and !consumed) {
        app.mixer_win.selected_channel = @intCast(ci);
    }
    // 右键 → 通道菜单（删除/上移/下移）；控件的右键菜单优先（`right_consumed`）
    if (!right_consumed and util.hitUI(ui, x, y, w, h) and ui.mouse_right_pressed) {
        app.mixer_win.selected_channel = @intCast(ci);
        app.mixer_win.ctx_channel = ci;
        app.mixer_win.ctx_effect = null;
        app.mixer_win.ctx_pan = null;
        app.mixer_win.ctx_menu_x = ui.mouse_x;
        app.mixer_win.ctx_menu_y = ui.mouse_y;
    }
}

/// （已移除：通道名改由 `MixerChannel.displayName` 提供——自定义名/占位名）

/// 右区：选中通道的效果器链（抬头 + 效果行 + 空槽 + 添加按钮）
fn drawEffectPanel(ui: *Ui, app: *App, ci: usize, x: i32, y: i32, w: i32, h: i32) void {
    const mc = &app.mixer_channels_state.items[ci];
    var cy = y + 6;

    // 抬头：CH n · 路由乐器名 +N
    {
        var buf: [96]u8 = undefined;
        var inst_names_buf: [64]u8 = undefined;
        const inst_names = model.routedInstrumentNames(app.instruments.items, ci, &inst_names_buf);
        const title = std.fmt.bufPrint(&buf, "CH {d}{s}{s}", .{
            ci, // 与标尺/默认通道名同一编号（0 起；曾误用 +1）
            if (inst_names.len > 0) " · " else "",
            inst_names,
        }) catch "";
        ui.labelClipped(title, x + pad_inner, cy, w - pad_inner * 2, ui.theme.text);
    }
    cy += 20;
    ui.renderer.hline(x + pad_inner, cy, w - pad_inner * 2, ui.theme.panel_border);
    cy += 6;

    // 效果行（**动态链**：有几个画几个）+ 滚动（放不下时滚轮）+ 底部添加按钮
    const add_h: i32 = 20;
    const rows_top = cy;
    const rows_bot = y + h - add_h - pad_inner - 1; // 底框线 1px + 留白
    const rows_area_h = @max(0, rows_bot - rows_top);
    const content_h: i32 = @as(i32, @intCast(mc.effects.items.len)) * fx_row_h;
    const scroll_max: i32 = @max(0, content_h - rows_area_h);
    app.mixer_win.fx_scroll = std.math.clamp(app.mixer_win.fx_scroll, 0, scroll_max);
    // 滚轮（悬停在效果链区）
    if (util.hitUI(ui, x, rows_top, w, rows_area_h) and scroll_max > 0) {
        app.mixer_win.fx_scroll = std.math.clamp(app.mixer_win.fx_scroll - ui.wheel * 24, 0, scroll_max);
    }
    const scrollbar_w: i32 = if (scroll_max > 0) 6 else 0; // 有滚动条时给行让出宽度
    {
        const saved = ui.renderer.pushClip(x + 1, rows_top, w - 2, rows_area_h);
        defer ui.renderer.popClip(saved);
        var si: usize = 0;
        while (si < mc.effects.items.len) : (si += 1) {
            const ey = rows_top + @as(i32, @intCast(si)) * fx_row_h - app.mixer_win.fx_scroll;
            if (ey + fx_row_h < rows_top or ey > rows_bot) continue; // 视口剔除
            drawEffectRow(ui, app, ci, si, x + pad_inner, ey, w - pad_inner * 2 - scrollbar_w, fx_row_h - 2);
        }
    }
    // 滚动条（内容超出时）
    if (scroll_max > 0) {
        ui.drawScrollbar(x + w - 7, rows_top, 5, rows_area_h, app.mixer_win.fx_scroll, content_h, rows_area_h);
    }

    // 底部：「+ 效果器」（池化：无人工上限）
    {
        const by = y + h - add_h - pad_inner - 1;
        const label: []const u8 = "+ 效果器";
        const hovered = util.hitUI(ui, x + pad_inner, by, w - pad_inner * 2, add_h);
        ui.renderer.fillRect(x + pad_inner, by, w - pad_inner * 2, add_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(x + pad_inner, by, w - pad_inner * 2, add_h, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure(label));
        ui.label(label, x + @divTrunc(w - tw, 2), by + 3, ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            // M5：不再用下拉菜单——直接打开预设浏览器面板（内置 + 已扫描 VST3 效果）
            app.openPresetBrowser(.{ .create_effect = ci });
        }
    }
}

/// 一行效果器：开关 + 名字（点击开面板）+ 干湿旋钮
fn drawEffectRow(ui: *Ui, app: *App, ci: usize, si: usize, x: i32, y: i32, w: i32, h: i32) void {
    const mc = &app.mixer_channels_state.items[ci];
    const es = &mc.effects.items[si];

    ui.renderer.fillRect(x, y, w, h, if (es.enabled) ui.theme.slider_track else ui.theme.toolbar);
    ui.renderer.strokeRect(x, y, w, h, ui.theme.panel_border);

    // 开关（左侧小方块）
    const sw: i32 = 14;
    const sw_hovered = util.hitUI(ui, x + 3, y + @divTrunc(h - sw, 2), sw, sw);
    ui.renderer.fillRect(x + 3, y + @divTrunc(h - sw, 2), sw, sw, if (es.enabled) ui.theme.accent else ui.theme.slider_track);
    ui.renderer.strokeRect(x + 3, y + @divTrunc(h - sw, 2), sw, sw, ui.theme.panel_border);
    if (sw_hovered and ui.mouse_pressed) {
        es.enabled = !es.enabled;
        app.commitHistory("切换效果器开关");
    }

    // 名字（**交互与乐器对齐**：单击 = 切换（面板已开时跟随切到此效果——
    // 同“合成器窗口跟随选中乐器”；不开窗、不抢焦点）；双击 = 打开/切换 + 置顶）。
    // 注：单击分支排除 `ui.mouse_double`——双击的第二下系统会补发
    // mouse_down（见 window.zig），不排除则双击的第一下就触发“切换”。
    const name_x = x + 3 + sw + 6;
    const name_avail = w - (name_x - x) - (fx_knob + 22);
    const name_hovered = util.hitUI(ui, name_x, y, @max(1, name_avail), h);
    const open_now = if (app.mixer_win.panel) |p| p.ch == ci and p.slot == si else false;
    const name_col = if (es.load_failed) ui.theme.danger else if (name_hovered or open_now) ui.theme.accent else if (es.enabled) ui.theme.text else ui.theme.text_dim;
    ui.labelClipped(es.kind.displayName(), name_x, y + 4, @max(1, name_avail), name_col);
    if (name_hovered and ui.mouse_pressed and !ui.mouse_double) {
        // 单击 = 切换：面板已开时跟随切到这个效果；未开时不开窗（那是双击的职责）
        if (app.mixer_win.panel != null) {
            app.mixer_win.panel = .{ .ch = ci, .slot = si };
        }
    }
    if (name_hovered and ui.mouse_double) {
        // 双击：打开/切换独立面板并**置顶**
        app.mixer_win.panel = .{ .ch = ci, .slot = si };
        app.mixer_win.ctx_effect = null;
        app.bringToFront(&app.effect_win.z);
    }
    // 右键 → 删除菜单
    if (name_hovered and ui.mouse_right_pressed) {
        app.mixer_win.ctx_effect = .{ .ch = ci, .slot = si };
        app.mixer_win.ctx_channel = null;
        app.mixer_win.ctx_pan = null;
        app.mixer_win.ctx_menu_x = ui.mouse_x;
        app.mixer_win.ctx_menu_y = ui.mouse_y;
    }

    // 干湿旋钮（右侧）
    {
        const kx = x + w - fx_knob - 6;
        const ky = y + @divTrunc(h - fx_knob, 2);
        var mix = es.mix;
        if (ui.knob(id_fx_mix_base + @as(u64, ci) * 16 + @as(u64, si), &mix, kx, ky, fx_knob)) {
            es.mix = mix;
            app.history_pending = "调整效果器干湿";
        }
    }
}

/// 效果器右键菜单（位置在**打开时快照**——不跟鼠标跑，否则永远点不到）
fn drawCtxMenu(ui: *Ui, app: *App, ctx: app_mod.EffectRef) void {
    // 插件槽多一项「重新定位插件…」（换路径；pending 状态保留）
    const is_plugin = ctx.ch < app.mixer_channels_state.items.len and
        ctx.slot < app.mixer_channels_state.items[ctx.ch].effects.items.len and
        app.mixer_channels_state.items[ctx.ch].effects.items[ctx.slot].kind == .plugin;
    if (is_plugin) {
        const items = [_][]const u8{ "更换效果器…", "重新定位插件…", "删除效果器", "上移", "下移" };
        drawCtxMenuGeneric(ui, app, ctx.ch, ctx.slot, &items, null, true);
    } else {
        const items = [_][]const u8{ "更换效果器…", "删除效果器", "上移", "下移" };
        drawCtxMenuGeneric(ui, app, ctx.ch, ctx.slot, &items, null, false);
    }
}

/// 通用右键菜单（效果器/通道共用）：位置由**打开时快照**提供
/// （绘制时再**钳制到窗口内**——菜单不得超出窗口，否则超出部分点击会
/// 穿透到下层；见 `ctxMenuPos`）。`slot` 为 `null` 时是**通道菜单**。
/// `ok`：逐项可用性（null = 全可用；置灰项不响应点击）。
fn drawCtxMenuGeneric(ui: *Ui, app: *App, ch: usize, slot: ?usize, items: []const []const u8, ok: ?[]const bool, has_relocate: bool) void {
    const mw_win = &app.mixer_win;
    const menu_w: i32 = 130;
    const menu_h: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const pos = ctxMenuPos(mw_win, menu_w, menu_h);
    const mx = pos[0];
    const my = pos[1];
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h); // 遮挡插件子窗口

    var clicked: ?usize = null;
    var inside = false;
    for (items, 0..) |item, i| {
        const enabled = if (ok) |o| (i < o.len and o[i]) else true;
        const iy = my + 2 + @as(i32, @intCast(i)) * util.menu_item_h;
        const ih = enabled and util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (ih) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, if (enabled) ui.theme.text else ui.theme.text_dim);
        if (ih and ui.mouse_pressed) clicked = i;
    }

    if (clicked) |ci| {
        if (slot == null) {
            // 通道菜单：重命名 / 删除通道 / 上移 / 下移
            switch (ci) {
                0 => app.beginRenameMixerChannel(ch, mx + 4, my + 4),
                1 => {
                    if (app.removeMixerChannel(ch)) {
                        app.commitHistory("删除通道");
                    } else {
                        app.setToast("至少保留一个通道");
                    }
                },
                2 => {
                    if (app.moveMixerChannel(ch, -1)) app.commitHistory("通道上移");
                },
                3 => {
                    if (app.moveMixerChannel(ch, 1)) app.commitHistory("通道下移");
                },
                else => {},
            }
        } else if (slot) |sl| {
            // 效果器菜单：[更换效果器…] [重新定位插件…?] 删除 / 上移 / 下移
            const base: usize = 1 + (if (has_relocate) @as(usize, 1) else 0);
            if (ci == 0) {
                app.openPresetBrowser(.{ .replace_effect = .{ .ch = ch, .slot = sl } });
            } else if (has_relocate and ci == 1) {
                app.pending_relocate_effect = .{ .ch = ch, .slot = sl };
            } else switch (ci - base) {
                0 => {
                    if (ch < app.mixer_channels_state.items.len and sl < app.mixer_channels_state.items[ch].effects.items.len) {
                        if (app.mixer_win.panel) |p| {
                            if (p.ch == ch and p.slot == sl) app.mixer_win.panel = null;
                        }
                        app.removeEffect(ch, sl);
                        app.commitHistory("删除效果器");
                    }
                },
                1 => {
                    if (app.moveEffect(ch, sl, -1)) app.commitHistory("效果器上移");
                },
                2 => {
                    if (app.moveEffect(ch, sl, 1)) app.commitHistory("效果器下移");
                },
                else => {},
            }
        }
        mw_win.ctx_effect = null;
        mw_win.ctx_channel = null;
        mw_win.ctx_menu_x = 0;
        mw_win.ctx_menu_y = 0;
    } else if (ui.mouse_pressed and !inside) {
        mw_win.ctx_effect = null;
        mw_win.ctx_channel = null;
        mw_win.ctx_menu_x = 0;
        mw_win.ctx_menu_y = 0;
    }
}

/// 声像旋钮右键菜单（单项：恢复默认值 = 居中 0.5）。
/// 与通用菜单同一套路：位置鉗制到窗口内（`ctxMenuPos`）、点外关闭。
fn drawPanCtxMenu(ui: *Ui, app: *App, ch: usize) void {
    const mw_win = &app.mixer_win;
    const menu_w: i32 = 130;
    const menu_h: i32 = util.menu_item_h + 4;
    const pos = ctxMenuPos(mw_win, menu_w, menu_h);
    const mx = pos[0];
    const my = pos[1];
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h); // 遮挡插件子窗口

    const item = "恢复默认值";
    const iy = my + 2;
    const hovered = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
    if (hovered) ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
    ui.label(item, mx + 8, iy + 2, ui.theme.text);
    if (hovered and ui.mouse_pressed) {
        if (ch < app.mixer_channels_state.items.len) {
            const mc = &app.mixer_channels_state.items[ch];
            if (mc.pan != 0.5) {
                mc.pan = 0.5; // 居中
                app.commitHistory("恢复通道声像");
            }
        }
        mw_win.ctx_pan = null;
    } else if (ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, mx, my, menu_w, menu_h)) {
        mw_win.ctx_pan = null;
    }
}

// ── 测试 ──

test "view_mixer: 控件 id 段——不与其它视图撞车且互不重叠" {
    // 实测 bug：声像 7200+ci 与钢琴卷帘 PAT 标尺 7200 撞车——点主通道
    // 声像旋钮会跳播放游标、点标尺会改声像（7300/7500 两个控件同理）。
    // 本窗口控件统一占 **8100-8711 独占段**（分配表见 ui.zig `active_id`）。
    const pan_lo = id_pan_base;
    const pan_hi = id_pan_base + 31;
    const vol_lo = id_vol_base;
    const vol_hi = id_vol_base + 31;
    const fx_lo = id_fx_mix_base;
    const fx_hi = id_fx_mix_base + 31 * 16 + 15;

    // ① 全在独占段内（避开其它视图：7100-7501 / 7600-7810 / 5000-5499…）
    try std.testing.expect(pan_lo >= 8100);
    try std.testing.expect(fx_hi <= 8711);

    // ② 三个子段互不重叠
    try std.testing.expect(pan_hi < vol_lo);
    try std.testing.expect(vol_hi < fx_lo);

    // ③ 不落回曾经的撞车 id（回归：7200/7300/7500 均不得再出现）
    const banned = [_]u64{ 7200, 7300, 7500, 7501 };
    for (banned) |bad| {
        try std.testing.expect(bad < pan_lo or bad > fx_hi);
    }
}

test "view_mixer: 右键菜单坐标——钳制到窗口内（防超出部分点击穿透）" {
    var mw = app_mod.MixerWindow{ .x = 100, .y = 100, .w = 400, .h = 300 };
    const menu_w: i32 = 130;
    const menu_h: i32 = 100;

    // 鼠标在窗口中部 → 原位弹出
    mw.ctx_menu_x = 200;
    mw.ctx_menu_y = 200;
    {
        const pos = ctxMenuPos(&mw, menu_w, menu_h);
        try std.testing.expectEqual(@as(i32, 200), pos[0]);
        try std.testing.expectEqual(@as(i32, 200), pos[1]);
    }

    // 鼠标在右下角（窗口外）→ 钳到"右下角 − 菜单尺寸"
    mw.ctx_menu_x = 460;
    mw.ctx_menu_y = 380;
    {
        const pos = ctxMenuPos(&mw, menu_w, menu_h);
        try std.testing.expectEqual(@as(i32, 100 + 400 - menu_w), pos[0]);
        try std.testing.expectEqual(@as(i32, 100 + 300 - menu_h), pos[1]);
    }

    // 鼠标在左上角（窗口外）→ 钳到窗口原点
    mw.ctx_menu_x = 20;
    mw.ctx_menu_y = 30;
    {
        const pos = ctxMenuPos(&mw, menu_w, menu_h);
        try std.testing.expectEqual(@as(i32, 100), pos[0]);
        try std.testing.expectEqual(@as(i32, 100), pos[1]);
    }

    // 极端：菜单比窗口还大（当前窗口最小 544×240 不会出现；钳制不能反向翻车）
    {
        const pos = ctxMenuPos(&mw, 999, 999);
        try std.testing.expectEqual(@as(i32, 100), pos[0]); // max_x < min → 退回窗口原点
        try std.testing.expectEqual(@as(i32, 100), pos[1]);
    }
}
