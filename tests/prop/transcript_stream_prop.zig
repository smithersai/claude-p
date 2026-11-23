const std = @import("std");
const transcript = @import("claude_p").transcript;
const Tailer = @import("claude_p").stream.Tailer;
const testing = std.testing;
const alloc = testing.allocator;

const negative = "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":-1}}}";
const boundary = "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":9223372036854775808,\"output_tokens\":18446744073709551615,\"cache_read_input_tokens\":18446744073709551616,\"cache_creation_input_tokens\":-9223372036854775808}}}";
const invalid_result = "{\"type\":\"result\",\"result\":\"\",\"num_turns\":4294967296,\"duration_api_ms\":-1}";
const max_turns = "{\"type\":\"assistant\"}\n{\"type\":\"result\",\"num_turns\":4294967295}";

fn expectReplay(bytes: []const u8, replay: []const u8) !void {
    var remaining = replay;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const normalized = if (raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (normalized.len == 0) continue;
        try testing.expect(remaining.len > normalized.len);
        try testing.expectEqualSlices(u8, normalized, remaining[0..normalized.len]);
        try testing.expectEqual(@as(u8, '\n'), remaining[normalized.len]);
        remaining = remaining[normalized.len + 1 ..];
    }
    try testing.expectEqual(@as(usize, 0), remaining.len);
}

fn checkRawParse(bytes: []const u8) !void {
    var summary = transcript.parse(alloc, bytes) catch |err| switch (err) {
        error.NoAssistantMessage => return,
        else => return err,
    };
    defer summary.deinit(alloc);
    try expectReplay(bytes, summary.jsonl_replay);
}

fn fuzzParse(_: void, bytes: []const u8) !void {
    try checkRawParse(bytes);
    // Force a successful parse even when the entire fuzz input was garbage.
    const input = try std.mem.concat(alloc, u8, &.{ bytes, "\n{\"type\":\"result\",\"result\":\"sentinel\"}" });
    defer alloc.free(input);
    var s = try transcript.parse(alloc, input);
    defer s.deinit(alloc);
    try testing.expectEqualStrings("sentinel", s.final_text);
    try expectReplay(input, s.jsonl_replay);
}

test "transcript.parse fuzz arbitrary JSONL bytes and replay" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        negative,
        boundary,
        invalid_result,
        max_turns,
        boundary ++ "\n" ++ boundary,
        "{\"type\":\"result\",\"num_turns\":-1}",
        "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":-3,\"cache_read_input_tokens\":-2,\"cache_creation_input_tokens\":-1}}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{},null,{\"type\":\"text\",\"text\":\"\\uD83D\\uDE00\"}]}}\r\n\xff\x00\n",
        "{\"session_id\":\"abc\",\"type\":[]}\n{\"type\":\"assistant\",\"message\":null}\n{\"type\":\"result\",\"total_cost_usd\":1e309}",
        "{\"type\":\"result\",\"result\":\"first\",\"result\":\"duplicate\"}",
        "[[[]]]\r\n\n{\n\x00\r\r",
    } });
}

test "transcript.parse handles integer boundaries without losing representable totals" {
    var s = try transcript.parse(alloc, negative ++ "\n" ++ boundary ++ "\n" ++ invalid_result);
    defer s.deinit(alloc);
    try testing.expectEqual(transcript.Usage{
        .input_tokens = 1 << 63,
        .output_tokens = std.math.maxInt(u64),
    }, s.usage);
    try testing.expectEqual(@as(u32, 2), s.num_turns);
    try testing.expectEqual(@as(u64, 0), s.duration_api_ms);
    var turns = try transcript.parse(alloc, max_turns);
    defer turns.deinit(alloc);
    try testing.expectEqual(std.math.maxInt(u32), turns.num_turns);
}

