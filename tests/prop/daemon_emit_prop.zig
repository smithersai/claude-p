//! Result-envelope, stdin frame, and busy-turn watchdog properties.
const std = @import("std");
const lib = @import("claude_p");
const daemon = lib.daemon;
const emit = lib.emit;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Summary = lib.transcript.Summary;
const Json = std.json.Value;

const emit_seed = 0xe117_2500;
const frame_seed = 0xf2a3_3000;
const watchdog_seed = 0xc10c_5000;

// Reuse backing pages in deterministic loops. Count frees before each reset so
// the arena cannot hide a leaked result or an undeinitialized JSON parser.
fn finishTrial(arena: *std.heap.ArenaAllocator, counter: *const testing.FailingAllocator) !void {
    try testing.expectEqual(counter.allocations, counter.deallocations);
    try testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    _ = arena.reset(.retain_capacity);
}

// Uniform scalar values alone almost never exercise JSON escaping.
fn randomText(random: std.Random, buf: *[64]u8) []u8 {
    var len: usize = 0;
    for (0..random.uintLessThan(usize, 17)) |_| {
        var scalar: u21 = switch (random.uintLessThan(u8, 6)) {
            0 => random.int(u5),
            1 => "\"\\\r\n\t"[random.uintLessThan(usize, 5)],
            2 => random.intRangeAtMost(u21, 32, 126),
            3 => random.intRangeAtMost(u21, 0x1f600, 0x1f64f),
            4 => random.intRangeAtMost(u21, 0x80, 0x7ff),
            else => random.intRangeAtMost(u21, 0, 0x10ffff),
        };
        if (scalar >= 0xd800 and scalar <= 0xdfff) scalar = 0xfffd;
        len += std.unicode.utf8Encode(scalar, buf[len..]) catch unreachable;
    }
    return buf[0..len];
}

fn unsigned(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => std.math.maxInt(u64),
        2 => 1 << 63,
        else => random.int(u64),
    };
}

fn finiteCost(bits: u64) f64 {
    const cost: f64 = @bitCast(bits);
    return if (std.math.isFinite(cost)) cost else std.math.floatMax(f64);
}

fn expectNumber(value: Json, expected: u64) !void {
    // Dynamic JSON stores integer literals above maxInt(i64) as number_string.
    const actual: u64 = switch (value) {
        .integer => |n| std.math.cast(u64, n) orelse return error.ExpectedUnsigned,
        .number_string => |s| try std.fmt.parseUnsigned(u64, s, 10),
        else => return error.ExpectedUnsigned,
    };
    try testing.expectEqual(expected, actual);
}

fn field(obj: Json, name: []const u8) !Json {
    if (obj != .object) return error.ExpectedObject;
    return obj.object.get(name) orelse error.MissingResultField;
}

fn expectString(obj: Json, name: []const u8, expected: []const u8) !void {
    const value = try field(obj, name);
    try testing.expect(value == .string);
    try testing.expectEqualStrings(expected, value.string);
}

const ErrorFields = struct { subtype: []const u8, reason: []const u8 };

