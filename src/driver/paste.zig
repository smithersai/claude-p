//! Chunked DECSET 2004 bracketed paste with macOS TTYHOG=1024 safety,
//! UTF-8 boundary preservation, and embedded end-of-paste sanitization.
const std = @import("std");
const zmux = @import("zmux");
const env_mod = @import("env.zig");
const watchdog = @import("watchdog.zig");

/// DECSET 2004 bracketed-paste start escape sequence.
pub const paste_start = "\x1b[200~";
/// DECSET 2004 bracketed-paste end escape sequence.
pub const paste_end = "\x1b[201~";

/// Max bytes per PTY write chunk (half of macOS's 1024-byte `TTYHOG`).
pub const paste_chunk_bytes: usize = 512;

/// Pause between consecutive chunks so the child drains each write cleanly.
pub const paste_chunk_gap_ms: u64 = 8;

/// Splits prompt text into PTY-safe chunks (`<= paste_chunk_bytes`), never
/// splitting multi-byte UTF-8 codepoints and neutralizing embedded `\x1b[201~`.
pub const PasteChunker = struct {
    text: []const u8,
    pos: usize = 0,
    /// Number of leading bytes of `paste_end` that the emitted stream ends with.
    end_match: usize = 0,

    pub fn next(self: *PasteChunker, buf: *[paste_chunk_bytes]u8) ?[]const u8 {
        std.debug.assert(self.pos <= self.text.len and self.end_match < paste_end.len);
        var n: usize = 0;
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            if (n == buf.len) break;
            if (b >= 0xC0) {
                const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (n > 0 and n + seq_len > buf.len) break;
            }
            if (self.end_match == paste_end.len - 1 and b == paste_end[paste_end.len - 1]) {
                self.pos += 1;
                continue;
            }
            if (b == paste_end[self.end_match]) {
                self.end_match += 1;
            } else {
                self.end_match = if (b == paste_end[0]) 1 else 0;
            }
            buf[n] = b;
            n += 1;
            self.pos += 1;
        }
        std.debug.assert(n <= buf.len);
        if (n == 0) return null;
        return buf[0..n];
    }
};

/// Check interrupt flag and absolute deadline before performing a paste step.
pub fn checkDeadline(deadline_ns: i128) env_mod.RunError!void {
    if (watchdog.isInterrupted()) return error.Interrupted;
    if (watchdog.monotonicNs() >= deadline_ns) return error.StopTimeout;
}

/// Sleep up to `duration_ns` while honoring `deadline_ns` and interrupts.
pub fn pauseUntil(duration_ns: u64, deadline_ns: i128) env_mod.RunError!void {
    const end = @min(deadline_ns, watchdog.monotonicNs() + @as(i128, duration_ns));
    while (true) {
        try checkDeadline(deadline_ns);
        const remaining = end - watchdog.monotonicNs();
        if (remaining <= 0) return;
        std.Thread.sleep(@intCast(@min(remaining, @as(i128, 8 * std.time.ns_per_ms))));
    }
}

/// Write `text` to `sink` wrapped in bracketed-paste escapes with inter-chunk gaps.
pub fn writeBracketedPasteTo(sink: anytype, text: []const u8, gap_ns: u64) !void {
    return writePasteUntil(sink, text, gap_ns, std.math.maxInt(i128));
}

/// Write bracketed-paste chunks to `sink` until `deadline_ns`.
pub fn writePasteUntil(sink: anytype, text: []const u8, gap_ns: u64, deadline_ns: i128) !void {
    try checkDeadline(deadline_ns);
    try sink.writeInput(paste_start);
    var chunker: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    while (chunker.next(&buf)) |chunk| {
        std.debug.assert(chunk.len > 0 and chunk.len <= paste_chunk_bytes);
        try sink.writeInput(chunk);
        try pauseUntil(gap_ns, deadline_ns);
    }
    try sink.writeInput(paste_end);
}

/// Paste `text` to `sink`, wait `enter_debounce_ns`, and send `\r` to submit.
pub fn typePromptTo(sink: anytype, text: []const u8, gap_ns: u64, enter_debounce_ns: u64) !void {
    return typePromptUntil(sink, text, gap_ns, enter_debounce_ns, std.math.maxInt(i128));
}

