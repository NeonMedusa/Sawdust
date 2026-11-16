//! **VST 参数自动化（v1：UI 侧施加）**
//!
//! 一个乐器一个窗口，三段式（像常见 DAW 的“参数列表”）：
//!
//! 1. **已链接**：这个乐器上已有绑定的参数（**绿色、只读**——值由曲线决定，
//!    想改去自动化窗口；手动扭也会被自动化覆盖回去）；
//! 2. **最近改动**：用户最近动过的 10 个参数（取自插件 `edit_ring` 的 `performEdit`，
//!    见 `App.noteVstParamTouched`）；
//! 3. **全部参数**：插件报的全表（带搜索框；`kIsReadOnly` 不列）。
//!
//! 每行右侧 `自动化` 按钮弹菜单：新建曲线并链接 / 链接到曲线… / 打开自动化… / 取消链接。
//!
//! 入口：
//! - Windows：乐器窗口标题栏 `自动化` 按钮 → 浮动窗口（`draw`）；
//! - Linux：插件面板正文直接是本文件的 `drawBody`（编辑器是独立窗口，正文空着）。
//!
//! 施加在 `App.applyVstParamAutomation()`（UI 侧每帧 + 逐绑定平滑 τ）。

const std = @import("std");
const r_mod = @import("render.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const PluginSlotRef = app_mod.PluginSlotRef;
const Ui = @import("ui.zig").Ui;
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");
const vst_host = @import("vst_host.zig");

pub const W: i32 = 560;
pub const H: i32 = 540;

/// 行高 / 分段标题高
const row_h: i32 = 18;
const sect_h: i32 = 16;
const title_h: i32 = util.title_h;

/// 浮动窗口的控件 id 段（Linux 嵌入式用 `9600 + 2000` 之类，互不撞车）
const id_win: u64 = 12000;

/// 行内 `自动化` 按钮宽
const menu_btn_w: i32 = 56;
const menu_w: i32 = 132;

/// **浮动窗口**（窗口标题栏 `自动化` 按钮打开：乐器 / 效果器 / 鼓组层三处共用）
pub fn draw(ui: *Ui, app: *App) void {
    const st = &app.vst_auto;
    if (!st.open) return;
    const x = st.x;
    const y = st.y;
    const w = W;
    const h = H;

    // 目标插件槽没了（乐器/通道/槽/层被删）→ 自动关闭
    if (app.slotParamIdentity(st.ref) == null) {
        st.open = false;
        return;
    }

    // 窗口底 + 边框 + 标题栏
    ui.renderer.fillRect(x + 3, y + 3, w, h, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, w, h, ui.theme.panel);
    ui.renderer.strokeRect(x, y, w, h, ui.theme.accent);
    ui.renderer.fillRect(x + 1, y + 1, w - 2, title_h - 1, ui.theme.toolbar);
    // **注意：不登记 `noteOverlayRect`**。
    // 那张表是给**菜单/弹层**用的，而 `syncEmbeddedEditor` 拿 `overlay_n != 0`
    // 直接把插件子窗口禁掉（输入闸门）——整窗登记 = 一开自动化窗口，
    // 插件自己的 GUI 就再也不可交互（实测 bug）。窗口的遮挡靠 `win_draw_info` 处理。

    var tb: [192]u8 = undefined;
    const title = app.slotTitle(st.ref, &tb);
    ui.labelClipped(title, x + 8, y + 4, w - 60, ui.theme.text);

    // 标题拖动（存抓取偏移，避免拿起来就跳）
    const drag_id: u64 = id_win + 1;
    if (util.hitUI(ui, x, y, w - 60, title_h) and ui.mouse_pressed) {
        ui.active_id = drag_id;
        st.drag_dx = ui.mouse_x - x;
        st.drag_dy = ui.mouse_y - y;
    }
    if (ui.active_id == drag_id) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            const scr_w = ui.renderer.logicalWidth();
            const scr_h = ui.renderer.logicalHeight();
            st.x = std.math.clamp(ui.mouse_x - st.drag_dx, 0, @max(0, scr_w - w));
            st.y = std.math.clamp(ui.mouse_y - st.drag_dy, 0, @max(0, scr_h - h));
        }
    }

    // 关闭按钮（全项目统一：`util.titleCloseButton`）
    if (util.titleCloseButton(ui, x, y, w, title_h)) {
        st.open = false;
        st.menu_open = false;
        ui.active_id = 0;
        return;
    }

    drawBody(ui, app, st.ref, id_win + 100, x, y + title_h, w, h - title_h);
}

