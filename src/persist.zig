//! 工程保存/加载：把 App 的文档数据序列化为 JSON 文件（`.saw`）。
//!
//! **设计**：
//! - 磁盘格式与运行时模型**解耦**（`SynthParams` 等含原子字段，不能直接序列化）；
//! - JSON 可读可调试；带 `version` 字段便于将来迁移；
//! - 纯逻辑（序列化/反序列化内存 ↔ 存档结构体）可单测；文件 IO 在 main 接线。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");

/// 当前文件格式版本
/// v1 → v2：片段坐标由“小节”改为 **U=96 步**（`bar` → `start`，`len` 单位同步）
/// v2 → v3：乐器的 `mixer` 由 **1 起**改为 **0 起**（加载时减 1）
pub const file_version: u32 = 4;

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
/// 音符声像缺省（同上，与 model.default_pan 解耦）
pub const note_default_pan: i32 = 64;
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
    // ── v1 兼容字段（**仅用于迁移**；v2 存档不写）──
    /// v1：起始小节（1 起）。加载 v1 时据此重建 `start`。
    bar: ?i32 = null,
    /// v1：长度（小节）。加载 v1 时据此重建 `len`。
    len_bars: ?i32 = null,

    /// 序列化时**跳过 v1 兼容字段**（避免 JSON 里出现 null 噪音）
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("track");
        try jw.write(self.track);
        try jw.objectField("start");
        try jw.write(self.start);
        try jw.objectField("len");
        try jw.write(self.len);
        try jw.objectField("pattern");
        try jw.write(self.pattern);
        if (self.offset != 0) {
            try jw.objectField("offset");
            try jw.write(self.offset);
        }
        try jw.endObject();
    }
};

/// 存档中的音符
pub const SavedNote = struct {
    step: i32,
    len: i32,
    pitch: i32,
    // 默认 0：瘦身写入时省略（见 jsonStringify）；旧档总有该字段，给默认不改变解析
    pattern: i32 = 0,
    instrument: i32 = 0,
    /// 力度（1-127；缺省 =`note_default_velocity`，冻结格式常量）
    velocity: i32 = note_default_velocity,
    /// 声像（0-127；64 = 居中；缺省 =`note_default_pan`）
    pan: i32 = note_default_pan,

    /// 序列化省默认：格式/力度/声像/乐器为默认值时省略（占盘大头；见 docs/save-format.md）
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("step");
        try jw.write(self.step);
        try jw.objectField("len");
        try jw.write(self.len);
        try jw.objectField("pitch");
        try jw.write(self.pitch);
        if (self.pattern != 0) {
            try jw.objectField("pattern");
            try jw.write(self.pattern);
        }
        if (self.instrument != 0) {
            try jw.objectField("instrument");
            try jw.write(self.instrument);
        }
        if (self.velocity != note_default_velocity) {
            try jw.objectField("velocity");
            try jw.write(self.velocity);
        }
        if (self.pan != note_default_pan) {
            try jw.objectField("pan");
            try jw.write(self.pan);
        }
        try jw.endObject();
    }
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
    /// 乐器类型（0 = 减法合成器；旧存档缺失 → 0）
    kind: u32 = 0,
    synth: SavedSynth = .{},
    /// 层内增益（多层叠加的配比）
    gain: f32 = 1.0,
    /// 来源预设名（`分类/名字`；展示用，空 = 手调/空层）
    source_preset: []const u8 = "",
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
    name: []const u8 = "",
    volume: f32 = 0.8,
    pan: f32 = 0.5,
    muted: bool = false,
    /// 混音通道（**0 起**；v3 起。v1/v2 存档是 1 起——加载时减 1）
    mixer: i32 = 0,
    /// MIDI 通道（0-15；-1 = 无；旧存档缺失 → -1）
    midi_channel: i32 = -1,
    /// 乐器类型（0 = synth / 1 = drumkit；旧存档缺失 → 0）
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
    /// 合成器参数（synth 类型用；鼓组类型的“本体”不使用）
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
    /// 自定义名字（UTF-8；空 = 无自定义名——用默认占位名）
    name: []const u8 = "",
    volume: f32 = 0.8,
    pan: f32 = 0.5,
    muted: bool = false,
    /// 有效效果器数（0 = 旧存档：按 kind != 0 推断）
    effect_count: u32 = 0,
    /// 效果器链（**动态长度**：导出时按实际槽数分配，至多 `app.max_effects_per_channel`；
    /// 旧存档为固定 4 槽数组——切片解析天然兼容）
    effects: []const SavedEffectSlot = &.{},
};

