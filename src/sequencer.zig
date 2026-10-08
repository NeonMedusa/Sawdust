//! 序列器调度：把音符按时间转换为**带步时间戳的调度事件**（纯逻辑，可单测）。
//!
//! 设计：
//! - UI 线程每帧调用 `scheduleRange`，把 `[scheduled_upto, 当前步 + lookahead)`
//!   窗口内的音符开关事件推入 `SchedQueue`；
//! - 音频线程按播放步边界精确触发（时序不受 UI 帧率抖动影响）；
//! - transport 变化（开始/跳转）→ `reset`：gen 递增作废旧事件，并为
//!   「跨起点的长音符」补发 note-on（从音符中间开始播放会触发它）；
//! - 播放中**编辑提交** → `rescanForEdit`：`edit_gen` 递增（音频线程作废
//!   **未触发**的旧事件，但**不**打断在响声部），跨游标实例差分补 on/off，
//!   并按新数据重扫 `[游标+1, 水位线)`。水位线只前进不回头——不重扫的话，
//!   新增/移动/删除/改值到“已扫过窗口”的音符永远不会被调度
//!   （实测 bug：播放中放置/克隆/粘贴到游标前方的音符不响；改力度同理）。
//!
//! 坐标：全局步（0 = 第 1 小节第 1 步；每小节 16 步）。
//! - SONG：片段窗口 = `[(bar-1)*16, (bar-1)*16 + len*16)`；音符全局位置 =
//!   `片段起点 + (局部步 − offset*16)`；被窗口截断的音符只响露出部分；
//! - PAT：局部步即时间（不做片段换算）。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");

pub const Scheduler = struct {
    /// 已调度到的步（exclusive；下一个未调度的步）
    scheduled_upto: i32 = 0,
    /// generation（transport 变化时递增；音频线程据此丢弃旧事件）
    gen: u32 = 1,
    /// 编辑代（播放中编辑重扫时递增）：音频线程据此丢弃**未触发**的旧事件，
    /// 但**不**打断在响声部——与 `gen` 的区别（那个会全部释音）。
    /// 见 `rescanForEdit`。
    edit_gen: u32 = 1,
};

/// 单次 gather 上限（超出时截断窗口，剩余下一帧再调度）
const max_gather = 512;

fn pushEv(evs: []synth.SchedEvent, n: *usize, ev: synth.SchedEvent) bool {
    if (n.* >= evs.len) return false;
    evs[n.*] = ev;
    n.* += 1;
    return true;
}

/// 把音符映射到全局步（返回 null = 该音符在此上下文中不发声）。
/// SONG：需要片段上下文；PAT：局部步即全局步。
const Mapped = struct { start: i32, end: i32 };

fn mapSong(clip: model.Clip, nt: model.Note) ?Mapped {
    if (nt.pitch < 0 or nt.pitch > 127) return null;
    if (nt.instrument < 0 or nt.instrument >= synth.max_instruments) return null;
    if (nt.len <= 0) return null;
    // 片段与音符同为 **U=96 步**坐标：无需再乘每小节步数
    const clip_start = clip.start;
    const clip_end = clip.start + clip.len;
    const local_lo = clip.offset;
    const gs = clip_start + (nt.step - local_lo);
    const ge = gs + nt.len;
    if (ge <= clip_start or gs >= clip_end) return null; // 完全在片段窗口外
    return .{ .start = @max(gs, clip_start), .end = @min(ge, clip_end) };
}

fn mapPat(nt: model.Note) ?Mapped {
    if (nt.pitch < 0 or nt.pitch > 127) return null;
    if (nt.instrument < 0 or nt.instrument >= synth.max_instruments) return null;
    if (nt.len <= 0) return null;
    return .{ .start = nt.step, .end = nt.step + nt.len };
}

