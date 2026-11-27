//! End-to-end single-shot PTY session driver for interactive Claude Code.
const std = @import("std");
const zmux = @import("zmux");
const emit_mod = @import("emit.zig");
const hook_mod = @import("hook.zig");
const stream_mod = @import("stream.zig");
const transcript_mod = @import("transcript.zig");

/// Pre-spawn option/path/binary validation, argv builder, and child env filtering.
pub const env = @import("driver/env.zig");
/// Signal cancellation, monotonic clock, prompt watchdog, and Stop scanning.
pub const watchdog = @import("driver/watchdog.zig");
/// Chunked DECSET 2004 bracketed paste with UTF-8 safety.
pub const paste = @import("driver/paste.zig");
/// Pre-SessionStart startup dialog state machine and CSI/OSC stripping.
pub const dialog = @import("driver/dialog.zig");
/// Thread-shared PTY state, zmux callback, quiescence waits, and diagnostics.
pub const runtime = @import("driver/runtime.zig");

/// Configuration options for a single-shot PTY Claude Code session run.
pub const Options = env.Options;
/// Outcome of a completed single-shot run, owning its parsed `Summary`.
pub const Result = env.Result;
/// Error set returned by single-shot PTY session orchestration.
pub const RunError = env.RunError;
/// Error set returned when locating the `claude` binary fails.
pub const ResolveError = env.ResolveError;
/// Owned argv container returned by `buildArgv`.
pub const Argv = env.Argv;
/// Reject options or forwarded flags that are unsupported in PTY print mode.
pub const validateOptions = env.validateOptions;
/// True when this invocation restores an earlier conversation.
pub const isResumeRun = env.isResumeRun;
/// Check that `cwd`, when set, names an accessible directory.
pub const validateCwd = env.validateCwd;
/// Resolve the `claude` executable using an explicit override or `path_env`.
pub const resolveClaudeBinaryIn = env.resolveClaudeBinaryIn;
/// Resolve the `claude` executable against this process's `PATH`.
pub const resolveClaudeBinary = env.resolveClaudeBinary;
/// Build the `/bin/sh -l -c` `exec` command line from `argv`.
pub const buildShellCommand = env.buildShellCommand;
/// Build the `/bin/sh -l -c` command string, optionally changing into `cwd`.
pub const buildShellCommandInDir = env.buildShellCommandInDir;
/// Build the argv for the child `claude` invocation.
pub const buildArgv = env.buildArgv;
/// Join argv into a single shell-safe command line.
pub const shellQuoteArgv = env.shellQuoteArgv;
/// Return true ONLY for nested-session markers that must not leak into child `claude`.
pub const shouldStripChildEnv = env.shouldStripChildEnv;
/// Build the filtered child environment from the current process environment.
pub const buildChildEnv = env.buildChildEnv;
/// Construct the sanitized child environment list from `env_map`.
pub const buildChildEnvFromMap = env.buildChildEnvFromMap;
/// Free all owned `KEY=VALUE` entries in a child environment list.
pub const freeChildEnv = env.freeChildEnv;

/// Set by `requestInterrupt`; polled by `run` and every settle wait.
pub const interrupted = &watchdog.interrupted;
/// RAII guard capturing the current interrupt generation for a single session.
pub const InterruptScope = watchdog.InterruptScope;
/// Ask every in-flight run to stop using only lock-free signal-safe atomics.
pub const requestInterrupt = watchdog.requestInterrupt;
/// Reset the global interrupt flag after an interrupted session unwinds.
pub const clearInterrupt = watchdog.clearInterrupt;
/// Return true if a global interrupt was requested since this scope began.
pub const isInterrupted = watchdog.isInterrupted;
/// Nanoseconds on a monotonic clock anchored near wall-clock time.
pub const monotonicNs = watchdog.monotonicNs;
/// Quiet duration before typing on fresh sessions.
pub const ink_quiescence_ms = watchdog.ink_quiescence_ms;
/// Upper bound on initial Ink quiescence waits.
pub const ink_max_wait_ms = watchdog.ink_max_wait_ms;
/// Delay between pasting prompt bytes and sending Enter.
pub const ink_enter_debounce_ms = watchdog.ink_enter_debounce_ms;
/// Quiet duration before interacting with a startup dialog.
pub const dialog_quiescence_ms = watchdog.dialog_quiescence_ms;
/// Extra settle delay after first quiescence following SessionStart.
pub const prompt_settle_ms = watchdog.prompt_settle_ms;
/// Quiet window before typing into a resumed conversation.
pub const resume_quiescence_ms = watchdog.resume_quiescence_ms;
/// Upper bound on resume settle wait.
pub const resume_max_wait_ms = watchdog.resume_max_wait_ms;
/// Grace window after child exit while awaiting an in-flight Stop hook.
pub const post_exit_fifo_grace_ms = watchdog.post_exit_fifo_grace_ms;
/// Wait window for prompt acknowledgement before re-injecting.
pub const prompt_accept_timeout_ms = watchdog.prompt_accept_timeout_ms;
/// Maximum prompt injection attempts before failing.
pub const max_prompt_injections = watchdog.max_prompt_injections;
/// Minimum payload length subject to prompt truncation detection.
pub const prompt_truncation_min_len = watchdog.prompt_truncation_min_len;
/// Action chosen by the prompt-acknowledgement watchdog on each tick.
pub const WatchdogAction = watchdog.WatchdogAction;
/// Prompt-acceptance watchdog decision.
pub const promptWatchdogAction = watchdog.promptWatchdogAction;
/// Count deliverable printable non-space bytes in `text`.
pub const promptPayloadLen = watchdog.promptPayloadLen;
/// Detect whether Claude received a truncated copy of our typed prompt.
pub const isPromptTruncated = watchdog.isPromptTruncated;
/// True when `final_text` agrees with Stop's `last_assistant_message`.
pub const finalTextMatchesStop = watchdog.finalTextMatchesStop;
/// Validate a transcript file path.
pub const validateTranscriptPath = watchdog.validateTranscriptPath;
/// Extract and validate `transcript_path` from a hook JSON payload.
pub const extractSafeTranscriptPath = watchdog.extractSafeTranscriptPath;
/// Return true when `hooks` contains an extra hook registered for `event`.
pub const hasExtraHook = watchdog.hasExtraHook;
/// Return the stop-confirmation grace window in nanoseconds.
pub const stopConfirmationNs = watchdog.stopConfirmationNs;
/// Return true when failure screen capture is enabled.
pub const debugScreenEnabled = watchdog.debugScreenEnabled;
/// Classification of a post-Stop transcript record.
pub const StopSummaryStatus = watchdog.StopSummaryStatus;
/// Return true when a JSONL transcript line indicates continuation after Stop.
pub const isContinuationRecord = watchdog.isContinuationRecord;
/// Consume complete post-Stop transcript records up to `size`.
pub const scanStopRecords = watchdog.scanStopRecords;
/// Return byte offset of the last user record matching `prompt`.
pub const findPromptTurnOffset = watchdog.findPromptTurnOffset;
/// Build the error `Summary` for a `StopFailure` hook.
pub const synthesizeStopFailureSummary = watchdog.synthesizeStopFailureSummary;
/// Replace `summary.final_text` with Stop's text when the transcript disagrees.
pub const preferStopText = watchdog.preferStopText;

/// DECSET 2004 bracketed-paste start escape sequence.
pub const paste_start = paste.paste_start;
/// DECSET 2004 bracketed-paste end escape sequence.
pub const paste_end = paste.paste_end;
/// Max bytes per PTY write chunk.
pub const paste_chunk_bytes = paste.paste_chunk_bytes;
/// Inter-chunk pause in milliseconds.
pub const paste_chunk_gap_ms = paste.paste_chunk_gap_ms;
/// UTF-8-safe, end-marker-sanitizing bracketed-paste chunker.
pub const PasteChunker = paste.PasteChunker;
/// Write `text` wrapped in bracketed-paste escapes to `sink`.
pub const writeBracketedPasteTo = paste.writeBracketedPasteTo;
/// Paste `text`, debounce, and send `\r` to `sink`.
pub const typePromptTo = paste.typePromptTo;
/// Send `text` as one bracketed paste over `session`.
pub const writeBracketedPaste = paste.writeBracketedPaste;
/// Paste `text`, debounce, and send `\r` over `session`.
pub const typePrompt = paste.typePrompt;

