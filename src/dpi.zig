//! UI 缩放（DPI）检测：**纯阶梯**（平台无关、无分配、好测）。
//!
//! X11 没有统一的 DPI API，只能按各桌面的约定依次试探。顺序照抄 SDL3
//! （`src/video/x11/SDL_x11modes.c` 的 `X11_GetGlobalContentScale`）+ ArchWiki HiDPI 的实践：
//!
//! 1. Windows：`GetDpiForWindow() / 96`（per-monitor）
//! 2. `Gdk/WindowScalingFactor`（XSETTINGS；GNOME/Xfce 的**协议级**值，1 = 100%）
//! 3. `Xft/DPI`（XSETTINGS；单位是 **1/1024 dpi**）
//! 4. `Xft.dpi`（root 的 `RESOURCE_MANAGER` 属性；必须**实时读属性**，见 window_x11）
//! 5. `GDK_SCALE` / `QT_SCALE_FACTOR` / `QT_SCREEN_SCALE_FACTORS`（用户显式设的环境变量）
//! 6. 屏幕 ppi 估算（**只当建议**：ppi ≥ 130 且上面全没命中时才自动用）
//! 7. 1.0
//!
//! 两条铁律：
//!
//! - **绝不相乘**：`Xft.dpi` 与 `GDK_SCALE` 同时存在时相乘会把界面放大两倍
//!   （ArchWiki 明确警告过），所以"命中即返回"；
//! - 每个来源都是"桌面/用户已经表达过的意图"，没有谁的优先级高于"用户自己"——
//!   用户在设置页勾掉"自动"时**根本不走这里**。

const std = @import("std");

/// 缩放来源（设置页要显示"凭什么推荐这个"，见 `label` / `Result.detail`）
pub const Source = enum {
    /// 用户固定值（auto = false，不检测）
    settings,
    /// Windows `GetDpiForWindow`（per-monitor DPI）
    windows_dpi,
    /// XSETTINGS `Gdk/WindowScalingFactor`
    xs_scaling,
    /// XSETTINGS `Xft/DPI`（1/1024 dpi）
    xs_dpi,
    /// `Xft.dpi`（root RESOURCE_MANAGER）
    xft_dpi,
    /// `GDK_SCALE` / `QT_SCALE_FACTOR` / `QT_SCREEN_SCALE_FACTORS`
    env_scale,
    /// 屏幕 ppi 估算（只当建议）
    physical,
    /// 都没命中 → 1.0
    fallback,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .settings => "设置",
            .windows_dpi => "Windows 系统 DPI",
            .xs_scaling, .xs_dpi => "XSETTINGS",
            .xft_dpi => "Xft.dpi",
            .env_scale => "环境变量",
            .physical => "屏幕 ppi 估算",
            .fallback => "未检测到",
        };
    }
};

pub const min_scale: f32 = 0.75;
pub const max_scale: f32 = 4.0;

/// 物理 ppi 自动应用门槛：4K 27" ≈ 163ppi、1080p 24" ≈ 92ppi
const phys_min_ppi: f32 = 130;
/// 物理估算最多自动放大到 200%（再大就该用户自己决定）
const phys_max_scale: f32 = 2.0;

/// 各后端的原始输入（X11 填 XSETTINGS/Xft/mm；Windows 只填 `windows_dpi`）。
pub const Raw = struct {
    /// Windows：`GetDpiForWindow`（0 = 无）
    windows_dpi: f32 = 0,
    /// XSETTINGS `Gdk/WindowScalingFactor`（0 = 无；1 = 100%）
    xs_scaling: i32 = 0,
    /// XSETTINGS `Xft/DPI`（1/1024 dpi；0 = 无）
    xs_dpi: i32 = 0,
    /// `Xft.dpi`（0 = 无）
    xft_dpi: f32 = 0,
    /// 环境变量（空 = 无）。切片只在本次调用内有效（来自 getenv）
    gdk_scale: []const u8 = "",
    qt_scale: []const u8 = "",
    /// 屏幕像素宽 / 物理毫米宽（任一 ≤ 0 = 无）
    screen_px_w: i32 = 0,
    screen_mm_w: i32 = 0,
};

/// 检测结果：缩放值 + 来源 + **人话依据**（设置页直接显示）
pub const Result = struct {
    scale: f32 = 1.0,
    source: Source = .fallback,
    detail_buf: [72]u8 = @splat(0),
    detail_len: usize = 0,

    pub fn detail(self: *const Result) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn set(self: *const Result, scale: f32, src: Source, comptime fmt: []const u8, args: anytype) Result {
        var r = self.*;
        r.scale = std.math.clamp(scale, min_scale, max_scale);
        r.source = src;
        const s: []u8 = std.fmt.bufPrint(&r.detail_buf, fmt, args) catch r.detail_buf[0..0];
        r.detail_len = s.len;
        return r;
    }
};

