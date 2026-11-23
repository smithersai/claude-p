//! Parser for a Claude Code session transcript (JSONL).
//!
//! Each line of the transcript is one JSON object describing a single event
//! in the session. We extract:
//!   - the final assistant text (concatenated content[].text blocks of the
//!     last `assistant` event),
//!   - aggregated `usage` totals across all assistant messages,
//!   - the session id (from any line that includes one),
//!   - flags telling us whether an error result was reported.
//!
//! The transcript path comes to us via the Stop hook's `transcript_path`
//! field. We never write to it.
const std = @import("std");

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const Summary = struct {
    /// Heap-allocated. Owned by the caller; freed by `deinit`.
    final_text: []u8,
    session_id: []u8,
    is_error: bool,
    num_turns: u32,
    total_cost_usd: f64,
    duration_api_ms: u64,
    usage: Usage,
    /// Pretty-printed view of the original transcript, re-serialized as
    /// strict JSONL. Used by `emit.stream_json`. Owned by the caller.
    jsonl_replay: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.final_text);
        allocator.free(self.session_id);
        allocator.free(self.jsonl_replay);
    }
};

pub const ParseError = error{
    NoAssistantMessage,
    OutOfMemory,
    InvalidJson,
};

// Dynamic JSON stores integers outside i64 as number strings. Accept the
// full destination range and ignore invalid counters like other mistyped fields.
fn unsignedField(comptime T: type, obj: std.json.ObjectMap, name: []const u8) ?T {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| std.math.cast(T, n),
        .number_string => |digits| std.fmt.parseUnsigned(T, digits, 10) catch null,
        else => null,
    };
}

/// Parse a transcript from raw JSONL bytes.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Summary {
    var final_text_buf: std.ArrayList(u8) = .{};
    errdefer final_text_buf.deinit(allocator);

    var session_id_buf: std.ArrayList(u8) = .{};
    errdefer session_id_buf.deinit(allocator);

    var replay_buf: std.ArrayList(u8) = .{};
    errdefer replay_buf.deinit(allocator);

    var usage: Usage = .{};
    var is_error = false;
    var num_turns: u32 = 0;
    var total_cost_usd: f64 = 0.0;
    var duration_api_ms: u64 = 0;
    var saw_assistant = false;

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        // Trim trailing \r and skip empty lines.
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        try replay_buf.appendSlice(allocator, line);
        try replay_buf.append(allocator, '\n');

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Skip malformed lines without aborting the whole parse.
            else => continue,
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;

        // Session id (every event has one). Field is `sessionId` in real
        // Claude transcripts and `session_id` in the legacy stream-json
        // format. Accept both.
        if (session_id_buf.items.len == 0) {
            if (obj.get("sessionId")) |v| {
                if (v == .string) try session_id_buf.appendSlice(allocator, v.string);
            } else if (obj.get("session_id")) |v| {
                if (v == .string) try session_id_buf.appendSlice(allocator, v.string);
            }
        }

        const ty = obj.get("type") orelse continue;
        if (ty != .string) continue;

        if (std.mem.eql(u8, ty.string, "assistant")) {
            saw_assistant = true;
            num_turns +|= 1;

            // Reset and accumulate text from this assistant turn — we want
            // the *last* assistant message, so each new one overwrites.
            final_text_buf.clearRetainingCapacity();

            if (obj.get("message")) |msg| {
                if (msg == .object) {
                    if (msg.object.get("content")) |content| {
                        if (content == .array) {
                            for (content.array.items) |block| {
                                if (block != .object) continue;
                                const block_type = block.object.get("type") orelse continue;
                                if (block_type != .string) continue;
                                if (std.mem.eql(u8, block_type.string, "text")) {
                                    if (block.object.get("text")) |t| {
                                        if (t == .string) try final_text_buf.appendSlice(allocator, t.string);
                                    }
                                }
                            }
                        }
                    }
                    if (msg.object.get("usage")) |u| {
                        if (u == .object) {
                            usage.input_tokens +%= unsignedField(u64, u.object, "input_tokens") orelse 0;
                            usage.output_tokens +%= unsignedField(u64, u.object, "output_tokens") orelse 0;
                            usage.cache_read_input_tokens +%= unsignedField(u64, u.object, "cache_read_input_tokens") orelse 0;
                            usage.cache_creation_input_tokens +%= unsignedField(u64, u.object, "cache_creation_input_tokens") orelse 0;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, ty.string, "result")) {
            // Final result event — overrides everything if present.
            if (obj.get("result")) |r| {
                if (r == .string) {
                    final_text_buf.clearRetainingCapacity();
                    try final_text_buf.appendSlice(allocator, r.string);
                    saw_assistant = true;
                }
            }
            if (obj.get("is_error")) |x|
                if (x == .bool) {
                    is_error = x.bool;
                };
            if (unsignedField(u32, obj, "num_turns")) |n| num_turns = n;
            if (obj.get("total_cost_usd")) |x| switch (x) {
                .float => total_cost_usd = x.float,
                .integer => total_cost_usd = @floatFromInt(x.integer),
                else => {},
            };
            if (unsignedField(u64, obj, "duration_api_ms")) |n| duration_api_ms = n;
        }
    }

    if (!saw_assistant) {
        // errdefer above will release the three temporary buffers.
        return ParseError.NoAssistantMessage;
    }

    const final_text = try final_text_buf.toOwnedSlice(allocator);
    errdefer allocator.free(final_text);
    const session_id = try session_id_buf.toOwnedSlice(allocator);
    errdefer allocator.free(session_id);
    return Summary{
        .final_text = final_text,
        .session_id = session_id,
        .is_error = is_error,
        .num_turns = num_turns,
        .total_cost_usd = total_cost_usd,
        .duration_api_ms = duration_api_ms,
        .usage = usage,
        .jsonl_replay = try replay_buf.toOwnedSlice(allocator),
    };
}

/// Convenience: parse from a file path.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Summary {
    return parseFileFromOffset(allocator, path, 0);
}

