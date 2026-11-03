//! 调度 / 释音协议的**随机压力测试**（headless：不起音频设备、不需要窗口、不需要真插件）。
//!
//! 目的：把"播放中随机拖动 / 静音 → 偶发挂音"这类时序问题，变成**可重复的断言**。
//!
//! 做法：直接驱动真实的协议路径
//!   `sequencer.scheduleRange`（UI 前瞻）→ `params.sched_events`（无锁环）
//!   → `audio.renderBlock`（音频线程主体：drain / 作废 / 分发 / 不变量自检）
//! 每个 block 随机做编辑（拖动起点、缩长度、静音切换），并模拟真实 UI 的两个"恶意"行为：
//!   · 安全界抖动（`from = cur+1/+2/+6`，对应 UI 与音频相对进度漂移）
//!   · 同一帧**第二次**重扫（历史上一次拖动 = 两次全窗重扫，最容易漏 off 的时序）
//!
//! 断言（**没有任何兜底**：三层自愈已删除，听感保障由协议本身提供）：
//!   任何声部都不得在 `end_step + 1 小节` 之后仍处于发声状态
//!   （`params.dbg_overrun_peak` = 历史峰值，必须为 0）。
//!
//! 两条路径各一个用例：
//!   · `kind = 0` 内置合成器 —— 走 `synth` 声部池
//!   · `kind = 2` VSTi 宿主侧 —— 走 `vsti_active_lo/hi` 位图 + `Engine.vsti_end`
//!     （不加载真插件：`vstiNoteOn/Off` 只维护位图与事件批，批由测试每块"消费"掉）

const std = @import("std");
const model = @import("model.zig");
const synth = @import("synth.zig");
const sequencer = @import("sequencer.zig");
const audio = @import("audio.zig");

/// `kind`：0 = 内置合成器；2 = VSTi（宿主位图路径）
fn runStress(alloc: std.mem.Allocator, comptime kind: u32, seed: u64) !void {
    var params = audio.Params{};
    try params.initCapacity(alloc, 2, 2, 0);
    defer params.deinit(alloc);

    // 队列是**指针字段**（真实运行时由 App 持有）
    var imm_q = synth.EventQueue{};
    var sched_q = synth.SchedQueue{};
    params.events = &imm_q;
    params.sched_events = &sched_q;

    var engine = audio.Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(2, 2, 0);
    defer engine.deinit();

    // 音源：槽 0 = 内置合成器 或 VSTi（后者**不挂真插件**，只走宿主侧位图/事件批）
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

    var sched = sequencer.Scheduler{};
    var mutes = sequencer.TrackMutes{};
    defer mutes.deinit(alloc);
    sched.muted = &mutes;
    sched.edit_gen = params.sched_edit_gen.load(.monotonic); // 与已在用的代对齐

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var out: [512 * 2]f32 = undefined;
    var block: usize = 0;
    const blocks: usize = 6000; // ≈ 30 s 音频
    while (block < blocks) : (block += 1) {
        // ① UI 侧：推进前瞻窗口（等价于主循环每帧的 scheduleRange）
        const cur = params.last_step.load(.monotonic);
        const horizon = cur + 64;
        if (horizon > sched.scheduled_upto) {
            sequencer.scheduleRange(&sched, params.sched_events, &clips, &notes, true, 0, sched.scheduled_upto, horizon);
        }

        // ② 随机编辑（模拟拖动/静音）
        if (block % 3 == 0) {
            const i = rnd.uintLessThan(usize, clips.len);
            switch (rnd.uintLessThan(u8, 4)) {
                0 => clips[i].start = @max(0, clips[i].start + 8),
                1 => clips[i].start = @max(0, clips[i].start - 8),
                2 => clips[i].muted = !clips[i].muted,
                else => clips[i].len = @max(8, clips[i].len -| 8),
            }
            // 安全界有抖动（真实实现用 frames_played 估算 + 余量，UI/音频相对进度会漂）
            const from_off: i32 = switch (rnd.uintLessThan(u8, 3)) {
                0 => 1,
                1 => 2,
                else => 6,
            };
            const from = cur + from_off;
            sequencer.muteTrackLive(&sched, params.sched_events, &clips, &notes, true, 0, from);
            params.sched_rescan_from.store(sched.rescan_from, .monotonic);
            params.sched_edit_gen.store(sched.edit_gen, .monotonic);
            // 模拟「同一帧第二次重扫」（历史上一次拖动 = 两次全窗重扫）
            if (rnd.boolean()) {
                const from2 = from + rnd.intRangeLessThan(i32, 0, 4);
                sequencer.muteTrackLive(&sched, params.sched_events, &clips, &notes, true, 0, from2);
                params.sched_rescan_from.store(sched.rescan_from, .monotonic);
                params.sched_edit_gen.store(sched.edit_gen, .monotonic);
            }
        }

        // ③ 渲染一块（内部：drain → 作废 → 分发 → 不变量自检）
        @memset(&out, 0);
        audio.renderBlock(&engine, &params, &out, 512, 48000);

        // ④ VSTi 路径：模拟"插件已消费事件批"（真实实现里由 pl.processInstrument 清零）。
        //    不清零的话批会填满（256 条）→ 丢 off，那是另一个人为因素，会污染本测试。
        if (kind == 2) {
            for (engine.vsti_event_n) |*n| n.* = 0;
        }
    }

    // 断言：没有任何声部超时
    try std.testing.expectEqual(@as(u32, 0), params.dbg_overrun_peak.load(.monotonic));
}

