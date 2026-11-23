//! Live transcript tailing. Used by the driver to emit Claude's session
//! JSONL transcript to stdout as it grows, giving us per-message streaming
//! output (the same granularity `claude -p --output-format stream-json`
//! produces).
//!
//! The transcript file is being written by the child `claude` process while
//! we read from it. We use `pread` so we never disturb the file's own offset
//! (Claude appends; we read from our own cursor) and we buffer incomplete
//! trailing fragments until the newline arrives.
const std = @import("std");
const transcript = @import("transcript.zig");

pub fn isForwardable(allocator: std.mem.Allocator, line: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    if (parsed.value.object.get("type")) |ty| {
        if (ty == .string and std.mem.eql(u8, ty.string, "result")) return false;
    }
    return true;
}

pub const default_max_partial_bytes: usize = 16 * 1024 * 1024;

pub const Tailer = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    pos: u64 = 0,
    /// Bytes read but not yet forwarded or discarded.
    partial: std.ArrayList(u8) = .{},

    scanned: usize = 0, // Prefix of the partial line already searched for LF.
    max_partial_bytes: usize = default_max_partial_bytes,
    discarding_oversized: bool = false,

    /// Open a file path for tailing. Caller owns the returned Tailer and must
    /// call `deinit`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Tailer {
        const file = try transcript.openTranscriptFile(path);
        return .{ .allocator = allocator, .file = file };
    }

    pub fn reopenAt(self: *Tailer, path: []const u8, offset: u64) !void {
        var next = try open(self.allocator, path);
        next.pos = offset;
        next.max_partial_bytes = self.max_partial_bytes;
        self.deinit();
        self.* = next;
    }

    pub fn deinit(self: *Tailer) void {
        self.file.close();
        self.partial.deinit(self.allocator);
    }

    fn forwardComplete(self: *Tailer, writer: *std.Io.Writer) !usize {
        var consumed: usize = 0;
        defer if (consumed != 0) {
            const rest = self.partial.items[consumed..];
            std.mem.copyForwards(u8, self.partial.items[0..rest.len], rest);
            self.partial.shrinkRetainingCapacity(rest.len);
            self.scanned -= consumed;
        };
        var emitted: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.partial.items, self.scanned, '\n')) |nl| {
            const line = self.partial.items[consumed .. nl + 1];
            if (try isForwardable(self.allocator, line)) {
                try writer.writeAll(line);
                emitted += 1;
            }
            consumed = nl + 1;
            self.scanned = consumed;
        }
        self.scanned = self.partial.items.len;
        return emitted;
    }

    /// Forward complete JSON objects, omitting upstream result envelopes.
    /// Lines longer than `max_partial_bytes` without a newline are discarded
    /// through their terminating newline so unbounded transcript lines cannot
    /// exhaust memory.
    pub fn pump(self: *Tailer, writer: *std.Io.Writer) !usize {
        var buf: [4096]u8 = undefined;
        var emitted = try self.forwardComplete(writer);
        while (true) {
            const n = try std.posix.pread(self.file.handle, &buf, self.pos);
            if (n == 0) break;
            var slice: []const u8 = buf[0..n];
            while (slice.len > 0) {
                if (self.discarding_oversized) {
                    if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| {
                        self.discarding_oversized = false;
                        self.pos += nl + 1;
                        slice = slice[nl + 1 ..];
                    } else {
                        self.pos += slice.len;
                        break;
                    }
                    continue;
                }
                if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| {
                    const line_tail = slice[0 .. nl + 1];
                    if (self.partial.items.len + line_tail.len > self.max_partial_bytes) {
                        self.partial.clearRetainingCapacity();
                        self.scanned = 0;
                        self.pos += line_tail.len;
                        slice = slice[nl + 1 ..];
                        continue;
                    }
                    try self.partial.appendSlice(self.allocator, line_tail);
                    self.pos += line_tail.len;
                    emitted += try self.forwardComplete(writer);
                    slice = slice[nl + 1 ..];
                } else {
                    if (self.partial.items.len + slice.len > self.max_partial_bytes) {
                        self.partial.clearRetainingCapacity();
                        self.scanned = 0;
                        self.discarding_oversized = true;
                        self.pos += slice.len;
                        break;
                    }
                    try self.partial.appendSlice(self.allocator, slice);
                    self.pos += slice.len;
                    self.scanned = self.partial.items.len;
                    break;
                }
            }
            if (n < buf.len) break;
        }
        if (emitted > 0) try writer.flush();
        return emitted;
    }

    /// At EOF, forward a valid unterminated object with its JSONL delimiter.
    pub fn flushPartial(self: *Tailer, writer: *std.Io.Writer) !void {
        if (self.discarding_oversized) {
            self.discarding_oversized = false;
            try writer.flush();
            return;
        }
        if (self.partial.items.len > 0) {
            if (!std.mem.endsWith(u8, self.partial.items, "\n")) try self.partial.append(self.allocator, '\n');
            _ = try self.forwardComplete(writer);
        }
        try writer.flush();
    }
};