/// Recognised interactive startup dialogs before `SessionStart`.
pub const DialogKind = dialog.DialogKind;
/// Cursor selection state within a startup dialog.
pub const DialogSelection = dialog.DialogSelection;
/// Parsed cursor position and option layout of a startup dialog frame.
pub const DialogAnalysis = dialog.DialogAnalysis;
/// Next keystroke or transition emitted by the startup-dialog state machine.
pub const DialogAction = dialog.DialogAction;
/// Pair of detected startup dialog kind and action.
pub const DialogDecision = dialog.DialogDecision;
/// Mutable dialog tracker state embedded in `SharedState`.
pub const DialogState = dialog.DialogState;
/// Wait window before retrying a dropped dialog keystroke.
pub const dialog_retry_ms = dialog.dialog_retry_ms;
/// Hard cap on dialog keystrokes per session.
pub const max_dialog_keys = dialog.max_dialog_keys;
/// Return true when `opts` authorizes auto-confirming `kind`.
pub const dialogConfirmAllowed = dialog.dialogConfirmAllowed;
/// Identify the active startup dialog in CSI-stripped terminal output.
pub const classifyDialog = dialog.classifyDialog;
/// Read cursor selection and option layout of `kind`.
pub const analyzeDialog = dialog.analyzeDialog;
/// Choose the safe keystroke for `kind` given its parsed selection state.
pub const chooseDialogAction = dialog.chooseDialogAction;
/// One step of the startup-dialog state machine.
pub const decideDialog = dialog.decideDialog;
/// Strip CSI / OSC / DCS escape sequences into caller buffer `out`.
pub const stripCsiInto = dialog.stripCsiInto;
/// Strip CSI / OSC / DCS escape sequences into a newly allocated slice.
pub const stripCsi = dialog.stripCsi;

/// Maximum bytes retained in the rolling startup-dialog PTY buffer.
pub const recent_capacity = runtime.recent_capacity;
/// Fixed scratch capacity for `decRepliesInto`.
pub const dec_reply_capacity = runtime.dec_reply_capacity;
/// Maximum non-blank lines included in a failure screen diagnostic.
pub const failure_screen_max_lines = runtime.failure_screen_max_lines;
/// Maximum byte length of a failure screen diagnostic.
pub const failure_screen_max_bytes = runtime.failure_screen_max_bytes;
/// Thread-shared PTY telemetry, DEC reply queue, and startup-dialog state.
pub const SharedState = runtime.SharedState;
/// Fixed-buffer convenience for DEC query replies.
pub const decRepliesInto = runtime.decRepliesInto;
/// zmux EventSink callback invoked on the reader thread.
pub const onZmuxEvent = runtime.onZmuxEvent;
/// Drain queued DEC-query responses to the PTY.
pub const flushPendingToPty = runtime.flushPendingToPty;
/// Block until the child PTY has been quiet for `ink_quiescence_ms`.
pub const waitForInkQuiescent = runtime.waitForInkQuiescent;
/// Pre-SessionStart startup dialog handler.
pub const maybeHandleStartupDialogs = runtime.maybeHandleStartupDialogs;
/// Format a privacy-safe `--debug` trace line for a hook event.
pub const formatHookTrace = runtime.formatHookTrace;
/// Render the tail of raw PTY output for a failure diagnostic.
pub const formatFailureScreen = runtime.formatFailureScreen;
/// Write a formatted failure diagnostic and optional PTY tail to stderr.
pub const reportFailure = runtime.reportFailure;
/// Pump new transcript lines to `writer` and flush them.
pub const pumpStream = runtime.pumpStream;

const typePromptUntil = paste.typePromptUntil;
const writeFailure = runtime.writeFailure;
const stop_failure_default_text = watchdog.stop_failure_default_text;

fn sendPrompt(session: *zmux.NativeSession, opts: Options, trace_start: i128, deadline_ns: i128) RunError!void {
    const gap = paste_chunk_gap_ms * std.time.ns_per_ms;
    const debounce = ink_enter_debounce_ms * std.time.ns_per_ms;
    paste.typePromptUntil(session, opts.prompt, gap, debounce, deadline_ns) catch |err| switch (err) {
        error.Interrupted => return error.Interrupted,
        error.StopTimeout => return error.StopTimeout,
        else => runtime.traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(err)}),
    };
}

