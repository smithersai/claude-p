//! Active single-shot PTY session loop, hook-event state machine, and turn orchestration.
const std = @import("std");
const zmux = @import("zmux");
const emit_mod = @import("../emit.zig");
const hook_mod = @import("../hook.zig");
const stream_mod = @import("../stream.zig");
const env = @import("env.zig");
const watchdog = @import("watchdog.zig");
const paste = @import("paste.zig");
const runtime = @import("runtime.zig");
const finalizer = @import("finalizer.zig");

const Options = env.Options;
const Result = env.Result;
const RunError = env.RunError;
const SharedState = runtime.SharedState;

/// Inject `opts.prompt` into `session` using chunked bracketed paste under `deadline_ns`.
pub fn sendPrompt(session: *zmux.NativeSession, opts: Options, trace_start: i128, deadline_ns: i128) RunError!void {
    std.debug.assert(@intFromPtr(session) != 0);
    std.debug.assert(opts.prompt.len > 0);
    const paste_gap = paste.paste_chunk_gap_ms * std.time.ns_per_ms;
    const debounce = watchdog.ink_enter_debounce_ms * std.time.ns_per_ms;
    paste.typePromptUntil(session, opts.prompt, paste_gap, debounce, deadline_ns) catch |err| switch (err) {
        error.Interrupted => return error.Interrupted,
        error.StopTimeout => return error.StopTimeout,
        else => runtime.traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(err)}),
    };
}

/// Phase of a single-shot Claude Code PTY session.
pub const RunnerState = enum { waiting_for_ready, awaiting_stop };