/// **正文**（三段式）。`x/y/w/h` = 正文矩形（不含标题栏）。
/// `ref` = 插件实例的**运行时寻址**（乐器 / 效果器槽 / 鼓组层）：每帧由调用方重新解析（不跨帧持有 `*Plugin`）。
pub fn drawBody(ui: *Ui, app: *App, ref: PluginSlotRef, id_base: u64, x: i32, y: i32, w: i32, h: i32) void {
    const st = &app.vst_auto;
    const ident = app.slotParamIdentity(ref) orelse return;
    const pl = app.slotPlugin(ref) orelse {
        ui.label("（插件未加载——无法编辑参数；文件恢复后自动加载）", x + 10, y + 10, ui.theme.danger);
        return;
    };
    // 换目标 → 滚动/搜索复位
    if (App.slotRefKey(st.ref) != App.slotRefKey(ref)) {
        st.ref = ref;
        st.scroll = 0;
        st.filter_len = 0;
        st.menu_open = false;
    }

    var yy = y + 6;
    {
        var nb: [224]u8 = undefined;
        ui.labelClipped(
            std.fmt.bufPrint(&nb, "{s} · {d} 个参数", .{ pl.name(), pl.paramCount() }) catch "",
            x + 10,
            yy,
            w - 20,
            ui.theme.text_dim,
        );
        yy += 18;
    }

    // ── 搜索框（静态层；编辑中 main 的文本输入 overlay 盖在同位置）──
    const search_h: i32 = 18;
    {
        const sx = x + 8;
        const sw = w - 16;
        if (app.text_input.active and app.text_input.target == .vst_param_search) {
            const ti = &app.text_input;
            const n = @min(ti.len, st.filter_buf.len);
            @memcpy(st.filter_buf[0..n], ti.buf[0..n]);
            st.filter_len = n;
        }
        const editing = app.text_input.active and app.text_input.target == .vst_param_search;
        const hovered = util.hitUI(ui, sx, yy, sw, search_h);
        ui.renderer.fillRect(sx, yy, sw, search_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(sx, yy, sw, search_h, ui.theme.panel_border);
        if (!editing) {
            if (st.filter_len > 0) {
                ui.labelClipped(st.filter_buf[0..st.filter_len], sx + 4, yy + 3, sw - 8, ui.theme.text);
            } else {
                ui.label("搜索参数…", sx + 4, yy + 3, ui.theme.text_dim);
            }
        }
        if (hovered and ui.mouse_pressed) app.beginVstParamSearch(sx, yy, sw);
        yy += search_h + 6;
    }

    // ── 三段列表（共用滚动）──
    const list_y = yy;
    const list_h = y + h - list_y - 4;
    if (list_h < row_h * 2) return;

    const n_params = pl.paramCount();
    // ① 已链接：按**参数**归组（一个参数挂多条曲线 → **只占一行**）
    var linked: [48]LinkedRow = undefined;
    var n_linked: i32 = 0;
    for (app.auto_bindings.items) |b| {
        // 本插件槽的绑定（乐器 / 效果器槽 / 鼓组层 → 稳定 uid 身份）
        if (b.target.kind != ident.kind or b.target.uid != ident.uid or b.target.slot != ident.slot) continue;
        var gi: usize = 0;
        while (gi < @as(usize, @intCast(n_linked))) : (gi += 1) {
            if (view_lane.Target.eql(linked[gi].target, b.target)) break;
        }
        if (gi == @as(usize, @intCast(n_linked))) {
            if (gi >= linked.len) continue; // 上限：极端情况超出就丢（不影响播放）
            linked[gi] = .{ .target = b.target, .n = 0, .first_curve = b.curve_id, .enabled = false };
            n_linked += 1;
        }
        linked[gi].n += 1;
        linked[gi].enabled = linked[gi].enabled or b.enabled;
    }
    // 最近改动是**跨插件槽**的：只算本槽的（不占行）
    const slot_key = App.slotRefKey(ref);
    var n_recent: i32 = 0;
    for (app.vst_recent[0..app.vst_recent_n]) |e| {
        if (e.slot_key == slot_key and pl.findParamIndex(e.param_id) != null) n_recent += 1;
    }

    const q = st.filter_buf[0..st.filter_len];
    var n_all: i32 = 0;
    {
        var pi: usize = 0;
        while (pi < n_params) : (pi += 1) {
            if ((pl.params[pi].flags & 0x2) != 0) continue; // kIsReadOnly
            if (q.len > 0 and std.ascii.findIgnoreCase(pl.params[pi].name(), q) == null) continue;
            n_all += 1;
        }
    }

    const content_h: i32 = (sect_h + @max(n_linked, 1) * row_h) +
        (sect_h + @max(n_recent, 1) * row_h) +
        (sect_h + @max(n_all, 1) * row_h) + 8;
    const scroll_max: i32 = @max(0, content_h - list_h);
    if (util.hitUI(ui, x + 8, list_y, w - 16, list_h)) {
        st.scroll = std.math.clamp(st.scroll - util.scrollDelta(ui), 0, scroll_max);
    }
    st.scroll = std.math.clamp(st.scroll, 0, scroll_max);
    const scrollbar_w: i32 = if (scroll_max > 0) 7 else 0;

    const saved = ui.renderer.pushClip(x + 8, list_y, w - 16 - scrollbar_w, list_h);
    defer ui.renderer.popClip(saved);

    var cy = list_y - st.scroll;
    const row_x = x + 8;
    const row_w = w - 16 - scrollbar_w;
    // 视口剔除用：行是否可见
    const vis = struct {
        fn f(ry: i32, top: i32, bot: i32) bool {
            return ry + row_h > top and ry < bot;
        }
    }.f;
    const list_bot = list_y + list_h;

    // ① 已链接
    sectionLabel(ui, "已链接", row_x, cy, row_w, n_linked);
    cy += sect_h;
    if (n_linked == 0) {
        ui.labelClipped("（还没有链接任何参数——用下方行右侧的「自动化」建一条曲线）", row_x + 6, cy + 2, row_w - 8, ui.theme.text_dim);
        cy += row_h;
    } else {
        var gi: usize = 0;
        while (gi < @as(usize, @intCast(n_linked))) : (gi += 1) {
            if (vis(cy, list_y, list_bot)) drawLinkedRow(ui, app, pl, linked[gi], id_base + 1000 + @as(u64, gi), row_x, cy, row_w);
            cy += row_h;
        }
    }

    // ② 最近改动
    sectionLabel(ui, "最近改动", row_x, cy, row_w, n_recent);
    cy += sect_h;
    if (n_recent == 0) {
        ui.labelClipped("（在插件界面里扭一下旋钮，它就会出现在这里）", row_x + 6, cy + 2, row_w - 8, ui.theme.text_dim);
        cy += row_h;
    } else {
        var i: usize = 0;
        while (i < app.vst_recent_n) : (i += 1) {
            const e = app.vst_recent[i];
            if (e.slot_key != slot_key) continue;
            const pi = pl.findParamIndex(e.param_id) orelse continue;
            if (vis(cy, list_y, list_bot)) drawParamRow(ui, app, pl, pi, id_base + 2000 + @as(u64, pi), row_x, cy, row_w, ref);
            cy += row_h;
        }
    }

    // ③ 全部参数
    sectionLabel(ui, "全部参数", row_x, cy, row_w, n_all);
    cy += sect_h;
    if (n_all == 0) {
        ui.labelClipped("（没有匹配的参数）", row_x + 6, cy + 2, row_w - 8, ui.theme.text_dim);
        cy += row_h;
    } else {
        var pi: usize = 0;
        while (pi < n_params) : (pi += 1) {
            if ((pl.params[pi].flags & 0x2) != 0) continue;
            if (q.len > 0 and std.ascii.findIgnoreCase(pl.params[pi].name(), q) == null) continue;
            // 视口外直接跳过（Serum 这类 2000+ 参数不要每帧排版/取值）
            if (cy + row_h < list_y) {
                cy += row_h;
                continue;
            }
            if (cy > list_bot) break;
            drawParamRow(ui, app, pl, pi, id_base + 3000 + @as(u64, pi), row_x, cy, row_w, ref);
            cy += row_h;
        }
    }

    if (scroll_max > 0) ui.drawScrollbar(x + w - 11, list_y, 5, list_h, st.scroll, content_h, list_h);
}

fn sectionLabel(ui: *Ui, text: []const u8, x: i32, y: i32, w: i32, count: i32) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s}（{d}）", .{ text, count }) catch text;
    ui.labelClipped(s, x + 2, y + 1, w - 4, ui.theme.text_dim);
    ui.renderer.hline(x, y + sect_h - 2, w, ui.theme.panel_border);
}

