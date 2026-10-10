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
    /// 框选/批量操作选中（**瞬态**：不存档）
    selected: bool = false,
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
    /// 力度（1-127；默认 100 = MIDI 惯例）——影响发声响度
    velocity: i32 = default_velocity,
    /// 声像（0-127；64 = 居中）——与 MIDI CC10 坐标一致
    pan: i32 = default_pan,
    /// 框选/批量操作选中（**瞬态**：不存档）
    selected: bool = false,
};

/// 默认力度（新音符；MIDI 惯例 100——柱条不顶格、有编辑余量）
pub const default_velocity: i32 = 100;
/// 默认声像（居中；= MIDI CC10 坐标）
pub const default_pan: i32 = 64;

/// 乐器（通道机架中的一个槽位）。
/// `synth` 指向该乐器自己的合成器参数（堆分配、地址稳定——音频线程可安全读取）。
pub const Instrument = struct {
    name: []const u8, // 显示名（堆分配；由 App 管理生命周期）
    volume: f32 = 0.8, // 0-1
    pan: f32 = 0.5, // 0-1（0.5 = 居中）
    muted: bool = false,
    /// 混音通道（**0 起**，对应调音台通道序号 0..n-1）
    mixer: i32 = 0,
    /// MIDI 通道（0-15；-1 = 无）——MIDI 导入时记住来源通道，
    /// 导出时优先按它写通道号（保证往返稳定）；手动建的乐器 = -1（导出用序号 mod 16）
    midi_channel: i32 = -1,
    synth: *synth.SynthParams, // 每乐器独立的合成器参数
};

/// 路由到混音通道 `ch`（**0 起**——与调音台标尺名、`Instrument.mixer`
/// 同一基准）的乐器名摘要：单个 = 该名；多个 = `首个 +N`；无 = 空串。
/// `buf` 供多乐器情形写入（≥ 64 字节足够）。
///
/// 提取为公用函数的动机：调音台右区抬头与效果器窗口标题都要这份摘要——
/// 两处曾经各写一份，效果器那份误用 `mixer == ch + 1`（把 0 起当 1 起），
/// 显示成**下一个通道**的乐器（实测 bug：通道 Bass 的 EQ 标题显示 CH2·Key）。
///
/// 注：**不能增量拼接**（`bufPrint(buf, "{s}+", .{inst_names})`）——第二次时
/// `inst_names` 已指向同一缓冲 → 源与目标别名 → 运行时 panic（实测：两个乐器
/// 都路由到同通道时，打开效果器面板必崩）。
pub fn routedInstrumentNames(insts: []const Instrument, ch: usize, buf: []u8) []const u8 {
    var first: ?[]const u8 = null;
    var total: usize = 0;
    for (insts) |inst| {
        if (inst.mixer != @as(i32, @intCast(ch))) continue;
        if (total == 0) first = inst.name;
        total += 1;
    }
    const f = first orelse return "";
    if (total == 1) return f;
    return std.fmt.bufPrint(buf, "{s} +{d}", .{ f, total - 1 }) catch f;
}

/// **每全音符的份数**（分辨率 `U`）：数据层的时间单位。
/// `96 = 2⁵ × 3`——可精确表示的分母 = 96 的约数：
/// {1,2,3,4,6,8,12,16,24,32,48,96}——涵盖二进制细分与三连音体系。
/// `Note.step`、`Clip.start/len/offset` 均以它为单位。
pub const units_per_whole: i32 = 96;

/// 默认每小节步数（4/4 → 96 步；实际用 `App.steps_per_bar`）
pub const steps_per_bar: i32 = units_per_whole;

/// 样式数量上限（样式列表动态增长，但不超过此值）。
/// 播放列表预览（音域统计数组）等固定缓冲按此设限。
/// 注：无类型常量（comptime_int）——既可作数组长度，也可参与 i32 运算。
pub const max_patterns = 32;

/// 新工程的默认样式数（“样式 1”…“样式 N”）。
pub const default_pattern_count = 6;

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