/// Parse only the bytes in `[start_offset..EOF]` of a transcript file.
///
/// Used for `--resume` / `--continue` isolation: the driver snapshots the
/// transcript file size just before typing our prompt and passes it here so
/// earlier turns are never returned as this turn's answer. Returns
/// `ParseError.NoAssistantMessage` when the file size is `<= start_offset`
/// or when no assistant/result record exists in the appended slice.
pub fn parseFileFromOffset(allocator: std.mem.Allocator, path: []const u8, start_offset: u64) !Summary {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    if (size <= start_offset) return ParseError.NoAssistantMessage;
    try file.seekTo(start_offset);
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len == 0) return ParseError.NoAssistantMessage;
    return parse(allocator, bytes);
}

// -------- tests --------

const testing = std.testing;

test "parse: single assistant message" {
    const jsonl =
        \\{"type":"assistant","session_id":"abc","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hello, world."}],"usage":{"input_tokens":10,"output_tokens":3}}}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello, world.", s.final_text);
    try testing.expectEqualStrings("abc", s.session_id);
    try testing.expectEqual(@as(u32, 1), s.num_turns);
    try testing.expectEqual(@as(u64, 10), s.usage.input_tokens);
    try testing.expectEqual(@as(u64, 3), s.usage.output_tokens);
    try testing.expect(!s.is_error);
}

test "parse: multiple turns — last assistant wins" {
    const jsonl =
        \\{"type":"system","subtype":"init","session_id":"xyz"}
        \\{"type":"assistant","session_id":"xyz","message":{"content":[{"type":"text","text":"first"}],"usage":{"input_tokens":5,"output_tokens":2}}}
        \\{"type":"user","session_id":"xyz","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        \\{"type":"assistant","session_id":"xyz","message":{"content":[{"type":"text","text":"final answer"}],"usage":{"input_tokens":7,"output_tokens":4}}}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("final answer", s.final_text);
    try testing.expectEqualStrings("xyz", s.session_id);
    try testing.expectEqual(@as(u64, 12), s.usage.input_tokens);
    try testing.expectEqual(@as(u64, 6), s.usage.output_tokens);
}

test "parse: result event wins for final text + flags" {
    const jsonl =
        \\{"type":"assistant","session_id":"r","message":{"content":[{"type":"text","text":"draft"}]}}
        \\{"type":"result","subtype":"success","session_id":"r","result":"final","is_error":false,"num_turns":2,"total_cost_usd":0.0421,"duration_api_ms":9120}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("final", s.final_text);
    try testing.expect(!s.is_error);
    try testing.expectEqual(@as(u32, 2), s.num_turns);
    try testing.expectApproxEqAbs(@as(f64, 0.0421), s.total_cost_usd, 1e-9);
    try testing.expectEqual(@as(u64, 9120), s.duration_api_ms);
}

test "parse: error result event" {
    const jsonl =
        \\{"type":"assistant","session_id":"e","message":{"content":[{"type":"text","text":"oops"}]}}
        \\{"type":"result","subtype":"error","session_id":"e","result":"failure detail","is_error":true}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("failure detail", s.final_text);
    try testing.expect(s.is_error);
}

test "parse: no assistant returns error" {
    const jsonl =
        \\{"type":"system","subtype":"init","session_id":"x"}
        \\
    ;
    try testing.expectError(ParseError.NoAssistantMessage, parse(testing.allocator, jsonl));
}

test "parse: skips malformed lines" {
    const jsonl =
        \\not-json
        \\{"type":"assistant","session_id":"k","message":{"content":[{"type":"text","text":"alive"}]}}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("alive", s.final_text);
}

test "parse: replay preserves lines verbatim" {
    const jsonl =
        \\{"type":"system","subtype":"init","session_id":"a"}
        \\{"type":"assistant","session_id":"a","message":{"content":[{"type":"text","text":"hi"}]}}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, s.jsonl_replay, "\"subtype\":\"init\"") != null);
    try testing.expect(std.mem.indexOf(u8, s.jsonl_replay, "\"text\":\"hi\"") != null);
}

