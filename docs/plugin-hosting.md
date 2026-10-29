# VST3 宿主实现记录（阶段 1–5 已完成）

> 结论先行：**能接，且已接完**——效果器 / 乐器（含多输出 VSTi）全链路落地：
> 加载、参数编辑、插件界面、状态存档与撤销、扫描管理器 + 预设浏览器。
> 本文档保留调研结论（§1–2）、实现阶段账（§3）、互操作坑与已知边界（§4）。

## 1. 关键事实（2025 现状）

| 事实 | 说明 |
|---|---|
| **VST3 SDK 已转 MIT** | 2025 年起 Steinberg 把 VST3/ASIO SDK 改为 **MIT 许可**；原 GPLv3 + 专有双授权**不再提供**。MIT 项目（本项目）可直接使用，无传染风险 |
| **Zig 侧绑定已存在** | `zig-vst3`（joshburgess）：**Zig 0.16**（与本项目同版本）、**MIT**、提供 VST3 **COM 接口的原始 Zig 绑定** + 插件侧框架 + **host-side test helpers**；钉版 SDK `v3.8.0_build_66`，CI 覆盖 Win/Linux/macOS |
| **GUI 挂载机制明确** | VST3 编辑器 = `IEditController::createView("editor")` → `IPlugView::attached(父 HWND, "HWND")`。插件 GUI 是**独立子窗口**（通常插件自建 HWND 挂到宿主窗口下） |
| GPL 老坑不复存在 | 仍可选 CLAP（MIT、纯 C ABI）作补充，但它主要是插件"易实现"友好；**宿主侧 VST3 绑定生态已足够**（且 VST3 插件存量 >> CLAP） |

## 2. 与本项目架构的适配分析

### 2.1 音频链 —— 契合（按"内建效果器"同款插入）

- 插槽点现成：`audio.processChannelChain` 已按效果器 `kind` 分派；
  插件可作为新 kind（如 `plugin`）挂进每通道效果链，块大小 ≤4096 帧（VST3
  支持任意块长，process 里按我们的块跑）。
- **实例发布有先例**：`params.synth_ptrs`（把对象指针经原子发布给音频线程）
  与 `engine.effect_p`（参数原子数组）都是现成模式。
- **线程安全**：插件在 UI 线程加载/创建；音频线程只调用 process；
  删除走"退役列表"（乐器已有先例：`removeInstrument` 不立即释放指针）。
- 已知缺口（先标注、后可补）：
  - **延迟补偿**：插件的 latency（`IAudioProcessor::getLatencySamples`）需要在
    调度/回放对齐上补偿——当前框架无此机制；
  - **崩溃隔离**：进程内加载 = 插件崩则宿主崩（可选未来做独立音频进程，
    属重架构，不在 MVP）。

### 2.2 UI 渲染 —— **不受现有软渲染引擎限制**

- 插件编辑器**不经过我们的像素渲染管线**：它是独立 HWND，由插件自己绘制、
  自己收消息，我们只负责：
  1. 提供父窗口句柄（`window.zig` 已有 `win.hwnd`，filedialog 也在用）；
  2. `IPlugView::attached(hwnd_of_our_window / 子容器)` 挂载 + `getSize` 定尺寸；
  3. 关闭/隐藏时 `removed()` 并清引用。
- 我们的窗口是 Win32 直调（无框架），挂子窗口是原生操作，**不冲突**；
  待编辑器窗口出现后，它与我们的自绘界面是"叠在窗口树上的两块矩形"。
- 小成本项：插件窗口的 resize/focus 通知、与浮动窗口的 z 序观感协调。

### 2.3 存档与参数

- 效果器槽扩展：插件路径 + 插件状态（`IComponent::getState` 的字节流，
  base64 进 `.saw`），照 `SavedEffectSlot.p` 的兼容思路加字段（旧档缺失 → 默认）；
- 参数显示：`IEditController` 枚举参数（名/值/单位）→ 可先只读显示；
  参数自动化（曲线驱动）属远期（与现有"自动化未做"一致）。

### 2.4 乐器插件（VSTi）—— 后置

