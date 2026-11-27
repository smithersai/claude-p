//! End-to-end shell-fixture tests for the persistent multi-turn daemon.
const std = @import("std");
const claude_p = @import("claude_p");
const driver_mod = claude_p.driver;
const hook_mod = claude_p.hook;
const daemon = claude_p.daemon;
const Options = daemon.Options;
const TurnTranscript = daemon.turn.TurnTranscript;
const emitTurnResult = daemon.turn.emitTurnResult;
const pumpTranscript = daemon.turn.pumpTranscript;
const writeFailureExit = daemon.protocol.writeFailureExit;
const max_queued_prompts = daemon.protocol.max_queued_prompts;
const requestInterrupt = daemon.requestInterrupt;
const runWithIo = daemon.runWithIo;
const testing = std.testing;

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

const fixture_relay =
    "stty raw -echo\n" ++
    "[ \"$1\" = --settings ]\n" ++
    "relay=$(python3 -c 'import json,shlex,sys; " ++
    "print(shlex.split(json.loads(sys.argv[1])[\"hooks\"][\"Stop\"][0][\"hooks\"][0][\"command\"])[0])' \"$2\")\n";

test "daemon reports spontaneous child exit before readiness, while idle, and during a turn" {
    const ready = fixture_relay ++
        \\printf '{"session_id":"fixture"}\n' | "$relay" SessionStart
        \\
    ;
    const busy = ready ++
        \\# Consume the bracketed paste markers, four prompt bytes, and Enter.
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
        \\
    ;
    const cases = [_]struct { script: []const u8, input: []const u8 = "", ready: bool = true, stopped: bool = false }{
        .{ .script = "exit 7\n", .ready = false },
        .{ .script = ready ++ "exit 0\n" },
        .{ .script = busy, .input = "{\"type\":\"user\",\"content\":\"test\"}\n" },
        .{ .script = busy ++
            \\# Finish delivering Stop after the PTY owner exits.
            \\trap '' HUP
            \\(sleep 0.05; printf '{"last_assistant_message":"done"}\n' | "$relay" Stop) </dev/null >/dev/null 2>&1 &
            \\
        , .input = "{\"type\":\"user\",\"content\":\"test\"}\n", .stopped = true },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            const script = try tmp.dir.createFile("child", .{ .mode = 0o700 });
            defer script.close();
            try script.writeAll("#!/bin/sh\nset -eu\n");
            try script.writeAll(case.script);
        }
        const path = try tmp.dir.realpathAlloc(testing.allocator, "child");
        defer testing.allocator.free(path);
        const pipe = try std.posix.pipe();
        defer std.posix.close(pipe[0]);
        // Keep stdin live past the child exit. Bound the fixture even if an
        // idle daemon regresses to waiting indefinitely for the next frame.
        var finished = std.atomic.Value(bool).init(false);
        const closer = try std.Thread.spawn(.{}, struct {
            fn close(fd: std.posix.fd_t, done: *std.atomic.Value(bool)) void {
                defer std.posix.close(fd);
                for (0..500) |_| {
                    if (done.load(.seq_cst)) break;
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.close, .{ pipe[1], &finished });
        defer {
            finished.store(true, .seq_cst);
            closer.join();
        }
        if (case.input.len > 0) try (std.fs.File{ .handle = pipe[1] }).writeAll(case.input);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const code = try runWithIo(testing.allocator, .{
            .claude_path = path,
            .session_start_timeout_ms = 3000,
            .idle_progress_timeout_ms = 3000,
        }, pipe[0], &out.writer);
        try testing.expectEqual(@as(u8, 2), code);
        var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
        if (case.ready) try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingInit, "\"subtype\":\"init\"") != null);
        if (case.stopped) try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingStop, "\"result\":\"done\"") != null);
        try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingExit, "\"error\":\"child_exited\"") != null);
        try testing.expect(lines.next() == null);
    }
}

const fixture_input = "{\"type\":\"user\",\"content\":\"test\"}\n";
const fixture_ready = fixture_relay ++
    \\file="$PWD/transcript"
    \\: > "$file"
    \\printf '{"session_id":"first","transcript_path":"%s"}' "$file" | "$relay" SessionStart
    \\dd bs=1 count=17 of=/dev/null 2>/dev/null
    \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
    \\
;

fn fixtureRun(script: []const u8, input: []const u8, writer: *std.Io.Writer) !u8 {
    return fixtureRunWithOptions(script, input, writer, .{});
}

