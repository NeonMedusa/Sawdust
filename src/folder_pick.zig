//! **选目录对话框（Windows / 异步）**：`IFileOpenDialog` + `FOS_PICKFOLDERS`
//! —— 外观与「打开 / 另存为」一致（Vista+ Explorer 风格），只是选目录。
//!
//! ## 为什么是“专用 STA 线程 + 每帧轮询”而不是同步调用
//!
//! 两条**实测**结论（复现程序验证过）：
//!
//! 1. **UI 线程是 MTA**：miniaudio/WASAPI 在 `ma_context_init` 里对当前线程做了
//!    `CoInitializeEx(COINIT_MULTITHREADED)`。而 shell 文件对话框（`IFileOpenDialog`、
//!    以及老式 `SHBrowseForFolderW` + `BIF_NEWDIALOGSTYLE`）要求 **STA**：
//!    MTA 下 `BIF_NEWDIALOGSTYLE` 的 `SHBrowseForFolderW` **永不返回**且不建任何窗口
//!    → 用户看到的就是“点＋添加文件夹… → 程序未响应”。
//! 2. **owner 窗口跨线程时不能阻塞**：`Show(hwnd)` 会同步 `EnableWindow(owner)`；
//!    如果 UI 线程此刻正阻塞等结果，两边互相等死（实测：真实 owner + 同步等待 = 永不返回；
//!    让主循环继续泵消息 = 正常）。
//!
//! 所以：对话框跑在**自己初始化的 STA 工作线程**上，UI 线程每帧 `poll()` 非阻塞取结果
//! （顺带把文档 §13.3 的“Windows 弹框冻结 UI”在这个对话框上彻底消掉）。
//!
//! 工作线程**不做任何内存分配**：标题/路径都写回 `Ctx` 里的固定缓冲，
//! UTF-8 拷贝在 UI 线程（`poll`）里用调用方分配器完成。
//!
//! 用法：`start` → 每帧 `poll` 直到 `.finished` → `destroy`。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

/// 对话框参数 / 结果（跨线程共享）。
/// 约定：工作线程只在**最后**置位 `done`（release）；UI 线程读到 `done` 之后才读其它字段。
pub const Ctx = struct {
    owner: ?*anyopaque = null,
    title_w: [256]u16 = @splat(0),
    title_len: usize = 0,
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    /// 0 = 拿到路径；负数 = 用户取消 / 失败（HRESULT）
    hr: i32 = -1,
    done: std.atomic.Value(bool) = .init(false),

    /// 工作线程入口
    fn run(ctx: *@This()) void {
        if (comptime supported) {
            com.runDialog(ctx);
        } else {
            // 非 Windows：没有对话框可开（`Job.start` 本来就不会起线程，这里只兜底）
            ctx.done.store(true, .release);
        }
    }
};

/// 一次选目录作业
pub const Job = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    ctx: *Ctx,
    joined: bool = false,

    pub const Status = union(enum) {
        /// 对话框还开着
        pending,
        /// 结束（null = 用户取消 / 失败）；非 null 由调用方 `free`
        finished: ?[]u8,
    };

    /// 起一个选目录对话框（**非阻塞**）。`owner` = 主窗口句柄（跨线程；模态由 shell 处理）。
    pub fn start(allocator: std.mem.Allocator, owner: ?*anyopaque, title: []const u8) ?Job {
        if (!supported) return null;
        const ctx = allocator.create(Ctx) catch return null;
        ctx.* = .{ .owner = owner };
        // 标题 → UTF-16（留 0 终止位；转换失败 = 无标题）
        ctx.title_len = std.unicode.utf8ToUtf16Le(ctx.title_w[0 .. ctx.title_w.len - 1], title) catch 0;
        ctx.title_w[ctx.title_len] = 0;
        const th = std.Thread.spawn(.{}, Ctx.run, .{ctx}) catch {
            allocator.destroy(ctx);
            return null;
        };
        return .{ .allocator = allocator, .thread = th, .ctx = ctx };
    }

    /// 每帧调用（非阻塞）：完成 → 返回路径（或取消）
    pub fn poll(self: *Job) Status {
        if (!self.ctx.done.load(.acquire)) return .pending;
        self.reap();
        if (self.ctx.hr < 0 or self.ctx.path_len == 0) return .{ .finished = null };
        return .{ .finished = self.allocator.dupe(u8, self.ctx.path[0..self.ctx.path_len]) catch null };
    }

    /// 回收线程（`done` 已置位时立即返回）
    fn reap(self: *Job) void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
    }

    /// 释放作业（`poll` 返回 `.finished` 之后必须调）。
    /// **对话框还开着时**（进程退出路径）：`detach` + 故意泄漏 `ctx`——
    /// join 会死等（对话框在等人点），而释放 `ctx` 会给工作线程 UAF；进程即将退出，泄漏最安全。
    pub fn destroy(self: *Job) void {
        if (!self.ctx.done.load(.acquire)) {
            self.thread.detach();
            return; // ctx 不释放
        }
        self.reap();
        self.allocator.destroy(self.ctx);
    }
};

// ───────────────────────────── Windows（COM）─────────────────────────────

