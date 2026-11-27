//! `claude-p` CLI entry point. Parses argv, runs the driver, emits output.
const std = @import("std");
const builtin = @import("builtin");
const claude_p = @import("claude_p");

/// Signal number caught by `onSignal`, or 0. Read after `run` unwinds so
/// the process exits `128 + sig` once the PTY and temp dir are cleaned up.
var received_signal = std.atomic.Value(u32).init(0);

/// Monotonic time of the first signal, or 0 until `onSignal` stamps it.
var first_signal_ns = std.atomic.Value(u64).init(0);

var signal_mode_daemon = std.atomic.Value(bool).init(false);

/// A later signal escalates to the default action only this long after the
/// first. Ctrl-C and `kill -INT -<pgid>` reach claude-p twice within
/// milliseconds when it runs under `bin/claude-p.js`: once from the kernel
/// (same process group) and once forwarded by the launcher. Treating that
/// duplicate as "the unwind is stuck" killed the process before `run`'s
/// `defer`s removed `$TMPDIR/claude-p-*`.
const signal_escalate_window_ns: u64 = 2 * std.time.ns_per_s;

/// Monotonic nanoseconds. Async-signal-safe (`clock_gettime`). 0 on failure.
fn monotonicNowNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const LaterSignal = enum { ignore, escalate };

/// What to do with a signal that arrives after the first one.
fn laterSignalAction(first_ns: u64, now_ns: u64) LaterSignal {
    // 0: the first handler has not stamped its time yet, so this one is a
    // near-simultaneous duplicate.
    if (first_ns == 0) return .ignore;
    return if (now_ns -| first_ns >= signal_escalate_window_ns) .escalate else .ignore;
}

fn onSignal(sig: i32) callconv(.c) void {
    if (received_signal.cmpxchgStrong(0, @intCast(sig), .seq_cst, .seq_cst) == null) {
        first_signal_ns.store(@max(monotonicNowNs(), 1), .seq_cst);
        if (signal_mode_daemon.load(.seq_cst)) {
            claude_p.daemon.requestInterrupt();
        } else {
            claude_p.driver.requestInterrupt();
        }
        return;
    }
    switch (laterSignalAction(first_signal_ns.load(.seq_cst), monotonicNowNs())) {
        .ignore => {},
        .escalate => {
            // The graceful unwind is stuck; die the default way.
            resetSignal(sig);
            std.posix.raise(@intCast(sig)) catch |err| switch (err) {
                else => {},
            };
        },
    }
}

const handled_signals = [_]u8{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP };

fn resetSignal(sig: i32) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@intCast(sig), &act, null);
}

fn installSignalHandlers(daemon: bool) void {
    signal_mode_daemon.store(daemon, .seq_cst);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (handled_signals) |sig| std.posix.sigaction(sig, &act, null);
}

/// Exit `128 + sig` if a signal arrived; call after `run` has unwound.
fn exitIfSignaled() void {
    const sig = received_signal.load(.seq_cst);
    if (sig == 0) return;
    if (stdout_writer != null) stdoutWriter().flush() catch |err| switch (err) {
        else => {},
    };
    stderrWriter().flush() catch |err| switch (err) {
        else => {},
    };
    std.process.exit(@intCast(128 + sig));
}

/// `--timeout`/session-start seconds to milliseconds; 0 disables the cap.
fn timeoutMs(seconds: u32) u64 {
    if (seconds == 0) return std.math.maxInt(u64);
    return @as(u64, seconds) * 1000;
}

/// What is left of a `timeoutMs` budget after `elapsed_ns`. A disabled
/// budget stays disabled; a spent one leaves 1 ms so the driver reports the
/// timeout itself.
fn remainingTimeoutMs(total_ms: u64, elapsed_ns: u64) u64 {
    if (total_ms == std.math.maxInt(u64)) return total_ms;
    return @max(total_ms -| elapsed_ns / std.time.ns_per_ms, 1);
}

const max_prompt_bytes = 16 * 1024 * 1024;

/// How long to wait for piped stdin to produce data or EOF when a positional
/// prompt was also given. Matches `claude -p`'s 3 s grace: a parent that
/// leaves an open-but-silent pipe must not hang the run forever.
const stdin_grace_ms = 3000;

