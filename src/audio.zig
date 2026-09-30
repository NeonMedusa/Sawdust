//! 音频层：miniaudio（单头文件，跨平台）。
//!
//! 线程模型（DAW 的核心架构）：
//! - **音频回调运行在实时线程**：不能分配内存、不能加锁、不能阻塞；
//! - **UI 线程**通过原子变量/无锁队列把参数与事件传给音频线程；
//! - 音频线程把"已播放帧数"用原子变量回传，UI 每帧读取（驱动游标）。
//!
//! 事件分两类：
//! - **立即事件**（`EventQueue`）：试听、all_off——入队即生效；
//! - **调度事件**（`SchedQueue`）：序列器按**步时间戳**提前调度，
//!   音频线程在**样本级**精确触发（块内按事件边界分段渲染）。
//!
//! 每乐器一个独立声部池（`synths`），事件按 `instrument` 路由。

const std = @import("std");
const synth = @import("synth.zig");
const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// UI ↔ 音频线程共享的参数（原子，无锁）
pub const Params = struct {
    /// 主音量 0.0 - 1.0
    volume: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.3),
    /// 是否播放（序列器渲染开关）
    playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 音频线程回传：已播放帧数（UI 读取用于显示播放位置/驱动游标）
    frames_played: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// 采样率（设备初始化后写入；UI 读取用于“帧 → 步”换算）
    sample_rate: u64 = 48000,

    // ── 传输（UI 写、音频线程读）──
    /// BPM（序列器按此把步 → 帧换算；UI 每帧同步）
    bpm: std.atomic.Value(u32) = std.atomic.Value(u32).init(120),
    /// 每拍步数（`U / 分母`；决定“一步”的真实时长；UI 每帧同步）
    steps_per_beat: std.atomic.Value(u32) = std.atomic.Value(u32).init(24),
    /// 播放起点（帧；开始播放/跳转时写入）
    start_frame: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// 播放起点（步；与 start_frame 配对，用于步↔帧换算）
    start_step: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// 调度 generation（reset 时递增；音频线程丢弃旧事件）
    sched_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    // ── 队列与乐器（指针地址稳定）──
    /// 立即事件队列（试听/all_off）
    events: *synth.EventQueue = undefined,
    /// 调度事件队列（序列器）
    sched_events: *synth.SchedQueue = undefined,
    /// 每乐器的合成器参数指针（UI 每帧同步；空槽位 = null）
    synth_ptrs: [synth.max_instruments]std.atomic.Value(?*synth.SynthParams) = [_]std.atomic.Value(?*synth.SynthParams){std.atomic.Value(?*synth.SynthParams).init(null)} ** synth.max_instruments,
    /// 每乐器增益（音量 × 静音；UI 每帧同步）
    instrument_gain: [synth.max_instruments]std.atomic.Value(f32) = blk: {
        var a: [synth.max_instruments]std.atomic.Value(f32) = undefined;
        for (&a) |*g| g.* = std.atomic.Value(f32).init(0.8);
        break :blk a;
    },

    // ── 音频线程回传：正在发声的音高（位掩码，UI 用于播放/试听高亮）──
    /// 音高 0-63（位 = 音高）
    sounding_lo: [synth.max_instruments]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** synth.max_instruments,
    /// 音高 64-127（位 = 音高 − 64）
    sounding_hi: [synth.max_instruments]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** synth.max_instruments,
};

