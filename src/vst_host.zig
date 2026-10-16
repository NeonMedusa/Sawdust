//! VST3 插件宿主（阶段 2）：模块加载 / 类枚举 / 效果器实例化 / 立体声 process。
//!
//! 线程约定：
//! - `scanModule` / `loadEffect` / `unloadPlugin` 在 **UI 线程**调用；
//! - `Plugin.process` 在 **音频线程**调用（内部零分配、零系统调用）。
//!
//! 音频缓冲：宿主侧是**交错立体声**（与引擎一致），插件边界转换为
//! **planar**（VST3 的音频总线是"每通道一平面"）。
//!
//! 已知边界（见 docs/plugin-hosting.md）：
//! - 暂无延迟补偿（`latency` 已读出，供后续使用）；
//! - 参数编辑/状态存档已接（阶段 4）：参数面板拖动 + `inputParameterChanges`、
//!   工程存档携带 `getState`（base64）；参数自动化（曲线）与干湿混合未做；
//! - 已验证插件：GuitarD（单组件）、TDR Nova（JUCE 分离式）、SFLT、Vital
//!   （**合成器/VSTi**——已验证控制器层：连接后参数正常；音频接入见阶段 5）。
//!
//! 互操作要点（实测踩坑，勿删）：
//! 1. `initialize(hostContext)` **不能传 null**（部分插件直接解引用）；
//! 2. **单组件插件也要 `setComponentHandler`**（否则编辑器一动 UI 就崩）；
//! 3. **分离式插件必须 `IConnectionPoint` 双向连接**（JUCE 不连则控制器 0 参数、
//!    `createView` 返回 null）；
//! 4. `setComponentState`：组件 state 经 `MemStream` 推给控制器（规范要求；
//!    JUCE 返回 E_NOTIMPL 属正常）。

const std = @import("std");
const vst3 = @import("zig_vst3");

/// 编辑器编辑环形队列长度（每条 16B；UI 每帧排空，容量按“极端扫动一帧上百条”留裕量）
const edit_ring_len = 256;
const ipb = vst3.pluginterfaces.base.ipluginbase;
const btypes = vst3.pluginterfaces.base.types;
const tuid = vst3.tuid;
const ivst = vst3.pluginterfaces.vst;
const icomp = ivst.ivstcomponent;
const iaudio = ivst.ivstaudioprocessor;
const iedit = ivst.ivsteditcontroller;
const vsttypes = ivst.vsttypes;
const vstspeaker = ivst.vstspeaker;
const iplugview = vst3.pluginterfaces.gui.iplugview;
const funknown = vst3.funknown;
const ivsthostapplication = vst3.pluginterfaces.vst.ivsthostapplication;
const ibstream = vst3.pluginterfaces.base.ibstream;
const ivstparameterchanges = vst3.pluginterfaces.vst.ivstparameterchanges;
const ivstevents = vst3.pluginterfaces.vst.ivstevents;
const ivstprocesscontext = vst3.pluginterfaces.vst.ivstprocesscontext;

fn uidEq(a: *const tuid.TUID, b: *const tuid.TUID) bool {
    return std.mem.eql(u8, a.*[0..], b.*[0..]);
}

/// UTF-16（VST3 TChar）→ UTF-8 定长缓冲（按码点安全截断）
fn copyUtf16ToUtf8(dst: []u8, dst_len: *u8, src16: []const u16) void {
    var out: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(src16);
    while (it.nextCodepoint() catch null) |cp| {
        const n = std.unicode.utf8Encode(cp, dst[out..]) catch break;
        if (out + n > dst.len) break;
        out += n;
    }
    dst_len.* = @intCast(@min(out, 255));
}

// ── IConnectionPoint（vst/ivstmessage.h；zig-vst3 未提供绑定，本地声明）──
// 分离式插件（JUCE 等）靠它把组件与控制器连起来共享内部实例：
// 不连接的话，控制器拿不到处理器（参数=0、createView 返回 null、无编辑器）。
const icp_iid = tuid.inlineUid(0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1);
const IConnectionPointVTable = extern struct {
    queryInterface: *const fn (*anyopaque, *const tuid.TUID, *?*anyopaque) callconv(.c) btypes.tresult,
    addRef: *const fn (*anyopaque) callconv(.c) btypes.uint32,
    release: *const fn (*anyopaque) callconv(.c) btypes.uint32,
    connect: *const fn (*anyopaque, ?*IConnectionPoint) callconv(.c) btypes.tresult,
    disconnect: *const fn (*anyopaque, ?*IConnectionPoint) callconv(.c) btypes.tresult,
    notify: *const fn (*anyopaque, ?*anyopaque) callconv(.c) btypes.tresult,
};
const IConnectionPoint = extern struct {
    vtable: *const IConnectionPointVTable,
};

/// 组件↔控制器双向连接/断开（分离式插件必需）。
fn bridgeComponentController(
    raw_component: *anyopaque,
    component: *const icomp.IComponent,
    controller: *const iedit.IEditController,
    raw_ctrl: *anyopaque,
    do_connect: bool,
) void {
    var comp_cp_raw: ?*anyopaque = null;
    if (component.vtable.queryInterface(raw_component, &icp_iid, &comp_cp_raw) != btypes.kResultOk or comp_cp_raw == null) return;
    var comp_cp: *IConnectionPoint = @ptrCast(@alignCast(comp_cp_raw.?));
    var ctrl_cp_raw: ?*anyopaque = null;
    if (controller.vtable.queryInterface(raw_ctrl, &icp_iid, &ctrl_cp_raw) != btypes.kResultOk or ctrl_cp_raw == null) {
        _ = comp_cp.vtable.release(comp_cp_raw.?);
        return;
    }
    var ctrl_cp: *IConnectionPoint = @ptrCast(@alignCast(ctrl_cp_raw.?));
    const action_comp = if (do_connect) comp_cp.vtable.connect else comp_cp.vtable.disconnect;
    const action_ctrl = if (do_connect) ctrl_cp.vtable.connect else ctrl_cp.vtable.disconnect;
    _ = action_comp(comp_cp_raw.?, ctrl_cp);
    _ = action_ctrl(ctrl_cp_raw.?, comp_cp);
    _ = ctrl_cp.vtable.release(ctrl_cp_raw.?);
    _ = comp_cp.vtable.release(comp_cp_raw.?);
}

