//! 立即式 UI 的交互单测：模拟"按下 → 拖动 → 抬起"序列，验证推子值变化。
//! 这类测试不需要窗口（只依赖 render + ui），能在 CI 里跑。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const HBarMode = @import("ui.zig").HBarMode;
const Font = @import("font.zig").Font;
const view_util = @import("view_util.zig");

/// 构造一个"假 UI"（无字体依赖的控件测试用；slider 不需要字体）
fn makeUi(fb: *r_mod.Framebuffer) Ui {
    // slider 不读 font，但 Ui 结构要求非空指针 → 用 undefined 占位（测试不触碰）
    const fake_font: *Font = @ptrFromInt(@alignOf(Font));
    return Ui.init(r_mod.Renderer.init(fb), fake_font);
}

test "ui: 自绘下拉箭头——逐行收窄、不越界（替代缺字的 ▾）" {
    var buf: [20 * 10]u32 = undefined;
    @memset(&buf, 0);
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 20, .height = 10 };
    var ui = makeUi(&fb);
    const col: u32 = 0xFF112233;
    view_util.menuArrow(&ui, 2, 2, col);
    // 行宽 7/5/3/1，逐行缩进 1（x=2, y=2 起）
    try std.testing.expectEqual(col, buf[2 * 20 + 2]);
    try std.testing.expectEqual(col, buf[2 * 20 + 8]); // 首行最右
    const outside_row0 = buf[2 * 20 + 9]; // 首行之外
    try std.testing.expect(outside_row0 != col);
    try std.testing.expectEqual(col, buf[3 * 20 + 3]);
    try std.testing.expectEqual(col, buf[5 * 20 + 5]); // 末行宽 1
    try std.testing.expect(buf[6 * 20 + 2] != col); // 不越到第 5 行以下
}

test "view_util: 网格标签不带 ▾（字体缺字；箭头自绘）" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("网格 1/2", view_util.snapLabel(&buf, 1));
    try std.testing.expectEqualStrings("网格 1/12", view_util.snapLabel(&buf, 8));
    try std.testing.expect(std.mem.indexOf(u8, view_util.snapLabel(&buf, 3), "▾") == null);
}

test "ui: 旋钮值域——超出 0..1 的值也能拖回（Q 值卡最大值事故）" {
    // 实测事故：Q 旋钮（0.1..4.0）误用 `knob`（内部 clamp 到 0..1）→
    // 拖一下就被压到 1.0，之后再怎么拖都回不去（“拧不动/卡在最大值”）。
    var buf: [60 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 60, .height = 40 };
    var ui = makeUi(&fb);
    const x: i32 = 10;
    const y: i32 = 10;
    const size: i32 = 20;

    // `knobRange`：初值 1.0（范围内）→ 下拖应能降到 0.1 附近（不被钳到 0）
    var q: f32 = 1.0;
    ui.mouse_x = x + 10;
    ui.mouse_y = y + 10;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.knobRange(1, &q, x, y, size, 0.1, 4.0);
    ui.endFrame();
    // 下拖 120px → 减 1.0 个量程（range=3.9 → 3.9）→ 1.0-3.9 = -2.9 → 钳到 0.1
    ui.mouse_y = y + 10 + 120;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    _ = ui.knobRange(1, &q, x, y, size, 0.1, 4.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), q, 0.01);
    ui.endFrame();

    // 再上拖 → 能回升（不是“卡住”）
    ui.mouse_y = y + 10;
    _ = ui.knobRange(1, &q, x, y, size, 0.1, 4.0);
    try std.testing.expect(q > 0.5);
    ui.endFrame();
}

