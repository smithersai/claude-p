//! Transcript summary types, JSON field helpers, and safe regular-file offset reader.
const std = @import("std");

/// Hard upper bound on transcript slice bytes loaded into memory (64 MiB).
pub const max_transcript_file_bytes: usize = 64 * 1024 * 1024;

/// Aggregated token usage counters across assistant or result records.
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,

    pub fn fromObject(obj: std.json.ObjectMap) Usage {
        var usage: Usage = .{};
        inline for (std.meta.fields(Usage)) |field| {
            @field(usage, field.name) = unsignedField(u64, obj, field.name) orelse 0;
        }
        return usage;
    }

    pub fn add(total: *Usage, usage: Usage) void {
        std.debug.assert(@intFromPtr(total) != 0);
        inline for (std.meta.fields(Usage)) |field| {
            @field(total, field.name) +|= @field(usage, field.name);
        }
    }
};

/// Parsed summary of a Claude Code session JSONL transcript slice.
pub const Summary = struct {
    final_text: []u8,
    session_id: []u8,
    is_error: bool,
    subtype: ?[]u8 = null,
    permission_denials: ?[]u8 = null,
    num_turns: u32 = 0,
    total_cost_usd: f64,
    duration_api_ms: u64 = 0,
    usage: Usage = .{},
    jsonl_replay: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.permission_denials) |value| allocator.free(value);
        if (self.subtype) |value| allocator.free(value);
        allocator.free(self.final_text);
        allocator.free(self.session_id);
        allocator.free(self.jsonl_replay);
    }
};

/// Error set returned when parsing JSONL transcript bytes.
pub const ParseError = error{
    NoAssistantMessage,
    OutOfMemory,
    InvalidJson,
};

/// Optional controls for replay retention and stop-text prefix matching.
pub const ParseOptions = struct { keep_replay: bool = true, stop_text: ?[]const u8 = null };

/// Extract an unsigned integer counter from a JSON object, supporting number strings.
pub fn unsignedField(comptime T: type, obj: std.json.ObjectMap, name: []const u8) ?T {
    std.debug.assert(name.len > 0);
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| std.math.cast(T, n),
        .number_string => |digits| std.fmt.parseUnsigned(T, digits, 10) catch null,
        else => null,
    };
}

/// Extract a string field from a JSON object, or null when missing or non-string.
pub fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    const value = obj.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

/// Extract a nested JSON object field, or null when missing or non-object.
pub fn objectField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    std.debug.assert(name.len > 0);
    const value = obj.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

/// Append all `{"type":"text","text":"..."}` blocks from a message object to `buf`.
pub fn appendText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), msg: std.json.ObjectMap) !void {
    const content = msg.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |block| {
        if (block != .object) continue;
        if (!std.mem.eql(u8, stringField(block.object, "type") orelse "", "text")) continue;
        if (stringField(block.object, "text")) |t| try buf.appendSlice(allocator, t);
    }
}

/// Compare two text strings after trimming surrounding ASCII whitespace.
pub fn textMatches(text: []const u8, wanted: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), std.mem.trim(u8, wanted, " \t\r\n"));
}

/// Validate that `path` is an absolute path without NUL bytes or `..` segments.
pub fn validateTranscriptPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// Alias for `openTranscriptRegularFile` used by transcript readers and tailers.
pub const openTranscriptFile = openTranscriptRegularFile;

/// Open `path` non-blocking with `O_NOFOLLOW` and verify it is a regular file.
pub fn openTranscriptRegularFile(path: []const u8) !std.fs.File {
    if (!validateTranscriptPath(path)) return error.InvalidTranscriptPath;
    std.debug.assert(path.len > 0 and path[0] == '/');
    const file: std.fs.File = .{ .handle = try std.posix.open(path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOCTTY = true,
        .NOFOLLOW = true,
    }, 0) };
    errdefer file.close();
    if ((try file.stat()).kind != .file) return error.InvalidTranscriptPath;
    return file;
}

