//! **POSIX 侧的阻塞 IO 单例**（Linux/macOS 用）。
//!
//! 背景：Zig 0.17 起文件/进程/时钟 API 都要 `std.Io`，但很多调用点是**模型层或工具函数**
//! （`audio_import.probeFile`、窗口的计时、`filedialog`），签名里没有 io，也不想为了
//! 传一个 io 把上层接口全改一遍。
//!
//! 这里放一个**惰性初始化的 `std.Io.Threaded`**：只用它的**同步**能力
//! （open/read、`process.run`、读时钟），不会真的起线程池；也不在退出时释放
//! （进程级单例，进程结束由内核回收）。
//!
//! Windows 侧不引用本文件（那边直接用 Win32 API，不需要 io）。

const std = @import("std");
const builtin = @import("builtin");

var threaded: ?std.Io.Threaded = null;

/// 把**进程环境**交给 `std.Io.Threaded`。
///
/// ⚠️ 不传的后果（实测）：子进程拿到的是**空环境**——`zenity` 没有 `DISPLAY` 直接失败，
/// 我们把它当成“用户取消”，于是“文件 → 打开”永远弹不出对话框。
/// （块指向 libc 自己的存储，**不能释放**；本单例进程级存活，从不 deinit。）
fn processEnviron() std.process.Environ.PosixBlock {
    const ptr: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    var n: usize = 0;
    while (ptr[n] != null) : (n += 1) {}
    return .{ .slice = ptr[0..n :null] };
}

fn initThreaded() std.Io.Threaded {
    if (comptime builtin.os.tag == .windows) {
        // Windows：用全局环境块（同样是为了让子进程能继承）
        return .init(std.heap.page_allocator, .{ .environ = .{ .block = .{ .use_global = true } } });
    }
    return .init(std.heap.page_allocator, .{ .environ = .{ .block = processEnviron() } });
}

/// 取进程级阻塞 io（首次调用时初始化）
pub fn blocking() std.Io {
    if (threaded == null) threaded = initThreaded();
    return threaded.?.io();
}

/// 单调毫秒（窗口双击判定等用）
pub fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(blocking(), .awake).nanoseconds, std.time.ns_per_ms));
}

test "port_io: 子进程能继承进程环境（否则 zenity 拿不到 DISPLAY）" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = blocking();
    // 用一个必然存在的环境变量判定“环境是否被继承”：PATH
    const res = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "sh", "-c", "test -n \"$PATH\" && echo ok || echo empty" },
    }) catch return error.SkipZigTest;
    defer {
        std.testing.allocator.free(res.stdout);
        std.testing.allocator.free(res.stderr);
    }
    try std.testing.expectEqualStrings("ok", std.mem.trimEnd(u8, res.stdout, "\r\n"));
}
