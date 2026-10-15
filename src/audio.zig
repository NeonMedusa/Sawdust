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

/// 每槽效果器 DSP 状态盒：UI 线程 `create`/延迟退役，音频线程只读。
/// `kind` 为 2/3/4（与 `effect_kind` 同编码）；**音频侧以盒内 kind 为准**
/// （链 kind 与指针更新有帧间竞态——按盒分派保证永不误解指针）。
pub const FxBox = struct {
    kind: u8,
    payload: union {
        reverb: fx.Reverb,
        delay: fx.Delay,
        comp: fx.Compressor,
    },
};
const synth = @import("synth.zig");
const eq = @import("eq.zig");
const fx = @import("effects.zig");
const vst_host = @import("vst_host.zig");
const ivstevents = @import("zig_vst3").pluginterfaces.vst.ivstevents;
const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// 每乐器每个分段发送给 VSTi 的事件上限（超出的丢弃；宁可丢事件也不分配）
pub const vsti_batch_max = 128;

/// 调音台通道数**上限**（与 app.max_mixer_channels 一致；音频层不能 import app——循环依赖）。
/// 运行时实际通道数以 `Params.channel_count` 为准（≤ 此值）。
pub const mixer_channels = 32;
/// 每通道效果器槽数**上限**（与 app.max_effects_per_channel 一致）
pub const effect_slots = 16;
/// 每槽 EQ 段数（与 eq.band_count 一致）
pub const eq_bands = eq.band_count;
/// 鼓组每乐器的**层槽位上限**（槽位 = 一份合成器参数 + 绑定的音高；
/// 一个垫的多层占多个槽位；见 `docs/drumkit.md` §3.2/3.3）。
/// 内存：层声部池 32 声部 ≈ 9.6KB/层 → 16 层 ≈ 155KB/套（预分配大块）。
pub const kit_max_layers = 16;