test "游标：三角的不变量（居中、1px 尖端、不越出标尺行）" {
    // 注：三角宽度是**装饰性常量**（可随时微调）——本测试只验不变量，
    // 不硬编码宽度（否则调外观就挂）。
    var buf: [60 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 60, .height = 40 };
    var ui = makeUi(&fb);
    @memset(fb.pixels, ui.theme.bg);

    const x: i32 = 30;
    const ruler_y: i32 = 4;
    const ruler_h: i32 = 20;
    const bottom_y: i32 = 36;
    view_util.drawCursor(&ui, x, ruler_y, ruler_h, bottom_y, false);

    const col = ui.theme.cursor_idle;
    const width = 60;

    // 找出标尺行内所有含三角像素的行（顶行 = 最宽行）
    var top_row: i32 = -1;
    var tip_row: i32 = -1;
    var row = ruler_y;
    while (row < ruler_y + ruler_h) : (row += 1) {
        var has = false;
        var px: i32 = 0;
        while (px < width) : (px += 1) {
            if (buf[@as(usize, @intCast(row)) * width + @as(usize, @intCast(px))] == col) {
                has = true;
                break;
            }
        }
        if (has) {
            if (top_row < 0) top_row = row;
            tip_row = row;
        }
    }
    try std.testing.expect(top_row >= 0); // 三角已画出

    // 不变量 1：顶行宽度为奇数且以 x 为中心（居中无 off-by-one）
    var w_top: i32 = 0;
    var px: i32 = 0;
    while (px < width) : (px += 1) {
        if (buf[@as(usize, @intCast(top_row)) * width + @as(usize, @intCast(px))] == col) w_top += 1;
    }
    try std.testing.expect(@mod(w_top, 2) == 1);
    try std.testing.expectEqual(col, buf[@as(usize, @intCast(top_row)) * width + @as(usize, @intCast(x))]);
    const half = @divTrunc(w_top - 1, 2);
    try std.testing.expectEqual(col, buf[@as(usize, @intCast(top_row)) * width + @as(usize, @intCast(x - half))]);
    try std.testing.expectEqual(col, buf[@as(usize, @intCast(top_row)) * width + @as(usize, @intCast(x + half))]);

    // 不变量 2：尖端（最后一行）= 1px，居中于 x
    var w_tip: i32 = 0;
    px = 0;
    while (px < width) : (px += 1) {
        if (buf[@as(usize, @intCast(tip_row)) * width + @as(usize, @intCast(px))] == col) w_tip += 1;
    }
    try std.testing.expectEqual(@as(i32, 1), w_tip);
    try std.testing.expectEqual(col, buf[@as(usize, @intCast(tip_row)) * width + @as(usize, @intCast(x))]);

    // 不变量 3：三角矮小——不越出标尺行（尖端必须在标尺行内）
    try std.testing.expect(tip_row < ruler_y + ruler_h);

    // 不变量 4：竖线从标尺底边开始（x 处）
    const first_line_row = ruler_y + ruler_h;
    try std.testing.expectEqual(col, buf[@as(usize, @intCast(first_line_row)) * width + @as(usize, @intCast(x))]);
}

test "ui: 传输图标按钮——自绘形状（不依赖字体字形）" {
    // 动机：中文字体常缺几何符号字形（▶ U+25B6 等）→ 缺字退回 .notdef 方块
    // （实测“播放按钮变竖长方形”）。自绘形状与字体无关——本测试锁死四个形状的像素级不变量。
    var buf: [40 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 40, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 2;
    const y: i32 = 7;
    const w: i32 = 36;
    const h: i32 = 26;
    const cx = x + @divTrunc(w, 2); // 20
    const cy = y + @divTrunc(h, 2); // 20
    const fg = ui.theme.text;
    const at = struct {
        fn f(b: []const u32, px: i32, py: i32) u32 {
            return b[@as(usize, @intCast(py)) * 40 + @as(usize, @intCast(px))];
        }
    }.f;

    // ── 播放：右向三角（左缘竖直、中间行最宽、顶点朝右）──
    @memset(fb.pixels, ui.theme.bg);
    _ = ui.iconButton(200, .play, x, y, w, h, false, ui.theme.accent);
    try std.testing.expectEqual(fg, at(&buf, cx - 5, cy)); // 左缘（中间行最左）
    try std.testing.expectEqual(fg, at(&buf, cx + 4, cy)); // 顶点（中间行最右）
    try std.testing.expectEqual(fg, at(&buf, cx - 5, cy - 6)); // 顶行仍从同一条左缘起
    try std.testing.expect(at(&buf, cx + 4, cy - 6) != fg); // 顶行窄——顶点处无像素
    try std.testing.expectEqual(fg, at(&buf, cx - 5, cy + 6)); // 底行

    // ── 暂停：两根竖条 + 中间缝隙 ──
    @memset(fb.pixels, ui.theme.bg);
    _ = ui.iconButton(201, .pause, x, y, w, h, false, ui.theme.accent);
    try std.testing.expectEqual(fg, at(&buf, cx - 4, cy)); // 左条
    try std.testing.expectEqual(fg, at(&buf, cx + 4, cy)); // 右条
    try std.testing.expect(at(&buf, cx, cy) != fg); // 缝隙
    try std.testing.expectEqual(fg, at(&buf, cx - 4, cy - 6)); // 条高一致（上下端）
    try std.testing.expectEqual(fg, at(&buf, cx + 4, cy + 6));

    // ── 停止：实心方块（含四角）──
    @memset(fb.pixels, ui.theme.bg);
    _ = ui.iconButton(202, .stop, x, y, w, h, false, ui.theme.accent);
    try std.testing.expectEqual(fg, at(&buf, cx, cy));
    try std.testing.expectEqual(fg, at(&buf, cx - 6, cy - 6)); // 左上角
    try std.testing.expectEqual(fg, at(&buf, cx + 6, cy + 6)); // 右下角

    // ── 录制：实心圆（顶部/底部/左右都有像素，四角无）──
    @memset(fb.pixels, ui.theme.bg);
    _ = ui.iconButton(203, .record, x, y, w, h, false, ui.theme.accent);
    try std.testing.expectEqual(fg, at(&buf, cx, cy));
    try std.testing.expectEqual(fg, at(&buf, cx, cy - 6)); // 顶
    try std.testing.expectEqual(fg, at(&buf, cx, cy + 6)); // 底
    try std.testing.expectEqual(fg, at(&buf, cx - 6, cy)); // 左
    try std.testing.expectEqual(fg, at(&buf, cx + 6, cy)); // 右
    try std.testing.expect(at(&buf, cx - 6, cy - 6) != fg); // 四角在圆外（是圆不是方）

    // ── 激活态：底色 = active_color；点击判定 = hovered && mouse_pressed ──
    @memset(fb.pixels, ui.theme.bg);
    ui.mouse_x = cx;
    ui.mouse_y = cy;
    ui.mouse_pressed = false;
    try std.testing.expect(!ui.iconButton(204, .record, x, y, w, h, true, ui.theme.record));
    try std.testing.expectEqual(ui.theme.record, at(&buf, x + 2, y + 2)); // 激活底色（角上避开图标）
    ui.mouse_pressed = true;
    try std.testing.expect(ui.iconButton(204, .record, x, y, w, h, true, ui.theme.record)); // 点击
    ui.mouse_pressed = false;
    // 按钮外不命中
    ui.mouse_x = x - 2;
    try std.testing.expect(!ui.iconButton(204, .record, x, y, w, h, false, ui.theme.record));
}

test "ui: 视图切换按钮（标题栏最右）——命中范围与点击" {
    var buf: [300 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 300, .height = 40 };
    var ui = makeUi(&fb);

    const panel_x: i32 = 10;
    const panel_w: i32 = 280;
    const y: i32 = 8;
    const bar_h: i32 = 24;
    // 按钮右对齐：bw = 16、右缘 = panel_x + panel_w - 6 → [x+w-6-16-4, ...)
    const bw: i32 = bar_h - 8;
    const btn_x = panel_x + panel_w - 6 - bw - 4;

    // 悬停命中（不点击）→ 返回 false
    ui.mouse_x = btn_x + 2;
    ui.mouse_y = y + 6;
    try std.testing.expect(!view_util.viewSwitchButton(&ui, panel_x + panel_w - 6, y, bar_h));
    // 点击 → 返回 true
    ui.mouse_pressed = true;
    try std.testing.expect(view_util.viewSwitchButton(&ui, panel_x + panel_w - 6, y, bar_h));
    ui.mouse_pressed = false;
    // 按钮左侧（网格选单区域）不命中
    ui.mouse_x = btn_x - 10;
    try std.testing.expect(!view_util.viewSwitchButton(&ui, panel_x + panel_w - 6, y, bar_h));
    // 绘制：按钮区域应出现非背景像素（箭头已画出）
    ui.mouse_x = btn_x + 2;
    _ = view_util.viewSwitchButton(&ui, panel_x + panel_w - 6, y, bar_h);
    var found = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ui.theme.text) found = true;
    }
    try std.testing.expect(found);
}

