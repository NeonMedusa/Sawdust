//! VST3 扫描 worker 核心：候选发现 + JSONL 协议输出。
//! 由同二进制自举的扫描 worker 调用（`Sawdust.exe --vst-scan --jsonl <out.jsonl> <路径...>`）；
//! 主程序（插件管理器）按同格式消费。
//!
//! **安全模型**：只读枚举插件工厂的类信息，**绝不实例化组件**（不跑插件业务代码）；
//! worker 是独立进程——坏插件崩的是它，不是主程序。worker 内**从不 FreeLibrary**
//! （SFLT 教训：卸载后插件后台线程执行已卸载代码会崩；进程退出时由系统整体回收）。
//!
//! JSONL 协议（每行一个 JSON 对象；父进程看到没有配对 ok/err 的 `start` 行，
//! 即可断定该插件让 worker 崩了——崩溃定位机制）：
//!   {"t":"begin","n":<候选总数>}
//!   {"t":"start","path":"...","dll":"..."}
//!   {"t":"ok","path":"...","dll":"...","name":"...","vendor":"...","version":"...",
//!    "role":"instrument|effect|both|none",
//!    "classes":[{"cid":"<32hex>","name":"...","vendor":"...","version":"...",
//!                "category":"...","sub":"...","kind":"instrument|effect|other"}, ...]}
//!   {"t":"err","path":"...","dll":"...","error":"<ErrorName>"}
//!   {"t":"end","ok":N,"err":M}

const std = @import("std");
const builtin = @import("builtin");
const host = @import("vst_host.zig");

/// 本平台的可加载模块扩展名（VST3 规范：Linux 是 `.so`，Windows 是 `.vst3`/`.dll`）。
const module_exts: []const []const u8 = if (builtin.os.tag == .linux)
    &.{ ".so", ".vst3" }
else
    &.{ ".vst3", ".dll" };

/// bundle 内放本平台模块的子目录（按优先级；`""` = 包根，兼容扁平包）。
const bundle_subs: []const []const u8 = if (builtin.os.tag == .linux)
    &.{ "Contents/x86_64-linux", "" }
else
    &.{ "Contents/x86_64-win", "Contents/x86-win", "" };

/// 扫描目录里遇到的**普通文件**是否算插件模块。
/// Linux 上裸 `.so` 很容易和普通库混淆 → 只有位于 `.vst3` 包里（或本身叫 `.vst3`）才算。
fn acceptModuleFile(dir_path: []const u8, name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".vst3")) return true;
    if (builtin.os.tag == .linux) {
        if (!std.mem.endsWith(u8, name, ".so")) return false;
        return std.mem.endsWith(u8, dir_path, ".vst3");
    }
    return std.mem.endsWith(u8, name, ".dll");
}

/// 扫描候选：`path` = 发现的根（.vst3 目录包 / 裸文件；展示、去重、写存档用）；
/// `dll` = 真正可加载的模块路径（包内 `Contents/<arch>/` 模块；裸文件 = 自身）。
pub const Candidate = struct {
    path: []u8,
    dll: []u8,
};

pub fn freeCandidates(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(Candidate)) void {
    for (list.items) |c| {
        alloc.free(c.path);
        alloc.free(c.dll);
    }
    list.deinit(alloc);
}

/// JSON 字符串转义（写 `"..."`，含引号）。UTF-8 原样输出（JSON 允许）。
pub fn jsonEscape(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => {
            switch (c) {
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.print("\\u{x:0>4}", .{c}),
            }
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// 路径等值（忽略大小写——Windows 语义；用于候选去重）
fn pathEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn addCandidate(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Candidate), path: []const u8, dll: []const u8) !void {
    for (out.items) |c| {
        if (pathEql(c.path, path)) return; // 多根目录/重复发现 → 去重
    }
    const p = try alloc.dupe(u8, path);
    errdefer alloc.free(p);
    const d = try alloc.dupe(u8, dll);
    out.append(alloc, .{ .path = p, .dll = d }) catch |e| {
        alloc.free(p);
        alloc.free(d);
        return e;
    };
}

fn addFile(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Candidate), path: []const u8) !void {
    try addCandidate(alloc, out, path, path);
}

