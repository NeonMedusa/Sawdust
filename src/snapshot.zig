//! **Pull 模型快照**（`docs/scheduler-protocol.md` §11）：把「片段 × 音符」预先展开成
//! **按步分桶**的音符实例，供音频线程按 block 区间查询（O(块内音符数)，而不是每帧 O(全部音符)）。
//!
//! **当前阶段 = A1**：只**构建 + 对拍**，未接入主路（仍走 push 模型）。
//! 对拍测试要求：同一份数据、同一窗口，快照产出的事件与 `sequencer.gatherRange`
//! **逐字段完全一致**（含 `on_step` / `end_step` / 力度 / 声像 / gen）。
//!
//! 分桶设计：每个实例同时进 `by_start`（发 on）与 `by_end`（发 off）两张索引表，
//! 桶数组按 `step_base` 偏移覆盖数据范围；查询窗口内只碰“起点/终点落在窗口里”的实例。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");
const sequencer = @import("sequencer.zig");

/// 一个“音符实例”：已按片段窗口裁剪好的全局步区间 + 发声参数。
pub const Inst = struct {
    start: i32,
    /// 发声参数（**原始值**，钳位在发事件时做——与 `sequencer.makeEvent` 同一处，防对拍假失败）
    velocity: i32,
    pan: i32,
    end: i32,
    pitch: i32,
    instrument: i32,
    /// 片段所属轨道（PAT 模式 = -1）——A3 用来做**免重建**的静音过滤
    track: i32 = -1,
};

