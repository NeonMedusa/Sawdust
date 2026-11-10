//! 播放列表视图：时间轴 + 轨道行 + 片段编辑。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const model = @import("model.zig");
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");

/// 片段在轨道内容区的绘制矩形（x / 宽；屏幕像素，含 zoom 换算）。
/// **边缘与格子对齐**（不缩进）；起点/终点各自取整 → 并排片段严格相接、无 1px 缝。
/// 层序比较（用户拍板规则）：左端点升序；相同 → 数组序（越后越上层）。
fn clipLayerLess(clips: []const model.Clip, a: usize, b: usize) bool {
    if (clips[a].start != clips[b].start) return clips[a].start < clips[b].start;
    return a < b;
}

/// `step_px`：一步的**内容像素宽**（浮点；U=96 下每步很小）。
pub fn clipXW(c: model.Clip, lane_x: i32, step_px: f32, scroll_x: i32, zoom: f32) struct { x: i32, w: i32 } {
    const x0: f32 = (@as(f32, @floatFromInt(c.start)) * step_px - @as(f32, @floatFromInt(scroll_x))) * zoom;
    const x1: f32 = (@as(f32, @floatFromInt(c.start + c.len)) * step_px - @as(f32, @floatFromInt(scroll_x))) * zoom;
    const px0 = lane_x + @as(i32, @intFromFloat(@round(x0)));
    const px1 = lane_x + @as(i32, @intFromFloat(@round(x1)));
    return .{ .x = px0, .w = @max(1, px1 - px0) };
}

/// **音频 Part 的波形**（线性化：与音符 Part 共用同一套外观，只是内部画波形）。
/// 规则与旧片段版本一致：原生尺度（不压缩）——每像素 = (1/step_px) 步 × 每步帧数；超出音频即空。
fn drawAudioPartWave(ui: *Ui, app: *App, pt: *const model.Part, x: i32, w: i32, ty: i32, track_h: i32, step_px: f32, zoom: f32) void {
    const sti = pt.audio.style;
    if (sti < 0 or @as(usize, @intCast(sti)) >= app.audio_styles.items.len) return;
    const st = &app.audio_styles.items[@intCast(sti)];
    const asset = app.audioStyleAsset(@intCast(sti)) orelse {
        // 异步导入中（与旧片段一致）：斜纹占位 + 百分比；真·缺失才写“音频缺失”
        if (app.styleImportProgress(@intCast(sti))) |p| {
            var sx: i32 = 0;
            while (sx < w) : (sx += 6) {
                ui.renderer.vline(x + sx, ty + 2, @max(1, track_h - 4), ui.theme.panel_border);
            }
            const pct: i32 = @intFromFloat(@round(p * 100.0));
            var pbuf: [16]u8 = undefined;
            const ptxt = std.fmt.bufPrint(&pbuf, "载入 {d}%", .{pct}) catch "载入";
            if (w >= 30) {
                ui.labelClipped(ptxt, x + 6, ty + 4, w - 12, ui.theme.text_dim);
            } else if (w >= 22) {
                ui.labelClipped(ptxt, x + 3, ty + 3, w - 6, ui.theme.text_dim);
            }
        } else {
            ui.labelClipped("（音频缺失）", x + 4, ty + 3, w - 8, ui.theme.danger);
        }
        return;
    };
    const total: i32 = @intCast(asset.data.frame_count);
    if (total <= 0 or asset.peaks.len == 0) return;
    const ts: i64 = pt.audio.trim_start;
    const fps_f: f64 = @floatFromInt(app.framesPerStep());
    const mid = ty + @divTrunc(track_h, 2);
    const half: f32 = @as(f32, @floatFromInt(track_h)) * 0.4;
    const peak_frames: i32 = @intCast(@max(@as(u32, 1), asset.peak_frames));
    const spd: f64 = std.math.clamp(@as(f64, st.speed), 0.25, 4.0);
    const pxps: f64 = @as(f64, step_px) * @as(f64, zoom);
    var px: i32 = 0;
    while (px < w) : (px += 1) {
        const fr_i: i64 = @as(i64, @intFromFloat((@as(f64, @floatFromInt(ts)) + @as(f64, @floatFromInt(px)) / @max(1e-6, pxps) * fps_f * spd) * @as(f64, asset.data.ratio)));
        if (fr_i >= total) break;
        const fr: i32 = @intCast(fr_i);
        const bi: usize = @min(asset.peaks.len - 1, @as(usize, @intCast(@divTrunc(fr, peak_frames))));
        const pk = asset.peaks[bi];
        const y0: i32 = mid - @as(i32, @intFromFloat(pk.max * half));
        const y1: i32 = mid - @as(i32, @intFromFloat(pk.min * half));
        ui.renderer.vline(x + px, y0, @max(1, y1 - y0), ui.theme.waveform);
    }
    if (w >= 30) ui.labelClipped(st.name, x + 6, ty + 4, w - 12, ui.theme.text);
}

/// 样式配色（minimap / 片段色块）：按序号在色相上分布，保证相邻样式颜色可区分。
/// 静音视觉（浅灰）：轨道名与片段整体变灰
/// 片段自身静音（Ctrl+M）的灰
pub const muted_gray: r_mod.Color = r_mod.rgb(150, 150, 154);
/// **轨道静音**：比片段静音更暗（让用户一眼分辨"是自己静音了"还是"轨道静音了"）
pub const muted_gray_track: r_mod.Color = r_mod.rgb(92, 92, 96);

/// **Part 重叠层级**（与片段一致）：按左端点升序；相同起点 → 数组序（后加的在上）
fn partLayerLess(parts: []const model.Part, a: usize, b: usize) bool {
    if (parts[a].start != parts[b].start) return parts[a].start < parts[b].start;
    return a < b;
}
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

/// 轨道右键菜单（重命名 / 在下方插入 / 删除）——主循环调用（同样式菜单模式）。
pub fn drawTrackCtxMenu(ui: *Ui, app: *App) void {
    const idx = app.panels.ctx_track orelse return;
    if (idx >= @as(usize, @intCast(app.playlist.view_rows))) {
        app.panels.ctx_track = null; // 目标已不存在（撤销等）→ 关闭
        return;
    }
    const items = [_][]const u8{ "重命名", "上移", "下移", "清空轨道", "删除轨道", "更换乐器…" };
    const menu_w: i32 = 150;
    const menu_h: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const mx = app.panels.ctx_trk_x;
    const my = app.panels.ctx_trk_y;
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h); // 遮挡插件子窗口

    var clicked: ?usize = null;
    var inside = false;
    for (items, 0..) |item, ii| {
        const iy = my + 2 + @as(i32, @intCast(ii)) * util.menu_item_h;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (hovered) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, ui.theme.text);
        if (hovered and ui.mouse_pressed) clicked = ii;
    }
    if (clicked) |ci| {
        switch (ci) {
            0 => {
                // **重命名 = 重命名乐器**（乐器就是轨道、轨道就是乐器）：直接复用机架的重命名逻辑，
                // 预填当前乐器名；输入空字符串 = 不修改（`.instrument` 分支已守卫 `val.len > 0`）。
                const ii = app.trackInstrument(idx);
                if (ii >= 0) {
                    app.beginRenameInstrument(@intCast(ii), mx + 6, my + 4);
                } else {
                    app.beginRenameTrack(idx, mx + 6, my + 4);
                }
            },
            1 => {
                // 上移：与相邻行整体交换（默认名随位置，自定义名随行）
                if (idx > 0) {
                    app.swapTrackRows(idx, idx - 1);
                    app.commitHistory("上移轨道");
                } else {
                    app.setToast("已在最上一条");
                }
            },
            2 => {
                if (idx + 1 < app.tracks.items.len) {
                    app.swapTrackRows(idx, idx + 1);
                    app.commitHistory("下移轨道");
                } else {
                    app.setToast("已在最下一条");
                }
            },
            3 => {
                if (app.trackUsage(idx) == 0) {
                    app.setToast("该轨道已是空的");
                } else {
                    // 非空：弹确认框（清空片段 + 撤销兜底；行与名字保留）
                    app.modal = .track_clear;
                    app.struct_del_req = .{ .track = idx };
                }
            },
            4 => {
                if (app.trackUsage(idx) == 0) {
                    // 空轨：直接删（下方整体上移，**轨道实体与乐器一并移除**）
                    app.removeTrackRow(idx);
                    app.commitHistory("删除轨道");
                } else {
                    app.modal = .track_delete;
                    app.struct_del_req = .{ .track_row = idx };
                }
            },
            5 => {
                // **更换乐器…**：打开乐器预设选择窗（选完替换该轨乐器，音符保留）
                const ii = app.trackInstrument(idx);
                if (ii >= 0) {
                    app.openPresetBrowser(.{ .change_instrument = ii });
                } else {
                    app.beginAddTrackWithPicker();
                }
            },
            6 => {
                // （旧“+ 添加 Part”已删：Part 由网格左键单击放置）
            },
            else => {},
        }
        app.panels.ctx_track = null;
    } else if (ui.mouse_pressed and !inside) {
        app.panels.ctx_track = null;
    }
}

