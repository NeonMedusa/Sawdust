# 线性工作流改造：从「通道机架 + 样式」到「轨道 + Part」

> **状态（2026-11-11）：已实现大半，当前暂停，主线切回 `automation-v1`。**
> 用户判断：线性化剩余工作量≈重写一个 DAW；先把自动化做扎实，做成一个
> “图灵完备的小型 DAW”，比追一个半成品的线性化更划算。
> 本文件保留为**已完成改造的事实记录 + 未完成清单 + 血泪纪律**，随时可续。

---

## 一、已完成（`linear-refactor` 分支，含测试）

### 1.1 数据模型

```zig
Track{ uid: u32, kind: {instrument, audio}, instrument: i32, muted: bool }   // App.tracks
Part{
    track_uid, start, len, offset,
    kind: {midi, audio},                       // 音符 Part / 音频 Part
    notes: ArrayListUnmanaged(Note),           // midi 用（尚未接钢琴窗编辑）
    audio: { style, trim_start, trim_len },    // audio 用（引用 audio_styles）
    selected, muted,
}
```

- **轨道 = 实体**：`ensureTracks(n)` / `trackUidOf(row)` / `trackRowByUid(uid)`；`trackCount() = tracks.len`（无幽灵空行）。
- **一轨 ↔ 一乐器 ↔ 一混音通道**：通道号 = 轨道号 + 1（通道 0 = 主通道）；
  `channelName(ch) = 主通道 / trackName(ch-1)`——**通道名不是独立数据**，不允许单独命名。
- **Part 只认 `track_uid`**：所以整条轨道上下移/删除时，Part 自动跟随，无需逐个改。

### 1.2 已删除的东西

| 删除项 | 说明 |
| --- | --- |
| **通道机架窗口**（`view_rack.zig` 整文件、`RackState`、`WinKind.rack`、工具栏「乐器」按钮） | 职责被 Track 接管；乐器面板仍走「双击轨道头」 |
| 混音台**通道右键菜单**（重命名/删除/上移/下移） | 通道结构跟随轨道；改名请改 Track/乐器名 |
| 轨道右键菜单的「+ 添加 Part」 | Part 由网格左键放置 |
| `trackRemoveInstrument` | 设计上不存在"只删乐器留轨道"；删轨道 = 乐器随轨走 |
| 旧 Clip 的**全部 UI 路径**（绘制/命中/拖动/拉伸/框选/擦除/剪贴板） | 以 `if (false)` 封存；`model.Clip` 本体与旧测试仍在（见未完成） |

### 1.3 Part 交互（与线性工作流对齐）

| 能力 | 状态 |
| --- | --- |
| 点选 / 拖动移动 / 边缘拉伸（5px 热区 + 悬停 ↔ / 十字箭头） | ✅ |
| 重叠：左端升序绘制、命中取最上层、点中沉到同起点组最底层（连点轮换） | ✅ |
| 右键删一个 / 右键空白起手拖动擦除 | ✅ |
| 框选（Ctrl+拖）、向下追加（Ctrl+Shift+拖）、行头按行选 | ✅ |
| Ctrl+单击 = 单选、Ctrl+Shift+单击 = 切换 | ✅ |
| **Ctrl+单击轨道头 = 选中该轨全部 Part**、Ctrl+Shift+单击 = 追加 | ✅ |
| 刻度尺：Ctrl+**按下即清空选区**；Ctrl+拖 = 设循环区并选中区间内 Part | ✅ |
| Del / Ctrl+A / Ctrl+C/V / 剪切（只作用于 Part，剪切板保留轨道号） | ✅ |
| **批量移动**（选区 ≥ 2，拖动期以快照为锚、幂等） | ✅ 见 1.4 |
| 不合格落点（跨类型轨）：**不换轨但横向继续跟随** + 禁止光标 + 松手回滚 | ✅ |
| 双击 **音频 Part** → 波形窗口（目标已改成 Part 下标） | ✅ |
| 双击**音符 Part** → 钢琴窗编辑 `part.notes` | ❌ 未做（最后的大件） |
| 批量拉伸（多选拉边缘） | ❌ 未做 |

### 1.4 批量移动的"结构匹配"（用户设计，已实现）

轨道序列可能是 `乐器/音频/乐器/音频`。选区 = 行0(乐器)+行1(音频)，合法位移是 `{0, 2}`——
**在该轨道表里枚举所有"全组都落在同类轨道"的位移，取离鼠标意图最近的那个**（平局取位移小者＝宁可不动）：

