# 文件对话框：方案与决策记录

> **当前状态（已落地）：见 §13「决策记录」。**
> 本文其余部分是"如果要把原生观感 + 非阻塞做到最好"的完整方案（§1~§12），
> 里面的 Windows 工作线程、Portal、kdialog/zenity 异步都属于**待办/备选**，不是现状。

---

## 0. 目标 / 非目标

**做**

1. Windows：系统对话框（原生观感），跑在**工作线程**上，主循环每帧非阻塞轮询结果。
2. Linux：`kdialog` → `zenity`（异步子进程），缺失或失败才降级自绘。
3. 自绘选择器保留为**兜底**（并可用 `SAWDUST_PICKER=builtin` 强制）。
4. 统一语义：**非阻塞模态** —— 弹框期间主窗口输入被挡住，但渲染、音频、调度前瞻照常。
5. 目标失效护栏：异步期间目标（乐器/通道/样式/插件槽）可能被删 → 完成时校验，不崩。

**不做**

- 不写 XDG Desktop Portal / D-Bus。
- 不给系统对话框加 hook/自定义模板（会退回旧式观感，得不偿失）。
- 不改"4 小节前瞻"的既有语义（可选硬化见 §10）。
- 不做跨进程"对话框服务"之类的大改造。

---

## 1. 现状与根因（已核对代码）

| 事实 | 位置 |
|---|---|
| 调度前瞻 = **4 小节**，由 **UI 线程每帧**推进 | `src/main.zig:845-850` |
| 120 BPM 4/4 → 8 s；90 BPM → 10.7 s（与"响十秒就停"吻合） | 同上 |
| 音频线程只按步边界消费队列，UI 停则队列耗尽 ⇒ 音乐停 | `sequencer.zig` / `SchedQueue` |
| Linux 现在走**自绘**选择器 → 不阻塞（实测 OK） | `src/main.zig` `handlePick` |
| Windows 仍**同步**调 `GetOpenFileNameW` → 阻塞（问题仍在） | 同上，非 Linux 分支 |
| zenity/kdialog 用 `std.process.run`（同步等待） | `src/filedialog.zig:45`、`:302` |
| `MessageBoxW` 两个封装（`confirmSave`/`alert`）**已无调用点**（脏确认早已改自绘） | `src/filedialog.zig:419`、`:436` |
| Zig 0.17 的 `std.process.Child` **只有阻塞 `wait`**，没有 `tryWait` | `std/process/Child.zig` |

**结论**：剩下的唯一阻塞源就是"文件对话框本身走同步调用"，两端各一条：
- Windows：`GetOpenFileNameW` / `SHBrowseForFolderW`；
- Linux：`std.process.run(kdialog|zenity)`。

---

## 2. 架构：一个 Provider 抽象、三种实现

```zig
pub const Provider = union(enum) {
    builtin: file_picker.Picker, // 自绘（兜底）
    external: External,          // Linux：kdialog/zenity 子进程（异步）
    native: NativeWin,           // Windows：工作线程跑系统对话框
};

pub const Status = union(enum) {
    pending,
    done: []u8,      // 调用方 free
    cancelled,
    failed,
};

pub fn begin(app: *App, io: std.Io, req: PickRequest) Status/Begin;  // 选提供者（阶梯）+ 深拷贝参数
pub fn pump(p: *Provider, io: std.Io) Status;   // 每帧：**必须 O(1) 非阻塞**
pub fn draw(p: *Provider, ui: *Ui) void;        // builtin 画面板；其它画"暗化层 + 提示"
pub fn requestCancel(p: *Provider, io: std.Io) void;
pub fn deinit(p: *Provider, io: std.Io) void;
```

**不变量**

1. `pump` 里禁止任何可能阻塞的等待（只允许：一次 `waitpid(NOHANG)`、一次 atomic load、一次 `PeekMessage` 类调用）。
2. `begin` 时把 `title/filter/default_name/start_dir` **深拷贝**进请求（工作线程 / 子进程不能引用 UI 侧内存）。
3. `app.pick != null` 期间：
   - 新的 `requestPick` **直接忽略**（防"两个框"）；
   - 主窗口点击被闸门挡下（复用现有 modal 输入隔离）；
   - **帧循环、绘制、音频、前瞻照常**。
