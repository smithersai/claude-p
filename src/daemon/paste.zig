//! Non-blocking paced bracketed-paste state machine for daemon prompt injection.
const std = @import("std");
const driver_mod = @import("../driver.zig");

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

/// Non-blocking state machine that paces bracketed-paste writes between loop ticks.
pub const PendingPaste = struct {
    chunker: driver_mod.PasteChunker,
    stage: enum { chunks, enter_debounce } = .chunks,
    next_at_ns: i128 = 0,
    is_reinject: bool,

    /// Create a new paced paste state machine for `text`.
    pub fn init(text: []const u8, is_reinject: bool) PendingPaste {
        return .{ .chunker = .{ .text = text }, .is_reinject = is_reinject };
    }

    /// Advance the state machine if its inter-chunk or Enter debounce timer is due.
    /// Returns true once the terminating `\r` has been written to `sink`.
    pub fn advance(self: *PendingPaste, sink: anytype) !bool {
        std.debug.assert(self.chunker.pos <= self.chunker.text.len);
        const now: i128 = monotonicNs();
        if (now < self.next_at_ns) return false;
        switch (self.stage) {
            .chunks => {
                if (self.chunker.pos == 0) try sink.writeInput(driver_mod.paste_start);
                var buf: [driver_mod.paste_chunk_bytes]u8 = undefined;
                if (self.chunker.next(&buf)) |chunk| {
                    std.debug.assert(chunk.len > 0 and chunk.len <= buf.len);
                    try sink.writeInput(chunk);
                    self.next_at_ns = now + driver_mod.paste_chunk_gap_ms * std.time.ns_per_ms;
                } else {
                    try sink.writeInput(driver_mod.paste_end);
                    self.stage = .enter_debounce;
                    self.next_at_ns = now + driver_mod.ink_enter_debounce_ms * std.time.ns_per_ms;
                }
                return false;
            },
            .enter_debounce => {
                try sink.writeInput("\r");
                return true;
            },
        }
    }

    /// Cancel an in-progress paste cleanly by closing bracketed-paste mode and sending Ctrl-U.
    pub fn cancel(self: PendingPaste, sink: anytype) !void {
        std.debug.assert(self.chunker.pos <= self.chunker.text.len);
        if (self.stage == .chunks and self.chunker.pos != 0) try sink.writeInput(driver_mod.paste_end);
        try sink.writeInput("\x15");
    }
};

// -------- tests --------
const testing = std.testing;

const TestSink = struct {
    aw: std.Io.Writer.Allocating,
    pub fn writeInput(self: *@This(), data: []const u8) !void {
        try self.aw.writer.writeAll(data);
    }
};

test "PendingPaste: init sets chunks stage and reinject flag" {
    const p1 = PendingPaste.init("hi", false);
    try testing.expect(!p1.is_reinject);
    try testing.expectEqual(@as(usize, 0), p1.chunker.pos);
    const p2 = PendingPaste.init("hi", true);
    try testing.expect(p2.is_reinject);
}

test "PendingPaste: advances through paste_start, chunk, paste_end, and CR" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hello", false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqualStrings(driver_mod.paste_start ++ "hello" ++ driver_mod.paste_end ++ "\r", sink.aw.written());
}

test "PendingPaste: waits when next_at_ns is in the future" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hello", false);
    p.next_at_ns = std.math.maxInt(i128);
    try testing.expect(!try p.advance(&sink));
    try testing.expectEqual(@as(usize, 0), sink.aw.written().len);
}

test "PendingPaste: first advance emits paste_start and first chunk" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hello", false);
    try testing.expect(!try p.advance(&sink));
    try testing.expectEqualStrings(driver_mod.paste_start ++ "hello", sink.aw.written());
    try testing.expect(p.next_at_ns > 0);
}

test "PendingPaste: multi-chunk prompt emits paste_start once" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("a" ** (driver_mod.paste_chunk_bytes * 2 + 5), false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.aw.written(), driver_mod.paste_start));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.aw.written(), driver_mod.paste_end));
    try testing.expect(std.mem.endsWith(u8, sink.aw.written(), driver_mod.paste_end ++ "\r"));
}

