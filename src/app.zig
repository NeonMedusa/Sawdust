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
const preset_mod = @import("preset.zig");

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

/// 键盘移动选中音符的请求（Shift/Ctrl+方向键；main 登记、音符视图消费）
pub const MoveReq = struct {
    d_step: i32 = 0,
    d_pitch: i32 = 0,
    /// 粗移（Ctrl：八度/小节）＝**全有或全无**：完整位移不可行 → 拒不动
    /// （部分鉗制会让音高级数/拍位漂移；见 `nudgeSelectedNotesExact`）
    exact: bool = false,
};

/// 剪贴板音符（step 存为**相对**最左音符的偏移；粘贴时加到锚点）
/// ——力度/声像随复制粘贴携带（默认值兜底旧数据）
pub const ClipboardNote = struct {
    step: i32,
    len: i32,
    pitch: i32,
    velocity: i32 = model.default_velocity,
    pan: i32 = model.default_pan,
};

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
    /// 样式名字快照（每项堆分配；长度 = 样式数）——重命名/增删样式也要能撤销
    /// （只存 `pattern_count` 不够：`resetPatterns` 会重建默认名，自定义名丢失）
    pattern_names: [][]u8,
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

/// 预设操作的**目标**：哪个“合成器参数槽”（乐器本体 / 鼓组层 / 以新层加入垫）。
/// 这是“合成器窗口当前编辑谁”与“预设浏览器加载到哪”的统一坐标。
pub const PresetTarget = union(enum) {
    /// 乐器的合成器参数（synth 类型乐器）
    instrument: i32,
    /// **替换**指定鼓组层的参数（合成器窗口打开该层时）
    kit_layer_replace: KitLayerRef,

    /// 鼓组层引用（乐器槽位 + 垫音高 + 层下标）
    pub const KitLayerRef = struct { instrument: i32, pitch: u8, layer: usize };

    /// 与另一个目标是否指向同一参数槽（窗口刷新/防误关用）
    pub fn eql(a: PresetTarget, b: PresetTarget) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .instrument => |i| b.instrument == i,
            .kit_layer_replace => |r| b.kit_layer_replace.instrument == r.instrument and
                b.kit_layer_replace.pitch == r.pitch and
                b.kit_layer_replace.layer == r.layer,
        };
    }
};

/// 预设浏览器弹窗状态（**统一的插件+预设选择器**；见 `docs/drumkit.md` §5.2）
pub const PresetBrowser = struct {
    open: bool = false,
    /// 选中分类序号（指向 `preset_lib.categories`；越界时锚 0）
    cat: usize = 0,
    /// 右栏滚动位置（px）
    scroll: i32 = 0,
    /// 本帧刚打开（打开的那一下点击不能马上关闭/选中条目——与菜单 `just_opened` 同一模式；
    /// 实测 bug：点「预设 ▾」→ 同一帧被判定“点击面板外” → 面板一闪就没）
    just_opened: bool = false,
    /// 本次面板的意图（打开时设定；点击条目时随 `pending_preset` 排队）
    intent: PresetIntent = .create_instrument,
    /// 锚插件（分类 id）：replace → 要求的插件；create/change → 初始选中分类的依据
    plugin: []const u8 = preset_mod.plugin_subtractive,
    /// 右键菜单：右键的预设行下标（null = 未展开；仅对当前分类的预设文件行）
    ctx: ?usize = null,
    ctx_x: i32 = 0,
    ctx_y: i32 = 0,
};

    /// 预设面板的**意图**（同一面板服务四条路：选预设 / 新建 / 更换 / 加层）——
/// 决定左栏分类的可选性（`presetCategorySelectable`）与选中后的动作。
pub const PresetIntent = union(enum) {
    /// **替换音色**（乐器窗口「预设 ▾」）：同一面板——点其它插件 = 顺带换插件；
    /// 层目标 = 只换该层音色（层目前仅减法，UI 已拦鼓组）
    replace: PresetTarget,
    /// 机架「＋ 添加乐器」：选中即新建
    create_instrument,
    /// 机架右键「更换乐器」：选中即换（保留乐器属性）
    change_instrument: i32,
    /// 鼓组垫「＋ 添加乐器」：选中即在垫上加一个该插件的乐器
    create_kit_layer: KitPadRef,

    /// 鼓垫引用（乐器槽位 + 垫音高）
    pub const KitPadRef = struct { instrument: i32, pitch: u8 };
};

/// 面板里选中的条目：置顶默认伪预设 / 第 N 个预设文件
pub const PresetChoice = union(enum) { default, preset: usize };

/// 预设“保存为…”的**源**：参数槽（乐器本体/鼓组层）或**整组套鼓**
pub const PresetSaveSource = union(enum) {
    params: PresetTarget,
    /// 整组套鼓（乐器槽位；plugin = drumkit）
    kit: i32,
};

/// 帧末执行的预设操作（文件 IO 需 io——main 消费；分类/名字用库内索引，
/// 不持有字符串所有权）
pub const PresetAction = union(enum) {
    /// 重新扫描 `data/presets/`
    scan,
    /// 加载（按意图落点）
    load: struct { intent: PresetIntent, cat: usize, choice: PresetChoice },
    /// 把指定源存为新预设（名字为原文；main 清洗后落盘）；
    /// `overwrite` = 同名时直接替换（预填名 + 回车 → 覆写确认后重排）
    save: struct {
        source: PresetSaveSource,
        name_buf: [preset_mod.max_name_len]u8,
        name_len: usize,
        overwrite: bool = false,
    },
    /// 重命名预设文件（同分类内；旧/新名都带干净副本）
    rename: struct {
        cat: usize,
        old_buf: [preset_mod.max_name_len]u8,
        old_len: usize,
        new_buf: [preset_mod.max_name_len]u8,
        new_len: usize,
    },
    /// 删除预设文件
    delete: struct {
        cat: usize,
        name_buf: [preset_mod.max_name_len]u8,
        name_len: usize,
    },
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
pub const ModalKind = enum {
    /// 脏确认（保存/不保存/取消——退出或打开其它工程前）
    dirty_confirm,
    /// 预设重名 → 是否覆写（覆写/取消）
    preset_overwrite,
    /// 删除预设 → 确认（删除/取消）
    preset_delete,
};

/// 待确认的覆写保存请求（确认后重新排队；取消即丢弃）
pub const OverwriteReq = struct {
    source: PresetSaveSource,
    name: [preset_mod.max_name_len]u8 = undefined,
    name_len: usize = 0,
};

/// 待确认的预设删除请求（确认后重新排队；取消即丢弃）
pub const DeleteReq = struct {
    cat: usize = 0,
    name: [preset_mod.max_name_len]u8 = undefined,
    name_len: usize = 0,
};

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

    // ── 中键拖动平移视口（抓画布：内容跟手）──
    nav_active: bool = false,
    nav_mx: i32 = 0,
    nav_my: i32 = 0,
    nav_scroll_x0: i32 = 0,
    nav_scroll_y0: i32 = 0,

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
/// 钢琴卷帘键列模式（**每乐器独立**、随工程保存；定义在 `model`）
pub const KeyMode = model.KeyMode;

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

    // ── 中键拖动平移视口（音符网格区；抓画布：内容跟手）──
    nav_active: bool = false,
    nav_mx: i32 = 0,
    nav_my: i32 = 0,
    nav_scroll_x0: i32 = 0,
    nav_scroll_y0: i32 = 0,

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

    // ── 力度/声像编辑轨（钢琴卷帘底部；见 `docs/note-lane.md`）──
    /// 编辑轨高度（像素；**0 = 未初始化**——首帧按内容 12% 初始化）
    lane_h: i32 = 0,
    /// 编辑模式：力度 / 声像
    lane_mode: NoteLaneMode = .velocity,
    /// 拖动中：上次刷过的鼠标 x（扫刷插值用；-1 = 未刷）
    lane_last_x: i32 = -1,
    /// 画笔范围（**按下瞬间**判定）：true = 只编辑选中的柱条；
    /// false = 自由刷。不能用“实时选区”——点未选中柱条会先清选区单选它，
    /// 若据此限制则从柱条起笔画曲线会失效（只刷那一根）。
    lane_paint_selected_only: bool = false,
    /// 拖动中：上次刷过的值（扫刷去重用；-1 = 未刷）
    lane_last_val: i32 = -1,
    /// 本次拖动是否已改动
    lane_drag_dirty: bool = false,
};

/// 编辑轨模式（力度 / 声像）
pub const NoteLaneMode = enum { velocity, pan };

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

    // ── 右键菜单 ──
    /// 右键菜单中的乐器（重命名/更换/删除用；null = 未展开）
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

    /// 循环区域（**SONG 语义**：全局步；与 `song_step` 同坐标）：null = 未设置
    loop_song: ?[2]i32 = null,
    /// 循环区域（**PAT 语义**：当前样式的局部步；与 `piano_step` 同坐标）：null = 未设置
    loop_pat: ?[2]i32 = null,
    /// 循环标尺拖动：起点（步）——null = 未在拖动
    loop_drag_from: ?i32 = null,
    /// 循环标尺拖动：按下时的鼠标 x（区分“Ctrl+单击 = 取消”与“Ctrl+拖动 = 设置”）
    loop_drag_press_x: i32 = 0,
    /// 循环标尺拖动：是否已移动（超过死区）
    loop_drag_moved: bool = false,

    /// 当前显示的游标位置（步）
    pub fn cursorStep(self: *const Playback, song_mode: bool) i32 {
        return if (song_mode) self.song_step else self.piano_step;
    }
};