/// Resolution of where the CLI obtains the user prompt bytes.
pub const PromptSource = enum {
    /// Positional prompt only.
    positional,
    /// Positional prompt prefixed by piped stdin.
    positional_with_stdin,
    input_file,
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

/// `<stdin>\n\n<prompt>`, as `claude -p` composes piped input with a prompt.
/// Empty (after trimming trailing newlines) stdin leaves the prompt alone.
fn composePrompt(allocator: std.mem.Allocator, stdin_text: []const u8, prompt: []const u8) ![]u8 {
    const body = std.mem.trimRight(u8, stdin_text, "\r\n");
    if (body.len == 0) return allocator.dupe(u8, prompt);
    return std.mem.concat(allocator, u8, &.{ body, "\n\n", prompt });
}

/// Print `error: <msg>` to stderr and exit 2 (usage / input error).
fn usageExit(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const w = stderrWriter();
    w.print("error: " ++ fmt ++ "\n", fmt_args) catch |err| switch (err) {
        else => {},
    };
    w.flush() catch |err| switch (err) {
        else => {},
    };
    std.process.exit(2);
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
    max_bytes: usize,
    /// Give up with `.silent` when the first byte (or EOF) takes longer than
    /// this. Null waits for the first byte until `deadline_ns`.
    first_byte_grace_ms: ?u64 = null,
    /// Absolute `monotonicNowNs` deadline for reaching EOF. Null: no limit.
    deadline_ns: ?u64 = null,
    /// Checked at least every `bounded_read_slice_ms`.
    cancel: ?*const std.atomic.Value(u32) = null,
};

/// Longest single `poll`, so `cancel` and the deadlines are re-checked.
/// `std.posix.poll` restarts on EINTR, so a signal alone does not wake it.
const bounded_read_slice_ms: u64 = 100;

fn msUntil(now_ns: u64, target_ns: u64) u64 {
    return (target_ns - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
}

/// Read `fd` to EOF without ever blocking past the grace period, the
/// deadline, or a cancel request. Each `read` follows a ready `poll`, so an
/// open pipe that stops sending cannot hang the caller.
pub fn readBounded(allocator: std.mem.Allocator, fd: std.posix.fd_t, o: BoundedReadOptions) !BoundedRead {
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

/// Read piped stdin under the run's `--timeout` deadline. Returns null when
/// `first_byte_grace_ms` passed with nothing received. Exits 124 when the
/// deadline passes before EOF: running a prefix of the piped input as the
/// prompt would be silently wrong.
fn readStdin(allocator: std.mem.Allocator, first_byte_grace_ms: ?u64, deadline_ns: ?u64, timeout_seconds: u32) ?[]u8 {
    const outcome = readBounded(allocator, std.fs.File.stdin().handle, .{
        .max_bytes = max_prompt_bytes,
        .first_byte_grace_ms = first_byte_grace_ms,
        .deadline_ns = deadline_ns,
        .cancel = &received_signal,
    }) catch |err| {
        if (err == error.OutOfMemory) usageExit("out of memory reading stdin", .{});
        usageExit("cannot read stdin: {s}", .{@errorName(err)});
    };
    switch (outcome) {
        .complete => |bytes| return bytes,
        .silent => return null,
        .too_large => usageExit("stdin exceeds the {d} MiB prompt limit", .{max_prompt_bytes / (1024 * 1024)}),
        .interrupted => {
            exitIfSignaled();
            std.process.exit(130);
        },
        .timed_out => |received| {
            const w = stderrWriter();
            w.print(
                "claude-p: timed out after {d}s (--timeout) waiting for piped stdin to reach EOF; " ++
                    "received {d} bytes and did not run the incomplete prompt. " ++
                    "Close the pipe, redirect stdin (< /dev/null), or raise --timeout\n",
                .{ timeout_seconds, received },
            ) catch |err| switch (err) {
                else => {},
            };
            w.flush() catch |err| switch (err) {
                else => {},
            };
            std.process.exit(124);
        },
    }
}

fn readInputFile(allocator: std.mem.Allocator, path: []const u8) []u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch |err|
        usageExit("cannot read --input-file '{s}': {s}", .{ path, @errorName(err) });
    defer f.close();
    return f.readToEndAlloc(allocator, max_prompt_bytes) catch |err|
        usageExit("cannot read --input-file '{s}': {s}", .{ path, @errorName(err) });
}

/// Entry point for the `claude-p` CLI binary (one-shot and daemon modes).
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv_raw);
    const argv = argv_raw[1..];
    const start_ns = monotonicNowNs();

    var diag: claude_p.args.ParseDiag = .{};
    var opts = claude_p.args.parseWithDiag(allocator, argv, &diag) catch |err| {
        try printError(err, diag.offending);
        std.process.exit(2);
    };
    defer opts.deinit(allocator);

    if (opts.show_help) {
        try stdoutWriter().writeAll(claude_p.args.helpText());
        try stdoutWriter().flush();
        return;
    }
    if (opts.show_version) {
        try stdoutWriter().print("claude-p {f}\n", .{claude_p.version});
        try stdoutWriter().flush();
        return;
    }

    if (opts.is_daemon) {
        const daemon_opts: claude_p.daemon.Options = .{
            .model = opts.model,
            .allowed_tools = opts.allowed_tools,
            .skip_permissions = opts.dangerously_skip_permissions,
            .resume_session = opts.resume_session,
            .cont = opts.cont,
            .session_id = opts.session_id,
            .cwd = opts.cwd,
            .extra_args = opts.passthrough.items,
            .system_prompt = opts.system_prompt,
            .append_system_prompt = opts.append_system_prompt,
            .permission_mode = opts.permission_mode,
            .disallowed_tools = opts.disallowed_tools,
            .fallback_model = opts.fallback_model,
            .setting_sources = opts.setting_sources,
            .add_dirs = opts.add_dirs.items,
            .mcp_configs = opts.mcp_configs.items,
            .verbose = opts.verbose,
            .session_start_timeout_ms = timeoutMs(opts.timeout_seconds),
            .idle_progress_timeout_ms = @as(u64, opts.idle_timeout_seconds) * 1000,
            .transcript_idle_timeout_ms = @as(u64, opts.transcript_idle_timeout_seconds) * 1000,
            .extra_hooks = opts.extra_hooks.items,
            .extra_settings_json = opts.extra_settings_json,
            .debug = opts.debug,
        };
        installSignalHandlers(true);
        const code = claude_p.daemon.run(allocator, daemon_opts) catch |err| {
            exitIfSignaled();
            try reportRunError("claude-p daemon", err);
            std.process.exit(exitCodeForRunError(err));
        };
        exitIfSignaled();
        std.process.exit(code);
    }

    // Resolve the prompt: positional (optionally prefixed by piped stdin),
    // --input-file, or stdin. Read failures are input errors: exit 2.
    var prompt_buf: ?[]u8 = null;
    defer if (prompt_buf) |p| allocator.free(p);

    // Installed before any stdin wait so SIGINT/SIGTERM cancels it. `run`
    // returns `Interrupted` at once if a signal lands before it starts.
    installSignalHandlers(false);
    const run_timeout_ms = timeoutMs(opts.timeout_seconds);
    const stdin_deadline_ns: ?u64 = if (opts.timeout_seconds == 0)
        null
    else
        start_ns + run_timeout_ms * std.time.ns_per_ms;

    const stdin_is_tty = std.posix.isatty(std.fs.File.stdin().handle);
    const prompt: []const u8 = switch (promptSource(opts.prompt != null, opts.input_file != null, stdin_is_tty)) {
        .conflict => usageExit("pass the prompt as a positional argument or with --input-file, not both", .{}),
        .tty_empty => usageExit("empty prompt (positional, --input-file, or piped stdin required; stdin is a terminal)", .{}),
        .positional => opts.prompt.?,
        .positional_with_stdin => blk: {
            const piped = readStdin(allocator, stdin_grace_ms, stdin_deadline_ns, opts.timeout_seconds) orelse {
                const w = stderrWriter();
                w.print("warning: no stdin data received in {d}s, proceeding without it; redirect stdin (< /dev/null) to skip the wait\n", .{stdin_grace_ms / 1000}) catch |err| switch (err) {
                    else => {},
                };
                w.flush() catch |err| switch (err) {
                    else => {},
                };
                break :blk opts.prompt.?;
            };
            defer allocator.free(piped);
            prompt_buf = try composePrompt(allocator, piped, opts.prompt.?);
            break :blk prompt_buf.?;
        },
        .input_file => blk: {
            prompt_buf = readInputFile(allocator, opts.input_file.?);
            break :blk std.mem.trimRight(u8, prompt_buf.?, "\r\n");
        },
        .stdin => blk: {
            // No grace period: stdin is the only prompt source.
            prompt_buf = readStdin(allocator, null, stdin_deadline_ns, opts.timeout_seconds).?;
            break :blk std.mem.trimRight(u8, prompt_buf.?, "\r\n");
        },
    };

    if (prompt.len == 0) usageExit("empty prompt (positional, --input-file, or stdin required)", .{});

    // For stream-json output, hand stdout to the driver so transcript lines
    // can be written live as `claude` flushes them. Other formats accumulate
    // and emit once at the end.
    const stdout = stdoutWriter();
    const stream_writer: ?*std.Io.Writer =
        if (opts.output_format == .stream_json) stdout else null;

    const run_opts: claude_p.Options = .{
        .prompt = prompt,
        .output_format = opts.output_format,
        .model = opts.model,
        .max_turns = opts.max_turns,
        .allowed_tools = opts.allowed_tools,
        .skip_permissions = opts.dangerously_skip_permissions,
        .resume_session = opts.resume_session,
        .cont = opts.cont,
        .session_id = opts.session_id,
        .cwd = opts.cwd,
        .extra_args = opts.passthrough.items,
        .system_prompt = opts.system_prompt,
        .append_system_prompt = opts.append_system_prompt,
        .permission_mode = opts.permission_mode,
        .disallowed_tools = opts.disallowed_tools,
        .fallback_model = opts.fallback_model,
        .setting_sources = opts.setting_sources,
        .add_dirs = opts.add_dirs.items,
        .mcp_configs = opts.mcp_configs.items,
        .verbose = opts.verbose,
        .transcript_idle_timeout_ms = @as(u64, opts.transcript_idle_timeout_seconds) * 1000,
        // Time spent reading the prompt counts against `--timeout`.
        .timeout_ms = remainingTimeoutMs(run_timeout_ms, monotonicNowNs() -| start_ns),
        .debug = opts.debug,
        .stream_writer = stream_writer,
        .retain_replay = false,
        .extra_hooks = opts.extra_hooks.items,
        .extra_settings_json = opts.extra_settings_json,
    };
    var result = claude_p.run(allocator, run_opts) catch |err| {
        exitIfSignaled();
        try reportRunError("claude-p", err);
        std.process.exit(exitCodeForRunError(err));
    };
    defer result.deinit(allocator);
    exitIfSignaled();

    // Result.write is a no-op when stream-json was already streamed. A
    // failed write is a runtime error (2); exit 1 means assistant `is_error`.
    result.write(allocator, stdout, opts.output_format) catch |err| outputFailureExit(err);
    stdout.flush() catch |err| outputFailureExit(err);

    std.process.exit(result.exitCode());
}

