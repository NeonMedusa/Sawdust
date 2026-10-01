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
const midi = @import("midi.zig");

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
pub const FileAction = enum { open, save, save_as, import_midi, export_midi };

/// 编辑操作（框选/批量操作快捷键 → 由**当前视图**在帧内按上下文执行）
pub const EditOp = enum { delete_selected, clone_right, copy, paste, select_all };

/// 剪贴板音符（step 存为**相对**最左音符的偏移；粘贴时加到锚点）
pub const ClipboardNote = struct { step: i32, len: i32, pitch: i32 };

/// 批量拉伸快照项（拖选中音符期间；按音符数组顺序对应）
/// 批量操作快照项（拖选中音符/片段期间；按数组顺序对应）
/// - 音符：`step`=起点、`len`=长度、`pitch`=音高；
/// - 片段：`step`=start、`len`=len、`pitch`=track、`offset`=左缘局部步（左缘拉伸用）。
pub const BatchSnap = struct { step: i32, len: i32, pitch: i32, offset: i32 = 0 };

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
    /// SONG（播放全曲）还是 PAT（播放当前样式）——默认 PAT（启动/打开工程时；
    /// 点播放列表标尺会自动切回 SONG）
    song_mode: bool = false,
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
    snap: i32 = 3, // 默认 1/8（`snap_denoms` 下标 3）
    /// 吸附网格下拉选单：展开中
    snap_menu_open: bool = false,

    /// 片段拖动状态（下标 + 抓取点在小节内的偏移）
    drag_clip: ?usize = null,
    drag_grab: i32 = 0,
    /// 片段拉伸状态（下标）
    resize_clip: ?usize = null,
    /// 拉伸的是左缘（true，折叠/展开）还是右缘（false，改长度）
    resize_left: bool = false,
    /// 拉伸基准（按下时快照）：原起点 / 原长（**全局步**）——
    /// 增量式拉伸以它为锚（长度 = 原长 + k×格；`model.trimLenByGrid`）
    resize_orig_start: i32 = 0,
    resize_orig_len: i32 = 0,
    /// 按下时的鼠标内容步——拉伸位移（delta）的基准
    resize_down_step: i32 = 0,
    /// 拖动死区（像素）：按下后位移超过 3px 才真正编辑——
    /// 否则**单击片段**会在按下当帧被吸附（实测 bug：位置/长度跳变）
    drag_armed: bool = false,
    drag_down_x: i32 = 0,
    drag_down_y: i32 = 0,
    /// 右键擦除拖动中（按住右键划过片段即删）
    erase_drag: bool = false,

    // ── 框选 / 批量操作（片段）──
    /// 框选拖动中（Ctrl+左键拖）
    marquee_active: bool = false,
    /// 框选起点（屏幕坐标）
    marquee_x0: i32 = 0,
    marquee_y0: i32 = 0,
    /// 框选追加（Ctrl+Shift）：按下时不取消旧选区
    marquee_add: bool = false,
    /// 批量拖动选中片段（拖动中）
    drag_batch: bool = false,
    /// 批量拖动按下时的鼠标步 / 轨道（快照基准）
    batch_down_step: i32 = 0,
    batch_down_track: i32 = 0,
    /// 批量拉伸中（拖选中片段的边缘；全组同步，与音符一致）
    batch_trim: bool = false,
    /// 批量拉伸的基准：按下时的鼠标步 + 网格格宽（步）
    batch_trim_down_step: i32 = 0,
    batch_trim_grid: i32 = 1,
    /// **按行框选**（Ctrl+左键起点在轨道名列）：垂直拖选轨道行；水平不限（整条时间轴）
    row_marquee: bool = false,
    /// 行框选起始轨道（按下时）
    row_marquee_track0: i32 = 0,
};