/// Paste `text` and send `\r` to `sink` while respecting `deadline_ns`.
pub fn typePromptUntil(
    sink: anytype,
    text: []const u8,
    gap_ns: u64,
    enter_debounce_ns: u64,
    deadline_ns: i128,
) !void {
    try writePasteUntil(sink, text, gap_ns, deadline_ns);
    try pauseUntil(enter_debounce_ns, deadline_ns);
    try sink.writeInput("\r");
}

/// Send `text` as one DECSET 2004 bracketed paste over `session`.
pub fn writeBracketedPaste(session: *zmux.NativeSession, text: []const u8) !void {
    try writeBracketedPasteTo(session, text, paste_chunk_gap_ms * std.time.ns_per_ms);
}

/// Paste `text`, pause `ink_enter_debounce_ms`, and send `\r` over `session`.
pub fn typePrompt(session: *zmux.NativeSession, text: []const u8) !void {
    try typePromptTo(
        session,
        text,
        paste_chunk_gap_ms * std.time.ns_per_ms,
        watchdog.ink_enter_debounce_ms * std.time.ns_per_ms,
    );
}

// -------- tests --------
const testing = std.testing;

test "PasteChunker: empty text yields null immediately" {
    var c: PasteChunker = .{ .text = "" };
    var buf: [paste_chunk_bytes]u8 = undefined;
    try testing.expect(c.next(&buf) == null);
}

test "PasteChunker: short ASCII fits in one chunk" {
    var c: PasteChunker = .{ .text = "hello world" };
    var buf: [paste_chunk_bytes]u8 = undefined;
    try testing.expectEqualStrings("hello world", c.next(&buf).?);
    try testing.expect(c.next(&buf) == null);
}

test "PasteChunker: splits long text into <=512-byte chunks" {
    const big = "x" ** 1300;
    var c: PasteChunker = .{ .text = big };
    var buf: [paste_chunk_bytes]u8 = undefined;
    var total: usize = 0;
    var chunks: usize = 0;
    while (c.next(&buf)) |ch| {
        try testing.expect(ch.len <= paste_chunk_bytes);
        total += ch.len;
        chunks += 1;
    }
    try testing.expectEqual(@as(usize, 1300), total);
    try testing.expectEqual(@as(usize, 3), chunks);
}

test "PasteChunker: never splits 4-byte UTF-8 emoji across chunk boundary" {
    const text = "a" ** 510 ++ "\xf0\x9f\x9a\x80tail";
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    const c1 = c.next(&buf).?;
    try testing.expectEqual(@as(usize, 510), c1.len);
    const c2 = c.next(&buf).?;
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80tail", c2);
}

test "PasteChunker: never splits 3-byte UTF-8 char across chunk boundary" {
    const text = "a" ** 511 ++ "\xe2\x9c\x93!";
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    const c1 = c.next(&buf).?;
    try testing.expectEqual(@as(usize, 511), c1.len);
    try testing.expectEqualStrings("\xe2\x9c\x93!", c.next(&buf).?);
}

test "PasteChunker: never splits 2-byte UTF-8 char across chunk boundary" {
    const text = "a" ** 511 ++ "\xc3\xa9";
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    try testing.expectEqual(@as(usize, 511), c.next(&buf).?.len);
    try testing.expectEqualStrings("\xc3\xa9", c.next(&buf).?);
}

test "PasteChunker: neutralizes embedded ESC[201~" {
    var c: PasteChunker = .{ .text = "hi" ++ paste_end ++ "there" };
    var buf: [paste_chunk_bytes]u8 = undefined;
    const out = c.next(&buf).?;
    try testing.expect(std.mem.indexOf(u8, out, paste_end) == null);
    try testing.expectEqualStrings("hi\x1b[201there", out);
}

test "PasteChunker: neutralizes ESC[201~ split across chunk boundary" {
    const text = "a" ** 509 ++ paste_end ++ "z";
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(testing.allocator);
    while (c.next(&buf)) |ch| try joined.appendSlice(testing.allocator, ch);
    try testing.expect(std.mem.indexOf(u8, joined.items, paste_end) == null);
}

