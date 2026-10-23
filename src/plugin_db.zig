//! 插件管理器数据层：扫描配置（`plugins.json`）+ 扫描缓存（`plugins_cache.json`）。
//!
//! 设计（见 `tmp/changes-notes.md`「插件管理器 · 设计定稿」）：
//! - **手动扫描**：配置只记“扫什么”（文件夹 + 单文件条目），从不自动扫；
//! - 缓存 = worker JSONL（`vst_scan.zig` 协议）的解析产物——可随时重建，
//!   损坏/缺失当空缓存（不致命）；
//! - **崩溃定位**：JSONL 里 `start` 行没有配对的 ok/err（worker 死在它手里）→
//!   `crashed_after`；缺 `end` 行 → `completed = false`；
//! - 生命周期：`Config`/`Cache` 自带 arena——`deinit` 一次释放全部，内部字符串
//!   全部由 arena 持有（调用方零管理）。
//!
//! 存盘位置：`<data_root>/plugins.json`、`<data_root>/plugins_cache.json`
//! （`data_root` 由 main 启动时解析，同预设库）。

const std = @import("std");

pub const config_file = "plugins.json";
pub const cache_file = "plugins_cache.json";
pub const cache_version: u32 = 1;

extern "c" fn time(?*i64) i64;

/// 当前时间（unix 秒）——`scanned_at` 打戳与“相对时间”显示共用。
/// 注：Zig 0.16 的 `std.time` 已无时间戳 API（I/O 形态改革）、`Io.Clock` 要拨 io，
/// 这里直接走 libc（已链接）——与 io 无关的纯查询。
pub fn unixTime() i64 {
    return time(null);
}

// ── 配置 ──

