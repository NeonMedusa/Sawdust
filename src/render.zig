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

/// 把颜色按覆盖率（0~1）缩放 alpha —— 抗锯齿混合用
inline fn scaleAlpha(src: Color, cov: f32) Color {
    const sa: u32 = (src >> 24) & 0xFF;
    const na: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sa)) * cov));
    return (na << 24) | (src & 0x00FFFFFF);
}

/// 裁剪矩形（像素坐标；`w`/`h` <= 0 表示空区域）
pub const Clip = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Renderer = struct {
    fb: *Framebuffer,
    /// 当前裁剪区（默认覆盖全屏；用 setClip/pushClip 限制绘制范围，如滚动列表）
    clip: Clip = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// **UI 缩放（DPI）**：上层全部按“逻辑像素”布局，这里统一乘到物理像素。
    /// 1.0 = 100%（1080p 下的旧行为，逐像素一致）；4K@200% → 2.0。
    scale: f32 = 1.0,

    /// 逻辑像素 → 物理像素（四舍五入；scale==1 时恒等）
    inline fn px(self: Renderer, v: i32) i32 {
        if (self.scale == 1.0) return v;
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * self.scale));
    }

    /// 逻辑 `[起, 起+长)` → 物理两端点 `[起, 止)`。
    /// **按两端点分别取整**（而不是把长度乘 scale）→ 相邻矩形才能严丝合缝，
    /// 不会在 125%/150% 等非整数缩放下露出 1px 缝。裁剪区与 `fillRect` 共用同一口径。
    inline fn span(self: Renderer, v: i32, len: i32) [2]i32 {
        return .{ self.px(v), self.px(v + len) };
    }

    pub fn init(fb: *Framebuffer) Renderer {
        return .{ .fb = fb, .clip = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) } };
    }

    /// 设置裁剪区（影响后续所有图元）。调用方负责恢复（见 pushClip/popClip）。
    /// 入参为**逻辑像素**（内部乘 scale）。
    pub fn setClip(self: *Renderer, x: i32, y: i32, w: i32, h: i32) void {
        const xs = self.span(x, w);
        const ys = self.span(y, h);
        self.clip = .{ .x = xs[0], .y = ys[0], .w = @max(0, xs[1] - xs[0]), .h = @max(0, ys[1] - ys[0]) };
    }

    /// 重置裁剪区到全屏
    pub fn resetClip(self: *Renderer) void {
        self.clip = .{ .x = 0, .y = 0, .w = @intCast(self.fb.width), .h = @intCast(self.fb.height) };
    }

    /// 在当前裁剪区基础上**收窄**（取交集）——用于嵌套区域。返回旧值，配 popClip 恢复。
    /// 入参为**逻辑像素**（内部乘 scale）。
    pub fn pushClip(self: *Renderer, x: i32, y: i32, w: i32, h: i32) Clip {
        const old = self.clip;
        const xs = self.span(x, w);
        const ys = self.span(y, h);
        const x0 = @max(old.x, xs[0]);
        const y0 = @max(old.y, ys[0]);
        const x1 = @min(old.x + old.w, xs[1]);
        const y1 = @min(old.y + old.h, ys[1]);
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

    /// **逻辑**宽高（上层布局用；物理 / scale）
    pub fn logicalWidth(self: Renderer) i32 {
        return self.unpx(@intCast(self.fb.width));
    }
    pub fn logicalHeight(self: Renderer) i32 {
        return self.unpx(@intCast(self.fb.height));
    }

    /// 物理像素 → 逻辑像素（四舍五入；scale==1 时恒等）
    inline fn unpx(self: Renderer, v: i32) i32 {
        if (self.scale == 1.0) return v;
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) / self.scale));
    }

    /// 清屏
    pub fn clear(self: Renderer, color: Color) void {
        self.fb.fill(toDib(color));
    }

    /// 填充矩形（裁剪到边界；不透明时用 @memset 整行填充）。入参为**逻辑像素**。
    pub fn fillRect(self: Renderer, x_in: i32, y_in: i32, w_in: i32, h_in: i32, color: Color) void {
        const xs = self.span(x_in, w_in);
        const ys = self.span(y_in, h_in);
        const x = xs[0];
        const y = ys[0];
        const w = if (w_in > 0) @max(1, xs[1] - x) else 0;
        const h = if (h_in > 0) @max(1, ys[1] - y) else 0;
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
                for (row[start..end]) |*pp| pp.* = blend(pp.*, color);
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

    /// 直线（Bresenham）。入参为**逻辑像素**（端点乘 scale 后再走像素循环）。
    pub fn line(self: Renderer, x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: Color) void {
        const ax = self.px(x0_in);
        const ay = self.px(y0_in);
        const bx = self.px(x1_in);
        const by = self.px(y1_in);
        var x0 = ax;
        var y0 = ay;
        const dx: i32 = @intCast(@abs(bx - x0));
        const sx: i32 = if (x0 < bx) 1 else -1;
        const dy: i32 = -@as(i32, @intCast(@abs(by - y0)));
        const sy: i32 = if (y0 < by) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.plotPhys(x0, y0, color);
            if (x0 == bx and y0 == by) break;
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

    /// 单像素（带 alpha 混合与裁剪）。入参为**逻辑像素**。
    pub fn plot(self: Renderer, x: i32, y: i32, color: Color) void {
        self.plotPhys(self.px(x), self.px(y), color);
    }

    /// 按**覆盖率**（0~1）把一个颜色混合到物理像素上。
    /// 各图元 AA 的共用出口（将来 `line` 做 AA 时也走这里）。
    inline fn blendCov(self: Renderer, x: i32, y: i32, color: Color, cov: f32) void {
        if (x < self.clip.x or y < self.clip.y or x >= self.clip.x + self.clip.w or y >= self.clip.y + self.clip.h) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.fb.width or uy >= self.fb.height) return;
        const idx = uy * self.fb.width + ux;
        self.fb.pixels[idx] = blend(self.fb.pixels[idx], scaleAlpha(color, cov));
    }

    /// **圆弧环带**（旋钮的圆形版 `strokeRect`）：入参全为**逻辑像素**。
    /// - `cx`/`cy` 圆心，`r` **外**半径，`thickness` 环厚（逻辑像素，可小数）
    /// - `a0..a1` 角度（弧度；屏幕坐标 y 向下为正；需 `a0 < a1`）
    ///
    /// 为什么不做“两条同心圆线”：那种画法隐含“环厚 = 半径差 1 像素”的假设，
    /// DPI 缩放后半径差变成 2~3 像素 → 中间空了（实测：旋钮变成空心细边）。
    /// 这里直接光栅化**实心环带**，径向/角度边界算覆盖率做抗锯齿；
    /// 内部像素走不混合快路径。
    pub fn arcRing(self: Renderer, cx: i32, cy: i32, r: i32, thickness: f32, a0: f32, a1: f32, color: Color) void {
        if (r <= 0 or thickness <= 0 or a1 <= a0) return;
        const s = self.scale;
        const circ = 2.0 * std.math.pi;

        // 物理坐标（+0.5：圆心落在像素中心，圆才对称）
        const cxp = @as(f32, @floatFromInt(self.px(cx))) + 0.5;
        const cyp = @as(f32, @floatFromInt(self.px(cy))) + 0.5;
        const ro = @as(f32, @floatFromInt(r)) * s; // 外半径（物理）
        const tk = @max(0.8, thickness * s); // 环厚（物理；最小 0.8px 才看得见）
        const ri = @max(0.0, ro - tk); // 内半径（物理）

        // 候选区 = 环带包围盒（含 1px 边缘）× 裁剪区 × 帧缓冲
        const fbw: i32 = @intCast(self.fb.width);
        const fbh: i32 = @intCast(self.fb.height);
        const x_lo = @max(@max(self.px(cx - r - 1), self.clip.x), 0);
        const x_hi = @min(@min(self.px(cx + r + 1), self.clip.x + self.clip.w), fbw);
        const y_lo = @max(@max(self.px(cy - r - 1), self.clip.y), 0);
        const y_hi = @min(@min(self.px(cy + r + 1), self.clip.y + self.clip.h), fbh);
        if (x_lo >= x_hi or y_lo >= y_hi) return;

        const ro2 = (ro + 1.0) * (ro + 1.0);
        const ri1 = @max(0.0, ri - 1.0);
        const ri2 = ri1 * ri1;

        var y = y_lo;
        while (y < y_hi) : (y += 1) {
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cyp;
            const dy2 = dy * dy;
            if (dy2 > ro2) continue;
            // 本行可能的 x 区间（跳过行内无关部分）
            const half = @sqrt(ro2 - dy2);
            var x: i32 = @max(x_lo, @as(i32, @intFromFloat(@floor(cxp - half))));
            const x_end: i32 = @min(x_hi, @as(i32, @intFromFloat(@ceil(cxp + half))) + 1);
            while (x < x_end) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cxp;
                const d2 = dx * dx + dy2;
                if (d2 > ro2 or d2 < ri2) continue; // 带外（含边缘余量）
                const d = @sqrt(d2);
                // 径向覆盖率：内外两侧各半个像素羽化（细环自动变淡，不会变成锯齿）
                const cov_r = @min(1.0, ro - d + 0.5) * std.math.clamp(d - ri + 0.5, 0.0, 1.0);
                if (cov_r <= 0.0) continue;
                // 角度覆盖率：用弧长（角度 × 半径）当像素内坐标；
                // 两端都做半像素羽化（对称，避免一端硬一端软）
                var ang = std.math.atan2(dy, dx);
                while (ang < a0) ang += circ;
                const dc = @max(d, 1.0); // 圆心附近防退化
                const lead = (ang - a0) * dc; // 距起点弧长（≥ 0，已归一）
                const trail = (a1 - ang) * dc; // 距终点弧长（过了终点为负）
                if (trail < -0.5) continue; // 弧外
                const cov_a = std.math.clamp(lead + 0.5, 0.0, 1.0) * std.math.clamp(trail + 0.5, 0.0, 1.0);
                const cov = cov_r * cov_a;
                if (cov <= 0.004) continue;
                if (cov >= 0.996) {
                    // 内部：不混合快路径
                    self.fb.pixels[@as(usize, @intCast(y)) * self.fb.width + @as(usize, @intCast(x))] = toDib(color);
                } else {
                    self.blendCov(x, y, color, cov);
                }
            }
        }
    }

    /// 单像素（**物理像素**，不再缩放）：供 `line` 的 Bresenham 与 `arcRing` 内部使用。
    fn plotPhys(self: Renderer, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        if (x < self.clip.x or y < self.clip.y or x >= self.clip.x + self.clip.w or y >= self.clip.y + self.clip.h) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.fb.width or uy >= self.fb.height) return;
        const idx = uy * self.fb.width + ux;
        self.fb.pixels[idx] = blend(self.fb.pixels[idx], color);
    }

    /// blit 一块 8 位 alpha 位图（图标）：`dst_x`/`dst_y` 是**逻辑像素**（内部乘 scale）。
    pub fn blitAlphaMask(
        self: Renderer,
        mask: []const u8,
        mask_w: u32,
        mask_h: u32,
        dst_x: i32,
        dst_y: i32,
        color: Color,
    ) void {
        self.blitAlphaMaskPhys(mask, mask_w, mask_h, self.px(dst_x), self.px(dst_y), color);
    }

    /// blit 一块 8 位 alpha 位图（**物理像素**，不再缩放）：字形位图自己已按 DPI 光栅化，
    /// 坐标也由 Font 换算好，这里必须原样落地。
    /// `mask` 每像素 0-255 作为 alpha，`color` 提供 RGB。
    pub fn blitAlphaMaskPhys(
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
        const d0x = dst_x;
        const d0y = dst_y;
        while (y < mask_h) : (y += 1) {
            const dy = d0y + @as(i32, @intCast(y));
            if (dy < 0 or dy >= @as(i32, @intCast(self.fb.height))) continue;
            if (dy < self.clip.y or dy >= self.clip.y + self.clip.h) continue;
            var x: u32 = 0;
            while (x < mask_w) : (x += 1) {
                const dx = d0x + @as(i32, @intCast(x));
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

test "renderer: UI 缩放（scale 乘入图元）" {
    var buf: [20 * 20]u32 = undefined;
    var fb = Framebuffer{ .pixels = &buf, .width = 20, .height = 20 };
    var r = Renderer.init(&fb);
    r.scale = 2.0;
    r.clear(rgb(0, 0, 0));

    // 逻辑 (1,1,2,1) → 物理 (2,2)-(5,3)
    r.fillRect(1, 1, 2, 1, rgb(255, 0, 0));
    try std.testing.expectEqual(rgb(255, 0, 0), buf[2 * 20 + 2]);
    try std.testing.expectEqual(rgb(255, 0, 0), buf[3 * 20 + 5]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[2 * 20 + 6]);
    try std.testing.expectEqual(rgb(0, 0, 0), buf[4 * 20 + 2]);

    // 1 逻辑像素的矩形 → 至少 2 物理像素宽（scale=2）
    r.fillRect(0, 5, 1, 1, rgb(0, 255, 0));
    try std.testing.expectEqual(rgb(0, 255, 0), buf[10 * 20 + 0]);
    try std.testing.expectEqual(rgb(0, 255, 0), buf[11 * 20 + 1]);

    // 裁剪区也是逻辑坐标：只留 (0,10)-(9,19) 物理 = 逻辑 (0,5)-(4,9)
    r.setClip(0, 5, 5, 5);
    try std.testing.expectEqual(@as(i32, 10), r.clip.y);
    try std.testing.expectEqual(@as(i32, 10), r.clip.h);
    r.fillRect(0, 0, 10, 10, rgb(0, 0, 255));
    try std.testing.expectEqual(rgb(0, 0, 0), buf[0]); // 裁剪上边界外：不动
    try std.testing.expectEqual(rgb(0, 0, 255), buf[12 * 20 + 2]);

    // 逻辑宽高（物理 / scale）
    try std.testing.expectEqual(@as(i32, 10), r.logicalWidth());
    try std.testing.expectEqual(@as(i32, 10), r.logicalHeight());
}

// 只锁两条真回归：①环带**实心**（旧实现只描 r / r-1 两条线，缩放后空心）
// ②确实**跟随 scale**。具体像素级观感由启动软件看，不在单测里锁死。
test "renderer: arcRing 实心环带 + 跟随 UI 缩放" {
    var buf: [32 * 32]u32 = undefined;
    @memset(&buf, 0);
    var fb = Framebuffer{ .pixels = &buf, .width = 32, .height = 32 };
    var r = Renderer.init(&fb);
    const w = rgb(255, 255, 255);

    // scale=1：圆心(16,16) 外径 8 环厚 3 → 带内 d∈有理 5..8
    r.arcRing(16, 16, 8, 3, 0, 2 * std.math.pi, w);
    try std.testing.expectEqual(w, buf[10 * 32 + 16]); // 带内：实心
    try std.testing.expectEqual(w, buf[16 * 32 + 10]); // 带内：实心
    try std.testing.expect(buf[16 * 32 + 16] == 0); // 中心空心
    try std.testing.expect(buf[7 * 32 + 16] == 0); // 环外不洩

    // 角度区间（只画右下象限）：带内但不在象限内的像素不画
    @memset(&buf, 0);
    r.arcRing(16, 16, 8, 3, 0, std.math.pi / 2.0, w);
    try std.testing.expectEqual(w, buf[21 * 32 + 21]);
    try std.testing.expect(buf[10 * 32 + 16] == 0);

    // scale=2：同样逻辑参数 → 环带整个搬到大一倍的位置
    @memset(&buf, 0);
    r.scale = 2.0;
    r.arcRing(8, 8, 8, 3, 0, 2 * std.math.pi, w);
    try std.testing.expectEqual(w, buf[29 * 32 + 16]); // 下：物理 d=13
    try std.testing.expect(buf[20 * 32 + 16] == 0); // 中心：不画
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
