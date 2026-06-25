//! Phase 0 spike for the `interrupt` frame (meridian spec
//! 2026-06-25-claude-p-interrupt-frame.md §3). THROWAWAY experiment — not part
//! of the shipped binary's behavior, not a unit test. It answers the load-
//! bearing unknown before any `daemon.zig` change:
//!
//!   When claude's Ink TUI is mid-generation under claude-p's PTY, does
//!   injecting ESC / double-ESC / Ctrl-C (a) stop generation, (b) fire the Stop
//!   hook, (c) leave the session reusable for the next prompt?
//!
//! It reuses claude-p's REAL PTY stack (zmux + driver.onZmuxEvent's DEC
//! responder + the SessionStart/Stop FIFO hook + the modal-dialog handling) so
//! the observed reaction matches what the production daemon would see.
//!
//! Build & run (pick the key sequence to test):
//!   zig build spike-interrupt -- esc
//!   zig build spike-interrupt -- double-esc
//!   zig build spike-interrupt -- ctrl-c
//!
//! Output: a structured S-1/S-2/S-3 observation block on stdout. Interpret S-4
//! (path A/B/C) from it per the spec's decision gate.
//!
//! ======================== RESULTS (2026-06-25) ========================
//! Against real `claude` 2.1.190 under claude-p's PTY stack:
//!
//!   key=esc   : S-1 stopped=TRUE (output quiet ~205ms after inject),
//!               S-2 Stop hook=FALSE (no Stop within a 5s window),
//!               S-3 session reused=TRUE (next prompt produced output).
//!   key=none  : CONTROL — S-1 stopped=FALSE (the fast count does NOT go quiet
//!               prematurely; it runs to natural completion which DOES fire
//!               Stop, S-2=TRUE). Confirms the esc "stop" is a real interrupt,
//!               not a natural pause being misread.
//!
//! ⇒ S-4 DECISION = PATH B (synthesize result).
//!   ESC reliably interrupts generation and leaves the session reusable, but
//!   does NOT fire the Stop hook. So Phase 1 must: on an `interrupt` frame while
//!   busy, inject ESC, then SYNTHESIZE a {result, subtype:"interrupted"} frame
//!   and force state→idle (do not wait for a Stop that never comes; do not kill
//!   the process). ctrl-c/double-esc were not needed (ESC suffices; ctrl-c=0x03
//!   risks SIGINT-killing claude).
//! ======================================================================
const std = @import("std");
const zmux = @import("zmux");
const claude_p = @import("claude_p");

const driver = claude_p.driver;
const hook = claude_p.hook;

/// Which interrupt key sequence to inject (selected by argv[1]).
const KeySeq = enum {
    none, // control: inject nothing (does the long turn naturally go quiet?)
    esc, // \x1b
    double_esc, // \x1b\x1b
    ctrl_c, // \x03

    fn bytes(self: KeySeq) []const u8 {
        return switch (self) {
            .none => "",
            .esc => "\x1b",
            .double_esc => "\x1b\x1b",
            .ctrl_c => "\x03",
        };
    }

    fn fromArg(a: []const u8) ?KeySeq {
        if (std.mem.eql(u8, a, "none")) return .none;
        if (std.mem.eql(u8, a, "esc")) return .esc;
        if (std.mem.eql(u8, a, "double-esc")) return .double_esc;
        if (std.mem.eql(u8, a, "ctrl-c")) return .ctrl_c;
        return null;
    }
};

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}
fn msSince(start: i128) i64 {
    return @intCast(@divTrunc(nowNs() - start, std.time.ns_per_ms));
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[spike] " ++ fmt ++ "\n", args);
}

