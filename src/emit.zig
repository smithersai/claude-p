//! Output formatters that mirror `claude -p`'s wire format on stdout.
//!
//!   --output-format text         → final assistant text + "\n"
//!   --output-format json         → one result object
//!   --output-format stream-json  → JSONL replay of the transcript
const std = @import("std");
const transcript_mod = @import("transcript.zig");
const stream = @import("stream.zig");
const Summary = transcript_mod.Summary;
const args_mod = @import("args.zig");
/// Re-export of the CLI output format enum (`text`, `json`, `stream_json`).
pub const OutputFormat = args_mod.OutputFormat;

/// Summary payload and timing metadata rendered by `emit`.
pub const ResultEnvelope = struct {
    summary: *const Summary,
    duration_ms: u64,
    error_reason: ?[]const u8 = null,
};

/// Render `env` to `writer` according to `fmt`.
pub fn emit(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    fmt: OutputFormat,
    env: ResultEnvelope,
) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    switch (fmt) {
        .text => try emitText(writer, env),
        .json => try emitJson(allocator, writer, env),
        .stream_json => try emitStreamJson(allocator, writer, env),
    }
}

/// Write final assistant text followed by a single trailing newline.
pub fn emitText(writer: *std.Io.Writer, env: ResultEnvelope) !void {
    const needs_nl = !std.mem.endsWith(u8, env.summary.final_text, "\n");
    std.debug.assert(needs_nl or env.summary.final_text.len > 0);
    try writer.writeAll(env.summary.final_text);
    if (needs_nl) try writer.writeByte('\n');
}