/// 进程级宿主上下文：FUnknown + IHostApplication + IComponentHandler 三接口合一。
/// - `initialize`（组件与控制器）必须传 IHostApplication：**不少插件直接解引用它**（如 TDR Nova），
///   传 null 会在插件内部段错误；
/// - `setComponentHandler` 传 IComponentHandler：部分插件（如 TDR Nova）没有它时
///   `createView` 返回 null（无法开界面）。
/// 自动化方法（beginEdit/performEdit/endEdit）暂为记账占位（阶段 4 接参数编辑时再接）。
const HostCtx = extern struct {
    const Self = @This();

    host_iface: ivsthostapplication.IHostApplication = .{ .vtable = &host_vtable },
    handler_iface: iedit.IComponentHandler = .{ .vtable = &handler_vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    fn hostOwner(ptr: *anyopaque) *Self {
        return @fieldParentPtr("host_iface", @as(*ivsthostapplication.IHostApplication, @ptrCast(@alignCast(ptr))));
    }
    fn handlerOwner(ptr: *anyopaque) *Self {
        return @fieldParentPtr("handler_iface", @as(*iedit.IComponentHandler, @ptrCast(@alignCast(ptr))));
    }

    fn hostQuery(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        const self = hostOwner(ptr);
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &ivsthostapplication.ihost_application_iid)) {
            _ = hostAddRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        if (uidEq(iid, &iedit.icomponent_handler_iid)) {
            _ = hostAddRef(ptr);
            out.* = &self.handler_iface;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }

    fn handlerQuery(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        const self = handlerOwner(ptr);
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &iedit.icomponent_handler_iid)) {
            _ = handlerAddRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        if (uidEq(iid, &ivsthostapplication.ihost_application_iid)) {
            _ = handlerAddRef(ptr);
            out.* = &self.host_iface;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }

    fn hostAddRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return hostOwner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn hostRelease(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return hostOwner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn handlerAddRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return handlerOwner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn handlerRelease(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return handlerOwner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }

    fn getName(_: *anyopaque, out: [*]vsttypes.TChar) callconv(.c) btypes.tresult {
        const name = "Sawdust";
        for (name, 0..) |ch, i| out[i] = @as(u16, ch);
        out[name.len] = 0;
        return btypes.kResultOk;
    }

    fn createInstance(_: *anyopaque, _: *const tuid.TUID, _: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        out.* = null;
        return btypes.kResultFalse;
    }

    fn beginEdit(_: *anyopaque, _: vsttypes.ParamID) callconv(.c) btypes.tresult {
        return btypes.kResultOk;
    }
    fn performEdit(_: *anyopaque, _: vsttypes.ParamID, _: vsttypes.ParamValue) callconv(.c) btypes.tresult {
        return btypes.kResultOk;
    }
    fn endEdit(_: *anyopaque, _: vsttypes.ParamID) callconv(.c) btypes.tresult {
        return btypes.kResultOk;
    }
    fn restartComponent(_: *anyopaque, _: btypes.int32) callconv(.c) btypes.tresult {
        return btypes.kResultOk;
    }

    const host_vtable = ivsthostapplication.IHostApplicationVTable{
        .queryInterface = hostQuery,
        .addRef = hostAddRef,
        .release = hostRelease,
        .getName = getName,
        .createInstance = createInstance,
    };
    const handler_vtable = iedit.IComponentHandlerVTable{
        .queryInterface = handlerQuery,
        .addRef = handlerAddRef,
        .release = handlerRelease,
        .beginEdit = beginEdit,
        .performEdit = performEdit,
        .endEdit = endEdit,
        .restartComponent = restartComponent,
    };
};
var host_ctx: HostCtx = .{};

/// 宿主侧内存流（IBStream）：用于组件 state → 控制器传递（`setComponentState`）。
/// 规范：分离式插件在“使用控制器”（含开编辑器）前，宿主必须把组件 state 推给它。
const MemStream = struct {
    const Self = @This();

    iface: ibstream.IBStream = .{ .vtable = &vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    pos: usize = 0,

    fn asIface(self: *Self) *ibstream.IBStream {
        return &self.iface;
    }

    /// 以已有字节初始化（读位置 0）
    fn initWith(allocator: std.mem.Allocator, bytes: []const u8) MemStream {
        var ms = MemStream{ .alloc = allocator };
        ms.buf.appendSlice(allocator, bytes) catch {}; // OOM：空流（安全降级）
        ms.pos = 0;
        return ms;
    }

    fn owner(ptr: *anyopaque) *Self {
        return @fieldParentPtr("iface", @as(*ibstream.IBStream, @ptrCast(@alignCast(ptr))));
    }

    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &ibstream.ibstream_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }

    fn read(ptr: *anyopaque, buffer: ?*anyopaque, num_bytes: i32, num_read: ?*i32) callconv(.c) btypes.tresult {
        const self = owner(ptr);
        if (num_bytes < 0) {
            if (num_read) |nr| nr.* = 0;
            return btypes.kResultFalse;
        }
        const want: usize = @intCast(num_bytes);
        const avail = if (self.pos < self.buf.items.len) self.buf.items.len - self.pos else 0;
        const n = @min(want, avail);
        if (n > 0) {
            if (buffer) |b| {
                const dst: [*]u8 = @ptrCast(b);
                @memcpy(dst[0..n], self.buf.items[self.pos .. self.pos + n]);
            }
            self.pos += n;
        }
        if (num_read) |nr| nr.* = @intCast(n);
        return btypes.kResultOk; // EOF 不算错误（按实际读取量报告）
    }

    fn write(ptr: *anyopaque, buffer: ?*anyopaque, num_bytes: i32, num_written: ?*i32) callconv(.c) btypes.tresult {
        const self = owner(ptr);
        if (num_bytes < 0 or buffer == null) {
            if (num_written) |nw| nw.* = 0;
            return btypes.kResultFalse;
        }
        const n: usize = @intCast(num_bytes);
        const end = self.pos + n;
        if (end > self.buf.items.len) {
            const old_len = self.buf.items.len;
            self.buf.resize(self.alloc, end) catch {
                if (num_written) |nw| nw.* = 0;
                return btypes.kResultFalse;
            };
            @memset(self.buf.items[old_len..], 0); // 跳位/新区域总是零填（确定性）
        }
        if (n > 0) {
            const src: [*]const u8 = @ptrCast(buffer.?);
            @memcpy(self.buf.items[self.pos..end], src[0..n]);
            self.pos = end;
        }
        if (num_written) |nw| nw.* = @intCast(n);
        return btypes.kResultOk;
    }

    fn seek(ptr: *anyopaque, pos: i64, mode: i32, result: ?*i64) callconv(.c) btypes.tresult {
        const self = owner(ptr);
        // IStreamSeekMode：0=kIBSeekSet 1=kIBSeekCur 2=kIBSeekEnd
        const base: i64 = switch (mode) {
            @intFromEnum(ibstream.IStreamSeekMode.kIBSeekSet) => 0,
            @intFromEnum(ibstream.IStreamSeekMode.kIBSeekCur) => @intCast(self.pos),
            @intFromEnum(ibstream.IStreamSeekMode.kIBSeekEnd) => @intCast(self.buf.items.len),
            else => return btypes.kResultFalse,
        };
        const new_pos = base + pos;
        if (new_pos < 0) return btypes.kResultFalse;
        self.pos = @intCast(new_pos);
        if (result) |r| r.* = new_pos;
        return btypes.kResultOk;
    }

    fn tell(ptr: *anyopaque, pos: *i64) callconv(.c) btypes.tresult {
        pos.* = @intCast(owner(ptr).pos);
        return btypes.kResultOk;
    }

    fn deinit(self: *Self) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    const vtable = ibstream.IBStreamVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .read = read,
        .write = write,
        .seek = seek,
        .tell = tell,
    };
};

/// 注：用 **LoadLibraryW**（ANSI 版按系统代码页解释路径——含中文等非 ANSI
/// 字符的路径会解析失败；实测“GuitarD - 副本.vst3”加载失败而 ASCII 名可用）。
extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetErrorMode(u32) callconv(.winapi) u32;

/// 抑制 loader 硬错误弹框（**实测教训**：`LoadLibraryA` 一个损坏/0 字节镜像时，
/// Windows 会弹**模态**“损坏的映像”框并卡住进程——扫描目录里的垃圾 dll 时
/// 每条垃圾卡一次；宿主标配）。SEM_FAILCRITICALERRORS 抑制硬错误框，
/// SEM_NOGPFAULTERRORBOX 抑制默认异常框；子进程继承（worker 也安静）。
const SEM_FAILCRITICALERRORS: u32 = 0x0001;
const SEM_NOGPFAULTERRORBOX: u32 = 0x0002;
var error_mode_set: bool = false;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// ── 参数变更基础设施（阶段 4；音频线程零分配）──

/// 宿主 → 插件的一次参数设置（SPSC 环元素）
const ParamMsg = struct { id: u32, value: f64 };

/// 宿主时间信息（每秒同步给插件的 ProcessContext —— tempo 同步类插件
/// （delay/arp/LFO）必需；由音频层按**段**计算）
pub const HostTime = struct {
    playing: bool = false,
    tempo: f64 = 120,
    time_num: i32 = 4,
    time_den: i32 = 4,
    /// 段起点的绝对播放帧（projectTimeSamples / continousTimeSamples）
    abs_samples: u64 = 0,
    /// 段起点的音乐位置（四分音符数；仅播放中有效）
    ppq: f64 = 0,
};

/// 一次插件 GUI 内的参数编辑（轮询出来供面板同步/标脏）
pub const ParamEdit = struct { id: u32, value: f64 };

/// 编辑器参数交互事件种类（`IComponentHandler` 的 begin/perform/end 三件套）
pub const EditEventKind = enum(u8) { begin = 0, perform = 1, end = 2 };

/// 一条编辑器交互事件（环形队列元素；begin/end 的 value 无义）
pub const EditEvent = struct { kind: EditEventKind, id: u32, value: f64 };

/// `IComponentHandler::restartComponent` 标志（Vst::RestartFlags 子集）
pub const kLatencyChanged: i32 = 1 << 3;

/// 视为“文档可能已改”的 restart 标志：kReloadComponent | kParamValuesChanged |
/// kParamTitlesChanged | kRoutingInfoChanged。
/// （实测：GuitarD 增/删单块 = kParamTitlesChanged；JUCE 状态恢复后必发 kParamValuesChanged
/// ——后者靠调用方的宽限期过滤）
pub const kDirtyRestartFlags: i32 = 0x1 | 0x4 | 0x10 | 0x200;

/// 插件状态快照（组件 + 控制器各一份；调用方负责释放）
pub const StateBlobs = struct {
    comp: []u8 = &.{},
    ctrl: []u8 = &.{},

    pub fn deinit(self: StateBlobs, allocator: std.mem.Allocator) void {
        if (self.comp.len > 0) allocator.free(self.comp);
        if (self.ctrl.len > 0) allocator.free(self.ctrl);
    }
};

/// 单个参数的元数据（加载时抓取；名称/单位已转 UTF-8 限长存储）
pub const ParamMeta = struct {
    id: u32 = 0,
    name_buf: [48]u8 = [_]u8{0} ** 48,
    name_len: u8 = 0,
    units_buf: [16]u8 = [_]u8{0} ** 16,
    units_len: u8 = 0,
    /// 0 = 连续；>0 = 离散步数
    step_count: i32 = 0,
    default_norm: f64 = 0,
    flags: i32 = 0,

    pub fn name(self: *const ParamMeta) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn units(self: *const ParamMeta) []const u8 {
        return self.units_buf[0..self.units_len];
    }
};

/// 宿主侧 IParamValueQueue：一条参数在本块内的单点（offset 0）
const ParamValueQueue = extern struct {
    iface: ivstparameterchanges.IParamValueQueue = .{ .vtable = &vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    id: u32 = 0,
    value: f64 = 0,
    used: bool = false,

    fn owner(ptr: *anyopaque) *ParamValueQueue {
        return @fieldParentPtr("iface", @as(*ivstparameterchanges.IParamValueQueue, @ptrCast(@alignCast(ptr))));
    }
    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &ivstparameterchanges.iparam_value_queue_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn getParameterId(ptr: *anyopaque) callconv(.c) vsttypes.ParamID {
        return owner(ptr).id;
    }
    fn getPointCount(ptr: *anyopaque) callconv(.c) btypes.int32 {
        return if (owner(ptr).used) 1 else 0;
    }
    fn getPoint(ptr: *anyopaque, index: btypes.int32, sample_offset: *btypes.int32, value: *vsttypes.ParamValue) callconv(.c) btypes.tresult {
        const self = owner(ptr);
        if (index != 0 or !self.used) return btypes.kResultFalse;
        sample_offset.* = 0;
        value.* = self.value;
        return btypes.kResultOk;
    }
    fn addPoint(_: *anyopaque, _: btypes.int32, _: vsttypes.ParamValue, _: *btypes.int32) callconv(.c) btypes.tresult {
        return btypes.kResultFalse; // 宿主侧输入队列：插件不写入
    }

    const vtable = ivstparameterchanges.IParamValueQueueVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .getParameterId = getParameterId,
        .getPointCount = getPointCount,
        .getPoint = getPoint,
        .addPoint = addPoint,
    };
};

/// 宿主侧 IParameterChanges：包住本块弹出的若干 ParamValueQueue
const ParamChanges = struct {
    iface: ivstparameterchanges.IParameterChanges = .{ .vtable = &vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    count: u32 = 0,
    queues: [8]*ivstparameterchanges.IParamValueQueue = undefined,

    /// 绑定所属 Plugin 的队列数组（地址稳定；加载时调一次）
    fn setQueues(self: *ParamChanges, src: *[8]ParamValueQueue) void {
        for (0..8) |i| self.queues[i] = &src[i].iface;
    }

    fn owner(ptr: *anyopaque) *ParamChanges {
        return @fieldParentPtr("iface", @as(*ivstparameterchanges.IParameterChanges, @ptrCast(@alignCast(ptr))));
    }
    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &ivstparameterchanges.iparameter_changes_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn getParameterCount(ptr: *anyopaque) callconv(.c) btypes.int32 {
        return @intCast(owner(ptr).count);
    }
    fn getParameterData(ptr: *anyopaque, index: btypes.int32) callconv(.c) ?*ivstparameterchanges.IParamValueQueue {
        const self = owner(ptr);
        if (index < 0 or @as(u32, @intCast(index)) >= self.count) return null;
        return self.queues[@intCast(index)];
    }
    fn addParameterData(_: *anyopaque, _: *const vsttypes.ParamID, index: *btypes.int32) callconv(.c) ?*ivstparameterchanges.IParamValueQueue {
        index.* = 0;
        return null; // 宿主侧：插件只读
    }

    const vtable = ivstparameterchanges.IParameterChangesVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .getParameterCount = getParameterCount,
        .getParameterData = getParameterData,
        .addParameterData = addParameterData,
    };
};

/// 宿主侧 IEventList（输入事件；插件只读）。事件在**段边界以 offset 0 生效**——
/// 宿主把音频块按事件时刻切段，每段调用一次（与内部合成器同一分段机制）。
const EventList = struct {
    iface: ivstevents.IEventList = .{ .vtable = &vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    count: u32 = 0,
    events: [128]ivstevents.Event = [_]ivstevents.Event{.{}} ** 128,

    fn owner(ptr: *anyopaque) *EventList {
        return @fieldParentPtr("iface", @as(*ivstevents.IEventList, @ptrCast(@alignCast(ptr))));
    }
    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &ivstevents.ievent_list_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return owner(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn getEventCount(ptr: *anyopaque) callconv(.c) btypes.int32 {
        return @intCast(owner(ptr).count);
    }
    fn getEvent(ptr: *anyopaque, index: btypes.int32, out: *ivstevents.Event) callconv(.c) btypes.tresult {
        const self = owner(ptr);
        if (index < 0 or @as(u32, @intCast(index)) >= self.count) return btypes.kResultFalse;
        out.* = self.events[@intCast(index)];
        return btypes.kResultOk;
    }
    fn addEvent(_: *anyopaque, _: *ivstevents.Event) callconv(.c) btypes.tresult {
        return btypes.kResultFalse; // 宿主侧输入列表：插件只读
    }

    const vtable = ivstevents.IEventListVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .getEventCount = getEventCount,
        .getEvent = getEvent,
        .addEvent = addEvent,
    };
};

/// 每插件 IComponentHandler：记录插件 GUI 内的参数编辑与 restart 请求（UI 线程轮询）
const PluginHandler = extern struct {
    /// 调查开关：打印插件对 handler 的 query IID 与 restart 请求（调查已完成，关闭）
    const debug_log = false;

    iface: iedit.IComponentHandler = .{ .vtable = &vtable },
    iface2: iedit.IComponentHandler2 = .{ .vtable = &vtable2 },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    owner: ?*Plugin = null,

    pub fn asInterface(self: *PluginHandler) *iedit.IComponentHandler {
        return &self.iface;
    }
    pub fn asInterface2(self: *PluginHandler) *iedit.IComponentHandler2 {
        return &self.iface2;
    }

    fn ownerOf(ptr: *anyopaque) *PluginHandler {
        return @fieldParentPtr("iface", @as(*iedit.IComponentHandler, @ptrCast(@alignCast(ptr))));
    }
    fn ownerOf2(ptr: *anyopaque) *PluginHandler {
        return @fieldParentPtr("iface2", @as(*iedit.IComponentHandler2, @ptrCast(@alignCast(ptr))));
    }
    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (debug_log) std.debug.print("[vst] handler 被查询 iid={x}（FUnknown={} IComponentHandler={} IComponentHandler2={}）\n", .{
            iid.*[0..],
            uidEq(iid, &funknown.iid),
            uidEq(iid, &iedit.icomponent_handler_iid),
            uidEq(iid, &iedit.icomponent_handler2_iid),
        });
        const self = ownerOf(ptr);
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &iedit.icomponent_handler_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        if (uidEq(iid, &iedit.icomponent_handler2_iid)) {
            _ = addRef(ptr);
            out.* = &self.iface2;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn query2(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        const self = ownerOf2(ptr);
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &iedit.icomponent_handler2_iid)) {
            _ = addRef2(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        if (uidEq(iid, &iedit.icomponent_handler_iid)) {
            _ = addRef2(ptr);
            out.* = &self.iface;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }
    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return ownerOf(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return ownerOf(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn addRef2(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return ownerOf2(ptr).ref_count.fetchAdd(1, .seq_cst) + 1;
    }
    fn release2(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        return ownerOf2(ptr).ref_count.fetchSub(1, .seq_cst) - 1;
    }
    fn beginEdit(ptr: *anyopaque, id: vsttypes.ParamID) callconv(.c) btypes.tresult {
        if (ownerOf(ptr).owner) |pl| pl.recordEditEvent(.begin, id, 0);
        return btypes.kResultOk;
    }
    fn performEdit(ptr: *anyopaque, id: vsttypes.ParamID, value: vsttypes.ParamValue) callconv(.c) btypes.tresult {
        if (ownerOf(ptr).owner) |pl| pl.recordEditEvent(.perform, id, value);
        return btypes.kResultOk;
    }
    fn endEdit(ptr: *anyopaque, id: vsttypes.ParamID) callconv(.c) btypes.tresult {
        if (ownerOf(ptr).owner) |pl| pl.recordEditEvent(.end, id, 0);
        return btypes.kResultOk;
    }
    fn restartComponent(ptr: *anyopaque, flags: btypes.int32) callconv(.c) btypes.tresult {
        if (debug_log) std.debug.print("[vst] restartComponent flags={d}\n", .{flags});
        const self = ownerOf(ptr);
        if (self.owner) |pl| _ = pl.restart_flags.fetchOr(flags, .acq_rel);
        return btypes.kResultOk;
    }

    // ── IComponentHandler2：setDirty / requestOpenEditor / 分组编辑 ──

    fn setDirty(ptr: *anyopaque, state: btypes.TBool) callconv(.c) btypes.tresult {
        if (debug_log) std.debug.print("[vst] handler setDirty state={d}\n", .{state});
        const self = ownerOf2(ptr);
        if (self.owner) |pl| {
            if (state != 0) _ = pl.dirty_seq.fetchAdd(1, .release);
        }
        return btypes.kResultOk;
    }
    fn requestOpenEditor(ptr: *anyopaque, _: btypes.FIDString) callconv(.c) btypes.tresult {
        const self = ownerOf2(ptr);
        if (self.owner) |pl| pl.open_editor_req.store(true, .release);
        return btypes.kResultOk;
    }
    fn startGroupEdit(_: *anyopaque) callconv(.c) btypes.tresult {
        // IComponentHandler2 分组编辑：暂不参与手势切分（将来：组内禁按参数切）
        return btypes.kResultOk;
    }
    fn finishGroupEdit(_: *anyopaque) callconv(.c) btypes.tresult {
        return btypes.kResultOk;
    }

    const vtable2 = iedit.IComponentHandler2VTable{
        .queryInterface = query2,
        .addRef = addRef2,
        .release = release2,
        .setDirty = setDirty,
        .requestOpenEditor = requestOpenEditor,
        .startGroupEdit = startGroupEdit,
        .finishGroupEdit = finishGroupEdit,
    };

    const vtable = iedit.IComponentHandlerVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .beginEdit = beginEdit,
        .performEdit = performEdit,
        .endEdit = endEdit,
        .restartComponent = restartComponent,
    };
};

pub const MaxClasses = 32;
pub const MaxBuses = 64;

/// 插件角色：效果器（需主输入）/ 乐器（VSTi；无主输入，主输出即可）
pub const Role = enum { effect, instrument };

/// 一个 VST3 类的元数据（固定缓冲；零分配、可值传递）
pub const ModuleClass = struct {
    cid: tuid.TUID = tuid.zero,
    category_buf: [32]u8 = [_]u8{0} ** 32,
    category_len: u16 = 0,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u16 = 0,
    vendor_buf: [64]u8 = [_]u8{0} ** 64,
    vendor_len: u16 = 0,
    version_buf: [64]u8 = [_]u8{0} ** 64,
    version_len: u16 = 0,
    /// 子类别（v2 类信息；“Instrument|Synth” 等——乐器识别用）
    sub_buf: [64]u8 = [_]u8{0} ** 64,
    sub_len: u16 = 0,

    pub fn category(self: *const ModuleClass) []const u8 {
        return self.category_buf[0..self.category_len];
    }
    pub fn subCategories(self: *const ModuleClass) []const u8 {
        return self.sub_buf[0..self.sub_len];
    }
    /// 是否乐器类（子类别含 "Instrument"）
    pub fn isInstrument(self: *const ModuleClass) bool {
        return std.mem.indexOf(u8, self.subCategories(), "Instrument") != null;
    }
    pub fn name(self: *const ModuleClass) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn vendor(self: *const ModuleClass) []const u8 {
        return self.vendor_buf[0..self.vendor_len];
    }
    pub fn version(self: *const ModuleClass) []const u8 {
        return self.version_buf[0..self.version_len];
    }
    /// 是否音频效果器类（"Audio Module Class"）
    pub fn isAudioEffect(self: *const ModuleClass) bool {
        return std.mem.eql(u8, self.category(), std.mem.span(iaudio.kVstAudioEffectClass));
    }
};

/// 一次模块扫描的结果（最多 `MaxClasses` 个类）
pub const Scan = struct {
    classes: [MaxClasses]ModuleClass = [_]ModuleClass{.{}} ** MaxClasses,
    len: usize = 0,

    pub fn slice(self: *const Scan) []const ModuleClass {
        return self.classes[0..self.len];
    }
};

/// 已加载的模块（工厂句柄）
const Mod = struct {
    lib: *anyopaque,
    raw_factory: *anyopaque,
    factory: *const ipb.IPluginFactory,

    fn deinit(self: Mod) void {
        _ = FreeLibrary(self.lib);
    }
};

fn loadModule(path: [:0]const u8) !Mod {
    // 首次加载前抑制 loader 弹框（见 SetErrorMode 注释；咽喉点——主程序/worker/
    // 测试所有加载都经此，不会漏）
    if (!error_mode_set) {
        error_mode_set = true;
        _ = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    }
    // **必须 LoadLibraryW**：ANSI 版按系统代码页解路径，中文名会加载失败
    // （实测 bug）。UTF-8 → UTF-16 走栈缓冲（UTF-16 长度 ≤ UTF-8 字节数）
    var wbuf: [2048]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return error.InvalidPath;
    if (wlen >= wbuf.len) return error.PathTooLong;
    wbuf[wlen] = 0;
    const lib = LoadLibraryW(@ptrCast(&wbuf)) orelse return error.LoadLibraryFailed;
    errdefer _ = FreeLibrary(lib);
    // InitDll（可选导出：初始化模块全局状态）
    if (GetProcAddress(lib, "InitDll")) |fp| {
        const f: *const fn () callconv(.c) bool = @ptrCast(fp);
        _ = f();
    }
    const gp = GetProcAddress(lib, "GetPluginFactory") orelse return error.NoGetPluginFactory;
    const get_factory: *const fn () callconv(.c) ?*anyopaque = @ptrCast(gp);
    const raw = get_factory() orelse return error.NullFactory;
    return .{
        .lib = lib,
        .raw_factory = raw,
        .factory = @ptrCast(@alignCast(raw)),
    };
}

/// 扬声器布局掩码 → 通道数（popcount；多输出总线记账用）
fn speakerChannelCount(arr: vsttypes.SpeakerArrangement) usize {
    var v: u64 = arr;
    var n: usize = 0;
    while (v != 0) : (v &= v - 1) n += 1;
    return n;
}

fn copyTo(dst: []u8, dst_len: *u16, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst_len.* = @intCast(n);
}

fn tidToFid(cid: *const tuid.TUID) btypes.FIDString {
    return @ptrCast(cid);
}

fn collectClasses(m: Mod, out: *Scan) void {
    // 工厂级厂商名（v1 类无 vendor 时兜底）
    var fi: ipb.PFactoryInfo = .{};
    _ = m.factory.vtable.getFactoryInfo(m.raw_factory, &fi);
    const fac_vendor = std.mem.sliceTo(&fi.vendor, 0);

    // 尽量升到 IPluginFactory2（拿 厂商/版本）
    var raw2: ?*anyopaque = null;
    const f2: ?*const ipb.IPluginFactory2 = if (m.factory.vtable.queryInterface(m.raw_factory, &ipb.iplugin_factory2_iid, &raw2) == btypes.kResultOk and raw2 != null)
        @ptrCast(@alignCast(raw2.?))
    else
        null;

    const n = m.factory.vtable.countClasses(m.raw_factory);
    const cnt: usize = if (n > 0) @intCast(n) else 0;
    var i: usize = 0;
    while (i < cnt and out.len < MaxClasses) : (i += 1) {
        var ci: ipb.PClassInfo = .{};
        if (m.factory.vtable.getClassInfo(m.raw_factory, @intCast(i), &ci) != btypes.kResultOk) continue;
        var mc = ModuleClass{};
        mc.cid = ci.cid;
        copyTo(&mc.category_buf, &mc.category_len, std.mem.sliceTo(&ci.category, 0));
        copyTo(&mc.name_buf, &mc.name_len, std.mem.sliceTo(&ci.name, 0));
        var vendor: []const u8 = fac_vendor;
        var ver: []const u8 = "";
        if (f2) |f| {
            var c2: ipb.PClassInfo2 = .{};
            if (f.vtable.getClassInfo2(raw2.?, @intCast(i), &c2) == btypes.kResultOk) {
                ver = std.mem.sliceTo(&c2.version, 0);
                const v2 = std.mem.sliceTo(&c2.vendor, 0);
                if (v2.len > 0) vendor = v2;
                copyTo(&mc.sub_buf, &mc.sub_len, std.mem.sliceTo(&c2.subCategories, 0));
            }
        }
        copyTo(&mc.vendor_buf, &mc.vendor_len, vendor);
        copyTo(&mc.version_buf, &mc.version_len, ver);
        out.classes[out.len] = mc;
        out.len += 1;
    }
}

/// 扫描一个 `.vst3` 模块（加载 → 枚举全部类 → 卸载）
/// 诊断：打印模块中**第一个音频类**的全部总线布局（`Sawdust --vst-scan --buses` 用）——
/// 多输出插件（如 SFLT 0进17出）支持前的探测：总线数/类型/通道数/默认激活位。
pub fn dumpBuses(path: [:0]const u8) !void {
    const m = try loadModule(path);
    var s = Scan{};
    collectClasses(m, &s);
    var cid: ?tuid.TUID = null;
    var cname: []const u8 = "";
    for (s.slice()) |*c| {
        if (!c.isAudioEffect()) continue;
        cid = c.cid;
        cname = c.name();
        break;
    }
    const class_cid = cid orelse return error.NoEffectClass;
    std.debug.print("类：{s}\n", .{cname});
    var raw_comp: ?*anyopaque = null;
    if (m.factory.vtable.createInstance(m.raw_factory, tidToFid(&class_cid), tidToFid(&icomp.icomponent_iid), &raw_comp) != btypes.kResultOk or raw_comp == null) return error.CreateComponentFailed;
    const raw_component = raw_comp.?;
    const component: *const icomp.IComponent = @ptrCast(@alignCast(raw_component));
    defer _ = component.vtable.release(raw_component);
    if (component.vtable.initialize(raw_component, &host_ctx.host_iface) != btypes.kResultOk) return error.InitializeFailed;
    defer _ = component.vtable.terminate(raw_component);

    inline for ([_]struct { d: icomp.BusDirections, t: icomp.MediaTypes, label: []const u8 }{
        .{ .d = .kInput, .t = .kAudio, .label = "in" },
        .{ .d = .kOutput, .t = .kAudio, .label = "out" },
    }) |side| {
        const n = component.vtable.getBusCount(raw_component, @intFromEnum(side.t), @intFromEnum(side.d));
        std.debug.print("[{s}] 总线数 {d}\n", .{ side.label, n });
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            var bi: icomp.BusInfo = .{};
            _ = component.vtable.getBusInfo(raw_component, @intFromEnum(side.t), @intFromEnum(side.d), i, &bi);
            const is_main = bi.busType == @intFromEnum(icomp.BusTypes.kMain);
            std.debug.print("  [{s}{d}] {s} 通道={d} 默认激活={} flags={d}\n", .{
                side.label,
                i,
                if (is_main) "主 " else "辅助",
                bi.channelCount,
                (bi.flags & icomp.BusFlags.kDefaultActive) != 0,
                bi.flags,
            });
        }
    }
}

/// 扫描一个模块：加载 + 枚举全部工厂类（不实例化组件）。
pub fn scanModule(path: [:0]const u8) !Scan {
    const m = try loadModule(path);
    defer m.deinit();
    var s = Scan{};
    collectClasses(m, &s);
    return s;
}

// ── 插件实例 ──

/// 多输出 VSTi 混音策略：true = 全部激活总线**求和**（默认——不丢声：无论音频
/// 落在主还是辅助总线都能听见）；false = 只取主总线（若某插件主输出是各辅助的
/// 镜像，求和会音量翻倍 → 用户实测后改 false 重编）。
pub const vsti_sum_all_buses = true;

/// 调查开关：加载时打印总线协商结果（调试用；默认关）
const bus_debug = false;

pub const Plugin = struct {
    mod: Mod,
    raw_component: *anyopaque,
    component: *const icomp.IComponent,
    raw_processor: *anyopaque,
    processor: *const iaudio.IAudioProcessor,
    /// 分离组件时独立存在；单组件插件 == component
    raw_controller: ?*anyopaque = null,
    controller: ?*const iedit.IEditController = null,
    /// 宿主 allocator（加载时写入；编辑器窗口等分配用）
    alloc: std.mem.Allocator,

    // ── 编辑器（阶段 3；仅 UI 线程）──
    /// 已挂接的编辑器视图（打开中）
    view: ?*iplugview.IPlugView = null,
    /// 编辑器**子窗口**句柄（挂在主窗口内；打开中）
    editor_hwnd: ?*anyopaque = null,
    /// 子窗口是否已**首次显示**（创建时隐藏——先定位再 ShowWindow，
    /// 否则会在主窗 (0,0) 左上角闪现一个小黑框，实测）
    editor_shown: bool = false,
    /// 宿主侧 IPlugFrame 实例（打开中）
    frame: ?*EditorFrame = null,
    /// 插件请求的内容尺寸（面板按它定尺寸；`resizeView` 更新）
    editor_w: i32 = 0,
    editor_h: i32 = 0,
    /// 子窗口位置（`syncEditorRect` 记账，防每帧重复 SetWindowPos）
    editor_x: i32 = 0,
    editor_y: i32 = 0,
    /// 区域裁切哈希（覆盖矩形+位置尺寸；变化才重建 RGN；见 `setEditorClip`）
    clip_hash: u64 = 0,
    clip_valid: bool = false,
    /// 插件无界面（createView 空/不支持 HWND）——缓存，面板显示参数列表兜底
    editor_no_ui: bool = false,
    /// 编辑器打开失败后的退避帧数（防每帧重试骚扰插件）
    editor_fail_wait: u8 = 0,
    /// 输入闸门：模态框/菜单展开期间禁用子窗口（点击不落到插件上；
    /// 禁用窗的点击归父窗口 → 软 UI 的模态层正常拦截）。变化才动作。
    editor_enabled: bool = true,

    /// 单组件形态（component 即 controller；state 同步策略不同）
    ctrl_same: bool = false,

    /// 实例化时选中的类 CID（VST3 稳定身份——预设分类/重绑定用；零 = 未记录）
    class_cid: [16]u8 = [_]u8{0} ** 16,

    // ── 参数与状态（阶段 4）──
    /// 参数元数据（加载时抓取；空 = 抓取失败——面板退化，其余功能不受影响）
    params: []ParamMeta = &.{},
    /// 宿主 → 插件待送参数变更（SPSC 环：UI 线程写、音频线程读）
    pend: [8]ParamMsg = [_]ParamMsg{.{ .id = 0, .value = 0 }} ** 8,
    pend_head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pend_tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 音频线程组装 inputParameterChanges 的预分配容器
    in_queues: [8]ParamValueQueue = [_]ParamValueQueue{.{}} ** 8,
    in_changes: ParamChanges = .{},
    /// VSTi：本段输入事件（processInstrument 填充；段边界 = 事件时刻）
    in_events: EventList = .{},
    /// 每块填充的进程上下文（tempo/拍号/播放位置/ppq；复用同一实例）
    ctx: ivstprocesscontext.ProcessContext = .{},
    /// 每插件组件处理器实例（加载时创建；记录插件 GUI 内编辑与 restart 请求）
    handler_obj: ?*PluginHandler = null,
    /// 编辑器交互事件**环形队列**（插件 GUI 线程写、宿主 UI 线程读）：begin/perform/end
    /// 三类事件全量保留——撤销“参数增量回放”的数据源；begin 事件还用于“按旋钮切历史”。
    edit_ring: [edit_ring_len]EditEvent = [_]EditEvent{.{ .kind = .perform, .id = 0, .value = 0 }} ** edit_ring_len,
    /// 累计写入数（单调）；`edit_ring[w % len]` 为最新一条
    edit_w: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// 已读累计数（仅 UI 线程写）
    edit_seen: u32 = 0,
    /// 写超读丢段（消费方降级为整块状态恢复）
    edit_overflow: bool = false,
    /// 参数值缓存（归一化；下标与 `params` 对齐）。**撤销“旧值”的精确来源**：
    /// 只由宿主写（编辑器侧变更由 UI 排空时同步）——故“编辑前值”恒准。
    param_cache: []f64 = &.{},
    param_cache_valid: bool = false,
    /// 统计：`captureState` 实际调用次数（测试断言“捕获复用”用）
    get_state_calls: u32 = 0,
    restart_flags: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// 插件经 IComponentHandler2::setDirty(true) 的标脏通知（计数，去重轮询）
    dirty_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dirty_seen: u32 = 0,
    /// 插件请求宿主打开编辑器（requestOpenEditor；帧末处理）
    open_editor_req: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// restart 宽限期（帧）：实例新载入/状态恢复/编辑器刚打开期间，插件的 restart
    /// 通知不当作“文档已改”（JUCE 在 setComponentState 后必发 kParamValuesChanged）
    restart_grace: u32 = 0,
    /// 状态哈希监视（编辑器打开期间捕捉无通知的结构改动，如 GuitarD 改连线）
    last_state_hash: u64 = 0,
    hash_tick: u32 = 0,
    hash_armed: bool = false,

    /// 是否有主音频输入（乐器/VSTi 常为 false；process 时不读输入缓冲）
    has_input: bool = true,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u16 = 0,
    /// 厂商（类信息的 vendor；预设展示/回退用）
    vendor_buf: [64]u8 = [_]u8{0} ** 64,
    vendor_len: u16 = 0,
    sample_rate: f64 = 0,
    max_block: u32 = 0,
    /// 插件报告的延迟（样本数；补偿机制见 docs/plugin-hosting.md）
    latency: u32 = 0,

    // planar 缓冲（各 max_block 长；创建时分配）
    in_l: []f32 = &.{},
    in_r: []f32 = &.{},
    out_l: []f32 = &.{},
    out_r: []f32 = &.{},
    in_chans: [2][*]f32 = undefined,
    out_chans: [2][*]f32 = undefined,
    in_bus: iaudio.AudioBusBuffers = .{},
    out_bus: iaudio.AudioBusBuffers = .{},
    // ── 多输出（VSTi：如 SFLT 0进17出）──
    /// 激活的输出总线数（= ProcessData.numOutputs；单总线插件 = 1，走旧路径）
    out_bus_count: usize = 1,
    /// 主输出总线在**激活序列**中的位次（“仅主输出”混音策略用）
    out_main_index: usize = 0,
    /// 每激活总线的通道数（按总线索引升序；仅多输出有效）
    out_chan_counts: [MaxBuses]u8 = [_]u8{0} ** MaxBuses,
    /// 多输出：全部激活总线的 planar 样本池（一段连续内存）
    out_pool: []f32 = &.{},
    /// 各总线各声道的 planar 指针（装载期填好；渲染期只 memset/读）
    out_ptrs: [MaxBuses][2][*]f32 = [_][2][*]f32{.{ undefined, undefined }} ** MaxBuses,
    /// ProcessData.outputs 数组（音频线程只读）
    out_buffers: [MaxBuses]iaudio.AudioBusBuffers = [_]iaudio.AudioBusBuffers{.{}} ** MaxBuses,

    pub fn name(self: *const Plugin) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn vendor(self: *const Plugin) []const u8 {
        return self.vendor_buf[0..self.vendor_len];
    }

    /// 类 CID → 32 位小写 hex（写入 buf；返回切片）——VST3 稳定身份
    pub fn cidHex(self: *const Plugin, buf: *[32]u8) []const u8 {
        const hex = "0123456789abcdef";
        for (self.class_cid, 0..) |b, i| {
            buf[i * 2] = hex[b >> 4];
            buf[i * 2 + 1] = hex[b & 0xf];
        }
        return buf[0..32];
    }

    /// 编辑器是否已打开
    pub fn editorOpen(self: *const Plugin) bool {
        return self.editor_hwnd != null;
    }

    // ── 参数与状态（阶段 4；UI 线程接口）──

    pub fn paramCount(self: *const Plugin) usize {
        return self.params.len;
    }

    /// 宿主 UI 编辑参数（归一化 0-1）：更新控制器 + 排给音频线程（inputParameterChanges）
    pub fn setParamHost(self: *Plugin, idx: usize, norm: f64) void {
        if (idx >= self.params.len) return;
        const c = self.controller orelse return;
        const rc = self.raw_controller orelse return;
        const v = std.math.clamp(norm, 0, 1);
        _ = c.vtable.setParamNormalized(rc, self.params[idx].id, v);
        self.pushParamMsg(self.params[idx].id, v);
        self.cacheSet(idx, v); // 缓存跟随宿主写入（编辑器侧由排空时同步）
    }

    /// 当前归一化值
    pub fn paramNorm(self: *const Plugin, idx: usize) f64 {
        if (idx >= self.params.len) return 0;
        const c = self.controller orelse return 0;
        const rc = self.raw_controller orelse return 0;
        return c.vtable.getParamNormalized(rc, self.params[idx].id);
    }

    /// 当前值 → 显示文本（优先插件自带显示串；失败 → 归一化数值）
    pub fn paramText(self: *const Plugin, idx: usize, buf: []u8) []const u8 {
        if (idx >= self.params.len) return "";
        const c = self.controller orelse return "";
        const rc = self.raw_controller orelse return "";
        const id = self.params[idx].id;
        const v = c.vtable.getParamNormalized(rc, id);
        var wbuf: [128]u16 = [_]u16{0} ** 128;
        if (c.vtable.getParamStringByValue(rc, id, v, &wbuf) == btypes.kResultOk) {
            var len: u8 = 0;
            copyUtf16ToUtf8(buf, &len, std.mem.sliceTo(&wbuf, 0));
            if (len > 0) return buf[0..len];
        }
        return std.fmt.bufPrint(buf, "{d:.3}", .{v}) catch "";
    }

    /// 插件 GUI 内的参数编辑（去重轮询；无新编辑 → null）。
    /// 注：缓存/增量场景请用 `drainEditorEdits`（本函数只回最后一条，兼容旧调用）
    pub fn pollEditorEdit(self: *Plugin) ?ParamEdit {
        var buf: [8]ParamEdit = undefined;
        const n = self.drainEditorEdits(&buf);
        if (n == 0) return null;
        return buf[n - 1];
    }

    /// 记录一条编辑器交互事件（插件 GUI 线程；**不动参数缓存**——缓存中的值
    /// 必须保持“宿主已知的当前值”，排空时它正好是编辑前的旧值）。
    pub fn recordEditEvent(self: *Plugin, kind: EditEventKind, id: u32, value: f64) void {
        const w = self.edit_w.load(.monotonic);
        self.edit_ring[w % edit_ring_len] = .{ .kind = kind, .id = id, .value = value };
        self.edit_w.store(w + 1, .release);
    }

    /// 兼容旧名（只记录 perform）
    pub fn recordEditorEdit(self: *Plugin, id: u32, value: f64) void {
        self.recordEditEvent(.perform, id, value);
    }

    /// 排空交互事件队列（UI 线程，**保序**）；返回拷出的条数。写超读超过一圈 →
    /// 丢弃并置 `takeEditOverflow`（消费方须降级）。
    pub fn drainEditEvents(self: *Plugin, out: []EditEvent) usize {
        const w = self.edit_w.load(.acquire);
        if (w -% self.edit_seen > edit_ring_len) {
            // 追不上：中间段已被覆盖，全部作废（降级信号）
            self.edit_seen = w;
            self.edit_overflow = true;
            return 0;
        }
        var n: usize = 0;
        while (self.edit_seen != w and n < out.len) {
            out[n] = self.edit_ring[self.edit_seen % edit_ring_len];
            self.edit_seen += 1;
            n += 1;
        }
        return n;
    }

    /// 兼容接口：只拷出 perform 事件（begin/end 一并**消费**——单一消费者模型；
    /// 输出满时游标停在未消费事件上，不丢事件）
    pub fn drainEditorEdits(self: *Plugin, out: []ParamEdit) usize {
        const w = self.edit_w.load(.acquire);
        if (w -% self.edit_seen > edit_ring_len) {
            self.edit_seen = w;
            self.edit_overflow = true;
            return 0;
        }
        var n: usize = 0;
        while (self.edit_seen != w) {
            const ev = self.edit_ring[self.edit_seen % edit_ring_len];
            if (ev.kind == .perform) {
                if (n >= out.len) break;
                out[n] = .{ .id = ev.id, .value = ev.value };
                n += 1;
            }
            self.edit_seen += 1;
        }
        return n;
    }

    /// 取走溢出旗标（读后清零）
    pub fn takeEditOverflow(self: *Plugin) bool {
        const f = self.edit_overflow;
        self.edit_overflow = false;
        return f;
    }

    // ── 参数值缓存与按 ID 回放（撤销“参数增量回放”支撑）──

    /// 重建参数值缓存（加载完成/状态恢复后调用；UI 线程）
    pub fn refreshParamCache(self: *Plugin) void {
        const c = self.controller orelse return;
        const rc = self.raw_controller orelse return;
        if (self.param_cache.len != self.params.len) {
            if (self.param_cache.len > 0) self.alloc.free(self.param_cache);
            self.param_cache = self.alloc.alloc(f64, self.params.len) catch {
                self.param_cache = &.{};
                self.param_cache_valid = false;
                return;
            };
        }
        for (self.params, 0..) |p, i| {
            self.param_cache[i] = c.vtable.getParamNormalized(rc, p.id);
        }
        self.param_cache_valid = true;
    }

    /// 缓存读（无效 → null）；调用方据此决定能否参数回放
    pub fn cacheGet(self: *const Plugin, idx: usize) ?f64 {
        if (!self.param_cache_valid or idx >= self.param_cache.len) return null;
        return self.param_cache[idx];
    }

    /// 缓存写（无效则不动；供排空/回放时同步）
    pub fn cacheSet(self: *Plugin, idx: usize, v: f64) void {
        if (self.param_cache_valid and idx < self.param_cache.len) self.param_cache[idx] = v;
    }

    /// 参数 ID → 下标（插件参数表通常几十~几百项；线性扫描足够）
    pub fn findParamIndex(self: *const Plugin, id: u32) ?usize {
        for (self.params, 0..) |p, i| {
            if (p.id == id) return i;
        }
        return null;
    }

    /// 按参数 ID 设置归一化值（撤销参数回放用）。找不到该 ID → false。
    pub fn setParamById(self: *Plugin, id: u32, norm: f64) bool {
        const idx = self.findParamIndex(id) orelse return false;
        self.setParamHost(idx, norm);
        return true;
    }

    /// 取走 restartComponent 请求的 flags（0 = 无）
    pub fn takeRestartFlags(self: *Plugin) i32 {
        return self.restart_flags.swap(0, .acq_rel);
    }

    /// 去重轮询：插件是否发出过 setDirty(true)（结构性改动的主要通知途径）
    pub fn takeDirtyNotice(self: *Plugin) bool {
        const seq = self.dirty_seq.load(.acquire);
        if (seq == self.dirty_seen) return false;
        self.dirty_seen = seq;
        return true;
    }

    /// 取走 requestOpenEditor 请求（插件 GUI 内的“显示编辑器”按钮等）
    pub fn takeOpenEditorRequest(self: *Plugin) bool {
        return self.open_editor_req.swap(false, .acq_rel);
    }

    /// 采样当前状态哈希（UI 线程；编辑器打开时用于捕捉“无通知”的结构改动）。
    /// getState 失败/空 → null。
    pub fn sampleStateHash(self: *Plugin, allocator: std.mem.Allocator) ?u64 {
        var ms = MemStream{ .alloc = allocator };
        defer ms.deinit();
        if (self.component.vtable.getState(self.raw_component, ms.asIface()) != btypes.kResultOk) return null;
        if (ms.buf.items.len == 0) return null;
        return std.hash.Wyhash.hash(0, ms.buf.items);
    }

    /// 重读延迟（restartComponent(kLatencyChanged) 后调用）
    pub fn refreshLatency(self: *Plugin) void {
        self.latency = self.processor.vtable.getLatencySamples(self.raw_processor);
    }

    fn pushParamMsg(self: *Plugin, id: u32, value: f64) void {
        const head = self.pend_head.load(.monotonic);
        const tail = self.pend_tail.load(.acquire);
        if (head -% tail >= self.pend.len) return; // 满：丢弃（拖动中间态可丢，末端值随后必到）
        self.pend[head % self.pend.len] = .{ .id = id, .value = value };
        self.pend_head.store(head +% 1, .release);
    }
    fn popParamMsg(self: *Plugin) ?ParamMsg {
        const tail = self.pend_tail.load(.monotonic);
        if (tail == self.pend_head.load(.acquire)) return null;
        const m = self.pend[tail % self.pend.len];
        self.pend_tail.store(tail +% 1, .release);
        return m;
    }

    /// 抓取插件状态（组件 + 控制器各一份；调用方释放）。UI 线程。
    pub fn captureState(self: *Plugin, allocator: std.mem.Allocator) StateBlobs {
        self.get_state_calls +%= 1;
        var out = StateBlobs{};
        {
            var ms = MemStream{ .alloc = allocator };
            defer ms.deinit();
            if (self.component.vtable.getState(self.raw_component, ms.asIface()) == btypes.kResultOk and ms.buf.items.len > 0) {
                out.comp = ms.buf.toOwnedSlice(allocator) catch &.{};
            }
        }
        if (!self.ctrl_same) {
            if (self.controller) |c| {
                if (self.raw_controller) |rc| {
                    var ms = MemStream{ .alloc = allocator };
                    defer ms.deinit();
                    if (c.vtable.getState(rc, ms.asIface()) == btypes.kResultOk and ms.buf.items.len > 0) {
                        out.ctrl = ms.buf.toOwnedSlice(allocator) catch &.{};
                    }
                }
            }
        }
        return out;
    }

    /// 恢复插件状态（空 = 跳过该侧）。UI 线程；实例需已完全初始化。
    pub fn restoreState(self: *Plugin, comp: []const u8, ctrl: []const u8) void {
        self.restart_grace = 90; // JUCE 等在状态恢复后会补发 kParamValuesChanged
        // 状态已换 → 参数缓存失效，末尾重建（缓存是撤销“旧值”的依据，不能脏）
        self.param_cache_valid = false;
        // 丢弃待送参数：它们已被恢复的状态覆盖；否则下一个 process 会用旧值
        // 把恢复值又压回去（实测：拖动→撤销→process 回旧值）
        self.pend_tail.store(self.pend_head.load(.acquire), .release);
        if (comp.len > 0) {
            var ms = MemStream.initWith(self.alloc, comp);
            defer ms.deinit();
            _ = self.component.vtable.setState(self.raw_component, ms.asIface());
            if (!self.ctrl_same) {
                if (self.controller) |c| {
                    if (self.raw_controller) |rc| {
                        ms.pos = 0;
                        _ = c.vtable.setComponentState(rc, ms.asIface());
                    }
                }
            }
        }
        if (ctrl.len > 0 and !self.ctrl_same) {
            if (self.controller) |c| {
                if (self.raw_controller) |rc| {
                    var ms = MemStream.initWith(self.alloc, ctrl);
                    defer ms.deinit();
                    _ = c.vtable.setState(rc, ms.asIface());
                }
            }
        }
        self.refreshParamCache();
    }

    pub const EditorResult = enum { opened, no_editor, failed };

    /// 打开插件编辑器（UI 线程）：创建**子窗口**并挂接插件视图（嵌入宿主面板）。
    /// 已打开则直接返回；插件无界面 → `.no_editor`（缓存 `editor_no_ui`）。
    pub fn openEditor(self: *Plugin, parent: ?*anyopaque) EditorResult {
        if (self.view != null) return .opened;
        if (self.editor_no_ui) return .no_editor;
        const raw_ctrl = self.raw_controller orelse {
            self.editor_no_ui = true;
            return .no_editor;
        };
        const ctrl = self.controller orelse {
            self.editor_no_ui = true;
            return .no_editor;
        };
        const raw_view: ?*iplugview.IPlugView = ctrl.vtable.createView(raw_ctrl, iedit.ViewType.kEditor);
        const view = raw_view orelse {
            std.debug.print("[vst] 编辑器：createView 返回 null（插件无界面或未实现）\n", .{});
            self.editor_no_ui = true;
            return .no_editor;
        };
        var committed = false;
        defer if (!committed) {
            _ = view.vtable.release(view);
        };

        if (view.vtable.isPlatformTypeSupported(view, iplugview.PlatformType.kPlatformTypeHWND) != btypes.kResultOk) {
            std.debug.print("[vst] 编辑器：插件不支持 HWND 平台\n", .{});
            self.editor_no_ui = true;
            return .no_editor;
        }

        var rect = iplugview.ViewRect{};
        if (view.vtable.getSize(view, &rect) != btypes.kResultOk) {
            std.debug.print("[vst] 编辑器：getSize 失败\n", .{});
            return .failed;
        }
        const cw = rect.right - rect.left;
        const ch = rect.bottom - rect.top;
        if (cw <= 0 or ch <= 0 or cw > 8192 or ch > 8192) return .failed;

        if (!ensureEditorClass()) return .failed;

        // 子窗口：无标题栏/边框（规范：attached 的 parent 是 HWND，“should attach a
        // child window to it”）；外框与标题栏由我们的软渲染面板提供。
        // 注：子窗口坐标 = 物理像素（规范 Coordinates 段）。
        const hwnd = CreateWindowExW(
            0,
            editor_class_name,
            null,
            0x40000000, // WS_CHILD（**不带 VISIBLE**：先隐藏创建，首次定位后再显示——防左上角小黑框闪现）
            0,
            0,
            cw,
            ch,
            parent,
            null,
            GetModuleHandleW(null),
            null,
        ) orelse return .failed;
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        const frame = self.alloc.create(EditorFrame) catch {
            _ = DestroyWindow(hwnd);
            return .failed;
        };
        frame.* = .{ .hwnd = hwnd, .owner = self };
        self.frame = frame;

        _ = view.vtable.setFrame(view, frame.asInterface());
        if (view.vtable.attached(view, hwnd, iplugview.PlatformType.kPlatformTypeHWND) != btypes.kResultOk) {
            _ = view.vtable.setFrame(view, null);
            _ = DestroyWindow(hwnd);
            self.alloc.destroy(frame);
            self.frame = null;
            return .failed;
        }
        self.view = view;
        self.editor_hwnd = hwnd;
        self.editor_w = cw;
        self.editor_h = ch;
        self.editor_x = 0;
        self.editor_y = 0;
        self.clip_valid = false;
        self.editor_shown = false;
        self.editor_enabled = true;
        self.restart_grace = 90; // 开窗瞬间可能触发插件补发 restart——宽限期内不当“已改”
        committed = true;
        return .opened;
    }

    /// 面板侧每帧同步：移动子窗口到面板内容区（变化才 SetWindowPos）。
    /// 大小以 `editor_w/h`（插件请求）为准；**首次定位后才显示**（创建时隐藏，
    /// 防在主窗左上角闪现小黑框）；显示时才抢焦点。
    pub fn syncEditorRect(self: *Plugin, x: i32, y: i32) void {
        const hwnd = self.editor_hwnd orelse return;
        if (x != self.editor_x or y != self.editor_y) {
            self.editor_x = x;
            self.editor_y = y;
            _ = SetWindowPos(hwnd, null, x, y, self.editor_w, self.editor_h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        if (!self.editor_shown) {
            self.editor_shown = true;
            _ = ShowWindow(hwnd, SW_SHOW);
            _ = SetFocus(hwnd);
        }
    }

    /// 子窗口的 client 矩形（主窗坐标；`present` 回写裁切用）。
    /// 未显示 → null（隐藏期间该区域仍是我们的面板像素，必须照常回写）。
    pub fn editorClientRect(self: *const Plugin) ?[4]i32 {
        if (self.editor_hwnd == null or !self.editor_shown) return null;
        return .{ self.editor_x, self.editor_y, self.editor_w, self.editor_h };
    }

    /// 输入闸门（见字段注释）：模态/菜单期间禁用；变化才动作
    pub fn setEditorEnabled(self: *Plugin, enabled: bool) void {
        if (self.editor_enabled == enabled) return;
        const hwnd = self.editor_hwnd orelse return;
        self.editor_enabled = enabled;
        _ = EnableWindow(hwnd, if (enabled) 1 else 0);
    }

    /// 子窗口**区域裁切**：把“绘制在面板之上”的矩形（主窗口 client 坐标）从子窗口中
    /// 减掉（`SetWindowRgn`）。子窗口是原生窗口，永远在软渲染之上——不裁切就会出现
    /// “插件界面盖住菜单/浮动窗口”；部分遮挡时保留可见部分（与原生窗口行为一致），
    /// 且被裁区域的鼠标点击会自动穿透到下层（区域同时作用于命中测试）。
    /// 变化检测：覆盖集合/位置/尺寸不变则跳过（RGN 只重建于变化时）。
    pub fn setEditorClip(self: *Plugin, covers: []const EditClipRect) void {
        const hwnd = self.editor_hwnd orelse return;
        var hsh = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        hsh.update(std.mem.asBytes(&self.editor_x));
        hsh.update(std.mem.asBytes(&self.editor_y));
        hsh.update(std.mem.asBytes(&self.editor_w));
        hsh.update(std.mem.asBytes(&self.editor_h));
        hsh.update(std.mem.sliceAsBytes(covers));
        const h = hsh.final();
        if (self.clip_valid and h == self.clip_hash) return;
        self.clip_hash = h;
        self.clip_valid = true;
        const full = CreateRectRgn(0, 0, self.editor_w, self.editor_h) orelse return;
        for (covers) |c| {
            const r = clipRectToClient(c, self.editor_x, self.editor_y, self.editor_w, self.editor_h) orelse continue;
            const reg = CreateRectRgn(r[0], r[1], r[2], r[3]) orelse continue;
            _ = CombineRgn(full, full, reg, RGN_DIFF);
            _ = DeleteObject(reg);
        }
        if (SetWindowRgn(hwnd, full, 1) == 0) {
            _ = DeleteObject(full); // 失败：系统未接管区域，需自删
        }
    }


    /// 关闭插件编辑器（UI 线程；幂等）
    pub fn closeEditor(self: *Plugin) void {
        if (self.view) |v| {
            _ = v.vtable.removed(v);
            _ = v.vtable.setFrame(v, null);
            _ = v.vtable.release(v);
            self.view = null;
        }
        if (self.frame) |f| {
            self.alloc.destroy(f);
            self.frame = null;
        }
        if (self.editor_hwnd) |h| {
            self.editor_hwnd = null;
            _ = DestroyWindow(h);
        }
        self.clip_valid = false;
        self.editor_shown = false;
        self.editor_x = 0;
        self.editor_y = 0;
    }

    /// 处理一块**交错立体声**（就地；`frames` ≤ `max_block`）。
    /// 音频线程调用——零分配。插件处理失败时退化为直通（fail-open）。
    pub fn process(self: *Plugin, buf: []f32, frames: u32) void {
        self.render(buf, frames, &.{}, .{});
    }

    /// 渲染一块（效果器；附带宿主时间信息——tempo 同步类插件需要）
    pub fn processWithHost(self: *Plugin, buf: []f32, frames: u32, host: HostTime) void {
        self.render(buf, frames, &.{}, host);
    }

    /// 渲染一块（VSTi；附带本段输入事件与宿主时间信息；事件偏移均为 0——宿主按事件时刻分段）
    pub fn processInstrument(self: *Plugin, buf: []f32, frames: u32, events: []const ivstevents.Event, host: HostTime) void {
        self.render(buf, frames, events, host);
    }

    /// 渲染核心。音频线程调用——零分配。插件处理失败时退化为直通（fail-open）。
    fn render(self: *Plugin, buf: []f32, frames: u32, events: []const ivstevents.Event, host: HostTime) void {
        if (frames == 0 or self.in_l.len < frames) return;
        // 事件入列（上限 128；超出丢弃——段内事件数实践中远低于此）
        const n_ev: usize = @min(events.len, self.in_events.events.len);
        for (events[0..n_ev], 0..) |e, k| self.in_events.events[k] = e;
        self.in_events.count = @intCast(n_ev);
        // 宿主进程上下文（tempo/拍号/播放位置/ppq）
        {
            var st: u32 = ivstprocesscontext.StatesAndFlags.kTempoValid | ivstprocesscontext.StatesAndFlags.kTimeSigValid | ivstprocesscontext.StatesAndFlags.kContTimeValid;
            if (host.playing) st |= ivstprocesscontext.StatesAndFlags.kPlaying | ivstprocesscontext.StatesAndFlags.kProjectTimeMusicValid;
            self.ctx = .{
                .state = st,
                .sampleRate = self.sample_rate,
                .projectTimeSamples = @intCast(host.abs_samples),
                .continousTimeSamples = @intCast(host.abs_samples),
                .projectTimeMusic = host.ppq,
                .tempo = host.tempo,
                .timeSigNumerator = host.time_num,
                .timeSigDenominator = host.time_den,
            };
        }
        // 交错 → planar（无主输入（VSTi）不读输入缓冲）
        var i: usize = 0;
        if (self.has_input) {
            while (i < frames) : (i += 1) {
                self.in_l[i] = buf[i * 2];
                self.in_r[i] = buf[i * 2 + 1];
            }
        }
        // 清输出（规范：输出缓冲内容由 host 提供初值）
        @memset(self.out_l[0..frames], 0);
        @memset(self.out_r[0..frames], 0);
        if (self.out_bus_count > 1) {
            for (0..self.out_bus_count) |b| {
                for (0..self.out_chan_counts[b]) |c| @memset(self.out_ptrs[b][c][0..frames], 0);
            }
        }

        // 宿主待送参数变更 → 本块 inputParameterChanges（每参数单点，offset 0）
        var n_q: usize = 0;
        while (n_q < self.in_queues.len) : (n_q += 1) {
            const m = self.popParamMsg() orelse break;
            self.in_queues[n_q].id = m.id;
            self.in_queues[n_q].value = m.value;
            self.in_queues[n_q].used = true;
        }
        self.in_changes.count = @intCast(n_q);

        var pd = iaudio.ProcessData{
            .processMode = @intFromEnum(iaudio.ProcessModes.kRealtime),
            .symbolicSampleSize = @intFromEnum(iaudio.SymbolicSampleSizes.kSample32),
            .numSamples = @intCast(frames),
            .numInputs = if (self.has_input) 1 else 0,
            .numOutputs = @intCast(self.out_bus_count),
            .inputs = if (self.has_input) @ptrCast(&self.in_bus) else null,
            .outputs = @ptrCast(&self.out_buffers),
            .inputParameterChanges = if (n_q > 0) &self.in_changes.iface else null,
            .inputEvents = if (n_ev > 0) &self.in_events.iface else null,
            .processContext = &self.ctx,
        };
        const r = self.processor.vtable.process(self.raw_processor, &pd);
        if (r != btypes.kResultOk) return; // 失败：保持输入原样（直通）

        // planar → 交错
        i = 0;
        if (self.out_bus_count > 1) {
            mixMultiOut(self, buf, frames);
        } else {
            while (i < frames) : (i += 1) {
                buf[i * 2] = self.out_l[i];
                buf[i * 2 + 1] = self.out_r[i];
            }
        }
    }
};

/// 多输出 VSTi：各激活总线 planar → 交错立体声。
/// 默认**求和**（不丢声——无论音频落在主还是辅助总线）；
/// `vsti_sum_all_buses=false` 时只取主总线（防“主=辅助镜像”类插件音量翻倍）。
/// 纯数据变换（只读 Plugin 的缓冲账目）——可单测（见文件尾）。
fn mixMultiOut(self: *const Plugin, buf: []f32, frames: usize) void {
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        var l: f32 = 0;
        var rr: f32 = 0;
        if (vsti_sum_all_buses) {
            for (0..self.out_bus_count) |b| {
                const ch = self.out_chan_counts[b];
                if (ch >= 2) {
                    l += self.out_ptrs[b][0][i];
                    rr += self.out_ptrs[b][1][i];
                } else if (ch == 1) {
                    l += self.out_ptrs[b][0][i];
                    rr += self.out_ptrs[b][0][i];
                }
            }
        } else {
            const b = @min(self.out_main_index, self.out_bus_count - 1);
            const ch = self.out_chan_counts[b];
            l = self.out_ptrs[b][0][i];
            rr = if (ch >= 2) self.out_ptrs[b][1][i] else l;
        }
        buf[i * 2] = l;
        buf[i * 2 + 1] = rr;
    }
}

/// 加载模块中的**第一个效果器类**并实例化（立体声主总线）。
/// 失败时返回 error（调用方展示；不会有半初始化实例）。
/// - `role == .effect`：需主立体声输入 + 输出；
/// - `role == .instrument`（VSTi）：允许无主输入（主输出必需；有主输入则一并激活）。
pub fn loadPlugin(allocator: std.mem.Allocator, path: [:0]const u8, sample_rate: f64, max_block: u32, role: Role) !*Plugin {
    const m = try loadModule(path);
    // 注：**失败不卸载模块**（原 errdefer m.deinit() 已移除）——SFLT 类插件在半初始化
    // 清理后仍持有 DLL 内后台线程/回调；FreeLibrary 后它们会执行已卸载代码 → 进程后续
    // 崩溃（实测：四步清理全部安全完成后崩于插件基址区）。宿主惯例亦为“插件 DLL 常驻”。
    // 代价：失败重试会复用同一已加载模块（不会重复 DllMain）；模块引用进程内累积（无害）。

    // 工厂级宿主上下文（IPluginFactory3::setHostContext；规范推荐，JUCE 等框架会用它）
    {
        var rawf3: ?*anyopaque = null;
        if (m.factory.vtable.queryInterface(m.raw_factory, &ipb.iplugin_factory3_iid, &rawf3) == btypes.kResultOk and rawf3 != null) {
            const f3: *const ipb.IPluginFactory3 = @ptrCast(@alignCast(rawf3.?));
            _ = f3.vtable.setHostContext(rawf3.?, @ptrCast(&host_ctx.host_iface));
            _ = f3.vtable.release(rawf3.?);
        }
    }

    // 选类（按角色）：
    // - effect：第一个**非乐器**的 Audio Module Class（兜底：任一效果类——如 Vital 会以
    //   NoMainInput 失败，提示清晰）；
    // - instrument：第一个子类别含 "Instrument" 的类
    var s = Scan{};
    collectClasses(m, &s);
    var cid: ?tuid.TUID = null;
    var plugin_name: []const u8 = "";
    var plugin_vendor: []const u8 = "";
    for (s.slice()) |*c| {
        if (!c.isAudioEffect()) continue;
        const want = switch (role) {
            .effect => !c.isInstrument(),
            .instrument => c.isInstrument(),
        };
        if (!want) continue;
        cid = c.cid;
        plugin_name = c.name();
        plugin_vendor = c.vendor();
        break;
    }
    if (cid == null and role == .effect) {
        for (s.slice()) |*c| {
            if (c.isAudioEffect()) {
                cid = c.cid;
                plugin_name = c.name();
                plugin_vendor = c.vendor();
                break;
            }
        }
    }
    const class_cid = cid orelse return error.NoEffectClass;

    // 组件 + 处理器
    var raw_comp: ?*anyopaque = null;
    if (m.factory.vtable.createInstance(m.raw_factory, tidToFid(&class_cid), tidToFid(&icomp.icomponent_iid), &raw_comp) != btypes.kResultOk or raw_comp == null) {
        return error.CreateComponentFailed;
    }
    const raw_component = raw_comp.?;
    const component: *const icomp.IComponent = @ptrCast(@alignCast(raw_component));
    errdefer {
        _ = component.vtable.release(raw_component);
    }

    var raw_proc: ?*anyopaque = null;
    if (component.vtable.queryInterface(raw_component, &iaudio.iaudio_processor_iid, &raw_proc) != btypes.kResultOk or raw_proc == null) {
        return error.NoAudioProcessor;
    }
    const raw_processor = raw_proc.?;
    const processor: *const iaudio.IAudioProcessor = @ptrCast(@alignCast(raw_processor));
    errdefer {
        _ = processor.vtable.release(raw_processor);
    }

    // 控制器：先试单组件（component 同时实现 IEditController），否则按 class id 独立创建
    var raw_ctrl: ?*anyopaque = null;
    var ctrl_same = false;
    if (component.vtable.queryInterface(raw_component, &iedit.iedit_controller_iid, &raw_ctrl) == btypes.kResultOk and raw_ctrl != null) {
        ctrl_same = true;
    } else {
        var ctrl_cid: tuid.TUID = tuid.zero;
        if (component.vtable.getControllerClassId(raw_component, &ctrl_cid) == btypes.kResultOk) {
            var rc: ?*anyopaque = null;
            if (m.factory.vtable.createInstance(m.raw_factory, tidToFid(&ctrl_cid), tidToFid(&iedit.iedit_controller_iid), &rc) == btypes.kResultOk and rc != null) {
                raw_ctrl = rc;
            }
        }
    }
    const controller: ?*const iedit.IEditController = if (raw_ctrl) |rc| @ptrCast(@alignCast(rc)) else null;
    errdefer if (raw_ctrl != null and !ctrl_same) {
        if (controller) |c| _ = c.vtable.release(raw_ctrl.?);
    };

    // 初始化（hostContext = 进程级宿主上下文；传 null 会崩在解引用上）
    if (component.vtable.initialize(raw_component, &host_ctx.host_iface) != btypes.kResultOk) return error.InitializeFailed;

    const pl = try allocator.create(Plugin);
    errdefer allocator.destroy(pl);
    pl.* = .{
        .mod = m,
        .raw_component = raw_component,
        .component = component,
        .raw_processor = raw_processor,
        .processor = processor,
        .raw_controller = raw_ctrl,
        .controller = controller,
        .alloc = allocator,
        .ctrl_same = ctrl_same,
        .class_cid = class_cid,
        .sample_rate = sample_rate,
        .max_block = max_block,
    };
    pl.in_changes.setQueues(&pl.in_queues);
    copyTo(&pl.name_buf, &pl.name_len, plugin_name);
    copyTo(&pl.vendor_buf, &pl.vendor_len, plugin_vendor);
    errdefer {
        _ = component.vtable.terminate(raw_component);
    }

    // 独立控制器也要 initialize（拿 hostContext；UI/自动化依赖）
    var new_handler: ?*PluginHandler = null;
    if (raw_ctrl) |rc| {
        if (!ctrl_same) {
            if (controller) |c| {
                if (c.vtable.initialize(rc, &host_ctx.host_iface) != btypes.kResultOk) return error.InitializeFailed;
                // 组件↔控制器双向连接（分离式插件共享内部实例的关键；JUCE 靠它给出参数与编辑器）
                bridgeComponentController(raw_component, component, c, rc, true);
                // 组件 state → 控制器（规范：分离式插件“使用控制器”前必须；
                // JUCE 控制器在 connect 前无参数表，connect 后此步也有意义）
                var ms = MemStream{ .alloc = allocator };
                defer ms.deinit();
                if (component.vtable.getState(raw_component, ms.asIface()) == btypes.kResultOk) {
                    ms.pos = 0;
                    _ = c.vtable.setComponentState(rc, ms.asIface());
                }
            }
        }
        // 无论单组件还是分离式，都要接上组件处理器：
        // 插件编辑器内部会调 getComponentHandler()，null 时一动 UI 就解引用崩溃；
        // 用每插件实例（记录 GUI 内编辑 → 面板同步/标脏；见 pollEditorEdit）。
        if (controller) |c| {
            const h = allocator.create(PluginHandler) catch null;
            if (h) |hh| {
                hh.* = .{ .owner = pl };
                pl.handler_obj = hh;
                new_handler = hh;
                _ = c.vtable.setComponentHandler(rc, hh.asInterface());
            } else {
                _ = c.vtable.setComponentHandler(rc, &host_ctx.handler_iface);
            }
        }
    }
    // 注：errdefer 必须在**函数作用域**（块内声明的 errdefer 不覆盖块之后的错误——实测泄漏）
    errdefer {
        if (new_handler) |hh| {
            pl.handler_obj = null;
            allocator.destroy(hh);
        }
    }
    // 参数缓存：必须在连接/初始化之后（JUCE 等插件在 IConnectionPoint::connect 后参数表才可用）
    buildParamCache(allocator, pl);
    errdefer if (pl.params.len > 0) allocator.free(pl.params);
    errdefer if (raw_ctrl != null and !ctrl_same) {
        if (controller) |c| _ = c.vtable.terminate(raw_ctrl.?);
    };

    // 主总线：1×立体声主输入 + 1×立体声主输出（辅助/侧链总线关闭但不拒绝）
    const n_in = component.vtable.getBusCount(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kInput));
    const n_out = component.vtable.getBusCount(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kOutput));
    if (n_in < 0 or n_out < 0 or n_in > MaxBuses or n_out > MaxBuses) return error.BusCountInvalid;
    var main_in: i32 = -1;
    var main_out: i32 = -1;
    {
        var i: i32 = 0;
        while (i < n_in) : (i += 1) {
            var bi: icomp.BusInfo = .{};
            if (component.vtable.getBusInfo(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kInput), i, &bi) != btypes.kResultOk) return error.BusInfoFailed;
            if (bi.busType == @intFromEnum(icomp.BusTypes.kMain) and main_in < 0) {
                if (bi.channelCount != 2) return error.MainInputNotStereo;
                main_in = i;
            }
        }
        i = 0;
        while (i < n_out) : (i += 1) {
            var bi: icomp.BusInfo = .{};
            if (component.vtable.getBusInfo(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kOutput), i, &bi) != btypes.kResultOk) return error.BusInfoFailed;
            if (bi.busType == @intFromEnum(icomp.BusTypes.kMain) and main_out < 0) {
                if (bi.channelCount != 2) return error.MainOutputNotStereo;
                main_out = i;
            }
        }
    }
    if (main_in < 0 and role == .effect) return error.NoMainInput; // 效果器必须有主输入；乐器允许无（VSTi）
    if (main_out < 0) return error.NoMainOutput;
    pl.has_input = main_in >= 0; // 总线探测完成后写入（process 据此决定是否读输入）

    // 总线激活策略（**升级阶梯**）：
    // ① 先试“仅主输出”（单总线路径：内存小、行为最简——旧行为）；
    // ② 被插件拒绝（如 SFLT：17 出全默认激活、要求全供 buffer）→ 全激活 +
    //    每总线 planar 缓冲 + 渲染时求和混音（见 `render` / `finishBuffers`）。
    var in_arr: [MaxBuses]vsttypes.SpeakerArrangement = [_]vsttypes.SpeakerArrangement{vstspeaker.SpeakerArr.kEmpty} ** MaxBuses;
    var out_arr: [MaxBuses]vsttypes.SpeakerArrangement = [_]vsttypes.SpeakerArrangement{vstspeaker.SpeakerArr.kEmpty} ** MaxBuses;
    if (main_in >= 0) in_arr[@intCast(main_in)] = vstspeaker.SpeakerArr.kStereo; // 乐器（VSTi）无主输入：跳过
    out_arr[@intCast(main_out)] = vstspeaker.SpeakerArr.kStereo;
    var multi = false;
    if (processor.vtable.setBusArrangements(raw_processor, &in_arr, n_in, &out_arr, n_out) != btypes.kResultOk) {
        // 全激活方案：非主输出总线通道数 ≤2 一律激活（单声道也收，混为双声道）
        multi = true;
        var oi: i32 = 0;
        var n_active: usize = 1;
        while (oi < n_out) : (oi += 1) {
            var bi2: icomp.BusInfo = .{};
            if (component.vtable.getBusInfo(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kOutput), oi, &bi2) != btypes.kResultOk) return error.BusInfoFailed;
            if (oi == main_out or bi2.channelCount == 0) continue;
            if (bi2.channelCount > 2) return error.MultiOutputUnsupported; // >立体声的辅助总线暂不支持
            out_arr[@intCast(oi)] = if (bi2.channelCount == 1) vstspeaker.SpeakerArr.kMono else vstspeaker.SpeakerArr.kStereo;
            n_active += 1;
        }
        if (n_active > MaxBuses) return error.MultiOutputUnsupported;
        if (processor.vtable.setBusArrangements(raw_processor, &in_arr, n_in, &out_arr, n_out) != btypes.kResultOk) {
            return error.MultiOutputUnsupported; // 两种布局都被拒：确实带不动
        }
        if (bus_debug) std.debug.print("[vst] {s}：多输出模式（{d} 总线激活）\n", .{ pl.name(), n_active });
    }
    // 激活总线（主输入/主输出 + 多输出模式下的辅助输出）
    {
        var i: i32 = 0;
        while (i < n_in) : (i += 1) {
            _ = component.vtable.activateBus(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kInput), i, if (i == main_in) 1 else 0);
        }
        i = 0;
        while (i < n_out) : (i += 1) {
            const want: u8 = if (multi)
                (if (out_arr[@intCast(i)] == vstspeaker.SpeakerArr.kEmpty) 0 else 1)
            else
                (if (i == main_out) 1 else 0);
            _ = component.vtable.activateBus(raw_component, @intFromEnum(icomp.MediaTypes.kAudio), @intFromEnum(icomp.BusDirections.kOutput), i, want);
        }
    }
    // 多输出：激活后重查各激活总线的通道数（激活可能改变 arrangement），
    // 并按**总线索引升序**记账（= ProcessData.outputs 的顺序）
    pl.out_bus_count = 1;
    pl.out_chan_counts[0] = 2;
    pl.out_main_index = 0;
    if (multi) {
        var cnt: usize = 0;
        var i: i32 = 0;
        while (i < n_out) : (i += 1) {
            if (out_arr[@intCast(i)] == vstspeaker.SpeakerArr.kEmpty) continue;
            var got: vsttypes.SpeakerArrangement = vstspeaker.SpeakerArr.kEmpty;
            _ = processor.vtable.getBusArrangement(raw_processor, @intFromEnum(icomp.BusDirections.kOutput), i, &got);
            const ch: usize = speakerChannelCount(got);
            if (ch == 0 or ch > 2) return error.MultiOutputUnsupported;
            pl.out_chan_counts[cnt] = @intCast(ch);
            if (i == main_out) pl.out_main_index = cnt;
            cnt += 1;
        }
        if (cnt == 0) cnt = 1; // 防御（理论不可达）
        pl.out_bus_count = cnt;
    }

    // 采样精度与 setup
    if (processor.vtable.canProcessSampleSize(raw_processor, @intFromEnum(iaudio.SymbolicSampleSizes.kSample32)) != btypes.kResultOk) {
        return error.Sample32Unsupported;
    }
    var setup = iaudio.ProcessSetup{
        .processMode = @intFromEnum(iaudio.ProcessModes.kRealtime),
        .symbolicSampleSize = @intFromEnum(iaudio.SymbolicSampleSizes.kSample32),
        .maxSamplesPerBlock = @intCast(max_block),
        .sampleRate = sample_rate,
    };
    if (processor.vtable.setupProcessing(raw_processor, &setup) != btypes.kResultOk) return error.SetupFailed;

    if (component.vtable.setActive(raw_component, 1) != btypes.kResultOk) return error.SetActiveFailed;
    if (processor.vtable.setProcessing(raw_processor, 1) != btypes.kResultOk) {
        _ = component.vtable.setActive(raw_component, 0);
        return error.SetProcessingFailed;
    }
    errdefer {
        _ = processor.vtable.setProcessing(raw_processor, 0);
        _ = component.vtable.setActive(raw_component, 0);
    }

    pl.latency = processor.vtable.getLatencySamples(raw_processor);

    // planar 缓冲（音频线程零分配的前提：全部在此分配）
    const ret = try finishBuffers(allocator, pl, max_block);
    ret.restart_grace = 90; // 载入后插件可能补发一轮 restart（不当作“已改”）
    return ret;
}

