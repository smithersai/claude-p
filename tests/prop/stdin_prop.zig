//! Property & fuzz tests for `stdin.zig` (prompt composition and timeout budget invariants).
const std = @import("std");
const claude_p = @import("claude_p");

const stdin_mod = claude_p.stdin;
const testing = std.testing;

fn fuzzComposePrompt(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    const split = input.len / 2;
    const piped = input[0..split];
    const prompt = input[split..];
    const out = try stdin_mod.composePrompt(testing.allocator, piped, prompt);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, prompt));
    const trimmed = std.mem.trimRight(u8, piped, "\r\n");
    if (trimmed.len == 0) {
        try testing.expectEqualStrings(prompt, out);
    } else {
        try testing.expect(std.mem.startsWith(u8, out, trimmed));
        try testing.expectEqual(trimmed.len + 2 + prompt.len, out.len);
    }
}

test "fuzz: composePrompt preserves suffix and blank-line separator invariant" {
    try std.testing.fuzz({}, fuzzComposePrompt, .{
        .corpus = &.{ "\n\r\nhi", "diff\n\nsummarize", "a\nb\nc" },
    });
}

test "prop: remainingTimeoutMs is monotonic non-increasing and >= 1" {
    for ([_]u32{ 0, 1, 10, 300, 3600 }) |secs| {
        const total = stdin_mod.timeoutMs(secs);
        var prev = total;
        for ([_]u64{ 0, 1, 500, 1000, 500_000, 10_000_000_000 }) |elapsed_ms| {
            const rem = stdin_mod.remainingTimeoutMs(total, elapsed_ms * std.time.ns_per_ms);
            try testing.expect(rem >= 1);
            try testing.expect(rem <= prev);
            prev = rem;
        }
    }
}
