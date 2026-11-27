//! Property & fuzz tests for `driver/spawn.zig` (shell quoting and child env stripping).
const std = @import("std");
const claude_p = @import("claude_p");

const spawn_mod = claude_p.driver.env.spawn;
const testing = std.testing;

fn fuzzShellQuoteAndStrip(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    const quoted = try spawn_mod.shellQuoteArgv(testing.allocator, &.{input});
    defer testing.allocator.free(quoted);
    try testing.expect(quoted.len >= 2);
    try testing.expectEqual(@as(u8, '\''), quoted[0]);
    try testing.expectEqual(@as(u8, '\''), quoted[quoted.len - 1]);
    _ = spawn_mod.shouldStripChildEnv(input);
}

test "fuzz: spawn.shellQuoteArgv and shouldStripChildEnv never crash or leak" {
    try std.testing.fuzz({}, fuzzShellQuoteAndStrip, .{
        .corpus = &.{ "it's", "CLAUDECODE", "CLAUDE_CODE_SESSION_1", "CLAUDE_CODE_OAUTH_TOKEN" },
    });
}
