//! VST3 编辑器在 **X11** 上的最小宿主。
//!
//! 与 Windows 的差别（为什么这里薄得多）：
//! - Windows：插件是 GDI 子窗口，盖在软渲染之上 → 必须 `SetWindowRgn` 裁切 + present 回写跳过；
//! - X11：**X 服务器自动裁掉父窗口绘制里被 child window 覆盖的部分**，
//!   所以不需要区域裁切，也不需要 present 的"跳过矩形"逻辑。
//!
//! 做法：我们建一个容器窗口（`XCreateSimpleWindow`），把它的 id 作为
//! `IPlugView::attached(view, win, "X11EmbedWindowID")` 的 parent 传进去；
//! JUCE/其他框架会在这个容器里再建自己的窗口并绘制。
const std = @import("std");

const Display = opaque {};
pub const Window = c_ulong;

extern "X11" fn XOpenDisplay(?[*:0]const u8) ?*Display;
extern "X11" fn XCreateSimpleWindow(*Display, parent: Window, x: c_int, y: c_int, w: c_uint, h: c_uint, border_width: c_uint, border: c_ulong, background: c_ulong) Window;
extern "X11" fn XDestroyWindow(*Display, Window) c_int;
extern "X11" fn XMapWindow(*Display, Window) c_int;
extern "X11" fn XUnmapWindow(*Display, Window) c_int;
extern "X11" fn XMoveResizeWindow(*Display, Window, x: c_int, y: c_int, w: c_uint, h: c_uint) c_int;
extern "X11" fn XStoreName(*Display, Window, [*:0]const u8) c_int;
extern "X11" fn XFlush(*Display) c_int;
extern "X11" fn XSync(*Display, i32) c_int;
extern "X11" fn XDefaultRootWindow(*Display) Window;
extern "X11" fn XPending(*Display) c_int;
extern "X11" fn XNextEvent(*Display, *XEvent) c_int;
extern "X11" fn XSetErrorHandler(handler: *const fn (*Display, *XErrorEvent) callconv(.c) c_int) ?*const anyopaque;
extern "X11" fn XSelectInput(*Display, Window, long: c_long) c_int;
extern "X11" fn XQueryTree(*Display, Window, root_ret: *Window, parent_ret: *Window, children: *?[*]Window, n: *c_uint) c_int;
extern "X11" fn XSendEvent(*Display, Window, propagate: c_int, event_mask: c_long, ev: *XEvent) c_int;
extern "X11" fn XSetInputFocus(*Display, Window, revert_to: c_int, time: c_ulong) c_int;
extern "X11" fn XFree(data: ?*anyopaque) c_int;
extern "X11" fn XSetWMProtocols(*Display, Window, protocols: [*]c_ulong, count: c_int) c_int;
extern "X11" fn XInternAtom(*Display, name: [*:0]const u8, only_if_exists: c_int) c_ulong;
// ── X11 事件结构（最小集合）──
const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
};
const XButtonEventX = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};
const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    message_type: c_ulong,
    format: c_int,
    data: [5]c_long,
};
const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};
const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    button: XButtonEventX,
    pad: [24]c_long,
};
const XErrorEvent = extern struct {
    type: c_int,
    display: *Display,
    resourceid: c_ulong,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};
const StructureNotifyMask: c_long = 1 << 17;
const RevertToParent: c_int = 2;
const Atom = c_ulong;
extern "X11" fn XQueryPointer(*Display, Window, root_ret: *Window, child_ret: *Window, root_x: *c_int, root_y: *c_int, win_x: *c_int, win_y: *c_int, mask: *c_uint) c_int;

/// 已 unmap/销毁的容器（不再参与同步）
var retired: [16]Window = @splat(0);
fn isRetired(w: Window) bool {
    for (retired) |r| if (r == w) return true;
    return false;
}
fn markRetired(w: Window) void {
    for (&retired) |*r| {
        if (r.* == 0) {
            r.* = w;
            return;
        }
    }
}

// ── X 连接与错误处理 ──
/// 非致命 X 协议错误处理：Xlib 默认遇到协议错误会直接 exit() 整个进程（插件踩过 BadAtom），
/// 所以装一个"只打印一次、然后继续"的处理器。
var err_seen: [256]bool = @splat(false);
fn onXError(_: *Display, ev: *XErrorEvent) callconv(.c) c_int {
    const key: usize = ev.request_code; // 0..255
    if (!err_seen[key]) {
        err_seen[key] = true;
        std.debug.print("[x11] 忽略协议错误：code={d} request={d} minor={d}（插件侧问题，宿主继续）\n", .{
            ev.error_code, ev.request_code, ev.minor_code,
        });
    }
    return 0;
}

/// 进程内共享一条 X 连接（UI 线程用；音频线程不碰 X）
var dpy_global: ?*Display = null;

pub fn display() ?*Display {
    if (dpy_global == null) {
        dpy_global = XOpenDisplay(null);
        if (dpy_global != null) _ = XSetErrorHandler(onXError);
    }
    return dpy_global;
}