fn fixtureRunWithOptions(script: []const u8, input: []const u8, writer: *std.Io.Writer, options: Options) !u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const exe = try tmp.dir.createFile("child", .{ .mode = 0o700 });
        defer exe.close();
        try exe.writeAll("#!/bin/sh\nset -eu\n");
        try exe.writeAll(script);
    }
    try tmp.dir.writeFile(.{ .sub_path = "stdin", .data = input });
    const stdin = try tmp.dir.openFile("stdin", .{});
    defer stdin.close();
    const exe = try tmp.dir.realpathAlloc(testing.allocator, "child");
    defer testing.allocator.free(exe);
    var opts = options;
    opts.claude_path = exe;
    opts.cwd = std.fs.path.dirname(exe);
    opts.session_start_timeout_ms = 10_000;
    opts.idle_progress_timeout_ms = 10_000;
    return runWithIo(testing.allocator, opts, stdin.handle, writer);
}

test "daemon responds to ping within 500 ms and cancels a 64 KiB paste before Enter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The child doubles as the hub. A FIFO lets it send the control frames
    // immediately after observing that the daemon has begun the paste.
    const script = try tmp.dir.createFile("child", .{ .mode = 0o700 });
    {
        defer script.close();
        try script.writeAll("#!/bin/sh\nset -eu\n" ++ fixture_relay ++
            \\exec 3>frames
            \\printf '{"session_id":"fixture"}' | "$relay" SessionStart
            \\exec python3 -c '
            \\import json, os, time
            \\with os.fdopen(3, "wb", buffering=0) as hub:
            \\    hub.write(json.dumps({"type":"user","content":"x"*65536}).encode() + b"\n")
            \\    first = os.read(0, 512)
            \\    assert first.startswith(b"\x1b[200~")
            \\    with open("sent_ms", "w") as stamp: stamp.write(str(time.time_ns() // 1000000))
            \\    hub.write(b"{\"type\":\"ping\"}\n{\"type\":\"interrupt\"}\n")
            \\    data = first
            \\    while b"\x15" not in data and b"\r" not in data: data += os.read(0, 1024)
            \\    assert data.endswith(b"\x1b[201~\x15") and b"\r" not in data
            \\    open("cancelled", "w").close()'
        );
    }
    const exe = try tmp.dir.realpathAlloc(testing.allocator, "child");
    defer testing.allocator.free(exe);
    const cwd = std.fs.path.dirname(exe).?;
    const fifo = try std.fs.path.joinZ(testing.allocator, &.{ cwd, "frames" });
    defer testing.allocator.free(fifo);
    const c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
    };
    try testing.expectEqual(0, c.mkfifo(fifo, 0o600));
    // Keep the hub side open through child exit on both Darwin and Linux.
    const input = try std.posix.openZ(fifo, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer std.posix.close(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = try runWithIo(testing.allocator, .{
        .claude_path = exe,
        .cwd = cwd,
        .session_start_timeout_ms = 3000,
        .idle_progress_timeout_ms = 3000,
    }, input, &out.writer);
    try testing.expectEqual(2, code);
    try tmp.dir.access("cancelled", .{});
    const sent = try tmp.dir.readFileAlloc(testing.allocator, "sent_ms", 32);
    defer testing.allocator.free(sent);
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next() orelse return error.MissingInit;
    const pong = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next() orelse return error.MissingPong, .{});
    defer pong.deinit();
    try testing.expectEqualStrings("pong", pong.value.object.get("type").?.string);
    const latency = pong.value.object.get("ts").?.integer - try std.fmt.parseInt(i64, sent, 10);
    try testing.expect(latency >= 0 and latency < 500);
    try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingInterrupt, "\"error\":\"interrupted\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next() orelse return error.MissingExit, "\"error\":\"child_exited\"") != null);
}

test "daemon startup EOF and invalid frames complete without waiting for SessionStart" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun("exec sleep 20", "\n\r\n   \t\r\n", &out.writer));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqual(0, try fixtureRun("exec sleep 20", "{", &out.writer));
    try testing.expectEqualStrings("{\"type\":\"error\",\"error\":\"invalid_json\"}\n", out.written());
}