fn garbage(w: *std.Io.Writer, random: std.Random) !void {
    if (random.boolean()) return;
    try w.writeAll("\r\n!"); // Every generated line is malformed regardless of its payload.
    var bytes: [16]u8 = undefined;
    const payload = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
    random.bytes(payload);
    std.mem.replaceScalar(u8, payload, '\n', 0);
    try w.writeAll(payload);
    try w.writeAll("\r\n");
}

const text_parts = [_]struct { json: []const u8, decoded: []const u8 }{
    .{ .json = "hello ", .decoded = "hello " },
    .{ .json = "雪", .decoded = "雪" },
    .{ .json = "\\n\\\"\\u2603", .decoded = "\n\"☃" },
    .{ .json = "", .decoded = "" },
};

fn writeAssistant(w: *std.Io.Writer, random: std.Random, last_text: *std.Io.Writer, totals: *transcript.Usage) !void {
    try w.writeAll("{\"type\":\"assistant\",\"session_id\":\"later\",\"message\":{\"content\":");
    switch (random.uintLessThan(u8, 6)) {
        0 => try w.writeAll("[]"),
        1 => try w.writeAll("null"),
        else => {
            const first = text_parts[random.uintLessThan(usize, text_parts.len)];
            const second = text_parts[random.uintLessThan(usize, text_parts.len)];
            try w.print("[{{\"type\":\"text\",\"text\":\"{s}\"}},", .{first.json});
            try w.writeAll("{\"type\":\"thinking\",\"text\":\"private\"},{\"type\":\"tool_use\",\"text\":\"tool\"},");
            try w.print("false,{{}},{{\"type\":4}},{{\"type\":\"text\",\"text\":1}},{{\"type\":\"text\",\"text\":\"{s}\"}}]", .{second.json});
            try last_text.writeAll(first.decoded);
            try last_text.writeAll(second.decoded);
        },
    }
    try w.writeAll(",\"usage\":{");
    inline for (std.meta.fields(transcript.Usage), 0..) |field, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("\"" ++ field.name ++ "\":");
        switch (random.uintLessThan(u8, 12)) {
            0 => try w.writeAll("-1"),
            1 => try w.writeAll("18446744073709551616"),
            2 => try w.writeAll("\"17\""),
            3 => try w.writeAll("4.5"),
            else => {
                const value = random.int(u40);
                try w.print("{d}", .{value});
                @field(totals, field.name) += value;
            },
        }
    }
    try w.writeAll("}}}");
}

test "transcript.parse 3000 generated transcripts agree with the event model" {
    var prng = std.Random.DefaultPrng.init(0x75a3_c001);
    const random = prng.random();
    for (0..3000) |_| {
        var raw: [96]u8 = undefined;
        const bytes = raw[0..random.uintLessThan(usize, raw.len + 1)];
        random.bytes(bytes);
        try checkRawParse(bytes);

        var storage: [4096]u8 = undefined;
        var jsonl = std.Io.Writer.fixed(&storage);
        var text_storage: [64]u8 = undefined;
        var last = std.Io.Writer.fixed(&text_storage);
        var totals: transcript.Usage = .{};
        try garbage(&jsonl, random);
        const id_field: []const u8 = if (random.boolean()) "sessionId" else "session_id";
        try jsonl.print("{{\"{s}\":\"first\",\"type\":null}}\n", .{id_field});
        const turns = random.intRangeAtMost(u32, 2, 5);
        for (0..turns) |_| {
            try garbage(&jsonl, random);
            last.end = 0;
            if (random.uintLessThan(u8, 8) == 0) {
                try jsonl.writeAll("{\"type\":\"assistant\"}");
            } else {
                try writeAssistant(&jsonl, random, &last, &totals);
            }
            try jsonl.writeAll(if (random.boolean()) "\n" else "\r\n");
        }
        try garbage(&jsonl, random);
        var cost: f64 = 0;
        if (random.boolean()) {
            const fractional = random.boolean();
            const dollars = random.int(u16);
            cost = @as(f64, @floatFromInt(dollars)) + @as(f64, if (fractional) 0.25 else 0);
            try jsonl.print("{{\"type\":\"result\",\"total_cost_usd\":{d}{s}", .{ dollars, if (fractional) ".25" else "" });
            if (random.boolean()) {
                try jsonl.writeAll(",\"result\":\"result override\"}");
                last.end = 0;
                try last.writeAll("result override");
            } else try jsonl.writeAll(",\"result\":[]}");
            if (random.boolean()) {
                try jsonl.writeByte('\n');
                try garbage(&jsonl, random);
            }
        }
        var actual = try transcript.parse(alloc, jsonl.buffered());
        defer actual.deinit(alloc);
        try testing.expectEqual(totals, actual.usage);
        try testing.expectEqualStrings(last.buffered(), actual.final_text);
        try testing.expectEqualStrings("first", actual.session_id);
        try testing.expectEqual(turns, actual.num_turns);
        try testing.expectEqual(cost, actual.total_cost_usd);
        try expectReplay(jsonl.buffered(), actual.jsonl_replay);
    }
}

