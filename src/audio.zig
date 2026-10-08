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
const eq = @import("eq.zig");
const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// 调音台通道数**上限**（与 app.max_mixer_channels 一致；音频层不能 import app——循环依赖）。
/// 运行时实际通道数以 `Params.channel_count` 为准（≤ 此值）。
pub const mixer_channels = 32;
/// 每通道效果器槽数**上限**（与 app.max_effects_per_channel 一致）
pub const effect_slots = 16;
/// 每槽 EQ 段数（与 eq.band_count 一致）
pub const eq_bands = eq.band_count;

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
    /// 编辑代（播放中编辑重扫时递增）：音频线程丢弃 `edit_gen` **小于**
    /// 当前值的事件（丢弃但不释放声部）——见 `sequencer.rescanForEdit`
    sched_edit_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

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
    /// 每乐器路由到的调音台通道（0..mixer_channels-1；UI 每帧同步）
    instrument_channel: [synth.max_instruments]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** synth.max_instruments,

    // ── 调音台：每通道参数（UI 写、音频线程读）──
    /// 通道增益（0-1）
    channel_gain: [mixer_channels]std.atomic.Value(f32) = blk: {
        var a: [mixer_channels]std.atomic.Value(f32) = undefined;
        for (&a) |*g| g.* = std.atomic.Value(f32).init(0.8);
        break :blk a;
    },
    /// 通道声像（0-1；0.5 = 居中）
    channel_pan: [mixer_channels]std.atomic.Value(f32) = blk: {
        var a: [mixer_channels]std.atomic.Value(f32) = undefined;
        for (&a) |*g| g.* = std.atomic.Value(f32).init(0.5);
        break :blk a;
    },
    /// 通道静音（增益已在 UI 侧合并——但保留独立标志以便 UI 同步）
    channel_muted: [mixer_channels]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(false)} ** mixer_channels,
    /// 通道 EQ 段参数（**效果器链的第 0 槽 = EQ**；频率/增益/Q——
    /// UI 每帧同步；音频线程据其重建 biquad）。
    /// 槽位元数据（kind/enabled/mix）在 `effect_chain`。
    channel_eq: [mixer_channels][eq_bands]eq.BandParams = blk: {
        var a: [mixer_channels][eq_bands]eq.BandParams = undefined;
        for (&a) |*ch| ch.* = .{
            .{ .freq = 100, .q = 1.0 },
            .{ .freq = 500, .q = 1.0 },
            .{ .freq = 2000, .q = 1.0 },
            .{ .freq = 8000, .q = 1.0 },
            .{ .freq = 12000, .q = 1.0 },
        };
        break :blk a;
    },
    /// 通道 EQ 版本号（参数变化时递增；音频线程对比后重建系数）
    channel_eq_version: [mixer_channels]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** mixer_channels,
    /// 效果器链元数据（槽 × 通道）：kind（0 = 空、1 = EQ）、enabled、mix
    effect_kind: [mixer_channels][effect_slots]std.atomic.Value(u32) = [_][effect_slots]std.atomic.Value(u32){[_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** effect_slots} ** mixer_channels,
    effect_enabled: [mixer_channels][effect_slots]std.atomic.Value(bool) = [_][effect_slots]std.atomic.Value(bool){[_]std.atomic.Value(bool){std.atomic.Value(bool).init(true)} ** effect_slots} ** mixer_channels,
    effect_mix: [mixer_channels][effect_slots]std.atomic.Value(f32) = [_][effect_slots]std.atomic.Value(f32){[_]std.atomic.Value(f32){std.atomic.Value(f32).init(1.0)} ** effect_slots} ** mixer_channels,
    /// 效果链版本（kind/enabled/mix 变化时递增）
    effect_chain_version: [mixer_channels]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** mixer_channels,
    /// 效果链长度（每通道：有效效果器数；UI 每帧同步）
    effect_count: [mixer_channels]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** mixer_channels,
    /// 实际通道数（UI 每帧同步；音频线程只处理 0..channel_count）
    channel_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    // ── 音频线程回传：调音台频谱（用于 EQ 窗口背景）──
    /// 主输出频谱柱（0-1）
    spec_bars: [eq.spec_bars]std.atomic.Value(f32) = [_]std.atomic.Value(f32){std.atomic.Value(f32).init(0)} ** eq.spec_bars,
    /// 频谱版本（音频线程每分析一次递增；UI 据此拷贝）
    spec_version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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

    // ── 调音台（音频线程状态；仅本人访问）──
    /// 每通道效果链上的 EQ 滤波器（**堆分配**：槽 × 段 × 2 声道；
    /// 32×16×4×2 个 Biquad 体积可观，不能放栈）。
    /// 布局：`[ch][slot][band][2]` 展平索引。
    slot_eq: []eq.Biquad = &.{},
    /// 每通道已应用的 EQ 版本（与 params.channel_eq_version 对比）
    chan_eq_ver: [mixer_channels]u32 = [_]u32{0} ** mixer_channels,
    /// 每通道渲染缓冲（**堆分配**：32 通道 × 32KB = 1MB，不能放栈）
    chan_bufs: []f32 = &.{},
    /// 频谱分析：滑窗样本（单声道混合）
    spec_win: [eq.fft_size]f32 = undefined,
    spec_pos: usize = 0,
    spec_fill: usize = 0,

    /// 初始化并启动音频设备（默认设备，双声道 f32）
    pub fn init(self: *Engine, params: *Params, allocator: std.mem.Allocator) !void {
        self.params = params;
        self.allocator = allocator;
        self.synths = try allocator.alloc(synth.Synth, synth.max_instruments);
        for (self.synths) |*s| s.* = .{};
        // 调音台缓冲（堆分配——体积大不能放栈）
        self.chan_bufs = try allocator.alloc(f32, mixer_channels * 2 * 4096);
        @memset(self.chan_bufs, 0);
        const n_eq = mixer_channels * effect_slots * eq_bands * 2;
        self.slot_eq = try allocator.alloc(eq.Biquad, n_eq);
        @memset(self.slot_eq, .{});

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
        if (self.chan_bufs.len > 0) {
            self.allocator.free(self.chan_bufs);
            self.chan_bufs = &.{};
        }
        if (self.slot_eq.len > 0) {
            self.allocator.free(self.slot_eq);
            self.slot_eq = &.{};
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

/// 传输跳变（generation 变化）：作废 stash；**播放中**的跳变（`was_playing`）
/// 还要释放全部声部。
///
/// 为什么必须释放：跳转时音符的 note-off 可能早已在 stash 里排队，
/// gen 递增整批作废后它被丢弃 → 已起音的声部永远收不到 off，
/// 停在 sustain 一直响（实测 bug：游标拖走后音符响到暂停/停止）。
/// 释放 = 进入 release（与暂停/停止同语义；不播剩余时值）。
///
/// 为什么放在音频线程（而不是 UI 的 jumpPlaybackCursor 里推 all_off）：
/// UI 推事件与 gen 存储之间有窗口（中间还有 reset 的 gather）——音频线程
/// 可能先消费 all_off、再按**新传输参数**误触发旧 gen 的事件（新声部，
/// 其 off 随后被作废 → 又悬挂）。这里与事件触发同线程，无窗口。
fn handleGenChange(engine: *Engine, gen: u32, was_playing: bool) void {
    engine.stash_n = 0;
    engine.stash_gen = gen;
    if (was_playing) {
        for (engine.synths) |*s| synth.allOff(s);
    }
}

/// 按步序插入一个调度事件（保持 stash 有序）。
///
/// 为什么不是追加：播放中补发的新增音符事件可能**早于**已 stash 的事件
/// （如新增音符在窗口最前端——见 `sequencer.scheduleAdded`）；
/// 追加会被前面的事件挡着，拖到很晚才触发（表现：补发的 on 迟到/整段不响）。
/// 插不进去（stash 满）时丢弃——宁可丢一个事件也不阻塞音频线程；
/// stash 溢出本身会由下一块的重扫/正常排水自愈。
fn stashInsert(engine: *Engine, ev: synth.SchedEvent) void {
    if (engine.stash_n >= engine.stash.len) return; // 满：丢弃
    // 从尾部往前找插入点（stash 已按步序）
    var i: usize = engine.stash_n;
    while (i > 0 and synth.schedEventLess({}, ev, engine.stash[i - 1])) : (i -= 1) {
        engine.stash[i] = engine.stash[i - 1];
    }
    engine.stash[i] = ev;
    engine.stash_n += 1;
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
        .on => synth.noteOn(&engine.synths[ev.instrument], ev.pitch, ev.velocity, ev.pan),
        .off => synth.noteOff(&engine.synths[ev.instrument], ev.pitch),
        .all_off => for (engine.synths) |*s| synth.allOff(s),
    }
}

/// 展平索引取 EQ Biquad（`engine.slot_eq` 的布局：`[ch][slot][band][2]`）
inline fn eqBiquadAt(engine: *Engine, ch: usize, slot: usize, band: usize, chan: usize) *eq.Biquad {
    const idx = ((ch * effect_slots + slot) * eq_bands + band) * 2 + chan;
    return &engine.slot_eq[idx];
}

/// 渲染一个分段（多乐器 → 按通道独立缓冲 → EQ/增益/声像 → 主输出叠加）。
/// `out` 已清零；本函数**累加**到 out。
pub fn renderSegment(engine: *Engine, params: *Params, out: [*]f32, frames: u32, sr: f32, master: f32) void {
    const n: usize = @as(usize, frames) * 2;
    const n_ch: usize = @min(params.channel_count.load(.monotonic), mixer_channels);
    if (engine.chan_bufs.len < mixer_channels * 2 * 4096 or engine.slot_eq.len < mixer_channels * effect_slots * eq_bands * 2) return;
    const buf_stride: usize = 2 * 4096;

    // 1) 所有通道缓冲清零
    for (0..n_ch) |ci| @memset(engine.chan_bufs[ci * buf_stride ..][0..n], 0);

    // 2) 乐器 → 各自通道的缓冲（**按通道路由分开渲染**——通道 EQ 必须逐通道）
    for (0..synth.max_instruments) |i| {
        const sp = params.synth_ptrs[i].load(.monotonic) orelse continue;
        const ch: usize = @min(params.instrument_channel[i].load(.monotonic), if (n_ch > 0) n_ch - 1 else 0);
        const g = params.instrument_gain[i].load(.monotonic); // 乐器音量×静音（推子前）
        synth.render(sp, &engine.synths[i], @ptrCast(&engine.chan_bufs[ch * buf_stride]), frames, sr, g, true);
    }

    // 3) 逐通道：效果链 → 增益（含通道静音）→ 等功率声像 → 累加到主输出
    var ch_i: usize = 0;
    while (ch_i < n_ch) : (ch_i += 1) {
        const buf = engine.chan_bufs[ch_i * buf_stride ..][0..n];

        // EQ 系数重建：参数变化版本号驱动（多槽共享同一份 EQ 参数对象）
        const ver = params.channel_eq_version[ch_i].load(.monotonic);
        if (ver != engine.chan_eq_ver[ch_i]) {
            engine.chan_eq_ver[ch_i] = ver;
            for (0..effect_slots) |slot| {
                for (0..eq_bands) |b| {
                    const p = params.channel_eq[ch_i][b];
                    eqBiquadAt(engine, ch_i, slot, b, 0).setPeak(sr, p.freq, p.q, p.gain_db);
                    eqBiquadAt(engine, ch_i, slot, b, 1).setPeak(sr, p.freq, p.q, p.gain_db);
                }
            }
        }
        // 本通道无乐器路由时也可跳过（但 EQ 尾音无意义——直接跳）
        var used = false;
        for (0..synth.max_instruments) |i| {
            if (params.synth_ptrs[i].load(.monotonic) != null and
                @min(params.instrument_channel[i].load(.monotonic), if (n_ch > 0) n_ch - 1 else 0) == ch_i)
            {
                used = true;
                break;
            }
        }
        if (!used) continue;

        // ── 效果器链（插件式；按槽顺序；长度以 `effect_count` 为准）──
        // 干湿比：效果信号与干声逐样本混合（mix = 0 为完全干声）
        const eff_n: usize = @min(params.effect_count[ch_i].load(.monotonic), effect_slots);
        var slot: usize = 0;
        while (slot < eff_n) : (slot += 1) {
            const kind = params.effect_kind[ch_i][slot].load(.monotonic);
            if (kind != 1) continue; // 1 = EQ
            if (!params.effect_enabled[ch_i][slot].load(.monotonic)) continue; // 旁通
            const mix = std.math.clamp(params.effect_mix[ch_i][slot].load(.monotonic), 0, 1);
            var sb: usize = 0;
            while (sb < eq_bands) : (sb += 1) {
                if (params.channel_eq[ch_i][sb].gain_db == 0) continue;
                var f: usize = 0;
                while (f < frames) : (f += 1) {
                    const dry_l = buf[f * 2];
                    const dry_r = buf[f * 2 + 1];
                    const wet_l = eqBiquadAt(engine, ch_i, slot, sb, 0).process(dry_l);
                    const wet_r = eqBiquadAt(engine, ch_i, slot, sb, 1).process(dry_r);
                    buf[f * 2] = dry_l + (wet_l - dry_l) * mix;
                    buf[f * 2 + 1] = dry_r + (wet_r - dry_r) * mix;
                }
            }
        }

        // 增益 + 等功率声像
        const muted = params.channel_muted[ch_i].load(.monotonic);
        const gain = if (muted) 0.0 else params.channel_gain[ch_i].load(.monotonic);
        const pan = std.math.clamp(params.channel_pan[ch_i].load(.monotonic), 0, 1);
        const ang = pan * (std.math.pi / 2.0);
        const gl = @cos(ang) * gain * master * std.math.sqrt2;
        const gr = @sin(ang) * gain * master * std.math.sqrt2;
        var f2: usize = 0;
        while (f2 < frames) : (f2 += 1) {
            out[f2 * 2] += buf[f2 * 2] * gl;
            out[f2 * 2 + 1] += buf[f2 * 2 + 1] * gr;
        }
    }
}

/// 频谱分析：把主输出 `out`（本块已混好的立体声）抽取入滑窗；
/// 窗满 → FFT → 柱形回传（`params.spec_bars`）。
/// 抽取：每 8 帧取 1 个（48k → 6kHz 有效带宽，覆盖显示范围足够）。
pub fn analyzeSpectrum(engine: *Engine, params: *Params, out: [*]const f32, frames: u32, sr: f32) void {
    const stride: usize = 8;
    var filled_this_block = false;
    var f: usize = 0;
    while (f < frames) : (f += stride) {
        const s = (out[f * 2] + out[f * 2 + 1]) * 0.5;
        engine.spec_win[engine.spec_pos] = s;
        engine.spec_pos = (engine.spec_pos + 1) % eq.fft_size;
        if (engine.spec_pos == 0) {
            engine.spec_fill = eq.fft_size;
            filled_this_block = true;
        }
    }
    if (engine.spec_fill < eq.fft_size) return;
    // 注：**不能要求块结束时 pos == 0**——frames % fft_size 不整除时
    // 永远凑不齐（实测 bug：测试里频谱恒为 0）。本块内写过一轮就分析。
    if (!filled_this_block) return;

    // 窗内样本重排（写指针 pos 处 = 最旧样本）
    const eff_sr = sr / @as(f32, @floatFromInt(stride));
    var re: [eq.fft_size]f32 = undefined;
    var im: [eq.fft_size]f32 = undefined;
    for (0..eq.fft_size) |k| {
        re[k] = engine.spec_win[(engine.spec_pos + k) % eq.fft_size];
        im[k] = 0;
    }
    eq.hannWindow(&re);
    eq.fft(&re, &im);
    var mag: [eq.fft_size / 2]f32 = undefined;
    for (0..eq.fft_size / 2) |k| mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
    var bars: [eq.spec_bars]f32 = undefined;
    eq.barsFromSpectrum(&mag, eff_sr, &bars);
    const ver = params.spec_version.load(.monotonic);
    for (bars, 0..) |b, k| params.spec_bars[k].store(b, .monotonic);
    params.spec_version.store(ver +% 1, .monotonic);
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
            .on => if (ev.instrument < synth.max_instruments) synth.noteOn(&engine.synths[ev.instrument], ev.pitch, ev.velocity, ev.pan),
            .off => if (ev.instrument < synth.max_instruments) synth.noteOff(&engine.synths[ev.instrument], ev.pitch),
            .all_off => for (engine.synths) |*s| synth.allOff(s),
        }
    }

    // 2) 清空输出（之后按分段叠加渲染）
    @memset(out[0 .. @as(usize, frames) * 2], 0);

    const master = params.volume.load(.monotonic);
    const playing = params.playing.load(.monotonic);
    const gen = params.sched_gen.load(.monotonic);
    // 本块之前的播放状态：区分“起播”与“播放中跳转”（两者都会让 gen 变化，
    // 但只有跳转需要释放正在发声的旧声部——见 handleGenChange）
    const was_playing = engine.was_playing;

    // 暂停边沿：释放全部声部（否则音符永远停在 sustain，实测 bug）
    transportEdge(engine, playing);

    // 3) 非播放：只渲染（试听/释音尾），调度事件不触发
    if (!playing) {
        renderSegment(engine, params, out, frames, sr, master);
        analyzeSpectrum(engine, params, out, frames, sr);
        publishSounding(engine, params);
        _ = params.frames_played.fetchAdd(frames, .monotonic);
        return;
    }

    // 4) 播放：stash 管理 + 样本级事件触发
    if (gen != engine.stash_gen) handleGenChange(engine, gen, was_playing);
    // 编辑代（重扫）：**不**清空 stash（有 drain 竞态会丢新事件），
    // 由触发循环按 `edit_gen < 当前值` 过滤——在响的音符保持发声
    const edit_gen = params.sched_edit_gen.load(.monotonic);
    // 尽量多取新事件（stash 有空位时）。**按步序插入**（不是追加）：
    // 播放中重扫补发的事件可能落在已 stash 的事件之前
    // （见 `sequencer.rescanForEdit`）——追加的话它们会被前面的事件挡着，
    // 拖到很晚才触发（表现：新增音符的 on 迟到/整段不响）。
    // 作废事件（旧 gen / 旧编辑代）**不在此处过滤**——存进 stash 由触发
    // 循环统一丢（避免过滤后 `got == 0` 提前退出而漏取后续有效事件）。
    if (engine.stash_n < engine.stash.len) {
        var tmp: [synth.sched_drain_max]synth.SchedEvent = undefined;
        const want = @min(engine.stash.len - engine.stash_n, tmp.len);
        const got = params.sched_events.drain(tmp[0..want]);
        for (tmp[0..got]) |ev| stashInsert(engine, ev);
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
        if (ev.gen != gen or ev.edit_gen < edit_gen) {
            si += 1; // 作废（旧传输代 / 旧编辑代）：丢弃，**不**释放声部
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

    // 6) 频谱回传（UI 的 EQ 背景）
    analyzeSpectrum(engine, params, out, frames, sr);

    // 7) 回传“正在发声的音高”（UI 用于播放/试听高亮）
    publishSounding(engine, params);

    _ = params.frames_played.fetchAdd(frames, .monotonic);
}

test "audio: 播放中 gen 变化（跳转）释放全部声部（修“跳走后音符悬挂”）" {
    var params = Params{};
    var engine = Engine{ .params = &params };
    engine.synths = try std.testing.allocator.alloc(synth.Synth, 1);
    defer std.testing.allocator.free(engine.synths);
    for (engine.synths) |*s| s.* = .{};

    var p = synth.SynthParams{}; // 默认：release ≈ 10ms、sustain 0.7
    var buf: [4800 * 2]f32 = undefined; // 0.1s @ 48k

    // 声部正在发声（模拟播放中扫到了音符）
    synth.noteOn(&engine.synths[0], 60, synth.default_velocity, synth.default_pan);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false); // 进入 sustain
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));
    engine.stash_n = 3;
    engine.stash_gen = 7;

    // 播放中跳转（gen 变化）→ stash 作废 + 声部进入 release
    handleGenChange(&engine, 8, true);
    try std.testing.expectEqual(@as(u32, 8), engine.stash_gen);
    try std.testing.expectEqual(@as(usize, 0), engine.stash_n);
    // 再渲染 0.1s：release（≈10ms）已走完 → 归零
    // （若仍停在 sustain，activeCount 会一直是 1——正是实测 bug）
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));

    // 起播（上一块未播放）→ **不释放**（不误杀试听/释音尾音）
    synth.noteOn(&engine.synths[0], 64, synth.default_velocity, synth.default_pan);
    handleGenChange(&engine, 9, false);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0])); // 仍在响
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
    synth.noteOn(&engine.synths[0], 60, synth.default_velocity, synth.default_pan);
    synth.noteOn(&engine.synths[1], 64, synth.default_velocity, synth.default_pan);
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
