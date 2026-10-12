# 鼓组插件（Drum Kit）设计方案

> 状态：**设计已定稿**（未实现；拍板结果见 §11）。目标：一个乐器搞定
> 整套鼓——钢琴卷帘写音高，音高映射到多个合成器预设/（未来的）音频采样层。
> 前置功能：**合成器预设保存/加载**（本方案第一阶段）。

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

**八度约定（已拍板：保持不动）**：MIDI 60 = **C4**（科学记法 SPN）——
学术/多数 DAW（Ableton/Logic/Cubase/Reaper）的标准；FL 用 60 = C5 是
其平台约定。因此 35 显示 B1、38 显示 D2（与 FL 差一个八度属正常差异）。
GM 鼓表的真源是 **MIDI 编号**（35/38/44），八度后缀只是显示。

**GM 鼓表**（35-81，`model.gmDrumName(pitch)` / `gmDrumShortName(pitch)`）：

| 编号 | 标准名 | 短记（备用） | 编号 | 标准名 | 短记（备用） |
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

**键列命名（已拍板）**：优先用 **GM 标准全名**；宽度不够时**中略**——省略
中间、保留两边（如 `Acoustic Bass Drum` → `Acous…Drum`，与资源管理器的
文件名省略同一风格）；表里的短记列仅作**紧凑场景备用**（如编辑器窄栏），
不用于键列。鼓组映射支持**任意音高 0-127**（不止 35-81；UI 第一阶段覆盖
GM 范围）。

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

沿用现有"原子数组 + 每帧同步"模式（实现以 `audio.zig` 为准）：

```zig
pub const kit_max_layers = 16; // 每套鼓的**层槽位上限**（≈155KB/套，见 §3.3）
// 槽位 = 一份合成器参数 + 绑定的音高；垫的层**展平**入槽（垫音高升序、垫内层序）。
// 多槽位同音高 = 多层叠加；整组总层数 ≤ kit_max_layers。

instrument_kind: [max_instruments]Atomic(u32),          // 0 = synth / 1 = drumkit
kit_layer_count: [max_instruments]Atomic(u32),          // 有效槽位数
kit_layer_pitch: [max_instruments][kit_max_layers]Atomic(u32), // 槽位音高（**off 不查它**）
kit_layer_gain:  [max_instruments][kit_max_layers]Atomic(f32),
kit_layer_params:[max_instruments][kit_max_layers]Atomic(?*SynthParams),
```

### 3.3 音频侧状态（audio.Engine）

```zig
/// 泛型声部池：鼓组层用少声部（32）——省内存（见下）
pub fn SynthN(comptime voices: usize) type { ... } // synth.zig 内部重构
pub const Synth = SynthN(256);                     // 现有乐器不变
pub const KitLayerSynth = SynthN(32);              // 鼓组层
```

- **泛型化的理由**：`Voice` 含 `phase[4][16]f32` ≈ 300B/声部；256 声部 ≈ 85KB
  每池。按"每层一个整池"算，16 层 = 1.36MB/套；泛型到 32 声部 → **9.6KB/层、
  16 层 ≈ 155KB/套**。鼓组每层实际同时发声 ≤ 十几（垫齐响 + 尾巴）。
- **实现简化（与初稿不同）**：层声部池改为 `Engine` 启动时**一次性预分配
  大块**（`kit_synths: []KitLayerSynth`，索引 = `i × kit_max_layers + l`，
  共 32×16 ≈ 5MB）——放弃初稿的 `KitAudioState` 按需分配 + 退役链：
  少一整类生命周期/悬挂 bug，且层槽位复用（层数/参数变时旧声部自然
  release，无需释放池）。

## 4. 音频路由（audio.zig）

- **渲染**（`renderSegment` 乐器循环）：`kind == .synth` → 现路径；
  `kind == .drumkit` → 对每层（`layer_count` 内、params 非空）：
  `synth.render(layer_params, &kit.synths[l], 通道缓冲, ..., layer_gain, true)`
  —— 多层自然叠加进同一通道缓冲（整组走同一调音台链）。