test "parse: multi-block text concatenation" {
    const jsonl =
        \\{"type":"assistant","session_id":"c","message":{"content":[{"type":"text","text":"part1 "},{"type":"tool_use","name":"X"},{"type":"text","text":"part2"}]}}
        \\
    ;
    var s = try parse(testing.allocator, jsonl);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("part1 part2", s.final_text);
}

const offset_turn1 =
    \\{"type":"user","sessionId":"s1","message":{"content":"first question"}}
    \\{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"old answer"}],"usage":{"input_tokens":5,"output_tokens":2}}}
    \\
;
const offset_turn2 =
    \\{"type":"user","sessionId":"s1","message":{"content":"second question"}}
    \\{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"new answer"}],"usage":{"input_tokens":7,"output_tokens":4}}}
    \\
;

fn writeOffsetFixture(tmp: *std.testing.TmpDir, parts: []const []const u8) ![]u8 {
    var f = try tmp.dir.createFile("t.jsonl", .{});
    defer f.close();
    for (parts) |p| try f.writeAll(p);
    return try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
}

test "parseFileFromOffset: offset 0 equals parseFile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{ offset_turn1, offset_turn2 });
    defer testing.allocator.free(path);

    var a = try parseFileFromOffset(testing.allocator, path, 0);
    defer a.deinit(testing.allocator);
    var b = try parseFile(testing.allocator, path);
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("new answer", a.final_text);
    try testing.expectEqualStrings(b.final_text, a.final_text);
    try testing.expectEqualStrings(b.jsonl_replay, a.jsonl_replay);
    try testing.expectEqual(@as(u32, 2), a.num_turns);
    try testing.expectEqual(@as(u64, 12), a.usage.input_tokens);
}

test "parseFileFromOffset: mid-file offset returns only the new turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{ offset_turn1, offset_turn2 });
    defer testing.allocator.free(path);

    var s = try parseFileFromOffset(testing.allocator, path, offset_turn1.len);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("new answer", s.final_text);
    try testing.expectEqualStrings("s1", s.session_id);
    try testing.expectEqual(@as(u32, 1), s.num_turns);
    try testing.expectEqual(@as(u64, 7), s.usage.input_tokens);
    try testing.expectEqual(@as(u64, 4), s.usage.output_tokens);
    try testing.expect(std.mem.indexOf(u8, s.jsonl_replay, "old answer") == null);
    try testing.expectEqualStrings(offset_turn2, s.jsonl_replay);
}

test "parseFileFromOffset: appended user-only slice never yields old answer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const user_only = offset_turn2[0 .. std.mem.indexOfScalar(u8, offset_turn2, '\n').? + 1];
    const path = try writeOffsetFixture(&tmp, &.{ offset_turn1, user_only });
    defer testing.allocator.free(path);
    try testing.expectError(
        ParseError.NoAssistantMessage,
        parseFileFromOffset(testing.allocator, path, offset_turn1.len),
    );
}

test "parseFileFromOffset: offset at or past EOF returns NoAssistantMessage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{offset_turn1});
    defer testing.allocator.free(path);
    try testing.expectError(
        ParseError.NoAssistantMessage,
        parseFileFromOffset(testing.allocator, path, offset_turn1.len),
    );
    try testing.expectError(
        ParseError.NoAssistantMessage,
        parseFileFromOffset(testing.allocator, path, offset_turn1.len + 1000),
    );
}

test "parseFileFromOffset: offset inside a line skips torn fragment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{ offset_turn1, offset_turn2 });
    defer testing.allocator.free(path);
    var s = try parseFileFromOffset(testing.allocator, path, offset_turn1.len - 20);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("new answer", s.final_text);
    try testing.expectEqual(@as(u32, 1), s.num_turns);
}

test "parseFileFromOffset: missing file returns FileNotFound" {
    try testing.expectError(
        error.FileNotFound,
        parseFileFromOffset(testing.allocator, "/nonexistent/claude-p/t.jsonl", 0),
    );
}