/// 分配 planar 缓冲并装配主总线（创建期一次性；音频线程零分配的前提）
fn finishBuffers(allocator: std.mem.Allocator, p: *Plugin, max_block: u32) !*Plugin {
    p.in_l = try allocator.alloc(f32, max_block);
    errdefer allocator.free(p.in_l);
    p.in_r = try allocator.alloc(f32, max_block);
    errdefer allocator.free(p.in_r);
    p.out_l = try allocator.alloc(f32, max_block);
    errdefer allocator.free(p.out_l);
    p.out_r = try allocator.alloc(f32, max_block);
    errdefer allocator.free(p.out_r);
    @memset(p.in_l, 0);
    @memset(p.in_r, 0);
    @memset(p.out_l, 0);
    @memset(p.out_r, 0);
    p.in_chans = .{ p.in_l.ptr, p.in_r.ptr };
    p.out_chans = .{ p.out_l.ptr, p.out_r.ptr };
    p.in_bus = .{
        .numChannels = 2,
        .silenceFlags = 0,
        .channelBuffers = .{ .channelBuffers32 = @ptrCast(&p.in_chans) },
    };
    p.out_bus = .{
        .numChannels = 2,
        .silenceFlags = 0,
        .channelBuffers = .{ .channelBuffers32 = @ptrCast(&p.out_chans) },
    };
    // 多输出（VSTi）：为**全部激活总线**建 planar 池 + 逐总线 AudioBusBuffers
    // （单总线路径保持旧行为：out_buffers[0] 指向 out_l/out_r，零额外内存）
    if (p.out_bus_count > 1) {
        var total: usize = 0;
        for (p.out_chan_counts[0..p.out_bus_count]) |c| total += c;
        p.out_pool = try allocator.alloc(f32, total * max_block);
        errdefer allocator.free(p.out_pool);
        @memset(p.out_pool, 0);
        var off: usize = 0;
        for (0..p.out_bus_count) |b| {
            const ch: usize = p.out_chan_counts[b];
            for (0..ch) |c| {
                p.out_ptrs[b][c] = p.out_pool.ptr + off + c * max_block;
            }
            p.out_buffers[b] = .{
                .numChannels = @intCast(ch),
                .silenceFlags = 0,
                .channelBuffers = .{ .channelBuffers32 = @ptrCast(&p.out_ptrs[b]) },
            };
            off += ch * max_block;
        }
    } else {
        p.out_bus_count = 1;
        p.out_chan_counts[0] = 2;
        p.out_ptrs[0] = .{ p.out_l.ptr, p.out_r.ptr };
        p.out_buffers[0] = .{
            .numChannels = 2,
            .silenceFlags = 0,
            .channelBuffers = .{ .channelBuffers32 = @ptrCast(&p.out_ptrs[0]) },
        };
    }
    return p;
}