- **事件分发**（`dispatchNote`——调度事件 `fireSched` 与立即事件**共用同一函数**）：
  - on：遍历该组所有层，`layer_pitch[l] == ev.pitch` 的层触发 `noteOn`；
  - off：**不查映射，直接对全部层**调 `noteOff(pitch)`——非相关层是无操作；
    这样"音符响着时改映射"不会漏 off（防悬挂，与调音台教训一致）。
- **类型切换边沿**：Engine 记录 `last_kind[i]`；变化时对该乐器两个池都
  `allOff`（防切类型时旧声部悬挂）。
- **键位高亮回传**（`publishSounding`）：鼓组的 sounding 位 = 各层池声部
  的并集。
- **试听**：琴键点击/放置预览走立即事件 → 同分支，天然支持。

## 5. 数据目录与合成器预设（前置功能）

### 5.0 数据根目录（全局约定）

- **位置**：`<exe 目录>/data/`（便携模式——与可执行同层，整个文件夹拷贝即
  迁移）。查找顺序：`<exe>/data` 存在 → 用它；否则 `<cwd>/data` 存在 → 用它
  （开发兜底：从仓库根启动即可用仓库里的 data）；都没有 → **创建于 exe 目录**。
- 开发期提示：预设默认落 `zig-out/bin/data/`——普通重建不丢，但清理/删掉
  `zig-out` 会丢；要放进仓库做版本管理，就先删 `zig-out/bin/data` 并在仓库
  根建 `data/`（走 cwd 兜底）。
- **目录结构**（分类 = **插件类型**（乐器类型），一级目录名；首次运行创建骨架）：

  ```
  data/
  ├─ presets/          # 预设（一级分类 = 插件/乐器类型）
  │   ├─ subtractive/  # 本项目内置的减法合成器（当前唯一）
  │   ├─ fm/ sampler/  # 将来的内置合成器
  │   ├─ vst3/         # 第三方 VST 预设（将来再按插件二级）
  │   └─ drumkit/      # 鼓组整组预设（鼓组也是插件类型）
  └─ config.json       # 全局配置（将来：窗口布局/最近工程等）
  ```

  注：分类 = **插件类型**（谁家的合成器），不是音乐用途（drums/bass/… 是
  用户自己的组织习惯，不是应用约定）；音乐用途将来可作为预设内部的标签
  字段，不占目录层级。第三方插件多了再往下分一级（`vst3/serum/…`）——
  别提前把树做深。

- 规则：
  - 预设文件 = `presets/<插件类型>/<名字>.sawpreset`；**文件名 = 显示名**；
  - 文件内自带 `plugin` 字段（见 §5.1）——加载时校验；**不匹配 → 拒绝**
    （否则把 A 插件的预设灌进 B 合成器 → 参数错乱）；
  - 扫描**列出所有一级子目录**为分类（不限骨架；多一层嵌套不支持——保持
    浏览简单）；只认 `.sawpreset` 后缀，其它文件忽略；
  - 保存重名（**忽略大小写**，Windows 语义）→ 拒绝并提示；
  - 写盘：先写 `<名字>.sawpreset.tmp` 再改名替换（防中断留半截文件）。

### 5.1 预设文件格式

```json
{ "version": 1, "plugin": "subtractive", "synth": { ...SavedSynth... } }
```
复用 `persist.SavedSynth` + `exportSynth/importSynth`（现有）。名字以**文件名**
为准（不存 `name` 字段——少一处真相）；`plugin` = **插件类型标识**（本项目
当前 `"subtractive"`；将来第三方的用插件自身 ID）——加载时校验不匹配则拒绝。

### 5.2 UI：**统一的插件+预设面板**（最终定稿）

一个面板服务四条路（入口不同、面板相同）；**面板完全统一**：任何入口都可点
任意已实装插件——跨插件 = 顺带换插件（乐器本体，一条历史）。

| 入口 | 意图（PresetIntent） | 选中后 |
|---|---|---|
| 乐器窗口「预设 ▾」 | `replace`（目标 = 乐器本体/鼓组层） | 同插件 = 只换音色；跨插件 = 换插件+载音色（乐器本体）；层目标 = 只换该层音色 |
| 机架「＋ 添加乐器」 | `create_instrument` | 新建乐器（任意已实装插件） |
| 机架右键「更换乐器…」 | `change_instrument` | 换插件+音色（保留名字/音量/声像/路由；一条历史） |
| 鼓垫「＋ 添加乐器」 | `create_kit_layer` | 在垫上加一个该插件的乐器（**不列鼓组**——禁自嵌套） |