/// 在目录里找第一个扩展名匹配的模块文件（返回堆分配全路径；忽略大小写）。
/// 目录不存在/没有匹配 → null。
fn findFirstModule(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, ext: []const u8) ?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len < ext.len) continue;
        const tail = entry.name[entry.name.len - ext.len ..];
        if (!std.ascii.eqlIgnoreCase(tail, ext)) continue;
        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        return alloc.dupe(u8, full) catch null;
    }
    return null;
}

/// 解析 .vst3 目录包的模块路径：按 VST3 规范找 `Contents/<arch>/` 下的模块；
/// 找不到 → 包根兜底（加载会失败，但错误对外可见）。
fn addBundle(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Candidate), bundle_root: []const u8) !void {
    var found: ?[]u8 = null;
    for (bundle_subs) |sub| {
        var buf: [1024]u8 = undefined;
        const dir_path: []const u8 = if (sub.len == 0)
            bundle_root
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ bundle_root, sub }) catch continue;
        for (module_exts) |ext| {
            found = findFirstModule(io, alloc, dir_path, ext);
            if (found != null) break;
        }
        if (found != null) break;
    }
    const dll = found orelse try alloc.dupe(u8, bundle_root);
    defer alloc.free(dll);
    try addCandidate(alloc, out, bundle_root, dll);
}

/// 递归遍历目录：`.vst3` 目录当叶子（解析包内模块）；裸 `.vst3`/`.dll` 文件直接候选；
/// 其余目录继续下钻。
fn walkContents(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, dir_path: []const u8, out: *std.ArrayListUnmanaged(Candidate)) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        var buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => {
                if (std.mem.endsWith(u8, entry.name, ".vst3")) {
                    addBundle(io, alloc, out, full) catch {};
                } else {
                    var sub = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch continue;
                    walkContents(io, alloc, sub, full, out);
                    sub.close(io);
                }
            },
            .file => {
                if (acceptModuleFile(dir_path, entry.name)) {
                    addFile(alloc, out, full) catch {};
                }
            },
            else => {},
        }
    }
}

/// 发现候选：
/// - `root` 本身是 `*.vst3` **目录** → 当作 bundle 解析（不是"遍历它的内容"）；
/// - `root` 是普通目录 → 递归遍历；
/// - `root` 是文件 → 自身即候选；
/// - `root` **不存在** → 跳过（早先会当成裸文件，缓存里因此留下
///   `/usr/local/lib/vst3`、`~/.vst3` 这类"LoadLibraryFailed"的幽灵条目）。
pub fn discover(io: std.Io, alloc: std.mem.Allocator, root: []const u8, out: *std.ArrayListUnmanaged(Candidate)) !void {
    if (std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        if (std.mem.endsWith(u8, root, ".vst3")) {
            try addBundle(io, alloc, out, root); // 用户直接指定了某个插件包
            return;
        }
        walkContents(io, alloc, dir, root, out);
        return;
    } else |_| {}
    // 不是目录：**存在**才当裸文件候选（不存在就跳过）
    var f = std.Io.Dir.cwd().openFile(io, root, .{}) catch return;
    f.close(io);
    try addFile(alloc, out, root);
}

fn sortCandidates(items: []Candidate) void {
    std.mem.sort(Candidate, items, {}, struct {
        fn less(_: void, a: Candidate, b: Candidate) bool {
            return std.ascii.lessThanIgnoreCase(a.path, b.path);
        }
    }.less);
}

/// 逐行追加 + **立即落盘**（整文件重写：数据量小；崩溃时父进程已能读到
/// 最后一条 `start`，这正是崩溃定位所依赖的）。
fn emitLine(io: std.Io, alloc: std.mem.Allocator, log: *std.ArrayListUnmanaged(u8), out_path: []const u8, line: []const u8) void {
    log.appendSlice(alloc, line) catch return;
    log.append(alloc, '\n') catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = log.items }) catch {};
}

fn classKind(c: host.ModuleClass) []const u8 {
    if (c.isInstrument()) return "instrument";
    if (c.isAudioEffect()) return "effect";
    return "other";
}

fn writeCidHex(w: *std.Io.Writer, cid: [16]u8) void {
    for (cid) |b| w.print("{x:0>2}", .{b}) catch {};
}

