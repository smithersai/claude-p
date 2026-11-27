//! Property & fuzz tests for `driver/stop_scan.zig` (Stop continuation & StopFailure synthesis).
const std = @import("std");
const claude_p = @import("claude_p");

const stop_scan = claude_p.driver.watchdog.stop_scan;
const testing = std.testing;

fn fuzzStopScan(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    _ = try stop_scan.isContinuationRecord(testing.allocator, input, "done", "hello");
    var sum = try stop_scan.synthesizeStopFailureSummary(testing.allocator, input);
    defer sum.deinit(testing.allocator);
    try testing.expect(sum.is_error);
    try testing.expect(sum.final_text.len > 0);
}

test "fuzz: stop_scan never crashes or leaks on arbitrary JSONL/payload input" {
    try std.testing.fuzz({}, fuzzStopScan, .{
        .corpus = &.{
            "{}",
            "{\"type\":\"tool_use\"}",
            "{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}",
            "{\"error\":\"overloaded\",\"session_id\":\"s\"}",
        },
    });
}