pub const Project = struct {
    version: u32 = file_version,
    bpm: i32 = 120,
    /// 主音量（0-1；旧存档缺失 → 默认 0.75，与 App.volume 一致）
    volume: f32 = 0.75,
    time_num: i32 = 4,
    time_den: i32 = 4,
    /// 每小节步数（冗余存储：拍号换算规则若变更仍能正确还原）
    steps_per_bar: i32 = model.units_per_whole,
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
    /// 兼容用：v1 存档的时长单位（小节）。加载 v1 时把 `bar/len` 乘此值转成步。
    legacy_units_per_bar: i32 = model.units_per_whole,
    clips: []SavedClip = &.{},
    notes: []SavedNote = &.{},
    instruments: []SavedInstrument = &.{},
    /// 调音台通道（旧存档缺失 → 全默认 8 通道；加载时长度不匹配则重置）
    mixer: []SavedMixerChannel = &.{},
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

/// 把工程序列化为 JSON 字符串（调用方负责释放）
pub fn toJson(allocator: std.mem.Allocator, project: Project) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.write(project);
    return out.toOwnedSlice();
}

/// 应用设置（数据目录下 `settings.json`；缺失/损坏 → 默认值）
pub const Settings = struct {
    /// 启动时打开上次工程（false = 新建空工程）
    open_last: bool = false,
    /// 最高帧率（30..240）
    fps: i32 = 120,
    /// 上次打开/保存的工程路径（仅落盘；运行时真身在 `App.project_path`）
    last_project: []const u8 = "",
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
    const json = try settingsToJson(allocator, .{ .open_last = true, .fps = 90, .last_project = "C:\\Music\\曲.saw" });
    defer allocator.free(json);
    var parsed = try settingsFromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.open_last);
    try std.testing.expectEqual(@as(i32, 90), parsed.value.fps);
    try std.testing.expectEqualStrings("C:\\Music\\曲.saw", parsed.value.last_project);

    // 未知字段忽略；缺字段 → 默认值
    var parsed2 = try settingsFromJson(allocator, "{\"fps\":60,\"future\":123}");
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(i32, 60), parsed2.value.fps);
    try std.testing.expect(!parsed2.value.open_last);
    try std.testing.expectEqualStrings("", parsed2.value.last_project);
}
/// **向后兼容**：v1 存档的片段坐标为“小节”（`bar`/`len`），
/// 自动按 `legacy_units_per_bar` 换算为步（v2 起统一用步）。
pub fn fromJson(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Project) {
    // **`.alloc_always` 必须**：默认的 `alloc_if_needed` 会让无转义字符串借用
    // `data` 缓冲——调用方习惯性 `defer free(data)`，一旦生命周期估算错误
    // （或被改写）就悬空。全拷进 arena 后，返回值自包含（见 preset.load 同注）。
    var parsed = try std.json.parseFromSlice(Project, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version < 2) {
        // v1：`bar`（1 起小节）与 `len`（小节）都是**小节单位**——
        // 注意 v1 JSON 里长度字段也叫 `len`（与 v2 同名不同单位），已解析进 `len`。
        const upb = if (parsed.value.legacy_units_per_bar > 0) parsed.value.legacy_units_per_bar else model.units_per_whole;
        for (parsed.value.clips) |*c| {
            if (c.bar) |bar| c.start = @max(0, bar - 1) * upb;
            if (c.len_bars) |lb| {
                c.len = @max(1, lb) * upb;
            } else {
                c.len = @max(1, c.len) * upb; // v1 的 `len` 字段 = 小节数
            }
            c.offset = c.offset * upb; // 局部小节 → 局部步
            c.bar = null;
            c.len_bars = null;
        }
        parsed.value.version = 2;
    }
    if (parsed.value.version < 3) {
        // v2：乐器 `mixer` 是 **1 起**（主通道 = 1）→ v3 改为 0 起（减 1）
        for (parsed.value.instruments) |*inst| {
            inst.mixer -= 1;
        }
        parsed.value.version = 3;
    }
    if (parsed.value.version < 4) {
        // v4：轨道名改为**稀疏对**（`track_name_rows` + `track_names`）。
        // 旧密集数组这里**不做改写**——加载侧（`importProject`）的垫片按“跳过空串”
        // 派生行号，本步仅作版本对齐（正式迁移函数链见 docs/save-format.md）。
        parsed.value.version = 4;
    }
    return parsed;
}

