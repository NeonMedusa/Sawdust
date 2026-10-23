//! 钢琴卷帘视图：琴键列 + 音符编辑 + 乐器选择器。
//!
//! 布局：标题栏 → 横向滚动条 → 小节标尺 → 音符区 → 分割条 →
//! 力度/声像编辑轨（`view_note_lane.zig`）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const Theme = @import("ui.zig").Theme;
const App = @import("app.zig").App;
const model = @import("model.zig");
const synth = @import("synth.zig");
const util = @import("view_util.zig");
const view_note_lane = @import("view_note_lane.zig");
const KeyMode = @import("app.zig").KeyMode;

pub fn draw(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    const pattern = app.piano.pattern orelse return;
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "钢琴卷帘 — 样式 {d}", .{pattern + 1}) catch "钢琴卷帘";
    ui.panelTitled(x, y, w, h, title);

    // 吸附网格选择器 + 乐器选择器（标题栏内，**紧挨标题文字**；两者交互/视觉一致）——
    // 按钮在此绘制（在标题后面）；下拉在内容之后绘制（最上层，见函数末尾）。
    const snap_menu_was_open = app.piano.snap_menu_open;
    const inst_menu_was_open = app.piano.inst_menu_open;
    const title_w: i32 = @intFromFloat(ui.font.measure(title));
    const snap_btn_x: i32 = x + 6 + title_w + 12;
    var snap_clicked = false;
    if (snap_btn_x + 40 < x + w - 24) {
        snap_clicked = util.snapSelectorButton(ui, snap_btn_x, y, util.title_h, &app.piano.snap, &app.piano.snap_menu_open);
    }
    // 乐器选择器（网格选单**右侧**；标签 = 当前乐器名）
    var inst_buf: [48]u8 = undefined;
    const inst_label: []const u8 = blk: {
        const iname: []const u8 = if (app.sel.instrument >= 0 and app.sel.instrument < @as(i32, @intCast(app.instruments.items.len)))
            app.instruments.items[@intCast(app.sel.instrument)].name
        else
            "无乐器";
        break :blk std.fmt.bufPrint(&inst_buf, "{s}", .{iname}) catch iname;
    };
    const inst_btn_x: i32 = blk: {
        var sbuf: [24]u8 = undefined;
        break :blk snap_btn_x + util.titleSelectorButtonWidth(ui, util.snapLabel(&sbuf, app.piano.snap)) + 6;
    };
    var inst_clicked = false;
    if (inst_btn_x + 40 < x + w - 24) {
        inst_clicked = util.titleSelectorButton(ui, inst_btn_x, y, util.title_h, inst_label, &app.piano.inst_menu_open);
        // 互斥：打开一个选单时关闭另一个
        if (inst_clicked) app.piano.snap_menu_open = false;
        if (snap_clicked) app.piano.inst_menu_open = false;
    }

    // 视图切换按钮（标题栏最右）：⇄ 返回播放列表
    if (util.viewSwitchButton(ui, x + w - 6, y, util.title_h)) {
        app.closePiano();
    }

    // 菜单展开时的点击只归菜单：屏蔽本帧其它交互（标尺/音符区）——
    // 必须在**任何交互处理之前**算（实测 bug：点选单条目穿透命中小节标尺，
    // 游标跳到鼠标位置——旧代码在末尾才算，标尺早已吃掉点击）。
    // 覆盖：帧首已有选单展开 / 本帧刚点选择器按钮（那两个点击都不该落到下层）。
    const menu_click = (inst_menu_was_open or snap_menu_was_open or snap_clicked or inst_clicked) and ui.mouse_pressed;

    const ruler_h: i32 = 20; // 标尺行高 = 滚动条厚度（与播放列表一致）
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;

    const main_x = x + 1;
    const main_w = w - 2 - ruler_h;
    const sb_x = x + w - 1 - ruler_h;
    const hsb_y = list_y;
    const ruler_y = list_y + ruler_h;
    const lane_y = list_y + ruler_h * 2; // 音符区顶部
    const keys_x = main_x;
    const lane_x = main_x + util.piano_header_w;
    const view_w = @max(1, main_w - util.piano_header_w);

    // ── 底部力度/声像编辑轨（见 `docs/note-lane.md`）──
    // 高度：会话态（`app.piano.lane_h`）；**0 = 未初始化** → 首帧 220px。
    // 每帧钳制 [min_h, min(35%·content, content−124)]（保证音符区至少 ~6 行）。
    // 分割条在**布局最前**处理（拖动后重算高度——本帧绘制/命中用新值，不滞后一帧）。
    const splitter_h: i32 = 4;
    const content_all = list_h - ruler_h * 2;
    {
        const max_by_frac: i32 = @intFromFloat(@as(f32, @floatFromInt(content_all)) * view_note_lane.max_frac);
        const max_h: i32 = @min(max_by_frac, @max(view_note_lane.min_h, content_all - 124));
        if (app.piano.lane_h <= 0) {
            app.piano.lane_h = 220; // 默认高度（小窗时由下方 clamp 收窄）
        }
        app.piano.lane_h = std.math.clamp(app.piano.lane_h, view_note_lane.min_h, max_h);
        // 分割条：**向上拖增高**；`sp_y` 随当前 lane_h 动（拖动中每帧重算 → 跟手）
        const sp_y = lane_y + @max(48, content_all - splitter_h - app.piano.lane_h);
        _ = ui.splitterH(7002, &app.piano.lane_h, sp_y, x + 1, w - 2, splitter_h, view_note_lane.min_h, max_h);
        app.piano.lane_h = std.math.clamp(app.piano.lane_h, view_note_lane.min_h, max_h);
    }
    const editor_h: i32 = app.piano.lane_h;
    const lane_h = @max(48, content_all - splitter_h - editor_h); // 音符区高度
    // 每小节步数由**拍号**决定（动态；App 字段）
    const spb: i32 = app.steps_per_bar;
    const bar_w = spb * util.piano_step_w;
    // 量化/吸附格（步）——音符移动/拉伸对齐到它；网格也按它加一层。
    const snap_steps: i32 = model.snapSteps(app.piano.snap);

    // ── 时间轴长度与缩放下限（**同一个值**，否则会出现“滑块有行程但拖不动”）──
    // 时间轴 = 内容右缘（保底 4 小节）+ 右侧 3 小节留白。
    // 缩放下限 = 视图恰好容纳整个时间轴 → 缩到底时滑块**满宽**（无假行程）。
    var max_step: i32 = 0;
    for (app.notes.items) |n| {
        if (n.pattern != pattern) continue;
        max_step = @max(max_step, n.step + n.len);
    }
    const bars_right = @max(4, @divTrunc(max_step + spb - 1, spb));
    const timeline_w: i32 = (bars_right + 3) * bar_w;
    const min_content: i32 = @max(timeline_w, 1); // 滚动条时间轴下限
    const content_span: i32 = timeline_w; // 缩放拉回限制（同值）
    const dyn_zoom_min: f32 = @min(8.0, @as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(timeline_w)));

    // 横向时间轴滚动条（minimap 语义；局部坐标）
    {
        // **动态缩放下限**（见函数顶部 dyn_zoom_min）

        // minimap：当前样式 + 当前乐器的音符分布（横向版 VSCode minimap）。
        // 纵向映射用**实际音域**（最低音→底、最高音→顶），并设**保底范围**
        // （至少 1 个八度）——否则只有一两个音时会看起来像通高块。
        var mini_buf: [512]Ui.MiniBlock = undefined;
        var nmini: usize = 0;
        var min_pitch: i32 = 127;
        var max_pitch: i32 = 0;
        var any_note = false;
        for (app.notes.items) |n| {
            if (n.pattern != pattern or n.instrument != app.sel.instrument) continue;
            any_note = true;
            min_pitch = @min(min_pitch, n.pitch);
            max_pitch = @max(max_pitch, n.pitch);
        }
        if (any_note) {
            // 保底 1 个八度（否则一两个音会像“通高块”）；以音域中点扩展
            const range = model.rangeMap(min_pitch, max_pitch, 12);
            for (app.notes.items) |n| {
                if (nmini >= mini_buf.len) break;
                if (n.pattern != pattern or n.instrument != app.sel.instrument) continue;
                mini_buf[nmini] = .{
                    .pos = n.step * util.piano_step_w,
                    .len = @max(util.piano_step_w, n.len * util.piano_step_w),
                    .kind = .note,
                    .y = 1.0 - range.yOf(n.pitch),
                    .color = ui.theme.waveform,
                };
                nmini += 1;
            }
        }
        _ = ui.scrollbarTimelineEx(10, x + 1, hsb_y, w - 2, ruler_h, &app.piano.scroll_x, min_content, &app.piano.zoom, view_w, dyn_zoom_min, 8.0, bars_right < util.overhang_map_limit, mini_buf[0..nmini]);
    }
    ui.renderer.hline(x + 1, ruler_y, w - 2, ui.theme.panel_border);

    // 横向缩放：内容坐标 → 屏幕坐标（本帧最终值）
    const zoom: f32 = app.piano.zoom;
    // 横向滚动**帧首快照**：网格/编辑区共用一个口径（本帧横向缩放补间在绘制之后——
    // 若编辑区现读 `app.piano.scroll_x` 会领先一帧：左缘网格线闪动，实测“没有补间”感）
    const scroll_x0: i32 = app.piano.scroll_x;
    const step_ws: f32 = @as(f32, @floatFromInt(util.piano_step_w)) * zoom; // 屏幕上的步宽
    const bar_ws: f32 = @as(f32, @floatFromInt(bar_w)) * zoom; // 屏幕上的小节宽
    const scroll_s: f32 = @as(f32, @floatFromInt(app.piano.scroll_x)) * zoom; // 屏幕上的滚动量

    // 窗外暗化（用户拍板设计）：SONG 模式 + 锚窗口存在 → 窗外网格/音符暗化
    // （暗示“片段外的音符不出声”）；PAT 不暗化；无锚（样式无片段）不暗化。
    // 实现：内容画完后在窗外区域盖两条半透明 scrim（**半跨界音符自动被切段**——
    // 只盖到窗口边界），再画窗口右缘分界线。
    const dim_x: ?[2]i32 = blk: {
        if (!app.sel.song_mode) break :blk null;
        const o = app.patOriginClip() orelse break :blk null;
        if (o.len <= 0) break :blk null;
        const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(o.offset)) * step_ws - scroll_s));
        const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(o.offset + o.len)) * step_ws - scroll_s));
        break :blk .{ x0, x1 };
    };

    // 循环区域在**本视图的局部坐标**（本视图时间轴 = 当前样式最左片段的局部轴）：
    // - PAT：`loop_pat` 即局部步，直接用；
    // - SONG：`loop_song` 是全局步，经**锚片段**换算（统一到锚——双击的片段；
    //   无快照 → 回退最左，行为与旧版一致。实测 bug：双击后面片段打开，
    //   标尺放游标却跑到第一个片段上——旧版此处用最左片段）
    const loop_clip: ?model.Clip = if (app.sel.song_mode) app.patOriginClip() else null;
    const loop_local: ?[2]i32 = blk: {
        const lr = app.loopRegion() orelse break :blk null;
        if (!app.sel.song_mode) break :blk lr;
        const c = loop_clip orelse break :blk null; // 无片段：无局部时间轴，不显示
        const lo_l = model.clipSongToLocalClamped(c, lr[0]);
        const hi_l = model.clipSongToLocalClamped(c, lr[1]);
        if (hi_l <= lo_l) break :blk null; // 区域完全在片段窗口外
        break :blk .{ lo_l, hi_l };
    };

    // 鼠标 x → 局部步（**吸附到当前网格**；标尺交互/循环拖动共用）
    const mouseLocalStepSnap = struct {
        fn f(mx: i32, lx: i32, scroll_x: i32, zm: f32, spb_v: i32, bar_w_v: i32, snap: i32) i32 {
            const cpx: i32 = scroll_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(mx - lx)) / zm));
            const raw: i32 = @max(0, @divFloor(cpx * spb_v, bar_w_v));
            return @max(0, model.snapRound(raw, snap));
        }
    }.f;

    // 局部小节标尺
    ui.renderer.fillRect(main_x, ruler_y, main_w, ruler_h, ui.theme.toolbar);
    {
        const saved = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h);
        defer ui.renderer.popClip(saved);
        var bar: i32 = @divFloor(app.piano.scroll_x, bar_w) + 1;
        // 小节数字**分级渲染**（1-2-5 系列）：标签太密时只显 1、2、5、10… 的切点
        const label_step: i32 = util.barLabelStep(bar_ws, 40);
        while (true) : (bar += 1) {
            const bx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar - 1)) * bar_ws - scroll_s));
            if (bx > main_x + main_w) break;
            if (@mod(bar - 1, label_step) != 0) continue;
            // 只画数字标记（小节线在内容区已有，标尺行保持干净）。
            // 若将来想加回刻度线，在此处加：
            //   ui.renderer.fillRect(bx, ruler_y, 1, ruler_h, ui.theme.grid_bar);
            var buf: [8]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{bar}) catch "";
            ui.label(t, bx + 3, ruler_y + 1, ui.theme.text_dim);
        }
        // 循环区域（标尺行部分；内容区部分在下面音符层里另行绘制）。
        // `loop_local` 已把 SONG 全局区域换算为**本视图局部步**（见顶部）；
        // 拖动中优先显示实时预览（首次设置区域也能看到预览）
        {
            var lo: i32 = 0;
            var hi: i32 = 0;
            var show = false;
            if (app.playback.loop_drag_from) |df| {
                // **按当前网格步进**（与松手时一致；旧版预览用 1/96 原始步，
                // 拖动时端点乱跳、松手忽然吸到网格——手感不对）
                const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                lo = @min(df, cur_step);
                hi = @max(df, cur_step);
                show = hi > lo;
            } else if (loop_local) |lr_in| {
                lo = lr_in[0];
                hi = lr_in[1];
                show = hi > lo;
            }
            if (show) {
                const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(lo)) * step_ws - scroll_s));
                const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(hi)) * step_ws - scroll_s));
                const tint = (@as(u32, 40) << 24) | (ui.theme.note_selected & 0x00FFFFFF);
                ui.renderer.fillRect(x0, ruler_y, x1 - x0, ruler_h, tint);
                ui.renderer.vline(x0, ruler_y, ruler_h, ui.theme.note_selected);
                ui.renderer.vline(x1, ruler_y, ruler_h, ui.theme.note_selected);
            }
        }
    }
    ui.renderer.vline(sb_x, ruler_y, ruler_h, ui.theme.panel_border); // □ 缺口左边界
    ui.renderer.vline(lane_x, ruler_y, ruler_h, ui.theme.panel_border); // 琴键列分界
    ui.renderer.hline(x + 1, lane_y, w - 2, ui.theme.panel_border);

    // ── 键列模式切换（琴键/鼓组；`docs/drumkit.md` §6）──
    // 位置 = 琴键列上方、标尺行左侧的 90×20 空格（与琴键列同宽）。
    // 分段式：左半「琴键」右半「鼓组」，当前模式用强调色；单击任一半即切到该模式。
    // 会话态（不入历史）；菜单展开时让位（menu_click 吞掉本帧点击）。
    {
        const seg_w = util.piano_header_w;
        const seg_h = ruler_h;
        const half = @divTrunc(seg_w, 2);
        const labels = [_][]const u8{ "琴键", "鼓组" };
        const modes = [_]KeyMode{ .piano, .drum };
        const cur_mode = app.currentKeyMode();
        const hovered = !ui.input_blocked and !menu_click and
            util.inRect(ui.mouse_x, ui.mouse_y, keys_x, ruler_y, seg_w, seg_h);
        ui.renderer.fillRect(keys_x, ruler_y, seg_w, seg_h, ui.theme.toolbar);
        for (labels, modes, 0..) |lb, mode, k| {
            const sx = keys_x + @as(i32, @intCast(k)) * half;
            const on = cur_mode == mode;
            const hov = hovered and ui.mouse_x >= sx and ui.mouse_x < sx + half;
            if (on) {
                ui.renderer.fillRect(sx + 1, ruler_y + 1, half - 2, seg_h - 2, ui.theme.accent);
            } else if (hov) {
                ui.renderer.fillRect(sx + 1, ruler_y + 1, half - 2, seg_h - 2, ui.theme.item_hover);
            }
            const tw2: i32 = @intFromFloat(ui.font.measure(lb));
            ui.labelCentered(lb, sx + @divTrunc(half - tw2, 2), ruler_y + 1, seg_h - 2, if (on) ui.theme.text else ui.theme.text_dim);
            if (hov and ui.mouse_pressed) app.setCurrentKeyMode(mode);
        }
        ui.renderer.hline(keys_x, ruler_y + seg_h - 1, seg_w, ui.theme.panel_border);
    }

    // 垂直缩放的“缩到底”下限（□ / Shift+滚轮共用）：音高行数固定 128，
    // 行数多到 fit 低于固定最小值时退回 piano_key_h_min。当前行高已低于该值时
    // 以当前为准（下限只当刹车，不反向顶大）。
    const zoom_min_h: i32 = @min(util.zoomOutFloor(util.piano_key_h_min, util.piano_key_h_max, app.piano.lane_h, 128), app.piano.key_h);

    // □ 缺口：按住上下拖 = 音高行高缩放（方块本身固定不动；视口中心音高保持不动）
    {
        const old_h = app.piano.key_h;
        if (ui.zoomSquare(13, sb_x, ruler_y, ruler_h, &app.piano.key_h, zoom_min_h, util.piano_key_h_max, 2) and app.piano.key_h != old_h) {
            const content_h_new: i32 = 128 * app.piano.key_h;
            app.piano.scroll = Ui.zoomAnchoredScroll(app.piano.scroll, lane_h, old_h, app.piano.key_h, content_h_new);
        }
    }

    // ── 琴键试听（在绘制之前处理状态，以便高亮）──
    // - 只在**按下的那一帧**触发（不跟随拖动）；鼠标移出琴键区、松开 → 释音
    // - 按下 = 推 note-on 事件（分配新声部）→ 快速连点/和弦天然支持
    // - 正在拖动（active_id != 0 且不是琴键试听）时忽略鼠标 → 修“拖动窗口时划过琴键误触发”
    // - **菜单展开中 / 帧首菜单开着** 时忽略鼠标 → 修“点菜单击穿到琴键发声”（实测 bug）
    {
        const kh = app.piano.key_h;
        // 菜单展开中 → 琴键不响应（机架的下拉/右键菜单，以及卷帘自己的两个选单）
        const menu_blocks = app.rack.ctx_instrument != null or
            app.piano.inst_menu_open or app.piano.snap_menu_open;
        const in_keys = !menu_blocks and ui.hitRect(keys_x, lane_y, util.piano_header_w, lane_h);
        const over_other_drag = ui.active_id != 0 and ui.active_id != 6000;
        const pitch_at_mouse: i32 = 127 - @divFloor(ui.mouse_y - lane_y + app.piano.scroll, kh);

        if (in_keys and ui.mouse_pressed and !over_other_drag and !ui.mods_ctrl) {
            if (pitch_at_mouse >= 0 and pitch_at_mouse <= 127) {
                ui.active_id = 6000; // 标记“琴键试听拖动”（归本控件）
                app.piano.held_pitch = pitch_at_mouse;
                app.auditionOn(pitch_at_mouse); // 路由到当前乐器
            }
        } else if (ui.active_id == 6000) {
            if (!ui.mouse_down or !in_keys) {
                // 松开或移出琴键区：释音
                if (app.piano.held_pitch) |hp| app.auditionOff(hp);
                app.piano.held_pitch = null;
                ui.active_id = 0;
            } else if (pitch_at_mouse != app.piano.held_pitch and pitch_at_mouse >= 0 and pitch_at_mouse <= 127) {
                // 按住时上下滑动：换音（沿琴键滑奏）
                if (app.piano.held_pitch) |hp| app.auditionOff(hp);
                app.piano.held_pitch = pitch_at_mouse;
                app.auditionOn(pitch_at_mouse);
            }
        }
        // 注：不再做“兜底释音”——held_pitch 现在由音符交互共享，
        // 该分支会误杀音符试听（各管各的：琴键 active_id=6000；音符 drag_note）
    }

    // 琴键列 + 音符区（裁剪）
    {
        const saved = ui.renderer.pushClip(main_x, lane_y, main_w, lane_h);
        defer ui.renderer.popClip(saved);

        ui.renderer.fillRect(keys_x, lane_y, util.piano_header_w, lane_h, ui.theme.bg);
        ui.renderer.fillRect(lane_x, lane_y, view_w, lane_h, ui.theme.panel);

        // 可见音高行（琴键 + 行线）
        const kh = app.piano.key_h;
        // 行高亮判定：试听（held_pitch）**或**正在发声（播放/释音尾）
        const lit = struct {
            fn f(a: *App, pitch: i32) bool {
                if (a.piano.held_pitch) |hp| {
                    if (hp == pitch) return true;
                }
                return a.sounding.isSounding(pitch);
            }
        }.f;
        const first_pitch: i32 = 127 - @divFloor(app.piano.scroll, kh);
        const drum_mode = app.currentKeyMode() == .drum;
        // 当前乐器的鼓组（鼓组模式用；非鼓组/无乐器 → null）
        const cur_kit: ?*const model.DrumKit = blk: {
            if (app.sel.instrument < 0 or app.sel.instrument >= @as(i32, @intCast(app.instruments.items.len))) break :blk null;
            const inst = &app.instruments.items[@intCast(app.sel.instrument)];
            if (inst.kind != .drumkit) break :blk null;
            break :blk inst.kit;
        };
        const rows: i32 = @divFloor(lane_h, kh) + 2;
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const p = first_pitch - i;
            if (p < 0) break;
            const py = lane_y + (127 - p) * kh - app.piano.scroll;
            if (py + kh < lane_y or py > lane_y + lane_h) continue;
            const black = model.isBlackKey(p);
            const pressed = lit(app, p); // 按下/发声中高亮（与行高亮联动）
            // 已映射（该音高**有垫且有层**）→ 左侧 2px 强调条（仅鼓组模式）
            const mapped = drum_mode and cur_kit != null and
                p >= 0 and p <= 127 and cur_kit.?.isMapped(@intCast(p));
            // 键底色 + 文字色（鼓组模式**不用钢琴黑白键**——见 keyRowStyle）
            const st = keyRowStyle(&ui.theme, drum_mode, black, pressed, mapped);
            ui.renderer.fillRect(keys_x + 1, py, util.piano_header_w - 1, kh - 1, st.bg);
            if (drum_mode) {
                // 鼓组模式键列：垫名 > GM 标准名 > 音名（C 行）
                // 行高太小（< 12px）时不画文字（会串行）——只留强调条。
                if (mapped) ui.renderer.fillRect(keys_x, py, 2, kh - 1, ui.theme.accent);
                if (kh >= 12) {
                    var dbuf: [48]u8 = undefined;
                    const lbl = model.drumKeyLabel(&dbuf, cur_kit, p);
                    if (lbl.len > 0) {
                        var ebuf: [160]u8 = undefined;
                        const shown = util.middleEllipsis(ui, &ebuf, lbl, util.piano_header_w - 10);
                        if (shown.len > 0) {
                            // 行内**垂直居中**（label 的 y 是基线锚点，行高变化时会偏上）
                            ui.labelCentered(shown, keys_x + 5, py, kh - 1, st.text);
                        }
                    }
                }
            } else if (!black) {
                var buf: [8]u8 = undefined;
                const nm = model.pitchName(&buf, p);
                if (nm.len > 0 and nm[0] == 'C') {
                    ui.labelClipped(nm, keys_x + util.piano_header_w - 34, py - 2, 30, st.text);
                }
            }
            // 黑键行背景加深（音符区）。半透明叠加（不会盖过行线/网格：它们在后面画）。
            // 注：**鼓组模式也画**——与键列的黑白无关，纯粋是“深浅交错的行定位
            // 参考线”（用户反馈：它有帮助，不只是钢琴语义）。
            if (black) ui.renderer.fillRect(lane_x, py, view_w, kh - 1, ui.theme.lane_black_key);
            // 行线（每八度加强）
            ui.renderer.hline(lane_x, py, view_w, if (@mod(p, 12) == 0) ui.theme.panel_border else ui.theme.grid);
        }

        // 时间轴网格（与播放列表共用 `util.drawTimelineGrid`；U=96 对齐）。
        // 该函数内部自行裁剪到音符区；网格层 = 当前量化档位（非固定步线），
        // 拍线/小节线常显（各自按密度门槛降级）。
        util.drawTimelineGrid(
            &ui.renderer,
            &ui.theme,
            lane_x,
            view_w,
            lane_y,
            lane_h,
            lane_x,
            scroll_x0,
            zoom,
            @floatFromInt(util.piano_step_w),
            spb,
            model.stepsPerBeat(app.time_den),
            snap_steps,
        );

        // 试听/发声行高亮：**网格之上、音符之下**——否则行线/网格会“透”过高亮层，
        // 看起来像高亮在下层（实测观感：高亮时网格反而更明显）
        {
            var hp2: i32 = 0;
            while (hp2 < 128) : (hp2 += 1) {
                if (!lit(app, hp2)) continue;
                const hy = lane_y + (127 - hp2) * app.piano.key_h - app.piano.scroll;
                if (hy + app.piano.key_h < lane_y or hy > lane_y + lane_h) continue;
                // 白键行亮得多一点、黑键行少一点（保持“黑白键”的视觉层次）
                const row_tint: u32 = if (model.isBlackKey(hp2)) 26 else 40;
                ui.renderer.fillRect(lane_x, hy, view_w, app.piano.key_h - 1, (@as(u32, row_tint) << 24) | (ui.theme.accent & 0x00FFFFFF));
            }
        }

        // 循环区域背景（半透明橙黄 = 选中音符同款色；叠在网格/行高亮之上、
        // 音符之下——只做背景层，不影响内容可读性）；标尺行同时叠加。
        // **单独裁剪到音符区**：外层裁剪含琴键列（main_x 起），
        // 不收紧的话区域会盖到琴键上（实测 bug）。
        {
            const saved_loop = ui.renderer.pushClip(lane_x, lane_y, view_w, lane_h);
            defer ui.renderer.popClip(saved_loop);
            // 区域来源：拖动中 → 实时预览（起点.. 鼠标）；否则 → 已设区域（已换算）
            var lo: i32 = 0;
            var hi: i32 = 0;
            var show = false;
            if (app.playback.loop_drag_from) |df| {
                // **按当前网格步进**（与松手时一致；见标尺行同名注释）
                const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                lo = @min(df, cur_step);
                hi = @max(df, cur_step);
                show = hi > lo;
            } else if (loop_local) |lr_in| {
                lo = lr_in[0];
                hi = lr_in[1];
                show = hi > lo;
            }
            if (show) {
                const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(lo)) * step_ws - scroll_s));
                const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(hi)) * step_ws - scroll_s));
                // 半透明叠加（alpha ≈ 40；与选中音符颜色同源）
                const tint = (@as(u32, 40) << 24) | (ui.theme.note_selected & 0x00FFFFFF);
                ui.renderer.fillRect(x0, lane_y, x1 - x0, lane_h, tint);
                // 边界竖线（不透明；精确范围）
                ui.renderer.vline(x0, lane_y, lane_h, ui.theme.note_selected);
                ui.renderer.vline(x1, lane_y, lane_h, ui.theme.note_selected);
            }
        }

        // 幽灵音符（**同样式、其它乐器**；灰色半透明——只读参考，无交互）：
        // 画在主体音符**之前** → 真实音符压在上层。
        // 交互（命中/框选/行选）的乐器筛选保留——幽灵不参与选择与拖动。
        {
            const saved_ghost = ui.renderer.pushClip(lane_x, lane_y, view_w, lane_h);
            defer ui.renderer.popClip(saved_ghost);
            for (app.notes.items) |n| {
                if (n.pattern != pattern or n.instrument == app.sel.instrument) continue;
                const gx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
                const gy = lane_y + (127 - n.pitch) * kh - app.piano.scroll;
                const gw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
                if (gx + gw < lane_x or gx > lane_x + view_w) continue;
                if (gy + kh < lane_y or gy > lane_y + lane_h) continue;
                ui.renderer.fillRect(gx, gy, gw, kh - 1, ui.theme.ghost_note);
            }
        }

        // 音符（当前样式 + 当前乐器）——**单独裁剪到音符区**：
        // 外层裁剪含琴键列（main_x 起），不收紧的话左滚时音符会压到琴键上（实测 bug）
        {
            const saved_notes = ui.renderer.pushClip(lane_x, lane_y, view_w, lane_h);
            defer ui.renderer.popClip(saved_notes);
            // 层级（与片段同规则，用户拍板）：按左端点升序绘制（越靠右越上层）；
            // 左端相同 → 数组序。暂存下标表排序（见 `PianoState.draw_order`）。
            app.piano.draw_order.clearRetainingCapacity();
            for (app.notes.items, 0..) |n0, ni0| {
                if (n0.pattern == pattern and n0.instrument == app.sel.instrument) {
                    app.piano.draw_order.append(app.allocator, ni0) catch {};
                }
            }
            std.mem.sort(usize, app.piano.draw_order.items, app.notes.items, struct {
                fn less(notes: []const model.Note, a: usize, b: usize) bool {
                    if (notes[a].step != notes[b].step) return notes[a].step < notes[b].step;
                    return a < b;
                }
            }.less);
            for (app.piano.draw_order.items) |ni| {
                const n = app.notes.items[ni];
                const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
                const ny = lane_y + (127 - n.pitch) * kh - app.piano.scroll;
                const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
                if (nx + nw < lane_x or nx > lane_x + view_w) continue;
                if (ny + kh < lane_y or ny > lane_y + lane_h) continue;
                const active = if (app.piano.drag_note) |dn| dn == ni else false;
                // 颜色层级：拖动中（accent）> 选中（橙）> 普通（波形绿）
                const note_color = if (active) ui.theme.accent else if (n.selected) ui.theme.note_selected else ui.theme.waveform;
                ui.renderer.fillRect(nx, ny, nw, kh - 1, note_color);
                // 描边只在“不会被填充满”时才画：宽/高 ≤ 2px 时描边会完全
                // 覆盖填充（1px 音符被灰色描边包成灰线——实测 bug）。
                if (nw > 2 and kh > 3) {
                    ui.renderer.strokeRect(nx, ny, nw, kh - 1, ui.theme.panel_border);
                }

                // 音高文字（空间足够时）：宽度 ≥ 文字宽+6，高 ≥ 10px
                if (kh >= 10) {
                    var pbuf: [8]u8 = undefined;
                    const pname = model.pitchName(&pbuf, n.pitch);
                    const text_w: i32 = @intFromFloat(ui.font.measure(pname));
                    if (nw >= text_w + 8) {
                        // 行内**垂直居中**：用全 app 同一算法（键列/按钮同款）。
                        // 不用 `ui.label` 手算 ty——它假定文字高 10px，而字体
                        // 实际约 16px → 文字整体偏下（用户反馈实测）。
                        ui.labelCentered(pname, nx + 4, ny, kh - 1, if (active) ui.theme.bg else r_mod.rgb(16, 18, 22));
                    }
                }
            }
        }

        // 窗外暗化（见顶部 `dim_x`）：内容之后盖 scrim（半跨界音符自动被切段）；
        // 右缘分界线 1px（比色带更清晰）
        if (dim_x) |dx| {
            const scrim: u32 = (@as(u32, 120) << 24) | 0x000000;
            if (dx[0] > lane_x) ui.renderer.fillRect(lane_x, lane_y, @min(dx[0], lane_x + view_w) - lane_x, lane_h, scrim);
            if (dx[1] < lane_x + view_w) {
                const s0 = @max(dx[1], lane_x);
                ui.renderer.fillRect(s0, lane_y, lane_x + view_w - s0, lane_h, scrim);
            }
            if (dx[1] >= lane_x and dx[1] <= lane_x + view_w) ui.renderer.vline(dx[1], lane_y, lane_h, ui.theme.text_dim);
        }

        // 框选矩形（半透明填充 + 描边；画在音符之上）
        if (app.piano.marquee_active) {
            const mx0 = @min(app.piano.marquee_x0, ui.mouse_x);
            const mx1 = @max(app.piano.marquee_x0, ui.mouse_x);
            const my0 = @min(app.piano.marquee_y0, ui.mouse_y);
            const my1 = @max(app.piano.marquee_y0, ui.mouse_y);
            const fill = (@as(u32, 40) << 24) | (ui.theme.accent & 0x00FFFFFF);
            if (app.piano.row_marquee) {
                // 按行框选：**横跨整个音符区**的行带（音高行范围；当前行 = 鼠标所在行）
                const cur_pitch: i32 = 127 - @divFloor(ui.mouse_y - lane_y + app.piano.scroll, app.piano.key_h);
                const p0 = @min(app.piano.row_marquee_pitch0, cur_pitch);
                const p1 = @max(app.piano.row_marquee_pitch0, cur_pitch);
                const ry0 = lane_y + (127 - p1) * app.piano.key_h - app.piano.scroll;
                const rh = (p1 - p0 + 1) * app.piano.key_h;
                ui.renderer.fillRect(lane_x, ry0, view_w, rh, fill);
                ui.renderer.strokeRect(lane_x, ry0, view_w, rh, ui.theme.accent);
            } else {
                ui.renderer.fillRect(mx0, my0, mx1 - mx0, my1 - my0, fill);
                ui.renderer.strokeRect(mx0, my0, mx1 - mx0, my1 - my0, ui.theme.accent);
            }
        }
    }
    ui.renderer.vline(lane_x, lane_y, lane_h, ui.theme.panel_border); // 琴键列与音符区分界

    // ── 播放游标（PAT：独立自由设置；SONG：由全局换算，无片段时不显示/不可设置）──
    {
        // 裁剪到「标尺行 + 音符区」：左滚时游标 x 会变负，不裁剪会画到琴键列/左侧面板上（实测 bug）
        const saved_cursor = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h + lane_h);
        defer ui.renderer.popClip(saved_cursor);

        // 局部步（**小数步**：子步精度）→ 屏幕 x（内容像素 → 屏幕：乘 zoom）
        const localStepX = struct {
            fn f(step: f32, lx: i32, sw: f32, ss: f32) i32 {
                return lx + @as(i32, @intFromFloat(step * sw - ss));
            }
        }.f;

        if (app.sel.song_mode) {
            // SONG：找当前样式最左片段 → 全局步换算为局部步；无片段/不在范围内不显示
            // SONG 模式片段参照 = **锚**（双击的片段；无快照回退最左）——
            // 标尺拖动/游标绘制/换算统一到锚（实测 bug：双击后片段后放游标跑到第一个片段）
            if (app.patOriginClip()) |c| {
                if (model.clipSongToLocal(c, app.playback.song_step) != null) {
                    // **平滑小数步**（渲染帧线性；音频缓冲量化被吸收——实测“游标还是抖”的终解）
                    const local_f: f32 = app.cursorDisplay(true) - @as(f32, @floatFromInt(c.start)) + @as(f32, @floatFromInt(c.offset));
                    util.drawCursor(ui, localStepX(local_f, lane_x, step_ws, scroll_s), ruler_y, ruler_h, lane_y + lane_h, app.playing);
                }
                // 设置：局部 → 全局（超出片段可见范围 → 归位到片段起点）
                // （`menu_click` 门控：点选单条目的那一帧不得穿透到标尺）
                const in_ruler = !menu_click and ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
                // Ctrl+标尺：拖动 = 设循环区域；单击（未拖动）= 取消循环
                // （手势存**局部步**做预览；松手时换算成**全局步**入 SONG 槽——
                // 本视图 SONG 时间轴 = 最左片段的局部轴，见顶部 `loop_local`）
                if (in_ruler and ui.mouse_pressed and ui.mods_ctrl) {
                    app.playback.loop_drag_from = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                    app.playback.loop_drag_press_x = ui.mouse_x;
                    app.playback.loop_drag_moved = false;
                    ui.active_id = 7500;
                }
                if (ui.active_id == 7500) {
                    if (!ui.mouse_down) {
                        if (app.playback.loop_drag_moved) {
                            if (app.playback.loop_drag_from) |df| {
                                const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                                const lo_l = @min(df, cur_step);
                                const hi_l = @max(df, cur_step);
                                // 存 SONG 槽（局部 → 全局，鉗制到片段窗口）
                                const a = model.clipLocalToSongClamped(c, lo_l);
                                const b = model.clipLocalToSongClamped(c, hi_l);
                                app.setLoopRegion(a, b);
                                // 选中区域内的音符：**当前样式 + 当前乐器**（本视图可见/可编辑
                                // 范围；用局部步——区域在屏幕上就是局部轴）
                                app.selectNotesInRegionPat(lo_l, hi_l);
                            }
                        } else {
                            app.clearLoopRegion();
                            app.clearNoteSelection(); // 取消循环时一并取消音符选区
                        }
                        app.playback.loop_drag_from = null;
                        app.playback.loop_drag_moved = false;
                        ui.active_id = 0;
                    } else {
                        if (@abs(ui.mouse_x - app.playback.loop_drag_press_x) > 3) {
                            app.playback.loop_drag_moved = true;
                        }
                        // 拖动中**实时高亮**：区域内的音符每帧重算选中
                        // （同框选“框内 = 选中”；不必等松手）
                        if (app.playback.loop_drag_moved) {
                            if (app.playback.loop_drag_from) |df| {
                                const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                                app.selectNotesInRegionPat(@min(df, cur_step), @max(df, cur_step));
                            }
                        }
                    }
                } else if (in_ruler and ui.mouse_pressed) {
                    ui.active_id = 7100;
                }
                if (ui.active_id == 7100) {
                    if (!ui.mouse_down) {
                        ui.active_id = 0;
                    } else {
                        const local = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                        // **点 SONG 标尺 = 切回 SONG**（与“点播放列表标尺 = 切 SONG”对称）
                        app.sel.song_mode = true;
                        // 超出可见范围 → 归位到片段起点（局部 offset）；
                        // 跳转**去重**（按住期间只在目标步变化/按下帧才跳）
                        app.jumpPlaybackCursorDrag(model.clipLocalToSong(c, local) orelse c.start, ui.mouse_pressed);
                    }
                }
            }
        } else {
            // PAT：局部步自由设置（**平滑小数步** → 平滑游标）
            util.drawCursor(ui, localStepX(app.cursorDisplay(false), lane_x, step_ws, scroll_s), ruler_y, ruler_h, lane_y + lane_h, app.playing);
            // （`menu_click` 门控：点选单条目的那一帧不得穿透到标尺）
            const in_ruler = !menu_click and ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
            // Ctrl+标尺：拖动 = 设循环区域；单击（未拖动）= 取消循环（同上）
            if (in_ruler and ui.mouse_pressed and ui.mods_ctrl) {
                app.playback.loop_drag_from = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                app.playback.loop_drag_press_x = ui.mouse_x;
                app.playback.loop_drag_moved = false;
                ui.active_id = 7500;
            }
            if (ui.active_id == 7500) {
                if (!ui.mouse_down) {
                    if (app.playback.loop_drag_moved) {
                        if (app.playback.loop_drag_from) |df| {
                            const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                            const lo = @min(df, cur_step);
                            const hi = @max(df, cur_step);
                            app.setLoopRegion(lo, hi);
                            app.selectNotesInRegionPat(lo, hi);
                        }
                    } else {
                        app.clearLoopRegion();
                        app.clearNoteSelection(); // 取消循环时一并取消音符选区
                    }
                    app.playback.loop_drag_from = null;
                    app.playback.loop_drag_moved = false;
                    ui.active_id = 0;
                } else {
                    if (@abs(ui.mouse_x - app.playback.loop_drag_press_x) > 3) {
                        app.playback.loop_drag_moved = true;
                    }
                    // 拖动中实时高亮（同上）
                    if (app.playback.loop_drag_moved) {
                        if (app.playback.loop_drag_from) |df| {
                            const cur_step: i32 = mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps);
                            app.selectNotesInRegionPat(@min(df, cur_step), @max(df, cur_step));
                        }
                    }
                }
            } else if (in_ruler and ui.mouse_pressed) {
                ui.active_id = 7200;
            }
            if (ui.active_id == 7200) {
                if (!ui.mouse_down) {
                    ui.active_id = 0;
                } else {
                    // **点 PAT 标尺 = 切回 PAT**（与“点 SONG 标尺 = 切 SONG”对称）
                    app.sel.song_mode = false;
                    // 跳转**去重**（按住期间只在目标步变化/按下帧才跳）；
                    // 吸附到当前网格
                    app.jumpPlaybackCursorDrag(mouseLocalStepSnap(ui.mouse_x, lane_x, app.piano.scroll_x, zoom, spb, bar_w, snap_steps), ui.mouse_pressed);
                }
            }
        }
    }

    // ── 乐器选择器已移至标题栏（网格选单右侧；见函数顶部）——
    // 标尺行左端保持为空（不再占用琴键列上方）。
    // （`menu_click` 已提前到函数顶部计算——标尺/音符区都用它门控；
    // 实测 bug：点选单条目穿透命中小节标尺 → 游标跳到鼠标位置）

    // 量化/吸附格（步）——音符移动/拉伸对齐到它；网格也按它加一层（已在函数顶部声明）。

    // ── 交互（音符区）──
    // 注：命中区下缘避开分割条的 ±3px 拖拽带（否则贴底点击会同时启动分割条拖动）
    const in_lane = !menu_click and ui.hitRect(lane_x, lane_y, view_w, lane_h - 3);
    // 鼠标 → 内容坐标（除以 zoom）→ 步号
    const mouse_cx: i32 = app.piano.scroll_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom));
    const step_i = @divFloor(mouse_cx, util.piano_step_w);
    // 吸附后的步（放置/移动/拉伸都用它——量化到当前网格）
    const snap_step: i32 = @max(0, model.snapRound(step_i, snap_steps));
    const pitch_i = 127 - @divFloor(ui.mouse_y - lane_y + app.piano.scroll, app.piano.key_h);

    // ── 框选（Ctrl+左键拖；Ctrl+Shift = 追加）──
    // 判定：本帧在音符区按下 + Ctrl（不要求命中音符——命中音符时也优先框选，
    // 否则“从音符上开始拖框”会变成拖动该音符）
    // **按行框选**：起点在**琴键列**时切换成“整行选择”（垂直拖选音高行、水平不限）
    if (ui.mods_ctrl and ui.mouse_pressed and ui.active_id == 0) {
        const in_keys = ui.hitRect(keys_x, lane_y, util.piano_header_w, lane_h);
        if (in_lane or in_keys) {
            app.piano.marquee_active = true;
            app.piano.marquee_add = ui.mods_shift;
            app.piano.marquee_x0 = ui.mouse_x;
            app.piano.marquee_y0 = ui.mouse_y;
            app.piano.row_marquee = in_keys;
            app.piano.row_marquee_pitch0 = pitch_i;
            ui.active_id = 7300; // 框选手势（归本视图）
            if (!app.piano.marquee_add) app.clearNoteSelection();
        }
    }
    if (ui.active_id == 7300 and !ui.mouse_down) {
        ui.active_id = 0;
        app.piano.marquee_active = false;
        app.piano.row_marquee = false;
    }
    if (app.piano.marquee_active) {
        // 实时更新选区（每帧重算：框内 = 选中）
        const mx0 = @min(app.piano.marquee_x0, ui.mouse_x);
        const mx1 = @max(app.piano.marquee_x0, ui.mouse_x);
        const my0 = @min(app.piano.marquee_y0, ui.mouse_y);
        const my1 = @max(app.piano.marquee_y0, ui.mouse_y);
        if (!app.piano.marquee_add) app.clearNoteSelection();
        for (app.notes.items) |*n| {
            if (n.pattern != pattern or n.instrument != app.sel.instrument) continue;
            if (app.piano.row_marquee) {
                // 按行：音高在起始/当前行之间 → 选中（**水平不限**）
                const p0 = @min(app.piano.row_marquee_pitch0, pitch_i);
                const p1 = @max(app.piano.row_marquee_pitch0, pitch_i);
                if (n.pitch >= p0 and n.pitch <= p1) n.selected = true;
                continue;
            }
            const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
            const ny = lane_y + (127 - n.pitch) * app.piano.key_h - app.piano.scroll;
            const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
            // 矩形相交（半开区间；含边界）
            if (nx + nw >= mx0 and nx <= mx1 and ny + app.piano.key_h >= my0 and ny <= my1) {
                n.selected = true;
            }
        }
    }

    // 命中音符（下标 + 命中模式：中部 / 左缘 / 右缘，边缘区 8px）
    // 注：框选手势期间不命中（框选优先）
    var note_hit: ?struct { index: usize, mode: model.NoteHitMode } = null;
    if (in_lane and !app.piano.marquee_active and !ui.mods_ctrl) {
        // 叠放（与片段同规则，用户拍板）：命中取**最顶层**
        // （左端越右越上；同左端取数组序最大）
        if (model.topmostNoteAt(app.notes.items, pattern, app.sel.instrument, pitch_i, step_i)) |ni| {
            const n = app.notes.items[ni];
            const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
            const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
            const near_left = ui.mouse_x <= nx + 8;
            const near_right = ui.mouse_x >= nx + nw - 8;
            const mode: model.NoteHitMode = if (near_left and near_right)
                // 窄音符两缘都近：按鼠标在音符内的相对位置就近选
                (if (ui.mouse_x - nx <= nx + nw - ui.mouse_x) .left else .right)
            else if (near_left)
                .left
            else if (near_right)
                .right
            else
                .body;
            note_hit = .{ .index = ni, .mode = mode };
        }
    }

    // 光标：
    // - 拖动中：边缘拉伸 → ↔（左右箭头）；移动/批量 → 十字箭头
    // - 悬停：边缘 → ↔；**主体（可拖动）→ 十字箭头**（与边缘 hover 同一层次感）
    // 注：拖边缘时 `drag_note` 也非 null——必须按 `drag_note_mode` 区分，
    // 否则边缘拉伸会被归入“移动”分支（实测 bug：拖边缘变十字）。
    if (app.piano.batch_trim) {
        ui.cursor = .resize_h;
    } else if (app.piano.drag_note != null) {
        ui.cursor = if (app.piano.drag_note_mode == .body) .size_all else .resize_h;
    } else if (app.piano.drag_batch) {
        ui.cursor = .size_all;
    } else if (note_hit) |hit| {
        ui.cursor = if (hit.mode == .body) .size_all else .resize_h;
    }

    // 放置音符时也试听一声（原型手感）：仅新放置（非拖动）
    // （按住即发声，松开琴键/点击后自然释音）

    // 右键：删除音符（按下或拖动划过）
    if (!menu_click and ui.mouse_right_pressed and ui.hitRect(main_x, lane_y, main_w, lane_h)) {
        app.playlist.erase_drag = true;
    }
    if (app.playlist.erase_drag) {
        if (!ui.mouse_right_down) {
            app.playlist.erase_drag = false;
        } else if (note_hit) |hit| {
            _ = app.notes.orderedRemove(hit.index);
            app.piano.drag_note = null;
            app.dirty = true;
            // 历史：右键擦除（含拖动划过多个）→ 松开右键时 coalesce 提交一次
            app.history_pending = "擦除音符";
        }
    }

    // 左键按下：拖动/拉伸音符，或空位放置（4 步）
    // 试听规则（按设计）：
    // - 放置/点击**未选中**音符的主体 → 发声（按住不放 = 持续发声）
    // - **已选中的音符**（框选选区）单击/拖动位置/长度 → 不发声
    // - **拖边缘改长度**（任何音符）→ 不发声
    // - 拖动中换音高 → 重触发（仅当按下时已开始试听）
    // 注：Ctrl 按下（框选手势）时**不放置**——否则框选启动当帧会先放一个音符
    if (ui.mouse_pressed and in_lane and !ui.mods_ctrl and step_i >= 0 and pitch_i >= 0 and pitch_i <= 127) {
        if (note_hit) |hit0| {
            // 叠放轮换（与片段同规则）：点中即沉到同（音高+左端点）组最底；
            // 拖动/拉伸仍作用于它（索引用沉降后新值）。
            const hit = .{ .index = app.sinkNoteToTieBottom(hit0.index), .mode = hit0.mode };
            const n = app.notes.items[hit.index];
            // 命中**已选中的音符** + 选区 ≥ 2 → 批量拖动/拉伸（选区整体）
            // （单击单个未选中音符 → 单选 + 单音符拖动；点已选中但选区 = 1 也走单音符）
            const batch_mode = n.selected and app.selectedNoteCount() >= 2 and hit.mode != .body;
            if (batch_mode) {
                app.beginBatchSnap();
                app.piano.batch_trim = true;
                app.history_pending = "批量拉伸音符"; // 松手时 coalesce 提交
                app.piano.batch_trim_down_step = step_i;
                app.piano.batch_trim_grid = @max(1, snap_steps);
                app.piano.drag_note_mode = hit.mode;
                app.piano.drag_armed = false;
                app.piano.drag_down_x = ui.mouse_x;
                app.piano.drag_down_y = ui.mouse_y;
            } else if (n.selected and app.selectedNoteCount() >= 2) {
                // 批量拖动（选区 ≥ 2）：快照 + 记录按下基准
                app.beginBatchSnap();
                app.piano.drag_batch = true;
                app.history_pending = "批量移动音符"; // 松手时 coalesce 提交
                app.piano.batch_down_step = step_i;
                app.piano.batch_down_pitch = pitch_i;
                app.piano.drag_armed = false;
                app.piano.drag_down_x = ui.mouse_x;
                app.piano.drag_down_y = ui.mouse_y;
                // 注：选中音符拖动**不试听**（按设计）——旧实现会开一个固定音高的声部
            } else {
                // 单选语义：点**未选中**的音符 → 清除旧选区（只操作当前这个）；
                // 点已选中但选区 = 1 → 保留选中（单音符拖动）
                if (!n.selected) app.clearNoteSelection();
                app.piano.drag_note = hit.index;
                app.piano.drag_note_mode = hit.mode;
                // 历史：拖动结束（松手）时 coalesce 提交
                app.history_pending = switch (hit.mode) {
                    .body => "移动音符",
                    .left, .right => "拉伸音符",
                };
                // 拉伸基准（**按下时快照**）：原起点/原长/按下步——
                // 增量式拉伸全程以它为锚（长度 = 原长 + k×格），避免“每帧以自身为基准”漂移
                app.piano.drag_orig_step = n.step;
                app.piano.drag_orig_len = n.len;
                app.piano.drag_down_step = step_i;
                app.piano.rememberNote(n); // 记住：新音符放置沿用其 长度/力度/声像
                app.piano.drag_grab_step = step_i - n.step;
                app.piano.drag_grab_pitch = pitch_i - n.pitch;
                // 拖动死区：先记录按下位置；超过阈值才真正编辑（防单击吸附）
                app.piano.drag_armed = false;
                app.piano.drag_down_x = ui.mouse_x;
                app.piano.drag_down_y = ui.mouse_y;
                // 点击已有音符 → 试听（按住不放持续发声）。
                // **不发声的两种情况**（按设计）：
                // - 音符已选中（框选选区）——单击/拖动均不发声；
                // - 拖边缘改长度——任何音符都不发声。
                if (!n.selected and hit.mode == .body) {
                    app.piano.held_pitch = n.pitch;
                    app.auditionOn(n.pitch);
                }
            }
        } else {
            // 新音符长度：沿用**上一个被点击/编辑过的音符**（无参考时 = 当前吸附格）
            // 注：**允许重叠**（与 MIDI 一致）——不再拦截；
            // 放置新音符时**取消选区**（符合直觉：新建 = 新焦点）
            app.clearNoteSelection();
            const new_len: i32 = if (app.piano.last_note_len > 0) app.piano.last_note_len else @max(1, snap_steps);
            // 力度/声像沿用“上一个被点击/编辑音符”（无参考 → model 默认）；
            // 与长度同一交互逻辑（`rememberNote` 三件套）
            const new_vel: i32 = app.piano.last_note_velocity orelse model.default_velocity;
            const new_pan: i32 = app.piano.last_note_pan orelse model.default_pan;
            {
                app.addNote(.{ .step = snap_step, .len = new_len, .pitch = pitch_i, .pattern = pattern, .instrument = app.sel.instrument, .velocity = new_vel, .pan = new_pan });
                app.piano.rememberNote(app.notes.items[app.notes.items.len - 1]); // 放置的音符本身成为“上一个”
                // **放置即拖拽**：新音符立即进入拖动状态（按住左键可直接拖着跑）；
                // 历史：拖动结束时 coalesce 提交（放置+拖动 = 一条“放置音符”）
                app.history_pending = "放置音符";
                // **放置即拖拽**：新音符立即进入拖动状态（按住左键可直接拖着跑）
                app.piano.drag_note = app.notes.items.len - 1;
                app.piano.drag_note_mode = .body;
                app.piano.drag_grab_step = 0;
                app.piano.drag_grab_pitch = 0;
                app.piano.drag_orig_step = snap_step;
                app.piano.drag_orig_len = new_len;
                app.piano.drag_down_step = step_i;
                // 新放置的音符视为“已拖动”（用户正按住左键）
                app.piano.drag_armed = true;
                app.piano.drag_down_x = ui.mouse_x;
                app.piano.drag_down_y = ui.mouse_y;
                // 放置时发声（按住不放持续发声）
                app.piano.held_pitch = pitch_i;
                app.auditionOn(pitch_i);
            }
        }
    }

    // 拖动 / 拉伸更新（带**死区**：位移超过 3px 才真正编辑——
    // 否则单击音符会在按下当帧被吸附，位置/长度跳变）
    if (ui.mouse_down) {
        // ── 批量拖动（选区 ≥ 2 中部拖动）──
        if (app.piano.drag_batch) {
            if (!app.piano.drag_armed) {
                const dx = ui.mouse_x - app.piano.drag_down_x;
                const dy = ui.mouse_y - app.piano.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.piano.drag_armed = true;
            }
            if (app.piano.drag_armed) {
                // 位移吸附到网格（与单音符一致：以**最左选中音符**的起点吸附）
                const d_step_raw = step_i - app.piano.batch_down_step;
                const d_pitch = pitch_i - app.piano.batch_down_pitch;
                // 吸附：位移 = 网格格数 × 格宽（round）
                const d_step = model.snapRound(d_step_raw, snap_steps);
                _ = app.moveSelectedNotes(d_step, d_pitch);
            }
        }
        // ── 批量拉伸（选区 ≥ 2 边缘拖动）──
        if (app.piano.batch_trim) {
            if (!app.piano.drag_armed) {
                const dx = ui.mouse_x - app.piano.drag_down_x;
                const dy = ui.mouse_y - app.piano.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.piano.drag_armed = true;
            }
            if (app.piano.drag_armed) {
                const g = app.piano.batch_trim_grid;
                // 位移 → 格数（左缘：左移为正、右缘：右移为正；与单音符增量式一致）
                const delta = if (app.piano.drag_note_mode == .left)
                    app.piano.batch_trim_down_step - step_i // 左缘：左移为正（加长）
                else
                    step_i - app.piano.batch_trim_down_step; // 右缘：右移为正（加长）
                const k = model.gridSteps(delta, g);
                _ = app.applyBatchTrim(k, g, app.piano.drag_note_mode == .left);
            }
        }
        if (app.piano.drag_note) |ni| {
            if (!app.piano.drag_armed) {
                const dx = ui.mouse_x - app.piano.drag_down_x;
                const dy = ui.mouse_y - app.piano.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.piano.drag_armed = true;
            }
            if (app.piano.drag_armed and ni < app.notes.items.len) {
                const n = &app.notes.items[ni];
                switch (app.piano.drag_note_mode) {
                    .right => {
                        // 右缘：长度 = **原长 + k×格**（网格决定增减步长：
                        // 鼠标过半格即 ±一格，往回拖按格递减，不会跳到无关格线）
                        // 注：允许重叠——不再拦截
                        const delta = step_i - app.piano.drag_down_step;
                        const new_len = model.trimLenByGrid(app.piano.drag_orig_len, delta, snap_steps);
                        if (new_len != n.len) {
                            n.len = new_len;
                            app.piano.rememberNote(n.*); // 记住编辑后的 长度/力度/声像
                            app.dirty = true;
                        }
                    },
                    .left => {
                        // 左缘：右端固定；长度同增量式（鼠标左移 = 拉长、右移 = 缩短），
                        // 且不能展开到样式第 1 步之前（new_step >= 0）
                        // 注：允许重叠——不再拦截
                        const right = app.piano.drag_orig_step + app.piano.drag_orig_len;
                        const min_len = model.trimMinGridLen(app.piano.drag_orig_len, snap_steps);
                        const delta = app.piano.drag_down_step - step_i; // 左移为正（拉长方向）
                        const len = @min(model.trimLenByGrid(app.piano.drag_orig_len, delta, snap_steps), right);
                        if (model.noteTrimLeft(n.*, right - len, right, min_len)) |nn| {
                            n.* = nn;
                            app.piano.rememberNote(nn); // 记住编辑后的 长度/力度/声像
                            app.dirty = true;
                        }
                    },
                    .body => {
                        // 中部：移动（**目标位置**吸附到网格；音高自由）
                        // 注：吸附的是音符起点（而非鼠标），否则抓取点不在格上时会脱离网格。
                        const target = @max(0, step_i - app.piano.drag_grab_step);
                        const new_step = @max(0, model.snapRound(target, snap_steps));
                        const new_pitch = std.math.clamp(pitch_i - app.piano.drag_grab_pitch, 0, 127);
                        // 注：允许重叠——不再拦截
                        if (new_step != n.step or new_pitch != n.pitch) {
                            const pitch_changed = new_pitch != n.pitch;
                            n.step = new_step;
                            n.pitch = new_pitch;
                            app.dirty = true;
                            // 拖动换音高 → 重触发试听（滑奏；行高亮/琴键高亮跟随）。
                            // 仅当按下时已开始试听（held_pitch 非空）——
                            // 选中音符/边缘拖动不发声，拖中也不应冒出声音
                            if (pitch_changed and app.piano.held_pitch != null) {
                                if (app.piano.held_pitch) |hp| app.auditionOff(hp);
                                app.piano.held_pitch = new_pitch;
                                app.auditionOn(new_pitch);
                            }
                        }
                    },
                }
            }
        }
    } else {
        app.piano.drag_note = null;
        app.piano.drag_armed = false; // 下次按下重新评估死区
        app.piano.drag_batch = false;
        app.piano.batch_trim = false;
        // 松开：停止试听（仅当不是琴键试听拖动时——琴键有自己的生命周期）
        if (ui.active_id != 6000 and app.piano.held_pitch != null) {
            if (app.piano.held_pitch) |hp| app.auditionOff(hp);
            app.piano.held_pitch = null;
        }
    }

    // 纵向滚动（128 个音高）+ 右侧滚动条
    // 注：滚轮命中区**含编辑轨**（在轨上滚 = 与音符区同款滚动/缩放）
    const content_h: i32 = 128 * app.piano.key_h;
    // Alt+滚轮（音符区）：调**距鼠标最近的音符**的力度/声像
    // （有选区时 → 全部选中整体增减；见 `view_note_lane.altWheelAdjust`）。
    // 在编辑轨上的 Alt+滚轮由 `view_note_lane.draw` 自己处理（“最近”
    // 标准不同：柱条末端而非音符矩形）——这里用 `lane_y..lane_y+lane_h` 避开。
    if (ui.wheel != 0 and ui.wheel_alt and !app.piano.nav_active and ui.hitRect(lane_x, lane_y, view_w, lane_h - 3)) {
        const mode = app.piano.lane_mode;
        const near = view_note_lane.nearestNoteInPiano(app, ui.mouse_x, ui.mouse_y, lane_x, lane_y, step_ws, scroll_s, app.piano.key_h, app.piano.scroll, pattern);
        if (view_note_lane.altWheelAdjust(app, mode, ui.wheel, near)) {
            app.touchGesture(if (mode == .velocity) "调整力度" else "调整声像");
        }
        ui.wheel = 0; // 消费
    }
    // 中键拖动中：屏蔽滚轮（含 Ctrl/Shift 缩放）——缩放会让锚定比例失准、
    // 拖动跟随抽动（用户约定：拖动期间只平移，不缩放）
    if (!app.piano.nav_active and !ui.wheel_alt and ui.hitRect(main_x, lane_y, main_w, lane_h + splitter_h + editor_h)) {
        if (ui.wheel_ctrl) {
            // Ctrl+滚轮：横向缩放——**只更新补间目标**（滚轮离散，逐帧平滑逼近；
            // 补间块在本段之后；锚定用事件时的鼠标偏移，补间每一步都锚定）
            // 注：拉回**无条件执行**（不只在 zoom 变化时）——
            // 否则“已缩到下限 + 视口停在右侧空白”时下滚会无事发生。
            app.piano.zoom_anchor_off = ui.mouse_x - lane_x;
            var tgt = app.piano.zoom_target;
            // 反向输入先抵消未完成的补间（同播放列表；实测手感 bug）
            if ((ui.wheel > 0 and tgt < app.piano.zoom) or (ui.wheel < 0 and tgt > app.piano.zoom)) tgt = app.piano.zoom;
            // 下限取 min(动态下限，当前)：内容缩短（动态下限被动抬高）时
            // 不得把视口突然放大——只拦“继续缩小”。
            app.piano.zoom_target = std.math.clamp(tgt * std.math.pow(f32, util.wheel_zoom_factor, @as(f32, @floatFromInt(ui.wheel))), @min(dyn_zoom_min, tgt), 8.0);
            // 缩小/已到下限：把视口右缘拉回内容跨度内（全装得下 → 贴左）——悬空量保留
            const vcw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / app.piano.zoom)));
            const over: i32 = @max(0, app.piano.scroll_x - @max(0, content_span - vcw));
            app.piano.scroll_x = Ui.clampScrollToSpan(app.piano.scroll_x, vcw, content_span) + over;
        } else if (ui.wheel_shift) {
            // Shift+滚轮：**纵向缩放**（音高行高）——只设补间目标（补间块在本段之后）
            app.piano.key_h_anchor_off = ui.mouse_y - lane_y;
            var tgt = app.piano.key_h_target;
            // 反向输入先抵消未完成的补间（同横向缩放；实测手感 bug）
            if ((ui.wheel > 0 and tgt < app.piano.key_h) or (ui.wheel < 0 and tgt > app.piano.key_h)) tgt = app.piano.key_h;
            app.piano.key_h_target = std.math.clamp(tgt + ui.wheel * 2, zoom_min_h, util.piano_key_h_max);
        } else {
            // 裸滚轮：纵向滚动——只设补间目标（滚轮离散 → 逐帧平滑）
            app.piano.scroll_target = std.math.clamp(app.piano.scroll_target - util.scrollDelta(ui), 0, @max(0, content_h - lane_h));
        }
    }

    // ── 横向缩放的**补间动画**（同播放列表：滚轮离散，逐帧平滑逼近）──
    // 目标由 Ctrl+滚轮设置；他处改变 zoom（滚动条拖边缘、载入工程）→ 采纳为目标不补间。
    {
        const p = &app.piano;
        if (p.zoom_anim_last < 0.0 or p.zoom != p.zoom_anim_last) p.zoom_target = p.zoom;
        if (p.zoom != p.zoom_target) {
            const z_new = if (@abs(p.zoom_target - p.zoom) <= p.zoom_target * 0.002)
                p.zoom_target
            else
                util.glideF32(p.zoom, p.zoom_target, app.frame_dt_ns, 0.03);
            if (z_new > 0 and z_new != p.zoom) {
                const vcw_now: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / p.zoom)));
                const over: i32 = @max(0, p.scroll_x - @max(0, content_span - vcw_now)); // 悬空量保留
                p.scroll_x = Ui.zoomAnchoredScrollX(p.scroll_x, view_w, p.zoom_anchor_off, p.zoom, z_new, content_span, content_span) + over;
                p.zoom = z_new;
            }
        }
        p.zoom_anim_last = p.zoom;
    }
    // ── 纵向补间（Shift+滚轮 = 音高行高；裸滚轮 = 纵向滚动；τ=0.03 同横向）──
    {
        const p = &app.piano;
        if (p.key_h_anim_last < 0 or p.key_h != p.key_h_anim_last) p.key_h_target = p.key_h;
        if (p.key_h != p.key_h_target) {
            const h_new = if (@abs(p.key_h_target - p.key_h) <= 1)
                p.key_h_target
            else
                util.glideI32(p.key_h, p.key_h_target, app.frame_dt_ns, 0.03);
            if (h_new > 0 and h_new != p.key_h) {
                p.scroll = Ui.zoomAnchoredScrollY(p.scroll, lane_h, p.key_h_anchor_off, p.key_h, h_new, 128 * h_new);
                p.key_h = h_new;
            }
        }
        p.key_h_anim_last = p.key_h;
        const ch_now: i32 = 128 * @max(1, p.key_h);
        const max_s: i32 = @max(0, ch_now - lane_h);
        if (p.scroll_anim_last < 0 or p.scroll != p.scroll_anim_last) p.scroll_target = p.scroll;
        p.scroll_target = std.math.clamp(p.scroll_target, 0, max_s);
        if (p.scroll != p.scroll_target) {
            const s_new = if (@abs(p.scroll_target - p.scroll) <= 1)
                p.scroll_target
            else
                util.glideI32(p.scroll, p.scroll_target, app.frame_dt_ns, 0.03);
            p.scroll = std.math.clamp(s_new, 0, max_s);
        }
        p.scroll_anim_last = p.scroll;
    }
    // ── 中键拖动：平移视口（仅音符网格区；抓画布：内容跟手）──
    {
        const p = &app.piano;
        if (!p.nav_active and ui.mouse_middle_pressed and
            util.hitUI(ui, lane_x, lane_y, view_w, lane_h))
        {
            p.nav_active = true;
            p.nav_mx = ui.mouse_x;
            p.nav_my = ui.mouse_y;
            p.nav_scroll_x0 = p.scroll_x;
            p.nav_scroll_y0 = p.scroll;
        }
        if (p.nav_active) {
            if (!ui.mouse_middle_down) {
                p.nav_active = false;
            } else {
                // 从**原点**重算（拖出范围后回拖立即响应，不会积累死区）
                // 横向：**悬空出口**——不设地图上限（内部防溢出帽同滚动条控件）
                // 屏幕位移 → 内容像素（/zoom）——“鼠标移 1px、内容移 1px”的 1:1
                const dx_c = util.screenToContentPx(ui.mouse_x - p.nav_mx, p.zoom);
                p.scroll_x = std.math.clamp(p.nav_scroll_x0 - dx_c, 0, 1 << 30);
                p.scroll = std.math.clamp(p.nav_scroll_y0 - (ui.mouse_y - p.nav_my), 0, @max(0, content_h - lane_h));
            }
        }
    }
    // ── 视角跟随播放游标（与播放列表**共用开关**；主动操作优先）──
    // 关键：跟的必须是**屏幕上那个游标**——
    //   SONG 模式 = 全局步换算到当前片段局部步（同播放游标绘制逻辑；不在片段内/无片段
    //   → 屏幕上无游标，不跟）；PAT 模式 = `piano_step`。
    //   （曾错跟 `piano_step`：SONG 播放期间它是冻结值 → 视角跟了个静止点）
    // 主动操作判定同播放列表：中键平移 / 横向滚动条拖动或边缘缩放（其 id=10）；纯即时恢复。
    {
        const p = &app.piano;
        // **平滑小数步**（子步 + 渲染侧前馈/收敛；音频缓冲量化不显——实测“游标还是抖”的终解。
        // 与游标绘制同一映射。）
        const cur_step: ?f32 = if (app.sel.song_mode) blk: {
            const c = app.patOriginClip() orelse break :blk null;
            if (model.clipSongToLocal(c, app.playback.song_step) == null) break :blk null;
            break :blk app.cursorDisplay(true) - @as(f32, @floatFromInt(c.start)) + @as(f32, @floatFromInt(c.offset));
        } else app.cursorDisplay(false);
        const nav = p.nav_active or ui.active_id == 10;
        // 主动操作优先（纯即时：宽限/桥接已删）：中键/滚动条按住暂停，松手当帧恢复
        if (cur_step) |st| {
            if (app.playlist.follow_playhead and app.playing and !nav) {
                const cur_px: f32 = st * @as(f32, @floatFromInt(util.piano_step_w));
                // 锚点口径 = **内容区（网格区）**（用户确认以网格区为准）
                const off_screen: f32 = util.follow_anchor_frac * @as(f32, @floatFromInt(view_w));
                const vcw_f: f32 = @as(f32, @floatFromInt(view_w)) / p.zoom;
                const vcw_i: i32 = @max(1, @as(i32, @intFromFloat(vcw_f)));
                // **软锚定**（同播放列表）：有余量 → 锚点；余量耗尽 → 就势放开
                const follow_span: i32 = content_span;
                const target = util.followTargetScrollX(cur_px, view_w, p.zoom, off_screen, follow_span);
                p.scroll_x = Ui.clampScrollToSpan(util.followGlide(p.scroll_x, target, app.frame_dt_ns), vcw_i, follow_span);
            }
        }
    }
    _ = ui.scrollbarV(11, sb_x, lane_y, ruler_h, lane_h, &app.piano.scroll, content_h, lane_h);
    ui.renderer.vline(sb_x, lane_y, lane_h, ui.theme.panel_border);

    // ── 力度/声像编辑轨（分割条已在布局最前处理）──
    const editor_y2 = lane_y + lane_h + splitter_h;
    const lane_changed = view_note_lane.draw(ui, app, x + 1, editor_y2, w - 2, editor_h, lane_x, step_ws, scroll_s, scroll_x0, zoom, pattern, snap_steps);
    // 编辑轨改动：coalesce 提交（拖动中每帧置 pending，松手后帧末提交一条）
    if (lane_changed) {
        app.history_pending = if (app.piano.lane_mode == .velocity) "调整力度" else "调整声像";
    }

    // ── 编辑快捷键执行（框选/批量；按当前视图上下文）──
    // 由 main 的键盘处理登记（`pending_edit_op`）；本视图消费后清除。
    if (app.pending_edit_op) |op| {
        switch (op) {
            .delete_selected => {
                const n = app.deleteSelectedNotes();
                if (n > 0) {
                    app.setToastWith("已删除 {d} 个音符", .{n});
                    app.commitHistory("删除音符");
                }
            },
            .clone_right => {
                const n = app.cloneSelectedNotesRight();
                if (n > 0) {
                    app.setToastWith("已克隆 {d} 个音符（选区已移至克隆体）", .{n});
                    app.commitHistory("克隆音符");
                }
            },
            .copy => {
                const n = app.copySelectedNotes();
                if (n > 0) app.setToastWith("已复制 {d} 个音符", .{n});
            },
            .paste => {
                // 粘贴到**鼠标位置**（音高不变；step = 鼠标所在步）
                const anchor = @max(0, snap_step);
                const n = app.pasteNotes(pattern, app.sel.instrument, anchor);
                if (n > 0) {
                    app.setToastWith("已粘贴 {d} 个音符", .{n});
                    app.commitHistory("粘贴音符");
                }
            },
            .select_all => {
                const n = app.selectAllNotes(pattern, app.sel.instrument);
                if (n > 0) app.setToastWith("已全选 {d} 个音符", .{n});
            },
        }
        app.pending_edit_op = null;
    }

    // ── 键盘移动选中音符（Shift/Ctrl+方向键；main 登记，钳制在 App 侧）──
    // Shift（细移）：部分钳制（同拖动）；Ctrl（粗移）：全有或全无（防拍位/级数漂移）
    // 连按合并为一条历史（与滚轮同一机制：静默 0.6s 后提交）
    if (app.pending_move) |mv| {
        const changed = if (mv.exact)
            app.nudgeSelectedNotesExact(mv.d_step, mv.d_pitch)
        else
            app.nudgeSelectedNotes(mv.d_step, mv.d_pitch);
        if (changed) {
            app.touchGesture("移动音符");
        }
        app.pending_move = null;
    }

    // 吸附网格下拉（在**全部内容之后** → 绘制在最上层，不会被标尺/音符区盖住）
    if (app.piano.snap_menu_open and snap_btn_x + 40 < x + w - 24) {
        _ = util.snapSelectorMenu(ui, snap_btn_x, y + util.title_h, &app.piano.snap, &app.piano.snap_menu_open, snap_clicked);
    }
    // 乐器下拉（同样在最上层；与网格选单互斥——同时只会开一个）
    if (app.piano.inst_menu_open and inst_btn_x + 40 < x + w - 24) {
        // 池化：乐器数量无上限——按实际数量堆分配名字列表（逐帧短暂持有）
        const names = std.heap.page_allocator.alloc([]const u8, app.instruments.items.len) catch return;
        defer std.heap.page_allocator.free(names);
        for (app.instruments.items, 0..) |inst2, ii| names[ii] = inst2.name;
        const inst_before = app.sel.instrument;
        _ = util.titleSelectorMenu(ui, inst_btn_x, y + util.title_h, names, &app.sel.instrument, &app.piano.inst_menu_open, inst_clicked, 170);
        // 切换乐器 → 清选区（防跨乐器孤儿选区；见 App.setInstrument）
        if (app.sel.instrument != inst_before) app.clearNoteSelection();
    }
}

