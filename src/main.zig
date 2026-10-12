//! Sawdust — Simple Audio Workstation in Zig.
//!
//! 主入口：窗口 + 主循环 + 工具栏 + 布局组装（三栏 + 浮动窗口）。
//! - 数据模型与纯逻辑：`model.zig`（可单测）
//! - 应用状态：`app.zig`
//! - 视图：`view_playlist.zig` / `view_pianoroll.zig` / `view_rack.zig` / `view_panels.zig`
//! - 控件库：`ui.zig`；渲染：`render.zig`；窗口：`window.zig`；音频：`audio.zig`

const std = @import("std");
const window = @import("window.zig");
const r_mod = @import("render.zig");
const Font = @import("font.zig").Font;
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const PresetTarget = @import("app.zig").PresetTarget;
const PresetIntent = @import("app.zig").PresetIntent;
const PresetChoice = @import("app.zig").PresetChoice;
const PresetSaveSource = @import("app.zig").PresetSaveSource;
const QuitChoice = @import("app.zig").QuitChoice;
const synth = @import("synth.zig");
const sequencer = @import("sequencer.zig");
const model = @import("model.zig");
const persist = @import("persist.zig");
const midi = @import("midi.zig");
const filedialog = @import("filedialog.zig");
const util = @import("view_util.zig");
const view_playlist = @import("view_playlist.zig");
const view_pianoroll = @import("view_pianoroll.zig");
const view_rack = @import("view_rack.zig");
const view_synth = @import("view_synth.zig");
const view_mixer = @import("view_mixer.zig");
const view_effect = @import("view_effect.zig");
const view_panels = @import("view_panels.zig");
const view_presets = @import("view_presets.zig");
const view_drumkit = @import("view_drumkit.zig");
const eq = @import("eq.zig");
const audio = @import("audio.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var win: window.Window = undefined;
    try win.init(allocator, "Sawdust — Simple Audio Workstation", 1280, 760);
    defer win.deinit();

    var font = loadFont(allocator, io) catch |e| {
        std.debug.print("字体加载失败（{s}）：请把任意 .ttf 放到 fonts/ 目录\n", .{@errorName(e)});
        return 1;
    };
    defer font.deinit();

    var app = App{ .allocator = allocator };
    defer app.clips.deinit(allocator);
    defer app.notes.deinit(allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count); // 默认样式 1..6
    app.resetMixerChannels(@import("app.zig").default_mixer_channels); // 默认调音台通道（主通道 + 通道#1）
    // 数据目录（预设库）+ 首次扫描（IO 统一在帧末 pending 处理）
    {
        var edir_buf: [1024]u8 = undefined;
        const edir = exeDir(allocator, &edir_buf);
        var root_buf: [512]u8 = undefined;
        if (preset_mod.resolveDataRoot(io, edir, &root_buf)) |root| app.setDataRoot(root);
        app.pending_preset = .scan;
    }
    // 初始片段（演示）：前 12 轨铺一些样式，每 16 小节重复（只铺 2 轮——
    // 避免演示内容把时间轴行程撑得过长，行程应贴合最右内容）
    {
        const B: i32 = model.units_per_whole; // 4/4 一小节 = 96 步
        var t: i32 = 0;
        while (t < 12) : (t += 1) {
            var rep: i32 = 0;
            while (rep < 2) : (rep += 1) {
                app.addClip(.{
                    .track = t,
                    .start = @mod(t, 6) * 2 * B + rep * 16 * B,
                    .len = (2 + @mod(t, 3)) * B,
                    .pattern = @mod(t, 6),
                });
            }
        }
    }
    // 初始乐器（演示）：两个减法合成器（各自独立参数）
    // **必须在 engine.init 之前**：音频回调启动后会解引用参数/队列指针
    _ = app.addInstrument("减法合成器");
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态"); // 演示数据 = 历史基线
    app.dirty = false; // 演示数据不算“未保存的修改”
    app.params.events = &app.events;
    app.params.sched_events = &app.sched_events;

    app.engine.init(&app.params, allocator) catch |e| {
        std.debug.print("音频初始化失败（{s}）：UI 仍可运行\n", .{@errorName(e)});
    };
    defer app.engine.deinit();
    app.engine.params = &app.params;

    var ui_input = InputState{};
    var ui = Ui.init(r_mod.Renderer.init(&win.fb), &font);

    // 帧率上限：120fps（帧预算 8.33ms）。
    // 历史：原为固定 `sleep(16ms)`（名义 60fps），但 Windows 默认计时器
    // 粒度 ≈ 15.6ms → 实测 sleep(16ms) 睡成 ~26ms，加上渲染耗时实际仅
    // ~30 多帧，表现为“UI 不流畅/操作滞后”。修法：
    //   ① window.init 里 timeBeginPeriod(1) 提高计时器精度；
    //   ② 改为**帧预算**：睡到“帧开始 + 预算”截止，而非固定睡眠
    //      （固定睡眠会与渲染耗时叠加，帧率随内容复杂度浮动）。
    const frame_budget_ns: i64 = 8_333_333; // 120fps

    while (true) {
        const frame_start_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        defer {
            // 5) 帧预算：睡完本帧剩余时间（渲染耗时已扣掉）
            const now_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
            const remain_ns = frame_budget_ns - (now_ns - frame_start_ns);
            if (remain_ns > 0) {
                std.Io.sleep(io, .fromNanoseconds(remain_ns), .awake) catch {};
            }
        }
        // ── 脏确认流程（自绘模态；**不用系统 MessageBox**——
        // 系统弹窗会把鼠标吸到默认按钮上，实测体验差）──
        // 两种场景共用：① 退出程序；② 打开其他工程（都会丢失未保存修改）
        if (win.shouldQuit()) {
            win.should_quit = false; // 拦截：先走确认流程
            if (!app.dirty) break; // 无未保存修改 → 直接退出
            app.dirty_flow = .confirming;
            app.dirty_intent = .quit;
            app.modal = .dirty_confirm;
            app.modal_choice = null;
        }
        switch (app.dirty_flow) {
            .none => {},
            .confirming => {
                // 等用户选择（鼠标在模态框中 / Enter / Esc）
                if (app.modal_choice) |choice| {
                    app.modal = null;
                    app.modal_choice = null;
                    switch (choice) {
                        .save => {
                            // 先保存，保存完成后再执行目标动作（见 save_then 分支）
                            app.pending_file_action = .save;
                            app.dirty_flow = .save_then;
                        },
                        .discard => {
                            // 不保存：直接执行目标动作（退出 / 打开）
                            app.dirty_flow = .none;
                            if (app.dirty_intent == .quit) break;
                        },
                        .cancel => {
                            // 取消：放弃目标动作（清掉待打开的工程）
                            app.dirty_flow = .none;
                            app.clearPendingOpen();
                        },
                    }
                }
            },
            .save_then => {
                // 保存已完成（pending 为空）：成功 → 继续目标动作；失败/取消 → 放弃
                if (app.pending_file_action == null) {
                    app.dirty_flow = .none;
                    if (!app.dirty) {
                        // 保存成功 → 执行目标动作
                        if (app.dirty_intent == .quit) break;
                        app.pending_file_action = .open; // 执行待定的打开
                    } else {
                        // 保存失败 / 用户在保存对话框里取消 → 放弃目标动作
                        app.clearPendingOpen();
                    }
                }
            },
        }
        // 预设覆写/删除确认（独立于脏确认流程；Enter = 确认、Esc = 取消）
        if (app.modal == .preset_overwrite or app.modal == .preset_delete) {
            if (app.modal_choice) |choice| {
                const was_overwrite = app.modal == .preset_overwrite;
                app.modal = null;
                app.modal_choice = null;
                if (choice == .save) { // 确认 → 重排对应动作
                    if (was_overwrite) {
                        if (app.overwrite_req) |req| {
                            app.pending_preset = .{ .save = .{
                                .source = req.source,
                                .name_buf = req.name,
                                .name_len = req.name_len,
                                .overwrite = true,
                            } };
                        }
                    } else {
                        if (app.delete_req) |req| {
                            app.pending_preset = .{ .delete = .{
                                .cat = req.cat,
                                .name_buf = req.name,
                                .name_len = req.name_len,
                            } };
                        }
                    }
                }
                app.overwrite_req = null;
                app.delete_req = null;
            }
        }

        // 脏确认已结束（且意图为打开）：执行待定的打开
        if (app.dirty_flow == .none and app.pending_open_path != null and app.pending_file_action == null) {
            app.pending_file_action = .open;
        }

        ui_input.mouse_pressed = false;
        ui_input.mouse_released = false;
        ui_input.mouse_right_pressed = false;
        ui_input.mouse_double = false;
        ui_input.wheel = 0;
        ui_input.wheel_ctrl = false;
        ui_input.wheel_alt = false;

        // 1) 输入
        const events = try win.pollEvents();
        // 修饰键（每帧读“当前”状态——框选手势需要实时状态，
        // 而键盘事件里只有按下瞬间的状态）
        {
            const m = win.modifiers();
            ui_input.mods_ctrl = m.ctrl;
            ui_input.mods_shift = m.shift;
        }
        for (events) |ev| {
            switch (ev) {
                .quit => {},
                .mouse_move => |m| {
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                },
                .mouse_double => |m| {
                    ui_input.mouse_double = true;
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                },
                .mouse_down => |m| {
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                    switch (m.button) {
                        .left => {
                            ui_input.mouse_down = true;
                            ui_input.mouse_pressed = true;
                        },
                        .right => {
                            ui_input.mouse_right_down = true;
                            ui_input.mouse_right_pressed = true;
                        },
                        else => {},
                    }
                },
                .mouse_up => |m| {
                    switch (m.button) {
                        .left => {
                            ui_input.mouse_down = false;
                            ui_input.mouse_released = true;
                        },
                        .right => ui_input.mouse_right_down = false,
                        else => {},
                    }
                },
                .mouse_wheel => |m| {
                    ui_input.wheel += m.delta;
                    ui_input.wheel_ctrl = m.ctrl;
                    ui_input.wheel_alt = m.alt;
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                },
                .key_down => |k| {
                    // 模态确认框优先捕获键盘
                    if (app.modal != null) {
                        switch (k.code) {
                            0x0D => app.modal_choice = .save, // Enter = 保存
                            0x1B => app.modal_choice = .cancel, // Esc = 取消
                            else => {},
                        }
                        continue;
                    }
                    // 文本输入（重命名）激活：键盘优先路由（吞掉其余按键，
                    // 防误触快捷键——如输入时的 S 不能变成 Ctrl+S）
                    if (app.text_input.active) {
                        switch (k.code) {
                            0x0D => app.textInputCommit(), // Enter = 提交
                            0x1B => app.textInputCancel(), // Esc = 取消
                            0x08 => app.textInputBackspace(), // Backspace
                            0x2E => app.textInputDelete(), // Del = 删光标后
                            0x25 => app.textInputMoveCursor(-1, k.shift), // ←
                            0x27 => app.textInputMoveCursor(1, k.shift), // →
                            0x24 => app.textInputMoveCursor(-2, k.shift), // Home
                            0x23 => app.textInputMoveCursor(2, k.shift), // End
                            else => {
                                // Ctrl+A：全选
                                if (k.ctrl and (k.code == 'A' or k.code == 'a')) app.textInputSelectAll();
                            },
                        }
                        continue;
                    }
                    if (k.code == 0x1B) { // Esc：关闭菜单 / 返回播放列表（**不退出程序**）
                        if (app.file_menu_open) {
                            app.file_menu_open = false;
                        } else if (app.preset_browser.open) {
                            app.preset_browser.open = false; // 预设浏览器
                        } else if (app.panels.ctx_pattern != null) {
                            app.panels.ctx_pattern = null; // 样式右键菜单
                        } else if (app.piano.pattern != null) {
                            app.closePiano();
                            if (ui.active_id == 6000) ui.active_id = 0; // 释放琴键试听拖动标记
                        }
                        // 退出请用窗口关闭按钮（X / Alt+F4）
                    }
                    if (k.code == 0x20) { // Space：播放/暂停（从游标处开始，基于音频时钟）
                        app.playing = !app.playing;
                        if (app.playing) {
                            const from = if (app.sel.song_mode) app.playback.song_step else app.playback.piano_step;
                            app.playback.start_frame = app.params.frames_played.load(.monotonic);
                            app.playback.start_step = from;
                            app.params.start_frame.store(app.playback.start_frame, .monotonic);
                            app.params.start_step.store(from, .monotonic);
                            app.params.playing.store(true, .monotonic);
                            // 调度：作废旧事件 + 为跨起点长音符补发 on；重置调度窗口
                            sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, from);
                            app.params.sched_gen.store(app.scheduler.gen, .monotonic);
                        } else {
                            app.params.playing.store(false, .monotonic);
                        }
                    }
                    // Ctrl+S：保存（无路径则弹对话框）；Ctrl+Shift+S：另存为；Ctrl+O：打开。
                    // 注：只登记动作，不在事件迭代中弹对话框——事件数组可能被
                    // 对话框泵入的消息 realloc，迭代中的 slice 会悬空（实测崩溃：
                    // “switch on corrupt value”）。帧末统一执行。
                    if (k.ctrl and (k.code == 'S' or k.code == 's')) {
                        app.pending_file_action = if (k.shift) .save_as else .save;
                    }
                    if (k.ctrl and (k.code == 'O' or k.code == 'o')) app.pending_file_action = .open;
                    // ── 编辑快捷键（框选/批量操作；只登记，由当前视图按上下文执行）──
                    // Del（VK_DELETE = 0x2E）：删除选中
                    if (k.code == 0x2E) app.pending_edit_op = .delete_selected;
                    if (k.ctrl and (k.code == 'B' or k.code == 'b')) app.pending_edit_op = .clone_right;
                    if (k.ctrl and (k.code == 'C' or k.code == 'c')) app.pending_edit_op = .copy;
                    if (k.ctrl and (k.code == 'V' or k.code == 'v')) app.pending_edit_op = .paste;
                    if (k.ctrl and (k.code == 'A' or k.code == 'a')) app.pending_edit_op = .select_all;
                    // ── 撤销/重做 ──
                    // Ctrl+Z 撤销；Ctrl+Alt+Z（或 Ctrl+Shift+Z）重做
                    if (k.ctrl and (k.code == 'Z' or k.code == 'z')) {
                        if (k.alt or k.shift) {
                            if (app.redo()) app.setToastWith("重做：{s}", .{app.historyLabel()});
                        } else {
                            // 提示用**被撤销的操作名**——undo 之前先读当前状态标签
                            // （undo 后 history_current 已指向到达的状态）
                            const undone: []const u8 = app.historyLabel();
                            if (app.undo()) app.setToastWith("撤销：{s}", .{undone});
                        }
                    }
                },
                .resize => {},
                .char => |cp| {
                    // 文本输入（重命名）：字符追加（含中文 IME 上屏——字符经
                    // WM_CHAR 到达；emoji 等代理对已在 window.zig 过滤）
                    if (app.text_input.active) app.textInputAppend(cp);
                },
                else => {},
            }
        }

        // 2) 绘制
        // 文本输入（重命名）：输入期间鼠标也归输入框独占（下层控件收不到）：
        // - 点在框外：提交（吞掉该次点击）
        // - 点在框内：定位光标；按住拖动 = 框选（光标跟随鼠标，可拖出框外）
        if (app.text_input.active) {
            const ti = &app.text_input;
            const in_box = ui_input.mouse_x >= ti.x and ui_input.mouse_x < ti.x + ti.w and
                ui_input.mouse_y >= ti.y and ui_input.mouse_y < ti.y + text_input_h;
            if (ui_input.mouse_pressed) {
                if (!in_box) {
                    app.textInputCommit();
                    ui_input.mouse_down = false; // 防拖动启动
                } else {
                    // 框内：拖动 → 框选（锚点 = 击点）；单击 → 仅定位光标
                    const local: f32 = @floatFromInt(ui_input.mouse_x - (ti.x + 4) + ti.view_off);
                    app.textInputPointerDown(ui.textIndexAtX(ti.text(), local));
                }
                ui_input.mouse_pressed = false;
                ui_input.mouse_double = false;
            } else if (app.text_input.drag_active) {
                if (ui_input.mouse_down) {
                    const local: f32 = @floatFromInt(ui_input.mouse_x - (ti.x + 4) + ti.view_off);
                    app.textInputPointerMove(ui.textIndexAtX(ti.text(), local));
                } else {
                    app.textInputPointerUp();
                }
            }
            // 右键：同样吞掉（不让下层弹右键菜单，也不取消输入）
            ui_input.mouse_right_pressed = false;
        }
        // 同步乐器指针/增益到音频线程（成本极低；删除乐器后自动变 null）
        for (0..synth.max_instruments) |i| {
            const has = i < app.instruments.items.len;
            const inst: ?*const model.Instrument = if (has) &app.instruments.items[i] else null;
            const sp: ?*synth.SynthParams = if (has) app.instruments.items[i].synth else null;
            app.params.synth_ptrs[i].store(sp, .monotonic);
            const g: f32 = if (has)
                (if (app.instruments.items[i].muted) 0.0 else app.instruments.items[i].volume)
            else
                0.0;
            app.params.instrument_gain[i].store(g, .monotonic);
            // 混音通道路由（`mixer` 已是 0 起；**按实际通道数**钳制——
            // 否则通道数减少后旧值会指向不存在的通道，实测 bug）
            const n_ch: u32 = @intCast(app.mixer_channels_state.items.len);
            const ch: u32 = if (has and n_ch > 0)
                @intCast(std.math.clamp(app.instruments.items[i].mixer, 0, @as(i32, @intCast(n_ch)) - 1))
            else
                0;
            app.params.instrument_channel[i].store(ch, .monotonic);
            // 乐器类型 + 鼓组层槽位（kind 边沿会在音频侧触发全释音）
            app.params.instrument_kind[i].store(if (inst) |it| @intFromEnum(it.kind) else 0, .monotonic);
            // 鼓组：把各垫的层**展平**到 16 个槽位（垫按音高升序；槽位顺序 = 扫过垫再扫层）。
            // 槽位音高 = 垫音高（音频侧 on 事件按音高分发，多槽位同音高 = 多层叠加）
            var slot: usize = 0;
            if (inst) |it| {
                if (it.kit) |kit| {
                    outer: for (kit.pads.items) |pad| {
                        for (pad.layers.items) |ly| {
                            if (slot >= audio.kit_max_layers) break :outer;
                            app.params.kit_layer_pitch[i][slot].store(pad.pitch, .monotonic);
                            app.params.kit_layer_gain[i][slot].store(ly.gain, .monotonic);
                            app.params.kit_layer_params[i][slot].store(ly.params, .monotonic);
                            slot += 1;
                        }
                    }
                }
            }
            // 清掉多余旧槽位（层数减少时防旧指针/旧音高残留）
            while (slot < audio.kit_max_layers) : (slot += 1) {
                app.params.kit_layer_pitch[i][slot].store(0, .monotonic);
                app.params.kit_layer_params[i][slot].store(null, .monotonic);
            }
            app.params.kit_layer_count[i].store(@intCast(slot), .monotonic);
        }

        // 同步调音台通道参数（增益/声像/静音/效果链）到音频线程
        const n_mixer: usize = @min(app.mixer_channels_state.items.len, audio.mixer_channels);
        app.params.channel_count.store(@intCast(n_mixer), .monotonic);
        for (0..n_mixer) |ci| {
            const mc = app.mixer_channels_state.items[ci];
            app.params.channel_gain[ci].store(mc.volume, .monotonic);
            app.params.channel_pan[ci].store(mc.pan, .monotonic);
            app.params.channel_muted[ci].store(mc.muted, .monotonic);
            // 效果链长度 + 元数据（kind/enabled/mix）：逐槽对比才写
            const eff_n: usize = @min(mc.effects.items.len, audio.effect_slots);
            app.params.effect_count[ci].store(@intCast(eff_n), .monotonic);
            var chain_changed = false;
            for (0..eff_n) |slot| {
                const es = mc.effects.items[slot];
                const k: u32 = @intFromEnum(es.kind);
                if (app.params.effect_kind[ci][slot].load(.monotonic) != k) {
                    app.params.effect_kind[ci][slot].store(k, .monotonic);
                    chain_changed = true;
                }
                if (app.params.effect_enabled[ci][slot].load(.monotonic) != es.enabled) {
                    app.params.effect_enabled[ci][slot].store(es.enabled, .monotonic);
                    chain_changed = true;
                }
                if (app.params.effect_mix[ci][slot].load(.monotonic) != es.mix) {
                    app.params.effect_mix[ci][slot].store(es.mix, .monotonic);
                    chain_changed = true;
                }
            }
            if (chain_changed) {
                const v = app.params.effect_chain_version[ci].load(.monotonic);
                app.params.effect_chain_version[ci].store(v +% 1, .monotonic);
            }
            // EQ 参数（取**首个 EQ** 的参数——当前 EQ 参数由链上 EQ 共享）
            var eq_bands: ?[eq.band_count]eq.BandParams = null;
            for (mc.effects.items) |es| {
                if (es.kind == .eq) {
                    eq_bands = es.bands;
                    break;
                }
            }
            if (eq_bands) |bands| {
                var ch_changed = false;
                for (0..eq.band_count) |b| {
                    const old = app.params.channel_eq[ci][b];
                    const new = bands[b];
                    if (old.freq != new.freq or old.gain_db != new.gain_db or old.q != new.q) {
                        app.params.channel_eq[ci][b] = new;
                        ch_changed = true;
                    }
                }
                if (ch_changed) {
                    const v = app.params.channel_eq_version[ci].load(.monotonic);
                    app.params.channel_eq_version[ci].store(v +% 1, .monotonic);
                }
            }
        }

        // 播放推进 + 序列器调度：**由音频采样时钟驱动**（frames_played），不由渲染驱动。
        // 每步 = 1 / (每拍步数) 拍；每拍步数 = U / 分母（拍号可变）。
        // 旧公式硬编码 4（= 16 分音符分辨率）；U=96 后必须用动态值，否则速度差 6 倍。
        if (app.playing) {
            const frames = app.params.frames_played.load(.monotonic);
            const bpm: u64 = @intCast(std.math.clamp(app.bpm, 20, 999));
            const spb_per_beat: u64 = @intCast(model.stepsPerBeat(app.time_den));
            const step_frames: u64 = @max(1, app.params.sample_rate * 60 / (bpm * spb_per_beat));
            const elapsed_steps: i32 = @intCast((frames - app.playback.start_frame) / step_frames);
            const cur = app.playback.start_step + elapsed_steps;
            if (app.sel.song_mode) {
                app.playback.song_step = cur;
            } else {
                app.playback.piano_step = cur;
            }

            // 循环回跳（循环区域 / 内容末尾自动循环）——
            // 必须在推进后、调度前检查：回跳会重置传输基准并重扫调度窗口。
            app.tickPlaybackLoop();

            // 调度 lookahead：提前 4 小节（步单位随拍号/分辨率变化）
            const cur2 = app.playback.cursorStep(app.sel.song_mode);
            const horizon = cur2 + app.steps_per_bar * 4;
            if (horizon > app.scheduler.scheduled_upto) {
                sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, app.scheduler.scheduled_upto, horizon);
            }
        }
        // 同步发声音高缓存（音频线程回传的位掩码 → 当前乐器的音高集合）
        {
            const si: usize = @intCast(std.math.clamp(app.sel.instrument, 0, @as(i32, synth.max_instruments - 1)));
            app.sounding.set(app.params.sounding_lo[si].load(.monotonic), app.params.sounding_hi[si].load(.monotonic));
        }

        // 同步 BPM / 每拍步数 到音频线程（序列器换算步→帧用）
        app.params.bpm.store(@intCast(std.math.clamp(app.bpm, 20, 999)), .monotonic);
        app.params.steps_per_beat.store(@intCast(model.stepsPerBeat(app.time_den)), .monotonic);

        ui.renderer = r_mod.Renderer.init(&win.fb);
        ui.mouse_x = ui_input.mouse_x;
        ui.mouse_y = ui_input.mouse_y;
        ui.mouse_down = ui_input.mouse_down;
        ui.mouse_pressed = ui_input.mouse_pressed;
        ui.mouse_released = ui_input.mouse_released;
        ui.mouse_right_pressed = ui_input.mouse_right_pressed;
        ui.mouse_right_down = ui_input.mouse_right_down;
        ui.mouse_double = ui_input.mouse_double;
        ui.wheel = ui_input.wheel;
        ui.wheel_ctrl = ui_input.wheel_ctrl;
        ui.wheel_alt = ui_input.wheel_alt;
        ui.mods_ctrl = ui_input.mods_ctrl;
        ui.mods_shift = ui_input.mods_shift;

        // □ 缩放拖动：鼠标冻结（光标隐藏 + 锚定不动，位移经 frozen_dy 传入）
        if (ui.mouse_capture) {
            win.beginMouseCapture();
            ui.cursor = .hidden;
        } else {
            win.endMouseCapture();
        }
        ui.frozen_dy = win.frozenDeltaY();

        // 每帧递减状态栏提示（按实际流逝时间，与帧率无关）
        const toast_now_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        app.tickToast(toast_now_ns - frame_start_ns);

        ui.beginFrame();
        drawApp(&ui, &app, @intCast(win.fb.width), @intCast(win.fb.height));
        // 文件菜单：在 UI 之后、endFrame **之前**（endFrame 会清 mouse_pressed——
        // 放在之后则菜单永远收不到点击，实测“点菜单没反应”）
        if (app.file_menu_open) drawFileMenu(&ui, &app);
        // 样式右键菜单：同上（浮动窗口之后，否则会被盖住）
        if (app.panels.ctx_pattern != null) view_panels.drawPatternCtxMenu(&ui, &app);
        // 预设浏览器（模态；同上——浮动窗口之后）
        if (app.preset_browser.open) view_presets.draw(&ui, &app, @intCast(win.fb.width), @intCast(win.fb.height));
        // 模态确认框（最上层；自绘——避开系统 MessageBox 把鼠标吸到默认按钮）
        if (app.modal != null) drawModal(&ui, &app);
        // 文本输入框（最顶层——跨窗口/菜单，重命名乐器/通道用）
        if (app.text_input.active) {
            const ti = &app.text_input;
            ti.view_off = ui.textFieldSyncOffset(ti.text(), ti.cursor, ti.w, ti.view_off);
            ui.renderer.fillRect(ti.x + 2, ti.y + 2, ti.w, text_input_h, r_mod.rgb(12, 13, 16)); // 阴影
            ui.textField(ti.text(), ti.cursor, ti.selection(), ti.view_off, ti.x, ti.y, ti.w, text_input_h);
        }
        ui.endFrame();

        // 普通拖动（滚动条/片段/音符/分隔条）捕获鼠标：拖出窗口后仍能收到松开事件
        // （否则拖动状态卡死，鼠标移回时误触发拖动分支 → 回弹/跳变）。
        // 文本框框选（拖出框/窗口）同理由此受益。
        // 冻结模式由 begin/endMouseCapture 自行管理，此处不碰。
        if (!ui.mouse_capture) win.setDragCapture(ui.active_id != 0 or app.text_input.drag_active);

        // 冻结中的光标：强制隐藏（控件可能在绘制时请求了别的形状）
        if (win.mouse_captured) ui.cursor = .hidden;

        // 3) 光标形状（UI 在绘制时按需请求）
        win.setCursor(ui.cursor);

        // 4) 呈现
        win.present();

        // 4.1) 历史提交（拖动类操作 **coalesce**：鼠标松开才提交一次——
        // 一次拖动 = 一条历史，而不是每帧一条；左右键都算）
        // 注：**滚轮类** pending 不走这里（无“松开”事件）——它用静默间隔，
        // 见 `pollWheelHistory`
        if (app.history_pending) |label| {
            if (!app.history_pending_wheel and !ui_input.mouse_down and !ui_input.mouse_right_down) {
                app.commitHistory(label);
                app.history_pending = null;
            }
        }
        app.pollWheelHistory();

        // 4.2) 帧末执行待定的文件操作（对话框在此弹出——不在事件迭代/绘制中，
        // 避免 pushEvent realloc 使迭代中的 events slice 悬空）
        if (app.pending_file_action) |act| {
            app.pending_file_action = null;
            ui.active_id = 0; // 对话框会抢走鼠标：清掉拖动状态
            win.setDragCapture(false);
            switch (act) {
                .open => {
                    // 已有待定路径（脏确认后继续打开）→ 直接加载；
                    // 否则弹对话框选文件
                    if (app.pending_open_path) |p| {
                        defer app.clearPendingOpen();
                        loadProjectFromPath(&app, io, p);
                    } else {
                        openProjectWithDialog(&app, &win, io);
                    }
                },
                .save => saveProject(&app, &win, io, false),
                .save_as => saveProject(&app, &win, io, true),
                .import_midi => importMidiWithDialog(&app, &win, io),
                .export_midi => exportMidiWithDialog(&app, &win, io),
            }
        }

        // 4.3) 预设库操作（文件 IO——同上帧末；App 无 io）
        if (app.pending_preset) |act| {
            app.pending_preset = null;
            switch (act) {
                .scan => scanPresets(&app, io),
                .load => |l| loadPreset(&app, io, l.intent, l.cat, l.choice),
                .save => |s| savePreset(&app, io, s.source, s.name_buf[0..s.name_len], s.overwrite),
                .rename => |r| renamePreset(&app, io, r.cat, r.old_buf[0..r.old_len], r.new_buf[0..r.new_len]),
                .delete => |d| deletePreset(&app, io, d.cat, d.name_buf[0..d.name_len]),
            }
        }

        // 4.5) 同步窗口标题（脏标记 `*` + 工程名；仅在变化时刷 Win32）
        const cur_name = app.projectName();
        const name_changed = blk: {
            const a = app.title_applied_name orelse break :blk (cur_name != null);
            const b = cur_name orelse break :blk true;
            break :blk !std.mem.eql(u8, a, b);
        };
        if (app.title_applied_dirty != app.dirty or name_changed) {
            app.title_applied_dirty = app.dirty;
            if (app.title_applied_name) |old| app.allocator.free(old);
            app.title_applied_name = if (cur_name) |n| (app.allocator.dupe(u8, n) catch null) else null;

            var title_buf: [192]u8 = undefined;
            const base = "Sawdust — Simple Audio Workstation";
            const title = if (cur_name) |n|
                (std.fmt.bufPrint(&title_buf, "Sawdust — {s}", .{n}) catch base)
            else
                base;
            var with_dirty: [208]u8 = undefined;
            const final_title = if (app.dirty)
                (std.fmt.bufPrint(&with_dirty, "* {s}", .{title}) catch title)
            else
                title;
            win.setTitle(final_title);
        }

        // （帧预算睡眠已移到循环首的 `defer`——睡眠时长需减去本帧渲染耗时，
        // 固定尾部睡眠会与渲染耗时叠加，帧率随内容复杂度浮动）
    }
    return 0;
}

