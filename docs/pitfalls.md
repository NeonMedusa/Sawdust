# Sawdust 开发踩坑记录

> 面向 AI/开发者：这些都是**真实踩过**的坑（有的一次就中，有的反复中）。
> 改代码前扫一眼，能省几轮调试。

## Zig 0.16 的 API 变更

### `build.zig`：编译选项挂在 **Module** 上，不在 `Compile` 上

```zig
// ✗ Zig 0.16 里不存在（会报 no field or member function named 'addIncludePath'）
exe.addIncludePath(...);
exe.linkSystemLibrary("user32");
exe.linkLibC();

// ✓ 正确写法
exe.root_module.addIncludePath(b.path("libs/stb"));
exe.root_module.addCSourceFile(.{ .file = ..., .flags = &.{"-std=c99"} });
exe.root_module.linkSystemLibrary("user32", .{});
exe.root_module.link_libc = true;   // 注意是字段赋值，不是函数调用
```

### `build.zig.zon`：新建包必须用 Zig 给出的 fingerprint

```
error: invalid fingerprint: 0x1a2b3c4d5e6f7a8b; if this is a new or forked package,
use this value: 0xb20f998bcb46ed2a
```
直接抄报错里给的值。

### `std.mem.trimRight` 不存在 → 用 `trimEnd`

（`trimLeft` 同理应为 `trimStart`）

## Win32 互操作

### `CreateDIBSection` 的内存**不能用 allocator.free**

```zig
// ✗ 段错误（非法释放）
self.allocator.free(self.fb.pixels);

// ✓ 那块内存属于 GDI，由 DeleteObject(hbitmap) 释放
_ = DeleteObject(@ptrCast(hbitmap));
```
**症状**：程序退出时 `Segmentation fault at address 0x...`（exit code 3）。

### `init` 不要"按值返回 + 内部取址"

```zig
// ✗ 危险：WndProc 里存的 &self 在返回值拷贝后悬垂 → 段错误
pub fn init(...) !WindowsWindow {
    var self = WindowsWindow{...};
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intFromPtr(&self));  // ← 悬垂
    return self;
}
var win = try Window.init(...);

// ✓ out-param 风格（地址稳定）
pub fn init(self: *WindowsWindow, ...) !void {
    self.* = WindowsWindow{...};
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intFromPtr(self));
}
var win: Window = undefined;
try win.init(...);
```

### 消息参数（`lparam`/`wparam`）需要显式窄化

`lparam: isize` 里打包的鼠标坐标（低/高 16 位）**必须显式转换**，否则编译报
`signed 64-bit int cannot represent all possible signed 64-bit values`：

```zig
fn lowWordSigned(v: u32) i32 {
    const w: u16 = @truncate(v);
    return @as(i16, @bitCast(w));
}
const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
```

### 窗口标题含中文要转 UTF-16

`CreateWindowExW` 接收宽字符，用 `std.unicode.utf8ToUtf16Le` 转换后传指针。

### 系统光标常量（`IDC_*`）是**奇数地址**，不能当 `[*:0]const u16`

```zig
// ✗ 编译报错：pointer type '[*:0]const u16' requires aligned address
const IDC_SIZENS: [*:0]const u16 = @ptrFromInt(32645); // 奇数！
LoadCursorW(null, IDC_SIZENS);

// ✓ 用 ?*anyopaque（对齐 1），LoadCursorW 的参数也改成 ?*anyopaque
const IDC_SIZENS: ?*anyopaque = @ptrFromInt(32645);
```

### 鼠标“冻结”拖动（拖推子但光标不动）：`SetCursorPos` 拉回 + 死区

改行高/缩放的推子要求**光标原地不动**（不跟随移动）：

```zig
// 每收到 WM_MOUSEMOVE（且已捕获）：
// 1) 超出死区才累积位移（否则 SetCursorPos 触发的回调会无限循环）
// 2) 拉回锚点：SetCursorPos(anchor_screen)
if (dx > mouse_deadzone or dx < -mouse_deadzone or ...) {
    s.frozen_dy += dy;
    _ = SetCursorPos(s.anchor_screen.x, s.anchor_screen.y);
}
```
- 必须配 `SetCapture`（否则快速拖出窗口丢事件、冻结失效）；
- 隐藏光标：`CreateCursor` 造 1×1 全透明 AND 掩码（`0xFF`）+ `SetCursor`；
- **`WM_SETCURSOR` 必须重设光标句柄**（返回 1），否则系统在移动时改回类默认箭头。