/// 钢琴卷帘视图状态
pub const PianoState = struct {
    /// 当前编辑的样式序号（null = 在播放列表视图）
    pattern: ?i32 = null,
    /// 音高行高（像素；□ 缺口缩放）——默认 16：视口内行数较少、内容更大
    key_h: i32 = 16,
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
    /// 拉伸基准（按下时快照）：原起点 / 原长（步）——
    /// 增量式拉伸的锚（长度 = 原长 + k×格；见 `model.trimLenByGrid`）
    drag_orig_step: i32 = 0,
    drag_orig_len: i32 = 0,
    /// 按下时的鼠标内容步——拉伸位移（delta）的基准
    drag_down_step: i32 = 0,
    /// 上一个被点击/编辑过的音符长度（步；新音符放置时沿用；0 = 无参考）
    last_note_len: i32 = 0,

    /// 量化/吸附网格档位（`model.snap_denoms` 下标；控制音符移动/拉伸对齐）
    snap: i32 = 3, // 默认 1/8（`snap_denoms` 下标 3）
    /// 吸附网格下拉选单：展开中
    snap_menu_open: bool = false,
    /// 乐器选择下拉选单：展开中（标题栏、网格选单右侧；与机架窗口的选单独立）
    inst_menu_open: bool = false,

    /// 拖动死区（像素）：按下后位移超过 3px 才真正编辑——
    /// 否则**单击音符**会在按下当帧被吸附（实测 bug：位置/长度跳变）
    drag_armed: bool = false,
    drag_down_x: i32 = 0,
    drag_down_y: i32 = 0,

    // ── 框选 / 批量操作 ──
    /// 框选拖动中（Ctrl+左键拖）
    marquee_active: bool = false,
    /// 框选起点（屏幕坐标）
    marquee_x0: i32 = 0,
    marquee_y0: i32 = 0,
    /// 框选追加（Ctrl+Shift）：按下时不取消旧选区
    marquee_add: bool = false,
    /// 批量拖动选中音符（拖动中；`drag_note` 为 null 时看这个）
    drag_batch: bool = false,
    /// 批量拖动按下时的鼠标内容步 / 音高（快照基准）
    batch_down_step: i32 = 0,
    batch_down_pitch: i32 = 0,
    /// 批量拉伸中（拖选中音符的边缘；左右同单音符规则）
    batch_trim: bool = false,
    /// 批量拉伸的基准：按下时的鼠标步 + 网格格宽（步）
    batch_trim_down_step: i32 = 0,
    batch_trim_grid: i32 = 1,
    /// **按行框选**（Ctrl+左键起点在琴键列）：垂直拖选音高行；水平不限（整条时间轴）
    row_marquee: bool = false,
    /// 行框选起始音高（按下时）
    row_marquee_pitch0: i32 = 0,

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
    /// 添加乐器的下拉菜单：展开中
    add_menu_open: bool = false,
    /// 右键菜单中的乐器（删除用；null = 未展开）
    ctx_instrument: ?usize = null,
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
    /// 标尺拖动的上次目标步（去重；负数 = 无——步非负）——
    /// 见 `App.jumpPlaybackCursorDrag`
    ruler_drag_step: i32 = -1,

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

    // ── 选区与批量操作（框选/剪贴板；瞬态，不存档）──
    /// 待执行的编辑操作（键盘快捷键只登记；由当前视图按上下文执行并清除）
    pending_edit_op: ?EditOp = null,
    /// 音符剪贴板（step 为相对最左音符的偏移）
    clipboard_notes: std.ArrayListUnmanaged(ClipboardNote) = .{ .items = &.{}, .capacity = 0 },
    /// 片段剪贴板（绝对坐标；粘贴时整体平移）
    clipboard_clips: std.ArrayListUnmanaged(Clip) = .{ .items = &.{}, .capacity = 0 },
    /// 批量拉伸快照（拖选中音符边缘期间；顺序 = 音符数组顺序）
    batch_snap: std.ArrayListUnmanaged(BatchSnap) = .{ .items = &.{}, .capacity = 0 },

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
    /// 样式列表（**动态**；名字由 App 管理生命周期，如 "样式 7"）。
    /// 数量 = `pattern_items.items.len`；上限 `max_patterns`（播放列表预览数组等按此设限）。
    pattern_items: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 },
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

    // ── 选区 / 批量操作（框选、批量删除/克隆/复制/粘贴）──

    /// 选中音符数
    pub fn selectedNoteCount(self: *const App) usize {
        var n: usize = 0;
        for (self.notes.items) |nt| {
            if (nt.selected) n += 1;
        }
        return n;
    }

    /// 清空音符选区（不碰片段选区）
    pub fn clearNoteSelection(self: *App) void {
        for (self.notes.items) |*nt| nt.selected = false;
    }

    /// 全选当前样式的全部音符（Ctrl+A；钢琴卷帘上下文）。返回选中数。
    pub fn selectAllNotes(self: *App, pattern: i32) usize {
        var n: usize = 0;
        for (self.notes.items) |*nt| {
            if (nt.pattern != pattern) continue;
            nt.selected = true;
            n += 1;
        }
        return n;
    }

    /// 全选全部片段（Ctrl+A；播放列表上下文）。返回选中数。
    pub fn selectAllClips(self: *App) usize {
        for (self.clips.items) |*c| c.selected = true;
        return self.clips.items.len;
    }

    /// 选中片段数
    pub fn selectedClipCount(self: *const App) usize {
        var n: usize = 0;
        for (self.clips.items) |c| {
            if (c.selected) n += 1;
        }
        return n;
    }

    /// 清空片段选区
    pub fn clearClipSelection(self: *App) void {
        for (self.clips.items) |*c| c.selected = false;
    }

    /// 删除全部选中片段（返回删除数）
    pub fn deleteSelectedClips(self: *App) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.clips.items.len) {
            if (self.clips.items[i].selected) {
                _ = self.clips.swapRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (removed > 0) self.dirty = true;
        return removed;
    }

    /// 批量移动选中片段：`d_step`/`d_track` = 相对**按下时快照**的位移（幂等）。
    /// 注：与单个片段拖动不同，**不拦重叠**（批量移动时允许交叠——与音符一致）。
    /// **钳制作用于整个选区**（同 `moveSelectedNotes`）：先算组内最小 step / 最小轨道
    /// → 全组统一下限，保持相对间距（撞墙时全组停，而非逐个压扁）。
    pub fn moveSelectedClips(self: *App, d_step: i32, d_track: i32, track_count: i32) bool {
        if (self.batch_snap.items.len == 0) return false;
        // 组级钳制（step >= 0、track ∈ [0, track_count-1]）
        var min_step: i32 = std.math.maxInt(i32);
        var min_track: i32 = std.math.maxInt(i32);
        var max_track: i32 = std.math.minInt(i32);
        for (self.batch_snap.items) |snap| {
            min_step = @min(min_step, snap.step);
            min_track = @min(min_track, snap.pitch);
            max_track = @max(max_track, snap.pitch);
        }
        const d_step_c = @max(d_step, -min_step);
        const d_track_c = std.math.clamp(d_track, -min_track, @max(0, track_count - 1) - max_track);
        var changed = false;
        var si: usize = 0;
        for (self.clips.items) |*c| {
            if (!c.selected) continue;
            if (si >= self.batch_snap.items.len) break;
            const snap = self.batch_snap.items[si];
            si += 1;
            const ns = snap.step + d_step_c;
            const ntr = snap.pitch + d_track_c;
            if (ns != c.start or ntr != c.track) {
                c.start = ns;
                c.track = ntr;
                changed = true;
            }
        }
        if (changed) self.dirty = true;
        return changed;
    }

    /// 开始片段批量操作快照（顺序 = 数组顺序；含 `offset`——左缘拉伸需要）
    pub fn beginClipBatchSnap(self: *App) void {
        self.batch_snap.clearRetainingCapacity();
        for (self.clips.items) |c| {
            if (!c.selected) continue;
            self.batch_snap.append(self.allocator, .{ .step = c.start, .len = c.len, .pitch = c.track, .offset = c.offset }) catch {};
        }
    }

    /// 批量拉伸（片段；增量式，单位 = **网格格数** `k`；以快照为锚，幂等）：
    /// - `k > 0`：加长 k 格（右缘不限；左缘受“不能展开到局部第 1 步之前”
    ///   （offset >= 0）与“不能越过时间轴起点”（start >= 0）限制）；
    /// - `k < 0`：缩短 |k| 格，受**全组同步**约束——全组最多能缩
    ///   `min over 片段 batchShortenMax(len, grid)` 格
    ///   （任一片段 ≤ 一格 → 全组不能缩）；
    /// - `k = 0`：**还原到快照状态**（往回拖经过 0 时必须写回）。
    /// `left_edge`：拖左缘（右端固定；改 start/len/offset）还是右缘（起点固定；改 len）。
    /// 不考虑重叠（与批量移动/音符批量一致）。返回实际应用的格数。
    pub fn applyClipBatchTrim(self: *App, k: i32, grid: i32, left_edge: bool) i32 {
        if (self.batch_snap.items.len == 0) return 0;
        const g = @max(1, grid);
        var applied = k;
        if (k < 0) {
            // 缩短：全组取最小（有一个不够就整体不能缩）
            var cap: i32 = std.math.maxInt(i32);
            for (self.batch_snap.items) |snap| {
                cap = @min(cap, model.batchShortenMax(snap.len, g));
            }
            if (cap < 0) cap = 0;
            applied = @max(k, -cap);
        } else if (k > 0 and left_edge) {
            // 左缘加长：不能展开到局部第 1 步之前（offset >= 0）、
            // 也不能越过时间轴起点（start >= 0）——两个约束取最小
            var cap: i32 = std.math.maxInt(i32);
            for (self.batch_snap.items) |snap| {
                cap = @min(cap, @min(@divFloor(snap.step, g), @divFloor(snap.offset, g)));
            }
            if (cap < 0) cap = 0;
            applied = @min(k, cap);
        }
        // **总是写回**（即使 applied == 0）：k 从非零变回 0 时要还原到快照状态
        var si: usize = 0;
        var changed = false;
        for (self.clips.items) |*c| {
            if (!c.selected) continue;
            if (si >= self.batch_snap.items.len) break;
            const snap = self.batch_snap.items[si];
            si += 1;
            const new_len = @max(1, snap.len + applied * g);
            if (left_edge) {
                const right = snap.step + snap.len; // 右端固定
                const ns = @max(0, right - new_len);
                const nl = right - ns;
                // offset 同步平移（clipTrimLeft 的规则：offset += delta）
                const no = snap.offset + (ns - snap.step);
                if (ns != c.start or nl != c.len or no != c.offset) {
                    c.start = ns;
                    c.len = nl;
                    c.offset = no;
                    changed = true;
                }
            } else {
                if (new_len != c.len) {
                    c.len = new_len;
                    changed = true;
                }
            }
        }
        if (changed) self.dirty = true;
        return applied;
    }

    /// 快速克隆（Ctrl+B，片段）：把选中片段整体右移**选区跨度**（= 最右缘 − 最左缘）
    /// 并复制一份；复制后**选区转移到克隆体**（连按 = 铺瓷砖）。
    /// 不考虑重叠（允许交叠）。返回克隆数（0 = 无选区）。
    pub fn cloneSelectedClipsRight(self: *App) usize {
        var min_start: i32 = std.math.maxInt(i32);
        var max_end: i32 = 0;
        for (self.clips.items) |c| {
            if (!c.selected) continue;
            min_start = @min(min_start, c.start);
            max_end = @max(max_end, c.start + c.len);
        }
        if (min_start == std.math.maxInt(i32)) return 0;
        const span = @max(1, max_end - min_start);

        // 先收集到临时表（append 可能 realloc——不能边迭代原数组边 append）
        var to_clone: std.ArrayListUnmanaged(Clip) = .{ .items = &.{}, .capacity = 0 };
        defer to_clone.deinit(self.allocator);
        for (self.clips.items) |c| {
            if (!c.selected) continue;
            to_clone.append(self.allocator, c) catch {};
        }
        self.clearClipSelection();
        for (to_clone.items) |c| {
            var copy = c;
            copy.start = c.start + span;
            copy.selected = true;
            self.clips.append(self.allocator, copy) catch {};
        }
        const cloned = to_clone.items.len;
        if (cloned > 0) self.dirty = true;
        return cloned;
    }

    /// 删除全部选中音符（返回删除数）
    pub fn deleteSelectedNotes(self: *App) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.notes.items.len) {
            if (self.notes.items[i].selected) {
                _ = self.notes.swapRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (removed > 0) self.dirty = true;
        return removed;
    }

    /// 复制选中音符到剪贴板（step 归一为相对最左音符的偏移；返回复制数）
    pub fn copySelectedNotes(self: *App) usize {
        self.clipboard_notes.clearRetainingCapacity();
        var min_step: i32 = std.math.maxInt(i32);
        for (self.notes.items) |nt| {
            if (nt.selected) min_step = @min(min_step, nt.step);
        }
        if (min_step == std.math.maxInt(i32)) return 0;
        for (self.notes.items) |nt| {
            if (!nt.selected) continue;
            self.clipboard_notes.append(self.allocator, .{
                .step = nt.step - min_step,
                .len = nt.len,
                .pitch = nt.pitch,
            }) catch {};
        }
        return self.clipboard_notes.items.len;
    }

    /// 快速克隆（Ctrl+B）：把选中音符整体右移**选区跨度**（= 最右缘 − 最左缘）
    /// 并复制一份；复制后**选区转移到克隆体**（连按 = 铺瓷砖）。
    /// 不考虑重叠（允许重叠）。返回克隆数（0 = 无选区）。
    pub fn cloneSelectedNotesRight(self: *App) usize {
        var min_step: i32 = std.math.maxInt(i32);
        var max_end: i32 = 0;
        for (self.notes.items) |nt| {
            if (!nt.selected) continue;
            min_step = @min(min_step, nt.step);
            max_end = @max(max_end, nt.step + nt.len);
        }
        if (min_step == std.math.maxInt(i32)) return 0;
        const span = @max(1, max_end - min_step);

        // 先把待克隆的音符收集到临时表（数组 append 可能 realloc——
        // 直接迭代原数组再 append 会悬空），再清空选区、追加克隆体。
        var to_clone: std.ArrayListUnmanaged(model.Note) = .{ .items = &.{}, .capacity = 0 };
        defer to_clone.deinit(self.allocator);
        for (self.notes.items) |nt| {
            if (!nt.selected) continue;
            to_clone.append(self.allocator, nt) catch {};
        }
        self.clearNoteSelection();
        for (to_clone.items) |nt| {
            var copy = nt;
            copy.step = nt.step + span;
            copy.selected = true;
            self.notes.append(self.allocator, copy) catch {};
        }
        const cloned = to_clone.items.len;
        if (cloned > 0) self.dirty = true;
        return cloned;
    }

    /// 粘贴音符（Ctrl+V）：把剪贴板内容粘贴到 `anchor_step`（相对偏移 + 锚点）；
    /// 音高不变；**选区转移到新粘贴的音符**。返回粘贴数。
    pub fn pasteNotes(self: *App, pattern: i32, instrument: i32, anchor_step: i32) usize {
        if (self.clipboard_notes.items.len == 0) return 0;
        self.clearNoteSelection();
        for (self.clipboard_notes.items) |cn| {
            self.notes.append(self.allocator, .{
                .step = @max(0, anchor_step + cn.step),
                .len = cn.len,
                .pitch = cn.pitch,
                .pattern = pattern,
                .instrument = instrument,
                .selected = true,
            }) catch {};
        }
        const n = self.clipboard_notes.items.len;
        if (n > 0) self.dirty = true;
        return n;
    }

    /// 复制选中片段到剪贴板（start 归一为相对最左片段的偏移；track 存原值；
    /// 返回复制数）
    pub fn copySelectedClips(self: *App) usize {
        self.clipboard_clips.clearRetainingCapacity();
        var min_start: i32 = std.math.maxInt(i32);
        for (self.clips.items) |c| {
            if (c.selected) min_start = @min(min_start, c.start);
        }
        if (min_start == std.math.maxInt(i32)) return 0;
        for (self.clips.items) |c| {
            if (!c.selected) continue;
            var copy = c;
            copy.start = c.start - min_start; // 相对偏移（粘贴时加锚点）
            copy.selected = false;
            self.clipboard_clips.append(self.allocator, copy) catch {};
        }
        return self.clipboard_clips.items.len;
    }

    /// 粘贴片段（Ctrl+V）：把剪贴板内容粘贴到 `anchor_start`（相对偏移 + 锚点）；
    /// **轨道不变**（每个片段回原轨道——用户只关心横向落点）；
    /// **选区转移到新粘贴的片段**。返回粘贴数。不考虑重叠（与克隆/批量一致）。
    pub fn pasteClips(self: *App, anchor_start: i32, track_count: i32) usize {
        if (self.clipboard_clips.items.len == 0) return 0;
        self.clearClipSelection();
        for (self.clipboard_clips.items) |c| {
            const tr = std.math.clamp(c.track, 0, @max(0, track_count - 1));
            self.clips.append(self.allocator, .{
                .track = tr,
                .start = @max(0, anchor_start + c.start),
                .len = c.len,
                .pattern = c.pattern,
                .offset = c.offset,
                .selected = true,
            }) catch {};
        }
        const n = self.clipboard_clips.items.len;
        if (n > 0) self.dirty = true;
        return n;
    }

    /// 批量移动选中音符（钢琴卷帘拖动）：`d_step`/`d_pitch` = 相对**按下时快照**的位移。
    /// 每帧从快照重算（幂等、可逆——不会因钳制而漂移）。
    ///
    /// **钳制必须作用于整个选区**（而非逐音符）：逐音符 `@max(0, step+d)` 会在
    /// 撞左墙时把左边的音符一个个压到 step 0（实测 bug：斜排四音符被“压扁”成
    /// 一列）。正确做法 = 先算组内最小 step → 全组统一的位移下限，
    /// 保持相对间距不变（最左的音符碰到 0 时全组停住）。
    /// 音高同理：`d_pitch` 也按组统一钳制（撞 0/127 时全组停）。
    /// 返回是否变化。
    pub fn moveSelectedNotes(self: *App, d_step: i32, d_pitch: i32) bool {
        if (self.batch_snap.items.len == 0) return false;
        // 组级钳制：算出全组允许的位移范围（保持相对间距）
        var min_step: i32 = std.math.maxInt(i32);
        var min_pitch: i32 = std.math.maxInt(i32);
        var max_pitch: i32 = std.math.minInt(i32);
        for (self.batch_snap.items) |snap| {
            min_step = @min(min_step, snap.step);
            min_pitch = @min(min_pitch, snap.pitch);
            max_pitch = @max(max_pitch, snap.pitch);
        }
        const d_step_c = @max(d_step, -min_step); // 最左碰到 0 → 全组停
        const d_pitch_c = std.math.clamp(d_pitch, -min_pitch, 127 - max_pitch); // 撞上下限 → 全组停
        var changed = false;
        var si: usize = 0;
        for (self.notes.items) |*nt| {
            if (!nt.selected) continue;
            if (si >= self.batch_snap.items.len) break;
            const snap = self.batch_snap.items[si];
            si += 1;
            const ns = snap.step + d_step_c; // 不再逐音符 @max(0, ...)
            const np = snap.pitch + d_pitch_c;
            if (ns != nt.step or np != nt.pitch) {
                nt.step = ns;
                nt.pitch = np;
                changed = true;
            }
        }
        if (changed) self.dirty = true;
        return changed;
    }

    /// 开始批量操作快照（拖选中音符/拉伸前调用；顺序 = 音符数组顺序）
    pub fn beginBatchSnap(self: *App) void {
        self.batch_snap.clearRetainingCapacity();
        for (self.notes.items) |nt| {
            if (!nt.selected) continue;
            self.batch_snap.append(self.allocator, .{ .step = nt.step, .len = nt.len, .pitch = nt.pitch }) catch {};
        }
    }

    /// 批量拉伸（增量式，单位 = **网格格数** `k`；以快照为锚，幂等）：
    /// - `k > 0`：加长 k 格（右缘不限；左缘受“不能越过样式开头”限制）；
    /// - `k < 0`：缩短 |k| 格，受**全组同步**约束——全组最多能缩
    ///   `min over 音符 batchShortenMax(len, grid)` 格
    ///   （任一音符 ≤ 一格 → 全组不能缩）；
    /// - `k = 0`：**还原到快照状态**（往回拖经过 0 时必须写回——否则音符
    ///   卡在上一次非零 k 的长度；实测 bug：拉长后往回拖卡在二分音符）。
    /// `left_edge`：拖左缘（右端固定）还是右缘（起点固定）。
    /// 返回实际应用的格数。
    pub fn applyBatchTrim(self: *App, k: i32, grid: i32, left_edge: bool) i32 {
        if (self.batch_snap.items.len == 0) return 0;
        const g = @max(1, grid);
        var applied = k;
        if (k < 0) {
            // 缩短：全组取最小（有一个不够就整体不能缩）
            var cap: i32 = std.math.maxInt(i32);
            for (self.batch_snap.items) |snap| {
                cap = @min(cap, model.batchShortenMax(snap.len, g));
            }
            if (cap < 0) cap = 0;
            applied = @max(k, -cap);
        } else if (k > 0 and left_edge) {
            // 左缘加长：不能越过样式开头（step >= 0）
            var cap: i32 = std.math.maxInt(i32);
            for (self.batch_snap.items) |snap| {
                cap = @min(cap, @divFloor(snap.step, g));
            }
            if (cap < 0) cap = 0;
            applied = @min(k, cap);
        }
        // **总是写回**（即使 applied == 0）：k 从非零变回 0 时要还原到快照状态——
        // 早退会让音符卡在上一次的非零长度（实测 bug：拉长后往回拖卡在二分音符）。
        var si: usize = 0;
        var changed = false;
        for (self.notes.items) |*nt| {
            if (!nt.selected) continue;
            if (si >= self.batch_snap.items.len) break;
            const snap = self.batch_snap.items[si];
            si += 1;
            const new_len = @max(1, snap.len + applied * g);
            if (left_edge) {
                const right = snap.step + snap.len; // 右端固定
                const ns = @max(0, right - new_len);
                const nl = right - ns;
                if (ns != nt.step or nl != nt.len) {
                    nt.step = ns;
                    nt.len = nl;
                    changed = true;
                }
            } else {
                if (new_len != nt.len) {
                    nt.len = new_len;
                    changed = true;
                }
            }
        }
        if (changed) self.dirty = true;
        return applied;
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
        self.clipboard_notes.deinit(self.allocator);
        self.clipboard_clips.deinit(self.allocator);
        self.batch_snap.deinit(self.allocator);
        self.deinitPatterns();
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

    /// 当前样式数量
    pub fn patternCount(self: *const App) i32 {
        return @intCast(self.pattern_items.items.len);
    }

    /// 添加样式（名字 = “样式 N”；上限 `model.max_patterns`）。
    /// 返回新样式序号（0 起；已达上限返回 -1）。
    pub fn addPattern(self: *App) i32 {
        if (self.pattern_items.items.len >= model.max_patterns) return -1;
        const n = self.pattern_items.items.len + 1;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "样式 {d}", .{n}) catch return -1;
        const name = self.allocator.dupe(u8, text) catch return -1;
        self.pattern_items.append(self.allocator, name) catch {
            self.allocator.free(name);
            return -1;
        };
        self.dirty = true;
        return @intCast(self.pattern_items.items.len - 1);
    }

    /// 清空样式列表并重建为默认数量（新建/加载工程时用；释放旧名字）
    pub fn resetPatterns(self: *App, count: i32) void {
        for (self.pattern_items.items) |name| self.allocator.free(name);
        self.pattern_items.clearRetainingCapacity();
        const n = std.math.clamp(count, 1, model.max_patterns);
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            _ = self.addPattern();
        }
        self.dirty = false; // 重置本身不算编辑（调用方决定脏标记）
    }

    /// 释放样式列表（进程退出时调用）
    pub fn deinitPatterns(self: *App) void {
        for (self.pattern_items.items) |name| self.allocator.free(name);
        self.pattern_items.deinit(self.allocator);
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
                .midi_channel = inst.midi_channel,
                .synth = persist.exportSynth(inst.synth),
            };
        }
        return .{
            .bpm = self.bpm,
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
            .pattern_count = self.patternCount(),
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
            target.midi_channel = inst.midi_channel;
            persist.importSynth(&inst.synth, target.synth);
        }

        // 全局设置
        self.bpm = p.bpm;
        self.time_num = p.time_num;
        self.time_den = p.time_den;
        self.steps_per_bar = p.steps_per_bar;
        // 样式列表：恢复到存档数量（旧存档无此字段 → 默认 6）
        self.resetPatterns(if (p.pattern_count > 0) p.pattern_count else model.default_pattern_count);

        // 选择/clamp 回有效范围
        self.sel.pattern = 0;
        self.sel.track = 0;
        self.sel.instrument = if (self.instruments.items.len > 0) 0 else -1;
        self.playback.song_step = 0;
        self.playback.piano_step = 0;
        self.playback.start_step = 0;
        self.piano.pattern = null;
        // 打开工程后回到 PAT（默认工作模式；点播放列表标尺会自动切 SONG）
        self.sel.song_mode = false;
    }

    // ── MIDI 导入 / 导出（转换逻辑；文件 IO 在 main 接线）──

    /// MIDI 导入结果
    pub const MidiImportResult = struct {
        /// 新样式序号（音符全部放进它）
        pattern: i32,
        /// 导入的音符数
        notes: usize,
        /// 新建的乐器数（= 文件里用到的通道数）
        instruments: usize,
        /// 被跳过的音符数（乐器上限、非法音高等）
        skipped: usize,
    };

    /// 导入 MIDI：每个用到的通道 → 一个新乐器（默认减法合成器参数）；
    /// 音符全部写进**一个新建样式**（不自动放片段——由用户自己放置）。
    /// 失败返回错误；成功返回统计信息。
    pub fn importMidi(self: *App, parsed: *const midi.Parsed) !MidiImportResult {
        // 1) 收集用到的通道（升序稳定）
        var ch_used = [_]bool{false} ** 16;
        for (parsed.notes) |n| ch_used[n.channel & 0x0F] = true;

        // 2) 新建样式（达到上限 → 报错，不做半途导入）
        const new_pat = self.addPattern();
        if (new_pat < 0) return error.TooManyPatterns;

        // 3) 通道 → 乐器（顺序建立，保持通道升序）
        var ch_to_inst = [_]i32{-1} ** 16;
        var inst_count: usize = 0;
        for (ch_used, 0..) |u, ch| {
            if (!u) continue;
            const idx = self.addInstrument("MIDI 通道");
            if (idx < 0) continue; // 乐器已达上限：该通道音符将被跳过
            self.instruments.items[@intCast(idx)].midi_channel = @intCast(ch); // 记住来源通道
            ch_to_inst[ch] = idx;
            inst_count += 1;
        }

        // 4) 音符：tick → 步（每事件独立换算）；时值至少 1 步
        var imported: usize = 0;
        var skipped: usize = 0;
        for (parsed.notes) |pn| {
            const inst = ch_to_inst[pn.channel & 0x0F];
            if (inst < 0) {
                skipped += 1;
                continue;
            }
            if (pn.pitch > 127) {
                skipped += 1;
                continue;
            }
            const start = midi.tickToStep(pn.start_tick, parsed.ticks_per_quarter);
            const end = midi.tickToStep(pn.end_tick, parsed.ticks_per_quarter);
            const len = @max(1, end - start);
            self.addNote(.{
                .step = @max(0, start),
                .len = len,
                .pitch = pn.pitch,
                .pattern = new_pat,
                .instrument = inst,
            });
            imported += 1;
        }

        // 选中新样式（用户一眼能看到）；乐器选中第一个新建的
        self.sel.pattern = new_pat;
        if (self.piano.pattern != null) self.piano.pattern = new_pat;
        if (inst_count > 0) {
            for (ch_to_inst) |idx| {
                if (idx >= 0) {
                    self.sel.instrument = idx;
                    break;
                }
            }
        }

        return .{ .pattern = new_pat, .notes = imported, .instruments = inst_count, .skipped = skipped };
    }

    /// 导出 MIDI：把**全部片段**里的音符按全局时间展开（同音符被多个片段引用
    /// 会导出多次——与播放听到的一致）；乐器号 mod 16 → 通道。
    /// 返回的切片归调用方释放（`allocator.free`）。
    pub fn exportMidiNotes(self: *App, allocator: std.mem.Allocator) ![]midi.ExportNote {
        var out: std.ArrayListUnmanaged(midi.ExportNote) = .{ .items = &.{}, .capacity = 0 };
        errdefer out.deinit(allocator);

        for (self.clips.items) |clip| {
            for (self.notes.items) |n| {
                if (n.pattern != clip.pattern) continue;
                if (n.pitch < 0 or n.pitch > 127 or n.len <= 0) continue;
                if (n.instrument < 0) continue;
                // 通道：优先乐器记录的来源通道（MIDI 导入往返稳定）；否则乐器号 mod 16
                const ch: i32 = blk: {
                    const ii = @as(usize, @intCast(n.instrument));
                    if (ii < self.instruments.items.len) {
                        const mc = self.instruments.items[ii].midi_channel;
                        if (mc >= 0) break :blk @mod(mc, 16);
                    }
                    break :blk @mod(n.instrument, 16);
                };
                // 全局步 = 局部步 + 片段起点 − 片段左缘偏移（与序列器同一公式）
                const gs = clip.start + (n.step - clip.offset);
                const ge = gs + n.len;
                if (ge <= clip.start or gs >= clip.start + clip.len) continue; // 窗口外
                const s = @max(gs, clip.start);
                const e = @min(ge, clip.start + clip.len);
                try out.append(allocator, .{
                    .start_step = s,
                    .len_steps = @max(1, e - s),
                    .pitch = @intCast(n.pitch),
                    .channel = @intCast(ch),
                });
            }
        }
        return out.toOwnedSlice(allocator);
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

    /// 标尺拖动跳转（**去重**）：按住鼠标时 UI 每帧都调用，
    /// 但只有目标步**变化**（或按下那一帧 `force`）才真正跳转。
    ///
    /// 为什么：每帧跳转 = 每帧 `reset`（gen++）→ 音频线程每帧作废 stash +
    /// 全声部释音 + 重新补发“跨位置”音符的 note-on → **每帧一次重触发**
    /// （实测 bug：播放中单击定位，音符“响两下”/连环重触发）；
    /// 且每帧重置传输基准让游标视觉上“回弹”（“游标又往左移了一小格”）。
    pub fn jumpPlaybackCursorDrag(self: *App, step: i32, force: bool) void {
        if (!force and step == self.playback.ruler_drag_step) return;
        self.playback.ruler_drag_step = step;
        self.jumpPlaybackCursor(step);
    }

    /// 关闭钢琴卷帘（返回播放列表）：同时释音——
    /// 防止“按住琴键时关闭视图”导致门控卡住（卡音）
    pub fn closePiano(self: *App) void {
        self.piano.pattern = null;
        self.piano.drag_note = null;
        self.piano.snap_menu_open = false; // 关闭视图时收起标题栏选单
        self.piano.inst_menu_open = false;
        self.events.push(.{ .kind = .all_off });
        self.piano.held_pitch = null;
    }

    /// 打开钢琴卷帘（编辑指定样式的音符）
    pub fn openPiano(self: *App, pattern: i32) void {
        self.piano.pattern = pattern;
        self.piano.snap_menu_open = false; // 打开时收起上次残留的选单
        self.piano.inst_menu_open = false;
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

// ── 选区 / 批量操作（框选、批量删除/克隆/复制/粘贴/拉伸）──

test "app: 批量操作——删除/复制/粘贴/克隆（选区转移、相对偏移、铺瓷砖）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 三个音符：两个选中（0..24、24..48），一个未选（96..120）
    app.notes.append(app.allocator, .{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 24, .len = 24, .pitch = 62, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 96, .len = 24, .pitch = 64, .pattern = 0 }) catch {};

    // 复制：相对偏移 = step - 最左（0/24）
    try std.testing.expectEqual(@as(usize, 2), app.copySelectedNotes());
    try std.testing.expectEqual(@as(i32, 0), app.clipboard_notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 24), app.clipboard_notes.items[1].step);

    // 克隆（Ctrl+B）：选区跨度 = 48 - 0 = 48 → 克隆体 48..72、72..96；选区转移到克隆体
    try std.testing.expectEqual(@as(usize, 2), app.cloneSelectedNotesRight());
    try std.testing.expectEqual(@as(usize, 5), app.notes.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.selectedNoteCount());
    // 原选区已取消
    try std.testing.expect(!app.notes.items[0].selected);
    try std.testing.expect(!app.notes.items[1].selected);
    // 克隆体成为新选区（48..72、72..96）
    var found_clone_a = false;
    var found_clone_b = false;
    for (app.notes.items) |n| {
        if (n.selected and n.step == 48 and n.pitch == 60) found_clone_a = true;
        if (n.selected and n.step == 72 and n.pitch == 62) found_clone_b = true;
    }
    try std.testing.expect(found_clone_a and found_clone_b);

    // **铺瓷砖**：再按一次 → 跨度还是 48（48..96）→ 克隆体 96..144、120..168
    try std.testing.expectEqual(@as(usize, 2), app.cloneSelectedNotesRight());
    try std.testing.expectEqual(@as(usize, 7), app.notes.items.len);
    var found_tile = false;
    for (app.notes.items) |n| {
        if (n.selected and n.step == 96 and n.pitch == 60) found_tile = true;
    }
    try std.testing.expect(found_tile);

    // 粘贴：锚点 240 → 相对偏移加上去（240、264）；音高不变；选区转移到粘贴体
    try std.testing.expectEqual(@as(usize, 2), app.pasteNotes(0, 0, 240));
    try std.testing.expectEqual(@as(usize, 9), app.notes.items.len);
    var pasted_a = false;
    var pasted_b = false;
    for (app.notes.items) |n| {
        if (n.selected and n.step == 240 and n.pitch == 60) pasted_a = true;
        if (n.selected and n.step == 264 and n.pitch == 62) pasted_b = true;
    }
    try std.testing.expect(pasted_a and pasted_b);
    try std.testing.expectEqual(@as(usize, 2), app.selectedNoteCount());

    // 删除选中（粘贴体）→ 剩 7 个
    try std.testing.expectEqual(@as(usize, 2), app.deleteSelectedNotes());
    try std.testing.expectEqual(@as(usize, 7), app.notes.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.selectedNoteCount());
}

