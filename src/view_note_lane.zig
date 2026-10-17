//! 力度/声像编辑轨（钢琴卷帘底部；见 `docs/note-lane.md`）。
//!
//! - 单轨 + 模式切换（力度 / 声像），轨道头 = `toggle2` 双段按钮；
//! - 横坐标与音符区**同一映射**（`lane_x + step*step_ws − scroll_s`）；
//! - 每音符一根柱条：力度从底向上、声像从中线双向（上 = 右、下 = 左）；
//!   末端 = 白色正方形（值标记；全部方块置顶、不被任何柱体遮挡）；
//! - 拖编辑区（起点任意）= 绝对画笔（跟鼠标 y + 横扫刷过路径上的柱条）；
//!   有选区时只刷选中的柱条；**编辑区不改选区**（选区只由钢琴窗建立）；
//! - Alt+滚轮 = 调力度/声像（有选区 → 全部选中整体增减；否则最近柱条末端）；
//! - 双击重置默认；右键不响应（防误删）；
//! - 拖动中不逐帧重扫调度（防事件风暴）；松手由调用方提交历史
//!   （`commitHistory` → `rescanForEdit`，正在响的音符改值下次触发生效）。

const std = @import("std");
const r_mod = @import("render.zig");
const model = @import("model.zig");
const app_mod = @import("app.zig");
const Ui = @import("ui.zig").Ui;
const util = @import("view_util.zig");

const App = app_mod.App;
const NoteLaneMode = app_mod.NoteLaneMode;

/// 编辑轨最小高度（像素）——再矮就放不下柱条 + 轨道头文字
pub const min_h: i32 = 44;
/// 编辑轨最大高度占内容区的比例（35%）
pub const max_frac: f32 = 0.35;
/// 柱条纵向内缩（上下各留白；值域映射的可用高度 = lane_h − 2*inset）
const inset: i32 = 4;
/// 柱条宽度范围
const bar_w_min: i32 = 4;
const bar_w_max: i32 = 8;

// ── 值 ↔ 像素映射（纯函数，可单测）──

/// 力度 → 柱条高度（像素；`avail` = 可用高度）。1..127 映射到 1..avail。
pub fn velBarH(vel: i32, avail: i32) i32 {
    const v = std.math.clamp(vel, 1, 127);
    return @max(1, @divTrunc(avail * v, 127));
}

/// 鼠标 y → 力度（`top`/`avail` = 柱条区顶部与高度；向上 = 增大）。
pub fn velFromY(mouse_y: i32, top: i32, avail: i32) i32 {
    const from_bottom = top + avail - mouse_y; // 距底高度
    const v = @divTrunc(from_bottom * 127 + @divTrunc(avail, 2), @max(1, avail)); // round
    return std.math.clamp(v, 1, 127);
}

/// 声像 → 柱条高度（中线起，双向；返回相对中线的像素偏移，正 = 向上 = 右）
pub fn panBarH(pan: i32, avail: i32) i32 {
    const p = std.math.clamp(pan, 0, 127);
    const half = @divTrunc(avail, 2);
    // 64 = 0；127 = +half；0 = −half
    return @divTrunc((p - 64) * half, 63);
}

/// 鼠标 y → 声像（中线 `mid_y`；上 = 右）。中线 ±2 单位吸附回 64（好居中）。
pub fn panFromY(mouse_y: i32, mid_y: i32, avail: i32) i32 {
    const half: i32 = @max(1, @divTrunc(avail, 2));
    const dy: i32 = mid_y - mouse_y; // 上为正
    // round：加半个刻度（正负方向各自取整）
    const adj: i32 = @divTrunc(half, 2);
    const numer: i32 = dy * 63 + (if (dy >= 0) adj else -adj);
    const v: i32 = 64 + @divTrunc(numer, half);
    const c: i32 = std.math.clamp(v, 0, 127);
    if (@abs(c - 64) <= 2) return 64; // 中线吸附
    return c;
}

/// 读音符的当前模式值
fn noteValue(nt: model.Note, mode: NoteLaneMode) i32 {
    return if (mode == .velocity) nt.velocity else nt.pan;
}

/// 写音符的当前模式值（钳制）
fn setNoteValue(nt: *model.Note, mode: NoteLaneMode, v: i32) void {
    if (mode == .velocity) {
        nt.velocity = std.math.clamp(v, 1, 127);
    } else {
        nt.pan = std.math.clamp(v, 0, 127);
    }
}

