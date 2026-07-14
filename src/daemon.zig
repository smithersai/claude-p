//! Long-lived multi-turn daemon mode.
//!
//! Stays alive across many user prompts, reusing one PTY-driven `claude`
//! session. Designed as a drop-in replacement for
//! `claude -p --input-format stream-json --output-format stream-json --verbose`:
//!
//!   - stdin: NDJSON lines of `{"type":"user","message":{"role":"user","content":"..."}}`
//!   - stdout: NDJSON lines as `claude -p` would emit them (raw transcript
//!     lines as they're flushed, plus one trailing `result` envelope per
//!     turn)
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
const std = @import("std");
const zmux = @import("zmux");

const driver_mod = @import("driver.zig");
const hook_mod = @import("hook.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const stream_mod = @import("stream.zig");

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
    /// Wall-time cap for the *initial* SessionStart wait. After that the
    /// daemon runs until stdin EOF or the child exits.
    session_start_timeout_ms: u64 = 300_000,
    /// While busy, kill the session if no PTY output has been observed for
    /// this long. Detects a genuinely hung Ink TUI (Stop hook never fires)
    /// without false-killing long turns that keep emitting tool progress.
    /// Set to 0 to disable.
    idle_progress_timeout_ms: u64 = 180_000,
};

pub const RunError = error{
    SessionStartTimeout,
    IdleTimeout,
    TranscriptUnavailable,
    SpawnFailed,
} || std.mem.Allocator.Error;

const State = enum {
    /// Spawned, waiting for SessionStart hook.
    waiting_for_ready,
    /// SessionStart fired, transcript opened, awaiting prompt from stdin.
    idle,
    /// Prompt typed, awaiting Stop hook.
    busy,
};

/// Decide whether a busy turn has stalled: no PTY output for longer than the
/// idle-progress timeout. Only meaningful while `.busy` — `.idle` /
/// `.waiting_for_ready` never time out here (an idle daemon legitimately
/// produces no PTY output while waiting for the next prompt).
///
/// `last_output_ns == 0` (no output observed yet) never trips. The caller
/// MUST reset `last_output_ns` to "now" when transitioning idle→busy;
/// otherwise a long idle period leaves a stale timestamp that trips this on
/// the very first busy loop even though the child is healthy and simply hasn't
/// had time to respond to the new prompt yet.
fn idleTimedOut(state: State, last_output_ns: i64, now_ns: i128, timeout_ms: u64) bool {
    if (timeout_ms == 0) return false;
    if (state != .busy) return false;
    if (last_output_ns == 0) return false;
    const idle_ms: i64 = @intCast(@divTrunc(now_ns - @as(i128, last_output_ns), std.time.ns_per_ms));
    return idle_ms > @as(i64, @intCast(timeout_ms));
}

