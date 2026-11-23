//! Parser for a Claude Code session transcript (JSONL).
//!
//! Each line of the transcript is one JSON object describing a single event
//! in the session. We extract:
//!   - the final assistant text (concatenated content[].text blocks of the
//!     last assistant message),
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

    fn fromObject(obj: std.json.ObjectMap) Usage {
        var usage: Usage = .{};
        inline for (std.meta.fields(Usage)) |field| {
            @field(usage, field.name) = unsignedField(u64, obj, field.name) orelse 0;
        }
        return usage;
    }

    fn add(total: *Usage, usage: Usage) void {
        inline for (std.meta.fields(Usage)) |field| {
            @field(total, field.name) +|= @field(usage, field.name);
        }
    }
};

pub const Summary = struct {
    /// Heap-allocated. Owned by the caller; freed by `deinit`.
    final_text: []u8,
    session_id: []u8,
    is_error: bool,
    subtype: ?[]u8 = null,
    num_turns: u32,
    total_cost_usd: f64,
    duration_api_ms: u64,
    usage: Usage,
    /// Original nonempty lines with LF terminators, or empty when replay is disabled.
    jsonl_replay: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.subtype) |value| allocator.free(value);
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

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = obj.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn appendText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), msg: std.json.ObjectMap) !void {
    const content = msg.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |block| {
        if (block != .object) continue;
        if (!std.mem.eql(u8, stringField(block.object, "type") orelse "", "text")) continue;
        if (stringField(block.object, "text")) |t| try buf.appendSlice(allocator, t);
    }
}

pub const ParseOptions = struct { keep_replay: bool = true };

/// Parse a transcript from raw JSONL bytes.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Summary {
    return parseWithOptions(allocator, bytes, .{});
}

pub fn parseWithOptions(allocator: std.mem.Allocator, bytes: []const u8, opts: ParseOptions) ParseError!Summary {
    var final_text_buf: std.ArrayList(u8) = .{};
    errdefer final_text_buf.deinit(allocator);

    var session_id_buf: std.ArrayList(u8) = .{};
    errdefer session_id_buf.deinit(allocator);

    var replay_buf: std.ArrayList(u8) = .{};
    errdefer replay_buf.deinit(allocator);

    var usage: Usage = .{};
    var result_usage: Usage = .{};
    var usage_by_id = std.StringHashMap(Usage).init(allocator);
    var id_arena = std.heap.ArenaAllocator.init(allocator);
    defer id_arena.deinit();
    defer usage_by_id.deinit();
    var last_msg_id: ?[]const u8 = null;
    var is_error = false;
    var subtype: ?[]u8 = null;
    errdefer if (subtype) |value| allocator.free(value);
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

        if (opts.keep_replay) {
            try replay_buf.appendSlice(allocator, line);
            try replay_buf.append(allocator, '\n');
        }

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

        const ty = stringField(obj, "type") orelse continue;
        var next_subtype: ?[]const u8 = null;
        if (std.mem.eql(u8, ty, "assistant")) {
            saw_assistant = true;
            const msg = objectField(obj, "message") orelse std.json.ObjectMap.init(allocator);
            const id = stringField(msg, "id");
            if (id == null or last_msg_id == null or !std.mem.eql(u8, id.?, last_msg_id.?)) {
                final_text_buf.clearRetainingCapacity();
            }
            const msg_usage = objectField(msg, "usage");
            if (id) |key| {
                const entry = try usage_by_id.getOrPut(key);
                if (!entry.found_existing) {
                    // Parsed strings can belong to the per-line JSON arena.
                    entry.key_ptr.* = try id_arena.allocator().dupe(u8, key);
                    entry.value_ptr.* = .{};
                    num_turns +|= 1;
                }
                if (msg_usage) |u| entry.value_ptr.* = Usage.fromObject(u);
                last_msg_id = entry.key_ptr.*;
            } else {
                last_msg_id = null;
                num_turns +|= 1;
                if (msg_usage) |u| usage.add(Usage.fromObject(u));
            }
            try appendText(allocator, &final_text_buf, msg);

            const api_error = obj.get("isApiErrorMessage") orelse .null;
            is_error = (api_error == .bool and api_error.bool) or
                std.mem.eql(u8, stringField(msg, "model") orelse "", "<synthetic>");
            if (is_error) next_subtype = "error_during_execution";
        } else if (std.mem.eql(u8, ty, "result")) {
            last_msg_id = null;
            if (obj.get("is_error")) |flag| {
                if (flag == .bool) is_error = flag.bool;
            }
            next_subtype = stringField(obj, "subtype");
            if (stringField(obj, "result")) |result| {
                final_text_buf.clearRetainingCapacity();
                try final_text_buf.appendSlice(allocator, result);
                saw_assistant = true;
            } else if (is_error) {
                if (obj.get("errors")) |errors| {
                    if (errors == .array) {
                        final_text_buf.clearRetainingCapacity();
                        saw_assistant = true;
                        var first = true;
                        for (errors.array.items) |item| {
                            if (item != .string) continue;
                            if (!first) try final_text_buf.append(allocator, '\n');
                            try final_text_buf.appendSlice(allocator, item.string);
                            first = false;
                        }
                    }
                }
            }
            if (objectField(obj, "usage")) |u| result_usage = Usage.fromObject(u);
            if (unsignedField(u32, obj, "num_turns")) |n| num_turns = n;
            if (obj.get("total_cost_usd")) |x| switch (x) {
                .float => total_cost_usd = x.float,
                .integer => total_cost_usd = @floatFromInt(x.integer),
                else => {},
            };
            if (unsignedField(u64, obj, "duration_api_ms")) |n| duration_api_ms = n;
        } else continue;

        const owned_subtype = if (next_subtype) |value| try allocator.dupe(u8, value) else null;
        if (subtype) |old| allocator.free(old);
        subtype = owned_subtype;
    }

    if (!saw_assistant) return error.NoAssistantMessage;
    var usage_iter = usage_by_id.valueIterator();
    while (usage_iter.next()) |u| usage.add(u.*);
    if (std.meta.eql(usage, Usage{})) usage = result_usage;

    const final_text = try final_text_buf.toOwnedSlice(allocator);
    errdefer allocator.free(final_text);
    const session_id = try session_id_buf.toOwnedSlice(allocator);
    errdefer allocator.free(session_id);
    return Summary{
        .final_text = final_text,
        .session_id = session_id,
        .is_error = is_error,
        .subtype = subtype,
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
    return parseFileFromOffsetWithOptions(allocator, path, start_offset, .{});
}

/// Open nonblocking so checking the descriptor kind also works for an idle FIFO.
pub fn openTranscriptFile(path: []const u8) !std.fs.File {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidTranscriptPath;
    const file: std.fs.File = .{ .handle = try std.posix.open(path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    }, 0) };
    errdefer file.close();
    if ((try file.stat()).kind != .file) return error.InvalidTranscriptPath;
    return file;
}

pub fn parseFileFromOffsetWithOptions(allocator: std.mem.Allocator, path: []const u8, start_offset: u64, opts: ParseOptions) !Summary {
    const file = try openTranscriptFile(path);
    defer file.close();
    const size = try file.getEndPos();
    if (size <= start_offset) return ParseError.NoAssistantMessage;
    try file.seekTo(start_offset);
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len == 0) return ParseError.NoAssistantMessage;
    return parseWithOptions(allocator, bytes, opts);
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