| 锚（按住谁） | 鼠标到 | 意图 d | 结果 |
| --- | --- | --- | --- |
| 乐器 Part(行0) | 行1 | 1 | 不合法 → 取 0（不动） |
| 乐器 Part(行0) | 行2 | 2 | 合法 → 落 行2/3 |
| 音频 Part(行1) | 行2 | 1 | 不合法 → 取 0（留在原位） |
| 音频 Part(行1) | 行3 | 2 | 合法 → 落 行2/3 |

水平方向另有**组级夹**：最左那个撞 0 步则全组停，相对间距不变。

### 1.5 音频（原地改造：音频 Part 就是 Part）

- 发声：`rebuildAudioTable` 读 `parts` 里 `kind == .audio` 的行，通道走 `audioChannelForTrack(轨道行, style)`；
- 绘制：Part 内画波形（`drawAudioPartWave`，异步导入中显示斜纹 + `载入 N%`，真缺失显示「音频缺失」）；
- 放入：音频样式栏单击 → `addAudioPart`；拖文件进窗口 → 落到音频轨即该轨、否则新建音频轨（名 = 文件名）；
- **左边界（唯一差异）**：audio Part 左缘受采样开头限制（`trim_start` 用尽即停，入点随左缘平移），midi Part 无限制；
- 波形窗口目标 = Part 下标（`openWaveForPart`）。

### 1.6 轨道操作

| 操作 | 行为 |
| --- | --- |
| 上移 / 下移 | `swapTrackRows`：**轨道实体整体交换**（uid 随实体走 → Part 自动跟随）+ **混音通道同步换位** + 乐器 `mixer` 字段重建 |
| 删除轨道 | 该轨 Part 全部释放 + 乐器（并修其它轨乐器下标）+ 对应混音通道删除 + 下方上移，**一次到位** |
| 清空轨道 | Part 与旧片段一起清，轨道本体保留 |
| 加轨 | `+ 添加轨道`（标尺行左侧行头列）→ 乐器预设选择器 → `addInstrumentVst3` → `syncTracksToInstruments` 落地成轨 |

> ⚠️ `removeInstrument` **不会**修 `tracks[].instrument`——不修的话 `syncTracksToInstruments`
> 会认为某乐器无轨认领而**立刻新建一行**，表现为"删了一次没消失，要再删一次"（已修）。

### 1.7 历史与存档（已接入 Part / Track）

- `HistoryState` 新增：`parts: []PartSnap` + `part_notes`（音符展平）+ `tracks: []model.Track` + `next_track_uid`；
  五处同改齐活：`captureHistory / freeHistoryState / stateEqualsCurrent / applyHistoryState / freeHistoryState`。
- 之前"移动 Part 不进历史 / 撤销无效"的根因：**快照不含 parts** → 去重判定"无变化"，撤销只恢复 notes/clips。
- `persist.Project` 新增 `tracks / parts / next_track_uid`（`SavedTrack` / `SavedPart{notes...}`）；
  存档往返测试：乐器轨 Part + 音频轨 Part（含 trim）都完整回来。
- 历史标签：加轨显示「添加轨道」（不再是「添加 VST3 乐器」）。

### 1.8 交互细节修复（本轮）

- **浮动窗口点击穿透**：播放列表大量用裸 `util.inRect`（不认层），窗口上的点击会落到 Part / `+ 添加轨道`。
  修法：`draw()` 顶部取 `ui_blocked = ui.input_blocked`，并入 `menu_click` 与 12 处交互入口。
- **右键轨道头误删紧邻 Part**：命中区用了含行头列的 `main_x`，`step_i` 被钳到 0 → 改成只认 `lane_x` 起的内容区。
- **Ctrl+Shift+单击切换失效**：框选更新块同帧用零尺寸矩形把 Part 又选回去 → 加"按下那帧不重算 + 位移 ≥3px 才重算"。
- **Ctrl+Shift+拖 变新建选区**：点空白的"取消选中"分支没判 Ctrl → 加 `!ui.mods_ctrl`。
- **插件丢失提示**：原来在机架"标红"，机架删后搬到**轨道头**（乐器名标红 + 类型字变红「插件丢失」）。

---

## 二、未完成（按建议顺序）

