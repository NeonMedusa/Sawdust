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
const MoveReq = @import("app.zig").MoveReq;
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
const view_help = @import("view_help.zig");
const view_settings = @import("view_settings.zig");
const view_plugins = @import("view_plugins.zig");
const plugin_db = @import("plugin_db.zig");
const app_mod = @import("app.zig");
const fx = @import("effects.zig");
const vst_host = @import("vst_host.zig");
const eq = @import("eq.zig");
const audio = @import("audio.zig");
const vstscan = @import("vstscan.zig"); // 插件扫描工具（同二进制自举入口 `--vst-scan`）

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    // 隐藏 CLI 模式（**同二进制自举**）：`Sawdust.exe --vst-scan …` = 原 vstscan 工具。
    // 插件扫描据此以独立进程运行**自身**（坏插件崩溃隔离在子进程；主程序零污染）。
    // 必须在任何 GUI/音频初始化**之前**——否则 worker 进程会拉起窗口。
    if (hasScanArg(init)) return vstscan.cliMain(init);

    var win: window.Window = undefined;
    try win.init(allocator, "Sawdust — Simple Audio Workstation", 1280, 760);
    defer win.deinit();

    var font = loadFont(allocator, io) catch |e| {
        std.debug.print("字体加载失败（{s}）：请把任意 .ttf 放到 fonts/ 目录\n", .{@errorName(e)});
        return 1;
    };
    defer font.deinit();

    var app = App{ .allocator = allocator };
    app.initAudioCapacity() catch {}; // 音频容量数组（池化：乐器/通道/效果槽动态容量）
    app.main_hwnd = win.hwnd;
    app.scheduler.muted = &app.track_muted; // 静音轨道集合挂载（SONG 调度时过滤）
    defer app.clips.deinit(allocator);
    defer app.notes.deinit(allocator);
    defer app.deinitAll();
    app.resetPatterns(1); // 空工程基线：只有样式 1（不再铺 6 个演示样式）；轨道行跨度自动推导
    app.resetMixerChannels(@import("app.zig").default_mixer_channels); // 默认调音台通道（主通道 + 通道#1）
    // 数据目录（预设库）+ 首次扫描（IO 统一在帧末 pending 处理）
    {
        var edir_buf: [1024]u8 = undefined;
        const edir = exeDir(allocator, &edir_buf);
        var root_buf: [512]u8 = undefined;
        if (preset_mod.resolveDataRoot(io, edir, &root_buf)) |root| app.setDataRoot(root);
        app.pending_preset = .scan;
    }
    // 插件管理数据（配置 + 缓存；**只读加载，从不自动扫描**）
    if (pluginDataRoot(&app)) |pdr| {
        app.plugin_cfg = plugin_db.Config.load(io, allocator, pdr);
        app.plugin_cache = plugin_db.Cache.load(io, allocator, pdr);
    }
    defer app.deinitPluginDb();
    loadSettings(&app, io); // 设置（settings.json；缺失 = 默认）+ 启动打开上次工程
    // 初始片段（空基线）：样式 1 放在 Track 1 的最左边（长度 = 样式有效长度）
    app.addClip(.{
        .track = 0,
        .start = 0,
        .len = app.patternEffectiveLen(0),
        .pattern = 0,
    });
    // 初始乐器：1 个减法合成器（**必须在 engine.init 之前**——
    // 音频回调启动后会解引用参数/队列指针）
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态"); // 空基线 = 历史基线（脏标记由历史派生）
    app.params.events = &app.events;
    app.params.sched_events = &app.sched_events;

    app.engine.init(&app.params, allocator) catch |e| {
        std.debug.print("音频初始化失败（{s}）：UI 仍可运行\n", .{@errorName(e)});
    };
    defer app.engine.deinit();
    app.engine.params = &app.params;

    var ui_input = InputState{};
    var ui = Ui.init(r_mod.Renderer.init(&win.fb), &font);

    // 帧率上限：默认 120fps（帧预算 8.33ms；现由设置窗口可调，见 `App.fps_limit`）。
    // 历史：原为固定 `sleep(16ms)`（名义 60fps），但 Windows 默认计时器
    // 粒度 ≈ 15.6ms → 实测 sleep(16ms) 睡成 ~26ms，加上渲染耗时实际仅
    // ~30 多帧，表现为“UI 不流畅/操作滞后”。修法：
    //   ① window.init 里 timeBeginPeriod(1) 提高计时器精度；
    //   ② 改为**帧预算**：睡到“帧开始 + 预算”截止，而非固定睡眠
    //      （固定睡眠会与渲染耗时叠加，帧率随内容复杂度浮动）。

    // 帧间隔基准（上一帧起点）——dt = 两次循环起点之差（**含上一帧的绘制与
    // 帧预算睡眠**；旧实现测“绘制前”，亚毫秒被夹成 1ms 下限 → 一切按 dt 的
    // 动画/倒计时慢 ~8 倍：跟随滑动滞后、宽限倒计时超长（实测根因））
    var prev_frame_start_ns: i64 = 0;

    while (true) {
        // 帧率上限：取设置值（30..240fps；帧预算 = 1e9 / fps——改设置即时生效）
        const frame_budget_ns: i64 = @divTrunc(1_000_000_000, @as(i64, std.math.clamp(app.fps_limit, 30, 240)));
        const frame_start_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        defer {
            // 5) 帧预算：睡完本帧剩余时间（渲染耗时已扣掉）
            const now_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
            const remain_ns = frame_budget_ns - (now_ns - frame_start_ns);
            if (remain_ns > 0) {
                std.Io.sleep(io, .fromNanoseconds(remain_ns), .awake) catch {};
            }
        }
        // 帧间隔（帧率无关动画/倒计时用）：**完整帧间隔**（上一帧的绘制+睡眠都计入）
        const frame_dt_raw: i64 = if (prev_frame_start_ns == 0) frame_budget_ns else frame_start_ns - prev_frame_start_ns;
        prev_frame_start_ns = frame_start_ns;
        app.frame_dt_ns = std.math.clamp(frame_dt_raw, 1_000_000, 100_000_000);
        app.tickToast(app.frame_dt_ns); // 状态栏提示递减（按实际流逝）
        app.tickCursorSmooth(); // 游标平滑（渲染帧推进；音频缓冲量化不显——实测“游标还是抖”的根因）
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
                            // 取消：放弃目标动作（清掉待打开的工程 / 待新建意图）
                            app.dirty_flow = .none;
                            app.clearPendingOpen();
                            app.dirty_intent = null;
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
                        // 执行目标动作：打开走帧末（需路径/对话框）；新建直接执行
                        // （脏已由本流程处理，不能再走带确认的帧末 `.new` 入口）
                        if (app.dirty_intent == .new) {
                            newProject(&app);
                        } else {
                            app.pending_file_action = .open;
                        }
                        app.dirty_intent = null;
                    } else {
                        // 保存失败 / 用户在保存对话框里取消 → 放弃目标动作
                        // （等同确认框里的“取消”：**也要清掉意图**——否则 206 区会
                        // 拿残留的 `.new` 意图直接执行新建，实测 bug：取消保存却新建了）
                        app.clearPendingOpen();
                        app.dirty_intent = null;
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
        // 旧档升级确认（v1–v3 → v5；Enter = 确认、Esc = 取消）
        if (app.modal == .save_upgrade) {
            if (app.modal_choice) |choice| {
                app.modal = null;
                app.modal_choice = null;
                if (choice == .save) {
                    performUpgrade(&app, io);
                } else {
                    app.clearPendingUpgrade(); // 否 = 不打开（原文件保持不动）
                }
            }
        }
        // 样式/轨道清空确认（非空删除/清空；Enter = 确认、Esc = 取消）
        if (app.modal == .pattern_delete or app.modal == .track_clear or app.modal == .track_delete) {
            if (app.modal_choice) |choice| {
                app.modal = null;
                app.modal_choice = null;
                if (choice == .save) { // 确认删除
                    if (app.struct_del_req) |req| {
                        switch (req) {
                            .pattern => |pi| {
                                if (app.removePattern(pi)) app.commitHistory("删除样式");
                            },
                            .track => |ti| {
                                if (app.clearTrackData(ti) > 0) {
                                    app.commitHistory("清空轨道");
                                }
                            },
                            .track_row => |ti| {
                                app.removeTrackRow(ti);
                                app.commitHistory("删除轨道");
                            },
                        }
                    }
                }
                app.struct_del_req = null;
            }
        }

        // 脏确认已结束（且意图为打开）：执行待定的打开
        if (app.dirty_flow == .none and app.pending_open_path != null and app.pending_file_action == null) {
            app.pending_file_action = .open;
            app.dirty_intent = null;
        }
        // 脏确认已结束（且意图为新建）：直接执行——**不再走 `.new` 帧末分支**
        // （那里带脏检查；discard 后仍脏，会二次弹窗死循环）
        if (app.dirty_flow == .none and app.dirty_intent == .new and app.pending_file_action == null) {
            newProject(&app);
            app.dirty_intent = null;
        }

        ui_input.mouse_pressed = false;
        ui_input.mouse_released = false;
        ui_input.mouse_right_pressed = false;
        ui_input.mouse_middle_pressed = false;
        ui_input.mouse_double = false;
        ui_input.wheel = 0;
        ui_input.wheel_ctrl = false;
        ui_input.wheel_alt = false;
        ui_input.wheel_shift = false;

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
                        .middle => {
                            ui_input.mouse_middle_down = true;
                            ui_input.mouse_middle_pressed = true;
                        },
                    }
                },
                .mouse_up => |m| {
                    switch (m.button) {
                        .left => {
                            ui_input.mouse_down = false;
                            ui_input.mouse_released = true;
                        },
                        .right => ui_input.mouse_right_down = false,
                        .middle => ui_input.mouse_middle_down = false,
                    }
                },
                .mouse_wheel => |m| {
                    ui_input.wheel += m.delta;
                    ui_input.wheel_ctrl = m.ctrl;
                    ui_input.wheel_alt = m.alt;
                    ui_input.wheel_shift = m.shift;
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                },
                .key_down => |k| {
                    // 导出进行中：Esc = 取消导出；其余键盘吞掉（模态）
                    if (app.export_wav != null) {
                        if (k.code == 0x1B) app.exportWavCancel();
                        continue;
                    }
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
        } else if (app.help_win.open) {
            app.help_win.open = false;
        } else if (app.settings_win.open) {
            app.settings_win.open = false;
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
                            app.markGenSoft(false); // 硬切换（起播）：照旧释放（无残留声部）
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
                    // Shift+方向键：移动选中音符（上下半音 / 左右当前网格）；
                    // Ctrl+方向键：八度 / 一小节；两者同按 → Ctrl 优先。
                    // 仅钢琴窗（有当前样式）有效；钳制在 App.moveSelectedNotes 侧。
                    if (app.piano.pattern != null and (k.ctrl or k.shift) and
                        (k.code == 0x25 or k.code == 0x26 or k.code == 0x27 or k.code == 0x28))
                    {
                        const big = k.ctrl;
                        var mv = app.pending_move orelse MoveReq{};
                        const grid: i32 = @max(1, model.snapSteps(app.piano.snap));
                        mv.exact = mv.exact or big; // Ctrl 粗移 = 全有或全无（见 App.nudgeSelectedNotesExact）
                        switch (k.code) {
                            0x26 => mv.d_pitch += if (big) 12 else 1,
                            0x28 => mv.d_pitch -= if (big) 12 else 1,
                            0x25 => mv.d_step -= if (big) app.steps_per_bar else grid,
                            0x27 => mv.d_step += if (big) app.steps_per_bar else grid,
                            else => {},
                        }
                        app.pending_move = mv;
                    }
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
            // 右键：同样吞掉（不让下层弹右键菜单，也不取消输入）；中键同理
            ui_input.mouse_right_pressed = false;
            ui_input.mouse_middle_pressed = false;
        }
        // 同步乐器指针/增益到音频线程（成本极低；删除乐器后自动变 null）
        for (0..app.params.instruments_cap) |i| {
            const has = i < app.instruments.items.len;
            const inst: ?*const model.Instrument = if (has) &app.instruments.items[i] else null;
            const sp: ?*synth.SynthParams = if (has) app.instruments.items[i].synth else null;
            app.params.synth_ptrs[i].store(sp, .monotonic);
            const g: f32 = if (has)
                (if (app.instruments.items[i].muted) 0.0 else app.instruments.items[i].volume)
            else
                0.0;
            app.params.instrument_gain[i].store(g, .monotonic);
            // 乐器声像（0-1）；空槽位 → 0.5（居中，防旧值残留）
            app.params.instrument_pan[i].store(if (has) app.instruments.items[i].pan else 0.5, .monotonic);
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
            // VST3 乐器实例（kind == 2；帧末 syncInstrumentPlugins 惰性加载/发布）
            app.params.instrument_plugin[i].store(if (inst) |it| it.plugin else null, .monotonic);
            // 鼓组池惰性分配 / 清理挂起（池随乐器生存；删除/装载由帧末回收）
            if (inst) |it| {
                if (it.kit != null) {
                    app.ensureKitPool(i);
                } else if (app.engine.kit_chunks.len > i and app.engine.kit_chunks[i].load(.monotonic) != null) {
                    app.kit_gc_pending = true; // 不再是鼓组 → 帧末释放其池
                }
            }
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
                            // VST3 层：实例指针**先于** kind 发布（音频侧 kind==2 时指针
                            // 必然已是新值——避免“新 kind + 旧退役实例”窗口）
                            app.params.kit_layer_plugin[i][slot].store(if (ly.kind == .vst3) ly.plugin else null, .monotonic);
                            app.params.kit_layer_kind[i][slot].store(@intFromEnum(ly.kind), .monotonic);
                            slot += 1;
                        }
                    }
                }
            }
            // 清掉多余旧槽位（层数减少时防旧指针/旧音高残留；同样指针先清、kind 后清）
            while (slot < audio.kit_max_layers) : (slot += 1) {
                app.params.kit_layer_plugin[i][slot].store(null, .monotonic);
                app.params.kit_layer_kind[i][slot].store(0, .monotonic);
                app.params.kit_layer_pitch[i][slot].store(0, .monotonic);
                app.params.kit_layer_params[i][slot].store(null, .monotonic);
            }
            app.params.kit_layer_count[i].store(@intCast(slot), .monotonic);
        }

        // 同步调音台通道参数（增益/声像/静音/效果链）到音频线程
        const n_mixer: usize = @min(app.mixer_channels_state.items.len, app.params.channels_cap);
        app.params.channel_count.store(@intCast(n_mixer), .monotonic);
        for (0..n_mixer) |ci| {
            const mc = app.mixer_channels_state.items[ci];
            app.params.channel_gain[ci].store(mc.volume, .monotonic);
            app.params.channel_pan[ci].store(mc.pan, .monotonic);
            app.params.channel_muted[ci].store(mc.muted, .monotonic);
            // 效果链长度 + 元数据（kind/enabled/mix）：逐槽对比才写
            const eff_n: usize = @min(mc.effects.items.len, app.params.slots_cap);
            app.params.effect_count[ci].store(@intCast(eff_n), .monotonic);
            var chain_changed = false;
            for (0..eff_n) |slot| {
                const es = &mc.effects.items[slot];
                // 先备好/发布 DSP 状态盒（**指针先到、kind 后到**——防音频线程
                // 在帧间看到“新 kind + 旧/空指针”或反向）
                app.syncFxStateForSlot(ci, slot, es);
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
            // 新效果器参数（混响/延迟/压缩器）：逐槽直接同步（store 廉价）
            for (0..eff_n) |slot| {
                const es = &mc.effects.items[slot];
                for (0..@import("effects.zig").max_params) |pi| {
                    app.params.fxParam(ci, slot, pi).store(es.p[pi], .monotonic);
                }
                // VST3 插件实例指针（null = 未加载/直通）
                app.params.plugin_ptrs[ci][slot].store(es.plugin, .monotonic);
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
            const si: usize = @intCast(std.math.clamp(app.sel.instrument, 0, @as(i32, @intCast(app.params.instruments_cap)) - 1));
            app.sounding.set(app.params.sounding_lo[si].load(.monotonic), app.params.sounding_hi[si].load(.monotonic));
        }

        // 同步 BPM / 每拍步数 到音频线程（序列器换算步→帧用）
        app.params.bpm.store(@intCast(std.math.clamp(app.bpm, 20, 999)), .monotonic);
        app.params.time_num.store(app.time_num, .monotonic);
        app.params.time_den.store(app.time_den, .monotonic);
        app.params.steps_per_beat.store(@intCast(model.stepsPerBeat(app.time_den)), .monotonic);

        ui.renderer = r_mod.Renderer.init(&win.fb);
        ui.mouse_x = ui_input.mouse_x;
        ui.mouse_y = ui_input.mouse_y;
        ui.mouse_down = ui_input.mouse_down;
        ui.mouse_pressed = ui_input.mouse_pressed;
        ui.mouse_released = ui_input.mouse_released;
        ui.mouse_right_pressed = ui_input.mouse_right_pressed;
        ui.mouse_right_down = ui_input.mouse_right_down;
        ui.mouse_middle_pressed = ui_input.mouse_middle_pressed;
        ui.mouse_middle_down = ui_input.mouse_middle_down;
        ui.mouse_double = ui_input.mouse_double;
        ui.wheel = ui_input.wheel;
        // 手势钉值钩子：本帧有鼠标按下 → 可能是新操作起手（拖动/点击）——先钉住
        // 进行中的手势（滚轮/插件侧），保证历史因果顺序
        if (ui_input.mouse_pressed or ui_input.mouse_right_pressed) app.pinPendingGesture();
        ui.wheel_ctrl = ui_input.wheel_ctrl;
        ui.wheel_alt = ui_input.wheel_alt;
        ui.wheel_shift = ui_input.wheel_shift;
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

        ui.beginFrame();
        drawApp(&ui, &app, @intCast(win.fb.width), @intCast(win.fb.height));
        // 文件菜单：在 UI 之后、endFrame **之前**（endFrame 会清 mouse_pressed——
        // 放在之后则菜单永远收不到点击，实测“点菜单没反应”）
        if (app.file_menu_open) drawFileMenu(&ui, &app);
        // 样式右键菜单：同上（浮动窗口之后，否则会被盖住）
        if (app.panels.ctx_pattern != null) view_panels.drawPatternCtxMenu(&ui, &app);
        // 轨道右键菜单（最外层同上——在浮动窗口之后）
        if (app.panels.ctx_track != null) view_playlist.drawTrackCtxMenu(&ui, &app);
        // 预设浏览器（模态；同上——浮动窗口之后）
        if (app.preset_browser.open) view_presets.draw(&ui, &app, @intCast(win.fb.width), @intCast(win.fb.height));
        // 模态确认框（最上层；自绘——避开系统 MessageBox 把鼠标吸到默认按钮）
        if (app.modal != null) {
            // 注：裁切覆盖矩形由各对话框**按自身矩形**登记（不是全屏）——全屏裁掉会让
            // 插件 UI 在弹窗期间“消失”（用户实测反馈）；只按对话框裁，插件保持可见，
            // 输入由 `setEditorEnabled` 闸门拦截（禁用窗点击归父窗口）。
            drawModal(&ui, &app);
        }
        // 导出进度窗（模态；置于最上层——导出期间其余元素均不可操作）
        if (app.export_wav != null) drawExportDialog(&ui, &app, io);
        // 文本输入框（最顶层——跨窗口/菜单，重命名乐器/通道用）
        if (app.text_input.active) {
            const ti = &app.text_input;
            ti.view_off = ui.textFieldSyncOffset(ti.text(), ti.cursor, ti.w, ti.view_off);
            ui.noteOverlayRect(ti.x, ti.y, ti.w, text_input_h); // 遮挡插件子窗口
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

        // 4) 呈现（原生子窗口＝插件编辑器：按**其当前可见区域**裁掉回写——
        //    未遮挡=整矩形跳过（防闪烁）；被弹窗/窗口遮挡的（已 SetWindowRgn 裁掉）
        //    部分照常回写（保证盖在插件上的窗口/弹窗正常覆盖，不破洞）
        collectEditorPresents(&app, &win);
        win.present();

        // 4.1) 历史提交（拖动类操作 **coalesce**：鼠标松开才提交一次——
        // 一次拖动 = 一条历史，而不是每帧一条；左右键都算）
        // 注：滚轮/插件侧改动走“起手提交 + 静置钉值”手势（`touchGesture`）。
        if (app.history_pending) |label| {
            if (!ui_input.mouse_down and !ui_input.mouse_right_down) {
                app.pinPendingGesture(); // 新提交起手：先钉住进行中的手势
                app.commitHistory(label);
                app.history_pending = null;
            }
        }
        app.pollGestureHistory();
        app.pollCapacityReclaim(); // 容量自动回收（删除/装载后滞回缩容；无声时几乎零开销）

        // 4.2) 帧末执行待定的文件操作（对话框在此弹出——不在事件迭代/绘制中，
        // 避免 pushEvent realloc 使迭代中的 events slice 悬空）
        if (app.pending_file_action) |act| {
            app.pending_file_action = null;
            ui.active_id = 0; // 对话框会抢走鼠标：清掉拖动状态
            win.setDragCapture(false);
            switch (act) {
                .new => newProjectWithConfirm(&app), // 新建（空）：脏 → 先走确认
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
                .export_wav => exportWavWithDialog(&app, &win, io),
                .import_json => importJsonWithDialog(&app, &win, io),
                .export_json => exportJsonWithDialog(&app, &win, io),
            }
        }

        // 4.2b) 导出进度推进（分块；完成后自动收尾——见 `App.exportWavFrame`）
        if (app.export_wav != null) app.exportWavFrame(io);

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

    // 4.4) 设置落盘（脏 → 写 settings.json；IO 在帧末）
    if (app.settings_dirty) {
        app.settings_dirty = false;
        saveSettings(&app, io);
    }

    // 4.4b) （已移除：加插件走预设面板；浏览文件走插件管理单文件条目）
    // 4.4b3) 插件管理：文件夹/文件选择 + 扫描管理（帧末；io 在此可用）
    if (app.pending_plugin_folder_pick) {
        app.pending_plugin_folder_pick = false;
        pickPluginFolder(&app, &win);
    }
    if (app.pending_plugin_file_pick) {
        app.pending_plugin_file_pick = false;
        pickPluginFile(&app, &win);
    }
    if (app.pending_scan_start) {
        app.pending_scan_start = false;
        startPluginScan(&app, io);
    }
    if (app.pending_scan_cancel) {
        app.pending_scan_cancel = false;
        cancelPluginScan(&app);
    }
    if (app.pending_relocate_instrument) |ri| {
        app.pending_relocate_instrument = null;
        relocateInstrumentDialog(&app, &win, ri);
    }
    if (app.pending_relocate_effect) |re| {
        app.pending_relocate_effect = null;
        relocateEffectDialog(&app, &win, re.ch, re.slot);
    }
    pollPluginScan(&app, io);
    // 自愈兑底（非扫描期；每 ~2s）：失败槽的**当前路径已消失**且缓存里有同 CID 的
    // 真文件 → 自动重定位（覆盖“打开工程后插件被删/移动”场景——无需先扫描；
    // 存在性门槛防两个坏文件来回跳，存在但加载失败 = 不换，等手动重定位）
    if (!app.plugin_mgr.scanning) {
        app.plugin_mgr.heal_tick +%= 1;
        if (app.plugin_mgr.heal_tick % 240 == 0) {
            const healed2 = app.reboundFailedPluginSlots(io);
            if (healed2 > 0) app.setToastWith("已自动重新定位 {d} 个插件", .{healed2});
        }
    }
    // 插件配置落盘（管理器改动；同 4.4 设置落盘模式）
    if (app.plugin_cfg_dirty) {
        app.plugin_cfg_dirty = false;
        if (pluginDataRoot(&app)) |pdr| {
            if (app.plugin_cfg) |*cfg| cfg.save(io, pdr) catch app.setToast("插件配置保存失败");
        }
    }
    // 4.4c) VST3 插件槽同步：退役实例回收 + 惰性加载（导入/撤销恢复后）
    syncPluginSlots(&app);
    // 4.4d) VST3 乐器实例同步（惰性加载 + 编辑器编辑轮询）
    syncInstrumentPlugins(&app);
    app.syncKitLayerPlugins();
    // 4.4e) VST3 插件界面嵌入同步（面板 → 子窗口；遮挡→隐藏；见函数注释）
    syncPluginEditors(&app, &ui, @intCast(win.fb.width), @intCast(win.fb.height));

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
    // 退出清理：扫描 worker 还在跑 → 杀（防孤儿进程；主进程退出不管子进程）
    if (app.plugin_mgr.scan_handle) |h| _ = TerminateProcess(h, 3);
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

/// 首个参数是否为 `--vst-scan`（同二进制自举入口判定；**GUI 初始化之前**调用）。
fn hasScanArg(init: std.process.Init) bool {
    var it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return false;
    defer it.deinit();
    _ = it.skip(); // argv0
    const a = it.next() orelse return false;
    return std.mem.eql(u8, a, "--vst-scan");
}

/// 可执行文件**完整路径**（UTF-8 写入 `buf`；失败返回 ""）。
/// 扫描 worker 用同二进制自举（`--vst-scan`）——需把自身路径传给 CreateProcessW。
fn selfExePath(allocator: std.mem.Allocator, buf: []u8) []const u8 {
    var wbuf: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &wbuf, wbuf.len);
    if (n == 0 or n >= wbuf.len) return "";
    const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..n]) catch return "";
    defer allocator.free(utf8);
    const m = @min(utf8.len, buf.len);
    @memcpy(buf[0..m], utf8[0..m]);
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
    appendVst3Categories(app); // 扫描缓存里的 VST3 乐器 → 合成分类
    // 浏览器分类索引钳制（库变化后可能越界）
    const n_cat = app.preset_lib.categories.items.len;
    if (n_cat == 0) {
        app.preset_browser.cat = 0;
    } else if (app.preset_browser.cat >= n_cat) {
        app.preset_browser.cat = n_cat - 1;
    }
}