- 需要把我们的音符事件转 VST3 事件列表（note on/off），并映射输出总线；
  架构上可行但与"效果器 MVP"分阶段做，先打通最简单闭环。

## 3. 建议路线（分阶段）

1. **阶段 1：绑定与探测（零风险探路）** ✅ 已完成：`src/vstscan.zig` 扫描工具；submodule `libs/zig-vst3`（path 依赖，构建零网络）。
2. **阶段 2：效果器插件槽（核心）** ✅ 已完成：`src/vst_host.zig`（加载/实例化/立体声 process/退役延迟销毁）；
   调音台「添加效果器 → 插件（VST3）…」；存档 `plugin_path` 往返（导入时惰性重载）。
3. **阶段 3：编辑器窗口** ✅ 已完成：插件面板「打开界面」→ `IEditController::createView(kEditor)` →
   **独立顶层窗口**（vst_host 注册窗口类 + 手写 `IPlugFrame`：`resizeView` → `SetWindowPos`；
   `WM_SETFOCUS/KILLFOCUS` → `onFocus`；用户点 X → `removed` → 销毁；卸载/退避前先 `closeEditor`）。
   冒烟：`vstscan --editor <文件.vst3>`（打开 → 泵消息 1.5s → 关闭）。
4. **阶段 4：插件参数与状态** ✅ 已完成（2026-10）：
   - 参数面板：效果器面板列出全部参数（名称/值用插件自带的显示串），拖动编辑
     （离散参数吸附步长）、双击恢复默认、滚轮滚动；
   - 编辑通路：`setParamNormalized` + `inputParameterChanges`（SPSC 环，音频线程零分配）；
   - GUI 联动：每插件 `IComponentHandler` 记录编辑器内的编辑 → 面板直读实时值 +
     标脏（`App.plugin_dirty`，保存/加载/新建时清零）；`restartComponent(kLatencyChanged)`
     → 重读延迟；
   - 状态存档：工程保存时 `getState`（组件+控制器）→ base64 存入存档；加载/撤销恢复
     经 `pending_state` 在实例就绪后 `setState`/`setComponentState`（复用 `MemStream`）；
   - **实例救援**：导入/撤销时“位置+路径”匹配的旧插件实例保留（不重置参数）；
   - 验证：`vstscan --params <文件.vst3>`（无头列参数）；gain/TDR Nova 参数与状态
     往返测试。
   - **历史集成**（2026-10 追加）：历史快照**携带**插件状态（按内容哈希去重池共享，
     未编辑的插件在多条历史间共享同一份内存）；撤销/重做真正回退插件参数与结构改动；
     “无明确终点事件”的输入（滚轮 / 插件侧改动 / 结构性改动）走**手势模型**：
     起手即提交临时条目 → 静置 1s / 新操作起手 / 编辑器关闭 / 保存 → 钉最终值
     （历史顺序永远正确；自绘指针拖动仍为松手提交）。
     状态恢复后会**丢弃队列中陈旧参数**（否则下一个 process 会把旧值压回恢复值）。
   - MVP 限制：干湿滑块对插件隐藏（未接混合）；参数自动化（曲线/捕获）未做。
