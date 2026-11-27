//! Bounded non-blocking stdin reader, prompt composition, and timeout budget helpers.
const std = @import("std");

/// Maximum bytes accepted from stdin or `--input-file` (16 MiB).
pub const max_prompt_bytes: usize = 16 * 1024 * 1024;

/// Grace period for piped stdin when a positional prompt was also supplied.
pub const stdin_grace_ms: u64 = 3000;

/// Longest single `poll` slice so cancel flags and deadlines are re-checked promptly.
pub const bounded_read_slice_ms: u64 = 100;

/// Monotonic nanoseconds via `clock_gettime`; returns 0 on platform failure.
pub fn monotonicNowNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Convert `--timeout` seconds to milliseconds; 0 disables the cap.
pub fn timeoutMs(seconds: u32) u64 {
    if (seconds == 0) return std.math.maxInt(u64);
    const ms = @as(u64, seconds) * 1000;
    std.debug.assert(ms >= 1000);
    return ms;
}

/// Remaining budget from `total_ms` after `elapsed_ns`; disabled stays disabled, spent leaves 1 ms.
pub fn remainingTimeoutMs(total_ms: u64, elapsed_ns: u64) u64 {
    if (total_ms == std.math.maxInt(u64)) return total_ms;
    const rem = @max(total_ms -| elapsed_ns / std.time.ns_per_ms, 1);
    std.debug.assert(rem >= 1);
    return rem;
}

/// Resolution of where the CLI obtains the user prompt bytes.
pub const PromptSource = enum {
    /// Positional prompt only.
    positional,
    /// Positional prompt prefixed by piped stdin.
    positional_with_stdin,
    /// Explicit `--input-file` path.
    input_file,
    /// Piped stdin only.
    stdin,
    /// Usage error: positional and `--input-file` together.
    conflict,
    /// Usage error: nothing to read and stdin is an interactive TTY.
    tty_empty,
};

/// Decide where the prompt should be read from given CLI flags and stdin TTY state.
pub fn promptSource(has_positional: bool, has_input_file: bool, stdin_is_tty: bool) PromptSource {
    if (has_positional and has_input_file) return .conflict;
    if (has_input_file) return .input_file;
    if (has_positional) return if (stdin_is_tty) .positional else .positional_with_stdin;
    return if (stdin_is_tty) .tty_empty else .stdin;
}

/// Compose `<stdin>\n\n<prompt>`, leaving `prompt` unchanged when trimmed stdin is empty.
pub fn composePrompt(allocator: std.mem.Allocator, stdin_text: []const u8, prompt: []const u8) ![]u8 {
    std.debug.assert(prompt.len > 0 or stdin_text.len >= 0);
    const body = std.mem.trimRight(u8, stdin_text, "\r\n");
    if (body.len == 0) return allocator.dupe(u8, prompt);
    return std.mem.concat(allocator, u8, &.{ body, "\n\n", prompt });
}

/// Outcome of reading stdin with a byte cap, optional first-byte grace, and deadline.
pub const BoundedRead = union(enum) {
    /// EOF reached. Caller owns the bytes.
    complete: []u8,
    /// No byte arrived within `first_byte_grace_ms`.
    silent,
    /// `deadline_ns` passed before EOF, after this many bytes.
    timed_out: usize,
    /// `cancel` became non-zero (a signal arrived).
    interrupted,
    /// More than `max_bytes` arrived.
    too_large,
};

/// Limits and cancellation controls for `readBounded`.
pub const BoundedReadOptions = struct {
    /// Maximum bytes allowed before returning `.too_large`.
    max_bytes: usize,
    /// Optional first-byte wait window in milliseconds.
    first_byte_grace_ms: ?u64 = null,
    /// Optional absolute `monotonicNowNs` deadline for reaching EOF.
    deadline_ns: ?u64 = null,
    /// Optional signal flag checked at least every `bounded_read_slice_ms`.
    cancel: ?*const std.atomic.Value(u32) = null,
};

