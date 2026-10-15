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
    ui.noteOverlayRect(px, py, panel_w, panel_h); // 模态面板：遮挡插件子窗口

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
            .create_effect => "添加效果器 — 选效果与预设",
            .replace_effect => "效果器预设 — 选效果（可换效果器）",
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
        var n_vis: usize = 0;
        for (app.preset_lib.categories.items, 0..) |cat, i| {
            // 可见性由意图决定（用户拍板：乐器面板不见效果器/反之；未安装 VST3 隐藏）
            if (!app.presetCategoryRelevant(app.preset_browser.intent, cat.name)) continue;
            if (iy + row_h > py + panel_h - 1) break;
            n_vis += 1;
            const selected = i == app.preset_browser.cat;
            // 可选性由意图决定（非可选 → 置灰；点击只提示，教“预设不换插件”的模型）
            const selectable = app.presetCategorySelectable(app.preset_browser.intent, cat.name);
            const hovered = selectable and !ctx_open and util.hitUI(ui, px + 2, iy, cat_w - 4, row_h);
            if (selected or hovered) {
                ui.renderer.fillRect(px + 2, iy, cat_w - 4, row_h, if (selected) ui.theme.item_hover else ui.theme.slider_track);
            }
            const label_color = if (!selectable) ui.theme.key_label else if (selected) ui.theme.accent else ui.theme.text;
            ui.labelClipped(app.presetCategoryLabel(cat.name), px + 8, iy + 3, cat_w - 16, label_color);
            if (!just and !ctx_open and util.hitUI(ui, px + 2, iy, cat_w - 4, row_h) and ui.mouse_pressed) {
                if (selectable) {
                    app.preset_browser.cat = i;
                    app.preset_browser.scroll = 0;
                } else {
                    // 置灰点击 → 提示原因
                    if (std.mem.eql(u8, cat.name, preset_mod.plugin_drumkit)) {
                        app.setToast("鼓组里不能再嵌鼓组");
                    } else if (preset_mod.vst3CidFromCategory(cat.name) != null) {
                        app.setToast("插件未安装或未扫描到——请在插件管理里扫描/添加");
                    } else {
                        app.setToastWith("{s}尚未实装", .{app.presetCategoryLabel(cat.name)});
                    }
                }
            }
            iy += row_h;
        }
        if (n_vis == 0) {
            ui.label("（无可用分类）", px + 8, body_y + 22, ui.theme.text_dim);
        }
    }

    // ── 右栏：搜索框 → 置顶默认伪预设（同款）→ 过滤后的预设列表 ──
    const rx = px + 1 + cat_w + 1;
    const rw = panel_w - (cat_w + 2) - 2;
    {
        // 搜索框文字 ← 输入框（编辑中实时同步；过滤即时生效）
        if (app.text_input.active and app.text_input.target == .preset_search) {
            const ti = &app.text_input;
            const n = @min(ti.len, app.preset_browser.filter_buf.len);
            @memcpy(app.preset_browser.filter_buf[0..n], ti.buf[0..n]);
            app.preset_browser.filter_len = n;
        }
        const q = app.presetSearchQuery();

        const list_y = body_y + 4;
        const list_h = body_h - 8;
        const n_cat = app.preset_lib.categories.items.len;
        const cat_idx = @min(app.preset_browser.cat, if (n_cat > 0) n_cat - 1 else 0);
        if (n_cat > 0) {
            const cat = &app.preset_lib.categories.items[cat_idx];
            // 行悬停高亮“钉”在右键的那一行（不跟鼠标——否则鼠标划过菜单项时，
            // 菜单下面的行也跟着亮；用户反馈观感差）
            const ctx_row: usize = app.preset_browser.ctx orelse std.math.maxInt(usize);

            // ① 搜索框（静态层；编辑中 main 的文本输入 overlay 会盖在同位置）
            const sx = rx + 4;
            const sw = rw - 8;
            {
                const s_hovered = !ctx_open and util.hitUI(ui, sx, list_y, sw, row_h);
                ui.renderer.fillRect(sx, list_y, sw, row_h, if (s_hovered) ui.theme.item_hover else ui.theme.slider_track);
                ui.renderer.strokeRect(sx, list_y, sw, row_h, ui.theme.panel_border);
                const editing = app.text_input.active and app.text_input.target == .preset_search;
                if (!editing) {
                    if (q.len > 0) {
                        ui.labelClipped(q, sx + 4, list_y + 6, sw - 8, ui.theme.text);
                    } else {
                        ui.label("搜索预设…", sx + 4, list_y + 6, ui.theme.text_dim);
                    }
                }
                if (!just and !ctx_open and s_hovered and ui.mouse_pressed) {
                    app.beginPresetSearch(sx, list_y, sw);
                }
            }
            // 搜索框与列表的分割线
            ui.renderer.hline(rx + 4, list_y + row_h + 1, rw - 8, ui.theme.panel_border);

            // ② 置顶默认伪预设（**与普通预设同款**：白字；仅恒置顶）
            const def_y = list_y + row_h + 2;
            {
                const hovered = !ctx_open and util.hitUI(ui, rx, def_y, rw, row_h);
                if (hovered) ui.renderer.fillRect(rx, def_y, rw, row_h, ui.theme.item_hover);
                var db: [64]u8 = undefined;
                const dlabel = std.fmt.bufPrint(&db, "{s}", .{preset_mod.defaultPresetLabel(cat.name)}) catch "";
                ui.labelClipped(dlabel, rx + 8, def_y + 3, rw - 16, ui.theme.text);
                if (!just and !ctx_open and hovered and ui.mouse_pressed) {
                    app.pending_preset = .{ .load = .{
                        .intent = app.preset_browser.intent,
                        .cat = cat_idx,
                        .choice = .default,
                    } };
                    app.preset_browser.open = false;
                }
            }

            // ③ 预设文件（过滤 + 滚动；与默认行同属一个列表，无下方分割线）
            const list_top = def_y + row_h;
            const list_area_h = @max(row_h, list_y + list_h - list_top);
            var n_match: i32 = 0;
            for (cat.presets.items) |name| {
                if (q.len > 0 and std.ascii.indexOfIgnoreCase(name, q) == null) continue;
                n_match += 1;
            }
            const content_h: i32 = n_match * row_h;
            // 滚动（滚轮悬停列表区；菜单展开时不让位——菜单在面板内，滚动它很怪）
            if (!ctx_open and util.hitUI(ui, rx, list_top, rw, list_area_h)) {
                app.preset_browser.scroll = std.math.clamp(app.preset_browser.scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_area_h));
            }
            app.preset_browser.scroll = std.math.clamp(app.preset_browser.scroll, 0, @max(0, content_h - list_area_h));
            if (n_match > 0) {
                const saved = ui.renderer.pushClip(rx, list_top, rw, list_area_h);
                defer ui.renderer.popClip(saved);
                var vi: i32 = 0;
                for (cat.presets.items, 0..) |name, i| {
                    if (q.len > 0 and std.ascii.indexOfIgnoreCase(name, q) == null) continue;
                    const iy = list_top + vi * row_h - app.preset_browser.scroll;
                    vi += 1;
                    if (iy + row_h <= list_top) continue;
                    if (iy >= list_top + list_area_h) break;
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
            } else if (q.len > 0) {
                ui.label("（无匹配预设）", rx + 8, list_top + 3, ui.theme.text_dim);
            }
            ui.drawScrollbar(rx + rw - 6, list_top, 5, list_area_h, app.preset_browser.scroll, content_h, list_area_h);

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
                    ui.noteOverlayRect(mx, my, mw, mh); // 遮挡插件子窗口
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
