const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary (default: true)") orelse true;

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

    // Windows 系统库（窗口 + GDI 软件渲染 + 文件对话框 + miniaudio 的 WASAPI 后端）
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "kernel32", "ole32", "uuid", "winmm", "comdlg32" }) |lib| {
            exe.root_module.linkSystemLibrary(lib, .{});
        }
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run Sawdust");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
