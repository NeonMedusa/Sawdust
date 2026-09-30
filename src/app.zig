//! 应用状态（App）：文档数据 + 各视图状态 + 布局 + 方法。
//!
//! **结构原则**：视图（view_*.zig）只读写本文件的状态，绘制逻辑不在本文件。
//! 字段按归属分组为子结构体（`playlist` / `piano` / `rack` / `panels` / `sel`），
//! 避免 50+ 个平铺字段互相混淆。

const std = @import("std");
const audio = @import("audio.zig");
const model = @import("model.zig");
const synth = @import("synth.zig");
const sequencer = @import("sequencer.zig");
const persist = @import("persist.zig");

pub const Clip = model.Clip;
pub const Note = model.Note;
pub const Instrument = model.Instrument;
pub const NoteHitMode = model.NoteHitMode;

/// 界面布局（可调参数，持久状态）
pub const Layout = struct {
    left_w: i32 = 0,
    mid_w: i32 = 0,
    initialized: bool = false,

    pub fn initIfNeeded(self: *Layout, total_w: i32) void {
        if (self.initialized) return;
        // 默认列宽：历史 140px / 样式 140px（固定宽，不随窗口比例缩放）
        _ = total_w;
        self.left_w = 140;
        self.mid_w = 140;
        self.initialized = true;
    }
};

/// 文件菜单动作（帧末统一执行）
pub const FileAction = enum { open, save, save_as };

/// 脏确认流程的**目标动作**（确认框按钮相同，但“保存后”要执行不同的事）
pub const PendingIntent = enum {
    /// 保存后退出程序
    quit,
    /// 保存后打开另一个工程（用户已在系统对话框里选了文件）
    open,
};

/// 脏确认流程状态（拦截动作 → 自绘模态确认 → 执行）
/// 共用场景：退出程序 / 打开其他工程（都会丢失未保存修改）
pub const DirtyFlow = enum {
    /// 无流程
    none,
    /// 正在显示确认框
    confirming,
    /// 用户选了“保存后再继续”（等保存完成）
    save_then,
};

/// 模态对话框种类（自绘；避开系统 MessageBox 的“鼠标跳默认按钮”）
pub const ModalKind = enum { dirty_confirm };

/// 脏确认框的用户选择
pub const QuitChoice = enum { save, discard, cancel };

/// 选择状态（三个视图共享的“当前编辑对象”）
pub const Selection = struct {
    /// 选中的样式序号
    pattern: i32 = 0,
    /// 选中的轨道序号
    track: i32 = 0,
    /// 当前编辑的乐器（钢琴卷帘归属；0 起，-1 = 无）
    instrument: i32 = 0,
    /// SONG（播放全曲）还是 PAT（播放当前样式）
    song_mode: bool = true,
};

/// 播放列表视图状态
pub const PlaylistState = struct {
    /// 轨道行高（像素；□ 缺口缩放）
    track_h: i32 = 44,
    /// 纵向滚动（像素）
    scroll: i32 = 0,
    /// 横向滚动（内容像素；视口左缘）
    scroll_x: i32 = 0,
    /// 时间轴内容长度（内容像素；下限 = 实际内容右缘）
    content_w: i32 = 0,
    /// 横向缩放（屏幕像素 / 内容像素）
    zoom: f32 = 1.0,
    /// 量化/吸附网格档位（`model.snap_denoms` 下标；**与钢琴卷帘独立**）
    snap: i32 = 2, // 默认 1/4
    /// 吸附网格下拉选单：展开中
    snap_menu_open: bool = false,

    /// 片段拖动状态（下标 + 抓取点在小节内的偏移）
    drag_clip: ?usize = null,
    drag_grab: i32 = 0,
    /// 片段拉伸状态（下标）
    resize_clip: ?usize = null,
    /// 拉伸的是左缘（true，折叠/展开）还是右缘（false，改长度）
    resize_left: bool = false,
    /// 拉伸中的最短长度（步；按下时 = 吸附格——**放行拉长、阻止收回**）
    resize_min_len: i32 = 1,
    /// 右键擦除拖动中（按住右键划过片段即删）
    erase_drag: bool = false,
};

