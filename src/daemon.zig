//! Long-lived multi-turn daemon mode.
//!
//! Stays alive across many user prompts, reusing one PTY-driven `claude`
//! session. It accepts NDJSON user, ping and interrupt frames. Each turn
//! streams transcript records followed by a result envelope.
//!
//! Lifecycle:
//!   1. Spawn `claude` under zmux PTY (same setup as `driver.run`)
//!   2. Handle pre-SessionStart modal dialogs (trust / bypass-permissions)
//!   3. After SessionStart, open tailer for the transcript file
//!   4. Loop:
//!        a. Pump any new transcript lines to stdout
//!        b. Read available stdin lines (non-blocking)
//!        c. When a `user` message arrives and we're idle, type it into the
//!           PTY and switch to busy
//!        d. When the Stop hook fires, compute the per-turn `result`
//!           envelope from the transcript slice covering this turn and
//!           emit it, then switch back to idle
//!        e. On stdin EOF, terminate the session and exit
//!
//! Every exit a hub cannot predict (SessionStart timeout, PTY idle timeout,
//! transcript stall) writes one structured `result` error frame to stdout
//! before the process ends, so the hub never reads a silent dead pipe.
const std = @import("std");
const zmux = @import("zmux");

const driver_mod = @import("driver.zig");
const hook_mod = @import("hook.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const stream_mod = @import("stream.zig");

/// Options for daemon mode. Subset of `driver.Options` — no prompt, no
/// output-format choice (always stream-json), no max-turns (the wrapper is
/// long-lived; the *caller* decides when to stop).
pub const Options = struct {
    model: ?[]const u8 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    add_dirs: []const []const u8 = &.{},
    mcp_configs: []const []const u8 = &.{},
    verbose: bool = false,
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
    /// Wall-time cap for the *initial* SessionStart wait. After that the
    /// daemon runs until stdin EOF or the child exits.
    session_start_timeout_ms: u64 = 300_000,
    /// While busy, kill the session if no PTY output has been observed for
    /// this long. Detects a genuinely hung Ink TUI (Stop hook never fires)
    /// without false-killing long turns that keep emitting tool progress.
    /// Set to 0 to disable.
    idle_progress_timeout_ms: u64 = 180_000,
    /// While busy, kill the session if the transcript file has not grown for
    /// this long. Unlike `idle_progress_timeout_ms`, a ticking spinner does
    /// not reset it: only real transcript bytes count. Set to 0 to disable.
    transcript_idle_timeout_ms: u64 = 600_000,
    /// Extra hooks merged into the generated settings (see `hook.zig`).
    extra_hooks: []const hook_mod.ExtraHook = &.{},
    /// Extra settings JSON object merged into the generated settings.
    extra_settings_json: ?[]const u8 = null,
};

pub const RunError = error{
    InvalidExtraSettings,
    InvalidOptions,
    IoFailure,
} || std.mem.Allocator.Error;

pub const State = enum {
    /// Spawned, waiting for SessionStart hook.
    waiting_for_ready,
    /// SessionStart fired, transcript opened, awaiting prompt from stdin.
    idle,
    /// Prompt typed, awaiting Stop hook.
    busy,
};

/// Decide whether a busy turn has stalled: no PTY output for longer than the
/// idle-progress timeout. Only meaningful while `.busy` — `.idle` /
/// `.waiting_for_ready` never time out here (an idle daemon legitimately
/// produces no PTY output while waiting for the next prompt).
///
/// `last_output_ns == 0` (no output observed yet) never trips. The caller
/// MUST reset `last_output_ns` to "now" when transitioning idle→busy;
/// otherwise a long idle period leaves a stale timestamp that trips this on
/// the very first busy loop even though the child is healthy and simply hasn't
/// had time to respond to the new prompt yet.
pub fn idleTimedOut(state: State, last_output_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    return progressTimedOut(state, last_output_ns, now_ns, timeout_ms);
}

/// Decide whether a busy turn has stalled: the transcript file has not grown
/// for longer than the transcript-idle timeout. Spinner-immune counterpart of
/// `idleTimedOut`: Ink repaints keep PTY bytes flowing during a wedged turn,
/// but only real progress appends transcript bytes.
///
/// Same rules as `idleTimedOut`: only `.busy` can trip, `timeout_ms == 0`
/// disables, and `last_transcript_advance_ns == 0` (no baseline) never trips.
/// The caller MUST reset the baseline to "now" on the idle→busy transition
/// and again each time the tailer reads new transcript bytes.
pub fn transcriptStalled(state: State, last_transcript_advance_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    return progressTimedOut(state, last_transcript_advance_ns, now_ns, timeout_ms);
}

fn progressTimedOut(state: State, last_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    if (state != .busy or last_ns == 0 or timeout_ms == 0) return false;
    // Compare against the first expired millisecond. The deadline fits i128
    // for every i64 baseline and u64 timeout, even at either clock extreme.
    const deadline = @as(i128, last_ns) + (@as(i128, timeout_ms) + 1) * std.time.ns_per_ms;
    return now_ns >= deadline;
}

/// How long to wait for a `Stop` hook after sending ESC for an `interrupt`
/// frame before reporting the turn as interrupted.
pub const interrupt_window_ms: u64 = 1500;

/// Decide whether a `Stop` hook that arrives while busy ends the current
/// turn. After an interrupted turn the daemon returns to idle without waiting
/// for that turn's `Stop`, so a late one can arrive after the next prompt was
/// typed. Only the new prompt acknowledgement distinguishes that Stop from
/// residual transcript writes belonging to the interrupted turn.
pub fn stopBelongsToTurn(state: State, prompt_acked: bool) bool {
    return state == .busy and prompt_acked;
}

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

pub const requestInterrupt = driver_mod.requestInterrupt;
const interrupted = driver_mod.isInterrupted;

/// Milliseconds from `start_ns` to `now_ns`, clamped at 0 and saturated at
/// `maxInt(u64)`. The difference is taken in u128 so no pair of i128 clock
/// values can overflow.
pub fn elapsedMs(start_ns: i128, now_ns: i128) u64 {
    if (now_ns <= start_ns) return 0;
    const diff_ns: u128 = @as(u128, @bitCast(now_ns)) -% @as(u128, @bitCast(start_ns));
    return std.math.cast(u64, diff_ns / std.time.ns_per_ms) orelse std.math.maxInt(u64);
}

/// Translate daemon Options to a driver.Options (which buildArgv takes).
/// Prompt stays empty — buildArgv never reads it, and the daemon never
/// passes a prompt on argv anyway.
pub fn toDriverOptions(opts: Options) driver_mod.Options {
    return .{
        .prompt = "",
        .output_format = .stream_json,
        .model = opts.model,
        .max_turns = null,
        .allowed_tools = opts.allowed_tools,
        .skip_permissions = opts.skip_permissions,
        .resume_session = opts.resume_session,
        .cont = opts.cont,
        .session_id = opts.session_id,
        .cwd = opts.cwd,
        .extra_args = opts.extra_args,
        .system_prompt = opts.system_prompt,
        .append_system_prompt = opts.append_system_prompt,
        .permission_mode = opts.permission_mode,
        .disallowed_tools = opts.disallowed_tools,
        .fallback_model = opts.fallback_model,
        .setting_sources = opts.setting_sources,
        .add_dirs = opts.add_dirs,
        .mcp_configs = opts.mcp_configs,
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
        .verbose = opts.verbose,
        .timeout_ms = opts.session_start_timeout_ms,
        .claude_path = opts.claude_path,
        .cols = opts.cols,
        .rows = opts.rows,
        .debug = opts.debug,
        .stream_writer = null,
    };
}

fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const now: i128 = monotonicNs();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = monotonicNs();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Extract the user-message content from a hub-style stdin frame:
/// `{"type":"user","message":{"role":"user","content":"..."}}`
/// Also accepts `{"type":"user","content":"..."}` for convenience.
/// Returned slice is heap-allocated.
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
    if (tval != .string) return null;
    if (!std.mem.eql(u8, tval.string, "user")) return null;

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
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) return error.UnsupportedContentBlock;
        const text = item.object.get("text") orelse return error.UnsupportedContentBlock;
        if (text != .string) return error.UnsupportedContentBlock;
        try buf.appendSlice(allocator, text.string);
    }
    return try buf.toOwnedSlice(allocator);
}

const InputFrame = union(enum) {
    ping,
    interrupt,
    user: []u8,
};

