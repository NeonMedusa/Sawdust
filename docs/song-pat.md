# SONG / PAT 双模式（播放域、游标、锚片段与切换语义）

> **本文是这套设计的唯一真源**。改动 `sel.song_mode` / `playback.song_step` /
> `playback.piano_step` / `piano.origin` / 模式切换 / 游标显示之前，先读这里。
> 相关：`docs/scheduler-protocol.md`（快照/pull 调度）、`docs/drag-snap.md`（拖动语义）、
> `docs/pitfalls.md` §《位置不变的传输变化：软切换》《快照模型的“输入”…》（事故记录）。

## 1. 一句话

**同一个工程有两套时间轴**：SONG 是"片段实例拼起来的全曲时间线"，PAT 是"当前样式
自身的循环时间线"。界面能在两者间**保位切换**（播放中不释音、不重击），
其桥梁是**锚片段**——一个"PAT 的局部位置 ⇄ SONG 的全局位置"的换算参照。

## 2. 两个域

| 域 | 播放内容 | 坐标 | 游标字段 |
|---|---|---|---|
| **SONG** | 全部**片段实例**展开（每片段把其样式的音符按 `offset`/`len` 映射进全局步） | 全局步（U=96；4/4 下 96 步/小节） | `playback.song_step` |
| **PAT** | **仅当前样式**（`sel.pattern`）的音符，从局部步 0 开始循环 | 局部步（样式内坐标） | `playback.piano_step` |

- 选择开关：`sel.song_mode`（`true` = SONG，默认）。
- 两个游标**各自持久、互不覆盖**：切模式时"能诚实换算就换算，否则保留各自的旧位置"
  （§7）。默认值都是 0（= 第 1 小节 / 样式开头）。
- 播放推进由**音频采样时钟**（`params.frames_played`）驱动，不由渲染帧驱动；
  绘制用平滑小数步（`cursorStepFrac` / `tickCursorSmooth` / `cursorDisplay`，
  见 §8）。

## 3. 样式的“三个身份”必须对齐

| 字段 | 含义 |
|---|---|
| `sel.pattern` | **选中的样式**——PAT 播放的内容来源、状态栏显示、锚片段校验都用它 |
| `piano.pattern` | **钢琴窗当前显示的样式**（`null` = 钢琴窗未打开） |
| `piano.origin` | **锚片段**（§6），其 `pattern` 必须等于 `sel.pattern` 才算有效 |

**不变量：`piano.pattern == sel.pattern`（当钢琴窗打开时）**。PAT 播放看
`sel.pattern`，钢琴窗画 `piano.pattern`——两者一旦分叉，就会出现
"看到样式2、响的样式1"（历史上真出现过，见 pitfalls）。维护它的入口：

- 样式栏单击/双击：先设 `sel.pattern`，钢琴窗开着就同步 `piano.pattern`（`view_panels`）；
- 双击片段：`openPianoFromClip` **自己**设 `sel.pattern = c.pattern`（自给自足，
  不依赖调用方先点过片段）；
- 删除样式：两者各自钳制（`removePattern`），保持同值。

## 4. 播放内容从哪来：快照（关键！）

音频线程**只读快照**（`snapshot.build(clips, notes, song_mode, pattern, mutes)`）：

- **SONG**：遍历全部片段实例展开事件（片段/轨道/音符静音都在展开时过滤）；
- **PAT**：只取 `notes[pattern == sel.pattern]`（**不看片段**——样式没有片段实例也照播）。

`(song_mode, sel.pattern)` 是**快照的输入**，不是"编辑"。因此：

- 快照只在**编辑/撤销/开工程**时标脏（`snap_dirty`），**切模式与换样式不属于编辑**；
- 所以 `pollSnapshotRebuild` 另外记下这份快照烘的是哪个域/样式
  （`snap_mode` / `snap_pattern`），**与当前选择不一致就重建**——不依赖任何调用点
  记得标脏；
- `switchSongModePreserving` 换域后**当帧就重建**（否则切换后的头一个音频块还是
  旧域事件）；
- 标尺点击直接翻 `sel.song_mode`（不走切换函数）时，靠上面的自愈在帧末生效。

## 5. 锚片段：为什么需要

PAT 的局部步要映射成 SONG 的全局步，必须有"这个样式在歌曲里的哪一次出现"作参照：
同一个样式可能有多个片段实例（第 1 小节、第 5 小节…），局部第 30 步到底指哪一处？
**锚片段 = 你最近指向的那个实例**。

映射公式（`clip.offset` = 片段左缘对应的局部步）：

```
虚拟全局位置(piano_step) = anchor.start − anchor.offset + piano_step
局部步(全局位置 s)       = anchor.offset + (s − anchor.start)     // s 在片段窗口内
```

## 6. 锚片段规则（`piano.origin`，值快照）

