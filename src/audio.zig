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
// 0.17：`@cImport` 已移除——改用 `zig translate-c` 预生成的绑定（免网络、免构建期翻译）
// miniaudio 绑定：**按平台选择**。结构体布局随编译期启用的后端变化
// （Linux 的 ma_device/ma_context 内嵌 pulse/alsa/jack 状态 → sizeof 比 Windows 大 464 字节），
// 所以用同一份绑定会在跨平台时**越界写**。两份都由 `zig translate-c` 生成并入库。
const builtin = @import("builtin");
const ma = if (builtin.os.tag == .windows) @import("c/miniaudio_win.zig") else @import("c/miniaudio_linux.zig");
const audio_pref = @import("audio_pref.zig");

/// 每乐器每个分段发送给 VSTi 的事件上限（超出的丢弃；宁可丢事件也不分配）
pub const vsti_batch_max = 256;

/// 调音台通道数**初始容量**（与 app.max_mixer_channels 对齐；音频层不能 import app——循环依赖）。
/// 池化后实际容量在运行时增长（见 `Params.channels_cap`）；当前通道数以 `Params.channel_count` 为准。
pub const mixer_channels = 32;
/// 每通道效果器槽数**初始容量**（与 app.max_effects_per_channel 对齐；起点 32；运行时增长见 `Params.slots_cap`）
pub const effect_slots = 32;
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
    /// **软切换**（保位模式切换）：下一次 `sched_gen` 变化时**不释放声部**
    /// （单次消费——音频 `handleGenChange` 用 swap 清位）。其余路径（跳转/
    /// 起播）在 gen 递增前写 false。发布顺序：本标志 → gen → 事件入队。
    sched_gen_soft: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
    /// 注：以下全部数组为**运行时容量**（长度 = `instruments_cap` 等，见 `initCapacity`）
    synth_ptrs: []std.atomic.Value(?*synth.SynthParams) = &.{},
    /// 每乐器增益（音量 × 静音；UI 每帧同步）
    instrument_gain: []std.atomic.Value(f32) = &.{},
    /// 每乐器声像（0-1；0.5 居中；UI 每帧同步）——音符级声像的**基准**：
    /// 播放时合成有效声像（基准 + 音符偏移），见 `effectivePan`
    /// 每乐器声像（0-1；0.5 居中；UI 每帧同步）——音符级声像的**基准**：
    /// 播放时合成有效声像（基准 + 音符偏移），见 `effectivePan`
    instrument_pan: []std.atomic.Value(f32) = &.{},
    /// VSTi **panic 旗标**（UI 线程置位）：下一段对全 128 音高无条件 note-off。
    /// 用途：state 恢复（撤销/读档/载预设）可能**唤醒快照里仍在发声的声部**——
    /// 它们不在宿主活跃位图里，按位图补 off 会漏 → 永挂（实测 bug：播放中调
    /// Vital 参数后撤销，部分音符响个不停，暂停/停止无效）。
    instrument_panic: []std.atomic.Value(bool) = &.{},
    /// 每槽 VST3 插件实例指针（混音通道 × 效果槽；null = 未加载/直通）——
    /// UI 侧惰性加载并发布；删除走“退役列表”延迟销毁（见 App.retirePlugin）
    plugin_ptrs: [][]std.atomic.Value(?*vst_host.Plugin) = &.{},
    /// 每槽效果器 DSP 状态盒（混响/延迟/压缩器；UI 线程分配/发布/退役——与
    /// `plugin_ptrs` 同一模式）。null = 无状态（直通/未发布）。
    /// 历史：原为每通道一份（“同类至多一个”时代）；用户要叠加相同效果 → 每槽独立。
    fx_ptrs: [][]std.atomic.Value(?*FxBox) = &.{},
    /// 每乐器路由到的调音台通道（0..channels_cap-1；UI 每帧同步）
    instrument_channel: []std.atomic.Value(u32) = &.{},
    /// 每乐器的 VST3 插件实例（kind == 2/VSTi；null = 未加载）——UI 侧惰性加载/发布
    instrument_plugin: []std.atomic.Value(?*vst_host.Plugin) = &.{},

    // ── 鼓组（每乐器：类型 + 层列表；UI 每帧同步）──
    /// 乐器类型（0 = synth / 1 = drumkit / 2 = VST3 插件）
    instrument_kind: []std.atomic.Value(u32) = &.{},
    /// 鼓组层数（≤ kit_max_layers）
    kit_layer_count: []std.atomic.Value(u32) = &.{},
    /// 鼓组层 → 音高（on 事件按音高分发到匹配层）。
    /// 注：off **不查它**——直接对全部层 noteOff（防“响着改映射”漏 off 悬挂）。
    kit_layer_pitch: [][]std.atomic.Value(u32) = &.{},
    /// 鼓组层增益（多层叠加的配比）
    kit_layer_gain: [][]std.atomic.Value(f32) = &.{},
    /// 鼓组层合成器参数指针（层本体；UI 持有并保证地址稳定）
    kit_layer_params: [][]std.atomic.Value(?*synth.SynthParams) = &.{},
    /// 鼓组层类型（`model.LayerKind`：0 = 减法 / 2 = VST3）
    kit_layer_kind: [][]std.atomic.Value(u32) = &.{},
    /// 鼓组层 VST3 插件实例指针（kind == 2 时有效；UI 发布，音频线程 acquire 读）
    kit_layer_plugin: [][]std.atomic.Value(?*vst_host.Plugin) = &.{},
    /// 鼓组层 VST3 防挂音 panic（状态恢复后置位：下一段对该层全 128 补 off）
    kit_layer_panic: [][]std.atomic.Value(bool) = &.{},
    /// 鼓组采样器层的采样数据（kind == 3；UI 发布不可变 SampleData 指针）
    kit_layer_asset: [][]std.atomic.Value(?*const SampleData) = &.{},
    /// 鼓组采样器层：采样内起点（帧，>= 0）
    kit_layer_trim_start: [][]std.atomic.Value(i32) = &.{},
    /// 鼓组采样器层：采样内长度（帧；<= 0 = 到素材末尾）
    kit_layer_trim_len: [][]std.atomic.Value(i32) = &.{},
    /// 鼓组采样器层：播放速度（每帧前进的采样帧数；v1 = 音高同步变速）
    kit_layer_speed: [][]std.atomic.Value(f32) = &.{},

    // ── 音频片段/试听（见 `AudioTable` / `renderSegment`）──
    /// 音频片段播放表（不可变快照；UI 重建/发布，帧末轮换退役）
    audio_table: std.atomic.Value(?*const AudioTable) = std.atomic.Value(?*const AudioTable).init(null),
    /// 波形窗口试听（全局单实例）：采样 + 区间 + 增益 + 通道
    preview_asset: std.atomic.Value(?*const SampleData) = std.atomic.Value(?*const SampleData).init(null),
    preview_start: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    preview_len: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    preview_gain: std.atomic.Value(f32) = std.atomic.Value(f32).init(1.0),
    /// 试听速度（变速变调；波形窗按样式速度试听）
    preview_speed: std.atomic.Value(f32) = std.atomic.Value(f32).init(1.0),
    /// 试听速度（变速变调；波形窗按样式速度试听）
    preview_channel: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    preview_playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 试听游标回写（帧；-1 = 未播放）——UI 读它画游标
    preview_pos: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// 试听循环（采样器层：在 trim 区间内循环，像钢琴窗的循环选区）
    preview_loop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 主输出峰值（|x| 最大值；UI 读来做电平表——以后波形超载标红也用它）
    out_peak: std.atomic.Value(f32) = std.atomic.Value(f32).init(0),
    /// 自上次 UI 读取以来 |x| > 1.0 的采样数（swap 清零：削波计数）
    out_over: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ── 调音台：每通道参数（UI 写、音频线程读）──
    /// 通道增益（0-1）
    channel_gain: []std.atomic.Value(f32) = &.{},
    /// 通道声像（0-1；0.5 = 居中）
    channel_pan: []std.atomic.Value(f32) = &.{},
    /// 通道静音（增益已在 UI 侧合并——但保留独立标志以便 UI 同步）
    channel_muted: []std.atomic.Value(bool) = &.{},
    /// 通道 EQ 段参数（**效果器链的第 0 槽 = EQ**；频率/增益/Q——
    /// UI 每帧同步；音频线程据其重建 biquad）。
    /// 槽位元数据（kind/enabled/mix）在 `effect_chain`。
    channel_eq: [][]eq.BandParams = &.{},
    /// 通道 EQ 版本号（参数变化时递增；音频线程对比后重建系数）
    channel_eq_version: []std.atomic.Value(u32) = &.{},
    /// 效果器链元数据（槽 × 通道）：kind（0 = 空、1 = EQ）、enabled、mix
    effect_kind: [][]std.atomic.Value(u32) = &.{},
    effect_enabled: [][]std.atomic.Value(bool) = &.{},
    effect_mix: [][]std.atomic.Value(f32) = &.{},
    /// 效果链版本（kind/enabled/mix 变化时递增）
    effect_chain_version: []std.atomic.Value(u32) = &.{},
    /// 效果链长度（每通道：有效效果器数；UI 每帧同步）
    effect_count: []std.atomic.Value(u32) = &.{},
    /// 效果器参数位（每槽 `fx.max_params` 个；含义按 kind 见 `effects.paramInfos`——
    /// 2 = 混响 / 3 = 延迟 / 4 = 压缩器；1 = EQ 用 `channel_eq`）。
    /// **扁平**：索引 =(ch * slots_cap + slot) * fx.max_params + pi（用 `fxParam`）
    effect_p: []std.atomic.Value(f32) = &.{},
    /// 实际通道数（UI 每帧同步；音频线程只处理 0..channel_count）
    channel_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    // ── 音频线程回传：调音台频谱（用于 EQ 窗口背景）──
    /// 频谱柱（0-1）——**目标效果器的输入信号**（非主输出全混）
    spec_bars: [eq.spec_bars]std.atomic.Value(f32) = @splat(std.atomic.Value(f32).init(0)),
    /// 频谱版本（音频线程每分析一次递增；UI 据此拷贝）
    spec_version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 频谱分析目标：效果器所在通道（UI 每帧发布；-1 = 不分析）
    spec_target_ch: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// 频谱分析目标：效果器在链上的槽位（-1 = 不分析）
    spec_target_slot: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    // ── 音频线程回传：正在发声的音高（位掩码，UI 用于播放/试听高亮）──
    /// 音高 0-63（位 = 音高）
    sounding_lo: []std.atomic.Value(u64) = &.{},
    /// 音高 64-127（位 = 音高 − 64）
    sounding_hi: []std.atomic.Value(u64) = &.{},

    // ── 运行时容量（initCapacity 设定；grow 只增不减）──
    /// 乐器槽容量（乐器数组长度）
    instruments_cap: usize = 0,
    /// 通道容量
    channels_cap: usize = 0,
    /// 每通道效果槽容量
    slots_cap: usize = 0,

    /// 效果器参数原子位指针（扁平索引：(ch * slots_cap + slot) * fx.max_params + pi）
    pub fn fxParam(self: *Params, ch: usize, slot: usize, pi: usize) *std.atomic.Value(f32) {
        return &self.effect_p[(ch * self.slots_cap + slot) * fx.max_params + pi];
    }

    /// 初始化容量（启动/测试一次性建立全部数组；失败即返回错误，已分配部分已回滚）
    pub fn initCapacity(self: *Params, a: std.mem.Allocator, ic: usize, cc: usize, sc: usize) !void {
        self.instruments_cap = ic;
        self.channels_cap = cc;
        self.slots_cap = sc;
        errdefer self.deinit(a);
        self.synth_ptrs = try allocAtomicArr(?*synth.SynthParams, a, ic, null);
        self.instrument_gain = try allocAtomicArr(f32, a, ic, 0.8);
        self.instrument_pan = try allocAtomicArr(f32, a, ic, 0.5);
        self.instrument_panic = try allocAtomicArr(bool, a, ic, false);
        self.instrument_channel = try allocAtomicArr(u32, a, ic, 0);
        self.instrument_plugin = try allocAtomicArr(?*vst_host.Plugin, a, ic, null);
        self.instrument_kind = try allocAtomicArr(u32, a, ic, 0);
        self.kit_layer_count = try allocAtomicArr(u32, a, ic, 0);
        self.kit_layer_pitch = try allocAtomicRows(u32, a, ic, kit_max_layers, 0);
        self.kit_layer_gain = try allocAtomicRows(f32, a, ic, kit_max_layers, 1.0);
        self.kit_layer_params = try allocAtomicRows(?*synth.SynthParams, a, ic, kit_max_layers, null);
        self.kit_layer_kind = try allocAtomicRows(u32, a, ic, kit_max_layers, 0);
        self.kit_layer_plugin = try allocAtomicRows(?*vst_host.Plugin, a, ic, kit_max_layers, null);
        self.kit_layer_panic = try allocAtomicRows(bool, a, ic, kit_max_layers, false);
        self.kit_layer_asset = try allocAtomicRows(?*const SampleData, a, ic, kit_max_layers, null);
        self.kit_layer_trim_start = try allocAtomicRows(i32, a, ic, kit_max_layers, 0);
        self.kit_layer_trim_len = try allocAtomicRows(i32, a, ic, kit_max_layers, 0);
        self.kit_layer_speed = try allocAtomicRows(f32, a, ic, kit_max_layers, 1.0);
        self.sounding_lo = try allocAtomicArr(u64, a, ic, 0);
        self.sounding_hi = try allocAtomicArr(u64, a, ic, 0);
        self.channel_gain = try allocAtomicArr(f32, a, cc, 0.8);
        self.channel_pan = try allocAtomicArr(f32, a, cc, 0.5);
        self.channel_muted = try allocAtomicArr(bool, a, cc, false);
        self.channel_eq_version = try allocAtomicArr(u32, a, cc, 0);
        self.plugin_ptrs = try allocAtomicRows(?*vst_host.Plugin, a, cc, sc, null);
        self.fx_ptrs = try allocAtomicRows(?*FxBox, a, cc, sc, null);
        self.effect_kind = try allocAtomicRows(u32, a, cc, sc, 0);
        self.effect_enabled = try allocAtomicRows(bool, a, cc, sc, true);
        self.effect_mix = try allocAtomicRows(f32, a, cc, sc, 1.0);
        self.effect_chain_version = try allocAtomicArr(u32, a, cc, 0);
        self.effect_count = try allocAtomicArr(u32, a, cc, 0);
        self.effect_p = try allocAtomicArr(f32, a, cc * sc * fx.max_params, 0);
        self.channel_eq = try a.alloc([]eq.BandParams, cc);
        @memset(self.channel_eq, &.{});
        for (self.channel_eq) |*row| {
            row.* = try a.alloc(eq.BandParams, eq_bands);
            @memset(row.*, .{});
            setDefaultEqBands(row.*);
        }
    }

    /// 释放全部容量数组（可重复调用；与 initCapacity/grow 对偶）
    pub fn deinit(self: *Params, a: std.mem.Allocator) void {
        freeAtomicArr(?*synth.SynthParams, a, &self.synth_ptrs);
        freeAtomicArr(f32, a, &self.instrument_gain);
        freeAtomicArr(f32, a, &self.instrument_pan);
        freeAtomicArr(bool, a, &self.instrument_panic);
        freeAtomicArr(u32, a, &self.instrument_channel);
        freeAtomicArr(?*vst_host.Plugin, a, &self.instrument_plugin);
        freeAtomicArr(u32, a, &self.instrument_kind);
        freeAtomicArr(u32, a, &self.kit_layer_count);
        freeAtomicRows(u32, a, &self.kit_layer_pitch);
        freeAtomicRows(f32, a, &self.kit_layer_gain);
        freeAtomicRows(?*synth.SynthParams, a, &self.kit_layer_params);
        freeAtomicRows(u32, a, &self.kit_layer_kind);
        freeAtomicRows(?*vst_host.Plugin, a, &self.kit_layer_plugin);
        freeAtomicRows(bool, a, &self.kit_layer_panic);
        freeAtomicRows(?*const SampleData, a, &self.kit_layer_asset);
        freeAtomicRows(i32, a, &self.kit_layer_trim_start);
        freeAtomicRows(i32, a, &self.kit_layer_trim_len);
        freeAtomicRows(f32, a, &self.kit_layer_speed);
        freeAtomicArr(u64, a, &self.sounding_lo);
        freeAtomicArr(u64, a, &self.sounding_hi);
        freeAtomicArr(f32, a, &self.channel_gain);
        freeAtomicArr(f32, a, &self.channel_pan);
        freeAtomicArr(bool, a, &self.channel_muted);
        freeAtomicArr(u32, a, &self.channel_eq_version);
        for (self.channel_eq) |r| if (r.len > 0) a.free(r);
        if (self.channel_eq.len > 0) a.free(self.channel_eq);
        self.channel_eq = &.{};
        freeAtomicRows(?*vst_host.Plugin, a, &self.plugin_ptrs);
        freeAtomicRows(?*FxBox, a, &self.fx_ptrs);
        freeAtomicRows(u32, a, &self.effect_kind);
        freeAtomicRows(bool, a, &self.effect_enabled);
        freeAtomicRows(f32, a, &self.effect_mix);
        freeAtomicArr(u32, a, &self.effect_chain_version);
        freeAtomicArr(u32, a, &self.effect_count);
        freeAtomicArr(f32, a, &self.effect_p);
        self.instruments_cap = 0;
        self.channels_cap = 0;
        self.slots_cap = 0;
    }

    /// 扩容/缩容（**契约：调用方保证音频设备已暂停**——音频线程停走期间普通拷贝即安全）。
    /// 容量只受滞回策略控制；返回后各数组长度 == 目标值，前缀值保留。
    pub fn resize(self: *Params, a: std.mem.Allocator, ic: usize, cc: usize, sc: usize) !void {
        if (ic != self.instruments_cap) {
            try growAtomicArr(?*synth.SynthParams, a, &self.synth_ptrs, ic, null);
            try growAtomicArr(f32, a, &self.instrument_gain, ic, 0.8);
            try growAtomicArr(f32, a, &self.instrument_pan, ic, 0.5);
            try growAtomicArr(bool, a, &self.instrument_panic, ic, false);
            try growAtomicArr(u32, a, &self.instrument_channel, ic, 0);
            try growAtomicArr(?*vst_host.Plugin, a, &self.instrument_plugin, ic, null);
            try growAtomicArr(u32, a, &self.instrument_kind, ic, 0);
            try growAtomicArr(u32, a, &self.kit_layer_count, ic, 0);
            try growAtomicRows(u32, a, &self.kit_layer_pitch, ic, kit_max_layers, 0);
            try growAtomicRows(f32, a, &self.kit_layer_gain, ic, kit_max_layers, 1.0);
            try growAtomicRows(?*synth.SynthParams, a, &self.kit_layer_params, ic, kit_max_layers, null);
            try growAtomicRows(u32, a, &self.kit_layer_kind, ic, kit_max_layers, 0);
            try growAtomicRows(?*vst_host.Plugin, a, &self.kit_layer_plugin, ic, kit_max_layers, null);
            try growAtomicRows(bool, a, &self.kit_layer_panic, ic, kit_max_layers, false);
            try growAtomicRows(?*const SampleData, a, &self.kit_layer_asset, ic, kit_max_layers, null);
            try growAtomicRows(i32, a, &self.kit_layer_trim_start, ic, kit_max_layers, 0);
            try growAtomicRows(i32, a, &self.kit_layer_trim_len, ic, kit_max_layers, 0);
            try growAtomicRows(f32, a, &self.kit_layer_speed, ic, kit_max_layers, 1.0);
            try growAtomicArr(u64, a, &self.sounding_lo, ic, 0);
            try growAtomicArr(u64, a, &self.sounding_hi, ic, 0);
            self.instruments_cap = ic;
        }
        if (cc != self.channels_cap) {
            try growAtomicArr(f32, a, &self.channel_gain, cc, 0.8);
            try growAtomicArr(f32, a, &self.channel_pan, cc, 0.5);
            try growAtomicArr(bool, a, &self.channel_muted, cc, false);
            const nq = try a.alloc([]eq.BandParams, cc);
            @memset(nq, &.{});
            errdefer {
                for (nq) |r| if (r.len > 0) a.free(r);
                a.free(nq);
            }
            for (nq, 0..) |*r, i| {
                r.* = try a.alloc(eq.BandParams, eq_bands);
                @memset(r.*, .{});
                if (i < self.channel_eq.len) {
                    for (r.*[0..@min(eq_bands, self.channel_eq[i].len)], 0..) |*b, k| b.* = self.channel_eq[i][k];
                } else {
                    setDefaultEqBands(r.*);
                }
            }
            for (self.channel_eq) |r| if (r.len > 0) a.free(r);
            if (self.channel_eq.len > 0) a.free(self.channel_eq);
            self.channel_eq = nq;
            try growAtomicArr(u32, a, &self.channel_eq_version, cc, 0);
            // 每通道的效果槽家族（行 = 通道；列 = 当前槽容量）
            try growAtomicRows(?*vst_host.Plugin, a, &self.plugin_ptrs, cc, self.slots_cap, null);
            try growAtomicRows(?*FxBox, a, &self.fx_ptrs, cc, self.slots_cap, null);
            try growAtomicRows(u32, a, &self.effect_kind, cc, self.slots_cap, 0);
            try growAtomicRows(bool, a, &self.effect_enabled, cc, self.slots_cap, true);
            try growAtomicRows(f32, a, &self.effect_mix, cc, self.slots_cap, 1.0);
            try growAtomicArr(u32, a, &self.effect_chain_version, cc, 0);
            try growAtomicArr(u32, a, &self.effect_count, cc, 0);
            {
                // effect_p 扁平：前 old_n 项布局不变（前缀拷贝）
                const sc_cur = self.slots_cap;
                const np2 = try allocAtomicArr(f32, a, cc * sc_cur * fx.max_params, 0);
                const cp2 = @min(np2.len, self.effect_p.len);
                for (np2[0..cp2], 0..) |*v, i| v.* = std.atomic.Value(f32).init(self.effect_p[i].load(.monotonic));
                freeAtomicArr(f32, a, &self.effect_p);
                self.effect_p = np2;
            }
            self.channels_cap = cc;
        }
        if (sc != self.slots_cap) {
            try growAtomicRows(?*vst_host.Plugin, a, &self.plugin_ptrs, self.channels_cap, sc, null);
            try growAtomicRows(?*FxBox, a, &self.fx_ptrs, self.channels_cap, sc, null);
            try growAtomicRows(u32, a, &self.effect_kind, self.channels_cap, sc, 0);
            try growAtomicRows(bool, a, &self.effect_enabled, self.channels_cap, sc, true);
            try growAtomicRows(f32, a, &self.effect_mix, self.channels_cap, sc, 1.0);
            const old_slots = self.slots_cap;
            const np = try allocAtomicArr(f32, a, self.channels_cap * sc * fx.max_params, 0);
            for (0..self.channels_cap) |ch| {
                for (0..@min(old_slots, sc)) |slot| {
                    for (0..fx.max_params) |pi| {
                        const oi = (ch * old_slots + slot) * fx.max_params + pi;
                        const ni = (ch * sc + slot) * fx.max_params + pi;
                        np[ni] = std.atomic.Value(f32).init(self.effect_p[oi].load(.monotonic));
                    }
                }
            }
            freeAtomicArr(f32, a, &self.effect_p);
            self.effect_p = np;
            self.slots_cap = sc;
        }
    }
};

