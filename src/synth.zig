//! 减法合成器（**复音 + 序列器调度**）：4 振荡器 + ADSR + 高/低通滤波。
//!
//! - 4 个振荡器：独立开关 / 音量 / 波形（正弦、方波、三角、锯齿、噪声）
//! - ADSR 包络（4 参数；归一化 0-1，内部映射到时间）
//! - 高/低通滤波器：各带开关 + 归一化截止频率（映射 20Hz - 20kHz）
//!
//! **线程模型**：
//! - `SynthParams`：原子参数（UI 写、音频线程读）；
//! - `EventQueue`：无锁 SPSC 队列（**立即事件**：试听、all_off）；
//! - `SchedQueue`：无锁 SPSC 队列（**调度事件**：带步时间戳，音频线程按
//!   播放步边界精确触发——序列器播放的核心）；
//! - `Synth`：声部池（**每乐器一个**，仅音频线程访问）。
//!
//! `render()` 是纯 DSP（无分配、无锁、无阻塞）——可直接单测。

const std = @import("std");

const Atomic = std.atomic.Value;

/// 复音数（每乐器；将来做成可配置/按乐器设置）
pub const max_voices: usize = 256;

/// 最大乐器数（每乐器一个独立声部池）
pub const max_instruments: usize = 32;

/// 立即事件队列容量（UI 每秒推入的事件数远小于此值）
const queue_size: usize = 1024;

/// 调度事件队列容量（UI 按 lookahead 提前调度；数秒的余量）
const sched_capacity: usize = 4096;

/// 每块最多处理的立即事件数
pub const drain_max = 64;

/// 每块最多处理的调度事件数（块大小未知，取足够大避免初始调度积压）
pub const sched_drain_max = 256;

pub const Waveform = enum(u8) {
    sine = 0,
    square = 1,
    triangle = 2,
    sawtooth = 3,
    noise = 4,

    pub fn name(self: Waveform) []const u8 {
        return switch (self) {
            .sine => "正弦",
            .square => "方波",
            .triangle => "三角",
            .sawtooth => "锯齿",
            .noise => "噪声",
        };
    }

    pub fn next(self: Waveform) Waveform {
        return @enumFromInt((@intFromEnum(self) + 1) % waveform_count);
    }
};

pub const waveform_count: u8 = 5;

/// 振荡器数量（2×2 布局）
pub const osc_count: usize = 4;

pub const OscParams = struct {
    enabled: Atomic(bool) = Atomic(bool).init(false),
    /// 0-1
    volume: Atomic(f32) = Atomic(f32).init(0.5),
    /// Waveform（存 u8 便于原子访问）
    waveform: Atomic(u8) = Atomic(u8).init(0),
};

pub const FilterParams = struct {
    enabled: Atomic(bool) = Atomic(bool).init(false),
    /// 归一化截止频率 0-1（映射到 20Hz - 20kHz，指数）
    cutoff: Atomic(f32) = Atomic(f32).init(0.7),
};

pub const SynthParams = struct {
    /// 默认音色：振荡器 1 开启（正弦、音量 0.6）——保证“选中即能出声”
    osc: [osc_count]OscParams = .{
        .{ .enabled = Atomic(bool).init(true), .volume = Atomic(f32).init(0.6) },
        .{},
        .{},
        .{},
    },
    /// ADSR（归一化 0-1；时间映射：1ms - 2s，指数）
    attack: Atomic(f32) = Atomic(f32).init(0.05),
    decay: Atomic(f32) = Atomic(f32).init(0.30),
    sustain: Atomic(f32) = Atomic(f32).init(0.70),
    release: Atomic(f32) = Atomic(f32).init(0.30),

    hpf: FilterParams = .{},
    lpf: FilterParams = .{},
};

// ── 事件 ──

pub const EventKind = enum(u8) {
    /// 按下（分配新声部）
    on,
    /// 松开（该音高的声部进入释音）
    off,
    /// 全部松开（切换乐器/关闭视图/停止等场景；作用于**所有乐器**）
    all_off,
};

/// 立即事件（试听 / 停止）：入队即生效
pub const NoteEvent = struct {
    kind: EventKind = .off,
    pitch: u8 = 0,
    instrument: u8 = 0,
};

