//! Extended fixture tests extracted from `transcript.zig` and `hook.zig` (run under `zig build test`).
const std = @import("std");
const claude_p = @import("claude_p");

const transcript = claude_p.transcript;
const hook = claude_p.hook;
const testing = std.testing;

const offset_turn1 =
    "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"first question\"}}\n" ++
    "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"message\":{\"content\":[{\"type\":\"text\"," ++
    "\"text\":\"old answer\"}],\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\n";
const offset_turn2 =
    "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"second question\"}}\n" ++
    "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"message\":{\"content\":[{\"type\":\"text\"," ++
    "\"text\":\"new answer\"}],\"usage\":{\"input_tokens\":7,\"output_tokens\":4}}}\n";

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
    var a = try transcript.parseFileFromOffset(testing.allocator, path, 0);
    defer a.deinit(testing.allocator);
    var b = try transcript.parseFile(testing.allocator, path);
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
    var s = try transcript.parseFileFromOffset(testing.allocator, path, offset_turn1.len);
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
        transcript.ParseError.NoAssistantMessage,
        transcript.parseFileFromOffset(testing.allocator, path, offset_turn1.len),
    );
}

test "parseFileFromOffset: offset at or past EOF returns NoAssistantMessage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{offset_turn1});
    defer testing.allocator.free(path);
    try testing.expectError(
        transcript.ParseError.NoAssistantMessage,
        transcript.parseFileFromOffset(testing.allocator, path, offset_turn1.len),
    );
    try testing.expectError(
        transcript.ParseError.NoAssistantMessage,
        transcript.parseFileFromOffset(testing.allocator, path, offset_turn1.len + 1000),
    );
}

test "parseFileFromOffset: offset inside a line skips torn fragment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeOffsetFixture(&tmp, &.{ offset_turn1, offset_turn2 });
    defer testing.allocator.free(path);
    var s = try transcript.parseFileFromOffset(testing.allocator, path, offset_turn1.len - 20);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("new answer", s.final_text);
    try testing.expectEqual(@as(u32, 1), s.num_turns);
}

test "hook settings json: rejects disableAllHooks true and accepts every other value" {
    const a = testing.allocator;
    for ([_][]const u8{
        "{\"disableAllHooks\":true}",
        " { \"model\" : \"opus\" , \"disableAllHooks\" : true } ",
        "{\"disable\\u0041llHooks\":true}",
        "{\"disableAllHooks\":false,\"disableAllHooks\":true}",
    }) |bad| {
        const opts: hook.CreateOptions = .{ .extra_settings_json = bad };
        try testing.expectError(error.InvalidExtraSettings, hook.validateExtraSettings(a, opts));
        try testing.expectError(error.InvalidExtraSettings, hook.buildSettingsJson(a, "/tmp/hook.sh", opts));
        try testing.expectError(error.InvalidExtraSettings, hook.createWithOptions(a, opts));
    }
    for ([_][]const u8{
        "{\"disableAllHooks\":false}",
        "{\"disableAllHooks\":true,\"disableAllHooks\":false}",
        "{\"disableAllHooks\":\"true\"}",
        "{\"disableAllHooks\":1}",
        "{\"env\":{\"disableAllHooks\":true}}",
        "{\"DisableAllHooks\":true}",
    }) |ok| {
        const opts: hook.CreateOptions = .{ .extra_settings_json = ok };
        try hook.validateExtraSettings(a, opts);
        const json = try hook.buildSettingsJson(a, "/tmp/hook.sh", opts);
        a.free(json);
    }
}

test "hook extractErrorMessage: error, then message, then reason" {
    const a = testing.allocator;
    const cases = [_]struct { payload: []const u8, want: ?[]const u8 }{
        .{ .payload = "{\"error\":\"rate_limit\",\"message\":\"m\",\"reason\":\"r\"}", .want = "rate_limit" },
        .{ .payload = "{\"reason\":\"r\",\"message\":\"m\"}", .want = "m" },
        .{ .payload = "{\"reason\":\"overloaded\\nretry\"}", .want = "overloaded\nretry" },
        .{ .payload = "{\"error\":{\"type\":\"api\",\"message\":\"boom\"},\"reason\":\"r\"}", .want = "boom" },
        .{ .payload = "{\"error\":42,\"message\":null,\"reason\":\"r\"}", .want = "r" },
        .{ .payload = "{\"error\":{\"message\":7}}", .want = null },
        .{ .payload = "{\"error\":\"\"}", .want = "" },
        .{ .payload = "{}", .want = null },
        .{ .payload = "[]", .want = null },
        .{ .payload = "not-json", .want = null },
    };
    for (cases) |case| {
        const got = hook.extractErrorMessage(a, case.payload);
        defer if (got) |g| a.free(g);
        if (case.want) |want| {
            try testing.expectEqualStrings(want, got orelse return error.TestExpectedString);
        } else {
            try testing.expectEqual(@as(?[]u8, null), got);
        }
    }
}

test "hook parseLineWithNonce: rejects invalid, short, long, and legacy lines" {
    const nonce = "0123456789abcdef";
    for ([_][]const u8{
        "Stop\t{}",
        "0123456789abcdee\tStop\t{}",
        "0123456789abcde\tStop\t{}",
        "0123456789abcdef0\tStop\t{}",
        "0123456789ABCDEF\tStop\t{}",
        "0123456789abcdef\tStop",
        "0123456789abcdef\t",
        "0123456789abcdef",
        "\tStop\t{}",
        "",
    }) |bad| {
        try testing.expectEqual(@as(?hook.HookLine, null), hook.parseLineWithNonce(bad, nonce));
    }
    try testing.expectEqual(@as(?hook.HookLine, null), hook.parseLineWithNonce("\tStop\t{}", ""));
}

test "hook create: private 0700 directory, embedded script, distinct nonces" {
    var h = try hook.create(testing.allocator);
    defer h.deinit();
    var other = try hook.create(testing.allocator);
    defer other.deinit();

    try testing.expect(std.fs.path.isAbsolute(h.tmp_dir));
    const dir_stat = try std.fs.cwd().statFile(h.tmp_dir);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), dir_stat.mode & 0o777);
    const script_stat = try std.fs.cwd().statFile(h.script_path);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), script_stat.mode & 0o777);
    try testing.expect(!std.mem.eql(u8, &h.nonce, &other.nonce));
    try testing.expect(!std.mem.eql(u8, h.tmp_dir, other.tmp_dir));
}
