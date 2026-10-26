//! 音频导入（P2）：**单工作线程 + 队列 + 原子进度**。
//!
//! 设计要点（用户拍板）：
//! - **统一异步**：所有拖入都走这条路，没有"小文件同步快路径"；
//! - **单 worker**：同一时刻只有一个解码在跑 → 内存天然有界、并发面最小；
//! - **缓冲"轮到时"分配**（不是入队时）：队列里只放元数据，
//!   所以拖 5 个 30 分钟文件也不会一次性吃掉 3.5 GB；
//! - **分块解码**：每次读 `chunk_frames` 帧 —— 取消能及时响应（毫秒级），
//!   进度百分比也才有意义（整块读的话只有 0% 和 100%）。
//!
//! 线程契约（**硬性**，违反即崩/泄漏）：
//! - worker **只写自己 job 的缓冲与原子量**；不分配、不 free、不碰 `App`；
//! - 只有 UI 线程分配/释放/读 App 状态；
//! - 状态转移：`queued` --(UI 提升)--> `running` --(worker)--> `done|failed|cancelled`；
//! - `done` 之后由 UI 线程 `takeBuffers()` **过继**缓冲给资产池，`destroyJob` 不再释放它们。
const std = @import("std");
const ma = @import("c/miniaudio.zig");
const audio = @import("audio.zig");

/// 波形峰值桶（`App.AudioAsset.Peak` 直接复用它当单一真源）
pub const Peak = struct { min: f32, max: f32 };

pub const State = enum(u32) { queued, running, done, failed, cancelled };

pub const FailReason = enum(u8) {
    none = 0,
    open_failed,
    decode_failed,

    /// 失败原因文案（失败 toast 用）
    pub fn text(self: FailReason) []const u8 {
        return switch (self) {
            .none => "",
            .open_failed => "打不开文件（格式不支持/文件缺失）",
            .decode_failed => "解码失败或内存不足",
        };
    }
};

/// 存储计划（**P3a**：导入时定，解码/分配/取样三方共用）
///
/// 内存对比（立体声 48k，1 分钟）：
/// - 16-bit 源 → `i16` 立体声 4 B/帧 = 11 MB；单声道再减半 = 5.5 MB
/// - 24/32f 源 → `f32`（零损失，不省）
pub const Plan = struct {
    /// true = 存 `i16`（位深 ≤ 16、以及有损格式）；false = 存 `f32`
    store_s16: bool = true,
    /// 1 = 单声道（**保留**，不强制上混）；2 = 立体声
    channels: u8 = 2,

    pub fn maFormat(self: Plan) ma.ma_format {
        return if (self.store_s16) ma.ma_format_s16 else ma.ma_format_f32;
    }

    pub fn maChannels(self: Plan) u32 {
        return if (self.channels < 2) 1 else 2;
    }

    /// 每采样点字节数
    pub fn bytesPerSample(self: Plan) u64 {
        return if (self.store_s16) @sizeOf(i16) else @sizeOf(f32);
    }
};

/// 阶段 A（UI 线程，毫秒级）读到的文件头信息
pub const Header = struct {
    native_sr: u32,
    /// 原生帧数
    total_frames: u64,
    /// 引擎帧数（`total / ratio`；**解码前**就能算出片段长度）
    eng_frames: u64,
    /// 存储计划（声道数 + i16/f32）
    plan: Plan = .{},
};

/// 单文件内存预算：超过就拒绝导入。
/// 替代旧的“30 分钟上限”——同样时长在不同格式/声道下能差 4 倍，按字节算才准。
/// 16-bit 立体声 48k 下 ≈ 91 分钟。
pub const max_file_bytes: u64 = 1 << 30; // 1 GB

/// 只读文件头用的 IO（同步 open/read，不触发线程池）。
/// Zig 0.17 起文件 API 必须带 `std.Io`，而 `probeFile`/`decodeAll` 的调用点
/// （模型层、测试）手上没有 io —— 所以这里放一个惰性初始化的单例。
var header_io: ?std.Io.Threaded = null;

