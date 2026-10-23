//! 三个效果器 DSP：**混响 / 延迟 / 压缩器**（`docs`：EQ 在 `eq.zig`）。
//!
//! 统一约定：
//! - **块处理**：就地处理一段立体声缓冲（交错 L/R），状态结构跨块连续；
//! - 参数按块读取（数组 `p`，含义见 `paramInfos`）——变化即时生效；
//! - 输出“湿信号”，干湿混合由调用方（`audio.renderSegment`）按槽 `mix` 完成；
//! - **每通道一份状态**（调用方持有数组；同类效果每通道至多一个实例——
//!   添加时由 `App.addEffect` 约束）。
//!
//! 混响为 Freeverb 风格（8 并联 comb + 4 串联 allpass，左右独立、宽度可调）；
//! 延迟为 1s 上限的立体声延时线（时间平滑滑移，避免调节时的爆音）；
//! 压缩器为立体声联动峰值检测（阈值/比率/启动/释放/补偿）。

const std = @import("std");

/// 参数位上限（与 `audio.Params.effect_p` 的第三维、`app.EffectSlot.p` 对齐）
pub const max_params = 5;

/// 参数元数据（UI 旋钮 / 默认值 / 范围共用一份描述）
pub const ParamInfo = struct {
    name: []const u8,
    /// 单位（显示用；"" = 无单位）
    unit: []const u8,
    min: f32,
    max: f32,
    default: f32,
};

const reverb_params = [_]ParamInfo{
    .{ .name = "空间", .unit = "", .min = 0, .max = 1, .default = 0.72 },
    .{ .name = "阻尼", .unit = "", .min = 0, .max = 1, .default = 0.5 },
    .{ .name = "宽度", .unit = "", .min = 0, .max = 1, .default = 1.0 },
};
/// 延迟节奏档位：`p[0]` 存的是**档位码**（= 下标）；拍数 × 每拍秒数 = 延迟时间。
/// 主流延迟都按音符时值卡拍（BPM 变化时回响随之伸缩）。
pub const delay_tempos = [_]struct { beats: f32, label: []const u8 }{
    .{ .beats = 2.0, .label = "1/2" },
    .{ .beats = 1.5, .label = "1/4." },
    .{ .beats = 1.0, .label = "1/4" },
    .{ .beats = 0.75, .label = "1/8." },
    .{ .beats = 2.0 / 3.0, .label = "1/4T" },
    .{ .beats = 0.5, .label = "1/8" },
    .{ .beats = 0.375, .label = "1/16." },
    .{ .beats = 1.0 / 3.0, .label = "1/8T" },
    .{ .beats = 0.25, .label = "1/16" },
    .{ .beats = 1.0 / 6.0, .label = "1/16T" },
    .{ .beats = 0.125, .label = "1/32" },
};
/// 默认档位（下标 5 = 1/8）
pub const delay_tempo_default: u32 = 5;

const delay_params = [_]ParamInfo{
    // p[0] 不是毫秒而是**节奏档位码**（见 `delay_tempos`）
    .{ .name = "节奏", .unit = "", .min = 0, .max = @floatFromInt(delay_tempos.len - 1), .default = @floatFromInt(delay_tempo_default) },
    .{ .name = "反馈", .unit = "", .min = 0, .max = 0.95, .default = 0.35 },
};
const compressor_params = [_]ParamInfo{
    .{ .name = "阈值", .unit = "dB", .min = -60, .max = 0, .default = -18 },
    .{ .name = "比率", .unit = ":1", .min = 1, .max = 20, .default = 4 },
    .{ .name = "启动", .unit = "ms", .min = 0.1, .max = 200, .default = 10 },
    .{ .name = "释放", .unit = "ms", .min = 10, .max = 2000, .default = 120 },
    .{ .name = "补偿", .unit = "dB", .min = 0, .max = 24, .default = 0 },
};

