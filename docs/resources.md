# 资源账本：内存 / CPU / 二进制体积（现状 + 优化 backlog）

> 与 `docs/timeline-scrollbar.md`（投影模型）、`tmp/pooling-plan.md`（池化实施记录）配套。
> 本文记录"什么在占内存、什么在吃 CPU、什么在占发布包体积、哪些是刻意保留的取舍"。

## 一、容量跟随项（普通用户无感的固定成本）

| 项 | 成本 | 现状 |
|---|---|---|
| 合成器声部池 `synths` | **85KB × 乐器容量**（256 声部/乐器） | 唯一仍按容量预分配的大块；起点 32 ≈ 2.7MB。扩容拷贝的主体 |
| 鼓组层声部池 `kit_chunks` | 154KB × **真实鼓组数** | 已惰性化（仅鼓组乐器分配） |
| `chan_bufs` | 通道容量 × 32KB | 32 通道 = 1MB |
| `slot_eq`（EQ 滤波状态） | **通道×槽乘积** × 480B | 32×32 = 1MB；随两维乘积增长 |
| `vsti_events` 事件批 | ~10KB × 乐器容量 | 只为 VSTi 用但按容量付 |
| Params 原子数组 | 每乐器容量 ≈ 1KB；每通道每槽 ≈ 60B | 可忽略 |
| 每帧同步循环 | 乐器容量 × 15 原子写 | 容量 1024 也 <1ms |

## 二、随实际内容线性（正常消耗，疯狂用户自担）

- 每个发声声部：~300B 状态 + 每样本 DSP（振荡器×4、unison 副本最多 16）；
- 每个效果器实例：状态盒按需分配——**单个 Delay = 768KB**；
- VSTi：账单归插件本身；每真实鼓组 154KB（惰性）；
- 空转的调音台链照付算力（代码特意不跳过：混响/延迟尾音需持续推进）——大混音台的常驻 CPU 主项；
- 渲染循环按"乐器容量"扫 kind/gain 指针（每段一次），数千容量也只是微秒级。

## 三、三个容易被低估的"隐形"点

1. **历史快照**：128 步上限（`history_limit`），每步全量乐器/通道状态；插件 state blob 只在脏槽现取（捕获复用机制）——重度插件工程 ≈ 步数 × 脏槽字节数；
2. **删除 ≠ 立刻释放**：插件实例/状态盒走 **30 帧倒计时退役**（音频安全设计）——批量删除/装载时有几十帧的内存与句柄峰值；
3. **扩/缩容的一次性停顿**：暂停设备 + 重分配拷贝（鼓组池惰性化后已大降；128 乐器级 ≈ 20ms 级），仅在跨容量边界发生。
   （**历史导航不再触发**——仅乐器数量变化的重建才重置鼓组池；原位更新不置位，
   见 `docs/pitfalls.md` “无条件置位 = 意外暂停设备”。）

## 四、可选优化 backlog（未做，按需取用）

1. `synths` 惰性化：按实际乐器而非容量付 85KB/乐器（省扩容余量）；
2. `vsti_events` 惰性化（体量小，顺手可做）；
3. 历史快照 blob 进一步瘦身（只对插件重工程有意义）；
4. `slot_eq` 按 (通道,槽) 惰性分配（维度乘积真膨胀时才值得）；
5. 空转通道的"静音快进"（需先解决尾音推进语义——高风险，不建议轻易动）；
6. **全默认初值镜像**（§6.2 同款病灶）：`audio.zig` 鼓组采样器声部池
   `voices: [kit_sampler_voices]SamplerVoice = @splat(.{})` ≈ **84 KB**（符号 `__anon_5818`）、
   `synth.zig` 的 `voices: [voice_count]Voice = @splat(.{})` 同理——改 `undefined` 时
   **必须**同时在初始化处清零（`active` 标志在写之前就会被读）；
7. `vst_host.zig` 里几处 `@splat(.{})` 小表（`events`/`classes`/`in_queues`/`out_buffers`），
   合计几十 KB，顺手可做。

## 五、刻意保留的取舍（勿当 bug）

- 单鼓组 16 层上限（`kit_max_layers`）：真实用法 2-3 层，16 是防单个鼓组失控的护栏；
- 15 层以上叠加的实际听感 = 全频段噪音，无实际需求场景；
- 休止期渲染链不跳过（见上）；
- 状态脏标数组只增不减（体量小，简化语义）。

## 六、二进制体积与发布口径

> 起因：V14 → 2026-11-03 那次提交，发布包从 Linux 2.59 MB / Windows 3.00 MB 变成 3.55 MB / 3.97 MB。
> 查下来"涨的 1 MB"里**只有约 155 KB 是新功能**，其余是**出包口径不同**（同一提交、同一工具链
> 三档模式之间就差 1.4 MB）+ **一个 `.rodata` 初值镜像坑**（已修，−475 KB）。

