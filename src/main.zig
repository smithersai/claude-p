//! `claude-p` CLI entry point. Parses argv, runs the driver or daemon, emits output.
const std = @import("std");
const claude_p = @import("claude_p");

const stdin_mod = claude_p.stdin;
const monotonicNowNs = stdin_mod.monotonicNowNs;
const timeoutMs = stdin_mod.timeoutMs;
const remainingTimeoutMs = stdin_mod.remainingTimeoutMs;
const composePrompt = stdin_mod.composePrompt;
const parseErrorMessage = claude_p.emit.parseErrorMessage;
const exitCodeForRunError = claude_p.emit.exitCodeForRunError;
const runErrorMessage = claude_p.emit.runErrorMessage;

/// Resolution of where the CLI obtains the user prompt bytes.
pub const PromptSource = stdin_mod.PromptSource;
/// Decide where the prompt should be read from given CLI flags and stdin TTY state.
pub const promptSource = stdin_mod.promptSource;
/// Outcome of reading stdin with a byte cap, optional first-byte grace, and deadline.
pub const BoundedRead = stdin_mod.BoundedRead;
/// Limits and cancellation controls for `readBounded`.
pub const BoundedReadOptions = stdin_mod.BoundedReadOptions;
/// Read `fd` to EOF without blocking past grace, deadline, or cancel request.
pub const readBounded = stdin_mod.readBounded;

var received_signal = std.atomic.Value(u32).init(0);
var first_signal_ns = std.atomic.Value(u64).init(0);
var signal_mode_daemon = std.atomic.Value(bool).init(false);

const signal_escalate_window_ns: u64 = 2 * std.time.ns_per_s;
const LaterSignal = enum { ignore, escalate };
const handled_signals = [_]u8{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP };

fn ignoreIoErr(_: anyerror) void {}

fn laterSignalAction(first_ns: u64, now_ns: u64) LaterSignal {
    std.debug.assert(signal_escalate_window_ns > 0);
    if (first_ns == 0) return .ignore;
    return if (now_ns -| first_ns >= signal_escalate_window_ns) .escalate else .ignore;
}

fn onSignal(sig: i32) callconv(.c) void {
    std.debug.assert(sig > 0);
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
            resetSignal(sig);
            std.posix.raise(@intCast(sig)) catch |err| ignoreIoErr(err);
        },
    }
}

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

fn exitIfSignaled() void {
    const sig = received_signal.load(.seq_cst);
    if (sig == 0) return;
    if (stdout_writer != null) stdoutWriter().flush() catch |err| ignoreIoErr(err);
    stderrWriter().flush() catch |err| ignoreIoErr(err);
    std.process.exit(@intCast(128 + sig));
}

fn usageExit(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const w = stderrWriter();
    w.print("error: " ++ fmt ++ "\n", fmt_args) catch |err| ignoreIoErr(err);
    w.flush() catch |err| ignoreIoErr(err);
    std.process.exit(2);
}

fn readStdin(
    allocator: std.mem.Allocator,
    first_byte_grace_ms: ?u64,
    deadline_ns: ?u64,
    timeout_seconds: u32,
) ?[]u8 {
    std.debug.assert(stdin_mod.max_prompt_bytes > 0);
    const outcome = readBounded(allocator, std.fs.File.stdin().handle, .{
        .max_bytes = stdin_mod.max_prompt_bytes,
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
        .too_large => usageExit(
            "stdin exceeds the {d} MiB prompt limit",
            .{stdin_mod.max_prompt_bytes / (1024 * 1024)},
        ),
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
            ) catch |err| ignoreIoErr(err);
            w.flush() catch |err| ignoreIoErr(err);
            std.process.exit(124);
        },
    }
}

fn readInputFile(allocator: std.mem.Allocator, path: []const u8) []u8 {
    std.debug.assert(path.len > 0);
    const f = std.fs.cwd().openFile(path, .{}) catch |err|
        usageExit("cannot read --input-file '{s}': {s}", .{ path, @errorName(err) });
    defer f.close();
    return f.readToEndAlloc(allocator, stdin_mod.max_prompt_bytes) catch |err|
        usageExit("cannot read --input-file '{s}': {s}", .{ path, @errorName(err) });
}

