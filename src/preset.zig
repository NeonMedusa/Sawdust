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

/// 内建效果器的预设分类 id（单效果预设；EQ/混响/延迟/压缩）
pub const plugin_fx_eq = "fx_eq";
pub const plugin_fx_reverb = "fx_reverb";
pub const plugin_fx_delay = "fx_delay";
pub const plugin_fx_compressor = "fx_compressor";
pub const fx_category_ids = [_][]const u8{ plugin_fx_eq, plugin_fx_reverb, plugin_fx_delay, plugin_fx_compressor };

/// VST3 分类 id 前缀（分类身份 = `vst3_<32 位小写 hex CID>`；每插件一个分类）
pub const vst3_prefix = "vst3_";

/// 由 CID hex 生成 VST3 分类 id（写入 buf；长度不对 → 返回 ""）
pub fn vst3CategoryId(cid_hex: []const u8, buf: []u8) []const u8 {
    if (cid_hex.len != 32) return "";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ vst3_prefix, cid_hex }) catch "";
}

/// 分类 id → CID hex（非 VST3 分类/格式不对 → null）
pub fn vst3CidFromCategory(id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, id, vst3_prefix)) return null;
    const hex = id[vst3_prefix.len..];
    if (hex.len != 32) return null;
    for (hex) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return hex;
}

/// 插件类型显示名（分类 id → 中文名；供 UI 文案）
pub fn pluginDisplayName(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, plugin_subtractive)) return "减法合成器";
    if (std.mem.eql(u8, id, plugin_drumkit)) return "鼓组";
    if (std.mem.eql(u8, id, plugin_fx_eq)) return "EQ 参量均衡";
    if (std.mem.eql(u8, id, plugin_fx_reverb)) return "混响";
    if (std.mem.eql(u8, id, plugin_fx_delay)) return "延迟";
    if (std.mem.eql(u8, id, plugin_fx_compressor)) return "压缩器";
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
    if (std.mem.startsWith(u8, plugin, vst3_prefix)) return "（默认音色）";
    if (std.mem.eql(u8, plugin, plugin_fx_eq) or std.mem.eql(u8, plugin, plugin_fx_reverb) or
        std.mem.eql(u8, plugin, plugin_fx_delay) or std.mem.eql(u8, plugin, plugin_fx_compressor)) return "（默认参数）";
    return "（未实装）";
}
/// 首次运行创建的分类骨架（仅作提示；实际以扫描到的目录为准）
/// 注：VST3 分类由扫描缓存合成（`vst3_<cid>`），不再建 "vst3" 占位目录
pub const skeleton_dirs = [_][]const u8{ plugin_subtractive, "drumkit", plugin_fx_eq, plugin_fx_reverb, plugin_fx_delay, plugin_fx_compressor };
/// 名字长度上限（字节）
pub const max_name_len = 64;

/// 磁盘格式（`name` 不存——以文件名为准）。
/// 载荷按 `plugin` 取用：合成器系列（subtractive/将来 fm）→ `synth`；
/// `drumkit`（整组套预设）→ `kit`（**自包含**：每层内嵌合成器参数副本，
/// 加载不依赖外部文件）；`vst3_<cid>`（v2）→ `vst3_state*` + 身份字段。
/// **字段顺序即 JSON 写出顺序**，按“人类可读性”排：身份/展示 → 可读参数载荷 →
/// **不可读的大块状态（vst3_state*）放在最末**（方便手翻/尾读，不挡在前面）。
pub const File = struct {
    version: u32 = 1,
    /// 插件类型标识（**逻辑分类 id**：`subtractive` / `drumkit` / `fx_*` / `vst3_<32hex CID>`）
    /// ——加载校验（不匹配拒绝，防串插件灌参数）。注：VST3 的 CID **内嵌于此**，不另存 cid。
    plugin: []const u8 = plugin_subtractive,
    // ── 身份/展示（前置——人类可读）──
    /// 插件显示名（扫描缓存/活实例缺失时回退显示）
    name: []const u8 = "",
    vendor: []const u8 = "",
    /// 最后已知路径（缓存里找不到插件时的兑底定位）
    last_path: []const u8 = "",
    // ── 可读参数载荷（按 `plugin` 取用）──
    synth: persist.SavedSynth = .{},
    kit: persist.SavedDrumKit = .{},
    /// 内建效果器单效果预设（`plugin` 形如 `fx_eq`；v2 起——kind/mix/p/bands）
    effect: persist.SavedEffectSlot = .{},
    // ── 不可读状态（**最末**：base64 大块，人类读不了也不挡路）──
    /// VST3 插件状态（base64；组件 + 控制器各一份，成对）
    vst3_state: []const u8 = "",
    vst3_state_ctrl: []const u8 = "",
};

