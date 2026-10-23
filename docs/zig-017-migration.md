## Zig 0.17 的 API 变更（2026-10 迁移实录）

一次真实迁移的记录，按"踩到 → 怎么改"排序。**目录**：
`src/`（应用）、`build.zig`、`build.zig.zon`、`libs/zig-vst3`（submodule，见最后一条）。

### `@cImport` 被移除 → 预生成绑定
- **症状**：`error: invalid builtin function: '@cImport'`。
- **0.17 现状**：`@cImport` 彻底移除；`b.addTranslateC` 还在但已 deprecated，官方推荐
  外挂 `translate-c` 包（**要联网抓**）。
- **本项目的解法**：用 **CLI 生成一次、把产物入库**——
  `zig translate-c -I libs/miniaudio tmp/x.h > src/c/miniaudio.zig`（stb 同理）。
  构建期零网络、零翻译步骤；C 实现仍由 `addCSourceFile` 编译。
- **坑**：`zig translate-c` 在 0.17 **不支持 `-o`**，要重定向标准输出。

### 数组乘法 `a ** b` 被移除 → `@splat`
- **症状**：`error: binary operator '*' has whitespace on one side`（解析器把 `**` 当两个 `*`）。
- **改法**：`[_]u8{0} ** 16` → `@splat(0)`；**但 `@splat` 需要已知结果类型**——
  无类型标注的局部量必须补类型：`var x = [_]bool{false} ** 16` →
  `var x: [16]bool = @splat(false)`；嵌套 `[_][N]f32{[_]f32{0} ** N} ** M` →
  `@splat(@as([N]f32, @splat(0)))`；哨兵数组 `[160:0]u8` → `@as([160:0]u8, @splat('a'))`。
- **注意**：`.*** N` 里 N 是表达式时（`** (max + 1)`）**批量脚本容易吃掉右括号**，
  改完必须全量编译验证。

### `@typeInfo` 的 struct 信息改为"数组结构体"
- **症状**：`error: no field named 'fields' in struct 'lang.Type.Struct'`（`std.builtin` 也改名 `std.lang`）。
- **改法**：`inline for (s.fields) |f|` → `inline for (s.field_names, s.field_types, s.field_attrs) |name, T, attrs|`；
  默认值从 `f.default_value_ptr` 改成 `attrs.defaultValue(T)`。
  本项目 `persist.zig` 的二进制读写/`deepEq` 三处反射都踩了。

### `std.ArrayListUnmanaged` 新增 `pointer_stability` 字段
- **症状**：`error: missing struct field: pointer_stability`。
- **改法**：`= .{ .items = &.{}, .capacity = 0 }` → **`= .empty`**（0.17 提供 `empty` 常量）。

### `Allocator.dupeZ` 改名
- **症状**：`error: no field or member function named 'dupeZ'`。
- **改法**：`alloc.dupeZ(u8, s)` → `alloc.dupeSentinel(u8, s, 0)`。

### 其它落到的改名/移除
- `std.ascii.indexOfIgnoreCase` → **`findIgnoreCase`**。
- `zig fmt`（0.17）会把 `@intFromEnum`/`@enumFromInt` 自动改成
  **`@backingInt`/`@fromBackingInt`**（本项目 58 处，一次 fmt 完成）；
  顺带也会**删掉连续空行**——所以升级后跑一次 `zig fmt src build.zig` 是必要动作。
- `b.args` 移除：`--` 之后的透传参数改成 `run_cmd.addPassthruArgs()`。

### 构建系统：配置进程 / 执行进程分离
- 报错位置会变成 `maker.exe build --zig-lib=...`，**不影响**源码；只是多了层间接。
- submodule 里 `b.getInstallPath` 这类旧 API 会在配置阶段直接报错——本项目干脆
  **不跑 submodule 的 `build.zig`**，改在 `build.zig` 里用 `createModule` 直引源码
  （`zig-vst3/src/root.zig` + `zig-vst3-plugin/src/core.zig`，并 `addImport` 依赖名）。
- **副作用**：`build.zig.zon` 的 `.dependencies` 一并删掉（不再需要 path 依赖）。

