//! 工程保存/加载：把 App 的文档数据序列化为 JSON 文件（`.saw`）。
//!
//! **设计**：
//! - 磁盘格式与运行时模型**解耦**（`SynthParams` 等含原子字段，不能直接序列化）；
//! - 只保留**二进制**一种存档（JSON 可读通道已于 v9 删除）；
//! - 纯逻辑（序列化/反序列化内存 ↔ 存档结构体）可单测；文件 IO 在 main 接线。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");

/// **存档版本**（二进制；**只剩这一条线**——JSON 通道已在 v9 删除）。
///
/// 版本历史：
/// - v5：首版二进制（`f4a7960`）；
/// - v6：鼓组 VST3 层 / 音频片段 / 音频样式；
/// - v7：`Project.instrument_order`（乐器显示顺序）；
/// - v8：音符·片段静音 `muted`；
/// - **v9**（**已发布，格式冻结**）：自动化整套 + `SavedBinding.smooth_ms/invert/param_id`
///   + `SavedInstrument/SavedMixerChannel.uid` + 时间分辨率 U 96→3840（步域 ×40）
///   + **清格式**（删掉 `removed_fields` 那张表里的字段）。
///   **v9 已随正式版发布在外** → 除非只做“新增字段”（登记 `introducedVersion = 9`，
///   旧档填默认值），否则**下次改格式必须抬到 v10**（并写 v9→v10 迁移）。
///
/// **不变量**：任何 `Saved*`/`Project` 字段增删/调序**必须**跟上：
/// 新增 → 登记 `introducedVersion`；删除 → 登记 `removed_fields`。
/// v5 事故：改布局没登记 → 旧工程加载错位 → `integer does not fit…` 崩溃。
pub const binary_version: u8 = 9;
/// v5（首版二进制，f4a7960）——兼容读取用
const binary_version_legacy: u8 = 5;
/// v6（鼓组 VST3 层 / 音频片段 / 音频样式字段）——引入版本**钉死为 6**，
/// 不随 `binary_version` 上调而漂移（否则 v6 存档会被误判为“缺字段”而错位）。
const binary_version_v6: u8 = 6;
/// v8（音符/片段静音 `muted`）——同理钉死。
/// **坑**：这里曾直接写 `binary_version`（“当前版本即引入版本”）——
/// 一旦把当前版本从 8 抬到 9，`muted` 的引入版本也跟着飘到 9，
/// 旧 v8 档会被判为“没有该字段”而跳过它 → **字节流错位**。
const binary_version_v8: u8 = 8;
/// **v9 引入的字段**（含自动化：曲线/绑定整个家族——v8 发布版根本没有这两个数组）。
const binary_version_v9: u8 = 9;

/// **同名但类型变过**的字段：旧档按 `old_T` 读，再转成当前类型。
///
/// 与 `introducedVersion`（新增）、`removed_fields`（删除）凑成三件套：
/// 字段的**存在性变**看那两张表，**类型/语义变**看这张表。
const ChangedField = struct {
    owner: []const u8,
    name: []const u8,
    old_T: type,
    /// 从这个版本开始是新类型（`ver < changed_in` 的档里是 `old_T`）
    changed_in: u8,
    /// **旧档的数值刻度**（默认 1 = 纯类型变更）：`旧值 = 新值 × legacy_scale`。
    /// 例：`SavedNote.pan` 旧档是 MIDI 0..127，新是 0..1 → scale = 127；
    /// 读旧档：`新 = convert(旧) / scale`，写旧布局测试：`旧 = convert(新 × scale)`（取整）。
    legacy_scale: f32 = 1.0,
};

const changed_fields = [_]ChangedField{
    // `Project.bpm`：v5..v8 是 **i32**（整数 BPM）；v9 起改 f32（支持小数）。
    // **不登记 = 把旧档的 `bpm` 当 4 字节 f32 读 → 后面全错位**（本次排查就是它）。
    .{ .owner = "Project", .name = "bpm", .old_T = i32, .changed_in = binary_version_v9 },
    // `SavedNote.pan`：v5..v8 是 **i32 0..127**（MIDI 坐标）；v9 起改 f32 0..1（全项目一个声像域）。
    .{ .owner = "SavedNote", .name = "pan", .old_T = i32, .changed_in = binary_version_v9, .legacy_scale = 127.0 },
};

/// **已删除字段**：旧档里存在、当前结构体里已不存在。
///
/// 二进制是“按结构体字段顺序反射”，字段一旦删掉，旧档里那几个字节就没人消费 →
/// 后面全部错位。所以**删字段必须在这里登记**：读到 `ver < removed_in` 的档时
/// 按 `T` 类型**读掉丢弃**（写测试用的旧布局时对称地补写零值）。
const RemovedField = struct {
    /// 所属结构体（`@typeName` 后缀匹配）
    owner: []const u8,
    /// 旧字段名（**仅用于文档 + 绊线自检**：该名字必须已经不存在）
    name: []const u8,
    /// 插在**当前结构体的哪个字段之前**（空串 = 结构体末尾）
    before: []const u8,
    /// 旧字段类型（只用于“读掉/写零值”）
    T: type,
    /// 从这个版本开始**不再存在**（`ver < removed_in` 的档里有它）
    removed_in: u8,
};

const removed_fields = [_]RemovedField{
    // Project 原顺序：version → bpm → volume → time_num → time_den → steps_per_bar
    //              → pattern_count → … → legacy_units_per_bar → clips → …
    // 1) `version`：JSON 时代的“文件版本”（二进制头里已有真版本，冗余且混淆）
    .{ .owner = "Project", .name = "version", .before = "bpm", .T = u32, .removed_in = binary_version_v9 },
    // 2) `steps_per_bar`：由拍号推导，加载侧**从来不信它**（留着就是人为踩坑）
    .{ .owner = "Project", .name = "steps_per_bar", .before = "pattern_count", .T = i32, .removed_in = binary_version_v9 },
    // 3) `legacy_units_per_bar`：只有 JSON v1 迁移用过
    .{ .owner = "Project", .name = "legacy_units_per_bar", .before = "clips", .T = i32, .removed_in = binary_version_v9 },
    // 4) SavedClip 末尾的 v1 兼容字段（`bar` / `len_bars`，两个 `?i32`）
    .{ .owner = "SavedClip", .name = "bar", .before = "", .T = ?i32, .removed_in = binary_version_v9 },
    .{ .owner = "SavedClip", .name = "len_bars", .before = "", .T = ?i32, .removed_in = binary_version_v9 },
    // 5) SavedLane.curve_kind：占位常量（恒 1，无用）
    .{ .owner = "SavedLane", .name = "curve_kind", .before = "points", .T = u8, .removed_in = binary_version_v9 },
};

/// 默认文件名
pub const default_file_name: []const u8 = "project.saw";

/// ── 序列化策略（Z+ 决定，见 docs/save-format.md）──
/// 省默认**仅限** SavedNote 的四个字段（高基数实体；机制见其 jsonStringify）；
/// 其余结构一律反射全写——低频实体收益小、维护面大，且与未来破坏性更新冲突。
/// （历史上曾全结构省默认 + 3 位小数，已按上述决定回退。）

// ── 冻结格式常量（**永不追随运行时默认的改动**；改值 = 破坏性格式变更）──
// 语义：省略字段的“本义”与缺字段回填共用这些值——属格式规范的一部分。
// 绊线：下方「冻结默认值」测试；完整表见 docs/save-format.md《默认值冻结表》。
/// 音符力度缺省（与 model.default_velocity 解耦：后者可随产品改动，本值不可）
pub const note_default_velocity: i32 = 100;
/// 音符声像缺省（同上，与 model.default_pan 解耦；v9 起 = **0.5 居中**）
pub const note_default_pan: f32 = 0.5;
/// 样式数量缺省（旧档无 pattern_names 且缺 pattern_count 时的重建依据）
pub const pattern_count_default: i32 = 6;

/// 存档中的片段（与 `model.Clip` 同构，独立定义以保证磁盘格式稳定）
/// 坐标单位：步（U=96；96 = 4/4 一小节）。
pub const SavedClip = struct {
    track: i32,
    /// 起始步（全局坐标，0 起）——v2 起使用；有默认值以兼容 v1（缺失即 0）
    start: i32 = 0,
    /// 长度（步）
    len: i32 = 0,
    pattern: i32,
    /// 左缘对应的局部步
    offset: i32 = 0,
    /// **音频片段**：音频样式序号（-1 = 样式片段）
    audio_style: i32 = -1,
    /// 音频片段：采样内起点（帧）
    trim_start: i32 = 0,
    /// 音频片段：采样内长度（帧；<= 0 = 到素材末尾）
    trim_len: i32 = 0,
    /// 片段静音（v8；旧档缺失 → false）
    muted: bool = false,
};

/// 存档中的音符（坐标单位：步）
pub const SavedNote = struct {
    step: i32,
    len: i32,
    pitch: i32,
    pattern: i32 = 0,
    instrument: i32 = 0,
    /// 力度（1-127；缺省 = `note_default_velocity`，冻结格式常量）
    velocity: i32 = note_default_velocity,
    /// 声像（**0..1**，0.5 = 居中；v5–v8 旧档是 i32 0..127，见 `changed_fields`）
    pan: f32 = note_default_pan,
    /// 音符静音（v8；旧档缺失 → false）
    muted: bool = false,
};

/// **自动化曲线的锚点**（`step/value` 是世界坐标，pivot/curve 是手柄的几何位置）
pub const SavedLanePoint = struct {
    step: i32 = 0,
    value: f32 = 0,
    /// 手柄在两点之间的水平位置（0..1）
    pivot: f32 = 0.5,
    /// 手柄值 − 直连线值（已夹在两端值之间）
    curve: f32 = 0,
    /// 出生序号：同一步的多个点靠它定序（垂直断崖）
    seq: u32 = 0,
};

/// **自动化曲线**（一条 lane = 一条可被多条绑定引用的曲线）
pub const SavedLane = struct {
    id: u32 = 0,
    /// 曲线名（堆分配；空 = 用默认名“曲线N”）
    name: []const u8 = "",
    /// 0 = hold / 1 = linear / 2 = smooth
    interp: u8 = 2,
    /// 行头列显示单位（只影响 UI）
    display_unit: u8 = 0,
    points: []SavedLanePoint = &.{},
};

/// **自动化绑定**：曲线 → 参数（同一条曲线可绑多个目标）
pub const SavedBinding = struct {
    curve_id: u32 = 0,
    /// `view_lane.Target.Kind` 的序号
    target_kind: u8 = 0,
    target_uid: u32 = 0,
    /// **v3（v9 内）**：`fx_param` / `kit_param` 的子对象 uid（效果槽 / 鼓组层）
    target_slot: u32 = 0,
    /// 叠加深度
    depth: f32 = 1.0,
    /// 基准值（`null` = 用目标类型默认值）；JSON 里用哨兵 -1 表示 null
    base: f32 = -1.0,
    bipolar: bool = false,
    enabled: bool = true,
    /// **反向**（与 `bipolar` 独立；v9 引入）：贡献取负
    invert: bool = false,
    /// **`vst_param` 专用**：VST3 参数 ID（其他 target 恒 0）
    param_id: u32 = 0,
    /// **极点追赶的平滑时间常数**（毫秒；0 = 不平滑）
    /// v9 未发布 → 默认值直接定成 0（与 `view_lane.default_smooth_ms` 一致），无迁移义务
    smooth_ms: f32 = 0.0,
};

/// 存档中的振荡器（原子字段 → 普通值）
pub const SavedOsc = struct {
    enabled: bool = false,
    volume: f32 = 0.5,
    waveform: u8 = 0,
    /// 合奏副本总数 1-16（1 = 无合奏；缺字段的旧存档 → 1）
    unison: u32 = 1,
    /// 合奏音高散布 0-1（缺字段的旧存档 → 0.05 = 5%）
    unison_detune: f32 = 0.05,
    /// 散布位置功率 -5..5（缺字段 → 0 = 线性）
    detune_power: f32 = 0,
};

