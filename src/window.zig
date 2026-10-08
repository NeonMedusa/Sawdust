//! 窗口层：Win32 直接调用（零第三方依赖）。
//!
//! 设计要点：
//! - 只负责「窗口 + 消息 + 帧缓冲呈现」，不含任何 UI 逻辑；
//! - 帧缓冲用 `CreateDIBSection` 拿到**可直接写的内存指针**（软件光栅化的基础）；
//! - 每帧流程：UI 往 framebuffer 写像素 → `present()` 用 BitBlt 推到窗口；
//! - 输入事件（鼠标/键盘）转成统一的 `Event`，由上层（UI 层）消费。
//!
//! 将来跨平台时，只需替换本文件（Linux: X11/Wayland + 共享内存；macOS: Cocoa + CGContext）。

const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag == .windows) WindowsWindow else UnsupportedWindow;

/// 统一输入事件（跨平台抽象）
pub const Event = union(enum) {
    quit,
    /// 鼠标移动（客户区坐标）
    mouse_move: struct { x: i32, y: i32 },
    mouse_down: struct { x: i32, y: i32, button: MouseButton },
    mouse_up: struct { x: i32, y: i32, button: MouseButton },
    /// 双击（左键；窗口类需 CS_DBLCLKS）。
    /// **注意**：系统在双击时间窗内不发第二次 WM_LBUTTONDOWN，只发 WM_LBUTTONDBLCLK，
    /// 因此本事件会**同时**发一条 mouse_down（否则快速连点的第二下被吞）。
    mouse_double: struct { x: i32, y: i32 },
    /// 滚轮（delta > 0 = 向上/远离用户；ctrl = 按下 Ctrl，用于横向缩放）
    mouse_wheel: struct { x: i32, y: i32, delta: i32, ctrl: bool, alt: bool },
    key_down: struct { code: u32, repeat: bool, ctrl: bool, shift: bool, alt: bool },
    key_up: struct { code: u32 },
    /// 已翻译的字符（含 IME 结果）
    char: u21,
    /// 窗口尺寸变化
    resize: struct { width: u32, height: u32 },
};

pub const MouseButton = enum { left, right, middle };

/// 修饰键状态（每帧由 main 从窗口读取；框选/批量操作用）
pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
};

/// 帧缓冲：BGRA 像素（与 Win32 的 32 位 DIB 格式一致，可直接 blit）
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn fill(self: *Framebuffer, color: u32) void {
        @memset(self.pixels, color);
    }
};

// ── Windows 实现 ──

