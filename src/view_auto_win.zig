//! **自动化链接窗口**（一参数 ↔ 多曲线）
//!
//! 从混音台通道右键菜单的 `自动化…` 打开；管理“这个参数绑了哪些曲线、每条的深度/极性”。
//!
//! - 叠加语义：`参数 = clamp(静态推子 + Σ 深度 × (单向: v / 双向: 2v−1), 0, 1)`
//! - 每行：`[✓启用] 曲线名 · 深度滑条 · 单向/双向 · 映射占位(1:1) · ×移除`
//! - 底部：`+ 新曲线并链接` + 未绑定曲线的快捷芯片
//! - 映射曲线（画任意映射）**本轮仅占位**（1:1 斜线，点击提示暂未实现）
//!
//! 与“按曲线看”的播放列表行头列共享同一张绑定表（两个视角，互相同步）。

const std = @import("std");
const App = @import("app.zig").App;
const Ui = @import("ui.zig").Ui;
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");

pub const W: i32 = 460;
pub const H: i32 = 268;

const row_h: i32 = 34;

pub fn draw(ui: *Ui, app: *App) void {
    const win = &app.auto_win;
    if (!win.open) return;
    const w = W;
    const h = H;
    const x = win.x;
    const y = win.y;

    // ── 窗口底 + 边框 + 标题栏 ──
    ui.renderer.fillRect(x, y, w, h, ui.theme.panel);
    ui.renderer.strokeRect(x, y, w, h, ui.theme.accent);
    ui.renderer.fillRect(x + 1, y + 1, w - 2, util.title_h - 1, ui.theme.toolbar);
    ui.noteOverlayRect(x, y, w, h);

    var tb: [64]u8 = undefined;
    var nm: [32]u8 = undefined;
    const tname = targetName(app, win.target, &nm);
    const title = std.fmt.bufPrint(&tb, "自动化 · {s}", .{tname}) catch "自动化";
    ui.labelClipped(title, x + 8, y + 4, w - 40, ui.theme.text);

    // ✕ 关闭
    {
        const bx = x + w - 22;
        const by = y + 2;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx, by, 18, 16);
        if (hovered) ui.renderer.fillRect(bx, by, 18, 16, ui.theme.item_hover);
        ui.label("x", bx + 6, by + 3, if (hovered) ui.theme.accent else ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) win.open = false;
    }

    // ── 状态行：基准值 + 合成值（按当前游标）──
    // **基准 = 目标类型的标准基准，不是推子/旋钮当前值**：
    // 音量类 = 0（曲线值直接就是音量）、声像类 = 0.5（双向：中心不动，可上可下）；
    // 将来 VST3 参数目标的基准/极性则取插件的 `defaultNormalizedValue` / `kIsBipolar`。
    {
        const base = view_lane.Target.defaultBase(win.target.kind);
        const bipolar = view_lane.Target.defaultBipolar(win.target.kind);
        const step: f32 = @floatFromInt(app.playback.cursorStep(true));
        const v = app.autoValueFor(win.target, step, base);
        var sb: [160]u8 = undefined;
        const kind_txt: []const u8 = switch (win.target.kind) {
            .master_vol => "主音量",
            .mixer_vol, .inst_vol => "音量",
            .mixer_pan, .inst_pan => "声像",
            .tempo => "速度（BPM）",
            .none => "未绑定",
        };
        const pol_txt: []const u8 = if (bipolar) "双向" else "单向";
        const st = if (win.target.kind == .tempo)
            // BPM 用**真实的 bpm 数字**显示（归一化 0..1 对用户没意义）
            (if (app.isTargetBound(win.target))
                std.fmt.bufPrint(&sb, "区间 20~999 BPM  →  此刻 {d:.0} BPM", .{view_lane.Target.bpmFromNorm(v)}) catch ""
            else
                std.fmt.bufPrint(&sb, "区间 20~999 BPM  →  尚未链接曲线（当前 {d} BPM）", .{app.bpm}) catch "")
        else if (app.isTargetBound(win.target))
            std.fmt.bufPrint(&sb, "基准 {d:.2}（{s} · {s}）  →  合成 {d:.2}", .{ base, kind_txt, pol_txt, v }) catch ""
        else
            std.fmt.bufPrint(&sb, "基准 {d:.2}（{s} · {s}）  →  尚未链接曲线（旋钮静值 {d:.2}）", .{ base, kind_txt, pol_txt, baseValueOf(app, win.target) }) catch "";
        ui.labelClipped(st, x + 8, y + util.title_h + 4, w - 16, ui.theme.text_dim);
    }

    // ── 绑定行 ──
    var binds_buf: [32]view_lane.Binding = undefined;
    const binds = app.bindingsOfTarget(win.target, &binds_buf);
    const list_top = y + util.title_h + 20;
    const list_bottom = y + h - 34;
    const list_h = @max(row_h, list_bottom - list_top);
    const view_rows: i32 = @max(1, @divTrunc(list_h, row_h));
    const content_rows: i32 = @intCast(binds.len);
    const max_scroll: i32 = @max(0, content_rows - view_rows);
    if (util.inRect(ui.mouse_x, ui.mouse_y, x + 4, list_top, w - 14, list_h) and ui.wheel != 0 and max_scroll > 0) {
        win.rows_scroll = std.math.clamp(win.rows_scroll - ui.wheel, 0, max_scroll);
        ui.wheel = 0;
    }
    win.rows_scroll = std.math.clamp(win.rows_scroll, 0, max_scroll);
    if (binds.len == 0) {
        ui.labelClipped("尚未链接任何曲线 —— 用下方按钮链接或新建", x + 10, list_top + 8, w - 20, ui.theme.text_dim);
    }
    {
        var k: i32 = 0;
        var idx: usize = @intCast(win.rows_scroll);
        var ry = list_top;
        while (idx < binds.len and k < view_rows) : (idx += 1) {
            const b = binds[idx];
            const bi = app.bindingIndex(b.curve_id, win.target) orelse continue;
            const lc = app.curveById(b.curve_id) orelse continue;
            drawRow(ui, app, bi, lc, x + 4, ry, w - 8);
            ry += row_h;
            k += 1;
        }
        if (content_rows > view_rows) {
            ui.drawScrollbar(x + w - 8, list_top, 5, list_h, win.rows_scroll * row_h, content_rows * row_h, list_h);
        }
    }

    // ── 底部操作：`+ 新曲线并链接` / `链接到曲线…`（下拉，避免平铺溢出）──
    const by = y + h - 30;
    ui.renderer.hline(x + 4, by - 4, w - 8, ui.theme.panel_border);
    {
        const bw1: i32 = 116;
        const hovered1 = util.inRect(ui.mouse_x, ui.mouse_y, x + 8, by, bw1, 22);
        ui.renderer.fillRect(x + 8, by, bw1, 22, if (hovered1) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(x + 8, by, bw1, 22, ui.theme.panel_border);
        ui.labelClipped("+ 新曲线并链接", x + 12, by + 5, bw1 - 8, ui.theme.text);
        if (hovered1 and ui.mouse_pressed) {
            // **按参数名自动命名**（例：`通道1 · 音量`、`主通道 · 音量`），重名自动加 `(2)`
            var nb: [48]u8 = undefined;
            const cname = app.autoCurveNameFor(win.target, &nb);
            const cid = app.addAutoCurve(cname);
            if (cid != 0 and app.bindCurveTarget(cid, win.target)) app.setToast("已新建曲线并链接");
        }

        const bx2 = x + 8 + bw1 + 8;
        const bw2: i32 = 116;
        const hovered2 = util.inRect(ui.mouse_x, ui.mouse_y, bx2, by, bw2, 22);
        ui.renderer.fillRect(bx2, by, bw2, 22, if (hovered2 or win.pick_open) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(bx2, by, bw2, 22, ui.theme.panel_border);
        ui.labelClipped("链接到曲线", bx2 + 8, by + 5, bw2 - 26, ui.theme.text);
        util.menuArrow(ui, bx2 + bw2 - 18, by + @divTrunc(22 - util.menu_arrow_h, 2), ui.theme.text_dim); // 字体缺 ▾ → 自绘
        if (hovered2 and ui.mouse_pressed) {
            win.pick_open = !win.pick_open;
            win.pick_scroll = 0;
        }
        const link_btn = Rect{ .x = bx2, .y = by, .w = bw2, .h = 22 };
        if (win.pick_open) drawPickList(ui, app, x, by - 6, w, link_btn);
    }

    // 拖标题栏移动（按下记“鼠标 − 窗口左上”的偏移；按住期间反算）
    {
        const id = Ui.idOf("auto_win_title", 0);
        if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, w - 24, util.title_h) and ui.mouse_pressed) {
            ui.active_id = id;
            win.drag_dx = ui.mouse_x - win.x;
            win.drag_dy = ui.mouse_y - win.y;
        }
        if (ui.active_id == id) {
            if (ui.mouse_down) {
                win.x = ui.mouse_x - win.drag_dx;
                win.y = ui.mouse_y - win.drag_dy;
            } else ui.active_id = 0;
        }
    }
}

