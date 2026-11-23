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

/// True only for `CLAUDE_P_E2E=1`; `0`, empty, or any other value skips.
fn e2eEnabled() bool {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, "CLAUDE_P_E2E") catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1");
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

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var result = try claude_p.run(std.testing.allocator, .{
        .prompt = "Reply with the single word OK.",
        .output_format = .stream_json,
        .timeout_ms = 90_000,
        .skip_permissions = true,
        .verbose = true,
        .stream_writer = &aw.writer,
    });
    defer result.deinit(std.testing.allocator);

    const streamed = aw.written();

    // We expect at least one line emitted live (the streaming property).
    try std.testing.expect(result.streamed);
    try std.testing.expect(streamed.len > 0);

    // Validate every non-empty line is a parseable JSON object and the LAST
    // non-empty line is the `result` envelope.
    var line_iter = std.mem.splitScalar(u8, streamed, '\n');
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

// ----------------------------------------------------------------------
// Helpers for tests that spawn the built `claude-p` CLI.
// ----------------------------------------------------------------------

const e2e_timeout_ms: u64 = 120_000;

/// Path to the installed CLI. `zig build test-integration` sets
/// `CLAUDE_P_BIN` to the install path and depends on the install step.
fn claudePBinary(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "CLAUDE_P_BIN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "zig-out/bin/claude-p"),
        else => err,
    };
}

/// Newline-delimited reader over a child pipe with a wall-clock deadline.
const LineReader = struct {
    file: std.fs.File,
    buf: std.ArrayList(u8) = .{},
    eof: bool = false,

    fn deinit(self: *LineReader, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Returns the next line (without '\n', caller owns it), or null at EOF.
    /// Fails with `error.Timeout` once `deadline_ms` passes.
    fn next(self: *LineReader, allocator: std.mem.Allocator, deadline_ms: i64) !?[]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
                const line = try allocator.dupe(u8, self.buf.items[0..nl]);
                self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                return line;
            }
            if (self.eof) {
                if (self.buf.items.len == 0) return null;
                const rest = try self.buf.toOwnedSlice(allocator);
                return rest;
            }
            const remaining = deadline_ms - std.time.milliTimestamp();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = self.file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = try std.posix.poll(&fds, @intCast(@min(remaining, 1000)));
            if (ready == 0) continue;
            var tmp: [4096]u8 = undefined;
            const n = try self.file.read(&tmp);
            if (n == 0) {
                self.eof = true;
            } else {
                try self.buf.appendSlice(allocator, tmp[0..n]);
            }
        }
    }
};

fn deadlineFromNow(timeout_ms: u64) i64 {
    return std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
}

/// Returns the string value of `field` in a JSON object line, or null.
fn jsonStringField(parsed: *const std.json.Parsed(std.json.Value), field: []const u8) ?[]const u8 {
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.ChildDidNotExitCleanly,
    }
}

// ----------------------------------------------------------------------
// Large prompt, resume, nested env, daemon.
// ----------------------------------------------------------------------