/// The result could not be written to stdout (closed pipe, full disk).
fn outputFailureExit(err: anyerror) noreturn {
    const w = stderrWriter();
    w.print("claude-p: cannot write the result to stdout: {s}\n", .{@errorName(err)}) catch |write_err| switch (write_err) {
        else => {},
    };
    w.flush() catch |flush_err| switch (flush_err) {
        else => {},
    };
    std.process.exit(2);
}

/// Human-readable messages for the validation errors users actually hit.
/// Everything else falls back to the error name.
fn parseErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.StreamJsonRequiresVerbose => "Error: --output-format=stream-json requires --verbose",
        error.UnsupportedFlag => "Error: unsupported flag. claude-p rejects -p/--print (it emulates print mode), " ++
            "--settings (it injects its own; use --extra-hook or --setting-json), " ++
            "--bare/--safe-mode (Claude Code skips --settings hooks under them), " ++
            "--no-session-persistence (claude-p reads the transcript), the " ++
            "print-only --input-format, --json-schema, --max-budget-usd, --max-turns, and " ++
            "--fallback-model, the print-only stream flags --include-partial-messages, " ++
            "--forward-subagent-text, --replay-user-messages, and --verbose-thinking, " ++
            "and --output-format text/json in daemon mode (its output is always stream-json)",
        error.MissingValue => "Error: a flag is missing its value (--add-dir, --mcp-config, --allowedTools, " ++
            "and --disallowedTools need a value not starting with `-`; use the " ++
            "--flag=<value> form for one that does)",
        error.UnknownFlag => "Error: unexpected argument. claude-p takes one PROMPT; daemon mode takes " ++
            "no PROMPT or --input-file (prompts arrive as stdin frames)",
        error.BadExtraHook => "Error: --extra-hook expects <Event>=<cmd> with a non-empty event and command, " ++
            "e.g. --extra-hook 'PreToolUse=echo hi'",
        else => null,
    };
}