/// 绘制 + 交互（由 `view_pianoroll.draw` 在音符区之后调用）。
/// 返回 true = 本帧有改动（调用方据此 coalesce 提交历史）。
/// - `lane_x`/`step_ws`/`scroll_s`/`scroll_x`/`zoom`：与音符区**同一帧**的坐标映射
///   （`scroll_s` 屏幕像素 / `scroll_x` 内容像素——由调用方传帧首快照，本函数内含网格绘制）；
/// - `y`/`h`：编辑轨矩形（不含分割条）；`head_w`：轨道头宽（= 琴键列宽）。
pub fn draw(
    ui: *Ui,
    app: *App,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    lane_x: i32,
    step_ws: f32,
    scroll_s: f32,
    scroll_x: i32,
    zoom: f32,
    pattern: i32,
    snap_steps: i32,
) bool {
    const head_x = x;
    const track_x = lane_x;
    const track_w = @max(1, x + w - lane_x);
    // 背景 = 深灰（`bg`；与钢琴卷帘的音符区外底色呼应）
    ui.renderer.fillRect(x, y, w, h, ui.theme.bg);
    ui.renderer.hline(x, y, w, ui.theme.panel_border);
    // 轨道头 / 柱条区的分界（与钢琴卷帘的琴键列分界一致）
    ui.renderer.vline(lane_x, y, h, ui.theme.panel_border);

    // ── 轨道头：模式切换 + 读数 ──
    var mode_changed = false;
    {
        const bh = @min(22, h - 20);
        const bw = util.piano_header_w - 12;
        const bx = head_x + 6;
        const by = y + 4;
        const left_active = app.piano.lane_mode == .velocity;
        if (ui.toggle2(7000, "力度", "声像", left_active, bx, by, bw, bh)) {
            app.piano.lane_mode = if (left_active) .pan else .velocity;
            mode_changed = true;
        }
    }

    // 柱条区
    const top = y + inset;
    const avail = @max(8, h - inset * 2);
    const bar_w = std.math.clamp(@as(i32, @intFromFloat(step_ws * 4)), bar_w_min, bar_w_max);

    // 当前模式（**在 toggle2 之后读**——点击切换本帧就生效）
    const mode = app.piano.lane_mode;
    const in_track = ui.hitRect(track_x, y, track_w, h);

    // ── Alt+滚轮：调力度/声像 ──
    // 有选区 → 全部选中整体增减；否则 → **柱条末端**距鼠标最近的一个。
    // 必须**在绘制之前**处理（本帧柱条就用新值画，不滞后一帧）。
    var wheel_changed = false;
    if (ui.wheel != 0 and ui.wheel_alt and in_track) {
        const near = nearestNoteInLane(app, ui.mouse_x, ui.mouse_y, track_x, step_ws, scroll_s, pattern, bar_w, top, avail, mode);
        wheel_changed = altWheelAdjust(app, mode, ui.wheel, near);
        if (wheel_changed) {
            app.markWheelHistory(if (mode == .velocity) "调整力度" else "调整声像");
        }
        ui.wheel = 0; // 消费（防下层钢琴窗再滚一次）
    }

    // ── 悬停读数（先算，供轨道头显示）──
    var hover_idx: ?usize = null;
    {
        const mi = hitNoteIndex(app, ui.mouse_x, ui.mouse_y, track_x, y, h, step_ws, scroll_s, pattern, bar_w);
        if (mi) |idx| hover_idx = idx;
    }

    // 轨道头第二行：读数（拖动中优先 → 悬停 → “—”）；声像模式显示方向标签
    {
        var buf: [32]u8 = undefined;
        const text: []const u8 = blk: {
            if (ui.active_id == 7001 and app.piano.lane_drag_dirty) {
                const v = valueFromY(mode, ui.mouse_y, top, avail);
                break :blk if (mode == .velocity)
                    std.fmt.bufPrint(&buf, "力度 {d}", .{v}) catch ""
                else
                    panLabel(&buf, v);
            }
            if (hover_idx) |idx| {
                const v = noteValue(app.notes.items[idx], mode);
                break :blk if (mode == .velocity)
                    std.fmt.bufPrint(&buf, "力度 {d}", .{v}) catch ""
                else
                    panLabel(&buf, v);
            }
            break :blk "—";
        };
        ui.label(text, head_x + 8, y + 30, ui.theme.text_dim);
    }

    // ── 网格：纵向与钢琴窗**同参数**（步线/拍线/小节线）；
    //          横向 = 值域参考线（0-127 按 32 分 4 格、每格再按 8 分 4 小格）──
    {
        const saved = ui.renderer.pushClip(track_x, y, track_w, h);
        defer ui.renderer.popClip(saved);
        util.drawTimelineGrid(
            &ui.renderer,
            &ui.theme,
            track_x,
            track_w,
            y,
            h,
            track_x,
            scroll_x, // 帧首快照（与音符区同帧——本函数在缩放补间之后绘制，勿现读 app）
            zoom,
            @floatFromInt(util.piano_step_w),
            app.steps_per_bar,
            model.stepsPerBeat(app.time_den),
            snap_steps,
        );
        // 横向参考线：值与像素映射与柱条**同一公式**（两种模式共用值域坐标——
        // 力度/声像的 32/64/96 在屏幕上同位）。主线 = 32 的倍数（4 格 3 线），
        // 细线 = 8 的倍数（每格 4 小格 3 线；太矮时不画，否则糊成一片）。
        var v: i32 = 8;
        while (v < 127) : (v += 8) {
            const is_major = @mod(v, 32) == 0;
            if (!is_major and avail < 64) continue;
            const ly = if (mode == .velocity)
                top + avail - velBarH(v, avail)
            else
                top + @divTrunc(avail, 2) - panBarH(v, avail);
            if (ly <= top or ly >= top + avail) continue;
            ui.renderer.hline(track_x, ly, track_w, if (is_major) ui.theme.grid_beat else ui.theme.grid_snap);
        }
        // 声像模式：中线（64；比主线更亮）
        if (mode == .pan) {
            const mid_y = top + @divTrunc(avail, 2);
            ui.renderer.hline(track_x, mid_y, track_w, ui.theme.grid_bar);
            // 两端提示：R（上）/ L（下）
            ui.label("R", x + w - 14, top, ui.theme.text_dim);
            ui.label("L", x + w - 14, top + avail - 12, ui.theme.text_dim);
        }
    }

    // ── 柱条绘制：柱体（长→短、未选中→选中）+ 末端白方块（全部置顶）──
    // 叠放规则（后画的盖住先画的）：
    //   ① 柱体：未选中组（长 → 短）→ 选中组（长 → 短）——选中高亮竖线完整可见
    //   ② 末端白方块：**全部柱体之后**统一画（长 → 短）——任何方块
    //      都不被其他音符的竖条遮住（否则选中柱会盖住比它低的方块）
    {
        const saved = ui.renderer.pushClip(track_x, y, track_w, h);
        defer ui.renderer.popClip(saved);
        // 幽灵柱条（**同样式、其它乐器**；灰——只读参考、无交互；画在真实柱条之前）：
        // 与钢琴卷帘的幽灵音符同一约定（同样式其它乐器、不参与命中/拖动）。
        // 力度/声像两种模式共用值域坐标——幽灵与真实柱同几何，仅颜色区分。
        for (app.notes.items) |nt| {
            if (nt.pattern != pattern or nt.instrument == app.sel.instrument) continue;
            const bx = barX(nt.step, track_x, step_ws, scroll_s);
            if (bx + bar_w < track_x or bx > track_x + track_w) continue;
            const v = noteValue(nt, mode);
            const tip_y: i32 = if (mode == .velocity)
                top + avail - velBarH(v, avail)
            else
                top + @divTrunc(avail, 2) - panBarH(v, avail);
            const baseline: i32 = if (mode == .velocity)
                top + avail
            else
                top + @divTrunc(avail, 2);
            const lo = @min(tip_y, baseline);
            const hi = @max(tip_y, baseline);
            ui.renderer.fillRect(bx, lo, bar_w, @max(1, hi - lo + 1), ui.theme.ghost_note);
        }
        // 收集可见柱条（当前样式 + 乐器；x 在视野内），按柱高降序排序
        const LaneBar = struct { idx: usize, len_px: i32, selected: bool };
        var bars: [1024]LaneBar = undefined;
        var n: usize = 0;
        for (app.notes.items, 0..) |nt, i| {
            if (nt.pattern != pattern or nt.instrument != app.sel.instrument) continue;
            const bx = barX(nt.step, track_x, step_ws, scroll_s);
            if (bx + bar_w < track_x or bx > track_x + track_w) continue;
            if (n >= bars.len) break;
            const v = noteValue(nt, mode);
            const len_px: i32 = if (mode == .velocity) velBarH(v, avail) else @intCast(@abs(panBarH(v, avail)));
            bars[n] = .{ .idx = i, .len_px = len_px, .selected = nt.selected };
            n += 1;
        }
        std.mem.sort(LaneBar, bars[0..n], {}, struct {
            fn less(_: void, a: LaneBar, b: LaneBar) bool {
                return a.len_px > b.len_px; // 降序：长的先画、短的叠在上
            }
        }.less);
        const white = r_mod.rgb(240, 250, 244);
        // ① 柱体：未选中组 → 选中组
        for ([_]bool{ false, true }) |want_selected| {
            for (bars[0..n]) |b| {
                if (b.selected != want_selected) continue;
                const nt = app.notes.items[b.idx];
                const v = noteValue(nt, mode);
                const col = if (nt.selected) ui.theme.note_selected else ui.theme.waveform;
                const bx = barX(nt.step, track_x, step_ws, scroll_s);
                const tip_y: i32 = if (mode == .velocity)
                    top + avail - velBarH(v, avail)
                else
                    top + @divTrunc(avail, 2) - panBarH(v, avail);
                const baseline: i32 = if (mode == .velocity)
                    top + avail // 力度：柱从轨道底向上
                else
                    top + @divTrunc(avail, 2); // 声像：从中线双向
                const lo = @min(tip_y, baseline);
                const hi = @max(tip_y, baseline);
                ui.renderer.fillRect(bx, lo, bar_w, @max(1, hi - lo + 1), col);
            }
        }
        // ② 末端白方块：全部置顶（长 → 短，短柱方块最终可见）
        for (bars[0..n]) |b| {
            const nt = app.notes.items[b.idx];
            const v = noteValue(nt, mode);
            const bx = barX(nt.step, track_x, step_ws, scroll_s);
            const tip_y: i32 = if (mode == .velocity)
                top + avail - velBarH(v, avail)
            else
                top + @divTrunc(avail, 2) - panBarH(v, avail);
            ui.renderer.fillRect(bx, tip_y - @divTrunc(bar_w, 2), bar_w, bar_w, white);
        }
        // 悬停：白描边（最后画；方块已在上层，描边只绕柱体轮廓）
        if (hover_idx) |hi_idx| {
            const nt = app.notes.items[hi_idx];
            const v = noteValue(nt, mode);
            const bx = barX(nt.step, track_x, step_ws, scroll_s);
            const tip_y: i32 = if (mode == .velocity)
                top + avail - velBarH(v, avail)
            else
                top + @divTrunc(avail, 2) - panBarH(v, avail);
            const baseline: i32 = if (mode == .velocity)
                top + avail
            else
                top + @divTrunc(avail, 2);
            const lo = @min(tip_y, baseline);
            const hi = @max(tip_y, baseline);
            ui.renderer.strokeRect(bx, lo, bar_w, @max(1, hi - lo + 1), ui.theme.text);
            ui.renderer.fillRect(bx, tip_y - @divTrunc(bar_w, 2), bar_w, bar_w, white);
        }
    }

    // ── 播放游标（贯穿编辑轨）──
    {
        // **平滑小数步**（子步 + 渲染侧前馈/收敛；音频缓冲量化不显——“游标还是抖”的终解）。
        // SONG：与卷帘同法映射到当前片段局部（不在片段内不画）；PAT：局部步。
        var cur_f: f32 = app.cursorDisplay(false);
        var show = true;
        if (app.sel.song_mode) {
            show = false;
            if (model.leftmostClipFor(app.clips.items, pattern)) |c| {
                if (model.clipSongToLocal(c, app.playback.song_step) != null) {
                    cur_f = app.cursorDisplay(true) - @as(f32, @floatFromInt(c.start)) + @as(f32, @floatFromInt(c.offset));
                    show = true;
                }
            }
        }
        if (show) {
            const cx = track_x + @as(i32, @intFromFloat(cur_f * step_ws - scroll_s));
            if (cx >= track_x - 2 and cx <= track_x + track_w + 2) {
                const col = if (app.playing) ui.theme.cursor_play else ui.theme.cursor_idle;
                ui.renderer.vline(cx, y, h, col);
            }
        }
    }

    // ── 交互 ──
    var changed = false;
    const mi = hitNoteIndex(app, ui.mouse_x, ui.mouse_y, track_x, y, h, step_ws, scroll_s, pattern, bar_w);

    // 按下：决定拖动模式（画笔 / 双击重置）
    // **编辑区不改选区**（实测设计：力度/声像编辑不应反过来改音符选区——
    // 选区只能由钢琴窗本身建立/取消）：单击柱条/空白都只启动画笔。
    // **起点不必在柱条上**：编辑区任意位置按下都能启动画笔拖动（横扫
    // 刷过路径上的音符）——只在柱条上才能起拖会让“从空列开始画曲线”失效。
    // 画笔范围 = **按下瞬间**的选区状态（有选中 → 只编辑选中的；否则自由刷）。
    if (ui.mouse_pressed and in_track) {
        app.piano.lane_paint_selected_only = anyNoteSelected(app, pattern);
        if (mi) |idx| {
            if (ui.mouse_double) {
                // 双击：重置默认值（立即提交历史）
                setNoteValue(&app.notes.items[idx], mode, if (mode == .velocity) model.default_velocity else model.default_pan);
                // 该音符成为“上一个”参考（新音符放置沿用其 长度/力度/声像）
                app.piano.rememberNote(app.notes.items[idx]);
                app.piano.lane_drag_dirty = true;
                changed = true;
            } else {
                app.piano.lane_drag_dirty = false;
                app.piano.lane_last_x = ui.mouse_x;
                app.piano.lane_last_val = valueFromY(mode, ui.mouse_y, top, avail);
                ui.active_id = 7001;
            }
        } else {
            // 空处按下：启动画笔（横扫起点任意；选区存在时仍只编辑选中的）
            app.piano.lane_drag_dirty = false;
            app.piano.lane_last_x = ui.mouse_x;
            app.piano.lane_last_val = valueFromY(mode, ui.mouse_y, top, avail);
            ui.active_id = 7001;
        }
    }

    // 拖动中：绝对画笔（柱条跟鼠标 y 定值；横扫按 x 序**插值补齐**中间列）
    // 注：拖动中**不要求**鼠标在轨内（拖到顶/出界仍继续——
    // `valueFromY` 自行钳制值域，标准拖拽手感）
    if (ui.active_id == 7001 and ui.mouse_down) {
        const target = valueFromY(mode, ui.mouse_y, top, avail);
        // 采样 x 钳到轨内（拖出界时不刷到滚出视野的不可见音符）。
        const last_x = app.piano.lane_last_x;
        const x0 = std.math.clamp(@min(last_x, ui.mouse_x), track_x, track_x + track_w - 1);
        const x1 = std.math.clamp(@max(last_x, ui.mouse_x), track_x, track_x + track_w - 1);
        var sx = x0;
        while (sx <= x1) : (sx += @max(1, bar_w)) {
            if (paintAt(app, sx, target, track_x, step_ws, scroll_s, pattern, bar_w, mode, app.piano.lane_paint_selected_only)) changed = true;
        }
        const mx = std.math.clamp(ui.mouse_x, track_x, track_x + track_w - 1);
        if (paintAt(app, mx, target, track_x, step_ws, scroll_s, pattern, bar_w, mode, app.piano.lane_paint_selected_only)) changed = true;
        app.piano.lane_last_x = ui.mouse_x;
        if (changed) {
            app.piano.lane_drag_dirty = true;
            // 刚画笔编辑的值成为“上一个”参考（与“长度跟随”同一交互逻辑；
            // 新音符放置沿用其 长度/力度/声像）
            switch (mode) {
                .velocity => app.piano.last_note_velocity = target,
                .pan => app.piano.last_note_pan = target,
            }
        }
    }

    // 松手：清拖动状态（历史由调用方经 `history_pending` coalesce 提交）
    if (ui.active_id == 7001 and !ui.mouse_down) {
        ui.active_id = 0;
        app.piano.lane_last_x = -1;
        app.piano.lane_paint_selected_only = false;
        app.piano.lane_drag_dirty = false;
    }

    if (mode_changed) {
        // 模式切换：清拖动残留
        ui.active_id = 0;
        app.piano.lane_last_x = -1;
        app.piano.lane_drag_dirty = false;
    }
    return changed or wheel_changed;
}