/// 播放列表落点（拖入文件用）：屏幕坐标 → (轨道行, **吸附后**的步)。
/// 不在轨道内容区 → null（标题/标尺/滚动条/轨道名列都算"不响应"）。
pub fn hitAt(app: *const App, px: i32, py: i32) ?struct { track: i32, step: i32 } {
    const g = app.playlist.geom;
    if (g.track_h <= 0) return null;
    if (px < g.lane_x or px >= g.lane_x + g.view_w) return null;
    if (py < g.tracks_y or py >= g.tracks_y + g.tracks_h) return null;
    const track = @divFloor(py - g.tracks_y + app.playlist.scroll, g.track_h);
    if (track < 0) return null;
    const step_px: f32 = @floatFromInt(util.piano_step_w);
    const mouse_cx: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) + @as(f32, @floatFromInt(px - g.lane_x)) / app.playlist.zoom;
    const step_i: i32 = @max(0, @as(i32, @intFromFloat(mouse_cx / step_px)));
    const snap_steps: i32 = model.snapSteps(app.playlist.snap);
    return .{ .track = track, .step = @max(0, model.snapRound(step_i, snap_steps)) };
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

    // 吸附网格选择器（标题栏内，**紧挨标题文字**；与钢琴卷帘**独立**）
    const snap_menu_was_open = app.playlist.snap_menu_open;
    const title_w: i32 = @intFromFloat(ui.font.measure(title));
    const snap_btn_x: i32 = x + 6 + title_w + 12;
    var snap_clicked = false;
    if (snap_btn_x + 40 < x + w - 24) {
        snap_clicked = util.snapSelectorButton(ui, snap_btn_x, y, util.title_h, &app.playlist.snap, &app.playlist.snap_menu_open);
    }

    // 视图切换按钮（标题栏最右）：⇄ 打开钢琴卷帘（当前样式）
    if (util.viewSwitchButton(ui, x + w - 6, y, util.title_h)) {
        app.openPiano(app.sel.pattern);
    }

    // 菜单展开时的点击只归菜单：屏蔽本帧其它交互（标尺/轨道区）——
    // 必须在**任何交互处理之前**算（实测 bug：点选单条目穿透命中小节标尺，
    // 游标跳到鼠标位置）。
    // **本视图是否被浮动窗口/菜单盖住**（`ui.input_blocked` 由层系统在 `beginLayer` 时算好）。
    // 注：本视图很多命中用的是裸 `util.inRect`（不走 `ui.hitRect`），因此**必须显式参与判定**——
    // 否则浮动窗口上的点击会穿透到 Part / 轨道头 / `+ 添加轨道`（实测 bug）。
    const ui_blocked = ui.input_blocked;
    const menu_click = (snap_menu_was_open or snap_clicked or ui_blocked) and ui.mouse_pressed;

    const header_w: i32 = util.piano_header_w; // 轨道名列宽（**与钢琴窗琴键列同宽**，用户约定）
    const ruler_h: i32 = 20; // 标尺行高 = 滚动条厚度（横条高 = 纵条宽）
    const list_y = y + util.title_h;
    const list_h_full = h - util.title_h;
    // ── **自动化面板**（`docs/automation.md` §九）：与钢琴窗一致的**上下真分隔** ──
    // 先在总高度里扣出面板高度，再让 `list_h` 用剩余部分——
    // 这样标尺/轨道/横纵滚动条（含其命中区域）**全部**自动不进入面板带，
    // 不再是“盖在上面”（那样会点击穿透、滚动条滑进面板里）。
    // 上限与钢琴窗**同一个基准**：都按「轨道/音符内容区（扣掉两行标尺）」的一半来算。
    // 面板自己含一行目标切换按钮（hdr_h），所以要把这 20px 加回上限，
    // 否则用户会看到“播放列表的编辑区能拉得更高”（多出来的正好是按钮行高，实测）。
    // （按钮行高 20 已含在面板内部；上限不再额外加它）
    // **与钢琴窗走同一份布局数学**（`view_lane.layoutPanel`），高度也共用 `app.auto_panel_h`
    const lay = view_lane.layoutPanel(list_y + ruler_h * 2, list_y + list_h_full, 4, app.auto_panel_h, 60);
    const auto_h: i32 = lay.panel_h;
    // 分隔条：**与钢琴窗完全同款**——只让出自身厚度，只画这一条（不加“带子”底色）。
    // 悬停/按下都严格限制在本体内（`ui.splitterH` 已改成不外扩）→ 不会误放片段。
    // 粗细取 6px：4px 的横线视觉上明显比 4px 的竖线细，6px 才看起来等宽。
    const splitter_h: i32 = 4;
    const list_h = @max(1, list_h_full - auto_h - splitter_h);

    const main_x = x + 1;
    const main_w = w - 2 - ruler_h; // 主区宽（右侧留出滚动条列）
    const sb_x = x + w - 1 - ruler_h; // 滚动条列：□ 缺口 + 纵向滚动条
    const hsb_y = list_y; // 横向滚动条行
    const ruler_y = list_y + ruler_h; // 标尺行（右端为 □ 缺口：自然留空）
    const tracks_y = list_y + ruler_h * 2;
    const tracks_h = list_h - ruler_h * 2;

    // ── **分隔条先处理**（在一切内容之前）：认领这次按下并吃掉它，
    //    否则面板里的“点空白放片段 / 拖柱条改力度”会先吃到这一下（实测）。
    {
        const split_y0 = view_lane.layoutPanel(list_y + ruler_h * 2, list_y + list_h_full, 4, app.auto_panel_h, 60).split_y;
        _ = ui.splitterH(Ui.idOf("playlist_auto_splitter", 0), &app.auto_panel_h, split_y0, main_x, @max(1, x + w - main_x), splitter_h, 60, view_lane.layoutPanel(list_y + ruler_h * 2, list_y + list_h_full, 4, app.auto_panel_h, 60).max_h);
        app.auto_panel_h = view_lane.layoutPanel(list_y + ruler_h * 2, list_y + list_h_full, 4, app.auto_panel_h, 60).panel_h;
    }
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
    var max_end: i32 = 0; // 最右内容（Part / 旧片段）的结束步
    for (app.clips.items) |c| {
        max_end = @max(max_end, c.start + c.len);
    }
    for (app.parts.items) |pt| {
        max_end = @max(max_end, pt.start + pt.len);
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
        for (app.parts.items) |pt0| {
            const row0 = app.trackRowByUid(pt0.track_uid) orelse continue;
            min_track = @min(min_track, @as(i32, @intCast(row0)));
            max_track = @max(max_track, @as(i32, @intCast(row0)));
        }
        const track_range = model.rangeMap(min_track, max_track, 8); // 保底 8 轨高
        // minimap 内容 = **Part**（音符 Part / 音频 Part 同一套；音频用波形色区分）
        for (app.parts.items) |pt0| {
            if (nmini >= mini_buf.len) break;
            const row0 = app.trackRowByUid(pt0.track_uid) orelse continue;
            mini_buf[nmini] = .{
                .pos = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt0.start)) * step_px)),
                .len = @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt0.len)) * step_px)),
                .kind = .note,
                .y = track_range.yOf(@as(i32, @intCast(row0))),
                .color = if (pt0.kind == .audio) ui.theme.waveform else patternColor(0),
            };
            nmini += 1;
        }
        // 旧片段（历史兼容；新建工程不会有）
        for (app.clips.items) |c| {
            if (nmini >= mini_buf.len) break;
            mini_buf[nmini] = .{
                .pos = @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.start)) * step_px)),
                .len = @as(i32, @intFromFloat(@as(f32, @floatFromInt(c.len)) * step_px)),
                .kind = .note,
                .y = track_range.yOf(c.track),
                .color = patternColor(c.pattern),
            };
            nmini += 1;
        }
        // 防误触：滑块外的单击 / 滚动条上的滚轮 = 移动"一个当前网格"（Ctrl+单击才是直接定位）
        ui.scrollbar_nudge = model.snapSteps(app.playlist.snap) * util.piano_step_w;
        ui.scrollbar_target = &app.playlist.scroll_x_target; // 步进走补间（拖动仍直接写 scroll_x）
        _ = ui.scrollbarTimelineEx(8, x + 1, hsb_y, w - 2, ruler_h, &app.playlist.scroll_x, min_content, &app.playlist.zoom, view_w, dyn_zoom_min, 8.0, bars_right < util.overhang_map_limit, mini_buf[0..nmini]);
    }
    ui.renderer.hline(x + 1, ruler_y, w - 2, ui.theme.panel_border);

    // 横向缩放：内容坐标 → 屏幕坐标（本帧最终值；缩放块之后捕获）
    const zoom: f32 = app.playlist.zoom;
    const bar_ws: f32 = @as(f32, @floatFromInt(bar_w)) * zoom; // 屏幕上的小节宽
    const scroll_s: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) * zoom; // 屏幕上的滚动量

    // 鼠标 x → 全局步（**吸附到当前网格**；标尺/循环拖动共用——
    // 必须在任何使用点之前定义）
    const pl_snap: i32 = model.snapSteps(app.playlist.snap);
    const playlistMouseStepSnap = struct {
        fn f(mx: i32, lx: i32, scroll_x: i32, zm: f32, step_px_v: f32, snap: i32) i32 {
            const px: f32 = @as(f32, @floatFromInt(scroll_x)) + @as(f32, @floatFromInt(mx - lx)) / zm;
            const raw: i32 = @max(0, @as(i32, @intFromFloat(px / step_px_v)));
            return @max(0, model.snapRound(raw, snap));
        }
    }.f;

    // 小节标尺（随横向滚动与缩放；只画在轨道内容区上方）
    ui.renderer.fillRect(main_x, ruler_y, main_w, ruler_h, ui.theme.toolbar);
    {
        const saved = ui.renderer.pushClip(lane_x, ruler_y, view_w, ruler_h);
        defer ui.renderer.popClip(saved);
        var bar: i32 = @divFloor(app.playlist.scroll_x, bar_w) + 1;
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
        // 循环区域（标尺行部分；轨道区部分在轨道行之后叠加）。
        // 本视图时间轴**始终是全局步**，所以直接看 `loop_song`（不看当前模式）；
        // 拖动中优先显示实时预览（首次设置区域也能看到预览）
        {
            var lo: i32 = 0;
            var hi: i32 = 0;
            var show = false;
            if (app.playback.loop_drag_from) |df| {
                // **按当前网格步进**（与松手时一致）
                const cur_step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                lo = @min(df, cur_step);
                hi = @max(df, cur_step);
                show = hi > lo;
            } else if (app.playback.loop_song) |lr_in| {
                lo = lr_in[0];
                hi = lr_in[1];
                show = hi > lo;
            }
            if (show) {
                const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(lo)) * step_px * zoom - scroll_s));
                const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(hi)) * step_px * zoom - scroll_s));
                const tint = (@as(u32, 40) << 24) | (ui.theme.note_selected & 0x00FFFFFF);
                ui.renderer.fillRect(x0, ruler_y, x1 - x0, ruler_h, tint);
                ui.renderer.vline(x0, ruler_y, ruler_h, ui.theme.note_selected);
                ui.renderer.vline(x1, ruler_y, ruler_h, ui.theme.note_selected);
            }
        }
    }

    // ── **`+ 轨道`**：标尺行左侧行头列那片空白（与钢琴窗同位置的“鼓组/琴键”互斥按钮对称）──
    {
        const bw: i32 = util.piano_header_w - 4;
        const bh: i32 = ruler_h - 4;
        const bx = main_x + 2;
        const by = ruler_y + 2;
        const hovered = !ui_blocked and util.inRect(ui.mouse_x, ui.mouse_y, bx, by, bw, bh);
        ui.renderer.fillRect(bx, by, bw, bh, if (hovered) ui.theme.item_hover else ui.theme.toolbar);
        ui.renderer.strokeRect(bx, by, bw, bh, if (hovered) ui.theme.accent else ui.theme.panel_border);
        ui.labelClipped("+ 添加轨道", bx + 4, by + @divTrunc(bh - 10, 2), bw - 6, ui.theme.text);
        if (hovered and ui.mouse_pressed) app.beginAddTrackWithPicker(); // 打开乐器预设选择窗
    }
    ui.renderer.vline(sb_x, ruler_y, ruler_h, ui.theme.panel_border); // □ 缺口左边界
    ui.renderer.vline(lane_x, ruler_y, ruler_h, ui.theme.panel_border); // 轨道名列分界（标尺行）
    ui.renderer.hline(x + 1, tracks_y, w - 2, ui.theme.panel_border);

    // 地图行数（**推导跨度**：max(最短行程 128, 内容下缘 + 1 + 3 行留白)；与横向“保底 4 小节 + 3 留白”对称）。
    // 滚动条/滚轮/缩放以它为准；**悬空**（滚动越出地图）只影响滚动位置，不改地图。
    const map_rows: i32 = app.trackCount();

    // 缩放下限 = 视图恰好容纳整个行轴（与横向 `dyn_zoom_min` 同构）：缩到底时行轴恰好
    // 填满视口——不露白、无假行程；只当“刹车”不反向顶大。
    const zoom_min_h: i32 = @min(util.zoomOutFloor(util.track_h_min, util.track_h_max, tracks_h, @intCast(@max(1, map_rows))), app.playlist.track_h);

    // □ 缺口：按住上下拖 = 轨道行高缩放（方块本身固定不动；视口中心内容保持不动）
    // 悬空状态下缩放：只按新地图重钳下界、**悬空量保留**（不把视口拽回地图）
    {
        const old_h = app.playlist.track_h;
        if (ui.zoomSquare(12, sb_x, ruler_y, ruler_h, &app.playlist.track_h, zoom_min_h, util.track_h_max, 2) and app.playlist.track_h != old_h) {
            const old_content: i32 = map_rows * old_h;
            const content_h_new: i32 = map_rows * app.playlist.track_h;
            const over: i32 = @max(0, app.playlist.scroll - @max(0, old_content - tracks_h));
            const anchored = Ui.zoomAnchoredScroll(app.playlist.scroll, tracks_h, old_h, app.playlist.track_h, content_h_new);
            app.playlist.scroll = anchored + over;
        }
    }

    // 行高必须在 □ 缩放块**之后**捕获：否则本帧会用「旧行高 + 新滚动偏移」绘制，
    // 每步缩放都会跳一帧（实测明显上下跳变），下一帧才恢复。
    const track_h: i32 = app.playlist.track_h;

    // 几何写回（拖入文件的落点换算用；与绘制同一套坐标）
    app.playlist.geom = .{ .lane_x = lane_x, .tracks_y = tracks_y, .view_w = view_w, .tracks_h = tracks_h, .track_h = track_h };
    // **P1b：行数 = 真实轨道数**。以前这里会“按视口铺满”（行轴无限延伸的旧模型），
    // 于是 0 轨道的工程也会画出 Track 1..N（无边无际）。现在只画真实存在的轨道。
    const rows_draw: i32 = map_rows;
    app.playlist.view_rows = @max(1, rows_draw);
    // 滚动钳到真实内容（否则滚轮会滚到空白）
    {
        const content_h = rows_draw * track_h;
        const max_s = @max(0, content_h - tracks_h);
        app.playlist.scroll = std.math.clamp(app.playlist.scroll, 0, max_s);
    }

    // 样式音域统计（每帧一次）：片段预览的纵向映射用（避免片段循环里重复扫全量音符）。
    // **按实际样式数**复用 App 缓冲（原为 `[max_patterns]` 栈数组——上限放到十亿级后
    // 不能预分配；成本完全按真实用量）。
    const pat_stat = app.ensurePatStats(app.pattern_items.items.len);
    for (pat_stat) |*s| s.* = .{};
    for (app.notes.items) |n| {
        if (n.pattern < 0) continue;
        const pi: usize = @intCast(n.pattern);
        if (pi >= pat_stat.len) continue;
        pat_stat[pi].has_notes = true;
        pat_stat[pi].min_pitch = @min(pat_stat[pi].min_pitch, n.pitch);
        pat_stat[pi].max_pitch = @max(pat_stat[pi].max_pitch, n.pitch);
    }

    // 轨道行（裁剪：滚动时不画出边界）
    {
        const saved = ui.renderer.pushClip(main_x, tracks_y, main_w, tracks_h);
        defer ui.renderer.popClip(saved);

        // 跳过不可能可见的行（行轴无上限，滚动很远时避免从 0 逐行空转）
        var i: usize = @intCast(@max(0, @divTrunc(app.playlist.scroll, @max(1, track_h))));
        var ty = tracks_y - app.playlist.scroll + @as(i32, @intCast(i)) * track_h;
        // **手势目标行**（Part 手势只在这一次执行）：鼠标所在行；鼠标在轨道区外但正在拖动 → 用被拖对象所在行
        const g_row: usize = blk_g: {
            if (ui.mouse_y >= tracks_y and ui.mouse_y < tracks_y + tracks_h) {
                const r = @divTrunc(ui.mouse_y - tracks_y + app.playlist.scroll, @max(1, track_h));
                if (r >= 0 and r < rows_draw) break :blk_g @intCast(r);
            }
            if (app.playlist.part_drag.active and app.playlist.part_drag.idx < app.parts.items.len) {
                if (app.trackRowByUid(app.parts.items[app.playlist.part_drag.idx].track_uid)) |rr| break :blk_g rr;
            }
            break :blk_g std.math.maxInt(usize); // 无手势行
        };
        while (i < @as(usize, @intCast(rows_draw))) : (i += 1) {
            if (ty + track_h > tracks_y and ty < tracks_y + tracks_h) {
                const selected = app.sel.track == @as(i32, @intCast(i));
                // 轨道名（左列；底色加深与内容区区分）
                // 注：Ctrl 按下时不响应（让位给“按行框选”——起点在轨道名列的手势）
                const muted = app.trackMuted(i);
                // 静音方形开关（名字右侧；开=绿/关=灰）——点它切换，不点名字
                const btn_sz: i32 = @min(track_h - 2, @max(12, @as(i32, @intFromFloat(ui.font.lineHeight()))));
                const btn_x: i32 = main_x + header_w - btn_sz - 4;
                const btn_y: i32 = ty + @divTrunc(track_h - btn_sz, 2);
                const over_mute = !ui_blocked and util.inRect(ui.mouse_x, ui.mouse_y, btn_x, btn_y, btn_sz, btn_sz);
                // **插件丢失/加载失败**：乐器名标红（原机架的“标红”提示；机架已删，搬到轨道头）
                const inst_failed = blk_f: {
                    const ii_f = app.trackInstrument(i);
                    if (ii_f < 0 or @as(usize, @intCast(ii_f)) >= app.instruments.items.len) break :blk_f false;
                    break :blk_f app.instruments.items[@intCast(ii_f)].load_failed;
                };
                const name_col: ?u32 = if (muted)
                    muted_gray
                else if (inst_failed)
                    ui.theme.danger
                else
                    null;
                if (ui.listItem(3000 + i, app.trackName(i), main_x, ty, header_w, track_h, selected, i % 2 == 1, ui.theme.bg, name_col) and !ui.mods_ctrl and !over_mute) {
                    app.sel.track = @intCast(i);
                }
                // **Ctrl+单击轨道头 = 选中该轨全部 Part**（替换选）；
                // **Ctrl+Shift+单击 = 把这些 Part 加到选区**（只加不减，不切换）；
                // 两者都**不当框选起点**（否则零位移框选会把结果又抹掉）
                if (ui.mouse_pressed and !ui_blocked and ui.mods_ctrl and !over_mute and
                    util.inRect(ui.mouse_x, ui.mouse_y, main_x, ty, header_w, track_h))
                {
                    if (app.trackUidOf(i)) |tu_x| {
                        app.sel.track = @intCast(i);
                        if (!ui.mods_shift) {
                            for (app.parts.items) |*ptx| ptx.selected = false;
                        }
                        var first_sel: ?usize = null;
                        for (app.parts.items, 0..) |*ptx, pix| {
                            if (ptx.track_uid != tu_x) continue;
                            ptx.selected = true;
                            if (first_sel == null) first_sel = pix;
                        }
                        if (first_sel) |fs| app.sel.part = fs;
                    }
                    app.playlist.suppress_marquee = true;
                    ui.active_id = 0;
                }
                if (ui.toggleSquare(!muted, btn_x, btn_y, btn_sz)) { // 蓝=发声 / 灰=静音
                    app.setTrackMuted(i, !muted);
                    app.commitHistory(if (!muted) "静音轨道" else "取消静音轨道");
                }
                // **双击轨道头 → 打开该轨乐器的参数界面**（与机架里双击乐器完全同一套逻辑）
                // 注：**排除静音开关**（双击静音方块不应开面板）与右侧开关列。
                if (ui.mouse_double and !ui_blocked and !over_mute and util.inRect(ui.mouse_x, ui.mouse_y, main_x, ty, header_w - btn_sz - 8, track_h)) {
                    const ii = app.trackInstrument(i);
                    if (ii >= 0 and @as(usize, @intCast(ii)) < app.instruments.items.len) {
                        app.sel.instrument = ii;
                        if (app.instruments.items[@intCast(ii)].kind == .drumkit) {
                            app.openDrumKit(ii); // 含同步选择/置顶
                        } else {
                            app.synth_win.target = .{ .instrument = ii };
                            app.synth_win.open = true;
                            app.bringToFront(&app.synth_win.z);
                        }
                    }
                }
                // **轨道号**（左下角小字，暗色）：轨道名已经用乐器名了，序号放这里不抢位
                {
                    var nb: [12]u8 = undefined;
                    const num = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "";
                    ui.labelClipped(num, main_x + 3, ty + track_h - 16, 24, ui.theme.text_dim);
                    // **轨道类型标记**（用户定稿：轨道号右边两个小字 `乐器` / `音频`）
                    const kind_txt: []const u8 = if (inst_failed)
                        "插件丢失"
                    else if (app.isAudioTrack(@intCast(i)))
                        "音频"
                    else
                        "乐器";
                    ui.labelClipped(kind_txt, main_x + 16, ty + track_h - 16, 40, if (inst_failed) ui.theme.danger else ui.theme.text_dim);
                }
                // 右键轨道头 → 重命名/清空菜单（位置快照；与样式右键同一模式）
                if (ui.mouse_right_pressed and ui.hitRect(main_x, ty, header_w, track_h)) {
                    app.panels.ctx_track = i;
                    app.panels.ctx_trk_x = ui.mouse_x;
                    app.panels.ctx_trk_y = ui.mouse_y;
                }
                // 轨道内容区（背景 + 网格）
                const lane_bg = if (i % 2 == 1) ui.theme.item_alt else ui.theme.panel;
                ui.renderer.fillRect(lane_x, ty, view_w, track_h, lane_bg);
                // 网格线（与钢琴卷帘共用 `util.drawTimelineGrid`：网格层（= 当前量化档位）/
                // 拍线/小节线，各自按密度门槛独立显隐；U=96 对齐）
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
                    model.snapSteps(app.playlist.snap), // 播放列表**独立**的吸附档位
                );
                // 行分隔线：必须在片段**之前**绘制——
                // 否则它（画在 ty+track_h-1）会盖住片段底边的亮色描边（只有上/左/右亮、下不亮）。
                ui.renderer.hline(main_x, ty + track_h - 1, main_w, ui.theme.panel_border);
                // **Part（P1c-2）**：按归属轨道 uid 匹配，画成色块
                // ⚠️ 必须在背景/网格**之后**画（先画会被 `lane_bg` 盖掉——实测“加了 Part 看不见”）
                if (app.trackUidOf(i)) |tu| {
                    const saved_pt = ui.renderer.pushClip(lane_x, ty, view_w, track_h);
                    defer ui.renderer.popClip(saved_pt);
                    const step_ws: f32 = bar_ws / @as(f32, @floatFromInt(spb));
                    // **重叠层级与片段一致**：按左端点升序绘制（越靠右越上层；相同 → 数组序）
                    app.playlist.draw_order.clearRetainingCapacity();
                    for (app.parts.items, 0..) |pt0, pi0| {
                        if (pt0.track_uid == tu) app.playlist.draw_order.append(app.allocator, pi0) catch {};
                    }
                    std.mem.sort(usize, app.playlist.draw_order.items, app.parts.items, partLayerLess);
                    for (app.playlist.draw_order.items) |pi| {
                        const pt = &app.parts.items[pi];
                        const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt.start)) * step_ws - scroll_s));
                        const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt.start + pt.len)) * step_ws - scroll_s));
                        if (x1 < lane_x or x0 > lane_x + view_w) continue;
                        // **外观完全照抄样式片段**：
                        // - 高度 = 整行 `track_h`（不是 track_h-6）
                        // - 底色 = 样式色 **32% 不透明**（alpha 80，能透出后面的网格线）
                        // - 描边 / 顶部标识 = 样式色全亮
                        const bh: i32 = track_h;
                        const pw2: i32 = @max(3, x1 - x0);
                        const base = if (pt.muted) muted_gray else patternColor(0); // 静音 = 灰
                        const fill = (@as(u32, 80) << 24) | (base & 0x00FFFFFF);
                        ui.renderer.fillRect(x0, ty, pw2, bh, fill);
                        ui.renderer.strokeRect(x0, ty, pw2, bh, base);
                        // 选中：橙色叠加 + **描边也换成橙色**（与片段同一套规则）
                        if (pt.selected) {
                            const sel_fill = (@as(u32, 60) << 24) | (ui.theme.note_selected & 0x00FFFFFF);
                            ui.renderer.fillRect(x0, ty, pw2, bh, sel_fill);
                            if (pw2 > 2) ui.renderer.strokeRect(x0, ty, pw2, bh, ui.theme.note_selected);
                        }
                        if (pt.kind == .audio) {
                            // **音频 Part**：画波形（原生尺度、不压缩；超出音频即空）
                            drawAudioPartWave(ui, app, pt, x0, pw2, ty, track_h, step_px, zoom);
                        } else {
                            var pbuf: [24]u8 = undefined;
                            const pname = std.fmt.bufPrint(&pbuf, "Part · {d}音符", .{pt.notes.items.len}) catch "Part";
                            ui.labelClipped(pname, x0 + 5, ty + 3, pw2 - 8, ui.theme.text);
                        }
                    }
                }
                // ── **Part 交互：悬停↔ / 点选 / 拖动移动（跨同类轨）/ 边缘拉伸** ──
                // **手势块只跑一次**（B1-lite）：只在本行 = 鼠标所在行时执行绘制前的手势；
                // 拖动中鼠标可能已不在原行，此时用被拖 Part 自己的行（见下面的 `g_row` 判定）。
                if (app.trackUidOf(i) != null and i == g_row) {
                    const step_ws_ev: f32 = bar_ws / @as(f32, @floatFromInt(spb));
                    const m_step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                    // **像素级命中**（步级 `contains` 在边缘处会漏——拉伸热区甚至落在 Part 外面）：
                    // 返回 (part 下标, 边缘 0/±1)
                    const hit_pt: ?struct { idx: usize, edge: i8 } = blk: {
                        if (!util.inRect(ui.mouse_x, ui.mouse_y, lane_x, ty, view_w, track_h) or ui_blocked) break :blk null;
                        // 重叠时按绘制层级**反序**收集候选（上层优先），供“连点循环切换”用
                        var cand: [8]usize = undefined;
                        var cand_e: [8]i8 = undefined;
                        var nc: usize = 0;
                        const hot: i32 = 5; // 边缘热区（像素）
                        var k: usize = app.playlist.draw_order.items.len;
                        while (k > 0 and nc < cand.len) {
                            k -= 1;
                            const pi2 = app.playlist.draw_order.items[k];
                            const pt2 = &app.parts.items[pi2];
                            if (pt2.track_uid != app.trackUidOf(i).?) continue;
                            const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt2.start)) * step_ws_ev - scroll_s));
                            const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pt2.start + pt2.len)) * step_ws_ev - scroll_s));
                            if (ui.mouse_x >= x0 - hot and ui.mouse_x <= x1 + hot) {
                                cand[nc] = pi2;
                                cand_e[nc] = if (ui.mouse_x <= x0 + hot)
                                    -1
                                else if (ui.mouse_x >= x1 - hot)
                                    1
                                else
                                    0;
                                nc += 1;
                            }
                        }
                        if (nc == 0) break :blk null;
                        // 与片段一致：命中就取**最上层**；真正的轮换由“沉到同起点组最底层”完成
                        break :blk .{ .idx = cand[0], .edge = cand_e[0] };
                    };
                    // 悬停反馈（与样式片段一致）：边缘 → ↔，**本体 → 十字箭头**（可移动）
                    if (hit_pt) |hp2| {
                        ui.cursor = if (hp2.edge != 0) .resize_h else .size_all;
                    }
                    // 双击 **音频 Part** → 波形窗口（目标已改成 Part 下标）
                    if (ui.mouse_double) {
                        if (hit_pt) |hpd| {
                            if (app.parts.items[hpd.idx].kind == .audio) {
                                app.openWaveForPart(hpd.idx);
                                ui.active_id = 0;
                            }
                        }
                    }
                    // 拖动中：光标由**状态**决定（鼠标甩快/移出区域都不退化——与片段同做法）
                    if (app.playlist.part_drag.active) {
                        ui.cursor = if (app.playlist.part_drag.resize_edge != 0) .resize_h else .size_all;
                    }
                    // 注：右键删除不在行循环里做——统一由下方“主流程擦除”处理
                    //（否则一次右键会在两处各删一个：叠放时删掉两个；且会把 erase_drag 错误地点亮）
                    // 按下：命中则选中并开始拖动/拉伸（采集偏移，不跳变）
                    if (ui.mouse_pressed and !ui_blocked and !menu_click and !app.playlist.part_drag.active) {
                        // **Ctrl+单击 Part = 让它成为选区（单选）**：清掉其他选中，只选它
                        // （右键删除统一由主流程擦除处理）
                        if (ui.mods_ctrl and !ui.mods_shift and ui.mouse_pressed and hit_pt != null) {
                            const hp_s = hit_pt.?;
                            for (app.parts.items) |*pp_one| pp_one.selected = false;
                            app.parts.items[hp_s.idx].selected = true;
                            app.sel.part = hp_s.idx;
                            ui.active_id = 0;
                            app.playlist.suppress_marquee = true; // 这一下不当框选起点
                        } else if (ui.mods_ctrl and ui.mods_shift and ui.mouse_pressed and hit_pt != null) {
                            // **Ctrl+Shift+单击 Part = 切换选中**（与片段同语义；不启动拖动/轮换）
                            const hp_t = hit_pt.?;
                            app.parts.items[hp_t.idx].selected = !app.parts.items[hp_t.idx].selected;
                            ui.active_id = 0;
                            // 注：**不**抑制框选——否则 Ctrl+Shift+拖（追加框选）就永远开不起来（实测）
                        } else if (hit_pt) |hp2| {
                            // **已选中的 Part + 选区 ≥ 2 → 批量移动**（不轮换：轮换会重排数组）
                            if (app.parts.items[hp2.idx].selected and app.selectedPartCount() >= 2 and hp2.edge == 0) {
                                app.sel.part = hp2.idx;
                                app.sel.track = @intCast(i);
                                app.beginPartBatchSnap();
                                app.playlist.part_batch = true;
                                app.playlist.batch_down_step = m_step;
                                app.playlist.batch_down_row = @intCast(i);
                                ui.active_id = 7802;
                            } else {
                                // **叠放轮换**（片段同款）：点中的沉到同起点组最底层 → 下次点到下一个
                                const new_idx = app.sinkPartToTieBottom(hp2.idx);
                                app.sel.part = new_idx;
                                app.sel.track = @intCast(i);
                                app.playlist.part_drag = .{
                                    .active = true,
                                    .idx = new_idx,
                                    .grab_step = m_step - app.parts.items[new_idx].start,
                                    .resize_edge = hp2.edge,
                                    .orig_start = app.parts.items[new_idx].start,
                                    .orig_track_uid = app.parts.items[new_idx].track_uid,
                                    .orig_len = app.parts.items[new_idx].len,
                                    .orig_trim = app.parts.items[new_idx].audio.trim_start,
                                };
                                ui.active_id = 7801;
                            }
                        } else if (!ui.mods_ctrl and !ui_blocked and util.inRect(ui.mouse_x, ui.mouse_y, lane_x, ty, view_w, track_h)) {
                            // **点空白 → 取消选中**（Part 单选 + 框选集合都清）
                            // 注：**Ctrl / Ctrl+Shift 下不清**——否则追加框选的快照全是 false（实测：
                            // “Ctrl+Shift+拖”变成新建选区）
                            app.sel.part = null;
                            for (app.parts.items) |*ppz| ppz.selected = false;
                        }
                    }
                    // 拖动：按栅格移动；纵向落到别的行 → 可能换轨
                    if (app.playlist.part_drag.active and ui.active_id == 7801) {
                        // **越界保护**：拖动中 Part 被删（右键擦除/撤销）→ 结束拖动，别访问野下标
                        if (app.playlist.part_drag.idx >= app.parts.items.len) {
                            app.playlist.part_drag.active = false;
                            ui.active_id = 0;
                        } else if (ui.mouse_down) {
                            const cur_pt = &app.parts.items[app.playlist.part_drag.idx];
                            if (app.playlist.part_drag.resize_edge != 0) {
                                // **拉伸边缘**（最小 1 小节 / 1 步；拖动时实时改）
                                if (app.playlist.part_drag.resize_edge < 0) {
                                    // **左缘**：右端固定。
                                    // 唯一差异：midi Part 无左边界；**audio Part 的左缘不能越过采样开头**
                                    //（`trim_start` 用尽即停——切片模型的入点随左缘平移）
                                    const old_end = cur_pt.start + cur_pt.len;
                                    var ns = std.math.clamp(m_step, 0, old_end - 1);
                                    if (cur_pt.kind == .audio) {
                                        const fps: i64 = @intCast(@max(1, app.framesPerStep()));
                                        const head_steps: i32 = @intCast(@divTrunc(@as(i64, app.playlist.part_drag.orig_trim), fps));
                                        const min_start = app.playlist.part_drag.orig_start - head_steps;
                                        if (ns < min_start) ns = min_start;
                                        const d: i64 = @as(i64, ns) - @as(i64, app.playlist.part_drag.orig_start);
                                        const nt: i64 = @as(i64, app.playlist.part_drag.orig_trim) + d * fps;
                                        cur_pt.audio.trim_start = @intCast(@max(0, nt));
                                    }
                                    cur_pt.start = ns;
                                    cur_pt.len = old_end - ns;
                                } else {
                                    cur_pt.len = @max(1, m_step - cur_pt.start);
                                }
                                app.dirty = true;
                            } else {
                                const want_start = m_step - app.playlist.part_drag.grab_step;
                                // 目标行：鼠标所在行；**跨到不同类型的轨道 = 不合格落点**
                                var target_row: ?usize = null;
                                var over_bad = false;
                                // **基准 = 被拖 Part 自己所在的轨道**（不是循环变量 i——
                                // 用 i 会让判定随"当前画到哪一行"而翻转，实测禁止/十字光标反了）
                                const base_row: usize = app.trackRowByUid(app.parts.items[app.playlist.part_drag.idx].track_uid) orelse i;
                                if (ui.mouse_y >= tracks_y and ui.mouse_y < tracks_y + tracks_h) {
                                    const r = @divTrunc(ui.mouse_y - tracks_y + app.playlist.scroll, @max(1, track_h));
                                    if (r >= 0 and r != @as(i32, @intCast(base_row)) and r < @as(i32, @intCast(app.tracks.items.len))) {
                                        const rr: usize = @intCast(r);
                                        if (app.tracks.items[rr].kind == app.tracks.items[base_row].kind) {
                                            target_row = rr;
                                        } else {
                                            over_bad = true; // 类型不匹配
                                        }
                                    }
                                }
                                app.playlist.part_drag.invalid = over_bad;
                                if (over_bad) ui.cursor = .forbidden;
                                // **不合格落点：不换轨，但水平方向仍然跟随鼠标**（传 null = 保持当前轨）
                                app.movePart(app.playlist.part_drag.idx, want_start, if (over_bad) null else target_row);
                            }
                        } else {
                            app.playlist.part_drag.active = false;
                            ui.active_id = 0;
                            app.commitHistory(if (app.playlist.part_drag.resize_edge != 0) "调整 Part 长度" else "移动 Part");
                        }
                    }
                }
                // 旧 MIDI/音频片段绘制已废弃（线性化：音频也画成 Part）
                if (false) {
                    const saved_clips = ui.renderer.pushClip(lane_x, ty, view_w, track_h);
                    defer ui.renderer.popClip(saved_clips);
                    const row_muted = app.trackMuted(i);
                    // 层级（用户拍板）：按左端点升序绘制（越靠右越上层）；左端相同 → 数组序。
                    // 暂存下标表排序（片段数小；表跨帧复用，见 `PlaylistState.draw_order`）。
                    app.playlist.draw_order.clearRetainingCapacity();
                    for (app.clips.items, 0..) |c0, ci0| {
                        // 拖动/拉伸预览优先：预览可能改了轨道，要归到**目标行**绘制
                        const eff = app.previewClipAt(ci0) orelse c0;
                        if (eff.track == @as(i32, @intCast(i))) {
                            app.playlist.draw_order.append(app.allocator, ci0) catch {};
                        }
                    }
                    std.mem.sort(usize, app.playlist.draw_order.items, app.clips.items, clipLayerLess);
                    for (app.playlist.draw_order.items) |ci| {
                        const clip = app.previewClipAt(ci) orelse app.clips.items[ci];
                        const rect = clipXW(clip, lane_x, step_px, app.playlist.scroll_x, zoom);
                        const clip_x = rect.x;
                        const clip_w = rect.w;
                        if (clip_x + clip_w < lane_x or clip_x > lane_x + view_w) continue;
                        const base = if (row_muted) muted_gray_track else if (clip.muted) muted_gray else patternColor(clip.pattern); // 轨道静音=更暗的灰；片段静音=灰
                        // 静音片段内的**前景**（音符缩略图 / 波形 / 名字）：
                        // 未选中用深灰（“看就知道不响”，用户认可）；
                        // **选中时提亮一档**——否则“深灰底 + 橙色叠加”下几乎看不见（实测反馈）。
                        const inner_col = if (row_muted and clip.selected) muted_gray else base; // 只有轨道静音需要提亮
                        const wave_col = if (row_muted or clip.muted) inner_col else ui.theme.waveform;
                        const text_col = if (row_muted or clip.muted) inner_col else ui.theme.text;
                        // 底色 = 样式色（32% 不透明）+ 描边 = 样式色全亮；
                        // 选中片段：额外叠加橙色高亮（框选/批量操作的视觉反馈）
                        //
                        // **细线特例（≤2px——即描边会被跳过的宽度）**：整条用亮色画，
                        // “线本身就是边框”（用户拍板 A 方案）；选中的细线用主题的
                        // 选中橙亮色（`theme.note_selected`，缩小时选中态不丢）。
                        const thin = clip_w <= 2;
                        if (thin) {
                            const line_color = if (clip.selected) ui.theme.note_selected else base;
                            ui.renderer.fillRect(clip_x, ty, @max(1, clip_w), track_h, line_color);
                        } else {
                            const fill = (@as(u32, 80) << 24) | (base & 0x00FFFFFF);
                            ui.renderer.fillRect(clip_x, ty, clip_w, track_h, fill);
                            if (clip.selected) {
                                // 只有**轨道静音**（整体很暗）才换暗橙——深灰底 + 亮橙会混成“橙灰”；
                                // **片段自身静音**（底是中灰 150，叠加后仍然耐看）保持原来的亮橙 24%。
                                const sel_color = if (row_muted) r_mod.rgb(150, 96, 28) else ui.theme.note_selected;
                                const sel_alpha: u32 = if (row_muted) 90 else 60;
                                const sel_fill = (sel_alpha << 24) | (sel_color & 0x00FFFFFF);
                                ui.renderer.fillRect(clip_x, ty, clip_w, track_h, sel_fill);
                            }
                        }

                        // 片段左上角名称区高度（放不下就不占位；阈值放宽到 30px——
                        // 实测反馈：“片段缩短后名字过早消失”）
                        const label_h: i32 = if (clip_w >= 30 and track_h >= 26) 13 else 0;
                        // 音频片段：画波形（替代音符预览；预览走 trim 区间）
                        if (clip.isAudio()) {
                            if (!thin) {
                                if (app.audioStyleAsset(@intCast(clip.audio_style))) |asset| {
                                    const total: i32 = @intCast(asset.data.frame_count);
                                    if (total > 0 and asset.peaks.len > 0) {
                                        // **原生尺度**（不压缩）：clip = 整段音频的切片——
                                        // 每像素 = (1/step_px) 步 × 每步帧数；超出音频即空
                                        const ts: i64 = clip.trim_start;
                                        const fps_f: f64 = @floatFromInt(app.framesPerStep());
                                        const mid = ty + @divTrunc(track_h, 2);
                                        const half: f32 = @as(f32, @floatFromInt(track_h)) * 0.4;
                                        const peak_frames: i32 = @intCast(@max(@as(u32, 1), asset.peak_frames));
                                        var px: i32 = 0;
                                        while (px < clip_w) : (px += 1) {
                                            const pxps: f64 = @as(f64, step_px) * @as(f64, zoom);
                                            const spd_f: f64 = std.math.clamp(@as(f64, app.audioStyleSpeed(clip)), 0.25, 4.0);
                                            // 引擎帧域 → 原生帧域（ratio = 原生/引擎；峰值桶按原生帧）
                                            const fr_i: i64 = @as(i64, @intFromFloat((@as(f64, @floatFromInt(ts)) + @as(f64, @floatFromInt(px)) / @max(1e-6, pxps) * fps_f * spd_f) * @as(f64, asset.data.ratio)));
                                            if (fr_i >= total) break;
                                            const fr: i32 = @intCast(fr_i);
                                            const bi: usize = @min(asset.peaks.len - 1, @as(usize, @intCast(@divTrunc(fr, peak_frames))));
                                            const pk = asset.peaks[bi];
                                            const y0: i32 = mid - @as(i32, @intFromFloat(pk.max * half));
                                            const y1: i32 = mid - @as(i32, @intFromFloat(pk.min * half));
                                            ui.renderer.vline(clip_x + px, y0, @max(1, y1 - y0), wave_col);
                                        }
                                        // 名称：与音符片段**同一位置/风格**（无底色标签——用户拍板）
                                        if (label_h > 0) {
                                            const sidx: usize = @intCast(clip.audio_style);
                                            if (sidx < app.audio_styles.items.len) {
                                                ui.labelClipped(app.audio_styles.items[sidx].name, clip_x + 6, ty + 4, clip_w - 12, text_col);
                                            }
                                        }
                                    }
                                } else {
                                    // 异步导入中（P2）：斜纹占位 + 百分比；真·缺失才写“音频缺失”
                                    if (app.styleImportProgress(@intCast(clip.audio_style))) |p| {
                                        var sx: i32 = 0;
                                        // 斜纹（45°；间距 6px，直接画竖段近似）
                                        while (sx < clip_w) : (sx += 6) {
                                            ui.renderer.vline(clip_x + sx, ty + 2, @max(1, track_h - 4), ui.theme.panel_border);
                                        }
                                        const pct: i32 = @intFromFloat(@round(p * 100.0));
                                        var pbuf: [16]u8 = undefined;
                                        const ptxt = std.fmt.bufPrint(&pbuf, "载入 {d}%", .{pct}) catch "载入";
                                        if (label_h > 0) {
                                            ui.labelClipped(ptxt, clip_x + 6, ty + 4, clip_w - 12, ui.theme.text_dim);
                                        } else if (clip_w >= 40) {
                                            ui.labelClipped(ptxt, clip_x + 3, ty + 3, clip_w - 6, ui.theme.text_dim);
                                        }
                                    } else {
                                        ui.labelClipped("（音频缺失）", clip_x + 4, ty + 3, clip_w - 8, ui.theme.danger);
                                    }
                                }
                            }
                            continue;
                        }

                        // ── 片段内音符预览（minimap 风格）──
                        // 只画“片段可见窗口”（offset..offset+len）内的音符；
                        // 纵向用该样式的音域映射（与三处 minimap 同一规则）
                        // 预览区**与片段边缘严格对齐**（不内缩）：
                        // 否则与网格/边缘错位——拖边缘时音符看起来“漂移几像素”（实测 bug）
                        const inner_x = clip_x;
                        const inner_w = @max(1, clip_w);
                        const inner_y = ty + 2 + label_h;
                        const inner_h = @max(2, track_h - 4 - label_h);
                        {
                            const pi: usize = @intCast(@max(0, clip.pattern));
                            // 细线（≤2px）跳过预览：亮点不可见，且省一遍全量音符扫描
                            if (!thin and clip.pattern >= 0 and pi < pat_stat.len and pat_stat[pi].has_notes) {
                                const range = model.rangeMap(pat_stat[pi].min_pitch, pat_stat[pi].max_pitch, 12);
                                const win_lo = clip.offset;
                                const win_steps = clip.len;
                                // 画**全部**乐器、全部音符（**不做“画满 N 个就停”的截断**）。
                                // 实测 bug：旧版有 `drawn >= 64` 截断——多乐器共用一个大样式时，
                                // 数组顺序靠前的那个乐器往往就占满 64 个名额（实测工程：样式 3578 个
                                // 音符，前 64 个全属同一个乐器）——预览看起来“只显示单个乐器的音符”。
                                // 性能：循环本就要扫全量 notes；每个命中音符只是一次 1-8px × 2px 的
                                // `fillRect`（实测 3578 音符/剪辑每帧几万字节写入，软件光栅无感）。
                                // 若要优化，应做“同像素列合并”而不是静默丢音符（截断即本 bug 之源）。
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
                                    ui.renderer.fillRect(nx, ny, nw, 2, inner_col);
                                }
                            }
                        }

                        // 描边只在“不会被填充满”时才画（与钢琴卷帘音符同一规则）：
                        // 极窄的片段描边会把填充完全包成灰色。
                        if (clip_w > 2) ui.renderer.strokeRect(clip_x, ty, clip_w, track_h, base);
                        if (clip.selected and clip_w > 2) ui.renderer.strokeRect(clip_x, ty, clip_w, track_h, ui.theme.note_selected);
                        // PAT 模式：锚片段高亮（“你正在播的就是它”——游标位置的解释；
                        // 按 sel.pattern——PAT 播放的驱动样式）
                        if (!app.sel.song_mode and !thin and clip.pattern == app.sel.pattern) {
                            if (app.patOriginClip()) |o| {
                                if (o.track == clip.track and o.start == clip.start and o.len == clip.len and o.offset == clip.offset) {
                                    ui.renderer.strokeRect(clip_x, ty, clip_w, track_h, ui.theme.accent);
                                }
                            }
                        }
                        if (label_h > 0) {
                            var buf: [24]u8 = undefined;
                            // 显示**样式名**（可重命名）；名字缺失/索引无效时回退“样式 N”
                            const pname: []const u8 = if (clip.pattern >= 0 and @as(usize, @intCast(clip.pattern)) < app.pattern_items.items.len)
                                app.pattern_items.items[@intCast(clip.pattern)]
                            else
                                "";
                            const label_text = if (pname.len > 0) pname else std.fmt.bufPrint(&buf, "样式 {d}", .{clip.pattern + 1}) catch "";
                            ui.labelClipped(label_text, clip_x + 6, ty + 4, clip_w - 12, text_col);
                        }
                    }
                }
            }
            ty += track_h;
            if (ty > tracks_y + tracks_h) break;
        }

        // 循环区域背景（半透明橙黄 = 选中音符同款色；叠在片段之上——
        // 只做背景提示，不遮挡内容交互）。
        // **单独裁剪到轨道内容区**：外层裁剪含轨道名列（main_x 起），
        // 不收紧的话区域会盖到轨道头上（实测 bug）。
        // 同上：直接看 `loop_song`（本视图时间轴始终是全局步）
        {
            const saved_loop2 = ui.renderer.pushClip(lane_x, tracks_y, view_w, tracks_h);
            defer ui.renderer.popClip(saved_loop2);
            var lo: i32 = 0;
            var hi: i32 = 0;
            var show = false;
            if (app.playback.loop_drag_from) |df| {
                // **按当前网格步进**（与松手时一致）
                const cur_step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                lo = @min(df, cur_step);
                hi = @max(df, cur_step);
                show = hi > lo;
            } else if (app.playback.loop_song) |lr_in| {
                lo = lr_in[0];
                hi = lr_in[1];
                show = hi > lo;
            }
            if (show) {
                const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(lo)) * step_px * zoom - scroll_s));
                const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(hi)) * step_px * zoom - scroll_s));
                const tint = (@as(u32, 40) << 24) | (ui.theme.note_selected & 0x00FFFFFF);
                ui.renderer.fillRect(x0, tracks_y, x1 - x0, tracks_h, tint);
                ui.renderer.vline(x0, tracks_y, tracks_h, ui.theme.note_selected);
                ui.renderer.vline(x1, tracks_y, tracks_h, ui.theme.note_selected);
            }
        }

        // 框选矩形（半透明填充 + 描边；画在片段之上；裁剪到轨道内容区）
        if (app.playlist.marquee_active) {
            const mx0 = @min(app.playlist.marquee_x0, ui.mouse_x);
            const mx1 = @max(app.playlist.marquee_x0, ui.mouse_x);
            const my0 = @min(app.playlist.marquee_y0, ui.mouse_y);
            const my1 = @max(app.playlist.marquee_y0, ui.mouse_y);
            const fill = (@as(u32, 40) << 24) | (ui.theme.accent & 0x00FFFFFF);
            if (app.playlist.row_marquee) {
                // 按行框选：**横跨整个内容区**的行带（轨道行范围；当前行 = 鼠标所在行）
                const cur_track: i32 = @divFloor(ui.mouse_y - tracks_y + app.playlist.scroll, track_h);
                const t0 = @min(app.playlist.row_marquee_track0, cur_track);
                const t1 = @max(app.playlist.row_marquee_track0, cur_track);
                const ry0 = tracks_y + t0 * track_h - app.playlist.scroll;
                const rh = (t1 - t0 + 1) * track_h;
                ui.renderer.fillRect(lane_x, ry0, view_w, rh, fill);
                ui.renderer.strokeRect(lane_x, ry0, view_w, rh, ui.theme.accent);
            } else {
                ui.renderer.fillRect(mx0, my0, mx1 - mx0, my1 - my0, fill);
                ui.renderer.strokeRect(mx0, my0, mx1 - mx0, my1 - my0, ui.theme.accent);
            }
        }
    }

    // 轨道名列与内容区的分界线
    ui.renderer.vline(lane_x, tracks_y, tracks_h, ui.theme.panel_border);

    // **必须在轨道行之后绘制**：否则竖线会被轨道行背景盖住（实测 bug）。
    {
        // 0 轨道时的空状态提示
        if (rows_draw == 0) {
            ui.labelClipped("点左上角「+ 添加轨道」开始吧", main_x + 8, tracks_y + @divTrunc(tracks_h, 2) - 6, main_w - 16, ui.theme.text_dim);
        }

        // **播放游标（轨道区）**：标尺行倒三角 + 贯穿轨道区的竖线。
        // 注：这里以前没有显式绘制（只有 PAT 模式下的 PAT 游标），SONG 模式下就“看不见”。
        {
            const bar_frac: f32 = app.cursorDisplay(true) / @as(f32, @floatFromInt(spb));
            const cx = lane_x + @as(i32, @intFromFloat(bar_frac * bar_ws - scroll_s));
            if (cx >= lane_x - 2 and cx <= lane_x + view_w + 2) {
                util.drawCursor(ui, cx, ruler_y, ruler_h, tracks_y + tracks_h, app.playing);
            }
        }

        // 交互（仅标尺行）：按下 → 直接设置位置并进入拖动；拖动中跟随鼠标
        // （`menu_click` 门控：点选单条目的那一帧不得穿透到标尺）
        const in_ruler = !menu_click and !ui_blocked and ui.hitRect(lane_x, ruler_y, view_w, ruler_h);
        // Ctrl+标尺：拖动 = 设循环区域；单击（未拖动）= 取消循环
        // （全局步；点播放列表标尺会切 SONG——见下方跳转分支）；
        // 鼠标→步**吸附到当前网格**
        if (in_ruler and ui.mouse_pressed and ui.mods_ctrl) {
            const step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
            app.sel.song_mode = true; // 循环区域存 SONG 槽（与下方坐标系一致）
            app.playback.loop_drag_from = step;
            app.playback.loop_drag_press_x = ui.mouse_x;
            app.playback.loop_drag_moved = false;
            ui.active_id = 7501; // 循环标尺手势（播放列表版）
            // **按下即清空选区**（不等拖动）：Ctrl+单击刻度尺 = 清空；
            // Ctrl+拖 = 从空选区开始重选区间内的对象（实测：以前要拖起来才清，很别扭）
            app.clearNoteSelection();
            app.clearClipSelection();
            app.sel.part = null;
            for (app.parts.items) |*pp_clr| pp_clr.selected = false;
        }
        if (ui.active_id == 7501) {
            if (!ui.mouse_down) {
                if (app.playback.loop_drag_moved) {
                    if (app.playback.loop_drag_from) |df| {
                        const step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                        const lo = @min(df, step);
                        const hi = @max(df, step);
                        app.sel.song_mode = true;
                        app.setLoopRegion(lo, hi);
                        app.selectNotesInRegionSong(lo, hi); // 选中被拖过区域的音符（全局映射）
                        app.selectClipsInRegionSong(lo, hi); // **片段同理**（与钢琴窗对齐）
                    }
                } else {
                    app.clearLoopRegion(); // 单击未拖动 = 取消循环
                    app.clearNoteSelection(); // 一并取消音符选区
                    app.clearClipSelection(); // 片段选区同理（与钢琴窗对齐）
                }
                app.playback.loop_drag_from = null;
                app.playback.loop_drag_moved = false;
                ui.active_id = 0;
            } else {
                if (@abs(ui.mouse_x - app.playback.loop_drag_press_x) > 3) {
                    app.playback.loop_drag_moved = true;
                }
                // 拖动中**实时高亮**：区域内的音符/片段每帧重算选中
                // （同框选“框内 = 选中”；不必等松手）
                if (app.playback.loop_drag_moved) {
                    if (app.playback.loop_drag_from) |df| {
                        const cur = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                        app.selectNotesInRegionSong(@min(df, cur), @max(df, cur));
                        app.selectClipsInRegionSong(@min(df, cur), @max(df, cur));
                        // **同时选中区间内的 Part**（线性工作流；与框选同一套 selected 语义）
                        const lo_p = @min(df, cur);
                        const hi_p = @max(df, cur);
                        for (app.parts.items) |*pp_r| {
                            pp_r.selected = pp_r.start < hi_p and pp_r.start + pp_r.len > lo_p;
                        }
                    }
                }
            }
        } else if (in_ruler and ui.mouse_pressed) {
            ui.active_id = 7000;
        }
        if (ui.active_id == 7000) {
            if (!ui.mouse_down) {
                ui.active_id = 0;
            } else {
                // 鼠标 → 全局步（**吸附到当前网格**；范围 ≥ 0）
                const step = playlistMouseStepSnap(ui.mouse_x, lane_x, app.playlist.scroll_x, zoom, step_px, pl_snap);
                // **点播放列表标尺 = 自动切 SONG**（本视图编辑的是全曲时间线；
                // 符合直觉：在播放列表里定游标 → 就是要听全曲）。
                // 切换后下面的 jumpPlaybackCursorDrag 会按 SONG 语义跳转。
                app.sel.song_mode = true;
                // 跳转（**去重**：按住期间只在目标步变化/按下帧才跳——
                // 否则每帧 reset → 音符每帧重触发“响两下”，实测 bug）
                app.jumpPlaybackCursorDrag(step, ui.mouse_pressed);
            }
        }
    }

    // ── 鼠标交互（轨道内容区）──
    // 左键空位：放置样式；左键片段：拖动移动；片段右缘：拉伸长度；右键片段：删除
    // （`menu_click` 门控已在函数顶部提前计算——标尺/轨道区都用它）
    // **面板带（分割条 + 自动化面板）整块不属于轨道区**：显式排除，
    // 不再依赖“tracks_h 已经减过 auto_h”这种间接保证（实测：点面板会落到轨道行上）。
    const panel_top: i32 = list_y + list_h;
    const in_panel = ui.mouse_y >= panel_top;
    const in_lane = !menu_click and !in_panel and !ui_blocked and ui.hitRect(lane_x, tracks_y, view_w, tracks_h);
    const track_i = @divFloor(ui.mouse_y - tracks_y + app.playlist.scroll, track_h);
    // 鼠标 → 内容坐标（除以 zoom）→ **全局步**（U=96）
    const mouse_cx: f32 = @as(f32, @floatFromInt(app.playlist.scroll_x)) + @as(f32, @floatFromInt(ui.mouse_x - lane_x)) / zoom;
    const step_i: i32 = @max(0, @as(i32, @intFromFloat(mouse_cx / step_px)));
    // 量化/吸附格（步）——片段移动/拉伸对齐到它
    const snap_steps: i32 = model.snapSteps(app.playlist.snap);
    const snap_step: i32 = @max(0, model.snapRound(step_i, snap_steps));
    const valid_track = track_i >= 0 and track_i < rows_draw;

    // **左键点网格区任意位置（含下方没有轨道的空白）→ 取消选中**
    // 注：命中 Part 的路径在前面行循环里已经处理（会 set sel.part），这里只处理“没点到 Part”。
    if (ui.mouse_pressed and !ui.mods_ctrl and !app.playlist.part_drag.active and ui.active_id == 0 and !ui_blocked and
        ui.hitRect(main_x, tracks_y, main_w, tracks_h) and app.partAt(@max(0, track_i), step_i) == null)
    {
        app.sel.part = null;
        for (app.parts.items) |*ppc| ppc.selected = false;
    }
    // ── **框选：Part**（Ctrl+左键拖；Ctrl+Shift = 追加；起点在行头列 = 按行选）──
    // 与片段版同一套状态机，但选区落到 `Part.selected`（用 `marquee_parts` 区分）。
    // 注：**旧的“片段框选”启动块已删除**——它与本块抢同一个 Ctrl+按下，
    // 谁先抢到 `active_id` 谁生效（实测：Part 框选永远开不起来、框选退不出）。
    if (ui.mods_ctrl and ui.mouse_pressed and !ui_blocked and ui.active_id == 0 and !app.playlist.suppress_marquee) {
        const in_header_p = ui.hitRect(main_x, tracks_y, header_w, tracks_h);
        if (in_lane or in_header_p) {
            app.playlist.marquee_active = true;
            app.playlist.marquee_parts = true;
            app.playlist.marquee_add = ui.mods_shift;
            app.playlist.marquee_x0 = ui.mouse_x;
            app.playlist.marquee_y0 = ui.mouse_y;
            app.playlist.row_marquee = in_header_p;
            app.playlist.row_marquee_track0 = track_i;
            ui.active_id = 7402; // Part 框选手势（与片段的 7400 分开）
            // 追加模式：拍快照（每帧用“快照 ∪ 框内”重建）
            app.allocator.free(app.playlist.marquee_snap);
            app.playlist.marquee_snap = &.{};
            if (app.playlist.marquee_add) {
                var snap: []bool = app.allocator.alloc(bool, app.parts.items.len) catch return;
                for (app.parts.items, 0..) |pp0, kk| {
                    if (kk < snap.len) snap[kk] = pp0.selected;
                }
                app.playlist.marquee_snap = snap;
            } else {
                for (app.parts.items) |*pp0| pp0.selected = false;
            }
        }
    }
    // **结束条件不能用 `active_id == 7402`**：行循环里的其它控件可能先把 active_id 清掉，
    // 那样就永远进不了结束分支（实测：Ctrl+拖之后框选退不出来）。
    // 现在只看“是否还在按左键”，并顺手把 7402 收回去。
    app.playlist.suppress_marquee = false; // 只抑制“按下那一帧”
    if (app.playlist.marquee_active and app.playlist.marquee_parts and !ui.mouse_down) {
        if (ui.active_id == 7402) ui.active_id = 0;
        app.playlist.marquee_active = false;
        app.playlist.marquee_parts = false;
        app.playlist.marquee_add = false;
        app.playlist.row_marquee = false;
        app.allocator.free(app.playlist.marquee_snap);
        app.playlist.marquee_snap = &.{};
    }
    // **按下那一帧不重算**：Ctrl+Shift+单击的“切换选中”已经在这帧生效，
    // 若同帧再用框选重算，鼠标下的 Part 会被重新选上（实测：切换取消失效）。
    // 另：**没真拖动（<3px）也不重算** —— 否则零尺寸矩形会把鼠标下的 Part 又选上，
    // 表现为“取消选中后很快又变回选中”
    const marquee_moved = @abs(ui.mouse_x - app.playlist.marquee_x0) >= 3 or @abs(ui.mouse_y - app.playlist.marquee_y0) >= 3;
    if (app.playlist.marquee_active and app.playlist.marquee_parts and !ui.mouse_pressed and marquee_moved) {
        const mx0 = @min(app.playlist.marquee_x0, ui.mouse_x);
        const mx1 = @max(app.playlist.marquee_x0, ui.mouse_x);
        const my0 = @min(app.playlist.marquee_y0, ui.mouse_y);
        const my1 = @max(app.playlist.marquee_y0, ui.mouse_y);
        const step_ws_q: f32 = bar_ws / @as(f32, @floatFromInt(spb));
        const t0 = @min(app.playlist.row_marquee_track0, track_i);
        const t1 = @max(app.playlist.row_marquee_track0, track_i);
        for (app.parts.items, 0..) |*pp1, pi1| {
            // 追加：先回快照；否则先清空
            pp1.selected = if (app.playlist.marquee_add)
                (if (pi1 < app.playlist.marquee_snap.len) app.playlist.marquee_snap[pi1] else false)
            else
                false;
            // 轨道行
            const rowi = if (app.trackRowByUid(pp1.track_uid)) |r| @as(i32, @intCast(r)) else -1;
            if (rowi < 0) continue;
            if (app.playlist.row_marquee) {
                if (rowi >= t0 and rowi <= t1) pp1.selected = true;
                continue;
            }
            const x0 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pp1.start)) * step_ws_q - scroll_s));
            const x1 = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(pp1.start + pp1.len)) * step_ws_q - scroll_s));
            const cy = tracks_y + rowi * track_h - app.playlist.scroll;
            if (x1 >= mx0 and x0 <= mx1 and cy + track_h >= my0 and cy <= my1) pp1.selected = true;
        }
    }

    if (false and app.playlist.marquee_active and !app.playlist.marquee_parts) { // 旧片段框选：已废弃
        const mx0 = @min(app.playlist.marquee_x0, ui.mouse_x);
        const mx1 = @max(app.playlist.marquee_x0, ui.mouse_x);
        const my0 = @min(app.playlist.marquee_y0, ui.mouse_y);
        const my1 = @max(app.playlist.marquee_y0, ui.mouse_y);
        // 每帧重建选区：追加模式 = 快照 ∪ 框内（框缩回时自动回退）；否则 = 框内
        for (app.clips.items, 0..) |*c, ci| {
            if (app.playlist.marquee_add) {
                c.selected = if (ci < app.playlist.marquee_snap.len) app.playlist.marquee_snap[ci] else false;
            } else {
                c.selected = false;
            }
            if (app.playlist.row_marquee) {
                // 按行：轨道在起始/当前行之间 → 选中（**水平不限**）
                const t0 = @min(app.playlist.row_marquee_track0, track_i);
                const t1 = @max(app.playlist.row_marquee_track0, track_i);
                if (c.track >= t0 and c.track <= t1) c.selected = true;
                continue;
            }
            const rect = clipXW(c.*, lane_x, step_px, app.playlist.scroll_x, zoom);
            const cy = tracks_y + @as(i32, @intCast(c.track)) * track_h - app.playlist.scroll;
            if (rect.x + rect.w >= mx0 and rect.x <= mx1 and cy + track_h >= my0 and cy <= my1) {
                c.selected = true;
            }
        }
    }

    // 命中：鼠标下的片段 + 命中模式（中部 / 左缘 / 右缘，边缘区 8px）
    // 注：框选手势期间不命中（框选优先）
    var clip_hit: ?struct { index: usize, mode: model.ClipHitMode } = null;
    // 拖动/拉伸进行中不重新命中（模型位置未变，会让另一个片段"假悬停"）
    const drag_busy = app.playlist.drag_clip != null or app.playlist.resize_clip != null or
        app.playlist.drag_batch or app.playlist.batch_trim;
    if (false and in_lane and valid_track and !app.playlist.marquee_active and !ui.mods_ctrl and !drag_busy) { // 旧片段命中：已废弃
        // 叠放（用户拍板）：命中取**最顶层**（左端越右越上；同左端取数组序最大）
        if (model.topmostClipAt(app.clips.items, track_i, step_i)) |ci| {
            const c = app.clips.items[ci];
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
        }
    }

    // 双击片段：打开钢琴卷帘（编辑该样式）。
    // 用**第一次按下时命中**的片段（`prev_click_clip`）——点击会触发叠放轮换，
    // 第二次按下时命中的可能已经换人（用户双击的意图是第一次那个）。
    if (ui.mouse_double) {
        // **必须当前双击点命中片段**才打开（实测 bug：双击播放按钮打开了钢琴窗——
        // `prev_click_clip` 残留 + 此前无命中门槛，双击任意位置都会开“上次点的片段”）。
        // `prev_click_clip` 只用于消解“叠放轮换换人”的歧义（第一次按下的那个）。
        if (clip_hit) |hit| {
            var dbl: ?usize = app.playlist.prev_click_clip;
            if (dbl) |di| {
                if (di >= app.clips.items.len) dbl = null; // 已被删除 → 退回当前命中
            }
            const di = dbl orelse hit.index;
            const c = app.clips.items[di];
            if (c.isAudio()) {
                app.openWaveForClip(di); // 音频片段 → 波形窗口
            } else {
                app.openPianoFromClip(c); // 记录锚片段（PAT ⇄ SONG 位置映射，规则 1）
            }
            return;
        }
    }

    // 光标：
    // - 拖动中：边缘拉伸 → ↔（左右箭头）；移动/批量 → 十字箭头
    // - 悬停：边缘 → ↔；**主体（可拖动）→ 十字箭头**（与边缘 hover 同一层次感）
    if (app.playlist.batch_trim or app.playlist.resize_clip != null) {
        ui.cursor = .resize_h;
    } else if (app.playlist.drag_clip != null or app.playlist.drag_batch) {
        ui.cursor = .size_all;
    } else if (clip_hit) |hit| {
        ui.cursor = if (hit.mode == .body) .size_all else .resize_h;
    }

    // 右键：**起点在 Part 上 → 只删这一个**；
    // **起点在空白网格 → 按住拖动 = 擦除划过的所有 Part**（与片段同语义）
    // 注：起点必须在**轨道内容区**（`lane_x` 起）——否则右键轨道头时 `step_i`
    // 会被钳到 0，把紧贴行头的 Part 误删（实测 bug）
    if (ui.mouse_right_pressed and ui.hitRect(lane_x, tracks_y, view_w, tracks_h)) {
        var hit_top: ?usize = null;
        if (app.trackUidOf(@intCast(track_i))) |uu| {
            for (app.parts.items, 0..) |pt4, pi4| {
                if (pt4.track_uid != uu or !pt4.contains(step_i)) continue;
                // 取**最上层**：起点更靠右的在上；起点相同 → 数组序大的在上（与绘制层级一致）
                if (hit_top) |bt| {
                    if (pt4.start > app.parts.items[bt].start) {
                        hit_top = pi4;
                    } else if (pt4.start == app.parts.items[bt].start and pi4 > bt) {
                        hit_top = pi4;
                    }
                } else hit_top = pi4;
            }
        }
        if (hit_top) |hi4| {
            app.playlist.erase_drag = false;
            if (app.removePart(hi4)) {
                app.commitHistory("删除 Part");
                app.setToast("已删除 Part");
            }
        } else if (!ui.mods_ctrl) {
            // 点空白 → 取消选中 + 起手擦除拖动（音频/音符 Part 同一套）
            app.sel.part = null;
            for (app.parts.items) |*ppz2| ppz2.selected = false;
            app.playlist.erase_drag = true;
        }
    }
    if (app.playlist.erase_drag) {
        if (!ui.mouse_right_down) {
            app.playlist.erase_drag = false;
        } else if (in_lane and valid_track and !app.playlist.marquee_active and !ui.mods_ctrl) {
            // 拖动擦除：鼠标碰到的 Part **全部**删（叠放也一起）
            var k5: usize = app.parts.items.len;
            var erased: usize = 0;
            const uid5 = app.trackUidOf(@intCast(track_i));
            while (k5 > 0) {
                k5 -= 1;
                const pt5 = &app.parts.items[k5];
                if (uid5) |uu5| {
                    if (pt5.track_uid == uu5 and pt5.contains(step_i)) {
                        if (app.removePart(k5)) erased += 1;
                    }
                }
            }
            if (erased > 0) app.history_pending = "擦除 Part";
        }
    }
    // （音频片段擦除的旧分支已移除：音频 Part 还没做，此处只处理 Part）

    // ── **Part 批量拖动**（选区 ≥ 2）──
    // 组级夹 + 不落入异类轨道：位移全部交给 `movePartBatch`（以快照为锚，幂等）
    if (app.playlist.part_batch) {
        if (!ui.mouse_down) {
            app.playlist.part_batch = false;
            if (ui.active_id == 7802) ui.active_id = 0;
            app.commitHistory("批量移动 Part");
        } else {
            const d_step = model.snapRound(snap_step - app.playlist.batch_down_step, snap_steps);
            var d_row: i32 = 0;
            if (ui.mouse_y >= tracks_y and ui.mouse_y < tracks_y + tracks_h) {
                const r = @divTrunc(ui.mouse_y - tracks_y + app.playlist.scroll, @max(1, track_h));
                d_row = r - app.playlist.batch_down_row;
            }
            if (app.movePartBatch(d_step, d_row)) ui.cursor = .forbidden;
        }
    }

    // 左键按下：选中 / 开始拖动或拉伸 / 空位放置
    // 注：Ctrl 按下（框选手势）时不放置/拖动——否则框选启动当帧会先放一个片段
    if (ui.mouse_pressed and in_lane and !ui.mods_ctrl and valid_track) {
        app.sel.track = track_i;
        if (clip_hit) |hit0| {
            // 叠放轮换（用户拍板）：点中即沉到**同左端点组的最底层**——
            // 原来的第二层顶上来，连点即轮换；随后的拖动/拉伸仍作用于它
            // （索引用沉降后的新值；`prev_click_clip` 供双击打开用）。
            const hit = .{ .index = app.sinkClipToTieBottom(hit0.index), .mode = hit0.mode };
            app.playlist.prev_click_clip = hit.index;
            const c = app.clips.items[hit.index];
            app.sel.pattern = c.pattern;
            // 拉伸基准（**按下时快照**）：原起点/原长/按下步——增量式拉伸的锚
            app.playlist.resize_orig_start = c.start;
            app.playlist.resize_orig_len = c.len;
            app.playlist.resize_orig_trim = c.trim_start;
            app.playlist.resize_down_step = step_i;
            // 拖动死区：先记录按下位置；超过阈值才真正编辑（防单击吸附）
            app.playlist.drag_armed = false;
            app.playlist.drag_down_x = ui.mouse_x;
            app.playlist.drag_down_y = ui.mouse_y;
            // 命中**已选中的片段** + 选区 ≥ 2：
            // - 中部 → 批量拖动；边缘 → 批量拉伸（全组同步，与音符一致）
            const batch_sel = c.selected and app.selectedClipCount() >= 2;
            if (batch_sel and hit.mode == .body) {
                app.beginClipBatchSnap();
                app.beginDragSnaps(null); // 批量移动：记下所有选中片段的旧位置
                app.playlist.drag_batch = true;
                app.playlist.batch_down_step = step_i;
                app.playlist.batch_down_track = track_i;
                app.playlist.preview_rows = rows_draw;
                app.history_pending = "批量移动片段"; // 松手时 coalesce 提交
            } else if (batch_sel) {
                app.beginClipBatchSnap();
                app.beginDragSnaps(null); // 批量拉伸：同上
                app.playlist.batch_trim = true;
                app.playlist.batch_trim_down_step = step_i;
                app.playlist.batch_trim_grid = @max(1, snap_steps);
                app.playlist.resize_left = hit.mode == .left;
                app.history_pending = "批量拉伸片段";
            } else {
                // 单选语义：点未选中片段 → 清除旧选区（只操作当前这个）
                if (!c.selected) app.clearClipSelection();
                app.history_pending = switch (hit.mode) {
                    .body => "移动片段",
                    .left, .right => "拉伸片段",
                };
                switch (hit.mode) {
                    .left => {
                        app.playlist.resize_clip = hit.index;
                        app.beginDragSnaps(hit.index);
                        app.playlist.resize_left = true;
                    },
                    .right => {
                        app.playlist.resize_clip = hit.index;
                        app.beginDragSnaps(hit.index);
                        app.playlist.resize_left = false;
                    },
                    .body => {
                        app.playlist.drag_clip = hit.index;
                        app.beginDragSnaps(hit.index);
                        app.playlist.drag_grab = step_i - c.start;
                    },
                }
            }
        } else {
            app.clearClipSelection();
            app.playlist.prev_click_clip = null;
            // 选中了音频样式（♪ 行，且当前在音频页）→ 放置**音频片段**
            // 注：`ui.active_id != 0` = 这次按下已被其它控件（如 **Part 拖动**）认领 → 不再放新的
            if (ui.active_id != 0) {
                // 已由 Part 交互处理（点中已有 Part = 拖动，不是新建）
            } else if (app.panels.patterns_tab_audio and app.audio_style_sel >= 0 and @as(usize, @intCast(app.audio_style_sel)) < app.audio_styles.items.len) {
                const ast = app.audio_styles.items[@intCast(app.audio_style_sel)];
                // 异步导入中资产还没挂上 → 用文件头的引擎帧数（长度一样是对的）
                const frames: i32 = if (app.audioStyleAsset(@intCast(app.audio_style_sel))) |d|
                    @intCast(d.data.engFrames())
                else
                    @intCast(@min(ast.frames_hint, std.math.maxInt(i32)));
                const fps: i32 = @intCast(@max(1, app.framesPerStep()));
                const alen: i32 = @max(1, @divTrunc(frames, fps));
                _ = app.addAudioPart(@intCast(track_i), snap_step, alen, @intCast(app.audio_style_sel), 0);
                app.commitHistory("放置音频 Part"); // 原子操作：立即提交
            } else if (!app.isAudioTrack(@intCast(track_i))) {
                // **P1c-2：左键点空白 = 放置一个 1 小节的 Part**（替代“放样式片段”）
                // 注：**音频轨上不放音符 Part**（一轨一类），音频轨只能通过上面的音频样式分支放音频 Part
                // 对齐到小节起点（用户定稿：Part = 自带音符的块，不跨轨）
                const spb_i: i32 = app.steps_per_bar;
                const bar_start: i32 = @divTrunc(@max(0, snap_step), spb_i) * spb_i;
                if (app.addPart(@intCast(track_i), bar_start, spb_i)) |_| {
                    app.commitHistory("放置 Part");
                }
            }
        }
    }

    // 拖动 / 拉伸更新（鼠标可移出区域；位置 clamp 到有效范围）
    if (ui.mouse_down) {
        // ── 批量拖动（选区 ≥ 2）──
        if (false and app.playlist.drag_batch) { // 旧片段批量拖动：已废弃
            if (!app.playlist.drag_armed) {
                const dx = ui.mouse_x - app.playlist.drag_down_x;
                const dy = ui.mouse_y - app.playlist.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.playlist.drag_armed = true;
            }
            if (app.playlist.drag_armed) {
                const d_step = model.snapRound(step_i - app.playlist.batch_down_step, snap_steps);
                const d_track = track_i - app.playlist.batch_down_track;
                // **只更新预览**，松手才真正移动（拖动期间调度器看到的仍是旧位置）
                app.playlist.preview_batch_step = d_step;
                app.playlist.preview_batch_track = d_track;
            }
        }
        // ── 批量拉伸（选区 ≥ 2 边缘拖动；全组同步，与音符一致）──
        if (false and app.playlist.batch_trim) { // 旧片段批量拉伸：已废弃
            if (!app.playlist.drag_armed) {
                const dx = ui.mouse_x - app.playlist.drag_down_x;
                const dy = ui.mouse_y - app.playlist.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.playlist.drag_armed = true;
            }
            if (app.playlist.drag_armed) {
                const g = app.playlist.batch_trim_grid;
                // 位移 → 格数（左缘：左移为正、右缘：右移为正；与单片段增量式一致）
                const delta = if (app.playlist.resize_left)
                    app.playlist.batch_trim_down_step - step_i // 左缘：左移为正（加长）
                else
                    step_i - app.playlist.batch_trim_down_step; // 右缘：右移为正（加长）
                const k = model.gridSteps(delta, g);
                _ = app.applyClipBatchTrim(k, g, app.playlist.resize_left);
                _ = app.syncDragSnaps(); // 播放中改时间 → 旧实例释音 + 重扫
            }
        }
        // 死区：位移超过 3px 才真正开始编辑（防单击片段被吸附）
        if (app.playlist.drag_clip != null or app.playlist.resize_clip != null) {
            if (!app.playlist.drag_armed) {
                const dx = ui.mouse_x - app.playlist.drag_down_x;
                const dy = ui.mouse_y - app.playlist.drag_down_y;
                if (dx * dx + dy * dy >= 3 * 3) app.playlist.drag_armed = true;
            }
        }
        if (false and app.playlist.drag_armed) { // 旧片段拖动/拉伸：已废弃
            if (app.playlist.drag_clip) |ci| {
                if (ci < app.clips.items.len) {
                    const c = app.clips.items[ci];
                    // **目标位置**吸附到网格（而非鼠标位置——抓取点不在格上时会脱格）
                    const target = @max(0, step_i - app.playlist.drag_grab);
                    const new_start = @max(0, model.snapRound(target, snap_steps));
                    // **音频片段只能落到音频轨**（线性化：音频 Part 限同类轨）；
                    // 落点不是音频轨 → 保持源轨 + “禁止”光标（松手自然回到原处）
                    var new_track = std.math.clamp(track_i, 0, @max(0, rows_draw - 1));
                    if (new_track != c.track and !app.isAudioTrack(new_track)) {
                        new_track = c.track;
                        ui.cursor = .forbidden;
                    }
                    // **只写预览**：拖动期间不动模型（音频零干扰，松手一次性提交）
                    var pc = c;
                    pc.start = new_start;
                    pc.track = new_track;
                    app.playlist.preview_idx = ci;
                    app.playlist.preview_clip = pc;
                }
            }
            if (app.playlist.resize_clip) |ci| {
                if (ci < app.clips.items.len) {
                    const c = app.clips.items[ci];
                    const min_len = model.trimMinGridLen(app.playlist.resize_orig_len, snap_steps);
                    if (app.playlist.resize_left) {
                        // 左缘：右端固定；长度增量式（鼠标左移 = 拉长）
                        const right = app.playlist.resize_orig_start + app.playlist.resize_orig_len;
                        const delta = app.playlist.resize_down_step - step_i; // 左移为正（拉长）
                        const len = @min(model.trimLenByGrid(app.playlist.resize_orig_len, delta, snap_steps), right);
                        if (c.isAudio()) {
                            // 音频片段：**整个音频的一个切片**（用户拍板）——
                            // 左缘拖动 = 采样内起点（入点）；到音频开头即不能再往左
                            // （len 增长受 trim_start 余量限制；波形不压缩、被裁）
                            const delta2 = app.playlist.resize_down_step - step_i; // 左移为正（拉长）
                            var alen = model.trimLenByGrid(app.playlist.resize_orig_len, delta2, snap_steps);
                            const fps: i64 = @intCast(app.framesPerStep());
                            const head_steps: i32 = @intCast(@divTrunc(@as(i64, app.playlist.resize_orig_trim), fps));
                            const max_len = app.playlist.resize_orig_len + head_steps;
                            if (alen > max_len) alen = max_len;
                            alen = @min(alen, right);
                            const new_start = right - alen;
                            const dsteps: i64 = @as(i64, new_start) - @as(i64, app.playlist.resize_orig_start);
                            const nts = std.math.clamp(@as(i64, app.playlist.resize_orig_trim) + dsteps * fps, 0, @max(0, @as(i64, if (app.clipAudioData(c)) |d| @as(i32, @intCast(d.engFrames())) else 1) - 1));
                            if (nts != c.trim_start or new_start != c.start or alen != c.len) {
                                var pc = c;
                                pc.trim_start = @intCast(nts);
                                pc.start = new_start;
                                pc.len = alen;
                                pc.trim_len = 0; // 切片模型：长度即裁切，不用 trim_len
                                app.playlist.preview_idx = ci;
                                app.playlist.preview_clip = pc;
                            }
                        } else if (model.clipTrimLeft(c, right - len, min_len)) |nc| {
                            // 叠放实验：不再拦截重叠
                            if (nc.start != c.start or nc.len != c.len or nc.offset != c.offset) {
                                app.playlist.preview_idx = ci;
                                app.playlist.preview_clip = nc;
                            }
                        }
                    } else {
                        // 右缘：长度 = **原长 + k×格**（网格决定增减步长）
                        // 叠放实验：不再限“同轨下一片段之前”，也不再拦截重叠
                        const delta = step_i - app.playlist.resize_down_step;
                        const new_len = @max(min_len, model.trimLenByGrid(app.playlist.resize_orig_len, delta, snap_steps));
                        if (new_len != c.len) {
                            var pc = c;
                            pc.len = new_len;
                            app.playlist.preview_idx = ci;
                            app.playlist.preview_clip = pc;
                        }
                    }
                }
            }

            // 批量拉伸仍是**实时应用**（逐片段增量式改长，预览成本高）→ 每帧同步音频
            _ = app.syncDragSnaps();
        }
    } else {
        // **松手才应用**：提交拖动/拉伸预览（位置/长度/轨道）→ 旧实例释音 + 重扫
        app.commitDragPreview();
        app.playlist.drag_clip = null;
        app.playlist.resize_clip = null;
        app.endDragSnaps();
        app.playlist.drag_armed = false; // 下次按下重新评估死区
        app.playlist.drag_batch = false;
        app.playlist.batch_trim = false;
    }

    // 纵向滚动：滚轮（主区）+ 右侧纵向滚动条
    // 中键拖动中：屏蔽滚轮（含 Ctrl/Shift 缩放）——缩放会让锚定比例失准、
    // 拖动跟随抽动（用户约定：拖动期间只平移，不缩放）
    // 网格区**和**纵向滚动条上都响应滚轮（鼠标停在滚动条上滚不动不符合直觉）
    // **Ctrl+滚轮（横向缩放）的范围要把自动化面板也算进来**（与钢琴窗对齐：
    // 钢琴窗的命中区是 `lane_h + splitter_h + editor_h`）。其余修饰键保持原范围，
    // 以免面板里的滚轮被播放列表抢走。
    const over_tracks = ui.hitRect(main_x, tracks_y, main_w, tracks_h);
    const over_with_panel = ui.hitRect(main_x, tracks_y, main_w, tracks_h + splitter_h + auto_h);
    const wheel_area = if (ui.wheel_ctrl) over_with_panel else over_tracks;
    if (!app.playlist.nav_active and (wheel_area or ui.hitRect(sb_x, tracks_y, ruler_h, tracks_h))) {
        if (ui.wheel_ctrl) {
            // Ctrl+滚轮：横向缩放——**只更新补间目标**（滚轮离散，逐帧平滑逼近；
            // 补间块在本段之后；锚定用事件时的鼠标偏移，补间每一步都锚定）
            // 注：拉回**无条件执行**（不只在 zoom 变化时）——
            // 否则“已缩到下限 + 视口停在右侧空白”时下滚会无事发生。
            app.playlist.zoom_anchor_off = ui.mouse_x - lane_x;
            var tgt = app.playlist.zoom_target;
            // 反向输入先抵消未完成的补间：否则“回滚一格”会先继续朝旧方向动一点（实测手感 bug）
            if ((ui.wheel > 0 and tgt < app.playlist.zoom) or (ui.wheel < 0 and tgt > app.playlist.zoom)) tgt = app.playlist.zoom;
            // 下限取 min(动态下限，当前)：内容缩短（动态下限被动抬高）时
            // 不得把视口突然放大——只拦“继续缩小”。
            app.playlist.zoom_target = std.math.clamp(tgt * std.math.pow(f32, util.wheel_zoom_factor, @as(f32, @floatFromInt(ui.wheel))), @min(dyn_zoom_min, tgt), 8.0);
            // 缩小/已到下限：把视口右缘拉回内容跨度内（全装得下 → 贴左）——悬空量保留
            const vcw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / app.playlist.zoom)));
            const over: i32 = @max(0, app.playlist.scroll_x - @max(0, content_span - vcw));
            app.playlist.scroll_x = Ui.clampScrollToSpan(app.playlist.scroll_x, vcw, content_span) + over;
        } else if (ui.wheel_shift) {
            // Shift+滚轮：**纵向缩放**（轨道行高）——只设补间目标（补间块在本段之后）
            app.playlist.track_h_anchor_off = ui.mouse_y - tracks_y;
            var tgt = app.playlist.track_h_target;
            // 反向输入先抵消未完成的补间（同横向缩放；实测手感 bug）
            if ((ui.wheel > 0 and tgt < app.playlist.track_h) or (ui.wheel < 0 and tgt > app.playlist.track_h)) tgt = app.playlist.track_h;
            app.playlist.track_h_target = std.math.clamp(tgt + ui.wheel * 2, zoom_min_h, util.track_h_max);
        } else {
            // 裸滚轮：纵向滚动——只设补间目标（滚轮离散 → 逐帧平滑）
            // 滚轮上限 = 防溢出帽——**用户拍板：垂直滚轮也可以滚到地图外**（与拖动一致）；
            // 悬空状态不再限制滚轮下滚（旧“不得加深”规则已废）
            app.playlist.scroll_target = std.math.clamp(app.playlist.scroll_target - util.scrollDelta(ui), 0, 1 << 30);
        }
    }

    // ── 横向缩放的**补间动画**（滚轮是离散事件，直接跳变生硬；用户要求平滑）──
    // 目标由 Ctrl+滚轮设置；他处改变 zoom（滚动条拖边缘、载入工程）→ 采纳为目标不补间。
    // 每步 zoomAnchoredScrollX 锚定“事件时鼠标下的内容”——补间期间内容不漂。
    {
        const pl = &app.playlist;
        if (pl.zoom_anim_last < 0.0 or pl.zoom != pl.zoom_anim_last) pl.zoom_target = pl.zoom;
        if (pl.zoom != pl.zoom_target) {
            const z_new = if (@abs(pl.zoom_target - pl.zoom) <= pl.zoom_target * 0.002)
                pl.zoom_target
            else
                util.glideF32(pl.zoom, pl.zoom_target, app.frame_dt_ns, 0.03); // τ=0.03s（用户实测手感）
            if (z_new > 0 and z_new != pl.zoom) {
                const vcw_now: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / pl.zoom)));
                const over: i32 = @max(0, pl.scroll_x - @max(0, content_span - vcw_now)); // 悬空量保留
                pl.scroll_x = Ui.zoomAnchoredScrollX(pl.scroll_x, view_w, pl.zoom_anchor_off, pl.zoom, z_new, content_span, content_span, over);
                pl.zoom = z_new;
            }
        }
        pl.zoom_anim_last = pl.zoom;
    }

    // ── 横向滚动补间（滚动条单击/滚轮只写目标；拖动/载入直接改实体 → 采纳为目标不补间）──
    {
        const pl = &app.playlist;
        if (pl.scroll_x_anim_last != pl.scroll_x) pl.scroll_x_target = pl.scroll_x;
        if (pl.scroll_x != pl.scroll_x_target) {
            const cur: f32 = @floatFromInt(pl.scroll_x);
            const tgt: f32 = @floatFromInt(pl.scroll_x_target);
            const nx: i32 = if (@abs(tgt - cur) <= 1.0) pl.scroll_x_target else @intFromFloat(util.glideF32(cur, tgt, app.frame_dt_ns, 0.06));
            pl.scroll_x = @max(0, nx);
        }
        pl.scroll_x_anim_last = pl.scroll_x;
    }

    // ── 纵向补间（Shift+滚轮 = 轨道行高；裸滚轮 = 纵向滚动；τ=0.03 同横向）──
    // 外部改动（拖纵向滚动条写 `scroll`）→ 采纳为即时目标不补间；行高补间期间
    // 其锚定写入的 `scroll` 也会被采纳，两个补间不会互相拉锯。
    {
        const pl = &app.playlist;
        // 行高
        if (pl.track_h_anim_last < 0 or pl.track_h != pl.track_h_anim_last) pl.track_h_target = pl.track_h;
        if (pl.track_h != pl.track_h_target) {
            const h_new = if (@abs(pl.track_h_target - pl.track_h) <= 1)
                pl.track_h_target
            else
                util.glideI32(pl.track_h, pl.track_h_target, app.frame_dt_ns, 0.03);
            if (h_new > 0 and h_new != pl.track_h) {
                const content_new: i32 = map_rows * h_new;
                const old_map_max: i32 = @max(0, map_rows * pl.track_h - tracks_h);
                const over: i32 = @max(0, pl.scroll - old_map_max); // 悬空量保留（不拽回地图）
                pl.scroll = Ui.zoomAnchoredScrollY(pl.scroll, tracks_h, pl.track_h_anchor_off, pl.track_h, h_new, content_new) + over;
                pl.track_h = h_new;
            }
        }
        pl.track_h_anim_last = pl.track_h;
        // 纵向滚动
        if (pl.scroll_anim_last < 0 or pl.scroll != pl.scroll_anim_last) pl.scroll_target = pl.scroll;
        // 滚轮上限 = 防溢出帽（垂直滚轮可出图——同拖动）
        pl.scroll_target = std.math.clamp(pl.scroll_target, 0, 1 << 30);
        if (pl.scroll != pl.scroll_target) {
            const s_new = if (@abs(pl.scroll_target - pl.scroll) <= 1)
                pl.scroll_target
            else
                util.glideI32(pl.scroll, pl.scroll_target, app.frame_dt_ns, 0.03);
            pl.scroll = std.math.clamp(s_new, 0, 1 << 30);
        }
        pl.scroll_anim_last = pl.scroll;
    }

    // ── 中键拖动：平移视口（抓画布：内容跟手；标尺/轨道区均可起手）──
    {
        const pl = &app.playlist;
        if (!pl.nav_active and ui.mouse_middle_pressed and
            util.hitUI(ui, lane_x, ruler_y, view_w, tracks_y + tracks_h - ruler_y))
        {
            pl.nav_active = true;
            pl.nav_mx = ui.mouse_x;
            pl.nav_my = ui.mouse_y;
            pl.nav_scroll_x0 = pl.scroll_x;
            pl.nav_scroll_y0 = pl.scroll;
        }
        if (pl.nav_active) {
            if (!ui.mouse_middle_down) {
                pl.nav_active = false;
            } else {
                // 从**原点**重算（拖出范围后回拖立即响应，不会积累死区）。
                // 纵向：**悬空出口**——不设地图上限（内部防溢出帽同滚动条控件），拖出/拖回自由。
                // 横向：同理无界（新设计：中键可把视口整个拖出地图）
                // 屏幕位移 → 内容像素（/zoom）——“鼠标移 1px、内容移 1px”的 1:1
                const dx_c = util.screenToContentPx(ui.mouse_x - pl.nav_mx, pl.zoom);
                pl.scroll_x = std.math.clamp(pl.nav_scroll_x0 - dx_c, 0, 1 << 30);
                pl.scroll = std.math.clamp(pl.nav_scroll_y0 - (ui.mouse_y - pl.nav_my), 0, 1 << 30);
            }
        }
    }
    // ── 视角跟随播放游标（工具栏开关；**主动操作优先**）──
    // 中键平移 / 拖滚动条（id=8）按住期间暂停，松手**当帧**恢复跟随（纯即时——
    // 曾经的宽限/桥接等“等待”逻辑已按用户实测结论删除）。
    // 恢复后 → 指数滑动跟到游标（τ≈0.06s；锚点= `util.follow_anchor_frac`，**网格区左 15%**）。
    // 软锚定：行程有余量 → 锚定；余量耗尽（近曲末/缩得小）→ 自然放开。
    {
        const pl = &app.playlist;
        const nav = pl.nav_active or ui.active_id == 8;
        // 幽灵游标（PAT 无锚）不跟随：否则视角会追着第一小节的幻影跑
        const ghost = !app.sel.song_mode and app.patOriginClip() == null;
        if (pl.follow_playhead and app.playing and !nav and !ghost) {
            const cur_px: f32 = app.cursorDisplay(true) * @as(f32, @floatFromInt(util.piano_step_w)); // 平滑小数步（同游标绘制）
            // 锚点口径 = **内容区（网格区）**（用户确认以网格区为准）
            const off_screen: f32 = util.follow_anchor_frac * @as(f32, @floatFromInt(view_w));
            const vcw_f: f32 = @as(f32, @floatFromInt(view_w)) / pl.zoom;
            const vcw_i: i32 = @max(1, @as(i32, @intFromFloat(vcw_f)));
            // **软锚定**（用户拍板）：行程有余量 → 锚点；余量耗尽 → 就势放开
            // （scroll 钳在行程端，游标从锚点处自然向右漂移——在钳制发生的瞬间
            // 游标恰好位于锚点，所以过渡是连续的、不跳变）。
            // 行程 = 时间轴（全曲 + 3 小节留白）——旧“手动延长”已随新设计废除。
            const follow_span: i32 = content_span;
            const target = util.followTargetScrollX(cur_px, view_w, pl.zoom, off_screen, follow_span);
            pl.scroll_x = Ui.clampScrollToSpan(util.followGlide(pl.scroll_x, target, app.frame_dt_ns), vcw_i, follow_span);
        }
    }

    // 纵向 minimap（与横向同一套 MiniBlock，轴换 90°）：每个片段 = 其所在行的一小条；
    // 条在滑块列内的**横向**位置 = 该片段在曲长里的时间位置（同横向里“轨道位置”的角色）
    var mini_vbuf: [256]Ui.MiniBlock = undefined;
    var nmini_v: usize = 0;
    {
        const tden: f32 = @floatFromInt(@max(1, max_end));
        // 内容 = **Part**（音频 Part 用波形色）
        for (app.parts.items) |pt0| {
            if (nmini_v >= mini_vbuf.len) break;
            const row0 = app.trackRowByUid(pt0.track_uid) orelse continue;
            const pos64: i64 = @as(i64, @intCast(row0)) * track_h;
            if (pos64 > std.math.maxInt(i32)) continue;
            mini_vbuf[nmini_v] = .{
                .pos = @intCast(pos64),
                .len = track_h,
                .kind = .note,
                .y = std.math.clamp(@as(f32, @floatFromInt(pt0.start)) / tden, 0, 1),
                .color = if (pt0.kind == .audio) ui.theme.waveform else patternColor(0),
            };
            nmini_v += 1;
        }
        // 旧片段（历史兼容）
        for (app.clips.items) |c| {
            if (nmini_v >= mini_vbuf.len) break;
            if (c.track < 0) continue;
            const pos64: i64 = @as(i64, c.track) * track_h; // 防御：越界轨道跳过（i32 溢出）
            if (pos64 > std.math.maxInt(i32)) continue;
            mini_vbuf[nmini_v] = .{
                .pos = @intCast(pos64),
                .len = track_h,
                .kind = .note,
                .y = std.math.clamp(@as(f32, @floatFromInt(c.start)) / tden, 0, 1),
                .color = patternColor(c.pattern),
            };
            nmini_v += 1;
        }
    }
    _ = ui.scrollbarVExt(9, sb_x, tracks_y, ruler_h, tracks_h, &app.playlist.scroll, map_rows * track_h, tracks_h, map_rows < util.overhang_map_limit, mini_vbuf[0..nmini_v]);

    // ── 编辑快捷键执行（线性化：只有 Part）──
    // Del：删除选中 Part；Ctrl+A：全选；Ctrl+C/V：Part 剪贴板（粘贴到鼠标位置，轨道保持）。
    blk: {
        if (app.pending_edit_op) |op| {
            switch (op) {
                .delete_selected => {
                    var del_n: usize = 0;
                    var di: usize = app.parts.items.len;
                    while (di > 0) {
                        di -= 1;
                        if (app.parts.items[di].selected) {
                            if (app.removePart(di)) del_n += 1;
                        }
                    }
                    if (del_n > 0) {
                        app.setToastWith("已删除 {d} 个 Part", .{del_n});
                        app.commitHistory("删除 Part");
                        app.pending_edit_op = null;
                        break :blk;
                    }
                },
                .toggle_mute => {
                    var n: usize = 0;
                    for (app.parts.items) |*ptm| {
                        if (!ptm.selected) continue;
                        ptm.muted = !ptm.muted;
                        n += 1;
                    }
                    if (n > 0) {
                        app.dirty = true;
                        app.setToastWith("已切换 {d} 个 Part 的静音", .{n});
                        app.commitHistory("Part 静音");
                    }
                },
                .select_all => {
                    var n: usize = 0;
                    for (app.parts.items) |*pts| {
                        pts.selected = true;
                        n += 1;
                    }
                    if (n > 0) app.setToastWith("已全选 {d} 个 Part", .{n});
                },
                .copy => {
                    const np = app.copySelectedParts();
                    if (np > 0) {
                        app.setToastWith("已复制 {d} 个 Part", .{np});
                        app.pending_edit_op = null;
                        break :blk;
                    }
                },
                .cut => {
                    const np = app.copySelectedParts();
                    if (np > 0) {
                        var di: usize = app.parts.items.len;
                        while (di > 0) {
                            di -= 1;
                            if (app.parts.items[di].selected) _ = app.removePart(di);
                        }
                        app.setToastWith("已剪切 {d} 个 Part", .{np});
                        app.commitHistory("剪切 Part");
                    }
                },
                .paste => {
                    const np = app.pasteParts(snap_step);
                    if (np > 0) {
                        app.setToastWith("已粘贴 {d} 个 Part", .{np});
                        app.commitHistory("粘贴 Part");
                        app.pending_edit_op = null;
                        break :blk;
                    }
                },
                else => {},
            }
            app.pending_edit_op = null;
        }

        // ── **自动化面板（v0 原型）**：与钢琴窗底部**同一套布局**（`docs/automation.md` §九）──
        // 横向只覆盖**播放列表主区**（行头列 + 剪辑区），不压左侧样式栏/右侧历史栏；
        // 行头列位置放**目标切换按钮**（对应钢琴窗的 力度/声像 toggle2）。
        if (auto_h >= 48) {
            const ay = lay.panel_y;
            const panel_w = @max(1, x + w - lane_x); // 自动化区没有滚动条 → 铺到窗口右沿

            // ── **共用外壳**（底色/顶线/分隔线/竖向网格/播放游标）——与钢琴窗编辑区同一份代码 ──
            const cur_steps: f32 = app.cursorDisplay(true);
            const ghost = !app.sel.song_mode and app.patOriginClip() == null;
            view_lane.drawShell(ui, .{
                .x = main_x,
                .y = ay,
                .w = @max(1, x + w - main_x),
                .h = auto_h,
                .lane_x = lane_x,
                .step_w = @floatFromInt(util.piano_step_w),
                .zoom = app.playlist.zoom,
                .scroll_x = app.playlist.scroll_x,
                .bar_steps = app.steps_per_bar,
                .beat_steps = @max(1, @divTrunc(app.steps_per_bar, 4)),
                .snap_steps = model.snapSteps(app.playlist.snap),
                .cursor_step = if (ghost) null else cur_steps,
                .playing = app.playing,
            });

            // 横向值参考线：与钢琴窗**同一个函数**（1/8 等分；中线只画一次、正好在 50%）
            view_lane.drawValueGrid(ui, .{ .x = lane_x, .y = ay, .w = panel_w, .h = auto_h }, auto_h >= 64);

            // 行头列顶部两行：单位按钮 + 当前点数值（与钢琴窗同一份代码）
            const cur_lane = app.autoCurve() orelse return;
            const hh = view_lane.drawValueHeader(ui, cur_lane, main_x, ay, util.piano_header_w);
            if (hh.value_clicked) {
                if (cur_lane.sel_idx) |si| {
                    var vb: [24]u8 = undefined;
                    const pre = view_lane.formatValue(cur_lane.display_unit, cur_lane.points.items[si].value, &vb);
                    app.beginEditAutomationValue(-1, si, pre, hh.rect.x, hh.rect.y, hh.rect.w);
                }
            }
            // ── 行头列：**曲线列表**（显示曲线名）──
            // 左键 = 选中编辑；双击 = 重命名；右键 = 菜单（重命名 / 删除曲线）
            {
                const n = @min(app.auto_curves.items.len, 32);
                var names: [32][24]u8 = undefined;
                var shown: [32][]const u8 = undefined;
                var entries: [32]view_lane.ListEntry = undefined;
                for (0..n) |k| {
                    const lc = &app.auto_curves.items[k];
                    shown[k] = lc.name(&names[k]);
                    entries[k] = .{ .text = shown[k], .active = app.auto_sel == lc.id };
                }
                if (n == 0) {
                    entries[0] = .{ .text = "（点下方轨道右键 → 自动化…）", .active = false };
                }
                const list = if (n == 0) entries[0..1] else entries[0..n];
                const lh = view_lane.drawList(ui, main_x, ay, auto_h, util.piano_header_w, 40, &app.auto_list_scroll, list);
                if (n > 0) {
                    if (lh.index) |hi| {
                        if (hi < n) app.auto_sel = app.auto_curves.items[hi].id;
                    }
                    if (lh.dbl) |hi| {
                        if (hi < n) {
                            const cid = app.auto_curves.items[hi].id;
                            app.beginRenameAutoCurve(cid, main_x + 4, ay + 44 + 18, util.piano_header_w);
                        }
                    }
                    // 右键 → **菜单**（不是直接删）
                    if (lh.right) |hi| {
                        if (hi < n) {
                            app.curve_menu = .{
                                .open = true,
                                .just_opened = true,
                                .x = ui.mouse_x,
                                .y = ui.mouse_y,
                                .curve_id = app.auto_curves.items[hi].id,
                            };
                        }
                    }
                }
            }

            // ── 曲线行右键菜单（重命名 / 删除曲线）──
            if (app.curve_menu.open) {
                const items = [_][]const u8{ "重命名", "删除曲线" };
                const en = [_]bool{ true, true };
                const bounds: @import("ui.zig").Rect = .{ .x = main_x, .y = ay, .w = @max(1, x + w - main_x), .h = auto_h };
                if (util.menuPanel(ui, &app.curve_menu.x, &app.curve_menu.y, &app.curve_menu.open, app.curve_menu.just_opened, .{ .cursor = {} }, bounds, &items, 110, &en)) |ci| {
                    const cid = app.curve_menu.curve_id;
                    switch (ci) {
                        0 => app.beginRenameAutoCurve(cid, main_x + 4, ay + 44 + 18, util.piano_header_w),
                        else => {
                            if (app.bindingCountOfCurve(cid) > 1) {
                                app.struct_del_req = .{ .auto_curve = cid };
                                app.modal = .delete_auto_curve;
                                app.modal_choice = null;
                            } else if (app.removeAutoCurve(cid)) {
                                app.setToast("已删除曲线");
                            }
                        },
                    }
                }
                app.curve_menu.just_opened = false;
            }

            // 值轨本体（内容层）：与剪辑区同一横坐标映射。
            // ⚠️ **必须在这里重新解析曲线指针**：上面可能删过曲线（`removeAutoCurve` 会搬移/释放
            // 仓库内存），沿用旧指针 = use-after-free（实测：右键删曲线后崩溃在 `view_lane.draw`）。
            const draw_lane = app.autoCurve() orelse return;
            view_lane.draw(ui, draw_lane, lane_x, ay, panel_w, auto_h, @floatFromInt(util.piano_step_w), app.steps_per_bar, app.playlist.scroll_x, app.playlist.zoom, app.allocator);
        }
        // 吸附网格下拉（在**全部内容之后** → 绘制在最上层）
        if (app.playlist.snap_menu_open and snap_btn_x + 40 < x + w - 24) {
            _ = util.snapSelectorMenu(ui, snap_btn_x, y + util.title_h, &app.playlist.snap, &app.playlist.snap_menu_open, snap_clicked);
        }
    }
}