/// 「已链接」段的一行 = **一个参数**（同一个参数挂 N 条曲线也只占一行）
const LinkedRow = struct {
    target: view_lane.Target,
    /// 挂在这个参数上的曲线条数
    n: usize,
    /// 第一条曲线的 id（`n == 1` 时就是唯一那条；`n > 1` 时用于“曲线1 等N条”）
    first_curve: u32,
    /// 至少有一条启用中（决定绿色/灰色）
    enabled: bool,
};

/// **已链接**行：**参数名（主，绿）+ 曲线名/“等N条”（次，灰）+ 值 + `自动化`**
///
/// 语义：这一段的标题是“已链接”，主语是**参数**（一个参数可以挂多条曲线 → 仍**只占一行**）；
/// 所以主标签必须是参数名，曲线信息降为右侧的灰色旁注（多条时写 `xxx 等N条`）。
/// **本行不解绑**（用户拍板：已链接行只用来“看/进自动化”，
/// 解绑在自动化窗口的绑定行 `×` 里——一个动作一个地方）。
fn drawLinkedRow(ui: *Ui, app: *App, pl: *vst_host.Plugin, row: LinkedRow, id_base: u64, x: i32, y: i32, w: i32) void {
    const hovered = util.hitUI(ui, x, y, w, row_h - 1);
    if (hovered) ui.renderer.fillRect(x, y, w, row_h - 1, ui.theme.item_hover);
    ui.renderer.strokeRect(x, y, w, row_h - 1, ui.theme.panel_border);

    const value_w: i32 = 88;
    const bx_btn = x + w - menu_btn_w - 2;
    const pix_opt = pl.findParamIndex(row.target.param_id);

    // 参数值（只读：值是曲线算出来的）
    var value_left = bx_btn - 6;
    if (pix_opt) |pix| {
        var vb: [40]u8 = undefined;
        const vt = pl.paramText(pix, &vb);
        const vw: i32 = @min(value_w, @as(i32, @intFromFloat(ui.font.measure(vt))));
        value_left = bx_btn - 6 - vw;
        ui.labelClipped(vt, value_left, y + 2, vw + 2, ui.theme.auto_active);
    }

    // 主：**参数名**（绿 = 启用中 / 灰 = 整组都停用或参数已不存在）
    const pname: []const u8 = if (pix_opt) |pix| pl.params[pix].name() else "（参数不存在）";
    const name_w: i32 = @max(40, @divTrunc((value_left - x - 8) * 3, 5));
    ui.labelMiddle(pname, x + 4, y + 2, name_w, if (row.enabled) ui.theme.auto_active else ui.theme.text_dim);

    // 次：曲线信息（灰，中段省略）：单条 → 曲线名；多条 → `曲线名 等N条`
    {
        var cb: [48]u8 = undefined;
        var sb: [80]u8 = undefined;
        const cname = if (app.curveById(row.first_curve)) |lc| lc.name(&cb) else "（曲线已删除）";
        const label: []const u8 = if (row.n > 1)
            std.fmt.bufPrint(&sb, "{s} 等{d}条", .{ cname, row.n }) catch cname
        else
            cname;
        const cx = x + 4 + name_w + 8;
        const cw = value_left - cx - 6;
        if (cw > 12) ui.labelMiddle(label, cx, y + 2, cw, ui.theme.text_dim);
    }

    // `自动化` → 直接打开自动化窗口（深度/极性/反向/基础/平滑/解绑都在那）
    if (ui.button(id_base + 1, "自动化", bx_btn, y + 1, menu_btn_w, row_h - 3)) app.openAutoWin(row.target);

    // 行内右键：与普通参数行同一套菜单（恢复默认值 / 输入值… / 自动化…）
    if (!ui.mouse_pressed and util.hitUI(ui, x, y, w, row_h - 1) and ui.mouse_right_pressed) {
        openRowMenu(app, row.target.param_id, ui.mouse_x, ui.mouse_y);
    }
}