/// 文本输入（就地重命名：乐器名 / 调音台通道名）
///
/// 输入字符经 WM_CHAR 到达（含中文 IME 上屏——Unicode 窗口下
/// `WM_IME_CHAR == WM_CHAR`，组合过程由系统 IME 自己显示；emoji 等
/// 代理对字符已在 window.zig 过滤）。
///
/// 交互：字符追加；退格删末尾一个 code point；回车 = 提交；ESC = 取消；
/// 点击输入框外 = 提交（吞掉该次点击）。
pub const TextInput = struct {
    pub const Target = enum { instrument, mixer_channel, pattern, preset_name, kit_pad_name, preset_rename };

    active: bool = false,
    target: Target = .instrument,
    /// 目标下标（乐器槽位 / 通道序号 / **鼓垫音高** / **预设分类序号**）
    index: usize = 0,
    /// 目标乐器槽位（`kit_pad_name` 用；音高在 `index`）
    instrument: i32 = -1,
    /// 附加固定载荷（`preset_rename` 的**旧名字**；固定缓冲避免生命周期问题）
    aux_buf: [64]u8 = [_]u8{0} ** 64,
    aux_len: usize = 0,
    /// UTF-8 缓冲（64 字节 ≈ 21 个汉字）
    buf: [64]u8 = [_]u8{0} ** 64,
    len: usize = 0,
    /// 光标位置（**字节偏移**；总是落在 code point 边界上）
    cursor: usize = 0,
    /// 选区锚点（null = 无选区；否则为另一端字节偏移）
    sel_anchor: ?usize = null,
    /// 鼠标拖动选区中（按下且未松手）
    drag_active: bool = false,
    /// 水平滚动偏移（px；`textFieldSyncOffset` 每帧更新）
    view_off: i32 = 0,
    /// 输入框弹出位置（屏幕坐标；由右键菜单激活时快照）
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 160,

    pub fn text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    /// 选区字节区间 `[lo, hi)`（null = 无选区；锚点 == 光标时也视为无选区）。
    /// **防御**：锚点先鉗到 `len` 内——任何路径留下的陈旧锚点都不能让
    /// 渲染（`textField` 用 `text[0..hi]`）越界（实测 bug 的第二道防线）。
    pub fn selection(self: *const TextInput) ?[2]usize {
        const a = @min(self.sel_anchor orelse return null, self.len);
        if (a == self.cursor) return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
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
    /// 样式右键菜单：目标样式序号（null = 未展开）
    ctx_pattern: ?usize = null,
    /// 样式右键菜单位置（**打开时快照**——不跟鼠标跑，否则永远点不到）
    ctx_pat_x: i32 = 0,
    ctx_pat_y: i32 = 0,
};

/// 合成器编辑器（浮动窗口）状态
pub const SynthWindow = struct {
    open: bool = true,
    x: i32 = 340,
    y: i32 = 150,
    w: i32 = 590,
    h: i32 = 430,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 30,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 当前编辑的**目标**（乐器合成器 / 鼓组层）；点击机架/鼓组编辑器设定
    target: PresetTarget = .{ .instrument = 0 },
};

/// 鼓组编辑器（浮动窗口）状态——左音高列表 + 右垫详情（`docs/drumkit.md` §7）
pub const DrumKitWindow = struct {
    open: bool = false,
    x: i32 = 400,
    y: i32 = 150,
    w: i32 = 680,
    h: i32 = 460,
    /// Z 序（见 `RackState.z` 注释）
    z: i32 = 35,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    resize_w0: i32 = 0,
    resize_h0: i32 = 0,
    resize_mx: i32 = 0,
    resize_my: i32 = 0,
    /// 绑定的乐器槽位（打开时设定；删除/类型变→自动关闭）
    instrument: i32 = 0,
    /// 选中垫的音高（-1 = 未选）
    sel_pitch: i32 = -1,
    /// 左音高列表滚动（px）
    scroll: i32 = 0,
    /// 层列表滚动（px）
    layer_scroll: i32 = 0,
    /// 试听按住中的音高（松开 → 释音）
    audition_pitch: ?i32 = null,
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
    /// 自定义名字（UTF-8；`name_len == 0` = 用默认占位名“主通道/通道#N”）。
    /// 定长存储（≤ 32 字节 ≈ 10 个汉字）——避免动态分配的生命周期管理
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    /// 效果器链（**动态**：顺序处理；空列表 = 无效果）
    effects: std.ArrayListUnmanaged(EffectSlot) = .{ .items = &.{}, .capacity = 0 },

    /// 显示名（自定义 → 原名；否则占位）
    pub fn displayName(self: *const MixerChannel, index: usize, buf: []u8) []const u8 {
        if (self.name_len > 0) return self.name[0..self.name_len];
        return defaultChannelName(index, buf);
    }
};

/// 通道默认占位名（写入调用方缓冲）：通道 0 = “主通道”；其余 = “通道#N”
pub fn defaultChannelName(index: usize, buf: []u8) []const u8 {
    if (index == 0) return "主通道";
    return std.fmt.bufPrint(buf, "通道#{d}", .{index}) catch "通道";
}

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
    /// 声像旋钮右键菜单中的通道（恢复默认值用）——null = 未展开
    ctx_pan: ?usize = null,
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
    /// 键盘移动选中音符（Shift/Ctrl+方向键；本帧累加、音符视图消费）
    pending_move: ?MoveReq = null,
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
    /// toast 剩余**纳秒**（main 每帧按实际流逝时间递减）——
    /// 用时间而非帧数：帧率可变（60/120），帧计数会把时长搞乱
    toast_remaining_ns: i64 = 0,
    /// toast 总时长（显示用；3 秒）
    toast_total_ns: i64 = 3_000_000_000,
    /// “文件”菜单展开中
    file_menu_open: bool = false,
    /// “文件”菜单刚打开（帧内标记；用于区分“打开菜单那一下”与“已展开后点按钮关”）。
    /// 帧首由 drawToolbar 清零（`util.menuFrameBegin`）。
    file_menu_just_opened: bool = false,
    /// 待定的文件操作（帧末执行——对话框不能在事件迭代/绘制中弹出）。
    /// null = 无
    pending_file_action: ?FileAction = null,
    /// “文件”按钮位置（绘制时由工具栏写入；主循环用于菜单定位）
    file_menu_x: i32 = 8,
    file_menu_w: i32 = 140,

    // ── 预设库（合成器音色；`data/presets/<插件类型>/`）──
    /// 数据根目录（启动时由 `preset.resolveDataRoot` 解析；相对或绝对路径）
    data_root_buf: [512]u8 = [_]u8{0} ** 512,
    data_root_len: usize = 0,
    /// 预设库（扫描结果；启动/保存后刷新）
    preset_lib: preset_mod.Library = .{},
    /// 预设浏览器弹窗（合成器窗口的“预设 ▾”）
    preset_browser: PresetBrowser = .{},
    /// 预设“保存为…”的源（`beginRenamePreset` 记录；提交时排队）。
    /// 会话态——不随工程保存。
    preset_save_source: PresetSaveSource = .{ .params = .{ .instrument = 0 } },
    /// 帧末执行的预设操作（App 无 io——文件 IO 在 main）
    pending_preset: ?PresetAction = null,

    // ── 模态对话框与脏确认流程 ──
    /// 当前模态框（null = 无）
    modal: ?ModalKind = null,
    /// 模态框的用户选择（鼠标点击 / 键盘 Enter/Esc 均写入这里；
    /// 语义按 `modal` 而定：脏确认 = 保存/不保存/取消；覆写/删除确认 = 确认(.save)/取消）
    modal_choice: ?QuitChoice = null,
    /// 待确认的覆写保存请求（`modal == .preset_overwrite` 时有效；取消即丢弃）
    overwrite_req: ?OverwriteReq = null,
    /// 待确认的删除请求（`modal == .preset_delete` 时有效；取消即丢弃）
    delete_req: ?DeleteReq = null,
    /// 脏确认流程状态（拦截动作 → 确认 → 执行）
    dirty_flow: DirtyFlow = .none,
    /// 脏确认流程的目标动作（quit / open）
    dirty_intent: ?PendingIntent = null,
    /// 待打开的工程路径（用户已在系统对话框选好；等确认框决定后执行）
    pending_open_path: ?[]u8 = null,

    // ── 音频 ──
    params: audio.Params = .{},
    engine: audio.Engine = .{ .params = undefined },
    volume: f32 = 0.75,
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
    /// 文本输入（就地重命名乐器/通道）
    text_input: TextInput = .{},

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
    drumkit_win: DrumKitWindow = .{},
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
        // 优先级：有框选 → 删框选；框选内无音符（本就空）→ 退而删**循环区域内**
        // 的音符（有循环区域时）。
        // 注意：框选为空 = “没有 selected 的音符”；循环区域删除用
        // `selectNotesInRegion*` 的同一套映射（左右视图坐标不同，各自处理）
        var any_selected = false;
        for (self.notes.items) |nt| {
            if (nt.selected) {
                any_selected = true;
                break;
            }
        }
        if (!any_selected) {
            if (self.loopRegion()) |lr| {
                // 选区为空 + 有循环区域 → 选中区域音符后删除（与拖选同一选区语义）
                if (self.sel.song_mode) {
                    self.selectNotesInRegionSong(lr[0], lr[1]);
                } else {
                    self.selectNotesInRegionPat(lr[0], lr[1]);
                }
                // 若区域也没音符 → 下面的循环空转（removed 0，不改 dirty）
            }
        }
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
                .velocity = nt.velocity,
                .pan = nt.pan,
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
                .velocity = cn.velocity,
                .pan = cn.pan,
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

    /// 键盘微调**选中音符**（Shift/Ctrl+方向键 = 半音/网格/八度/小节）。
    /// 实现：以“即时快照”复用拖动版 `moveSelectedNotes`——**钳制语义与拖动
    /// 完全同源**（整组：最左碰 step 0 / 音高碰 0·127 → 全组停）。
    /// 返回是否有变化（无选中 / 钳到不动 → false）。
    pub fn nudgeSelectedNotes(self: *App, d_step: i32, d_pitch: i32) bool {
        self.beginBatchSnap();
        const changed = self.moveSelectedNotes(d_step, d_pitch);
        self.batch_snap.clearRetainingCapacity(); // 非拖动上下文：用完即清
        return changed;
    }

    /// 键盘**粗移**（Ctrl：八度/小节）——**全有或全无**（用户约定）：
    /// 整组位移必须 100% 可行（不越 step 0 / 音高 0·127），否则**一律不动**。
    /// 理由：部分钳制会让拍位（如“第一小节第三拍”被部分左移变成第一拍）
    /// 或音高级数（八度变非整八度）漂移，破坏强弱拍律动与调内级数。
    /// 返回是否有变化。
    pub fn nudgeSelectedNotesExact(self: *App, d_step: i32, d_pitch: i32) bool {
        if (d_step == 0 and d_pitch == 0) return false;
        var min_pitch: i32 = std.math.maxInt(i32);
        var max_pitch: i32 = std.math.minInt(i32);
        var min_step: i32 = std.math.maxInt(i32);
        var n: usize = 0;
        for (self.notes.items) |nt| {
            if (!nt.selected) continue;
            min_pitch = @min(min_pitch, nt.pitch);
            max_pitch = @max(max_pitch, nt.pitch);
            min_step = @min(min_step, nt.step);
            n += 1;
        }
        if (n == 0) return false;
        if (min_step + d_step < 0) return false; // 左移抭不动 → 整组拒
        if (min_pitch + d_pitch < 0 or max_pitch + d_pitch > 127) return false; // 音高越界 → 整组拒
        for (self.notes.items) |*nt| {
            if (!nt.selected) continue;
            nt.step += d_step;
            nt.pitch += d_pitch;
        }
        self.dirty = true;
        return true;
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

    /// 合成器参数指针进**退役列表**（音频线程可能仍持有它——异步读取；
    /// 不立即 free：流程退出时统一释放。分配失败时宁可不记录也不 free——
    /// 泄漏优于 use-after-free）
    fn retireSynth(self: *App, sp: *synth.SynthParams) void {
        self.retired_synths.append(self.allocator, sp) catch {};
    }

    /// 释放鼓垫内容（层参数进退役、名字/预设名释放；不含 pad 自身）
    fn deinitPadContents(self: *App, pad: *model.DrumPad) void {
        for (pad.layers.items) |ly| {
            self.retireSynth(ly.params);
            self.allocator.free(ly.source_preset);
        }
        pad.layers.deinit(self.allocator);
        self.allocator.free(pad.name);
    }

    /// 释放鼓组全部内容 + 本体
    fn deinitDrumKit(self: *App, kit: *model.DrumKit) void {
        for (kit.pads.items) |*pad| self.deinitPadContents(pad);
        kit.pads.deinit(self.allocator);
        self.allocator.destroy(kit);
    }

    /// 导出单个乐器为存档（深拷贝：名字/鼓组/合成器参数——供历史快照与工程保存共用）
    fn exportInstrument(self: *App, inst: *const model.Instrument) !persist.SavedInstrument {
        var si = persist.SavedInstrument{
            .name = try self.allocator.dupe(u8, inst.name),
            .volume = inst.volume,
            .pan = inst.pan,
            .muted = inst.muted,
            .mixer = inst.mixer,
            .midi_channel = inst.midi_channel,
            .kind = @intFromEnum(inst.kind),
            .key_mode = @intFromEnum(inst.key_mode),
            .synth = persist.exportSynth(inst.synth),
        };
        errdefer self.allocator.free(si.name);
        si.preset_name = try self.allocator.dupe(u8, inst.preset_name);
        errdefer self.allocator.free(si.preset_name);
        if (inst.kit) |kit| si.kit = try self.exportDrumKit(kit);
        return si;
    }

    fn exportDrumKit(self: *App, kit: *const model.DrumKit) !persist.SavedDrumKit {
        const pads = try self.allocator.alloc(persist.SavedDrumPad, kit.pads.items.len);
        var np: usize = 0;
        errdefer {
            for (pads[0..np]) |p| {
                for (p.layers) |ly| self.allocator.free(ly.source_preset);
                self.allocator.free(p.layers);
                self.allocator.free(p.name);
            }
            self.allocator.free(pads);
        }
        for (kit.pads.items, 0..) |pad, i| {
            const layers = try self.allocator.alloc(persist.SavedDrumLayer, pad.layers.items.len);
            var nl: usize = 0;
            errdefer {
                for (layers[0..nl]) |ly| self.allocator.free(ly.source_preset);
                self.allocator.free(layers);
            }
            for (pad.layers.items, 0..) |layer, li| {
                layers[li] = .{
                    .kind = @intFromEnum(layer.kind),
                    .synth = persist.exportSynth(layer.params),
                    .gain = layer.gain,
                    .source_preset = try self.allocator.dupe(u8, layer.source_preset),
                };
                nl += 1;
            }
            pads[i] = .{
                .pitch = pad.pitch,
                .name = try self.allocator.dupe(u8, pad.name),
                .layers = layers,
            };
            np += 1;
        }
        return .{ .pads = pads };
    }

    /// 释放存档乐器（与 `exportInstrument` 对称；历史快照/工程释放共用）
    fn freeSavedInstrument(self: *App, si: *const persist.SavedInstrument) void {
        self.allocator.free(si.name);
        self.allocator.free(si.preset_name);
        self.freeSavedKit(&si.kit);
    }

    /// 释放套鼓快照（导出/保存路径用；与 `exportDrumKit` 对称）
    pub fn freeSavedKit(self: *App, sk: *const persist.SavedDrumKit) void {
        for (sk.pads) |pad| {
            self.allocator.free(pad.name);
            for (pad.layers) |ly| self.allocator.free(ly.source_preset);
            self.allocator.free(pad.layers);
        }
        self.allocator.free(sk.pads);
    }

    /// 导出整组套鼓快照（深拷贝；调用方用 `freeSavedKit` 释放）；
    /// 非鼓组/越界/分配失败 → null
    pub fn exportKitForSave(self: *App, idx: usize) ?persist.SavedDrumKit {
        if (idx >= self.instruments.items.len) return null;
        const kit = self.instruments.items[idx].kit orelse return null;
        return self.exportDrumKit(kit) catch null;
    }

    /// 把套鼓快照载入乐器（**替换**现有套鼓内容；非鼓组也允许——先建空 kit）。
    /// 一条历史的调用方负责提交。返回是否成功。
    pub fn loadKitInto(self: *App, idx: usize, sk: *const persist.SavedDrumKit) bool {
        if (idx >= self.instruments.items.len) return false;
        const inst = &self.instruments.items[idx];
        if (inst.kit == null) {
            const kit = self.allocator.create(model.DrumKit) catch return false;
            kit.* = .{};
            inst.kit = kit;
        }
        self.importDrumKit(sk, inst.kit.?);
        self.dirty = true;
        return true;
    }

    /// 把存档鼓组恢复到 `kit`（清空重建；失败时尽量保留已恢复部分——
    /// 宁可部分丢也不 use-after-free）
    fn importDrumKit(self: *App, sk: *const persist.SavedDrumKit, kit: *model.DrumKit) void {
        for (kit.pads.items) |*pad| self.deinitPadContents(pad);
        kit.pads.clearRetainingCapacity();
        for (sk.pads) |sp| {
            var pad = model.DrumPad{
                .pitch = @intCast(@min(sp.pitch, 127)),
                .name = self.allocator.dupe(u8, sp.name) catch continue,
            };
            for (sp.layers) |sl| {
                const lp = self.allocator.create(synth.SynthParams) catch continue;
                lp.* = .{};
                persist.importSynth(&sl.synth, lp);
                const src: []u8 = self.allocator.dupe(u8, sl.source_preset) catch &.{};
                // 未知类型（未来存档）→ 退回减法（现阶段唯一引擎；参数照常载入）
                const kind = std.enums.fromInt(model.LayerKind, sl.kind) orelse model.LayerKind.subtractive;
                pad.layers.append(self.allocator, .{ .kind = kind, .params = lp, .gain = sl.gain, .source_preset = src }) catch {
                    self.retireSynth(lp);
                };
            }
            kit.pads.append(self.allocator, pad) catch {
                self.deinitPadContents(&pad);
            };
        }
        std.mem.sort(model.DrumPad, kit.pads.items, {}, struct {
            fn less(_: void, a: model.DrumPad, b: model.DrumPad) bool {
                return a.pitch < b.pitch;
            }
        }.less);
    }

    /// 把存档乐器恢复到已存在的 `target`（名字除外——由调用方处理；
    /// 历史恢复/工程导入共用，防两处逻辑分叉）
    fn applySavedInstrument(self: *App, si: *const persist.SavedInstrument, target: *model.Instrument) void {
        target.volume = si.volume;
        target.pan = si.pan;
        target.muted = si.muted;
        target.mixer = si.mixer;
        target.midi_channel = si.midi_channel;
        target.key_mode = if (si.key_mode == 1) .drum else .piano;
        // 关联预设名（快照往返：撤销/重做也能回到当时的名字）
        if (!std.mem.eql(u8, target.preset_name, si.preset_name)) {
            if (self.allocator.dupe(u8, si.preset_name)) |d| {
                self.allocator.free(target.preset_name);
                target.preset_name = d;
            } else |_| {}
        }
        persist.importSynth(&si.synth, target.synth);
        if (si.kind == 1) {
            // 鼓组：确保 kit 存在并重建内容
            if (target.kit == null) {
                const kit = self.allocator.create(model.DrumKit) catch return;
                kit.* = .{};
                target.kit = kit;
            }
            self.importDrumKit(&si.kit, target.kit.?);
            target.kind = .drumkit;
        } else {
            if (target.kit) |kit| {
                self.deinitDrumKit(kit);
                target.kit = null;
            }
            target.kind = .synth;
        }
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

        const pname = self.allocator.dupe(u8, "") catch {
            self.allocator.free(name);
            self.allocator.destroy(sp);
            return -1;
        };
        self.instruments.append(self.allocator, .{
            .name = name,
            .preset_name = pname,
            .synth = sp,
        }) catch {
            self.allocator.free(name);
            self.allocator.free(pname);
            self.allocator.destroy(sp);
            return -1;
        };
        self.dirty = true;
        return @intCast(self.instruments.items.len - 1);
    }

    /// 添加鼓组乐器（kind = drumkit + 空 kit）
    pub fn addDrumkit(self: *App, base_name: []const u8) i32 {
        const idx = self.addInstrument(base_name);
        if (idx < 0) return -1;
        const inst = &self.instruments.items[@intCast(idx)];
        const kit = self.allocator.create(model.DrumKit) catch return idx;
        kit.* = .{};
        inst.kit = kit;
        inst.kind = .drumkit;
        inst.key_mode = .drum; // 鼓组默认键列就是鼓名（用户可切回）
        return idx;
    }

    /// 当前选中乐器的键列模式（**每乐器独立**；无乐器 → 钢琴）
    pub fn currentKeyMode(self: *const App) KeyMode {
        const i = self.sel.instrument;
        if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) return .piano;
        return self.instruments.items[@intCast(i)].key_mode;
    }

    /// 设置当前选中乐器的键列模式（无乐器时无操作；会话态，不入历史）
    pub fn setCurrentKeyMode(self: *App, m: KeyMode) void {
        const i = self.sel.instrument;
        if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) return;
        self.instruments.items[@intCast(i)].key_mode = m;
    }

    // ── 鼓组编辑（鼓组编辑器用；每个操作后由调用方 commitHistory）──

    /// 找或建垫（升序插入）；无乐器/非鼓组 → null
    pub fn kitPadEnsure(self: *App, inst_idx: i32, pitch: u8) ?*model.DrumPad {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit = inst.kit orelse return null;
        if (kit.find(pitch)) |pad| return pad;
        const pad = model.DrumPad{
            .pitch = pitch,
            .name = self.allocator.dupe(u8, "") catch return null,
        };
        kit.pads.append(self.allocator, pad) catch {
            self.allocator.free(pad.name);
            return null;
        };
        // 升序插入（刚 append 的可能是乱序 → 冒泡到位置）
        var i: usize = kit.pads.items.len - 1;
        while (i > 0 and kit.pads.items[i - 1].pitch > kit.pads.items[i].pitch) : (i -= 1) {
            std.mem.swap(model.DrumPad, &kit.pads.items[i - 1], &kit.pads.items[i]);
        }
        self.dirty = true;
        return &kit.pads.items[i];
    }

    /// 删除垫（含其层；层参数进退役）
    pub fn kitPadRemove(self: *App, inst_idx: i32, pitch: u8) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit = inst.kit orelse return false;
        for (kit.pads.items, 0..) |*pad, i| {
            if (pad.pitch != pitch) continue;
            self.deinitPadContents(pad);
            _ = kit.pads.orderedRemove(i);
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// 给垫加一层（从预设副本或空层）。`saved` = 层参数（null = 默认空音色）。
    /// `source` = 来源预设名（`分类/名字`；空 = 手调）。返回 false = 失败。
    /// 注：上限是**全组总层数**（音频侧槽位数 `audio.kit_max_layers`）——
    /// 一个垫的多层占多个槽位。
    pub fn kitLayerAdd(self: *App, inst_idx: i32, pitch: u8, saved: ?*const persist.SavedSynth, source: []const u8) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit0 = inst.kit orelse return false;
        if (kit0.totalLayers() >= @import("audio.zig").kit_max_layers) return false;
        const pad = self.kitPadEnsure(inst_idx, pitch) orelse return false;
        const lp = self.allocator.create(synth.SynthParams) catch return false;
        lp.* = .{};
        if (saved) |s| persist.importSynth(s, lp);
        const src: []u8 = self.allocator.dupe(u8, source) catch &.{};
        pad.layers.append(self.allocator, .{ .params = lp, .gain = 1.0, .source_preset = src }) catch {
            self.retireSynth(lp);
            return false;
        };
        self.dirty = true;
        return true;
    }

    /// 清空后的**无名空垫**清理：无层且无名 = 无信息可保留 → 移除
    /// （有名空垫保留——名字是用户信息；用户反馈：清空层后不应留“幽灵垫”）。
    /// 返回是否清理了。可撤销（快照含垫本身）。
    fn pruneEmptyPad(self: *App, kit: *model.DrumKit, pitch: u8) bool {
        var i: usize = 0;
        while (i < kit.pads.items.len) : (i += 1) {
            const pp = &kit.pads.items[i];
            if (pp.pitch != pitch) continue;
            if (pp.layers.items.len != 0 or pp.name.len != 0) return false;
            self.deinitPadContents(pp);
            _ = kit.pads.orderedRemove(i);
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// 删除垫的第 `layer_idx` 层（参数进退役）；`layer_idx` 越界 → false
    pub fn kitLayerRemove(self: *App, inst_idx: i32, pitch: u8, layer_idx: usize) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit = inst.kit orelse return false;
        const pad = kit.find(pitch) orelse return false;
        if (layer_idx >= pad.layers.items.len) return false;
        const ly = pad.layers.orderedRemove(layer_idx);
        self.retireSynth(ly.params);
        self.allocator.free(ly.source_preset);
        // 清空后的无名空垫一并移除（见 pruneEmptyPad）
        _ = self.pruneEmptyPad(kit, pitch);
        self.dirty = true;
        return true;
    }

    /// 删除乐器槽位（同时删除其音符；合成器参数延迟释放；其余音符的槽位序号前移）
    pub fn removeInstrument(self: *App, idx: usize) void {
        if (idx >= self.instruments.items.len) return;
        self.dirty = true;
        const inst = self.instruments.items[idx];
        self.allocator.free(inst.name); // 名字只被 UI 线程使用，可立即释放
        self.allocator.free(inst.preset_name);
        // 合成器参数：音频线程可能仍持有该指针（异步读取）→ 移入退役列表，进程退出时释放。
        // （分配失败时宁可不记录也不 free——泄漏优于 use-after-free）
        self.retireSynth(inst.synth);
        if (inst.kit) |kit| self.deinitDrumKit(kit); // 鼓组内容同样退役层参数
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
        // 合成器窗口：`.instrument` 目标每帧跟随选择（无需在此修正）；
        // `.kit_layer_replace` 目标由层查找自然失效（窗口自行关闭）
        // 鼓组编辑器：删除的正是绑定乐器 → 关闭；删除在其前 → 索引前移
        if (self.drumkit_win.open) {
            if (self.drumkit_win.instrument == @as(i32, @intCast(idx))) {
                self.drumkit_win.open = false;
            } else if (self.drumkit_win.instrument > @as(i32, @intCast(idx))) {
                self.drumkit_win.instrument -= 1;
            }
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
        self.preset_lib.deinit(self.allocator);
    }

    // ── 预设库（数据根目录 / 扫描结果 / 弹窗状态）──

    /// 设置数据根目录（拷贝；由 main 启动时解析）
    pub fn setDataRoot(self: *App, path: []const u8) void {
        const n = @min(path.len, self.data_root_buf.len);
        @memcpy(self.data_root_buf[0..n], path[0..n]);
        self.data_root_len = n;
    }

    /// 当前数据根目录（相对或绝对路径；空串 = 未设置——预设功能禁用）
    pub fn dataRoot(self: *const App) []const u8 {
        return self.data_root_buf[0..self.data_root_len];
    }

    /// 打开预设面板（统一入口）：`intent` 决定分类可选性与选中后的动作
    pub fn openPresetBrowser(self: *App, intent: PresetIntent) void {
        // 护栏：库不可用（数据目录未就绪/未建分类）→ 面板无从选择，不开
        if (self.preset_lib.categories.items.len == 0) {
            self.setToast("预设库不可用（数据目录未就绪）");
            return;
        }
        const pb = &self.preset_browser;
        pb.open = true;
        pb.just_opened = true;
        pb.intent = intent;
        // 锚插件：replace → 要求的插件；change → 乐器当前插件；其余 → 减法（初始分类）
        pb.plugin = switch (intent) {
            .replace => |t| self.presetTargetPlugin(t),
            .create_instrument, .create_kit_layer => preset_mod.plugin_subtractive,
            .change_instrument => |i| blk: {
                if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) break :blk preset_mod.plugin_subtractive;
                break :blk if (self.instruments.items[@intCast(i)].kind == .drumkit)
                    preset_mod.plugin_drumkit
                else
                    preset_mod.plugin_subtractive;
            },
        };
        // 定位锚插件的分类（找不到 → 0；库可空）
        var idx: usize = 0;
        for (self.preset_lib.categories.items, 0..) |cat, i| {
            if (std.mem.eql(u8, cat.name, pb.plugin)) {
                idx = i;
                break;
            }
        }
        pb.cat = idx;
        pb.scroll = 0;
        pb.ctx = null; // 右键菜单不跨次残留
    }

    /// 该插件是否可作为**乐器本体**（新建/更换/预设面板选中 → 建或换）：
    /// 减法合成器 / 鼓组（已实装）；FM/VST3 将来。
    pub fn pluginSupportedAsInstrument(plugin: []const u8) bool {
        return std.mem.eql(u8, plugin, preset_mod.plugin_subtractive) or
            std.mem.eql(u8, plugin, preset_mod.plugin_drumkit);
    }

    /// 该插件是否可作为**鼓垫层**：目前仅减法（**不含鼓组**——禁自嵌套）。
    pub fn pluginSupportedAsLayer(plugin: []const u8) bool {
        return std.mem.eql(u8, plugin, preset_mod.plugin_subtractive);
    }

    /// 该意图下此分类是否**可选**（否则左栏置灰、点击只提示）：
    /// **面板已统一**——任何入口都能选任意已实装插件（跨插件即换插件）；
    /// 仅两类被拦：未实装插件（FM/VST3）与层上下文的鼓组（禁自嵌套）。
    pub fn presetCategorySelectable(self: *const App, intent: PresetIntent, plugin: []const u8) bool {
        _ = self;
        return switch (intent) {
            .replace => |t| switch (t) {
                .instrument => pluginSupportedAsInstrument(plugin),
                .kit_layer_replace => pluginSupportedAsLayer(plugin),
            },
            .create_instrument, .change_instrument => pluginSupportedAsInstrument(plugin),
            .create_kit_layer => pluginSupportedAsLayer(plugin),
        };
    }

    /// 预设目标所需的插件类型（分类 id）——浏览器的限定依据。
    /// 目前乐器本体（synth）/鼓组层都是减法合成器；鼓组乐器本体留给
    /// 将来的“整组套预设”（`drumkit` 分类，阶段 4）。
    pub fn presetTargetPlugin(self: *const App, target: PresetTarget) []const u8 {
        switch (target) {
            .instrument => |i| {
                if (i >= 0 and i < @as(i32, @intCast(self.instruments.items.len))) {
                    if (self.instruments.items[@intCast(i)].kind == .drumkit) return preset_mod.plugin_drumkit;
                }
                return preset_mod.plugin_subtractive;
            },
            .kit_layer_replace => return preset_mod.plugin_subtractive,
        }
    }

    /// 更换乐器类型（**保留**名字/音量/声像/路由/MIDI 通道）：
    /// synth→鼓组 = 建空套鼓 + 键列模式切鼓组；鼓组→synth = 释放鼓组层
    /// （层参数入退役）。`commit` = 是否立即提交历史
    /// （预设面板“更换乐器”要“换类型+载音色”一条历史 → 传 false，调用方合并提交）。
    /// 返回是否发生了更换。
    pub fn changeInstrumentKind(self: *App, idx: usize, kind: model.InstrumentKind, commit: bool) bool {
        if (idx >= self.instruments.items.len) return false;
        const inst = &self.instruments.items[idx];
        if (inst.kind == kind) return false;
        switch (kind) {
            .synth => {
                if (inst.kit) |kit| {
                    self.deinitDrumKit(kit); // 层参数入退役
                    inst.kit = null;
                }
                inst.kind = .synth;
                inst.key_mode = .piano; // 键列模式随类型回默认（与下方 .drumkit 对称）
            },
            .drumkit => {
                if (inst.kit == null) {
                    const kit = self.allocator.create(model.DrumKit) catch return false;
                    kit.* = .{};
                    inst.kit = kit;
                }
                inst.kind = .drumkit;
                inst.key_mode = .drum;
            },
        }
        self.dirty = true;
        if (commit) self.commitHistory("更换乐器");
        return true;
    }

    /// 开始“保存为…”命名（`source` = 保存源；`prefill` = 预填名——通常为当前关联
    /// 的预设名，直接回车 = 覆写确认流程；预填**全选**，直接输入即替换）
    pub fn beginRenamePreset(self: *App, x: i32, y: i32, source: PresetSaveSource, prefill: []const u8) void {
        self.preset_save_source = source;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .preset_name;
        ti.index = 0;
        ti.x = x;
        ti.y = y;
        ti.len = @min(prefill.len, ti.buf.len);
        @memcpy(ti.buf[0..ti.len], prefill[0..ti.len]);
        ti.cursor = ti.len;
        ti.sel_anchor = if (ti.len > 0) 0 else null; // 预填 → 全选（输入即替换）
        ti.drag_active = false;
        ti.view_off = 0;
    }

    /// 保存遇到重名 → 弹“是否覆写”确认框（暂存请求；确认后重新排队保存，
    /// 取消即丢弃）。`clean_name` = 已清洗后的名字（与碰重的那份一致）。
    pub fn setOverwritePrompt(self: *App, source: PresetSaveSource, clean_name: []const u8) void {
        var req = OverwriteReq{ .source = source };
        const n = @min(clean_name.len, req.name.len);
        @memcpy(req.name[0..n], clean_name[0..n]);
        req.name_len = n;
        self.overwrite_req = req;
        self.modal = .preset_overwrite;
        self.modal_choice = null;
    }

    /// 删除预设 → 弹“确认删除”模态（确认后重新排队删除，取消即丢弃）。
    /// 注：文件操作**不进操作历史**（历史 = 工程编辑；预设库是外部资源，
    /// 与“打开/保存工程”同类；误删防护 = 确认框 + 副本语义）。
    pub fn setDeletePrompt(self: *App, cat: usize, name: []const u8) void {
        var req = DeleteReq{ .cat = cat };
        const n = @min(name.len, req.name.len);
        @memcpy(req.name[0..n], name[0..n]);
        req.name_len = n;
        self.delete_req = req;
        self.modal = .preset_delete;
        self.modal_choice = null;
    }

    /// 开始重命名预设文件（文本输入；预填旧名 + 全选；`cat` 存 `index`，
    /// 旧名存 `aux_buf`）
    pub fn beginRenamePresetFile(self: *App, cat: usize, name_idx: usize, x: i32, y: i32) void {
        if (cat >= self.preset_lib.categories.items.len) return;
        const c = &self.preset_lib.categories.items[cat];
        if (name_idx >= c.presets.items.len) return;
        const old = c.presets.items[name_idx];
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .preset_rename;
        ti.index = cat;
        ti.x = x;
        ti.y = y;
        ti.w = 160;
        const n = @min(old.len, ti.buf.len);
        @memcpy(ti.buf[0..n], old[0..n]);
        ti.len = n;
        ti.cursor = n;
        ti.sel_anchor = if (n > 0) 0 else null; // 全选（输入即替换）
        ti.drag_active = false;
        ti.view_off = 0;
        ti.aux_len = @min(old.len, ti.aux_buf.len);
        @memcpy(ti.aux_buf[0..ti.aux_len], old[0..ti.aux_len]);
    }

    /// 设置乐器的“关联预设名”（加载/保存预设时维护；展示/预填用）
    pub fn setInstrumentPresetName(self: *App, idx: usize, name: []const u8) bool {
        if (idx >= self.instruments.items.len) return false;
        const inst = &self.instruments.items[idx];
        if (std.mem.eql(u8, inst.preset_name, name)) return false;
        const dup = self.allocator.dupe(u8, name) catch return false;
        self.allocator.free(inst.preset_name);
        inst.preset_name = dup;
        return true;
    }

    /// 乐器的关联预设名（越界 → ""）
    pub fn instrumentPresetName(self: *const App, idx: i32) []const u8 {
        if (idx < 0 or idx >= @as(i32, @intCast(self.instruments.items.len))) return "";
        return self.instruments.items[@intCast(idx)].preset_name;
    }

    /// 鼓组层的来源预设串（`分类/名字`；空 = 手调/无）
    pub fn kitLayerSource(self: *const App, inst_idx: i32, pitch: u8, layer: usize) []const u8 {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return "";
        const kit = self.instruments.items[@intCast(inst_idx)].kit orelse return "";
        const pad = kit.find(pitch) orelse return "";
        if (layer >= pad.layers.items.len) return "";
        return pad.layers.items[layer].source_preset;
    }

    /// 保存对话框的预填名（= 当前关联的预设名；层目标取来源串的名字部分）
    pub fn presetPrefillName(self: *const App, source: PresetSaveSource) []const u8 {
        return switch (source) {
            .params => |t| switch (t) {
                .instrument => |i| self.instrumentPresetName(i),
                .kit_layer_replace => |ref| preset_mod.nameFromSource(self.kitLayerSource(ref.instrument, ref.pitch, ref.layer)),
            },
            .kit => |i| self.instrumentPresetName(i),
        };
    }

    /// 释放全部乐器（名字 + 合成器参数，含退役的）——进程退出时调用
    pub fn deinitInstruments(self: *App) void {
        for (self.instruments.items) |inst| {
            self.allocator.free(inst.name);
            self.allocator.free(inst.preset_name);
            self.allocator.destroy(inst.synth);
            // 鼓组内容（垫/层）：层参数进退役列表，由下面的统一释放处理
            if (inst.kit) |kit| self.deinitDrumKit(kit);
        }
        self.instruments.deinit(self.allocator);
        for (self.retired_synths.items) |sp| self.allocator.destroy(sp);
        self.retired_synths.deinit(self.allocator);
    }

    /// 当前选中乐器的合成器参数（无乐器 / **鼓组** → null——合成器窗口自动隐藏）
    pub fn selectedSynth(self: *App) ?*synth.SynthParams {
        if (self.sel.instrument < 0 or self.sel.instrument >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const inst = &self.instruments.items[@intCast(self.sel.instrument)];
        if (inst.kind == .drumkit) return null;
        return inst.synth;
    }

    // ── 鼓组编辑（编辑器窗口 + 合成器窗口的层目标）──

    /// 打开鼓组编辑器（绑定乐器；非鼓组/越界 → 无操作）。
    /// 自动选中**第一个已映射垫**（无 → 36 = GM 底鼓），并同步选择（试听路由）。
    pub fn openDrumKit(self: *App, idx: i32) void {
        if (idx < 0 or idx >= @as(i32, @intCast(self.instruments.items.len))) return;
        const inst = &self.instruments.items[@intCast(idx)];
        if (inst.kind != .drumkit) return;
        const dw = &self.drumkit_win;
        dw.open = true;
        dw.instrument = idx;
        dw.sel_pitch = if (inst.kit) |k|
            (if (k.pads.items.len > 0) @as(i32, k.pads.items[0].pitch) else 36)
        else
            36;
        dw.scroll = 0;
        dw.layer_scroll = 0;
        dw.audition_pitch = null;
        self.sel.instrument = idx; // 试听/键列跟随
        self.bringToFront(&dw.z);
    }

    /// 鼓组编辑器绑定的鼓组（乐器被删/类型变更 → null；调用方应关闭窗口）
    pub fn drumKitWindowKit(self: *App) ?*model.DrumKit {
        const i = self.drumkit_win.instrument;
        if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const inst = &self.instruments.items[@intCast(i)];
        if (inst.kind != .drumkit) return null;
        return inst.kit;
    }

    /// 解析预设目标 → 参数指针（无效 → null）
    pub fn resolvePresetTarget(self: *App, target: PresetTarget) ?*synth.SynthParams {
        return switch (target) {
            .instrument => |i| blk: {
                if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) break :blk null;
                const inst = &self.instruments.items[@intCast(i)];
                if (inst.kind == .drumkit) break :blk null; // 鼓组没有可编辑的本体合成器
                break :blk inst.synth;
            },
            .kit_layer_replace => |ref| self.kitLayerParams(ref.instrument, ref.pitch, ref.layer),
        };
    }

    /// 取鼓组层参数（乐器/垫/层任一无效 → null）
    pub fn kitLayerParams(self: *App, inst_idx: i32, pitch: u8, layer: usize) ?*synth.SynthParams {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit = inst.kit orelse return null;
        const pad = kit.find(pitch) orelse return null;
        if (layer >= pad.layers.items.len) return null;
        return pad.layers.items[layer].params;
    }

    /// 更新鼓组层的来源预设名（展示用）；返回是否改动
    pub fn kitLayerSetSource(self: *App, inst_idx: i32, pitch: u8, layer: usize, src: []const u8) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit = inst.kit orelse return false;
        const pad = kit.find(pitch) orelse return false;
        if (layer >= pad.layers.items.len) return false;
        const ly = &pad.layers.items[layer];
        if (std.mem.eql(u8, ly.source_preset, src)) return false;
        const copy = self.allocator.dupe(u8, src) catch return false;
        self.allocator.free(ly.source_preset);
        ly.source_preset = copy;
        self.dirty = true;
        return true;
    }

    /// 重命名鼓垫（空名 = 清除自定义名，回退 GM/音名）；返回是否改动
    /// 重命名鼓垫（空名 = 清除自定义名，回退 GM/音名）；返回是否改动。
    /// 清成空名且无层 → 垫本身也没信息，一并清理（见 pruneEmptyPad）
    pub fn kitPadRename(self: *App, inst_idx: i32, pitch: u8, name: []const u8) bool {
        const pad = self.kitPadEnsure(inst_idx, pitch) orelse return false;
        if (std.mem.eql(u8, pad.name, name)) return false;
        const copy = self.allocator.dupe(u8, name) catch return false;
        self.allocator.free(pad.name);
        pad.name = copy;
        if (name.len == 0) {
            const kit = self.instruments.items[@intCast(inst_idx)].kit.?;
            _ = self.pruneEmptyPad(kit, pitch);
        }
        self.commitHistory("重命名鼓垫");
        return true;
    }

    /// 开始重命名鼓垫（文本输入；预填当前自定义名）
    pub fn beginRenameKitPad(self: *App, inst_idx: i32, pitch: u8, x: i32, y: i32) void {
        const pad = self.kitPadEnsure(inst_idx, pitch) orelse return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .kit_pad_name;
        ti.instrument = inst_idx;
        ti.index = pitch;
        ti.x = x;
        ti.y = y;
        ti.w = 160;
        ti.len = @min(pad.name.len, ti.buf.len);
        @memcpy(ti.buf[0..ti.len], pad.name[0..ti.len]);
        ti.cursor = ti.len;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.view_off = 0;
    }

    /// 标记脏（任何编辑操作调用）
    pub fn markDirty(self: *App) void {
        self.dirty = true;
    }

    /// 滚轮类操作的 coalesce：设置待提交名 + 记录本次变动时间。
    /// （滚轮无“松开”事件——用**静默间隔**判定：见 `pollWheelHistory`）
    /// 标记“连续微调”的 pending 历史（滚轮调值 / 键盘连按移动音符共用）：
    /// 帧末 `pollWheelHistory` 静默 ≥ 0.6s 后合并提交**一条**。
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
        for (st.instruments) |*si| self.freeSavedInstrument(si);
        self.allocator.free(st.instruments);
        for (st.pattern_names) |nm| self.allocator.free(nm);
        self.allocator.free(st.pattern_names);
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
            // 自定义名字（空 = 无；dupe 供快照/存档独立存活）
            if (mc.name_len > 0) {
                sm.name = try allocator.dupe(u8, mc.name[0..mc.name_len]);
            }
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
            // 自定义名字（空 = 无）
            {
                const mc = &self.mixer_channels_state.items[i];
                const n = @min(sm.name.len, mc.name.len);
                @memcpy(mc.name[0..n], sm.name[0..n]);
                mc.name_len = n;
            }
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
            for (insts[0..n]) |*si| self.freeSavedInstrument(si);
            self.allocator.free(insts);
        }
        for (self.instruments.items, 0..) |*inst, i| {
            insts[i] = try self.exportInstrument(inst);
            n += 1;
        }
        const mixer = try self.exportMixerChannels(self.allocator);
        errdefer {
            // 后续分配失败时释放（新增 pat_names 带来的失败路径；原代码无后续分配）
            self.freeSavedMixerChannels(mixer);
            self.allocator.free(mixer);
        }
        const pat_names = try self.allocator.alloc([]u8, self.pattern_items.items.len);
        var pn: usize = 0;
        errdefer {
            for (pat_names[0..pn]) |nm| self.allocator.free(nm);
            self.allocator.free(pat_names);
        }
        for (self.pattern_items.items, 0..) |nm, i| {
            pat_names[i] = try self.allocator.dupe(u8, nm);
            pn += 1;
        }
        return .{
            .label = label_copy,
            .notes = notes,
            .clips = clips,
            .instruments = insts,
            .mixer = mixer,
            .pattern_names = pat_names,
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
            // 力度/声像也要比较——否则改力度被判为“无变化”，静默丢弃历史条目
            // （与 ADSR 同一个坑：调了值但不产生历史）
            if (a.velocity != b.velocity or a.pan != b.pan) return false;
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
            if (!std.mem.eql(u8, a.preset_name, b.preset_name)) return false; // 关联预设名（否则加载同名同参预设会被判“无变化”）
            // 乐器类型/鼓组内容也要比较（否则鼓组编辑被判“无变化”）
            if (a.kind != @intFromEnum(b.kind)) return false;
            if (a.kit.pads.len != (if (b.kit) |k| k.pads.items.len else 0)) return false;
            if (b.kit) |k| {
                for (a.kit.pads, k.pads.items) |sa, ba| {
                    if (sa.pitch != ba.pitch) return false;
                    if (!std.mem.eql(u8, sa.name, ba.name)) return false;
                    if (sa.layers.len != ba.layers.items.len) return false;
                    for (sa.layers, ba.layers.items) |sl, bl| {
                        if (sl.gain != bl.gain) return false;
                        if (!std.mem.eql(u8, sl.source_preset, bl.source_preset)) return false;
                        const cur = persist.exportSynth(bl.params);
                        if (!std.meta.eql(sl.synth, cur)) return false;
                    }
                }
            }
            // **合成器参数也要比较**——否则 ADSR/滤波等改动会被判为“无变化”，
            // 静默丢弃历史条目（实测 bug：调 ADSR 不产生历史）
            const cur = persist.exportSynth(b.synth);
            if (!std.meta.eql(a.synth, cur)) return false;
        }
        if (st.bpm != self.bpm or st.time_num != self.time_num or st.time_den != self.time_den) return false;
        // 样式名字（数量 + 内容）——否则重命名会被判“无变化”，静默丢弃历史条目
        if (st.pattern_names.len != self.pattern_items.items.len) return false;
        for (st.pattern_names, self.pattern_items.items) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        // 调音台通道（数量/增益/声像/静音/效果链）——否则“添加通道/效果器”会被判无变化
        if (st.mixer.len != self.mixer_channels_state.items.len) return false;
        for (st.mixer, self.mixer_channels_state.items) |a, b| {
            if (a.volume != b.volume or a.pan != b.pan or a.muted != b.muted) return false;
            // 通道名也要比较——否则重命名被判为“无变化”，静默丢弃历史条目
            if (!std.mem.eql(u8, a.name, b.name[0..b.name_len])) return false;
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
        // 播放中：**仅当音符/片段真的变化**才重扫调度窗口。
        // EQ/通道音量/声像等编辑不改变调度事件（事件只带时间/力度/声像/
        // 乐器），重扫纯属浪费且有害——它会重发游标附近的事件，音频对
        // “已过时”事件立即触发 → 重发已在响的 on = 双声部（单个 off 只
        // 释放一个）→ 个别音悬挂（实测 bug：播放中调 EQ 概率悬挂）。
        if (!self.notesClipsUnchanged()) self.rescanForPlaybackEdit();
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

    /// 当前 notes/clips 与所在快照是否**内容等价**（忽略 `selected` 瞬态字段）。
    /// 供 `commitHistory` 判断是否需要重扫调度——只关心会改变事件的内容。
    fn notesClipsUnchanged(self: *const App) bool {
        if (self.history.items.len == 0) return false; // 无基准：保守重扫
        const old = &self.history.items[self.history_current];
        if (old.notes.len != self.notes.items.len or old.clips.len != self.clips.items.len) return false;
        for (old.notes, self.notes.items) |a, b| {
            if (a.step != b.step or a.len != b.len or a.pitch != b.pitch or
                a.pattern != b.pattern or a.instrument != b.instrument or
                a.velocity != b.velocity or a.pan != b.pan) return false;
        }
        for (old.clips, self.clips.items) |a, b| {
            if (a.track != b.track or a.start != b.start or a.len != b.len or
                a.pattern != b.pattern or a.offset != b.offset) return false;
        }
        return true;
    }

    /// 播放中编辑提交后：按新旧快照重扫调度（见 `sequencer.rescanForEdit`）。
    ///
    /// 背景（实测 bug）：调度水位线只前进不回头（提前 4 小节 gather）——
    /// 播放中新增/移动/删除/改值到“已扫过窗口”`[游标, 水位线)` 的音符
    /// 永远不会被重新 gather（表现：放置/克隆/粘贴的音符不响、改力度不生效）。
    ///
    /// 差分基准 = 提交前的上一快照（`history[history_current]`）——
    /// 音符/片段无 ID，序列器按（音高+乐器）的**跨游标实例数**比对
    /// （数量变化 → 补 on/off；数量不变如仅改力度 → 不补，正在响的
    /// 声部无法改值、下次触发生效）。
    fn rescanForPlaybackEdit(self: *App) void {
        if (!self.playing) return;
        if (self.history.items.len == 0) return;
        const old = &self.history.items[self.history_current];
        const cur = self.playback.cursorStep(self.sel.song_mode);
        const rescan_from = self.rescanSafeFromStep(cur);
        sequencer.rescanForEdit(
            &self.scheduler,
            &self.sched_events,
            self.clips.items,
            self.notes.items,
            old.clips,
            old.notes,
            self.sel.song_mode,
            self.sel.pattern,
            cur,
            rescan_from,
        );
        // 发布顺序：**先安全界、后编辑代**——音频读到新代时安全界必然
        // 已就位（反过来“新代 + 旧界”会丢弃还没重发的旧事件 → 漏 off → 悬挂）
        self.params.sched_rescan_from.store(self.scheduler.rescan_from, .monotonic);
        self.params.sched_edit_gen.store(self.scheduler.edit_gen, .monotonic);
    }

    /// 重扫的**安全界**：音频线程**确定还没走到**的第一步。
    ///
    /// 动机（实测 bug）：UI 游标来自帧首快照、落后音频线程；从 `游标+1`
    /// 重发会把音频**已经触发过**的 on 再发一次（音频对“已过时”事件立即
    /// 触发）→ 双声部；而 off 只有一份 → 只释放一个 → 个别音悬挂。
    /// 故用**新鲜读取**的 `frames_played` 估算音频位置，再加安全余量
    /// （≥2 步且 ≥1536 帧 ≈ 32ms——覆盖音频读取新代前可能推进的部分）。
    /// `(游标, 安全界)` 区间的旧副本由音频侧保留触发（不漏），代价是该
    /// 区间内**新增**的音符首次不响（下一遍会响）。
    fn rescanSafeFromStep(self: *const App, cur: i32) i32 {
        const sr: u64 = @max(1, self.params.sample_rate);
        const bpm: u64 = @intCast(std.math.clamp(self.bpm, 20, 999));
        const beat: u64 = @intCast(@max(1, model.stepsPerBeat(self.time_den)));
        const step_frames: u64 = @max(1, sr * 60 / (bpm * beat));
        const frames_now = self.params.frames_played.load(.monotonic);
        const el: u64 = frames_now -| self.playback.start_frame;
        const bound: i32 = self.playback.start_step + @as(i32, @intCast(el / step_frames));
        const margin: i32 = @intCast(@max(2, @divTrunc(1536 + step_frames - 1, step_frames)));
        return @max(cur + 1, bound + 1 + margin);
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
            for (st.instruments, 0..) |*si, i| {
                const target = &self.instruments.items[i];
                if (!std.mem.eql(u8, target.name, si.name)) {
                    const dup = self.allocator.dupe(u8, si.name) catch continue;
                    self.allocator.free(target.name);
                    target.name = dup;
                }
                self.applySavedInstrument(si, target);
            }
        } else {
            while (self.instruments.items.len > 0) {
                self.removeInstrument(self.instruments.items.len - 1);
            }
            for (st.instruments) |*si| {
                const idx = self.addInstrument(si.name);
                if (idx < 0) continue;
                const target = &self.instruments.items[@intCast(idx)];
                self.applySavedInstrument(si, target);
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
        if (st.pattern_names.len > 0) {
            self.restorePatternNames(st.pattern_names);
        } else if (self.patternCount() == 0) {
            self.resetPatterns(model.default_pattern_count);
        }
        self.bpm = st.bpm;
        self.time_num = st.time_num;
        self.time_den = st.time_den;
        self.steps_per_bar = st.steps_per_bar;
        // 调音台通道（含效果链）
        self.importMixerChannels(st.mixer);
        // 选择钳制
        if (self.sel.pattern >= self.patternCount()) self.sel.pattern = self.patternCount() - 1;
        // 钢琴卷帘：目标样式可能已被撤销到不存在 → 钳到有效范围
        if (self.piano.pattern) |pp| {
            if (pp >= self.patternCount()) self.piano.pattern = self.patternCount() - 1;
        }
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

    /// 添加样式（名字 = 最小可用的“样式 N”；上限 `model.max_patterns`）。
    /// 返回新样式序号（0 起；已达上限返回 -1）。
    /// 名字要**避开重名**：删掉“样式 2”后再加，应补回“样式 2”（而非一律用
    /// 数量+1——那样会与现存名字撞车）。
    pub fn addPattern(self: *App) i32 {
        if (self.pattern_items.items.len >= model.max_patterns) return -1;
        var buf: [32]u8 = undefined;
        var name_text: []const u8 = "";
        var n: i32 = 1;
        outer: while (n <= @as(i32, model.max_patterns)) : (n += 1) {
            const text = std.fmt.bufPrint(&buf, "样式 {d}", .{n}) catch return -1;
            for (self.pattern_items.items) |existing| {
                if (std.mem.eql(u8, existing, text)) continue :outer;
            }
            name_text = text;
            break;
        }
        if (name_text.len == 0) return -1; // 32 个名字全被占用（与上限同构，走不到）
        const name = self.allocator.dupe(u8, name_text) catch return -1;
        self.pattern_items.append(self.allocator, name) catch {
            self.allocator.free(name);
            return -1;
        };
        self.dirty = true;
        return @intCast(self.pattern_items.items.len - 1);
    }

    /// 删除样式（**连同其音符/片段**；其余样式序号前移）。
    /// 返回 false = 拒绝（无此样式 / 仅剩一个——**至少保留一个**）。
    /// 不弹确认框（与乐器删除一致；可 Ctrl+Z 撤销）。
    pub fn removePattern(self: *App, idx: usize) bool {
        if (idx >= self.pattern_items.items.len) return false;
        if (self.pattern_items.items.len <= 1) return false;
        const pat_i: i32 = @intCast(idx);
        // 音符：删除归属者；序号更大的前移（swapRemove——顺序无关）
        var i: usize = 0;
        while (i < self.notes.items.len) {
            const nt = &self.notes.items[i];
            if (nt.pattern == pat_i) {
                _ = self.notes.swapRemove(i);
            } else {
                if (nt.pattern > pat_i) nt.pattern -= 1;
                i += 1;
            }
        }
        // 片段同理
        i = 0;
        while (i < self.clips.items.len) {
            const c = &self.clips.items[i];
            if (c.pattern == pat_i) {
                _ = self.clips.swapRemove(i);
            } else {
                if (c.pattern > pat_i) c.pattern -= 1;
                i += 1;
            }
        }
        // 名字（释放并移除；其后前移）
        const name = self.pattern_items.orderedRemove(idx);
        self.allocator.free(name);
        // 选择钳制 / 钢琴卷帘跟随
        if (self.sel.pattern > pat_i) self.sel.pattern -= 1;
        if (self.sel.pattern >= self.patternCount()) self.sel.pattern = self.patternCount() - 1;
        if (self.piano.pattern) |pp| {
            if (pp == pat_i) {
                self.closePiano(); // 正在编辑的样式被删：内容已不存在 → 关闭
            } else if (pp > pat_i) {
                self.piano.pattern = pp - 1;
            }
        }
        // 右键菜单正指向被删项 → 关闭（防悬空索引）
        if (self.panels.ctx_pattern) |cp| {
            if (cp == idx) {
                self.panels.ctx_pattern = null;
            } else if (cp > idx) {
                self.panels.ctx_pattern = cp - 1;
            }
        }
        self.dirty = true;
        return true;
    }

    /// 用给定名字列表替换样式列表（撤销/重做/加载工程用；**复制每一项**）。
    /// `names` 接受 `[][]u8`（历史快照）或 `[]const []const u8`（存档）——故用 anytype。
    /// 兜底：全部复制失败时至少留一个样式（`patternCount() >= 1` 的约定）。
    fn restorePatternNames(self: *App, names: anytype) void {
        for (self.pattern_items.items) |nm| self.allocator.free(nm);
        self.pattern_items.clearRetainingCapacity();
        for (names) |nm| {
            const copy = self.allocator.dupe(u8, nm) catch continue;
            self.pattern_items.append(self.allocator, copy) catch {
                self.allocator.free(copy);
            };
        }
        if (self.pattern_items.items.len == 0) _ = self.addPattern();
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

    /// 是否有下拉/右键菜单展开（= 声明全屏模态层屏蔽下层交互）。
    ///
    /// **集中在这一处**：每种菜单都必须计入——漏项会让菜单的点击
    /// **穿透到下层**（实测 bug：文件→保存穿透点到左栏“操作历史”条目，
    /// 因为文件菜单正好盖在历史列表上方；历史面板用 `ui.listItem`（观 hit）
    /// 先于菜单绘制、当时又未被屏蔽）。
    pub fn menuIsOpen(self: *const App) bool {
        return self.rack.ctx_instrument != null or
            self.file_menu_open or self.panels.ctx_pattern != null or
            self.preset_browser.open;
    }

    /// 设置状态栏提示（覆盖旧的；默认显示约 3 秒）
    pub fn setToast(self: *App, text: []const u8) void {
        if (self.toast) |old| self.allocator.free(old);
        self.toast = self.allocator.dupe(u8, text) catch null;
        self.toast_remaining_ns = self.toast_total_ns;
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
        self.toast_remaining_ns = 0;
    }

    /// 每帧递减 toast 计时（main 调用）——`dt_ns` = 本帧实际流逝时间
    pub fn tickToast(self: *App, dt_ns: i64) void {
        if (self.toast_remaining_ns > 0) {
            self.toast_remaining_ns -= dt_ns;
            if (self.toast_remaining_ns <= 0) self.clearToast();
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
            notes[i] = .{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument, .velocity = n.velocity, .pan = n.pan };
        }
        const insts = try alloc.alloc(persist.SavedInstrument, self.instruments.items.len);
        var ni: usize = 0;
        errdefer {
            for (insts[0..ni]) |*si| self.freeSavedInstrument(si);
            alloc.free(insts);
        }
        for (self.instruments.items, 0..) |*inst, i| {
            insts[i] = try self.exportInstrument(inst);
            ni += 1;
        }
        // 调音台通道（增益/声像/静音/效果链）——共用 `exportMixerChannels`
        const mix = try self.exportMixerChannels(alloc);
        // 样式名字（自定义名随工程保存；旧版加载方忽略）
        const pat_names = try alloc.alloc([]const u8, self.pattern_items.items.len);
        var pn: usize = 0;
        errdefer {
            for (pat_names[0..pn]) |nm| alloc.free(nm);
            alloc.free(pat_names);
        }
        for (self.pattern_items.items, 0..) |nm, i| {
            pat_names[i] = try alloc.dupe(u8, nm);
            pn += 1;
        }
        return .{
            .bpm = self.bpm,
            .volume = self.volume, // 主音量（持久化——重开工程恢复）
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
            .pattern_count = self.patternCount(),
            .pattern_names = pat_names,
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
            if (sm.name.len > 0) self.allocator.free(sm.name);
        }
    }

    pub fn freeProject(self: *App, p: persist.Project) void {
        for (p.instruments) |*si| self.freeSavedInstrument(si);
        self.allocator.free(p.clips);
        self.allocator.free(p.notes);
        self.allocator.free(p.instruments);
        for (p.pattern_names) |nm| self.allocator.free(nm);
        self.allocator.free(p.pattern_names);
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
            self.addNote(.{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument, .velocity = n.velocity, .pan = n.pan });
        }
        for (p.instruments) |*inst| {
            const idx = self.addInstrument(inst.name);
            if (idx < 0) continue;
            const target = &self.instruments.items[@intCast(idx)];
            self.applySavedInstrument(inst, target);
        }

        // 全局设置
        self.bpm = p.bpm;
        self.volume = p.volume; // 主音量（缺字段的旧存档 → 默认值）
        self.params.volume.store(self.volume, .monotonic); // 立即同步到音频线程
        self.time_num = p.time_num;
        self.time_den = p.time_den;
        self.steps_per_bar = p.steps_per_bar;
        // 调音台通道：**动态数量**（旧存档无此字段 → 保持默认 2 个）——共用 `importMixerChannels`
        self.importMixerChannels(p.mixer);
        // 样式列表：优先按名字恢复（含自定义名）；旧存档无名字 → 按数量重建默认名
        if (p.pattern_names.len > 0) {
            self.restorePatternNames(p.pattern_names);
        } else {
            self.resetPatterns(if (p.pattern_count > 0) p.pattern_count else model.default_pattern_count);
        }

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
                .velocity = pn.velocity,
                .pan = pn.pan,
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
                    .velocity = @intCast(std.math.clamp(n.velocity, 1, 127)),
                    .pan = @intCast(std.math.clamp(n.pan, 0, 127)),
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

    /// 当前模式（SONG/PAT）的循环区域（与当前游标同坐标；null = 未设置）
    pub fn loopRegion(self: *const App) ?[2]i32 {
        return if (self.sel.song_mode) self.playback.loop_song else self.playback.loop_pat;
    }

    /// 设置当前模式的循环区域（归一化；空区域 → 取消）
    pub fn setLoopRegion(self: *App, a: i32, b: i32) void {
        const lo = @max(0, @min(a, b));
        const hi = @max(0, @max(a, b));
        if (hi <= lo) {
            self.clearLoopRegion();
            return;
        }
        if (self.sel.song_mode) {
            self.playback.loop_song = .{ lo, hi };
        } else {
            self.playback.loop_pat = .{ lo, hi };
        }
    }

    /// 取消当前模式的循环区域
    pub fn clearLoopRegion(self: *App) void {
        if (self.sel.song_mode) {
            self.playback.loop_song = null;
        } else {
            self.playback.loop_pat = null;
        }
        self.playback.loop_drag_from = null;
        self.playback.loop_drag_moved = false;
    }

    /// 指定样式的**内容末尾步**（该样式所有音符的最大结束步，不分乐器；
    /// 无音符 → 0）
    pub fn patternEndStep(self: *const App, pattern: i32) i32 {
        var last: i32 = 0;
        for (self.notes.items) |nt| {
            if (nt.pattern != pattern) continue;
            if (nt.len <= 0) continue;
            last = @max(last, nt.step + nt.len);
        }
        return last;
    }

    /// 指定样式的**有效长度**（步）：按拍号向上取整到小节倍数，至少 1 小节。
    /// 供播放列表“放置片段”的默认长度用（内容 2.5 小节 → 放 3 小节）。
    pub fn patternEffectiveLen(self: *const App, pattern: i32) i32 {
        const end = self.patternEndStep(pattern);
        const spb = @max(1, self.steps_per_bar);
        const bars = @max(1, @divTrunc(end + spb - 1, spb)); // 向上取整，至少 1
        return bars * spb;
    }

    /// 当前上下文（SONG/PAT）的**内容末尾步**（最后一个有效音符结束之后的
    /// 一步）；无音符 → 0。
    /// - SONG：所有片段的映射（音符经每片段映射的 end 最大值）——
    ///   与序列器一致（片段窗口截断后的 end）；
    /// - PAT：当前样式内**所有乐器**的末尾（与“听全样式”直觉一致）。
    pub fn contentEndStep(self: *const App) i32 {
        var last: i32 = 0;
        if (self.sel.song_mode) {
            for (self.clips.items) |clip| {
                for (self.notes.items) |nt| {
                    if (nt.pattern != clip.pattern) continue;
                    if (nt.len <= 0) continue;
                    const clip_end = clip.start + clip.len;
                    const local_lo = clip.offset;
                    const gs = clip.start + (nt.step - local_lo);
                    const ge = gs + nt.len;
                    if (ge <= clip.start or gs >= clip_end) continue; // 窗口外
                    last = @max(last, @min(ge, clip_end));
                }
            }
        } else {
            last = self.patternEndStep(self.sel.pattern);
        }
        return last;
    }

    /// 播放推进后的**循环回跳**（main 主循环每帧调用，播放中）。
    ///
    /// 规则（两条叠加）：
    /// 1. **循环区域**（用户设置）：游标到 `loop[1]` → 回跳到 `loop[0]`；
    /// 2. **自动循环**（未设区域）：游标超过内容末尾（最后一个有效音符）
    ///    → 回跳到开头（0）。
    /// 循环区域存在时只按 1 循环（不叠加自动），否则区域播放时会被
    /// “内容末尾”绕开。
    ///
    /// 回跳用 `jumpPlaybackCursor`（重置传输基准 + 作废旧调度事件 + 补发
    /// 跨起点音符）——与手动跳转同一套语义，声部释放/重触发都正确。
    pub fn tickPlaybackLoop(self: *App) void {
        if (!self.playing) return;
        const song_mode = self.sel.song_mode;
        const cur = self.playback.cursorStep(song_mode);

        // ① 循环区域（区域与游标同坐标：SONG 用全局、PAT 用局部）
        if (self.loopRegion()) |l| {
            if (cur >= l[1]) {
                self.jumpPlaybackCursor(l[0]);
            }
            return;
        }
        // ② 自动循环：超过内容末尾
        const end = self.contentEndStep();
        if (end > 0 and cur >= end) {
            self.jumpPlaybackCursor(0);
        }
    }

    /// 选中落入**全局步区域** `[lo, hi)` 的音符（按片段映射；播放列表
    /// 的循环选区用）。
    pub fn selectNotesInRegionSong(self: *App, lo: i32, hi: i32) void {
        self.clearNoteSelection();
        for (self.notes.items) |*nt| {
            if (nt.len <= 0) continue;
            for (self.clips.items) |clip| {
                if (nt.pattern != clip.pattern) continue;
                const clip_end = clip.start + clip.len;
                const gs = clip.start + (nt.step - clip.offset);
                const ge = gs + nt.len;
                if (ge <= clip.start or gs >= clip_end) continue;
                // 映射到片段窗口后的实际区间 [ms, me)，再与区域**相交判定**：
                // 音头在区域左、音尾伸进区域 → 也算（实测直觉：拖动框选应捕获
                // 与区域有重叠的所有音符，而不只是“起点在内”的）
                const ms = @max(gs, clip.start);
                const me = @min(ge, clip_end);
                if (ms < hi and me > lo) {
                    nt.selected = true;
                    break;
                }
            }
        }
    }

    /// 选中与**局部步区域** `[lo, hi)` 相交的音符（当前样式 + 当前乐器；
    /// 钢琴卷帘的循环选区用——与该视图的可编辑/可见范围一致）。
    /// **相交判定**（非“起点在内”）：音头在区域左、音尾伸进区域也算。
    pub fn selectNotesInRegionPat(self: *App, lo: i32, hi: i32) void {
        self.clearNoteSelection();
        for (self.notes.items) |*nt| {
            if (nt.pattern != self.sel.pattern) continue;
            if (nt.instrument != self.sel.instrument) continue;
            if (nt.len <= 0) continue;
            const ns = nt.step;
            const ne = nt.step + nt.len;
            if (ns < hi and ne > lo) nt.selected = true;
        }
    }

    /// 试听音符（路由到**当前乐器**）
    pub fn auditionOn(self: *App, pitch: i32) void {
        self.auditionOnInst(self.sel.instrument, pitch);
    }

    /// 试听释音（路由到**当前乐器**）
    pub fn auditionOff(self: *App, pitch: i32) void {
        self.auditionOffInst(self.sel.instrument, pitch);
    }

    /// 试听音符（**指定乐器**——鼓组编辑器绑定窗口时不依赖当前选择）
    pub fn auditionOnInst(self: *App, inst: i32, pitch: i32) void {
        if (inst < 0 or inst >= synth.max_instruments) return;
        if (pitch < 0 or pitch > 127) return;
        self.events.push(.{ .kind = .on, .pitch = @intCast(pitch), .instrument = @intCast(inst) });
    }

    /// 试听释音（**指定乐器**）
    pub fn auditionOffInst(self: *App, inst: i32, pitch: i32) void {
        if (inst < 0 or inst >= synth.max_instruments) return;
        if (pitch < 0 or pitch > 127) return;
        self.events.push(.{ .kind = .off, .pitch = @intCast(pitch), .instrument = @intCast(inst) });
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

    // ── 文本输入（就地重命名）──
    // 模型：`cursor`（字节偏移，总在 code point 边界）+ `sel_anchor`（选区另一端；
    // null = 无选区）。所有编辑（输入/退格/Del）都作用于「光标位置」或「选区」；
    // 鼠标点击定位光标、拖动框选；Ctrl+A 全选。

    /// 开始重命名乐器（输入框预填当前名字；光标置末尾、无选区）
    pub fn beginRenameInstrument(self: *App, idx: usize, x: i32, y: i32) void {
        if (idx >= self.instruments.items.len) return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .instrument;
        ti.index = idx;
        ti.x = x;
        ti.y = y;
        const name = self.instruments.items[idx].name;
        const n = @min(name.len, ti.buf.len);
        @memcpy(ti.buf[0..n], name[0..n]);
        ti.len = n;
        ti.cursor = n;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.view_off = 0;
    }

    /// 开始重命名调音台通道（预填自定义名；无自定义名则空）
    pub fn beginRenameMixerChannel(self: *App, idx: usize, x: i32, y: i32) void {
        if (idx >= self.mixer_channels_state.items.len) return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .mixer_channel;
        ti.index = idx;
        ti.x = x;
        ti.y = y;
        const mc = &self.mixer_channels_state.items[idx];
        const n = @min(mc.name_len, ti.buf.len);
        @memcpy(ti.buf[0..n], mc.name[0..n]);
        ti.len = n;
        ti.cursor = n;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.view_off = 0;
    }

    // ── 内部：选区/光标编辑 ──

    /// 删除选区（无选区 = 空操作）；光标置于选区起点
    fn textInputDeleteSelection(self: *App) void {
        const ti = &self.text_input;
        const sel = ti.selection() orelse return;
        const lo = sel[0];
        const hi = sel[1];
        const tail = ti.len - hi;
        std.mem.copyForwards(u8, ti.buf[lo .. lo + tail], ti.buf[hi..ti.len]);
        ti.len -= hi - lo;
        ti.cursor = lo;
        ti.sel_anchor = null;
    }

    /// 光标前一个 code point 的起始偏移（用于退格/左移）
    fn prevCp(self: *const App, from: usize) usize {
        if (from == 0) return 0;
        var i = from - 1;
        while (i > 0 and (self.text_input.buf[i] & 0xC0) == 0x80) : (i -= 1) {}
        return i;
    }

    /// 光标后一个 code point 的结束偏移（用于 Del/右移）
    fn nextCp(self: *const App, from: usize) usize {
        const ti = &self.text_input;
        if (from >= ti.len) return ti.len;
        var i = from + 1;
        while (i < ti.len and (ti.buf[i] & 0xC0) == 0x80) : (i += 1) {}
        return i;
    }

    /// 开始重命名样式（预填当前名字）
    pub fn beginRenamePattern(self: *App, idx: usize, x: i32, y: i32) void {
        if (idx >= self.pattern_items.items.len) return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .pattern;
        ti.index = idx;
        ti.x = x;
        ti.y = y;
        const name = self.pattern_items.items[idx];
        const n = @min(name.len, ti.buf.len);
        @memcpy(ti.buf[0..n], name[0..n]);
        ti.len = n;
        ti.cursor = n;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.view_off = 0;
    }

    /// 追加一个字符（UTF-8；在**光标处插入**——有选区则先删除选区）
    pub fn textInputAppend(self: *App, cp: u21) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        self.textInputDeleteSelection();
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return; // 非法 code point：丢弃
        if (ti.len + n > ti.buf.len) return;
        // 光标后的尾部右移 n 字节（从后往前——重叠安全）
        const tail = ti.len - ti.cursor;
        std.mem.copyBackwards(u8, ti.buf[ti.cursor + n .. ti.cursor + n + tail], ti.buf[ti.cursor .. ti.cursor + tail]);
        @memcpy(ti.buf[ti.cursor .. ti.cursor + n], tmp[0..n]);
        ti.len += n;
        ti.cursor += n;
    }

    /// 退格：有选区 → 删选区；否则删光标前一个 code point
    pub fn textInputBackspace(self: *App) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        if (ti.selection() != null) {
            self.textInputDeleteSelection();
            return;
        }
        if (ti.cursor == 0) return;
        const prev = self.prevCp(ti.cursor);
        const cut = ti.cursor - prev;
        const tail = ti.len - ti.cursor;
        std.mem.copyForwards(u8, ti.buf[prev .. prev + tail], ti.buf[ti.cursor..ti.len]);
        ti.len -= cut;
        // **锚点维护**：无选区时 anchor == cursor（“点一下定位光标”后就是这种状态）——
        // 光标前移时锚点必须跟着走，否则锚点滞留旧位置 > 新 len，下一帧
        // `text[0..sel_hi]` 越界 panic（实测：重命名 "Lead1" → 点尾 → 退格删 "1"
        // → "index 5, len 4"；脚本复现同族 "index 4, len 3"）。
        if (ti.sel_anchor) |a| {
            ti.sel_anchor = if (a == ti.cursor) prev else @min(a, ti.len);
        }
        ti.cursor = prev;
    }

    /// Delete 键：有选区 → 删选区；否则删光标后一个 code point
    pub fn textInputDelete(self: *App) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        if (ti.selection() != null) {
            self.textInputDeleteSelection();
            return;
        }
        if (ti.cursor >= ti.len) return;
        const next = self.nextCp(ti.cursor);
        const cut = next - ti.cursor;
        const tail = ti.len - next;
        std.mem.copyForwards(u8, ti.buf[ti.cursor .. ti.cursor + tail], ti.buf[next..ti.len]);
        ti.len -= cut;
    }

    /// 光标移动（方向键/Home/End）。`extend` = Shift 按住 → 扩展选区。
    /// `dir`：-2 = Home，-1 = 左，1 = 右，2 = End。
    /// Shift+Home/End：扩展到文本首/尾。
    pub fn textInputMoveCursor(self: *App, dir: i32, extend: bool) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        // 有选区且不带 Shift：左/右先折叠到选区边界
        if (!extend and ti.selection() != null) {
            const sel = ti.selection().?;
            ti.cursor = if (dir < 0) sel[0] else sel[1];
            ti.sel_anchor = null;
            return;
        }
        const new_pos: usize = switch (dir) {
            -2 => 0,
            -1 => self.prevCp(ti.cursor),
            1 => self.nextCp(ti.cursor),
            2 => ti.len,
            else => ti.cursor,
        };
        if (extend) {
            if (ti.sel_anchor == null) ti.sel_anchor = ti.cursor;
            ti.cursor = new_pos;
            // 注：光标回到锚点时**不**清锚点（同 `textInputPointerMove` 的坑）——
            // “无选区”由 `selection()` 判定；保留锚点才能继续反向扩展。
        } else {
            ti.cursor = new_pos;
            ti.sel_anchor = null;
        }
    }

    /// Ctrl+A：全选
    pub fn textInputSelectAll(self: *App) void {
        const ti = &self.text_input;
        if (!ti.active or ti.len == 0) return;
        ti.sel_anchor = 0;
        ti.cursor = ti.len;
    }

    /// 鼠标按下定位：`byte_off` = 击点对应的字节偏移（调用方用
    /// `Ui.textIndexAtX` 换算）。置光标并开始拖选（锚点 = 击点）。
    pub fn textInputPointerDown(self: *App, byte_off: usize) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        ti.cursor = byte_off;
        ti.sel_anchor = byte_off; // 锚点 = 击点（拖出后成为选区起点）
        ti.drag_active = true;
    }

    /// 鼠标拖动：扩展选区（锚点不变，光标跟鼠标）。
    /// 注：**不能**在“光标拖回锚点”时把锚点置 null——拖动开始时鼠标
    /// 必然先在同一字符格内移动（光标 == 锚点），一置 null 锚点就再也
    /// 回不来了（实测 bug：拖动只剩移动光标、永远拉不出选区）；
    /// “锚点 == 光标→ 无选区”由 `selection()` 判定，无需动状态。
    pub fn textInputPointerMove(self: *App, byte_off: usize) void {
        const ti = &self.text_input;
        if (!ti.active or !ti.drag_active) return;
        ti.cursor = byte_off;
    }

    /// 鼠标松开：结束拖选
    pub fn textInputPointerUp(self: *App) void {
        self.text_input.drag_active = false;
    }

    /// 提交：写入目标；空串 → 乐器保持原名、通道恢复默认占位名
    pub fn textInputCommit(self: *App) void {
        const ti = &self.text_input;
        if (!ti.active) return;
        const val = ti.buf[0..ti.len];
        switch (ti.target) {
            .instrument => {
                if (ti.index < self.instruments.items.len and val.len > 0) {
                    const inst = &self.instruments.items[ti.index];
                    if (!std.mem.eql(u8, inst.name, val)) {
                        const copy = self.allocator.dupe(u8, val) catch null;
                        if (copy) |c| {
                            self.allocator.free(inst.name);
                            inst.name = c;
                            self.commitHistory("重命名乐器");
                        }
                    }
                }
            },
            .mixer_channel => {
                if (ti.index < self.mixer_channels_state.items.len) {
                    const mc = &self.mixer_channels_state.items[ti.index];
                    const n = @min(val.len, mc.name.len);
                    if (n != mc.name_len or !std.mem.eql(u8, mc.name[0..mc.name_len], val[0..n])) {
                        @memcpy(mc.name[0..n], val[0..n]);
                        mc.name_len = n;
                        self.commitHistory("重命名通道");
                    }
                }
            },
            .pattern => {
                if (ti.index < self.pattern_items.items.len and val.len > 0) {
                    const old = self.pattern_items.items[ti.index];
                    if (!std.mem.eql(u8, old, val)) {
                        const copy = self.allocator.dupe(u8, val) catch null;
                        if (copy) |c| {
                            self.allocator.free(old);
                            self.pattern_items.items[ti.index] = c;
                            self.dirty = true;
                            self.commitHistory("重命名样式");
                        }
                    }
                }
            },
            .preset_name => {
                // “保存为…”：空名 → 忽略；否则排队等 main 落盘（源 = 预设保存源）
                if (val.len > 0) {
                    var act = PresetAction{ .save = .{
                        .source = self.preset_save_source,
                        .name_buf = undefined,
                        .name_len = 0,
                    } };
                    const n = @min(val.len, act.save.name_buf.len);
                    @memcpy(act.save.name_buf[0..n], val[0..n]);
                    act.save.name_len = n;
                    self.pending_preset = act;
                }
            },
            .kit_pad_name => {
                // 鼓垫重命名（空名 = 清除——回到默认 GM/音名显示）
                if (ti.instrument >= 0 and ti.index <= 127) {
                    _ = self.kitPadRename(ti.instrument, @intCast(ti.index), val);
                }
            },
            .preset_rename => {
                // 预设文件重命名（旧名存 `aux_buf`；空名/旧名缺失 → 忽略）
                if (val.len > 0 and ti.aux_len > 0) {
                    var act = PresetAction{ .rename = .{
                        .cat = ti.index,
                        .old_buf = ti.aux_buf,
                        .old_len = ti.aux_len,
                        .new_buf = undefined,
                        .new_len = 0,
                    } };
                    const n = @min(val.len, act.rename.new_buf.len);
                    @memcpy(act.rename.new_buf[0..n], val[0..n]);
                    act.rename.new_len = n;
                    self.pending_preset = act;
                }
            },
        }
        ti.active = false;
    }

    /// 取消（不写入）
    pub fn textInputCancel(self: *App) void {
        self.text_input.active = false;
        self.text_input.drag_active = false;
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

test "app: 样式有效长度——按内容末尾向上取整到小节（放置片段的默认长度）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    const spb: i32 = app.steps_per_bar; // 4/4 → 96
    app.sel.song_mode = false;
    app.sel.pattern = 0;

    // ① 空样式 → 至少 1 小节
    try std.testing.expectEqual(spb, app.patternEffectiveLen(0));

    // ② 内容正好 1 小节 → 1 小节
    app.addNote(.{ .step = 0, .len = spb, .pitch = 60, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(spb, app.patternEffectiveLen(0));

    // ③ 内容超过 1 小节（1 小节 + 4 步）→ 2 小节
    app.addNote(.{ .step = spb, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(spb * 2, app.patternEffectiveLen(0));

    // ④ 内容正好 2 小节 → 2 小节（不额外膨胀）
    app.addNote(.{ .step = spb + 4, .len = spb - 4, .pitch = 64, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(spb * 2, app.patternEffectiveLen(0));

    // ⑤ 只看**指定样式**：其它样式的音符不影响
    app.addNote(.{ .step = 0, .len = spb * 5, .pitch = 65, .pattern = 1, .instrument = 0 });
    try std.testing.expectEqual(spb * 2, app.patternEffectiveLen(0));
    try std.testing.expectEqual(spb * 5, app.patternEffectiveLen(1));

    // ⑥ 不分乐器：另一个乐器的长音符也算
    app.addNote(.{ .step = spb * 2, .len = spb, .pitch = 66, .pattern = 0, .instrument = 1 });
    try std.testing.expectEqual(spb * 3, app.patternEffectiveLen(0));
}

test "app: 循环播放——自动回跳（内容末尾）与循环区域" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // PAT：两个音符，末尾 = 24（第二个音符 16..24）
    app.sel.song_mode = false;
    app.sel.pattern = 0;
    app.addNote(.{ .step = 0, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 16, .len = 8, .pitch = 62, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(@as(i32, 24), app.contentEndStep());

    // ① 自动循环：游标过末尾（未设区域）→ 回跳 0
    app.playing = true;
    app.playback.piano_step = 23;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 23), app.playback.piano_step); // 未到末尾：不动
    app.playback.piano_step = 24;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 0), app.playback.piano_step); // 到末尾：回跳

    // ② 循环区域（PAT 局部步）：到 loop[1] → 回跳到 loop[0]
    app.setLoopRegion(4, 20);
    try std.testing.expectEqual(@as(?[2]i32, .{ 4, 20 }), app.loopRegion());
    app.playback.piano_step = 19;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 19), app.playback.piano_step); // 未到：不动
    app.playback.piano_step = 20;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 4), app.playback.piano_step); // 到区域末端：回跳到区域头

    // 区域优先于自动循环：内容末尾 24 不在区域内 → 到 20 就回跳（而非 24）
    app.playback.piano_step = 21;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 4), app.playback.piano_step);

    // ③ 取消循环区域 → 恢复自动循环
    app.clearLoopRegion();
    try std.testing.expectEqual(@as(?[2]i32, null), app.loopRegion());
    app.playback.piano_step = 24;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 0), app.playback.piano_step);

    // ④ SONG 区域与 PAT 区域互不干扰
    app.setLoopRegion(8, 16); // PAT 槽
    app.sel.song_mode = true;
    try std.testing.expectEqual(@as(?[2]i32, null), app.loopRegion()); // SONG 槽未设
    app.setLoopRegion(32, 64); // SONG 槽
    app.sel.song_mode = false;
    try std.testing.expectEqual(@as(?[2]i32, .{ 8, 16 }), app.loopRegion()); // PAT 槽不变
    app.sel.song_mode = true;
    try std.testing.expectEqual(@as(?[2]i32, .{ 32, 64 }), app.loopRegion());

    app.stopPlayback();
}

