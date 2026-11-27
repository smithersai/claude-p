//! Post-Stop transcript scanning, prompt-turn offset matching, and StopFailure synthesis.
const std = @import("std");
const hook_mod = @import("../hook.zig");
const transcript_mod = @import("../transcript.zig");

/// True when `final_text` agrees with a non-empty Stop `last_assistant_message`.
pub fn finalTextMatchesStop(final_text: []const u8, stop_last: ?[]const u8) bool {
    const want = stop_last orelse return true;
    const w = std.mem.trim(u8, want, " \t\r\n");
    if (w.len == 0) return true;
    return std.mem.eql(u8, std.mem.trim(u8, final_text, " \t\r\n"), w);
}

/// Validate a transcript file path using `transcript.validateTranscriptPath`.
pub fn validateTranscriptPath(path: []const u8) bool {
    return transcript_mod.validateTranscriptPath(path);
}

/// Extract and validate `transcript_path` from a hook JSON payload.
pub fn extractSafeTranscriptPath(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    const path = (try hook_mod.extractTranscriptPath(allocator, payload_json)) orelse return null;
    if (!validateTranscriptPath(path)) {
        allocator.free(path);
        return null;
    }
    std.debug.assert(path.len > 0 and path[0] == '/');
    return path;
}

/// Return the current regular-file byte size of `path`, or null if unavailable.
pub fn transcriptSize(path: ?[]const u8) ?u64 {
    const file = transcript_mod.openTranscriptRegularFile(path orelse return null) catch return null;
    defer file.close();
    return (file.stat() catch return null).size;
}

/// Classification of a post-Stop transcript record during blocking-Stop detection.
pub const StopSummaryStatus = enum { none, confirmed, continued };

fn normalizedPromptEqual(a: []const u8, b: []const u8) bool {
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (left.next()) |token| if (!std.mem.eql(u8, token, right.next() orelse return false)) return false;
    return right.next() == null;
}

fn userPromptMatches(allocator: std.mem.Allocator, obj: std.json.ObjectMap, prompt: []const u8) !bool {
    const message = obj.get("message") orelse return false;
    if (message != .object) return false;
    const content = message.object.get("content") orelse return false;
    if (content == .string) return normalizedPromptEqual(content.string, prompt);
    if (content != .array) return false;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const part = block.object.get("text") orelse continue;
        if (part == .string) try joined.appendSlice(allocator, part.string);
    }
    return normalizedPromptEqual(joined.items, prompt);
}

/// Return true when a JSONL transcript line indicates a blocking Stop hook continued the turn.
pub fn isContinuationRecord(
    allocator: std.mem.Allocator,
    line: []const u8,
    stop_last: ?[]const u8,
    current_prompt: ?[]const u8,
) !bool {
    return try stopRecordStatus(allocator, line, stop_last, current_prompt) == .continued;
}

fn stopRecordStatus(
    allocator: std.mem.Allocator,
    line: []const u8,
    stop_last: ?[]const u8,
    current_prompt: ?[]const u8,
) !StopSummaryStatus {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    defer record.deinit();
    if (record.value != .object) return .none;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return .none;
    if (ty != .string) return .none;
    if (std.mem.eql(u8, ty.string, "user")) {
        if (current_prompt) |prompt| if (try userPromptMatches(allocator, obj, prompt)) return .none;
        return .continued;
    }
    if (std.mem.eql(u8, ty.string, "tool_use")) return .continued;
    if (std.mem.eql(u8, ty.string, "system")) {
        const sub = obj.get("subtype") orelse return .none;
        if (sub != .string or !std.mem.eql(u8, sub.string, "stop_hook_summary")) return .none;
        const pc = obj.get("preventedContinuation") orelse return .confirmed;
        if (pc != .bool) return .none;
        return if (pc.bool) .continued else .confirmed;
    }
    if (!std.mem.eql(u8, ty.string, "assistant")) return .none;
    return classifyAssistantContinuation(allocator, obj, stop_last);
}

fn classifyAssistantContinuation(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    stop_last: ?[]const u8,
) !StopSummaryStatus {
    const message = obj.get("message") orelse return .none;
    if (message != .object) return .none;
    const content = message.object.get("content") orelse return .none;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    const text = switch (content) {
        .string => content.string,
        .array => |blocks| blk: {
            for (blocks.items) |block| {
                if (block != .object) continue;
                const kind = block.object.get("type") orelse continue;
                if (kind != .string) continue;
                if (std.mem.eql(u8, kind.string, "tool_use")) return .continued;
                if (!std.mem.eql(u8, kind.string, "text")) continue;
                const part = block.object.get("text") orelse continue;
                if (part == .string) try joined.appendSlice(allocator, part.string);
            }
            break :blk joined.items;
        },
        else => return .none,
    };
    const trimmed_text = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed_text.len == 0) return .none;
    const expected = stop_last orelse return .none;
    const trimmed_stop = std.mem.trim(u8, expected, " \t\r\n");
    if (trimmed_stop.len == 0) return .none;
    if (std.mem.eql(u8, trimmed_text, trimmed_stop) or std.mem.indexOf(u8, trimmed_stop, trimmed_text) != null) {
        return .none;
    }
    return .continued;
}

