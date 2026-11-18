//! **音符预览的共用核心**（三处预览共用同一套"窗口 → 音符"定位规则）：
//!
//! - 钢琴窗横向 minimap（`.piano` 里的位图缓存）
//! - 通道机架的行内 minimap
//! - 播放列表的**片段内**音符预览
//!
//! 它们要做的事本质相同：**给定 `(样式, 乐器?, 时间窗口)`，取出窗口内的音符**，
//! 再各自按自己的像素网格画。差别只有参数（见下表）：
//!
//! | 预览 | 乐器过滤 | 窗口 |
//! |---|---|---|
//! | 钢琴窗 minimap | 当前乐器 | 整个样式内容 |
//! | 机架行 | 该行乐器 | 整个样式内容 |
//! | 片段内预览 | **全部乐器** | `[clip.offset, offset+len)` |
//!
//! **为什么需要**：以前三处各自 `for (app.notes.items)` 全量扫。片段预览是
//! `O(片段数 × 全部音符)`（100 片段 × 1 万音符 = 每帧百万次迭代）。这里改走
//! `App.ensureNoteIndex(pattern)` 的**时间桶**（4 小节一桶，见 `app.zig`），
//! 只遍历覆盖窗口的那几个桶 → `O(窗口内音符)`。
//!
//! 长音符跨桶时在每个桶都会登记一次，所以"从窗口起点开始的桶"里一定能看到它；
//! 调用方仍需按自己的窗口做一次范围判断（下面的 `forEachInWindow` 已代做）。

const std = @import("std");
const App = @import("app.zig").App;
const model = @import("model.zig");

/// 遍历 `[step_lo, step_hi)` 窗口内、匹配 `(pattern, inst)` 的音符下标。
/// `inst = null` → 不过滤乐器（片段预览要画全乐器）。
/// `ctx` 由调用方给，`cb` 收到 `(ctx, app, note_index)`。
pub fn forEachInWindow(
    app: *App,
    pattern: i32,
    inst: ?i32,
    step_lo: i32,
    step_hi: i32,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), *const App, usize) void,
) void {
    if (step_hi <= step_lo) return;
    app.ensureNoteIndex(pattern);
    const ix = &app.note_index;
    if (ix.starts.items.len < 2) return;
    const nb: usize = ix.starts.items.len - 1;
    const bu = @import("app.zig").bucket_units;
    const b0: usize = @intCast(@max(0, @divFloor(step_lo, bu)));
    const b1: usize = @min(nb - 1, @as(usize, @intCast(@max(0, @divFloor(step_hi - 1, bu)))));
    var b = b0;
    while (b <= b1) : (b += 1) {
        const lo_i: usize = ix.starts.items[b];
        const hi_i: usize = ix.starts.items[b + 1];
        for (ix.items.items[lo_i..hi_i]) |ni| {
            const i: usize = ni;
            if (i >= app.notes.items.len) continue; // 索引过期：只漏扫，不越界
            const n = app.notes.items[i];
            if (n.pattern != pattern) continue;
            if (inst) |want| {
                if (n.instrument != want) continue;
            }
            // 窗口重叠：音符 [step, step+len) 与 [step_lo, step_hi) 有交集
            if (n.step + @max(1, n.len) <= step_lo) continue;
            if (n.step >= step_hi) continue;
            cb(ctx, app, i);
        }
    }
}

/// 位图所需 `u64` 字数（行优先，每行重新起字）
pub fn wordsNeeded(cols: i32, rows: i32) usize {
    if (cols <= 0 or rows <= 0) return 0;
    const wpr: usize = (@as(usize, @intCast(cols)) + 63) / 64;
    return wpr * @as(usize, @intCast(rows));
}

/// 把窗口内的音符**光栅化**进 `cols × rows` 位图（`bits` 由调用方持有，长度 = `wordsNeeded`）。
///
/// `step_lo`/`step_hi` 是窗口；`col = (step - step_lo) * cols / (step_hi - step_lo)`；
/// `range` 把音高映射到 0..1（调用方先按实际音域算好，三处预览都遵循
/// "保底 1 个八度 + 中点居中"，见 `model.rangeMap`）。
/// 纵向与旧的"2px 细条"一致：点亮 `row` 与 `row+1`。
pub fn rasterize(
    app: *App,
    pattern: i32,
    inst: ?i32,
    step_lo: i32,
    step_hi: i32,
    range: model.RangeMap,
    cols: i32,
    rows: i32,
    bits: []u64,
) void {
    const need = wordsNeeded(cols, rows);
    if (need == 0 or bits.len < need or step_hi <= step_lo) return;
    @memset(bits[0..need], 0);

    const wpr: usize = (@as(usize, @intCast(cols)) + 63) / 64;
    const span: i64 = @intCast(step_hi - step_lo);
    const cols64: i64 = cols;

    const Ctx = struct { cols: i32, rows: i32, wpr: usize, span: i64, cols64: i64, step_lo: i32, range: model.RangeMap, bits: []u64 };
    const ctx = Ctx{
        .cols = cols,
        .rows = rows,
        .wpr = wpr,
        .span = span,
        .cols64 = cols64,
        .step_lo = step_lo,
        .range = range,
        .bits = bits,
    };
    forEachInWindow(app, pattern, inst, step_lo, step_hi, ctx, struct {
        fn cb(c: Ctx, a: *const App, i: usize) void {
            const n = a.notes.items[i];
            const rel0: i64 = @as(i64, n.step) - c.step_lo;
            const rel1: i64 = rel0 + @max(1, n.len);
            const c0: i32 = @intCast(std.math.clamp(@divTrunc(rel0 * c.cols64, c.span), 0, c.cols64 - 1));
            const c1: i32 = @intCast(std.math.clamp(@divTrunc(rel1 * c.cols64, c.span), 0, c.cols64 - 1));
            const y_norm = 1.0 - c.range.yOf(n.pitch);
            const row: i32 = @intCast(std.math.clamp(@as(i64, @intFromFloat(y_norm * @as(f32, @floatFromInt(c.rows - 2)))), 0, c.rows - 1));
            var col = c0;
            while (col <= c1) : (col += 1) {
                const ci: usize = @intCast(col);
                const bit: u6 = @intCast(ci % 64);
                var r = row;
                while (r <= @min(row + 1, c.rows - 1)) : (r += 1) {
                    c.bits[@as(usize, @intCast(r)) * c.wpr + ci / 64] |= @as(u64, 1) << bit;
                }
            }
        }
    }.cb);
}