const SessionRunner = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    debug_screen: bool,
    trace_start: i128,
    deadline_ns: i128,
    fifo_fd: std.posix.fd_t,
    nonce: []const u8,
    shared: *SharedState,
    session: *zmux.NativeSession,
    resumed: bool,
    streaming: bool,
    state: enum { waiting_for_ready, awaiting_stop } = .waiting_for_ready,
    first_emit_logged: bool = false,
    total_lines_streamed: usize = 0,
    prompt_typed_ns: i128 = 0,
    prompt_injections: u32 = 0,
    prompt_accepted: bool = false,
    last_progress_ns: i128 = 0,
    last_transcript_size: u64 = 0,
    pre_prompt_transcript_offset: ?u64 = null,
    exited_seen_ns: ?i128 = null,
    fifo_buf: std.ArrayList(u8) = .{},
    transcript_path: ?[]u8 = null,
    stop_payload_owned: ?[]u8 = null,
    stop_failed: bool = false,
    confirm_until: i128 = 0,
    provisional_size: u64 = 0,
    stop_last: ?[]u8 = null,
    tailer: ?stream_mod.Tailer = null,
    tailer_open_attempts: u32 = 0,

    fn deinit(self: *SessionRunner) void {
        self.fifo_buf.deinit(self.allocator);
        if (self.transcript_path) |p| self.allocator.free(p);
        if (self.stop_payload_owned) |p| self.allocator.free(p);
        if (self.stop_last) |a| self.allocator.free(a);
        if (self.tailer) |*t| t.deinit();
    }

    fn updateTranscriptFromEvent(self: *SessionRunner, ev: hook_mod.HookLine) RunError!void {
        if (self.state != .awaiting_stop) return;
        std.debug.assert(self.opts.prompt.len > 0);
        const relevant = ev.event == .user_prompt_submit or ev.event == .stop or ev.event == .stop_failure;
        if (!relevant) return;
        if (try extractSafeTranscriptPath(self.allocator, ev.payload)) |path| {
            if (self.transcript_path != null and std.mem.eql(u8, self.transcript_path.?, path)) {
                self.allocator.free(path);
            } else {
                if (self.transcript_path) |old| self.allocator.free(old);
                self.transcript_path = path;
                self.pre_prompt_transcript_offset = null;
                if (self.tailer) |*t| t.deinit();
                self.tailer = null;
            }
        }
        if (self.pre_prompt_transcript_offset == null and (!self.resumed or ev.event != .user_prompt_submit)) {
            if (self.transcript_path) |path| {
                self.pre_prompt_transcript_offset = findPromptTurnOffset(self.allocator, path, self.opts.prompt);
                if (!self.resumed and self.pre_prompt_transcript_offset == null) {
                    self.pre_prompt_transcript_offset = 0;
                }
            }
        }
    }

    fn handleHookEvent(self: *SessionRunner, ev: hook_mod.HookLine) RunError!void {
        std.debug.assert(@intFromPtr(self.shared) != 0);
        if (self.opts.debug) {
            var trace_buf: [96]u8 = undefined;
            std.debug.print("{s}\n", .{formatHookTrace(&trace_buf, ev.event, ev.payload.len)});
        }
        try self.updateTranscriptFromEvent(ev);
        switch (ev.event) {
            .session_start => try self.onSessionStart(ev.payload),
            .user_prompt_submit => try self.onPromptSubmit(ev.payload),
            .permission_request => {
                if (self.state == .awaiting_stop and !hasExtraHook(self.opts.extra_hooks, "PermissionRequest")) {
                    const tool = hook_mod.extractPermissionTool(self.allocator, ev.payload);
                    defer if (tool) |name| self.allocator.free(name);
                    reportFailure(
                        self.shared,
                        self.debug_screen,
                        "awaiting Stop: permission prompt blocked ({s})",
                        .{tool orelse "unknown tool"},
                    );
                    return error.PermissionPromptBlocked;
                }
            },
            .stop, .stop_failure => if (self.state == .awaiting_stop) {
                self.prompt_accepted = true;
                const replacement = try self.allocator.dupe(u8, ev.payload);
                if (self.stop_payload_owned) |old| self.allocator.free(old);
                self.stop_payload_owned = replacement;
                if (self.stop_last) |old| self.allocator.free(old);
                self.stop_last = null;
                self.stop_last = try hook_mod.extractLastAssistantMessage(self.allocator, ev.payload);
                self.stop_failed = ev.event == .stop_failure;
                self.provisional_size = watchdog.transcriptSize(self.transcript_path) orelse 0;
                self.confirm_until = @min(self.deadline_ns, monotonicNs() + stopConfirmationNs(self.opts.extra_hooks));
            },
            .unknown => {},
        }
    }

    fn onSessionStart(self: *SessionRunner, payload: []const u8) RunError!void {
        std.debug.assert(self.opts.prompt.len > 0);
        runtime.trace(self.opts, self.trace_start, "SessionStart hook fired (Ink is up)");
        self.shared.startup_done.store(true, .seq_cst);
        if (self.transcript_path == null) {
            if (try extractSafeTranscriptPath(self.allocator, payload)) |p| self.transcript_path = p;
        }
        if (self.state != .waiting_for_ready) return;
        runtime.settleBeforePrompt(self.opts, self.trace_start, self.shared, self.session);
        if (isInterrupted()) return RunError.Interrupted;
        self.pre_prompt_transcript_offset = watchdog.transcriptSize(self.transcript_path);
        try sendPrompt(self.session, self.opts, self.trace_start, self.deadline_ns);
        self.prompt_typed_ns = monotonicNs();
        self.last_progress_ns = self.prompt_typed_ns;
        self.last_transcript_size = self.pre_prompt_transcript_offset orelse 0;
        self.prompt_injections = 1;
        std.debug.assert(self.prompt_injections == 1);
        self.state = .awaiting_stop;
    }

    fn onPromptSubmit(self: *SessionRunner, payload: []const u8) RunError!void {
        if (self.state != .awaiting_stop) return;
        std.debug.assert(self.prompt_injections >= 1);
        if (try hook_mod.extractPrompt(self.allocator, payload)) |received| {
            defer self.allocator.free(received);
            if (isPromptTruncated(self.opts.prompt, received)) return RunError.PromptTruncated;
        }
        self.prompt_accepted = true;
    }

    fn drainFifo(self: *SessionRunner, read_buf: *[4096]u8) RunError!void {
        std.debug.assert(self.nonce.len == hook_mod.nonce_len);
        while (!self.stop_failed) {
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
                if (self.stop_failed) break;
            }
        }
    }

    fn checkProvisionalStop(self: *SessionRunner) RunError!bool {
        const payload = self.stop_payload_owned orelse return false;
        std.debug.assert(self.state == .awaiting_stop);
        const status: StopSummaryStatus = scan: {
            const path = self.transcript_path orelse break :scan .none;
            const file = transcript_mod.openTranscriptRegularFile(path) catch break :scan .none;
            defer file.close();
            const size = (file.stat() catch break :scan .none).size;
            if (size <= self.provisional_size) break :scan .none;
            break :scan scanStopRecords(
                self.allocator,
                file,
                &self.provisional_size,
                size,
                self.stop_last,
                self.opts.prompt,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => .none,
            };
        };
        if (status == .continued) {
            self.allocator.free(payload);
            self.stop_payload_owned = null;
            return false;
        }
        return status == .confirmed or monotonicNs() >= self.confirm_until;
    }

    fn checkDeadlinesAndExit(self: *SessionRunner, now: i128) RunError!void {
        std.debug.assert(now >= self.trace_start);
        const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now - self.trace_start, std.time.ns_per_ms)));
        if (now >= self.deadline_ns and self.stop_payload_owned == null) {
            if (self.state == .waiting_for_ready) {
                reportFailure(
                    self.shared,
                    self.debug_screen,
                    "timed out after {d} ms waiting for claude to start",
                    .{elapsed_ms},
                );
                return RunError.SessionStartTimeout;
            }
            reportFailure(
                self.shared,
                self.debug_screen,
                "timed out after {d} ms waiting for claude to finish",
                .{elapsed_ms},
            );
            return RunError.StopTimeout;
        }
        const exited = self.shared.exited.load(.seq_cst) or self.session.state() == .terminated;
        if (self.stop_payload_owned == null and exited) {
            if (self.state == .waiting_for_ready) {
                reportFailure(self.shared, self.debug_screen, "claude exited before it finished starting", .{});
                return RunError.SpawnFailed;
            }
            const first_exited = self.exited_seen_ns orelse blk: {
                self.exited_seen_ns = now;
                break :blk now;
            };
            const since_ms: u64 = @intCast(@max(0, @divTrunc(now - first_exited, std.time.ns_per_ms)));
            if (since_ms >= post_exit_fifo_grace_ms) {
                if (self.prompt_accepted) return RunError.TranscriptUnavailable;
                reportFailure(self.shared, self.debug_screen, "claude exited before it accepted the prompt", .{});
                return RunError.PromptNotAccepted;
            }
        }
        if (self.state == .waiting_for_ready) {
            maybeHandleStartupDialogs(self.opts, self.trace_start, self.shared, self.session);
            if (self.shared.dialog.refused != .none) {
                reportFailure(
                    self.shared,
                    self.debug_screen,
                    "claude asked to confirm a {s} dialog that this run did not request; refusing to answer it. " ++
                        "Pass --dangerously-skip-permissions, --permission-mode bypassPermissions, or " ++
                        "--dangerously-load-development-channels to approve it explicitly",
                    .{@tagName(self.shared.dialog.refused)},
                );
                return RunError.UnexpectedStartupDialog;
            }
        }
    }

    fn checkWatchdogAndStream(self: *SessionRunner, now: i128) RunError!void {
        std.debug.assert(@intFromPtr(self.session) != 0);
        if (self.opts.transcript_idle_timeout_ms) |idle_ms| {
            const active = idle_ms != 0 and self.state == .awaiting_stop and
                self.stop_payload_owned == null and self.exited_seen_ns == null;
            if (active) {
                const size = watchdog.transcriptSize(self.transcript_path) orelse 0;
                if (size > self.last_transcript_size) self.last_progress_ns = now;
                self.last_transcript_size = size;
                const last_act = @max(self.last_progress_ns, self.shared.last_output_ns.load(.seq_cst));
                if (now - last_act >= @as(i128, idle_ms) * std.time.ns_per_ms) return error.TranscriptStalled;
            }
        }
        if (self.state == .awaiting_stop and self.exited_seen_ns == null) {
            const cur_size = watchdog.transcriptSize(self.transcript_path) orelse 0;
            const grew = cur_size > (self.pre_prompt_transcript_offset orelse 0);
            if (!self.prompt_accepted and (self.pre_prompt_transcript_offset != null or !self.resumed) and grew) {
                self.prompt_accepted = true;
            }
            const since_ms: i64 = @intCast(@divTrunc(monotonicNs() - self.prompt_typed_ns, std.time.ns_per_ms));
            switch (promptWatchdogAction(self.prompt_accepted, self.prompt_injections, since_ms)) {
                .wait => {},
                .reinject => {
                    self.session.writeInput("\x15") catch |err| {
                        runtime.traceFmt(self.opts, self.trace_start, "Ctrl-U failed: {s}", .{@errorName(err)});
                    };
                    runtime.sleepPumpingDec(self.shared, self.session, ink_enter_debounce_ms);
                    _ = runtime.waitForOutputQuiet(
                        self.opts,
                        self.trace_start,
                        self.shared,
                        self.session,
                        ink_quiescence_ms,
                        ink_max_wait_ms,
                    );
                    if (isInterrupted()) return RunError.Interrupted;
                    try sendPrompt(self.session, self.opts, self.trace_start, self.deadline_ns);
                    self.prompt_injections += 1;
                    self.prompt_typed_ns = monotonicNs();
                },
                .give_up => {
                    reportFailure(
                        self.shared,
                        self.debug_screen,
                        "claude did not accept the prompt after {d} attempts",
                        .{self.prompt_injections},
                    );
                    return RunError.PromptNotAccepted;
                },
            }
        }
        if (self.streaming and self.tailer == null and self.state == .awaiting_stop and
            (self.pre_prompt_transcript_offset != null or !self.resumed))
        {
            if (self.transcript_path) |p| {
                self.tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(self.allocator, p)) |t_const| {
                    var t = t_const;
                    t.pos = self.pre_prompt_transcript_offset orelse 0;
                    self.tailer = t;
                } else |_| {}
            }
        }
        if (self.streaming and self.tailer != null) {
            self.total_lines_streamed += try pumpStream(&self.tailer.?, self.opts.stream_writer.?);
        }
    }

    fn resolveFinalSummary(self: *SessionRunner) RunError!transcript_mod.Summary {
        std.debug.assert(self.stop_failed or self.stop_payload_owned != null);
        const keep_replay = self.opts.retain_replay and self.opts.stream_writer == null;
        if (self.transcript_path) |path| if (self.pre_prompt_transcript_offset) |offset| {
            for (0..20) |attempt| {
                if (isInterrupted()) return error.Interrupted;
                if (self.streaming and self.tailer == null) {
                    if (stream_mod.Tailer.open(self.allocator, path)) |t| {
                        self.tailer = t;
                        self.tailer.?.pos = offset;
                    } else |_| {}
                }
                if (self.tailer) |*t| self.total_lines_streamed += try pumpStream(t, self.opts.stream_writer.?);
                const parse_opts: transcript_mod.ParseOptions = .{
                    .keep_replay = keep_replay,
                    .stop_text = if (self.stop_failed) null else self.stop_last,
                };
                if (transcript_mod.parseFileFromOffsetWithOptions(self.allocator, path, offset, parse_opts)) |cand| {
                    var parsed = cand;
                    if (try self.acceptParsedSummary(&parsed, attempt)) return parsed;
                    parsed.deinit(self.allocator);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.FileNotFound, error.NoAssistantMessage => {},
                    else => break,
                }
                if (self.stop_failed or attempt == 19 or monotonicNs() >= self.deadline_ns) break;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
        };
        if (self.stop_failed) return try synthesizeStopFailureSummary(self.allocator, self.stop_payload_owned.?);
        return self.fallbackStopSummary();
    }

    fn acceptParsedSummary(
        self: *SessionRunner,
        parsed: *transcript_mod.Summary,
        attempt: usize,
    ) RunError!bool {
        std.debug.assert(attempt < 20);
        if (self.stop_failed) {
            if (try hook_mod.extractErrorMessageAlloc(self.allocator, self.stop_payload_owned.?)) |msg| {
                if (std.mem.trim(u8, msg, " \t\r\n").len > 0) {
                    self.allocator.free(parsed.final_text);
                    parsed.final_text = msg;
                } else self.allocator.free(msg);
            }
            parsed.is_error = true;
            if (parsed.subtype) |sub| if (std.mem.eql(u8, sub, "success")) {
                self.allocator.free(sub);
                parsed.subtype = null;
            };
            return true;
        }
        const matches = finalTextMatchesStop(parsed.final_text, self.stop_last);
        if ((parsed.final_text.len > 0 or parsed.is_error) and matches) return true;
        if ((attempt == 19 or monotonicNs() >= self.deadline_ns) and !matches) {
            try preferStopText(self.allocator, parsed, self.stop_last);
            return true;
        }
        return false;
    }

    fn fallbackStopSummary(self: *SessionRunner) RunError!transcript_mod.Summary {
        std.debug.assert(!self.stop_failed);
        const payload = self.stop_payload_owned orelse return RunError.TranscriptUnavailable;
        const text = self.stop_last orelse return RunError.TranscriptUnavailable;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return RunError.TranscriptUnavailable;
        const final_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(final_text);
        const sid = (try hook_mod.extractSessionId(self.allocator, payload)) orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(sid);
        return .{
            .final_text = final_text,
            .session_id = sid,
            .is_error = false,
            .num_turns = 1,
            .total_cost_usd = 0.0,
            .duration_api_ms = 0,
            .usage = .{},
            .jsonl_replay = try self.allocator.dupe(u8, ""),
        };
    }

    fn execute(self: *SessionRunner) RunError!Result {
        std.debug.assert(self.state == .waiting_for_ready);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            if (isInterrupted()) return RunError.Interrupted;
            flushPendingToPty(self.shared, self.session);
            try self.drainFifo(&read_buf);
            if (self.stop_failed or try self.checkProvisionalStop()) break;
            const now = monotonicNs();
            try self.checkDeadlinesAndExit(now);
            try self.checkWatchdogAndStream(now);
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        var summary = try self.resolveFinalSummary();
        errdefer summary.deinit(self.allocator);
        if (self.tailer) |*t| {
            _ = try pumpStream(t, self.opts.stream_writer.?);
            t.flushPartial(self.opts.stream_writer.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.WriteFailed,
            };
        }
        self.session.terminate();
        const duration_ms: u64 = @intCast(@max(0, @divTrunc(monotonicNs() - self.trace_start, std.time.ns_per_ms)));
        var streamed = false;
        if (self.streaming) if (self.opts.stream_writer) |w| {
            try emit_mod.emitJson(self.allocator, w, .{ .summary = &summary, .duration_ms = duration_ms });
            try w.flush();
            streamed = true;
        };
        return .{ .summary = summary, .duration_ms = duration_ms, .streamed = streamed };
    }
};