/// 声像读数（"R32" / "C" / "L20"）
fn panLabel(buf: []u8, pan: i32) []const u8 {
    const p = std.math.clamp(pan, 0, 127);
    if (p == 64) return "声像 C";
    if (p > 64) return std.fmt.bufPrint(buf, "声像 R{d}", .{p - 64}) catch "";
    return std.fmt.bufPrint(buf, "声像 L{d}", .{64 - p}) catch "";
}

/// 柱条左缘屏幕 x（与音符区同一映射）
fn barX(step: i32, lane_x: i32, step_ws: f32, scroll_s: f32) i32 {
    return lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(step)) * step_ws - scroll_s));
}

/// 命中柱条：返回音符下标（按 x 覆盖范围 + y 在轨道内；优先最近的 x）
fn hitNoteIndex(
    app: *App,
    mouse_x: i32,
    mouse_y: i32,
    track_x: i32,
    y: i32,
    h: i32,
    step_ws: f32,
    scroll_s: f32,
    pattern: i32,
    bar_w: i32,
) ?usize {
    if (mouse_y < y or mouse_y > y + h) return null;
    var best: ?usize = null;
    var best_dx: i32 = std.math.maxInt(i32);
    for (app.notes.items, 0..) |nt, i| {
        if (nt.pattern != pattern or nt.instrument != app.sel.instrument) continue;
        const bx = barX(nt.step, track_x, step_ws, scroll_s);
        // 命中范围放宽 2px（柱条窄时好点中）
        if (mouse_x >= bx - 2 and mouse_x < bx + bar_w + 2) {
            const dx: i32 = @intCast(@abs(mouse_x - (bx + @divTrunc(bar_w, 2))));
            var take = dx < best_dx;
            if (!take and dx == best_dx) {
                if (best) |b| {
                    // 同距（叠放柱条同 x）：层级规则——左端更右 / 数组序更大者在上
                    const bn = app.notes.items[b];
                    if (nt.step > bn.step or (nt.step == bn.step and i > b)) take = true;
                }
            }
            if (take) {
                best_dx = dx;
                best = i;
            }
        }
    }
    return best;
}

