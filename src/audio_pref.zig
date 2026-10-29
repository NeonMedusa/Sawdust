//! 音频后端偏好（`<data_root>/audio.txt` 一行数字；缺失/无法解析 = 自动）。
//!
//! 为什么单独一个模块：设置页（`view_settings.zig`）要能改、主循环（`main.zig`）要能落盘，
//! 两者不能互相 import（成环）。**改后端需要重启**（重建音频设备涉及线程启停，暂不在运行时做）。

const std = @import("std");

pub const Backend = enum(u8) {
    auto = 0,
    pulse = 1,
    alsa = 2,
    jack = 3,
};

/// 当前（本次进程启动时生效的）后端
pub var current: Backend = .auto;
/// 设置页刚点下的选择，等主循环落盘
pub var pending: ?Backend = null;
/// 落盘完成 → 设置页显示"重启后生效"
pub var saved: bool = false;

pub fn label(b: Backend) []const u8 {
    return switch (b) {
        .auto => "自动",
        .pulse => "PulseAudio",
        .alsa => "ALSA",
        .jack => "JACK",
    };
}

/// 可选后端（Windows 只有 WASAPI：miniaudio 的 wasapi 是默认且唯一推荐，其余是历史兜底）
pub const options: []const Backend = if (@import("builtin").os.tag == .windows)
    &.{.auto}
else
    &.{ .auto, .pulse, .alsa, .jack };

/// miniaudio 的 `ma_backend` 编号（pulseaudio=7 / alsa=8 / jack=9）；`.auto` 返回 null
pub fn maBackend(b: Backend) ?c_uint {
    return switch (b) {
        .auto => null,
        .pulse => 7,
        .alsa => 8,
        .jack => 9,
    };
}

fn prefPath(buf: []u8, data_root: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/audio.txt", .{data_root}) catch null;
}

pub fn load(io: std.Io, data_root: []const u8) void {
    var pbuf: [1024]u8 = undefined;
    const p = prefPath(&pbuf, data_root) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, std.heap.page_allocator, .limited(64)) catch return;
    defer std.heap.page_allocator.free(data);
    const t = std.mem.trim(u8, data, " \t\r\n");
    if (t.len == 0) return;
    const n = std.fmt.parseInt(u8, t, 10) catch return;
    current = switch (n) {
        1 => .pulse,
        2 => .alsa,
        3 => .jack,
        else => .auto,
    };
}

pub fn save(io: std.Io, data_root: []const u8) void {
    var pbuf: [1024]u8 = undefined;
    const p = prefPath(&pbuf, data_root) orelse return;
    var tbuf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&tbuf, "{d}\n", .{@backingInt(current)}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch return;
}

test "后端枚举与标签" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0), @backingInt(Backend.auto));
    try testing.expectEqualStrings("JACK", label(.jack));
    try testing.expect(maBackend(.auto) == null);
    try testing.expectEqual(@as(c_uint, 9), maBackend(.jack).?);
    try testing.expect(options.len >= 1);
}
