//! 序列器调度：把音符按时间转换为**带步时间戳的调度事件**（纯逻辑，可单测）。
//!
//! 设计：
//! - UI 线程每帧调用 `scheduleRange`，把 `[scheduled_upto, 当前步 + lookahead)`
//!   窗口内的音符开关事件推入 `SchedQueue`；
//! - 音频线程按播放步边界精确触发（时序不受 UI 帧率抖动影响）；
//! - transport 变化（开始/跳转）→ `reset`：gen 递增作废旧事件，并为
//!   「跨起点的长音符」补发 note-on（从音符中间开始播放会触发它）；
//! - 保位模式切换 → `switchMode`：gen 递增（**软切换**——音频不释放声部，
//!   见 `Params.sched_gen_soft`），旧模式@旧游标 vs 新模式@新游标差分
//!   （匹配不发事件）+ 窗口重扫；调用方负责 gen 递增与发布顺序（先 gen 后事件）；
//! - 播放中**编辑提交** → `rescanForEdit`：`edit_gen` 递增（音频线程作废
//!   **未触发**的旧事件，但**不**打断在响声部），跨游标实例差分补 on/off，
//!   并按新数据重扫 `[安全界, 水位线)`（安全界 = 音频**确定没走到**的步，
//!   见 `App.rescanSafeFromStep`；从 UI 游标起重发会双触发 → 悬挂）。
//!   水位线只前进不回头——不重扫的话，新增/移动/删除/改值到“已扫过窗口”
//!   的音符永远不会被调度（实测 bug：播放中放置/克隆/粘贴到游标前方的
//!   音符不响；改力度同理）。
//!
//! 坐标：全局步（0 = 第 1 小节第 1 步；每小节 16 步）。
//! - SONG：片段窗口 = `[(bar-1)*16, (bar-1)*16 + len*16)`；音符全局位置 =
//!   `片段起点 + (局部步 − offset*16)`；被窗口截断的音符只响露出部分；
//! - PAT：局部步即时间（不做片段换算）。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");

/// 静音轨道集合（App 持有；稀疏行号集合）——SONG 调度时跳过其全部片段
pub const TrackMutes = std.AutoHashMapUnmanaged(i32, void);

/// 乐器索引上限（App 按音频容量维护；超出的音符视为无效）。
/// 只由主线程调度/重扫读取——音频线程只消费事件队列，不读本变量。
pub var instrument_cap: usize = synth.max_instruments;

pub const Scheduler = struct {
    /// 已调度到的步（exclusive；下一个未调度的步）
    scheduled_upto: i32 = 0,
    /// **静音轨道**（App 在启动时挂上 `&app.track_muted`；null = 无静音）——
    /// 仅主线程调度钦读（音频线程只消费事件队列，不碰本 struct）
    muted: ?*const TrackMutes = null,
    /// generation（transport 变化时递增；音频线程据此丢弃旧事件）
    gen: u32 = 1,
    /// 编辑代（播放中编辑重扫时递增）：音频线程据此丢弃**未触发**的旧事件，
    /// 但**不**打断在响声部——与 `gen` 的区别（那个会全部释音）。
    /// 见 `rescanForEdit`。
    edit_gen: u32 = 1,
    /// 最近一次重扫的起点（`rescanForEdit` 写入；调用方发布给音频线程，
    /// 供其判定“旧事件是否已被重发替换”——见 `audio.schedEventObsolete`）
    rescan_from: i32 = 0,
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
    if (nt.instrument < 0 or nt.instrument >= @as(i32, @intCast(instrument_cap))) return null;
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
    if (nt.instrument < 0 or nt.instrument >= @as(i32, @intCast(instrument_cap))) return null;
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

/// 收集 [from, to) 窗口内的音符开关事件（扫描**整个**数组，不提前退出）。
/// 规则：on 在 `start` 落入窗口时发；off 在 `end` 落入窗口时发。
/// 返回 false = 事件数超缓冲上限（**收集不完整**）。
///
/// 为什么必须返回“完整/不完整”：扫描是**数组序**（≈ note-off 时间序，
/// 非步序）——缓冲满时数组靠后的音符可能尚未扫到（它们的步值可能很小）；
/// 此时若推进水位线，这批事件将**永久丢失**（实测 bug：大 MIDI 导入后
/// 某些起始位置“卡音 / 整段静音”）。
fn gatherRange(
    evs: []synth.SchedEvent,
    n: *usize,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    from: i32,
    to: i32,
    sched: *const Scheduler,
) bool {
    if (song_mode) {
        for (clips) |clip| {
            if (sched.muted) |mu| {
                if (mu.contains(clip.track)) continue; // 静音轨道：其片段不调度
            }
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                if (m.start >= from and m.start < to) {
                    if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched))) return false;
                }
                if (m.end >= from and m.end < to) {
                    if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched))) return false;
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (m.start >= from and m.start < to) {
                if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched))) return false;
            }
            if (m.end >= from and m.end < to) {
                if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched))) return false;
            }
        }
    }
    return true;
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
            if (sched.muted) |mu| {
                if (mu.contains(clip.track)) continue; // 静音轨道：不补挂音符
            }
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

