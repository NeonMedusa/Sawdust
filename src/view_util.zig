//! 视图共享工具：命中检测、滚轮增量、常量。
//!
//! 这些是所有视图（播放列表/钢琴卷帘/机架/面板）都要用的东西，
//! 单独成模块避免视图之间互相 import。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const Theme = @import("ui.zig").Theme;
const r_mod = @import("render.zig");
const model = @import("model.zig");

// ── 布局常量 ──
pub const toolbar_h: i32 = 40; // 顶部工具栏高度
pub const status_h: i32 = 26; // 底部状态栏高度
pub const splitter_w: i32 = 4; // 分隔条宽度
pub const min_pane_w: i32 = 100; // 每栏最小宽度
pub const title_h: i32 = 24; // 面板标题栏高度

// ── 钢琴卷帘常量 ──
/// 每步宽（像素）——步的单位为 1/96 全音符（`model.units_per_whole`）。
/// 4/4 时每小节 96 步；为保证视觉密度与手感，默认缩放下调到 5px/步
/// （效果 ≈ 旧值 20px × 每小节 16 步；缩放范围 0.2-8 仍然可用）。
pub const piano_step_w: i32 = 5;
pub const piano_header_w: i32 = 90; // 琴键列宽（与播放列表轨道列对齐）
/// 每小节步数（**默认 4/4**；实际用 `App.steps_per_bar`）
pub const piano_steps_per_bar: i32 = 96;
pub const piano_key_h_min: i32 = 6; // 音高行高范围（□ 缩放）
pub const piano_key_h_max: i32 = 40;

// ── 播放列表常量 ──
pub const track_h_min: i32 = 16; // 轨道行高范围（□ 缩放）
pub const track_h_max: i32 = 120;

// ── 通道机架（浮动窗口）常量 ──
pub const rack_title_h: i32 = 22; // 标题栏高
pub const rack_row_h: i32 = 30; // 每行高
pub const rack_mute_w: i32 = 20; // 静音开关尺寸
pub const rack_knob_size: i32 = 20; // 旋钮尺寸
pub const rack_mix_w: i32 = 26; // 混音通道列宽
pub const rack_name_w: i32 = 150; // 名称列宽
pub const rack_add_h: i32 = 24; // 添加按钮高
pub const menu_item_h: i32 = 20; // 下拉菜单项高
pub const rack_min_w: i32 = 360;
pub const rack_min_h: i32 = 120;

/// Ctrl+滑轮横向缩放的每格系数（>1；约 6 格翻倍，手感平滑）
pub const wheel_zoom_factor: f32 = 1.12;

/// 直接坐标命中（不受 ui.input_blocked 影响；弹窗/浮动窗口用）
pub fn inRect(mx: i32, my: i32, x: i32, y: i32, w: i32, h: i32) bool {
    return mx >= x and mx < x + w and my >= y and my < y + h;
}

/// 直接坐标命中 + 尊重 input_blocked（浮动窗口内部控件用：
/// 当菜单展开（模态）时，窗口自身的其它控件也要让位）
pub fn hitUI(ui: *Ui, x: i32, y: i32, w: i32, h: i32) bool {
    return !ui.input_blocked and inRect(ui.mouse_x, ui.mouse_y, x, y, w, h);
}

// ── 时间轴网格（播放列表与钢琴卷帘共用）──