/// Execute a single-shot Claude Code PTY session with interrupt scoping and full cleanup.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!Result {
    const scope = InterruptScope.enter();
    defer scope.exit();
    return runSession(allocator, opts) catch |err| {
        if (err == error.Interrupted) clearInterrupt();
        return err;
    };
}

fn runSession(caller_allocator: std.mem.Allocator, opts: Options) RunError!Result {
    try validateOptions(opts);
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;
    if (isInterrupted()) return RunError.Interrupted;
    const cwd = if (opts.cwd) |dir| try env.resolveCwd(caller_allocator, dir) else null;
    defer if (cwd) |dir| caller_allocator.free(dir);
    const debug_screen = debugScreenEnabled(opts.debug);

    var tsa: std.heap.ThreadSafeAllocator = .{ .child_allocator = caller_allocator };
    const allocator = tsa.allocator();
    const trace_start: i128 = monotonicNs();
    const deadline_ns = if (opts.timeout_ms == 0)
        std.math.maxInt(i128)
    else
        trace_start + @as(i128, opts.timeout_ms) * std.time.ns_per_ms;

    var harness = hook_mod.createWithOptions(allocator, .{
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
    }) catch |e| switch (e) {
        error.InvalidExtraSettings => return RunError.InvalidExtraSettings,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer harness.deinit();

    const claude_bin = resolveClaudeBinary(allocator, opts.claude_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reportFailure(null, debug_screen, "claude executable not found: `{s}` is not an executable file{s}", .{
                opts.claude_path orelse "claude",
                if (opts.claude_path == null) " on PATH" else "",
            });
            return RunError.SpawnFailed;
        },
    };
    defer allocator.free(claude_bin);

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer argv.deinit(allocator);
    const shell_cmd = try buildShellCommandInDir(allocator, argv.items, cwd);
    defer allocator.free(shell_cmd);
    var env_list = buildChildEnv(allocator, harness.fifo_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer freeChildEnv(allocator, &env_list);
    std.debug.assert(shell_cmd.len > 0);
    return spawnAndExecute(
        allocator,
        opts,
        cwd,
        debug_screen,
        trace_start,
        deadline_ns,
        &harness,
        shell_cmd,
        env_list.items,
    );
}

fn spawnAndExecute(
    allocator: std.mem.Allocator,
    opts: Options,
    cwd: ?[]const u8,
    debug_screen: bool,
    trace_start: i128,
    deadline_ns: i128,
    harness: *const hook_mod.HookHarness,
    shell_cmd: []const u8,
    env_items: []const []const u8,
) RunError!Result {
    std.debug.assert(opts.prompt.len > 0 and harness.nonce.len == hook_mod.nonce_len);
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(
        fifo_z,
        .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true },
        0,
    ) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined,
        .debug = opts.debug,
        .debug_screen = debug_screen,
        .deadline_ns = deadline_ns,
        .dec = .{ .rows = opts.rows, .cols = opts.cols },
    };
    defer shared.deinitBuffers();

    const sink: zmux.native.EventSink = .{ .context = @ptrCast(&shared), .emit = onZmuxEvent };
    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = cwd,
        .env = env_items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch |e| {
        reportFailure(null, debug_screen, "could not start claude under a PTY: {s}", .{@errorName(e)});
        return RunError.SpawnFailed;
    };
    shared.session = session;
    defer session.destroy();

    var runner: SessionRunner = .{
        .allocator = allocator,
        .opts = opts,
        .debug_screen = debug_screen,
        .trace_start = trace_start,
        .deadline_ns = deadline_ns,
        .fifo_fd = fifo_fd,
        .nonce = &harness.nonce,
        .shared = &shared,
        .session = session,
        .resumed = isResumeRun(opts),
        .streaming = opts.output_format == .stream_json and opts.stream_writer != null,
    };
    defer runner.deinit();
    return runner.execute();
}