/// 容量数组分配/释放助手（Params 与 Engine 共用）
fn allocAtomicArr(comptime T: type, a: std.mem.Allocator, n: usize, val: T) ![]std.atomic.Value(T) {
    const s = try a.alloc(std.atomic.Value(T), n);
    for (s) |*v| v.* = std.atomic.Value(T).init(val);
    return s;
}

fn allocAtomicRows(comptime T: type, a: std.mem.Allocator, rows: usize, cols: usize, val: T) ![][]std.atomic.Value(T) {
    const outer = try a.alloc([]std.atomic.Value(T), rows);
    @memset(outer, &.{});
    errdefer {
        for (outer) |r| if (r.len > 0) a.free(r);
        a.free(outer);
    }
    for (outer) |*r| r.* = try allocAtomicArr(T, a, cols, val);
    return outer;
}

fn freeAtomicArr(comptime T: type, a: std.mem.Allocator, s: *[]std.atomic.Value(T)) void {
    if (s.len > 0) a.free(s.*);
    s.* = &.{};
}

fn freeAtomicRows(comptime T: type, a: std.mem.Allocator, s: *[][]std.atomic.Value(T)) void {
    for (s.*) |r| if (r.len > 0) a.free(r);
    if (s.len > 0) a.free(s.*);
    s.* = &.{};
}

