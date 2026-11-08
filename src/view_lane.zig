//! **值轨控件**（value lane）——自动化包络的渲染与手势。v0 原型，见 `docs/automation.md` §九。
//!
//! 设计要点（定稿）：
//! - 锚点 + **每段** `(interp, curve)`；曲线 = `lerp + curve*4t(1-t)`（抛物鼓包，
//!   **穿过两个锚点、也穿过段中点的手柄**——不是贝塞尔控制点）；
//! - 曲率是**左锚点上的属性**，手柄是**派生**的（不占点）；
//! - `interp = .hold` 的段没有曲率（手柄隐藏）。
//!
//! v0 范围：单 lane、不进历史/存档；求值由 UI 线程每帧做（写通道增益），音频线程不参与。

const std = @import("std");
const model = @import("model.zig");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const util = @import("view_util.zig");

/// 段间插值
pub const Interp = enum { hold, linear, smooth };

/// 一个锚点；`curve` 属于“以本点为起点的那一段”（归一化，-1..1，0 = 直线）
/// 一个锚点；`curve` 属于“以本点为起点的那一段”（归一化，-1..1，0 = 直线）
/// `drawValueHeader` 的返回（值行是否被点、以及值行矩形）
pub const HeaderHit = struct { value_clicked: bool, rect: Rect };

pub const Point = struct {
    step: i32,
    value: f32,
    /// 本段（到下一个点）的弯曲量；0 = 直线。正 = 向上鼓
    curve: f32 = 0,
    /// 本段弯曲的**峰值位置**（0..1；0.5 = 正中）。左右拖曲率手柄改它
    pivot: f32 = 0.5,
    /// **出生序号**：同一步可以有多个点（形成垂直断崖），组内顺序 = 出生顺序
    seq: u32 = 0,
};

/// v0 支持的目标（正式版会换成稳定 id 的 target 表）
/// 自动化**目标**：参数种类 + 对象身份（**不是数组下标**）。
///
/// - `mixer_vol` / `mixer_pan`：`uid` = 混音台通道的**稳定身份**（`MixerChannel.uid`）——
///   通道上移/下移后绑定仍然跟着那个通道（用户明确要求）；发布时再用 `uid → 当前下标` 解析。
/// - `master_vol`：主通道推子（`uid` 忽略）。
/// - BPM / CC 暂不开放入口（见 `docs/automation.md` §11.22）。
pub const Target = struct {
    kind: Kind = .none,
    uid: u32 = 0,

    /// `none` = 未绑定（曲线不驱动任何参数）
    /// **`tempo`（BPM）**：全局目标（`uid` 忽略）；曲线值按 `bpmFromNorm` 映射到 BPM。
    pub const Kind = enum { none, master_vol, mixer_vol, mixer_pan, inst_vol, inst_pan, tempo };
    /// **BPM 的归一化映射区间**（线性）：0 → 20，1 → 999
    pub const tempo_min: f32 = 20.0;
    pub const tempo_span: f32 = 979.0;
    /// 曲线值（0..1）→ BPM
    pub fn bpmFromNorm(v: f32) f32 {
        return tempo_min + std.math.clamp(v, 0.0, 1.0) * tempo_span;
    }
    /// BPM → 曲线值（0..1）
    pub fn normFromBpm(bpm: f32) f32 {
        return std.math.clamp((bpm - tempo_min) / tempo_span, 0.0, 1.0);
    }

    /// 同种类且同一对象 → 相等（主通道/节奏忽略 uid）
    pub fn eql(a: Target, b: Target) bool {
        if (a.kind != b.kind) return false;
        if (a.kind == .none) return true;
        if (a.kind == .master_vol or a.kind == .tempo) return true;
        return a.uid == b.uid;
    }

    /// **默认基准值**（新建绑定时的叠加起点）。对齐 VST3 的 `ParameterInfo.defaultNormalizedValue`。
    /// 音量类 = 0（曲线 0..1 直接就是音量），声像类 = 0.5（中心），
    /// **BPM 也是 0**（曲线 0 → 20 BPM、1 → 999 BPM，即“曲线值直接就是速度”）。
    pub fn defaultBase(kind: Kind) f32 {
        return switch (kind) {
            .master_vol, .mixer_vol, .inst_vol => 0.0,
            .mixer_pan, .inst_pan => 0.5,
            .tempo => 0.0,
            .none => 0.0,
        };
    }

    /// **默认极性**（对齐 VST3 的 `kIsBipolar` 标志：声像类参数有中心位置）。
    pub fn defaultBipolar(kind: Kind) bool {
        return switch (kind) {
            .mixer_pan, .inst_pan => true,
            else => false,
        };
    }

    /// **默认叠加深度**：音量/声像给满（1.0）；
    /// **BPM 只给 20%**——深度 1.0 时一条 0→1 的缓坡会把速度从 20 拉到 999。
    pub fn defaultDepth(kind: Kind) f32 {
        return switch (kind) {
            .tempo => 0.2,
            else => 1.0,
        };
    }

    /// 该目标是否由**音量**驱动（影响默认显示单位）
    pub fn isVolume(self: Target) bool {
        return self.kind == .master_vol or self.kind == .mixer_vol or self.kind == .inst_vol;
    }
};

/// **绑定**：曲线 → 参数（同一条曲线可绑多个参数；同一个参数也可被多条曲线叠加）
pub const Binding = struct {
    curve_id: u32,
    target: Target,
    /// 叠加深度 0..1（将来可 >1）
    depth: f32 = 1.0,
    /// **基准值**（叠加起点，归一化 0..1）；`null` = 用目标类型的默认值
    /// （见 `Target.defaultBase`：音量 0 / 声像 0.5）。右键可恢复默认。
    base: ?f32 = null,
    /// **极性**：false = 单向（曲线 0 处不改变，只往上加）；true = 双向（曲线 0.5 处不改变，可上可下）
    bipolar: bool = false,
    enabled: bool = true,
};

/// 手势态
const DragKind = enum { none, anchor, curve };