/// 文本输入框高度（重命名用；固定值）
const text_input_h: i32 = 22;

// ── 数据目录与预设库（文件 IO 集中区）──

const preset_mod = @import("preset.zig");

extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;

/// 可执行文件所在目录（UTF-8 写入 `buf`；失败返回 ""）。
/// 用于定位便携数据目录 `<exe>/data`（见 `preset.resolveDataRoot`）。
fn exeDir(allocator: std.mem.Allocator, buf: []u8) []const u8 {
    var wbuf: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &wbuf, wbuf.len);
    if (n == 0 or n >= wbuf.len) return "";
    const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..n]) catch return "";
    defer allocator.free(utf8);
    const dir = std.fs.path.dirname(utf8) orelse return "";
    const m = @min(dir.len, buf.len);
    @memcpy(buf[0..m], dir[0..m]);
    return buf[0..m];
}

/// 扫描预设库（启动/保存后；损坏分类/文件静默跳过——见 preset.scan）
fn scanPresets(app: *App, io: std.Io) void {
    const root = app.dataRoot();
    if (root.len == 0) return; // 未设置数据目录：预设功能禁用
    var buf: [512]u8 = undefined;
    preset_mod.ensureSkeleton(io, root, &buf); // 首次运行建骨架（已存在无害）
    app.preset_lib.deinit(app.allocator);
    app.preset_lib = preset_mod.scan(io, app.allocator, root) catch .{};
    // 浏览器分类索引钳制（库变化后可能越界）
    const n_cat = app.preset_lib.categories.items.len;
    if (n_cat == 0) {
        app.preset_browser.cat = 0;
    } else if (app.preset_browser.cat >= n_cat) {
        app.preset_browser.cat = n_cat - 1;
    }
}

