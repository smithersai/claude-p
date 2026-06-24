//! Integration tests against the real `claude` binary.
//!
//! These tests are skipped by default. Enable with `CLAUDE_P_E2E=1`:
//!
//!     CLAUDE_P_E2E=1 zig build test-integration
//!
//! No mocks. We invoke the actual `claude` on $PATH and assert the wrapper's
//! output looks like what `claude -p` would emit for the same prompt.
const std = @import("std");
const claude_p = @import("claude_p");

fn e2eEnabled() bool {
    return std.process.hasEnvVar(std.heap.page_allocator, "CLAUDE_P_E2E") catch false;
}

/// Path to the built `claude-p` binary. build.zig sets CLAUDE_P_BIN on the
/// integration run; fall back to the conventional install path otherwise.
fn claudePBin() []const u8 {
    return std.posix.getenv("CLAUDE_P_BIN") orelse "zig-out/bin/claude-p";
}

/// Make a unique temp dir under $TMPDIR for a daemon subprocess test. Caller
/// owns the returned path and should delete the tree.
fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    const root = std.posix.getenv("TMPDIR") orelse "/tmp";
    const pid: i32 = @intCast(std.posix.system.getpid());
    const stamp: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const dir = try std.fmt.allocPrint(allocator, "{s}/claude-p-itest-{d}-{x}", .{ root, pid, stamp });
    try std.fs.cwd().makePath(dir);
    return dir;
}

fn writeExecScript(dir: []const u8, name: []const u8, body: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    var f = try std.fs.cwd().createFile(path, .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll(body);
    return path;
}

// P0-2: a watchdog trip must emit a terminal error-result frame on stdout
// *before* the daemon exits — never a silent dead pipe (SPEC §2.7). This is
// deterministic and needs no real `claude`: a fake child that stays alive but
// never fires the SessionStart hook forces the session-start-timeout path.
test "daemon: session-start timeout emits error frame + exit 2" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }
    // Fake claude: ignore all args, stay alive, emit nothing.
    const fake = try writeExecScript(tmp, "fake-claude.sh", "#!/bin/sh\nexec sleep 30\n", allocator);
    defer allocator.free(fake);

    var child = std.process.Child.init(&.{
        claudePBin(), "daemon",
        "--claude-path", fake,
        "--timeout",    "2", // session-start deadline (seconds)
        "--idle-timeout", "0",
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    // EOF stdin immediately; in waiting_for_ready this does not short-circuit
    // shutdown, so the session-start deadline (2s) fires first.
    child.stdin.?.close();
    child.stdin = null;

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(out);
    const term = try child.wait();

    // Exactly the session-start-timeout error frame, then exit 2.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"session_start_timeout\"") != null);
    try assertErrorFrame(allocator, out, "session_start_timeout");
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 2 }, term);
}

/// Assert `out` contains a JSONL line that is a well-formed terminal error
/// result with the given reason.
fn assertErrorFrame(allocator: std.mem.Allocator, out: []const u8, reason: []const u8) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const ty = obj.get("type") orelse continue;
        if (ty != .string or !std.mem.eql(u8, ty.string, "result")) continue;
        const err = obj.get("error") orelse continue;
        if (err == .string and std.mem.eql(u8, err.string, reason)) {
            try std.testing.expectEqualStrings("error", obj.get("subtype").?.string);
            try std.testing.expect(obj.get("is_error").?.bool);
            return; // found it
        }
    }
    return error.ErrorFrameNotFound;
}

