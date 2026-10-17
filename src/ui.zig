//! UI 层：极简立即式 UI（自绘，零依赖）。
//!
//! 立即式要点：
//! - 每帧重建：调用 `beginFrame` → 画控件 → `endFrame`；
//! - **持久状态**（音量值等）放调用方的 AppState；
//! - **瞬时状态**（谁在被拖动、拖动起点）放 `Ui` 上下文；
//! - 控件返回"是否发生变化/被点击"，调用方据此改自己的状态。

const std = @import("std");
const r_mod = @import("render.zig");
const Renderer = r_mod.Renderer;
const Color = r_mod.Color;
const Font = @import("font.zig").Font;
const window = @import("window.zig");

/// 光标形状请求（每帧由 UI 设置，窗口层据此切换系统光标）
pub const CursorKind = enum { arrow, resize_h, resize_v, size_all, hidden };

/// 矩形（层/区域用）
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, mx: i32, my: i32) bool {
        return mx >= self.x and mx < self.x + self.w and my >= self.y and my < self.y + self.h;
    }
};

/// 层：显式声明「优先级 + 区域」，由框架统一决定输入归属与绘制顺序。
/// - `prio`：优先级（大者在上；如 菜单 > 浮动窗口 > 主界面）；
/// - `rect`：层所占区域（模态层用全屏矩形）；
/// - `modal`：true = 只要层“存在”，就屏蔽所有更低层（不管鼠标在哪）。
pub const Layer = struct {
    prio: i32,
    rect: Rect,
    modal: bool = false,
};

/// 横向时间轴滚动条的手势模式
pub const HBarMode = enum { body, left, right };

/// 自绘图标形状（传输按钮用）。
/// **为什么自绘**：中文字体常缺几何符号字形（▶ U+25B6 / ❚ / ■ 等），
/// 缺字时退回 `.notdef` 方块——实测“播放按钮变竖长方形”。
/// 像素级画形状则任何字体下外观一致（同 `view_util.viewSwitchButton` 的思路）。
pub const IconShape = enum {
    /// 播放：右向实心三角
    play,
    /// 暂停：两根竖条
    pause,
    /// 停止：实心方块
    stop,
    /// 录制：实心圆
    record,
    /// 跟随播放游标：`>|`（45° 角形 + 竖线，**两部分同高**）
    follow,
};

pub const Theme = struct {
    bg: Color = r_mod.rgb(24, 26, 30),
    panel: Color = r_mod.rgb(36, 39, 45),
    panel_border: Color = r_mod.rgb(56, 60, 68),
    text: Color = r_mod.rgb(220, 224, 230),
    text_dim: Color = r_mod.rgb(140, 146, 156),
    accent: Color = r_mod.rgb(90, 170, 255),
    slider_track: Color = r_mod.rgb(50, 54, 62),
    slider_fill: Color = r_mod.rgb(90, 170, 255),
    waveform: Color = r_mod.rgb(120, 210, 150),
    grid: Color = r_mod.rgb(44, 48, 56),
    /// 钢琴卷帘音符区：黑键行背景加深色（半透明叠加；与琴键列的黑白层次呼应）
    lane_black_key: Color = 0x1E000000,
    /// 幽灵音符（同样式、其它乐器；灰色半透明——只读参考，无交互）
    ghost_note: Color = 0x70808692,
    /// 量化网格线（= 所选吸附档位；最暗、1px）
    grid_snap: Color = r_mod.rgb(48, 52, 62),
    /// 拍线（比网格线亮一档；1px）
    grid_beat: Color = r_mod.rgb(76, 82, 96),
    /// 小节线（最亮、2px——与拍/网格拉开明暗+粗细双层差异）
    grid_bar: Color = r_mod.rgb(108, 115, 132),
    /// 选中音符（框选/批量操作的视觉反馈；与普通音符、拖动中音符都区分）
    note_selected: Color = r_mod.rgb(255, 186, 80),
    /// 列表项：悬停 / 选中 / 交替行
    item_hover: Color = r_mod.rgb(52, 58, 68),
    item_selected: Color = r_mod.rgb(58, 84, 120),
    item_alt: Color = r_mod.rgb(40, 43, 50),
    /// 工具栏与状态栏
    toolbar: Color = r_mod.rgb(44, 47, 54),
    scrollbar: Color = r_mod.rgb(80, 86, 96),
    /// 横向滚动条滑块（无 hover）：偏白、保证在 minimap 上看得清
    scrollbar_light: Color = r_mod.rgb(185, 190, 200),
    /// 危险操作（关闭按钮悬停等）
    danger: Color = r_mod.rgb(160, 60, 60),
    /// 静音开关激活
    mute_on: Color = r_mod.rgb(190, 70, 70),
    /// 琴键：白键 / 黑键 / 键上音名
    key_white: Color = r_mod.rgb(196, 200, 206),
    key_black: Color = r_mod.rgb(28, 30, 34),
    key_label: Color = r_mod.rgb(70, 74, 80),
    /// 播放游标：停止（暗白）/ 播放（黄）
    cursor_idle: Color = r_mod.rgb(190, 195, 202),
    cursor_play: Color = r_mod.rgb(240, 208, 72),
    /// 录制按钮激活（红点）
    record: Color = r_mod.rgb(220, 68, 68),
};