### `libs/zig-vst3`（submodule）自身的 0.17 迁移
- 它也用了 `**` 数组乘法（163 处，含 41 个文件），需要同样改成 `@splat`，
  并且无类型标注的局部量要补类型（本仓库只编译其中的 `root.zig`/`core.zig`
  传递闭包，其余是它自己的 tests/tools/examples）。
- **纪律**：submodule 的改动要**在它自己的仓库里提交**，再回到本仓库 bump pin；
  否则别人 clone 下来还是坏的。

### `@typeInfo` 其它 payload 也是数组结构体（submodule 实踩）
- **struct**：`fields` → `field_names` / `field_types` / `field_attrs`；默认值在 `field_attrs[i].defaultValue(T)`。
- **enum**：`fields` → `field_names` / `field_values`（`field.name` 变成元素本身，`field.value` 变成 `field_values[i]`）。
- **fn**：`params`（`Fn.Param` 列表）→ `param_types: []const ?type` + `param_attrs`；取值要写 `param_types[i].?`
  （可空表示 `anytype`/泛型参数）。本项目在 `lifecycle.zig` 的钩子校验里踩到。

### `@hasDecl` 收窄到 `pub` —— 最阴的一条（不报错）
- **症状**：编译通过、但测试 `expected 1, found 0`——配置钩子（`clone` / `connect` / `disconnect` /
  `resizeView` …）静默不再被调用。
- **原因**：0.17 起 `@hasDecl` **只对 `pub` 声明**返回 true（不再考虑“与调用处同文件”）。
- **改法**：凡是被 `@hasDecl(Config, "钩子名")` 探测的钩子**必须 `pub fn`**；
  对库用户是**静默破坏**，必须写进 CHANGELOG。

### 迁移 submodule 的工程细节（zig-vst3 实录）
- 它 230 处 `@intFromEnum` 由 0.17 的 `zig fmt` **自动**换成 `@backingInt`（不要手写正则）。
- 它的仓库里 **41 个文件是 CRLF 提交、269 个是 LF**：改完必须按 `git ls-files --eol`
  逐文件对齐，否则 diff 会膨胀成一万多行的“全文件改动”（本次实测踩到）。
  且不要用 PowerShell 的 `WriteAllLines`/`Out-String` 判断 EOL（它们会骗你）。
- `b.getInstallPath` 的替代：**生成目录 + 安装步骤**——
  `const out = run.addOutputDirectoryArg2("x.vst3", .{})` 拿到 LazyPath，
  再 `b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "bundle/x.vst3" })`；
  下游（validate/pluginval）用 `addDirectoryArg2(out, .{})` 直接拿目录参数，不必再拼字符串路径。
- Windows 上 bundle 步骤本身跑不了（`addSystemCommand` 直接 spawn `.sh` → `InvalidExe`），
  CI 只在 Linux/macOS 跑它们；本地想验证参数契约可以手动
  `bash scripts/bundle_windows_vst3.sh <dll> <out.vst3> x86_64-win <name>`。

---

## C 绑定的长期方案（2026-10 调研，**结论：保持现状 C**）

0.17 把 `b.addTranslateC`（`std.Build.Step.TranslateC`）也列入了弃用序列，官方推荐外挂
ZSF 的 `translate-c` 包。本项目**不用它**，而是 **CLI 预生成 + 产物入库**（`src/c/*.zig`）。
下表是当时实测过的三条路，以后要改主意直接照表选：

| 方案 | 仓库增重 | 首次构建 | 离线可用 | 维护成本 |
|---|---|---|---|---|
| **A. URL 依赖**：`build.zig.zon` 写 `translate_c`，`build.zig` 里 `Translator.init(...)` | 0（`zig-pkg/` 已忽略） | **需联网 ~36 s** | ❌（除非全局包缓存已热） | 最低 |
| **B. vendored**：`libs/translate-c` + `libs/arocc` 入库，并把 translate-c 的 `.zon` 里 `.aro.url` 改成 `.path` | **+4.2 MB**（0.7 + 3.5） | ~42 s，全离线 | ✅ | 升级时重打补丁 || **C. 现状**：绑定入库，头文件变了就跑一次 CLI | +0.38 MB 生成物 | 0 | ✅ | 升级时跑一次 CLI |

