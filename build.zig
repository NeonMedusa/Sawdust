const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 调试构建（默认 `zig build run` = Debug）**不 strip**：否则 SafeAllocator 的泄漏报告
    // 与 panic 栈都只剩“Cannot print stack trace: stack tracing is disabled”，
    // 没任何可诊断信息（实测：退出时两条 1MB/280KB 泄漏无从下手）。
    // 发布构建（ReleaseFast/Small/Safe）仍默认 strip。
    const strip = b.option(bool, "strip", "Strip debug info (default: off for Debug, on otherwise)") orelse (optimize != .debug);

    const exe = b.addExecutable(.{
        .name = "Sawdust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });

    // ── 第三方库（手动引入，不用包管理器）──
    // stb_truetype：单头文件，字形光栅化
    exe.root_module.addIncludePath(b.path("libs/stb"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_impl.c"),
        .flags = &.{"-std=c99"},
    });
    // miniaudio：单头文件，跨平台音频 I/O
    exe.root_module.addIncludePath(b.path("libs/miniaudio"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/miniaudio/miniaudio_impl.c"),
        .flags = &.{"-std=c99"},
    });

    // Windows 系统库（窗口 + GDI 软件渲染 + 文件对话框 + shell（文件夹选择／插件管理）
    // + miniaudio 的 WASAPI 后端）
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "kernel32", "ole32", "uuid", "winmm", "comdlg32", "shell32" }) |lib| {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
        // **GUI 子系统**：双击 exe 不再弹控制台黑框。CLI 自举模式（`--vst-scan`）
        // 从终端启动时会接上父控制台（见 `vstscan.attachParentConsole`），
        // 被 GUI spawn 的扫描 worker 则静默无窗口。
        exe.subsystem = .windows;
    }

    // Linux 系统库：X11 窗口后端（`src/window_x11.zig`）。
    // miniaudio 的 ALSA/PulseAudio 后端是**运行时 dlopen**，无需链接。
    if (target.result.os.tag == .linux) {
        for ([_][]const u8{ "X11", "Xext" }) |lib| {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    }

    b.installArtifact(exe);
    // VST3 绑定：**直接建模块**（不跑 submodule 的 build.zig）——
    // 1) 构建全程不碰网络；2) submodule 的 build.zig 仍在用 0.16 构建 API（0.17 里
    //    `getInstallPath` 等已移除），而我们只需要它的两个源码模块。
    const vst3_core_mod = b.createModule(.{
        .root_source_file = b.path("libs/zig-vst3/zig-vst3-plugin/src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vst3_mod = b.createModule(.{
        .root_source_file = b.path("libs/zig-vst3/zig-vst3/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vst3_mod.addImport("zig-vst3-plugin-core", vst3_core_mod);
    exe.root_module.addImport("zig_vst3", vst3_mod);

    // VST3 探测/扫描工具已**并入主程序**（`Sawdust.exe --vst-scan …` 同二进制自举；
    // 插件扫描以独立进程运行自身 = 保留坏插件崩溃隔离）；不再单独构建 vstscan.exe。

    const run_step = b.step("run", "Run Sawdust");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // 0.17：`--` 之后的透传参数统一由 Run 步骤自己添加（`b.args` 已移除）
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    // 测试夹具：示例 VST3 插件（**只给单元测试用**）。直接从子模块源码编译，
    // 不跑它的 build.zig；装到 zig-out/bin，与测试里写死的路径一致
    //→ `zig build test` / `zig build` 一条命令就够，干净 clone 也不会缺夹具。
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "sine_synth", "gain" }) |fname| {
            const fixture = b.addLibrary(.{
                .name = b.fmt("zig_vst3_{s}", .{fname}),
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("libs/zig-vst3/zig-vst3/src/{s}_plugin.zig", .{fname})),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            fixture.root_module.addImport("zig-vst3", vst3_mod);
            fixture.root_module.addImport("zig-vst3-plugin-core", vst3_core_mod);
            const inst = b.addInstallFileWithDir(fixture.getEmittedBin(), .bin, b.fmt("zig_vst3_{s}.dll", .{fname}));
            // 只挂在 test 上：`zig build run` 不该为跑测试而多编两个 DLL
            test_step.dependOn(&inst.step);
        }
    }
    test_step.dependOn(&run_exe_tests.step);
}