// -------- tests --------
const testing = std.testing;

test "run: handles 2.1.330 trust dialog, chunked bracketed paste, and resumed transcript isolation end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\
    ++ fixture_relay ++
        \\down=$(printf '\033[B')
        \\enter=$(printf '\r')
        \\printf 'Quick safety check: Is this a project you trust?\r\nreview this folder first.\r\n❯ No, exit\r\n  Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 3)" = "$down" ]
        \\printf '\r  No, exit\r\n❯ Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"previous turn"}]}}' > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\{ printf '\033[200~'; cat prompt; printf '\033[201~\r'; } > expected
        \\read_bytes "$(wc -c < expected | tr -d ' ')" | cmp - expected
        \\hook UserPromptSubmit < submit.json
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"current turn"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"current turn"}' "$file" | hook Stop
        \\
    ;
    {
        const f = try tmp.dir.createFile("mock-claude", .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(fixture);
    }
    const prompt = ("a" ** 511 ++ "🌿\n") ** 6;
    try tmp.dir.writeFile(.{ .sub_path = "prompt", .data = prompt });
    const submit = try std.json.Stringify.valueAlloc(testing.allocator, .{ .prompt = prompt }, .{});
    defer testing.allocator.free(submit);
    try tmp.dir.writeFile(.{ .sub_path = "submit.json", .data = submit });

    const program = try tmp.dir.realpathAlloc(testing.allocator, "mock-claude");
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = prompt,
        .cont = true,
        .timeout_ms = 15_000,
        .output_format = .stream_json,
        .stream_writer = &output.writer,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("current turn", result.summary.final_text);
    try testing.expectEqual(@as(u32, 1), result.summary.num_turns);
    try testing.expect(std.mem.indexOf(u8, output.written(), "current turn") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "previous turn") == null);
}

test "run: fails fast if child exits early without Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\
    ++ fixture_relay ++
        \\printf 'Ready\r\n'
        \\printf '{"transcript_path":"%s/none.jsonl"}' "$PWD" | hook SessionStart
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\exit 1
        \\
    ;
    {
        const f = try tmp.dir.createFile("crash-claude", .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(fixture);
    }
    const program = try tmp.dir.realpathAlloc(testing.allocator, "crash-claude");
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const t0 = std.time.milliTimestamp();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ms = std.time.milliTimestamp() - t0;
    try testing.expectError(RunError.TranscriptUnavailable, err);
    // Must fail fast (well under the 30s timeout).
    try testing.expect(elapsed_ms < 5_000);
}

// -------- Round 1 review fixes --------

fn writeFixture(dir: std.fs.Dir, name: []const u8, body: []const u8) ![]u8 {
    {
        const f = try dir.createFile(name, .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(body);
    }
    return dir.realpathAlloc(testing.allocator, name);
}

/// Count `claude-p-<pid>-*` harness directories left under the temp root.
fn leftoverHarnessDirs() !usize {
    const root = std.posix.getenv("TMPDIR") orelse "/tmp";
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "claude-p-{d}-", .{std.c.getpid()});
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) n += 1;
    }
    return n;
}

test "monotonicNs: never goes backwards and tracks real time" {
    const a = monotonicNs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b - a >= 2 * std.time.ns_per_ms);
    try testing.expect(b - a < 5 * std.time.ns_per_s);
    var prev = b;
    for (0..1000) |_| {
        const now = monotonicNs();
        try testing.expect(now >= prev);
        prev = now;
    }
    // Fits the i64 atomics in SharedState.
    _ = @as(i64, @intCast(prev));
}

test "validateCwd: accepts directories, rejects files, missing paths, and NUL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain", .data = "x" });
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "plain");
    defer testing.allocator.free(file_path);

    try validateCwd(null);
    try validateCwd(dir_path);
    try testing.expectError(RunError.InvalidCwd, validateCwd(file_path));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/nonexistent/claude-p/cwd"));
    try testing.expectError(RunError.InvalidCwd, validateCwd(""));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/tmp\x00/x"));

    // run() refuses before it creates a harness or spawns anything.
    const before = try leftoverHarnessDirs();
    try testing.expectError(RunError.InvalidCwd, run(testing.allocator, .{
        .prompt = "hi",
        .cwd = "/nonexistent/claude-p/cwd",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "resolveClaudeBinaryIn: PATH search, explicit override, and non-executables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("bin/claude-dir");
    try tmp.dir.makePath("shadow/claude"); // a directory named claude is skipped
    try tmp.dir.writeFile(.{ .sub_path = "bin/not-exec", .data = "x" });
    const exe = try writeFixture(tmp.dir, "bin/claude", "#!/bin/sh\n");
    defer testing.allocator.free(exe);
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const path_env = try std.fmt.allocPrint(testing.allocator, "{s}/missing:{s}/empty:{s}/shadow:{s}/bin:/usr/bin", .{ root, root, root, root });
    defer testing.allocator.free(path_env);

    const found = try resolveClaudeBinaryIn(testing.allocator, null, path_env);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(exe, found);

    const by_path = try resolveClaudeBinaryIn(testing.allocator, exe, "");
    defer testing.allocator.free(by_path);
    try testing.expectEqualStrings(exe, by_path);

    const sh = try resolveClaudeBinaryIn(testing.allocator, "sh", "/nonexistent:/bin");
    defer testing.allocator.free(sh);
    const resolved_sh = try std.fs.cwd().realpathAlloc(testing.allocator, "/bin/sh");
    defer testing.allocator.free(resolved_sh);
    try testing.expectEqualStrings(resolved_sh, sh);

    const empty_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty", .{root});
    defer testing.allocator.free(empty_path);
    const not_exec = try std.fmt.allocPrint(testing.allocator, "{s}/bin/not-exec", .{root});
    defer testing.allocator.free(not_exec);
    const a_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin/claude-dir", .{root});
    defer testing.allocator.free(a_dir);
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, null, empty_path));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, not_exec, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, a_dir, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "/nonexistent/claude", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "not-exec", path_env));

    const Ctx = struct {
        fn resolve(allocator: std.mem.Allocator, p_env: []const u8, want: []const u8) !void {
            const got = try resolveClaudeBinaryIn(allocator, null, p_env);
            defer allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.resolve, .{ path_env, exe });
}

