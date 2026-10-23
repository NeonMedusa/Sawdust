//! MIDI 文件（SMF，Standard MIDI File）导入 / 导出。
//!
//! **范围**：只还原/写出音符的**音高与时值**（力度、声像、变速等以后再做）。
//! - 解析：合并全部轨道；按 (通道, 音高) **FIFO** 配对 note-on/off；
//!   支持 running status、vel=0 的 note-on（= off）；meta/sysex 正确跳过；
//! - 写出：format 1（指挥轨 + 每用到的通道一条音符轨），tpq = 480（每步 20 tick）；
//! - 通道 ↔ 乐器：导入时每个用到的通道建一个乐器；导出时乐器号 mod 16 作通道。
//!
//! 纯逻辑、不依赖 UI/音频（可单测）。

const std = @import("std");
const model = @import("model.zig");

/// 每四分音符的步数（U=96 → 每四分音符 24 步）
pub const steps_per_quarter: i32 = @divTrunc(model.units_per_whole, 4);

/// 导出用的每四分音符 tick 数（480 = 最常见值；480/24 = 20 tick/步，整除）
pub const export_tpq: i32 = 480;

/// tick → 步（**就近取整**：每个事件独立换算，不会像增量累加那样漂移）。
/// `tpq` = 该文件的每四分音符 tick 数（每个 MIDI 文件自带头块声明，常见 96/192/384/480）。
pub fn tickToStep(tick: i64, tpq: i32) i32 {
    const q: i64 = @max(1, tpq);
    const num = tick * steps_per_quarter;
    return @intCast(@divFloor(num + @divTrunc(q, 2), q));
}

/// 步 → tick（导出用）
pub fn stepToTick(step: i32, tpq: i32) i64 {
    return @divFloor(@as(i64, step) * tpq, steps_per_quarter);
}

// ── 变长量（VLQ）──

/// 读一个 VLQ（最多 4 字节）；成功返回 `{ 值, 新位置 }`
fn readVlq(data: []const u8, i: *usize) ?i64 {
    var v: i64 = 0;
    var n: usize = 0;
    while (i.* < data.len and n < 4) : (n += 1) {
        const b = data[i.*];
        i.* += 1;
        v = (v << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) return v;
    }
    return null;
}

/// 写一个 VLQ
fn writeVlq(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var tmp: [5]u8 = undefined;
    var v = value;
    tmp[0] = @intCast(v & 0x7F);
    v >>= 7;
    var n: usize = 1;
    while (v != 0) {
        tmp[n] = @intCast(v & 0x7F);
        v >>= 7;
        n += 1;
    }
    var k: usize = n;
    while (k > 0) {
        k -= 1;
        const b: u8 = tmp[k] | (if (k > 0) @as(u8, 0x80) else 0);
        try out.append(allocator, b);
    }
}

// ── 解析 ──

/// 解析出的一个音符（tick 坐标；调用方按 `tickToStep` 换算）
pub const ParsedNote = struct {
    start_tick: i64,
    end_tick: i64,
    pitch: u8,
    channel: u8,
    /// 力度（1-127）——note-on 的力度字节
    velocity: u8 = 100,
};

pub const Parsed = struct {
    /// 文件声明的每四分音符 tick 数
    ticks_per_quarter: i32,
    notes: []ParsedNote,
    /// 每通道**首个** CC10（声像）事件值（0-127；无 → 64）。
    /// 语义：MIDI 声像是**通道级**的（没有音符级声像）——导入时映射到乐器声像；
    /// 音符级声像一律居中（动态曲线以后再做）。
    channel_pan: [16]u8 = @splat(64),

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.notes);
        self.notes = &.{};
    }
};

const Pending = struct { channel: u8, pitch: u8, start: i64, velocity: u8 };