/// 一行绑定：`[✓] 名字 [深度滑条] [单向/双向] [映射占位] [×]`
fn drawRow(ui: *Ui, app: *App, bi: usize, lc: *view_lane.Lane, x: i32, y: i32, w: i32) void {
    const b = &app.auto_bindings.items[bi];
    const row_bg = if (b.enabled) ui.theme.item_alt else ui.theme.toolbar;
    ui.renderer.fillRect(x, y, w, row_h - 4, row_bg);

    // 启用开关
    {
        const bx = x + 4;
        const by = y + 7;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx, by, 16, 16);
        ui.renderer.fillRect(bx, by, 16, 16, if (b.enabled) ui.theme.accent else ui.theme.slider_track);
        ui.renderer.strokeRect(bx, by, 16, 16, ui.theme.panel_border);

        if (hovered and ui.mouse_pressed) b.enabled = !b.enabled;
    }

    // 曲线名（点击 → 切到播放列表编辑这条曲线）
    {
        var nb: [24]u8 = undefined;
        const nm = lc.name(&nb);
        const nw: i32 = 96;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, x + 24, y + 4, nw, row_h - 8);
        ui.labelClipped(nm, x + 24, y + 8, nw, if (hovered) ui.theme.accent else if (b.enabled) ui.theme.text else ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) app.auto_sel = lc.id;
    }

    // **基准值**（归一化 0..1）：左键键入、**右键恢复类型默认**（音量 0 / 声像 0.5）
    {
        const bx0 = x + 24 + 96 + 2;
        const spec_base = view_lane.Target.defaultBase(b.target.kind);
        const bv = b.base orelse spec_base;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx0, y + 8, 52, 16);
        ui.renderer.fillRect(bx0, y + 8, 52, 16, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(bx0, y + 8, 52, 16, ui.theme.panel_border);
        var bb: [24]u8 = undefined;
        const bt = std.fmt.bufPrint(&bb, "基{d:.2}", .{bv}) catch "基";
        ui.labelClipped(bt, bx0 + 4, y + 10, 48, if (b.base == null) ui.theme.text_dim else ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            app.beginEditAutomationBase(bi, bt, bx0, y + 24, 60);
        }
        if (hovered and ui.mouse_right_pressed) b.base = null; // 恢复类型默认
    }

    // 深度滑条（0..100%）
    {
        var depth = b.depth;
        const sx = x + 24 + 96 + 58;
        const sw = w - (sx - x) - 150;
        if (ui.slider(Ui.idOf("auto_win_depth", 0) + bi, &depth, sx, y + 8, @max(40, sw), 16)) {
            b.depth = std.math.clamp(depth, 0.0, 1.0);
        }
        var db: [16]u8 = undefined;
        const dt = std.fmt.bufPrint(&db, "{d}%", .{@as(i32, @intFromFloat(@round(b.depth * 100.0)))}) catch "";
        ui.labelClipped(dt, sx + @max(40, sw) + 4, y + 10, 40, ui.theme.text_dim);
    }

    // 极性（单向 / 双向）——点击切换
    {
        const px = x + w - 106;
        const py = y + 8;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, px, py, 44, 16);
        ui.renderer.fillRect(px, py, 44, 16, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(px, py, 44, 16, ui.theme.panel_border);
        ui.labelClipped(if (b.bipolar) "双向" else "单向", px + 6, py + 3, 36, if (b.bipolar) ui.theme.accent else ui.theme.text);
        if (hovered and ui.mouse_pressed) b.bipolar = !b.bipolar;
        if (hovered and ui.mouse_right_pressed) b.bipolar = view_lane.Target.defaultBipolar(b.target.kind); // 恢复默认极性
    }

    // 映射占位（1:1 斜线；点击提示暂未实现）
    {
        const mx = x + w - 56;
        const my = y + 4;
        ui.renderer.fillRect(mx, my, 24, 24, ui.theme.slider_track);
        ui.renderer.strokeRect(mx, my, 24, 24, ui.theme.panel_border);
        ui.renderer.line(mx + 3, my + 20, mx + 20, my + 3, ui.theme.text_dim); // 1:1
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, mx, my, 24, 24);
        if (hovered and ui.mouse_pressed) app.setToast("映射曲线即将支持");
    }

    // 移除
    {
        const rx = x + w - 26;
        const ry = y + 6;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, rx, ry, 18, 18);
        if (hovered) ui.renderer.fillRect(rx, ry, 18, 18, ui.theme.item_hover);
        ui.labelClipped("×", rx + 5, ry + 3, 12, if (hovered) ui.theme.danger else ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) {
            if (app.unbindCurveTarget(b.curve_id, app.auto_win.target)) app.setToast("已取消链接");
        }
    }
}

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// 「链接到曲线…」下拉：列出**尚未绑定到本参数**的曲线（可滚轮滚动）。
/// 曲线多时不再平铺（旧设计会把窗口撑爆）。点条目 = 绑定；点面板外 = 只关下拉。
fn drawPickList(ui: *Ui, app: *App, win_x: i32, above_y: i32, win_w: i32, btn: Rect) void {
    const win = &app.auto_win;
    const row: i32 = 20;
    const panel_w: i32 = win_w - 16;
    const pick_rows_max: i32 = 6;
    var avail: usize = 0;
    for (app.auto_curves.items) |*lc| {
        if (app.bindingIndex(lc.id, win.target) == null) avail += 1;
    }
    const rows: i32 = @intCast(@min(avail, @as(usize, @intCast(pick_rows_max))));
    const ph: i32 = @max(row, rows * row + 4);
    const px = win_x + 8;
    const py = above_y - ph;

    ui.renderer.fillRect(px, py, panel_w, ph, ui.theme.panel);
    ui.renderer.strokeRect(px, py, panel_w, ph, ui.theme.accent);
    ui.noteOverlayRect(px, py, panel_w, ph);

    if (avail == 0) {
        ui.labelClipped("（没有可链接的曲线——用左边按钮新建）", px + 8, py + 4, panel_w - 12, ui.theme.text_dim);
    }

    // 滚轮
    if (util.inRect(ui.mouse_x, ui.mouse_y, px, py, panel_w, ph) and ui.wheel != 0) {
        win.pick_scroll = std.math.clamp(win.pick_scroll - ui.wheel, 0, @max(0, @as(i32, @intCast(avail)) - pick_rows_max));
        ui.wheel = 0;
    }

    var k: i32 = 0;
    var shown: i32 = 0;
    var hit: ?u32 = null;
    for (app.auto_curves.items) |*lc| {
        if (app.bindingIndex(lc.id, win.target) != null) continue;
        if (shown < win.pick_scroll) {
            shown += 1;
            continue;
        }
        if (k >= pick_rows_max) break;
        const iy = py + 2 + k * row;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, px + 1, iy, panel_w - 2, row);
        if (hovered) ui.renderer.fillRect(px + 1, iy, panel_w - 2, row, ui.theme.item_hover);
        var nb: [24]u8 = undefined;
        const nm = lc.name(&nb);
        ui.labelClipped(nm, px + 8, iy + 3, panel_w - 14, ui.theme.text);
        if (hovered and ui.mouse_pressed) hit = lc.id;
        k += 1;
        shown += 1;
    }

    if (avail > @as(usize, @intCast(pick_rows_max))) {
        ui.drawScrollbar(px + panel_w - 6, py + 2, 5, ph - 4, win.pick_scroll * row, @as(i32, @intCast(avail)) * row, ph - 4);
    }
    if (hit) |cid| {
        if (app.bindCurveTarget(cid, win.target)) app.setToast("已链接曲线");
        win.pick_open = false;
    } else if (ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, px, py, panel_w, ph) and
        !util.inRect(ui.mouse_x, ui.mouse_y, btn.x, btn.y, btn.w, btn.h))
    {
        win.pick_open = false; // 点下拉之外（且不是那个按钮）→ 只收下拉
    }
}