/// 扫描时只读的身份字段（完整 `File` 的轻量子集）
const MetaDisk = struct {
    plugin: []const u8 = "",
    name: []const u8 = "",
};

/// 一个分类（一级子目录）。
/// **身份与展示分离**：`name` = 逻辑 id（文件 `plugin` 字段值，校验/选择用它）；
/// `dir` = 实际目录名（**纯展示层**：VST3 → `<插件名> (短CID)`；内置 → 等同 id）；
/// `label` = 展示名回退（VST3 预设文件里的 `name`；插件未安装时仍可读）。
pub const Category = struct {
    name: []u8,
    dir: []u8 = &.{},
    label: ?[]u8 = null,
    presets: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 },

    fn deinit(self: *Category, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.dir.len > 0) allocator.free(self.dir);
        if (self.label) |lb| allocator.free(lb);
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

/// 规范目录名：**纯插件名**（清洗；空 → "VST3"）；`with_hash` = 附 `(<CID哈希前8hex>)`
/// 后缀——**仅同名冲突时用**。纯展示——身份在预设文件的 `plugin` 字段里。
/// 后缀取完整 CID 的 Wyhash 前 4 字节（确定性；TUID 头常是厂商代号、尾常是名字+零填充，
/// 直接截两头都易撞）。
pub fn categoryDirName(display_name: []const u8, cid_hex: []const u8, with_hash: bool, buf: []u8) []const u8 {
    var nb: [max_name_len]u8 = undefined;
    const clean = sanitizeName(display_name, &nb);
    const base = if (clean.len > 0) clean else "VST3";
    if (!with_hash) return std.fmt.bufPrint(buf, "{s}", .{base}) catch "";
    const h = std.hash.Wyhash.hash(0x9e3779b9, cid_hex);
    return std.fmt.bufPrint(buf, "{s} ({x:0>8})", .{ base, @as(u32, @truncate(h)) }) catch "";
}

