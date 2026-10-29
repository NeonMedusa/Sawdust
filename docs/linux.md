# Linux 支持（用户视角 + 开发者视角）

> **定位**：Linux（X11 / WSLg）已经可以**日常用**——界面、音频、文件、插件（扫描/加载/发声/编辑器）都通。
> 但它**还不是 Windows 版的等价物**：下面 §2 列的差异，**多数是临时方案或环境妥协**，目标是把它们逐个追平。
> 本文件只写**长期有效**的内容：能力、差异、已知问题、待办、开发者地图。
> 逐轮的排查过程与踩坑细节在 [`pitfalls.md`](pitfalls.md)（"Linux / X11"一节）。

---

## 1. 面向用户：跑起来

### 1.1 依赖
| 需要 | 说明 |
|---|---|
| 构建工具 | Zig 0.17 |
| 运行时库 | libX11、libXext、libXcursor、PulseAudio（或 PipeWire-Pulse） |
| 字体 | 查找顺序：`<exe>/data/font.txt`（自选）→ **fontconfig**（尊重用户配置）→ 系统名单（Windows 微软雅黑 → Segoe UI → …；Linux 文泉驿微米黑 → Noto CJK → 思源黑体 → …）→ `<exe>/data/fonts/` → 任意一种系统字体。全找不到才报错并印安装命令 |

Debian/Ubuntu 一行装齐：
```bash
sudo apt install libx11-dev libxext-dev libxcursor-dev libpulse-dev
```
Arch：`sudo pacman -S libx11 libxext libxcursor libpulse`

### 1.2 构建与运行
和 README 一致，没有什么 Linux 专属仪式：
```bash
git clone --recursive https://github.com/NeonMedusa/Sawdust.git
cd Sawdust
zig build run                                  # 构建并运行（Debug）
zig build -Dcpu=baseline -Doptimize=ReleaseFast # 日常用这个：明显更流畅
```
产物在 `zig-out/bin/Sawdust`。**建议日常用 ReleaseFast**——界面是纯软件渲染，Debug 构建的帧率差距肉眼可见。

运行时的工作目录决定数据位置（`data/` 相对当前目录），所以建议：把二进制拷到一个固定目录，然后从那里启动。

> **WSLg 用户补充**（仅当你在 WSL 里跑）：把构建缓存放 Linux 侧会快很多
> （`zig build --cache-dir "$HOME/.cache/sawdust-build"`），并建议把二进制拷到 `~` 下运行，
> 避免从 `/mnt/c` 启动时的 9p 开销。

### 1.3 启动提示怎么看
| 启动时看到 | 含义 | 要不要管 |
|---|---|---|
| `[x11] MIT-SHM 不可用（服务器在别的 IPC 命名空间，典型：WSLg）→ 回退 XPutImage` | 零拷贝上屏用不了，走普通路径 | **不用管**，自动回退，功能不受影响 |
| `MESA-EGL: warning: DRI3 error` | 没有硬件 GL（WSLg 常态） | 不用管（只影响 OpenGL 类插件） |
| `[x11] 忽略协议错误：...` | 某次 X 请求被服务器拒绝（通常是插件侧） | 一般不用管；持续刷屏再报 |

---

## 2. 与 Windows 版的差异：**多数是临时方案，不是最终形态**

