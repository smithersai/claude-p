//! Thread-shared PTY runtime state, zmux event callback, DEC reply flushing,
//! Ink quiescence waits, startup dialog dispatch, failure screens, and live
//! transcript stream pumping.
const std = @import("std");
const zmux = @import("zmux");
const stream_mod = @import("../stream.zig");
const terminal_mod = @import("../terminal.zig");
pub const diag = @import("diag.zig");
const dialog_mod = @import("dialog.zig");
const env_mod = @import("env.zig");
const watchdog = @import("watchdog.zig");

/// Maximum bytes retained in the rolling startup-dialog PTY output buffer.
pub const recent_capacity = diag.recent_capacity;
/// Fixed scratch capacity for `decRepliesInto` convenience replies.
pub const dec_reply_capacity = 256;
/// Maximum non-blank lines included in a failure screen diagnostic excerpt.
pub const failure_screen_max_lines = diag.failure_screen_max_lines;
/// Maximum byte length of a failure screen diagnostic excerpt.
pub const failure_screen_max_bytes = diag.failure_screen_max_bytes;
/// Format a privacy-safe `--debug` trace line for a hook event (name and size only).
pub const formatHookTrace = diag.formatHookTrace;
/// Render the tail of raw PTY output for a failure diagnostic, bounded by lines and bytes.
pub const formatFailureScreen = diag.formatFailureScreen;

/// Thread-shared PTY telemetry, DEC reply queue, and startup-dialog state.
pub const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    debug_screen: bool = false,
    deadline_ns: i128 = std.math.maxInt(i128),
    post_start: [2048]u8 = undefined,
    post_start_len: usize = 0,
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_output_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    startup_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dec: terminal_mod.DecDecoder = .{},
    trust_dismissed: bool = false,
    bypass_perms_accepted: bool = false,
    dev_channels_confirmed: bool = false,
    dialog: dialog_mod.DialogState = .{},

    pub fn deinitBuffers(self: *SharedState) void {
        self.write_mutex.lock();
        self.pending_to_pty.deinit(std.heap.page_allocator);
        self.write_mutex.unlock();
        self.recent_mutex.lock();
        self.recent.deinit(std.heap.page_allocator);
        self.recent_mutex.unlock();
    }
};

