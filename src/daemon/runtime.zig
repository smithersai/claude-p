//! Daemon event loop, FIFO hook dispatch, stdin reading, and turn watchdogs.
const std = @import("std");
const zmux = @import("zmux");
const driver_mod = @import("../driver.zig");
const emit_mod = @import("../emit.zig");
const hook_mod = @import("../hook.zig");
const protocol = @import("protocol.zig");
const turn = @import("turn.zig");
const queue_mod = @import("queue.zig");

const Options = protocol.Options;
const State = protocol.State;
const LineBuffer = protocol.LineBuffer;
const TurnTranscript = turn.TurnTranscript;
const PendingStop = turn.PendingStop;
const PendingPaste = turn.PendingPaste;

/// Emit a timestamped debug trace line for daemon mode.
pub const trace = queue_mod.trace;
/// Emit a formatted timestamped debug trace line for daemon mode.
pub const traceFmt = queue_mod.traceFmt;
/// Return true once the child process has exited or zmux reports termination.
pub const childExited = queue_mod.childExited;
/// Wait for PTY quiescence and an optional settle period while flushing DEC replies.
pub const settleBeforePrompt = queue_mod.settleBeforePrompt;

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

/// Stateful event loop managing a long-lived multi-turn daemon session.
pub const DaemonLoop = struct {
    allocator: std.mem.Allocator,
    opts: Options = .{},
    drv_opts: driver_mod.Options = .{ .prompt = "" },
    stdin_fd: std.posix.fd_t = -1,
    stdout: *std.Io.Writer,
    fifo_fd: std.posix.fd_t = -1,
    nonce: []const u8 = "0123456789abcdef",
    shared: *driver_mod.SharedState,
    session: *zmux.NativeSession = undefined,
    trace_start: i128 = 0,
    session_start_deadline_ns: i128 = 0,
    trace_interval: ?i128 = null,
    next_trace_ns: i128 = 0,
    last_trace_bytes: u64 = 0,
    state: State = .waiting_for_ready,
    transcript: TurnTranscript = .{ .initial_resume = false },
    pending_stop: ?PendingStop = null,
    fifo_buf: LineBuffer = .{},
    stdin_buf: LineBuffer = .{},
    queue: queue_mod.PromptQueue = .{},
    active_prompt: ?[]u8 = null,
    pending_paste: ?PendingPaste = null,
    typed_ns: i64 = 0,
    injections: u32 = 0,
    exit_seen_ns: ?i64 = null,
    session_id: ?[]u8 = null,
    last_transcript_advance_ns: i64 = 0,
    interrupt_deadline_ns: ?i128 = null,
    after_interrupt: bool = false,
    prompt_acked: bool = false,
    turn_start_ns: i128 = 0,
    stdin_eof: bool = false,

    /// Release all owned buffers, pending Stop state, and queued prompts.
    pub fn deinit(self: *DaemonLoop) void {
        self.transcript.deinit(self.allocator);
        turn.clearStop(self.allocator, &self.pending_stop);
        self.fifo_buf.bytes.deinit(self.allocator);
        self.stdin_buf.bytes.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        if (self.active_prompt) |p| self.allocator.free(p);
        if (self.session_id) |s| self.allocator.free(s);
    }

    /// Return the active Claude session ID, or `""` before `SessionStart`.
    pub fn sid(self: *const DaemonLoop) []const u8 {
        return self.session_id orelse "";
    }

    /// Elapsed milliseconds since turn start (when busy) or daemon start (when idle).
    pub fn currentAge(self: *const DaemonLoop, now_ns: i128) u64 {
        return protocol.elapsedMs(if (self.state == .busy) self.turn_start_ns else self.trace_start, now_ns);
    }

    /// Apply one nonce-verified hook event to the daemon state machine.
    pub fn handleHookEvent(self: *DaemonLoop, ev: hook_mod.HookLine) !?u8 {
        std.debug.assert(@intFromPtr(self.shared) != 0);
        if (self.opts.debug) std.debug.print("hook: {s}\n", .{@tagName(ev.event)});
        switch (ev.event) {
            .session_start => {
                trace(self.opts, self.trace_start, "SessionStart hook fired");
                try self.transcript.observePath(self.allocator, ev.payload);
                if (try hook_mod.extractSessionId(self.allocator, ev.payload)) |id| {
                    if (self.session_id) |old| self.allocator.free(old);
                    self.session_id = id;
                }
                if (self.state == .waiting_for_ready) {
                    self.shared.startup_done.store(true, .seq_cst);
                    try protocol.emitSystemInit(self.stdout, self.sid());
                    try self.stdout.flush();
                    self.state = .idle;
                }
            },
            .user_prompt_submit => {
                if (self.state != .busy or self.injections == 0) return null;
                if (try hook_mod.extractPrompt(self.allocator, ev.payload)) |received| {
                    defer self.allocator.free(received);
                    if (driver_mod.isPromptTruncated(self.active_prompt.?, received)) {
                        const dur = protocol.elapsedMs(self.turn_start_ns, monotonicNs());
                        try protocol.writeError(self.allocator, self.stdout, "prompt_truncated", self.sid(), dur);
                        return 2;
                    }
                }
                try self.transcript.observePath(self.allocator, ev.payload);
                self.prompt_acked = true;
                if (self.pending_paste) |paste| if (paste.is_reinject) {
                    try paste.cancel(self.session);
                    self.pending_paste = null;
                };
            },
            .permission_request => try self.handlePermissionRequest(ev.payload),
            .stop, .stop_failure => try self.handleStopHook(ev),
            .unknown => {},
        }
        return null;
    }

    fn handlePermissionRequest(self: *DaemonLoop, payload: []const u8) !void {
        std.debug.assert(@intFromPtr(self.session) != 0);
        const allow = self.state == .busy and self.injections > 0 and
            !driver_mod.hasExtraHook(self.opts.extra_hooks, "PermissionRequest");
        if (!allow) return;
        if (self.pending_paste) |paste| try paste.cancel(self.session);
        self.pending_paste = null;
        self.session.writeInput("\x1b") catch |err| {
            traceFmt(self.opts, self.trace_start, "ESC on permission_request failed: {s}", .{@errorName(err)});
        };
        const tool = hook_mod.extractPermissionTool(self.allocator, payload);
        defer if (tool) |name| self.allocator.free(name);
        const dur = protocol.elapsedMs(self.turn_start_ns, monotonicNs());
        try emit_mod.emitErrorResultDetail(
            self.stdout,
            "error_during_execution",
            "permission_prompt_blocked",
            self.sid(),
            dur,
            .{ .message = tool orelse "unknown tool" },
        );
        try self.stdout.flush();
        turn.clearStop(self.allocator, &self.pending_stop);
        self.interrupt_deadline_ns = null;
        self.after_interrupt = true;
        self.state = .idle;
    }

    fn handleStopHook(self: *DaemonLoop, ev: hook_mod.HookLine) !void {
        if (!protocol.stopBelongsToTurn(self.state, self.prompt_acked)) return;
        std.debug.assert(self.active_prompt != null);
        try self.transcript.observePath(self.allocator, ev.payload);
        self.transcript.refresh(self.allocator, self.active_prompt.?, true);
        turn.clearStop(self.allocator, &self.pending_stop);
        if (ev.event == .stop_failure) {
            try turn.emitTurnResult(
                self.allocator,
                self.stdout,
                &self.transcript,
                self.active_prompt.?,
                ev.payload,
                true,
                self.turn_start_ns,
                self.sid(),
            );
            self.interrupt_deadline_ns = null;
            self.after_interrupt = false;
            self.state = .idle;
            return;
        }
        self.pending_stop = .{
            .payload = try self.allocator.dupe(u8, ev.payload),
            .deadline = @as(i128, monotonicNs()) + driver_mod.stopConfirmationNs(self.opts.extra_hooks),
            .inode = self.transcript.inode,
            .scan_pos = self.transcript.size,
        };
    }

    fn drainFifo(self: *DaemonLoop, read_buf: *[4096]u8) !?u8 {
        std.debug.assert(self.nonce.len == hook_mod.nonce_len);
        while (true) {
            const n = std.posix.read(self.fifo_fd, read_buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };
            if (n == 0) break;
            var chunk: []const u8 = read_buf[0..n];
            while (try self.fifo_buf.next(self.allocator, &chunk, false)) |frame| {
                const line = switch (frame) {
                    .line => |line| line,
                    .oversized => {
                        try emit_mod.writeProtocolError(self.stdout, "fifo_line_too_large");
                        continue;
                    },
                };
                if (hook_mod.parseLineWithNonce(line, self.nonce)) |ev| {
                    if (try self.handleHookEvent(ev)) |code| return code;
                }
            }
        }
        return null;
    }

    fn updateBusyTranscript(self: *DaemonLoop, before_size: u64) !void {
        if (self.state != .busy) return;
        std.debug.assert(self.active_prompt != null);
        const can_recover = self.prompt_acked and !self.transcript.initial_resume;
        self.transcript.refresh(self.allocator, self.active_prompt.?, can_recover);
        if (self.transcript.size > before_size) self.last_transcript_advance_ns = monotonicNs();
        if (self.transcript.tailer) |*t| {
            const before = t.pos;
            _ = try turn.pumpTranscript(t, self.stdout);
            if (t.pos > before) self.last_transcript_advance_ns = monotonicNs();
        }
        if (self.pending_stop) |*stop| {
            const status = try stop.status(self.allocator, &self.transcript, self.active_prompt.?);
            if (status == .continued) {
                turn.clearStop(self.allocator, &self.pending_stop);
            } else if (status == .confirmed or monotonicNs() >= stop.deadline) {
                try turn.emitTurnResult(
                    self.allocator,
                    self.stdout,
                    &self.transcript,
                    self.active_prompt.?,
                    stop.payload,
                    false,
                    self.turn_start_ns,
                    self.sid(),
                );
                turn.clearStop(self.allocator, &self.pending_stop);
                self.interrupt_deadline_ns = null;
                self.after_interrupt = false;
                self.state = .idle;
            }
        }
    }

    fn drainStdin(self: *DaemonLoop, read_buf: *[4096]u8, age: u64) !void {
        if (self.stdin_eof or !protocol.fdReadable(self.stdin_fd)) return;
        std.debug.assert(read_buf.len > 0);
        const n = try std.posix.read(self.stdin_fd, read_buf);
        self.stdin_eof = n == 0;
        var chunk: []const u8 = read_buf[0..n];
        while (try self.stdin_buf.next(self.allocator, &chunk, self.stdin_eof)) |frame| {
            const line = switch (frame) {
                .line => |line| line,
                .oversized => {
                    try emit_mod.writeProtocolError(self.stdout, "stdin_line_too_large");
                    continue;
                },
            };
            switch (try protocol.readInputFrame(self.allocator, self.stdout, line) orelse continue) {
                .ping => {
                    try protocol.emitPong(self.stdout);
                    try self.stdout.flush();
                },
                .interrupt => try self.handleInterruptFrame(age),
                .user => |content| _ = try self.queue.push(self.allocator, self.stdout, content),
            }
        }
    }

    fn handleInterruptFrame(self: *DaemonLoop, age: u64) !void {
        if (self.state != .busy or self.interrupt_deadline_ns != null) return;
        std.debug.assert(self.active_prompt != null);
        if (self.pending_paste) |paste| {
            try paste.cancel(self.session);
            self.pending_paste = null;
            if (!paste.is_reinject) {
                try emit_mod.emitErrorResult(
                    self.allocator,
                    self.stdout,
                    "interrupted",
                    "interrupted",
                    self.sid(),
                    age,
                );
                try self.stdout.flush();
                self.after_interrupt = true;
                self.state = .idle;
                return;
            }
        }
        self.session.writeInput("\x1b") catch |err| {
            traceFmt(self.opts, self.trace_start, "ESC on interrupt failed: {s}", .{@errorName(err)});
        };
        self.interrupt_deadline_ns = @as(i128, monotonicNs()) + protocol.interrupt_window_ms * std.time.ns_per_ms;
    }

    fn checkExitAndTimeouts(self: *DaemonLoop, now_ns: i128, age: u64) !?u8 {
        std.debug.assert(now_ns >= self.trace_start);
        if (self.stdin_eof and self.state != .busy and self.queue.isEmpty()) return 0;
        if (childExited(self.shared, self.session)) {
            if (self.exit_seen_ns == null) self.exit_seen_ns = @intCast(now_ns);
            const grace = self.pending_stop != null or
                protocol.elapsedMs(self.exit_seen_ns.?, now_ns) < driver_mod.post_exit_fifo_grace_ms;
            if (self.state == .busy and grace) return null;
            driver_mod.reportFailure(
                self.shared,
                self.shared.debug_screen,
                "claude exited while {s}",
                .{@tagName(self.state)},
            );
            try protocol.writeError(self.allocator, self.stdout, "child_exited", self.sid(), age);
            return 2;
        }
        const last_out = self.shared.last_output_ns.load(.seq_cst);
        if (self.trace_interval) |interval| if (now_ns >= self.next_trace_ns) {
            const bytes = self.shared.bytes_seen.load(.seq_cst);
            const pos = if (self.transcript.tailer) |t| t.pos else 0;
            const byte_age: i64 = if (last_out == 0) -1 else @intCast(protocol.elapsedMs(last_out, now_ns));
            const turn_age = if (self.state == .busy) age else 0;
            std.debug.print(
                "[pty-trace] state={s} pty_bytes={d} pty_delta={d} last_byte_age_ms={d} " ++
                    "turn_age_ms={d} transcript_pos={d}\n",
                .{ @tagName(self.state), bytes, bytes - self.last_trace_bytes, byte_age, turn_age, pos },
            );
            self.last_trace_bytes = bytes;
            self.next_trace_ns = now_ns + interval;
        };
        if (self.opts.session_start_timeout_ms != 0 and self.state == .waiting_for_ready and
            now_ns > self.session_start_deadline_ns)
        {
            driver_mod.reportFailure(self.shared, self.shared.debug_screen, "timed out waiting for SessionStart", .{});
            try protocol.writeError(self.allocator, self.stdout, "session_start_timeout", self.sid(), age);
            return 124;
        }
        if (self.pending_paste == null and self.pending_stop == null) {
            if (protocol.idleTimedOut(self.state, last_out, now_ns, self.opts.idle_progress_timeout_ms)) {
                try protocol.writeError(self.allocator, self.stdout, "idle_timeout", self.sid(), age);
                return 124;
            }
            const stalled = protocol.transcriptStalled(
                self.state,
                self.last_transcript_advance_ns,
                now_ns,
                self.opts.transcript_idle_timeout_ms,
            );
            if (stalled) {
                try protocol.writeError(self.allocator, self.stdout, "transcript_stalled", self.sid(), age);
                return 124;
            }
        }
        return null;
    }

    fn checkInterruptAndWatchdog(self: *DaemonLoop, now_ns: i128, age: u64) !void {
        if (self.state != .busy) return;
        std.debug.assert(self.active_prompt != null);
        if (self.interrupt_deadline_ns) |deadline| {
            const window_now: i128 = monotonicNs();
            if (self.pending_stop == null and window_now >= deadline) {
                const dur = protocol.elapsedMs(self.turn_start_ns, window_now);
                try emit_mod.emitErrorResult(
                    self.allocator,
                    self.stdout,
                    "interrupted",
                    "interrupted",
                    self.sid(),
                    dur,
                );
                try self.stdout.flush();
                turn.clearStop(self.allocator, &self.pending_stop);
                self.interrupt_deadline_ns = null;
                self.after_interrupt = true;
                self.state = .idle;
            }
            return;
        }
        if (self.pending_paste != null) return;
        const advanced = if (self.transcript.tailer) |t| t.pos > self.transcript.start.? else false;
        const accepted = self.prompt_acked or (!self.after_interrupt and advanced);
        const since_typed: i64 = @intCast(protocol.elapsedMs(self.typed_ns, now_ns));
        switch (driver_mod.promptWatchdogAction(accepted, self.injections, since_typed)) {
            .wait => {},
            .reinject => {
                self.session.writeInput("\x15") catch |err| {
                    traceFmt(self.opts, self.trace_start, "Ctrl-U before reinject failed: {s}", .{@errorName(err)});
                };
                settleBeforePrompt(self.shared, self.session, 0, 0, driver_mod.ink_enter_debounce_ms);
                settleBeforePrompt(
                    self.shared,
                    self.session,
                    driver_mod.ink_quiescence_ms,
                    driver_mod.ink_max_wait_ms,
                    0,
                );
                if (driver_mod.isInterrupted() or childExited(self.shared, self.session)) return;
                self.pending_paste = .init(self.active_prompt.?, true);
            },
            .give_up => {
                try protocol.writeError(self.allocator, self.stdout, "prompt_not_accepted", self.sid(), age);
                self.session.writeInput("\x15") catch |err| {
                    traceFmt(self.opts, self.trace_start, "Ctrl-U before reinject failed: {s}", .{@errorName(err)});
                };
                self.after_interrupt = true;
                self.state = .idle;
            },
        }
    }

    fn dispatchNextPrompt(self: *DaemonLoop) void {
        if (self.state != .idle) return;
        if (self.active_prompt) |old| self.allocator.free(old);
        self.active_prompt = null;
        if (childExited(self.shared, self.session) or self.queue.isEmpty()) return;
        if (self.transcript.initial_resume) {
            settleBeforePrompt(
                self.shared,
                self.session,
                driver_mod.resume_quiescence_ms,
                driver_mod.resume_max_wait_ms,
                0,
            );
        } else {
            settleBeforePrompt(
                self.shared,
                self.session,
                driver_mod.ink_quiescence_ms,
                driver_mod.ink_max_wait_ms,
                driver_mod.prompt_settle_ms,
            );
        }
        if (driver_mod.isInterrupted() or childExited(self.shared, self.session)) return;
        const content = self.queue.pop() orelse return;
        self.active_prompt = content;
        if (self.after_interrupt) self.session.writeInput("\x15") catch |err| {
            traceFmt(self.opts, self.trace_start, "Ctrl-U after interrupt failed: {s}", .{@errorName(err)});
        };
        self.transcript.begin(self.allocator, self.after_interrupt);
        self.turn_start_ns = monotonicNs();
        self.pending_paste = .init(content, false);
        self.injections = 0;
        self.prompt_acked = false;
        self.interrupt_deadline_ns = null;
        self.state = .busy;
    }

    fn stepPendingPaste(self: *DaemonLoop) void {
        if (self.pending_paste) |*paste| {
            std.debug.assert(self.state == .busy);
            const finished = paste.advance(self.session) catch |err| failed: {
                traceFmt(self.opts, self.trace_start, "prompt write failed: {s}", .{@errorName(err)});
                paste.cancel(self.session) catch |cancel_err| {
                    traceFmt(self.opts, self.trace_start, "paste cancel failed: {s}", .{@errorName(cancel_err)});
                };
                break :failed true;
            };
            if (finished) {
                self.typed_ns = monotonicNs();
                if (!paste.is_reinject) {
                    self.shared.last_output_ns.store(self.typed_ns, .seq_cst);
                    self.last_transcript_advance_ns = self.typed_ns;
                }
                self.injections += 1;
                self.pending_paste = null;
            }
        }
    }

    /// Run the daemon event loop until stdin EOF, child exit, timeout, or interrupt.
    pub fn runLoop(self: *DaemonLoop) !u8 {
        std.debug.assert(self.state == .waiting_for_ready);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            if (driver_mod.isInterrupted()) {
                driver_mod.clearInterrupt();
                return 130;
            }
            driver_mod.flushPendingToPty(self.shared, self.session);
            if (self.state == .waiting_for_ready) {
                driver_mod.maybeHandleStartupDialogs(self.drv_opts, self.trace_start, self.shared, self.session);
                if (self.shared.dialog.refused != .none) {
                    const dur = protocol.elapsedMs(self.trace_start, monotonicNs());
                    try protocol.writeError(self.allocator, self.stdout, "unexpected_startup_dialog", self.sid(), dur);
                    return 2;
                }
            }
            const before_size = self.transcript.size;
            if (try self.drainFifo(&read_buf)) |code| return code;
            try self.updateBusyTranscript(before_size);
            const now_ns: i128 = monotonicNs();
            const age = self.currentAge(now_ns);
            try self.drainStdin(&read_buf, age);
            if (try self.checkExitAndTimeouts(now_ns, age)) |code| return code;
            if (childExited(self.shared, self.session)) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            try self.checkInterruptAndWatchdog(now_ns, age);
            self.dispatchNextPrompt();
            self.stepPendingPaste();
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
};

// -------- tests --------
const testing = std.testing;

test "DaemonLoop.sid: returns empty string when unset and owned id when set" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh };
    defer loop.deinit();
    try testing.expectEqualStrings("", loop.sid());
    loop.session_id = try testing.allocator.dupe(u8, "s-1");
    try testing.expectEqualStrings("s-1", loop.sid());
}