/// 鼠标 y → 当前模式的值（力度 / 声像）
fn valueFromY(mode: NoteLaneMode, mouse_y: i32, top: i32, avail: i32) i32 {
    return if (mode == .velocity)
        velFromY(mouse_y, top, avail)
    else
        panFromY(mouse_y, top + @divTrunc(avail, 2), avail);
}

/// 绝对画笔（单点）：把 `mouse_x` 覆盖的柱条刷成 `target`。
/// 返回 true = 有音符被改动。
/// 当前样式 + 乐器下是否有选中的音符（画笔范围判定用）
fn anyNoteSelected(app: *App, pattern: i32) bool {
    for (app.notes.items) |o| {
        if (o.selected and o.pattern == pattern and o.instrument == app.sel.instrument) return true;
    }
    return false;
}

/// 绝对画笔（单点）：把 `mouse_x` 覆盖的柱条刷成 `target`。
/// `selected_only`（按下瞬间判定，见 `draw`）：true = 只编辑选中的柱条；
/// false = 自由刷（画曲线就靠它）。
/// 返回 true = 有音符被改动。
fn paintAt(
    app: *App,
    mouse_x: i32,
    target: i32,
    track_x: i32,
    step_ws: f32,
    scroll_s: f32,
    pattern: i32,
    bar_w: i32,
    mode: NoteLaneMode,
    selected_only: bool,
) bool {
    var changed = false;
    for (app.notes.items) |*nt| {
        if (nt.pattern != pattern or nt.instrument != app.sel.instrument) continue;
        if (selected_only and !nt.selected) continue; // 只编辑选中的
        const bx = barX(nt.step, track_x, step_ws, scroll_s);
        if (mouse_x >= bx - 2 and mouse_x < bx + bar_w + 2) {
            if (noteValue(nt.*, mode) == target) continue; // 已是目标值：跳过
            setNoteValue(nt, mode, target);
            changed = true;
        }
    }
    return changed;
}