test "daemon missing claude emits one session error with exit 2" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(2, try runWithIo(testing.allocator, .{ .claude_path = "/nonexistent/claude-p/claude" }, -1, &out.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("result", parsed.value.object.get("type").?.string);
    try testing.expectEqualStrings("error", parsed.value.object.get("subtype").?.string);
    try testing.expectEqualStrings("claude_not_found", parsed.value.object.get("error").?.string);
}

test "daemon sends ESC for permission and ignores abandoned Stop before next acknowledgment" {
    const script = fixture_ready ++
        \\printf '{"tool_name":"Bash"}' | "$relay" PermissionRequest
        \\[ "$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" = 27 ]
        \\# Ctrl-U, paste markers, four prompt bytes, Enter.
        \\dd bs=1 count=18 of=/dev/null 2>/dev/null
        \\printf '%s\n' '{"type":"assistant","message":{"content":"abandoned record"}}' >> "$file"
        \\printf '{"last_assistant_message":"abandoned"}' | "$relay" Stop
        \\sleep 0.25
        \\printf '{"session_id":"second"}' | "$relay" SessionStart
        \\printf '{"prompt":"next"}' | "$relay" UserPromptSubmit
        \\printf '{"last_assistant_message":"accepted"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input ++ "{\"type\":\"user\",\"content\":\"next\"}\n", &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    const denied = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer denied.deinit();
    const obj = denied.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("error_during_execution", obj.get("subtype").?.string);
    try testing.expectEqualStrings("permission_prompt_blocked", obj.get("error").?.string);
    try testing.expectEqualStrings("Bash", obj.get("message").?.string);
    const next = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer next.deinit();
    try testing.expectEqualStrings("accepted", next.value.object.get("result").?.string);
    try testing.expectEqualStrings("second", next.value.object.get("session_id").?.string);
    try testing.expect(lines.next() == null);
}

test "daemon waits for configured PermissionRequest and slow blocking Stop hooks" {
    const script = fixture_ready ++
        \\printf '{}' | "$relay" PermissionRequest
        \\printf '{"last_assistant_message":"draft"}' | "$relay" Stop
        \\sleep 0.5
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":true}' >> "$file"
        \\sleep 1.65
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}],"usage":{"output_tokens":3}}}' >> "$file"
        \\printf '{"last_assistant_message":"final"}' | "$relay" Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary"}' >> "$file"
        \\# A daemon still waiting on the fallback would consume this later failure.
        \\sleep 0.7
        \\printf '{"error":"late failure"}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRunWithOptions(script, fixture_input, &out.writer, .{ .extra_hooks = &.{
        .{ .event = "Stop", .command = "sleep 0.5" }, .{ .event = "PermissionRequest", .command = "true" },
    } }));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"final\"") != null);
}

test "daemon assistant continuation supersedes provisional Stop past the confirmation deadline" {
    const script = fixture_ready ++
        \\printf '{"last_assistant_message":"provisional"}' | "$relay" Stop
        \\sleep 0.04
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}' >> "$file"
        \\sleep 0.3
        \\printf '%s\n' '{"type":"assistant","message":{"content":"final","usage":{"output_tokens":9}}}' >> "$file"
        \\printf '{"last_assistant_message":"final","stop_hook_active":true}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"final\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "provisional") == null);
}

test "daemon confirms Stop after the current user and final assistant records flush late" {
    const script = fixture_ready ++
        \\printf '{"last_assistant_message":"PONG"}' | "$relay" Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"  test  "}]}}' >> "$file"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"}],"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"PONG\"") != null);
}

test "daemon StopFailure drains transcript before one error result and preserves usage" {
    const script = fixture_ready ++
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}],"usage":{"output_tokens":7}}}' >> "$file"
        \\printf '{"last_assistant_message":"quota reached","error":"generic"}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"assistant\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expect(obj.get("is_error").?.bool);
    try testing.expectEqualStrings("error_during_execution", obj.get("subtype").?.string);
    try testing.expectEqualStrings("stop_failure", obj.get("error").?.string);
    try testing.expectEqualStrings("quota reached", obj.get("result").?.string);
    try testing.expectEqual(7, obj.get("usage").?.object.get("output_tokens").?.integer);
    try testing.expect(lines.next() == null);
}

test "daemon StopFailure without hook text preserves transcript text" {
    const script = fixture_ready ++
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial answer"}]}}' >> "$file"
        \\printf '{}' | "$relay" StopFailure
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, fixture_input, &out.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"partial answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":\"stop_failure\"") != null);
}

test "daemon rejects queue overflow without completing a turn" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(2, try fixtureRun("sleep 0.2; exit 1", fixture_input ** (max_queued_prompts + 1), &out.writer));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "{\"type\":\"error\",\"error\":\"queue_full\"}"));
    try testing.expectEqual(1, std.mem.count(u8, out.written(), "\"type\":\"result\""));
}

test "daemon write failure exit distinguishes closed reader from storage errors" {
    try testing.expectEqual(0, writeFailureExit(error.BrokenPipe));
    try testing.expectEqual(2, writeFailureExit(error.NoSpaceLeft));
    try testing.expectEqual(2, writeFailureExit(error.InputOutput));
    try testing.expectEqual(2, writeFailureExit(null));
}

