# 工程存档格式与版本迁移——设计文档

> 实现：`src/persist.zig`（序列化）、`src/main.zig`（读写路径）、`src/app.zig`（导出/导入）。
> 迁移流程参考 SkyNet（`C:\Users\32182\Develop\SkyNet`，`src/db.zig` 的
> `probeVersionMismatch` / `migrateIfNeeded` / `backupBeforeMigrate` 模式）。

## 宗旨

- **JSON 文本是承诺**：用户随时可以带着存档脱离 DAW（自己解析、自己改、自己转格式）；
- 未来方向（用户设想）：**默认二进制 + 主动"导入/导出 JSON"双轨**——届时瘦身版 JSON
  即导出格式。本文档的瘦身项与迁移机制对此都兼容。

## 现状事实（file_version = 3）

- 存档 = **带 `whitespace = .indent_2` 的缩进 JSON**（`persist.toJson`）：
  一条音符约 5 行 ≈ 100 字节（`project.saw` 实测）；
- **插件状态 = base64 文本**（`plugin_state` / `plugin_state_ctrl`，+33% 且不可免——JSON 里放不了原始字节）；
- `Note` 已有字段省略的 `jsonStringify`（velocity/pan 为默认值时不写——实测老档可见）；
- `track_names` / `pattern_names` 为**密集-稀疏数组**（填 `""` 到最大命名行号）；
- `track_muted` 已是稀疏列表（`[]i32` 排序）——**其他稀疏化的参照样式**。

## 一、轨道名稀疏化（已拍板：方案 A）

```jsonc
"track_name_rows": [1, 500],     // 与 names 同长、升序、行号唯一
"track_names": ["鼓", "Bass"],   // 只含"用户命名过"的行；空串不允许出现
```

**为什么 A 最干净**（对比对象数组方案 B）：

1. 两个平行数组都是反射序列化器的**原生类型**（`[]i32` + `[]const []const u8`），
   序列化/反序列化零自定义代码；
2. 每条**零元数据开销**（B 每条约多 ~15 字节键名），深行命名的最坏情况从 3.5KB 噪声 → 0；
3. 与 `track_muted` 同型，加载侧"压缩/拆开"逻辑可共用模式。

**不变量（加载时校验，违反则修复/拒绝）**：`rows.len == names.len`、升序、名字非空。
（手改 JSON 的自由度带来的唯一风险就是两数组不同步——文档化 + 加载校验。）

**读取旧档的垫片**（兼容虽不承诺，但此垫片 5 行，建议保留）：无 `track_name_rows`
字段时，把旧密集数组按"跳过空串"派生出行号。

**第二梯队**：`pattern_names` 同样稀疏化（行号 = 样式号；注意样式删除会重编号，需重映射）。

## 二、JSON 瘦身清单（讨论已定，按序实施）

1. **手写序列化器**（推荐首做）：骨架保留缩进、**大数组每条一行紧凑**——
   音符 ≈ 55B、片段 ≈ 60B（现 ~100B），**总量 ≈ -45%**，仍逐行可读可改；
   顺带拿回浮点格式/字段省略/键序的完整控制权（取代逐类型 `jsonStringify` 的拼凑）。
2. **浮点三位小数**（`{d:.3}`）：velocity/pan/volume 的 f32 全精度文本（12 字符）→ 6 字符；
   加载侧本来就有 clamp，三位小数足够。
3. **默认值省略覆盖度补齐**：clip / instrument / mixer 各类型对齐 Note 的做法
   （offset、选中位、muted 等默认值不写；反序列化端 std.json 对缺省字段填默认 ✓）。
4. **base64 插件状态**：JSON 时代接受（+33%）；真解留给未来二进制默认格式。
   **不做 sidecar 旁挂文件**（破坏"单文件带走"）。

## 三、版本迁移（照 SkyNet 模式，**只在打开存档时检测**）