test "app: 循环标尺选区——相交判定（音尾伸进区域也算；PAT 局部 / SONG 全局）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // PAT：[0,4) / [16,20) / [32,36) / [4,12)（音头在区域左、音尾伸进 [8,24)）
    app.sel.song_mode = false;
    app.sel.pattern = 0;
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 }); // 窗口外（左）
    app.addNote(.{ .step = 16, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 }); // 完全在内
    app.addNote(.{ .step = 32, .len = 4, .pitch = 64, .pattern = 0, .instrument = 0 }); // 窗口外（右）
    app.addNote(.{ .step = 4, .len = 8, .pitch = 65, .pattern = 0, .instrument = 0 }); // 音头在区域左、音尾伸进区域
    app.selectNotesInRegionPat(8, 24);
    try std.testing.expect(!app.notes.items[0].selected); // [0,4)：不相交
    try std.testing.expect(app.notes.items[1].selected); // 完全在内
    try std.testing.expect(!app.notes.items[2].selected); // [32,36)：不相交
    try std.testing.expect(app.notes.items[3].selected); // [4,12)：尾伸进 → 算

    // SONG：片段 [0, 32) 映射；[4,12) 音符只映射一次（经片段）→ 全局 [4,12) 尾伸进 [8,24)
    app.clearNoteSelection();
    app.sel.song_mode = true;
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 32, .pattern = 0, .offset = 0 }) catch {};
    app.selectNotesInRegionSong(8, 24);
    try std.testing.expect(!app.notes.items[0].selected); // 全局 [0,4)：不相交
    try std.testing.expect(app.notes.items[1].selected); // 全局 [16,20)：在内
    try std.testing.expect(app.notes.items[3].selected); // 全局 [4,12)：尾伸进
    try std.testing.expect(!app.notes.items[2].selected); // 全局 [32,36)：出片段窗口 + 不相交
    try std.testing.expect(!app.notes.items[2].selected); // 全局 32：出片段窗口 + 不在区域
}