/// 抓取参数元数据（**必须在连接/初始化之后**——JUCE 等插件在 IConnectionPoint::connect
/// 前参数表为空）。OOM → 留空（面板退化，插件其余功能不受影响）。
fn buildParamCache(allocator: std.mem.Allocator, pl: *Plugin) void {
    const c = pl.controller orelse return;
    const rc = pl.raw_controller orelse return;
    const n = c.vtable.getParameterCount(rc);
    if (n <= 0) return;
    const cnt: usize = @intCast(n);
    const list = allocator.alloc(ParamMeta, cnt) catch return;
    pl.params = list;
    for (list, 0..) |*m, i| {
        m.* = .{};
        var pi = iedit.ParameterInfo{};
        if (c.vtable.getParameterInfo(rc, @intCast(i), &pi) != btypes.kResultOk) continue;
        m.id = pi.id;
        m.step_count = pi.stepCount;
        m.default_norm = pi.defaultNormalizedValue;
        m.flags = pi.flags;
        copyUtf16ToUtf8(&m.name_buf, &m.name_len, std.mem.sliceTo(&pi.title, 0));
        copyUtf16ToUtf8(&m.units_buf, &m.units_len, std.mem.sliceTo(&pi.units, 0));
    }
}

/// 效果器加载（`loadPlugin(.effect)` 的便捷入口；保持既有调用方不变）
pub fn loadEffect(allocator: std.mem.Allocator, path: [:0]const u8, sample_rate: f64, max_block: u32) !*Plugin {
    return loadPlugin(allocator, path, sample_rate, max_block, .effect);
}

