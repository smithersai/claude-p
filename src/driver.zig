//! End-to-end driver: spawn `claude` under a zmux NativeSession, drive the UI
//! with our prompt, wait for the Stop hook, and return a Result.
const std = @import("std");
const zmux = @import("zmux");

const args_mod = @import("args.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const hook_mod = @import("hook.zig");
const terminal_mod = @import("terminal.zig");
const stream_mod = @import("stream.zig");

pub const Options = struct {
    prompt: []const u8,
    output_format: args_mod.OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    /// Explicit support for high-value claude flags. These are forwarded to
    /// the child as the corresponding `claude` flag.
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    add_dirs: []const []const u8 = &.{},
    mcp_configs: []const []const u8 = &.{},
    verbose: bool = false,
    timeout_ms: u64 = 300_000,
    /// Override `claude` binary path (testing).
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
    /// When set and `output_format` is `.stream_json`, the driver tails the
    /// session transcript and writes each JSONL line to this writer as it
    /// is flushed by the child `claude`. After Stop, the driver writes the
    /// final `result` envelope and flushes. Result.streamed is set to true
    /// so callers can avoid re-emitting via Result.write.
    stream_writer: ?*std.Io.Writer = null,
};

pub const Result = struct {
    summary: transcript_mod.Summary,
    duration_ms: u64,
    /// True if `run()` already streamed stream-json output to the caller's
    /// `stream_writer`. `Result.write` is a no-op for `.stream_json` in that
    /// case to avoid double-emit.
    streamed: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
    }

    pub fn write(
        self: *const Result,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        fmt: args_mod.OutputFormat,
    ) !void {
        if (self.streamed and fmt == .stream_json) return;
        try emit_mod.emit(allocator, writer, fmt, .{
            .summary = &self.summary,
            .duration_ms = self.duration_ms,
        });
    }

    pub fn exitCode(self: *const Result) u8 {
        return if (self.summary.is_error) 1 else 0;
    }
};

pub const RunError = error{
    SessionStartTimeout,
    StopTimeout,
    PromptNotAccepted,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
} || std.mem.Allocator.Error;

/// Build the argv for the child `claude` invocation.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    binary: []const u8,
    settings_json: []const u8,
    opts: Options,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer argv.deinit(allocator);

    try argv.append(allocator, binary);
    try argv.append(allocator, "--settings");
    try argv.append(allocator, settings_json);
    if (opts.model) |m| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, m);
    }
    if (opts.max_turns) |n| {
        try argv.append(allocator, "--max-turns");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
    }
    if (opts.allowed_tools) |t| {
        try argv.append(allocator, "--allowedTools");
        try argv.append(allocator, t);
    }
    if (opts.skip_permissions) {
        try argv.append(allocator, "--dangerously-skip-permissions");
    }
    if (opts.resume_session) |id| {
        try argv.append(allocator, "--resume");
        try argv.append(allocator, id);
    }
    if (opts.cont) try argv.append(allocator, "--continue");
    if (opts.session_id) |id| {
        try argv.append(allocator, "--session-id");
        try argv.append(allocator, id);
    }
    if (opts.verbose) try argv.append(allocator, "--verbose");

    if (opts.system_prompt) |s| {
        try argv.append(allocator, "--system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.append_system_prompt) |s| {
        try argv.append(allocator, "--append-system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.permission_mode) |s| {
        try argv.append(allocator, "--permission-mode");
        try argv.append(allocator, s);
    }
    if (opts.disallowed_tools) |s| {
        try argv.append(allocator, "--disallowedTools");
        try argv.append(allocator, s);
    }
    if (opts.fallback_model) |s| {
        try argv.append(allocator, "--fallback-model");
        try argv.append(allocator, s);
    }
    if (opts.setting_sources) |s| {
        try argv.append(allocator, "--setting-sources");
        try argv.append(allocator, s);
    }
    for (opts.add_dirs) |d| {
        try argv.append(allocator, "--add-dir");
        try argv.append(allocator, d);
    }
    for (opts.mcp_configs) |c| {
        try argv.append(allocator, "--mcp-config");
        try argv.append(allocator, c);
    }

    for (opts.extra_args) |a| try argv.append(allocator, a);
    return argv;
}

/// Join argv into a single shell-safe command line (single-quoting each arg).
pub fn shellQuoteArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    for (argv, 0..) |a, idx| {
        if (idx > 0) try buf.append(allocator, ' ');
        try shellQuoteOne(allocator, &buf, a);
    }
    return try buf.toOwnedSlice(allocator);
}

