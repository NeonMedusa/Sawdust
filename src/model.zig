//! 数据模型与纯逻辑：片段 / 音符 / 乐器 + 坐标换算、重叠检测、裁剪。
//!
//! 本模块**不依赖 UI**（只依赖 std），全部可单测。
//! 坐标约定见各结构体注释（全局 = 播放列表小节；局部 = 样式内部小节/步）。

const std = @import("std");
const synth = @import("synth.zig");

/// 播放列表中的一个样式片段。
///
/// **坐标系**（重要）：
/// - 播放列表小节 = **全局坐标**：`bar`（起始，1 起）、`len`（可见长度）都用它；
/// - 片段内部小节 = **局部坐标**：双击打开钢琴卷帘时，卷帘里的小节号；
///   音符数据存在局部坐标里，左缘折叠只是改变“显示窗口”，不动内容。
/// - 换算：局部 = 全局 − `bar` + `offset`；全局 = 局部 + `bar` − `offset`。
///
/// 约束（左缘拖动的语义）：
/// - `offset >= 0`：不能展开到局部第 0 小节之前
///   （凭空往左 = 造出内容里不存在的音符位置，不对）；
/// - 折叠右移 `offset` 增大、`len` 减小（右端不动）；展开反之。
pub const Clip = struct {
    track: i32, // 轨道序号（0 起，全局）
    bar: i32, // 起始小节（全局坐标，1 起）
    len: i32, // 可见长度（全局小节数）
    pattern: i32, // 样式序号（0 起）
    offset: i32 = 0, // 左缘对应的局部小节号（0 = 从片段自身第 1 小节开始）
};

/// 钢琴卷帘中的音符（**局部坐标**，按样式 + 乐器归属）。
/// step：局部步（每小节 16 步，0 = 样式自身第 1 小节第 1 步）；
/// pitch：MIDI 音高（0-127，越大越高）。
/// 片段（Clip）只是样式的“窗口”（bar/len/offset 决定显示哪一段），音符本身归样式。
pub const Note = struct {
    step: i32, // 局部起始步（每小节 16 步）
    len: i32, // 长度（步，>= 1）
    pitch: i32, // MIDI 音高（0-127）
    pattern: i32, // 所属样式序号
    instrument: i32 = 0, // 所属乐器（通道机架槽位，0 起）
};

/// 乐器（通道机架中的一个槽位）。
/// `synth` 指向该乐器自己的合成器参数（堆分配、地址稳定——音频线程可安全读取）。
pub const Instrument = struct {
    name: []const u8, // 显示名（堆分配；由 App 管理生命周期）
    volume: f32 = 0.8, // 0-1
    pan: f32 = 0.5, // 0-1（0.5 = 居中）
    muted: bool = false,
    mixer: i32 = 1, // 混音通道（占位）
    synth: *synth.SynthParams, // 每乐器独立的合成器参数
};

/// **每全音符的份数**（分辨率 `U`）：数据层的时间单位。
/// `96 = 2⁵ × 3`——可精确表示的分母 = 96 的约数：
/// {1,2,3,4,6,8,12,16,24,32,48,96}——涵盖二进制细分与三连音体系。
/// `Note.step`、`Clip.bar`（小节）等均以它为单位。
pub const units_per_whole: i32 = 96;

/// 默认每小节步数（4/4 → 96 步；实际用 `App.steps_per_bar`）
pub const steps_per_bar: i32 = units_per_whole;

/// 拍号 → 每小节步数（`units_per_whole` 单位）。
/// `steps = num × (U / den)`；当 `den` 不整除 `U` 时会截断（UI 只允许 2 的幂分母，故不会发生）。
pub fn stepsPerBarFor(numerator: i32, denominator: i32) i32 {
    const num = std.math.clamp(numerator, 1, 32);
    const den = std.math.clamp(denominator, 1, units_per_whole);
    return @max(1, num * @divTrunc(units_per_whole, den));
}

/// 每拍步数（用于画拍线）：`U / den`
pub fn stepsPerBeat(denominator: i32) i32 {
    return @max(1, @divTrunc(units_per_whole, std.math.clamp(denominator, 1, units_per_whole)));
}