/// 调度事件（序列器）：带**步时间戳**，音频线程按播放步边界触发
pub const SchedEvent = struct {
    kind: EventKind = .off,
    pitch: u8 = 0,
    instrument: u8 = 0,
    /// 事件生效的步位置（与 playback 的步坐标一致）
    step: i32 = 0,
    /// 调度 generation（transport 变化时递增；旧事件作废）
    gen: u32 = 0,
};

/// 无锁单生产者单消费者（SPSC）环形队列：UI 线程 push、音频线程 drain。
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buf: [capacity]T = [_]T{.{}} ** capacity,
        /// 写位置（UI 线程）
        write: Atomic(usize) = Atomic(usize).init(0),
        /// 读位置（音频线程）
        read: Atomic(usize) = Atomic(usize).init(0),

        pub fn push(self: *Self, ev: T) void {
            const w = self.write.load(.monotonic);
            const r = self.read.load(.acquire);
            if (w -% r >= capacity) return; // 队列满：丢弃（宁可丢也不阻塞音频）
            self.buf[w % capacity] = ev;
            self.write.store(w + 1, .release);
        }

        /// 排空到 `out`（最多 out.len 条）；返回实际条数。
        pub fn drain(self: *Self, out: []T) usize {
            const w = self.write.load(.acquire);
            var r = self.read.load(.monotonic);
            var n: usize = 0;
            while (r != w and n < out.len) : (r += 1) {
                out[n] = self.buf[r % capacity];
                n += 1;
            }
            self.read.store(r, .release);
            return n;
        }
    };
}

pub const EventQueue = Ring(NoteEvent, queue_size);
pub const SchedQueue = Ring(SchedEvent, sched_capacity);

// ── 声部状态 ──

const EnvStage = enum { idle, attack, decay, sustain, release };

/// 单个声部（**仅音频线程访问**）
pub const Voice = struct {
    /// 当前音高（-1 = 空闲）
    pitch: i32 = -1,
    freq: f32 = 0,
    /// 各振荡器相位 [0,1)
    phase: [osc_count]f32 = .{ 0, 0, 0, 0 },
    env_stage: EnvStage = .idle,
    env_level: f32 = 0,
    /// 进入 release 时的电平（线性下降用）
    release_from: f32 = 0,
    /// 分配序号（无空闲声部时偷取最旧）
    start_seq: u64 = 0,
    /// 高通滤波的“低通分量”状态
    hpf_lp: f32 = 0,
    /// 低通滤波状态
    lpf_lp: f32 = 0,
    /// 噪声用 RNG（xorshift32）
    rng: u32 = 0x9E3779B9,
};

/// 声部池 + 渲染状态（**每乐器一个**；仅音频线程访问）
pub const Synth = struct {
    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
    /// 主音量平滑（防 zipper 噪声）
    smoothed_master: f32 = 0,
    /// 声部分配的轮转起点（避免每次从头扫描）
    next_voice: usize = 0,
    /// 音符序号（声部偷取时的年龄依据）
    note_counter: u64 = 0,
};

/// MIDI 音高 → 频率（Hz）；A4 = 440Hz
pub fn pitchHz(pitch: i32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(pitch - 69)) / 12.0);
}

/// 归一化时间参数 → 秒（0-1 → 1ms - 2s，指数映射）
pub fn mapTime(v: f32) f32 {
    const t = std.math.clamp(v, 0, 1);
    return 0.001 * std.math.pow(f32, 2000.0, t);
}

/// 归一化截止 → Hz（0-1 → 20Hz - 20kHz，指数映射）
pub fn cutoffHz(v: f32) f32 {
    const t = std.math.clamp(v, 0, 1);
    return 20.0 * std.math.pow(f32, 1000.0, t);
}

/// 一阶低通系数（每块计算一次）
fn onePoleCoeff(fc: f32, sr: f32) f32 {
    const f = std.math.clamp(fc, 5.0, sr * 0.45);
    return 1.0 - @exp(-2.0 * std.math.pi * f / sr);
}

/// xorshift32 → [-1, 1)
fn nextNoise(rng: *u32) f32 {
    var x = rng.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng.* = x;
    return @as(f32, @floatFromInt(x >> 8)) / 8388608.0 - 1.0;
}

