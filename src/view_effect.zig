//! 效果器独立面板（浮动窗口）：像合成器编辑器那样可拖动/缩放。
//!
//! 当前只有 EQ：**大尺寸频谱背景 + 包络曲线 + 4 个可拖控制点**（横 = 频率、
//! 纵 = 增益）、4 段的频率/增益数值、Q 推子。
//! **面板里没有开关/干湿**——那两项是**调音台效果链行**的职责（`view_mixer.drawEffectRow`：
//! 左侧旁通小方块 + 右侧干湿旋钮，同一份数据）；面板只管“这个效果长什么样/参数怎么调”。
//! 插件参数自动化统一从标题栏 `自动化` 进（那个窗口就是完整参数表 + 搜索，
//! 软参数列表仅在**没有自带 GUI** 的插件正文里出现）。

const std = @import("std");
const builtin = @import("builtin");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const eq = @import("eq.zig");
const fx = @import("effects.zig");
const util = @import("view_util.zig");
const view_vst_auto = @import("view_vst_auto.zig");
const model = @import("model.zig");

const win_title_h: i32 = 22;
const win_min_w: i32 = 460;
const win_min_h: i32 = 300;
const band_row_h: i32 = 22;

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const panel = app.mixer_win.panel orelse return false;
    // 面板目标有效？（通道/槽位范围 + 链上有效）
    if (panel.ch >= app.mixer_channels_state.items.len) return false;
    const mc = &app.mixer_channels_state.items[panel.ch];
    if (panel.slot >= mc.effects.items.len) return false;
    const es = &mc.effects.items[panel.slot];

    const ew = &app.effect_win;
    // 嵌入预期（插件有界面）：尺寸固定=插件尺寸，松约束；无界面 → 列表常规最小尺寸
    const embedded_expected = es.kind == .plugin and es.plugin != null and !es.plugin.?.editor_no_ui;
    const min_w: i32 = if (embedded_expected) 80 else win_min_w;
    const min_h: i32 = if (embedded_expected) 80 else win_min_h;
    ew.w = std.math.clamp(ew.w, min_w, @max(min_w, w - 20));
    ew.h = std.math.clamp(ew.h, min_h, @max(min_h, h - 20));
    ew.x = std.math.clamp(ew.x, 0, @max(0, w - ew.w));
    ew.y = std.math.clamp(ew.y, 0, @max(0, h - ew.h));

    const x = ew.x;
    const y = ew.y;
    const ww = ew.w;
    const hh = ew.h;

    // 标题文本（动态：效果器 — 通道号 + 路由乐器名；外壳负责画标题栏与文字）
    var tbuf: [96]u8 = undefined;
    var inst_names_buf: [64]u8 = undefined;
    // 路由到此通道的乐器名摘要（**0 起基准**——见 `model.routedInstrumentNames`；
    // 曾经误用 `mixer == ch + 1`，显示成下一个通道的乐器）
    const inst_names = model.routedInstrumentNames(app.instruments.items, panel.ch, &inst_names_buf);
    const title = std.fmt.bufPrint(&tbuf, "{s} — CH {d}{s}{s}", .{
        es.kind.displayName(),
        panel.ch, // 与调音台标尺/默认通道名同一编号（0 起；曾误用 +1）
        if (inst_names.len > 0) " · " else "",
        inst_names,
    }) catch "效果器";

    // ── 窗口外壳（共享 `util.windowChrome`；右侧动作条宽度/折叠由 `util.planChrome` 算；
    //    嵌入模式：面板尺寸跟随插件，不提供手动缩放）──
    // `自动化`：与乐器窗一致——**只有 VST3 插件槽**才画（内置效果器没有插件参数）；
    // Linux 面板正文已经嵌了参数表 → 不再画标题按钮（否则同一个表两个入口）。
    const show_auto_btn = es.kind == .plugin and builtin.os.tag != .linux;
    const plan = util.planChrome(ui, ew.x, ew.y, ew.w, win_title_h, title, .{
        .auto = show_auto_btn,
        .preset = es.kind != .empty,
        .save = es.kind != .empty,
    });
    if (util.windowChrome(ui, 7600, 7601, title, win_title_h, plan.reserve, &ew.x, &ew.y, &ew.w, &ew.h, &ew.grab_dx, &ew.grab_dy, &ew.resize_w0, &ew.resize_h0, &ew.resize_mx, &ew.resize_my, !embedded_expected)) {
        app.mixer_win.panel = null;
        ew.eq_drag = null;
        app.chrome_menu = null;
        return true;
    }
    // 拖出主窗口时**当场钳制**（顶部 clamp 下帧才生效——期间子窗口会跟着
    // 鼠标跑出面板/主窗口，用户实测“插件 UI 跑出去”；外壳只做纯赋值）
    ew.x = std.math.clamp(ew.x, 0, @max(0, w - ww));
    ew.y = std.math.clamp(ew.y, 0, @max(0, h - hh));

    // 动作按钮 / 折叠 `▾`
    var opened_now: ?util.Rect = null; // 本帧刚点开 `▾`
    {
        var clicked: ?struct { act: util.ChromeAct, r: util.Rect } = null;
        for (plan.btns[0..plan.n]) |b| {
            const active = b.act == .preset and app.preset_browser.open;
            if (util.chromeButton(ui, b, active)) clicked = .{ .act = b.act, .r = b.r };
        }
        if (plan.arrow) |r| {
            const menu_open = if (app.chrome_menu) |cm| cm.panel == .effect else false;
            if (util.chromeArrowButton(ui, r, menu_open)) {
                if (menu_open) {
                    app.chrome_menu = null;
                } else {
                    app.chrome_menu = .{ .panel = .effect, .x = r.x, .y = r.y + r.h };
                    opened_now = r;
                }
                ui.active_id = 0; // 防误触发标题拖动
            } else if (menu_open) {
                app.chrome_menu.?.x = r.x; // 跟着面板走（菜单不掉队）
                app.chrome_menu.?.y = r.y + r.h;
            }
        }
        if (clicked) |c| {
            runChromeAction(app, panel, c.act, c.r);
            ui.active_id = 0; // 防误触发标题拖动（同一位置按下）
        }
    }

    const cy = y + win_title_h + 6;

    // ── 主区：EQ = 频谱图 + 频段控制；其它效果器 = 参数旋钮面板 ──
    if (es.kind == .eq) {
        const info_w: i32 = 170;
        const gx = x + 10;
        const gw = ww - 20 - info_w - 10;
        const gh = hh - (cy - y) - 14;
        if (gw > 120 and gh > 80) {
            drawEqGraph(ui, app, es, gx, cy, gw, gh);

            // 右侧：4 段数值 + Q 旋钮（**旋钮代替推子**——推子与文字重叠，实测反馈）
            const ix = gx + gw + 10;
            var iy = cy;
            ui.label("频段 / Q", ix, iy, ui.theme.text_dim);
            iy += 16;
            const q_knob: i32 = 20;
            for (es.bands, 0..) |band, bi| {
                var fb: [64]u8 = undefined;
                // 增益带符号显示（“+3.5dB” / “-6.0dB”）——Zig 格式串不支持 `+` 标志，手动拼
                const ft = std.fmt.bufPrint(&fb, "{d}  {d:.2}kHz  {s}{d:.1}dB", .{
                    bi + 1,
                    band.freq / 1000,
                    if (band.gain_db >= 0) "+" else "",
                    band.gain_db,
                }) catch "";
                // 文字在左（宽 = 剩余 − 旋钮），旋钮在右（右对齐，不重叠）
                const text_w = info_w - q_knob - 10;
                ui.labelClipped(ft, ix, iy + 4, text_w, ui.theme.text);
                var q = band.q;
                if (ui.knobRange(7700 + @as(u64, bi), &q, ix + info_w - q_knob, iy, q_knob, 0.1, 4.0)) {
                    es.bands[bi].q = q;
                    app.history_pending = "调整 EQ Q 值";
                }
                iy += @max(band_row_h, q_knob + 6);
            }
        }
    } else if (es.kind != .empty) {
        // 混响/延迟/压缩器：纵列参数旋钮（含义/范围见 `effects.paramInfos`）
        drawParamPanel(ui, app, es, x + 10, cy, ww - 20, hh - (cy - y) - 14);
    }

    // 折叠菜单（`▾`）——必须在内容**之后**画（盖住面板正文）；
    // `menuPanel` 会登记 `ui.overlay_rects` → 插件子窗口被裁掉/禁用 → 点击不穿透。
    drawChromeMenu(ui, app, plan.acts[0..plan.n], plan.arrow != null, opened_now);

    return true;
}