/// 目录名是否为内置骨架分类（扫描时保留空的内置骨架目录；其它空目录跳过）
pub fn isSkeletonName(name: []const u8) bool {
    for (skeleton_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// 重命名分类目录（**预留**：手动“整理”功能用；自动迁移已按用户反馈取消）。
/// 失败返回错误。
pub fn renameCategoryDir(io: std.Io, data_root: []const u8, old_dir: []const u8, new_dir: []const u8) !void {
    var b1: [700]u8 = undefined;
    var b2: [700]u8 = undefined;
    const from = std.fmt.bufPrint(&b1, "{s}/presets/{s}", .{ data_root, old_dir }) catch return error.NameTooLong;
    const to = std.fmt.bufPrint(&b2, "{s}/presets/{s}", .{ data_root, new_dir }) catch return error.NameTooLong;
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, io) catch return error.IoFailure;
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

/// 扫描 `<data_root>/presets/*/`：一级子目录 = 分类，目录内 `*.sawpreset` = 预设。
/// **分类身份从文件读**（目录内首个预设的 `plugin` 字段；目录名仅展示）；
/// 空目录 → 身份=目录名（内置骨架占位目录）。分类/名字排序（浏览稳定）。
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
        const name_dup = allocator.dupe(u8, entry.name) catch continue;
        const dir_dup = allocator.dupe(u8, entry.name) catch {
            allocator.free(name_dup);
            continue;
        };
        var cat = Category{ .name = name_dup, .dir = dir_dup };
        errdefer cat.deinit(allocator);
        collectPresets(io, allocator, presets_dir, entry.name, &cat) catch {
            cat.deinit(allocator);
            continue;
        };
        // 身份/展示名从文件取（目录名只是展示层）
        if (cat.presets.items.len > 0) {
            var pb2: [600]u8 = undefined;
            const first = std.fmt.bufPrint(&pb2, "{s}/{s}/{s}{s}", .{ presets_dir, entry.name, cat.presets.items[0], extension }) catch "";
            if (first.len > 0) {
                if (std.Io.Dir.cwd().readFileAlloc(io, first, allocator, .limited(4 * 1024 * 1024))) |data| {
                    defer allocator.free(data);
                    if (std.json.parseFromSlice(MetaDisk, allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value.plugin.len > 0 and !std.mem.eql(u8, parsed.value.plugin, cat.name)) {
                            if (allocator.dupe(u8, parsed.value.plugin)) |ni| {
                                allocator.free(cat.name);
                                cat.name = ni;
                            } else |_| {}
                        }
                        if (parsed.value.name.len > 0 and std.mem.startsWith(u8, parsed.value.plugin, vst3_prefix)) {
                            if (allocator.dupe(u8, parsed.value.name)) |lb| cat.label = lb else |_| {}
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
        // 空目录：仅保留内置骨架占位（其它空目录——如删光预设残留的 VST3 目录——跳过）
        if (cat.presets.items.len == 0 and !isSkeletonName(entry.name)) {
            cat.deinit(allocator);
            continue;
        }
        lib.categories.append(allocator, cat) catch {
            cat.deinit(allocator);
            continue;
        };
    }

    // 排序：身份 → 目录名（同名多目录时顺序确定）
    std.mem.sort(Category, lib.categories.items, {}, struct {
        fn less(_: void, a: Category, b: Category) bool {
            const o = std.mem.order(u8, a.name, b.name);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.dir, b.dir) == .lt;
        }
    }.less);
    // **同一身份（CID）多个目录**（用户手动复制目录等）→ 只留排序第一
    // （否则浏览器里会出现两条同名分类互相兑位；被丢弃目录的文件仍在磁盘，
    //  挪进保留目录即重新可见）
    var di: usize = 1;
    while (di < lib.categories.items.len) {
        if (std.mem.eql(u8, lib.categories.items[di].name, lib.categories.items[di - 1].name)) {
            lib.categories.items[di].deinit(allocator);
            _ = lib.categories.orderedRemove(di);
        } else {
            di += 1;
        }
    }
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
    try std.testing.expectEqualStrings("future_plugin", pluginDisplayName("future_plugin"));
    // 置顶默认伪预设标签
    try std.testing.expectEqualStrings("（默认音色）", defaultPresetLabel(plugin_subtractive));
    try std.testing.expectEqualStrings("（默认套鼓）", defaultPresetLabel(plugin_drumkit));
    try std.testing.expectEqualStrings("（未实装）", defaultPresetLabel("future_plugin"));
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

test "preset：data 为 junction（scoop persist）时解析/建骨架/保存/扫描均穿透到目标" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // 目录布局：<tmp>/app（模拟 exe 旁）+ <tmp>/target（模拟 scoop persist）
    // <tmp>/app/data = 指到 target 的 junction。tmpDir 的 random 子路径保证可重入
    // （不清理也不影响下次运行）
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(base);
    const app = try std.fs.path.join(allocator, &.{ base, "app" });
    defer allocator.free(app);
    const target = try std.fs.path.join(allocator, &.{ base, "target" });
    defer allocator.free(target);
    const link = try std.fs.path.join(allocator, &.{ app, "data" });
    defer allocator.free(link);

    std.Io.Dir.cwd().createDirPath(io, app) catch {};
    std.Io.Dir.cwd().createDirPath(io, target) catch {};
    // mklink 用**绝对路径 + 反斜杠**（实测：相对路径报 "cannot find the path"；
    // 正斜杠会被 cmd 当选项开关："无效参数 - tmp"）
    const cwd = std.process.currentPathAlloc(io, allocator) catch return error.SkipZigTest;
    defer allocator.free(cwd);
    const link_abs = std.fs.path.join(allocator, &.{ cwd, link }) catch return error.SkipZigTest;
    defer allocator.free(link_abs);
    const target_abs = std.fs.path.join(allocator, &.{ cwd, target }) catch return error.SkipZigTest;
    defer allocator.free(target_abs);
    const link_win = allocator.dupe(u8, link_abs) catch return error.SkipZigTest;
    defer allocator.free(link_win);
    const target_win = allocator.dupe(u8, target_abs) catch return error.SkipZigTest;
    defer allocator.free(target_win);
    for (link_win) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    for (target_win) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    const mk = std.process.run(allocator, io, .{
        .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link_win, target_win },
    }) catch return error.SkipZigTest;
    defer allocator.free(mk.stdout);
    defer allocator.free(mk.stderr);
    switch (mk.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    // 1) 解析：data 是 junction（access 跟随）→ 应返回 <app>/data（而不是退 cwd）
    //    （分隔符按实现自拼的写法比较：resolveDataRoot 用 "{s}/data" 拼接）
    var root_buf: [512]u8 = undefined;
    const root = resolveDataRoot(io, app, &root_buf) orelse return error.TestUnexpectedResult;
    var exp_buf: [512]u8 = undefined;
    const expect_root = try std.fmt.bufPrint(&exp_buf, "{s}/data", .{app});
    try std.testing.expectEqualStrings(expect_root, root);

    // 2) 建骨架穿透 junction：presets/<分类> 出现在 target 内（而非 Link 表层）
    var skel_buf: [512]u8 = undefined;
    ensureSkeleton(io, root, &skel_buf);
    var chk_buf: [512]u8 = undefined;
    for (skeleton_dirs) |d| {
        const p = try std.fmt.bufPrint(&chk_buf, "{s}/presets/{s}", .{ target, d });
        std.Io.Dir.cwd().access(io, p, .{}) catch return error.TestUnexpectedResult;
    }

    // 3) 保存穿透：预设文件实际落在 target 里
    var p = @import("synth.zig").SynthParams{};
    p.attack.store(0.42, .monotonic);
    const saved = persist.exportSynth(&p);
    try save(io, allocator, root, plugin_subtractive, "JunctionTest", plugin_subtractive, saved);
    const fp = try std.fmt.bufPrint(&chk_buf, "{s}/presets/{s}/JunctionTest{s}", .{ target, plugin_subtractive, extension });
    std.Io.Dir.cwd().access(io, fp, .{}) catch return error.TestUnexpectedResult;

    // 4) 扫描穿透：通过 junction 能读到刚写的预设，且参数往返一致
    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    const ci = lib.findCategory(plugin_subtractive) orelse return error.NoCategory;
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items[ci].presets.items.len);
    try std.testing.expectEqualStrings("JunctionTest", lib.categories.items[ci].presets.items[0]);
    var parsed = try load(io, allocator, root, plugin_subtractive, "JunctionTest", plugin_subtractive);
    defer parsed.deinit();
    var q = @import("synth.zig").SynthParams{};
    persist.importSynth(&parsed.value.synth, &q);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), q.attack.load(.monotonic), 1e-6);
}

test "preset: vst3 分类 id 生成/解析 + v2 字段往返/旧文件兼容" {
    var buf: [48]u8 = undefined;
    const cid = "0102030405060708090a0b0c0d0e0f10";
    const id = vst3CategoryId(cid, &buf);
    try std.testing.expectEqualStrings("vst3_0102030405060708090a0b0c0d0e0f10", id);
    try std.testing.expectEqualStrings(cid, vst3CidFromCategory(id).?);
    try std.testing.expect(vst3CidFromCategory("subtractive") == null);
    try std.testing.expect(vst3CidFromCategory("vst3_short") == null);
    try std.testing.expect(vst3CidFromCategory("vst3_ZZ02030405060708090a0b0c0d0e0f10") == null); // 非 hex
    try std.testing.expect(vst3CategoryId("short", &buf).len == 0); // 长度不对 → 空

    const f = File{
        .version = 2,
        .plugin = id,
        .name = "Vital",
        .vendor = "Vital Audio",
        .last_path = "C:\\VST3\\Vital.vst3",
        .vst3_state = "AAEC",
        .vst3_state_ctrl = "",
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, f, .{});
    defer std.testing.allocator.free(json);
    // JSON 字段顺序 = 结构体声明序：可读信息在前，**不可读状态在文件末**
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":").? < std.mem.indexOf(u8, json, "\"osc\":").?);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"osc\":").? < std.mem.indexOf(u8, json, "\"vst3_state\":").?);
    var parsed = try std.json.parseFromSlice(File, std.testing.allocator, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Vital", parsed.value.name);
    try std.testing.expectEqualStrings(id, parsed.value.plugin);
    try std.testing.expectEqualStrings("AAEC", parsed.value.vst3_state);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.version);

    // 旧文件（无 v2 字段）→ 默认值，零影响
    var old = try std.json.parseFromSlice(File, std.testing.allocator, "{\"plugin\":\"subtractive\"}", .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer old.deinit();
    try std.testing.expectEqualStrings("subtractive", old.value.plugin);
    try std.testing.expectEqual(@as(u32, 1), old.value.version);
}

