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

    // ── 控制行：[循环][▶/⏸][■] / 增益 / 速度 / 通道（采样器层无通道框——跟随鼓组乐器）──
    const ctl_y = y + title_h + 4;
    {
        const asset = if (tgt.asset >= 0 and tgt.asset < @as(i32, @intCast(app.audio_assets.items.len)))
            app.audio_assets.items[@intCast(tgt.asset)]
        else
            null;
        // [循环] + [▶/⏸ 播放/暂停] + [■ 停止]（循环按钮在播放**左边**——用户拍板）
        const playing_this = app.preview.playing and app.preview.asset == tgt.asset and asset != null;
        const loop_w: i32 = 56;
        const loop_x = x + 8;
        const play_x = loop_x + loop_w + 6;
        const play_w: i32 = 64;
        const stop_w: i32 = 44;
        {
            // 循环开关（仅采样器层有意义；其它目标变灰不可点）
            const loop_ok = tgt.layer_ref != null;
            const lh = util.hitUI(ui, loop_x, ctl_y, loop_w, ctl_h - 8);
            const on = app.preview.loop and loop_ok;
            ui.renderer.fillRect(loop_x, ctl_y, loop_w, ctl_h - 8, if (!loop_ok) ui.theme.slider_track else if (on) ui.theme.accent else if (lh) ui.theme.item_hover else ui.theme.slider_track);
            ui.renderer.strokeRect(loop_x, ctl_y, loop_w, ctl_h - 8, ui.theme.panel_border);
            const lt: i32 = @intFromFloat(ui.font.measure("循环"));
            ui.labelCentered("循环", loop_x + @divTrunc(loop_w - lt, 2), ctl_y, ctl_h - 8, if (loop_ok) ui.theme.text else ui.theme.text_dim);
            if (lh and ui.mouse_pressed and loop_ok) app.preview.loop = !app.preview.loop;
        }
        {
            if (ui.iconButton(9710, if (playing_this) .pause else .play, play_x, ctl_y, play_w, ctl_h - 8, playing_this, ui.theme.accent)) {
                if (asset) |a| {
                    if (playing_this) {
                        app.previewPause(); // 暂停：保留暂停点（再按从该处继续）
                    } else {
                        // 游标/trim 都是**引擎帧域**（原生帧只影响取样的 ratio）
                        const total_e: i32 = @intCast(a.data.engFrames());
                        var start: i32 = 0;
                        var plen: i32 = 0;
                        if (tgt.layer_ref != null) {
                            // 采样器层：**只试听 trim 区间**（默认全选）
                            const ts2: i32 = std.math.clamp(tgt.trim_start.*, 0, @max(0, total_e - 1));
                            const te2: i32 = if (tgt.trim_len.* > 0) @min(total_e, ts2 + tgt.trim_len.*) else total_e;
                            start = ts2;
                            if (app.preview.asset == tgt.asset and app.preview.pos >= ts2 and app.preview.pos < te2) start = app.preview.pos;
                            plen = te2 - ts2;
                        } else if (app.preview.asset == tgt.asset and app.preview.pos > 0 and app.preview.pos < total_e) {
                            start = app.preview.pos;
                        }
                        // 循环只看按钮状态（且仅采样器层）
                        app.previewStartEx(tgt.asset, start, plen, tgt.channel, tgt.gain.*, tgt.speed.*, tgt.layer_ref != null and app.preview.loop);
                    }
                } else {
                    app.setToast("音频未加载（文件缺失/格式不支持）");
                }
            }
            if (ui.iconButton(9711, .stop, play_x + play_w + 6, ctl_y, stop_w, ctl_h - 8, false, ui.theme.accent)) {
                // 停止 → 游标回**左端点**（采样器层）/ 素材开头（样式·片段）
                var cp: i32 = 0;
                if (tgt.layer_ref != null) {
                    if (asset) |a| cp = std.math.clamp(tgt.trim_start.*, 0, @max(0, @as(i32, @intCast(a.data.engFrames())) - 1));
                }
                app.previewStopAt(cp);
            }
        }

        // 增益旋钮（用户拍板：增益用旋钮）
        var gx = play_x + play_w + 6 + stop_w + 12;
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
        // 采样器层 = 跟随鼓组乐器 → **不画通道框、也不占行宽**）
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
            // 采样器层：通道跟随鼓组乐器 → **不占行宽**（腾给循环按钮；用户拍板）
        }

        // 采样器层：[换采样…]
        if (tgt.layer_ref) |ref| {
            const bw: i32 = 78;
            // 与速度旋钮的“100%”标签拉开距离（实测：紧贴着，看着像一左一右）
            gx += 44;
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

    // ── 波形区：峰值 + trim 端点拖柄（仅采样器层）+ 试听游标 ──
    {
        const wave_x = x + 8;
        const wave_y = y + title_h + ctl_h + 12;
        const wave_w = ww_w - 16;
        const wave_h = ww_h - (title_h + ctl_h + 12) - 10;
        ui.renderer.fillRect(wave_x, wave_y, wave_w, wave_h, ui.theme.bg);
        ui.renderer.strokeRect(wave_x, wave_y, wave_w, wave_h, ui.theme.panel_border);
        const is_layer = tgt.layer_ref != null;
        const asset: ?*app_mod.AudioAsset = if (tgt.asset >= 0 and tgt.asset < @as(i32, @intCast(app.audio_assets.items.len)))
            app.audio_assets.items[@intCast(tgt.asset)]
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
            // （音频**样式/片段**的裁剪在播放列表里拖片段左右端点，与音符片段一致；
            //   只有**采样器层**没有片段可拖 → 在波形上直接给左右端点抓手。用户拍板：
            //   默认全选，拖左右端点调起点/终点；手感类似横向滑块的左右端点）
            const ts_now: i32 = std.math.clamp(tgt.trim_start.*, 0, total_eng - 1);
            const tl_now: i32 = tgt.trim_len.*;
            const te_now: i32 = if (tl_now > 0)
                @min(total_eng, ts_now + tl_now)
            else
                total_eng;
            const px_of = struct {
                fn f(t: i32, total_frames: i32, wx: i32, ww2: i32) i32 {
                    return wx + @as(i32, @intFromFloat(@as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(@max(1, total_frames))) * @as(f32, @floatFromInt(ww2))));
                }
            }.f;
            if (is_layer) {
                const lx: i32 = px_of(ts_now, total_eng, wave_x, wave_w);
                const rx: i32 = px_of(te_now, total_eng, wave_x, wave_w);
                // 左右外侧变暗（选中区间保持原亮度）+ 区间边线
                if (lx > wave_x) ui.renderer.fillRect(wave_x, wave_y, lx - wave_x, wave_h, 0x66000000);
                if (rx < wave_x + wave_w) ui.renderer.fillRect(rx, wave_y, wave_x + wave_w - rx, wave_h, 0x66000000);
                ui.renderer.fillRect(lx, wave_y, 2, wave_h, ui.theme.accent);
                ui.renderer.fillRect(rx - 2, wave_y, 2, wave_h, ui.theme.accent);
                // 抓手：命中带比线宽宽（±8px，好抓）；悬停/拖动时 ↔ 光标 + 加亮
                const grip_l_hover = util.inRect(ui.mouse_x, ui.mouse_y, lx - 8, wave_y, 20, wave_h);
                const grip_r_hover = util.inRect(ui.mouse_x, ui.mouse_y, rx - 8, wave_y, 20, wave_h);
                const dragging = ww.trim_drag_side != 0;
                if (grip_l_hover or grip_r_hover or dragging) ui.cursor = .resize_h;
                const l_hot = grip_l_hover or ww.trim_drag_side == 1;
                const r_hot = grip_r_hover or ww.trim_drag_side == 2;
                // 抓手块（上下各一个小方块，像滑块端点的齿）
                ui.renderer.fillRect(lx - 3, wave_y + 1, 8, 6, if (l_hot) ui.theme.text else ui.theme.accent);
                ui.renderer.fillRect(lx - 3, wave_y + wave_h - 7, 8, 6, if (l_hot) ui.theme.text else ui.theme.accent);
                ui.renderer.fillRect(rx - 5, wave_y + 1, 8, 6, if (r_hot) ui.theme.text else ui.theme.accent);
                ui.renderer.fillRect(rx - 5, wave_y + wave_h - 7, 8, 6, if (r_hot) ui.theme.text else ui.theme.accent);
                if (ui.mouse_pressed) {
                    if (grip_l_hover) {
                        ui.active_id = 9720; // ⚠️ 不能与旋钮 id 撞：9702 = 采样速度旋钮
                        ww.trim_drag_side = 1;
                    } else if (grip_r_hover) {
                        ui.active_id = 9720;
                        ww.trim_drag_side = 2;
                    }
                }
                // 拖动：**边侧必须存在窗口状态里**（每帧局部变量只有按下那帧生效 → 拖不动）
                if (ww.trim_drag_side != 0) {
                    if (!ui.mouse_down) {
                        ww.trim_drag_side = 0;
                        if (ui.active_id == 9720) ui.active_id = 0;
                    } else if (ui.active_id == 9720) {
                        const rel: f32 = @as(f32, @floatFromInt(ui.mouse_x - wave_x)) / @as(f32, @floatFromInt(@max(1, wave_w)));
                        const f: i32 = std.math.clamp(@as(i32, @intFromFloat(rel * @as(f32, @floatFromInt(total_eng)))), 0, total_eng);
                        if (ww.trim_drag_side == 1) {
                            const new_start = @min(f, te_now - 1);
                            tgt.trim_start.* = new_start;
                            tgt.trim_len.* = te_now - new_start;
                        } else {
                            const new_end = @max(f, ts_now + 1);
                            tgt.trim_len.* = new_end - ts_now;
                        }
                        app.history_pending = "调整采样范围";
                    }
                }
                // 起点/终点/长度数值（ms；trim 变了就地刷新）
                const sr_f: f32 = @floatFromInt(@max(1, app.params.sample_rate));
                var nb2: [112]u8 = undefined;
                const ts_draw = std.math.clamp(tgt.trim_start.*, 0, total_eng - 1);
                const te_draw = if (tgt.trim_len.* > 0) @min(total_eng, ts_draw + tgt.trim_len.*) else total_eng;
                const info = std.fmt.bufPrint(&nb2, "起点 {d:.3}s · 终点 {d:.3}s · 长 {d:.3}s", .{
                    @as(f32, @floatFromInt(ts_draw)) / sr_f,
                    @as(f32, @floatFromInt(te_draw)) / sr_f,
                    @as(f32, @floatFromInt(te_draw - ts_draw)) / sr_f,
                }) catch "";
                // 循环区**跟随拖动**：正在循环试听时，把 trim 改动同步回音频线程
                // （否则拖完右端点还要再按 ▶ 才生效）
                if (app.preview.playing and app.preview.asset == tgt.asset) {
                    app.params.preview_start.store(ts_draw, .monotonic);
                    app.params.preview_len.store(te_draw - ts_draw, .monotonic);
                }
                ui.label(info, wave_x + 4, wave_y + wave_h - 14, ui.theme.text_dim);
            }
            // 点击/拖动波形 = 设置试听游标（**仅非层目标**：采样器层没有片段可裁、采样往往很短，
            // 鼠标设游标反而会和端点抓手抢操作；层的游标只由 ▶ 试听推动并在 trim 区间内循环）
            if (!is_layer and util.hitUI(ui, wave_x, wave_y, wave_w, wave_h) and ui.mouse_down) {
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