test "run: a missing claude binary fails before spawning and leaves no temp dir" {
    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.SpawnFailed, run(testing.allocator, .{
        .prompt = "hi",
        .claude_path = "/nonexistent/claude",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 2 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "buildShellCommand: exec-prefixes the quoted argv" {
    const cmd = try buildShellCommand(testing.allocator, &.{ "/opt/my bin/claude", "--model", "it's" });
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exec '/opt/my bin/claude' '--model' 'it'\\''s'", cmd);
}

test "formatHookTrace: prints the event name and payload size, never the payload" {
    const secret = "{\"prompt\":\"my password is hunter2\",\"last_assistant_message\":\"TOP-SECRET-REPLY\"}";
    var buf: [96]u8 = undefined;
    const line = formatHookTrace(&buf, .user_prompt_submit, secret.len);
    try testing.expectEqualStrings("hook: user_prompt_submit payload_bytes=79", line);
    try testing.expect(std.mem.indexOf(u8, line, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, line, "SECRET") == null);
    // The signature takes a length, so no caller can hand it payload bytes.
    const params = @typeInfo(@TypeOf(formatHookTrace)).@"fn".params;
    try testing.expectEqual(@as(usize, 3), params.len);
    try testing.expect(params[2].type.? == usize);
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("hook: (trace overflow)", formatHookTrace(&tiny, .stop, 1));
}

test "formatFailureScreen: strips escapes, drops blank lines, keeps the last 15 lines within 1024 bytes" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("", formatFailureScreen(&out, ""));
    try testing.expectEqualStrings("", formatFailureScreen(&out, "\r\n \x1b[2J\r\n"));
    try testing.expectEqualStrings(
        "sh: claude: command not found\nbye",
        formatFailureScreen(&out, "\x1b[31msh: claude:\x07 command not found\x1b[0m\r\r\n\r\n   \r\nbye\r\n"),
    );

    var many: std.ArrayList(u8) = .{};
    defer many.deinit(testing.allocator);
    for (0..40) |i| try many.writer(testing.allocator).print("\x1b[1mline {d}\x1b[0m\r\n\r\n", .{i});
    const tail = formatFailureScreen(&out, many.items);
    try testing.expect(std.mem.startsWith(u8, tail, "line 25\n"));
    try testing.expect(std.mem.endsWith(u8, tail, "\nline 39"));
    try testing.expectEqual(@as(usize, 14), std.mem.count(u8, tail, "\n"));

    // One very long line: bounded to 1024 bytes on a UTF-8 boundary.
    const wide = "\xe2\x9d\xaf" ** 2000;
    const cut = formatFailureScreen(&out, wide);
    try testing.expect(cut.len <= failure_screen_max_bytes);
    try testing.expect(cut.len > failure_screen_max_bytes - 4);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "extractSafeTranscriptPath: drops paths with an embedded NUL" {
    const ok = (try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a.jsonl\"}")).?;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("/tmp/a.jsonl", ok);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a\\u0000/../../etc/passwd\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{}")) == null);
}

test "dialogConfirmAllowed: ordinary runs never approve bypass-permissions or dev-channels dialogs" {
    const plain: Options = .{ .prompt = "x" };
    try testing.expect(dialogConfirmAllowed(plain, .trust));
    try testing.expect(dialogConfirmAllowed(plain, .none));
    try testing.expect(!dialogConfirmAllowed(plain, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(plain, .dev_channels));

    // Flags that do not ask for bypass do not unlock it.
    const near: Options = .{
        .prompt = "--dangerously-skip-permissions",
        .permission_mode = "acceptEdits",
        .extra_args = &.{ "--permission-mode", "plan", "--permission-mode=acceptEdits", "bypassPermissions", "--dangerously-skip-permissions-x", "--allow-dangerously-skip-permissions" },
    };
    try testing.expect(!dialogConfirmAllowed(near, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(near, .dev_channels));

    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .permission_mode = "bypassPermissions" }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-skip-permissions"} }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{ "--permission-mode", "bypassPermissions" } }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--permission-mode=bypassPermissions"} }, .bypass_permissions));
    // Bypass intent does not approve development channels, and vice versa.
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .dev_channels));
    const dev: Options = .{ .prompt = "x", .extra_args = &.{ "--dangerously-load-development-channels", "server:x" } };
    try testing.expect(dialogConfirmAllowed(dev, .dev_channels));
    try testing.expect(!dialogConfirmAllowed(dev, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-load-development-channels=server:x"} }, .dev_channels));
}

test "run: refuses an unrequested bypass-permissions dialog without sending a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Any key the driver sends lands in `keys`; the fixture then exits.
    const program = try writeFixture(tmp.dir, "bypass-claude",
        \\#!/bin/sh
        \\stty raw -echo
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\dd bs=1 count=1 > keys 2>/dev/null
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.UnexpectedStartupDialog, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
    const keys = tmp.dir.readFileAlloc(testing.allocator, "keys", 16) catch |e| switch (e) {
        error.FileNotFound => try testing.allocator.dupe(u8, ""),
        else => return e,
    };
    defer testing.allocator.free(keys);
    try testing.expectEqualStrings("", keys);
}

test "run: approves a requested bypass dialog, runs with timeout 0 under exec, and prefers Stop text over a stale transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "bypass-ok-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\echo "$PPID" > ppid
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\
    ++ fixture_relay ++
        \\enter=$(printf '\r')
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\[ "$(read_bytes 1)" = "2" ]
        \\printf '\r  1. No, exit\r\n❯ 2. Yes, I accept\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\: > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\read_bytes 18 > /dev/null
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"stale text"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"fresh text"}' "$file" | hook Stop
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .skip_permissions = true,
        .timeout_ms = 0, // no wall-clock timeout
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("fresh text", result.summary.final_text);
    try testing.expect(!result.summary.is_error);

    // `exec` made the fixture the PTY child itself: its parent is this process.
    const ppid_text = try tmp.dir.readFileAlloc(testing.allocator, "ppid", 32);
    defer testing.allocator.free(ppid_text);
    const ppid = try std.fmt.parseInt(i64, std.mem.trim(u8, ppid_text, " \r\n"), 10);
    try testing.expectEqual(@as(i64, std.c.getpid()), ppid);
}

test "preferStopText: replaces stale text, keeps agreeing text and clears stale error metadata" {
    const a = testing.allocator;
    const make = struct {
        fn summary(text: []const u8, is_error: bool) !transcript_mod.Summary {
            return .{
                .final_text = try testing.allocator.dupe(u8, text),
                .session_id = try testing.allocator.dupe(u8, "s"),
                .is_error = is_error,
                .num_turns = 1,
                .total_cost_usd = 0,
                .duration_api_ms = 0,
                .usage = .{},
                .jsonl_replay = try testing.allocator.dupe(u8, ""),
            };
        }
    }.summary;

    var stale = try make("old answer", false);
    defer stale.deinit(a);
    try preferStopText(a, &stale, "new answer");
    try testing.expectEqualStrings("new answer", stale.final_text);

    var same = try make("answer\n", false);
    defer same.deinit(a);
    try preferStopText(a, &same, " answer");
    try testing.expectEqualStrings("answer\n", same.final_text);

    var no_stop = try make("answer", false);
    defer no_stop.deinit(a);
    try preferStopText(a, &no_stop, null);
    try preferStopText(a, &no_stop, " \n");
    try testing.expectEqualStrings("answer", no_stop.final_text);

    var failed = try make("API Error: 529", true);
    defer failed.deinit(a);
    try preferStopText(a, &failed, "something else");
    try testing.expectEqualStrings("something else", failed.final_text);
    try testing.expect(!failed.is_error);

    // Allocation failure leaves the summary intact.
    var keep = try make("old", false);
    defer keep.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, preferStopText(failing.allocator(), &keep, "new"));
    try testing.expectEqualStrings("old", keep.final_text);
}

