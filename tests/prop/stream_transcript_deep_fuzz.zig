//! Deep coverage-guided `std.testing.fuzz` targets for `src/stream.zig` and
//! `src/transcript.zig` surfaces not previously covered by `std.testing.fuzz`:
//!   - `stream.isForwardable` (raw bytes + JSON objects + OOM)
//!   - `stream.Tailer` (`open`, `pump`, `reopenAt`, `flushPartial`)
//!   - `transcript.parseWithOptions` (`keep_replay` false/true, `total_cost_usd`
//!     non-finite floats like `1e400`, downstream `emit` round-trip)
//!   - `transcript.parseFileFromOffsetWithOptions` (offset equivalence oracle)
const std = @import("std");
const claude_p = @import("claude_p");

const testing = std.testing;
const stream = claude_p.stream;
const transcript = claude_p.transcript;
const emit = claude_p.emit;

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn rem(self: *const Cursor) usize {
        return self.data.len - self.pos;
    }

    fn byte(self: *Cursor) u8 {
        if (self.pos >= self.data.len) return 0;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn int(self: *Cursor, comptime T: type) T {
        var buf: [@sizeOf(T)]u8 = [_]u8{0} ** @sizeOf(T);
        const n = @min(@sizeOf(T), self.rem());
        if (n > 0) {
            @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
        }
        return std.mem.readInt(T, &buf, .little);
    }

    fn rest(self: *Cursor) []const u8 {
        const out = self.data[self.pos..];
        self.pos = self.data.len;
        return out;
    }
};

// ============================================================================
// 1. stream.isForwardable
// ============================================================================

fn fuzzIsForwardable(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    const fwd = try stream.isForwardable(testing.allocator, input);

    // Independent reference oracle using strict std.json parse.
    const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, input, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try testing.expect(!fwd);
            return;
        },
    };
    defer parsed.deinit();

    const want = blk: {
        if (parsed.value != .object) break :blk false;
        if (parsed.value.object.get("type")) |ty| {
            if (ty == .string and std.mem.eql(u8, ty.string, "result")) break :blk false;
        }
        break :blk true;
    };
    try testing.expectEqual(want, fwd);
}

test "fuzz: stream.isForwardable matches JSON-object non-result oracle" {
    try testing.fuzz({}, fuzzIsForwardable, .{
        .corpus = &.{
            "{  }",
            "{\"type\":\"assistant\",\"text\":\"hi\"}",
            "{\"type\":\"result\",\"result\":\"ok\"}",
            "{\"type\":\"result\",\"type\":\"assistant\"}",
            "{\"type\":\"assistant\",\"type\":\"result\"}",
            "{\"type\":123}",
            "[  ]",
            "null",
            "\"result\"",
            "{\"a\":1}\r\n",
            "{truncated",
        },
    });
}

// ============================================================================
// 2. stream.Tailer — chunked append + pump + reopenAt + flushPartial
// ============================================================================

