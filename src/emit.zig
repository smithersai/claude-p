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
pub const OutputFormat = args_mod.OutputFormat;

pub const ResultEnvelope = struct {
    summary: *const Summary,
    duration_ms: u64,
    error_reason: ?[]const u8 = null,
};

pub fn emit(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    fmt: OutputFormat,
    env: ResultEnvelope,
) !void {
    switch (fmt) {
        .text => try emitText(writer, env),
        .json => try emitJson(allocator, writer, env),
        .stream_json => try emitStreamJson(allocator, writer, env),
    }
}

pub fn emitText(writer: *std.Io.Writer, env: ResultEnvelope) !void {
    try writer.writeAll(env.summary.final_text);
    if (!std.mem.endsWith(u8, env.summary.final_text, "\n")) try writer.writeByte('\n');
}

pub fn emitJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    env: ResultEnvelope,
) !void {
    _ = allocator;
    const s = env.summary;
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
    try jw.write(if (std.math.isFinite(s.total_cost_usd)) s.total_cost_usd else @as(f64, 0.0));
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

pub fn emitStreamJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    env: ResultEnvelope,
) !void {
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

pub fn emitErrorResultDetail(
    writer: *std.Io.Writer,
    subtype: []const u8,
    error_reason: []const u8,
    session_id: []const u8,
    duration_ms: u64,
    detail: struct { stage: ?[]const u8 = null, message: ?[]const u8 = null },
) !void {
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

// -------- tests --------

const testing = std.testing;

fn parseAndEmit(
    allocator: std.mem.Allocator,
    fmt: OutputFormat,
    jsonl: []const u8,
) ![]u8 {
    var s = try transcript_mod.parse(allocator, jsonl);
    defer s.deinit(allocator);
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    try emit(allocator, &aw.writer, fmt, .{ .summary = &s, .duration_ms = 100 });
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

test "emit text: final message + newline" {
    const jsonl =
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"hi"}]}}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .text, jsonl);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi\n", out);
}

test "emit text: preserves an existing final newline" {
    const jsonl =
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"hi\n"}]}}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .text, jsonl);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi\n", out);
}

test "emit json: result object shape" {
    const jsonl =
        \\{"type":"assistant","session_id":"sid","message":{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"output_tokens":1}}}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .json, jsonl);
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
    const usage = obj.get("usage").?.object;
    try testing.expectEqual(@as(i64, 2), usage.get("input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 1), usage.get("output_tokens").?.integer);
}

test "emit json preserves permission denials as an array" {
    const out = try parseAndEmit(testing.allocator, .json,
        \\{"type":"result","result":"ok","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"echo hi"}}]}
    );
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const denials = parsed.value.object.get("permission_denials").?.array.items;
    try testing.expectEqual(1, denials.len);
    try testing.expectEqualStrings("Bash", denials[0].object.get("tool_name").?.string);
    try testing.expectEqualStrings("echo hi", denials[0].object.get("tool_input").?.object.get("command").?.string);
}

test "emit json: error result" {
    const jsonl =
        \\{"type":"assistant","session_id":"e","message":{"content":[{"type":"text","text":"boom"}]}}
        \\{"type":"result","subtype":"error","session_id":"e","result":"boom","is_error":true}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .json, jsonl);
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("error", parsed.value.object.get("subtype").?.string);
    try testing.expect(parsed.value.object.get("is_error").?.bool);
}

test "emit stream-json: replay + trailing result" {
    const jsonl =
        \\{"type":"system","subtype":"init","session_id":"s"}
        \\{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"go"}]}}
        \\
    ;
    const out = try parseAndEmit(testing.allocator, .stream_json, jsonl);
    defer testing.allocator.free(out);
    // First two lines are the original events; third is the result envelope.
    var iter = std.mem.splitScalar(u8, out, '\n');
    const line1 = iter.next().?;
    const line2 = iter.next().?;
    const line3 = iter.next().?;
    try testing.expect(std.mem.indexOf(u8, line1, "\"subtype\":\"init\"") != null);
    try testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, line3, "\"type\":\"result\"") != null);
}

fn errorResultLine(
    allocator: std.mem.Allocator,
    subtype: []const u8,
    error_reason: []const u8,
    session_id: []const u8,
    duration_ms: u64,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    try emitErrorResult(allocator, &aw.writer, subtype, error_reason, session_id, duration_ms);
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

test "emitErrorResult: exact wire line for a timeout" {
    const out = try errorResultLine(testing.allocator, "error", "transcript_stalled", "sid-1", 4200);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"type\":\"result\",\"subtype\":\"error\",\"error\":\"transcript_stalled\"," ++
            "\"session_id\":\"sid-1\",\"result\":\"\",\"is_error\":true,\"duration_ms\":4200," ++
            "\"duration_api_ms\":0,\"num_turns\":0,\"total_cost_usd\":0," ++
            "\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0," ++
            "\"cache_creation_input_tokens\":0},\"permission_denials\":[]}\n",
        out,
    );
}

test "emitErrorResult: interrupted round-trips with is_error false" {
    const out = try errorResultLine(testing.allocator, "interrupted", "interrupted", "sid-2", 1500);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("interrupted", obj.get("subtype").?.string);
    try testing.expectEqualStrings("interrupted", obj.get("error").?.string);
    try testing.expectEqualStrings("sid-2", obj.get("session_id").?.string);
    try testing.expectEqualStrings("", obj.get("result").?.string);
    try testing.expect(!obj.get("is_error").?.bool);
    try testing.expectEqual(@as(i64, 1500), obj.get("duration_ms").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("num_turns").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("permission_denials").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), obj.get("usage").?.object.get("output_tokens").?.integer);
}

test "emitErrorResult: other subtypes are errors" {
    const subtypes = [_][]const u8{ "error", "error_during_execution", "" };
    for (subtypes) |subtype| {
        const out = try errorResultLine(testing.allocator, subtype, "idle_timeout", "", 0);
        defer testing.allocator.free(out);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("is_error").?.bool);
    }
}

test "emitErrorResult: strings are JSON-escaped and stay on one line" {
    const reason = "bad \"quote\" \\ back\nnew\tline \x01";
    const sid = "s\"id\n";
    const out = try errorResultLine(testing.allocator, "err\"or", reason, sid, 7);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("err\"or", obj.get("subtype").?.string);
    try testing.expectEqualStrings(reason, obj.get("error").?.string);
    try testing.expectEqualStrings(sid, obj.get("session_id").?.string);
}
