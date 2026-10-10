//! 减法合成器编辑器（浮动窗口）：
//! 4 振荡器（**一行一个**：开关/波形/音量/合奏数量/合奏散布）+
//! ADSR 四旋钮（带时间/电平数值）+ 高/低通滤波。
//!
//! 编辑的是**窗口绑定乐器**的合成器参数（每乐器独立，堆分配、地址稳定）。
//!
//! 合奏概念（调研自 Serum/JP-8000）：每振荡器可叠 N 个副本，
//! `unison` = 副本**总数**（1-16；1 = 单发声源），`unison_detune` = 音高散布 0-100%
//! （0% = 副本同音高只靠相位/立体声加厚；实用档 lead ≈ 20%、
//! supersaw ≈ 50%）。数值控件与 BPM 同款（上下拖动、光标冻结）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const synth = @import("synth.zig");
const util = @import("view_util.zig");

const win_title_h: i32 = 22;
// 振荡器行高（一行一个：容纳旋钮 34 + 上下余量）
const osc_row_h: i32 = 40;
const knob_size: i32 = 34;
// 最小宽度需容纳振荡器一行：开关 + 序号 + 波形 + 旋钮 + 合奏/散布/功率
// （估算：开关 22 + 序号 ≈ 40 + 波形 64 + 旋钮 34 + 三组“标签+数值”≈ 250 + 边距）
const win_min_w: i32 = 500;
const win_min_h: i32 = 380;

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const sw = &app.synth_win;
    if (!sw.open) return false;

    // 约束在屏幕内
    sw.w = std.math.clamp(sw.w, win_min_w, @max(win_min_w, w - 20));
    sw.h = std.math.clamp(sw.h, win_min_h, @max(win_min_h, h - 20));
    sw.x = std.math.clamp(sw.x, 0, @max(0, w - sw.w));
    sw.y = std.math.clamp(sw.y, 0, @max(0, h - sw.h));

    const x = sw.x;
    const y = sw.y;
    const ww = sw.w;
    const hh = sw.h;
    const body_y = y + win_title_h;
    // 编辑当前选中乐器的参数（切换乐器时窗口跟随；无乐器时自动关闭）
    sw.instrument = app.sel.instrument;
    const p = app.selectedSynth() orelse {
        sw.open = false;
        return true;
    };

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, win_title_h - 1, ui.theme.toolbar);
    var tbuf: [64]u8 = undefined;
    const iname: []const u8 = if (sw.instrument >= 0 and sw.instrument < @as(i32, @intCast(app.instruments.items.len)))
        app.instruments.items[@intCast(sw.instrument)].name
    else
        "（无乐器）";
    const title = std.fmt.bufPrint(&tbuf, "减法合成器 — {s}", .{iname}) catch "减法合成器";
    ui.label(title, x + 8, y + 4, ui.theme.text);

    // 关闭按钮
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, win_title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, win_title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        sw.open = false;
        return true;
    }

    // 点窗口内任意处 → 置顶（“点谁谁在上”）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&sw.z);
    }

    // 标题拖动
    if (util.hitUI(ui, x, y, ww - 24, win_title_h) and ui.mouse_pressed) {
        ui.active_id = 5000;
        sw.grab_dx = ui.mouse_x - x;
        sw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 5000) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            sw.x = ui.mouse_x - sw.grab_dx;
            sw.y = ui.mouse_y - sw.grab_dy;
        }
    }

    // 右下角缩放柄
    const grip = 14;
    const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
    if (grip_hovered) ui.cursor = .resize_h;
    if (grip_hovered and ui.mouse_pressed) {
        ui.active_id = 5001;
        sw.resize_w0 = ww;
        sw.resize_h0 = hh;
        sw.resize_mx = ui.mouse_x;
        sw.resize_my = ui.mouse_y;
    }
    if (ui.active_id == 5001) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            sw.w = sw.resize_w0 + (ui.mouse_x - sw.resize_mx);
            sw.h = sw.resize_h0 + (ui.mouse_y - sw.resize_my);
        }
    }
    ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);
    ui.renderer.line(x + ww - 6, y + hh - 2, x + ww - 2, y + hh - 6, ui.theme.panel_border);

    // ── 振荡器区（一行一个）──
    // 一行一个让每个振荡器的合奏控件有完整行宽（2×2 网格放不下两个数值控件）
    var ry = body_y + 6;
    ui.label("振荡器", x + 10, ry, ui.theme.text_dim);
    ry += 18;
    {
        for (0..synth.osc_count) |oi| {
            drawOscRow(ui, app, p, oi, x + 10, ry + @as(i32, @intCast(oi)) * osc_row_h, ww - 20);
        }
        ry += osc_row_h * @as(i32, @intCast(synth.osc_count));
    }

    // ── ADSR 区 ──
    ry += 4;
    ui.renderer.hline(x + 8, ry, ww - 16, ui.theme.panel_border);
    ry += 6;
    ui.label("ADSR", x + 10, ry, ui.theme.text_dim);
    ry += 18;
    {
        const labels = [_][]const u8{ "A", "D", "S", "R" };
        const knobs = [_]*std.atomic.Value(f32){ &p.attack, &p.decay, &p.sustain, &p.release };
        const kw = @divTrunc(ww - 40, 4);
        for (labels, 0..) |lb, ki| {
            const kx = x + 20 + @as(i32, @intCast(ki)) * kw;
            const ky = ry + 4;
            var v = knobs[ki].load(.monotonic);
            if (ui.knob(5100 + @as(u64, ki), &v, kx + @divTrunc(kw - knob_size, 2), ky, knob_size)) {
                knobs[ki].store(v, .monotonic);
                app.history_pending = "调整 ADSR"; // 松手时 coalesce 提交
            }
            ui.label(lb, kx + @divTrunc(kw, 2) - 4, ky + knob_size + 2, ui.theme.text_dim);
            // 数值：A/D/R = 时间（秒；`mapTime` 1ms-2s 指数映射），S = 电平百分比
            var vb: [16]u8 = undefined;
            const vt: []const u8 = if (ki == 2)
                std.fmt.bufPrint(&vb, "{d:.0}%", .{v * 100}) catch ""
            else
                fmtSeconds(&vb, synth.mapTime(v));
            const vw: i32 = @intFromFloat(ui.font.measure(vt));
            ui.label(vt, kx + @divTrunc(kw - vw, 2), ky + knob_size + 14, ui.theme.text_dim);
        }
    }
    ry += knob_size + 40; // 旋钮 + 字母 + 数值行（V+40 给数值留位）

    // ── 滤波器区（高通 / 低通）──
    ry += 4;
    ui.renderer.hline(x + 8, ry, ww - 16, ui.theme.panel_border);
    ry += 6;
    ui.label("滤波器", x + 10, ry, ui.theme.text_dim);
    ry += 18;
    {
        const names = [_][]const u8{ "高通 HPF", "低通 LPF" };
        const filters = [_]*synth.FilterParams{ &p.hpf, &p.lpf };
        const fw = @divTrunc(ww - 40, 2);
        for (names, 0..) |nm, fi| {
            const fx = x + 20 + @as(i32, @intCast(fi)) * fw;
            const on = filters[fi].enabled.load(.monotonic);
            // 开关按钮
            const btn_w: i32 = 84;
            const btn_h: i32 = 22;
            const hovered = util.hitUI(ui, fx, ry, btn_w, btn_h);
            ui.renderer.fillRect(fx, ry, btn_w, btn_h, if (on) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(fx, ry, btn_w, btn_h, ui.theme.panel_border);
            ui.labelClipped(nm, fx + 8, ry + 3, btn_w - 12, ui.theme.text);
            if (hovered and ui.mouse_pressed) {
                filters[fi].enabled.store(!on, .monotonic);
                app.commitHistory("切换滤波器"); // 开关：原子提交
            }

            // 截止频率旋钮
            const kx = fx + btn_w + 16;
            var cv = filters[fi].cutoff.load(.monotonic);
            if (ui.knob(5200 + @as(u64, fi), &cv, kx, ry - 6, knob_size)) {
                filters[fi].cutoff.store(cv, .monotonic);
                app.history_pending = "调整滤波截止"; // 松手时 coalesce
            }
            var hz_buf: [16]u8 = undefined;
            const hz = synth.cutoffHz(cv);
            const hz_t = if (hz >= 1000)
                std.fmt.bufPrint(&hz_buf, "{d:.1}k", .{hz / 1000.0}) catch ""
            else
                std.fmt.bufPrint(&hz_buf, "{d:.0}Hz", .{hz}) catch "";
            ui.label(hz_t, kx + knob_size + 6, ry + 6, ui.theme.text_dim);
        }
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}

/// 时间→秒的紧凑显示（单位固定为秒；< 1s 两位/三位小数保证可读）
fn fmtSeconds(buf: []u8, sec: f32) []const u8 {
    if (sec >= 10.0) return std.fmt.bufPrint(buf, "{d:.1}s", .{sec}) catch "";
    if (sec >= 1.0) return std.fmt.bufPrint(buf, "{d:.2}s", .{sec}) catch "";
    if (sec >= 0.1) return std.fmt.bufPrint(buf, "{d:.2}s", .{sec}) catch "";
    return std.fmt.bufPrint(buf, "{d:.3}s", .{sec}) catch "";
}

/// 百分比格式（合奏散布的数值控件用）
fn fmtPercent(v: i32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{v}) catch "";
}

