//! WAV（RIFF / PCM 24-bit）写出器——导出音频用。
//! **零依赖、无编码器**：PCM + 44 字节标准头；数据流式追加，
//! `finish` 用**定位写**回填 RIFF/data 尺寸（不依赖 seek）。
//! 尺寸字段超 u32（>4GB）按规范写 0xFFFFFFFF（单曲导出远用不到）。

const std = @import("std");

pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    sample_rate: u32,
    channels: u16,
    /// 已写入的数据字节数（不含头）
    data_bytes: u64 = 0,
    finished: bool = false,

    /// 创建并写占位头（真实尺寸在 `finish` 回填）。
    pub fn create(io: std.Io, path: []const u8, sample_rate: u32, channels: u16) !Writer {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        errdefer file.close(io);
        var self = Writer{ .io = io, .file = file, .sample_rate = sample_rate, .channels = channels };
        try self.file.writeStreamingAll(io, &self.header(0));
        return self;
    }

    fn header(self: *const Writer, data_bytes: u64) [44]u8 {
        const bits: u16 = 24;
        const block_align: u16 = self.channels * (bits / 8);
        const byte_rate: u32 = self.sample_rate * @as(u32, block_align);
        const dsz: u32 = if (data_bytes > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(data_bytes);
        const riff: u32 = if (data_bytes + 36 > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(data_bytes + 36);
        var h: [44]u8 = undefined;
        @memcpy(h[0..4], "RIFF");
        std.mem.writeInt(u32, h[4..8], riff, .little);
        @memcpy(h[8..12], "WAVE");
        @memcpy(h[12..16], "fmt ");
        std.mem.writeInt(u32, h[16..20], 16, .little); // fmt 块大小
        std.mem.writeInt(u16, h[20..22], 1, .little); // wFormatTag = PCM
        std.mem.writeInt(u16, h[22..24], self.channels, .little);
        std.mem.writeInt(u32, h[24..28], self.sample_rate, .little);
        std.mem.writeInt(u32, h[28..32], byte_rate, .little);
        std.mem.writeInt(u16, h[32..34], block_align, .little);
        std.mem.writeInt(u16, h[34..36], bits, .little);
        @memcpy(h[36..40], "data");
        std.mem.writeInt(u32, h[40..44], dsz, .little);
        return h;
    }

    /// 追加一块**交错** f32 样本（任意长度；内部转 24-bit LE）。
    pub fn writeFrames(self: *Writer, buf: []const f32) !void {
        var tmp: [4096 * 3]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len) {
            const n = @min(buf.len - i, 4096);
            for (buf[i .. i + n], 0..) |v, j| {
                // f32 → i24：±1 定标 + 钳制（-1 → -8388608、+1 → 8388607；四舍五入）
                const c = std.math.clamp(@as(f64, v), -1.0, 1.0);
                const s: i64 = @intFromFloat(@round(c * 8388608.0));
                const cl: i64 = std.math.clamp(s, -8388608, 8388607);
                const u: u32 = @truncate(@as(u64, @bitCast(cl)));
                tmp[j * 3 + 0] = @truncate(u);
                tmp[j * 3 + 1] = @truncate(u >> 8);
                tmp[j * 3 + 2] = @truncate(u >> 16);
            }
            try self.file.writeStreamingAll(self.io, tmp[0 .. n * 3]);
            self.data_bytes += n * 3;
            i += n;
        }
    }

    /// 回填尺寸并关闭。
    pub fn finish(self: *Writer) !void {
        if (self.finished) return;
        const h = self.header(self.data_bytes);
        try self.file.writePositionalAll(self.io, &h, 0);
        self.finished = true;
        self.file.close(self.io);
    }

    /// 出错清理：关闭（不落尺寸）——调用方随后删文件。
    pub fn abandon(self: *Writer) void {
        if (!self.finished) {
            self.finished = true;
            self.file.close(self.io);
        }
    }
};

test "wav: 24-bit PCM 头与样本（可回读校验）" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const path = "tmp/wav_roundtrip_test.wav";
    std.Io.Dir.cwd().createDirPath(io, "tmp") catch {};

    var w = try Writer.create(io, path, 48000, 2);
    try w.writeFrames(&.{ 1.0, -1.0, 0.0, 0.5 });
    try w.finish();

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(data);

    try std.testing.expectEqualStrings("RIFF", data[0..4]);
    try std.testing.expectEqualStrings("WAVE", data[8..12]);
    try std.testing.expectEqualStrings("fmt ", data[12..16]);
    try std.testing.expectEqualStrings("data", data[36..40]);
    try std.testing.expectEqual(@as(u32, 36 + 2 * 2 * 3), std.mem.readInt(u32, data[4..8], .little));
    try std.testing.expectEqual(@as(u32, 2 * 2 * 3), std.mem.readInt(u32, data[40..44], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, data[20..22], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, data[22..24], .little));
    try std.testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, data[24..28], .little));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, data[34..36], .little));
    try std.testing.expectEqual(@as(usize, 44 + 2 * 2 * 3), data.len);

    // 样本：+1 → 0x7FFFFF（最大正值）、-1 → 0x800000（two's complement 低 3 字节）、0 → 0、+0.5 → 0x400000
    const b = data[44..];
    const s0: u32 = @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
    const s1: u32 = @as(u32, b[3]) | (@as(u32, b[4]) << 8) | (@as(u32, b[5]) << 16);
    const s2: u32 = @as(u32, b[6]) | (@as(u32, b[7]) << 8) | (@as(u32, b[8]) << 16);
    const s3: u32 = @as(u32, b[9]) | (@as(u32, b[10]) << 8) | (@as(u32, b[11]) << 16);
    try std.testing.expectEqual(@as(u32, 0x7FFFFF), s0);
    try std.testing.expectEqual(@as(u32, 0x800000), s1);
    try std.testing.expectEqual(@as(u32, 0x000000), s2);
    try std.testing.expectEqual(@as(u32, 0x400000), s3);
}