pub const UiRect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Ui = struct {
    renderer: Renderer,
    font: *Font,
    theme: Theme = .{},

    /// 本帧登记的“遮罩”矩形（菜单/弹层；插件子窗口遮挡判定，见 `noteOverlayRect`）
    overlay_rects: [16]UiRect = undefined,
    overlay_n: usize = 0,

    // ── 瞬时输入状态（每帧由 main 更新）──
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_down: bool = false,
    mouse_pressed: bool = false, // 本帧按下
    mouse_released: bool = false, // 本帧抬起
    mouse_right_pressed: bool = false, // 本帧右键按下
    mouse_right_down: bool = false, // 右键按住（拖动擦除用）
    mouse_middle_pressed: bool = false, // 本帧中键按下（视口平移用）
    mouse_middle_down: bool = false, // 中键按住
    mouse_double: bool = false, // 本帧双击（左键）
    wheel: i32 = 0,
    /// 本帧滚轮是否按着 Ctrl（横向缩放）
    wheel_ctrl: bool = false,
    /// 本帧滚轮是否按着 Shift（纵向缩放）
    wheel_shift: bool = false,
    /// 本帧滚轮是否按着 Alt（微调力度/声像——见 `view_pianoroll`/`view_note_lane`）
    wheel_alt: bool = false,
    /// 本帧修饰键状态（每帧由 main 从窗口读取；框选/批量操作用）
    mods_ctrl: bool = false,
    mods_shift: bool = false,

    // ── 拖动状态（跨帧保持）──
    /// 当前操控中的控件 id（**全应用唯一**——撞 id 会“串场”：拖 A 动 B）。
    ///
    /// id 分配表（新增控件先查表再取号；见 docs/pitfalls.md 两起撞车事故）：
    /// - `100-160` / `300-352`：工具栏（菜单按钮 / 音量 / BPM / 拍号）
    /// - `1000-3001`：主面板列表（操作历史 / 样式 / 机架列表）
    /// - `3000-4130`：通道机架（窗口 3000/3001、旋钮 4000、通道推子 4100+）
    /// - `5000-5499`：合成器窗口（窗口 5000/5001、旋钮 5100-5402）
    /// - `6000`：钢琴卷帘琴键试听
    /// - `7000-7001`：播放列表标尺 / 音符轨画笔
    /// - `7100-7501`：钢琴卷帘与播放列表（标尺 7100/7200/7000、框选
    ///   7300/7400、循环拖选 7500/7501）
    /// - `7150-7161`：调音台窗口交互（分割条/拖动/缩放）
    /// - `7600-7900`：效果器窗口（窗口 7600/7601、干湿 7602、EQ 7800+、VST3 参数行 7900+）
    /// - `8100-8711`：调音台控件（声像 8100+ / 音量 8150+ / 干湿 8200+）
    active_id: u64 = 0,
    drag_anchor: f32 = 0,
    /// 拖动起始值（splitter 初值 / 滚动条的鼠标抓取偏移，像素）
    drag_start: i32 = 0,
    /// 边缘缩放（.left/.right）按下时的鼠标 x——**位移式**换算的基准（零位移恒等）
    drag_mx0: i32 = 0,
    /// 横向时间轴滚动条：手势模式（主体/左缘/右缘）+ 拖动快照
    drag_mode_h: HBarMode = .body,
    drag_anchor_x: i32 = 0, // .right=滑块左缘快照；.left=滑块右缘快照
    drag_content0: i32 = 0,
    drag_scroll0: i32 = 0,
    drag_view_cw0: i32 = 0,
    /// □ 缩放拖动：窗口冻结的累积位移（由 main 每帧写入；未冻结为 0）
    frozen_dy: i32 = 0,
    /// □ 缩放拖动：请求 main 隐藏并冻结鼠标
    mouse_capture: bool = false,
    /// □ 缩放拖动：上次的 frozen_dy（算增量）与不足一单位的余数
    zoom_last_dy: i32 = 0,
    zoom_rem: i32 = 0,
    /// 归一化值拖动：起始值 + 起始冻结位移（**锚点式累积**——
    /// 离散参数被步长吸附后读回值会归零，增量式永远跨不过阈值）
    drag_f0: f64 = 0,
    drag_dy0: i32 = 0,

    /// 本帧请求的光标（beginFrame 时重置为 arrow）
    cursor: CursorKind = .arrow,
    /// 本帧是否屏蔽底层控件交互（由层系统自动维护；调用方不应手写）
    input_blocked: bool = false,
    /// 本帧声明的层（帧首清空；各视图声明自己的层）
    layers: [16]Layer = undefined,
    layer_n: usize = 0,
    /// 当前正在绘制的层优先级（-1 = 未入层）
    cur_prio: i32 = -1,
    /// 层裁剪保存（beginLayer/endLayer 配对）
    saved_clip: r_mod.Clip = undefined,
    clip_active: bool = false,

    // ── 层 API（输入分层的正统做法）──

    /// 帧首调用：清空层表
    pub fn resetLayers(self: *Ui) void {
        self.layer_n = 0;
        self.cur_prio = -1;
        self.input_blocked = false;
    }

    /// 声明一个层（帧首调用；同优先级的多次声明：后者覆盖区域，不重复入表）。
    /// 返回是否成功（层表满则失败）。
    pub fn declare(self: *Ui, l: Layer) bool {
        for (self.layers[0..self.layer_n]) |*old| {
            if (old.prio == l.prio) {
                old.* = l; // 同优先级：更新（如窗口拖动后矩形变化）
                return true;
            }
        }
        if (self.layer_n >= self.layers.len) return false;
        self.layers[self.layer_n] = l;
        self.layer_n += 1;
        return true;
    }

    /// 进入某层：
    /// - **输入**：自动算出是否被更高层屏蔽（鼠标被高优先层区域覆盖，或存在模态高优先层）；
    /// - **绘制**：将渲染裁剪区收窄到本层区域（若声明了）；返回值 = 是否允许本层响应鼠标。
    /// 调用方无需再手写 `input_blocked` 组合，也不必手动 pushClip 窗口边界。
    pub fn beginLayer(self: *Ui, prio: i32) bool {
        var blocked = false;
        var rect: ?Rect = null;
        for (self.layers[0..self.layer_n]) |l| {
            if (l.prio == prio) rect = l.rect;
            if (l.prio <= prio) continue; // 只看更高层
            if (l.modal or l.rect.contains(self.mouse_x, self.mouse_y)) {
                blocked = true;
            }
        }
        self.cur_prio = prio;
        self.input_blocked = blocked;
        // 绘制裁剪：收窄到本层区域（嵌套时取交集）。
        // **注意**：层矩形外的绘制会被裁掉——窗口阴影/溢出菜单需自己声明更**大**的矩形，
        // 或改用无视裁剪的绘制路径（见 pitfalls：“层裁剪的副作用”）。
        if (rect) |r| {
            self.saved_clip = self.renderer.pushClip(r.x, r.y, r.w, r.h);
            self.clip_active = true;
        } else {
            self.clip_active = false;
        }
        return !blocked;
    }

    /// 进入某层——**不裁剪**（仅输入屏蔽）。用于“绘制会超出声明矩形”的层
    /// （如带阴影的窗口、跟随鼠标弹出的右键菜单）。
    pub fn beginLayerNoClip(self: *Ui, prio: i32) bool {
        const ok = self.beginLayer(prio);
        if (self.clip_active) {
            self.renderer.popClip(self.saved_clip); // 撤销裁剪
            self.clip_active = false;
        }
        return ok;
    }

    /// 退出当前层（恢复裁剪）
    pub fn endLayer(self: *Ui) void {
        if (self.clip_active) {
            self.renderer.popClip(self.saved_clip);
            self.clip_active = false;
        }
        self.cur_prio = -1;
        self.input_blocked = false;
    }

    pub fn init(renderer: Renderer, font: *Font) Ui {
        return .{ .renderer = renderer, .font = font };
    }

    pub fn beginFrame(self: *Ui) void {
        self.renderer.clear(self.theme.bg);
        self.cursor = .arrow; // 每帧重置；控件按需改
        self.resetLayers();
        self.overlay_n = 0; // 遮罩登记表每帧重建（各菜单/弹层绘制时登记）
    }

    // ── 遮罩矩形登记（插件编辑器子窗口的遮挡判定用）──
    // 菜单/下拉/弹层绘制时登记自己的矩形；帧末 syncPluginEditors 查
    // `overlayBlocks`：命中则隐藏插件子窗口（否则子窗口永远盖在软渲染之上）。

    /// 登记一个“遮罩”矩形（本帧有效；最多 16 个，超出丢弃）
    pub fn noteOverlayRect(self: *Ui, x: i32, y: i32, w: i32, h: i32) void {
        if (self.overlay_n >= self.overlay_rects.len) return;
        self.overlay_rects[self.overlay_n] = .{ .x = x, .y = y, .w = w, .h = h };
        self.overlay_n += 1;
    }

    /// 给定矩形是否与任一已登记遮罩相交
    pub fn overlayBlocks(self: *const Ui, x: i32, y: i32, w: i32, h: i32) bool {
        for (self.overlay_rects[0..self.overlay_n]) |r| {
            if (x < r.x + r.w and r.x < x + w and y < r.y + r.h and r.y < y + h) return true;
        }
        return false;
    }

    pub fn endFrame(self: *Ui) void {
        self.mouse_pressed = false;
        self.mouse_released = false;
        self.mouse_right_pressed = false;
        self.mouse_middle_pressed = false;
        self.mouse_double = false;
        self.wheel = 0;
        self.wheel_ctrl = false;
        self.wheel_alt = false;
        self.wheel_shift = false;
    }

    // ── 文本工具 ──

    /// 把文本裁剪到最多 max_px 像素宽（按字符累加，超出加 "…"）。
    /// 返回可直接绘制的切片（不做分配）。
    pub fn clipText(self: *Ui, text: []const u8, max_px: i32) []const u8 {
        if (max_px <= 0) return text[0..0];
        var width: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + n > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + n]) catch {
                i += n;
                continue;
            };
            const adv = if (self.font.getGlyph(cp)) |g| g.advance else self.font.size_px * 0.5;
            if (width + adv > @as(f32, @floatFromInt(max_px))) {
                // 留出 "…" 的空间
                return text[0..i];
            }
            width += adv;
            i += n;
        }
        return text;
    }

    /// 绘制带裁剪的文本（超出宽度不绘制；调用方可自行加省略号）
    pub fn labelClipped(self: *Ui, text: []const u8, x: i32, y: i32, max_px: i32, color: Color) void {
        const shown = self.clipText(text, max_px);
        self.font.draw(self.renderer, shown, @floatFromInt(x), @floatFromInt(y + @as(i32, @intFromFloat(self.font.ascent))), color);
    }

    // ── 控件 ──

    /// 文本在矩形内**垂直居中**的基线 y（`font.draw` 的 y 是基线）。
    /// 排版框从 `ascent`（基线之上）到 `descent`（基线之下，**负值**），
    /// 故居中基线 = 矩形中心 + (ascent + descent) / 2。
    /// （旧写法用 `ascent - descent`——符号反了，文字比正确位置低 |descent| 像素，
    /// 实测反馈：“按钮里文字没有垂直居中”）
    fn centeredBaselineY(self: *Ui, y: i32, h: i32) i32 {
        return y + @divTrunc(h, 2) + @divTrunc(@as(i32, @intFromFloat(self.font.ascent + self.font.descent)), 2);
    }

    /// 按钮：返回 true = 本帧被点击
    pub fn button(self: *Ui, id: u64, text: []const u8, x: i32, y: i32, w: i32, h: i32) bool {
        _ = id; // 预留：将来的焦点/键盘导航
        const hovered = self.hit(x, y, w, h);
        const bg = if (hovered and self.mouse_down) self.theme.accent else if (hovered) r_mod.rgb(60, 66, 76) else self.theme.panel;
        self.renderer.fillRect(x, y, w, h, bg);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);

        const tw = self.font.measure(text);
        const tx: i32 = x + @divTrunc(w - @as(i32, @intFromFloat(tw)), 2);
        self.font.draw(self.renderer, text, @floatFromInt(tx), @floatFromInt(self.centeredBaselineY(y, h)), self.theme.text);

        return hovered and self.mouse_pressed;
    }

    /// 按钮（带激活态）：active 时用强调色高亮（如当前视图的切换按钮）
    pub fn buttonEx(self: *Ui, id: u64, text: []const u8, x: i32, y: i32, w: i32, h: i32, active: bool) bool {
        if (!active) return self.button(id, text, x, y, w, h);
        const hovered = self.hit(x, y, w, h);
        const bg = if (hovered and self.mouse_down) r_mod.rgb(70, 130, 200) else self.theme.accent;
        self.renderer.fillRect(x, y, w, h, bg);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);
        const tw = self.font.measure(text);
        const tx: i32 = x + @divTrunc(w - @as(i32, @intFromFloat(tw)), 2);
        self.font.draw(self.renderer, text, @floatFromInt(tx), @floatFromInt(self.centeredBaselineY(y, h)), r_mod.rgb(240, 244, 250));
        return hovered and self.mouse_pressed;
    }

    /// 图标按钮（自绘形状）：返回 true = 本帧被点击。
    /// - `active`：激活态（如播放中/录制中）——底色用 `active_color` 高亮；
    /// - 形状在按钮内**居中**，图标高 ≈ 按钮高的 60%（随 h 自适应）。
    pub fn iconButton(self: *Ui, id: u64, shape: IconShape, x: i32, y: i32, w: i32, h: i32, active: bool, active_color: Color) bool {
        _ = id; // 预留：将来的焦点/键盘导航
        const hovered = self.hit(x, y, w, h);
        const bg = if (active)
            active_color
        else if (hovered and self.mouse_down)
            self.theme.accent
        else if (hovered)
            r_mod.rgb(60, 66, 76)
        else
            self.theme.panel;
        self.renderer.fillRect(x, y, w, h, bg);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);

        const fg = if (active) r_mod.rgb(250, 250, 250) else self.theme.text;
        // 图标半尺寸 = h×3/10（如 h=26 → r=7：图标高 13px，按钮内留白充足）
        drawIconShape(self.renderer, shape, x + @divTrunc(w, 2), y + @divTrunc(h, 2), @divTrunc(h * 3, 10), fg);
        return hovered and self.mouse_pressed;
    }

    /// 像素级画图标形状：`cx`/`cy` 为图标中心，`r` 为半尺寸（像素）。
    /// 注：`r` 必须**显式标 i32**——Zig 0.16 的 `@max(2, r_in)` 会把结果类型
    /// 窄化成 u3（按操作数范围推导），后续 `-r` / `r*2-1` 会溢出或报
    /// “negation of type 'u31'”。
    fn drawIconShape(ren: Renderer, shape: IconShape, cx: i32, cy: i32, r_in: i32, color: Color) void {
        const r: i32 = @max(2, r_in);
        switch (shape) {
            .play => {
                // 右向实心三角：左缘竖直固定，逐行按线性插值取该行宽度（斜边平滑）。
                // 尺寸：高 = 2r-1、宽 = 3r/2（**强制奇数**——偶数宽时
                // `cx - wmax/2` 会让三角整体偏左半像素，视觉上“没居中”）
                const wmax: i32 = @max(3, (@divTrunc(r * 3, 2) + 1) | 1);
                const x0 = cx - @divTrunc(wmax, 2);
                var dy: i32 = -r + 1;
                while (dy <= r - 1) : (dy += 1) {
                    // 注：`@abs(i32)` 在 Zig 0.16 返回 u32——需显式转回 i32
                    const ady: i32 = @intCast(@abs(dy));
                    const w_row: i32 = @max(1, @divTrunc(wmax * (r - ady), r));
                    ren.hline(x0, cy + dy, w_row, color);
                }
            },
            .pause => {
                // 两根竖条：条宽 = r/2（至少 2px），间隙 = r/2；高 = 2r-1
                const bw: i32 = @max(2, @divTrunc(r, 2));
                const gap: i32 = @max(2, @divTrunc(r, 2));
                const total = bw * 2 + gap;
                const x0 = cx - @divTrunc(total, 2);
                ren.fillRect(x0, cy - r + 1, bw, r * 2 - 1, color);
                ren.fillRect(x0 + bw + gap, cy - r + 1, bw, r * 2 - 1, color);
            },
            .stop => {
                // 实心方块（边长 = 2r-1，奇数居中）
                const s = r * 2 - 1;
                ren.fillRect(cx - r + 1, cy - r + 1, s, s, color);
            },
            .record => {
                // 实心圆（直径 = 2r-1）：逐行扫描，行宽由半径插值（圆边平滑）
                const rr = r - 1;
                var dy: i32 = -rr;
                while (dy <= rr) : (dy += 1) {
                    const rem = rr * rr - dy * dy;
                    const half: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(@max(0, rem)))));
                    ren.hline(cx - half, cy + dy, half * 2 + 1, color);
                }
            },
            .follow => {
                // `>|`：45° 角形（尖头朝右）+ 竖线——**两部分高度严格对齐**
                // （均 = 2r-1 = 13px，同播放/暂停图标）。
                // 角形加粗用**水平偏移**：垂直包围盒保持不变（垂直偏移法会多一行，破坏等高）。
                const top = cy - r + 1;
                const hgt = r * 2 - 1;
                const bar_x = cx + r - 2;
                ren.fillRect(bar_x, top, 2, hgt, color); // 竖线（2px 宽，与图标同高）
                const hh = r - 1; // 半高（45° → 深度 = 半高）
                const tip_x = bar_x - 5; // 加粗后与竖线留 3px 间隙（1px 太近，用户要求左移）
                const base_x = tip_x - hh;
                var t: i32 = 0;
                while (t <= 1) : (t += 1) {
                    ren.line(base_x + t, top, tip_x + t, cy, color);
                    ren.line(tip_x + t, cy, base_x + t, cy + r - 1, color);
                }
            },
        }
    }

    /// 水平推子 + 数值显示：`scale` 把 0-1 映射到显示范围（如 100 表示百分比）
    pub fn sliderPercent(self: *Ui, id: u64, value: *f32, x: i32, y: i32, w: i32, h: i32, scale: f32, suffix: []const u8) bool {
        const changed = self.slider(id, value, x, y, w, h);
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d:.0}{s}", .{ value.* * scale, suffix }) catch "";
        self.label(text, x + w + 8, y + @divTrunc(h, 2) - 8, self.theme.text_dim);
        return changed;
    }

    /// 水平推子：直接修改 `value`（0-1），返回 true = 值变了
    pub fn slider(self: *Ui, id: u64, value: *f32, x: i32, y: i32, w: i32, h: i32) bool {
        const hovered = self.hit(x, y, w, h);
        const changed = self.draggable(id, hovered, x, w, value);

        // 轨道
        const track_y = y + @divTrunc(h, 2) - 3;
        self.renderer.fillRect(x, track_y, w, 6, self.theme.slider_track);
        // 已填充部分
        const fill_w: i32 = @intFromFloat(value.* * @as(f32, @floatFromInt(w)));
        self.renderer.fillRect(x, track_y, fill_w, 6, self.theme.slider_fill);
        // 把手
        const knob_x = x + fill_w - 6;
        self.renderer.fillRect(knob_x, y, 12, h, if (hovered or self.active_id == id) self.theme.accent else r_mod.rgb(180, 186, 196));
        self.renderer.strokeRect(knob_x, y, 12, h, self.theme.panel_border);
        return changed;
    }

    /// 垂直推子（音量常用）：0 在底部
    pub fn vslider(self: *Ui, id: u64, value: *f32, x: i32, y: i32, w: i32, h: i32) bool {
        const hovered = self.hit(x, y, w, h);
        // 垂直方向：鼠标 y 向下增大 → 值减小
        const changed = self.draggableV(id, hovered, y, h, value);

        const track_x = x + @divTrunc(w, 2) - 3;
        self.renderer.fillRect(track_x, y, 6, h, self.theme.slider_track);
        const fill_h: i32 = @intFromFloat(value.* * @as(f32, @floatFromInt(h)));
        self.renderer.fillRect(track_x, y + h - fill_h, 6, fill_h, self.theme.slider_fill);
        const knob_y = y + h - fill_h - 6;
        self.renderer.fillRect(x, knob_y, w, 12, if (hovered or self.active_id == id) self.theme.accent else r_mod.rgb(180, 186, 196));
        self.renderer.strokeRect(x, knob_y, w, 12, self.theme.panel_border);
        return changed;
    }

    /// 旋钮（0-1）：拖动上下调节；显示为**底部缺口的圆环**——
    /// 数值 0 = 全不亮；0.5 = 左半边亮；1 = 全亮（从底部缺口起、逆着时针往左长）。
    /// `vmin`/`vmax`：值域（默认 0..1；绘制按归一化位置）。
    pub fn knob(self: *Ui, id: u64, value: *f32, x: i32, y: i32, size: i32) bool {
        return self.knobRange(id, value, x, y, size, 0, 1);
    }

    /// 带值域的旋钮（如 Q 值 0.1..4.0）——绘制按 `(v - vmin) / (vmax - vmin)` 归一化。
    pub fn knobRange(self: *Ui, id: u64, value: *f32, x: i32, y: i32, size: i32, vmin: f32, vmax: f32) bool {
        const range = @max(1e-6, vmax - vmin);
        const hovered = self.hit(x, y, size, size);
        var changed = false;
        if (hovered and self.mouse_pressed) {
            self.active_id = id;
            self.drag_anchor = value.*;
            self.drag_start = self.mouse_y;
        }
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                const dy = self.drag_start - self.mouse_y; // 上拖增大
                const nv = std.math.clamp(self.drag_anchor + @as(f32, @floatFromInt(dy)) / 120.0 * range, vmin, vmax);
                if (nv != value.*) {
                    value.* = nv;
                    changed = true;
                }
            }
        }
        const norm = std.math.clamp((value.* - vmin) / range, 0, 1);

        // 绘制：底部缺口圆环（底轨）+ 亮弧（从底部起往左长）
        const cx = x + @divTrunc(size, 2);
        const cy = y + @divTrunc(size, 2);
        const r = @divTrunc(size, 2) - 1;
        const gap: f32 = 0.30; // 底部缺口弧度（约 17°）
        const pi: f32 = std.math.pi;
        const a0: f32 = pi / 2 + gap / 2; // 底部（屏幕 y 向下）
        const a1: f32 = pi / 2 + 2 * pi - gap / 2;
        drawArc(self.renderer, cx, cy, r, a0, a1, self.theme.slider_track);
        if (norm > 0.002) {
            drawArc(self.renderer, cx, cy, r, a0, a0 + (a1 - a0) * norm, if (hovered or self.active_id == id) self.theme.accent else self.theme.slider_fill);
        }
        self.renderer.fillRect(cx - 1, cy - 1, 2, 2, self.theme.text_dim);
        return changed;
    }

    /// 圆弧（像素级描点；2px 粗）
    fn drawArc(ren: Renderer, cx: i32, cy: i32, r: i32, a0: f32, a1: f32, color: r_mod.Color) void {
        const len_px: f32 = (a1 - a0) * @as(f32, @floatFromInt(r));
        const steps: i32 = @max(1, @as(i32, @intFromFloat(len_px)));
        var i: i32 = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const a = a0 + (a1 - a0) * t;
            const px: i32 = cx + @as(i32, @intFromFloat(@cos(a) * @as(f32, @floatFromInt(r))));
            const py: i32 = cy + @as(i32, @intFromFloat(@sin(a) * @as(f32, @floatFromInt(r))));
            ren.plot(px, py, color);
            // 2px 粗：向内再描一点
            const px2: i32 = cx + @as(i32, @intFromFloat(@cos(a) * @as(f32, @floatFromInt(r - 1))));
            const py2: i32 = cy + @as(i32, @intFromFloat(@sin(a) * @as(f32, @floatFromInt(r - 1))));
            ren.plot(px2, py2, color);
        }
    }

    /// 两段式切换（如 SONG/PAT）：`left_active` 为 true 表示选中左段。
    /// 返回 true = 本帧切换了（点击了非当前选中的段）。
    pub fn toggle2(self: *Ui, id: u64, left_text: []const u8, right_text: []const u8, left_active: bool, x: i32, y: i32, w: i32, h: i32) bool {
        _ = id;
        const half = @divTrunc(w, 2);
        const l_hovered = self.hit(x, y, half, h);
        const r_hovered = self.hit(x + half, y, w - half, h);

        // 两段背景（选中段用强调色）
        const l_bg = if (left_active) self.theme.accent else if (l_hovered) self.theme.item_hover else self.theme.panel;
        const r_bg = if (!left_active) self.theme.accent else if (r_hovered) self.theme.item_hover else self.theme.panel;
        self.renderer.fillRect(x, y, half, h, l_bg);
        self.renderer.fillRect(x + half, y, w - half, h, r_bg);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);
        self.renderer.vline(x + half, y, h, self.theme.panel_border);

        // 文本居中（各段内）
        const drawSeg = struct {
            fn f(ui_: *Ui, text: []const u8, sx: i32, sw: i32, sy: i32, sh: i32) void {
                const tw = ui_.font.measure(text);
                const tx: i32 = sx + @divTrunc(sw - @as(i32, @intFromFloat(tw)), 2);
                ui_.font.draw(ui_.renderer, text, @floatFromInt(tx), @floatFromInt(ui_.centeredBaselineY(sy, sh)), r_mod.rgb(240, 244, 250));
            }
        }.f;
        drawSeg(self, left_text, x, half, y, h);
        drawSeg(self, right_text, x + half, w - half, y, h);

        if (l_hovered and self.mouse_pressed and !left_active) return true;
        if (r_hovered and self.mouse_pressed and left_active) return true;
        return false;
    }

    /// 面板容器（背景 + 边框）
    pub fn panel(self: *Ui, x: i32, y: i32, w: i32, h: i32) void {
        self.renderer.fillRect(x, y, w, h, self.theme.panel);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);
    }

    /// 带标题的面板（标题画在顶部左侧）
    pub fn panelTitled(self: *Ui, x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
        self.panel(x, y, w, h);
        // 标题栏背景
        const th: i32 = @as(i32, @intFromFloat(self.font.lineHeight())) + 6;
        self.renderer.fillRect(x + 1, y + 1, w - 2, th, self.theme.toolbar);
        self.renderer.hline(x + 1, y + th, w - 2, self.theme.panel_border);
        self.labelClipped(title, x + 6, y + 3, w - 12, self.theme.text_dim);
    }

    pub fn label(self: *Ui, text: []const u8, x: i32, y: i32, color: Color) void {
        self.font.draw(self.renderer, text, @floatFromInt(x), @floatFromInt(y + @as(i32, @intFromFloat(self.font.ascent))), color);
    }

    /// 文本在矩形内**垂直居中**（与同排控件对齐用：传同一组 `(y, h)`，
    /// 如工具栏一整排控件共用的 `(by, bh)`）
    pub fn labelCentered(self: *Ui, text: []const u8, x: i32, y: i32, h: i32, color: Color) void {
        self.font.draw(self.renderer, text, @floatFromInt(x), @floatFromInt(self.centeredBaselineY(y, h)), color);
    }

    /// 文本输入框（自绘；聚焦样式 = accent 边框 + 光标竖线 + 选区高亮）。
    /// - `cursor`：光标字节偏移（code point 边界）；
    /// - `sel`：选区字节区间 `[lo, hi)`（null = 无）；
    /// - `view_off`：水平滚动偏移（px；由 `textFieldSyncOffset` 每帧算）。
    /// 纯绘制：字符/退格/光标/选区由 `App.text_input` + main 的输入路由驱动。
    pub fn textField(self: *Ui, text: []const u8, cursor: usize, sel: ?[2]usize, view_off: i32, x: i32, y: i32, w: i32, h: i32) void {
        self.renderer.fillRect(x, y, w, h, self.theme.toolbar);
        self.renderer.strokeRect(x, y, w, h, self.theme.accent);
        const inner_w = w - 8;
        if (inner_w <= 0) return;
        const saved = self.renderer.pushClip(x + 1, y + 1, w - 2, h - 2);
        defer self.renderer.popClip(saved);
        const tx = x + 4 - view_off; // 文本原点（滚动后可为负）
        const by = self.centeredBaselineY(y, h);
        // 选区高亮（文本之下）
        if (sel) |s| {
            const sx0 = tx + @as(i32, @intFromFloat(self.font.measure(text[0..s[0]])));
            const sx1 = tx + @as(i32, @intFromFloat(self.font.measure(text[0..s[1]])));
            const hilite = (@as(u32, 70) << 24) | (self.theme.accent & 0x00FFFFFF);
            self.renderer.fillRect(sx0, y + 3, @max(1, sx1 - sx0), h - 6, hilite);
        }
        self.font.draw(self.renderer, text, @floatFromInt(tx), @floatFromInt(by), self.theme.text);
        // 光标（文本之上；不闪烁——简化）
        const cx = tx + @as(i32, @intFromFloat(self.font.measure(text[0..cursor])));
        self.renderer.vline(cx, y + 4, h - 8, self.theme.text);
    }

    /// 文本输入框：让**光标可见**的水平滚动偏移（px）。
    /// `prev` 上一帧的偏移（光标已在可见区时就不滚）。
    pub fn textFieldSyncOffset(self: *Ui, text: []const u8, cursor: usize, w: i32, prev: i32) i32 {
        const inner = @as(f32, @floatFromInt(w - 8));
        if (inner <= 0) return 0;
        const tw = self.font.measure(text);
        const max_off: f32 = @max(0, tw - inner);
        var off: f32 = @max(0, @min(@as(f32, @floatFromInt(prev)), max_off));
        const cx = self.font.measure(text[0..cursor]);
        // 光标出界才滚（边缘留 2px 余量）
        if (cx < off + 2) off = cx - 2;
        if (cx > off + inner - 2) off = cx - inner + 2;
        off = @max(0, @min(off, max_off));
        return @intFromFloat(off);
    }

    /// 文本输入框：屏幕 x（**相对文本原点**，已加滚动偏移）→ 最近的
    /// code point 边界字节偏移（点击定位光标用）。
    pub fn textIndexAtX(self: *Ui, text: []const u8, px: f32) usize {
        if (px <= 0) return 0;
        var x: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + n > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + n]) catch {
                i += n;
                continue;
            };
            const adv = if (self.font.getGlyph(cp)) |g| g.advance else self.font.size_px * 0.5;
            if (px < x + adv * 0.5) return i; // 点在前半 → 落在本字符之前
            x += adv;
            i += n;
        }
        return text.len;
    }

    /// 列表项：返回 true = 本帧被点击。`selected` 控制高亮。
    /// `y` 为该项顶部；`h` 为行高（调用方计算）。
    /// `bg_override`：非选中/非悬停时的底色覆盖（如播放列表的轨道名列加深）。
    pub fn listItem(self: *Ui, id: u64, text: []const u8, x: i32, y: i32, w: i32, h: i32, selected: bool, alt: bool, bg_override: ?Color, text_c: ?Color) bool {
        _ = id;
        const hovered = self.hit(x, y, w, h);
        const bg = if (selected)
            self.theme.item_selected
        else if (hovered)
            self.theme.item_hover
        else if (bg_override) |c|
            c
        else if (alt)
            self.theme.item_alt
        else
            self.theme.panel;
        self.renderer.fillRect(x, y, w, h, bg);
        self.labelClipped(text, x + 8, y + 2, w - 16, text_c orelse (if (selected) self.theme.text else self.theme.text_dim));
        return hovered and self.mouse_pressed;
    }

    /// 方形**开关**（静音等）：`on`（启用/发声）= **蓝**（同减法合成器 OSC 开关）/ 否则 = **灰**；
    /// 返回 true = 本帧被按下。三处共用（轨道头 / 混音台通道 / 通道机架乐器）。
    pub fn toggleSquare(self: *Ui, on: bool, x: i32, y: i32, size: i32) bool {
        const hovered = self.hit(x, y, size, size);
        const off_c = r_mod.rgb(98, 101, 106); // 灰（关闭/静音）
        self.renderer.fillRect(x, y, size, size, if (on) self.theme.accent else off_c);
        self.renderer.strokeRect(x, y, size, size, if (hovered) self.theme.accent else self.theme.panel_border);
        return hovered and self.mouse_pressed;
    }

    /// 可拖动分隔条（垂直方向）：拖动时修改 `pos`（像素），返回 true = 位置变了。
    ///
    /// 关键顺序：**先更新 pos，再用新位置做命中判断与绘制**——
    /// 若先绘制后更新，分隔条会永远滞后鼠标一帧（快速拖动时表现为"追鼠标"，
    /// 且 hover 判断基于旧位置 → 高亮闪烁）。
    /// 拖动中高亮**常显**（不依赖 hover 判断）。
    ///
    /// **`x` 是分隔条的绝对绘制位置，`pos` 是被拖动修改的值——两者可能不同**：
    /// 第 1 个分隔条 `x == left_w == pos`；第 2 个分隔条的 `x` 是
    /// `left_w + splitter_w + mid_w`，而 `pos` 指向 `mid_w`。
    /// （曾经把 `pos` 当 `x` 用 → 第 2 个分隔条画到了 x=mid_w 处，严重偏左。）
    pub fn splitterV(self: *Ui, id: u64, pos: *i32, x: i32, y: i32, h: i32, thickness: i32, min_pos: i32, max_pos: i32) bool {
        var changed = false;
        // 1) 拖动中：先更新位置
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                const new_pos = std.math.clamp(self.mouse_x - self.drag_start, min_pos, max_pos);
                if (new_pos != pos.*) {
                    pos.* = new_pos;
                    changed = true;
                }
            }
        }
        // 2) 用（可能刚更新的）位置判断命中与绘制
        //    注意：x 与 pos 的差值是**固定**的（拖动中 left_w 不变），
        //    因此按 pos 记录拖动偏移是安全的。
        const hovered = self.hit(x - 3, y, thickness + 6, h);
        if (self.active_id != id and hovered and self.mouse_pressed) {
            self.active_id = id;
            self.drag_start = self.mouse_x - pos.*;
        }
        const active = self.active_id == id;
        const color = if (active or hovered) self.theme.accent else self.theme.panel_border;
        self.renderer.fillRect(x, y, thickness, h, color);
        if (active or hovered) self.cursor = .resize_h;
        return changed;
    }

    /// 可拖动分隔条（水平方向）：拖动时修改 `pos`（像素高度），返回 true = 位置变了。
    /// 与 `splitterV` 同套路（先更新 pos，再用新位置判断/绘制；拖动中高亮常显）：
    /// - `y` 是分隔条的绝对绘制位置，`pos` 是被拖动修改的值；
    /// - 方向：**向上拖 = 增高**（与“上方区域的下缘”直觉一致）。
    pub fn splitterH(self: *Ui, id: u64, pos: *i32, y: i32, x: i32, w: i32, thickness: i32, min_pos: i32, max_pos: i32) bool {
        var changed = false;
        // 1) 拖动中：先更新位置（向上拖增高）
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                const new_pos = std.math.clamp(self.drag_start - self.mouse_y, min_pos, max_pos);
                if (new_pos != pos.*) {
                    pos.* = new_pos;
                    changed = true;
                }
            }
        }
        // 2) 用（可能刚更新的）位置判断命中与绘制
        const hovered = self.hit(x, y - 3, w, thickness + 6);
        if (self.active_id != id and hovered and self.mouse_pressed) {
            self.active_id = id;
            self.drag_start = self.mouse_y + pos.*;
        }
        const active = self.active_id == id;
        const color = if (active or hovered) self.theme.accent else self.theme.panel_border;
        self.renderer.fillRect(x, y, w, thickness, color);
        if (active or hovered) self.cursor = .resize_v;
        return changed;
    }

    /// 垂直缩放方块（□ 缺口）：按住上下拖 = 调整行高 `value`。
    /// - 方块位置**固定**（不随鼠标移动）；
    /// - 拖动期间由 main 隐藏并冻结鼠标（本控件置位 `mouse_capture`），
    ///   位移经 `frozen_dy` 累积传入；
    /// - **松开那一帧也要应用本帧累积的位移**（否则拖拽末尾一段丢失，
    ///   表现为“松手前最后一点没跟上”）；
    /// - 返回 true = 值变了。
    pub fn zoomSquare(self: *Ui, id: u64, x: i32, y: i32, size: i32, value: *i32, min_v: i32, max_v: i32, pixels_per_unit: i32) bool {
        const hovered = self.hit(x, y, size, size);
        const changed = self.zoomSquareState(id, hovered, value, min_v, max_v, pixels_per_unit);

        // 绘制（位置固定；悬停/拖动时高亮）
        const active = self.active_id == id;
        const bg = if (active) self.theme.accent else if (hovered) self.theme.item_hover else self.theme.panel;
        self.renderer.fillRect(x, y, size, size, bg);
        self.renderer.strokeRect(x, y, size, size, self.theme.panel_border);
        // 提示符号「↕」（无字形时退化为空方块）
        const tw = self.font.measure("↕");
        const tx: i32 = x + @divTrunc(size - @as(i32, @intFromFloat(tw)), 2);
        self.font.draw(self.renderer, "↕", @floatFromInt(tx), @floatFromInt(self.centeredBaselineY(y, size)), self.theme.text);
        if (hovered or active) self.cursor = .resize_v;
        return changed;
    }

    /// 拖动数值控件（BPM 等）：按住上下拖 = 调值，**光标隐藏并冻结在原位**。
    /// 与 `zoomSquare` 共用同一套机制（冻结位移 `frozen_dy` → `zoomStep` 步进），
    /// 只是绘制不同（显示数值文本而非方块）。
    /// `pixels_per_unit`：几像素一单位（BPM 用 8 → 拖 8px 变 1 BPM）。
    /// 余数**跨帧累积**（慢拖不丢步）；上拖增大、下拖减小。
    /// 返回 true = 值变了。
    pub fn dragNumber(self: *Ui, id: u64, x: i32, y: i32, w: i32, h: i32, value: *i32, min_v: i32, max_v: i32, pixels_per_unit: i32) bool {
        return self.dragNumberEx(id, x, y, w, h, value, min_v, max_v, pixels_per_unit, 0, null);
    }

    /// `dragNumber` 的扩展版：支持**拖动值 ↔ 显示值解耦**。
    /// - `exp_scale` > 0 时：拖动的是“指数”（1 单位 = ×2，用于拍号分母等 2 的幂序列），
    ///   存储值是 `2^exponent`；拖动手感线性（不会因吸附写回而振荡）。
    /// - 否则：直接拖动存储值。
    /// `fmt`：自定义显示函数（null = 按 exp_scale 或存储值显示）。
    pub fn dragNumberEx(
        self: *Ui,
        id: u64,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        value: *i32,
        min_v: i32,
        max_v: i32,
        pixels_per_unit: i32,
        exp_scale: i32,
        fmt: ?*const fn (v: i32, buf: []u8) []const u8,
    ) bool {
        const hovered = self.hit(x, y, w, h);
        var changed = false;

        // 拖动值：指数模式 = log2(存储值)；否则 = 存储值
        const cur_drag: i32 = if (exp_scale > 0) log2Floor(@max(1, value.*)) else value.*;

        if (self.active_id == id) {
            const dd = self.frozen_dy - self.zoom_last_dy;
            self.zoom_last_dy = self.frozen_dy;
            // 指数模式：min_v/max_v 是**指数**范围（如 0..4 → 分母 1/2/4/8/16）；
            // 非指数模式：直接是存储值范围。
            const r = zoomStep(cur_drag, dd, self.zoom_rem, pixels_per_unit, min_v, max_v);
            self.zoom_rem = r.rem;
            const new_val: i32 = if (exp_scale > 0) @as(i32, 1) << @intCast(std.math.clamp(r.v, 0, 30)) else r.v;
            if (new_val != value.*) {
                value.* = new_val;
                changed = true;
            }
            if (!self.mouse_down) {
                self.active_id = 0;
                self.mouse_capture = false;
            }
        } else if (hovered and self.mouse_pressed) {
            self.active_id = id;
            self.zoom_last_dy = self.frozen_dy;
            self.zoom_rem = 0;
            self.mouse_capture = true; // 请求 main 隐藏并冻结鼠标
        }

        // 绘制：数值文本（拖动/悬停时高亮）
        const active = self.active_id == id;
        const bg = if (active) self.theme.accent else if (hovered) self.theme.item_hover else self.theme.toolbar;
        self.renderer.fillRect(x, y, w, h, bg);
        self.renderer.strokeRect(x, y, w, h, self.theme.panel_border);
        var buf: [16]u8 = undefined;
        const t = if (fmt) |f| f(value.*, &buf) else if (exp_scale > 0)
            std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "---"
        else
            std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "---";
        const tw: i32 = @intFromFloat(self.font.measure(t));
        const tx = x + @divTrunc(w - tw, 2);
        self.font.draw(self.renderer, t, @floatFromInt(tx), @floatFromInt(self.centeredBaselineY(y, h)), self.theme.text);
        if (hovered or active) self.cursor = .resize_v;
        return changed;
    }

    /// 垂直拖动调整归一化值（0..1；VST3 参数行用）——返回本帧是否变化。
    /// 锚点式：按下记起始值与起始冻结位移，拖动中从锚点累积（离散参数也能逐格步进）。
    pub fn dragNormV(self: *Ui, id: u64, x: i32, y: i32, w: i32, h: i32, value: *f64) bool {
        const hovered = self.hit(x, y, w, h);
        var changed = false;
        if (self.active_id == id) {
            const total_dy = self.frozen_dy - self.drag_dy0;
            const nv = std.math.clamp(self.drag_f0 + @as(f64, @floatFromInt(total_dy)) * 0.004, 0, 1);
            if (nv != value.*) {
                value.* = nv;
                changed = true;
            }
            if (!self.mouse_down) {
                self.active_id = 0;
                self.mouse_capture = false;
            }
        } else if (hovered and self.mouse_pressed) {
            self.active_id = id;
            self.mouse_capture = true;
            self.drag_f0 = value.*;
            self.drag_dy0 = self.frozen_dy;
        }
        if (hovered) self.cursor = .resize_v;
        return changed;
    }

    /// f32 → i32 **最近取整**（对负值也正确）。
    /// 坑：`@intFromFloat` 是**向零截断**，`@intFromFloat(v + 0.5)` 的“四舍五入”
    /// 只对非负数成立——负数下 -5.0 + 0.5 = -4.5 → 截成 -4（实测 bug：
    /// 功率推子拉到 -5，松手后显示 -4：每帧从存储重读、负值读回总是 +1）。
    pub fn roundF(v: f32) i32 {
        return @intFromFloat(@round(v));
    }

    /// 2 的幂的指数（floor；用于指数式推子）
    fn log2Floor(v: i32) i32 {
        var x = @max(1, v);
        var e: i32 = 0;
        while (x > 1) : (x >>= 1) e += 1;
        return e;
    }

    /// □ 缩放的状态更新（不绘制；与绘制分离便于单测）。
    /// 顺序：**先应用本帧累积位移，再清拖动状态**——松开帧的位移不能丢。
    pub fn zoomSquareState(self: *Ui, id: u64, hovered: bool, value: *i32, min_v: i32, max_v: i32, pixels_per_unit: i32) bool {
        var changed = false;
        if (self.active_id == id) {
            const dd = self.frozen_dy - self.zoom_last_dy;
            self.zoom_last_dy = self.frozen_dy;
            const r = zoomStep(value.*, dd, self.zoom_rem, pixels_per_unit, min_v, max_v);
            self.zoom_rem = r.rem;
            if (r.v != value.*) {
                value.* = r.v;
                changed = true;
            }
            if (!self.mouse_down) {
                self.active_id = 0;
                self.mouse_capture = false;
            }
        } else if (hovered and self.mouse_pressed) {
            self.active_id = id;
            self.zoom_last_dy = self.frozen_dy;
            self.zoom_rem = 0;
            self.mouse_capture = true;
        }
        return changed;
    }

    /// 缩放步进：`dd` 为冻结位移增量（向上为负 = 增大）。
    /// 返回新值与「不足一个单位」的余数（跨帧累积，慢拖不丢步）。
    pub fn zoomStep(value: i32, dd: i32, rem: i32, pixels_per_unit: i32, min_v: i32, max_v: i32) struct { v: i32, rem: i32 } {
        const k = @max(1, pixels_per_unit);
        const total = -dd + rem;
        const step = @divTrunc(total, k);
        return .{ .v = std.math.clamp(value + step, min_v, max_v), .rem = total - step * k };
    }

    /// 缩放时保持「视口垂直中心的内容」不动：返回新的滚动偏移（像素）。
    /// `old_unit_h` / `new_unit_h`：单位行高（轨道行 / 音高行）；
    /// `content_h_new`：缩放后的内容总高（钳制用）。
    pub fn zoomAnchoredScroll(scroll: i32, view_h: i32, old_unit_h: i32, new_unit_h: i32, content_h_new: i32) i32 {
        const o: f32 = @floatFromInt(@max(1, old_unit_h));
        const n: f32 = @floatFromInt(@max(1, new_unit_h));
        const half: f32 = @as(f32, @floatFromInt(view_h)) / 2.0;
        // 视口中心在「单位」坐标中的位置（缩放前后保持一致）
        const center_units = (@as(f32, @floatFromInt(scroll)) + half) / o;
        const new_scroll = center_units * n - half;
        return std.math.clamp(@as(i32, @intFromFloat(@round(new_scroll))), 0, @max(0, content_h_new - view_h));
    }

    /// 垂直缩放（Shift+滚轮）时保持「鼠标下的内容行」不动：返回新的纵向滚动偏移。
    /// - `view_h` = 可视高；`mouse_off` = 鼠标相对内容区顶缘的像素；
    /// - `old_unit_h`/`new_unit_h` = 单位行高（轨道行高 / 音高行高）；
    /// - `content_h_new` = 缩放后的内容总高（尾界钳制）。
    /// 与 `zoomAnchoredScroll`（视口中心锚定，□ 缩放用）同族，区别是锚在鼠标。
    pub fn zoomAnchoredScrollY(scroll: i32, view_h: i32, mouse_off: i32, old_unit_h: i32, new_unit_h: i32, content_h_new: i32) i32 {
        const o: f32 = @floatFromInt(@max(1, old_unit_h));
        const n: f32 = @floatFromInt(@max(1, new_unit_h));
        // 鼠标下的“单位坐标”（缩放前后保持一致）
        const units = (@as(f32, @floatFromInt(scroll)) + @as(f32, @floatFromInt(mouse_off))) / o;
        const ns = units * n - @as(f32, @floatFromInt(mouse_off));
        return std.math.clamp(@as(i32, @intFromFloat(@round(ns))), 0, @max(0, content_h_new - view_h));
    }

    /// 把横向滚动钳制到“内容跨度”内（缩放时的拉回）：视口右缘不越过 `span`
    /// （内容 + 右侧留白）；内容全部装得下（`view_cw >= span`）时 → 强制贴左。
    /// 用途：Ctrl+滚轮（无论 zoom 是否还能变）都执行一次——
    /// 否则“已缩到下限 + 视口停在右侧空白”时下滚会无事发生。
    pub fn clampScrollToSpan(scroll: i32, view_cw: i32, span: i32) i32 {
        const vcw = @max(1, view_cw);
        const den: i32 = if (span > 0) span else 0;
        const max_s = @max(0, @max(den, vcw) - vcw);
        return std.math.clamp(scroll, 0, max_s);
    }

    /// 横向缩放（Ctrl+滚轮）时保持「鼠标下的内容」不动：返回新的横向滚动偏移（内容像素）。
    /// - `mouse_off` = 鼠标相对内容区左缘的像素（屏幕坐标，可为负）；
    /// - 锚定：鼠标处的内容坐标 `cx = scroll + mouse_off/old_zoom` 缩放后仍在鼠标处；
    /// - `span`：**内容跨度**（最右内容 + 留白，0 = 不限制）——右边缘不超过
    ///   `span`（即视图不留在“内容右侧的空白区”里）；缩到极限时上界为 0 → 自动贴左。
    ///   否则：曾把时间轴往右拉过（content_w 被拉大）时，缩小后视图会留在右边看空白。
    pub fn zoomAnchoredScrollX(scroll: i32, view_w: i32, mouse_off: i32, old_zoom: f32, new_zoom: f32, content_w: i32, span: i32) i32 {
        // 防零下限只防“零/负”——**不能用 0.01**：时间轴超 ~12 万像素（几百小节）后
        // 合法缩放会跌破 0.01，旧下限会让锚定公式用错 zoom → 滑块位置/长度跳变（实测）
        const oz = @max(1e-9, old_zoom);
        const nz = @max(1e-9, new_zoom);
        const cx = @as(f32, @floatFromInt(scroll)) + @as(f32, @floatFromInt(mouse_off)) / oz;
        const ns = cx - @as(f32, @floatFromInt(mouse_off)) / nz;
        // 缩放后视口宽（内容像素）：内容至少一屏（与滚动条控件规范化一致）
        const view_cw_new = @as(f32, @floatFromInt(view_w)) / nz;
        var cw = @max(@as(f32, @floatFromInt(content_w)), view_cw_new);
        // 内容跨度限制：视图右边缘不越过 span（留白区只留 3 小节用量）
        if (span > 0) cw = @min(cw, @max(@as(f32, @floatFromInt(span)), view_cw_new));
        const max_scroll = @max(0, cw - view_cw_new);
        return @intFromFloat(std.math.clamp(ns, 0, max_scroll));
    }

    test "ui: zoomAnchoredScrollX——深缩放（zoom<0.01）锚定精确（几百小节跳变回归）" {
        // 时间轴 30 万像素（≈1560 小节）时 dyn_zoom_min≈0.004：
        // 旧版 @max(0.01) 下限会让 0.02→0.008 的锚定算出 100000（错）——正确为 55000
        const ns = Ui.zoomAnchoredScrollX(100000, 1200, 600, 0.02, 0.008, 300000, 300000);
        try std.testing.expectEqual(@as(i32, 55000), ns);
    }

    test "ui: zoomStep——向上拖增大、慢拖累积、范围钳制" {
        // 向上拖 8px（4px/单位）→ +2
        {
            const r = Ui.zoomStep(44, -8, 0, 4, 16, 120);
            try std.testing.expectEqual(@as(i32, 46), r.v);
            try std.testing.expectEqual(@as(i32, 0), r.rem);
        }
        // 向下拖 8px → -2
        {
            const r = Ui.zoomStep(44, 8, 0, 4, 16, 120);
            try std.testing.expectEqual(@as(i32, 42), r.v);
        }
        // 慢拖：每次 1px，累积到 4px 才跳 1 个单位（不丢步）
        {
            var v: i32 = 44;
            var rem: i32 = 0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const r = Ui.zoomStep(v, -1, rem, 4, 16, 120);
                v = r.v;
                rem = r.rem;
            }
            try std.testing.expectEqual(@as(i32, 45), v); // 4 次 -1px → +1
            try std.testing.expectEqual(@as(i32, 0), rem);
        }
        // 钳制：上限 / 下限
        {
            const r = Ui.zoomStep(118, -100, 0, 4, 16, 120);
            try std.testing.expectEqual(@as(i32, 120), r.v);
            const r2 = Ui.zoomStep(18, 100, 0, 4, 16, 120);
            try std.testing.expectEqual(@as(i32, 16), r2.v);
        }
    }

    test "ui: zoomAnchoredScrollX——横向缩放锚定鼠标下的内容" {
        // 放大：鼠标处内容停在鼠标处
        // view=380, mouse_off=100, 1.0→2.0, scroll=0 → cx=100 → ns=100-50=50
        try std.testing.expectEqual(@as(i32, 50), Ui.zoomAnchoredScrollX(0, 380, 100, 1.0, 2.0, 400, 0));
        // 缩小：1/2 → 鼠标处内容仍在鼠标处（scroll=50, cx=50+50=100 → ns=100-100=0）
        try std.testing.expectEqual(@as(i32, 0), Ui.zoomAnchoredScrollX(50, 380, 100, 2.0, 1.0, 400, 0));
        // 缩小到负值 → 钳到 0
        try std.testing.expectEqual(@as(i32, 0), Ui.zoomAnchoredScrollX(0, 380, 100, 1.0, 0.5, 400, 0));
        // 放大超出内容右端 → 钳到 max_scroll（content 400、view_cw_new=380/2=190 → 210）
        try std.testing.expectEqual(@as(i32, 210), Ui.zoomAnchoredScrollX(210, 380, 300, 1.0, 2.0, 400, 0));
    }

    test "ui: zoomAnchoredScrollX——span 限制（缩小后不留在内容右侧空白）" {
        // 场景：内容实际跨度 600，但曾把时间轴拉到 5000、视图在很右边（scroll=3000）
        // 缩小（1.0 → 0.1）：view_cw_new = 3800
        // 无 span 限制：cw = max(5000, 3800) = 5000 → 仍可停在右侧
        // 有 span=600：cw = min(5000, max(600, 3800)) = 3800 → max_scroll = 0（拉回左侧）
        const no_span = Ui.zoomAnchoredScrollX(3000, 380, 0, 1.0, 0.1, 5000, 0);
        try std.testing.expect(no_span > 0);
        const with_span = Ui.zoomAnchoredScrollX(3000, 380, 0, 1.0, 0.1, 5000, 600);
        try std.testing.expectEqual(@as(i32, 0), with_span);

        // span 很大（内容确实超一屏）→ 限制不生效（可正常右滚）
        const wide = Ui.zoomAnchoredScrollX(3000, 380, 0, 1.0, 1.0, 5000, 4800);
        try std.testing.expectEqual(@as(i32, 3000), wide);
    }

    test "ui: clampScrollToSpan——缩放时内容区拉回（含已缩到下限的场景）" {
        // 视口在内容内 / 右缘贴 span：不动
        try std.testing.expectEqual(@as(i32, 800), Ui.clampScrollToSpan(800, 200, 1000));
        // 视口停在 span 右侧空白：拉回到 span 右缘
        try std.testing.expectEqual(@as(i32, 800), Ui.clampScrollToSpan(3000, 200, 1000));
        // 内容全装得下（view_cw >= span）：强制贴左（“自动跳转到主内容区”）
        try std.testing.expectEqual(@as(i32, 0), Ui.clampScrollToSpan(500, 1200, 1000));
        // 负值 / 边界
        try std.testing.expectEqual(@as(i32, 0), Ui.clampScrollToSpan(-50, 200, 1000));
        try std.testing.expectEqual(@as(i32, 0), Ui.clampScrollToSpan(100, 200, 0));
    }

    test "ui: zoomAnchoredScroll——缩放时视口中心内容不动" {
        // 行高翻倍 → 滚动位置翻倍（中心内容不变）
        try std.testing.expectEqual(@as(i32, 300), Ui.zoomAnchoredScroll(100, 200, 44, 88, 100000));
        // 行高减半 → 滚动位置减半
        try std.testing.expectEqual(@as(i32, 100), Ui.zoomAnchoredScroll(300, 200, 88, 44, 100000));
        // 顶部 + 缩小 → 钳到 0
        try std.testing.expectEqual(@as(i32, 0), Ui.zoomAnchoredScroll(0, 200, 44, 22, 100000));
        // 接近底部 + 放大 → 钳到 max_scroll
        try std.testing.expectEqual(@as(i32, 200), Ui.zoomAnchoredScroll(150, 200, 44, 88, 400));
    }

    /// 可交互滚动条（垂直）：绘制轨道 + 滑块，支持**拖动滑块**。
    /// `scroll` 为当前滚动位置（像素），拖动时直接修改它。
    /// 返回 true = 本帧滚动位置变了。
    /// 坐标说明：`x`/`y`/`w`/`h` 是滚动条的**轨道**区域。
    pub fn scrollbarV(self: *Ui, id: u64, x: i32, y: i32, w: i32, h: i32, scroll: *i32, content_h: i32, view_h: i32) bool {
        // 内容收缩后回收 scroll（删轨道 / 撤销 / 行高缩放等）——不回收的话
        // 滑块会被顶出轨道（“超出最大行程”，实测；横向版每帧都回收，纵向漏了）。
        // **必须先于**“内容不超出”的提前返回：否则控件隐藏时 scroll 停在脏值。
        const max_scroll_all = @max(0, content_h - view_h);
        if (scroll.* > max_scroll_all) scroll.* = max_scroll_all;
        if (scroll.* < 0) scroll.* = 0;
        if (content_h < view_h) {
            // 内容装不满：不画滚动条（保持界面干净）；恰好等于视口时**画满行程滑块**
            // ——“缩到底 = 滑块刚好占满行程”（实测诉求）。
            return false;
        }

        // 轨道背景（凹槽）
        self.renderer.fillRect(x, y, w, h, self.theme.bg);

        // 滑块几何
        const ratio = @as(f32, @floatFromInt(view_h)) / @as(f32, @floatFromInt(content_h));
        const thumb_h = @max(min_thumb, @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(h)))));
        const max_scroll = content_h - view_h;
        const travel = h - thumb_h; // 滑块可移动距离

        var changed = false;
        const hovered = self.hit(x - 2, y, w + 4, h);

        // 拖动滑块：按鼠标位移换算滚动量
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                if (travel > 0) {
                    const rel = @as(f32, @floatFromInt(self.mouse_y - y - self.drag_start)) / @as(f32, @floatFromInt(travel));
                    const new_scroll = std.math.clamp(@as(i32, @intFromFloat(rel * @as(f32, @floatFromInt(max_scroll)))), 0, max_scroll);
                    if (new_scroll != scroll.*) {
                        scroll.* = new_scroll;
                        changed = true;
                    }
                }
            }
        } else if (hovered and self.mouse_pressed) {
            self.active_id = id;
            // drag_start = 鼠标相对滑块顶部的偏移（点滑块内部拖动时不跳变）
            const t0 = if (max_scroll > 0) @as(f32, @floatFromInt(scroll.*)) / @as(f32, @floatFromInt(max_scroll)) else 0;
            const thumb_y0 = y + @as(i32, @intFromFloat(t0 * @as(f32, @floatFromInt(travel))));
            self.drag_start = self.mouse_y - thumb_y0;
        }

        // 绘制滑块
        const t = if (max_scroll > 0) @as(f32, @floatFromInt(scroll.*)) / @as(f32, @floatFromInt(max_scroll)) else 0;
        const thumb_y = y + @as(i32, @intFromFloat(t * @as(f32, @floatFromInt(travel))));
        const active = self.active_id == id;
        const color = if (active or hovered) self.theme.accent else self.theme.scrollbar;
        self.renderer.fillRect(x, thumb_y, w, thumb_h, color);
        self.renderer.strokeRect(x, thumb_y, w, thumb_h, self.theme.panel_border);
        return changed;
    }

    /// 纵向投影（滑块 = 视口在地图上的投影）：返回相对轨道的 `[top, bot)`——
    /// 钳到 `[0, h]`；**显示层最小 1px**：投影亚像素且与轨道相交时仍占位“一根线”。
    /// 命中与绘制共用同一规则（看得见就抓得住）。
    fn projThumbY(scroll: i32, view_h: i32, content_h: i32, h: i32) struct { top: i32, bot: i32 } {
        const c64: i64 = @max(1, content_h);
        const h64: i64 = @max(1, h);
        const raw_top: i64 = @divTrunc(@as(i64, scroll) * h64, c64);
        const raw_bot: i64 = @divTrunc((@as(i64, scroll) + view_h) * h64, c64);
        const top: i32 = @intCast(std.math.clamp(raw_top, 0, h64));
        var bot: i32 = @intCast(std.math.clamp(raw_bot, 0, h64));
        if (bot <= top and raw_bot > 0 and raw_top < h64) bot = top + 1;
        return .{ .top = top, .bot = bot };
    }

    /// 横向投影（同 `projThumbY`，轴换 x）：返回相对轨道的 `[x, len)`。
    fn projThumbX(scroll: i32, view_cw: i32, content_w: i32, w: i32) struct { x: i32, len: i32 } {
        const c64: i64 = @max(1, content_w);
        const w64: i64 = @max(1, w);
        const raw_x: i64 = @divTrunc(@as(i64, scroll) * w64, c64);
        const raw_len: i64 = @divTrunc(@as(i64, view_cw) * w64, c64);
        const xpos: i32 = @intCast(std.math.clamp(raw_x, 0, w64));
        var len: i32 = @intCast(std.math.clamp(raw_len, 0, w64));
        if (len == 0 and xpos < w64 and raw_x + raw_len > 0) len = 1;
        return .{ .x = xpos, .len = len };
    }

    /// 纵向滚动条（播放列表专用）——**纯投影（mipmap）语义 + 无界悬空**
    /// （用户拍板的新设计；横向验证后再移植同款）。
    ///
    /// - 滑块 = 视口在地图上的**原始投影**：上缘 = `scroll/内容长 × 轨道长`，
    ///   高 = `视口/内容长 × 轨道长`；超出轨道的部分**裁剪绘制**（不压缩、不增长）；
    /// - **滚动可越过地图底**（“悬空”）：拖滑块越过底缘继续拖 → 视口继续下移、滑块整体
    ///   滑出轨道（完全出界 → 不可见）；**总行程（地图）不动**、无任何回收状态——
    ///   往上滚 / 中键拖回来，滑块自然重现；
    /// - 拖动全程按**地图比例 1:1**（鼠标 1px = `内容长/轨道长` px 内容坐标）——
    ///   过门前后速度天然一致（旧版“压短滑块 + 反推跨度”的 1/thumb² 爆炸已根治）；
    /// - 按下只在滑块（**可见部分**）上生效；悬空时点轨道列无事（未来“点击地图跳回”的位）；
    /// - `scroll` 只硬钳下界 0（地图**上缘**是绝对原点）与内部防溢出帽（交互无感）；
    /// - minimap 内容块（`mini`）+ 半透明高亮窗滑块——与横向同一观感。
    pub fn scrollbarVExt(self: *Ui, id: u64, x: i32, y: i32, w: i32, h: i32, scroll: *i32, content_h: i32, view_h: i32, allow_overhang: bool, mini: []const MiniBlock) bool {
        const cap: i32 = 1 << 30; // 内部防溢出（i32 内绝对安全；交互上无感）
        if (scroll.* < 0) scroll.* = 0;
        if (scroll.* > cap) scroll.* = cap;
        if (content_h < view_h) return false;
        const content64: i64 = @max(1, content_h);
        const h64: i64 = @max(1, h);

        // 轨道背景（凹槽）
        self.renderer.fillRect(x, y, w, h, self.theme.bg);

        // minimap 内容块（背景之上、滑块之下）：**横置 90°**——沿轴 = pos/len（行像素），
        // 交叉轴 = blk.y（0..1，片段的时间位置；同横向里“轨道位置”的角色）；整图不随滚动移动
        if (mini.len > 0) {
            const inner_x = x + 2;
            const inner_w = @max(4, w - 4);
            for (mini) |blk| {
                const by = y + @as(i32, @intCast(@divTrunc(@as(i64, blk.pos) * h, content64)));
                const bh = @max(1, @as(i32, @intCast(@divTrunc(@as(i64, blk.len) * h, content64))));
                if (by >= y + h or by + bh <= y) continue; // 不在轨道可视范围内：跳过
                if (blk.kind == .full) {
                    self.renderer.fillRect(inner_x, by, inner_w, bh, blk.color);
                } else {
                    // 交叉轴定位（时间类）：按 y 映射到内宽内的一条（钳制越界）
                    const y_norm = std.math.clamp(blk.y, 0, 1);
                    const bx = inner_x + @as(i32, @intFromFloat(y_norm * @as(f32, @floatFromInt(inner_w - 2))));
                    self.renderer.fillRect(bx, by, 2, bh, blk.color);
                }
            }
        }

        // 投影几何（帧首快照，命中/拖动共用；helper 内置**显示层最小 1px 线**）
        const pr = projThumbY(scroll.*, view_h, content_h, h);
        const vis_top = y + pr.top;
        const vis_bot = y + pr.bot;

        var changed = false;
        const hovered = self.hit(x - 2, y, w + 4, h);
        // 按下只在滑块的**可见部分**上生效（完全出界 → 不可见 → 不响应）
        const in_thumb = hovered and pr.bot > 0 and pr.top < h and
            self.mouse_y >= vis_top and self.mouse_y < vis_bot;

        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                // 地图比例 1:1（按下时快照）——**位移式**（零位移恒等：鼠标点着不动、反复
                // 按/松不会漂移；旧“绝对位置复原”每次点击丢掉亚像素分数 → 累积左移/上移，实测）
                const dy: i64 = @as(i64, self.mouse_y) - @as(i64, self.drag_mx0);
                const ns64 = @as(i64, self.drag_scroll0) + @divTrunc(dy * @max(1, self.drag_content0), h64);
                var ns: i32 = @intCast(std.math.clamp(ns64, 0, @as(i64, cap)));
                // 巨图模式（allow_overhang=false）：拖动不得再出图，只允许往回（回程不限）
                if (!allow_overhang) {
                    const map_s: i32 = @max(0, content_h - view_h);
                    ns = @min(ns, @max(map_s, self.drag_scroll0));
                }
                if (ns != scroll.*) {
                    scroll.* = ns;
                    changed = true;
                }
            }
        } else if (in_thumb and self.mouse_pressed) {
            self.active_id = id;
            self.drag_content0 = content_h; // 快照（地图比例；与横向共用字段——两者不同时拖动）
            self.drag_scroll0 = scroll.*; // 快照（位移式基准：零位移恒等；巨图模式“只允许往回”的基准）
            self.drag_mx0 = self.mouse_y; // 位移式基准（纵向用 y）
        } else if (hovered and self.mouse_pressed) {
            // **点击小地图（滑块外）→ 点击的内容置于视口正中**（用户拍板：可以产生悬空；
            // 唯一例外 = 上端：不允许上悬空 → 硬钳 0）。按住继续拖 = 滑块跟手。
            const target_top = self.mouse_y - y;
            const clicked = @divTrunc(@as(i64, target_top) * @max(1, content_h), h64); // 点击处的内容坐标
            const ns64 = clicked - @divTrunc(@as(i64, view_h), 2); // 视口中心对准点击处
            const cap_eff: i64 = if (allow_overhang) cap else @max(0, content_h - view_h); // 巨图模式不出图
            const ns: i32 = @intCast(std.math.clamp(ns64, 0, cap_eff));
            if (ns != scroll.*) {
                scroll.* = ns;
                changed = true;
            }
            self.active_id = id;
            self.drag_content0 = content_h;
            self.drag_mx0 = self.mouse_y; // 位移式基准（后续拖动零位移恒等）
            self.drag_scroll0 = ns; // 基准 = 定位后的新滚动
        }

        // 绘制滑块（本帧最终状态重投影，**裁剪**到轨道；悬空部分裁掉；完全出界不画）
        const prf = projThumbY(scroll.*, view_h, content_h, h);
        if (prf.bot > prf.top) {
            const active = self.active_id == id;
            // 半透明高亮窗：minimap 内容块透出；层级：拖动 > 悬停 > 静止（同横向）
            const color = if (active or hovered) self.theme.accent else self.theme.scrollbar_light;
            const tint_a: u8 = if (active) 150 else if (hovered) 120 else 70;
            const tint = (@as(u32, tint_a) << 24) | (color & 0x00FFFFFF);
            self.renderer.fillRect(x, y + prf.top, w, prf.bot - prf.top, tint);
            self.renderer.strokeRect(x, y + prf.top, w, prf.bot - prf.top, color);
        }
        return changed;
    }

    /// 可交互**横向时间轴**滚动条（minimap 语义，播放列表/钢琴窗共用实例）——
    /// 与纵向 `scrollbarVExt` 同一套“**纯投影 + 无界悬空**”设计
    /// （完整规则见 docs/timeline-scrollbar.md）：
    /// - 滑块 = 视口在地图上的原始投影（`scroll/地图长` / `视口/地图长`），超出部分裁剪；
    /// - 拖主体 = 地图 1:1 平移（位移式：零位移恒等）；越过右端 → 悬空；左端硬钳 0；
    /// - 拖左/右缘（≤8px）= 缩放（位移式；无“正方形”下限；悬空量保留）；
    /// - 点击滑块外空白 = 点击处居中于视口（可产生悬空；仅左端例外钳 0）；
    /// - `allow_overhang=false`（巨图模式）：拖动/点击不得再出图，只允许往回；
    /// - `content_min_w`：与可写的 `content_w` 取 max 后的地图下限（旧接口形状兼容）；
    /// - 返回 true = 本帧发生了变化。
    pub fn scrollbarTimeline(
        self: *Ui,
        id: u64,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        scroll: *i32,
        content_w: *i32,
        zoom: *f32,
        view_w: i32,
        content_min_w: i32,
        zoom_min: f32,
        zoom_max: f32,
    ) bool {
        return self.scrollbarTimelineEx(id, x, y, w, h, scroll, @max(content_w.*, content_min_w), zoom, view_w, zoom_min, zoom_max, true, &.{});
    }

    /// 同上，但带 **minimap 内容块**（`mini` 画在滑块之下，内容分布可见）。
    pub fn scrollbarTimelineEx(
        self: *Ui,
        id: u64,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        scroll: *i32,
        content_w: i32,
        zoom: *f32,
        view_w: i32,
        zoom_min: f32,
        zoom_max: f32,
        allow_overhang: bool,
        mini: []const MiniBlock,
    ) bool {
        const edge = 8; // 边缘命中区上限（缩放）
        const cap: i32 = 1 << 30; // 内部防溢出（交互无感）

        // ── 规范化（每帧）──
        // zoom：只钳上限，不被动抬高（旧行为保留——内容缩短时视口不被自动放大）；
        // 缩放下限只在**用户主动缩放**时生效（滚轮→视图侧；拖边缘→下方 zoom_floor）。
        // 防零下限（兼顾 i32 值域：view/zoom 不得越过 @intFromFloat 上限）——
        // 同样不能用 0.001：巨大时间轴（数千小节）的合法缩放会低于它
        if (zoom.* < 1e-6) zoom.* = 1e-6;
        if (zoom.* > zoom_max) zoom.* = zoom_max;
        const view_cw = @max(1, viewCw(view_w, zoom.*));
        // 地图 = max(时间轴【调用方传入】，一屏)——空工程/高倍缩小时投影不超宽
        const cw_eff: i32 = @max(content_w, view_cw);
        // scroll：硬钳下界 0（时间轴左端 = 绝对原点）+ 防溢出帽；**上界不设**——
        // 可滚过地图右端（悬空），由拖动/中键产生，滚轮不得加深（视图侧钳制）
        if (scroll.* < 0) scroll.* = 0;
        if (scroll.* > cap) scroll.* = cap;
        const cw64: i64 = @max(1, cw_eff);
        const w64: i64 = @max(1, w);

        // 投影几何（帧首快照，命中/拖动共用；helper 内置**显示层最小 1px 线**）
        const pr = projThumbX(scroll.*, view_cw, cw_eff, w);
        const vis_l = x + pr.x;
        const vis_r = x + @min(w, pr.x + pr.len);
        const edge_zone = @min(edge, @max(4, @divTrunc(pr.len, 3)));

        // 轨道背景（凹槽，常显）
        self.renderer.fillRect(x, y, w, h, self.theme.bg);

        // minimap 内容块（在背景之上、滑块之下）：内容分布按比例映射到轨道
        if (mini.len > 0) {
            const inner_y = y + 2;
            const inner_h = @max(4, h - 4);
            for (mini) |blk| {
                const bx = x + @as(i32, @intCast(@divTrunc(@as(i64, blk.pos) * w, cw64)));
                const bw = @max(1, @as(i32, @intCast(@divTrunc(@as(i64, blk.len) * w, cw64))));
                if (bx >= x + w or bx + bw <= x) continue; // 不在轨道可视范围内：跳过
                if (blk.kind == .full) {
                    // 占满全高（片段类）
                    self.renderer.fillRect(bx, inner_y, bw, inner_h, blk.color);
                } else {
                    // 纵向定位（音符类）：按 y 映射到内部高度内的一小条（钳制越界）
                    const y_norm = std.math.clamp(blk.y, 0, 1);
                    const by = inner_y + @as(i32, @intFromFloat(y_norm * @as(f32, @floatFromInt(inner_h - 2))));
                    self.renderer.fillRect(bx, by, bw, 2, blk.color);
                }
            }
        }

        var changed = false;
        const hovered = self.hit(x, y, w, h);
        // 按下只在滑块的**可见部分**上生效（完全悬空 → 不可见 → 不响应）
        const in_thumb = hovered and vis_r > vis_l and self.mouse_x >= vis_l and self.mouse_x < vis_r;
        const on_left = in_thumb and self.mouse_x < vis_l + edge_zone;
        const on_right = in_thumb and self.mouse_x >= vis_r - edge_zone;

        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                switch (self.drag_mode_h) {
                    .body => {
                        // 地图比例 1:1（按下时快照）——**位移式**（零位移恒等：鼠标点着不动、
                        // 反复按/松不会漂移——旧“绝对位置复原”每次点击丢掉亚像素分数、累积偏移）
                        const dx: i64 = @as(i64, self.mouse_x) - @as(i64, self.drag_mx0);
                        const ns64 = @as(i64, self.drag_scroll0) + @divTrunc(dx * @max(1, self.drag_content0), w64);
                        var ns: i32 = @intCast(std.math.clamp(ns64, 0, @as(i64, cap)));
                        // 巨图模式（allow_overhang=false）：拖动不得再出图，只允许往回（回程不限）
                        if (!allow_overhang) {
                            const map_s: i32 = @max(0, cw_eff - view_cw);
                            ns = @min(ns, @max(map_s, self.drag_scroll0));
                        }
                        if (ns != scroll.*) {
                            scroll.* = ns;
                            changed = true;
                        }
                    },
                    .left => {
                        // 拖左缘：缩放（右缘钉住）——**位移式**（零位移恒等；无“正方形”下限：
                        // 可一路压到 1px 线）。旧版用“绝对宽度 + min_w 钳制”，亚像素滑块下
                        // 一点击就跳成正方形、视野突扩（实测）——已废。
                        const dx: i32 = self.mouse_x - self.drag_mx0; // 右移 = 拖窄
                        const tw0f: f32 = @as(f32, @floatFromInt(self.drag_view_cw0)) * @as(f32, @floatFromInt(w)) /
                            @as(f32, @floatFromInt(@max(1, cw_eff)));
                        var twf: f32 = tw0f - @as(f32, @floatFromInt(dx));
                        const twf_floor: f32 = @min(tw0f, 1); // 压缩下限 = min(起始宽, 1px)：
                        // 亚像素起始不许被“抬到 1px”（否则零位移也跳）；正常情况即 1px 线
                        if (twf < twf_floor) twf = twf_floor;
                        const twf_max: f32 = @floatFromInt(self.drag_anchor_x - x); // 左缘不出轨道左端
                        if (twf > twf_max) twf = twf_max;
                        const new_view_cw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.drag_view_cw0)) * (twf / tw0f))));
                        const zoom_floor = @min(zoom.*, @min(zoom_min, @as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(@max(1, cw_eff)))));
                        const new_zoom = std.math.clamp(@as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(new_view_cw)), zoom_floor, zoom_max);
                        if (new_zoom != zoom.*) {
                            zoom.* = new_zoom;
                            changed = true;
                        }
                        const vcw = @max(1, viewCw(view_w, zoom.*));
                        const over0 = @max(0, self.drag_scroll0 - @max(0, self.drag_content0 - self.drag_view_cw0)); // 悬空量保留
                        const ns = std.math.clamp(self.drag_scroll0 + self.drag_view_cw0 - vcw, 0, @max(0, cw_eff - vcw)) + over0;
                        if (ns != scroll.*) {
                            scroll.* = ns;
                            changed = true;
                        }
                    },
                    .right => {
                        // 拖右缘：缩放（左缘钉住）——位移式；同一套比例/下限
                        const dx: i32 = self.mouse_x - self.drag_mx0; // 右移 = 拉宽
                        const tw0f: f32 = @as(f32, @floatFromInt(self.drag_view_cw0)) * @as(f32, @floatFromInt(w)) /
                            @as(f32, @floatFromInt(@max(1, cw_eff)));
                        var twf: f32 = tw0f + @as(f32, @floatFromInt(dx));
                        const twf_floor: f32 = @min(tw0f, 1); // 同左：亚像素起始不被抬升
                        if (twf < twf_floor) twf = twf_floor;
                        const twf_max: f32 = @floatFromInt(x + w - self.drag_anchor_x); // 右缘不出轨道右端
                        if (twf > twf_max) twf = twf_max;
                        const new_view_cw: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.drag_view_cw0)) * (twf / tw0f))));
                        const zoom_floor = @min(zoom.*, @min(zoom_min, @as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(@max(1, cw_eff)))));
                        const new_zoom = std.math.clamp(@as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(new_view_cw)), zoom_floor, zoom_max);
                        if (new_zoom != zoom.*) {
                            zoom.* = new_zoom;
                            changed = true;
                        }
                        const vcw = @max(1, viewCw(view_w, zoom.*));
                        const over0 = @max(0, self.drag_scroll0 - @max(0, self.drag_content0 - self.drag_view_cw0));
                        const ns = std.math.clamp(self.drag_scroll0, 0, @max(0, cw_eff - vcw)) + over0;
                        if (ns != scroll.*) {
                            scroll.* = ns;
                            changed = true;
                        }
                    },
                }
            }
        } else if (in_thumb and self.mouse_pressed) {
            self.active_id = id;
            self.drag_content0 = cw_eff;
            self.drag_scroll0 = scroll.*;
            self.drag_view_cw0 = view_cw;
            if (on_left and on_right) {
                // 窄滑块：两缘都近时按鼠标相对位置就近选
                self.drag_mode_h = if (self.mouse_x - vis_l <= vis_r - self.mouse_x) .left else .right;
            } else if (on_left) {
                self.drag_mode_h = .left;
            } else if (on_right) {
                self.drag_mode_h = .right;
            } else {
                self.drag_mode_h = .body;
            }
            switch (self.drag_mode_h) {
                .body => {},
                .left => {
                    self.drag_anchor_x = vis_r; // 参考右缘（缩放上限用）
                },
                .right => self.drag_anchor_x = vis_l, // 参考左缘
            }
            self.drag_mx0 = self.mouse_x; // 位移式基准（零位移恒等）
        } else if (hovered and self.mouse_pressed) {
            // **点击小地图（滑块外）→ 点击的内容置于视口正中**（可以产生悬空；
            // 唯一例外 = 左端：不允许左悬空 → 硬钳 0）。按住继续拖 = 滑块跟手。
            const target_left = self.mouse_x - x;
            const clicked = @divTrunc(@as(i64, target_left) * @max(1, cw_eff), w64); // 点击处的内容坐标
            const ns64 = clicked - @divTrunc(@as(i64, view_cw), 2); // 视口中心对准点击处
            const cap_eff: i64 = if (allow_overhang) cap else @max(0, cw_eff - view_cw); // 巨图模式不出图
            const ns: i32 = @intCast(std.math.clamp(ns64, 0, cap_eff));
            if (ns != scroll.*) {
                scroll.* = ns;
                changed = true;
            }
            self.active_id = id;
            self.drag_content0 = cw_eff;
            self.drag_scroll0 = scroll.*;
            self.drag_view_cw0 = view_cw;
            self.drag_mode_h = .body;
            self.drag_mx0 = self.mouse_x; // 位移式基准（后续拖动零位移恒等）
        }

        // 绘制滑块（用**本帧最终状态**重投影，**裁剪**到轨道；悬空部分裁掉；完全出界不画）
        const active = self.active_id == id;
        const vcw_final = @max(1, viewCw(view_w, zoom.*));
        const prf = projThumbX(scroll.*, vcw_final, @max(content_w, vcw_final), w);
        const fw_fin: i32 = @min(w - prf.x, prf.len);
        if (fw_fin > 0) {
            // 半透明高亮窗：minimap 内容块透出；层级：拖动 > 悬停 > 静止
            const color = if (active or hovered) self.theme.accent else self.theme.scrollbar_light;
            const tint_a: u8 = if (active) 150 else if (hovered) 120 else 70;
            const tint = (@as(u32, tint_a) << 24) | (color & 0x00FFFFFF);
            self.renderer.fillRect(x + prf.x, y, fw_fin, h, tint);
            self.renderer.strokeRect(x + prf.x, y, fw_fin, h, color);
        }

        // 光标：边缘（缩放）/ 主体（平移）
        if (active) {
            if (self.drag_mode_h != .body) self.cursor = .resize_h;
        } else if (on_left or on_right) {
            self.cursor = .resize_h;
        }
        return changed;
    }

    /// 视口可见内容宽度（内容像素）= view_w / zoom
    fn viewCw(view_w: i32, z: f32) i32 {
        return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(view_w)) / z)));
    }

    /// 滚动条滑块最小长度（像素）——低于此值不再缩短
    pub const min_thumb: i32 = 24;

    /// minimap 内容块（时间轴滚动条用）：`pos`/`len` 为**内容像素**，
    /// 由调用方按内容（片段/音符）填充，控件负责映射到轨道比例上绘制。
    /// `kind` 决定纵向画法：`.full` = 通高（片段类）；`.note` = 按 `y`（0=顶、1=底）
    /// 映射到内部高度内的细条（音符类，能看出纵向结构）。
    pub const MiniKind = enum { full, note };
    pub const MiniBlock = struct {
        pos: i32,
        len: i32,
        kind: MiniKind = .full,
        /// 仅 `.note` 用：纵向位置 0-1（0 = 顶、1 = 底）；越界自动钳制
        y: f32 = 0,
        color: r_mod.Color,
    };

    /// 滚动条（垂直）：仅绘制（交互留给调用方）。
    /// `scroll` / `content_h` / `view_h` 都是像素单位。
    pub fn drawScrollbar(self: *Ui, x: i32, y: i32, w: i32, h: i32, scroll: i32, content_h: i32, view_h: i32) void {
        if (content_h <= view_h) return;
        self.renderer.fillRect(x, y, w, h, self.theme.panel);
        const ratio = @as(f32, @floatFromInt(view_h)) / @as(f32, @floatFromInt(content_h));
        const thumb_h = @max(20, @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(h)))));
        const max_scroll = content_h - view_h;
        const t = if (max_scroll > 0) @as(f32, @floatFromInt(scroll)) / @as(f32, @floatFromInt(max_scroll)) else 0;
        const thumb_y = y + @as(i32, @intFromFloat(t * @as(f32, @floatFromInt(h - thumb_h))));
        self.renderer.fillRect(x, thumb_y, w, thumb_h, self.theme.scrollbar);
    }

    // ── 内部：命中测试与拖动 ──

    /// 公开的命中测试（供调用方判断"鼠标是否在区域内"，如滚动处理）
    pub fn hitRect(self: *Ui, x: i32, y: i32, w: i32, h: i32) bool {
        return self.hit(x, y, w, h);
    }

    fn hit(self: *Ui, x: i32, y: i32, w: i32, h: i32) bool {
        if (self.input_blocked) return false; // 被浮动窗口/菜单覆盖：底层不响应
        return self.mouse_x >= x and self.mouse_x < x + w and
            self.mouse_y >= y and self.mouse_y < y + h;
    }

    fn draggable(self: *Ui, id: u64, hovered: bool, x: i32, w: i32, value: *f32) bool {
        if (hovered and self.mouse_pressed) {
            self.active_id = id;
            self.drag_anchor = @as(f32, @floatFromInt(self.mouse_x - x)) / @as(f32, @floatFromInt(w)) - value.*;
        }
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                const rel = @as(f32, @floatFromInt(self.mouse_x - x)) / @as(f32, @floatFromInt(w));
                const new_val = std.math.clamp(rel - self.drag_anchor, 0, 1);
                if (new_val != value.*) {
                    value.* = new_val;
                    return true;
                }
            }
        }
        return false;
    }

    fn draggableV(self: *Ui, id: u64, hovered: bool, y: i32, h: i32, value: *f32) bool {
        if (hovered and self.mouse_pressed) {
            self.active_id = id;
            const rel = 1.0 - @as(f32, @floatFromInt(self.mouse_y - y)) / @as(f32, @floatFromInt(h));
            self.drag_anchor = rel - value.*;
        }
        if (self.active_id == id) {
            if (!self.mouse_down) {
                self.active_id = 0;
            } else {
                const rel = 1.0 - @as(f32, @floatFromInt(self.mouse_y - y)) / @as(f32, @floatFromInt(h));
                const new_val = std.math.clamp(rel - self.drag_anchor, 0, 1);
                if (new_val != value.*) {
                    value.* = new_val;
                    return true;
                }
            }
        }
        return false;
    }
};


test "ui: 遮罩矩形登记与命中（插件子窗口遮挡判定用）" {
    var ui = Ui{ .renderer = undefined, .font = undefined };
    ui.overlay_n = 0;
    ui.noteOverlayRect(10, 10, 100, 50);
    try std.testing.expect(ui.overlayBlocks(50, 20, 10, 10)); // 相交
    try std.testing.expect(ui.overlayBlocks(105, 55, 10, 10)); // 边缘相交
    try std.testing.expect(!ui.overlayBlocks(200, 200, 10, 10)); // 不相交
    try std.testing.expect(!ui.overlayBlocks(0, 0, 10, 5)); // 左上方
    // 上限：超过 16 个丢弃（不崩）；beginFrame 会清空
    ui.overlay_n = 0;
    var i: usize = 0;
    while (i < 40) : (i += 1) ui.noteOverlayRect(0, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 16), ui.overlay_n);
    try std.testing.expect(ui.overlayBlocks(0, 0, 1, 1));
}
