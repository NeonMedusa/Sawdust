//! 设置窗口（工具栏「选项」打开）：启动行为 / 最高帧率。
//! 变更即置 `settings_dirty`，由 main 帧末落盘到数据目录 `settings.json`。

const std = @import("std");
const r_mod = @import("render.zig");
const Ui = @import("ui.zig").Ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const util = @import("view_util.zig");
const font_info = @import("font_info.zig");
const audio_pref = @import("audio_pref.zig");

const title_h: i32 = 22;
// 允许窗口缩得很小：内容区本来就能滚动，**底部“应用/取消”必须永远可见**
// （缩放调很大时逻辑屏幕很小，以前写 560 → 窗口比屏幕还高，按钮就跑出屏幕了）
const min_w: i32 = 300;
const min_h: i32 = 240;

/// 返回 true = 鼠标被窗口消费
pub fn draw(ui: *Ui, app: *App, w: i32, h: i32) bool {
    const sw = &app.settings_win;
    if (!sw.open) return false;
    sw.w = std.math.clamp(sw.w, min_w, @max(min_w, w - 20));
    sw.h = std.math.clamp(sw.h, min_h, @max(min_h, h - 20));
    sw.x = std.math.clamp(sw.x, 0, @max(0, w - sw.w));
    sw.y = std.math.clamp(sw.y, 0, @max(0, h - sw.h));
    const x = sw.x;
    const y = sw.y;
    const ww = sw.w;
    const hh = sw.h;

    // ── 窗口外壳（共享 `util.windowChrome`；缩放柄 id = 9541——9521 被 toggle2 占着）──
    // 关闭 → 等同“取消”（丢弃待应用改动）
    if (util.windowChrome(ui, 9520, 9541, "设置", title_h, 24, &sw.x, &sw.y, &sw.w, &sw.h, &sw.grab_dx, &sw.grab_dy, &sw.resize_w0, &sw.resize_h0, &sw.resize_mx, &sw.resize_my, true)) {
        sw.open = false;
        app.settings_draft = null;
        return true;
    }

    // 打开时建一份**待应用副本**：所有控件只改它，点“应用”才真正生效。
    // 为什么要草案：UI 缩放如果边拖边生效，缩放变了滑块又跟着变，手感糊成一团（实测）。
    if (app.settings_draft == null) {
        app.settings_draft = .{
            .open_last = app.settings_open_last,
            .fps = app.fps_limit,
            .fps_idle = app.fps_idle,
            .ui_scale_auto = app.ui_scale_auto,
            .ui_scale = if (app.ui_scale_auto) app.ui_scale_detected else app.ui_scale,
            .audio_backend = audio_pref.current.backend,
        };
        app.settings_draft.?.setAudioDevice(audio_pref.current.deviceName());
    }
    const d = &app.settings_draft.?;
    // “应用”是否可点：草案与当前生效值有差异才有意义（未改动 → 置灰）
    const dirty = d.open_last != app.settings_open_last or
        d.fps != app.fps_limit or
        d.fps_idle != app.fps_idle or
        d.ui_scale_auto != app.ui_scale_auto or
        (!d.ui_scale_auto and @abs(d.ui_scale - app.ui_scale) > 0.001) or
        d.audio_backend != audio_pref.current.backend or
        !std.mem.eql(u8, d.audioDevice(), audio_pref.current.deviceName());

    // ── 内容区（可滚动；底部按钮条不随之滚动）──
    // 页面总高写死在这里：加/删段时同步调（不然滚不到底）。
    const foot_h: i32 = 34;
    const content_top = y + title_h + 1;
    const content_vis: i32 = hh - title_h - 1 - foot_h;
    const total_h: i32 = sw.content_h;
    const max_scroll: i32 = @max(0, total_h - content_vis);
    if (util.hitUI(ui, x + 1, content_top, ww - 2, content_vis)) {
        // 鼠标在**输出设备列表**里**且该列表真能滚**时 → 只滚那一栏；
        // 列表内容装得下时不抢滚轮（否则明明没东西可滚却把整页锁死，用户实测不爽）。
        const in_dev = sw.device_scrollable and util.hitUI(ui, sw.device_rect[0], sw.device_rect[1], sw.device_rect[2], sw.device_rect[3]);
        if (!in_dev) sw.scroll = std.math.clamp(sw.scroll - ui.wheel * 28, 0, max_scroll);
    }
    sw.scroll = std.math.clamp(sw.scroll, 0, max_scroll);
    const saved_clip = ui.renderer.pushClip(x + 1, content_top, ww - 2, content_vis);

    // **防空点穿透**：指针不在内容区（在标题栏/底栏/窗口外）时，把这一帧的鼠标坐标
    // 挪到屏外——否则滚上去的条目虽然被裁剪得看不见，**命中判定仍然有效**，
    // 点标题栏会连带点到它（实测 bug）。拖窗口/拖缩放柄中（9520/9541）也要屏蔽。
    const pointer_in_content = util.hitUI(ui, x + 1, content_top, ww - 2, content_vis);
    const chrome_active = ui.active_id == 9520 or ui.active_id == 9541;
    const saved_mx = ui.mouse_x;
    const saved_my = ui.mouse_y;
    if (!pointer_in_content and (ui.active_id == 0 or chrome_active)) {
        ui.mouse_x = -100000;
        ui.mouse_y = -100000;
    }

    // ── 启动程序时 ──
    var yy = content_top + 12 - sw.scroll;
    ui.label("启动程序时", x + 14, yy, ui.theme.text_dim);
    if (ui.toggle2(9521, "打开上次工程", "新建空工程", d.open_last, x + 14, yy + 16, 280, 24)) {
        d.open_last = !d.open_last;
    }
    yy += 56;

    // ── 帧率（忙时上限 / 闲置）──
    // 两个推子并排：左 = 忙时（播放/拖拽/动画期间的上限），右 = 完全无事+最小化时的档位。
    // 数字本身在推子里显示（“推子 120”），右侧只补一个单位词“fps”——
    // 再重复一遍数字（旧版“推子120 120fps”）是冗余。
    // **闲置 ≤ 最高**：闲置推子的上限就是最高推子的当前值；最高往下拖时闲置跟着
    // 削峰（不削会出现“闲置比忙时还快”的怪状态），最高往上调时闲置不跟着动。
    ui.label("最高帧率", x + 14, yy, ui.theme.text_dim);
    var fps = d.fps;
    if (ui.dragNumber(9522, x + 14, yy + 16, 64, 22, &fps, 30, 360, 2)) {
        d.fps = fps;
        if (d.fps_idle > d.fps) d.fps_idle = d.fps; // 闲置随最高削峰（上调不跟随）
    }
    ui.label("fps", x + 82, yy + 20, ui.theme.text);
    ui.label("闲置帧率", x + 160, yy, ui.theme.text_dim);
    var fps_idle = d.fps_idle;
    if (ui.dragNumber(9523, x + 160, yy + 16, 64, 22, &fps_idle, 30, d.fps, 2)) {
        d.fps_idle = fps_idle;
    }
    ui.label("fps", x + 228, yy + 20, ui.theme.text);
    ui.label("（闲置 ≤ 最高；完全无事或最小化时降到闲置档，任何操作立即回满速）", x + 14, yy + 44, ui.theme.text_dim);
    yy += 68;

    // ── 数据交换：JSON 通道已于 v9 删除（存档只剩二进制 `.saw`）──

    // ── 界面缩放（DPI）──
    // 上层是“自动”，下面是 5% 档位滑块（75% – 400%）。手拖滑块 = 自动取消。
    ui.label("界面缩放", x + 14, yy, ui.theme.text_dim);
    {
        if (ui.toggleSquare(d.ui_scale_auto, x + 14, yy + 18, 16)) {
            d.ui_scale_auto = !d.ui_scale_auto;
            if (d.ui_scale_auto) d.ui_scale = app.ui_scale_detected; // 勾上 = 跟随检测值
        }
        const auto_txt = if (d.ui_scale_auto) "自动（每次启动重新检测）" else "手动（用下面的倍率）";
        ui.label(auto_txt, x + 36, yy + 18, ui.theme.text);

        // 检测到的值 + 人话依据（即使不是自动模式也显示：方便用户“一键采用”）
        var db2: [160]u8 = undefined;
        const det = app.uiScaleDetail();
        const src = app.ui_scale_src.label();
        const hint = if (det.len > 0)
            std.fmt.bufPrint(&db2, "检测到 {d:.0}%（{s}：{s}）", .{ app.ui_scale_detected * 100.0, src, det }) catch ""
        else if (app.ui_scale_src == .settings)
            std.fmt.bufPrint(&db2, "使用设置中的固定值 {d:.0}%", .{app.ui_scale * 100.0}) catch ""
        else
            std.fmt.bufPrint(&db2, "未检测到缩放设置（{s}）", .{src}) catch "";
        ui.label(hint, x + 14, yy + 42, ui.theme.text_dim);

        // 5% 步进滑块：0..1 映射到 75%..400%（65 格）
        // **只改草案**：点“应用”才真正改缩放（否则拖一下就凭缩放重排，手感很差）。
        var t: f32 = (d.ui_scale - 0.75) / (4.0 - 0.75);
        if (ui.slider(9530, &t, x + 14, yy + 62, ww - 28, 20)) {
            const pct: i32 = 75 + @as(i32, @intFromFloat(@round(t * 65.0))) * 5;
            d.ui_scale = @as(f32, @floatFromInt(pct)) / 100.0;
            d.ui_scale_auto = false; // 手拖 = 改成固定值
        }
        // 刻度：100/125/150/200/300（只标个位置，不参与交互）
        for ([_]i32{ 100, 125, 150, 200, 300 }) |pct| {
            const tx = x + 14 + @as(i32, @intFromFloat((@as(f32, @floatFromInt(pct)) / 100.0 - 0.75) / (4.0 - 0.75) * @as(f32, @floatFromInt(ww - 28))));
            ui.renderer.vline(tx, yy + 84, 3, ui.theme.panel_border);
            var tb: [8]u8 = undefined;
            ui.label(std.fmt.bufPrint(&tb, "{d}", .{pct}) catch "", tx - 8, yy + 88, ui.theme.text_dim);
        }
        var vb: [40]u8 = undefined;
        const shown_pct = if (d.ui_scale_auto) app.ui_scale_detected * 100.0 else d.ui_scale * 100.0;
        ui.label(std.fmt.bufPrint(&vb, "{d:.0}%{s}", .{ shown_pct, if (d.ui_scale_auto) "（自动）" else "（待应用）" }) catch "", x + 14, yy + 104, ui.theme.text);
    }
    yy += 136;

    // ── 字体（当前实际生效的文件 + 自选）──
    ui.label("字体（当前生效）", x + 14, yy, ui.theme.text_dim);
    ui.label(font_info.active(), x + 14, yy + 16, ui.theme.text);
    if (ui.button(9525, "选择字体文件…", x + 14, yy + 36, 120, 22)) {
        app.requestPick(.{ .kind = .open, .use_ = .font_file, .title = "选择字体文件", .filter = "字体 (*.ttf;*.ttc;*.otf)|*.ttf;*.ttc;*.otf" });
    }
    if (ui.button(9526, "恢复自动", x + 140, yy + 36, 80, 22)) {
        app.setFontPath("");
        font_info.reload_requested = true;
    }
    if (ui.button(9527, "重新加载", x + 226, yy + 36, 80, 22)) {
        font_info.reload_requested = true; // 主循环帧首重跑查找（装完新字体不用重启）
    }
    ui.label("预览：中文 ABC 123 ♪ ⏵ 文件.saw", x + 14, yy + 64, ui.theme.text);
    ui.label("自动顺序：设置里的字体 → fontconfig → 系统字体名单", x + 14, yy + 82, ui.theme.text_dim);
    ui.label("→ data/fonts/ → 任意系统字体。", x + 14, yy + 96, ui.theme.text_dim);
    yy += 118;

    // ── 音频输出（改完重启生效）──
    // 分段控件：选中段用强调色（同设置页“打开上次工程/新建工程”与工具栏标签的观感）
    ui.label("音频后端（重启生效）", x + 14, yy, ui.theme.text_dim);
    {
        const seg_w: i32 = 96;
        const seg_h: i32 = 24;
        const n: i32 = @intCast(audio_pref.options.len);
        const total = seg_w * n;
        const sy = yy + 16;
        // 整条边框 + 分隔线
        ui.renderer.strokeRect(x + 14, sy, total, seg_h, ui.theme.panel_border);
        for (audio_pref.options, 0..) |opt, oi| {
            const sx = x + 14 + seg_w * @as(i32, @intCast(oi));
            const on = d.audio_backend == opt;
            const hovered = ui.hitRect(sx, sy, seg_w, seg_h);
            const bg = if (on) ui.theme.accent else if (hovered and ui.mouse_down) r_mod.rgb(70, 130, 200) else if (hovered) r_mod.rgb(60, 66, 76) else ui.theme.panel;
            ui.renderer.fillRect(sx, sy, seg_w, seg_h, bg);
            if (oi > 0) ui.renderer.vline(sx, sy, seg_h, ui.theme.panel_border);
            // `labelCentered` 只居中**纵向**（x 是左边缘）→ 横向自己算（同 `buttonEx`）
            const tw: i32 = @intFromFloat(ui.font.measure(audio_pref.label(opt)));
            ui.labelCentered(audio_pref.label(opt), sx + @divTrunc(seg_w - tw, 2), sy, seg_h, if (on) r_mod.rgb(240, 244, 250) else ui.theme.text);
            if (ui.hitRect(sx, sy, seg_w, seg_h) and ui.mouse_pressed) {
                d.audio_backend = opt;
                d.setAudioDevice(""); // 换后端时旧设备名没有可比性 → 回到系统默认
            }
        }
    }
    yy += 50;

    // ── 输出设备：当前后端的播放设备列表（含“系统默认”）──
    // 设备切换**立即生效**（同一后端内）；只有切换后端才需要重启
    ui.label("输出设备（立即生效；切换时声音会中断一瞬）", x + 14, yy, ui.theme.text_dim);
    const list_x = x + 14;
    const list_y = yy + 16;
    const list_w = ww - 28;
    const list_h: i32 = 104;
    const row_h: i32 = 22;
    const devices = app.engine.playbackDevices();
    const content_h: i32 = @intCast((devices.len + 1) * @as(usize, @intCast(row_h)));
    const max_dev_scroll = @max(0, content_h - list_h);
    const device_scrollable = max_dev_scroll > 0; // 装得下就**不**接管滚轮（让整页滚）
    sw.audio_device_scroll = std.math.clamp(sw.audio_device_scroll, 0, max_dev_scroll);
    if (device_scrollable and util.hitUI(ui, list_x, list_y, list_w, list_h)) {
        sw.audio_device_scroll = std.math.clamp(sw.audio_device_scroll - ui.wheel * row_h, 0, max_dev_scroll);
    }
    ui.renderer.fillRect(list_x, list_y, list_w, list_h, ui.theme.bg);
    ui.renderer.strokeRect(list_x, list_y, list_w, list_h, ui.theme.panel_border);
    const has_scroll = content_h > list_h;
    const sb_w: i32 = if (has_scroll) 6 else 0;
    {
        const saved = ui.renderer.pushClip(list_x + 1, list_y + 1, list_w - 2 - sb_w, list_h - 2);
        defer ui.renderer.popClip(saved);
        var row: usize = 0;
        while (row < devices.len + 1) : (row += 1) {
            const ry = list_y + @as(i32, @intCast(row)) * row_h - sw.audio_device_scroll;
            if (ry + row_h <= list_y or ry >= list_y + list_h) continue;
            const device_name: []const u8 = if (row == 0) "系统默认（由后端决定）" else devices[row - 1].label();
            const selected = std.mem.eql(u8, d.audioDevice(), if (row == 0) "" else device_name);
            const hovered = util.hitUI(ui, list_x + 1, ry, list_w - 2 - sb_w, row_h);
            const bg = if (selected) ui.theme.accent else if (hovered) ui.theme.item_hover else ui.theme.bg;
            ui.renderer.fillRect(list_x + 1, ry, list_w - 2 - sb_w, row_h, bg);
            var label_buf: [320]u8 = undefined;
            const label = if (row > 0 and devices[row - 1].is_default)
                std.fmt.bufPrint(&label_buf, "{s}（系统默认）", .{device_name}) catch device_name
            else
                device_name;
            ui.labelClipped(label, list_x + 8, ry + 4, list_w - 16 - sb_w, if (selected) r_mod.rgb(240, 244, 250) else ui.theme.text);
            if (hovered and ui.mouse_pressed) d.setAudioDevice(if (row == 0) "" else device_name);
        }
    }
    if (has_scroll) _ = ui.scrollbarV(9529, list_x + list_w - sb_w, list_y, sb_w, list_h, &sw.audio_device_scroll, content_h, list_h);
    // 记住列表矩形 + 能不能滚（供下一帧的滚轮分流）
    sw.device_rect = .{ list_x, list_y, list_w, list_h };
    sw.device_scrollable = device_scrollable;
    // 下一行从**列表底部**算起（原写法 `yy += list_h + 8` 漏了标题行那 16px，
    // “当前：…”会压在列表最下面一行上）
    yy = list_y + list_h + 8;

    // 底部：只有后端**已生效**才说“重启后生效”（草案未提交时什么也不写）
    if (audio_pref.saved) {
        ui.label("已保存，后端切换重启后生效", x + 14, yy, ui.theme.text);
    } else {
        var cb: [320]u8 = undefined;
        const selection = audio_pref.shown();
        const device = if (selection.deviceName().len == 0) "系统默认" else selection.deviceName();
        ui.label(std.fmt.bufPrint(&cb, "当前：{s} · {s}", .{ audio_pref.label(selection.backend), device }) catch "", x + 14, yy, ui.theme.text_dim);
    }
    yy += 16;
    // 回写内容总高：**必须与 scroll 无关**（yy 已经被 scroll 偏移过，加回来才不变），
    // 否则：滚到底 → content_h 变小 → 滚动上限变少 → 又被夹回去 → “自动回退两行”跳一下。
    // 末尾只留 ~8px 氧：值太大会出现“滚到底还多一行空白”（用户实测反馈）。
    sw.content_h = (yy - content_top) + sw.scroll + 8;

    // ── 内容区结束（恢复裁剪 + 恢复鼠标坐标）+ 底部按钮条（不随内容滚动）──
    ui.renderer.popClip(saved_clip);
    ui.mouse_x = saved_mx;
    ui.mouse_y = saved_my;
    const foot_y = y + hh - foot_h + 5;
    ui.renderer.fillRect(x + 1, y + hh - foot_h, ww - 2, foot_h - 1, ui.theme.toolbar);
    ui.label("改动需点“应用”才生效", x + 14, foot_y + 5, ui.theme.text_dim);
    if (dirty and ui.button(9538, "应用", x + ww - 172, foot_y, 76, 24)) {
        // 提交草案：缩放走 applyUiScale（立即生效 + 15 s 后不确认就回滚），其余直接写
        // 闲置随最高削峰（UI 已联动；这里兜底手改 settings.json 之类的来源）
        const open_last = d.open_last;
        const fps_want = std.math.clamp(d.fps, 30, 360);
        const fps_idle_want = std.math.clamp(d.fps_idle, 30, fps_want);
        const auto_want = d.ui_scale_auto;
        const scale_want = if (auto_want) app.ui_scale_detected else d.ui_scale;
        const be_want = d.audio_backend;
        const dev_want = d.audioDevice();
        // 音频：后端变了 = 重启生效；只改设备 = 引擎立即切换（由 main 帧末执行）。
        // 注：必须在清空草案**之前**把 `d` 里的值用完（`request*` 自己会拷贝，不会悬垂）。
        if (be_want != audio_pref.current.backend) {
            audio_pref.requestBackend(be_want);
            if (dev_want.len > 0) audio_pref.requestDevice(dev_want);
        } else if (!std.mem.eql(u8, dev_want, audio_pref.current.deviceName())) {
            audio_pref.requestDevice(dev_want);
        }
        app.settings_open_last = open_last;
        app.fps_limit = fps_want;
        app.fps_idle = fps_idle_want;
        app.ui_scale_auto = auto_want;
        app.settings_dirty = true;
        app.settings_draft = null; // 下一帧按生效值重建 → “应用”自动变灰
        app.applyUiScale(scale_want, true); // 立即生效 + 15 s 内不确认就回滚（**不关窗**）
        return true;
    } else if (!dirty) {
        // 未改动 → 置灰（不响应点击）
        const bw: i32 = 76;
        ui.renderer.fillRect(x + ww - 172, foot_y, bw, 24, ui.theme.panel);
        ui.renderer.strokeRect(x + ww - 172, foot_y, bw, 24, ui.theme.panel_border);
        const tw: i32 = @intFromFloat(ui.font.measure("应用"));
        ui.labelCentered("应用", x + ww - 172 + @divTrunc(bw - tw, 2), foot_y, 24, ui.theme.text_dim);
    }
    if (ui.button(9539, "取消", x + ww - 90, foot_y, 76, 24)) {
        // 丢弃草案（已在预览中的缩放也回滚）
        if (app.scale_confirm != null) app.revertUiScale();
        app.settings_draft = null;
        sw.open = false;
        return true;
    }

    return util.inRect(ui.mouse_x, ui.mouse_y, x, y, ww, hh);
}