/// UI ↔ 音频线程共享的参数（原子，无锁）
pub const Params = struct {
    /// 主音量 0.0 - 1.0
    volume: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.75),
    /// 是否播放（序列器渲染开关）
    playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 音频线程回传：已播放帧数（UI 读取用于显示播放位置/驱动游标）
    frames_played: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// 采样率（设备初始化后写入；UI 读取用于“帧 → 步”换算）
    sample_rate: u64 = 48000,

    // ── 传输（UI 写、音频线程读）──
    /// BPM（序列器按此把步 → 帧换算；UI 每帧同步）
    bpm: std.atomic.Value(u32) = std.atomic.Value(u32).init(120),
    /// 拍号（分子/分母；main 每帧同步——ProcessContext 用；仅信息性）
    time_num: std.atomic.Value(i32) = std.atomic.Value(i32).init(4),
    time_den: std.atomic.Value(i32) = std.atomic.Value(i32).init(4),
    /// 每拍步数（`U / 分母`；决定“一步”的真实时长；UI 每帧同步）
    steps_per_beat: std.atomic.Value(u32) = std.atomic.Value(u32).init(24),
    /// 播放起点（帧；开始播放/跳转时写入）
    start_frame: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// 播放起点（步；与 start_frame 配对，用于步↔帧换算）
    start_step: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// 调度 generation（reset 时递增；音频线程丢弃旧事件）
    sched_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    /// 编辑代（播放中编辑重扫时递增）：音频线程丢弃 `edit_gen` **小于**
    /// 当前值、**且步号 >= `sched_rescan_from`** 的旧事件（= 已有重发
    /// 副本替换；低于安全界的旧副本**保留触发**）——见 `sequencer.rescanForEdit`
    sched_edit_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    /// 最近一次重扫的**安全界**（步）：用 `schedEventObsolete` 判定旧事件
    /// 是否已被重发替换——UI 必须**先本值、后 `sched_edit_gen`**发布
    /// （见 `App.rescanForPlaybackEdit`）
    sched_rescan_from: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

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
    /// 每乐器声像（0-1；0.5 居中；UI 每帧同步）——音符级声像的**基准**：
    /// 播放时合成有效声像（基准 + 音符偏移），见 `effectivePan`
    instrument_pan: [synth.max_instruments]std.atomic.Value(f32) = blk: {
        var a: [synth.max_instruments]std.atomic.Value(f32) = undefined;
        for (&a) |*p| p.* = std.atomic.Value(f32).init(0.5);
        break :blk a;
    },
    /// 每槽 VST3 插件实例指针（混音通道 × 效果槽；null = 未加载/直通）——
    /// UI 侧惰性加载并发布；删除走“退役列表”延迟销毁（见 App.retirePlugin）
    plugin_ptrs: [mixer_channels][effect_slots]std.atomic.Value(?*vst_host.Plugin) = [_][effect_slots]std.atomic.Value(?*vst_host.Plugin){[_]std.atomic.Value(?*vst_host.Plugin){std.atomic.Value(?*vst_host.Plugin).init(null)} ** effect_slots} ** mixer_channels,
    /// 每槽效果器 DSP 状态盒（混响/延迟/压缩器；UI 线程分配/发布/退役——与
    /// `plugin_ptrs` 同一模式）。null = 无状态（直通/未发布）。
    /// 历史：原为每通道一份（“同类至多一个”时代）；用户要叠加相同效果 → 每槽独立。
    fx_ptrs: [mixer_channels][effect_slots]std.atomic.Value(?*FxBox) = [_][effect_slots]std.atomic.Value(?*FxBox){[_]std.atomic.Value(?*FxBox){std.atomic.Value(?*FxBox).init(null)} ** effect_slots} ** mixer_channels,
    /// 每乐器路由到的调音台通道（0..mixer_channels-1；UI 每帧同步）
    instrument_channel: [synth.max_instruments]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** synth.max_instruments,
    /// 每乐器的 VST3 插件实例（kind == 2/VSTi；null = 未加载）——UI 侧惰性加载/发布
    instrument_plugin: [synth.max_instruments]std.atomic.Value(?*vst_host.Plugin) = [_]std.atomic.Value(?*vst_host.Plugin){std.atomic.Value(?*vst_host.Plugin).init(null)} ** synth.max_instruments,

    // ── 鼓组（每乐器：类型 + 层列表；UI 每帧同步）──
    /// 乐器类型（0 = synth / 1 = drumkit / 2 = VST3 插件）
    instrument_kind: [synth.max_instruments]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** synth.max_instruments,
    /// 鼓组层数（≤ kit_max_layers）
    kit_layer_count: [synth.max_instruments]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** synth.max_instruments,
    /// 鼓组层 → 音高（on 事件按音高分发到匹配层）。
    /// 注：off **不查它**——直接对全部层 noteOff（防“响着改映射”漏 off 悬挂）。
    kit_layer_pitch: [synth.max_instruments][kit_max_layers]std.atomic.Value(u32) = blk: {
        @setEvalBranchQuota(10000);
        var a: [synth.max_instruments][kit_max_layers]std.atomic.Value(u32) = undefined;
        for (&a) |*row| {
            for (row) |*v| v.* = std.atomic.Value(u32).init(0);
        }
        break :blk a;
    },
    /// 鼓组层增益（多层叠加的配比）
    kit_layer_gain: [synth.max_instruments][kit_max_layers]std.atomic.Value(f32) = blk: {
        @setEvalBranchQuota(10000);
        var a: [synth.max_instruments][kit_max_layers]std.atomic.Value(f32) = undefined;
        for (&a) |*row| {
            for (row) |*v| v.* = std.atomic.Value(f32).init(1.0);
        }
        break :blk a;
    },
    /// 鼓组层合成器参数指针（层本体；UI 持有并保证地址稳定）
    kit_layer_params: [synth.max_instruments][kit_max_layers]std.atomic.Value(?*synth.SynthParams) = blk: {
        @setEvalBranchQuota(10000);
        var a: [synth.max_instruments][kit_max_layers]std.atomic.Value(?*synth.SynthParams) = undefined;
        for (&a) |*row| {
            for (row) |*v| v.* = std.atomic.Value(?*synth.SynthParams).init(null);
        }
        break :blk a;
    },

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
    /// 效果器参数位（每槽 5 个；含义按 kind 见 `effects.paramInfos`——
    /// 2 = 混响 / 3 = 延迟 / 4 = 压缩器；1 = EQ 用 `channel_eq`）
    effect_p: [mixer_channels][effect_slots][fx.max_params]std.atomic.Value(f32) = blk: {
        @setEvalBranchQuota(20000);
        var a: [mixer_channels][effect_slots][fx.max_params]std.atomic.Value(f32) = undefined;
        for (&a) |*ch| {
            for (ch) |*slot| {
                for (slot) |*v| v.* = std.atomic.Value(f32).init(0);
            }
        }
        break :blk a;
    },
    /// 实际通道数（UI 每帧同步；音频线程只处理 0..channel_count）
    channel_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    // ── 音频线程回传：调音台频谱（用于 EQ 窗口背景）──
    /// 频谱柱（0-1）——**目标效果器的输入信号**（非主输出全混）
    spec_bars: [eq.spec_bars]std.atomic.Value(f32) = [_]std.atomic.Value(f32){std.atomic.Value(f32).init(0)} ** eq.spec_bars,
    /// 频谱版本（音频线程每分析一次递增；UI 据此拷贝）
    spec_version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 频谱分析目标：效果器所在通道（UI 每帧发布；-1 = 不分析）
    spec_target_ch: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// 频谱分析目标：效果器在链上的槽位（-1 = 不分析）
    spec_target_slot: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

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
    /// 鼓组层声部池（**预分配大块**：max_instruments × kit_max_layers；
    /// 索引 = `i * kit_max_layers + l`）。启动一次分配——无生命周期管理
    /// （层槽位复用：层数/参数变时旧声部自然 release，无需释放池）。
    kit_synths: []synth.KitLayerSynth = &.{},
    /// VSTi 渲染中转缓冲（插件的原位写出不能直接覆盖通道缓冲——需叠加）
    vsti_scratch: []f32 = &.{},
    /// VSTi 待发送事件批（事件在**段边界以 offset 0 生效**：dispatchNote 填充，
    /// renderSegment 消费后清零——与内部合成器的样本级触发共用同一分段机制）
    vsti_events: [synth.max_instruments][vsti_batch_max]ivstevents.Event = [_][vsti_batch_max]ivstevents.Event{[_]ivstevents.Event{.{}} ** vsti_batch_max} ** synth.max_instruments,
    vsti_event_n: [synth.max_instruments]usize = [_]usize{0} ** synth.max_instruments,
    /// VSTi 正在发声的音高（位图；all-off 时按位补发 note-off）
    vsti_active_lo: [synth.max_instruments]u64 = [_]u64{0} ** synth.max_instruments,
    vsti_active_hi: [synth.max_instruments]u64 = [_]u64{0} ** synth.max_instruments,
    /// 每乐器上一帧的类型（类型切换边沿 → 两个池都全释音，防悬挂）
    last_kind: [synth.max_instruments]u32 = [_]u32{0} ** synth.max_instruments,
    /// 已取但未到时的调度事件（stash；按步序保留，到时再触发）
    stash: [synth.sched_drain_max]synth.SchedEvent = undefined,
    stash_n: usize = 0,
    /// 当前渲染**段**起点的绝对播放帧（dataCallback 每段设置；ProcessContext 用）
    seg_abs0: u64 = 0,
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
    /// 注：混响/延迟/压缩器状态已改为**每槽状态盒**（`Params.fx_ptrs`，
    /// UI 线程分配/退役）——原“每通道一份”的 `reverbs/delays/comps` 已移除
    /// （用户要叠加相同效果；Delay 每份 768KB，不能按槽预分配）。
    /// 每通道渲染缓冲（**堆分配**：32 通道 × 32KB = 1MB，不能放栈）
    chan_bufs: []f32 = &.{},
    /// 频谱分析：滑窗样本（单声道混合）——滑窗取自
    /// **目标效果器的输入点**（见 `captureSpectrum`）
    spec_win: [eq.fft_size]f32 = undefined,
    spec_pos: usize = 0,
    /// 滑窗已满（待分析）；由 `captureSpectrum` 置位、`analyzeSpectrum` 消费
    spec_ready: bool = false,
    /// 上次捕获时的目标（ch, slot）——变化时丢弃旧滑窗（防两种信号混窗）
    spec_target_seen: [2]i32 = .{ -2, -2 },

    /// 初始化并启动音频设备（默认设备，双声道 f32）
    pub fn init(self: *Engine, params: *Params, allocator: std.mem.Allocator) !void {
        self.params = params;
        self.allocator = allocator;
        self.synths = try allocator.alloc(synth.Synth, synth.max_instruments);
        for (self.synths) |*s| s.* = .{};
        // 鼓组层声部池（预分配大块；≈32×16 × 9.6KB ≈ 5MB，一次分配）
        self.kit_synths = try allocator.alloc(synth.KitLayerSynth, synth.max_instruments * kit_max_layers);
        for (self.kit_synths) |*s| s.* = .{};
        // VSTi 中转缓冲（一个渲染块大小）
        self.vsti_scratch = try allocator.alloc(f32, 2 * 4096);
        @memset(self.vsti_scratch, 0);
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
        if (self.kit_synths.len > 0) {
            self.allocator.free(self.kit_synths);
            self.kit_synths = &.{};
        }
        if (self.vsti_scratch.len > 0) {
            self.allocator.free(self.vsti_scratch);
            self.vsti_scratch = &.{};
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

/// 释放**两个声部池**的全部声部（合成器 + 鼓组层）——暂停下降沿/跳转作废/
/// 全体释音（all_off）共用。
/// 注：漏掉 `kit_synths` 是实测 bug——暂停后鼓组的音会一直响到停止
/// （旧代码只遍历了 `synths`）。
fn releaseAllVoices(engine: *Engine) void {
    for (engine.synths) |*s| synth.allOff(s);
    for (engine.kit_synths) |*s| synth.allOff(s);
    // VSTi：给正在发声的乐器按音高补发 note-off（VST3 无“全体释音”事件）
    const params = engine.params;
    for (0..synth.max_instruments) |i| {
        if (params.instrument_kind[i].load(.monotonic) == 2) vstiAllOff(engine, i);
    }
}

/// VSTi：把事件追加到该乐器的待发送批（满则丢弃——宁可丢事件不分配）
fn vstiPush(engine: *Engine, i: usize, ev: ivstevents.Event) void {
    const n = engine.vsti_event_n[i];
    if (n >= engine.vsti_events[i].len) return;
    engine.vsti_events[i][n] = ev;
    engine.vsti_event_n[i] = n + 1;
}

/// VSTi：正在发声位图的置位/清除
fn vstiActiveSet(engine: *Engine, i: usize, pitch: u8, on: bool) void {
    if (pitch < 64) {
        const bit = @as(u64, 1) << @intCast(pitch);
        if (on) engine.vsti_active_lo[i] |= bit else engine.vsti_active_lo[i] &= ~bit;
    } else {
        const bit = @as(u64, 1) << @intCast(pitch - 64);
        if (on) engine.vsti_active_hi[i] |= bit else engine.vsti_active_hi[i] &= ~bit;
    }
}

fn vstiNoteOn(engine: *Engine, i: usize, pitch: u8, velocity: u8) void {
    vstiActiveSet(engine, i, pitch, true);
    vstiPush(engine, i, .{
        .sampleOffset = 0,
        .type = @intFromEnum(ivstevents.Event.EventTypes.kNoteOnEvent),
        .data = .{ .noteOn = .{
            .channel = 0,
            .pitch = @intCast(pitch),
            .velocity = @as(f32, @floatFromInt(@max(1, velocity))) / 127.0,
            .length = 0,
            .noteId = -1,
        } },
    });
}

fn vstiNoteOff(engine: *Engine, i: usize, pitch: u8) void {
    vstiActiveSet(engine, i, pitch, false);
    vstiPush(engine, i, .{
        .sampleOffset = 0,
        .type = @intFromEnum(ivstevents.Event.EventTypes.kNoteOffEvent),
        .data = .{ .noteOff = .{
            .channel = 0,
            .pitch = @intCast(pitch),
            .velocity = 0,
            .noteId = -1,
        } },
    });
}

/// VSTi：按位图补发全部 note-off（暂停/跳转/切类型/全体释音共用）
fn vstiAllOff(engine: *Engine, i: usize) void {
    var lo = engine.vsti_active_lo[i];
    while (lo != 0) {
        const p: u8 = @intCast(@ctz(lo));
        lo &= lo - 1;
        vstiNoteOff(engine, i, p);
    }
    var hi = engine.vsti_active_hi[i];
    while (hi != 0) {
        const p: u8 = @intCast(@ctz(hi));
        hi &= hi - 1;
        vstiNoteOff(engine, i, p + 64);
    }
}

/// 传输边沿处理：**暂停时释放全部声部**（两个池）。
/// 否则已发声的声部会永远停在 ADSR 的 sustain 段（实测 bug：暂停后音符一直响）。
/// 放在音频层（而非 UI）——任何把 playing 置 false 的路径都会生效。
/// 释音后的尾音仍会被渲染（非播放路径照常 render）。
pub fn transportEdge(engine: *Engine, playing: bool) void {
    if (!playing and engine.was_playing) {
        releaseAllVoices(engine);
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
        releaseAllVoices(engine);
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
    // 去重：清掉**同键（种类+音高+乐器+步）的更旧编辑代**副本——
    // 快速连续编辑（或 store/读竞态）时多代副本会同时在 stash 里存活，
    // 全部触发就双发（on 双声部 → off 只释一个 → 悬挂）。
    // 同代重复**保留**（合法：同位置同音高的两个音符本就该发两条事件）。
    var di: usize = 0;
    while (di < engine.stash_n) {
        const ex = engine.stash[di];
        if (ex.edit_gen < ev.edit_gen and ex.kind == ev.kind and ex.pitch == ev.pitch and
            ex.instrument == ev.instrument and ex.step == ev.step)
        {
            std.mem.copyForwards(synth.SchedEvent, engine.stash[di .. engine.stash_n - 1], engine.stash[di + 1 .. engine.stash_n]);
            engine.stash_n -= 1;
        } else {
            di += 1;
        }
    }
    // 从尾部往前找插入点（stash 已按步序）
    var i: usize = engine.stash_n;
    while (i > 0 and synth.schedEventLess({}, ev, engine.stash[i - 1])) : (i -= 1) {
        engine.stash[i] = engine.stash[i - 1];
    }
    engine.stash[i] = ev;
    engine.stash_n += 1;
}

/// 调度事件是否应**作废**（丢弃但不释放声部——与 `gen` 变化的区别）：
/// - 旧传输代（`ev.gen != gen`）：reset/跳转语义，作废；
/// - 旧编辑代且**步号 >= 该代重扫的安全界**：已有重发副本替换，作废；
/// - 旧编辑代但步号更低：**保留触发**——重扫没覆盖这段（见
///   `sequencer.rescanForEdit`），它们还没被音频走到，正常触发一次即可。
fn schedEventObsolete(ev: synth.SchedEvent, gen: u32, edit_gen: u32, rescan_from: i32) bool {
    if (ev.gen != gen) return true;
    return ev.edit_gen < edit_gen and ev.step >= rescan_from;
}

/// 回传“正在发声的音高”（位掩码；UI 用于播放/试听高亮）。
/// 鼓组：各层池的并集（层与垫多对一，并集即该组当前发声的音高）。
fn publishSounding(engine: *Engine, params: *Params) void {
    for (0..synth.max_instruments) |i| {
        if (params.instrument_kind[i].load(.monotonic) == 2) {
            // VST3 乐器：直接发布 note-on 活跃位图（宿主侧无声部模型；
            // 位图由 vstiNoteOn/Off 维护——暂停/释音也经 all-off 同位清）
            params.sounding_lo[i].store(engine.vsti_active_lo[i], .monotonic);
            params.sounding_hi[i].store(engine.vsti_active_hi[i], .monotonic);
            continue;
        }
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
        // 鼓组层池（未用到的池全空闲，扫描成本低）
        const kbase = i * kit_max_layers;
        for (0..kit_max_layers) |l| {
            for (engine.kit_synths[kbase + l].voices) |v| {
                if (!synth.isSounding(&v)) continue;
                const p = v.pitch;
                if (p < 0 or p > 127) continue;
                if (p < 64) {
                    lo |= @as(u64, 1) << @intCast(p);
                } else {
                    hi |= @as(u64, 1) << @intCast(p - 64);
                }
            }
        }
        params.sounding_lo[i].store(lo, .monotonic);
        params.sounding_hi[i].store(hi, .monotonic);
    }
}

/// 合成有效声像：乐器声像（0-1）为**基准**，音符级声像（0-127）是**偏移**
/// （Sawdust 特色：MIDI 本身无音符级声像；导入的音符居中 → 完全跟随乐器）。
/// 合成后走**单次**等功率渲染——避免两次声像串行（乐器偏左会“挡住”想上右的音符）。
pub fn effectivePan(inst_pan: f32, note_pan: u8) u8 {
    const base: f32 = std.math.clamp(inst_pan, 0.0, 1.0) * 127.0;
    const v: f32 = base + @as(f32, @floatFromInt(note_pan)) - 64.0;
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 127.0)));
}