```
打开存档
  └─ 探针读 version（轻量：只取顶层 version 字段，不全量解析）
       ├─ version == file_version        → 正常加载
       ├─ version >  file_version        → 拒绝打开（弹窗："存档版本比程序新"）
       └─ version <  file_version        → 弹窗："检测到旧版存档（vN）。
                                            是否备份并升级？【备份并升级 / 不打开】"
             ├─ 否（不打开）              → 什么都不做（原文件零接触）
             └─ 是 →
                  ① 内存中跑完整条迁移链（注册表 {from, fn} 逐级 v→v+1；缺路径→拒绝）
                  ② 新内容先写为 `<原名>.tmp`（**动原件之前**——写失败则原件未被碰）
                  ③ 备份 = **重命名**原件 → `<原名>.bak.saw`（同目录；占用则 `.bak.2.saw`…）
                  ④ 提示："旧存档已备份为 xxx.bak.saw"；
                  ⑤ 重命名 `.tmp` → 原路径（收尾替换，与③相邻、纯元数据操作）
                  ⑥ 走正常加载路径（clamp/修复照旧）。
```

**为什么备份用重命名而不是复制**（“迁移后写回原路径”前提下，用户拍板）：

- 复制方案 = “读 + **整写一份备份** + 写回”共两份满量 I/O；重命名方案 = “读 + 写 tmp +
  两次重命名”只有**一份满量写**——省一整份文件大小的 I/O（插件重的存档可达数十 MB）；
- 峰值磁盘占用：复制 = 3 份（原/备份/新）、重命名 = 2 份（旧即备份，新在 tmp）；
- **同名替换本来就需要把原来的移开**——重命名把“备份”与“腾位”合为一步；
- 一致性：SkyNet 的 `backupBeforeMigrate` 正是重命名（`<base>.old.db` …），模式同源；
- 失败语义：①②失败 → 原件未动；③之后失败 → 原路径暂时无文件，但 `.tmp`（完整新内容）
  与 `.bak.saw`（完整旧内容）俱在，改名即恢复（窗口 = 两次相邻重命名之间，极小）。
  Windows：同目录重命名有效；文件句柄已在读档后关闭。

**迁移函数准则**：

- 只做**结构升级**（字段搬迁/形状变化），不做业务修复（那是加载路径的事）；
- 每步一个函数、只认识"从 vN 到 vN+1"一件事，可单测（构造 vN 的 `Project` → 断言 vN+1 形状）；
- 迁移链跑完后 `version = file_version` 再验证一遍（防漏步）。

**第一个实例（轨道名稀疏化，v3 → v4）**：旧密集 `track_names`（含空串）→ 派生
`track_name_rows` + 压缩数组；这正是上面"读取垫片"升格成的正式迁移函数。

## 四、未决项（实现时定夺）

- 备份方式：**已定 —— 重命名**（理由见上；与“写回原路径”配套）；
- 迁写目标：**已定 —— 写回原路径**（用户明确同意升级；`.tmp` + 重命名收尾）；
- 对话框形态（现有模态基建沿用：`.save/.cancel` 两键即“备份并升级/不打开”）；
- 探针的轻量实现细节（JSON：扫描顶层 `"version"` 键值，避免全量 `parseFromSlice`）。

## v4 未发布——定型自由度（本轮决定）

- 实测：现存档案中只有**一份真实 v4 文件**（VST示例原件，4.1MB，内部产出、从未发布）；其余全部为 v3（含其两份“- 副本”）。
- 结论：v4 仍是内部版本，定型前可自由改形（密集打包/编码/字段省略都在定型这一刻一次合入），**无需 v4→v5 中间跳版本**。
- 迁移承诺只针对 v1/v2/v3 已发布存档：终版发布时做"任意旧版 → 终版一跳"的弹窗迁移（链式对齐代码可保留，UI 层面是一次操作）。
- 兼容性夹具（真实存档）：
  - tmp/测试工程/VST示例(Vital+SFLT)-lulls[3]v4.saw（**唯一真实 v4**，4.1MB，含 VST 插件状态——定型前最后一个自产 v4 样本）
  - tmp/测试工程/VST示例(Vital+SFLT)-lulls[3]v4 - 副本.saw（其 v3 前身，**含 VST 状态 blob**——v3→终版迁移的真正金夹具）
  - tmp/测试工程/lulls[3].saw（v3）
  - tmp/测试工程/[示例工程]lulls[3]v4.saw（v3，3580 notes，无插件）
- 批次顺序（用户拍板）：① 池化动态 → ② 默认二进制 + 迁移弹窗 → ③ JSON 导入/导出完善（手写序列化器降级为"可读+diff 友好"目标，base64 仅对 JSON 通道有意义）。

