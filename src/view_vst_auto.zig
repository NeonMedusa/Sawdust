//! **VST 参数自动化**（v1 起步于 UI 侧施加，v2 起求值在音频线程）
//!
//! 一个乐器一个窗口，三段式（像常见 DAW 的“参数列表”）：
//!
//! 1. **已链接**：这个乐器上已有绑定的参数（**绿色**——值由曲线决定，拖动时变**橙**表示“现在听你的”）；
//!    **链接了也照样能拖**（touch 语义：拖动期间该车道临时下线，松手曲线立刻接手；§11.48 结论）；
//! 2. **最近改动**：用户最近动过的 10 个参数（取自插件 `edit_ring` 的 `performEdit`，
//!    见 `App.noteVstParamTouched`）；
//! 3. **全部参数**：插件报的全表（带搜索框；`kIsReadOnly` 不列）。
//!
//! 每行右侧 `自动化` 按钮 = **直接打开自动化窗口**（深度/极性/反向/基础/平滑/解绑都在那）；
//! **链接管理菜单在行内右键**：新建曲线并链接 / 链接到已有曲线… / 打开自动化… / 取消链接。
//! （参数 ↔ 曲线是**多对多**：同一参数可挂多条曲线，同一曲线可驱多个参数。）
//!
//! 入口：
//! - Windows：乐器窗口标题栏 `自动化` 按钮 → 浮动窗口（`draw`）；
//! - Linux：插件面板正文直接是本文件的 `drawBody`（编辑器是独立窗口，正文空着）。
//!
//! 求值施加在**音频线程**（`LaneSet.collectPluginParams` 每段取段首/段末两点 →
//! `queueAuto` 逐绑定极点平滑；v1 时代的 UI 侧每帧直写已退役）。

const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const PluginSlotRef = app_mod.PluginSlotRef;
const Ui = @import("ui.zig").Ui;
const util = @import("view_util.zig");
const view_lane = @import("view_lane.zig");
const vst_host = @import("vst_host.zig");

pub const W: i32 = 560;
pub const H: i32 = 540;
/// 窗口最小尺寸（`main.winRectOf` 与 `draw` 的钳制下限**必须一致**）
pub const min_w: i32 = 300;
pub const min_h: i32 = 220;

/// 行高 / 分段标题高
const row_h: i32 = 18;
const sect_h: i32 = 16;
const title_h: i32 = util.title_h;

/// **窗口高度**：内置乐器（无插件）只有 3 行 MIDI 段 → 不必 540 高（省得大片空白）。
/// `draw` 与 `main.winRectOf` 都引用它（**两边必须一致**，否则命中区与画面错位）。
pub fn heightFor(app: *const App) i32 {
    const st = &app.vst_auto;
    if (st.inst_uid != 0 and app.slotPlugin(st.ref) == null) {
        const midi_rows: i32 = @intCast(midi_specs.len);
        // 标题 + 搜索框(6+18+6) + 分段标题(sect_h) + N 行 + 底边距
        return @min(H, title_h + 6 + 18 + 6 + sect_h + midi_rows * row_h + 10);
    }
    return H;
}

/// 浮动窗口的控件 id 段（Linux 嵌入式用 `9600 + 2000` 之类，互不撞车）
const id_win: u64 = 12000;

/// **参数表 id 空间**：
/// 旧写法“每行隔 1 个号 + 行内偏移 5000/5500”在参数 > 500 时必然跨行撞号；
/// 现在：每行 `row_stride` 个号（拖动 = row_id，按钮 = row_id+1），
/// 分段与宿主（`App.hostIdBase`）都用百万级间距（一个分段可容 50 万参数）。
const row_stride: u64 = 2;
const sec_stride: u64 = 1_000_000;

/// 分段编号（每段一个百万区间）
const sec_midi: u64 = 0;
const sec_linked: u64 = 1;
const sec_recent: u64 = 2;
const sec_all: u64 = 3;

/// 某个控件行的 id（`row` = 该段内的**行序号**（MIDI = kind 序号、已链接 = 组号、
/// 最近 = 行序、全部 = 参数下标））
inline fn rowId(host: app_mod.AutoTableHost, section: u64, row: usize) u64 {
    return app_mod.hostIdBase(host) + section * sec_stride + @as(u64, row) * row_stride;
}

/// 行内 `自动化` 按钮宽
const menu_btn_w: i32 = 56;
const menu_w: i32 = 132;

/// **乐器参数**（§11.47；原名“MIDI 通道参数”）：与插件无关的三项，**所有乐器都有**。
/// 命名理由：这三行只满足“宿主对所有乐器统一施加”（音量=宿主增益、声像=宿主平衡、
/// 音高=标准 129 映射 + 内置合成器自身实现）；bend range 之类“只有内置才有”的不进表。
const MidiSpec = struct { label: []const u8, alias: []const u8, kind: view_lane.Target.Kind };
const midi_specs = [_]MidiSpec{
    .{ .label = "音量", .alias = "volume vol level", .kind = .inst_vol },
    .{ .label = "声像", .alias = "pan 声像 平衡", .kind = .inst_pan },
    .{ .label = "音高（Pitch Bend）", .alias = "pitch bend 音高 弯音", .kind = .pitch_bend },
};

/// 搜索匹配（空格分词、全命中 AND、大小写不敏感；空串 = 全中）
fn midiMatch(sp: MidiSpec, q: []const u8) bool {
    if (q.len == 0) return true;
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |tok| {
        if (std.ascii.findIgnoreCase(sp.label, tok) == null and
            std.ascii.findIgnoreCase(sp.alias, tok) == null) return false;
    }
    return true;
}