/// Parse one stdin line. Blank lines and rejected frames never enter the queue.
pub fn readInputFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, line: []const u8) !?InputFrame {
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

const max_queued_prompts = 64;
const max_queued_bytes = 64 * 1024 * 1024;

/// Incrementally frame NDJSON from a nonblocking fd. Report an oversized line
/// once, then discard through its delimiter without losing subsequent frames.
const LineBuffer = struct {
    const limit = 16 * 1024 * 1024;
    const Event = union(enum) { line: []const u8, oversized };
    bytes: std.ArrayList(u8) = .{},
    discarding: bool = false,
    delivered: bool = false,

    fn next(self: *LineBuffer, allocator: std.mem.Allocator, chunk: *[]const u8, eof: bool) !?Event {
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
                try self.bytes.ensureTotalCapacityPrecise(allocator, @min(limit, @max(needed, self.bytes.capacity * 2)));
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

/// True if `line` is a JSON object whose `type` field equals `frame_type`.
fn isFrameOfType(allocator: std.mem.Allocator, line: []const u8, frame_type: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const tval = parsed.value.object.get("type") orelse return false;
    if (tval != .string) return false;
    return std.mem.eql(u8, tval.string, frame_type);
}

/// True if `line` is a `{"type":"ping"}` health-probe frame. Cheap classifier
/// run before `parseUserMessageContent` in the stdin loop so a ping is answered
/// with a `pong` and never queued as a prompt (see SPEC §2.7).
pub fn isPingFrame(allocator: std.mem.Allocator, line: []const u8) bool {
    return isFrameOfType(allocator, line, "ping");
}

/// True if `line` is a `{"type":"interrupt"}` frame: the hub asks the daemon
/// to stop the turn in flight and keep the session (see SPEC §2.7).
pub fn isInterruptFrame(allocator: std.mem.Allocator, line: []const u8) bool {
    return isFrameOfType(allocator, line, "interrupt");
}

/// Read the byte range [start_pos..end_pos) from a file via pread. Caller
/// owns the returned slice.
pub fn readFileRange(allocator: std.mem.Allocator, file: std.fs.File, start_pos: u64, end_pos: u64) ![]u8 {
    const len = std.math.cast(usize, end_pos -| start_pos) orelse return error.OutOfMemory;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const done = try file.preadAll(buf, start_pos);
    return if (done == len) buf else try allocator.realloc(buf, done);
}

/// A cursor belongs to one file and one turn. A missing boundary leaves
/// streaming suspended until the active prompt can be located in that file.
const TurnTranscript = struct {
    path: ?[]u8 = null,
    tailer: ?stream_mod.Tailer = null,
    inode: ?std.fs.File.INode = null,
    start: ?u64 = null,
    size: u64 = 0,
    initial_resume: bool,
    first_turn: bool = true,
    allow_zero_offset: bool = false,
    searched_size: ?u64 = null,
    minimum_prompt_offset: u64 = 0,

    fn reset(self: *TurnTranscript) void {
        if (self.tailer) |*t| t.deinit();
        self.tailer = null;
        self.inode = null;
        self.allow_zero_offset = false;
        self.start = null;
        self.size = 0;
        self.searched_size = null;
        self.minimum_prompt_offset = 0;
    }

    fn deinit(self: *TurnTranscript, allocator: std.mem.Allocator) void {
        self.reset();
        if (self.path) |p| allocator.free(p);
    }

    fn observePath(self: *TurnTranscript, allocator: std.mem.Allocator, payload: []const u8) !void {
        const path = try driver_mod.extractSafeTranscriptPath(allocator, payload) orelse return;
        if (self.path) |old| {
            if (std.mem.eql(u8, old, path)) {
                allocator.free(path);
                return;
            }
            allocator.free(old);
        }
        self.reset();
        self.path = path;
    }

    fn begin(self: *TurnTranscript, allocator: std.mem.Allocator, after_interrupt: bool) void {
        const fresh = self.first_turn and !self.initial_resume and !after_interrupt;
        self.first_turn = false;
        self.reset();
        const path = self.path orelse return;
        var t = stream_mod.Tailer.open(allocator, path) catch |err| {
            self.allow_zero_offset = err == error.FileNotFound and fresh;
            return;
        };
        const stat = t.file.stat() catch {
            t.deinit();
            return;
        };
        self.inode = stat.inode;
        self.size = stat.size;
        self.initial_resume = false;
        if (after_interrupt) {
            // Late output can follow this snapshot. Wait for the new user
            // record or finish from Stop alone if Claude never writes one.
            self.minimum_prompt_offset = stat.size;
            t.deinit();
            return;
        }
        self.start = stat.size;
        t.pos = stat.size;
        self.tailer = t;
    }

    fn refresh(self: *TurnTranscript, allocator: std.mem.Allocator, prompt: []const u8, recover: bool) void {
        const path = self.path orelse return;
        const file = transcript_mod.openTranscriptRegularFile(path) catch |err| {
            if (err != error.FileNotFound or self.inode != null) self.reset();
            return;
        };
        defer file.close();
        const stat = file.stat() catch return;
        if ((self.inode != null and self.inode != stat.inode) or stat.size < self.size or
            (self.tailer != null and stat.size < self.tailer.?.pos)) self.reset();
        self.size = stat.size;
        self.inode = stat.inode;
        if (self.tailer != null or !recover or self.searched_size == stat.size) return;
        self.searched_size = stat.size;
        const offset = driver_mod.findPromptTurnOffset(allocator, path, prompt) orelse
            if (self.allow_zero_offset) @as(u64, 0) else return;
        if (offset < self.minimum_prompt_offset) return;
        var t = stream_mod.Tailer.open(allocator, path) catch return;
        const opened = t.file.stat() catch {
            t.deinit();
            return;
        };
        if (opened.inode != stat.inode or opened.size < stat.size) {
            t.deinit();
            return;
        }
        self.start = offset;
        self.initial_resume = false;
        t.pos = offset;
        self.tailer = t;
    }
};

const PendingStop = struct {
    payload: []u8,
    deadline: i128,
    inode: ?std.fs.File.INode,
    scan_pos: u64,

    fn status(self: *PendingStop, allocator: std.mem.Allocator, transcript: *TurnTranscript, prompt: []const u8) !driver_mod.StopSummaryStatus {
        if (self.inode != transcript.inode or self.scan_pos > transcript.size) {
            self.scan_pos = transcript.start orelse transcript.size;
            self.inode = transcript.inode;
        }
        if (transcript.size <= self.scan_pos) return .none;
        const file = transcript_mod.openTranscriptRegularFile(transcript.path orelse return .none) catch return .none;
        defer file.close();
        if ((file.stat() catch return .none).inode != self.inode) return .none;
        const last = try hook_mod.extractLastAssistantMessage(allocator, self.payload);
        defer if (last) |text| allocator.free(text);
        return driver_mod.scanStopRecords(allocator, file, &self.scan_pos, transcript.size, last, prompt) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .none,
        };
    }
};

const PendingPaste = struct {
    chunker: driver_mod.PasteChunker,
    stage: enum { chunks, enter_debounce } = .chunks,
    next_at_ns: i128 = 0,
    is_reinject: bool,

    fn init(text: []const u8, is_reinject: bool) PendingPaste {
        return .{ .chunker = .{ .text = text }, .is_reinject = is_reinject };
    }

    // Advance one scheduled write, leaving the main loop free between writes.
    fn advance(self: *PendingPaste, session: *zmux.NativeSession) !bool {
        const now: i128 = monotonicNs();
        if (now < self.next_at_ns) return false;
        switch (self.stage) {
            .chunks => {
                if (self.chunker.pos == 0) try session.writeInput(driver_mod.paste_start);
                var buf: [driver_mod.paste_chunk_bytes]u8 = undefined;
                if (self.chunker.next(&buf)) |chunk| {
                    try session.writeInput(chunk);
                    self.next_at_ns = now + driver_mod.paste_chunk_gap_ms * std.time.ns_per_ms;
                } else {
                    try session.writeInput(driver_mod.paste_end);
                    self.stage = .enter_debounce;
                    self.next_at_ns = now + driver_mod.ink_enter_debounce_ms * std.time.ns_per_ms;
                }
                return false;
            },
            .enter_debounce => {
                try session.writeInput("\r");
                return true;
            },
        }
    }

    fn cancel(self: PendingPaste, session: *zmux.NativeSession) !void {
        if (self.stage == .chunks and self.chunker.pos != 0) try session.writeInput(driver_mod.paste_end);
        try session.writeInput("\x15");
    }
};

fn clearStop(allocator: std.mem.Allocator, pending: *?PendingStop) void {
    if (pending.*) |stop| allocator.free(stop.payload);
    pending.* = null;
}

fn emitTurnResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    transcript: *TurnTranscript,
    prompt: []const u8,
    stop_payload: []const u8,
    failed: bool,
    turn_start_ns: i128,
    session_id: []const u8,
) !void {
    const stop_last = try hook_mod.extractLastAssistantMessage(allocator, stop_payload);
    defer if (stop_last) |last| allocator.free(last);
    var summary: ?transcript_mod.Summary = null;
    defer if (summary) |*c| c.deinit(allocator);
    var parsed_pos: ?u64 = null;
    for (0..30) |attempt| {
        const inode = transcript.inode;
        const start = transcript.start;
        transcript.refresh(allocator, prompt, true);
        if (inode != transcript.inode or start != transcript.start or
            (parsed_pos != null and transcript.size < parsed_pos.?))
        {
            if (summary) |*c| c.deinit(allocator);
            summary = null;
            parsed_pos = null;
        }
        const t = if (transcript.tailer) |*t| t else {
            // Allow a final user record to flush before giving up on a known
            // path whose turn boundary is still unknown.
            if (transcript.path == null or attempt + 1 == 30) break;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            continue;
        };
        _ = try pumpTranscript(t, writer);
        if (parsed_pos != t.pos and t.pos > transcript.start.? and t.pos - transcript.start.? <= 64 * 1024 * 1024) {
            parsed_pos = t.pos;
            const bytes = readFileRange(allocator, t.file, transcript.start.?, t.pos) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break,
            };
            defer allocator.free(bytes);
            if (transcript_mod.parseWithOptions(allocator, bytes, .{ .keep_replay = false, .stop_text = if (failed) null else stop_last })) |parsed| {
                if (summary) |*c| c.deinit(allocator);
                summary = parsed;
                if (failed or ((parsed.final_text.len > 0 or parsed.is_error) and driver_mod.finalTextMatchesStop(parsed.final_text, stop_last))) break;
            } else |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            }
        }
        if (attempt + 1 < 30) std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    if (transcript.tailer) |*t| try t.flushPartial(writer);
    const duration = elapsedMs(turn_start_ns, monotonicNs());
    if (failed) {
        if (summary) |*s| {
            if (try hook_mod.extractErrorMessageAlloc(allocator, stop_payload)) |message| {
                if (std.mem.trim(u8, message, " \t\r\n").len > 0) {
                    allocator.free(s.final_text);
                    s.final_text = message;
                } else allocator.free(message);
            }
            s.is_error = true;
            if (s.subtype) |old| allocator.free(old);
            s.subtype = null; // emitJson supplies error_during_execution
        } else {
            summary = try driver_mod.synthesizeStopFailureSummary(allocator, stop_payload);
        }
    } else if (summary) |*s| {
        try driver_mod.preferStopText(allocator, s, stop_last);
    } else if (stop_last) |last| {
        if (std.mem.trim(u8, last, " \t\r\n").len > 0) {
            const sid = try hook_mod.extractSessionId(allocator, stop_payload);
            defer if (sid) |id| allocator.free(id);
            const fallback: transcript_mod.Summary = .{
                .session_id = @constCast(sid orelse session_id),
                .final_text = last,
                .num_turns = 1,
                .is_error = false,
                .total_cost_usd = 0,
                .duration_api_ms = 0,
                .usage = .{},
                .jsonl_replay = &.{},
            };
            try emit_mod.emitJson(allocator, writer, .{ .summary = &fallback, .duration_ms = duration });
            return writer.flush();
        }
    }
    if (summary) |*s| {
        if (s.final_text.len > 0 or s.is_error) {
            if (s.session_id.len == 0) s.session_id = try allocator.dupe(u8, session_id);
            try emit_mod.emitJson(allocator, writer, .{ .summary = s, .duration_ms = duration, .error_reason = if (failed) "stop_failure" else null });
            return writer.flush();
        }
    }
    try writeError(allocator, writer, "result_unavailable", session_id, duration);
}