/// Serialize a single `type: "result"` JSON envelope terminated by `\n`.
pub fn emitJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    env: ResultEnvelope,
) !void {
    _ = allocator;
    const s = env.summary;
    const safe_cost = if (std.math.isFinite(s.total_cost_usd)) s.total_cost_usd else @as(f64, 0.0);
    std.debug.assert(std.math.isFinite(safe_cost));
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("result");
    try jw.objectField("subtype");
    try jw.write(s.subtype orelse if (s.is_error) "error_during_execution" else "success");
    if (env.error_reason) |reason| {
        try jw.objectField("error");
        try jw.write(reason);
    }
    try jw.objectField("session_id");
    try jw.write(s.session_id);
    try jw.objectField("result");
    try jw.write(s.final_text);
    try jw.objectField("is_error");
    try jw.write(s.is_error);
    try jw.objectField("duration_ms");
    try jw.write(env.duration_ms);
    try jw.objectField("duration_api_ms");
    try jw.write(s.duration_api_ms);
    try jw.objectField("num_turns");
    try jw.write(s.num_turns);
    try jw.objectField("total_cost_usd");
    try jw.write(safe_cost);
    try jw.objectField("usage");
    try jw.beginObject();
    try jw.objectField("input_tokens");
    try jw.write(s.usage.input_tokens);
    try jw.objectField("output_tokens");
    try jw.write(s.usage.output_tokens);
    try jw.objectField("cache_read_input_tokens");
    try jw.write(s.usage.cache_read_input_tokens);
    try jw.objectField("cache_creation_input_tokens");
    try jw.write(s.usage.cache_creation_input_tokens);
    try jw.endObject();
    try jw.objectField("permission_denials");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(s.permission_denials orelse "[]");
    jw.endWriteRaw();
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Replay forwardable transcript JSONL lines and append the final result JSON object.
pub fn emitStreamJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    env: ResultEnvelope,
) !void {
    std.debug.assert(@intFromPtr(env.summary) != 0);
    var lines = std.mem.tokenizeScalar(u8, env.summary.jsonl_replay, '\n');
    while (lines.next()) |line| {
        if (try stream.isForwardable(allocator, line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }
    try emitJson(allocator, writer, env);
}

/// Reject an input frame without completing the caller's active turn.
pub fn writeProtocolError(writer: *std.Io.Writer, reason: []const u8) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    try std.json.Stringify.value(.{ .type = "error", .@"error" = reason }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Emit one structured daemon result line for a turn that did not finish
/// normally: an interrupted turn or a terminal watchdog timeout. Same field
/// set as `emitJson` plus `error`, so a hub parses both with one schema.
/// `is_error` is false only for the `"interrupted"` subtype.
pub fn emitErrorResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    subtype: []const u8,
    error_reason: []const u8,
    session_id: []const u8,
    duration_ms: u64,
) !void {
    _ = allocator;
    return emitErrorResultDetail(writer, subtype, error_reason, session_id, duration_ms, .{});
}

/// Emit a structured error result line with optional `stage` and `message` diagnostic fields.
pub fn emitErrorResultDetail(
    writer: *std.Io.Writer,
    subtype: []const u8,
    error_reason: []const u8,
    session_id: []const u8,
    duration_ms: u64,
    detail: struct { stage: ?[]const u8 = null, message: ?[]const u8 = null },
) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    var jw = std.json.Stringify{ .writer = writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("result");
    try jw.objectField("subtype");
    try jw.write(subtype);
    try jw.objectField("error");
    try jw.write(error_reason);
    if (detail.stage) |stage| {
        try jw.objectField("stage");
        try jw.write(stage);
    }
    if (detail.message) |message| {
        try jw.objectField("message");
        try jw.write(message);
    }
    try jw.objectField("session_id");
    try jw.write(session_id);
    try jw.objectField("result");
    try jw.write("");
    try jw.objectField("is_error");
    try jw.write(!std.mem.eql(u8, subtype, "interrupted"));
    try jw.objectField("duration_ms");
    try jw.write(duration_ms);
    try jw.objectField("duration_api_ms");
    try jw.write(@as(u64, 0));
    try jw.objectField("num_turns");
    try jw.write(@as(u64, 0));
    try jw.objectField("total_cost_usd");
    try jw.write(@as(u64, 0));
    try jw.objectField("usage");
    try jw.beginObject();
    try jw.objectField("input_tokens");
    try jw.write(@as(u64, 0));
    try jw.objectField("output_tokens");
    try jw.write(@as(u64, 0));
    try jw.objectField("cache_read_input_tokens");
    try jw.write(@as(u64, 0));
    try jw.objectField("cache_creation_input_tokens");
    try jw.write(@as(u64, 0));
    try jw.endObject();
    try jw.objectField("permission_denials");
    try jw.beginArray();
    try jw.endArray();
    try jw.endObject();
    try writer.writeAll("\n");
}

/// Human-readable message for known CLI argument parse errors, or null for fallback.
pub fn parseErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.StreamJsonRequiresVerbose => "Error: --output-format=stream-json requires --verbose",
        error.UnsupportedFlag => "Error: unsupported flag. claude-p rejects -p/--print (it emulates print mode), " ++
            "--settings (it injects its own; use --extra-hook or --setting-json), " ++
            "--bare/--safe-mode (Claude Code skips --settings hooks under them), " ++
            "--no-session-persistence (claude-p reads the transcript), the " ++
            "print-only --input-format, --json-schema, --max-budget-usd, --max-turns, and " ++
            "--fallback-model, the print-only stream flags --include-partial-messages, " ++
            "--forward-subagent-text, --replay-user-messages, and --verbose-thinking, " ++
            "and --output-format text/json in daemon mode (its output is always stream-json)",
        error.MissingValue => "Error: a flag is missing its value (--add-dir, --mcp-config, --allowedTools, " ++
            "and --disallowedTools need a value not starting with `-`; use the " ++
            "--flag=<value> form for one that does)",
        error.UnknownFlag => "Error: unexpected argument. claude-p takes one PROMPT; daemon mode takes " ++
            "no PROMPT or --input-file (prompts arrive as stdin frames)",
        error.BadExtraHook => "Error: --extra-hook expects <Event>=<cmd> with a non-empty event and command, " ++
            "e.g. --extra-hook 'PreToolUse=echo hi'",
        else => null,
    };
}

/// Exit code for a driver or daemon run error: 124 for timeouts, 2 for all others.
pub fn exitCodeForRunError(err: anyerror) u8 {
    return switch (err) {
        error.SessionStartTimeout,
        error.StopTimeout,
        error.IdleTimeout,
        error.TranscriptStalled,
        => 124,
        else => 2,
    };
}

/// Actionable stderr text for known run errors, or null to print only the error name.
pub fn runErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SessionStartTimeout => "timed out waiting for claude to start (SessionStart hook never fired); " ++
            "raise --timeout or run with --debug",
        error.StopTimeout => "timed out waiting for claude to finish the turn (Stop hook never fired); " ++
            "raise --timeout",
        error.IdleTimeout => "no PTY output while busy for --idle-timeout; claude appears hung",
        error.TranscriptStalled => "transcript stopped growing while busy for --transcript-idle-timeout",
        error.PromptNotAccepted => "claude never accepted the typed prompt; check for a blocking dialog with --debug",
        error.PromptTruncated => "claude received a truncated prompt; " ++
            "pass long prompts via --input-file or stdin and retry",
        error.Interrupted => "interrupted by a signal",
        error.PermissionPromptBlocked => "claude needs a permission decision; " ++
            "configure an allowed tool or a PermissionRequest hook and retry",
        error.InvalidOptions => "check the supplied options against claude-p --help " ++
            "and remove unsupported print-mode flags",
        error.InvalidCwd => "--cwd is not an accessible directory",
        error.UnexpectedStartupDialog => "claude displayed a security warning dialog that was not authorized " ++
            "by your flags; pass --dangerously-skip-permissions or " ++
            "--dangerously-load-development-channels if intended",
        error.InvalidExtraSettings => "--setting-json must be a JSON object nested at most 128 levels " ++
            "and each --extra-hook needs a non-empty UTF-8 event and command",
        else => null,
    };
}

