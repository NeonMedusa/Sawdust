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

### `@max`/`@min` 会**窄化结果类型**；`@abs` 返回无符号

两个都属“看起来无害、编译报错莫名其妙”的类型陷阱：

```zig
const r_in: i32 = 7;
const r = @max(2, r_in);       // ✗ r 的类型是 u3（按操作数范围推导）
var dy: i32 = -r + 1;          // error: negation of type 'u31'
const r: i32 = @max(2, r_in);  // ✓ 显式标注目标类型

var dy: i32 = -3;
const a = @abs(dy);            // ✗ a 的类型是 u32
const a: i32 = @intCast(@abs(dy)); // ✓ 或先转再算
```
**教训**：`@max`/`@min`/`@abs` 的结果类型由**操作数范围**推导（不是
“与操作数同类型”）——与 `i32` 变量混算前一律显式标类型。

### `@intFromFloat` 是**向零截断**——负值四舍五入不能用 `+ 0.5`

```zig
// ✗ 只对非负数是四舍五入；负数向零截断：
//   -5.0 + 0.5 = -4.5 → 截成 -4（差 1）
const pw: i32 = @intFromFloat(v + 0.5);

// ✓ 用 @round（远离零取整）：-4.5 → -5
const pw: i32 = @intFromFloat(@round(v));
```

**实测症状**：某推子（-5..5）拉到 -5，松手后显示 **-4**——每帧从存储
重读，负值读回总是 +1；拖动中因位移持续写回 -5 而“看不出问题”。
**教训**：任何“f32 存值 → 每帧读回 `i32` 喂控件”的模式，取整必须用
`@round`（本项目已封装 `Ui.roundF`）——`+ 0.5` 的写法只适用于确定
非负的值域（0..100 的百分比等）。

## Win32 互操作

### `Sleep` 的精度陷阱：默认粒度 ≈ 15.6ms，会把帧率腰斩

症状：主循环写 `sleep(16ms)`（名义 60fps），实际**只有 ~35fps**，UI 不流畅、操作滞后。

根因：Windows 默认计时器粒度 ≈ 15.6ms——`Sleep(16)` 会被系统“向上取整”
到下一个节拍，实测睡成 **~26ms**（有时 31ms）。

```zig
// ✗ 依赖默认精度：sleep(8ms) 实测 ~15.6ms、sleep(16ms) 实测 ~26ms
std.Io.sleep(io, .fromMilliseconds(16), .awake) catch {};

// ✓ ① 提高系统计时器精度（init 一次；deinit 配对恢复）
_ = timeBeginPeriod(1);   // winmm；实测 sleep(8.33ms) → 8.9ms
// ✓ ② 帧预算：睡“帧开始 + 预算 - 已耗时”，而非固定尾部睡眠
const frame_budget_ns: i64 = 8_333_333; // 120fps
while (true) {
    const t0 = nowNs();
    defer {
        const remain = frame_budget_ns - (nowNs() - t0);
        if (remain > 0) std.Io.sleep(io, .fromNanoseconds(remain), .awake) catch {};
    }
    // ... 本帧工作 ...
}
```

**为什么不能只用固定尾部睡眠**：帧时长 = 渲染耗时 + 睡眠时长（两者叠加）——
渲染变重（大工程、多浮动窗口）时帧率随内容浮动；帧预算则是“睡剩余部分”，
总帧时长恒定（渲染耗时被扣掉）。

**实测数据**（本机，Debug 构建）：
| 写法 | 平均帧时长 | 有效帧率 |
|---|---|---|
| 尾部 `sleep(16ms)`（修复前） | 28239us | **35.4 fps** |
| `timeBeginPeriod(1)` + 帧预算 8.33ms | 8785us | **113.8 fps** |

**连带坑：按帧计数的时长逻辑**。帧率可变后，“N 帧 ≈ M 秒”的换算全错
（如 toast 180 帧：60fps ≈ 3s → 120fps 变 1.5s）。修法：改用**时间**（纳秒），
每帧传实际流逝时间递减：`tickToast(dt_ns)`。

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

### 中文输入法（IME）：Unicode 窗口下**只需处理 WM_CHAR**

自绘文本输入（重命名等）接中文输入的最简方案：

- **不要**处理 `WM_IME_COMPOSITION`/`GCS_RESULTSTR`——那是 IME-aware
  （自己渲染组合窗）的路线；普通窗口让系统 IME 自己显示组合窗/候选窗
  即可（未处理时系统默认处理）；