fn parseWithAllocationFailures(a: std.mem.Allocator) !void {
    const bytes =
        \\{"sessionId":"s"}
        \\{torn
        \\{"type":"assistant","message":{"id":"one","model":"<synthetic>"}}
        \\{"type":"assistant","message":{"id":"two","content":[{"type":"text","text":"draft"}]}}
        \\{"type":"result","is_error":true,"errors":["done"],"subtype":"error_max_turns"}
    ;
    var s = try transcript.parse(a, bytes);
    defer s.deinit(a);
    try testing.expectEqualStrings("done", s.final_text);
}

test "transcript.parse releases partial results on allocation failure" {
    try testing.checkAllAllocationFailures(alloc, parseWithAllocationFailures, .{});
}

fn writeTurn(w: *std.Io.Writer, random: std.Random) !void {
    const turns = random.intRangeAtMost(u8, 1, 3);
    for (0..turns) |_| {
        try w.print("{{\"type\":\"assistant\",\"message\":{{\"content\":[{{\"type\":\"text\",\"text\":\"雪-{x}\"}}],", .{random.int(u32)});
        try w.print("\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_input_tokens\":{d},\"cache_creation_input_tokens\":{d}}}}}}}\n", .{ random.int(u16), random.int(u16), random.int(u16), random.int(u16) });
    }
    if (random.boolean()) try w.print("{{\"type\":\"result\",\"num_turns\":{d},\"result\":\"final-{x}\"}}\n", .{ random.int(u8), random.int(u32) });
}

fn expectTurn(expected: transcript.Summary, actual: transcript.Summary) !void {
    try testing.expectEqualStrings(expected.final_text, actual.final_text);
    try testing.expectEqual(expected.num_turns, actual.num_turns);
    try testing.expectEqual(expected.usage, actual.usage);
}

test "transcript.parseFileFromOffset isolates 1000 generated turn pairs at boundaries and torn records" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("offset.jsonl", .{});
    defer f.close();
    const path = try tmp.dir.realpathAlloc(alloc, "offset.jsonl");
    defer alloc.free(path);

    var prng = std.Random.DefaultPrng.init(0x75a3_c002);
    const random = prng.random();
    for (0..1000) |_| {
        var storage: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&storage);
        try writeTurn(&w, random);
        try f.setEndPos(0);
        try f.seekTo(0);
        try f.writeAll(w.buffered());
        const offset = try f.getEndPos();
        const prefix = w.buffered()[0 .. w.end - 1]; // Last byte was LF.
        const last_start = if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |n| n + 1 else 0;
        const torn = random.intRangeAtMost(usize, last_start + 1, prefix.len - 1);

        if (random.uintLessThan(u8, 10) == 0) {
            const unfinished = "{\"type\":\"user\"}\n{\"type\":\"assist";
            try f.writeAll(unfinished);
            try testing.expectError(error.NoAssistantMessage, transcript.parse(alloc, unfinished));
            try testing.expectError(error.NoAssistantMessage, transcript.parseFileFromOffset(alloc, path, offset));
            try f.setEndPos(offset);
            try f.seekTo(offset);
        }
        w.end = 0;
        try writeTurn(&w, random);
        try f.writeAll(w.buffered());
        var expected = try transcript.parse(alloc, w.buffered());
        defer expected.deinit(alloc);
        var actual = try transcript.parseFileFromOffset(alloc, path, offset);
        defer actual.deinit(alloc);
        try expectTurn(expected, actual);
        try testing.expectEqualStrings(expected.jsonl_replay, actual.jsonl_replay);
        var recovered = try transcript.parseFileFromOffset(alloc, path, torn);
        defer recovered.deinit(alloc);
        try expectTurn(expected, recovered);
        const size = try f.getEndPos();
        try testing.expectError(error.NoAssistantMessage, transcript.parseFileFromOffset(alloc, path, size));
        try testing.expectError(error.NoAssistantMessage, transcript.parseFileFromOffset(alloc, path, random.intRangeAtMost(u64, size + 1, std.math.maxInt(u64))));
    }
}