5. **阶段 5：VSTi 乐器插件（Vital 优先）** ✅ 已完成（2026-10）：
   - 5a 加载与发声：角色化加载（subCategories 识别 Instrument；允许无主输入）；
     引擎中转缓冲**叠加**渲染；机架「VST3…」入口、乐器右键「打开插件界面」、
     合成器窗口信息面板；上游 zig-vst3 补 subCategories 透传（fork 补丁）；
   - 5b 音符事件：复用“按事件时刻分段”架构——`dispatchNote` 对 VSTi 入批（offset 0），
     段渲染 `processInstrument` 喂 `IEventList`；**all-off 统一漏斗**（暂停/跳转/试听/
     切类型）按音高补发 note-off（位图跟踪，防悬挂）；
   - 5c 音色存档：`SavedInstrument` 携带 state（base64；历史去重池共享）+ `pending`
     懒应用（撤销可回退音色）；`stateEqualsCurrent` 同步比较乐器音色/路径
     （否则调音色会被去重逻辑静默丢历史——实测 bug）；
   - **ProcessContext**：每段填充 tempo/拍号/播放态/绝对位置/ppq（delay/arp/LFO 同步）。
   - 5d **打磨批次**（2026-10）：
     - **加载失败态（B1）**：路径保留（不再静默清空）；失败 → 机架 / 效果行 / 面板**标红**
       + toast（仅在状态翻转时报一次）；每 ~2s 自动重试（`fail_wait` 节流）；文件恢复 →
       自动加载并**应用 pending 参数/音色**；换路径 / 换乐器清 pending + 旧实例退役
       （防参数串到别的乐器）；
     - **VSTi 声像（B2）**：插件输出当立体声总线，按乐器声像旋钮做**等功率平衡**
       （0.5 = 原样；两端 = 单侧 ×√2）——插件自身定位偏侧（如 Vital 音色偏右）可拉回居中；
     - 发声高亮：note-on 活跃位图直接发布给 UI（无宿主声部模型也亮键）；
     - 乐器真名：加载完成后占位名（“VST3 乐器”）自动替换为插件名（重名 #N）；
     - 长驻 DLL：卸载/失败清理**不再 FreeLibrary**（见 4.2）。
   - 5e **多输出 VSTi（SFLT）**（2026-10）：总线**协商阶梯**——① 先试“仅主输出”（单总线
     旧路径）；② 被拒（SFLT：17 出全默认激活）→ 全激活 + 每总线 planar 缓冲 + 渲染**求和**。
     `vst_host.vsti_sum_all_buses`（默认 true；若某插件主输出是辅助的镜像导致音量
     翻倍 → 改 false 只取主输出）。工具：`vstscan --buses`（布局诊断）+ `--run` 每总线能量。
     实测：SFLT 0进17出加载/处理**不崩**（旧版直接拒绝）；sine-synth/Vital/效果器回归无损。
     注：SFLT 的 sf2 选择随工程存档依赖插件自身 `getState`（未专项回归）。
   - 已知边界：插件 MIDI 通道固定 0；`outputEvents`（插件 MIDI 输出）未接；
     多通道 MIDI 映射未做。
6. **阶段 6：延迟补偿（PDC）**（待做；置于 VSTi 之后——一次覆盖效果链 + 乐器链 + 导出）
   - 各通道总延迟 = 链上插件 `latency` 之和（内建效果器为 0）；全工程取 max，
     不足者补环形缓冲；导出走同一逻辑，保证听感与成品的对齐一致。
7. （可选）多总线/侧链探测、CLAP 支持。

### 3.1 工具速查（`vstscan.exe`，与主程序同目录）

| 子命令 | 用途 |
|---|---|
| `vstscan [目录...]` | 枚举 .vst3 模块与类（名称/厂商/子类/CID） |
| `--classes <file>` | 列工厂全部类（含控制器等） |
| `--buses <file>` | 音频总线布局（数量/类型/通道数/默认激活位；多输出诊断） |
| `--params <file>` | 无头列参数（名称/显示串/步数） |
| `--run <file> [effect\|instrument]` | 音频试跑（含每总线能量） |
| `--editor <file> [secs]` | 编辑器冒烟（真实弹窗） |
| `--jsonl <out> <路径...>` | 扫描 worker（插件管理器内部调用；JSONL 见 `src/vst_scan.zig`） |

## 4. 风险清单

### 4.1 已解决的互操作坑（2026-10 实测，勿回退）

1. **`initialize(hostContext)` 不能传 null**：TDR Nova 等会在插件内部直接解引用
   hostContext → 段错误。提供进程级 `HostCtx`（FUnknown + IHostApplication +
   IComponentHandler 三合一）。
2. **单组件插件也必须 `setComponentHandler`**：GuitarD 在 handler 为 null 时，
   编辑器一动 UI（加单块）就在插件内部段错误（插件内部调
   `getComponentHandler()->beginEdit(…)`）。