fn fileIo() std.Io {
    if (header_io == null) header_io = .init(std.heap.page_allocator, .{});
    return header_io.?.io();
}

/// 读容器位深（决定 i16 / f32）。`null` = 无法判断 → 用 f32 兜底（宁可不省也不降精度）。
/// - WAV：`fmt ` 块的 `wBitsPerSample`；`WAVE_FORMAT_EXTENSIBLE` 一律当 >16（可能是 24-in-32）
/// - FLAC：`STREAMINFO` 的 bits-per-sample
/// - MP3 / OGG（有损）：16—— 编码噪底本来远高于 −96 dB
fn sourceBitDepth(path: []const u8) ?u16 {
    const io = fileIo();
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readPositionalAll(io, buf[0..], 0) catch return null;
    const h: []const u8 = buf[0..n];

    if (h.len >= 12 and std.mem.eql(u8, h[0..4], "RIFF") and std.mem.eql(u8, h[8..12], "WAVE")) {
        var off: usize = 12;
        while (off + 8 <= h.len) {
            const sz: usize = std.mem.readInt(u32, h[off + 4 ..][0..4], .little);
            if (std.mem.eql(u8, h[off .. off + 4], "fmt ")) {
                if (off + 24 > h.len) return null;
                const afmt = std.mem.readInt(u16, h[off + 8 ..][0..2], .little);
                const bits = std.mem.readInt(u16, h[off + 22 ..][0..2], .little);
                if (afmt == 0xFFFE) return null; // extensible：可能 24-in-32，保守走 f32
                return if (bits == 0) null else bits;
            }
            off += 8 + sz + (sz & 1);
        }
        return null;
    }
    if (h.len >= 26 and std.mem.eql(u8, h[0..4], "fLaC")) {
        // STREAMINFO 必须是第一个元数据块：magic(4) + 块头(4) → 数据从 8 开始
        // 其内 offset 10 起是 8 字节打包字段：20b 采样率 + 3b 声道 + 5b 位深 + 36b 总帧数
        const v = std.mem.readInt(u64, h[18..26], .big);
        const bps: u16 = @intCast((v >> 36) & 0x1F);
        return if (bps == 0) null else bps;
    }
    if (h.len >= 4) {
        if (std.mem.eql(u8, h[0..4], "OggS")) return 16;
        if (std.mem.eql(u8, h[0..3], "ID3")) return 16;
        if (h[0] == 0xFF and (h[1] & 0xE0) == 0xE0) return 16; // MPEG 帧同步
    }
    return null;
}

/// 单次解码块（帧）：48 kHz 下约 0.68 s。取 64k 是"取消响应 vs 调用开销"的折中。
const chunk_frames: usize = 65536;

/// 峰值目标桶数（与历史实现保持一致，UI 波形数量感不变）
const peak_buckets: usize = 4096;