/// 滚轮微调步长（每格滚轮改变的值）
pub const wheel_step: i32 = 4;

/// 单步增减 + 跨默认值吸附（B 方案；选区/单音符两分支共用）。
/// 吸附仅对**细调**生效（|dv| ≤ 8 = 最多 2 格滚轮）——大跨度快滚是粗操作，
/// 不该被默认值“磁住”（否则猛滚会被拦在半路；既有测试的 +100 格钳到 127 不变）。
/// 动机：步长 4 与 127/1 的余数不整除（27%4、99%4、63%4 均非 0），纯钳制下
/// 回程会错格——永远回不到 100/64（用户实测复现：**有选中时尤其明显**）。
fn steppedValue(mode: NoteLaneMode, old: i32, dv: i32) i32 {
    var v = old + dv;
    if (@abs(dv) <= 8) {
        const def: i32 = if (mode == .velocity) model.default_velocity else model.default_pan;
        if ((old < def and v >= def) or (old > def and v <= def)) v = def;
    }
    return v;
}

/// Alt+滚轮：调整力度/声像。规则：
/// - 有**选中**音符 → 全部选中的音符整体增减（轮廓基本保持，跨默认值吸附）；
/// - 否则 → 只调**距离鼠标最近**的一个音符（同样吸附）。
/// `nearest` 由调用方算好（钢琴窗/编辑轨的“最近”标准不同——见
/// `nearestNoteInPiano` / `nearestNoteInLane`）。
/// 返回 true = 有改动（调用方用 `markWheelHistory` 记 coalesce 历史）。
pub fn altWheelAdjust(app: *App, mode: NoteLaneMode, delta_steps: i32, nearest: ?usize) bool {
    const dv = delta_steps * wheel_step;
    if (dv == 0) return false;
    // 有选中 → 整体调整
    var any_selected = false;
    for (app.notes.items) |o| {
        if (o.selected) {
            any_selected = true;
            break;
        }
    }
    if (any_selected) {
        // 选区：整体增减（轮廓基本保持）——**同样吸附默认值**（用户实测：有选中时
        // 滚到底再滚回必须也能精确落回 100/64；跨过瞬间多音符可能 1 格参差，
        // 随即恢复同相——一致性优先）。
        for (app.notes.items) |*o| {
            if (!o.selected) continue;
            setNoteValue(o, mode, steppedValue(mode, noteValue(o.*, mode), dv));
        }
        return true;
    }
    if (nearest) |idx| {
        const o = &app.notes.items[idx];
        setNoteValue(o, mode, steppedValue(mode, noteValue(o.*, mode), dv));
        return true;
    }
    return false;
}

