//! 系统文件对话框（打开 / 保存）与消息框。
//!
//! **平台**：当前仅实现 Windows（comdlg32）。
//! 其他平台：`supported()` 返回 false，对话框 API 返回 null（视作取消）——
//! 上层无需 #if，只要在 `supported()` 为 false 时走"内联输入文件名"的回退路径。
//!
//! **Windows 实现说明**：
//! - 用 `GetOpenFileNameW` / `GetSaveFileNameW`（comdlg32）。Vista 之后这套旧 API
//!   仍显示**系统新式对话框**（内部转发到 shell 对话框），代码量远小于手写 COM。
//! - `OPENFILENAMEW` 必须精确匹配 Win32 布局（`lStructSize` 不对则函数直接失败）；
//!   本文件末尾有 `@sizeOf` 断言测试。
//! - 需要链接 `comdlg32`（见 build.zig）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// 本平台是否支持系统文件对话框
pub fn supported() bool {
    return is_windows;
}

/// Windows 部分（其他平台不编译）
const win = if (is_windows) struct {
    const OPENFILENAMEW = extern struct {
        lStructSize: u32,
        hwndOwner: ?*anyopaque,
        hInstance: ?*anyopaque = null,
        /// 过滤器：`描述\0通配\0...\0\0`（双 NUL 结尾）
        lpstrFilter: ?[*:0]const u16,
        lpstrCustomFilter: ?[*:0]u16 = null,
        nMaxCustFilter: u32 = 0,
        nFilterIndex: u32 = 1,
        /// 文件名缓冲区（调用方提供；in = 默认名，out = 用户选择）
        lpstrFile: [*:0]u16,
        nMaxFile: u32,
        lpstrFileTitle: ?[*:0]u16 = null,
        nMaxFileTitle: u32 = 0,
        lpstrInitialDir: ?[*:0]const u16 = null,
        lpstrTitle: ?[*:0]const u16 = null,
        Flags: u32 = 0,
        nFileOffset: u16 = 0,
        nFileExtension: u16 = 0,
        lpstrDefExt: ?[*:0]const u16 = null,
        lCustData: isize = 0,
        lpfnHook: ?*anyopaque = null,
        lpTemplateName: ?[*:0]const u16 = null,
        pvReserved: ?*anyopaque = null,
        dwReserved: u32 = 0,
        FlagsEx: u32 = 0,
    };

    extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) i32;
    extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(.winapi) i32;
    extern "user32" fn MessageBoxW(?*anyopaque, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) i32;

    // 标志位
    const OFN_OVERWRITEPROMPT: u32 = 0x0000_0002;
    const OFN_HIDEREADONLY: u32 = 0x0000_0004;
    const OFN_NOCHANGEDIR: u32 = 0x0000_0008;
    const OFN_PATHMUSTEXIST: u32 = 0x0000_0800;
    const OFN_FILEMUSTEXIST: u32 = 0x0000_1000;
    const OFN_EXPLORER: u32 = 0x0008_0000;

    // MessageBox 返回值
    const IDYES: i32 = 6;
    const IDNO: i32 = 7;

    /// 文件名缓冲区大小（UTF-16 码元数；Windows MAX_PATH 限制）
    const name_capacity: usize = 512;

    /// 通用对话框主体。`is_save` = true 时用保存对话框（覆盖提示），否则用打开对话框（必须存在）。
    fn dialog(
        allocator: std.mem.Allocator,
        is_save: bool,
        owner: ?*anyopaque,
        title: []const u8,
        default_name: []const u8,
        filter: []const u8,
    ) !?[]u8 {
        // 标题 / 默认名 / 过滤器 → UTF-16（含结尾 NUL）
        const title_w = try toUtf16Z(allocator, title);
        defer allocator.free(title_w);
        const filter_w = try toFilterUtf16Z(allocator, filter);
        defer allocator.free(filter_w);

        var name_buf: [name_capacity]u16 = [_]u16{0} ** name_capacity;
        if (default_name.len > 0) {
            const n = try toUtf16(default_name, name_buf[0 .. name_capacity - 1]);
            name_buf[n] = 0;
        }

        var ofn = OPENFILENAMEW{
            .lStructSize = @sizeOf(OPENFILENAMEW),
            .hwndOwner = owner,
            .lpstrFilter = @ptrCast(filter_w.ptr),
            .nFilterIndex = 1,
            .lpstrFile = @ptrCast(&name_buf),
            .nMaxFile = name_capacity,
            .lpstrTitle = @ptrCast(title_w.ptr),
            .Flags = OFN_EXPLORER | OFN_HIDEREADONLY | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | (if (is_save) OFN_OVERWRITEPROMPT else OFN_FILEMUSTEXIST),
            .lpstrDefExt = if (is_save) default_ext_w else null,
        };

        const ok = if (is_save) GetSaveFileNameW(&ofn) else GetOpenFileNameW(&ofn);
        if (ok == 0) return null; // 用户取消（或出错——两者都按取消处理）

        // 取回用户选择（名字缓冲区现在是路径）
        const len = std.mem.indexOfScalar(u16, &name_buf, 0) orelse name_capacity;
        return try std.unicode.utf16LeToUtf8Alloc(allocator, name_buf[0..len]);
    }

    /// 默认扩展名（UTF-16 常量："saw"）
    const default_ext_w: [*:0]const u16 = &[_:0]u16{ 's', 'a', 'w' };

    /// "打开"对话框：返回选择的路径（null = 取消）
    pub fn open(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, filter: []const u8) !?[]u8 {
        return dialog(allocator, false, owner, title, "", filter);
    }

    /// "保存"对话框：`default_name` 为建议文件名（null = 取消）
    pub fn save(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, default_name: []const u8, filter: []const u8) !?[]u8 {
        return dialog(allocator, true, owner, title, default_name, filter);
    }

    /// 保存/不保存/取消 三选一（退出前的脏提示）。
    /// 返回：.save / .discard / .cancel
    pub fn confirmSave(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) ConfirmResult {
        const text_w = toUtf16Z(allocator, text) catch return .cancel;
        defer allocator.free(text_w);
        const title_w = toUtf16Z(allocator, "未保存的修改") catch return .cancel;
        defer allocator.free(title_w);

        const MB_YESNOCANCEL: u32 = 0x0000_0003;
        const MB_ICONWARNING: u32 = 0x0000_0030;
        const r = MessageBoxW(owner, @ptrCast(text_w.ptr), @ptrCast(title_w.ptr), MB_YESNOCANCEL | MB_ICONWARNING);
        return switch (r) {
            IDYES => .save,
            IDNO => .discard,
            else => .cancel,
        };
    }

    /// 普通提示（信息框）
    pub fn alert(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) void {
        const text_w = toUtf16Z(allocator, text) catch return;
        defer allocator.free(text_w);
        const title_w = toUtf16Z(allocator, "Sawdust") catch return;
        defer allocator.free(title_w);
        const MB_OK: u32 = 0x0000_0000;
        const MB_ICONINFORMATION: u32 = 0x0000_0040;
        _ = MessageBoxW(owner, @ptrCast(text_w.ptr), @ptrCast(title_w.ptr), MB_OK | MB_ICONINFORMATION);
    }
} else struct {};