pub const Folder = struct {
    path: []const u8,
    enabled: bool = true,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    folders: std.ArrayListUnmanaged(Folder) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn alloc(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// 默认配置：VST3 规范的两个标准位置（系统级 + 用户级；可增删）。
    /// 注：不含 `Program Files (x86)`——宿主是 64 位，32 位插件扫了也载不了
    /// （只会得到 BadImage 噪音），需要时用户手动加。
    pub fn initDefaults(backing: std.mem.Allocator) Config {
        var cfg = Config{ .arena = std.heap.ArenaAllocator.init(backing) };
        _ = cfg.addFolder("C:\\Program Files\\Common Files\\VST3") catch false;
        if (std.c.getenv("LOCALAPPDATA")) |p| {
            const env = std.mem.span(p);
            const s = std.fmt.allocPrint(cfg.alloc(), "{s}\\Programs\\Common\\VST3", .{env}) catch null;
            if (s) |s2| _ = cfg.addFolder(s2) catch false;
        }
        return cfg;
    }

    /// 添加扫描文件夹（忽略大小写去重）。返回是否新增。
    pub fn addFolder(self: *Config, path: []const u8) !bool {
        if (path.len == 0) return false;
        for (self.folders.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.path, path)) return false;
        }
        const p = try self.alloc().dupe(u8, path);
        try self.folders.append(self.alloc(), .{ .path = p, .enabled = true });
        return true;
    }

    pub fn removeFolder(self: *Config, path: []const u8) bool {
        for (self.folders.items, 0..) |f, i| {
            if (std.ascii.eqlIgnoreCase(f.path, path)) {
                _ = self.folders.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// 添加单文件条目（忽略大小写去重）。返回是否新增。
    pub fn addFile(self: *Config, path: []const u8) !bool {
        if (path.len == 0) return false;
        for (self.files.items) |p| {
            if (std.ascii.eqlIgnoreCase(p, path)) return false;
        }
        const p = try self.alloc().dupe(u8, path);
        try self.files.append(self.alloc(), p);
        return true;
    }

    pub fn removeFile(self: *Config, path: []const u8) bool {
        for (self.files.items, 0..) |p, i| {
            if (std.ascii.eqlIgnoreCase(p, path)) {
                _ = self.files.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    const DiskFolder = struct { path: []const u8 = "", enabled: bool = true };
    const DiskConfig = struct {
        version: u32 = 1,
        folders: []const DiskFolder = &.{},
        files: []const []const u8 = &.{},
    };

    /// 读配置；文件缺失/损坏 → 默认配置（不报错——管理器永远能开起来；
    /// 损坏文件会在下次 save 时被覆盖）。
    pub fn load(io: std.Io, backing: std.mem.Allocator, data_root: []const u8) Config {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ data_root, config_file }) catch return initDefaults(backing);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, backing, .unlimited) catch return initDefaults(backing);
        defer backing.free(data);
        const parsed = std.json.parseFromSlice(DiskConfig, backing, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return initDefaults(backing);
        defer parsed.deinit();

        var cfg = Config{ .arena = std.heap.ArenaAllocator.init(backing) };
        const al = cfg.alloc();
        for (parsed.value.folders) |f| {
            if (f.path.len == 0) continue;
            const p = al.dupe(u8, f.path) catch continue;
            cfg.folders.append(al, .{ .path = p, .enabled = f.enabled }) catch continue;
        }
        for (parsed.value.files) |p| {
            if (p.len == 0) continue;
            const c = al.dupe(u8, p) catch continue;
            cfg.files.append(al, c) catch continue;
        }
        return cfg;
    }

    /// 原子写（`.tmp` → rename；同 preset 惯例）。`data_root` 不存在时创建。
    pub fn save(self: *Config, io: std.Io, data_root: []const u8) !void {
        std.Io.Dir.cwd().createDirPath(io, data_root) catch return error.IoFailure;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const dfolders = sa.alloc(DiskFolder, self.folders.items.len) catch return error.OutOfMemory;
        for (self.folders.items, 0..) |f, i| dfolders[i] = .{ .path = f.path, .enabled = f.enabled };
        const json = std.json.Stringify.valueAlloc(sa, DiskConfig{
            .version = 1,
            .folders = dfolders,
            .files = self.files.items,
        }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;

        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ data_root, config_file }) catch return error.NameTooLong;
        var tmp_buf: [1024]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json }) catch return error.IoFailure;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(tmp_path, cwd, path, io) catch {
            cwd.deleteFile(io, tmp_path) catch {};
            return error.IoFailure;
        };
    }
};

// ── 缓存 ──

/// 一个插件类（工厂枚举结果；cid 为 32 位小写 hex）。
pub const Class = struct {
    cid: []const u8 = "",
    name: []const u8 = "",
    vendor: []const u8 = "",
    version: []const u8 = "",
    category: []const u8 = "",
    sub: []const u8 = "",
    kind: []const u8 = "other",
};

pub const Entry = struct {
    path: []const u8, // 发现的根（.vst3 包 / 裸文件）
    dll: []const u8, // 实际加载路径
    ok: bool, // false = 加载/枚举失败
    name: []const u8 = "",
    vendor: []const u8 = "",
    version: []const u8 = "",
    role: []const u8 = "none", // instrument|effect|both|none
    err: []const u8 = "", // ok == false 时的错误名
    classes: []const Class = &.{},

    /// 该插件能否作乐器（含 Instrument 类的）
    pub fn roleHasInstrument(self: *const Entry) bool {
        return std.mem.indexOf(u8, self.role, "instrument") != null;
    }
    /// 该插件能否作效果器
    pub fn roleHasEffect(self: *const Entry) bool {
        return std.mem.indexOf(u8, self.role, "effect") != null;
    }
};

pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},
    /// 扫描完成时间（unix 秒；0 = 未知/从未）
    scanned_at: i64 = 0,
    /// worker 正常跑完（有 `end` 行）
    completed: bool = false,
    /// 崩溃定位：worker 死在哪个路径手里（`start` 无配对结果）
    crashed_after: ?[]const u8 = null,
    /// 解析失败的行数（容忍坏行；仅诊断用）
    bad_lines: usize = 0,

    fn alloc(self: *Cache) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Cache) void {
        self.arena.deinit();
    }

    pub fn okCount(self: *const Cache) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.ok) n += 1;
        }
        return n;
    }

    pub fn errCount(self: *const Cache) usize {
        return self.entries.len - self.okCount();
    }

    /// 按类 CID 找条目（重绑定自愈用；返回第一个匹配的 ok 条目）。
    pub fn findByCid(self: *const Cache, cid: []const u8) ?*const Entry {
        if (cid.len == 0) return null;
        for (self.entries, 0..) |e, i| {
            if (!e.ok) continue;
            for (e.classes) |c| {
                if (std.ascii.eqlIgnoreCase(c.cid, cid)) return &self.entries[i];
            }
        }
        return null;
    }

    fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// 解析 worker JSONL（协议见 `vst_scan.zig`；坏行容忍计入 `bad_lines`）。
    pub fn parseJsonl(backing: std.mem.Allocator, text: []const u8) Cache {
        var c = Cache{ .arena = std.heap.ArenaAllocator.init(backing) };
        const al = c.alloc();
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var pending: ?[]const u8 = null; // 已 start、未见结果的路径

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, backing, line, .{ .allocate = .alloc_always }) catch {
                c.bad_lines += 1;
                continue;
            };
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => {
                    c.bad_lines += 1;
                    continue;
                },
            };
            const ts = strField(obj, "t") orelse {
                c.bad_lines += 1;
                continue;
            };

            if (std.mem.eql(u8, ts, "start")) {
                const p = strField(obj, "path") orelse "";
                pending = al.dupe(u8, p) catch null;
            } else if (std.mem.eql(u8, ts, "ok") or std.mem.eql(u8, ts, "err")) {
                const is_ok = ts[0] == 'o';
                var e = Entry{
                    .path = al.dupe(u8, strField(obj, "path") orelse "") catch "",
                    .dll = al.dupe(u8, strField(obj, "dll") orelse "") catch "",
                    .ok = is_ok,
                };
                if (is_ok) {
                    e.name = al.dupe(u8, strField(obj, "name") orelse "") catch "";
                    e.vendor = al.dupe(u8, strField(obj, "vendor") orelse "") catch "";
                    e.version = al.dupe(u8, strField(obj, "version") orelse "") catch "";
                    e.role = al.dupe(u8, strField(obj, "role") orelse "none") catch "none";
                    if (obj.get("classes")) |cv| {
                        if (cv == .array) {
                            const cs = al.alloc(Class, cv.array.items.len) catch null;
                            if (cs) |list| {
                                var cn: usize = 0;
                                for (cv.array.items) |clv| {
                                    if (clv != .object) continue;
                                    const co = clv.object;
                                    list[cn] = .{
                                        .cid = al.dupe(u8, strField(co, "cid") orelse "") catch "",
                                        .name = al.dupe(u8, strField(co, "name") orelse "") catch "",
                                        .vendor = al.dupe(u8, strField(co, "vendor") orelse "") catch "",
                                        .version = al.dupe(u8, strField(co, "version") orelse "") catch "",
                                        .category = al.dupe(u8, strField(co, "category") orelse "") catch "",
                                        .sub = al.dupe(u8, strField(co, "sub") orelse "") catch "",
                                        .kind = al.dupe(u8, strField(co, "kind") orelse "other") catch "other",
                                    };
                                    cn += 1;
                                }
                                e.classes = list[0..cn];
                            }
                        }
                    }
                } else {
                    e.err = al.dupe(u8, strField(obj, "error") orelse "") catch "";
                }
                entries.append(al, e) catch {};
                pending = null;
            } else if (std.mem.eql(u8, ts, "end")) {
                c.completed = true;
            }
            // "begin"：候选总数——仅进度用，这里忽略
        }

        c.crashed_after = pending;
        c.entries = entries.toOwnedSlice(al) catch &.{};
        return c;
    }

    const DiskClass = struct {
        cid: []const u8 = "",
        name: []const u8 = "",
        vendor: []const u8 = "",
        version: []const u8 = "",
        category: []const u8 = "",
        sub: []const u8 = "",
        kind: []const u8 = "other",
    };
    const DiskEntry = struct {
        path: []const u8 = "",
        dll: []const u8 = "",
        ok: bool = true,
        name: []const u8 = "",
        vendor: []const u8 = "",
        version: []const u8 = "",
        role: []const u8 = "none",
        err: []const u8 = "",
        classes: []const DiskClass = &.{},
    };
    const DiskCache = struct {
        version: u32 = 1,
        scanned_at: i64 = 0,
        completed: bool = false,
        crashed_after: []const u8 = "",
        entries: []const DiskEntry = &.{},
    };

    /// 原子写缓存（`.tmp` → rename）。
    pub fn save(self: *const Cache, io: std.Io, data_root: []const u8) !void {
        std.Io.Dir.cwd().createDirPath(io, data_root) catch return error.IoFailure;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const dentries = sa.alloc(DiskEntry, self.entries.len) catch return error.OutOfMemory;
        for (self.entries, 0..) |e, i| {
            const dclasses = sa.alloc(DiskClass, e.classes.len) catch return error.OutOfMemory;
            for (e.classes, 0..) |c, j| dclasses[j] = .{
                .cid = c.cid,
                .name = c.name,
                .vendor = c.vendor,
                .version = c.version,
                .category = c.category,
                .sub = c.sub,
                .kind = c.kind,
            };
            dentries[i] = .{
                .path = e.path,
                .dll = e.dll,
                .ok = e.ok,
                .name = e.name,
                .vendor = e.vendor,
                .version = e.version,
                .role = e.role,
                .err = e.err,
                .classes = dclasses,
            };
        }
        const json = std.json.Stringify.valueAlloc(sa, DiskCache{
            .version = cache_version,
            .scanned_at = self.scanned_at,
            .completed = self.completed,
            .crashed_after = self.crashed_after orelse "",
            .entries = dentries,
        }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;

        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ data_root, cache_file }) catch return error.NameTooLong;
        var tmp_buf: [1024]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json }) catch return error.IoFailure;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(tmp_path, cwd, path, io) catch {
            cwd.deleteFile(io, tmp_path) catch {};
            return error.IoFailure;
        };
    }

    /// 读缓存；缺失/损坏 → null（调用方当“从未扫描”）。
    pub fn load(io: std.Io, backing: std.mem.Allocator, data_root: []const u8) ?Cache {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ data_root, cache_file }) catch return null;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, backing, .unlimited) catch return null;
        defer backing.free(data);
        const parsed = std.json.parseFromSlice(DiskCache, backing, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
        defer parsed.deinit();

        var c = Cache{ .arena = std.heap.ArenaAllocator.init(backing) };
        const al = c.alloc();
        c.scanned_at = parsed.value.scanned_at;
        c.completed = parsed.value.completed;
        if (parsed.value.crashed_after.len > 0) c.crashed_after = al.dupe(u8, parsed.value.crashed_after) catch null;
        const entries = al.alloc(Entry, parsed.value.entries.len) catch return null;
        for (parsed.value.entries, 0..) |e, i| {
            var ne = Entry{
                .path = al.dupe(u8, e.path) catch "",
                .dll = al.dupe(u8, e.dll) catch "",
                .ok = e.ok,
            };
            ne.name = al.dupe(u8, e.name) catch "";
            ne.vendor = al.dupe(u8, e.vendor) catch "";
            ne.version = al.dupe(u8, e.version) catch "";
            ne.role = al.dupe(u8, e.role) catch "none";
            ne.err = al.dupe(u8, e.err) catch "";
            const classes: []Class = al.alloc(Class, e.classes.len) catch return null;
            for (e.classes, 0..) |cl, j| {
                if (j >= classes.len) break;
                classes[j] = .{
                    .cid = al.dupe(u8, cl.cid) catch "",
                    .name = al.dupe(u8, cl.name) catch "",
                    .vendor = al.dupe(u8, cl.vendor) catch "",
                    .version = al.dupe(u8, cl.version) catch "",
                    .category = al.dupe(u8, cl.category) catch "",
                    .sub = al.dupe(u8, cl.sub) catch "",
                    .kind = al.dupe(u8, cl.kind) catch "other",
                };
            }
            ne.classes = classes;
            entries[i] = ne;
        }
        c.entries = entries;
        return c;
    }
};