## v4 定型审计（实测于 [示例工程]lulls[3]v4.saw，571KB / 3580 notes）与执行计划

### 结论：现在的写法 = "反射全写，几乎无省略"
证据（从真实文件统计）：
- Note：7 个键**全部**写（含默认 velocity=100、pan=64、pattern=0、instrument=0）；
- 乐器：空 preset_name、muted:false、key_mode:0、midi_channel、空 kit{pads:[]} **都写**；
- SynthParam 块：4 个振荡器 × 6 字段 + ADSR + 2 滤波器 **全量写**（kit 层也各带一份）；
- 浮点全精度：`0.3500000238418579` 这种 17 字符怪兽到处是；
- 工程级：`legacy_units_per_bar`（v1 兼容，永不需要再写）、`pattern_count`（names 非空时冗余）都写；
- 唯一的省默认先例：`SavedClip.jsonStringify`（offset=0 不写）——**已有机制，只是没铺开**。
- 更正：plugin_state 早已是 **base64 文本**（b64Encode/state 池），无需再改。样本文件无插件字段
  是因为它保存于 v3 时代，不是省略。

### 瘦身清单（v4 定型，逐结构省默认；机制照抄 SavedClip 的 jsonStringify）
1. **SavedNote**（收益最大，笔记占 79%）：velocity=100 / pan=64 / pattern=0 / instrument=0 不写 → 每条省 ~45 字符；
2. **SavedSynth**：默认值字段不写（osc 缺省项、filter 缺省、ADSR=默认）；浮点 3 位小数格式化；
3. **SavedInstrument**：空串（preset/plugin×3）不写；kind=0/key_mode=0/muted=false 不写；空 kit 不写；
   鼓组（kind=1）不写 synth 块、合成器乐器不写 kit 块；
4. **SavedEffectSlot**：bands 仅 EQ；p 全 0 不写；空串不写；enabled=true/mix=1.0 不写；
5. **SavedMixerChannel**：空 name / muted=false 不写；effect_count 省略（= effects.len，旧档兼容读取保留）；
6. **Project**：legacy_units_per_bar 永不写；pattern_count 仅当 names 为空时写；
   全局浮点（volume 等）3 位小数；
7. 浮点格式化规则：手写 stringify 里统一 `{d:.3}`（f32 存 3 位足够——听感/参数分辨率都远超）；
   需保证 roundtrip 测试用近似比较（现有测试已用 expectApproxEqAbs）。
   预期：571KB → ~250-300KB（优化 JSON）；再去二进制 ~60-80KB。

### 执行顺序（建议）
① **结构级省默认 + 精度**（本清单 1-7，逐结构实现 + 往返测试；= "JSON 瘦身"的真正形态，
   也是 v4 定型动作——定型后 v3→v4 内容不再变）；
② **默认二进制（v5）**：typed/varint/raw blob 逐字节编码；JSON 转为导入/导出通道
   （瘦身后的 JSON 兼作可读/diff 友好的存档格式）；探针按魔数分发；
③ **迁移弹窗流程**：v1/v2/v3 老档 → 终版一跳（探针/备份 .bak.saw/UI）；发布前做，独立于①②。
## 续66：JSON 瘦身（v4 定型）完成——实测 71.9%

- 机制：per-结构 jsonStringify 省默认 + 全 f32 3 位小数（去尾零）；解析侧靠
  既有默认值天然兼容两种形态（旧全量档 / 新瘦身档都能读）。
- 覆盖：SavedNote（默认 pattern/instrument/velocity/pan 省略）、SavedOsc/Filter/Synth、
  SavedInstrument（空串/默认枚举/空 kit 省略；鼓组不写 synth、合成器不写 kit）、
  SavedDrumLayer/Pad/Kit、SavedEqBand（3 位小数）、SavedEffectSlot（bands 非空即写、
  全零 p 省略、空串省略）、SavedMixerChannel（effect_count 省略 = effects.len）、
  Project（legacy_units_per_bar 永不写、pattern_count 仅无名时写、空数组省略）。
- 修正：SavedNote.pattern 补默认 0（省略该字段需解析默认）；preset 顺序测试锚点
  attack → osc（attack 缺省时不再必然出现）。