test "synthesizeStopFailureSummary: error summary with exit code 1" {
    const Ctx = struct {
        fn check(allocator: std.mem.Allocator, payload: []const u8, want_text: []const u8, want_sid: []const u8) !void {
            var result: Result = .{
                .summary = try synthesizeStopFailureSummary(allocator, payload),
                .duration_ms = 1,
            };
            defer result.deinit(allocator);
            try testing.expect(result.summary.is_error);
            try testing.expectEqual(@as(u8, 1), result.exitCode());
            try testing.expectEqualStrings(want_text, result.summary.final_text);
            try testing.expectEqualStrings(want_sid, result.summary.session_id);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{
        "{\"session_id\":\"abc\",\"last_assistant_message\":\"API Error: overloaded\"}",
        "API Error: overloaded",
        "abc",
    });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{ "{\"last_assistant_message\":\"  \"}", stop_failure_default_text, "" });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{ "not json", stop_failure_default_text, "" });
}

test "run: a StopFailure hook ends the run at once with an error result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "failing-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\
    ++ fixture_relay ++
        \\printf 'Ready ? for shortcuts'
        \\printf '{"session_id":"sess-1"}' | hook SessionStart
        \\dd bs=1 count=18 > /dev/null 2>&1
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '{"session_id":"sess-1","error":"API Error: overloaded"}' | hook StopFailure
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);

    const t0 = monotonicNs();
    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = std.fs.path.dirname(program).?,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(monotonicNs() - t0 < 10 * std.time.ns_per_s);
    try testing.expect(result.summary.is_error);
    try testing.expectEqual(@as(u8, 1), result.exitCode());
    try testing.expectEqualStrings("API Error: overloaded", result.summary.final_text);
    try testing.expectEqualStrings("sess-1", result.summary.session_id);
}

test "pumpStream: a failed stdout write propagates instead of being swallowed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"a\":1}\n{\"b\":2}\npartial" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    {
        var tailer = try stream_mod.Tailer.open(testing.allocator, path);
        defer tailer.deinit();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 2), try pumpStream(&tailer, &out.writer));
        try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", out.written());
        try testing.expectEqual(@as(usize, 0), try pumpStream(&tailer, &out.writer));
    }
    {
        var tailer = try stream_mod.Tailer.open(testing.allocator, path);
        defer tailer.deinit();
        var closed: std.Io.Writer = .failing;
        try testing.expectError(error.WriteFailed, pumpStream(&tailer, &closed));
    }
}

test "onZmuxEvent: stops copying into `recent` after startup and queues complete DEC replies" {
    var shared: SharedState = .{ .session = undefined, .debug = false };
    defer shared.pending_to_pty.deinit(std.heap.page_allocator);
    defer shared.recent.deinit(std.heap.page_allocator);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "hello\x1b[c" } });
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 8), shared.bytes_seen.load(.seq_cst));
    const first_ns = shared.last_output_ns.load(.seq_cst);
    try testing.expect(first_ns != 0);

    shared.startup_done.store(true, .seq_cst);
    std.Thread.sleep(std.time.ns_per_ms);
    // Holding recent_mutex proves the post-startup path never takes it.
    shared.recent_mutex.lock();
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "world\x1b[6n" } });
    shared.recent_mutex.unlock();
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 17), shared.bytes_seen.load(.seq_cst));
    try testing.expect(shared.last_output_ns.load(.seq_cst) > first_ns);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "\x1b[c" ** 100 } });
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R" ++ "\x1b[?1;2c" ** 100, shared.pending_to_pty.items);
}

/// Wait until the fixture has written `dir/pid` (it is running), then interrupt.
fn interruptOnceRunning(dir: std.fs.Dir) void {
    for (0..1000) |_| {
        if (dir.statFile("pid")) |st| {
            if (st.size > 1) break;
        } else |_| {}
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.Thread.sleep(100 * std.time.ns_per_ms);
    requestInterrupt();
}

test "run: requestInterrupt returns Interrupted and cleans up the session and temp dir" {
    defer interrupted.store(false, .seq_cst);
    try testing.expect(!isInterrupted());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "slow-claude",
        \\#!/bin/sh
        \\echo $$ > pid
        \\printf 'Booting\r\n'
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;
    const before = try leftoverHarnessDirs();

    // Mid-run: the signal arrives while run() waits for SessionStart.
    const thread = try std.Thread.spawn(.{}, interruptOnceRunning, .{tmp.dir});
    const t0 = monotonicNs();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ns = monotonicNs() - t0;
    thread.join();
    try testing.expectError(RunError.Interrupted, err);
    try testing.expect(elapsed_ns < 15 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());

    // The PTY child is gone once run() has unwound.
    const pid_text = try tmp.dir.readFileAlloc(testing.allocator, "pid", 32);
    defer testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n"), 10);
    var gone = false;
    for (0..100) |_| {
        std.posix.kill(pid, 0) catch {
            gone = true;
            break;
        };
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try testing.expect(gone);

    try testing.expect(!isInterrupted());
    requestInterrupt();
    // Already interrupted: run() returns before creating anything.
    try testing.expectError(RunError.Interrupted, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

const fixture_relay =
    "relay=$(python3 -c 'import json,shlex,sys; " ++
    "print(shlex.split(json.loads(sys.argv[1])[\"hooks\"][\"Stop\"][0][\"hooks\"][0][\"command\"])[0])' \"$2\")\n" ++
    "hook() { \"$relay\" \"$1\"; }\n";

const fixture_shell =
    \\#!/bin/sh
    \\set -eu
    \\stty raw -echo
    \\[ "$1" = --settings ]
    \\
++ fixture_relay ++
    \\printf 'Ready'
    \\file="$PWD/session.jsonl"
    \\: > "$file"
    \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
    \\dd bs=1 count=18 of=/dev/null 2>/dev/null
    \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
    \\
;

test "run: PermissionRequest fails before Stop timeout and releases the hook harness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"tool_name":"Bash"}' | hook PermissionRequest
        \\sleep 30
    );
    defer testing.allocator.free(exe);
    const before = try leftoverHarnessDirs();
    const started = monotonicNs();
    try testing.expectError(error.PermissionPromptBlocked, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - started < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "run: configured permission and slow Stop hooks can complete the turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{}' | hook PermissionRequest
        \\printf '{"last_assistant_message":"draft"}' | hook Stop
        \\sleep 0.5
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":true}' >> "$file"
        \\sleep 1.65
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}],"usage":{"output_tokens":3}}}' >> "$file"
        \\printf '{"last_assistant_message":"final"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\# Waiting the full fallback after confirmation would consume this later failure.
        \\sleep 0.7
        \\printf '{"error":"late failure"}' | hook StopFailure
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .extra_hooks = &.{ .{ .event = "PermissionRequest", .command = "true" }, .{ .event = "Stop", .command = "sleep 0.5" } },
        .timeout_ms = 8000,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("final", result.summary.final_text);
    try testing.expectEqual(3, result.summary.usage.output_tokens);
}

