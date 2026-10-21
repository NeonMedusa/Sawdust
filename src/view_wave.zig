//! 波形窗口（音频片段 / 鼓组采样器层共用，见 `docs/audio-files.md` §7）：
//! 波形 + 采样起点/终点手柄 + 试听（播放/暂停/游标）+ 增益旋钮 + 通道推子。
//! 试听 = **局部预览**（不动主播放游标；走目标各自通道——用户拍板 2026-10）。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");

const title_h: i32 = 22;
const ctl_h: i32 = 30; // 顶部控制行（试听/增益/通道）
const min_w: i32 = 320;
const min_h: i32 = 150;

/// 目标解析：返回（资产 idx、trim 指针、增益、通道、名称）
const Target = struct {
    asset: i32,
    trim_start: *i32,
    trim_len: *i32,
    gain: *f32,
    /// 播放速度（1 = 原速；0.5..2.0 旋钮）
    speed: *f32,
    channel: i32,
    channel_editable: bool,
    name: []const u8,
    /// 采样器层：可换采样（片段无此项）
    layer_ref: ?app_mod.WaveLayerRef = null,
};

fn resolveTarget(app: *App) ?Target {
    const ww = &app.wave_win;
    if (ww.clip) |ci| {
        if (ci >= app.clips.items.len) return null;
        const c = &app.clips.items[ci];
        if (!c.isAudio()) return null;
        if (c.audio_style < 0 or c.audio_style >= @as(i32, @intCast(app.audio_styles.items.len))) return null;
        const st = &app.audio_styles.items[@intCast(c.audio_style)];
        if (st.asset < 0) {
            return .{
                .asset = -1,
                .trim_start = &c.trim_start,
                .trim_len = &c.trim_len,
                .gain = &st.gain,
                .speed = &st.speed,
                .channel = st.channel,
                .channel_editable = true,
                .name = st.name,
            };
        }
        return .{
            .asset = st.asset,
            .trim_start = &c.trim_start,
            .trim_len = &c.trim_len,
            .gain = &st.gain,
            .speed = &st.speed,
            .channel = st.channel,
            .channel_editable = true,
            .name = st.name,
        };
    }
    if (ww.layer) |ref| {
        const ly = app.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse return null;
        if (ly.kind != .sampler) return null;
        return .{
            .asset = ly.asset_idx,
            .trim_start = &ly.trim_start,
            .trim_len = &ly.trim_len,
            .gain = &ly.gain,
            .speed = &ly.speed,
            .channel = if (ref.instrument >= 0 and ref.instrument < @as(i32, @intCast(app.instruments.items.len)))
                app.instruments.items[@intCast(ref.instrument)].mixer
            else
                0,
            .channel_editable = false,
            .name = ly.source_preset,
            .layer_ref = ref,
        };
    }
    if (ww.style) |si| {
        if (si >= app.audio_styles.items.len) return null;
        const st = &app.audio_styles.items[si];
        return .{
            .asset = st.asset,
            .trim_start = &app.wave_trim_dummy[0],
            .trim_len = &app.wave_trim_dummy[1],
            .gain = &st.gain,
            .speed = &st.speed,
            .channel = st.channel,
            .channel_editable = true,
            .name = st.name,
        };
    }
    return null;
}

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const ww = &app.wave_win;
    if (!ww.open) return false;
    const tgt = resolveTarget(app) orelse {
        ww.open = false;
        return false;
    };
    ww.w = std.math.clamp(ww.w, min_w, @max(min_w, w - 20));
    ww.h = std.math.clamp(ww.h, min_h, @max(min_h, h - 20));
    ww.x = std.math.clamp(ww.x, 0, @max(0, w - ww.w));
    ww.y = std.math.clamp(ww.y, 0, @max(0, h - ww.h));
    const x = ww.x;
    const y = ww.y;
    const ww_w = ww.w;
    const ww_h = ww.h;

    // 阴影 + 背景 + 边框 + 标题栏
    ui.renderer.fillRect(x + 3, y + 3, ww_w, ww_h, r_mod.rgb(10, 11, 13));
    ui.renderer.fillRect(x, y, ww_w, ww_h, ui.theme.panel);
    ui.renderer.strokeRect(x, y, ww_w, ww_h, ui.theme.accent);
    ui.renderer.fillRect(x + 1, y + 1, ww_w - 2, title_h - 1, ui.theme.toolbar);
    var tbuf: [192]u8 = undefined;
    const kind_label: []const u8 = if (tgt.layer_ref != null) "采样器层" else if (app.wave_win.style != null) "音频样式" else "音频片段";
    const title = std.fmt.bufPrint(&tbuf, "{s} — {s}", .{ kind_label, tgt.name }) catch "音频";
    ui.label(title, x + 8, y + 4, ui.theme.text);

    // 关闭按钮
    const close_x = x + ww_w - 22;
    const close_hovered = util.hitUI(ui, close_x, y + 2, 20, title_h - 4);
    ui.renderer.fillRect(close_x, y + 2, 20, title_h - 4, if (close_hovered) ui.theme.danger else ui.theme.panel);
    ui.label("×", close_x + 6, y + 4, ui.theme.text);
    if (close_hovered and ui.mouse_pressed) {
        app.previewStop();
        ww.open = false;
        return true;
    }

    // 点窗口内任意处 → 置顶；标题拖动
    if (util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww_w, ww_h) and ui.mouse_pressed) {
        app.bringToFront(&ww.z);
    }
    if (util.hitUI(ui, x, y, ww_w - 24, title_h) and ui.mouse_pressed) {
        ui.active_id = 9600;
        ww.grab_dx = ui.mouse_x - x;
        ww.grab_dy = ui.mouse_y - y;
    }
    if (ui.active_id == 9600) {
        if (!ui.mouse_down) {
            ui.active_id = 0;
        } else {
            ww.x = std.math.clamp(ui.mouse_x - ww.grab_dx, 0, @max(0, w - ww_w));
            ww.y = std.math.clamp(ui.mouse_y - ww.grab_dy, 0, @max(0, h - ww_h));
        }
    }

    // ── 控制行：试听 / 增益旋钮 / 通道推子（或“跟随鼓组乐器”）──
    const ctl_y = y + title_h + 4;
    {
        const asset = if (tgt.asset >= 0 and tgt.asset < @as(i32, @intCast(app.audio_assets.items.len)))
            &app.audio_assets.items[@intCast(tgt.asset)]
        else
            null;
        // [▶/⏸ 播放/暂停] + [■ 停止]（与主传输同构——用户拍板）
        const playing_this = app.preview.playing and app.preview.asset == tgt.asset and asset != null;
        const play_w: i32 = 64;
        const stop_w: i32 = 44;
        {
            if (ui.iconButton(9710, if (playing_this) .pause else .play, x + 8, ctl_y, play_w, ctl_h - 8, playing_this, ui.theme.accent)) {
                if (asset) |a| {
                    if (playing_this) {
                        app.previewPause(); // 暂停：保留暂停点（再按从该处继续）
                    } else {
                        const total: i32 = @intCast(a.data.frame_count);
                        // 完整音频试听（与片段 trim 无关）
                        var start: i32 = 0;
                        if (app.preview.asset == tgt.asset and app.preview.pos > 0 and app.preview.pos < total) {
                            start = app.preview.pos;
                        }
                        app.previewStart(tgt.asset, start, 0, tgt.channel, tgt.gain.*, tgt.speed.*);
                    }
                } else {
                    app.setToast("音频未加载（文件缺失/格式不支持）");
                }
            }
            if (ui.iconButton(9711, .stop, x + 8 + play_w + 6, ctl_y, stop_w, ctl_h - 8, false, ui.theme.accent)) {
                app.previewStop(); // 停止：游标归位（下次从 trim 起点）
            }
        }

        // 增益旋钮（用户拍板：增益用旋钮）
        var gx = x + 8 + play_w + 6 + stop_w + 12;
        ui.label("增益", gx, ctl_y + 2, ui.theme.text_dim);
        gx += 36;
        var gv: f32 = std.math.clamp(tgt.gain.*, 0.0, 2.0) * 0.5; // 0..2（1.0 = 无增益＝旋钮正中）
        if (ui.knob(9700, &gv, gx, ctl_y - 2, ctl_h - 2)) {
            tgt.gain.* = gv * 2.0;
            app.history_pending = if (tgt.layer_ref != null) "调整层增益" else "调整音频增益";
        }
        var gd: [16]u8 = undefined;
        const gdt = std.fmt.bufPrint(&gd, "{d} dB", .{@as(i32, @intFromFloat(@round(20.0 * std.math.log10(@max(0.0001, tgt.gain.*)))))}) catch "";
        ui.label(gdt, gx + ctl_h + 2, ctl_y + 2, ui.theme.text_dim);
        gx += ctl_h + 34;
        // 速度旋钮（百分比，上下限 50%..200%；v1 = 变速变调）
        ui.label("速度", gx, ctl_y + 2, ui.theme.text_dim);
        gx += 36;
        {
        var kv: f32 = std.math.clamp(@log2(std.math.clamp(tgt.speed.*, 0.5, 2.0) / 0.5) / 2.0, 0.0, 1.0); // 对数：100% 在旋钮正中
            if (ui.knob(9702, &kv, gx, ctl_y - 2, ctl_h - 2)) {
            tgt.speed.* = 0.5 * std.math.pow(f32, 4.0, kv); // 50%..200% 对数映射
                app.history_pending = if (tgt.layer_ref != null) "调整采样速度" else "调整音频速度";
            }
            var vb: [8]u8 = undefined;
            const vt = std.fmt.bufPrint(&vb, "{d}%", .{Ui.roundF(tgt.speed.* * 100.0)}) catch "";
            ui.label(vt, gx + ctl_h + 2, ctl_y + 2, ui.theme.text_dim);
        }
        gx += ctl_h + 30;

        // 通道（音频片段 = 样式级推子，照机架乐器通道推子：方框数字 + 上下拖；
        // 采样器层 = 跟随鼓组乐器 → 只读显示）
        var cval: i32 = std.math.clamp(tgt.channel, 0, 65535);
        const n_ch: i32 = @max(1, @as(i32, @intCast(app.mixer_channels_state.items.len)));
        if (tgt.channel_editable) {
            ui.label("通道", gx, ctl_y + 2, ui.theme.text_dim);
            gx += 36;
            if (ui.dragNumber(9701, gx, ctl_y - 2, 52, ctl_h - 2, &cval, 0, n_ch - 1, 24)) {
                if (app.wave_win.clip) |ci| {
                    if (ci < app.clips.items.len) {
                        const c = app.clips.items[ci];
                        if (c.audio_style >= 0 and c.audio_style < @as(i32, @intCast(app.audio_styles.items.len))) {
                            app.audio_styles.items[@intCast(c.audio_style)].channel = cval;
                        }
                    }
                }
                app.history_pending = "调整音频通道";
            }
            gx += 62;
        } else {
            ui.label("通道 = 跟随鼓组乐器", gx, ctl_y + 2, ui.theme.text_dim);
            gx += 140;
        }

        // 采样器层：[换采样…]
        if (tgt.layer_ref) |ref| {
            const bw: i32 = 78;
            if (gx + bw < x + ww_w - 10) {
                const h2 = util.hitUI(ui, gx, ctl_y, bw, ctl_h - 8);
                ui.renderer.fillRect(gx, ctl_y, bw, ctl_h - 8, if (h2) ui.theme.item_hover else ui.theme.slider_track);
                ui.renderer.strokeRect(gx, ctl_y, bw, ctl_h - 8, ui.theme.panel_border);
                ui.labelCentered("换采样…", gx, ctl_y, ctl_h - 8, ui.theme.text);
                if (h2 and ui.mouse_pressed) {
                    app.pending_load_sample = .{ .instrument = ref.instrument, .pitch = ref.pitch, .layer = ref.layer };
                }
            }
        }
    }

    // ── 波形区：峰值 + trim 手柄 + 试听游标 ──
    {
        const wave_x = x + 8;
        const wave_y = y + title_h + ctl_h + 12;
        const wave_w = ww_w - 16;
        const wave_h = ww_h - (title_h + ctl_h + 12) - 10;
        ui.renderer.fillRect(wave_x, wave_y, wave_w, wave_h, ui.theme.bg);
        ui.renderer.strokeRect(wave_x, wave_y, wave_w, wave_h, ui.theme.panel_border);
        const asset: ?*app_mod.AudioAsset = if (tgt.asset >= 0 and tgt.asset < @as(i32, @intCast(app.audio_assets.items.len)))
            &app.audio_assets.items[@intCast(tgt.asset)]
        else
            null;
        if (asset == null) {
            ui.labelCentered("（音频未加载——文件缺失或格式不支持）", wave_x, wave_y, wave_h, ui.theme.danger);
        } else {
            const total: i32 = @intCast(asset.?.data.frame_count);
            // 游标/定位用**引擎帧域**（trim/pos 的单位）；绘图用原生帧域
            const total_eng: i32 = @intCast(asset.?.data.engFrames());
            const mid = wave_y + @divTrunc(wave_h, 2);
            const half: f32 = @as(f32, @floatFromInt(wave_h)) * 0.5;
            // 波形（按 trim 区间取峰值）
            const np: usize = asset.?.peaks.len;
            if (np > 0) {
                var px2: i32 = 0;
                while (px2 < wave_w) : (px2 += 1) {
                    const fr = @as(i32, @intFromFloat(@as(f32, @floatFromInt(total)) * @as(f32, @floatFromInt(px2)) / @as(f32, @floatFromInt(@max(1, wave_w)))));
                    const bi: usize = @min(np - 1, @as(usize, @intCast(@divTrunc(fr, @as(i32, @intCast(@max(@as(u32, 1), asset.?.peak_frames)))))));
                    const pk = asset.?.peaks[bi];
                    const y0: i32 = mid - @as(i32, @intFromFloat(pk.max * half));
                    const y1: i32 = mid - @as(i32, @intFromFloat(pk.min * half));
                    ui.renderer.vline(wave_x + px2, y0, @max(1, y1 - y0), ui.theme.waveform);
                }
            }
            // （trim 手柄已移除——用户拍板：采样裁剪在播放列表里拖片段左右端点，与音符片段一致）
            // 点击/拖动波形 = 设置游标（拖拽中只动**视觉游标**，松手才一次性跳转——
            // 播放中不再自动暂停，也不会因连续跳位出“打碟”声）
            if (util.hitUI(ui, wave_x, wave_y, wave_w, wave_h) and ui.mouse_down) {
                const relc: f32 = @as(f32, @floatFromInt(ui.mouse_x - wave_x)) / @as(f32, @floatFromInt(@max(1, wave_w)));
                const npos: i32 = std.math.clamp(@as(i32, @intFromFloat(relc * @as(f32, @floatFromInt(total_eng)))), 0, total_eng - 1);
                app.preview.seeking = true;
                app.preview.asset = tgt.asset;
                app.preview.pos = npos;
            }
            if (app.preview.seeking and !ui.mouse_down) {
                // 松手：播放中 → 一次性跳到新位置继续（单次不连续，听感只是一下）；
                // 暂停中 → 游标即下次 ▶ 的起点（不动音频线程）
                app.preview.seeking = false;
                if (app.preview.playing) app.params.preview_pos.store(app.preview.pos, .monotonic);
            }
            // 试听游标（本资产在播时；完整波形坐标）
            if (app.preview.asset == tgt.asset and app.preview.pos >= 0) {
                const rel2: f32 = @as(f32, @floatFromInt(app.preview.pos)) / @as(f32, @floatFromInt(total_eng));
                const cx = wave_x + @as(i32, @intFromFloat(rel2 * @as(f32, @floatFromInt(wave_w))));
                if (cx >= wave_x and cx < wave_x + wave_w) {
                    ui.renderer.vline(cx, wave_y, wave_h, if (app.preview.playing) ui.theme.note_selected else 0xFFFFFFFF);
                }
            }
        }
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww_w, ww_h);
}