## 立即式 UI

### `Ui` 上下文必须**跨帧复用**（否则控件"没反应"）
```zig
// ✗ 每帧新建 → active_id / drag_anchor 归零 → 推子"拉不动"
while (...) {
    var ui = Ui.init(...);
}

// ✓ 循环外创建，每帧只更新变化的部分
var ui = Ui.init(...);
while (...) {
    ui.renderer = Renderer.init(&win.fb);   // 帧缓冲可能因 resize 变化
    ui.mouse_x = ...; ui.mouse_down = ...;
    ui.beginFrame(); drawApp(&ui, ...); ui.endFrame();
}
```

### 输入状态也要跨帧保持（鼠标不动时**没有事件**）

```zig
// ✗ 每帧重置 → 鼠标静止时坐标归零 → hover 失效、拖动中断
while (...) {
    var input = InputState{};
    for (events) |ev| { ... }
}

// ✓ 循环外保持；每帧只清"瞬时"标记（pressed/released/wheel）
var input = InputState{};
while (...) {
    input.mouse_pressed = false;
    input.mouse_released = false;
    input.wheel = 0;
    for (events) |ev| { ... }
}
```

### 绘制顺序 = 层叠顺序（覆盖层必须画在被覆盖内容之后）

立即式 UI 里没有 z-order，**后画的盖先画的**。同类 bug 已出现三次：

1. 片段底边描边被行分隔线盖住（`hline` 排在片段之后绘制）；
2. 浮动窗口“点击穿透”（输入分层同理——底层面板先绘制先响应）；
3. 播放游标的竖线被轨道行背景盖住（游标画在轨道行**之前**）。

```zig
// ✗ 游标先画 → 后面的轨道行 fillRect 把竖线盖掉
util.drawCursor(...);
for (轨道行) |row| renderer.fillRect(row_bg);

// ✓ 内容先画、覆盖层最后（游标/描边/浮动 UI 都是“覆盖层”）
for (轨道行) |row| renderer.fillRect(row_bg);
util.drawCursor(...);
```
**教训**：写绘制代码时先问“谁在上面”；覆盖层（游标/选中描边/弹窗/浮动窗口）
统一放到函数**末尾**绘制。调试“某条线/某个元素看不见”先查绘制顺序。

**同类变体：描边会把窄元素“吞掉”**——`strokeRect` 的左右边在 `w <= 2` 时重合，
会完全覆盖填充（宽缩到 1px 的音符被灰色描边包成灰线，与网格难以区分）。
规则：**`w <= 2`（或 `h <= 3`）时不描边**，只留填充色。

## C 库集成

### stb_truetype / miniaudio 的 IMPLEMENTATION 宏只能在一个 `.c` 里定义

```c
/* libs/stb/stb_impl.c */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/* libs/miniaudio/miniaudio_impl.c */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
```
Zig 侧用 `@cImport({ @cInclude("..."); })`，并在 `build.zig` 里
`addIncludePath` + `addCSourceFile`。

### 测试不要用"假指针"绕过依赖

```zig
// ✗ 会段错误：button() 内部会调用 font.measure() 读字体数据
const fake_font: *Font = @ptrFromInt(@alignOf(Font));

// ✓ 要么构造真字体（需 TTF 文件），要么只测不依赖该组件的路径
```
**教训**：拖动逻辑的单测不需要字体（`slider` 不读 font），**别为了"能编译"塞假指针**。

## UI 逻辑与交互

### 帧内“先读后写”：每步缩放都会跳一帧（□ 缩放跳变事故）

```zig
// ✗ drawPlaylist 旧顺序：函数开头捕获 track_h，但缩放块在中间修改它，
//   随后 scroll 已按新行高重算 → 绘制用「旧行高 + 新滚动偏移」
const track_h = app.track_h;          // 读（旧值 44）
ui.zoomSquare(..., &app.track_h);      // 写（→ 43）
app.playlist_scroll = 锚定重算(...);    // 写（新偏移）
// 绘制：track_h=44 + 新偏移 → 每步缩放跳一帧（约 16px）→ 肉眼“上下跳变”

// ✓ 所有读取都在写入之后（捕获局部量放在更新块之后）
const track_h = app.track_h; // 此刻已是本帧最终值
```
**教训**：同一帧内对同一可变状态的**所有读取必须发生在所有写入之后**。
遇到“偶发跳一帧”类闪动，先查“谁在本帧改了这个值、谁又在它之前读了它”。
（同族：splitter“先更新 pos 再绘制”也是这条规则的正面用例。）

