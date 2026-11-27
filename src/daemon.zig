//! Long-lived multi-turn daemon mode reusing one PTY-driven `claude` session.
const std = @import("std");
const zmux = @import("zmux");
const driver_mod = @import("driver.zig");
const hook_mod = @import("hook.zig");

/// NDJSON input framing, watchdog predicates, and wire emitters.
pub const protocol = @import("daemon/protocol.zig");
/// Per-turn transcript cursor, pending Stop confirmation, and paste state.
pub const turn = @import("daemon/turn.zig");
/// Bounded FIFO prompt queue and PTY settling/tracing helpers.
pub const queue = @import("daemon/queue.zig");
/// Stateful event loop managing a long-lived multi-turn daemon session.
pub const runtime = @import("daemon/runtime.zig");

/// Options for persistent multi-turn daemon mode.
pub const Options = protocol.Options;
/// Error set returned by persistent daemon initialization and I/O failures.
pub const RunError = protocol.RunError;
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

/// Translate daemon `Options` to a `driver.Options` for `buildArgv` and dialog checks.
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

fn prepareSpawnCommand(
    allocator: std.mem.Allocator,
    opts: Options,
    drv_opts: driver_mod.Options,
    settings_json: []const u8,
    stdout: *std.Io.Writer,
) !union(enum) { cmd: []u8, exit_code: u8 } {
    std.debug.assert(settings_json.len > 0);
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

/// Execute the daemon against explicit `stdin_fd` and `stdout` streams.
pub fn runWithIo(
    backing_allocator: std.mem.Allocator,
    opts: Options,
    stdin_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
) !u8 {
    std.debug.assert(@intFromPtr(stdout) != 0);
    const scope = driver_mod.InterruptScope.enter();
    defer scope.exit();
    if (driver_mod.isInterrupted()) {
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
    const trace_start: i128 = @intCast(driver_mod.monotonicNs());
    runtime.trace(opts, trace_start, "daemon.run() entered");

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
    std.debug.assert(shell_cmd.len > 0);

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
    defer shared.deinitBuffers();
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
    queue.trace(opts, trace_start, "zmux session spawned; Ink booting");

    const start_deadline = trace_start +
        @as(i128, @intCast(opts.session_start_timeout_ms)) * std.time.ns_per_ms;
    const interval = protocol.ptyTraceInterval(opts.debug, std.posix.getenv("CLAUDE_P_PTY_TRACE"));
    var loop: runtime.DaemonLoop = .{
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

test "Options: default timeouts and empty hooks match contract" {
    const opts: Options = .{};
    try testing.expectEqual(@as(u64, 300_000), opts.session_start_timeout_ms);
    try testing.expectEqual(@as(u64, 180_000), opts.idle_progress_timeout_ms);
    try testing.expectEqual(@as(u64, 600_000), opts.transcript_idle_timeout_ms);
    try testing.expectEqual(@as(usize, 0), opts.extra_hooks.len);
}

test "Options: default terminal dimensions are 120x40" {
    const opts: Options = .{};
    try testing.expectEqual(@as(u16, 120), opts.cols);
    try testing.expectEqual(@as(u16, 40), opts.rows);
}

test "toDriverOptions: always sets output_format stream_json and empty prompt" {
    const drv = toDriverOptions(.{});
    try testing.expectEqualStrings("", drv.prompt);
    try testing.expectEqual(@as(?u32, null), drv.max_turns);
    try testing.expect(drv.output_format == .stream_json);
}

test "toDriverOptions: forwards extra_hooks, extra_settings_json, and timeout" {
    const hooks = [_]hook_mod.ExtraHook{.{ .event = "PreToolUse", .command = "echo hi" }};
    const drv = toDriverOptions(.{
        .extra_hooks = &hooks,
        .extra_settings_json = "{\"env\":{\"A\":\"1\"}}",
        .session_start_timeout_ms = 42,
    });
    try testing.expectEqual(@as(usize, 1), drv.extra_hooks.len);
    try testing.expectEqualStrings("PreToolUse", drv.extra_hooks[0].event);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\"}}", drv.extra_settings_json.?);
    try testing.expectEqual(@as(u64, 42), drv.timeout_ms);
}

test "toDriverOptions: forwards model, cwd, resume_session, cont, and skip_permissions" {
    const drv = toDriverOptions(.{
        .model = "opus",
        .cwd = "/tmp",
        .resume_session = "sid",
        .cont = true,
        .skip_permissions = true,
    });
    try testing.expectEqualStrings("opus", drv.model.?);
    try testing.expectEqualStrings("/tmp", drv.cwd.?);
    try testing.expectEqualStrings("sid", drv.resume_session.?);
    try testing.expect(drv.cont and drv.skip_permissions);
}

test "runWithIo: consumes pending interrupt immediately with exit 130" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    requestInterrupt();
    try testing.expectEqual(@as(u8, 130), try runWithIo(testing.allocator, .{}, -1, &out.writer));
    try testing.expect(!driver_mod.isInterrupted());
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "runWithIo: rejects unsupported fallback_model with InvalidOptions" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(
        error.InvalidOptions,
        runWithIo(testing.allocator, .{ .fallback_model = "haiku" }, -1, &out.writer),
    );
}

test "runWithIo: rejects invalid extra_settings_json and emits startup stage error" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(
        error.InvalidExtraSettings,
        runWithIo(testing.allocator, .{ .extra_settings_json = "[]" }, -1, &out.writer),
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"stage\":\"hook_settings\"") != null);
}

