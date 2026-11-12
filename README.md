# Sawdust

**S**imple **A**udio **W**orkstation — 用 Zig 写的 DAW。

SAWtooth（锯齿波）是我最喜欢的波形之一，而Zig的'Z'就是锯齿波的形状，SAW刚好是Simple Audio Workstation的缩写，而 "dust" 你可以理解为**声音的尘埃**：数字音频就是每秒几万个微小的采样点，
我们只是把它们扫成形状，声音是DAW里产出的锯末（你也可以理解为此软件的作者做的音乐难听得像是在拉锯子一样😄）。

<img width="1920" height="1032" alt="图片" src="https://github.com/user-attachments/assets/1ab0e049-c2be-4864-805d-abc977cd7843" />

## 示例工程和演示视频：
https://drive.google.com/drive/folders/1vHJcw6CiEt24WLKBgtTzmiMKY8IMpbfF?usp=sharing

## 下载与安装

**直接使用**：从 [Releases](https://github.com/NeonMedusa/Sawdust/releases) 下载对应二进制，双击（或命令行）运行即可——**单个二进制，无需安装任何运行时**：

- Windows：`Sawdust.exe`
- Linux（x86-64，动态链接 X11）：`Sawdust-Linux-amd64`（依赖与已知差异见 [`docs/linux.md`](docs/linux.md)）

首次启动会在 **exe 同目录自动创建 `data/` 子目录**（设置 `settings.json`、预设 `presets/`、日志 `logs/` 都在里面），整个目录可以随意移动/拷贝，即插即用。

**使用 Scoop 安装**（Windows）：本程序已收录进 [lemon bucket](https://github.com/hoilc/scoop-lemon)，执行：

```powershell
scoop bucket add lemon https://github.com/hoilc/scoop-lemon
scoop install sawdust
```

升级 `scoop update sawdust`；卸载 `scoop uninstall sawdust`（`data/` 目录**默认保留**——设置/预设/日志在里面；加 `-p` 连数据一起删）。

## 当前状态

已经是一个**可以拿来写东西**的工作站——从编曲到混音的全流程闭环都在：

- **VST3 插件**：效果器、乐器与鼓组垫层（加载 / 插件界面 / 参数编辑 / 状态随工程存档与撤销 /
  BPM 同步），多输出 VSTi（如 SFLT），扫描管理器 + 预设浏览器
- **音序器**：SONG / PAT 双模式（**保位无缝切换**：播放中切换不释音、不重击；
  锚片段映射与幽灵游标的完整规则见 [`docs/song-pat.md`](docs/song-pat.md)）、
  循环播放、BPM 与拍号（工具栏拖动调整）
- **钢琴卷帘**：绘图 / 移动 / 复制音符，网格选择，力度与声像编辑轨
- **播放列表**：多轨片段编排（拖拽 / 复制 / 裁剪），时间轴缩放与滚动
- **调音台**：动态增删通道、声像 / 推子 / 静音；**每通道效果链**
  （EQ / 混响 / 延迟 / 压缩器）；**主通道聚合**——所有子通道汇入主通道，
  主推子与主通道效果作用于全体混音
- **效果器**：
  - 4 段参数均衡（频谱背景 + 拖拽控制点）
  - 混响（Freeverb 风格，空间 / 阻尼 / 宽度）
  - 延迟（**按节奏卡拍**：1/2 ~ 1/32 共 11 档音符时值，BPM 变化实时跟随；
    时间平滑滑移防爆音）
  - 压缩器（阈值 / 比率 / 启动 / 释放 / 补偿）
  - 每个效果器干湿可调；混响 / 延迟 / 压缩同类每通道至多一个
- **乐器**：减法合成器（ADSR / 滤波 / 波形）、**乐器声像**（含右键恢复默认）、
  路由到任意调音台通道
- **鼓组插件**：每个垫可叠加多层合成器，独立的增益与预设来源
- **预设库**：合成器 / 效果器参数的扫描、保存、删除与覆盖确认
- **MIDI 导入 / 导出**：导入（多轨合并；通道声像映射到乐器、音符声像居中）；
  导出（轨首 CC10 = 乐器声像）；单测覆盖解析 / 写出的往返
- **音频输出 / 导出**：设置页可选择后端与播放设备（重启生效）；离线导出 WAV、MP3、
  FLAC、OGG，MP3/OGG 可选码率、FLAC 可选压缩等级（压缩格式需系统 FFmpeg）
- **工程**：`.saw`（JSON）保存 / 加载、打开 / 新建（空）的未保存提醒、
  **操作历史**（面板跳转 / Ctrl+Z / Ctrl+Alt+Z；播放中撤销不中断播放）

界面自绘（零 GUI 框架）：窗口、控件、图标形状全部像素级绘制。

## 路线图（下一步）
- [x] VST3 插件（效果器 + 乐器：参数编辑 / 插件界面 / 状态存档与撤销 / BPM 同步 /
  多输出 VSTi（SFLT）/ 扫描管理器 + 预设浏览器）
- [x] 音频文件（WAV/MP3）加载与波形缓存（音频样式 / 音频片段 / 波形窗 / 采样器层，
  见 `docs/audio-files.md`）
- [ ] 自动化曲线（声像、音量、颤音、bpm变速等等等，还有 MIDI 通道声像的完整还原）
  —— 🚧 正在 `automation` 分支上开发（未同步到 main）
- [ ] 更多效果器（合唱 / 失真 / 滤波器……）
- [ ] 将自带的减法合成器升级成更强大的波表合成器，用合成器捏出一整套midi标准乐器音色
- [ ] 音频录制（麦克风 / 线路输入 → 采样层与音频片段）
- [ ] asio支持
- [ ] MIDI 键盘/控制器输入与音符录制（设备枚举与热插拔 / 实时 thru 试听 /
  播放中录音符：量化、力度、声像 / 循环叠录）
- [ ] 音频内存：**P3a** i16 / 保留单声道存储（2~4×）+ 字节预算闸门；
  （流式播放与热集 LRU 已评估，**延后**；峰值懒算已作废——详见 `docs/audio-files.md` §8）
- [ ] 性能打磨（长工程滚动、打开/保存耗时、内存峰值）
- [x] 跨平台：**Linux（X11）已支持**（在 WSLg 上开发并验证，**尚未在真机 Linux 上实测**，见 [`docs/linux.md`](docs/linux.md)）；
  macOS 未开始
- [x] **DPI 感知的 UI 缩放**（100%~300%；高分屏/系统缩放不再“全部很小”，见 [`docs/ui-scaling.md`](docs/ui-scaling.md)；
  `SAWDUST_UI_SCALE=1.5` 可手动指定）

## 构建与运行

**环境：Windows + Zig 0.17**（仓库含 submodule，克隆必须带 `--recursive`）。
Linux（X11）同样适用：命令完全相同，依赖与差异见 [`docs/linux.md`](docs/linux.md)。
```bash
git clone --recursive https://github.com/NeonMedusa/Sawdust.git
cd Sawdust
zig build run             # 构建并运行
```

编译结果在 `zig-out\bin\` 目录中（Windows 为 `Sawdust.exe`，Linux 为 `Sawdust`），
正式编译发布请用：```zig build -Dcpu=baseline -Doptimize=ReleaseFast```

**C 绑定（Zig 0.17 起）**：`@cImport` 已被 Zig 移除，本项目改为**预生成绑定**：
`src/c/miniaudio.zig`、`src/c/stb_truetype.zig` 由 `zig translate-c` 生成并入库（构建期
零网络、零翻译步骤）。C 实现仍走 `addCSourceFile`（`libs/*/*_impl.c`）。
需要升级/更换第三方头文件时，重新生成：

```bash
zig translate-c -I libs/miniaudio libs/miniaudio/miniaudio.h > src/c/miniaudio.zig
zig translate-c -I libs/stb       libs/stb/stb_truetype.h    > src/c/stb_truetype.zig
```

**关于 `libs/zig-vst3`**：只当作**普通源码目录**用（`build.zig` 里 `createModule` 直引
`zig-vst3/src/root.zig`），**不跑它的 `build.zig`**——这样既不碰网络，也不受它自身
构建 API 与 Zig 版本同步的影响。

## 开发约定（提交代码前请读）

**只使用 Zig。** 第三方库可以是 C 语言实现，但必须按下面这套既有方式引入：

- 头文件用 `zig translate-c` **预生成绑定并入库**（`src/c/*.zig`；构建期零网络、零翻译步骤）；
- C 实现走 `addCSourceFile`（`libs/*/*_impl.c`）；
- 参考样例：miniaudio → `src/c/miniaudio*.zig`、stb_truetype → `src/c/stb_truetype.zig`
  （生成命令见上面「构建与运行」）。

**克隆即可离线编译，产物是单个二进制。** 干净克隆（`--recursive`）后，
只要本机装有**对应版本的 Zig** 就能完整构建并运行，**构建期不需要联网**：
不在 `build.zig` 里拉依赖包、不跑子项目的 `build.zig`、不调外部命令生成代码
（第三方源码与 `zig translate-c` 预生成绑定一律入库）。

编译产物必须是**单个可直接运行的可执行文件**（Windows 为 `Sawdust.exe`）：
不引入需要随程序分发的 DLL / 资源文件 / 解释器 / 运行时（Linux 仅依赖系统自带的
动态库，如 X11，见 `docs/linux.md`）。首次运行会在 exe 同目录自动创建 `data/`
（设置 / 预设 / 日志）——那是**运行期数据**，不是构建产物。

**运行期数据只允许落在 `data/`。** 设置、预设、日志、缓存、插件扫描结果……
一切运行时写入都必须放在 `<exe 同目录>/data/` 下，**不允许写到工作目录、用户主目录
或系统其它位置**。唯一例外是**用户自己选择的路径**（导出音频、保存/打开工程、导入采样）。

**临时文件放进被忽略的目录：** `tmp/` 与 `workspace/` 已被 `.gitignore` 排除，
草稿、生成物、调试数据、导出的音频都往这两处放，不要污染工作树。

## 架构

| 文件 | 职责 |
|---|---|
| `src/window.zig` | 窗口层：Win32 API + 消息循环 + 帧缓冲（DIB）。跨平台时只换这个文件 |
| `src/render.zig` | 渲染层：软件光栅化图元（矩形/线/alpha blit），**可独立单测** |
| `src/font.zig` | 字体层：stb_truetype 光栅化 + 字形缓存 + UTF-8 迭代 |
| `src/ui.zig` | UI 层：立即式控件（按钮/旋钮/推子/菜单/滚动条，全自绘） |
| `src/audio.zig` | 音频引擎：设备 + 实时回调 + 原子参数 + 调音台/效果链渲染 |
| `src/synth.zig` | 减法合成器 + 鼓组层声部（复音管理/ADSR/滤波） |
| `src/eq.zig` / `src/effects.zig` | 效果器 DSP：参数 EQ / 混响 / 延迟 / 压缩（含频谱分析） |
| `src/sequencer.zig` | 音序器：事件调度、编辑重扫（播放中编辑水位线） |
| `src/model.zig` | 数据模型：音符 / 片段 / 乐器 / 鼓组（U=96 步长单位） |
| `src/midi.zig` | MIDI 导入/导出（SMF 解析 + 写出；纯逻辑可单测） |
| `src/persist.zig` | 工程保存/加载（JSON `.saw`；版本迁移） |
| `src/preset.zig` | 预设库（扫描 / 读写 / 分类） |
| `src/vst_host.zig` | VST3 宿主：加载 / 处理 / 参数 / 状态 / 编辑器窗口（见 `docs/plugin-hosting.md`） |
| `src/vstscan.zig` | VST3 探测工具（枚举 / 试跑 / 参数 / 编辑器冒烟） |
| `src/main.zig` + `src/view_*.zig` | 应用主循环与各视图（播放列表/卷帘/调音台/机架/效果器/鼓组/预设） |
| `src/c/*.zig` | **预生成的 C 绑定**（`zig translate-c` 产物：miniaudio / stb_truetype） |

**文档**：踩坑记录见 `docs/pitfalls.md`；鼓组插件设计见 `docs/drumkit.md`；
力度/声像编辑轨见 `docs/note-lane.md`；时间轴滚动条见 `docs/timeline-scrollbar.md`；
VST3 宿主见 `docs/plugin-hosting.md`；**Zig 0.17 迁移实录**见 `docs/zig-017-migration.md`；
**播放中编辑的调度与释音协议**见 `docs/scheduler-protocol.md`（不变量 / 事件生命期 / 重扫门控 / 诊断字段）；
**内存 / CPU / 二进制体积账本**见 `docs/resources.md`（池化现状 / 优化 backlog / 发布口径矩阵 / `.rodata` 初值镜像坑）；
**UI 缩放（DPI）**见 `docs/ui-scaling.md`（逻辑像素单点乘算 / 字体按 DPI 光栅化 / 环境变量覆盖）；
**拖动 / 吸附 / Alt 细调**见 `docs/drag-snap.md`（八条不变式 / `GridRebase` 量化与重锚 / 橡皮筋与饱和点 / 八条手势路径对照）；
**SONG / PAT 双模式**见 `docs/song-pat.md`（两个播放域 / 锚片段与白环 / 两个方向的切换映射表 / 幽灵游标 / 点片段带游标 / 手工回归清单）；
**自动化（参数曲线）的模型与计划**见 `docs/automation.md`（点 + 每段插值 / 两种编辑视图 / 存取与历史纪律）。
**线性工作流改造（轨道 + 片段，线性 DAW 风格）的设计稿**见 `docs/linear-refactor.md`。

**线程模型**：UI 在主线程，音频回调在 miniaudio 的实时线程；
参数用 `std.atomic.Value` 传递（无锁，实时安全）；编辑提交走"重扫"机制
（作废未触发的旧事件、按新数据补齐，播放不中断）。

**平台支持**：

| 平台 | 状态 |
|---|---|
| **Windows** | 主要开发平台，功能完整 |
| **Linux（X11）** | 已支持：窗口/输入/剪贴板/拖放/音频（PulseAudio、可选 JACK）/VST3 宿主均可用。**在 WSLg 上开发并验证，尚未在真机 Linux 上实测**——已知差异、限制与待办见 [`docs/linux.md`](docs/linux.md) |
| macOS | 未开始 |

> Linux 构建/运行与 Windows 相同（`zig build run`）；依赖、已知问题、与 Windows 的差异详见 [`docs/linux.md`](docs/linux.md)。

## 开发工具

本项目使用 **[SkyNet](https://github.com/NeonMedusa/SkyNet)** 协作开发——
一个开源的 AI coding agent，模型使用 **deepseek-v4.1-flash** ：
从架构设计、DSP 到界面交互，全部工作在人机结对中完成。

## 第三方组件

- [stb_truetype](https://github.com/nothings/stb) — Public Domain
- [miniaudio](https://github.com/mackron/miniaudio) — Public Domain / MIT-0
- [zig-vst3](https://github.com/joshburgess/zig-vst3)（本项目 fork，submodule `libs/zig-vst3`）— MIT；
  VST3 绑定 + 插件侧框架（钉版 VST3 SDK v3.8.0 build 66；VST3 SDK 2025 起亦为 MIT）

## 许可证

MIT

## 交流

**Sawdust 编作曲交流群（QQ）：1130996634** —— 使用问题、报 bug、提需求、交流编曲都可以在这里（虽然群主经常失踪，但交流依然会比提issues更即时一些）。