/// 振荡器行（一行一个）：开关 / 序号 / 波形按钮 / 音量旋钮 /
/// 合奏数量（0-16）/ 合奏散布（0-100%）——两个数值控件与 BPM 同款
/// （上下拖动、光标冻结隐藏）
fn drawOscRow(ui: *Ui, app: *App, p: *synth.SynthParams, oi: usize, x: i32, y: i32, w: i32) void {
    _ = w;
    const op = &p.osc[oi];
    const on = op.enabled.load(.monotonic);
    const cy = y + @divTrunc(osc_row_h, 2); // 行垂直中心

    // 开关（方块按钮）
    const sw_sz: i32 = 22;
    const sw_y = cy - @divTrunc(sw_sz, 2);
    const sw_hovered = util.hitUI(ui, x, sw_y, sw_sz, sw_sz);
    ui.renderer.fillRect(x, sw_y, sw_sz, sw_sz, if (on) ui.theme.accent else if (sw_hovered) ui.theme.item_hover else ui.theme.slider_track);
    ui.renderer.strokeRect(x, sw_y, sw_sz, sw_sz, ui.theme.panel_border);
    if (sw_hovered and ui.mouse_pressed) {
        op.enabled.store(!on, .monotonic);
        app.commitHistory("切换振荡器"); // 开关：原子提交
    }

    // 序号
    var nb: [8]u8 = undefined;
    const nt = std.fmt.bufPrint(&nb, "OSC{d}", .{oi + 1}) catch "OSC";
    ui.label(nt, x + sw_sz + 8, cy - 5, if (on) ui.theme.text else ui.theme.text_dim);

    // 波形按钮（点击切换下一个）
    const wf = @as(synth.Waveform, @enumFromInt(op.waveform.load(.monotonic) % synth.waveform_count));
    const btn_x = x + sw_sz + 58;
    const btn_w: i32 = 64;
    const btn_h: i32 = 22;
    const btn_y = cy - @divTrunc(btn_h, 2);
    const btn_hovered = util.hitUI(ui, btn_x, btn_y, btn_w, btn_h);
    ui.renderer.fillRect(btn_x, btn_y, btn_w, btn_h, if (btn_hovered) ui.theme.item_hover else ui.theme.slider_track);
    ui.renderer.strokeRect(btn_x, btn_y, btn_w, btn_h, ui.theme.panel_border);
    ui.labelClipped(wf.name(), btn_x + 8, btn_y + 3, btn_w - 12, ui.theme.text);
    if (btn_hovered and ui.mouse_pressed) {
        op.waveform.store(@intFromEnum(wf.next()), .monotonic);
        app.commitHistory("切换波形"); // 按钮：原子提交
    }

    // 音量旋钮
    var v = op.volume.load(.monotonic);
    const kx = btn_x + btn_w + 14;
    if (ui.knob(5300 + @as(u64, oi), &v, kx, cy - @divTrunc(knob_size, 2), knob_size)) {
        op.volume.store(v, .monotonic);
        app.history_pending = "调整振荡器音量"; // 松手时 coalesce
    }

    // 合奏副本数（1-16；1 = 无合奏——最少一个发声源）——BPM 式上下拖动
    // **注意 id 步长 3**（每行三个控件：合奏/散布/功率）——步长写 2 会让
    // 本行功率与下一行合奏撞 id（dragNumber 的 active_id 串场，实测 bug）
    const uni_lx = kx + knob_size + 18;
    ui.label("合奏", uni_lx, cy - 5, ui.theme.text_dim);
    {
        var uni: i32 = @intCast(std.math.clamp(op.unison.load(.monotonic), 1, @as(u32, synth.max_unison)));
        if (ui.dragNumber(5400 + @as(u64, oi) * 3, uni_lx + 36, cy - 11, 34, 22, &uni, 1, @as(i32, @intCast(synth.max_unison)), 6)) {
            op.unison.store(@intCast(uni), .monotonic);
            app.history_pending = "调整合奏数量"; // 松手时 coalesce
        }
    }

    // 合奏散布（0-100%；拖动值即百分比——存 f32 0-1）——BPM 式上下拖动
    const det_lx = uni_lx + 36 + 34 + 14;
    ui.label("散布", det_lx, cy - 5, ui.theme.text_dim);
    {
        var pct: i32 = Ui.roundF(op.unison_detune.load(.monotonic) * 100.0);
        if (ui.dragNumberEx(5401 + @as(u64, oi) * 3, det_lx + 36, cy - 11, 50, 22, &pct, 0, 100, 3, 0, fmtPercent)) {
            op.unison_detune.store(std.math.clamp(@as(f32, @floatFromInt(pct)) / 100.0, 0, 1), .monotonic);
            app.history_pending = "调整合奏散布"; // 松手时 coalesce
        }
    }

    // 散布功率（-5..5；0 = 线性；非 0 → 副本间距指数扭曲）——BPM 式上下拖动
    // （与常见合成器的 “Unison Detune Power” 同义；存 f32）
    // 注：取整必须用 `Ui.roundF`——负值用 `+0.5` 截断会读回 +1（实测 bug）
    const pow_lx = det_lx + 36 + 50 + 14;
    ui.label("功率", pow_lx, cy - 5, ui.theme.text_dim);
    {
        var pw: i32 = Ui.roundF(op.detune_power.load(.monotonic));
        if (ui.dragNumber(5402 + @as(u64, oi) * 3, pow_lx + 36, cy - 11, 30, 22, &pw, -5, 5, 24)) {
            op.detune_power.store(@floatFromInt(pw), .monotonic);
            app.history_pending = "调整散布功率"; // 松手时 coalesce
        }
    }
}
