//! **自动化链接窗口**（一参数 ↔ 多曲线）
//!
//! 从混音台通道右键菜单的 `自动化…` 打开；管理“这个参数绑了哪些曲线、每条的深度/极性”。
//!
//! - 叠加语义：`参数 = clamp(静态推子 + Σ 深度 × (单向: v / 双向: 2v−1), 0, 1)`
//! - 每行：`[✓启用] 曲线名 · 极性 · 反向 · 基础值 · 深度 · 平滑(ms) · ×移除`
//! - 左键拖/点改值；**右键统一弹菜单**（恢复默认值 / 输入值…）
//! - 映射曲线**不做**（用户拍板：占位已删）
//!
//! 与“按曲线看”的播放列表行头列共享同一张绑定表（两个视角，互相同步）。

const std = @import("std");
const App = @import("app.zig").App;
const Ui = @import("ui.zig").Ui;
const model = @import("model.zig");
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");

pub const W: i32 = 448;
pub const H: i32 = 300;

const row_h: i32 = 34;
/// 表头行高（列标题：曲线 / 极性 / 反向 / 基础 / 深度 / 平滑）
const cap_h: i32 = 14;

// ── **一套几何**（强迫症版）：所有控件同高 `ctrl_h`、同间距 `gap`、同行内垂直居中 ──
const ctrl_h: i32 = 18; // 开关 / 按钮 / 推子 / × 全部 18 高
const ctrl_gap: i32 = 8; // 相邻控件水平间距（全行统一）
const row_pad: i32 = 6; // 行左右内边距
/// 控件在行内的 y（行内容高 = row_h−4，垂直居中）
fn ctrlY(row_y: i32) i32 {
    return row_y + @divTrunc(row_h - 4 - ctrl_h, 2);
}

/// 文本在 (cy, ctrl_h) 内垂直居中时的**顶边 y**（给需要裁剪的 `labelClipped` 用）。
/// 短标签直接用 `ui.labelCentered`（按 ascent/descent 算基线），两者视觉一致。
fn textTop(ui: *const Ui, cy: i32) i32 {
    const lh: i32 = @intFromFloat(ui.font.lineHeight());
    return cy + @divTrunc(ctrl_h - lh, 2);
}

/// 行内列偏移（相对行左边 x；`w` = 行宽）——**全由 `ctrl_gap` 递推**，不再手写数字
/// 列序：曲线开关 → 曲线名 → 极性 → 反向 → 基础 → 深度 → 平滑 → ×
const Col = struct {
    pub const on: i32 = row_pad;
    pub const name: i32 = on + ctrl_h + ctrl_gap;
    pub const name_w: i32 = 92;
    pub const pol: i32 = name + name_w + ctrl_gap;
    pub const btn_w: i32 = 40;
    pub const inv: i32 = pol + btn_w + ctrl_gap;
    pub const base: i32 = inv + btn_w + ctrl_gap;
    pub const base_w: i32 = 52;
    pub const depth: i32 = base + base_w + ctrl_gap;
    pub const depth_w: i32 = 56;
    pub const smooth: i32 = depth + depth_w + ctrl_gap;
    pub const smooth_w: i32 = 56;
    pub const del: i32 = smooth + smooth_w + ctrl_gap;
};