/// 预设面板选中回调（文件 IO 在这里）：按**意图**分派。
/// **面板已统一**：任何入口都可点任意已实装插件——跨插件 = 顺带换插件
/// （乐器本体）；层仅减法。全部动作可撤销（commitHistory）。
fn loadPreset(app: *App, io: std.Io, intent: PresetIntent, cat: usize, choice: PresetChoice) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const c = &cats[cat];
    const plugin = c.name;
    if (!app.presetCategorySelectable(intent, plugin)) {
        // 防御（UI 已拦）：按原因提示
        if (std.mem.eql(u8, plugin, preset_mod.plugin_drumkit)) {
            app.setToast("鼓组里不能再嵌鼓组");
        } else {
            app.setToast("该插件的引擎尚未实装");
        }
        return;
    }

    switch (choice) {
        .default => switch (intent) {
            .replace => |t| switch (t) {
                .instrument => |ii| applyInstrumentChoice(app, ii, plugin, null, ""),
                .kit_layer_replace => |ref| applyLayerChoice(app, ref, null, ""),
            },
            .change_instrument => |ii| applyInstrumentChoice(app, ii, plugin, null, ""),
            .create_instrument => createInstrumentChoice(app, plugin, null, ""),
            .create_kit_layer => |ref| addLayerChoice(app, ref, null, ""),
        },
        .preset => |idx| {
            if (idx >= c.presets.items.len) return;
            // 层上下文只接受减法预设文件（防御：UI 已把鼓组分类置灰）
            const is_layer_ctx = switch (intent) {
                .create_kit_layer => true,
                .replace => |t| switch (t) {
                    .kit_layer_replace => true,
                    .instrument => false,
                },
                else => false,
            };
            if (is_layer_ctx and !std.mem.eql(u8, plugin, preset_mod.plugin_subtractive)) {
                app.setToast("鼓组里不能再嵌鼓组");
                return;
            }
            const preset_name = c.presets.items[idx];
            const parsed = preset_mod.load(io, app.allocator, app.dataRoot(), c.name, preset_name, plugin) catch |e| {
                app.setToastWith("加载预设失败：{s}", .{@errorName(e)});
                return;
            };
            defer parsed.deinit();
            // 来源字符串 `分类/名字`（鼓组层展示用）
            var sbuf: [preset_mod.max_name_len * 2 + 4]u8 = undefined;
            const src = std.fmt.bufPrint(&sbuf, "{s}/{s}", .{ c.name, preset_name }) catch preset_name;

            switch (intent) {
                .replace => |t| switch (t) {
                    .instrument => |ii| applyInstrumentChoice(app, ii, plugin, &parsed.value, preset_name),
                    .kit_layer_replace => |ref| applyLayerChoice(app, ref, &parsed.value.synth, src),
                },
                .change_instrument => |ii| applyInstrumentChoice(app, ii, plugin, &parsed.value, preset_name),
                .create_instrument => createInstrumentChoice(app, plugin, &parsed.value, preset_name),
                .create_kit_layer => |ref| addLayerChoice(app, ref, &parsed.value.synth, src),
            }
        },
    }
}