3. **分离式插件必须 `IConnectionPoint` 双向连接组件与控制器**（VST3 规范）：
   JUCE 框架靠 `connect` 传递内部共享实例；不连则控制器 `getParameterCount()==0`、
   `createView` 返回 null（表现为“此插件没有编辑器界面”，极易误判为插件无 GUI）。
   zig-vst3 缺 `IConnectionPoint` 绑定，在 `vst_host.zig` 本地声明（ivstmessage.h，
   IID 0x70A4156F/0x6E6E4026/0x989148BF/0xAA60D8D1）。卸载时需 `disconnect`。
4. **`setComponentState`**：分离式插件把组件 state（`IComponent::getState` → 宿主
   侧内存流 `MemStream`）推给控制器；JUCE 返回 E_NOTIMPL 属正常（组件/控制器共享
   实例）。
5. **`IPluginFactory3::setHostContext`**：加载时向工厂登记宿主上下文（规范推荐）。

### 4.2 撤销/重做与插件状态重放（2026-10：商 DAW 式参数增量）

**问题**：撤销旋钮（插件 GUI 内或参数面板）会做整块 `setState`——Vital 等重建内部
状态要长时间持插件锁，音频线程被挡 → 全曲卡顿；另外每次历史提交都要对**每个**插件
`getState`（全等判定 + 快照捕获），播放中每次编辑都在碰插件锁。

**方案（对齐商用 DAW：旋钮级撤销 = 参数回放，不碰 setState）**：

- **参数增量历史**：手势期间记录每条参数编辑（`(槽, 参数ID, old, new)`，同参折叠）。
  来源：① 宿主参数列表（`App.setPluginParamHost` 唯一入口）；② 插件 GUI 内
  performEdit → **环形队列**（256 条，`vst_host`）帧末全量排空（溢出 → 降级信号）；
  `old` 取自插件参数缓存（只由宿主写 → 恒为编辑前值）。增量随快照存入历史条目（**运行时**
  字段，不持久化）。
- **旋钮级切分**（2026-10）：环形队列升级为 begin/perform/end 事件（Vital 探针实测：交互
  成对规范）。换旋钮（不同槽/参数的 `beginEdit`）会先把当前手势钉住 → A/B 两条条目、
  两步撤销；同旋钮连拧靠 1s 静置合并（用户拍板）；条目标签 = **“{归属名}: {参数名}”**
  （归属名：乐器 → 乐器槽名；效果器 → 通道名；英文冒号省宽；如“Solokey: Oscillator 1 Level”）。
  无 begin/end 通知的插件走原计时兜底。
- **应用计划（逐槽）**：`skip`（状态未变）/ `replay`（单步导航 + 本步无结构信号 +
  缓存匹配来向侧值 → `setParam` 免锁回放，**无 setState、无 panic、不断音**）/
  `full`（预设加载、结构变化、多步跳转 → 整块）。结构信号：`setDirty` /
  restart dirty 旗标 / 编辑溢出 / 无缓存 → 该槽本步禁回放。
- **捕获复用**：插件状态脏标（自上次历史捕获后是否变过）；未变槽的快照直接
  沿用来向条目文本（池化 intern 命中同块），**不再 getState**；与插件无关的编辑
  （音符/音量/BPM…）提交历史时零插件调用。工程保存永远现取（准确性优先）。
  脏标置位点：一切已知状态变更（参数编辑/结构信号/restoreState/实例新载）。
- 残余可闻：真正结构性的操作（加载预设/换插件/多步跳转）仍整块重放——商用 DAW
  同样会咔一下；VSTi 重放带 panic 清音防挂。


### 4.3 插件“恢复回声”与已采纳语义（2026-10 实测 Vital）

- **现象**：打开含 6×Vital 的工程，单击片段就出现一条“移动片段”历史（其实什么都没改）；
  在“打开工程”与该幽灵条目间切换 → 播放卡顿（每次对全部实例整块 `setState`）。
  纯内置乐器的工程无此问题（没有插件槽）。
- **根因**：Vital 的 `setState(自己的存档字节)` 后再 `getState`，**字节不守恒**
  （实测 174909 字节中 115713 不同；连续两次直取则守恒）。加载后我们对槽置脏以待
  现取 → 下次提交 `stateEqualsCurrent` 把回声当差异 → 幽灵条目，且其 blob 与基线不同。