test "ui: 水平推子——按下并拖动应改变值" {
    var buf: [200 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 200, .height = 40 };
    var ui = makeUi(&fb);

    var value: f32 = 0.0;
    const x: i32 = 10;
    const w: i32 = 100;

    // 帧 1：鼠标移到推子左端并按下
    ui.mouse_x = x + 5;
    ui.mouse_y = 20;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.slider(1, &value, x, 0, w, 40);
    try std.testing.expect(ui.active_id == 1); // 已进入拖动状态
    ui.endFrame();

    // 帧 2：鼠标拖到中间（不重新按下——这是关键：跨帧保持）
    ui.mouse_x = x + 50;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    const changed = ui.slider(1, &value, x, 0, w, 40);
    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), value, 0.05);
    ui.endFrame();

    // 帧 3：抬起 → 退出拖动
    ui.mouse_down = false;
    ui.mouse_released = true;
    _ = ui.slider(1, &value, x, 0, w, 40);
    try std.testing.expectEqual(@as(u64, 0), ui.active_id);
    ui.endFrame();
}

test "ui: 垂直推子——向上拖应增大" {
    var buf: [60 * 200]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 60, .height = 200 };
    var ui = makeUi(&fb);

    var value: f32 = 0.5;
    const y: i32 = 10;
    const h: i32 = 100;

    // 按下（在推子中部）
    ui.mouse_x = 20;
    ui.mouse_y = y + 50;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.vslider(2, &value, 0, y, 60, h);
    ui.endFrame();

    // 向上拖（y 减小 → 值增大）
    ui.mouse_y = y + 10;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    const changed = ui.vslider(2, &value, 0, y, 60, h);
    try std.testing.expect(changed);
    try std.testing.expect(value > 0.5);
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——拖主体到右端继续拖：滑块左缘 1:1、滑块被压缩" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    var scroll: i32 = 0;
    var content: i32 = view; // 初始：内容 = 一屏（滑块满宽）
    var zoom: f32 = 1.0;

    // 帧 1：在滑块中部按下（滑块满宽）
    ui.mouse_x = x + 100;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0);
    try std.testing.expectEqual(@as(u64, 7), ui.active_id);
    try std.testing.expectEqual(HBarMode.body, ui.drag_mode_h);
    ui.endFrame();

    // 帧 2：右拖 100px（滑块已贴右端）→ 滑块左缘 1:1 跟手（左缘 10→110，宽 380→280）
    // 内容长 = view_cw × w / thumb_w = 200 × 380 / 280 = 271（视图贴右端）
    ui.mouse_x = x + 200;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    try std.testing.expect(ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0));
    try std.testing.expectEqual(@as(i32, 271), content);
    try std.testing.expectEqual(@as(i32, 71), scroll);
    ui.endFrame();

    // 帧 3：继续右拖 50px → desired=170（绝对屏幕坐标）→ 滑块宽 = 390-170 = 220
    // → 内容 = 200×380/220 = 345
    ui.mouse_x = x + 260;
    try std.testing.expect(ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0));
    try std.testing.expectEqual(@as(i32, 345), content);
    try std.testing.expectEqual(@as(i32, 145), scroll);
    ui.endFrame();

    // 帧 4：抬起 → 退出拖动；行程保留（不回弹）
    ui.mouse_down = false;
    ui.mouse_released = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0);
    try std.testing.expectEqual(@as(u64, 0), ui.active_id);
    try std.testing.expectEqual(@as(i32, 345), content); // 松手不回弹
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——陈旧膨胀自动收回（行程贴合内容右缘）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;

    // 情景：content 之前被拖得很大（陈旧膨胀），内容右缘缩回 → 回到左端时自动收回
    var scroll: i32 = 0;
    var content: i32 = 900;
    var zoom: f32 = 1.0;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 400, 0.2, 8.0);
    try std.testing.expectEqual(@as(i32, 400), content); // 回到左端 → 重新贴合内容
    try std.testing.expectEqual(@as(i32, 0), scroll);
    ui.endFrame();

    // 内容右缘变大 → 下限抬升，content 自动跟上
    ui.mouse_x = -100; // 鼠标远离轨道（不影响）
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 700, 0.2, 8.0);
    try std.testing.expectEqual(@as(i32, 700), content);
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——回到左端才回收延长（拖出的行程保留、不回弹）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    var scroll: i32 = 0;
    var content: i32 = view;
    var zoom: f32 = 1.0;

    // 帧 1：按下（滑块满宽）
    ui.mouse_x = x + 100;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 100, 0.2, 8.0);
    ui.endFrame();

    // 帧 2：右拖 150px → 拖出延长（内容变大、滑块变短）
    ui.mouse_x = x + 250;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 100, 0.2, 8.0);
    const dragged = content;
    try std.testing.expect(dragged > 300); // 已延长
    ui.endFrame();

    // 帧 3：松手（不在左端）→ 行程保留，不回弹
    ui.mouse_down = false;
    ui.mouse_released = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 100, 0.2, 8.0);
    try std.testing.expectEqual(dragged, content); // 不回弹
    try std.testing.expect(content > 300);
    ui.endFrame();

    // 帧 4：把 scroll 拉回 0（回到左端）→ 行程重新贴合内容（回收延长）
    scroll = 0;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 100, 0.2, 8.0);
    try std.testing.expectEqual(@as(i32, 200), content); // 回收 = max(内容右缘, 一屏)
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——拖右缘 = 缩放（左端固定、滑块变长=视野变大）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    var scroll: i32 = 100; // 不在左端（避免触发“回左端自动贴合”规则）
    var content: i32 = 400;
    var zoom: f32 = 1.0; // view_cw=200, max_scroll=200, frac=0.5, travel=190 → thumb 跨 [105,295]

    // 帧 1：按右缘（295-8=287 内）
    ui.mouse_x = 290;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0);
    try std.testing.expectEqual(HBarMode.right, ui.drag_mode_h);
    ui.endFrame();

    // 帧 2：右拖到 380 → 左缘固定（105）→ 滑块宽 275 → view_cw = 275*400/380 = 289
    // → zoom = 200/289 ≈ 0.692（视野变大）；scroll 不变（左缘固定）
    ui.mouse_x = 380;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    try std.testing.expect(ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.692), zoom, 0.01);
    try std.testing.expectEqual(@as(i32, 100), scroll);
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——拖左缘 = 缩放（右端内容位置守恒）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    var scroll: i32 = 100;
    var content: i32 = 400;
    var zoom: f32 = 1.0; // view_cw=200, max_scroll=200, frac=0.5, travel=190 → thumb_x0=105

    // 帧 1：按左缘（105+8=113 内）
    ui.mouse_x = 107;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0);
    try std.testing.expectEqual(HBarMode.left, ui.drag_mode_h);
    ui.endFrame();

    // 帧 2：左拖到 155 → 新左缘 153 → 滑块宽 142 → view_cw = 142*400/380 = 149 → zoom = 200/149 ≈ 1.342
    // 右端内容位置守恒：scroll + view_cw = 300 → 新 scroll = 300 - 149 = 151
    ui.mouse_x = 155;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    try std.testing.expect(ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 0.2, 8.0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.342), zoom, 0.01);
    try std.testing.expectEqual(@as(i32, 151), scroll);
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——拖出延长后（zoom 低于 zoom_min）拖左缘仍可扩宽视野" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    // 模拟“拖出延长”后的状态：content 远大于一屏；zoom = 1.0 但 zoom_min = 1.43
    // （时间轴短于视口时的动态下限——**高于**当前 zoom，旧实现会把拖左缘钳死）
    var scroll: i32 = 600; // 贴右端（max_scroll = 800 - 200）
    var content: i32 = 800;
    var zoom: f32 = 1.0;

    // 滑块：thumb_w = 200/800×380 = 95；thumb_x = 10 + 1.0×(380-95) = 295 → [295, 390]
    // 帧 1：按左缘（295 + 8 = 303 内）
    ui.mouse_x = 297;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 1.43, 8.0);
    try std.testing.expectEqual(HBarMode.left, ui.drag_mode_h);
    ui.endFrame();

    // 帧 2：左拖到 200 → 新左缘 198 → 滑块宽 192 → view_cw = 192×800/380 = 404
    // → zoom = 200/404 ≈ 0.495（视野扩宽；旧实现被 zoom_min 钳回 1.0 = 拖不动）
    ui.mouse_x = 200;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    try std.testing.expect(ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 1.43, 8.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.495), zoom, 0.01);
    // 右端内容位置守恒：scroll + view_cw = 600 + 200 = 800 → 新 scroll = 800 - 404 = 396
    try std.testing.expectEqual(@as(i32, 396), scroll);
    ui.endFrame();
}