/// 容器窗口句柄（以不透明指针形式交给 `Plugin.editor_hwnd` —— X11 的 Window 是 64 位，装得下）
pub fn handleOf(win: Window) *anyopaque {
    return @ptrFromInt(@as(usize, @intCast(win)));
}

fn winOf(handle: *anyopaque) Window {
    return @intCast(@intFromPtr(handle));
}

/// 建容器窗口。`parent` = null → 顶层窗口（CLI 冒烟用）；否则嵌进该窗口。
/// 先创建（未 map），`show` 时才 map —— 与 Windows 侧"先隐藏创建再显示"一致，防闪。
pub fn create(parent: ?*anyopaque, title: [:0]const u8, w: i32, h: i32) ?*anyopaque {
    const dpy = display() orelse return null;
    const parent_win: Window = if (parent) |p| winOf(p) else XDefaultRootWindow(dpy);
    const cw: c_uint = @intCast(@max(1, w));
    const ch: c_uint = @intCast(@max(1, h));
    // 黑底（插件自己会画满）
    const win = XCreateSimpleWindow(dpy, parent_win, 0, 0, cw, ch, 0, 0, 0x000000);
    if (win == 0) return null;
    _ = XStoreName(dpy, win, title.ptr);
    // 顶层窗口（独立插件 UI）：**接管"关闭"动作**——只声明 WM_DELETE_WINDOW，
    // 由我们在 `pump()` 里改成"隐藏"，绝不让 WM 销毁窗口（销毁会让插件侧崩、并连带打死宿主）。
    _ = XSelectInput(dpy, win, StructureNotifyMask);
    var del_atom = XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
    if (del_atom != 0) _ = XSetWMProtocols(dpy, win, @ptrCast(&del_atom), 1);
    _ = XFlush(dpy);
    return handleOf(win);
}

/// 首次显示（map）+ 定位
pub fn show(handle: *anyopaque) void {
    const dpy = display() orelse return;
    _ = XMapWindow(dpy, winOf(handle));
    _ = XFlush(dpy);
    // 规范要求的嵌入握手（只做一次，且不抢焦点）
    ensureXEmbed(handle);
}

pub fn move(handle: *anyopaque, x: i32, y: i32, w: i32, h: i32) void {
    const dpy = display() orelse return;
    _ = XMoveResizeWindow(dpy, winOf(handle), x, y, @intCast(@max(1, w)), @intCast(@max(1, h)));
    _ = XFlush(dpy);
}

/// **区域裁切**：把"绘制在插件之上的矩形"从插件窗口里减掉（等价于 Windows 的 `SetWindowRgn`）。
/// 为什么要：插件窗口是**原生子窗口**，永远盖在我们的软渲染之上；菜单/模态框如果只是画在
/// framebuffer 里，就会被插件窗口挡住。X11 的做法是给**容器窗口**设 bounding shape：
/// 先设整窗，再 `ShapeSubtract` 掉每个遮挡矩形（X 会把子窗口一并裁掉）。
/// `rects` 用**容器本地坐标**；传空 = 恢复默认（不裁切）并请求重绘。
/// 隐藏编辑器：unmap + 取消输入选择，**窗口与插件对象都留着**。
/// （实测：Vital 一旦 `removed()+release()` 就有 GL 线程崩，所以 Linux 侧一律"藏起来不销毁"）
pub fn hide(handle: *anyopaque) void {
    const dpy = display() orelse return;
    _ = XSelectInput(dpy, winOf(handle), 0);
    _ = XUnmapWindow(dpy, winOf(handle));
    _ = XFlush(dpy);
}

/// 重新显示（配合 hide：不重建窗口/视图）
pub fn reshide(handle: *anyopaque) void {
    show(handle);
}

pub fn destroy(handle: *anyopaque) void {
    const dpy = display() orelse return;
    // **不立刻销毁**：插件的 GL/音频线程可能还在往这个窗口投递，销毁会让它们崩。
    // 只 unmap（视觉上消失）+ 取消输入选择，窗口本身留到进程退出。
    const w = winOf(handle);
    markRetired(w);
    _ = XSelectInput(dpy, w, 0);
    _ = XUnmapWindow(dpy, w);
    _ = XFlush(dpy);
}

/// 取容器窗口里**最深**的子窗口（插件自己的 GUI 窗口；JUCE 可能套一层）。
/// 调用方负责 `XFree` 返回数组（内部已 free）。
fn deepestChild(dpy: *Display, container: Window) ?Window {
    var cur = container;
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        var root_ret: Window = 0;
        var parent_ret: Window = 0;
        var children: ?[*]Window = null;
        var n: c_uint = 0;
        if (XQueryTree(dpy, cur, &root_ret, &parent_ret, &children, &n) == 0) return null;
        if (children) |cs| _ = XFree(@ptrCast(cs));
        if (n == 0 or children == null) break;
        cur = children.?[n - 1]; // 最后一个 = 最上层
    }
    return if (cur == container) null else cur;
}