/// 找空闲声部（轮转扫描）；无空闲时偷取最旧的声部
fn allocVoice(state: *Synth) *Voice {
    var k: usize = 0;
    while (k < max_voices) : (k += 1) {
        const idx = (state.next_voice + k) % max_voices;
        if (state.voices[idx].env_stage == .idle) {
            state.next_voice = (idx + 1) % max_voices;
            return &state.voices[idx];
        }
    }
    // 全部占用：偷最旧
    var oldest: usize = 0;
    for (state.voices, 0..) |v, vi| {
        if (v.start_seq < state.voices[oldest].start_seq) oldest = vi;
    }
    return &state.voices[oldest];
}

/// 音符开（分配声部）——公开：音频回调按事件路由调用
pub fn noteOn(state: *Synth, pitch: u8) void {
    state.note_counter += 1;
    const v = allocVoice(state);
    v.pitch = pitch;
    v.freq = pitchHz(pitch);
    v.env_stage = .attack;
    v.release_from = 0;
    v.start_seq = state.note_counter;
    // 每声部独立的噪声种子（不同音符噪声不相关）
    v.rng = 0x9E3779B9 ^ @as(u32, @truncate(state.note_counter *% 2654435761));
}

/// 音符关（该音高的声部进入释音）
pub fn noteOff(state: *Synth, pitch: u8) void {
    for (state.voices, 0..) |_, vi| {
        const v = &state.voices[vi];
        if (v.pitch == pitch and v.env_stage != .idle and v.env_stage != .release) {
            v.env_stage = .release;
            v.release_from = v.env_level;
        }
    }
}

/// 全部释音
pub fn allOff(state: *Synth) void {
    for (state.voices, 0..) |_, vi| {
        const v = &state.voices[vi];
        if (v.env_stage != .idle and v.env_stage != .release) {
            v.env_stage = .release;
            v.release_from = v.env_level;
        }
    }
}

/// 是否正在发声（含释音尾）——供音频层回传“发声音高”用
pub fn isSounding(v: *const Voice) bool {
    return v.env_stage != .idle;
}

/// 活跃声部数（供测试/调试）
pub fn activeCount(state: *const Synth) usize {
    var n: usize = 0;
    for (state.voices) |v| {
        if (v.env_stage != .idle) n += 1;
    }
    return n;
}