test "ui: 横向时间轴滚动条——拖右缘到物理下限（滑块满宽后不再缩）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    // 同场景：content 800、zoom 1.0、zoom_min 1.43（高于 zoom）
    var scroll: i32 = 300;
    var content: i32 = 800;
    var zoom: f32 = 1.0;
    // 滑块：thumb_w = 95、thumb_x = 10 + 0.5×285 = 152 → [152, 247]

    // 帧 1：按右缘（247 - 8 = 239 起）
    ui.mouse_x = 244;
    ui.mouse_y = y + 5;
    ui.mouse_down = true;
    ui.mouse_pressed = true;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 1.43, 8.0);
    try std.testing.expectEqual(HBarMode.right, ui.drag_mode_h);
    ui.endFrame();

    // 帧 2：右拖到 600（远超轨道右缘 390）→ 左缘固定 152，滑块最多到轨道右缘
    // → 宽 = 238（不是满宽）→ view_cw = 238×800/380 = 501 → zoom = 200/501 ≈ 0.399
    // （物理下限 0.25 未被触及——右缘拖动受“左缘固定”几何限制，行为正确）
    ui.mouse_x = 600;
    ui.mouse_down = true;
    ui.mouse_pressed = false;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 0, 1.43, 8.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.399), zoom, 0.01);
    // 视野变宽 → 右缘内容位置不变时 scroll 被钳到 content_w - vcw = 800 - 501 = 299
    try std.testing.expectEqual(@as(i32, 299), scroll);
    ui.endFrame();
}

