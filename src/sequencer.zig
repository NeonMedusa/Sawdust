//! 序列器调度：把音符按时间转换为**带步时间戳的调度事件**（纯逻辑，可单测）。
//!
//! 设计：
//! - UI 线程每帧调用 `scheduleRange`，把 `[scheduled_upto, 当前步 + lookahead)`
//!   窗口内的音符开关事件推入 `SchedQueue`；
//! - 音频线程按播放步边界精确触发（时序不受 UI 帧率抖动影响）；
//! - transport 变化（开始/跳转）→ `reset`：gen 递增作废旧事件，并为
//!   「跨起点的长音符」补发 note-on（从音符中间开始播放会触发它）；
//! - 播放中**新增内容**（放置/克隆/粘贴）→ `scheduleAdded`：水位线只前进
//!   不回头，落在“已扫过窗口”的新增音符必须补发事件，否则永远不会被调度
//!   （实测 bug：播放中追加到游标前方的音符不响）。
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
    gatherRange(&evs, &n, &max_step, clips, notes, song_mode, pattern, from, to, sched.gen);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);

    // 截断保护：gather 满时只推进到最后一个事件所在步
    if (n >= evs.len) {
        sched.scheduled_upto = @min(to, max_step + 1);
    } else {
        sched.scheduled_upto = to;
    }
}

/// 播放中**新增内容**（放置/克隆/粘贴）的补发调度
/// （水位线只前进不回头——见 `scheduleRange`）：
/// 新增音符/片段落在「已扫过窗口」`[cur, scheduled_upto)` 时，其 on/off
/// 永远不会被 gather 到（实测 bug：播放中追加到游标前方的音符不响）。
///
/// **只补新增、不作废旧事件**——纯增量，无双触发/悬挂风险：
/// - 新增音符映射完全在游标之前（`end <= cur`）→ 跳过（过去的位置不发声）；
/// - 映射 `start >= 水位线` → 跳过（窗口推进时会正常 gather）；
/// - 否则补 `on@max(start, cur)`（跨游标的新增立即发声）；
///   `off@end` 仅当 `end < 水位线`（≥ 水位线的由窗口 gather，避免重复）。
///
/// 补发事件的步序可能落在**已入队事件之前**——音频侧 stash 按步序
/// **插入**（`audio.stashInsert`），否则会被前面的事件挡着、很晚才触发。
///
/// SONG：新增音符经**所有**含其样式的片段映射（与 gather 一致）；
/// 新增片段则把其样式的**全部**音符经该片段映射。
/// PAT：只看新增音符（片段不参与 PAT 播放）。
/// 返回 false = 事件数超缓冲上限（调用方退化为 `reset` 全量重扫）。
pub fn scheduleAdded(
    sched: *Scheduler,
    queue: *synth.SchedQueue,
    clips: []const model.Clip,
    notes: []const model.Note,
    added_clips: []const model.Clip,
    added_notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    cur: i32,
) bool {
    const watermark = sched.scheduled_upto;
    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;

    if (song_mode) {
        // 新增音符：在所有含该样式的片段里补发
        for (clips) |clip| {
            for (added_notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (!pushAdded(&evs, &n, nt, m, cur, watermark, sched.gen)) return false;
            }
        }
        // 新增片段：其样式的全部音符经该片段补发
        // （**跳过新增音符**——它们在上一循环经同一片段已补发，会重复）
        for (added_clips) |clip| {
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                if (noteInList(added_notes, nt)) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (!pushAdded(&evs, &n, nt, m, cur, watermark, sched.gen)) return false;
            }
        }
    } else {
        for (added_notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (!pushAdded(&evs, &n, nt, m, cur, watermark, sched.gen)) return false;
        }
    }
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);
    return true;
}

/// 音符是否在列表中（内容比对；新增去重用）
fn noteInList(list: []const model.Note, nt: model.Note) bool {
    for (list) |o| {
        if (o.step == nt.step and o.len == nt.len and o.pitch == nt.pitch and
            o.pattern == nt.pattern and o.instrument == nt.instrument) return true;
    }
    return false;
}