fn runDaemon(allocator: std.mem.Allocator, opts: *const claude_p.args.Options) !noreturn {
    std.debug.assert(opts.is_daemon);
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

fn resolvePrompt(
    allocator: std.mem.Allocator,
    opts: *const claude_p.args.Options,
    stdin_deadline_ns: ?u64,
    prompt_buf: *?[]u8,
) ![]const u8 {
    std.debug.assert(prompt_buf.* == null);
    const stdin_is_tty = std.posix.isatty(std.fs.File.stdin().handle);
    return switch (promptSource(opts.prompt != null, opts.input_file != null, stdin_is_tty)) {
        .conflict => usageExit("pass the prompt as a positional argument or with --input-file, not both", .{}),
        .tty_empty => usageExit(
            "empty prompt (positional, --input-file, or piped stdin required; stdin is a terminal)",
            .{},
        ),
        .positional => opts.prompt.?,
        .positional_with_stdin => blk: {
            const grace = stdin_mod.stdin_grace_ms;
            const piped = readStdin(allocator, grace, stdin_deadline_ns, opts.timeout_seconds) orelse {
                const w = stderrWriter();
                w.print(
                    "warning: no stdin data received in {d}s, proceeding without it; " ++
                        "redirect stdin (< /dev/null) to skip the wait\n",
                    .{stdin_mod.stdin_grace_ms / 1000},
                ) catch |err| ignoreIoErr(err);
                w.flush() catch |err| ignoreIoErr(err);
                break :blk opts.prompt.?;
            };
            defer allocator.free(piped);
            prompt_buf.* = try composePrompt(allocator, piped, opts.prompt.?);
            break :blk prompt_buf.*.?;
        },
        .input_file => blk: {
            prompt_buf.* = readInputFile(allocator, opts.input_file.?);
            break :blk std.mem.trimRight(u8, prompt_buf.*.?, "\r\n");
        },
        .stdin => blk: {
            prompt_buf.* = readStdin(allocator, null, stdin_deadline_ns, opts.timeout_seconds).?;
            break :blk std.mem.trimRight(u8, prompt_buf.*.?, "\r\n");
        },
    };
}

fn runOneShot(
    allocator: std.mem.Allocator,
    opts: *const claude_p.args.Options,
    prompt: []const u8,
    start_ns: u64,
    run_timeout_ms: u64,
) !noreturn {
    std.debug.assert(prompt.len > 0);
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
    result.write(allocator, stdout, opts.output_format) catch |err| outputFailureExit(err);
    stdout.flush() catch |err| outputFailureExit(err);
    std.process.exit(result.exitCode());
}

/// Entry point for the `claude-p` CLI binary (one-shot and daemon modes).
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv_raw);
    const start_ns = monotonicNowNs();

    var diag: claude_p.args.ParseDiag = .{};
    var opts = claude_p.args.parseWithDiag(allocator, argv_raw[1..], &diag) catch |err| {
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
    if (opts.is_daemon) try runDaemon(allocator, &opts);

    var prompt_buf: ?[]u8 = null;
    defer if (prompt_buf) |p| allocator.free(p);
    installSignalHandlers(false);
    const run_timeout_ms = timeoutMs(opts.timeout_seconds);
    const stdin_deadline_ns: ?u64 = if (opts.timeout_seconds == 0)
        null
    else
        start_ns + run_timeout_ms * std.time.ns_per_ms;
    const prompt = try resolvePrompt(allocator, &opts, stdin_deadline_ns, &prompt_buf);
    if (prompt.len == 0) usageExit("empty prompt (positional, --input-file, or stdin required)", .{});
    try runOneShot(allocator, &opts, prompt, start_ns, run_timeout_ms);
}

fn outputFailureExit(err: anyerror) noreturn {
    const w = stderrWriter();
    w.print("claude-p: cannot write the result to stdout: {s}\n", .{@errorName(err)}) catch |e| ignoreIoErr(e);
    w.flush() catch |e| ignoreIoErr(e);
    std.process.exit(2);
}

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