### 6.1 铁律：比体积必须"同口径 + 同工具链"

同一份源码（V14 的提交 `3b0aa37`）在 Zig 0.17.0 下重编（Linux x86-64）：

| 构建 | 体积（字节） |
| --- | --- |
| `-Doptimize=ReleaseSmall` | 1,783,352 |
| `-Doptimize=ReleaseFast` | 3,087,304 |
| `-Doptimize=ReleaseSafe` | 3,169,040 |
| **实际发布的 `SawdustV14-Linux-amd64`** | **2,714,712** |

最后一行三档都复现不出来 → V14 那个包是**别的工具链/参数**编的。
**跨包直接比体积没有意义**，要比就各自在同一口径下重编一次。

当前出包（`build.zig` 对非 Debug 构建默认 `strip`）：

| 口径 | Windows | Linux | 取舍 |
| --- | --- | --- | --- |
| `ReleaseFast`（发布默认） | 3,691,008 | 3,242,392 | 全优化；DSP / 调度优先 |
| `ReleaseSmall` | 2,209,792 | 1,845,048 | 少内联 / 少向量化；体积敏感时用 |

```sh
zig build -Doptimize=ReleaseFast                 # 发布
zig build -Doptimize=ReleaseSmall                # 小体积
zig build -Doptimize=ReleaseFast -Dstrip=false   # 排障：保留符号表（体积暴涨，勿发布）
```

### 6.2 坑：大数组**字段默认值**会在 `.rodata` 里多存一整块

**症状**：某提交只加约 1k 行代码，`.text` 仅 +126 KB，`.rodata` 却从 398 KB 涨到 883 KB（+485 KB）。

**根因**：

```zig
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = @splat(.{}),   // ← 字段默认值 = 编译期常量
    };
}

// 而 App 里有：sched_events: synth.SchedQueue = .{},   ← 用到了这个默认值
```

字段默认值是**编译期常量** → Zig 把"整块全默认事件"材料化进 `.rodata`，`main` 建 `App` 时
再 `memcpy` 到 `.bss`。于是**同一份数据在文件里存了两份**：`.bss` 里是运行时真身，
`.rodata` 里那份纯粹是 `memcpy` 源。当时容量 4,096 → 16,384、`SchedEvent` 20 → 28 B，
80 KB 的队列就变成了 **448 KB** 的镜像。逐字节对账（符号大小完全对得上）：

| | 容量 | `sizeof` | 期望字节 | 实际符号 |
| --- | --- | --- | --- | --- |
| V14 | 4,096 | 20 B | 81,920 | `__anon_4761` = 81,936（+16 头）|
| 出问题那次 | 16,384 | 28 B | 458,752 | `__anon_4795` = 458,776（+24 头）|

**修法**：

```zig
/// 安全依据：`buf` 只在 `[read, write)` 区间内被读，而该区间内每格都必然已被 `push` 完整写过
buf: [capacity]T = undefined,

pub fn zeroed(self: *Self) void {
    @memset(std.mem.sliceAsBytes(&self.buf), 0);
}
```

启动时清一次（`App.initQueues()`，只为可重复性）。实测 **−475 KB**，
Windows / Linux、ReleaseFast / ReleaseSmall 四种组合完全一致。

### 6.3 怎么量

```sh
size -A bin | grep -E '\.(text|rodata|data|bss)'      # .bss 正常、.rodata 却多出"元素数×sizeof"
nm -S --size-sort -C bin | tail -20                   # 找最大的 __anon_*（匿名常量 = comptime 材料化）
objdump -d bin | awk '/^[0-9a-f]+ <.*>:/{fn=$2} /__anon_4795/{print fn}' | sort -u   # 谁在引用它
```

> 关键判据：**`.bss` 没涨而 `.rodata` 暴涨，且涨幅 ≈ 元素数 × sizeof = 多余的初值镜像**。

### 6.4 检查清单（新增静态数组 / 环形缓冲时过一遍）

1. 字段默认值 `= @splat(.{})` / `= [_]T{...} ** N`：能改 `undefined` + 运行时清零就改；
2. 值语义大结构体别随手给"全默认"字段——每多一个用到 `.{}` 的构造点，就多一份镜像；
3. 诊断格式化（`std.fmt`）每多一种实参类型组合就多一份实例化；体积敏感时可做编译期开关（未做）；
4. **测试代码不进发布包**：`_ = @import("x.zig")` 只写在 `test {}` 里就不影响体积
   （例如 `src/sched_stress.zig`）——这条常被误怀疑，别在错误方向上浪费时间；
5. `strip` 已默认对非 Debug 开启（`build.zig`），不要手工绕开；
6. 体积回归只看**同口径**数字（见 §6.1）。