// ── 测试 ──

test "plugin_db: 配置——默认值 / 往返 / 去重 / 删除" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);

    // 文件缺失 → 默认配置（含系统路径）
    var cfg = Config.load(io, alloc, root);
    defer cfg.deinit();
    var has_sys = false;
    for (cfg.folders.items) |f| {
        if (std.mem.eql(u8, f.path, "C:\\Program Files\\Common Files\\VST3")) has_sys = true;
    }
    try std.testing.expect(has_sys);

    // 去重（忽略大小写；文件夹与单文件各自）
    try std.testing.expect(!(try cfg.addFolder("c:\\program files\\common files\\vst3")));
    try std.testing.expect(try cfg.addFolder("D:\\VST3"));
    try std.testing.expect(try cfg.addFile("D:\\x\\A.vst3"));
    try std.testing.expect(!(try cfg.addFile("d:\\X\\a.VST3")));

    // 存盘 → 读回
    try cfg.save(io, root);
    var cfg2 = Config.load(io, alloc, root);
    defer cfg2.deinit();
    try std.testing.expectEqual(cfg.folders.items.len, cfg2.folders.items.len);
    try std.testing.expectEqual(cfg.files.items.len, cfg2.files.items.len);
    try std.testing.expectEqualStrings(cfg.files.items[0], cfg2.files.items[0]);
    var has_d = false;
    for (cfg2.folders.items) |f| {
        if (std.mem.eql(u8, f.path, "D:\\VST3")) has_d = true;
    }
    try std.testing.expect(has_d);

    // 删除
    try std.testing.expect(cfg2.removeFolder("d:\\vst3")); // 忽略大小写
    try std.testing.expect(!cfg2.removeFolder("D:\\nope"));
    try std.testing.expect(cfg2.removeFile("D:\\x\\A.vst3"));
    try std.testing.expect(!cfg2.removeFile("D:\\x\\A.vst3"));
}