/// 目标显示名（主通道 / 通道N · 音量|声像）
fn targetName(app: *const App, t: view_lane.Target, buf: []u8) []const u8 {
    switch (t.kind) {
        .none => return "未绑定",
        .master_vol => return "主通道 · 音量",
        .tempo => return "速度（BPM）",
        .mixer_vol, .mixer_pan => {
            const suffix: []const u8 = if (t.kind == .mixer_vol) "音量" else "声像";
            const idx = app.channelIndexByUid(t.uid) orelse return std.fmt.bufPrint(buf, "通道? · {s}", .{suffix}) catch "通道";
            var nb: [24]u8 = undefined;
            const nm = app.mixer_channels_state.items[idx].displayName(idx, &nb);
            return std.fmt.bufPrint(buf, "{s} · {s}", .{ nm, suffix }) catch nm;
        },
        .inst_vol, .inst_pan => {
            const suffix: []const u8 = if (t.kind == .inst_vol) "音量" else "声像";
            const idx = app.instrumentIndexByUid(t.uid) orelse return std.fmt.bufPrint(buf, "乐器? · {s}", .{suffix}) catch "乐器";
            return std.fmt.bufPrint(buf, "{s} · {s}", .{ app.instruments.items[idx].name, suffix }) catch "乐器";
        },
    }
}

/// 该参数的静态基准值（推子/旋钮当前值）
fn baseValueOf(app: *const App, t: view_lane.Target) f32 {
    switch (t.kind) {
        .master_vol => return if (app.mixer_channels_state.items.len > 0) app.mixer_channels_state.items[0].volume else 0.8,
        .mixer_vol, .mixer_pan => {
            const idx = app.channelIndexByUid(t.uid) orelse return 0.8;
            const mc = &app.mixer_channels_state.items[idx];
            return if (t.kind == .mixer_vol) mc.volume else mc.pan;
        },
        .inst_vol, .inst_pan => {
            const idx = app.instrumentIndexByUid(t.uid) orelse return 0.8;
            const inst = &app.instruments.items[idx];
            return if (t.kind == .inst_vol) inst.volume else inst.pan;
        },
        .tempo => return view_lane.Target.normFromBpm(app.bpm),
        .none => return 0.0,
    }
}
