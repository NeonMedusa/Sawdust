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
const synth = @import("synth.zig");
const sequencer = @import("sequencer.zig");
const model = @import("model.zig");
const util = @import("view_util.zig");
const view_playlist = @import("view_playlist.zig");
const view_pianoroll = @import("view_pianoroll.zig");
const view_rack = @import("view_rack.zig");
const view_synth = @import("view_synth.zig");
const view_panels = @import("view_panels.zig");

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
    defer app.deinitInstruments();
    // 初始片段（演示）：前 12 轨铺一些样式，每 16 小节重复（只铺 2 轮——
    // 避免演示内容把时间轴行程撑得过长，行程应贴合最右内容）
    {
        var t: i32 = 0;
        while (t < 12) : (t += 1) {
            var rep: i32 = 0;
            while (rep < 2) : (rep += 1) {
                app.addClip(.{
                    .track = t,
                    .bar = 1 + @mod(t, 6) * 2 + rep * 16,
                    .len = 2 + @mod(t, 3),
                    .pattern = @mod(t, 6),
                });
            }
        }
    }
    // 初始乐器（演示）：两个减法合成器（各自独立参数）
    // **必须在 engine.init 之前**：音频回调启动后会解引用参数/队列指针
    _ = app.addInstrument("减法合成器");
    _ = app.addInstrument("减法合成器");
    app.params.events = &app.events;
    app.params.sched_events = &app.sched_events;

    app.engine.init(&app.params, allocator) catch |e| {
        std.debug.print("音频初始化失败（{s}）：UI 仍可运行\n", .{@errorName(e)});
    };
    defer app.engine.deinit();
    app.engine.params = &app.params;

    var ui_input = InputState{};
    var ui = Ui.init(r_mod.Renderer.init(&win.fb), &font);

    while (!win.shouldQuit()) {
        ui_input.mouse_pressed = false;
        ui_input.mouse_released = false;
        ui_input.mouse_right_pressed = false;
        ui_input.mouse_double = false;
        ui_input.wheel = 0;
        ui_input.wheel_ctrl = false;

        // 1) 输入
        const events = try win.pollEvents();
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
                    ui_input.mouse_x = m.x;
                    ui_input.mouse_y = m.y;
                },
                .key_down => |k| {
                    if (k.code == 0x1B) { // Esc：钢琴卷帘中返回播放列表，否则退出
                        if (app.piano.pattern != null) {
                            app.closePiano();
                            if (ui.active_id == 6000) ui.active_id = 0; // 释放琴键试听拖动标记
                        } else {
                            win.should_quit = true;
                        }
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
                            sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, from, app.steps_per_bar);
                            app.params.sched_gen.store(app.scheduler.gen, .monotonic);
                        } else {
                            app.params.playing.store(false, .monotonic);
                        }
                    }
                },
                .resize => {},
                else => {},
            }
        }

        // 2) 绘制
        // 同步乐器指针/增益到音频线程（成本极低；删除乐器后自动变 null）
        for (0..synth.max_instruments) |i| {
            const sp: ?*synth.SynthParams = if (i < app.instruments.items.len) app.instruments.items[i].synth else null;
            app.params.synth_ptrs[i].store(sp, .monotonic);
            const g: f32 = if (i < app.instruments.items.len)
                (if (app.instruments.items[i].muted) 0.0 else app.instruments.items[i].volume)
            else
                0.0;
            app.params.instrument_gain[i].store(g, .monotonic);
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

            // 调度 lookahead：提前 4 小节（步单位随拍号/分辨率变化）
            const horizon = cur + app.steps_per_bar * 4;
            if (horizon > app.scheduler.scheduled_upto) {
                sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, app.scheduler.scheduled_upto, horizon, app.steps_per_bar);
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
        ui.endFrame();

        // 普通拖动（滚动条/片段/音符/分隔条）捕获鼠标：拖出窗口后仍能收到松开事件
        // （否则拖动状态卡死，鼠标移回时误触发拖动分支 → 回弹/跳变）。
        // 冻结模式由 begin/endMouseCapture 自行管理，此处不碰。
        if (!ui.mouse_capture) win.setDragCapture(ui.active_id != 0);

        // 冻结中的光标：强制隐藏（控件可能在绘制时请求了别的形状）
        if (win.mouse_captured) ui.cursor = .hidden;

        // 3) 光标形状（UI 在绘制时按需请求）
        win.setCursor(ui.cursor);

        // 4) 呈现
        win.present();

        // 5) 帧率限制（约 60fps）
        std.Io.sleep(io, .fromMilliseconds(16), .awake) catch {};
    }
    return 0;
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
};

// ── 主界面组装 ──