/// 钢琴卷帘视图状态
pub const PianoState = struct {
    /// 当前编辑的样式序号（null = 在播放列表视图）
    pattern: ?i32 = null,
    /// 音高行高（像素；□ 缺口缩放）
    key_h: i32 = 12,
    /// 纵向滚动（像素）
    scroll: i32 = 0,
    /// 横向滚动（内容像素）
    scroll_x: i32 = 0,
    /// 时间轴内容宽度（内容像素；最小 = 可视宽度）
    content_w: i32 = 0,
    /// 横向缩放（屏幕像素 / 内容像素）
    zoom: f32 = 1.0,

    /// 音符拖动状态（下标 + 抓取偏移：步 / 音高）
    drag_note: ?usize = null,
    drag_grab_step: i32 = 0,
    drag_grab_pitch: i32 = 0,
    /// 音符拖动模式：移动（body）/ 拖左缘（改起点+长度，右端不动）/ 拖右缘（改长度）
    drag_note_mode: NoteHitMode = .body,
    /// 拖左缘时的固定右端（步）
    drag_note_right: i32 = 0,
    /// 拖动中的最短长度（步；按下时 = 吸附格——**放行拉长、阻止收回**）
    drag_min_len: i32 = 1,

    /// 量化/吸附网格档位（`model.snap_denoms` 下标；控制音符移动/拉伸对齐）
    snap: i32 = 2, // 默认 1/4
    /// 吸附网格下拉选单：展开中
    snap_menu_open: bool = false,

    /// 正在试听的音高（null = 无）——**单一真源**：
    /// 琴键点击、音符放置、音符拖动换音都写它；行高亮/琴键高亮/发声都由它派生。
    held_pitch: ?i32 = null,
};

/// 通道机架（浮动窗口）状态
pub const RackState = struct {
    // ── 窗口几何 ──
    open: bool = true,
    x: i32 = 200,
    y: i32 = 110,
    w: i32 = 620,
    h: i32 = 300,
    /// 标题栏拖动抓取偏移
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    /// 缩放起点快照
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 行列表滚动（像素）
    scroll: i32 = 0,
    /// 右键菜单打开位置（固定，不跟鼠标跑）
    ctx_x: i32 = 0,
    ctx_y: i32 = 0,

    // ── 下拉菜单 ──
    /// 乐器选择下拉菜单：展开中
    inst_menu_open: bool = false,
    /// 添加乐器的下拉菜单：展开中
    add_menu_open: bool = false,
    /// 右键菜单中的乐器（删除用；null = 未展开）
    ctx_instrument: ?usize = null,
    /// 乐器选择器按钮矩形（标尺行左端空位；由视图绘制时写入，下拉菜单用）
    inst_btn_x: i32 = 0,
    inst_btn_y: i32 = 0,
    inst_btn_w: i32 = 0,
    inst_btn_h: i32 = 0,
};

/// 播放状态（游标 + 传输）——设计原则：
/// **单一真源是 `song_step`（全局步）**：
/// - SONG 模式：游标就是它；
/// - PAT 模式：游标 = `piano_step`（自由设置，独立存储）；
/// - 播放推进由**音频采样时钟**（frames_played）驱动，不由渲染驱动。
pub const Playback = struct {
    /// 全局播放位置（步；0 = 第 1 小节第 1 步）
    song_step: i32 = 0,
    /// PAT 模式的局部播放位置（步）
    piano_step: i32 = 0,
    /// 播放开始时的帧计数（由 main 在开始播放时写入）
    start_frame: u64 = 0,
    /// 游玩时的起始步（暂停/恢复用）
    start_step: i32 = 0,

    /// 当前显示的游标位置（步）
    pub fn cursorStep(self: *const Playback, song_mode: bool) i32 {
        return if (song_mode) self.song_step else self.piano_step;
    }
};