/// 通用时间轴网格绘制（播放列表/钢琴卷帘共用）。
///
/// **分层**（各自独立判断是否太密，绘制顺序 = **细 → 粗**，后画覆盖先画）：
/// 1. 网格层：当前量化档位（`snap_steps`；最暗、1px）；
/// 2. 拍线（`beat_steps`；亮一档、1px）；
/// 3. 小节线（`steps_per_bar`；最亮、常显）。
/// 当前三层都是 1px，纯靠明暗区分；若想加回粗线，把 `drawLayer` 的
/// `thick` 参数（第 3 层现在是 1）改成 2 即可。
///
/// **为什么不“网格线遇拍/小节位置就跳过”**：那样当拍线层因太密被隐藏时，
/// 拍位置上的网格线也没人画——会出现“洞”。覆盖式顺序则天然正确：
/// 哪层画了就以哪层为准，哪层隐藏也不留空缺。
///
/// - `scroll_x`/`zoom`：与各自视图一致的内容坐标与缩放；
/// - `step_w`：一步的**内容像素宽**（**浮点**——如播放列表 80/96≈0.833，
///   整数会被截断为 0 导致网格与内容错位）；
/// - `steps_per_bar`/`beat_steps`：U=96 下的每小节/拍步数；
/// - `snap_steps`：量化/吸附网格的格子大小（步；1 = 1/96 最细档——照常显示，受密度门槛约束）；
/// - 密度门槛（屏上间距，低于则跳过该层）：网格 4px、拍线 6px、小节线 3px；
/// - 自动裁剪到 [clip_x, clip_x+clip_w]（网格不会画到琴键列/轨道名列上）。
pub fn drawTimelineGrid(
    ren: *r_mod.Renderer,
    theme: *const Theme,
    clip_x: i32,
    clip_w: i32,
    y: i32,
    h: i32,
    lane_x: i32,
    scroll_x: i32,
    zoom: f32,
    step_w: f32,
    steps_per_bar: i32,
    beat_steps: i32,
    snap_steps: i32,
) void {
    if (steps_per_bar <= 0 or step_w <= 0) return;
    const view_w = clip_w;
    const step_ws: f32 = step_w * zoom; // 屏幕上的步宽
    const scroll_s: f32 = @as(f32, @floatFromInt(scroll_x)) * zoom;
    // 已滚过的步数（**内容**单位：内容滚动量 / 内容步宽——两者同为内容坐标）
    const scroll_steps: i32 = @intFromFloat(@as(f32, @floatFromInt(scroll_x)) / step_w);

    const saved = ren.pushClip(clip_x, y, clip_w, h);
    defer ren.popClip(saved);

    // 画某一层：`every` = 每几步一条线（<=0 = 不画）；
    // `min_px` = 密度门槛（屏上间距低于它 → 该层整体跳过）；
    // `thick`/`col` = 线宽与颜色。从滚动位置之后的第一条线开始（迭代量 ≤ 视宽/间距）。
    const drawLayer = struct {
        fn f(
            r: *r_mod.Renderer,
            clip_x_: i32,
            view_w_: i32,
            lane_x_: i32,
            scroll_s_: f32,
            scroll_steps_: i32,
            step_ws_: f32,
            y_: i32,
            h_: i32,
            every: i32,
            min_px: f32,
            thick: i32,
            col: r_mod.Color,
        ) void {
            if (every <= 0) return;
            const ws = step_ws_ * @as(f32, @floatFromInt(every)); // 屏上间距
            if (ws < min_px) return;
            var k: i32 = @divFloor(@max(0, scroll_steps_), every) + 1;
            while (true) : (k += 1) {
                const gx = lane_x_ + @as(i32, @intFromFloat(@as(f32, @floatFromInt(k)) * ws - scroll_s_));
                if (gx > clip_x_ + view_w_) break;
                if (gx >= clip_x_ - thick + 1) r.fillRect(gx, y_, thick, h_, col);
            }
        }
    }.f;

    // 1) 网格层（= 当前量化档位；最暗、1px——1/96 时即“步线”）
    drawLayer(ren, clip_x, view_w, lane_x, scroll_s, scroll_steps, step_ws, y, h, snap_steps, 4.0, 1, theme.grid_snap);
    // 2) 拍线（亮一档、1px）
    drawLayer(ren, clip_x, view_w, lane_x, scroll_s, scroll_steps, step_ws, y, h, beat_steps, 6.0, 1, theme.grid_beat);
    // 3) 小节线（最亮、常显；当前 1px——纯靠明暗与拍/网格区分）
    drawLayer(ren, clip_x, view_w, lane_x, scroll_s, scroll_steps, step_ws, y, h, steps_per_bar, 3.0, 1, theme.grid_bar);
}

/// 网格选择器按钮文本（"网格 1/4 ▾"；`buf` 由调用方提供——栈上格式化）。
pub fn snapLabel(buf: []u8, snap: i32) []const u8 {
    const idx = std.math.clamp(snap, 0, @as(i32, @intCast(model.snap_denoms.len - 1)));
    return std.fmt.bufPrint(buf, "网格 1/{d} ▾", .{model.snap_denoms[@intCast(idx)]}) catch "网格 ▾";
}

/// 标题栏选择器按钮宽度（文本宽 + 内边距；供调用方定位相邻控件/可见性判断）
pub fn titleSelectorButtonWidth(ui: *Ui, label: []const u8) i32 {
    return @as(i32, @intFromFloat(ui.font.measure(label))) + 16;
}