/// 主流程：发现 → 逐个枚举 → JSONL（每步立即落盘）。
/// 容错：任何单插件失败都只产生 `err` 行，不中断整场扫描。
pub fn runScan(io: std.Io, alloc: std.mem.Allocator, roots: []const []const u8, out_path: []const u8) !void {
    var cands: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &cands);
    for (roots) |r| discover(io, alloc, r, &cands) catch {};
    sortCandidates(cands.items);

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);

    {
        var lb: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&lb);
        w.print("{{\"t\":\"begin\",\"n\":{d}}}", .{cands.items.len}) catch {};
        emitLine(io, alloc, &log, out_path, w.buffered());
    }

    var nok: usize = 0;
    var nerr: usize = 0;
    for (cands.items) |c| {
        // start：任何后续失败/崩溃都以“它是最后一条 start”定位
        {
            var lb: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&lb);
            w.writeAll("{\"t\":\"start\",\"path\":") catch {};
            jsonEscape(&w, c.path) catch {};
            w.writeAll(",\"dll\":") catch {};
            jsonEscape(&w, c.dll) catch {};
            w.writeByte('}') catch {};
            emitLine(io, alloc, &log, out_path, w.buffered());
        }

        const dllz = alloc.dupeSentinel(u8, c.dll, 0) catch {
            nerr += 1;
            emitErr(io, alloc, &log, out_path, c, "OutOfMemory");
            continue;
        };
        defer alloc.free(dllz);

        const scan = host.scanModule(dllz) catch |e| {
            nerr += 1;
            emitErr(io, alloc, &log, out_path, c, @errorName(e));
            continue;
        };
        // 注：**不卸载模块**（不回 FreeLibrary）——worker 进程随扫描结束退出；
        // 卸载反而可能触发“后台线程执行已卸载代码”而崩（制造假崩溃）。
        nok += 1;
        emitOk(io, alloc, &log, out_path, c, &scan);
    }

    {
        var lb: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&lb);
        w.print("{{\"t\":\"end\",\"ok\":{d},\"err\":{d}}}", .{ nok, nerr }) catch {};
        emitLine(io, alloc, &log, out_path, w.buffered());
    }
}

fn emitErr(io: std.Io, alloc: std.mem.Allocator, log: *std.ArrayListUnmanaged(u8), out_path: []const u8, c: Candidate, err_name: []const u8) void {
    var lb: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&lb);
    w.writeAll("{\"t\":\"err\",\"path\":") catch {};
    jsonEscape(&w, c.path) catch {};
    w.writeAll(",\"dll\":") catch {};
    jsonEscape(&w, c.dll) catch {};
    w.writeAll(",\"error\":") catch {};
    jsonEscape(&w, err_name) catch {};
    w.writeByte('}') catch {};
    emitLine(io, alloc, log, out_path, w.buffered());
}

fn emitOk(io: std.Io, alloc: std.mem.Allocator, log: *std.ArrayListUnmanaged(u8), out_path: []const u8, c: Candidate, scan: *const host.Scan) void {
    // “主类” = 第一个乐器/效果类（用于顶层 name/vendor/version 便捷字段）
    var primary: ?host.ModuleClass = null;
    var has_inst = false;
    var has_fx = false;
    for (scan.slice()) |cl| {
        const k = classKind(cl);
        if (std.mem.eql(u8, k, "instrument")) has_inst = true;
        if (std.mem.eql(u8, k, "effect")) has_fx = true;
        if (primary == null and !std.mem.eql(u8, k, "other")) primary = cl;
    }
    const p = primary orelse (if (scan.slice().len > 0) scan.slice()[0] else host.ModuleClass{});
    const role: []const u8 = if (has_inst and has_fx)
        "both"
    else if (has_inst)
        "instrument"
    else if (has_fx)
        "effect"
    else
        "none";

    // 行缓冲 16KB：MaxClasses=32 × 每类 ~160B + 路径 ≈ 6KB，余量充足
    var lb: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&lb);
    w.writeAll("{\"t\":\"ok\",\"path\":") catch {};
    jsonEscape(&w, c.path) catch {};
    w.writeAll(",\"dll\":") catch {};
    jsonEscape(&w, c.dll) catch {};
    w.writeAll(",\"name\":") catch {};
    jsonEscape(&w, p.name()) catch {};
    w.writeAll(",\"vendor\":") catch {};
    jsonEscape(&w, p.vendor()) catch {};
    w.writeAll(",\"version\":") catch {};
    jsonEscape(&w, p.version()) catch {};
    w.writeAll(",\"role\":\"") catch {};
    w.writeAll(role) catch {};
    w.writeAll("\",\"classes\":[") catch {};
    for (scan.slice(), 0..) |cl, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.writeAll("{\"cid\":\"") catch {};
        writeCidHex(&w, cl.cid);
        w.writeAll("\",\"name\":") catch {};
        jsonEscape(&w, cl.name()) catch {};
        w.writeAll(",\"vendor\":") catch {};
        jsonEscape(&w, cl.vendor()) catch {};
        w.writeAll(",\"version\":") catch {};
        jsonEscape(&w, cl.version()) catch {};
        w.writeAll(",\"category\":") catch {};
        jsonEscape(&w, cl.category()) catch {};
        w.writeAll(",\"sub\":") catch {};
        jsonEscape(&w, cl.subCategories()) catch {};
        w.writeAll(",\"kind\":\"") catch {};
        w.writeAll(classKind(cl)) catch {};
        w.writeAll("\"}") catch {};
    }
    w.writeAll("]}") catch {};
    emitLine(io, alloc, log, out_path, w.buffered());
}