/// 渲染一块交错立体声（该乐器的所有活跃声部 → 主音量 → 软削波）。
/// - `gain`：主音量 × 乐器音量（0 = 静音；平滑防 zipper）
/// - `add`：true = 叠加到 out（多乐器混音）；false = 覆盖（单乐器/测试）
/// 空闲时：`add=false` 写零，`add=true` 不动 out。
pub fn render(
    params: *const SynthParams,
    state: *Synth,
    out: [*]f32,
    frames: u32,
    sample_rate: f32,
    gain: f32,
    add: bool,
) void {
    // ── 活跃声部快照（空闲时快速返回）──
    var active: [max_voices]u16 = undefined;
    var nactive: usize = 0;
    for (state.voices, 0..) |v, vi| {
        if (v.env_stage != .idle) {
            active[nactive] = @intCast(vi);
            nactive += 1;
        }
    }
    if (nactive == 0) {
        if (!add) @memset(out[0 .. @as(usize, frames) * 2], 0);
        return;
    }

    const dt = 1.0 / sample_rate;

    // 包络参数（每块读一次）
    const a_sec = mapTime(params.attack.load(.monotonic));
    const d_sec = mapTime(params.decay.load(.monotonic));
    const r_sec = mapTime(params.release.load(.monotonic));
    const sustain = std.math.clamp(params.sustain.load(.monotonic), 0, 1);

    // 滤波器（每块算一次系数；各声部有自己的滤波状态）
    const hpf_on = params.hpf.enabled.load(.monotonic);
    const lpf_on = params.lpf.enabled.load(.monotonic);
    const hpf_coeff = onePoleCoeff(cutoffHz(params.hpf.cutoff.load(.monotonic)), sample_rate);
    const lpf_coeff = onePoleCoeff(cutoffHz(params.lpf.cutoff.load(.monotonic)), sample_rate);

    // 振荡器快照
    var osc_on: [osc_count]bool = undefined;
    var osc_vol: [osc_count]f32 = undefined;
    var osc_wave: [osc_count]Waveform = undefined;
    for (0..osc_count) |i| {
        osc_on[i] = params.osc[i].enabled.load(.monotonic);
        osc_vol[i] = std.math.clamp(params.osc[i].volume.load(.monotonic), 0, 1);
        osc_wave[i] = @enumFromInt(params.osc[i].waveform.load(.monotonic) % waveform_count);
    }

    // 静默启动/静音恢复：直接跳到目标增益（避免“开头淡入”迟滞）
    if (state.smoothed_master <= 0.0001) state.smoothed_master = gain;

    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        var mix: f32 = 0;
        var a: usize = 0;
        while (a < nactive) : (a += 1) {
            const v = &state.voices[active[a]];

            // ── 包络（线性分段）──
            switch (v.env_stage) {
                .idle => continue,
                .attack => {
                    v.env_level += dt / a_sec;
                    if (v.env_level >= 1.0) {
                        v.env_level = 1.0;
                        v.env_stage = .decay;
                    }
                },
                .decay => {
                    const rate = (1.0 - sustain) / d_sec;
                    v.env_level -= rate * dt;
                    if (v.env_level <= sustain) {
                        v.env_level = sustain;
                        v.env_stage = .sustain;
                    }
                },
                .sustain => v.env_level = sustain,
                .release => {
                    v.env_level -= (v.release_from / r_sec) * dt;
                    if (v.env_level <= 0) {
                        v.env_level = 0;
                        v.env_stage = .idle;
                        continue;
                    }
                },
            }

            // ── 振荡器混音 ──
            var vmix: f32 = 0;
            for (0..osc_count) |o| {
                if (!osc_on[o]) continue;
                const s = switch (osc_wave[o]) {
                    .sine => @sin(v.phase[o] * 2.0 * std.math.pi),
                    .square => if (v.phase[o] < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
                    .triangle => 4.0 * @abs(v.phase[o] - 0.5) - 1.0,
                    .sawtooth => 2.0 * v.phase[o] - 1.0,
                    .noise => nextNoise(&v.rng),
                };
                vmix += s * osc_vol[o];
                if (osc_wave[o] != .noise) {
                    v.phase[o] += v.freq / sample_rate;
                    if (v.phase[o] >= 1.0) v.phase[o] -= 1.0;
                }
            }
            vmix *= 0.5; // 单声部内多振荡器叠加的余量

            // ── 滤波（高通 = 减去低通分量；低通 = 一阶）──
            var x = vmix;
            if (hpf_on) {
                v.hpf_lp += (x - v.hpf_lp) * hpf_coeff;
                x -= v.hpf_lp;
            }
            if (lpf_on) {
                v.lpf_lp += (x - v.lpf_lp) * lpf_coeff;
                x = v.lpf_lp;
            }

            mix += x * v.env_level;
        }

        // ── 主音量平滑（防拖动旋钮的 zipper 噪声）──
        state.smoothed_master += (gain - state.smoothed_master) * 0.0008;

        // ── 输出（软削波防爆音；多声部叠加溢出时自然压缩）──
        var s = mix * state.smoothed_master;
        s = s / (1.0 + @abs(s));
        const prev_l: f32 = if (add) out[i * 2] else 0;
        const prev_r: f32 = if (add) out[i * 2 + 1] else 0;
        out[i * 2] = prev_l + s;
        out[i * 2 + 1] = prev_r + s;
    }
}

// ── 测试 ──

const test_sr: f32 = 48000;

/// 测试辅助：排空立即事件并渲染（单乐器路径）
fn pump(p: *const SynthParams, st: *Synth, q: *EventQueue, buf: []f32, frames: u32, sr: f32, master: f32) void {
    var evbuf: [drain_max]NoteEvent = undefined;
    const n = q.drain(&evbuf);
    for (evbuf[0..n]) |ev| {
        switch (ev.kind) {
            .on => noteOn(st, ev.pitch),
            .off => noteOff(st, ev.pitch),
            .all_off => allOff(st),
        }
    }
    render(p, st, buf.ptr, frames, sr, master, false);
}

/// 测试辅助：找某音高活跃声部的包络电平（无则 0）
fn voiceLevelFor(state: *const Synth, pitch: u8) f32 {
    for (state.voices) |v| {
        if (v.pitch == pitch and v.env_stage != .idle) return v.env_level;
    }
    return 0;
}

test "synth: 正弦振荡器输出有限且非零" {
    var p = SynthParams{};
    var st = Synth{};
    var q = EventQueue{};
    var buf: [256 * 2]f32 = undefined;

    q.push(.{ .kind = .on, .pitch = 60 });
    pump(&p, &st, &q, &buf, 256, test_sr, 0.8);

    var energy: f32 = 0;
    for (buf) |s| energy += @abs(s);
    try std.testing.expect(energy > 0.1);
    for (buf) |s| try std.testing.expect(std.math.isFinite(s));
}