test "stepsPerBarFor / stepsPerBeat：常用拍号（U=96）" {
    // 4/4 = 96 步；每拍 24
    try std.testing.expectEqual(@as(i32, 96), stepsPerBarFor(4, 4));
    try std.testing.expectEqual(@as(i32, 24), stepsPerBeat(4));
    // 3/4 = 72 步；每拍 24
    try std.testing.expectEqual(@as(i32, 72), stepsPerBarFor(3, 4));
    // 6/8 = 6 × 12 = 72 步（= 3/4 的小节长度，正确的等价关系）
    try std.testing.expectEqual(@as(i32, 72), stepsPerBarFor(6, 8));
    try std.testing.expectEqual(@as(i32, 12), stepsPerBeat(8));
    // 2/4 = 48；每拍 24
    try std.testing.expectEqual(@as(i32, 48), stepsPerBarFor(2, 4));
    // 4/2 = 192；每拍 48
    try std.testing.expectEqual(@as(i32, 192), stepsPerBarFor(4, 2));
    try std.testing.expectEqual(@as(i32, 48), stepsPerBeat(2));
}

/// 找该样式**最靠左**的片段（无则为 null）。
/// 用于 SONG 模式下把“钢琴卷帘游标”换算为全局位置。
pub fn leftmostClipFor(clips: []const Clip, pattern: i32) ?Clip {
    var best: ?Clip = null;
    for (clips) |c| {
        if (c.pattern != pattern) continue;
        if (best == null or c.bar < best.?.bar) best = c;
    }
    return best;
}

/// 全局步 → 片段内的**局部**步（不在片段可见范围内 → null）。
/// `spb`：每小节步数（拍号决定；默认 16 = 4/4）。
pub fn clipSongToLocal(c: Clip, song_step: i32, spb: i32) ?i32 {
    const start = (c.bar - 1) * spb;
    const len_steps = c.len * spb;
    if (song_step < start or song_step >= start + len_steps) return null;
    return song_step - start + c.offset * spb;
}

/// 局部步 → 全局步（不在片段可见范围内 → null）
pub fn clipLocalToSong(c: Clip, local_step: i32, spb: i32) ?i32 {
    const lo = c.offset * spb;
    const hi = lo + c.len * spb;
    if (local_step < lo or local_step >= hi) return null;
    return (c.bar - 1) * spb + (local_step - lo);
}

test "游标换算：最左片段 / 全局↔局部 / 折叠截断" {
    const clips = [_]Clip{
        .{ .track = 0, .bar = 7, .len = 4, .pattern = 0 },
        .{ .track = 1, .bar = 3, .len = 4, .pattern = 0 }, // 更靠左
        .{ .track = 2, .bar = 2, .len = 2, .pattern = 1 },
    };
    const c = leftmostClipFor(&clips, 0).?;
    try std.testing.expectEqual(@as(i32, 3), c.bar);
    try std.testing.expect(leftmostClipFor(&clips, 9) == null);

    // 全局步 32（片段 bar3 的第 1 步）→ 局部 0
    const c0 = Clip{ .track = 0, .bar = 3, .len = 4, .pattern = 0 };
    try std.testing.expectEqual(@as(i32, 0), clipSongToLocal(c0, 32, 16).?);
    try std.testing.expectEqual(@as(i32, 16), clipSongToLocal(c0, 48, 16).?); // bar4
    try std.testing.expect(clipSongToLocal(c0, 31, 16) == null); // 片段左界外
    try std.testing.expect(clipSongToLocal(c0, 96, 16) == null); // 片段右界外
    try std.testing.expectEqual(@as(i32, 32), clipLocalToSong(c0, 0, 16).?);
    try std.testing.expect(clipLocalToSong(c0, 64, 16) == null);

    // 折叠：offset=1、len=3 → 可见局部 [16, 64)
    const fold = Clip{ .track = 0, .bar = 5, .len = 3, .pattern = 0, .offset = 1 };
    try std.testing.expect(clipLocalToSong(fold, 15, 16) == null); // 被折叠部分不可设置
    try std.testing.expectEqual(@as(i32, 64), clipLocalToSong(fold, 16, 16).?);
    try std.testing.expectEqual(@as(i32, 95), clipLocalToSong(fold, 47, 16).?);
    try std.testing.expectEqual(@as(i32, 96), clipLocalToSong(fold, 48, 16).?); // 仍在可见范围内（3 小节 = 48 步）
    try std.testing.expectEqual(@as(i32, 111), clipLocalToSong(fold, 63, 16).?); // 可见最后一步
    try std.testing.expect(clipLocalToSong(fold, 64, 16) == null); // 超出可见末小节
    try std.testing.expectEqual(@as(i32, 16), clipSongToLocal(fold, 64, 16).?);
}