/// 普通参数行（最近改动 / 全部参数）：拖动改值 · 双击复位 · 右侧 `自动化` 按钮
fn drawParamRow(ui: *Ui, app: *App, pl: *vst_host.Plugin, pi: usize, id_base: u64, x: i32, y: i32, w: i32, ref: PluginSlotRef) void {
    const meta = &pl.params[pi];
    const target = app.targetForSlotParam(ref, meta.id);
    const bound = if (target) |t| app.isTargetBound(t) else false;
    // 绿色 = 自动化**真的在驱动它**（同混音台/机架：绑了但全部停用就不算）
    const active = if (target) |t| app.enabledBindingCount(t) > 0 else false;
    const rid: u64 = id_base + 1;

    const rw = w - menu_btn_w - 4;
    const hovered = util.hitUI(ui, x, y, rw, row_h - 1);
    ui.renderer.fillRect(x, y, rw, row_h - 1, if (ui.active_id == rid) ui.theme.item_hover else if (hovered) ui.theme.toolbar else ui.theme.panel);
    ui.renderer.strokeRect(x, y, rw, row_h - 1, ui.theme.panel_border);

    // 已链接 → 值只读（跟着曲线走）；未链接 → 拖/双击
    if (!bound) {
        var v = pl.paramNorm(pi);
        if (hovered and ui.mouse_double) {
            app.setPluginParamHost(ref, pl, pi, meta.default_norm);
        } else if (ui.dragNormV(rid, x, y, rw, row_h - 1, &v)) {
            if (meta.step_count > 0) {
                const steps: f64 = @floatFromInt(meta.step_count);
                v = @round(v * steps) / steps;
            }
            app.setPluginParamHost(ref, pl, pi, v);
        }
    }

    const value_w: i32 = 92;
    var vb: [40]u8 = undefined;
    const vt = pl.paramText(pi, &vb);
    const vw: i32 = @min(value_w, @as(i32, @intFromFloat(ui.font.measure(vt))));
    ui.labelClipped(vt, x + rw - 6 - vw, y + 2, vw + 2, if (active) ui.theme.auto_active else ui.theme.text);
    ui.labelClipped(meta.name(), x + 6, y + 2, rw - value_w - 20, if (active) ui.theme.auto_active else if (hovered) ui.theme.text else ui.theme.text_dim);

    // `自动化` → **直接打开自动化窗口**（同 `打开…`/`保存为…` 按钮的样式：不画箭头、不发灰）
    const bx = x + rw + 2;
    if (target) |t| {
        if (ui.button(id_base + 2, "自动化", bx, y + 1, menu_btn_w, row_h - 3)) app.openAutoWin(t);
    }
    // 行内右键：推子/旋钮同款三项菜单（恢复默认值 / 输入值… / 自动化…）
    if (!ui.mouse_pressed and util.hitUI(ui, x, y, rw, row_h - 1) and ui.mouse_right_pressed) {
        openRowMenu(app, meta.id, ui.mouse_x, ui.mouse_y);
    }
}

