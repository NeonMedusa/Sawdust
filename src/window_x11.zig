//! Linux / X11 窗口后端（WSLg 与原生 X11 都可）。
//!
//! 与 Windows 后端**职责一一对应**：
//! - 建窗（含 WM_DELETE_WINDOW 协议、UTF-8 标题）；
//! - 帧缓冲：用 `c_allocator` 分配 `w*h*4` 字节，交给 `XCreateImage` 持有
//!   （32bpp ZPixmap@24 深度，小端即 BGRA——和 Win32 的 DIB 布局一致，零转换）；
//! - 每帧 `present()` → `XPutImage` + `XFlush`；
//! - 输入事件翻成 `window_types.Event`；**键码统一翻成 Windows VK 码**
//!   （上层 UI 完全不用分平台）。
//!
//! 未做（后续）：文件拖入（XDND）、XIM/IME 中文上屏（现在只有 ASCII 直入）。
//!
//! 为什么要手写 extern：Zig 0.17 移除了 `@cImport`，本项目一律用**预生成绑定**；
//! 这里只用到 Xlib 的很小一撮函数，直接声明比生成 6000 行绑定划算。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui.zig");
const types = @import("window_types.zig");
const port_io = @import("port_io.zig");
const Event = types.Event;
const Modifiers = types.Modifiers;
const Framebuffer = types.Framebuffer;
const MouseButton = types.MouseButton;

// ── Xlib 最小绑定 ──
const Display = opaque {};
const XWindow = c_ulong;
const Atom = c_ulong;
const Visual = opaque {};
const XImage = opaque {};
const XGC = opaque {};
const XCursor = c_ulong;

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8, // 注意：char 后跟 3 字节填充（下面显式补齐，保持与 C 一致）
    _pad: [3]u8 = .{ 0, 0, 0 },
    same_screen: c_int,
};

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    event: XWindow,
    window: XWindow,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: XWindow,
    override_redirect: c_int,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: XWindow,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};

const XEvent = extern union {
    type: c_int,
    selection: XSelectionEvent,
    pad: [24]c_ulong,
    key: XKeyEvent,
    button: XButtonEvent,
    motion: XMotionEvent,
    configure: XConfigureEvent,
    client: XClientMessageEvent,
};

const XColor = extern struct {
    pixel: c_ulong,
    red: c_ushort,
    green: c_ushort,
    blue: c_ushort,
    flags: u8,
    pad: u8,
};

const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    owner: XWindow,
    requestor: XWindow,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    requestor: XWindow,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

const Keysym = c_ulong;

/// X 协议错误事件（只用到前几个字段 + 错误码/请求码）
const XErrorEvent = extern struct {
    type: c_int,
    display: *Display,
    resourceid: XWindow,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};

/// ⚠️ Xlib 默认错误处理器会 **abort 整个进程**（实测：一次 `BadCursor`
/// 把正在拖推子的 DAW 直接干掉）。GUI 程序不能这么死，所以装个**非致命**处理器：
/// 打印到 stderr 后返回 0（忽略），由调用方靠 stderr 排障。
fn xErrorHandler(_: ?*Display, ev: *XErrorEvent) callconv(.c) c_int {
    x_error_count += 1;
    std.debug.print("[x11] 协议错误：code={d} request={d} minor={d} resource=0x{x}\n", .{
        ev.error_code, ev.request_code, ev.minor_code, ev.resourceid,
    });
    return 0;
}

/// 错误计数（回归测试用：跑一组操作后应仍为 0）
var x_error_count: u32 = 0;

extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(dpy: ?*Display) c_int;
extern "X11" fn XDefaultScreen(dpy: ?*Display) c_int;
extern "X11" fn XDefaultVisual(dpy: ?*Display, screen: c_int) ?*Visual;
extern "X11" fn XDefaultDepth(dpy: ?*Display, screen: c_int) c_int;
extern "X11" fn XRootWindow(dpy: ?*Display, screen: c_int) XWindow;
extern "X11" fn XCreateSimpleWindow(dpy: ?*Display, parent: XWindow, x: c_int, y: c_int, w: c_uint, h: c_uint, border_w: c_uint, border: c_ulong, background: c_ulong) XWindow;
extern "X11" fn XSelectInput(dpy: ?*Display, w: XWindow, mask: c_long) c_int;
extern "X11" fn XStoreName(dpy: ?*Display, w: XWindow, name: [*:0]const u8) c_int;
extern "X11" fn XInternAtom(dpy: ?*Display, name: [*:0]const u8, only_if_exists: c_int) Atom;
extern "X11" fn XSetWMProtocols(dpy: ?*Display, w: XWindow, protos: [*]Atom, count: c_int) c_int;
extern "X11" fn XChangeProperty(dpy: ?*Display, w: XWindow, prop: Atom, typ: Atom, format: c_int, mode: c_int, data: [*]const u8, n: c_int) c_int;
extern "X11" fn XMapWindow(dpy: ?*Display, w: XWindow) c_int;
extern "X11" fn XFlush(dpy: ?*Display) c_int;
extern "X11" fn XSync(dpy: ?*Display, discard: c_int) c_int;
extern "X11" fn XPending(dpy: ?*Display) c_int;
extern "X11" fn XNextEvent(dpy: ?*Display, ev: *XEvent) c_int;
extern "X11" fn XCreateImage(dpy: ?*Display, visual: ?*Visual, depth: c_uint, format: c_int, offset: c_int, data: ?[*]u8, w: c_uint, h: c_uint, bitmap_pad: c_int, bytes_per_line: c_int) ?*XImage;
extern "X11" fn XDestroyImage(img: *XImage) c_int;
extern "X11" fn XCreateGC(dpy: ?*Display, d: XWindow, valuemask: c_ulong, values: ?*const anyopaque) ?*XGC;
extern "X11" fn XFreeGC(dpy: ?*Display, gc: ?*XGC) c_int;
extern "X11" fn XPutImage(dpy: ?*Display, d: XWindow, gc: ?*XGC, img: *XImage, src_x: c_int, src_y: c_int, dst_x: c_int, dst_y: c_int, w: c_uint, h: c_uint) c_int;