| 时机 | 结果 |
|---|---|
| 单击片段 | 该片段成为锚（**值快照**；`model.Clip` 没有 uid） |
| 双击片段 | 同上 + 打开钢琴窗、`sel.pattern` 同步 |
| 换样式（样式栏点选 / 重开钢琴窗） | **离游标最近的该样式片段**（"窗随游标"）；同一样式重开则保留 |
| 锚被**编辑**（拖动/拉伸/批量移动或改长） | `anchorFollow(before, after)` 把锚推进到新值，白环不会跳到别的片段 |
| 拖动/拉伸**预览中** | `patOriginClip()` 比的是"有效值"（预览优先），白环与映射都跟着预览走 |
| 锚失效（片段被删/被改） | 退化为**该样式最左片段**（`leftmostClipFor`） |
| 该样式**没有任何片段实例** | `null` → PAT 里进入"幽灵游标"态（§8） |

**白环（画面标记）**：锚片段画一圈**内缩 1px 的近白**边框（`theme.text`），
与橙色选中环并存（外圈橙 = 选中，内圈白 = 锚）。**SONG 模式也画**——它回答
"切到 PAT 后以哪个片段为参照"；但只在**有锚快照**（你真点过片段）时画，
否则启动时会凭空多一圈（那时锚只是"最左片段"的默认落点）。

> 用近白而非 `theme.accent`：后者与样式1 的片段色是同一个蓝（`patternColor(0)`），
> 画在蓝片段上等于没画；而且同矩形后画会盖掉橙色选中环。

## 7. 模式切换（`switchSongModePreserving`）

**SONG → PAT**

| 条件 | 目标局部步 | 播放中 |
|---|---|---|
| `song_step` 落在锚窗口 `[start, start+len)` 内 | `anchor.offset + (song_step − anchor.start)`（**保位**） | **软切换**（不释音） |
| 窗外 | **锚片段起点** = `anchor.offset` | 硬跳转 |
| 无锚（样式无片段） | 0（= 样式开头，"从头播"） | 硬跳转 |

**PAT → SONG**

| 条件 | 目标全局步 | 播放中 |
|---|---|---|
| 局部步在锚窗口内 | `anchor.start + (piano_step − anchor.offset)`（**保位**） | **软切换** |
| 局部步越出窗口（音符比片段长） | **回绕进窗口**：`anchor.start + @mod(local, len)` | 硬跳转 |
| 无锚 | **不动 `song_step`**（SONG 的游标是它自己的持久位置，切回原地再现） | 硬跳转（重定位到该位置） |

**收尾**：切换后 `cursor_smooth` 用新域真值重播（否则同一帧会按新域读到旧域残影）。

**软切换**（位置不变时）：`markGenSoft(true)` → gen 递增/发布 → 音频**作废旧事件但不释放
声部**——正在响的音符在新域里是同一批音符，off 会重新排进新时间轴；硬跳转才释音
（细节与事故见 `docs/pitfalls.md`《位置不变的传输变化：软切换》）。

## 8. 游标显示

- **SONG**：游标 x 由 `song_step`（播放中为平滑小数步）直接换算像素。
- **PAT**：播放列表画的是**虚拟全局位置** = §5 公式；钢琴卷帘画的是 `piano_step`
  自身（局部坐标）。
- **幽灵游标**：`PAT 且 patOriginClip() == null`（该样式没有任何片段实例）→
  播放列表**不画游标**、视角跟随也**不追**——"没有歌曲位置的 PAT"不该在时间线上
  凭空画一条线。
- **平滑**：`cursorStepFrac` 用音频帧数算子步精度，`tickCursorSmooth` 做前馈 + 一阶收敛
  （吸收音频块量化）；跳转/回跳时直接归位（差 > 1.5 步）。
- 状态栏显示 `SONG/PAT · 样式 N · 轨道 N`（样式号来自 `sel.pattern`）。

## 9. 点片段 = 把 PAT 游标带进那个片段

用户拍板的规则（`App.patCursorIntoClip`，在片段**按下**时调用）：

- 点击前的**显示位置**已在片段窗口内 → **原地不动**（反算新锚下的局部步，画面不跳）；
- 否则 → **片段开头**（局部 = `clip.offset`；对 offset 窗口片段同样精确）；
- **不参与**：SONG 模式（游标归标尺管，点片段只选中/设锚）、音频片段（无样式时间轴）。

⚠ 顺序要求：必须在改 `sel.pattern` / `piano.origin` **之前**调用——"本来在不在窗口里"
要用旧锚推算。

## 10. 标尺点击（显式放置，不做换算）

| 位置 | 行为 |
|---|---|
| 播放列表标尺 | **自动切 SONG**，写 `song_step`（吸附网格；去重：目标变了才跳） |
| 播放列表标尺 + Ctrl 拖动 | 设**SONG** 循环区域（先切 SONG，坐标一致） |
| 钢琴卷帘 SONG 标尺 | 切 SONG；局部 → 全局经**锚**换算（`clipLocalToSong`，超出窗口归位到片段起点） |
| 钢琴卷帘 PAT 标尺 | 切 PAT，直接写 `piano_step`（自由放置） |
| 钢琴卷帘 PAT 标尺 + Ctrl 拖动 | 设 **PAT** 循环区域 |