/// Emit a timestamped debug trace line when `opts.debug` is enabled.
pub fn trace(opts: env_mod.Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const elapsed_ms: i64 = @intCast(@divTrunc(watchdog.monotonicNs() - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] {s}\n", .{ elapsed_ms, label });
}

/// Emit a formatted timestamped debug trace line when `opts.debug` is enabled.
pub fn traceFmt(opts: env_mod.Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const elapsed_ms: i64 = @intCast(@divTrunc(watchdog.monotonicNs() - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Fixed-buffer convenience for callers that only need a prefix of DEC replies.
pub fn decRepliesInto(shared: *SharedState, reply_buf: *[dec_reply_capacity]u8, data: []const u8) []const u8 {
    var backing = std.heap.FixedBufferAllocator.init(reply_buf);
    var replies = std.ArrayList(u8).initCapacity(backing.allocator(), reply_buf.len) catch return &.{};
    shared.dec.feed(backing.allocator(), data, &replies) catch |err| switch (err) {
        else => {},
    };
    std.debug.assert(replies.items.len <= reply_buf.len);
    return replies.items;
}

/// zmux EventSink callback invoked on the reader thread; never writes back to the PTY directly.
pub fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            shared.write_mutex.lock();
            shared.dec.feed(std.heap.page_allocator, po.data, &shared.pending_to_pty) catch |err| switch (err) {
                else => {},
            };
            shared.write_mutex.unlock();
            const now_ns: i64 = @intCast(watchdog.monotonicNs());
            if (shared.startup_done.load(.seq_cst)) {
                recordPostStart(shared, po.data, now_ns);
            } else {
                recordPreStart(shared, po.data, now_ns);
            }
            if (shared.debug) std.debug.print("zmux pane_output: {d} bytes\n", .{po.data.len});
        },
        .session_exited => |se| {
            shared.exited.store(true, .seq_cst);
            if (shared.debug) {
                std.debug.print("zmux session_exited: code={?d} signal={?d}\n", .{ se.exit_code, se.signal });
            }
        },
        .pane_activity, .pane_bell, .foreground_changed => {},
    }
}

fn recordPostStart(shared: *SharedState, data: []const u8, now_ns: i64) void {
    if (shared.debug_screen or shared.debug) {
        shared.recent_mutex.lock();
        defer shared.recent_mutex.unlock();
        const added = @min(data.len, shared.post_start.len);
        const kept = @min(shared.post_start_len, shared.post_start.len - added);
        std.debug.assert(kept + added <= shared.post_start.len);
        const src = shared.post_start[shared.post_start_len - kept .. shared.post_start_len];
        std.mem.copyForwards(u8, shared.post_start[0..kept], src);
        @memcpy(shared.post_start[kept..][0..added], data[data.len - added ..]);
        shared.post_start_len = kept + added;
    }
    _ = shared.bytes_seen.fetchAdd(data.len, .seq_cst);
    shared.last_output_ns.store(now_ns, .seq_cst);
}

fn recordPreStart(shared: *SharedState, data: []const u8, now_ns: i64) void {
    shared.recent_mutex.lock();
    defer shared.recent_mutex.unlock();
    shared.recent.appendSlice(std.heap.page_allocator, data) catch |err| switch (err) {
        else => {},
    };
    if (shared.recent.items.len > recent_capacity) {
        const drop = shared.recent.items.len - recent_capacity;
        std.mem.copyForwards(u8, shared.recent.items[0..recent_capacity], shared.recent.items[drop..]);
        shared.recent.shrinkRetainingCapacity(recent_capacity);
    }
    std.debug.assert(shared.recent.items.len <= recent_capacity);
    _ = shared.bytes_seen.fetchAdd(data.len, .seq_cst);
    shared.last_output_ns.store(now_ns, .seq_cst);
}

/// Drain queued DEC-query responses from the reader thread to the PTY without heap allocation.
pub fn flushPendingToPty(shared: *SharedState, session: *zmux.NativeSession) void {
    var buf: [512]u8 = undefined;
    while (true) {
        shared.write_mutex.lock();
        const n = @min(buf.len, shared.pending_to_pty.items.len);
        if (n > 0) {
            @memcpy(buf[0..n], shared.pending_to_pty.items[0..n]);
            shared.pending_to_pty.replaceRangeAssumeCapacity(0, n, &.{});
        }
        shared.write_mutex.unlock();
        if (n == 0) return;
        session.writeInput(buf[0..n]) catch |err| switch (err) {
            else => return,
        };
    }
}

/// Sleep up to `duration_ms` while flushing DEC replies and checking interrupts/deadlines.
pub fn sleepPumpingDec(shared: *SharedState, session: ?*zmux.NativeSession, duration_ms: u64) void {
    const end_ns = @min(shared.deadline_ns, watchdog.monotonicNs() + @as(i128, duration_ms) * std.time.ns_per_ms);
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        if (watchdog.isInterrupted()) return;
        const rem_ns = end_ns - watchdog.monotonicNs();
        if (rem_ns <= 0) return;
        const step_ns: u64 = @intCast(@min(rem_ns, @as(i128, 15 * std.time.ns_per_ms)));
        std.Thread.sleep(step_ns);
    }
}