/// 扩容/缩容（名称沿史，语义 = resize）：n < len 时前缀保留、尾部丢弃
fn growAtomicArr(comptime T: type, a: std.mem.Allocator, old: *[]std.atomic.Value(T), n: usize, val: T) !void {
    if (n == old.len) return;
    const s = try allocAtomicArr(T, a, n, val);
    for (s[0..@min(n, old.len)], 0..) |*v, i| v.* = std.atomic.Value(T).init(old.*[i].load(.monotonic));
    if (old.len > 0) a.free(old.*);
    old.* = s;
}

/// 扩容/缩容（名称沿史，语义 = resize）：行数/列数变小=剪枝，变大=补齐
fn growAtomicRows(comptime T: type, a: std.mem.Allocator, old: *[][]std.atomic.Value(T), rows: usize, cols: usize, val: T) !void {
    if (rows == old.len and (rows == 0 or old.*[0].len == cols)) return;
    const outer = try a.alloc([]std.atomic.Value(T), rows);
    @memset(outer, &.{});
    errdefer {
        for (outer) |r| if (r.len > 0) a.free(r);
        a.free(outer);
    }
    for (outer, 0..) |*r, i| {
        r.* = try allocAtomicArr(T, a, cols, val);
        if (i < old.len) {
            for (r.*[0..@min(cols, old.*[i].len)], 0..) |*v, k| v.* = std.atomic.Value(T).init(old.*[i][k].load(.monotonic));
        }
    }
    for (old.*) |r| if (r.len > 0) a.free(r);
    if (old.len > 0) a.free(old.*);
    old.* = outer;
}

/// 调音台 EQ 五段默认值（initCapacity/grow 共用）
fn setDefaultEqBands(r: []eq.BandParams) void {
    const d = [_]eq.BandParams{
        .{ .freq = 100, .q = 1.0 },
        .{ .freq = 500, .q = 1.0 },
        .{ .freq = 2000, .q = 1.0 },
        .{ .freq = 8000, .q = 1.0 },
        .{ .freq = 12000, .q = 1.0 },
    };
    for (r, 0..) |*b, i| b.* = if (i < d.len) d[i] else .{};
}