/// 钢琴窗：距鼠标最近的音符（距离 = 到音符**矩形**的曼哈顿距离，
/// 鼠标在矩形内则距离 0）。O(n) 扫描——工程音符数千级，单次滚轮事件
/// 完全可接受（只在 alt+滚轮时调用，不是每帧）。
pub fn nearestNoteInPiano(
    app: *App,
    mouse_x: i32,
    mouse_y: i32,
    lane_x: i32,
    lane_y: i32,
    step_ws: f32,
    scroll_s: f32,
    key_h: i32,
    scroll_y: i32,
    pattern: i32,
) ?usize {
    var best: ?usize = null;
    var best_d: i64 = std.math.maxInt(i64);
    for (app.notes.items, 0..) |nt, i| {
        if (nt.pattern != pattern or nt.instrument != app.sel.instrument) continue;
        const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(nt.step)) * step_ws - scroll_s));
        const ny = lane_y + (127 - nt.pitch) * key_h - scroll_y;
        const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(nt.len)) * step_ws)));
        const nh = key_h - 1;
        // 到矩形的距离（点在矩形内 → 0）
        const dx: i64 = if (mouse_x < nx) nx - mouse_x else if (mouse_x >= nx + nw) mouse_x - (nx + nw) else 0;
        const dy: i64 = if (mouse_y < ny) ny - mouse_y else if (mouse_y >= ny + nh) mouse_y - (ny + nh) else 0;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