4. 结果所有权：**谁分配谁释放**——工作线程/子进程结果一律用 `std.heap.page_allocator`，UI 线程消费后 `free`。

---

## 3. Windows：系统对话框 + 工作线程

```
UI 线程                               工作线程(STA)
begin: 深拷贝参数, Thread.spawn  ───▶  CoInitializeEx(COINIT_APARTMENTTHREADED)
每帧: atomic load 状态                GetOpenFileNameW(OFN_EXPLORER, hwndOwner)
      done → join, 取 buffer          写结果 → 状态置 DONE（release）
```

- **观感**：`GetOpenFileNameW`（不带 hook/自定义模板）在 Vista+ 内部走新式 IFileDialog，观感原生。
- **模态性**：不依赖系统行为——我们自己也有 `app.pick != null` 输入闸门。若系统顺带 `EnableWindow(owner, FALSE)`（常见），也接受：窗口仍会重绘、音频仍继续，只是输入被挡 = 正是想要的语义。
- **取消/退出**：`EnumThreadWindows(worker_tid, cb)` 找到对话框 HWND → `PostMessageW(hwnd, WM_CLOSE)`；线程 `detach`，进程退出兜底。
- **失败兜底**：`Thread.spawn` 失败、或对话框返回内部错误 → 降级 `builtin`。
- **候补方案（若跨线程 owner 出问题）**：`hwndOwner = null` + `EnumThreadWindows` + `SetForegroundWindow`，保证弹在最上层。

**需要新增/改动的 Win32 符号**：`CoInitializeEx`、`EnumThreadWindows`、`PostMessageW`、`GetCurrentThreadId`（其余已 extern）。

---

## 4. Linux：kdialog → zenity（异步子进程）+ 自绘兜底

```
begin: 探测 kdialog → zenity → builtin
       spawn(argv)（stdout 用管道；参数构造复用现有 filedialog.zig）
每帧: waitpid(pid, WNOHANG)  → 0: pending / 已退出: 读 stdout → 路径
结束: 自己关 fd（**不用** Child.wait/kill —— 0.17 是阻塞+断言）
```

- **为什么自己 poll**：Zig 0.17 `Child.wait` 阻塞、没有 `tryWait`；`waitpid(WNOHANG)` 最省事且不依赖内核版本（pidfd 方案可作备选，不做）。
- **结果体积**：zenity/kdialog 只输出一行路径（< 4 KB），不会塞满管道 → 退出后再读安全。
- **阶梯**：`kdialog` spawn 失败（ENOENT 等）→ `zenity` → `builtin`；可用 `SAWDUST_PICKER=auto|external|builtin` 覆盖。
- **暗化层**：外部框在场时由我们画全屏暗化 + "等待文件对话框…"，避免"界面像是没反应"的错觉。
- **WSLg 注意**：没有窗口管理器，外部框位置/置顶由 XWayland 决定，可能不理想——文档注明，不为此写 WM 适配。

---

## 5. 与主循环的接线（改动很小）

```zig
// 每帧（帧末）
if (app.pick == null) if (app.takePick()) |req| app.pick = provider.begin(app, io, req);
if (app.pick) |*p| switch (provider.pump(p, io)) {
    .pending => {},
    .done => |path| { dispatchPick(app, p.use_, path); provider.deinit(p, io); app.pick = null; },
    .cancelled, .failed => { app.setToast(p.cancelText()); provider.deinit(p, io); app.pick = null; },
};
// 绘制阶段（endFrame 之前）
if (app.pick) |*p| provider.draw(p, ui);
```

12 个调用点保持现状（`app.requestPick(...)` 不动）——它们在上轮已经改造完成。

---

## 6. 正确性护栏

1. **目标校验**：`load_sample`、`relocate_instrument/effect`、`preset_rename` 等带目标的 use，完成时先校验目标仍存在；否则 toast「目标已不存在」，不崩。
2. **单请求闸门**：`app.pick != null` 时忽略新请求（避免二次弹框）。
3. **退出顺序**：先 `requestCancel`（子进程 kill / 工作线程 WM_CLOSE）→ `deinit` → 让线程 detach；`app.pick` 的堆缓冲在 `deinit` 里统一释放。
4. **内存所有权表**：请求参数（begin 深拷贝）由 UI 线程释放；结果（工作线程/子进程产出）由 UI 线程消费后释放。
5. **不做同步等待**：`deinit` 里也不 join（detach），避免退出时卡住。