/// Stateful event loop driving one single-shot PTY session from `SessionStart` to `Stop`.
pub const SessionRunner = struct {
    allocator: std.mem.Allocator,
    opts: Options = .{ .prompt = "hi" },
    debug_screen: bool = false,
    trace_start: i128 = 0,
    deadline_ns: i128 = std.math.maxInt(i128),
    fifo_fd: std.posix.fd_t = -1,
    nonce: []const u8 = "0" ** hook_mod.nonce_len,
    shared: *SharedState,
    session: *zmux.NativeSession = undefined,
    resumed: bool = false,
    streaming: bool = false,
    state: RunnerState = .waiting_for_ready,
    prompt_typed_ns: i128 = 0,
    prompt_injections: u32 = 0,
    prompt_accepted: bool = false,
    last_progress_ns: i128 = 0,
    last_transcript_size: u64 = 0,
    exited_seen_ns: ?i128 = null,
    fifo_buf: std.ArrayList(u8) = .{},
    fin: finalizer.FinalizerState,
    tailer_open_attempts: u32 = 0,

    /// Construct a `SessionRunner` with its embedded `FinalizerState` initialized.
    pub fn init(cfg: struct {
        allocator: std.mem.Allocator,
        opts: Options = .{ .prompt = "hi" },
        debug_screen: bool = false,
        trace_start: i128 = 0,
        deadline_ns: i128 = std.math.maxInt(i128),
        fifo_fd: std.posix.fd_t = -1,
        nonce: []const u8 = "0" ** hook_mod.nonce_len,
        shared: *SharedState,
        session: *zmux.NativeSession = undefined,
        resumed: bool = false,
        streaming: bool = false,
    }) SessionRunner {
        return .{
            .allocator = cfg.allocator,
            .opts = cfg.opts,
            .debug_screen = cfg.debug_screen,
            .trace_start = cfg.trace_start,
            .deadline_ns = cfg.deadline_ns,
            .fifo_fd = cfg.fifo_fd,
            .nonce = cfg.nonce,
            .shared = cfg.shared,
            .session = cfg.session,
            .resumed = cfg.resumed,
            .streaming = cfg.streaming,
            .fin = .{
                .allocator = cfg.allocator,
                .opts = cfg.opts,
                .deadline_ns = cfg.deadline_ns,
                .streaming = cfg.streaming,
            },
        };
    }

    /// Release all heap buffers and open tailer resources owned by `self`.
    pub fn deinit(self: *SessionRunner) void {
        self.fifo_buf.deinit(self.allocator);
        self.fin.deinit();
    }

    /// Update the tracked transcript path and prompt turn offset from a hook event.
    pub fn updateTranscriptFromEvent(self: *SessionRunner, ev: hook_mod.HookLine) RunError!void {
        if (self.state != .awaiting_stop) return;
        std.debug.assert(self.opts.prompt.len > 0);
        const relevant = ev.event == .user_prompt_submit or ev.event == .stop or ev.event == .stop_failure;
        if (!relevant) return;
        if (try watchdog.extractSafeTranscriptPath(self.allocator, ev.payload)) |path| {
            if (self.fin.transcript_path != null and std.mem.eql(u8, self.fin.transcript_path.?, path)) {
                self.allocator.free(path);
            } else {
                if (self.fin.transcript_path) |old| self.allocator.free(old);
                self.fin.transcript_path = path;
                self.fin.pre_prompt_transcript_offset = null;
                if (self.fin.tailer) |*t| t.deinit();
                self.fin.tailer = null;
            }
        }
        if (self.fin.pre_prompt_transcript_offset == null and (!self.resumed or ev.event != .user_prompt_submit)) {
            if (self.fin.transcript_path) |path| {
                const offset = watchdog.findPromptTurnOffset(self.allocator, path, self.opts.prompt);
                self.fin.pre_prompt_transcript_offset = offset;
                if (!self.resumed and self.fin.pre_prompt_transcript_offset == null) {
                    self.fin.pre_prompt_transcript_offset = 0;
                }
            }
        }
    }

    /// Apply one nonce-verified hook event to the runner state machine.
    pub fn handleHookEvent(self: *SessionRunner, ev: hook_mod.HookLine) RunError!void {
        std.debug.assert(@intFromPtr(self.shared) != 0);
        if (self.opts.debug) {
            var trace_buf: [96]u8 = undefined;
            std.debug.print("{s}\n", .{runtime.formatHookTrace(&trace_buf, ev.event, ev.payload.len)});
        }
        try self.updateTranscriptFromEvent(ev);
        switch (ev.event) {
            .session_start => try self.onSessionStart(ev.payload),
            .user_prompt_submit => try self.onPromptSubmit(ev.payload),
            .permission_request => try self.onPermissionRequest(ev.payload),
            .stop, .stop_failure => if (self.state == .awaiting_stop) {
                self.prompt_accepted = true;
                try self.fin.recordStop(ev.event == .stop_failure, ev.payload);
            },
            .unknown => {},
        }
    }

    fn onPermissionRequest(self: *SessionRunner, payload: []const u8) RunError!void {
        if (self.state != .awaiting_stop) return;
        if (watchdog.hasExtraHook(self.opts.extra_hooks, "PermissionRequest")) return;
        const tool = hook_mod.extractPermissionTool(self.allocator, payload);
        defer if (tool) |name| self.allocator.free(name);
        runtime.reportFailure(
            self.shared,
            self.debug_screen,
            "awaiting Stop: permission prompt blocked ({s})",
            .{tool orelse "unknown tool"},
        );
        return error.PermissionPromptBlocked;
    }

    fn onSessionStart(self: *SessionRunner, payload: []const u8) RunError!void {
        std.debug.assert(self.opts.prompt.len > 0);
        runtime.trace(self.opts, self.trace_start, "SessionStart hook fired (Ink is up)");
        self.shared.startup_done.store(true, .seq_cst);
        if (self.fin.transcript_path == null) {
            if (try watchdog.extractSafeTranscriptPath(self.allocator, payload)) |p| self.fin.transcript_path = p;
        }
        if (self.state != .waiting_for_ready) return;
        runtime.settleBeforePrompt(self.opts, self.trace_start, self.shared, self.session);
        if (watchdog.isInterrupted()) return RunError.Interrupted;
        self.fin.pre_prompt_transcript_offset = watchdog.transcriptSize(self.fin.transcript_path);
        try sendPrompt(self.session, self.opts, self.trace_start, self.deadline_ns);
        self.prompt_typed_ns = watchdog.monotonicNs();
        self.last_progress_ns = self.prompt_typed_ns;
        self.last_transcript_size = self.fin.pre_prompt_transcript_offset orelse 0;
        self.prompt_injections = 1;
        std.debug.assert(self.prompt_injections == 1);
        self.state = .awaiting_stop;
    }

    /// Record prompt acceptance and reject truncated delivery reported by `UserPromptSubmit`.
    pub fn onPromptSubmit(self: *SessionRunner, payload: []const u8) RunError!void {
        if (self.state != .awaiting_stop) return;
        std.debug.assert(self.prompt_injections >= 1);
        if (try hook_mod.extractPrompt(self.allocator, payload)) |received| {
            defer self.allocator.free(received);
            if (watchdog.isPromptTruncated(self.opts.prompt, received)) return RunError.PromptTruncated;
        }
        self.prompt_accepted = true;
    }

    /// Drain all currently available bytes from the non-blocking hook FIFO.
    pub fn drainFifo(self: *SessionRunner, read_buf: *[4096]u8) RunError!void {
        std.debug.assert(self.nonce.len == hook_mod.nonce_len);
        while (!self.fin.stop_failed) {
            const fifo_n = std.posix.read(self.fifo_fd, read_buf) catch break;
            if (fifo_n == 0) break;
            try self.fifo_buf.appendSlice(self.allocator, read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, self.fifo_buf.items, '\n') orelse break;
                const line = self.fifo_buf.items[0..nl];
                if (hook_mod.parseLineWithNonce(line, self.nonce)) |ev| {
                    try self.handleHookEvent(ev);
                }
                std.mem.copyForwards(u8, self.fifo_buf.items, self.fifo_buf.items[nl + 1 ..]);
                self.fifo_buf.shrinkRetainingCapacity(self.fifo_buf.items.len - (nl + 1));
                if (self.fin.stop_failed) break;
            }
        }
    }

    fn checkDeadlinesAndExit(self: *SessionRunner, now: i128) RunError!void {
        std.debug.assert(now >= self.trace_start);
        const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now - self.trace_start, std.time.ns_per_ms)));
        if (now >= self.deadline_ns and self.fin.stop_payload_owned == null) {
            const what = if (self.state == .waiting_for_ready) "start" else "finish";
            runtime.reportFailure(
                self.shared,
                self.debug_screen,
                "timed out after {d} ms waiting for claude to {s}",
                .{ elapsed_ms, what },
            );
            return if (self.state == .waiting_for_ready) RunError.SessionStartTimeout else RunError.StopTimeout;
        }
        const exited = self.shared.exited.load(.seq_cst) or self.session.state() == .terminated;
        if (self.fin.stop_payload_owned == null and exited) {
            if (self.state == .waiting_for_ready) {
                runtime.reportFailure(self.shared, self.debug_screen, "claude exited before it finished starting", .{});
                return RunError.SpawnFailed;
            }
            const first_exited = self.exited_seen_ns orelse blk: {
                self.exited_seen_ns = now;
                break :blk now;
            };
            const since_ms: u64 = @intCast(@max(0, @divTrunc(now - first_exited, std.time.ns_per_ms)));
            if (since_ms >= watchdog.post_exit_fifo_grace_ms) {
                if (self.prompt_accepted) return RunError.TranscriptUnavailable;
                runtime.reportFailure(self.shared, self.debug_screen, "claude exited before accepting prompt", .{});
                return RunError.PromptNotAccepted;
            }
        }
        if (self.state == .waiting_for_ready) {
            runtime.maybeHandleStartupDialogs(self.opts, self.trace_start, self.shared, self.session);
            if (self.shared.dialog.refused != .none) {
                runtime.reportFailure(
                    self.shared,
                    self.debug_screen,
                    "claude asked to confirm an unrequested {s} dialog; refusing to answer",
                    .{@tagName(self.shared.dialog.refused)},
                );
                return RunError.UnexpectedStartupDialog;
            }
        }
    }

    fn checkIdleTimeout(self: *SessionRunner, now: i128) RunError!void {
        const idle_ms = self.opts.transcript_idle_timeout_ms orelse return;
        const active = idle_ms != 0 and self.state == .awaiting_stop and
            self.fin.stop_payload_owned == null and self.exited_seen_ns == null;
        if (!active) return;
        const size = watchdog.transcriptSize(self.fin.transcript_path) orelse 0;
        if (size > self.last_transcript_size) self.last_progress_ns = now;
        self.last_transcript_size = size;
        const last_act = @max(self.last_progress_ns, self.shared.last_output_ns.load(.seq_cst));
        if (now - last_act >= @as(i128, idle_ms) * std.time.ns_per_ms) return error.TranscriptStalled;
    }

    fn checkPromptWatchdog(self: *SessionRunner) RunError!void {
        if (self.state != .awaiting_stop or self.exited_seen_ns != null) return;
        const cur_size = watchdog.transcriptSize(self.fin.transcript_path) orelse 0;
        const grew = cur_size > (self.fin.pre_prompt_transcript_offset orelse 0);
        if (!self.prompt_accepted and (self.fin.pre_prompt_transcript_offset != null or !self.resumed) and grew) {
            self.prompt_accepted = true;
        }
        const since_ms: i64 = @intCast(@divTrunc(watchdog.monotonicNs() - self.prompt_typed_ns, std.time.ns_per_ms));
        switch (watchdog.promptWatchdogAction(self.prompt_accepted, self.prompt_injections, since_ms)) {
            .wait => {},
            .reinject => {
                self.session.writeInput("\x15") catch |err| {
                    runtime.traceFmt(self.opts, self.trace_start, "Ctrl-U failed: {s}", .{@errorName(err)});
                };
                runtime.sleepPumpingDec(self.shared, self.session, watchdog.ink_enter_debounce_ms);
                _ = runtime.waitForOutputQuiet(
                    self.opts,
                    self.trace_start,
                    self.shared,
                    self.session,
                    watchdog.ink_quiescence_ms,
                    watchdog.ink_max_wait_ms,
                );
                if (watchdog.isInterrupted()) return RunError.Interrupted;
                try sendPrompt(self.session, self.opts, self.trace_start, self.deadline_ns);
                self.prompt_injections += 1;
                self.prompt_typed_ns = watchdog.monotonicNs();
            },
            .give_up => {
                runtime.reportFailure(
                    self.shared,
                    self.debug_screen,
                    "claude did not accept the prompt after {d} attempts",
                    .{self.prompt_injections},
                );
                return RunError.PromptNotAccepted;
            },
        }
    }

    /// Run idle-timeout checks, prompt re-injection watchdog, and live stream tailing.
    pub fn checkWatchdogAndStream(self: *SessionRunner, now: i128) RunError!void {
        std.debug.assert(@intFromPtr(self.session) != 0);
        try self.checkIdleTimeout(now);
        try self.checkPromptWatchdog();
        if (self.streaming and self.fin.tailer == null and self.state == .awaiting_stop and
            (self.fin.pre_prompt_transcript_offset != null or !self.resumed))
        {
            if (self.fin.transcript_path) |p| {
                self.tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(self.allocator, p)) |t_const| {
                    var t = t_const;
                    t.pos = self.fin.pre_prompt_transcript_offset orelse 0;
                    self.fin.tailer = t;
                } else |_| {}
            }
        }
        if (self.streaming and self.fin.tailer != null) {
            self.fin.total_lines_streamed += try runtime.pumpStream(&self.fin.tailer.?, self.opts.stream_writer.?);
        }
    }

    /// Run the single-shot session loop until Stop confirmation, StopFailure, or error.
    pub fn execute(self: *SessionRunner) RunError!Result {
        std.debug.assert(self.state == .waiting_for_ready);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            if (watchdog.isInterrupted()) return RunError.Interrupted;
            runtime.flushPendingToPty(self.shared, self.session);
            try self.drainFifo(&read_buf);
            if (self.fin.stop_failed or try self.fin.checkProvisionalStop()) break;
            const now = watchdog.monotonicNs();
            try self.checkDeadlinesAndExit(now);
            try self.checkWatchdogAndStream(now);
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        var summary = try self.fin.resolveFinalSummary();
        errdefer summary.deinit(self.allocator);
        if (self.fin.tailer) |*t| {
            _ = try runtime.pumpStream(t, self.opts.stream_writer.?);
            t.flushPartial(self.opts.stream_writer.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.WriteFailed,
            };
        }
        self.session.terminate();
        const elapsed_ns = watchdog.monotonicNs() - self.trace_start;
        const duration_ms: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, std.time.ns_per_ms)));
        var streamed = false;
        if (self.streaming) if (self.opts.stream_writer) |w| {
            try emit_mod.emitJson(self.allocator, w, .{ .summary = &summary, .duration_ms = duration_ms });
            try w.flush();
            streamed = true;
        };
        return .{ .summary = summary, .duration_ms = duration_ms, .streamed = streamed };
    }
};