/// 存档中的滤波器
pub const SavedFilter = struct {
    enabled: bool = false,
    cutoff: f32 = 0.7,
};

/// 存档中的合成器参数
pub const SavedSynth = struct {
    osc: [synth.osc_count]SavedOsc = .{ .{}, .{}, .{}, .{} },
    attack: f32 = 0.05,
    decay: f32 = 0.30,
    sustain: f32 = 0.70,
    release: f32 = 0.30,
    hpf: SavedFilter = .{},
    lpf: SavedFilter = .{},
};

/// 存档中的鼓组层（每垫一份内嵌合成器参数；见 `docs/drumkit.md` §8）
pub const SavedDrumLayer = struct {
    /// **稳定 uid**（v9：鼓组层参数自动化按它引用层）
    uid: u32 = 0,
    /// 乐器类型（0 = 减法合成器 / 2 = VST3；旧存档缺失 → 0）
    kind: u32 = 0,
    synth: SavedSynth = .{},
    /// 层内增益（多层叠加的配比）
    gain: f32 = 1.0,
    /// 来源预设名（`分类/名字`；展示用，空 = 手调/空层）
    source_preset: []const u8 = "",
    // ── VST3 层（kind == 2；字段/惯例同 `SavedInstrument` 插件段）──
    /// 插件路径（空 = 非插件层/未定位）
    plugin_path: []const u8 = "",
    /// 插件类 CID（32 hex；空 = 未知）——重绑定自愈的匹配身份
    plugin_cid: []const u8 = "",
    /// 音色状态（base64 文本；组件/控制器各一份；空 = 无）
    plugin_state: []const u8 = "",
    plugin_state_ctrl: []const u8 = "",
    // ── 采样器层（kind == 3；路径按相对工程目录存）──
    /// 采样源文件（相对路径）
    asset_path: []const u8 = "",
    /// 采样内起点/长度（帧）
    trim_start: i32 = 0,
    trim_len: i32 = 0,
    /// 播放速度（1 = 原速）
    speed: f32 = 1.0,
};

/// 存档中的**音频样式**（与音符样式对称：共享内容 = 通道/增益；片段引用样式序号）
pub const SavedAudioStyle = struct {
    /// 名称（默认 = 文件名；用户信息）
    name: []const u8 = "",
    /// 源文件（**相对工程目录**的路径；空 = 无源）
    path: []const u8 = "",
    /// 混音通道（0 起）
    channel: i32 = 0,
    /// 样式增益（0..2；1 = 原电平）
    gain: f32 = 1.0,
    /// 播放速度（1 = 原速；变速变调）
    speed: f32 = 1.0,
};

/// 存档中的鼓垫（一个音高 + 名字 + 层列表）
pub const SavedDrumPad = struct {
    pitch: u32 = 0,
    /// 自定义名（空 = 用 GM 标准名/音名）
    name: []const u8 = "",
    layers: []SavedDrumLayer = &.{},
};

/// 存档中的鼓组
pub const SavedDrumKit = struct {
    pads: []SavedDrumPad = &.{},
};

/// 存档中的乐器
pub const SavedInstrument = struct {
    /// **稳定 uid**（v9 引入；自动化绑定按它引用乐器）。0 = 旧存档/未分配
    uid: u32 = 0,
    name: []const u8 = "",
    /// 推子位置（0..1；**0 dB 在 0.75**，顶部 = +5 dB——见 audio.faderGain）
    volume: f32 = 0.75,
    pan: f32 = 0.5,
    muted: bool = false,
    /// 混音通道（**0 起**；v3 起。v1/v2 存档是 1 起——加载时减 1）
    mixer: i32 = 0,
    /// MIDI 通道（0-15；-1 = 无；旧存档缺失 → -1）
    midi_channel: i32 = -1,
    /// 乐器类型（0 = synth / 1 = drumkit / 2 = VST3；旧存档缺失 → 0）
    kind: u32 = 0,
    /// 键盘列模式（0 = 钢琴/1 = 鼓组；每乐器独立；旧存档缺失 → 0）
    key_mode: u32 = 0,
    /// 关联预设名（最近加载/保存的预设；展示/保存预填用；空 = 无）
    preset_name: []const u8 = "",
    /// VST3 乐器插件路径（kind == 2 时有效；空 = 非插件乐器）
    plugin_path: []const u8 = "",
    /// VST3 乐器**音色状态**（base64 文本；空 = 无/未捕获）。组件状态与控制器状态各一份。
    plugin_state: []const u8 = "",
    plugin_state_ctrl: []const u8 = "",
    /// 插件类 CID（32 hex；空 = 未知）——重绑定自愈的匹配身份
    plugin_cid: []const u8 = "",
    /// 鼓组数据（`kind == 1` 时有效；空 = 无）
    kit: SavedDrumKit = .{},
    /// 合成器参数（减法合成器使用；鼓组类型的“本体”不使用）
    synth: SavedSynth = .{},
};

/// 完整工程存档
/// 存档中的一段 EQ
pub const SavedEqBand = struct {
    freq: f32 = 1000,
    gain_db: f32 = 0,
    q: f32 = 1.0,
};

/// 存档中的一个效果器（`kind`：1 = EQ / 2 = 混响 / 3 = 延迟 / 4 = 压缩器；0 = 无效）
pub const SavedEffectSlot = struct {
    /// **稳定 uid**（v9：效果器参数自动化按它引用槽位）
    uid: u32 = 0,
    kind: u32 = 0, // 与 app.EffectKind 对应；0 = 无效
    enabled: bool = true,
    /// 干湿比（0 = 干声、1 = 完全效果）
    mix: f32 = 1.0,
    /// EQ 段（**只读切片**：兼容旧存档的 4 段；加载时按需截断/补齐）
    bands: []const SavedEqBand = &.{},
    /// 通用参数位（混响/延迟/压缩器；含义见 `effects.paramInfos`；旧档缺失 → 全 0）
    p: [5]f32 = .{ 0, 0, 0, 0, 0 },
    /// VST3 插件路径（kind = 5；旧档缺失 → 空）
    plugin_path: []const u8 = "",
    /// VST3 插件状态（**base64 文本**；空 = 无/未捕获）。组件状态与控制器状态各一份。
    plugin_state: []const u8 = "",
    plugin_state_ctrl: []const u8 = "",
    /// 插件类 CID（32 hex；空 = 未知）——重绑定自愈的匹配身份
    plugin_cid: []const u8 = "",
};

/// 存档中的一个调音台通道
pub const SavedMixerChannel = struct {
    /// **稳定 uid**（v9 引入；自动化绑定按它引用通道）。0 = 旧存档/未分配
    uid: u32 = 0,
    /// 自定义名字（UTF-8；空 = 无自定义名——用默认占位名）
    name: []const u8 = "",
    /// 推子位置（0..1；**0 dB 在 0.75**，顶部 = +5 dB——见 audio.faderGain）
    volume: f32 = 0.75,
    pan: f32 = 0.5,
    muted: bool = false,
    /// 有效效果器数（0 = 旧存档：按 kind != 0 推断）
    effect_count: u32 = 0,
    /// 效果器链（**动态长度**：导出时按实际槽数分配，至多 `app.max_effects_per_channel`；
    /// 旧存档为固定 4 槽数组——切片解析天然兼容）
    effects: []const SavedEffectSlot = &.{},
};

pub const Project = struct {
    bpm: f32 = 120,
    /// 主音量（0-1；旧存档缺失 → 默认 0.75，与 App.volume 一致）
    volume: f32 = 0.75,
    time_num: i32 = 4,
    time_den: i32 = 4,
    /// 样式数量（旧存档缺失 → `pattern_count_default`；仅当 `pattern_names` 为空时用于重建）
    pattern_count: i32 = pattern_count_default,
    /// 样式名字（UTF-8；空 = 旧存档/无自定义名——加载时按 `pattern_count` 重建默认名）
    pattern_names: []const []const u8 = &.{},
    /// 轨道自定义名（**v4：稀疏对**——只含命名行；与 `track_name_rows` 同长、升序。
    /// 默认名 "Track N" 与行跨度都是位置推导、不入档。旧档（v3 及以前）此数组为
    /// 密集（空串占位）——加载侧垫片按“跳过空串”派生行号）。
    track_names: []const []const u8 = &.{},
    /// 命名行的行号（与 `track_names` 配对；v4 起；旧档无此字段）
    track_name_rows: []const i32 = &.{},
    /// 静音轨道（**排序行号列表**；空 = 无静音）——旧存档无此字段 → 全部未静音
    track_muted: []const i32 = &.{},
    clips: []SavedClip = &.{},
    notes: []SavedNote = &.{},
    /// 音频样式（引用文件按相对工程目录的路径；片段经 `SavedClip.audio_style` 引用）
    audio_styles: []SavedAudioStyle = &.{},
    instruments: []SavedInstrument = &.{},
    /// 乐器**显示顺序**（显示第 i 行 → 物理槽位 `order[i]`；空/缺失 = 按 0..n 顺序）。
    /// 物理槽位是音符引用与音频同步的身份，上下移只改本数组（不动音符）。
    instrument_order: []u32 = &.{},
    /// 调音台通道（旧存档缺失 → 全默认 8 通道；加载时长度不匹配则重置）
    mixer: []SavedMixerChannel = &.{},
    /// **自动化曲线**（每条点列表内联）与绑定；`auto_sel` = 当前选中的曲线 id
    auto_lanes: []SavedLane = &.{},
    auto_bindings: []SavedBinding = &.{},
    auto_sel: u32 = 0,
};

/// 从合成器参数导出存档结构（读原子 → 普通值）
pub fn exportSynth(p: *const synth.SynthParams) SavedSynth {
    var s = SavedSynth{
        .attack = p.attack.load(.monotonic),
        .decay = p.decay.load(.monotonic),
        .sustain = p.sustain.load(.monotonic),
        .release = p.release.load(.monotonic),
        .hpf = .{ .enabled = p.hpf.enabled.load(.monotonic), .cutoff = p.hpf.cutoff.load(.monotonic) },
        .lpf = .{ .enabled = p.lpf.enabled.load(.monotonic), .cutoff = p.lpf.cutoff.load(.monotonic) },
    };
    for (0..synth.osc_count) |i| {
        s.osc[i] = .{
            .enabled = p.osc[i].enabled.load(.monotonic),
            .volume = p.osc[i].volume.load(.monotonic),
            .waveform = p.osc[i].waveform.load(.monotonic),
            .unison = p.osc[i].unison.load(.monotonic),
            .unison_detune = p.osc[i].unison_detune.load(.monotonic),
            .detune_power = p.osc[i].detune_power.load(.monotonic),
        };
    }
    return s;
}

/// 把存档结构写回合成器参数（普通值 → 原子）
pub fn importSynth(s: *const SavedSynth, p: *synth.SynthParams) void {
    p.attack.store(s.attack, .monotonic);
    p.decay.store(s.decay, .monotonic);
    p.sustain.store(s.sustain, .monotonic);
    p.release.store(s.release, .monotonic);
    p.hpf.enabled.store(s.hpf.enabled, .monotonic);
    p.hpf.cutoff.store(s.hpf.cutoff, .monotonic);
    p.lpf.enabled.store(s.lpf.enabled, .monotonic);
    p.lpf.cutoff.store(s.lpf.cutoff, .monotonic);
    for (0..synth.osc_count) |i| {
        p.osc[i].enabled.store(s.osc[i].enabled, .monotonic);
        p.osc[i].volume.store(s.osc[i].volume, .monotonic);
        p.osc[i].waveform.store(s.osc[i].waveform, .monotonic);
        p.osc[i].unison.store(@min(@max(s.osc[i].unison, 1), @as(u32, synth.max_unison)), .monotonic);
        p.osc[i].unison_detune.store(std.math.clamp(s.osc[i].unison_detune, 0, 1), .monotonic);
        p.osc[i].detune_power.store(std.math.clamp(s.osc[i].detune_power, -5, 5), .monotonic);
    }
}