fn pumpTranscript(tailer: *stream_mod.Tailer, writer: *std.Io.Writer) !usize {
    const lines = tailer.pump(writer) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return e,
        else => 0,
    };
    if (lines > 0) try writer.flush();
    return lines;
}

fn writeError(allocator: std.mem.Allocator, writer: *std.Io.Writer, reason: []const u8, sid: []const u8, duration: u64) !void {
    try emit_mod.emitErrorResult(allocator, writer, "error", reason, sid, duration);
    try writer.flush();
}

/// Emit a minimal `claude -p stream-json` style `system:init` envelope.
/// Used at startup so hubs can capture the session_id and treat the agent
/// as alive without waiting for the first transcript flush.
pub fn emitSystemInit(writer: *std.Io.Writer, session_id: []const u8) !void {
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

/// Emit a `{"type":"pong","ts":<unix_ms>}` health-probe response. Produced by
/// the main event loop in reply to a `ping` frame; its arrival proves the loop
/// is not wedged (see SPEC §2.7).
pub fn emitPong(writer: *std.Io.Writer) !void {
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("pong");
    try jw.objectField("ts");
    try jw.write(std.time.milliTimestamp());
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Return true if `fd` has data available to read, without blocking.
/// Uses poll(2) with a 0 timeout. POLLHUP / POLLERR also report as readable
/// so a subsequent read() can pick up EOF.
fn fdReadable(fd: std.posix.fd_t) bool {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    if (ready == 0) return false;
    return (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

fn childExited(shared: *driver_mod.SharedState, session: *zmux.NativeSession) bool {
    return shared.exited.load(.seq_cst) or session.state() == .terminated;
}

/// Wait until the PTY has been quiet for `quiet_ms` (at most `max_ms`), then
/// hold for `settle_ms` more so late Ink chrome finishes painting before we
/// type. Flushes queued DEC replies the whole time: Ink blocks its render on
/// those replies, so a wait that stops answering them never sees quiet.
fn settleBeforePrompt(
    shared: *driver_mod.SharedState,
    session: *zmux.NativeSession,
    quiet_ms: u64,
    max_ms: u64,
    settle_ms: u64,
) void {
    const step_ns: u64 = 15 * std.time.ns_per_ms;
    const quiet_ns: i128 = @as(i128, quiet_ms) * std.time.ns_per_ms;
    const started: i128 = monotonicNs();
    const give_up: i128 = started + @as(i128, max_ms) * std.time.ns_per_ms;
    while (true) {
        if (interrupted() or childExited(shared, session)) return;
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
        if (interrupted() or childExited(shared, session)) return;
        driver_mod.flushPendingToPty(shared, session);
        const remaining = settle_end - monotonicNs();
        if (remaining <= 0) break;
        std.Thread.sleep(@intCast(@min(remaining, @as(i128, step_ns))));
    }
}

pub fn ptyTraceInterval(debug: bool, setting: ?[]const u8) ?i128 {
    const default: ?i128 = if (debug) 60 * std.time.ns_per_s else null;
    const raw = std.mem.trim(u8, setting orelse return default, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no")) return null;
    const seconds = std.fmt.parseInt(u32, raw, 10) catch return default;
    return if (seconds == 0) null else @as(i128, seconds) * std.time.ns_per_s;
}

fn startupFailure(writer: *std.Io.Writer, reason: []const u8, stage: []const u8) !u8 {
    try emit_mod.emitErrorResultDetail(writer, "error", reason, "", 0, .{ .stage = stage });
    try writer.flush();
    return 2;
}

fn writeFailureExit(cause: ?std.fs.File.WriteError) u8 {
    return if ((cause orelse return 2) == error.BrokenPipe) 0 else 2;
}

/// Daemon entry. Runs until stdin EOF (callers close the spawned daemon's
/// stdin to signal shutdown) or until the child `claude` exits.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!u8 {
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    return runWithIo(allocator, opts, std.posix.STDIN_FILENO, &stdout_writer.interface) catch |e| switch (e) {
        error.WriteFailed => writeFailureExit(stdout_writer.err),
        error.OutOfMemory, error.InvalidExtraSettings, error.InvalidOptions => |err| return err,
        else => return error.IoFailure,
    };
}

fn runWithIo(backing_allocator: std.mem.Allocator, opts: Options, stdin_fd: std.posix.fd_t, stdout: *std.Io.Writer) !u8 {
    const scope = driver_mod.InterruptScope.enter();
    defer scope.exit();
    // Consume only a signal this invocation actually observed. A signal that
    // arrives during a successful teardown remains pending for the next run.
    if (interrupted()) {
        driver_mod.clearInterrupt();
        return 130;
    }
    var thread_safe: std.heap.ThreadSafeAllocator = .{ .child_allocator = backing_allocator };
    const allocator = thread_safe.allocator();
    const drv_opts = toDriverOptions(opts);
    driver_mod.validateOptions(drv_opts) catch return error.InvalidOptions;
    driver_mod.validateCwd(opts.cwd) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return startupFailure(stdout, "spawn_failed", "cwd"),
    };
    const trace_start: i128 = monotonicNs();
    trace(opts, trace_start, "daemon.run() entered");

    // ----------- 1. Hook harness + argv + env -----------
    var harness = hook_mod.createWithOptions(allocator, .{
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
    }) catch |e| switch (e) {
        error.InvalidExtraSettings => {
            _ = try startupFailure(stdout, "spawn_failed", "hook_settings");
            return error.InvalidExtraSettings;
        },
        error.OutOfMemory => return e,
        else => return startupFailure(stdout, "spawn_failed", "hook_harness"),
    };
    defer harness.deinit();

    const claude_bin = driver_mod.resolveClaudeBinary(allocator, opts.claude_path) catch |err| switch (err) {
        error.ClaudeNotFound => return startupFailure(stdout, "claude_not_found", "resolve_claude"),
        error.OutOfMemory => return err,
    };
    defer allocator.free(claude_bin);

    var argv = try driver_mod.buildArgv(allocator, claude_bin, harness.settings_json, drv_opts);
    defer argv.deinit(allocator);

    const shell_cmd = driver_mod.buildShellCommandInDir(allocator, argv.items, opts.cwd) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return startupFailure(stdout, "spawn_failed", "shell_command"),
    };
    defer allocator.free(shell_cmd);

    // Same child environment as one-shot mode: nested-session markers are
    // stripped. Only the relay script embeds the FIFO path and nonce.
    var env_list = driver_mod.buildChildEnv(allocator, harness.fifo_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return startupFailure(stdout, "spawn_failed", "environment"),
    };
    defer driver_mod.freeChildEnv(allocator, &env_list);

    // ----------- 2. FIFO for hook events -----------
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return startupFailure(stdout, "spawn_failed", "fifo_open");
    defer std.posix.close(fifo_fd);

    // ----------- 3. SharedState + spawn zmux session -----------
    var shared: driver_mod.SharedState = .{
        .session = undefined,
        .dec = .{ .rows = opts.rows, .cols = opts.cols },
        .debug_screen = driver_mod.debugScreenEnabled(opts.debug),
        .debug = opts.debug,
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
    }

    const sink: zmux.native.EventSink = .{
        .context = @ptrCast(&shared),
        .emit = driver_mod.onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p-daemon",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = opts.cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return startupFailure(stdout, "spawn_failed", "pty_spawn");
    shared.session = session;
    defer session.destroy();
    trace(opts, trace_start, "zmux session spawned; Ink booting");

    var state: State = .waiting_for_ready;
    var transcript: TurnTranscript = .{ .initial_resume = driver_mod.isResumeRun(drv_opts) };
    defer transcript.deinit(allocator);
    var pending_stop: ?PendingStop = null;
    defer clearStop(allocator, &pending_stop);

    var fifo_buf: LineBuffer = .{};
    defer fifo_buf.bytes.deinit(allocator);
    var stdin_buf: LineBuffer = .{};
    defer stdin_buf.bytes.deinit(allocator);
    var read_buf: [4096]u8 = undefined;

    var prompt_queue: std.ArrayList([]u8) = .{};
    var prompt_queue_head: usize = 0;
    defer {
        for (prompt_queue.items[prompt_queue_head..]) |p| allocator.free(p);
        prompt_queue.deinit(allocator);
    }
    var active_prompt: ?[]u8 = null;
    defer if (active_prompt) |prompt| allocator.free(prompt);
    var pending_paste: ?PendingPaste = null;
    var typed_ns: i64 = 0;
    var injections: u32 = 0;
    var exit_seen_ns: ?i64 = null;
    var queued_bytes: usize = 0;

    // Session id from the SessionStart payload; error frames carry it.
    var session_id: ?[]u8 = null;
    defer if (session_id) |sid| allocator.free(sid);

    // Transcript-advance watchdog baseline (see `transcriptStalled`).
    var last_transcript_advance_ns: i64 = 0;
    // Set while an `interrupt` frame waits for the turn's Stop hook.
    var interrupt_deadline_ns: ?i128 = null;
    // The previous turn ended as `interrupted`; its Stop hook may still come.
    var after_interrupt = false;
    // UserPromptSubmit fired for the turn in flight.
    var prompt_acked = false;

    var turn_start_ns: i128 = 0;
    const session_start_deadline_ns: i128 = trace_start + @as(i128, @intCast(opts.session_start_timeout_ms)) * std.time.ns_per_ms;
    var stdin_eof = false;

    const trace_interval = ptyTraceInterval(opts.debug, std.posix.getenv("CLAUDE_P_PTY_TRACE"));
    var next_trace_ns = trace_start + (trace_interval orelse 0);
    var last_trace_bytes: u64 = 0;

    while (true) {
        if (interrupted()) {
            driver_mod.clearInterrupt();
            return 130;
        }
        // ----- flush DEC-responder bytes to PTY -----
        driver_mod.flushPendingToPty(&shared, session);

        // ----- pre-SessionStart modal dialogs (shared with driver.run) -----
        // Workspace trust (Claude Code 2.1 preselects "No, exit"),
        // bypass-permissions, and development channels.
        if (state == .waiting_for_ready) {
            driver_mod.maybeHandleStartupDialogs(drv_opts, trace_start, &shared, session);
            if (shared.dialog.refused != .none) {
                try writeError(allocator, stdout, "unexpected_startup_dialog", session_id orelse "", elapsedMs(trace_start, monotonicNs()));
                return 2;
            }
        }

        const before_size = transcript.size;
        // ----- drain FIFO (hook events) -----
        while (true) {
            const n = std.posix.read(fifo_fd, &read_buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };
            if (n == 0) break;
            var chunk: []const u8 = read_buf[0..n];
            while (try fifo_buf.next(allocator, &chunk, false)) |frame| {
                const line = switch (frame) {
                    .line => |line| line,
                    .oversized => {
                        try emit_mod.writeProtocolError(stdout, "fifo_line_too_large");
                        continue;
                    },
                };
                if (hook_mod.parseLineWithNonce(line, &harness.nonce)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s}\n", .{@tagName(ev.event)});
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired");
                            try transcript.observePath(allocator, ev.payload);
                            if (try hook_mod.extractSessionId(allocator, ev.payload)) |id| {
                                if (session_id) |old| allocator.free(old);
                                session_id = id;
                            }
                            if (state == .waiting_for_ready) {
                                shared.startup_done.store(true, .seq_cst);
                                try emitSystemInit(stdout, session_id orelse "");
                                try stdout.flush();
                                state = .idle;
                                trace(opts, trace_start, "daemon ready for prompts");
                            }
                        },
                        .user_prompt_submit => {
                            if (state != .busy or injections == 0) continue;
                            if (try hook_mod.extractPrompt(allocator, ev.payload)) |received| {
                                defer allocator.free(received);
                                if (driver_mod.isPromptTruncated(active_prompt.?, received)) {
                                    try writeError(allocator, stdout, "prompt_truncated", session_id orelse "", elapsedMs(turn_start_ns, monotonicNs()));
                                    return 2;
                                }
                            }
                            try transcript.observePath(allocator, ev.payload);
                            prompt_acked = true;
                            if (pending_paste) |paste| {
                                if (paste.is_reinject) {
                                    try paste.cancel(session);
                                    pending_paste = null;
                                }
                            }
                        },
                        .permission_request => if (state == .busy and injections > 0 and !driver_mod.hasExtraHook(opts.extra_hooks, "PermissionRequest")) {
                            if (pending_paste) |paste| try paste.cancel(session);
                            pending_paste = null;
                            session.writeInput("\x1b") catch {};
                            const tool = hook_mod.extractPermissionTool(allocator, ev.payload);
                            defer if (tool) |name| allocator.free(name);
                            try emit_mod.emitErrorResultDetail(stdout, "error_during_execution", "permission_prompt_blocked", session_id orelse "", elapsedMs(turn_start_ns, monotonicNs()), .{ .message = tool orelse "unknown tool" });
                            try stdout.flush();
                            clearStop(allocator, &pending_stop);
                            interrupt_deadline_ns = null;
                            after_interrupt = true;
                            state = .idle;
                        },
                        .stop, .stop_failure => {
                            if (!stopBelongsToTurn(state, prompt_acked)) continue;
                            try transcript.observePath(allocator, ev.payload);
                            transcript.refresh(allocator, active_prompt.?, true);
                            clearStop(allocator, &pending_stop);
                            if (ev.event == .stop_failure) {
                                try emitTurnResult(allocator, stdout, &transcript, active_prompt.?, ev.payload, true, turn_start_ns, session_id orelse "");
                                interrupt_deadline_ns = null;
                                after_interrupt = false;
                                state = .idle;
                            } else {
                                pending_stop = .{
                                    .payload = try allocator.dupe(u8, ev.payload),
                                    .deadline = @as(i128, monotonicNs()) + driver_mod.stopConfirmationNs(opts.extra_hooks),
                                    .inode = transcript.inode,
                                    .scan_pos = transcript.size,
                                };
                            }
                        },
                        .unknown => {},
                    }
                }
            }
        }

        if (state == .busy) {
            transcript.refresh(allocator, active_prompt.?, prompt_acked and !transcript.initial_resume);
            if (transcript.size > before_size) last_transcript_advance_ns = monotonicNs();
            if (transcript.tailer) |*t| {
                const before = t.pos;
                _ = try pumpTranscript(t, stdout);
                if (t.pos > before) last_transcript_advance_ns = monotonicNs();
            }
            if (pending_stop) |*stop| {
                const status = try stop.status(allocator, &transcript, active_prompt.?);
                if (status == .continued) {
                    clearStop(allocator, &pending_stop);
                } else if (status == .confirmed or monotonicNs() >= stop.deadline) {
                    try emitTurnResult(allocator, stdout, &transcript, active_prompt.?, stop.payload, false, turn_start_ns, session_id orelse "");
                    clearStop(allocator, &pending_stop);
                    interrupt_deadline_ns = null;
                    after_interrupt = false;
                    state = .idle;
                }
            }
        }

        const now_ns: i128 = monotonicNs();
        const sid = session_id orelse "";
        const age = elapsedMs(if (state == .busy) turn_start_ns else trace_start, now_ns);
        if (!stdin_eof and fdReadable(stdin_fd)) {
            const n = try std.posix.read(stdin_fd, &read_buf);
            stdin_eof = n == 0;
            var chunk: []const u8 = read_buf[0..n];
            while (try stdin_buf.next(allocator, &chunk, stdin_eof)) |frame| {
                const line = switch (frame) {
                    .line => |line| line,
                    .oversized => {
                        try emit_mod.writeProtocolError(stdout, "stdin_line_too_large");
                        continue;
                    },
                };
                switch (try readInputFrame(allocator, stdout, line) orelse continue) {
                    .ping => {
                        try emitPong(stdout);
                        try stdout.flush();
                    },
                    .interrupt => if (state == .busy and interrupt_deadline_ns == null) {
                        if (pending_paste) |paste| {
                            try paste.cancel(session);
                            pending_paste = null;
                            if (!paste.is_reinject) {
                                try emit_mod.emitErrorResult(allocator, stdout, "interrupted", "interrupted", sid, age);
                                try stdout.flush();
                                after_interrupt = true;
                                state = .idle;
                                continue;
                            }
                        }
                        session.writeInput("\x1b") catch {};
                        interrupt_deadline_ns = @as(i128, monotonicNs()) + interrupt_window_ms * std.time.ns_per_ms;
                    },
                    .user => |content| {
                        if (prompt_queue.items.len - prompt_queue_head >= max_queued_prompts or content.len > max_queued_bytes - queued_bytes) {
                            allocator.free(content);
                            try emit_mod.writeProtocolError(stdout, "queue_full");
                            continue;
                        }
                        errdefer allocator.free(content);
                        try prompt_queue.append(allocator, content);
                        queued_bytes += content.len;
                    },
                }
            }
        }

        if (stdin_eof and state != .busy and prompt_queue_head == prompt_queue.items.len) return 0;
        if (childExited(&shared, session)) {
            if (exit_seen_ns == null) exit_seen_ns = @intCast(now_ns);
            if (state == .busy and (pending_stop != null or elapsedMs(exit_seen_ns.?, now_ns) < driver_mod.post_exit_fifo_grace_ms)) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            traceFmt(opts, trace_start, "child exited while {s}", .{@tagName(state)});
            driver_mod.reportFailure(&shared, shared.debug_screen, "claude exited while {s}", .{@tagName(state)});
            try writeError(allocator, stdout, "child_exited", sid, age);
            return 2;
        }
        const last_output_ns = shared.last_output_ns.load(.seq_cst);
        if (trace_interval) |interval| {
            if (now_ns >= next_trace_ns) {
                const bytes = shared.bytes_seen.load(.seq_cst);
                const pos = if (transcript.tailer) |t| t.pos else 0;
                const byte_age: i64 = if (last_output_ns == 0) -1 else @intCast(elapsedMs(last_output_ns, now_ns));
                std.debug.print("[pty-trace] state={s} pty_bytes={d} pty_delta={d} last_byte_age_ms={d} turn_age_ms={d} transcript_pos={d}\n", .{
                    @tagName(state), bytes, bytes - last_trace_bytes, byte_age, if (state == .busy) age else 0, pos,
                });
                last_trace_bytes = bytes;
                next_trace_ns = now_ns + interval;
            }
        }
        if (opts.session_start_timeout_ms != 0 and state == .waiting_for_ready and now_ns > session_start_deadline_ns) {
            driver_mod.reportFailure(&shared, shared.debug_screen, "timed out waiting for SessionStart", .{});
            try writeError(allocator, stdout, "session_start_timeout", sid, age);
            return 124;
        }
        if (pending_paste == null and pending_stop == null and idleTimedOut(state, last_output_ns, now_ns, opts.idle_progress_timeout_ms)) {
            try writeError(allocator, stdout, "idle_timeout", sid, age);
            return 124;
        }
        if (pending_paste == null and pending_stop == null and transcriptStalled(state, last_transcript_advance_ns, now_ns, opts.transcript_idle_timeout_ms)) {
            try writeError(allocator, stdout, "transcript_stalled", sid, age);
            return 124;
        }

        // ----- interrupt window: no Stop arrived after ESC -----
        // Runs after the FIFO drain above, so a Stop that landed inside the
        // window has already ended the turn with a normal result.
        if (state == .busy) {
            if (interrupt_deadline_ns) |deadline| {
                const window_now: i128 = monotonicNs();
                if (pending_stop == null and window_now >= deadline) {
                    trace(opts, trace_start, "interrupt window elapsed without Stop; reporting interrupted");
                    try emit_mod.emitErrorResult(allocator, stdout, "interrupted", "interrupted", sid, elapsedMs(turn_start_ns, window_now));
                    try stdout.flush();
                    clearStop(allocator, &pending_stop);
                    interrupt_deadline_ns = null;
                    after_interrupt = true;
                    // The session stays alive for the next turn.
                    state = .idle;
                }
            }
        }

        if (state == .busy and pending_paste == null and interrupt_deadline_ns == null) {
            const advanced = if (transcript.tailer) |t| t.pos > transcript.start.? else false;
            const accepted = prompt_acked or (!after_interrupt and advanced);
            switch (driver_mod.promptWatchdogAction(accepted, injections, @intCast(elapsedMs(typed_ns, now_ns)))) {
                .wait => {},
                .reinject => {
                    traceFmt(opts, trace_start, "retrying prompt after {d} unacknowledged injections", .{injections});
                    session.writeInput("\x15") catch {};
                    settleBeforePrompt(&shared, session, 0, 0, driver_mod.ink_enter_debounce_ms);
                    settleBeforePrompt(&shared, session, driver_mod.ink_quiescence_ms, driver_mod.ink_max_wait_ms, 0);
                    if (interrupted() or childExited(&shared, session)) continue;
                    pending_paste = .init(active_prompt.?, true);
                },
                .give_up => {
                    try writeError(allocator, stdout, "prompt_not_accepted", sid, age);
                    session.writeInput("\x15") catch {};
                    after_interrupt = true;
                    state = .idle;
                },
            }
        }

        if (state == .idle) {
            if (active_prompt) |old| allocator.free(old);
            active_prompt = null;
            if (childExited(&shared, session)) continue;
            if (prompt_queue_head < prompt_queue.items.len) {
                if (transcript.initial_resume) {
                    settleBeforePrompt(&shared, session, driver_mod.resume_quiescence_ms, driver_mod.resume_max_wait_ms, 0);
                } else {
                    settleBeforePrompt(&shared, session, driver_mod.ink_quiescence_ms, driver_mod.ink_max_wait_ms, driver_mod.prompt_settle_ms);
                }
                if (interrupted() or childExited(&shared, session)) continue;
                const content = prompt_queue.items[prompt_queue_head];
                prompt_queue_head += 1;
                queued_bytes -= content.len;
                active_prompt = content;
                if (prompt_queue_head == prompt_queue.items.len) {
                    prompt_queue.clearRetainingCapacity();
                    prompt_queue_head = 0;
                } else if (prompt_queue_head >= 64 and prompt_queue_head >= prompt_queue.items.len / 2) {
                    const pending = prompt_queue.items[prompt_queue_head..];
                    std.mem.copyForwards([]u8, prompt_queue.items, pending);
                    prompt_queue.shrinkRetainingCapacity(pending.len);
                    prompt_queue_head = 0;
                }
                if (after_interrupt) session.writeInput("\x15") catch {};
                // Snapshot immediately before typing, including any idle-time
                // writes or resumed history that appeared during settling.
                transcript.begin(allocator, after_interrupt);
                traceFmt(opts, trace_start, "sending prompt ({d} bytes, transcript offset {?d})", .{ content.len, transcript.start });
                turn_start_ns = monotonicNs();
                pending_paste = .init(content, false);
                injections = 0;
                prompt_acked = false;
                interrupt_deadline_ns = null;
                state = .busy;
            }
        }

        if (pending_paste) |*paste| {
            const attempt_finished = paste.advance(session) catch |err| failed: {
                traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(err)});
                paste.cancel(session) catch {};
                // A child exit can race the write. Let FIFO drain, exit
                // detection and the acceptance watchdog resolve this attempt.
                break :failed true;
            };
            if (attempt_finished) {
                typed_ns = monotonicNs();
                if (!paste.is_reinject) {
                    shared.last_output_ns.store(typed_ns, .seq_cst);
                    last_transcript_advance_ns = typed_ns;
                }
                injections += 1;
                pending_paste = null;
            }
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
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
        "{\"type\":\"text\",\"text\":\"hi \"}," ++
        "{\"type\":\"text\",\"text\":\"there\"}" ++
        "]}}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi there", out);
}

