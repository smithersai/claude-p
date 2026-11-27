//! Minimal scanner for the handful of DEC / XTerm queries Ink (the React-for-
//! terminals runtime Claude Code uses) emits at startup. Without responses
//! the UI hangs forever waiting for a terminal it thinks is broken.
//!
//! Recognised:
//!   - DA1: `ESC [ c` or `ESC [ 0 c`        → "VT100 with AVO"
//!   - DA2: `ESC [ > c` or `ESC [ > 0 c`    → "claude-p 0/0"
//!   - DSR cursor position: `ESC [ 6 n`     → row 1 col 1
//!   - XTVERSION: `ESC [ > q` or `ESC [ > 0 q`
//!   - Window-size report: `ESC [ 18 t`     → `ESC [ 8 ; rows ; cols t`
//!
//! `DecDecoder` is the streaming form: it carries a trailing incomplete ESC /
//! CSI across `feed` calls, so a query split at any byte boundary between two
//! PTY reads is still answered. `respondToDecQueries` and
//! `respondToDecQueriesSized` are the one-shot forms: they run a fresh decoder
//! over a single chunk and drop whatever is left incomplete at its end.
//! Callers append the response bytes (if any) from `out` back to the PTY.
const std = @import("std");

/// Default terminal row count reported to window-size queries.
pub const default_rows: u16 = 40;
/// Default terminal column count reported to window-size queries.
pub const default_cols: u16 = 120;

/// Streaming DEC / XTerm query responder. One instance per PTY; not
/// thread-safe.
pub const DecDecoder = struct {
    /// Pending incomplete sequence: `ESC`, or `ESC [` plus parameter and
    /// intermediate bytes. The longest query answered is 5 bytes, so a
    /// sequence that outgrows the buffer can never earn a reply.
    carry: [32]u8 = undefined,
    carry_len: usize = 0,
    /// Dimensions reported for the window-size query (`ESC [ 18 t`).
    rows: u16 = default_rows,
    cols: u16 = default_cols,

    /// Scan `chunk`, appending the reply for every query that completes in
    /// it to `out`. An incomplete trailing sequence waits for the next call.
    /// On `error.OutOfMemory` the decoder is left mid-chunk; call `reset`
    /// before reusing it.
    pub fn feed(
        self: *DecDecoder,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        std.debug.assert(self.carry_len <= self.carry.len);
        for (chunk) |b| {
            if (self.carry_len == 0) {
                if (b == 0x1b) self.start();
                continue;
            }
            if (self.carry_len == 1) {
                if (b == '[') {
                    self.carry[1] = b;
                    self.carry_len = 2;
                } else if (b != 0x1b) {
                    self.carry_len = 0;
                }
                continue;
            }

            // Inside a CSI: parameter bytes (0x30-0x3f), then intermediate
            // bytes (0x20-0x2f), then one final byte.
            const last = self.carry[self.carry_len - 1];
            const in_intermediates = self.carry_len > 2 and last >= 0x20 and last <= 0x2f;
            const is_param = b >= 0x30 and b <= 0x3f and !in_intermediates;
            const is_intermediate = b >= 0x20 and b <= 0x2f;
            if (is_param or is_intermediate) {
                if (self.carry_len == self.carry.len) {
                    // Too long to be a supported query. The rest of the
                    // sequence holds no ESC, so plain scanning skips it.
                    self.carry_len = 0;
                } else {
                    self.carry[self.carry_len] = b;
                    self.carry_len += 1;
                }
                continue;
            }

            std.debug.assert(self.carry_len >= 2 and self.carry_len <= self.carry.len);
            const body = self.carry[2..self.carry_len];
            // An ESC interrupts the unfinished CSI and starts a new sequence.
            if (b == 0x1b) self.start() else self.carry_len = 0;
            try self.reply(allocator, body, b, out);
        }
    }

    /// Drop any pending incomplete sequence.
    pub fn reset(self: *DecDecoder) void {
        self.carry_len = 0;
        std.debug.assert(self.carry_len == 0);
    }

    fn start(self: *DecDecoder) void {
        self.carry[0] = 0x1b;
        self.carry_len = 1;
        std.debug.assert(self.carry[0] == 0x1b);
    }

    fn reply(
        self: *const DecDecoder,
        allocator: std.mem.Allocator,
        body: []const u8,
        final: u8,
        out: *std.ArrayList(u8),
    ) !void {
        const private_gt = body.len > 0 and body[0] == '>';
        const params = body[@intFromBool(private_gt)..];
        const default_param = params.len == 0 or std.mem.eql(u8, params, "0");

        switch (final) {
            'c' => {
                if (!default_param) return;
                if (private_gt) {
                    try out.appendSlice(allocator, "\x1b[>0;0;0c");
                } else {
                    try out.appendSlice(allocator, "\x1b[?1;2c");
                }
            },
            'n' => {
                if (!private_gt and std.mem.eql(u8, params, "6")) {
                    try out.appendSlice(allocator, "\x1b[1;1R");
                }
            },
            'q' => {
                if (private_gt and default_param) {
                    try out.appendSlice(allocator, "\x1bP>|claude-p\x1b\\");
                }
            },
            't' => {
                if (!private_gt and std.mem.eql(u8, params, "18")) {
                    var buf: [24]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "\x1b[8;{d};{d}t", .{ self.rows, self.cols }) catch {
                        return error.OutOfMemory;
                    };
                    std.debug.assert(text.len <= buf.len);
                    try out.appendSlice(allocator, text);
                }
            },
            else => {},
        }
    }
};

