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

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const mw = &app.mixer_win;
    if (!mw.open) return false;
    // 帧首：清“刚打开”标记（共享下拉控件；必须逐帧做，否则“点外部关闭”永久失效）
    util.menuFrameBegin(&mw.menu_just_opened);

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
        mw.add_effect_ch = null;
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
            drawStrip(ui, app, @intCast(ci), left_x + ruler_w + strip_pad_l, ry, left_w - ruler_w - strip_pad_l - strip_pad_r, row_h);
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
    // 底部固定：“+ 添加通道”
    {
        const by = btn_y;
        // 水平位置与通道条**完全对齐**（含左右留白）
        const bx = left_x + ruler_w + strip_pad_l;
        const bw = left_w - ruler_w - strip_pad_l - strip_pad_r;
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
                app.setToast("通道已达上限");
            }
        }
    }

    // ── 右区：选中通道的效果器链 ──
    const sel_ch: usize = if (mw.selected_channel >= 0 and mw.selected_channel < n_ch) @intCast(mw.selected_channel) else 0;
    drawEffectPanel(ui, app, sel_ch, right_x, right_y, right_w, right_h);

    // ── 添加效果器下拉（全窗口最上层）──
    if (mw.add_effect_ch) |ech| {
        drawAddEffectMenu(ui, app, ech, x, y, ww, hh);
    }
    // ── 效果器右键菜单 ──
    if (mw.ctx_effect) |ctx| {
        drawCtxMenu(ui, app, ctx);
    }
    // ── 通道右键菜单（重命名/删除/上移/下移）──
    if (mw.ctx_channel) |cc| {
        const items = [_][]const u8{ "重命名", "删除通道", "上移", "下移" };
        drawCtxMenuGeneric(ui, app, cc, null, &items);
    }

    return true;
}