test "PendingPaste: empty prompt emits start, end, then CR" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("", false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqualStrings(driver_mod.paste_start ++ driver_mod.paste_end ++ "\r", sink.aw.written());
}

test "PendingPaste: cancel before first byte sends only Ctrl-U" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    try PendingPaste.init("abc", true).cancel(&sink);
    try testing.expectEqualStrings("\x15", sink.aw.written());
}

test "PendingPaste: cancel mid-paste closes bracketed paste before Ctrl-U" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("a" ** 600, false);
    try testing.expect(!try p.advance(&sink));
    try p.cancel(&sink);
    try testing.expect(std.mem.endsWith(u8, sink.aw.written(), driver_mod.paste_end ++ "\x15"));
}

test "PendingPaste: cancel in enter_debounce sends only Ctrl-U" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hi", false);
    p.stage = .enter_debounce;
    try p.cancel(&sink);
    try testing.expectEqualStrings("\x15", sink.aw.written());
}

test "PendingPaste: neutralizes embedded paste_end inside prompt" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("a" ++ driver_mod.paste_end ++ "b", false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.aw.written(), driver_mod.paste_end));
}

test "PendingPaste: preserves UTF-8 multibyte boundaries across chunks" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    const prompt = "🌿" ** 200;
    var p = PendingPaste.init(prompt, false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expect(std.mem.indexOf(u8, sink.aw.written(), prompt) != null);
}

test "PendingPaste: propagates sink write error from advance" {
    const FailSink = struct {
        pub fn writeInput(_: *@This(), _: []const u8) !void {
            return error.BrokenPipe;
        }
    };
    var sink: FailSink = .{};
    var p = PendingPaste.init("hi", false);
    try testing.expectError(error.BrokenPipe, p.advance(&sink));
}

test "PendingPaste: propagates sink write error from cancel" {
    const FailSink = struct {
        pub fn writeInput(_: *@This(), _: []const u8) !void {
            return error.BrokenPipe;
        }
    };
    var sink: FailSink = .{};
    try testing.expectError(error.BrokenPipe, PendingPaste.init("hi", false).cancel(&sink));
}

test "PendingPaste: enter_debounce transitions to done on due tick" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hi", false);
    p.stage = .enter_debounce;
    p.next_at_ns = 0;
    try testing.expect(try p.advance(&sink));
    try testing.expectEqualStrings("\r", sink.aw.written());
}

test "PendingPaste: enter_debounce waits while next_at_ns is in the future" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hi", false);
    p.stage = .enter_debounce;
    p.next_at_ns = std.math.maxInt(i128);
    try testing.expect(!try p.advance(&sink));
}

test "PendingPaste: reinject flag persists across advances" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("hi", true);
    _ = try p.advance(&sink);
    try testing.expect(p.is_reinject);
}

test "PendingPaste: newlines inside prompt are preserved verbatim" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("line1\nline2\n", false);
    while (true) {
        p.next_at_ns = 0;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqualStrings(driver_mod.paste_start ++ "line1\nline2\n" ++ driver_mod.paste_end ++ "\r", sink.aw.written());
}

test "PendingPaste: exact chunk-size prompt finishes in 3 ticks" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("x" ** driver_mod.paste_chunk_bytes, false);
    var ticks: usize = 0;
    while (true) {
        p.next_at_ns = 0;
        ticks += 1;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqual(@as(usize, 3), ticks);
}

test "PendingPaste: chunk_size + 1 prompt finishes in 4 ticks" {
    var sink: TestSink = .{ .aw = .init(testing.allocator) };
    defer sink.aw.deinit();
    var p = PendingPaste.init("x" ** (driver_mod.paste_chunk_bytes + 1), false);
    var ticks: usize = 0;
    while (true) {
        p.next_at_ns = 0;
        ticks += 1;
        if (try p.advance(&sink)) break;
    }
    try testing.expectEqual(@as(usize, 4), ticks);
}

test "PendingPaste: monotonicNs returns positive value" {
    try testing.expect(monotonicNs() > 0);
}