const Range = struct { start: u32, len: u32 };

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// 桶数组覆盖的起始步（桶下标 = step - step_base）
    step_base: i32 = 0,
    steps: usize = 0,
    by_start: []Range = &.{},
    start_idx: []u32 = &.{},
    by_end: []Range = &.{},
    end_idx: []u32 = &.{},
    insts: []Inst = &.{},

    pub fn deinit(self: *Snapshot) void {
        const a = self.allocator;
        if (self.by_start.len > 0) a.free(self.by_start);
        if (self.start_idx.len > 0) a.free(self.start_idx);
        if (self.by_end.len > 0) a.free(self.by_end);
        if (self.end_idx.len > 0) a.free(self.end_idx);
        if (self.insts.len > 0) a.free(self.insts);
        self.* = .{ .allocator = a };
    }

    pub fn instCount(self: *const Snapshot) usize {
        return self.insts.len;
    }

    /// **A3b 对账用**：把 `at_step` 处“应该正在响”的实例下标写进 `out`（返回条数；null = 溢出）。
    /// 判据与 `gatherMidOns` 相同：`start <= at_step < end`。
    pub fn crossingInsts(self: *const Snapshot, out: []u32, at_step: i32) ?usize {
        var n: usize = 0;
        for (self.insts, 0..) |it, i| {
            if (!(it.start <= at_step and it.end > at_step)) continue;
            if (n >= out.len) return null;
            out[n] = @intCast(i);
            n += 1;
        }
        return n;
    }

    /// 起播/跳转后补发“**已跨过游标**的长音符”的 on（与 `sequencer.gatherMidOns` 同语义：
    /// on 落在游标处、带真实 `end_step`）。只在 `snap_step < 0` 的第一个 block 调用一次，
    /// 所以 O(全部实例) 可以接受。
    pub fn gatherMidOns(self: *const Snapshot, out: []synth.SchedEvent, at_step: i32, gen: u32) ?usize {
        var n: usize = 0;
        for (self.insts) |it| {
            if (!(it.start < at_step and it.end > at_step)) continue;
            if (n >= out.len) return null;
            out[n] = .{
                .kind = .on,
                .pitch = @intCast(it.pitch),
                .instrument = @intCast(it.instrument),
                .step = at_step,
                .on_step = it.start,
                .end_step = it.end,
                .gen = gen,
                .velocity = @intCast(std.math.clamp(it.velocity, 1, 127)),
                .pan = @intCast(std.math.clamp(it.pan, 0, 127)),
            };
            n += 1;
        }
        return n;
    }

    /// 影子求值用：只按 `gen` 造事件（音频线程没有 `Scheduler` 实例）。
    pub fn gatherRaw(
        self: *const Snapshot,
        out: []synth.SchedEvent,
        from: i32,
        to: i32,
        gen: u32,
    ) ?usize {
        var n: usize = 0;
        if (to <= from or self.steps == 0) return 0;
        const lo = self.step_base;
        const hi = self.step_base + @as(i32, @intCast(self.steps));
        const f = @max(from, lo);
        const t = @min(to, hi);
        if (t > f) {
            var s = f;
            while (s < t) : (s += 1) {
                const r = self.by_start[@intCast(s - lo)];
                for (self.start_idx[r.start .. r.start + r.len]) |ii| {
                    const it = self.insts[ii];
                    if (n >= out.len) return null;
                    out[n] = .{
                        .kind = .on,
                        .pitch = @intCast(it.pitch),
                        .instrument = @intCast(it.instrument),
                        .step = it.start,
                        .on_step = it.start,
                        .end_step = it.end,
                        .gen = gen,
                        .velocity = @intCast(std.math.clamp(it.velocity, 1, 127)),
                        .pan = @intCast(std.math.clamp(it.pan, 0, 127)),
                    };
                    n += 1;
                }
            }
            s = f;
            while (s < t) : (s += 1) {
                const r = self.by_end[@intCast(s - lo)];
                for (self.end_idx[r.start .. r.start + r.len]) |ii| {
                    const it = self.insts[ii];
                    if (n >= out.len) return null;
                    out[n] = .{
                        .kind = .off,
                        .pitch = @intCast(it.pitch),
                        .instrument = @intCast(it.instrument),
                        .step = it.end,
                        .on_step = it.start,
                        .end_step = -1,
                        .gen = gen,
                        .velocity = @intCast(std.math.clamp(it.velocity, 1, 127)),
                        .pan = @intCast(std.math.clamp(it.pan, 0, 127)),
                    };
                    n += 1;
                }
            }
        }
        return n;
    }

    /// 把 `[from, to)` 窗口内的事件追加进 `out`（返回写入条数；`null` = 缓冲区不够）。
    /// **语义必须与 `sequencer.gatherRange` 一致**（对拍测试钉住）。
    pub fn gather(
        self: *const Snapshot,
        out: []synth.SchedEvent,
        sched: *const sequencer.Scheduler,
        from: i32,
        to: i32,
    ) ?usize {
        var n: usize = 0;
        if (to <= from or self.steps == 0) return 0;
        const lo = self.step_base;
        const hi = self.step_base + @as(i32, @intCast(self.steps));
        const f = @max(from, lo);
        const t = @min(to, hi);
        if (t > f) {
            var s = f;
            const f_off: usize = @intCast(f - lo);
            const t_off: usize = @intCast(t - lo);
            // on：起点落在窗口
            s = f;
            while (s < t) : (s += 1) {
                const r = self.by_start[@intCast(s - lo)];
                for (self.start_idx[r.start .. r.start + r.len]) |ii| {
                    const it = self.insts[ii];
                    if (n >= out.len) return null;
                    out[n] = sequencer.makeEvent(.on, it.pitch, it.instrument, it.start, sched, it.start, it.end, it.velocity, it.pan);
                    n += 1;
                }
            }
            _ = f_off;
            _ = t_off;
            // off：终点落在窗口
            s = f;
            while (s < t) : (s += 1) {
                const r = self.by_end[@intCast(s - lo)];
                for (self.end_idx[r.start .. r.start + r.len]) |ii| {
                    const it = self.insts[ii];
                    if (n >= out.len) return null;
                    out[n] = sequencer.makeEvent(.off, it.pitch, it.instrument, it.end, sched, it.start, -1, it.velocity, it.pan);
                    n += 1;
                }
            }
        }
        return n;
    }
};

