//! VST3 探测工具（阶段 1：**只读枚举**——不接音频、不显示界面）。
//!
//! **已并入主程序（同二进制自举）**：入口为 `Sawdust.exe --vst-scan …`——
//! 插件扫描以**独立进程**运行同一 exe（坏插件崩溃隔离在 worker 里），
//! 不再单独构建 `vstscan.exe`。
//! 用法：`Sawdust.exe --vst-scan [目录...]`（默认扫描系统 VST3 目录）。
//! 输出：每个 .vst3 模块一行路径，其下列出效果器类（名称 · 厂商 · 版本）。
//!
//! 复用 `src/vst_host.zig` 的模块加载/枚举（主程序接入同一实现）。

const std = @import("std");
const host = @import("vst_host.zig");
const vst_scan = @import("vst_scan.zig");

// 消息泵（--editor 冒烟用）
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
extern "user32" fn PeekMessageW(*MSG, ?*anyopaque, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

// 控制台接驳（GUI 子系统 exe 的 CLI 模式）
extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetStdHandle(nStdHandle: u32, hHandle: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

/// 接上**父控制台**（`ATTACH_PARENT_PROCESS`）——GUI 子系统的 exe 从终端启动时，
/// 标准句柄可能为 NULL（`std.debug.print` 无处可去）。策略：
/// - 无父控制台（双击；或被 GUI 进程 spawn 的扫描 worker）→ 静默失败，**不弹窗**；
/// - 已有合法标准句柄（终端继承 / 重定向管道）→ **不覆盖**（重定向才能正常捕获）；
/// - 句柄为 NULL 时 → 重开 `CONOUT$` 并 SetStdHandle。
fn attachParentConsole() void {
    if (AttachConsole(0xFFFF_FFFF) == 0) return; // ATTACH_PARENT_PROCESS
    const h = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), 0x8000_0000 | 0x4000_0000, 1 | 2, null, 3, 0, null);
    const raw = @intFromPtr(h orelse return);
    if (raw == std.math.maxInt(usize)) return; // INVALID_HANDLE_VALUE
    if (GetStdHandle(0xFFFF_FFF5) == null) _ = SetStdHandle(0xFFFF_FFF5, h); // STD_OUTPUT_HANDLE
    if (GetStdHandle(0xFFFF_FFF4) == null) _ = SetStdHandle(0xFFFF_FFF4, h); // STD_ERROR_HANDLE
}