/// 应用设置（数据目录下 `settings.json`；缺失/损坏 → 默认值）。
/// **所有用户可见的设置都在这里**（早期散在 `audio.txt` / `font.txt`，已废弃）。
pub const Settings = struct {
    /// 启动时打开上次工程（false = 新建空工程）
    open_last: bool = false,
    /// 最高帧率（30..240）
    fps: i32 = 120,
    /// 上次打开/保存的工程路径（仅落盘；运行时真身在 `App.project_path`）
    last_project: []const u8 = "",
    /// **UI 缩放**：true = 每次启动自动检测（阶梯见 `src/dpi.zig`）；false = 用 `ui_scale`
    ui_scale_auto: bool = true,
    /// 固定缩放倍率（自动期间也保留着，取消自动就回到它）
    ui_scale: f32 = 1.0,
    /// 音频后端：0 自动 / 1 PulseAudio / 2 ALSA / 3 JACK（见 `audio_pref.Backend`）
    audio_backend: i32 = 0,
    /// 音频输出设备名（"" = 系统默认）
    audio_device: []const u8 = "",
    /// 自选字体文件路径（"" = 自动探测：fontconfig → 系统名单 → data/fonts/）
    font_path: []const u8 = "",
};

/// 设置 → JSON（归调用方释放）
pub fn settingsToJson(allocator: std.mem.Allocator, s: Settings) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.write(s);
    return out.toOwnedSlice();
}

/// JSON → 设置（自包含；`parsed` 释放前拷出 `last_project`）
pub fn settingsFromJson(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Settings) {
    return std.json.parseFromSlice(Settings, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "persist: 设置 JSON 往返（含路径转义；未知字段忽略、缺字段补齐）" {
    const allocator = std.testing.allocator;
    const json = try settingsToJson(allocator, .{
        .open_last = true,
        .fps = 90,
        .last_project = "C:\\Music\\曲.saw",
        .ui_scale_auto = false,
        .ui_scale = 1.5,
        .audio_backend = 2,
        .audio_device = "USB Audio",
        .font_path = "C:\\Fonts\\mi.ttf",
    });
    defer allocator.free(json);
    var parsed = try settingsFromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.open_last);
    try std.testing.expectEqual(@as(i32, 90), parsed.value.fps);
    try std.testing.expectEqualStrings("C:\\Music\\曲.saw", parsed.value.last_project);
    try std.testing.expect(!parsed.value.ui_scale_auto);
    try std.testing.expectEqual(@as(f32, 1.5), parsed.value.ui_scale);
    try std.testing.expectEqual(@as(i32, 2), parsed.value.audio_backend);
    try std.testing.expectEqualStrings("USB Audio", parsed.value.audio_device);
    try std.testing.expectEqualStrings("C:\\Fonts\\mi.ttf", parsed.value.font_path);

    // 未知字段忽略；缺字段 → 默认值（老 settings.json 照旧能读）
    var parsed2 = try settingsFromJson(allocator, "{\"fps\":60,\"future\":123}");
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(i32, 60), parsed2.value.fps);
    try std.testing.expect(parsed2.value.ui_scale_auto);
    try std.testing.expectEqual(@as(f32, 1.0), parsed2.value.ui_scale);
    try std.testing.expectEqual(@as(i32, 0), parsed2.value.audio_backend);
    try std.testing.expectEqualStrings("", parsed2.value.font_path);
    try std.testing.expect(!parsed2.value.open_last);
    try std.testing.expectEqualStrings("", parsed2.value.last_project);
}

// ── 二进制格式（**唯一存档格式**）──
//
// 布局：magic "SAWD" + u8 版本（当前 9）+ 载荷。载荷 = **comptime 反射编码**（全量字段，
// 零逐结构维护；不做任何省略——省默认只在 JSON 时代有意义，现在磁盘体积已不是瓶颈）。
// 编码规则：
// - 整数：varint（有符号走 zigzag）；bool：1 字节；枚举：底层整数 varint；
// - f32：原始 4 字节（平台本机字节序——本项目仅 Windows x64，不做跨端承诺）；
// - 字符串/切片：varint 长度 + 内容；定长数组：逐元素；optional：1 字节 tag + 载荷；
// - **特殊字段**：`plugin_state` / `plugin_state_ctrl`（base64 文本）解码为**原始字节**
//   存储（省 25%）：tag 0 = 空、1 = raw、2 = 文本回退（非法 base64 原样存）。
// 读取严格：magic/版本校验 + 全量消费（尾部垃圾 = 错误——防截断/错位静默）。
pub const binary_magic = "SAWD";

/// 某字段**首次出现的存档版本**（未登记 = 从首版就有 → null）。
///
/// **纪律**：新增字段时在这里登记它的版本号（见 `docs/save-format.md`）。
/// 读取比该字段更早的存档时，`legacySkip` 会跳过它（保留声明默认值），
/// 否则会吞掉下一字段/下一元素的字节（v5 事故：`integer does not fit…` 崩溃）。
/// 按**结构体名 + 字段名**双重匹配（`plugin_path` 在 `SavedInstrument`
/// 里是 v5 之前就有的，不能误跳）。
/// 字段首次出现的存档版本（未登记 = 从 v5 起就一直存在）。
///
/// 每个类型**一个分支**，分支内列出它所有“新字段”——**分支里的清单必须完整**：
/// 漏登一个 v9 字段 → 读 v8 档时多读几个字节 → 整档错位报 `CorruptProject`。
/// （实测：`SavedDrumLayer.uid` 曾漏登，导致 V18 升级来的**带鼓组** 工程打不开；
/// 不带鼓组的工程看不见，因为该结构只在鼓组层里才被读到。）
/// 回归测试：`persist: 版本门控——v9 新字段在 v8 档里必须全部跳过`。
fn introducedVersion(comptime T: type, comptime name: []const u8) ?u8 {
    const tn = @typeName(T);
    if (comptime std.mem.endsWith(u8, tn, "SavedDrumLayer")) {
        // **稳定 uid（v9）**；层 VST3 + 采样器字段（v6）
        if (comptime std.mem.eql(u8, name, "uid")) return binary_version_v9;
        inline for (.{ "plugin_path", "plugin_cid", "plugin_state", "plugin_state_ctrl", "asset_path", "trim_start", "trim_len", "speed" }) |fn_name| {
            if (comptime std.mem.eql(u8, name, fn_name)) return binary_version_v6;
        }
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "SavedClip")) {
        // 音频片段字段——v6；静音——v8
        inline for (.{ "audio_style", "trim_start", "trim_len" }) |fn_name| {
            if (comptime std.mem.eql(u8, name, fn_name)) return binary_version_v6;
        }
        if (comptime std.mem.eql(u8, name, "muted")) return binary_version_v8;
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "SavedNote")) {
        // 静音——v8（旧档缺失 → false）
        if (comptime std.mem.eql(u8, name, "muted")) return binary_version_v8;
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "SavedBinding")) {
        // 极点平滑时间常数 / 反向 / 插件参数 ID / 子对象 uid——均为 v9
        if (comptime std.mem.eql(u8, name, "smooth_ms")) return binary_version_v9;
        if (comptime std.mem.eql(u8, name, "invert")) return binary_version_v9;
        if (comptime std.mem.eql(u8, name, "param_id")) return binary_version_v9;
        if (comptime std.mem.eql(u8, name, "target_slot")) return binary_version_v9;
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "SavedEffectSlot")) {
        // **稳定 uid**（v9）：效果槽的参数自动化按它引用（位置会因插入/删除而漂）
        if (comptime std.mem.eql(u8, name, "uid")) return binary_version_v9;
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "SavedInstrument") or std.mem.endsWith(u8, tn, "SavedMixerChannel")) {
        // **稳定 uid**（v9）：自动化绑定按 uid 引用目标。不落盘的话读档/撤销后
        // uid 会重新编号 → 绑定“表面在、实际失效”（实测：读档后绑定指向不存在的通道）。
        if (comptime std.mem.eql(u8, name, "uid")) return binary_version_v9;
        return null;
    }
    if (comptime std.mem.endsWith(u8, tn, "Project")) {
        // 音频样式：v6；乐器显示顺序：v7（旧档缺失 → 默认空 = 按槽位顺序）；
        // **自动化整套（曲线 + 绑定 + 选中 id）：v9**——v8 发布版没有这三个字段，
        // 不登记就会在旧档末尾“多读三个字段” → 字节流错位（与 v5 事故同型）。
        if (comptime std.mem.eql(u8, name, "audio_styles")) return binary_version_v6;
        if (comptime std.mem.eql(u8, name, "instrument_order")) return 7;
        if (comptime std.mem.eql(u8, name, "auto_lanes")) return binary_version_v9;
        if (comptime std.mem.eql(u8, name, "auto_bindings")) return binary_version_v9;
        if (comptime std.mem.eql(u8, name, "auto_sel")) return binary_version_v9;
        return null;
    }
    return null;
}

/// 读 `ver` 版本存档时，字段 `name` 是否应**跳过不读**（比它首次出现的版本更旧）。
fn legacySkip(ver: u8, comptime T: type, comptime name: []const u8) bool {
    // 注：不能写 `comptime introducedVersion(...) orelse return false`——`comptime`
    // 会把 `orelu return` 一起包进去，整句在 comptime 求值时又会因
    // “called at runtime cannot return value at comptime”报错（全 comptime 实参的
    // 调用会被直接 comptime 求值，测试里就撞上了）。
    const intro = comptime (introducedVersion(T, name) orelse 0);
    return intro != 0 and ver < intro;
}

/// 已删字段匹配：结构体相同且插在当前字段 `before` 之前
fn removedMatches(comptime T: type, comptime rf: RemovedField, comptime before: []const u8) bool {
    if (!std.mem.endsWith(u8, @typeName(T), rf.owner)) return false;
    return std.mem.eql(u8, rf.before, before);
}

/// `owner` 字符串 → 结构体类型（**只给自检测试用**；新登记一行忘加分支会 `@compileError`）
fn structByOwner(comptime owner: []const u8) type {
    if (comptime std.mem.eql(u8, owner, "Project")) return Project;
    if (comptime std.mem.eql(u8, owner, "SavedClip")) return SavedClip;
    if (comptime std.mem.eql(u8, owner, "SavedNote")) return SavedNote;
    if (comptime std.mem.eql(u8, owner, "SavedLane")) return SavedLane;
    if (comptime std.mem.eql(u8, owner, "SavedBinding")) return SavedBinding;
    if (comptime std.mem.eql(u8, owner, "SavedInstrument")) return SavedInstrument;
    if (comptime std.mem.eql(u8, owner, "SavedMixerChannel")) return SavedMixerChannel;
    if (comptime std.mem.eql(u8, owner, "SavedDrumLayer")) return SavedDrumLayer;
    if (comptime std.mem.eql(u8, owner, "SavedDrumPad")) return SavedDrumPad;
    if (comptime std.mem.eql(u8, owner, "SavedAudioStyle")) return SavedAudioStyle;
    @compileError("removed_fields/changed_fields：未知 owner " ++ owner);
}

/// 写端（**仅测试用旧布局**）：目标版本比 `removed_in` 旧 → 按旧布局补写占位值。
fn binWriteRemoved(comptime T: type, w: *BinWriter, comptime before: []const u8) !void {
    inline for (removed_fields) |rf| {
        if (comptime removedMatches(T, rf, before)) {
            if (w.version < rf.removed_in) try binWriteValue(rf.T, w, std.mem.zeroes(rf.T));
        }
    }
}

/// 读端：目标存档比 `removed_in` 旧 → 把已删字段**读掉丢弃**（否则后面全错位）。
fn binReadRemoved(comptime T: type, r: *BinReader, a: std.mem.Allocator, comptime before: []const u8) !void {
    inline for (removed_fields) |rf| {
        if (comptime removedMatches(T, rf, before)) {
            if (r.version < rf.removed_in) _ = try binReadValue(rf.T, r, a);
        }
    }
}