/// Wait until PTY output stays quiet for `quiet_ms` or `max_ms` elapses.
pub fn waitForOutputQuiet(
    opts: env_mod.Options,
    trace_start: i128,
    shared: *SharedState,
    session: ?*zmux.NativeSession,
    quiet_ms: u64,
    max_ms: u64,
) bool {
    const quiescence_ns: i64 = @intCast(quiet_ms * std.time.ns_per_ms);
    const max_ns: i64 = @intCast(max_ms * std.time.ns_per_ms);
    const wait_started: i64 = @intCast(watchdog.monotonicNs());
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        if (watchdog.isInterrupted() or watchdog.monotonicNs() >= shared.deadline_ns) return false;
        const now: i64 = @intCast(watchdog.monotonicNs());
        if (now - wait_started > max_ns) {
            traceFmt(opts, trace_start, "Ink readiness wait hit max ({d}ms) — typing anyway", .{max_ms});
            return false;
        }
        const last: i64 = shared.last_output_ns.load(.seq_cst);
        if (last != 0 and now - last > quiescence_ns) {
            const since_ms: i64 = @divTrunc(now - last, std.time.ns_per_ms);
            const waited_ms: i64 = @divTrunc(now - wait_started, std.time.ns_per_ms);
            traceFmt(opts, trace_start, "Ink quiescent (silent {d}ms, waited {d}ms)", .{ since_ms, waited_ms });
            return true;
        }
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

/// Block until the child PTY has been quiet for at least `ink_quiescence_ms`.
pub fn waitForInkQuiescent(opts: env_mod.Options, trace_start: i128, shared: *SharedState) void {
    _ = waitForOutputQuiet(opts, trace_start, shared, null, watchdog.ink_quiescence_ms, watchdog.ink_max_wait_ms);
}

/// Settle Ink rendering after `SessionStart` before submitting the first prompt.
pub fn settleBeforePrompt(
    opts: env_mod.Options,
    trace_start: i128,
    shared: *SharedState,
    session: *zmux.NativeSession,
) void {
    if (env_mod.isResumeRun(opts)) {
        _ = waitForOutputQuiet(
            opts,
            trace_start,
            shared,
            session,
            watchdog.resume_quiescence_ms,
            watchdog.resume_max_wait_ms,
        );
        return;
    }
    _ = waitForOutputQuiet(opts, trace_start, shared, session, watchdog.ink_quiescence_ms, watchdog.ink_max_wait_ms);
    sleepPumpingDec(shared, session, watchdog.prompt_settle_ms);
    _ = waitForOutputQuiet(
        opts,
        trace_start,
        shared,
        session,
        watchdog.ink_quiescence_ms,
        watchdog.ink_max_wait_ms / 2,
    );
}

fn snapshotRecent(shared: *SharedState, raw_buf: *[recent_capacity]u8) struct { len: usize, total: u64 } {
    shared.recent_mutex.lock();
    defer shared.recent_mutex.unlock();
    const total = shared.bytes_seen.load(.seq_cst);
    const recent = shared.recent.items;
    const raw_len = @min(recent.len, raw_buf.len);
    @memcpy(raw_buf[0..raw_len], recent[recent.len - raw_len ..]);
    std.debug.assert(raw_len <= raw_buf.len);
    return .{ .len = raw_len, .total = total };
}

/// Pre-SessionStart startup dialog handler using zero-heap stack CSI stripping.
pub fn maybeHandleStartupDialogs(
    opts: env_mod.Options,
    trace_start: i128,
    shared: *SharedState,
    session: *zmux.NativeSession,
) void {
    const st = &shared.dialog;
    if (st.refused != .none or st.keys_sent >= dialog_mod.max_dialog_keys) return;
    const now_ns: i64 = @intCast(watchdog.monotonicNs());
    const last_out: i64 = shared.last_output_ns.load(.seq_cst);
    const quiescence_ns: i64 = @intCast(watchdog.dialog_quiescence_ms * std.time.ns_per_ms);
    if (last_out == 0 or now_ns - last_out <= quiescence_ns) return;

    var raw_buf: [recent_capacity]u8 = undefined;
    const snap = snapshotRecent(shared, &raw_buf);
    if (snap.len == 0) return;
    const fresh_bytes: u64 = snap.total -| st.bytes_at_key;
    const fresh_len: usize = @intCast(@min(fresh_bytes, @as(u64, snap.len)));
    var full_buf: [recent_capacity]u8 = undefined;
    var fresh_buf: [recent_capacity]u8 = undefined;
    const full = dialog_mod.stripCsiInto(&full_buf, raw_buf[0..snap.len]);
    const fresh = dialog_mod.stripCsiInto(&fresh_buf, raw_buf[snap.len - fresh_len .. snap.len]);
    const since_key_ms: i64 = @divTrunc(now_ns - st.last_key_ns, std.time.ns_per_ms);
    const decision = dialog_mod.decideDialog(st.kind, st.last, full, fresh, fresh_bytes, since_key_ms);
    switch (decision.action) {
        .none => return,
        .settled => {
            traceFmt(opts, trace_start, "{s} dialog no longer on screen; done with it", .{@tagName(st.kind)});
            st.kind = .none;
            st.last = .settled;
            st.bytes_at_key = snap.total;
            return;
        },
        .confirm, .move_up, .move_down, .digit => {},
    }
    if (!dialog_mod.dialogConfirmAllowed(opts, decision.kind)) {
        traceFmt(opts, trace_start, "{s} dialog not requested; refusing", .{@tagName(decision.kind)});
        st.kind = decision.kind;
        st.refused = decision.kind;
        return;
    }
    var digit_buf: [1]u8 = undefined;
    const keys = dialog_mod.dialogKeyBytes(decision.action, &digit_buf);
    std.debug.assert(keys.len > 0);
    session.writeInput(keys) catch |err| {
        traceFmt(opts, trace_start, "dialog key write failed: {s}", .{@errorName(err)});
    };
    st.kind = decision.kind;
    st.last = decision.action;
    st.last_key_ns = @intCast(watchdog.monotonicNs());
    st.bytes_at_key = snap.total;
    st.keys_sent += 1;
    if (decision.action == .confirm) switch (decision.kind) {
        .trust => shared.trust_dismissed = true,
        .bypass_permissions => shared.bypass_perms_accepted = true,
        .dev_channels => shared.dev_channels_confirmed = true,
        .none => {},
    };
}

/// Write a formatted failure diagnostic and optional PTY tail to stderr.
pub fn reportFailure(shared: ?*SharedState, debug_screen: bool, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var stderr = std.fs.File.stderr().writerStreaming(&buf);
    writeFailure(&stderr.interface, shared, debug_screen, fmt, args) catch return;
    stderr.interface.flush() catch |err| switch (err) {
        else => {},
    };
}

/// Write a formatted failure diagnostic and optional PTY tail to `writer`.
pub fn writeFailure(
    writer: *std.Io.Writer,
    shared: ?*SharedState,
    debug_screen: bool,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    try writer.print("claude-p: " ++ fmt, args);
    const sh = shared orelse return writer.writeByte('\n');
    try writer.print(" (PTY bytes={d})\n", .{sh.bytes_seen.load(.seq_cst)});
    if (!debug_screen) return;
    var out: [failure_screen_max_bytes]u8 = undefined;
    const screen = blk: {
        sh.recent_mutex.lock();
        defer sh.recent_mutex.unlock();
        const recent = if (sh.startup_done.load(.seq_cst)) sh.post_start[0..sh.post_start_len] else sh.recent.items;
        break :blk formatFailureScreen(&out, recent);
    };
    if (screen.len > 0) try writer.print("claude-p: recent claude output:\n{s}\n", .{screen});
}

/// Pump new transcript lines to `writer` and flush them; propagate write failures and OOM.
pub fn pumpStream(tailer: *stream_mod.Tailer, writer: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!usize {
    std.debug.assert(@intFromPtr(writer) != 0);
    const n = tailer.pump(writer) catch |e| switch (e) {
        error.WriteFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    if (n > 0) try writer.flush();
    return n;
}

// -------- tests --------
const testing = std.testing;

test "trace and traceFmt: no-op when debug is false" {
    trace(.{ .prompt = "p", .debug = false }, 0, "quiet");
    traceFmt(.{ .prompt = "p", .debug = false }, 0, "n={d}", .{1});
}

test "onZmuxEvent: ignores pane_activity and pane_bell" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    defer sh.deinitBuffers();
    onZmuxEvent(@ptrCast(&sh), .{ .pane_activity = .{ .pane_id = "0", .last_activity_ms = 1 } });
    onZmuxEvent(@ptrCast(&sh), .{ .pane_bell = .{ .pane_id = "0", .last_bell_ms = 2 } });
    try testing.expectEqual(@as(u64, 0), sh.bytes_seen.load(.seq_cst));
    try testing.expect(!sh.exited.load(.seq_cst));
}

test "onZmuxEvent: post-start truncates rolling buffer to post_start capacity" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer sh.deinitBuffers();
    sh.startup_done.store(true, .seq_cst);
    const big = "z" ** 3000;
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = big } });
    try testing.expectEqual(sh.post_start.len, sh.post_start_len);
}