/// 标题栏动作的实际行为（**按钮与折叠菜单共用**）。`r` = 触发控件的矩形
/// （“保存为…”的输入框锚在它左下）。
fn runChromeAction(app: *App, panel: app_mod.EffectRef, act: util.ChromeAct, r: util.Rect) void {
    switch (act) {
        .auto => app.openVstAutoWin(.{ .kind = .fx, .a = @intCast(panel.ch), .b = @intCast(panel.slot) }),
        .preset => {
            if (app.preset_browser.open) {
                app.preset_browser.open = false;
            } else {
                app.openPresetBrowser(.{ .replace_effect = .{ .ch = panel.ch, .slot = panel.slot } });
            }
        },
        .save => {
            const save_src = app_mod.PresetSaveSource{ .effect = .{ .ch = panel.ch, .slot = panel.slot } };
            app.beginRenamePreset(r.x - 60, r.y + r.h + 2, save_src, app.presetPrefillName(save_src));
            app.preset_browser.open = false;
        },
    }
}

/// 画折叠菜单（仅当 `▾` 处于折叠态且菜单属于本面板）。
/// `opened_by` = 本帧刚点开 `▾` 时的按钮矩形——**必须**传下去，
/// 否则菜单会在打开那一帧被“点外部关闭”立刻关掉（实测 bug）。
fn drawChromeMenu(ui: *Ui, app: *App, acts: []const util.ChromeAct, collapsed: bool, opened_by: ?util.Rect) void {
    if (!collapsed) {
        // 面板变宽→又摆得下三个按钮了：清掉可能残留的菜单状态
        if (app.chrome_menu) |cm| {
            if (cm.panel == .effect) app.chrome_menu = null;
        }
        return;
    }
    const cm = if (app.chrome_menu) |*c| (if (c.panel == .effect) c else null) else null;
    const p = cm orelse return;
    const panel = app.mixer_win.panel orelse return;
    var open = true;
    const bounds = util.Rect{ .x = 0, .y = 0, .w = ui.renderer.logicalWidth(), .h = ui.renderer.logicalHeight() };
    const picked = util.chromeMenuPanel(ui, &p.x, &p.y, &open, acts, bounds, opened_by);
    if (open) return;
    if (picked) |act| runChromeAction(app, panel, act, .{ .x = p.x + 40, .y = p.y, .w = 0, .h = 0 });
    app.chrome_menu = null;
}