/// 可见的 MIDI 行数（搜索后）
fn midiVisibleCount(q: []const u8) i32 {
    var n: i32 = 0;
    for (midi_specs) |sp| {
        if (midiMatch(sp, q)) n += 1;
    }
    return n;
}

/// 画「乐器参数」段；返回更新后的 `cy`。
/// 独立成函数的原因：乐器级入口（内置合成器/鼓组）**没有插件**，
/// `drawBody` 在无插件时会整段 return —— MIDI 段必须在它之前就能画（§11.47 A）。
fn drawMidiSection(
    ui: *Ui,
    app: *App,
    inst_uid: u32,
    q: []const u8,
    row_x: i32,
    cy_in: i32,
    row_w: i32,
    list_top: i32,
    list_bot: i32,
    host: app_mod.AutoTableHost,
    t: *app_mod.AutoTableState,
) i32 {
    var cy = cy_in;
    if (inst_uid == 0) return cy;
    const n = midiVisibleCount(q);
    if (n == 0) return cy;
    // 折叠：点标题行切换；**有搜索词时强制展开**（否则结果藏在折叠组里 = “搜不到”）
    const folded = t.midi_fold and q.len == 0;
    sectionLabel(ui, "乐器参数", row_x, cy, row_w, n);
    if (util.hitUI(ui, row_x, cy, row_w, sect_h) and ui.mouse_pressed) {
        t.midi_fold = !t.midi_fold;
        ui.active_id = 0; // 防标题/行拖动被误触发
    }
    cy += sect_h;
    if (folded) return cy;
    for (midi_specs) |sp| {
        if (!midiMatch(sp, q)) continue;
        const visible = cy + row_h > list_top and cy < list_bot;
        if (visible) {
            const tgt = view_lane.Target{ .kind = sp.kind, .uid = inst_uid };
            const inst_idx = app.instrumentIndexByUid(inst_uid) orelse 0;
            // 鼓组不弯音（打击乐；设计稿 §11.46 D）→ 音高行灰显，不给交互
            const drum_no_bend = sp.kind == .pitch_bend and inst_idx < app.instruments.items.len and
                app.instruments.items[inst_idx].kind == .drumkit;
            if (drum_no_bend) {
                ui.renderer.strokeRect(row_x, cy, row_w - menu_btn_w - 4, row_h - 1, ui.theme.panel_border);
                ui.labelClipped(sp.label, row_x + 6, cy + 3, row_w - 90, ui.theme.text_dim);
                ui.labelClipped("不适用", row_x + row_w - menu_btn_w - 12, cy + 3, 56, ui.theme.text_dim);
            } else {
                // 音量/声像/音高全走同一套行渲染。
                // 每行**独立 id**（`rowId`：每行两个号，分段/宿主都有百万级间距）
                drawAutoRow(ui, app, tgt, sp.label, .{ .inst = .{ .idx = inst_idx, .kind = sp.kind } }, rowId(host, sec_midi, @intCast(@backingInt(sp.kind))), row_x, cy, row_w, true);
            }
        }
        cy += row_h;
    }
    return cy;
}

/// **参数值（UI 口径）**：优先读**宿主缓存**，没有则问控制器。
/// 为何不直接 `paramNorm`：个别插件（分离式控制器）的 `getParamNormalized` 会
/// 跟自己的 DSP 同步——音频线程还没吃到本次写入时它会返回旧值 → 拖完松手
/// “参数回退”。缓存只由宿主写入与插件 performEdit 更新，不会回弹。
fn paramValueOf(pl: *vst_host.Plugin, pi: usize) f64 {
    return pl.cacheGet(pi) orelse pl.paramNorm(pi);
}

/// **参数行的值来源**（MIDI 乐器参数 / VST 插件参数）：
/// MIDI 与 VST 两列的“行底/名字颜色/徽标/值/拖动/复位/右键”全部走同一套绘制，
/// 只是值的读/写/显示/默认值不同——差异收集在这里，避免两边各写一份行渲染。
const RowVal = union(enum) {
    inst: struct { idx: usize, kind: view_lane.Target.Kind },
    vst: struct { pl: *vst_host.Plugin, pi: usize, ref: PluginSlotRef },

    fn read(self: RowVal, app: *const App) f64 {
        return switch (self) {
            .inst => |i| blk: {
                if (i.idx >= app.instruments.items.len) break :blk 0;
                const inst = &app.instruments.items[i.idx];
                break :blk switch (i.kind) {
                    .inst_vol => inst.volume,
                    .inst_pan => inst.pan,
                    else => inst.pitch, // 弯音位置（0.5 = 不弯）
                };
            },
            .vst => |v| paramValueOf(v.pl, v.pi),
        };
    }

    /// 写入（含历史策略：MIDI 走手势聚合，VST 走 `setPluginParamHost`）
    fn write(self: RowVal, app: *App, value: f64) void {
        switch (self) {
            .inst => |i| {
                if (i.idx >= app.instruments.items.len) return;
                const inst = &app.instruments.items[i.idx];
                switch (i.kind) {
                    .inst_vol => {
                        inst.volume = @floatCast(value);
                        app.touchGesture("设置乐器音量");
                    },
                    .inst_pan => {
                        inst.pan = @floatCast(value);
                        app.touchGesture("设置乐器声像");
                    },
                    else => {
                        inst.pitch = @floatCast(value);
                        app.touchGesture("设置乐器音高");
                    },
                }
            },
            .vst => |v| {
                const meta = &v.pl.params[v.pi];
                // 枚举/开关类参数：按 `step_count` 量化（与旧 `drawParamRow` 行为一致）
                var nv = value;
                if (meta.step_count > 0) {
                    const steps: f64 = @floatFromInt(meta.step_count);
                    nv = @round(nv * steps) / steps;
                }
                app.setPluginParamHost(v.ref, v.pl, v.pi, nv);
            },
        }
    }

    /// 双击复位值（null = 不支持）
    fn defaultValue(self: RowVal, app: *const App) ?f64 {
        _ = app;
        return switch (self) {
            // unity / 居中 / 不弯
            .inst => |i| if (i.kind == .inst_vol) 0.75 else 0.5,
            .vst => |v| v.pl.params[v.pi].default_norm,
        };
    }

    fn text(self: RowVal, buf: []u8, v: f64) []const u8 {
        return switch (self) {
            .inst => |i| view_lane.formatValue(
                if (i.kind == .inst_vol) .db else if (i.kind == .inst_pan) .pan else .semitone,
                @floatCast(v),
                buf,
            ),
            .vst => |x| x.pl.paramTextValue(x.pi, v, buf),
        };
    }
};