/// 发声音高缓存（每帧从音频线程回传的位掩码展开；供视图高亮用）
/// —— 只关心**当前乐器**：索引 = 音高（0-127）
pub const SoundingPitches = struct {
    flags: [128]bool = [_]bool{false} ** 128,

    pub fn set(self: *SoundingPitches, lo: u64, hi: u64) void {
        for (0..64) |i| self.flags[i] = (lo & (@as(u64, 1) << @intCast(i))) != 0;
        for (0..64) |i| self.flags[64 + i] = (hi & (@as(u64, 1) << @intCast(i))) != 0;
    }

    pub fn isSounding(self: *const SoundingPitches, pitch: i32) bool {
        if (pitch < 0 or pitch > 127) return false;
        return self.flags[@intCast(pitch)];
    }
};

/// 左右两个列表面板（历史/样式）状态
pub const PanelsState = struct {
    history_scroll: i32 = 0,
    pattern_scroll: i32 = 0,
};

/// 合成器编辑器（浮动窗口）状态
pub const SynthWindow = struct {
    open: bool = true,
    x: i32 = 340,
    y: i32 = 150,
    w: i32 = 520,
    h: i32 = 300,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 当前编辑的乐器槽位（0 起）
    instrument: i32 = 0,
};

pub const App = struct {
    allocator: std.mem.Allocator,

    // ── 文档数据（所有视图共享）──
    /// 已放置的样式片段
    clips: std.ArrayListUnmanaged(Clip) = .{ .items = &.{}, .capacity = 0 },
    /// 钢琴窗音符（**局部坐标**：按样式 + 乐器归属）
    notes: std.ArrayListUnmanaged(Note) = .{ .items = &.{}, .capacity = 0 },
    /// 乐器列表（槽位；可多个同名）
    instruments: std.ArrayListUnmanaged(Instrument) = .{ .items = &.{}, .capacity = 0 },
    /// 已删除乐器的合成器参数（**延迟释放**）：音频线程可能仍持有指针，
    /// 立即 destroy 会造成 use-after-free。进程退出时才真正释放。
    retired_synths: std.ArrayListUnmanaged(*synth.SynthParams) = .{ .items = &.{}, .capacity = 0 },
    /// 音符事件队列（UI 推、音频线程消费）——试听/all_off
    events: synth.EventQueue = .{},
    /// 调度事件队列（序列器；UI 按 lookahead 提前推）
    sched_events: synth.SchedQueue = .{},
    /// 序列器调度状态（已调度到哪一步 + generation）
    scheduler: sequencer.Scheduler = .{},

    // ── 保存 / 加载（工程文件）──
    /// 当前工程路径（null = 尚未保存过）
    project_path: ?[]u8 = null,
    /// 脏标记（有未保存修改）——任何编辑操作置 true；保存/加载后置 false
    dirty: bool = false,
    /// 已应用到窗口标题的状态（脏标记 + 工程名；避免每帧刷 Win32）
    title_applied_dirty: bool = false,
    /// 已应用到窗口标题的工程名快照（null = 无）
    title_applied_name: ?[]u8 = null,
    /// 状态栏提示（短暂显示保存/加载结果；null = 无）
    toast: ?[]u8 = null,
    /// toast 剩余帧数（main 每帧递减；到 0 清除）——约 60fps，180 帧 ≈ 3 秒
    toast_frames: i32 = 0,
    /// “文件”菜单展开中
    file_menu_open: bool = false,
    /// 待定的文件操作（帧末执行——对话框不能在事件迭代/绘制中弹出）。
    /// null = 无
    pending_file_action: ?FileAction = null,
    /// “文件”按钮位置（绘制时由工具栏写入；主循环用于菜单定位）
    file_menu_x: i32 = 8,
    file_menu_w: i32 = 140,

    // ── 模态对话框与脏确认流程 ──
    /// 当前模态框（null = 无）
    modal: ?ModalKind = null,
    /// 模态框的用户选择（鼠标点击 / 键盘 Enter/Esc 均写入这里）
    modal_choice: ?QuitChoice = null,
    /// 脏确认流程状态（拦截动作 → 确认 → 执行）
    dirty_flow: DirtyFlow = .none,
    /// 脏确认流程的目标动作（quit / open）
    dirty_intent: ?PendingIntent = null,
    /// 待打开的工程路径（用户已在系统对话框选好；等确认框决定后执行）
    pending_open_path: ?[]u8 = null,

    // ── 音频 ──
    params: audio.Params = .{},
    engine: audio.Engine = .{ .params = undefined },
    volume: f32 = 0.3,
    /// BPM（拍/分；工具栏可上下拖动调整；范围 20-999）
    bpm: i32 = 120,
    /// 拍号分子（每小节拍数；工具栏可拖动）
    time_num: i32 = 4,
    /// 拍号分母（以几分音符为一拍；工具栏可拖动）——**只允许 2 的幂**
    /// （1/2/4/8/16；配 U=96 时可精确表示）
    time_den: i32 = 4,
    /// 每小节步数（由拍号派生：`model.stepsPerBarFor`；拍号变更时同步）
    steps_per_bar: i32 = 96,
    playing: bool = false,

    // ── 各视图状态 ──
    sel: Selection = .{},
    playback: Playback = .{},
    /// 发声音高缓存（每帧从音频回传更新；供视图高亮）
    sounding: SoundingPitches = .{},
    layout: Layout = .{},
    playlist: PlaylistState = .{},
    piano: PianoState = .{},
    rack: RackState = .{},
    panels: PanelsState = .{},
    synth_win: SynthWindow = .{},

    // ── 占位数据 ──
    history_items: []const []const u8 = &.{
        "创建项目",
        "添加样式 1",
        "绘制音符",
        "调整 BPM",
        "添加样式 2",
        "复制样式 1 → 3",
        "调整音量",
        "添加样式 4",
        "删除样式 5",
        "调整音符力度",
    },
    pattern_items: []const []const u8 = &.{
        "样式 1",
        "样式 2",
        "样式 3",
        "样式 4",
        "样式 5",
        "样式 6",
    },
    track_items: []const []const u8 = &.{
        "Track 1",   "Track 2",   "Track 3",   "Track 4",   "Track 5",
        "Track 6",   "Track 7",   "Track 8",   "Track 9",   "Track 10",
        "Track 11",  "Track 12",  "Track 13",  "Track 14",  "Track 15",
        "Track 16",  "Track 17",  "Track 18",  "Track 19",  "Track 20",
        "Track 21",  "Track 22",  "Track 23",  "Track 24",  "Track 25",
        "Track 26",  "Track 27",  "Track 28",  "Track 29",  "Track 30",
        "Track 31",  "Track 32",  "Track 33",  "Track 34",  "Track 35",
        "Track 36",  "Track 37",  "Track 38",  "Track 39",  "Track 40",
        "Track 41",  "Track 42",  "Track 43",  "Track 44",  "Track 45",
        "Track 46",  "Track 47",  "Track 48",  "Track 49",  "Track 50",
        "Track 51",  "Track 52",  "Track 53",  "Track 54",  "Track 55",
        "Track 56",  "Track 57",  "Track 58",  "Track 59",  "Track 60",
        "Track 61",  "Track 62",  "Track 63",  "Track 64",  "Track 65",
        "Track 66",  "Track 67",  "Track 68",  "Track 69",  "Track 70",
        "Track 71",  "Track 72",  "Track 73",  "Track 74",  "Track 75",
        "Track 76",  "Track 77",  "Track 78",  "Track 79",  "Track 80",
        "Track 81",  "Track 82",  "Track 83",  "Track 84",  "Track 85",
        "Track 86",  "Track 87",  "Track 88",  "Track 89",  "Track 90",
        "Track 91",  "Track 92",  "Track 93",  "Track 94",  "Track 95",
        "Track 96",  "Track 97",  "Track 98",  "Track 99",  "Track 100",
        "Track 101", "Track 102", "Track 103", "Track 104", "Track 105",
        "Track 106", "Track 107", "Track 108", "Track 109", "Track 110",
        "Track 111", "Track 112", "Track 113", "Track 114", "Track 115",
        "Track 116", "Track 117", "Track 118", "Track 119", "Track 120",
        "Track 121", "Track 122", "Track 123", "Track 124", "Track 125",
        "Track 126", "Track 127", "Track 128",
    },

    // ── 方法 ──

    /// 放置一个样式片段（分配失败时静默忽略）
    pub fn addClip(self: *App, c: Clip) void {
        self.clips.append(self.allocator, c) catch {};
        self.dirty = true;
    }

    /// 添加一个音符（分配失败时静默忽略）
    pub fn addNote(self: *App, n: Note) void {
        self.notes.append(self.allocator, n) catch {};
        self.dirty = true;
    }

    /// 添加乐器（自动分配名字与合成器参数）；返回新槽位序号（失败 -1）
    /// `base_name`：基础名（如 "减法合成器"）；同名自动追加 #2、#3…
    pub fn addInstrument(self: *App, base_name: []const u8) i32 {
        // 1) 生成不重复的名字：统计已有同名（忽略 #N 后缀）数量
        var same: usize = 0;
        for (self.instruments.items) |inst| {
            if (baseNameEquals(inst.name, base_name)) same += 1;
        }
        var name_buf: [64]u8 = undefined;
        const name_text = if (same == 0)
            std.fmt.bufPrint(&name_buf, "{s}", .{base_name}) catch base_name
        else
            std.fmt.bufPrint(&name_buf, "{s} #{d}", .{ base_name, same + 1 }) catch base_name;
        const name = self.allocator.dupe(u8, name_text) catch return -1;

        // 2) 分配该乐器自己的合成器参数（地址稳定——音频线程可安全读）
        const sp = self.allocator.create(synth.SynthParams) catch {
            self.allocator.free(name);
            return -1;
        };
        sp.* = .{};

        self.instruments.append(self.allocator, .{ .name = name, .synth = sp }) catch {
            self.allocator.free(name);
            self.allocator.destroy(sp);
            return -1;
        };
        self.dirty = true;
        return @intCast(self.instruments.items.len - 1);
    }

    /// 删除乐器槽位（同时删除其音符；合成器参数延迟释放；其余音符的槽位序号前移）
    pub fn removeInstrument(self: *App, idx: usize) void {
        if (idx >= self.instruments.items.len) return;
        self.dirty = true;
        const inst = self.instruments.items[idx];
        self.allocator.free(inst.name); // 名字只被 UI 线程使用，可立即释放
        // 合成器参数：音频线程可能仍持有该指针（异步读取）→ 移入退役列表，进程退出时释放。
        // （分配失败时宁可不记录也不 free——泄漏优于 use-after-free）
        self.retired_synths.append(self.allocator, inst.synth) catch {};
        _ = self.instruments.orderedRemove(idx);
        var i: usize = 0;
        while (i < self.notes.items.len) {
            const n = &self.notes.items[i];
            if (n.instrument == @as(i32, @intCast(idx))) {
                _ = self.notes.orderedRemove(i); // 该乐器的音符一并删除
                continue;
            }
            if (n.instrument > @as(i32, @intCast(idx))) n.instrument -= 1;
            i += 1;
        }
        if (self.sel.instrument >= @as(i32, @intCast(self.instruments.items.len))) {
            self.sel.instrument = @as(i32, @intCast(self.instruments.items.len)) - 1;
        }
        if (self.synth_win.instrument >= @as(i32, @intCast(self.instruments.items.len))) {
            self.synth_win.instrument = @as(i32, @intCast(self.instruments.items.len)) - 1;
        }
    }

    /// 清除待打开工程的路径（取消流程时）
    pub fn clearPendingOpen(self: *App) void {
        if (self.pending_open_path) |p| self.allocator.free(p);
        self.pending_open_path = null;
    }

    /// 设置待打开工程的路径（复制所有权）
    pub fn setPendingOpen(self: *App, path: []const u8) void {
        self.clearPendingOpen();
        self.pending_open_path = self.allocator.dupe(u8, path) catch null;
    }

    /// 释放全部乐器（名字 + 合成器参数，含退役的）+ 保存相关字段——进程退出时调用
    pub fn deinitAll(self: *App) void {
        if (self.project_path) |p| self.allocator.free(p);
        if (self.toast) |t| self.allocator.free(t);
        if (self.title_applied_name) |n| self.allocator.free(n);
        if (self.pending_open_path) |p| self.allocator.free(p);
        self.project_path = null;
        self.toast = null;
        self.title_applied_name = null;
        self.pending_open_path = null;
        self.deinitInstruments();
    }

    /// 释放全部乐器（名字 + 合成器参数，含退役的）——进程退出时调用
    pub fn deinitInstruments(self: *App) void {
        for (self.instruments.items) |inst| {
            self.allocator.free(inst.name);
            self.allocator.destroy(inst.synth);
        }
        self.instruments.deinit(self.allocator);
        for (self.retired_synths.items) |sp| self.allocator.destroy(sp);
        self.retired_synths.deinit(self.allocator);
    }

    /// 当前选中乐器的合成器参数（无乐器时返回 null）
    pub fn selectedSynth(self: *App) ?*synth.SynthParams {
        if (self.sel.instrument < 0 or self.sel.instrument >= @as(i32, @intCast(self.instruments.items.len))) return null;
        return self.instruments.items[@intCast(self.sel.instrument)].synth;
    }

    /// 标记脏（任何编辑操作调用）
    pub fn markDirty(self: *App) void {
        self.dirty = true;
    }

    /// 设置当前工程路径（**安全**：不依赖 path 与旧值的别名关系）。
    /// 复制到临时缓冲后才释放旧值——即使 path 就是旧 project_path
    /// （普通保存的场景）也不会读已释放内存（实测 use-after-free：
    /// 路径变垃圾 → InvalidUtf8 / BadPathName）。
    pub fn setProjectPath(self: *App, path: []const u8) void {
        var buf: [1024]u8 = undefined;
        const len = @min(path.len, buf.len);
        @memcpy(buf[0..len], path[0..len]); // 先复制出别名区
        if (self.project_path) |old| self.allocator.free(old);
        self.project_path = self.allocator.dupe(u8, buf[0..len]) catch null;
    }

    /// 当前工程名（无路径或异常时 = null）
    pub fn projectName(self: *const App) ?[]const u8 {
        const p = self.project_path orelse return null;
        if (p.len == 0 or std.mem.indexOfScalar(u8, p, 0) != null) return null; // 防御：非法路径
        if (!std.unicode.utf8ValidateSlice(p)) return null; // 防御：非法 UTF-8
        const base = std.fs.path.basename(p);
        if (base.len == 0) return null;
        return base;
    }

    /// 设置状态栏提示（覆盖旧的；默认显示约 3 秒）
    pub fn setToast(self: *App, text: []const u8) void {
        if (self.toast) |old| self.allocator.free(old);
        self.toast = self.allocator.dupe(u8, text) catch null;
        self.toast_frames = 180;
    }

    /// 格式化版提示（如含文件名/错误名）
    pub fn setToastWith(self: *App, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch {
            self.setToast("（提示文本过长）");
            return;
        };
        self.setToast(text);
    }

    /// 取消提示（过期或手动）
    pub fn clearToast(self: *App) void {
        if (self.toast) |old| self.allocator.free(old);
        self.toast = null;
        self.toast_frames = 0;
    }

    /// 每帧递减 toast 计时（main 调用）
    pub fn tickToast(self: *App) void {
        if (self.toast_frames > 0) {
            self.toast_frames -= 1;
            if (self.toast_frames == 0) self.clearToast();
        }
    }

    /// 导出当前工程为存档（不涉及 IO；纯数据转换）
    pub fn exportProject(self: *App) !persist.Project {
        const alloc = self.allocator;
        const clips = try alloc.alloc(persist.SavedClip, self.clips.items.len);
        errdefer alloc.free(clips);
        for (self.clips.items, 0..) |c, i| {
            clips[i] = .{ .track = c.track, .start = c.start, .len = c.len, .pattern = c.pattern, .offset = c.offset };
        }
        const notes = try alloc.alloc(persist.SavedNote, self.notes.items.len);
        errdefer alloc.free(notes);
        for (self.notes.items, 0..) |n, i| {
            notes[i] = .{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument };
        }
        const insts = try alloc.alloc(persist.SavedInstrument, self.instruments.items.len);
        errdefer alloc.free(insts);
        for (self.instruments.items, 0..) |inst, i| {
            const name_copy = try alloc.dupe(u8, inst.name);
            insts[i] = .{
                .name = name_copy,
                .volume = inst.volume,
                .pan = inst.pan,
                .muted = inst.muted,
                .mixer = inst.mixer,
                .synth = persist.exportSynth(inst.synth),
            };
        }
        return .{
            .bpm = self.bpm,
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
            .clips = clips,
            .notes = notes,
            .instruments = insts,
        };
    }

    /// 释放 `exportProject` 返回的存档（含内部字符串）
    pub fn freeProject(self: *App, p: persist.Project) void {
        for (p.instruments) |inst| self.allocator.free(inst.name);
        self.allocator.free(p.clips);
        self.allocator.free(p.notes);
        self.allocator.free(p.instruments);
    }

    /// 用存档替换当前工程内容（先清空旧数据）
    pub fn importProject(self: *App, p: persist.Project) void {
        // 停止播放（避免调度器引用已被清空的数据）
        self.stopPlayback();

        // 清空旧数据
        self.clips.clearRetainingCapacity();
        self.notes.clearRetainingCapacity();
        // 乐器：逐个删除（复用删除逻辑，原子字段/退役列表正确处理）
        while (self.instruments.items.len > 0) {
            self.removeInstrument(self.instruments.items.len - 1);
        }

        // 恢复
        for (p.clips) |c| {
            self.addClip(.{ .track = c.track, .start = c.start, .len = c.len, .pattern = c.pattern, .offset = c.offset });
        }
        for (p.notes) |n| {
            self.addNote(.{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument });
        }
        for (p.instruments) |inst| {
            const idx = self.addInstrument(inst.name);
            if (idx < 0) continue;
            const target = &self.instruments.items[@intCast(idx)];
            target.volume = inst.volume;
            target.pan = inst.pan;
            target.muted = inst.muted;
            target.mixer = inst.mixer;
            persist.importSynth(&inst.synth, target.synth);
        }

        // 全局设置
        self.bpm = p.bpm;
        self.time_num = p.time_num;
        self.time_den = p.time_den;
        self.steps_per_bar = p.steps_per_bar;

        // 选择/clamp 回有效范围
        self.sel.pattern = 0;
        self.sel.track = 0;
        self.sel.instrument = if (self.instruments.items.len > 0) 0 else -1;
        self.playback.song_step = 0;
        self.playback.piano_step = 0;
        self.playback.start_step = 0;
        self.piano.pattern = null;
    }

    /// 停止播放（停声 + 作废调度事件）
    pub fn stopPlayback(self: *App) void {
        self.playing = false;
        self.params.playing.store(false, .monotonic);
        self.scheduler.gen +%= 1;
        self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        self.events.push(.{ .kind = .all_off });
    }

    /// 试听音符（路由到**当前乐器**）
    pub fn auditionOn(self: *App, pitch: i32) void {
        if (self.sel.instrument < 0 or self.sel.instrument >= synth.max_instruments) return;
        self.events.push(.{ .kind = .on, .pitch = @intCast(pitch), .instrument = @intCast(self.sel.instrument) });
    }

    /// 试听释音（路由到**当前乐器**）
    pub fn auditionOff(self: *App, pitch: i32) void {
        if (self.sel.instrument < 0 or self.sel.instrument >= synth.max_instruments) return;
        self.events.push(.{ .kind = .off, .pitch = @intCast(pitch), .instrument = @intCast(self.sel.instrument) });
    }

    /// 跳转播放位置（播放中拖动游标 / 设置起点）：
    /// 重置传输基准（帧+步）+ 作废旧调度事件（为跨起点长音符补发 on）。
    pub fn jumpPlaybackCursor(self: *App, step: i32) void {
        if (self.sel.song_mode) {
            self.playback.song_step = step;
        } else {
            self.playback.piano_step = step;
        }
        self.playback.start_step = step;
        self.playback.start_frame = self.params.frames_played.load(.monotonic);
        self.params.start_frame.store(self.playback.start_frame, .monotonic);
        self.params.start_step.store(step, .monotonic);
        if (self.playing) {
            sequencer.reset(&self.scheduler, &self.sched_events, self.clips.items, self.notes.items, self.sel.song_mode, self.sel.pattern, step);
            self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        }
    }

    /// 关闭钢琴卷帘（返回播放列表）：同时释音——
    /// 防止“按住琴键时关闭视图”导致门控卡住（卡音）
    pub fn closePiano(self: *App) void {
        self.piano.pattern = null;
        self.piano.drag_note = null;
        self.events.push(.{ .kind = .all_off });
        self.piano.held_pitch = null;
    }

    /// 打开钢琴卷帘（编辑指定样式的音符）
    pub fn openPiano(self: *App, pattern: i32) void {
        self.piano.pattern = pattern;
        self.playlist.drag_clip = null;
        self.playlist.resize_clip = null;
        self.playlist.erase_drag = false;
        self.piano.drag_note = null;
        self.piano.scroll = (127 - 84) * self.piano.key_h; // 视野顶部从 C6 开始（下方可见 C3-C6）
        self.piano.scroll_x = 0;
        self.piano.content_w = 0; // 重置为一屏（由滚动条控件规范化）
    }
};