// ── v5 二进制格式（默认保存；JSON 保留为导入/导出通道）──
//
// 布局：magic "SAWD" + u8 版本(5) + 载荷。载荷 = **comptime 反射编码**（全量字段，
// 零逐结构维护——与 JSON 的 Z+ 策略互补：二进制不做任何省略）。
// 编码规则：
// - 整数：varint（有符号走 zigzag）；bool：1 字节；枚举：底层整数 varint；
// - f32：原始 4 字节（平台本机字节序——本项目仅 Windows x64，不做跨端承诺）；
// - 字符串/切片：varint 长度 + 内容；定长数组：逐元素；optional：1 字节 tag + 载荷；
// - **特殊字段**：`plugin_state` / `plugin_state_ctrl`（base64 文本）解码为**原始字节**
//   存储（省 25%）：tag 0 = 空、1 = raw、2 = 文本回退（非法 base64 原样存）。
// 读取严格：magic/版本校验 + 全量消费（尾部垃圾 = 错误——防截断/错位静默）。
pub const binary_magic = "SAWD";
pub const binary_version: u8 = 5;

const BinWriter = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },

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
        .@"enum" => try w.putVarint(@intFromEnum(v)),
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (comptime isB64TextField(f.name, f.type)) {
                    try binWriteB64Field(w, @field(v, f.name));
                } else {
                    try binWriteValue(f.type, w, @field(v, f.name));
                }
            }
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
            if (info.signedness == .signed) {
                const zz: i64 = @bitCast(uv);
                const x: i64 = (zz >> 1) ^ -(zz & 1);
                return @intCast(x);
            }
            return @intCast(uv);
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
        .@"enum" => return @enumFromInt(try r.varint()),
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.fields) |f| {
                if (comptime isB64TextField(f.name, f.type)) {
                    @field(out, f.name) = try binReadB64Field(r, a);
                } else {
                    @field(out, f.name) = try binReadValue(f.type, r, a);
                }
            }
            return out;
        },
        else => @compileError("bin: unsupported type " ++ @typeName(T)),
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
    if (ver != binary_version) return error.UnsupportedBinaryVersion;
    const value = try binReadValue(Project, &r, arena.allocator());
    if (r.pos != data.len) return error.TrailingBinaryData;
    return .{ .arena = arena, .value = value };
}

/// 自动识别存档：v5 二进制（magic 前缀）或 JSON（v1–v4 旧档）→ 工程。
/// 默认保存写二进制；JSON 保留为导入/导出通道（见 docs/save-format.md）。
pub fn parseAuto(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Project) {
    if (data.len >= binary_magic.len and std.mem.eql(u8, data[0..binary_magic.len], binary_magic)) {
        return fromBinary(allocator, data);
    }
    return fromJson(allocator, data);
}

/// 轻量探针：JSON 存档的 `version`（非 JSON/解析失败 → null；缺字段 → 1 = v1 语义）。
/// 供“打开旧档 → 备份并升级”弹窗判定（见 main.loadProjectFromPath；③ 迁移流程）。
pub fn probeJsonVersion(allocator: std.mem.Allocator, data: []const u8) ?u32 {
    const Probe = struct { version: u32 = 1 };
    var parsed = std.json.parseFromSlice(Probe, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.version;
}

// ── 测试 ──

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

test "persist: JSON 往返（序列化 → 解析）" {
    const allocator = std.testing.allocator;
    const clips = [_]SavedClip{
        .{ .track = 1, .start = 3 * model.units_per_whole, .len = 4 * model.units_per_whole, .pattern = 2 },
        .{ .track = 0, .start = 9 * model.units_per_whole, .len = 2 * model.units_per_whole, .pattern = 0, .offset = model.units_per_whole },
    };
    const notes = [_]SavedNote{
        .{ .step = 24, .len = 12, .pitch = 60, .pattern = 0, .instrument = 1 },
    };
    const instruments = [_]SavedInstrument{
        .{ .name = "减法合成器", .volume = 0.7, .synth = .{ .attack = 0.1 } },
    };

    const project = Project{
        .bpm = 140,
        .volume = 0.42,
        .time_num = 3,
        .time_den = 4,
        .steps_per_bar = 72,
        .clips = @constCast(&clips),
        .notes = @constCast(&notes),
        .instruments = @constCast(&instruments),
    };

    const json = try toJson(allocator, project);
    defer allocator.free(json);

    // JSON 可读性：应含版本与关键字段
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\": 140") != null);
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 4), parsed.value.version);
    try std.testing.expectEqual(@as(i32, 140), parsed.value.bpm);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), parsed.value.volume, 1e-6); // 主音量往返
    try std.testing.expectEqual(@as(i32, 3), parsed.value.time_num);
    try std.testing.expectEqual(@as(i32, 72), parsed.value.steps_per_bar);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.clips.len);
    try std.testing.expectEqual(model.units_per_whole, parsed.value.clips[1].offset);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.notes.len);
    try std.testing.expectEqual(@as(i32, 60), parsed.value.notes[0].pitch);
    try std.testing.expectEqual(@as(i32, 1), parsed.value.notes[0].instrument);
    try std.testing.expectEqualStrings("减法合成器", parsed.value.instruments[0].name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), parsed.value.instruments[0].synth.attack, 1e-6);
}