test "app: 批量拉伸——全组同步缩短（任一 ≤ 一格则全组不能缩）、加长不限" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 两个四分音符（24 步）+ 1/8 网格（12 步）
    app.notes.append(app.allocator, .{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 48, .len = 24, .pitch = 62, .pattern = 0, .selected = true }) catch {};
    app.beginBatchSnap();

    // 缩 1 格（-1）：24 → 12 ✓
    try std.testing.expectEqual(@as(i32, -1), app.applyBatchTrim(-1, 12, false));
    try std.testing.expectEqual(@as(i32, 12), app.notes.items[0].len);
    try std.testing.expectEqual(@as(i32, 12), app.notes.items[1].len);
    // 继续往左拖（-2）：快照 24 最多缩 1 格（floor(23/12)）→ clamp 到 -1（仍 12，幂等）
    try std.testing.expectEqual(@as(i32, -1), app.applyBatchTrim(-2, 12, false));
    try std.testing.expectEqual(@as(i32, 12), app.notes.items[0].len);

    // 加长（+2）：24 + 24 = 48（从**快照 24** 起算；幂等）
    try std.testing.expectEqual(@as(i32, 2), app.applyBatchTrim(2, 12, false));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[0].len);
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[1].len);
    // 再应用同一值（+2）→ 仍是 48（幂等：从快照重算）
    try std.testing.expectEqual(@as(i32, 2), app.applyBatchTrim(2, 12, false));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[0].len);

    // 左缘拉伸（加长）：重建快照（当前长 48）——第 1 个音符快照 step = 0
    // → 全组 cap = floor(0/12) = 0（左缘加长不能把**任何**音符推到负起点）
    // → applied = 0 → **写回快照状态**（新语义：状态永远 = 快照 + applied×格）
    app.beginBatchSnap();
    try std.testing.expectEqual(@as(i32, 0), app.applyBatchTrim(1, 12, true));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[1].len); // 保持快照值

    // 把第 1 个音符往右挪（快照 step = 24）后，左缘可加 2 格（cap = floor(24/12) = 2）
    app.notes.items[0].step = 24;
    app.notes.items[1].step = 60;
    app.beginBatchSnap();
    try std.testing.expectEqual(@as(i32, 2), app.applyBatchTrim(2, 12, true));
    // 第 1 个：右端 = 24+48 = 72 → 新 len = 48+24 = 72 → 新 step = 0
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[0].len);
    // 第 2 个：右端 = 60+48 = 108 → 新 len = 72 → 新 step = 36
    try std.testing.expectEqual(@as(i32, 36), app.notes.items[1].step);
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[1].len);
    try std.testing.expectEqual(@as(i32, 108), app.notes.items[1].step + app.notes.items[1].len);

    // 组内有一个短的 → 全组不能缩
    app.clearNoteSelection();
    app.notes.items[0].selected = true;
    app.notes.items[1].selected = true;
    app.notes.items[1].len = 12; // 一个 = 一格
    app.beginBatchSnap();
    try std.testing.expectEqual(@as(i32, 0), app.applyBatchTrim(-1, 12, false));
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[0].len); // 未被缩短
}