/// 销毁插件实例（UI 线程）。
pub fn unloadPlugin(allocator: std.mem.Allocator, pl: *Plugin) void {
    var p = pl;
    if (p.param_cache.len > 0) p.alloc.free(p.param_cache);
    p.param_cache = &.{};
    p.param_cache_valid = false;
    p.closeEditor(); // 先关编辑器（插件还活着时发起 removed）
    // 终止前先摘掉组件处理器与连接（规范流程；编辑器已关，handler 无用）
    if (p.raw_controller) |rc| {
        if (p.controller) |c| {
            if (rc != p.raw_component) bridgeComponentController(p.raw_component, p.component, c, rc, false);
            _ = c.vtable.setComponentHandler(rc, null);
        }
    }
    if (p.handler_obj) |h| {
        p.alloc.destroy(h);
        p.handler_obj = null;
    }
    _ = p.processor.vtable.setProcessing(p.raw_processor, 0);
    _ = p.component.vtable.setActive(p.raw_component, 0);
    _ = p.component.vtable.terminate(p.raw_component);
    if (p.raw_controller) |rc| {
        if (p.controller) |c| {
            // 独立控制器：终止后再 release（单组件形态与 component 同体，terminate 已在上面调过）
            if (rc != p.raw_component) _ = c.vtable.terminate(rc);
            _ = c.vtable.release(rc);
        }
    }
    _ = p.processor.vtable.release(p.raw_processor);
    _ = p.component.vtable.release(p.raw_component);
    // 注：**不卸载模块**（原 `p.mod.deinit()` 已移除，与 loadPlugin 同理）——
    // SFLT 类插件的后台线程/回调在 FreeLibrary 后会执行已卸载代码而崩；
    // 插件 DLL 常驻进程（行业惯例）。文件占用随进程退出释放。

    if (p.in_l.len > 0) allocator.free(p.in_l);
    if (p.in_r.len > 0) allocator.free(p.in_r);
    if (p.out_l.len > 0) allocator.free(p.out_l);
    if (p.out_r.len > 0) allocator.free(p.out_r);
    if (p.out_pool.len > 0) allocator.free(p.out_pool);
    if (p.params.len > 0) allocator.free(p.params);
    allocator.destroy(p);
}