/// 把扫描缓存中的 VST3 **乐器**合成进预设库（每插件一个分类 `vst3_<cid>`；
/// 与真实目录同名时跳过——真实目录已由常规扫描带出预设列表）。
fn appendVst3Categories(app: *App) void {
    const cache = if (app.plugin_cache) |*c| c else return;
    for (cache.entries) |*e| {
        // 乐器**与效果**都要（效果面板 M5 起也要选 VST3 效果——曾只收乐器，TDR Nova 类纯效果插件被濾掉）
        if (!e.ok or (!e.roleHasInstrument() and !e.roleHasEffect())) continue;
        // 分类身份 = **主 CID**（乐器类优先，否则首个效果类）——与 `canonicalCategoryCid`
        // 同一规则；loadPlugin 选类也是“首个匹配角色”，三者对齐。
        var primary: ?[]const u8 = null;
        for (e.classes) |cl| {
            if (std.mem.eql(u8, cl.kind, "instrument") and cl.cid.len == 32) {
                primary = cl.cid;
                break;
            }
        }
        if (primary == null) {
            for (e.classes) |cl| {
                if (std.mem.eql(u8, cl.kind, "effect") and cl.cid.len == 32) {
                    primary = cl.cid;
                    break;
                }
            }
        }
        const cid = primary orelse continue;
        var idb: [48]u8 = undefined;
        const id = preset_mod.vst3CategoryId(cid, &idb);
        if (id.len == 0) continue;
        if (app.preset_lib.findCategory(id) != null) continue;
        const name = app.allocator.dupe(u8, id) catch continue;
        app.preset_lib.categories.append(app.allocator, .{ .name = name }) catch {
            app.allocator.free(name);
            continue;
        };
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
    // VST3 乐器分类：独立流程（路径解析/状态应用/新建或切换）
    if (preset_mod.vst3CidFromCategory(plugin) != null) {
        loadVst3Preset(app, io, intent, cat, choice);
        return;
    }
    // 内建效果器分类（`fx_*`）：单效果预设（创建/替换效果槽）
    if (app_mod.fxKindFromCategory(plugin) != null) {
        loadFxPreset(app, io, intent, cat, choice);
        return;
    }
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
            .create_effect, .replace_effect => app.setToast("请选效果器分类（fx_* / VST3 效果）"),
        },
        .preset => |idx| {
            if (idx >= c.presets.items.len) return;
            // 内置分类：层只接受减法（鼓组禁自嵌套；VST3 分类走上方独立流程）
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
            const parsed = preset_mod.load(io, app.allocator, app.dataRoot(), c.dir, preset_name, plugin) catch |e| {
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
                .create_effect, .replace_effect => app.setToast("请选效果器分类（fx_* / VST3 效果）"),
            }
        },
    }
}