pub const Engine = struct {
    device: ma.ma_device = undefined,
    /// 显式选后端时用（`.auto` 走 `ma_device_init(null, …)`，不用它）
    ctx: ma.ma_context = undefined,
    ctx_ok: bool = false,
    params: *Params,
    allocator: std.mem.Allocator = undefined,
    sample_rate: u32 = 0,
    initialized: bool = false,
    /// 每乐器一个声部池（**仅音频线程访问**；堆分配——32 池 × 256 声部体积可观）
    synths: []synth.Synth = &.{},
    /// 鼓组层声部池（**惰性**：每乐器的 16 层池按需分配，见 `App.ensureKitPool`——
    /// 指针数组按容量维护；普通（非鼓组）乐器零开销，扩容拷贝量不再含声部状态）。
    kit_chunks: []std.atomic.Value(?*KitPool) = &.{},
    /// 鼓组 VST3 层状态（每层事件批 + 发声位图；**惰性**——仅含 VST3 层的
    /// 鼓组分配；生命周期同鼓组池：设备暂停窗口内创建/释放，见 `App.ensureKitVsti`）
    kit_vsti: []std.atomic.Value(?*KitVstiState) = &.{},
    /// 鼓组采样器层状态（每层声部池；**惰性**，同 kit_vsti）
    kit_sampler: []std.atomic.Value(?*KitSamplerState) = &.{},
    /// VSTi 渲染中转缓冲（插件的原位写出不能直接覆盖通道缓冲——需叠加）
    vsti_scratch: []f32 = &.{},
    /// VSTi 待发送事件批（事件在**段边界以 offset 0 生效**：dispatchNote 填充，
    /// renderSegment 消费后清零——与内部合成器的样本级触发共用同一分段机制）
    vsti_events: [][]ivstevents.Event = &.{},
    vsti_event_n: []usize = &.{},
    /// VSTi 正在发声的音高（位图；all-off 时按位补发 note-off）
    vsti_active_lo: []u64 = &.{},
    vsti_active_hi: []u64 = &.{},
    /// 每乐器上一帧的类型（类型切换边沿 → 两个池都全释音，防悬挂）
    last_kind: []u32 = &.{},

    // ── 运行时容量（与 `Params` 同步；见 `setCapacity`）──
    instruments_cap: usize = 0,
    channels_cap: usize = 0,
    slots_cap: usize = 0,
    /// 已取但未到时的调度事件（stash；按步序保留，到时再触发）
    stash: [synth.sched_drain_max]synth.SchedEvent = undefined,
    stash_n: usize = 0,
    /// 当前渲染**段**起点的绝对播放帧（dataCallback 每段设置；ProcessContext 用）
    seg_abs0: u64 = 0,
    /// 累计派发的调度事件数（单调递增；导出诊断用）
    dbg_dispatched: u64 = 0,
    /// 最近一次 resumeDevice 的 miniaudio 返回码（0 = 成功；排障用）
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
    chan_eq_ver: []u32 = &.{},
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
        // ⚠️ `App.initAudioCapacity()` 可能**已经**建过容量数组（`setCapacity`）。
        // 这里必须先释放旧缓冲：下面若直接赋值会**覆盖指针**——实测泄漏
        // chan_bufs 1 MB + slot_eq 280 KB（Debug 下 SafeAllocator 报的正是它们）。
        self.freeStorage();
        self.params = params;
        self.allocator = allocator;
        // 容量数组：按 Params 当前容量建立（乐器/通道/效果槽）
        // **chan_bufs / slot_eq 都由 setCapacity 分配**（不要在这里再分配一遍）
        try self.setCapacity(params.instruments_cap, params.channels_cap, params.slots_cap);
        // VSTi 中转缓冲（一个渲染块大小）
        if (self.vsti_scratch.len == 0) {
            self.vsti_scratch = try allocator.alloc(f32, 2 * 4096);
            @memset(self.vsti_scratch, 0);
        }
        // 调音台缓冲 / EQ 阵列：**已在 setCapacity 里按 cc/sc 分配（含旧帧状态拷贝）**，
        // 这里不再重复分配（那是历史上泄漏 1 MB + 280 KB 的根源）。

        var config = ma.ma_device_config_init(ma.ma_device_type_playback);
        config.playback.format = ma.ma_format_f32;
        config.playback.channels = 2;
        config.sampleRate = 0; // 0 = 用设备默认
        config.dataCallback = dataCallback;
        config.pUserData = self; // 引擎实例（回调里取 params + synths）

        // 后端：显式选中时建 context（失败自动回退默认）；`.auto` 走 null 让 miniaudio 自己挑
        var ctx_ptr: ?*ma.ma_context = null;
        if (audio_pref.maBackend(audio_pref.current)) |mb| {
            var backends = [_]c_uint{mb};
            if (ma.ma_context_init(&backends, 1, null, &self.ctx) == ma.MA_SUCCESS) {
                self.ctx_ok = true;
                ctx_ptr = &self.ctx;
            } else {
                std.debug.print("[audio] 后端 {s} 不可用 → 回退自动\n", .{audio_pref.label(audio_pref.current)});
            }
        }
        if (ma.ma_device_init(ctx_ptr, &config, &self.device) != ma.MA_SUCCESS) {
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

    /// 暂停/恢复音频设备（离线导出用：期间实时回调完全停走，渲染由导出循环独占）。
    /// 未初始化（单测 / 无声卡）→ 无操作。
    pub fn pauseDevice(self: *Engine) void {
        if (self.initialized) _ = ma.ma_device_stop(&self.device);
    }

    pub fn resumeDevice(self: *Engine) void {
        if (!self.initialized) return;
        if (ma.ma_device_get_state(&self.device) == ma.ma_device_state_started) return;
        _ = ma.ma_device_start(&self.device);
    }

    pub fn deinit(self: *Engine) void {
        if (self.initialized) {
            _ = ma.ma_device_stop(&self.device);
            ma.ma_device_uninit(&self.device);
            self.initialized = false;
        }
        if (self.ctx_ok) {
            _ = ma.ma_context_uninit(&self.ctx);
            self.ctx_ok = false;
        }
        self.freeStorage();
    }

    /// 释放全部堆缓冲/容量数组（**不含设备**）。`deinit` 与 `init` 复用同一 Engine 前
    /// 都调它；全部按 `len > 0` 守卫，所以对全新的 `Engine{}`（allocator=undefined）安全。
    fn freeStorage(self: *Engine) void {
        if (self.synths.len > 0) {
            self.allocator.free(self.synths);
            self.synths = &.{};
        }
        for (self.kit_chunks) |*c| {
            if (c.load(.monotonic)) |kp| self.allocator.destroy(kp);
        }
        if (self.kit_chunks.len > 0) self.allocator.free(self.kit_chunks);
        self.kit_chunks = &.{};
        for (self.kit_vsti) |*c| {
            if (c.load(.monotonic)) |kv| self.allocator.destroy(kv);
        }
        if (self.kit_vsti.len > 0) self.allocator.free(self.kit_vsti);
        self.kit_vsti = &.{};
        for (self.kit_sampler) |*c| {
            if (c.load(.monotonic)) |ks| self.allocator.destroy(ks);
        }
        if (self.kit_sampler.len > 0) self.allocator.free(self.kit_sampler);
        self.kit_sampler = &.{};
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
        for (self.vsti_events) |r| if (r.len > 0) self.allocator.free(r);
        if (self.vsti_events.len > 0) self.allocator.free(self.vsti_events);
        self.vsti_events = &.{};
        if (self.vsti_event_n.len > 0) self.allocator.free(self.vsti_event_n);
        self.vsti_event_n = &.{};
        if (self.vsti_active_lo.len > 0) self.allocator.free(self.vsti_active_lo);
        self.vsti_active_lo = &.{};
        if (self.vsti_active_hi.len > 0) self.allocator.free(self.vsti_active_hi);
        self.vsti_active_hi = &.{};
        if (self.last_kind.len > 0) self.allocator.free(self.last_kind);
        self.last_kind = &.{};
        if (self.chan_eq_ver.len > 0) self.allocator.free(self.chan_eq_ver);
        self.chan_eq_ver = &.{};
        self.instruments_cap = 0;
        self.channels_cap = 0;
        self.slots_cap = 0;
    }

    /// 设备状态（排障用）：-1 = 未初始化；0 = uninit / 1 = stopped / 2 = started / 3 = starting / 4 = stopping
    pub fn deviceState(self: *const Engine) i32 {
        if (!self.initialized) return -1;
        return @intCast(ma.ma_device_get_state(&self.device));
    }

    /// 建立/扩容引擎侧容量数组（**契约：设备未运行或已暂停**——见 `App.ensureAudioCapacity`）。
    /// 只增不减；旧内容（声部状态/缓冲残留/EQ 滤波器）按新布局拷贝保留。
    pub fn setCapacity(self: *Engine, ic: usize, cc: usize, sc: usize) !void {
        const a = self.allocator;
        if (ic != self.instruments_cap) {
            const ns = try a.alloc(synth.Synth, ic);
            for (ns) |*s| s.* = .{};
            for (ns[0..@min(ic, self.synths.len)], 0..) |*s, i| s.* = self.synths[i];
            if (self.synths.len > 0) a.free(self.synths);
            self.synths = ns;
            // 鼓组层声部池：惰性——只维护指针数组（Chunk 由 `App.ensureKitPool` 分配）
            const nk = try a.alloc(std.atomic.Value(?*KitPool), ic);
            for (nk) |*c| c.* = std.atomic.Value(?*KitPool).init(null);
            for (nk[0..@min(ic, self.kit_chunks.len)], 0..) |*c, i| c.* = std.atomic.Value(?*KitPool).init(self.kit_chunks[i].load(.monotonic));
            // 缩容裁掉的池就地释放（契约：设备不运行或已暂停）
            if (self.kit_chunks.len > ic) {
                for (self.kit_chunks[ic..]) |*c| {
                    if (c.load(.monotonic)) |kp| a.destroy(kp);
                }
            }
            if (self.kit_chunks.len > 0) a.free(self.kit_chunks);
            self.kit_chunks = nk;
            // 鼓组 VST3 层状态：惰性——只维护指针数组（Chunk 由 `App.ensureKitVsti` 分配）
            const nv = try a.alloc(std.atomic.Value(?*KitVstiState), ic);
            for (nv) |*c| c.* = std.atomic.Value(?*KitVstiState).init(null);
            for (nv[0..@min(ic, self.kit_vsti.len)], 0..) |*c, i| c.* = std.atomic.Value(?*KitVstiState).init(self.kit_vsti[i].load(.monotonic));
            // 缩容裁掉的状态就地释放（契约：设备不运行或已暂停）
            if (self.kit_vsti.len > ic) {
                for (self.kit_vsti[ic..]) |*c| {
                    if (c.load(.monotonic)) |kv| a.destroy(kv);
                }
            }
            if (self.kit_vsti.len > 0) a.free(self.kit_vsti);
            self.kit_vsti = nv;
            // 鼓组采样器层状态：惰性——只维护指针数组（Chunk 由 `App.ensureKitSampler` 分配）
            const nsm = try a.alloc(std.atomic.Value(?*KitSamplerState), ic);
            for (nsm) |*c| c.* = std.atomic.Value(?*KitSamplerState).init(null);
            for (nsm[0..@min(ic, self.kit_sampler.len)], 0..) |*c, i| c.* = std.atomic.Value(?*KitSamplerState).init(self.kit_sampler[i].load(.monotonic));
            if (self.kit_sampler.len > ic) {
                for (self.kit_sampler[ic..]) |*c| {
                    if (c.load(.monotonic)) |ks| a.destroy(ks);
                }
            }
            if (self.kit_sampler.len > 0) a.free(self.kit_sampler);
            self.kit_sampler = nsm;
            const ne = try a.alloc([]ivstevents.Event, ic);
            @memset(ne, &.{});
            errdefer {
                for (ne) |r| if (r.len > 0) a.free(r);
                a.free(ne);
            }
            for (ne, 0..) |*r, i| {
                r.* = try a.alloc(ivstevents.Event, vsti_batch_max);
                @memset(r.*, .{});
                if (i < self.vsti_events.len and self.vsti_events[i].len > 0) {
                    const cp = @min(r.len, self.vsti_events[i].len);
                    @memcpy(r.*[0..cp], self.vsti_events[i][0..cp]);
                }
            }
            for (self.vsti_events) |r| if (r.len > 0) a.free(r);
            if (self.vsti_events.len > 0) a.free(self.vsti_events);
            self.vsti_events = ne;
            const nn = try a.alloc(usize, ic);
            @memset(nn, 0);
            @memcpy(nn[0..@min(ic, self.vsti_event_n.len)], self.vsti_event_n[0..@min(ic, self.vsti_event_n.len)]);
            if (self.vsti_event_n.len > 0) a.free(self.vsti_event_n);
            self.vsti_event_n = nn;
            const nl = try a.alloc(u64, ic);
            @memset(nl, 0);
            @memcpy(nl[0..@min(ic, self.vsti_active_lo.len)], self.vsti_active_lo[0..@min(ic, self.vsti_active_lo.len)]);
            if (self.vsti_active_lo.len > 0) a.free(self.vsti_active_lo);
            self.vsti_active_lo = nl;
            const nh = try a.alloc(u64, ic);
            @memset(nh, 0);
            @memcpy(nh[0..@min(ic, self.vsti_active_hi.len)], self.vsti_active_hi[0..@min(ic, self.vsti_active_hi.len)]);
            if (self.vsti_active_hi.len > 0) a.free(self.vsti_active_hi);
            self.vsti_active_hi = nh;
            const nk2 = try a.alloc(u32, ic);
            @memset(nk2, 0);
            @memcpy(nk2[0..@min(ic, self.last_kind.len)], self.last_kind[0..@min(ic, self.last_kind.len)]);
            if (self.last_kind.len > 0) a.free(self.last_kind);
            self.last_kind = nk2;
            self.instruments_cap = ic;
        }
        if (cc != self.channels_cap) {
            const nb = try a.alloc(f32, cc * 2 * 4096);
            @memset(nb, 0);
            const cp2 = @min(nb.len, self.chan_bufs.len);
            @memcpy(nb[0..cp2], self.chan_bufs[0..cp2]);
            if (self.chan_bufs.len > 0) a.free(self.chan_bufs);
            self.chan_bufs = nb;
            const nv = try a.alloc(u32, cc);
            @memset(nv, 0);
            @memcpy(nv[0..@min(cc, self.chan_eq_ver.len)], self.chan_eq_ver[0..@min(cc, self.chan_eq_ver.len)]);
            if (self.chan_eq_ver.len > 0) a.free(self.chan_eq_ver);
            self.chan_eq_ver = nv;
            self.channels_cap = cc;
        }
        if (self.slot_eq.len != cc * sc * eq_bands * 2) {
            // slot_eq 重排：旧 (channels × slots) → 新（逐通道逐槽拷贝）
            const old_sc = self.slots_cap;
            const old_total = self.slot_eq.len;
            const old_cc = if (old_sc > 0) old_total / (old_sc * eq_bands * 2) else 0;
            const nq = try a.alloc(eq.Biquad, cc * sc * eq_bands * 2);
            @memset(nq, .{});
            const ccp = @min(cc, old_cc);
            const scp = @min(sc, old_sc);
            for (0..ccp) |ch| {
                for (0..scp) |sl| {
                    const o = (ch * old_sc + sl) * eq_bands * 2;
                    const n2 = (ch * sc + sl) * eq_bands * 2;
                    @memcpy(nq[n2 .. n2 + eq_bands * 2], self.slot_eq[o .. o + eq_bands * 2]);
                }
            }
            if (self.slot_eq.len > 0) a.free(self.slot_eq);
            self.slot_eq = nq;
            self.slots_cap = sc;
        }
    }

    /// 取鼓组层池的第 l 层（未分配 → null；测试也用它直取层池）
    pub fn kitSynth(self: *const Engine, i: usize, l: usize) ?*synth.KitLayerSynth {
        const kp = kitPool(self, i) orelse return null;
        if (l >= kit_max_layers) return null;
        return &kp.*[l];
    }
};

/// 鼓组层声部池：每乐器一池（`kit_max_layers` 层 × 每层 32 声部）
pub const KitPool = [kit_max_layers]synth.KitLayerSynth;

/// 鼓组采样器层的每层声部数（快滚奏时重叠一次性采样）
pub const kit_sampler_voices = 8;

/// 采样器声部（v1：一次性、原速；`step` 预留变速）
pub const SamplerVoice = struct {
    /// 采样内位置（帧，浮点——线性插值）
    pos: f64 = 0,
    /// 结束位置（帧；trim 末）
    end: f64 = 0,
    /// 每帧前进的采样帧数（v1 恒 1.0）
    step: f64 = 1.0,
    /// 输出增益（力度 × 层增益 × 声像 L/R）
    gain_l: f32 = 0,
    gain_r: f32 = 0,
    /// 触发音高（发声高亮回传用）
    pitch: u8 = 0,
    active: bool = false,
};

/// 鼓组采样器集体：每层一个声部池
pub const KitSamplerState = struct {
    layers: [kit_max_layers]Layer = @splat(.{}),

    pub const Layer = struct {
        voices: [kit_sampler_voices]SamplerVoice = @splat(.{}),
    };
};

/// 采样帧存储：解码器**原生格式**（`s16`）/ 高位深与未知容器（`f32`）。
/// 内存：16-bit 立体声 4 B/帧、单声道 2 B/帧（f32 分别是 8 / 4 B/帧）。
pub const SampleFrames = union(enum) {
    s16: []const i16,
    f32: []const f32,

    /// 采样点总数（= 帧数 × 声道）
    pub fn count(self: SampleFrames) usize {
        return switch (self) {
            .s16 => |v| v.len,
            .f32 => |v| v.len,
        };
    }

    /// 占用字节数（内存统计/诊断用）
    pub fn bytes(self: SampleFrames) usize {
        return switch (self) {
            .s16 => |v| v.len * @sizeOf(i16),
            .f32 => |v| v.len * @sizeOf(f32),
        };
    }

    /// 释放帧存储（**两种布局统一入口**；空切片安全）
    pub fn freeFrames(self: SampleFrames, allocator: std.mem.Allocator) void {
        switch (self) {
            .s16 => |v| if (v.len > 0) allocator.free(v),
            .f32 => |v| if (v.len > 0) allocator.free(v),
        }
    }
};

/// 不可变采样数据（UI 解码后发布；音频线程只读）。
///
/// **P3a**：不再一律 f32 立体声——存解码器**原生格式 + 原生声道数**（1/2），
/// 内存从 8 B/帧 降到 4 B/帧（16-bit 立体声）或 2 B/帧（16-bit 单声道）。
/// ⚠️ 取样**只准走 `frameAt` / `sampleStereoAt`**——直接下标会让单声道只出一只耳朵。
pub const SampleData = struct {
    frames: SampleFrames,
    /// 声道数：1 = 单声道（取样时双臂共用）；2 = 立体声交错
    channels: u8 = 2,
    /// 采样点数（**原生采样率**下的帧数——`frames` 的帧索引上限）
    frame_count: usize,
    /// 原生率 / 引擎率（播放位置换算：引擎帧 × ratio = 采样帧；1.0 = 同率）
    /// 解码时**不重采样**（P1 提速）：所有 UI/trim 仍以引擎帧为单位，
    /// 只在真正取样本时乘这个系数。
    ratio: f32 = 1.0,

    const k16: f32 = 1.0 / 32768.0;

    /// 引擎帧域长度（UI/trim 域：= frame_count / ratio）
    pub inline fn engFrames(self: *const SampleData) usize {
        if (self.ratio <= 0.0) return self.frame_count;
        return @intFromFloat(@as(f64, @floatFromInt(self.frame_count)) / @as(f64, self.ratio));
    }

    /// 取第 `i` 采样帧的立体声样本（单声道自动展开到 L/R）。
    /// **不做越界检查**（调用方先判范围）——热循环用这个。
    pub inline fn frameAt(self: *const SampleData, i: usize) [2]f32 {
        const mono = self.channels < 2;
        switch (self.frames) {
            .s16 => |fs| {
                if (mono) {
                    const v = k16 * @as(f32, @floatFromInt(fs[i]));
                    return .{ v, v };
                }
                return .{ k16 * @as(f32, @floatFromInt(fs[i * 2])), k16 * @as(f32, @floatFromInt(fs[i * 2 + 1])) };
            },
            .f32 => |fs| {
                if (mono) {
                    const v = fs[i];
                    return .{ v, v };
                }
                return .{ fs[i * 2], fs[i * 2 + 1] };
            },
        }
    }

    /// 原生帧域的小数位置取立体声（**线性插值**；越界 clamp 到首/尾帧）。
    pub inline fn sampleStereoAt(self: *const SampleData, pos: f64) [2]f32 {
        if (self.frame_count == 0) return .{ 0, 0 };
        const last = self.frame_count - 1;
        if (!(pos > 0)) return self.frameAt(0);
        if (pos >= @as(f64, @floatFromInt(last))) return self.frameAt(last);
        const ia: usize = @intFromFloat(pos);
        const ib = @min(ia + 1, last);
        const t: f32 = @floatCast(pos - @floor(pos));
        const a = self.frameAt(ia);
        const b = self.frameAt(ib);
        return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
    }
};

/// 音频片段播放表的一行（不可变快照；UI 重建后原子发布）
pub const AudioTableRow = struct {
    /// 时间轴（步）
    start: i32,
    len: i32,
    /// 采样数据与采样内 trim（帧）
    asset: ?*const SampleData,
    trim_start: i32,
    trim_len: i32,
    /// 混音通道 + 样式增益
    channel: u16,
    gain: f32,
    /// 播放速度（1 = 原速；v1 = 变速变调，0.5..2.0）
    speed: f32 = 1.0,
};

/// 音频片段播放表（**不可变**快照；UI 在帧末重建并发布）
pub const AudioTable = struct {
    rows: []const AudioTableRow,
};

/// 音频片段在**本渲染段**内的写入窗口（纯函数，见 `clipSpan`）。
/// 坐标全部是**段内相对**（`[w0, w1)` ∈ `[0, seg_len)`）——直接下标写本段缓冲。
pub const ClipSpan = struct {
    w0: usize,
    w1: usize,
    /// 对 `w0` 的采样内起点（原生帧域，可为小数）
    pos0: f64,
    /// 每个输出帧的采样内前进量（速度 × 采样率比）
    step: f64,
};

/// 计算一个音频片段在渲染段 `[seg_abs0, seg_abs0+seg_len)` 内的写入窗口。
///
/// **坑（实测“篝火噼啪声”的真因）**：音频线程会把一个块按音符事件切段
/// （`renderSegment` 多次调用），每段的缓冲长度 = 段长、且缓冲每次只清段长。
/// 旧实现用**整块起点**（`params.frames_played`）算段内偏移 → 第二段起越界
/// 与错位（每次音符事件炸一下）。这里强制用**段坐标**。
pub fn clipSpan(
    seg_abs0: i64,
    seg_len: i64,
    start_frame: i64,
    start_step: i32,
    step_frames: i64,
    row_start: i32,
    row_len: i32,
    trim_start: i32,
    trim_len: i32,
    speed: f32,
    ratio: f32,
    eng_frames: usize,
) ?ClipSpan {
    const r: f64 = @max(0.0001, @as(f64, ratio));
    const tstart: i64 = trim_start;
    var tlen: i64 = trim_len;
    if (tlen <= 0) tlen = @as(i64, @intCast(eng_frames)) - tstart;
    if (tlen <= 0 or tstart < 0 or @as(u64, @intCast(tstart)) >= eng_frames) return null;
    const tstart_n: i64 = @intFromFloat(@as(f64, @floatFromInt(tstart)) * r);
    const tlen_n: i64 = @intFromFloat(@as(f64, @floatFromInt(tlen)) * r);
    const spd: f64 = @max(0.25, @min(4.0, @as(f64, speed)));
    const tlen_play: i64 = @intFromFloat(@as(f64, @floatFromInt(tlen_n)) / spd);
    // 时间轴 → 绝对帧
    const clip_s: i64 = start_frame + @as(i64, @intCast(row_start - start_step)) * step_frames;
    const span_all: i64 = @as(i64, row_len) * step_frames;
    const audible: i64 = @min(span_all, tlen_play);
    const clip_e = clip_s + audible;
    const ov_s: i64 = @max(seg_abs0, clip_s);
    const ov_e: i64 = @min(seg_abs0 + seg_len, clip_e);
    if (ov_e <= ov_s) return null;
    return .{
        .w0 = @intCast(ov_s - seg_abs0),
        .w1 = @intCast(ov_e - seg_abs0),
        .pos0 = @as(f64, @floatFromInt(tstart_n)) + @as(f64, @floatFromInt(ov_s - clip_s)) * spd * r,
        .step = spd * r,
    };
}

/// 鼓组 VST3 层的每层运行态：事件批（音频线程段内写/消费）+ 发声位图
/// （暂停/all-off 按位补发 note-off——同乐器级 VSTi 惯例）。
pub const KitVstiState = struct {
    evts: [kit_max_layers]EvtBuf,
    active_lo: [kit_max_layers]u64 = @splat(0),
    active_hi: [kit_max_layers]u64 = @splat(0),

    pub const EvtBuf = struct {
        events: [vsti_batch_max]ivstevents.Event = undefined,
        n: usize = 0,
    };
};

/// 取某乐器的鼓组 VST3 层状态（未分配 → null；惰性分配见 `App.ensureKitVsti`）
fn kitVstiState(engine: *const Engine, i: usize) ?*KitVstiState {
    if (i >= engine.kit_vsti.len) return null;
    return engine.kit_vsti[i].load(.acquire);
}

/// 取某乐器的鼓组采样器层状态（未分配 → null；惰性分配见 `App.ensureKitSampler`）
fn kitSamplerState(engine: *const Engine, i: usize) ?*KitSamplerState {
    if (i >= engine.kit_sampler.len) return null;
    return engine.kit_sampler[i].load(.acquire);
}

/// 采样器层：触发一次（一次性；找空闲声部，无 → 覆盖 0 号）
fn kitSamplerNoteOn(engine: *Engine, i: usize, l: usize, pitch: u8, velocity: u8, pan: f32) void {
    const st = kitSamplerState(engine, i) orelse return;
    const params = engine.params;
    const asset = params.kit_layer_asset[i][l].load(.acquire) orelse return;
    if (l >= kit_max_layers) return;
    const ld = &st.layers[l];
    var v: *SamplerVoice = &ld.voices[0];
    for (&ld.voices) |*cand| {
        if (!cand.active) {
            v = cand;
            break;
        }
    }
    const ts = params.kit_layer_trim_start[i][l].load(.monotonic);
    var tl = params.kit_layer_trim_len[i][l].load(.monotonic);
    if (ts < 0) return;
    // 引擎帧 → 采样帧（原生率；解码不重采样）
    const kr: f64 = @max(0.0001, @as(f64, asset.ratio));
    const total = asset.frame_count;
    if (ts >= @as(i32, @intCast(asset.engFrames()))) return;
    if (tl <= 0) tl = @as(i32, @intCast(asset.engFrames() - @as(usize, @intCast(ts))));
    const ts_n: usize = @intFromFloat(@as(f64, @floatFromInt(ts)) * kr);
    const end: usize = @min(total, @as(usize, @intFromFloat(@as(f64, @floatFromInt(@as(i64, @intCast(ts)) + tl)) * kr)));
    if (end <= ts_n) return;
    // ⚠️ `balanceGains` 要的是 **0..1**，而这里拿到的 `pan` 是**音符级 0..127**
    // （`effectivePan` 的返回）——直接传 → clamp 到 1.0 → **只有右耳**（实测 bug）。
    const bg = balanceGains(pan / 127.0);
    const g: f32 = @as(f32, @floatFromInt(@max(1, velocity))) / 127.0;
    const spd = std.math.clamp(params.kit_layer_speed[i][l].load(.monotonic), 0.25, 4.0);
    v.* = .{
        .pos = @floatFromInt(ts_n),
        .end = @floatFromInt(end),
        .step = spd * @as(f32, @floatCast(kr)),
        .gain_l = g * bg[0],
        .gain_r = g * bg[1],
        .pitch = pitch,
        .active = true,
    };
}

/// 混音鼓组采样器层（**一次性声部**；线性插值、按 trim 区间结束）。
/// 写进乐器自己的通道缓冲（`cbuf` = 立体声交错，`n_samples` = 采样点总数 = 帧×2）。
/// `g` = 乐器增益、`lg` = 层增益；声部自己的 `gain_l/gain_r` 已含力度×声像。
/// 【pub 供单测直接调用；渲染路径在同一处】
pub fn mixKitSamplerLayer(
    engine: *Engine,
    params: *const Params,
    cbuf: [*]f32,
    n_samples: usize,
    i: usize,
    l: usize,
    g: f32,
    lg: f32,
) void {
    const st = kitSamplerState(engine, i) orelse return;
    if (l >= kit_max_layers) return;
    const asset = params.kit_layer_asset[i][l].load(.acquire) orelse return;
    if (asset.frame_count < 2) return;
    const total: usize = asset.frame_count;
    const ld = &st.layers[l];
    for (&ld.voices) |*v| {
        if (!v.active) continue;
        var k: usize = 0;
        while (k < n_samples) : (k += 2) {
            if (v.pos >= v.end) {
                v.active = false;
                break;
            }
            const idx: usize = @intFromFloat(v.pos);
            if (idx + 1 >= total) {
                v.active = false;
                break;
            }
            // 取样（含插值 / 单声道展开 / i16 换算）统一走 `sampleStereoAt`
            const s = asset.sampleStereoAt(v.pos);
            cbuf[k] += s[0] * v.gain_l * g * lg;
            cbuf[k + 1] += s[1] * v.gain_r * g * lg;
            v.pos += v.step;
        }
    }
}

/// 采样器层：全部声部清零（暂停/跳转/全体释音）
fn kitSamplerAllOff(engine: *Engine, i: usize) void {
    const st = kitSamplerState(engine, i) orelse return;
    for (&st.layers) |*ld| {
        for (&ld.voices) |*v| v.* = .{};
    }
}

/// 取某乐器的鼓组层池（未分配 → null；惰性分配见 `App.ensureKitPool`）
fn kitPool(engine: *const Engine, i: usize) ?*KitPool {
    if (i >= engine.kit_chunks.len) return null;
    return engine.kit_chunks[i].load(.acquire);
}

/// 释放**两个声部池**的全部声部（合成器 + 鼓组层）——暂停下降沿/跳转作废/
/// 全体释音（all_off）共用。
/// 注：漏掉鼓组层池是实测 bug——暂停后鼓组的音会一直响到停止
/// （旧代码只遍历了 `synths`）。
fn releaseAllVoices(engine: *Engine) void {
    for (engine.synths) |*s| synth.allOff(s);
    for (engine.kit_chunks) |*c| {
        if (c.load(.monotonic)) |kp| for (&kp.*) |*s| synth.allOff(s);
    }
    // VSTi：**panic 式**全体释音（全 128 音高）——位图可能已失同步
    // （如恢复唤醒的幽灵声部/批满丢事件），按位图补 off 会漏 → 用不掉挂的版本
    const params = engine.params;
    for (0..engine.synths.len) |i| {
        if (params.instrument_kind[i].load(.monotonic) == 2) vstiPanic(engine, i);
    }
    // 鼓组 VST3 层：同样 panic 式全体释音（仅在有实例的层；位图可能失同步）
    for (0..engine.kit_vsti.len) |i| {
        const n_layers = @min(params.kit_layer_count[i].load(.monotonic), kit_max_layers);
        for (0..n_layers) |l| {
            if (params.kit_layer_kind[i][l].load(.monotonic) != 2) continue;
            if (params.kit_layer_plugin[i][l].load(.acquire) == null) continue;
            kitLayerVstiPanic(engine, i, l);
        }
    }
    // 鼓组采样器层：声部全清零（一次性无 off 可依——暂停/全体释音必须硬清）
    for (0..engine.kit_sampler.len) |i| kitSamplerAllOff(engine, i);
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
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOnEvent),
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
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOffEvent),
        .data = .{ .noteOff = .{
            .channel = 0,
            .pitch = @intCast(pitch),
            .velocity = 0,
            .noteId = -1,
        } },
    });
}

