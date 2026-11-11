//! 字体层：stb_truetype 字形光栅化 + 位图缓存。
//!
//! 策略（务实版）：
//! - 启动时加载 TTF 到内存（`stbtt_InitFont`）；
//! - 按需光栅化字形到 8 位 alpha 位图（`stbtt_GetCodepointBitmap`），**缓存**；
//! - 绘制 = `renderer.blitAlphaMask`（内存混合，快）；
//! - 缓存策略：线性表 + **码点 → 下标哈希索引**（O(1) 命中；宽度测量是热路径），
//!   字形**只增不淘汰**（界面用字有限，光栅化一次终身复用）。
//!
//! 为什么不用 SDF：起步阶段位图更简单；需要"界面缩放时字形依然锐利"时，
//! 可换 `stbtt_GetCodepointSDF` + CPU 采样（接口不变，只换内部实现）。

const std = @import("std");
// 0.17：`@cImport` 已移除——改用 `zig translate-c` 预生成的绑定（免网络、免构建期翻译）
const stb = @import("c/stb_truetype.zig");
const Renderer = @import("render.zig").Renderer;
const Color = @import("render.zig").Color;

/// 字形缓存条目
const Glyph = struct {
    codepoint: u21,
    /// 8 位 alpha 位图（w*h）
    mask: []u8,
    w: u32,
    h: u32,
    /// 相对基线的偏移（stbtt 的 xoff/yoff）
    xoff: i32,
    yoff: i32,
    /// 水平前进量（像素，已缩放）
    advance: f32,
};

