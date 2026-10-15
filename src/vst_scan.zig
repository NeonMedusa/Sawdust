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
const host = @import("vst_host.zig");

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
    const subs = [_][]const u8{ "Contents/x86_64-win", "Contents/x86-win", "" };
    var found: ?[]u8 = null;
    for (subs) |sub| {
        var buf: [1024]u8 = undefined;
        const dir_path: []const u8 = if (sub.len == 0)
            bundle_root
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ bundle_root, sub }) catch continue;
        found = findFirstModule(io, alloc, dir_path, ".vst3") orelse findFirstModule(io, alloc, dir_path, ".dll");
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
                if (std.mem.endsWith(u8, entry.name, ".vst3") or std.mem.endsWith(u8, entry.name, ".dll")) {
                    addFile(alloc, out, full) catch {};
                }
            },
            else => {},
        }
    }
}

/// 发现候选：`root` 是目录 → 递归遍历；不是目录（裸文件）→ 自身即候选。
pub fn discover(io: std.Io, alloc: std.mem.Allocator, root: []const u8, out: *std.ArrayListUnmanaged(Candidate)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        try addFile(alloc, out, root);
        return;
    };
    walkContents(io, alloc, dir, root, out);
    dir.close(io);
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
    var cands: std.ArrayListUnmanaged(Candidate) = .{ .items = &.{}, .capacity = 0 };
    defer freeCandidates(alloc, &cands);
    for (roots) |r| discover(io, alloc, r, &cands) catch {};
    sortCandidates(cands.items);

    var log: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
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

        const dllz = alloc.dupeZ(u8, c.dll) catch {
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

test "vst_scan: 候选发现（包结构 / 裸文件 / 递归 / 单文件根）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    try makeTestTree(io, root);

    var cands: std.ArrayListUnmanaged(Candidate) = .{ .items = &.{}, .capacity = 0 };
    defer freeCandidates(alloc, &cands);
    try discover(io, alloc, root, &cands);
    try std.testing.expectEqual(@as(usize, 4), cands.items.len);

    // 包内模块解析（path = 包根；dll = 包内模块）
    var found_a = false;
    var found_f = false;
    for (cands.items) |c| {
        if (std.mem.endsWith(u8, c.path, "/A.vst3")) {
            found_a = true;
            try std.testing.expect(std.mem.endsWith(u8, c.dll, "/A.vst3/Contents/x86_64-win/A.vst3"));
        }
        if (std.mem.endsWith(u8, c.path, "/F.vst3")) {
            found_f = true;
            try std.testing.expect(std.mem.endsWith(u8, c.dll, "/F.vst3/F.vst3")); // 包根兜底
        }
    }
    try std.testing.expect(found_a and found_f);

    // 单文件根：直接当候选
    var one: std.ArrayListUnmanaged(Candidate) = .{ .items = &.{}, .capacity = 0 };
    defer freeCandidates(alloc, &one);
    const b_path = try std.fmt.allocPrint(alloc, "{s}/B.vst3", .{root});
    defer alloc.free(b_path);
    try discover(io, alloc, b_path, &one);
    try std.testing.expectEqual(@as(usize, 1), one.items.len);
    try std.testing.expectEqualStrings(one.items[0].path, one.items[0].dll);
}

/// 造测试树：规范包 A.vst3（Contents/x86_64-win）、扁平包 F.vst3（模块在包根）、
/// 裸文件 B.vst3、嵌套目录里的 C.dll——全部 0 字节假模块（LoadLibrary 必败）。
fn makeTestTree(io: std.Io, root: []const u8) !void {
    var buf: [1024]u8 = undefined;
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/A.vst3/Contents/x86_64-win", .{root})) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/F.vst3", .{root})) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/sub", .{root})) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/A.vst3/Contents/x86_64-win/A.vst3", .{root}), .data = "" }) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/F.vst3/F.vst3", .{root}), .data = "" }) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/B.vst3", .{root}), .data = "" }) catch return error.IoFailure;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/sub/C.dll", .{root}), .data = "" }) catch return error.IoFailure;
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