// ── 编辑器宿主支撑（阶段 3）：独立顶层窗口 + 宿主侧 IPlugFrame ──

const editor_class_name = std.unicode.utf8ToUtf16LeStringLiteral("SawdustVstEditor");
/// WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX（无 WS_THICKFRAME：暂不让用户拉伸）
const WS_VISIBLE: u32 = 0x10000000;
const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
const RGN_DIFF: i32 = 4;

/// 插件子窗口裁切用的覆盖矩形（主窗口 client 坐标；`main` 侧收集）
pub const EditClipRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// 覆盖矩形 → 子窗口 client 坐标的相交矩形（`[x0,y0,x1,y1]`；不相交/退化 → null）。
/// 纯函数（单测）。
fn clipRectToClient(c: EditClipRect, ex: i32, ey: i32, ew: i32, eh: i32) ?[4]i32 {
    const x0 = @max(0, c.x - ex);
    const y0 = @max(0, c.y - ey);
    const x1 = @min(ew, c.x + c.w - ex);
    const y1 = @min(eh, c.y + c.h - ey);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ x0, y0, x1, y1 };
}
const SW_SHOWNA: i32 = 8;
const SW_HIDE: i32 = 0;
const GWLP_USERDATA: i32 = -21;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_SETFOCUS: u32 = 0x0007;
const WM_CLOSE: u32 = 0x0010;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = 0,
    style: u32 = 0,
    lpfnWndProc: ?*const fn (?*anyopaque, u32, usize, isize) callconv(.winapi) isize = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: ?*anyopaque = null,
};
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(*anyopaque) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(*anyopaque, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(*anyopaque, i32) callconv(.winapi) isize;
extern "user32" fn SetWindowPos(?*anyopaque, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn SetWindowRgn(?*anyopaque, ?*anyopaque, i32) callconv(.winapi) i32;
extern "user32" fn EnableWindow(?*anyopaque, i32) callconv(.winapi) i32;
extern "gdi32" fn CreateRectRgn(i32, i32, i32, i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CombineRgn(?*anyopaque, ?*anyopaque, ?*anyopaque, i32) callconv(.winapi) i32;
extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) i32;
extern "user32" fn SetFocus(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ShowWindow(?*anyopaque, i32) callconv(.winapi) i32;
/// `ShowWindow`：激活并显示
const SW_SHOW: i32 = 5;

/// 宿主侧 IPlugFrame：插件 `resizeView` 请求 → 记录尺寸 + 调整子窗口 + `onSize`。
/// 简化：ref 计数只记账（生命周期由 Plugin.closeEditor 掌控）。
const EditorFrame = extern struct {
    iface: iplugview.IPlugFrame = .{ .vtable = &vtable },
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    hwnd: ?*anyopaque = null,
    /// 所属插件（resizeView 时回写 editor_w/h）
    owner: *Plugin = undefined,

    pub fn asInterface(self: *EditorFrame) *iplugview.IPlugFrame {
        return &self.iface;
    }

    fn query(ptr: *anyopaque, iid: *const tuid.TUID, out: *?*anyopaque) callconv(.c) btypes.tresult {
        if (uidEq(iid, &funknown.iid) or uidEq(iid, &iplugview.iplug_frame_iid)) {
            _ = addRef(ptr);
            out.* = ptr;
            return btypes.kResultOk;
        }
        out.* = null;
        return btypes.kNoInterface;
    }

    fn addRef(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        const self: *EditorFrame = @fieldParentPtr("iface", @as(*iplugview.IPlugFrame, @ptrCast(@alignCast(ptr))));
        return self.ref_count.fetchAdd(1, .seq_cst) + 1;
    }

    fn release(ptr: *anyopaque) callconv(.c) btypes.uint32 {
        const self: *EditorFrame = @fieldParentPtr("iface", @as(*iplugview.IPlugFrame, @ptrCast(@alignCast(ptr))));
        return self.ref_count.fetchSub(1, .seq_cst) - 1;
    }

    fn resizeView(ptr: *anyopaque, view: ?*iplugview.IPlugView, rect: *iplugview.ViewRect) callconv(.c) btypes.tresult {
        const self: *EditorFrame = @fieldParentPtr("iface", @as(*iplugview.IPlugFrame, @ptrCast(@alignCast(ptr))));
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0 or w > 8192 or h > 8192) return btypes.kResultFalse;
        // 记录插件请求尺寸（面板按它布局）+ 立即调整子窗口（宿主调整平台窗口）
        self.owner.editor_w = w;
        self.owner.editor_h = h;
        if (self.owner.editor_hwnd) |hwnd| {
            _ = SetWindowPos(hwnd, null, self.owner.editor_x, self.owner.editor_y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        if (view) |v| {
            _ = v.vtable.onSize(v, rect); // 通知插件实际大小（规范流程）
        }
        return btypes.kResultOk;
    }

    const vtable = iplugview.IPlugFrameVTable{
        .queryInterface = query,
        .addRef = addRef,
        .release = release,
        .resizeView = resizeView,
    };
};

var editor_class_registered = false;

fn ensureEditorClass() bool {
    if (editor_class_registered) return true;
    var wc = WNDCLASSEXW{};
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = editorWndProc;
    wc.hInstance = GetModuleHandleW(null);
    wc.lpszClassName = editor_class_name;
    if (RegisterClassExW(&wc) == 0) return false;
    editor_class_registered = true;
    return true;
}

fn editorWndProc(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const raw = GetWindowLongPtrW(@ptrCast(hwnd), GWLP_USERDATA);
    const pl: ?*Plugin = if (raw != 0) @ptrFromInt(@as(usize, @bitCast(raw))) else null;
    switch (msg) {
        WM_CLOSE => {
            // 用户点 X：走宿主统一关闭流程（removed → 销毁窗口）
            if (pl) |p| p.closeEditor() else _ = DestroyWindow(@ptrCast(hwnd));
            return 0;
        },
        WM_SETFOCUS => {
            if (pl) |p| {
                if (p.view) |v| {
                    _ = v.vtable.onFocus(v, 1);
                }
            }
        },
        WM_KILLFOCUS => {
            if (pl) |p| {
                if (p.view) |v| {
                    _ = v.vtable.onFocus(v, 0);
                }
            }
        },
        else => {},
    }
    return DefWindowProcW(@ptrCast(hwnd), msg, wparam, lparam);
}

// ── 测试 ──

test "vst_host: 多输出求和混音（主静音 + 辅助立体声 + 单声道辅助）" {
    var pl = Plugin{
        .mod = undefined,
        .raw_component = undefined,
        .component = undefined,
        .raw_processor = undefined,
        .processor = undefined,
        .alloc = std.testing.allocator,
    };
    var b0: [4]f32 = .{ 0, 0, 0, 0 };
    var b1l: [4]f32 = .{ 1, 1, 1, 1 };
    var b1r: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 };
    var b2m: [4]f32 = .{ 0.25, 0.25, 0.25, 0.25 };
    pl.out_bus_count = 3;
    pl.out_chan_counts[0] = 2;
    pl.out_chan_counts[1] = 2;
    pl.out_chan_counts[2] = 1;
    pl.out_ptrs[0] = .{ &b0, &b0 };
    pl.out_ptrs[1] = .{ &b1l, &b1r };
    pl.out_ptrs[2] = .{ &b2m, &b2m };
    var buf: [8]f32 = undefined;
    mixMultiOut(&pl, &buf, 4);
    // 求和：L = 0 + 1 + 0.25；R = 0 + 0.5 + 0.25（单声道辅助混入两侧）
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), buf[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), buf[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), buf[6], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), buf[7], 1e-6);
}

test "vst_host: 覆盖矩形→子窗口 client 裁切坐标（SetWindowRgn 用）" {
    const E = struct {
        fn rc(x: i32, y: i32, w: i32, h: i32) EditClipRect {
            return .{ .x = x, .y = y, .w = w, .h = h };
        }
    };
    // 子窗位于 (100, 50)，尺寸 200x100
    const r1 = clipRectToClient(E.rc(150, 80, 20, 20), 100, 50, 200, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(i32, &.{ 50, 30, 70, 50 }, &r1); // 完全在内
    const r2 = clipRectToClient(E.rc(0, 0, 120, 70), 100, 50, 200, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 20, 20 }, &r2); // 左上溢出→钳制
    try std.testing.expect(clipRectToClient(E.rc(0, 0, 100, 50), 100, 50, 200, 100) == null); // 贴边不相交
    try std.testing.expect(clipRectToClient(E.rc(400, 400, 10, 10), 100, 50, 200, 100) == null); // 在外
}