test "parseUserMessageContent: fallback top-level content" {
    const line = "{\"type\":\"user\",\"content\":\"hi\"}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
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
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try emitPong(&aw.writer);
    buf = aw.toArrayList();
    const out = buf.items;
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ts\":") != null);
}

test "idleTimedOut: busy + stale last_output trips" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms; // 1_000_000 ms
    const last_out: i64 = 0; // not yet observed → never trips
    try testing.expect(!idleTimedOut(.busy, last_out, now, 180_000));
    // 200s of silence > 180s timeout
    const stale: i64 = @intCast(now - 200_000 * std.time.ns_per_ms);
    try testing.expect(idleTimedOut(.busy, stale, now, 180_000));
}

test "idleTimedOut: busy + fresh baseline does not trip" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    // Just reset on dispatch (last_output == now) → 0ms idle.
    try testing.expect(!idleTimedOut(.busy, @intCast(now), now, 180_000));
    // 1s after a fresh baseline, well under timeout.
    const one_s_ago: i64 = @intCast(now - 1_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.busy, one_s_ago, now, 180_000));
}

test "idleTimedOut: idle/waiting never trip even with ancient timestamp" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 3_600_000 * std.time.ns_per_ms); // 1h ago
    // This is the Bug B regression: an idle daemon parked for an hour must NOT
    // be considered timed out — only .busy is subject to the watchdog.
    try testing.expect(!idleTimedOut(.idle, ancient, now, 180_000));
    try testing.expect(!idleTimedOut(.waiting_for_ready, ancient, now, 180_000));
}

