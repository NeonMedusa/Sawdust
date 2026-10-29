//! 文本编辑的公共部分：**重命名输入框**（`app.TextInput`）与**文件选择器**
//! （`file_picker.Picker`）共用同一套语义，避免两边行为不一致。
//!
//! 这里只放"状态 + 纯函数"：缓冲区用定长切片传入（调用方各自持有 `[N]u8`），
//! 所以两边都能用，不需要堆分配、也不引入生命周期问题。
//!
//! 约定（两边一致）：
//! - `len` 是有效字节数，`cursor`/`anchor` 都是**字节偏移**且落在 code point 边界；
//! - `anchor == null` 或 `anchor == cursor` = 无选区；
//! - 任何插入/删除前都先删选区（典型编辑器行为）；
//! - `Ctrl+C` / `Ctrl+X` 在**无选区**时作用于整个字段（复制整串 / 清空），
//!   这是刻意选择：路径栏里直接 Ctrl+C 就能复制整条路径。
const std = @import("std");
const port_io = @import("port_io.zig");

/// 光标闪烁周期（ms）：亮一半、灭一半
pub const blink_period_ms: i64 = 530;

pub fn nowMs() i64 {
    return port_io.nowMs();
}

/// 光标是否该亮。`epoch` = 最近一次输入/移动光标/点击的时刻（ms）：
/// 以它为起点先亮后灭，所以"刚打完字"时一定是亮的（和常见编辑器一致）。
pub fn blinkOnSince(epoch: i64) bool {
    const now = nowMs();
    const d = if (now > epoch) now - epoch else 0;
    return @mod(@divTrunc(d, blink_period_ms), 2) == 0;
}

/// 选区字节区间 `[lo, hi)`
pub const Sel = struct { lo: usize, hi: usize };

/// 由（光标, 锚点, 长度）求选区；无锚点或两端重合 → null。
/// **防御**：两端都鉗到 `len` 内，陈旧锚点不会让渲染越界。
pub fn selRange(cursor: usize, anchor: ?usize, len: usize) ?Sel {
    const a = @min(anchor orelse return null, len);
    const c = @min(cursor, len);
    if (a == c) return null;
    return .{ .lo = @min(a, c), .hi = @max(a, c) };
}

/// 选区内的文本（无选区 → 空串）
pub fn selText(text: []const u8, sel: ?Sel) []const u8 {
    const s = sel orelse return &.{};
    const hi = @min(s.hi, text.len);
    return text[@min(s.lo, hi)..hi];
}

/// `Sel` → `ui.textField` 需要的 `[2]usize`
pub fn selPair(sel: ?Sel) ?[2]usize {
    const s = sel orelse return null;
    return .{ s.lo, s.hi };
}