/// 关闭最早的 (channel, pitch) 配对（FIFO——同 MIDI 接收端语义）
fn closeNote(
    allocator: std.mem.Allocator,
    notes: *std.ArrayListUnmanaged(ParsedNote),
    pending: *std.ArrayListUnmanaged(Pending),
    channel: u8,
    pitch: u8,
    end_tick: i64,
) !void {
    for (pending.items, 0..) |p, i| {
        if (p.channel == channel and p.pitch == pitch) {
            _ = pending.orderedRemove(i);
            try notes.append(allocator, .{
                .start_tick = p.start,
                .end_tick = @max(end_tick, p.start + 1),
                .pitch = pitch,
                .channel = channel,
                .velocity = p.velocity,
            });
            return;
        }
    }
    // 无匹配（幽灵 note-off）→ 忽略
}

/// 解析一条轨道（事件 → note 配对；未配对的 note-on 以轨道末尾收尾）
fn parseTrack(
    allocator: std.mem.Allocator,
    data: []const u8,
    notes: *std.ArrayListUnmanaged(ParsedNote),
    chan_pan: *[16]u8,
    chan_pan_set: *[16]bool,
) !void {
    var pending: std.ArrayListUnmanaged(Pending) = .empty;
    defer pending.deinit(allocator);

    var i: usize = 0;
    var abs: i64 = 0;
    var running: u8 = 0; // running status（上一个事件状态字节）
    // CC10（声像）不在音符级落地——只记每通道“首个”值（见 `Parsed.channel_pan`）
    while (i < data.len) {
        const delta = readVlq(data, &i) orelse return; // 损坏：宽容停止
        abs += delta;
        if (i >= data.len) break;

        var status = data[i];
        if (status >= 0x80) {
            i += 1;
            if (status < 0xF0) running = status;
        } else {
            if (running == 0) return; // 无 running status 可沿用：损坏
            status = running;
        }

        const kind = status & 0xF0;
        const ch = status & 0x0F;
        switch (kind) {
            0x80, 0x90 => {
                if (i + 2 > data.len) return;
                const key = data[i];
                const vel = data[i + 1];
                i += 2;
                if (kind == 0x90 and vel > 0) {
                    try pending.append(allocator, .{ .channel = ch, .pitch = key, .start = abs, .velocity = vel });
                } else {
                    try closeNote(allocator, notes, &pending, ch, key, abs);
                }
            },
            0xB0 => {
                // 控制器：CC10 = 声像（其余跳过）
                if (i + 2 > data.len) return;
                const cc = data[i];
                const val = data[i + 1];
                i += 2;
                // 只记**首个** CC10（该通道的静态声像基准；动态曲线以后再做）
                if (cc == 10 and !chan_pan_set[ch & 0x0F]) {
                    chan_pan[ch & 0x0F] = val;
                    chan_pan_set[ch & 0x0F] = true;
                }
            },
            0xA0, 0xE0 => i += 2, // 触后 / 弯音：跳过
            0xC0, 0xD0 => i += 1, // 音色 / 通道触后：跳过
            0xF0 => switch (status) {
                0xF0, 0xF7 => {
                    const len = readVlq(data, &i) orelse return;
                    i += @intCast(@max(0, len));
                },
                0xFF => {
                    if (i >= data.len) return;
                    const meta_type = data[i];
                    i += 1;
                    const len = readVlq(data, &i) orelse return;
                    i += @intCast(@max(0, len));
                    if (meta_type == 0x2F) break; // end of track
                },
                else => return, // 其他系统消息：宽容停止本轨
            },
            else => return,
        }
    }

    // 未配对的 note-on → 以轨道末尾收尾（文件截断/缺 off 的容错）
    for (pending.items) |p| {
        try notes.append(allocator, .{
            .start_tick = p.start,
            .end_tick = @max(abs, p.start + 1),
            .pitch = p.pitch,
            .channel = p.channel,
            .velocity = p.velocity,
        });
    }
}

