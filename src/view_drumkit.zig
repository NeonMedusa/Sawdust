//! 鼓组编辑器（浮动窗口）：左音高列表 + 右垫详情（`docs/drumkit.md` §7）。
//!
//! - 左：GM 35-81 全列表 **∪ 所有已映射音高**（合并升序；自定义音高也能编辑）；
//!   未映射行暗色、已映射行左缘强调条 + 右端 ●；点击选中。
//! - 右：垫名（点击就地改名；空 = GM/音名默认）+ [试听]（按住响、松开停）；
//!   层列表：来源名 / 增益（上下拖动）/ [编辑]（层窗口：减法=参数面板 /
//!   VST3=插件界面）/ [×]；
//!   底部 [＋ 添加乐器]（统一预设面板：减法/VST3，不列鼓组）。
//!
//! 数据改动全部经 App 的鼓组 API（退役/历史语义在那边统一处理）；
//! 预设文件 IO 走 `pending_preset` 在 main 帧末执行（本模块不碰 io）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const PresetSaveSource = @import("app.zig").PresetSaveSource;
const model = @import("model.zig");
const util = @import("view_util.zig");
const audio = @import("audio.zig");

const win_title_h: i32 = 22;
const win_min_w: i32 = 560;
const win_min_h: i32 = 320;
const left_w: i32 = 190; // 左列表宽
const row_h: i32 = 20; // 左列表行高
const layer_row_h: i32 = 26; // 层行高
const btn_h: i32 = 24; // 底部按钮高

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const dw = &app.drumkit_win;
    if (!dw.open) return false;

    // 约束在屏幕内
    dw.w = std.math.clamp(dw.w, win_min_w, @max(win_min_w, w - 20));
    dw.h = std.math.clamp(dw.h, win_min_h, @max(win_min_h, h - 20));
    dw.x = std.math.clamp(dw.x, 0, @max(0, w - dw.w));
    dw.y = std.math.clamp(dw.y, 0, @max(0, h - dw.h));

    const kit = app.drumKitWindowKit() orelse {
        // 乐器被删 / 变成非鼓组 → 自动关闭（与合成器窗口同一习惯）
        if (dw.audition_pitch) |ap| app.auditionOffInst(dw.instrument, ap);
        dw.open = false;
        dw.audition_pitch = null;
        return true;
    };
    const inst_idx = dw.instrument;
    const inst = &app.instruments.items[@intCast(inst_idx)];

    const x = dw.x;
    const y = dw.y;
    const ww = dw.w;
    const hh = dw.h;
    const body_y = y + win_title_h;

    // 选中音高钳制（选择被外部改动/存档恢复后可能越界）
    if (dw.sel_pitch < 0 or dw.sel_pitch > 127) dw.sel_pitch = 36;
    const sel: u8 = @intCast(dw.sel_pitch);

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏：鼓组 — 乐器名（右侧：[预设 ▾] [保存为…] 层 n/16 ×）
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, win_title_h - 1, ui.theme.toolbar);
    {
        var tbuf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "鼓组 — {s}", .{inst.name}) catch "鼓组";
        ui.label(title, x + 8, y + 4, ui.theme.text);
        // 层数概览
        var cb: [24]u8 = undefined;
        const cnt = std.fmt.bufPrint(&cb, "层 {d}/{d}", .{ kit.totalLayers(), audio.kit_max_layers }) catch "";
        const cw: i32 = @intFromFloat(ui.font.measure(cnt));
        ui.label(cnt, x + ww - 30 - cw, y + 4, ui.theme.text_dim);
        // [预设 ▾] [保存为…]（与合成器窗口同款：整组套鼓的存/取）
        const save_w: i32 = 62;
        const menu_w: i32 = 58;
        const gap: i32 = 6;
        const bx2 = x + ww - 30 - cw - 12 - save_w;
        const bx1 = bx2 - gap - menu_w;
        const bh2: i32 = win_title_h - 6;
        const by2 = y + 3;
        if (bx1 > x + 150) {
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
                    app.openPresetBrowser(.{ .replace = .{ .instrument = inst_idx } });
                }
                ui.active_id = 0; // 防误触发标题拖动
            }
            const h2 = util.hitUI(ui, bx2, by2, save_w, bh2);
            ui.renderer.fillRect(bx2, by2, save_w, bh2, if (h2) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx2, by2, save_w, bh2, ui.theme.panel_border);
            ui.label("保存为…", bx2 + 4, by2 + 2, ui.theme.text);
            if (h2 and ui.mouse_pressed) {
                const save_src = PresetSaveSource{ .kit = inst_idx };
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
        dw.open = false;
        if (dw.audition_pitch) |ap| {
            app.auditionOffInst(inst_idx, ap);
            dw.audition_pitch = null;
        }
        return true;
    }

    // 点窗口内任意处 → 置顶（“点谁谁在上”）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&dw.z);
    }

    // 标题拖动（排除右侧按钮区；按钮区≈150px）
    if (util.hitUI(ui, x, y, ww - 170, win_title_h) and ui.mouse_pressed) {
        ui.active_id = 7060;
        dw.grab_dx = ui.mouse_x - x;
        dw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 7060) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            dw.x = ui.mouse_x - dw.grab_dx;
            dw.y = ui.mouse_y - dw.grab_dy;
        }
    }

    // 右下角缩放柄
    const grip = 14;
    const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
    if (grip_hovered) ui.cursor = .resize_h;
    if (grip_hovered and ui.mouse_pressed) {
        ui.active_id = 7061;
        dw.resize_w0 = ww;
        dw.resize_h0 = hh;
        dw.resize_mx = ui.mouse_x;
        dw.resize_my = ui.mouse_y;
    }
    if (ui.active_id == 7061) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            dw.w = dw.resize_w0 + (ui.mouse_x - dw.resize_mx);
            dw.h = dw.resize_h0 + (ui.mouse_y - dw.resize_my);
        }
    }
    ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);
    ui.renderer.line(x + ww - 6, y + hh - 2, x + ww - 2, y + hh - 6, ui.theme.panel_border);

    const body_h = hh - win_title_h;

    // ── 左：音高列表 ────────────────────────────────────────────
    const lx = x + 4;
    const ly = body_y + 4;
    const lh = body_h - 8;
    ui.renderer.fillRect(lx, ly, left_w, lh, ui.theme.bg);
    ui.renderer.vline(lx + left_w, ly, lh, ui.theme.panel_border);
    {
        // 行集合 = GM 范围 ∪ 已映射音高（升序；自定义音高也能在此编辑）
        var pitches: [128]i32 = undefined;
        var np: usize = 0;
        var p: i32 = 0;
        while (p < 128) : (p += 1) {
            if ((p >= 35 and p <= 81) or kit.find(@intCast(p)) != null) {
                pitches[np] = p;
                np += 1;
            }
        }
        const content_h: i32 = @intCast(np * @as(usize, @intCast(row_h)));
        const scroll_max = @max(0, content_h - lh);
        if (util.hitUI(ui, lx, ly, left_w, lh)) {
            dw.scroll = std.math.clamp(dw.scroll - util.scrollDelta(ui), 0, scroll_max);
        }
        dw.scroll = std.math.clamp(dw.scroll, 0, scroll_max);

        const saved = ui.renderer.pushClip(lx, ly, left_w, lh);
        defer ui.renderer.popClip(saved);
        for (pitches[0..np], 0..) |pp, i| {
            const ry = ly + @as(i32, @intCast(i)) * row_h - dw.scroll;
            if (ry + row_h < ly or ry > ly + lh) continue;
            const mapped = kit.isMapped(@intCast(pp)); // 有层才算已映射（空垫不亮）
            const selected = dw.sel_pitch == pp;
            const hovered = util.hitUI(ui, lx, ry, left_w, row_h);
            if (selected or hovered) {
                ui.renderer.fillRect(lx, ry, left_w, row_h, if (selected) ui.theme.item_selected else ui.theme.item_hover);
            }
            if (mapped) ui.renderer.fillRect(lx, ry, 2, row_h - 1, ui.theme.accent);
            var pb: [16]u8 = undefined;
            const pt = std.fmt.bufPrint(&pb, "{d}", .{pp}) catch "";
            ui.labelCentered(pt, lx + 8, ry, row_h, ui.theme.text_dim);
            // 注：`pnb` 必须在外层声明——放在 if 块内会让返回的切片出块即悬空
            var nb: [64]u8 = undefined;
            var pnb: [8]u8 = undefined;
            var lbl = model.drumKeyLabel(&nb, kit, pp);
            if (lbl.len == 0) lbl = model.pitchName(&pnb, pp);
            var eb: [128]u8 = undefined;
            const shown = util.middleEllipsis(ui, &eb, lbl, left_w - 52);
            if (shown.len > 0) {
                ui.labelCentered(shown, lx + 30, ry, row_h, if (mapped) ui.theme.text else ui.theme.text_dim);
            }
            if (mapped) ui.renderer.fillRect(lx + left_w - 14, ry + @divTrunc(row_h - 6, 2), 6, 6, ui.theme.accent);
            if (hovered and ui.mouse_pressed and !selected) {
                dw.sel_pitch = pp;
                dw.layer_scroll = 0;
            }
        }
        ui.drawScrollbar(lx + left_w - 5, ly, 5, lh, dw.scroll, content_h, lh);
    }

    // ── 右：垫详情 ──────────────────────────────────────────────
    const rx = lx + left_w + 10;
    const rw = @max(120, x + ww - 6 - rx);
    var ry2 = body_y + 8;

    const pad: ?*model.DrumPad = kit.find(sel);

    // 抬头：垫 音高 · 显示名
    {
        var hb: [96]u8 = undefined;
        var nb: [64]u8 = undefined;
        const disp = model.drumKeyLabel(&nb, kit, dw.sel_pitch);
        const head = std.fmt.bufPrint(&hb, "垫 {d} · {s}", .{ dw.sel_pitch, disp }) catch "";
        ui.label(head, rx, ry2, ui.theme.text);
        ry2 += 22;
    }

    // 名称字段 + 试听
    {
        const fld_h: i32 = 20;
        ui.label("名称", rx, ry2 + 2, ui.theme.text_dim);
        const fld_x = rx + 40;
        const fld_w: i32 = 180;
        const fld_hovered = util.hitUI(ui, fld_x, ry2, fld_w, fld_h);
        ui.renderer.fillRect(fld_x, ry2, fld_w, fld_h, ui.theme.bg);
        ui.renderer.strokeRect(fld_x, ry2, fld_w, fld_h, if (fld_hovered) ui.theme.accent else ui.theme.panel_border);
        const pad_name: []const u8 = if (pad) |pp| pp.name else "";
        if (pad_name.len > 0) {
            ui.labelClipped(pad_name, fld_x + 5, ry2 + 2, fld_w - 10, ui.theme.text);
        } else {
            ui.label("（默认：用 GM/音名）", fld_x + 5, ry2 + 2, ui.theme.key_label);
        }
        if (fld_hovered and ui.mouse_pressed) {
            // 就地改名（复用文本输入基建：支持中文 IME；空名 = 清除）
            app.beginRenameKitPad(inst_idx, sel, fld_x, ry2);
        }

        // 试听（按住响、松开/移出停）
        const ab_x = fld_x + fld_w + 10;
        const ab_w: i32 = 56;
        const held = dw.audition_pitch != null and dw.audition_pitch.? == dw.sel_pitch;
        const ab_hovered = util.hitUI(ui, ab_x, ry2, ab_w, fld_h);
        ui.renderer.fillRect(ab_x, ry2, ab_w, fld_h, if (held) ui.theme.accent else if (ab_hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(ab_x, ry2, ab_w, fld_h, ui.theme.panel_border);
        const at: i32 = @intFromFloat(ui.font.measure("试听"));
        ui.labelCentered("试听", ab_x + @divTrunc(ab_w - at, 2), ry2, fld_h, ui.theme.text);
        if (ab_hovered and ui.mouse_pressed) {
            // 先释旧音（换音高试听时不漏 off）
            if (dw.audition_pitch) |ap| app.auditionOffInst(inst_idx, ap);
            dw.audition_pitch = dw.sel_pitch;
            app.auditionOnInst(inst_idx, dw.sel_pitch);
        }
        // 按住期间：松开或移出按钮 → 释音（与琴键试听同一手感）
        if (dw.audition_pitch) |ap| {
            if (!ui.mouse_down or !ab_hovered) {
                app.auditionOffInst(inst_idx, ap);
                dw.audition_pitch = null;
            }
        }

        ry2 += fld_h + 14;
    }

    // 层列表
    {
        ui.label("层", rx, ry2, ui.theme.text_dim);
        ry2 += 20;

        const list_h = @max(30, body_y + body_h - 8 - btn_h - 12 - ry2);
        // 可变切片（增益拖动要写回）；空切片用 `&.{}` 强转
        const layers: []model.DrumLayer = if (pad) |pp| pp.layers.items else &.{};
        const content_lh: i32 = @intCast(layers.len * @as(usize, @intCast(layer_row_h)));
        const lscroll_max = @max(0, content_lh - list_h);
        if (util.hitUI(ui, rx, ry2, rw, list_h)) {
            dw.layer_scroll = std.math.clamp(dw.layer_scroll - util.scrollDelta(ui), 0, lscroll_max);
        }
        dw.layer_scroll = std.math.clamp(dw.layer_scroll, 0, lscroll_max);

        // 行操作延后执行（循环内删除层会让下标失效）
        var edit_req: ?usize = null;
        var del_req: ?usize = null;
        {
            const saved = ui.renderer.pushClip(rx, ry2, rw, list_h);
            defer ui.renderer.popClip(saved);
            if (layers.len == 0) {
                ui.labelClipped("（无层）用下方按钮添加；上方点「试听」暂无声", rx + 4, ry2 + 6, rw - 12, ui.theme.text_dim);
            }
            for (layers, 0..) |*layer, li| {
                const rry = ry2 + @as(i32, @intCast(li)) * layer_row_h - dw.layer_scroll;
                if (rry + layer_row_h < ry2 or rry > ry2 + list_h) continue;
                const row_hovered = util.hitUI(ui, rx, rry, rw, layer_row_h - 2);
                if (row_hovered) ui.renderer.fillRect(rx, rry, rw, layer_row_h - 2, ui.theme.item_hover);

                // 序号 + 「插件 · 预设名」（层 = 乐器槽）
                var ib: [16]u8 = undefined;
                const it = std.fmt.bufPrint(&ib, "{d}", .{li + 1}) catch "";
                ui.labelCentered(it, rx + 4, rry, layer_row_h - 2, ui.theme.text_dim);
                var lb: [96]u8 = undefined;
                const pdisp = if (layer.kind == .vst3) layer.source_preset else presetDisplayName(layer.source_preset);
                const full = if (pdisp.len > 0)
                    (std.fmt.bufPrint(&lb, "{s} · {s}", .{ layer.kind.displayName(), pdisp }) catch pdisp)
                else
                    (std.fmt.bufPrint(&lb, "{s} · （默认音色）", .{layer.kind.displayName()}) catch "（默认音色）");
                var eb: [128]u8 = undefined;
                const shown = util.middleEllipsis(ui, &eb, full, @max(40, rw - 216));
                if (shown.len > 0) {
                    ui.labelClipped(shown, rx + 24, rry + 3, @max(40, rw - 216), if (pdisp.len > 0) ui.theme.text else ui.theme.text_dim);
                }

                // **双击层行**（名称区；排除右侧增益/编辑/×）→ 打开该层乐器面板
                // ——与机架“双击乐器名”同一习惯（`[编辑]` 按钮仍保留）
                if (util.hitUI(ui, rx, rry, @max(40, rw - 192), layer_row_h - 2) and ui.mouse_double) edit_req = li;

                // 增益（上下拖动；松手时 coalesce 提交）
                const gx = rx + rw - 158;
                ui.labelCentered("增益", gx - 34, rry, layer_row_h - 2, ui.theme.text_dim);
                var pct: i32 = Ui.roundF(std.math.clamp(layer.gain, 0, 1) * 100);
                if (ui.dragNumberEx(7300 + @as(u64, li), gx, rry + 2, 54, layer_row_h - 6, &pct, 0, 100, 3, 0, fmtPercent)) {
                    layer.gain = std.math.clamp(@as(f32, @floatFromInt(pct)) / 100.0, 0, 1);
                    app.history_pending = "调整层增益"; // 松手时 coalesce
                }

                // [编辑]：转交合成器窗口编辑该层参数
                const eb_x = rx + rw - 94;
                const eb_hovered = util.hitUI(ui, eb_x, rry + 2, 46, layer_row_h - 6);
                ui.renderer.fillRect(eb_x, rry + 2, 46, layer_row_h - 6, if (eb_hovered) ui.theme.accent else ui.theme.slider_track);
                ui.renderer.strokeRect(eb_x, rry + 2, 46, layer_row_h - 6, ui.theme.panel_border);
                ui.labelCentered("编辑", eb_x, rry + 2, layer_row_h - 6, ui.theme.text);
                if (eb_hovered and ui.mouse_pressed) edit_req = li;

                // [×]：删除该层
                const db_x = rx + rw - 42;
                const db_hovered = util.hitUI(ui, db_x, rry + 2, 34, layer_row_h - 6);
                ui.renderer.fillRect(db_x, rry + 2, 34, layer_row_h - 6, if (db_hovered) ui.theme.danger else ui.theme.slider_track);
                ui.renderer.strokeRect(db_x, rry + 2, 34, layer_row_h - 6, ui.theme.panel_border);
                ui.labelCentered("×", db_x, rry + 2, layer_row_h - 6, ui.theme.text);
                if (db_hovered and ui.mouse_pressed) del_req = li;
            }
            ui.drawScrollbar(rx + rw - 5, ry2, 5, list_h, dw.layer_scroll, content_lh, list_h);
        }

        if (edit_req) |li| {
            // 层窗口：减法层 = 参数面板；VST3 层 = **插件界面**（嵌入托管，同乐器）
            app.synth_win.target = .{ .kit_layer_replace = .{
                .instrument = inst_idx,
                .pitch = sel,
                .layer = li,
            } };
            app.synth_win.open = true;
            app.bringToFront(&app.synth_win.z);
        }
        if (del_req) |li| {
            if (app.kitLayerRemove(inst_idx, sel, li)) {
                app.commitHistory("删除层");
                dw.layer_scroll = 0;
            }
        }
    }

    // ── 底部：[＋ 添加乐器] → **预设面板**（任意插件；选中即在本垫加一层）──
    {
        const by2 = body_y + body_h - 8 - btn_h;
        const bw: i32 = 140;
        const hovered = util.hitUI(ui, rx, by2, bw, btn_h);
        ui.renderer.fillRect(rx, by2, bw, btn_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(rx, by2, bw, btn_h, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure("+ 添加乐器"));
        ui.labelCentered("+ 添加乐器", rx + @divTrunc(bw - tw, 2), by2, btn_h, ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            app.openPresetBrowser(.{ .create_kit_layer = .{ .instrument = inst_idx, .pitch = sel } });
        }
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}

/// 来源预设名 `分类/名字` → 显示名（取 `/` 后部分；无前缀则原样）
fn presetDisplayName(src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '/')) |i| return src[i + 1 ..];
    return src;
}

/// 百分比格式（增益单元格用）
fn fmtPercent(v: i32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{v}) catch "";
}