test "runWithIo: invalid cwd emits cwd startup stage error with exit 2" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = try runWithIo(testing.allocator, .{ .cwd = "/nonexistent/claude-p-daemon-cwd" }, -1, &out.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"stage\":\"cwd\"") != null);
}

test "runWithIo: missing claude binary emits claude_not_found with exit 2" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = try runWithIo(testing.allocator, .{ .claude_path = "/nonexistent/claude" }, -1, &out.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":\"claude_not_found\"") != null);
}

test "re-export: isPingFrame and isInterruptFrame" {
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(isInterruptFrame(testing.allocator, "{\"type\":\"interrupt\"}"));
}

test "re-export: parseUserMessageContent extracts string content" {
    const msg = (try parseUserMessageContent(testing.allocator, "{\"type\":\"user\",\"content\":\"yo\"}")).?;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("yo", msg);
}

test "re-export: idleTimedOut and transcriptStalled" {
    const now: i128 = 500_000 * std.time.ns_per_ms;
    try testing.expect(!idleTimedOut(.idle, 1, now, 100));
    try testing.expect(transcriptStalled(.busy, 1, now, 100));
}

test "re-export: stopBelongsToTurn enforces busy and prompt_acked" {
    try testing.expect(stopBelongsToTurn(.busy, true));
    try testing.expect(!stopBelongsToTurn(.busy, false));
}

test "re-export: elapsedMs clamps negative intervals to 0" {
    try testing.expectEqual(@as(u64, 0), elapsedMs(100, 50));
    try testing.expectEqual(@as(u64, 2), elapsedMs(0, 2 * std.time.ns_per_ms));
}

test "re-export: emitSystemInit writes init frame" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitSystemInit(&aw.writer, "sid");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"session_id\":\"sid\"") != null);
}

test "re-export: emitPong writes pong frame" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPong(&aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"type\":\"pong\"") != null);
}

test "re-export: ptyTraceInterval respects off and explicit seconds" {
    try testing.expectEqual(@as(?i128, null), ptyTraceInterval(true, "off"));
    try testing.expectEqual(@as(?i128, 5 * std.time.ns_per_s), ptyTraceInterval(false, "5"));
}

test "re-export: readInputFrame returns ping" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const frame = (try readInputFrame(testing.allocator, &aw.writer, "{\"type\":\"ping\"}")).?;
    try testing.expect(frame == .ping);
}

test "re-export: readFileRange reads slice from temporary file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "hello" });
    const f = try tmp.dir.openFile("a", .{});
    defer f.close();
    const s = try readFileRange(testing.allocator, f, 1, 4);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("ell", s);
}