// P0-1: an `--extra-hook PostToolUse=<cmd>` must actually fire against the real
// `claude` — this is the validation boundary we flagged (does matcher "*" fire
// for PostToolUse?). The hook touches a sentinel; a tool-using prompt should
// trigger it.
test "real claude: --extra-hook PostToolUse fires on tool use" {
    if (!e2eEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }
    const sentinel = try std.fmt.allocPrint(allocator, "{s}/fired", .{tmp});
    defer allocator.free(sentinel);
    // Drain stdin (the hook payload) to avoid SIGPIPE, then record the hit.
    const hook_body = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ncat >/dev/null\necho fired >> \"{s}\"\n",
        .{sentinel},
    );
    defer allocator.free(hook_body);
    const hook = try writeExecScript(tmp, "ptu.sh", hook_body, allocator);
    defer allocator.free(hook);

    const extra = try std.fmt.allocPrint(allocator, "PostToolUse={s}", .{hook});
    defer allocator.free(extra);

    var child = std.process.Child.init(&.{
        claudePBin(),                     "daemon",
        "--dangerously-skip-permissions", "--extra-hook",
        extra,                            "--timeout",
        "120",
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    // One tool-forcing turn, then EOF → daemon finishes the turn and shuts down.
    try child.stdin.?.writeAll(
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":" ++
            "\"Use the Bash tool to run exactly: echo hello. Then reply DONE.\"}}\n",
    );
    child.stdin.?.close();
    child.stdin = null;

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 22);
    defer allocator.free(out);
    _ = try child.wait();

    // A result frame for the turn must have been emitted...
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"result\"") != null);
    // ...and the PostToolUse hook must have fired (sentinel exists).
    std.fs.cwd().access(sentinel, .{}) catch {
        return error.PostToolUseHookDidNotFire;
    };
}

test "real claude: text output for trivial prompt" {
    if (!e2eEnabled()) return error.SkipZigTest;

    var result = try claude_p.run(std.testing.allocator, .{
        .prompt = "Reply with the single word OK and nothing else.",
        .output_format = .text,
        .timeout_ms = 90_000,
        .skip_permissions = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.summary.final_text.len > 0);
    try std.testing.expect(!result.summary.is_error);
}

test "real claude: json output round-trips through std.json" {
    if (!e2eEnabled()) return error.SkipZigTest;

    var result = try claude_p.run(std.testing.allocator, .{
        .prompt = "Reply with the single word OK and nothing else.",
        .output_format = .json,
        .timeout_ms = 90_000,
        .skip_permissions = true,
    });
    defer result.deinit(std.testing.allocator);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    try result.write(std.testing.allocator, &aw.writer, .json);
    buf = aw.toArrayList();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("result", parsed.value.object.get("type").?.string);
    try std.testing.expect(parsed.value.object.get("session_id").?.string.len > 0);
}

test "real claude: exit code 0 on success" {
    if (!e2eEnabled()) return error.SkipZigTest;
    var result = try claude_p.run(std.testing.allocator, .{
        .prompt = "Reply with OK.",
        .timeout_ms = 90_000,
        .skip_permissions = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exitCode());
}

test "real claude: stream-json arrives as JSONL ending in a result line" {
    if (!e2eEnabled()) return error.SkipZigTest;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);

    var result = try claude_p.run(std.testing.allocator, .{
        .prompt = "Reply with the single word OK.",
        .output_format = .stream_json,
        .timeout_ms = 90_000,
        .skip_permissions = true,
        .verbose = true,
        .stream_writer = &aw.writer,
    });
    defer result.deinit(std.testing.allocator);

    buf = aw.toArrayList();

    // We expect at least one line emitted live (the streaming property).
    try std.testing.expect(result.streamed);
    try std.testing.expect(buf.items.len > 0);

    // Validate every non-empty line is a parseable JSON object and the LAST
    // non-empty line is the `result` envelope.
    var line_iter = std.mem.splitScalar(u8, buf.items, '\n');
    var last_object_type: std.ArrayList(u8) = .{};
    defer last_object_type.deinit(std.testing.allocator);
    var line_count: u32 = 0;
    while (line_iter.next()) |raw| {
        if (raw.len == 0) continue;
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        if (parsed.value.object.get("type")) |t| {
            if (t == .string) {
                last_object_type.clearRetainingCapacity();
                try last_object_type.appendSlice(std.testing.allocator, t.string);
            }
        }
    }
    try std.testing.expect(line_count >= 2);
    try std.testing.expectEqualStrings("result", last_object_type.items);

    // Re-emitting via Result.write should be a no-op in stream-json mode.
    var dup: std.ArrayList(u8) = .{};
    defer dup.deinit(std.testing.allocator);
    var dup_aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &dup);
    try result.write(std.testing.allocator, &dup_aw.writer, .stream_json);
    dup = dup_aw.toArrayList();
    try std.testing.expectEqual(@as(usize, 0), dup.items.len);
}