test "preset: 内建效果预设往返（effect 载荷；真实文件）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const bands = [_]persist.SavedEqBand{.{ .freq = 320, .gain_db = 3.5, .q = 2.0 }};
    const file = File{
        .version = 2,
        .plugin = plugin_fx_delay,
        .effect = .{ .kind = 3, .enabled = false, .mix = 0.42, .bands = &bands, .p = .{ 4, 0.6, 0, 0, 0 } },
    };
    try saveFile(io, allocator, root, plugin_fx_delay, "T1", file, false);
    var parsed = try load(io, allocator, root, plugin_fx_delay, "T1", plugin_fx_delay);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 3), parsed.value.effect.kind);
    try std.testing.expect(!parsed.value.effect.enabled);
    try std.testing.expectEqual(@as(f32, 0.42), parsed.value.effect.mix);
    try std.testing.expectEqual(@as(f32, 4), parsed.value.effect.p[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.effect.bands.len);
    try std.testing.expectEqual(@as(f32, 320), parsed.value.effect.bands[0].freq);
    // 分类显示名/默认行标签
    try std.testing.expectEqualStrings("延迟", pluginDisplayName(plugin_fx_delay));
    try std.testing.expectEqualStrings("（默认参数）", defaultPresetLabel(plugin_fx_delay));
}

