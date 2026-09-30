//! 数据模型与纯逻辑：片段 / 音符 / 乐器 + 坐标换算、重叠检测、裁剪。
//!
//! 本模块**不依赖 UI**（只依赖 std），全部可单测。
//! 坐标约定见各结构体注释（全局 = 播放列表小节；局部 = 样式内部小节/步）。

const std = @import("std");
const synth = @import("synth.zig");

/// 播放列表中的一个样式片段。
///
/// **坐标系**（重要）：
/// - 播放列表 = **全局坐标**（单位 = `units_per_whole` 步；96 = 4/4 一小节）：
///   `start`（起始步，0 起）、`len`（可见长度，步）、`offset`（左缘对应的局部步）；
/// - 片段内部 = **局部坐标**（钢琴卷帘里的步）：音符数据在局部坐标，
///   左缘折叠只是改变“显示窗口”，不动内容。
/// - 换算：局部 = 全局 − `start` + `offset`；全局 = 局部 + `start` − `offset`。
///
/// 约束（左缘拖动的语义）：
/// - `offset >= 0`：不能展开到局部第 0 步之前
///   （凭空往左 = 造出内容里不存在的音符位置，不对）；
/// - 折叠右移 `offset` 增大、`len` 减小（右端不动）；展开反之。
pub const Clip = struct {
    track: i32, // 轨道序号（0 起）
    start: i32, // 起始步（全局坐标，0 起；U=96 单位）
    len: i32, // 可见长度（步，>= 1）
    pattern: i32, // 样式序号（0 起）
    offset: i32 = 0, // 左缘对应的局部步（0 = 从片段自身第 1 步开始）
};

/// 钢琴卷帘中的音符（**局部坐标**，按样式 + 乐器归属）。
/// step：局部步（U=96 单位，0 = 样式自身第 1 步）；
/// pitch：MIDI 音高（0-127，越大越高）。
/// 片段（Clip）只是样式的“窗口”（start/len/offset 决定显示哪一段），音符本身归样式。
pub const Note = struct {
    step: i32, // 局部起始步（U=96 单位）
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
/// `Note.step`、`Clip.start/len/offset` 均以它为单位。
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
        if (best == null or c.start < best.?.start) best = c;
    }
    return best;
}

/// 全局步 → 片段内的**局部**步（不在片段可见范围内 → null）。
/// 注：片段与音符现已同为 **U=96 步**坐标，无需再乘每小节步数。
pub fn clipSongToLocal(c: Clip, song_step: i32) ?i32 {
    if (song_step < c.start or song_step >= c.start + c.len) return null;
    return song_step - c.start + c.offset;
}

/// 局部步 → 全局步（不在片段可见范围内 → null）
pub fn clipLocalToSong(c: Clip, local_step: i32) ?i32 {
    const lo = c.offset;
    const hi = lo + c.len;
    if (local_step < lo or local_step >= hi) return null;
    return c.start + (local_step - lo);
}

test "游标换算：最左片段 / 全局↔局部 / 折叠截断" {
    const B: i32 = units_per_whole; // 一小节（4/4）= 96 步
    const clips = [_]Clip{
        .{ .track = 0, .start = 6 * B, .len = 4 * B, .pattern = 0 },
        .{ .track = 1, .start = 2 * B, .len = 4 * B, .pattern = 0 }, // 更靠左
        .{ .track = 2, .start = B, .len = 2 * B, .pattern = 1 },
    };
    const c = leftmostClipFor(&clips, 0).?;
    try std.testing.expectEqual(2 * B, c.start);
    try std.testing.expect(leftmostClipFor(&clips, 9) == null);

    // 片段从第 3 小节（步 2B）开始：全局 2B → 局部 0
    const c0 = Clip{ .track = 0, .start = 2 * B, .len = 4 * B, .pattern = 0 };
    try std.testing.expectEqual(@as(i32, 0), clipSongToLocal(c0, 2 * B).?);
    try std.testing.expectEqual(B, clipSongToLocal(c0, 3 * B).?);
    try std.testing.expect(clipSongToLocal(c0, 2 * B - 1) == null); // 片段左界外
    try std.testing.expect(clipSongToLocal(c0, 6 * B) == null); // 片段右界外
    try std.testing.expectEqual(2 * B, clipLocalToSong(c0, 0).?);
    try std.testing.expect(clipLocalToSong(c0, 4 * B) == null);

    // 折叠：offset = B（折叠 1 小节）、len = 3B → 可见局部 [B, 4B)
    const fold = Clip{ .track = 0, .start = 4 * B, .len = 3 * B, .pattern = 0, .offset = B };
    try std.testing.expect(clipLocalToSong(fold, B - 1) == null); // 被折叠部分不可设置
    try std.testing.expectEqual(4 * B, clipLocalToSong(fold, B).?);
    try std.testing.expectEqual(4 * B + 2 * B - 1, clipLocalToSong(fold, 3 * B - 1).?);
    try std.testing.expect(clipLocalToSong(fold, 4 * B) == null); // 超出可见末小节
    try std.testing.expectEqual(B, clipSongToLocal(fold, 4 * B).?);
}

