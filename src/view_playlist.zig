//! 播放列表视图：时间轴 + 轨道行 + 片段编辑。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const model = @import("model.zig");
const util = @import("view_util.zig");

/// 片段在轨道内容区的绘制矩形（x / 宽；屏幕像素，含 zoom 换算）。
/// **边缘与格子对齐**（不缩进）；起点/终点各自取整 → 并排片段严格相接、无 1px 缝。
/// `step_px`：一步的**内容像素宽**（浮点；U=96 下每步很小）。
pub fn clipXW(c: model.Clip, lane_x: i32, step_px: f32, scroll_x: i32, zoom: f32) struct { x: i32, w: i32 } {
    const x0: f32 = (@as(f32, @floatFromInt(c.start)) * step_px - @as(f32, @floatFromInt(scroll_x))) * zoom;
    const x1: f32 = (@as(f32, @floatFromInt(c.start + c.len)) * step_px - @as(f32, @floatFromInt(scroll_x))) * zoom;
    const px0 = lane_x + @as(i32, @intFromFloat(@round(x0)));
    const px1 = lane_x + @as(i32, @intFromFloat(@round(x1)));
    return .{ .x = px0, .w = @max(1, px1 - px0) };
}

/// 样式配色（minimap / 片段色块）：按序号在色相上分布，保证相邻样式颜色可区分。
pub fn patternColor(pattern: i32) r_mod.Color {
    const palette = [_]r_mod.Color{
        r_mod.rgb(90, 170, 255), // 蓝
        r_mod.rgb(120, 210, 150), // 绿
        r_mod.rgb(230, 170, 90), // 橙
        r_mod.rgb(200, 120, 210), // 紫
        r_mod.rgb(230, 120, 130), // 红
        r_mod.rgb(120, 200, 230), // 青
    };
    const idx: usize = @intCast(@mod(pattern, @as(i32, @intCast(palette.len))));
    return palette[idx];
}