test "Tailer emits exactly the completed prefix after each append across 1000 fragmentations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("stream.jsonl", .{});
    defer f.close();
    const path = try tmp.dir.realpathAlloc(alloc, "stream.jsonl");
    defer alloc.free(path);
    var prng = std.Random.DefaultPrng.init(0x75a3_c003);
    const random = prng.random();

    for (0..1000) |i| {
        try f.setEndPos(0);
        try f.seekTo(0);
        if (random.boolean()) try f.writeAll("{\"type\":\"assistant\",\"result\":\"old\"}\n");
        var tailer = try Tailer.open(alloc, path);
        defer tailer.deinit();
        tailer.pos = try f.getEndPos();
        var data: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&data);
        for (0..random.intRangeAtMost(usize, 2, 6)) |_| {
            try w.print("{{\"text\":\"雪🌿-{x}\"}}{s}", .{ random.int(u16), if (random.boolean()) "\n" else "\r\n" });
        }
        if (random.boolean()) try w.writeAll("{\"text\":\"pending");
        const bytes = w.buffered();
        var output: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try testing.expectEqual(@as(usize, 0), try tailer.pump(&writer));
        var written: usize = 0;
        var complete: usize = 0;
        while (written < bytes.len) {
            const chunk: usize = switch (i % 16) {
                0 => 1,
                1 => 3,
                else => random.intRangeAtMost(usize, 1, 64),
            };
            const end = @min(written + chunk, bytes.len);
            const fragment = bytes[written..end];
            try f.writeAll(fragment);
            const count = std.mem.count(u8, fragment, "\n");
            try testing.expectEqual(count, try tailer.pump(&writer));
            if (std.mem.lastIndexOfScalar(u8, fragment, '\n')) |lf| complete = written + lf + 1;
            try testing.expectEqualSlices(u8, bytes[0..complete], writer.buffered());
            written = end;
        }
        try testing.expectEqual(@as(usize, 0), try tailer.pump(&writer));
        try testing.expectEqualSlices(u8, bytes[0..complete], writer.buffered());
    }
}