/// 该字段是否**曾用过旧类型**（返回那次变更的信息；版本比较由调用方做）
fn changedFieldInfo(comptime T: type, comptime name: []const u8) ?ChangedField {
    inline for (changed_fields) |cf| {
        if (comptime std.mem.endsWith(u8, @typeName(T), cf.owner) and std.mem.eql(u8, cf.name, name)) return cf;
    }
    return null;
}

/// 旧类型 → 当前类型（只支持数值互转）
fn convertLegacyTo(comptime T: type, v: anytype) T {
    const F = @TypeOf(v);
    return switch (comptime @typeInfo(F)) {
        .int => switch (comptime @typeInfo(T)) {
            .int => @intCast(v),
            .float => @floatFromInt(v),
            else => @compileError("bin: 旧字段只能转数值：" ++ nameOf(T)),
        },
        .float => switch (comptime @typeInfo(T)) {
            .float => @floatCast(v),
            .int => @intFromFloat(@round(v)), // 取整（非截断）：0.5×127 = 63.5 → 64
            else => @compileError("bin: 旧字段只能转数值：" ++ nameOf(T)),
        },
        else => @compileError("bin: 旧字段只能转数值：" ++ nameOf(F)),
    };
}

fn nameOf(comptime T: type) []const u8 {
    return @typeName(T);
}

const BinWriter = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// 目标格式版本（默认当前；`toBinaryLegacyV5` 写旧布局时改为旧版本）
    version: u8 = binary_version,

    fn put(self: *BinWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.a, bytes);
    }
    fn putByte(self: *BinWriter, b: u8) !void {
        try self.buf.append(self.a, b);
    }
    fn putVarint(self: *BinWriter, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try self.putByte(@intCast((x & 0x7F) | 0x80));
        try self.putByte(@intCast(x));
    }
};

const BinReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// 源存档版本（决定哪些字段需要跳过：见 `legacySkip`）
    version: u8 = binary_version,

    fn take(self: *BinReader, n: usize) ![]const u8 {
        if (n > self.data.len -| self.pos) return error.UnexpectedEndOfBinary;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn byte(self: *BinReader) !u8 {
        return (try self.take(1))[0];
    }
    fn varint(self: *BinReader) !u64 {
        var x: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            x |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return x;
            if (shift >= 56) return error.VarintOverflow;
            shift += 7;
        }
    }
};

fn isB64TextField(comptime name: []const u8, comptime T: type) bool {
    if (T != []const u8) return false;
    return std.mem.eql(u8, name, "plugin_state") or std.mem.eql(u8, name, "plugin_state_ctrl");
}

fn binWriteB64Field(w: *BinWriter, s: []const u8) !void {
    if (s.len == 0) {
        try w.putByte(0);
        return;
    }
    const dec = std.base64.standard.Decoder;
    if (dec.calcSizeForSlice(s)) |n| {
        const raw = try w.a.alloc(u8, n);
        defer w.a.free(raw);
        if (dec.decode(raw, s)) |_| {
            try w.putByte(1);
            try w.putVarint(raw.len);
            try w.put(raw);
            return;
        } else |_| {}
    } else |_| {}
    // 非法 base64：文本回退（原样存，保真）
    try w.putByte(2);
    try w.putVarint(s.len);
    try w.put(s);
}

fn binWriteValue(comptime T: type, w: *BinWriter, v: T) !void {
    switch (@typeInfo(T)) {
        .bool => try w.putByte(if (v) 1 else 0),
        .int => |info| {
            if (info.signedness == .signed) {
                const x: i64 = @intCast(v);
                try w.putVarint(@bitCast((x *% 2) ^ (x >> 63)));
            } else {
                try w.putVarint(@intCast(v));
            }
        },
        .float => |f| {
            if (f.bits != 32) @compileError("bin: only f32 floats supported");
            try w.put(std.mem.asBytes(&v));
        },
        .optional => |o| {
            if (v) |x| {
                try w.putByte(1);
                try binWriteValue(o.child, w, x);
            } else {
                try w.putByte(0);
            }
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("bin: only slice pointers supported");
            try w.putVarint(v.len);
            for (v) |e| try binWriteValue(p.child, w, e);
        },
        .array => |arr| {
            for (v) |e| try binWriteValue(arr.child, w, e);
        },
        .@"enum" => try w.putVarint(@backingInt(v)),
        .@"struct" => |s| {
            // 0.17：`@typeInfo` 改为数组结构体风格（field_names / field_types / field_attrs）
            inline for (s.field_names, s.field_types) |fname, FType| {
                try binWriteRemoved(T, w, fname);
                if (comptime introducedVersion(T, fname) != null) {
                    if (!legacySkip(w.version, T, fname)) { // 目标版本更旧 → 不写该字段
                        if (comptime isB64TextField(fname, FType)) {
                            try binWriteB64Field(w, @field(v, fname));
                        } else {
                            try binWriteValue(FType, w, @field(v, fname));
                        }
                    }
                } else if (comptime isB64TextField(fname, FType)) {
                    try binWriteB64Field(w, @field(v, fname));
                } else if (comptime changedFieldInfo(T, fname)) |cf| {
                    // 旧档写**旧类型**（如 `bpm` 旧档是 i32、`pan` 旧档是 0..127）
                    if (w.version < cf.changed_in) {
                        try binWriteValue(cf.old_T, w, convertLegacyTo(cf.old_T, @field(v, fname) * cf.legacy_scale));
                    } else {
                        try binWriteValue(FType, w, @field(v, fname));
                    }
                } else {
                    try binWriteValue(FType, w, @field(v, fname));
                }
            }
            try binWriteRemoved(T, w, ""); // 结构体末尾的已删字段
        },
        else => @compileError("bin: unsupported type " ++ @typeName(T)),
    }
}

fn binReadB64Field(r: *BinReader, a: std.mem.Allocator) ![]const u8 {
    switch (try r.byte()) {
        0 => return "",
        1 => {
            const n: usize = @intCast(try r.varint());
            const raw = try r.take(n);
            const enc = std.base64.standard.Encoder;
            const out = try a.alloc(u8, enc.calcSize(n));
            _ = enc.encode(out, raw);
            return out;
        },
        else => {
            const n: usize = @intCast(try r.varint());
            return try a.dupe(u8, try r.take(n));
        },
    }
}

fn binReadValue(comptime T: type, r: *BinReader, a: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .bool => return (try r.byte()) != 0,
        .int => |info| {
            const uv = try r.varint();
            // 溢出 = 字节流已错位（通常为读写不对称或文件损坏）→ 友好报错，
            // 不用 `@intCast`（那会 panic："integer does not fit in destination type"）
            if (info.signedness == .signed) {
                const zz: i64 = @bitCast(uv);
                const x: i64 = (zz >> 1) ^ -(zz & 1);
                return std.math.cast(T, x) orelse error.CorruptProject;
            }
            return std.math.cast(T, uv) orelse error.CorruptProject;
        },
        .float => |f| {
            if (f.bits != 32) @compileError("bin: only f32 floats supported");
            const b = try r.take(4);
            return @bitCast(b[0..4].*);
        },
        .optional => |o| {
            if ((try r.byte()) != 0) return try binReadValue(o.child, r, a);
            return null;
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("bin: only slice pointers supported");
            const n: usize = @intCast(try r.varint());
            const out = try a.alloc(p.child, n);
            for (out) |*e| e.* = try binReadValue(p.child, r, a);
            return out;
        },
        .array => |arr| {
            var out: T = undefined;
            for (&out) |*e| e.* = try binReadValue(arr.child, r, a);
            return out;
        },
        .@"enum" => return @fromBackingInt(std.math.cast(@typeInfo(T).@"enum".tag_type orelse u32, try r.varint()) orelse error.CorruptProject),
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, FType, attrs| {
                try binReadRemoved(T, r, a, fname);
                if (comptime introducedVersion(T, fname) != null) {
                    if (legacySkip(r.version, T, fname)) {
                        // 旧版本没有该字段 → 用声明默认值（0.17：默认值挂在 field_attrs 上）
                        @field(out, fname) = attrs.defaultValue(FType) orelse @compileError("legacy v5 跳过字段必须有默认值：" ++ fname);
                    } else if (comptime isB64TextField(fname, FType)) {
                        // **必须和写入端一致**：版本门控字段里也有 plugin_state/plugin_state_ctrl，
                        // 写端走 b64、读端若当普通字符串 → 整条流错位（实测：含 VST3 鼓组层的工程打不开，
                        // 报 “integer does not fit in destination type”）。
                        @field(out, fname) = try binReadB64Field(r, a);
                    } else {
                        @field(out, fname) = try binReadValue(FType, r, a);
                    }
                } else if (comptime isB64TextField(fname, FType)) {
                    @field(out, fname) = try binReadB64Field(r, a);
                } else if (comptime changedFieldInfo(T, fname)) |cf| {
                    // 旧档里是旧类型（`bpm` 旧档 i32；`pan` 旧档 0..127）→ 读完再转成当前类型
                    if (r.version < cf.changed_in) {
                        const raw = try binReadValue(cf.old_T, r, a);
                        @field(out, fname) = convertLegacyTo(FType, raw) / cf.legacy_scale;
                    } else {
                        @field(out, fname) = try binReadValue(FType, r, a);
                    }
                } else {
                    // 溢出/错位在 `binReadValue` 里已转成 `error.CorruptProject`（不 panic）
                    @field(out, fname) = try binReadValue(FType, r, a);
                }
            }
            try binReadRemoved(T, r, a, ""); // 结构体末尾的已删字段
            return out;
        },
        else => @compileError("bin: unsupported type " ++ @typeName(T)),
    }
}

/// **v5 迁移**：时间分辨率 `U` 96 → 3840（= 960 PPQN）。
///
/// 只乘**步域**字段（`docs/units-3840.md` §2.3）：
/// - `Clip.start` / `Clip.len` / `Clip.offset`
/// - `Note.step` / `Note.len`
/// - 自动化曲线点 `SavedLanePoint.step`
///
/// **绝不乘**：`trim_start` / `trim_len`（帧）、`speed`、`audio_style`、`bpm`、
/// 拍号、乐器/效果器参数、各类索引。
/// 换算用 i64 中间值并饱和——防止手改过的极端值在 i32 上溢出。
fn migrateUnitsToV5(p: *Project) void {
    const s: i64 = model.unit_migration_scale; // 40
    const scale = struct {
        fn f(v: i32, k: i64) i32 {
            const w: i64 = @as(i64, v) * k;
            return @intCast(std.math.clamp(w, std.math.minInt(i32), std.math.maxInt(i32)));
        }
    }.f;
    for (p.clips) |*c| {
        c.start = scale(c.start, s);
        c.len = scale(c.len, s);
        c.offset = scale(c.offset, s);
    }
    for (p.notes) |*n| {
        n.step = scale(n.step, s);
        n.len = scale(n.len, s);
    }
    for (p.auto_lanes) |*ln| {
        for (ln.points) |*pt| pt.step = scale(pt.step, s);
    }
}

/// 工程 → v5 二进制（调用方负责释放）
pub fn toBinary(allocator: std.mem.Allocator, project: Project) ![]u8 {
    var w = BinWriter{ .a = allocator };
    errdefer w.buf.deinit(allocator);
    try w.put(binary_magic);
    try w.putByte(binary_version);
    try binWriteValue(Project, &w, project);
    return w.buf.toOwnedSlice(allocator);
}

/// 以指定**历史版本**的布局写出（测试用：真实旧档不会写“后续版本才有的字段”）。
/// 生产永远用 `toBinary`。
fn toBinaryAtVersion(allocator: std.mem.Allocator, project: Project, ver: u8) ![]u8 {
    var w = BinWriter{ .a = allocator, .version = ver };
    errdefer w.buf.deinit(allocator);
    try w.put(binary_magic);
    try w.putByte(ver);
    try binWriteValue(Project, &w, project);
    return w.buf.toOwnedSlice(allocator);
}

/// 以 **v5 旧布局**写出（测试/兼容验证用；生产永远写当前版本）
pub fn toBinaryLegacyV5(allocator: std.mem.Allocator, project: Project) ![]u8 {
    return toBinaryAtVersion(allocator, project, binary_version_legacy);
}