test "idleTimedOut: timeout 0 disables" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 3_600_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.busy, ancient, now, 0));
}

test "transcriptStalled: busy + stale baseline trips" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const stale: i64 = @intCast(now - 700_000 * std.time.ns_per_ms);
    try testing.expect(transcriptStalled(.busy, stale, now, 600_000));
    // Exactly at the limit does not trip; one ms past it does.
    const at_limit: i64 = @intCast(now - 600_000 * std.time.ns_per_ms);
    try testing.expect(!transcriptStalled(.busy, at_limit, now, 600_000));
    const past_limit: i64 = @intCast(now - 600_001 * std.time.ns_per_ms);
    try testing.expect(transcriptStalled(.busy, past_limit, now, 600_000));
}

test "transcriptStalled: fresh baseline or no baseline does not trip" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    // Reset on dispatch or on a tailer advance.
    try testing.expect(!transcriptStalled(.busy, @intCast(now), now, 600_000));
    const recent: i64 = @intCast(now - 599_000 * std.time.ns_per_ms);
    try testing.expect(!transcriptStalled(.busy, recent, now, 600_000));
    try testing.expect(!transcriptStalled(.busy, 0, now, 600_000));
}

test "transcriptStalled: idle/waiting never trip, timeout 0 disables" {
    const now: i128 = 10_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 7_200_000 * std.time.ns_per_ms);
    try testing.expect(!transcriptStalled(.idle, ancient, now, 600_000));
    try testing.expect(!transcriptStalled(.waiting_for_ready, ancient, now, 600_000));
    try testing.expect(!transcriptStalled(.busy, ancient, now, 0));
}