pub fn draw(ui: *Ui, app: *App, x: i32, y: i32, w: i32, h: i32) void {
    // 标题：`播放列表 (Playlist) — 工程名`（与钢琴卷帘的「钢琴卷帘 — 样式 N」同格式）；
    // 新工程未命名 / 非法路径时不带后缀；脏标记 `*` 附在工程名后。
    var title_buf: [192]u8 = undefined;
    const title: []const u8 = blk: {
        const name = app.projectName() orelse break :blk "播放列表 (Playlist)";
        if (app.dirty) {
            break :blk std.fmt.bufPrint(&title_buf, "播放列表 (Playlist) — {s}*", .{name}) catch "播放列表 (Playlist)";
        }
        break :blk std.fmt.bufPrint(&title_buf, "播放列表 (Playlist) — {s}", .{name}) catch "播放列表 (Playlist)";
    };
    ui.panelTitled(x, y, w, h, title);

    const header_w: i32 = 90; // 轨道名列宽
    const ruler_h: i32 = 20; // 标尺行高 = 滚动条厚度（横条高 = 纵条宽）
    const list_y = y + util.title_h;
    const list_h = h - util.title_h;

    const main_x = x + 1;
    const main_w = w - 2 - ruler_h; // 主区宽（右侧留出滚动条列）
    const sb_x = x + w - 1 - ruler_h; // 滚动条列：□ 缺口 + 纵向滚动条
    const hsb_y = list_y; // 横向滚动条行
    const ruler_y = list_y + ruler_h; // 标尺行（右端为 □ 缺口：自然留空）
    const tracks_y = list_y + ruler_h * 2;
    const tracks_h = list_h - ruler_h * 2;
    const lane_x = main_x + header_w;
    const view_w = @max(1, main_w - header_w); // 轨道内容可视宽度
    // 时间轴尺寸（与钢琴卷帘统一）：步 = U=96 单位；
    // 每步内容像素宽固定（`piano_step_w`）→ 一小节的像素宽随拍号变化。
    const spb: i32 = app.steps_per_bar;
    const step_px: f32 = @floatFromInt(util.piano_step_w);
    const bar_w: i32 = spb * util.piano_step_w; // 一小节的像素宽（未含 zoom）

    // ── 时间轴长度与缩放下限（**同一个值**，否则会出现“滑块有行程但拖不动”）──
    // 时间轴 = 内容右缘（保底 4 小节）+ 右侧 3 小节留白。
    // 缩放下限 = 视图恰好容纳整个时间轴 → 缩到底时滑块**满宽**（无假行程）。
    var max_end: i32 = 0; // 最右片段的结束步
    for (app.clips.items) |c| {
        max_end = @max(max_end, c.start + c.len);
    }
    const bars_right = @max(4, @divTrunc(max_end + spb - 1, spb)); // 向上取整到小节
    const timeline_w: i32 = (bars_right + 3) * bar_w;
    const min_content: i32 = @max(timeline_w, 1); // 滚动条时间轴下限
    const content_span: i32 = timeline_w; // 缩放拉回限制（同值）
    const dyn_zoom_min: f32 = @min(8.0, @as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(timeline_w)));

    // 横向时间轴滚动条（minimap 语义：拖主体=平移、拖端点继续拖=延长/回缩、拖边缘=缩放）
    {
        // minimap：所有片段按位置/长度映射（颜色区分样式）；**纵向 = 轨道位置**
        // （与钢琴卷帘 minimap 同一套值域映射：保底范围 + 中点居中，
        //  这样只用了少数几轨时也能看出轨道的层次）
        var mini_buf: [256]Ui.MiniBlock = undefined;
        var nmini: usize = 0;
        var min_track: i32 = 127;
        var max_track: i32 = 0;
        for (app.clips.items) |c| {
            min_track = @min(min_track, c.track);
            max_track = @max(max_track, c.track);
        }
        const track_range = model.rangeMap(min_track, max_track, 8); // 保底 8 轨高
        for (app.clips.items) |c| {
            if (nmini >= mini_buf.len) break;
            mini_buf[nmini] = .{
                // 步 → 内容像素（与时间轴同一尺度：step_px）
                .pos = @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.start)) * step_px)),
                .len = @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.len)) * step_px)),
                .kind = .note,
                // 纵向 = 轨道位置：**不反向**——播放列表是 track 0 在最上
                .y = track_range.yOf(c.track),
                .color = patternColor(c.pattern),
            };
            nmini += 1;
        }
        _ = ui.scrollbarTimelineEx(8, x + 1, hsb_y, w - 2, ruler_h, &app.playlist.scroll_x, &app.playlist.content_w, &app.playlist.zoom, view_w, min_content, dyn_zoom_min, 8.0, mini_buf[0..nmini]);
    }
    ui.renderer.hline(x + 1, ruler_y, w - 2, ui.theme.panel_border);

    // 横向缩放：内容坐标 → 屏幕坐标（本帧最终值；缩放块之后捕获）
    const zoom: f32 = app.playlist.zoom;
    const bar_ws: f32 = @as(f32, @floatFromInt(bar_w)) * zoom; // 屏幕上的小节宽
    const scroll_s: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) * zoom; // 屏幕上的滚动量

    // 小节标尺（随横向滚动与缩放；只画在轨道内容区上方）
    ui.renderer.fillRect(main_x, ruler_y, main_w, ruler_h, ui.theme.toolbar);
    {
        const saved = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h);
        defer ui.renderer.popClip(saved);
        var bar: i32 = @divFloor(app.playlist.scroll_x, bar_w) + 1;
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
    ui.renderer.vline(lane_x, ruler_y, ruler_h, ui.theme.panel_border); // 轨道名列分界（标尺行）
    ui.renderer.hline(x + 1, tracks_y, w - 2, ui.theme.panel_border);

    // □ 缺口：按住上下拖 = 轨道行高缩放（方块本身固定不动；视口中心内容保持不动）
    {
        const old_h = app.playlist.track_h;
        if (ui.zoomSquare(12, sb_x, ruler_y, ruler_h, &app.playlist.track_h, util.track_h_min, util.track_h_max, 2) and app.playlist.track_h != old_h) {
            const content_h_new: i32 = @intCast(app.track_items.len * @as(usize, @intCast(app.playlist.track_h)));
            app.playlist.scroll = Ui.zoomAnchoredScroll(app.playlist.scroll, tracks_h, old_h, app.playlist.track_h, content_h_new);
        }
    }

    // 行高必须在 □ 缩放块**之后**捕获：否则本帧会用「旧行高 + 新滚动偏移」绘制，
    // 每步缩放都会跳一帧（实测明显上下跳变），下一帧才恢复。
    const track_h: i32 = app.playlist.track_h;

    // 样式音域统计（每帧一次）：片段预览的纵向映射用（避免片段循环里重复扫全量音符）
    const max_patterns = 32;
    var pat_min_pitch: [max_patterns]i32 = [_]i32{127} ** max_patterns;
    var pat_max_pitch: [max_patterns]i32 = [_]i32{0} ** max_patterns;
    var pat_has_notes: [max_patterns]bool = [_]bool{false} ** max_patterns;
    for (app.notes.items) |n| {
        if (n.pattern < 0 or n.pattern >= max_patterns) continue;
        const pi: usize = @intCast(n.pattern);
        pat_has_notes[pi] = true;
        pat_min_pitch[pi] = @min(pat_min_pitch[pi], n.pitch);
        pat_max_pitch[pi] = @max(pat_max_pitch[pi], n.pitch);
    }

    // 轨道行（裁剪：滚动时不画出边界）
    {
        const saved = ui.renderer.pushClip(main_x, tracks_y, main_w, tracks_h);
        defer ui.renderer.popClip(saved);

        var i: usize = 0;
        var ty = tracks_y - app.playlist.scroll;
        while (i < app.track_items.len) : (i += 1) {
            if (ty + track_h > tracks_y and ty < tracks_y + tracks_h) {
                const selected = app.sel.track == @as(i32, @intCast(i));
                // 轨道名（左列；底色加深与内容区区分）
                if (ui.listItem(3000 + i, app.track_items[i], main_x, ty, header_w, track_h, selected, i % 2 == 1, ui.theme.bg)) {
                    app.sel.track = @intCast(i);
                }
                // 轨道内容区（背景 + 网格）
                const lane_bg = if (i % 2 == 1) ui.theme.item_alt else ui.theme.panel;
                ui.renderer.fillRect(lane_x, ty, view_w, track_h, lane_bg);
                // 网格线（与钢琴卷帘共用 `util.drawTimelineGrid`：步线/拍线/小节线三层，
                // U=96 对齐；`step_w` = 一小节宽/每小节步数）
                util.drawTimelineGrid(
                    &ui.renderer,
                    &ui.theme,
                    lane_x,
                    view_w,
                    ty,
                    track_h,
                    lane_x,
                    app.playlist.scroll_x,
                    zoom,
                    @as(f32, @floatFromInt(bar_w)) / @as(f32, @floatFromInt(spb)), // 步宽（浮点：80/96≈0.833）
                    spb,
                    model.stepsPerBeat(app.time_den),
                );
                // 行分隔线：必须在片段**之前**绘制——
                // 否则它（画在 ty+track_h-1）会盖住片段底边的亮色描边（只有上/左/右亮、下不亮）。
                ui.renderer.hline(main_x, ty + track_h - 1, main_w, ui.theme.panel_border);
                // 已放置的样式片段（裁剪到轨道内容区——左滚时不会盖住轨道名列）
                {
                    const saved_clips = ui.renderer.pushClip(lane_x, ty, view_w, track_h);
                    defer ui.renderer.popClip(saved_clips);
                    for (app.clips.items) |clip| {
                        if (clip.track != @as(i32, @intCast(i))) continue;
                        const rect = clipXW(clip, lane_x, step_px, app.playlist.scroll_x, zoom);
                        const clip_x = rect.x;
                        const clip_w = rect.w;
                        if (clip_x + clip_w < lane_x or clip_x > lane_x + view_w) continue;
                        const base = patternColor(clip.pattern);
                        // 底色 = 样式色（32% 不透明）+ 描边 = 样式色全亮
                        const fill = (@as(u32, 80) << 24) | (base & 0x00FFFFFF);
                        ui.renderer.fillRect(clip_x, ty, clip_w, track_h, fill);

                        // ── 片段内音符预览（minimap 风格）──
                        // 只画“片段可见窗口”（offset..offset+len）内的音符；
                        // 纵向用该样式的音域映射（与三处 minimap 同一规则）
                        const label_h: i32 = if (clip_w >= 70 and track_h >= 30) 13 else 0;
                        // 预览区**与片段边缘严格对齐**（不内缩）：
                        // 否则与网格/边缘错位——拖边缘时音符看起来“漂移几像素”（实测 bug）
                        const inner_x = clip_x;
                        const inner_w = @max(1, clip_w);
                        const inner_y = ty + 2 + label_h;
                        const inner_h = @max(2, track_h - 4 - label_h);
                        {
                            const pi: usize = @intCast(@min(clip.pattern, max_patterns - 1));
                            if (clip.pattern >= 0 and clip.pattern < max_patterns and pat_has_notes[pi]) {
                                const range = model.rangeMap(pat_min_pitch[pi], pat_max_pitch[pi], 12);
                                const win_lo = clip.offset;
                                const win_steps = clip.len;
                                var drawn: usize = 0;
                                for (app.notes.items) |n| {
                                    if (n.pattern != clip.pattern) continue;
                                    const rel = n.step - win_lo;
                                    if (rel >= win_steps or rel + n.len <= 0) continue; // 不在可见窗口
                                    const s = @max(0, rel);
                                    const e = @min(win_steps, rel + n.len);
                                    const nx = inner_x + @divTrunc(s * inner_w, win_steps);
                                    const nw = @max(1, @divTrunc((e - s) * inner_w, win_steps));
                                    const y_norm = range.yOf(n.pitch);
                                    const ny = inner_y + inner_h - 2 - @as(i32, @intFromFloat(y_norm * @as(f32, @floatFromInt(inner_h - 2))));
                                    ui.renderer.fillRect(nx, ny, nw, 2, base);
                                    drawn += 1;
                                    if (drawn >= 64) break; // 预览足够，防止极端情况卡顿
                                }
                            }
                        }

                        // 描边只在“不会被填充满”时才画（与钢琴卷帘音符同一规则）：
                        // 极窄的片段描边会把填充完全包成灰色。
                        if (clip_w > 2) ui.renderer.strokeRect(clip_x, ty, clip_w, track_h, base);
                        if (label_h > 0) {
                            var buf: [24]u8 = undefined;
                            const label_text = std.fmt.bufPrint(&buf, "样式 {d}", .{clip.pattern + 1}) catch "";
                            ui.labelClipped(label_text, clip_x + 6, ty + 4, clip_w - 12, ui.theme.text);
                        }
                    }
                }
            }
            ty += track_h;
            if (ty > tracks_y + tracks_h) break;
        }
    }

    // 轨道名列与内容区的分界线
    ui.renderer.vline(lane_x, tracks_y, tracks_h, ui.theme.panel_border);

    // ── 播放游标（标尺区单击/拖动设置位置；播放时按音频时钟推进）──
    // **必须在轨道行之后绘制**：否则竖线会被轨道行背景盖住（实测 bug）。
    // 位置 = 全局步（song_step）；屏幕 x = lane_x + (步/16) × 小节宽 × zoom − 滚动量
    {
        // 裁剪到「标尺行 + 轨道区」：左滚时游标 x 会变负，不裁剪会画到轨道名列/左侧面板上
        const saved_cursor = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h + tracks_h);
        defer ui.renderer.popClip(saved_cursor);

        const bar_frac: f32 = @as(f32, @floatFromInt(app.playback.song_step)) / @as(f32, @floatFromInt(spb));
        const cx = lane_x + @as(i32, @intFromFloat(bar_frac * bar_ws - scroll_s));
        util.drawCursor(ui, cx, ruler_y, ruler_h, tracks_y + tracks_h, app.playing);

        // 交互（仅标尺行）：按下 → 直接设置位置并进入拖动；拖动中跟随鼠标
        const in_ruler = ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
        if (in_ruler and ui.mouse_pressed) {
            ui.active_id = 7000;
        }
        if (ui.active_id == 7000) {
            if (!ui.mouse_down) {
                ui.active_id = 0;
            } else {
                // 鼠标 → 全局步（吸附到步；范围 ≥ 0）
                const content_px: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) + @as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom;
                const step: i32 = @max(0, @as(i32, @intFromFloat(content_px / step_px)));
                // 跳转（播放中会重置传输基准 + 作废旧调度事件）
                app.jumpPlaybackCursor(step);
            }
        }
    }

    // ── 鼠标交互（轨道内容区）──
    // 左键空位：放置样式；左键片段：拖动移动；片段右缘：拉伸长度；右键片段：删除
    const in_lane = ui.hitRect(lane_x, tracks_y, view_w, tracks_h);
    const track_i = @divFloor(ui.mouse_y - tracks_y + app.playlist.scroll, track_h);
    // 鼠标 → 内容坐标（除以 zoom）→ **全局步**（U=96）
    const mouse_cx: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) + @as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom;
    const step_i: i32 = @max(0, @as(i32, @intFromFloat(mouse_cx / step_px)));
    const track_count: i32 = @intCast(app.track_items.len);
    const valid_track = track_i >= 0 and track_i < track_count;

    // 命中：鼠标下的片段 + 命中模式（中部 / 左缘 / 右缘，边缘区 8px）
    var clip_hit: ?struct { index: usize, mode: model.ClipHitMode } = null;
    if (in_lane and valid_track) {
        for (app.clips.items, 0..) |c, ci| {
            if (c.track != track_i) continue;
            if (step_i >= c.start and step_i < c.start + c.len) {
                const rect = clipXW(c, lane_x, step_px, app.playlist.scroll_x, zoom);
                const near_left = ui.mouse_x <= rect.x + 8;
                const near_right = ui.mouse_x >= rect.x + rect.w - 8;
                const mode: model.ClipHitMode = if (near_left and near_right)
                    // 窄片段两缘都近：按鼠标在片段内的相对位置就近选
                    (if (ui.mouse_x - rect.x <= rect.x + rect.w - ui.mouse_x) .left else .right)
                else if (near_left)
                    .left
                else if (near_right)
                    .right
                else
                    .body;
                clip_hit = .{ .index = ci, .mode = mode };
                break;
            }
        }
    }

    // 双击片段：打开钢琴卷帘（编辑该样式）
    if (ui.mouse_double) {
        if (clip_hit) |hit| {
            const c = app.clips.items[hit.index];
            app.openPiano(c.pattern);
            return;
        }
    }

    // 光标：拉伸中 / 悬停边缘 → ↔
    if (app.playlist.resize_clip != null) {
        ui.cursor = .resize_h;
    } else if (app.playlist.drag_clip == null) {
        if (clip_hit) |hit| {
            if (hit.mode != .body) ui.cursor = .resize_h;
        }
    }

    // 右键：按下处删除；按住拖动 = 擦除（划过即删；起点需在播放列表内）
    if (ui.mouse_right_pressed and ui.hitRect(main_x, tracks_y, main_w, tracks_h)) {
        app.playlist.erase_drag = true;
    }
    if (app.playlist.erase_drag) {
        if (!ui.mouse_right_down) {
            app.playlist.erase_drag = false;
        } else if (clip_hit) |hit| {
            _ = app.clips.orderedRemove(hit.index);
            app.dirty = true;
            app.playlist.drag_clip = null;
            app.playlist.resize_clip = null;
        }
    }

    // 左键按下：选中 / 开始拖动或拉伸 / 空位放置
    if (ui.mouse_pressed and in_lane and valid_track) {
        app.sel.track = track_i;
        if (clip_hit) |hit| {
            const c = app.clips.items[hit.index];
            app.sel.pattern = c.pattern;
            switch (hit.mode) {
                .left => {
                    app.playlist.resize_clip = hit.index;
                    app.playlist.resize_left = true;
                },
                .right => {
                    app.playlist.resize_clip = hit.index;
                    app.playlist.resize_left = false;
                },
                .body => {
                    app.playlist.drag_clip = hit.index;
                    app.playlist.drag_grab = step_i - c.start;
                },
            }
        } else {
            // 默认片段长度 = 1 小节（步单位随拍号变化）
            const new_len: i32 = spb;
            if (!model.clipOverlaps(app.clips.items, app.clips.items.len, track_i, step_i, new_len)) {
                app.addClip(.{ .track = track_i, .start = step_i, .len = new_len, .pattern = app.sel.pattern });
            }
        }
    }

    // 拖动 / 拉伸更新（鼠标可移出区域；位置 clamp 到有效范围）
    if (ui.mouse_down) {
        if (app.playlist.drag_clip) |ci| {
            if (ci < app.clips.items.len) {
                const c = &app.clips.items[ci];
                const new_start = @max(0, step_i - app.playlist.drag_grab);
                const new_track = std.math.clamp(track_i, 0, track_count - 1);
                if ((new_start != c.start or new_track != c.track) and !model.clipOverlaps(app.clips.items, ci, new_track, new_start, c.len)) {
                    c.track = new_track;
                    c.start = new_start;
                    app.dirty = true;
                }
            }
        }
        if (app.playlist.resize_clip) |ci| {
            if (ci < app.clips.items.len) {
                const c = &app.clips.items[ci];
                if (app.playlist.resize_left) {
                    // 左缘：折叠/展开（不能超过自身第 1 步）
                    if (model.clipTrimLeft(c.*, step_i)) |nc| {
                        if (!model.clipOverlaps(app.clips.items, ci, nc.track, nc.start, nc.len)) {
                            c.* = nc;
                            app.dirty = true;
                        }
                    }
                } else {
                    // 右缘：加长/缩短（上限：同轨下一个片段之前）；最小 1 步
                    var max_len: i32 = 1 << 20;
                    for (app.clips.items, 0..) |o, oi| {
                        if (oi == ci or o.track != c.track or o.start <= c.start) continue;
                        max_len = @min(max_len, o.start - c.start);
                    }
                    const new_len = std.math.clamp(step_i - c.start + 1, 1, @max(1, max_len));
                    if (new_len != c.len) {
                        c.len = new_len;
                        app.dirty = true;
                    }
                }
            }
        }
    } else {
        app.playlist.drag_clip = null;
        app.playlist.resize_clip = null;
    }

    // 纵向滚动：滚轮（主区）+ 右侧纵向滚动条
    const content_h: i32 = @intCast(app.track_items.len * @as(usize, @intCast(track_h)));
    if (ui.hitRect(main_x, tracks_y, main_w, tracks_h)) {
        if (ui.wheel_ctrl) {
            // Ctrl+滚轮：横向缩放（锚定鼠标下的内容）+ 内容区拉回
            // 注：拉回**无条件执行**（不只在 zoom 变化时）——
            // 否则“已缩到下限 + 视口停在右侧空白”时下滚会无事发生。
            const mouse_off = ui.mouse_x - lane_x;
            const old_zoom = app.playlist.zoom;
            // 下限取 min(动态下限，当前)：内容缩短（动态下限被动抬高）时
            // 不得把视口突然放大——只拦“继续缩小”。
            const new_zoom = std.math.clamp(old_zoom * std.math.pow(f32, util.wheel_zoom_factor, @as(f32, @floatFromInt(ui.wheel))), @min(dyn_zoom_min, old_zoom), 8.0);
            if (new_zoom != old_zoom) {
                app.playlist.zoom = new_zoom;
                app.playlist.scroll_x = Ui.zoomAnchoredScrollX(app.playlist.scroll_x, view_w, mouse_off, old_zoom, new_zoom, app.playlist.content_w, content_span);
            }
            // 缩小/已到下限：把视口右缘拉回内容跨度内（全装得下 → 贴左）
            const vcw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / app.playlist.zoom)));
            app.playlist.scroll_x = Ui.clampScrollToSpan(app.playlist.scroll_x, vcw, content_span);
        } else {
            app.playlist.scroll = std.math.clamp(app.playlist.scroll - util.scrollDelta(ui), 0, @max(0, content_h - tracks_h));
        }
    }
    _ = ui.scrollbarV(9, sb_x, tracks_y, ruler_h, tracks_h, &app.playlist.scroll, content_h, tracks_h);
    ui.renderer.vline(sb_x, tracks_y, tracks_h, ui.theme.panel_border); // 纵向滚动条左边界
}