const WindowsWindow = struct {
    const win = std.os.windows;

    hwnd: ?*anyopaque = null,
    hdc_window: ?*anyopaque = null, // 窗口 DC（GetDC）
    hdc_mem: ?*anyopaque = null, // 内存 DC
    hbitmap: ?*anyopaque = null,
    old_bitmap: ?*anyopaque = null,
    fb: Framebuffer = .{ .pixels = &.{}, .width = 0, .height = 0 },
    allocator: std.mem.Allocator,
    should_quit: bool = false,
    /// 当前系统光标（避免重复设置）
    cursor_kind: @import("ui.zig").CursorKind = .arrow,
    /// 当前光标句柄（WM_SETCURSOR 时重设，防止系统改回默认）
    cursor_handle: ?*anyopaque = null,
    /// 空白光标（隐藏用；懒创建一次）
    blank_cursor: ?*anyopaque = null,
    /// 鼠标冻结（□ 缩放拖动）：位移累积、光标锚定不动
    mouse_captured: bool = false,
    /// 普通拖动捕获中（滚动条/片段/音符）
    drag_captured: bool = false,
    anchor_client: POINT = .{ .x = 0, .y = 0 },
    anchor_screen: POINT = .{ .x = 0, .y = 0 },
    frozen_dx: i32 = 0,
    frozen_dy: i32 = 0,
    /// 最近一次鼠标位置（客户区；冻结锚点用）
    last_mouse: POINT = .{ .x = 0, .y = 0 },
    /// 事件队列（主循环每帧排空）
    events: std.ArrayListUnmanaged(Event) = .{ .items = &.{}, .capacity = 0 },

    /// 初始化（**必须**在稳定的内存地址上调用：`var win: WindowsWindow = undefined; try win.init(...)`）。
    /// 注意：不能用"返回值 + 局部变量取址"的写法——WndProc 里保存的 `&self` 在
    /// 返回值拷贝后会变成悬垂指针（会段错误）。
    pub fn init(self: *WindowsWindow, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !void {
        self.* = WindowsWindow{ .allocator = allocator };

        // 提升系统计时器精度到 1ms（**必须**：默认粒度 ≈ 15.6ms，
        // `Io.sleep(8ms)` 实测睡成 ~15.6ms、`sleep(16ms)` 睡成 ~26ms——
        // 帧率被腰斩，表现为“UI 不流畅/操作滞后”。实测数据见 docs/pitfalls.md）
        _ = timeBeginPeriod(1);

        // DPI 感知（避免系统缩放导致模糊）
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

        const hinstance = GetModuleHandleW(null);

        var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
        wc.cbSize = @sizeOf(WNDCLASSEXW);
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC | CS_DBLCLKS;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinstance;
        wc.hCursor = LoadCursorW(null, IDC_ARROW);
        wc.lpszClassName = class_name;
        if (RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

        // 用 UTF-16 标题（支持中文）
        var title_buf: [256]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], title) catch 0;
        title_buf[title_len] = 0;

        // 计算窗口尺寸（客户区 = 请求的宽高）
        var rect = RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        _ = AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0);

        self.hwnd = CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_buf),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;

        // 关联 self（WndProc 里取回）
        _ = SetWindowLongPtrW(@ptrCast(self.hwnd), GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        // 初始光标句柄（WM_SETCURSOR 用）
        self.cursor_handle = LoadCursorW(null, IDC_ARROW);

        self.hdc_window = GetDC(@ptrCast(self.hwnd));
        if (self.hdc_window == null) return error.GetDCFailed;
        self.hdc_mem = CreateCompatibleDC(@ptrCast(self.hdc_window));
        if (self.hdc_mem == null) return error.CreateDCFailed;

        try self.resizeFramebuffer(width, height);
    }

    pub fn deinit(self: *WindowsWindow) void {
        // 恢复系统计时器精度（与 init 的 timeBeginPeriod(1) 配对）
        _ = timeEndPeriod(1);
        if (self.hbitmap) |hb| {
            if (self.hdc_mem) |dc| {
                if (self.old_bitmap) |ob| _ = SelectObject(@ptrCast(dc), @ptrCast(ob));
            }
            _ = DeleteObject(@ptrCast(hb));
        }
        if (self.hdc_mem) |dc| _ = DeleteDC(@ptrCast(dc));
        if (self.hdc_window) |dc| _ = ReleaseDC(@ptrCast(self.hwnd), @ptrCast(dc));
        if (self.hwnd) |h| _ = DestroyWindow(@ptrCast(h));
        if (self.blank_cursor) |c| _ = DestroyCursor(@ptrCast(c));
        _ = UnregisterClassW(class_name, null);
        // 注意：fb.pixels 指向 **GDI 的 DIB 内存**（CreateDIBSection 分配），
        // 由 DeleteObject(hbitmap) 释放——绝不能用 allocator.free（那是非法释放，会段错误）。
        self.events.deinit(self.allocator);
    }

    /// 重建帧缓冲（窗口尺寸变化时）
    pub fn resizeFramebuffer(self: *WindowsWindow, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return; // 最小化
        if (self.fb.width == width and self.fb.height == height) return;

        if (self.hbitmap) |hb| {
            if (self.old_bitmap) |ob| _ = SelectObject(@ptrCast(self.hdc_mem.?), @ptrCast(ob));
            _ = DeleteObject(@ptrCast(hb));
            self.hbitmap = null;
        }

        const bmi = BITMAPINFO{
            .bmiHeader = .{
                .biSize = @sizeOf(BITMAPINFOHEADER),
                .biWidth = @intCast(width),
                .biHeight = -@as(i32, @intCast(height)), // 负值 = 自上而下
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = BI_RGB,
            },
            .bmiColors = .{.{ .rgbBlue = 0, .rgbGreen = 0, .rgbRed = 0, .rgbReserved = 0 }},
        };

        var bits: ?*anyopaque = null;
        const hbmp = CreateDIBSection(
            @ptrCast(self.hdc_window),
            &bmi,
            DIB_RGB_COLORS,
            &bits,
            null,
            0,
        ) orelse return error.CreateDIBFailed;

        self.hbitmap = hbmp;
        self.old_bitmap = SelectObject(@ptrCast(self.hdc_mem.?), @ptrCast(hbmp));

        // 让 framebuffer 指向 DIB 内存（零拷贝：写像素即写窗口位图）
        const px: [*]u32 = @ptrCast(@alignCast(bits.?));
        self.fb.pixels = px[0 .. width * height];
        self.fb.width = width;
        self.fb.height = height;
    }

    /// 设置窗口标题（脏标记 `*` 用）
    pub fn setTitle(self: *WindowsWindow, title: []const u8) void {
        if (self.hwnd == null) return;
        // UTF-8 → UTF-16（栈缓冲，标题不会太长）
        var buf: [512]u16 = undefined;
        const need = std.unicode.calcUtf16LeLen(title) catch return;
        if (need >= buf.len) return;
        _ = std.unicode.utf8ToUtf16Le(buf[0..need], title) catch return;
        buf[need] = 0;
        _ = SetWindowTextW(@ptrCast(self.hwnd), @ptrCast(&buf));
    }

    /// 切换系统光标（UI 每帧按需调用；仅在变化时真正切换，避免每帧刷 Win32）
    pub fn setCursor(self: *WindowsWindow, kind: @import("ui.zig").CursorKind) void {
        if (self.cursor_kind == kind) return;
        self.cursor_kind = kind;
        const hcur: ?*anyopaque = switch (kind) {
            .arrow => LoadCursorW(null, IDC_ARROW),
            .resize_h => LoadCursorW(null, IDC_SIZEWE),
            .resize_v => LoadCursorW(null, IDC_SIZENS),
            .size_all => LoadCursorW(null, IDC_SIZEALL),
            .hidden => self.blankCursor(),
        };
        if (hcur) |h| {
            self.cursor_handle = h;
            _ = SetClassLongPtrW(@ptrCast(self.hwnd), GCLP_HCURSOR, @bitCast(@intFromPtr(h)));
            // 立即生效：向窗口发 WM_SETCURSOR 由系统重取类光标
            _ = SetCursor(@ptrCast(h));
        }
    }

    /// 当前修饰键状态（Ctrl/Shift；每帧由 main 读取——
    /// 键盘事件里只带按下瞬间的状态，而框选等手势需要“当前”状态）
    pub fn modifiers(self: *WindowsWindow) Modifiers {
        _ = self;
        const ctrl = (@as(u16, @bitCast(GetKeyState(VK_CONTROL))) & 0x8000) != 0;
        const shift = (@as(u16, @bitCast(GetKeyState(VK_SHIFT))) & 0x8000) != 0;
        return .{ .ctrl = ctrl, .shift = shift };
    }

    /// 空白光标（1×1 全透明；懒创建一次）
    fn blankCursor(self: *WindowsWindow) ?*anyopaque {
        if (self.blank_cursor) |c| return c;
        const and_mask = [_]u8{0xFF}; // AND=1 & XOR=0 → 保留屏幕 = 全透明
        const xor_mask = [_]u8{0x00};
        const c = CreateCursor(GetModuleHandleW(null), 0, 0, 1, 1, @ptrCast(&and_mask), @ptrCast(&xor_mask));
        self.blank_cursor = c;
        return c;
    }

    /// 开始鼠标冻结（□ 缩放拖动）：锚定当前位置，位移累积到 frozen_dx/dy。
    /// 已冻结时无操作——主循环可每帧调用。
    pub fn beginMouseCapture(self: *WindowsWindow) void {
        if (self.mouse_captured) return;
        self.anchor_client = self.last_mouse;
        var pt = self.anchor_client;
        _ = ClientToScreen(@ptrCast(self.hwnd), &pt);
        self.anchor_screen = pt;
        self.frozen_dx = 0;
        self.frozen_dy = 0;
        self.mouse_captured = true;
        // 捕获鼠标：快速拖出窗口也照常收事件（否则光标一旦出窗就冻结失效）
        _ = SetCapture(@ptrCast(self.hwnd));
    }

    /// 结束鼠标冻结（未冻结时无操作）
    pub fn endMouseCapture(self: *WindowsWindow) void {
        if (!self.mouse_captured) return;
        self.mouse_captured = false;
        _ = ReleaseCapture();
    }

    /// 冻结期间的累积垂直位移（未冻结时恒为 0）
    pub fn frozenDeltaY(self: *WindowsWindow) i32 {
        return if (self.mouse_captured) self.frozen_dy else 0;
    }

    /// 普通拖动期间捕获鼠标（滚动条/片段/音符等）：
    /// 拖出窗口后仍能收到鼠标事件（**尤其是松开**）——否则拖动状态卡死，
    /// 鼠标移回时误触发拖动分支（表现为“松手后回弹/跳变”）。
    pub fn setDragCapture(self: *WindowsWindow, on: bool) void {
        if (self.drag_captured == on) return;
        self.drag_captured = on;
        if (on) {
            _ = SetCapture(@ptrCast(self.hwnd));
        } else {
            _ = ReleaseCapture();
        }
    }

    /// 把帧缓冲推到窗口
    pub fn present(self: *WindowsWindow) void {
        if (self.fb.width == 0 or self.fb.height == 0) return;
        _ = BitBlt(
            @ptrCast(self.hdc_window.?),
            0,
            0,
            @intCast(self.fb.width),
            @intCast(self.fb.height),
            @ptrCast(self.hdc_mem.?),
            0,
            0,
            SRCCOPY,
        );
    }

    /// 排空消息队列，把系统消息转成统一事件
    pub fn pollEvents(self: *WindowsWindow) ![]const Event {
        self.events.clearRetainingCapacity();
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return self.events.items;
    }

    pub fn shouldQuit(self: *WindowsWindow) bool {
        return self.should_quit;
    }

    fn pushEvent(self: *WindowsWindow, ev: Event) void {
        self.events.append(self.allocator, ev) catch {};
    }

    const class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("SawdustWindow");

    /// 从 32 位打包坐标取低 16 位（有符号）
    fn lowWordSigned(v: u32) i32 {
        const w: u16 = @truncate(v);
        return @as(i16, @bitCast(w));
    }
    /// 取高 16 位（有符号）
    fn highWordSigned(v: u32) i32 {
        const w: u16 = @truncate(v >> 16);
        return @as(i16, @bitCast(w));
    }

    fn wndProc(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        const userdata = GetWindowLongPtrW(@ptrCast(hwnd), GWLP_USERDATA);
        const self: ?*WindowsWindow = if (userdata != 0) @ptrFromInt(@as(usize, @intCast(userdata))) else null;

        switch (msg) {
            WM_CLOSE => {
                if (self) |s| s.should_quit = true;
                return 0;
            },
            WM_DESTROY => {
                if (self) |s| s.should_quit = true;
                return 0;
            },
            WM_SIZE => {
                if (self) |s| {
                    const w: u32 = @intCast(lparam & 0xffff);
                    const h: u32 = @intCast((lparam >> 16) & 0xffff);
                    s.resizeFramebuffer(w, h) catch {};
                    s.pushEvent(.{ .resize = .{ .width = w, .height = h } });
                }
                return 0;
            },
            WM_SETCURSOR => {
                // 客户区：按当前光标句柄重设（防止系统在移动时改回类光标默认值）
                if (self) |s| {
                    if ((wparam & 0xffff) == 1) { // HTCLIENT
                        if (s.cursor_handle) |h| {
                            _ = SetCursor(@ptrCast(h));
                            return 1;
                        }
                    }
                }
                return DefWindowProcW(@ptrCast(hwnd), msg, wparam, lparam);
            },
            WM_MOUSEMOVE => {
                if (self) |s| {
                    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
                    const x = lowWordSigned(lp);
                    const y = highWordSigned(lp);
                    s.last_mouse = .{ .x = x, .y = y };
                    if (s.mouse_captured) {
                        // 冻结模式：超出死区才累积位移并拉回锚点（光标隐藏、位置不动）
                        const dx = x - s.anchor_client.x;
                        const dy = y - s.anchor_client.y;
                        if (dx > mouse_deadzone or dx < -mouse_deadzone or dy > mouse_deadzone or dy < -mouse_deadzone) {
                            s.frozen_dx += dx;
                            s.frozen_dy += dy;
                            _ = SetCursorPos(s.anchor_screen.x, s.anchor_screen.y);
                        }
                    } else {
                        s.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } });
                    }
                }
                return 0;
            },
            WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN => {
                if (self) |s| {
                    const button: MouseButton = switch (msg) {
                        WM_LBUTTONDOWN => .left,
                        WM_RBUTTONDOWN => .right,
                        else => .middle,
                    };
                    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
                    const x = lowWordSigned(lp);
                    const y = highWordSigned(lp);
                    s.last_mouse = .{ .x = x, .y = y };
                    s.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = button } });
                }
                return 0;
            },
            WM_LBUTTONDBLCLK => {
                if (self) |s| {
                    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
                    const x = lowWordSigned(lp);
                    const y = highWordSigned(lp);
                    s.last_mouse = .{ .x = x, .y = y };
                    // 双击 = 第二次按下（系统在此情况下**不再发** WM_LBUTTONDOWN）——
                    // 必须同时发一条 mouse_down，否则“快速连点”的第二下被吞
                    // （实测 bug：琴键连点不发声；任何“每下都要响应”的交互同理）
                    s.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = .left } });
                    s.pushEvent(.{ .mouse_double = .{ .x = x, .y = y } });
                }
                return 0;
            },
            WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP => {
                if (self) |s| {
                    const button: MouseButton = switch (msg) {
                        WM_LBUTTONUP => .left,
                        WM_RBUTTONUP => .right,
                        else => .middle,
                    };
                    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
                    s.pushEvent(.{ .mouse_up = .{ .x = lowWordSigned(lp), .y = highWordSigned(lp), .button = button } });
                }
                return 0;
            },
            WM_MOUSEWHEEL => {
                if (self) |s| {
                    const delta: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(wparam >> 16)))));
                    // wparam 低位是键状态标志：MK_CONTROL = 0x0008。
                    // **Alt 没有对应的 MK_ 标志**（0x0020 是 MK_XBUTTON1！）——
                    // 必须用 GetKeyState(VK_MENU)（实测 bug：用 wparam 位判断
                    // Alt 永远为 false，alt+滚轮完全无效）。
                    const ctrl = (wparam & 0x0008) != 0;
                    const alt = (@as(u16, @bitCast(GetKeyState(VK_MENU))) & 0x8000) != 0;
                    // 屏幕坐标 → 客户区坐标
                    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
                    var pt = POINT{ .x = lowWordSigned(lp), .y = highWordSigned(lp) };
                    _ = ScreenToClient(@ptrCast(hwnd), &pt);
                    s.pushEvent(.{ .mouse_wheel = .{ .x = pt.x, .y = pt.y, .delta = @divTrunc(delta, 120), .ctrl = ctrl, .alt = alt } });
                }
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN => {
                if (self) |s| {
                    const repeat = (lparam & (1 << 30)) != 0;
                    // Ctrl / Shift 状态（快捷键如 Ctrl+S / Ctrl+Shift+S）
                    // 注：返回 i16，0x8000 需经 u16 位转换判断
                    const ctrl = (@as(u16, @bitCast(GetKeyState(VK_CONTROL))) & 0x8000) != 0;
                    const shift = (@as(u16, @bitCast(GetKeyState(VK_SHIFT))) & 0x8000) != 0;
                    const alt = (@as(u16, @bitCast(GetKeyState(VK_MENU))) & 0x8000) != 0;
                    s.pushEvent(.{ .key_down = .{ .code = @intCast(wparam), .repeat = repeat, .ctrl = ctrl, .shift = shift, .alt = alt } });
                }
                return 0;
            },
            WM_SYSCOMMAND => {
                // 系统菜单（含 Alt+F4 / 关闭）：转成关闭请求
                if ((wparam & 0xFFF0) == SC_CLOSE) {
                    if (self) |s| s.should_quit = true;
                    return 0;
                }
            },
            WM_KEYUP, WM_SYSKEYUP => {
                if (self) |s| s.pushEvent(.{ .key_up = .{ .code = @intCast(wparam) } });
                return 0;
            },
            WM_CHAR => {
                if (self) |s| {
                    const ch: u21 = @intCast(wparam & 0xffff);
                    // 过滤控制字符（保留退格/回车等由 key_down 处理）
                    if (ch >= 32) s.pushEvent(.{ .char = ch });
                }
                return 0;
            },
            WM_ERASEBKGND => return 1, // 我们自己画，避免闪烁
            else => {},
        }
        return DefWindowProcW(@ptrCast(hwnd), msg, wparam, lparam);
    }
};