/// VSTi：**全 128 音高**无条件 note-off（panic）。
/// 与 `vstiAllOff`（仅活跃位图）的区别：state 恢复可能唤醒“快照里仍在发声”的
/// 幽灵声部（不在位图中）——只能地毯式清；顺带擦除位图（重新对齐真实状态）。
/// 事件量 128 ≤ `vsti_batch_max`（已为“段内真实事件 + panic”预留翻倍容量）。
fn vstiPanic(engine: *Engine, i: usize) void {
    var p: u16 = 0;
    while (p < 128) : (p += 1) vstiNoteOff(engine, i, @intCast(p));
}

// ── 鼓组 VST3 层（每层一份事件批 + 位图；同乐器级 VSTi 惯例）──

/// 鼓组 VST3 层：置位/清除发声位图
fn kitLayerVstiActiveSet(engine: *Engine, i: usize, l: usize, pitch: u8, on: bool) void {
    const st = kitVstiState(engine, i) orelse return;
    if (pitch < 64) {
        const bit = @as(u64, 1) << @intCast(pitch);
        if (on) st.active_lo[l] |= bit else st.active_lo[l] &= ~bit;
    } else {
        const bit = @as(u64, 1) << @intCast(pitch - 64);
        if (on) st.active_hi[l] |= bit else st.active_hi[l] &= ~bit;
    }
}

