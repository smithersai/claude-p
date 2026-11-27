//! Property & fuzz tests for `driver/finalizer.zig` (`FinalizerState` Stop resolution).
const std = @import("std");
const claude_p = @import("claude_p");

const finalizer = claude_p.driver.finalizer;
const testing = std.testing;

fn fuzzRecordAndFallback(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    var f: finalizer.FinalizerState = .{ .allocator = testing.allocator, .deadline_ns = 0 };
    defer f.deinit();
    const is_failure = (input[0] & 1) != 0;
    try f.recordStop(is_failure, input[1..]);
    var sum = f.resolveFinalSummary() catch |err| switch (err) {
        error.TranscriptUnavailable => return,
        else => return err,
    };
    defer sum.deinit(testing.allocator);
    if (is_failure) try testing.expect(sum.is_error);
}

test "fuzz: FinalizerState recordStop + resolveFinalSummary never crashes or leaks" {
    try std.testing.fuzz({}, fuzzRecordAndFallback, .{
        .corpus = &.{
            "\x00{\"session_id\":\"s\",\"last_assistant_message\":\"ok\"}",
            "\x01{\"session_id\":\"s\",\"error\":\"overloaded\"}",
            "\x00{\"last_assistant_message\":\"   \"}",
            "\x01not-json",
        },
    });
}