---

## 7. 测试计划

1. **回归测试（不需要窗口，最关键）**
   假 provider 连续 `pending` N 帧 → 断言 `scheduler.scheduled_upto` **持续推进**。
   → 这就是"弹框期间音乐不会停"的自动化证明。
2. **Provider 单测**
   - 阶梯选择：PATH 打桩（无 kdialog → 选 zenity → 都无 → builtin）；
   - 退出码/输出解析（正常路径、取消、空输出、多行）；
   - 双请求闸门；取消；目标失效。
3. **Linux 集成（WSL 实机）**
   `SAWDUST_PICKER=external` + xdotool 打开对话框 → 日志里 `scheduled_upto` 单调增长、播放位置推进（不打桩的端到端证明）。
4. **Windows 手工清单**（我这边无法实机验证，需你跑）
   - 弹框：原生观感、在最前、主窗口变灰/不可点；
   - **弹框期间**：界面仍在刷新（看播放头/表头电平）、**音乐不断**；
   - 取消（Esc / 关闭 / 取消按钮）→ 回到应用、状态正常；
   - 连续两次 Ctrl+O → 只有**一个**框；
   - 弹框时关闭主窗口 → 不卡、进程能退出。
5. 两端现有 371 个测试保持全绿。

---

## 8. 里程碑（每步可独立交付）

| M | 内容 | 估时 | 风险 |
|---|---|---|---|
| **M1** | `Provider` 抽象 + 假 provider + **前瞻不中断回归测试** | 0.5 d | 低 |
| **M2** | Linux `external` 异步（kdialog→zenity）+ 阶梯 + `SAWDUST_PICKER` | 1 d | 低 |
| **M3** | Windows `native` 工作线程（含取消/退出/兜底） | 1.5~2 d | **中高**（跨线程 owner、退出回收） |
| **M4** | 删死代码（`MessageBoxW` 封装）、审计其它阻塞调用、写文档 | 0.5 d | 低 |
| **M5** | 打磨：记住上次目录、错误提示文案、暗化层文案 | 0.5 d | 低 |

合计 ≈ **3.5~4.5 人日**。M1+M2 交付即"Linux 全链路非阻塞"；**M3 才是 Windows 的根治**。

---

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| 跨线程 owner 的系统对话框行为怪（焦点/禁用） | 候补：`hwndOwner=null` + `EnumThreadWindows` + `SetForegroundWindow` |
| 用户以为"还在冻结" | 不是冻结：重绘/音频继续，只是输入被挡；用暗化层 + 标题提示说明 |
| kdialog/zenity 被桌面策略限制 / 不在 PATH | 静默降级 zenity → builtin（可选弹一次 toast） |
| WSLg 无 WM，外部框位置/置顶不理想 | 文档注明；不为此写 WM 适配 |
| 退出时工作线程/子进程残留 | `requestCancel` + detach + 进程退出兜底；`deinit` 里不 join |
| 异步期间目标被删 | §6.1 目标校验 |

---

## 10. 可选硬化（不做也不影响本方案）

- `SAWDUST_LOOKAHEAD_BARS`（默认 4）让前瞻可调 → 万一将来又出现阻塞源，能临时撑更久。
- 帧耗时看门狗：单帧 > 200 ms 时打一条日志/toast，帮助发现新的阻塞源。

---

## 11. 需要拍板的点

1. **Windows 模态语义**：系统框在场时主窗口"变灰不可点"（更原生）是你要的吗？还是希望主窗口仍可点（更"非模态"）？
2. **Linux 降级提示**：`kdialog`/`zenity` 都缺失时，静默降级自绘，还是弹一次 toast 告知？
3. **M3 的 Windows 验证**：需要你在 Windows 上按 §7.4 清单实测（我可以把清单做成脚本可跑的命令）。
4. 是否把 **M5「记住上次目录」** 一起纳入本次范围。
5. **Portal 的时机**：按 §12 建议放到 M6（先 M1→M2→M3，Windows 先根治）；还是希望
   "Linux 一步到位用标准 Portal"而提前（那也要先做 M1，且 Windows 的阻塞会继续存在一段时间）。