/// 鼓组 VST3 层：追加事件到该层批（满则丢弃——宁可丢事件不分配）
fn kitLayerVstiPush(engine: *Engine, i: usize, l: usize, ev: ivstevents.Event) void {
    const st = kitVstiState(engine, i) orelse return;
    const b = &st.evts[l];
    if (b.n >= b.events.len) return;
    b.events[b.n] = ev;
    b.n += 1;
}

fn kitLayerVstiNoteOn(engine: *Engine, i: usize, l: usize, pitch: u8, velocity: u8) void {
    kitLayerVstiActiveSet(engine, i, l, pitch, true);
    kitLayerVstiPush(engine, i, l, .{
        .sampleOffset = 0,
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOnEvent),
        .data = .{ .noteOn = .{
            .channel = 0,
            .pitch = @intCast(pitch),
            .velocity = @as(f32, @floatFromInt(@max(1, velocity))) / 127.0,
            .length = 0,
            .noteId = -1,
        } },
    });
}

fn kitLayerVstiNoteOff(engine: *Engine, i: usize, l: usize, pitch: u8) void {
    kitLayerVstiActiveSet(engine, i, l, pitch, false);
    kitLayerVstiPush(engine, i, l, .{
        .sampleOffset = 0,
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOffEvent),
        .data = .{ .noteOff = .{
            .channel = 0,
            .pitch = @intCast(pitch),
            .velocity = 0,
            .noteId = -1,
        } },
    });
}

/// 鼓组 VST3 层：全 128 音高补 off（panic 式——位图可能失同步）
fn kitLayerVstiPanic(engine: *Engine, i: usize, l: usize) void {
    var p: u16 = 0;
    while (p < 128) : (p += 1) kitLayerVstiNoteOff(engine, i, l, @intCast(p));
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
/// 还要释放全部声部——**除非**本次是软切换（`sched_gen_soft` 置位：保位
/// 模式切换，声部保持发声；标志单次消费）。
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
fn handleGenChange(engine: *Engine, params: *Params, gen: u32, was_playing: bool) void {
    engine.stash_n = 0;
    engine.stash_gen = gen;
    if (was_playing) {
        // 软切换（保位模式切换）：声部保持发声（见 `Params.sched_gen_soft`）。
        // 跳转/起播路径写 false → 照旧释放（跳转必需：上面注释的悬挂依据）。
        if (!params.sched_gen_soft.swap(false, .acq_rel)) releaseAllVoices(engine);
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
    for (0..engine.synths.len) |i| {
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
        // 鼓组层池（惰性分配；未分配 = 无声部 → 跳过）
        if (kitPool(engine, i)) |kp| {
            for (&kp.*) |*s| {
                for (s.voices) |v| {
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
        }
        // 鼓组 VST3 层：位图并集（惰性状态；未分配 = 无层 → 跳过）
        if (kitVstiState(engine, i)) |st| {
            for (0..kit_max_layers) |l| {
                lo |= st.active_lo[l];
                hi |= st.active_hi[l];
            }
        }
        // 鼓组采样器层：发声声部的触发音高（一次性）
        if (kitSamplerState(engine, i)) |kss| {
            for (&kss.layers) |*ld| {
                for (&ld.voices) |*v| {
                    if (!v.active) continue;
                    const p = v.pitch;
                    if (p < 64) {
                        lo |= @as(u64, 1) << @intCast(p);
                    } else {
                        hi |= @as(u64, 1) << @intCast(p - 64);
                    }
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
    if (ev.instrument >= engine.synths.len) return;
    const params = engine.params;
    const kind = params.instrument_kind[ev.instrument].load(.monotonic);
    const is_kit = kind == 1;
    const is_vsti = kind == 2;
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
                    const lkind = params.kit_layer_kind[ev.instrument][l].load(.monotonic);
                    // VST3 层：事件转发到该层插件（实例未就绪 → 跳过）
                    if (lkind == 2) {
                        if (params.kit_layer_plugin[ev.instrument][l].load(.acquire) != null) {
                            kitLayerVstiNoteOn(engine, ev.instrument, l, ev.pitch, ev.velocity);
                        }
                        continue;
                    }
                    // 采样器层：一次性触发（不需要声部池的 kit pool）
                    if (lkind == 3) {
                        kitSamplerNoteOn(engine, ev.instrument, l, ev.pitch, ev.velocity, pan);
                        continue;
                    }
                    const ks = engine.kitSynth(ev.instrument, l) orelse continue;
                    synth.noteOn(ks, ev.pitch, ev.velocity, pan);
                }
            } else {
                synth.noteOn(&engine.synths[ev.instrument], ev.pitch, ev.velocity, pan);
            }
        },
        .off => {
            if (is_vsti) {
                vstiNoteOff(engine, ev.instrument, ev.pitch);
            } else if (is_kit) {
                // 全部层都收 off（无关层空转——防漏 off；采样器为一次性，off 自然无效）
                const n_layers = @min(params.kit_layer_count[ev.instrument].load(.monotonic), kit_max_layers);
                for (0..n_layers) |l| {
                    const lkind = params.kit_layer_kind[ev.instrument][l].load(.monotonic);
                    if (lkind == 2) {
                        if (params.kit_layer_plugin[ev.instrument][l].load(.acquire) != null) {
                            kitLayerVstiNoteOff(engine, ev.instrument, l, ev.pitch);
                        }
                        continue;
                    }
                    if (lkind == 3) continue; // 一次性：off 不处理
                    if (engine.kitSynth(ev.instrument, l)) |ks| synth.noteOff(ks, ev.pitch);
                }
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
    const idx = ((ch * engine.slots_cap + slot) * eq_bands + band) * 2 + chan;
    return &engine.slot_eq[idx];
}

/// 渲染一个分段（多乐器 → 按通道独立缓冲 → EQ/增益/声像 → 主输出叠加）。
/// `out` 已清零；本函数**累加**到 out。
pub fn renderSegment(engine: *Engine, params: *Params, out: [*]f32, frames: u32, sr: f32, master: f32) void {
    const n: usize = @as(usize, frames) * 2;
    const buf_stride: usize = 2 * 4096;
    const n_ch: usize = @min(params.channel_count.load(.monotonic), engine.channels_cap);
    // 容量未建立/缓冲尺寸不足（测试环境手工布局）→ 直接返回
    if (n_ch > 0 and (engine.chan_bufs.len < n_ch * buf_stride or engine.slot_eq.len < n_ch * engine.slots_cap * eq_bands * 2)) return;
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
    for (0..engine.synths.len) |i| {
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
            // state 恢复防挂音（UI 置旗标）：本段先对全 128 音高补 off——
            // 恢复可能唤醒“快照里仍在发声”的幽灵声部（不在活跃位图）
            if (params.instrument_panic[i].swap(false, .acq_rel)) vstiPanic(engine, i);
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
            for (0..n_layers) |l| {
                const lg = params.kit_layer_gain[i][l].load(.monotonic);
                if (params.kit_layer_kind[i][l].load(.monotonic) == 2) {
                    // VST3 层：中转缓冲 → 增益 × 等功率平衡 → 叠加（同乐器级 VSTi；
                    // 音符级声像不适用——插件只收音高/力度，声像 = 乐器声像平衡）
                    const pl = params.kit_layer_plugin[i][l].load(.acquire) orelse continue;
                    const st = kitVstiState(engine, i) orelse continue;
                    if (engine.vsti_scratch.len < n) continue;
                    // state 恢复防挂音（UI 置旗标）：本段先全 128 补 off
                    if (params.kit_layer_panic[i][l].swap(false, .acq_rel)) kitLayerVstiPanic(engine, i, l);
                    const sc = engine.vsti_scratch[0..n];
                    @memset(sc, 0);
                    pl.processInstrument(sc, frames, st.evts[l].events[0..st.evts[l].n], host_time);
                    st.evts[l].n = 0;
                    const bg = balanceGains(params.instrument_pan[i].load(.monotonic));
                    var k2: usize = 0;
                    while (k2 < n) : (k2 += 2) {
                        cbuf[k2] += sc[k2] * g * lg * bg[0];
                        cbuf[k2 + 1] += sc[k2 + 1] * g * lg * bg[1];
                    }
                    continue;
                }
                if (params.kit_layer_kind[i][l].load(.monotonic) == 3) {
                    // 采样器层：一次性声部（trim 区间内插值播放）
                    mixKitSamplerLayer(engine, params, cbuf, n, i, l, g, lg);
                    continue;
                }
                const lp = params.kit_layer_params[i][l].load(.monotonic) orelse continue;
                const ks = engine.kitSynth(i, l) orelse continue;
                synth.render(lp, ks, cbuf, frames, sr, g * lg, true);
            }
        } else {
            synth.render(sp, &engine.synths[i], cbuf, frames, sr, g, true);
        }
    }

    // 2.5) 音频片段 + 波形试听：**无状态按帧映射**（跳转/循环天然正确）：
    // 位置 = start_step + (abs − start_frame)/step_frames；**本段** = [seg_abs0, +frames)
    {
        // **段坐标**（不是整块起点！——见 `clipSpan` 注释里的“篝火噼啪”事故）
        const abs0 = engine.seg_abs0;
        const start_frame = params.start_frame.load(.monotonic);
        const start_step = params.start_step.load(.monotonic);
        const start_frame_i: i64 = @intCast(start_frame);
        const bpm2: u64 = @max(20, params.bpm.load(.monotonic));
        const spb2: u64 = @max(1, params.steps_per_beat.load(.monotonic));
        const step_frames: u64 = @max(1, @as(u64, @intFromFloat(@as(f64, sr))) * 60 / (bpm2 * spb2));
        if (params.audio_table.load(.acquire)) |tbl| {
            // **仅在播放时扫描**（暂停时位置映射仍在推进——实测 bug：暂停中拖入的
            // 音频“一直放、停止不停”）
            if (params.playing.load(.monotonic)) {
                for (tbl.rows) |row| {
                    const asset = row.asset orelse continue;
                    if (asset.frame_count == 0) continue;
                    const sp = clipSpan(
                        @intCast(abs0),
                        @as(i64, @intCast(frames)),
                        start_frame_i,
                        start_step,
                        @as(i64, @intCast(step_frames)),
                        row.start,
                        row.len,
                        row.trim_start,
                        row.trim_len,
                        row.speed,
                        asset.ratio,
                        asset.engFrames(),
                    ) orelse continue;
                    if (n_ch == 0) continue; // 无混音通道：不渲染（防御：chan_bufs 未分配时索引会崩）
                    const ch: usize = if (n_ch > 0) @min(row.channel, n_ch - 1) else 0;
                    const cb: [*]f32 = @ptrCast(&engine.chan_bufs[ch * buf_stride]);
                    var w: usize = sp.w0;
                    while (w < sp.w1) : (w += 1) {
                        const posf: f64 = sp.pos0 + @as(f64, @floatFromInt(w - sp.w0)) * sp.step;
                        if (posf < 0) continue;
                        const ip: usize = @intFromFloat(posf);
                        if (ip >= asset.frame_count) break;
                        // **线性插值**（采样率与引擎不同/变速时不再取最近邻——减少混叠噪声）
                        // 取样统一走 `sampleStereoAt`（单声道 / i16 都在里面展开）
                        const s = asset.sampleStereoAt(posf);
                        cb[w * 2] += s[0] * row.gain;
                        cb[w * 2 + 1] += s[1] * row.gain;
                    }
                }
            }
        }
        // 波形窗口试听（全局单实例；无状态：读游标→混音→写回）
        if (params.preview_playing.load(.monotonic)) {
            if (params.preview_asset.load(.acquire)) |pa| {
                const ps = params.preview_start.load(.monotonic);
                var pl = params.preview_len.load(.monotonic);
                const cur = params.preview_pos.load(.monotonic);
                if (ps < 0 or cur < ps or @as(usize, @intCast(cur)) >= pa.engFrames()) {
                    params.preview_playing.store(false, .monotonic);
                    params.preview_pos.store(-1, .monotonic);
                } else {
                    const pr: f64 = @max(0.0001, @as(f64, pa.ratio));
                    if (pl <= 0) pl = @intCast(pa.engFrames() - @as(usize, @intCast(ps)));
                    const p_end_eng: usize = @min(pa.engFrames(), @as(usize, @intCast(ps)) + @as(usize, @intCast(pl)));
                    const p_end: usize = @min(pa.frame_count, @as(usize, @intFromFloat(@as(f64, @floatFromInt(p_end_eng)) * pr)));
                    const pg = params.preview_gain.load(.monotonic);
                    const ch2: usize = if (n_ch > 0) @min(params.preview_channel.load(.monotonic), n_ch - 1) else 0;
                    const cb2: [*]f32 = @ptrCast(&engine.chan_bufs[ch2 * buf_stride]);
                    const pspd: f64 = @max(0.25, @min(4.0, @as(f64, params.preview_speed.load(.monotonic)))) * pr;
                    const loop_on = params.preview_loop.load(.monotonic);
                    const p_end_f: f64 = @floatFromInt(p_end);
                    const start_f: f64 = @as(f64, @floatFromInt(@max(0, ps))) * pr;
                    var ppos: f64 = @as(f64, @floatFromInt(cur)) * pr; // 引擎帧 → 采样帧
                    if (ppos >= p_end_f) ppos = start_f; // 防御：陈旧游标（裁剪缩短了）
                    // **循环必须在一个块内回绕**：否则每块都是“播到末尾→回绕”，而下块又从旧游标开始，
                    // 听感就是卡在右端点反复播同一个点（实测：“电流声”），游标也不动。
                    const can_loop = loop_on and start_f < p_end_f;
                    var f2: usize = 0;
                    while (f2 < frames) {
                        if (ppos >= p_end_f) {
                            if (!can_loop) break;
                            ppos = start_f;
                        }
                        const pi: usize = @intFromFloat(ppos);
                        if (pi >= p_end) break;
                        const psamp = pa.frameAt(pi);
                        cb2[f2 * 2] += psamp[0] * pg;
                        cb2[f2 * 2 + 1] += psamp[1] * pg;
                        f2 += 1;
                        ppos += pspd;
                    }
                    if (ppos >= p_end_f and !can_loop) {
                        // 不循环且播完（到右端点）：**游标回左端点**（= 下次 ▶ 的起点）
                        params.preview_playing.store(false, .monotonic);
                        params.preview_pos.store(@max(0, ps), .monotonic);
                    } else {
                        const pos_eng: i32 = @intFromFloat(ppos / pr);
                        const max_eng: i32 = @intCast(pa.engFrames() - 1);
                        params.preview_pos.store(std.math.clamp(pos_eng, @max(0, ps), @max(0, max_eng)), .monotonic);
                    }
                }
            } else {
                params.preview_playing.store(false, .monotonic);
            }
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
        for (0..engine.slots_cap) |slot| {
            for (0..eq_bands) |b| {
                const p = params.channel_eq[ch_i][b];
                eqBiquadAt(engine, ch_i, slot, b, 0).setPeak(sr, p.freq, p.q, p.gain_db);
                eqBiquadAt(engine, ch_i, slot, b, 1).setPeak(sr, p.freq, p.q, p.gain_db);
            }
        }
    }

    // 效果器链长度（以 `effect_count` 为准）
    const eff_n: usize = @min(params.effect_count[ch_i].load(.monotonic), engine.slots_cap);

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
                for (0..fx.max_params) |pi| p[pi] = params.fxParam(ch_i, slot, pi).load(.monotonic);
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
    for (0..engine.synths.len) |i| {
        const k = params.instrument_kind[i].load(.monotonic);
        if (k == engine.last_kind[i]) continue;
        engine.last_kind[i] = k;
        synth.allOff(&engine.synths[i]);
        if (kitPool(engine, i)) |kp| for (&kp.*) |*s| synth.allOff(s);
        // VSTi：类型切走/切回都补 off（防悬挂）；待发批一并作废
        vstiAllOff(engine, i);
        engine.vsti_event_n[i] = 0;
    }
}

/// 音频回调（实时线程）：设备包装 → `renderBlock`。严格约束：无分配、无锁、无阻塞。
fn dataCallback(
    device: ?*ma.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = input;
    const engine: *Engine = @ptrCast(@alignCast(device.?.pUserData));
    const out: [*]f32 = @ptrCast(@alignCast(output.?));
    renderBlock(engine, engine.params, out, frame_count, @floatFromInt(device.?.sampleRate));
}

/// 渲染一个块（多乐器合成 + 序列器精确触发）——**实时回调与离线导出共用**
/// （同一代码路径，离线/实时一致）。帧计数由 `params.frames_played` 驱动并推进；
/// 离线导出时设备已暂停，由导出循环独占调用。
pub fn renderBlock(engine: *Engine, params: *Params, out: [*]f32, frames: u32, sr: f32) void {
    const sr_u64: u64 = @intFromFloat(sr);

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
        publishOutMeter(params, out, frames);
        return;
    }

    // 4) 播放：stash 管理 + 样本级事件触发
    if (gen != engine.stash_gen) handleGenChange(engine, params, gen, was_playing);
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
            engine.dbg_dispatched += 1;
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
    publishOutMeter(params, out, frames);
}

/// 主输出电平/削波统计（音频线程→UI 原子量）：峰值 + |x|>1 采样计数
fn publishOutMeter(params: *Params, out: [*]f32, frames: u32) void {
    const n: usize = @as(usize, frames) * 2;
    var peak: f32 = 0;
    var over: u32 = 0;
    for (0..n) |i| {
        const v = @abs(out[i]);
        if (v > peak) peak = v;
        if (v > 1.0) over += 1;
    }
    params.out_peak.store(peak, .monotonic);
    if (over > 0) _ = params.out_over.fetchAdd(over, .monotonic);
}

test "audio: 播放中 gen 变化（跳转）释放全部声部（修“跳走后音符悬挂”）" {
    var params = Params{};
    try params.initCapacity(std.testing.allocator, 1, 0, 0);
    defer params.deinit(std.testing.allocator);
    var engine = Engine{ .params = &params };
    engine.allocator = std.testing.allocator;
    try engine.setCapacity(1, 0, 0);
    defer engine.deinit();

    var p = synth.SynthParams{}; // 默认：release ≈ 10ms、sustain 0.7
    var buf: [4800 * 2]f32 = undefined; // 0.1s @ 48k

    // 声部正在发声（模拟播放中扫到了音符）
    synth.noteOn(&engine.synths[0], 60, synth.default_velocity, synth.default_pan);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false); // 进入 sustain
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));
    engine.stash_n = 3;
    engine.stash_gen = 7;

    // 播放中跳转（gen 变化）→ stash 作废 + 声部进入 release
    handleGenChange(&engine, &params, 8, true);
    try std.testing.expectEqual(@as(u32, 8), engine.stash_gen);
    try std.testing.expectEqual(@as(usize, 0), engine.stash_n);
    // 再渲染 0.1s：release（≈10ms）已走完 → 归零
    // （若仍停在 sustain，activeCount 会一直是 1——正是实测 bug）
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));

    // 起播（上一块未播放）→ **不释放**（不误杀试听/释音尾音）
    synth.noteOn(&engine.synths[0], 64, synth.default_velocity, synth.default_pan);
    handleGenChange(&engine, &params, 9, false);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0])); // 仍在响
}

