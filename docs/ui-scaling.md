# UI 缩放（DPI 感知）

**问题**：早期 UI 全部按 1080p 设备像素硬编码（`toolbar_h=40`、`status_h=26`、
`piano_step_w=5`、`track_h=44`、菜单行高 20、字体 16px…）。
Windows 后端虽然声明了 **per-monitor DPI aware V2**，但布局不缩放，
于是在 4K / 高缩放屏幕上一切都只有 1/2~1/3 的物理尺寸
（实测反馈：“一打开就看到 40+ 轨道，所有 UI 极小”）。

**方案（单点乘算）**：布局代码**一行不改**，全部继续按**逻辑像素（96 DPI 当量）**工作；
只在一个地方把逻辑像素换成物理像素 —— 渲染器。

## 1. 缩放因子：`App.ui_scale`（设置 + 自动检测）

**唯一的用户入口是设置页**（`设置 → 界面缩放`）；环境变量 `SAWDUST_UI_SCALE` **已删除**——
“配环境变量”和“改配置文件”学习成本一样，而两条路只会制造“我改了为什么没生效”的困惑。

`settings.json` 两个字段：

| 字段 | 含义 |
|---|---|
| `ui_scale_auto` | true = 每次启动**自动检测**（且桌面改缩放时实时跟随）；false = 用 `ui_scale` |
| `ui_scale` | 固定倍率（自动期间也保留，取消自动就回到它） |

界面：`[✓] 自动` + 下面一行“检测到 150%（XSETTINGS：Gdk/WindowScalingFactor = 2）”
+ **5% 步进的滑块**（75% – 400%，65 格）。手拖滑块 = 自动取消，并进入 15 s 确认窗口。

### 1.1 自动检测的阶梯（`src/dpi.zig`，纯函数好测）

顺序抄 SDL3 的 `X11_GetGlobalContentScale` + ArchWiki HiDPI 的实践，**命中即返回**：

| # | 来源 | 备注 |
|---|---|---|
| 1 | Windows `GetDpiForWindow()/96` | per-monitor |
| 2 | XSETTINGS `Gdk/WindowScalingFactor` | 整数，1 = 100%（GNOME/Xfce 的协议级值） |
| 3 | XSETTINGS `Xft/DPI` | 单位 **1/1024 dpi** |
| 4 | `Xft.dpi`（root `RESOURCE_MANAGER`） | **实时读属性**：`XResourceManagerString()` 是连接级缓存，桌面改缩放不更新 |
| 5 | `GDK_SCALE` / `QT_SCALE_FACTOR` / `QT_SCREEN_SCALE_FACTORS` | 用户显式设的才认；每屏列表取第一个 |
| 6 | 屏幕 ppi 估算（`DisplayWidth / DisplayWidthMM`） | **只当建议**：ppi ≥ 130 且上面全没命中才自动用，且 clamp ≤ 200% |
| 7 | 1.0 | — |

两条铁律：

- **绝不相乘**：`Xft.dpi` + `GDK_SCALE` 同时存在时相乘会把界面放大成两倍（ArchWiki 明确警告）；
- **物理 ppi 不是用户意愿**：4K 27" 在 100% 下 ppi≈163，一概自动套 150% 会违背用户设置，
  所以它排在最后且只在“什么信号都没有”时生效。

XSETTINGS 客户端是自己实现的（`window_x11.zig`：`_XSETTINGS_S0` 属主窗口 →
`_XSETTINGS_SETTINGS` 属性 → 按 header 字节序解码 INT/STRING/COLOR）。
Wayland 原生不在本轮（我们只有 X11 后端）；XWayland 下第 4/6 步常常拿不到真值，
设置页会显示“未检测到缩放设置”，用户手拖滑块即可。

### 1.2 立即生效 + 15 s 后悔窗口

以前“改缩放需重启”。现在改成**立即生效**：

- `ui.renderer.scale` 每帧从 `app.ui_scale` 取；
- **唯一要重建的是字形图集**（位图按 `16 × scale` 光栅化，见 §3）——`App.font_dirty` 置位，
  主循环在帧首 `loadFont(scale, font_path)` 后换掉 `ui.font`（几十 ms，一次卡顿）；
- 布局全部是即时模式、无缓存 → 其余零成本；VST3 子窗口位置每帧按 scale 重算，也不受影响。

缩错了可能把设置页推出屏幕，所以有**确认条**（顶部居中，宽度 clamp 到 `逻辑宽-20`）：
`[保持] [恢复]`，15 秒内不确认就**自动回到原倍率**（只在点“保持”时写盘）；
`Enter`/`Space` = 保持，`Esc` = 恢复。

### 1.3 桌面改缩放时实时跟随（仅“自动”模式）

窗口后端监听 root 的 `RESOURCE_MANAGER` 与 XSETTINGS 的 `_XSETTINGS_SETTINGS`
（`XSelectInput(root, PropertyChangeMask)` + 属主窗口同样订阅），一变化就置 `dpi_dirty`；
主循环看到标记 → 重跑阶梯 → 值真的变了就 `applyUiScale(new, confirm=false)`
（外部意图，不弹确认条）。

### 1.4 窗口尺寸

初始窗口按**逻辑 1280×760** 换算成物理尺寸，且不会开出屏幕
（`setClientSizeLogical` 里按屏幕宽高夹取）。改缩放时**窗口物理尺寸不变**（逻辑区变多/变少，
布局自然重排），所以不会出现“窗口被推到屏幕外”。

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

## 6. 仍然不做

- **不改** `model.min_track_span`（幽灵行轴上限）：行数是视口逻辑高度 / `track_h`，
  缩放后 1080p 与 4K 看到的行数一致，本来就不该按物理像素算。
- **不做按物理 ppi 自动缩放**：Windows 与 X11 的程序都只认“系统缩放百分比”
  （`WM_DPICHANGED` / XSETTINGS 报的是缩放，不是 ppi）。4K@100% 天生很小是系统行为，
  要变大就在系统里调缩放——我们不越俎代庵去推翻用户的明确设置。

## 7. 自测清单

1. **设置页滑块**：拖到 150% → 点“应用”→ 界面立即变大 + 顶部弹确认条；不点“保持” 15 s 后回滚。
2. **自动模式**：Windows 系统缩放调到 150% / 200%（程序开着）→ 窗口一帧内跟随（不弹确认条）
   ——  走的是 `WM_DPICHANGED`；把窗口拖到另一块不同缩放的屏幕同理。
3. **Linux**：`Xft.dpi = 144` 或 XSETTINGS 里改 `Gdk/WindowScalingFactor`（程序开着）→ 实时跟随；
   无任何缩放信号的桌面，设置页应显示“未检测到缩放设置”。
4. 检查点：工具栏按钮可点、文本输入框光标/选区位置正确、拖动数值控件手感一致、
   插件面板里的子窗口与 chrome 对齐、浮动窗口拖拽不飘、**字形不发糊**（位图按新缩放重光渡）。
5. 极端：400% 下设置页 / 帮助页仍能缩进屏幕，底栏按钮与内容可滚动。
