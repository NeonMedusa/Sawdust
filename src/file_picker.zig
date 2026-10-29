//! 内置文件选择器（B 方案：**每帧推进的模态窗**，不阻塞主循环）。
//!
//! 为什么自绘：系统对话框（Win32 `GetOpenFileName` / Linux zenity·kdialog）都是同步模态，
//! 调用期间 UI 线程被占住 → 界面冻结 + 序列器调度前瞻（4 小节 ≈ 8~10 s）被耗干 → **音乐十秒后停**。
//! 自绘选择器把"选文件"变成普通的一帧帧 UI（输入被模态窗吞掉，但**渲染与音频照常**）。
//!
//! 刻意**极简**（搜索/书签/重命名留给系统对话框）：目录列表（目录优先）+ 双击进入 +
//! Enter/Esc + 保存模式的文件名框。
const std = @import("std");
const ui_mod = @import("ui.zig");
const util = @import("view_util.zig");
const port_io = @import("port_io.zig");
const text_edit = @import("text_edit.zig");
const app_mod = @import("app.zig");

const Ui = ui_mod.Ui;

pub const Mode = enum { open, save, folder };

pub const Outcome = union(enum) {
    pending,
    /// 调用方负责 free
    chosen: []u8,
    cancelled,
};

pub const Entry = struct {
    name: []u8,
    is_dir: bool,
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    use_: app_mod.PickUse,
    /// 取消时的提示（取自请求；标题是静态字面量，不释放）
    cancel_text: []const u8,
    title: []const u8,
    filter: []u8,
    /// 保存模式的文件名（编辑中）
    name_buf: [260]u8 = undefined,
    name_len: usize = 0,
    cwd: []u8,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    sel: i32 = -1,
    scroll: i32 = 0,
    /// 打开那一帧的点击只用于"打开"（本帧不处理，防穿透）
    just_opened: bool = true,
    /// 本帧键盘（由 main 的按键处理置位）
    want_cancel: bool = false,
    want_accept: bool = false,
    err_msg: ?[]const u8 = null,
    // ── 文本编辑（路径栏 / 保存文件名）──
    edit_target: EditTarget = .none,
    /// 已发出剪贴板请求、等数据到达后自动粘贴（X11 异步：否则要按两次 Ctrl+V）
    pending_paste: bool = false,
    edit_buf: [1024]u8 = undefined,
    edit_len: usize = 0,
    edit_cursor: usize = 0,
    /// 选区锚点（null / == 光标 = 无选区）
    edit_anchor: ?usize = null,
    /// 鼠标拖动框选中（按下未松手）
    edit_drag: bool = false,
    /// 光标闪烁起点（最近一次输入/移动/点击；`text_edit.blinkOnSince`）
    edit_epoch: i64 = 0,
    /// 编辑框横向滚动偏移（长路径也能看到光标处）
    edit_view_off: i32 = 0,
    /// 路径跳转失败（路径栏标红提示）
    edit_err: bool = false,

    pub fn deinit(self: *Picker) void {
        const a = self.allocator;
        for (self.entries.items) |e| a.free(e.name);
        self.entries.deinit(a);
        a.free(self.cwd);
        a.free(self.filter);
    }

    // ── 文本编辑（路径栏 / 保存文件名共用）──

    pub const EditTarget = enum { none, path, name };

    /// 开始编辑某个字段（复制当前文本、光标置尾）
    fn editBegin(self: *Picker, target: EditTarget) void {
        const src: []const u8 = switch (target) {
            .path => self.cwd,
            .name => self.name_buf[0..self.name_len],
            .none => return,
        };
        const n = @min(src.len, self.edit_buf.len);
        @memcpy(self.edit_buf[0..n], src[0..n]);
        self.edit_len = n;
        self.edit_cursor = n;
        self.edit_anchor = null;
        self.edit_drag = false;
        self.edit_view_off = 0;
        self.edit_epoch = text_edit.nowMs();
        self.edit_target = target;
        self.edit_err = false;
    }

    fn editEnd(self: *Picker) void {
        self.pending_paste = false;
        self.edit_target = .none;
        self.edit_anchor = null;
        self.edit_drag = false;
        self.edit_err = false;
        self.edit_view_off = 0;
    }

    fn editText(self: *const Picker) []const u8 {
        return self.edit_buf[0..self.edit_len];
    }

    pub fn isEditing(self: *const Picker) bool {
        return self.edit_target != .none;
    }

    fn editSel(self: *const Picker) ?text_edit.Sel {
        return text_edit.selRange(self.edit_cursor, self.edit_anchor, self.edit_len);
    }

    fn editTouch(self: *Picker) void {
        self.edit_epoch = text_edit.nowMs(); // 有输入 → 光标重新"先亮后灭"
    }

    /// 插入一个 code point（有选区 → 先删选区）
    pub fn editInsert(self: *Picker, ch: u21) void {
        if (self.edit_target == .none) return;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &tmp) catch return;
        _ = text_edit.insertSlice(self.edit_buf[0..], &self.edit_len, &self.edit_cursor, &self.edit_anchor, tmp[0..n]);
        self.editTouch();
    }

    /// 插入整串（粘贴用；有选区 → 先删选区）
    pub fn editInsertSlice(self: *Picker, s: []const u8) void {
        if (self.edit_target == .none) return;
        _ = text_edit.insertSlice(self.edit_buf[0..], &self.edit_len, &self.edit_cursor, &self.edit_anchor, s);
        self.editTouch();
    }

    pub fn editBackspace(self: *Picker) void {
        if (self.edit_target == .none) return;
        text_edit.deleteBackward(self.edit_buf[0..], &self.edit_len, &self.edit_cursor, &self.edit_anchor);
        self.editTouch();
    }

    pub fn editDelete(self: *Picker) void {
        if (self.edit_target == .none) return;
        text_edit.deleteForward(self.edit_buf[0..], &self.edit_len, &self.edit_cursor, &self.edit_anchor);
        self.editTouch();
    }

    /// ←/→（`extend` = Shift：拉选区）
    pub fn editMoveCursor(self: *Picker, dir: i32, extend: bool) void {
        if (self.edit_target == .none) return;
        text_edit.moveCursor(self.edit_buf[0..self.edit_len], self.edit_len, &self.edit_cursor, &self.edit_anchor, dir, extend);
        self.editTouch();
    }

    pub fn editHome(self: *Picker, extend: bool) void {
        if (self.edit_target == .none) return;
        text_edit.moveToStart(self.edit_len, &self.edit_cursor, &self.edit_anchor, extend);
        self.editTouch();
    }

    pub fn editEndPos(self: *Picker, extend: bool) void {
        if (self.edit_target == .none) return;
        text_edit.moveToEnd(self.edit_len, &self.edit_cursor, &self.edit_anchor, extend);
        self.editTouch();
    }

    pub fn editSelectAll(self: *Picker) void {
        if (self.edit_target == .none) return;
        text_edit.selectAll(self.edit_len, &self.edit_cursor, &self.edit_anchor);
        self.editTouch();
    }

    /// 鼠标单击定位光标（并开始拖动框选）
    pub fn editPointerDown(self: *Picker, idx: usize) void {
        if (self.edit_target == .none) return;
        self.edit_cursor = idx;
        self.edit_anchor = idx;
        self.edit_drag = true;
        self.editTouch();
    }

    /// 拖动框选：光标跟手，锚点不动（拖出框外也继续跟）
    pub fn editPointerMove(self: *Picker, idx: usize) void {
        if (self.edit_target == .none or !self.edit_drag) return;
        self.edit_cursor = idx;
        self.editTouch();
    }

    pub fn editPointerUp(self: *Picker) void {
        self.edit_drag = false;
    }

    /// 当前"被复制/剪切"的内容：有选区 → 选区；否则 → 整个字段
    /// （路径栏里直接 Ctrl+C 就能复制整条路径）
    pub fn editSelectionText(self: *const Picker) ?[]const u8 {
        if (self.edit_target == .none) return null;
        if (self.editSel()) |sel| return text_edit.selText(self.editText(), sel);
        if (self.edit_len == 0) return null;
        return self.editText();
    }

    /// 剪切：有选区删选区，否则清空整个字段
    pub fn editClearSelection(self: *Picker) void {
        if (self.edit_target == .none) return;
        if (text_edit.deleteSelection(self.edit_buf[0..], &self.edit_len, &self.edit_cursor, &self.edit_anchor)) {
            self.editTouch();
            return;
        }
        self.edit_len = 0;
        self.edit_cursor = 0;
        self.edit_anchor = null;
        self.editTouch();
    }

    /// Enter：路径 → 尝试跳转（失败标红、保留编辑态）；文件名 → 提交
    fn editCommit(self: *Picker) Outcome {
        switch (self.edit_target) {
            .path => {
                const target = self.editText();
                if (target.len == 0) {
                    self.edit_err = true;
                    return .pending;
                }
                const io = port_io.blocking();
                var dir = std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true }) catch {
                    self.edit_err = true; // 保留编辑态，让用户接着改
                    return .pending;
                };
                dir.close(io);
                const next = self.allocator.dupe(u8, target) catch return .pending;
                self.allocator.free(self.cwd);
                self.cwd = next;
                self.editEnd();
                reload(self);
                return .pending;
            },
            .name => {
                const name = self.editText();
                if (name.len == 0) return .pending;
                self.name_len = @min(name.len, self.name_buf.len);
                @memcpy(self.name_buf[0..self.name_len], name[0..self.name_len]);
                self.editEnd();
                return choose(self, self.name_buf[0..self.name_len]);
            },
            .none => return .pending,
        }
    }

    fn selected(self: *const Picker) ?Entry {
        if (self.sel < 0) return null;
        const i: usize = @intCast(self.sel);
        if (i >= self.entries.items.len) return null;
        return self.entries.items[i];
    }
};