- 实测（[示例工程]lulls[3]v4.saw）：571,436 → 410,902 字节（71.9%）。
- 剩余大头：**逐字段缩进排版**（每条 note 仍是多行）——"数组每条单行紧凑"是下一个
  大项（~再 -30-40%），归入二进制前的紧凑排版/手写通道；пресets 文件同受益（同结构）。

## 默认值冻结表（v4 定型——**改任一值 = 破坏性格式变更，须版本号+迁移**）

> 写入侧"省默认"与解析侧"缺字段回填"共用同一份默认值——它们是**格式规范的一部分**，
> 永不追随运行时默认（`model.default_velocity`、`SynthParams{}` 等）的改动：
> 运行时默认变了只影响**新建实体**（值与冻结默认不同 → 会被显式写出）；旧档照读冻结默认。
> 实现：velocity/pan/pattern_count 已用 persist 本地常量与 model 解耦。
> 绊线测试：persist.zig「冻结默认值」用例——改动任意默认值会当场红。

| 结构 | 字段 | 冻结默认 |
|---|---|---|
| SavedNote | velocity / pan | 100 / 64（本地常量，与 model 解耦） |
| SavedNote | pattern / instrument | 0 / 0 |
| SavedClip | start / len / offset | 0（bar/len_bars：v1 专用，永不写） |
| SavedOsc | enabled / volume / waveform / unison / unison_detune / detune_power | false / 0.5 / 0 / 1 / 0.05 / 0 |
| SavedFilter | enabled / cutoff | false / 0.7 |
| SavedSynth | attack / decay / sustain / release | 0.05 / 0.30 / 0.70 / 0.30 |
| SavedDrumLayer | kind / gain / source_preset | 0 / 1.0 / ""（空省略） |
| SavedDrumPad | pitch / name / layers | 0 / "" / 空 |
| SavedInstrument | volume / pan / muted / mixer / midi_channel / kind / key_mode | 0.8 / 0.5 / false / 0 / -1 / 0 / 0 |
| SavedInstrument | name / preset_name / plugin_path / plugin_state / plugin_state_ctrl / plugin_cid | ""（空省略） |
| SavedEqBand | freq / gain_db / q | 1000 / 0 / 1.0 |
| SavedEffectSlot | kind / enabled / mix / p | 0 / true / 1.0 / 全 0 |
| SavedMixerChannel | volume / pan / muted | 0.8 / 0.5 / false |
| SavedMixerChannel | effect_count | 0（**派生 = effects.len**；写入省略，加载按 kind 推断） |
| Project | bpm / volume / time_num / time_den | 120 / 0.75 / 4 / 4 |
| Project | steps_per_bar | 96（= units_per_whole，坐标结构常量） |
| Project | pattern_count | 6（本地常量；仅 names 为空时写，其余省略） |
| Project | legacy_units_per_bar | 96（**永不写**——v1 迁移专用，加载用默认即最新） |

护栏（防漂移三件套，已就位）：
1. 本地冻结常量（velocity/pan/pattern_count 与 model 解耦）；
2. 冻结默认值绊线测试（改默认当场红）；
3. 全字段非默认往返测试（手写序列化漏字段当场红）。

待定（记录）：二进制成为默认保存后，JSON **导出**通道是否切"全量显式版"（自包含优先）
——实现=给 writer 加 verbose 开关；届时机拍板（见对话决策记录）。

## 决定（Z+）：省默认范围收窄——只留 Note（用户拍板）

**结论**：省默认**仅限 SavedNote 的四个字段**（pattern/instrument/velocity/pan）；
其余全部结构（Synth/Osc/Filter/鼓组/乐器/EQ/效果/通道/Project）**回退为反射全写**。
（SavedClip 的 offset 省略为既有设计，保留。）

**实测数据（[示例工程] 样本，571,436 字节）**：
| 方案 | 体积 | 代码量 |
|---|---|---|
| 全结构省默认 + 3 位小数 | 410,902（71.9%） | ~300 行手写序列化 |
| **Z+：仅 Note** | **429,687（75.2%）** | **~15 行** |
| 全量反射 | ~571,436（100%） | 0 |

Note 规则用 5% 的代码拿到了 88% 的收益（141.7KB / 160.5KB）——其余结构的省默认
在低频实体上只省 ~19KB，却背 250 行维护面。

