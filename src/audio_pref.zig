//! 音频输出偏好（**纯内存**；持久化在 `settings.json` 的 `audio_backend` / `audio_device`）。
//!
//! 设置页与主循环都要访问本模块；音频引擎只在启动时读取，因此改**后端**要重启生效；
//! 同一后端内改**设备**由引擎立即重开。设备以**名称**保存：设备 ID 是后端私有的二进制
//! 联合体，跨重启/驱动更新并不稳定；找不到同名设备时引擎会安全回退到系统默认设备。
//!
//! 注：早期版本写 `<data_root>/audio.txt`；现在全部设置都在 `settings.json`，旧文件不再读写。

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

/// 从 `settings.json` 装填（启动时一次；`device` 空 = 系统默认）
pub fn fromSettings(backend: i32, device: []const u8) void {
    var s = Selection{ .backend = backendFromInt(backend) };
    s.setDevice(device);
    current = s;
    pending = null;
    saved = false;
}

/// `settings.json` 里的整数 → 后端（未知值 → 自动）
pub fn backendFromInt(n: i32) Backend {
    return switch (n) {
        1 => .pulse,
        2 => .alsa,
        3 => .jack,
        else => .auto,
    };
}

/// 落盘用的整数（与 `backendFromInt` 互逆）
pub fn backendToInt(b: Backend) i32 {
    return @backingInt(b);
}

test "音频偏好：设置值 ↔ 后端、设备名称" {
    const testing = std.testing;
    try testing.expectEqual(Backend.jack, backendFromInt(3));
    try testing.expectEqual(Backend.auto, backendFromInt(99));
    try testing.expectEqual(@as(i32, 2), backendToInt(.alsa));

    fromSettings(2, "USB Audio");
    try testing.expectEqual(Backend.alsa, current.backend);
    try testing.expectEqualStrings("USB Audio", current.deviceName());
    // 很长的设备名被截断，且换行不破坏存储
    var long_buf: [device_name_cap + 40]u8 = @splat('x');
    long_buf[10] = '\n';
    fromSettings(0, &long_buf);
    try testing.expectEqual(@as(usize, device_name_cap), current.deviceName().len);
    try testing.expect(std.mem.indexOfScalar(u8, current.deviceName(), '\n') == null);

    try testing.expectEqualStrings("JACK", label(.jack));
    try testing.expect(maBackend(.auto) == null);
    try testing.expectEqual(@as(c_uint, 9), maBackend(.jack).?);
    try testing.expect(options.len >= 1);
}
