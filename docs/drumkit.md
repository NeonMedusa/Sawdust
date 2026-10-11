# 鼓组插件（Drum Kit）设计方案

> 状态：**待拍板**（未实现）。目标：一个乐器搞定整套鼓——钢琴卷帘写音高，
> 音高映射到多个合成器预设/（未来的）音频采样层。前置功能：**合成器预设
> 保存/加载**（本方案第一阶段）。

## 0. 目标与用户故事

现状：kick/snare/hi-hat 是通道机架里三个独立乐器，写歌要来回切乐器。
目标：一个「鼓组」乐器，内部按音高分发：

- 写 MIDI 35（音名约定见 §2）→ 底鼓预设；38 → 军鼓；44 → 踩镲 …
- 每个音高可绑**多个层**（预设/采样叠加——如 kick = 808 本体 + 噪声点击）；
- 钢琴卷帘左上角（琴键上方、小节标尺左侧）加**视图切换**：琴键名 ⇄ 鼓名；
- 全部操作可撤销、随工程保存。

## 1. 总体结构（四块）

1. **合成器预设**（前置）：参数存/取为文件，合成器窗口里选/存。
2. **乐器类型 + 鼓组数据**：`Instrument` 增加 `kind`（synth / drumkit）；
   鼓组 = 音高 → 层列表；层内嵌一份合成器参数（来源预设名仅作记录）。
3. **音频路由**：鼓组乐器渲染"每层一个精简声部池"；音符事件按音高分发。
4. **UI**：钢琴卷帘角落切换按钮 + 键列鼓名；鼓组编辑器（新浮动窗口）。

## 2. 音高约定与 GM 鼓表

**八度约定（需拍板）**：Sawdust 现用科学记法（MIDI 60 = C4 → 35 显示 B1、
38 显示 D2）；你描述的 "B2 / D3 / G#3" 是 FL 约定（60 = C5）。GM 鼓表的
真源是 **MIDI 编号**（35/38/44），八度后缀只是显示。两个选项见 §11。

**GM 鼓表**（35-81，`model.gmDrumName(pitch)` / `gmDrumShortName(pitch)`）：

| 编号 | 标准名 | 键列短名 | 编号 | 标准名 | 键列短名 |
|---|---|---|---|---|---|
| 35 | Acoustic Bass Drum | Kick | 59 | Ride Cymbal 2 | Ride 2 |
| 36 | Bass Drum 1 | Kick 2 | 60 | Hi Bongo | Bongo H |
| 37 | Side Stick | Stick | 61 | Low Bongo | Bongo L |
| 38 | Acoustic Snare | Snare | 62 | Mute Hi Conga | Conga H |
| 39 | Hand Clap | Clap | 63 | Open Hi Conga | Conga M |
| 40 | Electric Snare | Snare 2 | 64 | Low Conga | Conga L |
| 41 | Low Floor Tom | Tom 1 | 65 | High Timbale | Timb H |
| 42 | Closed Hi-Hat | CHH | 66 | Low Timbale | Timb L |
| 43 | High Floor Tom | Tom 2 | 67 | High Agogo | Agogo H |
| 44 | Pedal Hi-Hat | PHH | 68 | Low Agogo | Agogo L |
| 45 | Low Tom | Tom 3 | 69 | Cabasa | Cabasa |
| 46 | Open Hi-Hat | OHH | 70 | Maracas | Maracas |
| 47 | Low-Mid Tom | Tom 4 | 71 | Short Whistle | Whist S |
| 48 | Hi-Mid Tom | Tom 5 | 72 | Long Whistle | Whist L |
| 49 | Crash Cymbal 1 | Crash 1 | 73 | Short Guiro | Guiro S |
| 50 | High Tom | Tom 6 | 74 | Long Guiro | Guiro L |
| 51 | Ride Cymbal 1 | Ride 1 | 75 | Claves | Claves |
| 52 | Chinese Cymbal | China | 76 | Hi Wood Block | Wood H |
| 53 | Ride Bell | Bell | 77 | Low Wood Block | Wood L |
| 54 | Tambourine | Tamb | 78 | Mute Cuica | Cuica M |
| 55 | Splash Cymbal | Splash | 79 | Open Cuica | Cuica O |
| 56 | Cowbell | Cowbell | 80 | Mute Triangle | Tri M |
| 57 | Crash Cymbal 2 | Crash 2 | 81 | Open Triangle | Tri O |
| 58 | Vibraslap | Vibra | | | |