fn checkResult(alloc: Allocator, line: []const u8, env: emit.ResultEnvelope, failure: ?ErrorFields) !void {
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(std.mem.indexOfScalar(u8, line, '\r') == null);
    const parsed = try std.json.parseFromSlice(Json, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value;
    const s = env.summary;
    try expectString(obj, "type", "result");
    try expectString(obj, "session_id", s.session_id);
    try expectString(obj, "result", if (failure == null) s.final_text else "");
    const is_error = try field(obj, "is_error");
    try testing.expect(is_error == .bool);
    if (failure) |e| {
        try expectString(obj, "subtype", e.subtype);
        try expectString(obj, "error", e.reason);
        try testing.expectEqual(!std.mem.eql(u8, e.subtype, "interrupted"), is_error.bool);
    } else {
        try expectString(obj, "subtype", s.subtype orelse if (s.is_error) "error_during_execution" else "success");
        try testing.expectEqual(s.is_error, is_error.bool);
    }
    try expectNumber(try field(obj, "duration_ms"), env.duration_ms);
    try expectNumber(try field(obj, "duration_api_ms"), if (failure == null) s.duration_api_ms else 0);
    try expectNumber(try field(obj, "num_turns"), if (failure == null) s.num_turns else 0);
    const usage = try field(obj, "usage");
    inline for (std.meta.fields(lib.transcript.Usage)) |f| {
        try expectNumber(try field(usage, f.name), if (failure == null) @field(s.usage, f.name) else 0);
    }
    const cost = switch (try field(obj, "total_cost_usd")) {
        .integer => |n| @as(f64, @floatFromInt(n)),
        .float => |n| n,
        .number_string => |literal| try std.fmt.parseFloat(f64, literal),
        else => return error.ExpectedNumericCost,
    };
    const expected_cost: f64 = if (failure == null) s.total_cost_usd else 0;
    try testing.expectEqual(@as(u64, @bitCast(expected_cost)), @as(u64, @bitCast(cost)));
    const denials = try field(obj, "permission_denials");
    try testing.expect(denials == .array and denials.array.items.len == 0);
}

const replay = "{\"type\":\"system\"}\n{\"type\":\"assistant\"}";

fn checkEmit(alloc: Allocator, input: emit.ResultEnvelope, failure: ErrorFields, replay_mode: u8) !void {
    var replay_bytes = (replay ++ "\n").*;
    var summary = input.summary.*;
    summary.jsonl_replay = switch (replay_mode % 3) {
        0 => replay_bytes[0..0],
        1 => replay_bytes[0..replay.len],
        else => &replay_bytes,
    };
    const env: emit.ResultEnvelope = .{ .summary = &summary, .duration_ms = input.duration_ms };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var dispatched: std.Io.Writer.Allocating = .init(alloc);
    defer dispatched.deinit();
    inline for ([_]emit.OutputFormat{ .text, .json, .stream_json }) |fmt| {
        out.clearRetainingCapacity();
        dispatched.clearRetainingCapacity();
        switch (fmt) {
            .text => {
                try emit.emitText(&out.writer, env);
                const bytes = out.written();
                const text = env.summary.final_text;
                const extra: usize = if (std.mem.endsWith(u8, text, "\n")) 0 else 1;
                try testing.expectEqual(text.len + extra, bytes.len);
                try testing.expectEqualStrings(text, bytes[0..text.len]);
                try testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
            },
            .json => {
                try emit.emitJson(alloc, &out.writer, env);
                try checkResult(alloc, out.written(), env, null);
            },
            .stream_json => {
                try emit.emitStreamJson(alloc, &out.writer, env);
                const prefix = if (summary.jsonl_replay.len > 0) replay ++ "\n" else "";
                try testing.expect(std.mem.startsWith(u8, out.written(), prefix));
                try checkResult(alloc, out.written()[prefix.len..], env, null);
            },
        }
        try emit.emit(alloc, &dispatched.writer, fmt, env);
        try testing.expectEqualStrings(out.written(), dispatched.written());
    }
    out.clearRetainingCapacity();
    try emit.emitErrorResult(alloc, &out.writer, failure.subtype, failure.reason, env.summary.session_id, env.duration_ms);
    try checkResult(alloc, out.written(), env, failure);
}

test "result envelopes round-trip 2500 random summaries" {
    var prng = std.Random.DefaultPrng.init(emit_seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counter = testing.FailingAllocator.init(arena.allocator(), .{});
    const alloc = counter.allocator();
    const costs = [_]f64{ 0.0, -0.0, std.math.floatTrueMin(f64), std.math.floatMin(f64), std.math.floatMax(f64), 0.1 };
    for (0..2500) |i| {
        var strings: [5][64]u8 = undefined;
        const summary: Summary = .{
            .final_text = randomText(r, &strings[0]),
            .session_id = randomText(r, &strings[1]),
            .is_error = r.boolean(),
            .subtype = if (i % 2 == 0) randomText(r, &strings[4]) else null,
            .num_turns = if (i % 11 == 0) std.math.maxInt(u32) else r.int(u32),
            .total_cost_usd = if (i % 2 == 0) costs[(i / 2) % costs.len] else finiteCost(r.int(u64)),
            .duration_api_ms = unsigned(r),
            .usage = .{ .input_tokens = unsigned(r), .output_tokens = unsigned(r), .cache_read_input_tokens = unsigned(r), .cache_creation_input_tokens = unsigned(r) },
            .jsonl_replay = &.{},
        };
        try checkEmit(alloc, .{ .summary = &summary, .duration_ms = unsigned(r) }, .{
            .subtype = if (i % 5 == 0) "interrupted" else randomText(r, &strings[2]),
            .reason = randomText(r, &strings[3]),
        }, @intCast(i % 3));
        try finishTrial(&arena, &counter);
    }
}

// 0xff is outside UTF-8, so all valid strings (including NUL) survive splitting.
// Repair malformed fields independently to keep the other fuzz mutations useful.
fn fuzzText(alloc: Allocator, raw: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return alloc.dupe(u8, raw);
    const bytes = try alloc.dupe(u8, raw);
    for (bytes) |*b| if (b.* >= 0x80) {
        b.* &= 0x7f;
    };
    return bytes;
}

fn fuzzEmit(_: void, input: []const u8) !void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    const alloc = testing.allocator;
    var fields = std.mem.splitScalar(u8, input, 0xff);
    var text = [_][]u8{&.{}} ** 4;
    defer for (text) |s| alloc.free(s);
    for (&text) |*s| s.* = try fuzzText(alloc, fields.next() orelse "");
    // A mutable little-endian trailer gives the fuzzer direct access to counters and float bits.
    var numbers = [_]u8{0} ** 64;
    const trailer = fields.rest();
    const n = @min(numbers.len, trailer.len);
    @memcpy(numbers[0..n], trailer[0..n]);
    const summary: Summary = .{
        .final_text = text[0],
        .session_id = text[1],
        .num_turns = std.mem.readInt(u32, numbers[56..60], .little),
        .is_error = numbers[60] & 1 != 0,
        .total_cost_usd = finiteCost(std.mem.readInt(u64, numbers[0..8], .little)),
        .duration_api_ms = std.mem.readInt(u64, numbers[8..16], .little),
        .usage = .{
            .input_tokens = std.mem.readInt(u64, numbers[16..24], .little),
            .output_tokens = std.mem.readInt(u64, numbers[24..32], .little),
            .cache_read_input_tokens = std.mem.readInt(u64, numbers[32..40], .little),
            .cache_creation_input_tokens = std.mem.readInt(u64, numbers[40..48], .little),
        },
        .jsonl_replay = &.{},
    };
    try checkEmit(alloc, .{ .summary = &summary, .duration_ms = std.mem.readInt(u64, numbers[48..56], .little) }, .{ .subtype = text[2], .reason = text[3] }, numbers[61]);
}

test "fuzz result emitters and format dispatch" {
    try testing.fuzz({}, fuzzEmit, .{ .corpus = &.{
        "\n\n\n\n",
        "👩‍💻\x00\r\n\xffid\\\"\xffinterrupted\xff\x01\t\xff" ++ "\xff" ** 64,
        "line\n\n\xff\xfferror\xff\x00\xff\x01",
        "\xc0\x80\xff🛰️\xffInterrupted\xff\r\n",
    } });
}

const FrameKind = enum { unknown, ignored, ping, interrupt, user };

fn checkFrame(alloc: Allocator, line: []const u8, kind: FrameKind, a: []const u8, b: []const u8) !void {
    const ping = daemon.isPingFrame(alloc, line);
    const interrupt = daemon.isInterruptFrame(alloc, line);
    const prompt = try daemon.parseUserMessageContent(alloc, line);
    defer if (prompt) |s| alloc.free(s);
    try testing.expect(!(ping and interrupt));
    if (ping or interrupt) try testing.expect(prompt == null);
    if (kind == .unknown) return;

    try testing.expectEqual(kind == .ping, ping);
    try testing.expectEqual(kind == .interrupt, interrupt);
    if (kind == .user) {
        const s = prompt orelse return error.MissingUserContent;
        try testing.expectEqual(a.len + b.len, s.len);
        try testing.expectEqualStrings(a, s[0..a.len]);
        try testing.expectEqualStrings(b, s[a.len..]);
    } else try testing.expect(prompt == null);
}

fn checkUserFrames(alloc: Allocator, a: []const u8, b: []const u8) !void {
    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    inline for (.{
        .{ .type = "user", .message = .{ .role = "user", .content = a } },
        .{ .type = "user", .content = a },
        .{ .type = "user", .content = "fallback", .message = .{ .content = .{
            .{ .type = "text", .text = a },
            .{ .type = "image", .text = "skip", .source = .{ .type = "text", .text = a } },
            .{ .type = "text", .text = b },
        } } },
        .{ .type = "user", .message = .{ .content = .{
            .{ .type = "text", .text = a },
            .{ .type = "text", .text = b },
        } } },
    }, 0..) |message, i| {
        frame.clearRetainingCapacity();
        try std.json.Stringify.value(message, .{}, &frame.writer);
        try checkFrame(alloc, frame.written(), if (i == 2) .ignored else .user, a, if (i == 3) b else "");
    }
}

test "stdin classifier and content extraction over 3000 random frames" {
    var prng = std.Random.DefaultPrng.init(frame_seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counter = testing.FailingAllocator.init(arena.allocator(), .{});
    const alloc = counter.allocator();
    for (0..3000) |i| {
        var strings: [2][64]u8 = undefined;
        const a = randomText(r, &strings[0]);
        const b = randomText(r, &strings[1]);
        try checkUserFrames(alloc, a, b);

        var bytes: [96]u8 = undefined;
        const raw = bytes[0..r.uintAtMost(usize, bytes.len)];
        r.bytes(raw);
        try checkFrame(alloc, raw, .unknown, "", "");

        const kind: FrameKind = if (i % 2 == 0) .ping else .interrupt;
        var buf: [768]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try std.json.Stringify.value(.{ .message = .{ .type = "user", .content = b }, .type = @tagName(kind), .content = a }, .{}, &w);
        try checkFrame(alloc, w.buffered(), kind, "", "");
        // Every proper prefix of this object is incomplete, regardless of UTF-8 boundaries.
        const cut = r.uintLessThan(usize, w.end);
        try checkFrame(alloc, w.buffered()[0..cut], .ignored, "", "");
        try finishTrial(&arena, &counter);
    }
}

fn fuzzFrames(_: void, input: []const u8) !void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    try checkFrame(testing.allocator, input, .unknown, "", "");
    var parts = std.mem.splitScalar(u8, input, 0xff);
    const a = try fuzzText(testing.allocator, parts.next().?);
    defer testing.allocator.free(a);
    const b = try fuzzText(testing.allocator, parts.rest());
    defer testing.allocator.free(b);
    try checkUserFrames(testing.allocator, a, b);
}

test "fuzz stdin frame exclusion and structured content" {
    try testing.fuzz({}, fuzzFrames, .{ .corpus = &.{
        "\x00\xff\xfe\x00",
        "🧑🏽‍🚀\xff\r\n\t\"\\",
        "{\"type\":\"ping\",\"content\":\"x\"}",
        "{\"type\":\"interrupt\",\"message\":{\"content\":\"x\"}}",
        "{\"type\":\"p\\u0069ng\"}",
        "{\"type\":\"ping\",\"type\":\"interrupt\"}",
        "{\"type\":\"user\",\"content\":\"\\ud83d\\ude00\"}",
        "{\"type\":\"user\",\"content\":\"\\ud800\"}",
        "{\"type\":\"user\",\"message\":{\"content\":[null,3,{}, {\"type\":false},{\"type\":\"text\"},{\"type\":\"text\",\"text\":[]}]}}",
        "[]" ++ "{}",
        "[" ** 100 ++ "0" ++ "]" ** 100,
        "{\"message\":[[[{\"type\":\"interrupt\"",
    } });
}

fn allocatedBlocks(alloc: Allocator) !void {
    const frame =
        \\{"type":"user","message":{"content":[{"type":"text","text":"line\n"},{"type":"text","text":"two longer than initial capacity"}]}}
    ;
    const prompt = (try daemon.parseUserMessageContent(alloc, frame)) orelse return error.MissingUserContent;
    defer alloc.free(prompt);
    try testing.expectEqualStrings("line\ntwo longer than initial capacity", prompt);
}

test "parser releases partial JSON and text blocks on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocatedBlocks, .{});
}