/// 应用到**乐器本体**（「预设 ▾」/右键更换共用）：跨插件先换类型，
/// 再载音色/套鼓（或默认）——**一条历史**；名字/音量/声像/路由保留。
fn applyInstrumentChoice(app: *App, ii: i32, plugin: []const u8, file: ?*const preset_mod.File, patch_name: []const u8) void {
    if (ii < 0 or ii >= @as(i32, @intCast(app.instruments.items.len))) return;
    const is_kit = std.mem.eql(u8, plugin, preset_mod.plugin_drumkit);
    const kind: model.InstrumentKind = if (is_kit) .drumkit else .synth;
    const kind_changed = app.changeInstrumentKind(@intCast(ii), kind, false);
    if (is_kit) {
        if (file) |f| {
            _ = app.loadKitInto(@intCast(ii), &f.kit);
            _ = app.setInstrumentPresetName(@intCast(ii), patch_name); // 关联名（保存预填用；提交前进快照）
            app.commitHistory(if (kind_changed) "更换乐器" else "加载预设");
            if (kind_changed) {
                app.setToastWith("已更换为鼓组并载入套鼓：{s}", .{patch_name});
            } else {
                app.setToastWith("已加载套鼓：{s}", .{patch_name});
            }
        } else if (kind_changed) {
            _ = app.setInstrumentPresetName(@intCast(ii), "");
            app.commitHistory("更换乐器");
            app.setToast("已换为鼓组（空套鼓，可撤销）");
        } else {
            // 已是鼓组：默认伪预设 = 重置为空套鼓（与减法的“重置音色”对称）
            const empty = persist.SavedDrumKit{};
            _ = app.loadKitInto(@intCast(ii), &empty);
            _ = app.setInstrumentPresetName(@intCast(ii), "");
            app.commitHistory("重置音色");
            app.setToast("已重置为空套鼓（可撤销）");
        }
        return;
    }
    // 减法：应用音色（文件）或默认基准
    const inst = &app.instruments.items[@intCast(ii)];
    if (file) |f| {
        persist.importSynth(&f.synth, inst.synth);
        _ = app.setInstrumentPresetName(@intCast(ii), patch_name);
    } else {
        const d = persist.defaultSavedSynth();
        persist.importSynth(&d, inst.synth);
        _ = app.setInstrumentPresetName(@intCast(ii), "");
    }
    if (file != null) {
        app.commitHistory(if (kind_changed) "更换乐器" else "加载预设");
        if (kind_changed) {
            app.setToastWith("已更换乐器并载入预设：{s}", .{patch_name});
        } else {
            app.setToastWith("已加载预设：{s}", .{patch_name});
        }
    } else {
        app.commitHistory(if (kind_changed) "更换乐器" else "重置音色");
        app.setToast(if (kind_changed) "已换为减法合成器（默认音色）" else "已重置为默认音色");
    }
}

/// 新建乐器（机架「＋ 添加乐器」）
fn createInstrumentChoice(app: *App, plugin: []const u8, file: ?*const preset_mod.File, patch_name: []const u8) void {
    if (std.mem.eql(u8, plugin, preset_mod.plugin_drumkit)) {
        const ni = app.addDrumkit("鼓组");
        if (ni >= 0) {
            if (file) |f| {
                _ = app.loadKitInto(@intCast(ni), &f.kit);
                _ = app.setInstrumentPresetName(@intCast(ni), patch_name);
            }
        }
        app.commitHistory("添加乐器");
        if (file != null) {
            app.setToastWith("已添加鼓组：{s}", .{patch_name});
        } else {
            app.setToast("已添加鼓组（空套鼓）");
        }
        return;
    }
    const ni = app.addInstrument("减法合成器");
    if (ni >= 0) {
        if (file) |f| {
            persist.importSynth(&f.synth, app.instruments.items[@intCast(ni)].synth);
            _ = app.setInstrumentPresetName(@intCast(ni), patch_name);
        }
    }
    app.commitHistory("添加乐器");
    if (file != null) {
        app.setToastWith("已添加乐器：{s}", .{patch_name});
    } else {
        app.setToast("已添加乐器（默认音色）");
    }
}

/// 鼓垫**加一个乐器**（层 = 乐器槽）
fn addLayerChoice(app: *App, ref: PresetIntent.KitPadRef, patch: ?*const persist.SavedSynth, src: []const u8) void {
    if (!app.kitLayerAdd(ref.instrument, ref.pitch, patch, src)) {
        app.setToastWith("添加失败（层数已满？上限 {d}）", .{audio.kit_max_layers});
        return;
    }
    app.commitHistory("添加乐器");
    openKitLayerWindow(app, ref.instrument, ref.pitch);
    app.setToast("已添加乐器 — 在窗口里点「预设 ▾」换音色");
}

/// 应用到**已有鼓组层**（层窗口「预设 ▾」）：换音色/默认 + 更新来源名
fn applyLayerChoice(app: *App, ref: PresetTarget.KitLayerRef, patch: ?*const persist.SavedSynth, src: []const u8) void {
    const lp = app.kitLayerParams(ref.instrument, ref.pitch, ref.layer) orelse {
        app.setToast("目标层已不存在");
        return;
    };
    if (patch) |p| {
        persist.importSynth(p, lp);
    } else {
        const d = persist.defaultSavedSynth();
        persist.importSynth(&d, lp);
    }
    _ = app.kitLayerSetSource(ref.instrument, ref.pitch, ref.layer, src); // 默认（src=""）= 清来源
    app.commitHistory(if (patch != null) "加载预设" else "重置音色");
    if (patch != null) {
        app.setToast("已加载预设到该层");
    } else {
        app.setToast("已重置该层为默认音色");
    }
}