const jsonl_sample =
    "{\"t\":\"begin\",\"n\":2}\n" ++
    "{\"t\":\"start\",\"path\":\"C:/v/A.vst3\",\"dll\":\"C:/v/A.vst3/x.dll\"}\n" ++
    "{\"t\":\"ok\",\"path\":\"C:/v/A.vst3\",\"dll\":\"C:/v/A.vst3/x.dll\",\"name\":\"A\",\"vendor\":\"VA\",\"version\":\"1.0\",\"role\":\"instrument\",\"classes\":[{\"cid\":\"0102030405060708090a0b0c0d0e0f10\",\"name\":\"A\",\"vendor\":\"VA\",\"version\":\"1.0\",\"category\":\"Audio Module Class\",\"sub\":\"Instrument|Synth\",\"kind\":\"instrument\"}]}\n" ++
    "{\"t\":\"start\",\"path\":\"C:/v/B.dll\",\"dll\":\"C:/v/B.dll\"}\n" ++
    "{\"t\":\"err\",\"path\":\"C:/v/B.dll\",\"dll\":\"C:/v/B.dll\",\"error\":\"NoGetPluginFactory\"}\n" ++
    "这不是 JSON\n" ++
    "{\"t\":\"end\",\"ok\":1,\"err\":1}\n";