/// VSTi 立体声平衡（等功率）：插件输出当**立体声总线**处理，声像旋钮 0..1
/// 映射到两侧增益。0.5 = 原样（两侧 ×1）；两端 = 单侧 ×√2、另一侧 0。
/// 恒有 gl² + gr² ≡ 2（与合成器逐音声像同一功率基准）。
/// 注：插件自己的声像不被改动（只作用于其后的总线平衡）。“Vital 音色偏右 +
/// 旋钮偏左 → 听感居中”即靠它。
pub fn balanceGains(pan: f32) [2]f32 {
    const p = std.math.clamp(pan, 0.0, 1.0);
    const ang = p * (std.math.pi / 2.0);
    return .{ @cos(ang) * std.math.sqrt2, @sin(ang) * std.math.sqrt2 };
}

/// 当前段的宿主时间（ProcessContext：tempo/拍号/播放位置/ppq）
fn currentHostTime(engine: *Engine, params: *Params, sr: f32) vst_host.HostTime {
    const playing = params.playing.load(.monotonic);
    const bpm: u32 = @max(20, params.bpm.load(.monotonic));
    const spb: u32 = @max(1, params.steps_per_beat.load(.monotonic));
    const start_frame = params.start_frame.load(.monotonic);
    const abs = engine.seg_abs0;
    var ppq: f64 = 0;
    if (playing and abs >= start_frame) {
        // 每步 = 1/spb 拍；拍 = 四分音符
        const step_frames = @as(f64, sr) * 60.0 / (@as(f64, @floatFromInt(bpm)) * @as(f64, @floatFromInt(spb)));
        ppq = (@as(f64, @floatFromInt(abs - start_frame)) / step_frames) / @as(f64, @floatFromInt(spb));
    }
    return .{
        .playing = playing,
        .tempo = @floatFromInt(bpm),
        .time_num = params.time_num.load(.monotonic),
        .time_den = params.time_den.load(.monotonic),
        .abs_samples = abs,
        .ppq = ppq,
    };
}