fn makeEv(nt: model.Note, kind: synth.EventKind, step: i32, sched: *const Scheduler) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(nt.pitch),
        .instrument = @intCast(nt.instrument),
        .step = step,
        .gen = sched.gen,
        .edit_gen = sched.edit_gen,
        .velocity = @intCast(std.math.clamp(nt.velocity, 1, 127)),
        .pan = @intCast(std.math.clamp(nt.pan, 0, 127)),
    };
}

/// 差分事件（跨游标实例的新增/移除——只有音高/乐器，无完整音符）。
fn makeKeyEv(pitch: i32, instrument: i32, kind: synth.EventKind, step: i32, sched: *const Scheduler) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(pitch),
        .instrument = @intCast(instrument),
        .step = step,
        .gen = sched.gen,
        .edit_gen = sched.edit_gen,
    };
}

/// 收集 [from, to) 窗口内的音符开关事件。
/// 规则：on 在 `start` 落入窗口时发；off 在 `end` 落入窗口时发
/// （每个事件恰好在它进入窗口的那一帧被调度一次，不重不漏）。
fn gatherRange(
    evs: []synth.SchedEvent,
    n: *usize,
    max_step: *i32,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    from: i32,
    to: i32,
    sched: *const Scheduler,
) void {
    if (song_mode) {
        for (clips) |clip| {
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start >= from and m.start < to) {
                    if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched))) return;
                    max_step.* = @max(max_step.*, m.start);
                }
                if (m.end >= from and m.end < to) {
                    if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched))) return;
                    max_step.* = @max(max_step.*, m.end);
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start >= from and m.start < to) {
                if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched))) return;
                max_step.* = @max(max_step.*, m.start);
            }
            if (m.end >= from and m.end < to) {
                if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched))) return;
                max_step.* = @max(max_step.*, m.end);
            }
        }
    }
}

/// 收集「跨 reset 点」的长音符（严格跨越 `point` 的）的 note-on。
/// 其 note-off 会在窗口推进到 `end` 时由 `gatherRange` 正常发出。
fn gatherMidOns(
    evs: []synth.SchedEvent,
    n: *usize,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    point: i32,
    sched: *const Scheduler,
) void {
    if (song_mode) {
        for (clips) |clip| {
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start < point and point < m.end) {
                    if (!pushEv(evs, n, makeEv(nt, .on, point, sched))) return;
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start < point and point < m.end) {
                if (!pushEv(evs, n, makeEv(nt, .on, point, sched))) return;
            }
        }
    }
}

/// 开始播放 / 跳转：作废旧事件（gen 递增）、重置调度窗口，
/// 并为跨起点的长音符补发 note-on。
pub fn reset(
    sched: *Scheduler,
    queue: *synth.SchedQueue,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    from_step: i32,
) void {
    sched.gen +%= 1;
    sched.scheduled_upto = from_step;

    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;
    gatherMidOns(&evs, &n, clips, notes, song_mode, pattern, from_step, sched);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);
}

/// 调度 [from, to) 窗口（推入队列；已按步排序）。
/// 事件数超过 gather 上限时截断窗口（剩余下一帧继续）。
pub fn scheduleRange(
    sched: *Scheduler,
    queue: *synth.SchedQueue,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    from: i32,
    to: i32,
) void {
    if (to <= from) return;

    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;
    var max_step: i32 = from - 1;
    gatherRange(&evs, &n, &max_step, clips, notes, song_mode, pattern, from, to, sched);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);

    // 截断保护：gather 满时只推进到最后一个事件所在步
    if (n >= evs.len) {
        sched.scheduled_upto = @min(to, max_step + 1);
    } else {
        sched.scheduled_upto = to;
    }
}

