//! 渲染层：软件光栅化图元（零依赖，纯 CPU 写帧缓冲）。
//!
//! 设计：
//! - 颜色统一用 `0xAARRGGBB`（内部解包成 BGRA 写 DIB）
//! - 所有图元都做**边界裁剪**（不越界写），保证安全
//! - 性能策略：`fillRect` 用 `@memset`（内存带宽级）；文字用预光栅化位图 blit
//!
//! 这一层不依赖窗口/字体，可独立单测（给定 framebuffer 检查像素）。

const std = @import("std");
pub const Framebuffer = @import("window.zig").Framebuffer;

/// 0xAARRGGBB
pub const Color = u32;

pub const transparent: Color = 0x00000000;
pub const black: Color = 0xFF000000;
pub const white: Color = 0xFFFFFFFF;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// 把 0xAARRGGBB 转成 DIB 期望的 0xAARRGGBB 内存序（BGRA 字节序 = 小端 u32 的 ARGB）
inline fn toDib(c: Color) u32 {
    return c;
}

/// 源 alpha 混合：src over dst（两者都是 0xAARRGGBB）
inline fn blend(dst: Color, src: Color) Color {
    const sa: u32 = (src >> 24) & 0xFF;
    if (sa == 255) return src;
    if (sa == 0) return dst;
    const inv: u32 = 255 - sa;
    const sr: u32 = (src >> 16) & 0xFF;
    const sg: u32 = (src >> 8) & 0xFF;
    const sb: u32 = src & 0xFF;
    const dr: u32 = (dst >> 16) & 0xFF;
    const dg: u32 = (dst >> 8) & 0xFF;
    const db: u32 = dst & 0xFF;
    const r = (sr * sa + dr * inv) / 255;
    const g = (sg * sa + dg * inv) / 255;
    const b = (sb * sa + db * inv) / 255;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// 裁剪矩形（像素坐标；`w`/`h` <= 0 表示空区域）
pub const Clip = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Renderer = struct {
    fb: *Framebuffer,
    /// 当前裁剪区（默认覆盖全屏；用 setClip/pushClip 限制绘制范围，如滚动列表）
    clip: Clip = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(fb: *Framebuffer) Renderer {
        return .{ .fb = fb, .clip = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) } };
    }

    /// 设置裁剪区（影响后续所有图元）。调用方负责恢复（见 pushClip/popClip）。
    pub fn setClip(self: *Renderer, x: i32, y: i32, w: i32, h: i32) void {
        self.clip = .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// 重置裁剪区到全屏
    pub fn resetClip(self: *Renderer) void {
        self.clip = .{ .x = 0, .y = 0, .w = @intCast(self.fb.width), .h = @intCast(self.fb.height) };
    }

    /// 在当前裁剪区基础上**收窄**（取交集）——用于嵌套区域。返回旧值，配 popClip 恢复。
    pub fn pushClip(self: *Renderer, x: i32, y: i32, w: i32, h: i32) Clip {
        const old = self.clip;
        const x0 = @max(old.x, x);
        const y0 = @max(old.y, y);
        const x1 = @min(old.x + old.w, x + w);
        const y1 = @min(old.y + old.h, y + h);
        self.clip = .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
        return old;
    }

    /// 恢复裁剪区（配合 pushClip）
    pub fn popClip(self: *Renderer, saved: Clip) void {
        self.clip = saved;
    }

    pub fn width(self: Renderer) u32 {
        return self.fb.width;
    }
    pub fn height(self: Renderer) u32 {
        return self.fb.height;
    }

    /// 清屏
    pub fn clear(self: Renderer, color: Color) void {
        self.fb.fill(toDib(color));
    }

    /// 填充矩形（裁剪到边界；不透明时用 @memset 整行填充）
    pub fn fillRect(self: Renderer, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (w <= 0 or h <= 0) return;
        const x0 = @max(@max(x, 0), self.clip.x);
        const y0 = @max(@max(y, 0), self.clip.y);
        const x1 = @min(@min(x + w, @as(i32, @intCast(self.fb.width))), self.clip.x + self.clip.w);
        const y1 = @min(@min(y + h, @as(i32, @intCast(self.fb.height))), self.clip.y + self.clip.h);
        if (x0 >= x1 or y0 >= y1) return;

        const c = toDib(color);
        const is_opaque = (color >> 24) == 255;
        var yy: i32 = y0;
        while (yy < y1) : (yy += 1) {
            const row = self.fb.pixels[@as(usize, @intCast(yy)) * self.fb.width ..][0..self.fb.width];
            const start: usize = @intCast(x0);
            const end: usize = @intCast(x1);
            if (is_opaque) {
                @memset(row[start..end], c);
            } else {
                for (row[start..end]) |*px| px.* = blend(px.*, color);
            }
        }
    }

    /// 描边矩形（1 像素宽）
    pub fn strokeRect(self: Renderer, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (w <= 0 or h <= 0) return;
        self.fillRect(x, y, w, 1, color);
        self.fillRect(x, y + h - 1, w, 1, color);
        self.fillRect(x, y + 1, 1, h - 2, color);
        self.fillRect(x + w - 1, y + 1, 1, h - 2, color);
    }

    /// 水平线
    pub fn hline(self: Renderer, x: i32, y: i32, w: i32, color: Color) void {
        self.fillRect(x, y, w, 1, color);
    }

    /// 垂直线
    pub fn vline(self: Renderer, x: i32, y: i32, h: i32, color: Color) void {
        self.fillRect(x, y, 1, h, color);
    }

    /// 直线（Bresenham）
    pub fn line(self: Renderer, x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: Color) void {
        var x0 = x0_in;
        var y0 = y0_in;
        const dx: i32 = @intCast(@abs(x1_in - x0));
        const sx: i32 = if (x0 < x1_in) 1 else -1;
        const dy: i32 = -@as(i32, @intCast(@abs(y1_in - y0)));
        const sy: i32 = if (y0 < y1_in) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.plot(x0, y0, color);
            if (x0 == x1_in and y0 == y1_in) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    /// 单像素（带 alpha 混合与裁剪）
    pub fn plot(self: Renderer, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        if (x < self.clip.x or y < self.clip.y or x >= self.clip.x + self.clip.w or y >= self.clip.y + self.clip.h) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.fb.width or uy >= self.fb.height) return;
        const idx = uy * self.fb.width + ux;
        self.fb.pixels[idx] = blend(self.fb.pixels[idx], color);
    }

    /// blit 一块 8 位 alpha 位图（字形/图标）：`mask` 每像素 0-255 作为 alpha，
    /// `color` 提供 RGB。用于文字与单色图标。
    pub fn blitAlphaMask(
        self: Renderer,
        mask: []const u8,
        mask_w: u32,
        mask_h: u32,
        dst_x: i32,
        dst_y: i32,
        color: Color,
    ) void {
        const cr: u32 = (color >> 16) & 0xFF;
        const cg: u32 = (color >> 8) & 0xFF;
        const cb: u32 = color & 0xFF;
        const base_a: u32 = (color >> 24) & 0xFF;

        var y: u32 = 0;
        while (y < mask_h) : (y += 1) {
            const dy = dst_y + @as(i32, @intCast(y));
            if (dy < 0 or dy >= @as(i32, @intCast(self.fb.height))) continue;
            if (dy < self.clip.y or dy >= self.clip.y + self.clip.h) continue;
            var x: u32 = 0;
            while (x < mask_w) : (x += 1) {
                const dx = dst_x + @as(i32, @intCast(x));
                if (dx < 0 or dx >= @as(i32, @intCast(self.fb.width))) continue;
                if (dx < self.clip.x or dx >= self.clip.x + self.clip.w) continue;
                const m = mask[y * mask_w + x];
                if (m == 0) continue;
                const a = (m * base_a) / 255;
                if (a == 0) continue;
                const src = (a << 24) | (cr << 16) | (cg << 8) | cb;
                const idx = @as(usize, @intCast(dy)) * self.fb.width + @as(usize, @intCast(dx));
                self.fb.pixels[idx] = blend(self.fb.pixels[idx], src);
            }
        }
    }
};