test "ui: zoomSquareState——冻结位移驱动、松开帧不丢位移" {
    var buf: [40 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 40, .height = 40 };
    var ui = makeUi(&fb);
    var value: i32 = 44;

    // 帧 1：悬停下按 → 进入拖动
    ui.mouse_pressed = true;
    ui.mouse_down = true;
    try std.testing.expect(!ui.zoomSquareState(5, true, &value, 16, 120, 2));
    try std.testing.expectEqual(@as(u64, 5), ui.active_id);
    try std.testing.expect(ui.mouse_capture);
    ui.endFrame();

    // 帧 2：冻结位移向上 10px（-10 → +5 单位，2px/单位）
    ui.mouse_down = true;
    ui.frozen_dy = -10;
    try std.testing.expect(ui.zoomSquareState(5, true, &value, 16, 120, 2));
    try std.testing.expectEqual(@as(i32, 49), value);
    ui.endFrame();

    // 帧 3：鼠标已松开，但本帧仍有累积位移 → 必须应用（不能直接丢弃）
    ui.mouse_down = false;
    ui.frozen_dy = -14; // 再向上 4px → +2 单位
    try std.testing.expect(ui.zoomSquareState(5, true, &value, 16, 120, 2));
    try std.testing.expectEqual(@as(i32, 51), value);
    try std.testing.expectEqual(@as(u64, 0), ui.active_id); // 拖动已结束
    try std.testing.expect(!ui.mouse_capture);
    ui.endFrame();
}

// ── 层系统（输入分层 + 自动裁剪）──

test "ui: 层系统——高层覆盖鼠标处屏蔽低层" {
    var buf: [200 * 100]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 200, .height = 100 };
    var ui = makeUi(&fb);

    // 主界面（全屏）+ 机架窗口（(50,20)-(150,80)）
    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 } });
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 50, .y = 20, .w = 100, .h = 60 } });

    // 鼠标在窗口内 → 主界面被屏蔽，窗口可响应
    ui.mouse_x = 100;
    ui.mouse_y = 50;
    try std.testing.expect(!ui.beginLayer(0));
    ui.endLayer();
    try std.testing.expect(ui.beginLayer(1));
    ui.endLayer();

    // 鼠标在窗口外 → 主界面可响应
    ui.mouse_x = 10;
    ui.mouse_y = 10;
    try std.testing.expect(ui.beginLayer(0));
    ui.endLayer();
    try std.testing.expect(ui.beginLayer(1));
    ui.endLayer();
}