test "transcriptStalled: spinner output cannot reset it" {
    // The PTY watchdog sees fresh output; the transcript watchdog still trips.
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const fresh_pty: i64 = @intCast(now - 100 * std.time.ns_per_ms);
    const stale_transcript: i64 = @intCast(now - 601_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.busy, fresh_pty, now, 180_000));
    try testing.expect(transcriptStalled(.busy, stale_transcript, now, 600_000));
}

test "isInterruptFrame: interrupt frame recognized" {
    try testing.expect(isInterruptFrame(testing.allocator, "{\"type\":\"interrupt\"}"));
    try testing.expect(isInterruptFrame(testing.allocator, "{\"type\":\"interrupt\",\"id\":3}"));
}

test "isInterruptFrame: other frames and malformed input return false" {
    const user = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"interrupt\"}}";
    try testing.expect(!isInterruptFrame(testing.allocator, user));
    try testing.expect(!isInterruptFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(!isInterruptFrame(testing.allocator, "{\"type\":7}"));
    try testing.expect(!isInterruptFrame(testing.allocator, "{\"interrupt\":true}"));
    try testing.expect(!isInterruptFrame(testing.allocator, "\"interrupt\""));
    try testing.expect(!isInterruptFrame(testing.allocator, "not json"));
    try testing.expect(!isInterruptFrame(testing.allocator, ""));
    // A ping is not an interrupt and an interrupt is not a ping or a prompt.
    try testing.expect(!isPingFrame(testing.allocator, "{\"type\":\"interrupt\"}"));
    try testing.expectEqual(@as(?[]u8, null), try parseUserMessageContent(testing.allocator, "{\"type\":\"interrupt\"}"));
}

test "Stop ownership requires acknowledgment even after a successful turn" {
    try testing.expect(!stopBelongsToTurn(.idle, true));
    try testing.expect(!stopBelongsToTurn(.busy, false));
    try testing.expect(stopBelongsToTurn(.busy, true));
}

test "elapsedMs: clamps a start in the future to 0" {
    try testing.expectEqual(@as(u64, 1500), elapsedMs(0, 1500 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 0), elapsedMs(10, 5));
    try testing.expectEqual(@as(u64, 0), elapsedMs(7, 7));
    // Regression: extreme clock values overflowed the i128 subtraction.
    try testing.expectEqual(std.math.maxInt(u64), elapsedMs(std.math.minInt(i128), std.math.maxInt(i128)));
    try testing.expectEqual(std.math.maxInt(u64), elapsedMs(0, std.math.maxInt(i128)));
}

test "Options: hardening defaults match the contract" {
    const opts: Options = .{};
    try testing.expectEqual(@as(u64, 600_000), opts.transcript_idle_timeout_ms);
    try testing.expectEqual(@as(usize, 0), opts.extra_hooks.len);
    try testing.expectEqual(@as(?[]const u8, null), opts.extra_settings_json);
}

test "toDriverOptions: passes extra hooks and extra settings" {
    const hooks = [_]hook_mod.ExtraHook{.{ .event = "PreToolUse", .command = "echo hi" }};
    const drv = toDriverOptions(.{
        .extra_hooks = &hooks,
        .extra_settings_json = "{\"env\":{\"A\":\"1\"}}",
        .session_start_timeout_ms = 42,
    });
    try testing.expectEqual(@as(usize, 1), drv.extra_hooks.len);
    try testing.expectEqualStrings("PreToolUse", drv.extra_hooks[0].event);
    try testing.expectEqualStrings("echo hi", drv.extra_hooks[0].command);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\"}}", drv.extra_settings_json.?);
    try testing.expectEqual(@as(u64, 42), drv.timeout_ms);
    try testing.expectEqual(@as(usize, 0), toDriverOptions(.{}).extra_hooks.len);
}

test "stdin rejects malformed and mixed content once without completing a turn" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_][]const u8{ "", "\r", "   \t\r" }) |line| {
        try testing.expect(try readInputFrame(testing.allocator, &out.writer, line) == null);
    }
    try testing.expectEqual(0, out.written().len);
    for ([_][]const u8{
        "{", "{}", "{\"type\":\"user\"}",
        \\{"type":"user","message":{"role":"assistant","content":"wrong role"}}
        ,
        \\{"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"image"}]}}
        ,
        \\{"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":false}]}}
        ,
    }, [_][]const u8{ "invalid_json", "unsupported_frame_type", "invalid_user_message", "invalid_user_message", "unsupported_content_block", "unsupported_content_block" }) |line, reason| {
        out.clearRetainingCapacity();
        try testing.expect(try readInputFrame(testing.allocator, &out.writer, line) == null);
        try testing.expectEqual(1, std.mem.count(u8, out.written(), "\n"));
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("error", parsed.value.object.get("type").?.string);
        try testing.expectEqualStrings(reason, parsed.value.object.get("error").?.string);
    }
}

test "line buffer bounds fragmented input, resynchronizes and delivers EOF remainder once" {
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

test "readFileRange returns exactly owned bytes on short reads including EOF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "transcript", .data = "abc" });
    const file = try tmp.dir.openFile("transcript", .{});
    defer file.close();
    for ([_]u64{ 1, 3 }, [_][]const u8{ "bc", "" }) |start, want| {
        const slice = try readFileRange(testing.allocator, file, start, 300);
        defer testing.allocator.free(slice);
        try testing.expectEqualStrings(want, slice);
    }
}

