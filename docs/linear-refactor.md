# 线性工作流改造：从「通道机架 + 样式」到「轨道 + 片段」（线性 DAW 风格）

> 状态：**设计稿**（未实现）。目标是把 Sawdust 从「通道机架 + 样式池」改成
> 线性 DAW 式「**轨道 = 乐器 = 一条音轨**」的工作流。
> 本文先讲清参考 DAW 的事实、目标模型、与现状的字段级映射、分期计划与风险。

---

## 一、两种主流做法（先对齐事实）

### 甲：轨道即容器（线性 DAW）
- 轨道列表是**唯一的组织中心**，轨类型包括 `Instrument` / `MIDI` / `Audio` / `Group` / `FX` / `Folder`。
- **Instrument Track**：轨道**自带**一个 VSTi，MIDI 部件（MIDI Part）直接放在该轨上，音符发给该轨的乐器。
- 老的 **MIDI Track → 路由到某个 VSTi 通道** 模型仍然存在（一个多音色乐器可被多条 MIDI 轨共用），
  但日常用 Instrument Track 更省事：**一轨一乐器**，不需要机架概念。
- 部件（Part）是**独立对象**：有自己的起点/长度和音符；复制默认是**独立副本**，也支持共享副本。
- 自动化（envelope）挂在轨道上，目标是该轨的参数（音量/声像/发送/插件参数）。

### 乙：通道机架 + 样式（非线性格栅式 DAW）
- Song Editor 里每条轨道**独占一个乐器**（track-exclusive instrument），轨道上没有“通道机架”这种中间层。
- 片段（clip）放在轨道上，片段里能直接编辑音符；老的 BB Pattern 也被“片段化”，本质仍归该轨道。
- 混音器通道由轨道派生，轨道头部就能改乐器、音量、声像。

### 结论（对我们的意义）
“**砍掉机架、乐器进轨道头、一轨一乐器、音符只属于该轨**”是**完全主流**的做法，
不是偏门设计；而且我们现有的数据模型其实已经**半线性**了：
- 已经有 `Clip{track, start, len, ...}`（片段在轨道上）；
- 已经有 `track_names`；
- 已经有音频片段（`audio_style`）；
- 通道机架（`instruments` + `instrument_order`）反而是“多出来的那一层”。

---

## 二、目标模型

```
Track（轨道） ──1:1── Instrument（乐器：内置合成器 / 鼓组 / VSTi / 音频轨无乐器）
   │  uid（稳定身份，自动化绑定用）
   │  name / height / muted / solo
   │
   ├── Parts（片段，按 start 排序）
   │      Part{ start(全局步), len, notes:[]Note, offset }
   │      注：即线性 DAW 的 MIDI Part；同名“样式”概念若保留，只作为**可复用的 Part 模板**
   │
   ├── Automation（自动化曲线绑定，目标 = 本轨的 vol / pan / …）
   │
   └── Channel（调音台通道，与轨道 1:1 派生；EQ/效果器/发送挂这里）

Note{ step(局部), len, pitch, velocity, pan }   ← **不再带 `instrument`/`pattern` 字段**
```

要点：
1. **音符的归属从“样式”变成“Part”**：`Note.pattern` → `Note` 属于 `Part`（`Part.notes`）。
2. **音符的乐器从“音符字段”变成“所在轨道”**：`Note.instrument` 删除，事件生成时取 `track.instrument`。
3. **轨道 = 混音通道**：`Track.uid` 同时用于自动化目标与通道映射，`Instrument.mixer` 字段删除
   （不再需要“乐器路由到某个通道”——它本来就在自己轨道的通道上）。
4. **机架窗口删除**；乐器选择/更换移到轨道头（点轨道头的乐器名 → 弹出选择器：合成器/鼓组/VSTi）。
5. 调音台仍然保留（它是混音视图，不是“组织层”）。

### 为什么这样可以砍掉很多复杂度

| 现状复杂度 | 改造后 |
| --- | --- |
| `pattern` 池 + `clip.pattern/offset` 窗口折叠（局部↔全局坐标换算） | Part 自带音符，一步到位（坐标换算只剩 `start` 一个偏移） |
| `Note.instrument` 与机架槽位、`instrument_order`、`inst.mixer` 路由 | 轨道自带乐器，无路由 |
| 自动化要区分 `mixer_vol` / `inst_vol` 两套目标 | 只剩 `track_vol / track_pan`（各一条轨道参数） |
| 快照要“按片段实例 × 样式”展开 | 按 Part 顺序展开即可（每个 Part 一次） |
| 两个窗口（机架 / 播放列表）都要维护乐器顺序 | 轨道顺序即乐器顺序 |

---

## 三、字段级映射（现状 → 目标）

