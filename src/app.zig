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
const ivstevents = @import("zig_vst3").pluginterfaces.vst.ivstevents;
const midi = @import("midi.zig");
// 0.17：`@cImport` 已移除——改用 `zig translate-c` 预生成的绑定（免网络、免构建期翻译）
const ma = @import("c/miniaudio.zig");
const eq = @import("eq.zig");
const fx = @import("effects.zig");
const plugin_db = @import("plugin_db.zig");
const vst_host = @import("vst_host.zig");
const preset_mod = @import("preset.zig");
const wav = @import("wav.zig"); // 导出音频（24-bit PCM WAV 写出器）
const audio_import = @import("audio_import.zig"); // P2：异步导入（单 worker）

pub const Clip = model.Clip;
pub const Note = model.Note;
pub const Instrument = model.Instrument;

pub const NoteHitMode = model.NoteHitMode;

/// 界面布局（可调参数，持久状态）
pub const Layout = struct {
    left_w: i32 = 0,
    mid_w: i32 = 0,
    initialized: bool = false,
    /// 三栏区域几何（每帧布局时写回；拖入文件的区域命中用）
    body_y: i32 = 0,
    body_h: i32 = 0,
    /// 播放列表面板矩形（x/w）——与绘制同一套坐标（避免两处漂移）
    playlist_x: i32 = 0,
    playlist_w: i32 = 0,
    /// 样式面板矩形（x/w）
    patterns_x: i32 = 0,
    patterns_w: i32 = 0,

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
pub const FileAction = enum { new, open, save, save_as, import_midi, export_midi, export_wav, import_json, export_json };

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
/// 音频资产（会话态；解码结果 + 波形峰值。工程切换时在**设备暂停窗口**统一释放）
pub const AudioAsset = struct {
    /// 绝对路径（加载时记录）
    path: []u8,
    /// 不可变采样数据（发布给音频线程的指针来源；本结构不移动）
    data: audio.SampleData,
    /// 波形峰值分桶（混合声道 min/max；UI 绘制用）
    peaks: []Peak,
    /// 每桶帧数
    peak_frames: u32,

    /// 峰值类型**单一真源**在 `audio_import.Peak`（异步导入的 worker 也要写同一布局）
    pub const Peak = audio_import.Peak;
};

/// 音频样式（编号 = 下标；与音符样式对称：**通道/增益共享给全部片段实例**）
pub const AudioStyle = struct {
    name: []u8,
    /// 绝对路径（会话态；存档转相对工程目录）
    path: []u8,
    /// 资产下标（`audio_assets`；-1 = 未加载/失败）
    asset: i32 = -1,
    channel: i32 = 0,
    gain: f32 = 1.0,
    /// 播放速度（1 = 原速；v1 变速变调）
    speed: f32 = 1.0,
    /// **运行时**（不入存档）：读文件头得到的引擎帧数。
    /// 异步导入未完成（`asset == -1`）时，片段长度/波形宽度用它算
    frames_hint: u64 = 0,
};

/// 退役中的音频播放表（音频线程可能仍在读旧指针；帧末倒计时后释放）
pub const RetiredAudioTable = struct { tbl: *const audio.AudioTable, countdown: u8 };

/// 波形窗口试听（UI 侧状态；音频线程经 `Params.preview_*` 播放并回写游标）
pub const PreviewState = struct {
    asset: i32 = -1,
    channel: u16 = 0,
    gain: f32 = 1.0,
    pos: i32 = -1,
    playing: bool = false,
    /// 用户意图（播放中或暂停中）；**暂停/停止时不从音频线程回读游标**（否则暂停按钮
    /// 永远弹不回播放——实测 bug：音频线程仍报 ≥0 的暂停点）
    active: bool = false,
    /// 拖拽定位中（松手才真正跳转；拖拽期间音频照旧播、不回读游标）
    seeking: bool = false,
    /// 循环试听（波形窗按钮切换；**默认关**——用户拍板）
    loop: bool = false,
};

/// 音频资产解码目标采样率（引擎采样率未知时兜底——实际以 `params.sample_rate` 为准）
const audio_fallback_rate = 48000;

/// 波形窗口（音频片段 / 鼓组采样器层：同一面板，见 `docs/audio-files.md` §7）
/// 波形窗口目标：鼓组采样器层
pub const WaveLayerRef = struct { instrument: i32, pitch: u8, layer: usize };

pub const WaveWindow = struct {
    open: bool = false,
    x: i32 = 420,
    y: i32 = 150,
    w: i32 = 580,
    h: i32 = 260,
    z: i32 = 25,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    /// 目标：音频片段下标（互斥于 layer）
    clip: ?usize = null,
    /// 目标：鼓组采样器层
    layer: ?WaveLayerRef = null,
    /// 目标：音频样式（双击样式列表的“♪”行；只是展示/试听——trim 以片段为准）
    style: ?usize = null,
    /// trim 端点拖动中的边（0 = 无，1 = 左端，2 = 右端）——**必须持久**：
    /// 用每帧局部变量的话只有按下那一帧会更新，拖不动（实测 bug：“一次只能拖一点点”）
    trim_drag_side: u8 = 0,
};

pub const HistoryState = struct {
    /// 操作名（如“放置音符”；堆分配，由 App 管理生命周期）
    label: []u8,
    notes: []model.Note,
    clips: []model.Clip,
    /// 乐器快照（name 为堆分配副本；synth 为值快照）
    instruments: []persist.SavedInstrument,
    /// 调音台通道快照（含效果链；条数 = 快照时的通道数）
    mixer: []persist.SavedMixerChannel,
    /// 音频样式快照（绝对路径；下标 = 片段 `audio_style` 引用）
    audio_styles: []persist.SavedAudioStyle,
    /// 样式名字快照（每项堆分配；长度 = 样式数）——重命名/增删样式也要能撤销
    /// （只存 `pattern_count` 不够：`resetPatterns` 会重建默认名，自定义名丢失）
    pattern_names: [][]u8,
    /// 轨道名字快照（每项堆分配；长度 = 轨道数）——增删/重命名轨道也要能撤销
    track_names: [][]u8,
    /// 静音轨道快照（排序行号列表；静态释放）——静音切换也要能撤销
    track_muted: []i32,
    bpm: i32 = 120,
    time_num: i32 = 4,
    time_den: i32 = 4,
    steps_per_bar: i32 = model.units_per_whole,
    /// **运行时**插件参数增量（不持久化；读档/旧条目为空 → 自动回落整块状态恢复）。
    /// `old` = 本步开始前的值、`new` = 本步结束值；同槽同参折叠为一条。
    /// **按 `ref` 排序**（同槽连续）——应用侧按槽取子切片
    param_edits: []ParamEditRec = &.{},
    /// 本步内出现过该槽的**结构性**信号（setDirty/restart/溢出/无缓存）→ 禁参数回放
    structural_refs: []PluginSlotRef = &.{},
};

/// 插件槽引用（历史参数增量的目标）
pub const PluginSlotRef = struct {
    kind: enum { instrument, fx, kit_layer },
    /// instrument / kit_layer：乐器下标；fx：通道下标
    a: u16 = 0,
    /// instrument 恒 0；fx：槽位；kit_layer：**展平层槽位**（`App.kitLayerSlot`）
    b: u16 = 0,
};

/// 一条插件参数增量（撤销“参数回放”的记录单元）
pub const ParamEditRec = struct {
    ref: PluginSlotRef,
    param_id: u32,
    old: f64,
    new: f64,
};

/// 插件状态应用计划（撤销/重做/跳转逐槽决定；商 DAW 式：旋钮级走参数回放）
pub const ApplyPlan = union(enum) {
    /// 整块重放（pending_state → 帧末 setState；VSTi 可唤醒幽灵声部 → 后续 panic）
    full,
    /// 状态未变：不碰实例
    skip,
    /// 参数增量回放（setParam 免锁；无 setState、无 panic、不断音）
    replay: ReplayJob,
};

pub const ReplayJob = struct {
    recs: []const ParamEditRec,
    /// true = 回放 old（撤销/往回跳）；false = 回放 new（重做/往前跳）
    backward: bool,
};

/// 脏确认流程的**目标动作**（确认框按钮相同，但“保存后”要执行不同的事）
pub const PendingIntent = enum {
    /// 保存后退出程序
    quit,
    /// 保存后打开另一个工程（用户已在系统对话框里选了文件）
    open,
    /// 保存后新建空工程
    new,
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
/// 浮动窗口种类（绘制序列表与插件子窗口裁切共用）
pub const WinKind = enum { rack, synth, mixer, effect, drumkit, help, settings, plugin_mgr };

/// 浮动窗口“绘制顺序 + 最终矩形”（`main.drawApp` 逐帧填写）
pub const WinDraw = struct { kind: WinKind, x: i32, y: i32, w: i32, h: i32 };

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
    /// 搜索过滤串（右栏；子串匹配、大小写不敏感；空 = 不过滤）。
    /// 与编辑中的 `text_input`（target = `.preset_search`）每帧同步。
    filter_buf: [40]u8 = @splat(0),
    filter_len: usize = 0,
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
    /// 混音台「＋ 效果器」：选中即在通道末尾加该效果（内置或 VST3 插件）
    create_effect: usize,
    /// 效果器面板「预设 ▾」/右键「更换效果器…」：替换指定效果槽
    replace_effect: EffectRef,

    /// 鼓垫引用（乐器槽位 + 垫音高）
    pub const KitPadRef = struct { instrument: i32, pitch: u8 };
};

/// 面板里选中的条目：置顶默认伪预设 / 第 N 个预设文件
pub const PresetChoice = union(enum) { default, preset: usize };

/// 预设“保存为…”的**源**：参数槽（乐器本体/鼓组层）/ **整组套鼓** / 效果槽
pub const PresetSaveSource = union(enum) {
    params: PresetTarget,
    /// 整组套鼓（乐器槽位；plugin = drumkit）
    kit: i32,
    /// 效果槽（内置 → `fx_*` 单效果预设；插件 → vst3 状态预设）
    effect: EffectRef,
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
    /// 删除**非空样式** → 确认（删除/取消）——空样式直接删
    pattern_delete,
    /// 清空**非空轨道**的片段 → 确认（清空/取消）——空轨道直接提示
    track_clear,
    /// 删除**轨道行** → 确认（删除/取消）——空行直接删（下方整体上移）
    track_delete,
    /// 旧版存档（v1–v3 JSON）打开 → “备份并升级”确认（③ 迁移流程）
    save_upgrade,
};

/// 待确认的结构删除（`struct_del_req`；`modal == .pattern_delete/.track_clear/.track_delete` 时有效）
pub const DelReq = union(enum) { pattern: usize, track: usize, track_row: usize };

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
    /// SONG（播放全曲）还是 PAT（播放当前样式）——**默认 SONG**（用户拍板；
    /// 点音符样式/钢琴卷帘会自动切到 PAT 编辑视图）
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
    /// 纵向滚动补间：目标（滚轮只设目标；`scroll` 逐帧逼近；拖滚动条写 `scroll` → 被采纳为即时）
    scroll_target: i32 = 0,
    /// 上一帧末 `scroll` 快照（<0 = 未初始化；检测外部改动）
    scroll_anim_last: i32 = -1,
    /// 轨道行高补间：目标 / 事件时鼠标偏移（相对轨道区顶）/ 上一帧末快照（<0 = 未初始化）
    track_h_target: i32 = 44,
    track_h_anchor_off: i32 = 0,
    track_h_anim_last: i32 = -1,
    /// 视角跟随播放游标（工具栏开关；主动操作优先、停手且播放中则恢复）
    follow_playhead: bool = false,
    /// 可见行数快照（视图每帧写入；行轴无限延伸——悬空时视口下方的行也是真行）。
    /// 供右键菜单/重命名等边界守卫读用（滚动越出地图后行号可以超出推导跨度）
    view_rows: i32 = 128,
    /// 轨道内容区几何（每帧绘制写回；拖入文件的落点换算用）
    geom: struct {
        lane_x: i32 = 0,
        tracks_y: i32 = 0,
        view_w: i32 = 0,
        tracks_h: i32 = 0,
        track_h: i32 = 1,
    } = .{},
    /// 横向缩放（屏幕像素 / 内容像素）
    zoom: f32 = 1.0,
    /// **缩放补间目标**（Ctrl+滚轮只设目标；`zoom` 逐帧平滑逼近——滚轮离散跳变生硬）
    zoom_target: f32 = 1.0,
    /// 补间锚点：最近滚轮事件时的鼠标偏移（相对内容区左缘；补间每步锚定）
    zoom_anchor_off: i32 = 0,
    /// 上一帧末 `zoom` 快照（检测“他处改变 zoom”→ 采纳为补间目标；<0 = 未初始化）
    zoom_anim_last: f32 = -1,
    /// 量化/吸附网格档位（`model.snap_denoms` 下标；**与钢琴卷帘独立**）
    snap: i32 = 3, // 默认 1/8（`snap_denoms` 下标 3）
    /// 吸附网格下拉选单：展开中
    snap_menu_open: bool = false,
    /// 叠放轮换：上一次按下命中的片段（双击打开用它——第一次按下的那个；
    /// 第二次按下时命中的可能已被轮换换人）
    prev_click_clip: ?usize = null,
    /// 绘制排序暂存（层序下标表；跨帧复用）
    draw_order: std.ArrayListUnmanaged(usize) = .empty,

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
    /// 拉伸基准：原采样内起点（音频片段左缘拉伸用；按下时快照）
    resize_orig_trim: i32 = 0,
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
    /// 锚片段（PAT ⇄ SONG 位置映射）——规则：
    /// 1) 双击片段打开 → 该片段的值快照；
    /// 2) 点样式/换样式打开 → **离游标最近的该样式片段**（v2“窗随游标”；无片段 → null）；
    /// 3) 关窗再开（同一样式）→ 保留原快照（游标停原位）；
    /// 无锚 → 映射退化为 0；失效快照自动退化（见 `patOriginClip`）。
    origin: ?model.Clip = null,
    /// 音高行高（像素；□ 缺口缩放）——默认 16：视口内行数较少、内容更大
    key_h: i32 = 16,
    /// 绘制排序暂存（音符层序下标表；跨帧复用）
    draw_order: std.ArrayListUnmanaged(usize) = .empty,
    /// 纵向滚动（像素）
    scroll: i32 = 0,
    /// 横向滚动（内容像素）
    scroll_x: i32 = 0,
    /// 纵向滚动补间：目标 / 上一帧末快照（<0 = 未初始化；拖滚动条写 `scroll` → 被采纳为即时）
    scroll_target: i32 = 0,
    scroll_anim_last: i32 = -1,
    /// 音高行高补间：目标 / 事件时鼠标偏移（相对网格顶）/ 上一帧末快照（<0 = 未初始化）
    key_h_target: i32 = 16,
    key_h_anchor_off: i32 = 0,
    key_h_anim_last: i32 = -1,
    /// 横向缩放（屏幕像素 / 内容像素）
    zoom: f32 = 1.0,
    /// **缩放补间目标**（Ctrl+滚轮只设目标；`zoom` 逐帧平滑逼近——滚轮离散跳变生硬）
    zoom_target: f32 = 1.0,
    /// 补间锚点：最近滚轮事件时的鼠标偏移（相对内容区左缘；补间每步锚定）
    zoom_anchor_off: i32 = 0,
    /// 上一帧末 `zoom` 快照（检测“他处改变 zoom”→ 采纳为补间目标；<0 = 未初始化）
    zoom_anim_last: f32 = -1,

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
    /// 新音符“跟随”参考：上一个**被放置/点击/编辑**音符的长度（0 = 无参考）
    last_note_len: i32 = 0,
    /// 同上：力度与声像（null = 无参考 → 用 model 默认）
    last_note_velocity: ?i32 = null,
    last_note_pan: ?i32 = null,

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

    /// 记录“上一个被点击/编辑的音符”参考（新音符放置沿用其 长度/力度/声像）——
    /// 三个字段永远同步更新（同一交互逻辑；见放置/点击/拉伸/画笔各处调用）
    pub fn rememberNote(self: *PianoState, n: model.Note) void {
        self.last_note_len = n.len;
        self.last_note_velocity = n.velocity;
        self.last_note_pan = n.pan;
    }
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
    /// 声像旋钮右键菜单（恢复默认值）所属乐器（null = 未展开）
    ctx_pan: ?usize = null,
};

/// 播放状态（游标 + 传输）——设计原则：
/// **单一真源是 `song_step`（全局步）**：
/// - SONG 模式：游标就是它；
/// - PAT 模式：游标 = `piano_step`（自由设置，独立存储）；
/// - **模式切换统一走 `switchSongModePreserving`**（工具栏与状态栏两处按钮共用）：
///   按锚片段把当前位置换算到目标模式——两个位置始终是“同一音乐时刻”的两种坐标；
///   无锚（样式无片段）时 PAT 侧归 0。标尺点击仍是“显式放置”（写当前模式的坐标）。
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
    pub const Target = enum { instrument, mixer_channel, pattern, track, preset_name, kit_pad_name, preset_rename, preset_search, audio_style };

    active: bool = false,
    target: Target = .instrument,
    /// 目标下标（乐器槽位 / 通道序号 / **鼓垫音高** / **预设分类序号**）
    index: usize = 0,
    /// 目标乐器槽位（`kit_pad_name` 用；音高在 `index`）
    instrument: i32 = -1,
    /// 附加固定载荷（`preset_rename` 的**旧名字**；固定缓冲避免生命周期问题）
    aux_buf: [64]u8 = @splat(0),
    aux_len: usize = 0,
    /// UTF-8 缓冲（64 字节 ≈ 21 个汉字）
    buf: [64]u8 = @splat(0),
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
    flags: [128]bool = @splat(false),

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
    /// 音频样式列表独立滚动位置（与音符样式分开）
    audio_scroll: i32 = 0,
    /// 样式面板当前页：false = 音符样式 / true = 音频样式
    /// （**两家族分家**：SONG/PAT/钢琴窗只看 `sel.pattern`，音频样式保持双击开采样器）
    patterns_tab_audio: bool = false,
    /// 历史栏：上次跟随的当前条目（**变化时才自动滚动**——否则用户无法手动滚动查看）
    history_follow: usize = 0,
    /// 样式右键菜单：目标样式序号（null = 未展开）
    ctx_pattern: ?usize = null,
    /// 音频样式右键菜单：目标序号（null = 未展开）
    ctx_audio_style: ?usize = null,
    ctx_aud_x: i32 = 0,
    ctx_aud_y: i32 = 0,
    /// 样式右键菜单位置（**打开时快照**——不跟鼠标跑，否则永远点不到）
    ctx_pat_x: i32 = 0,
    ctx_pat_y: i32 = 0,
    /// 轨道右键菜单：目标轨道序号（null = 未展开）
    ctx_track: ?usize = null,
    /// 轨道右键菜单位置（打开时快照）
    ctx_trk_x: i32 = 0,
    ctx_trk_y: i32 = 0,
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
    /// VST3 无界面插件（兜底参数列表）的滚动位置；切目标时需要重置
    param_scroll: i32 = 0,
};

/// 鼓组 VST3 层插件重试节流（帧）——`App.syncKitLayerPlugins` 用
const kit_plugin_retry_frames: u16 = 240;

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
    /// 左音高列表点击试听（与上者分开：列表是“点一下整行”，按钮是“按住”）
    list_audition: ?i32 = null,
};

/// 调音台通道数：**默认 2**（主通道 + 通道#1），可添加；上限见 `max_mixer_channels`
pub const default_mixer_channels = 2;
/// 调音台通道**初始容量**（池化：按需增长/回收；起点 32）
pub const max_mixer_channels = 32;
/// 每通道效果器链**初始槽数**（同上；起点 32）
pub const max_effects_per_channel = 32;

/// 效果器类型（插件式：通道上可挂多个效果器；目前只有 EQ）
pub const EffectKind = enum(u32) {
    empty = 0,
    eq = 1,
    reverb = 2,
    delay = 3,
    compressor = 4,
    plugin = 5,

    /// 内建效果 ↔ 预设分类 id（`fx_*`）；空/插件 → null
    pub fn presetCategoryId(self: EffectKind) ?[]const u8 {
        return switch (self) {
            .eq => preset_mod.plugin_fx_eq,
            .reverb => preset_mod.plugin_fx_reverb,
            .delay => preset_mod.plugin_fx_delay,
            .compressor => preset_mod.plugin_fx_compressor,
            else => null,
        };
    }

    pub fn displayName(self: EffectKind) []const u8 {
        return switch (self) {
            .empty => "（空槽）",
            .eq => "EQ 参量均衡",
            .reverb => "混响",
            .delay => "延迟",
            .compressor => "压缩器",
            .plugin => "插件",
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
    /// 通用参数位（混响/延迟/压缩器；含义见 `effects.paramInfos`）——
    /// 添加时由 `addEffect` 按类型填默认值（EQ 不用）
    p: [fx.max_params]f32 = .{ 0, 0, 0, 0, 0 },
    /// 插件路径（kind == .plugin；VST3 文件）；固定缓冲，零分配
    plugin_path: [512]u8 = @splat(0),
    plugin_path_len: u16 = 0,
    /// 运行时插件实例（**不存档**；main 侧惰性加载/退役回收）
    plugin: ?*vst_host.Plugin = null,
    /// 混响/延迟/压缩器的**每槽 DSP 状态盒**（运行时；UI 线程分配/发布/退役——
    /// 音频线程经 `params.fx_ptrs` 读）。允许叠加同种效果后状态必须每槽独立。
    fx_state: ?*audio.FxBox = null,
    /// 加载失败标记（**运行时，不存档**）——效果行/面板标红用。
    /// 失败后路径保留，syncPluginSlots 周期重试；文件恢复→自动加载并应用 pending
    load_failed: bool = false,
    /// 重试节流（帧递减；>0 时不发起加载）
    fail_wait: u16 = 0,

    /// 待恢复的插件状态（工程加载时从存档解码；实例就绪后由 syncPluginSlots 应用并释放）
    pending_state: ?[]u8 = null,
    pending_state_ctrl: ?[]u8 = null,

    /// 最后已知类 CID（32 hex 文本；0 长 = 未知）——重绑定自愈/存档身份。
    /// 加载成功时回填；路径变化时清空。
    plugin_cid: [32]u8 = @splat(0),
    plugin_cid_len: u8 = 0,

    pub fn pluginCid(self: *const EffectSlot) []const u8 {
        return self.plugin_cid[0..self.plugin_cid_len];
    }
    pub fn setPluginCid(self: *EffectSlot, text: []const u8) void {
        const n = @min(text.len, self.plugin_cid.len);
        @memcpy(self.plugin_cid[0..n], text[0..n]);
        self.plugin_cid_len = @intCast(n);
    }

    /// 释放待恢复状态（槽被移除/重建前必须调用）
    pub fn clearPendingState(self: *EffectSlot, allocator: std.mem.Allocator) void {
        if (self.pending_state) |b| allocator.free(b);
        if (self.pending_state_ctrl) |b| allocator.free(b);
        self.pending_state = null;
        self.pending_state_ctrl = null;
    }

    pub fn pluginPath(self: *const EffectSlot) []const u8 {
        return self.plugin_path[0..self.plugin_path_len];
    }
    pub fn setPluginPath(self: *EffectSlot, path: []const u8) void {
        const n = @min(path.len, self.plugin_path.len);
        const same = self.plugin_path_len == n and std.mem.eql(u8, self.plugin_path[0..n], path[0..n]);
        @memcpy(self.plugin_path[0..n], path[0..n]);
        self.plugin_path_len = @intCast(n);
        // 路径真变化 → 重置加载失败态 + 身份（新文件允许立即尝试；同路径保留）
        if (!same) {
            self.load_failed = false;
            self.fail_wait = 0;
            self.plugin_cid_len = 0;
        }
    }
};

/// 分类 id（`fx_*`）→ 内建效果类型（非 fx 分类 → null）
pub fn fxKindFromCategory(id: []const u8) ?EffectKind {
    if (std.mem.eql(u8, id, preset_mod.plugin_fx_eq)) return .eq;
    if (std.mem.eql(u8, id, preset_mod.plugin_fx_reverb)) return .reverb;
    if (std.mem.eql(u8, id, preset_mod.plugin_fx_delay)) return .delay;
    if (std.mem.eql(u8, id, preset_mod.plugin_fx_compressor)) return .compressor;
    return null;
}

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
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    /// 效果器链（**动态**：顺序处理；空列表 = 无效果）
    effects: std.ArrayListUnmanaged(EffectSlot) = .empty,

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
pub const EffectRef = struct { ch: usize, slot: usize, scroll: i32 = 0 };

/// 导出进行中的状态（`App.export_wav`）——生命周期：`exportWavBegin` → 每帧
/// `exportWavFrame` 分块推进 → 完成/取消/失败统一收尾清理。
pub const ExportWav = struct {
    /// 目标路径（自有副本；删除半成品/UI 显示用）
    path: []u8,
    writer: wav.Writer,
    /// 插件状态快照（结束时回写）
    states: std.ArrayListUnmanaged(PlStateSnap),
    // 传输快照（结束时恢复）
    snap_song: i32,
    snap_piano: i32,
    snap_start_step: i32,
    snap_start_frame: u64,
    snap_frames: u64,
    snap_song_mode: bool,
    // 渲染进度
    step_frames: u64,
    total_frames: u64,
    done: u64,
    /// 导出诊断：已渲染块数 / 开始时的派发事件计数
    blocks: u64 = 0,
    dbg0: u64 = 0,
    /// 导出日志（纯文本；完成时写成 `<wav>.log`——现场排障用）
    log_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// 开始时间（纳秒；预留剩余时间估算）
    t0_ns: i64,
    /// 取消请求（对话框按钮 / Esc 置位；下一帧步进时清理）
    cancel_req: bool = false,
};

/// 导出里的单个插件状态快照
const PlStateSnap = struct { pl: *vst_host.Plugin, blobs: vst_host.StateBlobs };

/// 导出进度窗位置（首帧居中；标题可拖动）
pub const ExportWindow = struct {
    x: i32 = -100000,
    y: i32 = -100000,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
};

/// 导出尾音时长（秒）：内容末尾后再渲染这么久，让混响/延迟/释音自然衰减
const export_tail_sec: u64 = 2;

/// 帮助窗口（基本操作速查；工具栏“帮助”按钮打开）
pub const HelpWindow = struct {
    open: bool = false,
    x: i32 = 420,
    y: i32 = 110,
    w: i32 = 500,
    h: i32 = 510, // 刚好等于内容高度（17 行×21px + 4 节标题间距 + 边距；无滚动——冗余会让底部空一截）
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 26,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
};

/// 设置窗口（启动行为 / 最高帧率；工具栏“选项”打开）
pub const SettingsWindow = struct {
    open: bool = false,
    x: i32 = 460,
    y: i32 = 130,
    w: i32 = 440,
    h: i32 = 240,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 27,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
};

/// 插件管理窗口（工具栏“插件”打开）：扫描文件夹/单文件清单 + 手动扫描 + 结果列表。
/// 扫描运行时状态（进程句柄/进度）由 main 驱动（CreateProcess 在帧末）。
pub const PluginMgrWindow = struct {
    open: bool = false,
    x: i32 = 380,
    y: i32 = 80,
    w: i32 = 660,
    h: i32 = 560,
    /// Z 序（越大越靠上；点窗口即置顶）——见 `RackState.z` 注释
    z: i32 = 28,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    /// 结果列表滚动
    scroll: i32 = 0,
    /// 隐藏“加载失败（非 VST3 / 损坏）”条目（默认隐藏——折叠语义）
    hide_ignored: bool = true,

    // ── 扫描运行时（main 管理；不存档、不参与历史）──
    scanning: bool = false,
    /// worker 进程句柄（CreateProcess 返回；结束时 CloseHandle）
    scan_handle: ?*anyopaque = null,
    /// 用户取消 → 丢弃本次结果（崩溃/看门狗杀 → 保留部分结果）
    scan_discard: bool = false,
    /// 自愈兑底节拍（帧；每 ~2s 尝试一次——覆盖“打开工程后插件已删”场景）
    heal_tick: u32 = 0,
    /// 进度（每隔几帧从 JSONL 尾部重数）
    scan_ok: usize = 0,
    scan_err: usize = 0,
    scan_total: usize = 0,
    scan_current_buf: [260]u8 = @splat(0),
    scan_current_len: usize = 0,
    /// 轮询计数（每 8 帧读一次进度文件）
    scan_frame: u32 = 0,
    /// 无进展帧数（看门狗：长时间无进展 → 殺 worker——防被外部弹框卡死）
    scan_idle: u32 = 0,
    /// 进度文件路径（数据目录下；扫描期间）
    scan_out_buf: [640]u8 = @splat(0),
    scan_out_len: usize = 0,
};

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

/// 插件状态块池（历史快照共享）：按内容去重——同一插件未被编辑时，多条历史指向
/// 同一份内存。这里存的是 base64 文本（与存档字段同一表示）。
/// 所有权：`intern` 成功则接管/释放传入块并返回共享块；失败（OOM/碰撞）不接管。
/// `release` 引用计数归零后释放；`deinit` 兜底清空（防漏）。
const StatePool = struct {
    map: std.AutoHashMapUnmanaged(u64, Entry) = .{},
    const Entry = struct { bytes: []const u8, refs: usize };

    fn intern(self: *StatePool, alloc: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
        if (bytes.len == 0) return "";
        const h = std.hash.Wyhash.hash(0, bytes);
        if (self.map.getPtr(h)) |e| {
            if (std.mem.eql(u8, e.bytes, bytes)) {
                alloc.free(bytes);
                e.refs += 1;
                return e.bytes;
            }
            return null; // 哈希碰撞（实际未见）：保守放弃
        }
        self.map.put(alloc, h, .{ .bytes = bytes, .refs = 1 }) catch return null;
        return bytes;
    }

    fn release(self: *StatePool, alloc: std.mem.Allocator, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const h = std.hash.Wyhash.hash(0, bytes);
        if (self.map.getPtr(h)) |e| {
            if (e.bytes.ptr != bytes.ptr) return; // 防御：非池块
            e.refs -= 1;
            if (e.refs == 0) {
                alloc.free(e.bytes);
                _ = self.map.remove(h);
            }
        }
    }

    fn deinit(self: *StatePool, alloc: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |kv| alloc.free(kv.value_ptr.bytes);
        self.map.deinit(alloc);
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    /// 插件状态块池（历史快照共享；见 StatePool）
    state_pool: StatePool = .{},
    /// 主窗口句柄（VST3 编辑器窗口的 owner；main 初始化时写入；无窗口环境为 null）
    main_hwnd: ?*anyopaque = null,

    // ── 文档数据（所有视图共享）──
    /// 已放置的样式片段
    clips: std.ArrayListUnmanaged(Clip) = .empty,
    /// 钢琴窗音符（**局部坐标**：按样式 + 乐器归属）
    notes: std.ArrayListUnmanaged(Note) = .empty,
    /// 乐器列表（槽位；可多个同名）
    instruments: std.ArrayListUnmanaged(Instrument) = .empty,
    /// 已删除乐器的合成器参数（**延迟释放**）：音频线程可能仍持有指针，
    /// 立即 destroy 会造成 use-after-free。进程退出时才真正释放。
    retired_synths: std.ArrayListUnmanaged(*synth.SynthParams) = .empty,
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
    clipboard_notes: std.ArrayListUnmanaged(ClipboardNote) = .empty,
    /// 片段剪贴板（绝对坐标；粘贴时整体平移）
    clipboard_clips: std.ArrayListUnmanaged(Clip) = .empty,
    /// 批量拉伸快照（拖选中音符边缘期间；顺序 = 音符数组顺序）
    batch_snap: std.ArrayListUnmanaged(BatchSnap) = .empty,

    // ── 撤销/重做（快照式；见 `commitHistory`）──
    /// 历史快照栈（[0] = 初始/打开工程时的状态；current = 当前所在快照）
    history: std.ArrayListUnmanaged(HistoryState) = .empty,
    /// 当前状态在 `history` 中的下标
    history_current: usize = 0,
    /// 最后一次保存时对应的历史下标（脏标记 = 当前 != 此处）
    history_saved_index: usize = 0,
    /// 待提交的操作名（**拖动类操作**在拖动中每帧设置，帧末鼠标松开后才真正提交——
    /// 实现 coalesce：一次拖动 = 一条历史，而不是每帧一条）
    history_pending: ?[]const u8 = null,
    /// 进行中的“起手提交 + 静置钉值”手势（滚轮 / 插件侧改动：无明确终点事件）。
    /// 起手即提交临时条目；静置 1s / 新操作起手 / 编辑器关闭 / 保存 → 钉住最终值。
    gesture: ?Gesture = null,
    /// 插件参数手势标签缓冲（“{插件名}：{参数名}”）；见 `paramGestureLabel` 生命周期纪律
    gesture_label_buf: [128]u8 = undefined,
    /// 插件状态脏标（**捕获复用**判据，见 `markSlotStateDirty`）：自上次历史
    /// 捕获后该槽插件状态是否变过。未变槽快照/全等判定不再 getState（撤销卡顿根治）
    instr_state_dirty: []bool = &.{},
    /// 鼓组层状态脏标（乐器容量 × `kit_max_layers`；VST3 层参数编辑/状态记账用）
    kit_layer_state_dirty: [][]bool = &.{},
    fx_state_dirty: [][]bool = &.{},
    /// 容量自动回收挂起（删除/装载后置位；帧末 `pollCapacityReclaim` 合并处理）
    shrink_pending: bool = false,
    /// 鼓组池回收/对齐挂起（删除/类型切换；见 `gcKitPools`）
    kit_gc_pending: bool = false,
    /// 鼓组池全量重置挂起（装载/历史重建：乐器被重建 → 池全部失效）
    kit_reset: bool = false,
    /// 鼓组池删除位移日志（removeInstrument 记录 idx；帧末按序重放左移）
    kit_shift_log: std.ArrayListUnmanaged(usize) = .empty,
    /// 音频资产池（会话存活；工程切换时统一释放）
    /// ⚠️ **指针稳定**：元素是 `*AudioAsset`，资产本体单独分配——
    /// 播放表（音频线程）里存的是 `&asset.data`，池子扩容绝不能让它悬空。
    audio_assets: std.ArrayListUnmanaged(*AudioAsset) = .empty,
    /// 音频样式（片段共享的通道/增益）
    audio_styles: std.ArrayListUnmanaged(AudioStyle) = .empty,
    /// 音频导入（P2：单 worker 线程 + 队列；见 `audio_import.zig`）
    /// **工程加载**也走它（`beginProjectLoadAsync`）——UI 线程全程不阻塞。
    import_mgr: audio_import.Manager = .{},
    /// 进程 Io（0.17 的阻塞 I/O 句柄）：`main` 启动时注入，测试用 `std.testing.io`
    io: ?std.Io = null,
    /// 播放表重建用的复用缓冲（逐帧重新计算；容量保留）
    audio_scratch: std.ArrayListUnmanaged(audio.AudioTableRow) = .empty,
    /// 退役中的旧播放表（倒计时回收；见 `reapRetiredAudioTables`）
    audio_tables_retired: std.ArrayListUnmanaged(RetiredAudioTable) = .empty,
    /// 波形窗口试听（全局单实例）
    preview: PreviewState = .{},
    /// 主输出电平表（帧末 pollOutMeter 更新）：当前峰值 / 回落保持值
    out_peak: f32 = 0,
    out_peak_hold: f32 = 0,
    /// 削波（|x|>1）采样数保持计数（>0 时状态栏显示"过载"；以后波形标红复用）
    out_over_hold: u32 = 0,
    /// 选中待放置的音频样式（♪ 行单击选中；-1 = 未选）
    audio_style_sel: i32 = -1,
    /// 波形窗口“样式模式”的占位 trim（无片段上下文；不可编辑）
    wave_trim_dummy: [2]i32 = .{ 0, 0 },
    /// 基准目录（打开工程时设置；相对音频路径按它解析）
    base_dir: [1024]u8 = @splat(0),
    base_dir_len: usize = 0,
    /// 待处理的“加载采样”（鼓垫层）——文件对话框在 main 帧初执行
    pending_load_sample: ?struct { instrument: i32, pitch: u8, layer: ?usize } = null,
    /// 编辑器打开计数（上一帧）——从 N 变 N-1 = 有人关窗 → 手势结束（钉值）
    editors_open_prev: usize = 0,

    // ── 保存 / 加载（工程文件）──
    /// 当前工程路径（null = 尚未保存过）
    project_path: ?[]u8 = null,
    /// 脏标记（有未保存修改）——任何编辑操作置 true；保存/加载后置 false
    dirty: bool = false,
    /// 插件内部状态已变更（编辑器/参数面板编辑；重存后清零）
    plugin_dirty: bool = false,
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
    /// 上一帧实际间隔（纳秒；main 每帧更新）——供帧率无关的滑动动画（如视角跟随）
    frame_dt_ns: i64 = 16_666_667,
    /// 游标平滑显示位置（**小数步**；`tickCursorSmooth` 每帧推进——渲染帧率下线性滑动，
    /// 吸收音频缓冲量化；见 `tickCursorSmooth`/`cursorDisplay`）
    cursor_smooth: f32 = 0,
    cursor_smooth_ok: bool = false,
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
    data_root_buf: [512]u8 = @splat(0),
    data_root_len: usize = 0,
    /// 预设库（扫描结果；启动/保存后刷新）
    preset_lib: preset_mod.Library = .{},
    /// 浏览器锚插件 id 缓冲（`presetTargetPlugin` 动态生成 VST3 分类 id 用；
    /// 每次开面板前覆写——slice 生命周期与面板同步）
    preset_anchor_buf: [40]u8 = @splat(0),
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
    /// 待确认的结构删除（非空样式/轨道；`modal == .pattern_delete/.track_clear` 时有效）
    struct_del_req: ?DelReq = null,
    /// 脏确认流程状态（拦截动作 → 确认 → 执行）
    dirty_flow: DirtyFlow = .none,
    /// 脏确认流程的目标动作（quit / open）
    dirty_intent: ?PendingIntent = null,
    /// 待打开的工程路径（用户已在系统对话框选好；等确认框决定后执行）
    pending_open_path: ?[]u8 = null,
    /// 待升级的旧版存档路径 + 版本（`modal == .save_upgrade` 时有效；取消即清理）
    pending_upgrade_path: ?[]u8 = null,
    pending_upgrade_version: u32 = 0,

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
    /// 导出进行中状态（null = 空闲）——分块离线渲染；见 `exportWavBegin/exportWavFrame`
    export_wav: ?ExportWav = null,
    /// 导出进度窗位置（模态，可拖动；首帧居中）——`drawExportDialog` 用
    export_win: ExportWindow = .{},
    panels: PanelsState = .{},
    synth_win: SynthWindow = .{},
    mixer_win: MixerWindow = .{},
    effect_win: EffectWindow = .{},
    help_win: HelpWindow = .{},
    /// 波形窗口（音频片段 / 鼓组采样器层）
    wave_win: WaveWindow = .{},
    settings_win: SettingsWindow = .{},
    plugin_mgr: PluginMgrWindow = .{},
    /// 本帧浮动窗口的**绘制顺序与最终矩形**（`main.drawApp` 逐帧填写；与绘制严格同序：
    /// 后排 = 在上）——插件子窗口区域裁切（`setEditorClip`）据此收集覆盖矩形
    win_draw_info: [8]WinDraw = @splat(.{ .kind = .rack, .x = 0, .y = 0, .w = 0, .h = 0 }),
    win_draw_n: usize = 0,
    /// 插件管理数据（main 启动时加载；`null` = 未初始化——单元测试不加载）
    plugin_cfg: ?plugin_db.Config = null,
    plugin_cache: ?plugin_db.Cache = null,
    /// 插件配置需落盘（管理器改动；帧末执行，同 settings_dirty 模式）
    plugin_cfg_dirty: bool = false,
    /// 管理器“+ 添加文件夹… / + 添加文件…”待打开对话框（帧末执行）
    pending_plugin_folder_pick: bool = false,
    pending_plugin_file_pick: bool = false,
    /// 管理器「开始扫描 / 取消」待帧末执行
    pending_scan_start: bool = false,
    pending_scan_cancel: bool = false,
    /// 应用设置（settings.json；IO 由 main 帧末执行）
    /// - `settings_open_last`：启动时打开上次工程（false = 新建空工程）
    /// - `fps_limit`：最高帧率（帧预算 = 1e9 / fps；30..240）
    settings_open_last: bool = false,
    fps_limit: i32 = 120,
    /// 设置需要落盘（变更 / 工程路径变化时置位）
    settings_dirty: bool = false,
    drumkit_win: DrumKitWindow = .{},
    /// 浮动窗口 Z 序的**全局计数器**（点窗口置顶时 +1，见 `bringToFront`）
    z_top: i32 = 50,
    /// 调音台通道（**动态**；默认 2 个，可添加；乐器通过 `Instrument.mixer` 路由到其中之一）
    mixer_channels_state: std.ArrayListUnmanaged(MixerChannel) = .empty,
    /// 已删除但可能仍被音频线程引用的插件实例（**延迟销毁**）——
    /// `countdown` 帧后由 `reapRetiredPlugins` 真正释放（远大于音频缓冲周期）
    retired_plugins: std.ArrayListUnmanaged(RetiredPlugin) = .empty,
    /// 同模式：退役的效果器状态盒（混响/延迟/压缩器）
    retired_fx: std.ArrayListUnmanaged(RetiredFx) = .empty,
    /// 「+ 添加乐器」→ 预设面板（帧末无待办项）
    /// 手动重定位（管理器/右键「重新定位插件…」帧末弹文件框）
    pending_relocate_instrument: ?usize = null,
    pending_relocate_effect: ?EffectRef = null,

    // ── 占位数据 ──
    /// 样式列表（**动态**；名字由 App 管理生命周期，如 "样式 7"）。
    /// 数量 = `pattern_items.items.len`；上限 `max_patterns`（播放列表预览数组等按此设限）。
    pattern_items: std.ArrayListUnmanaged([]u8) = .empty,
    /// 轨道自定义名（**稀疏**：仅存改过名的行；键 = 行号）。行本身是坐标空间（纯编排行，
    /// 无每轨状态）——行数 = `trackCount()`（内容下缘 + 保底 + 3 行留白）随时推导，
    /// 与横向小节对称、无限向下延伸；“添加轨道”动作已废弃（往留白行放片段即自动生长）。
    /// 未命名的行由 `trackName()` 合成 "Track N"；原显式轨道名单已按用户拍板移除。
    track_names: std.AutoHashMapUnmanaged(i32, []u8) = .{},
    /// **静音轨道**（稀疏行号集合；键 = 行号）——SONG 调度时跳过其全部片段
    /// （sequencer 通过 `Scheduler.muted` 读取；主线程调度链路，无跨线程共享）
    track_muted: std.AutoHashMapUnmanaged(i32, void) = .{},
    /// `trackName()` 合成默认名的临时缓冲（调用方须**立即**使用返回值，勿留存）
    track_name_buf: [24]u8 = undefined,
    /// 播放列表片段预览的每样式音域统计（按**实际样式数**分配/复用——见 `ensurePatStats`；
    /// 原为 `[max_patterns]` 栈数组，上限放到十亿级后改为复用缓冲）
    pat_stats: []PatPreviewStat = &.{},

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
        var to_clone: std.ArrayListUnmanaged(Clip) = .empty;
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
        var to_clone: std.ArrayListUnmanaged(model.Note) = .empty;
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

    /// 释放鼓垫内容（层参数进退役、VST3 层插件退役/待恢复状态释放；
    /// 名字/预设名释放；不含 pad 自身）
    fn deinitPadContents(self: *App, pad: *model.DrumPad) void {
        for (pad.layers.items) |*ly| {
            self.retireSynth(ly.params);
            if (ly.plugin) |pl| {
                ly.plugin = null;
                self.retirePlugin(pl);
            }
            ly.clearPendingState(self.allocator);
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
    fn exportInstrument(self: *App, inst: *const model.Instrument, pooled: bool) !persist.SavedInstrument {
        var si = persist.SavedInstrument{
            .name = try self.allocator.dupe(u8, inst.name),
            .volume = inst.volume,
            .pan = inst.pan,
            .muted = inst.muted,
            .mixer = inst.mixer,
            .midi_channel = inst.midi_channel,
            .kind = @backingInt(inst.kind),
            .key_mode = @backingInt(inst.key_mode),
            .synth = persist.exportSynth(inst.synth),
        };
        errdefer self.allocator.free(si.name);
        si.preset_name = try self.allocator.dupe(u8, inst.preset_name);
        errdefer self.allocator.free(si.preset_name);
        if (inst.kind == .vst3 and inst.pluginPath().len > 0) {
            si.plugin_path = try self.allocator.dupe(u8, inst.pluginPath());
            errdefer self.allocator.free(si.plugin_path);
        }
        // 类 CID：活实例优先（顺带回填槽位），否则用槽位记录（失败槽靠它重绑定）
        if (inst.kind == .vst3) {
            if (inst.plugin) |pl| {
                var cb: [32]u8 = undefined;
                si.plugin_cid = try self.allocator.dupe(u8, pl.cidHex(&cb));
            } else if (inst.pluginCid().len == 32) {
                si.plugin_cid = try self.allocator.dupe(u8, inst.pluginCid());
            }
            if (si.plugin_cid.len > 0) {
                errdefer self.allocator.free(si.plugin_cid);
            }
        }
        // VST3 乐器**音色状态**（优先活实例；无实例用 pending；历史走去重池）
        if (inst.kind == .vst3) {
            var comp_b64: []const u8 = "";
            var ctrl_b64: []const u8 = "";
            if (inst.plugin) |pl| {
                // 捕获复用：槽未脏且来向条目同路径 → 沿用状态文本（intern 命中同块）
                if (self.reuseInstrumentState(inst, pooled)) |r| {
                    comp_b64 = if (r.comp.len > 0) self.adoptStateB64(try self.allocator.dupe(u8, r.comp), pooled) else "";
                    ctrl_b64 = if (r.ctrl.len > 0) self.adoptStateB64(try self.allocator.dupe(u8, r.ctrl), pooled) else "";
                } else {
                    comp_b64 = self.adoptStateB64(try capturePluginStateB64(self.allocator, pl, true), pooled);
                    ctrl_b64 = self.adoptStateB64(try capturePluginStateB64(self.allocator, pl, false), pooled);
                }
            } else {
                comp_b64 = self.adoptStateB64(try b64Encode(self.allocator, if (inst.pending_state) |b| b else &.{}), pooled);
                ctrl_b64 = self.adoptStateB64(try b64Encode(self.allocator, if (inst.pending_state_ctrl) |b| b else &.{}), pooled);
            }
            errdefer if (comp_b64.len > 0) {
                if (pooled) {
                    self.state_pool.release(self.allocator, comp_b64);
                } else {
                    self.allocator.free(comp_b64);
                }
            };
            errdefer if (ctrl_b64.len > 0) {
                if (pooled) {
                    self.state_pool.release(self.allocator, ctrl_b64);
                } else {
                    self.allocator.free(ctrl_b64);
                }
            };
            si.plugin_state = comp_b64;
            si.plugin_state_ctrl = ctrl_b64;
        }
        if (inst.kit) |kit| si.kit = try self.exportDrumKit(kit, pooled, self.instrumentIndexOf(inst));
        return si;
    }

    fn exportDrumKit(self: *App, kit: *const model.DrumKit, pooled: bool, inst_idx: ?usize) !persist.SavedDrumKit {
        const pads = try self.allocator.alloc(persist.SavedDrumPad, kit.pads.items.len);
        var np: usize = 0;
        var flat: usize = 0; // 展平槽位（复用/脏标寻址；与 syncParams 同序）
        errdefer {
            for (pads[0..np]) |p| {
                for (p.layers) |ly| self.freeSavedLayer(&ly, pooled);
                self.allocator.free(p.layers);
                self.allocator.free(p.name);
            }
            self.allocator.free(pads);
        }
        for (kit.pads.items, 0..) |pad, i| {
            const layers = try self.allocator.alloc(persist.SavedDrumLayer, pad.layers.items.len);
            var nl: usize = 0;
            errdefer {
                for (layers[0..nl]) |ly| self.freeSavedLayer(&ly, pooled);
                self.allocator.free(layers);
            }
            for (pad.layers.items, 0..) |layer, li| {
                layers[li] = .{
                    .kind = @backingInt(layer.kind),
                    .synth = persist.exportSynth(layer.params),
                    .gain = layer.gain,
                    .source_preset = try self.allocator.dupe(u8, layer.source_preset),
                };
                if (layer.kind == .vst3) {
                    // 路径 / CID / 音色状态——**捕获复用（去重池）**：层未脏且来向
                    // 条目同位置同路径 → 沿用其状态文本（intern 同块）；否则现取
                    if (layer.pluginPath().len > 0) {
                        layers[li].plugin_path = try self.allocator.dupe(u8, layer.pluginPath());
                    }
                    if (layer.plugin) |pl| {
                        var cb: [32]u8 = undefined;
                        layers[li].plugin_cid = try self.allocator.dupe(u8, pl.cidHex(&cb));
                        var reused = false;
                        if (inst_idx) |ii| {
                            if (self.reuseLayerState(&layer, ii, pad.pitch, li, flat, pooled)) |r| {
                                layers[li].plugin_state = if (r.comp.len > 0) self.adoptStateB64(try self.allocator.dupe(u8, r.comp), pooled) else "";
                                layers[li].plugin_state_ctrl = if (r.ctrl.len > 0) self.adoptStateB64(try self.allocator.dupe(u8, r.ctrl), pooled) else "";
                                reused = true;
                            }
                        }
                        if (!reused) {
                            const s1 = try capturePluginStateB64(self.allocator, pl, true);
                            layers[li].plugin_state = self.adoptStateB64(s1, pooled);
                            const s2 = try capturePluginStateB64(self.allocator, pl, false);
                            layers[li].plugin_state_ctrl = self.adoptStateB64(s2, pooled);
                        }
                    } else {
                        if (layer.pluginCid().len == 32) {
                            layers[li].plugin_cid = try self.allocator.dupe(u8, layer.pluginCid());
                        }
                        layers[li].plugin_state = self.adoptStateB64(try b64Encode(self.allocator, if (layer.pending_state) |b| b else &.{}), pooled);
                        layers[li].plugin_state_ctrl = self.adoptStateB64(try b64Encode(self.allocator, if (layer.pending_state_ctrl) |b| b else &.{}), pooled);
                    }
                }
                if (layer.kind == .sampler) {
                    var rel_buf2: [1024]u8 = undefined;
                    const sp2 = self.audioPathForSave(layer.assetPath(), &rel_buf2);
                    if (sp2.len > 0) layers[li].asset_path = try self.allocator.dupe(u8, sp2);
                    layers[li].trim_start = layer.trim_start;
                    layers[li].trim_len = layer.trim_len;
                    layers[li].speed = layer.speed;
                }
                nl += 1;
                flat += 1;
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

    /// 释放一份存档层（`exportDrumKit`/`freeSavedKit` 共用；池化态经 state_pool 归还）
    fn freeSavedLayer(self: *App, ly: *const persist.SavedDrumLayer, pooled: bool) void {
        self.allocator.free(ly.source_preset);
        if (ly.plugin_path.len > 0) self.allocator.free(ly.plugin_path);
        if (ly.plugin_cid.len > 0) self.allocator.free(ly.plugin_cid);
        if (ly.asset_path.len > 0) self.allocator.free(ly.asset_path);
        if (ly.plugin_state.len > 0) {
            if (pooled) self.state_pool.release(self.allocator, ly.plugin_state) else self.allocator.free(ly.plugin_state);
        }
        if (ly.plugin_state_ctrl.len > 0) {
            if (pooled) self.state_pool.release(self.allocator, ly.plugin_state_ctrl) else self.allocator.free(ly.plugin_state_ctrl);
        }
    }

    /// 释放存档乐器（与 `exportInstrument` 对称；历史快照/工程释放共用）
    fn freeSavedInstrument(self: *App, si: *const persist.SavedInstrument, pooled: bool) void {
        self.allocator.free(si.name);
        self.allocator.free(si.preset_name);
        if (si.plugin_path.len > 0) self.allocator.free(si.plugin_path);
        if (si.plugin_cid.len > 0) self.allocator.free(si.plugin_cid);
        if (si.plugin_state.len > 0) {
            if (pooled) self.state_pool.release(self.allocator, si.plugin_state) else self.allocator.free(si.plugin_state);
        }
        if (si.plugin_state_ctrl.len > 0) {
            if (pooled) self.state_pool.release(self.allocator, si.plugin_state_ctrl) else self.allocator.free(si.plugin_state_ctrl);
        }
        self.freeSavedKit(&si.kit, pooled);
    }

    /// 释放套鼓快照（导出/保存路径用；与 `exportDrumKit` 对称）
    pub fn freeSavedKit(self: *App, sk: *const persist.SavedDrumKit, pooled: bool) void {
        for (sk.pads) |pad| {
            self.allocator.free(pad.name);
            for (pad.layers) |ly| self.freeSavedLayer(&ly, pooled);
            self.allocator.free(pad.layers);
        }
        self.allocator.free(sk.pads);
    }

    /// 导出整组套鼓快照（深拷贝；调用方用 `freeSavedKit` 释放）；
    /// 非鼓组/越界/分配失败 → null
    pub fn exportKitForSave(self: *App, idx: usize) ?persist.SavedDrumKit {
        if (idx >= self.instruments.items.len) return null;
        const kit = self.instruments.items[idx].kit orelse return null;
        return self.exportDrumKit(kit, false, null) catch null;
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
        self.importDrumKit(sk, inst.kit.?, idx, 0, 0);
        self.dirty = true;
        return true;
    }

    /// 把存档鼓组恢复到 `kit`（清空重建；失败时尽量保留已恢复部分——
    /// 宁可部分丢也不 use-after-free）。
    /// **实例救援 + 参数回放**（撤销/重做/载入共用）：新结构某位置（同垫音高、同层序）
    /// 的旧活实例若与新层同 kind+路径 → **保留实例**（不重建、不退役；编辑器窗口不闪断），
    /// 状态按计划应用：skip（与来向条目同状态）/ replay（旋钮级撤销——`replayPlanFor`）/
    /// full（整块 pending）。`inst_idx`/`prev_idx`/`target_idx`：历史上下文
    /// （载入无历史 → prev==target，计划退化为 full）。
    fn importDrumKit(self: *App, sk: *const persist.SavedDrumKit, kit: *model.DrumKit, inst_idx: ?usize, prev_idx: usize, target_idx: usize) void {
        // ① 救援扫描 + **摘取**（旧层仍在时把插件与身份摘出；旧层置空防退役）
        //    **状态计划在此算**：ref 经旧结构解析（`slotPlugin` 仍能找到该层实例）——
        //    放在重建中段算会因结构已清而永远解析不到 → 回放永不生效
        const Rescue = struct {
            pitch: u8,
            li: usize,
            kind: model.LayerKind,
            plugin: *vst_host.Plugin,
            used: bool = false,
            plan_skip: bool = false,
            plan_job: ?ReplayJob = null,
            path: [512]u8 = @splat(0),
            path_len: u16 = 0,
            cid: [32]u8 = @splat(0),
            cid_len: u8 = 0,
        };
        var rescues: [audio.kit_max_layers]Rescue = undefined;
        var n_rescues: usize = 0;
        var old_flat: usize = 0; // 旧结构展平槽位（ref 寻址；与 syncParams 同序）
        for (kit.pads.items) |*pad| {
            for (pad.layers.items, 0..) |*ly, li| {
                if (n_rescues >= audio.kit_max_layers) break;
                const pl = ly.plugin orelse {
                    old_flat += 1;
                    continue;
                };
                var r = Rescue{
                    .pitch = pad.pitch,
                    .li = li,
                    .kind = ly.kind,
                    .plugin = pl,
                    .path = ly.plugin_path,
                    .path_len = ly.plugin_path_len,
                    .cid = ly.plugin_cid,
                    .cid_len = ly.plugin_cid_len,
                };
                // 计划：目标条目同位置层（sk） vs 来向条目同位置层
                if (inst_idx) |ii| {
                    if (prev_idx != target_idx and prev_idx < self.history.items.len) {
                        const tgt_sl: ?persist.SavedDrumLayer = findSavedLayer(sk, pad.pitch, li);
                        if (tgt_sl) |sl| {
                            const psi = &self.history.items[prev_idx];
                            if (ii < psi.instruments.len and psi.instruments[ii].kind == 1) {
                                if (findSavedLayer(&psi.instruments[ii].kit, pad.pitch, li)) |pl0| {
                                    if (std.mem.eql(u8, sl.plugin_path, pl0.plugin_path) and
                                        stateBlobsEqual(sl.plugin_state, sl.plugin_state_ctrl, pl0.plugin_state, pl0.plugin_state_ctrl))
                                    {
                                        r.plan_skip = true;
                                    }
                                }
                            }
                            if (!r.plan_skip) {
                                const ref = PluginSlotRef{
                                    .kind = .kit_layer,
                                    .a = @intCast(@min(ii, std.math.maxInt(u16))),
                                    .b = @intCast(@min(old_flat, std.math.maxInt(u16))),
                                };
                                if (self.replayPlanFor(ref, prev_idx, target_idx)) |job| r.plan_job = job;
                            }
                        }
                    }
                }
                rescues[n_rescues] = r;
                ly.plugin = null; // 摘走（下面清空时不退役）
                n_rescues += 1;
                old_flat += 1;
            }
        }
        // ② 清空旧内容（未被救援的插件在此退役）
        for (kit.pads.items) |*pad| self.deinitPadContents(pad);
        kit.pads.clearRetainingCapacity();
        // ③ 重建（逐层：位置+路径匹配 → 实例救援；否则新建 + pending）
        for (sk.pads) |sp| {
            const pitch: u8 = @intCast(@min(sp.pitch, 127));
            var pad = model.DrumPad{
                .pitch = pitch,
                .name = self.allocator.dupe(u8, sp.name) catch continue,
            };
            for (sp.layers, 0..) |sl, li| {
                const lp = self.allocator.create(synth.SynthParams) catch continue;
                lp.* = .{};
                persist.importSynth(&sl.synth, lp);
                const src: []u8 = self.allocator.dupe(u8, sl.source_preset) catch &.{};
                // 未知类型（未来存档）→ 退回减法（现阶段可用引擎；参数照常载入）
                const kind = std.enums.fromInt(model.LayerKind, sl.kind) orelse model.LayerKind.subtractive;
                var layer = model.DrumLayer{ .kind = kind, .params = lp, .gain = sl.gain, .source_preset = src };
                if (kind == .sampler) {
                    var path_buf2: [1024]u8 = undefined;
                    const resolved = self.resolveAudioPath(sl.asset_path, &path_buf2) orelse sl.asset_path;
                    layer.setAssetPath(resolved);
                    layer.asset_idx = self.loadAudioAsset(resolved) orelse -1;
                    layer.load_failed = layer.asset_idx < 0;
                    layer.trim_start = sl.trim_start;
                    layer.trim_len = sl.trim_len;
                    layer.speed = if (sl.speed > 0) sl.speed else 1.0;
                }
                if (kind == .vst3) {
                    layer.setPluginPath(sl.plugin_path);
                    layer.setPluginCid(sl.plugin_cid);
                    // 救援查找：(音高, 层序) + 同 kind + 同路径
                    var ri: ?usize = null;
                    for (rescues[0..n_rescues], 0..) |r, k| {
                        if (!r.used and r.pitch == pitch and r.li == li and r.kind == kind and
                            std.mem.eql(u8, r.path[0..r.path_len], sl.plugin_path))
                        {
                            ri = k;
                            break;
                        }
                    }
                    if (ri) |k| {
                        // 实例救援：挂旧实例（编辑器窗口保持），状态按**摘取前算好的计划**应用
                        const r = &rescues[k];
                        r.used = true;
                        layer.plugin = r.plugin;
                        layer.plugin_path = r.path;
                        layer.plugin_path_len = r.path_len;
                        layer.plugin_cid = r.cid;
                        layer.plugin_cid_len = r.cid_len;
                        const ref = PluginSlotRef{
                            .kind = .kit_layer,
                            .a = @intCast(@min(inst_idx orelse 0, std.math.maxInt(u16))),
                            .b = 0,
                        };
                        if (r.plan_skip) {
                            // 状态未变：不碰实例
                        } else if (r.plan_job) |job| {
                            if (runReplay(r.plugin, job)) {
                                // 回放后实例 = 目标状态
                                if (inst_idx) |ii| {
                                    if (self.kitLayerSlot(ii, pitch, li)) |slot| {
                                        self.markSlotStateClean(.{ .kind = .kit_layer, .a = @intCast(@min(ii, std.math.maxInt(u16))), .b = @intCast(@min(slot, std.math.maxInt(u16))) });
                                    }
                                }
                            } else {
                                // ID 失配/前提破坏 → 整块兜底
                                layer.pending_state = b64Decode(self.allocator, sl.plugin_state);
                                layer.pending_state_ctrl = b64Decode(self.allocator, sl.plugin_state_ctrl);
                                self.markSlotStateDirty(ref);
                            }
                        } else {
                            layer.pending_state = b64Decode(self.allocator, sl.plugin_state);
                            layer.pending_state_ctrl = b64Decode(self.allocator, sl.plugin_state_ctrl);
                            self.markSlotStateDirty(ref);
                        }
                    } else {
                        // 新建：状态入 pending（实例帧末惰性加载——syncKitLayerPlugins）
                        layer.pending_state = b64Decode(self.allocator, sl.plugin_state);
                        layer.pending_state_ctrl = b64Decode(self.allocator, sl.plugin_state_ctrl);
                    }
                }
                pad.layers.append(self.allocator, layer) catch {
                    self.retireSynth(lp);
                    if (layer.plugin) |pl| self.retirePlugin(pl);
                    layer.clearPendingState(self.allocator);
                    self.allocator.free(src);
                };
            }
            kit.pads.append(self.allocator, pad) catch {
                self.deinitPadContents(&pad);
            };
        }
        // ④ 未被用到的救援实例 → 退役（结构变化后多余的旧层）
        for (rescues[0..n_rescues]) |r| {
            if (!r.used) self.retirePlugin(r.plugin);
        }
        std.mem.sort(model.DrumPad, kit.pads.items, {}, struct {
            fn less(_: void, a: model.DrumPad, b: model.DrumPad) bool {
                return a.pitch < b.pitch;
            }
        }.less);
    }

    /// 存档鼓组里按（音高, 层序）找层（找不到 → null）——实例救援/计划用
    fn findSavedLayer(sk: *const persist.SavedDrumKit, pitch: u8, li: usize) ?persist.SavedDrumLayer {
        for (sk.pads) |sp| {
            if (sp.pitch != @as(u32, pitch)) continue;
            if (li < sp.layers.len) return sp.layers[li];
            return null;
        }
        return null;
    }

    /// 两份 base64 插件状态是否同内容：池化共享 → 指针相等快路径；否则内容比较。
    /// 撤销/重做靠它跳过“没变过”的插件状态重放（setState 会锁插件、整曲卡顿）
    fn stateBlobsEqual(a_comp: []const u8, a_ctrl: []const u8, b_comp: []const u8, b_ctrl: []const u8) bool {
        if (a_comp.ptr == b_comp.ptr and a_ctrl.ptr == b_ctrl.ptr) return true;
        return std.mem.eql(u8, a_comp, b_comp) and std.mem.eql(u8, a_ctrl, b_ctrl);
    }

    /// 把存档乐器恢复到已存在的 `target`（名字除外——由调用方处理；
    /// 历史恢复/工程导入共用，防两处逻辑分叉）。
    /// `plan`：撤销/重做逐槽决定的状态应用方式（skip 不动 / replay 参数回放 / full 整块）
    fn applySavedInstrument(self: *App, si: *const persist.SavedInstrument, target: *model.Instrument, plan: ApplyPlan, prev_idx: usize, target_idx: usize) void {
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
        // VST3 乐器：路径变化 → 旧实例退役（帧末按新路径惰性加载）；kind 跟随存档
        if (si.kind == 2) {
            const new_path: []const u8 = si.plugin_path;
            if (!std.mem.eql(u8, target.pluginPath(), new_path)) {
                if (target.plugin) |pl| {
                    target.plugin = null;
                    self.retirePlugin(pl);
                }
            }
            target.setPluginPath(new_path); // 路径变化时内部重置 load_failed/fail_wait
            if (si.plugin_cid.len > 0) target.setPluginCid(si.plugin_cid); // 身份（自愈匹配用）
            // 状态应用计划（商 DAW 式：旋钮级撤销走参数回放，不碰 setState）
            switch (plan) {
                .skip => {},
                .replay => |job| {
                    var ok = false;
                    if (target.pending_state == null and target.pending_state_ctrl == null) {
                        if (target.plugin) |pl| ok = runReplay(pl, job);
                    }
                    const iref = PluginSlotRef{ .kind = .instrument, .a = @intCast(self.instrumentIndexOf(target) orelse 0) };
                    if (!ok) {
                        // ID 失配/实例缺失/前提破坏 → 整块恢复兜底
                        target.clearPendingState(self.allocator);
                        target.pending_state = b64Decode(self.allocator, si.plugin_state);
                        target.pending_state_ctrl = b64Decode(self.allocator, si.plugin_state_ctrl);
                        self.markSlotStateDirty(iref);
                    } else {
                        self.markSlotStateClean(iref); // 回放后实例 = 目标状态
                    }
                },
                .full => {
                    target.clearPendingState(self.allocator);
                    target.pending_state = b64Decode(self.allocator, si.plugin_state);
                    target.pending_state_ctrl = b64Decode(self.allocator, si.plugin_state_ctrl);
                    if (self.instrumentIndexOf(target)) |ii| {
                        self.markSlotStateDirty(.{ .kind = .instrument, .a = @intCast(ii) });
                    }
                },
            }
            if (target.kit) |kit| {
                self.deinitDrumKit(kit);
                target.kit = null;
            }
            target.kind = .vst3;
            return;
        }
        if (si.kind == 1) {
            // 鼓组：确保 kit 存在并重建内容
            if (target.kit == null) {
                const kit = self.allocator.create(model.DrumKit) catch return;
                kit.* = .{};
                target.kit = kit;
            }
            self.importDrumKit(&si.kit, target.kit.?, self.instrumentIndexOf(target), prev_idx, target_idx);
            target.kind = .drumkit;
        } else {
            if (target.kit) |kit| {
                self.deinitDrumKit(kit);
                target.kit = null;
            }
            target.kind = .synth;
        }
    }

    /// 添加 VST3 乐器（Vital 等）；返回新槽位序号（失败 -1）。
    /// 实例在帧末惰性加载（`syncInstrumentPlugins`）；加载前显示占位名。
    pub fn addInstrumentVst3(self: *App, path: []const u8) i32 {
        const idx = self.addInstrument("VST3 乐器");
        if (idx < 0) return idx;
        const inst = &self.instruments.items[@intCast(idx)];
        inst.kind = .vst3;
        inst.setPluginPath(path);
        self.commitHistory("添加 VST3 乐器");
        return idx;
    }

    /// VST3 乐器加载完成后：占位名（"VST3 乐器"/"VST3 乐器 #N"）→ 插件真名。
    /// 同名去重加 #N（与 addInstrument 同规则）；非占位名（已加载过/用户自定）不动。
    /// 不做历史提交——名字随下一次正常提交/保存落盘；重做后重新加载时会再次赋名。
    pub fn renamePlaceholderInstrument(self: *App, idx: usize, real_name: []const u8) void {
        if (idx >= self.instruments.items.len) return;
        const inst = &self.instruments.items[idx];
        if (!std.mem.startsWith(u8, inst.name, "VST3 乐器")) return;
        if (real_name.len == 0) return;
        var same: usize = 0;
        for (self.instruments.items, 0..) |other, oi| {
            if (oi == idx) continue;
            if (baseNameEquals(other.name, real_name)) same += 1;
        }
        var buf: [96]u8 = undefined;
        const text = if (same == 0)
            std.fmt.bufPrint(&buf, "{s}", .{real_name}) catch return
        else
            std.fmt.bufPrint(&buf, "{s} #{d}", .{ real_name, same + 1 }) catch return;
        const d = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(inst.name);
        inst.name = d;
    }

    /// 添加乐器（自动分配名字与合成器参数）；返回新槽位序号（失败 -1）
    /// `base_name`：基础名（如 "减法合成器"）；同名自动追加 #2、#3…
    pub fn addInstrument(self: *App, base_name: []const u8) i32 {
        self.ensureAudioCapacity(self.instruments.items.len + 1, 0, 0);
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
        self.ensureKitPool(@intCast(idx)); // 惰性池：创建即分配（试听立即可用）
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

    /// 添加 **VST3 乐器层**（实例帧末惰性加载——`syncKitLayerPlugins`）。
    /// 返回是否成功（越界/层数满 → false）。一条历史的调用方负责提交。
    pub fn kitLayerAddVst3(self: *App, inst_idx: i32, pitch: u8, path: []const u8, source: []const u8) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit0 = inst.kit orelse return false;
        if (kit0.totalLayers() >= @import("audio.zig").kit_max_layers) return false;
        const pad = self.kitPadEnsure(inst_idx, pitch) orelse return false;
        const lp = self.allocator.create(synth.SynthParams) catch return false;
        lp.* = .{};
        const src: []u8 = self.allocator.dupe(u8, source) catch &.{};
        var layer = model.DrumLayer{ .kind = .vst3, .params = lp, .gain = 1.0, .source_preset = src };
        layer.setPluginPath(path);
        pad.layers.append(self.allocator, layer) catch {
            self.retireSynth(lp);
            self.allocator.free(src);
            return false;
        };
        self.ensureKitVsti(@intCast(inst_idx));
        self.dirty = true;
        return true;
    }

    /// 取/建某乐器的鼓组 VST3 层状态（惰性；契约：设备暂停窗口内——同 `ensureKitPool`）。
    /// 仅当该鼓组确实含 VST3 层时分配。
    pub fn ensureKitVsti(self: *App, i: usize) void {
        if (i >= self.engine.kit_vsti.len) return; // 容量未覆盖（sync 前 ensureAudioCapacity 已跑）
        if (self.engine.kit_vsti[i].load(.monotonic) != null) return;
        if (i >= self.instruments.items.len) return;
        const kit = self.instruments.items[i].kit orelse return;
        var has_vst3 = false;
        outer: for (kit.pads.items) |pad| {
            for (pad.layers.items) |ly| {
                if (ly.kind == .vst3) {
                    has_vst3 = true;
                    break :outer;
                }
            }
        }
        if (!has_vst3) return;
        const kv = self.allocator.create(audio.KitVstiState) catch return;
        for (&kv.evts) |*b| b.n = 0;
        @memset(&kv.active_lo, 0);
        @memset(&kv.active_hi, 0);
        self.engine.kit_vsti[i].store(kv, .release);
    }

    /// 把鼓组层从 VST3 换回减法（插件退役/待恢复状态释放；路径清空）。
    /// 减法预设应用前必须调——否则“显示减法预设但仍响插件”（实测隐患）。
    pub fn kitLayerClearVst3(self: *App, inst_idx: i32, pitch: u8, layer: usize) void {
        const ly = self.kitLayerPtr(inst_idx, pitch, layer) orelse return;
        if (ly.kind != .vst3) return;
        if (ly.plugin) |pl| {
            ly.plugin = null;
            self.retirePlugin(pl);
        }
        ly.clearPendingState(self.allocator);
        ly.kind = .subtractive;
        ly.setPluginPath("");
    }

    /// 鼓组层的展平槽位号（与 `syncParams` 展平序一致：垫按音高升序、层按序；
    /// 找不到/越界 → null）。VST3 层 panic 旗标等按槽位寻址。
    pub fn kitLayerSlot(self: *const App, inst_idx: usize, pitch: u8, layer_idx: usize) ?usize {
        if (inst_idx >= self.instruments.items.len) return null;
        const kit = self.instruments.items[inst_idx].kit orelse return null;
        var slot: usize = 0;
        for (kit.pads.items) |pad| {
            for (pad.layers.items, 0..) |_, li| {
                if (pad.pitch == pitch and li == layer_idx) return slot;
                slot += 1;
                if (slot >= @import("audio.zig").kit_max_layers) return null;
            }
        }
        return null;
    }

    /// 鼓组层指针（越界/无垫/无层 → null）
    pub fn kitLayerPtr(self: *App, inst_idx: i32, pitch: u8, layer: usize) ?*model.DrumLayer {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const kit = self.instruments.items[@intCast(inst_idx)].kit orelse return null;
        const pad = kit.find(pitch) orelse return null;
        if (layer >= pad.layers.items.len) return null;
        return &pad.layers.items[layer];
    }

    /// 鼓组 VST3 层的实例惰性加载/状态应用/编辑轮询（每帧帧末；同
    /// `main.syncInstrumentPlugins` 惯例）。放在 App 里（而非 main）：**测试可直调**——
    /// 回声/幽灵条目这类行为需要走真实帧末路径才能复现（实测教训）。
    pub fn syncKitLayerPlugins(self: *App) void {
        const sr: f64 = @floatFromInt(@max(1, self.params.sample_rate));
        for (self.instruments.items, 0..) |*inst, ii| {
            if (inst.kind != .drumkit) continue;
            const kit = inst.kit orelse continue;
            for (kit.pads.items) |*pad| {
                for (pad.layers.items, 0..) |*ly, li| {
                    if (ly.kind != .vst3) continue;
                    if (ly.plugin == null) {
                        if (ly.pluginPath().len == 0) continue;
                        if (ly.fail_wait > 0) {
                            ly.fail_wait -= 1;
                            continue;
                        }
                        ly.fail_wait = kit_plugin_retry_frames;
                        const pz = self.allocator.dupeSentinel(u8, ly.pluginPath(), 0) catch continue;
                        defer self.allocator.free(pz);
                        ly.plugin = vst_host.loadPlugin(self.allocator, pz, sr, 4096, .instrument) catch |e| {
                            if (!ly.load_failed) {
                                ly.load_failed = true;
                                self.setToastWith("鼓组层插件“{s}”加载失败：{s}（将自动重试，文件恢复后自动加载）", .{ std.fs.path.basename(ly.pluginPath()), @errorName(e) });
                            }
                            continue;
                        };
                        ly.fail_wait = 0;
                        // 回填类 CID（身份：重绑定自愈/存档）
                        _ = ly.plugin.?.cidHex(&ly.plugin_cid);
                        ly.plugin_cid_len = 32;
                        if (ly.load_failed) {
                            ly.load_failed = false;
                            self.setToastWith("鼓组层插件已恢复加载：{s}", .{ly.plugin.?.name()});
                        } else {
                            self.setToastWith("已加载鼓组层插件：{s}", .{ly.plugin.?.name()});
                        }
                    }
                    const pl = ly.plugin orelse continue;
                    // 参数缓存一次建齐（撤销“参数回放”的旧值依据；restoreState 内置重建）——
                    // 缺它 → 插件内编辑无法记增量 → 历史只靠结构信号（实测：首操作后无历史）
                    if (!pl.param_cache_valid) pl.refreshParamCache();
                    // 待恢复音色（工程加载/撤销恢复后首次就绪时应用一次；幂等）
                    if (ly.pending_state != null or ly.pending_state_ctrl != null) {
                        pl.restoreState(ly.pending_state orelse &.{}, ly.pending_state_ctrl orelse &.{});
                        ly.clearPendingState(self.allocator);
                        // 防挂音 panic：恢复可能唤醒快照里仍在发声的声部——
                        // 音频侧下一段对该层全 128 补 off（槽位 = params 展平序）
                        if (self.kitLayerSlot(ii, pad.pitch, li)) |slot| {
                            self.params.kit_layer_panic[ii][slot].store(true, .release);
                            // 恢复完成 = 该层按“已采纳”处理：插件恢复后的 getState 回声字节
                            // 与存档常不同（Vital 实症）——留着脏标会把回声当差异 → 幽灵
                            // 历史条目（乐器级同款处理）
                            self.markSlotStateClean(PluginSlotRef{ .kind = .kit_layer, .a = @intCast(ii), .b = @intCast(slot) });
                        }
                    }
                    // 插件 GUI 内编辑 → 参数增量记录 + 手势（起手提交 + 静置钉值）
                    // （同 `syncInstrumentPlugins`；层 ref = (乐器, 展平槽位)）
                    if (self.kitLayerSlot(ii, pad.pitch, li)) |slot| {
                        const lref = PluginSlotRef{ .kind = .kit_layer, .a = @intCast(ii), .b = @intCast(slot) };
                        self.drainSlotEditorEdits(lref, pl);
                        if (pl.takeDirtyNotice()) self.notePluginStructural(lref);
                    }
                }
            }
        }
    }

    // ── 音频资产 / 样式 / 片段 / 播放表（见 `docs/audio-files.md`）──

    /// 当前 BPM/拍号下的**每步帧数**（音频片段 trim ↔ 步换算用）
    pub fn framesPerStep(self: *const App) u64 {
        const sr: u64 = if (self.params.sample_rate > 0) @intCast(self.params.sample_rate) else audio_fallback_rate;
        const bpm2: u64 = @max(20, @as(u64, @intCast(std.math.clamp(self.bpm, 20, 999))));
        const spb2: u64 = @intCast(@max(1, model.stepsPerBeat(self.time_den)));
        return @max(1, sr * 60 / (bpm2 * spb2));
    }

    /// 设置基准目录（打开工程时从文件路径取父目录；相对音频路径按它解析）
    pub fn setBaseDirFromPath(self: *App, path: []const u8) void {
        const dir = std.fs.path.dirname(path) orelse "";
        const n = @min(dir.len, self.base_dir.len);
        @memcpy(self.base_dir[0..n], dir[0..n]);
        self.base_dir_len = n;
    }

    /// 存档内的音频路径 → 实际路径（绝对路径原样返回；相对路径拼基准目录）。
    /// 返回 null = 无法解析（空路径）。
    pub fn resolveAudioPath(self: *const App, stored: []const u8, buf: []u8) ?[]const u8 {
        if (stored.len == 0) return null;
        const is_abs = if (stored.len >= 2 and stored[1] == ':') true else (stored[0] == '/' or stored[0] == '\\');
        if (is_abs) return stored;
        const base = self.base_dir[0..self.base_dir_len];
        if (base.len == 0) return stored;
        return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ base, std.fs.path.sep, stored }) catch null;
    }

    /// 保存时的音频路径：在基准目录内 → 相对路径（便携）；否则原样绝对
    pub fn audioPathForSave(self: *const App, abs: []const u8, buf: []u8) []const u8 {
        _ = buf;
        const base = self.base_dir[0..self.base_dir_len];
        if (base.len == 0) return abs;
        if (std.mem.startsWith(u8, abs, base) and abs.len > base.len + 1 and
            (abs[base.len] == '\\' or abs[base.len] == '/'))
        {
            return abs[base.len + 1 ..];
        }
        return abs;
    }

    pub fn findAssetByPath(self: *const App, path: []const u8) ?usize {
        for (self.audio_assets.items, 0..) |asset, i| {
            if (std.mem.eql(u8, asset.path, path)) return i;
        }
        return null;
    }

    /// 解码音频文件进资产池（按路径去重；f32 立体声@**文件原生率**）。
    /// 失败/超限 → null；上限 = 30 分钟（v1 整文件进内存）。
    ///
    /// **P1 提速**：解码时**不重采样**（省一遍全量 SRC）；移动平均峰值
    /// **与解码合并成一遍**（桶大于 32 帧时只取 16 个等距点估计包络——
    /// 只影响显示精度，不影响声音）。播放侧靠 `SampleData.ratio` 换算采样帧。
    pub fn loadAudioAsset(self: *App, path: []const u8) ?i32 {
        if (path.len == 0) return null;
        if (self.findAssetByPath(path)) |i| return @intCast(i);
        const a = self.allocator;
        // 宽字符路径（中文路径必须——同 VST3 加载的坑）
        var wbuf: [1024]u16 = undefined;
        const wbuf_out = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return null;
        if (wbuf_out + 1 > wbuf.len) return null;
        wbuf[wbuf_out] = 0;
        const eng_sr: u32 = if (self.params.sample_rate > 0) @intCast(self.params.sample_rate) else audio_fallback_rate;
        // 采样率传 0 = 不重采样（原生率直出）
        const cfg = ma.ma_decoder_config_init(ma.ma_format_f32, 2, 0);
        var dec: ma.ma_decoder = undefined;
        if (ma.ma_decoder_init_file_w(@ptrCast(&wbuf[0]), &cfg, &dec) != ma.MA_SUCCESS) return null;
        defer _ = ma.ma_decoder_uninit(&dec);
        var native_sr: ma.ma_uint32 = eng_sr;
        var ch_out: ma.ma_uint32 = 2;
        var fmt_out: ma.ma_format = ma.ma_format_f32;
        if (ma.ma_decoder_get_data_format(&dec, &fmt_out, &ch_out, &native_sr, null, 0) != ma.MA_SUCCESS) return null;
        if (native_sr == 0) native_sr = eng_sr;
        var total: ma.ma_uint64 = 0;
        if (ma.ma_decoder_get_length_in_pcm_frames(&dec, &total) != ma.MA_SUCCESS) return null;
        const max_frames: u64 = @as(u64, native_sr) * 60 * 30;
        if (total == 0 or total > max_frames) return null;
        const nframes: usize = @intCast(total);
        const frames = a.alloc(f32, nframes * 2) catch return null;
        errdefer a.free(frames);
        // 峰值：桶大小先算（目标 ~4096 桶；桶大时抽样——与解码单遍完成）
        const bucket: usize = @max(1, nframes / 4096);
        const npeaks: usize = (nframes + bucket - 1) / bucket;
        const peaks = a.alloc(AudioAsset.Peak, npeaks) catch {
            a.free(frames);
            return null;
        };
        errdefer a.free(peaks);
        const stride: usize = if (bucket > 32) @max(1, bucket / 16) else 1;
        var got_total: usize = 0;
        while (got_total < nframes) {
            var got: ma.ma_uint64 = 0;
            const want: ma.ma_uint64 = @intCast(nframes - got_total);
            if (ma.ma_decoder_read_pcm_frames(&dec, frames.ptr + got_total * 2, want, &got) != ma.MA_SUCCESS) break;
            if (got == 0) break;
            const s0 = got_total;
            const s1 = got_total + @as(usize, @intCast(got));
            // 峰值算法**单一真源**在 `audio_import.updatePeaks`（异步导入的 worker 用同一份）
            audio_import.Manager.updatePeaks(frames, s0, s1, peaks, bucket, stride);
            got_total = s1;
        }
        if (got_total == 0) return null;
        // 未解码到的尾部桶：置零
        var pz = got_total / bucket;
        while (pz < npeaks) : (pz += 1) peaks[pz] = .{ .min = 0, .max = 0 };
        const path_dup = a.dupe(u8, path) catch {
            a.free(frames);
            a.free(peaks);
            return null;
        };
        errdefer a.free(path_dup);
        // **单独分配**：池子扩容时资产本体不移动（播放表里存的是 &asset.data）
        const asset = a.create(AudioAsset) catch {
            a.free(path_dup);
            a.free(frames);
            a.free(peaks);
            return null;
        };
        asset.* = .{
            .path = path_dup,
            .data = .{ .frames = frames, .frame_count = got_total, .ratio = @floatCast(@as(f64, @floatFromInt(native_sr)) / @as(f64, @floatFromInt(eng_sr))) },
            .peaks = peaks,
            .peak_frames = @intCast(bucket),
        };
        self.audio_assets.append(a, asset) catch {
            a.destroy(asset);
            a.free(path_dup);
            a.free(frames);
            a.free(peaks);
            return null;
        };
        return @intCast(self.audio_assets.items.len - 1);
    }

    /// 释放全部资产（**契约：先暂停设备**——音频线程可能正在读；工程切换/退出时用）
    pub fn resetAudioAssets(self: *App) void {
        // 先停掉导入（worker 可能正在往将要释放的样式/资产里写）——阻塞最多一个解码块
        self.import_mgr.cancelAll();
        self.import_mgr.drain();
        for (self.audio_assets.items) |asset| {
            self.allocator.free(asset.path);
            if (asset.data.frames.len > 0) self.allocator.free(asset.data.frames);
            if (asset.peaks.len > 0) self.allocator.free(asset.peaks);
            self.allocator.destroy(asset);
        }
        self.audio_assets.deinit(self.allocator);
        self.audio_assets = .empty;
        self.params.preview_asset.store(null, .release);
        self.preview = .{};
    }

    pub fn audioStyleFindByPath(self: *const App, path: []const u8) ?usize {
        for (self.audio_styles.items, 0..) |*st, i| {
            if (std.mem.eql(u8, st.path, path)) return i;
        }
        return null;
    }

    /// 新建音频样式（同路径去重；名称缺省 = 文件名）
    pub fn audioStyleAdd(self: *App, path: []const u8, name: []const u8) ?i32 {
        if (self.audioStyleFindByPath(path)) |i| return @intCast(i);
        const a = self.allocator;
        const nm = if (name.len > 0) name else std.fs.path.basename(path);
        const nd = a.dupe(u8, nm) catch return null;
        const pd = a.dupe(u8, path) catch {
            a.free(nd);
            return null;
        };
        const ai = self.loadAudioAsset(path) orelse -1;
        self.audio_styles.append(a, .{ .name = nd, .path = pd, .asset = ai, .channel = 0, .gain = 1.0 }) catch {
            a.free(nd);
            a.free(pd);
            return null;
        };
        return @intCast(self.audio_styles.items.len - 1);
    }

    /// 注入进程 Io（`main` 启动时调用；测试用 `std.testing.io`）
    pub fn attachIo(self: *App, io: std.Io) void {
        self.io = io;
    }

    /// 引擎采样率（未初始化时用回退值；异步导入的 ratio 用它算）
    fn engSampleRate(self: *const App) u32 {
        return if (self.params.sample_rate > 0) @intCast(self.params.sample_rate) else audio_fallback_rate;
    }

    /// **异步**新建音频样式（P2）：只读文件头（毫秒级）→ 建样式 + 入队；解码在 worker。
    /// - 导入完成前 `style.asset == -1`，UI 用 `styleImportProgress` 画进度；
    /// - 片段长度用 `style.frames_hint`（文件头时长）——**解码前就能算对**；
    /// - 同路径去重（包括正在导入中的）；失败（非音频/超长/读不到头）→ null。
    pub fn audioStyleAddAsync(self: *App, path: []const u8, name: []const u8) ?i32 {
        if (path.len == 0) return null;
        if (self.audioStyleFindByPath(path)) |i| return @intCast(i);
        const io = self.io orelse return null;
        const eng_sr = self.engSampleRate();
        const hdr = audio_import.Manager.probeFile(path, eng_sr) orelse return null;
        const a = self.allocator;
        const nm = if (name.len > 0) name else std.fs.path.basename(path);
        const nd = a.dupe(u8, nm) catch return null;
        const pd = a.dupe(u8, path) catch {
            a.free(nd);
            return null;
        };
        self.audio_styles.append(a, .{
            .name = nd,
            .path = pd,
            .asset = -1,
            .channel = 0,
            .gain = 1.0,
            .frames_hint = hdr.eng_frames,
        }) catch {
            a.free(nd);
            a.free(pd);
            return null;
        };
        const idx = self.audio_styles.items.len - 1;
        // 入队失败：样式保留（asset = -1 → 片段画“音频缺失”），不崩不泄
        _ = self.import_mgr.enqueue(a, io, path, idx, hdr, eng_sr);
        return @intCast(idx);
    }

    /// 该样式是否正在导入 → 返回 0..1 进度（未在导入 → null）
    pub fn styleImportProgress(self: *const App, style: usize) ?f32 {
        if (!self.import_mgr.started) return null;
        return self.import_mgr.progressFor(style);
    }

    /// 每帧：收尾已结束的导入（done → 过继缓冲；failed → toast）。
    /// 调用点在 `main` 主循环里、`rebuildAudioTable` **之前**——保证同帧出声。
    pub fn pollImports(self: *App) void {
        if (!self.import_mgr.started) return;
        while (self.import_mgr.takeFinished()) |job| self.finalizeImport(job);
        self.import_mgr.promote();
    }

    fn finalizeImport(self: *App, job: *audio_import.Job) void {
        const st = job.state.load(.acquire);
        const a = self.allocator;
        defer self.import_mgr.destroyJob(job);
        switch (st) {
            .done => {
                const bufs = self.import_mgr.takeBuffers(job);
                const pd = a.dupe(u8, job.path) catch {
                    if (bufs.frames.len > 0) a.free(bufs.frames);
                    if (bufs.peaks.len > 0) a.free(bufs.peaks);
                    return;
                };
                const nat_sr: u32 = @max(1, job.native_sr);
                const eng_sr: u32 = @max(1, job.eng_sr);
                // **单独分配**：池子扩容时不移动已有资产（播放表存的是 `&asset.data`）
                const asset = a.create(AudioAsset) catch {
                    a.free(pd);
                    if (bufs.frames.len > 0) a.free(bufs.frames);
                    if (bufs.peaks.len > 0) a.free(bufs.peaks);
                    return;
                };
                asset.* = .{
                    .path = pd,
                    .data = .{
                        .frames = bufs.frames,
                        .frame_count = @intCast(bufs.got_frames),
                        .ratio = @floatCast(@as(f64, @floatFromInt(nat_sr)) / @as(f64, @floatFromInt(eng_sr))),
                    },
                    .peaks = bufs.peaks,
                    .peak_frames = bufs.peak_frames,
                };
                self.audio_assets.append(a, asset) catch {
                    a.destroy(asset);
                    a.free(pd);
                    if (bufs.frames.len > 0) a.free(bufs.frames);
                    if (bufs.peaks.len > 0) a.free(bufs.peaks);
                    return;
                };
                const ai: i32 = @intCast(self.audio_assets.items.len - 1);
                if (job.style < self.audio_styles.items.len) self.audio_styles.items[job.style].asset = ai;
            },
            .failed => {
                // 用 job 记录的原因（打不开 / 解码失败）——比“导入失败”更能定位问题
                const why = @as(audio_import.FailReason, @fromBackingInt(@intCast(job.fail_reason.load(.acquire)))).text();
                self.setToastWith("音频导入失败：{s}（{s}）", .{ std.fs.path.basename(job.path), why });
            },
            else => {},
        }
    }

    /// 样式 → 资产（无效 → null）
    pub fn audioStyleAsset(self: *const App, style: usize) ?*AudioAsset {
        if (style >= self.audio_styles.items.len) return null;
        const si = self.audio_styles.items[style].asset;
        if (si < 0 or si >= @as(i32, @intCast(self.audio_assets.items.len))) return null;
        return self.audio_assets.items[@intCast(si)];
    }

    /// 删除音频样式后**修正所有索引引用**：引用它的片段一并删除（与音符样式删除同语义），
    /// 更大的索引前移；选择/波形窗口/右键菜单同步跟随。返回被连带删除的片段数。
    fn remapAudioStyleRefs(self: *App, removed: i32) usize {
        var dropped: usize = 0;
        var i: usize = 0;
        while (i < self.clips.items.len) {
            const c = &self.clips.items[i];
            if (c.audio_style == removed) {
                _ = self.clips.swapRemove(i);
                dropped += 1;
                continue;
            }
            if (c.audio_style > removed) c.audio_style -= 1;
            i += 1;
        }
        if (self.audio_style_sel == removed) {
            self.audio_style_sel = -1;
        } else if (self.audio_style_sel > removed) {
            self.audio_style_sel -= 1;
        }
        if (self.panels.ctx_audio_style) |s| {
            if (s == removed) {
                self.panels.ctx_audio_style = null;
            } else if (s > removed) {
                self.panels.ctx_audio_style = s - 1;
            }
        }
        if (self.wave_win.open) {
            if (self.wave_win.style) |s| {
                if (s == removed) {
                    self.wave_win.open = false; // 正看着被删的样式 → 关闭
                } else if (s > removed) {
                    self.wave_win.style = s - 1;
                }
            }
            if (self.wave_win.clip != null) self.wave_win.open = false; // 片段下标会移位：直接关
        }
        return dropped;
    }

    /// 删除音频样式（**顺序删除**以保持索引语义；连带删除引用它的片段）。
    /// 返回连带删除的片段数（>=0）；越界返回 null。调用方负责 commitHistory。
    pub fn removeAudioStyle(self: *App, idx: usize) ?usize {
        if (idx >= self.audio_styles.items.len) return null;
        // 进行中/排队中的导入：引用该样式的取消，更大索引的 job 前移
        self.import_mgr.remapAfterRemove(idx);
        const st = self.audio_styles.items[idx];
        _ = self.audio_styles.orderedRemove(idx);
        self.allocator.free(st.name);
        self.allocator.free(st.path);
        const dropped = self.remapAudioStyleRefs(@intCast(idx));
        self.dirty = true;
        return dropped;
    }

    /// 片段 → 资产（音频片段有效 → 资产的采样数据）
    pub fn clipAudioData(self: *const App, c: model.Clip) ?*const audio.SampleData {
        if (!c.isAudio()) return null;
        const asset = self.audioStyleAsset(@intCast(c.audio_style)) orelse return null;
        return &asset.data;
    }

    /// 在播放列表放入一个音频片段（自然时长按当前 BPM 折算；v1 不变速）
    pub fn audioClipAdd(self: *App, style_idx: i32, track: i32, start: i32) ?usize {
        if (style_idx < 0 or style_idx >= @as(i32, @intCast(self.audio_styles.items.len))) return null;
        var steps: i32 = 4;
        // 异步导入未完成时资产还没挂上 → 用文件头的 `frames_hint`（长度一样是对的）
        const eng_frames: u64 = if (self.audioStyleAsset(@intCast(style_idx))) |asset|
            asset.data.engFrames()
        else
            self.audio_styles.items[@intCast(style_idx)].frames_hint;
        if (eng_frames > 0) {
            const sr: u64 = if (self.params.sample_rate > 0) self.params.sample_rate else audio_fallback_rate;
            const bpm2: u64 = @max(20, @as(u64, @intCast(std.math.clamp(self.bpm, 20, 999))));
            const spb2: u64 = @intCast(@max(1, model.stepsPerBeat(self.time_den)));
            const step_frames: u64 = @max(1, sr * 60 / (bpm2 * spb2));
            steps = @intCast(@max(1, eng_frames / step_frames));
        }
        self.addClip(.{
            .track = track,
            .start = @max(0, start),
            .len = steps,
            .pattern = 0,
            .audio_style = style_idx,
        });
        return self.clips.items.len - 1;
    }

    /// 帧末：重建并发布音频片段播放表（脏才重建；旧表退役倒计时）
    /// 帧末：重建并发布音频片段播放表。
    ///
    /// **每帧重新计算 + 逐字段比对，内容变了才发布**（不做脏标门控）——
    /// 历史的脏标复用曾经漏置/提前消费，导致“拖入后首次不响、动一下片段或切
    /// PAT/SONG 才响”（实测 bug）。行数很少，逐帧比对成本可忽略；顺带能捕捉
    /// **资产列表扩容后指针失效**（指针变了 → 重发）。
    pub fn rebuildAudioTable(self: *App) void {
        const a = self.allocator;
        self.reapRetiredAudioTables();
        // 目标行：PAT 模式恒为空（音频片段只在 SONG 模式发声——用户拍板）
        self.audio_scratch.clearRetainingCapacity();
        if (self.sel.song_mode) {
            for (self.clips.items) |c| {
                if (!c.isAudio()) continue;
                // **跟随轨道静音开关**（与音符片段同语义：静音轨道的片段整段不发声）
                if (c.track >= 0 and self.trackMuted(@intCast(c.track))) continue;
                if (c.audio_style < 0 or c.audio_style >= @as(i32, @intCast(self.audio_styles.items.len))) continue;
                const asset = self.audioStyleAsset(@intCast(c.audio_style)) orelse continue;
                const st = self.audio_styles.items[@intCast(c.audio_style)];
                self.audio_scratch.append(a, .{
                    .start = c.start,
                    .len = c.len,
                    .asset = &asset.data,
                    .trim_start = c.trim_start,
                    .trim_len = c.trim_len,
                    .channel = @intCast(std.math.clamp(st.channel, 0, 65535)),
                    .gain = st.gain,
                    .speed = st.speed,
                }) catch return; // OOM：保留旧表，下帧重试
            }
        }
        // 与已发布表逐字段比对（结构体有 padding，不能用 mem.eql）
        var same = false;
        if (self.params.audio_table.load(.acquire)) |cur| {
            same = cur.rows.len == self.audio_scratch.items.len;
            if (same) {
                for (cur.rows, self.audio_scratch.items) |x, y| {
                    if (x.start != y.start or x.len != y.len or x.asset != y.asset or
                        x.trim_start != y.trim_start or x.trim_len != y.trim_len or
                        x.channel != y.channel or x.gain != y.gain or x.speed != y.speed)
                    {
                        same = false;
                        break;
                    }
                }
            }
        }
        if (same) {
            return;
        }
        const tbl = a.create(audio.AudioTable) catch return;
        tbl.* = .{ .rows = a.dupe(audio.AudioTableRow, self.audio_scratch.items) catch {
            a.destroy(tbl);
            return;
        } };
        if (self.params.audio_table.swap(tbl, .acq_rel)) |old| {
            self.audio_tables_retired.append(a, .{ .tbl = old, .countdown = 3 }) catch {
                if (old.rows.len > 0) a.free(@constCast(old.rows));
                a.destroy(@constCast(old));
            };
        }
    }

    fn reapRetiredAudioTables(self: *App) void {
        var i: usize = 0;
        while (i < self.audio_tables_retired.items.len) {
            const r = &self.audio_tables_retired.items[i];
            if (r.countdown == 0) {
                if (r.tbl.rows.len > 0) self.allocator.free(@constCast(r.tbl.rows));
                self.allocator.destroy(@constCast(r.tbl));
                _ = self.audio_tables_retired.swapRemove(i);
            } else {
                r.countdown -= 1;
                i += 1;
            }
        }
    }

    /// 释放全部播放表（退出时；需先停音频）
    fn deinitAudioTables(self: *App) void {
        if (self.params.audio_table.swap(null, .acq_rel)) |tbl| {
            if (tbl.rows.len > 0) self.allocator.free(@constCast(tbl.rows));
            self.allocator.destroy(@constCast(tbl));
        }
        var i: usize = 0;
        while (i < self.audio_tables_retired.items.len) : (i += 1) {
            const r = self.audio_tables_retired.items[i];
            if (r.tbl.rows.len > 0) self.allocator.free(r.tbl.rows);
            self.allocator.destroy(r.tbl);
        }
        self.audio_tables_retired.deinit(self.allocator);
        self.audio_tables_retired = .empty;
        self.audio_scratch.deinit(self.allocator);
        self.audio_scratch = .empty;
    }

    /// 采样器层：资产指针（声部渲染用）
    pub fn kitLayerAssetData(self: *const App, ly: *const model.DrumLayer) ?*const audio.SampleData {
        if (ly.asset_idx < 0 or ly.asset_idx >= @as(i32, @intCast(self.audio_assets.items.len))) return null;
        return &self.audio_assets.items[@intCast(ly.asset_idx)].data;
    }

    /// 添加 **采样器层**（一次性原速；v1 不跟随音高）。返回是否成功。
    pub fn kitLayerAddSampler(self: *App, inst_idx: i32, pitch: u8, path: []const u8) bool {
        if (inst_idx < 0 or inst_idx >= @as(i32, @intCast(self.instruments.items.len))) return false;
        const inst = &self.instruments.items[@intCast(inst_idx)];
        const kit0 = inst.kit orelse return false;
        if (kit0.totalLayers() >= @import("audio.zig").kit_max_layers) return false;
        const pad = self.kitPadEnsure(inst_idx, pitch) orelse return false;
        const lp = self.allocator.create(synth.SynthParams) catch return false;
        lp.* = .{};
        const src: []u8 = self.allocator.dupe(u8, std.fs.path.basename(path)) catch &.{};
        var layer = model.DrumLayer{ .kind = .sampler, .params = lp, .gain = 1.0, .source_preset = src };
        layer.setAssetPath(path);
        layer.asset_idx = self.loadAudioAsset(path) orelse -1;
        layer.load_failed = layer.asset_idx < 0;
        pad.layers.append(self.allocator, layer) catch {
            self.retireSynth(lp);
            self.allocator.free(src);
            return false;
        };
        self.ensureKitSampler(@intCast(inst_idx));
        self.dirty = true;
        return true;
    }

    /// 给已有采样器层换采样（对话框结果）：重置 trim；返回是否加载成功
    pub fn kitSamplerSetSample(self: *App, inst_idx: i32, pitch: u8, layer: usize, path: []const u8) bool {
        const ly = self.kitLayerPtr(inst_idx, pitch, layer) orelse return false;
        if (ly.kind != .sampler) return false;
        ly.setAssetPath(path);
        ly.asset_idx = self.loadAudioAsset(path) orelse -1;
        ly.load_failed = ly.asset_idx < 0;
        ly.trim_start = 0;
        ly.trim_len = 0;
        if (self.allocator.dupe(u8, std.fs.path.basename(path))) |nm| {
            self.allocator.free(ly.source_preset);
            ly.source_preset = nm;
        } else |_| {}
        self.dirty = true;
        return ly.asset_idx >= 0;
    }

    /// 取/建某乐器的鼓组采样器层状态（惰性；契约：设备暂停窗口内——同 `ensureKitPool`）
    pub fn ensureKitSampler(self: *App, i: usize) void {
        if (i >= self.engine.kit_sampler.len) return;
        if (self.engine.kit_sampler[i].load(.monotonic) != null) return;
        if (i >= self.instruments.items.len) return;
        const kit = self.instruments.items[i].kit orelse return;
        var has = false;
        outer: for (kit.pads.items) |pad| {
            for (pad.layers.items) |ly| {
                if (ly.kind == .sampler) {
                    has = true;
                    break :outer;
                }
            }
        }
        if (!has) return;
        const ks = self.allocator.create(audio.KitSamplerState) catch return;
        ks.* = .{};
        self.engine.kit_sampler[i].store(ks, .release);
    }

    /// 打开音频**样式**波形窗口（双击样式列表的“♪”行；trim 不可编辑）
    pub fn openWaveForStyle(self: *App, style: usize) void {
        if (style >= self.audio_styles.items.len) return;
        self.wave_win = .{ .open = true, .x = self.wave_win.x, .y = self.wave_win.y, .w = self.wave_win.w, .h = self.wave_win.h, .z = self.wave_win.z, .style = style };
        self.bringToFront(&self.wave_win.z);
    }

    // ── 波形窗口试听（全局单实例；音频线程播放并回写游标）──

    /// 打开音频片段波形窗口
    pub fn openWaveForClip(self: *App, idx: usize) void {
        if (idx >= self.clips.items.len or !self.clips.items[idx].isAudio()) return;
        self.wave_win = .{ .open = true, .x = self.wave_win.x, .y = self.wave_win.y, .w = self.wave_win.w, .h = self.wave_win.h, .z = self.wave_win.z, .clip = idx };
        self.bringToFront(&self.wave_win.z);
    }

    /// 打开鼓组采样器层波形窗口
    pub fn openWaveForLayer(self: *App, inst_idx: i32, pitch: u8, layer: usize) void {
        const ly = self.kitLayerPtr(inst_idx, pitch, layer) orelse return;
        if (ly.kind != .sampler) return;
        self.wave_win = .{ .open = true, .x = self.wave_win.x, .y = self.wave_win.y, .w = self.wave_win.w, .h = self.wave_win.h, .z = self.wave_win.z, .layer = .{ .instrument = inst_idx, .pitch = pitch, .layer = layer } };
        self.bringToFront(&self.wave_win.z);
    }

    /// 试听（可指定**循环**：采样器层在 trim 区间内循环，像钢琴窗的循环选区）
    pub fn previewStartEx(self: *App, asset: i32, start: i32, len: i32, channel: i32, gain: f32, speed: f32, loop: bool) void {
        if (asset < 0 or asset >= @as(i32, @intCast(self.audio_assets.items.len))) return;
        const data = self.audio_assets.items[@intCast(asset)].data;
        if (data.frame_count == 0) return;
        const s = std.math.clamp(start, 0, @as(i32, @intCast(data.engFrames() - 1)));
        // 注意：**整结构重建会把 loop 冲回默认值**（实测 bug：点播放后循环按钮自己亮/灭）
        const keep_loop = self.preview.loop;
        self.preview = .{
            .asset = asset,
            .channel = @intCast(std.math.clamp(channel, 0, 65535)),
            .gain = gain,
            .active = true,
            .pos = s,
            .playing = true,
            .loop = keep_loop,
        };
        self.params.preview_asset.store(&self.audio_assets.items[@intCast(asset)].data, .release);
        self.params.preview_start.store(s, .monotonic);
        self.params.preview_len.store(len, .monotonic);
        self.params.preview_gain.store(gain, .monotonic);
        self.params.preview_speed.store(std.math.clamp(speed, 0.25, 4.0), .monotonic);
        self.params.preview_channel.store(self.preview.channel, .monotonic);
        self.params.preview_pos.store(s, .monotonic);
        self.params.preview_loop.store(loop, .monotonic);
        self.params.preview_playing.store(true, .monotonic);
    }

    /// 停止试听：**游标停在 `cursor`**（= 下次 ▶ 的起点）。
    /// 采样器层传 trim 左端点，样式/片段传 0。
    pub fn previewStopAt(self: *App, cursor: i32) void {
        self.preview.playing = false;
        self.preview.active = false;
        self.preview.seeking = false;
        const cp = @max(0, cursor);
        self.preview.pos = cp; // 白线可见地留在起点
        self.params.preview_playing.store(false, .monotonic);
        self.params.preview_pos.store(cp, .monotonic);
    }

    pub fn previewStop(self: *App) void {
        self.previewStopAt(0);
    }

    /// 暂停试听：停播但**保留暂停点**（再按播放从该处继续）
    pub fn previewPause(self: *App) void {
        self.preview.playing = false;
        self.preview.active = false;
        self.params.preview_playing.store(false, .monotonic);
    }

    /// 音频样式速度（片段波形绘制/引擎共用）
    pub fn audioStyleSpeed(self: *const App, clip: model.Clip) f32 {
        if (clip.audio_style >= 0 and @as(usize, @intCast(clip.audio_style)) < self.audio_styles.items.len) return self.audio_styles.items[@intCast(clip.audio_style)].speed;
        return 1.0;
    }

    /// 帧末：取回音频线程回写的试听游标
    pub fn pollPreview(self: *App) void {
        if (!self.preview.active or self.preview.seeking) return; // 暂停/停止/拖拽中：保留本地游标
        const p = self.params.preview_pos.load(.monotonic);
        const still_playing = self.params.preview_playing.load(.monotonic);
        if (p < 0 or !still_playing) {
            // 音频线程停了（不循环播完 / 越界）：**游标留在起点**（= 下次 ▶ 的起点），不留 -1
            self.preview.active = false;
            self.preview.playing = false;
            if (p >= 0) self.preview.pos = p;
            return;
        }

        self.preview.pos = p;
    }
    /// 帧末：取主输出峰值/削波计数（状态栏电平表；削波显示保持 ~0.5s）
    pub fn pollOutMeter(self: *App) void {
        const p = self.params.out_peak.load(.monotonic);
        self.out_peak = p;
        self.out_peak_hold = @max(self.out_peak_hold * 0.9, p);
        const over = self.params.out_over.swap(0, .monotonic);
        if (over > 0) {
            self.out_over_hold = 30; // ≈0.5s @60fps
        } else if (self.out_over_hold > 0) {
            self.out_over_hold -= 1;
        }
    }

    // ── 音频样式：历史/存档的导出导入 ──

    /// 导出音频样式（`relative` = 存档用相对路径；历史快照用绝对路径）
    fn exportAudioStyles(self: *App, alloc: std.mem.Allocator, relative: bool) ![]persist.SavedAudioStyle {
        const out = try alloc.alloc(persist.SavedAudioStyle, self.audio_styles.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |*s| self.freeSavedAudioStyle(s);
            alloc.free(out);
        }
        for (self.audio_styles.items) |*st| {
            var rel_buf: [1024]u8 = undefined;
            const p = if (relative) self.audioPathForSave(st.path, &rel_buf) else st.path;
            out[n] = .{
                .name = try alloc.dupe(u8, st.name),
                .path = try alloc.dupe(u8, p),
                .channel = st.channel,
                .gain = st.gain,
                .speed = st.speed,
            };
            n += 1;
        }
        return out;
    }

    fn freeSavedAudioStyle(self: *App, s: *const persist.SavedAudioStyle) void {
        self.allocator.free(s.name);
        self.allocator.free(s.path);
    }

    fn freeSavedAudioStyles(self: *App, styles: []persist.SavedAudioStyle) void {
        for (styles) |*s| self.freeSavedAudioStyle(s);
        self.allocator.free(styles);
    }

    /// 导入音频样式表（**整表替换**，下标与存档一致；相对路径按基准目录解析）
    pub fn importAudioStyles(self: *App, styles: []const persist.SavedAudioStyle) void {
        // 样式数组即将整块替换 → 进行中的导入全部作废（否则 job 里的 style 下标会指错）
        self.import_mgr.cancelAll();
        self.import_mgr.drain();
        for (self.audio_styles.items) |*st| {
            self.allocator.free(st.name);
            self.allocator.free(st.path);
        }
        self.audio_styles.clearRetainingCapacity();
        for (styles) |s| self.importAudioStyleOne(s);
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
        var ly = pad.layers.orderedRemove(layer_idx);
        self.retireSynth(ly.params);
        if (ly.plugin) |pl| self.retirePlugin(pl);
        ly.clearPendingState(self.allocator);
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
        var inst_rm = inst; // 可变副本（清 pending 后本体即将移除）
        if (inst.plugin) |pl| self.retirePlugin(pl); // VST3 乐器实例延迟销毁（音频线程安全）
        inst_rm.clearPendingState(self.allocator);
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
        self.kit_shift_log.append(self.allocator, idx) catch {}; // 鼓组池帧末左移对齐
        self.kit_gc_pending = true;
        self.shrink_pending = true; // 帧末尝试回收容量
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

    /// 登记待升级（旧版 JSON 存档；弹窗确认前不打开——③ 迁移流程）
    pub fn setPendingUpgrade(self: *App, path: []const u8, version: u32) void {
        self.clearPendingUpgrade();
        self.pending_upgrade_path = self.allocator.dupe(u8, path) catch null;
        self.pending_upgrade_version = version;
    }
    pub fn clearPendingUpgrade(self: *App) void {
        if (self.pending_upgrade_path) |p| self.allocator.free(p);
        self.pending_upgrade_path = null;
        self.pending_upgrade_version = 0;
    }

    /// 释放全部乐器（名字 + 合成器参数，含退役的）+ 保存相关字段——进程退出时调用
    pub fn deinitAll(self: *App) void {
        // 异步导入：先停 worker（join）——之后才能安全释放缓冲/资产
        self.import_mgr.deinit();
        self.clearGesture(); // 手势增量列表（无引擎依赖）先释放
        // 插件实例：引擎已停（main 的 defer 顺序保证）→ 直接同步销毁；
        // 退役列表中未到期的也必须在此强制释放（之后没人再跑回收）
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.plugin) |pl| {
                    es.plugin = null;
                    vst_host.unloadPlugin(self.allocator, pl);
                }
            }
        }
        // VST3 乐器实例：引擎已停 → 同步卸载（**含鼓组 VST3 层实例**——
        // 旧版漏了层：退出时不析构、测试分配器报泄漏；层清理晚于退役列表冲刷）
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                inst.plugin = null;
                vst_host.unloadPlugin(self.allocator, pl);
            }
            inst.clearPendingState(self.allocator);
            if (inst.kit) |kit| {
                for (kit.pads.items) |*pad| {
                    for (pad.layers.items) |*ly| {
                        if (ly.plugin) |pl| {
                            ly.plugin = null;
                            vst_host.unloadPlugin(self.allocator, pl);
                        }
                        ly.clearPendingState(self.allocator);
                    }
                }
            }
        }
        for (self.retired_plugins.items) |r| vst_host.unloadPlugin(self.allocator, r.pl);
        self.retired_plugins.deinit(self.allocator);
        self.retired_plugins = .empty;
        // 效果器状态盒：退役列表 + 链上活槽（引擎已停 → 同步销毁）
        for (self.retired_fx.items) |r| self.allocator.destroy(r.box);
        self.retired_fx.deinit(self.allocator);
        self.retired_fx = .empty;
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.fx_state) |box| {
                    es.fx_state = null;
                    self.allocator.destroy(box);
                }
            }
        }
        if (self.project_path) |p| self.allocator.free(p);
        if (self.toast) |t| self.allocator.free(t);
        if (self.title_applied_name) |n| self.allocator.free(n);
        if (self.pending_open_path) |p| self.allocator.free(p);
        self.project_path = null;
        self.toast = null;
        self.title_applied_name = null;
        self.pending_open_path = null;
        self.clearPendingUpgrade();
        self.clipboard_notes.deinit(self.allocator);
        self.clipboard_clips.deinit(self.allocator);
        self.playlist.draw_order.deinit(self.allocator);
        self.piano.draw_order.deinit(self.allocator);
        self.batch_snap.deinit(self.allocator);
        self.deinitMixerChannels();
        self.deinitHistory();
        self.state_pool.deinit(self.allocator); // 历史释放完后兜底清池（防漏）
        self.deinitPatterns();
        self.deinitTracks();
        self.deinitPatStats();
        self.deinitInstruments();
        self.preset_lib.deinit(self.allocator);
        if (self.instr_state_dirty.len > 0) self.allocator.free(self.instr_state_dirty);
        self.instr_state_dirty = &.{};
        for (self.kit_layer_state_dirty) |r| if (r.len > 0) self.allocator.free(r);
        if (self.kit_layer_state_dirty.len > 0) self.allocator.free(self.kit_layer_state_dirty);
        self.kit_layer_state_dirty = &.{};
        for (self.fx_state_dirty) |r| if (r.len > 0) self.allocator.free(r);
        if (self.fx_state_dirty.len > 0) self.allocator.free(self.fx_state_dirty);
        self.fx_state_dirty = &.{};
        self.engine.deinit(); // 音频引擎容量池（无设备/重复调用均幂等）
        self.deinitAudioTables();
        self.resetAudioAssets();
        for (self.audio_styles.items) |*st| {
            self.allocator.free(st.name);
            self.allocator.free(st.path);
        }
        self.audio_styles.deinit(self.allocator);
        self.audio_styles = .empty;
        self.params.deinit(self.allocator);
        self.kit_shift_log.deinit(self.allocator);
        self.kit_shift_log = .empty;
    }

    /// 工程加载（**异步解码**，P3）：打开工程时**只读文件头**建样式 + 入队，
    /// 解码交给 P2 的 worker —— UI 线程（窗口拖动/最大化/重绘）全程不被阻塞。
    ///
    /// - 片段/音符/乐器等内容**立刻**建好 → 时间轴马上可见；
    /// - 音频片段在解码完成前画"载入 N%"（`styleImportProgress`），完成后自动出声；
    /// - `parsed` 的所有权**转移**进来（拷贝完就释放）；`path` 复制一份。
    /// - 无 io（单测/异常）→ 退回同步解码（保持确定性）。
    pub fn beginProjectLoadAsync(self: *App, parsed: std.json.Parsed(persist.Project), path: ?[]const u8) void {
        const p = parsed.value;
        self.importProjectPrepare(p);
        const eng_sr = self.engSampleRate();
        const io_opt = self.io;
        if (io_opt == null) {
            for (p.audio_styles) |s| self.importAudioStyleOne(s);
            self.importProjectBody(p);
            if (path) |pth| self.setProjectPath(pth);
            self.resetHistory("打开工程");
            self.markSaved();
            parsed.deinit();
            return;
        }
        const io = io_opt.?;
        const a = self.allocator;
        // 音频样式：建样式（asset=-1）+ 入队（probe 只读头，毫秒级；失败 → 保持缺失态）
        for (p.audio_styles) |s| {
            var path_buf: [1024]u8 = undefined;
            const resolved = self.resolveAudioPath(s.path, &path_buf) orelse s.path;
            const nd = a.dupe(u8, s.name) catch continue;
            const pd = a.dupe(u8, resolved) catch {
                a.free(nd);
                continue;
            };
            // 已经解过的文件（同一次加载里重复引用/池里已有）→ 直接挂上，不再重复解码
            var ai: i32 = -1;
            var hint: u64 = 0;
            var hdr_opt: ?audio_import.Header = null; // **探测一次就够**（每多探一次就多开一次文件）
            if (self.findAssetByPath(resolved)) |existing| {
                ai = @intCast(existing);
            } else if (audio_import.Manager.probeFile(resolved, eng_sr)) |hdr| {
                hint = hdr.eng_frames;
                hdr_opt = hdr;
            }
            self.audio_styles.append(a, .{
                .name = nd,
                .path = pd,
                .asset = ai,
                .channel = s.channel,
                .gain = s.gain,
                .speed = s.speed,
                .frames_hint = hint,
            }) catch {
                a.free(nd);
                a.free(pd);
                continue;
            };
            if (ai < 0) {
                if (hdr_opt) |hdr| {
                    const style_idx = self.audio_styles.items.len - 1;
                    _ = self.import_mgr.enqueue(a, io, pd, style_idx, hdr, eng_sr);
                }
            }
        }
        self.importProjectBody(p);
        if (path) |pth| self.setProjectPath(pth);
        self.resetHistory("打开工程"); // 打开 = 新基线（旧历史作废）
        self.markSaved();
        self.setToastWith("已打开：{s}", .{if (path) |pth| pth else "工程"});
        parsed.deinit(); // 内容已拷进 App → 解析数据可立刻释放
    }

    /// 还有多少个音频样式在后台解码（状态栏提示用）
    pub fn audioLoadPending(self: *const App) usize {
        if (!self.import_mgr.started) return 0;
        var n: usize = 0;
        for (0..self.audio_styles.items.len) |i| {
            if (self.import_mgr.progressFor(i) != null) n += 1;
        }
        return n;
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

    /// 释放插件管理数据（配置/缓存；main 退出时调；热重载场景可重复调）
    pub fn deinitPluginDb(self: *App) void {
        if (self.plugin_cfg) |*c| c.deinit();
        self.plugin_cfg = null;
        if (self.plugin_cache) |*c| c.deinit();
        self.plugin_cache = null;
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
            .replace_effect => |r| self.effectSlotCategory(r),
            .create_instrument, .create_kit_layer => preset_mod.plugin_subtractive,
            .create_effect => preset_mod.plugin_fx_eq,
            .change_instrument => |i| blk: {
                if (i < 0 or i >= @as(i32, @intCast(self.instruments.items.len))) break :blk preset_mod.plugin_subtractive;
                const inst = &self.instruments.items[@intCast(i)];
                break :blk switch (inst.kind) {
                    .drumkit => preset_mod.plugin_drumkit,
                    .vst3 => self.vst3InstrumentCategory(inst),
                    .synth => preset_mod.plugin_subtractive,
                };
            },
        };
        // 定位锚插件的分类；锚不可见（未安装/角色不符）→ 落第一个**可见**分类
        const cats = self.preset_lib.categories.items;
        var chosen: usize = 0;
        var found = false;
        for (cats, 0..) |cat, i| {
            if (!std.mem.eql(u8, cat.name, pb.plugin)) continue;
            if (self.presetCategoryRelevant(intent, cat.name)) {
                chosen = i;
                found = true;
            }
            break;
        }
        if (!found) {
            for (cats, 0..) |cat, i| {
                if (self.presetCategoryRelevant(intent, cat.name)) {
                    chosen = i;
                    break;
                }
            }
        }
        pb.cat = chosen;
        pb.scroll = 0;
        pb.ctx = null; // 右键菜单不跨次残留
    }

    /// 该插件是否可作为**乐器本体**（新建/更换/预设面板选中 → 建或换）：
    /// 减法合成器 / 鼓组（已实装）；FM/VST3 将来。
    pub fn pluginSupportedAsInstrument(plugin: []const u8) bool {
        return std.mem.eql(u8, plugin, preset_mod.plugin_subtractive) or
            std.mem.eql(u8, plugin, preset_mod.plugin_drumkit);
    }

    /// 该插件是否可作为**鼓垫层**：减法合成器 + VST3 乐器分类
    /// （**不含鼓组**——禁自嵌套；层 = 乐器槽，`docs/drumkit.md` §7）。
    pub fn pluginSupportedAsLayer(self: *const App, plugin: []const u8) bool {
        if (std.mem.eql(u8, plugin, preset_mod.plugin_subtractive)) return true;
        if (std.mem.eql(u8, plugin, preset_mod.plugin_drumkit)) return false;
        return self.presetCategoryInstalledRole(plugin, true); // VST3 乐器分类
    }

    /// VST3 分类可用性（**角色过滤**）：缓存条目或活实例需匹配角色
    /// （乐器意图看 instrument；效果意图看 effect）
    pub fn presetCategoryInstalledRole(self: *const App, id: []const u8, want_instrument: bool) bool {
        const cid = preset_mod.vst3CidFromCategory(id) orelse return false;
        if (self.plugin_cache) |*c| {
            if (c.findByCid(cid)) |e| {
                if (want_instrument and e.roleHasInstrument()) return true;
                if (!want_instrument and e.roleHasEffect()) return true;
            }
        }
        if (want_instrument) {
            for (self.instruments.items) |*inst| {
                if (inst.plugin) |pl| {
                    var hb: [32]u8 = undefined;
                    if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return true;
                }
            }
        } else {
            for (self.mixer_channels_state.items) |*mc| {
                for (mc.effects.items) |*es| {
                    if (es.plugin) |pl| {
                        var hb: [32]u8 = undefined;
                        if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return true;
                    }
                }
            }
        }
        return false;
    }

    /// 分类在浏览器是否**可见**（用户拍板：乐器面板不见效果器，反之亦然；
    /// **未安装的 VST3 直接隐藏**——插件不在，加载也无从谈起，回归自动重现）：
    /// - `fx_*` → 仅效果意图；
    /// - `vst3_*` → 需已安装且角色匹配（乐器意图需能作乐器；效果意图需能作效果器）；
    /// - 内置乐器（subtractive/drumkit/fm/sampler）→ 仅乐器意图；
    /// - 层上下文（鼓垫/鼓组层）：减法 + **VST3 乐器**（禁鼓组——自嵌套）。
    pub fn presetCategoryRelevant(self: *const App, intent: PresetIntent, id: []const u8) bool {
        const is_effect_intent = switch (intent) {
            .create_effect, .replace_effect => true,
            else => false,
        };
        const is_layer_ctx = switch (intent) {
            .create_kit_layer => true,
            .replace => |t| switch (t) {
                .kit_layer_replace => true,
                .instrument => false,
            },
            else => false,
        };
        if (fxKindFromCategory(id) != null) return is_effect_intent;
        if (preset_mod.vst3CidFromCategory(id) != null) {
            // 层上下文 = 乐器角色（VST3 乐器可入层；效果器分类由 role 拦下）
            return self.presetCategoryInstalledRole(id, !is_effect_intent);
        }
        if (is_effect_intent) return false;
        if (is_layer_ctx) return std.mem.eql(u8, id, preset_mod.plugin_subtractive);
        return true; // 乐器意图：全部内置（含未实装占位，保持既有置灰提示）
    }

    /// 分类 id → **保存目录名**：
    /// 1) 按身份（CID）复用已有目录（目录名“冻结”——插件改名由扫描时迁移追上）；
    /// 2) 无 → **纯插件名**（清洗；空 → "VST3"）；
    /// 3) 纯名被别的分类占用 → `(CID哈希8位)` 后缀兑底；内置 → id 本身。
    pub fn presetDirForCategory(self: *const App, id: []const u8, display_name: []const u8, buf: []u8) []const u8 {
        const cid = preset_mod.vst3CidFromCategory(id) orelse return id; // 内置：目录名 == id
        if (self.preset_lib.findCategory(id)) |ci| {
            const c = &self.preset_lib.categories.items[ci];
            if (c.dir.len > 0) return c.dir;
        }
        const plain = preset_mod.categoryDirName(display_name, cid, false, buf);
        if (plain.len == 0) return id;
        var taken = false;
        for (self.preset_lib.categories.items) |*other| {
            if (other.dir.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(other.dir, plain)) {
                taken = true;
                break;
            }
        }
        if (!taken) return plain;
        const hashed = preset_mod.categoryDirName(display_name, cid, true, buf); // 同一 buf 覆写（plain 失效）
        return if (hashed.len > 0) hashed else id;
    }

    /// 插件名查询（CID）：扫描缓存 → 活乐器实例 → 活效果实例；都没有 → null。
    /// （改名迁移/目录命名策略用；与 `presetCategoryLabel` 的区别：不返回占位文案）
    pub fn vst3PluginName(self: *const App, cid: []const u8) ?[]const u8 {
        if (self.plugin_cache) |*c| {
            if (c.findByCid(cid)) |e| {
                if (e.name.len > 0) return e.name;
            }
        }
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                var hb: [32]u8 = undefined;
                if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return pl.name();
            }
        }
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.plugin) |pl| {
                    var hb: [32]u8 = undefined;
                    if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return pl.name();
                }
            }
        }
        return null;
    }

    /// 效果槽的预设分类 id（锚点）：内置 → `fx_*`；插件 → vst3 分类（**主 CID**）
    pub fn effectSlotCategory(self: *App, r: EffectRef) []const u8 {
        if (r.ch >= self.mixer_channels_state.items.len) return "";
        const chain = &self.mixer_channels_state.items[r.ch].effects;
        if (r.slot >= chain.items.len) return "";
        const es = &chain.items[r.slot];
        if (es.kind == .plugin) {
            const pl = es.plugin orelse return "";
            var hb: [32]u8 = undefined;
            var canon: [32]u8 = undefined;
            const cc = self.canonicalCategoryCid(pl.cidHex(&hb), &canon);
            return preset_mod.vst3CategoryId(cc, &self.preset_anchor_buf);
        }
        return es.kind.presetCategoryId() orelse "";
    }

    /// 实例 CID → **分类主 CID**（缓存条目“乐器类优先、否则首个效果类”；未扫描 → 原样）。
    /// 分类身份、存档 `cid` 字段、锚点全部走它——“双角色”插件（既含乐器类又含效果类）
    /// 在乐器/效果两条路上不会错位。`out` 由调用方提供。
    pub fn canonicalCategoryCid(self: *const App, live_hex: []const u8, out: *[32]u8) []const u8 {
        if (live_hex.len != 32) return "";
        @memcpy(out, live_hex[0..32]);
        if (self.plugin_cache) |*c| {
            if (c.findByCid(live_hex)) |e| {
                var primary: ?[]const u8 = null;
                for (e.classes) |cl| {
                    if (std.mem.eql(u8, cl.kind, "instrument") and cl.cid.len == 32) {
                        primary = cl.cid;
                        break;
                    }
                }
                if (primary == null) {
                    for (e.classes) |cl| {
                        if (std.mem.eql(u8, cl.kind, "effect") and cl.cid.len == 32) {
                            primary = cl.cid;
                            break;
                        }
                    }
                }
                if (primary) |pc| @memcpy(out, pc[0..32]);
            }
        }
        return out[0..32];
    }

    /// 实例是否属于该分类身份（主 CID）：CID 直接相等，或同一缓存条目
    /// （“双角色”插件：乐器实例的 CID ≠ 效果分类的CID，但同一条目）。
    pub fn pluginInstanceMatchesCategory(self: *const App, pl: *const vst_host.Plugin, cat_cid: []const u8) bool {
        var hb: [32]u8 = undefined;
        const live = pl.cidHex(&hb);
        if (std.ascii.eqlIgnoreCase(live, cat_cid)) return true;
        if (self.plugin_cache) |*c| {
            const e1 = c.findByCid(live) orelse return false;
            const e2 = c.findByCid(cat_cid) orelse return false;
            return e1 == e2;
        }
        return false;
    }

    /// 该意图下此分类是否**可选**（否则左栏置灰、点击只提示）：
    /// **面板已统一**——任何入口都能选任意已实装插件（跨插件即换插件）；
    /// 仅两类被拦：未实装插件（FM/未扫描 VST3）与层上下文的鼓组（禁自嵌套）。
    pub fn presetCategorySelectable(self: *const App, intent: PresetIntent, plugin: []const u8) bool {
        // 内建效果分类（fx_*）：仅效果意图可选
        if (fxKindFromCategory(plugin) != null) {
            return switch (intent) {
                .create_effect, .replace_effect => true,
                else => false,
            };
        }
        // VST3 分类：可选性看“插件可用”（缓存/活实例有 CID + 角色匹配）；特例：
        // 替换目标就是该插件（即使暂未安装）→ 可选——预设存 pending，
        // 插件回归后自动应用（B1 机制），不堵用户。
        if (preset_mod.vst3CidFromCategory(plugin)) |cid| {
            return switch (intent) {
                .replace => |t| switch (t) {
                    .instrument => |ii| blk: {
                        if (ii >= 0 and ii < @as(i32, @intCast(self.instruments.items.len))) {
                            const inst = &self.instruments.items[@intCast(ii)];
                            if (inst.plugin) |pl| {
                                if (self.pluginInstanceMatchesCategory(pl, cid)) break :blk true;
                            }
                        }
                        break :blk self.presetCategoryInstalledRole(plugin, true);
                    },
                    .kit_layer_replace => |ref| blk: {
                        // 层 = 乐器槽：VST3 乐器可选；替换目标就是该插件（即使暂未安装）
                        // → 可选（预设存 pending，插件回归后自动应用）
                        if (ref.instrument >= 0 and ref.instrument < @as(i32, @intCast(self.instruments.items.len))) {
                            const inst = &self.instruments.items[@intCast(ref.instrument)];
                            if (inst.kit) |kit| {
                                if (kit.find(ref.pitch)) |pad| {
                                    if (ref.layer < pad.layers.items.len) {
                                        const ly = &pad.layers.items[ref.layer];
                                        if (ly.kind == .vst3) {
                                            if (ly.plugin) |pl| {
                                                if (self.pluginInstanceMatchesCategory(pl, cid)) break :blk true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        break :blk self.presetCategoryInstalledRole(plugin, true);
                    },
                },
                .replace_effect => |r| blk: {
                    if (r.ch < self.mixer_channels_state.items.len and
                        r.slot < self.mixer_channels_state.items[r.ch].effects.items.len)
                    {
                        const es = &self.mixer_channels_state.items[r.ch].effects.items[r.slot];
                        if (es.plugin) |pl| {
                            if (self.pluginInstanceMatchesCategory(pl, cid)) break :blk true;
                        }
                    }
                    break :blk self.presetCategoryInstalledRole(plugin, false);
                },
                .create_kit_layer => self.presetCategoryInstalledRole(plugin, true), // VST3 乐器分类（层 = 乐器槽）
                .create_instrument, .change_instrument => self.presetCategoryInstalledRole(plugin, true),
                .create_effect => self.presetCategoryInstalledRole(plugin, false),
            };
        }
        return switch (intent) {
            .replace => |t| switch (t) {
                .instrument => pluginSupportedAsInstrument(plugin),
                .kit_layer_replace => self.pluginSupportedAsLayer(plugin),
            },
            .create_instrument, .change_instrument => pluginSupportedAsInstrument(plugin),
            .create_kit_layer => self.pluginSupportedAsLayer(plugin),
            .create_effect, .replace_effect => false, // 效果意图：仅 fx_* / VST3 效果分类
        };
    }

    /// 预设目标所需的插件类型（分类 id）——浏览器的限定依据。
    /// 目前乐器本体（synth）/鼓组层都是减法合成器；鼓组乐器本体留给
    /// 将来的“整组套预设”（`drumkit` 分类，阶段 4）。
    pub fn presetTargetPlugin(self: *App, target: PresetTarget) []const u8 {
        switch (target) {
            .instrument => |i| {
                if (i >= 0 and i < @as(i32, @intCast(self.instruments.items.len))) {
                    const inst = &self.instruments.items[@intCast(i)];
                    if (inst.kind == .drumkit) return preset_mod.plugin_drumkit;
                    if (inst.kind == .vst3) return self.vst3InstrumentCategory(inst);
                }
                return preset_mod.plugin_subtractive;
            },
            .kit_layer_replace => |ref| {
                // 层 = 乐器槽：VST3 层的锚 = 该层插件分类（浏览器打开时定位）
                if (self.kitLayerPtr(ref.instrument, ref.pitch, ref.layer)) |ly| {
                    if (ly.kind == .vst3) {
                        if (ly.plugin) |pl| {
                            var hb: [32]u8 = undefined;
                            var canon: [32]u8 = undefined;
                            const cc = self.canonicalCategoryCid(pl.cidHex(&hb), &canon);
                            return preset_mod.vst3CategoryId(cc, &self.preset_anchor_buf);
                        }
                    }
                }
                return preset_mod.plugin_subtractive;
            },
        }
    }

    /// 乐器的 VST3 分类 id（主 CID → `preset_anchor_buf`；无实例 → ""）
    pub fn vst3InstrumentCategory(self: *App, inst: *const model.Instrument) []const u8 {
        const pl = inst.plugin orelse return "";
        var hb: [32]u8 = undefined;
        var canon: [32]u8 = undefined;
        const cc = self.canonicalCategoryCid(pl.cidHex(&hb), &canon);
        return preset_mod.vst3CategoryId(cc, &self.preset_anchor_buf);
    }

    /// VST3 分类的插件是否已安装（扫描缓存有 CID，或任一活实例 CID 匹配）
    pub fn presetCategoryInstalled(self: *const App, id: []const u8) bool {
        const cid = preset_mod.vst3CidFromCategory(id) orelse return false;
        if (self.plugin_cache) |*c| {
            if (c.findByCid(cid) != null) return true;
        }
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                var hb: [32]u8 = undefined;
                if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return true;
            }
        }
        return false;
    }

    /// 分类显示名：内置走静态表；VST3 分类查缓存/活实例取插件名；
    /// 都没 → 提示串（插件未安装/未扫描）
    pub fn presetCategoryLabel(self: *const App, id: []const u8) []const u8 {
        const cid = preset_mod.vst3CidFromCategory(id) orelse return preset_mod.pluginDisplayName(id);
        if (self.plugin_cache) |*c| {
            if (c.findByCid(cid)) |e| {
                if (e.name.len > 0) return e.name;
            }
        }
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                var hb: [32]u8 = undefined;
                if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return pl.name();
            }
        }
        // 预设文件里存的展示名（插件已卸载/未扫描也能读；见 `Category.label`）
        if (self.preset_lib.findCategory(id)) |ci| {
            if (self.preset_lib.categories.items[ci].label) |lb| return lb;
        }
        return "VST3 插件（未安装/未扫描）";
    }

    /// VST3 分类 → 可加载的插件路径（缓存 dll 优先；活实例在用路径兜底）
    pub fn vst3CategoryPath(self: *const App, id: []const u8) ?[]const u8 {
        const cid = preset_mod.vst3CidFromCategory(id) orelse return null;
        if (self.plugin_cache) |*c| {
            if (c.findByCid(cid)) |e| {
                if (e.dll.len > 0) return e.dll;
                if (e.path.len > 0) return e.path;
            }
        }
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                var hb: [32]u8 = undefined;
                if (std.ascii.eqlIgnoreCase(pl.cidHex(&hb), cid)) return inst.pluginPath();
            }
        }
        return null;
    }

    /// 扫描完成后：把 `load_failed` 的槽按记录的类 CID 重定位到缓存里的新路径
    /// （**只碰失败槽**；同路径不动——交给 B1 重试）。返回重定位数量；
    /// 调用方随后提示（已处理时内部提交历史“重新定位插件”）。
    ///
    /// `io` 用于**存在性门槛**：只当“当前路径真消失”且“候选文件真在磁盘上”才换。
    /// （防两个坏文件来回跳；也防把路径换成另一个同样死的旧缓存项。）
    pub fn reboundFailedPluginSlots(self: *App, io: std.Io) usize {
        if (self.plugin_cache == null) return 0;
        var n: usize = 0;
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.kind != .plugin or es.plugin != null or !es.load_failed) continue;
                if (es.pluginCid().len != 32) continue;
                if (!self.pluginPathGone(io, es.pluginPath())) continue;
                const e = self.findLiveEntryFor(io, es.pluginCid(), false) orelse continue;
                var keep: [32]u8 = undefined;
                @memcpy(&keep, es.pluginCid());
                es.setPluginPath(e.dll); // 重置失败态
                es.setPluginCid(&keep); // 身份保留：新路径再失败仍可继续匹配
                n += 1;
            }
        }
        for (self.instruments.items) |*inst| {
            if (inst.kind != .vst3 or inst.plugin != null or !inst.load_failed) continue;
            if (inst.pluginCid().len != 32) continue;
            if (!self.pluginPathGone(io, inst.pluginPath())) continue;
            const e = self.findLiveEntryFor(io, inst.pluginCid(), true) orelse continue;
            var keep: [32]u8 = undefined;
            @memcpy(&keep, inst.pluginCid());
            inst.setPluginPath(e.dll);
            inst.setPluginCid(&keep);
            n += 1;
        }
        if (n > 0) self.commitHistory("重新定位插件");
        return n;
    }

    /// 路径是否已从磁盘消失（空路径视为消失）
    fn pluginPathGone(self: *const App, io: std.Io, path: []const u8) bool {
        _ = self;
        if (path.len == 0) return true;
        std.Io.Dir.cwd().access(io, path, .{}) catch return true;
        return false;
    }

    /// 缓存里找“CID 匹配 + 角色匹配 + **文件真在磁盘上**”的条目
    fn findLiveEntryFor(self: *const App, io: std.Io, cid: []const u8, want_instrument: bool) ?*const plugin_db.Entry {
        const cache = if (self.plugin_cache) |*c| c else return null;
        for (cache.entries, 0..) |e, i| {
            if (!e.ok or e.dll.len == 0) continue;
            if (want_instrument) {
                if (!e.roleHasInstrument()) continue;
            } else {
                if (!e.roleHasEffect()) continue;
            }
            var match = false;
            for (e.classes) |cl| {
                if (std.ascii.eqlIgnoreCase(cl.cid, cid)) {
                    match = true;
                    break;
                }
            }
            if (!match) continue;
            std.Io.Dir.cwd().access(io, e.dll, .{}) catch continue;
            return &cache.entries[i];
        }
        return null;
    }

    /// 手动重新定位**乐器**插件：换路径但**保留 pending 音色**（插件回来时应用）。
    /// 一条历史；实际加载由 syncInstrumentPlugins 帧末完成。
    pub fn relocateInstrument(self: *App, ii: i32, path: []const u8) void {
        if (ii < 0 or ii >= @as(i32, @intCast(self.instruments.items.len))) return;
        if (path.len == 0) return;
        const inst = &self.instruments.items[@intCast(ii)];
        if (inst.plugin) |pl| {
            inst.plugin = null;
            self.retirePlugin(pl);
        }
        inst.setPluginPath(path); // 清失败态/身份（加载成功后回填）
        inst.kind = .vst3;
        self.commitHistory("重新定位插件");
        self.setToastWith("已重新定位乐器插件：{s}", .{std.fs.path.basename(path)});
    }

    /// 手动重新定位**效果器**插件（同上；pending 保留）
    pub fn relocateEffect(self: *App, ch: usize, slot: usize, path: []const u8) void {
        if (ch >= self.mixer_channels_state.items.len) return;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (slot >= chain.items.len or path.len == 0) return;
        const es = &chain.items[slot];
        if (es.plugin) |pl| {
            es.plugin = null;
            self.retirePlugin(pl);
        }
        es.setPluginPath(path);
        self.commitHistory("重新定位插件");
        self.setToastWith("已重新定位效果器插件：{s}", .{std.fs.path.basename(path)});
    }

    /// 把指定乐器切到 VST3 插件（**保留**名字/音量/声像/路由；旧实例退役、
    /// 鼓组本体释放、pending 清空——新状态由调用方随后写入）。
    pub fn applyVst3Instrument(self: *App, ii: i32, path: []const u8) void {
        if (ii < 0 or ii >= @as(i32, @intCast(self.instruments.items.len))) return;
        const inst = &self.instruments.items[@intCast(ii)];
        if (inst.plugin) |pl| {
            inst.plugin = null;
            self.retirePlugin(pl);
        }
        if (inst.kit) |kit| {
            self.deinitDrumKit(kit);
            inst.kit = null;
        }
        inst.setPluginPath(path); // 路径变化时内部重置 load_failed/fail_wait
        inst.clearPendingState(self.allocator);
        inst.kind = .vst3;
    }

    /// base64 状态解码（VST3 预设加载用；空/坏 → null，调用方释放）
    pub fn decodeStateB64(self: *App, text: []const u8) ?[]u8 {
        return b64Decode(self.allocator, text);
    }

    /// 捕获效果槽插件状态 → base64（main 保存 VST3 效果预设用）；失败 → null
    pub fn captureEffectStateB64(self: *App, es: *const EffectSlot, comp: bool) ?[]const u8 {
        return captureSlotStateB64(self.allocator, es, comp) catch null;
    }

    /// 捕获乐器的 VST3 状态（base64，组件+控制器）；插件未加载 → null。
    /// 返回切片非空时调用方释放。
    /// 插件状态捕获（base64 对；乐器/鼓组层共用类型——避免匿名结构类型不兼容）
    pub const CapturedStateB64 = struct { comp: []const u8, ctrl: []const u8 };

    pub fn captureVst3StateB64(self: *App, ii: i32) ?CapturedStateB64 {
        if (ii < 0 or ii >= @as(i32, @intCast(self.instruments.items.len))) return null;
        const pl = self.instruments.items[@intCast(ii)].plugin orelse return null;
        const comp = capturePluginStateB64(self.allocator, pl, true) catch return null;
        const ctrl = capturePluginStateB64(self.allocator, pl, false) catch {
            if (comp.len > 0) self.allocator.free(comp);
            return null;
        };
        return .{ .comp = comp, .ctrl = ctrl };
    }

    /// 捕获鼓组 VST3 层的插件状态（base64；插件未加载 → null）——保存预设用
    pub fn captureLayerVst3StateB64(self: *App, ref: PresetTarget.KitLayerRef) ?CapturedStateB64 {
        const ly = self.kitLayerPtr(ref.instrument, ref.pitch, ref.layer) orelse return null;
        const pl = ly.plugin orelse return null;
        const comp = capturePluginStateB64(self.allocator, pl, true) catch return null;
        const ctrl = capturePluginStateB64(self.allocator, pl, false) catch {
            if (comp.len > 0) self.allocator.free(comp);
            return null;
        };
        return .{ .comp = comp, .ctrl = ctrl };
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
            .vst3 => return false, // 换入 VST3 走预设面板的插件分类（或插件管理加单文件）
        }
        // 离开 VST3：旧实例退役、路径清空（沿用新类型）；待恢复状态作废
        if (inst.kind != .vst3 and (inst.plugin != null or inst.pluginPath().len > 0)) {
            if (inst.plugin) |pl| {
                inst.plugin = null;
                self.retirePlugin(pl);
            }
            inst.plugin_path_len = 0;
            inst.clearPendingState(self.allocator);
            inst.load_failed = false;
            inst.fail_wait = 0;
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
    /// 打开预设搜索框（复用文本输入基建：IME/框选/光标都现成）。
    /// 框内文字每帧实时同步到 `preset_browser.filter_*`（右栏即时过滤）。
    pub fn beginPresetSearch(self: *App, x: i32, y: i32, w: i32) void {
        const ti = &self.text_input;
        const pb = &self.preset_browser;
        ti.active = true;
        ti.target = .preset_search;
        ti.index = 0;
        ti.len = pb.filter_len;
        @memcpy(ti.buf[0..pb.filter_len], pb.filter_buf[0..pb.filter_len]);
        ti.cursor = ti.len;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.x = x;
        ti.y = y;
        ti.w = w;
        ti.view_off = 0;
        ti.aux_len = 0;
    }

    /// 当前预设搜索过滤串（空 = 不过滤）
    pub fn presetSearchQuery(self: *const App) []const u8 {
        return self.preset_browser.filter_buf[0..self.preset_browser.filter_len];
    }

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
            .effect => "", // 效果槽无关联预设名（不预填）
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

    /// 滚轮类 / 插件侧改动的“起手提交 + 静置钉值”入口（每次变动调用）。
    /// 首次调用立即提交一条临时历史（顺序正确：后续任何即时操作必排其后）；
    /// 静置（`pollGestureHistory`）/新操作起手/编辑器关闭 → `pinPendingGesture` 钉最终值。
    pub fn touchGesture(self: *App, label: []const u8) void {
        const now = self.params.frames_played.load(.monotonic);
        if (self.gesture) |*g| {
            g.last_change_frame = now; // 续接同一手势
            // **续接的改动也要送达调度**（音符类：力度/声像/键盘移音符——
            // 否则只到 4 小节水位线扫过才生效。实测 bug：Ctrl+A 全选后
            // Alt+滚轮改力度“不及时生效”：续接分支只续手势、不重扫，
            // 而钉值（静置 1s）也不重扫——只有第一滚生效）。
            // 非音符改动（EQ 旋钮等）不重扫（判据同 `commitHistory`）。
            if (!self.notesClipsUnchanged()) self.rescanForPlaybackEdit();
            return;
        }
        const before = self.history.items.len;
        self.commitHistory(label);
        // 去重跳过（内容未变）→ 不建立手势；后续变化会再试
        if (self.history.items.len == before) return;
        self.gesture = .{ .label = label, .last_change_frame = now, .index = self.history_current };
    }

    /// 钉住进行中的手势：把当前状态重新捕获进其临时条目。
    /// 触发点：静置计时、新操作起手（鼠标按下/其它提交）、编辑器关闭、保存、导航前。
    pub fn pinPendingGesture(self: *App) void {
        const g = self.gesture orelse return;
        // 仅当临时条目仍是当前顶条（期间无其它提交/导航）才替换；否则丢弃（内容已错位）
        if (g.index != self.history_current or g.index + 1 != self.history.items.len) {
            self.clearGesture();
            return;
        }
        // 先备好增量拷贝（alloc(0) 也是可 free 的真分配；失败 → 放弃本次钉值）
        std.mem.sort(ParamEditRec, g.param_edits.items, {}, paramEditLess);
        const recs = self.allocator.alloc(ParamEditRec, g.param_edits.items.len) catch {
            self.clearGesture();
            return;
        };
        @memcpy(recs, g.param_edits.items);
        const srefs = self.allocator.alloc(PluginSlotRef, g.structural_refs.items.len) catch {
            self.allocator.free(recs);
            self.clearGesture();
            return;
        };
        @memcpy(srefs, g.structural_refs.items);
        var st = self.captureHistory(g.label) catch {
            self.allocator.free(recs);
            self.allocator.free(srefs);
            self.clearGesture();
            return;
        };
        st.param_edits = recs;
        st.structural_refs = srefs;
        self.clearGesture();
        const old = &self.history.items[g.index];
        self.freeHistoryState(old);
        old.* = st;
    }

    /// 参数增量排序：按槽（kind,a,b）+ 参数 ID——同槽记录连续，应用侧取子切片
    fn paramEditLess(_: void, a: ParamEditRec, b: ParamEditRec) bool {
        if (a.ref.kind != b.ref.kind) return @backingInt(a.ref.kind) < @backingInt(b.ref.kind);
        if (a.ref.a != b.ref.a) return a.ref.a < b.ref.a;
        if (a.ref.b != b.ref.b) return a.ref.b < b.ref.b;
        return a.param_id < b.param_id;
    }

    /// 乐器指针 → 下标（导出时查脏标用；非本容器指针 → null）
    fn instrumentIndexOf(self: *const App, inst: *const model.Instrument) ?usize {
        if (self.instruments.items.len == 0) return null;
        const base = @intFromPtr(self.instruments.items.ptr);
        const p = @intFromPtr(inst);
        if (p < base) return null;
        const off = p - base;
        if (off % @sizeOf(model.Instrument) != 0) return null;
        const i = off / @sizeOf(model.Instrument);
        if (i >= self.instruments.items.len) return null;
        return i;
    }

    const ReusePair = struct { comp: []const u8, ctrl: []const u8 };

    /// 捕获复用（乐器）：槽未脏且来向条目同槽同路径 → 沿用其状态文本。
    /// 返回 null = 必须重新 getState。**只用于历史快照**（工程保存永远现取）。
    fn reuseInstrumentState(self: *const App, inst: *const model.Instrument, pooled: bool) ?ReusePair {
        if (!pooled) return null;
        if (self.history.items.len == 0) return null;
        const ii = self.instrumentIndexOf(inst) orelse return null;
        if (ii >= self.instr_state_dirty.len or self.instr_state_dirty[ii]) return null;
        const prev = &self.history.items[self.history_current];
        if (ii >= prev.instruments.len) return null;
        const psi = &prev.instruments[ii];
        if (!std.mem.eql(u8, inst.pluginPath(), psi.plugin_path)) return null;
        return .{ .comp = psi.plugin_state, .ctrl = psi.plugin_state_ctrl };
    }

    /// 捕获复用（**鼓组层**）：层未脏且来向条目同位置（音高+层序）同路径 →
    /// 沿用其状态文本（池共享；O(1)）——同 `reuseInstrumentState`。
    /// `slot` = 展平槽位（脏标寻址）；`inst_idx` = 乐器下标。
    fn reuseLayerState(self: *const App, ly: *const model.DrumLayer, inst_idx: usize, pitch: u8, li: usize, slot: usize, pooled: bool) ?ReusePair {
        if (!pooled) return null;
        if (self.history.items.len == 0) return null;
        if (inst_idx >= self.kit_layer_state_dirty.len or slot >= self.kit_layer_state_dirty[inst_idx].len) return null;
        if (self.kit_layer_state_dirty[inst_idx][slot]) return null;
        const prev = &self.history.items[self.history_current];
        if (inst_idx >= prev.instruments.len) return null;
        const psi = &prev.instruments[inst_idx];
        for (psi.kit.pads) |pp| {
            if (pp.pitch != @as(u32, pitch)) continue;
            if (li >= pp.layers.len) return null;
            const pl0 = pp.layers[li];
            if (!std.mem.eql(u8, ly.pluginPath(), pl0.plugin_path)) return null;
            return .{ .comp = pl0.plugin_state, .ctrl = pl0.plugin_state_ctrl };
        }
        return null;
    }

    /// 捕获复用（效果器槽）：同 `reuseInstrumentState`
    fn reuseFxState(self: *const App, ch: usize, slot: usize, es: *const EffectSlot, pooled: bool) ?ReusePair {
        if (!pooled) return null;
        if (self.history.items.len == 0) return null;
        if (ch >= self.params.channels_cap or slot >= self.params.slots_cap) return null;
        if (self.fx_state_dirty[ch][slot]) return null;
        const prev = &self.history.items[self.history_current];
        if (ch >= prev.mixer.len) return null;
        const psm = prev.mixer[ch];
        if (slot >= psm.effects.len) return null;
        const pse = psm.effects[slot];
        if (!std.mem.eql(u8, es.pluginPath(), pse.plugin_path)) return null;
        return .{ .comp = pse.plugin_state, .ctrl = pse.plugin_state_ctrl };
    }

    /// 取条目中某槽的增量段（条目内按 ref 有序 → 同槽连续）
    fn slotRecs(edits: []const ParamEditRec, ref: PluginSlotRef) []const ParamEditRec {
        var start: ?usize = null;
        var end: usize = 0;
        for (edits, 0..) |rec, i| {
            if (sameSlotRef(rec.ref, ref)) {
                if (start == null) start = i;
                end = i + 1;
            }
        }
        if (start) |s| return edits[s..end];
        return &.{};
    }

    /// 参数回放资格判定：单步导航 + 该槽本步无结构信号 + 有增量 + 实例就绪 +
    /// 参数缓存匹配“来向侧”值（缓存是唯一可信的现状依据）。null = 整块恢复。
    fn replayPlanFor(self: *const App, ref: PluginSlotRef, prev_idx: usize, target_idx: usize) ?ReplayJob {
        if (prev_idx == target_idx) return null;
        const backward = prev_idx > target_idx;
        const hi = @max(prev_idx, target_idx);
        const lo = @min(prev_idx, target_idx);
        if (hi - lo != 1) return null; // 多步跳转：不做增量拆解（罕见操作）
        if (hi >= self.history.items.len) return null;
        const step = &self.history.items[hi];
        for (step.structural_refs) |sref| {
            if (sameSlotRef(sref, ref)) return null;
        }
        const recs = slotRecs(step.param_edits, ref);
        if (recs.len == 0) return null;
        const pl = self.slotPlugin(ref) orelse return null;
        for (recs) |rec| {
            const pidx = pl.findParamIndex(rec.param_id) orelse return null;
            const cached = pl.cacheGet(pidx) orelse return null;
            const expect = if (backward) rec.new else rec.old;
            if (cached != expect) return null;
        }
        return .{ .recs = recs, .backward = backward };
    }

    /// 乐器槽的应用计划（撤销/重做逐槽）
    fn planInstrumentApply(self: *App, i: usize, prev_idx: usize, target_idx: usize, si: *const persist.SavedInstrument, target: *const model.Instrument) ApplyPlan {
        if (prev_idx != target_idx and prev_idx < self.history.items.len) {
            const prev = &self.history.items[prev_idx];
            if (i < prev.instruments.len) {
                const psi = &prev.instruments[i];
                if (std.mem.eql(u8, si.plugin_path, psi.plugin_path) and
                    stateBlobsEqual(si.plugin_state, si.plugin_state_ctrl, psi.plugin_state, psi.plugin_state_ctrl))
                {
                    return .skip;
                }
            }
        }
        const ref = PluginSlotRef{ .kind = .instrument, .a = @intCast(@min(i, std.math.maxInt(u16))) };
        if (target.plugin != null) {
            if (self.replayPlanFor(ref, prev_idx, target_idx)) |job| return .{ .replay = job };
        }
        return .full;
    }

    /// 参数增量回放（setParam 免锁路径）。false = 无法完成（调用方整块恢复兜底）
    fn runReplay(pl: *vst_host.Plugin, job: ReplayJob) bool {
        for (job.recs) |rec| {
            const v = if (job.backward) rec.old else rec.new;
            if (!pl.setParamById(rec.param_id, v)) return false;
        }
        return true;
    }

    /// 旧链同槽活插件（且路径一致）——效果器参数回放前提（救援可保留实例）
    fn fxSlotLivePlugin(self: *const App, ch: usize, slot: usize, path: []const u8) ?*vst_host.Plugin {
        if (ch >= self.mixer_channels_state.items.len) return null;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (slot >= chain.items.len) return null;
        const pl = chain.items[slot].plugin orelse return null;
        if (!std.mem.eql(u8, chain.items[slot].pluginPath(), path)) return null;
        return pl;
    }

    /// 帧末调用：手势静置 ≥ 1s → 钉值。
    /// （时间源 = 音频帧计数：单调、与 UI 帧率无关）
    pub fn pollGestureHistory(self: *App) void {
        const g = self.gesture orelse return;
        const now = self.params.frames_played.load(.monotonic);
        const quiet_frames: u64 = self.params.sample_rate; // 1s
        if (now -| g.last_change_frame >= quiet_frames) self.pinPendingGesture();
    }

    // ── 调音台通道 ──

    /// 当前通道数
    pub fn mixerChannelCount(self: *const App) usize {
        return self.mixer_channels_state.items.len;
    }

    /// 初始化调音台通道（启动/新建/加载无 mixer 字段时）：默认 `default_mixer_channels` 个。
    /// 先释放旧链（每通道效果器列表）再重建。
    pub fn resetMixerChannels(self: *App, count: usize) void {
        self.initAudioCapacity() catch {};
        self.ensureAudioCapacity(0, count, 0);
        self.deinitMixerChannels();
        var i: usize = 0;
        const n = @min(count, self.params.channels_cap);
        while (i < n) : (i += 1) {
            self.mixer_channels_state.append(self.allocator, .{}) catch break;
        }
        self.shrink_pending = true; // 帧末尝试回收容量
    }

    /// 释放调音台通道（每通道的效果器链 + **列表底层数组**）
    pub fn deinitMixerChannels(self: *App) void {
        // 链上插件实例：退役（延迟销毁——音频线程可能仍在读旧指针；
        // 覆盖“新建空工程/导入重建”等路径，帧末 syncPluginSlots 回收）
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.plugin) |pl| {
                    es.plugin = null;
                    self.retirePlugin(pl);
                }
                if (es.fx_state) |box| {
                    es.fx_state = null;
                    self.retireFxState(box);
                }
                es.clearPendingState(self.allocator);
            }
        }
        for (self.mixer_channels_state.items) |*mc| mc.effects.deinit(self.allocator);
        // 注：必须 `deinit`（释放底层数组）——`clearRetainingCapacity` 只清长度，
        // 会把数组泄漏掉（实测：undo → importMixerChannels → 重建通道后泄漏）
        self.mixer_channels_state.deinit(self.allocator);
        self.mixer_channels_state = .empty;
    }

    /// 初始化音频容量（启动第一个编辑动作/测试建立；幂等）
    pub fn initAudioCapacity(self: *App) !void {
        if (self.params.instruments_cap > 0) return;
        const a = self.allocator;
        try self.params.initCapacity(a, synth.max_instruments, max_mixer_channels, audio.effect_slots);
        self.engine.allocator = a;
        try self.engine.setCapacity(synth.max_instruments, max_mixer_channels, audio.effect_slots);
        self.instr_state_dirty = try a.alloc(bool, synth.max_instruments);
        @memset(self.instr_state_dirty, false);
        self.kit_layer_state_dirty = try a.alloc([]bool, synth.max_instruments);
        @memset(self.kit_layer_state_dirty, &.{});
        for (self.kit_layer_state_dirty) |*r| {
            r.* = try a.alloc(bool, audio.kit_max_layers);
            @memset(r.*, false);
        }
        self.fx_state_dirty = try a.alloc([]bool, max_mixer_channels);
        @memset(self.fx_state_dirty, &.{});
        for (self.fx_state_dirty) |*r| {
            r.* = try a.alloc(bool, audio.effect_slots);
            @memset(r.*, false);
        }
        sequencer.instrument_cap = synth.max_instruments;
    }

    /// 确保音频容量足够（乐器/通道/效果槽任一不足 → **暂停设备** → Params+Engine 扩容 → 恢复）。
    /// 容量只增不减（需求值、当前值×2、+8 三者取大）；失败保持旧容量（下次重试）。
    pub fn ensureAudioCapacity(self: *App, ic: usize, cc: usize, sc: usize) void {
        self.initAudioCapacity() catch {};
        self.engine.allocator = self.allocator;
        const pc = self.params.instruments_cap;
        const qc = self.params.channels_cap;
        const rc = self.params.slots_cap;
        if (ic <= pc and cc <= qc and sc <= rc) return;
        const nic = if (ic <= pc) pc else @max(ic, @max(pc * 2, pc + 8));
        const ncc = if (cc <= qc) qc else @max(cc, @max(qc * 2, qc + 8));
        const nsc = if (sc <= rc) rc else @max(sc, @max(rc * 2, rc + 8));
        self.engine.pauseDevice();
        defer self.engine.resumeDevice();
        self.params.resize(self.allocator, nic, ncc, nsc) catch return;
        self.engine.setCapacity(nic, ncc, nsc) catch {};
        self.growStateDirty(nic, ncc, nsc);
        sequencer.instrument_cap = nic;
    }

    /// 确保某乐器的鼓组层声部池已分配（惰性；可在音频运行时调用——原子发布指针）。
    /// 只有带 kit 的乐器需要；非鼓组或无乐器 = 无操作。
    pub fn ensureKitPool(self: *App, i: usize) void {
        if (i >= self.engine.kit_chunks.len) return; // 容量未覆盖（sync 前 ensureAudioCapacity 已跑）
        if (self.engine.kit_chunks[i].load(.monotonic) != null) return;
        if (i >= self.instruments.items.len) return;
        if (self.instruments.items[i].kit == null) return;
        const kp = self.allocator.create(audio.KitPool) catch return;
        for (kp) |*s| s.* = .{};
        self.engine.kit_chunks[i].store(kp, .release);
    }

    /// 释放/对齐鼓组池（**契约：设备已暂停**）：
    /// - `kit_reset`（装载/历史重建）：全量释放（乐器已被重建，池不再对应）；
    /// - 否则重放删除位移（逐个 idx 左移一格，按删除发生顺序重放）；
    /// - 最后清理：索引越界或宿主不再是鼓组的池释放。
    fn gcKitPools(self: *App) void {
        if (self.kit_reset) {
            self.kit_reset = false;
            for (self.engine.kit_chunks) |*c| {
                if (c.load(.monotonic)) |kp| self.allocator.destroy(kp);
                c.store(null, .monotonic);
            }
            for (self.engine.kit_vsti) |*c| {
                if (c.load(.monotonic)) |kv| self.allocator.destroy(kv);
                c.store(null, .monotonic);
            }
            for (self.engine.kit_sampler) |*c| {
                if (c.load(.monotonic)) |ks| self.allocator.destroy(ks);
                c.store(null, .monotonic);
            }
            self.kit_shift_log.clearRetainingCapacity();
        } else {
            for (self.kit_shift_log.items) |idx| {
                var i: usize = idx;
                while (i + 1 < self.engine.kit_chunks.len) : (i += 1) {
                    self.engine.kit_chunks[i].store(self.engine.kit_chunks[i + 1].load(.monotonic), .monotonic);
                }
                if (self.engine.kit_chunks.len > 0) {
                    self.engine.kit_chunks[self.engine.kit_chunks.len - 1].store(null, .monotonic);
                }
            }
            self.kit_shift_log.clearRetainingCapacity();
        }
        var i: usize = 0;
        while (i < self.engine.kit_chunks.len) : (i += 1) {
            const kp = self.engine.kit_chunks[i].load(.monotonic) orelse continue;
            const needed = i < self.instruments.items.len and self.instruments.items[i].kit != null;
            if (!needed) {
                self.allocator.destroy(kp);
                self.engine.kit_chunks[i].store(null, .monotonic);
            }
        }
        // 鼓组 VST3 层状态清理（宿主不再是鼓组 / 不再含 VST3 层 → 释放）
        var ik: usize = 0;
        while (ik < self.engine.kit_vsti.len) : (ik += 1) {
            const kv = self.engine.kit_vsti[ik].load(.monotonic) orelse continue;
            var needed = false;
            if (ik < self.instruments.items.len) {
                if (self.instruments.items[ik].kit) |kit| {
                    outer: for (kit.pads.items) |pad| {
                        for (pad.layers.items) |ly| {
                            if (ly.kind == .vst3) {
                                needed = true;
                                break :outer;
                            }
                        }
                    }
                }
            }
            if (!needed) {
                self.allocator.destroy(kv);
                self.engine.kit_vsti[ik].store(null, .monotonic);
            }
        }
        // 鼓组采样器层状态清理（宿主不再是鼓组 / 不再含采样器层 → 释放）
        var iks: usize = 0;
        while (iks < self.engine.kit_sampler.len) : (iks += 1) {
            const ks = self.engine.kit_sampler[iks].load(.monotonic) orelse continue;
            var needed = false;
            if (iks < self.instruments.items.len) {
                if (self.instruments.items[iks].kit) |kit| {
                    outer2: for (kit.pads.items) |pad| {
                        for (pad.layers.items) |ly| {
                            if (ly.kind == .sampler) {
                                needed = true;
                                break :outer2;
                            }
                        }
                    }
                }
            }
            if (!needed) {
                self.allocator.destroy(ks);
                self.engine.kit_sampler[iks].store(null, .monotonic);
            }
        }
    }

    /// 每帧调用：容量自动回收（删除/装载后置位；滞回 4×——用量不足容量 1/4 才缩容，
    /// 防抖；缩到 max(32, 用量×2) 留余量。一次暂停设备完成全部维度）。
    pub fn pollCapacityReclaim(self: *App) void {
        if (!self.shrink_pending and !self.kit_gc_pending) return;
        self.shrink_pending = false;
        const pc = self.params.instruments_cap;
        const qc = self.params.channels_cap;
        const rc = self.params.slots_cap;
        const need_ic = self.instruments.items.len;
        const need_cc = self.mixer_channels_state.items.len;
        var need_sc: usize = 0;
        for (self.mixer_channels_state.items) |mc| need_sc = @max(need_sc, mc.effects.items.len);
        const nic = if (pc > 32 and need_ic * 4 <= pc) @max(32, need_ic * 2) else pc;
        const ncc = if (qc > 32 and need_cc * 4 <= qc) @max(32, need_cc * 2) else qc;
        const nsc = if (rc > 32 and need_sc * 4 <= rc) @max(32, need_sc * 2) else rc;
        if (nic == pc and ncc == qc and nsc == rc and !self.kit_gc_pending) return;
        self.engine.pauseDevice();
        defer self.engine.resumeDevice();
        if (self.kit_gc_pending) {
            self.kit_gc_pending = false;
            self.gcKitPools();
        }
        if (nic != pc or ncc != qc or nsc != rc) {
            self.params.resize(self.allocator, nic, ncc, nsc) catch return;
            self.engine.setCapacity(nic, ncc, nsc) catch {};
            sequencer.instrument_cap = nic;
        }
        // 注：状态脏标数组不缩容（体量小，按高水位保留，简化语义）
    }

    /// 状态脏标数组随容量增长（仅 UI 线程；在设备暂停窗口内调用）
    fn growStateDirty(self: *App, ic: usize, cc: usize, sc: usize) void {
        const a = self.allocator;
        if (ic > self.instr_state_dirty.len) {
            const n = a.alloc(bool, ic) catch return;
            @memset(n, false);
            @memcpy(n[0..self.instr_state_dirty.len], self.instr_state_dirty);
            if (self.instr_state_dirty.len > 0) a.free(self.instr_state_dirty);
            self.instr_state_dirty = n;
        }
        // 鼓组层状态脏标（乐器容量 × kit_max_layers）
        const kl_rows = @max(ic, self.kit_layer_state_dirty.len);
        var kl_need = ic > self.kit_layer_state_dirty.len;
        if (!kl_need and self.kit_layer_state_dirty.len > 0 and self.kit_layer_state_dirty[0].len < audio.kit_max_layers) kl_need = true;
        if (kl_need) {
            const kr = a.alloc([]bool, kl_rows) catch return;
            @memset(kr, &.{});
            for (0..kl_rows) |i| {
                kr[i] = a.alloc(bool, audio.kit_max_layers) catch return;
                @memset(kr[i], false);
                if (i < self.kit_layer_state_dirty.len and self.kit_layer_state_dirty[i].len > 0) {
                    const cp = @min(audio.kit_max_layers, self.kit_layer_state_dirty[i].len);
                    @memcpy(kr[i][0..cp], self.kit_layer_state_dirty[i][0..cp]);
                }
            }
            for (self.kit_layer_state_dirty) |r| if (r.len > 0) a.free(r);
            if (self.kit_layer_state_dirty.len > 0) a.free(self.kit_layer_state_dirty);
            self.kit_layer_state_dirty = kr;
        }
        const need_rows = @max(cc, self.fx_state_dirty.len);
        var need = cc > self.fx_state_dirty.len;
        if (!need and self.fx_state_dirty.len > 0 and self.fx_state_dirty[0].len < sc) need = true;
        if (!need) return;
        const nr = a.alloc([]bool, need_rows) catch return;
        @memset(nr, &.{});
        for (0..need_rows) |i| {
            nr[i] = a.alloc(bool, sc) catch return;
            @memset(nr[i], false);
            if (i < self.fx_state_dirty.len and self.fx_state_dirty[i].len > 0) {
                const cp = @min(sc, self.fx_state_dirty[i].len);
                @memcpy(nr[i][0..cp], self.fx_state_dirty[i][0..cp]);
            }
        }
        for (self.fx_state_dirty) |r| if (r.len > 0) a.free(r);
        if (self.fx_state_dirty.len > 0) a.free(self.fx_state_dirty);
        self.fx_state_dirty = nr;
    }

    /// 存档中单通道最长效果链长度（扩容需求计算用）
    fn savedMaxChainSlots(mixer: []const persist.SavedMixerChannel) usize {
        var m: usize = 0;
        for (mixer) |sm| {
            const n: usize = @min(if (sm.effect_count > 0) @as(usize, @intCast(sm.effect_count)) else sm.effects.len, sm.effects.len);
            m = @max(m, n);
        }
        return m;
    }

    /// 添加一个通道（返回新通道下标；失败 null）
    pub fn addMixerChannel(self: *App) ?usize {
        self.ensureAudioCapacity(0, self.mixer_channels_state.items.len + 1, 0);
        self.mixer_channels_state.append(self.allocator, .{}) catch return null;
        return self.mixer_channels_state.items.len - 1;
    }

    /// 给某通道添加一个效果器（返回新槽下标；失败 null）
    pub fn addEffect(self: *App, ch: usize, kind: EffectKind) ?usize {
        if (ch >= self.mixer_channels_state.items.len) return null;
        self.ensureAudioCapacity(0, 0, self.mixer_channels_state.items[ch].effects.items.len + 1);
        const chain = &self.mixer_channels_state.items[ch].effects;
        // 注：**允许叠加同种效果**（用户拍板：选择权交给用户——多个混响/延迟
        // 叠加做特殊效果是常规玩法）。DSP 状态已改每槽一份（见 `fx_state`）。
        const slot = newEffectSlot(kind);
        chain.append(self.allocator, slot) catch return null;
        return chain.items.len - 1;
    }

    /// 新效果器槽（默认干湿/参数；新建与导入共用）
    fn newEffectSlot(kind: EffectKind) EffectSlot {
        var slot = EffectSlot{ .kind = kind };
        slot.mix = fx.defaultMix(@backingInt(kind));
        if (kind != .eq) slot.p = fx.defaultParams(@backingInt(kind));
        return slot;
    }

    /// 删除某通道的第 `slot` 个效果器
    pub fn removeEffect(self: *App, ch: usize, slot: usize) void {
        if (ch >= self.mixer_channels_state.items.len) return;
        const chain = &self.mixer_channels_state.items[ch].effects;
        if (slot >= chain.items.len) return;
        const es = chain.items[slot];
        if (es.plugin) |pl| self.retirePlugin(pl);
        if (es.fx_state) |box| self.retireFxState(box); // DSP 状态盒退役（音频侧限界保护）
        self.params.fx_ptrs[ch][slot].store(null, .monotonic); // 指针即时清零（不依赖下一帧同步）
        chain.items[slot].clearPendingState(self.allocator);
        _ = chain.orderedRemove(slot);
        self.shrink_pending = true; // 帧末尝试回收容量
    }

    /// 把一个插件实例送入退役列表（延迟销毁；可安全地对音频线程正在引用的实例）
    pub fn retirePlugin(self: *App, pl: *vst_host.Plugin) void {
        // 嵌入面板的编辑器子窗口必须先关（实例退役后没人再同步它）
        if (pl.view != null) pl.closeEditor();
        self.retired_plugins.append(self.allocator, .{ .pl = pl, .countdown = 30 }) catch {
            vst_host.unloadPlugin(self.allocator, pl); // 分配失败：立即释放（极罕见）
        };
    }

    /// 插件请求暴露界面（`requestOpenEditor`）→ 打开其所属面板（嵌入路径由帧末同步接手）。
    /// 找不到归属（已退役/待卸载）→ 忽略。
    pub fn openPanelForPlugin(self: *App, pl: *vst_host.Plugin) void {
        for (self.instruments.items, 0..) |*inst, ii| {
            if (inst.plugin == pl) {
                self.synth_win.target = .{ .instrument = @intCast(ii) };
                self.synth_win.open = true;
                self.bringToFront(&self.synth_win.z);
                return;
            }
        }
        for (self.mixer_channels_state.items, 0..) |*mc, ch| {
            for (mc.effects.items, 0..) |*es, si| {
                if (es.kind == .plugin and es.plugin == pl) {
                    self.mixer_win.panel = .{ .ch = ch, .slot = si };
                    self.bringToFront(&self.effect_win.z);
                    return;
                }
            }
        }
    }

    /// 效果器状态盒进退役列表（音频线程可能仍持有指针；倒计时后销毁）
    pub fn retireFxState(self: *App, box: *audio.FxBox) void {
        self.retired_fx.append(self.allocator, .{ .box = box, .countdown = 30 }) catch {
            self.allocator.destroy(box);
        };
    }

    /// 每帧调用：退役状态盒倒计时 → 销毁
    pub fn reapRetiredFx(self: *App) void {
        var i: usize = 0;
        while (i < self.retired_fx.items.len) {
            const r = &self.retired_fx.items[i];
            if (r.countdown == 0) {
                self.allocator.destroy(r.box);
                _ = self.retired_fx.swapRemove(i);
            } else {
                r.countdown -= 1;
                i += 1;
            }
        }
    }

    /// 每帧同步：为效果槽准备/替换/释放 DSP 状态盒并在**改 kind 之前**发布指针
    /// （音频线程以 effect_count 限界 + 盒内 kind 自洽，指针先到就不会误解）。
    /// 链外旧槽的状态由字段销毁路径退役（removeEffect/deinitMixerChannels 等）。
    pub fn syncFxStateForSlot(self: *App, ci: usize, slot: usize, es: *EffectSlot) void {
        const kind: u8 = @intCast(@backingInt(es.kind));
        const needs = kind >= 2 and kind <= 4;
        if (needs) {
            if (es.fx_state) |box| {
                if (box.kind == kind) {
                    // 自愈：导入/撤销重建通道后，音频侧指针可能与当前盒错位（槽位错移）
                    if (self.params.fx_ptrs[ci][slot].load(.monotonic) != box) {
                        self.params.fx_ptrs[ci][slot].store(box, .monotonic);
                    }
                    return; // 已就绪
                }
                self.retireFxState(box);
                es.fx_state = null;
            }
            const box = self.allocator.create(audio.FxBox) catch return;
            box.* = .{ .kind = kind, .payload = switch (kind) {
                2 => .{ .reverb = .{} },
                3 => .{ .delay = .{} },
                else => .{ .comp = .{} },
            } };
            es.fx_state = box;
            self.params.fx_ptrs[ci][slot].store(box, .monotonic);
        } else if (es.fx_state) |box| {
            self.retireFxState(box);
            es.fx_state = null;
            self.params.fx_ptrs[ci][slot].store(null, .monotonic);
        }
    }

    /// 每帧调用：退役实例倒计时 → 释放（此时音频线程已不可能持有旧指针）
    pub fn reapRetiredPlugins(self: *App) void {
        var i: usize = 0;
        while (i < self.retired_plugins.items.len) {
            const r = &self.retired_plugins.items[i];
            if (r.countdown == 0) {
                vst_host.unloadPlugin(self.allocator, r.pl);
                _ = self.retired_plugins.swapRemove(i);
            } else {
                r.countdown -= 1;
                i += 1;
            }
        }
    }

    pub const RetiredPlugin = struct { pl: *vst_host.Plugin, countdown: u8 };
    pub const RetiredFx = struct { box: *audio.FxBox, countdown: u8 };

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
        // **主通道（下标 0）永久固定**（用户约定）：主通道不移动，
        // 任何与主通道交换位置的移动也拒绝（否则主通道会被换走）
        if (ch == 0) return false;
        const ni: usize = if (dir < 0) ch -| 1 else @min(ch + 1, n - 1);
        if (ni == ch) return false;
        if (ni == 0) return false;
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
        self.shrink_pending = true; // 帧末尝试回收容量
        return true;
    }

    // ── 浮动窗口 Z 序（“点谁谁置顶”）──

    /// 把某窗口提到最上层（点击该窗口时调用）。
    /// 参数是窗口 z 字段的指针——四个窗口结构都持有 `z: i32`。
    /// **模态期间不动作**（确认框 / **导出进度窗**）：窗口的“点击置顶”用的是纯几何
    /// 判断（`inRect`，不查输入屏蔽）——弹窗按钮/导出遮罩上的点击会“点穿”到后面窗口
    /// （实测：点“取消”把它后面的窗口提上来；导出中点窗口也能置顶）。
    pub fn bringToFront(self: *App, z: *i32) void {
        if (self.modal != null or self.export_wav != null) return;
        self.z_top += 1;
        z.* = self.z_top;
    }

    // ── 撤销/重做（快照式）──

    /// 历史容量上限（超出后丢弃最旧的快照）
    pub const history_limit: usize = 128;

    /// 进行中的手势（见 `touchGesture`/`pinPendingGesture`）
    pub const Gesture = struct {
        label: []const u8,
        last_change_frame: u64,
        /// 起手提交的历史下标（pin 时替换该条快照）
        index: usize,
        /// 本手势内插件参数编辑（折叠：同槽同参一条；pin 时按 ref 排序）
        param_edits: std.ArrayListUnmanaged(ParamEditRec) = .empty,
        /// 本手势内出现过结构性信号的槽
        structural_refs: std.ArrayListUnmanaged(PluginSlotRef) = .empty,
    };

    /// 丢弃进行中的手势（释放增量/结构信号列表）
    fn clearGesture(self: *App) void {
        if (self.gesture) |*g| {
            g.param_edits.deinit(self.allocator);
            g.structural_refs.deinit(self.allocator);
            self.gesture = null;
        }
    }

    /// 标记“已保存”（脏标记清零 + 记住当前历史位置）
    pub fn markSaved(self: *App) void {
        self.pinPendingGesture(); // 保存前把手势最终值钉住（历史/脏标记一致）
        self.dirty = false;
        self.plugin_dirty = false;
        self.history_saved_index = self.history_current;
    }

    /// 插件内部状态被编辑（面板拖动 / 插件 GUI 内操作）：标脏。
    /// 操作历史由 `touchGesture` 负责（起手提交 + 静置钉值）；状态随快照往返。
    pub fn markPluginEdited(self: *App) void {
        self.dirty = true;
        self.plugin_dirty = true;
    }

    // ── 插件状态脏标（捕获复用：未变槽不再 getState）──

    /// 置某槽插件状态脏标（一切已知状态变更必须调：参数编辑/结构信号/状态恢复/实例新载）
    pub fn markSlotStateDirty(self: *App, ref: PluginSlotRef) void {
        switch (ref.kind) {
            .instrument => {
                if (ref.a < self.instr_state_dirty.len) self.instr_state_dirty[ref.a] = true;
            },
            .fx => {
                if (ref.a < self.params.channels_cap and ref.b < self.params.slots_cap and
                    ref.a < self.fx_state_dirty.len and ref.b < self.fx_state_dirty[ref.a].len)
                {
                    self.fx_state_dirty[ref.a][ref.b] = true;
                }
            },
            .kit_layer => {
                if (ref.a < self.kit_layer_state_dirty.len and ref.b < self.kit_layer_state_dirty[ref.a].len) {
                    self.kit_layer_state_dirty[ref.a][ref.b] = true;
                }
            },
        }
    }

    /// 插件状态按“已采纳”标记（恢复完成/参数回放完成）——与当前条目视为一致。
    /// **关键语义**：插件恢复后的 `getState` 回声字节与存档字节常常不同
    /// （实测 Vital：17.5 万字节里 11.5 万不同）——插件自身重归一化，不是用户编辑；
    /// 若不按“已采纳”处理，下一次提交会把回声当成差异→幽灵历史条目，
    /// 而幽灵条目的 blob 又与基线不同 → 跳转时整块 setState（卡顿）。
    pub fn markSlotStateClean(self: *App, ref: PluginSlotRef) void {
        switch (ref.kind) {
            .instrument => {
                if (ref.a < self.instr_state_dirty.len) self.instr_state_dirty[ref.a] = false;
            },
            .fx => {
                if (ref.a < self.params.channels_cap and ref.b < self.params.slots_cap and
                    ref.a < self.fx_state_dirty.len and ref.b < self.fx_state_dirty[ref.a].len)
                {
                    self.fx_state_dirty[ref.a][ref.b] = false;
                }
            },
            .kit_layer => {
                if (ref.a < self.kit_layer_state_dirty.len and ref.b < self.kit_layer_state_dirty[ref.a].len) {
                    self.kit_layer_state_dirty[ref.a][ref.b] = false;
                }
            },
        }
    }

    /// 就地替换插件状态的**记账**（预设加载等无手势路径专用）：置脏 + 标插件已改 + 提交历史。
    /// **这类路径必须走这里**：脏标驱动“提交时的差异检测 + 快照现取”——不置脏会被判
    /// “无变化”而静默丢弃条目（效果器实症），或复用旧 blob 生成携带过期状态的条目
    /// （乐器侧实症：靠 preset_name 差异勉强建了条目，但 blob 是旧状态）。
    pub fn notePluginStateReplaced(self: *App, ref: PluginSlotRef, label: []const u8) void {
        self.markSlotStateDirty(ref);
        self.markPluginEdited();
        self.commitHistory(label);
    }

    fn clearAllStateDirty(self: *App) void {
        @memset(self.instr_state_dirty, false);
        for (self.fx_state_dirty) |r| @memset(r, false);
    }

    fn sameSlotRef(a: PluginSlotRef, b: PluginSlotRef) bool {
        return a.kind == b.kind and a.a == b.a and a.b == b.b;
    }

    /// 槽引用 → 活插件实例（无 → null）
    fn slotPlugin(self: *const App, ref: PluginSlotRef) ?*vst_host.Plugin {
        switch (ref.kind) {
            .instrument => {
                if (ref.a >= self.instruments.items.len) return null;
                return self.instruments.items[ref.a].plugin;
            },
            .fx => {
                if (ref.a >= self.mixer_channels_state.items.len) return null;
                const ch = &self.mixer_channels_state.items[ref.a];
                if (ref.b >= ch.effects.items.len) return null;
                return ch.effects.items[ref.b].plugin;
            },
            .kit_layer => {
                if (ref.a >= self.instruments.items.len) return null;
                const kit = self.instruments.items[ref.a].kit orelse return null;
                var slot: usize = 0;
                for (kit.pads.items) |pad| {
                    for (pad.layers.items) |ly| {
                        if (slot == ref.b) return ly.plugin;
                        slot += 1;
                        if (slot >= @import("audio.zig").kit_max_layers) return null;
                    }
                }
                return null;
            },
        }
    }

    /// 宿主参数列表编辑（拖动/双击复位）**唯一入口**：应用 + 记录增量 + 手势。
    /// “旧值”取参数缓存（缓存只由宿主写，故为本次编辑前值）。
    pub fn setPluginParamHost(self: *App, ref: PluginSlotRef, pl: *vst_host.Plugin, idx: usize, norm: f64) void {
        const old = pl.cacheGet(idx);
        const id: u32 = if (idx < pl.params.len) pl.params[idx].id else 0;
        pl.setParamHost(idx, norm);
        self.markSlotStateDirty(ref);
        self.markPluginEdited();
        if (old) |o| {
            if (self.gesture == null) {
                self.touchGesture(self.paramGestureLabel(ref, pl, id));
            } else {
                self.touchGesture("调整插件参数"); // 续接：label 被忽略
            }
            self.recordParamEdit(ref, id, o, norm);
        } else {
            // 无缓存 → 无法回放：先建立手势（后续 setDirty/restart 往往同帧到）
            self.notePluginStructural(ref);
        }
    }

    /// 手势标签的“归属名”：乐器 → 乐器槽名（如“Solokey”）；效果器 → 通道名
    /// （自定义优先，未命名用调音台同款占位名“主通道/通道#N”）；鼓组层 →
    /// “乐器名 · 层N”；都取不到 → 插件名。
    fn gestureOwnerName(self: *App, ref: PluginSlotRef, pl: *vst_host.Plugin, buf: []u8) []const u8 {
        switch (ref.kind) {
            .instrument => {
                if (ref.a < self.instruments.items.len) {
                    const n = self.instruments.items[ref.a].name;
                    if (n.len > 0) return n;
                }
            },
            .fx => {
                if (ref.a < self.mixer_channels_state.items.len) {
                    return self.mixer_channels_state.items[ref.a].displayName(ref.a, buf);
                }
            },
            .kit_layer => {
                if (ref.a < self.instruments.items.len) {
                    const n = self.instruments.items[ref.a].name;
                    if (n.len > 0) {
                        return std.fmt.bufPrint(buf, "{s} · 层{d}", .{ n, ref.b + 1 }) catch n;
                    }
                }
            },
        }
        return pl.name();
    }

    /// 插件参数手势的标签（**“{归属名}: {参数名}”**，如“Solokey: Oscillator 1 Level”；
    /// 英文冒号省宽；参数名未知 → 仅归属名；归属名异常为空 → 固定串）。
    /// 借用 App 内固定缓冲：**仅在无进行中手势时调用**（否则会覆写到手势仍引用的内容）。
    fn paramGestureLabel(self: *App, ref: PluginSlotRef, pl: *vst_host.Plugin, id: u32) []const u8 {
        var owner_buf: [32]u8 = undefined;
        const owner = self.gestureOwnerName(ref, pl, &owner_buf);
        if (owner.len == 0) return "调整插件参数";
        const buf = &self.gesture_label_buf;
        var w: usize = @min(owner.len, buf.len);
        @memcpy(buf[0..w], owner[0..w]);
        const name = if (pl.findParamIndex(id)) |i| pl.params[i].name() else "";
        if (name.len > 0) {
            const sep = ": ";
            if (w + sep.len < buf.len) {
                @memcpy(buf[w .. w + sep.len], sep);
                w += sep.len;
            }
            const n = @min(name.len, buf.len - w);
            @memcpy(buf[w .. w + n], name[0..n]);
            w += n;
        }
        return buf[0..w];
    }

    /// 排空某槽编辑器交互（帧末）。begin/perform/end 语义：
    /// - begin（不同槽/参数）→ 先钉住当前手势：**换旋钮 = 切历史**；
    /// - end → 仅消费（同旋钮连拧靠 1s 静置合并——用户拍板）；
    /// - perform → 起手提交（手势）+ 记增量（旧值取缓存）；未知 ID/无缓存 → 结构信号。
    pub fn drainSlotEditorEdits(self: *App, ref: PluginSlotRef, pl: *vst_host.Plugin) void {
        var buf: [64]vst_host.EditEvent = undefined;
        var any_perform = false;
        while (true) {
            const n = pl.drainEditEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |ev| {
                switch (ev.kind) {
                    .begin => self.splitGestureOnBegin(ref, ev.id),
                    .end => {},
                    .perform => {
                        if (!any_perform) {
                            any_perform = true;
                            self.markSlotStateDirty(ref);
                            self.markPluginEdited();
                            if (self.gesture == null) {
                                self.touchGesture(self.paramGestureLabel(ref, pl, ev.id));
                            } else {
                                self.touchGesture("调整插件参数"); // 续接：label 被忽略
                            }
                        }
                        self.applyEditorPerform(ref, pl, ev.id, ev.value);
                    },
                }
            }
        }
        if (pl.takeEditOverflow()) self.notePluginStructural(ref);
    }

    /// 新互动的 begin：若当前手势已经在编辑**别的参数**（或别的槽）→ 先钉住（切开历史）。
    /// 同参数 begin 续接（有的插件每次变动前都发 begin）。
    fn splitGestureOnBegin(self: *App, ref: PluginSlotRef, id: u32) void {
        const g = if (self.gesture) |*g| g else return;
        for (g.param_edits.items) |rec| {
            if (sameSlotRef(rec.ref, ref) and rec.param_id == id) return;
        }
        self.pinPendingGesture();
    }

    /// 一条 perform 的记账：增量（旧值取缓存）+ 缓存跟随；无法记增量 → 结构信号
    fn applyEditorPerform(self: *App, ref: PluginSlotRef, pl: *vst_host.Plugin, id: u32, value: f64) void {
        const idx = pl.findParamIndex(id);
        var rec_ok = false;
        if (idx) |i| {
            if (pl.cacheGet(i)) |old| {
                self.recordParamEdit(ref, id, old, value);
                rec_ok = true;
            }
            pl.cacheSet(i, value); // 缓存跟随（后续编辑的“旧值”）
        }
        if (!rec_ok) {
            if (self.gesture) |*g| self.addStructuralRef(g, ref);
        }
    }

    /// 记录一条参数增量（同槽同参折叠：old 首次、new 末次）。无手势 → 丢弃（回落整块）
    fn recordParamEdit(self: *App, ref: PluginSlotRef, param_id: u32, old: f64, new: f64) void {
        const g = if (self.gesture) |*g| g else return;
        for (g.param_edits.items) |*rec| {
            if (sameSlotRef(rec.ref, ref) and rec.param_id == param_id) {
                rec.new = new;
                return;
            }
        }
        g.param_edits.append(self.allocator, .{ .ref = ref, .param_id = param_id, .old = old, .new = new }) catch {};
    }

    fn addStructuralRef(self: *App, g: *Gesture, ref: PluginSlotRef) void {
        for (g.structural_refs.items) |sref| {
            if (sameSlotRef(sref, ref)) return;
        }
        g.structural_refs.append(self.allocator, ref) catch {};
    }

    /// 结构性改动信号（setDirty/restart/编辑溢出/无缓存）：本步禁用该槽参数回放
    pub fn notePluginStructural(self: *App, ref: PluginSlotRef) void {
        self.markSlotStateDirty(ref);
        self.markPluginEdited();
        self.touchGesture("编辑插件");
        if (self.gesture) |*g| self.addStructuralRef(g, ref);
    }

    /// 新建（空）工程：重置为默认基线——
    /// 1 个样式 + 样式 1 在 Track 1 最左的片段 + 1 个减法合成器 + 默认调音台/BPM；
    /// 历史以“新建”为基线，视为已保存（dirty = false）。**先停播**（数据全换）。
    /// 清空音频样式 + 资产池（**新建/打开工程共用**）。
    /// 顺序很重要：先作废进行中的导入 → **暂停设备**（音频线程可能正读资产）→
    /// 清样式/释放资产 → 发布空播放表 → 恢复设备（`defer`）。
    /// 否则会留下悬念指针：旧资产已 free，而已发布的播放表/预览还指着它。
    fn clearAudioEverything(self: *App) void {
        self.import_mgr.cancelAll();
        self.import_mgr.drain();
        self.engine.pauseDevice();
        defer self.engine.resumeDevice();
        // 样式（名字/路径）
        for (self.audio_styles.items) |*st| {
            self.allocator.free(st.name);
            self.allocator.free(st.path);
        }
        self.audio_styles.clearRetainingCapacity();
        self.resetAudioAssets(); // 清资产 + 预览（含 preview_asset 发布 null）
        // 已发布的播放表可能还指着旧资产 → 在**暂停窗口内**重发（空表；旧表退役）
        self.rebuildAudioTable();
        // UI 侧引用一并复位
        self.audio_style_sel = -1;
        self.panels.ctx_audio_style = null;
        self.wave_win.open = false; // 波形窗可能正看着被清掉的样式/片段
    }

    pub fn resetToDefaultProject(self: *App) void {
        self.stopPlayback();
        // 音频：新建的空工程没有任何音频样式/资产 → 一并清空并释放内存
        self.clearAudioEverything();
        self.panels.patterns_tab_audio = false; // 回到音符页（音页已无样式）
        // 样式 / 调音台 / BPM 拍号
        self.resetPatterns(1);
        self.clearTrackNames(); // 轨道：自定义名清空——行跨度自动推导（最短行程 128 行）
        self.clearTrackMutes(); // 静音集合一并清零
        self.playlist.view_rows = 128; // 可见行快照复位（下一帧视图重写）
        self.resetMixerChannels(default_mixer_channels);
        self.bpm = 120;
        self.time_num = 4;
        self.time_den = 4;
        self.steps_per_bar = model.stepsPerBarFor(4, 4);
        // 音符清空；片段：样式 1 在 Track 1 最左（长度 = 样式有效长度）
        self.notes.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        const len = self.patternEffectiveLen(0);
        self.clips.append(self.allocator, .{ .track = 0, .start = 0, .len = len, .pattern = 0 }) catch {};
        // 乐器：重建为 1 个减法合成器（removeInstrument 会退役旧指针——音频安全）
        while (self.instruments.items.len > 0) {
            self.removeInstrument(self.instruments.items.len - 1);
        }
        _ = self.addInstrument("减法合成器");
        // 选择 / 窗口目标钳制（一切都指向样式 0 / 乐器 0）
        self.sel.pattern = 0;
        self.sel.instrument = if (self.instruments.items.len > 0) 0 else -1;
        if (self.piano.pattern != null) self.piano.pattern = 0;
        self.mixer_win.selected_channel = 0;
        self.mixer_win.panel = null;
        // 历史：新建 = 新基线（视为已保存）
        self.resetHistory("新建");
        self.markSaved();
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
        self.freeSavedMixerChannels(st.mixer, true);
        self.allocator.free(st.mixer);
        self.freeSavedAudioStyles(st.audio_styles);
        for (st.instruments) |*si| self.freeSavedInstrument(si, true);
        self.allocator.free(st.instruments);
        for (st.pattern_names) |nm| self.allocator.free(nm);
        self.allocator.free(st.pattern_names);
        for (st.track_names) |nm| self.allocator.free(nm);
        self.allocator.free(st.track_names);
        self.allocator.free(st.track_muted);
        self.allocator.free(st.param_edits);
        self.allocator.free(st.structural_refs);
    }

    /// 把当前调音台通道导出为存档切片（历史快照 / 工程保存共用）
    fn exportMixerChannels(self: *App, allocator: std.mem.Allocator, include_plugin_state: bool, pooled: bool) ![]persist.SavedMixerChannel {
        const n_ch = self.mixer_channels_state.items.len;
        // 注：即使 0 条也要返回**已分配**切片（与 `free` 配对；
        // 不能直接返回 `&.{}`——那样 `freeHistoryState` 的 `free` 会崩，
        // 而返回 `alloc(0)` 又必须被 free）
        const mix = try allocator.alloc(persist.SavedMixerChannel, n_ch);
        var filled: usize = 0;
        errdefer {
            self.freeSavedMixerChannels(mix[0..filled], pooled);
            allocator.free(mix);
        }
        for (self.mixer_channels_state.items, 0..) |mc, i| {
            var sm = persist.SavedMixerChannel{
                .volume = mc.volume,
                .pan = mc.pan,
                .muted = mc.muted,
            };
            // 自定义名字（空 = 无；dupe 供快照/存档独立存活）
            if (mc.name_len > 0) {
                sm.name = try allocator.dupe(u8, mc.name[0..mc.name_len]);
                errdefer allocator.free(sm.name);
            }
            // 效果器链：动态长度切片（不再 4 槽截断）
            const effs = try allocator.alloc(persist.SavedEffectSlot, mc.effects.items.len);
            errdefer allocator.free(effs);
            sm.effects = effs;
            sm.effect_count = @intCast(effs.len);
            for (mc.effects.items, 0..) |es, si| {
                // 效果器段：分配切片（长度 = band_count）
                const bands = try allocator.alloc(persist.SavedEqBand, es.bands.len);
                errdefer allocator.free(bands);
                for (es.bands, 0..) |b, bi| {
                    bands[bi] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
                }
                // 插件状态（历史快照与工程保存都携带；历史走内容去重池共享）
                var comp_b64: []const u8 = "";
                var ctrl_b64: []const u8 = "";
                if (include_plugin_state and es.kind == .plugin) {
                    // 捕获复用：槽未脏且来向条目同槽同路径 → 沿其文本（intern 命中同块）
                    if (self.reuseFxState(i, si, &es, pooled)) |r| {
                        const rc = if (r.comp.len > 0) try self.allocator.dupe(u8, r.comp) else @as([]const u8, "");
                        const rk = if (r.ctrl.len > 0) try self.allocator.dupe(u8, r.ctrl) else @as([]const u8, "");
                        if (pooled) {
                            comp_b64 = if (rc.len > 0) (self.state_pool.intern(self.allocator, rc) orelse blk: {
                                self.allocator.free(rc);
                                break :blk "";
                            }) else rc;
                            ctrl_b64 = if (rk.len > 0) (self.state_pool.intern(self.allocator, rk) orelse blk: {
                                self.allocator.free(rk);
                                break :blk "";
                            }) else rk;
                        } else {
                            comp_b64 = rc;
                            ctrl_b64 = rk;
                        }
                    } else {
                        const raw_c = try captureSlotStateB64(allocator, &es, true);
                        const raw_k = try captureSlotStateB64(allocator, &es, false);
                        if (pooled) {
                            comp_b64 = if (raw_c.len > 0) (self.state_pool.intern(self.allocator, raw_c) orelse blk: {
                                self.allocator.free(raw_c);
                                break :blk "";
                            }) else raw_c;
                            ctrl_b64 = if (raw_k.len > 0) (self.state_pool.intern(self.allocator, raw_k) orelse blk: {
                                self.allocator.free(raw_k);
                                break :blk "";
                            }) else raw_k;
                        } else {
                            comp_b64 = raw_c;
                            ctrl_b64 = raw_k;
                        }
                    }
                }
                // 状态已到手：后续失败时按归属释放（池块 release / 独占块 free）
                errdefer if (comp_b64.len > 0) {
                    if (pooled) {
                        self.state_pool.release(self.allocator, comp_b64);
                    } else {
                        self.allocator.free(comp_b64);
                    }
                };
                errdefer if (ctrl_b64.len > 0) {
                    if (pooled) {
                        self.state_pool.release(self.allocator, ctrl_b64);
                    } else {
                        self.allocator.free(ctrl_b64);
                    }
                };
                var path_dup: []const u8 = "";
                if (es.pluginPath().len > 0) {
                    path_dup = try allocator.dupe(u8, es.pluginPath());
                    errdefer allocator.free(path_dup);
                }
                // 类 CID（活实例优先，否则槽位记录；重绑定身份）
                var cid_dup: []const u8 = "";
                if (es.kind == .plugin) {
                    if (es.plugin) |pl| {
                        var cb2: [32]u8 = undefined;
                        cid_dup = try allocator.dupe(u8, pl.cidHex(&cb2));
                    } else if (es.pluginCid().len == 32) {
                        cid_dup = try allocator.dupe(u8, es.pluginCid());
                    }
                    if (cid_dup.len > 0) {
                        errdefer allocator.free(cid_dup);
                    }
                }
                effs[si] = .{
                    .kind = @backingInt(es.kind),
                    .enabled = es.enabled,
                    .mix = es.mix,
                    .bands = bands,
                    .p = es.p,
                    .plugin_path = path_dup,
                    .plugin_state = comp_b64,
                    .plugin_state_ctrl = ctrl_b64,
                    .plugin_cid = cid_dup,
                };
            }
            mix[i] = sm;
            filled = i + 1;
        }
        return mix;
    }

    /// 用存档切片恢复调音台通道（历史恢复 / 工程加载共用）。
    /// - 位置+路径匹配的旧插件实例**保留**（撤销/重做不重置插件内部状态）；
    ///   其余旧实例退役（延迟销毁，音频线程安全）；
    /// - 存档中的插件状态解码为 `pending_state`（实例就绪后由 syncPluginSlots 应用）；
    /// - 构建失败（OOM）→ 整体放弃，旧状态不变。
    /// `prev`：来向条目的通道快照（可为 null＝工程导入等无对照场景）。
    /// `prev_idx`/`target_idx`：历史双向下标（逐槽应用计划：skip / 参数回放 / 整块）；
    /// 实例/状态盒救援与它们无关。
    fn importMixerChannels(self: *App, mixer: []const persist.SavedMixerChannel, prev: ?[]const persist.SavedMixerChannel, prev_idx: usize, target_idx: usize) void {
        const alloc = self.allocator;
        self.ensureAudioCapacity(0, if (mixer.len == 0) default_mixer_channels else mixer.len, savedMaxChainSlots(mixer));
        const n_saved = mixer.len;
        const n_total = if (mixer.len == 0) default_mixer_channels else n_saved;
        // 参数回放任务（构建期登记；救援后执行——那时新槽才持有实例）
        const ReplayJobSlot = struct { ch: usize, slot: usize, job: ReplayJob, saved: *const persist.SavedEffectSlot };
        var replay_jobs: std.ArrayListUnmanaged(ReplayJobSlot) = .empty;
        defer replay_jobs.deinit(alloc);

        // ── 1) 构建新通道列表（先不动旧链：救援需要旧槽仍存活）──
        var new_list: std.ArrayListUnmanaged(MixerChannel) = .empty;
        var build_ok = true;
        new_list.ensureTotalCapacity(alloc, n_total) catch {
            build_ok = false;
        };
        var i: usize = 0;
        while (build_ok and i < n_total) : (i += 1) {
            var mc = MixerChannel{};
            if (i < n_saved) {
                const sm = mixer[i];
                mc.volume = sm.volume;
                mc.pan = sm.pan;
                mc.muted = sm.muted;
                const n = @min(sm.name.len, mc.name.len);
                @memcpy(mc.name[0..n], sm.name[0..n]);
                mc.name_len = n;
                // 效果链：按 effect_count 恢复（0 = 旧存档：按 kind != 0 推断）
                const n_eff: usize = if (sm.effect_count > 0)
                    @min(@as(usize, @intCast(sm.effect_count)), sm.effects.len)
                else blk: {
                    var n2: usize = 0;
                    for (sm.effects) |se| {
                        if (se.kind != 0) n2 += 1;
                    }
                    break :blk n2;
                };
                var se_i: usize = 0;
                while (se_i < n_eff) : (se_i += 1) {
                    const se = sm.effects[se_i];
                    const kind: EffectKind = switch (se.kind) {
                        1 => .eq,
                        2 => .reverb,
                        3 => .delay,
                        4 => .compressor,
                        5 => .plugin,
                        else => continue, // 未知类型跳过
                    };
                    var slot = newEffectSlot(kind);
                    slot.enabled = se.enabled;
                    slot.mix = se.mix;
                    // 通用参数（混响/延迟/压缩器；旧存档缺失 → 全 0）
                    if (slot.kind != .eq) {
                        slot.p = se.p;
                        slot.setPluginPath(se.plugin_path); // VST3 插件路径（旧档为空）
                        if (se.plugin_cid.len > 0) slot.setPluginCid(se.plugin_cid); // 身份（旧档为空 → 加载后回填）
                        // 旧存档/手改档全 0（未写入参数）→ 用该类型默认值，避免“零值怪音色”
                        var all_zero = true;
                        for (se.p) |v| {
                            if (v != 0) all_zero = false;
                        }
                        if (all_zero) slot.p = fx.defaultParams(se.kind);
                        // **旧档迁移**：延迟的 p[0] 曾是毫秒，现在是节奏档位码——越界/非整 → 归默认
                        if (se.kind == 3) {
                            const p0 = slot.p[0];
                            if (p0 < 0 or p0 > @as(f32, @floatFromInt(fx.delay_tempos.len - 1)) or p0 != @trunc(p0)) {
                                slot.p[0] = @floatFromInt(fx.delay_tempo_default);
                            }
                        }
                    }
                    // 插件状态（base64 → 原始字节；空/解码失败 → null，用默认参数）。
                    // 逐槽计划：状态未变 → 不设 pending；参数回放 → 延后（救援后执行）；
                    // 其余 → pending（帧末 setState；防卡顿的商 DAW 式分流）
                    if (kind == .plugin) {
                        var skip_state = false;
                        if (prev) |pm| {
                            if (i < pm.len and se_i < pm[i].effects.len) {
                                const pse = pm[i].effects[se_i];
                                skip_state = std.mem.eql(u8, se.plugin_path, pse.plugin_path) and
                                    stateBlobsEqual(se.plugin_state, se.plugin_state_ctrl, pse.plugin_state, pse.plugin_state_ctrl);
                            }
                        }
                        var replay_ok = false;
                        if (!skip_state and prev_idx != target_idx) {
                            const ref = PluginSlotRef{ .kind = .fx, .a = @intCast(@min(i, std.math.maxInt(u16))), .b = @intCast(@min(se_i, std.math.maxInt(u16))) };
                            if (self.fxSlotLivePlugin(i, se_i, se.plugin_path) != null) {
                                if (self.replayPlanFor(ref, prev_idx, target_idx)) |job| {
                                    replay_jobs.append(alloc, .{ .ch = i, .slot = se_i, .job = job, .saved = &sm.effects[se_i] }) catch {};
                                    replay_ok = true;
                                }
                            }
                        }
                        if (!skip_state and !replay_ok) {
                            slot.pending_state = b64Decode(alloc, se.plugin_state);
                            slot.pending_state_ctrl = b64Decode(alloc, se.plugin_state_ctrl);
                        }
                    }
                    // 段：按需复制（旧存档 4 段 → 剩下的段保留默认值）
                    const nb: usize = @min(se.bands.len, slot.bands.len);
                    for (se.bands[0..nb], 0..) |b, bi| {
                        slot.bands[bi] = .{ .freq = b.freq, .gain_db = b.gain_db, .q = b.q };
                    }
                    mc.effects.append(alloc, slot) catch {
                        build_ok = false;
                        break;
                    };
                }
            }
            if (build_ok) {
                new_list.append(alloc, mc) catch {
                    build_ok = false;
                };
            }
            if (!build_ok) {
                for (mc.effects.items) |*es| es.clearPendingState(alloc);
                mc.effects.deinit(alloc);
            }
        }
        if (!build_ok) {
            for (new_list.items) |*mc| {
                for (mc.effects.items) |*es| es.clearPendingState(alloc);
                mc.effects.deinit(alloc);
            }
            new_list.deinit(alloc);
            return; // 保持旧状态不变
        }

        // ── 2) 实例救援：位置与路径均匹配 → 旧实例搬入新槽 ──
        for (new_list.items, 0..) |*mc, ch| {
            if (ch >= self.mixer_channels_state.items.len) break;
            const old_mc = &self.mixer_channels_state.items[ch];
            for (mc.effects.items, 0..) |*nes, si| {
                if (si >= old_mc.effects.items.len) break;
                const oes = &old_mc.effects.items[si];
                // 内置效果（混响/延迟/压缩）：同位置同类型 → **DSP 状态盒随槽搬运**。
                // 否则撤销/重做每次重建通道都会：延迟盒 768KB 重分配 + 尾音/回声清零
                //（卡顿 + 跳音）
                if (nes.kind == oes.kind and nes.kind != .plugin and nes.kind != .empty) {
                    if (oes.fx_state) |box| {
                        nes.fx_state = box;
                        oes.fx_state = null; // 已搬走：退役清理不重复处理
                    }
                    continue;
                }
                const old_pl = oes.plugin orelse continue;
                if (nes.kind != .plugin or oes.kind != .plugin) continue;
                if (!std.mem.eql(u8, nes.pluginPath(), oes.pluginPath())) continue;
                nes.plugin = old_pl;
                oes.plugin = null; // 已搬走：退役循环跳过
            }
        }
        // ── 2.5) 参数增量回放（实例已就位；setParam 免锁，不碰 setState）──
        for (replay_jobs.items) |rj| {
            var done = false;
            if (rj.ch < new_list.items.len) {
                const chain = &new_list.items[rj.ch].effects;
                if (rj.slot < chain.items.len) {
                    const nes = &chain.items[rj.slot];
                    if (nes.plugin) |pl| done = runReplay(pl, rj.job);
                    if (done) {
                        self.markSlotStateClean(.{ .kind = .fx, .a = @intCast(rj.ch), .b = @intCast(rj.slot) });
                    } else if (nes.pending_state == null and nes.pending_state_ctrl == null) {
                        // 兜底：整块恢复（从目标保存文本解码）
                        nes.pending_state = b64Decode(alloc, rj.saved.plugin_state);
                        nes.pending_state_ctrl = b64Decode(alloc, rj.saved.plugin_state_ctrl);
                        self.markSlotStateDirty(.{ .kind = .fx, .a = @intCast(rj.ch), .b = @intCast(rj.slot) });
                    }
                }
            }
        }
        // ── 3) 旧链：剩余实例退役 + 释放（含 pending 状态/状态盒）──
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.plugin) |pl| {
                    es.plugin = null;
                    self.retirePlugin(pl);
                }
                if (es.fx_state) |box| {
                    es.fx_state = null;
                    self.retireFxState(box);
                }
                es.clearPendingState(alloc);
            }
            mc.effects.deinit(alloc);
        }
        self.mixer_channels_state.deinit(alloc);
        self.mixer_channels_state = new_list;
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
            for (insts[0..n]) |*si| self.freeSavedInstrument(si, true);
            self.allocator.free(insts);
        }
        for (self.instruments.items, 0..) |*inst, i| {
            insts[i] = try self.exportInstrument(inst, true);
            n += 1;
        }
        // 历史快照**携带**插件状态（撤销可回退插件参数/结构改动）；去重池共享
        const mixer = try self.exportMixerChannels(self.allocator, true, true);
        errdefer {
            // 后续分配失败时释放（新增 pat_names 带来的失败路径；原代码无后续分配）
            self.freeSavedMixerChannels(mixer, true);
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
        // 轨道自定义名（稀疏 → 密集到最大命名行号；空串 = 未命名）
        const n_named: usize = self.denseTrackNamesLen();
        const trk_names = try self.allocator.alloc([]u8, n_named);
        var tn: usize = 0;
        errdefer {
            for (trk_names[0..tn]) |nm| self.allocator.free(nm);
            self.allocator.free(trk_names);
        }
        while (tn < n_named) : (tn += 1) {
            trk_names[tn] = if (self.track_names.get(@intCast(tn))) |nm|
                try self.allocator.dupe(u8, nm)
            else
                try self.allocator.alloc(u8, 0);
        }
        // 静音轨道（排序行号列表——集合语义；快照可撤销）
        const nmute: usize = self.track_muted.count();
        const muted_list = try self.allocator.alloc(i32, nmute);
        errdefer self.allocator.free(muted_list);
        {
            var mi: usize = 0;
            var mit = self.track_muted.keyIterator();
            while (mit.next()) |k| : (mi += 1) muted_list[mi] = k.*;
            std.mem.sort(i32, muted_list, {}, std.sort.asc(i32));
        }
        // 参数增量默认空（pin 时填入）；仍用真分配（freeHistoryState 无条件 free）
        const recs0 = try self.allocator.alloc(ParamEditRec, 0);
        errdefer self.allocator.free(recs0);
        // 已捕获（本次全部槽都已“现取或复用”）→ 插件状态脏标清零
        self.clearAllStateDirty();
        const astyles = try self.exportAudioStyles(self.allocator, false);
        errdefer self.freeSavedAudioStyles(astyles);
        return .{
            .label = label_copy,
            .notes = notes,
            .clips = clips,
            .instruments = insts,
            .mixer = mixer,
            .audio_styles = astyles,
            .pattern_names = pat_names,
            .track_names = trk_names,
            .track_muted = muted_list,
            .param_edits = recs0,
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
            // 音频片段字段（样式引用/trim）也要比较——否则粗剪/换源被判“无变化”
            if (a.audio_style != b.audio_style or a.trim_start != b.trim_start or a.trim_len != b.trim_len) return false;
        }
        // 音频样式（名称/路径/通道/增益）——否则调样式推子会被判“无变化”丢历史
        if (st.audio_styles.len != self.audio_styles.items.len) return false;
        for (st.audio_styles, self.audio_styles.items) |a, b| {
            if (!std.mem.eql(u8, a.name, b.name)) return false;
            if (!std.mem.eql(u8, a.path, b.path)) return false;
            if (a.channel != b.channel or a.gain != b.gain or a.speed != b.speed) return false;
        }
        if (st.instruments.len != self.instruments.items.len) return false;
        for (st.instruments, self.instruments.items, 0..) |a, b, ii| {
            if (a.volume != b.volume or a.pan != b.pan or a.muted != b.muted or
                a.mixer != b.mixer or a.midi_channel != b.midi_channel) return false;
            if (!std.mem.eql(u8, a.name, b.name)) return false;
            if (!std.mem.eql(u8, a.preset_name, b.preset_name)) return false; // 关联预设名（否则加载同名同参预设会被判“无变化”）
            // 乐器类型/鼓组内容也要比较（否则鼓组编辑被判“无变化”）
            if (a.kind != @backingInt(b.kind)) return false;
            if (a.kit.pads.len != (if (b.kit) |k| k.pads.items.len else 0)) return false;
            if (b.kit) |k| {
                var flat: usize = 0; // 展平槽位（脏标寻址；与 syncParams 同序）
                for (a.kit.pads, k.pads.items) |sa, ba| {
                    if (sa.pitch != ba.pitch) return false;
                    if (!std.mem.eql(u8, sa.name, ba.name)) return false;
                    if (sa.layers.len != ba.layers.items.len) return false;
                    for (sa.layers, ba.layers.items) |sl, bl| {
                        if (sl.kind != @backingInt(bl.kind)) return false;
                        if (sl.gain != bl.gain) return false;
                        if (!std.mem.eql(u8, sl.source_preset, bl.source_preset)) return false;
                        // VST3 层：路径/CID + **脏时与活实例比较音色**——否则插件内参数
                        // 编辑被判“无变化”，静默丢弃历史条目（同乐器级机制）
                        if (bl.kind == .vst3) {
                            if (!std.mem.eql(u8, sl.plugin_path, bl.pluginPath())) return false;
                            if (!std.mem.eql(u8, sl.plugin_cid, bl.pluginCid())) return false;
                            if (ii < self.kit_layer_state_dirty.len and flat < self.kit_layer_state_dirty[ii].len and
                                self.kit_layer_state_dirty[ii][flat])
                            {
                                if (!self.layerStateMatchesLive(&bl, sl.plugin_state, sl.plugin_state_ctrl)) return false;
                            }
                        }
                        const cur = persist.exportSynth(bl.params);
                        if (!std.meta.eql(sl.synth, cur)) return false;
                        flat += 1;
                    }
                }
            }
            // **合成器参数也要比较**——否则 ADSR/滤波等改动会被判为“无变化”，
            // 静默丢弃历史条目（实测 bug：调 ADSR 不产生历史）
            const cur = persist.exportSynth(b.synth);
            if (!std.meta.eql(a.synth, cur)) return false;
            // VST3 乐器：路径与音色也要比较——否则调音色/换插件被判“无变化”而静默丢历史
            if (!std.mem.eql(u8, a.plugin_path, b.pluginPath())) return false;
            if (b.kind == .vst3 and ii < self.instr_state_dirty.len and self.instr_state_dirty[ii]) {
                if (!self.instrumentStateMatchesLive(&b, a.plugin_state, a.plugin_state_ctrl)) return false;
            }
        }
        if (st.bpm != self.bpm or st.time_num != self.time_num or st.time_den != self.time_den) return false;
        // 样式名字（数量 + 内容）——否则重命名会被判“无变化”，静默丢弃历史条目
        if (st.pattern_names.len != self.pattern_items.items.len) return false;
        for (st.pattern_names, self.pattern_items.items) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        // 轨道自定义名（稀疏比较：快照数组 = 到最大命名行号为止，空串 = 未命名）
        if (st.track_names.len != self.denseTrackNamesLen()) return false;
        for (st.track_names, 0..) |a, i| {
            const b = self.track_names.get(@intCast(i)) orelse "";
            if (!std.mem.eql(u8, a, b)) return false;
        }
        // 静音集合（数量 + 隶属——快照已排序，集合语义比较）
        if (st.track_muted.len != self.track_muted.count()) return false;
        for (st.track_muted) |k| {
            if (!self.track_muted.contains(k)) return false;
        }
        // 调音台通道（数量/增益/声像/静音/效果链）——否则“添加通道/效果器”会被判无变化
        if (st.mixer.len != self.mixer_channels_state.items.len) return false;
        for (st.mixer, self.mixer_channels_state.items, 0..) |a, b, ci| {
            if (a.volume != b.volume or a.pan != b.pan or a.muted != b.muted) return false;
            // 通道名也要比较——否则重命名被判为“无变化”，静默丢弃历史条目
            if (!std.mem.eql(u8, a.name, b.name[0..b.name_len])) return false;
            const bn: usize = @min(b.effects.items.len, a.effects.len);
            if (a.effect_count != b.effects.items.len) return false;
            for (0..bn) |si| {
                const ae = a.effects[si];
                const be = b.effects.items[si];
                if (ae.kind != @backingInt(be.kind) or ae.enabled != be.enabled or ae.mix != be.mix) return false;
                for (ae.bands, be.bands) |ab, bb| {
                    if (ab.freq != bb.freq or ab.gain_db != bb.gain_db or ab.q != bb.q) return false;
                }
                // **通用参数位（混响/延迟/压缩）也要比较**——否则旋钮调整被判
                // “无变化”，静默丢弃历史条目（实测 bug：三效果器旋钮不进历史、
                // 不标脏；EQ 的 bands 有比较所以正常）
                for (ae.p, be.p) |pa, pb| {
                    if (pa != pb) return false;
                }
                // 插件路径与状态（历史快照携带插件 state；不一致 → 视为有变化）。
                // 脏标未置 → 自上次捕获未变，免 getState 直接视为相等
                if (!std.mem.eql(u8, ae.plugin_path, be.pluginPath())) return false;
                if (be.kind == .plugin and ci < self.params.channels_cap and si < self.params.slots_cap and self.fx_state_dirty[ci][si]) {
                    if (!self.pluginStateMatchesLive(&be, ae.plugin_state, ae.plugin_state_ctrl)) return false;
                }
            }
        }
        return true;
    }

    /// 提交一次历史快照（**操作完成后**调用；`label` 会被复制）。
    /// 若当前状态与所在快照等价（忽略选区）→ 不产生新条目（防“点了没动”噪音）。
    pub fn commitHistory(self: *App, label: []const u8) void {
        if (self.history.items.len > 0 and self.stateEqualsCurrent()) return;
        // 片段/音频样式可能变 → 播放表重建（帧末；廉价标记）
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
        // **脏标记与操作历史同源**：当前指针 ≠ 保存点即脏。
        // 所有编辑（含效果器旋钮等只设 `history_pending` 的拖动类控件）都经
        // 这里提交——无需逐点手动标记（各编辑函数里的手动 set 保留为冗余）。
        self.dirty = self.history_current != self.history_saved_index or self.plugin_dirty;
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

    /// 播放中**撤销/重做/点历史**后：不停播，走“编辑重扫”（与
    /// `rescanForPlaybackEdit` 同机制）。差分基准 = 跳转前快照 `history[old_idx]`
    /// （历史当前项恒等于跳转前的 live 数据）。不重扫的后果：旧数据的事件
    /// 残留在队列、新数据不响。
    fn publishHistoryRescan(self: *App, old_idx: usize) void {
        if (!self.playing) return;
        if (old_idx >= self.history.items.len) return;
        const old = &self.history.items[old_idx];
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
        // 发布顺序：**先安全界、后编辑代**（与 rescanForPlaybackEdit 一致）
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
    /// 应用历史条目。`prev_idx`＝**来向条目**（改 `history_current` 之前的下标）：
    /// 用于跳过未变插件状态的重放——撤销/重做最贵的一步是逐插件 `setState`
    /// （插件内部锁 + 可能重建内部状态 → 全曲卡顿），而多数条目间只有少数插件真正变过。
    /// 判定：目标条目与来向条目该槽的状态（含路径）同内容；池化保证同内容常是同指针 → O(1)。
    /// 前提“实例现状 == 来向条目状态”由两条纪律保证：编辑必经手势提交（导航前
    /// `pinPendingGesture` 钉值），且条目应用后帧末即重放（同帧无第二次导航）。
    fn applyHistoryState(self: *App, st: *const HistoryState, prev_idx: usize, target_idx: usize) void {
        // 播放中**不停播**：撤销/重做/跳转走“编辑重扫”（见 `publishHistoryRescan`）——
        // 停播会让编辑时音乐中断（回归 bug：Ctrl+Z / 点历史条目导致播放暂停）
        if (!self.playing) self.stopPlayback(); // 停止态：作废旧事件 + 清残留声部
        self.history_pending = null; // 拖动中的 coalesce 标记作废
        self.clearGesture(); // 进行中的手势作废（导航入口已先行钉值）
        // 容量先行：存档可能比当前容量大（扩容后重建；设备自动暂停/恢复）
        self.ensureAudioCapacity(st.instruments.len, st.mixer.len, savedMaxChainSlots(st.mixer));
        // 鼓组池重置**只在乐器重建（数量变化 → 下标重排）时**置位（见下方分支）。
        // 原位更新（数量相同）池仍有效——池 = 纯声部状态（同 `engine.synths`），
        // 与乐器内容无关。**无条件置位 = 实测 bug**：帧末 `pollCapacityReclaim`
        // 会为此**暂停/恢复设备** → 撤销/重做音符编辑“卡一下 + 爆音”
        //（直接编辑路径不置位，所以无缝）。
        var kit_host_changed = false;
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
                // 宿主 kit↔非 kit 变化 → 帧末清理该槽的池（罕见；池不再对应）
                if ((si.kind == 1) != (target.kit != null)) kit_host_changed = true;
                if (!std.mem.eql(u8, target.name, si.name)) {
                    const dup = self.allocator.dupe(u8, si.name) catch continue;
                    self.allocator.free(target.name);
                    target.name = dup;
                }
                // 逐槽状态应用计划（skip / 参数回放 / 整块）
                const plan = self.planInstrumentApply(i, prev_idx, target_idx, si, target);
                self.applySavedInstrument(si, target, plan, prev_idx, target_idx);
            }
        } else {
            self.kit_reset = true;
            self.kit_gc_pending = true; // 乐器将被重建：鼓组池帧末全量重置
            while (self.instruments.items.len > 0) {
                self.removeInstrument(self.instruments.items.len - 1);
            }
            for (st.instruments) |*si| {
                const idx = self.addInstrument(si.name);
                if (idx < 0) continue;
                const target = &self.instruments.items[@intCast(idx)];
                self.applySavedInstrument(si, target, .full, target_idx, target_idx); // 全新实例：整块重放
            }
        }
        if (kit_host_changed) self.kit_gc_pending = true; // 帧末清理该槽的池（罕见路径）
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
        self.setTrackNames(st.track_names); // 空快照 → 全部回到合成默认名（行跨度自动推导）
        self.setTrackMutes(st.track_muted); // 静音集合同理（空快照 → 全未静音）
        self.bpm = st.bpm;
        self.time_num = st.time_num;
        self.time_den = st.time_den;
        self.steps_per_bar = st.steps_per_bar;
        // 调音台通道（含效果链）。来向条目 + 双向下标 = 逐槽状态应用计划依据
        self.importMixerChannels(
            st.mixer,
            if (prev_idx < self.history.items.len and prev_idx != target_idx) self.history.items[prev_idx].mixer else null,
            prev_idx,
            target_idx,
        );
        self.importAudioStyles(st.audio_styles);
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
        self.pinPendingGesture(); // 手势未钉：先把最终值钉住再导航
        const old_idx = self.history_current;
        self.history_current -= 1;
        self.applyHistoryState(&self.history.items[self.history_current], old_idx, self.history_current);
        self.publishHistoryRescan(old_idx);
        self.dirty = self.history_current != self.history_saved_index or self.plugin_dirty;
        return true;
    }

    /// 重做（Ctrl+Alt+Z）。返回是否成功。
    pub fn redo(self: *App) bool {
        if (self.history.items.len == 0 or self.history_current + 1 >= self.history.items.len) return false;
        self.pinPendingGesture();
        const old_idx = self.history_current;
        self.history_current += 1;
        self.applyHistoryState(&self.history.items[self.history_current], old_idx, self.history_current);
        self.publishHistoryRescan(old_idx);
        self.dirty = self.history_current != self.history_saved_index or self.plugin_dirty;
        return true;
    }

    /// 跳转到指定历史条目（历史栏点击）。返回是否成功。
    pub fn jumpHistory(self: *App, index: usize) bool {
        if (self.history.items.len == 0 or index >= self.history.items.len or index == self.history_current) return false;
        self.pinPendingGesture();
        const old_idx = self.history_current;
        self.history_current = index;
        self.applyHistoryState(&self.history.items[index], old_idx, index);
        self.publishHistoryRescan(old_idx);
        self.dirty = self.history_current != self.history_saved_index or self.plugin_dirty;
        return true;
    }

    /// 重置历史（启动/打开工程时）：以当前状态为基线（`label` 如“初始状态”）。
    pub fn resetHistory(self: *App, label: []const u8) void {
        for (self.history.items) |*st| self.freeHistoryState(st);
        self.history.clearRetainingCapacity();
        self.history_pending = null;
        self.clearGesture();
        if (self.captureHistory(label)) |st| {
            self.history.append(self.allocator, st) catch self.freeHistoryState(&st);
        } else |_| {}
        self.history_current = 0;
        self.history_saved_index = 0;
        self.dirty = false; // 重置 = 新基线（与派生公式一致，显式写出）
        self.plugin_dirty = false; // 新基线：插件状态亦视为已保存
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
        // 最小可用名 ≤ 数量+1（鸽笼原理）——不扫到上限（上限已放到十亿级）
        const bound: i32 = @intCast(self.pattern_items.items.len + 1);
        outer: while (n <= bound) : (n += 1) {
            const text = std.fmt.bufPrint(&buf, "样式 {d}", .{n}) catch return -1;
            for (self.pattern_items.items) |existing| {
                if (std.mem.eql(u8, existing, text)) continue :outer;
            }
            name_text = text;
            break;
        }
        if (name_text.len == 0) return -1; // 名字全被占用（与上限同构，走不到）
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

    // ── 轨道（播放列表的行；增删/重命名）──

    /// 保证 `pat_stats` 至少有 `n` 项并返回切片（已有项保留；新增项为零值）。
    /// 分配失败 → 返回现有长度（调用方按 `.len` 操作，安全）。
    pub const PatPreviewStat = struct { min_pitch: i32 = 127, max_pitch: i32 = 0, has_notes: bool = false };

    pub fn ensurePatStats(self: *App, n: usize) []PatPreviewStat {
        if (self.pat_stats.len < n) {
            const old_len = self.pat_stats.len;
            if (old_len == 0) {
                self.pat_stats = self.allocator.alloc(PatPreviewStat, n) catch return self.pat_stats;
            } else {
                self.pat_stats = self.allocator.realloc(self.pat_stats, n) catch return self.pat_stats;
            }
            @memset(self.pat_stats[old_len..], .{});
        }
        return self.pat_stats;
    }

    /// 释放预览统计缓冲（进程退出时调用）
    pub fn deinitPatStats(self: *App) void {
        if (self.pat_stats.len > 0) self.allocator.free(self.pat_stats);
        self.pat_stats = &.{};
    }

    /// 轨道行跨度（**推导**，非存储）：= max(`model.min_track_span`（最短行程 128 行），
    /// 内容下缘 + 1 + `model.track_headroom`）。与横向“内容右缘 + 3 小节留白（保底 4）”
    /// 完全对称——行空间无限向下延伸：往留白行放片段即自动生长（“添加轨道”动作不再需要）。
    /// 留白恒 ≥ `track_headroom`：max 选中本值时，最短行程比内容多出 ≥3 行。
    pub fn trackCount(self: *const App) i32 {
        var last: i32 = -1;
        for (self.clips.items) |c| {
            if (c.track > last) last = c.track;
        }
        return @max(model.min_track_span, last + 1 + model.track_headroom);
    }

    /// 自定义名数组的“密集长度”（最大命名行号 + 1；无命名单 = 0）——历史快照/存档用
    fn denseTrackNamesLen(self: *const App) usize {
        var max_i: i32 = -1;
        var it = self.track_names.keyIterator();
        while (it.next()) |k| {
            if (k.* > max_i) max_i = k.*;
        }
        return if (max_i < 0) 0 else @intCast(max_i + 1);
    }

    /// 清空轨道上的全部片段（原“删除轨道”；**行本身与名字保留**——行号是绝对坐标，
    /// 无序号重映射）。返回删除的片段数（0 = 本来就是空行）。
    /// 非空轨道的确认流程由调用方（右键菜单/确认框）把关。
    pub fn clearTrackData(self: *App, idx: usize) usize {
        const ti: i32 = @intCast(idx);
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.clips.items.len) {
            if (self.clips.items[i].track == ti) {
                _ = self.clips.swapRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (removed > 0) {
            // 跨度可能因此缩短 → 选择钳制
            if (self.sel.track >= self.trackCount()) self.sel.track = self.trackCount() - 1;
            self.dirty = true;
        }
        return removed;
    }

    /// 轨道显示名：有自定义名用之；否则合成 "Track N"（写入 `track_name_buf`——
    /// 返回值指向 App 内部缓冲，调用方须**立即**使用，不要跨调用留存）。
    pub fn trackName(self: *App, idx: usize) []const u8 {
        const key: i32 = std.math.cast(i32, idx) orelse return "";
        if (self.track_names.get(key)) |nm| return nm;
        return std.fmt.bufPrint(&self.track_name_buf, "Track {d}", .{key + 1}) catch "Track";
    }

    /// 样式占用（删除确认框文案用）：音符数 / 片段数
    pub fn patternUsage(self: *const App, idx: usize) struct { notes: usize, clips: usize } {
        const pi: i32 = @intCast(idx);
        var n_notes: usize = 0;
        for (self.notes.items) |nt| {
            if (nt.pattern == pi) n_notes += 1;
        }
        var n_clips: usize = 0;
        for (self.clips.items) |c| {
            if (c.pattern == pi) n_clips += 1;
        }
        return .{ .notes = n_notes, .clips = n_clips };
    }

    /// 轨道占用（删除确认框文案用）：片段数
    pub fn trackUsage(self: *const App, idx: usize) usize {
        const ti: i32 = @intCast(idx);
        var n: usize = 0;
        for (self.clips.items) |c| {
            if (c.track == ti) n += 1;
        }
        return n;
    }

    /// 以稀疏形式写入轨道自定义名（撤销/重做/加载工程用；**复制每一项**；
    /// 空串 = 未命名（跳过）；数组下标 = 行号）。写入前先清空现有名字。
    fn setTrackNames(self: *App, names: anytype) void {
        self.clearTrackNames();
        for (names, 0..) |nm, i| {
            if (nm.len == 0) continue;
            const copy = self.allocator.dupe(u8, nm) catch continue;
            self.track_names.put(self.allocator, @intCast(i), copy) catch {
                self.allocator.free(copy);
            };
        }
    }

    /// 清空全部轨道自定义名（新建工程/重置等）——之后全部显示合成默认名
    pub fn clearTrackNames(self: *App) void {
        var it = self.track_names.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.track_names.clearRetainingCapacity();
    }

    /// 轨道是否静音（稀疏集合查询；越界/未记录 → 未静音）
    pub fn trackMuted(self: *const App, idx: usize) bool {
        const key: i32 = std.math.cast(i32, idx) orelse return false;
        return self.track_muted.contains(key);
    }

    /// 设置/取消轨道静音（调用方负责 commitHistory；会置脏）
    pub fn setTrackMuted(self: *App, idx: usize, muted: bool) void {
        const key: i32 = std.math.cast(i32, idx) orelse return;
        if (muted) {
            self.track_muted.put(self.allocator, key, {}) catch {};
        } else {
            _ = self.track_muted.remove(key);
        }
        self.dirty = true;
        if (self.scheduler.muted == null) self.scheduler.muted = &self.track_muted;
        self.setToast(if (muted) "轨道已静音" else "已取消静音");
        // **播放中立即生效**（实测 bug：播放中点静音，该轨音符仍在响）——
        // 补 off@游标（只动这条轨）+ 编辑代递增作废未触发副本 + 重扫窗口（带新静音集）
        if (self.playing) {
            const cur = self.playback.cursorStep(self.sel.song_mode);
            sequencer.muteTrackLive(
                &self.scheduler,
                &self.sched_events,
                self.clips.items,
                self.notes.items,
                self.sel.song_mode,
                self.sel.pattern,
                key,
                cur,
                muted,
            );
            // 发布序：先安全界、后编辑代（同 rescanForPlaybackEdit）
            self.params.sched_rescan_from.store(self.scheduler.rescan_from, .monotonic);
            self.params.sched_edit_gen.store(self.scheduler.edit_gen, .monotonic);
        }
    }

    /// 以列表重建静音集合（历史/存档用；先清空）
    fn setTrackMutes(self: *App, list: []const i32) void {
        self.track_muted.clearRetainingCapacity();
        for (list) |k| self.track_muted.put(self.allocator, k, {}) catch {};
    }

    /// 清空全部静音（新建工程/重置）
    pub fn clearTrackMutes(self: *App) void {
        self.track_muted.clearRetainingCapacity();
    }

    /// 行**上移/下移**：与相邻行整体交换（片段 + 自定义名 + 静音 + 选择跟随）。
    /// **默认名不随行移动**——合成名按行号（位置）显示，永远是 "Track N"（用户拍板）。
    pub fn swapTrackRows(self: *App, a: usize, b: usize) void {
        if (a == b) return;
        const ai: i32 = @intCast(a);
        const bi: i32 = @intCast(b);
        for (self.clips.items) |*c| {
            if (c.track == ai) {
                c.track = bi;
            } else if (c.track == bi) {
                c.track = ai;
            }
        }
        // 自定义名交换（稀疏；所有权随值走）
        const na = self.track_names.fetchRemove(ai);
        const nb = self.track_names.fetchRemove(bi);
        if (na) |kv| self.track_names.put(self.allocator, bi, kv.value) catch self.allocator.free(kv.value);
        if (nb) |kv| self.track_names.put(self.allocator, ai, kv.value) catch self.allocator.free(kv.value);
        // 静音交换
        const ma_muted = self.track_muted.contains(ai);
        const mb = self.track_muted.contains(bi);
        if (mb) {
            self.track_muted.put(self.allocator, ai, {}) catch {};
        } else {
            _ = self.track_muted.remove(ai);
        }
        if (ma_muted) {
            self.track_muted.put(self.allocator, bi, {}) catch {};
        } else {
            _ = self.track_muted.remove(bi);
        }
        // 选择跟随被移动的行
        if (self.sel.track == ai) {
            self.sel.track = bi;
        } else if (self.sel.track == bi) {
            self.sel.track = ai;
        }
        self.dirty = true;
    }

    /// 行**删除**（**下方整体上移**）：片段/自定义名/静音同步前移；默认名随位置自动。
    pub fn removeTrackRow(self: *App, idx: usize) void {
        const ti: i32 = @intCast(idx);
        var i: usize = 0;
        while (i < self.clips.items.len) {
            const c = &self.clips.items[i];
            if (c.track == ti) {
                _ = self.clips.swapRemove(i);
            } else {
                if (c.track > ti) c.track -= 1;
                i += 1;
            }
        }
        // 自定义名：收集 → 清空 → 按新键回填（被删行的名字释放）
        const KV = struct { k: i32, v: []u8 };
        var keep: std.ArrayListUnmanaged(KV) = .empty;
        defer keep.deinit(self.allocator);
        var itn = self.track_names.iterator();
        while (itn.next()) |e| {
            const k = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (k == ti) {
                self.allocator.free(v);
                continue;
            }
            keep.append(self.allocator, .{ .k = if (k > ti) k - 1 else k, .v = v }) catch {
                self.allocator.free(v);
            };
        }
        self.track_names.clearRetainingCapacity();
        for (keep.items) |kv| self.track_names.put(self.allocator, kv.k, kv.v) catch self.allocator.free(kv.v);
        // 静音：同理
        var keepm: std.ArrayListUnmanaged(i32) = .empty;
        defer keepm.deinit(self.allocator);
        var itm = self.track_muted.keyIterator();
        while (itm.next()) |kp| {
            if (kp.* == ti) continue;
            keepm.append(self.allocator, if (kp.* > ti) kp.* - 1 else kp.*) catch {};
        }
        self.track_muted.clearRetainingCapacity();
        for (keepm.items) |k| self.track_muted.put(self.allocator, k, {}) catch {};
        if (self.sel.track > ti) self.sel.track -= 1;
        if (self.sel.track >= self.trackCount()) self.sel.track = self.trackCount() - 1;
        self.dirty = true;
    }

    /// 释放轨道名字表（进程退出时调用）
    pub fn deinitTracks(self: *App) void {
        self.clearTrackNames();
        self.track_names.deinit(self.allocator);
        self.track_muted.deinit(self.allocator);
    }

    /// 打开轨道重命名输入框（位置由调用方给；复用文本输入基建——支持中文 IME）
    pub fn beginRenameTrack(self: *App, idx: usize, x: i32, y: i32) void {
        if (idx >= @as(usize, @intCast(self.playlist.view_rows))) return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .track;
        ti.index = idx;
        ti.x = x;
        ti.y = y;
        // 预填 = **仅自定义名**；未命名（默认 Track N）→ 输入框留空（用户拍板）
        const name = self.track_names.get(std.math.cast(i32, idx) orelse 0) orelse "";
        const n = @min(name.len, ti.buf.len);
        @memcpy(ti.buf[0..n], name[0..n]);
        ti.len = n;
        ti.cursor = n;
        ti.sel_anchor = null;
        ti.drag_active = false;
        ti.view_off = 0;
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
        self.settings_dirty = true; // “上次工程”落盘
    }

    /// 清除工程路径（新建空工程：标题回到“未命名”）
    pub fn clearProjectPath(self: *App) void {
        if (self.project_path) |old| self.allocator.free(old);
        self.project_path = null;
        self.settings_dirty = true; // “上次工程”落盘
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
            self.file_menu_open or self.panels.ctx_pattern != null or self.panels.ctx_audio_style != null or
            self.panels.ctx_track != null or
            self.preset_browser.open or
            self.mixer_win.ctx_effect != null or self.mixer_win.ctx_channel != null or self.mixer_win.ctx_pan != null;
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
            clips[i] = .{ .track = c.track, .start = c.start, .len = c.len, .pattern = c.pattern, .offset = c.offset, .audio_style = c.audio_style, .trim_start = c.trim_start, .trim_len = c.trim_len };
        }
        const notes = try alloc.alloc(persist.SavedNote, self.notes.items.len);
        errdefer alloc.free(notes);
        for (self.notes.items, 0..) |n, i| {
            notes[i] = .{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument, .velocity = n.velocity, .pan = n.pan };
        }
        const insts = try alloc.alloc(persist.SavedInstrument, self.instruments.items.len);
        var ni: usize = 0;
        errdefer {
            for (insts[0..ni]) |*si| self.freeSavedInstrument(si, false);
            alloc.free(insts);
        }
        for (self.instruments.items, 0..) |*inst, i| {
            insts[i] = try self.exportInstrument(inst, false);
            ni += 1;
        }
        // 调音台通道（增益/声像/静音/效果链）——共用 `exportMixerChannels`
        const mix = try self.exportMixerChannels(alloc, true, false);
        // 音频样式（相对路径——工程文件夹便携；未在基准目录下 → 保留绝对）
        const astyles = try self.exportAudioStyles(alloc, true);
        errdefer self.freeSavedAudioStyles(astyles);
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
        // 轨道自定义名（**v4 稀疏对**：rows + names 平行数组，只含命名行；升序）——
        // 行跨度与默认名（Track N）都是位置推导，不入档；旧档密集数组由加载侧垫片兼容
        const n_named: usize = self.track_names.count();
        const trk_rows = try alloc.alloc(i32, n_named);
        errdefer alloc.free(trk_rows);
        const trk_names = try alloc.alloc([]const u8, n_named);
        var tn: usize = 0;
        errdefer {
            for (trk_names[0..tn]) |nm| alloc.free(nm);
            alloc.free(trk_names);
        }
        {
            var mit = self.track_names.iterator();
            while (mit.next()) |e| {
                trk_rows[tn] = e.key_ptr.*;
                trk_names[tn] = try alloc.dupe(u8, e.value_ptr.*);
                tn += 1;
            }
            // 按行号排序（平行数组同步交换；命名行数很小，插入排序足够）
            var si: usize = 1;
            while (si < tn) : (si += 1) {
                const rk = trk_rows[si];
                const rv = trk_names[si];
                var sj: usize = si;
                while (sj > 0 and trk_rows[sj - 1] > rk) : (sj -= 1) {
                    trk_rows[sj] = trk_rows[sj - 1];
                    trk_names[sj] = trk_names[sj - 1];
                }
                trk_rows[sj] = rk;
                trk_names[sj] = rv;
            }
        }
        // 静音轨道（排序行号列表）
        const nmute: usize = self.track_muted.count();
        const muted_list = try alloc.alloc(i32, nmute);
        errdefer alloc.free(muted_list);
        {
            var mi: usize = 0;
            var mit = self.track_muted.keyIterator();
            while (mit.next()) |k| : (mi += 1) muted_list[mi] = k.*;
            std.mem.sort(i32, muted_list, {}, std.sort.asc(i32));
        }
        return .{
            .bpm = self.bpm,
            .volume = self.volume, // 主音量（持久化——重开工程恢复）
            .time_num = self.time_num,
            .time_den = self.time_den,
            .steps_per_bar = self.steps_per_bar,
            .pattern_count = self.patternCount(),
            .pattern_names = pat_names,
            .track_names = trk_names,
            .track_name_rows = trk_rows,
            .track_muted = muted_list,
            .clips = clips,
            .notes = notes,
            .instruments = insts,
            .mixer = mix,
            .audio_styles = astyles,
        };
    }

    /// 释放 `exportProject` 返回的存档（含内部字符串）
    /// 槽内插件状态 → base64 文本（优先活实例；无实例时用 pending；空 → ""）
    fn captureSlotStateB64(allocator: std.mem.Allocator, es: *const EffectSlot, comp: bool) ![]const u8 {
        if (es.plugin) |pl| {
            const blobs = pl.captureState(allocator);
            defer blobs.deinit(allocator);
            return b64Encode(allocator, if (comp) blobs.comp else blobs.ctrl);
        }
        const b = if (comp) es.pending_state else es.pending_state_ctrl;
        return b64Encode(allocator, if (b) |x| x else &.{});
    }

    /// 实时乐器音色（base64）是否与快照中的一致（commitHistory 去重用）
    fn instrumentStateMatchesLive(self: *const App, inst: *const model.Instrument, top_comp: []const u8, top_ctrl: []const u8) bool {
        const live_c = if (inst.plugin) |pl|
            (capturePluginStateB64(self.allocator, pl, true) catch return false)
        else
            (b64Encode(self.allocator, if (inst.pending_state) |x| x else &.{}) catch return false);
        defer if (live_c.len > 0) self.allocator.free(live_c);
        const live_k = if (inst.plugin) |pl|
            (capturePluginStateB64(self.allocator, pl, false) catch return false)
        else
            (b64Encode(self.allocator, if (inst.pending_state_ctrl) |x| x else &.{}) catch return false);
        defer if (live_k.len > 0) self.allocator.free(live_k);
        return std.mem.eql(u8, live_c, top_comp) and std.mem.eql(u8, live_k, top_ctrl);
    }

    /// 实时**鼓组层**插件状态（base64）是否与快照一致（commitHistory 去重用）
    fn layerStateMatchesLive(self: *const App, ly: *const model.DrumLayer, top_comp: []const u8, top_ctrl: []const u8) bool {
        const live_c = if (ly.plugin) |pl|
            (capturePluginStateB64(self.allocator, pl, true) catch return false)
        else
            (b64Encode(self.allocator, if (ly.pending_state) |x| x else &.{}) catch return false);
        defer if (live_c.len > 0) self.allocator.free(live_c);
        const live_k = if (ly.plugin) |pl|
            (capturePluginStateB64(self.allocator, pl, false) catch return false)
        else
            (b64Encode(self.allocator, if (ly.pending_state_ctrl) |x| x else &.{}) catch return false);
        defer if (live_k.len > 0) self.allocator.free(live_k);
        return std.mem.eql(u8, live_c, top_comp) and std.mem.eql(u8, live_k, top_ctrl);
    }

    /// 实时插件状态（base64）是否与快照中的一致（commitHistory 去重用；含结构改动）
    fn pluginStateMatchesLive(self: *const App, es: *const EffectSlot, top_comp: []const u8, top_ctrl: []const u8) bool {
        const live_c = captureSlotStateB64(self.allocator, es, true) catch return false;
        defer if (live_c.len > 0) self.allocator.free(live_c);
        const live_k = captureSlotStateB64(self.allocator, es, false) catch return false;
        defer if (live_k.len > 0) self.allocator.free(live_k);
        return std.mem.eql(u8, live_c, top_comp) and std.mem.eql(u8, live_k, top_ctrl);
    }

    /// 字节 → base64 文本（空输入 → 空串，**不分配**；调用方释放）
    fn b64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        if (bytes.len == 0) return "";
        const size = std.base64.standard.Encoder.calcSize(bytes.len);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        _ = std.base64.standard.Encoder.encode(buf, bytes);
        return buf;
    }

    /// base64 文本按归属收编（pooled → 池共享；OOM/碰撞 → 释放并返回 ""）
    fn adoptStateB64(self: *App, b64: []const u8, pooled: bool) []const u8 {
        if (!pooled or b64.len == 0) return b64;
        return self.state_pool.intern(self.allocator, b64) orelse blk: {
            self.allocator.free(b64);
            break :blk "";
        };
    }

    /// 插件实例状态 → base64（comp=true 组件侧；空 = 无）。调用方释放。
    fn capturePluginStateB64(allocator: std.mem.Allocator, pl: *vst_host.Plugin, comp: bool) ![]const u8 {
        const blobs = pl.captureState(allocator);
        defer blobs.deinit(allocator);
        return b64Encode(allocator, if (comp) blobs.comp else blobs.ctrl);
    }

    /// base64 文本 → 字节（空/非法 → null；调用方释放）
    fn b64Decode(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
        if (text.len == 0) return null;
        const size = std.base64.standard.Decoder.calcSizeForSlice(text) catch return null;
        const buf = allocator.alloc(u8, size) catch return null;
        std.base64.standard.Decoder.decode(buf, text) catch {
            allocator.free(buf);
            return null;
        };
        return buf;
    }

    /// 释放存档切片里的调音台通道（含每效果的 bands 子切片）——多处共用
    fn freeSavedMixerChannels(self: *App, mixer: []const persist.SavedMixerChannel, pooled: bool) void {
        for (mixer) |sm| {
            for (sm.effects[0..@min(sm.effects.len, sm.effect_count)]) |se| {
                if (se.bands.len > 0) self.allocator.free(se.bands);
                if (se.plugin_path.len > 0) self.allocator.free(se.plugin_path);
                if (se.plugin_cid.len > 0) self.allocator.free(se.plugin_cid);
                // 插件状态：历史快照走池引用计数；工程导出为独占块（直接 free）
                if (se.plugin_state.len > 0) {
                    if (pooled) self.state_pool.release(self.allocator, se.plugin_state) else self.allocator.free(se.plugin_state);
                }
                if (se.plugin_state_ctrl.len > 0) {
                    if (pooled) self.state_pool.release(self.allocator, se.plugin_state_ctrl) else self.allocator.free(se.plugin_state_ctrl);
                }
            }
            if (sm.name.len > 0) self.allocator.free(sm.name);
            if (sm.effects.len > 0) self.allocator.free(sm.effects);
        }
    }

    pub fn freeProject(self: *App, p: persist.Project) void {
        for (p.instruments) |*si| self.freeSavedInstrument(si, false);
        self.allocator.free(p.clips);
        self.allocator.free(p.notes);
        self.allocator.free(p.instruments);
        for (p.pattern_names) |nm| self.allocator.free(nm);
        self.allocator.free(p.pattern_names);
        for (p.track_names) |nm| self.allocator.free(nm);
        self.allocator.free(p.track_names);
        self.allocator.free(p.track_name_rows);
        self.allocator.free(p.track_muted);
        if (p.mixer.len > 0) {
            self.freeSavedMixerChannels(p.mixer, false);
            self.allocator.free(p.mixer);
        }
        // 注：**不要**加 `if (len > 0)`——`alloc(T, 0)` 也必须配对 free（同 `freeHistoryState`）
        const styles: []persist.SavedAudioStyle = @constCast(p.audio_styles);
        self.freeSavedAudioStyles(styles);
    }

    /// 用存档替换当前工程内容（先清空旧数据）——**同步一条到底**（测试/内部用）。
    /// 界面里走 `beginProjectLoad()` + 每帧 `stepProjectLoad()`（同一套代码分段执行）。
    pub fn importProject(self: *App, p: persist.Project) void {
        self.importProjectPrepare(p);
        for (p.audio_styles) |s| self.importAudioStyleOne(s);
        self.importProjectBody(p);
    }

    /// 阶段 1：清场 + 容量（便宜，毫秒级）
    fn importProjectPrepare(self: *App, p: persist.Project) void {
        // 停止播放（避免调度器引用已被清空的数据）
        self.stopPlayback();
        // 旧工程的音频样式/资产全部作废（否则旧资产池只增不减，白吃内存）
        self.clearAudioEverything();
        // 容量先行（存档规模可能超过当前容量；设备自动暂停/恢复）
        self.ensureAudioCapacity(p.instruments.len, p.mixer.len, savedMaxChainSlots(p.mixer));
        self.kit_reset = true;
        self.kit_gc_pending = true; // 乐器将被重建：鼓组池帧末全量重置
        self.shrink_pending = true; // 帧末回收多余容量（若新工程更小）

        // 清空旧数据
        self.clips.clearRetainingCapacity();
        self.notes.clearRetainingCapacity();
        // 乐器：逐个删除（复用删除逻辑，原子字段/退役列表正确处理）
        while (self.instruments.items.len > 0) {
            self.removeInstrument(self.instruments.items.len - 1);
        }
    }

    /// 阶段 2：**单个**音频样式（含同步解码——这是加载最慢的部分；分帧时一次只做一个）
    fn importAudioStyleOne(self: *App, s: persist.SavedAudioStyle) void {
        var path_buf: [1024]u8 = undefined;
        const resolved = self.resolveAudioPath(s.path, &path_buf) orelse s.path;
        const nd = self.allocator.dupe(u8, s.name) catch return;
        const pd = self.allocator.dupe(u8, resolved) catch {
            self.allocator.free(nd);
            return;
        };
        const ai = self.loadAudioAsset(resolved) orelse -1;
        self.audio_styles.append(self.allocator, .{
            .name = nd,
            .path = pd,
            .asset = ai,
            .channel = s.channel,
            .gain = s.gain,
            .speed = s.speed,
        }) catch {
            self.allocator.free(nd);
            self.allocator.free(pd);
        };
    }

    /// 阶段 3：其余内宇（片段/音符/乐器/全局设置；毫秒级）
    fn importProjectBody(self: *App, p: persist.Project) void {
        for (p.clips) |c| {
            self.addClip(.{ .track = c.track, .start = c.start, .len = c.len, .pattern = c.pattern, .offset = c.offset, .audio_style = c.audio_style, .trim_start = c.trim_start, .trim_len = c.trim_len });
        }
        // 容错：片段引用了不存在的音频样式（手工改档/旧 bug）→ 丢弃，避免“隐形空片段”
        {
            var bad: usize = 0;
            const n_styles: i32 = @intCast(self.audio_styles.items.len);
            var ci: usize = 0;
            while (ci < self.clips.items.len) {
                const c = &self.clips.items[ci];
                if (c.isAudio() and (c.audio_style < 0 or c.audio_style >= n_styles)) {
                    _ = self.clips.swapRemove(ci);
                    bad += 1;
                    continue;
                }
                ci += 1;
            }
            if (bad > 0) self.setToastWith("有 {d} 个音频片段引用了不存在的样式，已丢弃", .{bad});
        }
        for (p.notes) |n| {
            self.addNote(.{ .step = n.step, .len = n.len, .pitch = n.pitch, .pattern = n.pattern, .instrument = n.instrument, .velocity = n.velocity, .pan = n.pan });
        }
        for (p.instruments) |*inst| {
            const idx = self.addInstrument(inst.name);
            if (idx < 0) continue;
            const target = &self.instruments.items[@intCast(idx)];
            self.applySavedInstrument(inst, target, .full, 0, 0);
        }

        // 全局设置
        self.bpm = p.bpm;
        self.volume = p.volume; // 主音量（缺字段的旧存档 → 默认值）
        self.params.volume.store(self.volume, .monotonic); // 立即同步到音频线程
        self.time_num = p.time_num;
        self.time_den = p.time_den;
        self.steps_per_bar = p.steps_per_bar;
        // 调音台通道：**动态数量**（旧存档无此字段 → 保持默认 2 个）——共用 `importMixerChannels`
        self.importMixerChannels(p.mixer, null, 0, 0);
        // 样式列表：优先按名字恢复（含自定义名）；旧存档无名字 → 按数量重建默认名
        if (p.pattern_names.len > 0) {
            self.restorePatternNames(p.pattern_names);
        } else {
            self.resetPatterns(if (p.pattern_count > 0) p.pattern_count else model.default_pattern_count);
        }
        // 轨道自定义名（稀疏）：旧存档的数组（当年含默认名）逐项保留为空串以外的条目；
        // 行跨度由片段推导——不再需要“补默认数量/覆盖最右片段”的逻辑
        // 轨道自定义名：**v4 稀疏对**（rows + names 平行数组）；行跨度由片段推导。
        // 旧档（v3 及以前）为密集数组——垫片：无 rows 时按“跳过空串”派生行号
        if (p.track_name_rows.len > 0 and p.track_name_rows.len == p.track_names.len) {
            self.clearTrackNames();
            var ti: usize = 0;
            while (ti < p.track_name_rows.len) : (ti += 1) {
                const row = p.track_name_rows[ti];
                if (row < 0) continue;
                const copy = self.allocator.dupe(u8, p.track_names[ti]) catch continue;
                self.track_names.put(self.allocator, row, copy) catch self.allocator.free(copy);
            }
        } else {
            self.setTrackNames(p.track_names); // 旧档垫片（setTrackNames 本就跳过空串）
        }
        self.setTrackMutes(p.track_muted);

        // 选择/clamp 回有效范围
        self.sel.pattern = 0;
        self.sel.track = 0;
        self.playlist.scroll = 0; // 悬空/滚动位置不带入新工程
        self.sel.instrument = if (self.instruments.items.len > 0) 0 else -1;
        self.playback.song_step = 0;
        self.playback.piano_step = 0;
        self.playback.start_step = 0;
        self.piano.pattern = null;
        // 打开工程后回到 PAT（默认工作模式；点播放列表标尺会自动切 SONG）
        self.sel.song_mode = true; // 打开工程后默认 SONG（用户拍板）
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

    /// 叠放轮换（用户拍板）：把片段沉到**同轨道同左端点**组的最底层（数组序最前）。
    /// 返回沉降后的新下标（已在底层则原样返回）。不单独提交历史
    /// （层级变更随下一次提交/拖动折叠）。
    pub fn sinkClipToTieBottom(self: *App, ci: usize) usize {
        if (ci >= self.clips.items.len) return ci;
        const c = self.clips.items[ci];
        var min_i: usize = ci;
        for (self.clips.items, 0..) |o, oi| {
            if (oi == ci) continue;
            if (o.track == c.track and o.start == c.start and oi < min_i) min_i = oi;
        }
        if (min_i == ci) return ci; // 已在最底
        _ = self.clips.orderedRemove(ci);
        const ins = if (min_i > ci) min_i - 1 else min_i;
        self.clips.insert(self.allocator, ins, c) catch {
            // 插入失败（OOM）：补回尾部（保数据，层级不完美）
            self.clips.append(self.allocator, c) catch {};
            return self.clips.items.len -| 1;
        };
        self.dirty = true;
        return ins;
    }

    /// 叠放轮换（音符版，与片段同规则）：沉到**同样式同乐器同音高同左端点**组的最底。
    /// 返回新下标（已在底层则原样）。不单独提交历史。
    pub fn sinkNoteToTieBottom(self: *App, ci: usize) usize {
        if (ci >= self.notes.items.len) return ci;
        const n = self.notes.items[ci];
        var min_i: usize = ci;
        for (self.notes.items, 0..) |o, oi| {
            if (oi == ci) continue;
            if (o.pattern == n.pattern and o.instrument == n.instrument and o.pitch == n.pitch and o.step == n.step and oi < min_i) min_i = oi;
        }
        if (min_i == ci) return ci; // 已在最底
        _ = self.notes.orderedRemove(ci);
        const ins = if (min_i > ci) min_i - 1 else min_i;
        self.notes.insert(self.allocator, ins, n) catch {
            self.notes.append(self.allocator, n) catch {};
            return self.notes.items.len -| 1;
        };
        self.dirty = true;
        return ins;
    }

    /// 导入 MIDI：每个用到的通道 → 一个新乐器（默认减法合成器参数）；
    /// 音符全部写进**一个新建样式**（不自动放片段——由用户自己放置）。
    /// 失败返回错误；成功返回统计信息。
    pub fn importMidi(self: *App, parsed: *const midi.Parsed) !MidiImportResult {
        // 1) 收集用到的通道（升序稳定）
        var ch_used: [16]bool = @splat(false);
        for (parsed.notes) |n| ch_used[n.channel & 0x0F] = true;

        // 2) 新建样式（达到上限 → 报错，不做半途导入）
        const new_pat = self.addPattern();
        if (new_pat < 0) return error.TooManyPatterns;

        // 3) 通道 → 乐器（顺序建立，保持通道升序）
        var ch_to_inst: [16]i32 = @splat(-1);
        var inst_count: usize = 0;
        for (ch_used, 0..) |u, ch| {
            if (!u) continue;
            const idx = self.addInstrument("MIDI 通道");
            if (idx < 0) continue; // 乐器已达上限：该通道音符将被跳过
            const inst = &self.instruments.items[@intCast(idx)];
            inst.midi_channel = @intCast(ch); // 记住来源通道
            // MIDI 声像是**通道级**的（无音符级声像）→ 映射为乐器的静态声像
            // （取该通道首个 CC10；动态曲线以后再做）
            inst.pan = @as(f32, @floatFromInt(parsed.channel_pan[ch])) / 127.0;
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
                // 声像居中（默认 64）：MIDI 音符不带声像；Sawdust 的音符级声像
                // 以乐器声像为基准叠加（导入时不快照 CC10——那是通道级的）
            });
            imported += 1;
        }

        // **纯追加，不干扰视图**（用户拍板：自动跳到新样式/新乐器迷惑性太强——
        // 导入只追加，样式号在 toast 里告知，用户自行前往）。
        return .{ .pattern = new_pat, .notes = imported, .instruments = inst_count, .skipped = skipped };
    }

    /// 导出用：每 MIDI 通道声像（0-127；= 该通道**首个**乐器的声像）。
    /// 通道规则与 `exportMidiNotes` 一致（优先来源通道 `midi_channel`，否则号 mod 16）；
    /// 音符级声像不导出（MIDI 只有通道级声像）——见 `midi.ExportSong.channel_pan`。
    pub fn exportChannelPans(self: *const App) [16]u8 {
        var out: [16]u8 = @splat(64);
        var set: [16]bool = @splat(false);
        for (self.instruments.items, 0..) |inst, i| {
            // 无来源通道且乐器号 ≥ 16 → 不导出（与 `exportMidiNotes` 同规则）
            if (inst.midi_channel < 0 and i >= 16) continue;
            const ch: usize = if (inst.midi_channel >= 0)
                @intCast(@mod(inst.midi_channel, 16))
            else
                @mod(i, 16);
            if (set[ch]) continue;
            set[ch] = true;
            out[ch] = @intFromFloat(@round(std.math.clamp(inst.pan, 0.0, 1.0) * 127.0));
        }
        return out;
    }

    /// 导出 MIDI：把**全部片段**里的音符按全局时间展开（同音符被多个片段引用
    /// 会导出多次——与播放听到的一致）；乐器号 mod 16 → 通道。
    /// 返回的切片归调用方释放（`allocator.free`）。
    pub fn exportMidiNotes(self: *App, allocator: std.mem.Allocator) ![]midi.ExportNote {
        var out: std.ArrayListUnmanaged(midi.ExportNote) = .empty;
        errdefer out.deinit(allocator);

        for (self.clips.items) |clip| {
            for (self.notes.items) |n| {
                if (n.pattern != clip.pattern) continue;
                if (n.pitch < 0 or n.pitch > 127 or n.len <= 0) continue;
                if (n.instrument < 0) continue;
                // 通道：优先乐器记录的来源通道（MIDI 导入往返稳定）；否则乐器号 = 通道。
                // **无来源通道且乐器号 ≥ 16 → 不导出**（MIDI 只有 16 通道；此前用
                // 乐器号 mod 16 折回，会挤占已有通道——用户拍板偷懒：宁缺毋挤）
                const ii = @as(usize, @intCast(n.instrument));
                var ch: i32 = undefined;
                if (ii < self.instruments.items.len) {
                    const mc = self.instruments.items[ii].midi_channel;
                    if (mc >= 0) {
                        ch = @mod(mc, 16);
                    } else if (ii < 16) {
                        ch = @intCast(ii);
                    } else {
                        continue;
                    }
                } else {
                    continue; // 悬空引用（理论不可达）：不导出
                }
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

    /// SONG：**最后一个片段的右缘**（`start + len` 最大值）——不论片段内有无音符；
    /// 无片段 → 0。播放回跳用它：片段空着也应播满整段。
    pub fn clipsEndStep(self: *const App) i32 {
        var last: i32 = 0;
        for (self.clips.items) |clip| {
            last = @max(last, clip.start + clip.len);
        }
        return last;
    }

    /// 导出整曲为 **WAV（24-bit PCM）**——同步整跑（测试/无进度窗场景）；
    /// 主程序走“分块状态机”：`exportWavBegin` → 每帧 `exportWavFrame`，对话框驱动进度/取消。
    pub fn exportSongWav(self: *App, io: std.Io, path: []const u8) !void {
        try self.exportWavBegin(io, path);
        while (self.export_wav != null) {
            self.exportWavRun(io, std.math.maxInt(i64)) catch |e| {
                self.exportWavFail(io, e);
                return e;
            };
        }
    }

    /// 开始导出：进入状态机（快照 → 暂停设备 → 传输归零 → 打开 WAV）。
    /// 之后由主循环每帧 `exportWavFrame` 分块推进；完成/取消/失败均自动收尾。
    pub fn exportWavBegin(self: *App, io: std.Io, path: []const u8) !void {
        if (self.export_wav != null) return error.ExportInProgress;
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        // 插件状态快照（乐器 + 混音台效果链）——导出会推进其 DSP 内部状态；
        // 结束后回写（分配失败的那一个不入快照：该插件保持导出后的状态，可接受）
        var states: std.ArrayListUnmanaged(PlStateSnap) = .empty;
        errdefer {
            for (states.items) |s| s.blobs.deinit(self.allocator);
            states.deinit(self.allocator);
        }
        for (self.instruments.items) |*inst| {
            if (inst.plugin) |pl| {
                states.append(self.allocator, .{ .pl = pl, .blobs = pl.captureState(self.allocator) }) catch {};
            }
        }
        for (self.mixer_channels_state.items) |*mc| {
            for (mc.effects.items) |*es| {
                if (es.kind == .plugin) {
                    if (es.plugin) |pl| {
                        states.append(self.allocator, .{ .pl = pl, .blobs = pl.captureState(self.allocator) }) catch {};
                    }
                }
            }
        }

        // ── 快照（结束时恢复；全部为无失败读）──
        const snap_song = self.playback.song_step;
        const snap_piano = self.playback.piano_step;
        const snap_start_step = self.playback.start_step;
        const snap_start_frame = self.playback.start_frame;
        const snap_frames = self.params.frames_played.load(.monotonic);
        const snap_song_mode = self.sel.song_mode;

        const sr: u64 = self.params.sample_rate;
        const bpm: u64 = @intCast(std.math.clamp(self.bpm, 20, 999));
        const spb_per_beat: u64 = @intCast(model.stepsPerBeat(self.time_den));
        const step_frames: u64 = @max(1, sr * 60 / (bpm * spb_per_beat));
        const end_step: u64 = @intCast(@max(0, self.clipsEndStep()));
        const total_frames: u64 = end_step * step_frames + sr * export_tail_sec;

        // 写盘器先建：失败时设备/传输都还没动，直接返回
        const writer = try wav.Writer.create(io, path_copy, @intCast(sr), 2);

        // ── 停播 + 暂停设备 + 离线传输（此后无回退错误）──
        if (self.playing) self.stopPlayback();
        self.engine.pauseDevice();
        self.sel.song_mode = true;
        self.playback.start_frame = 0;
        self.playback.start_step = 0;
        self.playback.song_step = 0;
        self.params.start_frame.store(0, .monotonic);
        self.params.start_step.store(0, .monotonic);
        self.params.frames_played.store(0, .monotonic);
        self.params.bpm.store(@intCast(bpm), .monotonic);
        self.params.steps_per_beat.store(@intCast(spb_per_beat), .monotonic);
        self.markGenSoft(false); // 硬切换（导出起播）：照旧释放（无残留声部）
        sequencer.reset(&self.scheduler, &self.sched_events, self.clips.items, self.notes.items, true, self.sel.pattern, 0);
        self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        self.params.playing.store(true, .monotonic);

        self.export_wav = .{
            .path = path_copy,
            .writer = writer,
            .states = states,
            .snap_song = snap_song,
            .snap_piano = snap_piano,
            .snap_start_step = snap_start_step,
            .snap_start_frame = snap_start_frame,
            .snap_frames = snap_frames,
            .snap_song_mode = snap_song_mode,
            .step_frames = step_frames,
            .total_frames = total_frames,
            .done = 0,
            .dbg0 = self.engine.dbg_dispatched,
            .log_buf = .empty,
            .t0_ns = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds),
        };
        self.export_win = .{}; // 进度窗复位（首帧居中）
        // 导出日志头（完成时写入 `<wav>.log`——现场排障用）
        if (self.export_wav) |*ew| {
            var hb: [256]u8 = undefined;
            const h = std.fmt.bufPrint(&hb, "begin gen={d} edit_gen={d} start_step={d} start_frame={d} bpm={d} spb={d} step_frames={d} total={d} sr={d}", .{
                self.scheduler.gen,                      self.scheduler.edit_gen,
                self.params.start_step.load(.monotonic), self.params.start_frame.load(.monotonic),
                self.params.bpm.load(.monotonic),        self.params.steps_per_beat.load(.monotonic),
                step_frames,                             total_frames,
                sr,
            }) catch "";
            ew.log_buf.appendSlice(self.allocator, h) catch {};
            ew.log_buf.appendSlice(self.allocator, "\n") catch {};
        }
    }

    /// 主循环每帧推进（时间预算内分块渲染；完成后自动收尾）。
    /// 预算 30ms：导出期间 UI 约 30fps，但渲染吞吐接近纯 CPU 极限
    /// （商用 DAW 的弹速即来自“跑满 CPU”；预算过小会把快插件也节流成 1–2 块/帧）。
    pub fn exportWavFrame(self: *App, io: std.Io) void {
        self.exportWavRun(io, 30_000_000) catch |e| self.exportWavFail(io, e);
    }

    /// 取消导出（对话框按钮 / Esc 置位；下一帧步进时清理）。
    pub fn exportWavCancel(self: *App) void {
        if (self.export_wav) |*ew| ew.cancel_req = true;
    }

    /// 分块渲染（`budget_ns` 内尽量多跑；maxInt = 一次跑完——同步模式）。
    /// 完成后自动收尾（状态机消费：返回后 `export_wav` 已清理）。
    fn exportWavRun(self: *App, io: std.Io, budget_ns: i64) !void {
        const ew = if (self.export_wav) |*e| e else return;
        if (ew.cancel_req) return self.exportWavCanceled(io);
        const t0: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        var obuf: [1024 * 2]f32 = undefined;
        while (ew.done < ew.total_frames) {
            if (ew.cancel_req) return self.exportWavCanceled(io);
            // 调度 lookahead：与主循环同款（提前 4 小节）
            const cur: i32 = @intCast(ew.done / ew.step_frames);
            const horizon = cur + self.steps_per_bar * 4;
            if (horizon > self.scheduler.scheduled_upto) {
                sequencer.scheduleRange(&self.scheduler, &self.sched_events, self.clips.items, self.notes.items, true, self.sel.pattern, self.scheduler.scheduled_upto, horizon);
            }
            const n: u32 = @intCast(@min(@as(u64, obuf.len / 2), ew.total_frames - ew.done));
            audio.renderBlock(&self.engine, &self.params, &obuf, n, @floatFromInt(self.params.sample_rate));
            try ew.writer.writeFrames(obuf[0 .. n * 2]);
            ew.done += n;
            ew.blocks += 1;
            if (ew.blocks % 32 == 0) {
                var lb: [192]u8 = undefined;
                const ls = std.fmt.bufPrint(&lb, "blk={d} fp={d} stash={d} disp={d} peak={d:.3} pl={}", .{
                    ew.blocks,                             self.params.frames_played.load(.monotonic),
                    self.engine.stash_n,                   self.engine.dbg_dispatched -| ew.dbg0,
                    self.params.out_peak.load(.monotonic), self.params.playing.load(.monotonic),
                }) catch "";
                ew.log_buf.appendSlice(self.allocator, ls) catch {};
                ew.log_buf.appendSlice(self.allocator, "\n") catch {};
            }
            if (budget_ns != std.math.maxInt(i64)) {
                const now: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
                if (now - t0 >= budget_ns) return; // 本帧预算用尽（下一帧继续）
            }
        }
        try ew.writer.finish();
        self.exportWavDone(io);
    }

    /// 完成：toast → 恢复快照/设备 → 释放（状态机消费）。
    fn exportWavDone(self: *App, io: std.Io) void {
        const ev_n = self.engine.dbg_dispatched -| self.export_wav.?.dbg0;
        // 落盘导出日志（<wav>.log——现场排障用）
        if (self.export_wav) |*ew| {
            var pb: [1080]u8 = undefined;
            if (std.fmt.bufPrint(&pb, "{s}.log", .{ew.path}) catch null) |lp| {
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = ew.log_buf.items }) catch {};
            }
        }
        self.setToastWith("已导出（块 {d} · 事件 {d}）：{s}", .{ self.export_wav.?.blocks, ev_n, self.export_wav.?.path });
        self.exportWavFree();
    }

    /// 用户取消：丢弃半成品（删文件）→ 恢复快照/设备 → 释放。
    fn exportWavCanceled(self: *App, io: std.Io) void {
        self.export_wav.?.writer.abandon();
        std.Io.Dir.cwd().deleteFile(io, self.export_wav.?.path) catch {};
        self.setToast("已取消导出");
        self.exportWavRestore();
        self.exportWavFree();
    }

    /// 失败：丢半成品 → 恢复快照/设备 → 释放（toast 报错）。
    fn exportWavFail(self: *App, io: std.Io, err: anyerror) void {
        if (self.export_wav == null) return;
        self.export_wav.?.writer.abandon();
        std.Io.Dir.cwd().deleteFile(io, self.export_wav.?.path) catch {};
        self.setToastWith("导出失败：{s}", .{@errorName(err)});
        self.exportWavRestore();
        self.exportWavFree();
    }

    /// 恢复快照并恢复设备（完成/取消/失败共用；设备仍暂停时回写插件状态）。
    fn exportWavRestore(self: *App) void {
        const ew = &self.export_wav.?;
        for (ew.states.items) |s| s.pl.restoreState(s.blobs.comp, s.blobs.ctrl);
        // 作废旧调度/残留声部（gen++ → stash 作废；设备恢复后首块回调全释音）
        self.scheduler.gen +%= 1;
        self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        self.events.push(.{ .kind = .all_off });
        self.params.playing.store(false, .monotonic);
        // 传输归位
        self.sel.song_mode = ew.snap_song_mode;
        self.playback.song_step = ew.snap_song;
        self.playback.piano_step = ew.snap_piano;
        self.playback.start_step = ew.snap_start_step;
        self.playback.start_frame = ew.snap_start_frame;
        self.params.start_step.store(ew.snap_start_step, .monotonic);
        self.params.start_frame.store(ew.snap_start_frame, .monotonic);
        self.params.frames_played.store(ew.snap_frames, .monotonic);
        self.engine.resumeDevice();
    }

    /// 释放导出状态（状态机终点）。
    fn exportWavFree(self: *App) void {
        if (self.export_wav) |*ew| {
            for (ew.states.items) |s| s.blobs.deinit(self.allocator);
            ew.states.deinit(self.allocator);
            self.allocator.free(ew.path);
            self.export_wav.?.log_buf.deinit(self.allocator);
        }
        self.export_wav = null;
    }

    /// 播放中的**小数步位置**（子步精度；未播放或域不匹配时 = 整数步）。
    /// 游标绘制与视角跟随用——整数步在屏幕上是 5px×zoom 的阶梯：播放中每步
    /// “跳一下再被平滑滚动回拉”形成锯齿抖动（实测“游标很抖”，放大时尤其明显）。
    /// `song_domain`：true = SONG（`song_step`）、false = PAT（`piano_step`）。
    pub fn cursorStepFrac(self: *const App, song_domain: bool) f32 {
        const base: i32 = if (song_domain) self.playback.song_step else self.playback.piano_step;
        if (!self.playing or self.sel.song_mode != song_domain) return @floatFromInt(base);
        const frames = self.params.frames_played.load(.monotonic);
        const bpm: u64 = @intCast(std.math.clamp(self.bpm, 20, 999));
        const spb_per_beat: u64 = @intCast(model.stepsPerBeat(self.time_den));
        const step_frames: u64 = @max(1, self.params.sample_rate * 60 / (bpm * spb_per_beat));
        const elapsed = frames -| self.playback.start_frame;
        const frac: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(step_frames));
        return @as(f32, @floatFromInt(self.playback.start_step)) + frac;
    }

    /// 游标**平滑**（渲染每帧调用，main）：前馈（按当前速度恒速推进）+ 一阶收敛
    /// （吸收音频缓冲量化——`frames_played` 是整缓冲跳的，直接用仍会阶梯抖，实测）。
    /// 跳转/回跳/未播放（与平滑值差 > 1.5 步）→ 直接归位。**不加“不许超前”钳制**
    /// ——那会把追赶变成“冲-停-冲”的棘轮；允许微幅超前无感知。
    pub fn tickCursorSmooth(self: *App) void {
        const target: f32 = self.cursorStepFrac(self.sel.song_mode);
        if (!self.playing or !self.cursor_smooth_ok or @abs(target - self.cursor_smooth) > 1.5) {
            self.cursor_smooth = target;
            self.cursor_smooth_ok = true;
            return;
        }
        const dt_s: f32 = @as(f32, @floatFromInt(self.frame_dt_ns)) / 1e9;
        const bpm: u64 = @intCast(std.math.clamp(self.bpm, 20, 999));
        const spb_per_beat: u64 = @intCast(model.stepsPerBeat(self.time_den));
        const step_frames: f32 = @as(f32, @floatFromInt(@max(1, self.params.sample_rate * 60 / (bpm * spb_per_beat))));
        const v: f32 = @as(f32, @floatFromInt(self.params.sample_rate)) / step_frames; // 步/秒
        const k: f32 = 1.0 - @exp(-dt_s / 0.12);
        self.cursor_smooth += v * dt_s + (target - self.cursor_smooth) * k;
    }

    /// 游标**显示用**小数步（平滑版；见 `tickCursorSmooth`）——
    /// 未播放或域不匹配时 = 冻结整数步。
    pub fn cursorDisplay(self: *const App, song_domain: bool) f32 {
        // PAT 模式下的“SONG 域”查询 = **虚拟全局位置**（锚片段映射；仅显示用，
        // 不写 song_step）——播放列表游标/跟随在 PAT 下位置自洽（设计 v1）。
        if (song_domain and !self.sel.song_mode) return self.patVirtualSongStepFrac();
        if (self.playing and self.cursor_smooth_ok and self.sel.song_mode == song_domain) return self.cursor_smooth;
        return @floatFromInt(if (song_domain) self.playback.song_step else self.playback.piano_step);
    }

    /// 播放推进后的**循环回跳**（main 主循环每帧调用，播放中）。
    ///
    /// 规则（两条叠加）：
    /// 1. **循环区域**（用户设置）：游标到 `loop[1]` → 回跳到 `loop[0]`；
    /// 2. **自动循环**（未设区域）：
    ///    - SONG：游标到**最后一个片段的右缘**（不论片段内有无音符）→ 回跳 0；
    ///    - PAT：游标到样式内最后一个音符末尾 → 回跳 0；
    ///    - 都无（无片段 / 无音符）→ 以**一小节**（当前拍号）为限，防游标无限右跑。
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
        //    SONG：**最后一个片段的右缘**（不论有无音符；空片段也播完整段）；
        //    PAT：样式内音符末尾。都为 0（无内容）→ 以一小节为限（防无限右跑）。
        const end: i32 = if (song_mode) self.clipsEndStep() else self.contentEndStep();
        const limit: i32 = if (end > 0) end else self.steps_per_bar;
        if (cur >= limit) {
            self.jumpPlaybackCursor(0);
        }
    }

    /// 选中与**全局步区域** `[lo, hi)` 相交的片段（播放列表循环选区用；与
    /// `selectNotesInRegionSong` 同语义：片段窗口 `[start, start+len)` 与区域有重叠即选中）。
    pub fn selectClipsInRegionSong(self: *App, lo: i32, hi: i32) void {
        self.clearClipSelection();
        for (self.clips.items) |*c| {
            if (c.len <= 0) continue;
            if (c.start < hi and c.start + c.len > lo) c.selected = true;
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
        if (inst < 0 or inst >= @as(i32, @intCast(self.params.instruments_cap))) return;
        if (pitch < 0 or pitch > 127) return;
        self.events.push(.{ .kind = .on, .pitch = @intCast(pitch), .instrument = @intCast(inst) });
    }

    /// 试听释音（**指定乐器**）
    pub fn auditionOffInst(self: *App, inst: i32, pitch: i32) void {
        if (inst < 0 or inst >= @as(i32, @intCast(self.params.instruments_cap))) return;
        if (pitch < 0 or pitch > 127) return;
        self.events.push(.{ .kind = .off, .pitch = @intCast(pitch), .instrument = @intCast(inst) });
    }

    /// 跳转播放位置（播放中拖动游标 / 设置起点）：
    /// 重置传输基准（帧+步）+ 作废旧调度事件（为跨起点长音符补发 on）。
    /// 传输代（gen）发布的前置标志：`soft=true` = **软切换**（音频侧不释放
    /// 声部——保位模式切换用；见 `audio.handleGenChange`）。必须在 gen 递增/
    /// 发布**之前**调用；单次消费（音频 swap 清位）。跳转/起播路径写 false。
    pub fn markGenSoft(self: *App, soft: bool) void {
        self.params.sched_gen_soft.store(soft, .release);
    }

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
            self.markGenSoft(false); // 硬切换：音频侧照旧释放全部声部（跳转必需）
            sequencer.reset(&self.scheduler, &self.sched_events, self.clips.items, self.notes.items, self.sel.song_mode, self.sel.pattern, step);
            self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        }
    }

    /// 当前锚片段（PAT ⇄ SONG 位置映射用；规则见 `PianoState.origin`）：
    /// 快照仍在（同值片段存在）→ 用它；被改/删 → 退化到动态最左片段；都没有 → null。
    /// **按 `sel.pattern` 而非 `piano.pattern`**——PAT 播放的驱动是选中样式，
    /// 与钢琴窗是否打开无关（实测 bug：钢琴窗关闭时映射失效、游标停在第 1 小节）。
    pub fn patOriginClip(self: *const App) ?model.Clip {
        const pat = self.sel.pattern;
        if (self.piano.origin) |o| {
            if (o.pattern == pat) {
                for (self.clips.items) |c| {
                    if (c.track == o.track and c.start == o.start and c.len == o.len and c.offset == o.offset and c.pattern == o.pattern) return o;
                }
            }
        }
        return model.leftmostClipFor(self.clips.items, pat);
    }

    /// 锚选择的参考位置（全局小数步）：SONG → `song_step`；PAT → 经**当前锚快照**
    /// 把 `piano_step` 换算（不看 `sel.pattern`——改样式前后调用结果一致）；无锚 → 0。
    pub fn anchorRefSongFrac(self: *const App) f32 {
        if (self.sel.song_mode) return @floatFromInt(self.playback.song_step);
        if (self.piano.origin) |o| {
            return @max(0, @as(f32, @floatFromInt(o.start - o.offset)) + @as(f32, @floatFromInt(self.playback.piano_step)));
        }
        return 0;
    }

    /// 换样式（点样式/重开）时的锚：**离参考位置最近的该样式片段**（无 → null）。
    pub fn nearestAnchorForPattern(self: *const App, pat: i32) ?model.Clip {
        return model.nearestClipFor(self.clips.items, pat, self.anchorRefSongFrac());
    }

    /// PAT 模式下的**虚拟全局位置**（小数步；仅显示/映射用——不写 `song_step`）。
    /// 有锚 → 锚映射；无锚 → 0（第 1 小节，规则 3）。
    pub fn patVirtualSongStepFrac(self: *const App) f32 {
        const local = self.cursorStepFrac(false);
        const o = self.patOriginClip() orelse return 0;
        return @max(0, @as(f32, @floatFromInt(o.start - o.offset)) + local);
    }

    /// 切到 PAT 时的目标局部步（SONG→PAT 反向）：song 游标在锚窗口内 → 映射；
    /// 窗口外/无锚 → 0（“切到样式从头播”——没有诚实的对应点）。
    pub fn patTargetLocalStep(self: *const App) i32 {
        const o = self.patOriginClip() orelse return 0;
        const s = self.playback.song_step;
        if (s < o.start or s >= o.start + o.len) return 0;
        return o.offset + (s - o.start);
    }

    /// 模式切换（**保位无缝**，用户拍板）：按锚片段映射换算目标步、原地换坐标。
    /// PAT→SONG 时局部位置**回绕进锚片段窗口**——PAT 的循环界（音符末尾）
    /// 可超出片段 len（放置后音符变长），直接映射会落在歌曲内容之外，被
    /// `tickPlaybackLoop` 的自动循环抓回 0（实测“切 SONG 游标停到其他小节”）。
    /// 播放中：位置**未变**（在锚窗口内）→ **软切换**（`seamlessSwitchPlayback`：
    /// 不释放声部、游标处差分、窗口重扫——听感无缝）；回绕/跳位 → 一次硬跳转
    /// （gen 重置、声部释放）。
    pub fn switchSongModePreserving(self: *App) void {
        if (self.sel.song_mode) {
            // SONG → PAT：锚窗口内 → 映射（保位）；窗外/无锚 → 0（真跳位）
            const o = self.patOriginClip();
            const s = self.playback.song_step;
            const in_window = if (o) |a| (s >= a.start and s < a.start + a.len) else false;
            const target = self.patTargetLocalStep();
            self.sel.song_mode = false;
            if (self.playing and in_window) {
                self.seamlessSwitchPlayback(target);
            } else {
                self.jumpPlaybackCursor(target);
            }
        } else {
            // PAT → SONG：局部位置在锚窗口内 → 直接映射（保位）；否则回绕进窗口（跳位）
            var target: i32 = @intFromFloat(@max(0, self.patVirtualSongStepFrac()));
            var preserved = false;
            if (self.patOriginClip()) |a| {
                if (a.len > 0) {
                    const local = self.playback.piano_step - a.offset;
                    target = a.start + @mod(local, a.len);
                    preserved = local >= 0 and local < a.len;
                }
            }
            self.sel.song_mode = true;
            if (self.playing and preserved) {
                self.seamlessSwitchPlayback(target);
            } else {
                self.jumpPlaybackCursor(target);
            }
        }
        // 切换后 `cursor_smooth` 是**旧域**的值（域检查会误认成新域 → 同一帧游标
        // 按新域取值会拿到旧域残影，一帧错位）；以新域真值重播——连续、无残影。
        self.cursor_smooth = self.cursorStepFrac(self.sel.song_mode);
        self.cursor_smooth_ok = true;
    }

    /// 播放中的**软切换**（保位模式切换：`sel.song_mode` 已翻、`target` 已算）：
    /// 换事件源但不释放声部——`switchMode` 做游标处差分 + 窗口重扫；
    /// 传输基准换到新模式坐标（音乐位置连续）。
    /// 发布顺序：软标志 → gen 递增 + 发布 → **最后**入队事件（音频回调若落在
    /// “新事件已入队、新代未发布”的窗口会把它们当旧代作废——整段丢失）。
    fn seamlessSwitchPlayback(self: *App, target: i32) void {
        const new_mode = self.sel.song_mode;
        const old_cur = if (new_mode) self.playback.piano_step else self.playback.song_step;
        if (new_mode) {
            self.playback.song_step = target;
        } else {
            self.playback.piano_step = target;
        }
        self.playback.start_step = target;
        self.playback.start_frame = self.params.frames_played.load(.monotonic);
        self.params.start_frame.store(self.playback.start_frame, .monotonic);
        self.params.start_step.store(target, .monotonic);
        self.markGenSoft(true);
        self.scheduler.gen +%= 1;
        self.params.sched_gen.store(self.scheduler.gen, .monotonic);
        const horizon = target + self.steps_per_bar * 4; // 同主循环 lookahead（4 小节）
        sequencer.switchMode(
            &self.scheduler,
            &self.sched_events,
            self.clips.items,
            self.notes.items,
            !new_mode,
            self.sel.pattern,
            old_cur,
            new_mode,
            self.sel.pattern,
            target,
            horizon,
        );
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
        // 锚快照**保留**（关窗只是隐藏；重新打开同一样式时游标/映射停原位——
        // 实测 bug：双击片段放游标 → 切播放列表 → 切回，SONG 游标消失）。
        // 失效快照由 `patOriginClip` 的校验兜底（片段被改/删 → 动态最左）。
        self.piano.drag_note = null;
        self.piano.snap_menu_open = false; // 关闭视图时收起标题栏选单
        self.piano.inst_menu_open = false;
        // 释音：**只释放按住琴键/音符拖动的试听**（防止“按住时关闭视图”卡音——
        // 原实现推 `all_off` 兜底，但 all_off 会连**播放中的声部**一起掐掉：
        // 实测 bug——播放中连点视图切换按钮，每次关窗 = 全体消音 + 体感卡。
        // `held_pitch` 是试听的唯一在按标记（琴键与音符拖动共用）。
        if (self.piano.held_pitch) |hp| self.auditionOff(hp);
        self.piano.held_pitch = null;
    }

    /// 打开钢琴卷帘（编辑指定样式的音符）
    pub fn openPiano(self: *App, pattern: i32) void {
        // 锚快照：**同一样式重开（关窗→再开）时保留**——游标/映射停原位；
        // **换样式 → 离游标最近的片段**（规则 2 v2：窗随游标，最左只是特例）。
        if (self.piano.origin == null or self.piano.origin.?.pattern != pattern) {
            self.piano.origin = self.nearestAnchorForPattern(pattern);
        }
        self.piano.pattern = pattern;
        self.piano.snap_menu_open = false; // 打开时收起上次残留的选单
        self.piano.inst_menu_open = false;
        self.playlist.drag_clip = null;
        self.playlist.resize_clip = null;
        self.playlist.erase_drag = false;
        self.piano.drag_note = null;
        self.piano.scroll = (127 - 84) * self.piano.key_h; // 视野顶部从 C6 开始（下方可见 C3-C6）
        self.piano.scroll_x = 0;
    }

    /// 打开钢琴卷帘（**从片段双击**）——记录锚片段（PAT ⇄ SONG 位置映射，规则 1）
    pub fn openPianoFromClip(self: *App, c: model.Clip) void {
        self.openPiano(c.pattern);
        self.piano.origin = c;
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

    /// 打开音频样式重命名输入框（位置由调用方给；复用文本输入基建——支持中文 IME）
    pub fn beginRenameAudioStyle(self: *App, idx: usize, x: i32, y: i32) void {
        if (idx >= self.audio_styles.items.len) return;
        const ti = &self.text_input;
        ti.active = true;
        ti.target = .audio_style;
        ti.index = idx;
        ti.x = x;
        ti.y = y;
        const name = self.audio_styles.items[idx].name;
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
            .audio_style => {
                if (ti.index < self.audio_styles.items.len) {
                    const st = &self.audio_styles.items[ti.index];
                    // 空串 → 恢复默认名（文件名）
                    const want: []const u8 = if (val.len > 0) val else std.fs.path.basename(st.path);
                    if (want.len > 0 and !std.mem.eql(u8, st.name, want)) {
                        if (self.allocator.dupe(u8, want)) |c| {
                            self.allocator.free(st.name);
                            st.name = c;
                            self.dirty = true;
                            self.commitHistory("重命名音频样式");
                        } else |_| {}
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
            .track => {
                const key: i32 = @intCast(ti.index);
                if (val.len == 0) {
                    // **空 = 恢复默认名**（Track N）：删除自定义名条目（用户拍板）
                    if (self.track_names.fetchRemove(key)) |kv| {
                        self.allocator.free(kv.value);
                        self.dirty = true;
                        self.commitHistory("恢复默认轨道名");
                    }
                } else {
                    const old = self.track_names.get(key);
                    // 改名 == 合成默认名（且本无自定义名）→ 无需入表
                    const same = if (old) |o| std.mem.eql(u8, o, val) else std.mem.eql(u8, val, self.trackName(ti.index));
                    if (!same) {
                        const copy = self.allocator.dupe(u8, val) catch null;
                        if (copy) |c| {
                            self.track_names.put(self.allocator, key, c) catch {
                                self.allocator.free(c);
                            };
                            if (old) |o| self.allocator.free(o);
                            self.dirty = true;
                            self.commitHistory("重命名轨道");
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
            .preset_search => {
                // 搜索框：文字已实时同步到 `preset_browser.filter_*`（见 beginPresetSearch）
                // ——提交仅收起输入框，过滤保留
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

test "app: 手势历史（滚轮类）：起手即提交临时条目 + 静置钉值 + 再滚新条目" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");
    const base = app.history.items.len;

    var f: u64 = app.params.frames_played.load(.monotonic);

    // 第一滚：**立即**产生临时条目（起手提交——他家 DAW 模型）
    f += 1000;
    app.params.frames_played.store(f, .monotonic);
    app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .eq }) catch {};
    app.touchGesture("调整 EQ Q 值");
    try std.testing.expectEqual(base + 1, app.history.items.len);

    // 连续滚动：同一条（临时条目仍为起手时的快照）
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        f += 1000;
        app.params.frames_played.store(f, .monotonic);
        app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .eq }) catch {};
        app.touchGesture("调整 EQ Q 值");
        app.pollGestureHistory(); // 间隔远小于 1s → 不钉
    }
    try std.testing.expectEqual(base + 1, app.history.items.len);
    try std.testing.expectEqual(@as(u32, 1), app.history.items[base].mixer[0].effect_count);

    // 静置 ≥ 1s → 钉住最终值（共 10 个效果器——动态切片不再截断）
    f += app.params.sample_rate + 10;
    app.params.frames_played.store(f, .monotonic);
    app.pollGestureHistory();
    try std.testing.expectEqual(base + 1, app.history.items.len);
    try std.testing.expectEqual(@as(u32, 10), app.history.items[base].mixer[0].effect_count);

    // 再滚一轮 → 新条目
    f += 1000;
    app.params.frames_played.store(f, .monotonic);
    app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .eq }) catch {};
    app.touchGesture("调整 EQ Q 值");
    try std.testing.expectEqual(base + 2, app.history.items.len);
}

test "app: 手势历史顺序（新操作起手先钉 → 撤销按因果顺序回退）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    app.resetHistory("初始状态");

    // 手势（如 BPM 滚轮）：起手即时提交
    app.bpm = 100;
    app.touchGesture("调整 BPM");
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len);
    app.bpm = 110;
    app.touchGesture("调整 BPM"); // 同一条
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len);

    // 新离散操作起手：先钉（模拟鼠标按下钩子）→ 再改值提交
    app.pinPendingGesture();
    app.mixer_channels_state.items[0].volume = 0.5;
    app.commitHistory("调整音量");
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len);
    try std.testing.expectEqual(@as(i32, 110), app.history.items[1].bpm); // 钉住了最终值
    try std.testing.expectEqual(@as(f32, 0.5), app.history.items[2].mixer[0].volume);

    // 撤销：先回音量（BPM 仍 110）→ 再回 BPM
    try std.testing.expect(app.undo());
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), app.mixer_channels_state.items[0].volume, 0.001);
    try std.testing.expectEqual(@as(i32, 110), app.bpm);
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(i32, 120), app.bpm); // 回到基线
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

    // 池化：通道无人工上限——加到 40 条（自动扩容），容量随之增长
    while (app.mixer_channels_state.items.len < 40) {
        try std.testing.expect(app.addMixerChannel() != null);
    }
    try std.testing.expectEqual(@as(usize, 40), app.mixer_channels_state.items.len);
    try std.testing.expect(app.params.channels_cap >= 40);
    // 新通道上的效果器也能正常添加（扩容后的行/扁平数组可用）
    try std.testing.expect(app.addEffect(39, .eq) != null);
    try std.testing.expect(app.addEffect(39, .reverb) != null);
    app.removeEffect(39, 0);
    try std.testing.expectEqual(@as(usize, 1), app.mixer_channels_state.items[39].effects.items.len);
}

test "app: 片段叠放——沉底轮换（点中即沉到同左端点组最底）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    // 三条同轨道同左端点的片段（数组序 0,1,2 = 层序底→顶）
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 0 });
    // 命中 = 最顶层（数组序最大）
    try std.testing.expectEqual(@as(?usize, 2), model.topmostClipAt(app.clips.items, 0, 5));
    // 沉底：2 → 新下标 0；层序变为 [旧2, 旧0, 旧1]，顶层 = 下标 2（旧1）
    try std.testing.expectEqual(@as(usize, 0), app.sinkClipToTieBottom(2));
    try std.testing.expectEqual(@as(?usize, 2), model.topmostClipAt(app.clips.items, 0, 5));
    // 三连沉 → 回到初始序
    try std.testing.expectEqual(@as(usize, 0), app.sinkClipToTieBottom(2));
    try std.testing.expectEqual(@as(usize, 0), app.sinkClipToTieBottom(2));
    // 另一轨道的独苗：原样返回（不跨轨成组）
    app.addClip(.{ .track = 1, .start = 0, .len = 96, .pattern = 0 });
    try std.testing.expectEqual(@as(usize, 3), app.sinkClipToTieBottom(3));
}

test "app: 音符叠放——沉底轮换（点中即沉到同音高同左端点组最底）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.addNote(.{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 24, .pitch = 60, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(@as(?usize, 2), model.topmostNoteAt(app.notes.items, 0, 0, 60, 5));
    // 三连沉 → 回环（同片段测试）
    try std.testing.expectEqual(@as(usize, 0), app.sinkNoteToTieBottom(2));
    try std.testing.expectEqual(@as(?usize, 2), model.topmostNoteAt(app.notes.items, 0, 0, 60, 5));
    try std.testing.expectEqual(@as(usize, 0), app.sinkNoteToTieBottom(2));
    try std.testing.expectEqual(@as(usize, 0), app.sinkNoteToTieBottom(2));
    // 同音高但左端不同：不跨组成团
    app.addNote(.{ .step = 48, .len = 24, .pitch = 60, .pattern = 0, .instrument = 0 });
    try std.testing.expectEqual(@as(usize, 3), app.sinkNoteToTieBottom(3));
}

test "app: MIDI 导入为纯追加（不干扰已有乐器/音符/样式；含撤销往返）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const old_inst = app.addInstrument("减法合成器");
    try std.testing.expect(old_inst >= 0);
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0, .instrument = old_inst });
    app.resetHistory("初始状态");
    const old_notes = app.notes.items.len;
    const old_pats = app.pattern_items.items.len;
    const old_insts = app.instruments.items.len;

    var pnotes = [_]midi.ParsedNote{
        .{ .start_tick = 0, .end_tick = 480, .pitch = 64, .channel = 2, .velocity = 90 },
        .{ .start_tick = 480, .end_tick = 960, .pitch = 67, .channel = 2, .velocity = 90 },
    };
    var parsed = midi.Parsed{ .ticks_per_quarter = 480, .notes = &pnotes };

    // 导入前把“视图”钉在已有内容上（复现用户场景）
    app.sel.pattern = 0;
    app.piano.pattern = 0;
    app.sel.instrument = old_inst;

    const r = try app.importMidi(&parsed);
    try std.testing.expectEqual(@as(usize, 2), r.notes);
    try std.testing.expectEqual(@as(usize, 1), r.instruments);
    // 1) 已有音符/乐器/样式原样保留
    try std.testing.expectEqual(old_notes + 2, app.notes.items.len);
    try std.testing.expectEqual(old_insts + 1, app.instruments.items.len);
    try std.testing.expectEqual(old_pats + 1, app.pattern_items.items.len);
    try std.testing.expectEqualStrings("减法合成器", app.instruments.items[0].name);
    try std.testing.expectEqual(@as(i32, 0), app.notes.items[0].pattern);
    try std.testing.expectEqual(old_inst, app.notes.items[0].instrument);
    // 2) 新内容在“后方追加”
    try std.testing.expectEqual(@as(i32, @intCast(old_pats)), r.pattern);
    try std.testing.expectEqual(@as(i32, 2), app.instruments.items[old_insts].midi_channel);
    try std.testing.expectEqual(r.pattern, app.notes.items[old_notes].pattern);
    try std.testing.expectEqual(@as(i32, @intCast(old_insts)), app.notes.items[old_notes].instrument);
    // 3) 视图**不被劫持**（用户拍板：样式/乐器都不自动切——导入只追加，
    //    样式号在 toast 里告知）
    try std.testing.expectEqual(@as(i32, 0), app.sel.pattern);
    try std.testing.expectEqual(@as(?i32, 0), app.piano.pattern);
    try std.testing.expectEqual(old_inst, app.sel.instrument);

    // 4) 提交后撤销/重做往返：模型与旧内容均稳定
    app.commitHistory("导入 MIDI");
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(old_notes, app.notes.items.len);
    try std.testing.expectEqual(old_insts, app.instruments.items.len);
    try std.testing.expect(app.redo());
    try std.testing.expectEqual(old_notes + 2, app.notes.items.len);
    try std.testing.expectEqual(old_insts + 1, app.instruments.items.len);
}

test "app: MIDI 导出——超过 16 的乐器不导出（防通道挤占；带来源通道者除外）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        try std.testing.expect(app.addInstrument("减法合成器") >= 0);
    }
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.addNote(.{ .step = 0, .len = 4, .pitch = 62, .pattern = 0, .instrument = 16 }); // 超限：不导出
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0, .offset = 0 }) catch {};
    const evs = try app.exportMidiNotes(app.allocator);
    defer app.allocator.free(evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expect(evs[0].channel == 0);
    // 带来源通道的记录（导入而来）：即使 ≥16 也按记录通道导出（往返稳定）
    app.instruments.items[16].midi_channel = 5;
    const evs2 = try app.exportMidiNotes(app.allocator);
    defer app.allocator.free(evs2);
    try std.testing.expectEqual(@as(usize, 2), evs2.len);
}

test "app: 池化——乐器无人工上限（40 个自动扩容；容量只增不减）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.resetHistory("初始状态");
    const cap0 = app.params.instruments_cap;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try std.testing.expect(app.addInstrument("减法合成器") >= 0);
    }
    try std.testing.expectEqual(@as(usize, 40), app.instruments.items.len);
    try std.testing.expect(app.params.instruments_cap > cap0);
    try std.testing.expect(app.params.instruments_cap >= 40);
    try std.testing.expect(sequencer.instrument_cap >= 40);
    try std.testing.expect(app.params.synth_ptrs.len >= 40);
    // 删除全部 → 帧末回收（滞回：4× 余量才缩容）→ 回到初始容量 32
    while (app.instruments.items.len > 0) app.removeInstrument(app.instruments.items.len - 1);
    try std.testing.expectEqual(@as(usize, 0), app.instruments.items.len);
    try std.testing.expect(app.params.instruments_cap >= 40); // 回收前仍是扩容后的容量
    app.pollCapacityReclaim();
    try std.testing.expectEqual(@as(usize, 32), app.params.instruments_cap);
    // 缩容后仍可继续添加（容量再增长）
    try std.testing.expect(app.addInstrument("减法合成器") >= 0);
    try std.testing.expectEqual(@as(usize, 1), app.instruments.items.len);
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

test "app: 循环播放——**空内容**播完一小节自动回跳（不再无限右跑）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // PAT：样式 0 无音符 → 内容末尾 0
    app.sel.song_mode = false;
    app.sel.pattern = 0;
    try std.testing.expectEqual(@as(i32, 0), app.contentEndStep());

    const bar: i32 = app.steps_per_bar;
    app.playing = true;
    app.playback.piano_step = bar - 1;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(bar - 1, app.playback.piano_step); // 未到一小节：不动
    app.playback.piano_step = bar;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 0), app.playback.piano_step); // 播完一小节：回跳

    // 循环区域仍优先（空内容也一样）
    app.setLoopRegion(4, 12);
    app.playback.piano_step = 12;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 4), app.playback.piano_step);

    // SONG：无片段 → 同样是“一小节”
    app.clearLoopRegion();
    app.sel.song_mode = true;
    app.playback.song_step = bar;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 0), app.playback.song_step);

    // SONG：有片段但**无音符** → 循环点 = 最后一个片段的**右缘**（不论有无音符）
    app.clips.append(app.allocator, .{ .track = 0, .start = bar, .len = bar, .pattern = 0, .offset = 0 }) catch {};
    try std.testing.expectEqual(bar * 2, app.clipsEndStep());
    try std.testing.expectEqual(@as(i32, 0), app.contentEndStep()); // 无音符 → 仍 0
    app.playback.song_step = bar * 2 - 1;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(bar * 2 - 1, app.playback.song_step); // 未到片段右缘：不动
    app.playback.song_step = bar * 2;
    app.tickPlaybackLoop();
    try std.testing.expectEqual(@as(i32, 0), app.playback.song_step); // 到片段右缘：回跳

    app.stopPlayback();
}

test "app: cursorStepFrac——子步精度（播放中 = 起始步 + 已播放帧/步长帧）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 48000Hz、120BPM、4/4（每拍 96/4 = 24 步）→ 1000 帧/步
    app.bpm = 120;
    app.time_den = 4;
    app.params.sample_rate = 48_000;
    app.playback.start_frame = 1000;
    app.playback.start_step = 10;
    app.params.frames_played.store(1000 + 3500, .monotonic); // 已过 3.5 步

    app.sel.song_mode = true;
    app.playing = true;
    try std.testing.expectEqual(@as(f32, 13.5), app.cursorStepFrac(true));

    // 域不匹配 / 未播放 → 冻结整数步
    app.playback.song_step = 7;
    app.sel.song_mode = false;
    try std.testing.expectEqual(@as(f32, 7), app.cursorStepFrac(true));
    app.sel.song_mode = true;
    app.playing = false;
    try std.testing.expectEqual(@as(f32, 7), app.cursorStepFrac(true));
}

test "app: SONG→PAT 往返精确（钢琴窗放游标后切 PAT 位置不变）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    // 样式1 一前一后两个片段；双击后者 → 锚 = 后者
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 384, .len = 96, .pattern = 0 });
    app.openPianoFromClip(app.clips.items[1]);
    app.sel.pattern = 0;
    app.sel.song_mode = true;
    // 钢琴 SONG 标尺放置：local 50 → song = 384 + 50 = 434
    try std.testing.expectEqual(@as(?i32, 434), model.clipLocalToSong(app.clips.items[1], 50));
    app.playback.song_step = 434;
    // 切 PAT → local 应 = 50（位置不变）
    app.switchSongModePreserving();
    try std.testing.expect(!app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 50), app.playback.piano_step);
    // 再切回 SONG → 仍 434（往返）
    app.switchSongModePreserving();
    try std.testing.expectEqual(@as(i32, 434), app.playback.song_step);
}

test "app: 关钢琴再开（同一样式）锚快照保留——双击片段放的游标切回来仍在原位" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    // 样式1 一前一后两个片段；双击后者（锚 = 后者，非动态最左）
    app.addClip(.{ .track = 0, .start = 0, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 384, .len = 96, .pattern = 0 });
    app.openPianoFromClip(app.clips.items[1]);
    app.sel.pattern = 0;
    app.sel.song_mode = true;
    app.playback.song_step = 434; // SONG 游标：后片段局部 50
    // 切回播放列表（关钢琴）→ 再切回钢琴（同一样式；工具栏/⇄ 按钮路径）
    app.closePiano();
    app.openPiano(app.sel.pattern);
    // 实测 bug：此前关窗清快照 → 重开锚退化成动态最左（start 0）→ song 434 不在
    // 其窗口内 → SONG 游标不绘制（“游标不见了”）。现在快照保留 → 锚仍是后片段
    try std.testing.expectEqual(@as(i32, 384), app.patOriginClip().?.start);
    try std.testing.expect(model.clipSongToLocal(app.patOriginClip().?, app.playback.song_step) != null);
    // 规则 2（v2：点样式打开 = 离游标最近）：游标移到前片段内（song 50）→ 锚 = 前片段
    app.playback.song_step = 50;
    app.closePiano();
    app.piano.origin = null; // 模拟“从未有快照”的通用打开
    app.openPiano(app.sel.pattern);
    try std.testing.expectEqual(@as(i32, 0), app.patOriginClip().?.start);
}

test "app: 换样式锚 = 离游标最近——切走再切回 = 双击的片段（游标仍在其内）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(2);
    app.resetMixerChannels(default_mixer_channels);
    // 样式1：B(384)、C(960)；样式2：一处 480
    app.addClip(.{ .track = 0, .start = 384, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 960, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 480, .len = 96, .pattern = 1 });
    app.openPianoFromClip(app.clips.items[0]); // 双击 B
    app.sel.song_mode = true;
    app.playback.song_step = 434; // 游标在 B 内
    // 换到样式2（点样式路径）：锚 = 离游标最近的该样式片段
    app.sel.pattern = 1;
    app.piano.pattern = 1;
    app.piano.origin = app.nearestAnchorForPattern(1);
    try std.testing.expectEqual(@as(i32, 480), app.patOriginClip().?.start);
    // 切回样式1：游标仍在 B 内 → 锚回到 B（“切回来还是那个片段”——自然得到）
    app.sel.pattern = 0;
    app.piano.pattern = 0;
    app.piano.origin = app.nearestAnchorForPattern(0);
    try std.testing.expectEqual(@as(i32, 384), app.patOriginClip().?.start);
    // 游标移到 C 内（1000）→ 锚 = C
    app.playback.song_step = 1000;
    app.piano.origin = app.nearestAnchorForPattern(0);
    try std.testing.expectEqual(@as(i32, 960), app.patOriginClip().?.start);
    // PAT 参考：经当前锚换算虚拟位置（B 锚、piano_step 50 → 434）→ 样式2 最近 = 480
    app.sel.song_mode = false;
    app.playback.piano_step = 50;
    app.piano.origin = app.clips.items[0]; // 锚回 B
    try std.testing.expectEqual(@as(i32, 480), app.nearestAnchorForPattern(1).?.start);
    // 无片段样式（样式3）→ null（映射退化 0，规则 3 不变）
    app.resetPatterns(3);
    try std.testing.expect(app.nearestAnchorForPattern(2) == null);
}

test "app: 鼓组 VST3 层——添加/展平槽位/导出导入往返/相等比较/换回减法" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    try std.testing.expectEqual(@as(i32, 0), inst);
    app.resetHistory("初始状态");

    // 减法层（35）+ VST3 层（35）+ 减法层（38）：展平槽位 = 0,1,2
    try std.testing.expect(app.kitLayerAdd(inst, 35, null, ""));
    try std.testing.expect(app.kitLayerAddVst3(inst, 35, "C:/v/Vital.vst3", "Vital"));
    try std.testing.expect(app.kitLayerAdd(inst, 38, null, ""));
    app.commitHistory("添加层");

    const kit = app.instruments.items[0].kit.?;
    try std.testing.expectEqual(@as(usize, 3), kit.totalLayers());
    const vl = &kit.find(35).?.layers.items[1];
    try std.testing.expect(vl.kind == .vst3);
    try std.testing.expectEqualStrings("C:/v/Vital.vst3", vl.pluginPath());
    try std.testing.expectEqualStrings("Vital", vl.source_preset);
    // 展平槽位（与 params 展平序一致；VST3 panic 旗标等按它寻址）
    try std.testing.expectEqual(@as(?usize, 1), app.kitLayerSlot(0, 35, 1));
    try std.testing.expectEqual(@as(?usize, 2), app.kitLayerSlot(0, 38, 0));
    // kit_vsti 惰性状态（含 VST3 层 → 已建立；测试环境无插件实例，加载静默失败）
    try std.testing.expect(app.engine.kit_vsti[0].load(.monotonic) != null);

    // 导出 → 导入往返：VST3 字段保留（无实例 → 路径/来源）
    var sk = app.exportKitForSave(0).?;
    defer app.freeSavedKit(&sk, false);
    try std.testing.expectEqual(@as(u32, 2), sk.pads[0].layers[1].kind);
    try std.testing.expectEqualStrings("C:/v/Vital.vst3", sk.pads[0].layers[1].plugin_path);
    try std.testing.expectEqualStrings("Vital", sk.pads[0].layers[1].source_preset);
    try std.testing.expect(app.loadKitInto(0, &sk));
    const kit2 = app.instruments.items[0].kit.?;
    try std.testing.expectEqual(@as(usize, 3), kit2.totalLayers());
    try std.testing.expect(kit2.find(35).?.layers.items[1].kind == .vst3);
    try std.testing.expectEqualStrings("C:/v/Vital.vst3", kit2.find(35).?.layers.items[1].pluginPath());

    // 相等比较：无变化提交被去重；**VST3 路径变化** → 判“有变化”（防静默丢历史）
    const before = app.history.items.len;
    app.commitHistory("无变化提交");
    try std.testing.expectEqual(before, app.history.items.len);
    kit2.find(35).?.layers.items[1].setPluginPath("C:/v/Other.vst3");
    app.commitHistory("换路径");
    try std.testing.expectEqual(before + 1, app.history.items.len);

    // 换回减法（插件退役/路径清空）——减法预设应用前必须走它
    app.kitLayerClearVst3(0, 35, 1);
    try std.testing.expect(kit2.find(35).?.layers.items[1].kind == .subtractive);
    try std.testing.expectEqualStrings("", kit2.find(35).?.layers.items[1].pluginPath());

    // 撤销两次：换路径 → 添加层（3 层）→ 初始状态（无层）
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 3), app.instruments.items[0].kit.?.totalLayers());
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 0), app.instruments.items[0].kit.?.totalLayers());
}

test "app: 音频资产/样式/片段——解码/去重/播放表/撤销/采样层/存档往返（生成 WAV）" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}/a.wav", .{dirp});
    defer alloc.free(wav_path);
    // 写 16bit PCM 立体声 4800 帧（0.1s@48k 正弦）
    {
        var w = std.ArrayListUnmanaged(u8).empty;
        defer w.deinit(alloc);
        const data_bytes: u32 = 4800 * 4;
        try w.appendSlice(alloc, "RIFF");
        try w.appendSlice(alloc, std.mem.asBytes(&(@as(u32, 36) + data_bytes)));
        try w.appendSlice(alloc, "WAVEfmt ");
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 48000)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 48000 * 4)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 4)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
        try w.appendSlice(alloc, "data");
        try w.appendSlice(alloc, std.mem.asBytes(&data_bytes));
        var i: usize = 0;
        while (i < 4800) : (i += 1) {
            const s: i16 = @intFromFloat(@sin(@as(f64, @floatFromInt(i)) * 0.03) * 12000.0);
            try w.appendSlice(alloc, std.mem.asBytes(&s));
            try w.appendSlice(alloc, std.mem.asBytes(&s));
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wav_path, .data = w.items }) catch return error.IoFailure;
    }

    var app = App{ .allocator = alloc };
    app.sel.song_mode = true; // 音频片段只在 SONG 模式发声/入表（PAT 发布空表）
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.resetHistory("初始");

    // 解码 + 去重
    const ai = app.loadAudioAsset(wav_path) orelse return error.AssetLoadFailed;
    try std.testing.expectEqual(@as(usize, 4800), app.audio_assets.items[@intCast(ai)].data.frame_count);
    try std.testing.expect(app.audio_assets.items[@intCast(ai)].peaks.len > 0);
    try std.testing.expectEqual(@as(?i32, ai), app.loadAudioAsset(wav_path));
    // 原生率解码（不重采样）：24kHz 文件 → frame_count 是原生帧；ratio = 0.5；
    // engFrames 换算回引擎域（UI/trim 的单位），与 48k 文件等长
    {
        const wav2 = try std.fmt.allocPrint(alloc, "{s}/b24.wav", .{dirp});
        defer alloc.free(wav2);
        var w = std.ArrayListUnmanaged(u8).empty;
        defer w.deinit(alloc);
        const data_bytes: u32 = 2400 * 4;
        try w.appendSlice(alloc, "RIFF");
        try w.appendSlice(alloc, std.mem.asBytes(&(@as(u32, 36) + data_bytes)));
        try w.appendSlice(alloc, "WAVEfmt ");
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 24000)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 24000 * 4)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 4)));
        try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
        try w.appendSlice(alloc, "data");
        try w.appendSlice(alloc, std.mem.asBytes(&data_bytes));
        var j24: usize = 0;
        while (j24 < 2400) : (j24 += 1) {
            const s2: i16 = @intFromFloat(@sin(@as(f64, @floatFromInt(j24)) * 0.06) * 12000.0);
            try w.appendSlice(alloc, std.mem.asBytes(&s2));
            try w.appendSlice(alloc, std.mem.asBytes(&s2));
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wav2, .data = w.items }) catch return error.IoFailure;
        const ai2 = app.loadAudioAsset(wav2) orelse return error.AssetLoadFailed;
        const d2 = &app.audio_assets.items[@intCast(ai2)].data;
        try std.testing.expectEqual(@as(usize, 2400), d2.frame_count);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), d2.ratio, 1e-3);
        try std.testing.expectEqual(@as(usize, 4800), d2.engFrames());
    }

    // 样式 + 片段 + 播放表
    const style = app.audioStyleAdd(wav_path, "") orelse return error.StyleFailed;
    const ci = app.audioClipAdd(style, 0, 0) orelse return error.ClipFailed;
    try std.testing.expect(app.clips.items[ci].isAudio());
    try std.testing.expect(app.clips.items[ci].len >= 1);
    app.commitHistory("导入音频");
    app.rebuildAudioTable();
    const tbl = app.params.audio_table.load(.monotonic).?;
    try std.testing.expectEqual(@as(usize, 1), tbl.rows.len);
    try std.testing.expect(tbl.rows[0].asset != null);
    // 无变化 → **不重发**（逐字段比对；指针不变）
    app.rebuildAudioTable();
    try std.testing.expect(tbl == app.params.audio_table.load(.monotonic).?);
    // PAT 模式 → 空表；回 SONG → 行回来（每帧重算，不依赖脏标）
    app.sel.song_mode = false;
    app.rebuildAudioTable();
    try std.testing.expectEqual(@as(usize, 0), app.params.audio_table.load(.monotonic).?.rows.len);
    app.sel.song_mode = true;
    app.rebuildAudioTable();
    try std.testing.expectEqual(@as(usize, 1), app.params.audio_table.load(.monotonic).?.rows.len);
    // 轨道静音 → 音频片段也静音（与音符片段同语义）；取消静音 → 行回来
    app.setTrackMuted(0, true);
    app.rebuildAudioTable();
    try std.testing.expectEqual(@as(usize, 0), app.params.audio_table.load(.monotonic).?.rows.len);
    app.setTrackMuted(0, false);
    app.rebuildAudioTable();
    try std.testing.expectEqual(@as(usize, 1), app.params.audio_table.load(.monotonic).?.rows.len);

    // 样式增益改动 → 历史；撤销还原（样式级共享语义）
    app.audio_styles.items[@intCast(style)].gain = 0.5;
    app.commitHistory("调整音频增益");
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len);
    try std.testing.expect(app.undo());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), app.audio_styles.items[@intCast(style)].gain, 1e-6);

    // 采样器层
    const inst = app.addDrumkit("鼓组");
    try std.testing.expect(app.kitLayerAddSampler(inst, 35, wav_path));
    const ly = &app.instruments.items[0].kit.?.find(35).?.layers.items[0];
    try std.testing.expect(ly.kind == .sampler);
    try std.testing.expect(ly.asset_idx >= 0);

    // 存档往返（绝对路径保留；样式/片段/层均重建）
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    var app2 = App{ .allocator = alloc };
    defer app2.clips.deinit(alloc);
    defer app2.notes.deinit(alloc);
    defer app2.deinitAll();
    app2.importProject(proj);
    try std.testing.expectEqual(@as(usize, 1), app2.audio_styles.items.len);
    var found_audio_clip = false;
    for (app2.clips.items) |c| {
        if (c.isAudio()) found_audio_clip = true;
    }
    try std.testing.expect(found_audio_clip);
    const ly2 = &app2.instruments.items[0].kit.?.find(35).?.layers.items[0];
    try std.testing.expect(ly2.kind == .sampler);
    try std.testing.expect(ly2.asset_idx >= 0);
}

test "app: 鼓组 VST3 层槽位引用——slotPlugin 解析 + 层脏标置位/清除" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    try std.testing.expectEqual(@as(i32, 0), inst);
    app.resetHistory("初始状态");
    // 层序：35 减法 / 35 VST3 / 38 减法 → 展平槽位 0 / 1 / 2
    try std.testing.expect(app.kitLayerAdd(inst, 35, null, ""));
    try std.testing.expect(app.kitLayerAddVst3(inst, 35, "C:/v/Vital.vst3", "Vital"));
    try std.testing.expect(app.kitLayerAdd(inst, 38, null, ""));
    // slotPlugin：槽位 → 层插件（测试环境无实例 → null）；越界/无垫 → null
    try std.testing.expectEqual(@as(?usize, 1), app.kitLayerSlot(0, 35, 1));
    try std.testing.expect(app.slotPlugin(.{ .kind = .kit_layer, .a = 0, .b = 1 }) == null);
    try std.testing.expect(app.slotPlugin(.{ .kind = .kit_layer, .a = 0, .b = 99 }) == null);
    try std.testing.expect(app.slotPlugin(.{ .kind = .kit_layer, .a = 7, .b = 0 }) == null);
    // 层脏标（编辑器参数记账路径）：置位 → 清除
    app.markSlotStateDirty(.{ .kind = .kit_layer, .a = 0, .b = 1 });
    try std.testing.expect(app.kit_layer_state_dirty[0][1]);
    app.markSlotStateClean(.{ .kind = .kit_layer, .a = 0, .b = 1 });
    try std.testing.expect(!app.kit_layer_state_dirty[0][1]);
}

test "app: 鼓组两层 VST3 各自编辑 → 历史各自成条 + 撤销 + 无幽灵（Vital 优先/自带测试插件兑底）" {
    const alloc = std.testing.allocator;
    // 优先 Vital（用户实症：恢复后 getState 回声字节与存档不同）；无 → 自带测试插件；都无 → 跳过
    const vital_path = "C:\\Program Files\\Common Files\\VST3\\Vital.vst3";
    const sine_path = "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll";
    var dll: []const u8 = vital_path;
    var pz = alloc.dupeSentinel(u8, dll, 0) catch return;
    var pl1 = vst_host.loadPlugin(alloc, pz, 48000, 4096, .instrument) catch blk: {
        alloc.free(pz);
        dll = sine_path;
        pz = alloc.dupeSentinel(u8, dll, 0) catch return;
        break :blk vst_host.loadPlugin(alloc, pz, 48000, 4096, .instrument) catch return;
    };
    defer alloc.free(pz);
    const pl2 = vst_host.loadPlugin(alloc, pz, 48000, 4096, .instrument) catch return;
    // 注：两个实例挂到层上后**归 App 所有**（deinitAll 经退役链统一销毁）——不手动 unload

    var app = App{ .allocator = alloc };
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    try std.testing.expectEqual(@as(i32, 0), inst);
    try std.testing.expect(app.kitLayerAddVst3(inst, 35, dll, "P"));
    try std.testing.expect(app.kitLayerAddVst3(inst, 38, dll, "P"));
    {
        const kit = app.instruments.items[0].kit.?;
        kit.find(35).?.layers.items[0].plugin = pl1;
        kit.find(38).?.layers.items[0].plugin = pl2;
    }
    pl1.refreshParamCache();
    pl2.refreshParamCache();
    app.resetHistory("初始");

    const ref38 = PluginSlotRef{ .kind = .kit_layer, .a = 0, .b = 1 };
    const ref35 = PluginSlotRef{ .kind = .kit_layer, .a = 0, .b = 0 };

    // 编辑 38 的参数 → 一条历史
    try std.testing.expect(pl2.params.len > 0);
    app.setPluginParamHost(ref38, pl2, 0, 0.9);
    app.pinPendingGesture();
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len); // 初始 + 38 编辑

    // 编辑 35 的参数 → **必须再出一条**（复现点：旧行为被“无变化”吞掉）
    app.setPluginParamHost(ref35, pl1, 0, 0.9);
    app.pinPendingGesture();
    try std.testing.expectEqual(@as(usize, 3), app.history.items.len); // 初始 + 38 编辑 + 35 编辑

    // 撤销 35 编辑：参数回放（同路径+有增量）或整块 pending 二者必居其一
    try std.testing.expect(app.undo());
    const replayed35 = if (pl1.cacheGet(0)) |v| @abs(v - 0.9) > 0.01 else false;
    try std.testing.expect(replayed35 or app.instruments.items[0].kit.?.find(35).?.layers.items[0].pending_state != null);
    // 38 的编辑应还在（未被连带回退）——活实例或 pending 任一侧保持 0.9
    const kept38 = if (pl2.cacheGet(0)) |v| @abs(v - 0.9) < 0.01 else false;
    const pend38 = app.instruments.items[0].kit.?.find(38).?.layers.items[0].pending_state != null;
    try std.testing.expect(kept38 or pend38);

    // 帧末同步（真实路径）：应用 pending + “已采纳”记账（清脏标）
    app.syncKitLayerPlugins();
    // **回声不得造幽灵条目**（Vital 实症：恢复后 getState 字节与存档不同——
    // 旧行为：留着脏标 → 下一次提交把回声当差异 → 幽灵条目 → “撤销无反应”）
    const n_before = app.history.items.len;
    app.commitHistory("无变化");
    try std.testing.expectEqual(n_before, app.history.items.len);
}

test "app: 鼓组 VST3 层状态去重池（历史捕获）——同内容复用同块" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const inst = app.addDrumkit("鼓组");
    try std.testing.expectEqual(@as(i32, 0), inst);
    try std.testing.expect(app.kitLayerAddVst3(inst, 35, "C:/v/Vital.vst3", "Vital"));
    // 模拟“已恢复的状态”（测试无实例 → pending 分支经 b64 编码入池）
    app.instruments.items[0].kit.?.find(35).?.layers.items[0].pending_state = try std.testing.allocator.dupe(u8, "STATEBYTES");
    app.resetHistory("初始");
    // 与层无关的改动（增益）→ 第二条目；层状态未变 → 池内同块（指针相等）
    app.instruments.items[0].kit.?.find(35).?.layers.items[0].gain = 0.5;
    app.commitHistory("改增益");
    try std.testing.expectEqual(@as(usize, 2), app.history.items.len);
    const s0 = app.history.items[0].instruments[0].kit.pads[0].layers[0].plugin_state;
    const s1 = app.history.items[1].instruments[0].kit.pads[0].layers[0].plugin_state;
    try std.testing.expect(s0.len > 0);
    try std.testing.expectEqual(s0.ptr, s1.ptr);
}

test "app: 保位切换=软切换（播放中）——无重击、off 续排；非保位=硬切换" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.addClip(.{ .track = 0, .start = 384, .len = 96, .pattern = 0 });
    // 跨游标长音符：局部 10..18（局部 15 处正在发声）
    app.addNote(.{ .step = 10, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.openPianoFromClip(app.clips.items[0]);
    app.sel.pattern = 0;
    app.sel.song_mode = false;
    app.playback.piano_step = 15;
    app.playing = true;
    app.params.playing.store(true, .monotonic);
    app.playback.start_step = 15;
    app.playback.start_frame = 0;
    app.params.frames_played.store(15000, .monotonic);
    const gen0 = app.scheduler.gen;
    app.switchSongModePreserving(); // PAT 15 → SONG 384+15=399（保位 → 软）
    try std.testing.expect(app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 399), app.playback.song_step);
    try std.testing.expect(app.scheduler.gen != gen0);
    try std.testing.expectEqual(app.scheduler.gen, app.params.sched_gen.load(.monotonic));
    try std.testing.expect(app.params.sched_gen_soft.load(.monotonic)); // 软标志（待音频消费）
    // 事件：匹配实例不重击（无 on@399）；off 由窗口重扫续上（映射 end = 384+18 = 402）
    var out: [128]synth.SchedEvent = undefined;
    const n = app.sched_events.drain(&out);
    var on399 = false;
    var off402 = false;
    for (out[0..n]) |ev| {
        if (ev.step == 399 and ev.kind == .on) on399 = true;
        if (ev.step == 402 and ev.kind == .off and ev.pitch == 60) off402 = true;
    }
    try std.testing.expect(!on399); // 旧行为（reset+gatherMidOns）会补 on → 重击
    try std.testing.expect(off402); // 声部不悬挂
    // 反向 SONG→PAT 保位：song 399 在窗口内 → piano = 15（软；标志重置模拟音频已消费）
    app.params.sched_gen_soft.store(false, .monotonic);
    const gen1 = app.scheduler.gen;
    app.switchSongModePreserving();
    try std.testing.expect(!app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 15), app.playback.piano_step);
    try std.testing.expect(app.scheduler.gen != gen1);
    try std.testing.expect(app.params.sched_gen_soft.load(.monotonic));
    // 非保位（局部 200 在窗口 [0,96) 外 → 回绕）= 硬切换：软标志清（跳位需释放声部）
    app.playback.piano_step = 200;
    app.switchSongModePreserving();
    try std.testing.expect(app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 384 + 8), app.playback.song_step); // mod(200,96)=8
    try std.testing.expect(!app.params.sched_gen_soft.load(.monotonic));
}

test "app: 关钢琴不再推 all_off（播放中关视图不消音）——只释放在按试听" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.openPiano(0);
    // ① 按住试听（琴键/音符拖动）时关窗：推**定向 off**（不推 all_off）
    app.piano.held_pitch = 62;
    app.closePiano();
    var out: [8]synth.NoteEvent = undefined;
    const n = app.events.drain(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(synth.EventKind.off, out[0].kind);
    try std.testing.expectEqual(@as(u8, 62), out[0].pitch);
    // ② 无在按试听（播放中的常见情形）：**不推任何事件**——播放声部不受影响
    app.openPiano(0);
    app.closePiano();
    try std.testing.expectEqual(@as(usize, 0), app.events.drain(&out));
}

test "app: 滚轮续接改力度即时重扫（修“Ctrl+A 后 Alt+滚轮改力度不及时生效”）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.addNote(.{ .step = 20, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.resetHistory("初始");
    app.sel.pattern = 0;
    app.sel.song_mode = false;
    // 播放中（音频在步 8；音符 20 在未来 → 在已扫过的水位线窗口内）
    app.playing = true;
    app.params.playing.store(true, .monotonic);
    app.playback.piano_step = 8;
    app.playback.start_frame = 0;
    app.playback.start_step = 0;
    app.params.frames_played.store(8000, .monotonic);
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    var drain: [64]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&drain);
    // 第一滚：起手提交临时条目（内部重扫）→ 手势建立
    app.notes.items[0].velocity = 104;
    app.touchGesture("调整力度");
    try std.testing.expect(app.gesture != null);
    const edit1 = app.scheduler.edit_gen;
    // 第二滚（续接）：必须**重扫**（编辑代递增）且窗口内事件带新力度
    app.notes.items[0].velocity = 108;
    app.touchGesture("调整力度");
    try std.testing.expect(app.scheduler.edit_gen != edit1); // ← 旧行为：不变（bug）
    const n = app.sched_events.drain(&drain);
    var found = false;
    for (drain[0..n]) |ev| {
        if (ev.kind == .on and ev.step == 20 and ev.velocity == 108) found = true;
    }
    try std.testing.expect(found);
    // 对照：非音符改动（内容未变）不重扫
    app.pinPendingGesture(); // 钉值：条目归位到最终值
    const edit2 = app.scheduler.edit_gen;
    app.touchGesture("调旋钮");
    try std.testing.expectEqual(edit2, app.scheduler.edit_gen);
}

test "app: PAT ⇄ SONG 保位切换（锚片段映射）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.addClip(.{ .track = 0, .start = 480, .len = 96, .pattern = 0 });
    app.addClip(.{ .track = 0, .start = 960, .len = 96, .pattern = 0 });
    app.openPiano(0);
    // 规则 2：无快照 → 动态最左片段
    try std.testing.expectEqual(@as(i32, 480), app.patOriginClip().?.start);
    // 规则 1：双击来源快照（第二个片段）
    app.openPianoFromClip(app.clips.items[1]);
    try std.testing.expectEqual(@as(i32, 960), app.patOriginClip().?.start);
    // 快照失效（片段被移动）→ 退化到最左
    app.clips.items[1].start = 2000;
    try std.testing.expectEqual(@as(i32, 480), app.patOriginClip().?.start);
    // 回归（实测 bug）：钢琴窗**关闭**时映射仍成立——PAT 播放用的是 sel.pattern，
    // 与 piano.pattern 无关（此前键在 piano.pattern 上：关窗即映射失效）
    app.closePiano();
    app.sel.pattern = 0;
    try std.testing.expectEqual(@as(i32, 480), app.patOriginClip().?.start);
    app.playback.piano_step = 96;
    try std.testing.expectApproxEqAbs(@as(f32, 576), app.patVirtualSongStepFrac(), 0.01);
    // 虚拟位置映射：local 96 → 480 + 96 = 576（锚 = 最左，offset 0）——**显示用原始映射**
    // （显示如实追踪 PAT 位置；回绕只在“切换”时做——见下）
    app.sel.song_mode = false;
    app.playback.piano_step = 96;
    try std.testing.expectApproxEqAbs(@as(f32, 576), app.patVirtualSongStepFrac(), 0.01);
    // 保位切换 PAT→SONG：local 95（窗内）→ song_step = 575
    app.playback.piano_step = 95;
    app.switchSongModePreserving();
    try std.testing.expect(app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 575), app.playback.song_step);
    // SONG→PAT：游标在锚窗口内 → 映射回 20
    app.playback.song_step = 500;
    app.switchSongModePreserving();
    try std.testing.expect(!app.sel.song_mode);
    try std.testing.expectEqual(@as(i32, 20), app.playback.piano_step);
    // 窗口外 → 0（“切到样式从头播”）
    app.sel.song_mode = true;
    app.playback.song_step = 3000;
    app.switchSongModePreserving();
    try std.testing.expectEqual(@as(i32, 0), app.playback.piano_step);

    // **实测 bug 回归**：PAT 局部越出片段窗口（音符比片段长）→ 切换时**回绕进窗口**，
    // 不被 SONG 自动循环抓回 0（此前直接映射 → 越界 → tickPlaybackLoop 跳 0）。
    // 锚 = 最左（start 480，len 96，offset 0）；局部 150 → @mod(150,96)=54 → 534。
    app.sel.song_mode = false;
    app.playback.piano_step = 150;
    app.playing = true;
    app.playback.start_step = 150;
    app.playback.start_frame = 0;
    app.params.frames_played.store(0, .monotonic);
    app.switchSongModePreserving();
    try std.testing.expectEqual(@as(i32, 534), app.playback.song_step);
    app.tickPlaybackLoop(); // 534 < clipsEndStep（2096）→ 不得被抓回 0
    try std.testing.expectEqual(@as(i32, 534), app.playback.song_step);
    app.playing = false;
}

test "app: 游标平滑——前馈+收敛（渲染帧下线性；缓冲量化不显、单调、不跳变）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    app.bpm = 120;
    app.time_den = 4;
    app.params.sample_rate = 48_000; // 1000 帧/步 → 48 步/秒
    app.playback.start_frame = 0;
    app.playback.start_step = 0;
    app.frame_dt_ns = 8_333_333; // ≈120fps：每帧 400 帧音频 ≈ 0.4 步
    app.sel.song_mode = true;
    app.playing = true;

    var frames: u64 = 0;
    var prev: f32 = -1;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        frames += 400; // 音频按缓冲整块推进（量化的来源）
        app.params.frames_played.store(frames, .monotonic);
        app.tickCursorSmooth();
        const d = app.cursorDisplay(true);
        if (i > 20) {
            const mv = d - prev;
            try std.testing.expect(mv >= -0.001); // 单调不回退
            try std.testing.expect(mv <= 0.45); // ≈0.4 步/帧，无跳变
            try std.testing.expect(@abs(d - app.cursorStepFrac(true)) <= 0.45); // 贴近真值（≤ 一个缓冲脉宽）
        }
        prev = d;
    }
    // 跳转（seek/循环回跳）→ 直接归位
    app.playback.start_frame = 100_000;
    app.params.frames_played.store(100_000 + 10_000, .monotonic);
    app.tickCursorSmooth();
    try std.testing.expect(@abs(app.cursorDisplay(true) - app.cursorStepFrac(true)) < 0.01);
    // 停顿 → 冻结整数步
    app.playing = false;
    app.playback.song_step = 5;
    app.tickCursorSmooth();
    try std.testing.expectEqual(@as(f32, 5), app.cursorDisplay(true));
}

test "app: 导出 WAV——离线渲染整曲（长度 = 内容 + 2s 尾；有实际声音）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 极小的“歌”：1 小节 1 个音符 + 1 个片段（渲染量小）
    app.bpm = 240;
    app.time_den = 4;
    app.params.sample_rate = 48_000;
    app.params.volume.store(1.0, .monotonic);
    app.sel.song_mode = true;
    app.addNote(.{ .step = 0, .len = 8, .pitch = 60, .pattern = 0, .instrument = 0 });
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0, .offset = 0 }) catch {};

    // 最小离线引擎（无设备；容量数组由 setCapacity 建立）——生命周期由本测试负责
    app.params.events = &app.events;
    app.params.sched_events = &app.sched_events;
    app.engine.params = &app.params;
    app.engine.allocator = std.testing.allocator;
    try app.engine.setCapacity(app.params.instruments_cap, app.params.channels_cap, app.params.slots_cap);
    defer app.engine.deinit();
    var sp = synth.SynthParams{};
    app.params.synth_ptrs[0].store(&sp, .monotonic);
    app.params.channel_count.store(1, .monotonic);
    app.params.instrument_channel[0].store(0, .monotonic);
    app.params.instrument_gain[0].store(1.0, .monotonic);

    const io = std.testing.io;
    const path = "tmp/export_song_test.wav";
    std.Io.Dir.cwd().createDirPath(io, "tmp") catch {};
    try app.exportSongWav(io, path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("RIFF", data[0..4]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, data[22..24], .little));
    try std.testing.expectEqual(@as(u32, 48_000), std.mem.readInt(u32, data[24..28], .little));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, data[34..36], .little));
    // 长度 = 内容（96 步 × 500 帧/步）+ 2s 尾（48000×2）
    const step_frames: u64 = 48_000 * 60 / (240 * 24);
    const total_frames: u64 = 96 * step_frames + 48_000 * 2;
    try std.testing.expectEqual(@as(usize, @intCast(44 + total_frames * 6)), data.len);
    try std.testing.expectEqual(@as(u32, @intCast(total_frames * 6)), std.mem.readInt(u32, data[40..44], .little));
    // 有实际声音（前 1 秒数据段存在非零字节）
    var nz = false;
    for (data[44..@min(data.len, 44 + 48_000 * 6)]) |b| {
        if (b != 0) {
            nz = true;
            break;
        }
    }
    try std.testing.expect(nz);
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

test "app: 脏标记与历史同源——commitHistory 即标脏，undo 回保存点即不脏" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");
    try std.testing.expect(!app.dirty); // 基线不脏

    // 模拟效果器旋钮等“只设 history_pending”的拖动类编辑（无手动 dirty 置位）
    app.mixer_channels_state.items[0].effects.append(app.allocator, .{ .kind = .compressor }) catch
        return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[0].p[1] = 7.5; // 改个参数
    app.commitHistory("调整效果器参数");
    try std.testing.expect(app.dirty); // ← 以前这里不脏（用户报的 bug）

    // 撤销回保存点 → 不脏；重做 → 又脏
    try std.testing.expect(app.undo());
    try std.testing.expect(!app.dirty);
    try std.testing.expect(app.redo());
    try std.testing.expect(app.dirty);

    // 保存（markSaved）后再编辑 → 脏；撤销回保存点 → 不脏
    app.markSaved();
    try std.testing.expect(!app.dirty);
    app.notes.append(app.allocator, .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 }) catch
        return error.TestUnexpectedResult;
    app.commitHistory("放置音符");
    try std.testing.expect(app.dirty);
    try std.testing.expect(app.undo());
    try std.testing.expect(!app.dirty);
}

test "app: 效果器参数（p）改动进入历史并标脏（回归：“判无变化”坑）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    const s = app.addEffect(0, .reverb) orelse return error.TestUnexpectedResult;
    app.commitHistory("添加效果器");

    // 模拟面板旋钮：只改 es.p[0]（以前会被 stateEqualsCurrent 判“无变化”）
    const n0 = app.history.items.len;
    app.mixer_channels_state.items[0].effects.items[s].p[0] = 0.1;
    app.commitHistory("调整效果器参数");
    try std.testing.expectEqual(n0 + 1, app.history.items.len); // ← 修复前这里判“无变化”进不了
    try std.testing.expect(app.dirty);

    // 撤销返回；同值再提交 → 不产生条目（等值挡重复）
    try std.testing.expect(app.undo());
    const n1 = app.history.items.len;
    app.commitHistory("调整效果器参数");
    try std.testing.expectEqual(n1, app.history.items.len);
}

test "app: 播放中撤销/点历史——不停播，走编辑重扫（回归：Ctrl+Z 导致暂停）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 音符编辑提交（历史 1）：放一个跨游标音符（游标=8）
    app.addNote(.{ .step = 20, .len = 4, .pitch = 62, .pattern = 0, .instrument = 0 });
    app.commitHistory("放置音符");

    // 模拟播放中（音频已走到 8；48k/120bpm → 1000 帧/步）
    app.playing = true;
    app.params.playing.store(true, .monotonic);
    app.sel.song_mode = false;
    app.playback.piano_step = 8;
    app.playback.start_frame = 0;
    app.playback.start_step = 0;
    app.params.frames_played.store(8000, .monotonic);
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, false, 0, 0, 32);
    var out: [8]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&out);

    // 撤销 → **不停播**（关键回归点）；且走编辑重扫（编辑代递增 + 发布）
    const edit0 = app.scheduler.edit_gen;
    try std.testing.expect(app.undo());
    try std.testing.expect(app.playing); // ← 以前这里被 stopPlayback 打断
    try std.testing.expect(app.params.playing.load(.monotonic));
    try std.testing.expect(app.scheduler.edit_gen != edit0); // 重扫代递增
    try std.testing.expectEqual(app.scheduler.edit_gen, app.params.sched_edit_gen.load(.monotonic));
    // **不置鼓组池重置/回收**（实测 bug 修复：置位会让帧末 pollCapacityReclaim
    // 暂停/恢复设备 → 撤销/重做音符编辑“卡一下 + 爆音”；直接编辑不置位所以无缝）
    try std.testing.expect(!app.kit_reset);
    try std.testing.expect(!app.kit_gc_pending);

    // 重做 → 同样不停播
    try std.testing.expect(app.redo());
    try std.testing.expect(app.playing);
    try std.testing.expect(app.params.playing.load(.monotonic));

    // 点历史条目跳转 → 不停播
    try std.testing.expect(app.jumpHistory(0));
    try std.testing.expect(app.playing);
    try std.testing.expect(app.params.playing.load(.monotonic));
    try std.testing.expect(!app.kit_reset);
    try std.testing.expect(!app.kit_gc_pending);

    // 停止态跳转：不触发重扫（编辑代不变）
    app.playing = false;
    app.params.playing.store(false, .monotonic);
    const edit1 = app.scheduler.edit_gen;
    try std.testing.expect(app.jumpHistory(1));
    try std.testing.expectEqual(edit1, app.scheduler.edit_gen);
}

test "app: 撤销——乐器数量变化（重建）才置鼓组池重置（设备暂停仅限罕见重建路径）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");
    _ = app.addInstrument("减法合成器");
    app.commitHistory("添加乐器");
    // 撤销：2 → 1（重建路径）→ 置位（下标重排，池不再对应）
    try std.testing.expect(app.undo());
    try std.testing.expect(app.kit_reset);
    try std.testing.expect(app.kit_gc_pending);
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

    // 调音台右键菜单（通道/效果器/声像）——实测 bug：漏项 → 点击穿透到通道条
    app.mixer_win.ctx_channel = 0;
    try std.testing.expect(app.menuIsOpen());
    app.mixer_win.ctx_channel = null;
    app.mixer_win.ctx_effect = .{ .ch = 0, .slot = 0 };
    try std.testing.expect(app.menuIsOpen());
    app.mixer_win.ctx_effect = null;
    app.mixer_win.ctx_pan = 0;
    try std.testing.expect(app.menuIsOpen());
    app.mixer_win.ctx_pan = null;

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

    // 上限（≈十亿，不可达）——“装满后拒绝”无法再靠填满测试（会挂）；
    // 该分支就是 `addPattern` 里一行 `>= max_patterns` 比较。
}

test "app: 轨道轴——行跨度推导（保底+留白）、片段下缘生长、清空无重映射" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();

    // 空工程：最短行程 128 行
    try std.testing.expectEqual(@as(i32, 128), app.trackCount());
    try std.testing.expectEqualStrings("Track 1", app.trackName(0));
    try std.testing.expectEqualStrings("Track 32", app.trackName(31));

    // 片段放到第 40 行（0 起）→ 低于最短行程 → 仍 128
    app.clips.append(app.allocator, .{ .track = 40, .start = 0, .len = 48, .pattern = 0 }) catch {};
    try std.testing.expectEqual(@as(i32, 128), app.trackCount());

    // 放到第 200 行 → 按内容推导：200 + 1 + 3 留白
    app.clips.append(app.allocator, .{ .track = 200, .start = 0, .len = 48, .pattern = 0 }) catch {};
    try std.testing.expectEqual(@as(i32, 204), app.trackCount());

    // 空行清空：无事发生
    app.clips.append(app.allocator, .{ .track = 0, .start = 96, .len = 48, .pattern = 0 }) catch {};
    try std.testing.expectEqual(@as(usize, 0), app.clearTrackData(5));
    try std.testing.expectEqual(@as(usize, 3), app.clips.items.len);

    // 清空第 200 行 → 片段删、其余**不重映射**、跨度收回最短行程
    try std.testing.expectEqual(@as(usize, 1), app.trackUsage(200));
    try std.testing.expectEqual(@as(usize, 1), app.clearTrackData(200));
    try std.testing.expectEqual(@as(usize, 2), app.clips.items.len);
    try std.testing.expectEqual(@as(i32, 40), app.clips.items[0].track); // swapRemove：尾项顶上
    try std.testing.expectEqual(@as(i32, 0), app.clips.items[1].track);
    try std.testing.expectEqual(@as(i32, 128), app.trackCount());
}

test "app: 轨道重命名（文本输入提交）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetHistory("初始状态");

    app.beginRenameTrack(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('鼓');
    app.textInputCommit();
    try std.testing.expectEqualStrings("鼓", app.trackName(1));
    try std.testing.expectEqualStrings("Track 1", app.trackName(0));
}

test "app: 轨道名随存档导出/导入（稀疏保留；旧档无字段=全默认；跨度由片段推导）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 改名第 2 条 → “鼓”
    app.beginRenameTrack(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('鼓');
    app.textInputCommit();

    const proj = try app.exportProject();
    defer app.freeProject(proj);

    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expectEqual(@as(i32, 128), app2.trackCount());
    try std.testing.expectEqualStrings("Track 1", app2.trackName(0));
    try std.testing.expectEqualStrings("鼓", app2.trackName(1));
    try std.testing.expectEqualStrings("Track 3", app2.trackName(2)); // 未命名 → 合成

    // 旧存档（无 track_names）+ 第 40 行片段 → 跨度自动覆盖到 44，名字全默认
    var l2 = proj;
    l2.track_names = &.{};
    const clips = try app2.allocator.alloc(persist.SavedClip, 1);
    defer app2.allocator.free(clips);
    clips[0] = .{ .track = 40, .start = 0, .len = 48, .pattern = 0 };
    l2.clips = clips;
    l2.notes = &.{};
    l2.instruments = &.{};
    l2.mixer = &.{};
    l2.pattern_count = 1;
    l2.pattern_names = &.{};

    var app3 = App{ .allocator = std.testing.allocator };
    defer app3.clips.deinit(app3.allocator);
    defer app3.notes.deinit(app3.allocator);
    defer app3.deinitAll();
    app3.resetMixerChannels(default_mixer_channels);
    app3.importProject(l2);
    try std.testing.expectEqual(@as(i32, 128), app3.trackCount()); // 40 行片段低于最短行程 → 128
    try std.testing.expectEqualStrings("Track 41", app3.trackName(40));
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
    // 未实装插件（unknown/vst3）不可选
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, preset_mod.plugin_subtractive));
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, preset_mod.plugin_drumkit));
    try std.testing.expect(!app.presetCategorySelectable(.{ .replace = .{ .instrument = syn } }, "future_synth"));
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .instrument = kit } }, preset_mod.plugin_drumkit));

    // replace + **鼓组层**：仅减法（层目前只支持减法；鼓组禁自嵌套）
    const layer_ref = PresetTarget.KitLayerRef{ .instrument = kit, .pitch = 35, .layer = 0 };
    try std.testing.expect(app.presetCategorySelectable(.{ .replace = .{ .kit_layer_replace = layer_ref } }, preset_mod.plugin_subtractive));
    try std.testing.expect(!app.presetCategorySelectable(.{ .replace = .{ .kit_layer_replace = layer_ref } }, preset_mod.plugin_drumkit));

    // 新建/更换乐器：减法 + 鼓组（已实装）；unknown/vst3 不可选
    try std.testing.expect(app.presetCategorySelectable(.create_instrument, preset_mod.plugin_subtractive));
    try std.testing.expect(app.presetCategorySelectable(.create_instrument, preset_mod.plugin_drumkit));
    try std.testing.expect(!app.presetCategorySelectable(.create_instrument, "future_synth"));
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
    defer app.freeSavedKit(&snap, false);
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

test "app: 主通道（下标 0）永久锁定——不可移动/被换位，但可重命名" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(3);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 给通道 1/2 改名以便验证交换
    app.beginRenameMixerChannel(1, 0, 0);
    app.textInputAppend('A');
    app.textInputCommit();
    app.beginRenameMixerChannel(2, 0, 0);
    app.textInputAppend('B');
    app.textInputCommit();

    // ① 主通道自身不可移动（上下都拒）
    try std.testing.expect(!app.moveMixerChannel(0, 1));
    try std.testing.expect(!app.moveMixerChannel(0, -1));
    // ② 其它通道“上移”到主通道位置 → 也拒绝（否则主通道会被换走）
    try std.testing.expect(!app.moveMixerChannel(1, -1));
    // ③ 非主通道之间正常交换
    try std.testing.expect(app.moveMixerChannel(2, -1));
    var nb: [24]u8 = undefined;
    try std.testing.expectEqualStrings("B", app.mixer_channels_state.items[1].displayName(1, &nb));
    try std.testing.expectEqualStrings("A", app.mixer_channels_state.items[2].displayName(2, &nb));
    try std.testing.expectEqualStrings("主通道", app.mixer_channels_state.items[0].displayName(0, &nb));
    try std.testing.expect(app.moveMixerChannel(1, 1)); // 换回

    // ④ 主通道重命名仍允许（用户约定：只锁移动）
    app.beginRenameMixerChannel(0, 0, 0);
    app.textInputAppend('M');
    app.textInputCommit();
    try std.testing.expectEqualStrings("M", app.mixer_channels_state.items[0].displayName(0, &nb));
}

test "app: 效果器可叠加同种（用户拍板）；默认参数随类型填装" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(2);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 混合叠加：同种可多次（用户要叠两个混响/延迟做特殊效果）
    const s0 = app.addEffect(0, .reverb) orelse return error.TestUnexpectedResult;
    const s1 = app.addEffect(0, .reverb) orelse return error.TestUnexpectedResult;
    try std.testing.expect(s1 != s0);
    const s_d = app.addEffect(0, .delay) orelse return error.TestUnexpectedResult;
    const s_c = app.addEffect(0, .compressor) orelse return error.TestUnexpectedResult;
    // EQ 可多个（历史语义：参数由链上首个 EQ 共享）
    try std.testing.expect(app.addEffect(0, .eq) != null);
    try std.testing.expect(app.addEffect(0, .eq) != null);
    // 另一通道不受影响
    try std.testing.expect(app.addEffect(1, .reverb) != null);

    // 默认参数：与 `fx.defaultParams` 一致（混响首位 = 空间默认，非全零）
    const es_r = &app.mixer_channels_state.items[0].effects.items[s0];
    const defs = fx.defaultParams(@backingInt(EffectKind.reverb));
    try std.testing.expectEqual(defs[0], es_r.p[0]);
    try std.testing.expectEqual(defs[1], es_r.p[1]);
    try std.testing.expect(es_r.p[0] > 0);
    // 干湿默认：混响/延迟**不全湿**（全湿 = 干声被吞——实测反馈“第一个音要等一个延迟时间才响”）
    try std.testing.expectEqual(@as(f32, 0.30), es_r.mix);
    try std.testing.expectEqual(@as(f32, 0.35), app.mixer_channels_state.items[0].effects.items[s_d].mix);
    try std.testing.expectEqual(@as(f32, 1.0), app.mixer_channels_state.items[0].effects.items[s_c].mix); // 压缩器全压
}

test "audio/app: 每槽状态盒——同种叠加各自独立、换 kind 替换、移除退役" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(1);
    app.resetHistory("初始");

    _ = app.addEffect(0, .reverb);
    _ = app.addEffect(0, .reverb);
    const chain = &app.mixer_channels_state.items[0].effects;
    app.syncFxStateForSlot(0, 0, &chain.items[0]);
    app.syncFxStateForSlot(0, 1, &chain.items[1]);
    const box0 = chain.items[0].fx_state orelse return error.NoState;
    const box1 = chain.items[1].fx_state orelse return error.NoState;
    try std.testing.expect(box0 != box1); // 两个混响状态各自独立
    try std.testing.expectEqual(@as(u8, 2), box0.kind);
    try std.testing.expect(app.params.fx_ptrs[0][0].load(.monotonic) == box0);
    try std.testing.expect(app.params.fx_ptrs[0][1].load(.monotonic) == box1);

    // 换 kind（混响→延迟）：旧盒退役，新盒发布
    chain.items[1].kind = .delay;
    app.syncFxStateForSlot(0, 1, &chain.items[1]);
    const box1b = chain.items[1].fx_state orelse return error.NoState;
    try std.testing.expect(box1b != box1);
    try std.testing.expectEqual(@as(u8, 3), box1b.kind);
    try std.testing.expect(app.retired_fx.items.len >= 1); // 旧盒在退役列表

    // 移除槽：退役 + 指针即时清零
    app.removeEffect(0, 1);
    try std.testing.expect(app.params.fx_ptrs[0][1].load(.monotonic) == null);

    // 倒计时走完 → 列表清空（无泄漏——测试分配器兑底）
    var i: usize = 0;
    while (i < 40) : (i += 1) app.reapRetiredFx();
    try std.testing.expectEqual(@as(usize, 0), app.retired_fx.items.len);
}

test "app: 导入存档——延迟 p[0] 旧毫秒值迁移为节奏档位码" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(2);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    // 模拟旧档：延迟 p[0] = 375（毫秒时代的越界值）
    var mixer = [_]persist.SavedMixerChannel{
        .{
            .name = "A",
            .effect_count = 1,
            .effects = &.{
                .{ .kind = 3, .p = .{ 375, 0.35, 0, 0, 0 } },
            },
        },
    };
    app.importMixerChannels(&mixer, null, 0, 0);
    const chain = app.mixer_channels_state.items[0].effects;
    try std.testing.expectEqual(@as(usize, 1), chain.items.len);
    try std.testing.expectEqual(@as(f32, @floatFromInt(fx.delay_tempo_default)), chain.items[0].p[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), chain.items[0].p[1], 0.0001); // 反馈语义未变

    // 新档合法码值不受迁移影响
    var mixer2 = [_]persist.SavedMixerChannel{
        .{
            .name = "B",
            .effect_count = 1,
            .effects = &.{
                .{ .kind = 3, .p = .{ 2, 0.5, 0, 0, 0 } },
            },
        },
    };
    app.importMixerChannels(&mixer2, null, 0, 0);
    const chain2 = app.mixer_channels_state.items[0].effects;
    try std.testing.expectEqual(@as(f32, 2), chain2.items[0].p[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), chain2.items[0].p[1], 0.0001);
}

test "app: 新建（空）工程——1 样式 + Track1 最左 1 片段 + 1 乐器" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(model.default_pattern_count);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    _ = app.addInstrument("减法合成器");
    app.addNote(.{ .step = 0, .len = 4, .pitch = 60, .pattern = 3, .instrument = 0 });
    app.addClip(.{ .track = 5, .start = 480, .len = 96, .pattern = 2 });
    app.bpm = 90;
    app.resetHistory("初始状态");

    app.resetToDefaultProject();
    try std.testing.expectEqual(@as(i32, 1), app.patternCount());
    try std.testing.expectEqual(@as(usize, 0), app.notes.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.clips.items.len);
    const c = app.clips.items[0];
    try std.testing.expectEqual(@as(i32, 0), c.track);
    try std.testing.expectEqual(@as(i32, 0), c.start);
    try std.testing.expectEqual(@as(i32, 0), c.pattern);
    try std.testing.expectEqual(app.patternEffectiveLen(0), c.len);
    try std.testing.expect(c.len >= 96); // 空样式 = 至少 1 小节
    try std.testing.expectEqual(@as(usize, 1), app.instruments.items.len);
    try std.testing.expectEqual(@as(i32, 120), app.bpm);
    try std.testing.expectEqual(@as(i32, 0), app.sel.pattern);
    try std.testing.expectEqual(@as(i32, 0), app.sel.instrument);
    try std.testing.expect(!app.dirty); // 新建 = 已保存基线
    try std.testing.expectEqual(@as(usize, 1), app.history.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.history_current);
}

test "app: 插件槽——添加 / 存档往返（plugin_path）/ 无实例删除不退役" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    _ = app.addInstrument("减法合成器");
    app.resetHistory("初始状态");

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    {
        const es = &app.mixer_channels_state.items[0].effects.items[slot];
        es.setPluginPath("C:\\fake\\test.vst3");
        try std.testing.expectEqualStrings("C:\\fake\\test.vst3", es.pluginPath());
    }
    // 存档导出：plugin_path 落盘
    const saved = try app.exportMixerChannels(std.testing.allocator, false, false);
    defer {
        app.freeSavedMixerChannels(saved, false);
        std.testing.allocator.free(saved);
    }
    try std.testing.expect(saved.len >= 1);
    try std.testing.expectEqual(@as(u32, 1), saved[0].effect_count);
    try std.testing.expect(saved[0].effects[0].plugin_path.len > 0);
    try std.testing.expect(std.mem.eql(u8, "C:\\fake\\test.vst3", saved[0].effects[0].plugin_path));
    try std.testing.expectEqualStrings("C:\\fake\\test.vst3", saved[0].effects[0].plugin_path);

    // 导入回（现有链无实例——退役路径不应误判）
    app.importMixerChannels(saved, null, 0, 0);
    try std.testing.expectEqualStrings("C:\\fake\\test.vst3", app.mixer_channels_state.items[0].effects.items[0].pluginPath());
    try std.testing.expectEqual(@as(usize, 0), app.retired_plugins.items.len);

    // 删除（plugin == null）：不产生退役项
    app.removeEffect(0, 0);
    try std.testing.expectEqual(@as(usize, 0), app.retired_plugins.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.mixer_channels_state.items[0].effects.items.len);
}

test "插件实例：deinitAll 同步卸载链上实例与退役项（无泄漏）" {
    // 用 zig-vst3 自带示例 DLL 真加载（缺失则跳过——示例未构建的环境）
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll(); // 引擎已停的退出路径：两处都必须同步卸载
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    const slot = app.addEffect(0, .plugin) orelse {
        vst_host.unloadPlugin(std.testing.allocator, pl);
        return error.TestUnexpectedResult;
    };
    app.mixer_channels_state.items[0].effects.items[slot].plugin = pl;
    // 再造一个“退役未到期”的实例（模拟退出前 30 帧内删掉的插件）
    const pl2 = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    app.retirePlugin(pl2);
}

test "VST3 参数：元数据/设置/音频生效/编辑器编辑轮询" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl);

    // 参数缓存（名称非空）
    try std.testing.expectEqual(@as(usize, 1), pl.paramCount());
    try std.testing.expect(pl.params[0].name().len > 0);

    // 宿主设置 → 控制器与音频两侧生效（zig-vst3 的 gain：归一化值 = 线性增益）
    pl.setParamHost(0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pl.paramNorm(0), 0.0001);
    var buf: [512 * 2]f32 = undefined;
    for (&buf) |*v| v.* = 1.0;
    pl.process(&buf, 512);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buf[1023], 0.001);

    // 插件 GUI 内编辑 → 去重轮询
    const h = pl.handler_obj orelse return error.TestUnexpectedResult;
    _ = h.iface.vtable.performEdit(&h.iface, 424242, 0.7);
    const pe = pl.pollEditorEdit() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 424242), pe.id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), pe.value, 0.0001);
    try std.testing.expect(pl.pollEditorEdit() == null);
}

test "VST3 状态：捕获/恢复往返（参数值保留、音频生效）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const p1 = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, p1);
    p1.setParamHost(0, 0.4);
    const blobs = p1.captureState(std.testing.allocator);
    defer blobs.deinit(std.testing.allocator);
    try std.testing.expect(blobs.comp.len > 0);

    const p2 = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, p2);
    p2.restoreState(blobs.comp, blobs.ctrl);
    var buf: [256 * 2]f32 = undefined;
    for (&buf) |*v| v.* = 1.0;
    p2.process(&buf, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), buf[0], 0.01);
}

test "VST3 状态：工程存档往返（base64 → pending 解码 → 恢复）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    const slot = app.addEffect(0, .plugin) orelse {
        vst_host.unloadPlugin(std.testing.allocator, pl);
        return error.TestUnexpectedResult;
    };
    const es = &app.mixer_channels_state.items[0].effects.items[slot];
    es.setPluginPath("libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll");
    es.plugin = pl;
    pl.setParamHost(0, 0.3);

    // 导出（含状态）→ JSON 往返
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    try std.testing.expect(proj.mixer[0].effects[0].plugin_state.len > 0);
    const json = try persist.toJson(app.allocator, proj);
    defer app.allocator.free(json);
    var parsed = try persist.fromJson(app.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.mixer[0].effects[0].plugin_state.len > 0);

    // 第二个 app 导入（模拟打开工程）→ pending 就绪 → 手动应用 → 参数值保留
    var app2 = App{ .allocator = std.testing.allocator };
    app2.resetPatterns(1);
    app2.resetMixerChannels(default_mixer_channels);
    defer app2.deinitAll();
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    app2.importMixerChannels(parsed.value.mixer, null, 0, 0);
    const es2 = &app2.mixer_channels_state.items[0].effects.items[0];
    try std.testing.expectEqual(EffectKind.plugin, es2.kind);
    try std.testing.expect(es2.pending_state != null);
    try std.testing.expect(es2.pluginPath().len > 0);
    const pl2 = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl2);
    pl2.restoreState(es2.pending_state orelse &.{}, es2.pending_state_ctrl orelse &.{});
    var buf: [256 * 2]f32 = undefined;
    for (&buf) |*v| v.* = 1.0;
    pl2.process(&buf, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), buf[0], 0.01);
}

test "VST3 乐器：无输入插件按乐器角色加载与 process（sine-synth 示例）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    // 效果器角色：应报 NoMainInput（它没有主音频输入）
    if (vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .effect)) |pl| {
        vst_host.unloadPlugin(std.testing.allocator, pl);
        return error.TestUnexpectedResult; // 预期失败（否则它被当作效果器了）
    } else |e| {
        try std.testing.expectEqual(error.NoMainInput, e);
    }
    // 乐器角色：加载 ✓、无输入 ✓、process 数值有限
    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl);
    try std.testing.expect(!pl.has_input);
    var buf: [512 * 2]f32 = undefined;
    @memset(&buf, 0);
    pl.process(&buf, 512);
    for (buf) |v| try std.testing.expect(std.math.isFinite(v));
}

test "VST3 乐器：音符事件送达插件（sine-synth：noteOn 发声、noteOff 停）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl);

    const note_on = ivstevents.Event{
        .sampleOffset = 0,
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOnEvent),
        .data = .{ .noteOn = .{ .channel = 0, .pitch = 69, .velocity = 1.0, .noteId = -1 } },
    };
    const note_off = ivstevents.Event{
        .sampleOffset = 0,
        .type = @backingInt(ivstevents.Event.EventTypes.kNoteOffEvent),
        .data = .{ .noteOff = .{ .channel = 0, .pitch = 69, .velocity = 0, .noteId = -1 } },
    };

    var buf: [1024 * 2]f32 = undefined;
    // 无事件 → 静音（sine-synth 无音符不发声）
    @memset(&buf, 0);
    pl.processInstrument(&buf, 1024, &.{}, .{});
    var e0: f64 = 0;
    for (buf) |v| e0 += @as(f64, v) * v;
    try std.testing.expect(e0 < 1e-9);

    // noteOn(69) → 有声
    @memset(&buf, 0);
    pl.processInstrument(&buf, 1024, &.{note_on}, .{});
    var e1: f64 = 0;
    for (buf) |v| e1 += @as(f64, v) * v;
    try std.testing.expect(e1 > 1e-9);

    // noteOff → 停（先喂 off 块，再验证后续块静音）
    @memset(&buf, 0);
    pl.processInstrument(&buf, 128, &.{note_off}, .{});
    @memset(&buf, 0);
    pl.processInstrument(&buf, 1024, &.{}, .{});
    var e2: f64 = 0;
    for (buf) |v| e2 += @as(f64, v) * v;
    try std.testing.expect(e2 < 1e-9);
}

test "VST3 乐器：音色随工程存档与撤销往返（pending → restoreState）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return;

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const ni = app.addInstrumentVst3("libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll");
    try std.testing.expect(ni >= 0);
    const idx: usize = @intCast(ni);
    app.instruments.items[idx].plugin = pl;
    const iref = PluginSlotRef{ .kind = .instrument, .a = @intCast(idx) };
    pl.refreshParamCache(); // 生产：实例就绪帧自动建齐（测试手动）
    app.commitHistory("接入插件"); // 快照携带默认音色（0.1）
    app.setPluginParamHost(iref, pl, 0, 0.5); // level = 0.5（唯一入口：应用 + 记录增量）
    app.pinPendingGesture();

    // 工程导出（含乐器 state）→ JSON 往返
    const proj = try app.exportProject();
    defer app.freeProject(proj);
    try std.testing.expect(proj.instruments[0].plugin_state.len > 0);
    const json = try persist.toJson(app.allocator, proj);
    defer app.allocator.free(json);
    var parsed = try persist.fromJson(app.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.instruments[0].plugin_state.len > 0);

    // 改音色 → 钉值 → 撤销 → **参数回放**（不整块 setState；pending 保持空）→ 回退 0.5
    app.setPluginParamHost(iref, pl, 0, 0.2);
    app.pinPendingGesture();
    try std.testing.expect(app.undo());
    const inst = &app.instruments.items[idx];
    try std.testing.expect(inst.pending_state == null); // 增量回放：无需整块恢复
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pl.paramNorm(0), 0.01); // 回放 old
    // 重做 → 回放 new（0.2）
    try std.testing.expect(app.redo());
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), pl.paramNorm(0), 0.01);
}

test "工程加载恢复后：插件回声字节不算编辑（单击不产生幽灵历史）" {
    // Vital 实测陷阱：setState(自己的存档字节) 后再 getState，字节不同（插件重归一化）——
    // 若非“已采纳”处理：①单击片段提交→幽灵历史条目（实测 v4 工程）；
    // ②幽灵条目 blob 与基线不同 → 条目间跳转每次对全部实例整块 setState（卡顿）。
    const vital_path = "C:\\Program Files\\Common Files\\VST3/Vital.vst3";
    const dll_z = std.testing.allocator.dupeSentinel(u8, vital_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return; // 未安装 → 跳过

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);

    const ni = app.addInstrumentVst3(vital_path);
    try std.testing.expect(ni >= 0);
    const idx: usize = @intCast(ni);
    app.instruments.items[idx].plugin = pl;
    const iref = PluginSlotRef{ .kind = .instrument, .a = @intCast(idx) };
    app.resetHistory("打开工程"); // E0 = “存档字节”

    // 模拟“加载工程走一遍恢复”：pending(来自 E0) → 恢复 → **按已采纳标 clean**（修复后契约）
    const si = app.history.items[0].instruments[0];
    app.applySavedInstrument(&si, &app.instruments.items[idx], .full, 0, 0);
    const inst = &app.instruments.items[idx];
    const archive_raw = try std.testing.allocator.dupe(u8, inst.pending_state orelse &.{}); // 存档原始字节
    defer std.testing.allocator.free(archive_raw);
    pl.restoreState(archive_raw, inst.pending_state_ctrl orelse &.{});
    inst.clearPendingState(app.allocator);
    app.markSlotStateClean(iref);

    // 前提：恢复回声确实与存档字节不同（插件已守恒时本场景不存在 → 跳过）
    const st = pl.captureState(std.testing.allocator);
    defer st.deinit(std.testing.allocator);
    if (std.mem.eql(u8, st.comp, archive_raw)) return;

    // ① 修复后：clean → 单击片段提交 → **不产生新条目**
    const before = app.history.items.len;
    app.commitHistory("移动片段");
    try std.testing.expectEqual(before, app.history.items.len);

    // ② 对照（修复前语义）：留着脏标 → 回声被当差异 → 幽灵条目，且其 blob ≠ 存档
    //    （这正是“两条目间跳转整块 setState → 卡顿”的源头）
    app.markSlotStateDirty(iref);
    app.commitHistory("移动片段");
    try std.testing.expectEqual(before + 1, app.history.items.len);
    try std.testing.expect(!std.mem.eql(u8, app.history.items[before].instruments[0].plugin_state, si.plugin_state));
}

test "就地替换插件状态记账：提交建条目且快照现取（预设加载路径回归锁）" {
    const dll_path = "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll";
    const dll_z = std.testing.allocator.dupeSentinel(u8, dll_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[slot].setPluginPath(dll_path);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    app.mixer_channels_state.items[0].effects.items[slot].plugin = pl;
    const fref = PluginSlotRef{ .kind = .fx, .a = 0, .b = @intCast(slot) };
    pl.refreshParamCache();
    app.markSlotStateDirty(fref);
    pl.setParamHost(0, 0.3);
    app.commitHistory("接入插件"); // E_before：blob = 状态(0.3)

    // 造一份“另一状态”的字节（0.7），然后让 live 回到 0.3（== 当前条目）
    pl.setParamHost(0, 0.7);
    const st = pl.captureState(std.testing.allocator);
    defer st.deinit(std.testing.allocator);
    pl.setParamHost(0, 0.3);

    // 模拟预设加载（main.loadVst3Preset 的就地路径）：恢复 + 记账
    const before = app.history.items.len;
    pl.restoreState(st.comp, st.ctrl);
    app.notePluginStateReplaced(fref, "加载预设");

    // 条目建立 + 快照**现取**（blob 与上一条不同——不置脏的旧实现会静默丢弃或复用旧 blob）
    try std.testing.expectEqual(before + 1, app.history.items.len);
    try std.testing.expect(app.dirty and app.plugin_dirty);
    const prev_blob = app.history.items[before - 1].mixer[0].effects[slot].plugin_state;
    const new_blob = app.history.items[before].mixer[0].effects[slot].plugin_state;
    try std.testing.expect(!std.mem.eql(u8, prev_blob, new_blob));
    // 撤销 → 结构路径无增量 → 整块恢复 pending 就绪
    try std.testing.expect(app.undo());
    const es_u = &app.mixer_channels_state.items[0].effects.items[slot];
    try std.testing.expect(es_u.pending_state != null);
}

test "编辑器参数手势切分规则：不同（槽/参数）的 begin 钉住当前手势；同参数续接" {
    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const fa = PluginSlotRef{ .kind = .fx, .a = 0, .b = 0 };
    const fb = PluginSlotRef{ .kind = .fx, .a = 0, .b = 1 };
    const fi = PluginSlotRef{ .kind = .instrument, .a = 0 };

    // 造一个“A 手势”（临时条目 = 当前顶条，满足 pin 的 index 前提）
    app.gesture = .{ .label = "调整插件参数：A", .last_change_frame = 0, .index = app.history_current };
    if (app.gesture) |*g| {
        try g.param_edits.append(app.allocator, .{ .ref = fa, .param_id = 7, .old = 0.1, .new = 0.5 });
    }

    // 同参数 begin → 续接（手势保持）
    app.splitGestureOnBegin(fa, 7);
    try std.testing.expect(app.gesture != null);

    // 同槽不同参数 begin → 切：钉住当前手势（顶条目收官，label 保留）并清空手势
    app.splitGestureOnBegin(fa, 8);
    try std.testing.expect(app.gesture == null);
    try std.testing.expectEqualStrings("调整插件参数：A", app.history.items[app.history.items.len - 1].label);

    // 跨槽（不同槽 + 跨到乐器槽，同 ID）→ 同样切
    app.gesture = .{ .label = "调整插件参数：B", .last_change_frame = 0, .index = app.history_current };
    if (app.gesture) |*g| {
        try g.param_edits.append(app.allocator, .{ .ref = fb, .param_id = 7, .old = 0.0, .new = 0.2 });
    }
    app.splitGestureOnBegin(fi, 7);
    try std.testing.expect(app.gesture == null);
}

/// 测试辅助：“插件 GUI 内部”改参（只动控制器值、绕开宿主缓存/推送）——
/// 真实顺序 = 先插件内部变化（本函数）、再 begin/perform/end 通知宿主。
fn guiSetParam(pl: *vst_host.Plugin, idx: usize, v: f64) void {
    const c = pl.controller orelse return;
    const rc = pl.raw_controller orelse return;
    _ = c.vtable.setParamNormalized(rc, pl.params[idx].id, v);
}

test "编辑器参数手势：同旋钮连拧合并为一条（静置语义；撤销一次全回退）" {
    const dll_path = "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll";
    const dll_z = std.testing.allocator.dupeSentinel(u8, dll_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[slot].setPluginPath(dll_path);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    app.mixer_channels_state.items[0].effects.items[slot].plugin = pl;
    const fref = PluginSlotRef{ .kind = .fx, .a = 0, .b = @intCast(slot) };
    pl.setParamHost(0, 0.31); // 专属基线（免与其它测试残留相撞）
    pl.refreshParamCache();
    app.markSlotStateDirty(fref);
    // 通道命名（效果器归属名进标签）
    {
        const mc0 = &app.mixer_channels_state.items[0];
        const cname = "Pedalboard";
        @memcpy(mc0.name[0..cname.len], cname);
        mc0.name_len = cname.len;
    }
    app.resetHistory("初始");
    const vbase = pl.paramNorm(0);

    const h = pl.handler_obj orelse return error.TestUnexpectedResult;
    const id = pl.params[0].id;

    // 一拧（GUI 内部改值 → begin/perform/end 通知）
    _ = h.iface.vtable.beginEdit(&h.iface, id);
    guiSetParam(pl, 0, 0.6);
    _ = h.iface.vtable.performEdit(&h.iface, id, 0.6);
    _ = h.iface.vtable.endEdit(&h.iface, id);
    app.drainSlotEditorEdits(fref, pl);
    // 立刻二拧（同参数 begin → 不切分）
    _ = h.iface.vtable.beginEdit(&h.iface, id);
    guiSetParam(pl, 0, 0.9);
    _ = h.iface.vtable.performEdit(&h.iface, id, 0.9);
    _ = h.iface.vtable.endEdit(&h.iface, id);
    app.drainSlotEditorEdits(fref, pl);
    try std.testing.expect(app.gesture != null); // 手势续接中（未切）

    const n = app.history.items.len; // temp 条目
    app.pinPendingGesture();
    try std.testing.expectEqual(n, app.history.items.len); // 合并：仍是一条
    // 标签 = “{归属名}: {参数名}”（效果器 → 通道名）
    try std.testing.expect(std.mem.startsWith(u8, app.history.items[n - 1].label, "Pedalboard"));
    try std.testing.expect(std.mem.endsWith(u8, app.history.items[n - 1].label, pl.params[0].name()));

    // 撤销一次 → 两拧一起回退（合并证明）
    try std.testing.expect(app.undo());
    try std.testing.expectApproxEqAbs(vbase, pl.paramNorm(0), 1e-6);
}

test "编辑器参数手势：同一插件换旋钮切历史（Vital 实测场景：Level→Pan）" {
    const vital_path = "C:\\Program Files\\Common Files\\VST3/Vital.vst3";
    const dll_z = std.testing.allocator.dupeSentinel(u8, vital_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return; // 未安装 → 跳过
    // 探针实测的 Vital 参数（版本差异 → 不存在则跳过）
    const li = pl.findParamIndex(50797) orelse return; // Oscillator 1 Level
    const pi = pl.findParamIndex(50800) orelse return; // Oscillator 1 Pan

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);

    const ni = app.addInstrumentVst3(vital_path);
    try std.testing.expect(ni >= 0);
    const idx: usize = @intCast(ni);
    app.instruments.items[idx].plugin = pl;
    app.renamePlaceholderInstrument(idx, "Solokey"); // 乐器名进标签（如“Solokey: Oscillator 1 Level”）
    const iref = PluginSlotRef{ .kind = .instrument, .a = @intCast(idx) };
    pl.refreshParamCache();
    app.markSlotStateDirty(iref);
    app.resetHistory("初始");

    const h = pl.handler_obj orelse return error.TestUnexpectedResult;
    const lvbase = pl.paramNorm(li);
    // 拧 Level（GUI 内部改值 → begin/perform/end）
    _ = h.iface.vtable.beginEdit(&h.iface, 50797);
    guiSetParam(pl, li, 0.3);
    _ = h.iface.vtable.performEdit(&h.iface, 50797, 0.3);
    _ = h.iface.vtable.endEdit(&h.iface, 50797);
    app.drainSlotEditorEdits(iref, pl);
    // 立刻拧 Pan：begin 不同参数 → 应切历史
    _ = h.iface.vtable.beginEdit(&h.iface, 50800);
    guiSetParam(pl, pi, 0.7);
    _ = h.iface.vtable.performEdit(&h.iface, 50800, 0.7);
    _ = h.iface.vtable.endEdit(&h.iface, 50800);
    app.drainSlotEditorEdits(iref, pl);
    app.pinPendingGesture();

    try std.testing.expectEqual(@as(usize, 3), app.history.items.len); // 初始 + Level + Pan
    try std.testing.expect(std.mem.startsWith(u8, app.history.items[1].label, "Solokey"));
    try std.testing.expect(std.mem.endsWith(u8, app.history.items[1].label, pl.params[li].name()));
    try std.testing.expect(std.mem.endsWith(u8, app.history.items[2].label, pl.params[pi].name()));
    try std.testing.expect(!std.mem.eql(u8, app.history.items[1].label, app.history.items[2].label));
    // 两步撤销：Pan 先回退、Level 不受影响；再撤销 → Level 回退到基线
    try std.testing.expect(app.undo());
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), pl.paramNorm(li), 0.02);
    try std.testing.expect(app.undo());
    try std.testing.expect(app.history_current == 0);
    try std.testing.expectApproxEqAbs(lvbase, pl.paramNorm(li), 0.02);
}

test "VST3 乐器：加载后占位名 → 插件真名（重名去重 #N）" {
    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    try std.testing.expect(app.addInstrumentVst3("C:\\x\\A.vst3") == 0);
    try std.testing.expect(app.addInstrumentVst3("C:\\x\\B.vst3") == 1);
    try std.testing.expectEqualStrings("VST3 乐器", app.instruments.items[0].name);
    try std.testing.expectEqualStrings("VST3 乐器 #2", app.instruments.items[1].name);

    app.renamePlaceholderInstrument(0, "Vital");
    app.renamePlaceholderInstrument(1, "Vital");
    try std.testing.expectEqualStrings("Vital", app.instruments.items[0].name);
    try std.testing.expectEqualStrings("Vital #2", app.instruments.items[1].name);

    // 已不是占位名 → 再次加载不覆盖（用户手动命名的与真名都保留）
    app.renamePlaceholderInstrument(1, "Other");
    try std.testing.expectEqualStrings("Vital #2", app.instruments.items[1].name);
}

test "VST3 乐器：换路径清零旧 pending（防参数灌到别的乐器）与失败态" {
    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    try std.testing.expect(app.addInstrumentVst3("C:\\x\\old.vst3") == 0);
    const inst = &app.instruments.items[0];
    // 模拟：旧插件加载失败、带有待恢复音色（文件稍后被移除的场景）
    inst.load_failed = true;
    inst.fail_wait = 77;
    inst.clearPendingState(std.testing.allocator);
    inst.pending_state = try app.allocator.dupe(u8, "stale-pending-bytes");

    // 换成别的乐器（与历史/存档同路径：applySavedInstrument）
    var si = persist.SavedInstrument{ .kind = 2 };
    si.plugin_path = "C:\\x\\new.vst3";
    si.plugin_state = ""; // 新乐器无音色
    app.applySavedInstrument(&si, &app.instruments.items[0], .full, 0, 0);
    const inst2 = &app.instruments.items[0];
    try std.testing.expectEqualStrings("C:\\x\\new.vst3", inst2.pluginPath());
    try std.testing.expect(inst2.pending_state == null); // 旧 pending 已释放（否则测试分配器报泄漏）
    try std.testing.expect(inst2.pending_state_ctrl == null);
    try std.testing.expect(!inst2.load_failed); // 新路径 → 失败态重置，立即尝试
    try std.testing.expectEqual(@as(u16, 0), inst2.fail_wait);
}

test "撤销：状态未变的插件槽跳过重放（不设 pending → 无 setState 风暴）" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    app.resetHistory("初始");

    // 通道 0 加一个 VST3 效果槽（无实例：状态串为空）
    {
        var slot = EffectSlot{ .kind = .plugin };
        slot.setPluginPath("C:\\fx\\a.vst3");
        app.mixer_channels_state.items[0].effects.append(alloc, slot) catch unreachable;
    }
    app.commitHistory("添加效果器");
    app.mixer_channels_state.items[0].volume = 0.5;
    app.commitHistory("调音量");

    // 撤销到“添加效果器”：效果槽状态与来向条目同内容 → 跳过重放（不设 pending）
    try std.testing.expect(app.undo());
    const es = &app.mixer_channels_state.items[0].effects.items[0];
    try std.testing.expect(es.kind == .plugin);
    try std.testing.expect(es.pending_state == null);
    try std.testing.expect(es.pending_state_ctrl == null);

    // 重做再撤销：内容仍一致 → 仍跳过（且无泄漏）
    try std.testing.expect(app.redo());
    const es2 = &app.mixer_channels_state.items[0].effects.items[0];
    try std.testing.expect(es2.pending_state == null);
    try std.testing.expect(app.undo());
    try std.testing.expect(app.mixer_channels_state.items[0].effects.items[0].pending_state == null);
}

test "撤销：VST3 乐器状态未变时跳过重放（pending 不设）" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    app.resetHistory("初始");

    try std.testing.expect(app.addInstrumentVst3("C:\\v\\syn.vst3") == 0);
    app.commitHistory("添加乐器");
    app.instruments.items[0].volume = 0.3;
    app.commitHistory("调音量");

    try std.testing.expect(app.undo());
    const inst = &app.instruments.items[0];
    try std.testing.expect(inst.kind == .vst3);
    try std.testing.expect(inst.pending_state == null); // 状态未变 → 不重放
    try std.testing.expect(inst.pending_state_ctrl == null);
    try std.testing.expectEqual(@as(f32, 0.8), inst.volume); // 其它字段照常回退
}

test "VST3 编辑队列：多条排空/最后一条兼容/溢出降级" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl);
    const h = pl.handler_obj orelse return error.TestUnexpectedResult;

    // 一次拖动 = 大量连续编辑：必须**全量**排出（此前只留最后一条）
    for (0..100) |i| _ = h.iface.vtable.performEdit(&h.iface, 7, @as(f64, @floatFromInt(i)) / 100.0);
    var buf: [16]vst_host.ParamEdit = undefined;
    var total: usize = 0;
    var last = vst_host.ParamEdit{ .id = 0, .value = 0 };
    while (true) {
        const n = pl.drainEditorEdits(&buf);
        if (n == 0) break;
        total += n;
        last = buf[n - 1];
    }
    try std.testing.expectEqual(@as(usize, 100), total);
    try std.testing.expectEqual(@as(u32, 7), last.id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.99), last.value, 1e-9);

    // `pollEditorEdit` 兼容旧语义（取最后一条）
    _ = h.iface.vtable.performEdit(&h.iface, 8, 0.25);
    const pe = pl.pollEditorEdit() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 8), pe.id);
    try std.testing.expect(pl.pollEditorEdit() == null);

    // begin/perform/end 三类事件保序（新接口）
    _ = h.iface.vtable.beginEdit(&h.iface, 7);
    _ = h.iface.vtable.performEdit(&h.iface, 7, 0.5);
    _ = h.iface.vtable.endEdit(&h.iface, 7);
    var ebuf: [8]vst_host.EditEvent = undefined;
    const ne = pl.drainEditEvents(&ebuf);
    try std.testing.expectEqual(@as(usize, 3), ne);
    try std.testing.expect(ebuf[0].kind == .begin and ebuf[0].id == 7);
    try std.testing.expect(ebuf[1].kind == .perform and ebuf[1].id == 7);
    try std.testing.expect(ebuf[2].kind == .end and ebuf[2].id == 7);

    // perform-only 兼容接口：begin/end 一并消费（不丢 perform）
    _ = h.iface.vtable.beginEdit(&h.iface, 9);
    _ = h.iface.vtable.performEdit(&h.iface, 9, 0.6);
    _ = h.iface.vtable.endEdit(&h.iface, 9);
    var pbuf2: [4]vst_host.ParamEdit = undefined;
    const np2 = pl.drainEditorEdits(&pbuf2);
    try std.testing.expectEqual(@as(usize, 1), np2);
    try std.testing.expectEqual(@as(u32, 9), pbuf2[0].id);

    // 溢出：写 300 条不读 → 丢弃 + 降级旗标（消费方须回落整块恢复）
    for (0..300) |i| _ = h.iface.vtable.performEdit(&h.iface, 9, @as(f64, @floatFromInt(i)) / 300.0);
    try std.testing.expectEqual(@as(usize, 0), pl.drainEditorEdits(&buf));
    try std.testing.expect(pl.takeEditOverflow());
    try std.testing.expect(!pl.takeEditOverflow());
}

test "撤销：参数增量回放（不 setState）+ 未变槽捕获复用（零 getState）" {
    const dll_path = "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll";
    const dll_z = std.testing.allocator.dupeSentinel(u8, dll_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[slot].setPluginPath(dll_path);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    app.mixer_channels_state.items[0].effects.items[slot].plugin = pl;
    const fref = PluginSlotRef{ .kind = .fx, .a = 0, .b = @intCast(slot) };
    pl.refreshParamCache(); // 生产：实例就绪帧自动建齐（测试手动）
    app.markSlotStateDirty(fref);
    pl.setParamHost(0, 0.8);
    app.commitHistory("接入插件");

    // 与插件无关的编辑（BPM）→ 未脏槽捕获复用：**不调 getState**
    const c0 = pl.get_state_calls;
    app.bpm = 130;
    app.commitHistory("改 BPM");
    try std.testing.expectEqual(c0, pl.get_state_calls);

    // 旋钮：0.8 → 0.2（唯一入口，带增量）；钉值后撤销 → 参数回放
    app.setPluginParamHost(fref, pl, 0, 0.2);
    app.pinPendingGesture();
    try std.testing.expect(app.undo());
    const es_u = &app.mixer_channels_state.items[0].effects.items[slot];
    try std.testing.expect(es_u.pending_state == null); // 未整块 setState
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), pl.paramNorm(0), 0.01); // 回放 old
    // 重做 → 回放 new（0.2）
    try std.testing.expect(app.redo());
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), pl.paramNorm(0), 0.01);
}

test "撤销：结构性信号存在时参数回放降级为整块恢复（pending 就绪）" {
    const dll_path = "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll";
    const dll_z = std.testing.allocator.dupeSentinel(u8, dll_path, 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[slot].setPluginPath(dll_path);
    const pl = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    app.mixer_channels_state.items[0].effects.items[slot].plugin = pl;
    const fref = PluginSlotRef{ .kind = .fx, .a = 0, .b = @intCast(slot) };
    pl.refreshParamCache();
    app.markSlotStateDirty(fref);
    pl.setParamHost(0, 0.8);
    app.commitHistory("接入插件");

    // 旋钮 + 结构信号（setDirty/restart/溢出同类）→ 本步禁参数回放
    app.setPluginParamHost(fref, pl, 0, 0.2);
    app.notePluginStructural(fref);
    app.pinPendingGesture();
    try std.testing.expect(app.undo());
    const es_u = &app.mixer_channels_state.items[0].effects.items[slot];
    try std.testing.expect(es_u.pending_state != null); // 降级：整块恢复就绪
    pl.restoreState(es_u.pending_state.?, es_u.pending_state_ctrl orelse &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), pl.paramNorm(0), 0.01);
}

test "VST3 预设：分类标签/可用性/路径解析（扫描缓存驱动）" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.deinitPluginDb();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);

    const jsonl =
        "{\"t\":\"begin\",\"n\":1}\n" ++
        "{\"t\":\"start\",\"path\":\"C:/v/Vital.vst3\",\"dll\":\"C:/v/Vital.vst3\"}\n" ++
        "{\"t\":\"ok\",\"path\":\"C:/v/Vital.vst3\",\"dll\":\"C:/v/Vital.vst3\",\"name\":\"Vital\",\"vendor\":\"Vital Audio\",\"role\":\"instrument\",\"classes\":[{\"cid\":\"0102030405060708090a0b0c0d0e0f10\",\"name\":\"Vital\",\"vendor\":\"Vital Audio\",\"sub\":\"Instrument|Synth\",\"kind\":\"instrument\"}]}\n" ++
        "{\"t\":\"end\",\"ok\":1,\"err\":0}\n";
    app.plugin_cache = plugin_db.Cache.parseJsonl(alloc, jsonl);

    const id = "vst3_0102030405060708090a0b0c0d0e0f10";
    try std.testing.expect(app.presetCategoryInstalled(id));
    try std.testing.expectEqualStrings("Vital", app.presetCategoryLabel(id));
    try std.testing.expectEqualStrings("C:/v/Vital.vst3", app.vst3CategoryPath(id).?);

    const id2 = "vst3_ff02030405060708090a0b0c0d0e0f10";
    try std.testing.expect(!app.presetCategoryInstalled(id2));
    try std.testing.expectEqualStrings("VST3 插件（未安装/未扫描）", app.presetCategoryLabel(id2));
    try std.testing.expect(app.vst3CategoryPath(id2) == null);
    try std.testing.expectEqualStrings("减法合成器", app.presetCategoryLabel("subtractive"));

    // 可选性：create 意图需已安装；**鼓组层接受 VST3 乐器分类**（层 = 乐器槽）——
    // 未安装仍拒绝；鼓组分类仍拒绝（禁自嵌套）
    try std.testing.expect(app.presetCategorySelectable(.create_instrument, id));
    try std.testing.expect(!app.presetCategorySelectable(.create_instrument, id2));
    try std.testing.expect(app.presetCategorySelectable(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, id));
    try std.testing.expect(!app.presetCategorySelectable(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, id2));
    // 可见性：层上下文列出 VST3 乐器分类（已装；未装/鼓组仍隐藏）
    try std.testing.expect(app.presetCategoryRelevant(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, id));
    try std.testing.expect(!app.presetCategoryRelevant(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, id2));
    try std.testing.expect(!app.presetCategoryRelevant(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, preset_mod.plugin_drumkit));
    try std.testing.expect(!app.presetCategorySelectable(.{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } }, preset_mod.plugin_drumkit));
}

test "VST3 乐器：applyVst3Instrument 清 pending/退役旧实例，保留名字与路由" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    app.resetHistory("初始");

    try std.testing.expect(app.addInstrumentVst3("C:\\old.vst3") == 0);
    const inst = &app.instruments.items[0];
    inst.pending_state = try alloc.dupe(u8, "stale");
    inst.mixer = 1;
    inst.volume = 0.33;
    inst.pan = 0.2;

    app.applyVst3Instrument(0, "C:\\new.vst3");
    const inst2 = &app.instruments.items[0];
    try std.testing.expect(inst2.pending_state == null); // 旧 pending 已释放（测试分配器验证无泄漏）
    try std.testing.expectEqualStrings("C:\\new.vst3", inst2.pluginPath());
    try std.testing.expectEqual(@as(i32, 1), inst2.mixer); // 路由保留
    try std.testing.expectApproxEqAbs(@as(f32, 0.33), inst2.volume, 1e-6);
    try std.testing.expect(inst2.kind == .vst3);
}

test "VST3 预设：CID 捕获 + 状态捕获/解码往返（sine-synth 真实插件）" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.deinitPluginDb();
    defer app.clips.deinit(std.testing.allocator);
    defer app.notes.deinit(std.testing.allocator);
    app.resetHistory("初始");

    const pl = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return;
    // 注：pl 会挂进乐器槽 → 由 deinitAll 统一卸载（不能再手动 unload——双重释放）
    // CID 已捕获（非零）且稳定可格式化
    var hb: [32]u8 = undefined;
    const hex = pl.cidHex(&hb);
    try std.testing.expect(!std.mem.eql(u8, hex, "00000000000000000000000000000000"));

    try std.testing.expect(app.addInstrumentVst3("libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll") == 0);
    app.instruments.items[0].plugin = pl;
    pl.setParamHost(0, 0.42); // level

    const st = app.captureVst3StateB64(0) orelse return error.CaptureFailed;
    defer {
        if (st.comp.len > 0) std.testing.allocator.free(st.comp);
        if (st.ctrl.len > 0) std.testing.allocator.free(st.ctrl);
    }
    try std.testing.expect(st.comp.len > 0);

    // 解码 → 恢复到新实例（模拟预设加载；restoreState 收**原始字节**）
    const dec = app.decodeStateB64(st.comp).?;
    defer std.testing.allocator.free(dec);
    var dec_ctrl: ?[]u8 = null;
    if (st.ctrl.len > 0) dec_ctrl = app.decodeStateB64(st.ctrl);
    defer if (dec_ctrl) |b| std.testing.allocator.free(b);
    const pl2 = vst_host.loadPlugin(std.testing.allocator, dll_z, 48000, 4096, .instrument) catch return;
    defer vst_host.unloadPlugin(std.testing.allocator, pl2);
    pl2.restoreState(dec, dec_ctrl orelse &.{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), pl2.paramNorm(0), 0.01);
    var hb2: [32]u8 = undefined;
    try std.testing.expectEqualStrings(hex, pl2.cidHex(&hb2)); // CID 跨实例稳定
}

test "VST3 自愈：reboundFailedPluginSlots 按 CID 重定位失败槽（只碰失败槽）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);

    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.deinitPluginDb();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    app.resetHistory("初始");

    // 候选文件必须真实存在（存在性门槛：只换到“真在磁盘上”的路径）
    var pb1: [1080]u8 = undefined;
    const vital_path = try std.fmt.bufPrint(&pb1, "{s}/Vital.vst3", .{root});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = vital_path, .data = "" }) catch return error.IoFailure;
    var pb2: [1080]u8 = undefined;
    const nova_path = try std.fmt.bufPrint(&pb2, "{s}/Nova.vst3", .{root});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nova_path, .data = "" }) catch return error.IoFailure;

    const cid_a = "0102030405060708090a0b0c0d0e0f10";
    const cid_b = "ff02030405060708090a0b0c0d0e0f10";
    const jsonl = try std.fmt.allocPrint(alloc, "{{\"t\":\"begin\",\"n\":2}}\n" ++
        "{{\"t\":\"start\",\"path\":\"{0s}\",\"dll\":\"{0s}\"}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"{0s}\",\"dll\":\"{0s}\",\"name\":\"Vital\",\"role\":\"instrument\",\"classes\":[{{\"cid\":\"{2s}\",\"kind\":\"instrument\"}}]}}\n" ++
        "{{\"t\":\"start\",\"path\":\"{1s}\",\"dll\":\"{1s}\"}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"{1s}\",\"dll\":\"{1s}\",\"name\":\"Nova\",\"role\":\"effect\",\"classes\":[{{\"cid\":\"{3s}\",\"kind\":\"effect\"}}]}}\n" ++
        "{{\"t\":\"end\",\"ok\":2,\"err\":0}}\n", .{ vital_path, nova_path, cid_a, cid_b });
    defer alloc.free(jsonl);
    app.plugin_cache = plugin_db.Cache.parseJsonl(alloc, jsonl);

    // 失败乐器槽（旧路径**已不存在** + 记录 CID）
    try std.testing.expect(app.addInstrumentVst3("C:\\gone\\Vital.vst3") == 0);
    app.instruments.items[0].load_failed = true;
    app.instruments.items[0].setPluginCid(cid_a);
    // 失败效果槽
    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    const es = &app.mixer_channels_state.items[0].effects.items[slot];
    es.setPluginPath("C:\\gone\\Nova.vst3");
    es.load_failed = true;
    es.setPluginCid(cid_b);

    try std.testing.expectEqual(@as(usize, 2), app.reboundFailedPluginSlots(io));
    try std.testing.expectEqualStrings(vital_path, app.instruments.items[0].pluginPath());
    try std.testing.expect(!app.instruments.items[0].load_failed);
    try std.testing.expectEqualStrings(cid_a, app.instruments.items[0].pluginCid()); // 身份保留（再失败仍可匹配）
    try std.testing.expectEqualStrings(nova_path, es.pluginPath());
    // 幂等：再跑 → 0（已不失败）
    try std.testing.expectEqual(@as(usize, 0), app.reboundFailedPluginSlots(io));
}

test "VST3 存档：类 CID 捕获（活实例/失败槽）+ JSON 往返" {
    const alloc = std.testing.allocator;
    const dll_z = alloc.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", 0) catch return;
    defer alloc.free(dll_z);

    var app = App{ .allocator = alloc };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.deinitPluginDb();
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    app.resetHistory("初始");

    const pl = vst_host.loadPlugin(alloc, dll_z, 48000, 4096, .instrument) catch return;
    try std.testing.expect(app.addInstrumentVst3("libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll") == 0);
    app.instruments.items[0].plugin = pl; // 由 deinitAll 统一卸载
    // 另一个失败槽（无实例、只有记录 CID）
    try std.testing.expect(app.addInstrumentVst3("C:\\missing.vst3") == 1);
    app.instruments.items[1].load_failed = true;
    app.instruments.items[1].setPluginCid("0102030405060708090a0b0c0d0e0f10");

    const proj = try app.exportProject();
    defer app.freeProject(proj);
    var hb: [32]u8 = undefined;
    const live_hex = pl.cidHex(&hb);
    try std.testing.expectEqualStrings(live_hex, proj.instruments[0].plugin_cid);
    try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", proj.instruments[1].plugin_cid);

    const json = try persist.toJson(alloc, proj);
    defer alloc.free(json);
    var parsed = try persist.fromJson(alloc, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(live_hex, parsed.value.instruments[0].plugin_cid);
    try std.testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", parsed.value.instruments[1].plugin_cid);
}

test "效果器预设：fx 分类映射与可选性" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitPluginDb();
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(1);
    app.resetHistory("初始");

    try std.testing.expectEqualStrings("fx_delay", EffectKind.delay.presetCategoryId().?);
    try std.testing.expect(EffectKind.plugin.presetCategoryId() == null);
    try std.testing.expect(fxKindFromCategory("fx_reverb").? == .reverb);
    try std.testing.expect(fxKindFromCategory("subtractive") == null);
    // 效果意图：fx 可选、乐器分类不可选；乐器意图反之
    try std.testing.expect(app.presetCategorySelectable(.{ .create_effect = 0 }, "fx_reverb"));
    try std.testing.expect(app.presetCategorySelectable(.{ .replace_effect = .{ .ch = 0, .slot = 0 } }, "fx_eq"));
    try std.testing.expect(!app.presetCategorySelectable(.create_instrument, "fx_reverb"));
    try std.testing.expect(!app.presetCategorySelectable(.{ .create_effect = 0 }, "subtractive"));
    try std.testing.expect(!app.presetCategorySelectable(.{ .create_effect = 0 }, "drumkit"));

    // 缓存驱动的 VST3「**纯效果**」分类（M4 遗留 bug：曾只合成乐器类 → TDR Nova 不可选）
    const fx_cid = "0de7aef2de004e4f544f4249424d3750";
    const inst_cid = "aa030405060708090a0b0c0d0e0f10ff";
    const jsonl = try std.fmt.allocPrint(std.testing.allocator, "{{\"t\":\"begin\",\"n\":2}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"C:/v/Nova.vst3\",\"dll\":\"C:/v/Nova.vst3\",\"name\":\"Nova\",\"role\":\"effect\",\"classes\":[{{\"cid\":\"{0s}\",\"kind\":\"effect\"}}]}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"C:/v/Both.vst3\",\"dll\":\"C:/v/Both.vst3\",\"name\":\"Both\",\"role\":\"both\",\"classes\":[{{\"cid\":\"{1s}\",\"kind\":\"instrument\"}},{{\"cid\":\"{2s}\",\"kind\":\"effect\"}}]}}\n" ++
        "{{\"t\":\"end\",\"ok\":2,\"err\":0}}\n", .{ fx_cid, inst_cid, "bb030405060708090a0b0c0d0e0f10ff" });
    defer std.testing.allocator.free(jsonl);
    app.plugin_cache = plugin_db.Cache.parseJsonl(std.testing.allocator, jsonl);

    var idbuf: [64]u8 = undefined;
    const id_nova = preset_mod.vst3CategoryId(fx_cid, &idbuf);
    try std.testing.expect(app.presetCategorySelectable(.{ .create_effect = 0 }, id_nova));
    try std.testing.expect(!app.presetCategorySelectable(.create_instrument, id_nova)); // 纯效果不能当乐器
    try std.testing.expectEqualStrings("C:/v/Nova.vst3", app.vst3CategoryPath(id_nova).?);

    // 双角色插件：效果类 CID → 归一到主 CID（乐器类优先）
    var canon: [32]u8 = undefined;
    try std.testing.expectEqualStrings(inst_cid, app.canonicalCategoryCid("bb030405060708090a0b0c0d0e0f10ff", &canon));
    try std.testing.expectEqualStrings(fx_cid, app.canonicalCategoryCid(fx_cid, &canon)); // 纯效果：原样
}

test "预设目录：按ID复用 / 纯名 / 同名冲突哈希" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll(); // 释放 preset_lib

    const id_a = "vst3_0de7aef2de004e4f544f4249424d3754";
    const id_b = "vst3_56545356746976616974616c00000000";
    // 库里已有：id_a 占用 "SuperVerb" 目录；id_b 为合成分类（无目录）
    const nm = try app.allocator.dupe(u8, id_a);
    const dr = try app.allocator.dupe(u8, "SuperVerb");
    try app.preset_lib.categories.append(app.allocator, .{ .name = nm, .dir = dr });
    const nm2 = try app.allocator.dupe(u8, id_b);
    try app.preset_lib.categories.append(app.allocator, .{ .name = nm2 });

    var buf: [200]u8 = undefined;
    // 1) 按 ID 复用 → 返回既有目录（冻结）
    try std.testing.expectEqualStrings("SuperVerb", app.presetDirForCategory(id_a, "SuperVerb", &buf));
    // 2) 无既有目录 → 纯名
    try std.testing.expectEqualStrings("Vital", app.presetDirForCategory(id_b, "Vital", &buf));
    // 3) 同名冲突（"SuperVerb" 已被 id_a 占用）→ 哈希后缀
    const dir_h = app.presetDirForCategory(id_b, "SuperVerb", &buf);
    try std.testing.expect(std.mem.startsWith(u8, dir_h, "SuperVerb ("));
    try std.testing.expectEqual(@as(usize, "SuperVerb (".len + 8 + 1), dir_h.len);
    // 内置：目录名 == id
    try std.testing.expectEqualStrings("subtractive", app.presetDirForCategory("subtractive", "", &buf));
}

test "预设浏览：可见性规则（乐器/效果互不可见；未安装 VST3 隐藏；层上下文仅减法）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitPluginDb();
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(1);
    app.resetHistory("初始");

    // 缓存：一个纯效果插件 + 一个乐器插件（均已安装）
    const fx_cid = "0de7aef2de004e4f544f4249424d3750";
    const in_cid = "0102030405060708090a0b0c0d0e0f10";
    const jsonl = try std.fmt.allocPrint(std.testing.allocator, "{{\"t\":\"begin\",\"n\":1}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"C:/v/Nova\",\"dll\":\"C:/v/Nova\",\"name\":\"Nova\",\"role\":\"effect\",\"classes\":[{{\"cid\":\"{s}\",\"kind\":\"effect\"}}]}}\n" ++
        "{{\"t\":\"ok\",\"path\":\"C:/v/Vita\",\"dll\":\"C:/v/Vita\",\"name\":\"Vita\",\"role\":\"instrument\",\"classes\":[{{\"cid\":\"{s}\",\"kind\":\"instrument\"}}]}}\n" ++
        "{{\"t\":\"end\",\"ok\":1,\"err\":0}}\n", .{ fx_cid, in_cid });
    defer std.testing.allocator.free(jsonl);
    app.plugin_cache = plugin_db.Cache.parseJsonl(std.testing.allocator, jsonl);

    var idbuf: [48]u8 = undefined;
    var idbuf2: [48]u8 = undefined;
    const id_nova = preset_mod.vst3CategoryId(fx_cid, &idbuf);
    const id_vita = preset_mod.vst3CategoryId(in_cid, &idbuf2);
    const id_missing = "vst3_ff030405060708090a0b0c0d0e0f10ff";

    // 乐器意图：内置可见；效果不可见；纯效果插件不可见；未安装隐藏
    try std.testing.expect(app.presetCategoryRelevant(.create_instrument, "subtractive"));
    try std.testing.expect(app.presetCategoryRelevant(.create_instrument, "drumkit"));
    try std.testing.expect(!app.presetCategoryRelevant(.create_instrument, "fx_reverb"));
    try std.testing.expect(!app.presetCategoryRelevant(.create_instrument, id_nova));
    try std.testing.expect(!app.presetCategoryRelevant(.create_instrument, id_missing));
    // 效果意图：fx 可见；已安装效果插件可见；内置乐器不可见；未安装隐藏
    try std.testing.expect(app.presetCategoryRelevant(.{ .create_effect = 0 }, "fx_reverb"));
    try std.testing.expect(app.presetCategoryRelevant(.{ .create_effect = 0 }, id_nova));
    try std.testing.expect(!app.presetCategoryRelevant(.{ .create_effect = 0 }, "subtractive"));
    try std.testing.expect(!app.presetCategoryRelevant(.{ .create_effect = 0 }, id_missing));
    // 层上下文：减法 + **VST3 乐器分类**（已装）；鼓组/效果仍不可见；
    // 替换意图同规则（层 = 乐器槽）
    const layer_intent = PresetIntent{ .create_kit_layer = .{ .instrument = 0, .pitch = 35 } };
    try std.testing.expect(app.presetCategoryRelevant(layer_intent, "subtractive"));
    try std.testing.expect(app.presetCategoryRelevant(layer_intent, id_vita));
    try std.testing.expect(app.presetCategorySelectable(layer_intent, id_vita));
    try std.testing.expect(!app.presetCategoryRelevant(layer_intent, "drumkit"));
    try std.testing.expect(!app.presetCategoryRelevant(layer_intent, "fx_reverb"));
    const layer_replace = PresetIntent{ .replace = .{ .kit_layer_replace = .{ .instrument = 0, .pitch = 35, .layer = 0 } } };
    try std.testing.expect(app.presetCategorySelectable(layer_replace, id_vita));
    try std.testing.expect(!app.presetCategorySelectable(layer_replace, "drumkit"));
}

test "VST3 乐器：多输出插件（SFLT，系统装有才跑）加载 + 处理不崩" {
    const alloc = std.testing.allocator;
    const pz = alloc.dupeSentinel(u8, "C:\\Program Files\\Common Files\\VST3\\SFLT.vst3", 0) catch return;
    defer alloc.free(pz);
    const pl = vst_host.loadPlugin(alloc, pz, 48000, 4096, .instrument) catch |e| switch (e) {
        error.LoadLibraryFailed, error.NoGetPluginFactory => return, // 未安装：跳过
        else => return error.SFLTLoadFailed,
    };
    defer vst_host.unloadPlugin(alloc, pl);
    // 0进17出：多输出协商成功（旧版直接 MultiOutputUnsupported 拒绝）
    try std.testing.expect(pl.out_bus_count >= 1);
    // 处理两块（无 sf2 → 静音，关键是**不崩**——旧版 SFLT 会在此崩）
    var buf: [512 * 2]f32 = @splat(0);
    const ht = vst_host.HostTime{ .playing = true, .tempo = 120, .time_num = 4, .time_den = 4, .abs_samples = 0, .ppq = 0 };
    pl.processInstrument(&buf, 512, &.{}, ht);
    pl.processInstrument(&buf, 512, &.{}, ht);
    for (buf) |s| {
        try std.testing.expect(!std.math.isNan(s));
        try std.testing.expect(@abs(s) < 0.5); // 结构健全性（未加载音色不应有大声输出）
    }
}

test "VST3 加载：中文路径（LoadLibraryW 回归）" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);

    // 把 sine-synth 复制成中文名（修复前：LoadLibraryA 按系统代码页解路径 → 加载失败）
    const src = std.Io.Dir.cwd().readFileAlloc(io, "libs/zig-vst3/zig-out/bin/zig_vst3_sine_synth.dll", alloc, .unlimited) catch return; // 示例未构建：跳过
    defer alloc.free(src);
    const dst = try std.fmt.allocPrint(alloc, "{s}/GuitarD - 副本.vst3", .{root});
    defer alloc.free(dst);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = src }) catch return error.IoFailure;

    const dz = try alloc.dupeSentinel(u8, dst, 0);
    defer alloc.free(dz);
    const pl = vst_host.loadPlugin(alloc, dz, 48000, 4096, .instrument) catch return error.ChinesePathLoadFailed;
    defer vst_host.unloadPlugin(alloc, pl);
    try std.testing.expect(pl.name().len > 0);
    var hb: [32]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, pl.cidHex(&hb), "00000000000000000000000000000000"));
}

test "VST3 状态：历史携带插件状态（池共享/去重）与撤销回退" {
    const dll_z = std.testing.allocator.dupeSentinel(u8, "libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll", 0) catch return;
    defer std.testing.allocator.free(dll_z);

    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    app.resetHistory("初始");

    const slot = app.addEffect(0, .plugin) orelse return error.TestUnexpectedResult;
    app.mixer_channels_state.items[0].effects.items[slot].setPluginPath("libs/zig-vst3/zig-out/bin/zig_vst3_gain.dll");
    app.mixer_channels_state.items[0].effects.items[slot].plugin = vst_host.loadEffect(std.testing.allocator, dll_z, 48000, 4096) catch return;
    // 注：zig-vst3 示例插件的参数是**进程级全局存储**（多实例共享）——先设一个专属基线值，
    // 避免与前面测试残留的全局值相撞导致去重误跳（测试环境特有问题）
    const pl = app.mixer_channels_state.items[0].effects.items[slot].plugin.?;
    const fref = PluginSlotRef{ .kind = .fx, .a = 0, .b = @intCast(slot) };
    pl.setParamHost(0, 0.9);
    app.markSlotStateDirty(fref); // 生产路径经 setPluginParamHost 钩子自动置脏（此处直调插件 API）
    app.commitHistory("添加插件");

    // 三次调参：A(0.3) → B(0.5) → A2(0.3)
    pl.setParamHost(0, 0.3);
    app.markSlotStateDirty(fref);
    app.commitHistory("调参 A");
    pl.setParamHost(0, 0.5);
    app.markSlotStateDirty(fref);
    app.commitHistory("调参 B");
    pl.setParamHost(0, 0.3);
    app.markSlotStateDirty(fref);
    app.commitHistory("调参 A2");
    try std.testing.expectEqual(@as(usize, 5), app.history.items.len);

    // 内容相同 → 池复用（A2 与 A 的状态块同指针）
    const e_a = &app.history.items[2];
    const e_a2 = &app.history.items[4];
    const blk_a = e_a.mixer[0].effects[0].plugin_state;
    const blk_a2 = e_a2.mixer[0].effects[0].plugin_state;
    try std.testing.expect(blk_a.len > 0);
    try std.testing.expectEqual(blk_a.ptr, blk_a2.ptr);

    // 去重：内容无变化 → 不新增条目
    app.commitHistory("无变化");
    try std.testing.expectEqual(@as(usize, 5), app.history.items.len);

    // 撤销「调参 A2」→ 槽得到 B(0.5) 的 pending；应用后音频回退到 0.5
    try std.testing.expect(app.undo());
    const es_u = &app.mixer_channels_state.items[0].effects.items[slot];
    try std.testing.expect(es_u.pending_state != null);
    const pl_u = es_u.plugin.?;
    pl_u.restoreState(es_u.pending_state.?, es_u.pending_state_ctrl orelse &.{});
    var buf: [256 * 2]f32 = undefined;
    for (&buf) |*v| v.* = 1.0;
    pl_u.process(&buf, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buf[0], 0.02);

    // 重做 → 回到 A2(0.3)
    try std.testing.expect(app.redo());
    const es_r = &app.mixer_channels_state.items[0].effects.items[slot];
    const pl_r = es_r.plugin.?;
    pl_r.restoreState(es_r.pending_state orelse &.{}, es_r.pending_state_ctrl orelse &.{});
    for (&buf) |*v| v.* = 1.0;
    pl_r.process(&buf, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), buf[0], 0.02);
}

test "模态框展开期间 bringToFront 不动作（弹窗按钮点穿回归锁）" {
    var app = App{ .allocator = std.testing.allocator };
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    defer app.deinitAll();
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);

    const z0 = app.synth_win.z;
    app.bringToFront(&app.synth_win.z);
    try std.testing.expect(app.synth_win.z > z0); // 正常路径：可置顶

    app.modal = .dirty_confirm;
    const z1 = app.synth_win.z;
    app.bringToFront(&app.synth_win.z);
    try std.testing.expectEqual(z1, app.synth_win.z); // 模态期间：不动作
}
test "app: 全局区域选片段（与音符版同语义：相交判定 + 只选中一次）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 96, .pattern = 0 }) catch {};
    app.clips.append(app.allocator, .{ .track = 1, .start = 200, .len = 96, .pattern = 0 }) catch {};
    app.clips.append(app.allocator, .{ .track = 2, .start = 500, .len = 96, .pattern = 0 }) catch {};

    // 区域 [50,250)：与 [0,96)、[200,296) 相交 → 两条选中；[500,596) 不选
    app.selectClipsInRegionSong(50, 250);
    try std.testing.expect(app.clips.items[0].selected);
    try std.testing.expect(app.clips.items[1].selected);
    try std.testing.expect(!app.clips.items[2].selected);

    // 重选清旧选择：区域 [520,560) 只选第三条（含“音尾伸入”式相交）
    app.selectClipsInRegionSong(520, 560);
    try std.testing.expect(!app.clips.items[0].selected);
    try std.testing.expect(!app.clips.items[1].selected);
    try std.testing.expect(app.clips.items[2].selected);
}

test "app: 轨道静音——切换与存档往返" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.resetHistory("初始状态");

    try std.testing.expect(!app.trackMuted(3));
    app.setTrackMuted(3, true);
    try std.testing.expect(app.trackMuted(3));

    const proj = try app.exportProject();
    defer app.freeProject(proj);

    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expect(app2.trackMuted(3));
    try std.testing.expect(!app2.trackMuted(4));

    app2.setTrackMuted(3, false);
    try std.testing.expect(!app2.trackMuted(3));
}

test "app: 轨道行上移/下移与删除——片段/自定义名/静音整体搬；默认名随位置" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.clips.append(app.allocator, .{ .track = 1, .start = 0, .len = 48, .pattern = 0 }) catch {};
    app.clips.append(app.allocator, .{ .track = 2, .start = 96, .len = 48, .pattern = 0 }) catch {};
    app.setTrackMuted(1, true);

    // 命名 idx1 为“鼓”
    app.beginRenameTrack(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('鼓');
    app.textInputCommit();
    try std.testing.expectEqualStrings("鼓", app.trackName(1));

    // 上移 idx2 ↔ idx1：内容 + 自定义名 + 静音随行；未命名行显示位置默认名
    app.swapTrackRows(2, 1);
    try std.testing.expectEqualStrings("鼓", app.trackName(2));
    try std.testing.expectEqualStrings("Track 2", app.trackName(1));
    try std.testing.expect(app.trackMuted(2));
    try std.testing.expect(!app.trackMuted(1));
    try std.testing.expectEqual(@as(i32, 2), app.clips.items[0].track); // 原 idx1 片段 → idx2
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[1].track);

    // 删除 idx1（空行）→ 下方整体上移：“鼓”行来到 idx1
    app.removeTrackRow(1);
    try std.testing.expectEqual(@as(usize, 1), app.clips.items.len);
    try std.testing.expectEqual(@as(i32, 1), app.clips.items[0].track);
    try std.testing.expectEqualStrings("鼓", app.trackName(1));
    try std.testing.expect(app.trackMuted(1));
}

test "app: 轨道重命名——空字符串恢复默认名（输入框不预填默认名）" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.beginRenameTrack(1, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), app.text_input.text().len); // 未命名行：输入框留空
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('鼓');
    app.textInputCommit();
    try std.testing.expectEqualStrings("鼓", app.trackName(1));

    app.beginRenameTrack(1, 0, 0);
    try std.testing.expectEqualStrings("鼓", app.text_input.text()); // 命名行：预填自定义名
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputCommit(); // 清空提交 → 恢复默认名
    try std.testing.expectEqualStrings("Track 2", app.trackName(1));
}

test "app: 存档 v4 稀疏轨道名——深行命名只写一对；旧密集数组垫片互通" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.resetHistory("初始状态");

    // 深行命名（第 500 行）——导出应只有 1 对，而不是 501 条空串
    app.playlist.view_rows = 1000; // 放开重命名守卫（正常由视图每帧写入）
    app.beginRenameTrack(500, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputAppend('低');
    app.textInputAppend('音');
    app.textInputCommit();

    const proj = try app.exportProject();
    defer app.freeProject(proj);
    try std.testing.expectEqual(@as(usize, 1), proj.track_name_rows.len);
    try std.testing.expectEqual(@as(i32, 500), proj.track_name_rows[0]);
    try std.testing.expectEqualStrings("低音", proj.track_names[0]);

    // v4 稀疏对往返
    var app2 = App{ .allocator = std.testing.allocator };
    defer app2.clips.deinit(app2.allocator);
    defer app2.notes.deinit(app2.allocator);
    defer app2.deinitAll();
    app2.resetMixerChannels(default_mixer_channels);
    app2.importProject(proj);
    try std.testing.expectEqualStrings("低音", app2.trackName(500));
    try std.testing.expectEqualStrings("Track 500", app2.trackName(499));

    // 垫片：旧档密集数组（含空串、无 rows）→ 按“跳过空串”派生行号
    var l3 = proj;
    l3.track_name_rows = &.{};
    const dense = try app2.allocator.alloc([]const u8, 3);
    defer app2.allocator.free(dense);
    dense[0] = "";
    dense[1] = "鼓";
    dense[2] = "";
    l3.track_names = dense;
    var app3 = App{ .allocator = std.testing.allocator };
    defer app3.clips.deinit(app3.allocator);
    defer app3.notes.deinit(app3.allocator);
    defer app3.deinitAll();
    app3.resetMixerChannels(default_mixer_channels);
    app3.importProject(l3);
    try std.testing.expectEqualStrings("鼓", app3.trackName(1));
    try std.testing.expectEqualStrings("Track 1", app3.trackName(0));
}

test "app: SONG 下静音轨道不调度其音符片段" {
    var app = App{ .allocator = std.testing.allocator };
    defer app.clips.deinit(app.allocator);
    defer app.notes.deinit(app.allocator);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.scheduler.muted = &app.track_muted; // 与 main 同一条挂载线
    app.clips.append(app.allocator, .{ .track = 0, .start = 0, .len = 32, .pattern = 0 }) catch {};
    app.notes.append(app.allocator, .{ .step = 0, .len = 4, .pitch = 60, .pattern = 0 }) catch {};
    app.sel.song_mode = true;

    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, true, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, true, 0, 0, 64);

    // 清空队列，静音轨道 0 后重扫
    var tmpq: [512]synth.SchedEvent = undefined;
    _ = app.sched_events.drain(&tmpq);
    app.setTrackMuted(0, true);
    sequencer.reset(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, true, 0, 0);
    sequencer.scheduleRange(&app.scheduler, &app.sched_events, app.clips.items, app.notes.items, true, 0, 0, 64);

    var outq: [512]synth.SchedEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), app.sched_events.drain(&outq));
}

test "app: 音频样式重命名——只改名字；空串恢复文件名" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    // 两个假样式（asset = -1：仅名字/路径，不碰磁盘）
    try app.audio_styles.append(alloc, .{ .name = try alloc.dupe(u8, "A"), .path = try alloc.dupe(u8, "a.wav") });
    try app.audio_styles.append(alloc, .{ .name = try alloc.dupe(u8, "B"), .path = try alloc.dupe(u8, "sub/kick.wav") });
    app.audio_styles.items[1].gain = 0.5;
    app.audio_styles.items[1].speed = 1.5;
    app.audio_styles.items[1].channel = 2;
    app.resetHistory("初始");

    app.beginRenameAudioStyle(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    for ("Kick") |ch| app.textInputAppend(ch);
    app.textInputCommit();
    try std.testing.expectEqualStrings("Kick", app.audio_styles.items[1].name);
    // 其余字段原样
    try std.testing.expectEqual(@as(f32, 0.5), app.audio_styles.items[1].gain);
    try std.testing.expectEqual(@as(f32, 1.5), app.audio_styles.items[1].speed);
    try std.testing.expectEqual(@as(i32, 2), app.audio_styles.items[1].channel);
    try std.testing.expectEqualStrings("sub/kick.wav", app.audio_styles.items[1].path);

    // 空串 → 默认名 = 文件名
    app.beginRenameAudioStyle(1, 0, 0);
    while (app.text_input.text().len > 0) app.textInputBackspace();
    app.textInputCommit();
    try std.testing.expectEqualStrings("kick.wav", app.audio_styles.items[1].name);
}

test "app: 删除音频样式——片段连带删除、索引前移、撤销恢复" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    for (0..3) |i| {
        const nm = try std.fmt.allocPrint(alloc, "S{d}", .{i});
        const pth = try std.fmt.allocPrint(alloc, "s{d}.wav", .{i});
        try app.audio_styles.append(alloc, .{ .name = nm, .path = pth });
    }
    // 三个音频片段（各引用一个样式）+ 一个音符片段（audio_style = -1）
    app.addClip(.{ .track = 0, .start = 0, .len = 8, .pattern = 0, .audio_style = 0 });
    app.addClip(.{ .track = 1, .start = 0, .len = 8, .pattern = 0, .audio_style = 1 });
    app.addClip(.{ .track = 2, .start = 0, .len = 8, .pattern = 0, .audio_style = 2 });
    app.addClip(.{ .track = 3, .start = 0, .len = 8, .pattern = 0 });
    app.resetHistory("初始");
    app.audio_style_sel = 2;

    const dropped = app.removeAudioStyle(1).?;
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqual(@as(usize, 2), app.audio_styles.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.clips.items.len); // 音符片段 + 两个音频片段
    // 前移：原 style2 → 1；原 style0 仍 0
    var seen0 = false;
    var seen1 = false;
    var note_clip = false;
    for (app.clips.items) |c| {
        if (c.isAudio()) {
            if (c.audio_style == 0) seen0 = true;
            if (c.audio_style == 1) seen1 = true;
        } else note_clip = true;
    }
    try std.testing.expect(seen0 and seen1 and note_clip);
    try std.testing.expectEqual(@as(i32, 1), app.audio_style_sel); // 选择随索引前移
    app.commitHistory("删除音频样式");

    // 撤销 → 样式与片段全部恢复
    try std.testing.expect(app.undo());
    try std.testing.expectEqual(@as(usize, 3), app.audio_styles.items.len);
    try std.testing.expectEqual(@as(usize, 4), app.clips.items.len);
}

test "app: 存档容错——片段引用不存在的音频样式 → 加载时丢弃" {
    const alloc = std.testing.allocator;
    var app = App{ .allocator = alloc };
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    const clips = [_]persist.SavedClip{.{
        .track = 0,
        .start = 0,
        .len = 8,
        .pattern = 0,
        .audio_style = 5, // 越界：工程里没有任何音频样式
    }};
    const proj = persist.Project{ .clips = @constCast(&clips), .pattern_count = 1 };
    app.importProject(proj);
    try std.testing.expectEqual(@as(usize, 0), app.clips.items.len);
}

// ── P2：异步导入（单 worker）────────────────────────────────────────────

/// 测试用：写一个 16-bit PCM 立体声正弦 WAV（48 kHz）
fn writeSineWavForTest(io: std.Io, alloc: std.mem.Allocator, path: []const u8, frames: usize, sample_rate: u32) !void {
    var w = std.ArrayListUnmanaged(u8).empty;
    defer w.deinit(alloc);
    const data_bytes: u32 = @intCast(frames * 4);
    try w.appendSlice(alloc, "RIFF");
    try w.appendSlice(alloc, std.mem.asBytes(&(@as(u32, 36) + data_bytes)));
    try w.appendSlice(alloc, "WAVEfmt ");
    try w.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
    try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
    try w.appendSlice(alloc, std.mem.asBytes(&sample_rate));
    try w.appendSlice(alloc, std.mem.asBytes(&(sample_rate * 4)));
    try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 4)));
    try w.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
    try w.appendSlice(alloc, "data");
    try w.appendSlice(alloc, std.mem.asBytes(&data_bytes));
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const s: i16 = @intFromFloat(@sin(@as(f64, @floatFromInt(i)) * 0.03) * 12000.0);
        try w.appendSlice(alloc, std.mem.asBytes(&s));
        try w.appendSlice(alloc, std.mem.asBytes(&s));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.items });
}

/// 测试用：等异步导入收尾（UI 侧 poll；最多 5 s）
fn waitImportsIdleForTest(app: *App, io: std.Io) void {
    var spins: usize = 0;
    while (app.import_mgr.busy() and spins < 5000) : (spins += 1) {
        app.pollImports();
        if (!app.import_mgr.busy()) break;
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    app.pollImports();
}

test "P2 异步导入：立刻返回占位 → 完成后资产入池 + 播放表出现该行" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}/p2.wav", .{dirp});
    defer alloc.free(wav_path);
    try writeSineWavForTest(io, alloc, wav_path, 9600, 48000); // 0.2 s

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.sel.song_mode = true;
    app.resetHistory("初始");

    const s = app.audioStyleAddAsync(wav_path, "P2") orelse return error.StyleFailed;
    const si: usize = @intCast(s);
    // 阶段 A 立刻返回：资产没挂，但时长已知（9600 帧）
    try std.testing.expectEqual(@as(i32, -1), app.audio_styles.items[si].asset);
    try std.testing.expectEqual(@as(u64, 9600), app.audio_styles.items[si].frames_hint);
    // 占位片段的长度来自文件头（不是默认的 4 步）
    const ci = app.audioClipAdd(s, 0, 0) orelse return error.ClipFailed;
    const fps: u64 = app.framesPerStep();
    try std.testing.expectEqual(@as(i32, @intCast(@max(1, 9600 / fps))), app.clips.items[ci].len);

    waitImportsIdleForTest(&app, io);

    // 完成后：资产入池、样式挂上、峰值有内容
    try std.testing.expect(app.audio_styles.items[si].asset >= 0);
    const asset = app.audioStyleAsset(si) orelse return error.AssetMissing;
    try std.testing.expectEqual(@as(usize, 9600), asset.data.frame_count);
    try std.testing.expect(asset.peaks.len > 0);
    try std.testing.expectEqual(@as(usize, 1), app.audio_assets.items.len);
    // 播放表出现该行（每帧重算；下一帧就出声）
    app.rebuildAudioTable();
    const tbl = app.params.audio_table.load(.monotonic).?;
    try std.testing.expectEqual(@as(usize, 1), tbl.rows.len);
    try std.testing.expect(tbl.rows[0].asset != null);
}

test "P2 异步导入：取消 → 缓冲释放、样式保持缺失态（无泄漏）" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}/p2c.wav", .{dirp});
    defer alloc.free(wav_path);
    try writeSineWavForTest(io, alloc, wav_path, 48000 * 3, 48000); // 3 s：够长，能被打断

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);

    const s = app.audioStyleAddAsync(wav_path, "取消") orelse return error.StyleFailed;
    const si: usize = @intCast(s);
    app.import_mgr.cancelAll();
    app.import_mgr.drain(); // 等 worker 收手（正常 1 ms 级）
    waitImportsIdleForTest(&app, io);

    try std.testing.expectEqual(@as(i32, -1), app.audio_styles.items[si].asset);
    try std.testing.expectEqual(@as(usize, 0), app.audio_assets.items.len);
    try std.testing.expect(!app.import_mgr.busy());
}

test "P2 异步导入：非音频文件 → 建样式失败（不产生占位样式）" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const txt = try std.fmt.allocPrint(alloc, "{s}/notaudio.wav", .{dirp});
    defer alloc.free(txt);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = txt, .data = "hello, not audio" });

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);

    try std.testing.expectEqual(@as(?i32, null), app.audioStyleAddAsync(txt, ""));
    try std.testing.expectEqual(@as(usize, 0), app.audio_styles.items.len);
}

test "app: 新建空工程 → 音频样式与资产池一并清空（含异步导入中）" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}/reset.wav", .{dirp});
    defer alloc.free(wav_path);
    try writeSineWavForTest(io, alloc, wav_path, 9600, 48000);

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.sel.song_mode = true;

    // 导入 + 放片段（模拟用户刚拖进来的音频）
    const s = app.audioStyleAddAsync(wav_path, "将随工程消失") orelse return error.StyleFailed;
    _ = app.audioClipAdd(s, 0, 0) orelse return error.ClipFailed;
    waitImportsIdleForTest(&app, io);
    try std.testing.expectEqual(@as(usize, 1), app.audio_styles.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.audio_assets.items.len);
    app.rebuildAudioTable();
    try std.testing.expect(app.params.audio_table.load(.monotonic).?.rows.len == 1);

    // 新建（空）工程：样式/资产/音频片段全部消失，内存释放（testing.allocator 查泄漏）
    app.resetToDefaultProject();

    try std.testing.expectEqual(@as(usize, 0), app.audio_styles.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.audio_assets.items.len);
    try std.testing.expectEqual(@as(i32, -1), app.audio_style_sel);
    try std.testing.expect(!app.panels.patterns_tab_audio);
    // 片段回到默认的 1 个**音符**片段（不是音频）
    try std.testing.expectEqual(@as(usize, 1), app.clips.items.len);
    try std.testing.expect(!app.clips.items[0].isAudio());
    // 播放表已发布空表（不让音频线程摸已释放的资产）
    try std.testing.expectEqual(@as(usize, 0), app.params.audio_table.load(.monotonic).?.rows.len);
}

test "app: 导入中新建空工程 → 取消在跑的导入，不崩不泄" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);
    const wav_path = try std.fmt.allocPrint(alloc, "{s}/inflight.wav", .{dirp});
    defer alloc.free(wav_path);
    try writeSineWavForTest(io, alloc, wav_path, 48000 * 3, 48000);

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);

    _ = app.audioStyleAddAsync(wav_path, "导入中") orelse return error.StyleFailed;
    app.resetToDefaultProject(); // 导入可能还在跑：必须取消 + join 前等待
    try std.testing.expectEqual(@as(usize, 0), app.audio_styles.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.audio_assets.items.len);
    try std.testing.expect(!app.import_mgr.busy());
}
test "音频资产池：追加资产不移动已有 Asset —— 播放表指针稳定（回归：播放中导入崩溃）" {
    // 曾经的实现是 `ArrayListUnmanaged(AudioAsset)`：导入完成时 append 触发扩容，
    // 已有 AudioAsset 被搬到新内存，而**音频线程的播放表**里存的是 `&asset.data`
    // → 播放中导入 = 读已释放内存（实测：边播边导入一会儿就崩）。
    // 现在池子里放的是 `*AudioAsset`（本体单独分配），地址恒定。
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);

    var app = App{ .allocator = alloc };
    app.attachIo(io);
    defer app.clips.deinit(alloc);
    defer app.notes.deinit(alloc);
    defer app.deinitAll();
    app.resetPatterns(1);
    app.resetMixerChannels(default_mixer_channels);
    app.sel.song_mode = true;

    const p0 = try std.fmt.allocPrint(alloc, "{s}/a0.wav", .{dirp});
    defer alloc.free(p0);
    try writeSineWavForTest(io, alloc, p0, 4800, 48000);
    const s0 = app.audioStyleAdd(p0, "") orelse return error.StyleFailed;
    _ = app.audioClipAdd(s0, 0, 0) orelse return error.ClipFailed;
    app.rebuildAudioTable();
    const tbl = app.params.audio_table.load(.monotonic).?;
    try std.testing.expectEqual(@as(usize, 1), tbl.rows.len);
    const sample0 = tbl.rows[0].asset.?; // 音频线程看到的就是这个指针
    const frames0 = sample0.frame_count;
    const first0 = sample0.frames[0];

    // 追加 12 个资产（必然触发多次扩容）
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const pn = try std.fmt.allocPrint(alloc, "{s}/a{d}.wav", .{ dirp, i + 1 });
        defer alloc.free(pn);
        try writeSineWavForTest(io, alloc, pn, 960 + i * 120, 48000);
        _ = app.audioStyleAdd(pn, "") orelse return error.StyleFailed;
    }
    try std.testing.expectEqual(@as(usize, 13), app.audio_assets.items.len);

    // 旧指针仍指向有效数据（内容不变）
    try std.testing.expectEqual(frames0, sample0.frame_count);
    try std.testing.expectEqual(first0, sample0.frames[0]);
    try std.testing.expectEqual(frames0, app.audioStyleAsset(@intCast(s0)).?.data.frame_count);
}

test "工程加载（异步解码）：工程立刻可见，音频随后就位" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.dir.close(io);
    const dirp = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dirp);

    // 源 App：两个音频样式 + 两个音频片段 → 导出存档 JSON
    var a1 = App{ .allocator = alloc };
    a1.attachIo(io);
    defer a1.clips.deinit(alloc);
    defer a1.notes.deinit(alloc);
    defer a1.deinitAll();
    a1.resetPatterns(1);
    a1.resetMixerChannels(default_mixer_channels);
    a1.sel.song_mode = true;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const pth = try std.fmt.allocPrint(alloc, "{s}/aload{d}.wav", .{ dirp, i });
        defer alloc.free(pth);
        try writeSineWavForTest(io, alloc, pth, 4800, 48000);
        const s = a1.audioStyleAdd(pth, "") orelse return error.StyleFailed;
        _ = a1.audioClipAdd(s, @intCast(i), 0) orelse return error.ClipFailed;
    }
    const proj = try a1.exportProject();
    defer a1.freeProject(proj);
    const json = try std.json.Stringify.valueAlloc(alloc, proj, .{});
    defer alloc.free(json);

    // 目标 App：异步加载（UI 线程不阻塞）
    var a2 = App{ .allocator = alloc };
    a2.attachIo(io);
    defer a2.clips.deinit(alloc);
    defer a2.notes.deinit(alloc);
    defer a2.deinitAll();
    a2.resetPatterns(1);
    a2.resetMixerChannels(default_mixer_channels);

    const parsed = try persist.parseAuto(alloc, json);
    a2.beginProjectLoadAsync(parsed, null);
    // 立刻可见：样式与片段都已就位（音频可能还在解码 → asset = -1 但长度正确）
    try std.testing.expectEqual(@as(usize, 2), a2.audio_styles.items.len);
    var audio_clips: usize = 0;
    for (a2.clips.items) |c| {
        if (c.isAudio()) audio_clips += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), audio_clips);
    try std.testing.expect(!a2.dirty); // 打开 = 已保存基线
    try std.testing.expectEqual(@as(usize, 1), a2.history.items.len);

    // 等后台解码收尾 → 两个资产都挂上
    waitImportsIdleForTest(&a2, io);
    try std.testing.expectEqual(@as(usize, 2), a2.audio_assets.items.len);
    try std.testing.expect(a2.audioStyleAsset(0) != null);
    try std.testing.expect(a2.audioStyleAsset(1) != null);
    try std.testing.expectEqual(@as(usize, 0), a2.audioLoadPending());
}
