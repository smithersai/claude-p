//! Shell-fixture and integration-level tests for `driver.zig` (run under `zig build test`).
const std = @import("std");
const claude_p = @import("claude_p");

const driver = claude_p.driver;
const stream_mod = claude_p.stream;
const transcript_mod = claude_p.transcript;
const testing = std.testing;

const run = driver.run;
const Options = driver.Options;
const Result = driver.Result;
const RunError = driver.RunError;
const ResolveError = driver.ResolveError;
const SharedState = driver.SharedState;
const monotonicNs = driver.monotonicNs;
const validateCwd = driver.validateCwd;
const resolveClaudeBinaryIn = driver.resolveClaudeBinaryIn;
const buildShellCommand = driver.buildShellCommand;
const buildShellCommandInDir = driver.buildShellCommandInDir;
const formatHookTrace = driver.formatHookTrace;
const formatFailureScreen = driver.formatFailureScreen;
const failure_screen_max_bytes = driver.failure_screen_max_bytes;
const extractSafeTranscriptPath = driver.extractSafeTranscriptPath;
const dialogConfirmAllowed = driver.dialogConfirmAllowed;
const preferStopText = driver.preferStopText;
const synthesizeStopFailureSummary = driver.synthesizeStopFailureSummary;
const pumpStream = driver.pumpStream;
const onZmuxEvent = driver.onZmuxEvent;
const requestInterrupt = driver.requestInterrupt;
const clearInterrupt = driver.clearInterrupt;
const isInterrupted = driver.isInterrupted;
const interrupted = driver.interrupted;
const isContinuationRecord = driver.isContinuationRecord;
const findPromptTurnOffset = driver.findPromptTurnOffset;
const validateTranscriptPath = driver.validateTranscriptPath;
const reportFailure = driver.reportFailure;
const validateOptions = driver.validateOptions;
const stop_failure_default_text = driver.watchdog.stop_failure_default_text;
const typePromptUntil = driver.paste.typePromptUntil;

const fixture_relay =
    "relay=$(python3 -c 'import json,shlex,sys; " ++
    "print(shlex.split(json.loads(sys.argv[1])[\"hooks\"][\"Stop\"][0][\"hooks\"][0][\"command\"])[0])' \"$2\")\n" ++
    "hook() { \"$relay\" \"$1\"; }\n";

const fixture_shell =
    \\#!/bin/sh
    \\set -eu
    \\stty raw -echo
    \\[ "$1" = --settings ]
    \\
++ fixture_relay ++
    \\printf 'Ready'
    \\file="$PWD/session.jsonl"
    \\: > "$file"
    \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
    \\dd bs=1 count=18 of=/dev/null 2>/dev/null
    \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
    \\
;

fn writeFixture(dir: std.fs.Dir, name: []const u8, body: []const u8) ![]u8 {
    {
        const f = try dir.createFile(name, .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(body);
    }
    return dir.realpathAlloc(testing.allocator, name);
}

fn leftoverHarnessDirs() !usize {
    const root = std.posix.getenv("TMPDIR") orelse "/tmp";
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "claude-p-{d}-", .{std.c.getpid()});
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) n += 1;
    }
    return n;
}

