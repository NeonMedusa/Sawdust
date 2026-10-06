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
const eq = @import("eq.zig");

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

/// 撤销/重做历史的一个**完整快照**（快照式撤销：恢复 = 整块回写）。
/// 存音符/片段/乐器/样式数/全局设置。
/// 乐器恢复的指针安全：数量相同 → **原位更新**（指针身份不变，音频线程安全）；
/// 数量不同 → 重建（旧指针进退役列表——**不释放**，防音频线程 use-after-free）。
pub const HistoryState = struct {
    /// 操作名（如“放置音符”；堆分配，由 App 管理生命周期）
    label: []u8,
    notes: []model.Note,
    clips: []model.Clip,
    /// 乐器快照（name 为堆分配副本；synth 为值快照）
    instruments: []persist.SavedInstrument,
    /// 调音台通道快照（含效果链；条数 = 快照时的通道数）
    mixer: []persist.SavedMixerChannel,
    pattern_count: i32 = model.default_pattern_count,
    bpm: i32 = 120,
    time_num: i32 = 4,
    time_den: i32 = 4,
    steps_per_bar: i32 = model.units_per_whole,
};

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
    /// Z 序（越大越靠上；**点窗口即置顶**）。
    /// 注：窗口各自持有 z，`main` 每帧按 z 排序绘制与声明层——
    /// 早期版本用固定 prio（两窗口同 prio），`ui.declare` 会把后声明的顶掉，
    /// 导致被顶那层的点击穿透（实测 bug）。
    z: i32 = 10,
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
    /// 添加乐器的下拉菜单（共享控件 view_util.menu*）：四个平铺字段
    menu_open: bool = false,
    menu_just_opened: bool = false,
    menu_x: i32 = 0,
    menu_y: i32 = 0,
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
    /// 历史栏：上次跟随的当前条目（**变化时才自动滚动**——否则用户无法手动滚动查看）
    history_follow: usize = 0,
};

/// 合成器编辑器（浮动窗口）状态
pub const SynthWindow = struct {
    open: bool = true,
    x: i32 = 340,
    y: i32 = 150,
    w: i32 = 520,
    h: i32 = 300,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 30,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 当前编辑的乐器槽位（0 起）
    instrument: i32 = 0,
};

/// 调音台通道数：**默认 2**（主通道 + 通道#1），可添加；上限见 `max_mixer_channels`
pub const default_mixer_channels = 2;
/// 调音台通道上限（音频层的原子数组按此设容量）
pub const max_mixer_channels = 32;
/// 每通道效果器链上限（音频层的原子数组按此设容量）
pub const max_effects_per_channel = 16;

/// 效果器类型（插件式：通道上可挂多个效果器；目前只有 EQ）
pub const EffectKind = enum(u32) {
    empty = 0,
    eq = 1,

    pub fn displayName(self: EffectKind) []const u8 {
        return switch (self) {
            .empty => "（空槽）",
            .eq => "EQ 参量均衡",
        };
    }
};

/// 一个效果器槽（插件实例）
pub const EffectSlot = struct {
    kind: EffectKind = .empty,
    /// 开关（旁通）
    enabled: bool = true,
    /// 干湿比（0-1）
    mix: f32 = 1.0,
    /// EQ 参数（kind == .eq 时有效）
    bands: [eq.band_count]eq.BandParams = .{
        .{ .freq = 100, .q = 1.0 },
        .{ .freq = 500, .q = 1.0 },
        .{ .freq = 2000, .q = 1.0 },
        .{ .freq = 8000, .q = 1.0 },
        .{ .freq = 12000, .q = 1.0 },
    },
};

/// 每通道效果器槽数（已废弃：效果器链改为**动态列表**，见 `MixerChannel.effects`；
/// 上限见 `max_effects_per_channel`）
pub const effects_per_channel = max_effects_per_channel;

/// 一个调音台通道：增益/声像/静音 + **效果器链**（插件式，动态列表）
pub const MixerChannel = struct {
    volume: f32 = 0.8, // 0-1（线性增益）
    pan: f32 = 0.5, // 0-1（0.5 = 居中）
    muted: bool = false,
    /// 效果器链（**动态**：顺序处理；空列表 = 无效果）
    effects: std.ArrayListUnmanaged(EffectSlot) = .{ .items = &.{}, .capacity = 0 },
};

/// 调音台窗口状态
pub const MixerWindow = struct {
    open: bool = false,
    x: i32 = 120,
    y: i32 = 90,
    w: i32 = 760,
    h: i32 = 420,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 20,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// “添加效果器”下拉：所属通道（null = 未展开）
    add_effect_ch: ?usize = null,
    /// 下拉菜单状态（共享控件 view_util.menu*）：四个平铺字段
    menu_open: bool = false,
    menu_just_opened: bool = false,
    menu_x: i32 = 0,
    menu_y: i32 = 0,
    /// 效果器右键菜单中的槽位（删除/上移/下移用）——null = 未展开
    ctx_effect: ?EffectRef = null,
    /// 通道右键菜单中的通道（删除/上移/下移用）——null = 未展开
    ctx_channel: ?usize = null,
    /// 右键菜单位置（**打开时快照**——不跟鼠标跑，否则永远点不到）
    ctx_menu_x: i32 = 0,
    ctx_menu_y: i32 = 0,
    /// 打开的效果器面板（通道 × 槽位；null = 未开）
    panel: ?EffectRef = null,
    /// 当前选中的通道（右侧效果器链显示哪个通道；默认 0）
    selected_channel: i32 = 0,
    /// 通道竖条区的横向滚动（像素；窗口太窄时滚轮查看）
    strips_scroll: i32 = 0,
    /// 效果链区的纵向滚动（像素；效果器太多放不下时滚轮查看）
    fx_scroll: i32 = 0,
    /// 效果器链区宽度（**可拖动分割条调整**；0 = 用默认值 `ww/4` 重算）
    fx_w: i32 = 0,
};

