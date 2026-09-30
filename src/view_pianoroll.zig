//! 钢琴卷帘视图：琴键列 + 音符编辑 + 乐器选择器。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const model = @import("model.zig");
const util = @import("view_util.zig");

pub fn draw(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    const pattern = app.piano.pattern orelse return;
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "钢琴卷帘 — 样式 {d}", .{pattern + 1}) catch "钢琴卷帘";
    ui.panelTitled(x, y, w, h, title);

    const ruler_h: i32 = 20; // 标尺行高 = 滚动条厚度（与播放列表一致）
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;

    const main_x = x + 1;
    const main_w = w - 2 - ruler_h;
    const sb_x = x + w - 1 - ruler_h;
    const hsb_y = list_y;
    const ruler_y = list_y + ruler_h;
    const lane_y = list_y + ruler_h * 2; // 音符区顶部
    const lane_h = list_h - ruler_h * 2;
    const keys_x = main_x;
    const lane_x = main_x + util.piano_header_w;
    const view_w = @max(1, main_w - util.piano_header_w);
    // 每小节步数由**拍号**决定（动态；App 字段）
    const spb: i32 = app.steps_per_bar;
    const bar_w = spb * util.piano_step_w;

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
        _ = ui.scrollbarTimelineEx(10, x + 1, hsb_y, w - 2, ruler_h, &app.piano.scroll_x, &app.piano.content_w, &app.piano.zoom, view_w, min_content, dyn_zoom_min, 8.0, mini_buf[0..nmini]);
    }
    ui.renderer.hline(x + 1, ruler_y, w - 2, ui.theme.panel_border);

    // 横向缩放：内容坐标 → 屏幕坐标（本帧最终值）
    const zoom: f32 = app.piano.zoom;
    const step_ws: f32 = @as(f32, @floatFromInt(util.piano_step_w)) * zoom; // 屏幕上的步宽
    const bar_ws: f32 = @as(f32, @floatFromInt(bar_w)) * zoom; // 屏幕上的小节宽
    const scroll_s: f32 = @as(f32, @floatFromInt(app.piano.scroll_x)) * zoom; // 屏幕上的滚动量

    // 局部小节标尺
    ui.renderer.fillRect(main_x, ruler_y, main_w, ruler_h, ui.theme.toolbar);
    {
        const saved = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h);
        defer ui.renderer.popClip(saved);
        var bar: i32 = @divFloor(app.piano.scroll_x, bar_w) + 1;
        while (true) : (bar += 1) {
            const bx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar - 1)) * bar_ws - scroll_s));
            if (bx > main_x + main_w) break;
            ui.renderer.vline(bx, ruler_y, ruler_h, ui.theme.panel_border);
            var buf: [8]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{bar}) catch "";
            ui.label(t, bx + 3, ruler_y + 1, ui.theme.text_dim);
        }
    }
    ui.renderer.vline(sb_x, ruler_y, ruler_h, ui.theme.panel_border); // □ 缺口左边界
    ui.renderer.vline(lane_x, ruler_y, ruler_h, ui.theme.panel_border); // 琴键列分界
    ui.renderer.hline(x + 1, lane_y, w - 2, ui.theme.panel_border);

    // □ 缺口：按住上下拖 = 音高行高缩放（方块本身固定不动；视口中心音高保持不动）
    {
        const old_h = app.piano.key_h;
        if (ui.zoomSquare(13, sb_x, ruler_y, ruler_h, &app.piano.key_h, util.piano_key_h_min, util.piano_key_h_max, 2) and app.piano.key_h != old_h) {
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
        const menu_blocks = app.rack.inst_menu_open or app.rack.add_menu_open or app.rack.ctx_instrument != null;
        const in_keys = !menu_blocks and ui.hitRect(keys_x, lane_y, util.piano_header_w, lane_h);
        const over_other_drag = ui.active_id != 0 and ui.active_id != 6000;
        const pitch_at_mouse: i32 = 127 - @divFloor(ui.mouse_y - lane_y + app.piano.scroll, kh);

        if (in_keys and ui.mouse_pressed and !over_other_drag) {
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
        const rows: i32 = @divFloor(lane_h, kh) + 2;
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const p = first_pitch - i;
            if (p < 0) break;
            const py = lane_y + (127 - p) * kh - app.piano.scroll;
            if (py + kh < lane_y or py > lane_y + lane_h) continue;
            const black = model.isBlackKey(p);
            const pressed = lit(app, p); // 按下/发声中高亮（与行高亮联动）
            const key_color = if (pressed)
                ui.theme.accent
            else if (black)
                ui.theme.key_black
            else
                ui.theme.key_white;
            ui.renderer.fillRect(keys_x + 1, py, util.piano_header_w - 1, kh - 1, key_color);
            if (!black) {
                var buf: [8]u8 = undefined;
                const nm = model.pitchName(&buf, p);
                if (nm.len > 0 and nm[0] == 'C') {
                    ui.labelClipped(nm, keys_x + util.piano_header_w - 34, py - 2, 30, if (pressed) ui.theme.text else ui.theme.key_label);
                }
            }
            // 行线（每八度加强）
            ui.renderer.hline(lane_x, py, view_w, if (@mod(p, 12) == 0) ui.theme.panel_border else ui.theme.grid);
        }

        // 步网格（竖线；每小节加强）。
        // 时间轴网格（与播放列表共用 `util.drawTimelineGrid`；U=96 对齐）。
        // 该函数内部自行裁剪到音符区（含细小缩放时只画小节线的降级）。
        util.drawTimelineGrid(
            &ui.renderer,
            &ui.theme,
            lane_x,
            view_w,
            lane_y,
            lane_h,
            lane_x,
            app.piano.scroll_x,
            zoom,
            @floatFromInt(util.piano_step_w),
            spb,
            model.stepsPerBeat(app.time_den),
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

        // 音符（当前样式 + 当前乐器）——**单独裁剪到音符区**：
        // 外层裁剪含琴键列（main_x 起），不收紧的话左滚时音符会压到琴键上（实测 bug）
        {
            const saved_notes = ui.renderer.pushClip(lane_x, lane_y, view_w, lane_h);
            defer ui.renderer.popClip(saved_notes);
            for (app.notes.items, 0..) |n, ni| {
                if (n.pattern != pattern or n.instrument != app.sel.instrument) continue;
                const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
                const ny = lane_y + (127 - n.pitch) * kh - app.piano.scroll;
                const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
                if (nx + nw < lane_x or nx > lane_x + view_w) continue;
                if (ny + kh < lane_y or ny > lane_y + lane_h) continue;
                const active = if (app.piano.drag_note) |dn| dn == ni else false;
                const note_color = if (active) ui.theme.accent else ui.theme.waveform;
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
                        const ty = ny + @divTrunc(kh - 1 - 10, 2);
                        const tx = nx + 4;
                        // 白字（黑键行上也清楚）；拖动中反色以保持对比度
                        ui.label(pname, tx, ty, if (active) ui.theme.bg else r_mod.rgb(16, 18, 22));
                    }
                }
            }
        }
    }
    ui.renderer.vline(lane_x, lane_y, lane_h, ui.theme.panel_border); // 琴键列与音符区分界

    // ── 播放游标（PAT：独立自由设置；SONG：由全局换算，无片段时不显示/不可设置）──
    {
        // 裁剪到「标尺行 + 音符区」：左滚时游标 x 会变负，不裁剪会画到琴键列/左侧面板上（实测 bug）
        const saved_cursor = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h + lane_h);
        defer ui.renderer.popClip(saved_cursor);

        // 局部步 → 屏幕 x（内容像素 → 屏幕：乘 zoom）
        const localStepX = struct {
            fn f(step: i32, lx: i32, sw: f32, ss: f32) i32 {
                return lx + @as(i32, @intFromFloat(@as(f32, @floatFromInt(step)) * sw - ss));
            }
        }.f;

        if (app.sel.song_mode) {
            // SONG：找当前样式最左片段 → 全局步换算为局部步；无片段/不在范围内不显示
            if (model.leftmostClipFor(app.clips.items, pattern)) |c| {
                if (model.clipSongToLocal(c, app.playback.song_step)) |local| {
                    util.drawCursor(ui, localStepX(local, lane_x, step_ws, scroll_s), ruler_y, ruler_h, lane_y + lane_h, app.playing);
                }
                // 设置：局部 → 全局（超出片段可见范围 → 归位到片段起点）
                const in_ruler = ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
                if (in_ruler and ui.mouse_pressed) {
                    ui.active_id = 7100;
                }
                if (ui.active_id == 7100) {
                    if (!ui.mouse_down) {
                        ui.active_id = 0;
                    } else {
                        const content_px: i32 = app.piano.scroll_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom));
                        const local = @max(0, @divFloor(content_px * spb, bar_w));
                        // 超出可见范围 → 归位到片段起点（局部 offset）；跳转（播放中重置传输）
                        app.jumpPlaybackCursor(model.clipLocalToSong(c, local) orelse c.start);
                    }
                }
            }
        } else {
            // PAT：局部步自由设置
            util.drawCursor(ui, localStepX(app.playback.piano_step, lane_x, step_ws, scroll_s), ruler_y, ruler_h, lane_y + lane_h, app.playing);
            const in_ruler = ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
            if (in_ruler and ui.mouse_pressed) {
                ui.active_id = 7200;
            }
            if (ui.active_id == 7200) {
                if (!ui.mouse_down) {
                    ui.active_id = 0;
                } else {
                    const content_px: i32 = app.piano.scroll_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom));
                    app.jumpPlaybackCursor(@max(0, @divFloor(content_px * spb, bar_w)));
                }
            }
        }
    }

    // ── 乐器选择器（标尺行左端空位：琴键列上方）──
    const menu_was_open = app.rack.inst_menu_open;
    {
        const btn_x = main_x + 1;
        const btn_y = ruler_y;
        const btn_w = util.piano_header_w - 1;
        const btn_h = ruler_h;
        app.rack.inst_btn_x = btn_x;
        app.rack.inst_btn_y = btn_y;
        app.rack.inst_btn_w = btn_w;
        app.rack.inst_btn_h = btn_h;
        const hovered = ui.hitRect(btn_x, btn_y, btn_w, btn_h);
        ui.renderer.fillRect(btn_x, btn_y, btn_w, btn_h, if (app.rack.inst_menu_open) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.toolbar);
        var ibuf: [48]u8 = undefined;
        const iname: []const u8 = if (app.sel.instrument >= 0 and app.sel.instrument < @as(i32, @intCast(app.instruments.items.len)))
            app.instruments.items[@intCast(app.sel.instrument)].name
        else
            "无乐器";
        const it = std.fmt.bufPrint(&ibuf, "{s} ▾", .{iname}) catch iname;
        ui.labelClipped(it, btn_x + 4, btn_y + 1, btn_w - 8, ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            app.rack.inst_menu_open = !app.rack.inst_menu_open;
            app.rack.add_menu_open = false;
            app.rack.ctx_instrument = null;
        }
        if (app.rack.inst_menu_open) {
            const n: i32 = @intCast(app.instruments.items.len);
            const mw: i32 = @max(btn_w + 60, 170);
            const mh: i32 = @max(1, n) * util.menu_item_h + 4;
            const mx = btn_x;
            const my = btn_y + btn_h;
            ui.renderer.fillRect(mx, my, mw, mh, ui.theme.panel);
            ui.renderer.strokeRect(mx, my, mw, mh, ui.theme.accent);
            if (n == 0) {
                ui.label("（通道机架为空）", mx + 8, my + 4, ui.theme.text_dim);
            }
            for (app.instruments.items, 0..) |inst2, ii| {
                const iy = my + 2 + @as(i32, @intCast(ii)) * util.menu_item_h;
                const ih = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, mw - 2, util.menu_item_h);
                if (ih) ui.renderer.fillRect(mx + 1, iy, mw - 2, util.menu_item_h, ui.theme.item_hover);
                const sel = app.sel.instrument == @as(i32, @intCast(ii));
                ui.labelClipped(inst2.name, mx + 8, iy + 2, mw - 16, if (sel) ui.theme.accent else ui.theme.text);
                if (ih and ui.mouse_pressed) {
                    app.sel.instrument = @intCast(ii);
                    app.rack.inst_menu_open = false;
                }
            }
            if (ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, mx, my, mw, mh) and !hovered) app.rack.inst_menu_open = false;
        }
    }
    // 菜单展开时的点击只归菜单：屏蔽音符交互一帧
    const menu_click = menu_was_open and ui.mouse_pressed;

    // ── 交互（音符区）──
    const in_lane = !menu_click and ui.hitRect(lane_x, lane_y, view_w, lane_h);
    // 鼠标 → 内容坐标（除以 zoom）→ 步号
    const mouse_cx: i32 = app.piano.scroll_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom));
    const step_i = @divFloor(mouse_cx, util.piano_step_w);
    const pitch_i = 127 - @divFloor(ui.mouse_y - lane_y + app.piano.scroll, app.piano.key_h);

    // 命中音符（下标 + 命中模式：中部 / 左缘 / 右缘，边缘区 8px）
    var note_hit: ?struct { index: usize, mode: model.NoteHitMode } = null;
    if (in_lane) {
        for (app.notes.items, 0..) |n, ni| {
            if (n.pattern != pattern or n.instrument != app.sel.instrument) continue;
            const nx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.step)) * step_ws - scroll_s));
            const ny = lane_y + (127 - n.pitch) * app.piano.key_h - app.piano.scroll;
            const nw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(n.len)) * step_ws)));
            if (ui.mouse_x >= nx and ui.mouse_x < nx + nw and ui.mouse_y >= ny and ui.mouse_y < ny + app.piano.key_h) {
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
                break;
            }
        }
    }

    // 光标：拖动中 → 十字箭头（音符可横竖拖动）；悬停边缘 → ↔
    if (app.piano.drag_note != null) {
        ui.cursor = .size_all;
    } else if (note_hit) |hit| {
        if (hit.mode != .body) ui.cursor = .resize_h;
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
        }
    }

    // 左键按下：拖动/拉伸音符，或空位放置（4 步）
    // 试听（单一真源 `held_pitch`）：
    // - 放置/点击音符 → 发声（按住不放 = 持续发声）
    // - 拖动中换音高 → 重触发（滑奏）
    if (ui.mouse_pressed and in_lane and step_i >= 0 and pitch_i >= 0 and pitch_i <= 127) {
        if (note_hit) |hit| {
            const n = app.notes.items[hit.index];
            app.piano.drag_note = hit.index;
            app.piano.drag_note_mode = hit.mode;
            app.piano.drag_note_right = n.step + n.len; // 拖左缘时右端固定
            app.piano.drag_grab_step = step_i - n.step;
            app.piano.drag_grab_pitch = pitch_i - n.pitch;
            // 点击已有音符 → 试听（按住不放持续发声）
            app.piano.held_pitch = n.pitch;
            app.auditionOn(n.pitch);
        } else {
            // 默认音符长度 = 四分之一小节（≈ 四分音符；U=96 时 4/4 → 24 步）
            const new_len: i32 = @max(1, @divTrunc(app.steps_per_bar, 4));
            if (!model.noteOverlaps(app.notes.items, app.notes.items.len, pattern, app.sel.instrument, step_i, new_len, pitch_i)) {
                app.addNote(.{ .step = step_i, .len = new_len, .pitch = pitch_i, .pattern = pattern, .instrument = app.sel.instrument });
                // **放置即拖拽**：新音符立即进入拖动状态（按住左键可直接拖着跑）
                app.piano.drag_note = app.notes.items.len - 1;
                app.piano.drag_note_mode = .body;
                app.piano.drag_grab_step = 0;
                app.piano.drag_grab_pitch = 0;
                // 放置时发声（按住不放持续发声）
                app.piano.held_pitch = pitch_i;
                app.auditionOn(pitch_i);
            }
        }
    }

    // 拖动 / 拉伸更新
    if (ui.mouse_down) {
        if (app.piano.drag_note) |ni| {
            if (ni < app.notes.items.len) {
                const n = &app.notes.items[ni];
                switch (app.piano.drag_note_mode) {
                    .right => {
                        // 右缘：改长度（最小 1 步）
                        const new_len = @max(1, step_i - n.step + 1);
                        if (!model.noteOverlaps(app.notes.items, ni, pattern, n.instrument, n.step, new_len, n.pitch)) {
                            n.len = new_len;
                            app.dirty = true;
                        }
                    },
                    .left => {
                        // 左缘：改起点+长度（右端固定；不能撞出局部第 1 步）
                        if (model.noteTrimLeft(n.*, step_i, app.piano.drag_note_right)) |nn| {
                            if (!model.noteOverlaps(app.notes.items, ni, pattern, nn.instrument, nn.step, nn.len, nn.pitch)) {
                                n.* = nn;
                                app.dirty = true;
                            }
                        }
                    },
                    .body => {
                        // 中部：移动（步 + 音高）
                        const new_step = @max(0, step_i - app.piano.drag_grab_step);
                        const new_pitch = std.math.clamp(pitch_i - app.piano.drag_grab_pitch, 0, 127);
                        if ((new_step != n.step or new_pitch != n.pitch) and
                            !model.noteOverlaps(app.notes.items, ni, pattern, n.instrument, new_step, n.len, new_pitch))
                        {
                            const pitch_changed = new_pitch != n.pitch;
                            n.step = new_step;
                            n.pitch = new_pitch;
                            app.dirty = true;
                            // 拖动换音高 → 重触发试听（滑奏；行高亮/琴键高亮跟随）
                            if (pitch_changed) {
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
        // 松开：停止试听（仅当不是琴键试听拖动时——琴键有自己的生命周期）
        if (ui.active_id != 6000 and app.piano.held_pitch != null) {
            if (app.piano.held_pitch) |hp| app.auditionOff(hp);
            app.piano.held_pitch = null;
        }
    }

    // 纵向滚动（128 个音高）+ 右侧滚动条
    const content_h: i32 = 128 * app.piano.key_h;
    if (ui.hitRect(main_x, lane_y, main_w, lane_h)) {
        if (ui.wheel_ctrl) {
            // Ctrl+滚轮：横向缩放（锚定鼠标下的内容）+ 内容区拉回
            // 注：拉回**无条件执行**（不只在 zoom 变化时）——
            // 否则“已缩到下限 + 视口停在右侧空白”时下滚会无事发生。
            const mouse_off = ui.mouse_x - lane_x;
            const old_zoom = app.piano.zoom;
            // 下限取 min(动态下限，当前)：内容缩短（动态下限被动抬高）时
            // 不得把视口突然放大——只拦“继续缩小”。
            const new_zoom = std.math.clamp(old_zoom * std.math.pow(f32, util.wheel_zoom_factor, @as(f32, @floatFromInt(ui.wheel))), @min(dyn_zoom_min, old_zoom), 8.0);
            if (new_zoom != old_zoom) {
                app.piano.zoom = new_zoom;
                app.piano.scroll_x = Ui.zoomAnchoredScrollX(app.piano.scroll_x, view_w, mouse_off, old_zoom, new_zoom, app.piano.content_w, content_span);
            }
            // 缩小/已到下限：把视口右缘拉回内容跨度内（全装得下 → 贴左）
            const vcw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / app.piano.zoom)));
            app.piano.scroll_x = Ui.clampScrollToSpan(app.piano.scroll_x, vcw, content_span);
        } else {
            app.piano.scroll = std.math.clamp(app.piano.scroll - util.scrollDelta(ui), 0, @max(0, content_h - lane_h));
        }
    }
    _ = ui.scrollbarV(11, sb_x, lane_y, ruler_h, lane_h, &app.piano.scroll, content_h, lane_h);
    ui.renderer.vline(sb_x, lane_y, lane_h, ui.theme.panel_border);
}