| 功能 | Windows | Linux 现状 | 状态与目标 |
|---|---|---|---|
| **文件对话框** | 系统原生对话框 | **自绘选择器**（`src/file_picker.zig`） | ⚠️ **丐版**：能用（目录优先列表、路径栏、过滤、双击、Ctrl+A/C/X/V、光标闪烁），但**外观与体验明显不如系统对话框**（没有图标、侧栏、书签、最近位置、缩略图、网络位置）。**临时方案**，还没精力打磨。目标：观感追平系统对话框，或改用 **XDG Portal**（异步） |
| 选择器为何自绘 | — | 系统对话框是**同步模态**：调用期间 UI 线程被占住，序列器调度前瞻（4 小节 ≈ 8~10 s）会被耗干 → **音乐十秒后停** | kdialog/zenity 适配代码**停用保留**；重启用前**必须先异步化**（`spawn` + `waitpid(NOHANG)`）。见 [`file-dialogs.md`](file-dialogs.md) §13 |
| **插件 UI（编辑器）** | **嵌进**乐器/效果面板（GDI 子窗口 + `SetWindowRgn` 裁切弹窗） | **独立顶层窗口** + 面板保留自绘参数表 + 「打开/关闭插件 UI」按钮 | ⚠️ **无奈之举**。嵌入容器窗口的体验**更统一、更和谐**（切乐器时插件界面就在面板里，焦点/ALT+TAB 也自然）。X11 下"自绘弹窗盖住插件"试过三种都失败：XShape 裁切（每次改形状服务器自发 Expose → 闪）、拖动抑制（仍闪）、镜像叠加窗（内容位置对，观感错位）。目标：**回到嵌入** |
| 插件 UI **中文输入** | 可用（Win32 IME） | **不可用** | ❌ 与主界面同一个 XIM 缺口 |
| 主界面**中文输入** | 可用 | **不可用**：只能打字面 ASCII | ❌ XIM 未接（§5 待办 #1） |
| **上屏路径** | GDI 位图 | 软件帧缓冲 → `XPutImage`；**真 Linux Xorg 上用 MIT-SHM 零拷贝**；WSLg / 远程 X 自动回退 | ✅ 真机已优化；WSLg 受 IPC 命名空间限制（§3-4） |
| 剪贴板 | `CF_UNICODETEXT` | X11 `CLIPBOARD` 选区，回 `UTF8_STRING`/`TEXT`/`STRING`；粘贴异步、每帧泵一次 | ✅ 行为已对齐（按一次 Ctrl+V 即可） |
| 拖放导入 | `WM_DROPFILES` | **XDND v5**（协议级，任何拖源通用） | ✅ |
| 帮助/外链 | `ShellExecute` | **未接** | ❌ 应走 `xdg-open`（§5 待办 #2） |
| 插件崩溃隔离 | 一插件一 worker + 崩溃补 `WorkerCrashed` | 同（`/proc/self/exe` 自举 + 每帧 `waitpid(NOHANG)`） | ✅ 已对齐 |
| 插件卸载 | `FreeLibrary` | **永不 `dlclose`**（后台线程会踩已释放内存） | ✅ 有意为之（插件稳定性优先） |

---

## 3. 已知问题（Linux 特有）

| # | 问题 | 影响 | 现状 |
|---|---|---|---|
| 1 | **Vital 在本环境不可用**（编辑器能画，但鼠标无反应；且它自己会触发 `BadAtom`，被默认错误处理器 `exit()` 打死宿主） | 该插件用不了 | **已定案不投入**：同宿主里 Dexed / JC303 / OB-Xf（也是 JUCE）都正常，判断为"WSLg 软件 GL + 无窗口管理器"的环境限制。需真 Linux 桌面 / 真 GPU 复测 |
| 2 | **中文输入（XIM）** 主界面与插件 UI 都没有 | 重命名、插件内输入只能用 ASCII | §5 待办 #1 |
| 3 | **WSLg 无硬件 GL**（DRI3 警告），音频/输入延迟偏高 | 手感不如 Windows | 环境限制；ReleaseFast 构建可显著缓解 |
| 4 | **MIT-SHM 在 WSLg 不可用**（Xwayland 在另一个 IPC 命名空间，SysV 共享段看不见） | 每帧 3.9 MB 走 socket | 自动回退，功能正常；**真 Linux 自动启用** |
| 5 | CLI 冒烟（`--vst-scan --run`）**退出前**偶发插件线程 segfault | GUI 长跑不受影响 | 已知，低优先级 |
| 6 | WSLg **没有窗口管理器**：无人发 `WM_TAKE_FOCUS`/`_NET_ACTIVE_WINDOW` | 插件独立窗口焦点需用户自己点 | 真桌面无此问题 |
| 7 | 远程 X（`ssh -X`）下 SHM 不可用、延迟高 | 能用，但不适合实时音频 | 预期行为 |

---

## 3.5 Wayland 与音频后端（现状与结论）

### Wayland
| 场景 | 结果 |
|---|---|
| **Wayland 桌面上的 XWayland**（主流发行版默认开启） | ✅ 能用：窗口/输入/剪贴板/拖放/插件编辑器全走 X11 路径；MIT-SHM 零拷贝也正常（同机同 IPC 命名空间） |
| **中文输入（XIM）** | ❌ XWayland 不为裸 XIM 客户端做输入法桥接（GTK/Qt 走 `text-input` 协议），所以 Wayland 桌面下 XIM 多半仍不可用 |
| HiDPI / 分数缩放 | ⚠️ 只能跟着 XWayland 的整数缩放 |
| 插件编辑器 | ⚠️ Linux 插件（JUCE 等）本来就是 X11 嵌入 → 即使主窗口做成原生 Wayland，插件仍要 XWayland |