### 拖动换算必须用“按下时快照”（时间轴滚动条加速事故）

横向时间轴滚动条：拖动中滑块宽度会变（内容延长 → 滑块变短），
若每帧用“当前滑块宽”重算鼠标→数值映射，拖动会**越拖越快**：

```zig
// ✗ 每帧重算：travel 随拖动变小 → 同样鼠标位移对应越来越大的内容变化
const travel = w - thumbW(content_w.*, ...); // 越来越小
const ns = (desired - x) * max_scroll / travel;

// ✓ 按下时快照，全程用它换算（单调 1:1）
// 在 mouse_pressed 时存 drag_content0 / drag_view_cw0 / drag_start
const travel0s = w - thumbW(self.drag_content0, self.drag_view_cw0, w, min_w);
```
**教训**：任何“拖动改自身的控件”（滚动条、滑块长度会变的控件），
换算基准必须取自**拖动起点**；中途变动的量只能用于绘制，不能用于映射。

### 持久状态必须每帧“贴合真实内容”（行程膨胀事故）

时间轴 `content_w` 是持久值：拖动延长过就一直记着（上限一度高达 756 小节），
后来内容右缘缩回也不会自动收回 → 滑块行程与内容脱钩（"50 小节在滑块半路就过去了"）。

```zig
// ✗ 只设下限：陈旧膨胀永远收不回
if (content_w.* < lo) content_w.* = lo;

// ✓ 每帧双向钳制到 [内容右缘+最小余量, 内容右缘+最大余量]
if (content_w.* < lo) content_w.* = lo;
if (content_w.* > hi) content_w.* = hi;
```
**教训**：凡是“用户可拖大、又应该随内容变化收回”的持久量，
每帧必须按**真实内容重新定界**（而不是只在变小时手动修正）。
同族：滚动位置也必须跟着钳制，否则会滞留在内容之外。

### 快速连点只响一下：`WM_LBUTTONDBLCLK` 吞掉了第二次 `WM_LBUTTONDOWN`

**Windows 行为**：双击时间窗（系统设置，默认 ~500ms）内的第二次按下，
系统**不发** `WM_LBUTTONDOWN`，只发 `WM_LBUTTONDBLCLK`。

```zig
// ✗ 只发双击事件：快速连点的第二下“没有按下” → 琴键不发声
WM_LBUTTONDBLCLK => s.pushEvent(.{ .mouse_double = ... });

// ✓ 双击 = 第二次按下，同时发一条 mouse_down（否则任何“每下都要响应”的交互被吞）
WM_LBUTTONDBLCLK => {
    s.pushEvent(.{ .mouse_down = .{ ..., .button = .left } });
    s.pushEvent(.{ .mouse_double = ... });
},
```
**副作用核对**：双击帧会同时带 `mouse_pressed` + `mouse_double`，
各处双击处理需 early-return（如播放列表片段双击 → openPiano 后 return），
否则单击逻辑会跟着执行（同位置重复操作多为幂等/被重叠检测拦住，但不要依赖运气）。

### 拖动/按住类交互必须用 `mouse_pressed`（否则拖窗口会误触划过的东西）

琴键试听/按钮类“点击”只看 `mouse_pressed`；若用 `mouse_down` 判断：
拖动其它窗口（机架/合成器）时，鼠标滑过琴键就会不断满足条件 → 误发声。

```zig
// ✗ 每帧都成立 → 拖动窗口划过的琴键全被“按响”
if (in_keys and ui.mouse_down) { ... }

// ✓ 只响应按下的那一帧；且需处理“按住滑奏”（active_id 标记本控件）
if (in_keys and ui.mouse_pressed and !over_other_drag) { ui.active_id = 6000; ... }
else if (ui.active_id == 6000) { /* 滑动换音 / 松开释音 */ }
```
**同族**：推子（slider/knob）的正确写法——`hovered and mouse_pressed` 进入拖动、
之后用 `active_id` 延续；与本次修琴键试听是同一模式。