/// 触发一个音符事件（音频线程；`SchedEvent` / `NoteEvent` 均可——字段兼容）。
/// **鼓组分支**：on 按音高分发到匹配层；off **不查映射**直接对所有层——
/// 防“响着时改映射”漏 off → 悬挂（与调音台教训一致）。
fn dispatchNote(engine: *Engine, ev: anytype) void {
    if (ev.instrument >= synth.max_instruments) return;
    const params = engine.params;
    const kind = params.instrument_kind[ev.instrument].load(.monotonic);
    const is_kit = kind == 1;
    const is_vsti = kind == 2;
    const base = @as(usize, ev.instrument) * kit_max_layers;
    switch (ev.kind) {
        .on => {
            // **有效声像** = 乐器声像（基准）+ 音符级偏移（Sawdust 特色）
            const pan = effectivePan(params.instrument_pan[ev.instrument].load(.monotonic), ev.pan);
            if (is_vsti) {
                vstiNoteOn(engine, ev.instrument, ev.pitch, ev.velocity);
            } else if (is_kit) {
                const n_layers = @min(params.kit_layer_count[ev.instrument].load(.monotonic), kit_max_layers);
                for (0..n_layers) |l| {
                    if (params.kit_layer_pitch[ev.instrument][l].load(.monotonic) != ev.pitch) continue;
                    synth.noteOn(&engine.kit_synths[base + l], ev.pitch, ev.velocity, pan);
                }
            } else {
                synth.noteOn(&engine.synths[ev.instrument], ev.pitch, ev.velocity, pan);
            }
        },
        .off => {
            if (is_vsti) {
                vstiNoteOff(engine, ev.instrument, ev.pitch);
            } else if (is_kit) {
                // 全部层都收 off（无关层空转——防漏 off）
                const n_layers = @min(params.kit_layer_count[ev.instrument].load(.monotonic), kit_max_layers);
                for (0..n_layers) |l| synth.noteOff(&engine.kit_synths[base + l], ev.pitch);
                // 类型刚切走的边角：synth 池也发一份（空转无害）
                synth.noteOff(&engine.synths[ev.instrument], ev.pitch);
            } else {
                synth.noteOff(&engine.synths[ev.instrument], ev.pitch);
            }
        },
        .all_off => {
            releaseAllVoices(engine);
        },
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
    // 本段的宿主时间（tempo/拍号/位置/ppq；VST3 插件的 ProcessContext）
    const host_time = currentHostTime(engine, params, sr);

    // 频谱目标（UI 每帧发布）：目标效果器所在通道/槽位（-1 = 不分析）。
    // 目标变化时丢弃旧滑窗——否则两种信号的样本会混进同一窗（频谱错乱）。
    const tgt_ch = params.spec_target_ch.load(.monotonic);
    const tgt_slot = params.spec_target_slot.load(.monotonic);
    if (engine.spec_target_seen[0] != tgt_ch or engine.spec_target_seen[1] != tgt_slot) {
        engine.spec_target_seen = .{ tgt_ch, tgt_slot };
        engine.spec_pos = 0;
        engine.spec_ready = false;
    }

    // 1) 所有通道缓冲清零
    for (0..n_ch) |ci| @memset(engine.chan_bufs[ci * buf_stride ..][0..n], 0);

    // 2) 乐器 → 各自通道的缓冲（**按通道路由分开渲染**——通道 EQ 必须逐通道）
    for (0..synth.max_instruments) |i| {
        const kind = params.instrument_kind[i].load(.monotonic);
        const ch: usize = @min(params.instrument_channel[i].load(.monotonic), if (n_ch > 0) n_ch - 1 else 0);
        const g = params.instrument_gain[i].load(.monotonic); // 乐器音量×静音（推子前）
        const cbuf: [*]f32 = @ptrCast(&engine.chan_bufs[ch * buf_stride]);
        if (kind == 2) {
            // VST3 乐器（VSTi）：渲染到中转缓冲 → 增益 × 等功率立体声平衡 → 叠加进通道缓冲
            // （插件是原位写出，不能直接覆盖通道缓冲：同通道其他乐器/乐器的已渲染内容。
            //  声像 = 标准立体声平衡：输出当立体声总线，按旋钮位置对两侧做等功率增益）
            const pl = params.instrument_plugin[i].load(.monotonic) orelse continue;
            if (engine.vsti_scratch.len < n) continue; // 中转缓冲未初始化（测试环境）：未加载即跳过
            const sc = engine.vsti_scratch[0..n];
            @memset(sc, 0);
            // 本段事件（段边界 = 事件时刻 → offset 全 0）；消费后清零
            pl.processInstrument(sc, frames, engine.vsti_events[i][0..engine.vsti_event_n[i]], host_time);
            engine.vsti_event_n[i] = 0;
            const bg = balanceGains(params.instrument_pan[i].load(.monotonic));
            var k: usize = 0;
            while (k < n) : (k += 2) {
                cbuf[k] += sc[k] * g * bg[0];
                cbuf[k + 1] += sc[k + 1] * g * bg[1];
            }
            continue;
        }
        const sp = params.synth_ptrs[i].load(.monotonic) orelse continue;
        if (kind == 1) {
            // 鼓组：逐层渲染叠加进同一通道缓冲（整组走同一调音台链）
            const n_layers = @min(params.kit_layer_count[i].load(.monotonic), kit_max_layers);
            const base = i * kit_max_layers;
            for (0..n_layers) |l| {
                const lp = params.kit_layer_params[i][l].load(.monotonic) orelse continue;
                const lg = params.kit_layer_gain[i][l].load(.monotonic);
                synth.render(lp, &engine.kit_synths[base + l], cbuf, frames, sr, g * lg, true);
            }
        } else {
            synth.render(sp, &engine.synths[i], cbuf, frames, sr, g, true);
        }
    }

    // 3) **子通道（1..）**：效果链 → 增益（含静音）→ 等功率声像 → **汇入主通道缓冲**
    // 注：此处**不含 master**——master 只在主通道出口乘一次（否则会重复相乘）
    var ch_i: usize = 1;
    while (ch_i < n_ch) : (ch_i += 1) {
        const buf = engine.chan_bufs[ch_i * buf_stride ..][0..n];
        processChannelChain(engine, params, ch_i, buf, frames, sr, tgt_ch, tgt_slot);

        const gain = if (params.channel_muted[ch_i].load(.monotonic)) 0.0 else params.channel_gain[ch_i].load(.monotonic);
        const pan = std.math.clamp(params.channel_pan[ch_i].load(.monotonic), 0, 1);
        const ang = pan * (std.math.pi / 2.0);
        const gl = @cos(ang) * gain * std.math.sqrt2;
        const gr = @sin(ang) * gain * std.math.sqrt2;
        const dst = engine.chan_bufs[0..][0..n];
        var f2: usize = 0;
        while (f2 < frames) : (f2 += 1) {
            dst[f2 * 2] += buf[f2 * 2] * gl;
            dst[f2 * 2 + 1] += buf[f2 * 2 + 1] * gr;
        }
    }

    // 4) **主通道（0）**：直连乐器 + 全部子通道汇入 → 效果链 → 主推子/声像 → 输出
    // （“主通道嘛”：所有通道的音频最终都经它；其效果器作用在**汇总信号**上）
    if (n_ch > 0) {
        const buf = engine.chan_bufs[0..][0..n];
        processChannelChain(engine, params, 0, buf, frames, sr, tgt_ch, tgt_slot);
        const gain = if (params.channel_muted[0].load(.monotonic)) 0.0 else params.channel_gain[0].load(.monotonic);
        const pan = std.math.clamp(params.channel_pan[0].load(.monotonic), 0, 1);
        const ang = pan * (std.math.pi / 2.0);
        const gl = @cos(ang) * gain * master * std.math.sqrt2;
        const gr = @sin(ang) * gain * master * std.math.sqrt2;
        var f2: usize = 0;
        while (f2 < frames) : (f2 += 1) {
            out[f2 * 2] += buf[f2 * 2] * gl;
            out[f2 * 2 + 1] += buf[f2 * 2 + 1] * gr;
        }
    }

    // 频谱分析（窗满时）——数据来自目标效果器的**输入点**（上面的捕获），
    // 不是主输出全混。
    analyzeSpectrum(engine, params, sr);
}
/// 单通道效果链处理（EQ 系数重建 + 逐槽处理 + 频谱捕获）。
/// 注：**无“无乐器跳过”优化**——混响/延迟的尾音需状态持续推进（空缓冲
/// 处理廉价）；主通道还会承载子通道汇入信号。
fn processChannelChain(engine: *Engine, params: *Params, ch_i: usize, buf: []f32, frames: u32, sr: f32, tgt_ch: i32, tgt_slot: i32) void {
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

    // 效果器链长度（以 `effect_count` 为准）
    const eff_n: usize = @min(params.effect_count[ch_i].load(.monotonic), effect_slots);

    // ── 效果器链（插件式；按槽顺序）──
    // 干湿比：效果信号与干声逐样本混合（mix = 0 为完全干声）
    var slot: usize = 0;
    while (slot < eff_n) : (slot += 1) {
        // 频谱捕获点 = 目标效果器的**输入**（本槽处理之前）。
        // 注：与本槽是否 EQ/启用无关——“进入该效果器的声音”与旁通态无关。
        if (@as(i32, @intCast(ch_i)) == tgt_ch and @as(i32, @intCast(slot)) == tgt_slot) {
            captureSpectrum(engine, buf, frames);
        }
        const kind = params.effect_kind[ch_i][slot].load(.monotonic);
        if (!params.effect_enabled[ch_i][slot].load(.monotonic)) continue; // 旁通
        const mix = std.math.clamp(params.effect_mix[ch_i][slot].load(.monotonic), 0, 1);
        switch (kind) {
            1 => { // EQ（干湿比 = “EQ 强度”）
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
            },
        5 => { // VST3 插件（实例未加载 → 直通；由 UI 侧惰性加载/退役）
            if (params.plugin_ptrs[ch_i][slot].load(.monotonic)) |pl| pl.processWithHost(buf, frames, currentHostTime(engine, params, sr));
        },
            2, 3, 4 => { // 混响 / 延迟 / 压缩器：**每槽独立状态盒**（UI 发布指针）
                const raw = params.fx_ptrs[ch_i][slot].load(.monotonic) orelse continue;
                const box: *FxBox = @ptrCast(@alignCast(raw));
                var p: [fx.max_params]f32 = undefined;
                for (0..fx.max_params) |pi| p[pi] = params.effect_p[ch_i][slot][pi].load(.monotonic);
                // 每拍秒数（延迟卡拍用；BPM 已钳到 ≥20，与序列器换算同一口径）
                const beat_secs: f32 = 60.0 / @as(f32, @floatFromInt(@max(20, params.bpm.load(.monotonic))));
                // 按**盒内 kind** 分派（链 kind 与指针更新有帧间竞态；盒是自洽的）
                switch (box.kind) {
                    2 => box.payload.reverb.process(buf, frames, sr, &p, mix),
                    3 => box.payload.delay.process(buf, frames, sr, &p, mix, beat_secs),
                    else => box.payload.comp.process(buf, frames, sr, &p, mix),
                }
            },
            else => {},
        }
    }
}

/// 频谱捕获：把**目标效果器输入点**的通道缓冲抽取入滑窗（每 8 帧取 1 个；
/// 48k → 6kHz 有效带宽，覆盖显示范围足够）。窗满时置 `spec_ready`
/// （FFT 在 `renderSegment` 末尾统一做）。
fn captureSpectrum(engine: *Engine, buf: []const f32, frames: u32) void {
    const stride: usize = 8;
    var f: usize = 0;
    while (f < frames) : (f += stride) {
        const s = (buf[f * 2] + buf[f * 2 + 1]) * 0.5;
        engine.spec_win[engine.spec_pos] = s;
        engine.spec_pos = (engine.spec_pos + 1) % eq.fft_size;
        if (engine.spec_pos == 0) {
            engine.spec_ready = true;
        }
    }
}

/// 频谱分析：窗满（`spec_ready`）时 FFT → 柱形回传（`params.spec_bars`）。
/// 每段渲染末尾调用（一次分析 ≈ 2048 输入样本 ≈ 43ms @48k）。
///
/// 注：**不能要求块结束时 pos == 0**——frames % fft_size 不整除时
/// 永远凑不齐（实测 bug：测试里频谱恒为 0）。故由 `spec_ready` 标记。
fn analyzeSpectrum(engine: *Engine, params: *Params, sr: f32) void {
    if (!engine.spec_ready) return;
    engine.spec_ready = false;

    // 窗内样本重排（写指针 pos 处 = 最旧样本）
    const stride: f32 = 8.0; // 抽样步长（与 captureSpectrum 一致）
    const eff_sr = sr / stride;
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

/// 乐器**类型切换边沿**：两个声部池都全释音
/// （切 synth ⇄ drumkit 时旧类型的声部不能继续响——防悬挂）
fn applyKindEdges(engine: *Engine) void {
    const params = engine.params;
    for (0..synth.max_instruments) |i| {
        const k = params.instrument_kind[i].load(.monotonic);
        if (k == engine.last_kind[i]) continue;
        engine.last_kind[i] = k;
        synth.allOff(&engine.synths[i]);
        const kbase = i * kit_max_layers;
        for (0..kit_max_layers) |l| synth.allOff(&engine.kit_synths[kbase + l]);
        // VSTi：类型切走/切回都补 off（防悬挂）；待发批一并作废
        vstiAllOff(engine, i);
        engine.vsti_event_n[i] = 0;
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

    // 1) 立即事件（试听 / all_off）——与调度事件共用分发（含鼓组分支）
    var evbuf: [synth.drain_max]synth.NoteEvent = undefined;
    const n_imm = params.events.drain(&evbuf);
    for (evbuf[0..n_imm]) |ev| dispatchNote(engine, ev);

    // 2) 清空输出（之后按分段叠加渲染）
    @memset(out[0 .. @as(usize, frames) * 2], 0);

    // 2.1) 乐器**类型切换边沿**：两个声部池都全释音
    applyKindEdges(engine);

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
        engine.seg_abs0 = params.frames_played.load(.monotonic);
        renderSegment(engine, params, out, frames, sr, master);
        publishSounding(engine, params);
        _ = params.frames_played.fetchAdd(frames, .monotonic);
        return;
    }

    // 4) 播放：stash 管理 + 样本级事件触发
    if (gen != engine.stash_gen) handleGenChange(engine, gen, was_playing);
    // 编辑代（重扫）：**不**清空 stash（有 drain 竞态会丢新事件），
    // 由触发循环按 `schedEventObsolete` 过滤——在响的音符保持发声。
    // 注：读顺序为“代后界”（界先于代发布，读到新代时界必已就位）
    const edit_gen = params.sched_edit_gen.load(.monotonic);
    const rescan_from = params.sched_rescan_from.load(.monotonic);
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
        if (schedEventObsolete(ev, gen, edit_gen, rescan_from)) {
            si += 1; // 作废（旧传输代 / 已被重发替换的旧编辑代）：丢弃，**不**释放声部
            continue;
        }
        // 事件应在的绝对帧位置
        const ev_frame: i64 = @as(i64, @intCast(start_frame)) +
            (@as(i64, ev.step) - @as(i64, start_step)) * @as(i64, @intCast(step_frames));
        const cur: i64 = @as(i64, @intCast(abs0)) + @as(i64, done);
        if (ev_frame <= cur) {
            dispatchNote(engine, ev); // 已到时（含“起播前就应触发”的补发事件）
            si += 1;
            continue;
        }
        // 未到时：渲染到事件边界为止
        const off: u64 = @intCast(ev_frame - cur);
        const seg: u32 = @intCast(@min(@as(u64, frames - done), off));
        if (seg == 0) break;
        engine.seg_abs0 = abs0 + done;
        renderSegment(engine, params, out + done * 2, seg, sr, master);
        done += seg;
    }
    if (done < frames) {
        engine.seg_abs0 = abs0 + done;
        renderSegment(engine, params, out + done * 2, frames - done, sr, master);
    }

    // 5) stash 压缩（保留未处理的事件）
    if (si > 0) {
        const remaining = engine.stash_n - si;
        std.mem.copyForwards(synth.SchedEvent, engine.stash[0..remaining], engine.stash[si..engine.stash_n]);
        engine.stash_n = remaining;
    }

    // 6) 频谱回传：已在 `renderSegment` 末尾完成（目标效果器输入点）

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
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), p.volume.load(.monotonic), 0.001);
    try std.testing.expect(!p.playing.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), p.sched_gen.load(.monotonic));
    try std.testing.expect(p.synth_ptrs[0].load(.monotonic) == null);
}

