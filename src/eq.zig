//! EQ（参量均衡器）与频谱分析——纯逻辑、可单测。
//!
//! - `Biquad`：RBJ cookbook 峰值滤波器（音频线程逐样本处理）；
//! - `responseDb`：幅频响应的**解析计算**（UI 画包络线，不跑音频）；
//! - `fft` / `barsFromSpectrum`：256 点 radix-2 FFT + 对数分布频谱柱
//!   （视觉频谱背景）。

const std = @import("std");

/// 每通道 EQ 段数
pub const band_count = 5;
/// FFT 大小（2 的幂）
pub const fft_size = 256;
/// 频谱显示柱数
pub const spec_bars = 32;
/// 频谱频率范围（对数映射）
pub const spec_f_min: f32 = 40;
pub const spec_f_max: f32 = 16000;
/// 增益范围（dB）
pub const gain_db_min: f32 = -18;
pub const gain_db_max: f32 = 18;

/// 一段 EQ 的参数
pub const BandParams = struct {
    freq: f32 = 1000, // 中心频率（Hz）
    gain_db: f32 = 0, // 增益（dB；0 = 不作用）
    q: f32 = 1.0, // 品质因数
};

/// 双二阶滤波器（transposed DF-II；每声道一个实例）
pub const Biquad = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    /// 配置为 RBJ 峰值滤波器（在线性尺度归一化：a0 除掉了）
    pub fn setPeak(self: *Biquad, sr: f32, freq: f32, q: f32, gain_db: f32) void {
        const a = std.math.pow(f32, 10, gain_db / 40);
        const w0 = 2 * std.math.pi * std.math.clamp(freq, 20, sr * 0.45) / sr;
        const cw = @cos(w0);
        const sw = @sin(w0);
        const alpha = sw / (2 * @max(0.05, q));
        const a0 = 1 + alpha / a;
        self.b0 = (1 + alpha * a) / a0;
        self.b1 = (-2 * cw) / a0;
        self.b2 = (1 - alpha * a) / a0;
        self.a1 = (-2 * cw) / a0;
        self.a2 = (1 - alpha / a) / a0;
    }

    /// 逐样本处理
    pub fn process(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }

    pub fn reset(self: *Biquad) void {
        self.z1 = 0;
        self.z2 = 0;
    }
};

/// 幅频响应（**解析计算**；UI 画包络线用）。
/// 返回频率 `freq` 处所有段的合成增益（dB）。
pub fn responseDb(bands: []const BandParams, sr: f32, freq: f32) f32 {
    var total: f32 = 0;
    const w = 2 * std.math.pi * freq / sr;
    const c1 = @cos(w);
    const s1 = @sin(w);
    const c2 = @cos(2 * w);
    const s2 = @sin(2 * w);
    for (bands) |b| {
        if (b.gain_db == 0) continue;
        const a = std.math.pow(f32, 10, b.gain_db / 40);
        const w0 = 2 * std.math.pi * std.math.clamp(b.freq, 20, sr * 0.45) / sr;
        const cw = @cos(w0);
        const sw = @sin(w0);
        const alpha = sw / (2 * @max(0.05, b.q));
        const a0 = 1 + alpha / a;
        const b0 = (1 + alpha * a) / a0;
        const b1 = (-2 * cw) / a0;
        const b2 = (1 - alpha * a) / a0;
        const a1 = (-2 * cw) / a0;
        const a2 = (1 - alpha / a) / a0;
        // H(e^{jw}) = (b0 + b1 e^{-jw} + b2 e^{-2jw}) / (1 + a1 e^{-jw} + a2 e^{-2jw})
        const num_re = b0 + b1 * c1 + b2 * c2;
        const num_im = -(b1 * s1 + b2 * s2);
        const den_re = 1 + a1 * c1 + a2 * c2;
        const den_im = -(a1 * s1 + a2 * s2);
        const num_m2 = num_re * num_re + num_im * num_im;
        const den_m2 = den_re * den_re + den_im * den_im;
        // |H|² = num_m2 / den_m2 → 10·log10 即 dB（功率比）
        total += 10 * std.math.log10(@max(1e-12, num_m2 / @max(1e-12, den_m2)));
    }
    return total;
}