/// 三选一结果
pub const ConfirmResult = enum { save, discard, cancel };

// ── 跨平台 API（其他平台为取消/不支持）──

/// "打开"对话框：返回选择的路径（null = 取消或不支持）
pub fn open(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, filter: []const u8) !?[]u8 {
    if (!is_windows) return null;
    return win.open(allocator, owner, title, filter);
}

/// "保存"对话框：`default_name` 为建议文件名（null = 取消或不支持）
pub fn save(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, default_name: []const u8, filter: []const u8) !?[]u8 {
    if (!is_windows) return null;
    return win.save(allocator, owner, title, default_name, filter);
}

/// 保存/不保存/取消（其他平台固定返回 .cancel——上层应避免在无对话框平台走此路径）
pub fn confirmSave(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) ConfirmResult {
    if (!is_windows) return .cancel;
    return win.confirmSave(allocator, owner, text);
}

/// 信息提示框
pub fn alert(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) void {
    if (!is_windows) return;
    win.alert(allocator, owner, text);
}

// ── 工具（可测）──

/// 「Sawdust 工程」过滤器字符串（人类可读形式；`toFilterUtf16Z` 会转成 Win32 格式）
pub const project_filter = "Sawdust 工程 (*.saw)\x00*.saw\x00所有文件 (*.*)\x00*.*\x00";

