//! Daemon NDJSON input framing, watchdog predicates, and wire emitters.
const std = @import("std");
const emit_mod = @import("../emit.zig");

/// Lifecycle state of the persistent multi-turn daemon.
pub const State = enum {
    /// Spawned, waiting for SessionStart hook.
    waiting_for_ready,
    /// SessionStart fired, transcript opened, awaiting prompt from stdin.
    idle,
    /// Prompt typed, awaiting Stop hook.
    busy,
};

/// How long to wait for a `Stop` hook after sending ESC for an `interrupt`
/// frame before reporting the turn as interrupted.
pub const interrupt_window_ms: u64 = 1500;

/// Decide whether a busy turn has stalled due to no PTY output.
pub fn idleTimedOut(state: State, last_output_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    return progressTimedOut(state, last_output_ns, now_ns, timeout_ms);
}

/// Decide whether a busy turn has stalled because the transcript stopped growing.
pub fn transcriptStalled(state: State, last_transcript_advance_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    return progressTimedOut(state, last_transcript_advance_ns, now_ns, timeout_ms);
}

fn progressTimedOut(state: State, last_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    if (state != .busy or last_ns == 0 or timeout_ms == 0) return false;
    std.debug.assert(timeout_ms > 0);
    const deadline = @as(i128, last_ns) + (@as(i128, timeout_ms) + 1) * std.time.ns_per_ms;
    return now_ns >= deadline;
}

/// Decide whether a `Stop` hook arriving while busy belongs to the active turn.
pub fn stopBelongsToTurn(state: State, prompt_acked: bool) bool {
    return state == .busy and prompt_acked;
}

/// Milliseconds from `start_ns` to `now_ns`, clamped at 0 and saturated at `maxInt(u64)`.
pub fn elapsedMs(start_ns: i128, now_ns: i128) u64 {
    if (now_ns <= start_ns) return 0;
    const diff_ns: u128 = @as(u128, @bitCast(now_ns)) -% @as(u128, @bitCast(start_ns));
    std.debug.assert(diff_ns > 0);
    return std.math.cast(u64, diff_ns / std.time.ns_per_ms) orelse std.math.maxInt(u64);
}

/// Extract the user-message content from a hub-style stdin frame.
/// Caller owns the returned heap-allocated slice.
pub fn parseUserMessageContent(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const tval = obj.get("type") orelse return null;
    if (tval != .string or !std.mem.eql(u8, tval.string, "user")) return null;
    return extractContent(allocator, obj) catch |err| switch (err) {
        error.UnsupportedContentBlock => null,
        error.OutOfMemory => return err,
    };
}

fn extractContent(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]u8 {
    const content = if (obj.get("message")) |message| blk: {
        if (message != .object) return null;
        if (message.object.get("role")) |role| {
            if (role != .string or !std.mem.eql(u8, role.string, "user")) return null;
        }
        break :blk message.object.get("content") orelse return null;
    } else obj.get("content") orelse return null;
    if (content == .string) return try allocator.dupe(u8, content.string);
    if (content != .array) return null;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    for (content.array.items) |item| {
        if (item != .object) return error.UnsupportedContentBlock;
        const kind = item.object.get("type") orelse return error.UnsupportedContentBlock;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) {
            return error.UnsupportedContentBlock;
        }
        const text = item.object.get("text") orelse return error.UnsupportedContentBlock;
        if (text != .string) return error.UnsupportedContentBlock;
        try buf.appendSlice(allocator, text.string);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Decoded daemon stdin control or user prompt frame.
pub const InputFrame = union(enum) {
    ping,
    interrupt,
    user: []u8,
};

/// Parse one stdin line, emitting a protocol error frame on invalid input.
pub fn readInputFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, line: []const u8) !?InputFrame {
    std.debug.assert(@intFromPtr(writer) != 0);
    if (std.mem.trim(u8, line, " \t\r").len == 0) return null;
    return parseInputFrame(allocator, line) catch |err| {
        const reason = switch (err) {
            error.InvalidJson => "invalid_json",
            error.InvalidUserMessage => "invalid_user_message",
            error.UnsupportedContentBlock => "unsupported_content_block",
            error.UnsupportedFrameType => "unsupported_frame_type",
            error.OutOfMemory => return err,
        };
        try emit_mod.writeProtocolError(writer, reason);
        return null;
    };
}