// -------- tests --------
const testing = std.testing;

test "SessionRunner: init and deinit release buffers" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    try r.fifo_buf.appendSlice(testing.allocator, "x");
    r.fin.transcript_path = try testing.allocator.dupe(u8, "/tmp/a.jsonl");
    r.deinit();
}

test "SessionRunner: initial state is waiting_for_ready" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    try testing.expectEqual(RunnerState.waiting_for_ready, r.state);
}

test "SessionRunner: onPromptSubmit ignored while waiting" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    try r.onPromptSubmit("{\"prompt\":\"x\"}");
    try testing.expect(!r.prompt_accepted);
}

test "SessionRunner: onPromptSubmit accepts normal prompt" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .opts = .{ .prompt = "a" ** 80 }, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    r.prompt_injections = 1;
    try r.onPromptSubmit("{\"prompt\":\"" ++ "a" ** 80 ++ "\"}");
    try testing.expect(r.prompt_accepted);
}

test "SessionRunner: onPromptSubmit rejects truncated prompt" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .opts = .{ .prompt = "a" ** 80 }, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    r.prompt_injections = 1;
    try testing.expectError(RunError.PromptTruncated, r.onPromptSubmit("{\"prompt\":\"short\"}"));
}

test "SessionRunner: onPromptSubmit accepts payload without prompt" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    r.prompt_injections = 1;
    try r.onPromptSubmit("{}");
    try testing.expect(r.prompt_accepted);
}