// -------- tests --------

const testing = std.testing;

fn parseAndEmit(allocator: std.mem.Allocator, fmt: OutputFormat, jsonl: []const u8) ![]u8 {
    var s = try transcript_mod.parse(allocator, jsonl);
    defer s.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try emit(allocator, &aw.writer, fmt, .{ .summary = &s, .duration_ms = 100 });
    return allocator.dupe(u8, aw.written());
}

test "emit text: final message + newline" {
    const out = try parseAndEmit(testing.allocator, .text, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi\n", out);
}

test "emit text: preserves an existing final newline" {
    const out = try parseAndEmit(testing.allocator, .text, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\\n\"}]}}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi\n", out);
}

test "emit json: result object shape" {
    const out = try parseAndEmit(testing.allocator, .json, "{\"type\":\"assistant\",\"session_id\":\"sid\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n");
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("success", obj.get("subtype").?.string);
    try testing.expectEqualStrings("sid", obj.get("session_id").?.string);
    try testing.expectEqualStrings("ok", obj.get("result").?.string);
    try testing.expect(!obj.get("is_error").?.bool);
    try testing.expectEqual(@as(i64, 100), obj.get("duration_ms").?.integer);
}

test "emit json preserves permission denials as an array" {
    const out = try parseAndEmit(testing.allocator, .json, "{\"type\":\"result\",\"result\":\"ok\",\"permission_denials\":[{\"tool_name\":\"Bash\"}]}");
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Bash", parsed.value.object.get("permission_denials").?.array.items[0].object.get("tool_name").?.string);
}

test "emit json: error result" {
    const out = try parseAndEmit(testing.allocator, .json, "{\"type\":\"result\",\"subtype\":\"error\",\"session_id\":\"e\",\"result\":\"boom\",\"is_error\":true}\n");
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("error", parsed.value.object.get("subtype").?.string);
    try testing.expect(parsed.value.object.get("is_error").?.bool);
}

test "emit stream-json: replay + trailing result" {
    const out = try parseAndEmit(testing.allocator, .stream_json, "{\"type\":\"system\",\"subtype\":\"init\"}\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}\n");
    defer testing.allocator.free(out);
    var iter = std.mem.splitScalar(u8, out, '\n');
    try testing.expect(std.mem.indexOf(u8, iter.next().?, "\"subtype\":\"init\"") != null);
    try testing.expect(std.mem.indexOf(u8, iter.next().?, "\"type\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, iter.next().?, "\"type\":\"result\"") != null);
}

test "emitErrorResult: exact wire line for a timeout" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitErrorResult(testing.allocator, &aw.writer, "error", "transcript_stalled", "sid-1", 4200);
    try testing.expectEqualStrings(
        "{\"type\":\"result\",\"subtype\":\"error\",\"error\":\"transcript_stalled\"," ++
            "\"session_id\":\"sid-1\",\"result\":\"\",\"is_error\":true,\"duration_ms\":4200," ++
            "\"duration_api_ms\":0,\"num_turns\":0,\"total_cost_usd\":0," ++
            "\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0," ++
            "\"cache_creation_input_tokens\":0},\"permission_denials\":[]}\n",
        aw.written(),
    );
}

test "emitErrorResult: interrupted round-trips with is_error false" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitErrorResult(testing.allocator, &aw.writer, "interrupted", "interrupted", "sid-2", 1500);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("interrupted", obj.get("subtype").?.string);
    try testing.expect(!obj.get("is_error").?.bool);
    try testing.expectEqual(@as(i64, 1500), obj.get("duration_ms").?.integer);
}

test "emitErrorResult: other subtypes are errors" {
    for ([_][]const u8{ "error", "error_during_execution", "" }) |subtype| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try emitErrorResult(testing.allocator, &aw.writer, subtype, "idle_timeout", "", 0);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("is_error").?.bool);
    }
}