/// 值域映射（minimap 的纵向压缩）：把 `[min_v, max_v]` 归一化到 `[0, 1]`。
/// 适用于任何有纵向语义的序号：**音高**（钢琴卷帘/机架 minimap）、**轨道**（播放列表 minimap）。
/// - **保底范围** `min_range`：值域过窄（或只有一个值）时扩到该宽度，
///   否则 minimap 会看起来像“通高块”；
/// - 以值域**中点**为中心扩展（内容居中，视觉最自然）。
pub const RangeMap = struct {
    span: i32,
    lo: i32,

    /// 值 → 归一化位置（自动钳制到 [0,1]）
    pub fn yOf(self: RangeMap, v: i32) f32 {
        const t = @as(f32, @floatFromInt(v - self.lo)) / @as(f32, @floatFromInt(@max(1, self.span)));
        return std.math.clamp(t, 0, 1);
    }
};

/// 计算值域映射（见 `RangeMap` 注释）
pub fn rangeMap(min_v: i32, max_v: i32, min_range: i32) RangeMap {
    const span = @max(@max(1, min_range), max_v - min_v);
    const mid = @divTrunc(min_v + max_v, 2);
    return .{ .span = span, .lo = mid - @divTrunc(span, 2) };
}

test "rangeMap: 保底范围 + 中点扩展 + 映射" {
    // 只有一个值 → 扩到保底范围，居中（y = 0.5）
    {
        const r = rangeMap(60, 60, 12);
        try std.testing.expectEqual(@as(i32, 12), r.span);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.yOf(60), 0.001);
    }
    // 宽值域 → 用实际范围（低 0、高 1）
    {
        const r = rangeMap(48, 72, 12);
        try std.testing.expectEqual(@as(i32, 24), r.span);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), r.yOf(48), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.yOf(72), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.yOf(60), 0.001);
    }
    // 窄值域（差异小于保底）→ 居中分布、不贴边
    {
        const r = rangeMap(60, 63, 12);
        try std.testing.expectEqual(@as(i32, 12), r.span);
        const y0 = r.yOf(60);
        const y1 = r.yOf(63);
        try std.testing.expect(y0 > 0.3 and y0 < 0.5);
        try std.testing.expect(y1 > 0.5 and y1 < 0.7);
    }
    // 超界值 → 钳制（不溢出）
    {
        const r = rangeMap(48, 60, 12);
        try std.testing.expectEqual(@as(f32, 1.0), r.yOf(200));
        try std.testing.expectEqual(@as(f32, 0.0), r.yOf(-100));
    }
}

/// 片段命中模式：中部（拖动）/ 左缘（折叠展开）/ 右缘（改长度）
pub const ClipHitMode = enum { body, left, right };

/// 音符命中模式：中部（移动）/ 左缘（改起点+长度，右端不动）/ 右缘（改长度）
pub const NoteHitMode = enum { body, left, right };

/// MIDI 音高 → 频率（Hz）；A4 = 440Hz（转发 synth 的实现，避免两处实现）
pub const pitchHz = @import("synth.zig").pitchHz;

/// 音名（MIDI 音高 → 如 "C4"）。用于钢琴键标签。
pub fn pitchName(buf: []u8, pitch: i32) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const pc = @mod(pitch, 12);
    const octave = @divFloor(pitch, 12) - 1; // MIDI 60 = C4
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[@intCast(pc)], octave }) catch "";
}