const LONG_PROMPT =
    "Count from 1 to 300 as fast as you can with NO pauses. Put each number on its " ++
    "own line and nothing else. Output continuously until you reach 300.";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- args: key sequence ----
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const key: KeySeq = if (args.len >= 2) (KeySeq.fromArg(args[1]) orelse {
        dbg("unknown key seq '{s}'; use: esc | double-esc | ctrl-c", .{args[1]});
        return error.BadArg;
    }) else .esc;
    dbg("injecting key sequence: {s}", .{@tagName(key)});

    const trace_start = nowNs();

    // ---- hook harness (SessionStart/Stop → FIFO), reused verbatim ----
    var harness = try hook.create(allocator, &.{}, null);
    defer harness.deinit();

    // ---- argv + env (mirror daemon.run) ----
    const drv_opts: driver.Options = .{
        .prompt = "",
        .output_format = .stream_json,
        .skip_permissions = true,
        .verbose = true,
        .cols = 120,
        .rows = 40,
        .debug = false,
    };
    var argv = try driver.buildArgv(allocator, "claude", harness.settings_json, drv_opts);
    defer argv.deinit(allocator);
    const shell_cmd = try driver.shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    var env_list: std.ArrayList([]const u8) = .{};
    defer {
        for (env_list.items) |s| allocator.free(s);
        env_list.deinit(allocator);
    }
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    var it = env_map.iterator();
    while (it.next()) |e|
        try env_list.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try env_list.append(allocator, try std.fmt.allocPrint(allocator, "CLAUDE_P_FIFO={s}", .{harness.fifo_path}));
    try env_list.append(allocator, try allocator.dupe(u8, "TERM=xterm-256color"));

    // ---- FIFO ----
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = try std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    defer std.posix.close(fifo_fd);

    // ---- shared state + zmux session (onZmuxEvent gives DEC + output stats) ----
    var shared: driver.SharedState = .{ .session = undefined, .debug = false };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
    }
    const sink: zmux.native.EventSink = .{ .context = @ptrCast(&shared), .emit = driver.onZmuxEvent };
    const session = try zmux.NativeSession.create(allocator, .{
        .id = "claude-p-spike",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .env = env_list.items,
        .rows = 40,
        .cols = 120,
        .event_sink = sink,
    });
    shared.session = session;
    defer session.destroy();
    dbg("spawned claude under zmux; waiting for SessionStart", .{});

    // ---- observation state ----
    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read: [4096]u8 = undefined;

    var ready = false;
    var prompt_sent = false;
    var injected = false;
    var inject_ns: i128 = 0;
    var bytes_at_inject: u64 = 0;
    var stop_fired = false;
    var stop_ns: i128 = 0;
    var quiet_after_inject_ms: i64 = -1; // time from inject until output went quiet
    var reuse_prompt_sent = false;
    var reuse_bytes_at_send: u64 = 0;
    var reuse_produced = false;
    var stream_seen_ns: i128 = 0;

    const deadline = trace_start + 180 * std.time.ns_per_s;

    while (nowNs() < deadline) {
        // flush DEC-responder bytes
        shared.write_mutex.lock();
        const to_write = if (shared.pending_to_pty.items.len > 0) try allocator.dupe(u8, shared.pending_to_pty.items) else null;
        if (to_write != null) shared.pending_to_pty.clearRetainingCapacity();
        shared.write_mutex.unlock();
        if (to_write) |b| {
            session.writeInput(b) catch {};
            allocator.free(b);
        }

        if (shared.exited.load(.seq_cst)) {
            dbg("session exited unexpectedly", .{});
            break;
        }

        // modal dialogs before ready (trust / bypass-permissions / dev-channels)
        if (!ready) handleDialogs(allocator, &shared);

        // drain FIFO for SessionStart / Stop
        const n = std.posix.read(fifo_fd, &fifo_read) catch 0;
        if (n > 0) {
            try fifo_buf.appendSlice(allocator, fifo_read[0..n]);
            while (std.mem.indexOfScalar(u8, fifo_buf.items, '\n')) |nl| {
                const line = fifo_buf.items[0..nl];
                if (hook.parseLine(line)) |ev| switch (ev.event) {
                    .session_start => {
                        if (!ready) {
                            ready = true;
                            dbg("SessionStart @ {d}ms — daemon ready", .{msSince(trace_start)});
                        }
                    },
                    .stop => {
                        if (injected and !stop_fired) {
                            stop_fired = true;
                            stop_ns = nowNs();
                            dbg("Stop hook fired @ {d}ms after inject", .{@as(i64, @intCast(@divTrunc(stop_ns - inject_ns, std.time.ns_per_ms)))});
                        } else if (!injected) {
                            dbg("Stop hook fired BEFORE inject (turn finished too fast — use a longer prompt)", .{});
                        }
                    },
                    .unknown => {},
                };
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
            }
        }

        // ---- state machine ----
        if (ready and !prompt_sent) {
            driver.waitForInkQuiescent(drv_opts, trace_start, &shared);
            dbg("sending long prompt", .{});
            session.send(LONG_PROMPT, false) catch {};
            std.Thread.sleep(driver.ink_enter_debounce_ms * std.time.ns_per_ms);
            session.send("", true) catch {};
            prompt_sent = true;
            shared.last_output_ns.store(@intCast(nowNs()), .seq_cst);
        }

        if (prompt_sent and !injected) {
            // Wait until streaming is clearly underway: meaningful byte volume
            // AND ~2s elapsed since first output, so we interrupt mid-generation.
            const seen = shared.bytes_seen.load(.seq_cst);
            if (stream_seen_ns == 0 and seen > 2000) stream_seen_ns = nowNs();
            if (stream_seen_ns != 0 and msSince(stream_seen_ns) > 2000) {
                bytes_at_inject = seen;
                dbg("injecting {s} mid-turn ({d} bytes seen so far)", .{ @tagName(key), seen });
                session.writeInput(key.bytes()) catch {};
                injected = true;
                inject_ns = nowNs();
            }
        }

        // ---- after inject: detect when output goes quiet ----
        if (injected and quiet_after_inject_ms < 0) {
            const last_out: i64 = shared.last_output_ns.load(.seq_cst);
            const quiet_for_ms: i64 = if (last_out == 0) 0 else @intCast(@divTrunc(nowNs() - @as(i128, last_out), std.time.ns_per_ms));
            // 1.5s of no PTY output after inject == "generation stopped".
            if (quiet_for_ms > 1500 and msSince(inject_ns) > 1500)
                quiet_after_inject_ms = msSince(inject_ns) - quiet_for_ms;
        }

        // ---- test session reuse with a second prompt ----
        // Give Stop a fair chance: proceed as soon as Stop fires, otherwise wait
        // until output is quiet AND ≥5s have elapsed since inject (so an absent
        // Stop is a real "no", not a too-early read).
        const reuse_ready = stop_fired or (quiet_after_inject_ms >= 0 and msSince(inject_ns) > 5000);
        if (injected and reuse_ready and !reuse_prompt_sent) {
            // small settle, drain residual, then send a fresh prompt
            std.Thread.sleep(800 * std.time.ns_per_ms);
            reuse_bytes_at_send = shared.bytes_seen.load(.seq_cst);
            driver.waitForInkQuiescent(drv_opts, trace_start, &shared);
            dbg("session-reuse test: sending second prompt", .{});
            session.send("Reply with exactly: REUSE_OK", false) catch {};
            std.Thread.sleep(driver.ink_enter_debounce_ms * std.time.ns_per_ms);
            session.send("", true) catch {};
            reuse_prompt_sent = true;
        }

        if (reuse_prompt_sent and !reuse_produced) {
            // grew by a clear margin after the reuse prompt → session alive
            if (shared.bytes_seen.load(.seq_cst) > reuse_bytes_at_send + 200) {
                reuse_produced = true;
                dbg("session-reuse: second prompt produced output", .{});
                // give it a moment, then we're done
                std.Thread.sleep(1500 * std.time.ns_per_ms);
                break;
            }
        }

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    session.terminate();

    // ---- structured observation block (interpret S-4 from this) ----
    const out = std.fs.File.stdout();
    var buf: [2048]u8 = undefined;
    const interrupted = quiet_after_inject_ms >= 0 and quiet_after_inject_ms < 3000;
    const report = try std.fmt.bufPrint(&buf,
        \\
        \\======== INTERRUPT SPIKE OBSERVATIONS ========
        \\ key_sequence        : {s}
        \\ reached_ready       : {}
        \\ prompt_sent         : {}
        \\ injected            : {}
        \\ bytes_at_inject     : {d}
        \\ S-1 stopped_gen     : {}   (output went quiet {d} ms after inject; <3000ms ⇒ interrupted)
        \\ S-2 stop_hook_fired : {}
        \\ S-3 session_reused  : {}
        \\----------------------------------------------
        \\ S-4 hint: if S-1=false ⇒ path C (this key ineffective; try another / abandon).
        \\           if S-1=true & S-2=true ⇒ path A (rely on Stop).
        \\           if S-1=true & S-2=false ⇒ path B (synthesize result).
        \\==============================================
        \\
    , .{
        @tagName(key), ready, prompt_sent, injected, bytes_at_inject,
        interrupted, quiet_after_inject_ms, stop_fired, reuse_produced,
    });
    _ = try out.write(report);
}