test "audio: 事件作废判定——旧代低步保留（安全界过滤）" {
    // 实测 bug：重扫把音频已走过的 on 再发一次 → 双声部 → off 只释一个 →
    // 悬挂。修法：重扫从**安全界**起；音频只作废“步 >= 安全界”的旧编辑代
    // 事件（已有重发副本替换），低于安全界的旧副本保留、正常触发一次。
    const ev = synth.SchedEvent{ .kind = .on, .pitch = 60, .step = 12, .gen = 1, .edit_gen = 1 };
    // 同代：任何情况都不作废
    try std.testing.expect(!schedEventObsolete(ev, 1, 1, 14));
    try std.testing.expect(!schedEventObsolete(ev, 1, 1, 0));
    // 旧传输代：作废（reset/跳转语义，不管步号）
    try std.testing.expect(schedEventObsolete(ev, 2, 1, 14));
    try std.testing.expect(schedEventObsolete(ev, 2, 1, 0));
    // 旧编辑代 + 步 >= 安全界：作废（有重发副本）
    var big = ev;
    big.step = 20;
    try std.testing.expect(schedEventObsolete(big, 1, 2, 14));
    try std.testing.expect(schedEventObsolete(big, 1, 2, 20)); // 边界：等于安全界 → 作废
    // 旧编辑代 + 步 < 安全界：**保留**（重扫没覆盖这段；必须触发一次）
    try std.testing.expect(!schedEventObsolete(ev, 1, 2, 14));
}

test "audio: stash 去重——同键更旧代被替换；同代重复保留" {
    var params = Params{};
    var engine = Engine{ .params = &params };

    // 旧副本（代 1）→ 重发副本（代 2）：后者插入时清掉前者
    const e1 = synth.SchedEvent{ .kind = .on, .pitch = 60, .instrument = 0, .step = 100, .gen = 1, .edit_gen = 1 };
    var e2 = e1;
    e2.edit_gen = 2;
    stashInsert(&engine, e1);
    stashInsert(&engine, e2);
    try std.testing.expectEqual(@as(usize, 1), engine.stash_n);
    try std.testing.expectEqual(@as(u32, 2), engine.stash[0].edit_gen);

    // 同代重复：两条都保留（合法：同位置同音高的两个音符）
    stashInsert(&engine, e2);
    try std.testing.expectEqual(@as(usize, 2), engine.stash_n);

    // 不同键（不同步号）不受影响，且保持步序
    var e3 = e1;
    e3.step = 50;
    e3.edit_gen = 3;
    stashInsert(&engine, e3);
    try std.testing.expectEqual(@as(usize, 3), engine.stash_n);
    try std.testing.expectEqual(@as(i32, 50), engine.stash[0].step); // 插入到最前

    // 不同编辑代的“不同种类/音高”不误删
    var off = e2;
    off.kind = .off;
    stashInsert(&engine, off);
    try std.testing.expectEqual(@as(usize, 4), engine.stash_n);
}