test "writeFailure: post-start reads post_start buffer when debug_screen is true" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer sh.deinitBuffers();
    sh.startup_done.store(true, .seq_cst);
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "post-err" } });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeFailure(&aw.writer, &sh, true, "oops", .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "post-err") != null);
}

test "maybeHandleStartupDialogs: returns early when refused or max keys reached" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    sh.dialog.refused = .trust;
    maybeHandleStartupDialogs(.{ .prompt = "p" }, 0, &sh, undefined);
    sh.dialog.refused = .none;
    sh.dialog.keys_sent = dialog_mod.max_dialog_keys;
    maybeHandleStartupDialogs(.{ .prompt = "p" }, 0, &sh, undefined);
    try testing.expectEqual(dialog_mod.max_dialog_keys, sh.dialog.keys_sent);
}

test "maybeHandleStartupDialogs: returns early before any PTY output" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    maybeHandleStartupDialogs(.{ .prompt = "p" }, 0, &sh, undefined);
    try testing.expectEqual(@as(u8, 0), sh.dialog.keys_sent);
}

test "waitForInkQuiescent: returns immediately on expired deadline" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .deadline_ns = 0 };
    waitForInkQuiescent(.{ .prompt = "p" }, 0, &sh);
}

test "decRepliesInto: answers DA1 and DSR queries into fixed buffer" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var buf: [dec_reply_capacity]u8 = undefined;
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R", decRepliesInto(&sh, &buf, "\x1b[c\x1b[6n"));
}

test "decRepliesInto: carries split query across calls" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    var buf: [dec_reply_capacity]u8 = undefined;
    try testing.expectEqualStrings("", decRepliesInto(&sh, &buf, "\x1b["));
    try testing.expectEqualStrings("\x1b[1;1R", decRepliesInto(&sh, &buf, "6n"));
}