test "app: 批量拉伸——往回拖经过 0 格必须还原（修“卡在二分音符”）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 1/4 网格（24 步）、两个四分音符（24 步）——实测场景
    app.notes.append(app.allocator, .{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 48, .len = 24, .pitch = 62, .pattern = 0, .selected = true }) catch {};
    app.beginBatchSnap();

    // 拉长 1 格 → 48（二分音符）
    try std.testing.expectEqual(@as(i32, 1), app.applyBatchTrim(1, 24, false));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[0].len);

    // **关键回归**：往回拖经过 0 格 → 必须还原为 24
    // （旧实现在 applied == 0 时早退 → 卡在 48，再也缩不回）
    try std.testing.expectEqual(@as(i32, 0), app.applyBatchTrim(0, 24, false));
    try std.testing.expectEqual(@as(i32, 24), app.notes.items[0].len);
    try std.testing.expectEqual(@as(i32, 24), app.notes.items[1].len);

    // 单调不跳变：+2 → 72；回 1 格 → 48；回 0 格 → 24（旧实现会从 72 直接跳）
    try std.testing.expectEqual(@as(i32, 2), app.applyBatchTrim(2, 24, false));
    try std.testing.expectEqual(@as(i32, 72), app.notes.items[0].len);
    try std.testing.expectEqual(@as(i32, 1), app.applyBatchTrim(1, 24, false));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[0].len);
    try std.testing.expectEqual(@as(i32, 0), app.applyBatchTrim(0, 24, false));
    try std.testing.expectEqual(@as(i32, 24), app.notes.items[0].len);

    // 继续往左（-1）：1/4 网格下 24 = 一格 → 全组不能缩（保持 24）
    try std.testing.expectEqual(@as(i32, 0), app.applyBatchTrim(-1, 24, false));
    try std.testing.expectEqual(@as(i32, 24), app.notes.items[0].len);
}

