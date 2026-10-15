# Sawdust

**S**imple **A**udio **W**orkstation — 用 Zig 写的 DAW。

SAWtooth（锯齿波）是我最喜欢的波形之一，而Zig的'Z'就是锯齿波的形状，SAW刚好是Simple Audio Workstation的缩写，而 "dust" 你可以理解为**声音的尘埃**：数字音频就是每秒几万个微小的采样点，
我们只是把它们扫成形状，声音是DAW里产出的锯末（你也可以理解为此软件的作者做的音乐难听得像是在拉锯子一样😄）。

<img width="1920" height="1032" alt="图片" src="https://github.com/user-attachments/assets/1ab0e049-c2be-4864-805d-abc977cd7843" />

## 示例工程和演示视频：
https://drive.google.com/drive/folders/1vHJcw6CiEt24WLKBgtTzmiMKY8IMpbfF?usp=sharing

## 当前状态

已经是一个**可以拿来写东西**的工作站——从编曲到混音的全流程闭环都在：

- **音序器**：SONG / PAT 双模式、循环播放、BPM 与拍号（工具栏拖动调整）
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
- **工程**：`.saw`（JSON）保存 / 加载、打开 / 新建（空）的未保存提醒、
  **操作历史**（面板跳转 / Ctrl+Z / Ctrl+Alt+Z；播放中撤销不中断播放）

界面自绘（零 GUI 框架）：窗口、控件、图标形状全部像素级绘制。

## 构建与运行

需要 **Zig 0.16**。依赖手动放在 `libs/`（不用包管理器）：

```
libs/stb/stb_truetype.h        # 字形光栅化（Public Domain）
libs/miniaudio/miniaudio.h     # 音频 I/O（Public Domain / MIT-0）
libs/zig-vst3/                 # VST3 绑定（submodule；MIT）
```

> 仓库含 submodule（`libs/zig-vst3`）：克隆请用 `git clone --recursive`；
> 已克隆的仓库补 `git submodule update --init` 即可。

```bash
zig build                 # 调试构建 → zig-out/bin/Sawdust.exe（**单文件**）
zig build run             # 构建并运行
zig build test            # 单元测试
zig build -Doptimize=ReleaseFast
```

> 注：插件管理器的扫描以**独立进程运行自身 exe**（`Sawdust.exe --vst-scan …`，同二进制
> 自举）——坏插件崩溃隔离在 worker 进程里；发布只需一个 exe。

## 快捷键

| 键 | 作用 |
|---|---|
| `空格` | 播放 / 暂停 |
| `Ctrl+Z` / `Ctrl+Alt+Z` | 撤销 / 重做 |
| `Ctrl+S` / `Ctrl+Shift+S` | 保存 / 另存为 |
| `Ctrl+O` | 打开工程 |

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

**文档**：踩坑记录见 `docs/pitfalls.md`；鼓组插件设计见 `docs/drumkit.md`；
力度/声像编辑轨见 `docs/note-lane.md`；时间轴滚动条见 `docs/timeline-scrollbar.md`；
VST3 宿主见 `docs/plugin-hosting.md`。

**线程模型**：UI 在主线程，音频回调在 miniaudio 的实时线程；
参数用 `std.atomic.Value` 传递（无锁，实时安全）；编辑提交走"重扫"机制
（作废未触发的旧事件、按新数据补齐，播放不中断）。

**平台支持**：目前仅 Windows。`src/window.zig` 有非 Windows 的编译期占位
（会给出明确的编译错误指向需要移植的文件）。

## 路线图（下一步）

- [ ] 音频文件（WAV/MP3）加载与波形缓存
- [ ] 自动化曲线（声像、音量、颤音、bpm变速等等等，还有 MIDI 通道声像的完整还原）
- [ ] 音频、音符录制
- [ ] 更多效果器（合唱 / 失真 / 滤波器……）
- [ ] 跨平台（Linux: X11/Wayland；macOS: Cocoa）
- [x] VST3 插件（效果器 + 乐器：参数编辑 / 插件界面 / 状态存档与撤销 / BPM 同步 /
  多输出 VSTi（SFLT）/ 扫描管理器 + 预设浏览器）
- [ ] asio支持
- [ ] 更加强大的波表合成器

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