fn interruptOnceRunning(dir: std.fs.Dir) void {
    for (0..1000) |_| {
        if (dir.statFile("pid")) |st| {
            if (st.size > 1) break;
        } else |_| {}
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.Thread.sleep(100 * std.time.ns_per_ms);
    requestInterrupt();
}

test "run: handles 2.1.330 trust dialog, chunked bracketed paste, and resumed transcript isolation end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\
    ++ fixture_relay ++
        \\down=$(printf '\033[B')
        \\enter=$(printf '\r')
        \\printf 'Quick safety check: Is this a project you trust?\r\nreview this folder first.\r\n❯ No, exit\r\n  Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 3)" = "$down" ]
        \\printf '\r  No, exit\r\n❯ Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"previous turn"}]}}' > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\{ printf '\033[200~'; cat prompt; printf '\033[201~\r'; } > expected
        \\read_bytes "$(wc -c < expected | tr -d ' ')" | cmp - expected
        \\hook UserPromptSubmit < submit.json
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"current turn"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"current turn"}' "$file" | hook Stop
        \\
    ;
    const program = try writeFixture(tmp.dir, "mock-claude", fixture);
    defer testing.allocator.free(program);
    const prompt = ("a" ** 511 ++ "🌿\n") ** 6;
    try tmp.dir.writeFile(.{ .sub_path = "prompt", .data = prompt });
    const submit = try std.json.Stringify.valueAlloc(testing.allocator, .{ .prompt = prompt }, .{});
    defer testing.allocator.free(submit);
    try tmp.dir.writeFile(.{ .sub_path = "submit.json", .data = submit });

    const cwd = std.fs.path.dirname(program).?;
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = prompt,
        .cont = true,
        .timeout_ms = 15_000,
        .output_format = .stream_json,
        .stream_writer = &output.writer,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("current turn", result.summary.final_text);
    try testing.expectEqual(@as(u32, 1), result.summary.num_turns);
    try testing.expect(std.mem.indexOf(u8, output.written(), "current turn") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "previous turn") == null);
}

test "run: fails fast if child exits early without Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\
    ++ fixture_relay ++
        \\printf 'Ready\r\n'
        \\printf '{"transcript_path":"%s/none.jsonl"}' "$PWD" | hook SessionStart
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\exit 1
        \\
    ;
    const program = try writeFixture(tmp.dir, "crash-claude", fixture);
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const t0 = std.time.milliTimestamp();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ms = std.time.milliTimestamp() - t0;
    try testing.expectError(RunError.TranscriptUnavailable, err);
    try testing.expect(elapsed_ms < 5_000);
}

test "monotonicNs: never goes backwards and tracks real time" {
    const a = monotonicNs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b - a >= 2 * std.time.ns_per_ms);
    try testing.expect(b - a < 5 * std.time.ns_per_s);
    var prev = b;
    for (0..1000) |_| {
        const now = monotonicNs();
        try testing.expect(now >= prev);
        prev = now;
    }
    _ = @as(i64, @intCast(prev));
}

test "validateCwd: accepts directories, rejects files, missing paths, and NUL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain", .data = "x" });
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "plain");
    defer testing.allocator.free(file_path);

    try validateCwd(null);
    try validateCwd(dir_path);
    try testing.expectError(RunError.InvalidCwd, validateCwd(file_path));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/nonexistent/claude-p/cwd"));
    try testing.expectError(RunError.InvalidCwd, validateCwd(""));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/tmp\x00/x"));

    const before = try leftoverHarnessDirs();
    try testing.expectError(RunError.InvalidCwd, run(testing.allocator, .{
        .prompt = "hi",
        .cwd = "/nonexistent/claude-p/cwd",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "resolveClaudeBinaryIn: PATH search, explicit override, and non-executables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("bin/claude-dir");
    try tmp.dir.makePath("shadow/claude");
    try tmp.dir.writeFile(.{ .sub_path = "bin/not-exec", .data = "x" });
    const exe = try writeFixture(tmp.dir, "bin/claude", "#!/bin/sh\n");
    defer testing.allocator.free(exe);
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const path_env = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/missing:{s}/empty:{s}/shadow:{s}/bin:/usr/bin",
        .{ root, root, root, root },
    );
    defer testing.allocator.free(path_env);

    const found = try resolveClaudeBinaryIn(testing.allocator, null, path_env);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(exe, found);

    const by_path = try resolveClaudeBinaryIn(testing.allocator, exe, "");
    defer testing.allocator.free(by_path);
    try testing.expectEqualStrings(exe, by_path);

    const sh = try resolveClaudeBinaryIn(testing.allocator, "sh", "/nonexistent:/bin");
    defer testing.allocator.free(sh);
    const resolved_sh = try std.fs.cwd().realpathAlloc(testing.allocator, "/bin/sh");
    defer testing.allocator.free(resolved_sh);
    try testing.expectEqualStrings(resolved_sh, sh);

    const empty_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty", .{root});
    defer testing.allocator.free(empty_path);
    const not_exec = try std.fmt.allocPrint(testing.allocator, "{s}/bin/not-exec", .{root});
    defer testing.allocator.free(not_exec);
    const a_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin/claude-dir", .{root});
    defer testing.allocator.free(a_dir);
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, null, empty_path));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, not_exec, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, a_dir, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "/nonexistent/claude", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "not-exec", path_env));

    const Ctx = struct {
        fn resolve(allocator: std.mem.Allocator, p_env: []const u8, want: []const u8) !void {
            const got = try resolveClaudeBinaryIn(allocator, null, p_env);
            defer allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.resolve, .{ path_env, exe });
}