/// 解析 MIDI 文件（全部轨道合并；返回的音符按原顺序）
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Parsed {
    if (data.len < 14) return error.InvalidMidi;
    if (!std.mem.eql(u8, data[0..4], "MThd")) return error.InvalidMidi;
    const header_len = std.mem.readInt(u32, data[4..8], .big);
    if (header_len < 6) return error.InvalidMidi;
    _ = std.mem.readInt(u16, data[8..10], .big); // format（0/1/2 一律按“多轨合并”处理）
    const ntrks = std.mem.readInt(u16, data[10..12], .big);
    const division = std.mem.readInt(u16, data[12..14], .big);
    if (division & 0x8000 != 0) return error.SmpteTimeNotSupported; // SMPTE 时基暂不支持
    const tpq: i32 = @max(1, division);

    var notes: std.ArrayListUnmanaged(ParsedNote) = .empty;
    errdefer notes.deinit(allocator);

    var pos: usize = 8 + header_len;
    var track_i: usize = 0;
    // CC10 跨轨全局（format 1 多轨共享同一声像状态）
    var chan_pan: [16]u8 = @splat(64);
    var chan_pan_set: [16]bool = @splat(false);
    while (track_i < ntrks and pos + 8 <= data.len) : (track_i += 1) {
        if (!std.mem.eql(u8, data[pos .. pos + 4], "MTrk")) break; // 结构异常：宽容停止
        const tlen = std.mem.readInt(u32, data[pos + 4 .. pos + 8][0..4], .big);
        pos += 8;
        const end = @min(data.len, pos + tlen);
        try parseTrack(allocator, data[pos..end], &notes, &chan_pan, &chan_pan_set);
        pos = end;
    }

    return .{ .ticks_per_quarter = tpq, .notes = try notes.toOwnedSlice(allocator), .channel_pan = chan_pan };
}

// ── 写出 ──

/// 待导出的一个音符（步坐标；`channel` 0-15）
pub const ExportNote = struct {
    start_step: i32,
    len_steps: i32,
    pitch: u8,
    channel: u8,
    /// 力度（1-127；默认 100）
    velocity: u8 = 100,
};

pub const ExportSong = struct {
    bpm: i32 = 120,
    time_num: u8 = 4,
    time_den: u8 = 4,
    notes: []const ExportNote,
    /// 每通道声像（0-127）= 该通道乐器的声像——**轨首一次性 CC10**。
    /// 音符级声像（Sawdust 特色）不导出：MIDI 只有通道级声像。
    channel_pan: [16]u8 = @splat(64),
};

const Event = struct { tick: i64, pitch: u8, is_on: bool, velocity: u8 = 100 };

/// CC10（声像）事件（每通道轨首一条）
const CcEvent = struct { tick: i64, value: u8 };

fn evLess(_: void, a: Event, b: Event) bool {
    if (a.tick != b.tick) return a.tick < b.tick;
    // 同 tick：off 先于 on（同音高快速重触发不粘连）
    const pa: u8 = if (a.is_on) 1 else 0;
    const pb: u8 = if (b.is_on) 1 else 0;
    return pa < pb;
}

fn ccLess(_: void, a: CcEvent, b: CcEvent) bool {
    return a.tick < b.tick;
}

/// 写指挥轨（tempo + 拍号 + 结束）
fn writeConductorTrack(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    song: ExportSong,
) !void {
    // tempo：微秒/四分音符 = 60,000,000 / BPM
    try writeVlq(out, allocator, 0);
    try out.appendSlice(allocator, &.{ 0xFF, 0x51, 0x03 });
    const us: u32 = @intCast(@divTrunc(60_000_000, @max(1, song.bpm)));
    try out.append(allocator, @intCast((us >> 16) & 0xFF));
    try out.append(allocator, @intCast((us >> 8) & 0xFF));
    try out.append(allocator, @intCast(us & 0xFF));

    // 拍号：nn dd cc bb（dd = log2(分母)）
    try writeVlq(out, allocator, 0);
    try out.appendSlice(allocator, &.{ 0xFF, 0x58, 0x04 });
    try out.append(allocator, song.time_num);
    const den_log2: u8 = @intCast(std.math.log2_int(u16, std.math.clamp(song.time_den, 1, 64)));
    try out.append(allocator, den_log2);
    try out.append(allocator, 24); // 每节拍 MIDI 时钟数
    try out.append(allocator, 8); // 每四分音符 32 分音符数

    // 结束
    try writeVlq(out, allocator, 0);
    try out.appendSlice(allocator, &.{ 0xFF, 0x2F, 0x00 });
}

