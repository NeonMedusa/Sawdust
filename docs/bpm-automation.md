# BPM（速度）自动化 —— 设计与边界

> 状态（2026-11-11）：**BPM 自动化已实现**（方案 B：音频侧步位置积分器）。
> 本文同时**写死**三件"暂不做"的事，避免以后误以为漏了。

---

## 一、BPM 自动化：为什么必须动音频侧

旧的位置公式是**锚定式**：

```
当前步 = start_step + (当前帧 − start_frame) / step_frames(BPM)
```

`start_frame / start_step` 在起播/跳转/循环时定一次。BPM 一旦在播放中改变，
这个等式会拿**新速率**重算**历史**——播放头直接跳一下。所以"BPM 自动化"的真名是
**变速播放**，必须让位置变成**积分**而不是"重算"。

### 方案 B（已采用）：音频侧步位置积分器

| 位置 | 改动 |
| --- | --- |
| `audio.Engine` | 新增 `ref_step: f64`（块首"当前步"）、`ref_gen: u32`、`blk_abs0: u64` |
| `renderBlock` | **换锚**（`sched_gen` 变 = 起播/跳转/循环）时用旧等式初始化 `ref_step`；之后每块 `ref_step += frames / step_frames(当前 BPM)` |
| 事件触发 | `ev_frame = 块参考帧 + (ev.step − 块参考步) × step_frames`（步坐标事件，天然跟随变速） |
| 音频片段 | `clipSpan` 的 `(start_frame, start_step)` 改传**块参考系**（同上换算） |
| 自动化求值 | 段首步 = `ref_step + (段帧 − 块帧)/step_frames`（BPM 对 music-time 求值同样受影响） |
| 回传 UI | `Params.play_step: atomic f32`（每块发布）——游标直接读它 |

块内仍按"当前 BPM 恒定"处理：变速只发生在**块边界**（10~20ms 粒度），这与
一切"每块现算 step_frames"的既有逻辑同口径。

### 自动化目标

- `view_lane.Target.Kind` 新增 **`tempo`**（全局目标，`uid` 忽略）；
- 归一化映射（线性）：`bpm = 20 + v × 480`（20~500），`defaultBase = normFromBpm(120)`；
- **求值在 UI 侧**（`App.applyTempoAutomation()`，每帧，主循环同步 BPM 前调用）：
  音频侧只需要块级 `params.bpm`，不需要 lane 快照；
- 入口：工具栏 **BPM 数字右键 → 自动化**；
- 存档/历史：`tempo` 绑定走既有 `SavedBinding`（`kind + uid=0`），**无需改格式**。

---

## 二、小数 BPM（两位小数）与右键菜单

- `App.bpm` / `persist.Project.bpm` / `HistoryState.bpm` / `params.bpm` 均为 **f32**；
- **音频侧 `step_frames` 改 f64**（事件触发/片段窗口/lane 求值/诊断），位置推进本来就由 f64 积分器负责，不漂；
  `clipSpan` 仍收整数帧（窗口取整），因窗口每块重算，误差不累加；
- UI：BPM 控件 = **`ui.dragNumberBpm`**：
  - **拖动只改整数位**（8px = 1 BPM），**保留三位小数**：`120.555` ↑ → `121.555`，↓ → `119.555`；
  - **推到边界小数清零**：`20.555` ↓ → `20.000`（之后 ↑ → `21.000`）；`998.555` ↑ → `999.000`（之后 ↓ → `998.000`）；
  - 小数只能通过**右键 → 输入值…**键入（如 `120.555`）；显示形式 `{整数}.{三位小数}`；
- **右键 → 菜单**：`输入值…`（文本输入 `TextInput.Target.bpm`，可键入 `128.50`）/ `自动化…`（开自动化窗口）；
- **每步帧数公式唯一实现**：`audio.stepFramesOf(sr, bpm, steps_per_beat)`（App 侧 `framesPerStep/stepFramesNow` 只是它取整后的 u64 版）；
- `Playback.start_frame/start_step` = **换锚基准**（起播/跳转/循环那一刻），真实位置由音频侧积分器推进；
  `currentHostTime` 的 ppq 也改用积分器（否则插件收到的宿主位置在变速时是错的）；
- MIDI 导出：`µs/四分音符 = 60_000_000 / bpm`（小数精度保留到微秒）；
- tempo 绑定 **默认深度 20%**（`Target.defaultDepth`）——深度 100% 时一条 0→1 缓坡会把速度从 20 拉到 999。

## 三、音频片段的播放速度：**速度与 BPM 解耦**（不改）

现状（有意保持）：

- 片段窗口 = `start_frame + (片段起点步 − 参考步) × step_frames` → **改 BPM 只改"什么时候开始、占多长时间"**；
- 片段**内部**播放速度由音频样式自己的 `speed`（× 采样率比）决定，**与 BPM 无关** → 变速不变调、也不变速度；
- 鼓组采样器层同理（`v.step` 只由 asset ratio × 层 speed 决定）。

### 明确不做（本轮及近期）

1. **播放列表音频片段"实时跟随 BPM 变速"**：技术上要引入"锚定 BPM"并打破现在的
   *无状态按帧映射*（改成逐块累加采样位置），会牵动循环/跳转/暂停语义——不做；
2. **变速不变调（时间伸缩）**：需要 WSOLA / phase vocoder 级别 DSP，且与"逐块变速"
   叠加时极易爆音；将来若要做，**先做离线/固定比例**验证音质再谈实时；
3. **BPM 自动化驱动 VST3 时间相关参数**：VST 宿主 tempo 已随 `params.bpm` 变化
   （`currentHostTime` 每块读），但插件侧是否跟随由插件自己决定，我们不额外处理。