| 现状 | 目标 | 备注 |
| --- | --- | --- |
| `App.notes: []Note`（共享池，按 `pattern` 分组） | `Track.parts[i].notes: []Note` | 迁移时按 `(pattern, clip.track)` 归并；**跨轨共享样式的音符会被复制多份**（见 Q1） |
| `Clip{track, start, len, pattern, offset}` | `Part{start, len, offset, notes}`（属于 Track） | `track` 字段消失（隐含在所属 Track） |
| `App.pattern_items`（样式名） | 若保留“可复用 Part”：`Part.template_name`；否则删除 | 见 Q1 |
| `Note.instrument` | 删除（取 `track.instrument`） | 迁移时按现有 `clip.track` 的乐器填 |
| `App.instruments` + `instrument_order` | `Track.instrument`（每条轨道一个） | 机架窗口删除 |
| `Instrument.mixer` | 删除（通道 = 轨道） | 混音台通道与轨道 1:1 |
| `App.track_names: HashMap(i32,[]u8)` | `Track.name` | 轨道变成实体，不再是“行号” |
| `mixer_channels_state` | `Track.channel`（或保留独立数组，用 uid 关联） | 见 Q3 |
| 自动化 `Target{kind, uid}`（`mixer_*`/`inst_*`） | `Target{track_uid, kind: {vol, pan, send…}}` | 一条轨道一组参数，两个 uid 合一 |
| 音频片段 `audio_style` | `Track.kind = .audio` 的 Part（引用音频资源） | 音频轨没有乐器 |

---

## 四、分期计划（每期都能编译 + 跑测试 + 手动验证）

| 期 | 内容 | 验收 | 风险 |
| --- | --- | --- | --- |
| **P0 轨道实体化** | 新增 `Track{uid, name, height, muted, instrument_slot, channel_uid}`；`clips` 改为按 `track_uid` 归属；`track_names` 并入 | 现有功能不变（轨道只是“有身份的行走”） | 低 |
| **P1 音符进 Part** | 新增 `Part{start,len,offset,notes}`；`Note` 去掉 `pattern`；坐标换算简化为 `Step = part.start + note.step − part.offset`；播放列表/钢琴窗改读写 Part | 编辑/播放/复制粘贴/撤销全绿 | 中（涉及历史/存档） |
| **P2 乐器进轨道** | `Track.instrument`（内置乐器/VSTi/鼓组）；删除 `Note.instrument`、`Instrument.mixer`、`instrument_order`；机架窗口只读或移除 | 一轨一乐器可发声、可换乐器、可静音 | 中（音频侧事件取乐器来源） |
| **P3 自动化重定向** | `Target{track_uid, vol/pan}`；曲线/绑定改成轨道作用域；`mixer_vol/inst_vol` 合并 | 现有自动化行为不变，语义更简单 | 低（自动化刚重写过） |
| **P4 删机架 + UI 收敛** | 删除机架窗口、`+ 添加乐器` 移到轨道头；播放列表 = 唯一组织视图；样式选择器 UI 简化 | 全流程可用：加轨 → 选乐器 → 画音符 → 混音 | 中（UI 改动面大） |
| **P5 存档/历史收口** | 新格式 + `introducedVersion` 迁移；旧工程按 P1/P2 规则转换 | 旧工程能打开；5 处同改纪律 | **高**（数据不可逆，必须先备份） |

> 建议顺序就是 P0→P5，每期一个提交；**P5 之前不要动存档格式**，先用内存态 + 兼容读取。

---

## 五、主要风险与对策

| 风险 | 对策 |
| --- | --- |
| 跨轨共享样式（现在一个样式可以被多条轨道引用） | 见 Q1；推荐“迁移时复制成独立 Part”，之后用「共享 Part」可选功能恢复 |
| 音符里带乐器（同一轨道内多乐器） | 迁移时按 `Note.instrument` 拆成多条轨道（推荐），或保留为轨道内子音色（不推荐） |
| 历史/存档要动 5 处（`captureHistory/stateEqualsCurrent/applyHistoryState/freeHistoryState/persist`） | P5 一次做完；在此之前**不写入新字段到存档** |
| 音频侧事件来源（`snapshot` 现在按 `pattern` 展开） | P1 后改成按 Part 展开：`gatherRaw(part)` |
| 自动化目标改为 track_uid | 轨道 uid 稳定（同现在的 channel uid 做法），删除轨道时清理绑定 |

---

## 六、需要拍板的问题

**Q1. 样式（pattern）概念怎么处理？**
- (a) **彻底线性**：样式消失，只剩 Part（推荐；最干净，迁移时跨轨共享的音符复制多份）
- (b) 保留“样式”作为**可复用 Part 模板**（共享 Part / 原型 pattern）：`Part.template_id`
- (c) 保留样式池但只允许**同轨**引用

**Q2. 一条轨道能否有多个乐器？**
- 推荐：**不能**（一轨一乐器）。要多个乐器就多开轨道——这也是线性 DAW 的乐器轨语义。

**Q3. 调音台通道与轨道的关系？**
- (a) **1:1**：每条轨道一个通道，轨道头即通道条（推荐；`Target` 从两套 uid 变一套）
- (b) 独立：通道仍可自由增删、轨道可路由到任意通道（更像“轨道 → 输出路由”的线性 DAW）

**Q4. 音频轨怎么进来？**
- 推荐：`Track.kind = .audio`，成员是音频片段；没有乐器、没有钢琴窗。

**Q5. 鼓组/采样器怎么算？**
- 推荐：仍是乐器类型（`Track.kind = .instrument`，乐器 = 鼓组），钢琴窗显示鼓垫模式。

---

## 七、给用户的迁移建议

1. 先做 **P0+P1**（轨道实体 + Part 化），这期**不改存档**、不改 UI 布局，只在内存里换模型，
   用现有 369 个测试兜底；做完后“线性化”的地基就有了。
2. **P2** 把乐器搬进轨道，这是用户感知最大的一步（机架消失一半）。
3. **P4** 收尾 UI，再谈存档格式（P5）。
4. 每期结束留一次手动验证清单（加轨/换乐器/画音符/自动化/混音/撤销/读档）。
