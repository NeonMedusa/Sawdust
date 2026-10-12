//! 预设库：`data/presets/<插件类型>/<名字>.sawpreset` 的读写与扫描。
//!
//! 设计（见 `docs/drumkit.md` §5，已定稿）：
//! - **数据根**：`<exe>/data`（便携）→ 不存在则看 `<cwd>/data`（开发兜底）
//!   → 都没有则创建于 exe 目录；
//! - **分类 = 插件类型**（`subtractive` / 将来的 `fm`/`vst3`…），一级子目录；
//! - 文件内自带 `plugin` 字段：**加载时校验**，不匹配拒绝（防串插件灌参数）；
//! - 名字以**文件名**为准（不存 `name`）；保存重名（忽略大小写）拒绝；
//! - 写盘先写 `.tmp` 再改名替换（防中断留半截文件）。
//!
//! 本模块**不依赖 UI**；文件 IO 用 `std.Io`（调用方传 io——App 无 io）。

const std = @import("std");
const persist = @import("persist.zig");

/// 预设文件后缀（含点）
pub const extension = ".sawpreset";
/// 当前唯一支持预设的插件类型（将来的内置合成器/第三方各有自己的）
pub const plugin_subtractive = "subtractive";
pub const plugin_drumkit = "drumkit";

/// 插件类型显示名（分类 id → 中文名；供 UI 文案）
pub fn pluginDisplayName(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, plugin_subtractive)) return "减法合成器";
    if (std.mem.eql(u8, id, plugin_drumkit)) return "鼓组";
    if (std.mem.eql(u8, id, "fm")) return "FM 合成器";
    if (std.mem.eql(u8, id, "sampler")) return "采样器";
    if (std.mem.eql(u8, id, "vst3")) return "VST3 插件";
    return id;
}

/// 来源串 `分类/名字` → 名字部分（无 `/` 则原样；供保存预填/展示）
pub fn nameFromSource(src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '/')) |i| return src[i + 1 ..];
    return src;
}

/// 每个插件分类置顶的**默认伪预设**标签（选中 = 用该插件的默认参数建/换乐器）
pub fn defaultPresetLabel(plugin: []const u8) []const u8 {
    if (std.mem.eql(u8, plugin, plugin_subtractive)) return "（默认音色）";
    if (std.mem.eql(u8, plugin, plugin_drumkit)) return "（默认套鼓）";
    return "（未实装）";
}
/// 首次运行创建的分类骨架（仅作提示；实际以扫描到的目录为准）
pub const skeleton_dirs = [_][]const u8{ plugin_subtractive, "fm", "vst3", "drumkit" };
/// 名字长度上限（字节）
pub const max_name_len = 64;

/// 磁盘格式（`name` 不存——以文件名为准）。
/// 载荷按 `plugin` 取用：合成器系列（subtractive/将来 fm）→ `synth`；
/// `drumkit`（整组套预设）→ `kit`（**自包含**：每层内嵌合成器参数副本，
/// 加载不依赖外部文件）。另一字段保持默认值即可（旧文件缺失 → 默认）。
pub const File = struct {
    version: u32 = 1,
    /// 插件类型标识（加载校验；见模块注释）
    plugin: []const u8 = plugin_subtractive,
    synth: persist.SavedSynth = .{},
    kit: persist.SavedDrumKit = .{},
};

/// 一个分类（= 一级子目录）下的预设名列表（名字为**文件名去后缀**，堆分配）
pub const Category = struct {
    name: []u8,
    presets: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 },

    fn deinit(self: *Category, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.presets.items) |p| allocator.free(p);
        self.presets.deinit(allocator);
    }
};

/// 扫描结果（调用方 `deinit`）
pub const Library = struct {
    categories: std.ArrayListUnmanaged(Category) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *Library, allocator: std.mem.Allocator) void {
        for (self.categories.items) |*c| c.deinit(allocator);
        self.categories.deinit(allocator);
    }

    /// 找分类序号（找不到返回 null）
    pub fn findCategory(self: *const Library, name: []const u8) ?usize {
        for (self.categories.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return i;
        }
        return null;
    }
};

