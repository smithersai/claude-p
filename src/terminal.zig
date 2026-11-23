//! Minimal scanner for the handful of DEC / XTerm queries Ink (the React-for-
//! terminals runtime Claude Code uses) emits at startup. Without responses
//! the UI hangs forever waiting for a terminal it thinks is broken.
//!
//! Recognised:
//!   - DA1: `ESC [ c` or `ESC [ 0 c`        → "VT100 with AVO"
//!   - DA2: `ESC [ > c` or `ESC [ > 0 c`    → "claude-p 0/0"
//!   - DSR cursor position: `ESC [ 6 n`     → row 1 col 1
//!   - XTVERSION: `ESC [ > q` or `ESC [ > 0 q`
//!   - Window-size report: `ESC [ 18 t`     → "8 ; rows ; cols t"
//!
//! Pure function. Callers pass in incoming PTY bytes; we append the
//! response bytes (if any) to `out` for the caller to write back to the
//! PTY. Thread-safe by virtue of being state-free.
const std = @import("std");

pub fn respondToDecQueries(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    out: *std.ArrayList(u8),
) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b) continue; // ESC
        if (i + 1 >= bytes.len) break;
        if (bytes[i + 1] != '[') continue;

        var j = i + 2;
        const private_gt = j < bytes.len and bytes[j] == '>';
        if (private_gt) j += 1;
        while (j < bytes.len and bytes[j] >= 0x30 and bytes[j] <= 0x3f) : (j += 1) {}
        while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] <= 0x2f) : (j += 1) {}
        if (j >= bytes.len) break;
        const final = bytes[j];
        const params = bytes[i + 2 + @as(usize, if (private_gt) 1 else 0) .. j];
        // An ESC interrupts the unfinished CSI and starts a new sequence.
        i = if (final == 0x1b) j - 1 else j;
        const default_param = params.len == 0 or std.mem.eql(u8, params, "0");

        switch (final) {
            'c' => {
                if (!default_param) continue;
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
                    try out.appendSlice(allocator, "\x1b[8;40;120t");
                }
            },
            else => {},
        }
    }
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
