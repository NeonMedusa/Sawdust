//! 效果器独立面板（浮动窗口）：像合成器编辑器那样可拖动/缩放。
//!
//! 当前只有 EQ：**大尺寸频谱背景 + 包络曲线 + 4 个可拖控制点**（横 = 频率、
//! 纵 = 增益）、4 段的频率/增益数值、Q 推子。
//! 顶部还提供开关（旁通）与干湿比——与调音台里的行控制同步（同一数据）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const eq = @import("eq.zig");
const fx = @import("effects.zig");
const util = @import("view_util.zig");
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

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, win_title_h - 1, ui.theme.toolbar);
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
    ui.label(title, x + 8, y + 4, ui.theme.text);

    // 预设按钮（标题栏右侧）：[预设 ▾][保存为…]——内置单效果与 VST3 效果都支持
    {
        const save_w: i32 = 62;
        const menu_w: i32 = 58;
        const gap: i32 = 6;
        const bx2 = x + ww - 22 - 6 - save_w;
        const bx1 = bx2 - gap - menu_w;
        const bh2: i32 = win_title_h - 6;
        const by2 = y + 3;
        if (bx1 > x + 200 and es.kind != .empty) { // 标题放不下就不画（窄窗）
            const h1 = util.hitUI(ui, bx1, by2, menu_w, bh2);
            ui.renderer.fillRect(bx1, by2, menu_w, bh2, if (app.preset_browser.open) ui.theme.accent else if (h1) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx1, by2, menu_w, bh2, ui.theme.panel_border);
            {
                const tw: i32 = @intFromFloat(ui.font.measure("预设"));
                const arrow_gap: i32 = 4;
                const total = tw + arrow_gap + util.menu_arrow_w;
                const tx = bx1 + @divTrunc(menu_w - total, 2);
                ui.label("预设", tx, by2 + 2, ui.theme.text);
                util.menuArrow(ui, tx + tw + arrow_gap, by2 + @divTrunc(bh2 - util.menu_arrow_h, 2), ui.theme.text);
            }
            if (h1 and ui.mouse_pressed) {
                if (app.preset_browser.open) {
                    app.preset_browser.open = false;
                } else {
                    app.openPresetBrowser(.{ .replace_effect = .{ .ch = panel.ch, .slot = panel.slot } });
                }
                ui.active_id = 0; // 防误触发标题拖动
            }
            const h2 = util.hitUI(ui, bx2, by2, save_w, bh2);
            ui.renderer.fillRect(bx2, by2, save_w, bh2, if (h2) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx2, by2, save_w, bh2, ui.theme.panel_border);
            ui.label("保存为…", bx2 + 4, by2 + 2, ui.theme.text);
            if (h2 and ui.mouse_pressed) {
                const save_src = app_mod.PresetSaveSource{ .effect = .{ .ch = panel.ch, .slot = panel.slot } };
                app.beginRenamePreset(bx2 - 60, y + win_title_h + 4, save_src, app.presetPrefillName(save_src));
                app.preset_browser.open = false;
                ui.active_id = 0;
            }
        }
    }

    // 关闭按钮
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, win_title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, win_title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        app.mixer_win.panel = null;
        ew.eq_drag = null;
        return true;
    }

    // 标题拖动
    // 点窗口内任意处 → 置顶（“点谁谁在上”）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&ew.z);
    }

    if (util.hitUI(ui, x, y, ww - 24, win_title_h) and ui.mouse_pressed) {
        ui.active_id = 7600;
        ew.grab_dx = ui.mouse_x - x;
        ew.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 7600) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            // 拖出主窗口时**当场钳制**（顶部 clamp 下帧才生效——期间子窗口会跟着
            // 鼠标跑出面板/主窗口，用户实测“插件 UI 跑出去”）
            ew.x = std.math.clamp(ui.mouse_x - ew.grab_dx, 0, @max(0, w - ww));
            ew.y = std.math.clamp(ui.mouse_y - ew.grab_dy, 0, @max(0, h - hh));
        }
    }

    // 右下角缩放柄（嵌入模式：面板尺寸跟随插件，不提供手动缩放）
    if (!embedded_expected) {
        const grip = 14;
        const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
        if (grip_hovered) ui.cursor = .resize_h;
        if (grip_hovered and ui.mouse_pressed) {
            ui.active_id = 7601;
            ew.resize_w0 = ww;
            ew.resize_h0 = hh;
            ew.resize_mx = ui.mouse_x;
            ew.resize_my = ui.mouse_y;
        }
        if (ui.active_id == 7601) {
            if (!ui.mouse_down) {
                ui.active_id = 0;
            } else {
                ew.w = ew.resize_w0 + (ui.mouse_x - ew.resize_mx);
                ew.h = ew.resize_h0 + (ui.mouse_y - ew.resize_my);
            }
        }
        ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);
        ui.renderer.line(x + ww - 6, y + hh - 2, x + ww - 2, y + hh - 6, ui.theme.panel_border);
    }

    var cy = y + win_title_h + 6;

    // ── 顶部控制行：开关（左）…… 干湿比（**右对齐独立分组**）──
    // 干湿**不能贴着“启用”**（否则两个控制读成“启用干湿”）；
    // 它是独立的混合参数：0% = 完全旁通（等同关效果）、1 = 完全处理；
    // 对 EQ 而言近似“EQ 强度”（对未来的混响/延迟才是核心参数）。
    {
        const sw: i32 = 16;
        const sw_hovered = util.hitUI(ui, x + 10, cy + 2, sw, sw);
        ui.renderer.fillRect(x + 10, cy + 2, sw, sw, if (es.enabled) ui.theme.accent else ui.theme.slider_track);
        ui.renderer.strokeRect(x + 10, cy + 2, sw, sw, ui.theme.panel_border);
        ui.label("启用", x + 10 + sw + 6, cy + 4, if (es.enabled) ui.theme.text else ui.theme.text_dim);
        if (sw_hovered and ui.mouse_pressed) {
            es.enabled = !es.enabled;
            app.commitHistory("切换效果器开关");
        }

        // 干湿比（横向推子；右对齐到窗口右缘）——VST3 插件暂未接干湿混合（滑块隐藏，避免误导）
        if (es.kind != .plugin) {
            const pct_w: i32 = 44; // 预留 "100%" 文字宽度
            const mix_w: i32 = @min(180, ww - 320);
            if (mix_w > 60) {
                const mix_x = x + ww - 12 - pct_w - 8 - mix_w;
                ui.label("干湿", mix_x - 34, cy + 4, ui.theme.text_dim);
                var mix = es.mix;
                if (ui.slider(7602, &mix, mix_x, cy + 4, mix_w, 14)) {
                    es.mix = mix;
                    app.history_pending = "调整效果器干湿";
                }
                var mb: [16]u8 = undefined;
                const mt = std.fmt.bufPrint(&mb, "{d:.0}%", .{es.mix * 100}) catch "";
                ui.label(mt, mix_x + mix_w + 8, cy + 4, ui.theme.text_dim);
            }
        }
    }
    cy += 28;

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

    return true;
}