/// 是否为黑键（C#/D#/F#/G#/A#）
pub fn isBlackKey(pitch: i32) bool {
    const pc = @mod(pitch, 12);
    return pc == 1 or pc == 3 or pc == 6 or pc == 8 or pc == 10;
}

/// 片段是否与其它片段重叠（排除 exclude 下标；exclude == len 表示不排除任何）
pub fn clipOverlaps(clips: []const Clip, exclude: usize, track: i32, bar: i32, len: i32) bool {
    for (clips, 0..) |o, oi| {
        if (oi == exclude or o.track != track) continue;
        if (bar < o.bar + o.len and o.bar < bar + len) return true;
    }
    return false;
}

/// 左缘裁剪/展开：`new_bar` 为鼠标所在小节（**全局坐标**）。
/// 折叠 = offset 增大、len 减小（右端不动）；展开反之。
/// 约束：offset >= 0（局部坐标不能为负——不能展开到自身第 1 小节之前）、len >= 1。
/// 无效返回 null（调用方保持原样）。
pub fn clipTrimLeft(c: Clip, new_bar: i32) ?Clip {
    const delta = new_bar - c.bar;
    const new_offset = c.offset + delta;
    const new_len = c.len - delta;
    if (new_offset < 0 or new_len < 1) return null;
    var r = c;
    r.bar = new_bar;
    r.offset = new_offset;
    r.len = new_len;
    return r;
}

/// 音符是否与同样式、同乐器、同音高的其它音符重叠（排除 exclude 下标）
pub fn noteOverlaps(notes: []const Note, exclude: usize, pattern: i32, instrument: i32, step: i32, len: i32, pitch: i32) bool {
    for (notes, 0..) |o, oi| {
        if (oi == exclude or o.pattern != pattern or o.instrument != instrument or o.pitch != pitch) continue;
        if (step < o.step + o.len and o.step < step + len) return true;
    }
    return false;
}

/// 拖音符左缘：改起点+长度（右端固定）。
/// `new_step` 为鼠标所在步（局部坐标）；约束：`0 <= new_step <= right-1`（不能撞出局部第 1 步）。
/// 无效返回 null（调用方保持原样）。
pub fn noteTrimLeft(n: Note, new_step: i32, right: i32) ?Note {
    const s = std.math.clamp(new_step, 0, right - 1);
    if (s == n.step) return null;
    var r = n;
    r.step = s;
    r.len = right - s;
    return r;
}

// ── 测试 ──

test "pitchHz: A4 = 440、八度翻倍" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), pitchHz(69), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 880.0), pitchHz(81), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 220.0), pitchHz(57), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), pitchHz(60), 0.01); // C4
}

test "pitchName / isBlackKey" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("C4", pitchName(&buf, 60));
    try std.testing.expectEqualStrings("C#4", pitchName(&buf, 61));
    try std.testing.expectEqualStrings("A4", pitchName(&buf, 69));
    try std.testing.expectEqualStrings("C-1", pitchName(&buf, 0));
    try std.testing.expect(!isBlackKey(60)); // C
    try std.testing.expect(isBlackKey(61)); // C#
    try std.testing.expect(!isBlackKey(62)); // D
    try std.testing.expect(isBlackKey(66)); // F#
}

test "clipOverlaps: 重叠检测、排除自身、不同轨道" {
    const clips = [_]Clip{
        .{ .track = 0, .bar = 5, .len = 4, .pattern = 0 }, // 占 5-8
    };
    try std.testing.expect(clipOverlaps(&clips, clips.len, 0, 6, 2)); // 与首片段重叠
    try std.testing.expect(clipOverlaps(&clips, clips.len, 0, 4, 2)); // 左缘相接处重叠（4-5 与 5-8）
    try std.testing.expect(!clipOverlaps(&clips, clips.len, 0, 9, 2)); // 紧邻右侧不重叠
    try std.testing.expect(!clipOverlaps(&clips, clips.len, 1, 5, 2)); // 不同轨道
    try std.testing.expect(!clipOverlaps(&clips, 0, 0, 5, 4)); // 排除自身
}