test "SessionRunner: unknown hook is no-op" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    try r.handleHookEvent(.{ .event = .unknown, .payload = "{}" });
    try testing.expectEqual(RunnerState.waiting_for_ready, r.state);
}

test "SessionRunner: Stop recorded while awaiting_stop" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    try r.handleHookEvent(.{ .event = .stop, .payload = "{\"last_assistant_message\":\"ok\"}" });
    try testing.expect(r.prompt_accepted and !r.fin.stop_failed);
    try testing.expectEqualStrings("ok", r.fin.stop_last.?);
}

test "SessionRunner: Stop ignored before awaiting_stop" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    try r.handleHookEvent(.{ .event = .stop, .payload = "{\"last_assistant_message\":\"early\"}" });
    try testing.expect(r.fin.stop_payload_owned == null);
}

test "SessionRunner: StopFailure marks stop_failed" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    try r.handleHookEvent(.{ .event = .stop_failure, .payload = "{\"error\":\"boom\"}" });
    try testing.expect(r.fin.stop_failed);
}

test "SessionRunner: PermissionRequest blocked by default" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    try testing.expectError(error.PermissionPromptBlocked, r.handleHookEvent(.{ .event = .permission_request, .payload = "{}" }));
}

test "SessionRunner: PermissionRequest allowed with extra hook" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{
        .allocator = testing.allocator,
        .opts = .{ .prompt = "hi", .extra_hooks = &.{.{ .event = "PermissionRequest", .command = "true" }} },
        .shared = &sh,
    });
    defer r.deinit();
    r.state = .awaiting_stop;
    try r.handleHookEvent(.{ .event = .permission_request, .payload = "{}" });
}