/// 解析环境变量形式的缩放值（"2" / "1.5" / "150%" 不接受；越界返回 null）
pub fn parseScale(s: []const u8) ?f32 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    const v = std.fmt.parseFloat(f32, t) catch return null;
    if (!(v >= min_scale and v <= max_scale)) return null;
    return v;
}

/// `QT_SCREEN_SCALE_FACTORS` 是分号分隔的**每屏**列表（如 `"1;1.5"`）→ 取第一个
pub fn firstListToken(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.indexOfScalar(u8, t, ';')) |i| return std.mem.trim(u8, t[0..i], " \t");
    return t;
}

/// 把环境变量填进 `raw`（X11/Windows 通用；调用方随后补平台自己的字段）。
pub fn fillEnv(raw: *Raw) void {
    if (std.c.getenv("GDK_SCALE")) |v| raw.gdk_scale = std.mem.span(v);
    // Qt：`QT_SCALE_FACTOR` 是全局系数；`QT_SCREEN_SCALE_FACTORS` 是每屏列表
    if (std.c.getenv("QT_SCALE_FACTOR")) |v| {
        raw.qt_scale = std.mem.span(v);
    } else if (std.c.getenv("QT_SCREEN_SCALE_FACTORS")) |v| {
        raw.qt_scale = firstListToken(std.mem.span(v));
    }
}

/// 阶梯：**命中即返回**（绝不相乘）
pub fn fromRaw(raw: Raw) Result {
    const r = Result{};
    // 1. Windows 系统 DPI（per-monitor；用户把窗口拖到另一块屏时会变）
    if (raw.windows_dpi >= 48.0) {
        return r.set(raw.windows_dpi / 96.0, .windows_dpi, "Windows 系统 DPI = {d:.0}", .{raw.windows_dpi});
    }
    // 2. XSETTINGS：整数缩放（GNOME `scaling-factor`、Xfce、KDE 都写这个）
    if (raw.xs_scaling >= 1) {
        return r.set(@floatFromInt(raw.xs_scaling), .xs_scaling, "XSETTINGS Gdk/WindowScalingFactor = {d}", .{raw.xs_scaling});
    }
    // 3. XSETTINGS：Xft/DPI（1/1024 dpi；GNOME 的分数缩放与文本缩放会落到这里）
    if (raw.xs_dpi > 0) {
        const dpi = @as(f32, @floatFromInt(raw.xs_dpi)) / 1024.0;
        if (dpi >= 48.0 and dpi <= 960.0) {
            return r.set(dpi / 96.0, .xs_dpi, "XSETTINGS Xft/DPI = {d:.0}", .{dpi});
        }
    }
    // 4. Xft.dpi（没有 xsettings 守护进程的桌面：KDE/Xfce/手写 ~/.Xresources）
    if (raw.xft_dpi >= 48.0 and raw.xft_dpi <= 960.0) {
        return r.set(raw.xft_dpi / 96.0, .xft_dpi, "Xft.dpi = {d:.0}", .{raw.xft_dpi});
    }
    // 5. 用户显式设的环境变量
    if (parseScale(raw.gdk_scale)) |v| return r.set(v, .env_scale, "GDK_SCALE = {s}", .{raw.gdk_scale});
    if (parseScale(raw.qt_scale)) |v| return r.set(v, .env_scale, "QT_SCALE_FACTOR = {s}", .{raw.qt_scale});
    // 6. 屏幕 ppi 估算（**只当建议**：够密才自动用）
    if (raw.screen_px_w > 0 and raw.screen_mm_w > 0) {
        const ppi = @as(f32, @floatFromInt(raw.screen_px_w)) * 25.4 / @as(f32, @floatFromInt(raw.screen_mm_w));
        if (ppi >= phys_min_ppi) {
            return r.set(std.math.clamp(ppi / 96.0, 1.25, phys_max_scale), .physical, "屏幕 ppi ≈ {d:.0}，且无桌面缩放设置", .{ppi});
        }
        return r.set(1.0, .fallback, "屏幕 ppi ≈ {d:.0}，无需缩放", .{ppi});
    }
    // 7. 兜底
    return r;
}

// ── 测试 ──