test "playlist: hitAt——落点换算（轨道行/吸附/缩放/滚动；区域外 null）" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.playlist.geom = .{ .lane_x = 100, .tracks_y = 50, .view_w = 400, .tracks_h = 300, .track_h = 24 };
    app.playlist.zoom = 1.0;
    app.playlist.scroll = 0;
    app.playlist.scroll_x = 0;
    app.playlist.snap = 11; // 1/96 → snapSteps = 1（不吸附，便于精确断言）

    // 轨道行：第 2 行（0 起）→ py = 50 + 24*2 + 10
    const h = hitAt(&app, 100 + 5 * 5, 50 + 24 * 2 + 10).?;
    try std.testing.expectEqual(@as(i32, 2), h.track);
    try std.testing.expectEqual(@as(i32, 5), h.step); // 每步 5px：x 偏移 25px → 第 5 步

    // 纵向滚动：滚过 1 行 → 同一个 py 命中第 3 行
    app.playlist.scroll = 24;
    try std.testing.expectEqual(@as(i32, 3), hitAt(&app, 100, 50 + 24 * 2 + 10).?.track);
    app.playlist.scroll = 0;

    // 横向滚动 + 缩放：scroll_x=10 步、zoom=2 → 屏幕 25px = 内容 12.5px = 2.5 步
    app.playlist.scroll_x = 10 * 5;
    app.playlist.zoom = 2.0;
    try std.testing.expectEqual(@as(i32, 12), hitAt(&app, 100 + 25, 60).?.step);
    app.playlist.zoom = 1.0;
    app.playlist.scroll_x = 0;

    // 吸附：1/4（24 步）→ 第 13 步吸到 24
    app.playlist.snap = 2;
    try std.testing.expectEqual(@as(i32, 24), hitAt(&app, 100 + 13 * 5, 60).?.step);
    app.playlist.snap = 0;

    // 区域外：轨道名列 / 标题 / 下方空白
    try std.testing.expect(hitAt(&app, 90, 60) == null); // lane_x 左侧
    try std.testing.expect(hitAt(&app, 120, 40) == null); // tracks_y 上方
    try std.testing.expect(hitAt(&app, 120, 50 + 300 + 1) == null); // tracks_h 下方
    try std.testing.expect(hitAt(&app, 100 + 400, 60) == null); // view_w 右侧
}