fn shellQuoteOne(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

/// How long the PTY output stream must be quiet before we believe Ink has
/// finished its initial render and is ready to accept keystrokes. Smaller
/// values type sooner; too small risks racing Ink's prompt-box draw. Tuned
/// to 80 ms based on observed bursts (the input box renders in <50 ms of
/// continuous output, then goes silent).
pub const ink_quiescence_ms: u64 = 80;

/// Upper bound on how long we'll wait for quiescence. If Ink keeps emitting
/// output past this, we give up and type anyway; in practice the prompt box
/// is always up by then, and the failure mode is identical to the previous
/// fixed-sleep behavior.
pub const ink_max_wait_ms: u64 = 2000;

/// How long to wait between sending the prompt bytes and sending Enter.
/// Ink's bracketed-paste heuristic merges back-to-back writes; without a
/// gap, `\r` lands in the input buffer instead of triggering submit.
pub const ink_enter_debounce_ms: u64 = 120;

/// How long the PTY must be silent before we believe a pre-SessionStart
/// modal dialog (workspace-trust or bypass-permissions) is fully rendered
/// and ready to accept a keystroke. Typing into a mid-transition Ink frame
/// can drop the key — observed when bypass dialog appears <200 ms after we
/// dismiss the trust dialog and our `2` lands on a half-rendered screen.
pub const dialog_quiescence_ms: u64 = 80;

/// After typing the prompt we expect claude to acknowledge it — either the
/// UserPromptSubmit hook fires or the session transcript appears on disk (its
/// first line is the user turn). If neither happens within this window, Ink
/// dropped our keystrokes (the same mid-render key-drop the dialog handling
/// fights) and the turn never started. Tuned well above the sub-second submit
/// latency so we never re-inject a prompt that merely registered late.
pub const prompt_accept_timeout_ms: u64 = 4000;

/// Total prompt (re-)injection attempts before giving up. The first is the
/// normal type after SessionStart; the rest are re-injections. Bounds a fully
/// wedged launch to ~prompt_accept_timeout_ms × max_prompt_injections instead
/// of the full `--timeout`: previously a dropped prompt meant claude-p waited
/// the entire wall-clock cap for a Stop the never-started turn never sends
/// (the 60-minute "StopTimeout" hang).
pub const max_prompt_injections: u32 = 4;

pub const WatchdogAction = enum { wait, reinject, give_up };

/// Prompt-acceptance watchdog decision, factored out as a pure function so the
/// re-inject / give-up policy is unit-testable without a live PTY.
pub fn promptWatchdogAction(accepted: bool, injections: u32, since_typed_ms: i64) WatchdogAction {
    if (accepted) return .wait;
    if (since_typed_ms <= @as(i64, @intCast(prompt_accept_timeout_ms))) return .wait;
    if (injections >= max_prompt_injections) return .give_up;
    return .reinject;
}

test "promptWatchdogAction: accepted always waits" {
    try std.testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, 1, 999_999));
    try std.testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, max_prompt_injections, 999_999));
}

test "promptWatchdogAction: within window waits" {
    try std.testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, 0));
    try std.testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, @intCast(prompt_accept_timeout_ms)));
}

test "promptWatchdogAction: past window with attempts left re-injects" {
    try std.testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, 1, @as(i64, @intCast(prompt_accept_timeout_ms)) + 1));
    try std.testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, max_prompt_injections - 1, 10_000));
}

test "promptWatchdogAction: past window with attempts exhausted gives up" {
    try std.testing.expectEqual(WatchdogAction.give_up, promptWatchdogAction(false, max_prompt_injections, 10_000));
}