/// Translate daemon Options to a driver.Options (which buildArgv takes).
/// Prompt stays empty — buildArgv never reads it, and the daemon never
/// passes a prompt on argv anyway.
fn toDriverOptions(opts: Options) driver_mod.Options {
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
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p-daemon +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Extract the user-message content from a hub-style stdin frame:
/// `{"type":"user","message":{"role":"user","content":"..."}}`
/// Also accepts `{"type":"user","content":"..."}` for convenience.
/// Returned slice is heap-allocated.
fn parseUserMessageContent(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const tval = obj.get("type") orelse return null;
    if (tval != .string) return null;
    if (!std.mem.eql(u8, tval.string, "user")) return null;

    // Try {message:{content:"..."}} first (claude -p stream-json shape).
    if (obj.get("message")) |mv| {
        if (mv == .object) {
            if (mv.object.get("content")) |cv| {
                if (cv == .string) return try allocator.dupe(u8, cv.string);
                // content can be an array of blocks; concatenate text blocks.
                if (cv == .array) {
                    var buf: std.ArrayList(u8) = .{};
                    errdefer buf.deinit(allocator);
                    for (cv.array.items) |item| {
                        if (item != .object) continue;
                        const btype = item.object.get("type") orelse continue;
                        if (btype != .string) continue;
                        if (!std.mem.eql(u8, btype.string, "text")) continue;
                        const text = item.object.get("text") orelse continue;
                        if (text != .string) continue;
                        try buf.appendSlice(allocator, text.string);
                    }
                    return try buf.toOwnedSlice(allocator);
                }
            }
        }
    }
    // Fallback shape: top-level content.
    if (obj.get("content")) |cv| {
        if (cv == .string) return try allocator.dupe(u8, cv.string);
    }
    return null;
}

/// True if `line` is a `{"type":"ping"}` health-probe frame. Cheap classifier
/// run before `parseUserMessageContent` in the stdin loop so a ping is answered
/// with a `pong` and never queued as a prompt (see SPEC §2.7).
fn isPingFrame(allocator: std.mem.Allocator, line: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const tval = parsed.value.object.get("type") orelse return false;
    if (tval != .string) return false;
    return std.mem.eql(u8, tval.string, "ping");
}

/// Read the byte range [start_pos..end_pos) from a file via pread. Caller
/// owns the returned slice.
fn readFileRange(allocator: std.mem.Allocator, path: []const u8, start_pos: u64, end_pos: u64) ![]u8 {
    if (end_pos <= start_pos) return try allocator.alloc(u8, 0);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const len = end_pos - start_pos;
    var buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < len) {
        const n = try std.posix.pread(file.handle, buf[done..], start_pos + done);
        if (n == 0) break;
        done += n;
    }
    return buf[0..done];
}

/// Flush remaining transcript bytes for the just-finished turn and emit a
/// per-turn `result` envelope. Mirrors `claude -p`'s wire format so a hub
/// driving the daemon over stdin/stdout sees the same shape it would from
/// `claude -p --output-format stream-json`.
fn emitTurnResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    transcript_path: []const u8,
    stop_payload: []const u8,
    tailer: ?*stream_mod.Tailer,
    turn_start_pos: u64,
    turn_start_ns: i128,
) !void {
    // Drain any final transcript flushes claude makes after Stop. The Stop
    // hook can fire a few ms before the trailing assistant line lands on
    // disk; matches the post-Stop retry loop in driver.run.
    if (tailer) |t| {
        var attempt: u32 = 0;
        while (attempt < 20) : (attempt += 1) {
            _ = t.pump(writer) catch 0;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        writer.flush() catch {};
    }

    const turn_end_pos: u64 = if (tailer) |t| t.pos else 0;
    var summary: transcript_mod.Summary = blk: {
        const slice = readFileRange(allocator, transcript_path, turn_start_pos, turn_end_pos) catch null;
        if (slice) |s| {
            defer allocator.free(s);
            if (transcript_mod.parse(allocator, s)) |parsed| break :blk parsed else |_| {}
        }
        const last = (hook_mod.extractLastAssistantMessage(allocator, stop_payload) catch null) orelse try allocator.dupe(u8, "");
        const sid = (hook_mod.extractSessionId(allocator, stop_payload) catch null) orelse try allocator.dupe(u8, "");
        break :blk transcript_mod.Summary{
            .final_text = last,
            .session_id = sid,
            .is_error = false,
            .num_turns = 1,
            .total_cost_usd = 0.0,
            .duration_api_ms = 0,
            .usage = .{},
            .jsonl_replay = try allocator.dupe(u8, ""),
        };
    };
    defer summary.deinit(allocator);

    const dur_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - turn_start_ns, std.time.ns_per_ms));
    try emit_mod.emitJson(allocator, writer, .{
        .summary = &summary,
        .duration_ms = dur_ms,
    });
    writer.flush() catch {};
}