**理由（写进决策，防翻案）**：
1. 低频实体（乐器/效果/通道，几十个）本来就没有体积压力；
2. **破坏性更新 × 省默认 = 复杂度爆炸**：将来改内置乐器/效果器的默认参数时，
   省默认的"缺失=默认"语义会把版本迁移搅成一团（用户核心论据）；
3. 二进制（v5）是体积主战场（~60-80KB 量级），JSON 是导出/归档通道——
   自包含（每值显式）对"带走"场景更友好，且 git diff 的收益仅在高基数的 notes 上显著；
4. Note 四字段的省略语义 = MIDI 世界最稳定的默认（100/64/0/0），且已冻死 + 绊线测试。

**保留的护栏**（无论范围如何都有效）：冻结默认值表（解析侧缺字段回填仍依赖它）、
绊线测试、全字段非默认往返测试（deepEq）、Note 四字段的往返回归测试。

## v5 二进制（默认保存）——**已落地**（319/319 绿）

### 格式
- 布局：magic "SAWD" + u8 版本(5) + 载荷；载荷 = **comptime 反射编码**（全量字段，
  零逐结构维护——与 JSON 的 Z+ 策略互补：二进制不做任何省略）。
- 编码：整数 varint（有符号 zigzag）；bool 1B；枚举 varint；f32 原始 4B（本机序，
  仅承诺 Windows x64）；字符串/切片 = varint 长度 + 内容；optional = tag + 载荷。
- **特殊字段**：plugin_state / plugin_state_ctrl（base64 文本）→ 解码为 raw 字节
  （tag 0=空 / 1=raw / 2=非法回退原文）——省 25%。
- 读取严格：magic/版本校验 + 全量消费（尾部垃圾=错误，防截断/错位静默）。

### 接线
- 保存（main 保存路径）：toBinary（**默认**）；打开（loadProjectFromPath）：parseAuto
  （magic 前缀 → 二进制；否则 JSON v1–v4 旧档——**旧档照常直接打开**）。
- JSON 保留为导入/导出通道（toJson/fromJson 原样保留）；presets/settings 仍 JSON。
- fromBinary 返回值与 fromJson 同型（std.json.Parsed，内部 Arena）——调用方零差异。

### 实测
| 文件 | JSON 原 | v5 二进制 | 比例 |
|---|---|---|---|
| [示例工程]（纯 MIDI） | 571,436 | **40,321** | **7.1%** |
| VST示例（Vital+SFLT） | 4,104,098 | **2,693,940** | 65.6%（含 raw 插件状态 ~2.6MB） |

### 测试
- v5 往返（代表性子结构 + 全字段工程 + 空工程；复用 deepEq/expectBinRoundtrip）；
- base64→raw 通道 + 非法回退保真；
- parseAuto 双识别 + magic 严格性（尾部垃圾/版本不符 → 错误）。

### 仍待
- **③ 迁移弹窗流程**（v1/v2/v3 老档打开时探针/备份/提示——发布前做）；
- （可选）JSON 导出/导入 UI 入口；presets 是否二进制化（后话）。

## ③ 迁移弹窗流程 + JSON 出入口——已落地（320/320 绿）

### 打开旧档（③ 迁移流程）
- 判定（`loadProjectFromPath`）：非二进制（无 SAWD magic）→ `probeJsonVersion` 探针：
  - v > 4（JSON 声称过新）→ toast 拒绝；
  - v == 4 → 直接加载（当前 JSON 形态，无需迁移）；
  - **v1–v3 → 弹窗「这是旧版存档（vN），升级为最新格式？」**（备份并升级 / 取消）。
- 确认 = `performUpgrade`：读 → `parseAuto` 内存迁移链 → import → 写 `.tmp` →
  原件**重命名**为 `.bak.saw`（碰撞 `.bak2.saw`…）→ `.tmp` 重命名回原路径 →
  登记路径 / 重置历史基线 / 标记已保存；危险窗口 = 两次相邻重命名之间。
- 取消 = 不打开（原文件不动）。任一步失败 = 保留原件 + 清理 tmp + toast 报错
  （替换失败还会尝试把备份改回原名回滚）。
- 二进制（v5）文件直接加载，无弹窗。