test "ui: 层系统——模态层无条件屏蔽所有低层" {
    var buf: [200 * 100]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 200, .height = 100 };
    var ui = makeUi(&fb);

    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 } });
    _ = ui.declare(.{ .prio = 2, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .modal = true });

    // 鼠标在任何位置（哪怕模态层矩形为空）→ 低层都被屏蔽
    ui.mouse_x = 5;
    ui.mouse_y = 5;
    try std.testing.expect(!ui.beginLayer(0));
    ui.endLayer();
    try std.testing.expect(!ui.beginLayer(1));
    ui.endLayer();
}

test "ui: 层系统——同优先级多次声明会更新矩形" {
    var buf: [200 * 100]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 200, .height = 100 };
    var ui = makeUi(&fb);

    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 } });
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } });
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 50, .y = 50, .w = 10, .h = 10 } }); // 窗口拖动后
    try std.testing.expectEqual(@as(usize, 2), ui.layer_n); // 未重复入表

    // 鼠标在新矩形内 → 主界面被屏蔽
    ui.mouse_x = 55;
    ui.mouse_y = 55;
    try std.testing.expect(!ui.beginLayer(0));
    ui.endLayer();
    // 鼠标在旧矩形内（已移走）→ 主界面可响应
    ui.mouse_x = 5;
    ui.mouse_y = 5;
    try std.testing.expect(ui.beginLayer(0));
    ui.endLayer();
}

test "ui: 层系统——beginLayer 自动收窄绘制裁剪区" {
    var buf: [100 * 50]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 100, .height = 50 };
    var ui = makeUi(&fb);
    ui.renderer.clear(r_mod.rgb(0, 0, 0));

    ui.resetLayers();
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 } });

    _ = ui.beginLayer(1);
    ui.renderer.fillRect(0, 0, 100, 50, r_mod.rgb(255, 0, 0)); // 试图全屏填充
    ui.endLayer();

    // 只有层矩形内变红
    try std.testing.expectEqual(r_mod.rgb(255, 0, 0), buf[15 * 100 + 15]);
    try std.testing.expectEqual(r_mod.rgb(0, 0, 0), buf[5 * 100 + 5]);
    try std.testing.expectEqual(r_mod.rgb(0, 0, 0), buf[40 * 100 + 40]);
}

test "ui: 层系统——多窗口各自独立层（同 prio 不会互相顶掉、无点击穿透）" {
    // 实测事故：合成器与调音台曾都用 prio 2——`declare` 对同 prio 是**覆盖**，
    // 后声明的把先声明的层顶掉 → 被顶那层矩形不在表里 → 鼠标在其上时不被屏蔽
    // → 点击穿透到下层（“三者同开时击穿减法合成器”）。
    // 修法：每窗口独立 prio（= z 序位次）。本测试锁死该不变量。
    var buf: [400 * 300]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 300 };
    var ui = makeUi(&fb);

    // 三个窗口矩形（互不重叠便于断言）：
    //   下：合成器 (10,10)-(110,60)；上：调音台 (150,10)-(250,60)；机架 (10,100)-(110,150)
    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } });
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 10, .y = 100, .w = 100, .h = 50 } }); // 机架
    _ = ui.declare(.{ .prio = 2, .rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 } }); // 合成器
    _ = ui.declare(.{ .prio = 3, .rect = .{ .x = 150, .y = 10, .w = 100, .h = 50 } }); // 调音台
    try std.testing.expectEqual(@as(usize, 4), ui.layer_n); // 四个层都在（无覆盖）

    // 鼠标在合成器上：合成器层可响应（未被调音台顶掉）、主界面被屏蔽
    ui.mouse_x = 60;
    ui.mouse_y = 35;
    try std.testing.expect(!ui.beginLayer(0));
    ui.endLayer();
    try std.testing.expect(ui.beginLayer(2)); // 合成器：**能**响应（修好前会因层被顶掉而误判）
    ui.endLayer();
    // 调音台在合成器之上：鼠标不在其矩形内 → 仍可响应
    try std.testing.expect(ui.beginLayer(3));
    ui.endLayer();

    // 鼠标在调音台上：调音台可响应，合成器被屏蔽
    ui.mouse_x = 200;
    ui.mouse_y = 35;
    try std.testing.expect(!ui.beginLayer(2));
    ui.endLayer();
    try std.testing.expect(ui.beginLayer(3));
    ui.endLayer();
}

