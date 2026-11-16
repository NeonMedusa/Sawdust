//! 调度 / 释音协议的**随机压力测试**（headless：不起音频设备、不需要窗口、不需要真插件）。
//!
//! **A4 之后：驱动的是 pull 模型**——`snapshot`（按步分桶的权威数据）→ 音频每 block 从快照取事件。
//! 原来的 push 模型（`sequencer.scheduleRange` + 重扫）已退役，对应压力测试一并改写。
//!
//! 做法：每块随机做编辑（拖片段/改长度/静音），**每次编辑后重建并发布快照**（模拟
//! `App.pollSnapshotRebuild`：`snapshot_ptr` store + `snap_gen` 递增），然后渲染一块。
//!
//! 断言（**没有兜底**：听感保障由协议本身提供）：
//! 任何声部都不得在 `end_step + 1 小节` 之后仍处于发声状态
//! （`params.dbg_overrun_peak` = 历史峰值，必须为 0）。

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");
const audio = @import("audio.zig");
const snapshot = @import("snapshot.zig");

/// 重建并发布快照（模拟 UI 的 `pollSnapshotRebuild`）。
fn publishSnapshot(
    alloc: std.mem.Allocator,
    params: *audio.Params,
    clips: []const model.Clip,
    notes: []const model.Note,
    slot: *?snapshot.Snapshot,
) void {
    if (slot.*) |*old| old.deinit();
    slot.* = snapshot.build(alloc, clips, notes, true, 0, null) catch null;
    if (slot.*) |*s| {
        params.snapshot_ptr.store(@intFromPtr(s), .release);
        _ = params.snap_gen.fetchAdd(1, .monotonic);
    }
}

fn soundingVoices(engine: *audio.Engine, inst: usize, out: []synth.Voice) usize {
    var n: usize = 0;
    if (inst >= engine.synths.len) return 0;
    for (engine.synths[inst].voices) |v| {
        if (v.env_stage == .idle or v.env_stage == .release) continue;
        if (n < out.len) {
            out[n] = v;
            n += 1;
        }
    }
    return n;
}

/// `kind`：0 = 内置合成器；2 = VSTi（宿主位图路径，不加载真插件）
fn runStress(alloc: std.mem.Allocator, comptime kind: u32, seed: u64) !void {
    var params = audio.Params{};
    try params.initCapacity(alloc, 2, 2, 0);
    defer params.deinit(alloc);

    var imm_q = synth.EventQueue{};
    params.events = &imm_q;

    var engine = audio.Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(2, 2, 0);
    defer engine.deinit();

    var sp = synth.SynthParams{};
    if (kind == 2) {
        params.instrument_kind[0].store(2, .monotonic);
    } else {
        params.synth_ptrs[0].store(&sp, .monotonic);
        params.instrument_kind[0].store(0, .monotonic);
    }

    params.sample_rate = 48000;
    params.bpm.store(400, .monotonic); // 快一点：同样的 block 数走更多步
    params.steps_per_beat.store(4, .monotonic);
    params.time_num.store(4, .monotonic);
    params.time_den.store(4, .monotonic);
    params.playing.store(true, .monotonic);
    params.start_frame.store(0, .monotonic);
    params.start_step.store(0, .monotonic);
    params.frames_played.store(0, .monotonic);

    // 两个片段（同一样式放两条轨，制造重叠同音高实例）
    var clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 4096, .pattern = 0 },
        .{ .track = 1, .start = 16, .len = 4096, .pattern = 0 },
    };
    var notes = [_]model.Note{
        .{ .step = 0, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 },
        .{ .step = 8, .len = 32, .pitch = 64, .pattern = 0, .instrument = 0 }, // 长音（跨多个编辑点）
        .{ .step = 24, .len = 4, .pitch = 67, .pattern = 0, .instrument = 0 },
        .{ .step = 40, .len = 16, .pitch = 60, .pattern = 0, .instrument = 0 },
    };

    var snap: ?snapshot.Snapshot = null;
    defer if (snap) |*s| s.deinit();
    publishSnapshot(alloc, &params, &clips, &notes, &snap);

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var out: [512 * 2]f32 = undefined;
    const blocks: usize = 3000; // 足够跑过所有音符若干遍
    var block: usize = 0;
    while (block < blocks) : (block += 1) {
        // ① 随机编辑（模拟拖动/裁剪/静音）→ 重建 + 发布快照（= 编辑提交）
        if (block % 3 == 0) {
            const i = rnd.uintLessThan(usize, clips.len);
            switch (rnd.uintLessThan(u8, 4)) {
                0 => clips[i].start = @max(0, clips[i].start + 8),
                1 => clips[i].start = @max(0, clips[i].start - 8),
                2 => clips[i].muted = !clips[i].muted,
                else => clips[i].len = @max(8, clips[i].len -| 8),
            }
            publishSnapshot(alloc, &params, &clips, &notes, &snap);
            // 历史上“一次拖动 = 同一帧两次重扫”：换成**同帧两次重建**（换代两次）
            if (rnd.boolean()) {
                clips[i].len = @max(8, clips[i].len -| 4);
                publishSnapshot(alloc, &params, &clips, &notes, &snap);
            }
        }

        // ② 渲染一块（内部：换代清 stash + 对账 + 从快照取事件 + 本地到点释音）
        @memset(&out, 0);
        audio.renderBlock(&engine, &params, &out, 512, 48000);
    }

    // ④ 不变量：任何声部都不得越过 `end_step + 1 小节`（挂音）
    try std.testing.expectEqual(@as(u32, 0), params.dbg_overrun_peak.load(.monotonic));
}