test "DaemonLoop.currentAge: uses trace_start when idle and turn_start when busy" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .trace_start = 100 * std.time.ns_per_ms,
        .turn_start_ns = 250 * std.time.ns_per_ms,
    };
    defer loop.deinit();
    try testing.expectEqual(@as(u64, 200), loop.currentAge(300 * std.time.ns_per_ms));
    loop.state = .busy;
    try testing.expectEqual(@as(u64, 50), loop.currentAge(300 * std.time.ns_per_ms));
}

test "DaemonLoop.handleHookEvent: SessionStart transitions waiting_for_ready to idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh };
    defer loop.deinit();
    try testing.expectEqual(@as(?u8, null), try loop.handleHookEvent(.{ .event = .session_start, .payload = "{\"session_id\":\"abc\"}" }));
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqualStrings("abc", loop.sid());
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"subtype\":\"init\"") != null);
}

test "DaemonLoop.handleHookEvent: duplicate SessionStart updates session_id only" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .session_start, .payload = "{\"session_id\":\"s2\"}" });
    try testing.expectEqualStrings("s2", loop.sid());
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "DaemonLoop.handleHookEvent: UserPromptSubmit ignored while idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .user_prompt_submit, .payload = "{\"prompt\":\"hi\"}" });
    try testing.expect(!loop.prompt_acked);
}