/// Write the parse error, naming the offending argv token when known:
/// `claude-p: bad arguments: BadInteger (near 'abc')`.
fn writeParseError(w: *std.Io.Writer, err: anyerror, offending: ?[]const u8) !void {
    if (parseErrorMessage(err)) |msg| {
        try w.writeAll(msg);
    } else {
        try w.print("claude-p: bad arguments: {s}", .{@errorName(err)});
    }
    if (offending) |tok| try w.print(" (near '{s}')", .{tok});
    try w.writeAll("\n");
}

fn printError(err: anyerror, offending: ?[]const u8) !void {
    const w = stderrWriter();
    try writeParseError(w, err, offending);
    try w.flush();
}

/// Exit code for an error returned by `claude_p.run` or `daemon.run`.
/// Matches the SPEC/README exit code table: timeouts are 124, everything
/// else is a usage or runtime failure (2).
fn exitCodeForRunError(err: anyerror) u8 {
    return switch (err) {
        error.SessionStartTimeout,
        error.StopTimeout,
        error.IdleTimeout,
        error.TranscriptStalled,
        => 124,
        else => 2,
    };
}

/// Actionable stderr text for known run errors; null means print the name.
fn runErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SessionStartTimeout => "timed out waiting for claude to start (SessionStart hook never fired); raise --timeout or run with --debug",
        error.StopTimeout => "timed out waiting for claude to finish the turn (Stop hook never fired); raise --timeout",
        error.IdleTimeout => "no PTY output while busy for --idle-timeout; claude appears hung",
        error.TranscriptStalled => "transcript stopped growing while busy for --transcript-idle-timeout",
        error.PromptNotAccepted => "claude never accepted the typed prompt; check for a blocking dialog with --debug",
        error.PromptTruncated => "claude received a truncated prompt; pass long prompts via --input-file or stdin and retry",
        error.Interrupted => "interrupted by a signal",
        error.PermissionPromptBlocked => "claude needs a permission decision; configure an allowed tool or a PermissionRequest hook and retry",
        error.InvalidOptions => "check the supplied options against claude-p --help and remove unsupported print-mode flags",
        error.InvalidCwd => "--cwd is not an accessible directory",
        error.UnexpectedStartupDialog => "claude displayed a security warning dialog that was not authorized by your flags; pass --dangerously-skip-permissions or --dangerously-load-development-channels if intended",
        error.InvalidExtraSettings => "--setting-json must be a JSON object nested at most 128 levels and each --extra-hook needs a non-empty UTF-8 event and command",
        else => null,
    };
}