// ── 测试 ──

test "vst_scan: JSON 转义（引号/反斜杠/控制字符/UTF-8）" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try jsonEscape(&w, "C:\\程序\\a\"b\n\t");
    try std.testing.expectEqualStrings("\"C:\\\\程序\\\\a\\\"b\\n\\t\"", w.buffered());
}

test "vst_scan: 真实系统目录（/usr/lib/vst3）里每个 .vst3 包都能解析出可加载模块" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var root = std.Io.Dir.cwd().openDir(io, "/usr/lib/vst3", .{ .iterate = true }) catch return error.SkipZigTest;
    defer root.close(io);

    // 收集系统里实际存在的 bundle 名（本机：Dexed.vst3、Vital.vst3 …）
    var bundles: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (bundles.items) |b| alloc.free(b);
        bundles.deinit(alloc);
    }
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".vst3")) continue;
        const dup = alloc.dupe(u8, entry.name) catch continue;
        bundles.append(alloc, dup) catch {
            alloc.free(dup);
            continue;
        };
    }
    if (bundles.items.len == 0) return error.SkipZigTest; // 机器上没装插件 → 跳过

    var cands: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &cands);
    try discover(io, alloc, "/usr/lib/vst3", &cands);
    try std.testing.expect(cands.items.len >= bundles.items.len);

    // 对每个真实存在的 bundle：必须有候选，且 dll 指向**存在**的本平台模块
    for (bundles.items) |b| {
        var found = false;
        for (cands.items) |c| {
            try std.testing.expect(std.mem.indexOf(u8, c.dll, "x86_64-win") == null);
            if (!std.mem.endsWith(u8, c.path, b)) continue;
            found = true;
            try std.testing.expect(std.mem.endsWith(u8, c.dll, ".so") or std.mem.endsWith(u8, c.dll, ".vst3"));
            var f = std.Io.Dir.cwd().openFile(io, c.dll, .{}) catch {
                std.debug.print("候选 dll 不存在：{s}\n", .{c.dll});
                return error.MissingModule;
            };
            f.close(io);
        }
        if (!found) {
            std.debug.print("bundle 没被扫到：{s}\n", .{b});
            return error.BundleNotFound;
        }
    }
}

test "vst_scan: 不存在的根不产生候选；.vst3 目录当 bundle 解析" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    try makeTestTree(io, root);

    // ① 不存在的根：不该冒出一个"幽灵候选"（旧实现会当成裸文件）
    var none: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &none);
    try discover(io, alloc, "/definitely/not/here/vst3", &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    // ② 直接把 bundle 目录当根：应解析出包内模块，而不是遍历 Contents 一无所获
    var one: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &one);
    const bundle = try std.fmt.allocPrint(alloc, "{s}/A.vst3", .{root});
    defer alloc.free(bundle);
    try discover(io, alloc, bundle, &one);
    try std.testing.expectEqual(@as(usize, 1), one.items.len);
    try std.testing.expect(std.mem.endsWith(u8, one.items[0].dll, ".so") or std.mem.endsWith(u8, one.items[0].dll, ".vst3"));
}