fn reportRunError(prefix: []const u8, err: anyerror) !void {
    std.debug.assert(prefix.len > 0);
    const w = stderrWriter();
    if (runErrorMessage(err)) |msg| {
        try w.print("{s}: {s}: {s}\n", .{ prefix, @errorName(err), msg });
    } else {
        try w.print("{s}: {s}\n", .{ prefix, @errorName(err) });
    }
    try w.flush();
}

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

// -------- tests --------
const testing = std.testing;

test "exitCodeForRunError: timeouts map to 124 and others to 2" {
    try testing.expectEqual(@as(u8, 124), exitCodeForRunError(error.SessionStartTimeout));
    try testing.expectEqual(@as(u8, 124), exitCodeForRunError(error.StopTimeout));
    try testing.expectEqual(@as(u8, 124), exitCodeForRunError(error.IdleTimeout));
    try testing.expectEqual(@as(u8, 124), exitCodeForRunError(error.TranscriptStalled));
    try testing.expectEqual(@as(u8, 2), exitCodeForRunError(error.PromptNotAccepted));
    try testing.expectEqual(@as(u8, 2), exitCodeForRunError(error.SpawnFailed));
}

test "timeoutMs: 0 disables and positive converts to ms" {
    try testing.expectEqual(std.math.maxInt(u64), timeoutMs(0));
    try testing.expectEqual(@as(u64, 300_000), timeoutMs(300));
}

test "remainingTimeoutMs: subtracts elapsed and floors at 1" {
    try testing.expectEqual(@as(u64, 297_500), remainingTimeoutMs(300_000, 2_500 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 1), remainingTimeoutMs(1_000, 90 * std.time.ns_per_s));
    try testing.expectEqual(std.math.maxInt(u64), remainingTimeoutMs(timeoutMs(0), 90 * std.time.ns_per_s));
}

test "promptSource: resolves positional, input_file, stdin, and conflict" {
    try testing.expectEqual(PromptSource.conflict, promptSource(true, true, true));
    try testing.expectEqual(PromptSource.input_file, promptSource(false, true, false));
    try testing.expectEqual(PromptSource.positional, promptSource(true, false, true));
    try testing.expectEqual(PromptSource.positional_with_stdin, promptSource(true, false, false));
    try testing.expectEqual(PromptSource.tty_empty, promptSource(false, false, true));
    try testing.expectEqual(PromptSource.stdin, promptSource(false, false, false));
}

test "composePrompt: joins stdin and prompt or returns prompt when empty" {
    const a = try composePrompt(testing.allocator, "line\n\n", "go");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("line\n\ngo", a);
    const b = try composePrompt(testing.allocator, "\r\n", "go");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("go", b);
}

test "runErrorMessage: prompt and settings errors carry diagnostics" {
    try testing.expect(runErrorMessage(error.PromptNotAccepted) != null);
    try testing.expect(runErrorMessage(error.PromptTruncated) != null);
    try testing.expect(runErrorMessage(error.InvalidExtraSettings) != null);
    try testing.expect(runErrorMessage(error.SpawnFailed) == null);
}

test "writeParseError: formats offending token and unsupported flag guidance" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeParseError(&out.writer, error.BadInteger, "abc");
    try testing.expectEqualStrings("claude-p: bad arguments: BadInteger (near 'abc')\n", out.written());

    out.clearRetainingCapacity();
    try writeParseError(&out.writer, error.UnsupportedFlag, "--max-turns");
    try testing.expect(std.mem.indexOf(u8, out.written(), " (near '--max-turns')\n") != null);
}

test "writeParseError: omits near clause when offending is null" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeParseError(&out.writer, error.BadOutputFormat, null);
    try testing.expectEqualStrings("claude-p: bad arguments: BadOutputFormat\n", out.written());
}