fn reportRunError(prefix: []const u8, err: anyerror) !void {
    const w = stderrWriter();
    if (runErrorMessage(err)) |msg| {
        try w.print("{s}: {s}: {s}\n", .{ prefix, @errorName(err), msg });
    } else {
        try w.print("{s}: {s}\n", .{ prefix, @errorName(err) });
    }
    try w.flush();
}

// Keep this test first: in child mode it must run before any other.
/// Set in the launcher test's child. The test binary then runs `main()`, so
/// it stands in for the `claude-p` executable that `bin/claude-p.js` spawns.
const pgroup_child_env = "CLAUDE_P_TEST_PGROUP_CHILD";

test "launcher child: run main() when re-executed as the claude-p binary" {
    if (std.posix.getenv(pgroup_child_env) == null) return;
    main() catch {};
    std.process.exit(3);
}

test "exitCodeForRunError: timeouts are 124, the rest 2" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 124), exitCodeForRunError(error.SessionStartTimeout));
    try t.expectEqual(@as(u8, 124), exitCodeForRunError(error.StopTimeout));
    try t.expectEqual(@as(u8, 124), exitCodeForRunError(error.IdleTimeout));
    try t.expectEqual(@as(u8, 124), exitCodeForRunError(error.TranscriptStalled));
    try t.expectEqual(@as(u8, 2), exitCodeForRunError(error.PromptNotAccepted));
    try t.expectEqual(@as(u8, 2), exitCodeForRunError(error.PromptTruncated));
    try t.expectEqual(@as(u8, 2), exitCodeForRunError(error.InvalidExtraSettings));
    try t.expectEqual(@as(u8, 2), exitCodeForRunError(error.SpawnFailed));
}

test "timeoutMs: 0 disables, otherwise seconds to ms" {
    try std.testing.expectEqual(std.math.maxInt(u64), timeoutMs(0));
    try std.testing.expectEqual(@as(u64, 300_000), timeoutMs(300));
    try std.testing.expectEqual(@as(u64, 4_294_967_295_000), timeoutMs(std.math.maxInt(u32)));
}

test "promptSource: every combination" {
    const t = std.testing;
    try t.expectEqual(PromptSource.conflict, promptSource(true, true, true));
    try t.expectEqual(PromptSource.conflict, promptSource(true, true, false));
    try t.expectEqual(PromptSource.input_file, promptSource(false, true, true));
    try t.expectEqual(PromptSource.input_file, promptSource(false, true, false));
    try t.expectEqual(PromptSource.positional, promptSource(true, false, true));
    try t.expectEqual(PromptSource.positional_with_stdin, promptSource(true, false, false));
    try t.expectEqual(PromptSource.tty_empty, promptSource(false, false, true));
    try t.expectEqual(PromptSource.stdin, promptSource(false, false, false));
}

test "composePrompt: stdin, blank line, prompt; empty stdin leaves the prompt" {
    const t = std.testing;
    const a = try composePrompt(t.allocator, "diff --git a b\n+x\n\n", "summarize this");
    defer t.allocator.free(a);
    try t.expectEqualStrings("diff --git a b\n+x\n\nsummarize this", a);
    const b = try composePrompt(t.allocator, "\r\n", "hi");
    defer t.allocator.free(b);
    try t.expectEqualStrings("hi", b);
}

test "runErrorMessage: prompt and settings errors carry diagnostics" {
    const t = std.testing;
    try t.expect(runErrorMessage(error.PromptNotAccepted) != null);
    try t.expect(runErrorMessage(error.PromptTruncated) != null);
    try t.expect(runErrorMessage(error.InvalidExtraSettings) != null);
    try t.expect(runErrorMessage(error.Interrupted) != null);
    try t.expect(runErrorMessage(error.InvalidCwd) != null);
    try t.expect(runErrorMessage(error.SpawnFailed) == null);
}

test "remainingTimeoutMs: subtracts elapsed time, keeps a disabled budget, never reaches 0" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 300_000), remainingTimeoutMs(300_000, 0));
    try t.expectEqual(@as(u64, 297_500), remainingTimeoutMs(300_000, 2_500 * std.time.ns_per_ms));
    try t.expectEqual(@as(u64, 1), remainingTimeoutMs(1_000, 1_000 * std.time.ns_per_ms));
    try t.expectEqual(@as(u64, 1), remainingTimeoutMs(1_000, 90 * std.time.ns_per_s));
    try t.expectEqual(std.math.maxInt(u64), remainingTimeoutMs(timeoutMs(0), 90 * std.time.ns_per_s));
}