test "PTY trace follows debug by default and honors explicit intervals and disable" {
    try testing.expectEqual(null, ptyTraceInterval(false, null));
    try testing.expectEqual(@as(?i128, 60 * std.time.ns_per_s), ptyTraceInterval(true, null));
    try testing.expectEqual(@as(?i128, std.time.ns_per_s), ptyTraceInterval(false, "1"));
    try testing.expectEqual(null, ptyTraceInterval(true, "off"));
}

const fixture_relay =
    \\stty raw -echo
    \\[ "$1" = --settings ]
    \\relay=$(python3 -c 'import json,shlex,sys; print(shlex.split(json.loads(sys.argv[1])["hooks"]["Stop"][0]["hooks"][0]["command"])[0])' "$2")
    \\
;

test "daemon reports spontaneous child exit before readiness, while idle, and during a turn" {
    const ready = fixture_relay ++
        \\printf '{"session_id":"fixture"}\n' | "$relay" SessionStart
        \\
    ;
    const busy = ready ++
        \\# Consume the bracketed paste markers, four prompt bytes, and Enter.
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
        \\
    ;
    const cases = [_]struct { script: []const u8, input: []const u8 = "", ready: bool = true, stopped: bool = false }{
        .{ .script = "exit 7\n", .ready = false },
        .{ .script = ready ++ "exit 0\n" },
        .{ .script = busy, .input = "{\"type\":\"user\",\"content\":\"test\"}\n" },
        .{ .script = busy ++
            \\# Finish delivering Stop after the PTY owner exits.
            \\trap '' HUP
            \\(sleep 0.05; printf '{"last_assistant_message":"done"}\n' | "$relay" Stop) </dev/null >/dev/null 2>&1 &
            \\
        , .input = "{\"type\":\"user\",\"content\":\"test\"}\n", .stopped = true },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            const script = try tmp.dir.createFile("child", .{ .mode = 0o700 });
            defer script.close();
            try script.writeAll("#!/bin/sh\nset -eu\n");
            try script.writeAll(case.script);
        }
        const path = try tmp.dir.realpathAlloc(testing.allocator, "child");
        defer testing.allocator.free(path);
        const pipe = try std.posix.pipe();
        defer std.posix.close(pipe[0]);
        // Keep stdin live past the child exit. Bound the fixture even if an
        // idle daemon regresses to waiting indefinitely for the next frame.
        var finished = std.atomic.Value(bool).init(false);
        const closer = try std.Thread.spawn(.{}, struct {
            fn close(fd: std.posix.fd_t, done: *std.atomic.Value(bool)) void {
                defer std.posix.close(fd);
                for (0..500) |_| {
                    if (done.load(.seq_cst)) break;
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.close, .{ pipe[1], &finished });
        defer {
            finished.store(true, .seq_cst);
            closer.join();
        }
        if (case.input.len > 0) try (std.fs.File{ .handle = pipe[1] }).writeAll(case.input);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const code = try runWithIo(testing.allocator, .{
            .claude_path = path,
            .session_start_timeout_ms = 3000,
            .idle_progress_timeout_ms = 3000,
        }, pipe[0], &out.writer);
        try testing.expectEqual(@as(u8, 2), code);
        var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
        if (case.ready) try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingInit, "\"subtype\":\"init\"") != null);
        if (case.stopped) try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingStop, "\"result\":\"done\"") != null);
        try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingExit, "\"error\":\"child_exited\"") != null);
        try testing.expect(lines.next() == null);
    }
}

const fixture_input = "{\"type\":\"user\",\"content\":\"test\"}\n";
const fixture_ready = fixture_relay ++
    \\file="$PWD/transcript"
    \\: > "$file"
    \\printf '{"session_id":"first","transcript_path":"%s"}' "$file" | "$relay" SessionStart
    \\dd bs=1 count=17 of=/dev/null 2>/dev/null
    \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
    \\
;

fn fixtureRun(script: []const u8, input: []const u8, writer: *std.Io.Writer) !u8 {
    return fixtureRunWithOptions(script, input, writer, .{});
}

fn fixtureRunWithOptions(script: []const u8, input: []const u8, writer: *std.Io.Writer, options: Options) !u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const exe = try tmp.dir.createFile("child", .{ .mode = 0o700 });
        defer exe.close();
        try exe.writeAll("#!/bin/sh\nset -eu\n");
        try exe.writeAll(script);
    }
    try tmp.dir.writeFile(.{ .sub_path = "stdin", .data = input });
    const stdin = try tmp.dir.openFile("stdin", .{});
    defer stdin.close();
    const exe = try tmp.dir.realpathAlloc(testing.allocator, "child");
    defer testing.allocator.free(exe);
    var opts = options;
    opts.claude_path = exe;
    opts.cwd = std.fs.path.dirname(exe);
    opts.session_start_timeout_ms = 3000;
    opts.idle_progress_timeout_ms = 3000;
    return runWithIo(testing.allocator, opts, stdin.handle, writer);
}

test "daemon responds to ping within 500 ms and cancels a 64 KiB paste before Enter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The child doubles as the hub. A FIFO lets it send the control frames
    // immediately after observing that the daemon has begun the paste.
    const script = try tmp.dir.createFile("child", .{ .mode = 0o700 });
    {
        defer script.close();
        try script.writeAll("#!/bin/sh\nset -eu\n" ++ fixture_relay ++
            \\exec 3>frames
            \\printf '{"session_id":"fixture"}' | "$relay" SessionStart
            \\exec python3 -c '
            \\import json, os, time
            \\with os.fdopen(3, "wb", buffering=0) as hub:
            \\    hub.write(json.dumps({"type":"user","content":"x"*65536}).encode() + b"\n")
            \\    first = os.read(0, 512)
            \\    assert first.startswith(b"\x1b[200~")
            \\    with open("sent_ms", "w") as stamp: stamp.write(str(time.time_ns() // 1000000))
            \\    hub.write(b"{\"type\":\"ping\"}\n{\"type\":\"interrupt\"}\n")
            \\    data = first
            \\    while b"\x15" not in data and b"\r" not in data: data += os.read(0, 1024)
            \\    assert data.endswith(b"\x1b[201~\x15") and b"\r" not in data
            \\    open("cancelled", "w").close()'
        );
    }
    const exe = try tmp.dir.realpathAlloc(testing.allocator, "child");
    defer testing.allocator.free(exe);
    const cwd = std.fs.path.dirname(exe).?;
    const fifo = try std.fs.path.joinZ(testing.allocator, &.{ cwd, "frames" });
    defer testing.allocator.free(fifo);
    const c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
    };
    try testing.expectEqual(0, c.mkfifo(fifo, 0o600));
    // Keep the hub side open through child exit on both Darwin and Linux.
    const input = try std.posix.openZ(fifo, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer std.posix.close(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = try runWithIo(testing.allocator, .{
        .claude_path = exe,
        .cwd = cwd,
        .session_start_timeout_ms = 3000,
        .idle_progress_timeout_ms = 3000,
    }, input, &out.writer);
    try testing.expectEqual(2, code);
    try tmp.dir.access("cancelled", .{});
    const sent = try tmp.dir.readFileAlloc(testing.allocator, "sent_ms", 32);
    defer testing.allocator.free(sent);
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next() orelse return error.MissingInit;
    const pong = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next() orelse return error.MissingPong, .{});
    defer pong.deinit();
    try testing.expectEqualStrings("pong", pong.value.object.get("type").?.string);
    const latency = pong.value.object.get("ts").?.integer - try std.fmt.parseInt(i64, sent, 10);
    try testing.expect(latency >= 0 and latency < 500);
    try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingInterrupt, "\"error\":\"interrupted\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingExit, "\"error\":\"child_exited\"") != null);
}

test "daemon startup EOF and invalid frames complete without waiting for SessionStart" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun("exec sleep 20", "\n\r\n   \t\r\n", &out.writer));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqual(0, try fixtureRun("exec sleep 20", "{", &out.writer));
    try testing.expectEqualStrings("{\"type\":\"error\",\"error\":\"invalid_json\"}\n", out.written());
}

