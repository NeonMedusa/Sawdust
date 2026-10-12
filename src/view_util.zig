//! 视图共享工具：命中检测、滚轮增量、常量。
//!
//! 这些是所有视图（播放列表/钢琴卷帘/机架/面板）都要用的东西，
//! 单独成模块避免视图之间互相 import。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const Theme = @import("ui.zig").Theme;
const r_mod = @import("render.zig");
const Rect = @import("ui.zig").Rect;
const model = @import("model.zig");

// ── 布局常量 ──
pub const toolbar_h: i32 = 40; // 顶部工具栏高度
pub const status_h: i32 = 26; // 底部状态栏高度
pub const splitter_w: i32 = 4; // 分隔条宽度
pub const min_pane_w: i32 = 100; // 每栏最小宽度
pub const title_h: i32 = 24; // 面板标题栏高度

/// 视图切换按钮（标题栏**最右侧**）：播放列表 ⇄ 钢琴卷帘。
/// `x` = 面板右缘；按钮右对齐。返回 true = 本帧被点击（调用方执行切换）。
/// 图标用**自绘双向箭头**（不依赖字体字形——`⇄` 在常见 UI 字体里缺失）。
pub fn viewSwitchButton(ui: *Ui, x: i32, y: i32, bar_h: i32) bool {
    const bw: i32 = bar_h - 8;
    const btn_x = x - bw - 4; // 右对齐
    const btn_y = y + 4;
    const hovered = ui.hitRect(btn_x, btn_y, bw, bw);
    ui.renderer.fillRect(btn_x, btn_y, bw, bw, if (hovered) ui.theme.item_hover else ui.theme.toolbar);
    // 双向箭头（上下两根带箭头的短横线；箭头头用斜线画）：
    // 上行 → 右箭头；下行 → 左箭头
    const col = ui.theme.text;
    const cx = btn_x + @divTrunc(bw, 2);
    const cy = btn_y + @divTrunc(bw, 2);
    const half: i32 = 5;
    const gap: i32 = 3;
    const ah: i32 = 3; // 箭头头张开幅度
    // 上行（y = cy-gap）：主体 + 右箭头头（向右张开的两条斜线）
    ui.renderer.hline(cx - half, cy - gap, half * 2, col);
    ui.renderer.line(cx + half, cy - gap, cx + half - ah, cy - gap - ah, col);
    ui.renderer.line(cx + half, cy - gap, cx + half - ah, cy - gap + ah, col);
    // 下行（y = cy+gap）：主体 + 左箭头头
    ui.renderer.hline(cx - half, cy + gap, half * 2, col);
    ui.renderer.line(cx - half, cy + gap, cx - half + ah, cy + gap - ah, col);
    ui.renderer.line(cx - half, cy + gap, cx - half + ah, cy + gap + ah, col);
    return hovered and ui.mouse_pressed;
}

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

// ── 下拉菜单（“按钮 → 菜单”的共享实现）──
//
// 动机：机架“+ 添加乐器”与调音台“+ 效果器”是同一套交互（按钮 → 下拉选类型），
// 却各写一份 → 两边各踩一次同样的坑（同帧关闭、菜单追随鼠标）。
// 共享实现 = 一次修对、以后不再各踩一遍。
//
// 为保持分层（app ↛ view_util），这里不定义状态结构体：
// 调用方在**自己的状态**里放四个字段（open/just_opened/x/y），传指针进来。

/// 菜单锚定方式
pub const MenuAnchor = union(enum) {
    /// 锚到按钮下方（下方放不下 → 向上展开）
    button: struct { x: i32, y: i32, w: i32, h: i32 },
    /// 跟随鼠标（位置在**开启那一帧快照后固定**——否则菜单会跟着鼠标跑，
    /// “钓竿上的胡萝卜”，永远点不到）
    cursor: void,
};

/// 帧首调用：清零“刚打开”标记（必须逐帧做，否则“点外部关闭”永久失效）
pub fn menuFrameBegin(just_opened: *bool) void {
    just_opened.* = false;
}