pub const Job = struct {
    /// 源文件路径（job 独占；UI 线程 dup/free）
    path: []u8 = &.{},
    /// 目标音频样式下标（完成前该样式的 `asset == -1`）
    style: usize = 0,
    native_sr: u32 = 0,
    eng_sr: u32 = 0,
    total_frames: u64 = 0,
    /// 引擎帧数（片段长度来源；来自文件头）
    eng_frames: u64 = 0,

    // ── 提升为 active 时在 UI 线程分配（worker 只写内容）──
    /// 存储计划：决定 `frames_s16` / `frames_f32` 哪个非空
    plan: Plan = .{},
    frames_s16: []i16 = &.{},
    frames_f32: []f32 = &.{},
    peaks: []Peak = &.{},
    peak_frames: u32 = 0,
    /// 完成时实际解出的帧数（< total 表示文件比头里声明的短）
    got_frames: u64 = 0,

    state: std.atomic.Value(State) = .init(.queued),
    cancel: std.atomic.Value(bool) = .init(false),
    done_frames: std.atomic.Value(u64) = .init(0),
    fail_reason: std.atomic.Value(u8) = .init(0),

    /// 进度（0..1）；total == 0 时按 0 处理
    pub fn progress(self: *const Job) f32 {
        const total = self.total_frames;
        if (total == 0) return 0;
        const done = @min(self.done_frames.load(.acquire), total);
        return @floatCast(@as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total)));
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    started: bool = false,

    /// 待处理（只有元数据；缓冲在提升时才分配）
    queue: std.ArrayListUnmanaged(*Job) = .empty,
    /// 正在解码的 job（同一时刻最多一个）
    active: ?*Job = null,
    /// 交给 worker 的指针：UI 写 → wake；worker 取走后清 null
    handoff: std.atomic.Value(?*Job) = .init(null),
    /// 唤醒序号（配合 futex；worker 侧零轮询、空闲零 CPU）
    wake: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,

    // ── 阶段 A：读文件头（UI 线程；毫秒级）──
    /// 打开解码器只取格式与时长；失败/非音频/超长 → null
    pub fn probeFile(path: []const u8, eng_sr: u32) ?Header {
        var wbuf: [1024]u16 = undefined;
        const w = toWide(path, &wbuf) orelse return null;
        const cfg = ma.ma_decoder_config_init(ma.ma_format_f32, 0, 0);
        var dec: ma.ma_decoder = undefined;
        if (ma.ma_decoder_init_file_w(@ptrCast(w.ptr), &cfg, &dec) != ma.MA_SUCCESS) return null;
        defer _ = ma.ma_decoder_uninit(&dec);

        var native_sr: ma.ma_uint32 = eng_sr;
        var ch_out: ma.ma_uint32 = 2;
        var fmt_out: ma.ma_format = ma.ma_format_f32;
        if (ma.ma_decoder_get_data_format(&dec, &fmt_out, &ch_out, &native_sr, null, 0) != ma.MA_SUCCESS) return null;
        if (native_sr == 0) native_sr = eng_sr;
        if (ch_out == 0) ch_out = 2; // 防御：个别后端不给声道信息
        var total: ma.ma_uint64 = 0;
        if (ma.ma_decoder_get_length_in_pcm_frames(&dec, &total) != ma.MA_SUCCESS) return null;
        if (total == 0) return null;

        // 存储计划：位深 ≤ 16 / 有损 → i16；24·32f / 未知 → f32。声道 ≥ 2 一律存 2。
        const plan: Plan = .{
            .store_s16 = (sourceBitDepth(path) orelse 32) <= 16,
            .channels = if (ch_out >= 2) 2 else 1,
        };
        // 内存闸门（字节，不是时长）
        const need: u64 = @as(u64, total) * plan.maChannels() * plan.bytesPerSample();
        if (need > max_file_bytes) return null;

        const sr_eng: u64 = @max(1, eng_sr);
        const eng_frames: u64 = @intCast(@as(u64, total) * sr_eng / @as(u64, native_sr));
        return .{
            .native_sr = @intCast(native_sr),
            .total_frames = @intCast(total),
            .eng_frames = @max(1, eng_frames),
            .plan = plan,
        };
    }

    /// 峰值分桶（UI 线程在提升时用；与历史实现同口径）
    fn bucketFor(total_frames: u64) struct { bucket: usize, npeaks: usize } {
        const n: usize = @intCast(@max(1, total_frames));
        const bucket: usize = @max(1, n / peak_buckets);
        const npeaks: usize = (n + bucket - 1) / bucket;
        return .{ .bucket = bucket, .npeaks = @max(1, npeaks) };
    }

    /// 单遍峰值更新（供 worker 与同步导入共用——**唯一一份算法**）
    /// 格式分支只判一次，内层循环无 switch。
    pub fn updatePeaks(
        frames: audio.SampleFrames,
        channels: u8,
        s0: usize,
        s1: usize,
        peaks: []Peak,
        bucket: usize,
        stride: usize,
    ) void {
        const mono = channels < 2;
        switch (frames) {
            .s16 => |fs| updatePeaksSlice(i16, fs, 1.0 / 32768.0, mono, s0, s1, peaks, bucket, stride),
            .f32 => |fs| updatePeaksSlice(f32, fs, 1.0, mono, s0, s1, peaks, bucket, stride),
        }
    }

    /// 样本值 → f32（i16/f32 两种元素类型共用一套循环）
    inline fn toF32(comptime T: type, v: T) f32 {
        return if (T == f32) v else @floatFromInt(v);
    }

    fn updatePeaksSlice(
        comptime T: type,
        fs: []const T,
        scale: f32,
        mono: bool,
        s0: usize,
        s1: usize,
        peaks: []Peak,
        bucket: usize,
        stride: usize,
    ) void {
        if (bucket == 0 or peaks.len == 0) return;
        var pi = s0 / bucket;
        while (pi < peaks.len and pi * bucket < s1) : (pi += 1) {
            const b0 = @max(s0, pi * bucket);
            const b1 = @min(s1, (pi + 1) * bucket);
            if (b1 <= b0) continue;
            var mn: f32 = 1;
            var mx: f32 = -1;
            var fi = b0;
            while (fi < b1) : (fi += stride) {
                const m: f32 = if (mono)
                    toF32(T, fs[fi]) * scale
                else
                    (toF32(T, fs[fi * 2]) + toF32(T, fs[fi * 2 + 1])) * 0.5 * scale;
                mn = @min(mn, m);
                mx = @max(mx, m);
            }
            if (mn > mx) {
                mn = 0;
                mx = 0;
            }
            if (b0 == pi * bucket) {
                peaks[pi] = .{ .min = mn, .max = mx };
            } else { // 跨块桶：取更宽的包络
                peaks[pi] = .{ .min = @min(peaks[pi].min, mn), .max = @max(peaks[pi].max, mx) };
            }
        }
    }

    /// 首次使用时启动 worker（拿到 allocator/io 后必须调一次）
    fn ensureStarted(self: *Manager, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.started) return;
        self.allocator = allocator;
        self.io = io;
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
        self.started = true;
    }

    // ── 阶段 A：入队（UI 线程）──
    pub fn enqueue(
        self: *Manager,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        style: usize,
        hdr: Header,
        eng_sr: u32,
    ) ?*Job {
        self.ensureStarted(allocator, io);
        const job = self.allocator.create(Job) catch return null;
        const p = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(job);
            return null;
        };
        job.* = .{
            .path = p,
            .style = style,
            .native_sr = hdr.native_sr,
            .eng_sr = @max(1, eng_sr),
            .total_frames = hdr.total_frames,
            .eng_frames = hdr.eng_frames,
            .plan = hdr.plan,
        };
        self.queue.append(self.allocator, job) catch {
            self.allocator.free(p);
            self.allocator.destroy(job);
            return null;
        };
        return job;
    }

    /// UI 每帧：取走**已结束**的 active（done/failed/cancelled），交给 App 收尾。
    pub fn takeFinished(self: *Manager) ?*Job {
        const job = self.active orelse return null;
        const st = job.state.load(.acquire);
        if (st == .queued or st == .running) return null;
        self.active = null;
        return job;
    }

    /// UI 每帧：空闲且队列非空 → **在这里分配缓冲**（不在入队时）→ 唤醒 worker。
    /// 分配失败：把该 job 直接标 failed 并留在 active，等 `takeFinished` 收尾。
    pub fn promote(self: *Manager) void {
        if (self.active != null) return;
        const job = blk: {
            if (self.queue.items.len == 0) return;
            break :blk self.queue.orderedRemove(0);
        };
        self.active = job;
        const nframes: usize = @intCast(@max(1, job.total_frames));
        const b = bucketFor(job.total_frames);
        const n_samples = nframes * job.plan.maChannels();
        if (job.plan.store_s16) {
            job.frames_s16 = self.allocator.alloc(i16, n_samples) catch {
                job.fail_reason.store(@backingInt(FailReason.decode_failed), .release);
                job.state.store(.failed, .release);
                return;
            };
        } else {
            job.frames_f32 = self.allocator.alloc(f32, n_samples) catch {
                job.fail_reason.store(@backingInt(FailReason.decode_failed), .release);
                job.state.store(.failed, .release);
                return;
            };
        }
        job.peaks = self.allocator.alloc(Peak, b.npeaks) catch {
            freeFrames(self.allocator, job);
            job.fail_reason.store(@backingInt(FailReason.decode_failed), .release);
            job.state.store(.failed, .release);
            return;
        };
        job.peak_frames = @intCast(b.bucket);
        job.state.store(.running, .release);
        self.handoff.store(job, .release);
        _ = self.wake.fetchAdd(1, .release);
        std.Io.futexWake(self.io, u32, &self.wake.raw, 1);
    }

    /// 队列里还有活 / 正在解码
    pub fn busy(self: *const Manager) bool {
        return self.active != null or self.queue.items.len > 0;
    }

    /// 某个音频样式的导入进度（含排队中的：按 0% 处理）
    pub fn progressFor(self: *const Manager, style: usize) ?f32 {
        if (self.active) |a| {
            if (a.style == style) return a.progress();
        }
        for (self.queue.items) |q| {
            if (q.style == style) return 0;
        }
        return null;
    }

    /// 取消某个样式的导入：排队中的直接摘掉，正在解码的置取消标记
    pub fn cancelStyle(self: *Manager, style: usize) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (self.queue.items[i].style == style) {
                const job = self.queue.orderedRemove(i);
                self.destroyJob(job);
                continue;
            }
            i += 1;
        }
        if (self.active) |a| {
            if (a.style == style) a.cancel.store(true, .release);
        }
    }

    /// 删除音频样式后修索引：引用被删样式的 job 取消，更大索引的 job 前移
    pub fn remapAfterRemove(self: *Manager, removed: usize) void {
        if (!self.started) return;
        self.cancelStyle(removed);
        for (self.queue.items) |job| {
            if (job.style > removed) job.style -= 1;
        }
        if (self.active) |a| {
            if (a.style > removed) a.style -= 1;
        }
    }

    /// 全部取消（撤销/重做/换工程/退出前）
    pub fn cancelAll(self: *Manager) void {
        if (!self.started) return;
        for (self.queue.items) |job| self.destroyJob(job);
        self.queue.clearRetainingCapacity();
        if (self.active) |a| a.cancel.store(true, .release);
    }

    /// 阻塞等待 active 结束（换工程/退出前用；必须**在释放资产池之前**）。
    /// 只在 UI 线程的用户动作里调用，最多等一个解码块（毫秒级）。
    pub fn drain(self: *Manager) void {
        if (!self.started) return;
        const io = self.io;
        var spins: usize = 0;
        while (self.active) |a| {
            const st = a.state.load(.acquire);
            if (st != .queued and st != .running) {
                self.destroyJob(a);
                self.active = null;
                break;
            }
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            spins += 1;
            if (spins > 5000) { // 5 s 兜底：正常永远走不到
                self.destroyJob(a);
                self.active = null;
                break;
            }
        }
        for (self.queue.items) |job| self.destroyJob(job);
        self.queue.clearRetainingCapacity();
    }

    /// 过继的缓冲（UI 线程拿到后写进资产池）
    pub const Buffers = struct {
        frames: audio.SampleFrames,
        plan: Plan,
        peaks: []Peak,
        peak_frames: u32,
        got_frames: u64,
    };

    /// 过继缓冲给资产池（UI 线程；之后 `destroyJob` 不再释放它们）
    pub fn takeBuffers(self: *Manager, job: *Job) Buffers {
        _ = self;
        const out: Buffers = .{
            .frames = framesOf(job),
            .plan = job.plan,
            .peaks = job.peaks,
            .peak_frames = job.peak_frames,
            .got_frames = job.got_frames,
        };
        job.frames_s16 = &.{};
        job.frames_f32 = &.{};
        job.peaks = &.{};
        return out;
    }

    /// job 的帧存储（两种布局二选一）
    inline fn framesOf(job: *const Job) audio.SampleFrames {
        return if (job.plan.store_s16) .{ .s16 = job.frames_s16 } else .{ .f32 = job.frames_f32 };
    }

    /// 释放 job 的帧缓冲（不碰 peaks/path）
    fn freeFrames(allocator: std.mem.Allocator, job: *Job) void {
        framesOf(job).freeFrames(allocator);
        job.frames_s16 = &.{};
        job.frames_f32 = &.{};
    }

    /// 销毁 job（未过继的缓冲在这里释放）
    pub fn destroyJob(self: *Manager, job: *Job) void {
        freeFrames(self.allocator, job);
        if (job.peaks.len > 0) self.allocator.free(job.peaks);
        if (job.path.len > 0) self.allocator.free(job.path);
        self.allocator.destroy(job);
    }

    /// 退出：停 worker（join）并清空一切
    pub fn deinit(self: *Manager) void {
        if (!self.started) return;
        self.quit.store(true, .release);
        _ = self.wake.fetchAdd(1, .release);
        std.Io.futexWake(self.io, u32, &self.wake.raw, 1);
        if (self.worker) |t| t.join();
        self.worker = null;
        if (self.active) |a| {
            self.destroyJob(a);
            self.active = null;
        }
        for (self.queue.items) |job| self.destroyJob(job);
        self.queue.deinit(self.allocator);
        self.queue = .empty;
        self.started = false;
    }

    // ── 阶段 B：worker ──
    fn workerMain(self: *Manager) void {
        var seen: u32 = 0;
        while (true) {
            // 等活（futex：空闲时零 CPU 占用，不轮询）
            while (true) {
                if (self.quit.load(.acquire)) return;
                const seq = self.wake.load(.acquire);
                if (seq != seen) {
                    seen = seq;
                    break;
                }
                std.Io.futexWaitUncancelable(self.io, u32, &self.wake.raw, seq);
            }
            const job = self.handoff.swap(null, .acquire) orelse continue;
            runJob(job);
        }
    }

    fn runJob(job: *Job) void {
        if (job.cancel.load(.acquire)) {
            job.state.store(.cancelled, .release);
            return;
        }
        const bucket: usize = @intCast(@max(1, job.peak_frames));
        switch (decodeInto(job.path, job.plan, job.total_frames, framesOf(job), job.peaks, bucket, &job.cancel, &job.done_frames)) {
            .ok => |n| {
                job.got_frames = @intCast(n);
                job.done_frames.store(@intCast(n), .release);
                job.state.store(.done, .release);
            },
            .cancelled => job.state.store(.cancelled, .release),
            .open_failed => {
                job.fail_reason.store(@backingInt(FailReason.open_failed), .release);
                job.state.store(.failed, .release);
            },
            .decode_failed => {
                job.fail_reason.store(@backingInt(FailReason.decode_failed), .release);
                job.state.store(.failed, .release);
            },
        }
    }
};