- **修复**：pending 恢复成功应用后，该槽按“**已采纳**”标 clean（与当前条目视为一致）
  ——插件自己的重归一化不是用户编辑。提交提交时不再比较、不再现取；跳转仍是
  blob-to-blob 比较（未变 → skip → 无 setState）。SFLT 实测往返守恒，不背锅。
- 回归测试：`app.test`“工程加载恢复后：插件回声字节不算编辑”（依赖本机 Vital，未装则跳过；
  含“留脏标会中招”的对照断言）。

### 4.4 插件界面嵌入面板（2026-10，用户拍板“简单易用流派”）

- **无“打开界面”入口**：删掉效果面板/乐器面板/机架菜单三处按钮；双击乐器/效果器
  打开面板，**插件界面直接嵌在面板内容区**（`IPlugView::attached` 挂到面板内的
  WS_CHILD 子窗口——规范原话：“You should attach a child window to it”）。
  不提供“弹出为独立窗口”。
- **无界面插件自动兑底**：`createView` 为空 → `editor_no_ui` 缓存 → 面板显示参数列表
  （列表实现归一化到 `view_util.drawPluginParamList`，乐器/效果共用；无按钮切换）。
- **尺寸**：面板固定=插件尺寸（`getSize`/`resizeView` 驱动；隐藏两面板手动缩放柄）；
  效果面板保留“启用”控制行，乐器面板只留自绘标题栏。
- **遮挡（矩形精确判定）**：浮动窗口按 Z+矩形、菜单/弹层/模态/输入框绘制时在 `Ui`
  登记遮罩矩形（`noteOverlayRect`）；被盖住时子窗口 `SW_HIDE`，否则 `SW_SHOW`
  （子窗口永远在软渲染之上，不处理就会出现“插件盖住菜单”）。
- **生命周期**：每个插件实例最多一个视图；面板关闭/切目标/插件被换 → 帧末对账
  （`syncPluginEditors`）关掉归属不符的编辑器；实例退役前强制 `closeEditor`。
  打开失败不退避重试（~2s）；`WM_SETFOCUS/KILLFOCUS` → `onFocus`（同旧）。
- **已知边界**：乐器面板目标**跟随选择** → 切换乐器会重建编辑器（后续可做缓存）；
  DPI 与 `IPlugViewContentScaleSupport` 未接（旧行为一致）。

### 4.5 未决

- **延迟补偿（PDC）**：鼓点对齐场景下插件延迟会可闻；排期下个大版本（与 UI 重设计同期）。
- **多输出 VSTi：已支持（2026-10）**（乐器角色）。协商阶梯：先试“仅主输出”；被拒则
  全激活 + 每总线 planar 缓冲 + 渲染**求和**（`vsti_sum_all_buses` 默认 true——不丢声；
  若实测某插件“主输出=辅助镜像”导致音量翻倍，改 false 重编）。>2 通道的辅助总线仍拒绝；
  多输出**效果器**仍拒绝（后续）。SFLT 0进17出实测：加载/激活/process 均不崩。
- **插件 DLL 常驻进程**（2026-10 定案）：卸载/加载失败**都不 `FreeLibrary`**——SFLT 实测：
  插件后台线程/回调在 FreeLibrary 后执行已卸载代码而崩（固定地址复现）；宿主行业惯例
  即插件常驻。代价：插件文件在会话期间被占用（退出进程时释放）。
- **崩溃隔离**：进程内插件是硬伤（可选方案：独立音频进程 × 太大了，暂不做）。
- **SDK 版本**：跟 `zig-vst3` 钉版（v3.8.0_build_66）可省大量 ABI 踩坑。
- **跨平台**：插件宿主先做 Windows（与项目现状一致）。

## 5. 参考