/// 写一条音符轨（固定通道；力度用音符自身的；CC10 在轨首一次性写入）
fn writeNoteTrack(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    evs: []const Event,
    ccs: []const CcEvent,
    channel: u4,
) !void {
    // 合并两个有序序列（音符事件 + CC10），按 tick 先后写出
    var last: i64 = 0;
    var ei: usize = 0;
    var ci: usize = 0;
    while (ei < evs.len or ci < ccs.len) {
        // 同 tick：CC 先于音符事件（轨首 CC10 在有音符前就位）
        const take_cc = ci < ccs.len and (ei >= evs.len or ccs[ci].tick <= evs[ei].tick);
        if (take_cc) {
            const c = ccs[ci];
            ci += 1;
            try writeVlq(out, allocator, @intCast(@max(0, c.tick - last)));
            last = c.tick;
            try out.append(allocator, 0xB0 | @as(u8, channel));
            try out.append(allocator, 10); // CC10 = 声像
            try out.append(allocator, c.value);
        } else {
            const e = evs[ei];
            ei += 1;
            try writeVlq(out, allocator, @intCast(@max(0, e.tick - last)));
            last = e.tick;
            const status: u8 = (if (e.is_on) @as(u8, 0x90) else 0x80) | @as(u8, channel);
            try out.append(allocator, status);
            try out.append(allocator, e.pitch);
            try out.append(allocator, if (e.is_on) e.velocity else 64);
        }
    }
    try writeVlq(out, allocator, 0);
    try out.appendSlice(allocator, &.{ 0xFF, 0x2F, 0x00 });
}

/// 把歌曲写成 MIDI 文件字节（format 1：指挥轨 + 每用到的通道一条轨）
pub fn write(allocator: std.mem.Allocator, song: ExportSong) ![]u8 {
    const tpq = export_tpq;

    // 按通道收集事件（音符 + 声像 CC10；CC 去重：同值连续不重发）
    var evs: [16]std.ArrayListUnmanaged(Event) = @splat(.empty);
    var ccs: [16]std.ArrayListUnmanaged(CcEvent) = @splat(.empty);
    defer for (&evs) |*e| e.deinit(allocator);
    defer for (&ccs) |*c| c.deinit(allocator);
    var used: [16]bool = @splat(false);

    for (song.notes) |n| {
        const ch: u4 = @intCast(@min(n.channel, 15));
        used[ch] = true;
        const on_tick = stepToTick(n.start_step, tpq);
        const off_tick = stepToTick(n.start_step + @max(1, n.len_steps), tpq);
        try evs[ch].append(allocator, .{ .tick = on_tick, .pitch = n.pitch, .is_on = true, .velocity = @max(1, n.velocity) });
        try evs[ch].append(allocator, .{ .tick = off_tick, .pitch = n.pitch, .is_on = false });
    }
    // 每通道轨首一条 CC10：通道声像（= 乐器声像——音符级声像不导出）
    for (&ccs, 0..) |*c, ch| {
        if (used[ch]) try c.append(allocator, .{ .tick = 0, .value = @min(127, song.channel_pan[ch]) });
    }
    for (&evs, 0..) |*e, ch| {
        if (used[ch]) std.mem.sort(Event, e.items, {}, evLess);
        if (used[ch]) std.mem.sort(CcEvent, ccs[ch].items, {}, ccLess);
    }

    // 头块
    var ntrks: u16 = 1; // 指挥轨
    for (used) |u| {
        if (u) ntrks += 1;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "MThd");
    try appendU32(allocator, &out, 6);
    try appendU16(allocator, &out, 1); // format 1
    try appendU16(allocator, &out, ntrks);
    try appendU16(allocator, &out, @intCast(tpq));

    // 指挥轨
    {
        var track: std.ArrayListUnmanaged(u8) = .empty;
        defer track.deinit(allocator);
        try writeConductorTrack(allocator, &track, song);
        try appendChunk(allocator, &out, track.items);
    }
    // 各通道音符轨
    for (&evs, 0..) |*e, ch| {
        if (!used[ch]) continue;
        var track: std.ArrayListUnmanaged(u8) = .empty;
        defer track.deinit(allocator);
        try writeNoteTrack(allocator, &track, e.items, ccs[ch].items, @intCast(ch));
        try appendChunk(allocator, &out, track.items);
    }

    return out.toOwnedSlice(allocator);
}