pub fn draw(ui: *Ui, app: *App) void {
    const win = &app.auto_win;
    if (!win.open) return;
    const w = W;
    const h = H;
    const x = win.x;
    const y = win.y;

    // 窗口底 + 边框 + 标题栏
    ui.renderer.fillRect(x, y, w, h, ui.theme.panel);
    ui.renderer.strokeRect(x, y, w, h, ui.theme.accent);
    ui.renderer.fillRect(x + 1, y + 1, w - 2, util.title_h - 1, ui.theme.toolbar);
    // **不要整窗登记 `noteOverlayRect`**：那张表是给菜单/弹层用的，
    // `syncEmbeddedEditor` 拿 `overlay_n != 0` 直接禁掉插件子窗口（输入闸门）→
    // 一开自动化窗口，插件的 GUI 就点不动了。窗口遮挡走 `win_draw_info`。

    // 标题缓冲要够大：`{乐器名} · {参数名}`（插件参数）或 `通道12 · 声像`
    // ——旧版本这里是 `[32]`，VST 参数拼接一超长就 `catch "插件参数"`
    // （实测：标题永远只剩“插件参数”）。
    const by_curve = win.view == .by_curve;
    var tb: [128]u8 = undefined;
    var nm: [96]u8 = undefined;
    const title = if (by_curve) blk: {
        const lc = app.curveById(win.curve_id) orelse {
            win.open = false; // 曲线被删了 → 自动关闭
            return;
        };
        break :blk std.fmt.bufPrint(&tb, "已链接项 · {s}", .{lc.name(&nm)}) catch "已链接项";
    } else blk: {
        const tname = targetName(app, win.target, &nm);
        break :blk std.fmt.bufPrint(&tb, "自动化 · {s}", .{tname}) catch "自动化";
    };
    // 中段省略：名字太长时保留两头（“自动化” + 参数名）
    ui.labelMiddle(title, x + 8, y + 4, w - 40, ui.theme.text);

    // 关闭按钮（全项目统一：`util.titleCloseButton`）
    if (util.titleCloseButton(ui, x, y, w, util.title_h)) win.open = false;

    // ── 状态行 ──
    // `by_target`：基准值 + 游标处合成值。**基准 = 绑定自己设的 `base`；没设 → 静态推子/旋钮值**
    // （音量/声像/插件参数都是这个规矩：链接曲线**不应改变**当前的值）。
    // `by_curve`：没有单一目标 → 显示**游标处曲线值** + 驱动了几个参数。
    {
        var sb: [160]u8 = undefined;
        const step: f32 = @floatFromInt(app.playback.cursorStep(true));
        const st: []const u8 = if (by_curve) blk: {
            const lc = app.curveById(win.curve_id) orelse break :blk "";
            const v = lc.evalAt(step);
            const nbind = app.bindingCountOfCurve(win.curve_id);
            break :blk if (v < 0)
                std.fmt.bufPrint(&sb, "游标处：无曲线点  ·  驱动 {d} 个参数", .{nbind}) catch ""
            else
                std.fmt.bufPrint(&sb, "游标处曲线值 {d:.2}  ·  驱动 {d} 个参数", .{ v, nbind }) catch "";
        } else blk: {
            const base = app.defaultBaseFor(win.target);
            const bipolar = view_lane.Target.defaultBipolar(win.target.kind);
            const v = app.autoValueFor(win.target, step, base);
            const kind_txt: []const u8 = switch (win.target.kind) {
                .master_vol => "主音量",
                .mixer_vol, .inst_vol => "音量",
                .mixer_pan, .inst_pan => "声像",
                .tempo => "速度（BPM）",
                .vst_param => "插件参数",
                .fx_param => "效果器参数",
                .kit_param => "鼓组层参数",
                .none => "未绑定",
            };
            const pol_txt: []const u8 = if (bipolar) "双向" else "单向";
            // **空曲线（已链接但还没画点）= 不接管**：状态行说清楚，否则用户会以为“链接了却没反应”
            if (app.isTargetBound(win.target) and !app.isTargetDriven(win.target)) {
                break :blk std.fmt.bufPrint(&sb, "已链接但**曲线为空** → 未接管（保持当前值，画一个点即开始）", .{}) catch "";
            }
            break :blk if (win.target.kind == .tempo)
                // BPM 用**真实的 bpm 数字**显示（归一化 0..1 对用户没意义）
                (if (app.isTargetBound(win.target))
                    std.fmt.bufPrint(&sb, "区间 {d:.0}~{d:.0} BPM  →  此刻 {d:.0} BPM", .{ model.bpm_min, model.bpm_max, view_lane.Target.bpmFromNorm(v) }) catch ""
                else
                    std.fmt.bufPrint(&sb, "区间 {d:.0}~{d:.0} BPM  →  尚未链接曲线（当前 {d} BPM）", .{ model.bpm_min, model.bpm_max, app.bpm }) catch "")
            else if (app.isTargetBound(win.target)) blk2: {
                // **音量类目标额外报 dB**（推子锥度：gain = (p/0.75)² ⇒ dB = 40·log10）；
                // 自动化是**位置域叠加**（默认：曲线最低点 = 静音、最高点 = +5 dB），所以“合成 dB”才是听感值。
                if (view_lane.Target.isVolume(win.target)) {
                    var db_buf: [16]u8 = undefined;
                    const dbt = view_lane.formatValue(.db, v, &db_buf);
                    break :blk2 std.fmt.bufPrint(&sb, "基准 {d:.2}（{s} · {s}）  →  合成 {d:.2}（{s} dB）", .{ base, kind_txt, pol_txt, v, dbt }) catch "";
                }
                break :blk2 std.fmt.bufPrint(&sb, "基准 {d:.2}（{s} · {s}）  →  合成 {d:.2}", .{ base, kind_txt, pol_txt, v }) catch "";
            } else std.fmt.bufPrint(&sb, "基准 {d:.2}（{s} · {s}）  →  尚未链接曲线（旋钮静值 {d:.2}）", .{ base, kind_txt, pol_txt, baseValueOf(app, win.target) }) catch "";
        };
        ui.labelClipped(st, x + 8, y + util.title_h + 4, w - 16, ui.theme.text_dim);
    }

    // ── 绑定行 ──
    var binds_buf: [32]view_lane.Binding = undefined;
    const binds = if (by_curve)
        app.bindingsOfCurve(win.curve_id, &binds_buf)
    else
        app.bindingsOfTarget(win.target, &binds_buf);
    const cap_top = y + util.title_h + 20;
    const list_top = cap_top + cap_h;
    // `by_curve` 没有底部按钮行 → 列表用满高度
    const list_bottom = if (by_curve) y + h - 8 else y + h - 34;
    const list_h = @max(row_h, list_bottom - list_top);
    // 列标题（与行内控件**同一个居中算法**：标题中心 = 控件中心 → 首字尽量对齐）
    {
        const capX = struct {
            fn f(ui_: *const Ui, box_x: i32, box_w: i32, text: []const u8) i32 {
                const tw: i32 = @intFromFloat(ui_.font.measure(text));
                return box_x + @divTrunc(box_w - tw, 2);
            }
        }.f;
        ui.labelClipped(if (by_curve) "参数" else "曲线", x + 4 + Col.name, cap_top, 90, ui.theme.text_dim);
        ui.labelClipped("极性", capX(ui, x + 4 + Col.pol, Col.btn_w, "极性"), cap_top, 44, ui.theme.text_dim);
        ui.labelClipped("反向", capX(ui, x + 4 + Col.inv, Col.btn_w, "反向"), cap_top, 44, ui.theme.text_dim);
        ui.labelClipped("基础", capX(ui, x + 4 + Col.base, Col.base_w, "基础"), cap_top, 46, ui.theme.text_dim);
        ui.labelClipped("深度", capX(ui, x + 4 + Col.depth, Col.depth_w, "深度"), cap_top, 46, ui.theme.text_dim);
        ui.labelClipped("平滑", capX(ui, x + 4 + Col.smooth, Col.smooth_w, "平滑"), cap_top, 46, ui.theme.text_dim);
    }
    const view_rows: i32 = @max(1, @divTrunc(list_h, row_h));
    const content_rows: i32 = @intCast(binds.len);
    const max_scroll: i32 = @max(0, content_rows - view_rows);
    if (util.inRect(ui.mouse_x, ui.mouse_y, x + 4, list_top, w - 14, list_h) and ui.wheel != 0 and max_scroll > 0) {
        win.rows_scroll = std.math.clamp(win.rows_scroll - ui.wheel, 0, max_scroll);
        ui.wheel = 0;
    }
    win.rows_scroll = std.math.clamp(win.rows_scroll, 0, max_scroll);
    if (binds.len == 0) {
        ui.labelClipped(
            if (by_curve) "这条曲线还没链接任何参数 —— 用混音台/机架/VST 参数行的「自动化…」链接" else "尚未链接任何曲线 —— 用下方按钮链接或新建",
            x + 10,
            list_top + 8,
            w - 20,
            ui.theme.text_dim,
        );
    }
    {
        var k: i32 = 0;
        var idx: usize = @intCast(win.rows_scroll);
        var ry = list_top;
        while (idx < binds.len and k < view_rows) : (idx += 1) {
            const b = binds[idx];
            const bi = app.bindingIndex(b.curve_id, b.target) orelse continue;
            if (by_curve) {
                // 第 1 列 = **参数名**
                var nb: [96]u8 = undefined;
                const label = targetName(app, b.target, &nb);
                drawRow(ui, app, bi, label, x + 4, ry, w - 8);
            } else {
                // 第 1 列 = **曲线名**
                const lc = app.curveById(b.curve_id) orelse continue;
                var nb: [48]u8 = undefined;
                drawRow(ui, app, bi, lc.name(&nb), x + 4, ry, w - 8);
            }
            ry += row_h;
            k += 1;
        }
        if (content_rows > view_rows) {
            ui.drawScrollbar(x + w - 8, list_top, 5, list_h, win.rows_scroll * row_h, content_rows * row_h, list_h);
        }
    }

    // ── 底部操作：`+ 新曲线并链接` / `链接到曲线…`（下拉，避免平铺溢出）──
    // **`by_curve` 视角不要底部按钮**（用户拍板）：曲线已经有了，反向链接（选参数）暂不做——
    // VST 参数在“参数视角”里链，固定目标在混音台/机架里链，绑定本就是双向的。
    const by = y + h - 30;
    if (!by_curve) {
        ui.renderer.hline(x + 4, by - 4, w - 8, ui.theme.panel_border);
        {
            const bw1: i32 = 116;
            const hovered1 = util.inRect(ui.mouse_x, ui.mouse_y, x + 8, by, bw1, 22);
            ui.renderer.fillRect(x + 8, by, bw1, 22, if (hovered1) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(x + 8, by, bw1, 22, ui.theme.panel_border);
            ui.labelClipped("+ 新曲线并链接", x + 12, by + 5, bw1 - 8, ui.theme.text);
            if (hovered1 and ui.mouse_pressed) {
                // **新曲线 = 空曲线**：不猜用户想先在哪加点；空曲线不接管 → 听感不变
                if (app.addAutoCurveForTarget(win.target) != null) {
                    app.setToast("已新建空曲线并链接（画点开始生效）");
                    app.commitHistory("新建自动化曲线");
                }
            }

            const bx2 = x + 8 + bw1 + 8;
            const bw2: i32 = 116;
            const hovered2 = util.inRect(ui.mouse_x, ui.mouse_y, bx2, by, bw2, 22);
            ui.renderer.fillRect(bx2, by, bw2, 22, if (hovered2 or win.pick_open) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(bx2, by, bw2, 22, ui.theme.panel_border);
            ui.labelClipped("链接到曲线", bx2 + 8, by + 5, bw2 - 26, ui.theme.text);
            util.menuArrow(ui, bx2 + bw2 - 18, by + @divTrunc(22 - util.menu_arrow_h, 2), ui.theme.text_dim); // 字体缺 ▾ → 自绘
            if (hovered2 and ui.mouse_pressed) {
                win.pick_open = !win.pick_open;
                win.pick_scroll = 0;
            }
            const link_btn = Rect{ .x = bx2, .y = by, .w = bw2, .h = 22 };
            if (win.pick_open) drawPickList(ui, app, x, by - 6, w, link_btn);
        }
    }

    // 拖标题栏移动（按下记“鼠标 − 窗口左上”的偏移；按住期间反算）
    {
        const id = Ui.idOf("auto_win_title", 0);
        if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, w - 24, util.title_h) and ui.mouse_pressed) {
            ui.active_id = id;
            win.drag_dx = ui.mouse_x - win.x;
            win.drag_dy = ui.mouse_y - win.y;
        }
        if (ui.active_id == id) {
            if (ui.mouse_down) {
                win.x = ui.mouse_x - win.drag_dx;
                win.y = ui.mouse_y - win.drag_dy;
            } else ui.active_id = 0;
        }
    }

    // 行内右键菜单：**最后一次绘制**（盖在行/底部按钮之上，不会被它们挡或抢命中）
    // 展开时解除全局屏蔽——`menuIsOpen()` 计入 `ctx_row`，不解除的话菜单自己点不到
    // （菜单本体用裸 `inRect` 收点击；上方行控件用 `hitUI` 已被屏蔽）。
    if (app.auto_win.ctx_row != null) ui.input_blocked = false;
    drawRowCtxMenu(ui, app);
}