test "run: a missing claude binary fails before spawning and leaves no temp dir" {
    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.SpawnFailed, run(testing.allocator, .{
        .prompt = "hi",
        .claude_path = "/nonexistent/claude",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 2 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "formatHookTrace: prints the event name and payload size, never the payload" {
    const secret = "{\"prompt\":\"my password is hunter2\",\"last_assistant_message\":\"TOP-SECRET-REPLY\"}";
    var buf: [96]u8 = undefined;
    const line = formatHookTrace(&buf, .user_prompt_submit, secret.len);
    try testing.expectEqualStrings("hook: user_prompt_submit payload_bytes=79", line);
    try testing.expect(std.mem.indexOf(u8, line, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, line, "SECRET") == null);
    const params = @typeInfo(@TypeOf(formatHookTrace)).@"fn".params;
    try testing.expectEqual(@as(usize, 3), params.len);
    try testing.expect(params[2].type.? == usize);
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("hook: (trace overflow)", formatHookTrace(&tiny, .stop, 1));
}

test "formatFailureScreen: strips escapes, drops blank lines, keeps the last 15 lines within 1024 bytes" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("", formatFailureScreen(&out, ""));
    try testing.expectEqualStrings("", formatFailureScreen(&out, "\r\n \x1b[2J\r\n"));
    try testing.expectEqualStrings(
        "sh: claude: command not found\nbye",
        formatFailureScreen(&out, "\x1b[31msh: claude:\x07 command not found\x1b[0m\r\r\n\r\n   \r\nbye\r\n"),
    );

    var many: std.ArrayList(u8) = .{};
    defer many.deinit(testing.allocator);
    for (0..40) |i| try many.writer(testing.allocator).print("\x1b[1mline {d}\x1b[0m\r\n\r\n", .{i});
    const tail = formatFailureScreen(&out, many.items);
    try testing.expect(std.mem.startsWith(u8, tail, "line 25\n"));
    try testing.expect(std.mem.endsWith(u8, tail, "\nline 39"));
    try testing.expectEqual(@as(usize, 14), std.mem.count(u8, tail, "\n"));

    const wide = "\xe2\x9d\xaf" ** 2000;
    const cut = formatFailureScreen(&out, wide);
    try testing.expect(cut.len <= failure_screen_max_bytes);
    try testing.expect(cut.len > failure_screen_max_bytes - 4);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "dialogConfirmAllowed: ordinary runs never approve bypass-permissions or dev-channels dialogs" {
    const plain: Options = .{ .prompt = "x" };
    try testing.expect(dialogConfirmAllowed(plain, .trust));
    try testing.expect(dialogConfirmAllowed(plain, .none));
    try testing.expect(!dialogConfirmAllowed(plain, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(plain, .dev_channels));

    const near: Options = .{
        .prompt = "--dangerously-skip-permissions",
        .permission_mode = "acceptEdits",
        .extra_args = &.{
            "--permission-mode",                "plan",
            "--permission-mode=acceptEdits",    "bypassPermissions",
            "--dangerously-skip-permissions-x", "--allow-dangerously-skip-permissions",
        },
    };
    try testing.expect(!dialogConfirmAllowed(near, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(near, .dev_channels));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .permission_mode = "bypassPermissions" }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-skip-permissions"} }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{ "--permission-mode", "bypassPermissions" } }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--permission-mode=bypassPermissions"} }, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .dev_channels));
    const dev: Options = .{ .prompt = "x", .extra_args = &.{ "--dangerously-load-development-channels", "server:x" } };
    try testing.expect(dialogConfirmAllowed(dev, .dev_channels));
    try testing.expect(!dialogConfirmAllowed(dev, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-load-development-channels=server:x"} }, .dev_channels));
}

test "run: refuses an unrequested bypass-permissions dialog without sending a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "bypass-claude",
        \\#!/bin/sh
        \\stty raw -echo
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\dd bs=1 count=1 > keys 2>/dev/null
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.UnexpectedStartupDialog, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
    const keys = tmp.dir.readFileAlloc(testing.allocator, "keys", 16) catch |e| switch (e) {
        error.FileNotFound => try testing.allocator.dupe(u8, ""),
        else => return e,
    };
    defer testing.allocator.free(keys);
    try testing.expectEqualStrings("", keys);
}

test "run: approves a requested bypass dialog, runs with timeout 0 under exec, and prefers Stop text over a stale transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "bypass-ok-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\echo "$PPID" > ppid
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\
    ++ fixture_relay ++
        \\enter=$(printf '\r')
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\[ "$(read_bytes 1)" = "2" ]
        \\printf '\r  1. No, exit\r\n❯ 2. Yes, I accept\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\: > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\read_bytes 18 > /dev/null
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"stale text"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"fresh text"}' "$file" | hook Stop
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .skip_permissions = true,
        .timeout_ms = 0,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("fresh text", result.summary.final_text);
    try testing.expect(!result.summary.is_error);

    const ppid_text = try tmp.dir.readFileAlloc(testing.allocator, "ppid", 32);
    defer testing.allocator.free(ppid_text);
    const ppid = try std.fmt.parseInt(i64, std.mem.trim(u8, ppid_text, " \r\n"), 10);
    try testing.expectEqual(@as(i64, std.c.getpid()), ppid);
}

