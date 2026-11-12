# UI 缩放（DPI 感知）

**问题**：早期 UI 全部按 1080p 设备像素硬编码（`toolbar_h=40`、`status_h=26`、
`piano_step_w=5`、`track_h=44`、菜单行高 20、字体 16px…）。
Windows 后端虽然声明了 **per-monitor DPI aware V2**，但布局不缩放，
于是在 4K / 高缩放屏幕上一切都只有 1/2~1/3 的物理尺寸
（实测反馈：“一打开就看到 40+ 轨道，所有 UI 极小”）。

**方案（单点乘算）**：布局代码**一行不改**，全部继续按**逻辑像素（96 DPI 当量）**工作；
只在一个地方把逻辑像素换成物理像素 —— 渲染器。

## 1. 缩放因子 `ui.scale`

| 平台 | 来源 | 兜底 |
|---|---|---|
| Windows | `GetDpiForWindow(hwnd) / 96`（per-monitor，随窗口所在显示器） | 1.0 |
| Linux（X11） | ① `Xft.dpi` 资源（`XResourceManagerString` + `XrmGetStringDatabase`）；② `DisplayWidth(px) / DisplayWidthMM` 估算 | 1.0 |
| 任意 | 环境变量 **`SAWDUST_UI_SCALE=1.5`** 强制覆盖（WSLg / 无 DPI 环境 / 自查用） | — |

- 取值 **clamp 到 1.0~3.0**（环境变量允许 0.75~4.0，便于"想小一点"的人）。
- 启动时采样一次（改了要重开程序：缩放变了意味着整个帧缓冲与字形缓存都要重建，
  首版不值得为此做热切换）。
- 初始窗口按**逻辑 1280×760** 换算成物理尺寸，且不会开出屏幕
  （`setClientSizeLogical` 里按屏幕宽高夹取）。

## 2. 渲染器是唯一的换算点（`src/render.zig`）

`Renderer.scale: f32`，所有图元入参都是**逻辑像素**：

- `fillRect / strokeRect / hline / vline / line / plot` → 内部 `px(v) = round(v * scale)`
- `setClip / pushClip`（裁剪区同样是逻辑坐标）
- `blitAlphaMask`（图标）→ 位置乘 scale
- `logicalWidth() / logicalHeight()` → 物理 / scale（上层要窗口尺寸时用这两个）

细节：`fillRect` 的宽高按**两端点取整**（`px(x+w) - px(x)`），
这样相邻矩形在 125% / 150% 这类非整数缩放下才能真正贴合，不会露出 1px 缝。

**坑（实测踩过）**：`plot` 是**逻辑像素**入口（内部转 `plotPhys`），`line` 的 Bresenham
在物理空间里走、用 `plotPhys` 描点。旋钮的圆弧（`ui.drawArc`）曾直接用 `plot` 描点
→ 漏乘 scale，表现就是“**所有旋钮都错位**”（圆环跑到左上角、只剩中心点在对的位置）。
圆弧这类“自己算像素”的图元要按**物理半径**描点（否则 scale>1 时逐点间距成 2~3px，
弧线会变成虚线），且步数按物理弧长算。`ui_test.zig` 里有回归测试锁这条。

## 3. 字体（`src/font.zig`）

- 字形位图按 **`16 * scale`** 光栅化（`loadFontScaled`）→ 高分屏上是真清晰，
  不是"小字画完再放大"的糊图。
- 但对外的度量全部**除回逻辑像素**：`measure()` / `lineHeight()` / `ascentL()` /
  `descentL()`。所以排版代码（`ui.label`、按钮宽度、光标 x…）依旧按逻辑像素算。
- `Font.draw(x, y)` 接收逻辑坐标，内部乘 scale 得到物理笔位，再叠加字形自身的
  物理偏移，用 `blitAlphaMaskPhys`（不缩放的原始 blit）落地。

## 4. 输入（鼠标 / 拖放）

物理 → 逻辑的换算只做在**入口**：

- 主循环里 `ui.mouse_x = i2l(ui_input.mouse_x, scale)`（`ui_input` 保留物理值，
  文本输入框那几处命中测试自己换算）。
- 拖放落点 `win.dropPoint()` 同样是物理 → 换算后再进命中测试。
- 自适应缩放下"隐藏鼠标 + 冻结位移"的拖动量（`frozen_dy`）也换算成逻辑像素，
  这样手感与缩放无关。

## 5. VST3 插件界面（子窗口）

插件编辑器是**子窗口**，坐标必须是物理像素；面板 chrome 是自绘的逻辑像素。
`syncPluginEditors` 里做双向换算：面板逻辑尺寸 = 插件物理尺寸 / scale，
同步子窗口时再乘回去；`collectEditorCovers` 把逻辑的窗口/弹层矩形乘 scale 后再求交。

## 6. 明确不做

- **不改** `model.min_track_span`（幽灵行轴上限）：行数是视口逻辑高度 / `track_h`，
  缩放后 1080p 与 4K 看到的行数一致，本来就不该按物理像素算。
- 不做运行时热切换缩放（重开程序即可）。
- 不做每显示器动态跟随（窗口拖到另一块不同 DPI 的屏幕后需要重启——
  首版够用；要做的话在 `WM_DPICHANGED` 里重设 scale + 重建字体）。

## 7. 自测清单

1. Windows：系统缩放调到 150% / 200% → 工具栏、状态栏、轨道行高、菜单、字号
   的**物理尺寸**应与 100% 时一致，文字清晰不糊，鼠标点击位置准确。
2. `SAWDUST_UI_SCALE=2.0` 在 100% 环境启动 → 等同 200% 的效果（验证无 DPI 环境）。
3. Linux：`Xft.dpi` 设置正确时自动生效；`xrandr --dpi 192` 后重开程序应放大一倍。
4. 检查点：工具栏按钮可点、文本输入框光标/选区位置正确、拖动数值控件手感一致、
   插件面板里的子窗口与 chrome 对齐、浮动窗口拖拽不飘。