/// 把「描述\0通配\0…\0」转成 UTF-16 + **双 NUL 结尾**（Win32 要求）。
/// 输入以单 NUL 分隔、单 NUL 结尾；输出在末尾再补一个 NUL。
pub fn toFilterUtf16Z(allocator: std.mem.Allocator, filter: []const u8) ![:0]u16 {
    // 计算需要的码元数（UTF-8 → UTF-16 最坏情况 ×2，加上双 NUL）
    var list: std.ArrayListUnmanaged(u16) = .{ .items = &.{}, .capacity = 0 };
    errdefer list.deinit(allocator);

    // 按 NUL 分段转换（保留分隔 NUL）
    var it = std.mem.splitScalar(u8, filter, 0);
    while (it.next()) |seg| {
        if (seg.len > 0) {
            const need = try std.unicode.calcUtf16LeLen(seg);
            const old = list.items.len;
            try list.resize(allocator, old + need);
            _ = try std.unicode.utf8ToUtf16Le(list.items[old..], seg);
        }
        try list.append(allocator, 0); // 段间 / 结尾 NUL
    }
    // 双 NUL：splitScalar 已给每段尾 NUL；若最后一段为空（原串以 NUL 结尾），上面已追加 → 再补一个
    try list.append(allocator, 0);

    return list.toOwnedSliceSentinel(allocator, 0);
}

/// UTF-8 → UTF-16（调用方保证缓冲够大）；返回写入的码元数
pub fn toUtf16(text: []const u8, out: []u16) !usize {
    return std.unicode.utf8ToUtf16Le(out, text);
}

/// UTF-8 → UTF-16（含结尾 NUL）
pub fn toUtf16Z(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    const need = try std.unicode.calcUtf16LeLen(text);
    const buf = try allocator.alloc(u16, need + 1);
    errdefer allocator.free(buf);
    _ = try std.unicode.utf8ToUtf16Le(buf[0..need], text);
    buf[need] = 0;
    return buf[0..need :0];
}

// ── 测试 ──

test "filedialog: 过滤器转为 UTF-16 双 NUL 结尾" {
    const allocator = std.testing.allocator;
    const f = try toFilterUtf16Z(allocator, project_filter);
    defer allocator.free(f);

    // 结构：描述 NUL 通配 NUL 描述 NUL 通配 NUL NUL
    // 断言：含两个连续的 0（双 NUL 结尾）且以 0 结尾
    try std.testing.expect(f.len >= 2);
    try std.testing.expectEqual(@as(u16, 0), f[f.len - 1]);
    try std.testing.expectEqual(@as(u16, 0), f[f.len - 2]);

    // 应包含 "*.saw" 的 UTF-16 序列
    const needle = [_]u16{ '*', '.', 's', 'a', 'w' };
    var found = false;
    var i: usize = 0;
    while (i + needle.len <= f.len) : (i += 1) {
        if (std.mem.eql(u16, f[i .. i + needle.len], &needle)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "filedialog: UTF-8 → UTF-16（含中文与 NUL 结尾）" {
    const allocator = std.testing.allocator;
    const s = try toUtf16Z(allocator, "工程文件.saw");
    defer allocator.free(s);
    try std.testing.expectEqual(@as(u16, 0), s[s.len]);
    // 中文 '工' = U+5DE5
    try std.testing.expectEqual(@as(u16, 0x5DE5), s[0]);
    // "工"占 1 个 UTF-16 码元；"程文件" 3 个；".saw" 4 个 → 共 8
    try std.testing.expectEqual(@as(usize, 8), s.len);
}

test "filedialog: 平台能力标志自洽" {
    const expect_supported = builtin.os.tag == .windows;
    try std.testing.expectEqual(expect_supported, supported());
}

test "filedialog: OPENFILENAMEW 布局（大小必须匹配 Win32）" {
    if (!is_windows) return error.SkipZigTest;
    // Win32 上 OPENFILENAMEW 在 64 位下为 152 字节（字段对齐后的固定值）。
    // 若此断言失败，说明结构体定义与 Win32 布局不符——对话框会静默失败。
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(win.OPENFILENAMEW));
}