/// 统计某乐器正在发声（非释音尾）的声部，返回 [{pitch, start_step}]
/// 一个正在发声的声部快照（诊断/断言用）
const SoundingVoice = struct { pitch: i32, start_step: i32 };

fn soundingVoices(engine: *audio.Engine, inst: usize, out: []SoundingVoice) usize {
    var n: usize = 0;
    for (engine.synths[inst].voices) |v| {
        if (v.env_stage == .idle or v.env_stage == .release) continue;
        if (n >= out.len) break;
        out[n] = .{ .pitch = v.pitch, .start_step = v.start_step };
        n += 1;
    }
    return n;
}

test "sched: 释音不误杀——切一个实例不得连带另一个同音高实例" {
    // 场景：**同一样式**放在两条轨，但两个片段位置不同（起点 0 与 8），
    // 因此两个实例的 (音高, 乐器) 相同、起点步不同。
    // 切掉起点 8 那个实例时：
    //   · 按起点精确匹配（现状） → 只释放 8 那个，起点 0 的继续响 ✅
    //   · 按音高 FIFO（旧行为）   → 会释放**最早**的 0 那个 → 误杀 ❌
    const alloc = std.testing.allocator;
    var params = audio.Params{};
    try params.initCapacity(alloc, 2, 2, 0);
    defer params.deinit(alloc);
    var imm_q = synth.EventQueue{};
    var sched_q = synth.SchedQueue{};
    params.events = &imm_q;
    params.sched_events = &sched_q;

    var engine = audio.Engine{ .params = &params };
    engine.allocator = alloc;
    try engine.setCapacity(2, 2, 0);
    defer engine.deinit();

    var sp = synth.SynthParams{};
    sp.release.store(0.0, .monotonic); // 释音极短：便于断言"是否已释放"
    params.synth_ptrs[0].store(&sp, .monotonic);
    params.instrument_kind[0].store(0, .monotonic);
    params.sample_rate = 48000;
    params.bpm.store(400, .monotonic);
    params.steps_per_beat.store(4, .monotonic);
    params.time_num.store(4, .monotonic);
    params.time_den.store(4, .monotonic);
    params.playing.store(true, .monotonic);
    params.start_frame.store(0, .monotonic);
    params.start_step.store(0, .monotonic);
    params.frames_played.store(0, .monotonic);

    var clips = [_]model.Clip{
        .{ .track = 0, .start = 0, .len = 128, .pattern = 0 },
        .{ .track = 1, .start = 8, .len = 128, .pattern = 0 },
    };
    var notes = [_]model.Note{
        .{ .step = 0, .len = 64, .pitch = 60, .pattern = 0, .instrument = 0 }, // 长音
    };

    var sched = sequencer.Scheduler{};
    var mutes = sequencer.TrackMutes{};
    defer mutes.deinit(alloc);
    sched.muted = &mutes;
    sched.edit_gen = params.sched_edit_gen.load(.monotonic);

    var out: [512 * 2]f32 = undefined;
    var cur: i32 = 0;
    // ① 播到游标 ≥ 20（两个实例都已起音）
    while (cur < 20) {
        cur = params.last_step.load(.monotonic);
        const horizon = cur + 128;
        if (horizon > sched.scheduled_upto) {
            sequencer.scheduleRange(&sched, params.sched_events, &clips, &notes, true, 0, sched.scheduled_upto, horizon);
        }
        @memset(&out, 0);
        audio.renderBlock(&engine, &params, &out, 512, 48000);
    }

    var vs: [8]SoundingVoice = undefined;
    const n0 = soundingVoices(&engine, 0, vs[0..]);
    try std.testing.expectEqual(@as(usize, 2), n0); // 两个实例都在响
    var has0 = false;
    var has8 = false;
    for (vs[0..n0]) |v| {
        if (v.pitch != 60) continue;
        if (v.start_step == 0) has0 = true;
        if (v.start_step == 8) has8 = true;
    }
    try std.testing.expect(has0 and has8);

    // ② 切掉"起点 8"那个实例（= App 里 releaseNotesNowForClips 推的那条）
    params.events.push(.{ .kind = .off, .pitch = 60, .instrument = 0, .on_step = 8 });
    @memset(&out, 0);
    audio.renderBlock(&engine, &params, &out, 512, 48000);

    // ③ 只剩起点 0 那个实例还在响（未被误杀）
    const n1 = soundingVoices(&engine, 0, vs[0..]);
    try std.testing.expectEqual(@as(usize, 1), n1);
    try std.testing.expectEqual(@as(i32, 60), vs[0].pitch);
    try std.testing.expectEqual(@as(i32, 0), vs[0].start_step); // ← 误杀的话这里会是 8
}
test "sched stress (synth): 播放中随机拖动/静音 —— 不出现超时声部" {
    try runStress(std.testing.allocator, 0, 0xC0FFEE);
}

test "sched stress (VSTi): 播放中随机拖动/静音 —— 不出现超时声部" {
    try runStress(std.testing.allocator, 2, 0xBEEF1234);
}