/// 效果器定位（通道 × 槽位）
pub const EffectRef = struct { ch: usize, slot: usize };

/// 效果器独立面板（像合成器窗口一样可拖动/缩放）
pub const EffectWindow = struct {
    x: i32 = 260,
    y: i32 = 130,
    w: i32 = 620,
    h: i32 = 340,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 40,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 正在拖动的 EQ 控制点（段；null = 无）
    eq_drag: ?usize = null,
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

    // ── 撤销/重做（快照式；见 `commitHistory`）──
    /// 历史快照栈（[0] = 初始/打开工程时的状态；current = 当前所在快照）
    history: std.ArrayListUnmanaged(HistoryState) = .{ .items = &.{}, .capacity = 0 },
    /// 当前状态在 `history` 中的下标
    history_current: usize = 0,
    /// 最后一次保存时对应的历史下标（脏标记 = 当前 != 此处）
    history_saved_index: usize = 0,
    /// 待提交的操作名（**拖动类操作**在拖动中每帧设置，帧末鼠标松开后才真正提交——
    /// 实现 coalesce：一次拖动 = 一条历史，而不是每帧一条）
    history_pending: ?[]const u8 = null,
    /// `history_pending` 是否属于**滚轮类**操作（无“松开”事件——
    /// 改用**静默间隔**提交：停止滚动约 0.6s 后提交一次）
    history_pending_wheel: bool = false,
    /// 滚轮类 pending 的最后一次变动时间（音频帧计数；`frames_played`）
    history_pending_frame: u64 = 0,

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
    /// 录制武装（工具栏红点按钮）——目前只切换视觉状态（录音写入未实现）；
    /// **不进入存档**（会话态；重开工程回到未武装）
    record_armed: bool = false,

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
    mixer_win: MixerWindow = .{},
    effect_win: EffectWindow = .{},
    /// 浮动窗口 Z 序的**全局计数器**（点窗口置顶时 +1，见 `bringToFront`）
    z_top: i32 = 50,
    /// 调音台通道（**动态**；默认 2 个，可添加；乐器通过 `Instrument.mixer` 路由到其中之一）
    mixer_channels_state: std.ArrayListUnmanaged(MixerChannel) = .{ .items = &.{}, .capacity = 0 },

    // ── 占位数据 ──
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

    /// 切换当前乐器（**唯一的乐器切换入口**）：
    /// 乐器变化时**清空音符选区**——选区是“当前样式 + 当前乐器”上下文里的，
    /// 切走后旧选中的音符会变成不可见的“孤儿选区”，批量操作（拖动/Del/克隆）
    /// 却仍会带上它们（实测 bug：切乐器后拖动，旧乐器音符跟着跑）。
    pub fn setInstrument(self: *App, idx: i32) void {
        if (self.sel.instrument == idx) return;
        self.sel.instrument = idx;
        self.clearNoteSelection();
    }

    /// 全选**当前样式 + 当前乐器**的全部音符（Ctrl+A；钢琴卷帘上下文）。
    /// 返回选中数。注：幽灵音符（其它乐器）不参与。
    pub fn selectAllNotes(self: *App, pattern: i32, instrument: i32) usize {
        var n: usize = 0;
        for (self.notes.items) |*nt| {
            if (nt.pattern != pattern or nt.instrument != instrument) continue;
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
        self.deinitMixerChannels();
        self.deinitHistory();
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

    /// 滚轮类操作的 coalesce：设置待提交名 + 记录本次变动时间。
    /// （滚轮无“松开”事件——用**静默间隔**判定：见 `pollWheelHistory`）
    pub fn markWheelHistory(self: *App, label: []const u8) void {
        self.history_pending = label;
        self.history_pending_wheel = true;
        self.history_pending_frame = self.params.frames_played.load(.monotonic);
    }

    /// 帧末调用：滚轮类 pending 若已**静默 ≥ 0.6s** → 提交一条历史。
    /// （0.6s = 采样率 × 0.6；用音频帧计数当时间源——它单调且与 UI 帧率无关）
    pub fn pollWheelHistory(self: *App) void {
        if (!self.history_pending_wheel) return;
        const label = self.history_pending orelse {
            self.history_pending_wheel = false;
            return;
        };
        const now = self.params.frames_played.load(.monotonic);
        const quiet_frames: u64 = self.params.sample_rate * 6 / 10; // 0.6s
        if (now -| self.history_pending_frame >= quiet_frames) {
            self.commitHistory(label);
            self.history_pending = null;
            self.history_pending_wheel = false;
        }
    }

    // ── 调音台通道 ──

    /// 当前通道数
    pub fn mixerChannelCount(self: *const App) usize {
        return self.mixer_channels_state.items.len;
    }

    /// 初始化调音台通道（启动/新建/加载无 mixer 字段时）：默认 `default_mixer_channels` 个。
    /// 先释放旧链（每通道效果器列表）再重建。
    pub fn resetMixerChannels(self: *App, count: usize) void {
        self.deinitMixerChannels();
        var i: usize = 0;
        while (i < count and i < max_mixer_channels) : (i += 1) {
            self.mixer_channels_state.append(self.allocator, .{}) catch break;
        }
    }

    /// 释放调音台通道（每通道的效果器链 + **列表底层数组**）
    pub fn deinitMixerChannels(self: *App) void {
        for (self.mixer_channels_state.items) |*mc| mc.effects.deinit(self.allocator);
        // 注：必须 `deinit`（释放底层数组）——`clearRetainingCapacity` 只清长度，
        // 会把数组泄漏掉（实测：undo → importMixerChannels → 重建通道后泄漏）
        self.mixer_channels_state.deinit(self.allocator);
        self.mixer_channels_state = .{ .items = &.{}, .capacity = 0 };
    }

    /// 添加一个通道（返回新通道下标；达到上限返回 null）
    pub fn addMixerChannel(self: *App) ?usize {
        if (self.mixer_channels_state.items.len >= max_mixer_channels) return null;
        self.mixer_channels_state.append(self.allocator, .{}) catch return null;
        return self.mixer_channels_state.items.len - 1;
    }

    /// 给某通道添加一个效果器（返回新槽下标；达到上限返回 null）
    pub fn addEffect(self: *App, ch: usize, kind: EffectKind) ?usize {
        if (ch >= self.mixer_channels_state.items.len) return null;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (chain.items.len >= max_effects_per_channel) return null;
        chain.append(self.allocator, .{ .kind = kind }) catch return null;
        return chain.items.len - 1;
    }

    /// 删除某通道的第 `slot` 个效果器
    pub fn removeEffect(self: *App, ch: usize, slot: usize) void {
        if (ch >= self.mixer_channels_state.items.len) return;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (slot >= chain.items.len) return;
        _ = chain.orderedRemove(slot);
    }

    /// 效果器上移/下移（`dir`：-1 上、+1 下）；返回是否移动了。
    /// 面板跟随移动后的槽位。
    pub fn moveEffect(self: *App, ch: usize, slot: usize, dir: i32) bool {
        if (ch >= self.mixer_channels_state.items.len) return false;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (slot >= chain.items.len or chain.items.len < 2) return false;
        const ni: usize = if (dir < 0) slot -| 1 else @min(slot + 1, chain.items.len - 1);
        if (ni == slot) return false;
        std.mem.swap(EffectSlot, &chain.items[slot], &chain.items[ni]);
        if (self.mixer_win.panel) |p| {
            if (p.ch == ch and p.slot == slot) self.mixer_win.panel = .{ .ch = ch, .slot = ni };
        }
        return true;
    }

    /// 通道上移/下移（`dir`：-1 上、+1 下）；返回是否移动了。
    /// **乐器的通道路由与选中通道跟随交换**。
    pub fn moveMixerChannel(self: *App, ch: usize, dir: i32) bool {
        const n = self.mixer_channels_state.items.len;
        if (ch >= n or n < 2) return false;
        const ni: usize = if (dir < 0) ch -| 1 else @min(ch + 1, n - 1);
        if (ni == ch) return false;
        std.mem.swap(MixerChannel, &self.mixer_channels_state.items[ch], &self.mixer_channels_state.items[ni]);
        // 乐器路由跟随（交换两个通道号）
        for (self.instruments.items) |*inst| {
            if (inst.mixer == @as(i32, @intCast(ch))) {
                inst.mixer = @intCast(ni);
            } else if (inst.mixer == @as(i32, @intCast(ni))) {
                inst.mixer = @intCast(ch);
            }
        }
        // 选中/面板跟随
        if (self.mixer_win.selected_channel == @as(i32, @intCast(ch))) {
            self.mixer_win.selected_channel = @intCast(ni);
        } else if (self.mixer_win.selected_channel == @as(i32, @intCast(ni))) {
            self.mixer_win.selected_channel = @intCast(ch);
        }
        if (self.mixer_win.panel) |p| {
            if (p.ch == ch) {
                self.mixer_win.panel = .{ .ch = ni, .slot = p.slot };
            } else if (p.ch == ni) {
                self.mixer_win.panel = .{ .ch = ch, .slot = p.slot };
            }
        }
        return true;
    }

    /// 删除一个调音台通道（**至少保留 1 条**）；路由到此通道的乐器向前补位。
    /// 返回是否删除成功。
    pub fn removeMixerChannel(self: *App, ch: usize) bool {
        const n = self.mixer_channels_state.items.len;
        if (ch >= n or n <= 1) return false;
        var removed = self.mixer_channels_state.items[ch];
        removed.effects.deinit(self.allocator);
        _ = self.mixer_channels_state.orderedRemove(ch);
        // 面板/选中修正
        if (self.mixer_win.panel) |p| {
            if (p.ch == ch) self.mixer_win.panel = null;
        }
        const new_n: i32 = @intCast(self.mixer_channels_state.items.len);
        if (self.mixer_win.selected_channel >= new_n) self.mixer_win.selected_channel = new_n - 1;
        // 乐器路由：删除点之后的向前补位，并钳到有效范围
        for (self.instruments.items) |*inst| {
            if (inst.mixer > @as(i32, @intCast(ch))) inst.mixer -= 1;
            inst.mixer = std.math.clamp(inst.mixer, 0, @max(0, new_n - 1));
        }
        return true;
    }

    // ── 浮动窗口 Z 序（“点谁谁置顶”）──

    /// 把某窗口提到最上层（点击该窗口时调用）。
    /// 参数是窗口 z 字段的指针——四个窗口结构都持有 `z: i32`。
    pub fn bringToFront(self: *App, z: *i32) void {
        self.z_top += 1;
        z.* = self.z_top;
    }

    // ── 撤销/重做（快照式）──

    /// 历史容量上限（超出后丢弃最旧的快照）
    pub const history_limit: usize = 128;

    /// 标记“已保存”（脏标记清零 + 记住当前历史位置）
    pub fn markSaved(self: *App) void {
        self.dirty = false;
        self.history_saved_index = self.history_current;
    }

    /// 当前历史条目的操作名（供 toast/历史栏；无历史时返回 ""）
    pub fn historyLabel(self: *const App) []const u8 {
        if (self.history.items.len == 0) return "";
        return self.history.items[self.history_current].label;
    }

    fn freeHistoryState(self: *App, st: *const HistoryState) void {
        self.allocator.free(st.label);
        self.allocator.free(st.notes);
        self.allocator.free(st.clips);
        // 注：**不要**加 `if (len > 0)`——`alloc(T, 0)` 也必须配对 `free`
        // （测试分配器会把 0 长度分配记为泄漏）
        self.freeSavedMixerChannels(st.mixer);
        self.allocator.free(st.mixer);
        for (st.instruments) |si| self.allocator.free(si.name);
        self.allocator.free(st.instruments);
    }

    /// 把当前调音台通道导出为存档切片（历史快照 / 工程保存共用）
    fn exportMixerChannels(self: *App, allocator: std.mem.Allocator) ![]persist.SavedMixerChannel {
        const n_ch = self.mixer_channels_state.items.len;
        // 注：即使 0 条也要返回**已分配**切片（与 `free` 配对；
        // 不能直接返回 `&.{}`——那样 `freeHistoryState` 的 `free` 会崩，
        // 而返回 `alloc(0)` 又必须被 free）
        const mix = try allocator.alloc(persist.SavedMixerChannel, n_ch);
        errdefer allocator.free(mix);
        for (self.mixer_channels_state.items, 0..) |mc, i| {
            var sm = persist.SavedMixerChannel{
                .volume = mc.volume,
                .pan = mc.pan,
                .muted = mc.muted,
            };
            for (mc.effects.items, 0..) |es, si| {
                if (si >= sm.effects.len) break; // 超出存档容量：截断
                // 效果器段：分配切片（长度 = band_count）
                const bands = try allocator.alloc(persist.SavedEqBand, es.bands.len);
                for (es.bands, 0..) |b, bi| {
                    bands[bi] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
                }
                sm.effects[si] = .{
                    .kind = @intFromEnum(es.kind),
                    .enabled = es.enabled,
                    .mix = es.mix,
                    .bands = bands,
                };
            }
            sm.effect_count = @intCast(@min(mc.effects.items.len, sm.effects.len));
            mix[i] = sm;
        }
        return mix;
    }

    /// 用存档切片恢复调音台通道（历史恢复 / 工程加载共用）
    fn importMixerChannels(self: *App, mixer: []const persist.SavedMixerChannel) void {
        if (mixer.len == 0) {
            self.resetMixerChannels(default_mixer_channels);
            return;
        }
        self.resetMixerChannels(@min(mixer.len, max_mixer_channels));
        for (mixer[0..self.mixer_channels_state.items.len], 0..) |sm, i| {
            self.mixer_channels_state.items[i].volume = sm.volume;
            self.mixer_channels_state.items[i].pan = sm.pan;
            self.mixer_channels_state.items[i].muted = sm.muted;
            // 效果链：按 effect_count 恢复（0 = 旧存档：按 kind != 0 推断）
            const n_eff: usize = if (sm.effect_count > 0)
                @min(@as(usize, @intCast(sm.effect_count)), sm.effects.len)
            else blk: {
                var n: usize = 0;
                for (sm.effects) |se| {
                    if (se.kind != 0) n += 1;
                }
                break :blk n;
            };
            var se_i: usize = 0;
            while (se_i < n_eff) : (se_i += 1) {
                const se = sm.effects[se_i];
                const kind: EffectKind = switch (se.kind) {
                    1 => .eq,
                    else => continue, // 未知类型跳过
                };
                const slot = self.addEffect(i, kind) orelse break;
                const es = &self.mixer_channels_state.items[i].effects.items[slot];
                es.enabled = se.enabled;
                es.mix = se.mix;
                // 段：按需复制（旧存档 4 段 → 剩下的段保留默认值）
                const nb: usize = @min(se.bands.len, es.bands.len);
                for (se.bands[0..nb], 0..) |b, bi| {
                    es.bands[bi] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
                }
            }
        }
    }

    /// 捕获当前状态为快照（调用方负责释放；失败返回 error）
    fn captureHistory(self: *App, label: []const u8) !HistoryState {
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
        const notes = try self.allocator.dupe(model.Note, self.notes.items);
        errdefer self.allocator.free(notes);
        const clips = try self.allocator.dupe(model.Clip, self.clips.items);
        errdefer self.allocator.free(clips);
        const insts = try self.allocator.alloc(persist.SavedInstrument, self.instruments.items.len);
        var n: usize = 0;
        errdefer {
            for (insts[0..n]) |si| self.allocator.free(si.name);
            self.allocator.free(insts);
        }
        for (self.instruments.items, 0..) |inst, i| {
            insts[i] = .{
                .name = try self.allocator.dupe(u8, inst.name),
                .volume = inst.volume,
                .pan = inst.pan,
                .muted = inst.muted,
                .mixer = inst.mixer,
                .midi_channel = inst.midi_channel,
                .synth = persist.exportSynth(inst.synth),
            };
            n += 1;
        }
        const mixer = try self.exportMixerChannels(self.allocator);
        return .{
            .label = label_copy,
            .notes = notes,
            .clips = clips,
            .instruments = insts,
            .mixer = mixer,
            .pattern_count = self.patternCount(),
            .bpm = self.bpm,
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
        };
    }

    /// 当前状态是否与 `history[history_current]` 等价（**忽略选区**——
    /// 选区是瞬态，不应产生历史条目/脏标记）
    fn stateEqualsCurrent(self: *const App) bool {
        if (self.history.items.len == 0) return false;
        const st = self.history.items[self.history_current];
        if (st.notes.len != self.notes.items.len or st.clips.len != self.clips.items.len) return false;
        for (st.notes, self.notes.items) |a, b| {
            if (a.step != b.step or a.len != b.len or a.pitch != b.pitch or
                a.pattern != b.pattern or a.instrument != b.instrument) return false;
        }
        for (st.clips, self.clips.items) |a, b| {
            if (a.track != b.track or a.start != b.start or a.len != b.len or
                a.pattern != b.pattern or a.offset != b.offset) return false;
        }
        if (st.instruments.len != self.instruments.items.len) return false;
        for (st.instruments, self.instruments.items) |a, b| {
            if (a.volume != b.volume or a.pan != b.pan or a.muted != b.muted or
                a.mixer != b.mixer or a.midi_channel != b.midi_channel) return false;
            if (!std.mem.eql(u8, a.name, b.name)) return false;
            // **合成器参数也要比较**——否则 ADSR/滤波等改动会被判为“无变化”，
            // 静默丢弃历史条目（实测 bug：调 ADSR 不产生历史）
            const cur = persist.exportSynth(b.synth);
            if (!std.meta.eql(a.synth, cur)) return false;
        }
        if (st.bpm != self.bpm or st.time_num != self.time_num or st.time_den != self.time_den) return false;
        if (st.pattern_count != self.patternCount()) return false;
        // 调音台通道（数量/增益/声像/静音/效果链）——否则“添加通道/效果器”会被判无变化
        if (st.mixer.len != self.mixer_channels_state.items.len) return false;
        for (st.mixer, self.mixer_channels_state.items) |a, b| {
            if (a.volume != b.volume or a.pan != b.pan or a.muted != b.muted) return false;
            const bn: usize = @min(b.effects.items.len, a.effects.len);
            if (a.effect_count != b.effects.items.len) return false;
            for (0..bn) |si| {
                const ae = a.effects[si];
                const be = b.effects.items[si];
                if (ae.kind != @intFromEnum(be.kind) or ae.enabled != be.enabled or ae.mix != be.mix) return false;
                for (ae.bands, be.bands) |ab, bb| {
                    if (ab.freq != bb.freq or ab.gain_db != bb.gain_db or ab.q != bb.q) return false;
                }
            }
        }
        return true;
    }

    /// 提交一次历史快照（**操作完成后**调用；`label` 会被复制）。
    /// 若当前状态与所在快照等价（忽略选区）→ 不产生新条目（防“点了没动”噪音）。
    pub fn commitHistory(self: *App, label: []const u8) void {
        if (self.history.items.len > 0 and self.stateEqualsCurrent()) return;
        // 截断 redo 尾巴（新操作发生在撤销之后）
        while (self.history.items.len > self.history_current + 1) {
            var st = self.history.pop().?;
            self.freeHistoryState(&st);
        }
        const st = self.captureHistory(label) catch return;
        self.history.append(self.allocator, st) catch {
            self.freeHistoryState(&st);
            return;
        };
        self.history_current = self.history.items.len - 1;
        // 超限：丢最旧
        while (self.history.items.len > history_limit) {
            var old = self.history.orderedRemove(0);
            self.freeHistoryState(&old);
            if (self.history_current > 0) self.history_current -= 1;
            if (self.history_saved_index > 0) self.history_saved_index -= 1;
        }
    }

    /// 应用历史快照（恢复 = 整块回写；顺带钳制选择/乐器索引）
    fn applyHistoryState(self: *App, st: *const HistoryState) void {
        self.stopPlayback(); // 调度器引用旧数据：先停
        self.history_pending = null; // 拖动中的 coalesce 标记作废
        self.history_pending_wheel = false; // 滚轮类 pending 一并作废
        // 拖动状态全部清空：撤销/重做后数据已换，旧拖动（及其快照/下标）
        // 会指向错误内容（下标可能越界）；用户需重新按下才能继续拖
        self.piano.drag_note = null;
        self.piano.drag_batch = false;
        self.piano.batch_trim = false;
        self.piano.marquee_active = false;
        self.playlist.drag_clip = null;
        self.playlist.resize_clip = null;
        self.playlist.drag_batch = false;
        self.playlist.batch_trim = false;
        self.playlist.erase_drag = false;
        self.playlist.marquee_active = false;
        // 乐器：数量相同 → **原位更新**（指针身份不变——音频线程安全）；
        // 数量不同 → 重建（removeInstrument 会把旧指针送入退役列表，不释放）
        if (st.instruments.len == self.instruments.items.len) {
            for (st.instruments, 0..) |si, i| {
                const target = &self.instruments.items[i];
                if (!std.mem.eql(u8, target.name, si.name)) {
                    const dup = self.allocator.dupe(u8, si.name) catch continue;
                    self.allocator.free(target.name);
                    target.name = dup;
                }
                target.volume = si.volume;
                target.pan = si.pan;
                target.muted = si.muted;
                target.mixer = si.mixer;
                target.midi_channel = si.midi_channel;
                persist.importSynth(&si.synth, target.synth);
            }
        } else {
            while (self.instruments.items.len > 0) {
                self.removeInstrument(self.instruments.items.len - 1);
            }
            for (st.instruments) |si| {
                const idx = self.addInstrument(si.name);
                if (idx < 0) continue;
                const target = &self.instruments.items[@intCast(idx)];
                target.volume = si.volume;
                target.pan = si.pan;
                target.muted = si.muted;
                target.mixer = si.mixer;
                target.midi_channel = si.midi_channel;
                persist.importSynth(&si.synth, target.synth);
            }
        }
        // 音符/片段
        self.notes.clearRetainingCapacity();
        for (st.notes) |n| {
            var copy = n;
            if (self.instruments.items.len > 0) {
                copy.instrument = std.math.clamp(copy.instrument, 0, @as(i32, @intCast(self.instruments.items.len)) - 1);
            }
            self.notes.append(self.allocator, copy) catch {};
        }
        self.clips.clearRetainingCapacity();
        for (st.clips) |c| self.clips.append(self.allocator, c) catch {};
        if (st.pattern_count > 0 and st.pattern_count != self.patternCount()) {
            const was_dirty = self.dirty;
            self.resetPatterns(st.pattern_count);
            self.dirty = was_dirty;
        }
        self.bpm = st.bpm;
        self.time_num = st.time_num;
        self.time_den = st.time_den;
        self.steps_per_bar = st.steps_per_bar;
        // 调音台通道（含效果链）
        self.importMixerChannels(st.mixer);
        // 选择钳制
        if (self.sel.pattern >= self.patternCount()) self.sel.pattern = self.patternCount() - 1;
        if (self.mixer_win.selected_channel >= @as(i32, @intCast(self.mixer_channels_state.items.len))) {
            self.mixer_win.selected_channel = @intCast(@max(0, self.mixer_channels_state.items.len - 1));
        }
        // 效果器面板：目标可能已不存在 → 关闭
        if (self.mixer_win.panel) |p| {
            if (p.ch >= self.mixer_channels_state.items.len or
                p.slot >= self.mixer_channels_state.items[p.ch].effects.items.len)
            {
                self.mixer_win.panel = null;
            }
        }
    }

    /// 撤销（Ctrl+Z）。返回是否成功。
    pub fn undo(self: *App) bool {
        if (self.history.items.len == 0 or self.history_current == 0) return false;
        self.history_current -= 1;
        self.applyHistoryState(&self.history.items[self.history_current]);
        self.dirty = self.history_current != self.history_saved_index;
        return true;
    }

    /// 重做（Ctrl+Alt+Z）。返回是否成功。
    pub fn redo(self: *App) bool {
        if (self.history.items.len == 0 or self.history_current + 1 >= self.history.items.len) return false;
        self.history_current += 1;
        self.applyHistoryState(&self.history.items[self.history_current]);
        self.dirty = self.history_current != self.history_saved_index;
        return true;
    }

    /// 跳转到指定历史条目（历史栏点击）。返回是否成功。
    pub fn jumpHistory(self: *App, index: usize) bool {
        if (self.history.items.len == 0 or index >= self.history.items.len or index == self.history_current) return false;
        self.history_current = index;
        self.applyHistoryState(&self.history.items[index]);
        self.dirty = self.history_current != self.history_saved_index;
        return true;
    }

    /// 重置历史（启动/打开工程时）：以当前状态为基线（`label` 如“初始状态”）。
    pub fn resetHistory(self: *App, label: []const u8) void {
        for (self.history.items) |*st| self.freeHistoryState(st);
        self.history.clearRetainingCapacity();
        self.history_pending = null;
        self.history_pending_wheel = false;
        if (self.captureHistory(label)) |st| {
            self.history.append(self.allocator, st) catch self.freeHistoryState(&st);
        } else |_| {}
        self.history_current = 0;
        self.history_saved_index = 0;
    }

    /// 释放历史（进程退出）
    pub fn deinitHistory(self: *App) void {
        for (self.history.items) |*st| self.freeHistoryState(st);
        self.history.deinit(self.allocator);
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
        // 调音台通道（增益/声像/静音/效果链）——共用 `exportMixerChannels`
        const mix = try self.exportMixerChannels(alloc);
        return .{
            .bpm = self.bpm,
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
            .pattern_count = self.patternCount(),
            .clips = clips,
            .notes = notes,
            .instruments = insts,
            .mixer = mix,
        };
    }

    /// 释放 `exportProject` 返回的存档（含内部字符串）
    /// 释放存档切片里的调音台通道（含每效果的 bands 子切片）——多处共用
    fn freeSavedMixerChannels(self: *App, mixer: []const persist.SavedMixerChannel) void {
        for (mixer) |sm| {
            for (sm.effects[0..@min(sm.effects.len, sm.effect_count)]) |se| {
                if (se.bands.len > 0) self.allocator.free(se.bands);
            }
        }
    }

    pub fn freeProject(self: *App, p: persist.Project) void {
        for (p.instruments) |inst| self.allocator.free(inst.name);
        self.allocator.free(p.clips);
        self.allocator.free(p.notes);
        self.allocator.free(p.instruments);
        if (p.mixer.len > 0) {
            self.freeSavedMixerChannels(p.mixer);
            self.allocator.free(p.mixer);
        }
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
        // 调音台通道：**动态数量**（旧存档无此字段 → 保持默认 2 个）——共用 `importMixerChannels`
        self.importMixerChannels(p.mixer);
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

test "app: 滚轮类操作 coalesce（静默 0.6s 才提交一条历史）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");
    const base = app.history.items.len;

    // 模拟连续滚动：每帧改一点数据 + markWheelHistory（帧间隔小）
    // 音频帧计数手动推进（测试里无真实音频）
    var f: u64 = app.params.frames_played.load(.monotonic);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        f += 1000; // 1k 帧/步（约 20ms）
        app.params.frames_played.store(f, .monotonic);
        // 真改数据（否则 commitHistory 判“无变化”而静默跳过）
        app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .eq }) catch {};
        app.markWheelHistory("调整 EQ Q 值");
        app.pollWheelHistory(); // 间隔远小于 0.6s → 不提交
    }
    try std.testing.expectEqual(base, app.history.items.len); // 还没提交

    // 静默 ≥ 0.6s（= 28800 帧）→ 提交**一条**
    f += app.params.sample_rate * 7 / 10;
    app.params.frames_played.store(f, .monotonic);
    app.pollWheelHistory();
    try std.testing.expectEqual(base + 1, app.history.items.len); // 只多一条

    // 再滚一轮（又会开新的一条）
    f += 1000;
    app.params.frames_played.store(f, .monotonic);
    app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .eq }) catch {};
    app.markWheelHistory("调整 EQ Q 值");
    f += app.params.sample_rate * 7 / 10;
    app.params.frames_played.store(f, .monotonic);
    app.pollWheelHistory();
    try std.testing.expectEqual(base + 2, app.history.items.len);
}