/// 名字清洗：非法字符（Windows 禁用集）→ `_`，首尾空白裁剪。
/// 纯函数（返回写进 `buf` 的切片；buf 不够/结果为空 → 返回空串表示拒绝）。
pub fn sanitizeName(name: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "";
    var n: usize = 0;
    for (trimmed) |ch| {
        if (n >= @min(buf.len, max_name_len)) break;
        buf[n] = switch (ch) {
            '\\', '/', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => ch,
        };
        n += 1;
    }
    if (n == 0) return "";
    return buf[0..n];
}

/// 解析数据根目录（相对可执行目录/工作目录；见模块注释）。
/// `exe_dir` = 可执行文件所在目录（如 "zig-out/bin"；调用方自取）。
/// 返回的切片写进 `buf`（相对路径，可直接给 cwd 开头的 `std.Io.Dir` 用）。
pub fn resolveDataRoot(io: std.Io, exe_dir: []const u8, buf: []u8) ?[]const u8 {
    // 1) <exe>/data
    const p1 = std.fmt.bufPrint(buf, "{s}/data", .{exe_dir}) catch return null;
    if (pathExists(io, p1)) return p1;
    // 2) <cwd>/data（开发兜底）
    if (exe_dir.len > 0 and pathExists(io, "data")) return "data";
    // 3) 都无 → 返回 exe 目录下的（由调用方创建）
    return p1;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 首次运行创建骨架：`<data>/presets/<各分类>`（已存在则无害）
pub fn ensureSkeleton(io: std.Io, data_root: []const u8, buf: []u8) void {
    const base = std.fmt.bufPrint(buf, "{s}/presets", .{data_root}) catch return;
    std.Io.Dir.cwd().createDirPath(io, base) catch return;
    var b2: [512]u8 = undefined;
    for (skeleton_dirs) |d| {
        const p = std.fmt.bufPrint(&b2, "{s}/{s}", .{ base, d }) catch continue;
        std.Io.Dir.cwd().createDirPath(io, p) catch continue;
    }
}

/// 扫描 `<data_root>/presets/*/`：一级子目录 = 分类，目录内 `*.sawpreset` = 预设
/// （名字去后缀）。分类/名字均按字典序排序（浏览稳定）。
pub fn scan(io: std.Io, allocator: std.mem.Allocator, data_root: []const u8) !Library {
    var lib = Library{};
    errdefer lib.deinit(allocator);

    var path_buf: [512]u8 = undefined;
    const presets_dir = std.fmt.bufPrint(&path_buf, "{s}/presets", .{data_root}) catch return lib;

    var dir = std.Io.Dir.cwd().openDir(io, presets_dir, .{ .iterate = true }) catch return lib;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var cat = Category{ .name = allocator.dupe(u8, entry.name) catch continue };
        errdefer cat.deinit(allocator);
        collectPresets(io, allocator, presets_dir, entry.name, &cat) catch {
            cat.deinit(allocator);
            continue;
        };
        lib.categories.append(allocator, cat) catch {
            cat.deinit(allocator);
            continue;
        };
    }

    std.mem.sort(Category, lib.categories.items, {}, struct {
        fn less(_: void, a: Category, b: Category) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return lib;
}

fn collectPresets(io: std.Io, allocator: std.mem.Allocator, presets_dir: []const u8, cat: []const u8, out: *Category) !void {
    var path_buf: [600]u8 = undefined;
    const cat_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ presets_dir, cat }) catch return;
    var dir = try std.Io.Dir.cwd().openDir(io, cat_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, extension)) continue;
        const base = entry.name[0 .. entry.name.len - extension.len];
        if (base.len == 0) continue;
        const name = allocator.dupe(u8, base) catch continue;
        out.presets.append(allocator, name) catch {
            allocator.free(name);
            continue;
        };
    }
    std.mem.sort([]u8, out.presets.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

/// 读一个预设文件并解析。`plugin` 字段不匹配 `expected_plugin` → 返回
/// `error.PluginMismatch`（调用方提示；防串插件灌参数）。
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_root: []const u8,
    category: []const u8,
    name: []const u8,
    expected_plugin: []const u8,
) !std.json.Parsed(File) {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/presets/{s}/{s}{s}", .{ data_root, category, name, extension }) catch
        return error.NameTooLong;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);

    // **`.alloc_always` 必须**：默认的 `alloc_if_needed` 会让无转义字符串
    // 借用 `data` 缓冲——`data` 在返回前就释放了 → 返回值里的字符串
    // （prep 名字/层来源名/插件名…）全部悬空。实测：套预设名字读出乱码
    // 到段错误。全拷进 arena 后，返回值自包含。
    var parsed = try std.json.parseFromSlice(File, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.plugin, expected_plugin)) return error.PluginMismatch;
    return parsed;
}