### 2.1 P1：双击音符 Part → 钢琴窗编辑 `part.notes`
- 现在 Part 的 `notes` 恒空，音符仍来自全局 `App.notes` + 样式池（PAT 模式）。
- 需要：钢琴窗上下文从"样式"切成"Part"，坐标 `全局步 = part.start + note.step - part.offset`；
  编辑落盘到 `part.notes`；`selected` 语义独立。

### 2.2 P2：快照/调度按 Part 展开（让 Part 真的发声）
- 现在发声仍靠样式池折叠（`Clip.pattern + offset`）。
- 改成按 Part 展开：`gatherRaw(part)`，事件乐器取 `track.instrument`。

### 2.3 P3：自动化重定向到轨道
- `Target{kind: mixer_vol/mixer_pan/inst_vol/inst_pan, uid}` → `Target{track_uid, vol/pan}`；
  曲线/绑定/链接窗口改成轨道作用域（混音台通道 uid 与轨道 uid 合一）。
- **本轮暂停点**：分支回到自动化后，先在现有（通道 uid）模型上把自动化做扎实。

### 2.4 P4：删样式池
- `Note.pattern`、`pattern_items`、`patternEffectiveLen`、`patternColor`、PAT/SONG 模式区分。
- ⚠️ 用户已改口：**样式栏不必删**，将来可作"资源/原型仓库"（拖出 = 复制），音频也在用 → 保留 `pattern_names`。

### 2.5 P5：删 `Clip` 本体
- 剩余依赖：旧存档读档（`importProjectBody` 的 clips 导入）、~20 个旧测试、`persist.SavedClip`。
- 步骤：先删读档导入 → 再删那批测试 → 最后删结构体让编译器报残留。
- 用户已批准"不考虑旧存档兼容，将来再补迁移代码"。

---

## 三、血泪纪律（务必保留）

1. **文件读写只用内置工具**（`read / write / edit / grep / find / ls`）；禁用 shell/脚本改文件——
   PowerShell/python 的字符串替换**静默 no-op**，本轮多次造成"编译通过但功能没变"。
2. **改完立刻 `grep` 确认落点**，并把关键行贴出来；不要只凭"修改成功"下结论。
3. **裸 `util.inRect` 不认层**：浮动窗口内的点击会穿透。新写的交互一律用 `ui.hitRect`/`ui.hitUI`，
   或显式并入 `ui.input_blocked`。
4. **同一个 `active_id` 命名空间里两套手势会互抢**：谁先判 `== 0` 谁永久胜出（框选曾因此永远开不起来）。
5. **零位移的框选会重算选区**：任何"单击切换选中"都必须配"按下帧不重算 + 位移门槛"。
6. **轨道/乐器/通道三者必须同源改动**：任何只动其中一个的操作都会破坏 1:1（删轨道要删 Part+乐器+通道；
   移动轨道要换通道；`removeInstrument` 不修 `tracks[].instrument` 会触发"删两次"）。
7. **历史/存档"五处同改"**：`persist` / `captureHistory` / `stateEqualsCurrent` / `applyHistoryState` / `freeHistoryState`；
   漏一处就是"有调用但无效"或"内存泄漏"。

---

## 四、分支约定

| 分支 | 内容 |
| --- | --- |
| `main` | 停在 `e9e5697`（A 计划 pull 模型），不含自动化 |
| `automation-v1` | 自动化 v1 完成态（+ 线性化设计稿）；**当前主线** |
| `linear-refactor` | 线性化改造（本文全部内容）；出问题随时 `git checkout automation-v1` |

---

## 五、讨论存档：混放音频与乐器（暂不采用）

结论：**技术上可行**，当前仍按"音频轨 / 乐器轨"分类型。

- 用户对"分类型理由"的逐条回应：自动化目标集并不冲突（音量/声像对两者都生效）；录音可给两个武装开关；
  默认编辑器由 Part 类型决定；点空白默认画音符 Part；冻结是整轨混成音频；PDC 按通道算。
- 我仍留意的三点风险：PDC/延迟账目要按通道而不是按轨道；冻结/解冻簿记；自动化作用域要在 UI 说清。
- 若将来放开，需要写死的规则：`kind` 只决定默认类型与双击编辑器、两个录音武装、冻结=整轨混音+锁、
  音量/声像=轨道作用域而乐器参数=乐器作用域、拖动只按"目标轨存在"校验。
- 样式栏去向（用户提案）：作**资源/原型仓库**，拖进播放列表 = 创建副本（复制而非引用）。**待定未实施。**