/// Ceiling-rounded milliseconds from `now_ns` to `target_ns` (`target_ns > now_ns`).
pub fn msUntil(now_ns: u64, target_ns: u64) u64 {
    std.debug.assert(target_ns > now_ns);
    const ms = (target_ns - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    std.debug.assert(ms >= 1);
    return ms;
}

/// Read `fd` to EOF without blocking past the grace period, deadline, or cancel request.
pub fn readBounded(allocator: std.mem.Allocator, fd: std.posix.fd_t, o: BoundedReadOptions) !BoundedRead {
    std.debug.assert(bounded_read_slice_ms > 0);
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    const start_ns = monotonicNowNs();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (o.cancel) |c| if (c.load(.seq_cst) != 0) return .interrupted;
        const now_ns = monotonicNowNs();
        var wait_ms = bounded_read_slice_ms;
        if (o.deadline_ns) |d| {
            if (now_ns >= d) return .{ .timed_out = list.items.len };
            wait_ms = @min(wait_ms, msUntil(now_ns, d));
        }
        if (list.items.len == 0) if (o.first_byte_grace_ms) |g| {
            const grace_end = start_ns + g * std.time.ns_per_ms;
            if (now_ns >= grace_end) return .silent;
            wait_ms = @min(wait_ms, msUntil(now_ns, grace_end));
        };
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, @intCast(wait_ms)) == 0) continue;
        const optional_stdin = o.first_byte_grace_ms != null and list.items.len == 0;
        if (fds[0].revents & std.posix.POLL.NVAL != 0) {
            if (optional_stdin) return .silent;
            return error.NotOpenForReading;
        }
        const n = std.posix.read(fd, &buf) catch |err| {
            if (err == error.NotOpenForReading and optional_stdin) return .silent;
            return err;
        };
        if (n == 0) return .{ .complete = try list.toOwnedSlice(allocator) };
        if (list.items.len + n > o.max_bytes) return .too_large;
        try list.appendSlice(allocator, buf[0..n]);
    }
}

// -------- tests --------
const testing = std.testing;

test "timeoutMs: 0 disables, positive converts seconds to ms" {
    try testing.expectEqual(std.math.maxInt(u64), timeoutMs(0));
    try testing.expectEqual(@as(u64, 300_000), timeoutMs(300));
    try testing.expectEqual(@as(u64, 4_294_967_295_000), timeoutMs(std.math.maxInt(u32)));
}

test "remainingTimeoutMs: subtracts elapsed, preserves disabled, floors at 1" {
    try testing.expectEqual(@as(u64, 300_000), remainingTimeoutMs(300_000, 0));
    try testing.expectEqual(@as(u64, 297_500), remainingTimeoutMs(300_000, 2_500 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 1), remainingTimeoutMs(1_000, 1_000 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 1), remainingTimeoutMs(1_000, 90 * std.time.ns_per_s));
    try testing.expectEqual(std.math.maxInt(u64), remainingTimeoutMs(timeoutMs(0), 90 * std.time.ns_per_s));
}

test "promptSource: conflict wins when both positional and input_file set" {
    try testing.expectEqual(PromptSource.conflict, promptSource(true, true, true));
    try testing.expectEqual(PromptSource.conflict, promptSource(true, true, false));
}

test "promptSource: input_file takes priority over stdin TTY state" {
    try testing.expectEqual(PromptSource.input_file, promptSource(false, true, true));
    try testing.expectEqual(PromptSource.input_file, promptSource(false, true, false));
}

test "promptSource: positional switches on stdin TTY state" {
    try testing.expectEqual(PromptSource.positional, promptSource(true, false, true));
    try testing.expectEqual(PromptSource.positional_with_stdin, promptSource(true, false, false));
}

test "promptSource: empty args require piped stdin" {
    try testing.expectEqual(PromptSource.tty_empty, promptSource(false, false, true));
    try testing.expectEqual(PromptSource.stdin, promptSource(false, false, false));
}

test "composePrompt: joins trimmed stdin and prompt with blank line" {
    const a = try composePrompt(testing.allocator, "diff\n+x\n\n", "summarize");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("diff\n+x\n\nsummarize", a);
}

test "composePrompt: whitespace-only newlines leave prompt unchanged" {
    const b = try composePrompt(testing.allocator, "\r\n\n", "hi");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("hi", b);
}

test "composePrompt: empty stdin returns owned copy of prompt" {
    const c = try composePrompt(testing.allocator, "", "solo");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("solo", c);
}

test "msUntil: rounds up sub-millisecond deltas" {
    const ms = std.time.ns_per_ms;
    try testing.expectEqual(@as(u64, 1), msUntil(10, 11));
    try testing.expectEqual(@as(u64, 1), msUntil(10, 10 + ms));
    try testing.expectEqual(@as(u64, 2), msUntil(10, 10 + ms + 1));
}

