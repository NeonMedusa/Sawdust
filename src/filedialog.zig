//! 系统文件对话框（打开 / 保存 / 选文件夹）。
//!
//! ## 当前状态（见 `docs/file-dialogs.md` 的「决策记录」）
//!
//! | 平台 | 用的是什么 | 阻塞吗 |
//! |---|---|---|
//! | **Linux** | **内置自绘选择器**（`src/file_picker.zig`）——**无条件**，不看桌面装了谁 | 否（主循环每帧推进） |
//! | **Windows** | 本文件的 `GetOpenFileNameW` / `SHBrowseForFolderW`（系统原生观感） | **是**（已知问题，单独立项，见文档 §13） |
//!
//! ### Linux 的 kdialog / zenity（**停用保留**）
//!
//! 下面 `linux` 命名空间里的 kdialog → zenity 适配代码**保留但不启用**：
//! 它们只是 toolkik CLI 垫片（不是标准），而且同步 `std.process.run` 会卡住 UI 线程
//! → 序列器 4 小节前瞻被耗干 → 音乐十秒后停。
//! 将来若要用（想要 KDE/GNOME 原生观感、或想接 XDG Portal），先把
//! `linux_external_enabled` 改成 `true`、并按文档把它改成**异步 spawn**，别直接打开。
//!
//! ### Windows 实现说明
//!
//! - 用 `GetOpenFileNameW` / `GetSaveFileNameW`（comdlg32）。Vista 之后这套旧 API
//!   仍显示**系统新式对话框**（内部转发到 shell 对话框），代码量远小于手写 COM。
//! - `OPENFILENAMEW` 必须精确匹配 Win32 布局（`lStructSize` 不对则函数直接失败）；
//!   本文件末尾有 `@sizeOf` 断言测试。
//! - 需要链接 `comdlg32`（见 build.zig）。
//! - ⚠️ **这里是同步调用**：它会阻塞 UI 线程。Windows 上"弹框约十秒后音乐停"的根治方案
//!   （工作线程跑系统对话框 + 主循环每帧轮询）见 `docs/file-dialogs.md` §3，属于**独立问题**。

const std = @import("std");
const builtin = @import("builtin");
const port_io = @import("port_io.zig");

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

/// **Linux 外部对话框提供者（kdialog → zenity）：已停用，仅保留代码。**
///
/// 原因：同步 `std.process.run` 会阻塞 UI 线程 → 调度前瞻耗尽 → 音乐十秒后停；
/// 而 Linux 现在一律用内置自绘选择器（`file_picker.zig`），不依赖桌面装了什么。
/// 要重新启用：改成 `true` **并且**把 `linux` 里的等待改成异步 spawn（见 docs）。
pub const linux_external_enabled = false;

/// 本平台是否"有可用的文件选择能力"（含内置自绘选择器）。
/// 注意：Windows 是系统对话框；Linux 是内置自绘；两者都算 supports。
pub fn supported() bool {
    return is_windows or is_linux;
}