/// UTF-8 → UTF-16LE（含 NUL）；失败 null。
/// 中文路径必须走宽字符 API（同 VST3 加载的坑），这层在 3 处用到。
fn toWide(path: []const u8, wbuf: []u16) ?[]u16 {
    const wn = std.unicode.utf8ToUtf16Le(wbuf, path) catch return null;
    if (wn + 1 > wbuf.len) return null;
    wbuf[wn] = 0;
    return wbuf[0 .. wn + 1];
}

/// 按存储计划打开解码器
fn openDecoder(path: []const u8, plan: Plan, dec: *ma.ma_decoder) bool {
    var wbuf: [1024]u16 = undefined;
    const w = toWide(path, &wbuf) orelse return false;
    const cfg = ma.ma_decoder_config_init(plan.maFormat(), plan.maChannels(), 0);
    return ma.ma_decoder_init_file_w(@ptrCast(w.ptr), &cfg, dec) == ma.MA_SUCCESS;
}

/// 同步解码结果（同步路径用：采样器层 / 旧工程 / 测试夹具）
pub const Decoded = struct {
    frames: audio.SampleFrames,
    plan: Plan,
    peaks: []Peak,
    peak_frames: u32,
    frame_count: usize,
    native_sr: u32,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        self.frames.freeFrames(allocator);
        if (self.peaks.len > 0) allocator.free(self.peaks);
    }
};