test "clipTrimLeft: 左缘折叠/展开（不能超过自身第 1 小节）" {
    const c0 = Clip{ .track = 0, .bar = 5, .len = 8, .pattern = 0 };

    // 向右折叠 2 小节：offset +2、len -2、右端（5+8=13）不动
    const folded = clipTrimLeft(c0, 7).?;
    try std.testing.expectEqual(@as(i32, 7), folded.bar);
    try std.testing.expectEqual(@as(i32, 2), folded.offset);
    try std.testing.expectEqual(@as(i32, 6), folded.len);
    try std.testing.expectEqual(c0.bar + c0.len, folded.bar + folded.len);

    // 再展开回来（offset 归 0、len 复原）
    const unfolded = clipTrimLeft(folded, 5).?;
    try std.testing.expectEqual(@as(i32, 0), unfolded.offset);
    try std.testing.expectEqual(@as(i32, 8), unfolded.len);

    // 凭空向左超过自身第 1 小节 → 拒绝
    try std.testing.expect(clipTrimLeft(c0, 4) == null);
    // 折叠后最多展开回自身第 1 小节（anchor = 5）：到 5 可以、到 4 不行
    try std.testing.expect(clipTrimLeft(folded, 5) != null);
    try std.testing.expect(clipTrimLeft(folded, 4) == null);
    // 折叠到不足 1 小节 → 拒绝（最多折到 bar 12）
    try std.testing.expect(clipTrimLeft(c0, 12) != null);
    try std.testing.expect(clipTrimLeft(c0, 13) == null);
}

test "noteTrimLeft: 左缘自由拖动（右端固定、不撞出第 1 步）" {
    const n0 = Note{ .step = 8, .len = 8, .pitch = 60, .pattern = 0 }; // 占 8-15
    const right = n0.step + n0.len; // 16

    // 向左扩到步 4：step 4、len 12、右端不动
    const grew = noteTrimLeft(n0, 4, right).?;
    try std.testing.expectEqual(@as(i32, 4), grew.step);
    try std.testing.expectEqual(@as(i32, 12), grew.len);
    try std.testing.expectEqual(right, grew.step + grew.len);

    // 向右收到步 12：step 12、len 4
    const shrunk = noteTrimLeft(n0, 12, right).?;
    try std.testing.expectEqual(@as(i32, 12), shrunk.step);
    try std.testing.expectEqual(@as(i32, 4), shrunk.len);
    try std.testing.expectEqual(right, shrunk.step + shrunk.len);

    // 拖到第 1 步左边 → 限在 0（len = 16）
    const clamped = noteTrimLeft(n0, -5, right).?;
    try std.testing.expectEqual(@as(i32, 0), clamped.step);
    try std.testing.expectEqual(@as(i32, 16), clamped.len);

    // 拖到右端或越过 → 至少留 1 步（step = right-1）
    const minned = noteTrimLeft(n0, 999, right).?;
    try std.testing.expectEqual(@as(i32, 15), minned.step);
    try std.testing.expectEqual(@as(i32, 1), minned.len);

    // 无变化 → null
    try std.testing.expect(noteTrimLeft(n0, 8, right) == null);
}

test "noteOverlaps: 同音高重叠检测、排除自身、不同音高/样式" {
    const notes = [_]Note{
        .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 },
        .{ .step = 8, .len = 4, .pitch = 62, .pattern = 0 },
    };
    try std.testing.expect(noteOverlaps(&notes, notes.len, 0, 0, 2, 4, 60)); // 与首音符重叠
    try std.testing.expect(!noteOverlaps(&notes, notes.len, 0, 0, 4, 4, 60)); // 紧邻右侧不重叠
    try std.testing.expect(!noteOverlaps(&notes, notes.len, 0, 0, 2, 4, 61)); // 不同音高
    try std.testing.expect(!noteOverlaps(&notes, notes.len, 1, 0, 2, 4, 60)); // 不同样式
    try std.testing.expect(!noteOverlaps(&notes, notes.len, 0, 1, 2, 4, 60)); // 不同乐器
    try std.testing.expect(!noteOverlaps(&notes, 0, 0, 0, 0, 4, 60)); // 排除自身
}