- VST3 License（MIT, 2025）：https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License.html
- zig-vst3（Zig 绑定，MIT，Zig 0.16）：https://github.com/joshburgess/zig-vst3
- IPlugView 头（GUI 挂载）：https://github.com/steinbergmedia/vst3_pluginterfaces/blob/master/gui/iplugview.h
- 最小宿主参考：https://stackoverflow.com/questions/55640822/how-to-instantiate-a-vst3-plugin-in-code-for-a-vst3-host-app

## 插件路径自愈（跨平台工程的关键）

工程里存的是**插件路径 + 类 CID**。把 Windows 上做的工程拿到 Linux 打开时，路径（`C:\Program Files\Common Files\VST3\X.vst3`）
在 Linux 上必然不存在 → 槽位进入 `load_failed`（界面上"插件加载失败——将自动重试；文件恢复后自动加载"）。

`App.reboundFailedPluginSlots()` 负责把它们**重绑到本机同款插件**，触发时机：
- 插件扫描完成后；
- 每 240 帧的后台巡检（`main` 里）。

匹配规则（**从精确到兜底**）：
1. **CID 匹配**：`findLiveEntryFor()` —— 缓存里找 class CID 相同、角色匹配（乐器/效果）、且 `dll` 真存在的条目；
2. **包名兜底**：`findEntryByBundleName()` —— 取失败槽路径的**文件名**（`Vital.vst3`），
   在缓存里找同名、角色匹配、文件存在的条目。**只在唯一命中时生效**（同名多份就不猜）。

覆盖范围（三处都要扫，之前缺了第三处）：
- 混音通道的效果槽；
- 乐器槽；
- **鼓组 VST3 层**（`instrument.kit.pads[].layers[]`）。

> 教训：只做 CID 匹配不够——老工程可能没存 CID（`plugin_cid` 为空），跨平台工程还多一层
> "路径完全不同"的问题。**包名兜底是必要的第二条腿**。
### 自愈的两个坑（2026-10 实测）

1. **扫描缓存的 `path` 曾经是"模块文件"而不是"包根"**
   `startPluginScan` 把候选的 `dll`（`…/Vital.vst3/Contents/x86_64-linux/Vital.so`）当根传给 worker，
   worker 再 `discover(该文件)` → 缓存里的 `path` 就变成了 `.so` 文件。
   → 自愈的"包名兜底"拿 `Vital.so` 去比工程的 `Vital.vst3`，**永远不匹配**。
   修法：扫描队列改存 **`c.path`（包根）**；兜底比较改成比 **名字主干**（`Vital`），
   这样包根/模块两种形态都能对上，旧缓存也兼容。
2. **老工程可能没有 CID**
   现版本保存**会**写 `plugin_cid`（乐器/鼓组层/效果槽三处，见 `app.zig` 的 `plugin_cid = …`），
   但更早版本没写 → 这类工程只能靠"包名兜底"。所以**两级匹配（CID → 包名）缺一不可**。
### 按包名兜底的重定位：**静默应用**（确认窗已移除）

- **为什么不再弹窗**：确认窗的前提是“已经有扫描结果”。但真实场景里，用户打开工程时往往**还没扫过插件**，
  此时候选集为空 → 弹窗永远不会出现；等用户自己扫完，包名兜底已经能直接命中 → 弹窗又已经错过了时机。
  一个永远不会在该出现时出现的确认窗，就是纯粹的代码负担。
- **现在的行为**：后台巡检（约每 2 秒）与扫描完成时，
  `reboundFailedPluginSlots(io)` 按 **CID 精确 → 包名兜底** 依次尝试，命中就静默改路径并弹 toast
  「已自动重新定位 N 个插件」；都没命中就保持失败态，用户可在插件管理器里手动定位。
- **为何安全**：
  1. 只在“原路径真的消失”且“候选文件真的在磁盘上”时才改（存在性门槛，防两个坏文件来回跳）；
  2. **保留原 CID**：换路径后再失败仍能继续按身份匹配；
  3. 改动计入撤销历史（`commitHistory("重新定位插件")`）。
- 已删除：`ModalKind.heal_plugin_guess`、`App.heal_guess_count`、`backupProjectFile()`、`drawHealGuess()`、
  `reboundFailedPluginSlotsEx(io, apply)` 的“只统计不改动”分支。