test "preferStopText: replaces stale text, keeps agreeing text and clears stale error metadata" {
    const a = testing.allocator;
    const make = struct {
        fn summary(text: []const u8, is_error: bool) !transcript_mod.Summary {
            return .{
                .final_text = try testing.allocator.dupe(u8, text),
                .session_id = try testing.allocator.dupe(u8, "s"),
                .is_error = is_error,
                .num_turns = 1,
                .total_cost_usd = 0,
                .duration_api_ms = 0,
                .usage = .{},
                .jsonl_replay = try testing.allocator.dupe(u8, ""),
            };
        }
    }.summary;

    var stale = try make("old answer", false);
    defer stale.deinit(a);
    try preferStopText(a, &stale, "new answer");
    try testing.expectEqualStrings("new answer", stale.final_text);

    var same = try make("answer\n", false);
    defer same.deinit(a);
    try preferStopText(a, &same, " answer");
    try testing.expectEqualStrings("answer\n", same.final_text);

    var no_stop = try make("answer", false);
    defer no_stop.deinit(a);
    try preferStopText(a, &no_stop, null);
    try preferStopText(a, &no_stop, " \n");
    try testing.expectEqualStrings("answer", no_stop.final_text);

    var failed = try make("API Error: 529", true);
    defer failed.deinit(a);
    try preferStopText(a, &failed, "something else");
    try testing.expectEqualStrings("something else", failed.final_text);
    try testing.expect(!failed.is_error);

    var keep = try make("old", false);
    defer keep.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, preferStopText(failing.allocator(), &keep, "new"));
    try testing.expectEqualStrings("old", keep.final_text);
}

test "synthesizeStopFailureSummary: error summary with exit code 1" {
    const Ctx = struct {
        fn check(allocator: std.mem.Allocator, payload: []const u8, want_text: []const u8, want_sid: []const u8) !void {
            var result: Result = .{
                .summary = try synthesizeStopFailureSummary(allocator, payload),
                .duration_ms = 1,
            };
            defer result.deinit(allocator);
            try testing.expect(result.summary.is_error);
            try testing.expectEqual(@as(u8, 1), result.exitCode());
            try testing.expectEqualStrings(want_text, result.summary.final_text);
            try testing.expectEqualStrings(want_sid, result.summary.session_id);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{
        "{\"session_id\":\"abc\",\"last_assistant_message\":\"API Error: overloaded\"}",
        "API Error: overloaded",
        "abc",
    });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{
        "{\"last_assistant_message\":\"  \"}",
        stop_failure_default_text,
        "",
    });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{
        "not json",
        stop_failure_default_text,
        "",
    });
}

