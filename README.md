# Sawdust

**S**imple **A**udio **W**orkstation — 用 Zig 写的 DAW。

名字里的 "dust" 指的是**声音的尘埃**：数字音频就是每秒几万个微小的采样点，
我们只是把它们扫成形状。

## 当前状态：骨架（第一个里程碑已完成）

已验证的闭环：

- **窗口**：Win32 直接调用（零第三方窗口库），`CreateDIBSection` 拿到可直接写的帧缓冲
- **渲染**：软件光栅化（`fillRect`/`line`/`blitAlphaMask`），纯 CPU 写像素
- **文字**：stb_truetype 字形光栅化 + 缓存
- **音频**：miniaudio（跨平台），音频回调在实时线程，参数通过原子变量传递
- **UI**：立即式（自绘控件：按钮 / 水平推子 / 垂直推子 / 面板 / 标签）
- **波形视图**：每像素列 min/max 包络（DAW 的标准做法）

界面：播放/暂停按钮、音量推子、频率推子、波形视图、主音量垂直推子。
操作：鼠标拖动推子、空格播放/暂停、Esc 退出。

## 构建与运行

需要 **Zig 0.16**。依赖已手动放在 `libs/`（不用包管理器）：

```
libs/stb/stb_truetype.h        # 字形光栅化（Public Domain）
libs/miniaudio/miniaudio.h     # 音频 I/O（Public Domain / MIT-0）
```

```bash
zig build                 # 调试构建 → zig-out/bin/Sawdust.exe
zig build run             # 构建并运行
zig build test            # 单元测试
zig build -Doptimize=ReleaseFast
```

## 架构

| 文件 | 职责 |
|---|---|
| `src/window.zig` | 窗口层：Win32 API + 消息循环 + 帧缓冲（DIB）。跨平台时只换这个文件 |
| `src/render.zig` | 渲染层：软件光栅化图元（矩形/线/alpha blit），**可独立单测** |
| `src/font.zig` | 字体层：stb_truetype 光栅化 + 字形缓存 + UTF-8 迭代 |
| `src/audio.zig` | 音频层：miniaudio 设备 + 实时回调 + 原子参数 |
| `src/midi.zig` | MIDI 导入/导出（SMF 解析 + 写出；纯逻辑可单测） |
| `src/persist.zig` | 工程保存/加载（JSON `.saw`；版本迁移） |
| `src/ui.zig` | UI 层：立即式控件（自绘） |
| `src/main.zig` | 应用：状态 + 主循环 + 界面布局 |

**文档**：踩坑记录见 `docs/pitfalls.md`；复杂控件设计见 `docs/timeline-scrollbar.md`
（横向时间轴滚动条：minimap 语义的手势/不变量/快照语义）。

**线程模型**：UI 在主线程，音频回调在 miniaudio 的实时线程；
参数（音量/频率/播放状态）用 `std.atomic.Value` 传递（无锁，实时安全）。

**平台支持**：目前仅 Windows。`src/window.zig` 有非 Windows 的编译期占位
（会给出明确的编译错误指向需要移植的文件）。

## 路线图（下一步）

- [ ] 多轨道 + 音频块（clip）编辑
- [ ] 时间轴缩放/滚动、播放头
- [ ] 音频文件加载（WAV/MP3）与波形缓存（多级包络）
- [ ] 混音器（多轨混合、每轨音量/声像）
- [ ] 文本输入（轨道命名）+ IME
- [ ] 键盘快捷键与焦点管理
- [ ] 跨平台（Linux: X11/Wayland；macOS: Cocoa）

## 第三方组件

- [stb_truetype](https://github.com/nothings/stb) — Public Domain
- [miniaudio](https://github.com/mackron/miniaudio) — Public Domain / MIT-0

## 许可证

MIT