- **左栏 = 插件类型**（中文显示名）；可选性（`presetCategorySelectable`）：
  **任意入口可选任意已实装插件**；仅两类被拦——未实装插件（FM/VST3）与
  **层上下文的鼓组**（禁自嵌套）；置灰分类点击 toast 说原因。
- **右栏 = 置顶默认伪预设 + 预设文件**：每个插件分类的第一行是
  `（默认音色）/（默认套鼓）/（未实装）`（`preset.defaultPresetLabel`）——
  **空库也能建乐器**；在 replace 语境选它 = 重置音色。默认音色基准 =
  `persist.defaultSavedSynth()`（由 `SynthParams{}` 导出，与新建必然一致；
  **不要**用 `SavedSynth{}`——它的默认是全振荡器关闭/静音，实测被测试戳穿）。
- 标题按意图：`预设库 — 选音色（可换插件）` / `添加乐器` / `更换乐器` /
  `为鼓垫添加乐器`；打开帧不响应点击（`just_opened`，防自关/穿透）。
- **目标（PresetTarget）**：（replace 专用）乐器本体参数 | 鼓组层参数；
  当前插件由目标推导（`presetTargetPlugin`，用于初始分类/展示）。
- **保存为…**（乐器/鼓组窗口）：预填**当前关联的预设名**（全选，输入即替换）；
  直接回车 → 同名时弹**自绘模态“是否覆写”**（Enter = 覆写、Esc = 取消；
  确认后重排保存）。覆写提示写明：“其它已加载它的乐器不受影响（需手动
  重新加载）”——因为预设加载是**副本语义**（见 §5.3）。保存成功后自关联：
  乐器更新 `preset_name`（工程同步），鼓组层更新 `source_preset`。
- **关联名**：`Instrument.preset_name`（同步进 `SavedInstrument`，撤销/重做
  可恢复）+ 层的 `source_preset`——仅为展示/预填标签，**不引用文件**。
- 文件 IO 全部走 **main 帧末 pending 模式**（App 无 io）：
  ```zig
  pub const PresetAction = union(enum) {
      scan,                                         // 扫描 data/presets 目录树
      save: struct { target: PresetTarget, name_buf, name_len },
      load: struct { intent: PresetIntent, cat: usize, choice: PresetChoice },
      //   choice = .default（置顶伪预设）| .preset: usize（第 N 个文件）
  };
  ```
- 名称清洗：非法字符（`\ / : * ? " < > |`）换 `_`；首尾空白裁剪；长度上限
  ~64 字节；空名拒绝。目前只有**减法的预设文件**能载入（鼓组分类的文件 =
  整组套预设，阶段 4）。
- 库不可用（数据目录未就绪）→ 面板不开，toast 提示（面板是建乐器唯一入口）。
- **右键预设行** → `重命名 / 删除…`（弹确认框；删除主按钮红色）。
  重命名走文本输入（预填旧名 + 全选）；仅大小写变化允许（Windows 同一文件），
  与其它预设重名拒绝。**菜单展开时面板其它条目让位**（防穿透）。
- **文件操作不入操作历史**（讨论拍板）：历史 = 工程编辑；预设库是外部
  资源（与“打开/保存工程”同类）；快照恢复不了文件内容（要做得添回收站机制）；
  误删防护 = 确认框 + 副本语义（删了预设，已加载它的乐器照常发声）。

### 5.3 与鼓组的关系

- 鼓组层 = **乐器槽**（见 §7）：层的音色来自“在该层乐器窗口点预设”或
  建层时在面板里选的预设 —— **内嵌副本**（参数复制进层 `params`），记录
  `source_preset`（`插件类型/名字`）供展示。**理由**：鼓组自包含——
  工程存档不依赖外部 data 目录、预设删改不悬空、换机打开不失效。

### 5.4 整组套预设（**已实现**）

- **磁盘**：`data/presets/drumkit/<名字>.sawpreset`——`File.kit` 载荷
  （`SavedDrumKit`：全部墴/层的**自包含副本**）。`preset.saveKit` 写入；
  与音色预设共用原子写/清洗/重名检查。