// ── MIT-SHM（XShm，零拷贝上屏）──
// 布局必须精确匹配 X11 的 `XShmSegmentInfo`（LP64：8+4(+pad)+8+4 → 32 字节）
pub const ShmSegmentInfo = extern struct {
    shmseg: c_ulong = 0,
    shmid: c_int = 0,
    shmaddr: ?*anyopaque = null,
    readOnly: c_int = 0,
};
comptime {
    std.debug.assert(@sizeOf(ShmSegmentInfo) == 32);
}
extern "Xext" fn XShmQueryExtension(dpy: ?*Display) c_int;
extern "Xext" fn XShmCreateImage(dpy: ?*Display, visual: ?*Visual, depth: c_uint, format: c_int, data: ?[*]u8, shminfo: *ShmSegmentInfo, w: c_uint, h: c_uint) ?*XImage;
extern "Xext" fn XShmAttach(dpy: ?*Display, shminfo: *ShmSegmentInfo) c_int;
extern "Xext" fn XShmDetach(dpy: ?*Display, shminfo: *ShmSegmentInfo) c_int;
extern "Xext" fn XShmPutImage(dpy: ?*Display, d: XWindow, gc: ?*XGC, img: *XImage, src_x: c_int, src_y: c_int, dst_x: c_int, dst_y: c_int, w: c_uint, h: c_uint, send_event: c_int) c_int;
extern "c" fn shmget(key: c_int, size: usize, shmflg: c_int) c_int;
extern "c" fn shmat(shmid: c_int, shmaddr: ?*const anyopaque, shmflg: c_int) ?*anyopaque;
extern "c" fn shmdt(shmaddr: ?*const anyopaque) c_int;
extern "c" fn shmctl(shmid: c_int, cmd: c_int, buf: ?*anyopaque) c_int;
const IPC_PRIVATE: c_int = 0;
var shm_attach_errors: u32 = 0;
fn shmAttachErrHandler(_: ?*Display, _: *XErrorEvent) callconv(.c) c_int {
    shm_attach_errors += 1;
    return 0;
}
const IPC_CREAT: c_int = 0o1000;
const IPC_RMID: c_int = 0;
extern "X11" fn XDestroyWindow(dpy: ?*Display, w: XWindow) c_int;
extern "X11" fn XCreateFontCursor(dpy: ?*Display, shape: c_uint) XCursor;
extern "X11" fn XFreePixmap(dpy: ?*Display, pixmap: XWindow) c_int;
extern "X11" fn XSetErrorHandler(handler: ?*const fn (?*Display, *XErrorEvent) callconv(.c) c_int) ?*const anyopaque;
extern "X11" fn XDefineCursor(dpy: ?*Display, w: XWindow, cursor: XCursor) c_int;
extern "X11" fn XFreeCursor(dpy: ?*Display, cursor: XCursor) c_int;
extern "X11" fn XCreateBitmapFromData(dpy: ?*Display, d: XWindow, data: [*]const u8, w: c_uint, h: c_uint) XCursor;
extern "X11" fn XCreatePixmapCursor(dpy: ?*Display, source: XCursor, mask: XCursor, fg: *XColor, bg: *XColor, x: c_uint, y: c_uint) XCursor;
extern "X11" fn XUnmapWindow(dpy: ?*Display, w: XWindow) c_int;
extern "X11" fn XTranslateCoordinates(dpy: ?*Display, src: XWindow, dst: XWindow, src_x: c_int, src_y: c_int, dst_x: *c_int, dst_y: *c_int, child: *XWindow) c_int;
extern "X11" fn XQueryPointer(dpy: ?*Display, w: XWindow, root: ?*XWindow, child: ?*XWindow, root_x: *c_int, root_y: *c_int, win_x: *c_int, win_y: *c_int, mask: *c_uint) c_int;
extern "X11" fn XLookupKeysym(ev: *XKeyEvent, index: c_int) Keysym;
extern "X11" fn XLookupString(ev: *XKeyEvent, buf: [*]u8, nbytes: c_int, keysym: ?*Keysym, status: ?*anyopaque) c_int;

// ── 拖放（XDND）/ 选区转换 ──
extern "X11" fn XSetSelectionOwner(dpy: ?*Display, selection: Atom, owner: XWindow, time: c_ulong) c_int;
extern "X11" fn XGetSelectionOwner(dpy: ?*Display, selection: Atom) XWindow;
extern "X11" fn XConvertSelection(dpy: ?*Display, selection: Atom, target: Atom, property: Atom, requestor: XWindow, time: c_ulong) c_int;
extern "X11" fn XSendEvent(dpy: ?*Display, w: XWindow, propagate: c_int, event_mask: c_long, ev: *XEvent) c_int;
extern "X11" fn XGetWindowProperty(dpy: ?*Display, w: XWindow, prop: Atom, long_offset: c_long, long_length: c_long, delete: c_int, req_type: Atom, actual_type: *Atom, actual_format: *c_int, nitems: *c_ulong, bytes_after: *c_ulong, prop_data: *?[*]u8) c_int;
extern "X11" fn XFree(data: ?*anyopaque) c_int;
extern "X11" fn XkbSetDetectableAutoRepeat(dpy: ?*Display, detectable: c_int, supported: ?*c_int) c_int;

// 事件类型
const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const Expose: c_int = 12;
const DestroyNotify: c_int = 17;
const ConfigureNotify: c_int = 22;
const SelectionClear: c_int = 29;
const SelectionRequest: c_int = 30;
const SelectionNotify: c_int = 31;
const ClientMessage: c_int = 33;

// 事件掩码
const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const ButtonMotionMask: c_long = 1 << 13;
const ExposureMask: c_long = 1 << 15;
const StructureNotifyMask: c_long = 1 << 17;

// 修饰位
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3; // Alt

const ZPixmap: c_int = 2;
const PropModeReplace: c_int = 0;
const XC_left_ptr: c_uint = 68;
const XC_sb_h_double_arrow: c_uint = 108;
const XC_sb_v_double_arrow: c_uint = 116;
const XC_fleur: c_uint = 52;

/// Windows 虚拟键码（与上层 UI 的期望一致）
const VK = struct {
    const back: u32 = 0x08;
    const tab: u32 = 0x09;
    const ret: u32 = 0x0D;
    const shift: u32 = 0x10;
    const ctrl: u32 = 0x11;
    const alt: u32 = 0x12;
    const esc: u32 = 0x1B;
    const space: u32 = 0x20;
    const prior: u32 = 0x21;
    const next: u32 = 0x22;
    const end: u32 = 0x23;
    const home: u32 = 0x24;
    const left: u32 = 0x25;
    const up: u32 = 0x26;
    const right: u32 = 0x27;
    const down: u32 = 0x28;
    const insert: u32 = 0x2D;
    const delete: u32 = 0x2E;
    const lwin: u32 = 0x5B;
    const f1: u32 = 0x70;
};