/// 调度 [from, to) 窗口（推入队列）。
///
/// **正确性**：推进水位线前，窗口内的事件必须**全部**发出——扫描是
/// 数组序（≈ note-off 时间序），非步序；缓冲满时数组靠后的音符可能
/// 尚未扫到（步值可能很小）。旧实现“截断到已收集最大步 + 1”会把这批
/// 音符的事件**永久跳过**：实测 bug——导入音符密集的多通道 MIDI
///（13 通道）后从某些位置起播，数组中靠后的通道要么 on 丢失
///（整段静音）、要么 off 丢失（卡音）。
///
/// 做法：把窗口切成**子区间**，完整收集一个子区间才推进水位线；
/// 溢出时子区间减半重扫（对数收敛；现实数据 1-2 次即可）。
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
    var cur = from;
    while (cur < to) {
        var sub_len: i32 = to - cur;
        while (true) {
            const sub_to = @min(to, cur + sub_len);
            var n: usize = 0;
            if (gatherRange(&evs, &n, clips, notes, song_mode, pattern, cur, sub_to, sched)) {
                // 完整收集：排序 + 推入 + 推进水位线
                std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
                for (evs[0..n]) |ev| queue.push(ev);
                cur = sub_to;
                sched.scheduled_upto = cur;
                break;
            }
            if (sub_len <= 1) {
                // 单步仍溢出（单步事件数 > 512；现实不可达）：
                // 尽力发出已收集部分并前进，防死循环
                std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
                for (evs[0..n]) |ev| queue.push(ev);
                cur += 1;
                sched.scheduled_upto = cur;
                break;
            }
            sub_len = @max(1, @divTrunc(sub_len, 2));
        }
    }
}

/// 播放中**编辑提交**后的调度重扫（水位线只前进不回头——见 `scheduleRange`）。
///
/// 已扫过窗口里的事件早已入队：新增/移动/删除/改值都不会反映到它们
/// （表现：播放中放置/克隆/粘贴的音符不响、改力度不生效）。
///
/// 步骤：
/// 1. `edit_gen` 递增——音频线程作废**未触发**的旧事件（丢弃），但**不**
///    释放声部（在响的音符保持发声；与 `gen` 递增的区别）；
/// 2. **跨游标差分**（旧数据 vs 新数据，键 = 音高+乐器，按数量）：
///    新增实例 → `on@游标`（立即发声）；移除实例 → `off@游标`
///    （释放正在响的声部；对没在响的是空操作）；
/// 3. 重扫 `[rescan_from, 水位线)`：旧事件已作废，按新数据补齐。
///
/// **`rescan_from` 必须给音频安全界**（见 `App.rescanSafeFromStep`）——
/// 即“音频线程**确定还没走到**的第一步”：
/// - UI 游标来自帧首快照、落后音频线程；从 `游标+1` 重发会把音频
///   **已经触发过**的 on 再发一次（音频对“已过时”事件立即触发）→
///   双声部；而 off 只有一份 → 只释放一个 → **个别音悬挂**
///   （实测 bug：播放中调 EQ（每次提交都重扫）概率出现）；
/// - `(游标, rescan_from)` 区间的旧副本**不重发**：音频侧对这段
///   保留旧副本照常触发（见 `audio.schedEventObsolete` 的步号条件），
///   所以不漏事件；代价是该区间内**新增**的音符首次不响（下一遍会响）。
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
    rescan_from: i32,
) void {
    sched.edit_gen +%= 1;
    // 安全界不许低于 `游标+1`（理论上调用方已保证；钳一下防手滑）
    const from = @max(cur + 1, rescan_from);
    sched.rescan_from = from;

    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;

    // ── 1) 跨游标差分（键 = 音高+乐器；每侧各自去重，每键每侧恰处理一次）──
    // 旧侧：旧多新少 → 移除 → off@cur
    diffSide(&evs, &n, old_clips, old_notes, clips, notes, song_mode, pattern, cur, song_mode, pattern, cur, cur, sched, false);
    // 新侧：新多旧少 → 新增 → on@cur
    diffSide(&evs, &n, clips, notes, old_clips, old_notes, song_mode, pattern, cur, song_mode, pattern, cur, cur, sched, true);

    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);

    // ── 2) 重扫 [from, 水位线)：补齐被作废的窗口事件（`from` 之前的旧副本
    //        由音频侧保留触发——见函数注释）──
    const watermark = sched.scheduled_upto;
    if (watermark > from) {
        scheduleRange(sched, queue, clips, notes, song_mode, pattern, from, watermark);
    }
}