/// 解码结果（worker 用它区分失败类型 → 写入 `fail_reason`）
const DecodeOutcome = union(enum) {
    /// 实际解码帧数
    ok: usize,
    cancelled,
    open_failed,
    decode_failed,
};

/// **唯一的解码循环**（worker 与同步路径共用）。
/// `cancel` / `done` 传 null = 同步路径（不响应取消、不写进度）。
/// 尾部未解码到的峰值桶会置零（文件实际长度 < 头里声明的长度时）。
fn decodeInto(
    path: []const u8,
    plan: Plan,
    total_frames: u64,
    frames: audio.SampleFrames,
    peaks: []Peak,
    bucket: usize,
    cancel: ?*const std.atomic.Value(bool),
    done: ?*std.atomic.Value(u64),
) DecodeOutcome {
    var dec: ma.ma_decoder = undefined;
    if (!openDecoder(path, plan, &dec)) return .open_failed;
    defer _ = ma.ma_decoder_uninit(&dec);

    const nframes: usize = @intCast(@max(1, total_frames));
    const nch: usize = plan.maChannels();
    const bk: usize = @max(1, bucket);
    const stride: usize = if (bk > 32) @max(1, bk / 16) else 1;
    var got_total: usize = 0;
    while (got_total < nframes) {
        if (cancel) |c| {
            if (c.load(.acquire)) return .cancelled;
        }
        const want: usize = @min(nframes - got_total, chunk_frames);
        var got: ma.ma_uint64 = 0;
        const dst: ?*anyopaque = switch (frames) {
            .s16 => |v| @ptrCast(@constCast(v.ptr) + got_total * nch),
            .f32 => |v| @ptrCast(@constCast(v.ptr) + got_total * nch),
        };
        if (ma.ma_decoder_read_pcm_frames(&dec, dst, @intCast(want), &got) != ma.MA_SUCCESS) {
            return .decode_failed;
        }
        if (got == 0) break;
        const s0 = got_total;
        const s1 = got_total + @as(usize, @intCast(got));
        Manager.updatePeaks(frames, plan.channels, s0, s1, peaks, bk, stride);
        got_total = s1;
        if (done) |d| d.store(@intCast(got_total), .release);
    }
    var pz = got_total / bk;
    while (pz < peaks.len) : (pz += 1) peaks[pz] = .{ .min = 0, .max = 0 };
    return .{ .ok = got_total };
}