test "audio: EQ 干湿比生效（100% 与 0% 输出显著不同——非占位）" {
    // 干湿（dry/wet）：dry = 未处理原声、wet = 效果输出；
    // mix = 输出中效果声的混合比例（0 = 完全旁通、1 = 完全处理）。
    // 本测试证明它**真实作用于 DSP**（用户实测“没感觉”另见：EQ 默认曲线
    // 全平——无增益时滤波器直接跳过，此时混什么都不变）。
    const alloc = std.testing.allocator;

    const energy = struct {
        fn run(alloc_: std.mem.Allocator, mix: f32) !f64 {
            var params = Params{};
            var engine = Engine{ .params = &params };
            engine.synths = try alloc_.alloc(synth.Synth, 1);
            defer alloc_.free(engine.synths);
            engine.synths[0] = .{};
            engine.chan_bufs = try alloc_.alloc(f32, mixer_channels * 2 * 4096);
            defer alloc_.free(engine.chan_bufs);
            engine.slot_eq = try alloc_.alloc(eq.Biquad, mixer_channels * effect_slots * eq_bands * 2);
            defer alloc_.free(engine.slot_eq);
            @memset(engine.slot_eq, .{});

            var sp = synth.SynthParams{ .attack = std.atomic.Value(f32).init(0.0) };
            params.channel_count.store(1, .monotonic);
            params.volume.store(1.0, .monotonic);
            params.synth_ptrs[0].store(&sp, .monotonic);
            params.instrument_channel[0].store(0, .monotonic);
            params.instrument_gain[0].store(1.0, .monotonic);
            // EQ：440Hz +12dB 峰值；干湿 = mix
            params.effect_count[0].store(1, .monotonic);
            params.effect_kind[0][0].store(1, .monotonic);
            params.effect_enabled[0][0].store(true, .monotonic);
            params.effect_mix[0][0].store(mix, .monotonic);
            params.channel_eq[0][0] = .{ .freq = 440, .q = 1.0, .gain_db = 12 };
            params.channel_eq_version[0].store(1, .monotonic);

            synth.noteOn(&engine.synths[0], 69, 30, 64); // A4 = 440Hz（小力度防软削波压缩）
            var out: [1024 * 2]f32 = undefined;
            var total: f64 = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                @memset(&out, 0);
                renderSegment(&engine, &params, &out, 1024, 48000, 1.0);
                for (out) |s| total += @as(f64, s) * s;
            }
            return total;
        }
    }.run;

    const e_wet = try energy(alloc, 1.0); // 100%：完全 EQ
    const e_dry = try energy(alloc, 0.0); // 0%：完全旁通
    try std.testing.expect(e_dry > 0);
    // +12dB 峰值在中心频率 ≈ 4× 幅度 ≈ 16× 能量（软削波会压缩，断言放宽到 2×）
    try std.testing.expect(e_wet > e_dry * 2);
    // 50% 介于两者之间
    const e_mid = try energy(alloc, 0.5);
    try std.testing.expect(e_mid > e_dry and e_mid < e_wet);
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

test "audio: 暂停/跳转边沿也释放鼓组层池（修“暂停后鼓声一直响到停止”）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);
    const engine = &env.engine;

    var lp0 = synth.SynthParams{};
    lp0.release.store(0.0, .monotonic); // 1ms 释音
    env.setLayers(&.{35}, &.{&lp0});
    var buf: [4800 * 2]f32 = undefined; // 0.1s @ 48k

    // ① 暂停下降沿：鼓组层进入释音（旧代码只释放 synths → 鼓声悬挂）
    dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.kit_synths[0]));
    engine.was_playing = true;
    transportEdge(engine, false);
    synth.render(&lp0, &engine.kit_synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.kit_synths[0]));

    // ② 跳转（gen 变化且播放中）：同样释放层池
    dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.kit_synths[0]));
    handleGenChange(engine, engine.stash_gen + 1, true);
    synth.render(&lp0, &engine.kit_synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.kit_synths[0]));
}

test "audio: 频谱取自目标效果器输入（非主输出全混）" {
    const alloc = std.testing.allocator;
    var params = Params{};
    var engine = Engine{ .params = &params };
    engine.synths = try alloc.alloc(synth.Synth, 2);
    defer alloc.free(engine.synths);
    engine.synths[0] = .{};
    engine.synths[1] = .{};
    engine.chan_bufs = try alloc.alloc(f32, mixer_channels * 2 * 4096);
    defer alloc.free(engine.chan_bufs);
    engine.slot_eq = try alloc.alloc(eq.Biquad, mixer_channels * effect_slots * eq_bands * 2);
    defer alloc.free(engine.slot_eq);
    @memset(engine.slot_eq, .{});

    // 乐器 0 → 通道 0，乐器 1 → 通道 1；通道 0 有 1 个 EQ 槽
    var sp0 = synth.SynthParams{};
    var sp1 = synth.SynthParams{};
    params.channel_count.store(2, .monotonic);
    params.volume.store(1.0, .monotonic);
    params.synth_ptrs[0].store(&sp0, .monotonic);
    params.instrument_channel[0].store(0, .monotonic);
    params.instrument_gain[0].store(1.0, .monotonic);
    params.synth_ptrs[1].store(&sp1, .monotonic);
    params.instrument_channel[1].store(1, .monotonic);
    params.instrument_gain[1].store(1.0, .monotonic);
    params.effect_count[0].store(1, .monotonic);
    params.effect_kind[0][0].store(1, .monotonic);
    params.effect_enabled[0][0].store(true, .monotonic);
    // 通道 1 也挂一个 EQ 槽（频谱目标可以指向它——捕获点要求槽存在）
    params.effect_count[1].store(1, .monotonic);
    params.effect_kind[1][0].store(1, .monotonic);
    params.effect_enabled[1][0].store(true, .monotonic);

    // 两个乐器同时发声（A4）
    synth.noteOn(&engine.synths[0], 69, synth.default_velocity, synth.default_pan);
    synth.noteOn(&engine.synths[1], 69, synth.default_velocity, synth.default_pan);

    const F = 512;
    var out: [F * 2]f32 = undefined;

    // ① 目标未发布（-1）：不分析（版本不增）
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        @memset(&out, 0);
        renderSegment(&engine, &params, &out, F, 48000, 1.0);
    }
    try std.testing.expectEqual(@as(u32, 0), params.spec_version.load(.monotonic));

    // ② 目标 = 通道 0 槽 0：渲染满一窗（fft_size×8 = 2048 样本）→ 有分析、柱非零
    params.spec_target_ch.store(0, .monotonic);
    params.spec_target_slot.store(0, .monotonic);
    i = 0;
    while (i < 4) : (i += 1) {
        @memset(&out, 0);
        renderSegment(&engine, &params, &out, F, 48000, 1.0);
    }
    try std.testing.expect(params.spec_version.load(.monotonic) > 0);
    var max_bar: f32 = 0;
    for (params.spec_bars) |b| max_bar = @max(max_bar, b.load(.monotonic));
    try std.testing.expect(max_bar > 0.05); // 目标通道在发声：频谱非零

    // ③ 通道 1 静音（乐器移走），通道 0 仍在发声：
    // 目标 = 通道 1 → 频谱应衰减到 ~0（旧实现会一直显示主输出全混 → 非零）；
    // 注：聚合架构下**通道 0 的输入 = 全混**（子通道汇入）——
    // 要验“非全混”，目标需指向一个真静音的子通道
    params.synth_ptrs[1].store(null, .monotonic);
    // 先把旧窗清掉（目标切换会重置滑窗）：-1 → 1
    params.spec_target_ch.store(-1, .monotonic);
    @memset(&out, 0);
    renderSegment(&engine, &params, &out, 8, 48000, 1.0);
    params.spec_target_ch.store(1, .monotonic);
    i = 0;
    while (i < 8) : (i += 1) { // 两窗（4096 样本）：第一窗混旧样本，第二窗纯静音
        @memset(&out, 0);
        renderSegment(&engine, &params, &out, F, 48000, 1.0);
    }
    max_bar = 0;
    for (params.spec_bars) |b| max_bar = @max(max_bar, b.load(.monotonic));
    // 通道 0 仍在响（主输出非零）——但目标通道已静音 → 频谱≈0
    var mix_energy: f32 = 0;
    @memset(&out, 0);
    renderSegment(&engine, &params, &out, F, 48000, 1.0);
    for (out) |s| mix_energy += @abs(s);
    try std.testing.expect(mix_energy > 1.0); // 主输出仍有声（通道 0）
    try std.testing.expect(max_bar < 0.01); // 而频谱已衰减到零（非全混）

    // ④ 目标切换会重置滑窗
    params.spec_target_ch.store(0, .monotonic);
    @memset(&out, 0);
    renderSegment(&engine, &params, &out, 8, 48000, 1.0);
    try std.testing.expectEqual(@as(usize, 1), engine.spec_pos); // 8/8（新目标从头开始）
}

// ── 鼓组（阶段 2）──

/// 鼓组测试的公共搭建：分配两个声部池 + 最小引擎缓冲。
/// **必须原地初始化**（`env.init(...)`）——`engine.params` 指向 `env` 自身，
/// 按值返回会让指针悬空到已死的栈帧（实测：所有断言读不到参数）。
const KitTestEnv = struct {
    params: Params = .{},
    engine: Engine = undefined,

    fn init(self: *KitTestEnv, alloc: std.mem.Allocator, with_bufs: bool) !void {
        self.* = .{};
        self.engine = Engine{ .params = &self.params };
        self.engine.synths = try alloc.alloc(synth.Synth, 1);
        self.engine.synths[0] = .{};
        self.engine.kit_synths = try alloc.alloc(synth.KitLayerSynth, synth.max_instruments * kit_max_layers);
        for (self.engine.kit_synths) |*s| s.* = .{};
        if (with_bufs) {
            self.engine.chan_bufs = try alloc.alloc(f32, mixer_channels * 2 * 4096);
            self.engine.slot_eq = try alloc.alloc(eq.Biquad, mixer_channels * effect_slots * eq_bands * 2);
            @memset(self.engine.slot_eq, .{});
        }
    }

    fn deinit(self: *KitTestEnv, alloc: std.mem.Allocator) void {
        alloc.free(self.engine.synths);
        alloc.free(self.engine.kit_synths);
        if (self.engine.chan_bufs.len > 0) alloc.free(self.engine.chan_bufs);
        if (self.engine.slot_eq.len > 0) alloc.free(self.engine.slot_eq);
        if (self.engine.vsti_scratch.len > 0) alloc.free(self.engine.vsti_scratch);
    }

    /// 组 0 设为鼓组；槽位按 (音高, 参数) 逐对写入
    fn setLayers(self: *KitTestEnv, pitches: []const u32, lps: []const *synth.SynthParams) void {
        self.params.instrument_kind[0].store(1, .monotonic);
        self.params.kit_layer_count[0].store(@intCast(lps.len), .monotonic);
        for (pitches, 0..) |p, i| {
            self.params.kit_layer_pitch[0][i].store(p, .monotonic);
            self.params.kit_layer_gain[0][i].store(1.0, .monotonic);
            self.params.kit_layer_params[0][i].store(lps[i], .monotonic);
        }
    }
};