pub const Lane = struct {
    /// **稳定 id**（单调、不重用）——绑定表按 id 引用，删除/重排不会错位
    id: u32 = 0,
    /// 曲线名（定长 UTF-8；`name_len == 0` → 显示 `curveNameFallback`）
    name_buf: [24]u8 = @splat(0),
    name_len: u8 = 0,
    target: Target = .{},
    /// **归属乐器**（乐器作用域的 target 用）：-1 = 未绑定。
    /// 求值只作用于它，不再用“当前选中的乐器”——否则给 A 画线会去控 B（实测隐患）。
    inst: i32 = -1,
    interp: Interp = .smooth,
    points: std.ArrayListUnmanaged(Point) = .empty,
    /// 出生序号发生器（同一步的多个点靠它定序；只增不减）
    next_seq: u32 = 1,

    drag_kind: DragKind = .none,
    drag_idx: usize = 0,
    /// 悬停中的点/段（每帧由 `draw` 更新；行头列顶部读数用）
    hover_kind: DragKind = .none,
    hover_idx: usize = 0,
    /// 行头列顶部**显示单位**（只影响显示与键入；内部永远存归一化 0..1）
    display_unit: Unit = .percent,
    /// **选中的锚点**（左键点选；读数/键入都以它为准，鼠标移开也不丢）
    sel_idx: ?usize = null,
    /// 拖动**抓取偏移**：按下瞬间 `鼠标位置 − 点位置`，拖动期间保持。
    /// 没有它的话，按下那一刻点会**瞬移到鼠标正下方**（用户实测：只想点选却“抖一下”）。
    /// 单位：`grab_step` = 步（取整后用于 step），`grab_value` = 归一化值。
    grab_step: i32 = 0,
    grab_value: f32 = 0,
    /// 曲率手柄的 **pivot 抓取偏移**（归一化 0..1）：按下时 `手柄 pivot − 鼠标处的 pivot`。
    /// 没有它 → 按手柄任意一边拖动，手柄会先**瞬移到鼠标 x** 上（用户实测：“单击手柄会乱跑”）。
    grab_pivot: f32 = 0,

    pub fn deinit(self: *Lane, alloc: std.mem.Allocator) void {
        self.points.deinit(alloc);
        self.points = .empty;
        self.drag_kind = .none;
    }

    /// 曲线名（无自定义名 → `"曲线#"`；由调用方给缓冲）
    pub fn name(self: *const Lane, buf: []u8) []const u8 {
        if (self.name_len > 0) return self.name_buf[0..self.name_len];
        return std.fmt.bufPrint(buf, "曲线{d}", .{self.id}) catch "曲线";
    }

    pub fn setName(self: *Lane, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn hasPoints(self: *const Lane) bool {
        return self.points.items.len > 0;
    }

    /// 在 `step` 处求值（**同一 step 允许多点 = 垂直断崖**）：
    /// 段定位 = “最后一个 step ≤ 查询步的点”（跳崖时取组内**最右**那个），
    /// 然后向右与下一个点插值；`a.curve ≠ 0` 时叠加**偏斜鼓包**（峰值位置 `a.pivot`）。
    /// **连续**求值（`step` 可为小数）。
    pub fn evalAt(self: *const Lane, step_in: f32) f32 {
        const ps = self.points.items;
        if (ps.len == 0) return -1; // -1 = 无 lane（调用方回落静态值）
        const step = step_in;
        // ① 找“最后一个 step <= 查询步”的点（同 step → 组内最右，即断崖右侧的高度）
        var i: usize = ps.len;
        while (i > 0) : (i -= 1) {
            if (@as(f32, @floatFromInt(ps[i - 1].step)) <= step) break;
        }
        if (i == 0) return ps[0].value;
        const a = ps[i - 1];
        if (i >= ps.len) return a.value; // 尾点之后：保持
        const b = ps[i];
        // ② `a` 是组内最后一个 → `b.step > a.step` 恒成立（无需除零保护）
        const a_step: f32 = @floatFromInt(a.step);
        const b_step: f32 = @floatFromInt(b.step);
        const span: f32 = @max(1.0, b_step - a_step);
        const t: f32 = std.math.clamp((step - a_step) / span, 0.0, 1.0);
        const v = switch (self.interp) {
            .hold => a.value,
            .linear => a.value + (b.value - a.value) * t,
            .smooth => segEval(a.value, b.value, a.pivot, a.curve, t),
        };
        return std.math.clamp(v, 0.0, 1.0);
    }

    /// 插入锚点（按 `(step, seq)` 保序；**同一步已有点 → 追加到该组末尾**（出生顺序））。
    /// 同 step 且值几乎相同（双击重复点）→ 返回既有下标（不产生零高度断崖）。
    pub fn insertPoint(self: *Lane, alloc: std.mem.Allocator, step: i32, value: f32) usize {
        var i: usize = 0;
        while (i < self.points.items.len and self.points.items[i].step <= step) : (i += 1) {
            const p = self.points.items[i];
            if (p.step == step and @abs(p.value - value) < 0.002) return i;
        }
        const seq = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        self.points.insert(alloc, i, .{ .step = step, .value = std.math.clamp(value, 0, 1), .seq = seq }) catch return 0;
        return i;
    }

    pub fn removeAt(self: *Lane, idx: usize) void {
        if (idx >= self.points.items.len) return;
        _ = self.points.orderedRemove(idx);
    }
};

// ─────────────────────────── 渲染 + 手势 ───────────────────────────

const anchor_half: i32 = 4; // 锚点方块半宽（像素）
const handle_half: i32 = 5; // 曲率手柄半宽（菱形）
/// **手柄隐藏阈值（横/竖同一个值）**：段的屏幕宽或高小于它 → 手柄不画也不可点。
/// 理由：太小时手柄必然与锚点抢点击（用户实测“分不开”），不如直接让位给锚点。
const handle_min_extent: f32 = 20;

/// **段形状（主流 DAW 手感）**：折线 `A → H → B` + 在 H 处**倒圆角**。
/// - H = `(pivot, 直连线值 + curve)`（即曲率手柄所在点）；
/// - 两个锚点处是**真的折角**（拉到底时就是直角），只有 H 附近被抹圆；
/// - `curve == 0` 时三点共线 → 整段直线。
/// 旧实现是“平滑鼓包”（`bell`），它让两端零斜率 → 拉到底时两侧变成 S 形波浪，与主流 DAW 不符。
pub fn segEval(a: f32, b: f32, pivot: f32, curve: f32, t_in: f32) f32 {
    const p = std.math.clamp(pivot, 0.0, 1.0);
    const t = std.math.clamp(t_in, 0.0, 1.0);
    // 折点值也被夹在两端值之间（**模型层就不过冲**；UI 已通过 `curveFromHandle` 预夹一次）
    const lo = @min(a, b);
    const hi = @max(a, b);
    const h = std.math.clamp(a + (b - a) * p + curve, lo, hi);
    // pivot 在两端 → 退化成从 H（或到 H）的直线（pivot=0 时相当于段首跳变）
    if (p <= 1e-5) return h + (b - h) * t;
    if (p >= 1.0 - 1e-5) return a + (h - a) * t;
    // 倒角：两侧各取 25% 长度作为圆角过渡区
    const f: f32 = 0.25;
    const x1 = p * (1.0 - f);
    const x2 = p + (1.0 - p) * f;
    const v1 = a + (h - a) * (1.0 - f);
    const v2 = h + (b - h) * f;
    if (t <= x1) return a + (h - a) * (t / p); // A → H 的直线段
    if (t >= x2) return h + (b - h) * ((t - p) / (1.0 - p)); // H → B 的直线段
    // 圆角：以 (x1,v1) / (p,h) / (x2,v2) 为控制点的二次贝塞尔；
    // 先由 t 反解 u（x(u) 单调），再取 v(u)。
    const e2 = x1 - 2.0 * p + x2;
    const e1 = 2.0 * (p - x1);
    const e0 = x1 - t;
    var u: f32 = 0.5;
    if (@abs(e2) < 1e-6) {
        u = if (@abs(e1) < 1e-6) 0.5 else -e0 / e1;
    } else {
        const disc = @max(0.0, e1 * e1 - 4.0 * e2 * e0);
        const sq = @sqrt(disc);
        const ur1 = (-e1 + sq) / (2.0 * e2);
        const ur2 = (-e1 - sq) / (2.0 * e2);
        u = if (ur1 >= -0.001 and ur1 <= 1.001) ur1 else ur2;
    }
    u = std.math.clamp(u, 0.0, 1.0);
    const w0 = (1.0 - u) * (1.0 - u);
    const w1 = 2.0 * u * (1.0 - u);
    const w2 = u * u;
    return w0 * v1 + w1 * h + w2 * v2;
}

/// 把值 0..1 映射到 y（1 在上）
fn yOf(value: f32, y: i32, h: i32) i32 {
    // **值轴不内缩**：0 → 面板底边、1 → 顶边、0.5 → 正中心。
    // 曾经上下各缩 4px（"柱条不贴边"），结果 50% 的点与几何中线差 0~1px，
    // 且柱条/曲线看起来"悬空"（用户实测），已去掉。
    const usable: f32 = @floatFromInt(@max(1, h));
    return y + @as(i32, @intFromFloat((1.0 - std.math.clamp(value, 0, 1)) * usable));
}

fn valueOfY(py: i32, y: i32, h: i32) f32 {
    const usable: f32 = @floatFromInt(@max(1, h));
    const t: f32 = @as(f32, @floatFromInt(py - y)) / usable;
    return std.math.clamp(1.0 - t, 0.0, 1.0);
}

// 注：`step_px` 是**未缩放**的步宽；屏幕步宽 = `step_px * zoom`
//（与 `util.drawTimelineGrid` 内部 `step_w * zoom` 同一口径）。
/// 步 → 屏幕 x。**与竖向网格完全同一表达式**：`lane_x + step*step_ws − scroll_s`
/// （`scroll_s` = 内容滚动像素 × zoom，**不截断成整步**）。
/// 曾把滚动截断成整步再乘步宽 → 点的位置比网格多偏最多一个步宽，
/// 且偏移量随缩放变化（用户实测：点落不到竖网格线上）。
fn xOf(step: f32, x: i32, step_px: f32, zoom: f32, scroll_s: f32) i32 {
    const sp = step_px * zoom;
    return x + @as(i32, @intFromFloat(step * sp - scroll_s));
}

/// 屏幕 x → **小数**步（绘制曲线用；不做取整 → 曲线平滑）
fn stepOfXf(px: i32, x: i32, step_px: f32, zoom: f32, scroll_s: f32) f32 {
    const sp = step_px * zoom;
    if (sp <= 0.0001) return 0;
    return (@as(f32, @floatFromInt(px - x)) + scroll_s) / sp;
}

/// 屏幕 y → 值（**不夹到 0..1**，拖动专用）。
/// 拖动时点是追“鼠标值 + 抓取偏移”，若先把鼠标值夹到 1.0，再叠加**负的**抓取偏移
/// （按下时鼠标在点中心偏上 → 偏移为负），就永远到不了 1.0（实测：拖到底只到 97~99%）。
fn valueOfYRaw(py: i32, y: i32, h: i32) f32 {
    const usable: f32 = @floatFromInt(@max(1, h));
    const t: f32 = @as(f32, @floatFromInt(py - y)) / usable;
    return 1.0 - t;
}

/// 屏幕 x → 步（**取最近的步**，于是拖动/加点自然吸附到网格线上）
fn stepOfX(px: i32, x: i32, step_px: f32, zoom: f32, scroll_s: f32) i32 {
    const sp = step_px * zoom;
    if (sp <= 0.0001) return 0;
    const content = (@as(f32, @floatFromInt(px - x)) + scroll_s) / sp;
    return @intFromFloat(@round(content));
}

/// **曲率手柄 → 曲率**（主流 DAW 手感：手柄被夹在两锚点构成的平行四边形内，**永不过冲**）：
/// 手柄的 y 就是“曲线在 pivot 处的值”，它被夹到**两端值之间**，
/// 于是整条曲线（端点精确、鼓包只能落在两点值之间）不会超出两端值。
pub fn curveFromHandle(a: f32, b: f32, pivot: f32, want_value: f32) f32 {
    const p = std.math.clamp(pivot, 0.0, 1.0);
    const chord = a + (b - a) * p;
    const lo = @min(a, b);
    const hi = @max(a, b);
    return std.math.clamp(want_value, lo, hi) - chord;
}

/// 曲率手柄的 **pivot 允许范围**（满了 = 允许贴到锚点所在的**垂直线**）。
/// 叠到锚点上时靠“命中取更近者、平局归手柄”区分（见下方命中测试）。
pub const pivot_min: f32 = 0.0;
pub const pivot_max: f32 = 1.0;

/// 段太窄/太矮 → 手柄**隐藏且不可点**（否则与锚点抢点击）。横竖用**同一个阈值**。
fn handleTooSmall(a: Point, b: Point, x: i32, step_px: f32, zoom: f32, scroll_s: f32, h: i32) bool {
    const x1 = xOf(@floatFromInt(a.step), x, step_px, zoom, scroll_s);
    const x2 = xOf(@floatFromInt(b.step), x, step_px, zoom, scroll_s);
    if (@as(f32, @floatFromInt(x2 - x1)) < handle_min_extent) return true;
    return @as(f32, @floatFromInt(h)) * @abs(b.value - a.value) < handle_min_extent;
}

/// 段内曲率手柄位置（主流 DAW 手感）：**x 由 `pivot` 决定**（左右可拖）、y = 曲线在该处的值。
/// 手柄始终贴在曲线上，且被夹在两个锚点构成的平行四边形内（x ∈ [x1,x2]，值 ∈ [两端值]）。
fn curveHandlePos(lane: *const Lane, i: usize, x: i32, y: i32, h: i32, step_px: f32, zoom: f32, scroll_s: f32) ?struct { x: i32, y: i32 } {
    const ps = lane.points.items;
    if (i + 1 >= ps.len) return null;
    const a = ps[i];
    const b = ps[i + 1];
    if (b.step <= a.step) return null; // 零宽段（断崖）没有水平可拖空间 → 不做手柄
    if (handleTooSmall(a, b, x, step_px, zoom, scroll_s, h)) return null;
    const p = std.math.clamp(a.pivot, pivot_min, pivot_max);
    const step_f: f32 = @as(f32, @floatFromInt(a.step)) + @as(f32, @floatFromInt(b.step - a.step)) * p;
    const lo = @min(a.value, b.value);
    const hi = @max(a.value, b.value);
    const v = a.value + (b.value - a.value) * p + (if (lane.interp == .smooth) a.curve else 0.0);
    return .{ .x = xOf(step_f, x, step_px, zoom, scroll_s), .y = yOf(std.math.clamp(v, lo, hi), y, h) };
}

/// 绘制 + 处理手势。调用方负责面板背景/网格/游标；这里只管 lane 本体
/// （曲线 + 锚点 + 曲率手柄）与鼠标手势。
pub fn draw(
    ui: *Ui,
    lane: *Lane,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    step_px: f32,
    bar_steps: i32,
    scroll_x: i32,
    zoom: f32,
    alloc: std.mem.Allocator,
) void {
    _ = bar_steps; // 网格/刻度由调用方绘制（此处不重复画）
    // **内容坐标 → 内部步号**：`scroll_x` 是内容像素、`step_px` 是内容步宽 →
    // 左沿对应的步号在此**唯一一处**换算（以前让调用方传，出现过 “传了像素当步数”
    // 的 bug：静止时看不出、Ctrl+滚轮缩放时曲线与网格各走各的）。
    const scroll_s: f32 = @as(f32, @floatFromInt(scroll_x)) * zoom; // 屏幕滚动（精确；与网格同源）
    if (w <= 8 or h <= 16) return;
    const r = &ui.renderer;

    // ⚠️ **不铺底色、不画网格**——底色/竖向网格/游标由调用方铺满**整个面板**。
    // 这里只负责：曲线 + 曲率手柄 + 锚点 + 手势。
    const saved_clip = r.pushClip(x, y, w, h);
    defer r.popClip(saved_clip);

    const ps = lane.points.items;

    // ── 命中测试 + 悬停状态（**绘制之前**先算：hover 外环不滞后一帧）──
    const inside = util.inRect(ui.mouse_x, ui.mouse_y, x, y, w, h);

    // 命中：**曲率手柄优先**（否则手柄贴到锚点边上就再也抓不回来），
    // 但**鼠标离锚点更近（含相等）→ 归锚点**——这样“叠在一起”时仍能拖锚点。
    var hit_anchor: ?usize = null;
    for (ps, 0..) |p, i| {
        const px = xOf(@floatFromInt(p.step), x, step_px, zoom, scroll_s);
        const py = yOf(p.value, y, h);
        if (ui.mouse_x >= px - anchor_half - 2 and ui.mouse_x <= px + anchor_half + 2 and
            ui.mouse_y >= py - anchor_half - 2 and ui.mouse_y <= py + anchor_half + 2)
        {
            hit_anchor = i;
            break;
        }
    }
    var hit_curve: ?usize = null;
    if (lane.interp == .smooth) {
        var i: usize = 0;
        while (i + 1 < ps.len) : (i += 1) {
            if (curveHandlePos(lane, i, x, y, h, step_px, zoom, scroll_s)) |hp| {
                if (ui.mouse_x >= hp.x - handle_half and ui.mouse_x <= hp.x + handle_half and
                    ui.mouse_y >= hp.y - handle_half and ui.mouse_y <= hp.y + handle_half)
                {
                    hit_curve = i;
                    break;
                }
            }
        }
    }
    if (hit_curve != null and hit_anchor != null) {
        const ci = hit_curve.?;
        const ai = hit_anchor.?;
        const cp = curveHandlePos(lane, ci, x, y, h, step_px, zoom, scroll_s).?;
        const ap_x = xOf(@floatFromInt(ps[ai].step), x, step_px, zoom, scroll_s);
        const ap_y = yOf(ps[ai].value, y, h);
        const d_curve = @max(@abs(ui.mouse_x - cp.x), @abs(ui.mouse_y - cp.y));
        const d_anchor = @max(@abs(ui.mouse_x - ap_x), @abs(ui.mouse_y - ap_y));
        // **严格更近的锚点才抢**；平局归手柄（否则手柄贴到锚点就再也抓不回来）
        if (d_anchor < d_curve) hit_curve = null else hit_anchor = null;
    }

    // 光标：**一律保持默认箭头**（用户拍板）——可操作提示由锚点/手柄自身的高亮承担。
    // 记录悬停对象（供 hover 外环与行头列读数用；拖动中优先看 `drag_*`）
    if (lane.sel_idx) |si| {
        if (si >= ps.len) lane.sel_idx = null;
    }
    lane.hover_kind = .none;
    if (inside) {
        if (hit_anchor) |i| {
            lane.hover_kind = .anchor;
            lane.hover_idx = i;
        } else if (hit_curve) |i| {
            lane.hover_kind = .curve;
            lane.hover_idx = i;
        }
    }

    // ── 绘制 ──
    // 实际曲线：逐像素列**连续**求值（`stepOfXf` 返回小数步 → 平滑，无 1/96 台阶）
    // 注：原来还画一条“锚点直连”的灰色参考线，它在 `curve ≠ 0` / `hold` 段与真值不符
    // （用户实测“白线和蓝线到底跟哪条”），已按用户要求**删除**。
    if (ps.len >= 2) {
        var px = x;
        var has_prev = false;
        var prev_x: i32 = 0;
        var prev_y: i32 = 0;
        var prev_st: f32 = 0;
        while (px <= x + w) : (px += 1) {
            const st = stepOfXf(px, x, step_px, zoom, scroll_s);
            const cy = yOf(lane.evalAt(st), y, h);
            if (has_prev) {
                // **断崖**（同一步的多个点）：这一列不画斜线——竖向由下面“按数据画”的
                // 真·竖线负责。否则 1px 斜线看起来像“两条差 1~2px 的竖线”。
                var cliff = false;
                for (ps[0 .. ps.len - 1], ps[1..]) |aa, bb| {
                    if (bb.step != aa.step) continue;
                    const s: f32 = @floatFromInt(aa.step);
                    if (prev_st < s and st >= s) {
                        cliff = true;
                        break;
                    }
                }
                if (!cliff) r.line(prev_x, prev_y, px, cy, ui.theme.accent);
            }
            prev_x = px;
            prev_y = cy;
            prev_st = st;
            has_prev = true;
        }
    }

    // **断崖竖线：直接从数据画**（不经过逐像素采样）——x 用与锚点方块**同一个** `xOf`，
    // 保证竖线精确穿过两个锚点，不会差 1~2px。
    if (ps.len >= 2) {
        for (ps[0 .. ps.len - 1], ps[1..]) |aa, bb| {
            if (bb.step != aa.step) continue;
            const vx = xOf(@floatFromInt(aa.step), x, step_px, zoom, scroll_s);
            const y0 = yOf(aa.value, y, h);
            const y1 = yOf(bb.value, y, h);
            const top = @min(y0, y1);
            const len: i32 = @max(1, @as(i32, @intCast(@abs(y1 - y0))));
            r.vline(vx, top, len, ui.theme.accent);
        }
    }

    // **只有一个点时**：画一条穿过它的水平线——否则用户看不到“这个值作用于整条曲线”
    if (ps.len == 1) {
        r.hline(x, yOf(ps[0].value, y, h), w, ui.theme.accent);
    }

    // 曲率手柄（菱形近似：4 条线）：悬停/拖动中 → accent（“可抓”提示，替代改鼠标形状）
    // 注：先画手柄、后画锚点（锚点默认在上）；**悬停的手柄**在锚点之后**补画一遍**，
    // 实现“hover 到谁谁在上”。
    const drawHandle = struct {
        fn f(ui2: *Ui, hx: i32, hy: i32, col: u32) void {
            const rr = &ui2.renderer;
            rr.line(hx, hy - handle_half, hx + handle_half, hy, col);
            rr.line(hx + handle_half, hy, hx, hy + handle_half, col);
            rr.line(hx, hy + handle_half, hx - handle_half, hy, col);
            rr.line(hx - handle_half, hy, hx, hy - handle_half, col);
        }
    }.f;
    const handleHot = struct {
        fn f(l: *const Lane, i: usize) bool {
            return (l.drag_kind == .curve and l.drag_idx == i) or
                (l.drag_kind == .none and l.hover_kind == .curve and l.hover_idx == i);
        }
    }.f;
    if (lane.interp == .smooth and ps.len >= 2) {
        var i: usize = 0;
        while (i + 1 < ps.len) : (i += 1) {
            if (curveHandlePos(lane, i, x, y, h, step_px, zoom, scroll_s)) |hp| {
                drawHandle(ui, hp.x, hp.y, if (handleHot(lane, i)) ui.theme.accent else ui.theme.text);
            }
        }
    }

    // 锚点（方块 + 蓝色外环）
    // - **悬停**：只加外环（与选中环同款）→ 取代“改鼠标形状”的 hover 提示
    // - **选中 / 拖动中**：外环 + 方块本身变 accent（与“仅悬停”区分）
    for (ps, 0..) |p, i| {
        const px = xOf(@floatFromInt(p.step), x, step_px, zoom, scroll_s);
        const py = yOf(p.value, y, h);
        const dragging = lane.drag_kind == .anchor and lane.drag_idx == i;
        const selected = lane.sel_idx != null and lane.sel_idx.? == i;
        const hovered = lane.drag_kind == .none and lane.hover_kind == .anchor and lane.hover_idx == i;
        const col = if (dragging or selected) ui.theme.accent else ui.theme.text;
        if (dragging or selected or hovered) {
            const rs = anchor_half + 3;
            r.fillRect(px - rs, py - rs, rs * 2 + 1, 1, ui.theme.accent);
            r.fillRect(px - rs, py + rs, rs * 2 + 1, 1, ui.theme.accent);
            r.fillRect(px - rs, py - rs, 1, rs * 2 + 1, ui.theme.accent);
            r.fillRect(px + rs, py - rs, 1, rs * 2 + 1, ui.theme.accent);
        }
        r.fillRect(px - anchor_half, py - anchor_half, anchor_half * 2, anchor_half * 2, col);
    }

    // **hover / 拖动到谁，谁补画在最上**：锚点已经后画（默认在上），
    // 所以这里只需把“热的”曲率手柄再补画一遍。
    if (lane.interp == .smooth) {
        if (lane.drag_kind == .curve) {
            if (curveHandlePos(lane, lane.drag_idx, x, y, h, step_px, zoom, scroll_s)) |hp| {
                drawHandle(ui, hp.x, hp.y, ui.theme.accent);
            }
        } else if (lane.hover_kind == .curve) {
            if (curveHandlePos(lane, lane.hover_idx, x, y, h, step_px, zoom, scroll_s)) |hp| {
                drawHandle(ui, hp.x, hp.y, ui.theme.accent);
            }
        }
    }

    // ── 手势（命中结果见上方）──
    // 左键点选：锚点 → 选中（读数/键入以它为准）；点空白 → 取消选中
    if (ui.mouse_pressed and inside and !ui.mouse_double) {
        if (hit_anchor) |i| {
            lane.sel_idx = i;
        } else if (hit_curve == null) {
            lane.sel_idx = null;
        }
    }

    // 按下：开始拖动 / 双击加点 / 右键删点
    if (ui.mouse_pressed and inside) {
        if (ui.mouse_double) {
            // 双击曲率手柄 → 本段恢复直线：**curve 归零 + pivot 回到段中点**
            // （否则手柄会停在边上，看起来“还是歪的”，得再手动拖回来）
            if (hit_curve) |i| {
                lane.points.items[i].curve = 0;
                lane.points.items[i].pivot = 0.5;
            } else if (hit_anchor == null) {
                const st = @max(0, stepOfX(ui.mouse_x, x, step_px, zoom, scroll_s));
                _ = lane.insertPoint(alloc, st, valueOfY(ui.mouse_y, y, h));
            }
        } else if (hit_anchor) |i| {
            lane.drag_kind = .anchor;
            lane.drag_idx = i;
            // **抓取偏移**：点相对鼠标的偏移，拖动时保持 → 按下不再“瞬移到鼠标处”
            lane.grab_step = lane.points.items[i].step - stepOfX(ui.mouse_x, x, step_px, zoom, scroll_s);
            lane.grab_value = lane.points.items[i].value - valueOfY(ui.mouse_y, y, h);
            ui.active_id = 7701;
        } else if (hit_curve) |i| {
            // Ctrl + 拖 → 直接吸附成直线
            if (ui.mods_ctrl) lane.points.items[i].curve = 0 else {
                lane.drag_kind = .curve;
                lane.drag_idx = i;
                // **抓取偏移（两个轴都要）**：否则按下瞬间手柄会瞬移到鼠标位置——
                // 旧代码只算了 y 且用的还是**旧公式**（中点 + curve，忽略 pivot）→ “单击手柄乱跑”。
                const a0 = lane.points.items[i];
                const b0 = lane.points.items[i + 1];
                const lo0 = @min(a0.value, b0.value);
                const hi0 = @max(a0.value, b0.value);
                // pivot 夹在 [0.1, 0.9]（避免与锚点完全重叠）
                const p0 = std.math.clamp(a0.pivot, pivot_min, pivot_max);
                const handle_v0 = std.math.clamp(a0.value + (b0.value - a0.value) * p0 + a0.curve, lo0, hi0);
                lane.grab_value = handle_v0 - valueOfY(ui.mouse_y, y, h);
                // x：把鼠标位置换算成“该处的 pivot”，记下与当前 pivot 的差
                const x1 = xOf(@floatFromInt(a0.step), x, step_px, zoom, scroll_s);
                const x2 = xOf(@floatFromInt(b0.step), x, step_px, zoom, scroll_s);
                const span_px: f32 = @floatFromInt(@max(1, x2 - x1));
                const mouse_p = std.math.clamp(@as(f32, @floatFromInt(ui.mouse_x - x1)) / span_px, 0.0, 1.0);
                lane.grab_pivot = p0 - mouse_p;
                ui.active_id = 7702;
            }
        }
    }

    // 右键：删锚点（至少保留 1 个）
    if (ui.mouse_right_pressed and inside) {
        if (hit_anchor) |i| {
            if (lane.points.items.len > 1) lane.removeAt(i);
        }
    }

    // 拖动中
    if (lane.drag_kind != .none) {
        if (!ui.mouse_down or ui.active_id == 0) {
            // **松手必须把 active_id 还回去**：否则它会一直卡在 7701/7702，
            // 所有“要求 active_id == 0”的控件（窗口右上角 ×）全部失灵（实测）。
            if (ui.active_id == 7701 or ui.active_id == 7702) ui.active_id = 0;
            lane.drag_kind = .none;
        } else switch (lane.drag_kind) {
            .none => {},
            .anchor => {
                const i = @min(lane.drag_idx, lane.points.items.len -| 1);
                if (lane.points.items.len > 0) {
                    const p = &lane.points.items[i];
                    // 追“鼠标 − 抓取偏移”而不是鼠标本身（否则按下即微跳）
                    p.value = std.math.clamp(valueOfYRaw(ui.mouse_y, y, h) + lane.grab_value, 0.0, 1.0);
                    // **位置手柄不互插**（主流 DAW 手感）：水平被夹在左右邻居之间——
                    // 允许**等于**邻居的步（同一步多点 = 垂直断崖，组内顺序 = 出生顺序），
                    // 但不能越过它们。因此数组顺序永不改变，无需重排（重排会把本段曲率换给别的段）。
                    var st: i32 = @max(0, stepOfX(ui.mouse_x, x, step_px, zoom, scroll_s) + lane.grab_step);
                    if (i > 0) st = @max(st, lane.points.items[i - 1].step);
                    if (i + 1 < lane.points.items.len) st = @min(st, lane.points.items[i + 1].step);
                    p.step = st;
                }
            },
            .curve => {
                const i = @min(lane.drag_idx, lane.points.items.len -| 1);
                if (i + 1 < lane.points.items.len) {
                    const a = lane.points.items[i];
                    const b = lane.points.items[i + 1];
                    // **手柄在平行四边形内活动**（不过冲）：
                    // x → `pivot`（夹到两端之间）；y → `curve`（= 曲线在该处的值与直连线之差）。
                    const x1 = xOf(@floatFromInt(a.step), x, step_px, zoom, scroll_s);
                    const x2 = xOf(@floatFromInt(b.step), x, step_px, zoom, scroll_s);
                    const span_px: f32 = @floatFromInt(@max(1, x2 - x1));
                    const want = valueOfYRaw(ui.mouse_y, y, h) + lane.grab_value;
                    const pv = std.math.clamp(@as(f32, @floatFromInt(ui.mouse_x - x1)) / span_px + lane.grab_pivot, pivot_min, pivot_max);
                    lane.points.items[i].pivot = pv;
                    // 手柄夹在平行四边形内（两端值之间）→ 曲线**永不过冲**
                    lane.points.items[i].curve = curveFromHandle(a.value, b.value, pv, want);
                }
            },
        }
    }
}

// ─────────────────────────── 单测 ───────────────────────────

test "view_lane: 曲率手柄不过冲——值被夹在两端之间（平行四边形的上下边）" {
    // 段：0.2 → 0.8；pivot 0.5 时直连线值 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), curveFromHandle(0.2, 0.8, 0.5, 9.9), 1e-6); // 顶到上限 → 峰值 = 0.8
    try std.testing.expectApproxEqAbs(@as(f32, -0.3), curveFromHandle(0.2, 0.8, 0.5, -9.9), 1e-6); // 顶到下限 → 峰值 = 0.2
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curveFromHandle(0.2, 0.8, 0.5, 0.5), 1e-6); // 不拖 = 直线
    // pivot 偏左 → 直连线更靠近下端 → 可向上支配的空间变大
    try std.testing.expectApproxEqAbs(@as(f32, 0.48), curveFromHandle(0.2, 0.8, 0.2, 9.9), 1e-6); // 0.8 − (0.2+0.6*0.2)
    // 平段：两端同值 → 手柄没有活动余地（不允许造出鼓包 = 不过冲）
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curveFromHandle(0.5, 0.5, 0.5, 9.9), 1e-6);
}

