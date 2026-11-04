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
//! - 播放中**编辑提交** → （A4 起由快照换代取代，旧的 rescanEdit 机制已删）
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

/// 单次重扫最多覆盖多少步（≈1 小节@1/96、4 小节@1/16）。
/// 动机：整窗（4 小节）重发在密集工程里一次就上千条事件，音频线程 `stashInsert`
/// 每条 O(n) → 毫秒级尖峰 → 掉块（实测"拖动时别的轨卡一下"）。
/// 只重发前面这一段，水位线回退到这里，主循环的前瞻推送（每帧 ≤16 步）会很快补齐。
const max_rescan_steps: i32 = 96;

pub const Scheduler = struct {
    /// **静音轨道**（App 在启动时挂上 `&app.track_muted`；null = 无静音）——
    /// 仅主线程调度钦读（音频线程只消费事件队列，不碰本 struct）
    muted: ?*const TrackMutes = null,
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
pub const Mapped = struct { start: i32, end: i32 };

pub fn mapSong(clip: model.Clip, nt: model.Note) ?Mapped {
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

pub fn mapPat(nt: model.Note) ?Mapped {
    if (nt.pitch < 0 or nt.pitch > 127) return null;
    if (nt.instrument < 0 or nt.instrument >= @as(i32, @intCast(instrument_cap))) return null;
    if (nt.len <= 0) return null;
    return .{ .start = nt.step, .end = nt.step + nt.len };
}

fn makeEv(nt: model.Note, kind: synth.EventKind, step: i32, sched: *const Scheduler, on_step: i32, end_step: i32) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(nt.pitch),
        .instrument = @intCast(nt.instrument),
        .step = step,
        .on_step = on_step,
        .end_step = end_step,
        .gen = sched.gen,
        .velocity = @intCast(std.math.clamp(nt.velocity, 1, 127)),
        .pan = @intCast(std.math.clamp(nt.pan, 0, 127)),
    };
}

/// 构造一条调度事件（Pull 快照对拍用；规则与 `makeEv` **完全一致**——
/// 两边必须共用同一处实现，否则对拍会因“钳位/默认值”分叉而假失败）。
pub fn makeEvent(
    kind: synth.EventKind,
    pitch: i32,
    instrument: i32,
    step: i32,
    sched: *const Scheduler,
    on_step: i32,
    end_step: i32,
    velocity: i32,
    pan: i32,
) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(pitch),
        .instrument = @intCast(instrument),
        .step = step,
        .on_step = on_step,
        .end_step = end_step,
        .gen = sched.gen,
        .velocity = @intCast(std.math.clamp(velocity, 1, 127)),
        .pan = @intCast(std.math.clamp(pan, 0, 127)),
    };
}

/// 差分事件（跨游标实例的新增/移除——只有音高/乐器，无完整音符）。
fn makeKeyEv(pitch: i32, instrument: i32, kind: synth.EventKind, step: i32, sched: *const Scheduler, on_step: i32) synth.SchedEvent {
    return .{
        .kind = kind,
        .pitch = @intCast(pitch),
        .instrument = @intCast(instrument),
        .step = step,
        .on_step = on_step,
        .gen = sched.gen,
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
pub fn gatherRange(
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
            if (clip.isAudio()) continue; // 音频片段不是样式实例：不参与音符调度
            // 静音轨道：**不再整个片段跳过**（那会连 off 一起丢 → 正在响的音挂住），
            // 改为只跳过 on（与音符/片段静音同一规则）
            const track_muted = if (sched.muted) |mu| mu.contains(clip.track) else false;
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = mapSong(clip, nt) orelse continue;
                // 静音：**on / off 都不发**。
                // 早先的“只跳过 on、off 照发”是为了给“刚变静音时正在响的音”兜底，
                // 但那类释音现在由**换代对账**（`audio.reconcileVoices`）精确负责；留下 off 反而有害：
                // 音频按 (音高, 乐器) 释音，**同一 (音高,乐器) 在其它轨上正响**时会被切掉
                // （实测：拖动静音轨里的片段 → 别的轨同音高音符断音/只响音头）。
                const muted = nt.muted or clip.muted or track_muted;
                if (muted) continue;
                // off 仍然发（提前终止/精确定时用），但**不再是唯一保障**：
                // 音频线程会按 on 携带的 `end_step` 本地到点释放（见 renderBlock），
                // 所以即使这条 off 在重扫/丢弃里丢了，也不会挂音。
                if (m.start >= from and m.start < to) {
                    if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched, m.start, m.end))) return false;
                }
                if (m.end >= from and m.end < to) {
                    if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched, m.start, -1))) return false;
                }
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = mapPat(nt) orelse continue;
            if (nt.muted) continue; // 静音：on / off 都不发（同上：off 会误伤其它轨同音高声部）
            if (m.start >= from and m.start < to) {
                if (!pushEv(evs, n, makeEv(nt, .on, m.start, sched, m.start, m.end))) return false;
            }
            if (m.end >= from and m.end < to) {
                if (!pushEv(evs, n, makeEv(nt, .off, m.end, sched, m.start, -1))) return false;
            }
        }
    }
    return true;
}

/// 开始播放 / 跳转：作废旧事件（gen 递增）、重置调度窗口，
/// 并为跨起点的长音符补发 note-on。
/// 开始播放 / 跳转：**只推进 `gen`**。
/// 音频线程看到 `gen` 变化 → 丢弃 stash 待触发事件、重置 `snap_step`，
/// 并从快照补发“已跨过游标的长音符”（见 `docs/scheduler-protocol.md` §11.8）。
/// A4：本函数不再发事件（旧的 `gatherMidOns` 补发由快照侧接管）。
pub fn reset(sched: *Scheduler) void {
    sched.gen +%= 1;
}

// ── 测试 ──

fn drainAll(q: *synth.SchedQueue, out: []synth.SchedEvent) usize {
    return q.drain(out);
}

test "sequencer: 静音音符 on / off 都不发（避免误切其它轨）" {
    const testing = std.testing;
    const clips = [_]model.Clip{.{ .track = 0, .start = 0, .len = 96, .pattern = 0 }};
    const notes = [_]model.Note{
        .{ .step = 0, .len = 48, .pitch = 60, .pattern = 0, .instrument = 0 }, // 正常
        .{ .step = 0, .len = 48, .pitch = 64, .pattern = 0, .instrument = 0, .muted = true }, // 静音
    };
    var sched = Scheduler{};
    var evs: [64]synth.SchedEvent = undefined;
    var n: usize = 0;
    try testing.expect(gatherRange(&evs, &n, &clips, &notes, true, 0, 0, 96, &sched));
    var ons: usize = 0;
    var offs: usize = 0;
    for (evs[0..n]) |ev| {
        if (ev.kind == .on) ons += 1;
        if (ev.kind == .off) offs += 1;
    }
    // 2 个音符：静音的那个 **on / off 都不产生**（off 会误切其它轨同音高声部）
    try testing.expectEqual(@as(usize, 1), ons);
    try testing.expectEqual(@as(usize, 1), offs);
}