/// 参数面板（混响/延迟/压缩器）：纵列 = 名称 + 旋钮 + 数值
/// 注：干湿（mix）不在此列——它在**调音台效果链行**的旋钮里（同一数据，避免两个入口）
fn drawParamPanel(ui: *Ui, app: *App, es: *app_mod.EffectSlot, px: i32, py: i32, pw: i32, ph: i32) void {
    if (es.kind == .plugin) {
        // Windows：编辑器嵌在内容区（原生子窗口覆盖）→ 不画软层；
        // Linux：编辑器是独立顶层窗口 → 正文画 UI 开关 + 参数表（两平台共用同一个表）
        if (comptime builtin.os.tag != .linux) {
            if (es.plugin) |p| {
                if (p.view != null) return;
            }
        }
        const pl = es.plugin;
        var yy = py + 4;
        // 插件 UI 开关（Linux「独立顶层窗口」/ Windows「嵌入面板」；无界面插件 / 未加载 → 不占高度）
        if (pl) |p| yy += util.pluginUiToggle(ui, app, p, 7901, px, yy, pw);
        // ── 头部：名称；路径 · 延迟 ──
        {
            const name_t = if (pl) |p| p.name() else "（未加载）";
            ui.labelClipped(name_t, px + 8, yy, pw - 16, if (es.load_failed) ui.theme.danger else ui.theme.text);
        }
        yy += 24;
        {
            var lb: [48]u8 = undefined;
            const lat_t = if (pl) |p| (std.fmt.bufPrint(&lb, " · 延迟 {d}", .{p.latency}) catch "") else "";
            var pb: [600]u8 = undefined;
            const path_t = std.fmt.bufPrint(&pb, "{s}{s}", .{ std.fs.path.basename(es.pluginPath()), lat_t }) catch "";
            ui.labelClipped(path_t, px + 8, yy, pw - 16, ui.theme.text_dim);
        }
        yy += 18;

        const ref: app_mod.PluginSlotRef = if (app.mixer_win.panel) |pref|
            .{ .kind = .fx, .a = @intCast(pref.ch), .b = @intCast(pref.slot) }
        else
            .{ .kind = .fx };
        // 参数表：**与乐器面板 / 浮动窗口同一份**（`drawBody`），不再有第二套列表实现
        view_vst_auto.drawBody(ui, app, ref, px, yy, pw, py + ph - yy, .fx_panel);
        return;
    }
    const infos = fx.paramInfos(@backingInt(es.kind));
    if (infos.len == 0 or pw < 200 or ph < 60) return;
    const knob: i32 = 40;
    const row_h: i32 = knob + 18;
    const knob_x = px + 96;
    var yy = py + 6;
    for (infos, 0..) |info, i| {
        if (std.mem.eql(u8, info.name, "mix")) continue; // 干湿在顶部控制行
        if (yy + row_h > py + ph) break; // 空间不足：剩下的行不画（拉大窗口可见）
        // 延迟「节奏」= 拖动换档（同工具栏拍号的手感）；旁注 BPM 换算后的实际毫秒
        if (es.kind == .delay and i == 0) {
            ui.label(info.name, px + 8, yy + @divTrunc(knob, 2) - 6, ui.theme.text_dim);
            const max_code: i32 = @intCast(fx.delay_tempos.len - 1);
            var code: i32 = @intFromFloat(@round(std.math.clamp(es.p[i], 0, @as(f32, @floatFromInt(fx.delay_tempos.len - 1)))));
            if (ui.dragNumberEx(9000, knob_x, yy + @divTrunc(knob - 20, 2), 56, 20, &code, 0, max_code, 12, 0, &fmtDelayTempo)) {
                es.p[i] = @floatFromInt(code);
                app.history_pending = "调整延迟节奏";
            }
            var mb: [24]u8 = undefined;
            const bpm_c: f32 = @max(model.bpm_min, app.bpm);
            const ms = fx.delay_tempos[@intCast(code)].beats * 60000.0 / bpm_c;
            ui.label(std.fmt.bufPrint(&mb, "{d:.0}ms", .{ms}) catch "", knob_x + 68, yy + @divTrunc(knob, 2) - 6, ui.theme.text);
            yy += row_h;
            continue;
        }
        ui.label(info.name, px + 8, yy + @divTrunc(knob, 2) - 6, ui.theme.text_dim);
        var v = es.p[i];
        if (ui.knobRange(9000 + @as(u64, i), &v, knob_x, yy, knob, info.min, info.max)) {
            es.p[i] = v;
            app.history_pending = "调整效果器参数";
        }
        var vb: [32]u8 = undefined;
        const vt: []const u8 = if (std.mem.eql(u8, info.unit, ":1"))
            (std.fmt.bufPrint(&vb, "{d:.1}:1", .{es.p[i]}) catch "")
        else if (info.unit.len > 0)
            (std.fmt.bufPrint(&vb, "{d:.1}{s}", .{ es.p[i], info.unit }) catch "")
        else
            (std.fmt.bufPrint(&vb, "{d:.0}%", .{es.p[i] * 100}) catch "");
        ui.label(vt, knob_x + knob + 12, yy + @divTrunc(knob, 2) - 6, ui.theme.text);
        yy += row_h;
    }
}