/// 效果器类型（音频侧 id）→ 参数表（unknown → 空表）
pub fn paramInfos(kind: u32) []const ParamInfo {
    return switch (kind) {
        2 => &reverb_params,
        3 => &delay_params,
        4 => &compressor_params,
        else => &.{},
    };
}

/// 按参数表填默认值（添加效果器时用；未用参数位补 0）
pub fn defaultParams(kind: u32) [max_params]f32 {
    var p: [max_params]f32 = .{ 0, 0, 0, 0, 0 };
    for (paramInfos(kind), 0..) |info, i| p[i] = info.default;
    return p;
}

/// 新建效果器时的**默认干湿比**（`EffectSlot.mix` / `effect_mix`）。
/// 混响/延迟**不能默认 1.0**（= 只有湿声、干声被吞——实测反馈：
/// “加了延迟后第一个音要等一个延迟时间才响”，其实听到的就是纯回响）；
/// 压缩器 1.0（全压是压缩的正常语义，并行压缩由用户自行下调）；
/// EQ 与干湿无关（全通滤波，取 1.0）。
pub fn defaultMix(kind: u32) f32 {
    return switch (kind) {
        2 => 0.30, // 混响
        3 => 0.35, // 延迟
        else => 1.0, // 压缩器 / EQ / 未知
    };
}

/// 便捷：钳制取值并按 info 数组打包读取（调用方已把原子值拷进 `p`）
fn get(p: *const [max_params]f32, infos: []const ParamInfo, i: usize) f32 {
    return std.math.clamp(p[i], infos[i].min, infos[i].max);
}

// ── 混响（Freeverb 风格）──

pub const Reverb = struct {
    // 组合滤波器基准长度（44.1kHz；实际按采样率缩放）
    const comb_base = [8]usize{ 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
    const allpass_base = [4]usize{ 556, 441, 341, 225 };
    /// 容量按 48kHz 缩放 + 余量（约 ×1.0884）
    const comb_cap = 1792;
    const allpass_cap = 608;

    comb_l: [8][comb_cap]f32 = @splat(@splat(0)),
    comb_r: [8][comb_cap]f32 = @splat(@splat(0)),
    comb_filt_l: [8]f32 = @splat(0),
    comb_filt_r: [8]f32 = @splat(0),
    comb_idx: [8]usize = @splat(0),
    comb_len: [8]usize = @splat(0),

    ap_l: [4][allpass_cap]f32 = @splat(@splat(0)),
    ap_r: [4][allpass_cap]f32 = @splat(@splat(0)),
    ap_idx: [4]usize = @splat(0),
    ap_len: [4]usize = @splat(0),

    sr: f32 = 0,
    /// 可用的 48k 上限容量（测试用小缓冲时由调用方直接构造）
    ready: bool = false,

    pub fn reset(self: *Reverb, sr: f32) void {
        self.sr = sr;
        const scale = sr / 44100.0;
        for (0..8) |i| {
            self.comb_len[i] = @min(@as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(comb_base[i])) * scale))), comb_cap);
            self.comb_len[i] = @max(self.comb_len[i], 8);
            self.comb_idx[i] = 0;
            self.comb_filt_l[i] = 0;
            self.comb_filt_r[i] = 0;
            @memset(&self.comb_l[i], 0);
            @memset(&self.comb_r[i], 0);
        }
        for (0..4) |i| {
            self.ap_len[i] = @min(@as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(allpass_base[i])) * scale))), allpass_cap);
            self.ap_len[i] = @max(self.ap_len[i], 4);
            self.ap_idx[i] = 0;
            @memset(&self.ap_l[i], 0);
            @memset(&self.ap_r[i], 0);
        }
        self.ready = true;
    }

    inline fn combStep(store: []f32, idx: *usize, filt: *f32, in: f32, feedback: f32, d1: f32, d2: f32) f32 {
        const out = store[idx.*];
        filt.* = out * d2 + filt.* * d1; // 阻尼低通
        store[idx.*] = in + filt.* * feedback;
        idx.* += 1;
        if (idx.* >= store.len) idx.* = 0;
        return out;
    }

    inline fn allpassStep(store: []f32, idx: *usize, in: f32) f32 {
        const bufout = store[idx.*];
        const out = -in + bufout;
        store[idx.*] = in + bufout * 0.5;
        idx.* += 1;
        if (idx.* >= store.len) idx.* = 0;
        return out;
    }

    pub fn process(self: *Reverb, buf: []f32, frames: u32, sr: f32, p: *const [max_params]f32, mix: f32) void {
        if (!self.ready or self.sr != sr) self.reset(sr);
        const feedback = 0.7 + 0.28 * get(p, &reverb_params, 0); // 空间
        const damp1 = get(p, &reverb_params, 1) * 0.4; // 阻尼
        const damp2 = 1.0 - damp1;
        const width = get(p, &reverb_params, 2);
        const in_gain: f32 = 0.015; // 经典 Freeverb 输入增益（配合反馈塑形）

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            const dry_l = buf[f * 2];
            const dry_r = buf[f * 2 + 1];
            const in_m = (dry_l + dry_r) * 0.5 * in_gain;

            var out_l: f32 = 0;
            var out_r: f32 = 0;
            inline for (0..8) |i| {
                out_l += combStep(self.comb_l[i][0..self.comb_len[i]], &self.comb_idx[i], &self.comb_filt_l[i], in_m, feedback, damp1, damp2);
                out_r += combStep(self.comb_r[i][0..self.comb_len[i]], &self.comb_idx[i], &self.comb_filt_r[i], in_m, feedback, damp1, damp2);
            }
            inline for (0..4) |i| {
                out_l = allpassStep(self.ap_l[i][0..self.ap_len[i]], &self.ap_idx[i], out_l);
                out_r = allpassStep(self.ap_r[i][0..self.ap_len[i]], &self.ap_idx[i], out_r);
            }
            // 宽度：mid/side 缩放（0 = 完全单声道、1 = 原样）
            const mid = (out_l + out_r) * 0.5;
            const side = (out_l - out_r) * 0.5 * width;
            const wet_l = mid + side;
            const wet_r = mid - side;

            buf[f * 2] = dry_l + (wet_l - dry_l) * mix;
            buf[f * 2 + 1] = dry_r + (wet_r - dry_r) * mix;
        }
    }
};