/// 打开刚添加的鼓组层乐器窗口（用户顺势点「预设 ▾」）
fn openKitLayerWindow(app: *App, inst_idx: i32, pitch: u8) void {
    if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(app.instruments.items.len))) return;
    const kit = app.instruments.items[@intCast(inst_idx)].kit orelse return;
    const pad = kit.find(pitch) orelse return;
    if (pad.layers.items.len == 0) return;
    app.synth_win.target = .{ .kit_layer_replace = .{
        .instrument = inst_idx,
        .pitch = pitch,
        .layer = pad.layers.items.len - 1,
    } };
    app.synth_win.open = true;
    app.bringToFront(&app.synth_win.z);
}

/// 保存目标当前参数为新预设（名字清洗/重名/原子写在 `preset.save` 内）；
/// 鼓组层：保存后记住来源预设名（展示用）
/// 保存预设（参数槽 / 整组套鼓）；名字清洗/重名/原子写在 `preset.save*` 内。
/// 重名且非覆写 → 弹“是否覆写”确认（`setOverwritePrompt`，确认后重排本函数）。
fn savePreset(app: *App, io: std.Io, source: PresetSaveSource, raw_name: []const u8, overwrite: bool) void {
    const root = app.dataRoot();
    if (root.len == 0) {
        app.setToast("数据目录不可用，无法保存预设");
        return;
    }
    // 清洗后的名字（重名提示/关联名更新都以它为准）
    var nb: [preset_mod.max_name_len]u8 = undefined;
    const clean = preset_mod.sanitizeName(raw_name, &nb);
    if (clean.len == 0) {
        app.setToast("保存预设失败：预设名为空或非法");
        return;
    }
    switch (source) {
        .params => |target| {
            const params = app.resolvePresetTarget(target) orelse {
                app.setToast("保存目标已不存在");
                return;
            };
            const plugin = app.presetTargetPlugin(target);
            const file = preset_mod.File{ .plugin = plugin, .synth = persist.exportSynth(params) };
            preset_mod.saveFile(io, app.allocator, root, plugin, clean, file, overwrite) catch |e| {
                if (e == error.AlreadyExists and !overwrite) {
                    app.setOverwritePrompt(source, clean);
                    return;
                }
                saveFailed(app, e);
                return;
            };
            // 关联名更新：乐器 → `preset_name`；鼓组层 → `source_preset`（展示用）
            switch (target) {
                .instrument => |i| {
                    if (i >= 0 and i < @as(i32, @intCast(app.instruments.items.len))) {
                        _ = app.setInstrumentPresetName(@intCast(i), clean);
                    }
                },
                .kit_layer_replace => |ref| {
                    var sbuf: [preset_mod.max_name_len * 2 + 4]u8 = undefined;
                    const src = std.fmt.bufPrint(&sbuf, "{s}/{s}", .{ plugin, clean }) catch clean;
                    if (app.kitLayerSetSource(ref.instrument, ref.pitch, ref.layer, src)) {
                        app.commitHistory("保存预设");
                    }
                },
            }
        },
        .kit => |ii| {
            if (ii < 0 or ii >= @as(i32, @intCast(app.instruments.items.len))) return;
            if (app.instruments.items[@intCast(ii)].kit == null) {
                app.setToast("该乐器没有鼓组数据");
                return;
            }
            // 深拷贝快照（自包含：层内嵌合成器参数）→ 写盘后释放
            const snapshot = app.exportKitForSave(@intCast(ii)) orelse {
                app.setToast("导出套鼓失败（内存不足？）");
                return;
            };
            defer app.freeSavedKit(&snapshot);
            const file = preset_mod.File{ .plugin = preset_mod.plugin_drumkit, .kit = snapshot };
            preset_mod.saveFile(io, app.allocator, root, preset_mod.plugin_drumkit, clean, file, overwrite) catch |e| {
                if (e == error.AlreadyExists and !overwrite) {
                    app.setOverwritePrompt(source, clean);
                    return;
                }
                saveFailed(app, e);
                return;
            };
            _ = app.setInstrumentPresetName(@intCast(ii), clean);
        },
    }
    if (overwrite) {
        app.setToastWith("已覆写预设：{s}（其它已加载它的乐器不受影响）", .{clean});
    } else {
        app.setToastWith("已保存预设：{s}", .{clean});
    }
    scanPresets(app, io); // 立即出现在面板列表里
}

/// 重命名预设文件（重名/空名 → toast；成功后重扫）
fn renamePreset(app: *App, io: std.Io, cat: usize, old_name: []const u8, raw_new: []const u8) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const plugin = cats[cat].name;
    preset_mod.rename(io, app.dataRoot(), plugin, old_name, raw_new) catch |e| {
        const msg = switch (e) {
            error.InvalidName => "新名为空或非法",
            error.AlreadyExists => "同名预设已存在",
            else => "重命名失败",
        };
        app.setToastWith("重命名预设失败：{s}", .{msg});
        return;
    };
    var nb: [preset_mod.max_name_len]u8 = undefined;
    const clean = preset_mod.sanitizeName(raw_new, &nb);
    app.setToastWith("已重命名预设：{s}", .{clean});
    scanPresets(app, io);
}

/// 删除预设文件（确认后的执行路径；成功后重扫）
fn deletePreset(app: *App, io: std.Io, cat: usize, name: []const u8) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const plugin = cats[cat].name;
    preset_mod.remove(io, app.dataRoot(), plugin, name) catch {
        app.setToast("删除预设失败");
        return;
    };
    app.setToastWith("已删除预设：{s}", .{name});
    scanPresets(app, io);
}

/// 保存失败的统一提示文案
fn saveFailed(app: *App, e: anyerror) void {
    const msg = switch (e) {
        error.InvalidName => "预设名为空或非法",
        error.AlreadyExists => "同名预设已存在",
        else => "写入失败",
    };
    app.setToastWith("保存预设失败：{s}", .{msg});
}

const InputState = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_down: bool = false,
    mouse_pressed: bool = false,
    mouse_released: bool = false,
    mouse_right_pressed: bool = false,
    mouse_right_down: bool = false,
    mouse_double: bool = false,
    wheel: i32 = 0,
    wheel_ctrl: bool = false,
    wheel_alt: bool = false,
    mods_ctrl: bool = false,
    mods_shift: bool = false,
};

// ── 主界面组装 ──

fn drawApp(ui: *Ui, app: *App, w: i32, h: i32) void {
    app.layout.initIfNeeded(w);

    // ── 层声明（帧首）──
    // 立即式 UI 里“绘制顺序 = 事件处理顺序”；层系统把“谁接收鼠标”
    // 从手写组合逻辑变成**声明式**：各层声明矩形，beginLayer 自动判定是否被上层屏蔽。
    //
    // **浮动窗口按 z 排序**（点谁谁置顶）：每个窗口持有自己的 z，
    // 按 z 升序声明层 + 绘制（后声明/后绘制 = 在上）。
    // 注：早期版本给窗口写死 prio（合成器/调音台都是 2）——而 `ui.declare`
    // 对**同 prio 是覆盖**，后声明的把先声明的层顶掉 → 被顶那层点击穿透（实测 bug）。
    const rack_open = app.rack.open;
    const synth_open = app.synth_win.open;
    const mixer_open = app.mixer_win.open;    // 效果器面板（依赖调音台的 panel 选择；通道/槽位有效才显示）
    const effect_open = app.mixer_win.panel != null;
    // 频谱目标（EQ 背景 = **该效果器的输入信号**）：每帧发布（关窗 → -1：
    // 音频线程停止捕获，省 CPU）。见 audio.captureSpectrum。
    if (app.mixer_win.panel) |p| {
        app.params.spec_target_ch.store(@intCast(@min(p.ch, audio.mixer_channels - 1)), .monotonic);
        app.params.spec_target_slot.store(@intCast(@min(p.slot, audio.effect_slots - 1)), .monotonic);
    } else {
        app.params.spec_target_ch.store(-1, .monotonic);
    }
    // 机架的下拉/右键菜单、文件菜单 = 模态层（全屏屏蔽）。
    // 注：钢琴卷帘的两个标题栏选单**不在此列**——它们保持轻量语义，
    // 这样两个选单可以单击直接互切（进模态层会让选择器按钮自身被屏蔽）。
    // **组合集中在 `App.menuIsOpen`**（漏项会导致点击穿透下层——
    // 实测 bug：文件→保存穿透点到左栏“操作历史”）。
    const menu_open = app.menuIsOpen();

    // 浮动窗口列表（按 z 升序 = 从下到上）；排序用插入排序（只有 5 个元素）
    var wins: [5]struct { z: i32, draw: enum { rack, synth, mixer, effect, drumkit } } = undefined;
    var nwin: usize = 0;
    if (rack_open) {
        wins[nwin] = .{ .z = app.rack.z, .draw = .rack };
        nwin += 1;
    }
    if (synth_open) {
        wins[nwin] = .{ .z = app.synth_win.z, .draw = .synth };
        nwin += 1;
    }
    if (app.drumkit_win.open) {
        wins[nwin] = .{ .z = app.drumkit_win.z, .draw = .drumkit };
        nwin += 1;
    }
    if (mixer_open) {
        wins[nwin] = .{ .z = app.mixer_win.z, .draw = .mixer };
        nwin += 1;
    }
    if (effect_open) {
        wins[nwin] = .{ .z = app.effect_win.z, .draw = .effect };
        nwin += 1;
    }
    {
        var i: usize = 1;
        while (i < nwin) : (i += 1) {
            const key = wins[i];
            var j: usize = i;
            while (j > 0 and wins[j - 1].z > key.z) : (j -= 1) wins[j] = wins[j - 1];
            wins[j] = key;
        }
    }

    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = w, .h = h } }); // 主界面
    // 模态确认框（最高优先级，全屏屏蔽）：存在时所有低层不响应鼠标
    if (app.modal != null) {
        _ = ui.declare(.{ .prio = 1000, .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .modal = true });
    }
    // 浮动窗口：prio = 窗口 z（+1 避开主界面 0）；按 z 升序声明（同层上覆盖下）
    // 注：prio 用 1 + idx（idx = 排序后的位次）而非窗口 z 值——declare 对
    // 同 prio 是覆盖且要求 prio 互不相同；位次天然互异且与排序一致。
    for (wins[0..nwin], 0..) |win, wi| {
        const r: @import("ui.zig").Rect = switch (win.draw) {
            .rack => .{ .x = app.rack.x, .y = app.rack.y, .w = app.rack.w, .h = app.rack.h },
            .synth => .{ .x = app.synth_win.x, .y = app.synth_win.y, .w = app.synth_win.w, .h = app.synth_win.h },
            .mixer => .{ .x = app.mixer_win.x, .y = app.mixer_win.y, .w = app.mixer_win.w, .h = app.mixer_win.h },
            .effect => .{ .x = app.effect_win.x, .y = app.effect_win.y, .w = app.effect_win.w, .h = app.effect_win.h },
            .drumkit => .{ .x = app.drumkit_win.x, .y = app.drumkit_win.y, .w = app.drumkit_win.w, .h = app.drumkit_win.h },
        };
        _ = ui.declare(.{ .prio = 1 + @as(i32, @intCast(wi)), .rect = r });
    }
    if (menu_open) {
        // 任何菜单展开 = 最上模态层（全屏屏蔽）
        _ = ui.declare(.{ .prio = 900, .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .modal = true });
    }

    // 主界面（prio 0）
    _ = ui.beginLayer(0);

    drawToolbar(ui, app, w);

    // 三栏区域（工具栏与状态栏之间）
    const body_y = util.toolbar_h;
    const body_h = h - util.toolbar_h - util.status_h;
    if (body_h <= 0) return;

    // 限制左右栏宽度（保证最小宽度）
    const total = w;
    app.layout.left_w = std.math.clamp(app.layout.left_w, util.min_pane_w, @max(util.min_pane_w, total - app.layout.mid_w - util.min_pane_w - util.splitter_w * 2));
    app.layout.mid_w = std.math.clamp(app.layout.mid_w, util.min_pane_w, @max(util.min_pane_w, total - app.layout.left_w - util.min_pane_w - util.splitter_w * 2));

    // 左栏：操作历史
    view_panels.drawHistory(ui, app, 0, body_y, app.layout.left_w, body_h);

    // 分隔条 1（x == left_w == pos）
    _ = ui.splitterV(1, &app.layout.left_w, app.layout.left_w, body_y, body_h, util.splitter_w, util.min_pane_w, @max(util.min_pane_w, total - app.layout.mid_w - util.min_pane_w - util.splitter_w * 2));

    // 中栏：样式
    const mid_x = app.layout.left_w + util.splitter_w;
    view_panels.drawPatterns(ui, app, mid_x, body_y, app.layout.mid_w, body_h);

    // 分隔条 2（x = left_w + splitter_w + mid_w；pos 指向 mid_w）
    const sp2_x = app.layout.left_w + util.splitter_w + app.layout.mid_w;
    _ = ui.splitterV(2, &app.layout.mid_w, sp2_x, body_y, body_h, util.splitter_w, util.min_pane_w, @max(util.min_pane_w, total - app.layout.left_w - util.min_pane_w - util.splitter_w * 2));

    // 右栏：播放列表 / 钢琴卷帘（互斥；用更新后的宽度）
    const right_x2 = app.layout.left_w + util.splitter_w + app.layout.mid_w + util.splitter_w;
    const right_w2 = @max(util.min_pane_w, w - right_x2);
    if (app.piano.pattern != null) {
        view_pianoroll.draw(ui, app, right_x2, body_y, right_w2, body_h);
    } else {
        view_playlist.draw(ui, app, right_x2, body_y, right_w2, body_h);
    }

    // 状态栏
    view_panels.drawStatusBar(ui, app, w, h);
    ui.endLayer(); // 主界面层结束（浮动窗口之前）

    // 浮动窗口：按 z 升序绘制（后画 = 在上；与层声明同一顺序）
    for (wins[0..nwin], 0..) |win, wi| {
        _ = ui.beginLayerNoClip(1 + @as(i32, @intCast(wi)));
        switch (win.draw) {
            .rack => _ = view_rack.draw(ui, app, w, h, menu_open),
            .synth => _ = view_synth.draw(ui, app, w, h),
            .mixer => _ = view_mixer.draw(ui, app, w, h),
            .effect => _ = view_effect.draw(ui, app, w, h),
            .drumkit => _ = view_drumkit.draw(ui, app, w, h),
        }
        ui.endLayer();
    }
}

