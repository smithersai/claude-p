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
        const code = claude_p.daemon.run(allocator, .{
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
            .extra_hooks = opts.extra_hooks.items,
            .setting_json = opts.setting_json,
            .verbose = opts.verbose,
            .session_start_timeout_ms = @as(u64, opts.timeout_seconds) * 1000,
            .idle_progress_timeout_ms = @as(u64, opts.idle_timeout_seconds) * 1000,
            .debug = opts.debug,
        }) catch |err| {
            try stderrWriter().print("claude-p daemon: {s}\n", .{@errorName(err)});
            try stderrWriter().flush();
            // Exit codes per SPEC §2.7: idle watchdog → 124 (timeout family),
            // everything else (session-start timeout, spawn failure) → 2.
            std.process.exit(switch (err) {
                error.IdleTimeout => 124,
                else => 2,
            });
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

    var result = claude_p.run(allocator, .{
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
        .extra_hooks = opts.extra_hooks.items,
        .setting_json = opts.setting_json,
        .verbose = opts.verbose,
        .timeout_ms = @as(u64, opts.timeout_seconds) * 1000,
        .debug = opts.debug,
        .stream_writer = stream_writer,
    }) catch |err| {
        try stderrWriter().print("claude-p: {s}\n", .{@errorName(err)});
        try stderrWriter().flush();
        std.process.exit(2);
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
            "Error: unsupported flag (claude-p emulates `claude -p` and injects its own --settings)\n",
        ),
        else => try w.print("claude-p: bad arguments: {s}\n", .{@errorName(err)}),
    }
    try w.flush();
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