/// 打开选择器（起始目录 = 主目录或上次目录）
pub fn begin(allocator: std.mem.Allocator, req: app_mod.PickRequest) !Picker {
    const filter = try allocator.dupe(u8, req.filter);
    errdefer allocator.free(filter);
    const start = req.start_dir;

    var p: Picker = .{
        .allocator = allocator,
        .mode = switch (req.kind) {
            .open => .open,
            .save => .save,
            .folder => .folder,
        },
        .use_ = req.use_,
        .cancel_text = req.cancelText(),
        .title = req.title,
        .filter = filter,
        .cwd = &.{},
    };
    if (req.default_name.len > 0) {
        p.name_len = @min(req.default_name.len, p.name_buf.len);
        @memcpy(p.name_buf[0..p.name_len], req.default_name[0..p.name_len]);
    }
    p.cwd = try allocator.dupe(u8, if (start.len > 0) start else homeDir());
    reload(&p);
    return p;
}

fn homeDir() []const u8 {
    if (std.c.getenv("HOME")) |h| return std.mem.span(h);
    return "/";
}

/// 重新读取 `cwd`（目录优先 → 名字升序；按过滤器筛文件）
pub fn reload(self: *Picker) void {
    const a = self.allocator;
    for (self.entries.items) |e| a.free(e.name);
    self.entries.clearRetainingCapacity();
    self.sel = -1;
    self.scroll = 0;
    self.err_msg = null;

    const io = port_io.blocking();
    var dir = std.Io.Dir.cwd().openDir(io, self.cwd, .{ .iterate = true }) catch {
        self.err_msg = "无法打开该目录";
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const is_dir = e.kind == .directory;
        if (!is_dir) {
            if (self.mode == .folder) continue;
            if (!matchesFilter(self.filter, e.name)) continue;
        }
        const name = a.dupe(u8, e.name) catch continue;
        self.entries.append(a, .{ .name = name, .is_dir = is_dir }) catch {
            a.free(name);
            continue;
        };
    }
    const Ctx = struct {
        fn lessThan(_: void, x: Entry, y: Entry) bool {
            if (x.is_dir != y.is_dir) return x.is_dir; // 目录排前面
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    };
    std.mem.sort(Entry, self.entries.items, {}, Ctx.lessThan);
}

/// 过滤器匹配：`描述\0*.wav;*.flac\0…`（无模式 → 全通过）
pub fn matchesFilter(filter: []const u8, name: []const u8) bool {
    if (filter.len == 0) return true;
    var any = false;
    var it = std.mem.splitScalar(u8, filter, 0);
    while (it.next()) |desc_raw| {
        _ = desc_raw;
        const pats = it.next() orelse break;
        var pit = std.mem.splitScalar(u8, pats, ';');
        while (pit.next()) |pat| {
            const p = std.mem.trim(u8, pat, " ");
            if (p.len == 0) continue;
            any = true;
            if (std.mem.eql(u8, p, "*.*") or std.mem.eql(u8, p, "*")) return true;
            if (p.len > 2 and p[0] == '*' and p[1] == '.') {
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    if (std.ascii.eqlIgnoreCase(name[dot + 1 ..], p[2..])) return true;
                }
                continue;
            }
            if (std.mem.eql(u8, p, name)) return true;
        }
    }
    return !any;
}