/// `rescanForEdit`/`switchMode` 的差分单侧：遍历 `side_notes` 中**本侧首次
/// 出现**的（音高, 乐器）键，计算两侧跨游标实例数差（两侧的模式/游标可不同：
/// 编辑重扫时同侧同游标；模式切换时旧模式@旧游标 vs 新模式@新游标）；
/// `emit_on` 时新侧多于旧侧 → 补 `on@emit_step`；否则旧侧多于新侧 → 补
/// `off@emit_step`。（去重是**每侧各自**的：同一键可能在两侧都被处理，
/// 但差值符号唯一，只有一侧会真正发出事件。）
fn diffSide(
    evs: []synth.SchedEvent,
    n: *usize,
    side_clips: []const model.Clip,
    side_notes: []const model.Note,
    other_clips: []const model.Clip,
    other_notes: []const model.Note,
    side_song_mode: bool,
    side_pattern: i32,
    side_cur: i32,
    other_song_mode: bool,
    other_pattern: i32,
    other_cur: i32,
    emit_step: i32,
    sched: *const Scheduler,
    emit_on: bool,
) void {
    // 本侧去重：seen[pitch] 的 bit i = 乐器 i 已处理
    var seen: [128]u32 = [_]u32{0} ** 128;
    for (side_notes) |nt| {
        if (nt.pitch < 0 or nt.pitch > 127) continue;
        if (nt.instrument < 0 or nt.instrument >= @as(i32, @intCast(instrument_cap))) continue;
        const bit = @as(u32, 1) << @intCast(nt.instrument);
        if (seen[@intCast(nt.pitch)] & bit != 0) continue;
        seen[@intCast(nt.pitch)] |= bit;

        const side_c = crossingCount(side_clips, side_notes, side_song_mode, side_pattern, nt.pitch, nt.instrument, side_cur);
        const other_c = crossingCount(other_clips, other_notes, other_song_mode, other_pattern, nt.pitch, nt.instrument, other_cur);
        if (emit_on) {
            // 新侧：新增（新 > 旧）——带**该音符的力度/声像**（跨游标立即发声）
            var k: usize = 0;
            while (k < side_c -| other_c) : (k += 1) {
                var ev = makeEv(nt, .on, emit_step, sched);
                ev.step = emit_step;
                if (!pushEv(evs, n, ev)) return;
            }
        } else {
            // 旧侧：移除（旧 > 新）
            var k: usize = 0;
            while (k < side_c -| other_c) : (k += 1) {
                if (!pushEv(evs, n, makeKeyEv(nt.pitch, nt.instrument, .off, emit_step, sched))) return;
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

/// 保位模式切换（播放中）：换事件源但**不释放声部**（软切换——调用方在
/// gen 递增前置 `params.sched_gen_soft`，并**先发布 gen、再调用本函数**：
/// 否则音频回调恰落在“新事件已入队、新代未发布”的窗口会把它们当旧代作废）。
/// **调用方负责 `gen` 递增**（本函数只推事件 + 维护水位线）。
///
/// 事件构造（旧模式@旧游标 vs 新模式@新游标，键 = 音高+乐器、按实例数）：
/// - 仅旧侧有 → `off@新游标`（释放：如 SONG→PAT 时其他轨的音符）；
/// - 仅新侧有 → `on@新游标`（起音：如 PAT→SONG 时其他轨的音符）；
/// - 两侧匹配（锚映射下就是同一实例）→ **不发事件**：声部继续发声，
///   其 off 由窗口重扫自然补发（end >= 新游标+1，必在窗口内）。
///
/// 窗口重扫 `[新游标+1, 地平线)`：stash 已被 gen 变化清空（旧副本不存在），
/// 必须整段重发；起点 +1 与差分的 on@游标 不重叠（同 `rescanForEdit`）。
pub fn switchMode(
    sched: *Scheduler,
    queue: *synth.SchedQueue,
    clips: []const model.Clip,
    notes: []const model.Note,
    old_song_mode: bool,
    old_pattern: i32,
    old_cur: i32,
    new_song_mode: bool,
    new_pattern: i32,
    new_cur: i32,
    horizon: i32,
) void {
    var evs: [max_gather]synth.SchedEvent = undefined;
    var n: usize = 0;
    // 差分：旧侧（仅旧有 → off@新游标）+ 新侧（仅新有 → on@新游标）
    diffSide(&evs, &n, clips, notes, clips, notes, old_song_mode, old_pattern, old_cur, new_song_mode, new_pattern, new_cur, new_cur, sched, false);
    diffSide(&evs, &n, clips, notes, clips, notes, new_song_mode, new_pattern, new_cur, old_song_mode, old_pattern, old_cur, new_cur, sched, true);
    std.mem.sort(synth.SchedEvent, evs[0..n], {}, synth.schedEventLess);
    for (evs[0..n]) |ev| queue.push(ev);

    sched.scheduled_upto = new_cur;
    if (horizon > new_cur + 1) {
        scheduleRange(sched, queue, clips, notes, new_song_mode, new_pattern, new_cur + 1, horizon);
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
    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &clips, &new_notes, &clips, &old_notes, false, 0, 8, 9);

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

    rescanForEdit(&s, &q, &added_clips, &notes, &old_clips, &notes, true, 0, 8, 9);

    var out: [8]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
}

test "sequencer: 编辑重扫——安全界之前的步不重发（防双触发悬挂）" {
    // 实测 bug：UI 游标来自帧首快照、落后音频线程；从“游标+1”重发会把
    // 音频**已经触发过**的 on 再发一次（音频对过时事件立即触发）→ 双声部；
    // off 只有一份 → 单个释放 → 悬挂（播放中调 EQ 概率出现）。
    // 修法：重扫从**安全界**起；安全界之前的旧副本由音频侧保留触发。
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};
    // 音符 [12, 20)：cur=8、安全界=14 → on@12 在 (cur, 安全界) 内不重发；
    // off@20（>= 安全界）重发；不跨游标（start 12 > 8）→ 无差分事件
    const notes = [_]model.Note{
        .{ .step = 12, .len = 8, .pitch = 60, .pattern = 0 },
    };

    reset(&s, &q, &clips, &notes, false, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, false, 0, 0, 32); // 水位线 = 32
    var out: [8]synth.SchedEvent = undefined;
    _ = drainAll(&q, &out); // 排空初始事件

    rescanForEdit(&s, &q, &clips, &notes, &clips, &notes, false, 0, 8, 14);
    try std.testing.expectEqual(@as(i32, 14), s.rescan_from); // 调用方读此值发布

    const n = drainAll(&q, &out);
    // 只重发 [14, 32)：off@20；on@12（< 14）不重发
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(i32, 20), out[0].step);
}

test "sequencer: 密集窗口不丢事件（gather 溢出子区间收敛）" {
    // 实测 bug（音符密集的多通道 MIDI，13 通道）：窗口内事件数 > 缓冲（512）时，
    // 旧实现把水位线推进到“已收集事件的最大步 + 1”——扫描是**数组序**
    // （≈ note-off 时间序），数组靠后的音符（步值可能很小）被永久跳过：
    // 某些起始位置“卡音 / 整段静音”（典型：数组中靠后的通道）。
    //
    // 构造：1200 个音符**故意倒序**排列（数组序与步序相反——最坏情况），
    // 全部落在小窗口内。新实现必须把它们全部发出，且水位线只推到 to。
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    const clips = [_]model.Clip{};

    var notes_buf: [1200]model.Note = undefined;
    for (&notes_buf, 0..) |*nt, i| {
        // 倒序：数组前面的音符步大、后面的步小（数组序 ≠ 步序）
        const step: i32 = @intCast(1200 - i);
        nt.* = .{ .step = step, .len = 2, .pitch = @intCast(60 + (i % 12)), .pattern = 0 };
    }

    reset(&s, &q, &clips, &notes_buf, false, 0, 0);
    scheduleRange(&s, &q, &clips, &notes_buf, false, 0, 0, 1203);

    // 水位线必须推到 to（完整扫描；旧实现会停在中间某步）
    try std.testing.expectEqual(@as(i32, 1203), s.scheduled_upto);

    // 排空：on + off 各 1200 个（on 在 step∈[0,1203)、off 在 step+2∈[0,1203)——
    // 即 step ∈ 1..1200 的 on 与 step ∈ 1..1198 的 off，再加 step=1199（end=1201）
    // 和 step=1200（end=1202）的 off——共 1200 个 off
    var on_count: usize = 0;
    var off_count: usize = 0;
    var out: [256]synth.SchedEvent = undefined;
    while (true) {
        const n = drainAll(&q, &out);
        if (n == 0) break;
        for (out[0..n]) |ev| {
            if (ev.kind == .on) on_count += 1 else off_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1200), on_count); // 一个不丢
    try std.testing.expectEqual(@as(usize, 1200), off_count);
}

test "sequencer: SONG 静音轨道——其片段不被调度" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    // 两个片段同型（轨 0 / 轨 1，各映射同一音符）——未静音时共 4 个事件
    const clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 32, .pattern = 0 },
        .{ .track = 1, .start = 0, .len = 32, .pattern = 0 },
    };
    const notes = [_]model.Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
    };
    var mutes = TrackMutes{};
    defer mutes.deinit(std.testing.allocator);
    try mutes.put(std.testing.allocator, 1, {});
    s.muted = &mutes; // 轨 1 静音

    reset(&s, &q, &clips, &notes, true, 0, 0);
    scheduleRange(&s, &q, &clips, &notes, true, 0, 0, 64);

    var out: [16]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    try std.testing.expectEqual(@as(usize, 2), n); // 只剩轨 0 的 on/off
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
}