test "app: Del 优先删框选；框选为空时删循环区域内音符" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // PAT：[0,4) / [16,20) / [32,36)；循环区域 [8, 24)
    app.sel.song_mode = false;
    app.sel.pattern = 0;
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 16, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 32, .len = 4, .pitch = 64, .pattern = 0, .instrument = 0 });
    app.setLoopRegion(8, 24);

    // ① 框选为空 → 删循环区域内的音符（step 16 那个）
    try std.testing.expectEqual(@as(usize, 0), app.selectedNoteCount());
    try std.testing.expectEqual(@as(usize, 1), app.deleteSelectedNotes());
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len);
    for (app.notes.items) |nt| try std.testing.expect(nt.step != 16);

    // ② 有框选 → 优先删框选（即使框选在循环区域之外）
    for (app.notes.items) |*nt| {
        if (nt.step == 32) nt.selected = true;
    }
    try std.testing.expectEqual(@as(usize, 1), app.deleteSelectedNotes());
    try std.testing.expectEqual(@as(usize, 1), app.notes.items.len);
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].step); // 循环区域内的 16 已在①删了；32 被框选删了

    // ③ 框选为空 + 循环区域也无音符 → 不删（返回 0）
    try std.testing.expectEqual(@as(usize, 0), app.selectedNoteCount());
    try std.testing.expectEqual(@as(usize, 0), app.deleteSelectedNotes());
    try std.testing.expectEqual(@as(usize, 1), app.notes.items.len);

    // ④ 无循环区域 + 框选为空 → 不删（返回 0）
    app.clearLoopRegion();
    try std.testing.expectEqual(@as(usize, 0), app.deleteSelectedNotes());
    try std.testing.expectEqual(@as(usize, 1), app.notes.items.len);
}