test "emitErrorResult: strings are JSON-escaped and stay on one line" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const reason = "bad \"quote\" \\ back\nnew\tline \x01";
    const sid = "s\"id\n";
    try emitErrorResult(testing.allocator, &aw.writer, "err\"or", reason, sid, 7);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw.written(), "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(reason, parsed.value.object.get("error").?.string);
    try testing.expectEqualStrings(sid, parsed.value.object.get("session_id").?.string);
}

test "emit text: empty final_text emits single newline" {
    const s: Summary = .{ .final_text = &.{}, .session_id = &.{}, .is_error = false, .total_cost_usd = 0, .jsonl_replay = &.{} };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitText(&aw.writer, .{ .summary = &s, .duration_ms = 0 });
    try testing.expectEqualStrings("\n", aw.written());
}

test "emit json: non-finite total_cost_usd clamps to 0.0" {
    const s: Summary = .{
        .final_text = &.{},
        .session_id = &.{},
        .is_error = false,
        .total_cost_usd = std.math.nan(f64),
        .jsonl_replay = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(testing.allocator, &aw.writer, .{ .summary = &s, .duration_ms = 5 });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const cost = parsed.value.object.get("total_cost_usd").?;
    try testing.expect(cost == .integer and cost.integer == 0 or cost == .float and cost.float == 0.0);
}

test "emit json: includes error field when error_reason is set" {
    const s: Summary = .{ .final_text = &.{}, .session_id = &.{}, .is_error = true, .total_cost_usd = 0, .jsonl_replay = &.{} };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(testing.allocator, &aw.writer, .{ .summary = &s, .duration_ms = 9, .error_reason = "watchdog_expired" });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("watchdog_expired", parsed.value.object.get("error").?.string);
    try testing.expectEqualStrings("error_during_execution", parsed.value.object.get("subtype").?.string);
}

test "emit json: omits error field when error_reason is null" {
    const s: Summary = .{ .final_text = &.{}, .session_id = &.{}, .is_error = false, .total_cost_usd = 0, .jsonl_replay = &.{} };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(testing.allocator, &aw.writer, .{ .summary = &s, .duration_ms = 1 });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);
}

test "emit json: serializes all four token usage counters" {
    const s: Summary = .{
        .final_text = &.{},
        .session_id = &.{},
        .is_error = false,
        .total_cost_usd = 0,
        .jsonl_replay = &.{},
        .usage = .{ .input_tokens = 11, .output_tokens = 22, .cache_read_input_tokens = 33, .cache_creation_input_tokens = 44 },
        .duration_api_ms = 55,
        .num_turns = 3,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(testing.allocator, &aw.writer, .{ .summary = &s, .duration_ms = 66 });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const u = parsed.value.object.get("usage").?.object;
    try testing.expectEqual(@as(i64, 11), u.get("input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 44), u.get("cache_creation_input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("num_turns").?.integer);
}

test "emit stream-json: filters upstream result lines and invalid lines" {
    const jsonl =
        \\corrupt-line
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"ok"}]}}
        \\{"type":"result","session_id":"s","result":"upstream"}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .stream_json, jsonl);
    defer testing.allocator.free(out);
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    try testing.expect(std.mem.indexOf(u8, it.next().?, "\"type\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, it.next().?, "\"type\":\"result\"") != null);
    try testing.expect(it.next() == null);
}

test "writeProtocolError: emits single-line error JSON frame" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeProtocolError(&aw.writer, "turn_in_progress");
    try testing.expectEqualStrings("{\"type\":\"error\",\"error\":\"turn_in_progress\"}\n", aw.written());
}

test "emitErrorResultDetail: includes optional stage and message fields" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitErrorResultDetail(&aw.writer, "error", "startup_timeout", "sid", 900, .{
        .stage = "session_start",
        .message = "timed out",
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("session_start", parsed.value.object.get("stage").?.string);
    try testing.expectEqualStrings("timed out", parsed.value.object.get("message").?.string);
}

test "emitErrorResultDetail: omits stage and message when null" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitErrorResultDetail(&aw.writer, "error", "child_exited", "sid", 10, .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("stage") == null);
    try testing.expect(parsed.value.object.get("message") == null);
}

test "emit: inf cost clamps to 0.0 in json format" {
    const s: Summary = .{
        .final_text = &.{},
        .session_id = &.{},
        .is_error = false,
        .total_cost_usd = std.math.inf(f64),
        .jsonl_replay = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(testing.allocator, &aw.writer, .json, .{ .summary = &s, .duration_ms = 2 });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const cost = parsed.value.object.get("total_cost_usd").?;
    try testing.expect(cost == .integer and cost.integer == 0 or cost == .float and cost.float == 0.0);
}