test "preset: 目录名纯展示——身份从文件读（纯名目录）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const cid = "56545356746976616974616c00000000";
    var idbuf: [48]u8 = undefined;
    const id = vst3CategoryId(cid, &idbuf);
    var dirb: [200]u8 = undefined;
    const dir = categoryDirName("Vital", cid, false, &dirb);
    try std.testing.expectEqualStrings("Vital", dir); // 纯名（无后缀）

    try saveFile(io, allocator, root, dir, "Strážce", File{
        .version = 2,
        .plugin = id,
        .name = "Vital",
        .vendor = "Vital Audio",
        .vst3_state = "AA",
    }, false);
    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    // 身份 = 文件里的 plugin 字段（目录名只是展示）
    const ci = lib.findCategory(id) orelse return error.NoCategory;
    try std.testing.expectEqualStrings("Vital", lib.categories.items[ci].dir);
    try std.testing.expectEqualStrings("Vital", lib.categories.items[ci].label.?); // 卸载后仍可读的展示名
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items[ci].presets.items.len);
    // 按 dir 构建路径、按 id 校验
    var parsed = try load(io, allocator, root, dir, "Strážce", id);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(id, parsed.value.plugin); // CID 内嵌于分类 id

    // 哈希后缀（**仅同名冲突时用**）：确定性、不同 CID → 不同后缀
    var d2: [200]u8 = undefined;
    const dn = categoryDirName("TDR Nova", "0de7aef2de004e4f544f4249424d3754", true, &dirb);
    try std.testing.expect(std.mem.startsWith(u8, dn, "TDR Nova ("));
    try std.testing.expectEqual(@as(usize, "TDR Nova (".len + 8 + 1), dn.len);
    try std.testing.expectEqualStrings(dn, categoryDirName("TDR Nova", "0de7aef2de004e4f544f4249424d3754", true, &d2)); // 确定性
    try std.testing.expect(!std.mem.eql(u8, dn, categoryDirName("TDR Nova", "ff0de7aef2de004e4f544f4249424d3754", true, &d2))); // 不同 CID
    // 关键回归：TUID 前缀相似（Vital/TDR 实测）+ 直接截头会撞——哈希后缀不撞
    try std.testing.expect(!std.mem.eql(u8,
        categoryDirName("X", cid, true, &dirb),
        categoryDirName("X", "56545356746976616974616c00001000", true, &d2))); // 仅尾部不同
    // 清洗非法字符/空名兑底
    try std.testing.expectEqualStrings("a_b", categoryDirName("a/b", "0de7aef2de004e4f544f4249424d3754", false, &dirb));
    try std.testing.expectEqualStrings("VST3", categoryDirName("", "0de7aef2de004e4f544f4249424d3754", false, &dirb));
}