/// 打开本行的右键菜单（行内右键用；按钮已改成直接打开自动化窗口）
fn openRowMenu(app: *App, param_id: u32, x: i32, y: i32) void {
    const st = &app.vst_auto;
    st.menu_open = true;
    st.menu_just_opened = true; // 否则**打开它的那次点击**会在同帧把它关掉
    st.menu_param = param_id;
    st.menu_x = x;
    st.menu_y = y;
}

/// 行内菜单：**全项目统一的三项**（恢复默认值 > 输入值… > 自动化…），
/// 与右键推子/旋钮的菜单同款。
///
/// **必须在所有窗口之后单独画**（`drawApp` 之后、`endFrame` 前）：菜单展开时
/// `menuIsOpen()` 把窗口层全屏蔽了，画在窗口层里就点不到；坐标夹回屏幕——
/// 同一份代码被浮动窗口和 Linux 嵌入式面板共用，不能夹到某个窗口矩形。
pub fn drawMenu(ui: *Ui, app: *App) void {
    const st = &app.vst_auto;
    if (!st.menu_open) return;
    // 刚打开的那一帧：只画不判定（打开它的左键还在 `mouse_pressed` 上）
    const just = st.menu_just_opened;
    st.menu_just_opened = false;

    const pl = app.slotPlugin(st.ref) orelse {
        st.menu_open = false;
        return;
    };
    const pi = pl.findParamIndex(st.menu_param) orelse {
        st.menu_open = false;
        return;
    };
    const meta = &pl.params[pi];
    const target = app.targetForSlotParam(st.ref, st.menu_param) orelse {
        st.menu_open = false;
        return;
    };

    const items = [_][]const u8{ "恢复默认值", "输入值…", "自动化…" };
    const mh: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const scr_w = ui.renderer.logicalWidth();
    const scr_h = ui.renderer.logicalHeight();
    const mx = std.math.clamp(st.menu_x, 0, @max(0, scr_w - menu_w));
    const my = std.math.clamp(st.menu_y, 0, @max(0, scr_h - mh));
    ui.noteOverlayRect(mx, my, menu_w, mh); // 遮挡插件子窗口（这张表正是给菜单用的）
    ui.renderer.fillRect(mx, my, menu_w, mh, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, mh, ui.theme.accent);

    var hit: ?usize = null;
    var inside = false;
    for (items, 0..) |item, k| {
        const iy = my + 2 + @as(i32, @intCast(k)) * util.menu_item_h;
        const hov = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (hov) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(item, mx + 8, iy + 2, ui.theme.text);
        if (!just and hov and ui.mouse_pressed) hit = k;
    }

    if (hit) |k| {
        // 恢复默认值 / 输入值… 都直接作用于该插件槽（ref 已存于窗口状态）
        const slot_ref = st.ref;
        switch (k) {
            0 => app.setPluginParamHost(slot_ref, pl, pi, meta.default_norm), // 恢复默认值
            1 => {
                // 输入值…（按**百分比** 0..100 解析：与自动化窗口的基础值同一套手感）
                var vb: [16]u8 = undefined;
                const pre = std.fmt.bufPrint(&vb, "{d:.1}", .{pl.paramNorm(pi) * 100.0}) catch "";
                app.beginVstParamValueEdit(slot_ref, meta.id, pre, mx + 4, my + 4, menu_w - 8);
            },
            else => app.openAutoWin(target), // 自动化…
        }
        st.menu_open = false;
        ui.active_id = 0;
        return;
    }
    // 点菜单外 → 收起（打开它的那一帧不判）
    if (!just and ui.mouse_pressed and !inside and !util.inRect(ui.mouse_x, ui.mouse_y, mx, my, menu_w, mh)) {
        st.menu_open = false;
        ui.active_id = 0;
    }
}