/// v5 二进制 → 工程。返回值与 `fromJson` 同型（`.value` / `.deinit()`）——
/// 内部用 ArenaAllocator 持有切片，调用方零差异。
pub fn fromBinary(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Project) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var r = BinReader{ .data = data };
    const magic = try r.take(binary_magic.len);
    if (!std.mem.eql(u8, magic, binary_magic)) return error.NotBinaryProject;
    const ver = try r.byte();
    if (ver >= binary_version_legacy and ver <= binary_version) {
        r.version = ver; // 按存档版本决定哪些字段需要跳过（`legacySkip`）
    } else return error.UnsupportedBinaryVersion;
    const value = try binReadValue(Project, &r, arena.allocator());
    if (r.pos != data.len) return error.TrailingBinaryData;
    // v9：读完后按源版本换算时间单位（U=96 → 3840）——
    // 放在这处**唯一入口**，下游（App/UI/调度）只见新单位。
    var out = value;
    if (ver < 9) {
        migrateUnitsToV5(&out);
        // 音符声像：旧档是 MIDI 0..127（已经按 `changed_fields` 的 scale 除过 127，
        // 但 64/127 = 0.5039 不是精确居中）→ 再用 `panFromMidi` 把 64 归成 0.5。
        for (out.notes) |*n| n.pan = model.panFromMidi(n.pan * 127.0);
    }
    return .{ .arena = arena, .value = out };
}

/// 自动识别存档（现在只有一种）：二进制 `SAWD` → 工程；其它 → `error.NotBinaryProject`。
pub fn parseAuto(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Project) {
    return fromBinary(allocator, data);
}

/// 解析失败的人话提示（UI 用：toast 里不要把裸错误名丢给用户）
pub fn parseErrorHint(e: anyerror) []const u8 {
    return switch (e) {
        error.NotBinaryProject => "不是 Sawdust 工程文件（需要二进制 .saw；旧的 JSON 工程已不再支持）",
        error.UnsupportedBinaryVersion => "存档版本不受支持（比当前版本新或早于 v5）",
        error.CorruptProject, error.TrailingBinaryData => "存档已损坏（或不是本版本能读的格式）",
        else => @errorName(e),
    };
}

/// **轻量探版本**（不解析全档）：magic 后那个版本字节（v5..）；
/// 不是二进制/被截断到只剩 magic → null。
pub fn probeVersion(allocator: std.mem.Allocator, data: []const u8) ?u32 {
    _ = allocator;
    if (data.len <= binary_magic.len) return null;
    if (!std.mem.eql(u8, data[0..binary_magic.len], binary_magic)) return null;
    return data[binary_magic.len];
}

/// 旧版 **JSON** 存档的版本探针（v1–v5）。
///
/// **只用于打不开时的提示**（“这是旧版 JSON 工程，请用旧版程序另存为 .saw”）——
/// JSON 读写通道已于 v9 删除，这里**不**解析工程，只读一个 `version` 字段。
/// 要求同时出现工程键（`"clips"`/`"notes"`）：`settings.json`、预设 JSON 没它们，
/// 不会被误报成“旧版工程”。
pub fn probeLegacyJsonVersion(allocator: std.mem.Allocator, data: []const u8) ?u32 {
    if (std.mem.indexOf(u8, data, "\"clips\"") == null and std.mem.indexOf(u8, data, "\"notes\"") == null) return null;
    const Probe = struct { version: u32 = 1 };
    var parsed = std.json.parseFromSlice(Probe, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.version;
}

// ── 测试 ──

test "persist: 旧版 JSON 探针——只认工程（settings/预设不误报）" {
    const a = std.testing.allocator;
    // 工程 JSON（带 version）→ 原样返回
    try std.testing.expectEqual(@as(?u32, 3), probeLegacyJsonVersion(a, "{\"version\":3,\"bpm\":112,\"clips\":[],\"notes\":[]}"));
    // 缺 version → v1 语义（与旧 fromJson 的默认一致）
    try std.testing.expectEqual(@as(?u32, 1), probeLegacyJsonVersion(a, "{\"clips\":[]}"));
    // settings.json / 预设 JSON：没有工程键 → 不误报成“旧版工程”
    try std.testing.expectEqual(@as(?u32, null), probeLegacyJsonVersion(a, "{\"fps\":90,\"last_project\":\"\"}"));
    // 随便一个文件 / 坏 JSON → null
    try std.testing.expectEqual(@as(?u32, null), probeLegacyJsonVersion(a, "这不是 JSON"));
    try std.testing.expectEqual(@as(?u32, null), probeLegacyJsonVersion(a, "{\"version\":3,\"clips\":[}"));
    // 二进制存档 → null（不是 JSON）
    try std.testing.expectEqual(@as(?u32, null), probeLegacyJsonVersion(a, "SAWD\x09\x00"));
}

/// 乐器/Layer 的**默认音色基准**（预设面板“重置音色”与新建乐器共用同一份）——
/// **不能用 `SavedSynth{}`**：它的字段默认是“全振荡器关闭”（静音），与
/// `SynthParams{}`（振荡器 1 开启、音量 0.6）不一致（实测被测试戳穿）；
/// 这里由 `SynthParams{}` 导出 → 与新建必然一致（两处一分叉，测试就报）。
pub fn defaultSavedSynth() SavedSynth {
    var p = synth.SynthParams{};
    return exportSynth(&p);
}

test "persist: 默认音色基准——重置 ≠ 静音，与新建乐器一致" {
    const d = defaultSavedSynth();
    try std.testing.expect(d.osc[0].enabled); // 会出声
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), d.osc[0].volume, 1e-6);
    var p = synth.SynthParams{};
    try std.testing.expect(std.meta.eql(d, exportSynth(&p))); // 同一基准
}

test "persist: 合成器参数往返（导出 → 导入）" {
    var p = synth.SynthParams{};
    p.attack.store(0.42, .monotonic);
    p.osc[2].enabled.store(true, .monotonic);
    p.osc[2].volume.store(0.33, .monotonic);
    p.osc[2].waveform.store(3, .monotonic); // 锯齿
    p.osc[2].unison.store(7, .monotonic); // 合奏副本数
    p.osc[2].unison_detune.store(0.35, .monotonic); // 合奏散布
    p.osc[2].detune_power.store(-2.5, .monotonic); // 散布功率
    p.lpf.enabled.store(true, .monotonic);
    p.lpf.cutoff.store(0.9, .monotonic);

    const saved = exportSynth(&p);

    var q = synth.SynthParams{};
    importSynth(&saved, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), q.attack.load(.monotonic), 1e-6);
    try std.testing.expect(q.osc[2].enabled.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), q.osc[2].volume.load(.monotonic), 1e-6);
    try std.testing.expectEqual(@as(u8, 3), q.osc[2].waveform.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 7), q.osc[2].unison.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), q.osc[2].unison_detune.load(.monotonic), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), q.osc[2].detune_power.load(.monotonic), 1e-6);
    try std.testing.expect(q.lpf.enabled.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), q.lpf.cutoff.load(.monotonic), 1e-6);
    // 未设置过的字段保持默认
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), q.decay.load(.monotonic), 1e-6);
    try std.testing.expectEqual(@as(u32, 1), q.osc[0].unison.load(.monotonic)); // 缺省单发声源

    // 超范围值 → 鉗制；低于 1 → 抬到 1（最少一个发声源）
    var s2 = saved;
    s2.osc[1].unison = 999;
    s2.osc[1].unison_detune = 5.0; // 越界
    s2.osc[1].detune_power = -99; // 越界
    var q2 = synth.SynthParams{};
    importSynth(&s2, &q2);
    try std.testing.expectEqual(@as(u32, synth.max_unison), q2.osc[1].unison.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), q2.osc[1].unison_detune.load(.monotonic), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), q2.osc[1].detune_power.load(.monotonic), 1e-6);
    var s2b = saved;
    s2b.osc[1].unison = 0; // 0 也要抬到 1
    var q2b = synth.SynthParams{};
    importSynth(&s2b, &q2b);
    try std.testing.expectEqual(@as(u32, 1), q2b.osc[1].unison.load(.monotonic));
    // 缺字段默认（旧存档）：散布默认 5%、功率 0
    var s3 = saved;
    s3.osc[1] = .{};
    var q3 = synth.SynthParams{};
    importSynth(&s3, &q3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), q3.osc[1].unison_detune.load(.monotonic), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q3.osc[1].detune_power.load(.monotonic), 1e-6);
}

test "persist: 冻结默认值（绊线——改动任意一项=破坏性格式变更，见 docs/save-format.md）" {
    try std.testing.expectEqual(@as(i32, 100), note_default_velocity);
    try std.testing.expectEqual(@as(f32, 0.5), note_default_pan);
    const n0 = SavedNote{ .step = 0, .len = 0, .pitch = 0 };
    try std.testing.expectEqual(@as(i32, 0), n0.pattern);
    try std.testing.expectEqual(@as(i32, 0), n0.instrument);
    const o = SavedOsc{};
    try std.testing.expect(!o.enabled);
    try std.testing.expectEqual(@as(f32, 0.5), o.volume);
    try std.testing.expectEqual(@as(u8, 0), o.waveform);
    try std.testing.expectEqual(@as(u32, 1), o.unison);
    try std.testing.expectEqual(@as(f32, 0.05), o.unison_detune);
    try std.testing.expectEqual(@as(f32, 0), o.detune_power);
    const f = SavedFilter{};
    try std.testing.expect(!f.enabled);
    try std.testing.expectEqual(@as(f32, 0.7), f.cutoff);
    const s = SavedSynth{};
    try std.testing.expectEqual(@as(f32, 0.05), s.attack);
    try std.testing.expectEqual(@as(f32, 0.30), s.decay);
    try std.testing.expectEqual(@as(f32, 0.70), s.sustain);
    try std.testing.expectEqual(@as(f32, 0.30), s.release);
    const dl = SavedDrumLayer{};
    try std.testing.expectEqual(@as(u32, 0), dl.kind);
    try std.testing.expectEqual(@as(f32, 1.0), dl.gain);
    const inst = SavedInstrument{};
    try std.testing.expectEqual(@as(f32, 0.75), inst.volume); // 推子位置 0.75 = 0 dB（v9 默认改为 unity）
    try std.testing.expectEqual(@as(f32, 0.5), inst.pan);
    try std.testing.expectEqual(@as(i32, 0), inst.mixer);
    try std.testing.expectEqual(@as(i32, -1), inst.midi_channel);
    const eb = SavedEqBand{};
    try std.testing.expectEqual(@as(f32, 1000), eb.freq);
    try std.testing.expectEqual(@as(f32, 0), eb.gain_db);
    try std.testing.expectEqual(@as(f32, 1.0), eb.q);
    const es = SavedEffectSlot{};
    try std.testing.expect(es.enabled);
    try std.testing.expectEqual(@as(f32, 1.0), es.mix);
    const mc = SavedMixerChannel{};
    try std.testing.expectEqual(@as(f32, 0.75), mc.volume); // 推子位置 0.75 = 0 dB
    try std.testing.expectEqual(@as(f32, 0.5), mc.pan);
    try std.testing.expectEqual(@as(i32, 6), pattern_count_default);
}

