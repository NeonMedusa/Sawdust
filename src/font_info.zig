//! 字体运行时信息（供设置页显示"当前实际生效的字体"）。
//!
//! 为什么单独一个模块：`main.zig` 与 `view_settings.zig` 不能互相 import（会成环），
//! 而这条信息只是"诊断展示"，不值得塞进 `App` 再到处传。

/// 设置页请求"重新加载字体"（主循环在帧首处理；见 `main.loadFont`）
pub var reload_requested: bool = false;

var active_buf: [512]u8 = undefined;
var active_len: usize = 0;

/// 记录实际生效的字体文件路径（由 `main.loadFont` 在选中后调用）。
pub fn setActive(path: []const u8) void {
    const m = @min(path.len, active_buf.len);
    @memcpy(active_buf[0..m], path[0..m]);
    active_len = m;
}

/// 当前实际生效的字体路径（未加载成功时为空）。
pub fn active() []const u8 {
    return active_buf[0..active_len];
}

test "setActive/active 往返（含截断）" {
    const testing = @import("std").testing;
    setActive("/usr/share/fonts/wqy-microhei/wqy-microhei.ttc");
    try testing.expectEqualStrings("/usr/share/fonts/wqy-microhei/wqy-microhei.ttc", active());
    setActive("");
    try testing.expectEqualStrings("", active());
}