/// 保存合成器音色预设（原子写：`.tmp` → rename 替换）。名字先清洗；
/// 空名/超长 → `error.InvalidName`；重名（忽略大小写）→ `error.AlreadyExists`。
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_root: []const u8,
    category: []const u8,
    raw_name: []const u8,
    plugin: []const u8,
    synth_saved: persist.SavedSynth,
) !void {
    return saveFile(io, allocator, data_root, category, raw_name, .{ .plugin = plugin, .synth = synth_saved }, false);
}

/// 保存**整组套预设**（`plugin = drumkit`；载荷 = 套鼓快照）
pub fn saveKit(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_root: []const u8,
    category: []const u8,
    raw_name: []const u8,
    kit_saved: persist.SavedDrumKit,
) !void {
    return saveFile(io, allocator, data_root, category, raw_name, .{ .plugin = plugin_drumkit, .kit = kit_saved }, false);
}

/// 保存任意载荷（音色/套鼓；`overwrite` = 同名时直接替换而不是报 AlreadyExists）。
/// 原子写：`.tmp` → rename 替换。名字先清洗；空名/超长 → `error.InvalidName`；
/// 重名（忽略大小写）→ `error.AlreadyExists`（overwrite 时跳过）。
pub fn saveFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_root: []const u8,
    category: []const u8,
    raw_name: []const u8,
    file: File,
    overwrite: bool,
) !void {
    var name_buf: [max_name_len]u8 = undefined;
    const name = sanitizeName(raw_name, &name_buf);
    if (name.len == 0) return error.InvalidName;

    var dir_buf: [600]u8 = undefined;
    const cat_dir = std.fmt.bufPrint(&dir_buf, "{s}/presets/{s}", .{ data_root, category }) catch return error.NameTooLong;
    std.Io.Dir.cwd().createDirPath(io, cat_dir) catch return error.IoFailure;

    // 重名检查（忽略大小写——Windows 语义；`.sawpreset` 后缀也一并比）
    var path_buf: [1024]u8 = undefined;
    const final_path = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ cat_dir, name, extension }) catch return error.NameTooLong;
    if (!overwrite) {
        if (pathExists(io, final_path)) return error.AlreadyExists;

        // 首字母不同大小写的情况：Windows 下 access 已能命中；但为稳，再列一遍目录做 ASCII 忽略大小写比对
        if (nameInDirIgnoreCase(io, cat_dir, name)) return error.AlreadyExists;
    }

    const json = try std.json.Stringify.valueAlloc(allocator, file, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    // 原子写：先写 tmp 再改名
    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{final_path}) catch return error.NameTooLong;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json }) catch return error.IoFailure;
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, io) catch {
        cwd.deleteFile(io, tmp_path) catch {};
        return error.IoFailure;
    };
}

/// 重命名预设文件（同分类内；`old_name` 为**已清洗的显示名**）。
/// 新名先清洗；空名 → `InvalidName`；与其它预设重名（忽略大小写）→
/// `AlreadyExists`；**仅大小写变化**允许（Windows 下同一文件）；
/// 旧名==新名 → 直接成功（no-op）。
pub fn rename(
    io: std.Io,
    data_root: []const u8,
    category: []const u8,
    old_name: []const u8,
    raw_new_name: []const u8,
) !void {
    var name_buf: [max_name_len]u8 = undefined;
    const new_name = sanitizeName(raw_new_name, &name_buf);
    if (new_name.len == 0) return error.InvalidName;
    if (std.mem.eql(u8, old_name, new_name)) return; // 无变化

    var old_buf: [1024]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}/presets/{s}/{s}{s}", .{ data_root, category, old_name, extension }) catch
        return error.NameTooLong;
    var new_buf: [1024]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_buf, "{s}/presets/{s}/{s}{s}", .{ data_root, category, new_name, extension }) catch
        return error.NameTooLong;

    const cwd = std.Io.Dir.cwd();
    // 重名检查（仅大小写变化跳过：那是同一个文件）
    if (!std.ascii.eqlIgnoreCase(old_name, new_name)) {
        if (pathExists(io, new_path)) return error.AlreadyExists;
        var cat_buf: [600]u8 = undefined;
        const cat_dir = std.fmt.bufPrint(&cat_buf, "{s}/presets/{s}", .{ data_root, category }) catch return error.NameTooLong;
        if (nameInDirIgnoreCase(io, cat_dir, new_name)) return error.AlreadyExists;
    }
    cwd.rename(old_path, cwd, new_path, io) catch return error.IoFailure;
}

