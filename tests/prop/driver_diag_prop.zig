//! Property & fuzz tests for `driver/diag.zig` (bounded UTF-8-safe failure screen rendering).
const std = @import("std");
const claude_p = @import("claude_p");

const diag = claude_p.driver.runtime.diag;
const testing = std.testing;

fn fuzzFailureScreen(_: void, input: []const u8) anyerror!void {
    var out: [diag.failure_screen_max_bytes]u8 = undefined;
    const screen = diag.formatFailureScreen(&out, input);
    try testing.expect(screen.len <= diag.failure_screen_max_bytes);
    try testing.expect(std.mem.count(u8, screen, "\n") < diag.failure_screen_max_lines);
    for (screen) |b| {
        if (b != '\n') try testing.expect(b >= 0x20 and b != 0x7f);
    }
}

test "fuzz: formatFailureScreen enforces line, byte, and control-char bounds" {
    try std.testing.fuzz({}, fuzzFailureScreen, .{
        .corpus = &.{ "", "\x1b[31merr\x1b[0m\r\n", "a\n" ** 30, "é" ** 600 },
    });
}