/// Block until the child PTY has been quiet for at least `ink_quiescence_ms`,
/// up to a cap of `ink_max_wait_ms`. Replaces the hardcoded "give Ink time
/// to settle" sleep from the original fix — adapts to whatever boot latency
/// the machine actually has.
pub fn waitForInkQuiescent(opts: Options, trace_start: i128, shared: *SharedState) void {
    const quiescence_ns: i64 = @intCast(ink_quiescence_ms * std.time.ns_per_ms);
    const max_ns: i64 = @intCast(ink_max_wait_ms * std.time.ns_per_ms);
    const wait_started: i64 = @intCast(std.time.nanoTimestamp());
    while (true) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        if (now - wait_started > max_ns) {
            traceFmt(opts, trace_start, "Ink readiness wait hit max ({d}ms) — typing anyway", .{ink_max_wait_ms});
            return;
        }
        const last: i64 = shared.last_output_ns.load(.seq_cst);
        if (last != 0 and now - last > quiescence_ns) {
            const since_ms: i64 = @divTrunc(now - last, std.time.ns_per_ms);
            const waited_ms: i64 = @divTrunc(now - wait_started, std.time.ns_per_ms);
            traceFmt(opts, trace_start, "Ink quiescent (output silent for {d}ms, waited {d}ms total)", .{ since_ms, waited_ms });
            return;
        }
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

/// Type the prompt into claude's input box: wait for Ink to settle, send the
/// prompt body, pause so Ink's bracketed-paste heuristic doesn't merge the
/// trailing Enter into the same burst (which drops `\r` into the buffer instead
/// of submitting), then send Enter.
fn typePrompt(session: anytype, opts: Options, trace_start: i128, shared: *SharedState) void {
    waitForInkQuiescent(opts, trace_start, shared);
    session.send(opts.prompt, false) catch {};
    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
    session.send("", true) catch {};
}

/// Re-inject the prompt after a dropped first attempt. Sends Ctrl-U first to
/// clear any residual input, so a first attempt whose body landed but whose
/// Enter was dropped doesn't concatenate into "/review …/review …".
fn reinjectPrompt(session: anytype, opts: Options, trace_start: i128, shared: *SharedState) void {
    session.send("\x15", false) catch {}; // Ctrl-U: clear the input line
    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
    typePrompt(session, opts, trace_start, shared);
}

/// Emit a debug-gated trace line to stderr with the elapsed time since
/// `start`. Lets the user pinpoint where the latency in a `--debug` run is
/// going: hook harness setup, claude/Ink boot, first transcript flush, etc.
fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

// Thread-shared state between the NativeSession reader thread and the
// driver's main loop.
pub const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    // Bytes the DEC responder wants written back to the PTY. Mutex-guarded.
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Timestamp (ns since arbitrary epoch — std.time.nanoTimestamp, truncated
    /// to i64). Used by the main loop to decide when Ink has gone quiescent
    /// (UI rendering done) and is therefore ready to accept keystrokes —
    /// replaces a previous hardcoded 1500 ms sleep. Stored as i64 because
    /// Zig's atomic load/store doesn't support 128-bit integers on all
    /// targets (e.g. x86_64-linux-musl); i64 ns gives ~292 years of range,
    /// vastly more than we need.
    last_output_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Rolling buffer of recently-seen output. The driver loop scans this
    // for the workspace-trust dialog (shown in unfamiliar directories,
    // not bypassed by --dangerously-skip-permissions) and dismisses it
    // by pressing Enter.
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    trust_dismissed: bool = false,
    bypass_perms_accepted: bool = false,
    dev_channels_confirmed: bool = false,
};

pub const recent_capacity: usize = 8192;

pub fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
            shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
            // Run the DEC-query responder; queue responses for the main loop.
            var resp: std.ArrayList(u8) = .{};
            defer resp.deinit(std.heap.page_allocator);
            terminal_mod.respondToDecQueries(std.heap.page_allocator, po.data, &resp) catch {};
            if (resp.items.len > 0) {
                shared.write_mutex.lock();
                shared.pending_to_pty.appendSlice(std.heap.page_allocator, resp.items) catch {};
                shared.write_mutex.unlock();
            }
            // Update the rolling recent-output buffer for trust-dialog
            // detection in the main loop.
            shared.recent_mutex.lock();
            shared.recent.appendSlice(std.heap.page_allocator, po.data) catch {};
            if (shared.recent.items.len > recent_capacity) {
                const drop = shared.recent.items.len - recent_capacity;
                std.mem.copyForwards(
                    u8,
                    shared.recent.items[0 .. recent_capacity],
                    shared.recent.items[drop..],
                );
                shared.recent.shrinkRetainingCapacity(recent_capacity);
            }
            shared.recent_mutex.unlock();
            if (shared.debug) std.debug.print("zmux pane_output: {d} bytes\n", .{po.data.len});
        },
        .session_exited => |se| {
            shared.exited.store(true, .seq_cst);
            if (shared.debug) std.debug.print("zmux session_exited: code={?d} signal={?d}\n", .{ se.exit_code, se.signal });
        },
        .pane_activity, .pane_bell, .foreground_changed => {},
    }
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;

    const trace_start: i128 = std.time.nanoTimestamp();
    trace(opts, trace_start, "run() entered");

    var harness = try hook_mod.create(allocator);
    defer harness.deinit();
    trace(opts, trace_start, "hook harness ready (FIFO + relay script + --settings)");

    const claude_bin = opts.claude_path orelse "claude";

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer {
        // Some entries (max-turns) are heap-allocated by buildArgv. We can't
        // tell which without tracking, so we just leak the small strings —
        // the process is short-lived. (TODO: refactor buildArgv to track
        // owned entries.)
        argv.deinit(allocator);
    }

    const shell_cmd = try shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    // Compose env: forward the FIFO path; force TERM; include the existing
    // environment so PATH etc. is preserved.
    var env_list: std.ArrayList([]const u8) = .{};
    defer {
        for (env_list.items) |s| allocator.free(s);
        env_list.deinit(allocator);
    }
    // Inherit existing environment.
    var env_iter = try std.process.getEnvMap(allocator);
    defer env_iter.deinit();
    var it = env_iter.iterator();
    while (it.next()) |e| {
        try env_list.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }),
        );
    }
    try env_list.append(
        allocator,
        try std.fmt.allocPrint(allocator, "CLAUDE_P_FIFO={s}", .{harness.fifo_path}),
    );
    try env_list.append(allocator, try allocator.dupe(u8, "TERM=xterm-256color"));

    // Open the FIFO for reading BEFORE spawning so the child's hook never
    // blocks trying to open the write side.
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined, // set after create
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
        .emit = onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = opts.cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return RunError.SpawnFailed;
    shared.session = session;
    defer session.destroy();
    trace(opts, trace_start, "zmux session spawned; child claude PID up, Ink booting");

    const start_ns: i128 = trace_start;
    var state: enum { waiting_for_ready, awaiting_stop } = .waiting_for_ready;
    var first_emit_logged = false;
    var total_lines_streamed: usize = 0;

    // Prompt-acceptance tracking (see promptWatchdogAction). After the prompt
    // is typed we confirm claude actually received it; if not, we re-inject.
    var prompt_typed_ns: i128 = 0;
    var prompt_injections: u32 = 0;
    var prompt_accepted = false;

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var stop_payload_owned: ?[]u8 = null;
    defer if (stop_payload_owned) |p| allocator.free(p);

    // Live transcript tailer. Opened lazily once we learn `transcript_path`
    // (typically from the SessionStart hook payload). Only used when the
    // caller requested stream-json output AND supplied a writer.
    //
    // The transcript_path arrives in the SessionStart payload but the file
    // itself may not exist on disk until claude flushes its first line —
    // so opening can fail at SessionStart and needs to be retried in the
    // main loop until it succeeds. Without this retry the streaming path
    // degenerates to a single post-Stop dump, which is the "12s of silence
    // then everything at once" symptom users see.
    const streaming = opts.output_format == .stream_json and opts.stream_writer != null;
    var tailer: ?stream_mod.Tailer = null;
    defer if (tailer) |*t| t.deinit();
    var tailer_open_attempts: u32 = 0;

    while (true) {
        const now: i128 = std.time.nanoTimestamp();
        const elapsed_ms: u64 = @intCast(@divTrunc(now - start_ns, std.time.ns_per_ms));
        if (elapsed_ms > opts.timeout_ms) {
            if (state == .waiting_for_ready) return RunError.SessionStartTimeout;
            return RunError.StopTimeout;
        }
        if (shared.exited.load(.seq_cst) and state == .waiting_for_ready) {
            return RunError.SpawnFailed;
        }

        // Flush any DEC-responder bytes back to the PTY.
        shared.write_mutex.lock();
        const to_write = if (shared.pending_to_pty.items.len > 0)
            try allocator.dupe(u8, shared.pending_to_pty.items)
        else
            null;
        if (to_write != null) shared.pending_to_pty.clearRetainingCapacity();
        shared.write_mutex.unlock();
        if (to_write) |bytes| {
            session.writeInput(bytes) catch {};
            allocator.free(bytes);
        }

        // Pre-SessionStart dialog detection. Claude shows several modal
        // prompts that block startup *before* SessionStart hooks register
        // and that are not bypassed by --dangerously-skip-permissions.
        // Detect by substring on the stripped (CSI-removed) recent buffer
        // — after stripping CSI, words concatenate because the dialog
        // separates them with `\033[1C` cursor-move rather than spaces,
        // so we look for multi-distinct-word markers.
        //
        // The two detections are independent (both run per iteration) but
        // guarded by a per-iteration `fired` flag so at most ONE keystroke
        // is sent in a single loop pass. The rolling 8 KB `recent` buffer
        // keeps BOTH dialogs' text once claude transitions from trust →
        // bypass; without the `fired` guard, the same iteration that first
        // fires the trust dismiss could also fire the bypass accept, sending
        // `2`+Enter into a screen that is still mid-transition. Ink drops
        // those keys, claude stays on the dialog, and SessionStart never
        // fires.
        //
        // Independent (not else-if) because the dialogs are independent:
        // a directory whose trust state is already persisted will skip the
        // trust dialog entirely and go straight to bypass — `else if`
        // would deadlock that case because `trust_dismissed` stays false
        // forever, blocking bypass detection from ever running.
        //
        // Each detection also requires PTY quiescence (≥ dialog_quiescence_ms
        // since the last output byte) before sending a keystroke, so we
        // don't type into a partially-rendered Ink frame.
        if (state == .waiting_for_ready and (!shared.trust_dismissed or !shared.bypass_perms_accepted or !shared.dev_channels_confirmed)) {
            shared.recent_mutex.lock();
            const stripped = try stripCsi(allocator, shared.recent.items);
            shared.recent_mutex.unlock();
            defer allocator.free(stripped);

            const last_out: i64 = shared.last_output_ns.load(.seq_cst);
            const now_ns: i64 = @intCast(std.time.nanoTimestamp());
            const quiescence_ns: i64 = @intCast(dialog_quiescence_ms * std.time.ns_per_ms);
            const quiescent = last_out != 0 and (now_ns - last_out) > quiescence_ns;
            var fired_this_iter = false;

            // 1. Workspace-trust dialog: "Is this a project you trust?
            //    1. Yes, I trust this folder / 2. No, exit"
            //    Default selection = option 1 (Yes). Enter accepts.
            if (!shared.trust_dismissed and !fired_this_iter) {
                const has_trust = std.mem.indexOf(u8, stripped, "trust") != null;
                const has_folder = std.mem.indexOf(u8, stripped, "folder") != null;
                if (has_trust and has_folder and quiescent) {
                    trace(opts, trace_start, "workspace-trust dialog detected — sending Enter to dismiss");
                    session.send("", true) catch {};
                    shared.trust_dismissed = true;
                    fired_this_iter = true;
                    // Reset the rolling buffer so the next dialog (bypass)
                    // is detected only after its own bytes arrive — without
                    // this, the trust dialog text lingers in the 8 KB window
                    // and can interfere with subsequent state tracking.
                    shared.recent_mutex.lock();
                    shared.recent.clearRetainingCapacity();
                    shared.recent_mutex.unlock();
                    // Force a fresh quiescence wait before the next dialog
                    // fires — claude is about to repaint.
                    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
                }
            }

            // 2. Bypass-permissions accept dialog: "WARNING: Claude Code
            //    running in Bypass Permissions mode ... By proceeding,
            //    you accept all responsibility ... 1. No, exit / 2. Yes,
            //    I accept". Triggered by --dangerously-skip-permissions
            //    when the user (or this session's persisted state) hasn't
            //    accepted it before. Default selection = option 1 (No),
            //    which exits claude — so we MUST type "2" to move to the
            //    safe option, THEN Enter to confirm.
            if (!shared.bypass_perms_accepted and !fired_this_iter) {
                const has_bypass = std.mem.indexOf(u8, stripped, "Bypass") != null or
                    std.mem.indexOf(u8, stripped, "bypass") != null;
                const has_permissions = std.mem.indexOf(u8, stripped, "Permissions") != null or
                    std.mem.indexOf(u8, stripped, "permissions") != null;
                const has_accept = std.mem.indexOf(u8, stripped, "accept") != null;
                if (has_bypass and has_permissions and has_accept and quiescent) {
                    trace(opts, trace_start, "bypass-permissions accept dialog detected — sending '2' + Enter to accept");
                    // Send "2" to select "Yes, I accept", then Enter. Gap
                    // matches the prompt+Enter case (ink_enter_debounce_ms);
                    // shorter gaps (e.g. 50 ms) sometimes get merged by
                    // Ink's bracketed-paste heuristic and the Enter lands
                    // in the dialog's text field instead of confirming.
                    session.send("2", false) catch {};
                    std.Thread.sleep(ink_enter_debounce_ms * std.time.ns_per_ms);
                    session.send("", true) catch {};
                    shared.bypass_perms_accepted = true;
                    fired_this_iter = true;
                    shared.recent_mutex.lock();
                    shared.recent.clearRetainingCapacity();
                    shared.recent_mutex.unlock();
                    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
                }
            }

            // 3. Development-channels confirmation dialog (triggered by
            //    --dangerously-load-development-channels). Screen reads:
            //      "WARNING: Loading development channels ...
            //       ❯ 1. I am using this for local development
            //         2. Exit
            //       Enter to confirm · Esc to cancel"
            //    Default selection = option 1, so a bare Enter accepts.
            if (!shared.dev_channels_confirmed and !fired_this_iter) {
                const has_loading = std.mem.indexOf(u8, stripped, "Loading") != null;
                const has_development = std.mem.indexOf(u8, stripped, "development") != null;
                const has_channels = std.mem.indexOf(u8, stripped, "channels") != null;
                if (has_loading and has_development and has_channels and quiescent) {
                    trace(opts, trace_start, "dev-channels dialog detected — sending Enter to confirm");
                    session.send("", true) catch {};
                    shared.dev_channels_confirmed = true;
                    fired_this_iter = true;
                    shared.recent_mutex.lock();
                    shared.recent.clearRetainingCapacity();
                    shared.recent_mutex.unlock();
                    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
                }
            }
        }

        // Drain the FIFO.
        const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => 0,
        };
        if (fifo_n > 0) {
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, fifo_buf.items, '\n') orelse break;
                const line = fifo_buf.items[0..nl];
                if (hook_mod.parseLine(line)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s} payload={s}\n", .{ @tagName(ev.event), ev.payload });
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired (Ink is up)");
                            // SessionStart payloads carry the transcript
                            // path. Stash it unconditionally: the streaming
                            // tailer needs it, and the prompt-acceptance
                            // watchdog uses the file's appearance on disk as
                            // proof claude received the prompt.
                            if (transcript_path == null) {
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path from SessionStart: {s}", .{p});
                                }
                            }
                            if (state == .waiting_for_ready) {
                                traceFmt(opts, trace_start, "typing prompt ({d} bytes)", .{opts.prompt.len});
                                typePrompt(session, opts, trace_start, &shared);
                                trace(opts, trace_start, "prompt + Enter sent; confirming acceptance");
                                prompt_typed_ns = std.time.nanoTimestamp();
                                prompt_injections = 1;
                                state = .awaiting_stop;
                            }
                        },
                        .user_prompt_submit => {
                            trace(opts, trace_start, "UserPromptSubmit hook fired (prompt accepted)");
                            prompt_accepted = true;
                        },
                        .stop => {
                            trace(opts, trace_start, "Stop hook fired (assistant turn finished)");
                            if (transcript_path == null) {
                                transcript_path = try hook_mod.extractTranscriptPath(allocator, ev.payload);
                            }
                            stop_payload_owned = try allocator.dupe(u8, ev.payload);
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
                if (stop_payload_owned != null) break;
            }
        }

        // Prompt-acceptance watchdog. If claude never acknowledged the prompt
        // (no UserPromptSubmit hook and no transcript on disk), Ink dropped our
        // keystrokes — re-inject, then fail fast rather than wait the full
        // `--timeout` for a Stop that a never-started turn will never send.
        if (state == .awaiting_stop and stop_payload_owned == null) {
            if (!prompt_accepted) {
                if (transcript_path) |p| {
                    if (std.fs.cwd().access(p, .{})) |_| {
                        prompt_accepted = true;
                    } else |_| {}
                }
            }
            const since_typed_ms: i64 = @intCast(@divTrunc(now - prompt_typed_ns, std.time.ns_per_ms));
            switch (promptWatchdogAction(prompt_accepted, prompt_injections, since_typed_ms)) {
                .wait => {},
                .reinject => {
                    traceFmt(opts, trace_start, "prompt unacknowledged after {d}ms — re-injecting (attempt {d}/{d})", .{ since_typed_ms, prompt_injections + 1, max_prompt_injections });
                    reinjectPrompt(session, opts, trace_start, &shared);
                    prompt_injections += 1;
                    prompt_typed_ns = std.time.nanoTimestamp();
                },
                .give_up => {
                    traceFmt(opts, trace_start, "prompt not accepted after {d} injection(s) — aborting", .{prompt_injections});
                    return RunError.PromptNotAccepted;
                },
            }
        }

        // Open the tailer as soon as the transcript file shows up on disk.
        // claude writes `transcript_path` into the SessionStart payload
        // before it has actually created the file; we keep retrying so we
        // can start emitting from the very first line `claude` writes.
        if (streaming and tailer == null) {
            if (transcript_path) |p| {
                tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(allocator, p)) |t| {
                    tailer = t;
                    traceFmt(opts, trace_start, "transcript opened for tailing after {d} attempt(s): {s}", .{ tailer_open_attempts, p });
                } else |e| switch (e) {
                    error.FileNotFound => {
                        // Expected; keep trying.
                        if (tailer_open_attempts == 1) {
                            traceFmt(opts, trace_start, "transcript not yet on disk; retrying (path={s})", .{p});
                        }
                    },
                    else => {
                        traceFmt(opts, trace_start, "transcript open failed: {s}", .{@errorName(e)});
                    },
                }
            }
        }

        // Pump any new transcript bytes to the caller's stream_writer.
        if (streaming and tailer != null and opts.stream_writer != null) {
            const n = tailer.?.pump(opts.stream_writer.?) catch 0;
            if (n > 0) {
                opts.stream_writer.?.flush() catch {};
                total_lines_streamed += n;
                if (!first_emit_logged) {
                    traceFmt(opts, trace_start, "first transcript line streamed ({d} line(s) in first flush)", .{n});
                    first_emit_logged = true;
                } else {
                    traceFmt(opts, trace_start, "streamed {d} more line(s) (total={d})", .{ n, total_lines_streamed });
                }
            }
        }

        if (stop_payload_owned != null) break;

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Final pump — Claude flushes the last assistant message after Stop fires.
    if (streaming and opts.stream_writer != null) {
        trace(opts, trace_start, "draining post-Stop transcript flush window (20 × 20ms)");
        // The Stop event may have arrived before claude flushed the trailing
        // transcript line. If we haven't opened a Tailer yet (transcript_path
        // only arrived via Stop), do it now.
        if (tailer == null) {
            if (transcript_path) |p| tailer = stream_mod.Tailer.open(allocator, p) catch null;
        }
        if (tailer != null) {
            // Retry briefly to catch the final-flush window (same race the
            // parseFile fallback below handles).
            var attempt: u32 = 0;
            var post_stop_lines: usize = 0;
            while (attempt < 20) : (attempt += 1) {
                const n = tailer.?.pump(opts.stream_writer.?) catch 0;
                post_stop_lines += n;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
            opts.stream_writer.?.flush() catch {};
            traceFmt(opts, trace_start, "post-Stop drain streamed {d} more line(s)", .{post_stop_lines});
        }
    }

    const tp = transcript_path orelse return RunError.TranscriptUnavailable;

    // The Stop hook can fire a few milliseconds before claude flushes the
    // assistant message line into the transcript JSONL. Retry briefly, then
    // fall back to `last_assistant_message` from the Stop payload.
    var summary = blk: {
        var attempt: u32 = 0;
        while (attempt < 40) : (attempt += 1) {
            var maybe = transcript_mod.parseFile(allocator, tp) catch |e| switch (e) {
                error.NoAssistantMessage, error.FileNotFound => null,
                else => return e,
            };
            if (maybe) |valid| {
                // If the assistant text is empty but no error was reported,
                // we likely read the transcript before the final text-block
                // assistant message was flushed (the early lines only have
                // thinking + tool_use blocks). Retry until text appears.
                if (valid.final_text.len > 0 or valid.is_error) break :blk valid;
                maybe.?.deinit(allocator);
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (stop_payload_owned) |payload| {
            const last = try hook_mod.extractLastAssistantMessage(allocator, payload);
            if (last) |text| {
                const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
                break :blk transcript_mod.Summary{
                    .final_text = text,
                    .session_id = sid,
                    .is_error = false,
                    .num_turns = 1,
                    .total_cost_usd = 0.0,
                    .duration_api_ms = 0,
                    .usage = .{},
                    .jsonl_replay = try allocator.dupe(u8, ""),
                };
            }
        }
        return RunError.TranscriptUnavailable;
    };
    errdefer summary.deinit(allocator);

    // Tear down the child immediately — we already have the answer.
    session.terminate();

    const total_ns: i128 = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(total_ns, std.time.ns_per_ms));

    // If we streamed transcript JSONL live, append the trailing `result`
    // envelope (the same final line `claude -p --output-format stream-json`
    // emits) so the wire format is complete.
    var streamed = false;
    if (streaming) {
        if (opts.stream_writer) |w| {
            try emit_mod.emitJson(allocator, w, .{
                .summary = &summary,
                .duration_ms = duration_ms,
            });
            w.flush() catch {};
            streamed = true;
            trace(opts, trace_start, "result envelope emitted; stream done");
        }
    }

    traceFmt(opts, trace_start, "run() returning (total_lines_streamed={d}, duration={d}ms)", .{ total_lines_streamed, duration_ms });
    return Result{
        .summary = summary,
        .duration_ms = duration_ms,
        .streamed = streamed,
    };
}

/// Strip CSI / OSC / DCS escape sequences, leaving only literal payload.
/// Used to make plain-text substring matching (e.g. trust-dialog detection)
/// robust against cursor-positioning escapes that pad words with `\033[1C`.
pub fn stripCsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b != 0x1b) {
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        if (i + 1 >= bytes.len) break;
        const next = bytes[i + 1];
        switch (next) {
            '[' => {
                i += 2;
                while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
                if (i < bytes.len) i += 1; // final byte
            },
            ']' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            'P', 'X', '^', '_' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            else => {
                i += 2;
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

// -------- tests --------

const testing = std.testing;

test "buildArgv: minimal" {
    var argv = try buildArgv(testing.allocator, "/bin/claude", "{}", .{
        .prompt = "hi",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("/bin/claude", argv.items[0]);
    try testing.expectEqualStrings("--settings", argv.items[1]);
    try testing.expectEqualStrings("{}", argv.items[2]);
}

test "buildArgv: with model + verbose" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .model = "opus",
        .verbose = true,
    });
    defer argv.deinit(testing.allocator);
    var saw_model = false;
    var saw_verbose = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--model")) saw_model = true;
        if (std.mem.eql(u8, a, "--verbose")) saw_verbose = true;
    }
    try testing.expect(saw_model);
    try testing.expect(saw_verbose);
}

test "buildArgv: dangerously-skip-permissions" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .skip_permissions = true,
    });
    defer argv.deinit(testing.allocator);
    var saw = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) saw = true;
    }
    try testing.expect(saw);
}