/// 延迟节奏档位码 → 文本（"1/8" 等；`dragNumberEx` 的 fmt 回调）
fn fmtDelayTempo(v: i32, buf: []u8) []const u8 {
    const c = std.math.clamp(v, 0, @as(i32, @intCast(fx.delay_tempos.len)) - 1);
    return std.fmt.bufPrint(buf, "{s}", .{fx.delay_tempos[@intCast(c)].label}) catch "?";
}

/// EQ 主图：频谱背景 + 包络曲线 + 控制点（大尺寸版）
fn drawEqGraph(ui: *Ui, app: *App, es: *app_mod.EffectSlot, gx: i32, gy: i32, gw: i32, gh: i32) void {
    ui.renderer.fillRect(gx, gy, gw, gh, ui.theme.bg);
    ui.renderer.strokeRect(gx, gy, gw, gh, ui.theme.panel_border);

    // 频谱背景（**该效果器的输入信号**；对数对齐）
    const bar_w_f = @as(f32, @floatFromInt(gw)) / @as(f32, @floatFromInt(eq.spec_bars));
    for (0..eq.spec_bars) |bi| {
        const b = app.params.spec_bars[bi].load(.monotonic);
        const bx = gx + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bi)) * bar_w_f));
        const bw = @max(1, @as(i32, @intFromFloat(bar_w_f)) - 1);
        const bh = @as(i32, @intFromFloat(b * @as(f32, @floatFromInt(gh - 2))));
        if (bh > 0) ui.renderer.fillRect(bx, gy + gh - 1 - bh, bw, bh, 0x3050B0A0);
    }

    // 频率刻度（对数；1k/10k 标线）
    {
        const marks = [_]f32{ 100, 1000, 10000 };
        for (marks) |fm| {
            const kx = freqToX(fm, gw);
            ui.renderer.vline(gx + kx, gy, gh, ui.theme.grid);
            var mb: [16]u8 = undefined;
            const mt = std.fmt.bufPrint(&mb, "{d:.0}", .{fm}) catch "";
            ui.label(mt, gx + kx + 3, gy + 2, ui.theme.text_dim);
        }
    }
    // 0dB 中线
    const mid_y = gy + @divTrunc(gh, 2);
    ui.renderer.hline(gx, mid_y, gw, ui.theme.panel_border);

    // 包络曲线（解析响应）
    const sr: f32 = @floatFromInt(app.params.sample_rate);
    var px: i32 = 0;
    var prev_y: i32 = mid_y;
    while (px <= gw - 1) : (px += 1) {
        const k = @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(gw - 1));
        const f = eq.spec_f_min * std.math.pow(f32, eq.spec_f_max / eq.spec_f_min, k);
        const db = eq.responseDb(&es.bands, sr, f);
        const ny = dbToY(db, gy, gh);
        if (px == 0) {
            prev_y = ny;
        } else {
            // 竖向连接两采样点（避免 1px 宽线在陡峭处断裂）
            const y0 = @min(prev_y, ny);
            const y1 = @max(prev_y, ny);
            ui.renderer.vline(gx + px, y0, y1 - y0 + 1, ui.theme.accent);
            prev_y = ny;
        }
    }

    // 控制点（4 个）
    var wheel_used = false; // 本帧滚轮已被某个控制点消费（防重叠时多次生效）
    for (es.bands, 0..) |band, bi| {
        const point_x = gx + freqToX(band.freq, gw);
        const point_y = dbToY(band.gain_db, gy, gh);
        const hovered = util.hitUI(ui, point_x - 7, point_y - 7, 14, 14);
        const dragging = if (app.effect_win.eq_drag) |d| d == bi else false;
        const col = if (dragging or hovered) ui.theme.note_selected else ui.theme.text;
        var lb: [8]u8 = undefined;
        const lt = std.fmt.bufPrint(&lb, "{d}", .{bi + 1}) catch "";
        ui.renderer.fillRect(point_x - 5, point_y - 5, 10, 10, col);
        ui.renderer.strokeRect(point_x - 5, point_y - 5, 10, 10, r_mod.rgb(20, 22, 26));
        ui.label(lt, point_x - 3, point_y - 6, r_mod.rgb(20, 22, 26));

        if (hovered and ui.mouse_pressed) {
            app.effect_win.eq_drag = bi;
            // 控制点用**独立 id 段**（7800+）——曾误用 7700，
            // 与第 0 段的 Q 旋钮（id 7700）撞车：拖控制点时第 0 段 Q 被同步误改
            ui.active_id = 7800 + @as(u64, bi);
        }
        // **悬停 + 滚轮 = 调该点的 Q**（尖锐度）；上滚增大、下滚减小。
        // 每帧只响应一次（`wheel_used`——两点重叠时 hover 都成立，会重复改）
        if (hovered and ui.wheel != 0 and !wheel_used) {
            wheel_used = true;
            const dq: f32 = @as(f32, @floatFromInt(ui.wheel)) * 0.2;
            const nq = std.math.clamp(es.bands[bi].q + dq, 0.1, 4.0);
            if (nq != es.bands[bi].q) {
                es.bands[bi].q = nq;
                // **滚轮类 coalesce**：连续滚动只记最后一条（静默 0.6s 后提交）——
                // 否则每次滚动都产生一条历史（实测：操作历史刷屏）
                app.touchGesture("调整 EQ Q 值");
            }
            // **消费滚轮**：面板浮在混音台上，不置 0 会让下层（通道条/效果链滚动）也跟着动
            ui.wheel = 0;
        }
    }

    // 拖动（横 = 频率、纵 = 增益）——以 `eq_drag` 为准（不再看 active_id，避免与旋钮 id 耦合）
    if (app.effect_win.eq_drag) |bi| {
        if (bi < eq.band_count) {
            if (!ui.mouse_down) {
                app.effect_win.eq_drag = null;
                app.history_pending = "调整 EQ";
                // 清残留的 active_id（7800+bi）
                if (ui.active_id >= 7800 and ui.active_id < 7800 + eq.band_count) ui.active_id = 0;
            } else {
                const lx = std.math.clamp(ui.mouse_x - gx, 0, gw - 1);
                const ly = std.math.clamp(ui.mouse_y - gy, 0, gh - 1);
                const k = @as(f32, @floatFromInt(lx)) / @as(f32, @floatFromInt(gw - 1));
                var f = eq.spec_f_min * std.math.pow(f32, eq.spec_f_max / eq.spec_f_min, k);
                f = std.math.clamp(f, 30, 18000);
                const db = std.math.clamp((0.5 - @as(f32, @floatFromInt(ly)) / @as(f32, @floatFromInt(gh))) * 2 * eq.gain_db_max, eq.gain_db_min, eq.gain_db_max);
                es.bands[bi].freq = f;
                es.bands[bi].gain_db = db;
            }
        }
    }

    // **图区内的滚轮不穿透到下层窗口**（面板浮在混音台上）——放在最后：
    // 控制点自己要先有机会消费滚轮（调 Q）
    if (util.hitUI(ui, gx, gy, gw, gh)) ui.wheel = 0;
}

/// 频率 → 图内 x（对数）
fn freqToX(freq: f32, gw: i32) i32 {
    const k = std.math.log(f32, eq.spec_f_max / eq.spec_f_min, std.math.clamp(freq, eq.spec_f_min, eq.spec_f_max) / eq.spec_f_min);
    return @intFromFloat(k * @as(f32, @floatFromInt(gw - 1)));
}

/// 增益 dB → 图内 y（绝对坐标；中心 = 0dB）
fn dbToY(db: f32, gy: i32, gh: i32) i32 {
    const half = @divTrunc(gh, 2) - 2;
    const y = @as(f32, @floatFromInt(gy + @divTrunc(gh, 2))) - db / eq.gain_db_max * @as(f32, @floatFromInt(half));
    return @intFromFloat(std.math.clamp(y, @as(f32, @floatFromInt(gy)), @as(f32, @floatFromInt(gy + gh - 1))));
}