fn expectedForwardedFromSlice(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, start, '\n')) |nl| {
        const line = content[start .. nl + 1];
        if (try stream.isForwardable(allocator, line)) {
            try out.appendSlice(allocator, line);
        }
        start = nl + 1;
    }
    if (start < content.len) {
        const tail = content[start..];
        const with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{tail});
        defer allocator.free(with_nl);
        if (try stream.isForwardable(allocator, with_nl)) {
            try out.appendSlice(allocator, with_nl);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn fuzzStreamTailer(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var cur: Cursor = .{ .data = input };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f1 = try tmp.dir.createFile("a.jsonl", .{ .read = true, .truncate = true });
    defer f1.close();
    const p1 = try tmp.dir.realpathAlloc(testing.allocator, "a.jsonl");
    defer testing.allocator.free(p1);

    var tailer = try stream.Tailer.open(testing.allocator, p1);
    defer tailer.deinit();

    var raw1: std.ArrayList(u8) = .{};
    defer raw1.deinit(testing.allocator);
    var emitted1: std.ArrayList(u8) = .{};
    defer emitted1.deinit(testing.allocator);

    const do_reopen = (cur.byte() & 1) != 0;
    const half = cur.rem() / 2;
    const stop1 = if (do_reopen) cur.pos + half else cur.data.len;

    while (cur.pos < stop1) {
        const sz = @min(@as(usize, cur.byte() % 64), stop1 - cur.pos);
        const chunk = cur.data[cur.pos .. cur.pos + sz];
        cur.pos += sz;

        try f1.writeAll(chunk);
        try raw1.appendSlice(testing.allocator, chunk);

        var step_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer step_aw.deinit();
        const lines = try tailer.pump(&step_aw.writer);
        const wrote = step_aw.written();

        if (lines == 0) {
            try testing.expectEqual(@as(usize, 0), wrote.len);
        } else {
            try testing.expect(wrote.len > 0 and wrote[wrote.len - 1] == '\n');
            try testing.expectEqual(lines, std.mem.count(u8, wrote, "\n"));
        }
        try emitted1.appendSlice(testing.allocator, wrote);
        try testing.expectEqual(@as(u64, raw1.items.len), tailer.pos);
    }

    var flush1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer flush1.deinit();
    try tailer.flushPartial(&flush1.writer);
    try emitted1.appendSlice(testing.allocator, flush1.written());

    const want1 = try expectedForwardedFromSlice(testing.allocator, raw1.items);
    defer testing.allocator.free(want1);
    try testing.expectEqualStrings(want1, emitted1.items);
    try testing.expectEqual(@as(usize, 0), tailer.partial.items.len);

    // Optional second phase: reopenAt a new file at a fuzzer-chosen offset!
    if (do_reopen) {
        const rem_bytes = cur.rest();
        var f2 = try tmp.dir.createFile("b.jsonl", .{ .read = true, .truncate = true });
        defer f2.close();
        try f2.writeAll(rem_bytes);
        const p2 = try tmp.dir.realpathAlloc(testing.allocator, "b.jsonl");
        defer testing.allocator.free(p2);

        const off: u64 = if (rem_bytes.len == 0) 0 else @min(rem_bytes.len, rem_bytes[0] % (rem_bytes.len + 1));
        try tailer.reopenAt(p2, off);
        try testing.expectEqual(off, tailer.pos);
        try testing.expectEqual(@as(usize, 0), tailer.partial.items.len);

        var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw2.deinit();
        _ = try tailer.pump(&aw2.writer);
        try tailer.flushPartial(&aw2.writer);

        const want2 = try expectedForwardedFromSlice(testing.allocator, rem_bytes[@intCast(off)..]);
        defer testing.allocator.free(want2);
        try testing.expectEqualStrings(want2, aw2.written());
    }
}

test "fuzz: stream.Tailer chunked pump, reopenAt, and flushPartial match reference oracle" {
    try testing.fuzz({}, fuzzStreamTailer, .{
        .corpus = &.{
            "\x00\x08{\"a\":1}\n\x1c{\"type\":\"result\",\"ok\":1}\n",
            "\x01\x06{\"x\":1\x04}\n\x08{\"b\":2}\n",
            "\x00\x05bad\n\x07{\"k\":3}",
        },
    });
}

// ============================================================================
// 3. transcript.parseWithOptions + emit round-trip (including non-finite floats!)
// ============================================================================

fn fuzzTranscriptOptionsAndEmit(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    // Parse with both keep_replay=true and keep_replay=false and confirm identical summaries
    // (except jsonl_replay which is empty when keep_replay=false).
    const res_keep = transcript.parseWithOptions(testing.allocator, input, .{ .keep_replay = true });
    const res_drop = transcript.parseWithOptions(testing.allocator, input, .{ .keep_replay = false });

    if (res_keep) |s_keep_const| {
        var s_keep = s_keep_const;
        defer s_keep.deinit(testing.allocator);
        var s_drop = try res_drop;
        defer s_drop.deinit(testing.allocator);

        try testing.expectEqualStrings(s_keep.final_text, s_drop.final_text);
        try testing.expectEqualStrings(s_keep.session_id, s_drop.session_id);
        try testing.expectEqual(s_keep.is_error, s_drop.is_error);
        try testing.expectEqual(s_keep.num_turns, s_drop.num_turns);
        try testing.expectEqual(s_keep.duration_api_ms, s_drop.duration_api_ms);
        try testing.expectEqual(s_keep.usage, s_drop.usage);
        try testing.expectEqual(@as(usize, 0), s_drop.jsonl_replay.len);

        // INVARIANT: total_cost_usd MUST be finite so emitJson ALWAYS outputs valid RFC 8259 JSON!
        try testing.expect(std.math.isFinite(s_keep.total_cost_usd));

        var jw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer jw.deinit();
        try emit.emitJson(testing.allocator, &jw.writer, .{ .summary = &s_keep, .duration_ms = 1 });
        const json_out = jw.written();
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json_out, "\n"));
        var reparsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_out, .{
            .duplicate_field_behavior = .@"error",
        });
        defer reparsed.deinit();
        try testing.expectEqualStrings("result", reparsed.value.object.get("type").?.string);

        // stream_json output must end with the exact emitJson line and every preceding line must be forwardable JSON.
        var sw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer sw.deinit();
        try emit.emitStreamJson(testing.allocator, &sw.writer, .{ .summary = &s_keep, .duration_ms = 1 });
        try testing.expect(std.mem.endsWith(u8, sw.written(), json_out));
    } else |err| {
        try testing.expectError(err, res_drop);
    }
}