**结论**：Wayland 桌面**现在就能用**（经 XWayland），不急做原生后端。
若将来做，`wl_shm` 与我们的软件帧缓冲天然契合（mmap 像素 → attach → commit，零拷贝），
但收益仅限主窗口（插件仍需 XWayland），优先级排在 IME 与音频之后。

### 音频后端
- 当前调用是 `ma_device_init(null, …)` → miniaudio 按内置优先级选：
  **pulseaudio → alsa → jack**（见 `libs/miniaudio/miniaudio.h` 的后端优先级表）。
- **JACK 已经是运行时 `dlopen`**（绑定里是 `jack_client_open: ma_proc = null`），
  所以**编译期不需要 jack 头文件/库**，机器上装了 libjack 或 `pipewire-jack` 就能用。
- PipeWire 现在就能用（`pipewire-pulse` 模拟 Pulse）；想要原生低延迟需走 JACK 接口（pipewire-jack）。
- 待做：**设置里选后端**（自动 / PulseAudio / ALSA / JACK）+ 采样率/缓冲自适应
  （JACK 的周期由服务端决定，`ma_device_init` 后要读回实际值）。

## 4. 已实现能力（按子系统）

| 子系统 | 内容 |
|---|---|
| 窗口/输入 | X11 窗口、UTF-8 标题、鼠标/键盘/滚轮/双击、光标形态、冻结拖动、每帧事件泵 |
| 上屏 | 软件帧缓冲 `XPutImage`；**MIT-SHM 零拷贝**（探测失败自动回退） |
| 文本编辑 | `src/text_edit.zig`：选择器与所有重命名输入框共用语义（单击定位、拖动框选、Shift+方向、Ctrl+A/C/X/V、按 UTF-8 码点删除、光标闪烁） |
| 文件 | 自绘选择器（打开/保存/选目录 + 路径栏 + 文件名编辑 + 过滤）、XDND 拖放导入、剪贴板读写 |
| 音频 | miniaudio → PulseAudio；后台解码；播放/停止/循环/采样器试听 |
| 字体 | 见 §1.1 查找顺序；**单手 exe 就能跑**（不需把字体放 CWD） |
| 插件（L3） | 扫描（bundle 内 `Contents/x86_64-linux/*.so`）、加载（`std.DynLib`）、实例化发声、**编辑器 GUI（独立顶层窗口）**、一插件一 worker 崩溃隔离、路径自愈（CID 精确 → 包名兜底，均静默应用；找不到就标失败，插件管理里可手动定位） |

---

## 5. 待实现（按优先级）

| # | 待办 | 详见 |
|---|---|---|
| 1 | **XIM 中文输入**（主界面 + 插件 UI 共用一套） | §3-2；`pitfalls.md` |
| 2 | `openExternalUrl` → `xdg-open` | §2 表格"帮助/外链" |
| 3 | **插件 UI 回到"嵌入容器窗口"**（体验更统一）——需要先解决"自绘弹窗盖住插件"的闪烁，思路候选：XComposite 重定向 / 让插件窗口只占面板矩形并用 XShape 但**避免拖动时改形状** / 真桌面复测后再定 | §2 表格"插件 UI" |
| 4 | **文件选择器打磨**：图标、侧栏/常用位置、记住上次目录、缩略图；或接 XDG Portal（异步） | §2 表格"文件对话框"；`file-dialogs.md` §11/§12 |
| 5 | CLI 冒烟退出前插件线程 segfault | `pitfalls.md` |
| 6 | （可选）WSLg 零拷贝：走 **fd 传递**（`xcb_shm_attach_fd`）。需引入 libxcb、重写上屏路径，**不建议只为 WSLg 做** | §3-4 |
| 7 | （可选）kdialog/zenity 重启：**必须先异步化** | `file-dialogs.md` §13.2 |
| 8 | **字体回退链**（`FontSet`：主字体缺字时问下一个；用于图标符号/生僻字）。当前是单字体，缺字画方框 | 本节 §1.1 字体行 |
| 9 | **设置页选字体**（枚举系统字体、优先顺序、预览、`settings.json` 持久化、缺字自检） | 同 #8 |
| 10 | **音频后端选择**（Linux：自动/PulseAudio/ALSA/JACK；采样率与缓冲自适应） | §3.5 |