/// 横向通道条：`[M][S]` · 声像旋钮 · 通道名（定宽）· 音量推子 · 数值。
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
    var cx = x + 5;

    // [M] 静音
    {
        const my = y + @divTrunc(h - mute_size, 2);
        const hovered = util.hitUI(ui, cx, my, mute_size, mute_size);
        ui.renderer.fillRect(cx, my, mute_size, mute_size, if (mc.muted) ui.theme.mute_on else ui.theme.slider_track);
        ui.renderer.strokeRect(cx, my, mute_size, mute_size, ui.theme.panel_border);
        ui.label("M", cx + 4, my + 2, if (mc.muted) ui.theme.text else ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) {
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
        if (ui.knob(7200 + @as(u64, ci), &pan, cx, ky, knob_size)) {
            mc.pan = pan;
            app.history_pending = "调整通道声像";
            consumed = true;
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
        if (ui.slider(7300 + @as(u64, ci), &vol, cx, sy, slider_w, 18)) {
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
    // 右键 → 通道菜单（删除/上移/下移）
    if (util.hitUI(ui, x, y, w, h) and ui.mouse_right_pressed) {
        app.mixer_win.selected_channel = @intCast(ci);
        app.mixer_win.ctx_channel = ci;
        app.mixer_win.ctx_effect = null;
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
        var inst_names: []const u8 = "";
        var first: ?[]const u8 = null;
        var total: usize = 0;
        for (app.instruments.items) |inst2| {
            if (inst2.mixer != @as(i32, @intCast(ci))) continue;
            if (total == 0) first = inst2.name;
            total += 1;
        }
        if (first) |fname| {
            inst_names = if (total == 1)
                fname
            else
                std.fmt.bufPrint(&inst_names_buf, "{s} +{d}", .{ fname, total - 1 }) catch fname;
        }
        const title = std.fmt.bufPrint(&buf, "CH {d}{s}{s}", .{
            ci + 1,
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

    // 底部：「+ 效果器」/「链已满」
    {
        const full = mc.effects.items.len >= app_mod.max_effects_per_channel;
        const by = y + h - add_h - pad_inner - 1;
        const label: []const u8 = if (full) "链已达上限" else "+ 效果器";
        const hovered = util.hitUI(ui, x + pad_inner, by, w - pad_inner * 2, add_h);
        ui.renderer.fillRect(x + pad_inner, by, w - pad_inner * 2, add_h, if (hovered and !full) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(x + pad_inner, by, w - pad_inner * 2, add_h, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure(label));
        ui.label(label, x + @divTrunc(w - tw, 2), by + 3, if (full) ui.theme.text_dim else ui.theme.text);
        if (hovered and ui.mouse_pressed and !full) {
            app.mixer_win.menu_open = true;
            app.mixer_win.menu_just_opened = true;
            app.mixer_win.add_effect_ch = ci;
            app.mixer_win.ctx_effect = null;
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

    // 名字（点击 = 打开独立面板）
    const name_x = x + 3 + sw + 6;
    const name_avail = w - (name_x - x) - (fx_knob + 22);
    const name_hovered = util.hitUI(ui, name_x, y, @max(1, name_avail), h);
    const open_now = if (app.mixer_win.panel) |p| p.ch == ci and p.slot == si else false;
    ui.labelClipped(es.kind.displayName(), name_x, y + 4, @max(1, name_avail), if (name_hovered or open_now) ui.theme.accent else if (es.enabled) ui.theme.text else ui.theme.text_dim);
    if (name_hovered and ui.mouse_pressed) {
        app.mixer_win.panel = .{ .ch = ci, .slot = si };
        app.mixer_win.menu_open = false;
        app.mixer_win.add_effect_ch = null;
        app.mixer_win.ctx_effect = null;
    }
    // 右键 → 删除菜单
    if (name_hovered and ui.mouse_right_pressed) {
        app.mixer_win.ctx_effect = .{ .ch = ci, .slot = si };
        app.mixer_win.ctx_channel = null;
        app.mixer_win.ctx_menu_x = ui.mouse_x;
        app.mixer_win.ctx_menu_y = ui.mouse_y;
        app.mixer_win.menu_open = false;
        app.mixer_win.add_effect_ch = null;
    }

    // 干湿旋钮（右侧）
    {
        const kx = x + w - fx_knob - 6;
        const ky = y + @divTrunc(h - fx_knob, 2);
        var mix = es.mix;
        if (ui.knob(7500 + @as(u64, ci) * 16 + @as(u64, si), &mix, kx, ky, fx_knob)) {
            es.mix = mix;
            app.history_pending = "调整效果器音量";
        }
    }
}

/// 「添加效果器」下拉（**共享控件** view_util.menuPanel）：选类型 → 填入该通道第一个空槽。
fn drawAddEffectMenu(ui: *Ui, app: *App, ci: usize, wx: i32, wy: i32, ww: i32, hh: i32) void {
    const mw = &app.mixer_win;
    const items = [_][]const u8{"EQ 参量均衡"};
    const clicked = util.menuPanel(
        ui,
        &mw.menu_x,
        &mw.menu_y,
        &mw.menu_open,
        mw.menu_just_opened,
        .cursor,
        .{ .x = wx, .y = wy, .w = ww, .h = hh },
        &items,
        170,
        null,
    );
    if (clicked != null) {
        // 追加到该通道的效果链末尾
        _ = app.addEffect(ci, .eq);
        const chain = app.mixer_channels_state.items[ci].effects;
        if (chain.items.len > 0) {
            app.mixer_win.panel = .{ .ch = ci, .slot = chain.items.len - 1 };
        }
        app.mixer_win.add_effect_ch = null;
        app.commitHistory("添加效果器");
    }
    // 菜单关闭（点外部/点条目）→ 同步清“所属通道”
    if (!mw.menu_open) app.mixer_win.add_effect_ch = null;
}

/// 效果器右键菜单（位置在**打开时快照**——不跟鼠标跑，否则永远点不到）
fn drawCtxMenu(ui: *Ui, app: *App, ctx: app_mod.EffectRef) void {
    const items = [_][]const u8{ "删除效果器", "上移", "下移" };
    drawCtxMenuGeneric(ui, app, ctx.ch, ctx.slot, &items);
}

/// 通用右键菜单（效果器/通道共用）：位置由**打开时快照**提供。
/// `slot` 为 `null` 时是**通道菜单**。
fn drawCtxMenuGeneric(ui: *Ui, app: *App, ch: usize, slot: ?usize, items: []const []const u8) void {
    const mw_win = &app.mixer_win;
    const mx = mw_win.ctx_menu_x;
    const my = mw_win.ctx_menu_y;
    const menu_w: i32 = 130;
    const menu_h: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);

    var clicked: ?usize = null;
    var inside = false;
    for (items, 0..) |item, i| {
        const iy = my + 2 + @as(i32, @intCast(i)) * util.menu_item_h;
        const ih = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (ih) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, ui.theme.text);
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
            // 效果器菜单：删除效果器 / 上移 / 下移
            switch (ci) {
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