/// Only consume complete records from `file` up to `size`, advancing `pos`.
pub fn scanStopRecords(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    pos: *u64,
    size: u64,
    stop_last: ?[]const u8,
    prompt: []const u8,
) !StopSummaryStatus {
    std.debug.assert(pos.* <= size);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    try reader.seekTo(pos.*);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    while (reader.logicalPos() < size) {
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', limit) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try reader.interface.discardDelimiterInclusive('\n');
                pos.* = reader.logicalPos();
                continue;
            },
            else => return err,
        };
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1);
        pos.* = reader.logicalPos();
        const status = try stopRecordStatus(allocator, line.written(), stop_last, prompt);
        if (status != .none) return status;
    }
    return .none;
}

fn matchesPrompt(allocator: std.mem.Allocator, line: []const u8, prompt: []const u8) !bool {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer record.deinit();
    if (record.value != .object) return false;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "user") and try userPromptMatches(allocator, obj, prompt);
}

fn scanForPrompt(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) !?u64 {
    std.debug.assert(path.len > 0);
    const file = try transcript_mod.openTranscriptRegularFile(path);
    defer file.close();
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    var last: ?u64 = null;
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    while (true) {
        const offset = reader.logicalPos();
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', limit) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            },
            else => return err,
        };
        if (try matchesPrompt(allocator, line.written(), prompt)) last = offset;
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1);
    }
    return last;
}

/// Return the byte offset of the last user record matching `prompt` in `path`, if found.
pub fn findPromptTurnOffset(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) ?u64 {
    if (!validateTranscriptPath(path)) return null;
    return scanForPrompt(allocator, path, prompt) catch null;
}

/// Fallback message emitted when a `StopFailure` hook carries no error text.
pub const stop_failure_default_text = "claude reported StopFailure before finishing the turn";

/// Build the error `Summary` for a `StopFailure` hook.
pub fn synthesizeStopFailureSummary(allocator: std.mem.Allocator, payload: []const u8) !transcript_mod.Summary {
    var message = try hook_mod.extractErrorMessageAlloc(allocator, payload);
    errdefer if (message) |m| allocator.free(m);
    if (message) |m| {
        if (std.mem.trim(u8, m, " \t\r\n").len == 0) {
            allocator.free(m);
            message = null;
        }
    }
    if (message == null) message = try allocator.dupe(u8, stop_failure_default_text);
    const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
    errdefer allocator.free(sid);
    const replay = try allocator.dupe(u8, "");
    const final_text = message.?;
    message = null;
    std.debug.assert(final_text.len > 0);
    return .{
        .final_text = final_text,
        .session_id = sid,
        .is_error = true,
        .num_turns = 1,
        .total_cost_usd = 0.0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = replay,
    };
}

/// Replace `summary.final_text` with Stop's authoritative text when the transcript disagrees.
pub fn preferStopText(
    allocator: std.mem.Allocator,
    summary: *transcript_mod.Summary,
    stop_last: ?[]const u8,
) std.mem.Allocator.Error!void {
    if (finalTextMatchesStop(summary.final_text, stop_last)) return;
    std.debug.assert(stop_last != null);
    const fresh = try allocator.dupe(u8, stop_last.?);
    allocator.free(summary.final_text);
    summary.final_text = fresh;
    summary.is_error = false;
    if (summary.subtype) |old| allocator.free(old);
    if (summary.permission_denials) |old| allocator.free(old);
    summary.subtype = null;
    summary.permission_denials = null;
    summary.usage = .{};
    summary.num_turns = 1;
    summary.total_cost_usd = 0;
    summary.duration_api_ms = 0;
}

// -------- tests --------
const testing = std.testing;

test "finalTextMatchesStop: accepts null, blank, and trimmed equal" {
    try testing.expect(finalTextMatchesStop("ok", null));
    try testing.expect(finalTextMatchesStop("ok", "  \n"));
    try testing.expect(finalTextMatchesStop(" ok\n", "ok"));
    try testing.expect(!finalTextMatchesStop("old", "new"));
}

test "validateTranscriptPath: accepts absolute and rejects relative or traversal" {
    try testing.expect(validateTranscriptPath("/tmp/a.jsonl"));
    try testing.expect(!validateTranscriptPath("rel.jsonl"));
    try testing.expect(!validateTranscriptPath("/tmp/../etc/passwd"));
}

test "extractSafeTranscriptPath: returns clean path and drops unsafe" {
    const ok = (try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/s.jsonl\"}")).?;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("/tmp/s.jsonl", ok);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"rel\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/a\\u0000b\"}")) == null);
}