test "run: a StopFailure hook ends the run at once with an error result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "failing-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\
    ++ fixture_relay ++
        \\printf 'Ready ? for shortcuts'
        \\printf '{"session_id":"sess-1"}' | hook SessionStart
        \\dd bs=1 count=18 > /dev/null 2>&1
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '{"session_id":"sess-1","error":"API Error: overloaded"}' | hook StopFailure
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);

    const t0 = monotonicNs();
    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = std.fs.path.dirname(program).?,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(monotonicNs() - t0 < 10 * std.time.ns_per_s);
    try testing.expect(result.summary.is_error);
    try testing.expectEqual(@as(u8, 1), result.exitCode());
    try testing.expectEqualStrings("API Error: overloaded", result.summary.final_text);
    try testing.expectEqualStrings("sess-1", result.summary.session_id);
}

test "onZmuxEvent: stops copying into recent after startup and queues complete DEC replies" {
    var shared: SharedState = .{ .session = undefined, .debug = false };
    defer shared.pending_to_pty.deinit(std.heap.page_allocator);
    defer shared.recent.deinit(std.heap.page_allocator);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "hello\x1b[c" } });
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 8), shared.bytes_seen.load(.seq_cst));
    const first_ns = shared.last_output_ns.load(.seq_cst);
    try testing.expect(first_ns != 0);

    shared.startup_done.store(true, .seq_cst);
    std.Thread.sleep(std.time.ns_per_ms);
    shared.recent_mutex.lock();
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "world\x1b[6n" } });
    shared.recent_mutex.unlock();
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 17), shared.bytes_seen.load(.seq_cst));
    try testing.expect(shared.last_output_ns.load(.seq_cst) > first_ns);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "\x1b[c" ** 100 } });
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R" ++ "\x1b[?1;2c" ** 100, shared.pending_to_pty.items);
}

test "run: requestInterrupt returns Interrupted and cleans up the session and temp dir" {
    defer interrupted.store(false, .seq_cst);
    try testing.expect(!isInterrupted());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "slow-claude",
        \\#!/bin/sh
        \\echo $$ > pid
        \\printf 'Booting\r\n'
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;
    const before = try leftoverHarnessDirs();

    const thread = try std.Thread.spawn(.{}, interruptOnceRunning, .{tmp.dir});
    const t0 = monotonicNs();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ns = monotonicNs() - t0;
    thread.join();
    try testing.expectError(RunError.Interrupted, err);
    try testing.expect(elapsed_ns < 15 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());

    const pid_text = try tmp.dir.readFileAlloc(testing.allocator, "pid", 32);
    defer testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n"), 10);
    var gone = false;
    for (0..100) |_| {
        std.posix.kill(pid, 0) catch {
            gone = true;
            break;
        };
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try testing.expect(gone);

    try testing.expect(!isInterrupted());
    requestInterrupt();
    try testing.expectError(RunError.Interrupted, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "run: PermissionRequest fails before Stop timeout and releases the hook harness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"tool_name":"Bash"}' | hook PermissionRequest
        \\sleep 30
    );
    defer testing.allocator.free(exe);
    const before = try leftoverHarnessDirs();
    const started = monotonicNs();
    try testing.expectError(error.PermissionPromptBlocked, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - started < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "run: configured permission and slow Stop hooks can complete the turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{}' | hook PermissionRequest
        \\printf '{"last_assistant_message":"draft"}' | hook Stop
        \\sleep 0.5
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":true}' >> "$file"
        \\sleep 1.65
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}],"usage":{"output_tokens":3}}}' >> "$file"
        \\printf '{"last_assistant_message":"final"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\sleep 0.7
        \\printf '{"error":"late failure"}' | hook StopFailure
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .extra_hooks = &.{
            .{ .event = "PermissionRequest", .command = "true" },
            .{ .event = "Stop", .command = "sleep 0.5" },
        },
        .timeout_ms = 8000,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("final", result.summary.final_text);
    try testing.expectEqual(3, result.summary.usage.output_tokens);
}