test "app: 播放中新增音符——提交历史时补发调度（修“追加的音符不响”）" {
    // 复现：水位线已扫到 32、游标在 8；播放中放置/克隆/粘贴到 [8,32) 的音符
    // 必须被补发（否则永远不响——实测 bug）
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 播放中（PAT 模式）：水位线扫到 32，游标 8
    app.playing = true;
    app.sel.song_mode = false;
    app.playback.piano_step = 8;
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    // 排空既有事件（不干扰断言）
    var drain: [16]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&drain);

    // 放置一个音符（游标后方、水位线之内）→ 提交历史
    app.addNote(.{ .step = 16, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");

    var out: [8]synth.SchedEvent = undefined;
    const n = app.sched_events.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n); // 补发 on@16 + off@20
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 16), out[0].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    try std.testing.expectEqual(@as(i32, 20), out[1].step);

    // 未播放时不补发（无水位线语义）
    app.stopPlayback();
    _ = app.sched_events.drain(&drain);
    app.addNote(.{ .step = 20, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");
    try std.testing.expectEqual(@as(usize, 0), app.sched_events.drain(&out));
}

test "app: 播放中改力度——提交历史时重扫（带新力度）且产生历史条目" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 一个窗口内的音符（水位线已扫过，事件带旧力度 100）
    app.addNote(.{ .step = 16, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");

    app.playing = true;
    app.sel.song_mode = false;
    app.playback.piano_step = 8;
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    var drain: [16]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&drain);

    // 改力度 → 提交历史
    const before_len = app.history.items.len;
    app.notes.items[0].velocity = 40;
    app.commitHistory("调整力度");
    try std.testing.expectEqual(before_len + 1, app.history.items.len); // 产生历史条目

    // 重扫：on@16/off@20 重发，且**带新力度 40** + 新编辑代
    var out: [8]synth.SchedEvent = undefined;
    const n = app.sched_events.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(u8, 40), out[0].velocity);
    try std.testing.expectEqual(app.scheduler.edit_gen, out[0].edit_gen);

    // 撤销 → 力度恢复 100
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].velocity);
}