键列宽 90px 放不下全名 → **键列用短名**；全名在鼓组编辑器里显示。
鼓组映射支持**任意音高 0-127**（不止 35-81；UI 第一阶段覆盖 GM 范围）。

## 3. 数据模型

### 3.1 乐器类型（model.zig）

```zig
pub const InstrumentKind = enum(u8) { synth = 0, drumkit = 1 };

pub const Instrument = struct {
    // ...现有字段...
    kind: InstrumentKind = .synth,
    /// 鼓组数据（kind == .drumkit 时非空；App 管理生命周期）
    kit: ?*DrumKit = null,
    /// 合成器（kind == .synth 时使用；鼓组的"本体音色"不用，但保留字段）
    synth: *synth.SynthParams,
};

pub const DrumLayer = struct {
    params: *synth.SynthParams, // 堆分配、地址稳定（音频线程读）
    gain: f32 = 1.0,            // 层内增益（叠加配比）
    preset_name: []u8,          // 来源预设名（展示用；空 = 内置/手调）
};
pub const DrumPad = struct {
    pitch: u8,                  // MIDI 音高（0-127）
    name: []u8,                 // 自定义名（空 = 用 GM 默认）
    layers: std.ArrayListUnmanaged(DrumLayer),
};
pub const DrumKit = struct {
    pads: std.ArrayListUnmanaged(DrumPad), // 按 pitch 升序
};
```

### 3.2 UI → 音频发布（audio.Params）

沿用现有"原子数组 + 每帧 diff 同步"模式：

```zig
pub const kit_max_layers = 32; // 每鼓组层数上限（≈310KB/套，见 §4 泛型声部池）

instrument_kind: [max_instruments]Atomic(u32),          // 0 = synth / 1 = drumkit
kit_state:       [max_instruments]Atomic(?*KitAudioState),
kit_layer_count: [max_instruments]Atomic(u32),
kit_layer_pitch: [max_instruments][kit_max_layers]Atomic(u8),
kit_layer_gain:  [max_instruments][kit_max_layers]Atomic(f32),
kit_layer_params:[max_instruments][kit_max_layers]Atomic(?*SynthParams),
```

### 3.3 音频侧状态（audio.Engine）

```zig
/// 泛型声部池：鼓组层用少声部（32）——省内存（见下）
pub fn SynthType(comptime voices: usize) type { ... } // synth.zig 内部重构
pub const Synth = SynthType(256);                     // 现有乐器不变
pub const KitLayerSynth = SynthType(32);              // 鼓组层

pub const KitAudioState = struct { synths: [kit_max_layers]KitLayerSynth };
```

- **泛型化的理由**：`Voice` 含 `phase[4][16]f32` ≈ 300B/声部；256 声部 ≈ 85KB
  每池。按"每层一个整池"算，32 层 = 2.7MB/套；泛型到 32 声部 → **9.6KB/层、
  32 层 ≈ 310KB/套**。鼓组每层实际同时发声 ≤ 十几（16 垫 + 尾巴）。
- `KitAudioState` 在 UI 线程**按需分配**（乐器首次加层时），指针经
  `params.kit_state` 发布；删除/替换时旧指针进**退役列表**（不释放——与
  `retired_synths` 同一内存安全模式）。

## 4. 音频路由（audio.zig）

- **渲染**（`renderSegment` 乐器循环）：`kind == .synth` → 现路径；
  `kind == .drumkit` → 对每层（`layer_count` 内、params 非空）：
  `synth.render(layer_params, &kit.synths[l], 通道缓冲, ..., layer_gain, true)`
  —— 多层自然叠加进同一通道缓冲（整组走同一调音台链）。