test "run: continued assistant output supersedes provisional Stop until the second Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "0.03", "0.2" }) |delay| {
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
            \\printf '{"last_assistant_message":"draft"}' | hook Stop
            \\sleep 0.04
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}' >> "$file"
            \\
        ++ "sleep " ++ delay ++ "\n" ++
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"second answer"}],"usage":{"output_tokens":3}}}' >> "$file"
            \\printf '{"last_assistant_message":"second answer","stop_hook_active":true}' | hook Stop
        );
        defer testing.allocator.free(exe);
        var result = try run(testing.allocator, .{
            .prompt = "hello",
            .claude_path = exe,
            .cwd = std.fs.path.dirname(exe),
            .timeout_ms = 10_000,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("second answer", result.summary.final_text);
        try testing.expectEqual(3, result.summary.usage.output_tokens);
        var replay: std.Io.Writer.Allocating = .init(testing.allocator);
        defer replay.deinit();
        try result.write(testing.allocator, &replay.writer, .stream_json);
        try testing.expect(std.mem.indexOf(u8, replay.written(), "tool_use") != null);
    }
}

test "run: late-flushed current user and final assistant records preserve provisional Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock-late-flush", fixture_shell ++
        \\printf '{"last_assistant_message":"PONG"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"  hello  "}]}}' >> "$file"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"}],"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 10_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("PONG", result.summary.final_text);
    try testing.expectEqual(@as(u64, 5), result.summary.usage.output_tokens);
}

test "run: resumed transcript path change isolates a matched turn or uses Stop alone" {
    const new_path =
        \\file="$PWD/resumed.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"private history"}]}}' > "$file"
        \\
    ;
    const matched =
        \\printf '%s\n' '{"type":"user","message":{"content":"hello"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}],"usage":{"input_tokens":9}}}' >> "$file"
        \\
    ;
    const stop =
        \\printf '{"transcript_path":"%s","last_assistant_message":"answer"}' "$file" | hook Stop
    ;
    inline for (.{ true, false }) |has_match| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++ new_path ++ (if (has_match) matched else "") ++ stop);
        defer testing.allocator.free(exe);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var result = try run(testing.allocator, .{
            .prompt = "hello",
            .cont = true,
            .cwd = std.fs.path.dirname(exe),
            .claude_path = exe,
            .output_format = .stream_json,
            .stream_writer = &output.writer,
            .timeout_ms = 5000,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("answer", result.summary.final_text);
        try testing.expectEqual(@as(u64, if (has_match) 9 else 0), result.summary.usage.input_tokens);
        try testing.expect(std.mem.indexOf(u8, output.written(), "private history") == null);
    }
}

test "findPromptTurnOffset returns the last matching user entry and rejects unsafe paths" {
    const first = "{\"type\":\"user\",\"message\":{\"content\":\"some text\"}}\r\n{torn\n";
    const last =
        \\{"type":"user","message":{"content":[{"type":"text","text":"  some\r\ntext "}]}}
        \\{"type":"assistant","message":{"content":"some text"}}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.dir, "transcript", first ++ last);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, first.len), findPromptTurnOffset(testing.allocator, path, "some text"));
    try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, path, "different"));
    for ([_][]const u8{ "", "relative", "/a/../b", "/..", "/a\x00b" }) |invalid| {
        try testing.expect(!validateTranscriptPath(invalid));
        try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, invalid, "some text"));
        try testing.expectError(error.InvalidTranscriptPath, transcript_mod.openTranscriptRegularFile(invalid));
    }
}

test "reportFailure includes screen content only with debug screen consent" {
    var shared: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer shared.recent.deinit(std.heap.page_allocator);
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "SENTINEL-startup-secret" } });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture = try tmp.dir.createFile("stderr", .{ .read = true });
    defer capture.close();
    {
        const previous = try std.posix.dup(std.posix.STDERR_FILENO);
        defer std.posix.close(previous);
        try std.posix.dup2(capture.handle, std.posix.STDERR_FILENO);
        defer std.posix.dup2(previous, std.posix.STDERR_FILENO) catch unreachable;
        reportFailure(&shared, false, "startup timeout", .{});
        shared.startup_done.store(true, .seq_cst);
        onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "x" ** 2200 ++ "recent-output" } });
        reportFailure(&shared, true, "stop timeout", .{});
    }
    try capture.seekTo(0);
    const logged = try capture.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "startup timeout") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "SENTINEL") == null);
    try testing.expect(std.mem.indexOf(u8, logged, "recent-output") != null);
}