pub const Engine = struct {
    device: ma.ma_device = undefined,
    params: *Params,
    allocator: std.mem.Allocator = undefined,
    sample_rate: u32 = 0,
    initialized: bool = false,
    /// 每乐器一个声部池（**仅音频线程访问**；堆分配——32 池 × 256 声部体积可观）
    synths: []synth.Synth = &.{},
    /// 已取但未到时的调度事件（stash；按步序保留，到时再触发）
    stash: [synth.sched_drain_max]synth.SchedEvent = undefined,
    stash_n: usize = 0,
    /// stash 所属的 generation（gen 变化时整批作废）
    stash_gen: u32 = 1,
    /// 上一块的播放状态（用于检测“播放 → 暂停”下降沿）
    was_playing: bool = false,

    /// 初始化并启动音频设备（默认设备，双声道 f32）
    pub fn init(self: *Engine, params: *Params, allocator: std.mem.Allocator) !void {
        self.params = params;
        self.allocator = allocator;
        self.synths = try allocator.alloc(synth.Synth, synth.max_instruments);
        for (self.synths) |*s| s.* = .{};

        var config = ma.ma_device_config_init(ma.ma_device_type_playback);
        config.playback.format = ma.ma_format_f32;
        config.playback.channels = 2;
        config.sampleRate = 0; // 0 = 用设备默认
        config.dataCallback = dataCallback;
        config.pUserData = self; // 引擎实例（回调里取 params + synths）

        if (ma.ma_device_init(null, &config, &self.device) != ma.MA_SUCCESS) {
            return error.AudioInitFailed;
        }
        self.sample_rate = self.device.sampleRate;
        params.sample_rate = self.device.sampleRate; // UI 读取用（帧 → 步换算）
        if (ma.ma_device_start(&self.device) != ma.MA_SUCCESS) {
            ma.ma_device_uninit(&self.device);
            return error.AudioStartFailed;
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Engine) void {
        if (self.initialized) {
            _ = ma.ma_device_stop(&self.device);
            ma.ma_device_uninit(&self.device);
            self.initialized = false;
        }
        if (self.synths.len > 0) {
            self.allocator.free(self.synths);
            self.synths = &.{};
        }
    }
};

/// 传输边沿处理：**暂停时释放全部声部**。
/// 否则已发声的声部会永远停在 ADSR 的 sustain 段（实测 bug：暂停后音符一直响）。
/// 放在音频层（而非 UI）——任何把 playing 置 false 的路径都会生效。
/// 释音后的尾音仍会被渲染（非播放路径照常 render）。
pub fn transportEdge(engine: *Engine, playing: bool) void {
    if (!playing and engine.was_playing) {
        for (engine.synths) |*s| synth.allOff(s);
    }
    engine.was_playing = playing;
}

/// 回传“正在发声的音高”（位掩码；UI 用于播放/试听高亮）
fn publishSounding(engine: *Engine, params: *Params) void {
    for (0..synth.max_instruments) |i| {
        if (params.synth_ptrs[i].load(.monotonic) == null) {
            params.sounding_lo[i].store(0, .monotonic);
            params.sounding_hi[i].store(0, .monotonic);
            continue;
        }
        var lo: u64 = 0;
        var hi: u64 = 0;
        for (engine.synths[i].voices) |v| {
            if (!synth.isSounding(&v)) continue;
            const p = v.pitch;
            if (p < 0 or p > 127) continue;
            if (p < 64) {
                lo |= @as(u64, 1) << @intCast(p);
            } else {
                hi |= @as(u64, 1) << @intCast(p - 64);
            }
        }
        params.sounding_lo[i].store(lo, .monotonic);
        params.sounding_hi[i].store(hi, .monotonic);
    }
}

/// 触发一个调度事件（音频线程）
fn fireSched(engine: *Engine, ev: synth.SchedEvent) void {
    if (ev.instrument >= synth.max_instruments) return;
    switch (ev.kind) {
        .on => synth.noteOn(&engine.synths[ev.instrument], ev.pitch),
        .off => synth.noteOff(&engine.synths[ev.instrument], ev.pitch),
        .all_off => for (engine.synths) |*s| synth.allOff(s),
    }
}

/// 渲染一个分段（所有乐器叠加；out 已清零）
fn renderSegment(engine: *Engine, params: *Params, out: [*]f32, frames: u32, sr: f32, master: f32) void {
    for (0..synth.max_instruments) |i| {
        const sp = params.synth_ptrs[i].load(.monotonic) orelse continue;
        const g = master * params.instrument_gain[i].load(.monotonic);
        synth.render(sp, &engine.synths[i], out, frames, sr, g, true);
    }
}

/// 音频回调（实时线程）：多乐器合成 + 序列器精确触发。
/// 严格约束：无分配、无锁、无阻塞。
fn dataCallback(
    device: ?*ma.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = input;
    const engine: *Engine = @ptrCast(@alignCast(device.?.pUserData));
    const params = engine.params;
    const out: [*]f32 = @ptrCast(@alignCast(output.?));
    const frames = frame_count;
    const sr: f32 = @floatFromInt(device.?.sampleRate);
    const sr_u64: u64 = device.?.sampleRate;

    // 1) 立即事件（试听 / all_off）
    var evbuf: [synth.drain_max]synth.NoteEvent = undefined;
    const n_imm = params.events.drain(&evbuf);
    for (evbuf[0..n_imm]) |ev| {
        switch (ev.kind) {
            .on => if (ev.instrument < synth.max_instruments) synth.noteOn(&engine.synths[ev.instrument], ev.pitch),
            .off => if (ev.instrument < synth.max_instruments) synth.noteOff(&engine.synths[ev.instrument], ev.pitch),
            .all_off => for (engine.synths) |*s| synth.allOff(s),
        }
    }

    // 2) 清空输出（之后按分段叠加渲染）
    @memset(out[0 .. @as(usize, frames) * 2], 0);

    const master = params.volume.load(.monotonic);
    const playing = params.playing.load(.monotonic);
    const gen = params.sched_gen.load(.monotonic);

    // 暂停边沿：释放全部声部（否则音符永远停在 sustain，实测 bug）
    transportEdge(engine, playing);

    // 3) 非播放：只渲染（试听/释音尾），调度事件不触发
    if (!playing) {
        renderSegment(engine, params, out, frames, sr, master);
        publishSounding(engine, params);
        _ = params.frames_played.fetchAdd(frames, .monotonic);
        return;
    }

    // 4) 播放：stash 管理 + 样本级事件触发
    if (gen != engine.stash_gen) {
        // generation 变化（开始/跳转/停止）：整批作废
        engine.stash_n = 0;
        engine.stash_gen = gen;
    }
    // 尽量多取新事件（stash 有空位时）
    if (engine.stash_n < engine.stash.len) {
        const space = engine.stash.len - engine.stash_n;
        var tmp: [synth.sched_drain_max]synth.SchedEvent = undefined;
        const want = @min(space, tmp.len);
        const got = params.sched_events.drain(tmp[0..want]);
        @memcpy(engine.stash[engine.stash_n .. engine.stash_n + got], tmp[0..got]);
        engine.stash_n += got;
    }

    const abs0 = params.frames_played.load(.monotonic);
    const start_frame = params.start_frame.load(.monotonic);
    const start_step = params.start_step.load(.monotonic);
    // 每步 = 1/(每拍步数) 拍（拍号可变；UI 每帧同步 steps_per_beat）
    const bpm: u64 = @max(20, params.bpm.load(.monotonic));
    const spb_per_beat: u64 = @max(1, params.steps_per_beat.load(.monotonic));
    const step_frames: u64 = @max(1, sr_u64 * 60 / (bpm * spb_per_beat));

    var done: u32 = 0;
    var si: usize = 0;
    while (done < frames and si < engine.stash_n) {
        const ev = engine.stash[si];
        if (ev.gen != gen) {
            si += 1; // 旧 generation：丢弃
            continue;
        }
        // 事件应在的绝对帧位置
        const ev_frame: i64 = @as(i64, @intCast(start_frame)) +
            (@as(i64, ev.step) - @as(i64, start_step)) * @as(i64, @intCast(step_frames));
        const cur: i64 = @as(i64, @intCast(abs0)) + @as(i64, done);
        if (ev_frame <= cur) {
            fireSched(engine, ev); // 已到时（含“起播前就应触发”的补发事件）
            si += 1;
            continue;
        }
        // 未到时：渲染到事件边界为止
        const off: u64 = @intCast(ev_frame - cur);
        const seg: u32 = @intCast(@min(@as(u64, frames - done), off));
        if (seg == 0) break;
        renderSegment(engine, params, out + done * 2, seg, sr, master);
        done += seg;
    }
    if (done < frames) {
        renderSegment(engine, params, out + done * 2, frames - done, sr, master);
    }

    // 5) stash 压缩（保留未处理的事件）
    if (si > 0) {
        const remaining = engine.stash_n - si;
        std.mem.copyForwards(synth.SchedEvent, engine.stash[0..remaining], engine.stash[si..engine.stash_n]);
        engine.stash_n = remaining;
    }

    // 6) 回传“正在发声的音高”（UI 用于播放/试听高亮）
    publishSounding(engine, params);

    _ = params.frames_played.fetchAdd(frames, .monotonic);
}

test "audio: Params 默认值" {
    var p = Params{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), p.volume.load(.monotonic), 0.001);
    try std.testing.expect(!p.playing.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), p.sched_gen.load(.monotonic));
    try std.testing.expect(p.synth_ptrs[0].load(.monotonic) == null);
}

test "audio: 暂停边沿释放全部声部（修“暂停后音符一直响”）" {
    var params = Params{};
    var engine = Engine{ .params = &params };
    engine.synths = try std.testing.allocator.alloc(synth.Synth, 2);
    defer std.testing.allocator.free(engine.synths);
    for (engine.synths) |*s| s.* = .{};

    // 两个乐器各发一个音（模拟播放中的状态）
    synth.noteOn(&engine.synths[0], 60);
    synth.noteOn(&engine.synths[1], 64);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[1]));

    // 播放中：不触发释音
    transportEdge(&engine, true);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));

    // 暂停下降沿：全部进入释音
    transportEdge(&engine, false);
    var p = synth.SynthParams{};
    p.release.store(0.0, .monotonic); // 1ms 释音
    var buf: [4800 * 2]f32 = undefined; // 0.1s
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    synth.render(&p, &engine.synths[1], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[1]));

    // 持续暂停（无新下降沿）：无副作用
    transportEdge(&engine, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));
}