pub const X11Window = struct {
    allocator: Allocator,
    dpy: ?*Display = null,
    win: XWindow = 0,
    /// 根窗口（拖放坐标换算用）
    root_win: XWindow = 0,
    gc: ?*XGC = null,
    img: ?*XImage = null,
    /// MIT-SHM（零拷贝上屏）：建立时 pixmap 内存就是共享段，服务器直接读
    shm: ?ShmSegmentInfo = null,
    /// 服务器不支持 SHM（例如 WSLg 的 Xwayland 在别的 IPC 命名空间）→ 永久回退 XPutImage
    shm_unsupported: bool = false,
    depth: c_int = 24,
    visual: ?*Visual = null,
    wm_delete: Atom = 0,
    net_wm_name: Atom = 0,
    utf8_string: Atom = 0,
    fb: Framebuffer = .{ .pixels = &.{}, .width = 0, .height = 0 },
    should_quit: bool = false,

    // ── 与 Windows 后端保持一致的**兼容字段** ──
    // Linux 下没有 HWND，但**填的是 X11 窗口 id**：上层（插件编辑器嵌入 / 父子窗口关系）
    // 拿到它就能当 `X11EmbedWindowID` 的 parent 用，main.zig 里的嵌入代码零改动。
    hwnd: ?*anyopaque = null,
    exclude_n: usize = 0,
    exclude_hwnd: [4]?*anyopaque = @splat(null),
    exclude_pos: [4][4]i32 = @splat(@splat(0)),
    events: std.ArrayListUnmanaged(Event) = .empty,
    cursor_kind: ui.CursorKind = .arrow,
    /// 字体光标（arrow / resize_h / resize_v / size_all）——**惰性建一次，之后只切不重建**
    cursors: [4]XCursor = .{ 0, 0, 0, 0 },
    blank_cursor: XCursor = 0,
    /// 鼠标冻结（缩放/推子拖动）：锚点（根坐标）+ 累计位移
    mouse_captured: bool = false,
    /// 上一次运动事件的根坐标（相对累积用）
    anchor_root_x: c_int = 0,
    anchor_root_y: c_int = 0,
    frozen_dx: c_int = 0,
    frozen_dy: c_int = 0,
    /// 双击检测
    last_click_ms: i64 = 0,
    last_click_x: i32 = 0,
    last_click_y: i32 = 0,
    /// 可检测自动重复：记录按下的 keycode（区分首按/重复）
    pressed: [256]bool = @splat(false),
    last_mask: c_uint = 0,

    // ── 拖放（XDND v5）：文件从文件管理器拖进来 ──
    /// 待消费的拖入路径（UTF-8；`takeDropped` 逐个取走）
    dropped: std.ArrayListUnmanaged([]u8) = .empty,
    xdnd_aware: Atom = 0,
    xdnd_selection: Atom = 0,
    xdnd_enter: Atom = 0,
    xdnd_position: Atom = 0,
    xdnd_status: Atom = 0,
    xdnd_drop: Atom = 0,
    xdnd_leave: Atom = 0,
    xdnd_finished: Atom = 0,
    xdnd_action_copy: Atom = 0,
    xdnd_type_list: Atom = 0,
    /// 我们接受的数据类型：`text/uri-list`
    uri_list_atom: Atom = 0,
    /// 转换结果写入的属性名（我们自己的原子）
    drop_prop: Atom = 0,
    /// 当前拖放源窗口（0 = 无）
    drag_source: XWindow = 0,
    /// 当前能否接受（XdndPosition 需要回 XdndStatus）
    drag_accept: bool = false,
    /// 本次拖放的落点（客户区；来自 XdndPosition 的根坐标，经 XTranslateCoordinates 转换）
    drop_pt: ?types.DropPoint = null,
    // ── 剪贴板（Ctrl+V 用）：CLIPBOARD 选区 → 文本
    clip_atom: Atom = 0,
    clip_prop: Atom = 0,
    clip_text: ?[]u8 = null,
    /// 我们当前**提供给**别人的剪贴板内容（Ctrl+C/X 写入；SelectionClear 时释放）
    clip_own: ?[]u8 = null,
    targets_atom: Atom = 0,
    text_atom: Atom = 0,

    pub fn init(self: *X11Window, allocator: Allocator, title: []const u8, width: u32, height: u32) !void {
        self.* = .{ .allocator = allocator };

        const dpy = XOpenDisplay(null) orelse return error.OpenDisplayFailed;
        self.dpy = dpy;
        _ = XSetErrorHandler(xErrorHandler); // 错误不致命（否则一个 BadCursor 就把进程 abort）
        const screen = XDefaultScreen(dpy);
        const root = XRootWindow(dpy, screen);
        self.root_win = root;
        self.visual = XDefaultVisual(dpy, screen);
        self.depth = XDefaultDepth(dpy, screen);

        self.win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 0, 0, 0xFF202020);
        // 上层（插件编辑器嵌入等）通过 `hwnd` 拿"本平台窗口标识"：
        // X11 侧就是窗口 id，直接当 `IPlugView::attached(.., "X11EmbedWindowID")` 的 parent。
        self.hwnd = @ptrFromInt(@as(usize, @intCast(self.win)));
        if (self.win == 0) return error.CreateWindowFailed;

        _ = XSelectInput(dpy, self.win, KeyPressMask | KeyReleaseMask | ButtonPressMask |
            ButtonReleaseMask | PointerMotionMask | ButtonMotionMask | ExposureMask | StructureNotifyMask);

        // 关闭窗口 = 请求退出（WM_DELETE_WINDOW）
        self.wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        self.net_wm_name = XInternAtom(dpy, "_NET_WM_NAME", 0);
        self.utf8_string = XInternAtom(dpy, "UTF8_STRING", 0);
        var proto = [_]Atom{self.wm_delete};
        _ = XSetWMProtocols(dpy, self.win, &proto, 1);

        // ── 拖放（XDND v5）：注册 `XdndAware` = 5，文件管理器才肯往我们这拖 ──
        self.xdnd_aware = XInternAtom(dpy, "XdndAware", 0);
        self.xdnd_selection = XInternAtom(dpy, "XdndSelection", 0);
        self.xdnd_enter = XInternAtom(dpy, "XdndEnter", 0);
        self.xdnd_position = XInternAtom(dpy, "XdndPosition", 0);
        self.xdnd_status = XInternAtom(dpy, "XdndStatus", 0);
        self.xdnd_drop = XInternAtom(dpy, "XdndDrop", 0);
        self.xdnd_leave = XInternAtom(dpy, "XdndLeave", 0);
        self.xdnd_finished = XInternAtom(dpy, "XdndFinished", 0);
        self.xdnd_action_copy = XInternAtom(dpy, "XdndActionCopy", 0);
        self.xdnd_type_list = XInternAtom(dpy, "XdndTypeList", 0);
        self.uri_list_atom = XInternAtom(dpy, "text/uri-list", 0);
        self.drop_prop = XInternAtom(dpy, "SAWDUST_DROP", 0);
        self.clip_atom = XInternAtom(dpy, "CLIPBOARD", 0);
        self.clip_prop = XInternAtom(dpy, "SAWDUST_CLIP", 0);
        self.targets_atom = XInternAtom(dpy, "TARGETS", 0);
        self.text_atom = XInternAtom(dpy, "TEXT", 0);
        {
            // XdndAware 属性：类型 XA_ATOM、format 32、值 = 支持的协议版本（5）
            var ver = [_]c_ulong{5};
            _ = XChangeProperty(dpy, self.win, self.xdnd_aware, 4, 32, PropModeReplace, @ptrCast(&ver), 1); // 4 = XA_ATOM
        }

        self.setTitle(title);

        // 自动重复：让重复走 KeyPress（与 Win32 的 repeat 位语义一致），而不是 Press/Release 成对
        var supported: c_int = 0;
        _ = XkbSetDetectableAutoRepeat(dpy, 1, &supported);

        self.gc = XCreateGC(dpy, self.win, 0, null) orelse return error.CreateGCFailed;

        try self.resizeFramebuffer(width, height);

        _ = XMapWindow(dpy, self.win);
        _ = XFlush(dpy);
    }

    pub fn deinit(self: *X11Window) void {
        const dpy = self.dpy orelse return;
        for (self.dropped.items) |p| self.allocator.free(p);
        if (self.clip_text) |s2| self.allocator.free(s2);
        if (self.clip_own) |s3| self.allocator.free(s3);
        self.dropped.deinit(self.allocator);
        self.shmTeardown(dpy); // 先拆 MIT-SHM（会自行销毁 img）
        if (self.img) |img| {
            _ = XDestroyImage(img); // 顺带释放我们交给它的像素内存（c_allocator == malloc）
            self.img = null;
            self.fb = .{ .pixels = &.{}, .width = 0, .height = 0 };
        }
        if (self.gc) |gc| {
            _ = XFreeGC(dpy, gc);
            self.gc = null;
        }
        if (self.blank_cursor != 0) _ = XFreeCursor(dpy, self.blank_cursor);
        for (self.cursors) |c| {
            if (c != 0) _ = XFreeCursor(dpy, c);
        }
        if (self.win != 0) _ = XDestroyWindow(dpy, self.win);
        _ = XCloseDisplay(dpy);
        self.dpy = null;
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// 本次拖放落点（客户区）——**只读**：由 `takeDropped()` 在队列取空时清空。
    /// 不在这里清的原因：落点与路径可能不在同一帧被消费（顺序错了就会退回到”旧鼠标位置“）。
    /// 请求剪贴板文本（异步：结果由 `clipboardTake` 取走）
    pub fn clipboardRequestText(self: *X11Window) void {
        if (self.dpy) |dpy| {
            _ = XConvertSelection(dpy, self.clip_atom, self.utf8_string, self.clip_prop, self.win, 0);
        }
    }

    /// 写入剪贴板（成为 CLIPBOARD 的 owner；之后要响应别人的 SelectionRequest）
    pub fn clipboardSetText(self: *X11Window, text: []const u8) void {
        const dup = self.allocator.dupe(u8, text) catch return;
        if (self.clip_own) |old| self.allocator.free(old);
        self.clip_own = dup;
        self.clip_text = null; // 旧的读取结果作废
        if (self.dpy) |dpy| {
            _ = XSetSelectionOwner(dpy, self.clip_atom, self.win, 0);
            _ = XFlush(dpy);
        }
    }

    /// 取剪贴板文本（null = 还没到/没有文本）；返回的串由调用方 free
    pub fn clipboardTake(self: *X11Window) ?[]u8 {
        const s = self.clip_text orelse return null;
        self.clip_text = null;
        return s;
    }

    pub fn dropPoint(self: *X11Window) ?types.DropPoint {
        return self.drop_pt;
    }

    pub fn takeDropped(self: *X11Window) ?[]u8 {
        if (self.dropped.items.len == 0) return null;
        const p = self.dropped.orderedRemove(0);
        if (self.dropped.items.len == 0) self.drop_pt = null; // 队列空了 → 落点失效
        return p;
    }

    pub fn resizeFramebuffer(self: *X11Window, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;
        if (self.fb.width == width and self.fb.height == height) return;
        const dpy = self.dpy orelse return;

        if (self.img) |img| {
            _ = XDestroyImage(img); // 释放旧像素缓冲
            self.img = null;
        }
        self.shmTeardown(dpy);

        // **优先 MIT-SHM（零拷贝）**：把像素放进共享段，服务器直接读，不走 X 协议 socket。
        // 1280x760x4 ≈ 3.9 MB/帧，60fps ≈ 233 MB/s —— 走 socket 是 WSLg 下卡顿的主因。
        if (self.shmInit(dpy, width, height)) return;

        const px = std.heap.c_allocator.alloc(u32, @as(usize, width) * height) catch return error.OutOfMemory;
        @memset(px, 0xFF000000);

        const img = XCreateImage(dpy, self.visual, @intCast(self.depth), ZPixmap, 0, @ptrCast(px.ptr), width, height, 32, 0) orelse {
            std.heap.c_allocator.free(px);
            return error.CreateImageFailed;
        };
        self.img = img;
        self.fb = .{ .pixels = px[0 .. @as(usize, width) * height], .width = width, .height = height };
    }

    /// 把 XImage 的 `data` 指针置空（XImage 是 opaque，按 Xlib 布局算偏移：
    /// `int width, height, xoffset, format;` 四个 int 之后就是 `char *data`）
    fn clearImageData(img: *XImage) void {
        const p: *?[*]u8 = @ptrFromInt(@intFromPtr(img) + 4 * @sizeOf(c_int));
        p.* = null;
    }

    /// 尝试建立 MIT-SHM 上屏缓冲；成功返回 true（失败时调用方回退到 XPutImage）'
    fn shmInit(self: *X11Window, dpy: *Display, width: u32, height: u32) bool {
        if (self.shm_unsupported) return false;
        if (XShmQueryExtension(dpy) == 0) return false;
        var info = ShmSegmentInfo{};
        const bytes: usize = @as(usize, width) * height * 4;
        info.shmid = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0o600);
        if (info.shmid < 0) return false;
        const addr = shmat(info.shmid, null, 0) orelse {
            _ = shmctl(info.shmid, IPC_RMID, null);
            return false;
        };
        const raw = @intFromPtr(addr);
        if (raw == std.math.maxInt(usize)) { // (void*)-1
            _ = shmctl(info.shmid, IPC_RMID, null);
            return false;
        }
        info.shmaddr = addr;
        info.readOnly = 0;
        const img = XShmCreateImage(dpy, self.visual, @intCast(self.depth), ZPixmap, @ptrCast(addr), &info, width, height) orelse {
            _ = shmdt(addr);
            _ = shmctl(info.shmid, IPC_RMID, null);
            return false;
        };
        // **探测式 attach**：X 错误是异步的，`XShmAttach` 返回非 0 不代表服务器真的接到了段。
        // 实测 WSLg：Xwayland 跑在**另一个 IPC 命名空间**里（WSLg 系统发行版），
        // SysV 共享段它根本看不到 → BadAccess，画面全灰。所以这里临时挂错误处理器做判定。
        shm_attach_errors = 0;
        const prev_handler = XSetErrorHandler(shmAttachErrHandler);
        const attach_ok = XShmAttach(dpy, &info) != 0;
        _ = XSync(dpy, 0);
        _ = XSetErrorHandler(@ptrCast(prev_handler));
        if (!attach_ok or shm_attach_errors != 0) {
            self.shm_unsupported = true; // 本次会话不再尝试（每帧重试只会白白报错）
            clearImageData(img);
            _ = XDestroyImage(img);
            _ = shmdt(addr);
            _ = shmctl(info.shmid, IPC_RMID, null);
            std.debug.print("[x11] MIT-SHM 不可用（服务器在别的 IPC 命名空间，典型：WSLg）→ 回退 XPutImage\n", .{});
            return false;
        }
        _ = shmctl(info.shmid, IPC_RMID, null);
        _ = XFlush(dpy);

        const px: [*]u32 = @ptrCast(@alignCast(addr));
        @memset(px[0 .. @as(usize, width) * height], 0xFF000000);
        self.img = img;
        self.shm = info;
        self.fb = .{ .pixels = px[0 .. @as(usize, width) * height], .width = width, .height = height };
        return true;
    }

    /// 拆掉 MIT-SHM（换尺寸/退出时）；从 fb 引用的内存也交回内核
    fn shmTeardown(self: *X11Window, dpy: *Display) void {
        const info = self.shm orelse return;
        self.shm = null;
        if (self.img) |img| {
            clearImageData(img); // shm 内存由 shmdt 释放，绝不让 XDestroyImage 去 free
            _ = XDestroyImage(img);
            self.img = null;
        }
        _ = XShmDetach(dpy, @constCast(&info));
        if (info.shmaddr) |a| _ = shmdt(a);
        _ = XFlush(dpy);
        self.fb = .{ .pixels = &.{}, .width = 0, .height = 0 };
    }

    pub fn setTitle(self: *X11Window, title: []const u8) void {
        const dpy = self.dpy orelse return;
        if (self.win == 0) return;
        // _NET_WM_NAME（UTF-8，中文/emoji 安全）；XStoreName 作为老 WM 的 ASCII 兜底
        _ = XChangeProperty(dpy, self.win, self.net_wm_name, self.utf8_string, 8, PropModeReplace, title.ptr, @intCast(title.len));
        var buf: [512]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        _ = XStoreName(dpy, self.win, @ptrCast(&buf));
        _ = XFlush(dpy);
    }

    pub fn setCursor(self: *X11Window, kind: ui.CursorKind) void {
        if (self.cursor_kind == kind) return;
        self.cursor_kind = kind;
        const dpy = self.dpy orelse return;
        const cur = self.cursorFor(kind);
        if (cur != 0) _ = XDefineCursor(dpy, self.win, cur);
        _ = XFlush(dpy);
    }

    /// 惰性创建并返回对应光标（建过一次就复用）
    fn cursorFor(self: *X11Window, kind: ui.CursorKind) XCursor {
        const dpy = self.dpy orelse return 0;
        if (kind == .hidden) {
            if (self.blank_cursor == 0) self.blank_cursor = self.makeBlankCursor();
            return self.blank_cursor;
        }
        const idx: usize = switch (kind) {
            .arrow => 0,
            .resize_h => 1,
            .resize_v => 2,
            .size_all => 3,
            .hidden => unreachable,
        };
        if (self.cursors[idx] == 0) {
            const shape: c_uint = switch (kind) {
                .arrow => XC_left_ptr,
                .resize_h => XC_sb_h_double_arrow,
                .resize_v => XC_sb_v_double_arrow,
                .size_all => XC_fleur,
                .hidden => unreachable,
            };
            self.cursors[idx] = XCreateFontCursor(dpy, shape);
        }
        return self.cursors[idx];
    }

    /// 1×1 全透明光标（拖动冻结时隐藏鼠标）
    fn makeBlankCursor(self: *X11Window) XCursor {
        const dpy = self.dpy orelse return 0;
        const zeros = [_]u8{ 0, 0, 0, 0 };
        const src = XCreateBitmapFromData(dpy, self.win, &zeros, 1, 1);
        const msk = XCreateBitmapFromData(dpy, self.win, &zeros, 1, 1);
        var black = XColor{ .pixel = 0, .red = 0, .green = 0, .blue = 0, .flags = 0, .pad = 0 };
        const cur = XCreatePixmapCursor(dpy, src, msk, &black, &black, 0, 0);
        // ⚠️ 这里拿到的是 **pixmap** 而不是 cursor：必须用 `XFreePixmap`
        // （写成 XFreeCursor → BadCursor → Xlib 默认处理器直接 abort 进程，实测事故）
        if (src != 0) _ = XFreePixmap(dpy, src);
        if (msk != 0) _ = XFreePixmap(dpy, msk);
        return cur;
    }

    /// 当前修饰键状态：**从事件里跟踪**（不再每帧 `XQueryPointer` 同步往返）。
    /// Xwayland 上一次往返 ~0.1~0.3 ms，60fps 下白花 1~2% CPU；本 UI 只用它做框选/批量，
    /// “焦点在别处时略陈旧”可以接受。（Windows 侧仍用 `GetKeyState`，语义略强一点。）
    pub fn modifiers(self: *X11Window) Modifiers {
        return .{
            .ctrl = (self.last_mask & ControlMask) != 0,
            .shift = (self.last_mask & ShiftMask) != 0,
        };
    }

    /// 开始鼠标冻结（缩放/推子拖动）：记下当前指针位置，之后位移**相对累积**进 frozen_dx/dy。
    ///
    /// ⚠️ **故意不用 `XWarpPointer`**（Windows 那边靠 `SetCursorPos` 把指针钉在锚点）。
    /// 实测（WSLg/Xwayland）warp 会导致推子“时快时慢 + 偶尔反向”：
    /// warp 的回声事件与真实事件交错，靠 `warping` 标志去重会丢真实位移；
    /// composite 侧还可能把指针位置夹回/回跳，造成负增量。
    /// 改成“相邻两次运动事件的根坐标差”累加：无回声、无竞态，手感就是“拖多远动多少”。
    pub fn beginMouseCapture(self: *X11Window) void {
        if (self.mouse_captured) return;
        const dpy = self.dpy orelse return;
        var rr: XWindow = 0;
        var cr: XWindow = 0;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        _ = XQueryPointer(dpy, self.win, &rr, &cr, &rx, &ry, &wx, &wy, &mask);
        self.anchor_root_x = rx;
        self.anchor_root_y = ry;
        self.frozen_dx = 0;
        self.frozen_dy = 0;
        self.mouse_captured = true;
    }

    pub fn endMouseCapture(self: *X11Window) void {
        self.mouse_captured = false;
    }

    pub fn frozenDeltaY(self: *X11Window) i32 {
        return if (self.mouse_captured) self.frozen_dy else 0;
    }

    /// 普通拖动捕获：X11 在按键按下期间对本窗口有**隐式抓取**（指针移出窗口
    /// 仍会收到 Release），所以这里无需 `XGrabPointer`——保持空实现即可。
    pub fn setDragCapture(self: *X11Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn present(self: *X11Window) void {
        const dpy = self.dpy orelse return;
        const img = self.img orelse return;
        if (self.fb.width == 0 or self.fb.height == 0) return;
        if (self.shm != null) {
            // 零拷贝：只告诉服务器“去读那块共享内存”。
            // `XSync` 保证服务器已拷完才返回，下一帧我们才安全地覆写同一块内存
            // （本地实测这仍是 XPutImage 的零头；后续可换成 ShmCompletion 事件省掉往返）
            _ = XShmPutImage(dpy, self.win, self.gc, img, 0, 0, 0, 0, self.fb.width, self.fb.height, 0);
            _ = XSync(dpy, 0);
            return;
        }
        _ = XPutImage(dpy, self.win, self.gc, img, 0, 0, 0, 0, self.fb.width, self.fb.height);
        _ = XFlush(dpy);
    }

    pub fn pollEvents(self: *X11Window) ![]const Event {
        self.events.clearRetainingCapacity();
        const dpy = self.dpy orelse return self.events.items;
        var ev: XEvent = undefined;
        while (XPending(dpy) != 0) {
            _ = XNextEvent(dpy, &ev);
            self.handleEvent(&ev);
        }
        return self.events.items;
    }

    pub fn shouldQuit(self: *X11Window) bool {
        return self.should_quit;
    }

    fn push(self: *X11Window, e: Event) void {
        self.events.append(self.allocator, e) catch {};
    }

    fn maskBits(mask: c_uint) struct { ctrl: bool, shift: bool, alt: bool } {
        return .{
            .ctrl = (mask & ControlMask) != 0,
            .shift = (mask & ShiftMask) != 0,
            .alt = (mask & Mod1Mask) != 0,
        };
    }

    fn handleEvent(self: *X11Window, ev: *XEvent) void {
        switch (ev.type) {
            ConfigureNotify => {
                const cf = ev.configure;
                const w: u32 = if (cf.width > 0) @intCast(cf.width) else 0;
                const h: u32 = if (cf.height > 0) @intCast(cf.height) else 0;
                if (w > 0 and h > 0) {
                    self.resizeFramebuffer(w, h) catch {};
                    self.push(.{ .resize = .{ .width = w, .height = h } });
                }
            },
            Expose => self.present(),
            ClientMessage => {
                const cm = ev.client;
                if (cm.message_type == self.wm_delete) {
                    self.should_quit = true;
                    self.push(.quit);
                } else if (cm.message_type == self.xdnd_enter) {
                    // data.l[0] = 源窗口；l[2..4] = 前三个类型原子；l[1] bit0 = 还有更多类型
                    self.drag_source = @intCast(cm.data.l[0]);
                    self.drag_accept = true;
                } else if (cm.message_type == self.xdnd_position) {
                    self.drag_source = @intCast(cm.data.l[0]);
                    // 落点：**不能用当前鼠标位置**（拖放期间指针被源程序抓住，我们收不到 MotionNotify）
                    if (self.dpy) |dpy| {
                        const rx: c_int = @intCast((cm.data.l[2] >> 16) & 0xFFFF);
                        const ry: c_int = @intCast(cm.data.l[2] & 0xFFFF);
                        var wx: c_int = 0;
                        var wy: c_int = 0;
                        var child: XWindow = 0;
                        if (XTranslateCoordinates(dpy, self.root_win, self.win, rx, ry, &wx, &wy, &child) != 0) {
                            self.drop_pt = .{ .x = wx, .y = wy };
                        }
                    }
                    // 必须回 XdndStatus，否则源端会认为目标不接
                    self.xdndSendStatus(self.drag_accept);
                } else if (cm.message_type == self.xdnd_drop) {
                    self.drag_source = @intCast(cm.data.l[0]);
                    if (self.drop_pt) |p| {
                        std.debug.print("[drop] XdndDrop 落点(客户区) = ({d},{d})\n", .{ p.x, p.y });
                    } else {
                        std.debug.print("[drop] XdndDrop 时落点为空（Position 没算出来）\n", .{});
                    }
                    const ts: c_ulong = @intCast(cm.data.l[2]);
                    // 请源端把 `text/uri-list` 写进我们的属性
                    if (self.dpy) |dpy| {
                        _ = XConvertSelection(dpy, self.xdnd_selection, self.uri_list_atom, self.drop_prop, self.win, ts);
                    }
                } else if (cm.message_type == self.xdnd_leave) {
                    self.drag_source = 0;
                    self.drag_accept = false;
                    self.drop_pt = null;
                } else if (cm.message_type == self.xdnd_finished) {
                    self.drag_source = 0;
                } else if (cm.data.l[0] == @as(c_long, @intCast(self.wm_delete))) {
                    self.should_quit = true;
                    self.push(.quit);
                }
            },
            SelectionRequest => {
                self.answerSelectionRequest(@ptrCast(ev));
            },
            SelectionClear => {
                const clr: *const XSelectionEvent = @ptrCast(ev);
                if (clr.selection == self.clip_atom) {
                    if (self.clip_own) |old| self.allocator.free(old);
                    self.clip_own = null; // 别人抢走了剪贴板
                }
            },
            SelectionNotify => {
                // 只有我们自己的拖放转换才处理
                const sel: *const XSelectionEvent = @ptrCast(ev); // 注意：ev 已经是指针（写 &ev 会读到局部变量本身——实测踩过）
                if (sel.property == self.drop_prop) {
                    self.finishDrop();
                } else if (sel.property == self.clip_prop) {
                    self.finishClipboard();
                }
            },
            MotionNotify => {
                const mv = ev.motion;
                self.last_mask = mv.state;
                if (self.mouse_captured) {
                    // 相对累积（不需要/不执行 warp）——见 `beginMouseCapture` 的注释
                    self.frozen_dx += mv.x_root - self.anchor_root_x;
                    self.frozen_dy += mv.y_root - self.anchor_root_y;
                    self.anchor_root_x = mv.x_root;
                    self.anchor_root_y = mv.y_root;
                }
                self.push(.{ .mouse_move = .{ .x = mv.x, .y = mv.y } });
            },
            ButtonPress => {
                const b = ev.button;
                self.last_mask = b.state;
                if (b.button == 4 or b.button == 5 or b.button == 6 or b.button == 7) {
                    const m = maskBits(b.state);
                    // ⚠️ **单位是“一格” = ±1，不是 Windows 的 120**：
                    // Windows 后端已经做了 `@divTrunc(delta, 120)`（见 window.zig 的 WM_MOUSEWHEEL），
                    // 上层 UI 全部按“±1/格”写（如 `ui.wheel * 30` 像素/格）。
                    // 这里曾误传 ±120 → 滚一格 = 120 格（实测：播放列表一下滚过上百条）。
                    const delta: i32 = if (b.button == 4 or b.button == 6) 1 else -1;
                    self.push(.{ .mouse_wheel = .{ .x = b.x, .y = b.y, .delta = delta, .ctrl = m.ctrl, .alt = m.alt, .shift = m.shift } });
                    return;
                }
                const btn: MouseButton = switch (b.button) {
                    1 => .left,
                    2 => .middle,
                    3 => .right,
                    else => return,
                };
                // 双击：先判（并照 Win32 的做法**同时**补一条 mouse_down**）
                const now = port_io.nowMs();
                const dbl = btn == .left and
                    (now - self.last_click_ms) <= 500 and
                    @abs(b.x - self.last_click_x) <= 4 and
                    @abs(b.y - self.last_click_y) <= 4;
                self.last_click_ms = if (dbl) 0 else now;
                self.last_click_x = b.x;
                self.last_click_y = b.y;
                self.push(.{ .mouse_down = .{ .x = b.x, .y = b.y, .button = btn } });
                if (dbl) self.push(.{ .mouse_double = .{ .x = b.x, .y = b.y } });
            },
            ButtonRelease => {
                const b = ev.button;
                self.last_mask = b.state;
                if (b.button == 4 or b.button == 5 or b.button == 6 or b.button == 7) return;
                const btn: MouseButton = switch (b.button) {
                    1 => .left,
                    2 => .middle,
                    3 => .right,
                    else => return,
                };
                self.push(.{ .mouse_up = .{ .x = b.x, .y = b.y, .button = btn } });
            },
            KeyPress, KeyRelease => {
                const k = ev.key;
                self.last_mask = k.state;
                const m = maskBits(k.state);
                const sym = XLookupKeysym(@ptrCast(@constCast(&k)), 0);
                const code = keysymToVk(sym);
                if (ev.type == KeyPress) {
                    var repeat = false;
                    if (k.keycode < self.pressed.len) {
                        repeat = self.pressed[k.keycode];
                        self.pressed[k.keycode] = true;
                    }
                    if (code != 0) {
                        self.push(.{ .key_down = .{ .code = code, .repeat = repeat, .ctrl = m.ctrl, .shift = m.shift, .alt = m.alt } });
                    }
                    // 文本输入：`XLookupString` 会带上修饰键效果（Shift+1 = '!'、大写字母），
                    // 而上面 `XLookupKeysym(.., 0)` 只给**未按 Shift 的**符号（专用于 VK 映射）。
                    // （中文 IME 待接 XIM）
                    if (!m.ctrl and !m.alt) {
                        var cbuf: [8]u8 = undefined;
                        var ks: Keysym = 0;
                        const n = XLookupString(@ptrCast(@constCast(&k)), &cbuf, cbuf.len, &ks, null);
                        if (n == 1 and cbuf[0] >= 0x20 and cbuf[0] < 0x7F) {
                            self.push(.{ .char = @intCast(cbuf[0]) });
                        }
                    }
                } else {
                    if (k.keycode < self.pressed.len) self.pressed[k.keycode] = false;
                    if (code != 0) self.push(.{ .key_up = .{ .code = code } });
                }
            },
            DestroyNotify => {
                self.should_quit = true;
                self.push(.quit);
            },
            else => {},
        }
    }

    // ── 拖放（XDND）──

    /// 回 `XdndStatus`（源端据此决定要不要真的投递）
    fn xdndSendStatus(self: *X11Window, accept: bool) void {
        const dpy = self.dpy orelse return;
        if (self.drag_source == 0) return;
        var ev: XEvent = std.mem.zeroes(XEvent);
        ev.client.type = ClientMessage;
        ev.client.display = dpy;
        ev.client.window = self.drag_source;
        ev.client.message_type = self.xdnd_status;
        ev.client.format = 32;
        ev.client.data.l[0] = @intCast(self.win);
        ev.client.data.l[1] = if (accept) 1 else 0;
        ev.client.data.l[4] = if (accept) @intCast(self.xdnd_action_copy) else 0;
        _ = XSendEvent(dpy, self.drag_source, 0, 0, &ev);
        _ = XFlush(dpy);
    }

    /// 回 `XdndFinished`（告诉源端“收下了”/“不收”）。
    /// 注意：必须先发这个离开拖放，否则文件管理器会一直转着“复制中”。
    fn xdndSendFinished(self: *X11Window, ok: bool) void {
        const dpy = self.dpy orelse return;
        if (self.drag_source == 0) {
            self.drag_accept = false;
            return;
        }
        var ev: XEvent = std.mem.zeroes(XEvent);
        ev.client.type = ClientMessage;
        ev.client.display = dpy;
        ev.client.window = self.drag_source;
        ev.client.message_type = self.xdnd_finished;
        ev.client.format = 32;
        ev.client.data.l[0] = @intCast(self.win);
        ev.client.data.l[1] = if (ok) 1 else 0;
        ev.client.data.l[2] = @intCast(self.xdnd_action_copy);
        _ = XSendEvent(dpy, self.drag_source, 0, 0, &ev);
        _ = XFlush(dpy);
        self.drag_source = 0;
        self.drag_accept = false;
    }

    /// `SelectionNotify` 到达：把属性里的 `text/uri-list` 取出来解析成路径
    fn finishDrop(self: *X11Window) void {
        const dpy = self.dpy orelse return;
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var n_items: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var data: ?[*]u8 = null;
        // long_length 用字节数 / 4（每单元 32 位）；给 1 MB 预算够拖很多东西了
        const rc = XGetWindowProperty(dpy, self.win, self.drop_prop, 0, 262144, 1, 0, &actual_type, &actual_format, &n_items, &bytes_after, &data);
        if (rc != 0 or data == null or n_items == 0) {
            if (data) |d| _ = XFree(d);
            self.xdndSendFinished(false);
            return;
        }
        defer _ = XFree(data.?);

        var added: usize = 0;
        if (actual_format == 8) {
            const bytes = data.?[0..@intCast(n_items)];
            added = self.addDroppedUris(bytes);
        }
        self.xdndSendFinished(added > 0);
    }

    /// 别人来要数据（我们拥有 CLIPBOARD）：按 ICCCM 回 TARGETS / UTF8_STRING / TEXT / STRING
    fn answerSelectionRequest(self: *X11Window, req: *const XSelectionRequestEvent) void {
        const dpy = self.dpy orelse return;
        var prop: Atom = req.property;
        if (prop == 0) prop = req.target; // 老式客户端的约定
        var ok = false;
        const data = self.clip_own orelse &.{};

        if (req.target == self.targets_atom) {
            var list = [_]c_ulong{ @intCast(self.utf8_string), @intCast(self.text_atom), 31 }; // 31 = XA_STRING
            _ = XChangeProperty(dpy, req.requestor, prop, 4, 32, PropModeReplace, @ptrCast(&list), 3); // 4 = XA_ATOM
            ok = true;
        } else if (req.target == self.utf8_string or req.target == self.text_atom or req.target == 31) {
            const typ: Atom = if (req.target == 31) 31 else self.utf8_string;
            _ = XChangeProperty(dpy, req.requestor, prop, typ, 8, PropModeReplace, data.ptr, @intCast(data.len));
            ok = true;
        }

        var notify: XEvent = std.mem.zeroes(XEvent);
        notify.selection.type = SelectionNotify;
        notify.selection.display = dpy;
        notify.selection.requestor = req.requestor;
        notify.selection.selection = req.selection;
        notify.selection.target = req.target;
        notify.selection.property = if (ok) prop else 0;
        notify.selection.time = req.time;
        _ = XSendEvent(dpy, req.requestor, 0, 0, &notify);
        _ = XFlush(dpy);
    }

    /// 剪贴板文本到达：读属性 → 复制成 UTF-8
    fn finishClipboard(self: *X11Window) void {
        const dpy = self.dpy orelse return;
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var n_items: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var data: ?[*]u8 = null;
        const rc = XGetWindowProperty(dpy, self.win, self.clip_prop, 0, 1 << 20, 1, 0, &actual_type, &actual_format, &n_items, &bytes_after, &data);
        if (rc != 0 or data == null or n_items == 0) {
            if (data) |d| _ = XFree(d);
            return;
        }
        defer _ = XFree(data.?);
        if (actual_format != 8) return;
        const dup = self.allocator.dupe(u8, data.?[0..@intCast(n_items)]) catch return;
        if (self.clip_text) |old| self.allocator.free(old);
        self.clip_text = dup;
    }

    /// `text/uri-list` → 路径列表（每行一个 `file://` URI；`#` 开头为注释）
    fn addDroppedUris(self: *X11Window, blob: []const u8) usize {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, blob, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            const path = uriToPath(self.allocator, line) orelse continue;
            self.dropped.append(self.allocator, path) catch {
                self.allocator.free(path);
                continue;
            };
            n += 1;
        }
        return n;
    }
};