// ── 延迟（立体声延时线；时间平滑滑移）──

pub const Delay = struct {
    /// 缓冲容量：2 秒 @48kHz（主流“1/2 音符 @60BPM”也能卡拍；每通道 ≈768KB 堆内存）
    pub const cap_frames = 96000;

    buf_l: [cap_frames]f32 = @splat(0),
    buf_r: [cap_frames]f32 = @splat(0),
    idx: usize = 0,
    /// 当前（平滑中）的延迟样本数（f32：滑移时插值读取）
    cur_d: f32 = 0,
    sr: f32 = 0,
    ready: bool = false,

    pub fn reset(self: *Delay, sr: f32) void {
        self.sr = sr;
        self.idx = 0;
        self.cur_d = 0; // 采样率切换/首用：滑移距离从头开始（防残留超界）
        @memset(&self.buf_l, 0);
        @memset(&self.buf_r, 0);
        self.ready = true;
    }

    pub fn process(self: *Delay, buf: []f32, frames: u32, sr: f32, p: *const [max_params]f32, mix: f32, beat_secs: f32) void {
        if (!self.ready or self.sr != sr) self.reset(sr);
        const len = @min(cap_frames, @as(usize, @intFromFloat(@round(sr)))); // 容量上限
        // **节奏同步**：档位码 → 拍数 × 每拍秒数 → 样本数（卡拍；BPM 改变立即生效）
        const code: usize = @intFromFloat(std.math.clamp(@round(get(p, &delay_params, 0)), 0, @as(f32, @floatFromInt(delay_tempos.len - 1))));
        const beats = delay_tempos[code].beats;
        const target: f32 = @max(1.0, @min(beats * beat_secs * sr, @as(f32, @floatFromInt(len - 2))));
        const feedback = get(p, &delay_params, 1);

        // 时间**平滑滑移**（每块朝目标移动 1/8，最短 1 样本/块）：
        // 直接跳读指针会在调节时爆音；滑移带来轻微的“磁带式”变调感，符合直觉
        const step = (target - self.cur_d) / 8.0;
        var d = self.cur_d;
        const len_f: f32 = @floatFromInt(len);

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            if ((target - d) * (target - d) > 1.0) d += step; // >1 样本差距才继续滑
            if (d < 1.0) d = 1.0;
            if (d > len_f - 1.0) d = len_f - 1.0; // 采样率骤降时把旧距离拉回
            // 读取点 = idx − d，位于样本 (back2) 与 (back1) 之间。
            // **全整数寻址**：曾用浮点 pos±len 再 @floor，f32 在 48000 附近粒度 ~0.004，
            // 加法舍入可把 47999.998 舍成恰好 len → 偶发越界（fuzz 抓出，见回归测试）
            const di: usize = @intFromFloat(d); // 1 ≤ di ≤ len−1
            const fr = d - @as(f32, @floatFromInt(di)); // [0,1)
            const back1 = if (self.idx >= di) self.idx - di else self.idx + len - di;
            const back2 = if (back1 == 0) len - 1 else back1 - 1;
            const wet_l = self.buf_l[back1] + (self.buf_l[back2] - self.buf_l[back1]) * fr;
            const wet_r = self.buf_r[back1] + (self.buf_r[back2] - self.buf_r[back1]) * fr;

            const dry_l = buf[f * 2];
            const dry_r = buf[f * 2 + 1];
            self.buf_l[self.idx] = dry_l + wet_l * feedback;
            self.buf_r[self.idx] = dry_r + wet_r * feedback;
            self.idx += 1;
            if (self.idx >= len) self.idx = 0;

            buf[f * 2] = dry_l + (wet_l - dry_l) * mix;
            buf[f * 2 + 1] = dry_r + (wet_r - dry_r) * mix;
        }
        self.cur_d = d;
    }
};