test "view_lane: 同一步多点 = 垂直断崖（左取组内最左、右取组内最右）" {
    const a = std.testing.allocator;
    var lane = Lane{ .interp = .linear };
    defer lane.deinit(a);
    _ = lane.insertPoint(a, 0, 0.5);
    _ = lane.insertPoint(a, 48, 0.9); // 断崖**左侧**的高度
    _ = lane.insertPoint(a, 48, 0.1); // 同一步第二个点（出生在后 → 组内最右）
    _ = lane.insertPoint(a, 96, 0.5);
    // 段落：0→(48,0.9) 线性；断崖处瞬间跳到 0.1；然后 (48,0.1)→(96,0.5)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 + 0.4 * (47.5 / 48.0)), lane.evalAt(47.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), lane.evalAt(48.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1 + 0.4 * 0.5), lane.evalAt(72.0), 1e-6);
}

test "view_lane: 曲率手柄可左右挪（pivot）——折点跟着手柄走" {
    const a = std.testing.allocator;
    var lane = Lane{ .interp = .smooth };
    defer lane.deinit(a);
    _ = lane.insertPoint(a, 0, 0.2);
    _ = lane.insertPoint(a, 96, 0.8);
    const p = &lane.points.items[0];
    p.pivot = 0.25; // 手柄拖到左侧 1/4
    p.curve = curveFromHandle(0.2, 0.8, 0.25, 0.65); // 手柄停在 0.65（直连线 0.35 + 0.3）
    // 远离折点的两侧 = 向手柄的**直线**（不是向弦线）
    try std.testing.expectApproxEqAbs(@as(f32, 0.29), lane.evalAt(4.8), 5e-3); // t=0.05：0.2+(0.65-0.2)*0.2
    try std.testing.expectApproxEqAbs(@as(f32, 0.79), lane.evalAt(91.2), 5e-3); // t=0.95：0.65+(0.8-0.65)*0.9333
    // 折点处被抬到 0.65 附近（手柄位置；倒圆角会让它略内收一点）
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), lane.evalAt(24.0), 6e-2);
    // pivot 挪到 0.75：此时手柄落回直连线上 → 整段就是直线
    p.pivot = 0.75;
    p.curve = curveFromHandle(0.2, 0.8, 0.75, 0.65);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), lane.evalAt(72.0), 1e-4);
}