// ── 键列行配色（纯函数；便于测试）──

/// 键列一行的“底色 + 文字色”
pub const KeyRowStyle = struct { bg: u32, text: u32 };

/// 决定键列一行怎么画：
/// - 钢琴模式：黑白键底色 + `key_label` 字（C 行音名），不变；
/// - **鼓组模式：不用钢琴黑白键**（用户反馈：白键底 + 已映射垫的亮字对比度
///   太低）——改成“槽位列表”样式（与鼓组编辑器左列表一致）：普通行用底色
///   + 暗字（GM 名可读）、**已映射行**提亮（`slider_track`）+ 亮字 + 强调条；
///   发声中/试听统一用强调色底。
pub fn keyRowStyle(theme: *const Theme, drum: bool, black: bool, pressed: bool, mapped: bool) KeyRowStyle {
    if (pressed) return .{ .bg = theme.accent, .text = theme.text };
    if (drum) {
        return if (mapped)
            .{ .bg = theme.slider_track, .text = theme.text }
        else
            .{ .bg = theme.bg, .text = theme.text_dim };
    }
    return .{ .bg = if (black) theme.key_black else theme.key_white, .text = theme.key_label };
}

test "pianoroll: 键列配色——鼓组模式不用钢琴黑白键（修白底亮字对比度）" {
    const theme = Theme{};
    // 鼓组 + 已映射：暗底、亮字、不出现白键底
    const m = keyRowStyle(&theme, true, false, false, true);
    try std.testing.expectEqual(theme.slider_track, m.bg);
    try std.testing.expectEqual(theme.text, m.text);
    try std.testing.expect(m.bg != theme.key_white);
    // 鼓组 + 未映射：底色 + 暗字（可读）
    const u = keyRowStyle(&theme, true, false, false, false);
    try std.testing.expectEqual(theme.bg, u.bg);
    try std.testing.expectEqual(theme.text_dim, u.text);
    // 鼓组下“黑键行”与白键行一视同仁（不再有黑白之分）
    try std.testing.expectEqual(m.bg, keyRowStyle(&theme, true, true, false, true).bg);
    try std.testing.expectEqual(u.bg, keyRowStyle(&theme, true, true, false, false).bg);
    // 钢琴模式保持黑白键
    try std.testing.expectEqual(theme.key_white, keyRowStyle(&theme, false, false, false, false).bg);
    try std.testing.expectEqual(theme.key_black, keyRowStyle(&theme, false, true, false, false).bg);
    // 发声中（两种模式）优先 = 强调色底
    try std.testing.expectEqual(theme.accent, keyRowStyle(&theme, true, false, true, true).bg);
    try std.testing.expectEqual(theme.accent, keyRowStyle(&theme, false, false, true, false).bg);
}
