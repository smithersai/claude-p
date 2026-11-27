//! Property & fuzz tests for `transcript/file.zig` (path validation invariants).
const std = @import("std");
const claude_p = @import("claude_p");

const file_mod = claude_p.transcript.file;
const testing = std.testing;

fn fuzzValidatePath(_: void, input: []const u8) anyerror!void {
    const ok = file_mod.validateTranscriptPath(input);
    if (ok) {
        try testing.expect(input.len > 0 and input[0] == '/');
        try testing.expect(std.mem.indexOfScalar(u8, input, 0) == null);
    }
}

test "fuzz: validateTranscriptPath enforces absolute, NUL-free, traversal-free invariant" {
    try std.testing.fuzz({}, fuzzValidatePath, .{
        .corpus = &.{ "", "/", "/tmp/a.jsonl", "/tmp/../etc/passwd", "/a\x00b", "relative" },
    });
}