test "SessionRunner: SessionStartTimeout while waiting" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .trace_start = 100, .deadline_ns = 200, .shared = &sh });
    defer r.deinit();
    try testing.expectError(RunError.SessionStartTimeout, r.checkDeadlinesAndExit(200));
}

test "SessionRunner: StopTimeout while awaiting_stop" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .trace_start = 100, .deadline_ns = 200, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    try testing.expectError(RunError.StopTimeout, r.checkDeadlinesAndExit(200));
}

test "SessionRunner: SpawnFailed on early exit" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    sh.exited.store(true, .seq_cst);
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    try testing.expectError(RunError.SpawnFailed, r.checkDeadlinesAndExit(100));
}

test "SessionRunner: checkIdleTimeout flags stall and honors 0" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{
        .allocator = testing.allocator,
        .opts = .{ .prompt = "hi", .transcript_idle_timeout_ms = 50 },
        .shared = &sh,
    });
    defer r.deinit();
    r.state = .awaiting_stop;
    try testing.expectError(error.TranscriptStalled, r.checkIdleTimeout(60 * std.time.ns_per_ms));
    r.opts.transcript_idle_timeout_ms = 0;
    try r.checkIdleTimeout(60 * std.time.ns_per_ms);
}

test "SessionRunner: updateTranscriptFromEvent sets path and offset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"type\":\"assistant\"}\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    const payload = try std.fmt.allocPrint(testing.allocator, "{{\"transcript_path\":\"{s}\"}}", .{path});
    defer testing.allocator.free(payload);
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    try r.updateTranscriptFromEvent(.{ .event = .stop, .payload = payload });
    try testing.expectEqualStrings(path, r.fin.transcript_path.?);
    try testing.expectEqual(@as(?u64, 0), r.fin.pre_prompt_transcript_offset);
}