/// 标题栏下拉选择器——按钮（网格/乐器共用：交互与视觉一致）。
/// `label`：按钮文本（由调用方生成）；`open`：展开状态（点击切换）。
/// 返回 true = 本帧点击了按钮（调用方用于屏蔽同帧交互 / 互斥关闭另一选单）。
/// **下拉内容由 `titleSelectorMenu` 绘制（在全部内容之后 → 最上层）**。
pub fn titleSelectorButton(ui: *Ui, btn_x: i32, y: i32, bar_h: i32, label: []const u8, open: *bool) bool {
    const btn_h: i32 = bar_h - 8;
    const btn_y = y + 4;
    const bw = titleSelectorButtonWidth(ui, label);
    const hovered = ui.hitRect(btn_x, btn_y, bw, btn_h);
    ui.renderer.fillRect(btn_x, btn_y, bw, btn_h, if (open.*) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.toolbar);
    ui.labelClipped(label, btn_x + 8, btn_y, bw - 12, ui.theme.text);
    if (hovered and ui.mouse_pressed) open.* = !open.*;
    return hovered and ui.mouse_pressed;
}

/// 吸附网格选择器按钮（= `titleSelectorButton` + 网格档位文本）
pub fn snapSelectorButton(ui: *Ui, btn_x: i32, y: i32, bar_h: i32, snap: *i32, open: *bool) bool {
    var buf: [24]u8 = undefined;
    return titleSelectorButton(ui, btn_x, y, bar_h, snapLabel(&buf, snap.*), open);
}

/// 标题栏下拉选择器——菜单（在**全部内容之后**调用 → 绘制在最上层）。
/// `items`：条目文本（空列表显示占位提示）；`selected`：选中下标（点击条目写入）；
/// `min_w`：最小宽度（如网格 96、乐器 170）；实际宽度还会按最长条目放宽；
/// `skip_close`：本帧刚点击了按钮（用于打开菜单）——**跳过“点外部关闭”判断**，
/// 否则同帧的点击会立刻把菜单关掉（实测 bug：菜单闪一下消失）。
/// 返回 true = 本帧点击了列表（调用方用它屏蔽同帧的其它交互）。
pub fn titleSelectorMenu(
    ui: *Ui,
    btn_x: i32,
    below_y: i32,
    items: []const []const u8,
    selected: *i32,
    open: *bool,
    skip_close: bool,
    min_w: i32,
) bool {
    if (!open.*) return false;
    var mw = min_w;
    for (items) |it| mw = @max(mw, titleSelectorButtonWidth(ui, it));
    const n: i32 = @intCast(items.len);
    const mh: i32 = @max(1, n) * menu_item_h + 4;
    const mx = btn_x;
    const my = below_y;
    ui.renderer.fillRect(mx, my, mw, mh, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, mw, mh, ui.theme.accent);
    if (n == 0) ui.label("（空）", mx + 10, my + 4, ui.theme.text_dim);
    var consumed = false;
    for (items, 0..) |it, ii| {
        const iy = my + 2 + @as(i32, @intCast(ii)) * menu_item_h;
        const ih = inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, mw - 2, menu_item_h);
        if (ih) ui.renderer.fillRect(mx + 1, iy, mw - 2, menu_item_h, ui.theme.item_hover);
        const sel = selected.* == @as(i32, @intCast(ii));
        ui.labelClipped(it, mx + 10, iy + 2, mw - 20, if (sel) ui.theme.accent else ui.theme.text);
        if (ih) consumed = true;
        if (ih and ui.mouse_pressed) {
            selected.* = @intCast(ii);
            open.* = false;
        }
    }
    // 点外部关闭（跳过“刚点按钮打开菜单”那一帧）
    if (!skip_close and ui.mouse_pressed and !inRect(ui.mouse_x, ui.mouse_y, mx, my, mw, mh)) {
        open.* = false;
    }
    return consumed;
}

/// 吸附网格下拉（= `titleSelectorMenu` + 网格档位条目 "1/N"）
pub fn snapSelectorMenu(ui: *Ui, btn_x: i32, below_y: i32, snap: *i32, open: *bool, skip_close: bool) bool {
    if (!open.*) return false;
    var bufs: [model.snap_denoms.len][16]u8 = undefined;
    var items: [model.snap_denoms.len][]const u8 = undefined;
    for (model.snap_denoms, 0..) |d, i| {
        items[i] = std.fmt.bufPrint(&bufs[i], "1/{d}", .{d}) catch "";
    }
    return titleSelectorMenu(ui, btn_x, below_y, &items, snap, open, skip_close, 96);
}