test "sched_stress: 随机编辑 × 快照换代（内置合成器）——不得挂音" {
    try runStress(std.testing.allocator, 0, 0xC0FFEE_01);
}

test "sched_stress: 随机编辑 × 快照换代（VSTi 位图路径）——不得挂音" {
    try runStress(std.testing.allocator, 2, 0xC0FFEE_02);
}

// **性能压测（opt-in：`SAWDUST_BENCH=1`）**：
// 64 轨 × 32 音/轨 × 16 乐器（VSTi 路径，不载真插件——**只量宿主侧开销**：
// 快照取事件 + stash + 事件构造/转发 + 每块诊断扫描；真插件的 DSP 不在本测里）。
// 输出：每块微秒 + 占实时预算（512 帧 @48k = 10.67ms）的百分比。
test "sched_stress: [bench] 64 轨密集事件——每块宿主侧开销" {
    if (std.c.getenv("SAWDUST_BENCH") == null) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // 乐器数可用 `SAWDUST_BENCH_CAP` 覆盖（折出“每乐器固定开销”）
    var inst_cap: usize = 16;
    if (std.c.getenv("SAWDUST_BENCH_CAP")) |s| {
        var buf: [16]u8 = undefined;
        const len = @min(std.mem.len(s), buf.len);
        @memcpy(buf[0..len], s[0..len]);
        inst_cap = std.fmt.parseInt(usize, buf[0..len], 10) catch 16;
        inst_cap = std.math.clamp(inst_cap, 1, 32);
    }
    var params = audio.Params{};
    try params.initCapacity(alloc, inst_cap, 2, 0);
    defer params.deinit(alloc);

    var imm_q = synth.EventQueue{};
    params.events = &imm_q;

    var engine = audio.Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(inst_cap, 2, 0);
    defer engine.deinit();

    params.sample_rate = 48000;
    params.bpm.store(120, .monotonic);
    params.steps_per_beat.store(960, .monotonic); // 4/4 @ U=3840
    params.time_num.store(4, .monotonic);
    params.time_den.store(4, .monotonic);
    params.channel_count.store(2, .monotonic);
    params.playing.store(true, .monotonic);
    params.start_frame.store(0, .monotonic);
    params.start_step.store(0, .monotonic);
    params.frames_played.store(0, .monotonic);
    for (0..inst_cap) |i| {
        params.instrument_kind[i].store(2, .monotonic); // VSTi 路径（无实例）
        params.instrument_channel[i].store(@intCast(i % 2), .monotonic);
        params.instrument_gain[i].store(0.8, .monotonic);
        params.instrument_pan[i].store(0.5, .monotonic);
    }

    // 64 轨（= 64 个片段）→ 每轨 32 个 16 分音符，乐器轮流分给 16 个 VSTi
    const n_tracks: usize = 64;
    const per_track: usize = 32;
    const bar: i32 = 3840;
    var clips_buf: [n_tracks]model.Clip = undefined;
    for (&clips_buf, 0..) |*c, ti| {
        c.* = .{ .track = @intCast(ti), .start = 0, .len = bar, .pattern = 0 };
    }
    var notes_buf: [n_tracks * per_track]model.Note = undefined;
    for (0..n_tracks) |ti| {
        for (0..per_track) |k| {
            notes_buf[ti * per_track + k] = .{
                .step = @intCast(@as(usize, k) * 120), // 120 步 = 16 分（U=3840/32）
                .len = 100,
                .pitch = @intCast(36 + (ti + k) % 48),
                .pattern = 0,
                .instrument = @intCast(ti % inst_cap),
                .velocity = 100,
            };
        }
    }

    var snap: ?snapshot.Snapshot = null;
    defer if (snap) |*s| s.deinit();
    publishSnapshot(alloc, &params, &clips_buf, &notes_buf, &snap);

    var out: [512 * 2]f32 = undefined;
    const blocks: usize = 1200; // ≈ 12.8 秒音频
    // 预热（首块有换代对账/缓存冷）
    @memset(&out, 0);
    audio.renderBlock(&engine, &params, &out, 512, 48000);

    const t0 = @import("port_io.zig").nowMs();
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        @memset(&out, 0);
        audio.renderBlock(&engine, &params, &out, 512, 48000);
    }
    const dt_ms = @import("port_io.zig").nowMs() - t0;
    const per_block_us = @as(f64, @floatFromInt(dt_ms)) * 1000.0 / @as(f64, @floatFromInt(blocks));
    // 分解：只跑 renderSegment（不含取事件/扫描）
    const t1 = @import("port_io.zig").nowMs();
    var b2: usize = 0;
    while (b2 < blocks) : (b2 += 1) {
        @memset(&out, 0);
        engine.seg_abs0 = params.frames_played.load(.monotonic);
        audio.renderSegment(&engine, &params, &out, 512, 48000, params.volume.load(.monotonic));
    }
    const seg_ms = @import("port_io.zig").nowMs() - t1;
    const seg_us = @as(f64, @floatFromInt(seg_ms)) * 1000.0 / @as(f64, @floatFromInt(blocks));
    std.debug.print("[bench] 分解：renderSegment {d:.1}us / 其他（取事件+扫描） {d:.1}us\n", .{ seg_us, per_block_us - seg_us });
    // 微测：只跑 gatherRaw（快照取事件）
    {
        const tg = @import("port_io.zig").nowMs();
        var gb: usize = 0;
        var gsum: usize = 0;
        var evb2: [256]synth.SchedEvent = undefined;
        while (gb < blocks) : (gb += 1) {
            const s0: i32 = @intCast(gb * 20);
            if (snap.?.gatherRaw(&evb2, s0, s0 + 21, 1)) |n| gsum +%= n;
        }
        const g_ms = @import("port_io.zig").nowMs() - tg;
        std.debug.print("[bench] 分解2：gatherRaw {d:.1}us/次（事件数合计 {d}）\n", .{
            @as(f64, @floatFromInt(g_ms)) * 1000.0 / @as(f64, @floatFromInt(blocks)), gsum,
        });
    }
    const budget_us: f64 = 512.0 / 48000.0 * 1_000_000.0; // 10.67ms
    std.debug.print(
        "\n[bench] 64轨×32音 / 16 VSTi：blocks={d} total={d}ms  per_block={d:.1}us  = {d:.1}% of 10.67ms\n",
        .{ blocks, dt_ms, per_block_us, per_block_us / budget_us * 100.0 },
    );
    // 健壮性：不得挂音（压测同时也是正确性测试）
    try std.testing.expectEqual(@as(u32, 0), params.dbg_overrun_peak.load(.monotonic));
}