/// Read `[start_offset..EOF]` from a regular transcript file, bounded by `max_transcript_file_bytes`.
/// Returns `null` when `size <= start_offset`.
pub fn readSliceFromOffset(allocator: std.mem.Allocator, path: []const u8, start_offset: u64) !?[]u8 {
    const file = try openTranscriptRegularFile(path);
    defer file.close();
    const size = (try file.stat()).size;
    if (size <= start_offset) return null;
    std.debug.assert(size > start_offset);
    if (size - start_offset > max_transcript_file_bytes) return error.FileTooBig;
    try file.seekTo(start_offset);
    const bytes = try file.readToEndAlloc(allocator, max_transcript_file_bytes);
    if (bytes.len == 0) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

// -------- tests --------
const testing = std.testing;

test "validateTranscriptPath: accepts clean absolute paths" {
    try testing.expect(validateTranscriptPath("/tmp/session.jsonl"));
    try testing.expect(validateTranscriptPath("/var/log/claude/a..b.jsonl"));
}

test "validateTranscriptPath: rejects empty path" {
    try testing.expect(!validateTranscriptPath(""));
}

test "validateTranscriptPath: rejects relative paths" {
    try testing.expect(!validateTranscriptPath("session.jsonl"));
    try testing.expect(!validateTranscriptPath("./session.jsonl"));
}

test "validateTranscriptPath: rejects embedded NUL bytes" {
    try testing.expect(!validateTranscriptPath("/tmp/a\x00b.jsonl"));
}

test "validateTranscriptPath: rejects parent traversal segments" {
    try testing.expect(!validateTranscriptPath("/tmp/../etc/passwd"));
    try testing.expect(!validateTranscriptPath("/.."));
    try testing.expect(!validateTranscriptPath("/a/b/.."));
}

test "validateTranscriptPath: allows single-dot and double-dot within filenames" {
    try testing.expect(validateTranscriptPath("/tmp/./a.jsonl"));
    try testing.expect(validateTranscriptPath("/tmp/..hidden.jsonl"));
    try testing.expect(validateTranscriptPath("/tmp/file..jsonl"));
}

test "openTranscriptRegularFile: opens an existing regular file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.jsonl", .data = "hi\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.jsonl");
    defer testing.allocator.free(path);
    const f = try openTranscriptRegularFile(path);
    f.close();
}

test "openTranscriptRegularFile: rejects relative path" {
    try testing.expectError(error.InvalidTranscriptPath, openTranscriptRegularFile("relative.jsonl"));
}

test "openTranscriptRegularFile: rejects directory path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    try testing.expectError(error.InvalidTranscriptPath, openTranscriptRegularFile(dir));
}

test "openTranscriptRegularFile: rejects symlink via O_NOFOLLOW" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "real.jsonl", .data = "x" });
    try tmp.dir.symLink("real.jsonl", "link.jsonl", .{});
    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const link_path = try std.fs.path.join(testing.allocator, &.{ base, "link.jsonl" });
    defer testing.allocator.free(link_path);
    try testing.expectError(error.SymLinkLoop, openTranscriptRegularFile(link_path));
}

test "openTranscriptRegularFile: returns FileNotFound for missing absolute file" {
    try testing.expectError(error.FileNotFound, openTranscriptRegularFile("/nonexistent/claude-p-missing.jsonl"));
}

test "openTranscriptFile: alias matches openTranscriptRegularFile" {
    try testing.expectError(error.InvalidTranscriptPath, openTranscriptFile(""));
}

test "readSliceFromOffset: reads full file from offset 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "abcdef" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    const got = (try readSliceFromOffset(testing.allocator, path, 0)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abcdef", got);
}

test "readSliceFromOffset: reads suffix from mid-file offset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "abcdef" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    const got = (try readSliceFromOffset(testing.allocator, path, 3)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("def", got);
}

test "readSliceFromOffset: returns null at exact EOF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "abc" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?[]u8, null), try readSliceFromOffset(testing.allocator, path, 3));
}

test "readSliceFromOffset: returns null past EOF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "abc" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?[]u8, null), try readSliceFromOffset(testing.allocator, path, 999));
}

test "readSliceFromOffset: returns null on empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "empty.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "empty.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?[]u8, null), try readSliceFromOffset(testing.allocator, path, 0));
}

test "readSliceFromOffset: propagates InvalidTranscriptPath" {
    try testing.expectError(error.InvalidTranscriptPath, readSliceFromOffset(testing.allocator, "rel.jsonl", 0));
}

test "readSliceFromOffset: propagates FileNotFound" {
    try testing.expectError(error.FileNotFound, readSliceFromOffset(testing.allocator, "/nonexistent/t.jsonl", 0));
}

test "max_transcript_file_bytes is 64 MiB" {
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), max_transcript_file_bytes);
}