fn drawToolbar(ui: *Ui, app: *App, w: i32) void {
    ui.renderer.fillRect(0, 0, w, util.toolbar_h, ui.theme.toolbar);
    ui.renderer.hline(0, util.toolbar_h - 1, w, ui.theme.panel_border);

    var x: i32 = 8;
    const by: i32 = 7;
    const bh: i32 = 26;
    // “文件”按钮位置（菜单展开时用于判断点击是否在按钮上）
    var file_menu_x: i32 = 8;
    var file_menu_w: i32 = 140;

    // 菜单：“文件”带下拉（打开/保存/另存为）；“乐器”开关通道机架
    // 注：下拉项的**动作**由 main 循环处理（需要 window/io）；本函数只置状态
    // 帧首：清“刚打开”标记（文件菜单；与机架下拉同一模式——必须逐帧做，
    // 否则“点按钮关闭”失效，且用 `ui.button` 的点击会被模态层屏蔽）
    util.menuFrameBegin(&app.file_menu_just_opened);
    const menus = [_][]const u8{ "文件", "选项", "视图", "乐器", "混音台" };
    for (menus, 0..) |m, i| {
        const mw: i32 = @as(i32, @intFromFloat(ui.font.measure(m))) + 16;
        const active = (i == 3 and app.rack.open) or (i == 0 and app.file_menu_open) or (i == 4 and app.mixer_win.open);
        if (active) {
            if (ui.buttonEx(100 + @as(u64, i), m, x, by, mw, bh, true)) {
                if (i == 3) app.rack.open = false else if (i == 0) app.file_menu_open = false else if (i == 4) app.mixer_win.open = false;
            }
        } else if (ui.button(100 + @as(u64, i), m, x, by, mw, bh)) {
            if (i == 3) {
                app.rack.open = true;
                app.bringToFront(&app.rack.z); // 刚打开：置顶（否则可能被别的窗口盖住）
            } else if (i == 0) {
                app.file_menu_open = !app.file_menu_open;
                // 刚打开：供 drawFileMenu 区分“打开那一下”（不立即关）
                if (app.file_menu_open) app.file_menu_just_opened = true;
            } else if (i == 4) {
                app.mixer_win.open = !app.mixer_win.open;
                // 刚打开：置顶（同上；关闭时不动 z）
                if (app.mixer_win.open) app.bringToFront(&app.mixer_win.z);
            }
        }
        if (i == 0) {
            file_menu_x = x;
            file_menu_w = @max(mw + 70, 140);
        }
        x += mw + 2;
    }
    app.file_menu_x = file_menu_x;
    app.file_menu_w = file_menu_w;

    // 视图切换：播放列表 / 钢琴卷帘（两段式，像 SONG/PAT）
    {
        const piano_open = app.piano.pattern != null;
        if (ui.toggle2(160, "播放列表", "钢琴卷帘", !piano_open, x, by, 150, bh)) {
            if (piano_open) {
                // → 播放列表（同时释音，防卡音）
                app.closePiano();
                if (ui.active_id == 6000) ui.active_id = 0;
            } else {
                // → 钢琴卷帘（编辑当前选中的样式）
                app.openPiano(app.sel.pattern);
            }
        }
        x += 158;
    }

    // 分隔
    x += 6;
    ui.renderer.vline(x, 6, util.toolbar_h - 12, ui.theme.panel_border);
    x += 10;

    // SONG / PAT 切换（播放全曲 or 当前样式）——播放中切换 → 重新调度
    if (ui.toggle2(150, "SONG", "PAT", app.sel.song_mode, x, by, 92, bh)) {
        app.sel.song_mode = !app.sel.song_mode;
        if (app.playing) app.jumpPlaybackCursor(app.playback.cursorStep(app.sel.song_mode));
    }
    x += 100;

    // 分隔
    ui.renderer.vline(x - 6, 6, util.toolbar_h - 12, ui.theme.panel_border);

    // 传输控制（图标**自绘**：中文字体常缺几何符号字形（▶ U+25B6 等），
    // 缺字时退回 .notdef 方块——实测“播放按钮变竖长方形”；
    // 像素级画形状则任何字体下外观一致）
    if (ui.iconButton(200, if (app.playing) .pause else .play, x, by, 36, bh, app.playing, ui.theme.accent)) {
        app.playing = !app.playing;
        if (app.playing) {
            const from = if (app.sel.song_mode) app.playback.song_step else app.playback.piano_step;
            app.playback.start_frame = app.params.frames_played.load(.monotonic);
            app.playback.start_step = from;
            app.params.start_frame.store(app.playback.start_frame, .monotonic);
            app.params.start_step.store(from, .monotonic);
            app.params.playing.store(true, .monotonic);
            sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, from);
            app.params.sched_gen.store(app.scheduler.gen, .monotonic);
        } else {
            app.params.playing.store(false, .monotonic);
        }
    }
    x += 40;
    if (ui.iconButton(201, .stop, x, by, 36, bh, false, ui.theme.accent)) {
        // 停止：停声 + 作废调度事件 + 游标归位到第一小节
        app.stopPlayback();
        if (app.sel.song_mode) {
            app.playback.song_step = 0;
        } else {
            app.playback.piano_step = 0;
        }
        app.playback.start_step = 0;
        app.params.start_step.store(0, .monotonic);
    }
    x += 40;
    // 录制开关：当前只切换“武装”状态（录音写入还没接）——
    // 激活时红底白点（与播放的蓝底拉开区分）
    if (ui.iconButton(202, .record, x, by, 36, bh, app.record_armed, ui.theme.record)) {
        app.record_armed = !app.record_armed;
    }
    x += 46;

    // BPM（按住上下拖：上滑增加 / 下滑减小；拖动时光标隐藏并冻结）
    // 灵敏度：8px/单位（再降一半——拖 8px 变 1 BPM）
    // 高度/位置与前面的菜单、SONG/PAT、传输按钮**同排对齐**（by/bh）
    ui.labelCentered("BPM", x, by, bh, ui.theme.text_dim);
    x += @as(i32, @intFromFloat(ui.font.measure("BPM"))) + 8;
    {
        const old_bpm = app.bpm;
        _ = ui.dragNumber(350, x, by, 56, bh, &app.bpm, 20, 999, 8);
        if (app.bpm != old_bpm) app.history_pending = "调整 BPM"; // 松手时 coalesce 提交
        x += 62;
    }

    // 拍号（分子/分母都可推；分母为 2 的幂：指数式推子——拖 1 单位 = 翻倍）
    // 灵敏度：分子 12px/单位（范围 1..32）、分母 12px/档（指数 0..4）
    {
        const num_w: i32 = 30;
        const den_w: i32 = 30;
        const changed_num = ui.dragNumber(351, x, by, num_w, bh, &app.time_num, 1, 32, 12);
        ui.labelCentered("/", x + num_w + 5, by, bh, ui.theme.text_dim);
        // 指数模式：拖动值 = log2(分母)（1..4 → 2/4/8/16）；不会因吸附写回而振荡
        const changed_den = ui.dragNumberEx(352, x + num_w + 15, by, den_w, bh, &app.time_den, 0, 4, 12, 1, null);
        if (changed_num or changed_den) {
            app.steps_per_bar = model.stepsPerBarFor(app.time_num, app.time_den);
            app.history_pending = "调整拍号"; // 松手时 coalesce 提交
            // 拍号变更 → 内容解释变了：播放中重置调度与传输
            if (app.playing) app.jumpPlaybackCursor(app.playback.cursorStep(app.sel.song_mode));
        }
        x += num_w + den_w + 24;
    }

    // 时间显示（占位：后续接真实播放位置）
    ui.labelCentered("00:00:00", x, by, bh, ui.theme.text_dim);

    // 右侧：主音量推子（保持原有 20px 高——推子把手随 h 全高绘制，
    // 拉成 26px 会显得过粗；其中心与同排控件一致，标签仍居中）
    const vol_w: i32 = 120;
    const vol_x = w - vol_w - 16;
    ui.labelCentered("音量", vol_x - 44, by, bh, ui.theme.text_dim);
    if (ui.slider(300, &app.volume, vol_x, by + 3, vol_w, 20)) {
        app.params.volume.store(app.volume, .monotonic);
    }
    app.params.playing.store(app.playing, .monotonic);
}