- **事件分发**（`fireSched` 与立即事件路径都要分支）：
  - on：遍历该组所有层，`layer_pitch[l] == ev.pitch` 的层触发 `noteOn`；
  - off：**不查映射，直接对全部层**调 `noteOff(pitch)`——非相关层是无操作；
    这样"音符响着时改映射"不会漏 off（防悬挂，与调音台教训一致）。
- **类型切换边沿**：Engine 记录 `last_kind[i]`；变化时对该乐器两个池都
  `allOff`（防切类型时旧声部悬挂）。
- **键位高亮回传**（`publishSounding`）：鼓组的 sounding 位 = 各层池声部
  的并集。
- **试听**：琴键点击/放置预览走立即事件 → 同分支，天然支持。

## 5. 合成器预设（前置功能）

### 5.1 文件与目录

- 目录：`presets/`（工作目录下；与工程/可执行同层），启动时扫描。
- 格式：`presets/<名字>.sawpreset`，JSON：
  ```json
  { "version": 1, "name": "Kick808", "synth": { ...SavedSynth... } }
  ```
  复用 `persist.SavedSynth` + `exportSynth/importSynth`（现有）。
- 展示名 = 文件名（去掉后缀）；重名文件天然互斥。

### 5.2 UI（合成器窗口顶部加一行）

`[预设 ▾ Kick808] [保存为…] [刷新]`：
- **▾ 下拉**：列出 `app.preset_names`；选中 → 读文件 → `importSynth` 到
  当前乐器 + `commitHistory("加载预设")`（可撤销）；
- **保存为…**：复用文本输入（`TextInput.Target` 加 `.preset_name`）→ 提交后
  置 `app.pending_preset`；
- 文件 IO 全部走 **main 帧末 pending 模式**（App 无 io）：
  ```zig
  pub const PresetAction = union(enum) {
      scan,                                     // 扫描目录
      save: struct { instrument: i32, name: []u8 },
      load: struct { instrument: i32, name_index: usize },
  };
  ```
- 文件名清洗：非法字符（`\ / : * ? " < > |`）换 `_`；长度上限 ~64 字节。

### 5.3 与鼓组的关系

- 鼓组层的"从预设添加"：**内嵌副本**（把预设参数复制进层的 `params`），
  记录 `preset_name` 供展示；提供「重新载入预设」按钮刷新副本。
  **理由**：鼓组自包含（工程存档不依赖外部预设目录；预设删改不悬空）。
- （备选：按名引用。复杂在引用失效与跨机打开——不推荐，见 §11 问题 2。）

## 6. 钢琴卷帘 UI

- **状态**：`PianoState.key_mode: enum { piano, drum } = .piano`（会话态）。
- **切换按钮**：左上角空白格（`main_x..lane_x` × `ruler_y..+ruler_h`，
  90×20px）放小按钮，显示当前模式（`琴键` / `鼓组`），点击切换。
- **键列标签**（`key_mode == .drum`）：每个可见音高一行：
  1. 当前乐器是鼓组且该音高**已映射** → 用垫名（自定义名或 GM 短名）；
  2. 否则在 35-81 → GM 短名；
  3. 其余 → 原音名（照旧只画 C 行）；
  使用 `labelClipped`（放不下就裁剪）；**已映射的行**左侧加 2px 强调条
  （一眼看出套鼓装了什么）。
- **音符块文字**：鼓组视图下,够宽的块显示短鼓名（否则照旧音名）。可选（阶段 4）。
- **不动**：行高/滚动/网格/游标——纯标签层切换，零布局变化。

## 7. 鼓组编辑器（新浮动窗口 view_drumkit.zig）

布局仿调音台（左列表 + 右详情）：

```
┌ 鼓组 — Kick Kit ────────────────────── ×┬
│ 音高列表(35-81,滚动)   │ 选中垫：Kick（35）      │
│  35 Kick      ●已映射  │  名称: [Kick____] 试听  │
│  36 (Kick 2)           │  层:                    │
│  ...                   │   ▸ Kick808    [编辑][×]│
│  44 PHH       ●已映射  │   ▸ Noise Click[编辑][×]│
│                        │  [＋ 从预设添加][＋空层] │
└───────────────────────┴────────────────────────┘
```