fn enterDir(self: *Picker, name: []const u8) void {
    const a = self.allocator;
    const next = std.fs.path.join(a, &.{ self.cwd, name }) catch return;
    a.free(self.cwd);
    self.cwd = next;
    reload(self);
}

fn goUp(self: *Picker) void {
    const parent = std.fs.path.dirname(self.cwd) orelse return;
    const next = self.allocator.dupe(u8, parent) catch return;
    self.allocator.free(self.cwd);
    self.cwd = next;
    reload(self);
}

fn choose(self: *Picker, name: []const u8) Outcome {
    const path = std.fs.path.join(self.allocator, &.{ self.cwd, name }) catch return .cancelled;
    return .{ .chosen = path };
}

/// 每帧绘制（模态窗，绘于最上层）。返回待处理结果。
pub fn draw(ui: *Ui, self: *Picker, w: i32, h: i32) Outcome {
    const just = self.just_opened;
    self.just_opened = false;

    // 键盘（main 的按键处理翻译成这两个标志）。
    // ⚠️ 这里**不能提前 return**：提前返回会让这一帧整个面板（连暗化层）都不画，
    // 表现为"选择器闪一下"。所以先只改状态，取消动作留到画完再执行。
    var close_now = false;
    if (self.want_cancel) {
        self.want_cancel = false;
        if (self.isEditing()) {
            self.editEnd(); // Esc 只退出编辑（不生效）
        } else {
            close_now = true;
        }
    }

    // 全屏暗化；点窗外 = 取消
    ui.renderer.fillRect(0, 0, w, h, (@as(u32, 0x66) << 24) | 0x000000);
    const pw: i32 = 620;
    const ph: i32 = 460;
    const px = @divTrunc(w - pw, 2);
    const py = @divTrunc(h - ph, 2);
    if (!just and ui.mouse_pressed and !util.inRect(ui.mouse_x, ui.mouse_y, px, py, pw, ph)) {
        // 编辑中点窗外 = 放弃编辑（不生效）；否则 = 取消整个选择器
        if (self.isEditing()) {
            self.editEnd();
        } else {
            close_now = true;
        }
    }

    ui.panelTitled(px, py, pw, ph, self.title);

    // ── 路径栏 ──
    const bar_y = py + 22;
    ui.renderer.fillRect(px + 6, bar_y, pw - 12, 20, ui.theme.toolbar);
    const bar_w = pw - 12 - 84;
    if (self.edit_target == .path) {
        // 编辑中：标红 = 上次 Enter 跳转失败
        const border = if (self.edit_err) ui.theme.danger else ui.theme.accent;
        ui.renderer.strokeRect(px + 6, bar_y, bar_w, 20, border);
        self.edit_view_off = ui.textFieldSyncOffset(self.editText(), self.edit_cursor, bar_w - 8, self.edit_view_off);
        ui.textFieldEx(self.editText(), self.edit_cursor, text_edit.selPair(self.editSel()), self.edit_view_off, px + 10, bar_y + 3, bar_w - 8, 16, text_edit.blinkOnSince(self.edit_epoch));
    } else {
        ui.labelClipped(self.cwd, px + 10, bar_y + 3, bar_w - 8, ui.theme.text_dim);
        if (!just and ui.mouse_pressed and util.inRect(ui.mouse_x, ui.mouse_y, px + 6, bar_y, bar_w, 20)) {
            self.editBegin(.path); // 点路径栏 → 进入编辑
            self.editPointerDown(self.edit_len); // 进入即把光标放到击点（下面是精确换算）
        }
    }
    // 路径栏编辑态：单击定位光标 / 按住拖动框选（拖出框外也跟手）
    if (self.edit_target == .path and !just) {
        const local: f32 = @floatFromInt(ui.mouse_x - (px + 10) + self.edit_view_off);
        if (ui.mouse_pressed and util.inRect(ui.mouse_x, ui.mouse_y, px + 6, bar_y, bar_w, 20)) {
            self.editPointerDown(ui.textIndexAtX(self.editText(), local));
        } else if (self.edit_drag) {
            if (ui.mouse_down) {
                self.editPointerMove(ui.textIndexAtX(self.editText(), local));
            } else {
                self.editPointerUp();
            }
        }
    }
    if (ui.button(8801, "上级", px + pw - 76, bar_y, 64, 20)) goUp(self);

    const has_name_row0 = self.mode == .save;
    const list_y0 = bar_y + 24;
    const name_row_h0: i32 = if (has_name_row0) 26 else 0;
    const list_h0 = ph - (list_y0 - py) - 34 - name_row_h0 - 6;
    // 编辑中点"非当前编辑框"的地方 → 放弃编辑（用户要求：不按 Enter 点别处 = 不生效）。
    // 列表/按钮的点击继续由后续代码处理（所以这里只是退出编辑，不吞掉这次点击）。
    if (self.isEditing() and !just and ui.mouse_pressed) {
        const in_path = self.edit_target == .path and util.inRect(ui.mouse_x, ui.mouse_y, px + 6, bar_y, pw - 12 - 84, 20);
        const name_row_y0 = list_y0 + list_h0 + 4;
        const in_name = self.edit_target == .name and has_name_row0 and util.inRect(ui.mouse_x, ui.mouse_y, px + 60, name_row_y0, pw - 72, 20);
        if (!in_path and !in_name) self.editEnd();
    }

    // ── 列表 ──
    const list_x = px + 6;
    const list_y = bar_y + 24;
    const list_w = pw - 12 - 12;
    const has_name_row = has_name_row0;
    const name_row_h: i32 = if (has_name_row) 26 else 0;
    const list_h = ph - (list_y - py) - 34 - name_row_h - 6;
    ui.renderer.fillRect(list_x, list_y, list_w + 12, list_h, ui.theme.panel);
    const row_h: i32 = 20;
    const content_h: i32 = @as(i32, @intCast(self.entries.items.len)) * row_h;
    if (util.inRect(ui.mouse_x, ui.mouse_y, list_x, list_y, list_w + 12, list_h) and ui.wheel != 0) {
        self.scroll -= ui.wheel * row_h * 3;
        ui.wheel = 0;
    }
    _ = ui.scrollbarV(8802, list_x + list_w + 2, list_y, 10, list_h, &self.scroll, content_h, list_h);
    self.scroll = std.math.clamp(self.scroll, 0, @max(0, content_h - list_h));

    if (self.err_msg) |m| ui.label(m, list_x + 8, list_y + 6, ui.theme.danger);

    var i: usize = 0;
    while (i < self.entries.items.len) : (i += 1) {
        const ey = list_y + @as(i32, @intCast(i)) * row_h - self.scroll;
        if (ey + row_h <= list_y or ey >= list_y + list_h) continue;
        const e = self.entries.items[i];
        const hovered = !just and util.inRect(ui.mouse_x, ui.mouse_y, list_x, ey, list_w, list_h) and util.inRect(ui.mouse_x, ui.mouse_y, list_x, ey, list_w, row_h);
        const is_sel = self.sel == @as(i32, @intCast(i));
        if (is_sel) ui.renderer.fillRect(list_x, ey, list_w, row_h, ui.theme.item_selected);
        if (hovered and !is_sel) ui.renderer.fillRect(list_x, ey, list_w, row_h, ui.theme.item_hover);
        var nb: [320]u8 = undefined;
        const label = if (e.is_dir) std.fmt.bufPrint(&nb, "[{s}]", .{e.name}) catch e.name else e.name;
        ui.labelClipped(label, list_x + 6, ey + 3, list_w - 12, if (e.is_dir) ui.theme.accent else ui.theme.text);

        if (!just and hovered and ui.mouse_pressed) {
            self.sel = @intCast(i);
            if (e.is_dir) {
                if (ui.mouse_double) {
                    enterDir(self, e.name);
                    return .pending;
                }
            } else if (ui.mouse_double and self.mode == .open) {
                return choose(self, e.name);
            } else if (self.mode == .save) {
                self.name_len = @min(e.name.len, self.name_buf.len);
                @memcpy(self.name_buf[0..self.name_len], e.name[0..self.name_len]);
            }
        }
    }

    // ── 文件名（保存模式）──
    var by = list_y + list_h + 4;
    if (has_name_row) {
        ui.label("文件名", px + 8, by + 3, ui.theme.text_dim);
        ui.renderer.fillRect(px + 60, by, pw - 60 - 12, 20, ui.theme.toolbar);
        if (self.edit_target == .name) {
            ui.renderer.strokeRect(px + 60, by, pw - 72, 20, ui.theme.accent);
            self.edit_view_off = ui.textFieldSyncOffset(self.editText(), self.edit_cursor, pw - 80, self.edit_view_off);
            ui.textFieldEx(self.editText(), self.edit_cursor, text_edit.selPair(self.editSel()), self.edit_view_off, px + 64, by + 3, pw - 80, 16, text_edit.blinkOnSince(self.edit_epoch));
        } else {
            ui.textField(self.name_buf[0..self.name_len], self.name_len, null, 0, px + 64, by + 3, pw - 74, 18);
            if (!just and ui.mouse_pressed and util.inRect(ui.mouse_x, ui.mouse_y, px + 60, by, pw - 72, 20)) {
                self.editBegin(.name); // 点文件名 → 进入编辑
                self.editPointerDown(self.edit_len);
            }
        }
        // 文件名编辑态：单击定位 / 拖动框选
        if (self.edit_target == .name and !just) {
            const field_x = px + 64;
            const local: f32 = @floatFromInt(ui.mouse_x - field_x + self.edit_view_off);
            if (ui.mouse_pressed and util.inRect(ui.mouse_x, ui.mouse_y, px + 60, by, pw - 72, 20)) {
                self.editPointerDown(ui.textIndexAtX(self.editText(), local));
            } else if (self.edit_drag) {
                if (ui.mouse_down) {
                    self.editPointerMove(ui.textIndexAtX(self.editText(), local));
                } else {
                    self.editPointerUp();
                }
            }
        }
        by += 26;
    }

    // ── 底部按钮 ──
    const bw: i32 = 96;
    const bh: i32 = 22;
    const byy = py + ph - 28;
    const bx = px + pw - 12 - bw;
    const ok_text: []const u8 = switch (self.mode) {
        .open => "打开",
        .save => "保存",
        .folder => "选此目录",
    };
    const accept = self.want_accept;
    self.want_accept = false;
    // 编辑中按 Enter：先提交编辑（路径跳转 / 文件名确定），不直接关窗
    if (accept and self.isEditing()) return self.editCommit();
    const clicked_ok = ui.button(8803, ok_text, bx, byy, bw, bh);
    if (clicked_ok and self.isEditing()) return self.editCommit(); // 点“保存/打开”也先提交编辑内容
    if (clicked_ok or accept) {
        switch (self.mode) {
            .open => {
                if (self.selected()) |e| {
                    if (e.is_dir) {
                        enterDir(self, e.name);
                        return .pending;
                    }
                    return choose(self, e.name);
                }
            },
            .folder => {
                // 选"当前目录"：直接返回 cwd（不要拼 "."，避免出现 /a/b/. 这种路径）
                const path = self.allocator.dupe(u8, self.cwd) catch return .cancelled;
                return .{ .chosen = path };
            },
            .save => {
                if (self.name_len > 0) return choose(self, self.name_buf[0..self.name_len]);
            },
        }
    }
    if (ui.button(8804, "取消", bx - bw - 8, byy, bw, bh)) return .cancelled;

    if (close_now) return .cancelled; // Esc / 点窗外：面板已画完，这一帧照常呈现
    return .pending;
}