fn parseInputFrame(allocator: std.mem.Allocator, line: []const u8) !InputFrame {
    std.debug.assert(line.len > 0);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.UnsupportedFrameType;
    const obj = parsed.value.object;
    const kind = obj.get("type") orelse return error.UnsupportedFrameType;
    if (kind != .string) return error.UnsupportedFrameType;
    if (std.mem.eql(u8, kind.string, "ping")) return .ping;
    if (std.mem.eql(u8, kind.string, "interrupt")) return .interrupt;
    if (!std.mem.eql(u8, kind.string, "user")) return error.UnsupportedFrameType;
    const content = try extractContent(allocator, obj) orelse return error.InvalidUserMessage;
    if (content.len > 0) return .{ .user = content };
    allocator.free(content);
    return error.InvalidUserMessage;
}

/// Incrementally frame NDJSON from a nonblocking fd with bounded line size.
pub const LineBuffer = struct {
    pub const limit = 16 * 1024 * 1024;
    pub const Event = union(enum) { line: []const u8, oversized };
    bytes: std.ArrayList(u8) = .{},
    discarding: bool = false,
    delivered: bool = false,

    pub fn next(self: *LineBuffer, allocator: std.mem.Allocator, chunk: *[]const u8, eof: bool) !?Event {
        std.debug.assert(self.bytes.items.len <= limit);
        if (self.delivered) {
            self.bytes.clearRetainingCapacity();
            self.delivered = false;
        }
        while (chunk.len > 0) {
            const nl = std.mem.indexOfScalar(u8, chunk.*, '\n');
            const part = chunk.*[0 .. nl orelse chunk.len];
            chunk.* = chunk.*[part.len + @intFromBool(nl != null) ..];
            if (self.discarding) {
                self.discarding = nl == null;
                continue;
            }
            if (part.len > limit - self.bytes.items.len) {
                self.bytes.clearRetainingCapacity();
                self.discarding = nl == null;
                return .oversized;
            }
            const needed = self.bytes.items.len + part.len;
            if (needed > self.bytes.capacity) {
                const cap = @min(limit, @max(needed, self.bytes.capacity * 2));
                std.debug.assert(cap >= needed and cap <= limit);
                try self.bytes.ensureTotalCapacityPrecise(allocator, cap);
            }
            self.bytes.appendSliceAssumeCapacity(part);
            if (nl != null) {
                self.delivered = true;
                return .{ .line = self.bytes.items };
            }
        }
        if (eof and self.bytes.items.len > 0) {
            self.delivered = true;
            return .{ .line = self.bytes.items };
        }
        return null;
    }
};

fn isFrameOfType(allocator: std.mem.Allocator, line: []const u8, frame_type: []const u8) bool {
    std.debug.assert(frame_type.len > 0);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const tval = parsed.value.object.get("type") orelse return false;
    return tval == .string and std.mem.eql(u8, tval.string, frame_type);
}

/// True if `line` is a `{"type":"ping"}` health-probe frame.
pub fn isPingFrame(allocator: std.mem.Allocator, line: []const u8) bool {
    return isFrameOfType(allocator, line, "ping");
}

/// True if `line` is a `{"type":"interrupt"}` frame.
pub fn isInterruptFrame(allocator: std.mem.Allocator, line: []const u8) bool {
    return isFrameOfType(allocator, line, "interrupt");
}

/// Emit a minimal `system:init` envelope once `SessionStart` fires.
pub fn emitSystemInit(writer: *std.Io.Writer, session_id: []const u8) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("system");
    try jw.objectField("subtype");
    try jw.write("init");
    try jw.objectField("session_id");
    try jw.write(session_id);
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Emit a `{"type":"pong","ts":<unix_ms>}` health-probe reply.
pub fn emitPong(writer: *std.Io.Writer) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("pong");
    try jw.objectField("ts");
    try jw.write(std.time.milliTimestamp());
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Compute the periodic PTY diagnostic trace interval in nanoseconds, or null when disabled.
pub fn ptyTraceInterval(debug: bool, setting: ?[]const u8) ?i128 {
    const default: ?i128 = if (debug) 60 * std.time.ns_per_s else null;
    const raw = std.mem.trim(u8, setting orelse return default, " \t\r\n");
    const disabled = std.ascii.eqlIgnoreCase(raw, "off") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no");
    if (disabled) return null;
    const seconds = std.fmt.parseInt(u32, raw, 10) catch return default;
    return if (seconds == 0) null else @as(i128, seconds) * std.time.ns_per_s;
}