test "view_lane: 段形状 = 折线 A→H→B + H 处倒圆角（主流 DAW 手感）" {
    const a = std.testing.allocator;
    var lane = Lane{ .interp = .smooth };
    defer lane.deinit(a);
    _ = lane.insertPoint(a, 0, 0.8); // 左高
    _ = lane.insertPoint(a, 96, 0.2); // 右低
    lane.points.items[0].pivot = 0.5;
    lane.points.items[0].curve = curveFromHandle(0.8, 0.2, 0.5, -9.9); // 拉到底 → H = 0.2
    // 两端精确穿过锚点
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), lane.evalAt(0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(96), 1e-5);
    // **两侧是直线**（这才是主流 DAW 的手感；旧“平滑鼓包”会变成 S 形波浪）
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lane.evalAt(24), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(72), 1e-3);
    // 手柄处是**圆角**：比折点（0.2）略内收一点，既不是尖角也不是鼓包
    const corner = lane.evalAt(48);
    try std.testing.expect(corner > 0.2 and corner < 0.35);
    // 全程单调下降，且永不越出两端值（不过冲）
    var prev: f32 = 1.0;
    var st: i32 = 0;
    while (st <= 96) : (st += 1) {
        const v = lane.evalAt(@floatFromInt(st));
        try std.testing.expect(v <= prev + 1e-6);
        try std.testing.expect(v >= 0.2 - 1e-4 and v <= 0.8 + 1e-4);
        prev = v;
    }
}