test "persist: 未知字段被忽略（向前兼容）" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":2,"bpm":100,"future_field":42,
        \\ "clips":[],"notes":[],"instruments":[]}
    ;
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 100), parsed.value.bpm);
}

test "persist: v1 存档自动迁移（小节 → 步）" {
    const allocator = std.testing.allocator;
    // v1 格式：片段用 bar/len（小节）；此处 bar = 3、len = 2、offset = 1
    const json =
        \\{"version":1,"bpm":120,"time_num":4,"time_den":4,"steps_per_bar":96,
        \\ "clips":[{"track":0,"bar":3,"len":2,"pattern":0,"offset":1}],
        \\ "notes":[],"instruments":[]}
    ;
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 4), parsed.value.version); // 已升级
    try std.testing.expectEqual(@as(usize, 1), parsed.value.clips.len);
    const c = parsed.value.clips[0];
    const B: i32 = model.units_per_whole;
    try std.testing.expectEqual(2 * B, c.start); // bar 3 → 步 2 小节（0 起）
    try std.testing.expectEqual(2 * B, c.len); // 2 小节 → 步
    try std.testing.expectEqual(B, c.offset); // 1 小节局部 → 步

    // 回写 v2 → 再读 → 不重复迁移
    const json2 = try toJson(allocator, parsed.value);
    defer allocator.free(json2);
    const parsed2 = try fromJson(allocator, json2);
    defer parsed2.deinit();
    try std.testing.expectEqual(2 * B, parsed2.value.clips[0].start);
    try std.testing.expectEqual(2 * B, parsed2.value.clips[0].len);
}

test "persist: v2 存档自动迁移（mixer 1 起 → 0 起）" {
    const allocator = std.testing.allocator;
    // v2：乐器 mixer = 1（旧语义：主通道 = 1）→ v3 应为 0
    const json =
        \\{"version":2,"bpm":120,"time_num":4,"time_den":4,"steps_per_bar":96,
        \\ "clips":[],"notes":[],
        \\ "instruments":[{"name":"A","mixer":1},{"name":"B","mixer":3}]}
    ;
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 4), parsed.value.version);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.instruments[0].mixer); // 1 → 0
    try std.testing.expectEqual(@as(i32, 2), parsed.value.instruments[1].mixer); // 3 → 2

    // 回写再读：不重复迁移
    const json2 = try toJson(allocator, parsed.value);
    defer allocator.free(json2);
    const parsed2 = try fromJson(allocator, json2);
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(i32, 0), parsed2.value.instruments[0].mixer);
}

test "persist: 缺失字段用默认值（向后兼容）" {
    const allocator = std.testing.allocator;
    // 只有 version 和 bpm：其余字段应取默认
    const json =
        \\{"version":1,"bpm":90}
    ;
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 90), parsed.value.bpm);
    try std.testing.expectEqual(@as(i32, 4), parsed.value.time_num); // 默认
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), parsed.value.volume, 1e-6); // 缺字段 → 默认主音量
    try std.testing.expectEqual(@as(usize, 0), parsed.value.clips.len);
}