test "sequencer: switchMode——匹配实例不发事件（保声部）、off 由窗口重扫补发" {
    var q = synth.SchedQueue{};
    var s = Scheduler{};
    // 样式0：跨游标长音符（局部 10..18）+ 后续音符（20..24）；样式1：另一条跨游标音符
    const notes = [_]model.Note{
        .{ .step = 10, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 },
        .{ .step = 20, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 },
        .{ .step = 12, .len = 20, .pitch = 64, .pattern = 1, .instrument = 0 },
    };
    // SONG：轨0 样式0 片段 [100,196)；轨1 样式1 片段 [100,196)
    const clips = [_]model.Clip{
        .{ .track = 0, .start = 100, .len = 96, .pattern = 0 },
        .{ .track = 1, .start = 100, .len = 96, .pattern = 1 },
    };
    // SONG@115 → PAT 样式0@15：60 两侧匹配（不发）；64（样式1）仅旧侧 → off@15
    switchMode(&s, &q, &clips, &notes, true, 0, 115, false, 0, 15, 15 + 4 * 96);
    var out: [128]synth.SchedEvent = undefined;
    const n = drainAll(&q, &out);
    var off15 = false;
    var on_at_15 = false;
    var off18 = false; // 匹配实例 60 的 off：**新模式（PAT）坐标**局部 end = 18（窗口重扫补发）
    var on20 = false; // 后续音符 62：局部 on = 20
    for (out[0..n]) |ev| {
        if (ev.step == 15 and ev.kind == .off and ev.pitch == 64) off15 = true;
        if (ev.step == 15 and ev.kind == .on) on_at_15 = true;
        if (ev.step == 18 and ev.kind == .off and ev.pitch == 60) off18 = true;
        if (ev.step == 20 and ev.kind == .on and ev.pitch == 62) on20 = true;
    }
    try std.testing.expect(off15);
    try std.testing.expect(!on_at_15); // **无重击**（旧行为会补 on@游标）
    try std.testing.expect(off18); // 声部不悬挂（off 已续排，新模式坐标）
    try std.testing.expect(on20);
    try std.testing.expectEqual(@as(i32, 15 + 4 * 96), s.scheduled_upto);

    // 反向：PAT 样式0@15 → SONG@115：64 仅新侧 → on@115（起音）；60 匹配（不发）
    var q2 = synth.SchedQueue{};
    var s2 = Scheduler{};
    switchMode(&s2, &q2, &clips, &notes, false, 0, 15, true, 0, 115, 115 + 4 * 96);
    var out2: [128]synth.SchedEvent = undefined;
    const n2 = drainAll(&q2, &out2);
    var on115_64 = false;
    var on115_60 = false;
    for (out2[0..n2]) |ev| {
        if (ev.step == 115 and ev.kind == .on and ev.pitch == 64) on115_64 = true;
        if (ev.step == 115 and ev.kind == .on and ev.pitch == 60) on115_60 = true;
    }
    try std.testing.expect(on115_64); // 其他轨起音
    try std.testing.expect(!on115_60); // 匹配实例不重击
}