/// 播放中**编辑提交**后的调度重扫（水位线只前进不回头——见 `scheduleRange`）。
///
/// 已扫过窗口 `[游标, 水位线)` 里的事件早已入队：新增/移动/删除/改值
/// 都不会反映到它们（表现：播放中放置/克隆/粘贴的音符不响、改力度不生效）。
///
/// 步骤：
/// 1. `edit_gen` 递增——音频线程作废**未触发**的旧事件（丢弃），但**不**
///    释放声部（在响的音符保持发声；与 `gen` 递增的区别）；
/// 2. **跨游标差分**（旧数据 vs 新数据，键 = 音高+乐器，按数量）：
///    新增实例 → `on@游标`（立即发声）；移除实例 → `off@游标`
///    （释放正在响的声部；对没在响的是空操作——`noteOff` 找不到声部
///    就不做任何事）；数量不变（如仅改力度）→ 不补（正在响的声部
///    无法改值，下次触发生效）；
/// 3. 重扫 `[游标+1, 水位线)`：旧事件已作废，按新数据补齐。
///    （从 `游标+1` 起：步 `游标` 的事件音频线程可能已触发，重发会双触发；
///    边界漏触发是单音符一次不响，比悬挂/重触发轻）
///
/// `old_*` = 上一历史快照（差分基准）；无快照时传空切片（差分退化为
/// “全部跨游标实例都算新增”——会重触发跨游标音符，可接受）。
pub fn rescanForEdit(
    sched: *Scheduler,
    queue: *synth.SchedQueue,
    clips: []const model.Clip,
    notes: []const model.Note,
    old_clips: []const model.Clip,
    old_notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    cur: i32,
) void {
    sched.edit_gen +%= 1;

    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;

    // ── 1) 跨游标差分（键 = 音高+乐器；每侧各自去重，每键每侧恰处理一次）──
    // 旧侧：旧多新少 → 移除 → off@cur
    diffSide(&evs, &n, old_clips, old_notes, clips, notes, song_mode, pattern, cur, sched, false);
    // 新侧：新多旧少 → 新增 → on@cur
    diffSide(&evs, &n, clips, notes, old_clips, old_notes, song_mode, pattern, cur, sched, true);

    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);

    // ── 2) 重扫 [cur+1, 水位线)：补齐被作废的窗口事件 ──
    const watermark = sched.scheduled_upto;
    if (watermark > cur + 1) {
        scheduleRange(sched, queue, clips, notes, song_mode, pattern, cur + 1, watermark);
    }
}

/// `rescanForEdit` 的差分单侧：遍历 `side_notes` 中跨游标的音符，对每个
/// **本侧首次出现**的（音高, 乐器）键计算两侧跨游标实例数差；
/// `emit_on` 时新侧多于旧侧 → 补 `on@cur`；否则旧侧多于新侧 → 补 `off@cur`。
/// （去重是**每侧各自**的：同一键可能在两侧都被处理，但差值符号唯一，
/// 只有一侧会真正发出事件。）
fn diffSide(
    evs: []synth.SchedEvent,
    n: *usize,
    side_clips: []const model.Clip,
    side_notes: []const model.Note,
    other_clips: []const model.Clip,
    other_notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    cur: i32,
    sched: *const Scheduler,
    emit_on: bool,
) void {
    // 本侧去重：seen[pitch] 的 bit i = 乐器 i 已处理
    var seen: [128]u32 = [_]u32{0} ** 128;
    for (side_notes) |nt| {
        if (nt.pitch < 0 or nt.pitch > 127) continue;
        if (nt.instrument < 0 or nt.instrument >= synth.max_instruments) continue;
        const bit = @as(u32, 1) << @intCast(nt.instrument);
        if (seen[@intCast(nt.pitch)] & bit != 0) continue;
        seen[@intCast(nt.pitch)] |= bit;

        const side_c = crossingCount(side_clips, side_notes, song_mode, pattern, nt.pitch, nt.instrument, cur);
        const other_c = crossingCount(other_clips, other_notes, song_mode, pattern, nt.pitch, nt.instrument, cur);
        if (emit_on) {
            // 新侧：新增（新 > 旧）——带**该音符的力度/声像**（跨游标立即发声）
            var k: usize = 0;
            while (k < side_c -| other_c) : (k += 1) {
                var ev = makeEv(nt, .on, cur, sched);
                ev.step = cur;
                if (!pushEv(evs, n, ev)) return;
            }
        } else {
            // 旧侧：移除（旧 > 新）
            var k: usize = 0;
            while (k < side_c -| other_c) : (k += 1) {
                if (!pushEv(evs, n, makeKeyEv(nt.pitch, nt.instrument, .off, cur, sched))) return;
            }
        }
    }
}