### 菜单开关：打开它的那次点击不能被自己的“点外部关闭”吃掉

```zig
// 帧内次序：先按钮后菜单（菜单在按钮下方）
if (hovered and ui.mouse_pressed) open.* = !open.*;  // ① 点击按钮 → 打开
// ...同帧稍后...
if (ui.mouse_pressed and !inRect(mouse, 菜单区)) open.* = false;  // ② 鼠标在按钮上 → 立即关闭
```
**表现**：菜单展开后**闪一下消失**（只存活一帧）。
**修法**：把“本帧是否点了按钮”传给菜单，那一帧**跳过外部关闭判断**：
`if (!skip_close and ui.mouse_pressed and !inRect(...)) open.* = false;`

### 浮动窗口的“点击穿透”：输入分层必须在帧首决定

立即式 UI 里**绘制顺序 = 事件处理顺序**：底层面板先绘制、先响应。
如果在画完底层之后才设 `input_blocked`，底层已经吃掉本帧点击了 → 点击穿透。

```zig
// ✗ 画完所有面板、最后才画浮动窗口并设屏蔽 → 太晚
// ✓ drawApp 开头（任何控件绘制之前）就定好谁接收点击：
const menu_open = ...;
ui.input_blocked = rack_open and (menu_open or 鼠标在机架矩形内);
drawToolbar(...);   // 此时已被正确屏蔽
drawPlaylist(...);
// 最后画浮动窗口：取消屏蔽（它自己用 inRect 直接坐标命中）
```
**教训**：分层 UI 要分两件事——**视觉绘制顺序**（后画的在上）和
**输入归属**（帧首决定，与绘制顺序解耦）。模态（菜单展开）要全屏屏蔽。

**同类变体**（后续踩到，归入本条）：

1. **屏蔽不能包在别的条件里**（乐器菜单属于钢琴卷帘，但屏蔽包在 `if (rack_open)` 里
   → 机架关闭时菜单点击穿透到琴键）。：屏蔽逻辑的作用域要覆盖**所有使用场景**。
2. **`inRect`（直接坐标）不受 `input_blocked` 影响**：菜单项/浮动窗口用它的控件
   必须**显式判断上层覆盖**（否则上层窗口盖住它时仍会响应）。
   惯例：浮动窗口用 `hitUI`（受屏蔽）；只有“模态菜单项”用 `inRect` + 显式 `covered` 判断。
3. **窗口内部不要无条件重置 `input_blocked`**：浮动窗口绘制时若 `ui.input_blocked = false`，
   会抹掉外层设的“被上层覆盖”屏蔽（应在“菜单展开”时才重置）。

**后续：改用层系统解决（见 `ui.zig` 的 `declare`/`beginLayer`）**——
把“优先级 + 矩形”声明式化，输入屏蔽与绘制裁剪自动处理，不再手写组合逻辑。
注意其**自身副作用**：层矩形外的绘制会被裁掉——窗口阴影、跟随鼠标弹出的
菜单等“故意超界”的绘制要用 `beginLayerNoClip`（或把层矩形声明得足够大）。

### 缩放锚定：屏幕像素与内容像素的换算要区分

横向缩放（Ctrl+滚轮）锚定鼠标下的内容：鼠标处的内容坐标缩放前后必须相同。

```zig
// 错：把“鼠标屏幕偏移”当成“内容偏移”
const cx = scroll + mouse_off;             // ✗ mouse_off 是屏幕像素

// 对：屏幕偏移 ÷ zoom = 内容偏移
const cx = scroll + mouse_off / old_zoom;  // 锚点（内容坐标）
const ns = cx - mouse_off / new_zoom;      // 缩放后鼠标处仍对同一内容
```
**教训**：只要有 zoom 概念，“屏幕像素”与“内容像素”就不能混算；
锚定类逻辑（中心/鼠标）都先换算到内容坐标，算完再换算回去。

### “回收”的时机错了会变成“回弹”（时间轴行程事故）

上一版给行程加了一个“上限 = 内容右缘 + 一屏”的每帧钳制，
想防止膨胀。结果：**拖动中允许超出上限，松手那一帧立刻被钳回** → 用户看到“拖出去、松手弹回来”。