- **入口**（与音色预设完全统一——同一面板）：
  - 鼓组编辑器标题栏 `[预设 ▾]`：同插件（鼓组）= 加载套鼓；点减法 =
    把该乐器换成减法合成器（统一面板的跨插件行为）。
  - 鼓组编辑器标题栏 `[保存为…]`：存整组（`PresetSaveSource.kit`）；
  - 机架「＋ 添加乐器」/右键「更换乐器…」→ 面板选鼓组分类的预设/默认。
- **置顶默认** = `（默认套鼓）`：已在鼓组上选它 = **重置为空套鼓**
  （与减法“重置音色”对称；可撤销）；从其它类型选它 = 换成空套鼓。
- 加载路径 `main.applyInstrumentChoice`：同类型 → `loadKitInto`；
  跨类型 → `changeInstrumentKind(commit=false)` + 载入 + 一条历史。

## 6. 钢琴卷帘 UI

- **状态**：`Instrument.key_mode: KeyMode`（`piano` / `drum`）——**每乐器独立**、
  随工程保存（`SavedInstrument.key_mode`）；新建鼓组默认 `.drum`，用户可切回。
- **切换按钮**：左上角空白格（`main_x..lane_x` × `ruler_y..+ruler_h`，
  90×20px）放**分段式**小按钮（左「琴键」右「鼓组」，当前模式强调色），
  点击切换选中乐器的模式；无乐器时无操作。
- **键列标签**（`key_mode == .drum`）：每个可见音高一行：
  1. 当前乐器是鼓组且该音高**已映射** → 用垫名（自定义名或 GM 标准名）；
  2. 否则在 35-81 → GM 标准名；
  3. 其余 → 原音名（照旧只画 C 行）；
  文本超宽用**中略**（省略中间、保留两边；`view_util.middleEllipsis`）；太窄
  （连最小形式都放不下）就不画；行高 < 12px 不画文字。**已映射的行**（= 该
  音高有垫**且至少有一层**——空垫不算，`DrumKit.isMapped`）左侧加 2px
  强调条。标签在行内**垂直居中**。
- **鼓组模式不用钢琴黑白键**（用户反馈：白键底 + 已映射垫的亮字对比度太低；
  `view_pianoroll.keyRowStyle` 纯函数）：键列改成与鼓组编辑器左列表一致的
  “槽位列表”样式——普通行 = 底色 + 暗字（GM 名可读）；已映射行 =
  提亮底（`slider_track`）+ 亮字 + 强调条；发声中/试听 = 强调色底。
  注：**音符区的黑键行深浅交错保留**（含鼓组模式）——它是有用的行定位
  参考线，与钢琴语义无关（用户反馈确认）。钢琴模式键列不变。
- **音符块文字**：鼓组视图下，够宽的块显示鼓名（标准名/垫名，超宽中略；
  现有"放不下就不画"规则不变）。可选（阶段 4）。
- **不动**：行高/滚动/网格/游标——纯标签层切换，零布局变化。

## 7. 鼓组编辑器（view_drumkit.zig；**已实现**）

浮动窗口（拖动标题/右下角缩放/点内置顶/× 关闭；标题栏右侧显示「层 n/16」）：

```
┌ 鼓组 — Kick Kit ────────────── 层 3/16 ×┐
│ 35 Kick          ●│ 垫 35 · Kick             │
│ 36 Bass Drum 1     │ 名称 [Kick____] [试听]   │
│ …（GM 35-81 ∪      │ 层                       │
│   已映射音高）      │  1 Kick808  增益 100% [编辑][×]│
│                    │  2 （手调） 增益  60% [编辑][×]│
│                    │ [＋ 从预设添加][＋空层] │
└───────────────────┴─────────────────────────┘
```

- **左**：GM 35-81 **∪ 全部已映射音高**（升序合并——MIDI 导入的自定义
  音高也能编辑）；未映射行暗色；已映射行左缘强调条 + 右端 ●；点击选中；
  带滚动条。