- **IME 上屏字符经 `WM_CHAR` 到达**：对 Unicode 窗口，`WM_IME_CHAR`
  与 `WM_CHAR` 完全相同（MSDN 原话）；已上屏的汉字就是一条条 WM_CHAR
  （wParam = UTF-16 code unit）；
- **emoji/特殊符号过滤**：BMP 外字符以**代理对**（两个 WM_CHAR：
  D800-DBFF + DC00-DFFF）到达——丢弃 0xD800-0xDFFF 区间的 code unit
  即可完全排除 emoji；
- 别忘 `ch != 127`（DEL 是控制字符但 ≥ 32，会漏网）。

```zig
WM_CHAR => {
    const ch: u21 = @intCast(wparam & 0xffff);
    if (ch >= 32 and ch != 127 and (ch < 0xD800 or ch > 0xDFFF)) {
        s.pushEvent(.{ .char = ch });
    }
    return 0;
},
```

**教训**：中文输入不必上 `ImmGetContext`/`ImmGetCompositionString`
那套；先查 MSDN 确认“IME 结果怎么到达窗口”，能省一整层自绘组合窗。

### 禁止用 PowerShell 的 Get-Content/Set-Content 改源码！

**实测事故**：用 `Get-Content -Raw` + `.Replace(...)` + `Set-Content` 做
文本替换（想省事改一个小 assert）——整套 UTF-8 中文注释被按 GBK 解码
再写回：大量汉字变 `?`、**换行被吞**，文件彻底损坏（只能 git checkout
恢复后重做全部未提交修改）。

- PowerShell 5.1 的 `Get-Content/Set-Content` 默认用 ANSI（本机 GBK）
  编码，读写 UTF-8 源码必损坏；事故现场是 `powershell -File xxx.ps1`
  （显式调 5.1 子进程）；
- **正确做法**：用编辑器的文本替换（如 edit 工具/IDE），从不整体读写；
- 单文件小改动也不要用 PowerShell——省一分钟，赔一小时。
- （补充：外层 bash 工具本身跑的是 **pwsh 7**（默认 UTF-8 无 BOM）——
  `pwsh` 下的 Get/Set-Content 不会 GBK 乱码；但为一致性，改源码仍统一用
  edit 工具，Append/脚本生成文件仅限 tmp/ 辅助物。）

## 立即式 UI

### 控件 id 步长必须 = 每行控件数（否则跨行撞车）

症状：拖某行的第三个控件，**下一行**的同类控件跟着动（实测：合成器
“功率”推子拖到下一振荡器的“合奏”）。

根因：每行有 3 个控件，但 id 用了步长 2：

```zig
// ✗ oi=0 的三个控件 = 5400/5401/5402；oi=1 的合奏也 = 5402 → 撞车
//   （dragNumber 的 active_id 全局唯一，撞 id 就“串场”）
uni:   5400 + oi * 2
detune: 5401 + oi * 2
power: 5402 + oi * 2   // ← 与下一行 unison 同号

// ✓ 步长 = 每行控件数（3）
uni:   5400 + oi * 3
detune: 5401 + oi * 3
power: 5402 + oi * 3
```

**教训**：`active_id` 是**全应用唯一**的——加控件时先数“每行几个”，
再定步长；本项目已三次撞 id（调音台 7160 与钢琴卷帘 7100；合成器 5402
与下一行合奏；调音台声像 7200 与钢琴卷帘 PAT 标尺 7200——点声像旋钮
会**跳播放游标**、点标尺会**改声像**）。

**防发**：分配表维护在 `ui.zig` 的 `active_id` 注释（新增控件先查表取号）；
每个窗口的控件尽量用**常量基段**（如调音台 `id_pan_base = 8100`）而不是
散落的字面量，并配一条“段不重叠”的单测（见 `view_mixer.zig`）。

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

### 预览类绘图的“画满 N 个就停”会静默丢内容

症状：播放列表片段预览“只显示单个乐器的音符”（多乐器共用一个大样式时）。

机制：预览循环有 `drawn >= 64 则 break` 的“防卡顿”截断；而音符数组的
顺序是**乐器连续的**（导入/编辑都是逐个乐器追加）——数组靠前的乐器
往往就占满 64 个名额（实测工程：样式 3578 个音符，数组前 64 个**全属
同一个乐器**）→ 其余乐器一个都画不出来。