/// 构建快照。`mutes` = 静音轨道集合（与 `Scheduler.muted` 同源；null = 无静音）。
pub fn build(
    allocator: std.mem.Allocator,
    clips: []const model.Clip,
    notes: []const model.Note,
    song_mode: bool,
    pattern: i32,
    mutes: ?*const sequencer.TrackMutes,
) !Snapshot {
    var self = Snapshot{ .allocator = allocator };
    errdefer self.deinit();

    // ── 1) 展开实例（与 `gatherRange` **同一套映射/过滤规则**：直接复用 `mapSong/mapPat`）──
    var list: std.ArrayListUnmanaged(Inst) = .empty;
    defer list.deinit(allocator);
    var lo: i32 = std.math.maxInt(i32);
    var hi: i32 = std.math.minInt(i32);

    if (song_mode) {
        for (clips) |clip| {
            if (clip.isAudio()) continue; // 音频片段不是样式实例
            const track_muted = if (mutes) |mu| mu.contains(clip.track) else false;
            for (notes) |nt| {
                if (nt.pattern != clip.pattern) continue;
                const m = sequencer.mapSong(clip, nt) orelse continue;
                if (nt.muted or clip.muted or track_muted) continue;
                try list.append(allocator, .{
                    .start = m.start,
                    .end = m.end,
                    .pitch = nt.pitch,
                    .instrument = nt.instrument,
                    .velocity = nt.velocity,
                    .pan = nt.pan,
                    .track = clip.track,
                });
                lo = @min(lo, m.start);
                hi = @max(hi, m.end);
            }
        }
    } else {
        for (notes) |nt| {
            if (nt.pattern != pattern) continue;
            const m = sequencer.mapPat(nt) orelse continue;
            if (nt.muted) continue;
            try list.append(allocator, .{
                .start = m.start,
                .end = m.end,
                .pitch = nt.pitch,
                .instrument = nt.instrument,
                .velocity = nt.velocity,
                .pan = nt.pan,
            });
            lo = @min(lo, m.start);
            hi = @max(hi, m.end);
        }
    }

    if (list.items.len == 0) return self; // 空工程：steps = 0，gather 恒返回 0

    // ── 2) 分配桶（按数据范围，不整曲分配）──
    const span: i32 = hi - lo;
    if (span <= 0) return self;
    // 桶数组覆盖 **[lo, hi] 闭区间**：off 事件可能正好落在 `hi`（最大终点），
    // 写成 `hi - lo` 会让它越界（实测 panic）。
    const steps: usize = @intCast(span + 1);
    self.step_base = lo;
    self.steps = steps;
    self.insts = try allocator.alloc(Inst, list.items.len);
    @memcpy(self.insts, list.items);
    self.by_start = try allocator.alloc(Range, steps);
    self.by_end = try allocator.alloc(Range, steps);
    @memset(self.by_start, .{ .start = 0, .len = 0 });
    @memset(self.by_end, .{ .start = 0, .len = 0 });
    self.start_idx = try allocator.alloc(u32, self.insts.len);
    self.end_idx = try allocator.alloc(u32, self.insts.len);

    // 计数
    for (self.insts, 0..) |it, i| {
        self.by_start[@intCast(it.start - lo)].len += 1;
        self.by_end[@intCast(it.end - lo)].len += 1;
        _ = i;
    }
    // 前缀和 → 桶起点
    var acc: u32 = 0;
    for (self.by_start) |*r| {
        r.start = acc;
        acc += r.len;
        r.len = 0; // 复用 len 作为“已填数量”计数器
    }
    acc = 0;
    for (self.by_end) |*r| {
        r.start = acc;
        acc += r.len;
        r.len = 0;
    }
    // 填充（保持数组序 → 与 gatherRange 的遍历序一致，便于人工比对）
    for (self.insts, 0..) |it, i| {
        const bs = &self.by_start[@intCast(it.start - lo)];
        self.start_idx[bs.start + bs.len] = @intCast(i);
        bs.len += 1;
        const be = &self.by_end[@intCast(it.end - lo)];
        self.end_idx[be.start + be.len] = @intCast(i);
        be.len += 1;
    }
    return self;
}

// ─────────────────────────── A1 对拍测试 ───────────────────────────

/// 全序比较（`schedEventLess` 不是全序——同 step 同 kind 的并列项可以任意排序，
/// 所以对拍必须按**全字段**排序后比）。
fn lessTotal(_: void, a: synth.SchedEvent, b: synth.SchedEvent) bool {
    if (a.step != b.step) return a.step < b.step;
    const ka: u8 = @backingInt(a.kind);
    const kb: u8 = @backingInt(b.kind);
    if (ka != kb) return ka < kb;
    if (a.pitch != b.pitch) return a.pitch < b.pitch;
    if (a.instrument != b.instrument) return a.instrument < b.instrument;
    if (a.on_step != b.on_step) return a.on_step < b.on_step;
    if (a.end_step != b.end_step) return a.end_step < b.end_step;
    if (a.velocity != b.velocity) return a.velocity < b.velocity;
    return a.pan < b.pan;
}

fn evEql(a: synth.SchedEvent, b: synth.SchedEvent) bool {
    return a.kind == b.kind and a.pitch == b.pitch and a.instrument == b.instrument and
        a.step == b.step and a.on_step == b.on_step and a.end_step == b.end_step and
        a.velocity == b.velocity and a.pan == b.pan and a.gen == b.gen;
}