/// 删除预设文件（`name` = 已清洗的显示名）
pub fn remove(io: std.Io, data_root: []const u8, category: []const u8, name: []const u8) !void {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/presets/{s}/{s}{s}", .{ data_root, category, name, extension }) catch
        return error.NameTooLong;
    std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {}, // 已不存在：当作成功（重扫后自然消失）
        else => return error.IoFailure,
    };
}

fn nameInDirIgnoreCase(io: std.Io, dir_path: []const u8, name: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, extension)) continue;
        const base = entry.name[0 .. entry.name.len - extension.len];
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

// ── 测试 ──

test "preset: 名字清洗（非法字符/空白/超长/空）" {
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("Kick808", sanitizeName("Kick808", &buf));
    try std.testing.expectEqualStrings("a_b_c_d_e_f_g_h_i_", sanitizeName(" a\\b/c:d*e?f\"g<h>i|", &buf));
    try std.testing.expectEqualStrings("hi  there", sanitizeName("  hi  there ", &buf)); // 首尾裁剪、中间保留
    try std.testing.expectEqualStrings("", sanitizeName("   ", &buf)); // 全空白 → 拒绝
    try std.testing.expectEqualStrings("", sanitizeName("", &buf));

    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectEqual(@as(usize, max_name_len), sanitizeName(&long, &buf).len); // 截断到上限
}

test "preset: JSON 往返（plugin 字段与合成器参数）" {
    const allocator = std.testing.allocator;
    var p = @import("synth.zig").SynthParams{};
    p.attack.store(0.42, .monotonic);
    p.osc[1].enabled.store(true, .monotonic);
    const saved = persist.exportSynth(&p);

    const file = File{ .plugin = plugin_subtractive, .synth = saved };
    const json = try std.json.Stringify.valueAlloc(allocator, file, .{});
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"subtractive\"") != null);

    const parsed = try std.json.parseFromSlice(File, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(plugin_subtractive, parsed.value.plugin);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), parsed.value.synth.attack, 1e-6);
    try std.testing.expect(parsed.value.synth.osc[1].enabled);
}

test "preset: 插件显示名（已知 id → 中文；未知 → 原样）" {
    try std.testing.expectEqualStrings("减法合成器", pluginDisplayName(plugin_subtractive));
    try std.testing.expectEqualStrings("鼓组", pluginDisplayName(plugin_drumkit));
    try std.testing.expectEqualStrings("FM 合成器", pluginDisplayName("fm"));
    try std.testing.expectEqualStrings("future_plugin", pluginDisplayName("future_plugin"));
    // 置顶默认伪预设标签
    try std.testing.expectEqualStrings("（默认音色）", defaultPresetLabel(plugin_subtractive));
    try std.testing.expectEqualStrings("（默认套鼓）", defaultPresetLabel(plugin_drumkit));
    try std.testing.expectEqualStrings("（未实装）", defaultPresetLabel("fm"));
    // 来源串 → 名字（保存预填/展示用）
    try std.testing.expectEqualStrings("Kick808", nameFromSource("subtractive/Kick808"));
    try std.testing.expectEqualStrings("无前缀", nameFromSource("无前缀"));
    try std.testing.expectEqualStrings("", nameFromSource(""));
    try std.testing.expectEqualStrings("a/b", nameFromSource("cat/a/b")); // 只切第一段
}

