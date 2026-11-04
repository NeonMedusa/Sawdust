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