test "audio: 软切换（sched_gen_soft）gen 变化不释放声部（保位模式切换）" {
    var params = Params{};
    try params.initCapacity(std.testing.allocator, 1, 0, 0);
    defer params.deinit(std.testing.allocator);
    var engine = Engine{ .params = &params };
    engine.allocator = std.testing.allocator;
    try engine.setCapacity(1, 0, 0);
    defer engine.deinit();

    var p = synth.SynthParams{};
    var buf: [4800 * 2]f32 = undefined; // 0.1s @ 48k

    // 声部正在发声（模拟保位切换时刻）
    synth.noteOn(&engine.synths[0], 60, synth.default_velocity, synth.default_pan);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false); // 进入 sustain
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0]));
    engine.stash_n = 3;
    engine.stash_gen = 7;

    // 软切换：stash 照旧作废（旧事件消失），但声部**保持发声**（不进入 release）
    params.sched_gen_soft.store(true, .release);
    handleGenChange(&engine, &params, 8, true);
    try std.testing.expectEqual(@as(u32, 8), engine.stash_gen);
    try std.testing.expectEqual(@as(usize, 0), engine.stash_n);
    try std.testing.expect(!params.sched_gen_soft.load(.monotonic)); // 单次消费
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(&engine.synths[0])); // 仍在响（硬切换为 0）

    // 标志已消费：下一次 gen 变化（无置位）= 硬切换 → 释放
    handleGenChange(&engine, &params, 9, true);
    synth.render(&p, &engine.synths[0], &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(&engine.synths[0]));
}

test "audio: Params 默认值" {
    var p = Params{};
    try p.initCapacity(std.testing.allocator, 1, 1, 1);
    defer p.deinit(std.testing.allocator);
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
    try params.initCapacity(std.testing.allocator, 1, 0, 0);
    defer params.deinit(std.testing.allocator);
    var engine = Engine{ .params = &params };
    engine.allocator = std.testing.allocator;
    try engine.setCapacity(1, 0, 0);
    defer engine.deinit();

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
            try params.initCapacity(alloc_, 1, 2, 1);
            defer params.deinit(alloc_);
            var engine = Engine{ .params = &params };
            engine.allocator = alloc_;
            try engine.setCapacity(1, 2, 1);
            defer engine.deinit();

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
    try params.initCapacity(std.testing.allocator, 2, 0, 0);
    defer params.deinit(std.testing.allocator);
    var engine = Engine{ .params = &params };
    engine.allocator = std.testing.allocator;
    try engine.setCapacity(2, 0, 0);
    defer engine.deinit();

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
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(engine.kitSynth(0, 0).?));
    engine.was_playing = true;
    transportEdge(engine, false);
    synth.render(&lp0, engine.kitSynth(0, 0).?, &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(engine.kitSynth(0, 0).?));

    // ② 跳转（gen 变化且播放中）：同样释放层池
    dispatchNote(engine, synth.NoteEvent{ .kind = .on, .pitch = 35, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(engine.kitSynth(0, 0).?));
    handleGenChange(engine, engine.params, engine.stash_gen + 1, true);
    synth.render(&lp0, engine.kitSynth(0, 0).?, &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(engine.kitSynth(0, 0).?));
}

