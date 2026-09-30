# AGENTS.md — 给 AI 协作者的约定

> 这是 Sawdust 项目的 AI 协作约定。**动手改代码前先读本文 + `docs/pitfalls.md`。**

## 临时文件与测试产物：一律放 `tmp/`

**`tmp/` 已被 `.gitignore` 忽略**，所有"用完即弃"的文件都必须放这里：

| 场景 | 正确做法 |
|---|---|
| 启动验证的重定向输出 | `Start-Process .\zig-out\bin\Sawdust.exe -RedirectStandardOutput tmp\o.txt -RedirectStandardError tmp\e.txt` |
| 一次性脚本（生成测试数据等） | 写到 `tmp/xxx.py` |
| 复现文件 / 调试输出 / 临时截图 | `tmp/` 下任意文件名 |
| 调研报告 / 草稿 | `tmp/xxx.md` |

**禁止**在项目根目录或 `src/`、`docs/` 下生成任何临时文件——
曾经有 `o.txt` / `e.txt` 残留根目录且被 `git add` 暂存，差点污染仓库。

**好习惯**：任务完成后顺手清理自己产生的 `tmp/` 文件（`tmp/` 内容随时可删）。

## 验证流程（每次改完必须做）

```bash
zig build test                  # 单元测试必须全绿
zig build -p tmp/verify         # 若 zig-out/bin/Sawdust.exe 被占用（用户在运行），
                                # 构建到 tmp/ 下验证，不要杀用户的进程
tmp/verify/bin/Sawdust.exe      # 启动冒烟测试（输出也重定向到 tmp/）
```

**验证产物一律在 `tmp/` 内**（`tmp/verify/` 等）——不要在项目根目录建目录，
用完顺手删除（`Remove-Item tmp/verify -Recurse -Force`）。

**改完提醒用户重启才能实测**（运行中的实例是旧二进制）。

## 项目约定

- 注释和文档用**中文**（代码标识符用英文）。
- 提交信息用**中文**，格式 `type(scope): 简述`（如 `fix(ui): 修复缩放跳变`）。
- **不主动 `git commit`**——由用户自己提交；AI 只负责把改动和验证做扎实。
- 踩过的坑记进 `docs/pitfalls.md`（有具体代码 + 症状 + 教训，不写空话）。