/// 下拉菜单的按钮：点击切换开/关；**开启那一帧**置 `just_opened`（供 menuPanel）。
pub fn menuButton(ui: *Ui, label: []const u8, x: i32, y: i32, w: i32, h: i32, open: *bool, just_opened: *bool) void {
    const hovered = hitUI(ui, x, y, w, h);
    ui.renderer.fillRect(x, y, w, h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
    ui.renderer.strokeRect(x, y, w, h, ui.theme.panel_border);
    const tw: i32 = @intFromFloat(ui.font.measure(label));
    ui.label(label, x + @divTrunc(w - tw, 2), y + @divTrunc(h - 10, 2), ui.theme.text);
    if (hovered and ui.mouse_pressed) {
        open.* = !open.*;
        if (open.*) just_opened.* = true; // 只在“开启”那一帧标记
    }
}

/// 菜单面板：位置快照（仅开启帧）、hover、点击、“点外部关闭”（跳过开启帧）。
/// - `mx`/`my`：菜单坐标状态（开启帧快照后固定）
/// - `open`：菜单开关（点外部/点条目时置 false）
/// - `bounds`：所在窗口矩形（越界翻转/钳制）
/// - `enabled`：条目可用性（null = 全可用；禁用项变暗且不可点）
/// 返回被点击的条目下标（null = 无）。
pub fn menuPanel(
    ui: *Ui,
    mx: *i32,
    my: *i32,
    open: *bool,
    just_opened: bool,
    anchor: MenuAnchor,
    bounds: Rect,
    items: []const []const u8,
    item_w: i32,
    enabled: ?[]const bool,
) ?usize {
    const count: i32 = @intCast(items.len);
    const mh: i32 = count * menu_item_h + 4;
    if (just_opened) {
        switch (anchor) {
            .button => |b| {
                mx.* = b.x;
                my.* = b.y + b.h;
                // 下方放不下 → 向上展开
                if (my.* + mh > bounds.y + bounds.h) my.* = @max(bounds.y, b.y - mh);
            },
            .cursor => {
                mx.* = ui.mouse_x;
                my.* = ui.mouse_y + 6;
                if (my.* + mh > bounds.y + bounds.h) my.* = @max(bounds.y, ui.mouse_y - mh - 6);
            },
        }
        // 右/下越界兜底
        mx.* = std.math.clamp(mx.*, bounds.x, @max(bounds.x, bounds.x + bounds.w - item_w));
        my.* = std.math.clamp(my.*, bounds.y, @max(bounds.y, bounds.y + bounds.h - mh));
    }

    const pmx = mx.*;
    const pmy = my.*;
    ui.renderer.fillRect(pmx, pmy, item_w, mh, ui.theme.panel);
    ui.renderer.strokeRect(pmx, pmy, item_w, mh, ui.theme.accent);

    var clicked: ?usize = null;
    var inside_any = false;
    for (items, 0..) |item, i| {
        const iy = pmy + 2 + @as(i32, @intCast(i)) * menu_item_h;
        const ih = inRect(ui.mouse_x, ui.mouse_y, pmx + 1, iy, item_w - 2, menu_item_h);
        const ok = enabled == null or enabled.?[i];
        if (ih) {
            inside_any = true;
            if (ok) ui.renderer.fillRect(pmx + 1, iy, item_w - 2, menu_item_h, ui.theme.item_hover);
        }
        ui.labelClipped(item, pmx + 8, iy + 2, item_w - 16, if (!ok) ui.theme.text_dim else if (ih) ui.theme.accent else ui.theme.text);
        if (ih and ok and ui.mouse_pressed) clicked = i;
    }
    // 点外部关闭（**跳过“刚打开”那一帧**：同帧点击会立刻把它关掉，
    // 实测 bug：菜单闪一下消失）
    if (ui.mouse_pressed and !inside_any and !just_opened and clicked == null) {
        open.* = false;
    }
    if (clicked != null) open.* = false;
    return clicked;
}
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

/// 网格选择器按钮文本（"网格 1/4"；`buf` 由调用方提供——栈上格式化）。
/// 注：**不再拼 `▾`**——字体缺该码点（U+25BE）会显示为空心方块豆腐块；
/// 下拉箭头由 `menuArrow` 自绘（见下）。
pub fn snapLabel(buf: []u8, snap: i32) []const u8 {
    const idx = std.math.clamp(snap, 0, @as(i32, @intCast(model.snap_denoms.len - 1)));
    return std.fmt.bufPrint(buf, "网格 1/{d}", .{model.snap_denoms[@intCast(idx)]}) catch "网格";
}

// ── 自绘下拉箭头（替代字体缺字的 `▾`）──

/// 箭头尺寸（宽 × 高；实心向下小三角）
pub const menu_arrow_w: i32 = 7;
pub const menu_arrow_h: i32 = 4;

/// 下拉小三角（自绘）。字体缺 `▾`（U+25BE）——直接拼进文本会渲染成
/// 空心方块（实测；长期存在的观感问题）。所有“下拉”UI 统一用它：
/// `(x, y)` = 三角包围盒**左上角**（行宽 7/5/3/1，逐行收窄）。
pub fn menuArrow(ui: *Ui, x: i32, y: i32, color: u32) void {
    var i: i32 = 0;
    while (i < menu_arrow_h) : (i += 1) {
        const w = menu_arrow_w - i * 2;
        if (w <= 0) break;
        ui.renderer.fillRect(x + i, y + i, w, 1, color);
    }
}

// ── 文件名式**中略**（省略中间、保留两边）──

/// 屏幕位移 → **内容像素**位移（中键拖动 1:1 用）：
/// `scroll_x` 系的滚动量存的是内容像素（屏幕 = 内容 × zoom），
/// 所以屏幕上移 1px = 内容上 1/zoom。不换算时拖动比例会差 zoom 倍
/// （实测 bug：缩放到非 1 后中键拖动“不跟手”）。
/// 注：内容像素是整数——高倍缩放（zoom 大）下水平拖动会有
/// ⌈zoom⌉ 像素级颗粒；zoom=1 时严格 1:1。
pub fn screenToContentPx(dx: i32, zoom: f32) i32 {
    const z = @max(0.01, zoom);
    return @intFromFloat(@round(@as(f32, @floatFromInt(dx)) / z));
}

/// 中略拆分结果：保留头部 `head` 码点 + 省略号 + 尾部 `tail` 码点
pub const EllipsisSplit = struct { head: usize, tail: usize };

/// 中略拆分纯逻辑：`widths` = 每个码点宽度、`ellipsis_w` = 省略号宽度、
/// `max_px` = 可用宽度。
/// - 全文放得下 → `{ .head = n, .tail = 0 }`（不省略的记号）；
/// - 否则在“两端保留、中间省略”下选**保留最多**的拆分（头略多：
///   `Acous…Drum` 风格）；
/// - 连最小形式（1 码点 + … + 1 码点）都放不下 → null（调用方不画）。
pub fn ellipsisSplit(widths: []const f32, ellipsis_w: f32, max_px: f32) ?EllipsisSplit {
    const n = widths.len;
    if (n == 0) return null;
    var total: f32 = 0;
    for (widths) |w| total += w;
    if (total <= max_px) return .{ .head = n, .tail = 0 };
    if (n < 2) return null;
    var k: usize = n - 1;
    while (k >= 2) : (k -= 1) {
        const head = (k + 1) / 2;
        const tail = k - head;
        var hw: f32 = 0;
        for (widths[0..head]) |w| hw += w;
        var tw: f32 = 0;
        for (widths[n - tail ..]) |w| tw += w;
        if (hw + ellipsis_w + tw <= max_px) return .{ .head = head, .tail = tail };
    }
    return null;
}

/// 文本超宽时**中略**（`docs/drumkit.md` §6）：写进 `buf` 返回切片（需
/// 容纳全文 + 省略号）；放得下原文时**直接返回 `text`**（不拷贝、不用 buf）；
/// 连最小形式都放不下 → 返回空（不画）。
pub fn middleEllipsis(ui: *Ui, buf: []u8, text: []const u8, max_px: i32) []const u8 {
    if (text.len == 0 or max_px <= 0) return "";
    if (ui.font.measure(text) <= @as(f32, @floatFromInt(max_px))) return text;

    // 码点边界与宽度（最多 128 码点——键列标签都是短文本；超出则截断看待）
    var offs: [129]usize = undefined;
    var wid: [128]f32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < 128) {
        const cl = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const j = @min(i + cl, text.len);
        const cp = std.unicode.utf8Decode(text[i..j]) catch 0xFFFD;
        offs[n] = i;
        wid[n] = if (ui.font.getGlyph(cp)) |g| g.advance else ui.font.size_px * 0.5;
        n += 1;
        i = j;
    }
    offs[n] = text.len;
    const sp = ellipsisSplit(wid[0..n], ui.font.measure("…"), @as(f32, @floatFromInt(max_px))) orelse return "";
    if (sp.tail == 0) return text[0..offs[sp.head]]; // 放得下（与上面等价的兼底）
    const hb = offs[sp.head];
    const ts = offs[n - sp.tail];
    const tb = text.len - ts;
    if (hb + 3 + tb > buf.len) return "";
    @memcpy(buf[0..hb], text[0..hb]);
    @memcpy(buf[hb..][0..3], "…");
    @memcpy(buf[hb + 3 ..][0..tb], text[ts..]);
    return buf[0 .. hb + 3 + tb];
}