test "preset: 端到端——保存 → 扫描 → 加载（真实文件）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    // 骨架（首次运行路径）
    var skel_buf: [512]u8 = undefined;
    ensureSkeleton(io, root, &skel_buf);

    // 保存：参数带几个可区分的值
    var p = @import("synth.zig").SynthParams{};
    p.attack.store(0.31, .monotonic);
    p.osc[2].enabled.store(true, .monotonic);
    p.osc[2].unison.store(9, .monotonic);
    const saved = persist.exportSynth(&p);
    try save(io, allocator, root, plugin_subtractive, "My Kick 808", plugin_subtractive, saved);

    // 扫描：出现在列表里
    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    const ci = lib.findCategory(plugin_subtractive) orelse return error.NoCategory;
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items[ci].presets.items.len);
    try std.testing.expectEqualStrings("My Kick 808", lib.categories.items[ci].presets.items[0]);

    // 加载：参数还原
    var parsed = try load(io, allocator, root, plugin_subtractive, "My Kick 808", plugin_subtractive);
    defer parsed.deinit();
    var q = @import("synth.zig").SynthParams{};
    persist.importSynth(&parsed.value.synth, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.31), q.attack.load(.monotonic), 1e-6);
    try std.testing.expectEqual(@as(u32, 9), q.osc[2].unison.load(.monotonic));

    // plugin 不匹配 → 拒绝（防串插件灌参数）
    try std.testing.expectError(error.PluginMismatch, load(io, allocator, root, plugin_subtractive, "My Kick 808", "vst3"));

    // 重名（忽略大小写，Windows 语义）→ 拒绝
    try std.testing.expectError(error.AlreadyExists, save(io, allocator, root, plugin_subtractive, "my kick 808", plugin_subtractive, saved));
    // 空名 → 拒绝
    try std.testing.expectError(error.InvalidName, save(io, allocator, root, plugin_subtractive, "   ", plugin_subtractive, saved));

    // 非法字符名 → 清洗后保存成功（第二个预设）
    try save(io, allocator, root, plugin_subtractive, "a/b:c", plugin_subtractive, saved);
    var lib2 = try scan(io, allocator, root);
    defer lib2.deinit(allocator);
    const ci2 = lib2.findCategory(plugin_subtractive).?;
    try std.testing.expectEqual(@as(usize, 2), lib2.categories.items[ci2].presets.items.len);
    // 字典序（字节序：大写 'M' < 小写 'a'）
    try std.testing.expectEqualStrings("My Kick 808", lib2.categories.items[ci2].presets.items[0]);
    try std.testing.expectEqualStrings("a_b_c", lib2.categories.items[ci2].presets.items[1]);
}

