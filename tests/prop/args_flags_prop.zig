//! Property & fuzz tests for `args/flags.zig` (flag table matching and hook parsing).
const std = @import("std");
const claude_p = @import("claude_p");

const flags = claude_p.args.flags;
const testing = std.testing;

fn fuzzFlagMatchers(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    _ = flags.OutputFormat.fromString(input);
    _ = flags.isKnownBoolean(input);
    _ = flags.isRejectedFlag(input);
    _ = flags.matchFlag(input, flags.value_flag_table);
    _ = flags.parseExtraHook(input) catch {};
    _ = flags.parseU32(input) catch {};
}

test "fuzz: args/flags matchers never crash on arbitrary inputs" {
    try std.testing.fuzz({}, fuzzFlagMatchers, .{
        .corpus = &.{ "-p", "-pc", "--model=opus", "Stop=echo 1=2", "300", "--bare" },
    });
}