fn checkWatchdogs(expected: bool, state: daemon.State, last: i64, now: i128, timeout: u64) !void {
    inline for (.{ daemon.idleTimedOut, daemon.transcriptStalled }) |predicate| {
        try testing.expectEqual(expected, predicate(state, last, now, timeout));
    }
}

test "busy watchdog gates, skew, and strict millisecond boundaries" {
    const ms = std.time.ns_per_ms;
    var prng = std.Random.DefaultPrng.init(watchdog_seed);
    const r = prng.random();
    for (0..5500) |_| {
        const timestamp = r.int(i64);
        const last = if (timestamp == 0) 1 else timestamp;
        const timeout = @max(unsigned(r), 1);
        const now = r.int(i128);
        try checkWatchdogs(false, .waiting_for_ready, last, now, timeout);
        try checkWatchdogs(false, .idle, last, now, timeout);
        try checkWatchdogs(false, .busy, 0, now, timeout);
        try checkWatchdogs(false, .busy, last, now, 0);
        try checkWatchdogs(false, .busy, last, @as(i128, last) - 1 - r.int(u64), timeout);

        const boundary = @as(i128, last) + @as(i128, timeout) * ms;
        try checkWatchdogs(false, .busy, last, boundary, timeout);
        try checkWatchdogs(false, .busy, last, boundary + r.uintLessThan(u32, ms), timeout);
        try checkWatchdogs(false, .busy, last, boundary + ms - 1, timeout);
        try checkWatchdogs(true, .busy, last, boundary + ms, timeout);
        // Widen before subtracting so the independent oracle spans the entire clock domain.
        const delta: i256 = @as(i256, now) - last;
        try checkWatchdogs(@divTrunc(delta, ms) > timeout, .busy, last, now, timeout);
    }
    try checkWatchdogs(false, .busy, 1, std.math.minInt(i128), 1);
    try checkWatchdogs(true, .busy, -1, std.math.maxInt(i128), std.math.maxInt(u64));
    try checkWatchdogs(false, .busy, 1, 1, std.math.maxInt(u64));
}