/// Emit a structured error result and flush stdout.
pub fn writeError(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    reason: []const u8,
    sid: []const u8,
    duration: u64,
) !void {
    std.debug.assert(reason.len > 0);
    try emit_mod.emitErrorResult(allocator, writer, "error", reason, sid, duration);
    try writer.flush();
}

/// Emit a startup-stage error result and return exit code 2.
pub fn startupFailure(writer: *std.Io.Writer, reason: []const u8, stage: []const u8) !u8 {
    std.debug.assert(reason.len > 0 and stage.len > 0);
    try emit_mod.emitErrorResultDetail(writer, "error", reason, "", 0, .{ .stage = stage });
    try writer.flush();
    return 2;
}

/// Map a stdout write error to daemon exit code (`BrokenPipe` exits 0, others 2).
pub fn writeFailureExit(cause: ?std.fs.File.WriteError) u8 {
    return if ((cause orelse return 2) == error.BrokenPipe) 0 else 2;
}

/// Return true if `fd` is readable (or at HUP/ERR) without blocking.
pub fn fdReadable(fd: std.posix.fd_t) bool {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    if (ready == 0) return false;
    return (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

// -------- tests --------
const testing = std.testing;

test "parseUserMessageContent: simple string content" {
    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "parseUserMessageContent: array content with text blocks" {
    const line =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"hi \"},{\"type\":\"text\",\"text\":\"there\"}]}}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi there", out);
}

test "parseUserMessageContent: fallback top-level content" {
    const out = (try parseUserMessageContent(testing.allocator, "{\"type\":\"user\",\"content\":\"hi\"}")).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi", out);
}

test "parseUserMessageContent: non-user type returns null" {
    const line = "{\"type\":\"system\",\"content\":\"nope\"}";
    try testing.expectEqual(@as(?[]u8, null), try parseUserMessageContent(testing.allocator, line));
}

test "parseUserMessageContent: malformed returns null" {
    try testing.expectEqual(@as(?[]u8, null), try parseUserMessageContent(testing.allocator, "not json"));
}

test "isPingFrame: ping frame recognized" {
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\",\"id\":7}"));
}

test "isPingFrame: user frame is not a ping" {
    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}";
    try testing.expect(!isPingFrame(testing.allocator, line));
}

test "isPingFrame: malformed / non-ping returns false" {
    try testing.expect(!isPingFrame(testing.allocator, "not json"));
    try testing.expect(!isPingFrame(testing.allocator, "{\"type\":\"system\"}"));
    try testing.expect(!isPingFrame(testing.allocator, "{\"foo\":1}"));
}

test "emitPong: shape is a single-line pong object with ts" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPong(&aw.writer);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "\n"));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"type\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"ts\":") != null);
}

test "emitSystemInit: writes init JSON object with session_id" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitSystemInit(&aw.writer, "sid-42");
    try testing.expectEqualStrings(
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sid-42\"}\n",
        aw.written(),
    );
}

test "idleTimedOut: busy + stale last_output trips" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    try testing.expect(!idleTimedOut(.busy, 0, now, 180_000));
    const stale: i64 = @intCast(now - 200_000 * std.time.ns_per_ms);
    try testing.expect(idleTimedOut(.busy, stale, now, 180_000));
}

test "idleTimedOut: busy + fresh baseline does not trip" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    try testing.expect(!idleTimedOut(.busy, @intCast(now), now, 180_000));
    try testing.expect(!idleTimedOut(.busy, @intCast(now - 1_000 * std.time.ns_per_ms), now, 180_000));
}

test "idleTimedOut: idle/waiting never trip and timeout 0 disables" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 3_600_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.idle, ancient, now, 180_000));
    try testing.expect(!idleTimedOut(.waiting_for_ready, ancient, now, 180_000));
    try testing.expect(!idleTimedOut(.busy, ancient, now, 0));
}

test "transcriptStalled: boundary and spinner independence" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    try testing.expect(!transcriptStalled(.busy, @intCast(now - 600_000 * std.time.ns_per_ms), now, 600_000));
    try testing.expect(transcriptStalled(.busy, @intCast(now - 600_001 * std.time.ns_per_ms), now, 600_000));
    try testing.expect(!transcriptStalled(.idle, @intCast(now - 700_000 * std.time.ns_per_ms), now, 600_000));
    try testing.expect(!transcriptStalled(.busy, 0, now, 600_000));
}

