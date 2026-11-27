//! Property-based & fuzz tests for `daemon/protocol.zig` and `daemon/turn.zig`.
const std = @import("std");
const claude_p = @import("claude_p");
const protocol = claude_p.daemon.protocol;
const turn = claude_p.daemon.turn;

test "prop: LineBuffer never exceeds limit and preserves short line round-trip" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0xda3a_0001);
    const rng = prng.random();
    for (0..64) |_| {
        var lb: protocol.LineBuffer = .{};
        defer lb.bytes.deinit(t.allocator);
        const len = rng.intRangeAtMost(usize, 1, 256);
        const msg = try t.allocator.alloc(u8, len + 1);
        defer t.allocator.free(msg);
        for (msg[0..len]) |*b| b.* = 'a' + rng.intRangeAtMost(u8, 0, 25);
        msg[len] = '\n';

        var pos: usize = 0;
        var delivered: ?[]u8 = null;
        defer if (delivered) |d| t.allocator.free(d);
        while (pos < msg.len) {
            const step = rng.intRangeAtMost(usize, 1, @min(@as(usize, 17), msg.len - pos));
            var slice: []const u8 = msg[pos .. pos + step];
            pos += step;
            while (try lb.next(t.allocator, &slice, false)) |ev| {
                switch (ev) {
                    .line => |l| delivered = try t.allocator.dupe(u8, l),
                    .oversized => return error.TestUnexpectedResult,
                }
            }
        }
        try t.expect(delivered != null);
        try t.expectEqualStrings(msg[0..len], delivered.?);
        try t.expect(lb.bytes.capacity <= protocol.LineBuffer.limit);
    }
}

test "prop: idleTimedOut and transcriptStalled agree on all states and clocks" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0xda3a_0002);
    const rng = prng.random();
    const states = [_]protocol.State{ .waiting_for_ready, .idle, .busy };
    for (0..256) |_| {
        const st = states[rng.intRangeLessThan(usize, 0, states.len)];
        const last: i64 = rng.intRangeAtMost(i64, 0, 10_000_000) * std.time.ns_per_ms;
        const delta: i64 = rng.intRangeAtMost(i64, -5000, 500_000) * std.time.ns_per_ms;
        const now: i128 = @as(i128, last) + delta;
        const timeout_ms: u64 = rng.intRangeAtMost(u64, 0, 200_000);
        const a = protocol.idleTimedOut(st, last, now, timeout_ms);
        const b = protocol.transcriptStalled(st, last, now, timeout_ms);
        try t.expectEqual(a, b);
        if (st != .busy or last == 0 or timeout_ms == 0) try t.expect(!a);
    }
}

test "prop: PendingPaste always brackets output and ends with CR" {
    const t = std.testing;
    const Sink = struct {
        buf: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.alloc, data);
        }
    };
    var prng = std.Random.DefaultPrng.init(0xda3a_0003);
    const rng = prng.random();
    for (0..32) |_| {
        const len = rng.intRangeAtMost(usize, 0, 1400);
        const text = try t.allocator.alloc(u8, len);
        defer t.allocator.free(text);
        for (text) |*b| b.* = 0x20 + rng.intRangeAtMost(u8, 0, 90);
        var sink: Sink = .{ .alloc = t.allocator };
        defer sink.buf.deinit(t.allocator);
        var paste = turn.PendingPaste.init(text, false);
        while (true) {
            paste.next_at_ns = 0;
            if (try paste.advance(&sink)) break;
        }
        try t.expect(std.mem.startsWith(u8, sink.buf.items, claude_p.driver.paste_start));
        try t.expect(std.mem.endsWith(u8, sink.buf.items, claude_p.driver.paste_end ++ "\r"));
    }
}

test "fuzz: readInputFrame never panics on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn check(_: void, input: []const u8) !void {
            if (input.len == 0) return;
            var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            if (try protocol.readInputFrame(std.testing.allocator, &aw.writer, input)) |frame| {
                switch (frame) {
                    .user => |u| std.testing.allocator.free(u),
                    .ping, .interrupt => {},
                }
            }
        }
    }.check, .{ .corpus = &.{
        "{\"type\":\"ping\"}",
        "{\"type\":\"interrupt\"}",
        "{\"type\":\"user\",\"content\":\"hello\"}",
        "not json",
    } });
}