fn drawApp(ui: *Ui, app: *App, w: i32, h: i32) void {
    app.layout.initIfNeeded(w);

    // ── 层声明（帧首）──
    // 立即式 UI 里“绘制顺序 = 事件处理顺序”；层系统把“谁接收鼠标”
    // 从手写组合逻辑（rack_blocks or synth_blocks...）变成**声明式**：
    // 各层声明优先级 + 矩形，beginLayer 自动判定是否被上层屏蔽。
    // 优先级：菜单(3) > 合成器窗口(2) > 机架窗口(1) > 主界面(0)。
    const rack_open = app.rack.open;
    const synth_open = app.synth_win.open;
    const menu_open = app.rack.inst_menu_open or app.rack.add_menu_open or app.rack.ctx_instrument != null;

    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = w, .h = h } }); // 主界面
    if (rack_open) {
        _ = ui.declare(.{ .prio = 1, .rect = .{ .x = app.rack.x, .y = app.rack.y, .w = app.rack.w, .h = app.rack.h } });
    }
    if (synth_open) {
        _ = ui.declare(.{ .prio = 2, .rect = .{ .x = app.synth_win.x, .y = app.synth_win.y, .w = app.synth_win.w, .h = app.synth_win.h } });
    }
    if (menu_open) {
        // 任何菜单展开 = 模态层（全屏屏蔽）
        _ = ui.declare(.{ .prio = 3, .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .modal = true });
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

    // 通道机架（浮动窗口）：进入自己的层（自动屏蔽：被合成器/菜单覆盖时不响应）
    // 用 NoClip：窗口阴影/右键菜单会超出窗口矩形，裁剪会切掉它们。
    if (rack_open) {
        _ = ui.beginLayerNoClip(1);
        _ = view_rack.draw(ui, app, w, h, menu_open);
        ui.endLayer();
    }
    // 合成器编辑器（最上层浮动窗口）——同理：阴影超界
    if (synth_open) {
        _ = ui.beginLayerNoClip(2);
        _ = view_synth.draw(ui, app, w, h);
        ui.endLayer();
    }
}

fn drawToolbar(ui: *Ui, app: *App, w: i32) void {
    ui.renderer.fillRect(0, 0, w, util.toolbar_h, ui.theme.toolbar);
    ui.renderer.hline(0, util.toolbar_h - 1, w, ui.theme.panel_border);

    var x: i32 = 8;
    const by: i32 = 7;
    const bh: i32 = 26;

    // 菜单（占位：只有文字按钮）；“乐器”按钮 = 开关通道机架
    const menus = [_][]const u8{ "文件", "选项", "视图", "乐器", "混音台" };
    for (menus, 0..) |m, i| {
        const mw: i32 = @as(i32, @intFromFloat(ui.font.measure(m))) + 16;
        const active = (i == 3) and app.rack.open; // “乐器”当前开着 → 高亮
        if (active) {
            if (ui.buttonEx(100 + @as(u64, i), m, x, by, mw, bh, true)) {
                app.rack.open = false; // 点击关闭
            }
        } else if (ui.button(100 + @as(u64, i), m, x, by, mw, bh)) {
            if (i == 3) app.rack.open = true; // 点击打开通道机架
        }
        x += mw + 2;
    }

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

    // 传输控制（图标用 ASCII：中文字体常缺 ▶（U+25B6）/❚（U+275A），
    // 缺失时会退回 .notdef 方块（实测“播放按钮变竖长方形”）
    if (ui.button(200, if (app.playing) "||" else ">", x, by, 36, bh)) {
        app.playing = !app.playing;
        if (app.playing) {
            const from = if (app.sel.song_mode) app.playback.song_step else app.playback.piano_step;
            app.playback.start_frame = app.params.frames_played.load(.monotonic);
            app.playback.start_step = from;
            app.params.start_frame.store(app.playback.start_frame, .monotonic);
            app.params.start_step.store(from, .monotonic);
            app.params.playing.store(true, .monotonic);
            sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, app.sel.song_mode, app.sel.pattern, from, app.steps_per_bar);
            app.params.sched_gen.store(app.scheduler.gen, .monotonic);
        } else {
            app.params.playing.store(false, .monotonic);
        }
    }
    x += 40;
    if (ui.button(201, "■", x, by, 36, bh)) {
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
    _ = ui.button(202, "●", x, by, 36, bh);
    x += 46;

    // BPM（按住上下拖：上滑增加 / 下滑减小；拖动时光标隐藏并冻结）
    ui.label("BPM", x, by + 4, ui.theme.text_dim);
    x += @as(i32, @intFromFloat(ui.font.measure("BPM"))) + 8;
    _ = ui.dragNumber(350, x, by + 3, 56, 20, &app.bpm, 20, 999, 2);
    x += 62;

    // 拍号（分子/分母都可推；分母为 2 的幂：指数式推子——拖 1 单位 = 翻倍）
    {
        const num_w: i32 = 30;
        const den_w: i32 = 30;
        const changed_num = ui.dragNumber(351, x, by + 3, num_w, 20, &app.time_num, 1, 32, 4);
        ui.label("/", x + num_w + 5, by + 4, ui.theme.text_dim);
        // 指数模式：拖动值 = log2(分母)（1..4 → 2/4/8/16）；不会因吸附写回而振荡
        const changed_den = ui.dragNumberEx(352, x + num_w + 15, by + 3, den_w, 20, &app.time_den, 0, 4, 4, 1, null);
        if (changed_num or changed_den) {
            app.steps_per_bar = model.stepsPerBarFor(app.time_num, app.time_den);
            // 拍号变更 → 内容解释变了：播放中重置调度与传输
            if (app.playing) app.jumpPlaybackCursor(app.playback.cursorStep(app.sel.song_mode));
        }
        x += num_w + den_w + 24;
    }

    // 时间显示
    ui.label("00:00:00", x, by + 4, ui.theme.text_dim);

    // 右侧：主音量推子
    const vol_w: i32 = 120;
    const vol_x = w - vol_w - 16;
    ui.label("音量", vol_x - 44, by + 4, ui.theme.text_dim);
    if (ui.slider(300, &app.volume, vol_x, by + 3, vol_w, 20)) {
        app.params.volume.store(app.volume, .monotonic);
    }
    app.params.playing.store(app.playing, .monotonic);
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
    _ = @import("app.zig");
    _ = @import("view_util.zig");
    _ = @import("view_playlist.zig");
    _ = @import("view_pianoroll.zig");
    _ = @import("view_rack.zig");
    _ = @import("view_synth.zig");
    _ = @import("view_panels.zig");
    _ = @import("ui_test.zig");
}