/// Linux 实现：**外部 zenity**（GTK 对话框）——比自己写 XDG portal 便宜得多。
/// 约定：exit 0 = 选中（stdout 是路径），其它 = 取消。
/// Linux 实现：**外部对话框程序**（不作自绘，见 docs/linux.md §文件对话框）。
///
/// 优先级：**KDE 会话 → `kdialog`**（原生观感 + 记得上次目录），否则 **`zenity`**；
/// 两者都不可用时返回 `.failed`，由上层决定是否退到"极简自绘选择器"。
/// 约定：exit 0 = 选中（stdout 是路径），exit 1 = 用户取消，其它 = 失败（可回退）。
const linux = if (is_linux) struct {
    const Outcome = union(enum) {
        /// page_allocator 分配（调用方 free）
        ok: []const u8,
        cancelled,
        /// 程序不存在/启动失败/异常退出 → 上游可换下一个提供者
        failed,
    };

    fn runOutcome(argv: []const []const u8) Outcome {
        const res = std.process.run(std.heap.page_allocator, port_io.blocking(), .{ .argv = argv }) catch return .failed;
        defer std.heap.page_allocator.free(res.stderr);
        switch (res.term) {
            .exited => |code| {
                if (code == 0) return .{ .ok = res.stdout };
                std.heap.page_allocator.free(res.stdout);
                return if (code == 1) .cancelled else .failed;
            },
            else => {
                std.heap.page_allocator.free(res.stdout);
                return .failed;
            },
        }
    }

    fn envValue(name: [:0]const u8) ?[]const u8 {
        const p = std.c.getenv(name) orelse return null;
        return std.mem.span(p);
    }

    /// 大小写无关的子串查找（0.17 里 std.ascii 没有 indexOfIgnoreCase）
    fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or hay.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
        }
        return false;
    }
    /// 是否 KDE 会话（`KDE_FULL_SESSION` / `XDG_CURRENT_DESKTOP` 含 KDE）
    fn isKdeSession() bool {
        if (envValue("KDE_FULL_SESSION") != null) return true;
        if (envValue("XDG_CURRENT_DESKTOP")) |d| {
            if (containsIgnoreCase(d, "kde")) return true;
        }
        return false;
    }

    /// `描述\0*.a;*.b\0…` → kdialog 的 `描述(*.a *.b)\n…`（kdialog 用空格分隔通配、`\n` 分隔多组）
    fn toKdialogFilter(allocator: std.mem.Allocator, filter: []const u8) !?[]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, filter, 0);
        while (it.next()) |desc| {
            const pats = it.next() orelse break;
            if (desc.len == 0 or pats.len == 0) continue;
            if (out.items.len > 0) try out.append(allocator, '\n');
            // 描述里**通常已带** `(*.ext)` 后缀（我们的 filter 就是这么写的）→ 先去掉，避免出现 `(…)(…)`
            const name = if (std.mem.indexOfScalar(u8, desc, '(')) |i| std.mem.trimEnd(u8, desc[0..i], " ") else desc;
            try out.appendSlice(allocator, name);
            try out.append(allocator, '(');
            for (pats) |c| try out.append(allocator, if (c == ';') ' ' else c);
            try out.append(allocator, ')');
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// `描述\0*.a;*.b\0…` → zenity 的多个 `--file-filter=描述 | *.a *.b`
    fn addZenityFilters(cmd: *Cmd, filter: []const u8) !void {
        var it = std.mem.splitScalar(u8, filter, 0);
        while (it.next()) |desc| {
            const pats = it.next() orelse break;
            if (desc.len == 0 or pats.len == 0) continue;
            const pats_sp = try std.mem.replaceOwned(u8, cmd.allocator, pats, ";", " ");
            defer cmd.allocator.free(pats_sp);
            try cmd.ownedArg("--file-filter={s} | {s}", .{ desc, pats_sp });
        }
    }

    // ── kdialog ──

    fn kdialogOpen(allocator: std.mem.Allocator, title: []const u8, filter: []const u8) ?Outcome {
        const f = toKdialogFilter(allocator, filter) catch null;
        defer if (f) |s| allocator.free(s);
        // ⚠️ 必须带 `--getopenfilename`（漏了它 kdialog 会打印 usage 并以 0 退出——实测踩过）
        const argv = [_][]const u8{ "kdialog", "--getopenfilename", ":sawdust-open", f orelse "", "--title", title };
        return runOutcome(&argv);
    }

    fn kdialogSave(allocator: std.mem.Allocator, title: []const u8, default_name: []const u8, filter: []const u8) ?Outcome {
        const f = toKdialogFilter(allocator, filter) catch null;
        defer if (f) |s| allocator.free(s);
        const start = std.fmt.allocPrint(allocator, "{s}", .{default_name}) catch return null;
        defer allocator.free(start);
        const argv = [_][]const u8{ "kdialog", "--getsavefilename", start, f orelse "", "--title", title };
        return runOutcome(&argv);
    }

    fn kdialogFolder(title: []const u8) ?Outcome {
        const argv = [_][]const u8{ "kdialog", "--getexistingdirectory", ":sawdust-folder", "--title", title };
        return runOutcome(&argv);
    }

    // ── zenity ──

    /// 命令行组装：`argv` 存借用的字面量，`owned` 存需要释放的拼接串
    const Cmd = struct {
        owned: std.ArrayListUnmanaged([]u8) = .empty,
        argv: std.ArrayListUnmanaged([]const u8) = .empty,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) Cmd {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Cmd) void {
            for (self.owned.items) |s| self.allocator.free(s);
            self.owned.deinit(self.allocator);
            self.argv.deinit(self.allocator);
            self.* = undefined;
        }

        /// 借用字面量参数
        fn arg(self: *Cmd, a: []const u8) !void {
            try self.argv.append(self.allocator, a);
        }

        /// 拼接出来的参数（`deinit` 时统一释放）
        fn ownedArg(self: *Cmd, comptime fmt: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(self.allocator, fmt, args);
            errdefer self.allocator.free(s);
            try self.owned.append(self.allocator, s);
            try self.argv.append(self.allocator, s);
        }
    };

    fn takePath(allocator: std.mem.Allocator, out: []const u8) !?[]u8 {
        const path = std.mem.trimEnd(u8, out, "\r\n");
        if (path.len == 0) return null;
        return try allocator.dupe(u8, path);
    }

    fn open(allocator: std.mem.Allocator, title: []const u8, filter: []const u8) !?[]u8 {
        // ① KDE 会话且有 kdialog → 原生观感
        if (isKdeSession()) {
            if (kdialogOpen(allocator, title, filter)) |r| switch (r) {
                .ok => |out| {
                    defer std.heap.page_allocator.free(out);
                    const trimmed = std.mem.trim(u8, out, " \\r\\n");
                    // 空输出 = kdialog 静默失败（实测：WSLg 下 0 退出但不弹窗）→ 回退 zenity
                    if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
                },
                .cancelled => return null,
                .failed => {}, // 退回 zenity
            };
        }
        // ② zenity
        var cmd = Cmd.init(allocator);
        defer cmd.deinit();
        try cmd.arg("zenity");
        try cmd.arg("--file-selection");
        try cmd.ownedArg("--title={s}", .{title});
        try addZenityFilters(&cmd, filter);
        switch (runOutcome(cmd.argv.items)) {
            .ok => |out| {
                defer std.heap.page_allocator.free(out);
                return takePath(allocator, out);
            },
            else => return null,
        }
    }

    fn save(allocator: std.mem.Allocator, title: []const u8, default_name: []const u8, filter: []const u8) !?[]u8 {
        if (isKdeSession()) {
            if (kdialogSave(allocator, title, default_name, filter)) |r| switch (r) {
                .ok => |out| {
                    defer std.heap.page_allocator.free(out);
                    const trimmed = std.mem.trim(u8, out, " \\r\\n");
                    if (trimmed.len > 0) return try allocator.dupe(u8, trimmed); // 空 = kdialog 静默失败 → 回退 zenity
                },
                .cancelled => return null,
                .failed => {},
            };
        }
        var cmd = Cmd.init(allocator);
        defer cmd.deinit();
        try cmd.arg("zenity");
        try cmd.arg("--file-selection");
        try cmd.arg("--save");
        try cmd.arg("--confirm-overwrite");
        try cmd.ownedArg("--title={s}", .{title});
        try cmd.ownedArg("--filename={s}", .{default_name});
        try addZenityFilters(&cmd, filter);
        switch (runOutcome(cmd.argv.items)) {
            .ok => |out| {
                defer std.heap.page_allocator.free(out);
                return takePath(allocator, out);
            },
            else => return null,
        }
    }

    fn pickFolder(allocator: std.mem.Allocator, title: []const u8) !?[]u8 {
        if (isKdeSession()) {
            if (kdialogFolder(title)) |r| switch (r) {
                .ok => |out| {
                    defer std.heap.page_allocator.free(out);
                    const trimmed = std.mem.trim(u8, out, " \\r\\n");
                    if (trimmed.len > 0) return try allocator.dupe(u8, trimmed); // 空 = kdialog 静默失败 → 回退 zenity
                },
                .cancelled => return null,
                .failed => {},
            };
        }
        var cmd = Cmd.init(allocator);
        defer cmd.deinit();
        try cmd.arg("zenity");
        try cmd.arg("--file-selection");
        try cmd.arg("--directory");
        try cmd.ownedArg("--title={s}", .{title});
        switch (runOutcome(cmd.argv.items)) {
            .ok => |out| {
                defer std.heap.page_allocator.free(out);
                return takePath(allocator, out);
            },
            else => return null,
        }
    }

    fn alert(allocator: std.mem.Allocator, text: []const u8) void {
        if (isKdeSession()) {
            const argv = [_][]const u8{ "kdialog", "--msgbox", text };
            if (runOutcome(&argv)) |r| switch (r) {
                .ok => |out| std.heap.page_allocator.free(out),
                else => {},
            };
            return;
        }
        var cmd = Cmd.init(allocator);
        defer cmd.deinit();
        cmd.arg("zenity") catch return;
        cmd.arg("--info") catch return;
        cmd.ownedArg("--text={s}", .{text}) catch return;
        if (runOutcome(cmd.argv.items)) |r| switch (r) {
            .ok => |out| std.heap.page_allocator.free(out),
            else => {},
        };
    }

    fn confirmSave(allocator: std.mem.Allocator, text: []const u8) ConfirmResult {
        _ = allocator;
        if (isKdeSession()) {
            const argv = [_][]const u8{ "kdialog", "--yesnocancel", text };
            return switch (runOutcome(&argv) orelse .failed) {
                .ok => |out| blk: {
                    std.heap.page_allocator.free(out);
                    break :blk .save;
                },
                .cancelled => .discard, // kdialog: exit 1 = No
                .failed => .cancel,
            };
        }
        const argv = [_][]const u8{ "zenity", "--question", text, "--ok-label=保存", "--extra-button=不保存", "--cancel-label=取消" };
        const res = std.process.run(std.heap.page_allocator, port_io.blocking(), .{ .argv = &argv }) catch return .cancel;
        std.heap.page_allocator.free(res.stdout);
        std.heap.page_allocator.free(res.stderr);
        if (res.term != .exited) return .cancel;
        return switch (res.term.exited) {
            0 => .save,
            1 => .discard, // --extra-button
            else => .cancel,
        };
    }
} else struct {};

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

        var name_buf: [name_capacity]u16 = @splat(0);
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

    // ── 文件夹选择（shell32 SHBrowseForFolderW；插件管理“+ 添加文件夹…”）──
    const BROWSEINFOW = extern struct {
        hwndOwner: ?*anyopaque = null,
        pidlRoot: ?*anyopaque = null,
        pszDisplayName: ?[*]u16 = null,
        lpszTitle: ?[*:0]const u16 = null,
        ulFlags: u32 = 0,
        lpfn: ?*anyopaque = null,
        lParam: isize = 0,
        iImage: i32 = 0,
    };
    extern "shell32" fn SHBrowseForFolderW(*BROWSEINFOW) callconv(.winapi) ?*anyopaque;
    extern "shell32" fn SHGetPathFromIDListW(*anyopaque, [*]u16) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
    extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;

    /// 文件夹选择框（取消 → null）。`BIF_NEWDIALOGSTYLE` 需要 COM 已初始化 →
    /// 调用前 `CoInitializeEx`（重复调用无害，返回 S_FALSE）。
    fn pickFolder(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8) !?[]u8 {
        _ = CoInitializeEx(null, 2); // COINIT_APARTMENTTHREADED
        const title_w = toUtf16Z(allocator, title) catch return null;
        defer allocator.free(title_w);
        var display: [260]u16 = undefined;
        var bi = BROWSEINFOW{
            .hwndOwner = owner,
            .pszDisplayName = &display,
            .lpszTitle = title_w.ptr,
            .ulFlags = 0x0001 | 0x0040, // BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
        };
        const pidl = SHBrowseForFolderW(&bi) orelse return null;
        defer CoTaskMemFree(pidl);
        var path_buf: [1024]u16 = undefined;
        if (SHGetPathFromIDListW(pidl, &path_buf) == 0) return null;
        const slice = std.mem.sliceTo(&path_buf, 0);
        return try std.unicode.utf16LeToUtf8Alloc(allocator, slice);
    }
} else struct {};