fn appendU16(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try out.appendSlice(allocator, &buf);
}

/// 追加一个 MTrk 块（自动填长度）
fn appendChunk(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), data: []const u8) !void {
    try out.appendSlice(allocator, "MTrk");
    try appendU32(allocator, out, @intCast(data.len));
    try out.appendSlice(allocator, data);
}

// ── 测试 ──

test "midi: VLQ 编解码（边界值）" {
    const allocator = std.testing.allocator;
    const cases = [_]u64{ 0, 1, 127, 128, 255, 0x3FFF, 0x4000, 0x1FFFFF, 0x0FFFFFFF };
    for (cases) |v| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try writeVlq(&buf, allocator, v);
        var i: usize = 0;
        const got = readVlq(buf.items, &i) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(i64, @intCast(v)), got);
        try std.testing.expectEqual(buf.items.len, i);
    }
    // 损坏输入（全部带续标志）
    var i: usize = 0;
    try std.testing.expect(readVlq(&.{ 0x80, 0x80, 0x80, 0x80, 0x00 }, &i) == null);
}

test "midi: tick ↔ 步换算（就近取整；常见 tpq）" {
    // 每四分音符 = 24 步
    try std.testing.expectEqual(@as(i32, 24), tickToStep(96, 96));
    try std.testing.expectEqual(@as(i32, 24), tickToStep(480, 480));
    try std.testing.expectEqual(@as(i32, 24), tickToStep(192, 192));
    try std.testing.expectEqual(@as(i32, 0), tickToStep(0, 480));
    // 就近取整：490/480 四分音符 ≈ 24.5 步 → 25
    try std.testing.expectEqual(@as(i32, 25), tickToStep(490, 480));
    // 半分以下舍去：485 → 24.25 → 24
    try std.testing.expectEqual(@as(i32, 24), tickToStep(485, 480));
    // 反向
    try std.testing.expectEqual(@as(i64, 480), stepToTick(24, 480));
    try std.testing.expectEqual(@as(i64, 96), stepToTick(24, 96));
    try std.testing.expectEqual(@as(i64, 20), stepToTick(1, 480)); // 1 步 = 480/24 tick
}

