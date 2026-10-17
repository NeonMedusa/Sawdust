//! 设置窗口（工具栏「选项」打开）：启动行为 / 最高帧率。
//! 变更即置 `settings_dirty`，由 main 帧末落盘到数据目录 `settings.json`。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");

const title_h: i32 = 22;
const min_w: i32 = 360;
const min_h: i32 = 280;

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const sw = &app.settings_win;
    if (!sw.open) return false;
    sw.w = std.math.clamp(sw.w, min_w, @max(min_w, w - 20));
    sw.h = std.math.clamp(sw.h, min_h, @max(min_h, h - 20));
    sw.x = std.math.clamp(sw.x, 0, @max(0, w - sw.w));
    sw.y = std.math.clamp(sw.y, 0, @max(0, h - sw.h));
    const x = sw.x;
    const y = sw.y;
    const ww = sw.w;
    const hh = sw.h;

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, title_h - 1, ui.theme.toolbar);
    ui.label("设置", x + 8, y + 4, ui.theme.text);

    // 关闭按钮
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        sw.open = false;
        return true;
    }

    // 点窗口内任意处 → 置顶（“点谁谁在上”）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&sw.z);
    }

    // 标题拖动
    if (util.hitUI(ui, x, y, ww - 24, title_h) and ui.mouse_pressed) {
        ui.active_id = 9520;
        sw.grab_dx = ui.mouse_x - x;
        sw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 9520) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            sw.x = ui.mouse_x - sw.grab_dx;
            sw.y = ui.mouse_y - sw.grab_dy;
        }
    }

    // ── 启动程序时 ──
    var yy = y + title_h + 12;
    ui.label("启动程序时", x + 14, yy, ui.theme.text_dim);
    if (ui.toggle2(9521, "打开上次工程", "新建空工程", app.settings_open_last, x + 14, yy + 16, 280, 24)) {
        app.settings_open_last = !app.settings_open_last;
        app.settings_dirty = true;
    }
    yy += 56;

    // ── 最高帧率 ──
    ui.label("最高帧率（30 – 240 fps）", x + 14, yy, ui.theme.text_dim);
    var fps = app.fps_limit;
    if (ui.dragNumber(9522, x + 14, yy + 16, 64, 22, &fps, 30, 240, 2)) {
        app.fps_limit = fps;
        app.settings_dirty = true;
    }
    var fb: [16]u8 = undefined;
    ui.label(std.fmt.bufPrint(&fb, "{d} fps", .{app.fps_limit}) catch "", x + 88, yy + 20, ui.theme.text);
    ui.label("（拖动调整；实现为帧预算 = 1 秒 ÷ 帧率）", x + 14, yy + 44, ui.theme.text_dim);
    yy += 68;

    // ── 数据交换（JSON 可读格式；说明放在这里有充足宽度——用户要求）──
    ui.label("数据交换", x + 14, yy, ui.theme.text_dim);
    if (ui.button(9523, "导入 JSON...", x + 14, yy + 16, 140, 24)) {
        app.pending_file_action = .import_json;
    }
    if (ui.button(9524, "导出 JSON...", x + 162, yy + 16, 140, 24)) {
        app.pending_file_action = .export_json;
    }
    ui.label("JSON：可读文本格式，便于迁移到其他 DAW。", x + 14, yy + 46, ui.theme.text_dim);
    ui.label("导入 = 替换当前工程；导出 = 写出副本。", x + 14, yy + 60, ui.theme.text_dim);

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}
