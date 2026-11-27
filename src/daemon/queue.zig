//! Bounded FIFO prompt queue and PTY settling/tracing helpers for daemon mode.
const std = @import("std");
const zmux = @import("zmux");
const driver_mod = @import("../driver.zig");
const emit_mod = @import("../emit.zig");
const protocol = @import("protocol.zig");

const Options = protocol.Options;

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

/// Emit a timestamped debug trace line for daemon mode.
pub fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const elapsed_ms: i64 = @intCast(@divTrunc(@as(i128, monotonicNs()) - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] {s}\n", .{ elapsed_ms, label });
}

/// Emit a formatted timestamped debug trace line for daemon mode.
pub fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const elapsed_ms: i64 = @intCast(@divTrunc(@as(i128, monotonicNs()) - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Return true once the child process has exited or zmux reports termination.
pub fn childExited(shared: *driver_mod.SharedState, session: *zmux.NativeSession) bool {
    std.debug.assert(@intFromPtr(shared) != 0);
    return shared.exited.load(.seq_cst) or session.state() == .terminated;
}

/// Wait for PTY quiescence and an optional settle period while flushing DEC replies.
pub fn settleBeforePrompt(
    shared: *driver_mod.SharedState,
    session: *zmux.NativeSession,
    quiet_ms: u64,
    max_ms: u64,
    settle_ms: u64,
) void {
    std.debug.assert(@intFromPtr(shared) != 0);
    const step_ns: u64 = 15 * std.time.ns_per_ms;
    const quiet_ns: i128 = @as(i128, quiet_ms) * std.time.ns_per_ms;
    const started: i128 = monotonicNs();
    const give_up: i128 = started + @as(i128, max_ms) * std.time.ns_per_ms;
    while (true) {
        if (driver_mod.isInterrupted() or childExited(shared, session)) return;
        driver_mod.flushPendingToPty(shared, session);
        const now: i128 = monotonicNs();
        if (now > give_up) break;
        const last: i64 = shared.last_output_ns.load(.seq_cst);
        const quiet_since = if (last == 0) started else last;
        if (now - quiet_since > quiet_ns) break;
        std.Thread.sleep(step_ns);
    }
    const settle_end: i128 = monotonicNs() + @as(i128, settle_ms) * std.time.ns_per_ms;
    while (true) {
        if (driver_mod.isInterrupted() or childExited(shared, session)) return;
        driver_mod.flushPendingToPty(shared, session);
        const remaining = settle_end - monotonicNs();
        if (remaining <= 0) break;
        std.Thread.sleep(@intCast(@min(remaining, @as(i128, step_ns))));
    }
}

/// Bounded FIFO queue of owned prompt buffers with amortized O(1) head compaction.
pub const PromptQueue = struct {
    items: std.ArrayList([]u8) = .{},
    head: usize = 0,
    bytes: usize = 0,

    /// Free all queued prompt buffers and the backing list.
    pub fn deinit(self: *PromptQueue, allocator: std.mem.Allocator) void {
        for (self.items.items[self.head..]) |p| allocator.free(p);
        self.items.deinit(allocator);
    }

    /// Number of currently queued prompts waiting to run.
    pub fn len(self: *const PromptQueue) usize {
        std.debug.assert(self.head <= self.items.items.len);
        return self.items.items.len - self.head;
    }

    /// True when no prompts are queued.
    pub fn isEmpty(self: *const PromptQueue) bool {
        return self.len() == 0;
    }

    /// Push an owned prompt buffer, rejecting with `queue_full` if caps would be exceeded.
    pub fn push(self: *PromptQueue, allocator: std.mem.Allocator, stdout: *std.Io.Writer, content: []u8) !bool {
        std.debug.assert(content.len > 0);
        const full = self.len() >= protocol.max_queued_prompts or
            content.len > protocol.max_queued_bytes - self.bytes;
        if (full) {
            allocator.free(content);
            try emit_mod.writeProtocolError(stdout, "queue_full");
            return false;
        }
        errdefer allocator.free(content);
        try self.items.append(allocator, content);
        self.bytes += content.len;
        std.debug.assert(self.bytes <= protocol.max_queued_bytes);
        return true;
    }

    /// Pop and return the next owned prompt buffer, compacting consumed prefix periodically.
    pub fn pop(self: *PromptQueue) ?[]u8 {
        if (self.isEmpty()) return null;
        const content = self.items.items[self.head];
        self.head += 1;
        self.bytes -= content.len;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 64 and self.head >= self.items.items.len / 2) {
            const pending = self.items.items[self.head..];
            std.mem.copyForwards([]u8, self.items.items, pending);
            self.items.shrinkRetainingCapacity(pending.len);
            self.head = 0;
        }
        return content;
    }
};

// -------- tests --------
const testing = std.testing;

test "PromptQueue: starts empty with zero bytes" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expectEqual(@as(usize, 0), q.bytes);
}