/// **量化/吸附网格**：分母（1/1 … 1/96）→ 步数（U=96 单位）。
/// 只列可整除 U 的分母（1/64 不可整除故不含）。
/// 0 = 关闭吸附（自由精度）。
pub const snap_denoms = [_]i32{ 1, 2, 4, 8, 16, 32, 3, 6, 12, 24, 48, 96 };

/// 档位下标 → 步数（每格多少步）
pub fn snapSteps(idx: i32) i32 {
    if (idx < 0 or idx >= snap_denoms.len) return 1;
    const d = snap_denoms[@intCast(idx)];
    return @max(1, @divTrunc(units_per_whole, d)); // 96/d：1/96→1 步、1/1→96 步
}

/// 把步对齐到网格（向下取整）；`steps` = 网格步数
pub fn snapFloor(step: i32, steps: i32) i32 {
    if (steps <= 1) return step;
    return @divFloor(step, steps) * steps;
}

/// 把步对齐到网格（就近取整）
pub fn snapRound(step: i32, steps: i32) i32 {
    if (steps <= 1) return step;
    return @divFloor(step + @divTrunc(steps, 2), steps) * steps;
}

/// 把步对齐到网格（向上取整）；`steps` = 网格步数
pub fn snapCeil(step: i32, steps: i32) i32 {
    if (steps <= 1) return step;
    return @divFloor(step + steps - 1, steps) * steps;
}

/// **拉伸边缘的“已越过格线”吸附**：`edge` = 边缘当前步，`mouse` = 鼠标所在步。
/// 边缘只落到**鼠标已经越过**的格线上：
/// - 鼠标在边缘右侧：`max(edge, ≤鼠标的最近格线)`——鼠标走满一格才向右延一格；
/// - 鼠标在边缘左侧：`min(edge, ≥鼠标的最近格线)`——向左同理。
///
/// 动机（实测事故）：若直接取“离鼠标最近的格线”，
/// **本来就比一格短的音符/片段**（如 1/32 音符在 1/1 网格下）
/// 只需移动几像素就会被吸到远处小节线——鼠标根本没走过“一格”的距离。
/// 改成本规则后，拉长一格必须真的走满一格。
pub fn snapEdgeCrossed(edge: i32, mouse: i32, steps: i32) i32 {
    if (mouse >= edge) return @max(edge, snapFloor(mouse, steps));
    return @min(edge, snapCeil(mouse, steps));
}

/// **拉伸下限**（每帧重算）：
/// - 长度 < 一格（网格调粗后遗留的短音符/片段）：下限 = `min(原长, 一格)`——
///   按下**不会**被强行拉长（“按下一格就跳成整格”是实测 bug），也不允许比原来更短；
/// - 长度 ≥ 一格：下限升为**一格**（放行拉长、阻止收回——收回不得低于一格）。
pub fn trimMinLen(orig_len: i32, cur_len: i32, snap_steps: i32) i32 {
    const grid = @max(1, snap_steps);
    if (cur_len >= grid) return grid;
    return @max(1, @min(orig_len, grid));
}

test "snapSteps / snapFloor / snapRound（U=96）" {
    // 档位 → 步数：1/1 = 96、1/4 = 24、1/8 = 12、1/3 = 32、1/12 = 8、1/96 = 1
    try std.testing.expectEqual(@as(i32, 96), snapSteps(0)); // 1/1
    try std.testing.expectEqual(@as(i32, 24), snapSteps(2)); // 1/4
    try std.testing.expectEqual(@as(i32, 12), snapSteps(3)); // 1/8
    try std.testing.expectEqual(@as(i32, 32), snapSteps(6)); // 1/3（三连音）
    try std.testing.expectEqual(@as(i32, 8), snapSteps(8)); // 1/12
    try std.testing.expectEqual(@as(i32, 1), snapSteps(11)); // 1/96

    // 对齐：1/4 网格（24 步）
    try std.testing.expectEqual(@as(i32, 0), snapFloor(5, 24));
    try std.testing.expectEqual(@as(i32, 24), snapFloor(30, 24));
    try std.testing.expectEqual(@as(i32, 24), snapRound(30, 24));
    try std.testing.expectEqual(@as(i32, 48), snapRound(40, 24));
    // 网格 = 1 步时不改动
    try std.testing.expectEqual(@as(i32, 37), snapFloor(37, 1));
    try std.testing.expectEqual(@as(i32, 37), snapRound(37, 1));
}