test "app: 播放中非音符编辑不重扫（修“调 EQ 悬挂”的根源之一）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    app.addNote(.{ .step = 16, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");

    app.playing = true;
    app.sel.song_mode = false;
    app.playback.piano_step = 8;
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&out);

    // 非音符编辑（通道声像）：commitHistory 产生历史条目，但**不**重扫调度——
    // 否则会重发游标附近的 on，音频对过时事件立即触发 → 双声部 → 悬挂。
    const edit0 = app.scheduler.edit_gen;
    app.mixer_channels_state.items[0].pan = 0.25;
    app.commitHistory("调整通道声像");
    try std.testing.expectEqual(edit0, app.scheduler.edit_gen); // 编辑代不变
    try std.testing.expectEqual(@as(usize, 0), app.sched_events.drain(&out)); // 无重发
    try std.testing.expect(app.history.items.len >= 3); // 历史条目照常

    // 对照：音符编辑（改力度）→ 重扫（编辑代递增 + 事件重发）
    app.notes.items[0].velocity = 40;
    app.commitHistory("调整力度");
    try std.testing.expect(app.scheduler.edit_gen != edit0);
    try std.testing.expect(app.sched_events.drain(&out) > 0);
}

test "app: 重扫安全界——游标附近已走过的步不重发（防双触发）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 两个音符：① [9,10)（(游标, 安全界) 内——不重发）；② [20,24)（重发）
    app.addNote(.{ .step = 9, .len = 1, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 20, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");

    app.playing = true;
    app.sel.song_mode = false;
    app.playback.piano_step = 8;
    // 造“音频已走到 8”：帧数 / 每步帧数（48k、120bpm、分母 4 → 1000 帧/步）
    app.playback.start_frame = 0;
    app.playback.start_step = 0;
    app.params.frames_played.store(8000, .monotonic);
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&out);

    // 安全界：bound=8、margin≥2 → 11（游标 8）
    try std.testing.expectEqual(@as(i32, 11), app.rescanSafeFromStep(8));

    // 改力度提交 → 重扫 [11, 32)：只重发 ②（on@20/off@24）；①的 on@9/off@10
    // 均 < 11，不重发（旧副本由音频侧保留触发，不漏）
    app.notes.items[0].velocity = 40;
    app.notes.items[1].velocity = 40;
    app.commitHistory("调整力度");
    const n = app.sched_events.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, 20), out[0].step);
    try std.testing.expectEqual(synth.EventKind.on, out[0].kind);
    try std.testing.expectEqual(@as(i32, 24), out[1].step);
    try std.testing.expectEqual(synth.EventKind.off, out[1].kind);
    // 发布的安全界与编辑代（音频据此过滤——先界后代的顺序在源码中保证）
    try std.testing.expectEqual(@as(i32, 11), app.params.sched_rescan_from.load(.monotonic));
    try std.testing.expectEqual(app.scheduler.edit_gen, app.params.sched_edit_gen.load(.monotonic));
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

test "app: menuIsOpen——每种菜单都必须计入（漏项会穿透下层）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 实测 bug：文件菜单未计入 → 展开时不声明模态层 → 点“保存”
    // 穿透点到左栏“操作历史”的条目（菜单盖在列表上方）
    try std.testing.expect(!app.menuIsOpen());
    app.file_menu_open = true;
    try std.testing.expect(app.menuIsOpen());
    app.file_menu_open = false;

    // 机架右键菜单（乐器）
    app.rack.ctx_instrument = 0;
    try std.testing.expect(app.menuIsOpen());
    app.rack.ctx_instrument = null;

    // 预设面板（统一选择器：模态）
    app.preset_browser.open = true;
    try std.testing.expect(app.menuIsOpen());
    app.preset_browser.open = false;

    // 全部关闭 → 无菜单
    try std.testing.expect(!app.menuIsOpen());
}

test "app: 导入工程恢复主音量（并同步到音频线程）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), app.volume, 1e-6); // 默认
    app.importProject(.{ .bpm = 120, .volume = 0.77 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.77), app.volume, 1e-6);
    // 音频线程参数同步（不重开软件即时生效）
    try std.testing.expectApproxEqAbs(@as(f32, 0.77), app.params.volume.load(.monotonic), 1e-6);
}

test "app: 重命名乐器——预填/追加/退格（多字节）/提交/历史；空名不改" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // ① 开始重命名：预填当前名
    app.beginRenameInstrument(0, 0, 0);
    try std.testing.expect(app.text_input.active);
    try std.testing.expectEqualStrings("减法合成器", app.text_input.text());

    // ② 退格 3 次（删“成器”与“合”）→ “减法”
    var i: usize = 0;
    while (i < 3) : (i += 1) app.textInputBackspace();
    try std.testing.expectEqualStrings("减法", app.text_input.text());

    // ③ 追加中文 + 英文（UTF-8 多字节）
    app.textInputAppend('主');
    app.textInputAppend('奏');
    app.textInputAppend('A');
    try std.testing.expectEqualStrings("减法主奏A", app.text_input.text());

    // ④ 退格一次：删掉 'A'（ASCII）
    app.textInputBackspace();
    try std.testing.expectEqualStrings("减法主奏", app.text_input.text());

    // ⑤ 提交：名字变更 + 纳入历史（撤销可恢复）
    const hist_before = app.history.items.len;
    app.textInputCommit();
    try std.testing.expect(!app.text_input.active);
    try std.testing.expectEqualStrings("减法主奏", app.instruments.items[0].name);
    try std.testing.expectEqual(hist_before + 1, app.history.items.len);
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("减法合成器", app.instruments.items[0].name);

    // ⑥ 空名提交：乐器保持原名（不允许空名）
    try std.testing.expect(app.redo());
    app.beginRenameInstrument(0, 0, 0);
    var k: usize = 0;
    while (k < 32) : (k += 1) app.textInputBackspace();
    try std.testing.expectEqual(@as(usize, 0), app.text_input.text().len);
    app.textInputCommit();
    try std.testing.expectEqualStrings("减法主奏", app.instruments.items[0].name); // 空名：不改

    // ⑦ ESC 取消：不动
    app.beginRenameInstrument(0, 0, 0);
    app.textInputAppend('X');
    app.textInputCancel();
    try std.testing.expect(!app.text_input.active);
    try std.testing.expectEqualStrings("减法主奏", app.instruments.items[0].name);
}

test "app: 重命名——光标定位/插入/Del/选区/Ctrl+A" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("abcdef");
    app.resetHistory("初始状态");

    // 预填后光标在末尾
    app.beginRenameInstrument(0, 0, 0);
    try std.testing.expectEqualStrings("abcdef", app.text_input.text());
    try std.testing.expectEqual(@as(usize, 6), app.text_input.cursor);

    // ←/→ 移动（无选区）
    app.textInputMoveCursor(-1, false);
    try std.testing.expectEqual(@as(usize, 5), app.text_input.cursor);
    app.textInputMoveCursor(1, false);
    try std.testing.expectEqual(@as(usize, 6), app.text_input.cursor);
    app.textInputMoveCursor(-2, false); // Home
    try std.testing.expectEqual(@as(usize, 0), app.text_input.cursor);

    // 光标处插入（不是末尾追加）
    app.textInputAppend('X');
    try std.testing.expectEqualStrings("Xabcdef", app.text_input.text());
    try std.testing.expectEqual(@as(usize, 1), app.text_input.cursor);

    // Del：删光标后一个字符
    app.textInputDelete();
    try std.testing.expectEqualStrings("Xbcdef", app.text_input.text());

    // Shift+→ 三次 → 选区 [1, 4)；再无 Shift 右移 → 折叠到选区右侧
    app.textInputMoveCursor(1, true);
    app.textInputMoveCursor(1, true);
    app.textInputMoveCursor(1, true);
    try std.testing.expectEqual(@as(?[2]usize, .{ 1, 4 }), app.text_input.selection());
    app.textInputMoveCursor(1, false);
    try std.testing.expectEqual(@as(?[2]usize, null), app.text_input.selection());
    try std.testing.expectEqual(@as(usize, 4), app.text_input.cursor);

    // 输入字符替换选区：Ctrl+A 全选 + 输入 → 只剩新字符
    app.textInputSelectAll();
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 6 }), app.text_input.selection());
    app.textInputAppend('Z');
    try std.testing.expectEqualStrings("Z", app.text_input.text());

    // Backspace/Del 删选区
    app.textInputAppend('A');
    app.textInputAppend('B');
    app.textInputSelectAll();
    app.textInputBackspace();
    try std.testing.expectEqual(@as(usize, 0), app.text_input.text().len);
    app.textInputAppend('C');
    app.textInputAppend('D');
    app.textInputMoveCursor(-2, false); // Home
    app.textInputMoveCursor(1, true); // 选中 'C'
    app.textInputDelete(); // 删选区
    try std.testing.expectEqualStrings("D", app.text_input.text());

    // 鼠标：按下定位（锚点 = 击点，无选区）→ 拖出 → 选区
    app.textInputAppend('E'); // 光标在 0（删选区后）→ 插入后为 "ED"
    app.textInputPointerDown(1);
    try std.testing.expectEqual(@as(?[2]usize, null), app.text_input.selection());
    app.textInputPointerMove(2);
    try std.testing.expectEqual(@as(?[2]usize, .{ 1, 2 }), app.text_input.selection());
    app.textInputPointerUp();
    try std.testing.expectEqual(@as(?[2]usize, .{ 1, 2 }), app.text_input.selection()); // 松手后保留

    // 拖回锚点 → 选区取消（锚点**保留**：再拖出可重新选区）
    app.textInputPointerDown(0);
    app.textInputPointerMove(2);
    try std.testing.expect(app.text_input.selection() != null);
    app.textInputPointerMove(0);
    try std.testing.expectEqual(@as(?[2]usize, null), app.text_input.selection());
    app.textInputPointerUp();

    // 回归：拖动开始时鼠标**先在同一字符格内**移动（光标 == 锚点）——
    // 实测 bug：旧代码在这里把锚点置 null，之后拖到别的字符只剩移动光标、
    // 永远拉不出选区。锚点必须存活，再拖出应恢复选区。
    app.textInputPointerDown(0);
    app.textInputPointerMove(0); // 同一格：无选区但不该销毁锚点
    try std.testing.expectEqual(@as(?[2]usize, null), app.text_input.selection());
    app.textInputPointerMove(1);
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), app.text_input.selection()); // 拖出 → 选区
    app.textInputPointerUp();

    // 回归（键盘同理）：Shift+右 → Shift+左（回锚点）→ Shift+右：
    // 仍应从**原锚点**扩展（而非从头再来）
    app.textInputMoveCursor(-2, false); // Home → 光标 0
    app.textInputMoveCursor(1, true); // 锚点 0，光标 1 → [0,1)
    app.textInputMoveCursor(-1, true); // 光标回 0 → 无选区（锚点 0 保留）
    try std.testing.expectEqual(@as(?[2]usize, null), app.text_input.selection());
    app.textInputMoveCursor(1, true); // 再从锚点 0 向右
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), app.text_input.selection());
    app.textInputMoveCursor(1, false); // 无 Shift → 折叠并清锚点
    app.textInputMoveCursor(-2, false); // Home
}

test "app: 文本输入——点尾定位后退格不越界（修“Lead1 退格删 1”事故）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 预填 + 全选（与保存/重命名一致）；用事故里的名字 "Lead1"（5 字节）
    app.beginRenamePreset(0, 0, .{ .params = .{ .instrument = 0 } }, "Lead1");
    try std.testing.expectEqual(@as(usize, 5), app.text_input.len);
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 5 }), app.text_input.selection());

    // 点输入框尾部（定位光标：anchor = cursor = 5，无选区）——用户实际动作
    app.textInputPointerDown(5);
    app.textInputPointerUp();
    try std.testing.expect(app.text_input.selection() == null);

    // 退格删掉 "1"：旧代码锚点滞留 5 > 新 len 4 → 下一帧 text[0..5] 越界 panic
    app.textInputBackspace();
    try std.testing.expectEqual(@as(usize, 4), app.text_input.len);
    try std.testing.expectEqual(@as(usize, 4), app.text_input.cursor);
    try std.testing.expectEqualStrings("Lead", app.text_input.text());
    if (app.text_input.selection()) |sel| {
        try std.testing.expect(sel[1] <= app.text_input.len); // 渲染不变式
    }

    // 多字节名同理（“键” 3 字节 + 尾字符）
    app.beginRenamePreset(0, 0, .{ .params = .{ .instrument = 0 } }, "大鼓X");
    app.textInputPointerDown(app.text_input.len);
    app.textInputPointerUp();
    app.textInputBackspace();
    try std.testing.expectEqualStrings("大鼓", app.text_input.text());
    if (app.text_input.selection()) |sel| {
        try std.testing.expect(sel[1] <= app.text_input.len);
    }

    // 防御：就算钆点被人为弄脏，selection() 也不越界
    app.text_input.sel_anchor = 99;
    if (app.text_input.selection()) |sel| {
        try std.testing.expect(sel[1] <= app.text_input.len);
    }
}

test "app: 重命名调音台通道——空串恢复默认占位名" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 通道 0 默认占位名
    var nb: [24]u8 = undefined;
    try std.testing.expectEqualStrings("主通道", app.mixer_channels_state.items[0].displayName(0, &nb));
    try std.testing.expectEqualStrings("通道#1", app.mixer_channels_state.items[1].displayName(1, &nb));

    // 重命名通道 1 → “鼓组”
    app.beginRenameMixerChannel(1, 0, 0);
    app.textInputAppend('鼓');
    app.textInputAppend('组');
    app.textInputCommit();
    try std.testing.expectEqualStrings("鼓组", app.mixer_channels_state.items[1].displayName(1, &nb));

    // 清空重命名 → 恢复占位名
    app.beginRenameMixerChannel(1, 0, 0);
    var k: usize = 0;
    while (k < 8) : (k += 1) app.textInputBackspace();
    app.textInputCommit();
    try std.testing.expectEqualStrings("通道#1", app.mixer_channels_state.items[1].displayName(1, &nb));

    // 历史：两次重命名都有条目（第一次改名 + 第二次清空各一条）
    try std.testing.expect(app.history.items.len >= 3); // 初始 + 改名 + 清空
    try std.testing.expect(app.undo()); // 撤销“清空” → 恢复“鼓组”
    try std.testing.expectEqualStrings("鼓组", app.mixer_channels_state.items[1].displayName(1, &nb));
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

test "app: 样式——删除（音符/片段随删、序号前移、选择/钢琴卷帘/菜单跟随）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(4);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 四个样式各一个音符（音高 60..63 区分）；样式 2/3 各一个片段
    app.addNote(.{ .step = 0, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 8, .pitch = 61, .pattern = 1, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 8, .pitch = 62, .pattern = 2, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 8, .pitch = 63, .pattern = 3, .instrument = 0 });
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 1 });
    app.addClip(.{ .track = 0, .start = 96, .len = 96, .pattern = 3 });
    app.sel.pattern = 3;
    app.openPiano(2);
    app.panels.ctx_pattern = 3;

    // 删除中间的“样式 2”（索引 1）
    try std.testing.expect(app.removePattern(1));
    try std.testing.expectEqual(@as(i32, 3), app.patternCount());
    try std.testing.expectEqualStrings("样式 1", app.pattern_items.items[0]);
    try std.testing.expectEqualStrings("样式 3", app.pattern_items.items[1]);
    try std.testing.expectEqualStrings("样式 4", app.pattern_items.items[2]);

    // 音符：pitch 61（原样式 2）删了；62 由 2→1；63 由 3→2；60 不变
    // （swapRemove 打乱数组顺序，故按音高断言而非下标）
    try std.testing.expectEqual(@as(usize, 3), app.notes.items.len);
    for (app.notes.items) |nt| {
        switch (nt.pitch) {
            60 => try std.testing.expectEqual(@as(i32, 0), nt.pattern),
            62 => try std.testing.expectEqual(@as(i32, 1), nt.pattern),
            63 => try std.testing.expectEqual(@as(i32, 2), nt.pattern),
            else => return error.TestUnexpectedResult, // 61 应已删除
        }
    }
    // 片段：样式 1 的删了；样式 3 的 3→2
    try std.testing.expectEqual(@as(usize, 1), app.clips.items.len);
    try std.testing.expectEqual(@as(i32, 2), app.clips.items[0].pattern);

    // 选择/钢琴卷帘/右键菜单跟随
    try std.testing.expectEqual(@as(i32, 2), app.sel.pattern); // 3 → 2
    try std.testing.expectEqual(@as(?i32, 1), app.piano.pattern); // 2 → 1
    try std.testing.expectEqual(@as(?usize, 2), app.panels.ctx_pattern); // 3 → 2

    // 删除钢琴卷帘正在编辑的样式 → 关闭视图（内容已不存在）
    try std.testing.expect(app.removePattern(1));
    try std.testing.expectEqual(@as(?i32, null), app.piano.pattern);

    // 最后一个样式不可删
    try std.testing.expect(app.removePattern(0));
    try std.testing.expectEqual(@as(i32, 1), app.patternCount());
    try std.testing.expect(!app.removePattern(0));
}