test "run: continued assistant output supersedes provisional Stop until the second Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "0.03", "0.2" }) |delay| {
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
            \\printf '{"last_assistant_message":"draft"}' | hook Stop
            \\sleep 0.04
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}' >> "$file"
            \\
        ++ "sleep " ++ delay ++ "\n" ++
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"second answer"}],"usage":{"output_tokens":3}}}' >> "$file"
            \\printf '{"last_assistant_message":"second answer","stop_hook_active":true}' | hook Stop
        );
        defer testing.allocator.free(exe);
        var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("second answer", result.summary.final_text);
        try testing.expectEqual(3, result.summary.usage.output_tokens);
        var replay: std.Io.Writer.Allocating = .init(testing.allocator);
        defer replay.deinit();
        try result.write(testing.allocator, &replay.writer, .stream_json);
        try testing.expect(std.mem.indexOf(u8, replay.written(), "tool_use") != null);
    }
}

test "a post-Stop user record only continues a turn when it differs from the current prompt" {
    const line =
        \\{"type":"user","message":{"content":"hello\nworld"}}
    ;
    try testing.expect(!try isContinuationRecord(testing.allocator, line, "done", "hello world"));
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", "different prompt"));
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", null));
}

test "run: late-flushed current user and final assistant records preserve provisional Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock-late-flush", fixture_shell ++
        \\printf '{"last_assistant_message":"PONG"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"  hello  "}]}}' >> "$file"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"}],"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("PONG", result.summary.final_text);
    try testing.expectEqual(@as(u64, 5), result.summary.usage.output_tokens);
}

test "run: resumed transcript path change isolates a matched turn or uses Stop alone" {
    const new_path =
        \\file="$PWD/resumed.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"private history"}]}}' > "$file"
        \\
    ;
    const matched =
        \\printf '%s\n' '{"type":"user","message":{"content":"hello"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}],"usage":{"input_tokens":9}}}' >> "$file"
        \\
    ;
    const stop =
        \\printf '{"transcript_path":"%s","last_assistant_message":"answer"}' "$file" | hook Stop
    ;
    inline for (.{ true, false }) |has_match| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++ new_path ++ (if (has_match) matched else "") ++ stop);
        defer testing.allocator.free(exe);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var result = try run(testing.allocator, .{
            .prompt = "hello",
            .cont = true,
            .cwd = std.fs.path.dirname(exe),
            .claude_path = exe,
            .output_format = .stream_json,
            .stream_writer = &output.writer,
            .timeout_ms = 5000,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("answer", result.summary.final_text);
        try testing.expectEqual(@as(u64, if (has_match) 9 else 0), result.summary.usage.input_tokens);
        try testing.expect(std.mem.indexOf(u8, output.written(), "private history") == null);
    }
}

test "findPromptTurnOffset returns the last matching user entry and rejects unsafe paths" {
    const first = "{\"type\":\"user\",\"message\":{\"content\":\"some text\"}}\r\n{torn\n";
    const last =
        \\{"type":"user","message":{"content":[{"type":"text","text":"  some\r\ntext "}]}}
        \\{"type":"assistant","message":{"content":"some text"}}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.dir, "transcript", first ++ last);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, first.len), findPromptTurnOffset(testing.allocator, path, "some text"));
    try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, path, "different"));
    for ([_][]const u8{ "", "relative", "/a/../b", "/..", "/a\x00b" }) |invalid| {
        try testing.expect(!validateTranscriptPath(invalid));
        try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, invalid, "some text"));
        try testing.expectError(error.InvalidTranscriptPath, transcript_mod.openTranscriptRegularFile(invalid));
    }
}

test "reportFailure includes screen content only with debug screen consent" {
    var shared: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer shared.recent.deinit(std.heap.page_allocator);
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "SENTINEL-startup-secret" } });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture = try tmp.dir.createFile("stderr", .{ .read = true });
    defer capture.close();
    {
        const previous = try std.posix.dup(std.posix.STDERR_FILENO);
        defer std.posix.close(previous);
        try std.posix.dup2(capture.handle, std.posix.STDERR_FILENO);
        defer std.posix.dup2(previous, std.posix.STDERR_FILENO) catch unreachable;
        reportFailure(&shared, false, "startup timeout", .{});
        shared.startup_done.store(true, .seq_cst);
        onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "x" ** 2200 ++ "recent-output" } });
        reportFailure(&shared, true, "stop timeout", .{});
    }
    try capture.seekTo(0);
    const logged = try capture.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "startup timeout") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "SENTINEL") == null);
    try testing.expect(std.mem.indexOf(u8, logged, "recent-output") != null);
}

test "chunked paste observes interrupts and deadlines before the second chunk or Enter" {
    const Sink = struct {
        writes: usize = 0,
        interrupt: bool,
        pub fn writeInput(self: *@This(), _: []const u8) !void {
            self.writes += 1;
            if (self.interrupt and self.writes == 2) requestInterrupt();
        }
    };
    defer clearInterrupt();
    for ([_]bool{ false, true }) |cancel| {
        var sink: Sink = .{ .interrupt = cancel };
        const start = monotonicNs();
        const deadline = start + (if (cancel) @as(i128, 60 * std.time.ns_per_s) else 20 * std.time.ns_per_ms);
        try testing.expectError(if (cancel) error.Interrupted else error.StopTimeout, typePromptUntil(&sink, "x" ** (64 * 1024), std.time.ns_per_s, std.time.ns_per_s, deadline));
        try testing.expect(sink.writes <= 2);
        try testing.expect(monotonicNs() - start < std.time.ns_per_s);
    }
}

test "run validates unsupported library options before spawning" {
    const blocked = [_][]const u8{
        "--bare",                 "--safe-mode",    "--no-session-persistence", "--max-turns",                "--max-budget-usd",
        "--fallback-model",       "--input-format", "--json-schema",            "--include-partial-messages", "--forward-subagent-text",
        "--replay-user-messages", "-p",             "--print",                  "--settings",
    };
    inline for (blocked) |flag| {
        try testing.expectError(error.InvalidOptions, run(testing.allocator, .{ .prompt = "x", .extra_args = &.{flag} }));
        try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .extra_args = &.{flag ++ "=value"} }));
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--system-prompt", flag } });
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--", flag } });
    }
    try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--from-pr", "--print" } });
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .max_turns = 1 }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .fallback_model = "other" }));
}

test "run: blank Stop text without an assistant transcript is unavailable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"last_assistant_message":"  "}' | hook Stop
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptUnavailable, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
    }));
}

test "run: oversized transcript falls back to authoritative Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\dd if=/dev/zero of="$file" bs=1 count=1 seek=67108864 2>/dev/null
        \\printf '{"session_id":"s","last_assistant_message":"done"}' | hook Stop
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("done", result.summary.final_text);
    try testing.expectEqualStrings("s", result.summary.session_id);
    try testing.expectEqualStrings("", result.summary.jsonl_replay);
}

test "run: StopFailure preserves transcript usage and turns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":9}}}' '{"type":"assistant","message":{"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '{"last_assistant_message":"quota reached","error":"generic"}' | hook StopFailure
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expect(result.summary.is_error);
    try testing.expectEqualStrings("quota reached", result.summary.final_text);
    try testing.expectEqual(2, result.summary.num_turns);
    try testing.expectEqual(9, result.summary.usage.input_tokens);
    try testing.expectEqual(5, result.summary.usage.output_tokens);
}

test "shell refuses to exec after a previously validated cwd disappears" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("it's here");
    const cwd = try tmp.dir.realpathAlloc(testing.allocator, "it's here");
    defer testing.allocator.free(cwd);
    const command = try buildShellCommandInDir(testing.allocator, &.{ "/bin/echo", "unexpected" }, cwd);
    defer testing.allocator.free(command);
    try tmp.dir.deleteDir("it's here");
    const res = try std.process.Child.run(.{ .allocator = testing.allocator, .argv = &.{ "/bin/sh", "-c", command } });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(126, res.term.Exited);
    try testing.expectEqualStrings("", res.stdout);
}

test "run: transcript idle timeout waits for PTY progress and ends a silent turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\for i in 1 2 3 4 5 6; do printf .; sleep 0.05; done
        \\touch still-running
        \\sleep 5
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptStalled, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
        .transcript_idle_timeout_ms = 250,
    }));
    try tmp.dir.access("still-running", .{});
}