test "dpi: 阶梯优先级——命中即返回、绝不相乘" {
    // 全都有 → Windows 系统 DPI 优先
    {
        const r = fromRaw(.{ .windows_dpi = 144, .xs_scaling = 2, .xs_dpi = 192 * 1024, .xft_dpi = 192, .gdk_scale = "3" });
        try std.testing.expectEqual(@as(f32, 1.5), r.scale);
        try std.testing.expectEqual(Source.windows_dpi, r.source);
    }
    // 无 Windows DPI → XSETTINGS 整数优先于其它一切（**不相乘**：不是 4.0）
    {
        const r = fromRaw(.{ .windows_dpi = 0, .xs_scaling = 2, .xft_dpi = 192, .gdk_scale = "2" });
        try std.testing.expectEqual(@as(f32, 2.0), r.scale);
        try std.testing.expectEqual(Source.xs_scaling, r.source);
    }
    // XSETTINGS 分数 DPI：196608/1024 = 192 → 2.0
    {
        const r = fromRaw(.{ .xs_dpi = 196608, .xft_dpi = 120 });
        try std.testing.expectEqual(@as(f32, 2.0), r.scale);
        try std.testing.expectEqual(Source.xs_dpi, r.source);
    }
    // Xft.dpi = 144 → 1.5
    {
        const r = fromRaw(.{ .xft_dpi = 144 });
        try std.testing.expectEqual(@as(f32, 1.5), r.scale);
        try std.testing.expectEqual(Source.xft_dpi, r.source);
        try std.testing.expectEqualStrings("Xft.dpi = 144", r.detail());
    }
    // 环境变量（GDK 优先于 QT）
    {
        const r = fromRaw(.{ .gdk_scale = "2", .qt_scale = "1.25" });
        try std.testing.expectEqual(@as(f32, 2.0), r.scale);
        try std.testing.expectEqual(Source.env_scale, r.source);
        const r2 = fromRaw(.{ .qt_scale = "1.25" });
        try std.testing.expectEqual(@as(f32, 1.25), r2.scale);
    }
}

test "dpi: 物理 ppi 只当建议（够密且无其它信号才自动用）" {
    // 4K 27"：3840 / 600mm ≈ 163ppi → 163/96 ≈ 1.69
    {
        const r = fromRaw(.{ .screen_px_w = 3840, .screen_mm_w = 600 });
        try std.testing.expectEqual(Source.physical, r.source);
        try std.testing.expectApproxEqAbs(@as(f32, 1.6875), r.scale, 0.01);
    }
    // 4K 但比 2K 上限还大 → 钳到 2.0
    {
        const r = fromRaw(.{ .screen_px_w = 7680, .screen_mm_w = 600 });
        try std.testing.expectEqual(@as(f32, 2.0), r.scale);
    }
    // 1080p 24"（≈92ppi）：稀疏屏不自动放大
    {
        const r = fromRaw(.{ .screen_px_w = 1920, .screen_mm_w = 530 });
        try std.testing.expectEqual(@as(f32, 1.0), r.scale);
        try std.testing.expectEqual(Source.fallback, r.source);
    }
    // 有桌面信号时，物理 ppi 被忽略（哪怕屏幕很密）
    {
        const r = fromRaw(.{ .xft_dpi = 96, .screen_px_w = 3840, .screen_mm_w = 600 });
        try std.testing.expectEqual(@as(f32, 1.0), r.scale);
        try std.testing.expectEqual(Source.xft_dpi, r.source);
    }
}

test "dpi: 什么都检测不到 → 1.0 且来源标记为未检测到" {
    const r = fromRaw(.{});
    try std.testing.expectEqual(@as(f32, 1.0), r.scale);
    try std.testing.expectEqual(Source.fallback, r.source);
    try std.testing.expectEqualStrings("", r.detail());
    // 越界值要被钳住（4.0 上限 / 0.75 下限）
    try std.testing.expectEqual(@as(f32, 4.0), fromRaw(.{ .xs_scaling = 9 }).scale);
}

test "dpi: 环境变量解析（含 QT 每屏列表、非法值）" {
    try std.testing.expectEqual(@as(?f32, 2.0), parseScale("2"));
    try std.testing.expectEqual(@as(?f32, 1.5), parseScale(" 1.5\r\n"));
    try std.testing.expectEqual(@as(?f32, null), parseScale(""));
    try std.testing.expectEqual(@as(?f32, null), parseScale("abc"));
    try std.testing.expectEqual(@as(?f32, null), parseScale("0.5")); // 低于下限
    try std.testing.expectEqualStrings("1", firstListToken("1;1.5"));
    try std.testing.expectEqualStrings("2", firstListToken(" 2 ; 3"));
}