/// 编辑轨：距鼠标最近的**柱条末端**（距离 = 到末端点的欧氏距离平方）。
/// “末端” = 力度模式的柱条顶 / 声像模式的柱条端（按偏移方向）。
pub fn nearestNoteInLane(
    app: *App,
    mouse_x: i32,
    mouse_y: i32,
    track_x: i32,
    step_ws: f32,
    scroll_s: f32,
    pattern: i32,
    bar_w: i32,
    top: i32,
    avail: i32,
    mode: NoteLaneMode,
) ?usize {
    var best: ?usize = null;
    var best_d: i64 = std.math.maxInt(i64);
    for (app.notes.items, 0..) |nt, i| {
        if (nt.pattern != pattern or nt.instrument != app.sel.instrument) continue;
        const bx = barX(nt.step, track_x, step_ws, scroll_s);
        const cx = bx + @divTrunc(bar_w, 2);
        const v = noteValue(nt, mode);
        const tip_y = if (mode == .velocity)
            top + avail - velBarH(v, avail)
        else
            top + @divTrunc(avail, 2) - panBarH(v, avail);
        const dx: i64 = mouse_x - cx;
        const dy: i64 = mouse_y - tip_y;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

// ── 测试 ──

test "note lane: 力度映射往返与钳制" {
    const avail: i32 = 100;
    // 1 → 1px（最小可见）；127 → 满高
    try std.testing.expectEqual(@as(i32, 1), velBarH(1, avail));
    try std.testing.expectEqual(@as(i32, 100), velBarH(127, avail));
    try std.testing.expectEqual(@as(i32, 0), velBarH(0, avail) - 1); // 0 钳到 1
    try std.testing.expectEqual(@as(i32, 100), velBarH(999, avail));
    // y 往返：底部 → 1；顶部 → 127
    const top: i32 = 10;
    try std.testing.expectEqual(@as(i32, 1), velFromY(top + avail, top, avail));
    try std.testing.expectEqual(@as(i32, 127), velFromY(top, top, avail));
    try std.testing.expectEqual(@as(i32, 64), velFromY(top + @divTrunc(avail, 2), top, avail));
}

test "note lane: 声像映射往返、中线吸附与方向（上 = 右）" {
    const avail: i32 = 100;
    const mid: i32 = 50;
    // 64 = 0 偏移；127 = +50（向上）；0 = −50
    try std.testing.expectEqual(@as(i32, 0), panBarH(64, avail));
    try std.testing.expectEqual(@as(i32, 50), panBarH(127, avail));
    try std.testing.expectEqual(@as(i32, -50), panBarH(0, avail));
    // 上 = 右：中线上方 → pan > 64
    try std.testing.expect(panFromY(mid - 20, mid, avail) > 64);
    try std.testing.expect(panFromY(mid + 20, mid, avail) < 64);
    // 中线附近 ±2 单位吸附回 64
    try std.testing.expectEqual(@as(i32, 64), panFromY(mid - 1, mid, avail));
    try std.testing.expectEqual(@as(i32, 64), panFromY(mid + 1, mid, avail));
    // 两端钳制
    try std.testing.expectEqual(@as(i32, 127), panFromY(mid - 999, mid, avail));
    try std.testing.expectEqual(@as(i32, 0), panFromY(mid + 999, mid, avail));
}

test "note lane: 值读写（钳制）" {
    var nt = model.Note{ .step = 0, .len = 1, .pitch = 60, .pattern = 0 };
    setNoteValue(&nt, .velocity, 0);
    try std.testing.expectEqual(@as(i32, 1), nt.velocity); // 力度 0 不允许
    setNoteValue(&nt, .velocity, 999);
    try std.testing.expectEqual(@as(i32, 127), nt.velocity);
    setNoteValue(&nt, .pan, -5);
    try std.testing.expectEqual(@as(i32, 0), nt.pan);
    setNoteValue(&nt, .pan, 300);
    try std.testing.expectEqual(@as(i32, 127), nt.pan);
    // 模式隔离：改声像不动力度
    try std.testing.expectEqual(@as(i32, 127), nt.velocity);
}

test "note lane: Alt+滚轮——有选区整体增减 / 无选区只调最近" {
    const allocator = std.testing.allocator;
    var app = App{ .allocator = allocator };
    defer app.clips.deinit(allocator);
    defer app.notes.deinit(allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(4);

    // 三个音符：力度均 100
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 });
    app.addNote(.{ .step = 8, .len = 4, .pitch = 64, .pattern = 0 });
    app.addNote(.{ .step = 16, .len = 4, .pitch = 67, .pattern = 0 });

    // 无选区：只调最近（index 1）；滚 +1 → +4
    try std.testing.expect(altWheelAdjust(&app, .velocity, 1, 1));
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].velocity);
    try std.testing.expectEqual(@as(i32, 104), app.notes.items[1].velocity);
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[2].velocity);

    // 无选区 + 无最近 → 无改动
    try std.testing.expect(!altWheelAdjust(&app, .velocity, 1, null));

    // 有选区：整体增减（轮廓保持）——选 0 与 2，滚 −2 → −8
    app.notes.items[0].selected = true;
    app.notes.items[2].selected = true;
    try std.testing.expect(altWheelAdjust(&app, .velocity, -2, 1));
    try std.testing.expectEqual(@as(i32, 92), app.notes.items[0].velocity);
    try std.testing.expectEqual(@as(i32, 104), app.notes.items[1].velocity); // 未选中不动
    try std.testing.expectEqual(@as(i32, 92), app.notes.items[2].velocity);

    // 声像模式（同一函数）：整体 +8（从 64 → 72）
    try std.testing.expect(altWheelAdjust(&app, .pan, 2, null));
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[0].pan);
    try std.testing.expectEqual(@as(i32, 64), app.notes.items[1].pan); // 未选中
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[2].pan);

    // 钳制：整体滚到边界不越界
    try std.testing.expect(altWheelAdjust(&app, .velocity, 100, null));
    try std.testing.expectEqual(@as(i32, 127), app.notes.items[0].velocity);
    try std.testing.expect(altWheelAdjust(&app, .pan, -100, null));
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].pan);
}