test "persist: 力度/声像往返（缺字段的旧存档 → 默认值）" {
    const allocator = std.testing.allocator;
    const notes = [_]SavedNote{
        .{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .velocity = 40, .pan = 20 },
        .{ .step = 48, .len = 24, .pitch = 64, .pattern = 0 }, // 默认 100 / 64
    };
    const project = Project{ .notes = @constCast(&notes) };

    const json = try toJson(allocator, project);
    defer allocator.free(json);
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.notes.len);
    try std.testing.expectEqual(@as(i32, 40), parsed.value.notes[0].velocity);
    try std.testing.expectEqual(@as(i32, 20), parsed.value.notes[0].pan);
    try std.testing.expectEqual(@as(i32, 100), parsed.value.notes[1].velocity);
    try std.testing.expectEqual(@as(i32, 64), parsed.value.notes[1].pan);

    // 旧存档（无字段）→ 默认值
    const legacy =
        \\{"version":3,"bpm":120,"time_num":4,"time_den":4,"steps_per_bar":96,
        \\ "clips":[],"notes":[{"step":0,"len":12,"pitch":60,"pattern":0,"instrument":0}],
        \\ "instruments":[]}
    ;
    const old = try fromJson(allocator, legacy);
    defer old.deinit();
    try std.testing.expectEqual(@as(i32, 100), old.value.notes[0].velocity);
    try std.testing.expectEqual(@as(i32, 64), old.value.notes[0].pan);
}

test "persist: 瘦身——仅 Note 省默认（Z+）；其余结构反射全写" {
    const allocator = std.testing.allocator;
    const notes = [_]SavedNote{
        .{ .step = 0, .len = 12, .pitch = 60, .pattern = 0 }, // 全默认 → 只剩三键
        .{ .step = 96, .len = 12, .pitch = 62, .pattern = 1, .instrument = 2, .velocity = 90, .pan = 20 },
    };
    const instruments = [_]SavedInstrument{
        .{ .name = "A", .synth = .{ .attack = 0.1 } },
    };
    const project = Project{ .notes = @constCast(&notes), .instruments = @constCast(&instruments) };
    const json = try toJson(allocator, project);
    defer allocator.free(json);

    // Note：默认字段省略（用**值定位**断言，不受其他结构的键影响）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"velocity\": 90") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"velocity\": 100") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pan\": 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pan\": 64") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pattern\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pattern\": 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instrument\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instrument\": 0") == null);
    // 其余结构：反射全写（Z+ 决定——低频实体不做省默认）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"attack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"decay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hpf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"preset_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kit\"") != null);
    // 往返仍正确
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.notes.len);
    try std.testing.expectEqual(@as(i32, 100), parsed.value.notes[0].velocity);
    try std.testing.expectEqual(@as(i32, 64), parsed.value.notes[0].pan);
    try std.testing.expectEqual(@as(i32, 90), parsed.value.notes[1].velocity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), parsed.value.instruments[0].synth.attack, 1e-6);
}

