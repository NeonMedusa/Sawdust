//! 插件管理窗口：扫描文件夹 / 单文件清单 + 手动扫描 + 结果列表。
//!
//! 数据：`app.plugin_cfg`（`plugins.json`）/ `app.plugin_cache`（`plugins_cache.json`）
//! ——见 `plugin_db.zig`；扫描 worker 由 main 驱动（本模块只置 pending 标志，
//! 不直接碰 io / 进程）。UI 与行为约定见 `tmp/changes-notes.md`「插件管理器」。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");
const plugin_db = @import("plugin_db.zig");

const title_h: i32 = 22;
const min_w: i32 = 500;
const min_h: i32 = 340;
const row_h: i32 = 20;
const list_row_h: i32 = 18;
const tag_w: i32 = 80; // 结果行角色标签列宽

/// 相对时间文本（buf 由调用方提供）
fn agoText(ts: i64, buf: []u8) []const u8 {
    if (ts <= 0) return "从未扫描";
    const now: i64 = plugin_db.unixTime();
    const d: i64 = if (now > ts) now - ts else 0;
    if (d < 60) return std.fmt.bufPrint(buf, "{d} 秒前", .{d}) catch "";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d} 分钟前", .{@divTrunc(d, 60)}) catch "";
    if (d < 86400) return std.fmt.bufPrint(buf, "{d} 小时前", .{@divTrunc(d, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d} 天前", .{@divTrunc(d, 86400)}) catch "";
}

/// 返回 true = 鼠标被窗口消费（同 view_help/view_rack 惯例）
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const pm = &app.plugin_mgr;
    if (!pm.open) return false;
    pm.w = std.math.clamp(pm.w, min_w, @max(min_w, w - 20));
    pm.h = std.math.clamp(pm.h, min_h, @max(min_h, h - 20));
    pm.x = std.math.clamp(pm.x, 0, @max(0, w - pm.w));
    pm.y = std.math.clamp(pm.y, 0, @max(0, h - pm.h));
    const x = pm.x;
    const y = pm.y;
    const ww = pm.w;
    const hh = pm.h;

    // 阴影 + 背景 + 边框
    ui.renderer.fillRect(x + 3, y + 3, ww, hh, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww, hh, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww, hh, ui.theme.accent);

    // 标题栏
    ui.renderer.fillRect(x + 1, y + 1, ww - 2, title_h - 1, ui.theme.toolbar);
    ui.label("插件管理", x + 8, y + 4, ui.theme.text);

    // 关闭按钮
    const close_x = x + ww - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        pm.open = false;
        return true;
    }

    // 点窗口内任意处 → 置顶
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh) and ui.mouse_pressed) {
        app.bringToFront(&pm.z);
    }
    // 标题拖动
    if (util.hitUI(ui, x, y, ww - 24, title_h) and ui.mouse_pressed) {
        ui.active_id = 9700;
        pm.grab_dx = ui.mouse_x - x;
        pm.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 9700) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            pm.x = ui.mouse_x - pm.grab_dx;
            pm.y = ui.mouse_y - pm.grab_dy;
        }
    }

    var yy = y + title_h + 8;
    const left = x + 10;
    const right = x + ww - 12;
    const cw = @max(64, right - left);

    const cfg = if (app.plugin_cfg) |*c| c else {
        ui.label("（数据目录不可用——请检查启动目录）", left, yy, ui.theme.danger);
        return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
    };

    // ── 扫描文件夹 ──
    ui.label("扫描文件夹", left, yy, ui.theme.accent);
    yy += 18;
    {
        var fi: usize = 0;
        while (fi < cfg.folders.items.len) : (fi += 1) {
            const f = &cfg.folders.items[fi];
            const ry = yy + @as(i32, @intCast(fi)) * row_h;
            // 启用开关（小方块；关闭 = 灰——暂不扫该目录）
            const sw: i32 = 13;
            const sw_y = ry + @divTrunc(row_h - sw, 2);
            const sw_hov = util.hitUI(ui, left, sw_y, sw, sw);
            ui.renderer.fillRect(left, sw_y, sw, sw, if (f.enabled) ui.theme.accent else ui.theme.slider_track);
            ui.renderer.strokeRect(left, sw_y, sw, sw, ui.theme.panel_border);
            if (sw_hov and ui.mouse_pressed) {
                f.enabled = !f.enabled;
                app.plugin_cfg_dirty = true;
            }
            // 删除按钮
            const del_w: i32 = 18;
            const del_x = right - del_w;
            const path_x = left + sw + 8;
            const del_hov = util.hitUI(ui, del_x, ry + 1, del_w, row_h - 2);
            ui.renderer.fillRect(del_x, ry + 1, del_w, row_h - 2, if (del_hov) ui.theme.danger else ui.theme.slider_track);
            ui.label("×", del_x + 5, ry + 3, ui.theme.text);
            if (del_hov and ui.mouse_pressed) {
                _ = cfg.removeFolder(f.path);
                app.plugin_cfg_dirty = true;
                break; // 列表已变：本帧停止画后续行（防悬垂）
            }
            ui.labelClipped(f.path, path_x, ry + 3, @max(8, del_x - path_x - 6), if (f.enabled) ui.theme.text else ui.theme.text_dim);
        }
        yy += @as(i32, @intCast(cfg.folders.items.len)) * row_h;
    }
    {
        const bw: i32 = 122;
        const bh: i32 = 22;
        const hov = util.hitUI(ui, left, yy + 2, bw, bh);
        ui.renderer.fillRect(left, yy + 2, bw, bh, if (hov) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(left, yy + 2, bw, bh, ui.theme.panel_border);
        ui.label("+ 添加文件夹…", left + 10, yy + 8, ui.theme.text);
        if (hov and ui.mouse_pressed) app.pending_plugin_folder_pick = true;
        yy += 28;
    }

    // ── 单文件条目 ──
    ui.label("单文件", left, yy, ui.theme.accent);
    yy += 18;
    {
        var si: usize = 0;
        while (si < cfg.files.items.len) : (si += 1) {
            const p = cfg.files.items[si];
            const ry = yy + @as(i32, @intCast(si)) * row_h;
            const del_w: i32 = 18;
            const del_x = right - del_w;
            const del_hov = util.hitUI(ui, del_x, ry + 1, del_w, row_h - 2);
            ui.renderer.fillRect(del_x, ry + 1, del_w, row_h - 2, if (del_hov) ui.theme.danger else ui.theme.slider_track);
            ui.label("×", del_x + 5, ry + 3, ui.theme.text);
            if (del_hov and ui.mouse_pressed) {
                _ = cfg.removeFile(p);
                app.plugin_cfg_dirty = true;
                break;
            }
            ui.labelClipped(p, left, ry + 3, @max(8, del_x - left - 6), ui.theme.text);
        }
        yy += @as(i32, @intCast(cfg.files.items.len)) * row_h;
    }
    {
        const bw: i32 = 122;
        const bh: i32 = 22;
        const hov = util.hitUI(ui, left, yy + 2, bw, bh);
        ui.renderer.fillRect(left, yy + 2, bw, bh, if (hov) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(left, yy + 2, bw, bh, ui.theme.panel_border);
        ui.label("+ 添加文件…", left + 10, yy + 8, ui.theme.text);
        if (hov and ui.mouse_pressed) app.pending_plugin_file_pick = true;
        yy += 30;
    }

    // ── 扫描控制 + 状态 ──
    {
        const bh: i32 = 24;
        const bw: i32 = 104;
        const hov = util.hitUI(ui, left, yy, bw, bh);
        const scanning = pm.scanning;
        ui.renderer.fillRect(left, yy, bw, bh, if (hov) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(left, yy, bw, bh, ui.theme.panel_border);
        ui.label(if (scanning) "取消扫描" else "开始扫描", left + 22, yy + 5, if (scanning) ui.theme.danger else ui.theme.text);
        if (hov and ui.mouse_pressed) {
            if (scanning) {
                app.pending_scan_cancel = true;
            } else {
                app.pending_scan_start = true;
            }
        }

        var sb: [512]u8 = undefined;
        var rb: [64]u8 = undefined;
        if (scanning) {
            const done = pm.scan_ok + pm.scan_err;
            const total_t = if (pm.scan_total > 0)
                (std.fmt.bufPrint(&sb, "扫描中… {d}/{d}（可用 {d} · 失败 {d}）", .{ done, pm.scan_total, pm.scan_ok, pm.scan_err }) catch "")
            else
                (std.fmt.bufPrint(&sb, "扫描中…（可用 {d} · 失败 {d}）", .{ pm.scan_ok, pm.scan_err }) catch "");
            ui.labelClipped(total_t, left + bw + 10, yy + 6, cw - bw - 12, ui.theme.text);
            if (pm.scan_current_len > 0) {
                var cb: [288]u8 = undefined;
                const cur = std.fmt.bufPrint(&cb, "当前：{s}", .{std.fs.path.basename(pm.scan_current_buf[0..pm.scan_current_len])}) catch "";
                ui.labelClipped(cur, left + bw + 10, yy + 22, cw - bw - 12, ui.theme.text_dim);
            }
        } else if (app.plugin_cache) |*cache| {
            const ago = agoText(cache.scanned_at, &rb);
            const s = std.fmt.bufPrint(&sb, "上次扫描：{s} · 可用 {d} · 失败 {d}{s}", .{
                ago,
                cache.okCount(),
                cache.errCount(),
                if (cache.completed) "" else "（未完成）",
            }) catch "";
            ui.labelClipped(s, left + bw + 10, yy + 6, cw - bw - 12, if (cache.completed) ui.theme.text_dim else ui.theme.danger);
        } else {
            ui.label("尚未扫描（需要手动点「开始扫描」）", left + bw + 10, yy + 6, ui.theme.text_dim);
        }
        yy += bh + (if (pm.scanning and pm.scan_current_len > 0) @as(i32, 20) else 4);
    }
    // 崩溃提示行（上次扫描被某个插件带崩 → 它不在结果里）
    if (app.plugin_cache) |*cache| {
        if (!pm.scanning) {
            if (cache.crashed_after) |cpath| {
                var cb: [600]u8 = undefined;
                const s = std.fmt.bufPrint(&cb, "上次扫描：{s} 使扫描进程崩溃——已跳过该插件", .{cpath}) catch "";
                ui.labelClipped(s, left, yy, cw, ui.theme.danger);
                yy += 16;
            }
        }
    }

    // ── 结果列表 ──
    ui.label("扫描结果", left, yy, ui.theme.accent);
    {
        // “隐藏失败项”开关（右键侧小按钮）
        const bw: i32 = 96;
        const bh: i32 = 18;
        const bx = right - bw;
        const hov = util.hitUI(ui, bx, yy - 2, bw, bh);
        ui.renderer.fillRect(bx, yy - 2, bw, bh, if (hov) ui.theme.item_hover else ui.theme.slider_track);
        ui.renderer.strokeRect(bx, yy - 2, bw, bh, ui.theme.panel_border);
        ui.label(if (pm.hide_ignored) "显示失败项" else "隐藏失败项", bx + 8, yy + 2, ui.theme.text);
        if (hov and ui.mouse_pressed) pm.hide_ignored = !pm.hide_ignored;
    }
    yy += 18;
    const list_top = yy;
    const list_h = @max(20, y + hh - 8 - list_top);
    const cache = if (app.plugin_cache) |*c| c else {
        ui.label("（尚无结果——点「开始扫描」）", left, list_top + 2, ui.theme.text_dim);
        return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
    };

    const n_ok = cache.okCount();
    const n_err = cache.errCount();
    const n_rows: usize = n_ok + (if (pm.hide_ignored) 0 else n_err);
    const content_h: i32 = @as(i32, @intCast(n_rows)) * list_row_h;
    if (util.hitUI(ui, left, list_top, cw, list_h)) {
        pm.scroll = std.math.clamp(pm.scroll - util.scrollDelta(ui), 0, @max(0, content_h - list_h));
    }
    pm.scroll = std.math.clamp(pm.scroll, 0, @max(0, content_h - list_h));

    if (n_rows == 0) {
        ui.label(if (cache.scanned_at == 0) "（尚无结果——点「开始扫描」）" else "（没有条目）", left, list_top + 2, ui.theme.text_dim);
    } else {
        const saved = ui.renderer.pushClip(left, list_top, cw - 4, list_h);
        defer ui.renderer.popClip(saved);
        var row: i32 = 0;
        // ok 条目在前（worker 已按路径排序），失败条目按开关追加在后
        for (cache.entries) |*e| {
            if (!e.ok) continue;
            drawResultRow(ui, e, left, list_top + row * list_row_h - pm.scroll, cw, list_top, list_h);
            row += 1;
        }
        if (!pm.hide_ignored) {
            for (cache.entries) |*e| {
                if (e.ok) continue;
                drawResultRow(ui, e, left, list_top + row * list_row_h - pm.scroll, cw, list_top, list_h);
                row += 1;
            }
        }
        if (content_h > list_h) {
            _ = ui.scrollbarV(8010, right - 5, list_top, 4, list_h, &pm.scroll, content_h, list_h);
        }
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}

/// 结果行：`[乐器] 名称 — 厂商 · 文件`（失败行：`[失败] 文件 — 错误`，暗色）
fn drawResultRow(ui: *Ui, e: *const plugin_db.Entry, x: i32, ry: i32, w: i32, list_top: i32, list_h: i32) void {
    if (ry + list_row_h <= list_top or ry >= list_top + list_h) return; // 视口剔除
    const y = ry + 2;
    if (e.ok) {
        const tag: []const u8 = if (e.roleHasInstrument() and e.roleHasEffect())
            "[乐器+效果]"
        else if (e.roleHasInstrument())
            "[乐器]"
        else if (e.roleHasEffect())
            "[效果]"
        else
            "[未知]";
        ui.label(tag, x, y, ui.theme.accent);
        ui.labelClipped(e.name, x + tag_w, y, 170, ui.theme.text);
        ui.labelClipped(e.vendor, x + tag_w + 176, y, 130, ui.theme.text_dim);
        ui.labelClipped(std.fs.path.basename(e.path), x + tag_w + 312, y, @max(20, w - tag_w - 320), ui.theme.text_dim);
    } else {
        ui.label("[失败]", x, y, ui.theme.danger);
        ui.labelClipped(std.fs.path.basename(e.path), x + tag_w, y, 200, ui.theme.text_dim);
        ui.labelClipped(e.err, x + tag_w + 206, y, @max(20, w - tag_w - 214), ui.theme.danger);
    }
}