/// 某（音高, 乐器）在 `cur` 时刻**正在发声**的实例数（映射区间跨游标：
/// `start <= cur < end`）。SONG：经每个含该样式的片段映射（与 gather 一致）。
fn crossingCount(clips: []const model.Clip, notes: []const model.Note, song_mode: bool, pattern: i32, pitch: i32, instrument: i32, cur: i32) usize {
    var c: usize = 0;
    for (notes) |nt| {
        if (nt.pitch != pitch or nt.instrument != instrument) continue;
        if (song_mode) {
            for (clips) |clip| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start <= cur and cur < m.end) c += 1;
            }
        } else {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start <= cur and cur < m.end) c += 1;
        }
    }
    return c;
}

// ── 测试 ──

fn drainAll(q: *synth.SchedQueue, out: []synth.SchedEvent) usize {
    return q.drain(out);
}

test "sequencer: SONG——同一样式的两个片段各播一次" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 32, .pattern = 0 }, // 步 [0, 32)
        .{ .track = 0, .start = 32, .len = 32, .pattern = 0 }, // 步 [32, 64)
    };
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &notes, true, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, true, 0, 0, 64);

    var out: [16]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 0), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 4), out[1].step);
    try std.testing.expectEqual(synth.EventKind.on, out[2].kind);
    try std.testing.expectEqual(@as(i32, 32), out[2].step);
    try std.testing.expectEqual(synth.EventKind.off, out[3].kind);
    try std.testing.expectEqual(@as(i32, 36), out[3].step);
}

test "sequencer: SONG——折叠 offset 与窗口截断" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    // 片段 [0,32)，可见局部 [16,48)：局部 16 → 全局 0
    const clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 32, .pattern = 0, .offset = 16 },
    };
    const notes = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0 }, // → 全局 [0,4)
        .{ .step = 8, .len = 4, .pitch = 62, .pattern = 0 }, // 折叠掉 → 不发声
        .{ .step = 46, .len = 8, .pitch = 64, .pattern = 0 }, // → 全局 [30,38) 被截断到 [30,32)
    };

    reset(&s, &q, &clips, &notes, true, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, true, 0, 0, 64);

    var out: [16]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 4), n); // on@0 off@4 on@30 off@32
    try std.testing.expectEqual(@as(i32, 0), out[0].step);
    try std.testing.expectEqual(@as(i32, 4), out[1].step);
    try std.testing.expectEqual(synth.EventKind.on, out[2].kind);
    try std.testing.expectEqual(@as(i32, 30), out[2].step);
    try std.testing.expectEqual(@as(u8, 64), out[2].pitch);
    try std.testing.expectEqual(synth.EventKind.off, out[3].kind);
    try std.testing.expectEqual(@as(i32, 32), out[3].step); // 被片段窗口截断
}

test "sequencer: PAT——局部步直接作为时间" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 5, .len = 3, .pitch = 67, .pattern = 2 },
        .{ .step = 5, .len = 3, .pitch = 67, .pattern = 3 }, // 不同样式 → 不发声
    };

    reset(&s, &q, &clips, &notes, false, 2, 0);
    scheduleRange(&s, &q, &clips, &notes, false, 2, 0, 16);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, 5), out[0].step);
    try std.testing.expectEqual(@as(i32, 8), out[1].step);
}

test "sequencer: 窗口推进不重不漏" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 }, // on@0 off@4
        .{ .step = 10, .len = 2, .pitch = 62, .pattern = 0 }, // on@10 off@12
    };

    reset(&s, &q, &clips, &notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, false, 0, 0, 8); // 第一窗口
    scheduleRange(&s, &q, &clips, &notes, false, 0, 8, 16); // 第二窗口

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(i32, 0), out[0].step);
    try std.testing.expectEqual(@as(i32, 4), out[1].step);
    try std.testing.expectEqual(@as(i32, 10), out[2].step);
    try std.testing.expectEqual(@as(i32, 12), out[3].step);
}