/// 名字是否与基础名相同（忽略 " #N" 后缀）
fn baseNameEquals(name: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, name, base)) return true;
    if (name.len <= base.len + 2) return false;
    if (!std.mem.startsWith(u8, name, base)) return false;
    // " #N"
    return name[base.len] == ' ' and name[base.len + 1] == '#';
}

test "baseNameEquals: 识别基础名与 #N 后缀" {
    try std.testing.expect(baseNameEquals("减法合成器", "减法合成器"));
    try std.testing.expect(baseNameEquals("减法合成器 #2", "减法合成器"));
    try std.testing.expect(baseNameEquals("减法合成器 #10", "减法合成器"));
    try std.testing.expect(!baseNameEquals("采样器", "减法合成器"));
    try std.testing.expect(!baseNameEquals("减法合成器X", "减法合成器"));
}

// ── 保存路径安全（回归：use-after-free）──

test "app: setProjectPath 在 path 别名旧值时安全（修 InvalidUtf8/BadPathName）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.deinitAll();

    // 首次设置
    app.setProjectPath("C:\\proj\\first.saw");
    try std.testing.expectEqualStrings("C:\\proj\\first.saw", app.project_path.?);
    try std.testing.expectEqualStrings("first.saw", app.projectName().?);

    // **关键场景**：path 就是当前 project_path 的切片（普通保存的路径：
    // saveProject 里 path 指向 project_path 自身）。
    // 旧实现「先 free 再 dupe」会读已释放内存 → 路径变垃圾。
    const aliased: []const u8 = app.project_path.?;
    app.setProjectPath(aliased);
    try std.testing.expectEqualStrings("C:\\proj\\first.saw", app.project_path.?);
    try std.testing.expectEqualStrings("first.saw", app.projectName().?);

    // 另存为到新路径 → 工程名跟随（且不残留旧路径）
    app.setProjectPath("D:\\other\\song2.saw");
    try std.testing.expectEqualStrings("D:\\other\\song2.saw", app.project_path.?);
    try std.testing.expectEqualStrings("song2.saw", app.projectName().?);

    // 无路径 → 工程名为 null
    std.testing.allocator.free(app.project_path.?);
    app.project_path = null;
    try std.testing.expect(app.projectName() == null);
}

test "app: projectName 对非法路径的防御（不崩溃）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.deinitAll();

    // 非法 UTF-8 → null（而不是崩溃/乱码）
    app.project_path = try std.testing.allocator.dupe(u8, &.{ 0xFF, 0xFE, 0x41 });
    try std.testing.expect(app.projectName() == null);

    // 空路径 → null
    std.testing.allocator.free(app.project_path.?);
    app.project_path = try std.testing.allocator.dupe(u8, "");
    try std.testing.expect(app.projectName() == null);
}