test "app: 调音台——通道/效果器上移下移 + 删除通道（路由跟随）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(4);
    _ = app.addInstrument("减法合成器");
    _ = app.addInstrument("减法合成器");
    // 乐器 0 → 通道 1；乐器 1 → 通道 2
    app.instruments.items[0].mixer = 1;
    app.instruments.items[1].mixer = 2;
    app.resetHistory("初始状态");

    // 给通道 1 加 2 个效果器（带可区分参数）
    _ = app.addEffect(1, .eq);
    _ = app.addEffect(1, .eq);
    app.mixer_channels_state.items[1].effects.items[0].mix = 0.1;
    app.mixer_channels_state.items[1].effects.items[1].mix = 0.9;

    // 效果器下移：0 ↔ 1 交换
    try std.testing.expect(app.moveEffect(1, 0, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), app.mixer_channels_state.items[1].effects.items[0].mix, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), app.mixer_channels_state.items[1].effects.items[1].mix, 0.001);
    // 已在末尾 → 不能再下移
    try std.testing.expect(!app.moveEffect(1, 1, 1));
    // 上移回来
    try std.testing.expect(app.moveEffect(1, 1, -1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), app.mixer_channels_state.items[1].effects.items[0].mix, 0.001);

    // 通道下移：通道 1（含效果链）→ 2；**乐器路由跟随交换**
    try std.testing.expect(app.moveMixerChannel(1, 1));
    try std.testing.expectEqual(@as(usize, 2), app.mixer_channels_state.items[2].effects.items.len); // 链跟着走
    try std.testing.expectEqual(@as(i32, 2), app.instruments.items[0].mixer); // 1 → 2
    try std.testing.expectEqual(@as(i32, 1), app.instruments.items[1].mixer); // 2 → 1

    // 删除通道 2（当前它带 2 个效果器）→ 路由补位；视图层会提交历史，测试里手动提交
    try std.testing.expect(app.removeMixerChannel(2));
    app.commitHistory("删除通道");
    try std.testing.expectEqual(@as(usize, 3), app.mixer_channels_state.items.len);
    // 原来路由到 2 的乐器 → 被钳到 2（现最大下标）
    try std.testing.expectEqual(@as(i32, 2), app.instruments.items[0].mixer);

    // 只剩 1 条时不能删
    _ = app.removeMixerChannel(0);
    _ = app.removeMixerChannel(0);
    try std.testing.expectEqual(@as(usize, 1), app.mixer_channels_state.items.len);
    try std.testing.expect(!app.removeMixerChannel(0));

    // 撤销：删除通道可恢复（含效果链）——撤销最后一次**已提交**的操作
    // （上面两次 removeMixerChannel 未提交历史，所以撤销回到“删除通道”之前 = 4 条）
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 4), app.mixer_channels_state.items.len);
}

