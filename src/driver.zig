//! End-to-end single-shot PTY session driver for interactive Claude Code.
const std = @import("std");
const zmux = @import("zmux");
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
/// Provisional Stop confirmation and final summary resolution.
pub const finalizer = @import("driver/finalizer.zig");
/// Active single-shot session loop, hook-event state machine, and turn orchestration.
pub const session = @import("driver/session.zig");

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
/// Stateful event loop driving one single-shot PTY session.
pub const SessionRunner = session.SessionRunner;

/// Execute a single-shot Claude Code PTY session with interrupt scoping and full cleanup.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!Result {
    std.debug.assert(opts.rows > 0 and opts.cols > 0);
    const scope = InterruptScope.enter();
    defer scope.exit();
    return runSession(allocator, opts) catch |err| {
        if (err == error.Interrupted) clearInterrupt();
        return err;
    };
}

fn runSession(caller_allocator: std.mem.Allocator, opts: Options) RunError!Result {
    std.debug.assert(opts.rows > 0 and opts.cols > 0);
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
    std.debug.assert(harness.nonce.len == hook_mod.nonce_len);
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
    std.debug.assert(fifo_fd >= 0);

    var shared: SharedState = .{
        .session = undefined,
        .debug = opts.debug,
        .debug_screen = debug_screen,
        .deadline_ns = deadline_ns,
        .dec = .{ .rows = opts.rows, .cols = opts.cols },
    };
    defer shared.deinitBuffers();

    const sink: zmux.native.EventSink = .{ .context = @ptrCast(&shared), .emit = runtime.onZmuxEvent };
    const pty = zmux.NativeSession.create(allocator, .{
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
    shared.session = pty;
    defer pty.destroy();

    var runner = SessionRunner.init(.{
        .allocator = allocator,
        .opts = opts,
        .debug_screen = debug_screen,
        .trace_start = trace_start,
        .deadline_ns = deadline_ns,
        .fifo_fd = fifo_fd,
        .nonce = &harness.nonce,
        .shared = &shared,
        .session = pty,
        .resumed = isResumeRun(opts),
        .streaming = opts.output_format == .stream_json and opts.stream_writer != null,
    });
    defer runner.deinit();
    return runner.execute();
}

// -------- tests --------
const testing = std.testing;

test "run: rejects empty prompt before spawning" {
    try testing.expectError(RunError.NoPromptSupplied, run(testing.allocator, .{ .prompt = "" }));
}

test "run: rejects invalid cwd before spawning" {
    try testing.expectError(RunError.InvalidCwd, run(testing.allocator, .{ .prompt = "hi", .cwd = "/nonexistent/x" }));
}

test "run: rejects unsupported options before spawning" {
    try testing.expectError(RunError.InvalidOptions, run(testing.allocator, .{ .prompt = "hi", .max_turns = 2 }));
}

test "run: rejects missing claude binary cleanly" {
    try testing.expectError(RunError.SpawnFailed, run(testing.allocator, .{
        .prompt = "hi",
        .claude_path = "/nonexistent/claude-bin",
    }));
}

test "run: rejects invalid extra settings JSON" {
    try testing.expectError(RunError.InvalidExtraSettings, run(testing.allocator, .{
        .prompt = "hi",
        .extra_settings_json = "{not json",
    }));
}

test "run: honors pre-set interrupt before spawning" {
    requestInterrupt();
    defer clearInterrupt();
    try testing.expectError(RunError.Interrupted, run(testing.allocator, .{ .prompt = "hi" }));
}

test "monotonicNs: never goes backwards" {
    const a = monotonicNs();
    const b = monotonicNs();
    try testing.expect(b >= a);
}

test "buildShellCommand: exec-prefixes quoted argv" {
    const cmd = try buildShellCommand(testing.allocator, &.{ "/opt/my bin/claude", "--model", "it's" });
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exec '/opt/my bin/claude' '--model' 'it'\\''s'", cmd);
}

test "formatHookTrace: prints event name and byte count only" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: stop payload_bytes=42", formatHookTrace(&buf, .stop, 42));
}

test "formatFailureScreen: strips escapes and drops blanks" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("err\nbye", formatFailureScreen(&out, "\x1b[31merr\x1b[0m\r\n\r\nbye\r\n"));
}

test "extractSafeTranscriptPath: drops NUL paths" {
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a\\u0000b\"}")) == null);
    const ok = (try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a.jsonl\"}")).?;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("/tmp/a.jsonl", ok);
}

test "dialogConfirmAllowed: gates bypass and dev-channels explicitly" {
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x" }, .trust));
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "x" }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .bypass_permissions));
}

test "preferStopText: replaces stale summary text" {
    var s: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "old"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .is_error = false,
        .num_turns = 1,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer s.deinit(testing.allocator);
    try preferStopText(testing.allocator, &s, "new");
    try testing.expectEqualStrings("new", s.final_text);
}

test "synthesizeStopFailureSummary: returns error summary" {
    var sum = try synthesizeStopFailureSummary(testing.allocator, "{\"session_id\":\"s\",\"error\":\"529\"}");
    defer sum.deinit(testing.allocator);
    try testing.expect(sum.is_error);
    try testing.expectEqualStrings("529", sum.final_text);
}

test "isContinuationRecord: ignores matching user prompt" {
    const line = "{\"type\":\"user\",\"message\":{\"content\":\"hello world\"}}";
    try testing.expect(!try isContinuationRecord(testing.allocator, line, "done", "hello world"));
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", "other"));
}

test "onZmuxEvent: queues DEC replies and tracks byte count" {
    var shared: SharedState = .{ .session = undefined, .debug = false };
    defer shared.deinitBuffers();
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "hi\x1b[c" } });
    try testing.expectEqualStrings("\x1b[?1;2c", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 5), shared.bytes_seen.load(.seq_cst));
}

test "pumpStream: writes complete lines and propagates write error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"a\":1}\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var tailer = try stream_mod.Tailer.open(testing.allocator, path);
    defer tailer.deinit();
    var closed: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, pumpStream(&tailer, &closed));
}

test "isResumeRun: true for cont or resume_session" {
    try testing.expect(!isResumeRun(.{ .prompt = "x" }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .cont = true }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .resume_session = "id" }));
}

test "validateTranscriptPath: accepts clean absolute paths" {
    try testing.expect(validateTranscriptPath("/tmp/session.jsonl"));
    try testing.expect(!validateTranscriptPath("relative.jsonl"));
    try testing.expect(!validateTranscriptPath("/tmp/../etc/passwd"));
}

test "promptWatchdogAction: waits, reinjects, then gives up" {
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, 1, 99_999));
    try testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, 1, prompt_accept_timeout_ms + 1));
    try testing.expectEqual(WatchdogAction.give_up, promptWatchdogAction(false, max_prompt_injections, prompt_accept_timeout_ms + 1));
}