/// VST3 乐器分类的预设加载/新建（路径解析：扫描缓存 CID → dll → 活实例 →
/// 预设 last_path；状态解码后：同插件直恢复/换插件存 pending 帧末应用）。
fn loadVst3Preset(app: *App, io: std.Io, intent: PresetIntent, cat: usize, choice: PresetChoice) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const c = &cats[cat];
    const id = c.name;
    const cid = preset_mod.vst3CidFromCategory(id) orelse return;

    // 读预设文件（.preset 时；校验 CID 一致）
    var file_buf: ?std.json.Parsed(preset_mod.File) = null;
    defer if (file_buf) |*p| p.deinit();
    switch (choice) {
        .default => {},
        .preset => |idx| {
            if (idx >= c.presets.items.len) return;
            const preset_name = c.presets.items[idx];
            const parsed = preset_mod.load(io, app.allocator, app.dataRoot(), c.dir, preset_name, id) catch |e| {
                app.setToastWith("加载预设失败：{s}", .{@errorName(e)});
                return;
            };
            file_buf = parsed;
            // 身份校验已由 `preset_mod.load` 的 `plugin` 字段比对完成（CID 内嵌于分类 id）
        },
    }
    const file: ?*const preset_mod.File = if (file_buf) |*p| &p.value else null;
    const is_default = switch (choice) {
        .default => true,
        .preset => false,
    };
    const patch_name: []const u8 = switch (choice) {
        .default => "（默认音色）",
        .preset => |idx| c.presets.items[idx],
    };
    const label = app.presetCategoryLabel(id);

    // 路径解析：扫描缓存（CID → dll）→ 活实例 → 预设 last_path
    var path: []const u8 = app.vst3CategoryPath(id) orelse "";
    if (path.len == 0) {
        if (file) |f| {
            if (f.last_path.len > 0) path = f.last_path;
        }
    }
    // 状态解码（调用方释放；移交 pending 时置 null）
    var comp: ?[]u8 = null;
    var ctrl: ?[]u8 = null;
    if (file) |f| {
        comp = app.decodeStateB64(f.vst3_state);
        ctrl = app.decodeStateB64(f.vst3_state_ctrl);
    }
    defer if (comp) |b| app.allocator.free(b);
    defer if (ctrl) |b| app.allocator.free(b);
    const has_state = comp != null or ctrl != null;

    const target_ii: ?i32 = switch (intent) {
        .create_instrument => null,
        .change_instrument => |i| i,
        .replace => |t| switch (t) {
            .instrument => |i| i,
            .kit_layer_replace => null, // 鼓组层：下方专用分支
        },
        .create_kit_layer => null, // 鼓组层：下方专用分支
        .create_effect, .replace_effect => null, // 走下方效果分支
    };

    // ── 鼓组层意图（create_kit_layer / replace.kit_layer_replace）：VST3 乐器层 ──
    // 层 = 乐器槽（`docs/drumkit.md` §7）：创建/换插件与乐器同惯例；实例帧末
    // 惰性加载（`syncKitLayerPlugins`）。层无插件界面（v1）。
    switch (intent) {
        .create_kit_layer => |ref| {
            if (path.len == 0) {
                app.setToast("插件未安装/未扫描到——请在插件管理里扫描或添加文件");
                return;
            }
            var sbuf2: [preset_mod.max_name_len + 96]u8 = undefined;
            const src = if (is_default) label else (std.fmt.bufPrint(&sbuf2, "{s}/{s}", .{ label, patch_name }) catch label);
            if (!app.kitLayerAddVst3(ref.instrument, ref.pitch, path, src)) {
                app.setToastWith("添加失败（层数已满？上限 {d}）", .{audio.kit_max_layers});
                return;
            }
            if (has_state) {
                // 新层（无实例）→ 状态入 pending，帧末加载后应用（一条历史捕获两者）
                const kit = app.instruments.items[@intCast(ref.instrument)].kit.?;
                if (kit.find(ref.pitch)) |pad| {
                    if (pad.layers.items.len > 0) {
                        const ly = &pad.layers.items[pad.layers.items.len - 1];
                        ly.clearPendingState(app.allocator);
                        ly.pending_state = comp;
                        ly.pending_state_ctrl = ctrl;
                        comp = null;
                        ctrl = null; // 所有权移交（defer 不再释放）
                    }
                }
            }
            app.commitHistory(if (is_default) "添加乐器" else "添加乐器（预设）");
            openKitLayerWindow(app, ref.instrument, ref.pitch); // 顺势展示插件界面（加载后出现）
            app.setToastWith("已添加 VST3 乐器层：{s}（{s}）", .{ label, patch_name });
            return;
        },
        .replace => |t| switch (t) {
            .kit_layer_replace => |ref| {
                const ly = app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse {
                    app.setToast("目标层已不存在");
                    return;
                };
                const same = blk: {
                    if (ly.kind == .vst3) {
                        if (ly.plugin) |pl| break :blk app.pluginInstanceMatchesCategory(pl, cid);
                    }
                    break :blk false;
                };
                if (same) {
                    if (has_state) {
                        ly.plugin.?.restoreState(comp orelse &.{}, ctrl orelse &.{});
                        // 同乐器路径：恢复后全 128 panic（防幽灵声部永挂）
                        if (app.kitLayerSlot(@intCast(ref.instrument), ref.pitch, ref.layer)) |slot| {
                            app.params.kit_layer_panic[@intCast(ref.instrument)][slot].store(true, .release);
                        }
                        _ = app.kitLayerSetSource(ref.instrument, ref.pitch, ref.layer, patch_name);
                        app.commitHistory("加载预设");
                        app.setToastWith("已加载插件预设：{s}", .{patch_name});
                    } else {
                        app.setToast("（默认音色在新建层或换插件时生效）");
                    }
                    return;
                }
                if (path.len == 0) {
                    app.setToast("插件未安装/未扫描到——请在插件管理里扫描或添加文件");
                    return;
                }
                // 换插件：旧实例退役（帧末按新路径惰性加载）；状态入 pending
                if (ly.plugin) |pl| {
                    ly.plugin = null;
                    app.retirePlugin(pl);
                }
                ly.clearPendingState(app.allocator);
                ly.kind = .vst3;
                ly.setPluginPath(path);
                if (has_state) {
                    ly.pending_state = comp;
                    ly.pending_state_ctrl = ctrl;
                    comp = null;
                    ctrl = null;
                }
                _ = app.kitLayerSetSource(ref.instrument, ref.pitch, ref.layer, if (is_default) "" else patch_name);
                app.commitHistory(if (is_default) "更换层乐器" else "更换层乐器并载入预设");
                app.setToastWith("已切换层乐器：{s}（{s}）", .{ label, patch_name });
                return;
            },
            .instrument => {},
        },
        else => {},
    }

    // ── 效果器意图（create_effect / replace_effect）──
    if (intent == .create_effect or intent == .replace_effect) {
        if (path.len == 0) {
            app.setToast("插件未安装/未扫描到——请在插件管理里扫描或添加文件");
            return;
        }
        if (intent == .replace_effect) {
            const r = intent.replace_effect;
            if (r.ch >= app.mixer_channels_state.items.len) return;
            const chain = &app.mixer_channels_state.items[r.ch].effects;
            if (r.slot >= chain.items.len) return;
            const es = &chain.items[r.slot];
            const same_plugin = blk: {
                if (es.kind == .plugin) {
                    if (es.plugin) |pl| {
                        break :blk app.pluginInstanceMatchesCategory(pl, cid);
                    }
                }
                break :blk false;
            };
            if (same_plugin) {
                if (has_state) {
                    es.plugin.?.restoreState(comp orelse &.{}, ctrl orelse &.{});
                    // 记账（置脏 + 提交）：干净槽不置脏会被判“无变化”而静默丢弃条目
                    app.notePluginStateReplaced(.{ .kind = .fx, .a = @intCast(r.ch), .b = @intCast(r.slot) }, "加载预设");
                    app.setToastWith("已加载插件预设：{s}", .{patch_name});
                } else {
                    app.setToast("（默认音色在新建插件时生效）");
                }
                return;
            }
            // 换成该插件（内置/其它插件 → 此插件）：旧实例退役、状态入 pending
            if (es.plugin) |pl| {
                es.plugin = null;
                app.retirePlugin(pl);
            }
            es.clearPendingState(app.allocator);
            es.setPluginPath(path);
            es.kind = .plugin;
            if (has_state) {
                es.pending_state = comp;
                es.pending_state_ctrl = ctrl;
                comp = null;
                ctrl = null;
            }
            app.mixer_win.panel = .{ .ch = r.ch, .slot = r.slot };
            app.commitHistory("更换效果器");
            app.setToastWith("已更换效果器插件：{s}（{s}）", .{ label, patch_name });
            return;
        }
        // create_effect：通道末尾新建插件槽
        const ch = intent.create_effect;
        const slot = app.addEffect(ch, .plugin) orelse {
            app.setToast("无法添加效果器（数量达上限）");
            return;
        };
        const es = &app.mixer_channels_state.items[ch].effects.items[slot];
        es.setPluginPath(path);
        if (has_state) {
            es.pending_state = comp;
            es.pending_state_ctrl = ctrl;
            comp = null;
            ctrl = null;
        }
        app.mixer_win.panel = .{ .ch = ch, .slot = slot };
        app.bringToFront(&app.effect_win.z);
        app.commitHistory(if (is_default) "添加效果器" else "添加效果器（预设）");
        app.setToastWith("已添加效果器插件：{s}（{s}）", .{ label, patch_name });
        return;
    }

    if (target_ii == null) {
        // 新建
        if (path.len == 0) {
            app.setToast("插件未安装/未扫描到——请在插件管理里扫描或添加文件");
            return;
        }
        const ni = app.addInstrumentVst3(path);
        if (ni < 0) {
            app.setToast("无法添加乐器（数量达上限）");
            return;
        }
        if (has_state) {
            const inst = &app.instruments.items[@intCast(ni)];
            inst.clearPendingState(app.allocator);
            inst.pending_state = comp;
            inst.pending_state_ctrl = ctrl;
            comp = null;
            ctrl = null; // 所有权移交（defer 不再释放）
            app.commitHistory("加载插件预设"); // 捕获 pending（exportInstrument 有 pending 回退）
        }
        app.setInstrument(@intCast(ni));
        app.setToastWith("已添加 VST3 乐器：{s}（{s}）", .{ label, patch_name });
        return;
    }

    // 应用到已有乐器（更换乐器 / 替换音色）
    const ii = target_ii.?;
    if (ii < 0 or ii >= @as(i32, @intCast(app.instruments.items.len))) return;
    const same_plugin = blk: {
        const inst = &app.instruments.items[@intCast(ii)];
        if (inst.kind == .vst3) {
            if (inst.plugin) |pl| {
                break :blk app.pluginInstanceMatchesCategory(pl, cid);
            }
        }
        break :blk false;
    };
    if (same_plugin) {
        if (has_state) {
            const pl = app.instruments.items[@intCast(ii)].plugin.?;
            pl.restoreState(comp orelse &.{}, ctrl orelse &.{});
            // 同 syncInstrumentPlugins：恢复后全 128 panic（防幽灵声部永挂）
            app.params.instrument_panic[@intCast(ii)].store(true, .release);
            _ = app.setInstrumentPresetName(@intCast(ii), patch_name);
            // 记账（置脏 + 提交）：否则新条目会复用旧 blob（携带过期插件状态）
            app.notePluginStateReplaced(.{ .kind = .instrument, .a = @intCast(ii) }, "加载预设");
            app.setToastWith("已加载插件预设：{s}", .{patch_name});
        } else {
            app.setToast("（默认音色在新建 VST3 乐器或换插件时生效）");
        }
        return;
    }
    if (path.len == 0) {
        app.setToast("插件未安装/未扫描到——请在插件管理里扫描或添加文件");
        return;
    }
    app.applyVst3Instrument(ii, path);
    if (has_state) {
        const inst = &app.instruments.items[@intCast(ii)];
        inst.pending_state = comp;
        inst.pending_state_ctrl = ctrl;
        comp = null;
        ctrl = null;
    }
    _ = app.setInstrumentPresetName(@intCast(ii), if (is_default) "" else patch_name);
    app.commitHistory(if (is_default) "更换乐器" else "更换乐器并载入预设");
    if (is_default) {
        app.setToastWith("已切到插件：{s}", .{label});
    } else {
        app.setToastWith("已切到插件并载入预设：{s}（{s}）", .{ label, patch_name });
    }
}

/// 内建效果器分类（`fx_*`）的预设：创建效果槽或替换指定效果槽。
/// 载荷 = kind/mix/p/bands（`preset.File.effect`）。
fn loadFxPreset(app: *App, io: std.Io, intent: PresetIntent, cat: usize, choice: PresetChoice) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const c = &cats[cat];
    const id = c.name;
    const kind = app_mod.fxKindFromCategory(id) orelse return;
    const is_default = switch (choice) {
        .default => true,
        .preset => false,
    };
    const patch_name: []const u8 = switch (choice) {
        .default => "",
        .preset => |idx| c.presets.items[idx],
    };

    var file_buf: ?std.json.Parsed(preset_mod.File) = null;
    defer if (file_buf) |*p| p.deinit();
    switch (choice) {
        .default => {},
        .preset => |idx| {
            if (idx >= c.presets.items.len) return;
            const parsed = preset_mod.load(io, app.allocator, app.dataRoot(), c.dir, c.presets.items[idx], id) catch |e| {
                app.setToastWith("加载预设失败：{s}", .{@errorName(e)});
                return;
            };
            file_buf = parsed;
        },
    }
    const file: ?*const preset_mod.File = if (file_buf) |*p| &p.value else null;

    switch (intent) {
        .create_effect => |ch| {
            const slot = app.addEffect(ch, kind) orelse {
                app.setToast("无法添加效果器（数量达上限）");
                return;
            };
            const es = &app.mixer_channels_state.items[ch].effects.items[slot];
            applyFxParams(es, file);
            app.mixer_win.panel = .{ .ch = ch, .slot = slot };
            app.bringToFront(&app.effect_win.z);
            app.commitHistory(if (is_default) "添加效果器" else "添加效果器（预设）");
            app.setToastWith("已添加效果器：{s}", .{kind.displayName()});
        },
        .replace_effect => |r| {
            if (r.ch >= app.mixer_channels_state.items.len) return;
            const chain = &app.mixer_channels_state.items[r.ch].effects;
            if (r.slot >= chain.items.len) return;
            const es = &chain.items[r.slot];
            const kind_changed = es.kind != kind;
            if (kind_changed) {
                // 从插件换到内置：旧实例退役、路径/状态清空
                if (es.plugin) |pl| {
                    es.plugin = null;
                    app.retirePlugin(pl);
                }
                es.plugin_path_len = 0;
                es.clearPendingState(app.allocator);
                // DSP 状态盒：kind 变了 → 立即退役/清指针（帧末同步会建新的）
                if (es.fx_state) |box| {
                    app.retireFxState(box);
                    es.fx_state = null;
                    app.params.fx_ptrs[r.ch][r.slot].store(null, .monotonic);
                }
                es.kind = kind;
            }
            applyFxParams(es, file);
            app.mixer_win.panel = .{ .ch = r.ch, .slot = r.slot };
            const label: []const u8 = if (kind_changed)
                "更换效果器"
            else if (is_default)
                "重置效果"
            else
                "加载预设";
            app.commitHistory(label);
            if (kind_changed) {
                app.setToastWith("已更换效果器：{s}", .{kind.displayName()});
            } else if (is_default) {
                app.setToast("已重置为默认参数（可撤销）");
            } else {
                app.setToastWith("已加载预设：{s}", .{patch_name});
            }
        },
        else => {},
    }
}