test "PromptQueue: pop on empty queue returns null" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), q.pop());
}

test "PromptQueue: FIFO push and pop preserves order" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "first")));
    try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "second")));
    try testing.expectEqual(@as(usize, 2), q.len());
    try testing.expectEqual(@as(usize, 11), q.bytes);
    const a = q.pop().?;
    defer testing.allocator.free(a);
    const b = q.pop().?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("first", a);
    try testing.expectEqualStrings("second", b);
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(usize, 0), q.bytes);
}

test "PromptQueue: resets head when drained" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "a"));
    const item = q.pop().?;
    testing.allocator.free(item);
    try testing.expectEqual(@as(usize, 0), q.head);
    try testing.expectEqual(@as(usize, 0), q.items.items.len);
}

test "PromptQueue: enforces max_queued_prompts cap and writes queue_full" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..protocol.max_queued_prompts) |_| {
        try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "x")));
    }
    try testing.expect(!try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "overflow")));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "queue_full") != null);
}

test "PromptQueue: enforces max_queued_bytes cap" {
    var q: PromptQueue = .{ .bytes = protocol.max_queued_bytes - 2 };
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(!try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "abc")));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "queue_full") != null);
}

test "PromptQueue: accepts prompt landing exactly on max_queued_bytes" {
    var q: PromptQueue = .{ .bytes = protocol.max_queued_bytes - 3 };
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "abc")));
    try testing.expectEqual(protocol.max_queued_bytes, q.bytes);
}

test "PromptQueue: compacts prefix after 64 pops with remaining items" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..64) |_| try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "p")));
    for (0..63) |_| testing.allocator.free(q.pop().?);
    for (0..16) |_| try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "p")));
    testing.allocator.free(q.pop().?);
    try testing.expectEqual(@as(usize, 0), q.head);
    try testing.expectEqual(@as(usize, 16), q.len());
}

test "PromptQueue: deinit frees unpopped items after partial drain" {
    var q: PromptQueue = .{};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..5) |_| _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "item"));
    testing.allocator.free(q.pop().?);
    q.deinit(testing.allocator);
}

test "PromptQueue: interleaved push and pop tracks bytes accurately" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "ab"));
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "cde"));
    testing.allocator.free(q.pop().?);
    try testing.expectEqual(@as(usize, 3), q.bytes);
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "fghi"));
    try testing.expectEqual(@as(usize, 7), q.bytes);
}

test "PromptQueue: rejects full queue without growing len or bytes" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..protocol.max_queued_prompts) |_| {
        _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "z"));
    }
    const before_bytes = q.bytes;
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "extra"));
    try testing.expectEqual(before_bytes, q.bytes);
    try testing.expectEqual(protocol.max_queued_prompts, q.len());
}

test "PromptQueue: freeing one slot allows pushing again" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..protocol.max_queued_prompts) |_| {
        _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "a"));
    }
    testing.allocator.free(q.pop().?);
    try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "b")));
    try testing.expectEqual(protocol.max_queued_prompts, q.len());
}

test "PromptQueue: head stays below items.len until drain" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "1"));
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "2"));
    testing.allocator.free(q.pop().?);
    try testing.expectEqual(@as(usize, 1), q.head);
    try testing.expectEqual(@as(usize, 1), q.len());
}

test "PromptQueue: preserves arbitrary UTF-8 prompt bytes" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const msg = "héllo 🌿\nworld";
    _ = try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, msg));
    const got = q.pop().?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(msg, got);
}

test "PromptQueue: single-byte prompts work at boundary" {
    var q: PromptQueue = .{};
    defer q.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(try q.push(testing.allocator, &aw.writer, try testing.allocator.dupe(u8, "x")));
    try testing.expectEqual(@as(usize, 1), q.bytes);
}

test "trace: silent when debug is false" {
    trace(.{ .debug = false }, 0, "noop");
}

test "traceFmt: silent when debug is false" {
    traceFmt(.{ .debug = false }, 0, "noop {d}", .{1});
}

test "childExited: returns true immediately when shared.exited is set" {
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    sh.exited.store(true, .seq_cst);
    try testing.expect(childExited(&sh, undefined));
}

test "settleBeforePrompt: returns immediately when shared.exited is set" {
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    sh.exited.store(true, .seq_cst);
    settleBeforePrompt(&sh, undefined, 1000, 1000, 1000);
}

test "settleBeforePrompt: returns immediately when interrupted" {
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    driver_mod.requestInterrupt();
    defer driver_mod.clearInterrupt();
    settleBeforePrompt(&sh, undefined, 1000, 1000, 1000);
}