/// 同二进制自举入口（原 `vstscan.exe` 的 main；由主程序 `--vst-scan` 转发）。
pub fn cliMain(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    attachParentConsole(); // GUI 子系统下从终端启动：把输出接回父控制台

    // 命令行：`vstscan [目录...]`（默认扫系统 VST3 目录）
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.skip(); // argv0
    var dirs: [16][]const u8 = undefined;
    var nd: usize = 0;
    while (arg_it.next()) |a| {
        if (nd == 0 and std.mem.eql(u8, a, "--vst-scan")) continue; // 同二进制自举前缀（主程序转发）
        if (nd < dirs.len) {
            dirs[nd] = a;
            nd += 1;
        }
    }
    // `vstscan --jsonl <out.jsonl> <路径...>`：插件管理器扫描 worker
    // （只枚举工厂类、不实例化；JSONL 协议与崩溃定位见 `vst_scan.zig`）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--jsonl")) {
        if (nd < 3) {
            std.debug.print("用法：Sawdust --vst-scan --jsonl <输出.jsonl> <目录或文件...>\n", .{});
            return 1;
        }
        const out_path = dirs[1];
        const roots: []const []const u8 = dirs[2..nd];
        vst_scan.runScan(io, alloc, roots, out_path) catch |e| {
            std.debug.print("扫描失败：{s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }
    // `vstscan --buses <文件.vst3>`：打印音频总线布局
    // （多输出插件支持前后的探测：总线数/类型/通道数/默认激活位）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--buses")) {
        const p = if (nd > 1) dirs[1] else {
            std.debug.print("用法：Sawdust --vst-scan --buses <文件.vst3>\n", .{});
            return 1;
        };
        const pz = alloc.dupeZ(u8, p) catch return 1;
        defer alloc.free(pz);
        host.dumpBuses(pz) catch |e| {
            std.debug.print("探测失败：{s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }
    // `vstscan --classes <文件.vst3>`：列出工厂里**全部类**（含非效果器：控制器等）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--classes")) {
        const p = if (nd > 1) dirs[1] else {
            std.debug.print("用法：Sawdust --vst-scan --classes <文件.vst3>\n", .{});
            return 1;
        };
        const pz = alloc.dupeZ(u8, p) catch return 1;
        defer alloc.free(pz);
        const s = host.scanModule(pz) catch |e| {
            std.debug.print("探测失败：{s}\n", .{@errorName(e)});
            return 1;
        };
        for (s.slice(), 0..) |c, i| {
            std.debug.print("[{d}] {s} | 类别 {s} | 子类 {s} | cid={x}\n", .{ i, c.name(), c.category(), c.subCategories(), c.cid[0..] });
        }
        return 0;
    }
    // `vstscan --params <文件.vst3>`：列出参数（阶段 4 面板数据的无头验证）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--params")) {
        const p = if (nd > 1) dirs[1] else {
            std.debug.print("用法：Sawdust --vst-scan --params <文件.vst3>\n", .{});
            return 1;
        };
        const pz = alloc.dupeZ(u8, p) catch return 1;
        defer alloc.free(pz);
        const pl = host.loadEffect(alloc, pz, 48000, 4096) catch |e| {
            std.debug.print("加载失败：{s}\n", .{@errorName(e)});
            return 1;
        };
        defer host.unloadPlugin(alloc, pl);
        std.debug.print("{s}：{d} 个参数\n", .{ pl.name(), pl.paramCount() });
        var i: usize = 0;
        while (i < pl.paramCount()) : (i += 1) {
            const m = &pl.params[i];
            var vb: [40]u8 = undefined;
            const vt = pl.paramText(i, &vb);
            std.debug.print("    [{d}] id={d} 步数={d} · {s} = {s}\n", .{ i, m.id, m.step_count, m.name(), vt });
        }
        return 0;
    }
    // `vstscan --run <文件.vst3> [effect|instrument]`：音频试跑（加载 → 喂正弦/静音 → 统计输出）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--run")) {
        const p = if (nd > 1) dirs[1] else {
            std.debug.print("用法：Sawdust --vst-scan --run <文件.vst3> [effect|instrument]\n", .{});
            return 1;
        };
        const role: host.Role = if (nd > 2 and std.mem.eql(u8, dirs[2], "instrument")) .instrument else .effect;
        runTest(alloc, p, role);
        return 0;
    }
    // `vstscan --editor <文件.vst3> [秒数]`：编辑器接口冒烟（打开 → 泵消息 → 关闭）
    if (nd > 0 and std.mem.eql(u8, dirs[0], "--editor")) {
        const p = if (nd > 1) dirs[1] else {
            std.debug.print("用法：Sawdust --vst-scan --editor <文件.vst3> [秒数]\n", .{});
            return 1;
        };
        const secs: u32 = if (nd > 2) (std.fmt.parseInt(u32, dirs[2], 10) catch 1) else 1;
        editorSmoke(alloc, p, secs);
        return 0;
    }
    const defaults = [_][]const u8{
        "C:\\Program Files\\Common Files\\VST3",
        "C:\\Program Files (x86)\\Common Files\\VST3",
    };
    const scan: []const []const u8 = if (nd > 0) dirs[0..nd] else &defaults;

    var found_files: usize = 0;
    for (scan) |d| {
        const dir_res = if (std.fs.path.isAbsolute(d))
            std.Io.Dir.openDirAbsolute(io, d, .{ .iterate = true })
        else
            std.Io.Dir.cwd().openDir(io, d, .{ .iterate = true });
        var dir = dir_res catch {
            std.debug.print("跳过（打不开）：{s}\n", .{d});
            continue;
        };
        defer dir.close(io);
        var walker = dir.walk(alloc) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.basename, ".vst3")) continue;
            found_files += 1;
            const full = std.fs.path.joinZ(alloc, &.{ d, ent.path }) catch continue;
            defer alloc.free(full);
            std.debug.print("\n▸ {s}\n", .{ent.path});
            const s = host.scanModule(full) catch |e| {
                std.debug.print("    （探测失败：{s}）\n", .{@errorName(e)});
                continue;
            };
            var printed: usize = 0;
            for (s.slice()) |c| {
                if (!c.isAudioEffect()) continue;
                std.debug.print("    [{d}] {s}", .{ printed, c.name() });
                if (c.vendor().len > 0) std.debug.print(" · {s}", .{c.vendor()});
                if (c.version().len > 0) std.debug.print(" · v{s}", .{c.version()});
                std.debug.print("\n", .{});
                printed += 1;
            }
            if (printed == 0) std.debug.print("    （无 Audio Module Class 类）\n", .{});
        }
    }
    std.debug.print("\n共扫描到 {d} 个 .vst3 模块\n", .{found_files});
    return 0;
}