/// 把效果器预设载荷（或类型默认值）写进效果槽（bands 按槽长截断）
fn applyFxParams(es: *app_mod.EffectSlot, file: ?*const preset_mod.File) void {
    if (file) |f| {
        const se = &f.effect;
        es.enabled = se.enabled;
        es.mix = se.mix;
        es.p = se.p;
        const n = @min(se.bands.len, es.bands.len);
        for (se.bands[0..n], 0..) |b, i| es.bands[i] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
    } else {
        es.enabled = true;
        es.mix = fx.defaultMix(@intFromEnum(es.kind));
        if (es.kind != .eq) es.p = fx.defaultParams(@intFromEnum(es.kind));
        if (es.kind == .eq) es.bands = (app_mod.EffectSlot{}).bands;
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
                app.setToast("已添加乐器 — 在窗口里点「预设」换音色");
}

/// 应用到**已有鼓组层**（层窗口「预设 ▾」）：换音色/默认 + 更新来源名
fn applyLayerChoice(app: *App, ref: PresetTarget.KitLayerRef, patch: ?*const persist.SavedSynth, src: []const u8) void {
    const lp = app.kitLayerParams(ref.instrument, ref.pitch, ref.layer) orelse {
        app.setToast("目标层已不存在");
        return;
    };
    // 目标层若为 VST3 → 换回减法（插件退役；防“显示减法预设但仍响插件”）
    app.kitLayerClearVst3(ref.instrument, ref.pitch, ref.layer);
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
            // VST3 乐器 → 独立保存流程（状态快照 + 身份字段；分类 `vst3_<cid>`）
            const vst3_target: ?PresetTarget = switch (target) {
                .instrument => |i| blk: {
                    if (i >= 0 and i < @as(i32, @intCast(app.instruments.items.len)) and
                        app.instruments.items[@intCast(i)].kind == .vst3) break :blk target;
                    break :blk null;
                },
                .kit_layer_replace => |ref| blk: {
                    const ly = app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse break :blk null;
                    break :blk if (ly.kind == .vst3) target else null;
                },
            };
            if (vst3_target) |t| {
                saveVst3Preset(app, io, root, t, clean, overwrite);
                return;
            }
            const params = app.resolvePresetTarget(target) orelse {
                app.setToast("保存目标已不存在");
                return;
            };
            const plugin = app.presetTargetPlugin(target);
            const file = preset_mod.File{ .plugin = plugin, .synth = persist.exportSynth(params) };
            var dir_buf: [200]u8 = undefined;
            const dir = app.presetDirForCategory(plugin, "", &dir_buf);
            preset_mod.saveFile(io, app.allocator, root, dir, clean, file, overwrite) catch |e| {
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
            defer app.freeSavedKit(&snapshot, false);
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
        .effect => |r| {
            if (r.ch >= app.mixer_channels_state.items.len) {
                app.setToast("保存目标已不存在");
                return;
            }
            const chain = &app.mixer_channels_state.items[r.ch].effects;
            if (r.slot >= chain.items.len) {
                app.setToast("保存目标已不存在");
                return;
            }
            const es = &chain.items[r.slot];
            if (es.kind == .plugin) {
                saveVst3EffectPreset(app, io, root, es, r, clean, overwrite);
            } else {
                const id = es.kind.presetCategoryId() orelse {
                    app.setToast("该效果器不支持保存预设");
                    return;
                };
                // bands 深拷贝（saveFile 只读；写盘后释放）
                const bands = app.allocator.alloc(persist.SavedEqBand, es.bands.len) catch {
                    saveFailed(app, error.OutOfMemory);
                    return;
                };
                defer app.allocator.free(bands);
                for (es.bands, 0..) |b, i| bands[i] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
                const file = preset_mod.File{
                    .version = 2,
                    .plugin = id,
                    .effect = .{
                        .kind = @intFromEnum(es.kind),
                        .enabled = es.enabled,
                        .mix = es.mix,
                        .bands = bands,
                        .p = es.p,
                    },
                };
                var dir_buf: [200]u8 = undefined;
                const dir = app.presetDirForCategory(id, "", &dir_buf);
                preset_mod.saveFile(io, app.allocator, root, dir, clean, file, overwrite) catch |e| {
                    if (e == error.AlreadyExists and !overwrite) {
                        app.setOverwritePrompt(.{ .effect = r }, clean);
                        return;
                    }
                    saveFailed(app, e);
                    return;
                };
            }
        },
    }
    if (overwrite) {
        app.setToastWith("已覆写预设：{s}（其它已加载它的乐器不受影响）", .{clean});
    } else {
        app.setToastWith("已保存预设：{s}", .{clean});
    }
    scanPresets(app, io); // 立即出现在面板列表里
}

/// VST3 效果器预设保存：与乐器版同构（CID **从活实例实时取**；状态 base64 组件+控制器）。
/// 只管写盘/重名；成功 toast 与重扫由 savePreset 共享尾部统一做。
fn saveVst3EffectPreset(app: *App, io: std.Io, root: []const u8, es: *app_mod.EffectSlot, ref: app_mod.EffectRef, clean: []const u8, overwrite: bool) void {
    const pl = es.plugin orelse {
        app.setToast("插件未加载，无法保存预设（稍候重试或检查插件路径）");
        return;
    };
    var hb: [32]u8 = undefined;
    var canon: [32]u8 = undefined;
    const cid_hex = app.canonicalCategoryCid(pl.cidHex(&hb), &canon); // 主 CID（双角色对齐）
    var idb: [48]u8 = undefined;
    const id = preset_mod.vst3CategoryId(cid_hex, &idb);
    if (id.len == 0) {
        app.setToast("无法保存预设：插件 CID 无效");
        return;
    }
    var dir_buf3: [200]u8 = undefined;
    const dir = app.presetDirForCategory(id, pl.name(), &dir_buf3);
    const comp_b64 = app.captureEffectStateB64(es, true) orelse {
        app.setToast("捕获插件状态失败");
        return;
    };
    defer if (comp_b64.len > 0) app.allocator.free(comp_b64);
    const ctrl_b64 = app.captureEffectStateB64(es, false) orelse {
        app.setToast("捕获插件状态失败");
        return;
    };
    defer if (ctrl_b64.len > 0) app.allocator.free(ctrl_b64);
    const file = preset_mod.File{
        .version = 2,
        .plugin = id,
        .name = pl.name(),
        .vendor = pl.vendor(),
        .last_path = es.pluginPath(),
        .vst3_state = comp_b64,
        .vst3_state_ctrl = ctrl_b64,
    };
    preset_mod.saveFile(io, app.allocator, root, dir, clean, file, overwrite) catch |e| {
        if (e == error.AlreadyExists and !overwrite) {
            app.setOverwritePrompt(.{ .effect = ref }, clean);
            return;
        }
        saveFailed(app, e);
        return;
    };
}

/// VST3 乐器预设保存：`plugin = vst3_<cid>`（CID **从活实例实时取**，不依赖
/// 扫描缓存——未扫描过的插件也能存）；状态 base64（组件+控制器）入档。
/// 首次保存自动创建分类目录；与内置流程共用重名/覆写/关联名逻辑。
fn saveVst3Preset(app: *App, io: std.Io, root: []const u8, target: PresetTarget, clean: []const u8, overwrite: bool) void {
    // 解析目标：插件实例 + 路径（乐器本体 / 鼓组 VST3 层）
    const pl: *vst_host.Plugin = switch (target) {
        .instrument => |ii| blk: {
            if (ii < 0 or ii >= @as(i32, @intCast(app.instruments.items.len))) return;
            break :blk app.instruments.items[@intCast(ii)].plugin orelse {
                app.setToast("插件未加载，无法保存预设（稍候重试或检查插件路径）");
                return;
            };
        },
        .kit_layer_replace => |ref| blk: {
            const ly = app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse return;
            break :blk ly.plugin orelse {
                app.setToast("插件未加载，无法保存预设（稍候重试或检查插件路径）");
                return;
            };
        },
    };
    const path: []const u8 = switch (target) {
        .instrument => |ii| app.instruments.items[@intCast(ii)].pluginPath(),
        .kit_layer_replace => |ref| (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse return).pluginPath(),
    };
    var hb: [32]u8 = undefined;
    var canon: [32]u8 = undefined;
    const cid_hex = app.canonicalCategoryCid(pl.cidHex(&hb), &canon); // 主 CID（双角色对齐）
    var idb: [48]u8 = undefined;
    const id = preset_mod.vst3CategoryId(cid_hex, &idb);
    if (id.len == 0) {
        app.setToast("无法保存预设：插件 CID 无效");
        return;
    }
    var dir_buf2: [200]u8 = undefined;
    const dir = app.presetDirForCategory(id, pl.name(), &dir_buf2);
    const st = switch (target) {
        .instrument => |ii| app.captureVst3StateB64(ii),
        .kit_layer_replace => |ref| app.captureLayerVst3StateB64(ref),
    } orelse {
        app.setToast("捕获插件状态失败");
        return;
    };
    defer {
        if (st.comp.len > 0) app.allocator.free(st.comp);
        if (st.ctrl.len > 0) app.allocator.free(st.ctrl);
    }
    const file = preset_mod.File{
        .version = 2,
        .plugin = id,
        .name = pl.name(),
        .vendor = pl.vendor(),
        .last_path = path,
        .vst3_state = st.comp,
        .vst3_state_ctrl = st.ctrl,
    };
    preset_mod.saveFile(io, app.allocator, root, dir, clean, file, overwrite) catch |e| {
        if (e == error.AlreadyExists and !overwrite) {
            app.setOverwritePrompt(.{ .params = target }, clean);
            return;
        }
        saveFailed(app, e);
        return;
    };
    // 名称落点：乐器 → 关联预设名；鼓组层 → 来源名（展示用）+ 一条历史
    switch (target) {
        .instrument => |ii| {
            _ = app.setInstrumentPresetName(@intCast(ii), clean);
        },
        .kit_layer_replace => |ref| {
            var sbuf: [preset_mod.max_name_len * 2 + 4]u8 = undefined;
            const src = std.fmt.bufPrint(&sbuf, "{s}/{s}", .{ id, clean }) catch clean;
            if (app.kitLayerSetSource(ref.instrument, ref.pitch, ref.layer, src)) {
                app.commitHistory("保存预设");
            }
        },
    }
    if (overwrite) {
        app.setToastWith("已覆写预设：{s}", .{clean});
    } else {
        app.setToastWith("已保存预设：{s}", .{clean});
    }
    scanPresets(app, io); // 新分类/条目立即出现在面板里
}

/// 重命名预设文件（重名/空名 → toast；成功后重扫）
fn renamePreset(app: *App, io: std.Io, cat: usize, old_name: []const u8, raw_new: []const u8) void {
    const cats = app.preset_lib.categories.items;
    if (cat >= cats.len) return;
    const dir = cats[cat].dir;
    preset_mod.rename(io, app.dataRoot(), dir, old_name, raw_new) catch |e| {
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
    const dir = cats[cat].dir;
    preset_mod.remove(io, app.dataRoot(), dir, name) catch {
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
    mouse_middle_pressed: bool = false,
    mouse_middle_down: bool = false,
    mouse_double: bool = false,
    wheel: i32 = 0,
    wheel_ctrl: bool = false,
    wheel_alt: bool = false,
    wheel_shift: bool = false,
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
    // 注：只有 **EQ** 面板画频谱背景——其它效果器面板不发目标（不白算 FFT）
    if (app.mixer_win.panel) |p| {
        const is_eq = p.ch < app.mixer_channels_state.items.len and
            p.slot < app.mixer_channels_state.items[p.ch].effects.items.len and
            app.mixer_channels_state.items[p.ch].effects.items[p.slot].kind == .eq;
        if (is_eq) {
            app.params.spec_target_ch.store(@intCast(@min(p.ch, audio.mixer_channels - 1)), .monotonic);
            app.params.spec_target_slot.store(@intCast(@min(p.slot, @as(i32, @intCast(app.params.slots_cap)) - 1)), .monotonic);
        } else {
            app.params.spec_target_ch.store(-1, .monotonic);
        }
    } else {
        app.params.spec_target_ch.store(-1, .monotonic);
    }
    // 机架的下拉/右键菜单、文件菜单 = 模态层（全屏屏蔽）。
    // 注：钢琴卷帘的两个标题栏选单**不在此列**——它们保持轻量语义，
    // 这样两个选单可以单击直接互切（进模态层会让选择器按钮自身被屏蔽）。
    // **组合集中在 `App.menuIsOpen`**（漏项会导致点击穿透下层——
    // 实测 bug：文件→保存穿透点到左栏“操作历史”）。
    const menu_open = app.menuIsOpen();

    // 浮动窗口列表（按 z 升序 = 从下到上）；排序用插入排序（元素很少）
    var wins: [8]struct { z: i32, draw: app_mod.WinKind } = undefined;
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
    if (app.help_win.open) {
        wins[nwin] = .{ .z = app.help_win.z, .draw = .help };
        nwin += 1;
    }
    if (app.settings_win.open) {
        wins[nwin] = .{ .z = app.settings_win.z, .draw = .settings };
        nwin += 1;
    }
    if (app.plugin_mgr.open) {
        wins[nwin] = .{ .z = app.plugin_mgr.z, .draw = .plugin_mgr };
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
    // 导出进度窗（模态：导出期间屏蔽一切；与确认框同优先级——两者不会同时出现）
    if (app.export_wav != null) {
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
            .help => .{ .x = app.help_win.x, .y = app.help_win.y, .w = app.help_win.w, .h = app.help_win.h },
            .settings => .{ .x = app.settings_win.x, .y = app.settings_win.y, .w = app.settings_win.w, .h = app.settings_win.h },
            .plugin_mgr => .{ .x = app.plugin_mgr.x, .y = app.plugin_mgr.y, .w = app.plugin_mgr.w, .h = app.plugin_mgr.h },
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
            .help => _ = view_help.draw(ui, app, w, h),
            .settings => _ = view_settings.draw(ui, app, w, h),
            .plugin_mgr => _ = view_plugins.draw(ui, app, w, h),
        }
        ui.endLayer();
    }

    // 记录本帧浮动窗口的绘制顺序与最终矩形（插件子窗口区域裁切用；与绘制严格同序）。
    // 注：在绘制之后读取——各窗口的 x/y/w/h 已 clamp/更新为最终值。
    app.win_draw_n = 0;
    for (wins[0..nwin]) |win| {
        if (app.win_draw_n >= app.win_draw_info.len) break;
        app.win_draw_info[app.win_draw_n] = switch (win.draw) {
            .rack => .{ .kind = .rack, .x = app.rack.x, .y = app.rack.y, .w = app.rack.w, .h = app.rack.h },
            .synth => .{ .kind = .synth, .x = app.synth_win.x, .y = app.synth_win.y, .w = app.synth_win.w, .h = app.synth_win.h },
            .mixer => .{ .kind = .mixer, .x = app.mixer_win.x, .y = app.mixer_win.y, .w = app.mixer_win.w, .h = app.mixer_win.h },
            .effect => .{ .kind = .effect, .x = app.effect_win.x, .y = app.effect_win.y, .w = app.effect_win.w, .h = app.effect_win.h },
            .drumkit => .{ .kind = .drumkit, .x = app.drumkit_win.x, .y = app.drumkit_win.y, .w = app.drumkit_win.w, .h = app.drumkit_win.h },
            .help => .{ .kind = .help, .x = app.help_win.x, .y = app.help_win.y, .w = app.help_win.w, .h = app.help_win.h },
            .settings => .{ .kind = .settings, .x = app.settings_win.x, .y = app.settings_win.y, .w = app.settings_win.w, .h = app.settings_win.h },
            .plugin_mgr => .{ .kind = .plugin_mgr, .x = app.plugin_mgr.x, .y = app.plugin_mgr.y, .w = app.plugin_mgr.w, .h = app.plugin_mgr.h },
        };
        app.win_draw_n += 1;
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
    const menus = [_][]const u8{ "文件", "选项", "乐器", "混音台" };
    // 工具栏顺序（用户拍板）：文件 选项 帮助 插件 乐器 混音台——
    // 菜单数组维持原下标（`i` 参与动作分派），按**绘制序列**遍历：
    // 255 = 帮助按钮、254 = 插件按钮（插在菜单之间的非菜单项）
    const seq = [_]usize{ 0, 1, 255, 254, 2, 3 };
    for (seq) |si| {
        if (si == 255) {
            // “帮助”按钮（无下拉）：单击**切换**帮助页可见性（同“乐器/混音台”）
            const hw2: i32 = @as(i32, @intFromFloat(ui.font.measure("帮助"))) + 16;
            if (app.help_win.open) {
                if (ui.buttonEx(110, "帮助", x, by, hw2, bh, true)) app.help_win.open = false;
            } else if (ui.button(110, "帮助", x, by, hw2, bh)) {
                app.help_win.open = true;
                app.bringToFront(&app.help_win.z); // 刚打开：置顶
            }
            x += hw2 + 2;
            continue;
        }
        if (si == 254) {
            // “插件”按钮（插件管理窗口；单击切换可见性，同“帮助”）
            const pw2: i32 = @as(i32, @intFromFloat(ui.font.measure("插件"))) + 16;
            if (app.plugin_mgr.open) {
                if (ui.buttonEx(111, "插件", x, by, pw2, bh, true)) app.plugin_mgr.open = false;
            } else if (ui.button(111, "插件", x, by, pw2, bh)) {
                app.plugin_mgr.open = true;
                app.bringToFront(&app.plugin_mgr.z); // 刚打开：置顶
            }
            x += pw2 + 2;
            continue;
        }
        const i: usize = si;
        const m = menus[i];
        const mw: i32 = @as(i32, @intFromFloat(ui.font.measure(m))) + 16;
        const active = (i == 2 and app.rack.open) or (i == 0 and app.file_menu_open) or (i == 3 and app.mixer_win.open) or (i == 1 and app.settings_win.open);
        if (active) {
            if (ui.buttonEx(100 + @as(u64, i), m, x, by, mw, bh, true)) {
                if (i == 2) {
                    app.rack.open = false;
                } else if (i == 0) {
                    app.file_menu_open = false;
                } else if (i == 3) {
                    app.mixer_win.open = false;
                } else if (i == 1) {
                    app.settings_win.open = false;
                }
            }
        } else if (ui.button(100 + @as(u64, i), m, x, by, mw, bh)) {
            if (i == 2) {
                app.rack.open = true;
                app.bringToFront(&app.rack.z); // 刚打开：置顶（否则可能被别的窗口盖住）
            } else if (i == 1) {
                app.settings_win.open = true;
                app.bringToFront(&app.settings_win.z);
            } else if (i == 0) {
                app.file_menu_open = !app.file_menu_open;
                // 刚打开：供 drawFileMenu 区分“打开那一下”（不立即关）
                if (app.file_menu_open) app.file_menu_just_opened = true;
            } else if (i == 3) {
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

    // SONG / PAT 切换（播放全曲 or 当前样式）——**保位切换**（与状态栏按钮同一
    // 路径 `switchSongModePreserving`：按锚片段映射换算、原地换坐标；
    // 旧版直接翻模式 → 跳到另一模式“冻结的旧位置”（实测“两个模式各自记位置”））
    if (ui.toggle2(150, "SONG", "PAT", app.sel.song_mode, x, by, 92, bh)) {
        app.switchSongModePreserving();
    }
    x += 100;

    // 分隔
    ui.renderer.vline(x - 6, 6, util.toolbar_h - 12, ui.theme.panel_border);

    // 传输控制（图标**自绘**：中文字体常缺几何符号字形（▶ U+25B6 等），
    // 缺字时退回 .notdef 方块——实测“播放按钮变竖长方形”；
    // 像素级画形状则任何字体下外观一致）
    // 「跟随播放游标」开关（播放按钮**左侧**、同尺寸 36×26）：开 = 播放中视角
    // 平滑滑到游标（动画过渡，不跳切）；中键平移/拖滚动条/滚轮等**主动操作优先**，
    // 停手且仍在播放 → 继续跟上（实现见 `view_playlist` 尾部跟随块）
    if (ui.iconButton(199, .follow, x, by, 36, bh, app.playlist.follow_playhead, ui.theme.accent)) {
        app.playlist.follow_playhead = !app.playlist.follow_playhead;
    }
    x += 40;
    if (ui.iconButton(200, if (app.playing) .pause else .play, x, by, 36, bh, app.playing, ui.theme.accent)) {
        app.playing = !app.playing;
        if (app.playing) {
            const from = if (app.sel.song_mode) app.playback.song_step else app.playback.piano_step;
            app.playback.start_frame = app.params.frames_played.load(.monotonic);
            app.playback.start_step = from;
            app.params.start_frame.store(app.playback.start_frame, .monotonic);
            app.params.start_step.store(from, .monotonic);
            app.params.playing.store(true, .monotonic);
            app.markGenSoft(false); // 硬切换（起播）：照旧释放（无残留声部）
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
        .{ .label = "新建（空）", .shortcut = "" },
        .{ .label = "打开...", .shortcut = "Ctrl+O" },
        .{ .label = "保存", .shortcut = "Ctrl+S" },
        .{ .label = "另存为...", .shortcut = "Ctrl+Shift+S" },
        .{ .label = "导入 MIDI...", .shortcut = "" },
        .{ .label = "导出 MIDI...", .shortcut = "" },
        .{ .label = "导出音频 (WAV)...", .shortcut = "" },
    };
    const item_h: i32 = 22;
    const menu_x = app.file_menu_x;
    const menu_w = app.file_menu_w;
    const menu_y = util.toolbar_h;
    const menu_h: i32 = @intCast(items.len * @as(usize, @intCast(item_h)) + 4);

    ui.renderer.fillRect(menu_x, menu_y, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(menu_x, menu_y, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(menu_x, menu_y, menu_w, menu_h); // 遮挡插件子窗口

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
            0 => .new,
            1 => .open,
            2 => .save,
            3 => .save_as,
            4 => .import_midi,
            5 => .export_midi,
            6 => .export_wav,
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

    // 导出 → 序列化（**v5 二进制默认**；JSON 保留为导入/导出通道）→ 写文件 → 释放
    const project = app.exportProject() catch |e| {
        app.setToastWith("保存失败：导出失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.freeProject(project);

    const bytes = persist.toBinary(app.allocator, project) catch |e| {
        app.setToastWith("保存失败：序列化失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |e| {
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

/// 新建（空）工程（文件菜单入口）：**脏则先弹确认**（与“打开...”同一套流程，
/// 保存/丢弃/取消三态）——确认后由状态机直接执行 `newProject`。
fn newProjectWithConfirm(app: *App) void {
    if (app.dirty) {
        app.dirty_flow = .confirming;
        app.dirty_intent = .new;
        app.modal = .dirty_confirm;
        app.modal_choice = null;
        return;
    }
    newProject(app);
}

/// 新建（空）工程（已确认 / 无需确认时）：重置为默认内容（1 样式 + Track 1
/// 最左 1 片段 + 1 个减法合成器）并清路径（标题回到“未命名”）。
fn newProject(app: *App) void {
    app.resetToDefaultProject(); // 内部：停播 + 重建 + resetHistory("新建") + markSaved
    app.clearProjectPath();
    app.setToast("已新建空工程");
}

/// 设置文件路径（数据根下 `settings.json`）；无数据根/分配失败 → null。
/// 返回的路径归调用方释放。
fn settingsPath(app: *const App) ?[]u8 {
    if (app.data_root_len == 0) return null;
    return std.fs.path.join(app.allocator, &.{ app.data_root_buf[0..app.data_root_len], "settings.json" }) catch null;
}

/// VST3 乐器实例同步（每帧帧末）：
/// 1) 有路径、无实例 → 惰性加载（工程加载/撤销恢复/新建后的场景）；
/// 2) 编辑器内参数编辑 → 标脏 + 手势（与效果器一致）。
/// 加载失败后的重试节流（帧；~2s @120fps）——防每帧反复探测缺失文件
const plugin_retry_frames: u16 = 240;

/// VST3 乐器插件同步（每帧帧末）：惰性加载 + 待恢复音色应用 + GUI 编辑轮询。
/// 加载失败：**保留路径**、置 load_failed（机架标红）、每 ~2s 重试（fail_wait 节流）；
/// 文件恢复后自动加载并应用 pending 音色（不丢参数）。
/// 注：失败/正常卸载都**不 FreeLibrary**（插件 DLL 常驻——卸载后插件后台线程会执行已卸载代码，实测崩）。
fn syncInstrumentPlugins(app: *App) void {
    const sr: f64 = @floatFromInt(@max(1, app.params.sample_rate));
    for (app.instruments.items, 0..) |*inst, ii| {
        if (inst.kind != .vst3) continue;
        if (inst.plugin == null) {
            if (inst.pluginPath().len == 0) continue;
            if (inst.fail_wait > 0) {
                inst.fail_wait -= 1;
                continue;
            }
            inst.fail_wait = plugin_retry_frames;
            const pz = app.allocator.dupeZ(u8, inst.pluginPath()) catch continue;
            defer app.allocator.free(pz);
            inst.plugin = vst_host.loadPlugin(app.allocator, pz, sr, 4096, .instrument) catch |e| {
                if (!inst.load_failed) {
                    inst.load_failed = true;
                    app.setToastWith("乐器插件“{s}”加载失败：{s}（将自动重试，文件恢复后自动加载）", .{ std.fs.path.basename(inst.pluginPath()), @errorName(e) });
                }
                continue;
            };
            inst.fail_wait = 0;
            // 回填类 CID（身份：重绑定自愈/存档）
            _ = inst.plugin.?.cidHex(&inst.plugin_cid);
            inst.plugin_cid_len = 32;
            // 捕获复用：新载实例状态未知 → 登记脏（下次历史捕获现取）
            app.markSlotStateDirty(.{ .kind = .instrument, .a = @intCast(ii) });
            if (inst.load_failed) {
                inst.load_failed = false;
                app.setToastWith("乐器插件已恢复加载：{s}", .{inst.plugin.?.name()});
            } else {
                app.setToastWith("已加载乐器插件：{s}", .{inst.plugin.?.name()});
            }
            // 占位名 → 插件真名（首次加载；用户/重载过的名字不动）
            app.renamePlaceholderInstrument(ii, inst.plugin.?.name());
        }
        const pl = inst.plugin orelse continue;
        const iref = app_mod.PluginSlotRef{ .kind = .instrument, .a = @intCast(ii) };
        // 参数缓存一次建齐（撤销“参数回放”的旧值依据；restoreState 内置重建）
        if (!pl.param_cache_valid) pl.refreshParamCache();
        // 待恢复音色（工程加载/撤销恢复后首次就绪时应用一次；幂等）
        if (inst.pending_state != null or inst.pending_state_ctrl != null) {
            pl.restoreState(inst.pending_state orelse &.{}, inst.pending_state_ctrl orelse &.{});
            inst.clearPendingState(app.allocator);
            // **防挂音 panic**：恢复可能唤醒快照里仍在发声的声部（不在活跃位图）——
            // 下一段全 128 音高补 off（实测 bug：播放中调 Vital 参数后撤销 → 永挂）
            app.params.instrument_panic[ii].store(true, .release);
            // 恢复完成 = 该槽按“已采纳”处理：插件恢复后的 getState 回声字节常与存档
            // 不同（Vital 实测），若留着脏标 → 下次提交出现幽灵历史/脏标（v4 工程实症）
            app.markSlotStateClean(iref);
        }
        // 插件 GUI 内编辑 → 参数增量记录 + 手势（起手提交 + 静置钉值）
        app.drainSlotEditorEdits(iref, pl);
        if (pl.takeDirtyNotice()) app.notePluginStructural(iref);
    }
}

/// 鼓组 VST3 层的实例惰性加载/状态应用（每帧帧末；同 `syncInstrumentPlugins` 惯例）。
/// 层数量少，不做乐器级的参数缓存/编辑器增量（v1：层无插件界面）。
/// VST3 插件界面嵌入同步（每帧帧末，**决策见 `tmp/vst-ui-embed-plan.md`**）：
/// - 乐器面板（.instrument 目标）/ 效果面板（插件槽）打开 → 把插件编辑器**子窗口**
///   挂进面板内容区（面板尺寸固定 = 插件尺寸 + 自绘 chrome）；
/// - 归属对不上的编辑器（面板关闭/切目标/插件被换的残留）→ 关闭；
/// - 遮挡：其它浮动窗口（Z 高且矩形相交）或菜单/弹层（`ui` 登记的遮罩矩形）→ 隐藏。
const vst_panel_title_h: i32 = 22;
const vst_fx_row_h: i32 = 22 + 34; // 标题 + 控制行（启用开关）

fn rectsOverlap(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah;
}

/// 收集“绘制在指定面板之后（= 在其上）的窗口/弹层”中与插件内容区相交的矩形
/// （主窗口 client 坐标；`setEditorClip` 区域裁切用）。与绘制**同源**（`win_draw_info`）。
/// 上限 24 = 窗口 ≤7 + 遮罩 ≤16，不会溢出。
fn collectEditorCovers(app: *App, ui: *const Ui, panel: app_mod.WinKind, cx: i32, cy: i32, cw: i32, ch: i32, out: []vst_host.EditClipRect) usize {
    var n: usize = 0;
    var start: usize = app.win_draw_n; // 未找到自身（理论不会）：只减弹层（安全侧）
    for (app.win_draw_info[0..app.win_draw_n], 0..) |wnd, wi| {
        if (wnd.kind == panel) {
            start = wi + 1;
            break;
        }
    }
    for (app.win_draw_info[start..app.win_draw_n]) |wnd| {
        if (n >= out.len) break;
        if (intersectRect(wnd.x, wnd.y, wnd.w, wnd.h, cx, cy, cw, ch)) |r| {
            out[n] = r;
            n += 1;
        }
    }
    for (ui.overlay_rects[0..ui.overlay_n]) |r0| {
        if (n >= out.len) break;
        if (intersectRect(r0.x, r0.y, r0.w, r0.h, cx, cy, cw, ch)) |r| {
            out[n] = r;
            n += 1;
        }
    }
    return n;
}

/// 两矩形的相交矩形（分离/贴边 → null）
fn intersectRect(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) ?vst_host.EditClipRect {
    const x0 = @max(ax, bx);
    const y0 = @max(ay, by);
    const x1 = @min(ax + aw, bx + bw);
    const y1 = @min(ay + ah, by + bh);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// 打开编辑器（带失败退避）：失败后 ~2 秒内不再重试（防每帧骚扰插件）
fn ensureEditor(app: *App, pl: *vst_host.Plugin) void {
    if (pl.editor_fail_wait > 0) pl.editor_fail_wait -= 1;
    if (pl.view == null and !pl.editor_no_ui and pl.editor_fail_wait == 0) {
        if (pl.openEditor(app.main_hwnd) == .failed) pl.editor_fail_wait = 120;
    }
}

/// 收集当前打开的插件编辑器子窗口（句柄 + 主窗 client 坐标位置）——`window.present`
/// 按**其当前可见区域**（`GetWindowRgn`——已含 `setEditorClip` 的遮挡裁切）从回写中排除。
/// 归属判定与 `syncPluginEditors` 同源；同一时刻最多 2 个（乐器面板 + 效果面板各一）。
fn collectEditorPresents(app: *App, win: *window.Window) void {
    win.exclude_n = 0;
    if (app.synth_win.open) {
        switch (app.synth_win.target) {
            .instrument => |ii| {
                if (ii >= 0 and ii < app.instruments.items.len) {
                    const inst = &app.instruments.items[@intCast(ii)];
                    if (inst.kind == .vst3) {
                        if (inst.plugin) |pl| {
                            if (pl.editorPresentInfo()) |info| {
                                win.exclude_hwnd[win.exclude_n] = info.hwnd;
                                win.exclude_pos[win.exclude_n] = .{ info.x, info.y, info.w, info.h };
                                win.exclude_n += 1;
                            }
                        }
                    }
                }
            },
            .kit_layer_replace => |ref| {
                if (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| {
                    if (ly.kind == .vst3) {
                        if (ly.plugin) |pl| {
                            if (pl.editorPresentInfo()) |info| {
                                win.exclude_hwnd[win.exclude_n] = info.hwnd;
                                win.exclude_pos[win.exclude_n] = .{ info.x, info.y, info.w, info.h };
                                win.exclude_n += 1;
                            }
                        }
                    }
                }
            },
        }
    }
    if (app.mixer_win.panel) |panel| {
        if (panel.ch < app.mixer_channels_state.items.len) {
            const mc = &app.mixer_channels_state.items[panel.ch];
            if (panel.slot < mc.effects.items.len) {
                const es = &mc.effects.items[panel.slot];
                if (es.kind == .plugin) {
                    if (es.plugin) |pl| {
                        if (pl.editorPresentInfo()) |info| {
                            win.exclude_hwnd[win.exclude_n] = info.hwnd;
                            win.exclude_pos[win.exclude_n] = .{ info.x, info.y, info.w, info.h };
                            win.exclude_n += 1;
                        }
                    }
                }
            }
        }
    }
}

fn syncPluginEditors(app: *App, ui: *Ui, fw: i32, fh: i32) void {
    // 期望挂载：乐器面板（.instrument 目标 + VST3）/ 效果面板（插件槽）
    var instr_pl: ?*vst_host.Plugin = null;
    if (app.synth_win.open) {
        switch (app.synth_win.target) {
            .instrument => |ii| {
                if (ii >= 0 and ii < app.instruments.items.len) {
                    const inst = &app.instruments.items[@intCast(ii)];
                    if (inst.kind == .vst3) instr_pl = inst.plugin;
                }
            },
            .kit_layer_replace => |ref| {
                // 鼓组 VST3 层：同槽位面板托管插件界面
                if (app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| {
                    if (ly.kind == .vst3) instr_pl = ly.plugin;
                }
            },
        }
    }
    var fx_pl: ?*vst_host.Plugin = null;
    if (app.mixer_win.panel) |panel| {
        if (panel.ch < app.mixer_channels_state.items.len) {
            const mc = &app.mixer_channels_state.items[panel.ch];
            if (panel.slot < mc.effects.items.len) {
                const es = &mc.effects.items[panel.slot];
                if (es.kind == .plugin) fx_pl = es.plugin;
            }
        }
    }

    // 1) 归属对不上的编辑器：关闭（面板关闭/切目标/插件被换的残留）
    for (app.instruments.items) |*inst| {
        if (inst.plugin) |pl| {
            if (pl.view != null and pl != instr_pl and pl != fx_pl) pl.closeEditor();
        }
        if (inst.kit) |kit| {
            for (kit.pads.items) |*pad| {
                for (pad.layers.items) |*ly| {
                    if (ly.kind != .vst3) continue;
                    if (ly.plugin) |pl| {
                        if (pl.view != null and pl != instr_pl and pl != fx_pl) pl.closeEditor();
                    }
                }
            }
        }
    }
    for (app.mixer_channels_state.items) |*mc| {
        for (mc.effects.items) |*es| {
            if (es.kind == .plugin) {
                if (es.plugin) |pl| {
                    if (pl.view != null and pl != instr_pl and pl != fx_pl) pl.closeEditor();
                }
            }
        }
    }

    // 2) 乐器面板：尺寸固定=插件尺寸；坐标同步；遮挡则隐藏
    if (instr_pl) |pl| {
        ensureEditor(app, pl);
        if (pl.view != null) {
            app.synth_win.w = pl.editor_w + 2;
            app.synth_win.h = pl.editor_h + vst_panel_title_h + 1;
            // 保险钳制：拖拽途中面板 x/y 可能瞬时未钳制（顶部 clamp 下帧才生效）——
            // 子窗口绝不能比面板 chrome 更早跑出去（用户实测“插件 UI 跑出去”）
            const cx = std.math.clamp(app.synth_win.x + 1, 0, @max(0, fw - pl.editor_w - 1));
            const cy = std.math.clamp(app.synth_win.y + vst_panel_title_h, 0, @max(0, fh - pl.editor_h - 1));
            pl.syncEditorRect(cx, cy);
            // 区域裁切（见 `setEditorClip`）：减去所有画在面板之上的窗口/弹层矩形
            var covers: [24]vst_host.EditClipRect = undefined;
            const nc = collectEditorCovers(app, ui, .synth, cx, cy, pl.editor_w, pl.editor_h, &covers);
            pl.setEditorClip(covers[0..nc]);
            // 输入闸门：模态框/菜单展开期间禁用子窗口（点击不落到插件上）
            pl.setEditorEnabled(app.modal == null and ui.overlay_n == 0);
        }
    }

    // 3) 效果面板（保留顶部控制行：启用开关）
    if (fx_pl) |pl| {
        ensureEditor(app, pl);
        if (pl.view != null) {
            app.effect_win.w = pl.editor_w + 2;
            app.effect_win.h = pl.editor_h + vst_fx_row_h + 1;
            // 保险钳制（同乐器侧）
            const cx = std.math.clamp(app.effect_win.x + 1, 0, @max(0, fw - pl.editor_w - 1));
            const cy = std.math.clamp(app.effect_win.y + vst_fx_row_h, 0, @max(0, fh - pl.editor_h - 1));
            pl.syncEditorRect(cx, cy);
            // 区域裁切（见 `setEditorClip`）：减去所有画在面板之上的窗口/弹层矩形
            var covers: [24]vst_host.EditClipRect = undefined;
            const nc = collectEditorCovers(app, ui, .effect, cx, cy, pl.editor_w, pl.editor_h, &covers);
            pl.setEditorClip(covers[0..nc]);
            // 输入闸门：模态框/菜单展开期间禁用子窗口（点击不落到插件上）
            pl.setEditorEnabled(app.modal == null and ui.overlay_n == 0);
        }
    }
}

/// VST3 插件槽同步（每帧帧末）：
/// 1) 退役实例倒计时释放（见 App.retirePlugin）；
/// 2) 有路径、无实例的槽 → 惰性加载（导入存档/撤销恢复后的场景）；
/// 3) 实例就绪后应用 `pending_state`（工程加载恢复的参数/状态）；
/// 4) 轮询插件 GUI 内的参数编辑（→ 标脏）与 restart 请求（延迟变化）。
fn syncPluginSlots(app: *App) void {
    app.reapRetiredPlugins();
    app.reapRetiredFx();
    const sr: f64 = @floatFromInt(@max(1, app.params.sample_rate));
    for (app.mixer_channels_state.items, 0..) |*mc, ci| {
        for (mc.effects.items, 0..) |*es, si| {
            if (es.kind != .plugin) continue;
            if (es.plugin == null) {
                if (es.pluginPath().len == 0) continue;
                if (es.fail_wait > 0) {
                    es.fail_wait -= 1;
                    continue;
                }
                es.fail_wait = plugin_retry_frames;
                const pz = app.allocator.dupeZ(u8, es.pluginPath()) catch continue;
                defer app.allocator.free(pz);
                es.plugin = vst_host.loadEffect(app.allocator, pz, sr, 4096) catch |e| {
                    if (!es.load_failed) {
                        es.load_failed = true;
                        app.setToastWith("插件“{s}”加载失败：{s}（将自动重试，文件恢复后自动加载）", .{ std.fs.path.basename(es.pluginPath()), @errorName(e) });
                    }
                    continue;
                };
                es.fail_wait = 0;
                // 回填类 CID（身份：重绑定自愈/存档）
                _ = es.plugin.?.cidHex(&es.plugin_cid);
                es.plugin_cid_len = 32;
                // 捕获复用：新载实例状态未知 → 登记脏
                app.markSlotStateDirty(.{ .kind = .fx, .a = @intCast(ci), .b = @intCast(si) });
                if (es.load_failed) {
                    es.load_failed = false;
                    app.setToastWith("插件已恢复加载：{s}", .{es.plugin.?.name()});
                }
            }
            const pl = es.plugin orelse continue;
            const fref = app_mod.PluginSlotRef{ .kind = .fx, .a = @intCast(ci), .b = @intCast(si) };
            // 参数缓存一次建齐（撤销“参数回放”的旧值依据；restoreState 内置重建）
            if (!pl.param_cache_valid) pl.refreshParamCache();
            // 待恢复状态（工程加载/撤销恢复后首次就绪时应用一次）
            if (es.pending_state != null or es.pending_state_ctrl != null) {
                pl.restoreState(
                    if (es.pending_state) |b| b else &.{},
                    if (es.pending_state_ctrl) |b| b else &.{},
                );
                es.clearPendingState(app.allocator);
                // 恢复完成 = 按“已采纳”处理（同乐器侧：插件回声字节不算编辑）
                app.markSlotStateClean(fref);
            }
            // 插件 GUI 内的编辑 → 参数增量记录 + 手势（起手提交 + 静置钉值）
            app.drainSlotEditorEdits(fref, pl);
            // restart 请求：延迟变化 → 重读；结构/参数变化 → 结构信号（宽限期内忽略——
            // 加载/状态恢复/开窗后插件通常会补发一轮）
            const flags = pl.takeRestartFlags();
            if (flags != 0) {
                if (flags & vst_host.kLatencyChanged != 0) pl.refreshLatency();
                if (pl.restart_grace == 0 and (flags & vst_host.kDirtyRestartFlags) != 0) {
                    app.notePluginStructural(fref);
                }
            }
            if (pl.restart_grace > 0) pl.restart_grace -= 1;
            // 状态哈希监视（编辑器打开期间每 ~60 帧）：捕捉无任何通知的结构改动
            // （实测：GuitarD 改单块连线既不 setDirty 也不 restart）
            if (pl.editorOpen()) {
                pl.hash_tick +%= 1;
                if (pl.hash_tick >= 60) {
                    pl.hash_tick = 0;
                    if (pl.sampleStateHash(app.allocator)) |h| {
                        if (pl.hash_armed) {
                            if (h != pl.last_state_hash) {
                                pl.last_state_hash = h;
                                app.notePluginStructural(fref);
                            }
                        } else {
                            pl.last_state_hash = h; // 首次采样：播种（不标脏）
                            pl.hash_armed = true;
                        }
                    }
                }
            } else if (pl.hash_armed) {
                pl.hash_armed = false; // 关编辑器：复位，下次打开重新播种
            }
            // 插件声明“文档已脏”（IComponentHandler2::setDirty）→ 结构信号
            if (pl.takeDirtyNotice()) app.notePluginStructural(fref);
            // 插件请求打开编辑器（帧末：UI 线程）
            if (pl.takeOpenEditorRequest()) app.openPanelForPlugin(pl);
        }
    }
    // 编辑器关闭 → 手势结束（把最终值钉住）
    var open_now: usize = 0;
    for (app.mixer_channels_state.items) |*mc| {
        for (mc.effects.items) |*es| {
            if (es.plugin) |pl| {
                if (pl.editorOpen()) open_now += 1;
            }
        }
    }
    if (open_now < app.editors_open_prev) app.pinPendingGesture();
    app.editors_open_prev = open_now;
}

// ── 插件管理：文件夹/文件选择 + 扫描 worker（进程）──
//
// 扫描 = 独立 worker 进程（**自身 exe** `--vst-scan --jsonl`，同二进制自举）：
// 坏插件崩的是它，主进程零污染；
// 进度/崩溃定位靠 JSONL（孤立 `start` 行）——协议见 `vst_scan.zig`。
// 进程走 Win32 直调（`CREATE_NO_WINDOW` 不闪控制台；不依赖 std.process 形态）。

/// 数据目录（空 = 未解析——插件管理功能禁用）
fn pluginDataRoot(app: *const App) ?[]const u8 {
    if (app.data_root_len == 0) return null;
    return app.data_root_buf[0..app.data_root_len];
}

/// 「+ 添加文件夹…」：文件夹选择框 → 存入配置（去重）
fn pickPluginFolder(app: *App, win: *window.Window) void {
    if (pluginDataRoot(app) == null) {
        app.setToast("数据目录不可用");
        return;
    }
    const picked = filedialog.pickFolder(app.allocator, win.hwnd, "选择 VST3 插件文件夹") catch |e| {
        app.setToastWith("文件夹选择出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse return;
    defer app.allocator.free(path);
    const cfg = if (app.plugin_cfg) |*c| c else return;
    const added = cfg.addFolder(path) catch false;
    if (added) {
        app.plugin_cfg_dirty = true;
        app.setToastWith("已添加扫描文件夹：{s}", .{path});
    } else {
        app.setToast("该文件夹已在列表中");
    }
}

/// 「+ 添加文件…」：单文件条目（兜底：不在任何扫描文件夹里的插件）
fn pickPluginFile(app: *App, win: *window.Window) void {
    if (pluginDataRoot(app) == null) {
        app.setToast("数据目录不可用");
        return;
    }
    const picked = filedialog.open(app.allocator, win.hwnd, "选择 VST3 插件文件", filedialog.vst3_filter) catch |e| {
        app.setToastWith("文件选择出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse return;
    defer app.allocator.free(path);
    const cfg = if (app.plugin_cfg) |*c| c else return;
    const added = cfg.addFile(path) catch false;
    if (added) {
        app.plugin_cfg_dirty = true;
        app.setToastWith("已添加插件文件（重新扫描后出现在结果中）：{s}", .{std.fs.path.basename(path)});
    } else {
        app.setToast("该文件已在列表中");
    }
}

/// 手动重新定位（右键「重新定位插件…」→ 帧末弹框；pending 状态保留）
fn relocateInstrumentDialog(app: *App, win: *window.Window, ii: usize) void {
    const picked = filedialog.open(app.allocator, win.hwnd, "重新定位 VST3 乐器插件", filedialog.vst3_filter) catch |e| {
        app.setToastWith("文件选择出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse return;
    defer app.allocator.free(path);
    app.relocateInstrument(@intCast(ii), path);
}

fn relocateEffectDialog(app: *App, win: *window.Window, ch: usize, slot: usize) void {
    const picked = filedialog.open(app.allocator, win.hwnd, "重新定位 VST3 效果器插件", filedialog.vst3_filter) catch |e| {
        app.setToastWith("文件选择出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse return;
    defer app.allocator.free(path);
    app.relocateEffect(ch, slot, path);
}

const scan_no_window: u32 = 0x0800_0000;
const still_active: u32 = 259; // STILL_ACTIVE
/// 看门狗：约 15s（@120fps）无新进度 → 杬掉 worker（防被外部弹框卡死）
const scan_watchdog_frames: u32 = 1800;

const STARTUPINFOW = extern struct {
    cb: u32 = 0,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?[*]u8 = null,
    hStdInput: ?*anyopaque = null,
    hStdOutput: ?*anyopaque = null,
    hStdError: ?*anyopaque = null,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque = null,
    hThread: ?*anyopaque = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) i32;
extern "kernel32" fn GetExitCodeProcess(*anyopaque, *u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(*anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) i32;

fn appendUtf16(list: *std.ArrayListUnmanaged(u16), alloc: std.mem.Allocator, s: []const u8) !void {
    if (s.len == 0) return;
    const need = try std.unicode.calcUtf16LeLen(s);
    const old = list.items.len;
    try list.resize(alloc, old + need);
    _ = try std.unicode.utf8ToUtf16Le(list.items[old..], s);
}

fn appendUtf16Quoted(list: *std.ArrayListUnmanaged(u16), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    try appendUtf16(list, alloc, s);
    try list.append(alloc, '"');
}

/// 「开始扫描」：spawn **自身 exe**（`Sawdust.exe --vst-scan --jsonl <数据目录>/scan_tmp.jsonl <根...>`）。
/// 根 = 启用的文件夹 + 单文件；路径全部加引号（Program Files 含空格）。
fn startPluginScan(app: *App, io: std.Io) void {
    const pm = &app.plugin_mgr;
    if (pm.scanning) return;
    const root = pluginDataRoot(app) orelse {
        app.setToast("数据目录不可用");
        return;
    };
    const cfg = if (app.plugin_cfg) |*c| c else return;

    var roots: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer roots.deinit(app.allocator);
    for (cfg.folders.items) |f| {
        if (f.enabled and f.path.len > 0) roots.append(app.allocator, f.path) catch {};
    }
    for (cfg.files.items) |p| {
        if (p.len > 0) roots.append(app.allocator, p) catch {};
    }
    if (roots.items.len == 0) {
        app.setToast("没有可扫描的文件夹/文件——请先添加");
        return;
    }

    // 扫描 worker = **自身 exe**（--vst-scan 自举）；不再依赖单独构建的 vstscan.exe
    var exe_buf: [1200]u8 = undefined;
    const exe_path = selfExePath(app.allocator, &exe_buf);
    if (exe_path.len == 0) {
        app.setToast("无法定位程序路径");
        return;
    }

    var out_buf: [640]u8 = undefined;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}/scan_tmp.jsonl", .{root}) catch return;
    std.Io.Dir.cwd().createDirPath(io, root) catch {};
    std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var cmd: std.ArrayListUnmanaged(u16) = .{ .items = &.{}, .capacity = 0 };
    defer cmd.deinit(app.allocator);
    appendUtf16Quoted(&cmd, app.allocator, exe_path) catch return;
    appendUtf16(&cmd, app.allocator, " --vst-scan --jsonl ") catch return;
    appendUtf16Quoted(&cmd, app.allocator, out_path) catch return;
    for (roots.items) |r| {
        appendUtf16(&cmd, app.allocator, " ") catch return;
        appendUtf16Quoted(&cmd, app.allocator, r) catch return;
    }
    const cmd_z = cmd.toOwnedSliceSentinel(app.allocator, 0) catch return;
    defer app.allocator.free(cmd_z);

    var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW) };
    var pi = PROCESS_INFORMATION{};
    if (CreateProcessW(null, cmd_z.ptr, null, null, 0, scan_no_window, null, null, &si, &pi) == 0) {
        app.setToast("无法启动扫描进程（自身 exe 自举失败）");
        return;
    }
    if (pi.hThread) |h| _ = CloseHandle(h);
    pm.scan_handle = pi.hProcess;
    pm.scanning = true;
    pm.scan_discard = false;
    pm.scan_ok = 0;
    pm.scan_err = 0;
    pm.scan_total = 0;
    pm.scan_current_len = 0;
    pm.scan_frame = 0;
    pm.scan_idle = 0;
    const n = @min(out_path.len, pm.scan_out_buf.len);
    @memcpy(pm.scan_out_buf[0..n], out_path[0..n]);
    pm.scan_out_len = n;
    app.setToast("插件扫描开始…（可手动取消）");
}

/// 「取消扫描」：置丢弃标记 + 杀 worker（收尾在 `pollPluginScan`——统一出口）
fn cancelPluginScan(app: *App) void {
    const pm = &app.plugin_mgr;
    if (!pm.scanning) return;
    pm.scan_discard = true; // 用户取消：保留旧缓存，不落部分结果
    if (pm.scan_handle) |h| _ = TerminateProcess(h, 1);
    app.setToast("扫描已取消");
}

/// 每帧帧末：读进度（每 8 帧）+ 看门狗 + 退出检测
fn pollPluginScan(app: *App, io: std.Io) void {
    const pm = &app.plugin_mgr;
    if (!pm.scanning) return;
    pm.scan_frame +%= 1;
    if (pm.scan_frame % 8 == 0) {
        const path = pm.scan_out_buf[0..pm.scan_out_len];
        if (std.Io.Dir.cwd().readFileAlloc(io, path, app.allocator, .limited(64 * 1024 * 1024))) |data| {
            defer app.allocator.free(data);
            if (updateScanProgress(pm, data)) pm.scan_idle = 0 else pm.scan_idle +%= 8;
        } else |_| {
            pm.scan_idle +%= 8;
        }
    }
    if (pm.scan_idle > scan_watchdog_frames) {
        pm.scan_idle = 0;
        if (pm.scan_handle) |h| _ = TerminateProcess(h, 2);
        app.setToast("扫描进程长时间无响应，已强行结束（保留部分结果）");
    }
    if (pm.scan_handle) |h| {
        var code: u32 = 0;
        if (GetExitCodeProcess(h, &code) != 0 and code != still_active) {
            finishPluginScan(app, io, code);
        }
    }
}

/// 从 JSONL 文本重数进度（oi/err/总数/当前路径）；返回是否有变化（看门狗用）
fn updateScanProgress(pm: *@import("app.zig").PluginMgrWindow, data: []const u8) bool {
    var ok: usize = 0;
    var err: usize = 0;
    var total: usize = 0;
    var last_start: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "{\"t\":\"begin\"")) {
            if (std.mem.indexOf(u8, line, "\"n\":")) |i| {
                const rest = line[i + 4 ..];
                const end = std.mem.indexOfAny(u8, rest, "},") orelse rest.len;
                total = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " "), 10) catch 0;
            }
        } else if (std.mem.startsWith(u8, line, "{\"t\":\"start\"")) {
            if (std.mem.indexOf(u8, line, "\"path\":\"")) |i| {
                const rest = line[i + 8 ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                last_start = rest[0..end];
            }
        } else if (std.mem.startsWith(u8, line, "{\"t\":\"ok\"")) {
            ok += 1;
        } else if (std.mem.startsWith(u8, line, "{\"t\":\"err\"")) {
            err += 1;
        }
    }
    var changed = pm.scan_ok != ok or pm.scan_err != err or pm.scan_total != total;
    pm.scan_ok = ok;
    pm.scan_err = err;
    pm.scan_total = total;
    // 当前路径：轻量还原 JSON 转义（`\\` → `\`、`\"` → `"`）供显示
    if (last_start.len > 0) {
        var tmp: [260]u8 = undefined;
        var n: usize = 0;
        var j: usize = 0;
        while (j < last_start.len and n < tmp.len) : (j += 1) {
            if (last_start[j] == '\\' and j + 1 < last_start.len and
                (last_start[j + 1] == '\\' or last_start[j + 1] == '"'))
            {
                tmp[n] = last_start[j + 1];
                n += 1;
                j += 1;
                continue;
            }
            tmp[n] = last_start[j];
            n += 1;
        }
        if (!std.mem.eql(u8, tmp[0..n], pm.scan_current_buf[0..pm.scan_current_len])) changed = true;
        @memcpy(pm.scan_current_buf[0..n], tmp[0..n]);
        pm.scan_current_len = n;
    }
    return changed;
}

/// 扫描收尾：句柄回收 → 解析 JSONL → 存缓存并换入 → toast。
/// 用户取消（`scan_discard`）→ 只清进度文件，保留旧缓存；崩溃/看门狗杀 →
/// 保留部分结果（孤立 start → `crashed_after` 在管理器里红字提示）。
fn finishPluginScan(app: *App, io: std.Io, exit_code: u32) void {
    const pm = &app.plugin_mgr;
    if (pm.scan_handle) |h| {
        _ = CloseHandle(h);
        pm.scan_handle = null;
    }
    pm.scanning = false;
    pm.scan_current_len = 0;
    const path = pm.scan_out_buf[0..pm.scan_out_len];
    if (pm.scan_discard) {
        pm.scan_discard = false;
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return; // 取消：保留旧缓存（toast 已在取消时提示）
    }
    const root = pluginDataRoot(app) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, app.allocator, .limited(64 * 1024 * 1024)) catch {
        app.setToastWith("扫描结果读取失败（退出码 {d}）", .{exit_code});
        return;
    };
    defer app.allocator.free(data);
    var c = plugin_db.Cache.parseJsonl(app.allocator, data);
    c.scanned_at = plugin_db.unixTime();
    c.save(io, root) catch app.setToast("扫描缓存保存失败");
    if (app.plugin_cache) |*old| old.deinit();
    app.plugin_cache = c;
    scanPresets(app, io); // 缓存变化 → 合成 VST3 分类立即进预设面板
    const cache = &app.plugin_cache.?;
    if (cache.crashed_after) |cp| {
        app.setToastWith("扫描完成（可用 {d} · 失败 {d}）；{s} 使扫描进程崩溃——已跳过", .{ cache.okCount(), cache.errCount(), std.fs.path.basename(cp) });
    } else {
        app.setToastWith("扫描完成：可用 {d} · 失败 {d}", .{ cache.okCount(), cache.errCount() });
    }
    // 重绑定自愈：失败槽按记录的 CID 匹配到扫描到的新路径（只碰失败槽；同路径不动）
    const healed = app.reboundFailedPluginSlots(io);
    if (healed > 0) app.setToastWith("已自动重新定位 {d} 个失败插件（扫描找到新路径）", .{healed});
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// 读取设置（缺失/损坏 → 默认值，静默）。“启动打开上次工程”走既有
/// `pending_open_path` 机制（首帧末自动执行；启动时 dirty=false 无确认弹窗）。
fn loadSettings(app: *App, io: std.Io) void {
    const spath = settingsPath(app) orelse return;
    defer app.allocator.free(spath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, spath, app.allocator, .unlimited) catch return;
    defer app.allocator.free(data);
    var parsed = persist.settingsFromJson(app.allocator, data) catch return;
    defer parsed.deinit();
    app.settings_open_last = parsed.value.open_last;
    app.fps_limit = std.math.clamp(parsed.value.fps, 30, 240);
    if (parsed.value.open_last and parsed.value.last_project.len > 0) {
        app.setPendingOpen(parsed.value.last_project);
    }
}

/// 写入设置（静默失败；下一步变更会重试）
fn saveSettings(app: *App, io: std.Io) void {
    const spath = settingsPath(app) orelse return;
    defer app.allocator.free(spath);
    const json = persist.settingsToJson(app.allocator, .{
        .open_last = app.settings_open_last,
        .fps = app.fps_limit,
        .last_project = app.project_path orelse "",
    }) catch return;
    defer app.allocator.free(json);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spath, .data = json }) catch return;
}

/// 备份名：`x.saw` → `x.bak.saw`（已存在 → `x.bak2.saw`…；无 `.saw` 后缀则追加 `.bak.saw`）
fn uniqueBackupPath(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const base = if (std.mem.endsWith(u8, path, ".saw")) path[0 .. path.len - 4] else path;
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const cand = if (n == 1)
            std.fmt.bufPrint(buf, "{s}.bak.saw", .{base}) catch return null
        else
            std.fmt.bufPrint(buf, "{s}.bak{d}.saw", .{ base, n }) catch return null;
        if (cwd.access(io, cand, .{})) |_| {
            continue; // 已存在 → 下一个序号
        } else |_| {
            return cand; // 不存在 → 可用
        }
    }
    return null;
}

/// 执行旧档升级（弹窗确认后）：读 → 内存迁移（parseAuto 链）→ import →
/// 写 `.tmp` → 原件重命名 `.bak.saw`（碰撞加序号）→ `.tmp` 回原路径。
/// 危险窗口 = 两次相邻重命名之间；任一步失败 → 保留原件、清理 tmp、toast 报错。
fn performUpgrade(app: *App, io: std.Io) void {
    const path = app.pending_upgrade_path orelse return;
    const cwd = std.Io.Dir.cwd();

    const data = cwd.readFileAlloc(io, path, app.allocator, .unlimited) catch |e| {
        app.setToastWith("升级失败：读取失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    defer app.allocator.free(data);

    var parsed = persist.parseAuto(app.allocator, data) catch |e| {
        app.setToastWith("升级失败：解析失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    defer parsed.deinit();

    app.importProject(parsed.value);

    const project = app.exportProject() catch |e| {
        app.setToastWith("升级失败：导出失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    defer app.freeProject(project);
    const bytes = persist.toBinary(app.allocator, project) catch |e| {
        app.setToastWith("升级失败：序列化失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    defer app.allocator.free(bytes);

    // 1) 写 .tmp（同目录）
    var tmp_buf: [1080]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch {
        app.setToast("升级失败：路径过长");
        app.clearPendingUpgrade();
        return;
    };
    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes }) catch |e| {
        app.setToastWith("升级失败：写入临时文件失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    // 2) 原件 → 备份名（重命名，不复制——危险窗口最小）
    var bak_buf: [1100]u8 = undefined;
    const bak = uniqueBackupPath(io, path, &bak_buf) orelse {
        cwd.deleteFile(io, tmp_path) catch {};
        app.setToast("升级失败：无法确定备份名");
        app.clearPendingUpgrade();
        return;
    };
    cwd.rename(path, cwd, bak, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        app.setToastWith("升级失败：备份重命名失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };
    // 3) .tmp → 原路径
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        // 尝试回滚（备份改回原名）；回滚失败则原文件仍在备份名下，不丢数据
        cwd.rename(bak, cwd, path, io) catch {};
        app.setToastWith("升级失败：替换失败（{s}）", .{@errorName(e)});
        app.clearPendingUpgrade();
        return;
    };

    app.setProjectPath(path);
    app.resetHistory("打开工程（已升级）");
    app.markSaved();
    app.setToastWith("已升级为 v5 并备份到 {s}", .{bak});
    app.clearPendingUpgrade();
}

/// 从指定路径加载并替换当前工程（失败时保留当前工程不变）
fn loadProjectFromPath(app: *App, io: std.Io, path: []const u8) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, app.allocator, .unlimited) catch |e| {
        app.setToastWith("打开失败：读取失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(data);

    // v5 二进制 = 当前格式，直接加载。JSON（v1–v4）探针版本：
    // v1–v3 旧档走“备份并升级”弹窗（③ 迁移流程）；过新拒绝；v4 直接加载。
    if (!(data.len >= persist.binary_magic.len and std.mem.eql(u8, data[0..persist.binary_magic.len], persist.binary_magic))) {
        if (persist.probeJsonVersion(app.allocator, data)) |ver| {
            if (ver > persist.file_version) {
                app.setToastWith("打开失败：存档版本过新（v{d}），请使用更新的 Sawdust", .{ver});
                return;
            }
            if (ver < persist.file_version) {
                app.setPendingUpgrade(path, ver);
                app.modal = .save_upgrade;
                app.modal_choice = null;
                return; // 等弹窗确认（performUpgrade）；取消 = 不打开（原文件不动）
            }
        }
    }

    const parsed = persist.parseAuto(app.allocator, data) catch |e| {
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

/// JSON 过滤器（描述\0通配\0…；与 project_filter 同格式）
const json_filter = "JSON 文件 (*.json)\x00*.json\x00所有文件 (*.*)\x00*.*\x00";

/// 导入 JSON（可读/迁移格式；与“打开”同流程——旧档同样走备份升级弹窗）
fn importJsonWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    const picked = filedialog.open(app.allocator, win.hwnd, "导入 JSON（可读/迁移格式）", json_filter) catch |e| {
        app.setToastWith("导入失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消导入");
        return;
    };
    defer app.allocator.free(path);
    loadProjectFromPath(app, io, path);
}

/// 导出 JSON（可读文本格式，便于迁移到其他 DAW）——不改变当前工程路径/保存态
fn exportJsonWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    const picked = filedialog.save(app.allocator, win.hwnd, "导出 JSON（可读/迁移格式）", "song.json", json_filter) catch |e| {
        app.setToastWith("导出失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消导出");
        return;
    };
    defer app.allocator.free(path);

    const project = app.exportProject() catch |e| {
        app.setToastWith("导出失败：导出失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.freeProject(project);
    const json = persist.toJson(app.allocator, project) catch |e| {
        app.setToastWith("导出失败：序列化失败（{s}）", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(json);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch |e| {
        app.setToastWith("导出失败：写入失败（{s}）", .{@errorName(e)});
        return;
    };
    app.setToastWith("已导出 JSON（可读格式）：{s}", .{path});
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
        .channel_pan = app.exportChannelPans(), // 通道声像 = 乐器声像（音符级不导出）
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

/// 导出音频（WAV, 24-bit）/ 整曲**离线渲染**：停播 + 暂停设备 → 快照 → 逐块渲染写盘。
/// 默认文件名 = 工程名.wav（新建未保存的工程 → Sawdust.wav）。
fn exportWavWithDialog(app: *App, win: *window.Window, io: std.Io) void {
    var name_buf: [300]u8 = undefined;
    const default_name = blk: {
        if (app.project_path) |p| {
            const base = std.fs.path.basename(p);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
            if (stem.len > 0 and stem.len < 290) break :blk std.fmt.bufPrint(&name_buf, "{s}.wav", .{stem}) catch "Sawdust.wav";
        }
        break :blk "Sawdust.wav";
    };
    const picked = filedialog.save(app.allocator, win.hwnd, "导出音频 (WAV)", default_name, filedialog.wav_filter) catch |e| {
        app.setToastWith("导出失败：对话框出错（{s}）", .{@errorName(e)});
        return;
    };
    const path = picked orelse {
        if (filedialog.supported()) app.setToast("已取消导出");
        return;
    };
    defer app.allocator.free(path);

    app.exportWavBegin(io, path) catch |e| {
        app.setToastWith("导出失败：{s}", .{@errorName(e)});
        return;
    };
    // 进度/取消/完成收尾由主循环的导出状态机负责（`exportWavFrame` + `drawExportDialog`）
}

/// 导出进度窗（模态；绘于最上层）。进度条 + 取消按钮；标题可拖动（位置记忆在
/// `app.export_win`）。完成/取消后状态机清理 `export_wav` → 本窗自动消失。
fn drawExportDialog(ui: *Ui, app: *App, io: std.Io) void {
    const ww: i32 = 430;
    const hh: i32 = 118;
    const win_w = @as(i32, @intCast(ui.renderer.fb.width));
    const win_h = @as(i32, @intCast(ui.renderer.fb.height));
    const ew = &app.export_win;
    if (ew.x == -100000) { // 首帧：居中偏上
        ew.x = @divTrunc(win_w - ww, 2);
        ew.y = @divTrunc(win_h - hh, 3);
    }
    ew.x = std.math.clamp(ew.x, 0, @max(0, win_w - ww));
    ew.y = std.math.clamp(ew.y, 0, @max(0, win_h - hh));
    const x = ew.x;
    const y = ew.y;

    // 半透明遮罩（同模态确认框；提示其余元素不可操作）
    ui.renderer.fillRect(0, 0, win_w, win_h, (@as(u32, 110) << 24) | 0x000000);
    ui.noteOverlayRect(x, y, ww + 4, hh + 4); // 裁切插件子窗口（仅本窗范围，含阴影）

    ui.renderer.fillRect(x + 4, y + 4, ww, hh, r_mod.rgb(10, 11, 13)); // 阴影
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题（拖动区）
    const title_bar_h: i32 = 22;
    ui.label("导出音频 (WAV)", x + 10, y + 5, ui.theme.text);
    if (util.hitUI(ui, x, y, ww, title_bar_h) and ui.mouse_pressed) {
        ui.active_id = 9800; // 导出窗标题拖动（**与插件管理器的 9700 错开**——撞车会拖着两窗一起动，实测）
        ew.grab_dx = ui.mouse_x - x;
        ew.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 9800) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            ew.x = ui.mouse_x - ew.grab_dx;
            ew.y = ui.mouse_y - ew.grab_dy;
        }
    }

    const st = if (app.export_wav) |*e| e else return;

    // 进度条
    const frac: f32 = if (st.total_frames > 0)
        @min(1.0, @as(f32, @floatFromInt(st.done)) / @as(f32, @floatFromInt(st.total_frames)))
    else
        1.0;
    const bar_x = x + 14;
    const bar_w = ww - 28;
    const bar_y = y + 32;
    const bar_h: i32 = 14;
    ui.renderer.fillRect(bar_x, bar_y, bar_w, bar_h, r_mod.rgb(28, 30, 34));
    ui.renderer.fillRect(bar_x, bar_y, @as(i32, @intFromFloat(frac * @as(f32, @floatFromInt(bar_w)))), bar_h, ui.theme.accent);
    ui.renderer.strokeRect(bar_x, bar_y, bar_w, bar_h, ui.theme.panel_border);

    // 百分比 + 秒数 + 实时倍速/剩余估算（t0 起算）
    const sr_f: f32 = @floatFromInt(app.params.sample_rate);
    const done_s: f32 = @as(f32, @floatFromInt(st.done)) / sr_f;
    const total_s: f32 = @as(f32, @floatFromInt(st.total_frames)) / sr_f;
    const now_ns: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    const elapsed_s: f32 = std.math.clamp(@as(f32, @floatFromInt(now_ns - st.t0_ns)) / 1e9, 0.001, 1e9);
    const rate: f32 = if (elapsed_s > 0.5) done_s / elapsed_s else 0.0; // 倍速（×实时）
    const eta_s: f32 = if (rate > 0.01) (total_s - done_s) / rate else 0.0;
    var buf: [128]u8 = undefined;
    const txt = if (rate > 0.01)
        std.fmt.bufPrint(&buf, "{d:.0}% · 已 {d:.0} / {d:.0} 秒 · {d:.1}× · 剩 ~{d:.0} 秒", .{ frac * 100.0, done_s, total_s, rate, @max(0.0, eta_s) }) catch "..."
    else
        std.fmt.bufPrint(&buf, "{d:.0}% · 已 {d:.0} / {d:.0} 秒", .{ frac * 100.0, done_s, total_s }) catch "...";
    const tw: i32 = @intFromFloat(ui.font.measure(txt));
    ui.label(txt, x + @divTrunc(ww - tw, 2), bar_y + bar_h + 5, ui.theme.text_dim);

    // 取消
    const btn_w: i32 = 96;
    const btn_h: i32 = 26;
    if (ui.button(9701, "取消导出", x + @divTrunc(ww - btn_w, 2), y + hh - btn_h - 10, btn_w, btn_h)) {
        app.exportWavCancel();
    }
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
        .pattern_delete => drawDeleteConfirm(ui, app, w, h),
            .track_clear => drawDeleteConfirm(ui, app, w, h),
            .track_delete => drawDeleteConfirm(ui, app, w, h),
        .save_upgrade => drawUpgradeConfirm(ui, app, w, h),
    }
}

/// 旧版存档升级确认框（备份并升级 / 取消）——③ 迁移流程（v1–v3 → v5 二进制）
fn drawUpgradeConfirm(ui: *Ui, app: *App, w: i32, h: i32) void {
    var l1: [96]u8 = undefined;
    const line1 = std.fmt.bufPrint(&l1, "这是旧版存档（v{d}），升级为最新格式？", .{app.pending_upgrade_version}) catch "这是旧版存档，升级？";
    const line2 = "会先备份原文件为 .bak.saw，然后原地升级。";
    const tw1: i32 = @intFromFloat(ui.font.measure(line1));
    const tw2: i32 = @intFromFloat(ui.font.measure(line2));
    const text_w = @max(tw1, tw2);
    const btn_w: i32 = 96;
    const gap: i32 = 10;
    const dlg_w = @max(text_w + 48, btn_w * 2 + gap + 32);
    const dlg_h: i32 = 110;
    const dx = @divTrunc(w - dlg_w, 2);
    const dy = @divTrunc(h - dlg_h, 2);
    ui.noteOverlayRect(dx, dy, dlg_w + 4, dlg_h + 4);

    ui.renderer.fillRect(dx + 4, dy + 4, dlg_w, dlg_h, r_mod.rgb(12, 13, 16));
    ui.renderer.fillRect(dx, dy, dlg_w, dlg_h, ui.theme.panel);
    ui.renderer.strokeRect(dx, dy, dlg_w, dlg_h, ui.theme.accent);
    ui.label(line1, dx + @divTrunc(dlg_w - tw1, 2), dy + 18, ui.theme.text);
    ui.label(line2, dx + @divTrunc(dlg_w - tw2, 2), dy + 40, ui.theme.text_dim);

    const labels = [_][]const u8{ "备份并升级", "取消" };
    const choices = [_]QuitChoice{ .save, .cancel };
    drawModalButtons(ui, app, dx, dy, dlg_w, dlg_h, &labels, &choices, 0, 0);
}

/// 脏确认框（保存/不保存/取消）——退出或打开其它工程前
fn drawDirtyConfirm(ui: *Ui, app: *App, w: i32, h: i32) void {
    // 文案随场景变化（退出 vs 打开其他工程）
    const line2 = switch (app.dirty_intent orelse .quit) {
        .open => "是否保存后再打开其他工程？",
        .new => "是否保存后再新建空工程？",
        .quit => "是否保存后再退出？",
    };
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
    ui.noteOverlayRect(dx, dy, dlg_w + 4, dlg_h + 4); // 裁切插件子窗口（含阴影；仅对话框范围）

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
    ui.noteOverlayRect(dx, dy, dlg_w + 4, dlg_h + 4); // 裁切插件子窗口（含阴影；仅对话框范围）

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
    ui.noteOverlayRect(dx, dy, dlg_w + 4, dlg_h + 4); // 裁切插件子窗口（含阴影；仅对话框范围）

    ui.renderer.fillRect(dx + 4, dy + 4, dlg_w, dlg_h, r_mod.rgb(12, 13, 16));
    ui.renderer.fillRect(dx, dy, dlg_w, dlg_h, ui.theme.panel);
    ui.renderer.strokeRect(dx, dy, dlg_w, dlg_h, ui.theme.accent);
    ui.label(line1, dx + @divTrunc(dlg_w - tw1, 2), dy + 18, ui.theme.text);
    ui.label(line2, dx + @divTrunc(dlg_w - tw2, 2), dy + 40, ui.theme.text_dim);

    const labels = [_][]const u8{ if (app.modal == .track_clear) "清空" else "删除", "取消" };
    const choices = [_]QuitChoice{ .save, .cancel };
    drawModalButtons(ui, app, dx, dy, dlg_w, dlg_h, &labels, &choices, 0, 1); // 删除/清空为主（红色）
}

/// 删除/清空确认（非空样式 / 轨道）——确认后由主循环的选择消费点执行（同样式的删除/取消）。
fn drawDeleteConfirm(ui: *Ui, app: *App, w: i32, h: i32) void {
    const req = app.struct_del_req orelse return;
    var l1: [128]u8 = undefined;
    var l2: [160]u8 = undefined;
    var line1: []const u8 = "删除？";
    var line2: []const u8 = "此操作可 Ctrl+Z 撤销。";
    switch (req) {
        .pattern => |pi| {
            const name = if (pi < app.pattern_items.items.len) app.pattern_items.items[pi] else "?";
            const short = name[0..@min(name.len, 24)];
            line1 = std.fmt.bufPrint(&l1, "删除样式「{s}」？", .{short}) catch "删除样式？";
            const usage = app.patternUsage(pi);
            line2 = std.fmt.bufPrint(&l2, "该样式含 {d} 个音符、被 {d} 个片段引用；删除将一并移除（可 Ctrl+Z 撤销）。", .{ usage.notes, usage.clips }) catch "删除将一并移除内容。";
        },
        .track => |ti| {
            const name = app.trackName(ti);
            const short = name[0..@min(name.len, 24)];
            line1 = std.fmt.bufPrint(&l1, "清空轨道「{s}」？", .{short}) catch "清空轨道？";
            line2 = std.fmt.bufPrint(&l2, "该轨道上有 {d} 个片段；清空将移除这些片段（行与名字保留，可 Ctrl+Z 撤销）。", .{app.trackUsage(ti)}) catch "清空将移除这些片段。";
        },
        .track_row => |ti| {
            const name = app.trackName(ti);
            const short = name[0..@min(name.len, 24)];
            line1 = std.fmt.bufPrint(&l1, "删除轨道「{s}」？", .{short}) catch "删除轨道？";
            line2 = std.fmt.bufPrint(&l2, "该轨道上有 {d} 个片段；删除将一并移除，下方轨道整体上移（可 Ctrl+Z 撤销）。", .{app.trackUsage(ti)}) catch "删除将一并移除内容。";
        },
    }
    const tw1: i32 = @intFromFloat(ui.font.measure(line1));
    const tw2: i32 = @intFromFloat(ui.font.measure(line2));
    const text_w = @max(tw1, tw2);
    const btn_w: i32 = 84;
    const gap: i32 = 10;
    const dlg_w = @max(text_w + 48, btn_w * 2 + gap + 32);
    const dlg_h: i32 = 110;
    const dx = @divTrunc(w - dlg_w, 2);
    const dy = @divTrunc(h - dlg_h, 2);
    ui.noteOverlayRect(dx, dy, dlg_w + 4, dlg_h + 4); // 裁切插件子窗口（含阴影；仅对话框范围）

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
    _ = @import("vst_scan.zig");
    _ = @import("plugin_db.zig");
    _ = @import("ui_test.zig");
}
 test "main: 编辑器遮挡矩形相交判定（插件子窗口隐藏用）" {
    try std.testing.expect(rectsOverlap(0, 0, 10, 10, 5, 5, 10, 10));
    try std.testing.expect(rectsOverlap(5, 5, 10, 10, 0, 0, 10, 10));
    try std.testing.expect(!rectsOverlap(0, 0, 10, 10, 10, 10, 10, 10)); // 边贴边不算
    try std.testing.expect(!rectsOverlap(0, 0, 10, 10, 20, 20, 5, 5));
}
 test "main: 相交矩形计算（插件子窗口裁切覆盖集用）" {
    const r = intersectRect(0, 0, 10, 10, 5, 5, 10, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 5), r.x);
    try std.testing.expectEqual(@as(i32, 5), r.y);
    try std.testing.expectEqual(@as(i32, 5), r.w);
    try std.testing.expectEqual(@as(i32, 5), r.h);
    try std.testing.expect(intersectRect(0, 0, 10, 10, 10, 10, 10, 10) == null); // 贴边不算
    try std.testing.expect(intersectRect(0, 0, 10, 10, 20, 20, 5, 5) == null);
    const r2 = intersectRect(0, 0, 10, 10, 2, 2, 100, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 8), r2.w);
    try std.testing.expectEqual(@as(i32, 8), r2.h);
}