test "real claude: large prompt over 4 KB arrives without truncation" {
    if (!e2eEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var prompt: std.ArrayList(u8) = .{};
    defer prompt.deinit(allocator);
    try prompt.appendSlice(allocator, "START_TOKEN_42\n" ++
        "The lines below are filler. Ignore their content.\n");
    var i: u32 = 0;
    while (prompt.items.len < 5 * 1024) : (i += 1) {
        try prompt.print(allocator, "Filler line {d:0>3}: the quick brown fox jumps over the lazy dog.\n", .{i});
    }
    try prompt.appendSlice(allocator, "This prompt began with a token on its first line and ends with a token on " ++
        "its last line. Reply with only those two tokens, separated by one space.\n" ++
        "END_TOKEN_99");
    try std.testing.expect(prompt.items.len > 4096);

    var result = try claude_p.run(allocator, .{
        .prompt = prompt.items,
        .output_format = .text,
        .timeout_ms = e2e_timeout_ms,
        .skip_permissions = true,
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.summary.is_error);
    const text = result.summary.final_text;
    try std.testing.expect(std.mem.indexOf(u8, text, "START_TOKEN_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "END_TOKEN_99") != null);
}

test "real claude: --resume continues the session and returns the new turn" {
    if (!e2eEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var result1 = try claude_p.run(allocator, .{
        .prompt = "Remember this secret token: ORCHID_7391. Reply with the single word STORED and nothing else.",
        .output_format = .text,
        .timeout_ms = e2e_timeout_ms,
        .skip_permissions = true,
    });
    defer result1.deinit(allocator);
    try std.testing.expect(!result1.summary.is_error);
    try std.testing.expect(result1.summary.session_id.len > 0);

    var result2 = try claude_p.run(allocator, .{
        .prompt = "What was the secret token I asked you to remember? Reply with the token, then a space, then TURN2_OK.",
        .output_format = .text,
        .timeout_ms = e2e_timeout_ms,
        .skip_permissions = true,
        .resume_session = result1.summary.session_id,
    });
    defer result2.deinit(allocator);

    try std.testing.expect(!result2.summary.is_error);
    const text2 = std.mem.trim(u8, result2.summary.final_text, " \t\r\n");
    try std.testing.expect(std.mem.indexOf(u8, text2, "ORCHID_7391") != null);
    try std.testing.expect(!std.mem.eql(u8, text2, "STORED"));
}

test "real claude: CLI survives a nested Claude Code environment" {
    if (!e2eEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const bin = try claudePBinary(allocator);
    defer allocator.free(bin);

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("CLAUDECODE", "1");
    try env.put("CLAUDE_CODE_ENTRYPOINT", "cli");
    try env.put("CLAUDE_CODE_CHILD_SESSION", "1");

    const argv = [_][]const u8{
        bin,
        "--output-format",
        "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        "Reply with the single word NESTED_OK and nothing else.",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    var waited = false;
    errdefer if (!waited) {
        _ = child.kill() catch {};
    };

    var reader: LineReader = .{ .file = child.stdout.? };
    defer reader.deinit(allocator);
    const deadline = deadlineFromNow(e2e_timeout_ms);

    var last_line: ?[]u8 = null;
    defer if (last_line) |l| allocator.free(l);
    var line_count: u32 = 0;
    while (try reader.next(allocator, deadline)) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            allocator.free(line);
            continue;
        }
        line_count += 1;
        // Every line must be a JSON object.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            allocator.free(line);
            return err;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            allocator.free(line);
            return error.NonObjectJsonLine;
        }
        if (last_line) |l| allocator.free(l);
        last_line = line;
    }

    waited = true;
    try expectExitedZero(try child.wait());

    try std.testing.expect(line_count >= 2);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last_line orelse return error.NoOutput, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("result", jsonStringField(&parsed, "type") orelse "");
    const text = jsonStringField(&parsed, "result") orelse return error.MissingResultField;
    try std.testing.expect(std.mem.indexOf(u8, text, "NESTED_OK") != null);
}

test "real claude: daemon answers ping and runs a user turn" {
    if (!e2eEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const bin = try claudePBinary(allocator);
    defer allocator.free(bin);

    const argv = [_][]const u8{ bin, "daemon", "--dangerously-skip-permissions" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    var waited = false;
    errdefer if (!waited) {
        _ = child.kill() catch {};
    };

    var reader: LineReader = .{ .file = child.stdout.? };
    defer reader.deinit(allocator);
    const deadline = deadlineFromNow(e2e_timeout_ms);

    // ----- ping -> pong -----
    try child.stdin.?.writeAll("{\"type\":\"ping\"}\n");
    var got_pong = false;
    while (!got_pong) {
        const line = (try reader.next(allocator, deadline)) orelse return error.DaemonExitedBeforePong;
        defer allocator.free(line);
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, jsonStringField(&parsed, "type") orelse "", "pong")) got_pong = true;
    }

    // ----- user turn -> result -----
    try child.stdin.?.writeAll(
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Reply with the single word DAEMON_OK and nothing else.\"}}\n",
    );
    var got_result = false;
    while (!got_result) {
        const line = (try reader.next(allocator, deadline)) orelse return error.DaemonExitedBeforeResult;
        defer allocator.free(line);
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, jsonStringField(&parsed, "type") orelse "", "result")) continue;
        const text = jsonStringField(&parsed, "result") orelse return error.MissingResultField;
        try std.testing.expect(std.mem.indexOf(u8, text, "DAEMON_OK") != null);
        got_result = true;
    }

    // ----- stdin EOF -> clean shutdown -----
    child.stdin.?.close();
    child.stdin = null;
    while (try reader.next(allocator, deadline)) |line| allocator.free(line);

    waited = true;
    try expectExitedZero(try child.wait());
}