// ── 保存 / 加载 ──

/// 绘制并处理“文件”下拉菜单（在 UI 之后调用 = 视觉最上层）。
/// 用**直接坐标**判定命中（不受 UI 层屏蔽影响）。
/// 绘制并处理“文件”下拉菜单（在 `endFrame` **之前**调用：需要未清的 mouse_pressed）。
/// 命中项只登记 `pending_file_action`（真正的对话框在帧末执行——见主循环）。
fn drawFileMenu(ui: *Ui, app: *App) void {
    const items = [_]struct { label: []const u8, shortcut: []const u8 }{
        .{ .label = "打开...", .shortcut = "Ctrl+O" },
        .{ .label = "保存", .shortcut = "Ctrl+S" },
        .{ .label = "另存为...", .shortcut = "Ctrl+Shift+S" },
        .{ .label = "导入 MIDI...", .shortcut = "" },
        .{ .label = "导出 MIDI...", .shortcut = "" },
    };
    const item_h: i32 = 22;
    const menu_x = app.file_menu_x;
    const menu_w = app.file_menu_w;
    const menu_y = util.toolbar_h;
    const menu_h: i32 = @intCast(items.len * @as(usize, @intCast(item_h)) + 4);

    ui.renderer.fillRect(menu_x, menu_y, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(menu_x, menu_y, menu_w, menu_h, ui.theme.accent);

    var activated: ?usize = null;
    for (items, 0..) |it, ii| {
        const iy = menu_y + 2 + @as(i32, @intCast(ii)) * item_h;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, menu_x + 1, iy, menu_w - 2, item_h);
        if (hovered) {
            ui.renderer.fillRect(menu_x + 1, iy, menu_w - 2, item_h, ui.theme.item_hover);
            ui.cursor = .arrow;
        }
        ui.label(it.label, menu_x + 8, iy + 3, ui.theme.text);
        if (it.shortcut.len > 0) {
            const sw: i32 = @intFromFloat(ui.font.measure(it.shortcut));
            ui.label(it.shortcut, menu_x + menu_w - sw - 8, iy + 3, ui.theme.text_dim);
        }
        if (hovered and ui.mouse_pressed) activated = ii;
    }

    // 点击外部关闭：落在“文件”按钮上时——
    // - 若是**打开菜单的那一帧**（just_opened）：那是打开动作本身（按钮已 toggle），
    //   不关（否则“开了又关”）；
    // - 否则：菜单展开后按钮被模态层屏蔽（`ui.button` 收不到点击），
    //   必须由这里响应“再点按钮 = 关闭”——否则只能靠 Esc/点别处。
    if (ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, menu_x, menu_y, menu_w, menu_h)) {
        const on_button = util.inRect(ui.mouse_x, ui.mouse_y, menu_x, 7, menu_w, 26);
        if (!on_button or !app.file_menu_just_opened) app.file_menu_open = false;
    }

    if (activated) |ai| {
        app.file_menu_open = false;
        app.pending_file_action = switch (ai) {
            0 => .open,
            1 => .save,
            2 => .save_as,
            3 => .import_midi,
            4 => .export_midi,
            else => null,
        };
    }
}