test "audio: 鼓组——on 按音高分发（同音多层全触发）、off 全层、高亮并集" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);

    var lp0 = synth.SynthParams{};
    var lp1 = synth.SynthParams{};
    var lp2 = synth.SynthParams{};
    var gate = synth.SynthParams{};
    env.setLayers(&.{ 35, 35, 38 }, &.{ &lp0, &lp1, &lp2 });
    env.params.synth_ptrs[0].store(&gate, .monotonic); // 高亮回传的门槛

    // on 35 → 槽位 0/1（同音高两层）都触发；槽位 2（38）不动
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&env.engine.kit_synths[0]));
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&env.engine.kit_synths[1]));
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&env.engine.kit_synths[2]));

    // 高亮并集：35；再响 38 → 两位都置
    publishSounding(&env.engine, &env.params);
    try std.testing.expect(env.params.sounding_lo[0].load(.monotonic) & (@as(u64, 1) << 35) != 0);
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 38, .instrument = 0 });
    publishSounding(&env.engine, &env.params);
    try std.testing.expect(env.params.sounding_lo[0].load(.monotonic) & (@as(u64, 1) << 38) != 0);

    // off 35：**全层**都收到（不查映射）——槽位 0/1 释放、槽位 2 不受影响
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .off, .pitch = 35, .instrument = 0 });
    var buf: [4800 * 2]f32 = undefined;
    synth.render(&lp0, &env.engine.kit_synths[0], &buf, 4800, 48000, 1.0, false);
    synth.render(&lp1, &env.engine.kit_synths[1], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&env.engine.kit_synths[0]));
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&env.engine.kit_synths[1]));
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&env.engine.kit_synths[2])); // 38 仍在响
}

test "audio: 鼓组——响着时改映射，off 仍全层下发（防漏 off 悬挂）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);

    var lp0 = synth.SynthParams{};
    var lp1 = synth.SynthParams{};
    env.setLayers(&.{ 35, 38 }, &.{ &lp0, &lp1 });

    // on 35 → 槽位 0 发声
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&env.engine.kit_synths[0]));

    // 响着时改映射：槽位 0 改成 36（模拟用户编辑）——old 35 声部还在响
    env.params.kit_layer_pitch[0][0].store(36, .monotonic);

    // off 35：不查映射 → 槽位 0 的 35 声部照常收到 noteOff → 释放
    // （若 off 查映射，这里会漏 → 悬挂，正是实测教训的模式）
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .off, .pitch = 35, .instrument = 0 });
    var buf: [4800 * 2]f32 = undefined;
    synth.render(&lp0, &env.engine.kit_synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&env.engine.kit_synths[0]));
}

test "audio: 鼓组——类型切换边沿释放两个池（防切类型悬挂）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);
    const engine = &env.engine;
    const params = &env.params;

    var sp = synth.SynthParams{};
    var lp0 = synth.SynthParams{};
    var buf: [4800 * 2]f32 = undefined;

    // synth 池发声 → kind 0 → 1（合成器切成鼓组）→ 边沿释放 synth 池
    synth.noteOn(&engine.synths[0], 60, synth.default_velocity, synth.default_pan);
    params.instrument_kind[0].store(1, .monotonic);
    applyKindEdges(engine);
    synth.render(&sp, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));

    // 鼓组层发声 → kind 1 → 0（鼓组切回合成器）→ 边沿释放层池
    var gate = synth.SynthParams{};
    env.setLayers(&.{35}, &.{&lp0});
    params.synth_ptrs[0].store(&gate, .monotonic);
    dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.kit_synths[0]));
    params.instrument_kind[0].store(0, .monotonic);
    applyKindEdges(engine);
    synth.render(&lp0, &engine.kit_synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.kit_synths[0]));

    // **只处理边沿**：kind 未变时重复调用不误杀试听声部
    synth.noteOn(&engine.synths[0], 64, synth.default_velocity, synth.default_pan);
    applyKindEdges(engine);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));
}

test "audio: 鼓组——渲染进通道缓冲（绑定音高有声、未绑定全静音）" {
    const alloc = std.testing.allocator;
    const energy = struct {
        fn run(alloc_: std.mem.Allocator, pitch: u8) !f64 {
            var env: KitTestEnv = undefined;
            try env.init(alloc_, true);
            defer env.deinit(alloc_);
            const engine = &env.engine;
            const params = &env.params;

            var lp0 = synth.SynthParams{};
            var gate = synth.SynthParams{};
            params.channel_count.store(1, .monotonic);
            params.volume.store(1.0, .monotonic);
            params.synth_ptrs[0].store(&gate, .monotonic);
            params.instrument_channel[0].store(0, .monotonic);
            params.instrument_gain[0].store(1.0, .monotonic);
            env.setLayers(&.{35}, &.{&lp0});

            dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = pitch, .instrument = 0 });
            var out: [1024 * 2]f32 = undefined;
            var total: f64 = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                @memset(&out, 0);
                renderSegment(engine, params, &out, 1024, 48000, 1.0);
                for (out) |s| total += @as(f64, s) * s;
            }
            return total;
        }
    }.run;

    try std.testing.expect(try energy(alloc, 35) > 1.0); // 绑定音高 → 有声
    try std.testing.expectEqual(@as(f64, 0), try energy(alloc, 60)); // 未绑定 → 全静音
}

test "audio: 鼓组——层增益生效（渲染能量随 gain 放大）" {
    const alloc = std.testing.allocator;
    const energy = struct {
        fn run(alloc_: std.mem.Allocator, gain: f32) !f64 {
            var env: KitTestEnv = undefined;
            try env.init(alloc_, true);
            defer env.deinit(alloc_);
            const engine = &env.engine;
            const params = &env.params;

            var lp0 = synth.SynthParams{};
            var gate = synth.SynthParams{};
            params.channel_count.store(1, .monotonic);
            params.volume.store(1.0, .monotonic);
            params.synth_ptrs[0].store(&gate, .monotonic);
            params.instrument_channel[0].store(0, .monotonic);
            params.instrument_gain[0].store(1.0, .monotonic);
            env.setLayers(&.{35}, &.{&lp0});
            params.kit_layer_gain[0][0].store(gain, .monotonic);

            dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
            var out: [1024 * 2]f32 = undefined;
            var total: f64 = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                @memset(&out, 0);
                renderSegment(engine, params, &out, 1024, 48000, 1.0);
                for (out) |s| total += @as(f64, s) * s;
            }
            return total;
        }
    }.run;

    const e_full = try energy(alloc, 1.0);
    const e_half = try energy(alloc, 0.5);
    // 能量 ∝ gain²（0.5² = 0.25）——软削波引入少量偏差，放宽到 ±20%
    try std.testing.expect(e_full > 1.0);
    try std.testing.expect(@abs(e_half / e_full - 0.25) < 0.05);
}

test "audio: 主通道聚合——子通道音频必经主通道（主推子/静音作用在汇总上）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, true);
    defer env.deinit(alloc);
    const engine = &env.engine;
    const params = &env.params;

    // 乐器 → 通道 1（子通道）；通道 0（主）无直连乐器
    var sp0 = synth.SynthParams{};
    params.channel_count.store(2, .monotonic);
    params.volume.store(1.0, .monotonic);
    params.synth_ptrs[0].store(&sp0, .monotonic);
    params.instrument_channel[0].store(1, .monotonic);
    params.instrument_gain[0].store(1.0, .monotonic);
    params.channel_gain[0].store(1.0, .monotonic);
    params.channel_gain[1].store(1.0, .monotonic);

    synth.noteOn(&engine.synths[0], 69, synth.default_velocity, synth.default_pan);
    var out: [1024 * 2]f32 = undefined;
    const run = struct {
        fn run(e: *Engine, p: *Params, o: [*]f32) f64 {
            var total: f64 = 0;
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                @memset(o[0 .. 1024 * 2], 0);
                renderSegment(e, p, o, 1024, 48000, 1.0);
                for (o[0 .. 1024 * 2]) |s| total += @as(f64, s) * s;
            }
            return total;
        }
    }.run;

    const e_ok = run(engine, params, &out);
    try std.testing.expect(e_ok > 1.0); // 子通道发声 → 主通道出口有声

    // ① 主推子归零 → **全部** 静音（即使子通道推子在 1.0）——证明必经主通道
    params.channel_gain[0].store(0.0, .monotonic);
    try std.testing.expectEqual(@as(f64, 0), run(engine, params, &out));
    params.channel_gain[0].store(1.0, .monotonic);

    // ② 主通道静音同理
    params.channel_muted[0].store(true, .monotonic);
    try std.testing.expectEqual(@as(f64, 0), run(engine, params, &out));
    params.channel_muted[0].store(false, .monotonic);

    // ③ 主推子减半 → 能量 ∝ 0.25
    params.channel_gain[0].store(0.5, .monotonic);
    const e_half = run(engine, params, &out);
    params.channel_gain[0].store(1.0, .monotonic);
    try std.testing.expect(@abs(e_half / e_ok - 0.25) < 0.05);
}