test "snapCeil / snapEdgeCrossed: 边缘只吸已越过的格线（短音符不再一碰就跳）" {
    // snapCeil：1/4 网格（24 步）
    try std.testing.expectEqual(@as(i32, 24), snapCeil(5, 24));
    try std.testing.expectEqual(@as(i32, 24), snapCeil(24, 24));
    try std.testing.expectEqual(@as(i32, 48), snapCeil(25, 24));
    try std.testing.expectEqual(@as(i32, 0), snapCeil(-1, 24));

    // **实测事故回归**：1/32 音符（右缘 = 3 步）+ 1/1 网格（96 步）
    // 鼠标在 3..95 游走 → 边缘必须原地不动（不能吸到 0 或 96）
    try std.testing.expectEqual(@as(i32, 3), snapEdgeCrossed(3, 3, 96));
    try std.testing.expectEqual(@as(i32, 3), snapEdgeCrossed(3, 50, 96));
    try std.testing.expectEqual(@as(i32, 3), snapEdgeCrossed(3, 95, 96));
    // 到达/越过小节线 96 → 吸到 96；再往上要越过 192
    try std.testing.expectEqual(@as(i32, 96), snapEdgeCrossed(3, 96, 96));
    try std.testing.expectEqual(@as(i32, 96), snapEdgeCrossed(96, 191, 96));
    try std.testing.expectEqual(@as(i32, 192), snapEdgeCrossed(96, 192, 96));
    // 回拉：在 1..96 之间不动；到达/越过 0 才缩回
    try std.testing.expectEqual(@as(i32, 96), snapEdgeCrossed(96, 50, 96));
    try std.testing.expectEqual(@as(i32, 96), snapEdgeCrossed(96, 1, 96));
    try std.testing.expectEqual(@as(i32, 0), snapEdgeCrossed(96, 0, 96));
    try std.testing.expectEqual(@as(i32, 0), snapEdgeCrossed(96, -1, 96));

    // 已在格线上（1/4 网格，边缘 = 24）：走满 24 步才延到 48
    try std.testing.expectEqual(@as(i32, 24), snapEdgeCrossed(24, 47, 24));
    try std.testing.expectEqual(@as(i32, 48), snapEdgeCrossed(24, 48, 24));
    // 自由精度（1 步网格）：直接跟随鼠标
    try std.testing.expectEqual(@as(i32, 77), snapEdgeCrossed(24, 77, 1));
    try std.testing.expectEqual(@as(i32, 3), snapEdgeCrossed(77, 3, 1));
}

test "trimMinLen: 短音符不被动拉长；达到一格后收回不得低于一格" {
    // 1/32 音符（3 步）+ 1/1 网格（96 步）
    try std.testing.expectEqual(@as(i32, 3), trimMinLen(3, 3, 96)); // 按下：下限 = 原长
    try std.testing.expectEqual(@as(i32, 96), trimMinLen(3, 96, 96)); // 已延到一格 → 升为一格
    // 1/8 音符（12 步）+ 1/4 网格（24 步）
    try std.testing.expectEqual(@as(i32, 12), trimMinLen(12, 12, 24));
    try std.testing.expectEqual(@as(i32, 24), trimMinLen(12, 24, 24)); // 延到一格 → 阻止收回
    // 长于一格：下限 = 一格
    try std.testing.expectEqual(@as(i32, 96), trimMinLen(300, 300, 96));
    // 自由精度（1 步）
    try std.testing.expectEqual(@as(i32, 1), trimMinLen(5, 5, 1));
}