test "DaemonLoop.handleHookEvent: UserPromptSubmit sets prompt_acked when busy" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .injections = 1,
        .active_prompt = try testing.allocator.dupe(u8, "hello"),
    };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .user_prompt_submit, .payload = "{\"prompt\":\"hello\"}" });
    try testing.expect(loop.prompt_acked);
}

test "DaemonLoop.handleHookEvent: UserPromptSubmit rejects truncated prompt" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .injections = 1,
        .active_prompt = try testing.allocator.dupe(u8, "a" ** 100),
    };
    defer loop.deinit();
    try testing.expectEqual(@as(?u8, 2), try loop.handleHookEvent(.{ .event = .user_prompt_submit, .payload = "{\"prompt\":\"aaa\"}" }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "prompt_truncated") != null);
}

test "DaemonLoop.handleHookEvent: Stop ignored until prompt_acked" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .active_prompt = try testing.allocator.dupe(u8, "hi"),
    };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .stop, .payload = "{\"last_assistant_message\":\"old\"}" });
    try testing.expect(loop.pending_stop == null);
}

test "DaemonLoop.handleHookEvent: Stop records pending_stop once prompt_acked" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .prompt_acked = true,
        .active_prompt = try testing.allocator.dupe(u8, "hi"),
    };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .stop, .payload = "{\"last_assistant_message\":\"ok\"}" });
    try testing.expect(loop.pending_stop != null);
}