// 停用代码的防腐烂守卫：只取函数地址，确保它们**仍然能编译**。
// （`linux_external_enabled = false` 会让上面的调用点在编译期被剪掉，若没有这层守卫，
// 停用的适配代码会在无人察觉的情况下烂掉。）
test "filedialog: Linux 外部提供者（停用中）仍然编译得过" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const refs = .{ &linux.open, &linux.save, &linux.pickFolder, &linux.confirmSave, &linux.alert };
    try std.testing.expect(@sizeOf(@TypeOf(refs)) > 0);
    try std.testing.expect(!linux_external_enabled); // 现实中必须是停用状态
}

/// 三选一结果
pub const ConfirmResult = enum { save, discard, cancel };

// ── 跨平台 API（其他平台为取消/不支持）──

/// "打开"对话框：返回选择的路径（null = 取消或不支持）
pub fn open(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, filter: []const u8) !?[]u8 {
    if (is_windows) return win.open(allocator, owner, title, filter);
    if (is_linux and linux_external_enabled) return linux.open(allocator, title, filter);
    return null;
}

/// "保存"对话框：`default_name` 为建议文件名（null = 取消或不支持）
pub fn save(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8, default_name: []const u8, filter: []const u8) !?[]u8 {
    if (is_windows) return win.save(allocator, owner, title, default_name, filter);
    if (is_linux and linux_external_enabled) return linux.save(allocator, title, default_name, filter);
    return null;
}