/// **统一的参数行**（MIDI / VST 共用）：行底+悬停 · 名字（白/绿） · 蓝字徽标 · 右侧值 ·
/// 拖动改值 · 双击复位 · 右键菜单（MIDI → 本窗口菜单；VST → `openRowMenu`） · `[自动化]` 按钮。
fn drawAutoRow(
    ui: *Ui,
    app: *App,
    tgt: view_lane.Target,
    label: []const u8,
    val: RowVal,
    id_base: u64,
    x: i32,
    y: i32,
    w: i32,
    is_midi: bool,
) void {
    // 显示/交互口径（touch 语义）：
    // - `driven` = 曲线正在驱动 → 绿、值跟曲线；
    // - `manual` = 正在拖这一行 → **橙**（“现在听你的”），松手回绿（curve 接手）。
    const driven = app.isAutoActive(tgt);
    const manual = app.isAutoTakeover(tgt); // 已链接 + 正在拖 → 橙（未链接的拖动保持常态）
    const rw = w - menu_btn_w - 4;
    const hovered = util.hitUI(ui, x, y, rw, row_h - 1);
    ui.renderer.fillRect(x, y, rw, row_h - 1, if (hovered) ui.theme.toolbar else ui.theme.panel);
    ui.renderer.strokeRect(x, y, rw, row_h - 1, ui.theme.panel_border);

    // 值 = **实际应用的值**：曲线在驱动时就是曲线值（与机架/混音台同一口径）。
    // 拖动锚点也用它——否则按下那一瞬会从曲线值跳到静态值（推子侧踩过的坑）。
    var cur = val.read(app);
    if (driven) cur = @floatCast(app.autoValueFor(tgt, @floatFromInt(app.playback.cursorStep(true)), @floatCast(cur)));
    // **音高目标的特殊口径**（MIDI 段的音高行 / VST 段的弯音别名行共用）：
    // 显示用半音、双击复位到 0.5（不弯）——插件自己报的 default_norm 往往是 0（=拉满向下）。
    const is_pitch = tgt.kind == .pitch_bend;
    if (hovered and ui.mouse_double) {
        const d: f64 = if (is_pitch) 0.5 else (val.defaultValue(app) orelse cur);
        if (@abs(d - cur) > 0.0002) {
            val.write(app, d);
            cur = val.read(app);
        }
    } else {
        // **链接了自动化也能手动拖**（不是“绿色 = 只读”）：拖动期间 `beginAutoDrag` 让该车道
        // 临时下线（touch：松手即恢复跟随，main 帧首 `clearAutoDrag`）。
        if (ui.active_id == id_base) app.beginAutoDrag(tgt);
        var v: f64 = cur;
        if (ui.dragNormV(id_base, x, y, rw, row_h - 1, &v)) {
            if (@abs(v - cur) > 0.0002) {
                val.write(app, v);
                cur = val.read(app);
            }
        }
    }

    // 右：值（跟随曲线 = 绿；拖动中 = 橙）；音高 → 半音读数（按乐器行程换算）
    var vb: [64]u8 = undefined;
    const vt = if (is_pitch)
        view_lane.formatSemitone(@floatCast(cur), app.bendRangeForTarget(tgt), &vb)
    else
        val.text(&vb, cur);
    const vw: i32 = @min(92, @as(i32, @intFromFloat(ui.font.measure(vt))));
    ui.labelClipped(vt, x + rw - 6 - vw, y + 3, vw + 2, if (driven) ui.theme.auto_active else if (manual) ui.theme.auto_takeover else ui.theme.text);

    // 左：参数名（链接中 → 绿；否则白） + 蓝字徽标（**紧贴值左侧**，名字让位）
    var cb2: [48]u8 = undefined;
    var ob: [96]u8 = undefined;
    const badge = linkedBadge(app, tgt, &cb2, &ob);
    var bw: i32 = 0;
    var bx2: i32 = x + rw;
    if (badge.len > 0) {
        // 徽标从右往左排：值 → 6px → 徽标 → 名字
        bw = @min(170, @as(i32, @intFromFloat(ui.font.measure(badge))));
        bx2 = x + rw - 6 - vw - 6 - bw;
        if (bx2 < x + 48) { // 行太窄：宁可截短徽标，也不能把它挤出可视区（实测 bug：徽标整段消失）
            bw = @max(0, x + rw - 6 - vw - 6 - (x + 48));
            bx2 = x + 48;
        }
    }
    const name_w2: i32 = @max(40, (bx2 - x - 10) - @as(i32, if (bw > 0) bw + 4 else 0));
    ui.labelClipped(label, x + 6, y + 3, name_w2, if (badge.len > 0) ui.theme.auto_active else ui.theme.text);
    if (bw > 0) ui.labelClipped(badge, bx2, y + 3, bw + 2, ui.theme.accent);

    // `[自动化]`：只开窗（建链/换曲线在窗口里的菜单）
    if (ui.button(id_base + 1, "自动化", x + rw + 2, y + 1, menu_btn_w, row_h - 3)) app.openAutoWin(tgt);

    // 行内右键：MIDI → 本窗口三项菜单；VST（含弯音别名行）→ 插件参数菜单
    if (!ui.mouse_pressed and util.hitUI(ui, x, y, rw, row_h - 1) and ui.mouse_right_pressed) {
        if (is_midi) {
            app.vst_auto.midi_menu = .{ .kind = tgt.kind, .uid = tgt.uid, .x = ui.mouse_x, .y = ui.mouse_y };
        } else switch (val) {
            .vst => |v| openRowMenu(app, v.ref, v.pl.params[v.pi].id, ui.mouse_x, ui.mouse_y),
            else => {},
        }
    }
}