```zig
// ✗ 每帧钳制上限：拖动中超出 → 松手立即回弹
content_w.* = clamp(content_w.*, lo, content_right + one_screen);

// ✓ 拖动中不设上限（只受几何极限限制）；
//    松手后保留；回到左端（scroll == 0 且不在拖动中）才回收
if (self.active_id != id and scroll.* == 0) content_w.* = lo;
```
**教训**：区分“拖动意图”（用户主动拉出来的空间必须保留）和“空闲整理”
（不再需要时才收回）。回收条件要写得**保守**（如“回到原点”），
否则用户会看到自己刚拉出来的东西被系统吃掉。

### “被修改的值” ≠ “控件位置”（第 2 个分隔条偏左事故）

```zig
// ✗ 曾经把 pos 当 x 用：splitter2 的 pos 指向 mid_w，但它的屏幕 x 是
//   left_w + splitter_w + mid_w —— 画到了 x=mid_w 处（严重偏左）
ui.splitterV(2, &app.layout.mid_w, app.layout.mid_w, ...);

// ✓ x（绘制/命中位置）与 pos（被拖动的值）分开传
const sp2_x = app.layout.left_w + splitter_w + app.layout.mid_w;
ui.splitterV(2, &app.layout.mid_w, sp2_x, ...);
```
**教训**：重构删参数时，先问“这个值和控件位置**恰好相等**是不是巧合”。
两个分隔条：第 1 个 `x == pos` 是巧合，第 2 个不是。

### 拉伸手感：量化“增量”而非“边缘位置”

拉伸边缘曾用“鼠标绝对位置 → 最近网格线”吸附，且“最短长度 = 一格”在按下当帧
就把短音符强行拉长——**1/32 音符（3 步）在 1/1 网格下，鼠标一动就顶到小节线**。

后来试过“边缘只吸鼠标已越过的格线”（相对吸附，见分支 experiment/edge-position-snap）：
方向对（真的要走满一格），但边缘与格线的相位不定、且边缘只能落在整格线上，
拉不出“原长 + k×格”（如 1/8 + 1/4 = 3/8 这类非格点长度）。

**采用：“网格 = 长度增减的步长”**（增量式，锚定按下时刻）：

```zig
// 按下时快照：drag_orig_len / drag_down_step（鼠标内容步）
// 每帧：长度 = 原长 + k×格，k = round(位移 / 格)（过半格即换一格、负数对称）
const delta = step_i - drag_down_step;
const new_len = model.trimLenByGrid(drag_orig_len, delta, snap_steps);
// 下限（最小格点）= “原长 − k×格仍 >= 1”的最小值：只剩不足一格时不能再减
const min_len = model.trimMinGridLen(drag_orig_len, snap_steps);
```
**教训**：
- 拖动换算必须用**按下时快照**（同“滚动条加速”条）：以当前值为基准会漂移；
- 量化分两类：“落点吸附”（放置/移动：吸最近格线）与“增量量化”（拉伸：
  以原值为锚、网格作**步长**）——后者手感稳定且允许非格点长度；
- 下限要写成“只剩不足一格不能再减”，而不是“最短 = 一格”（后者会把短音符拉长）。

### 按住期间每帧跳转 = 每帧重触发（标尺游标“响两下”事故）

症状：播放中单击标尺定位，音符快速响两下（按住更久则更多）。

三处标尺拖动都是“按住期间每帧调用 `jumpPlaybackCursor`”——
每帧跳转 = 每帧 `reset`（gen++）→ 音频线程每帧作废 stash + 全声部释音
+ 重新补发“跨位置”音符的 note-on → **每帧一个新音头**；
且每帧重置传输基准让游标视觉上“回弹”（“游标又往左移了一小格”）。

```zig
// ✗ 按住期间每帧跳（重置传输 + gen++ + 重触发）
if (ui.active_id == 7000 and ui.mouse_down) app.jumpPlaybackCursor(step);
// ✓ 去重：只有目标步变化（或按下那一帧 force）才真跳
pub fn jumpPlaybackCursorDrag(self: *App, step: i32, force: bool) void {
    if (!force and step == self.playback.ruler_drag_step) return;
    self.playback.ruler_drag_step = step;
    self.jumpPlaybackCursor(step);
}
```
**教训**：带副作用的“设置”操作在拖动路径上必须**按值去重**（同值重复调用
不能重复产生副作用）；重置传输/作废事件这类重操作尤其如此。