/// 滚轮增量 → 像素（24px/格）
pub fn scrollDelta(ui: *Ui) i32 {
    return ui.wheel * 24;
}

/// 播放游标（倒三角 + 贯穿内容区的竖线）。
/// `x`：游标位置（屏幕像素）；`ruler_y`/`ruler_h`：标尺行；`bottom_y`：竖线底端。
pub fn drawCursor(ui: *Ui, x: i32, ruler_y: i32, ruler_h: i32, bottom_y: i32, playing: bool) void {
    const col = if (playing) ui.theme.cursor_play else ui.theme.cursor_idle;
    // 竖线（贯穿内容区，先画在线下）
    if (bottom_y > ruler_y) ui.renderer.vline(x, ruler_y + ruler_h, bottom_y - ruler_y - ruler_h, col);
    // 倒三角（标尺顶部）
    const tri_w: i32 = 11;
    const tri_h: i32 = 9;
    var i: i32 = 0;
    while (i < tri_h) : (i += 1) {
        const half = @divTrunc(tri_w * (tri_h - 1 - i), tri_h * 2);
        ui.renderer.fillRect(x - half, ruler_y + i, half * 2 + 1, 1, col);
    }
}

// ── 测试 ──

/// 测试辅助：网格绘制到干净画布（4/4：每小节 96 步、每拍 24 步；lane_x = 0）。
fn gridTestRow(fb: *r_mod.Framebuffer, theme: *const Theme, snap_steps: i32, step_w: f32, zoom: f32) void {
    var ren = r_mod.Renderer.init(fb);
    @memset(fb.pixels, theme.bg);
    drawTimelineGrid(&ren, theme, 0, @intCast(fb.width), 0, @intCast(fb.height), 0, 0, zoom, step_w, 96, 24, snap_steps);
}

test "网格：只画所选档位（不再常显步线）；拍线/小节线常显" {
    var buf: [200 * 4]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 200, .height = 4 };
    const theme = Theme{};

    // 每步 1px；网格 1/96（每步）间距 1px < 4 → 网格层整层跳过
    gridTestRow(&fb, &theme, 1, 1.0, 1.0);
    try std.testing.expectEqual(theme.bg, buf[1]); // 步位置：无网格线（旧行为会常显）
    try std.testing.expectEqual(theme.grid_beat, buf[24]); // 拍线常显
    try std.testing.expectEqual(theme.grid_bar, buf[96]); // 小节线常显

    // 放大到每步 24px：网格 1/96 间距 24px ≥ 4 → 网格层画出（此时它 = 步线）
    gridTestRow(&fb, &theme, 1, 1.0, 24.0);
    try std.testing.expectEqual(theme.grid_snap, buf[24]); // step 1 → x=24
}

test "网格：与拍/小节线重合时显示粗层（覆盖式，无洞）" {
    var buf: [100 * 4]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 100, .height = 4 };
    const theme = Theme{};

    // 每步 0.5px；网格 1/4（24 步）与拍线完全重合
    gridTestRow(&fb, &theme, 24, 1.0, 0.5);
    try std.testing.expectEqual(theme.grid_beat, buf[12]); // step 24：拍线覆盖网格
    try std.testing.expectEqual(theme.grid_bar, buf[48]); // step 96：小节线覆盖
    try std.testing.expectEqual(theme.bg, buf[6]); // step 12：非网格点

    // 网格 1/8（12 步）：非拍位置也有网格线
    gridTestRow(&fb, &theme, 12, 1.0, 0.5);
    try std.testing.expectEqual(theme.grid_snap, buf[6]); // step 12：网格点（非拍）
    try std.testing.expectEqual(theme.grid_beat, buf[12]); // step 24：拍线覆盖
}

test "网格：拍线因太密隐藏时，拍位置上的网格线仍画（不留洞）" {
    var buf: [40 * 4]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 40, .height = 4 };
    const theme = Theme{};

    // 每步 0.1px：网格 1/2（48 步）间距 4.8px ≥ 4 → 画；
    // 拍线间距 2.4px < 6 → 整层跳过；小节线 9.6px ≥ 3 → 画。
    // step 48 是拍位置（拍线层没画）——网格线必须补上（若用“跳过”逻辑会是洞）。
    gridTestRow(&fb, &theme, 48, 1.0, 0.1);
    try std.testing.expectEqual(theme.grid_snap, buf[4]); // step 48 → x=4.8→4：网格线补上
    try std.testing.expectEqual(theme.grid_bar, buf[9]); // step 96 → x=9.6→9：小节线
}