test "synth: 包络——起音到峰值、释音归零" {
    var p = SynthParams{};
    p.attack.store(0.0, .monotonic); // → 1ms
    p.decay.store(0.0, .monotonic);
    p.sustain.store(1.0, .monotonic);
    p.release.store(0.0, .monotonic); // → 1ms

    var st = Synth{};
    var q = EventQueue{};
    var buf: [4800 * 2]f32 = undefined; // 0.1s @ 48k

    q.push(.{ .kind = .on, .pitch = 69 });
    pump(&p, &st, &q, &buf, 4800, test_sr, 1.0);
    try std.testing.expect(voiceLevelFor(&st, 69) > 0.99);

    // 松开 → release（1ms）→ 很快归零、声部全部空闲
    q.push(.{ .kind = .off, .pitch = 69 });
    pump(&p, &st, &q, &buf, 4800, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 0), activeCount(&st));
}

test "synth: 复音（和弦 = 多声部同时发声）" {
    var p = SynthParams{};
    p.attack.store(0.0, .monotonic);
    p.sustain.store(1.0, .monotonic);

    var st = Synth{};
    var q = EventQueue{};
    var buf: [4800 * 2]f32 = undefined;

    q.push(.{ .kind = .on, .pitch = 60 }); // C4
    q.push(.{ .kind = .on, .pitch = 64 }); // E4
    q.push(.{ .kind = .on, .pitch = 67 }); // G4
    pump(&p, &st, &q, &buf, 64, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 3), activeCount(&st));

    // 松开其中一个 → 其余仍在响
    q.push(.{ .kind = .off, .pitch = 64 });
    pump(&p, &st, &q, &buf, 4800, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 2), activeCount(&st));
}

test "synth: 快速连点 = 新声部重触发（不吞音）" {
    var p = SynthParams{};
    p.attack.store(0.5, .monotonic); // 慢起音（可观察每下从低位重起）
    var st = Synth{};
    var q = EventQueue{};
    var buf: [512 * 2]f32 = undefined;

    q.push(.{ .kind = .on, .pitch = 60 });
    pump(&p, &st, &q, &buf, 512, test_sr, 1.0);
    const l1 = voiceLevelFor(&st, 60);
    try std.testing.expect(l1 > 0 and l1 < 1);

    // 未松手再按 → 分配**新声部**（两个声部同时存在）
    q.push(.{ .kind = .on, .pitch = 60 });
    pump(&p, &st, &q, &buf, 4, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 2), activeCount(&st));
}

test "synth: 声部上限与偷取（最多 max_voices）" {
    var p = SynthParams{};
    p.attack.store(0.0, .monotonic);
    p.sustain.store(1.0, .monotonic);

    var st = Synth{};
    var q = EventQueue{};
    var buf: [8 * 2]f32 = undefined;

    // 推入超过上限的 note-on（每 50 条渲染一次；drain 每块上限 64）
    var k: usize = 0;
    while (k < max_voices + 20) : (k += 1) {
        q.push(.{ .kind = .on, .pitch = @intCast(k % 120) });
        if (k % 50 == 49) pump(&p, &st, &q, &buf, 4, test_sr, 1.0);
    }
    // 再渲染几块确保队列排空
    pump(&p, &st, &q, &buf, 4, test_sr, 1.0);
    pump(&p, &st, &q, &buf, 4, test_sr, 1.0);

    try std.testing.expectEqual(max_voices, activeCount(&st));
}

test "synth: all_off 释放全部声部" {
    var p = SynthParams{};
    p.attack.store(0.0, .monotonic);
    p.release.store(0.0, .monotonic); // 1ms 释音
    p.sustain.store(1.0, .monotonic);

    var st = Synth{};
    var q = EventQueue{};
    var buf: [4800 * 2]f32 = undefined;

    q.push(.{ .kind = .on, .pitch = 60 });
    q.push(.{ .kind = .on, .pitch = 64 });
    pump(&p, &st, &q, &buf, 64, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 2), activeCount(&st));

    q.push(.{ .kind = .all_off });
    pump(&p, &st, &q, &buf, 4800, test_sr, 1.0);
    try std.testing.expectEqual(@as(usize, 0), activeCount(&st));
}