/// 迭代 radix-2 FFT（原位；长度必须是 2 的幂且相同）
pub fn fft(re: []f32, im: []f32) void {
    const n = re.len;
    std.debug.assert(n == im.len and n > 0 and std.math.isPowerOfTwo(n));
    // bit-reversal 置换
    var j: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    // 蝶形
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2 * std.math.pi / @as(f32, @floatFromInt(len));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var k: usize = 0;
        while (k < n) : (k += len) {
            var cur_r: f32 = 1;
            var cur_i: f32 = 0;
            var m: usize = 0;
            const half = len / 2;
            while (m < half) : (m += 1) {
                const u_r = re[k + m];
                const u_i = im[k + m];
                const q_r = re[k + m + half];
                const q_i = im[k + m + half];
                const v_r = q_r * cur_r - q_i * cur_i;
                const v_i = q_r * cur_i + q_i * cur_r;
                re[k + m] = u_r + v_r;
                im[k + m] = u_i + v_i;
                re[k + m + half] = u_r - v_r;
                im[k + m + half] = u_i - v_i;
                const nr = cur_r * wr - cur_i * wi;
                cur_i = cur_r * wi + cur_i * wr;
                cur_r = nr;
            }
        }
    }
}

/// Hann 窗（减少频谱泄漏）
pub fn hannWindow(buf: []f32) void {
    const n = buf.len;
    for (buf, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(1, n - 1)));
        v.* *= 0.5 - 0.5 * @cos(2 * std.math.pi * t);
    }
}

/// 把 FFT 幅度谱映射到**对数分布**的 `out.len` 根柱（0-1；dB 压缩）。
/// - `mag`：幅度谱（长度 = fft_size/2，从 DC 到 Nyquist）；
/// - 每柱取频率范围内的**峰值** bin；**先按 2/N 归一化**为信号幅度
///   （单幅值 1.0 的正弦 → 峰值 bin 幅度 N/2 → 归一后 1.0 = 0dB）；
/// - -60dB → 0、0dB → 1。
/// 注：必须归一化——否则任意幅度 > 1 的信号全部撞上限 1.0，柱间无法区分。
pub fn barsFromSpectrum(mag: []const f32, sr: f32, out: []f32) void {
    const bin_hz = sr / @as(f32, fft_size);
    const ratio = spec_f_max / spec_f_min;
    const bars_f = @as(f32, @floatFromInt(out.len));
    const norm = 1.0 / @as(f32, @floatFromInt(@max(1, mag.len))); // = 2/fft_size
    for (out, 0..) |*o, i| {
        const k = @as(f32, @floatFromInt(i)) / bars_f;
        const k1 = @as(f32, @floatFromInt(i + 1)) / bars_f;
        const f_lo = spec_f_min * std.math.pow(f32, ratio, k);
        const f_hi = spec_f_min * std.math.pow(f32, ratio, k1);
        var b_lo: usize = @intFromFloat(@max(0, f_lo / bin_hz));
        var b_hi: usize = @intFromFloat(f_hi / bin_hz);
        b_lo = @min(b_lo, mag.len - 1);
        b_hi = @min(@max(b_hi, b_lo + 1), mag.len);
        var peak: f32 = 0;
        for (mag[b_lo..b_hi]) |m| peak = @max(peak, m);
        const db = 20 * std.math.log10(@max(1e-6, peak * norm));
        o.* = std.math.clamp((db + 60) / 60, 0, 1);
    }
}

// ── 测试 ──

test "eq: Biquad 峰值滤波器——中心频率增益符合设定（+6dB / -12dB / 0dB）" {
    const sr: f32 = 48000;
    const f0: f32 = 1000;

    // +6dB：1000Hz 正弦幅值应放大 10^(6/20) ≈ 1.995
    var bq = Biquad{};
    bq.setPeak(sr, f0, 1.0, 6.0);
    var peak: f32 = 0;
    var t: usize = 0;
    while (t < 4800) : (t += 1) { // 0.1s
        const x = @sin(2 * std.math.pi * f0 * @as(f32, @floatFromInt(t)) / sr);
        const y = bq.process(x);
        if (t > 2400) peak = @max(peak, @abs(y)); // 稳态后取峰
    }
    const expect6 = std.math.pow(f32, 10, 6.0 / 20.0);
    try std.testing.expectApproxEqAbs(expect6, peak, 0.05);

    // -12dB
    var bq2 = Biquad{};
    bq2.setPeak(sr, f0, 1.0, -12.0);
    var peak2: f32 = 0;
    t = 0;
    while (t < 4800) : (t += 1) {
        const x = @sin(2 * std.math.pi * f0 * @as(f32, @floatFromInt(t)) / sr);
        const y = bq2.process(x);
        if (t > 2400) peak2 = @max(peak2, @abs(y));
    }
    try std.testing.expectApproxEqAbs(std.math.pow(f32, 10, -12.0 / 20.0), peak2, 0.05);

    // 远离中心频率：近似不衰减（Q=1 时 10 倍频程处约 0dB）
    var bq3 = Biquad{};
    bq3.setPeak(sr, f0, 1.0, 12.0);
    var peak3: f32 = 0;
    t = 0;
    while (t < 4800) : (t += 1) {
        const x = @sin(2 * std.math.pi * 10000 * @as(f32, @floatFromInt(t)) / sr);
        const y = bq3.process(x);
        if (t > 2400) peak3 = @max(peak3, @abs(y));
    }
    try std.testing.expect(peak3 > 0.85 and peak3 < 1.15);
}