test "sequencer: reset 为跨起点长音符补发 note-on" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 8, .pitch = 60, .pattern = 0 }, // 跨越点 2
    };

    reset(&s, &q, &clips, &notes, false, 0, 2);
    scheduleRange(&s, &q, &clips, &notes, false, 0, 2, 16);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // 补发的 on 在起点 2；off 在 8
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 2), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 8), out[1].step);
}

test "sequencer: gen 递增作废旧事件" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &notes, false, 0, 0);
    const gen1 = s.gen;
    scheduleRange(&s, &q, &clips, &notes, false, 0, 0, 8);

    reset(&s, &q, &clips, &notes, false, 0, 3); // 跳转 → gen 递增
    try std.testing.expect(s.gen != gen1);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    // 旧事件 gen 落后（会被音频线程丢弃），新补发的 on 用新 gen
    var saw_new_gen = false;
    for (out[0..n]) |ev| {
        if (ev.gen == s.gen) saw_new_gen = true;
    }
    try std.testing.expect(saw_new_gen);
}

test "sequencer: 事件携带力度/声像（钳制到合法范围）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0, .velocity = 64, .pan = 20 },
        .{ .step = 8, .len = 4, .pitch = 62, .pattern = 0, .velocity = 0, .pan = 999 }, // 越界 → 钳制
    };

    reset(&s, &q, &clips, &notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, false, 0, 0, 16);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, 64), out[0].velocity);
    try std.testing.expectEqual(@as(u8, 20), out[0].pan);
    try std.testing.expectEqual(@as(u8, 1), out[2].velocity); // 0 → 1（力度 0 不允许）
    try std.testing.expectEqual(@as(u8, 127), out[2].pan);
}

test "sequencer: 编辑重扫——已扫过窗口内的新增音符补发（带新编辑代）" {
    // 复现 bug：水位线已扫到 32、游标在 8；新增音符在 [16,20)（已扫过
    // 但还没播到）→ 重扫必须补发，否则永远不响
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{};
    const new_notes = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32); // 水位线 = 32
    try std.testing.expectEqual(@as(i32, 32), s.scheduled_upto);

    const gen_before = s.gen;
    const edit_before = s.edit_gen;
    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    try std.testing.expectEqual(gen_before, s.gen); // gen 不变（不释音）
    try std.testing.expect(s.edit_gen != edit_before); // edit_gen 递增
    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
    // 事件带**新**编辑代（音频线程据此作废旧代事件）
    try std.testing.expectEqual(s.edit_gen, out[0].edit_gen);
}

test "sequencer: 编辑重扫——跨游标新增立即发声；过去/未扫过不补" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{};
    // 三个新增：① 跨游标 [4,12)（游标 8）；② 完全在过去 [0,4)；
    // ③ 在水位线之后 [40,44)
    const new_notes = [_]model.Note{
        .{ .step = 4, .len = 8, .pitch = 60, .pattern = 0 },
        .{ .step = 0, .len = 4, .pitch = 62, .pattern = 0 },
        .{ .step = 40, .len = 4, .pitch = 64, .pattern = 0 },
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32); // 水位线 = 32

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    // 差分补 ①：on@8（跨游标立即发声）；重扫 [9,32) 补 ①的 off@12
    // （② 在过去、③ 在水位线外——都不补）
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 8), out[0].step);
    try std.testing.expectEqual(@as(u8, 60), out[0].pitch);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 12), out[1].step);

    // ③ 在水位线之后：窗口推进时正常 gather
    scheduleRange(&s, &q, &clips, &new_notes, false, 0, 32, 48);
    const n2 = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(@as(i32, 40), out[0].step);
    try std.testing.expectEqual(@as(i32, 44), out[1].step);
}