/// 音频试跑：加载 → 喂正弦（效果器）/静音（乐器）→ 打印输入/输出 RMS。
fn runTest(alloc: std.mem.Allocator, path: []const u8, role: host.Role) void {
    const pz = alloc.dupeZ(u8, path) catch return;
    defer alloc.free(pz);
    const sr: f64 = 48000;
    const sr_u: u32 = 48000;
    const mb: u32 = 4096;
    const pl = host.loadPlugin(alloc, pz, sr, mb, role) catch |e| {
        std.debug.print("加载失败：{s}\n", .{@errorName(e)});
        return;
    };
    defer host.unloadPlugin(alloc, pl);
    std.debug.print("已加载：{s}（延迟 {d} 样本 ≈ {d:.1}ms）\n", .{
        pl.name(),
        pl.latency,
        @as(f64, @floatFromInt(pl.latency)) / sr * 1000.0,
    });

    const frames: u32 = 4096; // 适配 max_block
    var buf: [4096 * 2]f32 = undefined;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const v = 0.5 * @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr_u)));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    var in_sum: f64 = 0;
    for (buf) |s| in_sum += @as(f64, s) * s;
    pl.process(&buf, frames);
    var out_sum: f64 = 0;
    for (buf) |s| out_sum += @as(f64, s) * s;
    const inn = @sqrt(in_sum / @as(f64, @floatFromInt(frames * 2)));
    const out = @sqrt(out_sum / @as(f64, @floatFromInt(frames * 2)));
    std.debug.print("输入 RMS {d:.4} → 输出 RMS {d:.4}（比值 {d:.3}）\n", .{ inn, out, if (inn > 0) out / inn else 0 });
    // 总线报告（多输出 VSTi 支持验证：模式 + 每总线能量）
    if (pl.out_bus_count > 1) {
        std.debug.print("多输出模式：{d} 总线激活（求和混音）\n", .{pl.out_bus_count});
        var b: usize = 0;
        while (b < pl.out_bus_count) : (b += 1) {
            const ch: usize = pl.out_chan_counts[b];
            var s: f64 = 0;
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                const ptr = pl.out_ptrs[b][c];
                var k: usize = 0;
                while (k < frames) : (k += 1) s += @as(f64, ptr[k]) * ptr[k];
            }
            std.debug.print("  总线 {d}：{d} 通道 RMS {d:.5}\n", .{ b, ch, @sqrt(s / @as(f64, @floatFromInt(frames * ch))) });
        }
    } else {
        std.debug.print("单输出总线\n", .{});
    }
}

/// 编辑器接口冒烟：加载 → openEditor → 泵消息 N 秒 → closeEditor。
/// （窗口会真实弹出；期间可交互测试；无 GUI 会话也能验证协议调用不崩）
fn editorSmoke(alloc: std.mem.Allocator, path: []const u8, secs: u32) void {
    const pz = alloc.dupeZ(u8, path) catch return;
    defer alloc.free(pz);
    const pl = host.loadEffect(alloc, pz, 48000, 4096) catch |e| {
        std.debug.print("加载失败：{s}\n", .{@errorName(e)});
        return;
    };
    defer host.unloadPlugin(alloc, pl);
    // 先跑一小块音频（真实宿主里音频一直在跑；某些插件的 UI 依赖处理已开始）
    {
        var warm: [512 * 2]f32 = [_]f32{0} ** 1024;
        pl.process(&warm, 512);
    }
    switch (pl.openEditor(null)) {
        .opened => std.debug.print("编辑器已打开（{s}）— 泵消息 {d} 秒，期间可交互测试…\n", .{ pl.name(), secs }),
        .no_editor => {
            std.debug.print("此插件没有编辑器界面\n", .{});
            return;
        },
        .failed => {
            std.debug.print("编辑器创建失败\n", .{});
            return;
        },
    }
    var msg: MSG = undefined;
    var n: usize = 0;
    const steps: usize = @as(usize, secs) * 200; // 200 × 5ms = 1s
    while (n < steps) : (n += 1) {
        if (!pl.editorOpen()) break; // 用户点右上角 X 关闭了编辑器：立即结束等待
        while (PeekMessageW(&msg, null, 0, 0, 1) != 0) { // PM_REMOVE
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        Sleep(5);
    }
    pl.closeEditor();
    std.debug.print("编辑器已关闭（removed → 销毁窗口）— OK\n", .{});
}