/// 同步整文件解码（与异步路径**共用**存储计划/解码循环/宽路径）。
/// 失败/超预算 → null。
pub fn decodeAll(allocator: std.mem.Allocator, path: []const u8, eng_sr: u32) ?Decoded {
    const hdr = Manager.probeFile(path, eng_sr) orelse return null;
    const plan = hdr.plan;
    const nframes: usize = @intCast(@max(1, hdr.total_frames));
    const b = Manager.bucketFor(hdr.total_frames);

    var out: Decoded = .{
        .frames = .{ .s16 = &.{} },
        .plan = plan,
        .peaks = &.{},
        .peak_frames = @intCast(b.bucket),
        .frame_count = 0,
        .native_sr = hdr.native_sr,
    };
    const n_samples = nframes * plan.maChannels();
    if (plan.store_s16) {
        out.frames = .{ .s16 = allocator.alloc(i16, n_samples) catch return null };
    } else {
        out.frames = .{ .f32 = allocator.alloc(f32, n_samples) catch return null };
    }
    out.peaks = allocator.alloc(Peak, b.npeaks) catch {
        out.deinit(allocator);
        return null;
    };

    switch (decodeInto(path, plan, hdr.total_frames, out.frames, out.peaks, b.bucket, null, null)) {
        .ok => |n| {
            if (n == 0) {
                out.deinit(allocator);
                return null;
            }
            out.frame_count = n;
        },
        else => {
            out.deinit(allocator);
            return null;
        },
    }
    return out;
}