/// 已修过 input shape 的窗口（避免每次 pump 都重设）
// ── XEmbed（freedesktop 规范）──
const XEMBED_EMBEDDED_NOTIFY: c_long = 0;
const XEMBED_WINDOW_ACTIVATE: c_long = 1;
const XEMBED_REQUEST_FOCUS: c_long = 3;
const XEMBED_FOCUS_IN: c_long = 4;
const XEMBED_FOCUS_CURRENT: c_long = 0;
var xembed_atom: c_ulong = 0;
fn xembedAtom(dpy: *Display) c_ulong {
    if (xembed_atom == 0) xembed_atom = XInternAtom(dpy, "_XEMBED", 0);
    return xembed_atom;
}
fn sendXEmbed(dpy: *Display, win: Window, message: c_long, detail: c_long, d3: c_long, d4: c_long) void {
    var ev: XEvent = std.mem.zeroes(XEvent);
    const cm: *XClientMessageEvent = @ptrCast(&ev);
    cm.* = .{
        .type = 33,
        .serial = 0,
        .send_event = 1,
        .display = dpy,
        .window = win,
        .message_type = xembedAtom(dpy),
        .format = 32,
        .data = .{ 0, message, detail, d3, d4 },
    };
    _ = XSendEvent(dpy, win, 0, 0, &ev);
    _ = XFlush(dpy);
}

/// 用户用窗口自己的关闭按钮关掉了哪个容器窗口（单槽；上层每帧取走）
var user_closed: Window = 0;
/// 取走"被用户关闭"的窗口 id（取一次即清空）
pub fn takeUserClosed() ?*anyopaque {
    const w = user_closed;
    user_closed = 0;
    if (w == 0) return null;
    return handleOf(w);
}

var embed_done: [32]Window = @splat(0);
fn embedDone(w: Window) bool {
    for (embed_done) |x| if (x == w) return true;
    return false;
}
fn markEmbedDone(w: Window) void {
    for (&embed_done) |*x| {
        if (x.* == 0) {
            x.* = w;
            return;
        }
    }
}

/// 对容器的插件窗口做一次 XEmbed 握手（幂等）：
/// EMBEDDED_NOTIFY（告诉它谁是 embedder）→ WINDOW_ACTIVATE → FOCUS_IN
pub fn ensureXEmbed(container: *anyopaque) void {
    const dpy = display() orelse return;
    if (isRetired(winOf(container))) return;
    const child = deepestChild(dpy, winOf(container)) orelse return;
    // 每秒最多重发一次（JUCE 可能重建窗口/重映射后才真正就绪）
    if (embedDone(child)) return;
    markEmbedDone(child);
    sendXEmbed(dpy, child, XEMBED_EMBEDDED_NOTIFY, 0, @intCast(winOf(container)), 0);
    sendXEmbed(dpy, child, XEMBED_WINDOW_ACTIVATE, 0, 0, 0);
    sendXEmbed(dpy, child, XEMBED_FOCUS_IN, XEMBED_FOCUS_CURRENT, 0, 0);
    std.debug.print("[x11] 已对插件窗口 0x{x} 完成 XEmbed 握手（NOTIFY/ACTIVATE/FOCUS_IN）\n", .{child});
}

/// 诊断：报告容器窗口里"指针下最深可点窗口"，用来判断点击究竟会落到谁身上。
/// 返回格式：`container=0x.. child=0x.. deepest=0x.. inChild=true/false`
/// 把待处理事件抽干；容器窗口上的输入转发给插件 GUI 窗口。
/// 返回处理的事件数（冒烟/调试用）。
pub fn pump() usize {
    const dpy = display() orelse return 0;
    var n: usize = 0;
    var ev: XEvent = undefined;
    while (XPending(dpy) > 0) : (n += 1) {
        _ = XNextEvent(dpy, &ev);
        switch (ev.type) {
            33 => { // ClientMessage：WM_DELETE_WINDOW（改隐藏）/ XEmbed REQUEST_FOCUS
                const cm: *const XClientMessageEvent = @ptrCast(&ev);
                const del = XInternAtom(dpy, "WM_DELETE_WINDOW", 1);
                if (del != 0 and cm.message_type != xembedAtom(dpy) and cm.data[0] == @as(c_long, @intCast(del))) {
                    user_closed = cm.window;
                    _ = XUnmapWindow(dpy, cm.window);
                    _ = XFlush(dpy);
                    std.debug.print("[x11] 插件窗口被用户关闭 → 改为隐藏（不销毁）\n", .{});
                    return n;
                }
                if (cm.message_type == xembedAtom(dpy) and cm.data[1] == XEMBED_REQUEST_FOCUS) {
                    _ = XSetInputFocus(dpy, cm.window, RevertToParent, 0);
                    sendXEmbed(dpy, cm.window, XEMBED_FOCUS_IN, XEMBED_FOCUS_CURRENT, 0, 0);
                }
            },
            17 => std.debug.print("[x11] 插件窗口 0x{x} 已销毁（不再同步）\n", .{ev.xany.window}), // DestroyNotify
            else => {},
        }
    }
    _ = XFlush(dpy);
    return n;
}

pub fn flush() void {
    if (display()) |dpy| _ = XFlush(dpy);
}