/// 标题栏选择器按钮宽度（文本宽 + 左右内边距 + **自绘箭头**空间；
/// 供调用方定位相邻控件/可见性判断）。
/// 注：文本宽**向上取整 +1**——`labelClipped` 内部是 f32 比较，
/// 袪截断（intFromFloat）会让最后一字形差零点几像素被判越界丢掉
/// （实测 bug：“网格 1/8”只显示到 “网格 1/”）。
pub fn titleSelectorButtonWidth(ui: *Ui, label: []const u8) i32 {
    const tw = titleSelectorTextW(ui, label);
    return tw + 8 + 5 + menu_arrow_w + 6;
}

/// 选择器按钮文本宽（向上取整 +1 的安全余量；见 `titleSelectorButtonWidth` 注释）
fn titleSelectorTextW(ui: *Ui, label: []const u8) i32 {
    return @as(i32, @intFromFloat(@ceil(ui.font.measure(label)))) + 1;
}

/// 标题栏下拉选择器——按钮（网格/乐器共用：交互与视觉一致）。
/// `label`：按钮文本（由调用方生成）；`open`：展开状态（点击切换）。
/// 返回 true = 本帧点击了按钮（调用方用于屏蔽同帧交互 / 互斥关闭另一选单）。
/// **下拉内容由 `titleSelectorMenu` 绘制（在全部内容之后 → 最上层）**。
pub fn titleSelectorButton(ui: *Ui, btn_x: i32, y: i32, bar_h: i32, label: []const u8, open: *bool) bool {
    const btn_h: i32 = bar_h - 8;
    const btn_y = y + 4;
    const bw = titleSelectorButtonWidth(ui, label);
    const tw = titleSelectorTextW(ui, label);
    const hovered = ui.hitRect(btn_x, btn_y, bw, btn_h);
    ui.renderer.fillRect(btn_x, btn_y, bw, btn_h, if (open.*) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.toolbar);
    ui.labelClipped(label, btn_x + 8, btn_y, tw, ui.theme.text);
    // 自绘下拉箭头（字体缺 `▾`；见 menuArrow 注释）
    menuArrow(ui, btn_x + 8 + tw + 5, btn_y + @divTrunc(btn_h - menu_arrow_h, 2), ui.theme.text_dim);
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
/// 三角**矮小**（高 ≈ 标尺行一半、宽 11px）——与竖线是否相接不重要。
pub fn drawCursor(ui: *Ui, x: i32, ruler_y: i32, ruler_h: i32, bottom_y: i32, playing: bool) void {
    const col = if (playing) ui.theme.cursor_play else ui.theme.cursor_idle;
    // 竖线（贯穿内容区，先画在线下）
    if (bottom_y > ruler_y) ui.renderer.vline(x, ruler_y + ruler_h, bottom_y - ruler_y - ruler_h, col);
    // 倒三角（标尺行内，矮小）：宽 14px、高 = 标尺行一半（最小 5px）
    const tri_w: i32 = 14;
    const tri_h: i32 = @max(5, @divTrunc(ruler_h, 2));
    var i: i32 = 0;
    while (i < tri_h) : (i += 1) {
        // 线性收敛：i=0 最宽，i=tri_h-1 收为 1px（尖端）
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

test "中略：放得下不省略、超宽省略中间保留两边、太窄返回 null" {
    const w = [_]f32{10} ** 10; // 10 个码点、每个宽 10
    const ell: f32 = 12;

    // 放得下 → 不省略（记号：head = n、tail = 0）
    try std.testing.expectEqual(EllipsisSplit{ .head = 10, .tail = 0 }, ellipsisSplit(&w, ell, 150).?);

    // 宽 60：k=4 → 20+12+20=52≤60；k=5 → 30+12+20=62>60 → 取 k=4（头 2 尾 2）
    try std.testing.expectEqual(EllipsisSplit{ .head = 2, .tail = 2 }, ellipsisSplit(&w, ell, 60).?);
    // 头略多（与 `Acous…Drum` 风格一致）：20 码点、宽 102 时取 k=9 → head 5 / tail 4
    const w20 = [_]f32{10} ** 20; // 全文 200 > 102
    try std.testing.expectEqual(EllipsisSplit{ .head = 5, .tail = 4 }, ellipsisSplit(&w20, ell, 102).?);

    // 四舍五入边界：恰好等于可用宽 → 算放得下（≤）
    try std.testing.expectEqual(EllipsisSplit{ .head = 2, .tail = 1 }, ellipsisSplit(&w, ell, 42).?);

    // 连最小形式（1+…+1 = 32）都放不下 → null（不画）
    try std.testing.expect(ellipsisSplit(&w, ell, 31) == null);
    // 单码点文本 + 放不下 → null（无“中间”可省）
    try std.testing.expect(ellipsisSplit(w[0..1], ell, 5) == null);
    try std.testing.expect(ellipsisSplit(&[_]f32{}, ell, 100) == null);
}
