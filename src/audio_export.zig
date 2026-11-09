//! 离线导出的目标格式与压缩编码。
//!
//! 渲染器始终先写标准 PCM WAV：它是可流式写入、可在取消时安全丢弃的中间格式。
//! MP3 / FLAC / OGG 交给 FFmpeg 做最后一步容器与编码，参数全以 argv 传递，不经 shell。

const std = @import("std");
const wav = @import("wav.zig");

pub const Format = enum {
    wav,
    mp3,
    flac,
    ogg,

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .wav => "WAV（PCM 24-bit）",
            .mp3 => "MP3",
            .flac => "FLAC",
            .ogg => "OGG Vorbis",
        };
    }

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .wav => ".wav",
            .mp3 => ".mp3",
            .flac => ".flac",
            .ogg => ".ogg",
        };
    }

    pub fn needsEncoder(self: Format) bool {
        return self != .wav;
    }
};

pub const Options = struct {
    format: Format = .wav,
    /// MP3 / OGG 的目标恒定码率（kbps）。
    bitrate_kbps: u16 = 192,
    /// FLAC 压缩等级 0…12；只影响编码速度/文件体积，不损失音质。
    flac_compression: u8 = 5,
};

pub fn tempWavPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.sawdust-render.tmp.wav", .{target_path});
}

/// 导出格式是权威：用户在保存框里手打了其它扩展名时替换为所选格式，避免“.wav
/// 后缀里其实装 MP3”这类难排查的文件。
pub fn targetPath(allocator: std.mem.Allocator, picked_path: []const u8, format: Format) ![]u8 {
    const wanted = format.extension();
    const old = std.fs.path.extension(picked_path);
    if (std.ascii.eqlIgnoreCase(old, wanted)) return allocator.dupe(u8, picked_path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ picked_path[0 .. picked_path.len - old.len], wanted });
}

/// 把已经写完的 WAV 编码为目标格式。
///
/// FFmpeg 不存在、编解码器缺失或编码器报错都会返回错误；调用方负责删临时 WAV 和
/// 可能生成的半成品。`std.process.run` 在 Windows 默认 `CREATE_NO_WINDOW`，不会弹黑框。
pub fn encodeFromWav(allocator: std.mem.Allocator, io: std.Io, wav_path: []const u8, target_path: []const u8, options: Options) !void {
    if (!options.format.needsEncoder()) return;
    var bitrate_buf: [16]u8 = undefined;
    var compression_buf: [8]u8 = undefined;
    const bitrate = try std.fmt.bufPrint(&bitrate_buf, "{d}k", .{options.bitrate_kbps});
    const compression = try std.fmt.bufPrint(&compression_buf, "{d}", .{@min(options.flac_compression, 12)});
    const argv: []const []const u8 = switch (options.format) {
        .wav => unreachable,
        .mp3 => &.{ "ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", wav_path, "-c:a", "libmp3lame", "-b:a", bitrate, target_path },
        .flac => &.{ "ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", wav_path, "-c:a", "flac", "-compression_level", compression, target_path },
        .ogg => &.{ "ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", wav_path, "-c:a", "libvorbis", "-b:a", bitrate, target_path },
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        // 只需要错误码；限制诊断的保留量，避免异常编码器输出吞掉大块内存。
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FfmpegNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.EncoderFailed,
        else => return error.EncoderFailed,
    }
}

test "音频导出格式：扩展名和编码器需求" {
    const testing = std.testing;
    try testing.expectEqualStrings(".wav", Format.wav.extension());
    try testing.expectEqualStrings(".mp3", Format.mp3.extension());
    try testing.expect(!Format.wav.needsEncoder());
    try testing.expect(Format.flac.needsEncoder());
    const path = try targetPath(testing.allocator, "tmp/song.wav", .ogg);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("tmp/song.ogg", path);
}

test "音频导出：FFmpeg 可写 MP3/FLAC/OGG" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const source = "tmp/audio_export_fixture.wav";
    std.Io.Dir.cwd().createDirPath(io, "tmp") catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    var writer = try wav.Writer.create(io, source, 48000, 2);
    try writer.writeFrames(&.{ 0.0, 0.0, 0.25, -0.25, -0.5, 0.5, 0.0, 0.0 });
    try writer.finish();

    const cases = [_]Options{
        .{ .format = .mp3, .bitrate_kbps = 128 },
        .{ .format = .flac, .flac_compression = 8 },
        .{ .format = .ogg, .bitrate_kbps = 128 },
    };
    for (cases) |options| {
        const target = try std.fmt.allocPrint(a, "tmp/audio_export_fixture{s}", .{options.format.extension()});
        defer a.free(target);
        defer std.Io.Dir.cwd().deleteFile(io, target) catch {};
        encodeFromWav(a, io, source, target, options) catch |err| switch (err) {
            error.FfmpegNotFound => return error.SkipZigTest,
            else => return err,
        };
        const stat = try std.Io.Dir.cwd().statFile(io, target, .{});
        try std.testing.expect(stat.size > 0);
    }
}