test "preset: 空目录跳过（非内置；如删光预设残留的 VST3 目录）+ 内置骨架保留" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var b: [600]u8 = undefined;
    std.Io.Dir.cwd().createDirPath(io, std.fmt.bufPrint(&b, "{s}/presets/subtractive", .{root}) catch return error.IoFailure) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, std.fmt.bufPrint(&b, "{s}/presets/Vital", .{root}) catch return error.IoFailure) catch return error.IoFailure;
    std.Io.Dir.cwd().createDirPath(io, std.fmt.bufPrint(&b, "{s}/presets/Junk", .{root}) catch return error.IoFailure) catch return error.IoFailure;

    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    try std.testing.expect(lib.findCategory("subtractive") != null); // 内置骨架空目录保留
    try std.testing.expect(lib.findCategory("Junk") == null); // 非内置空目录跳过
    try std.testing.expect(lib.findCategory("Vital") == null); // 删光预设残留的空 VST3 目录跳过
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items.len);
}

test "preset: 同一 CID 多目录 → 只留排序第一（防浏览器双份）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const cid = "56545356746976616974616c00000000";
    var idbuf: [48]u8 = undefined;
    const id = vst3CategoryId(cid, &idbuf);
    // 用户复制目录场景：Vital 与 "Vital - 副本"（同插件同 CID）
    try saveFile(io, allocator, root, "Vital", "A", File{ .version = 2, .plugin = id, .name = "Vital" }, false);
    try saveFile(io, allocator, root, "Vital - 副本", "B", File{ .version = 2, .plugin = id, .name = "Vital" }, false);

    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), lib.categories.items.len); // 只留一个
    try std.testing.expectEqualStrings("Vital", lib.categories.items[0].dir); // 确定性：字典序第一
    try std.testing.expectEqualStrings("A", lib.categories.items[0].presets.items[0]);
}

test "preset: 分类目录重命名（改名迁移原语；预留）" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const cid = "56545356746976616974616c00000000";
    var idbuf: [48]u8 = undefined;
    const id = vst3CategoryId(cid, &idbuf);
    try saveFile(io, allocator, root, "Vital", "Old", File{ .version = 2, .plugin = id, .name = "Vital" }, false);
    try renameCategoryDir(io, root, "Vital", "Vital Mk2");

    var lib = try scan(io, allocator, root);
    defer lib.deinit(allocator);
    const ci = lib.findCategory(id) orelse return error.NoCategory; // 身份不变
    try std.testing.expectEqualStrings("Vital Mk2", lib.categories.items[ci].dir);
    var pb: [600]u8 = undefined;
    try std.testing.expect(!pathExists(io, std.fmt.bufPrint(&pb, "{s}/presets/Vital", .{root}) catch return error.IoFailure));
    try std.testing.expect(pathExists(io, std.fmt.bufPrint(&pb, "{s}/presets/Vital Mk2", .{root}) catch return error.IoFailure));
}