test "audio: 主通道效果链作用在汇总信号上（混响/延迟加入尾音）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, true);
    defer env.deinit(alloc);
    const engine = &env.engine;
    const params = &env.params;
    // 每槽延迟状态盒（生产由 UI 线程发布；测试手动给）
    const box = try alloc.create(FxBox);
    box.* = .{ .kind = 3, .payload = .{ .delay = .{} } };
    defer alloc.destroy(box);
    params.fx_ptrs[0][0].store(box, .monotonic);

    // 子通道 1 发声；主通道挂一个 delay（干湿各半、反馈 0.5）
    // 注：mix 不能用 1.0——纯湿时直声期（<0.25s）回波未到，直声期输出恒零
    var sp0 = synth.SynthParams{};
    params.channel_count.store(2, .monotonic);
    params.volume.store(1.0, .monotonic);
    params.synth_ptrs[0].store(&sp0, .monotonic);
    params.instrument_channel[0].store(1, .monotonic);
    params.instrument_gain[0].store(1.0, .monotonic);
    params.channel_gain[0].store(1.0, .monotonic);
    params.channel_gain[1].store(1.0, .monotonic);
    params.effect_count[0].store(1, .monotonic);
    params.effect_kind[0][0].store(3, .monotonic); // 3 = delay
    params.effect_enabled[0][0].store(true, .monotonic);
    params.effect_mix[0][0].store(0.5, .monotonic);
    params.effect_p[0][0][0].store(@floatFromInt(fx.delay_tempo_default), .monotonic); // 档位 1/8（BPM 120 → 0.25s）
    params.effect_p[0][0][1].store(0.5, .monotonic); // 反馈

    // 开声 0.2s 后立即关声（note off + 快速释放）——看主通道的 delay 尾巴
    synth.noteOn(&engine.synths[0], 69, synth.default_velocity, synth.default_pan);
    var out: [1024 * 2]f32 = undefined;
    var k: usize = 0;
    var during: f64 = 0;
    while (k < 9) : (k += 1) {
        @memset(&out, 0);
        renderSegment(engine, params, &out, 1024, 48000, 1.0);
        for (out) |s| during += @as(f64, s) * s;
    }
    try std.testing.expect(during > 1.0); // 直声期有声
    synth.allOff(&engine.synths[0]);
    synth.render(&sp0, &engine.synths[0], &out, 1024, 48000, 1.0, false); // 推进 release

    // 干声停后：主通道 delay 的尾巴仍输出（能量不归零）
    var tail: f64 = 0;
    k = 0;
    while (k < 8) : (k += 1) {
        @memset(&out, 0);
        renderSegment(engine, params, &out, 1024, 48000, 1.0);
        for (out) |s| tail += @as(f64, s) * s;
    }
    try std.testing.expect(tail > 1.0); // 尾音（子通道声音绕进主通道 delay）
}

test "audio: 有效声像合成——乐器基准 + 音符偏移（导入音符居中跟随乐器）" {
    // 居中音符（64）完全跟随乐器基准
    try std.testing.expectEqual(@as(u8, 64), effectivePan(0.5, 64));
    try std.testing.expectEqual(@as(u8, 0), effectivePan(0.0, 64));
    try std.testing.expectEqual(@as(u8, 127), effectivePan(1.0, 64));
    // 音符偏移在基准上平移（含越界钳制）
    try std.testing.expectEqual(@as(u8, 32), effectivePan(0.5, 32));
    try std.testing.expectEqual(@as(u8, 95), effectivePan(0.25, 127));
    try std.testing.expectEqual(@as(u8, 0), effectivePan(0.5, 0));
    try std.testing.expectEqual(@as(u8, 127), effectivePan(1.0, 127));
    try std.testing.expectEqual(@as(u8, 127), effectivePan(0.75, 127));
}

test "audio: VSTi 声像平衡——等功率（0.5 原样、两端满偏单侧、功率恒定）" {
    const c = balanceGains(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c[1], 1e-6);
    const l = balanceGains(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4142135), l[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), l[1], 1e-6);
    const r = balanceGains(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4142135), r[1], 1e-6);
    // 等功率：gl² + gr² ≡ 2（任意位置）
    var p: f32 = 0;
    while (p <= 1.0) : (p += 0.1) {
        const bg = balanceGains(p);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), bg[0] * bg[0] + bg[1] * bg[1], 1e-5);
    }
}

test "audio: VSTi 声像——插件输出按平衡叠加（全左/全右/居中能量分配）" {
    const alloc = std.testing.allocator;
    const dll_z = alloc.dupeZ(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll") catch return;
    defer alloc.free(dll_z);

    const measure = struct {
        fn run(alloc_: std.mem.Allocator, dll_z_: [:0]const u8, pan: f32) !struct { l: f64, r: f64 } {
            var env: KitTestEnv = undefined;
            try env.init(alloc_, true);
            defer env.deinit(alloc_);
            const engine = &env.engine;
            const params = &env.params;
            engine.vsti_scratch = try alloc_.alloc(f32, 2 * 4096);

            const pl = vst_host.loadPlugin(alloc_, dll_z_, 48000, 4096, .instrument) catch return error.SkipZigTest;
            defer vst_host.unloadPlugin(alloc_, pl);
            pl.setParamHost(0, 0.8); // 电平拉高
            params.instrument_kind[0].store(2, .monotonic);
            params.instrument_plugin[0].store(pl, .monotonic);
            params.instrument_channel[0].store(0, .monotonic);
            params.instrument_gain[0].store(1.0, .monotonic);
            params.instrument_pan[0].store(pan, .monotonic);
            params.channel_count.store(1, .monotonic);
            params.volume.store(1.0, .monotonic);

            dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 60, .instrument = 0, .velocity = 100 });
            var out: [512 * 2]f32 = undefined;
            var sl: f64 = 0;
            var sr: f64 = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                @memset(&out, 0);
                renderSegment(engine, params, &out, 512, 48000, 1.0);
                var k: usize = 0;
                while (k < out.len) : (k += 2) {
                    sl += @as(f64, out[k]) * out[k];
                    sr += @as(f64, out[k + 1]) * out[k + 1];
                }
            }
            params.instrument_plugin[0].store(null, .monotonic);
            return .{ .l = sl, .r = sr };
        }
    }.run;

    const left = try measure(alloc, dll_z, 0.0);
    const right = try measure(alloc, dll_z, 1.0);
    const mid = try measure(alloc, dll_z, 0.5);
    try std.testing.expect(left.l > 1.0);
    try std.testing.expect(left.r < 1e-6); // 全左：右侧寂音
    try std.testing.expect(right.r > 1.0);
    try std.testing.expect(right.l < 1e-6); // 全右：左侧寂音
    try std.testing.expectApproxEqRel(mid.l, mid.r, 1e-3); // 居中：两侧相等
    // 单侧能量：全左 ≈ 居中 ×2（等功率：×√2 增益 → 能量 ×2）
    try std.testing.expectApproxEqRel(left.l, mid.l * 2.0, 0.05);
}

test "audio: publishSounding——VSTi 直接发布 note-on 活跃位图" {
    var env: KitTestEnv = undefined;
    try env.init(std.testing.allocator, false);
    defer env.deinit(std.testing.allocator);
    const engine = &env.engine;
    const params = &env.params;
    params.instrument_kind[0].store(2, .monotonic);
    engine.vsti_active_lo[0] = @as(u64, 1) << 60;
    engine.vsti_active_hi[0] = @as(u64, 1) << 5; // 音高 69
    publishSounding(engine, params);
    try std.testing.expectEqual(@as(u64, 1) << 60, params.sounding_lo[0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1) << 5, params.sounding_hi[0].load(.monotonic));
    // 清位（all-off）后再发布 → 高亮归零
    engine.vsti_active_lo[0] = 0;
    engine.vsti_active_hi[0] = 0;
    publishSounding(engine, params);
    try std.testing.expectEqual(@as(u64, 0), params.sounding_lo[0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), params.sounding_hi[0].load(.monotonic));
}