test "midi: 解析最小文件（running status + vel=0 off + 未配对收尾）" {
    const allocator = std.testing.allocator;
    // MThd：format 0、1 轨、tpq 96
    // MTrk：
    //   delta 0   : 90 3C 40   on  C4 ch0（running ← 90）
    //   delta 96  : 3C 00      running on vel=0（= off C4）
    //   delta 0   : 3E 40      running on  D4
    //   delta 48  : 3E 00      running off D4（vel=0）
    //   delta 0   : 90 45 40   on  A4（未配对——到轨道末尾收尾）
    //   delta 0   : FF 2F 00   end
    const track = [_]u8{
        0x00, 0x90, 0x3C, 0x40,
        0x60, 0x3C, 0x00, 0x00,
        0x3E, 0x40, 0x30, 0x3E,
        0x00, 0x00, 0x90, 0x45,
        0x40, 0x00, 0xFF, 0x2F,
        0x00,
    };
    var file: std.ArrayListUnmanaged(u8) = .empty;
    defer file.deinit(allocator);
    try file.appendSlice(allocator, "MThd");
    try appendU32(allocator, &file, 6);
    try appendU16(allocator, &file, 0);
    try appendU16(allocator, &file, 1);
    try appendU16(allocator, &file, 96);
    try appendChunk(allocator, &file, &track);

    var parsed = try parse(allocator, file.items);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 96), parsed.ticks_per_quarter);
    try std.testing.expectEqual(@as(usize, 3), parsed.notes.len);

    // C4：0..96
    try std.testing.expectEqual(@as(u8, 60), parsed.notes[0].pitch);
    try std.testing.expectEqual(@as(i64, 0), parsed.notes[0].start_tick);
    try std.testing.expectEqual(@as(i64, 96), parsed.notes[0].end_tick);
    // D4：96..144（running status + vel=0 off）
    try std.testing.expectEqual(@as(u8, 62), parsed.notes[1].pitch);
    try std.testing.expectEqual(@as(i64, 96), parsed.notes[1].start_tick);
    try std.testing.expectEqual(@as(i64, 144), parsed.notes[1].end_tick);
    // A4：144..144+（未配对 → 以轨道末尾收尾，至少 1 tick）
    try std.testing.expectEqual(@as(u8, 69), parsed.notes[2].pitch);
    try std.testing.expectEqual(@as(i64, 144), parsed.notes[2].start_tick);
    try std.testing.expect(parsed.notes[2].end_tick >= 145);
}

test "midi: 同音高重叠——note-off FIFO 配对最早的一个" {
    const allocator = std.testing.allocator;
    // 两次 on C4（0、48），两次 off（96、144）→ 音符 0..96 与 48..144
    const track = [_]u8{
        0x00, 0x90, 0x3C, 0x40,
        0x30, 0x90, 0x3C, 0x40,
        0x30, 0x80, 0x3C, 0x40,
        0x30, 0x80, 0x3C, 0x40,
        0x00, 0xFF, 0x2F, 0x00,
    };
    var file: std.ArrayListUnmanaged(u8) = .empty;
    defer file.deinit(allocator);
    try file.appendSlice(allocator, "MThd");
    try appendU32(allocator, &file, 6);
    try appendU16(allocator, &file, 0);
    try appendU16(allocator, &file, 1);
    try appendU16(allocator, &file, 96);
    try appendChunk(allocator, &file, &track);

    var parsed = try parse(allocator, file.items);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.notes.len);
    try std.testing.expectEqual(@as(i64, 0), parsed.notes[0].start_tick);
    try std.testing.expectEqual(@as(i64, 96), parsed.notes[0].end_tick);
    try std.testing.expectEqual(@as(i64, 48), parsed.notes[1].start_tick);
    try std.testing.expectEqual(@as(i64, 144), parsed.notes[1].end_tick);
}