test "SessionRunner: updateTranscriptFromEvent keeps duplicate path" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    r.fin.transcript_path = try testing.allocator.dupe(u8, "/tmp/same.jsonl");
    r.fin.pre_prompt_transcript_offset = 12;
    try r.updateTranscriptFromEvent(.{ .event = .stop, .payload = "{\"transcript_path\":\"/tmp/same.jsonl\"}" });
    try testing.expectEqual(@as(?u64, 12), r.fin.pre_prompt_transcript_offset);
}

test "SessionRunner: drainFifo filters bad nonce and accepts valid" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    const nonce = "a" ** hook_mod.nonce_len;
    _ = try std.posix.write(fds[1], "b" ** hook_mod.nonce_len ++ "\tStop\t{\"last_assistant_message\":\"bad\"}\n");
    _ = try std.posix.write(fds[1], nonce ++ "\tStop\t{\"last_assistant_message\":\"ok\"}\n");
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .fifo_fd = fds[0], .nonce = nonce, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    var buf: [4096]u8 = undefined;
    try r.drainFifo(&buf);
    try testing.expectEqualStrings("ok", r.fin.stop_last.?);
}

test "SessionRunner: drainFifo buffers partial line until newline" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    const nonce = "a" ** hook_mod.nonce_len;
    _ = try std.posix.write(fds[1], nonce ++ "\tStop\t{\"last_assistant_message\":");
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var r = SessionRunner.init(.{ .allocator = testing.allocator, .fifo_fd = fds[0], .nonce = nonce, .shared = &sh });
    defer r.deinit();
    r.state = .awaiting_stop;
    var buf: [4096]u8 = undefined;
    try r.drainFifo(&buf);
    try testing.expect(r.fin.stop_last == null);
    _ = try std.posix.write(fds[1], "\"ok\"}\n");
    try r.drainFifo(&buf);
    try testing.expectEqualStrings("ok", r.fin.stop_last.?);
}