test "ui: 层系统——高 prio 窗口矩形内屏蔽低 prio 窗口（防穿透）" {
    var buf: [400 * 300]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 300 };
    var ui = makeUi(&fb);

    // 两窗口**重叠**（模拟合成器/调音台叠在一起）
    ui.resetLayers();
    _ = ui.declare(.{ .prio = 0, .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } });
    _ = ui.declare(.{ .prio = 1, .rect = .{ .x = 50, .y = 50, .w = 200, .h = 100 } }); // 下（合成器）
    _ = ui.declare(.{ .prio = 2, .rect = .{ .x = 100, .y = 50, .w = 200, .h = 100 } }); // 上（调音台）

    // 重叠区（x=150）：上层可响应，**下层被屏蔽**（不穿透）
    ui.mouse_x = 150;
    ui.mouse_y = 100;
    try std.testing.expect(!ui.beginLayer(1)); // 下层被上层矩形屏蔽
    ui.endLayer();
    try std.testing.expect(ui.beginLayer(2));
    ui.endLayer();
    // 非重叠区（x=70）：下层可响应（上层矩形不覆盖）
    ui.mouse_x = 70;
    ui.mouse_y = 100;
    try std.testing.expect(ui.beginLayer(1));
    ui.endLayer();
}

// ── 缩放下限的被动抬高不得改动用户缩放 ──

test "ui: 内容缩短后不自动回缩（缩放量不被被动钳制）" {
    var buf: [400 * 40]u32 = undefined;
    var fb = r_mod.Framebuffer{ .pixels = &buf, .width = 400, .height = 40 };
    var ui = makeUi(&fb);

    const x: i32 = 10;
    const y: i32 = 10;
    const w: i32 = 380;
    const h: i32 = 20;
    const view: i32 = 200;
    var scroll: i32 = 0;
    var content: i32 = 200;
    // 用户已缩到底：zoom 正好等于当时的动态下限（0.4）
    var zoom: f32 = 0.4;

    // 内容缩短（删除了最右音符）→ 调用方算出的动态下限抬高到 0.8
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom, view, 400, 0.8, 8.0);

    // zoom 不应被被动抬高（画面不回缩）；上限仍然有效
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), zoom, 0.001);

    // 对照：超过上限时仍被钳制
    var zoom2: f32 = 9.0;
    _ = ui.scrollbarTimeline(7, x, y, w, h, &scroll, &content, &zoom2, view, 400, 0.8, 8.0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), zoom2, 0.001);
}

test "ui: 主动缩放（滚轮）仍受动态下限约束" {
    // 滚轮路径的钳制在视图侧：new_zoom = clamp(old * 1.25^k, min(dyn_min, old), 8)
    // 已缩到底（old == dyn_min）→ 继续下滚不再变小
    const old: f32 = 0.4;
    const dyn_min: f32 = 0.4;
    const down = std.math.clamp(old * std.math.pow(f32, 1.25, -1), @min(dyn_min, old), 8.0);
    try std.testing.expectApproxEqAbs(old, down, 0.001);
    // 下限被动抬高（内容缩短后 dyn_min = 0.8）但用户当前 0.4 → 下滚不放大
    const dyn_raised: f32 = 0.8;
    const still = std.math.clamp(old * std.math.pow(f32, 1.25, -1), @min(dyn_raised, old), 8.0);
    try std.testing.expectApproxEqAbs(old, still, 0.001);
}

// ── 拖动数值控件（BPM）的内核：zoomStep + 每步帧数换算 ──
// 注：dragNumber 的绘制依赖字体（测里没有真字体），故只测其数值内核与换算。

test "ui: roundF——负值取整（修功率推子 -5 松手回 -4）" {
    // `@intFromFloat(v + 0.5)` 只对非负数是四舍五入；负数下向零截断会读回 +1
    // （实测 bug：功率推子拉到 -5 → 每帧重读为 -4）
    try std.testing.expectEqual(@as(i32, -5), Ui.roundF(-5.0));
    try std.testing.expectEqual(@as(i32, -4), Ui.roundF(-4.0));
    try std.testing.expectEqual(@as(i32, -5), Ui.roundF(-4.5)); // 远离零取
    try std.testing.expectEqual(@as(i32, -4), Ui.roundF(-4.4));
    try std.testing.expectEqual(@as(i32, 5), Ui.roundF(5.0));
    try std.testing.expectEqual(@as(i32, 4), Ui.roundF(4.4));
    try std.testing.expectEqual(@as(i32, 5), Ui.roundF(4.5));
    try std.testing.expectEqual(@as(i32, 0), Ui.roundF(0.0));
    try std.testing.expectEqual(@as(i32, -37), Ui.roundF(-36.6));
}