// ── 压缩器（立体声联动峰值检测）──

pub const Compressor = struct {
    env: f32 = 0,
    gain: f32 = 1,
    sr: f32 = 0,

    pub fn reset(self: *Compressor, sr: f32) void {
        self.sr = sr;
        self.env = 0;
        self.gain = 1;
    }

    pub fn process(self: *Compressor, buf: []f32, frames: u32, sr: f32, p: *const [max_params]f32, mix: f32) void {
        if (self.sr != sr) self.reset(sr);
        const thr_db = get(p, &compressor_params, 0);
        const ratio = get(p, &compressor_params, 1);
        const atk_ms = get(p, &compressor_params, 2);
        const rel_ms = get(p, &compressor_params, 3);
        const make_db = get(p, &compressor_params, 4);

        const thr = std.math.pow(f32, 10.0, thr_db / 20.0);
        const makeup = std.math.pow(f32, 10.0, make_db / 20.0);
        const a_coef = @exp(-1.0 / @max(1.0, atk_ms * 0.001 * sr));
        const r_coef = @exp(-1.0 / @max(1.0, rel_ms * 0.001 * sr));
        const slope: f32 = 1.0 / ratio - 1.0; // ≤ 0

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            const dry_l = buf[f * 2];
            const dry_r = buf[f * 2 + 1];
            // 立体声联动：取两声道绝对值的较大者为检测输入（左右不漂移）
            const x = @max(@abs(dry_l), @abs(dry_r));
            const ec = if (x > self.env) a_coef else r_coef;
            self.env = self.env * ec + x * (1.0 - ec);
            // 目标增益（dB 域折点 → 线性）；再平滑一次（防 dB 折点抖动）
            var g: f32 = 1.0;
            if (self.env > thr and thr > 0) {
                g = std.math.pow(f32, self.env / thr, slope);
            }
            const gc = if (g < self.gain) a_coef else r_coef;
            self.gain = self.gain * gc + g * (1.0 - gc);

            const gg = self.gain * makeup;
            buf[f * 2] = dry_l + (dry_l * gg - dry_l) * mix;
            buf[f * 2 + 1] = dry_r + (dry_r * gg - dry_r) * mix;
        }
    }
};

