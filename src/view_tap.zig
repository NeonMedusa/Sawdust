//! **敲击测速窗**（§11.48.4）：跟着节奏连点 → 中位数估 BPM → 即时写回。
//!
//! 算法全在 `App.tapTempo` / `App.tapTempoEnd`（纯逻辑、可单测），本文件只负责**画**与**命中**。
//! 规则摘要：最近 8 个间隔取**中位数** → 整数 BPM；新敲击与当前估计相差 **±30%** → 会话重置
//! （本次作为新会话第一击；< 2 个间隔不判）；**≥3 击**才出数；无超时；无 ×2/÷2。
//! 写值：**touch 语义**——BPM 被自动化驱动时不写（窗口里会显一行橙字提醒）。
//! 历史：**一个会话一条**（`App.tapRecordHistory` 起手 append、后续敲击原地更新）。

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const util = @import("view_util.zig");

const title_h: i32 = 22;
const min_w: i32 = 220;
const min_h: i32 = 200;

/// 返回 true = 鼠标被窗口消费。`frame_ns` = 本帧的 hi-res 时基（敲击间隔用它算）。
pub fn draw(ui: *Ui, app: *App, scr_w: i32, scr_h: i32, frame_ns: i64) bool {
    const tw = &app.tap_win;
    if (!tw.open) return false;
    util.clampWindow(scr_w, scr_h, &tw.x, &tw.y, &tw.w, &tw.h, min_w, min_h);
    const x = tw.x;
    const y = tw.y;
    const ww = tw.w;
    const hh = tw.h;

    // ── 窗口外壳 ──
    if (util.windowChrome(ui, 9600, 9601, "敲击测速", title_h, 24, &tw.x, &tw.y, &tw.w, &tw.h, &tw.grab_dx, &tw.grab_dy, &tw.resize_w0, &tw.resize_h0, &tw.resize_mx, &tw.resize_my, false)) {
        tw.open = false;
        app.tapTempoEnd(); // 关窗 = 会话终点（历史条目已在写值时落库，这里只清会话状态）
        return true;
    }

    // ── 大按钮（点它 = 敲一下）──
    const pad_x = x + 12;
    const pad_y = y + title_h + 8;
    const pad_w = ww - 24;
    const pad_h = @max(80, hh - title_h - 8 - 80);
    const hovered = util.hitUI(ui, pad_x, pad_y, pad_w, pad_h);
    if (hovered and ui.mouse_pressed) app.tapTempo(frame_ns);
    ui.renderer.fillRect(pad_x, pad_y, pad_w, pad_h, if (hovered) ui.theme.item_hover else ui.theme.toolbar);
    ui.renderer.strokeRect(pad_x, pad_y, pad_w, pad_h, ui.theme.panel_border);

    // 读数：**超大字号**数字（4× 字形，真光栅化不是位图放大），正下方水平居中的“BPM”（普通字号、灰色）。
    var nb: [24]u8 = undefined;
    const big = if (tw.est > 0)
        (std.fmt.bufPrint(&nb, "{d}", .{tw.est}) catch "—")
    else
        "—";
    const num_h: i32 = ui.lineHeightBig();
    const sub_h: i32 = 16;
    const gap_h: i32 = 6;
    const block_h = num_h + gap_h + sub_h;
    const block_y = pad_y + @divTrunc(pad_h - block_h, 2);
    const num_w = ui.measureBig(big);
    ui.labelBigCentered(big, pad_x + @divTrunc(pad_w - num_w, 2), block_y, num_h, if (tw.est > 0) ui.theme.auto_active else ui.theme.text_dim);
    const label_t = "BPM";
    const label_w: i32 = @as(i32, @intFromFloat(ui.font.measure(label_t)));
    ui.labelCentered(label_t, pad_x + @divTrunc(pad_w - label_w, 2), block_y + num_h + gap_h, sub_h, ui.theme.text_dim);

    // ── 底部：击数 + 当前文档值 + 提示（+ BPM 被自动化驱动时的警告行）──
    const auto_bpm = app.isTargetDriven(.{ .kind = .tempo });
    var ln: [72]u8 = undefined;
    const stats = std.fmt.bufPrint(&ln, "{d} 击 · 取中位数（最近 {d} 个间隔）", .{ tw.taps, tw.n_int }) catch "";
    ui.labelClipped(stats, x + 12, y + hh - 74, ww - 24, ui.theme.text_dim);
    var db: [64]u8 = undefined;
    const doc = std.fmt.bufPrint(&db, "文档 BPM {d:.2}", .{app.bpm_doc}) catch "";
    ui.labelClipped(doc, x + 12, y + hh - 58, ww - 24, ui.theme.text);
    // **touch 语义**：BPM 被曲线驱动时不写值（写进去也会被曲线盖掉）——这里讲明白
    if (auto_bpm) {
        ui.labelClipped("BPM 当前受自动化控制，敲击测速不会将值写入", x + 12, y + hh - 40, ww - 24, ui.theme.auto_takeover);
    }
    ui.labelClipped("跟着节奏连点；停顿后重新敲即开始新一轮", x + 12, y + hh - 22, ww - 24, ui.theme.text_dim);

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}