test "writeParseError: names the offending token" {
    const t = std.testing;
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try writeParseError(&out.writer, error.BadInteger, "abc");
    try t.expectEqualStrings("claude-p: bad arguments: BadInteger (near 'abc')\n", out.written());

    out.clearRetainingCapacity();
    try writeParseError(&out.writer, error.BadOutputFormat, null);
    try t.expectEqualStrings("claude-p: bad arguments: BadOutputFormat\n", out.written());

    out.clearRetainingCapacity();
    try writeParseError(&out.writer, error.UnsupportedFlag, "--max-turns");
    for ([_][]const u8{
        "--max-turns",             "--fallback-model",       "--include-partial-messages",
        "--forward-subagent-text", "--replay-user-messages", "daemon mode",
        " (near '--max-turns')\n",
    }) |needle| try t.expect(std.mem.indexOf(u8, out.written(), needle) != null);
}

test "laterSignalAction: duplicates inside 2 s are ignored, later ones escalate" {
    const t = std.testing;
    const s = std.time.ns_per_s;
    const ms = std.time.ns_per_ms;
    // The launcher's forwarded duplicate lands milliseconds after the first.
    try t.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 10 * s));
    try t.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 10 * s + 3 * ms));
    try t.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 12 * s - 1));
    try t.expectEqual(LaterSignal.escalate, laterSignalAction(10 * s, 12 * s));
    try t.expectEqual(LaterSignal.escalate, laterSignalAction(10 * s, 60 * s));
    // First handler not stamped yet, or a clock that ran backwards.
    try t.expectEqual(LaterSignal.ignore, laterSignalAction(0, 60 * s));
    try t.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 9 * s));
}

fn resetSignalState() void {
    received_signal.store(0, .seq_cst);
    first_signal_ns.store(0, .seq_cst);
    signal_mode_daemon.store(false, .seq_cst);
    claude_p.driver.interrupted.store(false, .seq_cst);
}

test "onSignal: the first signal requests an interrupt; an immediate duplicate does not kill" {
    const t = std.testing;
    resetSignalState();
    defer resetSignalState();

    onSignal(std.posix.SIG.INT);
    try t.expectEqual(@as(u32, std.posix.SIG.INT), received_signal.load(.seq_cst));
    try t.expect(first_signal_ns.load(.seq_cst) != 0);
    try t.expect(claude_p.driver.isInterrupted());

    // Regression (M1/H09): these re-raised the default action and killed the
    // process (here: this test binary) before cleanup could run.
    onSignal(std.posix.SIG.INT);
    onSignal(std.posix.SIG.TERM);
    try t.expectEqual(@as(u32, std.posix.SIG.INT), received_signal.load(.seq_cst));
}

const PipeWriter = struct {
    fn slow(fd: std.posix.fd_t) void {
        _ = std.posix.write(fd, "a") catch |err| switch (err) {
            else => {},
        };
        std.Thread.sleep(150 * std.time.ns_per_ms);
        _ = std.posix.write(fd, "b") catch |err| switch (err) {
            else => {},
        };
        std.posix.close(fd);
    }
};

test "readBounded: closed stdin is silent with a positional prompt" {
    const t = std.testing;
    const invalid_fd = std.math.maxInt(std.posix.fd_t);
    try t.expectEqual(BoundedRead.silent, try readBounded(t.allocator, invalid_fd, .{ .max_bytes = 64, .first_byte_grace_ms = 50 }));
    try t.expectError(error.NotOpenForReading, readBounded(t.allocator, invalid_fd, .{ .max_bytes = 64 }));
}

test "readBounded: reads to EOF" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "diff --git a b\n");
    std.posix.close(p[1]);
    const r = try readBounded(t.allocator, p[0], .{ .max_bytes = 64, .first_byte_grace_ms = 50 });
    defer t.allocator.free(r.complete);
    try t.expectEqualStrings("diff --git a b\n", r.complete);
}

test "readBounded: an open, silent pipe gives up after the first-byte grace" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    const t0 = monotonicNowNs();
    const r = try readBounded(t.allocator, p[0], .{ .max_bytes = 64, .first_byte_grace_ms = 60 });
    const elapsed = monotonicNowNs() - t0;
    try t.expectEqual(BoundedRead.silent, r);
    try t.expect(elapsed >= 60 * std.time.ns_per_ms);
    try t.expect(elapsed < 5 * std.time.ns_per_s);
}