test "onZmuxEvent: pre-start appends recent bounded to recent_capacity" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    defer sh.deinitBuffers();
    const big = "x" ** (recent_capacity + 100);
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = big } });
    try testing.expectEqual(recent_capacity, sh.recent.items.len);
    try testing.expectEqual(@as(u64, big.len), sh.bytes_seen.load(.seq_cst));
}

test "onZmuxEvent: post-start freezes recent and updates post_start" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer sh.deinitBuffers();
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "boot" } });
    sh.startup_done.store(true, .seq_cst);
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "after" } });
    try testing.expectEqualStrings("boot", sh.recent.items);
    try testing.expectEqualStrings("after", sh.post_start[0..sh.post_start_len]);
}

test "onZmuxEvent: post-start skips copy when debug_screen false" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    defer sh.deinitBuffers();
    sh.startup_done.store(true, .seq_cst);
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "secret" } });
    try testing.expectEqual(@as(usize, 0), sh.post_start_len);
}

test "onZmuxEvent: queues DEC replies in pending_to_pty" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    defer sh.deinitBuffers();
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "\x1b[6n" } });
    try testing.expectEqualStrings("\x1b[1;1R", sh.pending_to_pty.items);
}

test "onZmuxEvent: session_exited marks exited true" {
    var sh: SharedState = .{ .session = undefined, .debug = false };
    defer sh.deinitBuffers();
    onZmuxEvent(@ptrCast(&sh), .{ .session_exited = .{ .session_id = "s", .pid = 1, .exit_code = 0, .signal = null } });
    try testing.expect(sh.exited.load(.seq_cst));
}

test "writeFailure: omits screen unless debug_screen is true" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer sh.deinitBuffers();
    onZmuxEvent(@ptrCast(&sh), .{ .pane_output = .{ .pane_id = "0", .data = "visible error" } });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeFailure(&aw.writer, &sh, false, "failed", .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "visible error") == null);
    aw.clearRetainingCapacity();
    try writeFailure(&aw.writer, &sh, true, "failed", .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "visible error") != null);
}

test "writeFailure: null shared prints concise message" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeFailure(&aw.writer, null, true, "missing {s}", .{"bin"});
    try testing.expectEqualStrings("claude-p: missing bin\n", aw.written());
}

test "sleepPumpingDec: returns immediately on expired deadline" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .deadline_ns = 0 };
    sleepPumpingDec(&sh, null, 5000);
}

test "waitForOutputQuiet: returns false on expired deadline" {
    var sh: SharedState = .{ .session = undefined, .debug = false, .deadline_ns = 0 };
    try testing.expect(!waitForOutputQuiet(.{ .prompt = "p" }, 0, &sh, null, 50, 500));
}

test "waitForOutputQuiet: returns true once quiet_ms elapsed" {
    const now: i64 = @intCast(watchdog.monotonicNs());
    var sh: SharedState = .{ .session = undefined, .debug = false };
    sh.last_output_ns.store(now - 200 * std.time.ns_per_ms, .seq_cst);
    try testing.expect(waitForOutputQuiet(.{ .prompt = "p" }, now, &sh, null, 50, 500));
}

test "pumpStream: propagates WriteFailed from failing writer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"ok\":1}\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var t = try stream_mod.Tailer.open(testing.allocator, path);
    defer t.deinit();
    var w: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, pumpStream(&t, &w));
}