test "view_lane: 曲率数学——穿过锚点、折点在 H、hold 段阶跃" {
    const a = std.testing.allocator;
    var lane = Lane{ .interp = .linear };
    defer lane.deinit(a);
    _ = lane.insertPoint(a, 0, 0.2);
    _ = lane.insertPoint(a, 96, 0.2);

    // 直线：中点仍是 0.2
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(48), 1e-4);

    // 平段不允许鼓包（不过冲规则）→ 给了 curve 也只是直线
    lane.interp = .smooth;
    lane.points.items[0].curve = 0.4;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(48), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(96), 1e-4);

    // 负曲率一样不生效（两端同值 → 折点也被夹在同一高度）
    lane.points.items[0].curve = -0.15;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(48), 1e-4);

    // hold：整段保持左值
    lane.interp = .hold;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(80), 1e-4);

    // 范围外 → 端点值（“保持”语义）
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(-10), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), lane.evalAt(500), 1e-4);

    // 空 lane → -1（调用方据此回落静态值）
    var empty = Lane{};
    defer empty.deinit(a);
    try std.testing.expect(empty.evalAt(0) < 0);
}

/// `drawValueHeader` 的返回（值行是否被点、以及值行矩形）\npub const HeaderHit = struct { value_clicked: bool, rect: Rect };\n\n/// 简单矩形（行头列命中判断用）
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