test "audio: 频谱取自目标效果器输入（非主输出全混）" {
    const alloc = std.testing.allocator;
    var params = Params{};
    try params.initCapacity(alloc, 2, 2, 1);
    defer params.deinit(alloc);
    var engine = Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(2, 2, 1);
    defer engine.deinit();

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
        try self.params.initCapacity(alloc, 4, if (with_bufs) 2 else 0, if (with_bufs) 1 else 0);
        self.engine = Engine{ .params = &self.params };
        self.engine.allocator = alloc;
        try self.engine.setCapacity(self.params.instruments_cap, self.params.channels_cap, self.params.slots_cap);
        // 夹具：默认分配乐器 0 的鼓组层池（用例用 `kitSynth(0, l)` 直取）
        const kp = try alloc.create(KitPool);
        for (kp) |*s| s.* = .{};
        self.engine.kit_chunks[0].store(kp, .monotonic);
    }

    fn deinit(self: *KitTestEnv, alloc: std.mem.Allocator) void {
        self.engine.deinit();
        self.params.deinit(alloc);
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
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(env.engine.kitSynth(0, 0).?));
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(env.engine.kitSynth(0, 1).?));
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(env.engine.kitSynth(0, 2).?));

    // 高亮并集：35；再响 38 → 两位都置
    publishSounding(&env.engine, &env.params);
    try std.testing.expect(env.params.sounding_lo[0].load(.monotonic) & (@as(u64, 1) << 35) != 0);
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 38, .instrument = 0 });
    publishSounding(&env.engine, &env.params);
    try std.testing.expect(env.params.sounding_lo[0].load(.monotonic) & (@as(u64, 1) << 38) != 0);

    // off 35：**全层**都收到（不查映射）——槽位 0/1 释放、槽位 2 不受影响
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .off, .pitch = 35, .instrument = 0 });
    var buf: [4800 * 2]f32 = undefined;
    synth.render(&lp0, env.engine.kitSynth(0, 0).?, &buf, 4800, 48000, 1.0, false);
    synth.render(&lp1, env.engine.kitSynth(0, 1).?, &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(env.engine.kitSynth(0, 0).?));
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(env.engine.kitSynth(0, 1).?));
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(env.engine.kitSynth(0, 2).?)); // 38 仍在响
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
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(env.engine.kitSynth(0, 0).?));

    // 响着时改映射：槽位 0 改成 36（模拟用户编辑）——old 35 声部还在响
    env.params.kit_layer_pitch[0][0].store(36, .monotonic);

    // off 35：不查映射 → 槽位 0 的 35 声部照常收到 noteOff → 释放
    // （若 off 查映射，这里会漏 → 悬挂，正是实测教训的模式）
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .off, .pitch = 35, .instrument = 0 });
    var buf: [4800 * 2]f32 = undefined;
    synth.render(&lp0, env.engine.kitSynth(0, 0).?, &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(env.engine.kitSynth(0, 0).?));
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
    try std.testing.expectEqual(@as(usize, 1), synth.activeCount(engine.kitSynth(0, 0).?));
    params.instrument_kind[0].store(0, .monotonic);
    applyKindEdges(engine);
    synth.render(&lp0, engine.kitSynth(0, 0).?, &buf, 4800, 48000, 1.0, false);
    try std.testing.expectEqual(@as(usize, 0), synth.activeCount(engine.kitSynth(0, 0).?));

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
    params.fxParam(0, 0, 0).store(@floatFromInt(fx.delay_tempo_default), .monotonic); // 档位 1/8（BPM 120 → 0.25s）
    params.fxParam(0, 0, 1).store(0.5, .monotonic); // 反馈

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
    const dll_z = alloc.dupeSentinel(u8, "zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
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

test "audio: VSTi panic——全 128 音高 note-off + 位图清零（state 恢复防挂音）" {
    var env: KitTestEnv = undefined;
    try env.init(std.testing.allocator, false);
    defer env.deinit(std.testing.allocator);
    const engine = &env.engine;
    const params = &env.params;
    params.instrument_kind[0].store(2, .monotonic);
    vstiNoteOn(engine, 0, 60, 100);
    vstiNoteOn(engine, 0, 72, 100);
    try std.testing.expect(engine.vsti_active_lo[0] != 0);
    try std.testing.expect(engine.vsti_active_hi[0] != 0);
    const before = engine.vsti_event_n[0];
    vstiPanic(engine, 0);
    try std.testing.expectEqual(@as(u64, 0), engine.vsti_active_lo[0]); // 位图清零
    try std.testing.expectEqual(@as(u64, 0), engine.vsti_active_hi[0]);
    try std.testing.expectEqual(before + 128, engine.vsti_event_n[0]); // 全 128 无条件 off
    for (engine.vsti_events[0][before..engine.vsti_event_n[0]], 0..) |ev, k| {
        try std.testing.expectEqual(@backingInt(ivstevents.Event.EventTypes.kNoteOffEvent), ev.type);
        try std.testing.expectEqual(@as(i16, @intCast(k)), ev.data.noteOff.pitch);
    }
}

test "audio: clipSpan——按段坐标计算（多段渲染不越界、不重复）" {
    const step_frames: i64 = 100;
    const eng_frames: usize = 4800;

    // 段 1：[0,128)
    const s1 = clipSpan(0, 128, 0, 0, step_frames, 0, 48, 0, 0, 1.0, 1.0, eng_frames).?;
    try std.testing.expectEqual(@as(usize, 0), s1.w0);
    try std.testing.expectEqual(@as(usize, 128), s1.w1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), s1.pos0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s1.step, 1e-9);

    // 段 2：[128,256)——**段内相对**（旧实现这里越界 + 重复播放 → 噼啪声）
    const s2 = clipSpan(128, 128, 0, 0, step_frames, 0, 48, 0, 0, 1.0, 1.0, eng_frames).?;
    try std.testing.expectEqual(@as(usize, 0), s2.w0);
    try std.testing.expectEqual(@as(usize, 128), s2.w1);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0), s2.pos0, 1e-9); // 续上、不重复

    // 片段只到 1900 帧 → 段 [1792,1920) 只写 [0,108)
    const s3 = clipSpan(1792, 128, 0, 0, step_frames, 0, 19, 0, 0, 1.0, 1.0, eng_frames).?;
    try std.testing.expectEqual(@as(usize, 108), s3.w1);

    // 段与片段完全无交集
    try std.testing.expect(clipSpan(5000, 128, 0, 0, step_frames, 0, 48, 0, 0, 1.0, 1.0, eng_frames) == null);

    // 采样率不同（24k 素材 @48k 引擎）：段 2 采样内起点 = 64、步长 = 0.5
    const s4 = clipSpan(128, 128, 0, 0, step_frames, 0, 48, 0, 0, 1.0, 0.5, 4800).?;
    try std.testing.expectApproxEqAbs(@as(f64, 64.0), s4.pos0, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), s4.step, 1e-9);

    // 速度 2×：每输出帧前进 2 个采样帧
    const s5 = clipSpan(0, 64, 0, 0, step_frames, 0, 48, 0, 0, 2.0, 1.0, eng_frames).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), s5.step, 1e-9);
}

test "audio: SampleData 取样——s16/f32 × 单声道/立体声 + 插值与 clamp" {
    // 立体声 s16：2 帧 → (0, 0.5), (1.0, -1.0)
    const st = [_]i16{ 0, 16384, 32767, -32768 };
    const d = SampleData{ .frames = .{ .s16 = &st }, .channels = 2, .frame_count = 2 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), d.frameAt(0)[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), d.frameAt(0)[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.frameAt(1)[0], 1e-4);
    const mid = d.sampleStereoAt(0.5); // 线性插值
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid[0], 1e-3);

    // 单声道 s16：双臂共用（回归：“单耳”/“音量减半”）
    const mono = [_]i16{ -16384, 16384 };
    const m = SampleData{ .frames = .{ .s16 = &mono }, .channels = 1, .frame_count = 2 };
    const mf = m.frameAt(0);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), mf[0], 1e-6);
    try std.testing.expectEqual(mf[0], mf[1]);

    // 立体声 f32：越界 clamp 到末帧
    const ff = [_]f32{ 0.25, -0.25 };
    const f = SampleData{ .frames = .{ .f32 = &ff }, .channels = 2, .frame_count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), f.frameAt(0)[0], 1e-6);
    const clamped = f.sampleStereoAt(99.0);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), clamped[1], 1e-6);
}

test "audio: 鼓组采样器层——触发后能发声，trim 到点自动收声" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);

    // 采样夹具：立体声交错、前 200 帧恒为 0.5，其余 0（便于断言“有声/静音”）
    const nframes: usize = 1000;
    const frames = try alloc.alloc(f32, nframes * 2);
    defer alloc.free(frames);
    for (frames, 0..) |*s, k| s.* = if (k / 2 < 200) 0.5 else 0.0;
    var data = SampleData{ .frames = .{ .f32 = frames }, .frame_count = nframes, .ratio = 1.0 };

    // 采样器声部池（对应 App.ensureKitSampler）
    const kss = try alloc.create(KitSamplerState);
    kss.* = .{};
    env.engine.kit_sampler[0].store(kss, .monotonic);
    defer {
        env.engine.kit_sampler[0].store(null, .monotonic);
        alloc.destroy(kss);
    }

    // 层 0 = 采样器层，音高 36，trim = 全段
    env.params.instrument_kind[0].store(1, .monotonic);
    env.params.kit_layer_count[0].store(1, .monotonic);
    env.params.kit_layer_pitch[0][0].store(36, .monotonic);
    env.params.kit_layer_gain[0][0].store(1.0, .monotonic);
    env.params.kit_layer_asset[0][0].store(&data, .release);
    env.params.kit_layer_trim_start[0][0].store(0, .monotonic);
    env.params.kit_layer_trim_len[0][0].store(0, .monotonic); // 0 = 到末尾
    env.params.kit_layer_speed[0][0].store(1.0, .monotonic);
    env.params.kit_layer_kind[0][0].store(3, .monotonic);

    // 触发 → 声部激活
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 36, .instrument = 0 });
    try std.testing.expect(kss.layers[0].voices[0].active);

    // 混一块 100 帧：应听到非零（0.5 × 力度 × 声像）
    var buf: [200]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &buf, buf.len, 0, 0, 1.0, 1.0);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.3);

    // 继续推进到 200 帧之后（恒定段结束）→ 输出归零；推到 1000 帧 → 声部收声
    var buf2: [200]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &buf2, buf2.len, 0, 0, 1.0, 1.0);
    var peak2: f32 = 0;
    for (buf2) |s| peak2 = @max(peak2, @abs(s));
    try std.testing.expect(peak2 > 0.3); // 这块覆盖 100..200 帧，仍在恒定段
    var tail: [200]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &tail, tail.len, 0, 0, 1.0, 1.0);
    var peak3: f32 = 0;
    for (tail) |s| peak3 = @max(peak3, @abs(s));
    try std.testing.expect(peak3 == 0.0); // 300..400 帧都是静音样本
    var buf3: [1600 * 2]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &buf3, buf3.len, 0, 0, 1.0, 1.0);
    try std.testing.expect(!kss.layers[0].voices[0].active); // 播放到底 → 自动收声

    // trim 起点：从 500 帧开始且长 100 → 只在该区间出声
    env.params.kit_layer_trim_start[0][0].store(500, .monotonic);
    env.params.kit_layer_trim_len[0][0].store(500, .monotonic); // 500..1000（上半段静音）
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 36, .instrument = 0 });
    var tbuf: [200 * 2]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &tbuf, tbuf.len, 0, 0, 1.0, 1.0);
    // 500..600 帧是静音样本 → 这块应全零；但声部仍应活着（还没到 end）
    var tpeak: f32 = 0;
    for (tbuf) |s| tpeak = @max(tpeak, @abs(s));
    try std.testing.expectEqual(@as(f32, 0.0), tpeak);
    try std.testing.expect(kss.layers[0].voices[0].active);
}

test "audio: 鼓组采样器层——声像居中时左右声道都响（回归：只有右耳）" {
    const alloc = std.testing.allocator;
    var env: KitTestEnv = undefined;
    try env.init(alloc, false);
    defer env.deinit(alloc);

    const nframes: usize = 64;
    const frames = try alloc.alloc(f32, nframes * 2);
    defer alloc.free(frames);
    for (frames) |*s| s.* = 0.5;
    var data = SampleData{ .frames = .{ .f32 = frames }, .frame_count = nframes, .ratio = 1.0 };

    const kss = try alloc.create(KitSamplerState);
    kss.* = .{};
    env.engine.kit_sampler[0].store(kss, .monotonic);
    defer {
        env.engine.kit_sampler[0].store(null, .monotonic);
        alloc.destroy(kss);
    }

    env.params.instrument_kind[0].store(1, .monotonic);
    env.params.instrument_pan[0].store(0.5, .monotonic); // 乐器声像居中
    env.params.kit_layer_count[0].store(1, .monotonic);
    env.params.kit_layer_pitch[0][0].store(36, .monotonic);
    env.params.kit_layer_gain[0][0].store(1.0, .monotonic);
    env.params.kit_layer_asset[0][0].store(&data, .release);
    env.params.kit_layer_trim_start[0][0].store(0, .monotonic);
    env.params.kit_layer_trim_len[0][0].store(0, .monotonic);
    env.params.kit_layer_speed[0][0].store(1.0, .monotonic);
    env.params.kit_layer_kind[0][0].store(3, .monotonic);

    // 音符级声像 64 = 居中 → 左右都应出声
    dispatchNote(&env.engine, synth.NoteEvent{ .kind = .on, .pitch = 36, .instrument = 0, .pan = 64 });
    var buf: [32 * 2]f32 = @splat(0);
    mixKitSamplerLayer(&env.engine, &env.params, &buf, buf.len, 0, 0, 1.0, 1.0);
    var pl: f32 = 0;
    var pr: f32 = 0;
    var k: usize = 0;
    while (k < buf.len) : (k += 2) {
        pl = @max(pl, @abs(buf[k]));
        pr = @max(pr, @abs(buf[k + 1]));
    }
    try std.testing.expect(pl > 0.3); // 回归：曾经左声道恒 0（pan 单位错）
    try std.testing.expect(pr > 0.3);
    try std.testing.expectApproxEqAbs(pl, pr, 0.02); // 居中 → 两侧等功率
}