```zig
// ✗ 静默截断：内容丢失不可见，只有用户能发现“东西没了”
if (drawn >= 64) break; // 预览足够……

// ✓ 全画。循环本就要扫全量数组，每个命中音符只是一次小 fillRect
//（1-8px × 2px，实测 3578 个/帧无感）；真要优化就“同像素列合并”
ui.renderer.fillRect(nx, ny, nw, 2, base);
```

**教训**：渲染层的数量截断 = **静默的正确性损失**（无需报错也无人
察觉，直到用户发现“东西没了”）。除非有实测的硬需求，宁慢勿丢；
优化应选“合并/抽样”这类**不丢语义**的手段。

### 调音台通道编号：全项目统一 **0 起**（含标题显示）

基准（唯一权威：`model.Instrument.mixer` 注释）：`mixer` = 调音台通道
**索引，0 起**；通道 0 = “主通道”，通道 1 = “通道#1”；标尺/机架选择器/
标题一律显示同一编号。

实测 bug：效果器窗口标题的两处（乐器查找 + “CH n”）都误用了 `+ 1`
（把 0 起当 1 起）——打开通道 1（Bass）的 EQ 显示成 **“CH2 · Key”**
（Key 是路由到通道 2 的乐器）；而调音台右区抬头的同一份查找却是对的
——**两处各写一份**导致分叉。

```zig
// ✗ 副本 A（效果器窗口）：把 0 起当 1 起
if (inst.mixer != @as(i32, @intCast(ch)) + 1) continue;
// ✓ 调音台右区（对的那份）——现已提取公用函数防再分叉：
//   model.routedInstrumentNames(insts, ch, buf)
if (inst.mixer != @as(i32, @intCast(ch))) continue;
```

**教训**：同一份数据的多处显示/查找逻辑必须收成**公用函数**（附带
单测钉住基准）；写新显示处先看数据模型注释确认 0/1 起，别凭印象 +1。

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

#### “按钮 → 下拉菜单”三件套（踩过两遍的完整清单）

同一套交互我在不同地方写了两遍，**两遍各踩一个坑**——这类控件有
三个必须同时做对的点：

1. **跳过开启帧的“点外部关闭”**（上面那一条：菜单闪一下消失）；
2. **位置只在开启帧快照，之后固定**——若每帧取鼠标位置：
   菜单会跟着鼠标跑（“钓竿上的胡萝卜”，永远点不到）；
   ```zig
   // ✗ 每帧取鼠标 → 菜单追着鼠标跑
   var mx = ui.mouse_x;
   // ✓ 开启帧快照进状态，之后每帧读状态
   if (just_opened) { st.menu_x = ui.mouse_x; st.menu_y = ui.mouse_y + 6; }
   const mx = st.menu_x;
   ```
3. **“刚打开”标记必须每帧重置**（`menuFrameBegin`）——否则第二帧起
   “点外部关闭”永久失效（菜单再也关不掉）。

**根修法：抽成共享控件**（`view_util.menuButton` / `menuPanel`）——
三件事都已在 helper 内部处理对，每个新下拉菜单不再重复踩坑。
（注：`snapSelector*` / `titleSelector*` 是另一套“锚在按钮上”的选择器，
它们的位置天然固定，不会踩坑 2；但坑 1/3 同样适用。）

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

### 播放中新增的音符不响：调度水位线只前进不回头

症状：播放状态下，追加到游标**前方**的音符经常不响——鼠标放置、Ctrl+B
克隆、Ctrl+V 粘贴都一样；落在更远处（4 小节外）的反而正常。
（**同源**：播放中改力度/声像也不生效——同一个水位线不回头的问题；
见下方“通用化”。）

机制：序列器用“水位线”（`scheduled_upto`）提前 4 小节 gather 事件——
水位线**只前进**。播放中新增的音符若落在「已扫过但还没播到」的区间
`[游标, 水位线)`，其 on/off 永远不会被 gather 到（下一帧只扫
`[水位线, 水位线+4小节)`）→ 不响。