test "app: 全选——音符（仅当前样式）/ 片段" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 音符：样式 0 两个、样式 1 一个
    app.notes.append(app.allocator, .{ .step = 0, .len = 12, .pitch = 60, .pattern = 0 }) catch {};
    app.notes.append(app.allocator, .{ .step = 24, .len = 12, .pitch = 62, .pattern = 0 }) catch {};
    app.notes.append(app.allocator, .{ .step = 48, .len = 12, .pitch = 64, .pattern = 1 }) catch {};

    // Ctrl+A（钢琴卷帘上下文）：只选当前样式（0）的全部音符
    try std.testing.expectEqual(@as(usize, 2), app.selectAllNotes(0));
    try std.testing.expectEqual(@as(usize, 2), app.selectedNoteCount());
    try std.testing.expect(app.notes.items[0].selected);
    try std.testing.expect(app.notes.items[1].selected);
    try std.testing.expect(!app.notes.items[2].selected); // 样式 1 不受影响

    // 切样式全选：样式 1 一个
    app.clearNoteSelection();
    try std.testing.expectEqual(@as(usize, 1), app.selectAllNotes(1));
    try std.testing.expect(app.notes.items[2].selected);

    // 片段全选
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0 }) catch {};
    app.clips.append(app.allocator, .{ .track = 1, .start = 96, .len = 96, .pattern = 1 }) catch {};
    try std.testing.expectEqual(@as(usize, 2), app.selectAllClips());
    try std.testing.expectEqual(@as(usize, 2), app.selectedClipCount());
}

