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
const emit_mod = @import("emit.zig");
/// NDJSON input framing, watchdog predicates, and wire emitters.
pub const protocol = @import("daemon/protocol.zig");
/// Per-turn transcript cursor, pending Stop confirmation, and paste state.
pub const turn = @import("daemon/turn.zig");

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
    /// Wall-time cap for the *initial* SessionStart wait.
    session_start_timeout_ms: u64 = 300_000,
    /// While busy, kill the session if no PTY output is observed for this long.
    idle_progress_timeout_ms: u64 = 180_000,
    /// While busy, kill the session if the transcript stops growing for this long.
    transcript_idle_timeout_ms: u64 = 600_000,
    /// Extra hooks merged into the generated settings (see `hook.zig`).
    extra_hooks: []const hook_mod.ExtraHook = &.{},
    /// Extra settings JSON object merged into the generated settings.
    extra_settings_json: ?[]const u8 = null,
};

/// Error set returned by persistent daemon initialization and I/O failures.
pub const RunError = error{
    InvalidExtraSettings,
    InvalidOptions,
    IoFailure,
} || std.mem.Allocator.Error;

/// Lifecycle state of the persistent multi-turn daemon.
pub const State = protocol.State;
/// How long to wait for a Stop hook after sending ESC for an interrupt frame.
pub const interrupt_window_ms = protocol.interrupt_window_ms;
/// Decide whether a busy turn has stalled due to no PTY output.
pub const idleTimedOut = protocol.idleTimedOut;
/// Decide whether a busy turn has stalled because the transcript stopped growing.
pub const transcriptStalled = protocol.transcriptStalled;
/// Decide whether a Stop hook arriving while busy belongs to the active turn.
pub const stopBelongsToTurn = protocol.stopBelongsToTurn;
/// Signal the running daemon session to interrupt cleanly.
pub const requestInterrupt = driver_mod.requestInterrupt;
/// Milliseconds from `start_ns` to `now_ns`, clamped at 0 and saturated at `maxInt(u64)`.
pub const elapsedMs = protocol.elapsedMs;
/// Extract the user-message content from a hub-style stdin frame.
pub const parseUserMessageContent = protocol.parseUserMessageContent;
/// Parse one stdin line, emitting a protocol error frame on invalid input.
pub const readInputFrame = protocol.readInputFrame;
/// True if `line` is a `{"type":"ping"}` health-probe frame.
pub const isPingFrame = protocol.isPingFrame;
/// True if `line` is a `{"type":"interrupt"}` frame.
pub const isInterruptFrame = protocol.isInterruptFrame;
/// Read the byte range `[start_pos..end_pos)` from a file via `pread`.
pub const readFileRange = turn.readFileRange;
/// Emit a minimal `system:init` envelope once `SessionStart` fires.
pub const emitSystemInit = protocol.emitSystemInit;
/// Emit a `{"type":"pong","ts":<unix_ms>}` health-probe reply.
pub const emitPong = protocol.emitPong;
/// Compute the periodic PTY diagnostic trace interval in nanoseconds, or null when disabled.
pub const ptyTraceInterval = protocol.ptyTraceInterval;

const interrupted = driver_mod.isInterrupted;
const LineBuffer = protocol.LineBuffer;
const TurnTranscript = turn.TurnTranscript;
const PendingStop = turn.PendingStop;
const PendingPaste = turn.PendingPaste;
const writeFailureExit = protocol.writeFailureExit;
const emitTurnResult = turn.emitTurnResult;
const pumpTranscript = turn.pumpTranscript;
const max_queued_prompts = 64;
const max_queued_bytes = 64 * 1024 * 1024;

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