/// Emit a minimal `claude -p stream-json` style `system:init` envelope.
/// Used at startup so hubs can capture the session_id and treat the agent
/// as alive without waiting for the first transcript flush.
fn emitSystemInit(writer: *std.Io.Writer, session_id: []const u8) !void {
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("system");
    try jw.objectField("subtype");
    try jw.write("init");
    try jw.objectField("session_id");
    try jw.write(session_id);
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Emit a `{"type":"pong","ts":<unix_ms>}` health-probe response. Produced by
/// the main event loop in reply to a `ping` frame; its arrival proves the loop
/// is not wedged (see SPEC §2.7).
fn emitPong(writer: *std.Io.Writer) !void {
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("pong");
    try jw.objectField("ts");
    try jw.write(std.time.milliTimestamp());
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Return true if `fd` has data available to read, without blocking.
/// Uses poll(2) with a 0 timeout. POLLHUP / POLLERR also report as readable
/// so a subsequent read() can pick up EOF.
fn fdReadable(fd: std.posix.fd_t) bool {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    if (ready == 0) return false;
    return (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

/// Daemon entry. Runs until stdin EOF (callers close the spawned daemon's
/// stdin to signal shutdown) or until the child `claude` exits.
pub fn run(allocator: std.mem.Allocator, opts: Options) !u8 {
    const trace_start: i128 = std.time.nanoTimestamp();
    trace(opts, trace_start, "daemon.run() entered");

    // ----------- 1. Hook harness + argv + env -----------
    var harness = try hook_mod.create(allocator);
    defer harness.deinit();

    const claude_bin = opts.claude_path orelse "claude";
    const drv_opts = toDriverOptions(opts);

    var argv = try driver_mod.buildArgv(allocator, claude_bin, harness.settings_json, drv_opts);
    defer argv.deinit(allocator);

    const shell_cmd = try driver_mod.shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    var env_list: std.ArrayList([]const u8) = .{};
    defer {
        for (env_list.items) |s| allocator.free(s);
        env_list.deinit(allocator);
    }
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    var env_it = env_map.iterator();
    while (env_it.next()) |e| {
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

    // ----------- 2. FIFO for hook events -----------
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    // ----------- 3. SharedState + spawn zmux session -----------
    var shared: driver_mod.SharedState = .{
        .session = undefined,
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
        .emit = driver_mod.onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p-daemon",
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
    trace(opts, trace_start, "zmux session spawned; Ink booting");

    // ----------- 4. stdin (poll-driven) + stdout buffered writer -----------
    const stdin_fd = std.posix.STDIN_FILENO;
    var stdout_file = std.fs.File.stdout();
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // ----------- 5. Main loop -----------
    var state: State = .waiting_for_ready;
    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var tailer: ?stream_mod.Tailer = null;
    defer if (tailer) |*t| t.deinit();

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var stdin_buf: std.ArrayList(u8) = .{};
    defer stdin_buf.deinit(allocator);
    var stdin_read_buf: [4096]u8 = undefined;

    var prompt_queue: std.ArrayList([]u8) = .{};
    defer {
        for (prompt_queue.items) |p| allocator.free(p);
        prompt_queue.deinit(allocator);
    }

    var turn_start_ns: i128 = 0;
    // Bytes already accounted for in a prior turn's result envelope. Lets us
    // compute per-turn totals from the JSONL slice [turn_start_pos..tailer.pos).
    var turn_start_pos: u64 = 0;
    const session_start_deadline_ns: i128 = trace_start + @as(i128, @intCast(opts.session_start_timeout_ms)) * std.time.ns_per_ms;
    var stdin_eof = false;

    // PTY byte-rate trace: emit one structured line per interval so we can
    // see whether Ink keeps rendering during a real wedge (spinner ticking
    // → pty_delta > 0) vs. a fully stuck process (pty_delta == 0).
    //
    // Configurable via CLAUDE_P_PTY_TRACE:
    //   unset                  -> default 60s interval
    //   "0"/"off"/"false"/"no" -> disabled (no trace lines)
    //   <positive integer>     -> interval in seconds
    var pty_trace_enabled = true;
    var pty_trace_interval_ns: i128 = 60 * std.time.ns_per_s;
    if (std.posix.getenv("CLAUDE_P_PTY_TRACE")) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n");
        if (v.len == 0) {
            // empty -> keep default
        } else if (std.mem.eql(u8, v, "0") or
            std.ascii.eqlIgnoreCase(v, "off") or
            std.ascii.eqlIgnoreCase(v, "false") or
            std.ascii.eqlIgnoreCase(v, "no"))
        {
            pty_trace_enabled = false;
        } else if (std.fmt.parseInt(u32, v, 10)) |secs| {
            if (secs > 0) pty_trace_interval_ns = @as(i128, secs) * std.time.ns_per_s;
        } else |_| {
            // unparseable -> keep default 60s
        }
    }
    var next_pty_trace_ns: i128 = trace_start + pty_trace_interval_ns;
    var last_pty_bytes_seen: u64 = 0;

    while (true) {
        // ----- timeout checks -----
        const now_ns: i128 = std.time.nanoTimestamp();

        if (pty_trace_enabled and now_ns >= next_pty_trace_ns) {
            const cur_bytes = shared.bytes_seen.load(.seq_cst);
            const delta = cur_bytes - last_pty_bytes_seen;
            const last_out: i64 = shared.last_output_ns.load(.seq_cst);
            const last_out_age_ms: i64 = if (last_out == 0) -1 else @intCast(@divTrunc(now_ns - @as(i128, last_out), std.time.ns_per_ms));
            const turn_age_ms: i64 = if (turn_start_ns == 0) -1 else @intCast(@divTrunc(now_ns - turn_start_ns, std.time.ns_per_ms));
            const transcript_pos: u64 = if (tailer) |t| t.pos else 0;
            std.debug.print("[pty-trace] state={s} pty_bytes={d} pty_delta={d} last_byte_age_ms={d} turn_age_ms={d} transcript_pos={d}\n", .{
                @tagName(state), cur_bytes, delta, last_out_age_ms, turn_age_ms, transcript_pos,
            });
            last_pty_bytes_seen = cur_bytes;
            next_pty_trace_ns = now_ns + pty_trace_interval_ns;
        }

        if (state == .waiting_for_ready and now_ns > session_start_deadline_ns) {
            return RunError.SessionStartTimeout;
        }
        if (idleTimedOut(state, shared.last_output_ns.load(.seq_cst), now_ns, opts.idle_progress_timeout_ms)) {
            traceFmt(opts, trace_start, "idle timeout: no PTY activity since busy start", .{});
            return RunError.IdleTimeout;
        }
        if (shared.exited.load(.seq_cst)) {
            if (state == .waiting_for_ready) return RunError.SpawnFailed;
            // Child exited normally — emit shutdown and exit.
            traceFmt(opts, trace_start, "child claude exited; daemon shutting down", .{});
            // Drain any final transcript bytes.
            if (tailer != null) {
                _ = tailer.?.pump(stdout) catch 0;
                stdout.flush() catch {};
            }
            return 0;
        }

        // ----- flush DEC-responder bytes to PTY -----
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

        // ----- pre-SessionStart modal dialog handling (mirrors driver.run) -----
        if (state == .waiting_for_ready and (!shared.trust_dismissed or !shared.bypass_perms_accepted or !shared.dev_channels_confirmed)) {
            shared.recent_mutex.lock();
            const stripped = try driver_mod.stripCsi(allocator, shared.recent.items);
            shared.recent_mutex.unlock();
            defer allocator.free(stripped);

            const last_out: i64 = shared.last_output_ns.load(.seq_cst);
            const now_ns_i64: i64 = @intCast(std.time.nanoTimestamp());
            const quiescence_ns: i64 = @intCast(driver_mod.dialog_quiescence_ms * std.time.ns_per_ms);
            const quiescent = last_out != 0 and (now_ns_i64 - last_out) > quiescence_ns;
            var fired_this_iter = false;

            if (!shared.trust_dismissed and !fired_this_iter) {
                const has_trust = std.mem.indexOf(u8, stripped, "trust") != null;
                const has_folder = std.mem.indexOf(u8, stripped, "folder") != null;
                if (has_trust and has_folder and quiescent) {
                    trace(opts, trace_start, "workspace-trust dialog detected — Enter");
                    session.send("", true) catch {};
                    shared.trust_dismissed = true;
                    fired_this_iter = true;
                    shared.recent_mutex.lock();
                    shared.recent.clearRetainingCapacity();
                    shared.recent_mutex.unlock();
                    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
                }
            }
            if (!shared.bypass_perms_accepted and !fired_this_iter) {
                const has_bypass = std.mem.indexOf(u8, stripped, "Bypass") != null or
                    std.mem.indexOf(u8, stripped, "bypass") != null;
                const has_permissions = std.mem.indexOf(u8, stripped, "Permissions") != null or
                    std.mem.indexOf(u8, stripped, "permissions") != null;
                const has_accept = std.mem.indexOf(u8, stripped, "accept") != null;
                if (has_bypass and has_permissions and has_accept and quiescent) {
                    trace(opts, trace_start, "bypass-permissions accept dialog detected — '2'+Enter");
                    session.send("2", false) catch {};
                    std.Thread.sleep(driver_mod.ink_enter_debounce_ms * std.time.ns_per_ms);
                    session.send("", true) catch {};
                    shared.bypass_perms_accepted = true;
                    fired_this_iter = true;
                    shared.recent_mutex.lock();
                    shared.recent.clearRetainingCapacity();
                    shared.recent_mutex.unlock();
                    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
                }
            }
            // Development-channels confirmation (--dangerously-load-development-channels).
            // Default selection = option 1 ("I am using this for local development"); bare Enter accepts.
            if (!shared.dev_channels_confirmed and !fired_this_iter) {
                const has_loading = std.mem.indexOf(u8, stripped, "Loading") != null;
                const has_development = std.mem.indexOf(u8, stripped, "development") != null;
                const has_channels = std.mem.indexOf(u8, stripped, "channels") != null;
                if (has_loading and has_development and has_channels and quiescent) {
                    trace(opts, trace_start, "dev-channels dialog detected — Enter");
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

        // ----- drain FIFO (hook events) -----
        const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => 0,
        };
        if (fifo_n > 0) {
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (std.mem.indexOfScalar(u8, fifo_buf.items, '\n')) |nl| {
                const line = fifo_buf.items[0..nl];
                if (hook_mod.parseLine(line)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s}\n", .{@tagName(ev.event)});
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired");
                            if (transcript_path == null) {
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path: {s}", .{p});
                                }
                            }
                            // Emit a synthetic `system:init` envelope so the
                            // hub (or any client expecting `claude -p
                            // stream-json` shape) can capture the session_id
                            // and consider the agent live, regardless of
                            // whether the transcript file already has its
                            // own system entries.
                            if (state == .waiting_for_ready) {
                                const sid = (hook_mod.extractSessionId(allocator, ev.payload) catch null) orelse try allocator.dupe(u8, "");
                                defer allocator.free(sid);
                                emitSystemInit(stdout, sid) catch {};
                                stdout.flush() catch {};
                                driver_mod.waitForInkQuiescent(drv_opts, trace_start, &shared);
                                state = .idle;
                                trace(opts, trace_start, "daemon ready for prompts");
                            }
                        },
                        .user_prompt_submit => {
                            // Daemon tracks turn liveness via its prompt queue
                            // + idle watchdog; the hook fires (registered in
                            // the shared settings) but needs no action here.
                            trace(opts, trace_start, "UserPromptSubmit hook fired");
                        },
                        .stop => {
                            trace(opts, trace_start, "Stop hook fired");
                            if (transcript_path == null) {
                                transcript_path = try hook_mod.extractTranscriptPath(allocator, ev.payload);
                            }
                            if (state == .busy and transcript_path != null) {
                                emitTurnResult(
                                    allocator,
                                    stdout,
                                    transcript_path.?,
                                    ev.payload,
                                    if (tailer) |*t| t else null,
                                    turn_start_pos,
                                    turn_start_ns,
                                ) catch {};
                                if (tailer) |t| turn_start_pos = t.pos;
                            }
                            state = .idle;
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
            }
        }

        // ----- open transcript tailer once path known -----
        // When resuming an existing session, claude appends to the prior
        // transcript file. Reading from byte 0 would re-emit the entire
        // historical session into hub stdout. Skip past existing content
        // by seeking to current EOF on first open.
        if (tailer == null) {
            if (transcript_path) |p| {
                if (stream_mod.Tailer.open(allocator, p)) |t_const| {
                    var t = t_const;
                    if (opts.resume_session != null or opts.cont) {
                        const stat = t.file.stat() catch null;
                        if (stat) |s| {
                            t.pos = s.size;
                            turn_start_pos = s.size;
                            traceFmt(opts, trace_start, "resume: skipped to EOF @ {d} bytes", .{s.size});
                        }
                    }
                    tailer = t;
                    traceFmt(opts, trace_start, "tailer opened: {s}", .{p});
                } else |_| {}
            }
        }

        // ----- pump transcript to stdout (raw lines, as claude flushes them) -----
        if (tailer != null) {
            const n = tailer.?.pump(stdout) catch 0;
            if (n > 0) {
                stdout.flush() catch {};
            }
        }

        // ----- drain stdin (poll-driven; non-blocking via poll() timeout 0) -----
        if (!stdin_eof and fdReadable(stdin_fd)) {
            const sn = std.posix.read(stdin_fd, &stdin_read_buf) catch 0;
            if (sn == 0) {
                stdin_eof = true;
                traceFmt(opts, trace_start, "stdin EOF; will shut down once current turn finishes", .{});
            } else {
                try stdin_buf.appendSlice(allocator, stdin_read_buf[0..sn]);
            }
            while (std.mem.indexOfScalar(u8, stdin_buf.items, '\n')) |nl| {
                const line = stdin_buf.items[0..nl];
                if (isPingFrame(allocator, line)) {
                    // Answered inline by the main loop — proves the loop is live.
                    emitPong(stdout) catch {};
                    stdout.flush() catch {};
                } else if (try parseUserMessageContent(allocator, line)) |content| {
                    try prompt_queue.append(allocator, content);
                }
                std.mem.copyForwards(u8, stdin_buf.items, stdin_buf.items[nl + 1 ..]);
                stdin_buf.shrinkRetainingCapacity(stdin_buf.items.len - (nl + 1));
            }
        }

        // ----- shutdown on stdin EOF once we're idle (no pending turn) -----
        if (stdin_eof and state == .idle and prompt_queue.items.len == 0) {
            traceFmt(opts, trace_start, "stdin EOF + idle; terminating session", .{});
            session.terminate();
            // Drain any final transcript bytes.
            if (tailer != null) {
                _ = tailer.?.pump(stdout) catch 0;
                stdout.flush() catch {};
            }
            return 0;
        }

        // ----- dispatch next prompt if idle -----
        if (state == .idle and prompt_queue.items.len > 0) {
            const content = prompt_queue.orderedRemove(0);
            defer allocator.free(content);
            traceFmt(opts, trace_start, "sending prompt ({d} bytes)", .{content.len});
            driver_mod.waitForInkQuiescent(drv_opts, trace_start, &shared);
            session.send(content, false) catch {};
            std.Thread.sleep(driver_mod.ink_enter_debounce_ms * std.time.ns_per_ms);
            session.send("", true) catch {};
            turn_start_ns = std.time.nanoTimestamp();
            // Reset the idle-progress baseline to "now". Without this, a long
            // idle period (no PTY output) leaves last_output_ns stale and the
            // first busy loop trips idleTimedOut even though the child is
            // healthy and simply hasn't responded to the new prompt yet.
            shared.last_output_ns.store(@intCast(turn_start_ns), .seq_cst);
            state = .busy;
        }

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

// -------- tests --------
const testing = std.testing;

test "parseUserMessageContent: simple string content" {
    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "parseUserMessageContent: array content with text blocks" {
    const line =
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"hi \"}," ++
        "{\"type\":\"text\",\"text\":\"there\"}" ++
        "]}}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi there", out);
}

test "parseUserMessageContent: fallback top-level content" {
    const line = "{\"type\":\"user\",\"content\":\"hi\"}";
    const out = (try parseUserMessageContent(testing.allocator, line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi", out);
}

test "parseUserMessageContent: non-user type returns null" {
    const line = "{\"type\":\"system\",\"content\":\"nope\"}";
    try testing.expectEqual(@as(?[]u8, null), try parseUserMessageContent(testing.allocator, line));
}

test "parseUserMessageContent: malformed returns null" {
    try testing.expectEqual(@as(?[]u8, null), try parseUserMessageContent(testing.allocator, "not json"));
}

test "isPingFrame: ping frame recognized" {
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\"}"));
    try testing.expect(isPingFrame(testing.allocator, "{\"type\":\"ping\",\"id\":7}"));
}

test "isPingFrame: user frame is not a ping" {
    const line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}";
    try testing.expect(!isPingFrame(testing.allocator, line));
}

test "isPingFrame: malformed / non-ping returns false" {
    try testing.expect(!isPingFrame(testing.allocator, "not json"));
    try testing.expect(!isPingFrame(testing.allocator, "{\"type\":\"system\"}"));
    try testing.expect(!isPingFrame(testing.allocator, "{\"foo\":1}"));
}

test "emitPong: shape is a single-line pong object with ts" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    try emitPong(&aw.writer);
    buf = aw.toArrayList();
    const out = buf.items;
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ts\":") != null);
}

test "idleTimedOut: busy + stale last_output trips" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms; // 1_000_000 ms
    const last_out: i64 = 0; // not yet observed → never trips
    try testing.expect(!idleTimedOut(.busy, last_out, now, 180_000));
    // 200s of silence > 180s timeout
    const stale: i64 = @intCast(now - 200_000 * std.time.ns_per_ms);
    try testing.expect(idleTimedOut(.busy, stale, now, 180_000));
}

test "idleTimedOut: busy + fresh baseline does not trip" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    // Just reset on dispatch (last_output == now) → 0ms idle.
    try testing.expect(!idleTimedOut(.busy, @intCast(now), now, 180_000));
    // 1s after a fresh baseline, well under timeout.
    const one_s_ago: i64 = @intCast(now - 1_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.busy, one_s_ago, now, 180_000));
}

test "idleTimedOut: idle/waiting never trip even with ancient timestamp" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 3_600_000 * std.time.ns_per_ms); // 1h ago
    // This is the Bug B regression: an idle daemon parked for an hour must NOT
    // be considered timed out — only .busy is subject to the watchdog.
    try testing.expect(!idleTimedOut(.idle, ancient, now, 180_000));
    try testing.expect(!idleTimedOut(.waiting_for_ready, ancient, now, 180_000));
}

test "idleTimedOut: timeout 0 disables" {
    const now: i128 = 1_000_000 * std.time.ns_per_ms;
    const ancient: i64 = @intCast(now - 3_600_000 * std.time.ns_per_ms);
    try testing.expect(!idleTimedOut(.busy, ancient, now, 0));
}