test "readBounded: a prefix then silence times out at the deadline, not at the grace" {
    // Regression (M31): after the first byte the reader blocked with no
    // deadline, so an open pipe hung past --timeout.
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    _ = try std.posix.write(p[1], "abc");
    const t0 = monotonicNowNs();
    const r = try readBounded(t.allocator, p[0], .{
        .max_bytes = 64,
        .first_byte_grace_ms = 20,
        .deadline_ns = t0 + 200 * std.time.ns_per_ms,
    });
    const elapsed = monotonicNowNs() - t0;
    try t.expectEqual(BoundedRead{ .timed_out = 3 }, r);
    try t.expect(elapsed >= 200 * std.time.ns_per_ms);
    try t.expect(elapsed < 5 * std.time.ns_per_s);
}

test "readBounded: with no grace, a silent pipe times out with 0 bytes" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    const r = try readBounded(t.allocator, p[0], .{
        .max_bytes = 64,
        .deadline_ns = monotonicNowNs() + 80 * std.time.ns_per_ms,
    });
    try t.expectEqual(BoundedRead{ .timed_out = 0 }, r);
}

test "readBounded: the grace applies to the first byte only" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    // The writer pauses 150 ms mid-stream, longer than the 50 ms grace.
    const thread = try std.Thread.spawn(.{}, PipeWriter.slow, .{p[1]});
    defer thread.join();
    const r = try readBounded(t.allocator, p[0], .{
        .max_bytes = 64,
        .first_byte_grace_ms = 50,
        .deadline_ns = monotonicNowNs() + 10 * std.time.ns_per_s,
    });
    defer t.allocator.free(r.complete);
    try t.expectEqualStrings("ab", r.complete);
}

test "readBounded: a cancel request stops the wait" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    defer std.posix.close(p[1]);
    _ = try std.posix.write(p[1], "abc");
    var cancel = std.atomic.Value(u32).init(std.posix.SIG.TERM);
    const r = try readBounded(t.allocator, p[0], .{ .max_bytes = 64, .cancel = &cancel });
    try t.expectEqual(BoundedRead.interrupted, r);
}

test "readBounded: more than max_bytes is too_large" {
    const t = std.testing;
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "hello");
    std.posix.close(p[1]);
    try t.expectEqual(BoundedRead.too_large, try readBounded(t.allocator, p[0], .{ .max_bytes = 4 }));

    const q = try std.posix.pipe();
    defer std.posix.close(q[0]);
    _ = try std.posix.write(q[1], "hell");
    std.posix.close(q[1]);
    const exact = try readBounded(t.allocator, q[0], .{ .max_bytes = 4 });
    defer t.allocator.free(exact.complete);
    try t.expectEqualStrings("hell", exact.complete);
}

// ---------------------------------------------------------------------------
// Process-group SIGINT through the npm launcher (M1/H09)
// ---------------------------------------------------------------------------

fn countHarnessDirs(dir: std.fs.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "claude-p-")) n += 1;
    }
    return n;
}

const GroupKiller = struct {
    pgid: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),

    /// SIGKILL the group if the launcher has not exited within 30 s, so a
    /// stuck unwind fails the test instead of hanging it.
    fn run(self: *GroupKiller) void {
        for (0..300) |_| {
            if (self.done.load(.seq_cst)) return;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        std.posix.kill(-self.pgid, std.posix.SIG.KILL) catch |err| switch (err) {
            else => {},
        };
    }
};

