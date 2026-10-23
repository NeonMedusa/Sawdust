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
const PresetSaveSource = @import("app.zig").PresetSaveSource;
const synth = @import("synth.zig");
const model = @import("model.zig");
const util = @import("view_util.zig");
const vst_host = @import("vst_host.zig");
const PluginSlotRef = @import("app.zig").PluginSlotRef;

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

    // 约束在屏幕内（VST3 嵌入：尺寸固定=插件尺寸，松约束；其余：常规最小尺寸）
    var vst3_pl: ?*vst_host.Plugin = null;
    switch (sw.target) {
        .instrument => |ii| {
            if (ii >= 0 and ii < @as(i32, @intCast(app.instruments.items.len))) {
                const inst = &app.instruments.items[@intCast(ii)];
                if (inst.kind == .vst3) vst3_pl = inst.plugin;
            }
        },
        .kit_layer_replace => |ref| {
            if (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| {
                if (ly.kind == .vst3) vst3_pl = ly.plugin;
            }
        },
    }
    const embedded = vst3_pl != null and vst3_pl.?.view != null;
    const expect_ui = vst3_pl != null and !vst3_pl.?.editor_no_ui;
    const min_w: i32 = if (expect_ui) 80 else win_min_w;
    const min_h: i32 = if (expect_ui) 80 else win_min_h;
    sw.w = std.math.clamp(sw.w, min_w, @max(min_w, w - 20));
    sw.h = std.math.clamp(sw.h, min_h, @max(min_h, h - 20));
    sw.x = std.math.clamp(sw.x, 0, @max(0, w - sw.w));
    sw.y = std.math.clamp(sw.y, 0, @max(0, h - sw.h));

    const x = sw.x;
    const y = sw.y;
    const ww = sw.w;
    const hh = sw.h;
    const body_y = y + win_title_h;
    // 乐器目标：**跟随当前选择**（旧行为）；鼓组层目标：固定绑定（不跟随）。
    // 目标失效（乐器被删/变成鼓组/层被删）→ 自动关闭。
    switch (sw.target) {
        .instrument => |cur| {
            const ni = app.sel.instrument;
            if (cur != ni) sw.param_scroll = 0; // 换目标：兜底列表滚动归零
            sw.target = .{ .instrument = ni };
        },
        else => {},
    }
    const p = app.resolvePresetTarget(sw.target) orelse {
        sw.open = false;
        return true;
    };

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, win_title_h - 1, ui.theme.toolbar);
    var tbuf: [192]u8 = undefined;
    const title: []const u8 = switch (sw.target) {
        .instrument => |ii| blk: {
            const inst_ptr: ?*const model.Instrument = if (ii >= 0 and ii < @as(i32, @intCast(app.instruments.items.len)))
                &app.instruments.items[@intCast(ii)]
            else
                null;
            const iname: []const u8 = if (inst_ptr) |it| it.name else "（无乐器）";
            const kind_label: []const u8 = if (inst_ptr != null and inst_ptr.?.kind == .vst3) "VST3 乐器" else "减法合成器";
            break :blk std.fmt.bufPrint(&tbuf, "{s} — {s}", .{ kind_label, iname }) catch "乐器";
        },
        .kit_layer_replace => |ref| blk: {
            const iname: []const u8 = if (ref.instrument >= 0 and ref.instrument < @as(i32, @intCast(app.instruments.items.len)))
                app.instruments.items[@intCast(ref.instrument)].name
            else
                "（无乐器）";
            var nb: [48]u8 = undefined;
            const kit: ?*const model.DrumKit = if (ref.instrument >= 0 and ref.instrument < @as(i32, @intCast(app.instruments.items.len)))
                app.instruments.items[@intCast(ref.instrument)].kit
            else
                null;
            const pname = model.drumKeyLabel(&nb, kit, ref.pitch);
            const is_vst3_layer = blk2: {
                if (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| break :blk2 ly.kind == .vst3;
                break :blk2 false;
            };
            const kind_label: []const u8 = if (is_vst3_layer) "VST3 乐器" else "减法合成器";
            break :blk std.fmt.bufPrint(&tbuf, "{s} — {s} · {s} 层{d}", .{ kind_label, iname, pname, ref.layer + 1 }) catch "层";
        },
    };
    ui.label(title, x + 8, y + 4, ui.theme.text);

    // 预设按钮（标题栏右侧）：[预设 ▾] [保存为…]
    // 减法/VST3 乐器都有预设库——VST3 分类 = 插件 CID（`vst3_<cid>`）；
    // 见 main 的 loadVst3Preset/saveVst3Preset
    const target_is_vst3 = vst3_pl != null or switch (sw.target) {
        .instrument => |ii| (ii >= 0 and ii < @as(i32, @intCast(app.instruments.items.len)) and app.instruments.items[@intCast(ii)].kind == .vst3),
        .kit_layer_replace => |ref| blk: {
            const ly = app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse break :blk false;
            break :blk ly.kind == .vst3;
        },
    };
    {
        const save_w: i32 = 62;
        const menu_w: i32 = 58;
        const gap: i32 = 6;
        const bx2 = x + ww - 22 - 6 - save_w;
        const bx1 = bx2 - gap - menu_w;
        const bh2: i32 = win_title_h - 6;
        const by2 = y + 3;
        if (bx1 > x + 180) { // 标题放不下就不画（窄窗）
            // [预设 ▾]
            const h1 = util.hitUI(ui, bx1, by2, menu_w, bh2);
            ui.renderer.fillRect(bx1, by2, menu_w, bh2, if (app.preset_browser.open) ui.theme.accent else if (h1) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx1, by2, menu_w, bh2, ui.theme.panel_border);
            {
                // “预设” + 自绘下拉箭头（字体缺 `▾`；居中成组）
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
                    app.openPresetBrowser(.{ .replace = sw.target }); // 同插件限定
                }
                ui.active_id = 0; // 防误触发标题拖动（同一位置按下）
            }
            // [保存为…]
            const h2 = util.hitUI(ui, bx2, by2, save_w, bh2);
            ui.renderer.fillRect(bx2, by2, save_w, bh2, if (h2) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx2, by2, save_w, bh2, ui.theme.panel_border);
            ui.label("保存为…", bx2 + 4, by2 + 2, ui.theme.text);
            if (h2 and ui.mouse_pressed) {
                // 输入框弹在按钮下方（复用文本输入基建：支持中文 IME）；
                // **预填当前关联预设名**（直接回车 → 覆写确认）
                const save_src = PresetSaveSource{ .params = sw.target };
                app.beginRenamePreset(bx2 - 60, y + win_title_h + 4, save_src, app.presetPrefillName(save_src));
                app.preset_browser.open = false;
                ui.active_id = 0; // 防误触发标题拖动
            }
        }
    }

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

    // 标题拖动（**排除右侧按钮区**：预设/保存为/关闭——否则按按钮也会启动拖动）
    if (util.hitUI(ui, x, y, ww - 160, win_title_h) and ui.mouse_pressed) {
        ui.active_id = 5000;
        sw.grab_dx = ui.mouse_x - x;
        sw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 5000) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            // 拖出主窗口时**当场钳制**（顶部 clamp 下帧才生效——期间子窗口会跟着
            // 鼠标跑出面板/主窗口，用户实测“插件 UI 跑出去”）
            sw.x = std.math.clamp(ui.mouse_x - sw.grab_dx, 0, @max(0, w - ww));
            sw.y = std.math.clamp(ui.mouse_y - sw.grab_dy, 0, @max(0, h - hh));
        }
    }

    // 右下角缩放柄（VST3 嵌入：面板尺寸跟随插件，不提供手动缩放）
    if (!embedded) {
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
    }

    // ── VST3 乐器：插件界面嵌入（子窗口）或兜底参数列表（须在振荡器/ADSR 之前分流）──
    if (target_is_vst3) {
        switch (sw.target) {
            .instrument => |ii| {
                if (ii >= 0 and ii < @as(i32, @intCast(app.instruments.items.len))) {
                    const inst = &app.instruments.items[@intCast(ii)];
                    drawVst3Body(ui, app, inst.plugin, inst.name, inst.pluginPath(), inst.load_failed, .{ .kind = .instrument, .a = @intCast(@min(ii, std.math.maxInt(u16))) }, 9600, &sw.param_scroll, x, y, ww, hh);
                }
            },
            .kit_layer_replace => |ref| {
                if (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| {
                    const disp: []const u8 = if (ly.source_preset.len > 0) ly.source_preset else "VST3 乐器层";
                    const slot: u16 = if (app.kitLayerSlot(@intCast(@max(0, ref.instrument)), ref.pitch, ref.layer)) |s| @intCast(@min(s, std.math.maxInt(u16))) else 0;
                    drawVst3Body(ui, app, ly.plugin, disp, ly.pluginPath(), ly.load_failed, .{ .kind = .kit_layer, .a = @intCast(@max(0, ref.instrument)), .b = slot }, 9800 + @as(u64, slot), &sw.param_scroll, x, y, ww, hh);
                }
            },
        }
        return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
    }

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
/// VST3 乐器/鼓组层的插件体：嵌入中（子窗口覆盖内容区）不画；否则信息行 + 参数列表兜底
/// （无界面插件走列表）。`ref`/`id_base` 决定参数编辑记账归属与控件 id 段。
fn drawVst3Body(
    ui: *Ui,
    app: *App,
    pl_opt: ?*vst_host.Plugin,
    display_name: []const u8,
    path: []const u8,
    load_failed: bool,
    ref: PluginSlotRef,
    id_base: u64,
    scroll_p: *i32,
    x: i32,
    y: i32,
    ww: i32,
    hh: i32,
) void {
    if (pl_opt) |p| {
        if (p.view != null) return; // 嵌入中：子窗口覆盖内容区
    }
    const body_y = y + win_title_h;
    var yy = body_y + 10;
    ui.label(display_name, x + 10, yy, ui.theme.text);
    yy += 22;
    ui.labelClipped(path, x + 10, yy, ww - 20, ui.theme.text_dim);
    yy += 22;
    const pl = pl_opt;
    if (pl) |p| {
        var b: [64]u8 = undefined;
        ui.label(std.fmt.bufPrint(&b, "{s} · 延迟 {d} 样本", .{ p.name(), p.latency }) catch "", x + 10, yy, ui.theme.text_dim);
    } else {
        if (load_failed) {
            ui.label("（插件加载失败——将自动重试；文件恢复后自动加载）", x + 10, yy, ui.theme.danger);
        } else {
            ui.label("（插件未加载）", x + 10, yy, ui.theme.text_dim);
        }
        return;
    }
    yy += 24;
    ui.renderer.hline(x + 8, yy, ww - 16, ui.theme.panel_border);
    yy += 8;
    util.drawPluginParamList(ui, app, pl, load_failed, scroll_p, ref, id_base, x + 10, body_y, ww - 20, hh - win_title_h, yy);
}

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
    const wf = @as(synth.Waveform, @fromBackingInt(@intCast(op.waveform.load(.monotonic) % synth.waveform_count)));
    const btn_x = x + sw_sz + 58;
    const btn_w: i32 = 64;
    const btn_h: i32 = 22;
    const btn_y = cy - @divTrunc(btn_h, 2);
    const btn_hovered = util.hitUI(ui, btn_x, btn_y, btn_w, btn_h);
    ui.renderer.fillRect(btn_x, btn_y, btn_w, btn_h, if (btn_hovered) ui.theme.item_hover else ui.theme.slider_track);
    ui.renderer.strokeRect(btn_x, btn_y, btn_w, btn_h, ui.theme.panel_border);
    ui.labelClipped(wf.name(), btn_x + 8, btn_y + 3, btn_w - 12, ui.theme.text);
    if (btn_hovered and ui.mouse_pressed) {
        op.waveform.store(@backingInt(wf.next()), .monotonic);
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