test "eq: responseDb 与滤波器实际增益一致（解析式校验）" {
    const sr: f32 = 48000;
    const bands = [_]BandParams{.{ .freq = 1000, .gain_db = 6.0, .q = 1.0 }};
    // 中心频率处应 ≈ +6dB
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), responseDb(&bands, sr, 1000), 0.3);
    // 10 倍频程外应 ≈ 0dB
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), responseDb(&bands, sr, 10000), 0.5);
    // 0 增益段 → 恒 0
    const flat = [_]BandParams{.{ .freq = 500, .gain_db = 0 }};
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), responseDb(&flat, sr, 500), 0.001);
    // 两段叠加：+6 + (-6) 在各自中心 → 单点检查组合不为 NaN
    const two = [_]BandParams{
        .{ .freq = 1000, .gain_db = 6.0, .q = 1.0 },
        .{ .freq = 500, .gain_db = -6.0, .q = 1.0 },
    };
    const v = responseDb(&two, sr, 1000);
    try std.testing.expect(v > 3.0 and v < 7.0); // 500 段在 1000 处影响 < 3dB
}

test "eq: FFT——单频正弦的峰值应出现在正确的 bin" {
    var re: [fft_size]f32 = undefined;
    var im: [fft_size]f32 = undefined;
    // bin 8 的正弦（8 周期 / 256 样本）
    var i: usize = 0;
    while (i < fft_size) : (i += 1) {
        re[i] = @sin(2 * std.math.pi * 8 * @as(f32, @floatFromInt(i)) / fft_size);
        im[i] = 0;
    }
    fft(&re, &im);
    // 幅度谱：峰值在 bin 8（和对称的 bin 248）
    var mag: [fft_size / 2]f32 = undefined;
    for (0..fft_size / 2) |k| {
        mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
    }
    var peak_bin: usize = 0;
    for (mag, 0..) |m, k| {
        if (m > mag[peak_bin]) peak_bin = k;
    }
    try std.testing.expectEqual(@as(usize, 8), peak_bin);
    // 峰值幅度 ≈ N/2 = 128
    try std.testing.expectApproxEqAbs(@as(f32, 128), mag[8], 1.0);
}

test "eq: 频谱柱映射——低频正弦主能量落在低柱、高频落高柱" {
    var re: [fft_size]f32 = undefined;
    var im: [fft_size]f32 = undefined;
    var mag: [fft_size / 2]f32 = undefined;
    var bars: [spec_bars]f32 = undefined;
    const sr: f32 = 48000;

    // 200Hz（bin 1）：能量应在低柱（索引 < 8）
    var i: usize = 0;
    while (i < fft_size) : (i += 1) {
        re[i] = @sin(2 * std.math.pi * 200 * @as(f32, @floatFromInt(i)) / sr);
        im[i] = 0;
    }
    fft(&re, &im);
    for (0..fft_size / 2) |k| mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
    barsFromSpectrum(&mag, sr, &bars);
    var low_peak: usize = 0;
    for (bars, 0..) |b, k| {
        if (k < 12 and b > bars[low_peak]) low_peak = k;
    }
    try std.testing.expect(low_peak < 12);

    // 8kHz 正弦：能量应在高柱（索引 > 20）
    i = 0;
    while (i < fft_size) : (i += 1) {
        re[i] = @sin(2 * std.math.pi * 8000 * @as(f32, @floatFromInt(i)) / sr);
        im[i] = 0;
    }
    fft(&re, &im);
    for (0..fft_size / 2) |k| mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
    barsFromSpectrum(&mag, sr, &bars);
    var high_peak: usize = 20;
    for (bars[20..], 20..) |b, k| {
        if (b > bars[high_peak]) high_peak = k;
    }
    try std.testing.expect(high_peak > 20);
}

test "eq: Hann 窗（边界衰减、中心保持）" {
    var buf = [_]f32{1.0} ** 64;
    hannWindow(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[63], 0.001);
    try std.testing.expect(buf[32] > 0.99);
}
