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
pub const file_version: u32 = 2;

/// 默认文件名
pub const default_file_name: []const u8 = "project.saw";

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
    pattern: i32,
    instrument: i32 = 0,
};

/// 存档中的振荡器（原子字段 → 普通值）
pub const SavedOsc = struct {
    enabled: bool = false,
    volume: f32 = 0.5,
    waveform: u8 = 0,
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

/// 存档中的乐器
pub const SavedInstrument = struct {
    name: []const u8 = "",
    volume: f32 = 0.8,
    pan: f32 = 0.5,
    muted: bool = false,
    mixer: i32 = 1,
    synth: SavedSynth = .{},
};

/// 完整工程存档
pub const Project = struct {
    version: u32 = file_version,
    bpm: i32 = 120,
    time_num: i32 = 4,
    time_den: i32 = 4,
    /// 每小节步数（冗余存储：拍号换算规则若变更仍能正确还原）
    steps_per_bar: i32 = model.units_per_whole,
    /// 兼容用：v1 存档的时长单位（小节）。加载 v1 时把 `bar/len` 乘此值转成步。
    legacy_units_per_bar: i32 = model.units_per_whole,
    clips: []SavedClip = &.{},
    notes: []SavedNote = &.{},
    instruments: []SavedInstrument = &.{},
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

/// 从 JSON 字符串解析工程（返回的 `Project` 内切片归调用方释放）。
/// **向后兼容**：v1 存档的片段坐标为“小节”（`bar`/`len`），
/// 自动按 `legacy_units_per_bar` 换算为步（v2 起统一用步）。
pub fn fromJson(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Project) {
    var parsed = try std.json.parseFromSlice(Project, allocator, data, .{ .ignore_unknown_fields = true });
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
    return parsed;
}

// ── 测试 ──

test "persist: 合成器参数往返（导出 → 导入）" {
    var p = synth.SynthParams{};
    p.attack.store(0.42, .monotonic);
    p.osc[2].enabled.store(true, .monotonic);
    p.osc[2].volume.store(0.33, .monotonic);
    p.osc[2].waveform.store(3, .monotonic); // 锯齿
    p.lpf.enabled.store(true, .monotonic);
    p.lpf.cutoff.store(0.9, .monotonic);

    const saved = exportSynth(&p);

    var q = synth.SynthParams{};
    importSynth(&saved, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), q.attack.load(.monotonic), 1e-6);
    try std.testing.expect(q.osc[2].enabled.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), q.osc[2].volume.load(.monotonic), 1e-6);
    try std.testing.expectEqual(@as(u8, 3), q.osc[2].waveform.load(.monotonic));
    try std.testing.expect(q.lpf.enabled.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), q.lpf.cutoff.load(.monotonic), 1e-6);
    // 未设置过的字段保持默认
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), q.decay.load(.monotonic), 1e-6);
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\": 140") != null);

    const parsed = try fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 2), parsed.value.version);
    try std.testing.expectEqual(@as(i32, 140), parsed.value.bpm);
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

    try std.testing.expectEqual(@as(u32, 2), parsed.value.version); // 已升级
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
    try std.testing.expectEqual(@as(usize, 0), parsed.value.clips.len);
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