test "app: 样式——重命名（预填/提交/历史/撤销/空名拒绝）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(3);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 预填当前名
    app.beginRenamePattern(1, 5, 5);
    try std.testing.expect(app.text_input.active);
    try std.testing.expectEqualStrings("样式 2", app.text_input.text());

    // 清空重打 → 提交
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('主');
    app.textInputAppend('歌');
    const hist_before = app.history.items.len;
    app.textInputCommit();
    try std.testing.expectEqualStrings("主歌", app.pattern_items.items[1]);
    try std.testing.expectEqual(hist_before + 1, app.history.items.len); // 产生历史条目

    // 撤销/重做（名字在快照里，能还原）
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("样式 2", app.pattern_items.items[1]);
    try std.testing.expect(app.redo());
    try std.testing.expectEqualStrings("主歌", app.pattern_items.items[1]);

    // 空名：拒绝（保持原名；与乐器同规则）
    app.beginRenamePattern(1, 5, 5);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputCommit();
    try std.testing.expectEqualStrings("主歌", app.pattern_items.items[1]);
}

test "app: 样式——添加避开重名（删除后重加）+ 上限拒绝" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(3); // 样式 1..3
    try std.testing.expect(app.removePattern(1)); // 删“样式 2” → 样式 1、样式 3

    const ni = app.addPattern();
    try std.testing.expectEqual(@as(i32, 2), ni); // 追加在末尾
    try std.testing.expectEqualStrings("样式 2", app.pattern_items.items[@intCast(ni)]); // 补最小空号

    // 上限：装满后拒绝
    app.resetPatterns(model.max_patterns);
    try std.testing.expectEqual(@as(i32, -1), app.addPattern());
}

test "app: 样式名随存档导出/导入（自定义名保留）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(3);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 改名第 2 个样式 → “流行”
    app.beginRenamePattern(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('流');
    app.textInputAppend('行');
    app.textInputCommit();

    const proj = try app.exportProject();
    defer app.freeProject(proj);

    // 导入到另一个 App（先造不同的样式布局：6 个默认名）
    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetPatterns(6);
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expectEqual(@as(i32, 3), app2.patternCount());
    try std.testing.expectEqualStrings("样式 1", app2.pattern_items.items[0]);
    try std.testing.expectEqualStrings("流行", app2.pattern_items.items[1]);
    try std.testing.expectEqualStrings("样式 3", app2.pattern_items.items[2]);

    // 旧存档（无 pattern_names）→ 按数量重建默认名
    var legacy = proj;
    legacy.pattern_names = &.{};
    legacy.pattern_count = 5;
    var app3 = App{ .allocator = std.testing.allocator };
    defer app3.clips.deinit(app3.allocator);
    defer app3.notes.deinit(app3.allocator);
    defer app3.deinitAll();
    app3.resetPatterns(2);
    app3.resetMixerChannels(default_mixer_channels);
    app3.importProject(legacy);
    try std.testing.expectEqual(@as(i32, 5), app3.patternCount());
    try std.testing.expectEqualStrings("样式 5", app3.pattern_items.items[4]);
}

test "app: 样式——删除可撤销（快照含名字/音符，重做再删）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(3);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    app.addNote(.{ .step = 0, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 8, .pitch = 61, .pattern = 1, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 8, .pitch = 62, .pattern = 2, .instrument = 0 });
    app.commitHistory("放置音符"); // 快照：3 样式 + 3 音符（供撤销基准）

    try std.testing.expect(app.removePattern(1)); // 删“样式 2”（连其音符）
    app.commitHistory("删除样式");
    try std.testing.expectEqual(@as(i32, 2), app.patternCount());
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len);

    // 撤销：样式名/数量/音符全还原
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(i32, 3), app.patternCount());
    try std.testing.expectEqualStrings("样式 2", app.pattern_items.items[1]);
    try std.testing.expectEqual(@as(usize, 3), app.notes.items.len);
    for (app.notes.items) |nt| {
        if (nt.pitch == 61) try std.testing.expectEqual(@as(i32, 1), nt.pattern);
    }
    // 重做：再删
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(@as(i32, 2), app.patternCount());
    try std.testing.expectEqual(@as(usize, 2), app.notes.items.len);
}

test "app: 鼓组——层增删/来源名、撤销恢复、存档往返（含 JSON）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(3);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    try std.testing.expectEqual(@as(i32, 0), inst);
    app.resetHistory("初始状态");

    // 加层：kick 两层（第二层带预设来源 + 非默认音色）、snare 一层
    var saved = persist.SavedSynth{};
    saved.attack = 0.005; // 非默认值（验证内嵌副本真的带过来了）
    try std.testing.expect(app.kitLayerAdd(inst, 35, null, ""));
    try std.testing.expect(app.kitLayerAdd(inst, 35, &saved, "subtractive/Kick808"));
    try std.testing.expect(app.kitLayerAdd(inst, 38, null, ""));
    app.commitHistory("添加层");

    // 垫按音高升序；层数/来源/音色
    const kit = app.instruments.items[0].kit.?;
    try std.testing.expectEqual(@as(usize, 2), kit.pads.items.len);
    try std.testing.expectEqual(@as(u8, 35), kit.pads.items[0].pitch);
    try std.testing.expectEqual(@as(u8, 38), kit.pads.items[1].pitch);
    try std.testing.expectEqual(@as(usize, 3), kit.totalLayers());
    try std.testing.expectEqualStrings("subtractive/Kick808", kit.find(35).?.layers.items[1].source_preset);
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), kit.find(35).?.layers.items[1].params.attack.load(.monotonic), 0.0001);

    // 改名 → 撤销 → 重做
    {
        const pad = kit.find(35).?;
        app.allocator.free(pad.name);
        pad.name = try app.allocator.dupe(u8, "大鼓");
        app.commitHistory("改名");
    }
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("", app.instruments.items[0].kit.?.find(35).?.name);
    try std.testing.expect(app.redo());
    try std.testing.expectEqualStrings("大鼓", app.instruments.items[0].kit.?.find(35).?.name);

    // 删层 → 撤销（层回来且参数/来源还原）
    try std.testing.expect(app.kitLayerRemove(inst, 35, 1));
    app.commitHistory("删除层");
    try std.testing.expectEqual(@as(usize, 2), app.instruments.items[0].kit.?.totalLayers());
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 3), app.instruments.items[0].kit.?.totalLayers());
    try std.testing.expectEqualStrings("subtractive/Kick808", app.instruments.items[0].kit.?.find(35).?.layers.items[1].source_preset);

    // 存档导出 → 真实 JSON 往返 → 导入另一个 App
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    const json = try persist.toJson(std.testing.allocator, proj);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kit\"") != null); // 字段确实写出
    var parsed = try persist.fromJson(std.testing.allocator, json);
    defer parsed.deinit();

    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetPatterns(1);
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), app2.instruments.items.len);
    const inst2 = &app2.instruments.items[0];
    try std.testing.expectEqual(model.InstrumentKind.drumkit, inst2.kind);
    const kit2 = inst2.kit.?;
    try std.testing.expectEqual(@as(usize, 2), kit2.pads.items.len);
    try std.testing.expectEqual(@as(usize, 3), kit2.totalLayers());
    try std.testing.expectEqualStrings("大鼓", kit2.find(35).?.name);
    try std.testing.expectEqualStrings("subtractive/Kick808", kit2.find(35).?.layers.items[1].source_preset);
    try std.testing.expectEqual(model.LayerKind.subtractive, kit2.find(35).?.layers.items[1].kind); // 层乐器类型往返
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), kit2.find(35).?.layers.items[1].params.attack.load(.monotonic), 0.0001);

    // 旧存档（无 kind/kit 字段）→ 默认合成器（向后兼容）
    // 注：用**栈上副本**改，不能直接改 proj.instruments——那是共享数组，
    // 改它会盖掉 proj 里的 kit 指针（实测：freeProject 漏释放 → 测试报泄漏）
    var legacy_insts = [_]persist.SavedInstrument{proj.instruments[0]};
    legacy_insts[0].kind = 0;
    legacy_insts[0].kit = .{};
    var legacy = proj;
    legacy.instruments = &legacy_insts;
    var app3 = App{ .allocator = std.testing.allocator };
    defer app3.clips.deinit(app3.allocator);
    defer app3.notes.deinit(app3.allocator);
    defer app3.deinitAll();
    app3.resetPatterns(1);
    app3.resetMixerChannels(default_mixer_channels);
    app3.importProject(legacy);
    try std.testing.expectEqual(model.InstrumentKind.synth, app3.instruments.items[0].kind);
    try std.testing.expect(app3.instruments.items[0].kit == null);
}

test "app: 鼓组——层数上限（全组 16 槽位）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");

    // 16 层全给同一垫（同一音高）：第 17 个被拒绝
    var i: usize = 0;
    while (i < @import("audio.zig").kit_max_layers) : (i += 1) {
        try std.testing.expect(app.kitLayerAdd(inst, 36, null, ""));
    }
    try std.testing.expectEqual(@as(usize, @import("audio.zig").kit_max_layers), app.instruments.items[0].kit.?.totalLayers());
    try std.testing.expect(!app.kitLayerAdd(inst, 36, null, "")); // 满 → 拒绝
    try std.testing.expect(!app.kitLayerAdd(inst, 50, null, "")); // 别的音高也拒绝（槽位是**全组**共享）

    // 删一层后又能加
    try std.testing.expect(app.kitLayerRemove(inst, 36, 0));
    try std.testing.expect(app.kitLayerAdd(inst, 50, null, ""));
}

test "app: 鼓组编辑器——垫重命名（含空名清除）、文本输入提交、来源名更新" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    app.resetHistory("初始状态");
    _ = app.kitLayerAdd(inst, 35, null, "");
    app.commitHistory("添加层");

    // 直接改名 / 清除（空名 = 回退 GM/音名）
    try std.testing.expect(app.kitPadRename(inst, 35, "底鼓"));
    try std.testing.expectEqualStrings("底鼓", app.instruments.items[0].kit.?.find(35).?.name);
    try std.testing.expect(!app.kitPadRename(inst, 35, "底鼓")); // 无变化 → false
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("", app.instruments.items[0].kit.?.find(35).?.name);
    try std.testing.expect(app.redo());
    try std.testing.expectEqualStrings("底鼓", app.instruments.items[0].kit.?.find(35).?.name);

    // 文本输入路径（“名称”字段就地点改）：预填 + 提交
    app.beginRenameKitPad(inst, 35, 10, 10);
    try std.testing.expect(app.text_input.active);
    try std.testing.expectEqual(TextInput.Target.kit_pad_name, app.text_input.target);
    try std.testing.expectEqualStrings("底鼓", app.text_input.text()); // 预填当前名字
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('K');
    app.textInputCommit();
    try std.testing.expectEqualStrings("K", app.instruments.items[0].kit.?.find(35).?.name);

    // 空名提交 = 清除自定义名（回到默认）
    app.beginRenameKitPad(inst, 35, 10, 10);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputCommit();
    try std.testing.expectEqualStrings("", app.instruments.items[0].kit.?.find(35).?.name);

    // 来源预设名（加载/保存预设后由 main 调）；无变化返 false
    try std.testing.expect(app.kitLayerSetSource(inst, 35, 0, "subtractive/Kick808"));
    try std.testing.expectEqualStrings("subtractive/Kick808", app.instruments.items[0].kit.?.find(35).?.layers.items[0].source_preset);
    try std.testing.expect(!app.kitLayerSetSource(inst, 35, 0, "subtractive/Kick808"));
    try std.testing.expect(!app.kitLayerSetSource(inst, 35, 9, "subtractive/X")); // 层越界
    try std.testing.expect(!app.kitLayerSetSource(inst, 60, 0, "subtractive/X")); // 垫不存在
}

test "app: 鼓组编辑器——打开时选中首个已映射垫；删除乐器时关闭/前移" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const a = app.addDrumkit("鼓组 A");
    _ = app.addDrumkit("鼓组 B");
    _ = app.addInstrument("减法合成器");

    // 空套 → 默认 36；非鼓组 → 不开
    app.openDrumKit(2);
    try std.testing.expect(!app.drumkit_win.open);
    app.openDrumKit(a);
    try std.testing.expect(app.drumkit_win.open);
    try std.testing.expectEqual(@as(i32, 36), app.drumkit_win.sel_pitch);
    try std.testing.expectEqual(@as(i32, 0), app.sel.instrument); // 同步选择（试听路由）

    // 有垫 → 选首个（升序最小音高）
    _ = app.kitLayerAdd(a, 44, null, "");
    _ = app.kitLayerAdd(a, 35, null, "");
    app.openDrumKit(a);
    try std.testing.expectEqual(@as(i32, 35), app.drumkit_win.sel_pitch);

    // 改打开 B（空套）→ 默认 36；删除其前的 A → 窗口不关、索引前移
    app.openDrumKit(1);
    try std.testing.expectEqual(@as(i32, 36), app.drumkit_win.sel_pitch);
    app.removeInstrument(0);
    try std.testing.expect(app.drumkit_win.open);
    try std.testing.expectEqual(@as(i32, 0), app.drumkit_win.instrument); // B 前移到 0

    // 删除绑定乐器 → 关闭
    app.removeInstrument(0);
    try std.testing.expect(!app.drumkit_win.open);
}

test "app: 键列模式——每乐器独立（默认钢琴；鼓组默认鼓）；随存档往返" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const syn = app.addInstrument("减法合成器");
    const kit = app.addDrumkit("鼓组");
    try std.testing.expectEqual(model.KeyMode.piano, app.instruments.items[0].key_mode);
    try std.testing.expectEqual(model.KeyMode.drum, app.instruments.items[1].key_mode); // 鼓组默认

    // 按当前选择切换：只动选中乐器
    app.sel.instrument = syn;
    app.setCurrentKeyMode(.drum);
    app.sel.instrument = kit;
    app.setCurrentKeyMode(.piano);
    app.sel.instrument = syn;
    try std.testing.expectEqual(model.KeyMode.drum, app.currentKeyMode());
    app.sel.instrument = kit;
    try std.testing.expectEqual(model.KeyMode.piano, app.currentKeyMode());
    app.sel.instrument = -1;
    try std.testing.expectEqual(model.KeyMode.piano, app.currentKeyMode()); // 无乐器 → 钢琴

    // 存档往返（kind/key_mode/kit 一起走）
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetPatterns(1);
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expectEqual(model.KeyMode.drum, app2.instruments.items[0].key_mode);
    try std.testing.expectEqual(model.KeyMode.piano, app2.instruments.items[1].key_mode);
}

test "app: 预设目标——eql/解析（乐器/鼓组层/失效目标）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    _ = app.kitLayerAdd(inst, 35, null, "");

    const ref = PresetTarget.KitLayerRef{ .instrument = inst, .pitch = 35, .layer = 0 };
    const t1 = PresetTarget{ .kit_layer_replace = ref };
    const t2 = PresetTarget{ .kit_layer_replace = ref };
    const t3 = PresetTarget{ .kit_layer_replace = .{ .instrument = inst, .pitch = 35, .layer = 1 } };
    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(!t1.eql(t3));
    try std.testing.expect(!t1.eql(PresetTarget{ .instrument = inst }));
    const ta = PresetTarget{ .instrument = 1 };
    const tb = PresetTarget{ .instrument = 2 };
    try std.testing.expect(ta.eql(PresetTarget{ .instrument = 1 }));
    try std.testing.expect(!ta.eql(tb));

    // 解析：层目标 → 层参数指针；乐器目标（鼓组）→ null；越界 → null
    const lp = app.resolvePresetTarget(t1).?;
    try std.testing.expect(lp == app.instruments.items[0].kit.?.find(35).?.layers.items[0].params);
    try std.testing.expect(app.resolvePresetTarget(PresetTarget{ .instrument = inst }) == null);
    try std.testing.expect(app.resolvePresetTarget(PresetTarget{ .kit_layer_replace = .{ .instrument = 99, .pitch = 35, .layer = 0 } }) == null);

    // 目标所需插件：鼓组层 → 减法（层就是减法合成器音色）；
    // 鼓组乐器本体 → drumkit（将来“整组套预设”）；普通减法乐器 → subtractive
    try std.testing.expectEqualStrings("drumkit", app.presetTargetPlugin(PresetTarget{ .instrument = inst }));
    try std.testing.expectEqualStrings("subtractive", app.presetTargetPlugin(PresetTarget{ .kit_layer_replace = ref }));
    const syn2 = app.addInstrument("减法合成器");
    try std.testing.expectEqualStrings("subtractive", app.presetTargetPlugin(PresetTarget{ .instrument = syn2 }));

    // 层被删后目标失效（合成器窗口自动关闭的依据）
    _ = app.kitLayerRemove(inst, 35, 0);
    try std.testing.expect(app.resolvePresetTarget(t1) == null);
}

test "app: 预设面板分类可选性——统一面板（任意入口可选任意已实装插件；层不列鼓组）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const syn = app.addInstrument("减法合成器");
    const kit = app.addDrumkit("鼓组");

    // replace + **乐器本体**：面板已统一——减法与鼓组都可选（点别的插件 = 顺带换插件）；
    // 未实装插件（fm/vst3）不可选
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, preset_mod.plugin_subtractive));
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, preset_mod.plugin_drumkit));
    try std.testing.expect(!app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, "fm"));
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = kit } }, preset_mod.plugin_drumkit));

    // replace + **鼓组层**：仅减法（层目前只支持减法；鼓组禁自嵌套）
    const layer_ref = PresetTarget.KitLayerRef{ .instrument = kit, .pitch = 35, .layer = 0 };
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .kit_layer_replace = layer_ref } }, preset_mod.plugin_subtractive));
    try std.testing.expect(!app.presetCategorySelectable(.{ .replace = .{ .kit_layer_replace = layer_ref } }, preset_mod.plugin_drumkit));

    // 新建/更换乐器：减法 + 鼓组（已实装）；fm/vst3 不可选
    try std.testing.expect(app.presetCategorySelectable(.create_instrument, preset_mod.plugin_subtractive));
    try std.testing.expect(app.presetCategorySelectable(.create_instrument, preset_mod.plugin_drumkit));
    try std.testing.expect(!app.presetCategorySelectable(.create_instrument, "fm"));
    try std.testing.expect(!app.presetCategorySelectable(.{ .change_instrument = syn }, "vst3"));

    // 鼓垫加乐器：仅减法（**禁止自嵌套**——鼓组不可选）
    const layer_intent = PresetIntent{ .create_kit_layer = .{ .instrument = kit, .pitch = 35 } };
    try std.testing.expect(app.presetCategorySelectable(layer_intent, preset_mod.plugin_subtractive));
    try std.testing.expect(!app.presetCategorySelectable(layer_intent, preset_mod.plugin_drumkit));
}