/// 局部步 → 全局步（**带鉗制**：超出片段窗口 → 鉗到窗口边缘）。
/// 用于“在局部视图（钢琴卷帘标尺）上设置全局区域（SONG 循环）”
pub fn clipLocalToSongClamped(c: Clip, local_step: i32) i32 {
    if (local_step < c.offset) return c.start;
    if (local_step >= c.offset + c.len) return c.start + c.len;
    return c.start + (local_step - c.offset);
}

/// 全局步 → 局部步（**带鉗制**）。用于“在局部视图上显示全局区域”
pub fn clipSongToLocalClamped(c: Clip, song_step: i32) i32 {
    if (song_step < c.start) return c.offset;
    if (song_step >= c.start + c.len) return c.offset + c.len;
    return c.offset + (song_step - c.start);
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

    // 鉗制版（循环区域跨出片段窗口的换算）：局部→全局、全局→局部都鉗到边缘
    try std.testing.expectEqual(4 * B, clipLocalToSongClamped(fold, B - 1)); // 左溢出 → 片段起点
    try std.testing.expectEqual(4 * B + 3 * B, clipLocalToSongClamped(fold, 9 * B)); // 右溢出 → 片段终点
    try std.testing.expectEqual(4 * B + B, clipLocalToSongClamped(fold, 2 * B)); // 窗口内：正常换算
    try std.testing.expectEqual(B, clipSongToLocalClamped(fold, 4 * B - 1)); // 左溢出 → offset
    try std.testing.expectEqual(4 * B, clipSongToLocalClamped(fold, 9 * B)); // 右溢出 → offset+len
    try std.testing.expectEqual(2 * B, clipSongToLocalClamped(fold, 5 * B)); // 窗口内：正常换算
    // 往返一致（窗口内）：局部 → 全局 → 局部 = 原值
    var lp: i32 = B;
    while (lp < 4 * B) : (lp += B) {
        try std.testing.expectEqual(lp, clipSongToLocalClamped(fold, clipLocalToSongClamped(fold, lp)));
    }
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

/// 位移（步）→ **网格倍数**（四舍五入到最近格：过半格即换一格；负数对称）。
/// “增量式”拉伸的换算基础：网格决定长度增减的**步长**
/// （网格 1/4 → 鼠标走约 1/4 小节，长度 ±1/4）。
pub fn gridSteps(delta_steps: i32, grid: i32) i32 {
    const g = @max(1, grid);
    if (g <= 1) return delta_steps; // 自由精度
    const half = @divTrunc(g, 2);
    if (delta_steps >= 0) return @divTrunc(delta_steps + half, g);
    return -@divTrunc(-delta_steps + half, g);
}

/// 拉伸下限（最小格点）：`原长 − k×格`（k >= 0）中仍 >= 1 的最小值。
/// 例：1/8 音符（12 步）+ 1/4 格（24 步）→ 12（拖不短）；1/2 音符 → 24。
/// 语义：只剩不足一格时**不能再减**（没有整格可减）。
pub fn trimMinGridLen(orig_len: i32, grid: i32) i32 {
    const g = @max(1, grid);
    const l = @max(1, orig_len);
    return l - @divFloor(l - 1, g) * g;
}

/// **拉伸长度（增量式）**：`长度 = 原长 + k×格`（`k = gridSteps`），钳到最小格点。
/// 长度永远落在“原长 ± 整数格”的格点上——不会中途跳到无关的拍线/小节线。
pub fn trimLenByGrid(orig_len: i32, delta_steps: i32, grid: i32) i32 {
    const g = @max(1, grid);
    const k = gridSteps(delta_steps, g);
    return @max(trimMinGridLen(orig_len, g), orig_len + k * g);
}

/// 批量缩短：长 `len` 的音符在网格 `g` 下**最多能缩短几格**。
/// 规则（与单音符一致：缩短后长度 = 原长 − k×格，且 >= “原长减去整数格后的最小正余”）：
/// `m = floor((len-1)/g)`——若 `len <= g` 则 m = 0（不能缩短）。
/// 批量操作取所有选中音符的 **min(m)**（有一个不够就整体不能缩）。
pub fn batchShortenMax(len: i32, grid: i32) i32 {
    const g = @max(1, grid);
    return @divFloor(@max(1, len) - 1, g);
}

/// 批量拉伸的**格数钳制**：
/// - `requested`：鼠标位移换算的格数（正 = 加长、负 = 缩短）；
/// - `shorten_cap`：全组最多能缩几格（= min over 组内 `batchShortenMax`，>= 0）；
/// - `extend_cap`：全组最多能延几格（>= 0；右缘拉伸传大值，左缘传
///   `min(step/g)`——不能越过样式开头）；
/// 返回钳制后的格数（保持符号）。
pub fn clampBatchK(requested: i32, shorten_cap: i32, extend_cap: i32) i32 {
    // 注：不能用 `@max(0, x)`——Zig 会把非负结果收窄成 u31，无法取负。
    const sc: i32 = if (shorten_cap > 0) shorten_cap else 0;
    const ec: i32 = if (extend_cap > 0) extend_cap else 0;
    if (requested < 0) return @max(requested, -sc);
    return @min(requested, ec);
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

test "gridSteps / trimMinGridLen / trimLenByGrid：增量式拉伸（网格 = 长度增减步长）" {
    // 位移 → 格数：**四舍五入**（过半格即换一格；负数对称）；网格 = 1 步时直接跟随
    try std.testing.expectEqual(@as(i32, 0), gridSteps(11, 24)); // 不足半格：不变
    try std.testing.expectEqual(@as(i32, 1), gridSteps(12, 24)); // 半格：进一格
    try std.testing.expectEqual(@as(i32, 1), gridSteps(35, 24));
    try std.testing.expectEqual(@as(i32, 0), gridSteps(-11, 24));
    try std.testing.expectEqual(@as(i32, -1), gridSteps(-12, 24));
    try std.testing.expectEqual(@as(i32, -1), gridSteps(-35, 24));
    try std.testing.expectEqual(@as(i32, 25), gridSteps(25, 1));

    // **实测手感**：1/8 音符（12 步）+ 1/4 网格（24 步）
    try std.testing.expectEqual(@as(i32, 12), trimMinGridLen(12, 24)); // 只剩不足一格
    try std.testing.expectEqual(@as(i32, 12), trimLenByGrid(12, 11, 24)); // 不足半格 → 不变
    try std.testing.expectEqual(@as(i32, 36), trimLenByGrid(12, 12, 24)); // 过半格 → +1/4
    try std.testing.expectEqual(@as(i32, 60), trimLenByGrid(12, 36, 24)); // 一格半 → +2/4
    try std.testing.expectEqual(@as(i32, 12), trimLenByGrid(12, -12, 24)); // 拖回 → 复原
    try std.testing.expectEqual(@as(i32, 12), trimLenByGrid(12, -96, 24)); // 再往左：不能减

    // 1/2 音符（48 步）+ 1/4 网格：最低减到 1/4（24），不能更低
    try std.testing.expectEqual(@as(i32, 24), trimMinGridLen(48, 24));
    try std.testing.expectEqual(@as(i32, 24), trimLenByGrid(48, -24, 24));
    try std.testing.expectEqual(@as(i32, 24), trimLenByGrid(48, -999, 24));
    // 3/8 音符（36 步）：减一格到 1/8（仍是格点）、再减被挡
    try std.testing.expectEqual(@as(i32, 12), trimLenByGrid(36, -24, 24));

    // 自由精度（网格 = 1 步）：跟随位移、下限 1
    try std.testing.expectEqual(@as(i32, 37), trimLenByGrid(12, 25, 1));
    try std.testing.expectEqual(@as(i32, 1), trimLenByGrid(12, -999, 1));
}

test "batchShortenMax / clampBatchK：批量缩短的“全组同步”规则" {
    const g = 12; // 1/8 网格 = 12 步
    // 四分音符（24）：最多缩 1 格（24−12=12；再缩 24−24=0 不行）
    try std.testing.expectEqual(@as(i32, 1), batchShortenMax(24, g));
    // 八分音符（12）：不能缩（= 一格）
    try std.testing.expectEqual(@as(i32, 0), batchShortenMax(12, g));
    // 更短（6）：不能缩
    try std.testing.expectEqual(@as(i32, 0), batchShortenMax(6, g));
    // 二分音符（48）：3 格（48→36→24→12，到一格为止）
    try std.testing.expectEqual(@as(i32, 3), batchShortenMax(48, g));
    // 非整格（30）：floor(29/12) = 2
    try std.testing.expectEqual(@as(i32, 2), batchShortenMax(30, g));

    // 钳制：全组 cap = min（有一个不够就整体不能缩）
    const cap = @min(batchShortenMax(24, g), batchShortenMax(24, g));
    try std.testing.expectEqual(@as(i32, -1), clampBatchK(-1, cap, 0));
    try std.testing.expectEqual(@as(i32, -1), clampBatchK(-5, cap, 0)); // 超缩 → 钳到 -1
    const cap2 = @min(batchShortenMax(24, g), batchShortenMax(12, g)); // 有一个 = 一格
    try std.testing.expectEqual(@as(i32, 0), clampBatchK(-1, cap2, 0)); // 全组不能缩
    // 加长：受 extend_cap（左缘“不能越过 0”）
    try std.testing.expectEqual(@as(i32, 3), clampBatchK(10, 0, 3));
    try std.testing.expectEqual(@as(i32, 10), clampBatchK(10, 0, 999));
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
///
/// **注意**：数据层允许重叠（与 MIDI 一致）；本函数仅用于需要“找重叠”的场景
/// （如擦除、诊断），**放置/拖动不再拦截**。
pub fn noteOverlaps(notes: []const Note, exclude: usize, pattern: i32, instrument: i32, step: i32, len: i32, pitch: i32) bool {
    for (notes, 0..) |o, oi| {
        if (oi == exclude or o.pattern != pattern or o.instrument != instrument or o.pitch != pitch) continue;
        if (step < o.step + o.len and o.step < step + len) return true;
    }
    return false;
}

/// 拖音符左缘：改起点+长度（右端固定）。
/// `new_step` 为目标起点（局部坐标，已由调用方按增量式拉伸算好）；
/// `min_len` 为最短长度（通常 = `trimMinGridLen`——原长减去整数格后仍 >= 1 的值）。
/// 约束：`0 <= new_step <= right - min_len`、长度不可能变长（右端固定）。
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

test "model: routedInstrumentNames——0 起基准（修效果器标题显示下一通道乐器）" {
    var sp: synth.SynthParams = .{};
    // 实测场景：Bass → 通道 1，Key → 通道 2。效果器标题曾误用
    // `mixer == ch + 1`：打开通道 1 的 EQ 显示成通道 2 的 Key（应显示 Bass）。
    const insts = [_]Instrument{
        .{ .name = "Bass", .mixer = 1, .synth = &sp },
        .{ .name = "Key", .mixer = 2, .synth = &sp },
    };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bass", routedInstrumentNames(&insts, 1, &buf));
    try std.testing.expectEqualStrings("Key", routedInstrumentNames(&insts, 2, &buf));
    // 无路由到此通道 → 空串（而不是借位到别的通道）
    try std.testing.expectEqualStrings("", routedInstrumentNames(&insts, 0, &buf));
    try std.testing.expectEqualStrings("", routedInstrumentNames(&insts, 3, &buf));

    // 多乐器同通道：首个 + N
    const two = [_]Instrument{
        .{ .name = "Bass", .mixer = 1, .synth = &sp },
        .{ .name = "Key", .mixer = 1, .synth = &sp },
    };
    try std.testing.expectEqualStrings("Bass +1", routedInstrumentNames(&two, 1, &buf));
}