test "monotonicNowNs: returns non-decreasing positive timestamp" {
    const a = monotonicNowNs();
    const b = monotonicNowNs();
    try testing.expect(a > 0 and b >= a);
}

test "readBounded: closed fd returns silent with grace or NotOpenForReading without" {
    const invalid_fd = std.math.maxInt(std.posix.fd_t);
    try testing.expectEqual(
        BoundedRead.silent,
        try readBounded(testing.allocator, invalid_fd, .{ .max_bytes = 64, .first_byte_grace_ms = 50 }),
    );
    try testing.expectError(
        error.NotOpenForReading,
        readBounded(testing.allocator, invalid_fd, .{ .max_bytes = 64 }),
    );
}

test "readBounded: reads pipe to EOF" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "diff --git a b\n");
    std.posix.close(p[1]);
    const r = try readBounded(testing.allocator, p[0], .{ .max_bytes = 64, .first_byte_grace_ms = 50 });
    defer testing.allocator.free(r.complete);
    try testing.expectEqualStrings("diff --git a b\n", r.complete);
}

test "readBounded: empty closed pipe returns empty complete slice" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    std.posix.close(p[1]);
    const r = try readBounded(testing.allocator, p[0], .{ .max_bytes = 64 });
    defer testing.allocator.free(r.complete);
    try testing.expectEqualStrings("", r.complete);
}

test "readBounded: open silent pipe gives up after first-byte grace" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    const t0 = monotonicNowNs();
    const r = try readBounded(testing.allocator, p[0], .{ .max_bytes = 64, .first_byte_grace_ms = 40 });
    try testing.expectEqual(BoundedRead.silent, r);
    try testing.expect(monotonicNowNs() - t0 >= 40 * std.time.ns_per_ms);
}

test "readBounded: prefix then silence times out at deadline, not grace" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    _ = try std.posix.write(p[1], "abc");
    const t0 = monotonicNowNs();
    const r = try readBounded(testing.allocator, p[0], .{
        .max_bytes = 64,
        .first_byte_grace_ms = 15,
        .deadline_ns = t0 + 120 * std.time.ns_per_ms,
    });
    try testing.expectEqual(BoundedRead{ .timed_out = 3 }, r);
    try testing.expect(monotonicNowNs() - t0 >= 120 * std.time.ns_per_ms);
}

test "readBounded: no grace silent pipe times out with 0 bytes" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    const r = try readBounded(testing.allocator, p[0], .{
        .max_bytes = 64,
        .deadline_ns = monotonicNowNs() + 50 * std.time.ns_per_ms,
    });
    try testing.expectEqual(BoundedRead{ .timed_out = 0 }, r);
}

test "readBounded: first-byte grace does not abort mid-stream pause" {
    const PipeWriter = struct {
        fn slow(fd: std.posix.fd_t) void {
            _ = std.posix.write(fd, "a") catch {};
            std.Thread.sleep(90 * std.time.ns_per_ms);
            _ = std.posix.write(fd, "b") catch {};
            std.posix.close(fd);
        }
    };
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    const thread = try std.Thread.spawn(.{}, PipeWriter.slow, .{p[1]});
    defer thread.join();
    const r = try readBounded(testing.allocator, p[0], .{
        .max_bytes = 64,
        .first_byte_grace_ms = 30,
        .deadline_ns = monotonicNowNs() + 5 * std.time.ns_per_s,
    });
    defer testing.allocator.free(r.complete);
    try testing.expectEqualStrings("ab", r.complete);
}

test "readBounded: cancel atomic interrupts immediately" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    var cancel = std.atomic.Value(u32).init(std.posix.SIG.TERM);
    const r = try readBounded(testing.allocator, p[0], .{ .max_bytes = 64, .cancel = &cancel });
    try testing.expectEqual(BoundedRead.interrupted, r);
}

test "readBounded: enforces max_bytes boundary strictly" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "hello");
    std.posix.close(p[1]);
    try testing.expectEqual(BoundedRead.too_large, try readBounded(testing.allocator, p[0], .{ .max_bytes = 4 }));

    const q = try std.posix.pipe();
    defer std.posix.close(q[0]);
    _ = try std.posix.write(q[1], "hell");
    std.posix.close(q[1]);
    const exact = try readBounded(testing.allocator, q[0], .{ .max_bytes = 4 });
    defer testing.allocator.free(exact.complete);
    try testing.expectEqualStrings("hell", exact.complete);
}