test "isInterruptFrame: interrupt recognized and others rejected" {
    try testing.expect(isInterruptFrame(testing.allocator, "{\"type\":\"interrupt\"}"));
    try testing.expect(!isInterruptFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(!isInterruptFrame(testing.allocator, "not json"));
    try testing.expect(!isInterruptFrame(testing.allocator, ""));
}

test "stopBelongsToTurn: requires busy and prompt_acked" {
    try testing.expect(!stopBelongsToTurn(.idle, true));
    try testing.expect(!stopBelongsToTurn(.busy, false));
    try testing.expect(stopBelongsToTurn(.busy, true));
}

test "elapsedMs: clamps future start to 0 and saturates extremes" {
    try testing.expectEqual(@as(u64, 1500), elapsedMs(0, 1500 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 0), elapsedMs(10, 5));
    try testing.expectEqual(std.math.maxInt(u64), elapsedMs(std.math.minInt(i128), std.math.maxInt(i128)));
}

test "readInputFrame: rejects malformed and mixed content once" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_][]const u8{ "", "\r", "   \t\r" }) |line| {
        try testing.expect(try readInputFrame(testing.allocator, &out.writer, line) == null);
    }
    try testing.expectEqual(@as(usize, 0), out.written().len);
    const bad = [_][]const u8{
        "{",
        "{}",
        "{\"type\":\"user\"}",
        "{\"type\":\"user\",\"message\":{\"role\":\"assistant\",\"content\":\"x\"}}",
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"image\"}]}}",
    };
    const reasons = [_][]const u8{
        "invalid_json",
        "unsupported_frame_type",
        "invalid_user_message",
        "invalid_user_message",
        "unsupported_content_block",
    };
    for (bad, reasons) |line, reason| {
        out.clearRetainingCapacity();
        try testing.expect(try readInputFrame(testing.allocator, &out.writer, line) == null);
        try testing.expect(std.mem.indexOf(u8, out.written(), reason) != null);
    }
}

test "LineBuffer: bounds fragmented input, resyncs, and delivers EOF once" {
    var buf: LineBuffer = .{};
    defer buf.bytes.deinit(testing.allocator);
    const block = try testing.allocator.alloc(u8, LineBuffer.limit);
    defer testing.allocator.free(block);
    @memset(block, 'a');
    var chunk: []const u8 = block;
    try testing.expect(try buf.next(testing.allocator, &chunk, false) == null);
    chunk = "too long";
    try testing.expect((try buf.next(testing.allocator, &chunk, false)).? == .oversized);
    chunk = "discard me\nok\nlast";
    try testing.expectEqualStrings("ok", (try buf.next(testing.allocator, &chunk, false)).?.line);
    try testing.expect(try buf.next(testing.allocator, &chunk, false) == null);
    try testing.expectEqualStrings("last", (try buf.next(testing.allocator, &chunk, true)).?.line);
    try testing.expect(try buf.next(testing.allocator, &chunk, true) == null);
    try testing.expect(buf.bytes.capacity <= LineBuffer.limit);
}

test "ptyTraceInterval: debug default, numeric seconds, and disable keywords" {
    try testing.expectEqual(@as(?i128, null), ptyTraceInterval(false, null));
    try testing.expectEqual(@as(?i128, 60 * std.time.ns_per_s), ptyTraceInterval(true, null));
    try testing.expectEqual(@as(?i128, std.time.ns_per_s), ptyTraceInterval(false, "1"));
    try testing.expectEqual(@as(?i128, null), ptyTraceInterval(true, "off"));
    try testing.expectEqual(@as(?i128, null), ptyTraceInterval(true, "0"));
}

test "writeFailureExit and startupFailure map codes cleanly" {
    try testing.expectEqual(@as(u8, 0), writeFailureExit(error.BrokenPipe));
    try testing.expectEqual(@as(u8, 2), writeFailureExit(error.NoSpaceLeft));
    try testing.expectEqual(@as(u8, 2), writeFailureExit(null));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), try startupFailure(&out.writer, "spawn_failed", "cwd"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"stage\":\"cwd\"") != null);
}