test "snapshot: A1 对拍——与 gatherRange 逐事件一致（随机工程 × 多窗口）" {
    const alloc = std.testing.allocator;
    sequencer.instrument_cap = 16;
    defer sequencer.instrument_cap = synth.max_instruments;

    var prng = std.Random.DefaultPrng.init(0xA10_FA11);
    const rnd = prng.random();

    var trial: usize = 0;
    while (trial < 40) : (trial += 1) {
        var clips: std.ArrayListUnmanaged(model.Clip) = .empty;
        defer clips.deinit(alloc);
        var notes: std.ArrayListUnmanaged(model.Note) = .empty;
        defer notes.deinit(alloc);
        var mutes = sequencer.TrackMutes{};
        defer mutes.deinit(alloc);

        const song_mode = rnd.boolean();
        const pattern: i32 = @intCast(rnd.intRangeLessThan(u32, 0, 3));

        // 片段：0–6 个（随机起点/长度/偏移/静音，含音频片段）
        const nc = rnd.intRangeLessThan(usize, 0, 7);
        var ci: usize = 0;
        while (ci < nc) : (ci += 1) {
            const is_audio = rnd.intRangeLessThan(u32, 0, 10) == 0;
            var c = model.Clip{
                .track = @intCast(rnd.intRangeLessThan(i32, 0, 4)),
                .start = @intCast(rnd.intRangeLessThan(i32, -8, 64)),
                .len = @intCast(rnd.intRangeLessThan(i32, 1, 40)),
                .pattern = @intCast(rnd.intRangeLessThan(i32, 0, 3)),
                .offset = @intCast(rnd.intRangeLessThan(i32, 0, 8)),
                .muted = rnd.intRangeLessThan(u32, 0, 5) == 0,
            };
            if (is_audio) c.audio_style = 0; // 音频片段：不参与音符调度
            try clips.append(alloc, c);
            if (rnd.intRangeLessThan(u32, 0, 3) == 0) mutes.put(alloc, c.track, {}) catch {};
        }

        // 音符：0–40 个（随机步/长度/音高/乐器/静音，含非法值）
        const nn = rnd.intRangeLessThan(usize, 0, 41);
        var ni: usize = 0;
        while (ni < nn) : (ni += 1) {
            try notes.append(alloc, .{
                .step = @intCast(rnd.intRangeLessThan(i32, -8, 80)),
                .len = @intCast(rnd.intRangeLessThan(i32, -2, 24)),
                .pitch = @intCast(rnd.intRangeLessThan(i32, -2, 130)),
                .pattern = @intCast(rnd.intRangeLessThan(i32, 0, 3)),
                .instrument = @intCast(rnd.intRangeLessThan(i32, 0, 18)),
                .velocity = @intCast(rnd.intRangeLessThan(i32, -3, 130)),
                .pan = @intCast(rnd.intRangeLessThan(i32, -3, 130)),
                .muted = rnd.intRangeLessThan(u32, 0, 6) == 0,
            });
        }

        var snap = try build(alloc, clips.items, notes.items, song_mode, pattern, &mutes);
        defer snap.deinit();

        // 多窗口对拍（含窗口外、跨边界、负步）
        var w: usize = 0;
        while (w < 12) : (w += 1) {
            const from: i32 = @intCast(rnd.intRangeLessThan(i32, -16, 80));
            const to: i32 = from + @as(i32, @intCast(rnd.intRangeLessThan(i32, 0, 48)));

            var sched = sequencer.Scheduler{};
            sched.muted = &mutes;

            var a: [512]synth.SchedEvent = undefined;
            var an: usize = 0;
            const full = sequencer.gatherRange(&a, &an, clips.items, notes.items, song_mode, pattern, from, to, &sched);
            // gatherRange 缓冲不够时返回 false（窗口会被调用方截半重扫）——这里跳过大窗口
            if (!full) continue;

            var b: [512]synth.SchedEvent = undefined;
            const bn = snap.gather(&b, &sched, from, to) orelse {
                std.debug.print("[snapshot] 缓冲不足：from={d} to={d}\n", .{ from, to });
                return error.TestUnexpectedResult;
            };

            std.mem.sort(synth.SchedEvent, a[0..an], {}, lessTotal);
            std.mem.sort(synth.SchedEvent, b[0..bn], {}, lessTotal);

            if (an != bn) {
                std.debug.print("[snapshot] 条数不一致 trial={d} w={d} from={d} to={d}: gather={d} snap={d}\n", .{ trial, w, from, to, an, bn });
                return error.TestUnexpectedResult;
            }
            for (a[0..an], b[0..bn]) |ea, eb| {
                if (!evEql(ea, eb)) {
                    std.debug.print("[snapshot] 事件不一致 trial={d} w={d}: a={{step={d} kind={d} p={d} i={d} on={d} end={d} v={d} pan={d}}} b={{step={d} kind={d} p={d} i={d} on={d} end={d} v={d} pan={d}}}\n", .{
                        trial,   w,                    ea.step,  @backingInt(ea.kind), ea.pitch,   ea.instrument, ea.on_step,  ea.end_step, ea.velocity, ea.pan,
                        eb.step, @backingInt(eb.kind), eb.pitch, eb.instrument,        eb.on_step, eb.end_step,   eb.velocity, eb.pan,
                    });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