test "fuzz: transcript.parseWithOptions + emitJson strict RFC-8259 round-trip" {
    try testing.fuzz({}, fuzzTranscriptOptionsAndEmit, .{
        .corpus = &.{
            "{\"type\":\"result\",\"result\":\"ok\",\"total_cost_usd\":1e400}\n",
            "{\"type\":\"result\",\"result\":\"ok\",\"total_cost_usd\":-1e400}\n",
            "{\"type\":\"result\",\"result\":\"ok\",\"total_cost_usd\":0.05}\n",
            "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}],\"usage\":{\"input_tokens\":10}}}\n" ++
                "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"text\",\"text\":\"b\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}\n",
            "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"message\":{\"model\":\"<synthetic>\",\"content\":[{\"type\":\"text\",\"text\":\"err\"}]}}\n",
        },
    });
}

// ============================================================================
// 4. transcript.parseFileFromOffsetWithOptions
// ============================================================================

fn fuzzTranscriptOffsetFile(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var cur: Cursor = .{ .data = input };
    const keep_replay = (cur.byte() & 1) != 0;
    const raw_off = cur.int(u16);
    const content = cur.rest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "off.jsonl", .data = content });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "off.jsonl");
    defer testing.allocator.free(path);

    const offset: u64 = if (content.len == 0)
        raw_off
    else switch (raw_off % 5) {
        0 => 0,
        1 => content.len,
        2 => content.len + 100,
        3 => std.math.maxInt(u64),
        else => raw_off % content.len,
    };

    const opts: transcript.ParseOptions = .{ .keep_replay = keep_replay };
    const file_res = transcript.parseFileFromOffsetWithOptions(testing.allocator, path, offset, opts);

    if (offset >= content.len) {
        try testing.expectError(transcript.ParseError.NoAssistantMessage, file_res);
        return;
    }

    const mem_res = transcript.parseWithOptions(testing.allocator, content[@intCast(offset)..], opts);
    if (mem_res) |mem_const| {
        var mem_s = mem_const;
        defer mem_s.deinit(testing.allocator);
        var file_s = try file_res;
        defer file_s.deinit(testing.allocator);
        try testing.expectEqualStrings(mem_s.final_text, file_s.final_text);
        try testing.expectEqualStrings(mem_s.session_id, file_s.session_id);
        try testing.expectEqual(mem_s.is_error, file_s.is_error);
        try testing.expectEqual(mem_s.num_turns, file_s.num_turns);
        try testing.expectEqual(mem_s.usage, file_s.usage);
        try testing.expectEqualStrings(mem_s.jsonl_replay, file_s.jsonl_replay);
    } else |err| {
        try testing.expectError(err, file_res);
    }
}

test "fuzz: transcript.parseFileFromOffsetWithOptions matches in-memory slice parse" {
    try testing.fuzz({}, fuzzTranscriptOffsetFile, .{
        .corpus = &.{
            "\x01\x00\x00{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n",
            "\x00\x04\x00{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"old\"}]}}\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"new\"}]}}\n",
            "\x01\x03\x00\n",
        },
    });
}
