//! 预设面板（**统一的插件+预设选择器**；见 `docs/drumkit.md` §5.2）：
//!
//! - 左栏 = 插件类型（减法合成器 / 鼓组 / …；显示名）。可选性由**意图**决定
//!   （`App.presetCategorySelectable`）：乐器窗口的「预设 ▾」只允许当前插件；
//!   「＋ 添加乐器」「更换乐器」允许任意已实装插件（鼓垫加乐器不列鼓组）。
//! - 右栏 = 该插件**置顶的默认伪预设**（`（默认音色）/（默认套鼓）/（未实装）`）
//!   + 分类里的预设文件。选中条目 → 排队 `App.pending_preset = .load`
//!   （文件 IO 在 main 帧末做——本模块不碰 io）。
//!
//! 模态：由 `App.menuIsOpen()` 计入（全屏屏蔽下层）；绘制在 main 的
//! `endFrame` 之前、浮动窗口之后（与文件菜单同一层）。Esc / 点面板外关闭。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const App = @import("app.zig").App;
const util = @import("view_util.zig");
const preset_mod = @import("preset.zig");

const panel_w: i32 = 500;
const panel_h: i32 = 380;
const cat_w: i32 = 150; // 左栏宽
const row_h: i32 = 22;

pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) void {
    if (!app.preset_browser.open) return;
    // 打开的那一下点击只用于“打开”：本帧不处理任何点击
    // （否则会被“点面板外”立即关闭，或穿透选中预设行）
    const just = app.preset_browser.just_opened;
    app.preset_browser.just_opened = false;

    // 全屏暗化（点击面板外 = 关闭）
    ui.renderer.fillRect(0, 0, w, h, (@as(u32, 0x66) << 24) | 0x000000);
    const px = @divTrunc(w - panel_w, 2);
    const py = @divTrunc(h - panel_h, 2);
    const outside = !util.inRect(ui.mouse_x, ui.mouse_y, px, py, panel_w, panel_h);
    if (!just and ui.mouse_pressed and outside) {
        app.preset_browser.open = false;
        return;
    }

    // 面板
    ui.renderer.fillRect(px + 3, py + 3, panel_w, panel_h, r_mod.rgb(10, 11, 13)); // 阴影
    ui.renderer.fillRect(px, py, panel_w, panel_h, ui.theme.panel);
    ui.renderer.strokeRect(px, py, panel_w, panel_h, ui.theme.accent);

    // 标题（按意图区分；replace 带当前插件名）
    ui.renderer.fillRect(px + 1, py + 1, panel_w - 2, util.title_h - 1, ui.theme.toolbar);
    {
        const intent = app.preset_browser.intent;
        const title: []const u8 = switch (intent) {
            .replace => |t| switch (t) {
                .instrument => "预设库 — 选音色（可换插件）",
                .kit_layer_replace => "预设库 — 选音色",
            },
            .create_instrument => "添加乐器 — 选插件与预设",
            .change_instrument => "更换乐器 — 选插件与预设",
            .create_kit_layer => "为鼓垫添加乐器 — 选插件与预设",
        };
        ui.label(title, px + 8, py + 4, ui.theme.text);
    }
    {
        const cx = px + panel_w - 22;
        const hovered = util.hitUI(ui, cx, py + 2, 20, util.title_h - 4);
        ui.renderer.fillRect(cx, py + 2, 20, util.title_h - 4, if (hovered) ui.theme.danger else ui.theme.panel);
        ui.label("×", cx + 6, py + 4, ui.theme.text);
        if (!just and hovered and ui.mouse_pressed) {
            app.preset_browser.open = false;
            return;
        }
    }

    const body_y = py + util.title_h;
    const body_h = panel_h - util.title_h;
    // 右键菜单展开时：面板其它条目让位（防穿透；菜单在最后画并吞掉本帧点击）
    const ctx_open = app.preset_browser.ctx != null;

    // ── 左栏：插件类型（分类；中文显示名）──
    ui.renderer.fillRect(px + 1, body_y, cat_w, body_h - 1, ui.theme.bg);
    ui.renderer.vline(px + 1 + cat_w, body_y, body_h - 1, ui.theme.panel_border);
    ui.label("插件类型", px + 8, body_y + 4, ui.theme.text_dim);
    {
        var iy = body_y + 22;
        for (app.preset_lib.categories.items, 0..) |cat, i| {
            if (iy + row_h > py + panel_h - 1) break;
            const selected = i == app.preset_browser.cat;
            // 可选性由意图决定（非可选 → 置灰；点击只提示，教“预设不换插件”的模型）
            const selectable = app.presetCategorySelectable(app.preset_browser.intent, cat.name);
            const hovered = selectable and !ctx_open and util.hitUI(ui, px + 2, iy, cat_w - 4, row_h);
            if (selected or hovered) {
                ui.renderer.fillRect(px + 2, iy, cat_w - 4, row_h, if (selected) ui.theme.item_hover else ui.theme.slider_track);
            }
            const label_color = if (!selectable) ui.theme.key_label else if (selected) ui.theme.accent else ui.theme.text;
            ui.labelClipped(preset_mod.pluginDisplayName(cat.name), px + 8, iy + 3, cat_w - 16, label_color);
            if (!just and !ctx_open and util.hitUI(ui, px + 2, iy, cat_w - 4, row_h) and ui.mouse_pressed) {
                if (selectable) {
                    app.preset_browser.cat = i;
                    app.preset_browser.scroll = 0;
                } else {
                    // 置灰点击 → 提示原因
                    if (std.mem.eql(u8, cat.name, preset_mod.plugin_drumkit)) {
                        app.setToast("鼓组里不能再嵌鼓组");
                    } else {
                        app.setToastWith("{s}尚未实装", .{preset_mod.pluginDisplayName(cat.name)});
                    }
                }
            }
            iy += row_h;
        }
        if (app.preset_lib.categories.items.len == 0) {
            ui.label("（无）", px + 8, body_y + 22, ui.theme.text_dim);
        }
    }

    // ── 右栏：置顶默认伪预设 + 预设列表 ──
    const rx = px + 1 + cat_w + 1;
    const rw = panel_w - (cat_w + 2) - 2;
    {
        const list_y = body_y + 4;
        const list_h = body_h - 8;
        const n_cat = app.preset_lib.categories.items.len;
        const cat_idx = @min(app.preset_browser.cat, if (n_cat > 0) n_cat - 1 else 0);
        if (n_cat > 0) {
            const cat = &app.preset_lib.categories.items[cat_idx];
            // 行悬停高亮“钉”在右键的那一行（不跟鼠标——否则鼠标划过菜单项时，
            // 菜单下面的行也跟着亮；用户反馈观感差）
            const ctx_row: usize = app.preset_browser.ctx orelse std.math.maxInt(usize);
            // 行集合 = [0] 置顶默认伪预设 + [1..] 预设文件
            const n_rows: i32 = @as(i32, @intCast(cat.presets.items.len)) + 1;
            const content_h: i32 = n_rows * row_h;
            // 滚动（滚轮悬停右栏；菜单展开时不让位——菜单在面板内，滚动它很怪）
            if (!ctx_open and util.hitUI(ui, rx, list_y, rw, list_h)) {
                app.preset_browser.scroll = std.math.clamp(app.preset_browser.scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
            }
            const saved = ui.renderer.pushClip(rx, list_y, rw, list_h);
            defer ui.renderer.popClip(saved);

            // ① 置顶默认伪预设（选中 = 用该插件默认参数建/换/重置）
            {
                const ry = list_y - app.preset_browser.scroll;
                if (ry + row_h > list_y and ry < list_y + list_h) {
                    const hovered = !ctx_open and util.hitUI(ui, rx, ry, rw, row_h);
                    if (hovered) ui.renderer.fillRect(rx, ry, rw, row_h, ui.theme.item_hover);
                    var db: [64]u8 = undefined;
                    const dlabel = std.fmt.bufPrint(&db, "{s}", .{preset_mod.defaultPresetLabel(cat.name)}) catch "";
                    ui.labelClipped(dlabel, rx + 8, ry + 3, rw - 16, ui.theme.accent);
                    if (!just and !ctx_open and hovered and ui.mouse_pressed) {
                        app.pending_preset = .{ .load = .{
                            .intent = app.preset_browser.intent,
                            .cat = cat_idx,
                            .choice = .default,
                        } };
                        app.preset_browser.open = false;
                    }
                }
                // 默认行与预设列表的分隔线
                ui.renderer.hline(rx + 4, ry + row_h, rw - 8, ui.theme.panel_border);
            }

            // ② 预设文件
            var iy = list_y + row_h - app.preset_browser.scroll;
            for (cat.presets.items, 0..) |name, i| {
                if (iy + row_h > list_y + list_h) break;
                if (iy + row_h > list_y) {
                    // 悬停：ctx 展开时钉在右键行；否则跟鼠标
                    const hovered = if (ctx_open) (ctx_row == i) else util.hitUI(ui, rx, iy, rw, row_h);
                    if (hovered) ui.renderer.fillRect(rx, iy, rw, row_h, ui.theme.item_hover);
                    ui.labelClipped(name, rx + 8, iy + 3, rw - 16, ui.theme.text);
                    if (!just and !ctx_open and hovered and ui.mouse_pressed) {
                        // 排队加载（IO 在 main 帧末——不在此处碰文件）
                        app.pending_preset = .{ .load = .{
                            .intent = app.preset_browser.intent,
                            .cat = cat_idx,
                            .choice = .{ .preset = i },
                        } };
                        app.preset_browser.open = false;
                    }
                    // 右键 → 重命名/删除菜单（仅预设文件行；菜单位置 = 光标）
                    if (!ctx_open and hovered and ui.mouse_right_pressed) {
                        app.preset_browser.ctx = i;
                        app.preset_browser.ctx_x = ui.mouse_x;
                        app.preset_browser.ctx_y = ui.mouse_y;
                    }
                }
                iy += row_h;
            }
            // 空分类提示（默认伪预设仍可用——不算“空”）
            if (cat.presets.items.len == 0) {
                ui.label("（还没有预设 — 用乐器窗口的「保存为…」新增）", rx + 8, iy + 4, ui.theme.text_dim);
            }
            ui.drawScrollbar(rx + rw - 6, list_y, 5, list_h, app.preset_browser.scroll, content_h, list_h);

            // ③ 右键菜单（重命名/删除…）——最后画：本帧吞掉其余点击
            if (app.preset_browser.ctx) |ci| {
                if (ci >= cat.presets.items.len) {
                    app.preset_browser.ctx = null;
                } else {
                    const items = [_][]const u8{ "重命名", "删除…" };
                    const mw: i32 = 120;
                    const mh: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
                    const mx = std.math.clamp(app.preset_browser.ctx_x, 0, @max(0, w - mw));
                    const my = std.math.clamp(app.preset_browser.ctx_y, 0, @max(0, h - mh));
                    ui.renderer.fillRect(mx, my, mw, mh, ui.theme.panel);
                    ui.renderer.strokeRect(mx, my, mw, mh, ui.theme.accent);
                    var clicked: ?usize = null;
                    var inside = false;
                    for (items, 0..) |item, mi| {
                        const my2 = my + 2 + @as(i32, @intCast(mi)) * util.menu_item_h;
                        const ih = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, my2, mw - 2, util.menu_item_h);
                        if (ih) {
                            inside = true;
                            ui.renderer.fillRect(mx + 1, my2, mw - 2, util.menu_item_h, ui.theme.item_hover);
                        }
                        ui.label(item, mx + 8, my2 + 2, ui.theme.text);
                        if (ih and ui.mouse_pressed) clicked = mi;
                    }
                    if (clicked) |mi| {
                        const pname = cat.presets.items[ci];
                        if (mi == 0) {
                            app.beginRenamePresetFile(cat_idx, ci, mx + 4, my + 4);
                        } else {
                            app.setDeletePrompt(cat_idx, pname);
                        }
                        app.preset_browser.ctx = null;
                    } else if (ui.mouse_pressed and !inside) {
                        app.preset_browser.ctx = null;
                    }
                }
            }
        }
    }
}