test "DaemonLoop.handleHookEvent: StopFailure emits error result and returns to idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .prompt_acked = true,
        .active_prompt = try testing.allocator.dupe(u8, "hi"),
    };
    defer loop.deinit();
    _ = try loop.handleHookEvent(.{ .event = .stop_failure, .payload = "{\"error\":\"boom\"}" });
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "stop_failure") != null);
}

test "DaemonLoop.handleHookEvent: unknown event is a no-op" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh };
    defer loop.deinit();
    try testing.expectEqual(@as(?u8, null), try loop.handleHookEvent(.{ .event = .unknown, .payload = "{}" }));
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "DaemonLoop: stdin_eof while idle with empty queue exits 0" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle, .stdin_eof = true };
    defer loop.deinit();
    try testing.expectEqual(@as(?u8, 0), try loop.checkExitAndTimeouts(10, 10));
}

test "DaemonLoop: expired interrupt window reports interrupted and returns to idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .active_prompt = try testing.allocator.dupe(u8, "hi"),
        .interrupt_deadline_ns = 0,
    };
    defer loop.deinit();
    try loop.checkInterruptAndWatchdog(100, 100);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.after_interrupt);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"subtype\":\"interrupted\"") != null);
}

test "DaemonLoop: updateBusyTranscript emits confirmed pending stop" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{
        .allocator = testing.allocator,
        .stdout = &aw.writer,
        .shared = &sh,
        .state = .busy,
        .active_prompt = try testing.allocator.dupe(u8, "hi"),
        .pending_stop = .{
            .payload = try testing.allocator.dupe(u8, "{\"last_assistant_message\":\"done\"}"),
            .deadline = 0,
            .inode = null,
            .scan_pos = 0,
        },
    };
    defer loop.deinit();
    try loop.updateBusyTranscript(0);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"result\":\"done\"") != null);
}

