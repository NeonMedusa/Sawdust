//! 帮助窗口：基本操作速查（工具栏「帮助」按钮打开；Esc 关闭）。
//! 文案以**实际键位**为准——改动快捷键时记得同步这里。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");
const window_mod = @import("window.zig");

const title_h: i32 = 22;
const min_w: i32 = 360;
// 可滚动 + 可拉伸 → 允许缩得很小（缩放很大时逻辑屏幕也会很小）
const min_h: i32 = 180;
const row_h: i32 = 21;
/// 键位列宽（说明列从 `key_w` 之后开始）
const key_w: i32 = 170;

/// 「关于」节的仓库链接：显示文本（紧凑）/ 实际打开地址（带协议，ShellExecute 更稳）
const repo_display = "github.com/NeonMedusa/Sawdust";
const repo_open: [:0]const u8 = "https://github.com/NeonMedusa/Sawdust";

const Row = struct { sec: bool, key: []const u8, desc: []const u8, link: bool = false };
const rows = [_]Row{
    .{ .sec = true, .key = "常用", .desc = "" },
    .{ .sec = false, .key = "空格", .desc = "播放 / 暂停" },
    .{ .sec = false, .key = "Ctrl + Z", .desc = "撤销" },
    .{ .sec = false, .key = "Ctrl + Alt + Z", .desc = "重做" },
    .{ .sec = false, .key = "Ctrl + S / Ctrl + O", .desc = "保存 / 打开工程" },

    .{ .sec = true, .key = "选择与编辑", .desc = "" },
    .{ .sec = false, .key = "Ctrl + 左键拖动", .desc = "框选音符 / 片段" },
    .{ .sec = false, .key = "Ctrl + Shift + 左键拖动", .desc = "追加到选区" },
    .{ .sec = false, .key = "Ctrl + A", .desc = "全选" },
    .{ .sec = false, .key = "Delete", .desc = "删除选中内容" },
    .{ .sec = false, .key = "Ctrl + B", .desc = "克隆选中内容" },
    .{ .sec = false, .key = "Ctrl + C / Ctrl + V", .desc = "复制 / 粘贴到鼠标位置" },
    .{ .sec = false, .key = "Ctrl + X", .desc = "剪切选中内容" },
    .{ .sec = false, .key = "Ctrl + M", .desc = "静音 / 取消静音选中音符或片段" },
    .{ .sec = false, .key = "Ctrl + Q", .desc = "量化选中音符 / 片段（两端上当前网格）" },
    .{ .sec = false, .key = "Ctrl + ↑ / ↓", .desc = "音符上 / 下移动八度" },
    .{ .sec = false, .key = "Shift + ↑ / ↓", .desc = "音符上 / 下移动半音" },
    .{ .sec = false, .key = "Ctrl / Shift + ← / →", .desc = "左 / 右移动一小节 / 网格" },
    .{ .sec = false, .key = "Alt + 拖动", .desc = "按 1 步（最细网格）拖动 / 拉伸 / 放置音符与片段" },

    .{ .sec = true, .key = "视图", .desc = "" },
    .{ .sec = false, .key = "Ctrl + 滚轮", .desc = "横向缩放" },
    .{ .sec = false, .key = "Shift + 滚轮", .desc = "纵向缩放" },
    .{ .sec = false, .key = "Ctrl + 单击横向滚动条", .desc = "跳转到点击位置" },

    .{ .sec = true, .key = "关于", .desc = "" },
    .{ .sec = false, .key = "开源许可", .desc = "免费开源（MIT）" },
    .{ .sec = false, .key = "项目仓库", .desc = repo_display, .link = true },
};

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const hw = &app.help_win;
    if (!hw.open) return false;
    hw.w = std.math.clamp(hw.w, min_w, @max(min_w, w - 20));
    hw.h = std.math.clamp(hw.h, min_h, @max(min_h, h - 20));
    hw.x = std.math.clamp(hw.x, 0, @max(0, w - hw.w));
    hw.y = std.math.clamp(hw.y, 0, @max(0, h - hw.h));
    const x = hw.x;
    const y = hw.y;
    const ww = hw.w;
    const hh = hw.h;

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, title_h - 1, ui.theme.toolbar);
    ui.label("帮助 — 基本操作", x + 8, y + 4, ui.theme.text);

    // 关闭按钮
    if (util.titleCloseButton(ui, x, y, ww, title_h)) {
        hw.open = false;
        return true;
    }

    // 标题拖动
    if (util.hitUI(ui, x, y, ww - 24, title_h) and ui.mouse_pressed) {
        ui.active_id = 9500;
        hw.grab_dx = ui.mouse_x - x;
        hw.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 9500) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            hw.x = ui.mouse_x - hw.grab_dx;
            hw.y = ui.mouse_y - hw.grab_dy;
        }
    }

    // 右下角缩放柄（同设置页/机架窗：三角形区 + 拖动改尺寸）
    const grip = 14;
    const grip_hovered = util.hitUI(ui, x + ww - grip, y + hh - grip, grip, grip);
    if (grip_hovered) ui.cursor = .resize_h;
    if (grip_hovered and ui.mouse_pressed) {
        ui.active_id = 9501;
        hw.resize_w0 = ww;
        hw.resize_h0 = hh;
        hw.resize_mx = ui.mouse_x;
        hw.resize_my = ui.mouse_y;
    }
    if (ui.active_id == 9501) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            hw.w = hw.resize_w0 + (ui.mouse_x - hw.resize_mx);
            hw.h = hw.resize_h0 + (ui.mouse_y - hw.resize_my);
        }
    }
    ui.renderer.line(x + ww - 10, y + hh - 2, x + ww - 2, y + hh - 10, ui.theme.panel_border);

    // 内容：两列（键位 / 说明），节标题用强调色。
    // **可滚动**：标题栏固定，内容区裁剪 + 滚轮（以前靠“窗口高刚刚好”，加两行就露尾巴）。
    const content_top = y + title_h + 1;
    const content_vis: i32 = hh - title_h - 1;
    const max_scroll: i32 = @max(0, hw.content_h - content_vis);
    if (util.hitUI(ui, x + 1, content_top, ww - 2, content_vis)) {
        hw.scroll = std.math.clamp(hw.scroll - ui.wheel * 28, 0, max_scroll);
    }
    hw.scroll = std.math.clamp(hw.scroll, 0, max_scroll);
    const saved_clip = ui.renderer.pushClip(x + 1, content_top, ww - 2, content_vis);
    var yy = content_top + 10 - hw.scroll;
    for (&rows) |r| {
        if (r.sec) {
            yy += 6;
            ui.label(r.key, x + 12, yy, ui.theme.accent);
            yy += row_h + 1;
            ui.renderer.hline(x + 12, yy - 5, ww - 24, ui.theme.panel_border);
            continue;
        }
        ui.label(r.key, x + 20, yy, ui.theme.text);
        if (r.link) {
            // 链接行：悬停高亮 + 下划线（链接外观）+ 单击 → 系统浏览器
            const tw: i32 = @intFromFloat(ui.font.measure(r.desc));
            const lx = x + 20 + key_w;
            const hovered = util.inRect(ui.mouse_x, ui.mouse_y, lx, yy, tw, row_h);
            const color = if (hovered) ui.theme.accent else ui.theme.text_dim;
            ui.label(r.desc, lx, yy, color);
            const baseline = yy + @as(i32, @intFromFloat(ui.font.ascentL()));
            ui.renderer.hline(lx, baseline + 2, tw, color);
            if (hovered and ui.mouse_pressed) window_mod.openExternalUrl(repo_open);
        } else {
            ui.label(r.desc, x + 20 + key_w, yy, ui.theme.text_dim);
        }
        yy += row_h;
    }
    ui.renderer.popClip(saved_clip);
    // 内容总高：与 scroll 无关（yy 已被 scroll 偏移过，加回来才不变）
    hw.content_h = (yy - content_top) + hw.scroll + 12;

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}