// ─────────────────────────── 显示单位 ───────────────────────────

/// 曲线的**显示单位**（存储永远是归一化 0..1）。一条曲线可绑多个异构目标，
/// 所以单位是“曲线的显示设置”，由用户在行头列顶部切换。
pub const Unit = enum {
    percent, // 0–100
    midi, // 0–127
    db, // 20·log10(v)，−60dB 及以下 = 静音
    bpm, // 20–999
    pan, // L100 – C – R100

    pub fn label(u: Unit) []const u8 {
        return switch (u) {
            .percent => "百分比",
            .midi => "MIDI",
            .db => "dB",
            .bpm => "BPM",
            .pan => "PAN",
        };
    }
};

/// 归一化值 → 显示字符串（`buf` 由调用方给）
pub fn formatValue(u: Unit, v: f32, buf: []u8) []const u8 {
    const vc = std.math.clamp(v, 0.0, 1.0);
    return switch (u) {
        .percent => std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(@round(vc * 100.0)))}) catch "",
        .midi => std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(@round(vc * 127.0)))}) catch "",
        .db => blk: {
            if (vc <= 0.0005) break :blk "静音";
            const db = 20.0 * std.math.log10(vc);
            const dbc = std.math.clamp(db, -60.0, 6.0);
            break :blk std.fmt.bufPrint(buf, "{d:.1}", .{dbc}) catch "";
        },
        .bpm => std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(@round(20.0 + vc * 979.0)))}) catch "",
        .pan => blk: {
            const p: i32 = @intFromFloat(@round((vc * 2.0 - 1.0) * 100.0));
            if (p == 0) break :blk "C";
            break :blk if (p < 0)
                std.fmt.bufPrint(buf, "L{d}", .{@as(i32, @intCast(-p))}) catch ""
            else
                std.fmt.bufPrint(buf, "R{d}", .{p}) catch "";
        },
    };
}

/// 显示字符串 → 归一化值（键入用）。解析失败返回 null。
pub fn parseValue(u: Unit, text_in: []const u8) ?f32 {
    const text = std.mem.trim(u8, text_in, " ");
    if (text.len == 0) return null;
    switch (u) {
        .percent => {
            const x = std.fmt.parseFloat(f32, text) catch return null;
            return std.math.clamp(x / 100.0, 0.0, 1.0);
        },
        .midi => {
            const x = std.fmt.parseFloat(f32, text) catch return null;
            return std.math.clamp(x / 127.0, 0.0, 1.0);
        },
        .db => {
            const x = std.fmt.parseFloat(f32, text) catch return null;
            if (x <= -60.0) return 0.0; // −60dB 及以下 = 静音（用户拍板）
            return std.math.clamp(std.math.pow(f32, 10.0, x / 20.0), 0.0, 1.0);
        },
        .bpm => {
            const x = std.fmt.parseFloat(f32, text) catch return null;
            return std.math.clamp((x - 20.0) / 979.0, 0.0, 1.0);
        },
        .pan => {
            if (text.len == 1 and (text[0] == 'C' or text[0] == 'c')) return 0.5;
            var t2 = text;
            var sign: f32 = 1.0;
            if (t2[0] == 'L' or t2[0] == 'l') {
                sign = -1.0;
                t2 = t2[1..];
            } else if (t2[0] == 'R' or t2[0] == 'r') {
                t2 = t2[1..];
            }
            const x = std.fmt.parseFloat(f32, t2) catch return null;
            return std.math.clamp((sign * x + 100.0) / 200.0, 0.0, 1.0);
        },
    }
}

/// 该 lane 可作为显示单位循环切换的单位（按目标种类过滤：BPM 曲线不出现 PAN 等）
pub fn unitCycle(lane: *const Lane, out: *[4]Unit) []const Unit {
    var n: usize = 0;
    out[n] = .percent;
    n += 1;
    switch (lane.target.kind) {
        .mixer_pan, .inst_pan => {
            // 声像类：附带 MIDI（CC10 原生单位）与 PAN
            out[n] = .midi;
            n += 1;
            out[n] = .pan;
            n += 1;
        },
        else => {
            out[n] = .midi;
            n += 1;
            out[n] = .db;
            n += 1;
        },
    }
    return out[0..n];
}

/// 切到下一个可用单位
pub fn cycleUnit(lane: *Lane) void {
    var buf: [4]Unit = undefined;
    const list = unitCycle(lane, &buf);
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        if (list[i] == lane.display_unit) break;
    }
    lane.display_unit = list[(i + 1) % list.len];
}

/// **行头列顶部两行**（两个编辑区共用）：
/// 第 1 行 = 单位按钮（点击循环切换），第 2 行 = 当前数值（未来可点击键入）。
/// 返回本帧数值行的矩形（x, y, w, h），供调用方做“点击键入”的命中判断。
pub fn drawValueHeader(ui: *Ui, lane: *Lane, x: i32, y: i32, header_w: i32) HeaderHit {
    const row_h: i32 = 18;
    const bx = x + 2;
    const bw = header_w - 3;
    // 第 1 行：单位按钮（整行宽；点击循环切换）
    {
        const ubtn_y = y + 2;
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx, ubtn_y, bw, row_h - 2);
        if (hovered) ui.renderer.fillRect(bx, ubtn_y, bw, row_h - 2, ui.theme.toolbar);
        var ubuf: [20]u8 = undefined;
        const ut = std.fmt.bufPrint(&ubuf, "单位：{s}", .{Unit.label(lane.display_unit)}) catch "";
        ui.labelClipped(ut, bx + 2, ubtn_y + 2, bw - 4, if (hovered) ui.theme.accent else ui.theme.text);
        if (hovered and ui.mouse_pressed) cycleUnit(lane); // 点击型动作：不认领 active_id
    }
    // 第 2 行：数值（**点击 → 键入**；调用方负责弹输入框）
    const val = Rect{ .x = bx, .y = y + 2 + row_h, .w = bw, .h = row_h - 2 };
    const v_hovered = util.inRect(ui.mouse_x, ui.mouse_y, val.x, val.y, val.w, val.h);
    if (v_hovered) ui.renderer.fillRect(val.x, val.y, val.w, val.h, ui.theme.toolbar);
    var rbuf: [24]u8 = undefined;
    var vbuf: [32]u8 = undefined;
    const vt = std.fmt.bufPrint(&vbuf, "值：{s}", .{activeReadout(lane, &rbuf) orelse "—"}) catch "—";
    ui.labelClipped(vt, val.x + 2, val.y + 2, val.w - 4, if (v_hovered) ui.theme.accent else ui.theme.text);
    const clicked = v_hovered and ui.mouse_pressed and lane.sel_idx != null;
    return .{ .value_clicked = clicked, .rect = val };
}