test "ui: BPM 拖动内核——8px/单位、上滑增下滑减、慢拖累积、范围钳制" {
    // 上滑 16px → +2（8px/单位）
    {
        const r = Ui.zoomStep(120, -16, 0, 8, 20, 999);
        try std.testing.expectEqual(@as(i32, 122), r.v);
    }
    // 下滑 16px → -2
    {
        const r = Ui.zoomStep(120, 16, 0, 8, 20, 999);
        try std.testing.expectEqual(@as(i32, 118), r.v);
    }
    // 慢拖：每次 1px，8 次才 -1（不丢步）
    {
        var v: i32 = 120;
        var rem: i32 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const r = Ui.zoomStep(v, 1, rem, 8, 20, 999);
            v = r.v;
            rem = r.rem;
        }
        try std.testing.expectEqual(@as(i32, 119), v);
    }
    // 钳制
    try std.testing.expectEqual(@as(i32, 999), Ui.zoomStep(998, -100, 0, 8, 20, 999).v);
    try std.testing.expectEqual(@as(i32, 20), Ui.zoomStep(21, 100, 0, 8, 20, 999).v);
}

test "ui: 推子式慢拖——每帧小位移跨帧累积（修通道机架推子“慢拖无响应”）" {
    // 通道机架推子：40px/通道。旧实现每帧 `@divTrunc(dd, 20)` 且**丢弃余数**：
    // 每帧 5px 的慢拖每帧都截成 0 → 拖半天无响应；快拖单帧跳好几格。
    // 用 zoomStep 后：5px/帧 × 8 帧 = 40px → 恰好 1 通道（不丢步）。
    var ch: i32 = 0;
    var rem: i32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const r = Ui.zoomStep(ch, -5, rem, 40, 0, 7); // 上拖 5px/帧
        ch = r.v;
        rem = r.rem;
    }
    try std.testing.expectEqual(@as(i32, 1), ch); // 8 帧后恰好 +1（而非 0 或跳多格）
}

test "ui: 每步帧数换算（BPM × 每拍步数 → 步长）——U=96 对照" {
    const sr: u64 = 48000;
    // 4/4：每拍步数 = 96/4 = 24
    const spb4: u64 = 24;
    const f120: u64 = @max(1, sr * 60 / (120 * spb4));
    const f240: u64 = @max(1, sr * 60 / (240 * spb4));
    try std.testing.expectEqual(@as(u64, 1000), f120); // 每步 1/96 全音符，@120BPM ≈ 20.8ms
    try std.testing.expectEqual(@as(u64, 500), f240); // BPM 翻倍 → 每步减半
    // 四分音符（24 步）时长：120BPM 下应为 0.5s = 24000 帧
    try std.testing.expectEqual(@as(u64, 24000), f120 * spb4);
    // 8 分音符分母（6/8 → 每拍 12 步）：每步时长翻倍
    const spb8: u64 = 12;
    const f120_8: u64 = @max(1, sr * 60 / (120 * spb8));
    try std.testing.expectEqual(@as(u64, 2000), f120_8);
}

test "ui: 指数式推子（拍号分母）——拖 1 单位翻倍、无吸附振荡" {
    // 指数模式内核：cur_drag = log2(值)；拖 1 单位 → 值 ×2
    // 模拟：值 4（指数 2）→ 拖 +1 → 指数 3 → 值 8
    const log2Floor = struct {
        fn f(v: i32) i32 {
            var x = @max(1, v);
            var e: i32 = 0;
            while (x > 1) : (x >>= 1) e += 1;
            return e;
        }
    }.f;

    try std.testing.expectEqual(@as(i32, 2), log2Floor(4)); // 4 → 指数 2
    try std.testing.expectEqual(@as(i32, 3), log2Floor(8)); // 8 → 指数 3
    try std.testing.expectEqual(@as(i32, 0), log2Floor(1));
    try std.testing.expectEqual(@as(i32, 4), log2Floor(16));

    // 关键：连续的拖动手感是**线性指数**（不会像“吸附写回”那样 4↔5 振荡）
    // 拖 4px（1 单位）→ 指数 +1 → 值翻倍；再拖 4px → 再翻倍
    var den: i32 = 4;
    var exp = log2Floor(den);
    exp += 1;
    den = @as(i32, 1) << @intCast(exp);
    try std.testing.expectEqual(@as(i32, 8), den);
    exp += 1;
    den = @as(i32, 1) << @intCast(exp);
    try std.testing.expectEqual(@as(i32, 16), den);
}

// ── 字符串格式化：不能自别名 ──

test "fmt: 增量拼接要把上一个结果留在**别的**缓冲（自别名会 panic）" {
    // 实测事故：效果器面板标题拼乐器名时写成
    //   names = bufPrint(&buf, "{s}+", .{names});
    // 第二次时 names 已指向同一 buf → 源与目标别名 → “@memcpy arguments alias”
    // 运行时 panic（两个乐器都路由到同通道时必崩）。
    // 本测试用**正确写法**（前一个结果存独立缓冲）验证不 panic 且内容正确。
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const n1 = try std.fmt.bufPrint(&buf_a, "{s}", .{"减法合成器"});
    const n2 = try std.fmt.bufPrint(&buf_b, "{s} +1", .{n1});
    try std.testing.expectEqualStrings("减法合成器 +1", n2);

    // 格式化源来自**另一**缓冲时，可以回写第一个缓冲区（不构成别名）
    const n3 = try std.fmt.bufPrint(&buf_a, "{s}", .{n2});
    try std.testing.expectEqualStrings("减法合成器 +1", n3);
}