/// 保存工程。
/// - `force_dialog` = true（另存为）：总是弹对话框选路径；
/// - 否则：有 `project_path` 直接存；无路径（新工程首次保存）→ 弹对话框；
/// - 用户在对话框中取消 → 不保存（不是错误）。
/// 成功后清除脏标记并刷新标题。
fn saveProject(app: *App, win: *window.Window, io: std.Io, force_dialog: bool) void {
    // 决定目标路径
    var chosen: ?[]u8 = null;
    defer if (chosen) |p| app.allocator.free(p);

    const path: []const u8 = blk: {
        if (!force_dialog) {
            if (app.project_path) |p| break :blk p;
        }
        // 需要对话框（首次保存 / 另存为 / 无对话框平台回退到默认名）
        const default_name = if (force_dialog)
            (if (app.project_path) |p| std.fs.path.basename(p) else persist.default_file_name)
        else
            persist.default_file_name;
        const picked = filedialog.save(app.allocator, win.hwnd, "保存工程", default_name, filedialog.project_filter) catch |e| {
            app.setToastWith("保存失败：对话框出错（{s}）", .{@errorName(e)});
            return;
        };
        if (picked) |p| {
            chosen = p;
            break :blk p;
        }
        // 取消（或平台不支持对话框）
        if (filedialog.supported()) {
            app.setToast("已取消保存");
            return;
        }
        break :blk persist.default_file_name; // 无对话框平台的回退
    };

    // 导出 → 序列化 → 写文件 → 释放
    const project = app.exportProject() catch |e| {
        app.setToastWith("保存失败：导出失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.freeProject(project);

    const json = persist.toJson(app.allocator, project) catch |e| {
        app.setToastWith("保存失败：序列化失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(json);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch |e| {
        app.setToastWith("保存失败：写入失败（{s}）", .{@errorName(e)});
        return;
    };

    // 记住路径（首次保存 / 另存为后）——**安全设置**：
    // 普通保存时 path 正指向旧的 project_path，先 free 再读会 use-after-free
    app.setProjectPath(path);
    app.markSaved();
    app.setToastWith("已保存：{s}", .{path});
}

/// 弹对话框选文件并加载（替换当前工程）。取消/失败不影响当前工程。
/// 弹对话框选文件并加载（替换当前工程）。
/// **脏检查**：当前工程有未保存修改时，先弹自绘确认框（保存/不保存/取消），
/// 用户确认后才真正替换（避免无提示丢修改——实测漏洞）。
fn openProjectWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    const picked = filedialog.open(app.allocator, win.hwnd, "打开工程", filedialog.project_filter) catch |e| {
        app.setToastWith("打开失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消打开");
        return;
    };
    defer app.allocator.free(path);

    // 脏 → 先确认（确认框文案与退出场景共用）
    if (app.dirty) {
        app.setPendingOpen(path);
        app.dirty_flow = .confirming;
        app.dirty_intent = .open;
        app.modal = .dirty_confirm;
        app.modal_choice = null;
        return;
    }

    loadProjectFromPath(app, io, path);
}

/// 从指定路径加载并替换当前工程（失败时保留当前工程不变）
fn loadProjectFromPath(app: *App, io: std.Io, path: []const u8) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, app.allocator, .unlimited) catch |e| {
        app.setToastWith("打开失败：读取失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(data);

    const parsed = persist.fromJson(app.allocator, data) catch |e| {
        app.setToastWith("打开失败：解析失败（{s}）", .{@errorName(e)});
        return;
    };
    defer parsed.deinit();

    app.importProject(parsed.value);

    app.setProjectPath(path);
    app.resetHistory("打开工程"); // 打开 = 新基线（旧历史作废）
    app.markSaved();
    app.setToastWith("已打开：{s}", .{path});
}

/// MIDI 过滤器（描述\0通配\0…；与 project_filter 同格式）
pub const midi_filter = "MIDI 文件 (*.mid;*.midi)\x00*.mid;*.midi\x00所有文件 (*.*)\x00*.*\x00";

/// 导入 MIDI：选文件 → 解析 → 每个用到的通道建一个乐器 + 音符进新样式。
/// 导入**不替换**当前工程（追加）；有脏修改时提示先保存？——不拦截：
/// 导入是增量操作，不会丢数据。
fn importMidiWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    const picked = filedialog.open(app.allocator, win.hwnd, "导入 MIDI", midi_filter) catch |e| {
        app.setToastWith("导入失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消导入");
        return;
    };
    defer app.allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, app.allocator, .unlimited) catch |e| {
        app.setToastWith("导入失败：读取失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(data);

    var parsed = midi.parse(app.allocator, data) catch |e| {
        app.setToastWith("导入失败：解析失败（{s}）", .{@errorName(e)});
        return;
    };
    defer parsed.deinit(app.allocator);

    const r = app.importMidi(&parsed) catch |e| {
        app.setToastWith("导入失败：{s}", .{@errorName(e)});
        return;
    };
    app.commitHistory("导入 MIDI"); // 一次性提交（导入是原子操作）

    if (r.skipped > 0) {
        app.setToastWith("已导入 {d} 个音符（{d} 个乐器，跳过 {d}）；样式 {d}", .{ r.notes, r.instruments, r.skipped, r.pattern + 1 });
    } else {
        app.setToastWith("已导入 {d} 个音符（{d} 个乐器）；样式 {d}", .{ r.notes, r.instruments, r.pattern + 1 });
    }
}

/// 导出 MIDI：全部片段按全局时间展开 → 写出文件。
fn exportMidiWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    const default_name = "song.mid";
    const picked = filedialog.save(app.allocator, win.hwnd, "导出 MIDI", default_name, midi_filter) catch |e| {
        app.setToastWith("导出失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消导出");
        return;
    };
    defer app.allocator.free(path);

    const notes = app.exportMidiNotes(app.allocator) catch |e| {
        app.setToastWith("导出失败：收集音符失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(notes);

    const bytes = midi.write(app.allocator, .{
        .bpm = app.bpm,
        .time_num = @intCast(std.math.clamp(app.time_num, 1, 255)),
        .time_den = @intCast(std.math.clamp(app.time_den, 1, 64)),
        .notes = notes,
    }) catch |e| {
        app.setToastWith("导出失败：生成失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |e| {
        app.setToastWith("导出失败：写入失败（{s}）", .{@errorName(e)});
        return;
    };
    app.setToastWith("已导出 {d} 个音符：{s}", .{ notes.len, path });
}

// ── 模态确认框（自绘）──

/// 绘制退出确认框并处理鼠标点击（在 `endFrame` 前调用）。
/// 用户选择写入 `app.modal_choice`，由主循环的退出流程消费。
/// 不用系统 MessageBox：系统弹窗会把鼠标吸到默认按钮上（实测体验差，
/// 且受系统设置 `SnapToDefaultButton` 影响）。
fn drawModal(ui: *Ui, app: *App) void {
    const kind = app.modal orelse return;
    const w = @as(i32, @intCast(ui.renderer.fb.width));
    const h = @as(i32, @intCast(ui.renderer.fb.height));

    // 半透明遮罩（提亮对比）
    ui.renderer.fillRect(0, 0, w, h, (@as(u32, 110) << 24) | 0x000000);

    switch (kind) {
        .dirty_confirm => drawDirtyConfirm(ui, app, w, h),
        .preset_overwrite => drawPresetOverwrite(ui, app, w, h),
        .preset_delete => drawPresetDelete(ui, app, w, h),
    }
}

/// 脏确认框（保存/不保存/取消）——退出或打开其它工程前
fn drawDirtyConfirm(ui: *Ui, app: *App, w: i32, h: i32) void {
    // 文案随场景变化（退出 vs 打开其他工程）
    const line2 = if (app.dirty_intent == .open) "是否保存后再打开其他工程？" else "是否保存后再退出？";
    const line1 = "当前工程有未保存的修改。";
    const tw1: i32 = @intFromFloat(ui.font.measure(line1));
    const tw2: i32 = @intFromFloat(ui.font.measure(line2));
    const text_w = @max(tw1, tw2);
    const btn_w: i32 = 84;
    const gap: i32 = 10;
    const dlg_w = @max(text_w + 48, btn_w * 3 + gap * 2 + 32);
    const dlg_h: i32 = 110;
    const dx = @divTrunc(w - dlg_w, 2);
    const dy = @divTrunc(h - dlg_h, 2);

    // 对话框背景 + 边框
    ui.renderer.fillRect(dx + 4, dy + 4, dlg_w, dlg_h, r_mod.rgb(12, 13, 16)); // 阴影
    ui.renderer.fillRect(dx, dy, dlg_w, dlg_h, ui.theme.panel);
    ui.renderer.strokeRect(dx, dy, dlg_w, dlg_h, ui.theme.accent);

    // 文字（两行）
    ui.label(line1, dx + @divTrunc(dlg_w - tw1, 2), dy + 18, ui.theme.text);
    ui.label(line2, dx + @divTrunc(dlg_w - tw2, 2), dy + 40, ui.theme.text_dim);

    // 按钮：保存 / 不保存 / 取消
    const labels = [_][]const u8{ "保存", "不保存", "取消" };
    const choices = [_]QuitChoice{ .save, .discard, .cancel };
    drawModalButtons(ui, app, dx, dy, dlg_w, dlg_h, &labels, &choices, 0, 0);
}

/// 预设覆写确认框（覆写/取消）：预填名 + 回车直达；确认后重排保存（overwrite）
fn drawPresetOverwrite(ui: *Ui, app: *App, w: i32, h: i32) void {
    const req = app.overwrite_req orelse return;
    const name = req.name[0..req.name_len];
    var l1: [preset_mod.max_name_len + 32]u8 = undefined;
    const line1 = std.fmt.bufPrint(&l1, "预设「{s}」已存在。", .{name}) catch "预设已存在。";
    const line2 = "覆写后其它已加载它的乐器不受影响（需手动重新加载）。";
    const tw1: i32 = @intFromFloat(ui.font.measure(line1));
    const tw2: i32 = @intFromFloat(ui.font.measure(line2));
    const text_w = @max(tw1, tw2);
    const btn_w: i32 = 84;
    const gap: i32 = 10;
    const dlg_w = @max(text_w + 48, btn_w * 2 + gap + 32);
    const dlg_h: i32 = 110;
    const dx = @divTrunc(w - dlg_w, 2);
    const dy = @divTrunc(h - dlg_h, 2);

    ui.renderer.fillRect(dx + 4, dy + 4, dlg_w, dlg_h, r_mod.rgb(12, 13, 16));
    ui.renderer.fillRect(dx, dy, dlg_w, dlg_h, ui.theme.panel);
    ui.renderer.strokeRect(dx, dy, dlg_w, dlg_h, ui.theme.accent);
    ui.label(line1, dx + @divTrunc(dlg_w - tw1, 2), dy + 18, ui.theme.text);
    ui.label(line2, dx + @divTrunc(dlg_w - tw2, 2), dy + 40, ui.theme.text_dim);

    // 按钮：覆写（主按钮 = .save）/ 取消
    const labels = [_][]const u8{ "覆写", "取消" };
    const choices = [_]QuitChoice{ .save, .cancel };
    drawModalButtons(ui, app, dx, dy, dlg_w, dlg_h, &labels, &choices, 0, 0);
}

/// 预设删除确认框（删除/取消）：破坏性主按钮用红色；确认后重排删除。
/// 文案说明副本语义：已加载它的乐器不受影响。
fn drawPresetDelete(ui: *Ui, app: *App, w: i32, h: i32) void {
    const req = app.delete_req orelse return;
    const name = req.name[0..req.name_len];
    var l1: [preset_mod.max_name_len + 32]u8 = undefined;
    const line1 = std.fmt.bufPrint(&l1, "删除预设「{s}」？", .{name}) catch "删除预设？";
    const line2 = "已加载它的乐器不受影响；文件删除后不可恢复。";
    const tw1: i32 = @intFromFloat(ui.font.measure(line1));
    const tw2: i32 = @intFromFloat(ui.font.measure(line2));
    const text_w = @max(tw1, tw2);
    const btn_w: i32 = 84;
    const gap: i32 = 10;
    const dlg_w = @max(text_w + 48, btn_w * 2 + gap + 32);
    const dlg_h: i32 = 110;
    const dx = @divTrunc(w - dlg_w, 2);
    const dy = @divTrunc(h - dlg_h, 2);

    ui.renderer.fillRect(dx + 4, dy + 4, dlg_w, dlg_h, r_mod.rgb(12, 13, 16));
    ui.renderer.fillRect(dx, dy, dlg_w, dlg_h, ui.theme.panel);
    ui.renderer.strokeRect(dx, dy, dlg_w, dlg_h, ui.theme.accent);
    ui.label(line1, dx + @divTrunc(dlg_w - tw1, 2), dy + 18, ui.theme.text);
    ui.label(line2, dx + @divTrunc(dlg_w - tw2, 2), dy + 40, ui.theme.text_dim);

    const labels = [_][]const u8{ "删除", "取消" };
    const choices = [_]QuitChoice{ .save, .cancel };
    drawModalButtons(ui, app, dx, dy, dlg_w, dlg_h, &labels, &choices, 0, 1); // 删除为主（红色）
}

/// 对话框底部按钮排（居中一行；`primary` = 哪个用强调色主按钮样式；
/// `danger` = 主按钮用危险色）
fn drawModalButtons(
    ui: *Ui,
    app: *App,
    dx: i32,
    dy: i32,
    dlg_w: i32,
    dlg_h: i32,
    labels: []const []const u8,
    choices: []const QuitChoice,
    primary: usize,
    danger: u1,
) void {
    const btn_w: i32 = 84;
    const btn_h: i32 = 26;
    const gap: i32 = 10;
    const total_w = btn_w * @as(i32, @intCast(labels.len)) + gap * (@as(i32, @intCast(labels.len)) - 1);
    const bx0 = dx + @divTrunc(dlg_w - total_w, 2);
    const by = dy + dlg_h - btn_h - 16;
    for (labels, 0..) |label, bi| {
        const bx = bx0 + @as(i32, @intCast(bi)) * (btn_w + gap);
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx, by, btn_w, btn_h);
        const is_primary = (bi == primary); // 主按钮（默认动作）
        const main_col = if (danger == 1) ui.theme.danger else ui.theme.accent;
        const bg = if (hovered)
            (if (is_primary) (if (danger == 1) r_mod.rgb(190, 80, 80) else r_mod.rgb(70, 130, 200)) else ui.theme.item_hover)
        else if (is_primary)
            main_col
        else
            ui.theme.slider_track;
        ui.renderer.fillRect(bx, by, btn_w, btn_h, bg);
        ui.renderer.strokeRect(bx, by, btn_w, btn_h, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure(label));
        ui.labelCentered(label, bx + @divTrunc(btn_w - tw, 2), by, btn_h, ui.theme.text);
        if (hovered and ui.mouse_pressed) app.modal_choice = choices[bi];
    }
}

// ── 字体 ──

fn loadFont(allocator: std.mem.Allocator, io: std.Io) !Font {
    const candidates = [_][]const u8{
        "fonts/ui.ttf",
        "C:\\Windows\\Fonts\\msyh.ttc",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\consola.ttf",
    };
    for (candidates) |p| {
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return Font.initFromFile(allocator, io, p, 16);
    }
    return error.FontNotFound;
}

test {
    _ = @import("window.zig");
    _ = @import("render.zig");
    _ = @import("font.zig");
    _ = @import("audio.zig");
    _ = @import("synth.zig");
    _ = @import("model.zig");
    _ = @import("persist.zig");
    _ = @import("preset.zig");
    _ = @import("midi.zig");
    _ = @import("app.zig");
    _ = @import("view_util.zig");
    _ = @import("view_playlist.zig");
    _ = @import("view_pianoroll.zig");
    _ = @import("view_note_lane.zig");
    _ = @import("view_rack.zig");
    _ = @import("view_synth.zig");
    _ = @import("view_mixer.zig");
    _ = @import("view_panels.zig");
    _ = @import("ui_test.zig");
}