// ── Win32 类型与常量（手写声明，避免依赖 zigwin32）──

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (?*anyopaque, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct {
    hwnd: ?*anyopaque,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
    lPrivate: u32 = 0,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const RGBQUAD = extern struct { rgbBlue: u8, rgbGreen: u8, rgbRed: u8, rgbReserved: u8 };

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD,
};

const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const CS_OWNDC: u32 = 0x0020;
const CS_DBLCLKS: u32 = 0x0008;
const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_VISIBLE: u32 = 0x10000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const IDC_ARROW: ?*anyopaque = @ptrFromInt(32512);
const IDC_SIZEWE: ?*anyopaque = @ptrFromInt(32644);
const IDC_SIZENS: ?*anyopaque = @ptrFromInt(32645);
/// 十字箭头（四向；音符可横竖拖动时用）
const IDC_SIZEALL: ?*anyopaque = @ptrFromInt(32646);
/// 鼠标冻结死区（像素；超出才累积位移并拉回锚点）。
/// 值越小缩放越细腻；2 兼顾“过滤硬件微抖”与“细粒度累积”。
const mouse_deadzone: i32 = 2;
const GCLP_HCURSOR: i32 = -12;
const VK_CONTROL: i32 = 0x11;
const VK_SHIFT: i32 = 0x10;
const VK_MENU: i32 = 0x12; // Alt
const GWLP_USERDATA: i32 = -21;
const PM_REMOVE: u32 = 0x0001;
const WM_CLOSE: u32 = 0x0010;
const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_SETCURSOR: u32 = 0x0020;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_CHAR: u32 = 0x0102;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_SYSKEYUP: u32 = 0x0105;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_SYSCOMMAND: u32 = 0x0112;
const SC_CLOSE: usize = 0xF060;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;
const SRCCOPY: u32 = 0x00CC0020;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn UnregisterClassW([*:0]const u16, ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(*anyopaque) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(?*anyopaque, *anyopaque) callconv(.winapi) i32;
extern "user32" fn PeekMessageW(*MSG, ?*anyopaque, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetCursor(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetClassLongPtrW(*anyopaque, i32, isize) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(*anyopaque, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(*anyopaque, i32) callconv(.winapi) isize;
extern "user32" fn SetWindowTextW(?*anyopaque, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(*anyopaque, *POINT) callconv(.winapi) i32;
extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
extern "user32" fn ClientToScreen(?*anyopaque, *POINT) callconv(.winapi) i32;
extern "user32" fn SetCursorPos(i32, i32) callconv(.winapi) i32;
extern "user32" fn CreateCursor(?*anyopaque, i32, i32, i32, i32, *const anyopaque, *const anyopaque) ?*anyopaque;
extern "user32" fn DestroyCursor(*anyopaque) callconv(.winapi) i32;
extern "user32" fn SetCapture(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(.winapi) i32;
// winmm：提升系统计时器精度（默认 15.6ms 粒度会把 sleep(8ms) 拉成 ~15.6ms）
extern "winmm" fn timeBeginPeriod(uPeriod: u32) callconv(.winapi) u32;
extern "winmm" fn timeEndPeriod(uPeriod: u32) callconv(.winapi) u32;
extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(*anyopaque) callconv(.winapi) i32;
extern "gdi32" fn CreateDIBSection(?*anyopaque, *const BITMAPINFO, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(*anyopaque, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) i32;
extern "gdi32" fn BitBlt(*anyopaque, i32, i32, i32, i32, *anyopaque, i32, i32, u32) callconv(.winapi) i32;

// ── 非 Windows 占位（编译期隔离；移植时替换本文件）──

const UnsupportedWindow = struct {
    pub fn init(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !UnsupportedWindow {
        _ = allocator;
        _ = title;
        _ = width;
        _ = height;
        @compileError("窗口层尚未移植到该平台：请实现 src/window.zig 的对应后端（Linux: X11/Wayland；macOS: Cocoa）");
    }
    pub fn deinit(self: *UnsupportedWindow) void {
        _ = self;
    }
    pub fn present(self: *UnsupportedWindow) void {
        _ = self;
    }
    pub fn setCursor(self: *UnsupportedWindow, kind: @import("ui.zig").CursorKind) void {
        _ = self;
        _ = kind;
    }
    pub fn beginMouseCapture(self: *UnsupportedWindow) void {
        _ = self;
    }
    pub fn endMouseCapture(self: *UnsupportedWindow) void {
        _ = self;
    }
    pub fn frozenDeltaY(self: *UnsupportedWindow) i32 {
        _ = self;
        return 0;
    }
    pub fn modifiers(self: *UnsupportedWindow) Modifiers {
        _ = self;
        return .{};
    }
    pub fn setDragCapture(self: *UnsupportedWindow, on: bool) void {
        _ = self;
        _ = on;
    }
    pub fn setTitle(self: *UnsupportedWindow, title: []const u8) void {
        _ = self;
        _ = title;
    }
    pub fn pollEvents(self: *UnsupportedWindow) ![]const Event {
        _ = self;
        return &.{};
    }
    pub fn shouldQuit(self: *UnsupportedWindow) bool {
        _ = self;
        return true;
    }
};

test "framebuffer: fill 写入所有像素" {
    var buf: [4]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 2, .height = 2 };
    fb.fill(0xFF00FF00);
    for (buf) |px| try std.testing.expectEqual(@as(u32, 0xFF00FF00), px);
}