/// Modal-dialog handling lifted from daemon.run: dismiss workspace-trust,
/// accept bypass-permissions, confirm dev-channels. Keeps claude from hanging
/// at a pre-SessionStart prompt.
fn handleDialogs(allocator: std.mem.Allocator, shared: *driver.SharedState) void {
    if (shared.trust_dismissed and shared.bypass_perms_accepted and shared.dev_channels_confirmed) return;
    shared.recent_mutex.lock();
    const stripped = driver.stripCsi(allocator, shared.recent.items) catch {
        shared.recent_mutex.unlock();
        return;
    };
    shared.recent_mutex.unlock();
    defer allocator.free(stripped);

    const last_out: i64 = shared.last_output_ns.load(.seq_cst);
    const quiescent = last_out != 0 and
        (@as(i64, @intCast(std.time.nanoTimestamp())) - last_out) > @as(i64, @intCast(driver.dialog_quiescence_ms * std.time.ns_per_ms));
    if (!quiescent) return;

    if (!shared.trust_dismissed and
        std.mem.indexOf(u8, stripped, "trust") != null and std.mem.indexOf(u8, stripped, "folder") != null)
    {
        shared.session.send("", true) catch {};
        shared.trust_dismissed = true;
        clearRecent(shared);
        return;
    }
    if (!shared.bypass_perms_accepted and
        (std.mem.indexOf(u8, stripped, "Bypass") != null or std.mem.indexOf(u8, stripped, "bypass") != null) and
        (std.mem.indexOf(u8, stripped, "Permissions") != null or std.mem.indexOf(u8, stripped, "permissions") != null) and
        std.mem.indexOf(u8, stripped, "accept") != null)
    {
        shared.session.send("2", false) catch {};
        std.Thread.sleep(driver.ink_enter_debounce_ms * std.time.ns_per_ms);
        shared.session.send("", true) catch {};
        shared.bypass_perms_accepted = true;
        clearRecent(shared);
        return;
    }
    if (!shared.dev_channels_confirmed and
        std.mem.indexOf(u8, stripped, "Loading") != null and
        std.mem.indexOf(u8, stripped, "development") != null and
        std.mem.indexOf(u8, stripped, "channels") != null)
    {
        shared.session.send("", true) catch {};
        shared.dev_channels_confirmed = true;
        clearRecent(shared);
    }
}

fn clearRecent(shared: *driver.SharedState) void {
    shared.recent_mutex.lock();
    shared.recent.clearRetainingCapacity();
    shared.recent_mutex.unlock();
    shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
}
