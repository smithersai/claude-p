//! Property & fuzz tests for `daemon/queue.zig` (`PromptQueue` FIFO and capacity invariants).
const std = @import("std");
const claude_p = @import("claude_p");

const queue_mod = claude_p.daemon.queue;
const protocol = claude_p.daemon.protocol;
const testing = std.testing;

fn fuzzPromptQueue(_: void, ops: []const u8) anyerror!void {
    if (ops.len == 0) return;
    var q: queue_mod.PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var model_len: usize = 0;
    var model_bytes: usize = 0;
    for (ops) |b| {
        if ((b & 1) == 0) {
            const sz: usize = @as(usize, (b >> 1) & 0x0f) + 1;
            const buf = try testing.allocator.alloc(u8, sz);
            @memset(buf, b);
            const ok = try q.push(testing.allocator, &aw.writer, buf);
            if (ok) {
                model_len += 1;
                model_bytes += sz;
            }
        } else if (q.pop()) |item| {
            model_len -= 1;
            model_bytes -= item.len;
            testing.allocator.free(item);
        }
        try testing.expectEqual(model_len, q.len());
        try testing.expectEqual(model_bytes, q.bytes);
        try testing.expect(q.len() <= protocol.max_queued_prompts);
        try testing.expect(q.bytes <= protocol.max_queued_bytes);
    }
}

test "fuzz: PromptQueue preserves len/bytes invariants under arbitrary push/pop sequences" {
    try std.testing.fuzz({}, fuzzPromptQueue, .{
        .corpus = &.{ "\x00\x02\x01\x01", "\x00" ** 100 ++ "\x01" ** 70, "\x04\x06\x01\x08\x01\x01" },
    });
}
