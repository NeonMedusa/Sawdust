//! 帮助窗口：基本操作速查（工具栏「帮助」按钮打开；Esc 关闭）。
//! 文案以**实际键位**为准——改动快捷键时记得同步这里。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");

const title_h: i32 = 22;
const min_w: i32 = 360;
const min_h: i32 = 260;
const row_h: i32 = 21;
/// 键位列宽（说明列从 `key_w` 之后开始）
const key_w: i32 = 170;

const Row = struct { sec: bool, key: []const u8, desc: []const u8 };
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
    .{ .sec = false, .key = "Ctrl + ↑ / ↓", .desc = "音符上 / 下移动八度" },
    .{ .sec = false, .key = "Shift + ↑ / ↓", .desc = "音符上 / 下移动半音" },
    .{ .sec = false, .key = "Ctrl / Shift + ← / →", .desc = "左 / 右移动一小节 / 网格" },

    .{ .sec = true, .key = "视图", .desc = "" },
    .{ .sec = false, .key = "Ctrl + 滚轮", .desc = "横向缩放" },
    .{ .sec = false, .key = "Shift + 滚轮", .desc = "纵向缩放" },

    .{ .sec = true, .key = "VST3 插件", .desc = "" },
    .{ .sec = false, .key = "插件管理", .desc = "工具栏「插件」：加文件夹/文件 → 开始扫描（手动）" },
    .{ .sec = false, .key = "添加乐器", .desc = "机架「+ 添加乐器」→ 预设面板（内置 + 已扫描 VST3）" },
    .{ .sec = false, .key = "添加效果器", .desc = "混音台「+ 效果器」→ 预设面板（内置 + 已扫描 VST3）" },
        .{ .sec = false, .key = "插件界面", .desc = "双击效果 / 乐器名——插件界面直接嵌在面板中（无界面插件显示参数列表）" },
    .{ .sec = false, .key = "调参数", .desc = "面板列表：拖动改值 / 双击恢复默认 / 滚轮滚动" },
    .{ .sec = false, .key = "VST3 预设", .desc = "乐器窗口「预设 ▾ / 保存为…」；按插件分类存放" },
    .{ .sec = false, .key = "保存工程", .desc = "插件参数与音色随工程保存；撤销 / 重做同步" },
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
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        hw.open = false;
        return true;
    }

    // 点窗口内任意处 → 置顶（“点谁谁在上”）
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&hw.z);
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

    // 内容：两列（键位 / 说明），节标题用强调色
    var yy = y + title_h + 10;
    for (&rows) |r| {
        if (r.sec) {
            yy += 6;
            ui.label(r.key, x + 12, yy, ui.theme.accent);
            yy += row_h + 1;
            ui.renderer.hline(x + 12, yy - 5, ww - 24, ui.theme.panel_border);
            continue;
        }
        if (yy + row_h > y + hh - 8) break; // 装不下：后面的行不画（拉大窗口可见）
        ui.label(r.key, x + 20, yy, ui.theme.text);
        ui.label(r.desc, x + 20 + key_w, yy, ui.theme.text_dim);
        yy += row_h;
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}