/// 前一个 code point 的起始偏移（UTF-8 续字节是 10xxxxxx）
pub fn prevCodePoint(text: []const u8, from: usize) usize {
    if (from == 0) return 0;
    var i = @min(from, text.len) - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// 后一个 code point 的结束偏移
pub fn nextCodePoint(text: []const u8, from: usize) usize {
    if (from >= text.len) return text.len;
    var i = from + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

/// 删掉选区（无选区 → 返回 false，光标不动）
pub fn deleteSelection(buf: []u8, len: *usize, cursor: *usize, anchor: *?usize) bool {
    const sel = selRange(cursor.*, anchor.*, len.*) orelse return false;
    const tail = len.* - sel.hi;
    std.mem.copyForwards(u8, buf[sel.lo .. sel.lo + tail], buf[sel.hi..len.*]);
    len.* -= sel.hi - sel.lo;
    cursor.* = sel.lo;
    anchor.* = null;
    return true;
}

/// 在光标处插入（先删选区；放不下就整段放弃）
pub fn insertSlice(buf: []u8, len: *usize, cursor: *usize, anchor: *?usize, s: []const u8) bool {
    _ = deleteSelection(buf, len, cursor, anchor);
    const room = buf.len - len.*;
    const n = @min(s.len, room);
    if (n == 0) return false;
    const at = @min(cursor.*, len.*);
    const tail = len.* - at;
    // 尾部右移 n 字节（从后往前——重叠安全）
    std.mem.copyBackwards(u8, buf[at + n .. at + n + tail], buf[at .. at + tail]);
    @memcpy(buf[at .. at + n], s[0..n]);
    len.* += n;
    cursor.* = at + n;
    return true;
}

/// 退格：有选区删选区，否则删光标前一个 code point
pub fn deleteBackward(buf: []u8, len: *usize, cursor: *usize, anchor: *?usize) void {
    if (deleteSelection(buf, len, cursor, anchor)) return;
    if (cursor.* == 0) return;
    const from = prevCodePoint(buf[0..len.*], cursor.*);
    const rm = cursor.* - from;
    var i = from;
    while (i + rm < len.*) : (i += 1) buf[i] = buf[i + rm];
    len.* -= rm;
    cursor.* = from;
}

/// Delete：有选区删选区，否则删光标后一个 code point
pub fn deleteForward(buf: []u8, len: *usize, cursor: *usize, anchor: *?usize) void {
    if (deleteSelection(buf, len, cursor, anchor)) return;
    if (cursor.* >= len.*) return;
    const to = nextCodePoint(buf[0..len.*], cursor.*);
    const rm = to - cursor.*;
    var i = cursor.*;
    while (i + rm < len.*) : (i += 1) buf[i] = buf[i + rm];
    len.* -= rm;
}

/// 左右移动；`extend` = Shift（拉选区：锚点保持，没有就锚在当前光标）
pub fn moveCursor(buf: []const u8, len: usize, cursor: *usize, anchor: *?usize, dir: i32, extend: bool) void {
    if (!extend) {
        // 无 Shift：有选区就收拢（先跳到选区一端，不移动）
        if (selRange(cursor.*, anchor.*, len)) |sel| {
            anchor.* = null;
            cursor.* = if (dir < 0) sel.lo else sel.hi;
            return;
        }
    } else if (anchor.* == null) {
        anchor.* = cursor.*;
    }
    if (dir < 0) {
        cursor.* = prevCodePoint(buf[0..len], cursor.*);
    } else {
        cursor.* = nextCodePoint(buf[0..len], cursor.*);
    }
}

pub fn moveToStart(len: usize, cursor: *usize, anchor: *?usize, extend: bool) void {
    _ = len;
    if (extend) {
        if (anchor.* == null) anchor.* = cursor.*;
    } else {
        anchor.* = null;
    }
    cursor.* = 0;
}

pub fn moveToEnd(len: usize, cursor: *usize, anchor: *?usize, extend: bool) void {
    if (extend) {
        if (anchor.* == null) anchor.* = cursor.*;
    } else {
        anchor.* = null;
    }
    cursor.* = len;
}

/// 全选
pub fn selectAll(len: usize, cursor: *usize, anchor: *?usize) void {
    anchor.* = 0;
    cursor.* = len;
}

// ── 测试 ──

test "text_edit: 选区求值（含陈旧锚点防御）" {
    try std.testing.expectEqual(@as(?Sel, null), selRange(0, null, 5));
    try std.testing.expectEqual(@as(?Sel, null), selRange(2, 2, 5));
    try std.testing.expectEqual(Sel{ .lo = 1, .hi = 3 }, selRange(3, 1, 5).?);
    try std.testing.expectEqual(Sel{ .lo = 0, .hi = 5 }, selRange(38, 0, 5).?); // 锚点/光标越界 → 鉗住
    try std.testing.expectEqualStrings("bc", selText("abcde", selRange(3, 1, 5)));
    try std.testing.expectEqualStrings("", selText("abcde", null));
}

test "text_edit: 插入/退格/删除守 UTF-8 码点边界" {
    var buf: [16]u8 = @splat(0);
    var len: usize = 0;
    var cursor: usize = 0;
    var anchor: ?usize = null;
    _ = insertSlice(buf[0..], &len, &cursor, &anchor, "阿a");
    try std.testing.expectEqualStrings("阿a", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 4), cursor);
    deleteBackward(buf[0..], &len, &cursor, &anchor);
    try std.testing.expectEqualStrings("阿", buf[0..len]); // 汉字整块删掉，不留半个
    cursor = 0;
    deleteForward(buf[0..], &len, &cursor, &anchor);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "text_edit: 有选区时输入 = 先删选区再插入" {
    var buf: [16]u8 = @splat(0);
    var len: usize = 0;
    var cursor: usize = 0;
    var anchor: ?usize = null;
    _ = insertSlice(buf[0..], &len, &cursor, &anchor, "hello");
    selectAll(len, &cursor, &anchor);
    _ = insertSlice(buf[0..], &len, &cursor, &anchor, "hi");
    try std.testing.expectEqualStrings("hi", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), cursor);
    try std.testing.expectEqual(@as(?usize, null), anchor);
}

test "text_edit: 无 Shift 移动光标会收拢选区" {
    var cursor: usize = 1;
    var anchor: ?usize = 4;
    moveCursor("abcde", 5, &cursor, &anchor, -1, false);
    try std.testing.expectEqual(@as(usize, 1), cursor); // 先跳到选区左端
    try std.testing.expectEqual(@as(?usize, null), anchor);
    moveCursor("abcde", 5, &cursor, &anchor, 1, true); // Shift+→：锚在 1，光标到 2
    try std.testing.expectEqual(@as(usize, 2), cursor);
    try std.testing.expectEqual(@as(?usize, 1), anchor);
}

test "text_edit: 光标闪烁以 epoch 为起点先亮后灭" {
    const e = nowMs();
    try std.testing.expect(blinkOnSince(e)); // 刚输入 → 亮
    try std.testing.expect(!blinkOnSince(e - (blink_period_ms + 50))); // 半个周期前 → 灭
    try std.testing.expect(blinkOnSince(e - blink_period_ms * 2)); // 一整个周期前 → 又亮
}