/// 序列化 → 解析 → **深等**比较（值约定：浮点用 ≤3 位小数字面量——写入按 3 位小数格式化）。
/// 注：不能用 `std.meta.eql`——它对切片是**指针比较**（解析结果必然另一块内存）。
fn deepEq(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .int, .float, .bool, .@"enum" => a == b,
        .comptime_int, .comptime_float => a == b,
        .optional => blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk deepEq(@typeInfo(T).optional.child, a.?, b.?);
        },
        .pointer => |p| blk: {
            switch (p.size) {
                .slice => {
                    if (a.len != b.len) break :blk false;
                    for (a, b) |ea, eb| {
                        if (!deepEq(p.child, ea, eb)) break :blk false;
                    }
                    break :blk true;
                },
                else => break :blk a == b,
            }
        },
        .array => |arr| blk: {
            for (a, b) |ea, eb| {
                if (!deepEq(arr.child, ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |s| blk: {
            // 0.17：数组结构体风格（field_names / field_types 等长并列）
            inline for (s.field_names, s.field_types) |fname, FType| {
                if (!deepEq(FType, @field(a, fname), @field(b, fname))) break :blk false;
            }
            break :blk true;
        },
        else => @compileError("deepEq: unsupported " ++ @typeName(T)),
    };
}

fn expectRoundtrip(comptime T: type, v: T) !void {
    const a = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(a, v, .{});
    defer a.free(json);
    var p = try std.json.parseFromSlice(T, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer p.deinit();
    if (!deepEq(T, v, p.value)) {
        std.debug.print("roundtrip mismatch for {s}: {s}\n", .{ @typeName(T), json });
        return error.TestUnexpectedResult;
    }
}

test "persist: 全字段非默认往返（防手写序列化漏字段）" {
    try expectRoundtrip(SavedClip, .{ .track = 2, .start = 96, .len = 48, .pattern = 1, .offset = 12 });
    try expectRoundtrip(SavedNote, .{ .step = 24, .len = 12, .pitch = 64, .pattern = 3, .instrument = 5, .velocity = 90, .pan = 0.157 });
    try expectRoundtrip(SavedOsc, .{ .enabled = true, .volume = 0.123, .waveform = 3, .unison = 7, .unison_detune = 0.456, .detune_power = -2.5 });
    try expectRoundtrip(SavedFilter, .{ .enabled = true, .cutoff = 0.876 });
    try expectRoundtrip(SavedSynth, .{
        .osc = .{ .{ .enabled = true, .volume = 0.111 }, .{ .enabled = true, .waveform = 2 }, .{}, .{ .unison = 4 } },
        .attack = 0.1,
        .decay = 0.2,
        .sustain = 0.3,
        .release = 0.4,
        .hpf = .{ .enabled = true, .cutoff = 0.5 },
        .lpf = .{ .enabled = true, .cutoff = 0.6 },
    });
    const bands = [_]SavedEqBand{.{ .freq = 320, .gain_db = 3.5, .q = 2 }};
    try expectRoundtrip(SavedEqBand, .{ .freq = 320, .gain_db = 3.5, .q = 2 });
    try expectRoundtrip(SavedEffectSlot, .{
        .kind = 3,
        .enabled = false,
        .mix = 0.42,
        .bands = &bands,
        .p = .{ 4, 0.6, 0, 0, 0 },
        .plugin_path = "C:/x.vst3",
        .plugin_state = "AAEC",
        .plugin_state_ctrl = "AQ",
        .plugin_cid = "abcd",
    });
    // 注意：`effect_count` 为派生字段（写入省略 = effects.len），不参与全等比较
    const chain = [_]SavedEffectSlot{.{ .kind = 1 }};
    try expectRoundtrip(SavedMixerChannel, .{ .name = "鼓组", .volume = 0.111, .pan = 0.222, .muted = true, .effects = &chain });
    var lyrs = [_]SavedDrumLayer{.{ .kind = 1, .synth = .{ .attack = 0.1 }, .gain = 0.5, .source_preset = "kit/k" }};
    try expectRoundtrip(SavedDrumLayer, lyrs[0]);
    // 采样器层：采样路径/trim 全量往返
    try expectRoundtrip(SavedDrumLayer, .{
        .kind = 3,
        .gain = 0.8,
        .source_preset = "kick.wav",
        .asset_path = "samples/kick.wav",
        .trim_start = 100,
        .trim_len = 2000,
    });
    // 音频样式 + 音频片段字段往返
    try expectRoundtrip(SavedAudioStyle, .{ .name = "Kick", .path = "samples/kick.wav", .channel = 2, .gain = 0.75 });
    try expectRoundtrip(SavedClip, .{ .track = 1, .start = 96, .len = 24, .pattern = 0, .audio_style = 0, .trim_start = 100, .trim_len = 2000 });
    // VST3 层：插件字段全量往返（路径/CID/状态 base64）
    try expectRoundtrip(SavedDrumLayer, .{
        .kind = 2,
        .gain = 0.75,
        .source_preset = "Vital/pad",
        .plugin_path = "C:/v/Vital.vst3",
        .plugin_cid = "0102030405060708090a0b0c0d0e0f10",
        .plugin_state = "AQID",
        .plugin_state_ctrl = "BAUG",
    });
    var pads = [_]SavedDrumPad{.{ .pitch = 36, .name = "Kick", .layers = &lyrs }};
    try expectRoundtrip(SavedDrumPad, pads[0]);
    try expectRoundtrip(SavedDrumKit, .{ .pads = &pads });
    // 合成器乐器：全字段 + synth（kit 留空）
    try expectRoundtrip(SavedInstrument, .{
        .name = "X",
        .volume = 0.111,
        .pan = 0.222,
        .muted = true,
        .mixer = 3,
        .midi_channel = 5,
        .kind = 0,
        .key_mode = 1,
        .preset_name = "p",
        .plugin_path = "C:/v.vst3",
        .plugin_state = "AA",
        .plugin_state_ctrl = "BB",
        .plugin_cid = "cc",
        .synth = .{ .attack = 0.1 },
    });
    // 鼓组乐器：kit 载荷（synth 本体按设计不写——鼓组不使用）
    try expectRoundtrip(SavedInstrument, .{ .name = "D", .kind = 1, .kit = .{ .pads = &pads } });
    // 工程级（legacy_units_per_bar 永不写；pattern_count 仅无名时写——两者不参与比较）
    const pnames = [_][]const u8{"P1"};
    const tnames = [_][]const u8{"主歌"};
    const trows = [_]i32{5};
    const tmuted = [_]i32{2};
    const clips = [_]SavedClip{.{ .track = 1, .start = 10, .len = 20, .pattern = 1 }};
    const notes2 = [_]SavedNote{.{ .step = 1, .len = 2, .pitch = 60 }};
    const insts = [_]SavedInstrument{.{ .name = "A" }};
    const mix = [_]SavedMixerChannel{.{ .volume = 0.9 }};
    try expectRoundtrip(Project, .{
        .bpm = 140,
        .volume = 0.42,
        .time_num = 3,
        .time_den = 8,
        .pattern_names = &pnames,
        .track_names = &tnames,
        .track_name_rows = &trows,
        .track_muted = &tmuted,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes2),
        .instruments = @constCast(&insts),
        .mixer = @constCast(&mix),
    });
}

/// 二进制往返助手（ArenaAllocator 持有切片——与 fromBinary 同策略）
fn expectBinRoundtrip(comptime T: type, v: T) !void {
    const a = std.testing.allocator;
    var w = BinWriter{ .a = a };
    defer w.buf.deinit(a);
    try binWriteValue(T, &w, v);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = BinReader{ .data = w.buf.items };
    const parsed = try binReadValue(T, &r, arena.allocator());
    if (r.pos != w.buf.items.len) {
        std.debug.print("bin: trailing {d} bytes for {s}\n", .{ w.buf.items.len - r.pos, @typeName(T) });
        return error.TestUnexpectedResult;
    }
    if (!deepEq(T, v, parsed)) {
        std.debug.print("bin roundtrip mismatch for {s}\n", .{@typeName(T)});
        return error.TestUnexpectedResult;
    }
}

test "persist: v5 二进制往返（代表性子结构 + 全字段工程 + 空工程）" {
    try expectBinRoundtrip(SavedNote, .{ .step = 24, .len = 12, .pitch = 64, .pattern = 3, .instrument = 5, .velocity = 90, .pan = 0.157 });
    try expectBinRoundtrip(SavedSynth, .{ .attack = 0.123, .osc = .{ .{ .enabled = true, .volume = 0.111, .unison = 3 }, .{}, .{}, .{} } });
    var lyrs = [_]SavedDrumLayer{.{ .kind = 1, .gain = 0.5, .source_preset = "kit/k" }};
    var pads = [_]SavedDrumPad{.{ .pitch = 36, .name = "Kick", .layers = &lyrs }};
    try expectBinRoundtrip(SavedInstrument, .{ .name = "D", .kind = 1, .kit = .{ .pads = &pads } });
    const pnames = [_][]const u8{"P1"};
    const clips = [_]SavedClip{.{ .track = 1, .start = 10, .len = 20, .pattern = 1 }};
    const notes2 = [_]SavedNote{.{ .step = 1, .len = 2, .pitch = 60 }};
    const insts = [_]SavedInstrument{.{ .name = "A" }};
    const mix = [_]SavedMixerChannel{.{ .volume = 0.9 }};
    try expectBinRoundtrip(Project, .{
        .bpm = 140,
        .volume = 0.42,
        .time_num = 3,
        .time_den = 8,
        .pattern_names = &pnames,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes2),
        .instruments = @constCast(&insts),
        .mixer = @constCast(&mix),
    });
    try expectBinRoundtrip(Project, .{}); // 全默认/空切片
}

test "persist: v5 二进制——插件状态 base64→raw（-25%）与非法回退" {
    const a = std.testing.allocator;
    // base64 "AAECAwQFBgcICQ==" = 10 字节 → 二进制 1+1+10 = 12 字节（vs 文本 16 字符）
    const si = SavedInstrument{ .name = "V", .kind = 2, .plugin_path = "x", .plugin_state = "AAECAwQFBgcICQ==", .plugin_state_ctrl = "not-base64!!" };
    const json = try std.json.Stringify.valueAlloc(a, si, .{});
    defer a.free(json);
    var w = BinWriter{ .a = a };
    defer w.buf.deinit(a);
    try binWriteValue(SavedInstrument, &w, si);
    try std.testing.expect(w.buf.items.len < json.len); // raw 通道生效（体积优势）
    try expectBinRoundtrip(SavedInstrument, si); // 往返保真（含非法回退字段）
}

test "persist: parseAuto——只认二进制（magic / 尾部垃圾 / 版本不符均报错）" {
    const a = std.testing.allocator;
    const p = Project{ .bpm = 150 };
    const bin = try toBinary(a, p);
    defer a.free(bin);
    try std.testing.expect(std.mem.startsWith(u8, bin, binary_magic));
    var pb = try parseAuto(a, bin);
    defer pb.deinit();
    try std.testing.expectEqual(@as(f32, 150), pb.value.bpm);
    // 非二进制（旧 JSON / 垃圾）→ 一律 NotBinaryProject
    try std.testing.expectError(error.NotBinaryProject, parseAuto(a, "{\"bpm\":150}"));
    // 尾部垃圾 / 版本不符 → 错误（严格性）
    const bad = try std.mem.concat(a, u8, &.{ bin, "\x00" });
    defer a.free(bad);
    try std.testing.expectError(error.TrailingBinaryData, parseAuto(a, bad));
    var bad2 = try a.dupe(u8, bin);
    defer a.free(bad2);
    bad2[4] = 99;
    try std.testing.expectError(error.UnsupportedBinaryVersion, parseAuto(a, bad2));
}

test "persist: 真实文件往返（写盘 → 读回）" {
    const allocator = std.testing.allocator;
    const tmp_path = "tmp/persist_test.saw";

    const clips = [_]SavedClip{.{ .track = 2, .start = 4 * model.units_per_whole, .len = 2 * model.units_per_whole, .pattern = 1 }};
    const notes = [_]SavedNote{.{ .step = 48, .len = 24, .pitch = 72, .pattern = 1, .instrument = 0 }};
    const instruments = [_]SavedInstrument{.{ .name = "测试乐器", .volume = 0.55 }};

    const project = Project{
        .bpm = 96,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes),
        .instruments = @constCast(&instruments),
    };

    // 写文件（用 Zig 标准测试的临时目录 API）
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const bytes = try toBinary(allocator, project);
    defer allocator.free(bytes);
    tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "test.saw", .data = bytes }) catch return error.SkipZigTest;

    // 读回
    const data = try tmp_dir.dir.readFileAlloc(std.testing.io, "test.saw", allocator, .unlimited);
    defer allocator.free(data);

    const parsed = try fromBinary(allocator, data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, 96), parsed.value.bpm);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.clips.len);
    try std.testing.expectEqual(4 * model.units_per_whole, parsed.value.clips[0].start);
    try std.testing.expectEqual(@as(i32, 72), parsed.value.notes[0].pitch);
    try std.testing.expectEqualStrings("测试乐器", parsed.value.instruments[0].name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), parsed.value.instruments[0].volume, 1e-6);
    _ = tmp_path;
}