test "preset: 套鼓预设端到端——保存 → 扫描 → 加载（真实文件；自包含）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var skel_buf: [512]u8 = undefined;
    ensureSkeleton(io, root, &skel_buf);

    // 构造一个可区分的套鼓快照（层内嵌参数 + 名字 + 来源名）
    var p = @import("synth.zig").SynthParams{};
    p.release.store(0.11, .monotonic);
    p.osc[1].enabled.store(true, .monotonic);
    var layers = [_]persist.SavedDrumLayer{.{
        .kind = 0,
        .synth = persist.exportSynth(&p),
        .gain = 0.66,
        .source_preset = "subtractive/Kick808",
    }};
    var pads = [_]persist.SavedDrumPad{.{
        .pitch = 35,
        .name = "底鼓",
        .layers = &layers,
    }};
    const kit_saved = persist.SavedDrumKit{ .pads = &pads };

    try saveKit(io, allocator, root, plugin_drumkit, "My Kit", kit_saved);

    // 扫描：出现在 drumkit 分类
    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    const ci = lib.findCategory(plugin_drumkit) orelse return error.NoCategory;
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items[ci].presets.items.len);
    try std.testing.expectEqualStrings("My Kit", lib.categories.items[ci].presets.items[0]);

    // 加载：套鼓载荷还原（墴名/层增益/来源/内嵌参数）
    var parsed = try load(io, allocator, root, plugin_drumkit, "My Kit", plugin_drumkit);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.kit.pads.len);
    try std.testing.expectEqual(@as(u32, 35), parsed.value.kit.pads[0].pitch);
    try std.testing.expectEqualStrings("底鼓", parsed.value.kit.pads[0].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.kit.pads[0].layers.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.66), parsed.value.kit.pads[0].layers[0].gain, 1e-6);
    try std.testing.expectEqualStrings("subtractive/Kick808", parsed.value.kit.pads[0].layers[0].source_preset);
    var q = @import("synth.zig").SynthParams{};
    persist.importSynth(&parsed.value.kit.pads[0].layers[0].synth, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.11), q.release.load(.monotonic), 1e-6);
    try std.testing.expect(q.osc[1].enabled.load(.monotonic));

    // 插件校验：拿 drumkit 预设当减法预设加载 → 拒绝
    try std.testing.expectError(error.PluginMismatch, load(io, allocator, root, plugin_drumkit, "My Kit", plugin_subtractive));

    // 覆写：同名 + `overwrite = false` → AlreadyExists；`true` → 替换内容
    try std.testing.expectError(error.AlreadyExists, saveFile(io, allocator, root, plugin_drumkit, "My Kit", .{ .plugin = plugin_drumkit, .kit = kit_saved }, false));
    var p2 = @import("synth.zig").SynthParams{};
    p2.release.store(0.99, .monotonic);
    var layers2 = [_]persist.SavedDrumLayer{.{ .synth = persist.exportSynth(&p2) }};
    var pads2 = [_]persist.SavedDrumPad{.{ .pitch = 38, .name = "小军鼓", .layers = &layers2 }};
    const kit2 = persist.SavedDrumKit{ .pads = &pads2 };
    try saveFile(io, allocator, root, plugin_drumkit, "My Kit", .{ .plugin = plugin_drumkit, .kit = kit2 }, true);
    var parsed2 = try load(io, allocator, root, plugin_drumkit, "My Kit", plugin_drumkit);
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed2.value.kit.pads.len);
    try std.testing.expectEqual(@as(u32, 38), parsed2.value.kit.pads[0].pitch); // 旧内容被替换
    try std.testing.expectEqualStrings("小军鼓", parsed2.value.kit.pads[0].name);
}

test "preset: 重命名/删除（真实文件；重名/空名/仅大小写）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var skel_buf: [512]u8 = undefined;
    ensureSkeleton(io, root, &skel_buf);

    var p = @import("synth.zig").SynthParams{};
    p.attack.store(0.21, .monotonic);
    const saved = persist.exportSynth(&p);
    try save(io, allocator, root, plugin_subtractive, "Old名", plugin_subtractive, saved);
    try save(io, allocator, root, plugin_subtractive, "占用", plugin_subtractive, saved);

    // 重名（忽略大小写）→ 拒绝；空名 → 拒绝；非法字符 → 洗净后可行
    try std.testing.expectError(error.AlreadyExists, rename(io, root, plugin_subtractive, "Old名", "占用"));
    try std.testing.expectError(error.InvalidName, rename(io, root, plugin_subtractive, "Old名", "   "));

    // 正常重命名：新名能加载、内容不变；旧名消失
    try rename(io, root, plugin_subtractive, "Old名", "New名");
    var chk = try load(io, allocator, root, plugin_subtractive, "New名", plugin_subtractive);
    defer chk.deinit();
    var q = @import("synth.zig").SynthParams{};
    persist.importSynth(&chk.value.synth, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.21), q.attack.load(.monotonic), 1e-6);
    try std.testing.expectError(error.FileNotFound, load(io, allocator, root, plugin_subtractive, "Old名", plugin_subtractive));

    // 仅大小写变化（Windows 同一文件）→ 允许；旧名==新名 → no-op
    try rename(io, root, plugin_subtractive, "New名", "NEW名");
    var chk2 = try load(io, allocator, root, plugin_subtractive, "NEW名", plugin_subtractive);
    chk2.deinit();
    try rename(io, root, plugin_subtractive, "NEW名", "NEW名");

    // 删除：文件消失；再删（已不存在）也不报错
    try remove(io, root, plugin_subtractive, "NEW名");
    try std.testing.expectError(error.FileNotFound, load(io, allocator, root, plugin_subtractive, "NEW名", plugin_subtractive));
    try remove(io, root, plugin_subtractive, "NEW名");

    // 扫描只剩下“占用”
    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    const ci = lib.findCategory(plugin_subtractive) orelse return error.NoCategory;
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items[ci].presets.items.len);
    try std.testing.expectEqualStrings("占用", lib.categories.items[ci].presets.items[0]);
}