### `defer popClip` 挂到函数末尾 = 裁掉后续绘制

症状：样式列表底部的“＋ 添加样式”按钮看不见。

`defer` 是**函数级**作用域：在函数中部 `pushClip` + `defer popClip`，
裁剪区一直到**函数返回**才恢复——后面画的控件只要不在裁剪区内就全部被裁掉。
更阴的是：**`ui.hit()` 命中判定不检查裁剪区**——于是成了“看不见但可点击”的隐形按钮。

```zig
// ✗ defer 挂到函数末尾：按钮（在裁剪区外）被裁
const saved = ui.renderer.pushClip(x, list_y, w, list_h);
defer ui.renderer.popClip(saved);
...列表...
ui.button(2100, "＋ 添加样式", ..., btn_y, ...); // ← 画不出来

// ✓ 用作用域块：块结束即恢复裁剪（参照 view_rack.zig）
{
    const saved = ui.renderer.pushClip(x, list_y, w, list_h);
    defer ui.renderer.popClip(saved);
    ...列表...
}
...按钮（在块外，正常绘制）...
```

### 传输跳转必须释放已发声的声部（否则音符悬挂）

症状：游标扫到音符一半时拖走，该音符一直响到暂停/停止。

机制：note-off 早已被 lookahead 调度进音频线程的 stash；跳转时 gen 递增
把 stash 整批作废（**正确**——旧事件的时间戳相对新位置全错），
但**漏了释放已经起音的声部**——它永远收不到 off，停在 sustain。

```zig
// ✗ 只作废事件
if (gen != engine.stash_gen) { engine.stash_n = 0; engine.stash_gen = gen; }
// ✓ 播放中的 gen 变化（跳转）还要释放全部声部（进入 release）
fn handleGenChange(engine: *Engine, gen: u32, was_playing: bool) void {
    engine.stash_n = 0;
    engine.stash_gen = gen;
    if (was_playing) for (engine.synths) |*s| synth.allOff(s);
}
```
**教训**：
- “作废未来事件”与“释放已发声声部”是两件事——跳转/切模式/改 BPM
  这类传输变化两者都要做（暂停路径已有 transportEdge，别漏跳转）；
- 修复放在**音频线程内**（与事件触发同线程）——UI 推 all_off 与 gen 存储
  之间有窗口，音频线程可能先消费 all_off、再按新参数误触发旧 gen 事件，
  新声部的 off 随后被作废 → 又悬挂；
- 语义选“进入 release”（同暂停/停止）而非“播完剩余时值”：
  剩余时值的终点在旧时间线上，跳走后没有明确终点。

### 同音高重叠：合成器的 note-off 必须 FIFO

数据层改为**允许重叠**（与 MIDI 一致）后，合成器的 noteOff 若释放**所有**
同音高声部，重叠时第一个 note-off 会把后一个音也掉（实测断音）。

```zig
// ✗ 释放全部同音高声部（重叠时误杀）
for (state.voices) |*v| {
    if (v.pitch == pitch and ...) v.env_stage = .release;
}
// ✓ 只释放**最早分配**的（start_seq 最小）——MIDI 接收端的标准语义
//   note-off 匹配最早的未释放 note-on（FIFO）
```
**教训**：允许重叠 = 同一音高可同时存在多个声部，“哪个声部响应 off”
必须有明确规则（FIFO）；解析端配对、合成器释放端要用**同一条规则**。

### MIDI 解析：三个必须处理的细节

写 SMF 解析器时最易踩的三个坑（实际文件里全都常见）：

1. **running status**：事件可省略状态字节（沿用上一个）——不处理会解析崩溃；
2. **vel=0 的 note-on = note-off**（导出器省字节的常见写法）；
3. **tick → 步必须逐事件独立换算**（`tick × 24 / tpq`，就近取整）——
   若先算总长再累加，整除误差会累积漂移。

另外：**每个文件自带头块声明分辨率**（tpq，常见 96/192/384/480/960），
没有“统一值”——不能写死 480。SMPTE 时基（division 高位 1）先明确报错。

### 网格分层：覆盖式（细→粗），不能“跳过”

时间轴网格三层（网格/拍/小节）各自有密度门槛（太密就整层不画）。