**选 C 的理由**：C 面只有 miniaudio / stb_truetype 两个我们自己 vendored 的头，几乎不变；
A/B 都要多两套跟 Zig 版本强绑定的依赖（每个 Zig 大版本都要换分支）。

### 方案 A 的实测细节（想切时照抄）
- translate-c **有 `zig-0.17.x` 分支**（`2.0.2`）；⚠️ 它的 `main` 要 **0.18-dev**，不能用。
- 依赖写法（**必须带 `git+` 前缀**）：
  `git+https://codeberg.org/ziglang/translate-c#zig-0.17.x`（tag 用 `#2.0.2`；`.git` 后缀可带）。
  ⚠️ 写成裸 `https://codeberg.org/.../translate-c.git` 会当成 tarball 去下 →
  `unrecognized 'Content-Type': 'text/html'`。
- `aro` 由 translate-c 自己在 `.zon` 里声明，Zig 会**自动一起抓**，不用手工管。
- 实测（本机、未设 `HTTP_PROXY`/`HTTPS_PROXY`，直连 codeberg）：`zig fetch --save` **2.6 s**；
  冷缓存全流程 `zig build` **35.6 s**；缓存后重建 **0.4 s**；只改头文件重翻译 **0.7 s**。
- 生成物 vs 现有入库：miniaudio **313.7 KB**（现 340.6 KB）、stb_truetype **41.0 KB**（现 40.6 KB）；
  我们代码用到的 **29 个符号 + 全部字段访问/调用签名逐条编译通过**，
  `sizeof(ma_device)=3312`、`sizeof(stbtt_fontinfo)=160`，`ma_format_f32=5`、`MA_SUCCESS=0` 均一致。

### 方案 B 的补丁机制（实测结论）
- **根包覆盖不了子依赖**：在我们自己的 `build.zig.zon` 里同时声明
  `.translate_c = .{ .path = ... }` 和 `.aro = .{ .path = ... }`，translate-c 的
  `b.dependency("aro", …)` **仍然按它自己 zon 里的 URL 去抓**（构建日志会出现
  `-resource-dir ".\\zig-pkg\\aro-…"` 并且 `zig-pkg/` 被创建）。Zig 没有 Cargo 那种
  `[patch]` 机制 → **要离线就必须改那一行**（translate-c 的 zon 里 `.url` 总共只有 1 处）。
- 补丁只有 2 行变 1 行：`.url` + `.hash` → `.aro = .{ .path = "../arocc" }`。
- **必须用普通 vendored 目录，不能用 submodule**：submodule 形态下补丁在子模块工作区里
  （永远 uncommitted）→ 别人 `clone --recursive` 拿到未打补丁的版本（离线构建直接坏），
  而 `git -C libs/translate-c pull` 也会把补丁冲掉，且没有任何记录。
  入库后补丁是**我们自己仓库里的一次真实提交**，`git log -p` 可追溯。
- 体积要对“只取 `.paths` 子集”：translate-c **0.7 MB/486 文件**；arocc 完整 clone **9.5 MB/805 文件**，
  只取 `.paths` 后 **3.5 MB/98 文件**（我们不会去编它的 tests/tools）。合计入库 **~4.2 MB**。
- 升级流程可脚本化（`tools/vendor-translate-c.ps1`）：拉新版 → 去 `.git` → 打那一行 → `zig test` 验证 → 提交；
  建议每棵树里放一个 `UPSTREAM` 小记（上游分支/commit + 补丁说明）。

### 方案 C 的再生成命令（当前正路）
```bash
zig translate-c -I libs/miniaudio libs/miniaudio/miniaudio.h > src/c/miniaudio.zig
zig translate-c -I libs/stb       libs/stb/stb_truetype.h    > src/c/stb_truetype.zig
```
（0.17 的 `translate-c` 不认 `-o`，必须重定向 stdout；若将来 CLI 被移除，退回方案 A/B，
在旧版 Zig 上跑一次即可，入库产物不受影响。）