test "sched_stress: 换代对账不误杀——切一个实例不得连带另一个同音高实例" {
    const alloc = std.testing.allocator;
    var params = audio.Params{};
    try params.initCapacity(alloc, 2, 2, 0);
    defer params.deinit(alloc);

    var imm_q = synth.EventQueue{};
    params.events = &imm_q;

    var engine = audio.Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(2, 2, 0);
    defer engine.deinit();

    var sp = synth.SynthParams{};
    params.synth_ptrs[0].store(&sp, .monotonic);
    params.instrument_kind[0].store(0, .monotonic);
    params.sample_rate = 48000;
    params.bpm.store(400, .monotonic);
    params.steps_per_beat.store(4, .monotonic);
    params.playing.store(true, .monotonic);
    params.frames_played.store(0, .monotonic);

    // 同一轨道两个重叠片段 → 同音高 p60 的**两个实例**（start 0 与 8）
    var clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 64, .pattern = 0 },
        .{ .track = 0, .start = 8, .len = 64, .pattern = 0 }, // 第二个实例：起点 8
    };
    var notes = [_]model.Note{
        .{ .step = 0, .len = 32, .pitch = 60, .pattern = 0, .instrument = 0 },
    };
    var snap: ?snapshot.Snapshot = null;
    defer if (snap) |*s| s.deinit();
    publishSnapshot(alloc, &params, &clips, &notes, &snap);

    var out: [512 * 2]f32 = undefined;
    var cur: i32 = 0;
    while (cur < 20) {
        cur = params.last_step.load(.monotonic);
        @memset(&out, 0);
        audio.renderBlock(&engine, &params, &out, 512, 48000);
    }

    var vs: [8]synth.Voice = undefined;
    const n0 = soundingVoices(&engine, 0, vs[0..]);
    try std.testing.expectEqual(@as(usize, 2), n0); // 两个实例都在响

    // 只“静音”第二个片段（= 删掉 start=8 那个实例）→ 重建 + 对账
    clips[1].muted = true;
    publishSnapshot(alloc, &params, &clips, &notes, &snap);
    @memset(&out, 0);
    audio.renderBlock(&engine, &params, &out, 512, 48000);

    const n1 = soundingVoices(&engine, 0, vs[0..]);
    try std.testing.expectEqual(@as(usize, 1), n1); // 只该剩一个（另一个被精确释放）
    try std.testing.expectEqual(@as(i32, 0), vs[0].start_step); // 幸存者必须是 start=0 那个
}