/// **正在调整 / 悬停的点的读数**（行头列顶部固定行显示）。`null` = 当前没有可读的点。
/// 拖动中优先；其次悬停；都没有返回 null（调用方显示“—”）。
pub fn activeReadout(lane: *const Lane, buf: []u8) ?[]const u8 {
    var kind: DragKind = .none;
    var idx: usize = 0;
    if (lane.drag_kind != .none) {
        kind = lane.drag_kind;
        idx = lane.drag_idx;
    } else if (lane.sel_idx) |si| {
        kind = .anchor;
        idx = si;
    } else if (lane.hover_kind != .none) {
        kind = lane.hover_kind;
        idx = lane.hover_idx;
    }
    if (kind == .none) return null;
    const ps = lane.points.items;
    if (idx >= ps.len) return null;
    return switch (kind) {
        .anchor => formatValue(lane.display_unit, ps[idx].value, buf),
        .curve => blk: {
            if (idx + 1 >= ps.len) break :blk null;
            const pct: i32 = @intFromFloat(@round(ps[idx].curve * 100.0));
            break :blk std.fmt.bufPrint(buf, "曲率 {d}%", .{pct}) catch null;
        },
        .none => null,
    };
}

// ─────────────────────── 编辑器外壳（两个编辑区共用） ───────────────────────

/// 编辑器外壳的几何参数。**钢琴窗底部编辑区与播放列表自动化区都用这一份**，
/// 于是“底色/网格/分隔线/游标/行头列列表”只有一处实现（曾经两边各写一份，
/// 反复出现 1–3px 对不齐、横线缺失、游标被盖等问题）。
pub const Shell = struct {
    /// 面板块（含行头列）：与钢琴窗 `x+1, w-2` / 播放列表 `main_x, panel_w` 对应
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    /// 网格区左沿（行头列右沿）
    lane_x: i32,
    /// **内容**步宽（未乘 zoom；由本函数统一乘——调用方只给内容坐标，避免“有的地方乘了有的没乘”）
    step_w: f32,
    zoom: f32,
    /// **内容**滚动步数（未乘 zoom）
    scroll_x: i32,
    bar_steps: i32,
    beat_steps: i32,
    snap_steps: i32,
    /// 播放游标（步；null = 不画）
    cursor_step: ?f32,
    playing: bool,
};

/// 画外壳：底色 + 顶线 + 行头列分隔线 + 竖向网格（小节/拍/吸附格）+ 可选播放游标。
/// **横向值参考线不在这里**：它依赖“值 → 像素”的映射（力度柱条 / 包络线性），归内容层。
pub fn drawShell(ui: *Ui, sh: Shell) void {
    const r = &ui.renderer;
    if (sh.w <= 4 or sh.h <= 4) return;
    r.fillRect(sh.x, sh.y, sh.w, sh.h, ui.theme.bg);
    r.hline(sh.x, sh.y, sh.w, ui.theme.panel_border);
    r.vline(sh.lane_x, sh.y, sh.h, ui.theme.panel_border);

    const grid_w = @max(1, sh.x + sh.w - sh.lane_x);
    const step_ws: f32 = sh.step_w * sh.zoom; // 屏上步宽
    const scroll_s: f32 = @as(f32, @floatFromInt(sh.scroll_x)) * sh.zoom; // 屏上滚动
    {
        const saved = r.pushClip(sh.lane_x, sh.y, grid_w, sh.h);
        defer r.popClip(saved);
        // 竖向网格：与音符区/播放列表**同一个函数**、**同样的内容坐标参数**
        util.drawTimelineGrid(
            r,
            &ui.theme,
            sh.lane_x,
            grid_w,
            sh.y,
            sh.h,
            sh.lane_x,
            sh.scroll_x,
            sh.zoom,
            sh.step_w,
            sh.bar_steps,
            @max(1, sh.beat_steps),
            sh.snap_steps,
        );
        // 播放游标：与音符区/标尺**同一映射**（只画竖线，不带标尺倒三角）
        if (sh.cursor_step) |cs| {
            const cx = sh.lane_x + @as(i32, @intFromFloat(cs * step_ws - scroll_s));
            if (cx >= sh.lane_x and cx < sh.lane_x + grid_w) {
                r.vline(cx, sh.y, sh.h, if (sh.playing) ui.theme.cursor_play else ui.theme.cursor_idle);
            }
        }
    }
}

/// 行头列 lane 列表的一项
pub const ListEntry = struct { text: []const u8, active: bool };

/// 列表命中结果：`index` = 左键点中；`right` = 右键点中；`dbl` = 双击
pub const ListHit = struct { index: ?usize = null, right: ?usize = null, dbl: ?usize = null };

/// 在行头列画 **lane 列表**（每行 18px、选中高亮、**榨满行头列**、**可滚动 + 右侧细滚动条**）。
/// `scroll` = 顶部跳过的行数（调用方持有；本函数负责轮盘滚动与钳制）。
/// 返回被点中的**绝对下标**（`scroll + 可见行号`）。
/// 点击型动作：**不认领 `active_id`**（认领了就必须有人清，否则会卡死标题栏 ×）。
pub fn drawList(ui: *Ui, x: i32, y: i32, h: i32, header_w: i32, top_row: i32, scroll: *i32, entries: []const ListEntry) ListHit {
    const row_h: i32 = 18;
    const bx = x + 2;
    const bw = header_w - 3;
    const list_y = y + 4 + top_row;
    const list_h = @max(row_h, y + h - list_y);
    const view_rows: i32 = @max(1, @divTrunc(list_h, row_h));
    const content_rows: i32 = @intCast(entries.len);
    const max_scroll: i32 = @max(0, content_rows - view_rows);
    // 轮盘滚动（鼠标在本列内才吃；吃完清零 wheel，防下层再滚）
    if (util.inRect(ui.mouse_x, ui.mouse_y, bx - 1, list_y, bw + 1, list_h) and ui.wheel != 0 and max_scroll > 0) {
        scroll.* = std.math.clamp(scroll.* - ui.wheel, 0, max_scroll);
        ui.wheel = 0;
    }
    scroll.* = std.math.clamp(scroll.*, 0, max_scroll);

    var hit = ListHit{};
    var i: usize = @intCast(scroll.*);
    var by = list_y;
    while (i < entries.len and by + row_h <= list_y + list_h) : (i += 1) {
        const it = entries[i];
        const hovered = util.inRect(ui.mouse_x, ui.mouse_y, bx - 1, by, bw + 1, row_h);
        if (it.active) ui.renderer.fillRect(bx - 1, by, bw + 1, row_h - 1, ui.theme.toolbar);
        const col: r_mod.Color = if (it.active) ui.theme.accent else ui.theme.text;
        ui.labelClipped(it.text, bx + 2, by + 2, bw - 3, col);
        if (hovered) {
            if (ui.mouse_pressed) hit.index = i;
            if (ui.mouse_double) hit.dbl = i;
            if (ui.mouse_right_pressed) hit.right = i;
        }
        by += row_h;
    }
    // 右侧细滚动条（与乐器/调音台同款 5px）
    if (content_rows > view_rows) {
        // 注意：`drawScrollbar` 的 `scroll` 单位是**像素**（与 content/view 同单位）——
        // 传行数会让 thumb 永远贴在顶端（实测）。
        ui.drawScrollbar(x + header_w - 6, list_y, 5, list_h, scroll.* * row_h, content_rows * row_h, list_h);
    }
    return hit;
}

// ─────────────────── 下方编辑面板的统一布局（播放列表 / 钢琴窗共用） ───────────────────

/// 面板布局结果
pub const PanelLayout = struct {
    /// 编辑面板高度（不含分割条）
    panel_h: i32,
    /// 面板上方内容区（轨道 / 音符）可用高度
    content_h: i32,
    /// 分割条 y
    split_y: i32,
    /// 面板顶（= split_y + splitter_h）
    panel_y: i32,
    /// 面板高度上限（内容区一半）
    max_h: i32,
};

/// 计算“下方编辑面板”的布局。**播放列表与钢琴窗走同一份数学**，
/// 于是两者位置/上限/最小高度/分割条行为完全一致（它们本来就是同一块窗口区域、互斥显示）。
/// - `content_top`：内容区顶（扣掉标题栏与两行标尺之后）
/// - `bottom`：内容区底（= 窗口底）
pub fn layoutPanel(content_top: i32, bottom: i32, splitter_h: i32, want_h: i32, min_h: i32) PanelLayout {
    const content_all = @max(1, bottom - content_top);
    // 上限 = 内容区 **80%**（用户拍板），但仍要给上方内容区留 ≥48px
    const cap80: i32 = @divTrunc(content_all * 8, 10);
    const max_h: i32 = @max(min_h, @min(cap80, content_all - splitter_h - 48));
    const panel_h: i32 = std.math.clamp(want_h, min_h, max_h);
    const split_y: i32 = bottom - panel_h - splitter_h;
    return .{
        .panel_h = panel_h,
        .content_h = @max(48, content_all - panel_h - splitter_h),
        .split_y = split_y,
        .panel_y = split_y + splitter_h,
        .max_h = max_h,
    };
}