test "laterSignalAction: ignores duplicates inside 2s and escalates after" {
    const s = std.time.ns_per_s;
    try testing.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 10 * s));
    try testing.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 12 * s - 1));
    try testing.expectEqual(LaterSignal.escalate, laterSignalAction(10 * s, 12 * s));
    try testing.expectEqual(LaterSignal.ignore, laterSignalAction(0, 60 * s));
    try testing.expectEqual(LaterSignal.ignore, laterSignalAction(10 * s, 9 * s));
}

test "onSignal: records first signal and ignores immediate duplicate" {
    const reset = struct {
        fn run() void {
            received_signal.store(0, .seq_cst);
            first_signal_ns.store(0, .seq_cst);
            signal_mode_daemon.store(false, .seq_cst);
            claude_p.driver.interrupted.store(false, .seq_cst);
        }
    }.run;
    reset();
    defer reset();
    onSignal(std.posix.SIG.INT);
    try testing.expectEqual(@as(u32, std.posix.SIG.INT), received_signal.load(.seq_cst));
    try testing.expect(claude_p.driver.isInterrupted());
    onSignal(std.posix.SIG.TERM);
    try testing.expectEqual(@as(u32, std.posix.SIG.INT), received_signal.load(.seq_cst));
}

test "onSignal: daemon mode routes interrupt to daemon" {
    const reset = struct {
        fn run() void {
            received_signal.store(0, .seq_cst);
            first_signal_ns.store(0, .seq_cst);
            signal_mode_daemon.store(false, .seq_cst);
            claude_p.driver.interrupted.store(false, .seq_cst);
        }
    }.run;
    reset();
    defer reset();
    signal_mode_daemon.store(true, .seq_cst);
    onSignal(std.posix.SIG.TERM);
    try testing.expectEqual(@as(u32, std.posix.SIG.TERM), received_signal.load(.seq_cst));
    try testing.expect(claude_p.driver.isInterrupted());
}

test "handled_signals: covers INT, TERM, and HUP" {
    try testing.expectEqual(@as(usize, 3), handled_signals.len);
    try testing.expectEqual(std.posix.SIG.INT, handled_signals[0]);
    try testing.expectEqual(std.posix.SIG.TERM, handled_signals[1]);
    try testing.expectEqual(std.posix.SIG.HUP, handled_signals[2]);
}

test "readBounded: delegates to stdin module" {
    const p = try std.posix.pipe();
    defer std.posix.close(p[0]);
    _ = try std.posix.write(p[1], "ok");
    std.posix.close(p[1]);
    const r = try readBounded(testing.allocator, p[0], .{ .max_bytes = 16 });
    defer testing.allocator.free(r.complete);
    try testing.expectEqualStrings("ok", r.complete);
}

test "readInputFile: reads temp file bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "p.txt", .data = "hello prompt\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "p.txt");
    defer testing.allocator.free(path);
    const data = readInputFile(testing.allocator, path);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello prompt\n", data);
}

test "monotonicNowNs: monotonic non-zero" {
    const a = monotonicNowNs();
    const b = monotonicNowNs();
    try testing.expect(a > 0 and b >= a);
}

test "ignoreIoErr: swallows error cleanly" {
    ignoreIoErr(error.BrokenPipe);
}

test "exitIfSignaled: no-op when no signal received" {
    received_signal.store(0, .seq_cst);
    exitIfSignaled();
}

test "stdoutWriter and stderrWriter return stable interfaces" {
    const a = stdoutWriter();
    const b = stdoutWriter();
    try testing.expectEqual(a, b);
    const c = stderrWriter();
    const d = stderrWriter();
    try testing.expectEqual(c, d);
}

test "parseErrorMessage: known error has message, unknown returns null" {
    try testing.expect(parseErrorMessage(error.UnsupportedFlag) != null);
    try testing.expect(parseErrorMessage(error.BadInteger) == null);
}

test "exhaustive: every driver.RunError and daemon.RunError maps to exit code 2 or 124" {
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
                try testing.expectEqual(@as(u8, 124), code);
                try testing.expect(runErrorMessage(err) != null);
            } else {
                try testing.expectEqual(@as(u8, 2), code);
            }
        }
    }
}