fn fuzzWatchdogs(_: void, input: []const u8) !void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var bytes = [_]u8{0} ** 32;
    const n = @min(input.len, bytes.len);
    @memcpy(bytes[0..n], input[0..n]);
    const last = std.mem.readInt(i64, bytes[0..8], .little);
    const timeout = std.mem.readInt(u64, bytes[8..16], .little);
    const now = std.mem.readInt(i128, bytes[16..32], .little);
    const delta = @as(i256, now) - last;
    try checkWatchdogs(last != 0 and timeout != 0 and @divTrunc(delta, std.time.ns_per_ms) > timeout, .busy, last, now, timeout);
    try checkWatchdogs(false, .idle, last, now, timeout);
    try checkWatchdogs(false, .waiting_for_ready, last, now, timeout);
}

test "fuzz signed watchdog clocks and unsigned thresholds" {
    try testing.fuzz({}, fuzzWatchdogs, .{ .corpus = &.{
        "\xff" ** 32,
        "\x01" ++ "\x00" ** 7 ++ "\xff" ** 8 ++ "\x00" ** 15 ++ "\x80",
        "\xff" ** 31 ++ "\x7f",
        "\x01" ++ "\x00" ** 7 ++ "\x01" ++ "\x00" ** 7 ++ "\x81\x84\x1e",
    } });
}

