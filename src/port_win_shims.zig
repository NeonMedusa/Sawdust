//! ⚠️ **临时脚手架（仅 Linux 实验构建用）** ⚠️
//!
//! VST3 宿主（`vst_host.zig`）与主程序里少量子进程/窗口逻辑目前是 **Windows 专用**。
//! 移植它们属于里程碑 L3，不是"能跑起来"的前置条件。
//!
//! 为了让 Linux 版本先能编译/运行，这里把**仍然被引用**的 Win32 符号导出成行为明确的空实现：
//! - 动态库加载 → null（上层得到 `error.LoadLibraryFailed`，走"插件缺失"路径）
//! - 插件编辑器窗口/区域 → null / 0（没有插件实例时根本走不到）
//! - 子进程 → 0（扫描功能在 Linux 上直接拒绝，见 `main.startPluginScan`）
//!
//! **真正的修法**：把 `vst_host.zig` 的平台相关入口用
//! `if (comptime builtin.os.tag == .windows) { … } else { … }` 隔开，Linux 侧返回
//! `error.PluginHostUnavailable`；届时删掉本文件。（清单可随时用
//! `zig build 2>&1 | grep "undefined symbol"` 重新收集。）

const std = @import("std");
comptime {
    _ = std;
}

// ── 动态库加载（vst_host.loadModule）──
export fn LoadLibraryW(path: ?[*:0]const u16) ?*anyopaque {
    _ = path;
    return null;
}
export fn GetProcAddress(lib: ?*anyopaque, name: [*:0]const u8) ?*const anyopaque {
    _ = lib;
    _ = name;
    return null;
}
export fn FreeLibrary(lib: ?*anyopaque) i32 {
    _ = lib;
    return 0;
}
export fn SetErrorMode(mode: u32) u32 {
    _ = mode;
    return 0;
}
export fn GetModuleHandleW(name: ?[*:0]const u16) ?*anyopaque {
    _ = name;
    return null;
}

// ── 子进程（main.zig 的 VST 扫描 worker）──
export fn CreateProcessW(a: ?[*:0]const u16, b: ?[*:0]u16, c: ?*anyopaque, d: ?*anyopaque, e: i32, f: u32, g: ?*anyopaque, h: ?[*:0]const u16, i: ?*anyopaque, j: ?*anyopaque) i32 {
    _ = .{ a, b, c, d, e, f, g, h, i, j };
    return 0;
}
export fn TerminateProcess(h: ?*anyopaque, code: u32) i32 {
    _ = h;
    _ = code;
    return 0;
}
export fn CloseHandle(h: ?*anyopaque) i32 {
    _ = h;
    return 0;
}
export fn GetExitCodeProcess(h: ?*anyopaque, code: *u32) i32 {
    _ = h;
    code.* = 0;
    return 0;
}
export fn GetModuleFileNameW(mod: ?*anyopaque, buf: [*]u16, n: u32) u32 {
    _ = .{ mod, buf, n };
    return 0;
}

// ── 插件编辑器窗口（vst_host.openEditor 等；无插件实例时不会走到）──
export fn RegisterClassExW(wc: ?*const anyopaque) u16 {
    _ = wc;
    return 0;
}
export fn CreateWindowExW(ex: u32, cls: ?[*:0]const u16, name: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) ?*anyopaque {
    _ = .{ ex, cls, name, style, x, y, w, h, parent, menu, inst, param };
    return null;
}
export fn SetWindowLongPtrW(hwnd: ?*anyopaque, index: i32, value: isize) isize {
    _ = .{ hwnd, index, value };
    return 0;
}
export fn GetWindowLongPtrW(hwnd: ?*anyopaque, index: i32) isize {
    _ = hwnd;
    _ = index;
    return 0;
}
export fn DefWindowProcW(hwnd: ?*anyopaque, msg: u32, wp: usize, lp: isize) isize {
    _ = .{ hwnd, msg, wp, lp };
    return 0;
}
export fn DestroyWindow(hwnd: ?*anyopaque) i32 {
    _ = hwnd;
    return 0;
}
export fn SetWindowPos(hwnd: ?*anyopaque, after: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, flags: u32) i32 {
    _ = .{ hwnd, after, x, y, w, h, flags };
    return 0;
}
export fn ShowWindow(hwnd: ?*anyopaque, cmd: i32) i32 {
    _ = hwnd;
    _ = cmd;
    return 0;
}
export fn EnableWindow(hwnd: ?*anyopaque, enable: i32) i32 {
    _ = hwnd;
    _ = enable;
    return 0;
}
export fn SetFocus(hwnd: ?*anyopaque) ?*anyopaque {
    _ = hwnd;
    return null;
}
export fn SetWindowRgn(hwnd: ?*anyopaque, rgn: ?*anyopaque, redraw: i32) i32 {
    _ = .{ hwnd, rgn, redraw };
    return 0;
}

// ── GDI 区域（present 的插件排除区；Linux 走 X11 后端，用不到）──
export fn CreateRectRgn(x0: i32, y0: i32, x1: i32, y1: i32) ?*anyopaque {
    _ = .{ x0, y0, x1, y1 };
    return null;
}
export fn CombineRgn(dst: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, mode: i32) i32 {
    _ = .{ dst, a, b, mode };
    return 0;
}
export fn DeleteObject(obj: ?*anyopaque) i32 {
    _ = obj;
    return 0;
}
