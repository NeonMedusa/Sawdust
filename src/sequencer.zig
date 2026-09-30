//! 序列器调度：把音符按时间转换为**带步时间戳的调度事件**（纯逻辑，可单测）。
//!
//! 设计：
//! - UI 线程每帧调用 `scheduleRange`，把 `[scheduled_upto, 当前步 + lookahead)`
//!   窗口内的音符开关事件推入 `SchedQueue`；
//! - 音频线程按播放步边界精确触发（时序不受 UI 帧率抖动影响）；
//! - transport 变化（开始/跳转）→ `reset`：gen 递增作废旧事件，并为
//!   「跨起点的长音符」补发 note-on（从音符中间开始播放会触发它）。
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
};

/// 单次 gather 上限（超出时截断窗口，剩余下一帧再调度）
const max_gather = 512;

fn evLess(_: void, a: synth.SchedEvent, b: synth.SchedEvent) bool {
    if (a.step != b.step) return a.step < b.step;
    // 同一步：off 先于 on（允许同音高快速重触发）
    const pa: u8 = if (a.kind == .off) 0 else 1;
    const pb: u8 = if (b.kind == .off) 0 else 1;
    return pa < pb;
}

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

fn makeEv(nt: model.Note, kind: synth.EventKind, step: i32, gen: u32) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(nt.pitch),
        .instrument = @intCast(nt.instrument),
        .step = step,
        .gen = gen,
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
    gen: u32,
) void {
    if (song_mode) {
        for (clips) |clip| {
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start >= from and m.start < to) {
                    if (!pushEv(evs, n, makeEv(nt, .on, m.start, gen))) return;
                    max_step.* = @max(max_step.*, m.start);
                }
                if (m.end >= from and m.end < to) {
                    if (!pushEv(evs, n, makeEv(nt, .off, m.end, gen))) return;
                    max_step.* = @max(max_step.*, m.end);
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start >= from and m.start < to) {
                if (!pushEv(evs, n, makeEv(nt, .on, m.start, gen))) return;
                max_step.* = @max(max_step.*, m.start);
            }
            if (m.end >= from and m.end < to) {
                if (!pushEv(evs, n, makeEv(nt, .off, m.end, gen))) return;
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
    gen: u32,
) void {
    if (song_mode) {
        for (clips) |clip| {
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start < point and point < m.end) {
                    if (!pushEv(evs, n, makeEv(nt, .on, point, gen))) return;
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start < point and point < m.end) {
                if (!pushEv(evs, n, makeEv(nt, .on, point, gen))) return;
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
    gatherMidOns(&evs, &n, clips, notes, song_mode, pattern, from_step, sched.gen);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, evLess);
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
    gatherRange(&evs, &n, &max_step, clips, notes, song_mode, pattern, from, to, sched.gen);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, evLess);
    for (evs[0..n]) |ev| queue.push(ev);

    // 截断保护：gather 满时只推进到最后一个事件所在步
    if (n >= evs.len) {
        sched.scheduled_upto = @min(to, max_step + 1);
    } else {
        sched.scheduled_upto = to;
    }
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