```zig
// ✗ “网格线遇到拍/小节位置就跳过”——当拍线层因太密被隐藏时，
//   那些位置上的网格线也没人画 → **出现洞**（该有线的地方空白）
if (gridLevel(step_pos, ...) == .step) drawGridLine(...);

// ✓ 绘制顺序 = 细→粗（后画覆盖先画）：任一层隐藏都不留空缺，
//   重合处自然显示更粗的层
drawLayer(... snap_steps, 4.0, ...);   // 网格层
drawLayer(... beat_steps, 6.0, ...);   // 拍线
drawLayer(... steps_per_bar, 3.0, ...); // 小节线
```
**教训**：多个互斥/重叠的绘制层用“分层判断 + 跳过”很容易漏画；
“先画细、后画粗”的覆盖式天然无洞，且不需要层级判定函数。

### 网格分层的“单位”：内容像素 ≠ 屏幕像素

算“已滚过的步数”要用**内容**单位（`scroll_x / step_w`），
不能用屏幕单位（`scroll_x / (step_w × zoom)`）——后者滚动后网格会整体错位。
两个量维度不同时，先问“这个除法在哪个坐标系里”。

### 视觉层次：明暗差距要够大，不能靠线宽硬撑

网格三层曾把颜色挤在 54–62（宽度 8）区间，且**小节线比拍线还暗**——
三层看着糊成一片，只能靠 2px 线宽区分。改后：网格 48、拍线 76、小节 108
（相邻差 ≥ 28），即使全 1px 也一眼可辨。
**教训**：画多层同类元素时，**亮度梯度要拉开**（相邻差 ≥ 20-30），
不能假设用户能分辨 5-10 的亮度差。

### 时间轴滚动条：缩放下限要含“物理下限”（拖不动事故）

症状：拖主体向右延长行程（滑块被压缩、贴右端）后，拖滑块**左缘**往左
（想扩宽视野）拖不动。

机制：拖边缘的 zoom 下限是 `min(zoom_min, zoom.*)`，而 `zoom_min` 锚在
`timeline_w` 上。当**时间轴短于视口**时 `zoom_min > 1`，而初始 `zoom = 1.0`
本来就低于它 → 下限 = zoom → 想继续缩（扩宽视野）被钳死。
拖出的延长又让 `content_w > timeline_w`——此时真正的下限是
“装下全部内容”（物理下限），比 zoom_min 更宽松。

```zig
// ✗ 下限 = min(zoom_min, zoom.*)——zoom_min 锚在 timeline_w 上，拖出延长后钳死
const new_zoom = clamp(vw / new_view_cw, @min(zoom_min, zoom.*), zoom_max);
// ✓ 加物理下限：view_w / content_w（视野最多扩到装下全部内容 = 滑块满宽）
const zoom_floor = @min(zoom.*, @min(zoom_min, view_w / content_w));
```
**教训**：多个“下限”取**最松的那个**（min）——物理约束（装下全部内容）
永远是真极限；参数约束（zoom_min）若比物理约束更严，说明它漏了场景
（这里漏了“拖出的延长”）。

### 框选与放置/拖动共用 mouse_pressed：当帧双触发

Ctrl+拖框选与“左键按下放置”都看 `ui.mouse_pressed`——框选启动当帧
`note_hit`/`clip_hit` 为 null（框选优先）→ 会先走“空位放置”分支，
多放一个音符/片段。

```zig
// ✗ 框选启动帧也会放置
if (ui.mouse_pressed and in_lane) { ...放置... }
// ✓ 修饰键参与判定（框选手势时禁用放置/拖动）
if (ui.mouse_pressed and in_lane and !ui.mods_ctrl) { ...放置... }
```
**教训**：同一输入事件（mouse_pressed）被多个手势共用时，必须用
**修饰键/优先级**把互斥手势分开——否则当帧会双触发。

### 批量操作：快照要“全量重建”，位移要从快照重算

批量拖动/拉伸选中音符时：
- **快照顺序必须与迭代顺序一致**（都是数组顺序，跳过未选中）；
- **每帧从快照重算**（`新值 = 快照值 + 位移`）而不是累加当前值——
  累加在钳制（如 step >= 0）时会漂移（往回拖回不到原位）；
- **快照重入**：`beginBatchSnap` 必须在**每次按下**时重建
  （否则上一轮的快照污染新手势）。