/// 一行绑定：`[✓] [曲线名/参数名] [极性] [反向] [基础] [深度] [平滑] [×]`
/// `label` = 第 1 列文字（`by_target` → 曲线名；`by_curve` → 参数名）。
/// **几何只有一个来源**：控件同高 `ctrl_h`、同间距 `ctrl_gap`、同行内用 `ctrlY` 垂直居中、
/// 文本一律用 `labelCentered`（按字体 ascent/descent 居中）——不要再手写 `+8 / +3` 之类。
fn drawRow(ui: *Ui, app: *App, bi: usize, label: []const u8, x: i32, y: i32, w: i32) void {
    const b = &app.auto_bindings.items[bi];
    const row_bg = if (b.enabled) ui.theme.item_alt else ui.theme.toolbar;
    ui.renderer.fillRect(x, y, w, row_h - 4, row_bg);
    const cy = ctrlY(y);

    // 启用开关（方形；开 = 蓝，关 = 灰）
    {
        const bx = x + Col.on;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx, cy, ctrl_h, ctrl_h);
        ui.renderer.fillRect(bx, cy, ctrl_h, ctrl_h, if (b.enabled) ui.theme.accent else ui.theme.slider_track);
        ui.renderer.strokeRect(bx, cy, ctrl_h, ctrl_h, ui.theme.panel_border);
        if (hovered and ui.mouse_pressed) {
            b.enabled = !b.enabled;
            app.commitHistory(if (b.enabled) "启用自动化绑定" else "停用自动化绑定");
        }
    }

    // 曲线名（点击 → 切到播放列表编辑这条曲线；垂直居中同其他控件）
    {
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, x + Col.name, cy, Col.name_w, ctrl_h);
        if (hovered) ui.renderer.fillRect(x + Col.name, cy, Col.name_w, ctrl_h, ui.theme.item_hover);
        // 名字可能超宽 → **中段省略**（头…尾），垂直居中由 `textTop` 算
        ui.labelMiddle(label, x + Col.name, textTop(ui, cy), Col.name_w, if (hovered) ui.theme.accent else if (b.enabled) ui.theme.text else ui.theme.text_dim);
        // 点击名字：两个视角都“选中这条曲线”（播放列表高亮的那条），行为一致
        if (hovered and ui.mouse_pressed) app.auto_sel = b.curve_id;
    }

    // **极性**（单向 / 双向）——左键切换；右键菜单
    {
        const px = x + Col.pol;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, px, cy, Col.btn_w, ctrl_h);
        ui.renderer.fillRect(px, cy, Col.btn_w, ctrl_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(px, cy, Col.btn_w, ctrl_h, ui.theme.panel_border);
        const txt: []const u8 = if (b.bipolar) "双向" else "单向";
        const tw: i32 = @intFromFloat(ui.font.measure(txt));
        ui.labelCentered(txt, px + @divTrunc(Col.btn_w - tw, 2), cy, ctrl_h, if (b.bipolar) ui.theme.accent else ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            b.bipolar = !b.bipolar;
            app.commitHistory("切换自动化极性");
        }
        if (hovered and ui.mouse_right_pressed) openCtx(app, ui, bi, .bipolar);
    }

    // **反向**（与极性独立）：单向+反向 = ducking（曲线越高，参数压得越低）
    {
        const ix = x + Col.inv;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, ix, cy, Col.btn_w, ctrl_h);
        ui.renderer.fillRect(ix, cy, Col.btn_w, ctrl_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(ix, cy, Col.btn_w, ctrl_h, ui.theme.panel_border);
        const txt: []const u8 = if (b.invert) "反向" else "正常";
        const tw: i32 = @intFromFloat(ui.font.measure(txt));
        // 两种状态都是白字（只靠颜色强调：开 = 橙）
        ui.labelCentered(txt, ix + @divTrunc(Col.btn_w - tw, 2), cy, ctrl_h, if (b.invert) ui.theme.accent else ui.theme.text);
        if (hovered and ui.mouse_pressed) {
            b.invert = !b.invert;
            app.commitHistory("切换自动化反向");
        }
        if (hovered and ui.mouse_right_pressed) openCtx(app, ui, bi, .invert);
    }

    // **基础值**（归一化 0..1，上下拖数字）：一律白字
    {
        const bx0 = x + Col.base;
        var val: f32 = b.base orelse app.defaultBaseFor(b.target);
        if (ui.dragNumberF(Ui.idOf("auto_win_base", 0) + bi, bx0, cy, Col.base_w, ctrl_h, &val, 0.0, 1.0, 1)) {
            b.base = val;
            app.history_pending = "调整自动化基础值";
        }
        if (util.inRect(ui.mouse_x, ui.mouse_y, bx0, cy, Col.base_w, ctrl_h) and ui.mouse_right_pressed) {
            openCtx(app, ui, bi, .base);
        }
    }

    // **深度**（上下拖数字，0% ~ 200%，中点 = 100%；单位画在控件内，避免和下一列叠住）
    {
        const sx = x + Col.depth;
        var pct: i32 = @intFromFloat(@round(b.depth * 100.0));
        if (ui.dragNumberEx(Ui.idOf("auto_win_depth", 0) + bi, sx, cy, Col.depth_w, ctrl_h, &pct, 0, @intFromFloat(view_lane.depth_max * 100.0), 4, 0, fmtPct)) {
            b.depth = @as(f32, @floatFromInt(pct)) / 100.0;
            app.history_pending = "调整自动化深度";
        }
        if (util.inRect(ui.mouse_x, ui.mouse_y, sx, cy, Col.depth_w, ctrl_h) and ui.mouse_right_pressed) {
            openCtx(app, ui, bi, .depth);
        }
    }

    // **平滑**（极点追赶时间常数 ms）：0 = 不追赶（默认）；上限 200
    // **所有目标通用**（含 tempo）：tempo 的求值已在块级/帧级带 `dt_s`（见 `App.applyTempoAt`），
    // v2 之后不再有"帧粒度只剩 1 帧"的问题，所以不必置灰。
    {
        const sx = x + Col.smooth;
        var ms: i32 = @intFromFloat(@round(b.smooth_ms));
        if (ui.dragNumberEx(Ui.idOf("auto_win_smooth", 0) + bi, sx, cy, Col.smooth_w, ctrl_h, &ms, 0, @intFromFloat(view_lane.smooth_ms_max), 6, 0, fmtMs)) {
            b.smooth_ms = @floatFromInt(ms);
            app.history_pending = "调整自动化平滑";
        }
        if (util.inRect(ui.mouse_x, ui.mouse_y, sx, cy, Col.smooth_w, ctrl_h) and ui.mouse_right_pressed) {
            openCtx(app, ui, bi, .smooth);
        }
    }

    // 移除（右侧贴边；与其它控件同高同 y）
    {
        const rx = x + Col.del;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, rx, cy, ctrl_h, ctrl_h);
        if (hovered) ui.renderer.fillRect(rx, cy, ctrl_h, ctrl_h, ui.theme.item_hover);
        const tw: i32 = @intFromFloat(ui.font.measure("×"));
        ui.labelCentered("×", rx + @divTrunc(ctrl_h - tw, 2), cy, ctrl_h, if (hovered) ui.theme.danger else ui.theme.text_dim);
        if (hovered and ui.mouse_pressed) {
            // **用行自己的 target**（不是 `win.target`：`by_curve` 视角下它没意义）
            if (app.unbindCurveTarget(b.curve_id, b.target)) {
                app.setToast("已取消链接");
                app.commitHistory("取消自动化链接");
            }
        }
    }
}

