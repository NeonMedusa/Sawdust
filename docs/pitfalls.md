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

## 音频

### 实时回调的约束

`dataCallback` 运行在**实时线程**：
- ✗ 不能分配内存、不能加锁、不能阻塞；
- ✓ 参数用 `std.atomic.Value` 传递；状态（播放位置）用原子变量回传。

### miniaudio 的日志噪音

Windows 上会打印大量 `SarMMDeviceEnumerator` / `mmwrapper.cpp` 日志——
**这是音频驱动（不是 miniaudio）的输出**，属正常现象。