**教训**：任何“拖动期间每帧更新”的批量变换，都要用“按下时快照 + 相对
位移”的幂等模型（与单音符增量式拉伸同一原则）。

### 数组 append 期间不能迭代原数组（悬空指针）

`cloneSelectedNotesRight` 需要“遍历选中音符 + 向同一数组 append 克隆体”——
直接迭代原数组时 append 可能 realloc → 迭代中的 slice 悬空（读已释放内存）。

```zig
// ✗ 边迭代边 append（realloc → 迭代 slice 悬空）
for (self.notes.items) |nt| { ... self.notes.append(copy) ... }
// ✓ 先收集到临时表，再 append
var to_clone = ArrayList(...);
for (self.notes.items) |nt| { if (nt.selected) try to_clone.append(nt); }
for (to_clone.items) |nt| { try self.notes.append(copy); }
```

### 快照模型里“无变化就早退”会卡住状态

批量拉伸（快照 + 绝对格数 k：`长度 = 快照长 + k×格`）里曾写：

```zig
if (applied == 0) return 0; // ✗ k 从非零变回 0 时不写回 → 卡在上一次的长度
```

实测症状：1/4 网格下拉长两个四分音符到二分音符（k=+1）后，往回拖经过 k=0
**音符不变**（卡在二分音符），再往左拖 k=-1 因“全组不能缩”仍不写回——
**永久卡死**；而且观感上“鼠标超过一格不变、快两格时突然 +2”（值滞后一拍）。

**教训**：快照模型的写回是“状态 = 快照 + 位移”，**k = 0 也是一次有效写回**
（= 还原快照）。“无变化就早退”在这种模型里是错的——它把“无变化”与
“不需要写回”混为一谈。想省一次循环可以比较后写（本实现改成逐项 `!=` 比较），
但**不能跳过写回本身**。

### 批量移动的钳制必须“组级”，不能逐音符钳制

症状：斜排的四个音符（step 3/2/1/0）整体左拖撞左墙 → 被“压扁”成一列
（全部 step 0），而不是保持相对间距停在原地。

```zig
// ✗ 逐音符钳制：各自 @max(0, ...) → 左边的一个个被压到 0
const ns = @max(0, snap.step + d_step);
// ✓ 组级钳制：先算组内最小 step → 全组统一的位移下限（保持相对间距）
const d_step_c = @max(d_step, -min_step); // 最左碰到 0 → 全组停
const ns = snap.step + d_step_c;
```

音高/轨道同理（`clamp(d, -min, max_bound - max)`）。
**教训**：多对象整体变换的约束应作用于**整体**（保持相对关系）——
逐个钳制会把“整体平移”退化成“挤压”。判断准则：变换后**相对间距
是否保持**。

### 快照式撤销：拖动类操作必须 coalesce，且恢复时清拖动状态

实现撤销/重做时，**拖动类操作每帧都在改数据**（拖动/拉伸/擦除）。若每帧提交
历史 → 一次拖动产生几十条历史（无法使用）；若只在鼠标按下时提交 → 提交的
是拖动**前**的状态（丢最终结果）。

```zig
// ✓ 按下时记“待提交名”，帧末鼠标松开才真正提交（coalesce）
app.history_pending = "移动音符";       // 按下帧
if (app.history_pending) |label| {      // 帧末（主循环）
    if (!ui_input.mouse_down) { app.commitHistory(label); app.history_pending = null; }
}
```

另两个必备细节：
- **恢复快照时必须清拖动状态**（drag_note/drag_clip/batch_* 等）——撤销后
  数据已换，旧拖动下标会指向错误内容（可能越界）；
- **选区不参与历史等价判定**——否则点选/框选会刷屏产生历史条目。

**教训**：快照式撤销的三个坑：拖动 coalesce、恢复时清瞬态、等价判定忽略瞬态。

## 音频

### 实时回调的约束

`dataCallback` 运行在**实时线程**：
- ✗ 不能分配内存、不能加锁、不能阻塞；
- ✓ 参数用 `std.atomic.Value` 传递；状态（播放位置）用原子变量回传。

### miniaudio 的日志噪音

Windows 上会打印大量 `SarMMDeviceEnumerator` / `mmwrapper.cpp` 日志——
**这是音频驱动（不是 miniaudio）的输出**，属正常现象。