test "launcher: SIGINT to the process group unwinds claude-p, exits 130, and leaves no temp dir" {
    const t = std.testing;
    if (std.posix.getenv(pgroup_child_env) != null) return;
    const platform = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return error.SkipZigTest,
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return error.SkipZigTest,
    };
    const a = t.allocator;

    // `zig build test` runs from the package root.
    const launcher = std.fs.cwd().readFileAlloc(a, "bin/claude-p.js", 1 << 20) catch |err| {
        std.debug.print("launcher test skipped: bin/claude-p.js: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer a.free(launcher);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    // <root>/pkg mirrors the npm package: bin/claude-p.js plus the prebuilt
    // binary, which is this test binary in child mode.
    var prebuilt_buf: [64]u8 = undefined;
    const prebuilt = try std.fmt.bufPrint(&prebuilt_buf, "pkg/prebuilt/{s}-{s}", .{ platform, arch });
    try tmp.dir.makePath("pkg/bin");
    try tmp.dir.makePath(prebuilt);
    try tmp.dir.makePath("fakebin");
    try tmp.dir.makePath("tmpdir");
    try tmp.dir.writeFile(.{ .sub_path = "pkg/bin/claude-p.js", .data = launcher });
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = try std.fs.selfExePath(&self_buf);
    {
        var d = try tmp.dir.openDir(prebuilt, .{});
        defer d.close();
        try d.symLink(self_exe, "claude-p", .{});
    }
    // A `claude` that starts and never fires SessionStart: claude-p sits in
    // its startup wait with the harness temp dir on disk.
    {
        const f = try tmp.dir.createFile("fakebin/claude", .{ .mode = 0o700 });
        defer f.close();
        var script_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(
            &script_buf,
            "#!/bin/sh\necho $$ > '{s}/claude.pid'\nprintf 'Booting\\r\\n'\nsleep 60\n",
            .{root},
        ));
    }

    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    const tmpdir_path = try std.fs.path.join(a, &.{ root, "tmpdir" });
    defer a.free(tmpdir_path);
    const path_value = try std.fmt.allocPrint(a, "{s}/fakebin:{s}", .{ root, env.get("PATH") orelse "/usr/bin:/bin" });
    defer a.free(path_value);
    try env.put("TMPDIR", tmpdir_path);
    try env.put("PATH", path_value);
    try env.put(pgroup_child_env, "1");
    // The build runner's progress pipe is not open in the grandchild.
    env.remove("ZIG_PROGRESS");

    const launcher_path = try std.fs.path.join(a, &.{ root, "pkg", "bin", "claude-p.js" });
    defer a.free(launcher_path);
    var child = std.process.Child.init(&.{ "node", launcher_path }, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.env_map = &env;
    child.cwd = root;
    // Its own process group, shared with claude-p, like a shell job.
    child.pgid = 0;
    child.spawn() catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("launcher test skipped: node is not on PATH\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    var killer: GroupKiller = .{ .pgid = child.id };
    const killer_thread = try std.Thread.spawn(.{}, GroupKiller.run, .{&killer});
    var reaped = false;
    defer {
        if (!reaped) {
            std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
        }
        killer.done.store(true, .seq_cst);
        killer_thread.join();
    }

    // The prompt arrives on piped stdin.
    try child.stdin.?.writeAll("hello\n");
    child.stdin.?.close();
    child.stdin = null;

    var tmpdir = try tmp.dir.openDir("tmpdir", .{ .iterate = true });
    defer tmpdir.close();

    // Wait until claude-p is mid-run: fake claude up, harness dir on disk.
    var running = false;
    for (0..600) |_| {
        const pid_ready = if (tmp.dir.statFile("claude.pid")) |st| st.size > 1 else |_| false;
        if (pid_ready and try countHarnessDirs(tmpdir) == 1) {
            running = true;
            break;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    if (!running) {
        std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
        const err_text = child.stderr.?.readToEndAlloc(a, 1 << 20) catch try a.dupe(u8, "");
        defer a.free(err_text);
        std.debug.print("launcher test: claude-p never reached its startup wait; stderr:\n{s}\n", .{err_text});
        return error.TestUnexpectedResult;
    }
    std.Thread.sleep(150 * std.time.ns_per_ms);

    // Ctrl-C: the kernel signals the whole group, so claude-p gets SIGINT
    // directly and again milliseconds later, forwarded by the launcher.
    try std.posix.kill(-child.id, std.posix.SIG.INT);

    const err_text = try child.stderr.?.readToEndAlloc(a, 1 << 20);
    defer a.free(err_text);
    const term = try child.wait();
    reaped = true;
    errdefer std.debug.print("launcher test: term={any}; stderr:\n{s}\n", .{ term, err_text });

    // claude-p unwound and reported 128 + SIGINT; the launcher passed it on.
    try t.expectEqual(std.process.Child.Term{ .Exited = 130 }, term);
    try t.expectEqual(@as(usize, 0), try countHarnessDirs(tmpdir));

    // The PTY child is gone too.
    const pid_text = try tmp.dir.readFileAlloc(a, "claude.pid", 32);
    defer a.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n"), 10);
    var gone = false;
    for (0..150) |_| {
        std.posix.kill(pid, 0) catch {
            gone = true;
            break;
        };
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try t.expect(gone);
}

test "exhaustive: every driver.RunError and daemon.RunError maps to exit code 2 or 124" {
    const t = std.testing;
    const timeouts = [_][]const u8{ "SessionStartTimeout", "StopTimeout", "IdleTimeout", "TranscriptStalled" };
    inline for (.{ claude_p.driver.RunError, claude_p.daemon.RunError }) |E| {
        inline for (@typeInfo(E).error_set.?) |err_field| {
            const err = @field(anyerror, err_field.name);
            const code = exitCodeForRunError(err);
            var is_timeout = false;
            for (timeouts) |name| {
                if (std.mem.eql(u8, err_field.name, name)) is_timeout = true;
            }
            if (is_timeout) {
                try t.expectEqual(@as(u8, 124), code);
                try t.expect(runErrorMessage(err) != null);
            } else {
                try t.expectEqual(@as(u8, 2), code);
            }
        }
    }
}
// std.fs.File.stdout() / .stderr() return a File; we need a Writer to use the
// std.Io.Writer interface.
var stdout_buf: [4096]u8 = undefined;
var stderr_buf: [4096]u8 = undefined;
var stdout_writer: ?std.fs.File.Writer = null;
var stderr_writer: ?std.fs.File.Writer = null;

fn stdoutWriter() *std.Io.Writer {
    if (stdout_writer == null) stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    return &stdout_writer.?.interface;
}

fn stderrWriter() *std.Io.Writer {
    if (stderr_writer == null) stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    return &stderr_writer.?.interface;
}