test "app: 调音台——添加通道/效果器 + 撤销恢复（动态链）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 默认 2 条通道（主通道 + 通道#1）
    try std.testing.expectEqual(@as(usize, 2), app.mixer_channels_state.items.len);

    // 添加通道 → 3 条；提交历史
    try std.testing.expect(app.addMixerChannel() != null);
    app.commitHistory("添加通道");
    try std.testing.expectEqual(@as(usize, 3), app.mixer_channels_state.items.len);

    // 添加效果器（动态链）：第一条通道加 2 个
    try std.testing.expect(app.addEffect(0, .eq) != null);
    try std.testing.expect(app.addEffect(0, .eq) != null);
    app.commitHistory("添加效果器");
    try std.testing.expectEqual(@as(usize, 2), app.mixer_channels_state.items[0].effects.items.len);

    // **撤销应恢复效果链**（回到 0 个效果器）
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 0), app.mixer_channels_state.items[0].effects.items.len);
    // 再撤销 → 回到 2 条通道
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 2), app.mixer_channels_state.items.len);

    // 重做 → 回到 3 条 + 2 个效果器
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(usize, 3), app.mixer_channels_state.items.len);
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(usize, 2), app.mixer_channels_state.items[0].effects.items.len);

    // 删除效果器（中间删）
    app.removeEffect(0, 0);
    app.commitHistory("删除效果器");
    try std.testing.expectEqual(@as(usize, 1), app.mixer_channels_state.items[0].effects.items.len);

    // 通道上限：添到满
    while (app.addMixerChannel() != null) {}
    try std.testing.expectEqual(@as(usize, max_mixer_channels), app.mixer_channels_state.items.len);
    try std.testing.expect(app.addMixerChannel() == null);
}