---

## 12. XDG Desktop Portal 的定位（M6，纯增量）

### 12.1 它天生就是异步的 —— 这是它最大的技术优点

```
应用 ──OpenFile(parent_window, title, options)──▶ portal
     ◀──────────── handle (object path `o`) ──────   ← 立即返回，不阻塞
     ◀── 信号 Request.Response(response, results) ─   ← 用户选完后才发
```

`OpenFile/SaveFile` **立刻**返回一个 handle，结果通过 `org.freedesktop.portal.Request`
的 `Response(uint response, a{sv} results)` 信号回来。所以：

- **不需要工作线程**，也不需要 `waitpid` —— D-Bus 的 socket fd 变可读 = 有消息；
- `Provider.pump()` 里做一次"非阻塞读 socket → 解析一条消息"，形状和 Windows 的
  "atomic load" 完全一样；
- 还能顺手拿到 **`parent_window = "x11:0x600001"`**（我们的 X11 窗口 id 现成）→ 对话框
  真正挂靠主窗口（模态），这是 `zenity` 做不到的。

### 12.2 和 Windows 的"解法"是否一样？

**形状一样（启动 → 拿 handle → 每帧取结果），"谁提供异步"不一样：**

| | 异步由谁提供 | 我们的实现 |
|---|---|---|
| Linux · Portal | **协议本身**（请求/响应） | 读 D-Bus fd，无需线程 |
| Linux · kdialog/zenity | 我们自己造（子进程） | `spawn` + `waitpid(NOHANG)` |
| Windows · 系统对话框 | 我们自己造（线程） | 工作线程 + atomic 状态 |

也就是说：**Portal 让 Linux 更"干净"，但它对 Windows 一点帮助都没有**——Windows 的
唯一解仍然是工作线程。三者都塞进同一个 `Provider`，靠的就是 M1 那层抽象。

### 12.3 成本（Zig 没有 D-Bus 客户端）

| 做法 | 量 | 估时 | 风险 |
|---|---|---|---|
| **手写最小 D-Bus 客户端**（连接+SASL EXTERNAL 认证+Hello+AddMatch+编组 `sa{sv}`+解析 `ua{sv}`） | ~500–700 行 | 2–3 d | 编组/对齐细节容易出错 |
| **链 libgio**（本机实测 `pkg-config gio-2.0` = 2.90.1 已装）+ `g_dbus_connection_call` 异步 + 每帧 `g_main_context_iteration(ctx, FALSE)` | ~250–350 行 + build.zig 加 `pkg-config gio-2.0` | 1–1.5 d | 多一个构建依赖（GTK 桌面必有；纯 X11 极简环境可能没有 → 需降级） |

### 12.4 为什么建议**后做**（而不是先做）

1. **它不能替代兜底链**：裸 WSL / 无 portal 后端 / 无 D-Bus 会话的环境仍然存在 → 自绘与
   shim 都必须留着。Portal 是**又一个 provider**，不是替代品。
2. **它对 Windows 零帮助**：Windows 那个"十秒断音"还是得靠工作线程，先做 Portal 等于
   把最贵的活干在"用户可感知收益最小"的地方（现在 kdialog/zenity 已经是原生观感）。
3. **Provider 抽象让它天然可后插**：M1 完成后，Portal 只是 `Provider` 里多一个
   `portal: Portal` 分支 + 一个 `pump` 分支，不返工、不动 12 个调用点。

**只有当你要发 Flatpak/沙箱包、或必须在不装 zenity 的 GNOME/Wayland 上保持原生观感时**，
才值得把 Portal 提前。

### 12.5 顺带校正两处细节（已在本机验证）

| 说法 | 实际 |
|---|---|
| "kdialog/zenity 都不能挂靠父窗口" | `kdialog --attach <winid>` **可以**（"makes the dialog transient for an X app"）；`zenity --attach=` 是 **DEPRECATED; does nothing**，只有 `--modal` 提示。→ Linux shim 路线可以白捡 KDE 的模态挂靠 |
| "portal 是唯一标准" | 对（唯一标准），但 shim 不是"临时垃圾"：它们是**长期次选**，非沙箱应用用一辈子也没问题 |