/// 参数面板（混响/延迟/压缩器）：纵列 = 名称 + 旋钮 + 数值
/// 注：干湿（mix）不在此列——顶部已有独立干湿滑块（同一参数，避免两个入口）
fn drawParamPanel(ui: *Ui, app: *App, es: *app_mod.EffectSlot, px: i32, py: i32, pw: i32, ph: i32) void {
    // VST3 插件：界面已嵌在内容区（子窗口）时不画软层；否则头部信息 + 参数列表
    if (es.kind == .plugin) {
        if (es.plugin) |p| {
            if (p.view != null) return; // 嵌入中：子窗口覆盖内容区
        }
        const pl = es.plugin;
        // ── 头部：名称；路径 · 延迟（无按钮：插件界面直接嵌在下方）──
        {
            const name_t = if (pl) |p| p.name() else "（未加载）";
            ui.labelClipped(name_t, px + 8, py + 4, pw - 16, if (es.load_failed) ui.theme.danger else ui.theme.text);
        }
        var yy = py + 28;
        {
            var lb: [48]u8 = undefined;
            const lat_t = if (pl) |p| (std.fmt.bufPrint(&lb, " · 延迟 {d}", .{p.latency}) catch "") else "";
            var pb: [600]u8 = undefined;
            const path_t = std.fmt.bufPrint(&pb, "{s}{s}", .{ std.fs.path.basename(es.pluginPath()), lat_t }) catch "";
            ui.labelClipped(path_t, px + 8, yy, pw - 16, ui.theme.text_dim);
        }
        yy += 18;

        // 滚动状态挂在窗口面板引用上（切换效果槽时自动归零）
        var dummy_scroll: i32 = 0;
        const scroll_p: *i32 = if (app.mixer_win.panel) |*pref| &pref.scroll else &dummy_scroll;
        const ref: app_mod.PluginSlotRef = if (app.mixer_win.panel) |pref|
            .{ .kind = .fx, .a = @intCast(pref.ch), .b = @intCast(pref.slot) }
        else
            .{ .kind = .fx };
        util.drawPluginParamList(ui, app, pl, es.load_failed, scroll_p, ref, 7900, px, py, pw, ph, yy);
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
            const bpm_c: i32 = @max(20, app.bpm);
            const ms = fx.delay_tempos[@intCast(code)].beats * 60000.0 / @as(f32, @floatFromInt(bpm_c));
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