test "app: 撤销——合成器参数（ADSR）也恢复（修“调 ADSR 不产生历史”）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 修改 ADSR（attack 0.05 → 0.8）→ 提交
    const old_attack = app.instruments.items[0].synth.attack.load(.monotonic);
    app.instruments.items[0].synth.attack.store(0.8, .monotonic);
    app.commitHistory("调整 ADSR");
    // **关键回归**：stateEqualsCurrent 必须比较合成器参数——
    // 旧实现漏了 → 判为“无变化” → 历史条目被静默丢弃
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len);

    // 撤销 → attack 恢复
    try std.testing.expect(app.undo());
    try std.testing.expectApproxEqAbs(old_attack, app.instruments.items[0].synth.attack.load(.monotonic), 0.0001);
    // 重做 → 回到 0.8
    try std.testing.expect(app.redo());
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), app.instruments.items[0].synth.attack.load(.monotonic), 0.0001);
}

test "app: 撤销/重做——快照式（放置/删除/修改 + redo 截断 + 选区无关）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // ① 放置音符 → 提交历史
    app.addNote(.{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history_current);

    // ② 再放一个 → 第三条
    app.addNote(.{ .step = 48, .len = 24, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len);

    // ③ 撤销 → 回到 1 个音符
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 1), app.notes.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.history_current);
    try std.testing.expectEqualStrings("放置音符", app.historyLabel());

    // ④ 再撤销 → 回到 0 个
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 0), app.notes.items.len);
    // 到底了 → 再撤销失败
    try std.testing.expect(!app.undo());

    // ⑤ 重做 → 回到 1 个；再重做 → 2 个；到头失败
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(usize, 1), app.notes.items.len);
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len);
    try std.testing.expect(!app.redo());

    // ⑥ 撤销后新操作 → **截断 redo 尾巴**
    try std.testing.expect(app.undo()); // 回到 1 个（current = 1）
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len);
    app.addNote(.{ .step = 96, .len = 24, .pitch = 64, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符"); // 新分支
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len); // 尾巴被截断（回到 3 条）
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len); // 1 + 新 1
    try std.testing.expect(!app.redo()); // redo 已不可用

    // ⑦ **选区变化不产生历史**（瞬态）：
    const before = app.history.items.len;
    app.notes.items[0].selected = true;
    app.commitHistory("选中"); // 状态等价 → 不提交
    try std.testing.expectEqual(before, app.history.items.len);

    // ⑧ 脏标记与保存点：markSaved 后撤销 → 变脏；重做回来 → 不脏
    app.markSaved();
    try std.testing.expect(!app.dirty);
    _ = app.undo();
    try std.testing.expect(app.dirty);
    _ = app.redo();
    try std.testing.expect(!app.dirty);

    // ⑨ 跳转历史（历史栏点击）：跳回第 0 条
    try std.testing.expect(app.jumpHistory(0));
    try std.testing.expectEqual(@as(usize, 0), app.notes.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.history_current);
}