### 12.6 如果决定提前做 Portal

顺序也必须是：**M1（Provider 抽象 + 回归测试）** → M6-portal → M3（Windows 工作线程）。
M1 之前写 Portal，会和后面的状态机改动互相踩。
---

## 13. 决策记录（**以此为准**）

### 13.1 决策（已定）

| 平台 | 用什么 | 阻塞？ | 代码位置 |
|---|---|---|---|
| **Linux** | **内置自绘选择器，无条件**（不看桌面装了 kdialog/zenity） | 否 | `src/file_picker.zig`；入口 `main.zig` `handlePick` |
| **Windows** | **系统对话框**（原生观感，`GetOpenFileNameW` / `SHBrowseForFolderW`） | **是**（已知问题，**单独立项**） | `src/filedialog.zig` |
| **Linux 外部提供者**（kdialog → zenity） | **停用保留**，不删 | — | `src/filedialog.zig` 的 `linux` 命名空间；开关 `linux_external_enabled = false` |

**为什么 Linux 直接"无脑自绘"**：三条路（自绘 / shim / Portal）都能做到不阻塞，但
- 自绘**零依赖、零阻塞、观感与主界面一致**，且我们已经写完了（含路径栏编辑、剪贴板、框选）；
- shim 与 Portal 的收益是"原生观感 / 模态挂靠 / 沙箱"，属于**锦上添花**，不是必须；
- 权衡后：**先把 Linux 收敛到一条最简单的路**，其余代码留着，将来想升级再拿出来。

### 13.2 kdialog / zenity 代码的"停放"约定

- `src/filedialog.zig` 里 `linux` 命名空间完整保留（含过滤器转换、退出码解析等已修好的坑）；
- 顶层 `open/save/pickFolder/confirmSave/alert` 的 Linux 分支都加了开关
  `if (is_linux and linux_external_enabled) …`，默认 `false` → 编译期就被剪掉，**运行时不可能调到**；
- 为了防止停用代码悄悄烂掉，加了守卫测试
  `"filedialog: Linux 外部提供者（停用中）仍然编译得过"`（只取函数地址，不调用）；
- **将来要重新启用，必须同时做两件事**：
  1. `linux_external_enabled = true`；
  2. 把 `std.process.run` 改成**异步 spawn**（`spawn` + 每帧 `waitpid(NOHANG)`），
     否则会重新引入"音乐十秒后停"。参考 §4。

### 13.3 Windows 阻塞问题：**单独立项**（不在本次范围）

- **现象**：Windows 上弹出系统文件对话框期间，UI 冻结；约 8~10 秒后音乐停止。
- **根因**：`GetOpenFileNameW` 是同步/模态调用 → 卡住 UI 线程 → 序列器 4 小节前瞻
  （`main.zig:845`）推不上去 → 队列耗尽 → 音频线程空转。
- **根治方案**：§3（工作线程跑系统对话框 + 主循环每帧轮询状态），或 §12 的自绘替代。
- **验收标准**（将来做时照这个验收）：
  1. 弹框期间播放头继续走、电平表继续动、**音乐不断**；
  2. 弹框期间主窗口不可点（原生模态语义），但**仍在重绘**；
  3. Esc / 取消 / 关闭 都能正常回到应用；
  4. 连续按两次快捷键只弹**一个**框；
  5. 弹框时关闭主窗口 → 不卡死、进程能退出。
- **回归测试**：假 provider 连续 `pending` N 帧 → 断言 `scheduler.scheduled_upto` 持续推进
  （不需要窗口就能证明"音乐不会停"）。

### 13.4 明确的"暂不做"

| 项 | 理由 |
|---|---|
| XDG Desktop Portal（D-Bus） | 唯一标准，但要写 D-Bus 客户端（1~3 d）；且替代不了兜底链、对 Windows 无帮助。见 §12 |
| kdialog/zenity 异步化 | Linux 已走自绘，收益为 0；代码留着等将来 |
| Windows 工作线程 | 已单独立项（§13.3），本次不做 |
| 自绘选择器"文件管理器化" | 侧栏书签/搜索/缩略图等，等真有需求再说；现在靠"路径栏可编辑"已能覆盖 |