const com = if (builtin.os.tag == .windows) struct {
    const Guid = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };

    /// CLSID_FileOpenDialog {DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}
    const clsid_file_open_dialog = Guid{
        .d1 = 0xDC1C5A9C,
        .d2 = 0xE88A,
        .d3 = 0x4DDE,
        .d4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
    };
    /// IID_IFileOpenDialog {D57C7288-D4AD-4768-BE02-9D969532D960}
    const iid_file_open_dialog = Guid{
        .d1 = 0xD57C7288,
        .d2 = 0xD4AD,
        .d3 = 0x4768,
        .d4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
    };

    const CLSCTX_INPROC_SERVER: u32 = 1;
    /// 只选目录；强制文件系统路径（不要虚拟壳文件夹）；路径必须存在；不改进程 CWD（相对路径靠它）
    const options: u32 = 0x0000_0020 | 0x0000_0040 | 0x0000_0800 | 0x0000_0008;
    const SIGDN_FILESYSPATH: u32 = 0x8005_8000;

    extern "ole32" fn CoCreateInstance(*const Guid, ?*anyopaque, u32, *const Guid, *?*anyopaque) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
    extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;

    // COM vtable = 函数指针数组，按接口声明顺序取下标。
    // **顺序不能错**（继承链：IUnknown → IModalWindow → IFileDialog → IFileOpenDialog）
    const vt_release = 2;
    const vt_show = 3; // IModalWindow::Show(HWND)
    const vt_set_options = 9; // IFileDialog::SetOptions(DWORD)
    const vt_set_title = 17; // IFileDialog::SetTitle(LPCWSTR)
    const vt_get_result = 20; // IFileDialog::GetResult(IShellItem**)
    const si_get_display_name = 5; // IShellItem::GetDisplayName(SIGDN, PWSTR*)

    const ReleaseFn = *const fn (*anyopaque) callconv(.winapi) u32;
    const ShowFn = *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) i32;
    const SetOptionsFn = *const fn (*anyopaque, u32) callconv(.winapi) i32;
    const SetTitleFn = *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) i32;
    const GetResultFn = *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) i32;
    const GetDisplayNameFn = *const fn (*anyopaque, u32, *?[*:0]u16) callconv(.winapi) i32;

    /// 取 `obj` 的 vtable 第 `slot` 项并转成具体签名
    inline fn vt(obj: *anyopaque, slot: usize, comptime Fn: type) Fn {
        const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
        return @ptrCast(@alignCast(vtbl.*[slot]));
    }

    /// 工作线程：**自己初始化 STA**，跑模态对话框（同线程内完成，结果写回 `ctx`）
    pub fn runDialog(ctx: *Ctx) void {
        _ = CoInitializeEx(null, 2); // COINIT_APARTMENTTHREADED
        defer CoUninitialize();
        defer ctx.done.store(true, .release);

        var dlg: ?*anyopaque = null;
        if (CoCreateInstance(&clsid_file_open_dialog, null, CLSCTX_INPROC_SERVER, &iid_file_open_dialog, &dlg) < 0) return;
        const d = dlg orelse return;
        defer _ = vt(d, vt_release, ReleaseFn)(d);
        _ = vt(d, vt_set_options, SetOptionsFn)(d, options);
        if (ctx.title_len > 0) _ = vt(d, vt_set_title, SetTitleFn)(d, @ptrCast(&ctx.title_w));
        const hr = vt(d, vt_show, ShowFn)(d, ctx.owner);
        if (hr < 0) {
            ctx.hr = hr; // 用户取消（0x800704C7）也走这里
            return;
        }
        var item: ?*anyopaque = null;
        if (vt(d, vt_get_result, GetResultFn)(d, &item) < 0) return;
        const it = item orelse return;
        defer _ = vt(it, vt_release, ReleaseFn)(it);
        var name_w: ?[*:0]u16 = null;
        if (vt(it, si_get_display_name, GetDisplayNameFn)(it, SIGDN_FILESYSPATH, &name_w) < 0) return;
        const pw = name_w orelse return;
        defer CoTaskMemFree(@ptrCast(pw));
        ctx.path_len = std.unicode.utf16LeToUtf8(&ctx.path, std.mem.span(pw)) catch 0;
        ctx.hr = 0;
    }
} else struct {};

// ───────────────────────────── 测试 ─────────────────────────────

test "folder_pick: 非 Windows 平台不支持（返回 null，不会起线程）" {
    if (supported) return error.SkipZigTest;
    try std.testing.expect(Job.start(std.testing.allocator, null, "x") == null);
}

test "folder_pick: Ctx 约定——缓冲尺寸 + done 是原子（跨线程可见性前提）" {
    const blank: Ctx = .{};
    // 路径 1024 字节（长路径够用；Windows MAX_PATH 才 260）、标题留 0 终止位
    try std.testing.expect(blank.path.len >= 1024);
    try std.testing.expect(blank.title_w.len >= 256); // 255 字符 + NUL
    // done 必须是原子（工作线程写 / UI 线程读）
    try std.testing.expect(@FieldType(Ctx, "done") == std.atomic.Value(bool));
}
