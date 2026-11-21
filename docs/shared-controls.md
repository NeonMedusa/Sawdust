# 共享控件：右键菜单面板 / 浮动窗口外壳 — 设计文档

> 实现：`src/view_util.zig` 的 `menuPanel` / `windowChrome` / `menuButton` /
> `menuFrameBegin` / `titleCloseButton` / `clampWindow`。
> 2026-11 起，全部手写右键菜单（11 处）与浮动窗口外壳（11 处）都收敛到这两个控件——
> 以前每个窗口各写一份（菜单 ~30 行 × 13、外壳 ~50 行 × 10），同一套坑各踩一遍。

## 一句话概括

- `menuPanel` = **右键/下拉菜单的全部绘制与命中**（面板、hover、点击、点外关闭、
  位置快照、插件子窗口遮挡登记）；调用方只出**条目表 + 状态指针 + 动作分发**。
- `windowChrome` = **浮动窗口的全部外壳交互**（阴影、背景、边框、标题栏、关闭、
  标题拖动、右下角缩放柄）；调用方只出**状态指针 + 标题 + 各自的收尾语义**。

## 核心模型

### menuPanel

```
状态（调用方自备）：open / just_opened / mx / my
锚定 MenuAnchor：
  .button   → 开启帧锚到按钮下方（放不下向上翻转）
  .cursor   → 开启帧快照鼠标位置（不跟鼠标跑——“钓竿上的胡萝卜”）
  .snapshot → 位置已由调用方存好（可能还带每帧钳制），不自算、只享受开帧保护
```

- **位置只在开启帧写**（`just_opened`），之后每帧只读；
- `just_opened` 同时挡**条目点击**与**点外关闭**——左键打开的菜单（如 VST 参数行
  菜单）打开那次 mouse_pressed 还压在条目上，不挡会“开了秒选第一项”；
- **条目点击用裸 `inRect`**（菜单是最上层模态，`menuIsOpen()` 已计入其状态 →
  下层全被屏蔽）；调用方自己的窗口控件用 `hitUI` 让位；
- `enabled: ?[]const bool`：null = 全可用；越界视为可用（防御短数组）。

### windowChrome

```
状态约定（字段名各窗口一致，不改布局）：
  x / y / w / h          窗口矩形
  grab_dx / grab_dy      拖动抓取偏移（按下时存——“拿起来就跳”的防线）
  resize_w0/h0/mx/my     缩放起点快照（按下时存，全程用它换算）
```

- **拖动/缩放的 id 都显式传**（`drag_id` / `grip_id`），不搞 `id+1` 约定——
  设置窗的缩放柄就是 **9541** 而 9521 被 toggle2 占着，任何隐式约定必撞
  （`docs/pitfalls.md` 的“控件 id 撞车”系列事故的根治手段）；
- 标题用 `labelMiddle`（中段省略）：动态标题（乐器/参数名）超长保留两头，
  不溢出到右侧按钮区；
- `title_right_pad`：标题栏右侧保留宽度（关闭按钮 + 内嵌按钮；只有
  `w - title_right_pad` 那段可拖动）。**各窗口的内嵌按钮必须整体落在保留区内**——
  这是“按按钮不触发拖动”的机制保证（替代旧的 `title_btn_used` 手工标志）。

## 手势

| 手势 | menuPanel | windowChrome |
|---|---|---|
| 打开帧 | 位置按锚定方式写入；不判点击 | 不适用 |
| 条目/标题 hover | `item_hover` 高亮；文字 accent | 拖动区无高亮 |
| 点击条目 | 记 `clicked` + `open=false` | 不适用 |
| 点外部 | `open=false`（开启帧跳过） | 不适用 |
| 标题按下/拖动 | 不适用 | 存抓取偏移 → `x = mouse − grab` |
| 缩放柄按下/拖动 | 不适用 | 存起点快照 → `w = w0 + Δmouse` |
| 点关闭 | 不适用 | 返回 true，**调用方收尾** |

## 不变量

1. **拖动/缩放换算必须用按下时快照**（`docs/pitfalls.md` 的时间轴滚动条事故）：
   `grab_*` / `resize_*` 只在 `mouse_pressed` 帧写，之后只读；
2. `menuPanel` 每次调用登记 `noteOverlayRect`（插件子窗口遮挡——菜单是弹层）；
   `windowChrome` **不登记**（整窗登记会让 `syncEmbeddedEditor` 把插件 GUI 的
   输入闸门拉下，实测“一开自动化窗口插件就点不动”）；窗口遮挡走 `win_draw_info`；
3. `just_opened` 必须逐帧清（`menuFrameBegin` / 调用方自管），否则“点外部关闭”永久失效；
4. 外壳返回 `true`（点了关闭）时**只做绘制层的事**；清理（关菜单/停试听/丢草案）
   是调用方语义，写在调用方的 if 分支里。

## 快照语义

- 菜单位置：开启帧一次快照，之后固定（`.snapshot` 锚 = 调用方已经在打开时快照过）；
- 窗口拖动/缩放：按下帧快照，全程用它换算；
- 两个控件都**无跨帧隐藏状态**——所有持久量都在调用方的窗口状态里。

## 调用方契约

```zig
// 右键菜单（右键打开 → 位置已快照在状态里；点外/点条目都由 menuPanel 收口）
var open = true;
var mx = st.menu_x;               // 已快照（需要每帧钳制的窗口用局部变量传）
var my = st.menu_y;
if (util.menuPanel(ui, &mx, &my, &open, false, .{ .cursor = {} }, bounds, items, menu_w, enabled)) |ci| {
    // …按 ci 分发动作…
    st.menu_x = 0; st.menu_target = null;   // 调用方自己的关闭收尾
} else if (!open) {
    st.menu_target = null;
}

// 浮动窗口外壳（返回 true = 点了关闭 → 调用方收尾并 return）
if (util.windowChrome(ui, drag_id, grip_id, title, title_h_, right_pad,
        &st.x, &st.y, &st.w, &st.h, &st.grab_dx, &st.grab_dy,
        &st.resize_w0, &st.resize_h0, &st.resize_mx, &st.resize_my, resizable)) {
    st.open = false;
    // …调用方自己的清理（关菜单 / 停试听 / 丢草案）…
    return true;
}
```

- 不可缩放的窗口：`grip_id` 传 0，`resize_*` 传四个栈上占位；
- 拖动中要“当场钳制”的窗口（合成器/效果器/波形/参数表）在外壳调用后补两行
  `std.math.clamp`（原实现写在拖动分支里，语义等价）；
- 帧首 `util.clampWindow`（尺寸/位置夹回屏幕）由调用方自己做。

## 测试清单（迁移或改动后必跑）

1. `zig build test` 全绿（含 `app: menuIsOpen——每种菜单都必须计入`）；
2. 手测冒烟：每个窗口标题拖动跟手、松手不回退；缩放柄拖动改尺寸、松手保持；
   关闭按钮一次点中；菜单条目点击即关、点外部即关、开启帧点击不误触；
3. 标题栏内嵌按钮（合成器/鼓组/效果器的 预设/保存为/自动化）：**按住拖动不启动
   窗口拖动**（保留区语义）；窄窗时按钮自动隐藏不重叠；
4. 左键打开的菜单（VST 参数行）：打开帧不秒选第一项；
5. 播放中开自动化窗口 → 插件自己的 GUI 仍可交互（外壳不登记遮挡表的不变量）。