- **左**：GM 35-81 全列表（未映射行暗色）；点击选中；`●` 标记已映射；
  底部 `＋ 自定义音高…`（文本输入数字，覆盖 0-127，阶段 3 后置）。
- **右**：垫名（点击改，复用文本输入；空 = GM 默认）；层列表每行：
  `[来源名] [增益滑条] [编辑] [×]`——**编辑**把该层的 `params` 交给合成器
  窗口（`SynthWindow.target` 扩展为联合：绑定乐器 | 绑定鼓组层）。
- 打开方式：机架**双击鼓组乐器** → 开此窗口（合成器窗口不适用鼓组，
  `selectedSynth()` 对鼓组返回 null 时合成器窗口自动隐藏——现有逻辑已如此）。
- 机架"＋"菜单加一项 **「鼓组 (Drum Kit)」**（现有菜单已有占位项可参考）。

## 8. 存档 / 历史 / 撤销

- `persist.SavedInstrument` 增加 `kind: u32 = 0`、`kit: SavedDrumKit = .{}`：
  ```zig
  SavedDrumKit { pads: []SavedDrumPad }
  SavedDrumPad { pitch: u8, name: []const u8, layers: []SavedDrumLayer }
  SavedDrumLayer { synth: SavedSynth, gain: f32, source_preset: []const u8 }
  ```
  旧存档缺字段 → 默认 synth（向后兼容；实验阶段无需升级）。
- `captureHistory` 的乐器快照与 `exportProject` **统一走一个
  `exportInstrument()`**（目前两处各写一份——鼓组需要深拷贝 pads/层，
  必须收拢，防再分叉）。
- 鼓组编辑（加/删层、改名、调增益）→ `commitHistory` 各一条；撤销靠快照恢复。

## 9. 实施阶段

| 阶段 | 内容 | 主要文件 |
|---|---|---|
| **1. 预设** | 文件读写 + 扫描 + 合成器窗口预设行 + 文本输入命名 | persist/app/main/view_synth |
| **2. 数据+音频** | kind/kit 数据、泛型声部池、KitAudioState、渲染/事件/切换/高亮、工程存读 | model/synth/audio/app/persist |
| **3. UI** | 卷帘切换按钮 + 鼓名键列；鼓组编辑器窗口；机架菜单 + 双击 | view_pianoroll/view_drumkit/view_rack |
| **4. 打磨** | 音符块鼓名、非 GM 自定义音高、层声像/微调、套鼓预设（整组存/取）、音频采样（将来） | — |

## 10. 测试计划（各阶段）

- **预设**：`Preset` JSON 往返；文件名清洗纯函数。
- **数据**：加/删垫与层、改名、增益；工程存读往返（含鼓组）；撤销/重做
  恢复鼓组内容；`gmDrumName` 抽查（35/38/44/81）。
- **音频**：音高 35 触发且**仅触发**绑定 35 的层（activeCount 断言）；
  两层同时触发；off 释放；映射改动后 off 不漏（防悬挂）；类型切换释放；
  `publishSounding` 含鼓组层；渲染能量 > 0。
- **UI 纯函数**：键列标签选择逻辑（鼓组垫名 > GM 短名 > 音名）。

## 11. 待拍板

1. **八度约定**：保持科学记法（60 = C4，则 35 = B1）还是改成 FL 约定
   （60 = C5，则 35 = B2——与你的描述一致）？改动只涉及 `pitchName` 的
   八度偏移，全应用统一。
2. **层与预设关系**：内嵌副本（推荐：自包含、无悬空引用）还是按名引用
   （预设改动全局生效，但删除/跨机有失效风险）？
3. **键列短名**（Kick/Snare/CHH…）代替全名（全名放编辑器）——可以吗？
4. **每套鼓层数上限 32**（≈310KB 内存）够用吗？