/// `scheduleAdded` 的单音符事件收集（规则见其文档注释）。
fn pushAdded(evs: []synth.SchedEvent, n: *usize, nt: model.Note, m: Mapped, cur: i32, watermark: i32, gen: u32) bool {
    if (m.end <= cur) return true; // 完全在过去：不发声
    if (m.start >= watermark) return true; // 水位线会扫到
    if (!pushEv(evs, n, makeEv(nt, .on, @max(m.start, cur), gen))) return false;
    if (m.end < watermark) {
        if (!pushEv(evs, n, makeEv(nt, .off, m.end, gen))) return false;
    }
    return true;
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

test "sequencer: 播放中新增音符——已扫过窗口内补发 on/off（复现 bug）" {
    // 水位线已扫到 32、游标在 8；新增音符在 [16,20)（已扫过但还没播到）
    // → 不补发就永远不响（实测 bug：播放中放置/克隆/粘贴的音符不响）
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    const added = [_]model.Note{
        .{ .step = 16, .len = 4, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &.{}, false, 0, 0);
    scheduleRange(&s, &q, &clips, &.{}, false, 0, 0, 32); // 水位线 = 32
    try std.testing.expectEqual(@as(i32, 32), s.scheduled_upto);

    try std.testing.expect(scheduleAdded(&s, &q, &clips, &added, &.{}, &added, false, 0, 8));

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
}

test "sequencer: 播放中新增音符——跨游标立即发声；过去/未扫过不补" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    // 三个新增：① 跨游标 [4,12)（游标 8）；② 完全在过去 [0,4)；
    // ③ 在水位线之后 [40,44)
    const added = [_]model.Note{
        .{ .step = 4, .len = 8, .pitch = 60, .pattern = 0 },
        .{ .step = 0, .len = 4, .pitch = 62, .pattern = 0 },
        .{ .step = 40, .len = 4, .pitch = 64, .pattern = 0 },
    };

    reset(&s, &q, &clips, &.{}, false, 0, 0);
    scheduleRange(&s, &q, &clips, &.{}, false, 0, 0, 32); // 水位线 = 32

    try std.testing.expect(scheduleAdded(&s, &q, &clips, &added, &.{}, &added, false, 0, 8));

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    // 只补 ①：on@8（钳到游标）、off@12
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 8), out[0].step);
    try std.testing.expectEqual(@as(u8, 60), out[0].pitch);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 12), out[1].step);

    // ③ 在水位线之后：窗口推进时正常 gather（不重复补发）
    scheduleRange(&s, &q, &clips, &added, false, 0, 32, 48);
    const n2 = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(@as(i32, 40), out[0].step);
    try std.testing.expectEqual(@as(i32, 44), out[1].step);
}

test "sequencer: 播放中新增片段——其样式音符经新片段补发（SONG）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
    };
    // 新片段 [16,32)，样式 0：音符 → 全局 [16,20)
    const added_clips = [_]model.Clip{
        .{ .track = 0, .start = 16, .len = 16, .pattern = 0 },
    };

    reset(&s, &q, &.{}, &notes, true, 0, 0);
    scheduleRange(&s, &q, &.{}, &notes, true, 0, 0, 64); // 水位线 = 64

    try std.testing.expect(scheduleAdded(&s, &q, &added_clips, &notes, &added_clips, &.{}, true, 0, 8));

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
}

test "sequencer: 新增补发与窗口推进不重复（off 只在窗口内 gather 一次）" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    // 新增音符 [16,40)：跨过水位线 32——on/off 都要正确处理
    const added = [_]model.Note{
        .{ .step = 16, .len = 24, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &.{}, false, 0, 0);
    scheduleRange(&s, &q, &clips, &.{}, false, 0, 0, 32); // 水位线 = 32

    try std.testing.expect(scheduleAdded(&s, &q, &clips, &added, &.{}, &added, false, 0, 8));

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    // on@16 补发；off@40 在**水位线之后**——不补（由窗口推进 gather）
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);

    // 窗口推进到 48：off@40 恰好 gather 一次（不重复）
    scheduleRange(&s, &q, &clips, &added, false, 0, 32, 48);
    const n2 = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(i32, 40), out[0].step);
}