test "DaemonLoop: updateBusyTranscript is a no-op while idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    try loop.updateBusyTranscript(0);
    try testing.expectEqual(State.idle, loop.state);
}

test "DaemonLoop: drainStdin handles ping frame over pipe" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "{\"type\":\"ping\"}\n");
    std.posix.close(p[1]);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdin_fd = p[0], .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    var rbuf: [4096]u8 = undefined;
    try loop.drainStdin(&rbuf, 0);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"type\":\"pong\"") != null);
}

test "DaemonLoop: drainStdin enqueues user frame over pipe" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "{\"type\":\"user\",\"content\":\"hello\"}\n");
    std.posix.close(p[1]);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdin_fd = p[0], .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    var rbuf: [4096]u8 = undefined;
    try loop.drainStdin(&rbuf, 0);
    try testing.expectEqual(@as(usize, 1), loop.queue.len());
}

test "DaemonLoop: drainFifo parses nonced SessionStart from pipe" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    _ = try std.posix.write(fds[1], "0123456789abcdef\tSessionStart\t{\"session_id\":\"s9\"}\n");
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .fifo_fd = fds[0], .shared = &sh };
    defer loop.deinit();
    var rbuf: [4096]u8 = undefined;
    _ = try loop.drainFifo(&rbuf);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqualStrings("s9", loop.sid());
}

test "DaemonLoop: handleInterruptFrame ignored while idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    try loop.handleInterruptFrame(10);
    try testing.expect(loop.interrupt_deadline_ns == null);
}

test "DaemonLoop: checkExitAndTimeouts returns 2 on child exit while idle" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var sh: driver_mod.SharedState = .{ .session = undefined, .debug = false };
    sh.exited.store(true, .seq_cst);
    var loop: DaemonLoop = .{ .allocator = testing.allocator, .stdout = &aw.writer, .shared = &sh, .state = .idle };
    defer loop.deinit();
    try testing.expectEqual(@as(?u8, 2), try loop.checkExitAndTimeouts(100, 100));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "child_exited") != null);
}