- **右**：垫名（点击就地改名，复用文本输入；**空名 = 清除自定义名**，
  回退 GM/音名）；`[试听]` **按住响、松开/移出停**（与琴键试听同一手感，
  走 `auditionOnInst`——绑定本乐器，不依赖当前选择）；层列表每行：
  序号 + `减法合成器 · 预设名`（无预设 = 「（默认音色）」）+ 增益上下拖动 +
  `[编辑]` + `[×]`（带滚动条）；
  - **层 = 乐器槽**：`DrumLayer.kind: LayerKind`（目前仅 `.subtractive`）；
    一个垫可叠多个乐器（保留 kick 本体 + click 音这类用法）。
  - **编辑**：把该层 `params` 交给合成器窗口（`SynthWindow.target` 改为
    联合：绑定乐器 | 绑定鼓组层）；标题显示「乐器 · 垫名 层N」；
    预设按钮落点也随目标（「预设 ▾」→ 按插件限定的浏览器 → 加载 = 替换
    该层音色 + 记来源名）。**双击层行（名称区）同效**——与机架“双击乐器名”
    同一习惯；双击区避开右侧增益/编辑/× 控件。
  - **增益**：拖动实时生效、松手 coalesce 提交历史。
  - 层删除/添加/改名 → `commitHistory` 各一条（撤销靠快照恢复）。
- **底部**：`[＋ 添加乐器]` → 打开**预设面板**（`create_kit_layer` 意图；
  面板里选任意已实装插件+音色，或选置顶默认；不列鼓组——禁自嵌套）。
  添加成功后**自动打开该层乐器窗口**（用户顺势点「预设 ▾」）。
- 打开方式：机架**双击鼓组乐器** → 开此窗口（同时同步选择，试听路由）；
  乐器被删/类型变更 → 自动关闭（与合成器窗口同一习惯）。
- 语义同键列：左列表的 `●` = **有层才算已映射**（空垫不亮——用户反馈：
  清空层后不该还亮）。**无名空垫**在层清空/清名后**自动移除**
  （`pruneEmptyPad`；有名空垫保留——名字是用户信息；均可撤销）。
- 机架侧：「＋ 添加乐器」与右键「更换乐器…」都直接打开同一个预设面板；
  鼓组行与合成器行外观一致（不加徐标——已按用户反馈剔除）。
- `＋ 自定义音高…`（范围外音符垫的捷径）**未做**（阶段 4；左列表已能
  编辑所有已存在的自定义音高垫）。

## 8. 存档 / 历史 / 撤销

- `persist.SavedInstrument` 增加 `kind: u32 = 0`、`key_mode: u32 = 0`、
  `kit: SavedDrumKit = .{}`：
  ```zig
  SavedDrumKit { pads: []SavedDrumPad }
  SavedDrumPad { pitch: u8, name: []const u8, layers: []SavedDrumLayer }
  SavedDrumLayer { kind: u32 = 0, synth: SavedSynth, gain: f32, source_preset: []const u8 }
  SavedInstrument { …, kind, key_mode, preset_name, kit }
  ```
  旧存档缺字段 → 默认 synth/钢琴键列/减法层（向后兼容；实验阶段无需升级）；
  未识别的层 `kind`（未来存档）→ 退回减法（现阶段唯一引擎）。
- `captureHistory` 的乐器快照与 `exportProject` **统一走一个
  `exportInstrument()`**（已收拢——防止两处各写一份、鼓组深拷贝分叉）；
  释放侧对称收拢到 `freeSavedInstrument()`。
- 鼓组编辑（加/删层、改名、调增益、预设加载/保存）→ `commitHistory` 各一条；
  撤销靠快照恢复（`stateEqualsCurrent` 含 kit 内容比较，否则编辑会被判
  “无变化”而丢历史）。

## 9. 实施阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| **1. 预设** | 文件读写 + 扫描 + 合成器窗口预设行 + 文本输入命名 | ✅ |
| **2. 数据+音频** | kind/kit 数据、泛型声部池、预分配层声部池、渲染/事件/切换/高亮、工程存读 | ✅ |
| **3. UI** | 卷帘分段切换 + 鼓名键列；鼓组编辑器窗口；机架菜单 + 双击 +「更换乐器」；
预设按插件限定（浏览器只列当前插件）；垫层 = 乐器槽（＋ 添加乐器） | ✅ |
| **4. 打磨** | 音符块鼓名、非 GM 自定义音高（`＋自定义音高…`）、层声像/微调、
**套鼓整组预设 ✅**、采样器 | — |