test "daemon missing claude emits one session error with exit 2" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(2, try runWithIo(testing.allocator, .{ .claude_path = "/nonexistent/claude-p/claude" }, -1, &out.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("result", parsed.value.object.get("type").?.string);
    try testing.expectEqualStrings("error", parsed.value.object.get("subtype").?.string);
    try testing.expectEqualStrings("claude_not_found", parsed.value.object.get("error").?.string);
}

test "daemon sends ESC for permission and ignores abandoned Stop before next acknowledgment" {
    const script = fixture_ready ++
        \\printf '{"tool_name":"Bash"}' | "$relay" PermissionRequest
        \\[ "$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" = 27 ]
        \\# Ctrl-U, paste markers, four prompt bytes, Enter.
        \\dd bs=1 count=18 of=/dev/null 2>/dev/null
        \\printf '%s\n' '{"type":"assistant","message":{"content":"abandoned record"}}' >> "$file"
        \\printf '{"last_assistant_message":"abandoned"}' | "$relay" Stop
        \\sleep 0.25
        \\printf '{"session_id":"second"}' | "$relay" SessionStart
        \\printf '{"prompt":"next"}' | "$relay" UserPromptSubmit
        \\printf '{"last_assistant_message":"accepted"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input ++ "{\"type\":\"user\",\"content\":\"next\"}\n", &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    const denied = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer denied.deinit();
    const obj = denied.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("error_during_execution", obj.get("subtype").?.string);
    try testing.expectEqualStrings("permission_prompt_blocked", obj.get("error").?.string);
    try testing.expectEqualStrings("Bash", obj.get("message").?.string);
    const next = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer next.deinit();
    try testing.expectEqualStrings("accepted", next.value.object.get("result").?.string);
    try testing.expectEqualStrings("second", next.value.object.get("session_id").?.string);
    try testing.expect(lines.next() == null);
}

test "daemon waits for configured PermissionRequest and slow blocking Stop hooks" {
    const script = fixture_ready ++
        \\printf '{}' | "$relay" PermissionRequest
        \\printf '{"last_assistant_message":"draft"}' | "$relay" Stop
        \\sleep 0.5
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":true}' >> "$file"
        \\sleep 1.65
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}],"usage":{"output_tokens":3}}}' >> "$file"
        \\printf '{"last_assistant_message":"final"}' | "$relay" Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary"}' >> "$file"
        \\# A daemon still waiting on the fallback would consume this later failure.
        \\sleep 0.7
        \\printf '{"error":"late failure"}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRunWithOptions(script, fixture_input, &out.writer, .{ .extra_hooks = &.{
        .{ .event = "Stop", .command = "sleep 0.5" }, .{ .event = "PermissionRequest", .command = "true" },
    } }));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"final\"") != null);
}

test "daemon assistant continuation supersedes provisional Stop past the confirmation deadline" {
    const script = fixture_ready ++
        \\printf '{"last_assistant_message":"provisional"}' | "$relay" Stop
        \\sleep 0.04
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}' >> "$file"
        \\sleep 0.3
        \\printf '%s\n' '{"type":"assistant","message":{"content":"final","usage":{"output_tokens":9}}}' >> "$file"
        \\printf '{"last_assistant_message":"final","stop_hook_active":true}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"final\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "provisional") == null);
}

test "daemon confirms Stop after the current user and final assistant records flush late" {
    const script = fixture_ready ++
        \\printf '{"last_assistant_message":"PONG"}' | "$relay" Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"  test  "}]}}' >> "$file"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"}],"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"PONG\"") != null);
}

test "daemon StopFailure drains transcript before one error result and preserves usage" {
    const script = fixture_ready ++
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}],"usage":{"output_tokens":7}}}' >> "$file"
        \\printf '{"last_assistant_message":"quota reached","error":"generic"}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"assistant\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expect(obj.get("is_error").?.bool);
    try testing.expectEqualStrings("error_during_execution", obj.get("subtype").?.string);
    try testing.expectEqualStrings("stop_failure", obj.get("error").?.string);
    try testing.expectEqualStrings("quota reached", obj.get("result").?.string);
    try testing.expectEqual(7, obj.get("usage").?.object.get("output_tokens").?.integer);
    try testing.expect(lines.next() == null);
}

test "daemon StopFailure without hook text preserves transcript text" {
    const script = fixture_ready ++
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial answer"}]}}' >> "$file"
        \\printf '{}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"partial answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":\"stop_failure\"") != null);
}

test "daemon rejects queue overflow without completing a turn" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(2, try fixtureRun("sleep 0.2; exit 1", fixture_input ** (max_queued_prompts + 1), &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "{\"type\":\"error\",\"error\":\"queue_full\"}"));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
}

test "daemon write failure exit distinguishes closed reader from storage errors" {
    try testing.expectEqual(0, writeFailureExit(error.BrokenPipe));
    try testing.expectEqual(2, writeFailureExit(error.NoSpaceLeft));
    try testing.expectEqual(2, writeFailureExit(error.InputOutput));
    try testing.expectEqual(2, writeFailureExit(null));
}

test "daemon consumes an entry interrupt before a subsequent run" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    requestInterrupt();
    try testing.expectEqual(130, try runWithIo(testing.allocator, .{}, -1, &out.writer));
    try testing.expect(!driver_mod.isInterrupted());
    try testing.expectEqual(0, out.written().len);
}

test "daemon tails a new transcript from zero when a slash command was transformed" {
    const script = fixture_relay ++
        \\file="$PWD/transcript"
        \\printf '{"transcript_path":"%s"}' "$file" | "$relay" SessionStart
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"/cmd"}' | "$relay" UserPromptSubmit
        \\printf '%s\n' '{"type":"user","message":{"content":"expanded command"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"usage":{"output_tokens":7}}}' > "$file"
        \\printf '{"last_assistant_message":"done"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, "{\"type\":\"user\",\"content\":\"/cmd\"}\n", &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "expanded command") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"assistant\"") != null);
    const result = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, result, "\"output_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"result\":\"done\"") != null);
}

test "daemon growth watchdog observes resumed transcript before a boundary is known" {
    const script = fixture_relay ++
        \\file="$PWD/transcript"
        \\printf '{"transcript_path":"%s"}' "$file" | "$relay" SessionStart
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
        \\for i in 1 2 3 4 5; do
        \\    printf '%s\n' '{"type":"assistant","message":{"content":"private history"}}' >> "$file"
        \\    sleep 0.1
        \\done
        \\printf '{"last_assistant_message":"done"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRunWithOptions(script, fixture_input, &out.writer, .{
        .cont = true,
        .transcript_idle_timeout_ms = 300,
    }));
    try testing.expect(std.mem.indexOf(u8, out.written(), "private history") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"done\"") != null);
}

test "daemon recovers a matched turn on rotation or truncation and skips unmatched history" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(path);
    var transcript: TurnTranscript = .{ .initial_resume = true };
    defer transcript.deinit(a);
    try transcript.observePath(a, "{\"transcript_path\":\"/tmp/invalid\\u0000tail\"}");
    try testing.expect(transcript.path == null);
    transcript.path = try std.fs.path.join(a, &.{ path, "log" });
    transcript.begin(a, false);
    try testing.expect(transcript.initial_resume and transcript.start == null);

    const history = "{\"type\":\"assistant\",\"message\":{\"content\":\"old secret\"}}\n";
    const user = "{\"type\":\"user\",\"message\":{\"content\":\"active\"}}\n";
    const answer = "{\"type\":\"assistant\",\"message\":{\"content\":\"answer\"}}\n";
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // A late transcript with no matching user record may only supply Stop text.
    try tmp.dir.writeFile(.{ .sub_path = "log", .data = history });
    try emitTurnResult(a, &out.writer, &transcript, "active", "{\"last_assistant_message\":\"fallback\"}", false, monotonicNs(), "s");
    try testing.expect(std.mem.indexOf(u8, out.written(), "old secret") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"fallback\"") != null);
    try testing.expect(transcript.initial_resume);

    // Same path, new inode with a verified turn boundary.
    try tmp.dir.writeFile(.{ .sub_path = "replacement", .data = history ** 4 ++ user ++ answer });
    try tmp.dir.rename("replacement", "log");
    transcript.refresh(a, "active", true);
    try testing.expectEqual(@as(?u64, history.len * 4), transcript.start);
    try testing.expect(!transcript.initial_resume);
    _ = try pumpTranscript(&transcript.tailer.?, &out.writer);
    const inode = transcript.inode;

    // Same inode, shorter file. A fresh cursor must begin at the new user entry.
    try tmp.dir.writeFile(.{ .sub_path = "log", .data = history ++ user ++ answer });
    transcript.refresh(a, "active", true);
    try testing.expectEqual(inode, transcript.inode);
    try testing.expectEqual(@as(?u64, history.len), transcript.start);
    _ = try pumpTranscript(&transcript.tailer.?, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "old secret") == null);

    // An in-turn path change invalidates that cursor even for equal-sized files.
    try tmp.dir.writeFile(.{ .sub_path = "changed", .data = history });
    const payload = try std.fmt.allocPrint(a, "{{\"transcript_path\":\"{s}/changed\"}}", .{path});
    defer a.free(payload);
    try transcript.observePath(a, payload);
    transcript.refresh(a, "active", true);
    try testing.expect(transcript.start == null and transcript.tailer == null);
}