test "app: 更换乐器——synth⇄鼓组（保留属性、可撤销/重做）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addInstrument("减法合成器");
    app.instruments.items[@intCast(inst)].volume = 0.42;
    app.resetHistory("初始状态");

    // 同类型 → false（无操作）
    try std.testing.expect(!app.changeInstrumentKind(@intCast(inst), .synth, true));

    // 减法 → 鼓组：建空套鼓 + 键列模式切鼓组；名字/音量保留
    try std.testing.expect(app.changeInstrumentKind(@intCast(inst), .drumkit, true));
    {
        const it = &app.instruments.items[@intCast(inst)];
        try std.testing.expectEqual(model.InstrumentKind.drumkit, it.kind);
        try std.testing.expect(it.kit != null);
        try std.testing.expectEqual(model.KeyMode.drum, it.key_mode);
        try std.testing.expectApproxEqAbs(@as(f32, 0.42), it.volume, 0.001);
        try std.testing.expectEqualStrings("减法合成器", it.name);
    }

    // 加一层后换回减法：套鼓被释放；键列模式回钢琴；撤销 → 套鼓与层、类型/模式都回来
    _ = app.kitLayerAdd(inst, 35, null, "subtractive/Kick");
    app.commitHistory("添加层");
    try std.testing.expect(app.changeInstrumentKind(@intCast(inst), .synth, true));
    try std.testing.expect(app.instruments.items[@intCast(inst)].kit == null);
    try std.testing.expectEqual(model.KeyMode.piano, app.instruments.items[@intCast(inst)].key_mode);
    try std.testing.expect(app.undo()); // → 鼓组 + 1 层（键列模式也回到鼓组）
    {
        const it = &app.instruments.items[@intCast(inst)];
        try std.testing.expectEqual(model.InstrumentKind.drumkit, it.kind);
        try std.testing.expectEqual(model.KeyMode.drum, it.key_mode);
        try std.testing.expectEqual(@as(usize, 1), it.kit.?.totalLayers());
        try std.testing.expectEqualStrings("subtractive/Kick", it.kit.?.find(35).?.layers.items[0].source_preset);
        try std.testing.expectEqual(model.LayerKind.subtractive, it.kit.?.find(35).?.layers.items[0].kind);
    }
    try std.testing.expect(app.undo()); // → 鼓组、无层
    try std.testing.expect(app.undo()); // → 初始（减法、无套鼓）
    {
        const it = &app.instruments.items[@intCast(inst)];
        try std.testing.expectEqual(model.InstrumentKind.synth, it.kind);
        try std.testing.expect(it.kit == null);
    }
    // 重做两次 → 又回到鼓组 + 一层
    try std.testing.expect(app.redo());
    try std.testing.expect(app.redo());
    {
        const it = &app.instruments.items[@intCast(inst)];
        try std.testing.expectEqual(model.InstrumentKind.drumkit, it.kind);
        try std.testing.expectEqual(@as(usize, 1), it.kit.?.totalLayers());
    }
}

test "app: 鼓组——清空后的无名空垫自动移除（有名垫保留）；蓝点/强调条语义" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    app.resetHistory("初始状态");

    // 无名垫：加两层，删一层 → 还在；删最后一层 → 垫本身也没信息了，移除
    try std.testing.expect(app.kitLayerAdd(inst, 35, null, ""));
    try std.testing.expect(app.kitLayerAdd(inst, 35, null, ""));
    app.commitHistory("添加层");
    try std.testing.expect(app.instruments.items[0].kit.?.isMapped(35));
    try std.testing.expect(app.kitLayerRemove(inst, 35, 0));
    app.commitHistory("删除层");
    try std.testing.expect(app.instruments.items[0].kit.?.find(35) != null); // 还剩一层
    try std.testing.expect(app.kitLayerRemove(inst, 35, 0));
    app.commitHistory("删除层");
    try std.testing.expect(app.instruments.items[0].kit.?.find(35) == null); // 无名空垫被移除
    try std.testing.expect(!app.instruments.items[0].kit.?.isMapped(35));

    // 有名垫：清空层后保留（名字是用户信息）；但 isMapped 为 false（蓝点/强调条熄）
    try std.testing.expect(app.kitLayerAdd(inst, 38, null, ""));
    try std.testing.expect(app.kitPadRename(inst, 38, "小军鼓"));
    app.commitHistory("重命名鼓垫");
    try std.testing.expect(app.instruments.items[0].kit.?.isMapped(38));
    try std.testing.expect(app.kitLayerRemove(inst, 38, 0));
    app.commitHistory("删除层");
    try std.testing.expect(app.instruments.items[0].kit.?.find(38) != null);
    try std.testing.expectEqualStrings("小军鼓", app.instruments.items[0].kit.?.find(38).?.name);
    try std.testing.expect(!app.instruments.items[0].kit.?.isMapped(38));

    // 有名垫清成空名 → 此时无层无名 → 一并移除
    try std.testing.expect(app.kitPadRename(inst, 38, ""));
    try std.testing.expect(app.instruments.items[0].kit.?.find(38) == null);

    // 撤销链完整回放：最后一步撤销 → 名字/垫回来；一直撤销到底 → 套鼓回到空（但套鼓还在）
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("小军鼓", app.instruments.items[0].kit.?.find(38).?.name);
    try std.testing.expect(app.undo()); // 撤销“删除层” → 层 + 蓝点回来
    try std.testing.expect(app.instruments.items[0].kit.?.isMapped(38));
}

test "app: 套鼓快照——导出/载入/释放（自包含副本；替换现有内容）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const a = app.addDrumkit("鼓组 A");
    _ = app.kitLayerAdd(a, 35, null, "subtractive/Kick");
    _ = app.kitPadRename(a, 35, "底鼓");
    _ = app.kitLayerAdd(a, 44, null, "");

    // 导出快照（深拷贝）
    const snap = app.exportKitForSave(@intCast(a)).?;
    defer app.freeSavedKit(&snap);
    try std.testing.expectEqual(@as(usize, 2), snap.pads.len);
    try std.testing.expectEqual(@as(u32, 35), snap.pads[0].pitch);
    try std.testing.expectEqualStrings("底鼓", snap.pads[0].name);
    try std.testing.expectEqualStrings("subtractive/Kick", snap.pads[0].layers[0].source_preset);

    // 载入到另一个套（替换旧内容：旧墴 38 消失，新墴 35/44 到位）
    const b = app.addDrumkit("鼓组 B");
    _ = app.kitLayerAdd(b, 38, null, "subtractive/Snare");
    try std.testing.expect(app.loadKitInto(@intCast(b), &snap));
    {
        const kb = app.instruments.items[@intCast(b)].kit.?;
        try std.testing.expect(kb.find(38) == null);
        try std.testing.expectEqualStrings("底鼓", kb.find(35).?.name);
        try std.testing.expect(kb.isMapped(44));
        // 层参数是真副本（改源不影响目标——地址不同）
        try std.testing.expect(kb.find(35).?.layers.items[0].params != app.instruments.items[@intCast(a)].kit.?.find(35).?.layers.items[0].params);
    }

    // 空快照 = 清空（不变式：总层数归零）
    try std.testing.expect(app.loadKitInto(@intCast(b), &persist.SavedDrumKit{}));
    try std.testing.expectEqual(@as(usize, 0), app.instruments.items[@intCast(b)].kit.?.totalLayers());

    // 非鼓组乐器也能载入（先建空 kit）
    const syn = app.addInstrument("减法合成器");
    try std.testing.expect(app.loadKitInto(@intCast(syn), &snap));
    try std.testing.expectEqual(@as(usize, 2), app.instruments.items[@intCast(syn)].kit.?.pads.items.len);
    // 注：kind 未变（仍是 synth）——载入套鼓数据不等于换类型
}

test "app: 关联预设名——设置/读取/预填/存档往返/撤销恢复" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const syn = app.addInstrument("减法合成器");
    const kit = app.addDrumkit("鼓组");
    app.resetHistory("初始状态");

    // 初始为空；设置/读取
    try std.testing.expectEqualStrings("", app.instrumentPresetName(syn));
    try std.testing.expect(app.setInstrumentPresetName(@intCast(syn), "Kick808"));
    try std.testing.expectEqualStrings("Kick808", app.instrumentPresetName(syn));
    try std.testing.expect(!app.setInstrumentPresetName(@intCast(syn), "Kick808")); // 无变化
    app.commitHistory("加载预设");
    try std.testing.expect(app.setInstrumentPresetName(@intCast(syn), "Snare"));
    app.commitHistory("加载预设");

    // 预填名：乐器本体 / 鼓组整组 / 鼓组层（取来源名的名字部分）
    try std.testing.expectEqualStrings("Snare", app.presetPrefillName(.{ .params = .{ .instrument = syn } }));
    try std.testing.expectEqualStrings("Snare", app.presetPrefillName(.{ .kit = syn }));
    _ = app.kitLayerAdd(kit, 35, null, "subtractive/Kick808");
    const layer_ref = PresetTarget.KitLayerRef{ .instrument = kit, .pitch = 35, .layer = 0 };
    try std.testing.expectEqualStrings("Kick808", app.presetPrefillName(.{ .params = .{ .kit_layer_replace = layer_ref } }));
    try std.testing.expectEqualStrings("subtractive/Kick808", app.kitLayerSource(kit, 35, 0));
    try std.testing.expectEqualStrings("", app.kitLayerSource(kit, 36, 0)); // 无垫
    try std.testing.expectEqualStrings("", app.kitLayerSource(kit, 35, 9)); // 层越界

    // 撤销 → 名字回到当时的快照（“加载 Snare”前是 Kick808）
    try std.testing.expect(app.undo());
    try std.testing.expectEqualStrings("Kick808", app.instrumentPresetName(syn));
    try std.testing.expect(app.redo());
    try std.testing.expectEqualStrings("Snare", app.instrumentPresetName(syn));

    // 存档往返（工程文件里也带预设名）
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetPatterns(1);
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expectEqualStrings("Snare", app2.instrumentPresetName(0));
}

test "app: 保存对话框预填——全选当前名（输入即替换）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const syn = app.addInstrument("减法合成器");
    _ = app.setInstrumentPresetName(@intCast(syn), "Kick808");

    const src = PresetSaveSource{ .params = .{ .instrument = syn } };
    app.beginRenamePreset(100, 100, src, app.presetPrefillName(src));
    try std.testing.expect(app.text_input.active);
    try std.testing.expectEqualStrings("Kick808", app.text_input.text());
    try std.testing.expectEqual(@as(?usize, 0), app.text_input.sel_anchor); // 全选
    // 无预填时：空 + 无选区
    app.beginRenamePreset(100, 100, src, "");
    try std.testing.expectEqualStrings("", app.text_input.text());
    try std.testing.expect(app.text_input.sel_anchor == null);
}

test "app: 预设文件重命名/删除——文本输入排队 + 删除确认状态" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 假库：一个分类 + 两个预设名（deinitAll 会释放 preset_lib）
    {
        var cat = preset_mod.Category{ .name = try app.allocator.dupe(u8, preset_mod.plugin_subtractive) };
        try cat.presets.append(app.allocator, try app.allocator.dupe(u8, "Kick808"));
        try cat.presets.append(app.allocator, try app.allocator.dupe(u8, "Snare"));
        try app.preset_lib.categories.append(app.allocator, cat);
    }

    // 重命名：预填旧名 + 全选；提交 → 排队 `.rename`（旧名在 aux，新名在 buf）
    app.beginRenamePresetFile(0, 0, 10, 10);
    try std.testing.expect(app.text_input.active);
    try std.testing.expectEqual(TextInput.Target.preset_rename, app.text_input.target);
    try std.testing.expectEqualStrings("Kick808", app.text_input.text());
    try std.testing.expectEqual(@as(?usize, 0), app.text_input.sel_anchor);
    try std.testing.expectEqualStrings("Kick808", app.text_input.aux_buf[0..app.text_input.aux_len]);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('K');
    app.textInputAppend('9');
    app.textInputCommit();
    try std.testing.expect(app.pending_preset != null);
    switch (app.pending_preset.?) {
        .rename => |r| {
            try std.testing.expectEqual(@as(usize, 0), r.cat);
            try std.testing.expectEqualStrings("Kick808", r.old_buf[0..r.old_len]);
            try std.testing.expectEqualStrings("K9", r.new_buf[0..r.new_len]);
        },
        else => return error.TestUnexpectedResult,
    }
    app.pending_preset = null;

    // 越界（分类/行）→ 不开输入框
    app.beginRenamePresetFile(9, 0, 10, 10);
    try std.testing.expect(!app.text_input.active);
    app.beginRenamePresetFile(0, 9, 10, 10);
    try std.testing.expect(!app.text_input.active);

    // 删除：弹确认态（modal + delete_req）；未确认前不排队
    app.setDeletePrompt(0, "Snare");
    try std.testing.expectEqual(ModalKind.preset_delete, app.modal.?);
    try std.testing.expectEqualStrings("Snare", app.delete_req.?.name[0..app.delete_req.?.name_len]);
    try std.testing.expect(app.pending_preset == null);
}

test "app: 键盘微调选中音符——半音/八度/网格/小节 + 整组钳制（复用拖动版语义）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);

    // 未选中 → false、不动
    try app.notes.append(app.allocator, .{ .step = 10, .len = 4, .pitch = 60, .pattern = 0 });
    try std.testing.expect(!app.nudgeSelectedNotes(0, 1));
    try std.testing.expectEqual(@as(i32, 60), app.notes.items[0].pitch);

    // 选中两个音（step 10/13、pitch 60/64）：半音上移
    app.notes.items[0].selected = true;
    try app.notes.append(app.allocator, .{ .step = 13, .len = 4, .pitch = 64, .pattern = 0, .selected = true });
    try std.testing.expect(app.nudgeSelectedNotes(0, 1));
    try std.testing.expectEqual(@as(i32, 61), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 65), app.notes.items[1].pitch);

    // 上移八度 → 73/77
    try std.testing.expect(app.nudgeSelectedNotes(0, 12));
    try std.testing.expectEqual(@as(i32, 73), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 77), app.notes.items[1].pitch);

    // 大幅上移（60 半音）：顶端 77 碰 127 → 位移钳到 +50 → 123/127
    try std.testing.expect(app.nudgeSelectedNotes(0, 60));
    try std.testing.expectEqual(@as(i32, 123), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 127), app.notes.items[1].pitch);
    // 顶格后再上移 → 整组停
    try std.testing.expect(!app.nudgeSelectedNotes(0, 1));
    try std.testing.expectEqual(@as(i32, 123), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 127), app.notes.items[1].pitch);

    // 下端钳制：最低音 0 时整组下移无效
    app.notes.items[0].pitch = 0;
    app.notes.items[1].pitch = 5;
    try std.testing.expect(!app.nudgeSelectedNotes(0, -1));
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 5), app.notes.items[1].pitch);
    // 部分下移：3/5 下移 9 → 位移钳到 -3 → 0/2
    app.notes.items[0].pitch = 3;
    app.notes.items[1].pitch = 5;
    try std.testing.expect(app.nudgeSelectedNotes(0, -9));
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 2), app.notes.items[1].pitch);

    // 左移钳制：最左音 step 10、另一音 13；左移 8 → 位移 -8 → 2/5
    try std.testing.expect(app.nudgeSelectedNotes(-8, 0));
    try std.testing.expectEqual(@as(i32, 2), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 5), app.notes.items[1].step);
    // 继续左移 8 → 最左音贴 0（位移 -2）→ 0/3
    try std.testing.expect(app.nudgeSelectedNotes(-8, 0));
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 3), app.notes.items[1].step);
    // 再左移 → 整组停
    try std.testing.expect(!app.nudgeSelectedNotes(-8, 0));
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].step);

    // 右移一小节（96 步）无上限
    try std.testing.expect(app.nudgeSelectedNotes(model.units_per_whole, 0));
    try std.testing.expectEqual(@as(i32, 96), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 99), app.notes.items[1].step);
}

test "app: 键盘粗移（Ctrl：全有或全无）——拍位/级数不漂移" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);

    // 用户场景：最左音在第一小节**第三拍**（step 48）——Ctrl+左（一小节）
    // 会把它压到 0（第一拍）→ 必须**整组拒不动**
    try app.notes.append(app.allocator, .{ .step = 48, .len = 4, .pitch = 60, .pattern = 0, .selected = true });
    try app.notes.append(app.allocator, .{ .step = 60, .len = 4, .pitch = 64, .pattern = 0, .selected = true });
    try std.testing.expect(!app.nudgeSelectedNotesExact(-model.units_per_whole, 0));
    try std.testing.expectEqual(@as(i32, 48), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 60), app.notes.items[1].step);

    // 整体绰绰有余（≥ 一小节）→ 完整位移
    app.notes.items[0].step = 100;
    app.notes.items[1].step = 120;
    try std.testing.expect(app.nudgeSelectedNotesExact(-model.units_per_whole, 0));
    try std.testing.expectEqual(@as(i32, 4), app.notes.items[0].step);
    try std.testing.expectEqual(@as(i32, 24), app.notes.items[1].step);
    // 再左移一小节 → 抭不动 → 拒（4/24 保持拍内位置）
    try std.testing.expect(!app.nudgeSelectedNotesExact(-model.units_per_whole, 0));
    try std.testing.expectEqual(@as(i32, 4), app.notes.items[0].step);

    // 右移一小节无上限
    try std.testing.expect(app.nudgeSelectedNotesExact(model.units_per_whole, 0));
    try std.testing.expectEqual(@as(i32, 100), app.notes.items[0].step);

    // 八度同理：高音 120 + 12 = 132 越顶 → **整组拒**（部分鉗制会变成 +7——非整八度，级数漂移）
    app.notes.items[0].pitch = 108;
    app.notes.items[1].pitch = 120;
    try std.testing.expect(!app.nudgeSelectedNotesExact(0, 12));
    try std.testing.expectEqual(@as(i32, 108), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 120), app.notes.items[1].pitch);
    // 完整八度可行：96/108 + 12 → 108/120
    app.notes.items[0].pitch = 96;
    app.notes.items[1].pitch = 108;
    try std.testing.expect(app.nudgeSelectedNotesExact(0, 12));
    try std.testing.expectEqual(@as(i32, 108), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 120), app.notes.items[1].pitch);

    // 下端：最低音 5 + (-12) → 越底 → 拒；换 15/30 → 3/18
    app.notes.items[0].pitch = 5;
    app.notes.items[1].pitch = 20;
    try std.testing.expect(!app.nudgeSelectedNotesExact(0, -12));
    try std.testing.expectEqual(@as(i32, 5), app.notes.items[0].pitch);
    app.notes.items[0].pitch = 15;
    try std.testing.expect(app.nudgeSelectedNotesExact(0, -12));
    try std.testing.expectEqual(@as(i32, 3), app.notes.items[0].pitch);
    try std.testing.expectEqual(@as(i32, 8), app.notes.items[1].pitch);

    // 未选中 / 零位移 → false
    app.clearNoteSelection();
    try std.testing.expect(!app.nudgeSelectedNotesExact(0, 12));
    try std.testing.expect(!app.nudgeSelectedNotesExact(0, 0));
}