/// 保存/不保存/取消（其他平台固定返回 .cancel——上层应避免在无对话框平台走此路径）
pub fn confirmSave(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) ConfirmResult {
    if (is_windows) return win.confirmSave(allocator, owner, text);
    if (is_linux and linux_external_enabled) return linux.confirmSave(allocator, text);
    return .cancel;
}

/// 信息提示框
pub fn alert(allocator: std.mem.Allocator, owner: ?*anyopaque, text: []const u8) void {
    if (is_windows) return win.alert(allocator, owner, text);
    if (is_linux and linux_external_enabled) return linux.alert(allocator, text);
}

/// 选择文件夹（null = 取消或不支持）——插件管理的“+ 添加文件夹…”
pub fn pickFolder(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8) !?[]u8 {
    if (is_windows) return win.pickFolder(allocator, owner, title);
    if (is_linux and linux_external_enabled) return linux.pickFolder(allocator, title);
    return null;
}

// ── 工具（可测）──

/// 「Sawdust 工程」过滤器字符串（人类可读形式；`toFilterUtf16Z` 会转成 Win32 格式）
pub const project_filter = "Sawdust 工程 (*.saw)\x00*.saw\x00所有文件 (*.*)\x00*.*\x00";
pub const audio_filter = "音频文件 (*.wav;*.flac;*.mp3;*.ogg)\x00*.wav;*.flac;*.mp3;*.ogg\x00所有文件 (*.*)\x00*.*\x00";
pub const wav_filter = "WAV 音频 (*.wav)\x00*.wav\x00所有文件 (*.*)\x00*.*\x00";
pub const vst3_filter = "VST3 插件 (*.vst3)\x00*.vst3\x00所有文件 (*.*)\x00*.*\x00";

/// 把「描述\0通配\0…\0」转成 UTF-16 + **双 NUL 结尾**（Win32 要求）。
/// 输入以单 NUL 分隔、单 NUL 结尾；输出在末尾再补一个 NUL。
pub fn toFilterUtf16Z(allocator: std.mem.Allocator, filter: []const u8) ![:0]u16 {
    // 计算需要的码元数（UTF-8 → UTF-16 最坏情况 ×2，加上双 NUL）
    var list: std.ArrayListUnmanaged(u16) = .empty;
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