test "app: 批量移动——组级钳制（斜排撞左墙不压扁，保持相对间距）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 实测场景：xxx1 / xx2x / x3xx / 4xxx（step 3/2/1/0，音高 60/61/62/63）
    app.notes.append(app.allocator, .{ .step = 3, .len = 1, .pitch = 60, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 2, .len = 1, .pitch = 61, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 1, .len = 1, .pitch = 62, .pattern = 0, .selected = true }) catch {};
    app.notes.append(app.allocator, .{ .step = 0, .len = 1, .pitch = 63, .pattern = 0, .selected = true }) catch {};
    app.beginBatchSnap();

    // 大幅左拖（-10）：最左的（step 0）碰到 0 → **全组停**，不压扁
    // （旧实现：逐音符 @max(0, step+d) → 四个全挤到 step 0）
    try std.testing.expect(!app.moveSelectedNotes(-10, 0)); // 无变化（组级下限 = 0）
    try std.testing.expectEqual(@as(i32, 3), app.notes.items[0].step); // 保持相对间距
    try std.testing.expectEqual(@as(i32, 2), app.notes.items[1].step);
    try std.testing.expectEqual(@as(i32, 1), app.notes.items[2].step);
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[3].step);

    // 部分左移场景：组内最小 step = 2 → 可整体左移最多 2（保持间距）
    app.clearNoteSelection();
    for (app.notes.items, 0..) |*nt, i| {
        nt.selected = true;
        nt.step = @as(i32, @intCast(5 - i)); // 5/4/3/2
    }
    app.beginBatchSnap();
    try std.testing.expect(app.moveSelectedNotes(-10, 0)); // 钳到 -2
    try std.testing.expectEqual(@as(i32, 3), app.notes.items[0].step); // 5-2
    try std.testing.expectEqual(@as(i32, 2), app.notes.items[1].step);
    try std.testing.expectEqual(@as(i32, 1), app.notes.items[2].step);
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[3].step); // 2-2
    // 再左拖 → 全组停（最左已到 0）
    try std.testing.expect(!app.moveSelectedNotes(-11, 0));
    // 回拖到 -1：从快照重算（幂等）
    try std.testing.expect(app.moveSelectedNotes(-1, 0));
    try std.testing.expectEqual(@as(i32, 4), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 1), app.notes.items[3].step);

    // 音高组级钳制：往上撞 127 → 全组停（保持间距 126/127 不变）
    app.clearNoteSelection();
    app.notes.items[0].selected = true;
    app.notes.items[0].pitch = 126;
    app.notes.items[1].selected = true;
    app.notes.items[1].pitch = 127;
    app.beginBatchSnap();
    try std.testing.expect(!app.moveSelectedNotes(0, 5)); // 组级上限 = 127-127 = 0 → 无变化
    try std.testing.expectEqual(@as(i32, 126), app.notes.items[0].pitch); // 保持间距
    try std.testing.expectEqual(@as(i32, 127), app.notes.items[1].pitch);

    // 片段组级钳制：轨道 0/1/2 整体下移 -10 → 全组停（最上已在轨道 0）
    app.clearNoteSelection();
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 1, .start = 96, .len = 96, .pattern = 1, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 2, .start = 192, .len = 96, .pattern = 2, .selected = true }) catch {};
    app.beginClipBatchSnap();
    try std.testing.expect(!app.moveSelectedClips(0, -10, 8)); // 无变化（组级下限 = 0）
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[0].track);
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[1].track); // 保持间距
    try std.testing.expectEqual(@as(i32, 2), app.clips.items[2].track);
    // 从轨道 1 起的三片段可整体上移 1（保持间距）
    app.clearClipSelection();
    app.clips.items[0].selected = true;
    app.clips.items[0].track = 1;
    app.clips.items[1].selected = true;
    app.clips.items[2].selected = true;
    app.beginClipBatchSnap();
    try std.testing.expect(app.moveSelectedClips(0, -1, 8));
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[0].track);
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[1].track);
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[2].track);
}