/// One-shot scan of a single chunk with the default 40x120 window size.
/// A query cut off by the end of `bytes` is dropped; use `DecDecoder` when
/// chunks come from consecutive PTY reads.
pub fn respondToDecQueries(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    out: *std.ArrayList(u8),
) !void {
    return respondToDecQueriesSized(allocator, bytes, default_rows, default_cols, out);
}

/// One-shot scan that reports `rows` x `cols` for the window-size query.
pub fn respondToDecQueriesSized(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    rows: u16,
    cols: u16,
    out: *std.ArrayList(u8),
) !void {
    var decoder: DecDecoder = .{ .rows = rows, .cols = cols };
    try decoder.feed(allocator, bytes, out);
}

// -------- tests --------

const testing = std.testing;

test "DA1 query gets a response" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[c", &out);
    try testing.expectEqualStrings("\x1b[?1;2c", out.items);
}

test "DA2 query gets a response" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[>c", &out);
    try testing.expectEqualStrings("\x1b[>0;0;0c", out.items);
}

test "DSR cursor position responds with 1;1" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[6n", &out);
    try testing.expectEqualStrings("\x1b[1;1R", out.items);
}

test "XTVERSION query responds with DCS string" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[>q", &out);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1bP>|claude-p"));
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b\\"));
}

test "ignores non-CSI bytes" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "hello world without esc", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "multiple queries in one chunk" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "hi\x1b[cthere\x1b[>cyo", &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1;2c") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[>0;0;0c") != null);
}

test "window-size reply reports the configured rows and cols" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[18t", &out);
    try testing.expectEqualStrings("\x1b[8;40;120t", out.items);

    out.clearRetainingCapacity();
    try respondToDecQueriesSized(testing.allocator, "\x1b[18t", 24, 80, &out);
    try testing.expectEqualStrings("\x1b[8;24;80t", out.items);

    out.clearRetainingCapacity();
    var decoder: DecDecoder = .{ .rows = 65535, .cols = 1 };
    try decoder.feed(testing.allocator, "\x1b[18t", &out);
    try testing.expectEqualStrings("\x1b[8;65535;1t", out.items);
}