test "note lane: Alt+滚轮吸附默认值——滚到底再滚回精确落回（步长 4 不整除也能回）" {
    const allocator = std.testing.allocator;
    var app = App{ .allocator = allocator };
    defer app.clips.deinit(allocator);
    defer app.notes.deinit(allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(4);
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 }); // 力度 100 / 声像 64

    // 上滚到底（钳 127）→ 下滚回来：精确落回 100（跨过时吸附）
    var guard: usize = 0;
    while (app.notes.items[0].velocity < 127 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, 1, 0);
    }
    try std.testing.expectEqual(@as(i32, 127), app.notes.items[0].velocity);
    guard = 0;
    while (app.notes.items[0].velocity > 100 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, -1, 0);
    }
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].velocity);

    // 下滚到底（钳 1）→ 上滚回来：同样精确落回
    guard = 0;
    while (app.notes.items[0].velocity > 1 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, -1, 0);
    }
    try std.testing.expectEqual(@as(i32, 1), app.notes.items[0].velocity);
    guard = 0;
    while (app.notes.items[0].velocity < 100 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, 1, 0);
    }
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].velocity);

    // 声像同样受益（默认 64；步长 4 向上本会错格：127−64=63 不整除）
    guard = 0;
    while (app.notes.items[0].pan < 127 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .pan, 1, 0);
    }
    guard = 0;
    while (app.notes.items[0].pan > 64 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .pan, -1, 0);
    }
    try std.testing.expectEqual(@as(i32, 64), app.notes.items[0].pan);

    // **有选中（单音符选区）也要能滚回默认**——用户实测 bug：此前选区分支不吸附，
    // 点选音符后滚到底再滚回永远落在 99/103（无吸附格点）。
    app.notes.items[0].selected = true;
    guard = 0;
    while (app.notes.items[0].velocity < 127 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, 1, null);
    }
    guard = 0;
    while (app.notes.items[0].velocity > 100 and guard < 200) : (guard += 1) {
        _ = altWheelAdjust(&app, .velocity, -1, null);
    }
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].velocity);
    app.notes.items[0].selected = false;
}

test "note lane: 最近音符判定——钢琴窗（矩形距离）/ 编辑轨（柱条末端距离）" {
    const allocator = std.testing.allocator;
    var app = App{ .allocator = allocator };
    defer app.clips.deinit(allocator);
    defer app.notes.deinit(allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(4);

    // 音符 A：步 0、音高 60；音符 B：步 32、音高 72
    app.addNote(.{ .step = 0, .len = 8, .pitch = 60, .pattern = 0 });
    app.addNote(.{ .step = 32, .len = 8, .pitch = 72, .pattern = 0 });

    // 钢琴窗：鼠标在 A 矩形内（步 2、音高 60）→ 选 A
    const step_ws: f32 = 8.0; // 8px/步
    const key_h: i32 = 10;
    const lane_x: i32 = 100;
    const lane_y: i32 = 50;
    const a_y = lane_y + (127 - 60) * key_h; // A 行顶 y
    const near_a = nearestNoteInPiano(&app, 120, a_y + 3, lane_x, lane_y, step_ws, 0, key_h, 0, 0);
    try std.testing.expectEqual(@as(?usize, 0), near_a);
    // B 附近（步 34 → x = 100+272；音高 72）
    const b_y = lane_y + (127 - 72) * key_h;
    const near_b = nearestNoteInPiano(&app, 380, b_y + 3, lane_x, lane_y, step_ws, 0, key_h, 0, 0);
    try std.testing.expectEqual(@as(?usize, 1), near_b);

    // 编辑轨：力度 A=100（末端高）/ B=40（末端低）
    app.notes.items[0].velocity = 100;
    app.notes.items[1].velocity = 40;
    const track_x: i32 = 100;
    const top: i32 = 0;
    const avail: i32 = 200;
    const bar_w: i32 = 6;
    // 鼠标在底部（y=190）：B 的末端（vel 40 → 高 63 → 末端 y≈137）比 A（高 157 → y≈43）更近
    const bx_b = track_x + @as(i32, @intFromFloat(32 * step_ws)) + @divTrunc(bar_w, 2);
    const near_lane = nearestNoteInLane(&app, bx_b, 190, track_x, step_ws, 0, 0, bar_w, top, avail, .velocity);
    try std.testing.expectEqual(@as(?usize, 1), near_lane);
    // 鼠标在顶部（y=40）：A 的末端（y≈43）更近
    const near_lane2 = nearestNoteInLane(&app, track_x + 2, 40, track_x, step_ws, 0, 0, bar_w, top, avail, .velocity);
    try std.testing.expectEqual(@as(?usize, 0), near_lane2);
}
