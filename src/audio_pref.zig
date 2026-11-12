//! 音频输出偏好（`<data_root>/audio.txt`）。
//!
//! 设置页与主循环都要访问本模块；音频引擎只在启动时读取，因此改后端或设备都在
//! 下次启动生效。设备以名称保存：设备 ID 是后端私有的二进制联合体，跨重启/驱动
//! 更新并不稳定；找不到同名设备时引擎会安全回退到系统默认设备。

const std = @import("std");

pub const Backend = enum(u8) {
    auto = 0,
    pulse = 1,
    alsa = 2,
    jack = 3,
};

pub const device_name_cap = 256;

pub const Selection = struct {
    backend: Backend = .auto,
    device: [device_name_cap]u8 = @splat(0),
    device_len: usize = 0,

    pub fn deviceName(self: *const Selection) []const u8 {
        return self.device[0..self.device_len];
    }

    fn setDevice(self: *Selection, name: []const u8) void {
        self.device_len = 0;
        for (name) |c| {
            if (self.device_len >= self.device.len) break;
            // 配置是一行一个键；设备名意外含换行时也不能破坏文件结构。
            self.device[self.device_len] = if (c == '\n' or c == '\r') ' ' else c;
            self.device_len += 1;
        }
    }
};

/// 当前（本次进程启动时生效的）选择。
pub var current: Selection = .{};
/// 设置页刚点下的选择，等主循环帧末落盘。
pub var pending: ?Selection = null;
/// 落盘完成 → 设置页显示“重启后生效”。
pub var saved: bool = false;

pub fn label(b: Backend) []const u8 {
    return switch (b) {
        .auto => "自动",
        .pulse => "PulseAudio",
        .alsa => "ALSA",
        .jack => "JACK",
    };
}

/// 可选后端（Windows 只有 WASAPI：miniaudio 的 wasapi 是默认且唯一推荐，其余是历史兜底）。
pub const options: []const Backend = if (@import("builtin").os.tag == .windows)
    &.{.auto}
else
    &.{ .auto, .pulse, .alsa, .jack };

/// miniaudio 的 `ma_backend` 编号（pulseaudio=7 / alsa=8 / jack=9）；`.auto` 返回 null。
pub fn maBackend(b: Backend) ?c_uint {
    return switch (b) {
        .auto => null,
        .pulse => 7,
        .alsa => 8,
        .jack => 9,
    };
}

pub fn shown() *const Selection {
    return if (pending) |*p| p else &current;
}

pub fn requestBackend(backend: Backend) void {
    var next = shown().*;
    next.backend = backend;
    // 换后端时旧设备 ID/name 没有可比性，明确回到新后端的系统默认。
    next.device_len = 0;
    pending = next;
    saved = false;
}

/// `name.len == 0` = 选择系统默认输出设备。
pub fn requestDevice(name: []const u8) void {
    var next = shown().*;
    next.setDevice(name);
    pending = next;
    saved = false;
}

fn prefPath(buf: []u8, data_root: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/audio.txt", .{data_root}) catch null;
}

fn parseBackend(s: []const u8) Backend {
    const n = std.fmt.parseInt(u8, std.mem.trim(u8, s, " \t\r\n"), 10) catch return .auto;
    return switch (n) {
        1 => .pulse,
        2 => .alsa,
        3 => .jack,
        else => .auto,
    };
}

/// 兼容旧版仅存一行数字的文件；新版是 `backend=N` + `device=名称` 两行。
fn parse(data: []const u8) Selection {
    var out = Selection{};
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "backend=")) {
        out.backend = parseBackend(trimmed);
        return out;
    }
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "backend=")) out.backend = parseBackend(line["backend=".len..]);
        if (std.mem.startsWith(u8, line, "device=")) out.setDevice(line["device=".len..]);
    }
    return out;
}

pub fn load(io: std.Io, data_root: []const u8) void {
    var pbuf: [1024]u8 = undefined;
    const p = prefPath(&pbuf, data_root) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, std.heap.page_allocator, .limited(512)) catch return;
    defer std.heap.page_allocator.free(data);
    current = parse(data);
}

pub fn save(io: std.Io, data_root: []const u8) void {
    var pbuf: [1024]u8 = undefined;
    const p = prefPath(&pbuf, data_root) orelse return;
    var text: [320]u8 = undefined;
    const data = std.fmt.bufPrint(&text, "backend={d}\ndevice={s}\n", .{ @backingInt(current.backend), current.deviceName() }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data }) catch return;
}

test "音频偏好：旧格式与设备选择" {
    const testing = std.testing;
    const old = parse("3\n");
    try testing.expectEqual(Backend.jack, old.backend);
    try testing.expectEqualStrings("", old.deviceName());

    const now = parse("backend=2\ndevice=USB Audio\n");
    try testing.expectEqual(Backend.alsa, now.backend);
    try testing.expectEqualStrings("USB Audio", now.deviceName());

    try testing.expectEqualStrings("JACK", label(.jack));
    try testing.expect(maBackend(.auto) == null);
    try testing.expectEqual(@as(c_uint, 9), maBackend(.jack).?);
    try testing.expect(options.len >= 1);
}