test "unit: 归一化 ↔ 显示 往返稳定（dB 有舍入，其余精确）" {
    var buf: [24]u8 = undefined;

    // %
    try std.testing.expectEqualStrings("50", formatValue(.percent, 0.5, &buf));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parseValue(.percent, "50").?, 1e-6);
    try std.testing.expectEqual(@as(?f32, 1.0), parseValue(.percent, "999")); // 钳制
    try std.testing.expectEqual(@as(?f32, null), parseValue(.percent, "abc"));

    // MIDI
    const midi_v: f32 = 64.0 / 127.0;
    try std.testing.expectEqualStrings("64", formatValue(.midi, midi_v, &buf));
    try std.testing.expectApproxEqAbs(midi_v, parseValue(.midi, "64").?, 1e-6);

    // dB：0.5 ≈ −6.0dB；−60dB 及以下 = 静音（用户拍板）
    try std.testing.expectEqualStrings("-6.0", formatValue(.db, 0.5, &buf));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parseValue(.db, "-6.0").?, 0.01);
    try std.testing.expectEqualStrings("静音", formatValue(.db, 0.0, &buf));
    try std.testing.expectEqual(@as(?f32, 0.0), parseValue(.db, "-60"));
    try std.testing.expectEqual(@as(?f32, 0.0), parseValue(.db, "-80"));

    // BPM：20–999
    const bpm_v: f32 = (120.0 - 20.0) / 979.0;
    try std.testing.expectEqualStrings("120", formatValue(.bpm, bpm_v, &buf));
    try std.testing.expectApproxEqAbs(bpm_v, parseValue(.bpm, "120").?, 1e-4);

    // PAN：L/R/C
    try std.testing.expectEqualStrings("C", formatValue(.pan, 0.5, &buf));
    try std.testing.expectEqualStrings("L32", formatValue(.pan, 0.34, &buf));
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), parseValue(.pan, "L32").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.66), parseValue(.pan, "R32").?, 1e-6);
    try std.testing.expectEqual(@as(?f32, 0.5), parseValue(.pan, "C"));

    // 单位循环：按目标种类过滤
    var lane = Lane{ .target = .{ .kind = .mixer_vol, .uid = 1 } };
    var cyc: [4]Unit = undefined;
    try std.testing.expectEqual(@as(usize, 3), unitCycle(&lane, &cyc).len);
    lane.display_unit = .percent;
    cycleUnit(&lane);
    try std.testing.expectEqual(Unit.midi, lane.display_unit);
    cycleUnit(&lane);
    try std.testing.expectEqual(Unit.db, lane.display_unit);
    cycleUnit(&lane);
    try std.testing.expectEqual(Unit.percent, lane.display_unit); // 回环
}

/// **横向值参考线**（两个编辑区共用）：把值域 0..1 **等分 8 份**，
/// 中线（50%）用 `grid_bar`、四分之一线（25%/75%）用 `grid_beat`、其余用 `grid_snap`。
///
/// 以前这里按 **CC 值 0..127 的 8 的倍数** 画，于是 vv=64 落在 **50.394%**，
/// 和“真正的 50% 中线”是两条线——面板一高就差出 2~3px（用户实测“网格中线比曲线中线高几像素”）。
/// 现在只有一套等分，中线**只会被画一次**。
pub fn drawValueGrid(ui: *Ui, r: Rect, dense: bool) void {
    if (r.h < 8) return;
    const usable: f32 = @floatFromInt(r.h);
    var k: i32 = 1;
    while (k < 8) : (k += 1) {
        const t: f32 = @as(f32, @floatFromInt(k)) / 8.0;
        const vy = r.y + @as(i32, @intFromFloat((1.0 - t) * usable));
        const col = if (k == 4)
            ui.theme.grid_bar // 正中心（= 50%）
        else if (k == 2 or k == 6)
            ui.theme.grid_beat // 25% / 75%
        else if (dense)
            ui.theme.grid_snap // 12.5% / 37.5% / 62.5% / 87.5%
        else
            continue;
        ui.renderer.hline(r.x, vy, r.w, col);
    }
}

test "lane: 锚点 x 与竖向网格线**逐像素重合**（任意缩放/滚动）" {
    const step_px: f32 = 8.0;
    const lane_x: i32 = 100;
    const zooms = [_]f32{ 0.5, 1.0, 1.5, 2.0, 3.7 };
    const scrolls = [_]i32{ 0, 7, 96, 1000, 4321 };
    for (zooms) |z| {
        const ws = step_px * z; // 屏上步宽（与 `drawTimelineGrid` 同式）
        for (scrolls) |sc| {
            const scroll_s: f32 = @as(f32, @floatFromInt(sc)) * z; // 屏上滚动（精确）
            var step: i32 = 0;
            while (step < 400) : (step += 1) {
                const grid_x = lane_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(step)) * ws - scroll_s));
                const pt_x = xOf(@floatFromInt(step), lane_x, step_px, z, scroll_s);
                try std.testing.expectEqual(grid_x, pt_x);
                try std.testing.expectEqual(step, stepOfX(pt_x, lane_x, step_px, z, scroll_s));
            }
        }
    }
}

test "lane: 拖动到面板外可达 0% / 100%（抓取偏移为负时也能到顶）" {
    // 模拟：面板 y=100 h=200 → 值域 [100, 300] 的屏幕区间
    // 按下时鼠标在点中心**上方** 3px（→ 抓取偏移为负），一路往上拖到面板外 50px
    const y: i32 = 100;
    const h: i32 = 200;
    const grab_value: f32 = 0.5 - valueOfY(y + h / 2 - 3, y, h); // 负值
    try std.testing.expect(grab_value < 0);

    // 旧写法（先夹紧再叠加）到不了 1.0：
    const old_way = std.math.clamp(std.math.clamp(valueOfY(y - 50, y, h), 0.0, 1.0) + grab_value, 0.0, 1.0);
    try std.testing.expect(old_way < 1.0);

    // 新写法（raw 再夹紧一次）到顶：
    const new_way = std.math.clamp(valueOfYRaw(y - 50, y, h) + grab_value, 0.0, 1.0);
    try std.testing.expectEqual(@as(f32, 1.0), new_way);

    // 反向：拖到面板下方 50px → 0%
    const g2: f32 = 0.5 - valueOfY(y + h / 2 + 3, y, h); // 正值
    const bottom = std.math.clamp(valueOfYRaw(y + h + 50, y, h) + g2, 0.0, 1.0);
    try std.testing.expectEqual(@as(f32, 0.0), bottom);
}

test "evalAt: 连续求值（小数步）——linear 段中点、smooth 鼓包、hold 阶跃" {
    const a = std.testing.allocator;
    var lane = Lane{ .interp = .linear };
    defer lane.deinit(a);
    _ = lane.insertPoint(a, 0, 0.0);
    _ = lane.insertPoint(a, 96, 1.0);

    // 整数步
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lane.evalAt(@as(f32, 48)), 1e-5);
    // **小数步**（旧实现会先取整 → 台阶；现在连续）
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), lane.evalAt(@as(f32, 24)), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1875), lane.evalAt(@as(f32, 18)), 1e-5);
    // 单调递增（任意两点之间不应有台阶平台）
    var prev = lane.evalAt(@as(f32, 0));
    var s: f32 = 0.5;
    while (s < 96.0) : (s += 0.5) {
        const v = lane.evalAt(s);
        try std.testing.expect(v >= prev - 1e-6);
        try std.testing.expect(v - prev < 0.02);
        prev = v;
    }

    // smooth：折点被抬到 0.9（手柄位置），圆角内收 → 中点略低于 0.9
    lane.interp = .smooth;
    lane.points.items[0].curve = 0.4;
    try std.testing.expect(lane.evalAt(@as(f32, 48)) > 0.8);
    try std.testing.expect(lane.evalAt(@as(f32, 48)) < 0.9);
    // hold：整段保持左值
    lane.interp = .hold;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lane.evalAt(@as(f32, 95.9)), 1e-5);
}