test "sequencer: 编辑重扫——跨游标删除补 off@cur（防悬挂）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    // 旧：一个跨游标音符 [4,12)（游标 8 在中间）→ 正在响
    const old_notes = [_]model.Note{
        .{ .step = 4, .len = 8, .pitch = 62, .pattern = 0 },
    };
    const new_notes = [_]model.Note{}; // 删除

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = drainAll(&q, &out); // 排空初始事件（不干扰断言）

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    const n = drainAll(&q, &out);
    // 差分：off@8（释放正在响的声部）；重扫 [9,32)：无音符 → 无事件
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(u8, 62), out[0].pitch);
    try std.testing.expectEqual(@as(i32, 8), out[0].step);
}

test "sequencer: 编辑重扫——跨游标改力度不重触发（数量不变）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{
        .{ .step = 4, .len = 8, .pitch = 60, .pattern = 0, .velocity = 100 },
    };
    const new_notes = [_]model.Note{
        .{ .step = 4, .len = 8, .pitch = 60, .pattern = 0, .velocity = 40 },
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = drainAll(&q, &out); // 排空初始事件

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    const n = drainAll(&q, &out);
    // 跨游标数量不变 → 无差分事件；重扫 [9,32)：off@12（带新力度；
    // on@4 在过去不重发——正在响的声部保持旧力度，下次触发生效）
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(i32, 12), out[0].step);
}

test "sequencer: 编辑重扫——窗口内未变化音符重发（带新力度，作废旧代）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0, .velocity = 100 },
    };
    const new_notes = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0, .velocity = 55 },
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32); // 水位线 = 32
    var out: [8]synth.SchedEvent = undefined;
    _ = drainAll(&q, &out); // 排空初始事件

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    const n = drainAll(&q, &out);
    // 重扫 [9,32)：on@16/off@20 重发（带新力度 + 新编辑代）
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(@as(u8, 55), out[0].velocity);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
    try std.testing.expectEqual(s.edit_gen, out[0].edit_gen);
}

test "sequencer: 编辑重扫——移动音符（旧位置作废、新位置重发）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0 }, // 窗口内
    };
    const new_notes = [_]model.Note{
        .{ .step = 24, .len = 4, .pitch = 60, .pattern = 0 }, // 移到 24
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = drainAll(&q, &out); // 排空初始事件

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    const n = drainAll(&q, &out);
    // 重扫 [9,32)：on@24/off@28（新位置）；旧位置 16/20 不再出现
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, 24), out[0].step);
    try std.testing.expectEqual(@as(i32, 28), out[1].step);
}

test "sequencer: 编辑重扫——不重复补发（off 只在窗口内 gather 一次）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const old_notes = [_]model.Note{};
    // 新增音符 [16,40)：跨过水位线 32
    const new_notes = [_]model.Note{
        .{ .step = 16, .len = 24, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &old_notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &old_notes, false, 0, 0, 32); // 水位线 = 32

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    // on@16 由重扫补发；off@40 在**水位线之后**——由窗口推进 gather
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);

    // 窗口推进到 48：off@40 恰好 gather 一次（不重复）
    scheduleRange(&s, &q, &clips, &new_notes, false, 0, 32, 48);
    const n2 = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(i32, 40), out[0].step);
}

test "sequencer: 编辑重扫——SONG 模式新增片段其样式音符重扫（跨片段映射）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const old_clips = [_]model.Clip{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
    };
    // 新片段 [16,32)，样式 0：音符 → 全局 [16,20)
    const added_clips = [_]model.Clip{
        .{ .track = 0, .start = 16, .len = 16, .pattern = 0 },
    };

    reset(&s, &q, &old_clips, &notes, true, 0, 0);
    scheduleRange(&s, &q, &old_clips, &notes, true, 0, 0, 64); // 水位线 = 64

    rescanForEdit(&s, &q, &added_clips, &notes, &old_clips, &notes, true, 0, 8);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
}