test "three assistant blocks share one turn and the latest usage snapshot" {
    const blocks =
        \\{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking"}],"usage":{"input_tokens":7,"output_tokens":2}}}
        \\{"type":"assistant","message":{"id":"m\u0031","content":[{"type":"text","text":"first "}],"usage":{"input_tokens":7,"output_tokens":5}}}
        \\{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"last"}],"usage":{"input_tokens":7,"output_tokens":5}}}
    ;
    var s = try transcript.parseWithOptions(alloc, blocks, .{ .keep_replay = false });
    defer s.deinit(alloc);
    try testing.expectEqual(1, s.num_turns);
    try testing.expectEqual(transcript.Usage{ .input_tokens = 7, .output_tokens = 5 }, s.usage);
    try testing.expectEqualStrings("first last", s.final_text);
    try testing.expectEqualStrings("", s.jsonl_replay);

    const later =
        \\{"type":"assistant","message":{"usage":{"input_tokens":3}}}
        \\{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":4}}}
        \\{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"updated"}],"usage":{"input_tokens":2}}}
        \\{"type":"result","usage":{"output_tokens":100}}
    ;
    var revisited = try transcript.parse(alloc, blocks ++ "\n" ++ later);
    defer revisited.deinit(alloc);
    try testing.expectEqual(3, revisited.num_turns);
    try testing.expectEqual(transcript.Usage{ .input_tokens = 9, .output_tokens = 100 }, revisited.usage);
    try testing.expectEqualStrings("updated", revisited.final_text);
}

test "each interactive API error marker sets the subtype and a later success clears it" {
    inline for (.{
        "{\"type\":\"assistant\",\"isApiErrorMessage\":true}",
        "{\"type\":\"assistant\",\"message\":{\"model\":\"<synthetic>\"}}",
    }) |line| {
        var failure = try transcript.parse(alloc, line);
        defer failure.deinit(alloc);
        try testing.expect(failure.is_error);
        try testing.expectEqualStrings("error_during_execution", failure.subtype.?);
        var recovered = try transcript.parse(alloc, line ++ "\n{\"type\":\"assistant\",\"message\":{\"id\":\"ok\"}}");
        defer recovered.deinit(alloc);
        try testing.expect(!recovered.is_error);
        try testing.expectEqual(null, recovered.subtype);
    }
}

test "result-only errors retain details, subtype and fallback usage" {
    const line =
        \\{"type":"result","is_error":true,"subtype":"error_max_turns","errors":["first","second"],"usage":{"output_tokens":12}}
    ;
    var failure = try transcript.parse(alloc, line);
    defer failure.deinit(alloc);
    try testing.expect(failure.is_error);
    try testing.expectEqualStrings("error_max_turns", failure.subtype.?);
    try testing.expectEqualStrings("first\nsecond", failure.final_text);
    try testing.expectEqual(12, failure.usage.output_tokens);
}