---

## 6. 面向开发者：代码地图

### 6.1 平台分层
| 文件 | 职责 |
|---|---|
| `src/window_types.zig` | **纯数据**：`Event`、`Key`、鼠标单位契约（滚轮一律 ±1/格、`Key` 枚举） |
| `src/window.zig` | 平台分派 + 通用辅助（光标形态、修饰键缓存、拖放路径整理） |
| `src/window_x11.zig` | X11 后端：窗口、事件、光标、剪贴板、XDND、帧缓冲（`XPutImage` / **MIT-SHM**） |
| `src/file_picker.zig` | 自绘文件选择器（Linux 唯一路径） |
| `src/text_edit.zig` | 文本编辑纯函数（选择/光标/删除/插入），含单测 |
| `src/vst_editor_x11.zig` | 插件编辑器容器窗口（XEmbed 握手、`WM_DELETE_WINDOW`→unmap、`DestroyNotify`→retire） |
| `src/port_io.zig` / `port_win_shims.zig` | 非 Windows 的 `std.Io` 垫片 + Win32 符号垫片 |
| `src/c/miniaudio_linux.zig` | Linux 音频后端绑定 |

**两条硬规则**（都是踩过坑得出的）：
1. **垫片只给链接器看，绝不能被运行时调用**——每个被垫的入口必须 `if (comptime builtin.os.tag == .windows)` 隔开；
   违反的后果是 Linux release 下"main 被二次调用"式崩溃。
2. **单位契约写在 `window_types.zig`**（滚轮 ±1/格、鼠标坐标客户区原点），后端只做换算，UI 不做平台判断。

### 6.2 构建 / 测试
```bash
# Linux（WSL 把缓存放 Linux 侧更快）
zig build --cache-dir "$HOME/.cache/sawdust-build"
zig build test --cache-dir "$HOME/.cache/sawdust-build" --summary all

# Windows
zig build test --summary all
```
**动过 UI 代码（`view_*` / `ui` / `main`）必须 `zig build` + `zig build test` 都跑**：`zig build test` 不分析 UI。

当前基线：**Linux 352 pass / 22 skip（374）；Windows 370 pass / 3 skip（373）**。

### 6.3 调试技巧
| 目的 | 做法 |
|---|---|
| 看窗口树/属性 | `xwininfo -tree -id <win>`、`xprop -id <win>` |
| 合成事件 | `xdotool key/click/mousemove`（脚本：`workspace/tools/editor-click.sh`） |
| 绕开 XWayland | `Xephyr :1 -screen 1600x900 &`，`DISPLAY=:1` 跑程序 |
| 抓崩溃栈 | `gdb -batch -ex run -ex bt --args ./Sawdust` |
| 查内存 | `valgrind --error-exitcode=1 ./Sawdust`（Debug 构建） |
| X 错误不致命 | 后端已装**非致命** `XSetErrorHandler`；GUI 不该因边角请求退出 |

### 6.4 已删除的试错（不要重走）
- **XShape 裁切**插件区域、**镜像叠加窗**（override-redirect 小窗镜像像素 + 事件坐标归一化）、
  **XI2 探针**、**`SAWDUST_EDITOR_DETACH` 分离实验**——都因"插件 UI 暂改独立顶层窗口"而失去意义，已删。
- ⚠️ 但**插入式插件 UI 仍是目标**（§5 待办 #3）：重走前先想清楚"改形状 → 服务器自发 Expose → 插件异步重画 → 闪"
  这条因果链，以及拖动期间**不要**改形状。实测结论见 `pitfalls.md`（"Linux / X11"节）。

---

## 7. 测试要点（改动后自查）

1. 缩放窗口 / 最大化 / 中文标题；
2. 推子（BPM、缩放）拖动是否匀速跟手；旋钮是否正常；
3. 滚轮：播放列表 / 混音台 / 效果器列表；Ctrl+滚轮、Shift+滚轮；
4. 键盘：Space、Ctrl+S/O、Delete、方向键长按（自动重复）、文本框打 `A!?_`；
5. 文件：打开工程 / 导入音频 / 另存为 / 选目录；拖一个 `.wav` 进来；
6. 音频：播放 / 停止 / 循环 / 采样器试听；
7. 插件：扫描 → 列表 → 加载乐器 → 发声 → 打开/关闭插件 UI → 关窗后再开。