// -------- tests --------

const testing = std.testing;

test "Tailer: emits a single line written before open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true });
    try f.writeAll("{\"a\":1}\n");
    f.close();

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    const n = try t.pump(&aw.writer);
    buf = aw.toArrayList();

    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("{\"a\":1}\n", buf.items);
}

test "Tailer: tails appended lines across multiple pumps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true, .truncate = true });
    defer f.close();
    try f.writeAll("{\"n\":1}\n");

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);

    _ = try t.pump(&aw.writer);
    buf = aw.toArrayList();
    try testing.expectEqualStrings("{\"n\":1}\n", buf.items);

    try f.writeAll("{\"n\":2}\n");
    var aw2 = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    _ = try t.pump(&aw2.writer);
    buf = aw2.toArrayList();
    try testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n", buf.items);
}

test "Tailer: holds back partial line until newline arrives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true, .truncate = true });
    defer f.close();
    try f.writeAll("{\"text\":\"hello, ");

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);

    var lines = try t.pump(&aw.writer);
    buf = aw.toArrayList();
    try testing.expectEqual(@as(usize, 0), lines);
    try testing.expectEqual(@as(usize, 0), buf.items.len);

    try f.writeAll("world!\"}\n");
    var aw2 = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    lines = try t.pump(&aw2.writer);
    buf = aw2.toArrayList();
    try testing.expectEqual(@as(usize, 1), lines);
    try testing.expectEqualStrings("{\"text\":\"hello, world!\"}\n", buf.items);
}

test "Tailer: emits multiple lines in a single pump" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true, .truncate = true });
    try f.writeAll("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n");
    f.close();

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    const n = try t.pump(&aw.writer);
    buf = aw.toArrayList();
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", buf.items);
}

test "Tailer: flushPartial terminates a valid trailing object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true, .truncate = true });
    try f.writeAll("{\"done\":true}\n{\"final\":true}");
    f.close();

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    _ = try t.pump(&aw.writer);
    try t.flushPartial(&aw.writer);
    buf = aw.toArrayList();
    try testing.expectEqualStrings("{\"done\":true}\n{\"final\":true}\n", buf.items);
}

test "Tailer: drops oversized partial line and resumes after newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("t.jsonl", .{ .read = true, .truncate = true });
    defer f.close();
    try f.writeAll("{\"ok\":1}\n{\"big\":\"0123456789abcdefghijklmnopqrstuvwxyz0123456789\"}\n{\"ok\":2}\n");

    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    var t = try Tailer.open(testing.allocator, path);
    defer t.deinit();
    t.max_partial_bytes = 32;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    const n = try t.pump(&aw.writer);
    buf = aw.toArrayList();

    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("{\"ok\":1}\n{\"ok\":2}\n", buf.items);
    try testing.expect(!t.discarding_oversized);
}