test "synth: 噪声振荡器输出非恒定" {
    var p = SynthParams{};
    p.osc[0].enabled.store(true, .monotonic);
    p.osc[0].volume.store(1.0, .monotonic);
    p.osc[0].waveform.store(@intFromEnum(Waveform.noise), .monotonic);

    var st = Synth{};
    var q = EventQueue{};
    var buf: [128 * 2]f32 = undefined;
    q.push(.{ .kind = .on, .pitch = 60 });
    pump(&p, &st, &q, &buf, 128, test_sr, 1.0);

    // 相邻样本应有明显差异（白噪声）
    var diff: f32 = 0;
    var i: usize = 2;
    while (i < 128 * 2) : (i += 2) diff += @abs(buf[i] - buf[i - 2]);
    try std.testing.expect(diff > 0.5);
}

test "synth: 低通滤波衰减高频能量" {
    // 方波（含丰富高频）→ 低通截止拉到最低 → 能量应显著下降
    var p = SynthParams{};
    p.osc[0].enabled.store(true, .monotonic);
    p.osc[0].volume.store(1.0, .monotonic);
    p.osc[0].waveform.store(@intFromEnum(Waveform.square), .monotonic);
    p.attack.store(0.0, .monotonic);
    p.sustain.store(1.0, .monotonic);

    var buf: [4096 * 2]f32 = undefined;

    var st1 = Synth{};
    var q1 = EventQueue{};
    q1.push(.{ .kind = .on, .pitch = 69 });
    pump(&p, &st1, &q1, &buf, 4096, test_sr, 1.0);
    var e1: f32 = 0;
    for (buf) |s| e1 += s * s;

    p.lpf.enabled.store(true, .monotonic);
    p.lpf.cutoff.store(0.0, .monotonic); // 20Hz
    var st2 = Synth{};
    var q2 = EventQueue{};
    q2.push(.{ .kind = .on, .pitch = 69 });
    pump(&p, &st2, &q2, &buf, 4096, test_sr, 1.0);
    var e2: f32 = 0;
    for (buf) |s| e2 += s * s;

    try std.testing.expect(e2 < e1 * 0.5);
}

test "synth: render(add=true) 叠加而不覆盖" {
    var p = SynthParams{};
    p.attack.store(0.0, .monotonic);
    p.sustain.store(1.0, .monotonic);

    var st1 = Synth{};
    var q1 = EventQueue{};
    var buf: [64 * 2]f32 = undefined;

    q1.push(.{ .kind = .on, .pitch = 60 });
    pump(&p, &st1, &q1, &buf, 64, test_sr, 1.0);
    var e1: f32 = 0;
    for (buf) |s| e1 += @abs(s);

    // 第二个声部池（同相位）叠加渲染 → 能量应约翻倍（验证 add 而非覆盖）
    var st2 = Synth{};
    noteOn(&st2, 60);
    render(&p, &st2, &buf, 64, test_sr, 1.0, true);
    var e2: f32 = 0;
    for (buf) |s| e2 += @abs(s);
    try std.testing.expect(e2 > e1 * 1.5);
}

test "synth: SchedQueue 推入/取出保序" {
    var sq = SchedQueue{};
    sq.push(.{ .kind = .on, .pitch = 60, .step = 10, .gen = 1 });
    sq.push(.{ .kind = .off, .pitch = 60, .step = 20, .gen = 1 });
    sq.push(.{ .kind = .on, .pitch = 64, .step = 30, .gen = 1 });

    var out: [8]SchedEvent = undefined;
    const n = sq.drain(&out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(i32, 10), out[0].step);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);
    try std.testing.expectEqual(@as(i32, 30), out[2].step);
    try std.testing.expectEqual(@as(u8, 64), out[2].pitch);
    // 取空后再次 drain 应为 0
    try std.testing.expectEqual(@as(usize, 0), sq.drain(&out));
}

test "synth: 归一化映射（时间 / 截止频率）" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.001), mapTime(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mapTime(1), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cutoffHz(0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20000.0), cutoffHz(1), 1.0);
}

test "synth: pitchHz（A4 = 440、八度翻倍）" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), pitchHz(69), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 880.0), pitchHz(81), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 220.0), pitchHz(57), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), pitchHz(60), 0.01); // C4
}
