//! `claude-p` CLI entry point. Parses argv, runs the driver, emits output.
const std = @import("std");
const claude_p = @import("claude_p");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv_raw);
    const argv = argv_raw[1..];

    var opts = claude_p.args.parse(allocator, argv) catch |err| {
        try printError(err);
        std.process.exit(2);
    };
    defer opts.deinit(allocator);

    // (printError handles diagnostics; nothing else to do here.)

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
        var daemon_opts: claude_p.daemon.Options = .{
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
            .session_start_timeout_ms = @as(u64, opts.timeout_seconds) * 1000,
            .idle_progress_timeout_ms = @as(u64, opts.idle_timeout_seconds) * 1000,
            .debug = opts.debug,
        };
        // These fields land in daemon.Options with F1; guard so this file
        // compiles both before and after that change.
        const DaemonOptions = claude_p.daemon.Options;
        if (@hasField(DaemonOptions, "transcript_idle_timeout_ms"))
            daemon_opts.transcript_idle_timeout_ms = @as(u64, opts.transcript_idle_timeout_seconds) * 1000;
        if (@hasField(DaemonOptions, "extra_hooks"))
            daemon_opts.extra_hooks = opts.extra_hooks.items;
        if (@hasField(DaemonOptions, "extra_settings_json"))
            daemon_opts.extra_settings_json = opts.extra_settings_json;
        const code = claude_p.daemon.run(allocator, daemon_opts) catch |err| {
            try reportRunError("claude-p daemon", err);
            std.process.exit(exitCodeForRunError(err));
        };
        std.process.exit(code);
    }

    // Resolve prompt: positional, file, or stdin.
    var prompt_buf: ?[]u8 = null;
    defer if (prompt_buf) |p| allocator.free(p);

    const prompt: []const u8 = blk: {
        if (opts.prompt) |p| break :blk p;
        if (opts.input_file) |path| {
            const f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            prompt_buf = try f.readToEndAlloc(allocator, 16 * 1024 * 1024);
            break :blk std.mem.trimRight(u8, prompt_buf.?, "\r\n");
        }
        // Read from stdin.
        var stdin_file = std.fs.File.stdin();
        prompt_buf = try stdin_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        break :blk std.mem.trimRight(u8, prompt_buf.?, "\r\n");
    };

    if (prompt.len == 0) {
        try stderrWriter().writeAll("error: empty prompt (positional, --input-file, or stdin required)\n");
        try stderrWriter().flush();
        std.process.exit(2);
    }

    // For stream-json output, hand stdout to the driver so transcript lines
    // can be written live as `claude` flushes them. Other formats accumulate
    // and emit once at the end.
    const stdout = stdoutWriter();
    const stream_writer: ?*std.Io.Writer =
        if (opts.output_format == .stream_json) stdout else null;

    var run_opts: claude_p.Options = .{
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
        .timeout_ms = @as(u64, opts.timeout_seconds) * 1000,
        .debug = opts.debug,
        .stream_writer = stream_writer,
        .extra_hooks = opts.extra_hooks.items,
        .extra_settings_json = opts.extra_settings_json,
    };
    if (@hasField(claude_p.Options, "transcript_idle_timeout_ms"))
        run_opts.transcript_idle_timeout_ms = @as(u64, opts.transcript_idle_timeout_seconds) * 1000;
    var result = claude_p.run(allocator, run_opts) catch |err| {
        try reportRunError("claude-p", err);
        std.process.exit(exitCodeForRunError(err));
    };
    defer result.deinit(allocator);

    // Result.write is a no-op when stream-json was already streamed.
    try result.write(allocator, stdout, opts.output_format);
    try stdout.flush();

    std.process.exit(result.exitCode());
}

fn printError(err: anyerror) !void {
    var w = stderrWriter();
    // Human-readable messages for the validation errors users actually hit.
    // Everything else falls back to the error name.
    switch (err) {
        error.StreamJsonRequiresVerbose => try w.writeAll(
            "Error: --output-format=stream-json requires --verbose\n",
        ),
        error.UnsupportedFlag => try w.writeAll(
            "Error: unsupported flag. claude-p rejects -p/--print (it emulates print mode), " ++
                "--settings (it injects its own; use --extra-hook or --setting-json), " ++
                "and --bare/--safe-mode (Claude Code skips --settings hooks under them)\n",
        ),
        error.BadExtraHook => try w.writeAll(
            "Error: --extra-hook expects <Event>=<cmd> with a non-empty event and command, " ++
                "e.g. --extra-hook 'PreToolUse=echo hi'\n",
        ),
        else => try w.print("claude-p: bad arguments: {s}\n", .{@errorName(err)}),
    }
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

test "runErrorMessage: prompt and settings errors carry diagnostics" {
    const t = std.testing;
    try t.expect(runErrorMessage(error.PromptNotAccepted) != null);
    try t.expect(runErrorMessage(error.PromptTruncated) != null);
    try t.expect(runErrorMessage(error.InvalidExtraSettings) != null);
    try t.expect(runErrorMessage(error.SpawnFailed) == null);
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