test "plugin_db: JSONL 解析（ok/err/坏行/字段）+ findByCid" {
    const alloc = std.testing.allocator;
    var c = Cache.parseJsonl(alloc, jsonl_sample);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 2), c.entries.len);
    try std.testing.expect(c.completed);
    try std.testing.expect(c.crashed_after == null);
    try std.testing.expectEqual(@as(usize, 1), c.bad_lines);
    try std.testing.expectEqual(@as(usize, 1), c.okCount());
    try std.testing.expectEqual(@as(usize, 1), c.errCount());

    const e0 = &c.entries[0];
    try std.testing.expect(e0.ok);
    try std.testing.expectEqualStrings("A", e0.name);
    try std.testing.expectEqualStrings("instrument", e0.role);
    try std.testing.expect(e0.roleHasInstrument());
    try std.testing.expect(!e0.roleHasEffect());
    try std.testing.expectEqual(@as(usize, 1), e0.classes.len);
    try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", e0.classes[0].cid);
    try std.testing.expectEqualStrings("Instrument|Synth", e0.classes[0].sub);

    const e1 = &c.entries[1];
    try std.testing.expect(!e1.ok);
    try std.testing.expectEqualStrings("NoGetPluginFactory", e1.err);

    try std.testing.expect(c.findByCid("0102030405060708090a0b0c0d0e0f10") != null);
    try std.testing.expect(c.findByCid("0102030405060708090A0B0C0D0E0F10") != null); // 忽略大小写
    try std.testing.expect(c.findByCid("ffff") == null);
    try std.testing.expect(c.findByCid("") == null);
}

test "plugin_db: 崩溃定位——start 无配对结果 + 缺 end" {
    const alloc = std.testing.allocator;
    // 截断：B 的 start 之后 worker 就死了（无 err、无 end）
    const cut =
        "{\"t\":\"begin\",\"n\":2}\n" ++
        "{\"t\":\"start\",\"path\":\"C:/v/A.vst3\",\"dll\":\"C:/v/A.dll\"}\n" ++
        "{\"t\":\"ok\",\"path\":\"C:/v/A.vst3\",\"dll\":\"C:/v/A.dll\",\"name\":\"A\",\"role\":\"effect\",\"classes\":[]}\n" ++
        "{\"t\":\"start\",\"path\":\"C:/v/Bad.vst3\",\"dll\":\"C:/v/Bad.dll\"}\n";
    var c = Cache.parseJsonl(alloc, cut);
    defer c.deinit();
    try std.testing.expect(!c.completed);
    try std.testing.expectEqualStrings("C:/v/Bad.vst3", c.crashed_after.?);
    try std.testing.expectEqual(@as(usize, 1), c.entries.len);
}

test "plugin_db: 缓存存盘往返（含类信息）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);

    var c = Cache.parseJsonl(alloc, jsonl_sample);
    defer c.deinit();
    c.scanned_at = 1234567890;
    try c.save(io, root);

    var c2 = Cache.load(io, alloc, root) orelse return error.CacheLoadFailed;
    defer c2.deinit();
    try std.testing.expectEqual(@as(i64, 1234567890), c2.scanned_at);
    try std.testing.expect(c2.completed);
    try std.testing.expectEqual(@as(usize, 2), c2.entries.len);
    try std.testing.expectEqualStrings("A", c2.entries[0].name);
    try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", c2.entries[0].classes[0].cid);
    try std.testing.expectEqualStrings("NoGetPluginFactory", c2.entries[1].err);
    try std.testing.expect(c2.findByCid("0102030405060708090a0b0c0d0e0f10") != null);
}

test "plugin_db: 真实扫描输出可解析（文件存在才跑）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(io, "tmp/vst_scan_out.jsonl", alloc, .unlimited) catch return; // 不存在：跳过
    defer alloc.free(data);
    var c = Cache.parseJsonl(alloc, data);
    defer c.deinit();
    try std.testing.expect(c.entries.len > 0);
    try std.testing.expect(c.completed);
    try std.testing.expect(c.okCount() > 0);
    // 真实输出里至少能找到 Vital 的某个类 CID（本机环境；找不到也不强求——只查结构）
    try std.testing.expect(c.crashed_after == null);
}