test "persist: 冻结默认值（绊线——改动任意一项=破坏性格式变更，见 docs/save-format.md）" {
    try std.testing.expectEqual(@as(i32, 100), note_default_velocity);
    try std.testing.expectEqual(@as(i32, 64), note_default_pan);
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
    try std.testing.expectEqual(@as(f32, 0.8), inst.volume);
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
    try std.testing.expectEqual(@as(f32, 0.8), mc.volume);
    try std.testing.expectEqual(@as(f32, 0.5), mc.pan);
    const p = Project{};
    try std.testing.expectEqual(file_version, p.version);
    try std.testing.expectEqual(@as(f32, 0.75), p.volume);
    try std.testing.expectEqual(@as(i32, 6), pattern_count_default);
    try std.testing.expectEqual(@as(i32, 96), p.steps_per_bar); // = model.units_per_whole（坐标结构常量）
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
            inline for (s.fields) |f| {
                if (!deepEq(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
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
    try expectRoundtrip(SavedNote, .{ .step = 24, .len = 12, .pitch = 64, .pattern = 3, .instrument = 5, .velocity = 90, .pan = 20 });
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
        .version = file_version,
        .bpm = 140,
        .volume = 0.42,
        .time_num = 3,
        .time_den = 8,
        .steps_per_bar = 72,
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
    try expectBinRoundtrip(SavedNote, .{ .step = 24, .len = 12, .pitch = 64, .pattern = 3, .instrument = 5, .velocity = 90, .pan = 20 });
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
        .version = file_version,
        .bpm = 140,
        .volume = 0.42,
        .time_num = 3,
        .time_den = 8,
        .steps_per_bar = 72,
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

test "persist: parseAuto——JSON/二进制自动识别 + magic 严格性" {
    const a = std.testing.allocator;
    const p = Project{ .bpm = 150 };
    const bin = try toBinary(a, p);
    defer a.free(bin);
    try std.testing.expect(std.mem.startsWith(u8, bin, binary_magic));
    var pb = try parseAuto(a, bin);
    defer pb.deinit();
    try std.testing.expectEqual(@as(i32, 150), pb.value.bpm);
    const js = try toJson(a, p);
    defer a.free(js);
    var pj = try parseAuto(a, js);
    defer pj.deinit();
    try std.testing.expectEqual(@as(i32, 150), pj.value.bpm);
    // 尾部垃圾 / 版本不符 → 错误（严格性）
    const bad = try std.mem.concat(a, u8, &.{ bin, "\x00" });
    defer a.free(bad);
    try std.testing.expectError(error.TrailingBinaryData, parseAuto(a, bad));
    var bad2 = try a.dupe(u8, bin);
    defer a.free(bad2);
    bad2[4] = 99;
    try std.testing.expectError(error.UnsupportedBinaryVersion, parseAuto(a, bad2));
}

test "persist: probeJsonVersion——旧档探针" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?u32, 3), probeJsonVersion(a, "{\"version\":3,\"bpm\":120}"));
    try std.testing.expectEqual(@as(?u32, 1), probeJsonVersion(a, "{\"bpm\":120}")); // 缺字段 → 1（v1 语义）
    try std.testing.expectEqual(@as(?u32, null), probeJsonVersion(a, "not json"));
    try std.testing.expectEqual(@as(?u32, null), probeJsonVersion(a, ""));
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

    const json = try toJson(allocator, project);
    defer allocator.free(json);
    tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "test.saw", .data = json }) catch return error.SkipZigTest;

    // 读回
    const data = try tmp_dir.dir.readFileAlloc(std.testing.io, "test.saw", allocator, .unlimited);
    defer allocator.free(data);

    const parsed = try fromJson(allocator, data);
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

    const json = try toJson(allocator, project);
    defer allocator.free(json);
    // JSON 里应有调音台字段
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mixer\"") != null);

    const parsed = try fromJson(allocator, json);
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

    // 旧存档无 mixer 字段 → 空数组（不报错）
    const old = try fromJson(allocator, "{\"version\":2,\"bpm\":100}");
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.mixer.len);
}

test "persist: 效果链动态长度往返（>4 条不再截断）" {
    const allocator = std.testing.allocator;
    const six = [_]SavedEffectSlot{ .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 }, .{ .kind = 1 } };
    const mix = [_]SavedMixerChannel{.{ .effect_count = 6, .effects = &six }};
    const project = Project{ .mixer = @constCast(&mix) };
    const json = try toJson(allocator, project);
    defer allocator.free(json);
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 6), parsed.value.mixer[0].effects.len);
    // effect_count 已在写入侧省略（= effects.len；加载侧 `importMixerChannels` 按 kind 推断恢复）
}

test "persist: v2 输出不含 v1 兼容字段（bar/len_bars）" {
    const allocator = std.testing.allocator;
    const clips = [_]SavedClip{.{ .track = 0, .start = 2 * model.units_per_whole, .len = model.units_per_whole, .pattern = 0 }};
    const project = Project{ .clips = @constCast(&clips) };
    const json = try toJson(allocator, project);
    defer allocator.free(json);
    // bar/len_bars 为 null 时不应出现在 JSON 里（避免噪音与误读）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bar\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "len_bars") == null);
}

test "persist: 样式名往返（旧存档无字段 → 空列表）" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "主歌", "副歌" };
    const project = Project{ .pattern_names = &names };

    const json = try toJson(allocator, project);
    defer allocator.free(json);
    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.pattern_names.len);
    try std.testing.expectEqualStrings("主歌", parsed.value.pattern_names[0]);
    try std.testing.expectEqualStrings("副歌", parsed.value.pattern_names[1]);

    // 旧存档（v3、无 pattern_names）→ 空列表（加载方按 pattern_count 重建）
    const legacy =
        \\{"version":3,"bpm":120,"pattern_count":6}
    ;
    const old = try fromJson(allocator, legacy);
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.pattern_names.len);
    try std.testing.expectEqual(@as(i32, 6), old.value.pattern_count);
}
