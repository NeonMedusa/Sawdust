//! 视图共享工具：命中检测、滚轮增量、常量。
//!
//! 这些是所有视图（播放列表/钢琴卷帘/机架/面板）都要用的东西，
//! 单独成模块避免视图之间互相 import。

const Ui = @import("ui.zig").Ui;
const Theme = @import("ui.zig").Theme;
const r_mod = @import("render.zig");

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

/// 网格分层：步线 / 拍线 / 小节线（用于着色与粗细）
pub const GridLevel = enum { step, beat, bar };

/// 计算某**步**对应的网格层级（U=96 对齐；拍线由分母决定）
pub fn gridLevel(step: i32, steps_per_bar: i32, beat_steps: i32) GridLevel {
    if (steps_per_bar > 0 and @mod(step, steps_per_bar) == 0) return .bar;
    if (beat_steps > 0 and @mod(step, beat_steps) == 0) return .beat;
    return .step;
}

/// 通用时间轴网格绘制（播放列表/钢琴卷帘共用）。
/// - `scroll_x`/`zoom`：与各自视图一致的内容坐标与缩放；
/// - `step_w`：一步的**内容像素宽**（**浮点**——如播放列表 80/96≈0.833，
///   整数会被截断为 0 导致网格与内容错位）；
/// - `steps_per_bar`/`beat_steps`：U=96 下的每小节/拍步数；
/// - 细小缩放（步宽 < 3px）时只画小节线（避免“实心墙”且限制迭代量）；
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
) void {
    if (steps_per_bar <= 0 or step_w <= 0) return;
    const view_w = clip_w;
    const step_ws: f32 = step_w * zoom; // 屏幕上的步宽
    const bar_steps: i32 = steps_per_bar;
    const scroll_s: f32 = @as(f32, @floatFromInt(scroll_x)) * zoom;

    const saved = ren.pushClip(clip_x, y, clip_w, h);
    defer ren.popClip(saved);

    if (step_ws >= 3.0) {
        // 全网格：逐 step（迭代量 = 视宽/步宽 ≤ 视宽/3）
        var st: i32 = @as(i32, @intFromFloat(@as(f32, @floatFromInt(scroll_x)) / step_w));
        st += 1;
        while (true) : (st += 1) {
            const gx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(st)) * step_ws - scroll_s));
            if (gx > clip_x + view_w) break;
            switch (gridLevel(st, bar_steps, beat_steps)) {
                .bar => ren.fillRect(gx, y, 2, h, theme.panel_border),
                .beat => ren.vline(gx, y, h, theme.grid_beat),
                .step => ren.vline(gx, y, h, theme.grid),
            }
        }
    } else {
        // 细小缩放：只画小节线（按小节步进 → 迭代量 = 视宽/小节宽）
        const bar_ws: f32 = step_w * @as(f32, @floatFromInt(bar_steps)) * zoom;
        if (bar_ws <= 0) return;
        var bar_i: i32 = @as(i32, @intFromFloat(@as(f32, @floatFromInt(scroll_x)) / (step_w * @as(f32, @floatFromInt(bar_steps)))));
        bar_i += 1;
        while (true) : (bar_i += 1) {
            const bx = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar_i - 1)) * bar_ws - scroll_s));
            if (bx > clip_x + view_w) break;
            ren.fillRect(bx, y, 2, h, theme.panel_border);
        }
    }
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