test "vst_scan: 候选发现（包结构 / 裸文件 / 递归 / 单文件根）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    try makeTestTree(io, root);

    var cands: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &cands);
    try discover(io, alloc, root, &cands);
    try std.testing.expectEqual(@as(usize, 4), cands.items.len);

    // 包内模块解析（path = 包根；dll = 包内模块）——期望值按**本平台**形状拼
    var want_a: [1024]u8 = undefined;
    const want_a_path = try std.fmt.bufPrint(&want_a, "/A.vst3/{s}/A{s}", .{ bundle_subs[0], module_exts[0] });
    var want_f: [1024]u8 = undefined;
    const want_f_path = try std.fmt.bufPrint(&want_f, "/F.vst3/F{s}", .{module_exts[0]});
    var found_a = false;
    var found_f = false;
    for (cands.items) |c| {
        if (std.mem.endsWith(u8, c.path, "/A.vst3")) {
            found_a = true;
            try std.testing.expect(std.mem.endsWith(u8, c.dll, want_a_path));
        }
        if (std.mem.endsWith(u8, c.path, "/F.vst3")) {
            found_f = true;
            try std.testing.expect(std.mem.endsWith(u8, c.dll, want_f_path)); // 包根兜底
        }
    }
    try std.testing.expect(found_a and found_f);

    // 单文件根：直接当候选
    var one: std.ArrayListUnmanaged(Candidate) = .empty;
    defer freeCandidates(alloc, &one);
    const b_path = try std.fmt.allocPrint(alloc, "{s}/B.vst3", .{root});
    defer alloc.free(b_path);
    try discover(io, alloc, b_path, &one);
    try std.testing.expectEqual(@as(usize, 1), one.items.len);
    try std.testing.expectEqualStrings(one.items[0].path, one.items[0].dll);
}

/// 造测试树（**按本平台形状**）：规范包 A.vst3（`bundle_subs[0]`）、扁平包 F.vst3（模块在包根）、
/// 裸文件 B.vst3、嵌套目录里的 C 模块——全部 0 字节假模块（加载必败）。
/// Linux 上模块扩展名是 `.so`，Windows 上是 `.vst3`/`.dll`，所以扩展名走 `module_exts`。
fn makeTestTree(io: std.Io, root: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const arch = bundle_subs[0];
    const ext = module_exts[0];
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/A.vst3/{s}", .{ root, arch })) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/F.vst3", .{root})) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/sub", .{root})) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/A.vst3/{s}/A{s}", .{ root, arch, ext }), .data = "" }) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/F.vst3/F{s}", .{ root, ext }), .data = "" }) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/B.vst3", .{root}), .data = "" }) catch return error.IoFailure;
    // 嵌套目录里的"普通模块文件"：Windows 用 .dll（合法候选）；Linux 的裸 .so 不在 .vst3 包里
    // → 按设计**不算**插件（防止把 /usr/lib 下的库当插件），所以这里也用 .vst3 保证计数一致。
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/sub/C{s}", .{ root, if (builtin.os.tag == .linux) ".vst3" else ".dll" }), .data = "" }) catch return error.IoFailure;
}

test "vst_scan: runScan 端到端——fake 模块全部加载失败但 JSONL 结构完整" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    try makeTestTree(io, root);

    const out_path = try std.fmt.allocPrint(alloc, "{s}/out.jsonl", .{root});
    defer alloc.free(out_path);
    try runScan(io, alloc, &.{root}, out_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .unlimited);
    defer alloc.free(data);

    var n_start: usize = 0;
    var n_err: usize = 0;
    var n_ok: usize = 0;
    var n_begin: usize = 0;
    var n_end: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const t = parsed.value.object.get("t").?.string;
        if (std.mem.eql(u8, t, "begin")) {
            n_begin += 1;
            try std.testing.expect(parsed.value.object.get("n").?.integer > 0);
        } else if (std.mem.eql(u8, t, "start")) {
            n_start += 1;
        } else if (std.mem.eql(u8, t, "err")) {
            n_err += 1;
            try std.testing.expect(parsed.value.object.get("error").?.string.len > 0);
        } else if (std.mem.eql(u8, t, "ok")) {
            n_ok += 1;
        } else if (std.mem.eql(u8, t, "end")) {
            n_end += 1;
            try std.testing.expectEqual(@as(i64, @intCast(n_ok)), parsed.value.object.get("ok").?.integer);
            try std.testing.expectEqual(@as(i64, @intCast(n_err)), parsed.value.object.get("err").?.integer);
        } else {
            return error.UnexpectedLineType;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), n_begin);
    try std.testing.expectEqual(@as(usize, 1), n_end);
    try std.testing.expectEqual(@as(usize, 4), n_start); // 空文件模块：全部 err
    try std.testing.expectEqual(@as(usize, 4), n_err);
    try std.testing.expectEqual(@as(usize, 0), n_ok);
}