## 11. 循环区域与自动循环

- 循环区域**按域分开存**：`playback.loop_song`（全局坐标）与 `playback.loop_pat`
  （局部坐标）；`loopRegion()` / `setLoopRegion()` 按当前域取用。
- 播放中每帧 `tickPlaybackLoop()`：
  1. 有循环区域 → 游标到 `loop[1]` 回跳 `loop[0]`；
  2. 否则自动循环：**SONG** 用 `clipsEndStep()`（最后一个片段的右缘，空片段也播满）、
     **PAT** 用 `contentEndStep()`（当前样式音符末尾）；两者为 0 时以一小节为限。

## 12. 视角跟随

播放中跟随只在**非幽灵态**下生效（幽灵游标不追，否则视角会追着第一小节的幻影跑）；
跟随口径 = 内容区（网格区）、软锚定 + 行程耗尽放开，见 `docs/timeline-scrollbar.md`。

## 13. 代码索引

| 位置 | 作用 |
|---|---|
| `App.sel.song_mode` / `Playback.song_step` / `Playback.piano_step` | 域开关与两个游标 |
| `Playback.loop_song` / `loop_pat` | 两套循环区域 |
| `App.switchSongModePreserving` | **唯一**的保位模式切换入口（工具栏/状态栏按钮共用） |
| `App.patOriginClip` | 解析锚（有效值/预览优先；失效→最左；无→null） |
| `App.anchorFollow` | 锚跟随编辑（单拖提交/批量移动/批量拉伸） |
| `App.patTargetLocalStep` | SONG→PAT 的目标局部步 |
| `App.patVirtualSongStepFrac` | PAT 的虚拟全局位置（显示/换算用，不写 `song_step`） |
| `App.patCursorIntoClip` | 点片段 → 游标进入片段 |
| `App.cursorStepFrac` / `tickCursorSmooth` / `cursorDisplay` | 平滑小数步 |
| `App.tickPlaybackLoop` / `contentEndStep` / `clipsEndStep` | 循环与回跳 |
| `App.pollSnapshotRebuild`（`snap_mode` / `snap_pattern`） | 快照域/样式自愈 |
| `App.openPiano` / `openPianoFromClip` / `closePiano` | 钢琴窗打开/关闭与样式同步 |
| `view_playlist`（游标绘制、幽灵态、白环、标尺、片段按下） | 播放列表侧 |
| `view_pianoroll`（双域标尺、锚换算） | 钢琴卷帘侧 |
| `view_panels`（样式栏点选、状态栏） | 样式选择与显示 |

## 14. 已知取舍 / 未覆盖

- **换样式不改游标**：样式栏换样式时局部步保持不变（"同样位置换一个样式看"），
  锚换成"离游标最近的该样式片段"。若新锚窗口不含该局部步，白环与游标会分处两地
  ——这是"保持局部位置"语义的代价，未做强制归位。
- **锚不进历史快照**：撤销一次拖动后，锚仍是拖动后的值 → 与模型对不上 → 退化为
  "该样式最左片段"（白环会跳）。要还原需要把锚纳入历史条目（未做）。
- **PAT 无锚时按局部 0 播**：SONG→PAT 时若该样式没有片段实例，局部步归 0
  （"这个样式从头播"）；反过来 PAT→SONG 无锚时**不动** `song_step`（不对称是故意的：
  PAT 的 0 有语义、SONG 的 0 只是坐标原点）。
- **点片段即定位**：PAT 下按下片段就会重定位游标（拖动片段时游标跟着走）。
  这是"游标永远落在你指向的片段里"的直接推论；若要"只编辑不定位"，得加修饰键或改成松手定位。
- 音频片段、鼓组层、VST3 都不改变上述规则（音频片段不参与锚与游标映射）。

## 15. 手工回归清单

1. 两样式两片段（第 1、2 小节）→ 双击第 2 小节的片段 → 钢琴窗显示样式2 →
   **切 PAT → 播放应响样式2**；PAT 里点样式1 的样式行 → 播放应换成样式1。
2. SONG 游标落在双击的片段内 → 切 PAT 游标保位；游标在别的片段 → 切 PAT 落在
   **锚片段开头**。
3. 样式栏切到**没有任何片段**的样式 → 播放列表游标消失（幽灵态）→ 切回 SONG →
   游标回到**原来的 SONG 位置**（不是第 1 小节）。
4. PAT 里点一个不包含游标的片段 → 游标到它开头；点包含游标的片段 → 不动。
5. 拖动/拉伸白环所在的片段 → 白环全程黏着它；批量移动/改长同样跟随。
6. 播放中按 ⇄ 切换 → 音乐不中断、不重击、音色不错乱。