// ── 测试 ──

const testing = std.testing;

fn rms(x: []const f32) f32 {
    var s: f32 = 0;
    for (x) |v| s += v * v;
    return @sqrt(s / @as(f32, @floatFromInt(x.len)));
}

test "effects: 参数表——默认值在范围内、未用位为空" {
    inline for (.{ 2, 3, 4 }) |kind| {
        const infos = paramInfos(kind);
        try testing.expect(infos.len > 0);
        const p = defaultParams(kind);
        for (infos, 0..) |info, i| {
            try testing.expect(p[i] >= info.min and p[i] <= info.max);
        }
        for (infos.len..max_params) |i| try testing.expectEqual(@as(f32, 0), p[i]);
    }
    try testing.expectEqual(@as(usize, 0), paramInfos(1).len); // EQ 在 eq.zig
    try testing.expectEqual(@as(usize, 0), paramInfos(99).len);
}

test "effects: 延迟——脉冲后按节奏档出现回波、隔一拍再来一次（反馈）" {
    // 堆分配：缓冲 768KB（cap 2s@48k），**不可放栈**
    const d = try testing.allocator.create(Delay);
    defer testing.allocator.destroy(d);
    d.* = Delay{};
    const sr: f32 = 48000;
    var p: [max_params]f32 = .{ 0, 0, 0, 0, 0 };
    p[0] = @floatFromInt(delay_tempo_default); // 1/8
    p[1] = 0.5; // 反馈
    // 240BPM → 每拍 0.25s → 1/8 = 0.125s = 6000 帧

    // 脉冲（帧 0 的 L）；缓冲均为交错 L/R → 数组长 = 帧数×2
    var buf: [2048 * 2]f32 = @splat(0);
    buf[0] = 1.0;
    d.process(&buf, 2048, sr, &p, 1.0, 0.25);

    var buf2: [8192 * 2]f32 = @splat(0);
    d.process(&buf2, 8192, sr, &p, 1.0, 0.25); // 累计到帧 10240
    var buf3: [8192 * 2]f32 = @splat(0);
    d.process(&buf3, 8192, sr, &p, 1.0, 0.25); // 累计到帧 18432

    // 第一回波：帧 6000 → buf2 内帧 3952，幅度 ≈1.0（滑移 8 帧内完成 → 容差 ±16 帧）
    var pos: usize = 0;
    var amp: f32 = 0;
    for (buf2, 0..) |v, i| {
        if (@abs(v) > amp) {
            amp = @abs(v);
            pos = i;
        }
    }
    try testing.expect(pos >= 3952 * 2 - 32 and pos <= 3952 * 2 + 32);
    try testing.expectApproxEqAbs(@as(f32, 1.0), amp, 0.05);

    // 第二回波（反馈 0.5）：帧 12000 → buf3 内帧 1760，幅度 ≈0.5
    var pos2: usize = 0;
    var amp2: f32 = 0;
    for (buf3, 0..) |v, i| {
        if (@abs(v) > amp2) {
            amp2 = @abs(v);
            pos2 = i;
        }
    }
    try testing.expect(pos2 >= 1760 * 2 - 32 and pos2 <= 1760 * 2 + 32);
    try testing.expectApproxEqAbs(@as(f32, 0.5), amp2, 0.05);
}