test "buildArgv: passthrough extra args" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .extra_args = &.{ "--include-hook-events", "--bare" },
    });
    defer argv.deinit(testing.allocator);
    var saw_hook = false;
    var saw_bare = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--include-hook-events")) saw_hook = true;
        if (std.mem.eql(u8, a, "--bare")) saw_bare = true;
    }
    try testing.expect(saw_hook);
    try testing.expect(saw_bare);
}

test "buildArgv: system-prompt + permission-mode forwarded" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .system_prompt = "Be terse",
        .permission_mode = "acceptEdits",
        .disallowed_tools = "Bash(rm *)",
    });
    defer argv.deinit(testing.allocator);

    var saw_sysp = false;
    var saw_sysv = false;
    var saw_pm = false;
    var saw_pmv = false;
    var saw_dt = false;
    var saw_dtv = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--system-prompt")) saw_sysp = true;
        if (std.mem.eql(u8, a, "Be terse")) saw_sysv = true;
        if (std.mem.eql(u8, a, "--permission-mode")) saw_pm = true;
        if (std.mem.eql(u8, a, "acceptEdits")) saw_pmv = true;
        if (std.mem.eql(u8, a, "--disallowedTools")) saw_dt = true;
        if (std.mem.eql(u8, a, "Bash(rm *)")) saw_dtv = true;
    }
    try testing.expect(saw_sysp and saw_sysv);
    try testing.expect(saw_pm and saw_pmv);
    try testing.expect(saw_dt and saw_dtv);
}