**通用化（edit_gen 重扫）**：任何“改数据后已扫过窗口里的事件已陈旧”
的编辑都要重扫——新增/移动/删除/**改值**（力度/声像）全适用：

```zig
// rescanForEdit：编辑提交时
sched.edit_gen +%= 1;   // ① 音频线程丢弃 edit_gen < 当前值 的事件（不释音）
// ② 跨游标差分（键 = 音高+乐器，按实例数）：新多 → on@游标；旧多 → off@游标
// ③ 重扫 [游标+1, 水位线)：旧事件已作废，按新数据补齐
```

**音频侧关键**：**不能**清空 stash（有 drain 竞态会丢新事件）——
改为**触发时过滤**（`ev.edit_gen < edit_gen → 跳过，不释放声部`）。

**边界取舍**：步 == 游标 不重发（可能已触发 → 双触发；漏触发 =
单音符一次不响，轻）；正在响的音符改值 → 下次触发生效
（不能改发声中的声部）。

**配套**：重扫事件可能早于已 stash 事件——stash 必须**按步序插入**
（不是追加），否则被挡住、很晚才触发：

```zig
// ✗ @memcpy 追加：补发的 on@16 排在已 stash 的 off@100 之后 → 拖到 100 才响
// ✓ 按步序插入（从尾部往前移位；共用 schedEventLess）
fn stashInsert(engine: *Engine, ev: synth.SchedEvent) void {
    var i: usize = engine.stash_n;
    while (i > 0 and synth.schedEventLess({}, ev, engine.stash[i - 1])) : (i -= 1)
        engine.stash[i] = engine.stash[i - 1];
    engine.stash[i] = ev;
    engine.stash_n += 1;
}
```

**教训**：增量式调度器（水位线/游标类）必须想清楚“**编辑**”这个维度——
数据是活的，水位线是死的。“编辑代 + 触发时过滤 + 按步序插入”
是完整解（不能只靠“补新增”——改值/移动/删除同样需要）。

### 密集窗口丢事件：“截断保护”与扫描顺序矛盾

症状：导入音符密集的多通道 MIDI（实测 13 通道）后从某些位置起播，
**个别通道**“起点在音上→卡音、起点在空位→整段静音”，其他通道正常。

机制：`scheduleRange` 的 gather 缓冲（512）满时，旧实现把水位线推到
“已收集事件的最大步 + 1”——但**扫描是数组序**（≈ note-off 时间序，
非步序），数组靠后的音符可能尚未扫到（它们的步值可能很小）；
水位线一旦越过，这批事件**永久丢失**。哪个通道中招取决于它在
导入后的音符数组位置（实测：数组末尾的通道 98/413 个起始位置丢，
数组开头的 0/104 正常）——所以同一个文件里“只有某几个通道不正常”。

```zig
// ✗ 截断到 max_step：数组靠后的音符（步值可能很小）被跳过
if (n >= evs.len) sched.scheduled_upto = @min(to, max_step + 1);

// ✓ 子区间收敛：完整收集一个子区间才推进水位线；溢出则减半重扫
//（gatherRange 返回“完整/不完整”，scheduleRange 循环切块）
var sub_len = to - cur;
while (true) {
    if (gatherRange(..., cur, cur + sub_len, ...)) { pushAll(); cur += sub_len; break; }
    sub_len = @max(1, @divTrunc(sub_len, 2)); // 对数收敛
}
sched.scheduled_upto = cur;
```

**教训**：任何“部分扫描”的截断逻辑，截断点必须是**扫描进度**（而
不是“已收集元素的最大键”）——两者只有在“扫描序 = 键序”时才等价。
当扫描序与键序不一致时，前者才能保证不丢。

### 编辑重扫的双触发：重发窗口必须从“音频安全界”起

症状：播放中**调 EQ**（概率出现，“不操作就正常”）→ 某个乐器的某个
音**一直响**，直到暂停/停止才停。

机制（三层叠加）：
1. `commitHistory` **无条件**重扫（EQ 与调度事件无关，重扫纯属多余）；
2. UI 游标来自帧首快照，**落后音频线程**（~1–2 个块）；重扫窗口
   `[游标+1, 水位线)` 包含 `(游标, 音频实际位置]` 这些**已被触发**的步；
3. 音频对“已过时”事件**立即触发**（`ev_frame <= cur → fireSched`）——
   重发的 on 在已在响的地方又开一个声部；而 off 只重发一份 → 只释放
   两个声部中的一个 → 另一个永远 sustain。

```zig
// ✗ 从 UI 游标重发：游标落后音频 → 重发“已触发”的 on → 双声部
scheduleRange(sched, queue, ..., cur + 1, watermark);

// ✓ 从**安全界**重发（音频确定没走到的步）：新鲜读 frames_played 估算
//   音频位置 + 余量（≥2 步且 ≥1536 帧）；(游标, 安全界) 的旧副本**不重发**，
//   由音频侧保留触发（丢旧事件时加步号条件：只丢 step >= 安全界的）
const bound = start_step + (frames_played_now - start_frame) / step_frames;
const rescan_from = @max(cur + 1, bound + 1 + margin);
```

配套：
- 音频作废条件 = `旧传输代 OR (旧编辑代 AND step >= 安全界)`——低于安全界
  的旧副本**保留触发**（否则漏 off → 悬挂）；
- UI **先发布安全界、后发布编辑代**（反序会让音频“新代+旧界”丢多了）；
- stash 插入时**按同键去重更旧代副本**（快速连续编辑时多代副本同时存活
  → 双触发）；同代重复保留（同位置同音高的两个音符是合法的）；
- `commitHistory` 只在**音符/片段真变化**时重扫（比较快照，忽略选区）。

**取舍**：`(游标, 安全界)` 内**新增**的音符首次不响（下一遍会响；
≈3 步 ≈ 几十 ms）。比悬挂轻。

**教训**：任何“重发/重扫”机制必须先回答：“接收方**已经处理到**哪里了？”
——从“我以为它没走到的位置”重发，就会重发已生效的事件。权威水位
（本例音频位置）必须由**处理方**提供，且重发起点要与它加安全余量。

**同音高重叠：合成器的 note-off 必须 FIFO**

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

### 几何符号字形不可靠：图标要么自绘、要么用纯 ASCII

症状：播放按钮用 “▶”（U+25B6）时显示为**竖长方形**——中文字体
（微软雅黑等）常缺几何符号字形，缺字时 stb_truetype 退回 `.notdef` 方块。
同理“❚”“■”“●”都可能缺（字体覆盖范围不可预测）。

```zig
// ✗ 依赖字体覆盖：缺字形 → 方块（外观随用户字体而异）
if (ui.button(200, if (playing) "❚❚" else "▶", ...)) { ... }
// ✓ 像素级自绘：任何字体下外观一致（见 ui.IconShape / view_util.viewSwitchButton）
if (ui.iconButton(200, if (playing) .pause else .play, ...)) { ... }
```
**教训**：只有**纯 ASCII**（`>` `||`）才能假定字体一定覆盖；
其余符号（箭头/几何图形）一律自绘——而且自绘还顺带解决了“风格不统一”
（不同字体的 ▶ 胖瘦/基线都不一样）。

### 自绘图标：宽度要**强制奇数**才居中

逐行扫描画的三角/圆，宽度偶数时 `cx - w/2` 会整体偏左半像素：

```zig
// ✗ w=10（偶）→ 左缘占 5px、右缘 4px → 视觉偏左
const wmax = @divTrunc(r * 3, 2);
// ✓ 向上取到奇数：左右对称（|1 强制最低位为 1）
const wmax: i32 = @max(3, (@divTrunc(r * 3, 2) + 1) | 1);
```
**验证手法**：写个临时测试把帧缓冲按像素 dump 成 ASCII（`#`/`.`），
肉眼一瞥就能发现“偏心”——比截图快得多（截图还要窗口在前台、有缩放误差）。

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

**续（键盘粗移）**：组级钳制仍会“部分位移”——粗移（Ctrl：八度/小节）
必须**全有或全无**：完整位移不可行（如最左音在“第一小节第三拍”，左移
一小节会把它压到第一拍）就**整组拒不动**，否则拍位/级数漂移会破坏
强弱拍律动与调内级数（用户约定）。实现：`App.nudgeSelectedNotesExact`
（粗移，拒）vs `App.nudgeSelectedNotes`（细移/拖动，部分钳）。

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

### 音频效果链路的“陈旧快照”陷阱（频谱分析）

回调里的频谱分析（`analyzeSpectrum`）用滑动窗：每 8 帧抽 1 个样本入窗，
窗长 256。原实现只在“窗写指针恰为 0”时分析——而**块长 % 窗长 通常不整除**，
就此几乎永不触发（实测 bug：测试里频谱恒为 0，UI 背景永远空白）。

```zig
// ✗ 要求块结束时 pos == 0（2400 % 256 = 96 → 永不满足）
if (engine.spec_pos != 0) return;
// ✓ 本块内写过一轮就分析（置 filled_this_block 标记）
var filled = false;
... if (engine.spec_pos == 0) filled = true; ...
if (!filled) return;
```
另：窗内样本必须**按写指针重排**（写指针处 = 最旧样本），否则分析的是错位的窗口。
**教训**：环形缓冲的“写完一轮”判定不能依赖“恰好回到 0”——要显式记标记。

### 频谱幅度必须归一化（2/N）

FFT 幅度未归一化时，任意信号都不会恰好“满刻度”：大幅信号全部撞上限、
柱间无法区分（实测：测试断言恒不成立）。按 `2/N` 归一化后（单幅正弦
= 1.0 → 0dB），-60..0dB 的映射才有意义。

## 音频

### 实时回调的约束

`dataCallback` 运行在**实时线程**：
- ✗ 不能分配内存、不能加锁、不能阻塞；
- ✓ 参数用 `std.atomic.Value` 传递；状态（播放位置）用原子变量回传。

### miniaudio 的日志噪音

Windows 上会打印大量 `SarMMDeviceEnumerator` / `mmwrapper.cpp` 日志——
**这是音频驱动（不是 miniaudio）的输出**，属正常现象。

### `bufPrint` 不能自别名（“@memcpy arguments alias” panic）

症状：打开效果器面板时崩溃（两个乐器都路由到同一通道时必现）：
`thread panic: @memcpy arguments alias`（strip 后无行号，很难定位）。

```zig
// ✗ 增量拼接：第二次时 inst_names 已指向 inst_names_buf
//    → 源与目标同一块内存 → 运行时 panic
if (n > 0) inst_names = std.fmt.bufPrint(&inst_names_buf, "{s}+", .{inst_names}) catch ...;

// ✓ 方案 A：源留在**另一**缓冲（交错使用两个缓冲）
// ✓ 方案 B（本处采用）：**不用增量拼接**——先扫描得到首名与总数，一次成型
var first: ?[]const u8 = null;
var total: usize = 0;
for (items) |it| { if (!match(it)) continue; if (total == 0) first = it.name; total += 1; }
const names = if (total == 1) first.? else
    std.fmt.bufPrint(&buf, "{s} +{d}", .{ first.?, total - 1 }) catch first.?;
```
**教训**：`bufPrint` 的目标只能是“与所有源都无重叠”的缓冲。
“把上次结果接上后缀”这种增量拼接尤其危险（看起来对，第二帧/第二个元素才炸）。
更稳的直觉：**要拼接就先收集再格式化**，别在同一个栈缓冲上反复写读。

## Git / 开发环境（Windows）

### 行尾：全仓库约定 LF；scoop 的 system gitconfig 带 `core.autocrlf=true`

- **scoop 安装的 Git** 在 system 级 gitconfig（`scoop/apps/git/*/etc/gitconfig`）
  写入了 `core.autocrlf = true`——不是“默认值”，是 scoop 带的。它让 git
  双向变形：`git add` 时 CRLF→LF 入库、checkout/restore 时 LF→CRLF 写盘。
- 后果（实测）：工作区混着 CRLF/LF（20+21 个）时，`stash` 往返、
  `read-tree -u`、`restore` 等操作会在行尾层面打架——**stash pop 假冲突**。
- 处理：`git config --global core.autocrlf false` 覆盖它；用
  `git config --show-origin --get-all core.autocrlf` 看各层来源与有效值。
  设置后需**一次性把工作区存量 CRLF 统一成 LF**（从 index/HEAD 重写），
  否则那些文件会立刻显示为“假 modified”，一旦误 `git add` 会把 CRLF 写进库。

### 行尾/假 modified 排查三连（内容、行尾、缓存分开看）

1. `git ls-files --eol <file>` —— i/ 与 w/ 各自的行尾；
2. `git hash-object <file>` vs `git rev-parse :<file>` —— 内容是否真差异；
3. `git cat-file blob :<file> > tmp\b.bin` + `fc /b tmp\b.bin <file>` ——
   字节级铁证（二进制比较务必走 `cmd /c` 重定向；PowerShell 管道会碰编码）。

若 2/3 都一致而 `git status` 仍报 M：是 index 的 **stat 缓存**陈旧，
`git add -u <file>` 刷新即可（内容不变 → staged 为空，只是缓存更新）。

### `restore` 没写盘？touch 一下让 stat 缓存失效

`git restore --worktree`（含 `-c core.autocrlf=false`）可能因 stat 缓存命中
而**跳过写盘**（命令成功、文件行尾/大小原样不动）。把目标文件 mtime 改掉
（`(Get-Item f).LastWriteTime = Get-Date`）再 restore，才会真正重写。