test "app: 片段剪贴板——复制（相对偏移）+ 粘贴（鼠标位置：步/轨道）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 三个片段：两个选中（轨 1/2、步 96/192）
    app.clips.append(app.allocator, .{ .track = 1, .start = 96, .len = 48, .pattern = 0, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 2, .start = 192, .len = 48, .pattern = 1, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 3, .start = 0, .len = 48, .pattern = 2 }) catch {};

    // 复制：start 归一为相对偏移（0/96）；轨道存原值（1/2）
    try std.testing.expectEqual(@as(usize, 2), app.copySelectedClips());
    try std.testing.expectEqual(@as(i32, 0), app.clipboard_clips.items[0].start);
    try std.testing.expectEqual(@as(i32, 96), app.clipboard_clips.items[1].start);
    try std.testing.expectEqual(@as(i32, 1), app.clipboard_clips.items[0].track);

    // 粘贴到鼠标位置（步 480；**轨道不变**——回原轨道 1/2）
    try std.testing.expectEqual(@as(usize, 2), app.pasteClips(480, 8));
    try std.testing.expectEqual(@as(usize, 5), app.clips.items.len);
    try std.testing.expectEqual(@as(i32, 480), app.clips.items[3].start);
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[3].track); // 原轨道
    try std.testing.expectEqual(@as(i32, 576), app.clips.items[4].start); // 相对偏移 96 保留
    try std.testing.expectEqual(@as(i32, 2), app.clips.items[4].track); // 原轨道
    try std.testing.expect(app.clips.items[3].selected);
    try std.testing.expect(!app.clips.items[0].selected); // 原选区取消
    try std.testing.expectEqual(@as(usize, 2), app.selectedClipCount());

    // 轨道钳制：把剪贴板里的轨道改成超上限（99）→ 粘贴时钳到 7（8 轨）
    app.clipboard_clips.items[0].track = 99;
    app.clipboard_clips.items[1].track = 99;
    try std.testing.expectEqual(@as(usize, 2), app.pasteClips(0, 8));
    try std.testing.expectEqual(@as(i32, 7), app.clips.items[5].track);
    try std.testing.expectEqual(@as(i32, 7), app.clips.items[6].track);
    // 步钳制：负锚点 → 起点钳到 0（相对偏移保留，超出部分被钳）
    app.clipboard_clips.items[0].track = 0;
    app.clipboard_clips.items[1].track = 1;
    try std.testing.expectEqual(@as(usize, 2), app.pasteClips(-50, 8));
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[7].start); // max(0, -50+0)
    try std.testing.expectEqual(@as(i32, 46), app.clips.items[8].start); // max(0, -50+96)

    // 无选区 → 复制 0（不污染剪贴板？——清空后为空）
    app.clearClipSelection();
    try std.testing.expectEqual(@as(usize, 0), app.copySelectedClips());
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_clips.items.len);
}