test "transcriptSize: measures file size and returns null for null/missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.jsonl", .data = "12345" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, 5), transcriptSize(path));
    try testing.expectEqual(@as(?u64, null), transcriptSize(null));
    try testing.expectEqual(@as(?u64, null), transcriptSize("/nonexistent/size.jsonl"));
}

test "isContinuationRecord: matching user prompt is not a continuation" {
    const line = "{\"type\":\"user\",\"message\":{\"content\":\"hello world\"}}";
    try testing.expect(!try isContinuationRecord(testing.allocator, line, null, "hello   world"));
}

test "isContinuationRecord: different user prompt is a continuation" {
    const line = "{\"type\":\"user\",\"message\":{\"content\":\"next task\"}}";
    try testing.expect(try isContinuationRecord(testing.allocator, line, null, "first task"));
}

test "isContinuationRecord: user array content matches normalized prompt" {
    const line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi there\"}]}}";
    try testing.expect(!try isContinuationRecord(testing.allocator, line, null, "hi\nthere"));
}

test "isContinuationRecord: top-level tool_use is a continuation" {
    try testing.expect(try isContinuationRecord(testing.allocator, "{\"type\":\"tool_use\"}", null, null));
}

test "isContinuationRecord: assistant tool_use block is a continuation" {
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"}]}}";
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", null));
}

test "isContinuationRecord: assistant matching stop_last is not a continuation" {
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}";
    try testing.expect(!try isContinuationRecord(testing.allocator, line, "done", null));
}

test "isContinuationRecord: assistant diverging from stop_last is a continuation" {
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}";
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", null));
}

test "isContinuationRecord: malformed JSON returns false" {
    try testing.expect(!try isContinuationRecord(testing.allocator, "not-json", null, null));
}

test "scanStopRecords: confirms preventedContinuation false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":false}\n";
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = data });
    const f = try tmp.dir.openFile("s.jsonl", .{});
    defer f.close();
    var pos: u64 = 0;
    try testing.expectEqual(StopSummaryStatus.confirmed, try scanStopRecords(testing.allocator, f, &pos, data.len, null, "p"));
    try testing.expectEqual(@as(u64, data.len), pos);
}

test "scanStopRecords: flags continuation when preventedContinuation true" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":true}\n";
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = data });
    const f = try tmp.dir.openFile("s.jsonl", .{});
    defer f.close();
    var pos: u64 = 0;
    try testing.expectEqual(StopSummaryStatus.continued, try scanStopRecords(testing.allocator, f, &pos, data.len, null, "p"));
}

test "scanStopRecords: returns none on incomplete line without newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "{\"type\":\"tool_use\"}";
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = data });
    const f = try tmp.dir.openFile("s.jsonl", .{});
    defer f.close();
    var pos: u64 = 0;
    try testing.expectEqual(StopSummaryStatus.none, try scanStopRecords(testing.allocator, f, &pos, data.len, null, "p"));
}

test "findPromptTurnOffset: finds last matching user offset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const l1 = "{\"type\":\"user\",\"message\":{\"content\":\"ping\"}}\n";
    const l2 = "{\"type\":\"assistant\",\"message\":{\"content\":\"pong\"}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = l1 ++ l2 ++ l1 });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, l1.len + l2.len), findPromptTurnOffset(testing.allocator, path, "ping"));
}

test "findPromptTurnOffset: rejects relative path" {
    try testing.expectEqual(@as(?u64, null), findPromptTurnOffset(testing.allocator, "rel.jsonl", "ping"));
}

test "synthesizeStopFailureSummary: extracts error and session_id" {
    var s = try synthesizeStopFailureSummary(testing.allocator, "{\"session_id\":\"s1\",\"error\":\"rate limit\"}");
    defer s.deinit(testing.allocator);
    try testing.expect(s.is_error);
    try testing.expectEqualStrings("rate limit", s.final_text);
    try testing.expectEqualStrings("s1", s.session_id);
}

test "synthesizeStopFailureSummary: falls back to default text on empty payload" {
    var s = try synthesizeStopFailureSummary(testing.allocator, "{}");
    defer s.deinit(testing.allocator);
    try testing.expect(s.is_error);
    try testing.expectEqualStrings(stop_failure_default_text, s.final_text);
}

test "preferStopText: replaces stale text and resets error metadata" {
    var s: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "stale"),
        .session_id = try testing.allocator.dupe(u8, "s1"),
        .is_error = true,
        .subtype = try testing.allocator.dupe(u8, "error"),
        .num_turns = 3,
        .total_cost_usd = 1.5,
        .duration_api_ms = 99,
        .usage = .{ .input_tokens = 10 },
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer s.deinit(testing.allocator);
    try preferStopText(testing.allocator, &s, "fresh");
    try testing.expectEqualStrings("fresh", s.final_text);
    try testing.expect(!s.is_error);
    try testing.expect(s.subtype == null);
    try testing.expectEqual(@as(u64, 0), s.usage.input_tokens);
}