test "拉伸手感（回归）：走满一格才延、按下不拉长、延后收回被阻止" {
    const grid = snapSteps(0); // 1/1 = 96
    // 场景 1：1/32 音符（3 步，起点 0）+ 1/1 网格
    const len0: i32 = 3;
    // 按下：下限 = 3 → 不拉长
    try std.testing.expectEqual(@as(i32, 3), trimMinLen(len0, len0, grid));
    // 鼠标在下一格线之前游走：右缘不动
    var edge: i32 = len0;
    for ([_]i32{ len0, 50, 95 }) |m| {
        edge = @max(len0, snapEdgeCrossed(edge, m, grid)); // 下限 = 原长
        try std.testing.expectEqual(@as(i32, 3), edge);
    }
    // 鼠标越过后面的格线：右缘吸到该线（必须真的走满一格）
    edge = @max(len0, snapEdgeCrossed(edge, grid, grid));
    try std.testing.expectEqual(@as(i32, 96), edge);
    // 达到一格 → 下限升为一格 → 收回被阻止
    const min2 = trimMinLen(len0, edge - 0, grid);
    try std.testing.expectEqual(@as(i32, 96), min2);
    for ([_]i32{ 95, 50, 0 }) |m| {
        edge = @max(0 + min2, snapEdgeCrossed(edge, m, grid));
        try std.testing.expectEqual(@as(i32, 96), edge);
    }

    // 场景 2：1/8 音符（12 步，起点 0）+ 1/4 网格（24 步）——“放行拉长、阻止收回”
    const g2: i32 = snapSteps(2); // 24
    try std.testing.expectEqual(@as(i32, 12), trimMinLen(12, 12, g2)); // 按下不拉长
    try std.testing.expectEqual(@as(i32, 12), @max(12, snapEdgeCrossed(12, 23, g2))); // 未到格线：不动
    const e3 = @max(12, snapEdgeCrossed(12, 24, g2));
    try std.testing.expectEqual(@as(i32, 24), e3); // 到格线：延到 24
    const min3 = trimMinLen(12, e3, g2);
    try std.testing.expectEqual(@as(i32, 24), min3); // 升为一格
    try std.testing.expectEqual(@as(i32, 24), @max(min3, snapEdgeCrossed(e3, 0, g2))); // 收回被阻止（不再缩回 12）
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

/// 片段是否与其它片段重叠（排除 exclude 下标；exclude == len 表示不排除任何）。
/// 坐标单位：步（U=96）——区间为 `[start, start+len)`。
pub fn clipOverlaps(clips: []const Clip, exclude: usize, track: i32, start: i32, len: i32) bool {
    for (clips, 0..) |o, oi| {
        if (oi == exclude or o.track != track) continue;
        if (start < o.start + o.len and o.start < start + len) return true;
    }
    return false;
}

/// 左缘裁剪/展开：`new_start` 为鼠标所在步（**全局坐标**）。
/// 折叠 = offset 增大、len 减小（右端不动）；展开反之。
/// 约束：offset >= 0（局部坐标不能为负——不能展开到自身第 1 步之前）、
/// `len >= min_len`（通常 = 吸附格——不能折得比一格还短）。
/// 无效返回 null（调用方保持原样）。
pub fn clipTrimLeft(c: Clip, new_start: i32, min_len: i32) ?Clip {
    const min_l = @max(1, min_len);
    const delta = new_start - c.start;
    const new_offset = c.offset + delta;
    const new_len = c.len - delta;
    if (new_offset < 0 or new_len < min_l) return null;
    var r = c;
    r.start = new_start;
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
/// `new_step` 为鼠标所在步（局部坐标）；`min_len` 为最短长度（通常 = 吸附格）。
/// 约束：`0 <= new_step <= right - min_len`（左缘不能右移超过最短长度）。
/// 无效返回 null（调用方保持原样）。
pub fn noteTrimLeft(n: Note, new_step: i32, right: i32, min_len: i32) ?Note {
    const min_l = @max(1, min_len);
    const s = std.math.clamp(new_step, 0, @max(0, right - min_l));
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
    const B: i32 = units_per_whole;
    const clips = [_]Clip{
        .{ .track = 0, .start = 4 * B, .len = 4 * B, .pattern = 0 }, // 占 [4B, 8B)
    };
    try std.testing.expect(clipOverlaps(&clips, clips.len, 0, 5 * B, 2 * B)); // 重叠
    try std.testing.expect(clipOverlaps(&clips, clips.len, 0, 3 * B, 2 * B)); // 左缘相接处重叠
    try std.testing.expect(!clipOverlaps(&clips, clips.len, 0, 8 * B, 2 * B)); // 紧邻右侧不重叠
    try std.testing.expect(!clipOverlaps(&clips, clips.len, 1, 5 * B, 2 * B)); // 不同轨道
    try std.testing.expect(!clipOverlaps(&clips, 0, 0, 4 * B, 4 * B)); // 排除自身
}

test "clipTrimLeft: 左缘折叠/展开（不能超过自身第 1 步、受最短长度约束）" {
    const B: i32 = units_per_whole;
    const c0 = Clip{ .track = 0, .start = 4 * B, .len = 8 * B, .pattern = 0 };

    // 向右折叠 2 小节：offset +2B、len -2B、右端（4B+8B=12B）不动
    const folded = clipTrimLeft(c0, 6 * B, 1).?;
    try std.testing.expectEqual(6 * B, folded.start);
    try std.testing.expectEqual(2 * B, folded.offset);
    try std.testing.expectEqual(6 * B, folded.len);
    try std.testing.expectEqual(c0.start + c0.len, folded.start + folded.len);

    // 再展开回来（offset 归 0、len 复原）
    const unfolded = clipTrimLeft(folded, 4 * B, 1).?;
    try std.testing.expectEqual(@as(i32, 0), unfolded.offset);
    try std.testing.expectEqual(8 * B, unfolded.len);

    // 凭空向左超过自身第 1 步 → 拒绝
    try std.testing.expect(clipTrimLeft(c0, 4 * B - 1, 1) == null);
    // 折叠后最多展开回自身第 1 步（anchor = 4B）：到 4B 可以、更小不行
    try std.testing.expect(clipTrimLeft(folded, 4 * B, 1) != null);
    try std.testing.expect(clipTrimLeft(folded, 4 * B - 1, 1) == null);
    // 步级折叠（U=96 精度）：右移 1 步也可以
    const fine = clipTrimLeft(c0, 4 * B + 1, 1).?;
    try std.testing.expectEqual(@as(i32, 1), fine.offset);
    try std.testing.expectEqual(8 * B - 1, fine.len);
    // 折叠到不足 1 步 → 拒绝（最多折到 start = 12B - 1）
    try std.testing.expect(clipTrimLeft(c0, 12 * B - 1, 1) != null);
    try std.testing.expect(clipTrimLeft(c0, 12 * B, 1) == null);

    // **最短长度约束**（如吸附格 = 1 小节）：最多折到 start = 12B - B
    const limited = clipTrimLeft(c0, 12 * B - B, B).?;
    try std.testing.expectEqual(B, limited.len); // 长度为 1 格
    try std.testing.expect(clipTrimLeft(c0, 12 * B - B + 1, B) == null);
}

test "noteTrimLeft: 左缘自由拖动（右端固定、不撞出第 1 步、受最短长度约束）" {
    const n0 = Note{ .step = 8, .len = 8, .pitch = 60, .pattern = 0 }; // 占 8-15
    const right = n0.step + n0.len; // 16

    // 向左扩到步 4：step 4、len 12、右端不动
    const grew = noteTrimLeft(n0, 4, right, 1).?;
    try std.testing.expectEqual(@as(i32, 4), grew.step);
    try std.testing.expectEqual(@as(i32, 12), grew.len);
    try std.testing.expectEqual(right, grew.step + grew.len);

    // 向右收到步 12：step 12、len 4
    const shrunk = noteTrimLeft(n0, 12, right, 1).?;
    try std.testing.expectEqual(@as(i32, 12), shrunk.step);
    try std.testing.expectEqual(@as(i32, 4), shrunk.len);
    try std.testing.expectEqual(right, shrunk.step + shrunk.len);

    // 拖到第 1 步左边 → 限在 0（len = 16）
    const clamped = noteTrimLeft(n0, -5, right, 1).?;
    try std.testing.expectEqual(@as(i32, 0), clamped.step);
    try std.testing.expectEqual(@as(i32, 16), clamped.len);

    // 拖到右端或越过 → 至少留 1 步（step = right-1）
    const minned = noteTrimLeft(n0, 999, right, 1).?;
    try std.testing.expectEqual(@as(i32, 15), minned.step);
    try std.testing.expectEqual(@as(i32, 1), minned.len);

    // **最短长度约束**（如吸附格 = 4 步）：左缘最多右移到 right - 4
    const limited = noteTrimLeft(n0, 999, right, 4).?;
    try std.testing.expectEqual(@as(i32, 12), limited.step);
    try std.testing.expectEqual(@as(i32, 4), limited.len); // 长度为 1 格
    // 最短 = 整段长度时（min_len >= len）无法再缩（step 不变 → null）
    try std.testing.expect(noteTrimLeft(n0, 15, right, 8) == null);

    // 无变化 → null
    try std.testing.expect(noteTrimLeft(n0, 8, right, 1) == null);
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