test "all usage counters saturate across distinct assistant messages" {
    const bytes =
        \\{"type":"assistant","message":{"id":"max","usage":{"input_tokens":18446744073709551615,"output_tokens":18446744073709551615,"cache_read_input_tokens":18446744073709551615,"cache_creation_input_tokens":18446744073709551615}}}
        \\{"type":"assistant","message":{"id":"one","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}
    ;
    var s = try transcript.parse(alloc, bytes);
    defer s.deinit(alloc);
    inline for (std.meta.fields(transcript.Usage)) |f| {
        try testing.expectEqual(std.math.maxInt(u64), @field(s.usage, f.name));
    }
}

test "Tailer skips malformed, non-object and upstream result lines including the final fragment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const valid = " {\"type\":\"assistant\",\"message\":{\"type\":\"result\"}}\r\n";
    const invalid = "garbage\n{\"bad\":}\n42\n[]\nnull\n{}{}\n";
    const result = "{\"type\":\"res\\u0075lt\"}";
    try tmp.dir.writeFile(.{ .sub_path = "live", .data = invalid ++ result ++ "\n" ++ valid ++ result });
    const path = try tmp.dir.realpathAlloc(alloc, "live");
    defer alloc.free(path);
    var tailer = try Tailer.open(alloc, path);
    defer tailer.deinit();
    var storage: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try testing.expectEqual(1, try tailer.pump(&out));
    try tailer.flushPartial(&out);
    try testing.expectEqualStrings(valid, out.buffered());
}

test "Tailer retries a failed buffer allocation at the same position and reports writer and flush failures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "{\"n\":1}\n";
    try tmp.dir.writeFile(.{ .sub_path = "live", .data = line });
    const path = try tmp.dir.realpathAlloc(alloc, "live");
    defer alloc.free(path);
    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var tailer = try Tailer.open(failing.allocator(), path);
    defer tailer.deinit();
    var broken = std.Io.Writer.failing;
    try testing.expectError(error.OutOfMemory, tailer.pump(&broken));
    try testing.expectEqual(0, tailer.pos);
    try testing.expectEqual(0, tailer.partial.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectError(error.WriteFailed, tailer.pump(&broken));
    try testing.expectEqual(line.len, tailer.pos);
    try testing.expectEqualStrings(line, tailer.partial.items);

    var storage: [line.len]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try testing.expectEqual(1, try tailer.pump(&out));
    try testing.expectEqualStrings(line, out.buffered());

    try tailer.reopenAt(path, 0);
    // The entire write fits in the buffer. Only flushing can fail.
    broken.buffer = &storage;
    try testing.expectError(error.WriteFailed, tailer.pump(&broken));
}

test "transcript file APIs reject invalid paths and reopenAt preserves state until the switch succeeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    for ([_][]const u8{ "name\x00suffix", dir, "/dev/null" }) |invalid| {
        try testing.expectError(error.InvalidTranscriptPath, transcript.parseFile(alloc, invalid));
        try testing.expectError(error.InvalidTranscriptPath, Tailer.open(alloc, invalid));
    }
    try tmp.dir.writeFile(.{ .sub_path = "old", .data = "{\"unfinished" });
    const old = try tmp.dir.realpathAlloc(alloc, "old");
    defer alloc.free(old);
    var tailer = try Tailer.open(alloc, old);
    defer tailer.deinit();
    var storage: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try testing.expectEqual(0, try tailer.pump(&out));
    try testing.expectError(error.InvalidTranscriptPath, tailer.reopenAt(dir, 0));
    try testing.expectEqualStrings("{\"unfinished", tailer.partial.items);
    try testing.expectEqual(tailer.partial.items.len, tailer.pos);

    const prefix = "{\"old\":true}\n";
    const fresh = "{\"type\":\"assistant\"}\n";
    try tmp.dir.writeFile(.{ .sub_path = "new", .data = prefix ++ fresh });
    const new = try tmp.dir.realpathAlloc(alloc, "new");
    defer alloc.free(new);
    try tailer.reopenAt(new, prefix.len);
    try testing.expectEqual(1, try tailer.pump(&out));
    try testing.expectEqualStrings(fresh, out.buffered());
    var s = try transcript.parseFileFromOffsetWithOptions(alloc, new, prefix.len, .{ .keep_replay = false });
    defer s.deinit(alloc);
    try testing.expectEqual(1, s.num_turns);
    try testing.expectEqualStrings("", s.jsonl_replay);
}

test "record UUIDs deduplicate text while partial usage and terminal overrides merge by field" {
    const block =
        \\{"uuid":"1","type":"assistant","message":{"id":"m","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":4,"cache_read_input_tokens":7}}}
    ;
    const tail =
        \\{"uuid":"2","type":"assistant","message":{"id":"m","content":[{"type":"text","text":"b"}],"usage":{"input_tokens":0,"output_tokens":5}}}
        \\{"type":"result","usage":{"output_tokens":6,"cache_read_input_tokens":0},"permission_denials":[{"tool_name":"Bash"}]}
    ;
    var result = try transcript.parse(alloc, block ++ "\n" ++ block ++ "\n" ++ tail);
    defer result.deinit(alloc);
    try testing.expectEqualStrings("ab", result.final_text);
    try testing.expectEqual(1, result.num_turns);
    try testing.expectEqual(transcript.Usage{ .input_tokens = 4, .output_tokens = 6 }, result.usage);
    try testing.expectEqualStrings("[{\"tool_name\":\"Bash\"}]", result.permission_denials.?);
}