test "daemon consumes an entry interrupt before a subsequent run" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    requestInterrupt();
    try testing.expectEqual(130, try runWithIo(testing.allocator, .{}, -1, &out.writer));
    try testing.expect(!driver_mod.isInterrupted());
    try testing.expectEqual(0, out.written().len);
}

test "daemon tails a new transcript from zero when a slash command was transformed" {
    const script = fixture_relay ++
        \\file="$PWD/transcript"
        \\printf '{"transcript_path":"%s"}' "$file" | "$relay" SessionStart
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"/cmd"}' | "$relay" UserPromptSubmit
        \\printf '%s\n' '{"type":"user","message":{"content":"expanded command"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"usage":{"output_tokens":7}}}' > "$file"
        \\printf '{"last_assistant_message":"done"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRun(script, "{\"type\":\"user\",\"content\":\"/cmd\"}\n", &out.writer));
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    _ = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "expanded command") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"assistant\"") != null);
    const result = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, result, "\"output_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"result\":\"done\"") != null);
}

test "daemon growth watchdog observes resumed transcript before a boundary is known" {
    const script = fixture_relay ++
        \\file="$PWD/transcript"
        \\printf '{"transcript_path":"%s"}' "$file" | "$relay" SessionStart
        \\dd bs=1 count=17 of=/dev/null 2>/dev/null
        \\printf '{"prompt":"test"}' | "$relay" UserPromptSubmit
        \\for i in 1 2 3 4 5; do
        \\    printf '%s\n' '{"type":"assistant","message":{"content":"private history"}}' >> "$file"
        \\    sleep 0.1
        \\done
        \\printf '{"last_assistant_message":"done"}' | "$relay" Stop
        \\exec sleep 5
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(0, try fixtureRunWithOptions(script, fixture_input, &out.writer, .{
        .cont = true,
        .transcript_idle_timeout_ms = 300,
    }));
    try testing.expect(std.mem.indexOf(u8, out.written(), "private history") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"done\"") != null);
}

test "daemon recovers a matched turn on rotation or truncation and skips unmatched history" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(path);
    var transcript: TurnTranscript = .{ .initial_resume = true };
    defer transcript.deinit(a);
    try transcript.observePath(a, "{\"transcript_path\":\"/tmp/invalid\\u0000tail\"}");
    try testing.expect(transcript.path == null);
    transcript.path = try std.fs.path.join(a, &.{ path, "log" });
    transcript.begin(a, false);
    try testing.expect(transcript.initial_resume and transcript.start == null);

    const history = "{\"type\":\"assistant\",\"message\":{\"content\":\"old secret\"}}\n";
    const user = "{\"type\":\"user\",\"message\":{\"content\":\"active\"}}\n";
    const answer = "{\"type\":\"assistant\",\"message\":{\"content\":\"answer\"}}\n";
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // A late transcript with no matching user record may only supply Stop text.
    try tmp.dir.writeFile(.{ .sub_path = "log", .data = history });
    try emitTurnResult(a, &out.writer, &transcript, "active", "{\"last_assistant_message\":\"fallback\"}", false, monotonicNs(), "s");
    try testing.expect(std.mem.indexOf(u8, out.written(), "old secret") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":\"fallback\"") != null);
    try testing.expect(transcript.initial_resume);

    // Same path, new inode with a verified turn boundary.
    try tmp.dir.writeFile(.{ .sub_path = "replacement", .data = history ** 4 ++ user ++ answer });
    try tmp.dir.rename("replacement", "log");
    transcript.refresh(a, "active", true);
    try testing.expectEqual(@as(?u64, history.len * 4), transcript.start);
    try testing.expect(!transcript.initial_resume);
    _ = try pumpTranscript(&transcript.tailer.?, &out.writer);
    const inode = transcript.inode;

    // Same inode, shorter file. A fresh cursor must begin at the new user entry.
    try tmp.dir.writeFile(.{ .sub_path = "log", .data = history ++ user ++ answer });
    transcript.refresh(a, "active", true);
    try testing.expectEqual(inode, transcript.inode);
    try testing.expectEqual(@as(?u64, history.len), transcript.start);
    _ = try pumpTranscript(&transcript.tailer.?, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "old secret") == null);

    // An in-turn path change invalidates that cursor even for equal-sized files.
    try tmp.dir.writeFile(.{ .sub_path = "changed", .data = history });
    const payload = try std.fmt.allocPrint(a, "{{\"transcript_path\":\"{s}/changed\"}}", .{path});
    defer a.free(payload);
    try transcript.observePath(a, payload);
    transcript.refresh(a, "active", true);
    try testing.expect(transcript.start == null and transcript.tailer == null);
}