test "persist: 调音台通道往返（增益/声像/静音/效果链）" {
    const allocator = std.testing.allocator;
    const mix = [_]SavedMixerChannel{
        .{ .name = "鼓组", .volume = 0.33, .pan = 0.2, .muted = true, .effects = &.{
            .{ .kind = 1, .enabled = true, .mix = 0.7, .bands = &[_]SavedEqBand{
                .{ .freq = 80, .gain_db = -6, .q = 0.7 },
                .{ .freq = 600, .gain_db = 3.5, .q = 1.2 },
                .{ .freq = 2500, .gain_db = -12, .q = 2.0 },
                .{ .freq = 9000, .gain_db = 8, .q = 0.9 },
            } },
        } },
        .{ .volume = 0.9, .pan = 0.8, .muted = false },
    };
    const project = Project{ .mixer = @constCast(&mix) };

    const bytes = try toBinary(allocator, project);
    defer allocator.free(bytes);
    const parsed = try fromBinary(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.mixer.len);
    const m0 = parsed.value.mixer[0];
    try std.testing.expectEqualStrings("鼓组", m0.name); // 通道名往返
    try std.testing.expectEqual(@as(usize, 0), parsed.value.mixer[1].name.len); // 无自定义名 → 空
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), m0.volume, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), m0.pan, 1e-6);
    try std.testing.expect(m0.muted);
    // 效果链：第 0 槽 = EQ；切片长度 = 实际条数（旧固定 4 槽 → 动态切片）
    try std.testing.expectEqual(@as(usize, 1), m0.effects.len);
    try std.testing.expectEqual(@as(u32, 1), m0.effects[0].kind);
    try std.testing.expect(m0.effects[0].enabled);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), m0.effects[0].mix, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 80), m0.effects[0].bands[0].freq, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -6), m0.effects[0].bands[0].gain_db, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), m0.effects[0].bands[1].q, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -12), m0.effects[0].bands[2].gain_db, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8), m0.effects[0].bands[3].gain_db, 1e-5);
    // 第二通道
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), parsed.value.mixer[1].pan, 1e-6);
    try std.testing.expect(!parsed.value.mixer[1].muted);
}

test "persist: 效果链动态长度往返（>4 条不再截断）" {
    const allocator = std.testing.allocator;
    const six = [_]SavedEffectSlot{ .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 } };
    const mix = [_]SavedMixerChannel{.{ .effect_count = 6, .effects = &six }};
    const project = Project{ .mixer = @constCast(&mix) };
    const bytes = try toBinary(allocator, project);
    defer allocator.free(bytes);
    const parsed = try fromBinary(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 6), parsed.value.mixer[0].effects.len);
    // `effect_count` 与 `effects.len` 一致（导入侧 `importMixerChannels` 也按 kind 推断容错）
}

test "persist: 样式名往返" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "主歌", "副歌" };
    const project = Project{ .pattern_names = &names };

    const bytes = try toBinary(allocator, project);
    defer allocator.free(bytes);
    const parsed = try fromBinary(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.pattern_names.len);
    try std.testing.expectEqualStrings("主歌", parsed.value.pattern_names[0]);
    try std.testing.expectEqualStrings("副歌", parsed.value.pattern_names[1]);
}

test "persist: v9 单位迁移——步域 ×40、帧域/参数绝不动（含 3/4 的 steps_per_bar）" {
    const a = std.testing.allocator;
    const sc = model.unit_migration_scale;
    // 3/4：旧 `steps_per_bar` = 72（不是 4/4 的 96）——曾经只按 “== 96” 换，
    // 结果 3/4 工程加载后拍长仍是 72 步 → 像素尺度错 40 倍（启动一屏 70 小节）。
    const clips = [_]SavedClip{
        .{ .track = 0, .start = 72, .len = 48, .pattern = 0, .offset = 24 },
        .{ .track = 1, .start = 0, .len = 0, .pattern = 0, .audio_style = 2, .trim_start = 111, .trim_len = 222 },
    };
    const notes = [_]SavedNote{.{ .step = 30, .len = 12, .pitch = 60, .pattern = 0, .instrument = 0 }};
    const pts = [_]SavedLanePoint{.{ .step = 18, .value = 0.5 }};
    var lanes = [_]SavedLane{.{ .points = @constCast(&pts) }};
    const proj = Project{
        .time_num = 3,
        .time_den = 4,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes),
        .auto_lanes = @constCast(&lanes),
    };
    // **用 v8 布局写出**（自动化三字段是 v9 才有的，真实 v8 档里没有它们）
    const bytes = try toBinaryAtVersion(a, proj, 8);
    defer a.free(bytes);
    var parsed = try fromBinary(a, bytes);
    defer parsed.deinit();
    const p = parsed.value;
    // 步域：全部 ×40
    try std.testing.expectEqual(@as(i32, 72 * sc), p.clips[0].start);
    try std.testing.expectEqual(@as(i32, 48 * sc), p.clips[0].len);
    try std.testing.expectEqual(@as(i32, 24 * sc), p.clips[0].offset);
    try std.testing.expectEqual(@as(i32, 30 * sc), p.notes[0].step);
    try std.testing.expectEqual(@as(i32, 12 * sc), p.notes[0].len);
    // v8 档**没有自动化**（v9 才引入）→ 读出来应当是空的（字段跳过不丢字节）
    try std.testing.expectEqual(@as(usize, 0), p.auto_lanes.len);
    try std.testing.expectEqual(@as(usize, 0), p.auto_bindings.len);
    // 帧域 / 参数：**不动**
    try std.testing.expectEqual(@as(i32, 111), p.clips[1].trim_start);
    try std.testing.expectEqual(@as(i32, 222), p.clips[1].trim_len);
    try std.testing.expectEqual(@as(i32, 2), p.clips[1].audio_style);
    try std.testing.expectEqual(@as(i32, 3), p.time_num);
    try std.testing.expectEqual(@as(i32, 4), p.time_den);
}

test "persist: v9 迁移也把自动化曲线点换算（×40）——函数级直接验" {
    const sc = model.unit_migration_scale;
    var pts = [_]SavedLanePoint{ .{ .step = 18, .value = 0.5 }, .{ .step = 90, .value = 1 } };
    var lanes = [_]SavedLane{.{ .points = @constCast(&pts) }};
    var proj = Project{
        .auto_lanes = @constCast(&lanes),
    };
    migrateUnitsToV5(&proj);
    try std.testing.expectEqual(@as(i32, 18 * sc), proj.auto_lanes[0].points[0].step);
    try std.testing.expectEqual(@as(i32, 90 * sc), proj.auto_lanes[0].points[1].step);
    try std.testing.expectEqual(@as(f32, 0.5), proj.auto_lanes[0].points[0].value); // 值不换
}

test "persist: removed_fields / changed_fields 表自检（填错会静默错位，必须炸在测试里）" {
    // 这些表**没有运行时校验**：`owner`/`before` 拼错 → 该丢的字节没丢 → 后面全错位，
    // 而且只在“真实旧档”上才看得出来。所以在此逐条对准结构体自检。
    inline for (removed_fields) |rf| {
        const T = structByOwner(rf.owner);
        // 1) 被删的字段**必须真的不存在了**（否则会被读两次）
        try std.testing.expect(!@hasField(T, rf.name));
        // 2) `before` 必须是当前存在的字段（空串 = 结尾）
        if (rf.before.len > 0) try std.testing.expect(@hasField(T, rf.before));
        // 3) 类型不能是带堆内存的（“读掉丢弃”只用得上标量/可选标量）
        const Info = @typeInfo(rf.T);
        try std.testing.expect(Info == .int or Info == .float or Info == .bool or Info == .optional);
    }
    inline for (changed_fields) |cf| {
        const T = structByOwner(cf.owner);
        // 1) 字段必须先当前存在（类型变更不是删除）
        try std.testing.expect(@hasField(T, cf.name));
        // 2) 新旧类型**必须真的不同**（否则这条登记是死登记，谁也不知道它在守护什么）
        try std.testing.expect(@FieldType(T, cf.name) != cf.old_T);
        // 3) `changed_in` 不能比当前版本还新
        try std.testing.expect(cf.changed_in <= binary_version);
    }
}

test "persist: probeVersion——二进制看版本字节 / 截断或垃圾 → null" {
    const a = std.testing.allocator;
    const p = Project{};
    const bin = try toBinary(a, p);
    defer a.free(bin);
    try std.testing.expectEqual(@as(?u32, binary_version), probeVersion(a, bin));
    // 旧布局也能探出真实版本号（升级弹窗靠它显示“v6”这类提示）
    const bin6 = try toBinaryAtVersion(a, p, 6);
    defer a.free(bin6);
    try std.testing.expectEqual(@as(?u32, 6), probeVersion(a, bin6));
    // 只剩 magic（截断）→ null（不当成版本 0 去乱弹窗）
    try std.testing.expect(probeVersion(a, bin[0..binary_magic.len]) == null);
    // 非二进制（旧 JSON / 干脆是垃圾）→ null
    try std.testing.expect(probeVersion(a, "definitely not a project") == null);
    try std.testing.expect(probeVersion(a, "{\"version\":3}") == null);
}