/// **浮动窗口**（窗口标题栏 `自动化` 按钮打开：乐器 / 效果器 / 鼓组层三处共用）
pub fn draw(ui: *Ui, app: *App) void {
    const st = &app.vst_auto;
    if (!st.open) return;
    const x_ = st.x;
    const y_ = st.y;
    // **钳制**：主窗口缩小时自动收进屏幕（与机架/混音台/帮助页同一套 `util.clampWindow`）
    var w = W;
    var h = heightFor(app);
    var px = x_;
    var py = y_;
    util.clampWindow(ui.renderer.logicalWidth(), ui.renderer.logicalHeight(), &px, &py, &w, &h, min_w, min_h);
    st.x = px;
    st.y = py;
    const x = px;
    const y = py;

    // 目标插件槽没了（乐器/通道/槽/层被删）→ 自动关闭。
    // **乐器级入口**（`st.inst_uid != 0`）：只要那个乐器还在就允许打开（无插件时只画 MIDI 段）。
    if (st.inst_uid != 0) {
        if (app.instrumentIndexByUid(st.inst_uid) == null) {
            st.open = false;
            st.inst_uid = 0;
            return;
        }
    } else if (app.slotParamIdentity(st.ref) == null) {
        st.open = false;
        return;
    }

    // ── 窗口外壳（共享 `util.windowChrome`；本窗口不可缩放、标题右侧 60px 保留）──
    // **注意：外壳不登记 `noteOverlayRect`**。
    // 那张表是给**菜单/弹层**用的，而 `syncEmbeddedEditor` 拿 `overlay_n != 0`
    // 直接把插件子窗口禁掉（输入闸门）——整窗登记 = 一开自动化窗口，
    // 插件自己的 GUI 就再也不可交互（实测 bug）。窗口的遮挡靠 `win_draw_info` 处理。
    var tb: [192]u8 = undefined;
    // 标题：乐器级入口用「自动化参数 — 乐器名」（内置合成器没有“槽标题”可读）；
    // 插件槽入口（效果器/鼓组层）仍用 `slotTitle`。
    const title: []const u8 = blk: {
        if (st.inst_uid != 0) {
            if (app.instrumentIndexByUid(st.inst_uid)) |ii| {
                break :blk std.fmt.bufPrint(&tb, "自动化参数 — {s}", .{app.instruments.items[ii].name}) catch "自动化参数";
            }
            break :blk "自动化参数";
        }
        break :blk app.slotTitle(st.ref, &tb);
    };
    {
        var rs_w0: i32 = 0; // 缩放快照占位（本窗口不可缩放，只是传参）
        var rs_h0: i32 = 0;
        var rs_mx: i32 = 0;
        var rs_my: i32 = 0;
        if (util.windowChrome(ui, id_win + 1, 0, title, title_h, 60, &st.x, &st.y, &w, &h, &st.drag_dx, &st.drag_dy, &rs_w0, &rs_h0, &rs_mx, &rs_my, false)) {
            st.open = false;
            st.menu_open = false;
            ui.active_id = 0;
            return;
        }
    }
    // 拖出屏幕时**当场钳制**（原实现就在拖动分支里钳；外壳只做纯赋值）
    st.x = std.math.clamp(st.x, 0, @max(0, ui.renderer.logicalWidth() - w));
    st.y = std.math.clamp(st.y, 0, @max(0, ui.renderer.logicalHeight() - h));

    // **乐器级入口 + 无插件**（内置合成器 / 鼓组）：正文只有「乐器参数」（§11.47 A）。
    // 有插件的乐器（VSTi）仍走下面的 `drawBody`（它自己会画 MIDI 段 + 三段 VST）。
    if (st.inst_uid != 0 and app.slotPlugin(st.ref) == null) {
        // 无插件（内置合成器/鼓组）：**搜索框 + MIDI 段**（§11.47；搜索框与 VSTi 窗口共用）
        const sy0 = y + title_h + 6;
        const t0 = st.table(.float);
        drawSearchBox(ui, app, .float, t0, x + 8, sy0, w - 16, 18);
        const q = t0.filter_buf[0..t0.filter_len];
        const by = sy0 + 18 + 6;
        _ = drawMidiSection(ui, app, st.inst_uid, q, x + 8, by, w - 16, by, y + h, .float, t0);
        drawMidiMenu(ui, app); // 无插件路径也要画右键菜单（实测 bug：内置乐器右键没反应）
        return;
    }

    drawBody(ui, app, st.ref, x, y + title_h, w, h - title_h, .float);
}