## 10. 测试计划（各阶段）

- **预设**：`Preset` JSON 往返；文件名清洗纯函数。
- **数据**：加/删垫与层、改名（含空名清除/文本输入提交）、增益；工程存读
  往返（含鼓组、kind、key_mode）；撤销/重做恢复鼓组内容；`gmDrumName`
  抽查（35/38/44/81）；垫插入保持升序；全组 16 槽位上限。
- **音频**：音高 35 触发且**仅触发**绑定 35 的层（activeCount 断言）；
  两层同时触发；off 释放；映射改动后 off 不漏（防悬挂）；类型切换释放；
  `publishSounding` 含鼓组层；渲染能量 > 0；层增益 ∝ 能量。
- **UI 纯函数**：键列标签选择逻辑（鼓组垫名 > GM 标准名 > 音名，含每乐器
  模式）；中略函数（省略中间、保留两边；边界：太短不省、最小长度不足不画）。
- **编辑器**：预设目标 `eql`/解析（失效层/越界→null）；窗口绑定（打开选首个
  已映射垫；删前移/删绑定关窗）。

## 11. 已拍板（原待拍板项）

1. **八度约定**：保持科学记法 **60 = C4**（学术/多数 DAW 标准；FL 的 C5
   是其平台约定）。35 显示 B1——与 FL 差一个八度属正常现象。
2. **层与预设关系**：**内嵌副本**（自包含；工程不依赖 data 目录）。
3. **键列命名**：GM **标准全名** + 中略（省略中间、保留两边）；短记仅备用。
4. **每套鼓层数上限**：**16**（≈155KB/套；槽位 = 一份参数 + 绑定音高，
   垫的层展平入槽，多槽位可同音高叠加）。
5. **数据目录**：`<exe>/data/`（便携；cwd 兜底），分类 = `presets/` 一级
   子目录、**按插件类型分**（`subtractive` / `drumkit` / 将来的 `fm`、`vst3`…；
   见 §5.0）。预设文件自带 `plugin` 字段，加载时校验。
6. **键列模式归属**（后续修订）：**每乐器独立**（`Instrument.key_mode`）
   且随工程保存——不全局共享；新建鼓组默认鼓名视图。
7. **预设与插件的关系**（最终拍板）：**面板完全统一**——任何入口（「预设 ▾」
   / 「＋ 添加乐器」/「更换乐器…」/ 鼓垫加乐器）都开同一个面板，都能选任意
   已实装插件；**跨插件 = 顺带换插件**（乐器本体，一条历史；名字/音量/
   声像/路由保留）；层目标只换该层音色（层目前仅减法）。仅两类被拦：
   未实装插件、层上下文的鼓组（禁自嵌套）。（早期曾定“同插件限定”，
   后经讨论改为统一——少一道规则、少一步操作。）
8. **鼓垫 = 乐器槽**：层列表即乐器列表，入口统一为「＋ 添加乐器」（打开
   **同一个预设面板**）；一个垫可叠多个乐器；**垫内不许再嵌鼓组**（禁自嵌套）。
   采样器落地时每垫一个采样器实例即自然支持。
9. **置顶默认伪预设**：每个插件分类第一行 `（默认…）`，解决“空库也能建
   乐器/重置音色”；基准 = `defaultSavedSynth()`（与新建同源；测试防分叉）。
10. **整组套预设**（阶段 4 首批）：`drumkit` 分类 = 整组套预设
   （`File.kit` 自包含副本，加载不依赖层来源预设）；封存/加载入口与音色
   预设完全统一（编辑器标题栏「预设 ▾ / 保存为…」+ 面板全局可用）；
   已是鼓组时选「（默认套鼓）」= 重置为空套鼓。
11. **覆写语义**（用户讨论拍板）：预设加载是**副本**（不存在活引用）——
   覆写文件不会影响其它已加载它的乐器（**重启后也不会**：工程存内嵌副本）；
   要同步需手动重新加载。覆写确认框里会写明这一点。若将来需要批量同步，
   做成显式动作（“应用到所有使用该预设的乐器”），不做隐式联动。
12. **预设库文件操作（重命名/删除）不进操作历史**（讨论拍板）：理由同
   上——外部资源不混入工程撤销栈；防护 = 删除确认框 + 副本语义。
