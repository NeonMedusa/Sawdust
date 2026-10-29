//! 窗口层的**平台无关**类型：事件 / 鼠标键 / 修饰键 / 帧缓冲。
//!
//! 单独成文件是为了避免循环 import：
//! `window.zig`（平台分派）与 `window_x11.zig`（Linux 后端）都从这里取类型。

const std = @import("std");

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
    /// 滚轮（**单位：一格 = ±1**；delta > 0 = 向上/远离用户；ctrl = 按下 Ctrl，用于横向缩放；
    /// shift = 按下 Shift，用于纵向缩放。
    /// 注：两个平台后端负责把各自的原始单位归一到“格”：
    /// Windows 是 `WHEEL_DELTA(120)` → `/120`；X11 是 Button4/5 一次一格 → `±1`。
    mouse_wheel: struct { x: i32, y: i32, delta: i32, ctrl: bool, alt: bool, shift: bool },
    /// `code` = **Windows 虚拟键码**（0x1B=Esc、0x2E=Delete、0x41..='A'…）。
    /// Linux 后端负责把 X11 keysym 翻译成同一套码——上层 UI 无需分平台。
    key_down: struct { code: u32, repeat: bool, ctrl: bool, shift: bool, alt: bool },
    key_up: struct { code: u32 },
    /// 已翻译的字符（含 IME 结果）
    char: u21,
    /// 窗口尺寸变化
    resize: struct { width: u32, height: u32 },
};

pub const MouseButton = enum { left, right, middle };

/// 拖放落点（客户区坐标）。
/// **为什么要单独带位置**：外部拖放期间指针被**源程序抓住**，我们收不到 MotionNotify，
/// 所以“当前鼠标位置”是陈的——必须用拖放协议自己给的坐标（X11: XdndPosition / Win32: DragQueryPoint）。
pub const DropPoint = struct { x: i32, y: i32 };

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