test "replayed stream has one terminal result with upstream error details" {
    const assistant = "{\"type\":\"assistant\"}";
    const bytes = "garbage\n" ++ assistant ++ "\n[1]\n" ++
        "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"errors\":[\"max turns\"],\"usage\":{\"output_tokens\":2}}";
    var s = try lib.transcript.parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const env: emit.ResultEnvelope = .{ .summary = &s, .duration_ms = 0 };
    try emit.emitStreamJson(testing.allocator, &out.writer, env);
    const prefix = assistant ++ "\n";
    try testing.expect(std.mem.startsWith(u8, out.written(), prefix));
    try checkResult(testing.allocator, out.written()[prefix.len..], env, null);
    try testing.expectEqualStrings("error_max_turns", s.subtype.?);
    try testing.expectEqualStrings("max turns", s.final_text);
    try testing.expectEqual(2, s.usage.output_tokens);
}

test "blank stdin records and malformed JSON never emit a result" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, "\n\r\n   \t\r\n", '\n');
    while (lines.next()) |line| try testing.expect(try daemon.readInputFrame(testing.allocator, &out.writer, line) == null);
    try testing.expectEqual(0, out.written().len);
    try testing.expect(try daemon.readInputFrame(testing.allocator, &out.writer, "{") == null);
    try testing.expectEqualStrings("{\"type\":\"error\",\"error\":\"invalid_json\"}\n", out.written());
}
