//! 崩溃可诊断性（GUI 子系统专用）：`exe.subsystem = .windows` 没有控制台，
//! panic 默认只写 stderr —— 双击启动时**什么都看不见**（进程静默退出，exit code 3），
//! 这会让"播放中导入崩溃"这类竞态完全无法定位。
//!
//! 对策两条（互不依赖）：
//! 1. 从终端启动（`zig build run`）→ 把输出接回父控制台（见 `vstscan.attachParentConsole`）；
//! 2. 无论从哪里启动，都把 panic 消息**追加**写进工作目录的 `sawdust-crash.log`。
//!
//! 这里用 libc 的 `fopen/fwrite`：panic 路径上不能分配内存、不能依赖 `std.Io` 状态。
const std = @import("std");

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, fp: ?*anyopaque) usize;
extern fn fclose(fp: ?*anyopaque) c_int;

/// 崩溃日志文件名（工作目录；`zig build run` 时就是仓库根）
const log_name = "sawdust-crash.log";

/// 挂在 `main.zig` 的 `pub const panic = std.debug.FullPanic(panicFn);`
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    appendLog("panic: ", msg);
    // 默认处理器：写完栈回溯再 abort（父控制台接上时才可见）
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn appendLog(prefix: []const u8, msg: []const u8) void {
    const fp = fopen(log_name, "ab") orelse return;
    defer _ = fclose(fp);
    if (prefix.len > 0) _ = fwrite(prefix.ptr, 1, prefix.len, fp);
    if (msg.len > 0) _ = fwrite(msg.ptr, 1, msg.len, fp);
    _ = fwrite("\n", 1, 1, fp);
}