### JSON 出入口（**设置窗口内**——用户拍板：说明有充足宽度）
- 「选项」按钮维持原行为（单击直接开设置窗口，**无下拉**）；
- 设置窗口新增「数据交换」区：「导入 JSON...」「导出 JSON...」两个按钮 +
  两行说明（“JSON：可读文本格式，便于迁移到其他 DAW。导入 = 替换当前工程；导出 = 写出副本。”）；
- 文件菜单保持原样（7 项，无 JSON 项）。
- 导入 = 与"打开"同流程（旧档同样走升级弹窗）；导出 = 写 JSON 副本（可读、diff 友好），
  不改工程路径 / 保存态。

### 待办记录
- **预设二进制化：暂不做**——等出现"存了**一亿个预设**把硬盘存爆"的疯狂用户反馈再议
  （用户拍板，原话记录）。预设仍为 JSON（结构与 persist 同族，将来要切成本很低）。
## v5 → v6：二进制布局版本纪律（2026-10-19 事故）

**事故**：v5 二进制首版（`f4a7960`）之后，`SavedDrumLayer`（层 VST3 字段）、`SavedClip`
（音频片段字段）、`Project`（`audio_styles`）都**追加了字段但没递增 `binary_version`**
→ 10/18 及更早的工程用新代码读取时字节错位，报 `integer does not fit in destination type`
后 panic（GUI 里表现为进程直接退出，无任何提示）。

**规则（不变量）**：任何 `Saved*` / `Project` 字段的增删或调序 —— **必须**递增
`persist.binary_version`，并在 `legacyV5Skip` 同类的兼容表里登记新增字段。

**v6 实现**：
- `binary_version = 6`；
- 读档支持 **v5 旧布局**：`BinReader.legacy_v5` → 按 `legacyV5Skip(T, 字段名)`
  **跳过读取** v5 之后追加的字段（保留声明默认值），从而与旧字节流严格对齐；
- 写档永远写当前版本；测试用 `toBinaryLegacyV5` 生成旧布局字节做回归
  （`persist: v5 旧布局兼容读`）。
- 未知/更高版本 → `error.UnsupportedBinaryVersion`（上层给提示，不再 panic）。
## 存档版本纪律（硬性）

1. **一次提交只升一级**：禁止出现「v5→v6→v7」这种一次提交连跳两级的情况（版本号要能对应到一次可回滚的变更）。
2. **任何 `Saved*` / `Project` 字段增删/调序**都必须：
   - 递增 `persist.binary_version`，并
   - 在同一次提交里把新增字段登记进 `legacySkip(ver, T, field)` 跳过表（保证所有历史版本仍可读）。
3. 预发布期（v6 未对外）可以自由揉捻布局，但**只要有过"用 v6 保存过真实工程"的记录**，之后的改动就必须走第 2 条。

## 升级 = 单向迁移 → **打开时一次性"备份并升级"**

**事实**：旧版本 `fromBinary` 严格匹配版本号（`ver != 5 → UnsupportedBinaryVersion`）。
所以"用新版本保存一次"= **旧版 Sawdust 再也打不开这个工程**（数据不丢，但格式不可回退）。

**决策（用户拍板）**：与 JSON v1–v3 走**同一条**路径——打开旧格式时弹一次窗，
"备份并升级" = **立刻备份 + 立刻改写为当前格式**，然后加载新字节；"取消" = 不打开。
用户只做一次选择，不承担"什么时候会升级/什么时候要备份"的心智负担。

| 来源版本 | 处理 |
|---|---|
| `< 当前版本`（JSON v1–v4 / 二进制 v5） | 弹窗：**备份并升级 / 取消**；确认 → 复制 `<文件名>.saw.v<旧版>.bak`（重名自动加 `.2`/`.3`…）→ 以当前格式重写原文件 → 用新字节加载 |
| `== 当前版本` | 直接打开（零打扰） |
| `> 当前版本` | 拒绝并提示"请使用更新的 Sawdust"（不 panic） |

- 备份失败 / 改写失败 → toast 报错并**不打开**（原文件保持不动），绝不"升级到一半"。
- 备份只做一次；同名备份已存在则加序号，**不覆盖历史备份**。
- JSON v4 也弹窗：字段虽无迁移，但保存后同样变成不可回退的 v6 二进制，性质一致。