test "app: 撤销——乐器/全局设置（BPM、拍号、乐器增删）也恢复" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // BPM 修改
    app.bpm = 150;
    app.commitHistory("调整 BPM");
    // 拍号修改
    app.time_num = 3;
    app.steps_per_bar = model.stepsPerBarFor(3, 4);
    app.commitHistory("调整拍号");
    // 添加乐器
    _ = app.addInstrument("减法合成器");
    app.commitHistory("添加乐器");
    try std.testing.expectEqual(@as(usize, 2), app.instruments.items.len);

    // 撤销三次：乐器数、拍号、BPM 逐项恢复
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 1), app.instruments.items.len);
    try std.testing.expectEqual(@as(i32, 3), app.time_num); // 拍号还是 3（只撤销了乐器）
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(i32, 4), app.time_num); // 拍号恢复
    try std.testing.expectEqual(@as(i32, 150), app.bpm); // BPM 还是 150
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(i32, 120), app.bpm); // BPM 恢复
    // 重做三次回到最新
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(i32, 150), app.bpm);
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(i32, 3), app.time_num);
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(usize, 2), app.instruments.items.len);
}

test "app: 切换乐器清选区（防跨乐器“孤儿选区”：拖动时旧乐器音符跟着跑）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    _ = app.addInstrument("减法合成器");
    _ = app.addInstrument("减法合成器");

    // 乐器 0 的音符被选中（模拟：选了几个乐器 1 的音符）
    app.notes.append(app.allocator, .{ .step = 0, .len = 12, .pitch = 60, .pattern = 0, .instrument = 0, .selected = true }) catch {};
    app.sel.instrument = 0;
    try std.testing.expectEqual(@as(usize, 1), app.selectedNoteCount());

    // 切到乐器 1 → **选区清空**（孤儿选区消除）
    app.setInstrument(1);
    try std.testing.expectEqual(@as(i32, 1), app.sel.instrument);
    try std.testing.expectEqual(@as(usize, 0), app.selectedNoteCount());

    // 切回乐器 0 → 选区仍空（不会“恢复”旧选区）
    app.setInstrument(0);
    try std.testing.expectEqual(@as(usize, 0), app.selectedNoteCount());

    // 切到**同一**乐器 → 选区保留（不误清）
    app.notes.items[0].selected = true;
    app.setInstrument(0);
    try std.testing.expectEqual(@as(usize, 1), app.selectedNoteCount());
}