test "buildArgv: add-dirs + mcp-configs emit each entry as a flag pair" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .add_dirs = &.{ "/a", "/b" },
        .mcp_configs = &.{"server.json"},
    });
    defer argv.deinit(testing.allocator);

    var add_count: u32 = 0;
    var mcp_count: u32 = 0;
    for (argv.items, 0..) |a, idx| {
        if (std.mem.eql(u8, a, "--add-dir")) {
            add_count += 1;
            try testing.expect(idx + 1 < argv.items.len);
        }
        if (std.mem.eql(u8, a, "--mcp-config")) mcp_count += 1;
    }
    try testing.expectEqual(@as(u32, 2), add_count);
    try testing.expectEqual(@as(u32, 1), mcp_count);
}

test "shellQuoteArgv: simple" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "echo", "hi" });
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'echo' 'hi'", q);
}

test "shellQuoteArgv: embeds single-quote" {
    const q = try shellQuoteArgv(testing.allocator, &.{"can't"});
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'can'\\''t'", q);
}

test "shellQuoteArgv: json with double quotes survives" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "claude", "--settings", "{\"hooks\":{}}" });
    defer testing.allocator.free(q);
    // Round-trip via sh -c
    try testing.expect(std.mem.indexOf(u8, q, "{\"hooks\":{}}") != null);
}

test "run: empty prompt rejected" {
    try testing.expectError(RunError.NoPromptSupplied, run(testing.allocator, .{ .prompt = "" }));
}