/// **乐器参数行的右键菜单**（与插件参数行同款：恢复默认值 / 输入值… / 自动化…）。
/// 由 `draw`（无插件分支）与 `drawBody`（defer，两宿主通用）调用。
fn drawMidiMenu(ui: *Ui, app: *App) void {
    const st = &app.vst_auto;
    const mm = st.midi_menu orelse return;
    // 菜单自带乐器 uid（面板与浮窗共用同一个菜单状态，不能靠 `st.inst_uid` 猜）
    const uid: u32 = if (mm.uid != 0) mm.uid else st.inst_uid;
    const tgt = view_lane.Target{ .kind = mm.kind, .uid = uid };
    const items = [_][]const u8{ "恢复默认值", "输入值…", "自动化…" };
    const mw2: i32 = 140;
    // 走共享 `util.menuPanel`；位置固定（打开时快照进 mm.x/mm.y，不跟鼠标跑）
    var mx = mm.x;
    var my = mm.y;
    var open = true;
    const bounds: @import("ui.zig").Rect = .{ .x = 0, .y = 0, .w = ui.renderer.logicalWidth(), .h = ui.renderer.logicalHeight() };
    const clicked = util.menuPanel(ui, &mx, &my, &open, false, .{ .cursor = {} }, bounds, &items, mw2, null);
    if (clicked) |k| {
        if (app.instrumentIndexByUid(uid)) |ii| {
            const inst = &app.instruments.items[ii];
            const is_vol = mm.kind == .inst_vol;
            const is_pitch = mm.kind == .pitch_bend;
            if (k == 0) {
                if (is_vol) {
                    if (@abs(inst.volume - 0.75) > 0.0002) {
                        inst.volume = 0.75; // unity
                        app.commitHistory("恢复乐器音量");
                    }
                } else if (is_pitch) {
                    if (@abs(inst.pitch - 0.5) > 0.0002) {
                        inst.pitch = 0.5; // 不弯
                        app.commitHistory("恢复乐器音高");
                    }
                } else if (@abs(inst.pan - 0.5) > 0.0002) {
                    inst.pan = 0.5; // 居中
                    app.commitHistory("恢复乐器声像");
                }
            } else if (k == 1) {
                var vb: [16]u8 = undefined;
                if (is_vol) {
                    const pre = view_lane.formatValue(.db, inst.volume, &vb);
                    app.beginEditInstVol(ii, pre, mx + 4, my + 4, mw2 - 8);
                } else if (is_pitch) {
                    const pre = view_lane.formatSemitone(inst.pitch, app.bendRangeOf(ii), &vb);
                    app.beginEditInstPitch(ii, pre, mx + 4, my + 4, mw2 - 8);
                } else {
                    const pre = view_lane.formatValue(.pan, inst.pan, &vb);
                    app.beginEditInstPan(ii, pre, mx + 4, my + 4, mw2 - 8);
                }
                // **吞掉本次按下**：否则主循环的“点在输入框外→提交”会在同一帧把刚打开的输入框关掉
                // （实测 bug：右键“输入值…”开了框但打不了字）
                ui.mouse_pressed = false;
                ui.active_id = 0;
            } else {
                app.openAutoWin(tgt);
            }
        }
        st.midi_menu = null;
    } else if (!open) {
        st.midi_menu = null; // 点菜单外 = 关闭（`menuPanel` 已判定）
    }
}