/// 行内数值控件的显示格式：“100%” / “15ms”（把单位画在同一个控件里，避免和下一列重叠）
fn fmtPct(v: i32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{v}) catch "";
}
fn fmtMs(v: i32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}ms", .{v}) catch "";
}

/// 打开行内右键菜单（记下哪一条绑定的哪个控件）
fn openCtx(app: *App, ui: *Ui, bi: usize, field: @TypeOf(app.auto_win.ctx_field)) void {
    app.auto_win.ctx_row = bi;
    app.auto_win.ctx_field = field;
    app.auto_win.ctx_x = ui.mouse_x;
    app.auto_win.ctx_y = ui.mouse_y;
}

/// 行内右键菜单：`恢复默认值` / `输入值…`（极性只有前者）
fn drawRowCtxMenu(ui: *Ui, app: *App) void {
    const win = &app.auto_win;
    const bi = win.ctx_row orelse return;
    if (win.ctx_field == .none) return;
    if (bi >= app.auto_bindings.items.len) {
        win.ctx_row = null;
        return;
    }
    const b = &app.auto_bindings.items[bi];
    const has_input = win.ctx_field != .bipolar and win.ctx_field != .invert;
    const items = if (has_input)
        [_][]const u8{ "恢复默认值", "输入值…" }
    else
        [_][]const u8{ "恢复默认值", "" };
    const n_items: usize = if (has_input) 2 else 1;
    const menu_w: i32 = 128;
    const menu_h: i32 = @as(i32, @intCast(n_items)) * util.menu_item_h + 4;
    // **夹回窗口内**：菜单不能被窗口边缘截断，也不能跑到窗口外
    // （窗口层是 NoClip 绘制、输入屏蔽只按窗口矩形——跑出去会“看得见但点不到”，
    //  更糟的是点到下面的视图）
    const mx = std.math.clamp(win.ctx_x, win.x + 4, win.x + W - menu_w - 4);
    const my = std.math.clamp(win.ctx_y, win.y + util.title_h + 2, win.y + H - menu_h - 4);
    ui.renderer.fillRect(mx, my, menu_w, menu_h, ui.theme.panel);
    ui.renderer.strokeRect(mx, my, menu_w, menu_h, ui.theme.accent);
    ui.noteOverlayRect(mx, my, menu_w, menu_h);

    var clicked: ?usize = null;
    var inside = false;
    for (items[0..n_items], 0..) |it, k| {
        const iy = my + 2 + @as(i32, @intCast(k)) * util.menu_item_h;
        const hov = util.inRect(ui.mouse_x, ui.mouse_y, mx + 1, iy, menu_w - 2, util.menu_item_h);
        if (hov) {
            inside = true;
            ui.renderer.fillRect(mx + 1, iy, menu_w - 2, util.menu_item_h, ui.theme.item_hover);
        }
        ui.label(it, mx + 8, iy + 2, ui.theme.text);
        if (hov and ui.mouse_pressed) clicked = k;
    }
    if (clicked) |k| {
        if (k == 0) {
            // 恢复默认值
            switch (win.ctx_field) {
                .base => {
                    if (b.base != null) {
                        b.base = null;
                        app.commitHistory("恢复自动化基础值");
                    }
                },
                .depth => {
                    const d = view_lane.Target.defaultDepth(b.target.kind);
                    if (b.depth != d) {
                        b.depth = d;
                        app.commitHistory("恢复自动化深度");
                    }
                },
                .smooth => {
                    if (b.smooth_ms != view_lane.default_smooth_ms) {
                        b.smooth_ms = view_lane.default_smooth_ms;
                        app.commitHistory("恢复自动化平滑");
                    }
                },
                .bipolar => {
                    const v = view_lane.Target.defaultBipolar(b.target.kind);
                    if (b.bipolar != v) {
                        b.bipolar = v;
                        app.commitHistory("恢复自动化极性");
                    }
                },
                .invert => {
                    if (b.invert) {
                        b.invert = false;
                        app.commitHistory("恢复自动化反向");
                    }
                },
                .none => {},
            }
        } else {
            // 输入值…（预填当前值，单位：基础/深度 = 百分比，平滑 = 整数 ms）
            var vb: [24]u8 = undefined;
            switch (win.ctx_field) {
                .base => {
                    const v = b.base orelse app.defaultBaseFor(b.target);
                    const pre = view_lane.formatValue(.percent, v, &vb);
                    app.beginEditAutomationBase(bi, pre, mx + 4, my + 4, menu_w - 8);
                },
                .depth => {
                    const v = std.math.clamp(b.depth / view_lane.depth_max, 0.0, 1.0);
                    const pre = view_lane.formatValue(.percent, v, &vb);
                    app.beginEditAutomationDepth(bi, pre, mx + 4, my + 4, menu_w - 8);
                },
                .smooth => {
                    const pre = std.fmt.bufPrint(&vb, "{d}", .{@as(i32, @intFromFloat(@round(b.smooth_ms)))}) catch "";
                    app.beginEditAutomationSmooth(bi, pre, mx + 4, my + 4, menu_w - 8);
                },
                .bipolar, .invert, .none => {},
            }
        }
        win.ctx_row = null;
        win.ctx_field = .none;
    } else if (ui.mouse_pressed and !inside and !util.inRect(ui.mouse_x, ui.mouse_y, mx, my, menu_w, menu_h)) {
        win.ctx_row = null;
        win.ctx_field = .none;
    }
}

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// 「链接到曲线…」下拉：列出**尚未绑定到本参数**的曲线（可滚轮滚动）。
/// 曲线多时不再平铺（旧设计会把窗口撑爆）。点条目 = 绑定；点面板外 = 只关下拉。
fn drawPickList(ui: *Ui, app: *App, win_x: i32, above_y: i32, win_w: i32, btn: Rect) void {
    const win = &app.auto_win;
    const row: i32 = 20;
    const panel_w: i32 = win_w - 16;
    const pick_rows_max: i32 = 6;
    var avail: usize = 0;
    for (app.auto_curves.items) |*lc| {
        if (app.bindingIndex(lc.id, win.target) == null) avail += 1;
    }
    const rows: i32 = @intCast(@min(avail, @as(usize, @intCast(pick_rows_max))));
    const ph: i32 = @max(row, rows * row + 4);
    const px = win_x + 8;
    // **夹回窗口内**（默认向上弹，空间不够就往下走）——同行内右键菜单：
    // 窗口层 NoClip 绘制但输入屏蔽只按窗口矩形，贴到窗口外会“看得见点不到”。
    const py = std.math.clamp(above_y - ph, win.y + util.title_h + 2, win.y + H - ph - 4);

    ui.renderer.fillRect(px, py, panel_w, ph, ui.theme.panel);
    ui.renderer.strokeRect(px, py, panel_w, ph, ui.theme.accent);
    ui.noteOverlayRect(px, py, panel_w, ph);

    if (avail == 0) {
        ui.labelClipped("（没有可链接的曲线——用左边按钮新建）", px + 8, py + 4, panel_w - 12, ui.theme.text_dim);
    }

    // 滚轮
    if (util.inRect(ui.mouse_x, ui.mouse_y, px, py, panel_w, ph) and ui.wheel != 0) {
        win.pick_scroll = std.math.clamp(win.pick_scroll - ui.wheel, 0, @max(0, @as(i32, @intCast(avail)) - pick_rows_max));
        ui.wheel = 0;
    }

    var k: i32 = 0;
    var shown: i32 = 0;
    var hit: ?u32 = null;
    for (app.auto_curves.items) |*lc| {
        if (app.bindingIndex(lc.id, win.target) != null) continue;
        if (shown < win.pick_scroll) {
            shown += 1;
            continue;
        }
        if (k >= pick_rows_max) break;
        const iy = py + 2 + k * row;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, px + 1, iy, panel_w - 2, row);
        if (hovered) ui.renderer.fillRect(px + 1, iy, panel_w - 2, row, ui.theme.item_hover);
        var nb: [24]u8 = undefined;
        const nm = lc.name(&nb);
        ui.labelClipped(nm, px + 8, iy + 3, panel_w - 14, ui.theme.text);
        if (hovered and ui.mouse_pressed) hit = lc.id;
        k += 1;
        shown += 1;
    }

    if (avail > @as(usize, @intCast(pick_rows_max))) {
        ui.drawScrollbar(px + panel_w - 6, py + 2, 5, ph - 4, win.pick_scroll * row, @as(i32, @intCast(avail)) * row, ph - 4);
    }
    if (hit) |cid| {
        if (app.bindCurveTarget(cid, win.target)) {
            app.setToast("已链接曲线");
            app.commitHistory("链接自动化曲线");
        }
        win.pick_open = false;
    } else if (ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, px, py, panel_w, ph) and
        !util.inRect(ui.mouse_x, ui.mouse_y, btn.x, btn.y, btn.w, btn.h))
    {
        win.pick_open = false; // 点下拉之外（且不是那个按钮）→ 只收下拉
    }
}

