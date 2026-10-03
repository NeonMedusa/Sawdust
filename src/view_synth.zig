//! 减法合成器编辑器（浮动窗口）：
//! 4 振荡器（2×2，开关/音量/波形）+ ADSR 四旋钮 + 高/低通滤波（开关 + 截止频率）。
//!
//! 编辑的是**窗口绑定乐器**的合成器参数（每乐器独立，堆分配、地址稳定）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const synth = @import("synth.zig");
const util = @import("view_util.zig");

const win_title_h: i32 = 22;
const cell_h: i32 = 46; // 振荡器单元高（旋钮 34 + 上下余量）
const knob_size: i32 = 34;
const win_min_w: i32 = 440;
const win_min_h: i32 = 260;

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

    // ── 振荡器区（2×2）──
    var ry = body_y + 6;
    ui.label("振荡器", x + 10, ry, ui.theme.text_dim);
    ry += 18;
    {
        const col_w = @divTrunc(ww - 30, 2);
        for (0..synth.osc_count) |oi| {
            const col: i32 = @intCast(oi % 2);
            const row: i32 = @intCast(oi / 2);
            drawOscCell(ui, app, p, oi, x + 10 + col * (col_w + 10), ry + row * cell_h, col_w);
        }
        ry += cell_h * 2;
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
        }
    }
    ry += knob_size + 22;

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

/// 振荡器单元（2×2 网格的一格）：开关 / 波形按钮 / 音量旋钮
fn drawOscCell(ui: *Ui, app: *App, p: *synth.SynthParams, oi: usize, x: i32, y: i32, w: i32) void {
    _ = w;
    const op = &p.osc[oi];
    const on = op.enabled.load(.monotonic);
    const cy = y + @divTrunc(cell_h, 2); // 单元垂直中心

    // 开关（方块按钮）
    const sw_sz: i32 = 20;
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
    const kx = btn_x + btn_w + 12;
    if (ui.knob(5300 + @as(u64, oi), &v, kx, cy - @divTrunc(knob_size, 2), knob_size)) {
        op.volume.store(v, .monotonic);
        app.history_pending = "调整振荡器音量"; // 松手时 coalesce
    }
}