pub const Font = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    info: stb.stbtt_fontinfo,
    scale: f32,
    size_px: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    /// **DPI 缩放**（物理/逻辑）。字形位图按 `size_px * px_scale` 光栅化（高分屏真锐利），
    /// 而对外的度量（`measure`/`lineHeight`/`ascentL`）统一除回去 = **逻辑像素**，
    /// 这样上层布局代码不用关心缩放。
    px_scale: f32 = 1.0,
    glyphs: std.ArrayListUnmanaged(Glyph) = .empty,
    /// 码点 → `glyphs.items` 下标。`getGlyph/measure` 是每帧热路径（每个字符一次），
    /// 线性扫在几百个字形的缓存下会变成 O(n²) —— 这里换成哈希索引。
    glyph_index: std.AutoHashMapUnmanaged(u21, u32) = .empty,

    /// 从文件加载字体（`size_px` = 期望的字号像素高）
    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, size_px: f32) !Font {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(data);
        return initFromMemory(allocator, data, size_px);
    }

    /// 从内存加载（data 的所有权转移给 Font）
    pub fn initFromMemory(allocator: std.mem.Allocator, data: []u8, size_px: f32) !Font {
        const offset = stb.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0) return error.FontInitFailed;
        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, data.ptr, offset) == 0) return error.FontInitFailed;

        var ascent_i: c_int = undefined;
        var descent_i: c_int = undefined;
        var line_gap_i: c_int = undefined;
        stb.stbtt_GetFontVMetrics(&info, &ascent_i, &descent_i, &line_gap_i);

        const scale = stb.stbtt_ScaleForPixelHeight(&info, size_px);

        return .{
            .allocator = allocator,
            .data = data,
            .info = info,
            .scale = scale,
            .size_px = size_px,
            .ascent = @as(f32, @floatFromInt(ascent_i)) * scale,
            .descent = @as(f32, @floatFromInt(descent_i)) * scale,
            .line_gap = @as(f32, @floatFromInt(line_gap_i)) * scale,
        };
    }

    pub fn deinit(self: *Font) void {
        for (self.glyphs.items) |g| self.allocator.free(g.mask);
        self.glyphs.deinit(self.allocator);
        self.glyph_index.deinit(self.allocator);
        self.allocator.free(self.data);
    }

    /// **行高**（逻辑像素；UI 布局用的就是这个）
    pub fn lineHeight(self: *const Font) f32 {
        return (self.ascent - self.descent + self.line_gap) / self.px_scale;
    }

    /// 上开（逻辑像素，基线之上）
    pub fn ascentL(self: *const Font) f32 {
        return self.ascent / self.px_scale;
    }

    /// 下延（逻辑像素，**负值**，基线之下）
    pub fn descentL(self: *const Font) f32 {
        return self.descent / self.px_scale;
    }

    /// 取字形（无则光栅化并缓存）
    pub fn getGlyph(self: *Font, codepoint: u21) ?*const Glyph {
        if (self.glyph_index.get(codepoint)) |i| {
            if (i < self.glyphs.items.len) return &self.glyphs.items[i];
        }
        return self.rasterize(codepoint);
    }

    /// 追加已光栅化的字形并登记索引（索引写失败只丢掉 ACCEL，不影响正确性）
    fn addGlyph(self: *Font, g: Glyph) ?*const Glyph {
        self.glyphs.append(self.allocator, g) catch {
            if (g.mask.len > 0) self.allocator.free(g.mask);
            return null;
        };
        const idx: u32 = @intCast(self.glyphs.items.len - 1);
        self.glyph_index.put(self.allocator, g.codepoint, idx) catch {};
        return &self.glyphs.items[idx];
    }

    fn rasterize(self: *Font, codepoint: u21) ?*const Glyph {
        var w: c_int = undefined;
        var h: c_int = undefined;
        var xoff: c_int = undefined;
        var yoff: c_int = undefined;
        const bitmap = stb.stbtt_GetCodepointBitmap(
            &self.info,
            self.scale,
            self.scale,
            @intCast(codepoint),
            &w,
            &h,
            &xoff,
            &yoff,
        );
        if (bitmap == null or w <= 0 or h <= 0) {
            // 空白字形（空格等）：缓存一个 0×0 条目以便重复查询快速返回
            return self.addGlyph(.{
                .codepoint = codepoint,
                .mask = self.allocator.alloc(u8, 0) catch return null,
                .w = 0,
                .h = 0,
                .xoff = 0,
                .yoff = 0,
                .advance = self.advanceOf(codepoint),
            });
        }
        defer stb.stbtt_FreeBitmap(bitmap, null);

        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const mask = self.allocator.alloc(u8, uw * uh) catch return null;
        const src: [*]const u8 = @ptrCast(bitmap);
        @memcpy(mask, src[0 .. uw * uh]);

        const g = Glyph{
            .codepoint = codepoint,
            .mask = mask,
            .w = uw,
            .h = uh,
            .xoff = xoff,
            .yoff = yoff,
            .advance = self.advanceOf(codepoint),
        };
        return self.addGlyph(g);
    }

    fn advanceOf(self: *Font, codepoint: u21) f32 {
        var adv: c_int = undefined;
        stb.stbtt_GetCodepointHMetrics(&self.info, @intCast(codepoint), &adv, null);
        return @as(f32, @floatFromInt(adv)) * self.scale;
    }

    /// 单个码点的**逻辑**前进量（字形已按 DPI 光栅化，这里除回逻辑像素）
    pub fn advanceLogical(self: *Font, cp: u21) f32 {
        const a = if (self.getGlyph(cp)) |g| g.advance else self.advanceOf(cp);
        return a / self.px_scale;
    }

    /// 字符串宽度（**逻辑像素**）
    pub fn measure(self: *Font, text: []const u8) f32 {
        var width: f32 = 0;
        var iter = Utf8Iter{ .s = text };
        while (iter.next()) |cp| {
            width += self.advanceLogical(cp);
        }
        return width;
    }

    /// 绘制文字：`x`/`y` 是**基线左端**（逻辑像素，y 向下为正）
    pub fn draw(self: *Font, r: Renderer, text: []const u8, x: f32, y: f32, color: Color) void {
        const s = self.px_scale;
        var pen_x = x * s;
        const base_y = y * s;
        var iter = Utf8Iter{ .s = text };
        while (iter.next()) |cp| {
            const g = self.getGlyph(cp) orelse continue;
            if (g.w > 0 and g.h > 0) {
                r.blitAlphaMaskPhys(
                    g.mask,
                    g.w,
                    g.h,
                    @intFromFloat(pen_x + @as(f32, @floatFromInt(g.xoff))),
                    @intFromFloat(base_y + @as(f32, @floatFromInt(g.yoff))),
                    color,
                );
            }
            pen_x += g.advance;
        }
    }
};

/// 极简 UTF-8 迭代器（只处理码点，不做校验；非法字节跳过）
const Utf8Iter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *Utf8Iter) ?u21 {
        if (self.i >= self.s.len) return null;
        const b0 = self.s[self.i];
        const len: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.s.len) {
            self.i = self.s.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.s[self.i .. self.i + len]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        self.i += len;
        return cp;
    }
};

test "font: UTF-8 迭代器" {
    var it = Utf8Iter{ .s = "a中b" };
    try std.testing.expectEqual(@as(u21, 'a'), it.next().?);
    try std.testing.expectEqual(@as(u21, '中'), it.next().?);
    try std.testing.expectEqual(@as(u21, 'b'), it.next().?);
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "font: 非法 UTF-8 不崩" {
    var it = Utf8Iter{ .s = "\xFF\xFE" };
    _ = it.next();
    _ = it.next();
    try std.testing.expectEqual(@as(?u21, null), it.next());
}