/// 目标显示名（主通道 / 通道N · 音量|声像）
fn targetName(app: *const App, t: view_lane.Target, buf: []u8) []const u8 {
    switch (t.kind) {
        .none => return "未绑定",
        .master_vol => return "主通道 · 音量",
        .tempo => return "速度（BPM）",
        .mixer_vol, .mixer_pan => {
            const suffix: []const u8 = if (t.kind == .mixer_vol) "音量" else "声像";
            const idx = app.channelIndexByUid(t.uid) orelse return std.fmt.bufPrint(buf, "通道? · {s}", .{suffix}) catch "通道";
            var nb: [24]u8 = undefined;
            const nm = app.mixer_channels_state.items[idx].displayName(idx, &nb);
            return std.fmt.bufPrint(buf, "{s} · {s}", .{ nm, suffix }) catch nm;
        },
        .inst_vol, .inst_pan => {
            const suffix: []const u8 = if (t.kind == .inst_vol) "音量" else "声像";
            const idx = app.instrumentIndexByUid(t.uid) orelse return std.fmt.bufPrint(buf, "乐器? · {s}", .{suffix}) catch "乐器";
            return std.fmt.bufPrint(buf, "{s} · {s}", .{ app.instruments.items[idx].name, suffix }) catch "乐器";
        },
        .vst_param => return app.vstParamLabel(t, buf),
        .fx_param => return app.fxParamLabel(t, buf),
        .kit_param => return app.kitParamLabel(t, buf),
    }
}