/// Translate daemon Options to a `driver.Options` (which `buildArgv` takes).
pub fn toDriverOptions(opts: Options) driver_mod.Options {
    std.debug.assert(opts.cols > 0 and opts.rows > 0);
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
    const elapsed_ms: i64 = @intCast(@divTrunc(@as(i128, monotonicNs()) - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const elapsed_ms: i64 = @intCast(@divTrunc(@as(i128, monotonicNs()) - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn childExited(shared: *driver_mod.SharedState, session: *zmux.NativeSession) bool {
    return shared.exited.load(.seq_cst) or session.state() == .terminated;
}

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

const DaemonLoop = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    drv_opts: driver_mod.Options,
    stdin_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
    fifo_fd: std.posix.fd_t,
    nonce: []const u8,
    shared: *driver_mod.SharedState,
    session: *zmux.NativeSession,
    trace_start: i128,
    session_start_deadline_ns: i128,
    trace_interval: ?i128,
    next_trace_ns: i128,
    last_trace_bytes: u64 = 0,
    state: State = .waiting_for_ready,
    transcript: TurnTranscript,
    pending_stop: ?PendingStop = null,
    fifo_buf: LineBuffer = .{},
    stdin_buf: LineBuffer = .{},
    prompt_queue: std.ArrayList([]u8) = .{},
    prompt_queue_head: usize = 0,
    active_prompt: ?[]u8 = null,
    pending_paste: ?PendingPaste = null,
    typed_ns: i64 = 0,
    injections: u32 = 0,
    exit_seen_ns: ?i64 = null,
    queued_bytes: usize = 0,
    session_id: ?[]u8 = null,
    last_transcript_advance_ns: i64 = 0,
    interrupt_deadline_ns: ?i128 = null,
    after_interrupt: bool = false,
    prompt_acked: bool = false,
    turn_start_ns: i128 = 0,
    stdin_eof: bool = false,

    fn deinit(self: *DaemonLoop) void {
        self.transcript.deinit(self.allocator);
        turn.clearStop(self.allocator, &self.pending_stop);
        self.fifo_buf.bytes.deinit(self.allocator);
        self.stdin_buf.bytes.deinit(self.allocator);
        for (self.prompt_queue.items[self.prompt_queue_head..]) |p| self.allocator.free(p);
        self.prompt_queue.deinit(self.allocator);
        if (self.active_prompt) |p| self.allocator.free(p);
        if (self.session_id) |s| self.allocator.free(s);
    }

    fn sid(self: *const DaemonLoop) []const u8 {
        return self.session_id orelse "";
    }

    fn currentAge(self: *const DaemonLoop, now_ns: i128) u64 {
        return elapsedMs(if (self.state == .busy) self.turn_start_ns else self.trace_start, now_ns);
    }

    fn handleHookEvent(self: *DaemonLoop, ev: hook_mod.HookLine) !?u8 {
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
                    try emitSystemInit(self.stdout, self.sid());
                    try self.stdout.flush();
                    self.state = .idle;
                    trace(self.opts, self.trace_start, "daemon ready for prompts");
                }
            },
            .user_prompt_submit => {
                if (self.state != .busy or self.injections == 0) return null;
                if (try hook_mod.extractPrompt(self.allocator, ev.payload)) |received| {
                    defer self.allocator.free(received);
                    if (driver_mod.isPromptTruncated(self.active_prompt.?, received)) {
                        const dur = elapsedMs(self.turn_start_ns, monotonicNs());
                        try protocol.writeError(self.allocator, self.stdout, "prompt_truncated", self.sid(), dur);
                        return 2;
                    }
                }
                try self.transcript.observePath(self.allocator, ev.payload);
                self.prompt_acked = true;
                if (self.pending_paste) |paste| {
                    if (paste.is_reinject) {
                        try paste.cancel(self.session);
                        self.pending_paste = null;
                    }
                }
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
        const dur = elapsedMs(self.turn_start_ns, monotonicNs());
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
        if (!stopBelongsToTurn(self.state, self.prompt_acked)) return;
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
            switch (try readInputFrame(self.allocator, self.stdout, line) orelse continue) {
                .ping => {
                    try emitPong(self.stdout);
                    try self.stdout.flush();
                },
                .interrupt => try self.handleInterruptFrame(age),
                .user => |content| try self.enqueuePrompt(content),
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
        self.interrupt_deadline_ns = @as(i128, monotonicNs()) + interrupt_window_ms * std.time.ns_per_ms;
    }

    fn enqueuePrompt(self: *DaemonLoop, content: []u8) !void {
        std.debug.assert(content.len > 0);
        const queued = self.prompt_queue.items.len - self.prompt_queue_head;
        if (queued >= max_queued_prompts or content.len > max_queued_bytes - self.queued_bytes) {
            self.allocator.free(content);
            try emit_mod.writeProtocolError(self.stdout, "queue_full");
            return;
        }
        errdefer self.allocator.free(content);
        try self.prompt_queue.append(self.allocator, content);
        self.queued_bytes += content.len;
    }

    fn checkExitAndTimeouts(self: *DaemonLoop, now_ns: i128, age: u64) !?u8 {
        std.debug.assert(now_ns >= self.trace_start);
        if (self.stdin_eof and self.state != .busy and self.prompt_queue_head == self.prompt_queue.items.len) return 0;
        if (childExited(self.shared, self.session)) {
            if (self.exit_seen_ns == null) self.exit_seen_ns = @intCast(now_ns);
            const grace = self.pending_stop != null or
                elapsedMs(self.exit_seen_ns.?, now_ns) < driver_mod.post_exit_fifo_grace_ms;
            if (self.state == .busy and grace) return null;
            traceFmt(self.opts, self.trace_start, "child exited while {s}", .{@tagName(self.state)});
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
            const byte_age: i64 = if (last_out == 0) -1 else @intCast(elapsedMs(last_out, now_ns));
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
            if (idleTimedOut(self.state, last_out, now_ns, self.opts.idle_progress_timeout_ms)) {
                try protocol.writeError(self.allocator, self.stdout, "idle_timeout", self.sid(), age);
                return 124;
            }
            const stalled = transcriptStalled(
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
                trace(self.opts, self.trace_start, "interrupt window elapsed without Stop; reporting interrupted");
                const dur = elapsedMs(self.turn_start_ns, window_now);
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
        const since_typed: i64 = @intCast(elapsedMs(self.typed_ns, now_ns));
        switch (driver_mod.promptWatchdogAction(accepted, self.injections, since_typed)) {
            .wait => {},
            .reinject => {
                traceFmt(
                    self.opts,
                    self.trace_start,
                    "retrying prompt after {d} unacknowledged injections",
                    .{self.injections},
                );
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
                if (interrupted() or childExited(self.shared, self.session)) return;
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
        if (childExited(self.shared, self.session)) return;
        if (self.prompt_queue_head >= self.prompt_queue.items.len) return;
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
        if (interrupted() or childExited(self.shared, self.session)) return;
        std.debug.assert(self.prompt_queue_head < self.prompt_queue.items.len);
        const content = self.prompt_queue.items[self.prompt_queue_head];
        self.prompt_queue_head += 1;
        self.queued_bytes -= content.len;
        self.active_prompt = content;
        if (self.prompt_queue_head == self.prompt_queue.items.len) {
            self.prompt_queue.clearRetainingCapacity();
            self.prompt_queue_head = 0;
        } else if (self.prompt_queue_head >= 64 and self.prompt_queue_head >= self.prompt_queue.items.len / 2) {
            const pending = self.prompt_queue.items[self.prompt_queue_head..];
            std.mem.copyForwards([]u8, self.prompt_queue.items, pending);
            self.prompt_queue.shrinkRetainingCapacity(pending.len);
            self.prompt_queue_head = 0;
        }
        if (self.after_interrupt) self.session.writeInput("\x15") catch |err| {
            traceFmt(self.opts, self.trace_start, "Ctrl-U after interrupt failed: {s}", .{@errorName(err)});
        };
        self.transcript.begin(self.allocator, self.after_interrupt);
        traceFmt(self.opts, self.trace_start, "sending prompt ({d} bytes, transcript offset {?d})", .{
            content.len,
            self.transcript.start,
        });
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

    fn runLoop(self: *DaemonLoop) !u8 {
        std.debug.assert(self.state == .waiting_for_ready);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            if (interrupted()) {
                driver_mod.clearInterrupt();
                return 130;
            }
            driver_mod.flushPendingToPty(self.shared, self.session);
            if (self.state == .waiting_for_ready) {
                driver_mod.maybeHandleStartupDialogs(self.drv_opts, self.trace_start, self.shared, self.session);
                if (self.shared.dialog.refused != .none) {
                    const dur = elapsedMs(self.trace_start, monotonicNs());
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

/// Daemon entry. Runs until stdin EOF or until the child `claude` exits.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!u8 {
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    return runWithIo(allocator, opts, std.posix.STDIN_FILENO, &stdout_writer.interface) catch |e| switch (e) {
        error.WriteFailed => protocol.writeFailureExit(stdout_writer.err),
        error.OutOfMemory, error.InvalidExtraSettings, error.InvalidOptions => |err| return err,
        else => return error.IoFailure,
    };
}

fn prepareSpawnCommand(
    allocator: std.mem.Allocator,
    opts: Options,
    drv_opts: driver_mod.Options,
    settings_json: []const u8,
    stdout: *std.Io.Writer,
) !union(enum) { cmd: []u8, exit_code: u8 } {
    const claude_bin = driver_mod.resolveClaudeBinary(allocator, opts.claude_path) catch |err| switch (err) {
        error.ClaudeNotFound => {
            const code = try protocol.startupFailure(stdout, "claude_not_found", "resolve_claude");
            return .{ .exit_code = code };
        },
        error.OutOfMemory => return err,
    };
    defer allocator.free(claude_bin);
    var argv = try driver_mod.buildArgv(allocator, claude_bin, settings_json, drv_opts);
    defer argv.deinit(allocator);
    const shell_cmd = driver_mod.buildShellCommandInDir(allocator, argv.items, opts.cwd) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .exit_code = try protocol.startupFailure(stdout, "spawn_failed", "shell_command") },
    };
    return .{ .cmd = shell_cmd };
}

fn runWithIo(
    backing_allocator: std.mem.Allocator,
    opts: Options,
    stdin_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
) !u8 {
    const scope = driver_mod.InterruptScope.enter();
    defer scope.exit();
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
        else => return protocol.startupFailure(stdout, "spawn_failed", "cwd"),
    };
    const trace_start: i128 = monotonicNs();
    trace(opts, trace_start, "daemon.run() entered");

    var harness = hook_mod.createWithOptions(allocator, .{
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
    }) catch |e| switch (e) {
        error.InvalidExtraSettings => {
            _ = try protocol.startupFailure(stdout, "spawn_failed", "hook_settings");
            return error.InvalidExtraSettings;
        },
        error.OutOfMemory => return e,
        else => return protocol.startupFailure(stdout, "spawn_failed", "hook_harness"),
    };
    defer harness.deinit();

    const shell_cmd = switch (try prepareSpawnCommand(allocator, opts, drv_opts, harness.settings_json, stdout)) {
        .cmd => |cmd| cmd,
        .exit_code => |code| return code,
    };
    defer allocator.free(shell_cmd);

    var env_list = driver_mod.buildChildEnv(allocator, harness.fifo_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return protocol.startupFailure(stdout, "spawn_failed", "environment"),
    };
    defer driver_mod.freeChildEnv(allocator, &env_list);

    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(
        fifo_z,
        .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true },
        0,
    ) catch return protocol.startupFailure(stdout, "spawn_failed", "fifo_open");
    defer std.posix.close(fifo_fd);

    return runSessionLoop(
        allocator,
        opts,
        drv_opts,
        stdin_fd,
        stdout,
        fifo_fd,
        &harness.nonce,
        shell_cmd,
        env_list.items,
        trace_start,
    );
}

fn runSessionLoop(
    allocator: std.mem.Allocator,
    opts: Options,
    drv_opts: driver_mod.Options,
    stdin_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
    fifo_fd: std.posix.fd_t,
    nonce: []const u8,
    shell_cmd: []const u8,
    env_items: []const []const u8,
    trace_start: i128,
) !u8 {
    std.debug.assert(nonce.len == hook_mod.nonce_len);
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
    const sink: zmux.native.EventSink = .{ .context = @ptrCast(&shared), .emit = driver_mod.onZmuxEvent };
    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p-daemon",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = opts.cwd,
        .env = env_items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return protocol.startupFailure(stdout, "spawn_failed", "pty_spawn");
    shared.session = session;
    defer session.destroy();
    trace(opts, trace_start, "zmux session spawned; Ink booting");

    const start_deadline = trace_start +
        @as(i128, @intCast(opts.session_start_timeout_ms)) * std.time.ns_per_ms;
    const interval = ptyTraceInterval(opts.debug, std.posix.getenv("CLAUDE_P_PTY_TRACE"));
    var loop: DaemonLoop = .{
        .allocator = allocator,
        .opts = opts,
        .drv_opts = drv_opts,
        .stdin_fd = stdin_fd,
        .stdout = stdout,
        .fifo_fd = fifo_fd,
        .nonce = nonce,
        .shared = &shared,
        .session = session,
        .trace_start = trace_start,
        .session_start_deadline_ns = start_deadline,
        .trace_interval = interval,
        .next_trace_ns = trace_start + (interval orelse 0),
        .transcript = .{ .initial_resume = driver_mod.isResumeRun(drv_opts) },
    };
    defer loop.deinit();
    return loop.runLoop();
}

// -------- tests --------
const testing = std.testing;

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

test "daemon re-exports protocol and turn helpers cleanly" {
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(isInterruptFrame(testing.allocator, "{\"type\":\"interrupt\"}"));
    try testing.expect(stopBelongsToTurn(.busy, true));
    try testing.expectEqual(@as(u64, 0), elapsedMs(10, 5));
}

test "daemon write failure exit helper maps BrokenPipe to 0" {
    try testing.expectEqual(@as(u8, 0), protocol.writeFailureExit(error.BrokenPipe));
    try testing.expectEqual(@as(u8, 2), protocol.writeFailureExit(error.NoSpaceLeft));
}

const fixture_relay =
    "stty raw -echo\n" ++
    "[ \"$1\" = --settings ]\n" ++
    "relay=$(python3 -c 'import json,shlex,sys; " ++
    "print(shlex.split(json.loads(sys.argv[1])[\"hooks\"][\"Stop\"][0][\"hooks\"][0][\"command\"])[0])' \"$2\")\n";

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
    opts.session_start_timeout_ms = 10_000;
    opts.idle_progress_timeout_ms = 10_000;
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