test "DecDecoder answers a query split across two feeds" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);

    // The stateless scanner drops both halves.
    try respondToDecQueries(testing.allocator, "\x1b[", &out);
    try respondToDecQueries(testing.allocator, "6n", &out);
    try testing.expectEqualStrings("", out.items);

    var decoder: DecDecoder = .{};
    try decoder.feed(testing.allocator, "hi\x1b", &out);
    try testing.expectEqualStrings("", out.items);
    try decoder.feed(testing.allocator, "[", &out);
    try decoder.feed(testing.allocator, "6", &out);
    try testing.expectEqualStrings("", out.items);
    try decoder.feed(testing.allocator, "n\x1b[>", &out);
    try testing.expectEqualStrings("\x1b[1;1R", out.items);
    try decoder.feed(testing.allocator, "0q", &out);
    try testing.expectEqualStrings("\x1b[1;1R\x1bP>|claude-p\x1b\\", out.items);
    try testing.expectEqual(@as(usize, 0), decoder.carry_len);
}

test "DecDecoder drops an overlong CSI and still answers the next query" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    var decoder: DecDecoder = .{};
    try decoder.feed(testing.allocator, "\x1b[" ++ "0;" ** 64, &out);
    try testing.expectEqual(@as(usize, 0), decoder.carry_len);
    try decoder.feed(testing.allocator, "0c\x1b[c", &out);
    try testing.expectEqualStrings("\x1b[?1;2c", out.items);
}

test "DecDecoder reset drops the pending sequence" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    var decoder: DecDecoder = .{};
    try decoder.feed(testing.allocator, "\x1b[6", &out);
    try testing.expectEqual(@as(usize, 3), decoder.carry_len);
    decoder.reset();
    try decoder.feed(testing.allocator, "n", &out);
    try testing.expectEqualStrings("", out.items);
}

test "DA1 explicit 0 parameter gets a response" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[0c", &out);
    try testing.expectEqualStrings("\x1b[?1;2c", out.items);
}

test "DA1 non-zero parameter is ignored" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[1c\x1b[2c", &out);
    try testing.expectEqualStrings("", out.items);
}

test "DA2 explicit 0 parameter gets a response" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[>0c", &out);
    try testing.expectEqualStrings("\x1b[>0;0;0c", out.items);
}

test "DA2 non-zero parameter is ignored" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[>1c", &out);
    try testing.expectEqualStrings("", out.items);
}

test "XTVERSION explicit 0 parameter responds and non-zero is ignored" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[>0q\x1b[>1q\x1b[q", &out);
    try testing.expectEqualStrings("\x1bP>|claude-p\x1b\\", out.items);
}

test "DSR non-6 and private-gt 6n are ignored" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[5n\x1b[>6n\x1b[n", &out);
    try testing.expectEqualStrings("", out.items);
}

test "window-size query ignores non-18 and private-gt 18t" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[19t\x1b[>18t\x1b[t", &out);
    try testing.expectEqualStrings("", out.items);
}

test "ESC interrupting an incomplete CSI starts a fresh query" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[6\x1b[c", &out);
    try testing.expectEqualStrings("\x1b[?1;2c", out.items);
}

test "repeated ESC bytes before bracket still recognise CSI" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b\x1b[6n", &out);
    try testing.expectEqualStrings("\x1b[1;1R", out.items);
}

test "intermediate bytes after params prevent false matches" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    try respondToDecQueries(testing.allocator, "\x1b[0 c\x1b[6 n\x1b[18 t", &out);
    try testing.expectEqualStrings("", out.items);
}

test "empty chunk and non-bracket ESC sequence produce no reply" {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(testing.allocator);
    var decoder: DecDecoder = .{};
    try decoder.feed(testing.allocator, "", &out);
    try decoder.feed(testing.allocator, "\x1b(B\x1b]0;title\x07", &out);
    try testing.expectEqualStrings("", out.items);
    try testing.expectEqual(@as(usize, 0), decoder.carry_len);
}