test "persist: v6 / v7 / v8 三种旧布局都能读（字段门控不吞字节 + ×40 迁移）" {
    // 版本 → 引入内容（读者靠 `introducedVersion` 跳字段，**不靠补丁函数**）：
    //   v6 = 鼓组 VST3 层 / 音频片段 / 音频样式；v7 = instrument_order；
    //   v8 = 音符·片段静音 `muted`；v9 = 自动化整套 + uid + 绑定新字段 + 单位 ×40。
    const a = std.testing.allocator;
    const sc = model.unit_migration_scale;
    var clips = [_]SavedClip{.{ .track = 3, .start = 4, .len = 8, .pattern = 1, .audio_style = 2, .trim_start = 55, .trim_len = 66, .muted = true }};
    var notes = [_]SavedNote{.{ .step = 2, .len = 3, .pitch = 60, .pattern = 0, .instrument = 1, .muted = true }};
    var order = [_]u32{ 1, 0 };
    const proj = Project{
        .bpm = 112,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes),
        .instrument_order = @constCast(&order),
    };

    // v6：有音频字段；没 instrument_order（v7）、没 muted（v8）、没自动化（v9）
    {
        const bytes = try toBinaryAtVersion(a, proj, 6);
        defer a.free(bytes);
        try std.testing.expectEqual(@as(u8, 6), bytes[4]);
        var parsed = try fromBinary(a, bytes);
        defer parsed.deinit();
        const p = parsed.value;
        try std.testing.expectEqual(@as(usize, 1), p.clips.len);
        try std.testing.expectEqual(@as(i32, 2), p.clips[0].audio_style); // v6 字段在
        try std.testing.expectEqual(@as(i32, 55), p.clips[0].trim_start);
        try std.testing.expectEqual(@as(i32, 4 * sc), p.clips[0].start); // ×40
        try std.testing.expectEqual(@as(bool, false), p.clips[0].muted); // v8 缺失 → false
        try std.testing.expectEqual(@as(bool, false), p.notes[0].muted);
        try std.testing.expectEqual(@as(i32, 2 * sc), p.notes[0].step);
        try std.testing.expectEqual(@as(usize, 0), p.instrument_order.len); // v7 缺失 → empty
        try std.testing.expectEqual(@as(usize, 0), p.auto_lanes.len); // v9 缺失 → empty
        try std.testing.expectEqual(@as(usize, 0), p.auto_bindings.len);
        // **类型变更**：v5..v8 的 `bpm` 是 i32，v9 才是 f32——按旧类型读完必须转回
        try std.testing.expectEqual(@as(f32, 112), p.bpm);
    }
    // v7：多了 instrument_order
    {
        const bytes = try toBinaryAtVersion(a, proj, 7);
        defer a.free(bytes);
        var parsed = try fromBinary(a, bytes);
        defer parsed.deinit();
        const p = parsed.value;
        try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, p.instrument_order);
        try std.testing.expectEqual(@as(bool, false), p.clips[0].muted); // v8 仍缺失
        try std.testing.expectEqual(@as(i32, 2), p.clips[0].audio_style);
    }
    // v8：多了 muted（音符 + 片段），仍无自动化
    {
        const bytes = try toBinaryAtVersion(a, proj, 8);
        defer a.free(bytes);
        var parsed = try fromBinary(a, bytes);
        defer parsed.deinit();
        const p = parsed.value;
        try std.testing.expectEqual(@as(bool, true), p.clips[0].muted);
        try std.testing.expectEqual(@as(bool, true), p.notes[0].muted);
        try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, p.instrument_order);
        try std.testing.expectEqual(@as(usize, 0), p.auto_lanes.len);
    }
    // v9（当前）：所有字段都在，并且**不再 ×40**（已是新单位）
    {
        const bytes = try toBinary(a, proj);
        defer a.free(bytes);
        var parsed = try fromBinary(a, bytes);
        defer parsed.deinit();
        const p = parsed.value;
        try std.testing.expectEqual(@as(i32, 4), p.clips[0].start); // 原值
        try std.testing.expectEqual(@as(i32, 2), p.notes[0].step);
        try std.testing.expectEqual(@as(bool, true), p.clips[0].muted);
        try std.testing.expectEqual(@as(f32, 112), p.bpm);
    }
    // v9 起 `bpm` 是 f32：**小数必须原样保留**（旧 i32 路径会截成 112）
    {
        const bytes = try toBinary(a, .{ .bpm = 90.5, .clips = @constCast(&clips) });
        defer a.free(bytes);
        var parsed = try fromBinary(a, bytes);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(f32, 90.5), parsed.value.bpm);
        // 写成旧布局（v8）时按 **四舍五入** 落整数（90.5 → 91）——精度丢失是该版本格式的固有约束
        const old = try toBinaryAtVersion(a, .{ .bpm = 90.5 }, 8);
        defer a.free(old);
        var parsed_old = try fromBinary(a, old);
        defer parsed_old.deinit();
        try std.testing.expectEqual(@as(f32, 91), parsed_old.value.bpm); // 四舍五入写入旧 i32 布局
    }
}

test "persist: v5 旧布局兼容读（v5 之后追加的字段取默认值）" {
    const a = std.testing.allocator;
    const clips = [_]SavedClip{
        .{ .track = 2, .start = 8, .len = 4, .pattern = 1, .audio_style = 3, .trim_start = 100, .trim_len = 200 },
        .{ .track = 0, .start = 0, .len = 16, .pattern = 0, .audio_style = 5, .trim_start = 7, .trim_len = 9 },
    };
    const proj = Project{ .clips = @constCast(&clips) };
    const bytes = try toBinaryLegacyV5(a, proj);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u8, binary_version_legacy), bytes[4]);
    var parsed = try fromBinary(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.clips.len);
    // 旧字段完整（v5 = 旧单位 → 读入时已 ×40，见 `migrateUnitsToV5`）
    const sc = model.unit_migration_scale;
    try std.testing.expectEqual(@as(i32, 2), parsed.value.clips[0].track);
    try std.testing.expectEqual(@as(i32, 8 * sc), parsed.value.clips[0].start);
    try std.testing.expectEqual(@as(i32, 4 * sc), parsed.value.clips[0].len);
    try std.testing.expectEqual(@as(i32, 1), parsed.value.clips[0].pattern);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.clips[1].track);
    // v5 之后追加的字段 → 默认值（不吞后面的元素字节）；帧域字段在 v5 时代还不存在
    try std.testing.expectEqual(@as(i32, -1), parsed.value.clips[0].audio_style);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.clips[0].trim_start);
    try std.testing.expectEqual(@as(i32, -1), parsed.value.clips[1].audio_style);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.audio_styles.len);
}

test "persist: 二进制往返——SavedDrumLayer 的 plugin_state（版本门控 + b64）" {
    // 回归：写端在"版本门控分支"里走 b64、读端曾漏判 → 字节流错位 →
    // 含 VST3 鼓组层的工程重开时 @intCast 崩溃（见 docs/pitfalls.md）。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const layer = SavedDrumLayer{
        .kind = 2,
        .gain = 0.75,
        .plugin_path = "C:/v/Vital.vst3",
        .plugin_cid = "00112233445566778899aabbccddeeff",
        .plugin_state = "AAECAwQFBgc=",
        .plugin_state_ctrl = "",
    };
    var w = BinWriter{ .a = a };
    defer w.buf.deinit(a);
    try binWriteValue(SavedDrumLayer, &w, layer);

    var r = BinReader{ .data = w.buf.items };
    const got = try binReadValue(SavedDrumLayer, &r, a);
    try std.testing.expectEqual(w.buf.items.len, r.pos); // 不多读、不少读
    try std.testing.expectEqualStrings(layer.plugin_path, got.plugin_path);
    try std.testing.expectEqualStrings(layer.plugin_cid, got.plugin_cid);
    try std.testing.expectEqualStrings(layer.plugin_state, got.plugin_state);
    try std.testing.expectEqualStrings(layer.plugin_state_ctrl, got.plugin_state_ctrl);
    try std.testing.expectApproxEqAbs(layer.gain, got.gain, 1e-6);
}

test "persist: 版本门控——v9 新字段在 v8 档里必须全部跳过（鼓组层 uid 曾漏登 → 整档错位）" {
    // **这是“字节级”不变量**：漏登一个字段 = 旧档多读/少读字节 → 全档错位。
    // 即使读写两侧共用同一张表（往返测试对称），真实旧档也会挂——所以直接锁表。
    try std.testing.expect(legacySkip(8, SavedDrumLayer, "uid")); // ← 本次事故
    try std.testing.expect(legacySkip(8, SavedEffectSlot, "uid"));
    try std.testing.expect(legacySkip(8, SavedInstrument, "uid"));
    try std.testing.expect(legacySkip(8, SavedMixerChannel, "uid"));
    try std.testing.expect(legacySkip(8, Project, "auto_lanes"));
    try std.testing.expect(legacySkip(8, Project, "auto_bindings"));
    try std.testing.expect(legacySkip(8, Project, "auto_sel"));
    try std.testing.expect(legacySkip(8, SavedBinding, "smooth_ms"));
    try std.testing.expect(legacySkip(8, SavedBinding, "invert"));
    try std.testing.expect(legacySkip(8, SavedBinding, "param_id"));
    try std.testing.expect(legacySkip(8, SavedBinding, "target_slot"));
    // 当前版本当然照读
    try std.testing.expect(!legacySkip(9, SavedDrumLayer, "uid"));
    try std.testing.expect(!legacySkip(9, Project, "auto_lanes"));
    // v6/v8 字段的门控也不能错
    try std.testing.expect(legacySkip(5, SavedClip, "audio_style"));
    try std.testing.expect(!legacySkip(6, SavedClip, "audio_style"));
    try std.testing.expect(!legacySkip(8, SavedClip, "muted"));
    try std.testing.expect(!legacySkip(8, SavedNote, "muted"));
    try std.testing.expect(legacySkip(6, Project, "instrument_order"));
    try std.testing.expect(!legacySkip(7, Project, "instrument_order"));
    // 从未登记过的老字段：任何版本都读
    try std.testing.expect(!legacySkip(5, SavedOsc, "volume"));
    try std.testing.expect(!legacySkip(5, SavedDrumLayer, "kind"));
    try std.testing.expect(!legacySkip(5, SavedDrumLayer, "synth"));
}

test "persist: v8 档带鼓组层——读写对称（v9 的 uid 不得进 v8）" {
    // 关键断言：v8 没有 `SavedDrumLayer.uid` → 读回来必须是 0（默认值）。
    // 万一 `introducedVersion` 漏登 uid（历史上真漏过）→ 写/读都算上它，
    // 这里会得到 7 而不是 0 → 测试抳住（真旧档则是整档错位 → `CorruptProject`）。
    const a = std.testing.allocator;
    var layers = [_]SavedDrumLayer{
        .{ .uid = 7, .kind = 2, .gain = 0.5, .source_preset = "VST/某音色", .plugin_path = "X.vst3", .plugin_state = "AAAA", .speed = 1.5 },
        .{ .uid = 8, .kind = 3, .asset_path = "kick.wav", .trim_start = 12, .trim_len = 34 },
    };
    var pads = [_]SavedDrumPad{.{ .pitch = 36, .name = "Kick", .layers = &layers }};
    var insts = [_]SavedInstrument{.{ .uid = 3, .name = "Kit", .kind = 1, .mixer = 1, .kit = .{ .pads = &pads } }};
    const proj = Project{ .bpm = 112, .instruments = &insts };

    const bytes = try toBinaryAtVersion(a, proj, 8);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u8, 8), bytes[4]);
    var parsed = try fromBinary(a, bytes);
    defer parsed.deinit();
    const p = parsed.value;
    try std.testing.expectEqual(@as(usize, 1), p.instruments.len);
    try std.testing.expectEqual(@as(u32, 0), p.instruments[0].uid); // v8 无 uid
    try std.testing.expectEqualStrings("Kit", p.instruments[0].name);
    try std.testing.expectEqual(@as(usize, 1), p.instruments[0].kit.pads.len);
    const pad = p.instruments[0].kit.pads[0];
    try std.testing.expectEqual(@as(u32, 36), pad.pitch);
    try std.testing.expectEqual(@as(usize, 2), pad.layers.len);
    try std.testing.expectEqual(@as(u32, 0), pad.layers[0].uid); // ← v9 字段在 v8 必须为默认
    try std.testing.expectEqual(@as(u32, 2), pad.layers[0].kind);
    try std.testing.expectEqualStrings("X.vst3", pad.layers[0].plugin_path);
    try std.testing.expectEqualStrings("AAAA", pad.layers[0].plugin_state);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), pad.layers[0].speed, 1e-6);
    try std.testing.expectEqual(@as(u32, 3), pad.layers[1].kind);
    try std.testing.expectEqualStrings("kick.wav", pad.layers[1].asset_path);
    try std.testing.expectEqual(@as(i32, 12), pad.layers[1].trim_start);
    try std.testing.expectEqual(@as(i32, 34), pad.layers[1].trim_len);
    // 当前版本仍要带着 uid 往返（别为了兼容把 v9 也跳了）
    const cur = try toBinary(a, proj);
    defer a.free(cur);
    var p2 = try fromBinary(a, cur);
    defer p2.deinit();
    try std.testing.expectEqual(@as(u32, 7), p2.value.instruments[0].kit.pads[0].layers[0].uid);
    try std.testing.expectEqual(@as(u32, 3), p2.value.instruments[0].uid);
}

test "persist: 整数溢出 → error.CorruptProject（不再 panic）" {
    // 300 的 varint = 0xAC 0x02（能装进 u64，但装不进 u8）；旧代码 @intCast 会 panic
    var r = BinReader{ .data = &[_]u8{ 0xAC, 0x02 } };
    try std.testing.expectError(error.CorruptProject, binReadValue(u8, &r, std.testing.allocator));
}

test "persist: v6 旧档（无 instrument_order）能正确读取——版本门控回归" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const proj = Project{ .bpm = 133, .instrument_order = &.{} };
    var w = BinWriter{ .a = a, .version = binary_version_v6 };
    defer w.buf.deinit(a);
    try w.put(binary_magic);
    try w.putByte(binary_version_v6);
    try binWriteValue(Project, &w, proj);

    var parsed = try fromBinary(std.testing.allocator, w.buf.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 133), parsed.value.bpm);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.instrument_order.len); // 旧档 → 空 = 按槽位顺序
}