test "chunked paste observes interrupts and deadlines before the second chunk or Enter" {
    const Sink = struct {
        writes: usize = 0,
        interrupt: bool,
        pub fn writeInput(self: *@This(), _: []const u8) !void {
            self.writes += 1;
            if (self.interrupt and self.writes == 2) requestInterrupt();
        }
    };
    defer clearInterrupt();
    for ([_]bool{ false, true }) |cancel| {
        var sink: Sink = .{ .interrupt = cancel };
        const start = monotonicNs();
        const deadline = start + (if (cancel) @as(i128, 60 * std.time.ns_per_s) else 20 * std.time.ns_per_ms);
        try testing.expectError(
            if (cancel) error.Interrupted else error.StopTimeout,
            typePromptUntil(&sink, "x" ** (64 * 1024), std.time.ns_per_s, std.time.ns_per_s, deadline),
        );
        try testing.expect(sink.writes <= 2);
        try testing.expect(monotonicNs() - start < std.time.ns_per_s);
    }
}

test "run validates unsupported library options before spawning" {
    const blocked = [_][]const u8{
        "--bare",                 "--safe-mode",    "--no-session-persistence", "--max-turns",                "--max-budget-usd",
        "--fallback-model",       "--input-format", "--json-schema",            "--include-partial-messages", "--forward-subagent-text",
        "--replay-user-messages", "-p",             "--print",                  "--settings",
    };
    inline for (blocked) |flag| {
        try testing.expectError(error.InvalidOptions, run(testing.allocator, .{ .prompt = "x", .extra_args = &.{flag} }));
        try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .extra_args = &.{flag ++ "=value"} }));
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--system-prompt", flag } });
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--", flag } });
    }
    try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--from-pr", "--print" } });
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .max_turns = 1 }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .fallback_model = "other" }));
}

test "run: blank Stop text without an assistant transcript is unavailable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"last_assistant_message":"  "}' | hook Stop
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptUnavailable, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
    }));
}

test "run: oversized transcript falls back to authoritative Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\dd if=/dev/zero of="$file" bs=1 count=1 seek=67108864 2>/dev/null
        \\printf '{"session_id":"s","last_assistant_message":"done"}' | hook Stop
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 10_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("done", result.summary.final_text);
    try testing.expectEqualStrings("s", result.summary.session_id);
    try testing.expectEqualStrings("", result.summary.jsonl_replay);
}

test "run: StopFailure preserves transcript usage and turns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":9}}}' '{"type":"assistant","message":{"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '{"last_assistant_message":"quota reached","error":"generic"}' | hook StopFailure
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 10_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.summary.is_error);
    try testing.expectEqualStrings("quota reached", result.summary.final_text);
    try testing.expectEqual(2, result.summary.num_turns);
    try testing.expectEqual(9, result.summary.usage.input_tokens);
    try testing.expectEqual(5, result.summary.usage.output_tokens);
}

test "shell refuses to exec after a previously validated cwd disappears" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("it's here");
    const cwd = try tmp.dir.realpathAlloc(testing.allocator, "it's here");
    defer testing.allocator.free(cwd);
    const command = try buildShellCommandInDir(testing.allocator, &.{ "/bin/echo", "unexpected" }, cwd);
    defer testing.allocator.free(command);
    try tmp.dir.deleteDir("it's here");
    const res = try std.process.Child.run(.{ .allocator = testing.allocator, .argv = &.{ "/bin/sh", "-c", command } });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(126, res.term.Exited);
    try testing.expectEqualStrings("", res.stdout);
}

test "run: transcript idle timeout waits for PTY progress and ends a silent turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\for i in 1 2 3 4 5 6; do printf .; sleep 0.05; done
        \\touch still-running
        \\sleep 5
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptStalled, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
        .transcript_idle_timeout_ms = 250,
    }));
    try tmp.dir.access("still-running", .{});
}