// ── 测试 ──

test "renderer: 裁剪区限制绘制范围" {
    var buf: [10 * 10]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 10, .height = 10 };
    var r = Renderer.init(&fb);
    r.clear(rgb(0, 0, 0));

    // 只允许画 (2,2)-(6,6) 区域
    r.setClip(2, 2, 4, 4);
    r.fillRect(0, 0, 10, 10, rgb(255, 0, 0));

    // 区域内：红
    try std.testing.expectEqual(rgb(255, 0, 0), buf[3 * 10 + 3]);
    try std.testing.expectEqual(rgb(255, 0, 0), buf[5 * 10 + 5]);
    // 区域外：仍是黑（被裁剪）
    try std.testing.expectEqual(rgb(0, 0, 0), buf[0]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[9 * 10 + 9]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[1 * 10 + 1]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[6 * 10 + 6]);

    // pushClip 取交集；popClip 恢复
    const saved = r.pushClip(3, 3, 10, 10); // 与 (2,2,4,4) 交集 = (3,3,3,3)
    try std.testing.expectEqual(@as(i32, 3), r.clip.x);
    try std.testing.expectEqual(@as(i32, 3), r.clip.w);
    r.popClip(saved);
    try std.testing.expectEqual(@as(i32, 2), r.clip.x);
    try std.testing.expectEqual(@as(i32, 4), r.clip.w);
}

test "renderer: fillRect 裁剪与填充" {
    var buf: [10 * 10]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 10, .height = 10 };
    var r = Renderer.init(&fb);
    r.clear(rgb(0, 0, 0));

    // 正常矩形
    r.fillRect(2, 2, 3, 3, rgb(255, 0, 0));
    try std.testing.expectEqual(rgb(255, 0, 0), buf[2 * 10 + 2]);
    try std.testing.expectEqual(rgb(255, 0, 0), buf[4 * 10 + 4]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[5 * 10 + 5]);

    // 越界矩形（只画可见部分，不崩）
    r.fillRect(-5, -5, 10, 10, rgb(0, 255, 0));
    try std.testing.expectEqual(rgb(0, 255, 0), buf[0]);
    try std.testing.expectEqual(rgb(0, 255, 0), buf[4 * 10 + 4]);
}

test "renderer: 半透明混合" {
    var buf: [1]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 1, .height = 1 };
    var r = Renderer.init(&fb);
    r.clear(rgb(0, 0, 0));
    r.fillRect(0, 0, 1, 1, rgba(255, 255, 255, 128));
    // 50% 白 + 黑 ≈ 127/128
    const v = buf[0] & 0xFF;
    try std.testing.expect(v >= 126 and v <= 129);
}

test "renderer: 直线与单像素裁剪" {
    var buf: [5 * 5]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 5, .height = 5 };
    var r = Renderer.init(&fb);
    r.clear(rgb(0, 0, 0));
    r.line(0, 0, 4, 4, rgb(255, 255, 255));
    try std.testing.expectEqual(rgb(255, 255, 255), buf[0]);
    try std.testing.expectEqual(rgb(255, 255, 255), buf[4 * 5 + 4]);
    // 越界 plot 不崩
    r.plot(-1, -1, rgb(255, 0, 0));
    r.plot(100, 100, rgb(255, 0, 0));
}