test "app: 全选——音符（仅当前样式 + 当前乐器）/ 片段" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 音符：样式 0 乐器 0 两个、样式 0 乐器 1 一个（幽灵）、样式 1 乐器 0 一个
    app.notes.append(app.allocator, .{ .step = 0, .len = 12, .pitch = 60, .pattern = 0, .instrument = 0 }) catch {};
    app.notes.append(app.allocator, .{ .step = 24, .len = 12, .pitch = 62, .pattern = 0, .instrument = 0 }) catch {};
    app.notes.append(app.allocator, .{ .step = 12, .len = 12, .pitch = 61, .pattern = 0, .instrument = 1 }) catch {};
    app.notes.append(app.allocator, .{ .step = 48, .len = 12, .pitch = 64, .pattern = 1, .instrument = 0 }) catch {};

    // Ctrl+A（钢琴卷帘上下文）：只选当前样式（0）+ 当前乐器（0）的全部音符
    // **回归**：旧实现只看样式——会把幽灵音符（其它乐器）也选中
    try std.testing.expectEqual(@as(usize, 2), app.selectAllNotes(0, 0));
    try std.testing.expectEqual(@as(usize, 2), app.selectedNoteCount());
    try std.testing.expect(app.notes.items[0].selected);
    try std.testing.expect(app.notes.items[1].selected);
    try std.testing.expect(!app.notes.items[2].selected); // 幽灵（乐器 1）不受影响
    try std.testing.expect(!app.notes.items[3].selected); // 样式 1 不受影响

    // 切乐器：样式 0 + 乐器 1 → 只选幽灵那个
    app.clearNoteSelection();
    try std.testing.expectEqual(@as(usize, 1), app.selectAllNotes(0, 1));
    try std.testing.expect(app.notes.items[2].selected);

    // 切样式全选：样式 1 + 乐器 0
    app.clearNoteSelection();
    try std.testing.expectEqual(@as(usize, 1), app.selectAllNotes(1, 0));
    try std.testing.expect(app.notes.items[3].selected);

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