test "app: 片段批量拉伸——全组同步（任一 ≤ 一格则全组不能缩）+ 铺瓷砖克隆" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 两个片段：各 24 步（1/4 音符量级）；快照后 1/8 网格（12 步）
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 24, .pattern = 0, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 1, .start = 48, .len = 24, .pattern = 1, .selected = true }) catch {};
    app.beginClipBatchSnap();

    // 缩 1 格（-1）：24 → 12 ✓
    try std.testing.expectEqual(@as(i32, -1), app.applyClipBatchTrim(-1, 12, false));
    try std.testing.expectEqual(@as(i32, 12), app.clips.items[0].len);
    try std.testing.expectEqual(@as(i32, 12), app.clips.items[1].len);
    // 继续缩：快照 24 最多 1 格 → 钳到 -1（幂等，仍 12）
    try std.testing.expectEqual(@as(i32, -1), app.applyClipBatchTrim(-2, 12, false));
    // 回 0 格 → **还原快照**（24）——修“卡住”同一原则
    try std.testing.expectEqual(@as(i32, 0), app.applyClipBatchTrim(0, 12, false));
    try std.testing.expectEqual(@as(i32, 24), app.clips.items[0].len);
    // 加长 +2：24 + 24 = 48（从快照重算）
    try std.testing.expectEqual(@as(i32, 2), app.applyClipBatchTrim(2, 12, false));
    try std.testing.expectEqual(@as(i32, 48), app.clips.items[0].len);

    // 全组同步：有一个 = 一格 → 全组不能缩
    app.clips.items[1].len = 12;
    app.beginClipBatchSnap();
    try std.testing.expectEqual(@as(i32, 0), app.applyClipBatchTrim(-1, 12, false));
    try std.testing.expectEqual(@as(i32, 48), app.clips.items[0].len); // 未被缩短

    // 左缘拉伸：右端固定、offset 同步；片段 1 start=0 → 左缘不能加长（cap = min(0/g, 0/g) = 0）
    app.beginClipBatchSnap();
    try std.testing.expectEqual(@as(i32, 0), app.applyClipBatchTrim(1, 12, true));

    // 铺瓷砖克隆：跨度 = 最右缘(0+48 或 48+12) − 最左(0) = 60 → 克隆体 60/108
    const cloned = app.cloneSelectedClipsRight();
    try std.testing.expectEqual(@as(usize, 2), cloned);
    try std.testing.expectEqual(@as(usize, 4), app.clips.items.len);
    try std.testing.expectEqual(@as(i32, 60), app.clips.items[2].start);
    try std.testing.expectEqual(@as(i32, 108), app.clips.items[3].start);
    // 选区转移到克隆体（原选区取消）
    try std.testing.expect(!app.clips.items[0].selected);
    try std.testing.expect(app.clips.items[2].selected);
    // 再按一次 → 铺下一段（跨度 60：60→120、108→168）
    try std.testing.expectEqual(@as(usize, 2), app.cloneSelectedClipsRight());
    try std.testing.expectEqual(@as(i32, 120), app.clips.items[4].start);
    try std.testing.expectEqual(@as(i32, 168), app.clips.items[5].start);
}

test "app: 片段批量操作——框选删除 + 批量移动（幂等、轨道钳制）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 1, .start = 96, .len = 96, .pattern = 1, .selected = true }) catch {};
    app.clips.append(app.allocator, .{ .track = 2, .start = 192, .len = 96, .pattern = 2 }) catch {};

    try std.testing.expectEqual(@as(usize, 2), app.selectedClipCount());

    // 批量移动：+48 步、+1 轨（从快照重算；幂等）
    app.beginClipBatchSnap();
    try std.testing.expect(app.moveSelectedClips(48, 1, 8));
    try std.testing.expectEqual(@as(i32, 48), app.clips.items[0].start);
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[0].track);
    try std.testing.expectEqual(@as(i32, 144), app.clips.items[1].start);
    try std.testing.expectEqual(@as(i32, 2), app.clips.items[1].track);
    // 未选中片段不动
    try std.testing.expectEqual(@as(i32, 192), app.clips.items[2].start);
    // 再应用同一位移 → 结果不变（幂等）——返回值 false（无变化）
    try std.testing.expect(!app.moveSelectedClips(48, 1, 8));
    try std.testing.expectEqual(@as(i32, 48), app.clips.items[0].start);

    // 轨道钳制（**组级**）：摆到轨道 1/2 后快照 → 下移 -999 只能移 -1（保持间距）
    app.clips.items[0].track = 1;
    app.clips.items[1].track = 2;
    app.beginClipBatchSnap();
    try std.testing.expect(app.moveSelectedClips(0, -999, 8));
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[0].track); // 1-1
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[1].track); // 2-1（保持间距）
    // 更大位移 → 结果不变（组级下限 = 0；幂等）
    try std.testing.expect(!app.moveSelectedClips(0, -9999, 8));

    // 步钳制（**组级**）：快照 step 48/144 → 左移 -999 被钳到 -48（保持间距）
    app.clips.items[0].start = 48;
    app.clips.items[1].start = 144;
    app.beginClipBatchSnap();
    try std.testing.expect(app.moveSelectedClips(-999, 0, 8));
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[0].start); // 48-48
    try std.testing.expectEqual(@as(i32, 96), app.clips.items[1].start); // 144-48（保持间距）
    // 更大位移 → 结果不变（幂等）
    try std.testing.expect(!app.moveSelectedClips(-9999, 0, 8));

    // 删除选中 → 剩 1 个
    try std.testing.expectEqual(@as(usize, 2), app.deleteSelectedClips());
    try std.testing.expectEqual(@as(usize, 1), app.clips.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.selectedClipCount());
}