/// 该参数的静态基准值（推子/旋钮当前值）
fn baseValueOf(app: *const App, t: view_lane.Target) f32 {
    switch (t.kind) {
        .master_vol => return if (app.mixer_channels_state.items.len > 0) app.mixer_channels_state.items[0].volume else 0.8,
        .mixer_vol, .mixer_pan => {
            const idx = app.channelIndexByUid(t.uid) orelse return 0.8;
            const mc = &app.mixer_channels_state.items[idx];
            return if (t.kind == .mixer_vol) mc.volume else mc.pan;
        },
        .inst_vol, .inst_pan => {
            const idx = app.instrumentIndexByUid(t.uid) orelse return 0.8;
            const inst = &app.instruments.items[idx];
            return if (t.kind == .inst_vol) inst.volume else inst.pan;
        },
        .tempo => return view_lane.Target.normFromBpm(app.bpm),
        .vst_param => {
            const r = app.vstParamResolve(t) orelse return 0.0;
            return @floatCast(r.pl.paramNorm(r.param_idx));
        },
        .fx_param => {
            const r = app.fxParamResolve(t) orelse return 0.0;
            return @floatCast(r.pl.paramNorm(r.param_idx));
        },
        .kit_param => {
            const r = app.kitParamResolve(t) orelse return 0.0;
            return @floatCast(r.pl.paramNorm(r.param_idx));
        },
        .none => return 0.0,
    }
}