test "midi: 导出 → 解析往返（音高/时值/通道）" {
    const allocator = std.testing.allocator;
    const notes = [_]ExportNote{
        .{ .start_step = 0, .len_steps = 24, .pitch = 60, .channel = 0 }, // 四分音符
        .{ .start_step = 24, .len_steps = 12, .pitch = 64, .channel = 0 },
        .{ .start_step = 0, .len_steps = 96, .pitch = 48, .channel = 3 }, // 另一通道
        .{ .start_step = 48, .len_steps = 1, .pitch = 72, .channel = 15 }, // 最短
    };
    const bytes = try write(allocator, .{ .bpm = 140, .time_num = 3, .time_den = 4, .notes = &notes });
    defer allocator.free(bytes);

    // 头块自检
    try std.testing.expectEqualStrings("MThd", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[8..10], .big)); // format 1
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, bytes[12..14], .big));

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 480), parsed.ticks_per_quarter);
    try std.testing.expectEqual(@as(usize, 4), parsed.notes.len);

    // 每个音符都能精确还原成步坐标（tpq 480 → tick = step × 20，整除无误差）
    for (notes) |want| {
        var found = false;
        for (parsed.notes) |got| {
            if (got.pitch != want.pitch or got.channel != want.channel) continue;
            const s = tickToStep(got.start_tick, parsed.ticks_per_quarter);
            const e = tickToStep(got.end_tick, parsed.ticks_per_quarter);
            if (s == want.start_step and e - s == want.len_steps) found = true;
        }
        try std.testing.expect(found);
    }
}

test "midi: 力度/通道声像（CC10）导出 → 解析往返" {
    const allocator = std.testing.allocator;
    const notes = [_]ExportNote{
        .{ .start_step = 0, .len_steps = 24, .pitch = 60, .channel = 0, .velocity = 40 },
        .{ .start_step = 24, .len_steps = 24, .pitch = 64, .channel = 0, .velocity = 127 },
        .{ .start_step = 48, .len_steps = 24, .pitch = 67, .channel = 1 }, // 通道 1：默认力度 / 声像
    };
    var cpan: [16]u8 = @splat(64);
    cpan[0] = 20; // 模拟乐器声像：通道 0 偏左
    const bytes = try write(allocator, .{ .notes = &notes, .channel_pan = cpan });
    defer allocator.free(bytes);

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), parsed.notes.len);

    // 通道声像：轨首一次性 CC10 → 解析为通道级值（导入时映射到乐器）
    try std.testing.expectEqual(@as(u8, 20), parsed.channel_pan[0]);
    try std.testing.expectEqual(@as(u8, 64), parsed.channel_pan[1]);

    // 力度逐音符还原；音符级声像一律居中（Sawdust 语义：声像在乐器/通道级）
    for (parsed.notes) |got| {
        switch (got.pitch) {
            60 => try std.testing.expectEqual(@as(u8, 40), got.velocity),
            64 => try std.testing.expectEqual(@as(u8, 127), got.velocity),
            67 => try std.testing.expectEqual(@as(u8, 100), got.velocity),
            else => unreachable,
        }
    }
}

test "midi: 解析容错（坏头 / 截断轨道 / SMPTE）" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidMidi, parse(allocator, "not midi at all!"));
    // 头块正常但轨道截断：能解析出已完成的事件（宽容）
    var file: std.ArrayListUnmanaged(u8) = .empty;
    defer file.deinit(allocator);
    try file.appendSlice(allocator, "MThd");
    try appendU32(allocator, &file, 6);
    try appendU16(allocator, &file, 0);
    try appendU16(allocator, &file, 1);
    try appendU16(allocator, &file, 96);
    try file.appendSlice(allocator, "MTrk");
    try appendU32(allocator, &file, 100); // 声称 100 字节，实际只有 4
    try file.appendSlice(allocator, &.{ 0x00, 0x90, 0x3C, 0x40 });
    var parsed = try parse(allocator, file.items);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.notes.len); // 未配对 → 收尾

    // SMPTE 时基（division 高位 1）→ 明确报错
    var smpte: std.ArrayListUnmanaged(u8) = .empty;
    defer smpte.deinit(allocator);
    try smpte.appendSlice(allocator, "MThd");
    try appendU32(allocator, &smpte, 6);
    try appendU16(allocator, &smpte, 0);
    try appendU16(allocator, &smpte, 0);
    try appendU16(allocator, &smpte, 0xE728); // SMPTE 标志
    try std.testing.expectError(error.SmpteTimeNotSupported, parse(allocator, smpte.items));
}