test "effects: 压缩器——超阈值被压、小信号原样" {
    const sr: f32 = 48000;
    var p: [max_params]f32 = .{ 0, 0, 0, 0, 0 };
    p[0] = -20; // 阈值
    p[1] = 4; // 比率
    p[2] = 1; // 启动 1ms（快速收敛便于测试）
    p[3] = 50;
    p[4] = 0;

    // 大信号 0.5（≈ -6dBFS，超越阈值 14dB → 理论增益 ≈ -10.5dB ≈ 0.30）
    var d = Compressor{};
    var buf: [24000 * 2]f32 = undefined;
    for (0..24000) |i| {
        const v = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    d.process(&buf, 24000, sr, &p, 1.0);
    const r_loud = rms(buf[(24000 / 2) * 2 ..]); // 尾段（增益已收敛）
    try testing.expect(r_loud < 0.5 * 0.45); // 明显被压

    // 小信号 0.01（≈ -40dBFS，阈值之下）→ 不被压
    var d2 = Compressor{};
    var buf2: [24000 * 2]f32 = undefined;
    for (0..24000) |i| {
        const v = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        buf2[i * 2] = v;
        buf2[i * 2 + 1] = v;
    }
    d2.process(&buf2, 24000, sr, &p, 1.0);
    const r_small_in = rms(buf2[(24000 / 2) * 2 ..]);
    try testing.expectApproxEqAbs(@as(f32, 0.01 * std.math.sqrt1_2), r_small_in, 0.002);
}

test "effects: 混响——脉冲后有持续尾音（能量延长）" {
    var r = Reverb{};
    const sr: f32 = 48000;
    const p = defaultParams(2);

    var buf: [48000]f32 = @splat(0);
    buf[0] = 1.0;
    r.process(&buf, 24000, sr, &p, 1.0);
    // 直声之后（>1000 样本）仍有非零尾音
    var tail: f32 = 0;
    for (buf[2000..20000]) |v| tail += @abs(v);
    try testing.expect(tail > 0.01);
    // 且尾音是**衰减**的：后段能量 < 前段
    var e1: f32 = 0;
    var e2: f32 = 0;
    for (buf[2000..10000]) |v| e1 += v * v;
    for (buf[16000..24000]) |v| e2 += v * v;
    try testing.expect(e2 < e1);
}

test "effects: 延迟随机模糊——极端参数不越界（回归：读取点曾用 f32 位置加减，舍入可越界）" {
    // 背景：旧实现把“读取点 = idx − d”算成 f32 再 ±len，f32 在 48000 附近
    // 粒度 ~0.004，加法舍入可把 47999.998 舍成恰好 len → 偶发越界。
    // 触发窗口窄（需 d 与 idx 相差 < 半个 ulp）——随机模糊比固定用例更容易抓到。
    var prng = std.Random.DefaultPrng.init(0x5a5a);
    const rnd = prng.random();
    // 堆分配：缓冲 768KB，**不可放栈**
    const d = try testing.allocator.create(Delay);
    defer testing.allocator.destroy(d);
    d.* = Delay{};
    var p: [max_params]f32 = @splat(0);
    p[0] = @floatFromInt(delay_tempo_default);
    p[1] = 0.35;
    var buf: [8192]f32 = undefined;
    var rsr: f32 = 48000;
    var i: usize = 0;
    while (i < 300_000) : (i += 1) {
        // 偶尔切换采样率（含骤降——reset 会把平滑距离清零）
        if (rnd.uintLessThan(u32, 200) == 0) {
            rsr = switch (rnd.uintLessThan(u8, 6)) {
                0 => 8000,
                1 => 22050,
                2 => 44100,
                3 => 48000,
                4 => 96000,
                else => 192000,
            };
        }
        if (rnd.uintLessThan(u32, 50) == 0) p[0] = rnd.float(f32) * 14.0 - 2.0; // 含越界码（走钳制）
        const bs: f32 = 0.05 + rnd.float(f32) * 3.0; // 每拍 0.05..3.05s（含超 cap 的截断路径）
        const f = rnd.uintLessThan(u32, 4097); // 含 0 帧、小块、满块
        @memset(buf[0 .. f * 2], 0);
        d.process(buf[0 .. f * 2], f, rsr, &p, 1.0, bs);
    }
}