test "PasteChunker: neutralizes repeated back-to-back ESC[201~" {
    var c: PasteChunker = .{ .text = paste_end ++ paste_end };
    var buf: [paste_chunk_bytes]u8 = undefined;
    const out = c.next(&buf).?;
    try testing.expect(std.mem.indexOf(u8, out, paste_end) == null);
    try testing.expectEqualStrings("\x1b[201\x1b[201", out);
}

test "PasteChunker: handles overlapping ESC prefix before ESC[201~" {
    var c: PasteChunker = .{ .text = "\x1b" ++ paste_end };
    var buf: [paste_chunk_bytes]u8 = undefined;
    const out = c.next(&buf).?;
    try testing.expect(std.mem.indexOf(u8, out, paste_end) == null);
}

test "PasteChunker: preserves ESC[200~ and benign ESC sequences" {
    var c: PasteChunker = .{ .text = paste_start ++ "\x1b[31mred\x1b[0m" };
    var buf: [paste_chunk_bytes]u8 = undefined;
    try testing.expectEqualStrings(paste_start ++ "\x1b[31mred\x1b[0m", c.next(&buf).?);
}

test "PasteChunker: handles exact 512-byte ASCII boundary" {
    const text = "b" ** 512;
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    try testing.expectEqual(@as(usize, 512), c.next(&buf).?.len);
    try testing.expect(c.next(&buf) == null);
}

test "PasteChunker: handles invalid UTF-8 lead bytes without stalling" {
    const text = "a" ** 511 ++ "\xff\xfe!";
    var c: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    var total: usize = 0;
    while (c.next(&buf)) |ch| total += ch.len;
    try testing.expectEqual(text.len, total);
}

test "writeBracketedPasteTo: wraps text in paste_start and paste_end" {
    const Sink = struct {
        out: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.out.appendSlice(self.alloc, data);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.out.deinit(testing.allocator);
    try writeBracketedPasteTo(&sink, "hello", 0);
    try testing.expectEqualStrings(paste_start ++ "hello" ++ paste_end, sink.out.items);
}

test "writeBracketedPasteTo: empty text still emits start and end" {
    const Sink = struct {
        out: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.out.appendSlice(self.alloc, data);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.out.deinit(testing.allocator);
    try writeBracketedPasteTo(&sink, "", 0);
    try testing.expectEqualStrings(paste_start ++ paste_end, sink.out.items);
}

test "typePromptTo: emits paste frame then separate CR" {
    const Sink = struct {
        writes: std.ArrayList([]u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.writes.append(self.alloc, try self.alloc.dupe(u8, data));
        }
        fn deinit(self: *@This()) void {
            for (self.writes.items) |w| self.alloc.free(w);
            self.writes.deinit(self.alloc);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.deinit();
    try typePromptTo(&sink, "hi", 0, 0);
    try testing.expectEqual(@as(usize, 4), sink.writes.items.len);
    try testing.expectEqualStrings(paste_start, sink.writes.items[0]);
    try testing.expectEqualStrings("hi", sink.writes.items[1]);
    try testing.expectEqualStrings(paste_end, sink.writes.items[2]);
    try testing.expectEqualStrings("\r", sink.writes.items[3]);
}

test "checkDeadline: returns StopTimeout when expired" {
    try testing.expectError(error.StopTimeout, checkDeadline(0));
}

test "checkDeadline: returns Interrupted when interrupt is active" {
    const scope = watchdog.InterruptScope.enter();
    defer scope.exit();
    defer watchdog.clearInterrupt();
    watchdog.requestInterrupt();
    try testing.expectError(error.Interrupted, checkDeadline(std.math.maxInt(i128)));
}

test "writePasteUntil: aborts before start when deadline already expired" {
    const Sink = struct {
        calls: usize = 0,
        pub fn writeInput(self: *@This(), _: []const u8) !void {
            self.calls += 1;
        }
    };
    var sink: Sink = .{};
    try testing.expectError(error.StopTimeout, writePasteUntil(&sink, "hi", 0, 0));
    try testing.expectEqual(@as(usize, 0), sink.calls);
}

test "pauseUntil: completes immediately for zero duration before deadline" {
    try pauseUntil(0, std.math.maxInt(i128));
}