/// `file:///a/b%20c` → `/a/b c`（百分号解码；非 file:// 前缀返回 null）
fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // 主机部分通常为空（file:///path）；有主机时跳过到第一个 '/'
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const ch = rest[i];
        if (ch == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                out.append(allocator, ch) catch return null;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
                out.append(allocator, ch) catch return null;
                continue;
            };
            out.append(allocator, @as(u8, @intCast(hi * 16 + lo))) catch return null;
            i += 2;
        } else {
            out.append(allocator, ch) catch return null;
        }
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return null;
    };
}

/// X11 keysym → Windows 虚拟键码。返回 0 = 不关心。
fn keysymToVk(keysym: Keysym) u32 {
    const sym: u32 = @truncate(keysym);
    // 可打印 ASCII：字母统一大写（UI 里对 'A'/'a' 都做了判断）
    if (sym >= 'a' and sym <= 'z') return sym - 0x20;
    if (sym >= 'A' and sym <= 'Z') return sym;
    if (sym >= '0' and sym <= '9') return sym;
    if (sym == ' ') return VK.space;
    if (sym == ';' or sym == '=' or sym == ',' or sym == '-' or sym == '.' or sym == '/' or sym == '`' or
        sym == '[' or sym == '\\' or sym == ']' or sym == '\'') return sym;

    return switch (sym) {
        0xFF08 => VK.back, // BackSpace
        0xFF09 => VK.tab, // Tab
        0xFF0D, 0xFF8D => VK.ret, // Return / KP_Enter
        0xFF1B => VK.esc, // Escape
        0xFF50 => VK.home, // Home
        0xFF51 => VK.left, // Left
        0xFF52 => VK.up, // Up
        0xFF53 => VK.right, // Right
        0xFF54 => VK.down, // Down
        0xFF55 => VK.prior, // Page_Up
        0xFF56 => VK.next, // Page_Down
        0xFF57 => VK.end, // End
        0xFF63 => VK.insert, // Insert
        0xFFFF => VK.delete, // Delete
        0xFFE1, 0xFFE2 => VK.shift, // Shift_L/R
        0xFFE3, 0xFFE4 => VK.ctrl, // Control_L/R
        0xFFE9, 0xFFEA => VK.alt, // Alt_L/R
        0xFFEB, 0xFFEC, 0xFFE7, 0xFFE8 => VK.lwin, // Super/Hyper
        else => blk: {
            // F1..F12：keysym 0xFFBE..0xFFC9
            if (sym >= 0xFFBE and sym <= 0xFFC9) {
                break :blk VK.f1 + @as(u32, @intCast(sym - 0xFFBE));
            }
            break :blk 0;
        },
    };
}

test "x11: 光标切换（含隐藏光标）不产生 X 错误" {
    // 回归：曾经用 `XFreeCursor` 释放 `XCreateBitmapFromData` 出来的 **pixmap**
    // → BadCursor → Xlib 默认处理器直接 abort 进程（拖推子/缩放时必崩，实测事故）。
    // 需要真实 X 服务器（WSLg / 真机）；没有显示器则跳过。
    var w: X11Window = undefined;
    w.init(std.testing.allocator, "sawdust-cursor-test", 64, 64) catch return error.SkipZigTest;
    defer w.deinit();

    x_error_count = 0;
    w.setCursor(.resize_v);
    w.setCursor(.hidden); // ← 首次创建空白光标（事故点）
    w.setCursor(.resize_h);
    w.setCursor(.hidden); // 再次切换（复用已有光标）
    w.setCursor(.size_all);
    w.setCursor(.arrow);
    if (w.dpy) |dpy| _ = XSync(dpy, 0); // 强制把请求走完：错误在这里显现
    try std.testing.expectEqual(@as(u32, 0), x_error_count);
}