/// **正文**（三段式）。`x/y/w/h` = 正文矩形（不含标题栏）。
/// `ref` = 插件实例的**运行时寻址**（乐器 / 效果器槽 / 鼓组层）：每帧由调用方重新解析（不跨帧持有 `*Plugin`）。
/// `host` = 宿主（浮动窗口 / 乐器面板 / 效果器面板）：**滚动·搜索·折叠·上次目标都按宿主分开存**，
/// 控件 id 也由它推导（`App.hostIdBase`）——不要再传裸 id 基段给调用方自由发挥。
pub fn drawBody(ui: *Ui, app: *App, ref: PluginSlotRef, x: i32, y: i32, w: i32, h: i32, host: app_mod.AutoTableHost) void {
    const st = &app.vst_auto;
    const t = st.table(host);
    // MIDI 行右键菜单：**两条路径（浮窗/面板）都要画**，用 defer 保证早退分支也不漏
    defer drawMidiMenu(ui, app);
    const ident = app.slotParamIdentity(ref) orelse return;
    const pl = app.slotPlugin(ref) orelse {
        ui.label("（插件未加载——无法编辑参数；文件恢复后自动加载）", x + 10, y + 10, ui.theme.danger);
        return;
    };
    // 换目标 → 本宿主的滚动/搜索复位（其他宿主不受影响）
    if (t.last_key != App.slotRefKey(ref)) {
        t.last_key = App.slotRefKey(ref);
        t.scroll = 0;
        t.filter_len = 0;
        if (host == .float) {
            st.ref = ref;
            st.menu_open = false;
        }
    }

    var yy = y + 6;

    // ── 搜索框（静态层；编辑中 main 的文本输入 overlay 盖在同位置）──
    const search_h: i32 = 18;
    {
        drawSearchBox(ui, app, host, t, x + 8, yy, w - 16, search_h);
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
    // **音高绑定也归进这一段**（别名归一：插件有弯音参数时，`MIDI CC <ch>|129` 那行
    // 就是音高的另一个入口）；鼓组层/效果器没有音高概念，不适用。
    const pitch_alias_on = ref.kind == .instrument and pl.pitchParamId() != null;
    for (app.auto_bindings.items) |b| {
        // 本插件槽的绑定（乐器 / 效果器槽 / 鼓组层 → 稳定 uid 身份）
        const same_slot = b.target.kind == ident.kind and b.target.uid == ident.uid and b.target.slot == ident.slot;
        const is_pitch_here = pitch_alias_on and b.target.kind == .pitch_bend and b.target.uid == ident.uid;
        if (!same_slot and !is_pitch_here) continue;
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

    const q = t.filter_buf[0..t.filter_len];

    // ── **乐器参数**（§11.47）：与插件无关的三项，所有乐器都有 ──
    // 走乐器 `uid` 定位（改名/换插件仍有效）；音高本轮只显示不可建链。
    const inst_uid: u32 = blk: {
        // **面板正文**：永远以本面板的目标为准（否则会把浮动窗口那个乐器的 MIDI 行
        // 画进别的面板里——实测 bug：两个宿主共用一份 `inst_uid`）
        if (host != .float) {
            if (ref.kind == .instrument and ref.a < app.instruments.items.len)
                break :blk app.instruments.items[ref.a].uid;
            break :blk 0;
        }
        // 乐器级入口（§11.47 A）：内置合成器/鼓组也能打开，只看得到 MIDI 段
        if (st.inst_uid != 0) break :blk st.inst_uid;
        if (ref.kind == .instrument and ref.a < app.instruments.items.len)
            break :blk app.instruments.items[ref.a].uid;
        break :blk 0;
    };
    var n_all: i32 = 0;
    {
        var pi: usize = 0;
        while (pi < n_params) : (pi += 1) {
            if ((pl.params[pi].flags & 0x2) != 0) continue; // kIsReadOnly
            if (q.len > 0 and std.ascii.findIgnoreCase(pl.params[pi].name(), q) == null) continue;
            n_all += 1;
        }
    }

    // **VST 组折叠**：折叠时只留组标题行（§11.47：组内 = 已链接（置顶）→ 最近改动 → 全部参数）。
    // TODO（未做，见 `docs/automation.md` 同名小节）：改成“固定高度分区”（上区内容高、下区独立滚动），
    // 理由是现在「最近改动」变长会把「全部参数」整体往下推（行数跳变）。
    const vst_folded = t.vst_fold and q.len == 0;

    // **滚动界跟“上一帧实测的内容高”**（`t.drawn_h`，由下方绘制循环画完后回填）：
    // 旧实现用手工公式估高，与实际绘制漂移——外层“插件参数”组头没算进去、
    // MIDI 段折叠/缺失的口径不一致——实测“滚到底还差一两条”（“最近改动”一长
    // 就复现）。实测值从根上消灭这类漂移：以后改布局不用同步任何公式。
    // 首帧（还没量过）：先假设内容很长——滚动条从第一帧就占位，避免开窗时行宽跳一下。
    const measured_h: i32 = if (t.drawn_h > 0) t.drawn_h else (1 << 30);
    const scroll_max: i32 = @max(0, measured_h - list_h);
    if (util.hitUI(ui, x + 8, list_y, w - 16, list_h)) {
        t.scroll = std.math.clamp(t.scroll - util.scrollDelta(ui), 0, scroll_max);
    }
    t.scroll = std.math.clamp(t.scroll, 0, scroll_max);
    const scrollbar_w: i32 = if (scroll_max > 0) 7 else 0;

    const saved = ui.renderer.pushClip(x + 8, list_y, w - 16 - scrollbar_w, list_h);
    defer ui.renderer.popClip(saved);

    var cy = list_y - t.scroll;
    const row_x = x + 8;
    const row_w = w - 16 - scrollbar_w;
    // 视口剔除用：行是否可见
    const vis = struct {
        fn f(ry: i32, top: i32, bot: i32) bool {
            return ry + row_h > top and ry < bot;
        }
    }.f;
    const list_bot = list_y + list_h;

    // ⓪ **乐器参数**（§11.47）：音量 / 声像 / 音高——共用绘制函数（无插件入口也用它）
    cy = drawMidiSection(ui, app, inst_uid, q, row_x, cy, row_w, list_y, list_bot, host, t);
    // ── **插件参数**组（§11.47）：组内 = 已链接（置顶）→ 最近改动 → 全部参数
    // 与 MIDI 段同样支持折叠；**有搜索词时强制展开**
    sectionLabel(ui, "插件参数", row_x, cy, row_w, n_linked + n_recent + n_all);
    if (util.hitUI(ui, row_x, cy, row_w, sect_h) and ui.mouse_pressed) {
        t.vst_fold = !t.vst_fold;
        ui.active_id = 0; // 防标题/行拖动被误触发
    }
    cy += sect_h;
    if (!vst_folded) {
        // ① 已链接（按参数归组：一个参数挂多条曲线只占一行）
        sectionLabel(ui, "已链接", row_x, cy, row_w, n_linked);
        cy += sect_h;
        if (n_linked == 0) {
            ui.labelClipped("（还没有链接任何参数——用下方行右侧的「自动化」建一条曲线）", row_x + 6, cy + 2, row_w - 8, ui.theme.text_dim);
            cy += row_h;
        } else {
            var gi: usize = 0;
            while (gi < @as(usize, @intCast(n_linked))) : (gi += 1) {
                if (vis(cy, list_y, list_bot)) drawLinkedRow(ui, app, pl, ref, linked[gi], rowId(host, sec_linked, gi), row_x, cy, row_w);
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
            var row_ord: usize = 0; // **行序号**（不是参数下标——参数上万时下标会把 id 挤出本段）
            while (i < app.vst_recent_n) : (i += 1) {
                const e = app.vst_recent[i];
                if (e.slot_key != slot_key) continue;
                const pi = pl.findParamIndex(e.param_id) orelse continue;
                if (vis(cy, list_y, list_bot)) drawParamRow(ui, app, pl, pi, rowId(host, sec_recent, row_ord), row_x, cy, row_w, ref);
                row_ord += 1;
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
                // 视口外（上/下两侧）：**只累计不画、不 break**——绘制循环的 `cy`
                // 必须走到真实内容底（`t.drawn_h` 靠它回填；break 会让量出的高度
                // 停在视口底 → 滚动界又变小）。`n_all` 的计数循环本来就要全量扫，
                // 这里多做的只是加法。
                if (cy + row_h < list_y or cy > list_bot) {
                    cy += row_h;
                    continue;
                }
                drawParamRow(ui, app, pl, pi, rowId(host, sec_all, pi), row_x, cy, row_w, ref);
                cy += row_h;
            }
        }
    } // if (!vst_folded)

    // **实测内容高**：本帧画完后的 `cy` 就是内容底在屏幕上的位置——
    // 还原成内容高度并回填，下一帧的滚动界/滚动条都用它。
    t.drawn_h = cy - list_y + t.scroll;
    // 滚动条与滚动界同源（`measured_h`）——首帧（还没量过）也不会画出怪异的滑块
    if (scroll_max > 0) ui.drawScrollbar(x + w - 11, list_y, 5, list_h, t.scroll, measured_h, list_h);
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

/// **搜索框**（静态层；编辑中 main 的文本输入 overlay 盖在同位置）。
/// 抽出来是因为“无插件的乐器级窗口”也要用同一个框（§11.47）。
/// `t` = 宿主状态（面板与浮窗的搜索词互相独立）。
fn drawSearchBox(ui: *Ui, app: *App, host: app_mod.AutoTableHost, t: *app_mod.AutoTableState, x: i32, y: i32, w: i32, search_h: i32) void {
    if (app.text_input.active and app.text_input.target == .vst_param_search and app.vst_auto.search_host == host) {
        const ti = &app.text_input;
        const n = @min(ti.len, t.filter_buf.len);
        @memcpy(t.filter_buf[0..n], ti.buf[0..n]);
        t.filter_len = n;
    }
    const editing = app.text_input.active and app.text_input.target == .vst_param_search and app.vst_auto.search_host == host;
    const hovered = util.hitUI(ui, x, y, w, search_h);
    ui.renderer.fillRect(x, y, w, search_h, if (hovered) ui.theme.item_hover else ui.theme.slider_track);
    ui.renderer.strokeRect(x, y, w, search_h, ui.theme.panel_border);
    if (!editing) {
        if (t.filter_len > 0) {
            ui.labelClipped(t.filter_buf[0..t.filter_len], x + 4, y + 3, w - 8, ui.theme.text);
        } else {
            ui.label("搜索参数…", x + 4, y + 3, ui.theme.text_dim);
        }
    }
    if (hovered and ui.mouse_pressed) app.beginVstParamSearch(host, t, x, y, w);
}

/// **已链接徽标**（MIDI / VST 两组共用）：
/// 单条 → 「已链接到〈曲线名〉」；多条 → 「已链接到〈曲线名〉 等N条」。
/// 未链接 → 空串。`curve_buf`/`out` 由调用方提供（零分配）。
fn linkedBadge(app: *App, target: view_lane.Target, curve_buf: []u8, out: []u8) []const u8 {
    var n: i32 = 0;
    var first: u32 = 0;
    for (app.auto_bindings.items) |b| {
        if (!view_lane.Target.eql(b.target, target)) continue;
        if (n == 0) first = b.curve_id;
        n += 1;
    }
    if (n == 0) return "";
    const cname = if (app.curveById(first)) |lc| lc.name(curve_buf) else "（曲线已删除）";
    return if (n > 1)
        std.fmt.bufPrint(out, "已链接到 {s} 等{d}条", .{ cname, n }) catch "已链接"
    else
        std.fmt.bufPrint(out, "已链接到 {s}", .{cname}) catch "已链接";
}

/// **已链接**行：**参数名（主，绿）+ 曲线名/“等N条”（次，灰）+ 值 + `自动化`**
///
/// 语义：这一段的标题是“已链接”，主语是**参数**（一个参数可以挂多条曲线 → 仍**只占一行**）；
/// 所以主标签必须是参数名，曲线信息降为右侧的灰色旁注（多条时写 `xxx 等N条`）。
/// **本行不解绑**（用户拍板：已链接行只用来“看/进自动化”，
/// 解绑在自动化窗口的绑定行 `×` 里——一个动作一个地方）。
fn drawLinkedRow(ui: *Ui, app: *App, pl: *vst_host.Plugin, ref: PluginSlotRef, row: LinkedRow, id_base: u64, x: i32, y: i32, w: i32) void {
    // 音高绑定：参数 id 在插件身上（`IMidiMapping` 解析），不在 target 里（跨插件稳定）
    const pid: u32 = if (row.target.kind == .pitch_bend)
        (pl.pitchParamId() orelse 0)
    else
        row.target.param_id;
    if (pl.findParamIndex(pid)) |pix| {
        // **与「最近改动 / 全部参数 / MIDI 参数」完全同一套行渲染**：
        // 徽标（曲线信息）紧贴值左侧、绿名/绿值、[自动化] 按钮、右键菜单全部一致。
        // 被曲线驱动时照样可拖——拖动期 `beginAutoDrag` 让车道临时下线（touch：松手回曲线）。
        // `ref` 由调用方传入（不能用 `vst_auto.ref`：那是浮动窗口的目标，面板正文可能不同）。
        drawAutoRow(ui, app, row.target, pl.params[pix].name(), .{ .vst = .{ .pl = pl, .pi = pix, .ref = ref } }, id_base, x, y, w, false);
        return;
    }
    // 参数已不存在（插件换版本/换插件）→ 灰字占位，不提供交互
    ui.renderer.strokeRect(x, y, w - menu_btn_w - 4, row_h - 1, ui.theme.panel_border);
    var cb: [48]u8 = undefined;
    var sb: [80]u8 = undefined;
    const cname = if (app.curveById(row.first_curve)) |lc| lc.name(&cb) else "（曲线已删除）";
    const label: []const u8 = if (row.n > 1)
        std.fmt.bufPrint(&sb, "已链接到 {s} 等{d}条", .{ cname, row.n }) catch cname
    else
        std.fmt.bufPrint(&sb, "已链接到 {s}", .{cname}) catch cname;
    ui.labelClipped("（参数不存在）", x + 6, y + 2, 120, ui.theme.text_dim);
    ui.labelClipped(label, x + 130, y + 2, w - 130 - menu_btn_w - 10, ui.theme.accent);
}

/// 普通参数行（最近改动 / 全部参数）：拖动改值 · 双击复位 · 右侧 `自动化` 按钮
fn drawParamRow(ui: *Ui, app: *App, pl: *vst_host.Plugin, pi: usize, id_base: u64, x: i32, y: i32, w: i32, ref: PluginSlotRef) void {
    const meta = &pl.params[pi];
    const target = app.targetForSlotParam(ref, meta.id) orelse {
        // 未绑定（理论上不会发生：行来自已链接/最近/全表）→ 只画行底与名字，不给交互
        const rw0 = w - menu_btn_w - 4;
        ui.renderer.fillRect(x, y, rw0, row_h - 1, ui.theme.panel);
        ui.renderer.strokeRect(x, y, rw0, row_h - 1, ui.theme.panel_border);
        ui.labelClipped(meta.name(), x + 6, y + 2, rw0 - 100, ui.theme.text);
        return;
    };
    // **与 MIDI 行同一套绘制**（行走 RowVal 把读/写/显示/默认值的差异收在两个 lambda 里）
    drawAutoRow(ui, app, target, meta.name(), .{ .vst = .{ .pl = pl, .pi = pi, .ref = ref } }, id_base, x, y, w, false);
}

/// 打开本行的右键菜单（行内右键用；按钮已改成直接打开自动化窗口）。
/// `ref` 随菜单一起存：菜单可能从**面板正文**（Linux 嵌入式）发起，而 `vst_auto.ref`
/// 是浮动窗口的目标——两者可能不同插件（实测隐患：恢复默认值/输入值会写到别的插件上）。
fn openRowMenu(app: *App, ref: PluginSlotRef, param_id: u32, x: i32, y: i32) void {
    const st = &app.vst_auto;
    st.menu_open = true;
    st.menu_just_opened = true; // 否则**打开它的那次点击**会在同帧把它关掉
    st.menu_ref = ref;
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

    const pl = app.slotPlugin(st.menu_ref) orelse {
        st.menu_open = false;
        return;
    };
    const pi = pl.findParamIndex(st.menu_param) orelse {
        st.menu_open = false;
        return;
    };
    const meta = &pl.params[pi];
    const target = app.targetForSlotParam(st.menu_ref, st.menu_param) orelse {
        st.menu_open = false;
        return;
    };

    const items = [_][]const u8{ "恢复默认值", "输入值…", "自动化…" };
    const mh: i32 = @as(i32, @intCast(items.len)) * util.menu_item_h + 4;
    const scr_w = ui.renderer.logicalWidth();
    const scr_h = ui.renderer.logicalHeight();
    // 位置：打开时快照 + 每帧钳制到屏幕内（局部变量传给 `menuPanel`）。
    // **开帧保护**（`just`）：本菜单是**左键**打开的——那次 mouse_pressed 还压在
    // 菜单项上，开帧不得判定点击（`menuPanel` 的 just_opened + `.snapshot` 锚）。
    var mx = std.math.clamp(st.menu_x, 0, @max(0, scr_w - menu_w));
    var my = std.math.clamp(st.menu_y, 0, @max(0, scr_h - mh));
    var open = true;
    const bounds: @import("ui.zig").Rect = .{ .x = 0, .y = 0, .w = scr_w, .h = scr_h };
    const hit = util.menuPanel(ui, &mx, &my, &open, just, .{ .snapshot = {} }, bounds, &items, menu_w, null);
    if (hit) |k| {
        // 恢复默认值 / 输入值… 都直接作用于发起菜单的那个插件槽（存于菜单状态）
        const slot_ref = st.menu_ref;
        const is_pitch = target.kind == .pitch_bend; // 弯音别名行：复位 = 不弯、输入用半音
        switch (k) {
            0 => {
                // 恢复默认值（音高 → 0.5 不弯；插件自报 default_norm 常是 0 = 拉满向下）
                app.setPluginParamHost(slot_ref, pl, pi, if (is_pitch) 0.5 else meta.default_norm);
            },
            1 => {
                // 输入值…（普通参数按**百分比**；音高按**半音**）
                var vb: [16]u8 = undefined;
                const cur_v = paramValueOf(pl, pi);
                const pre = if (is_pitch)
                    view_lane.formatSemitone(@floatCast(cur_v), app.bendRangeForTarget(target), &vb)
                else
                    (std.fmt.bufPrint(&vb, "{d:.1}", .{cur_v * 100.0}) catch "");
                app.beginVstParamValueEdit(slot_ref, meta.id, pre, mx + 4, my + 4, menu_w - 8);
            },
            else => app.openAutoWin(target), // 自动化…（别名行 → 音高的同一个链接窗）
        }
        st.menu_open = false;
        ui.active_id = 0;
        return;
    }
    // 点菜单外 → 收起（开启帧不判——`menuPanel` 的 just_opened 已处理）
    if (!open) {
        st.menu_open = false;
        ui.active_id = 0;
    }
}
