//! Property-based and fuzz tests for the pure helpers in `src/driver.zig`:
//! `PasteChunker`, `writeBracketedPasteTo`, `typePromptTo`,
//! `isPromptTruncated`, `shouldStripChildEnv`, `buildChildEnvFromMap`,
//! `shellQuoteArgv`, and `buildArgv`.
//!
//! Every property is checked against a model written independently in this
//! file, never against the implementation's own helpers.
const std = @import("std");
const testing = std.testing;
const driver = @import("claude_p").driver;

const Random = std.Random;
const Bytes = std.ArrayList(u8);

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";
const chunk_max: usize = 512;

// ===========================================================================
// Generators
// ===========================================================================

fn appendCodepoint(a: std.mem.Allocator, out: *Bytes, r: Random) !void {
    const cp: u21 = switch (r.uintLessThan(u8, 6)) {
        0 => r.intRangeAtMost(u21, 0x20, 0x7E), // ASCII
        1 => r.intRangeAtMost(u21, 0x80, 0x7FF), // 2-byte
        2 => r.intRangeAtMost(u21, 0x4E00, 0x9FFF), // 3-byte CJK
        3 => r.intRangeAtMost(u21, 0x1F300, 0x1FAFF), // 4-byte emoji
        4 => r.intRangeAtMost(u21, 0x800, 0xD7FF), // 3-byte, below surrogates
        else => r.intRangeAtMost(u21, 0x10000, 0x10FFFF), // 4-byte
    };
    var b: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &b);
    try out.appendSlice(a, b[0..n]);
}

const paste_fragments = [_][]const u8{
    paste_end,
    paste_end ++ "~",
    "\x1b[201" ++ paste_end ++ "~",
    "\x1b" ++ paste_end,
    paste_end ++ paste_end,
    "\x1b[20" ++ paste_end ++ "1~",
    "\x1b[201~~~~" ++ paste_end,
    paste_start,
    "\x1b[201",
    "\x1b[",
    "\x1b",
    "~",
    paste_start ++ paste_end,
};

fn appendFragment(a: std.mem.Allocator, out: *Bytes, r: Random) !void {
    try out.appendSlice(a, paste_fragments[r.uintLessThan(usize, paste_fragments.len)]);
}

const TextKind = enum { ascii, utf8, raw, boundary };

/// Append filler of class `kind` until `out` holds at least `target` bytes.
fn appendFiller(a: std.mem.Allocator, out: *Bytes, r: Random, kind: TextKind, target: usize) !void {
    while (out.items.len < target) {
        switch (kind) {
            .ascii => try out.append(a, r.intRangeAtMost(u8, 0x20, 0x7E)),
            .utf8, .boundary => try appendCodepoint(a, out, r),
            .raw => try out.append(a, r.int(u8)),
        }
    }
}

fn genText(a: std.mem.Allocator, out: *Bytes, r: Random, kind: TextKind) !void {
    out.clearRetainingCapacity();
    switch (kind) {
        .ascii, .utf8, .raw => {
            const segments = r.uintLessThan(usize, 4);
            var i: usize = 0;
            while (i <= segments) : (i += 1) {
                try appendFiller(a, out, r, kind, out.items.len + r.uintLessThan(usize, 300));
                if (r.boolean()) try appendFragment(a, out, r);
            }
        },
        .boundary => {
            // Put an end-of-paste marker so it straddles a 512-byte boundary.
            const rounds = 1 + r.uintLessThan(usize, 3);
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                const base = (out.items.len / chunk_max) * chunk_max;
                const target = base + r.intRangeAtMost(usize, 507, 516);
                const filler: TextKind = if (r.boolean()) .ascii else .utf8;
                if (target > out.items.len) try appendFiller(a, out, r, filler, target);
                const reps = 1 + r.uintLessThan(usize, 3);
                var k: usize = 0;
                while (k < reps) : (k += 1) try appendFragment(a, out, r);
            }
            try appendFiller(a, out, r, .ascii, out.items.len + r.uintLessThan(usize, 40));
        },
    }
}

// ===========================================================================
// 1. PasteChunker / writeBracketedPasteTo / typePromptTo
// ===========================================================================

/// Independent model of end-of-paste neutralization: drop every `~` that would
/// complete `ESC[201~` in the emitted stream.
fn modelNeutralize(a: std.mem.Allocator, text: []const u8, out: *Bytes) !void {
    out.clearRetainingCapacity();
    for (text) |b| {
        if (b == '~' and std.mem.endsWith(u8, out.items, "\x1b[201")) continue;
        try out.append(a, b);
    }
}

/// Buffers reused across trials so the properties measure the driver, not the
/// debug allocator.
const Scratch = struct {
    concat: Bytes = .empty,
    model: Bytes = .empty,
    sink: RecSink = .{},

    fn deinit(self: *Scratch) void {
        self.concat.deinit(testing.allocator);
        self.model.deinit(testing.allocator);
        self.sink.deinit();
    }
};

fn checkChunker(sc: *Scratch, text: []const u8) !void {
    const a = testing.allocator;
    const concat = &sc.concat;
    const model = &sc.model;
    concat.clearRetainingCapacity();

    const valid = std.unicode.utf8ValidateSlice(text);
    var chunker: driver.PasteChunker = .{ .text = text };
    var buf: [driver.paste_chunk_bytes]u8 = undefined;
    var prev_len: ?usize = null;
    var chunks: usize = 0;
    while (chunker.next(&buf)) |chunk| {
        try testing.expect(chunk.len > 0);
        try testing.expect(chunk.len <= chunk_max);
        // Every chunk before the last is packed to within one codepoint.
        if (prev_len) |p| try testing.expect(p + 4 > chunk_max);
        if (valid) try testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try concat.appendSlice(a, chunk);
        prev_len = chunk.len;
        chunks += 1;
        try testing.expect(chunks <= text.len); // progress, no livelock
    }
    // Exhaustion is stable and consumes the whole input.
    try testing.expect(chunker.next(&buf) == null);
    try testing.expectEqual(text.len, chunker.pos);

    // SECURITY: the payload can never close bracketed paste.
    try testing.expect(std.mem.indexOf(u8, concat.items, paste_end) == null);
    // Only the neutralized `~` bytes are lost; nothing is added or reordered.
    try modelNeutralize(a, text, model);
    try testing.expectEqualSlices(u8, model.items, concat.items);
    if (std.mem.indexOf(u8, text, paste_end) == null) {
        try testing.expectEqualSlices(u8, text, concat.items);
    }
    if (valid) try testing.expect(std.unicode.utf8ValidateSlice(concat.items));
}

const RecSink = struct {
    bytes: Bytes = .empty,
    ends: std.ArrayList(usize) = .empty,
    fail_at: ?usize = null,

    fn deinit(self: *RecSink) void {
        self.bytes.deinit(testing.allocator);
        self.ends.deinit(testing.allocator);
    }

    fn reset(self: *RecSink, fail_at: ?usize) void {
        self.bytes.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
        self.fail_at = fail_at;
    }

    pub fn writeInput(self: *RecSink, data: []const u8) !void {
        if (self.fail_at) |f| {
            if (self.ends.items.len == f) return error.SinkFailed;
        }
        try self.bytes.appendSlice(testing.allocator, data);
        try self.ends.append(testing.allocator, self.bytes.items.len);
    }

    fn count(self: *const RecSink) usize {
        return self.ends.items.len;
    }

    fn write(self: *const RecSink, i: usize) []const u8 {
        const start = if (i == 0) 0 else self.ends.items[i - 1];
        return self.bytes.items[start..self.ends.items[i]];
    }
};

/// Checks the write sequence of a bracketed paste occupying writes
/// `[0, n_writes)` of `sink`. `model` is the neutralized payload for `text`.
fn checkPasteWrites(sink: *const RecSink, model: *const Bytes, text: []const u8, n_writes: usize) !void {
    try testing.expect(n_writes >= 2);
    try testing.expectEqualStrings(paste_start, sink.write(0));
    try testing.expectEqualStrings(paste_end, sink.write(n_writes - 1));

    const stream = sink.bytes.items[0..sink.ends.items[n_writes - 1]];
    try testing.expectEqual(paste_start.len + model.items.len + paste_end.len, stream.len);
    try testing.expectEqualSlices(u8, model.items, stream[paste_start.len .. stream.len - paste_end.len]);
    // Exactly one end marker in the whole stream, and it is the trailing one.
    try testing.expectEqual(stream.len - paste_end.len, std.mem.indexOf(u8, stream, paste_end).?);
    try testing.expect(std.mem.startsWith(u8, stream, paste_start));

    const valid = std.unicode.utf8ValidateSlice(text);
    var i: usize = 1;
    while (i + 1 < n_writes) : (i += 1) {
        const w = sink.write(i);
        try testing.expect(w.len > 0 and w.len <= chunk_max);
        if (valid) try testing.expect(std.unicode.utf8ValidateSlice(w));
    }
}

fn checkPasteSinks(sc: *Scratch, text: []const u8) !void {
    const sink = &sc.sink;
    try modelNeutralize(testing.allocator, text, &sc.model);
    {
        sink.reset(null);
        try driver.writeBracketedPasteTo(sink, text, 0);
        try checkPasteWrites(sink, &sc.model, text, sink.count());
    }
    {
        sink.reset(null);
        try driver.typePromptTo(sink, text, 0, 0);
        const n = sink.count();
        try testing.expect(n >= 3);
        try testing.expectEqualStrings("\r", sink.write(n - 1));
        try checkPasteWrites(sink, &sc.model, text, n - 1);
        // Enter is sent once, after the paste closed.
        try testing.expect(std.mem.endsWith(u8, sink.bytes.items, paste_end ++ "\r"));
    }
}

fn checkPaste(sc: *Scratch, text: []const u8) !void {
    try checkChunker(sc, text);
    try checkPasteSinks(sc, text);
}

test "prop: PasteChunker and bracketed paste invariants over 3200 random prompts" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x9a57_e001);
    const r = prng.random();
    var text: Bytes = .empty;
    defer text.deinit(a);
    var sc: Scratch = .{};
    defer sc.deinit();

    const kinds = [_]TextKind{ .ascii, .utf8, .raw, .boundary };
    var trial: usize = 0;
    while (trial < 3200) : (trial += 1) {
        try genText(a, &text, r, kinds[trial % kinds.len]);
        checkPaste(&sc, text.items) catch |err| {
            std.debug.print("paste property failed: trial={d} kind={s} len={d}\n", .{
                trial, @tagName(kinds[trial % kinds.len]), text.items.len,
            });
            return err;
        };
    }
}

test "prop: ESC[201~ at every offset 0..1040 is neutralized for 1/2/3/4-byte filler" {
    const a = testing.allocator;
    var text: Bytes = .empty;
    defer text.deinit(a);
    var sc: Scratch = .{};
    defer sc.deinit();
    const fillers = [_][]const u8{ "a", "é", "中", "😀" };
    for (fillers) |filler| {
        // Every offset for ASCII; both chunk boundaries for multi-byte filler.
        var units: usize = if (filler.len == 1) 0 else 480 / filler.len;
        while (units * filler.len <= 1040) : (units += 1) {
            if (filler.len > 1 and units * filler.len > 530 and units * filler.len < 990) continue;
            text.clearRetainingCapacity();
            var i: usize = 0;
            while (i < units) : (i += 1) try text.appendSlice(a, filler);
            try text.appendSlice(a, paste_end);
            try text.appendSlice(a, filler);
            try text.appendSlice(a, "tail");
            try checkChunker(&sc, text.items);
        }
    }
    // ASCII shim so multi-byte filler meets the boundary at every phase.
    for (fillers[1..]) |filler| {
        var shim: usize = 0;
        while (shim < 4) : (shim += 1) {
            var units: usize = 496 / filler.len;
            while (units * filler.len <= 520) : (units += 1) {
                text.clearRetainingCapacity();
                try text.appendNTimes(a, 'x', shim);
                var i: usize = 0;
                while (i < units) : (i += 1) try text.appendSlice(a, filler);
                try text.appendSlice(a, paste_end);
                try checkPaste(&sc, text.items);
            }
        }
    }
}

test "prop: paste sink errors propagate from any write index" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x51_4e_4b);
    const r = prng.random();
    var text: Bytes = .empty;
    defer text.deinit(a);
    var ok: RecSink = .{};
    defer ok.deinit();
    var bad: RecSink = .{};
    defer bad.deinit();
    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        try genText(a, &text, r, .boundary);
        ok.reset(null);
        try driver.typePromptTo(&ok, text.items, 0, 0);
        const fail_at = r.uintLessThan(usize, ok.count());
        bad.reset(fail_at);
        try testing.expectError(error.SinkFailed, driver.typePromptTo(&bad, text.items, 0, 0));
        // Writes before the failure are identical to the successful run.
        try testing.expectEqual(fail_at, bad.count());
        try testing.expectEqualSlices(u8, ok.bytes.items[0..bad.bytes.items.len], bad.bytes.items);
    }
}

fn fuzzPaste(_: void, input: []const u8) anyerror!void {
    var sc: Scratch = .{};
    defer sc.deinit();
    try checkPaste(&sc, input);
}

test "fuzz: PasteChunker / writeBracketedPasteTo / typePromptTo" {
    try testing.fuzz({}, fuzzPaste, .{ .corpus = &.{
        "",
        "~",
        "hello",
        paste_end,
        paste_start ++ "x" ++ paste_end,
        "\x1b[201" ++ paste_end ++ "~",
        "\x1b[201~~~~~",
        "\x1b\x1b[\x1b[2\x1b[20\x1b[201\x1b[201~",
        "a" ** 507 ++ paste_end ++ "b",
        "a" ** 508 ++ paste_end ++ "b",
        "a" ** 509 ++ paste_end ++ "b",
        "a" ** 510 ++ paste_end ++ "b",
        "a" ** 511 ++ paste_end ++ "b",
        "a" ** 512 ++ paste_end ++ "b",
        "a" ** 511 ++ "\x1b[201" ++ "~" ** 600,
        "a" ** 510 ++ "中" ++ "中" ** 200,
        "a" ** 509 ++ "😀" ** 300,
        "é" ** 255 ++ "x" ++ "é" ** 300,
        "\xff" ** 700,
        "\xf0\x9f" ** 300,
        "a" ** 511 ++ "\xf4",
        "a" ** 511 ++ "\xf0\x9f\x98",
        "\x80" ** 513,
    } });
}

// ===========================================================================
// 2. isPromptTruncated
// ===========================================================================

fn modelIsSpace(b: u8) bool {
    return switch (b) {
        ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

fn modelNonSpace(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| n += @intFromBool(!modelIsSpace(b));
    return n;
}

fn hasPlaceholder(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var parts = std.mem.tokenizeAny(u8, trimmed, " ");
    if (std.mem.startsWith(u8, trimmed, "<pasted_content ") and std.mem.endsWith(u8, trimmed, "</pasted_content>")) return true;
    const first = parts.next() orelse return false;
    const image = std.mem.eql(u8, first, "[Image");
    if (!image and (!std.mem.eql(u8, first, "[Pasted") or !std.mem.eql(u8, parts.next() orelse return false, "text"))) return false;
    const numbered = parts.next() orelse return false;
    if (numbered.len < 2 or numbered[0] != '#') return false;
    if (image and numbered[numbered.len - 1] != ']') return false;
    const number = numbered[1 .. numbered.len - @intFromBool(image)];
    if (number.len == 0 or std.mem.indexOfNone(u8, number, "0123456789") != null) return false;
    if (image) return parts.next() == null;
    const lines = parts.next() orelse return false;
    return lines.len > 1 and lines[0] == '+' and std.mem.indexOfNone(u8, lines[1..], "0123456789") == null and
        std.mem.eql(u8, parts.next() orelse return false, "lines]") and parts.next() == null;
}

/// Index one past the escape sequence that starts at `s[i]` (`s[i] == ESC`):
/// CSI (`ESC [` params, intermediates, one final byte), OSC (`ESC ]` to BEL or
/// `ESC \`), DCS/SOS/PM/APC (`ESC P|X|^|_` to `ESC \`), or any two-byte escape.
fn modelEscapeEnd(s: []const u8, i: usize) usize {
    if (i + 1 >= s.len) return s.len;
    const kind = s[i + 1];
    var j = i + 2;
    switch (kind) {
        '[' => {
            while (j < s.len and s[j] >= 0x30 and s[j] <= 0x3f) j += 1;
            while (j < s.len and s[j] >= 0x20 and s[j] <= 0x2f) j += 1;
            return @min(j + 1, s.len);
        },
        ']', 'P', 'X', '^', '_' => {
            while (j < s.len) : (j += 1) {
                if (kind == ']' and s[j] == 0x07) return j + 1;
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
            }
            return s.len;
        },
        else => return j,
    }
}

/// Bytes a terminal input parser delivers as text: no escape sequences, no
/// control bytes, no spaces.
fn modelPayload(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = modelEscapeEnd(s, i);
            continue;
        }
        n += @intFromBool(s[i] > 0x20 and s[i] != 0x7f);
        i += 1;
    }
    return n;
}

/// What a terminal input parser keeps of `s`: the same bytes `modelPayload`
/// counts, plus whitespace.
fn modelDelivered(a: std.mem.Allocator, out: *Bytes, s: []const u8) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = modelEscapeEnd(s, i);
            continue;
        }
        if ((s[i] > 0x20 and s[i] != 0x7f) or modelIsSpace(s[i])) try out.append(a, s[i]);
        i += 1;
    }
}

/// The smallest payload an intact delivery of `expected` can have: as
/// written, or as the chunker sends it with `ESC[201~` cut to `ESC[201`.
fn modelFloor(expected: []const u8) !usize {
    var sent: Bytes = .empty;
    defer sent.deinit(testing.allocator);
    try modelNeutralize(testing.allocator, expected, &sent);
    return @min(modelPayload(expected), modelPayload(sent.items));
}

fn modelTruncated(expected: []const u8, received: []const u8) !bool {
    if (expected.len <= 64) return false;
    const floor = try modelFloor(expected);
    if (floor <= 64) return false;
    if (hasPlaceholder(received)) return false;
    return modelPayload(received) < floor;
}

/// Copy `s` with every `\n` turned into `\r\n` and random outer whitespace.
fn crlfPadded(a: std.mem.Allocator, out: *Bytes, r: Random, s: []const u8) !void {
    out.clearRetainingCapacity();
    const ws = " \t\r\n";
    var i = r.uintLessThan(usize, 5);
    while (i > 0) : (i -= 1) try out.append(a, ws[r.uintLessThan(usize, ws.len)]);
    for (s) |b| {
        if (b == '\n') try out.append(a, '\r');
        try out.append(a, b);
    }
    i = r.uintLessThan(usize, 5);
    while (i > 0) : (i -= 1) try out.append(a, ws[r.uintLessThan(usize, ws.len)]);
}

/// Prompt text with exactly `non_ws` significant bytes, no escape or control
/// bytes, and no placeholder openers (`[`, `<`), so truncation is decided by
/// content alone.
fn genPrompt(a: std.mem.Allocator, out: *Bytes, r: Random, non_ws: usize) !void {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,;:!?#$%^&*()-_=+]>{}|/\\'\"`~\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80\xff";
    const ws = " \n\t\r";
    out.clearRetainingCapacity();
    var n: usize = 0;
    while (n < non_ws) {
        if (r.uintLessThan(u8, 6) == 0) {
            try out.append(a, ws[r.uintLessThan(usize, ws.len)]);
        } else {
            try out.append(a, alphabet[r.uintLessThan(usize, alphabet.len)]);
            n += 1;
        }
    }
    var trail = r.uintLessThan(usize, 4);
    while (trail > 0) : (trail -= 1) try out.append(a, ws[r.uintLessThan(usize, ws.len)]);
}

test "prop: isPromptTruncated is reflexive and whitespace/CRLF invariant" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x7c_0001);
    const r = prng.random();
    var x: Bytes = .empty;
    defer x.deinit(a);
    var y: Bytes = .empty;
    defer y.deinit(a);
    var other: Bytes = .empty;
    defer other.deinit(a);

    const kinds = [_]TextKind{ .ascii, .utf8, .raw, .boundary };
    var trial: usize = 0;
    while (trial < 3000) : (trial += 1) {
        if (trial % 2 == 0) {
            try genText(a, &x, r, kinds[(trial / 2) % kinds.len]);
        } else {
            try genPrompt(a, &x, r, r.uintLessThan(usize, 300));
        }
        // Reflexive.
        try testing.expect(!driver.isPromptTruncated(x.items, x.items));
        // CRLF + outer whitespace never looks like truncation.
        try crlfPadded(a, &y, r, x.items);
        try testing.expect(!driver.isPromptTruncated(x.items, y.items));
        try testing.expect(!driver.isPromptTruncated(y.items, x.items));
        // Normalizing either side leaves the verdict against any third text unchanged.
        try genPrompt(a, &other, r, r.uintLessThan(usize, 300));
        try testing.expectEqual(
            driver.isPromptTruncated(x.items, other.items),
            driver.isPromptTruncated(y.items, other.items),
        );
        try testing.expectEqual(
            driver.isPromptTruncated(other.items, x.items),
            driver.isPromptTruncated(other.items, y.items),
        );
        try testing.expectEqual(try modelTruncated(x.items, other.items), driver.isPromptTruncated(x.items, other.items));
        try testing.expectEqual(try modelTruncated(other.items, x.items), driver.isPromptTruncated(other.items, x.items));
        // Longer never counts as truncated.
        try y.appendSlice(a, other.items);
        try testing.expect(!driver.isPromptTruncated(x.items, y.items));
    }
}

test "prop: isPromptTruncated ignores short prompts and paste placeholders" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x7c_0002);
    const r = prng.random();
    var expected: Bytes = .empty;
    defer expected.deinit(a);
    var received: Bytes = .empty;
    defer received.deinit(a);

    const placeholders = [_][]const u8{
        "[Pasted text #1 +42 lines]",
        "[Image #2]",
        "[Pasted text #1]",
        "[Pasted text #",
        "[Pasted text #999 +1 lines][Pasted text #2 +3 lines]",
        "<pasted_content id=\"abc\">",
        "<pasted_content>",
        "<pasted_content",
    };
    var trial: usize = 0;
    while (trial < 3000) : (trial += 1) {
        // Short prompts (<= 64 significant bytes) are never flagged.
        try genPrompt(a, &expected, r, r.uintAtMost(usize, 64));
        try genText(a, &received, r, .raw);
        received.shrinkRetainingCapacity(r.uintAtMost(usize, @min(received.items.len, 80)));
        try testing.expect(!driver.isPromptTruncated(expected.items, received.items));
        try testing.expect(!driver.isPromptTruncated(expected.items, ""));

        const sample = placeholders[trial % placeholders.len];
        try testing.expectEqual(!hasPlaceholder(sample), driver.isPromptTruncated("x" ** 200, sample));
        try received.insertSlice(a, 0, "prefix");
        try received.appendSlice(a, sample);
        try testing.expect(driver.isPromptTruncated("x" ** 300, received.items));
    }
}

test "prop: isPromptTruncated detects genuine truncation of prompts over 64 bytes" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x7c_0003);
    const r = prng.random();
    var expected: Bytes = .empty;
    defer expected.deinit(a);
    var received: Bytes = .empty;
    defer received.deinit(a);
    var padded: Bytes = .empty;
    defer padded.deinit(a);

    var detected: usize = 0;
    var trial: usize = 0;
    while (trial < 3000) : (trial += 1) {
        const non_ws = 65 + r.uintLessThan(usize, if (trial % 3 == 0) 8 else 1500);
        try genPrompt(a, &expected, r, non_ws);
        const e = expected.items;

        received.clearRetainingCapacity();
        switch (trial % 4) {
            0 => try received.appendSlice(a, e[0..r.uintLessThan(usize, e.len)]), // head kept
            1 => try received.appendSlice(a, e[1 + r.uintLessThan(usize, e.len) ..]), // tail kept
            2 => { // middle dropped (a lost PTY chunk)
                const lo = r.uintLessThan(usize, e.len);
                const hi = lo + 1 + r.uintLessThan(usize, e.len - lo);
                try received.appendSlice(a, e[0..lo]);
                try received.appendSlice(a, e[hi..]);
            },
            else => { // TTYHOG-style cut at 1024 bytes or one byte short
                const cut = @min(e.len - 1, 1024);
                try received.appendSlice(a, e[0..cut]);
            },
        }
        const dropped = modelNonSpace(e) - modelNonSpace(received.items);
        const got = driver.isPromptTruncated(e, received.items);
        try testing.expectEqual(dropped > 0, got);
        detected += @intFromBool(got);

        // Whitespace reshaping of the truncated copy cannot mask the loss.
        try crlfPadded(a, &padded, r, received.items);
        try testing.expectEqual(got, driver.isPromptTruncated(e, padded.items));
    }
    try testing.expect(detected > 2500);
}

fn fuzzTruncated(_: void, input: []const u8) anyerror!void {
    const split: usize = if (input.len <= 1)
        input.len
    else
        1 + (@as(usize, input[0]) * (input.len - 1)) / 255;
    const body_start: usize = @min(1, input.len);
    const expected = input[body_start..split];
    const received = input[split..];

    const got = driver.isPromptTruncated(expected, received);
    try testing.expectEqual(try modelTruncated(expected, received), got);
    try testing.expectEqual(modelPayload(expected), driver.promptPayloadLen(expected, false));
    try testing.expectEqual(modelPayload(received), driver.promptPayloadLen(received, false));
    if (got) {
        try testing.expect(expected.len > 64);
        try testing.expect(modelPayload(expected) > 64);
        try testing.expect(!hasPlaceholder(received));
    }
    try testing.expect(!driver.isPromptTruncated(expected, expected));
    try testing.expect(!driver.isPromptTruncated(received, received));
    try testing.expect(!driver.isPromptTruncated(input, input));
    _ = driver.isPromptTruncated(received, expected);
    // A prefix can only be flagged when the full text is long enough.
    if (driver.isPromptTruncated(input, expected)) try testing.expect(modelNonSpace(input) > 64);

    // What the input parser keeps of the stream the chunker sends is never a
    // truncation, however the prompt mixes escapes, controls and ESC[201~.
    var sent: Bytes = .empty;
    defer sent.deinit(testing.allocator);
    var kept: Bytes = .empty;
    defer kept.deinit(testing.allocator);
    try modelNeutralize(testing.allocator, input, &sent);
    try testing.expectEqual(modelPayload(sent.items), driver.promptPayloadLen(input, true));
    try modelDelivered(testing.allocator, &kept, sent.items);
    try testing.expect(!driver.isPromptTruncated(input, kept.items));
    try modelDelivered(testing.allocator, &kept, input);
    try testing.expect(!driver.isPromptTruncated(input, kept.items));
    try testing.expect(!driver.isPromptTruncated(input, sent.items));
}

test "fuzz: isPromptTruncated(expected, received)" {
    const long = "The quick brown fox jumps over the lazy dog, then writes a property test. " ** 3;
    try testing.fuzz({}, fuzzTruncated, .{ .corpus = &.{
        "",
        "\x00",
        "\xff",
        "\x80abcabc",
        "\xe0" ++ long ++ long[0..40],
        "\xf0" ++ long ++ "[Pasted text #1 +12 lines]",
        "\xf0" ++ long ++ "<pasted_content id=1>",
        "\xc0" ++ long ++ "\r\n \t" ++ long,
        "\xff" ++ long,
        "\x01" ++ long,
        "\x90" ++ "a" ** 64 ++ "a" ** 63,
        "\x90" ++ "a" ** 65 ++ "a" ** 64,
        "\x90" ++ "a \n" ** 65 ++ "a\r\n" ** 64,
        "\x80" ++ " \t\r\n" ** 80,
        "\xff" ++ "\x1b[1;31m" ++ long ++ "\x1b[0m" ++ long,
        "\xff" ++ long[0..70] ++ paste_end ++ "12 hello" ++ long,
        "\xff" ++ long ++ "\x1b]0;title\x07" ++ long ++ "\x1bPq\x1b\\" ++ "\x00\x7f\x1b",
        "\x80" ++ long ++ paste_end ++ "~~" ++ long ++ "\x1b[201" ++ long,
    } });
}

/// Insert `count` decorations a terminal never delivers as text: SGR / cursor
/// CSI sequences, OSC titles, and bare control bytes.
fn decorate(a: std.mem.Allocator, out: *Bytes, r: Random, plain: []const u8, count: usize) !void {
    const decorations = [_][]const u8{
        "\x1b[0m",                 "\x1b[1;31m",             "\x1b[38;5;153m", "\x1b[2K", "\x1b[?25l", "\x1b[10;20H",
        "\x1b]0;window title\x07", "\x1b]8;;http://x\x1b\\", "\x1bPq#0\x1b\\", "\x1b7",   "\x00",      "\x07",
        "\x08",                    "\x7f",                   "\x0b",           "\x1f",
    };
    out.clearRetainingCapacity();
    try out.appendSlice(a, plain);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Insert only at whole-codepoint, non-decoration positions of the
        // original text by rebuilding from the front each time.
        var at = r.uintAtMost(usize, out.items.len);
        while (at > 0 and at < out.items.len and
            (inDecoration(out.items, at) or (out.items[at] & 0xC0) == 0x80)) at -= 1;
        try out.insertSlice(a, at, decorations[r.uintLessThan(usize, decorations.len)]);
    }
}

/// True when `at` falls strictly inside an escape sequence of `s`.
fn inDecoration(s: []const u8, at: usize) bool {
    var i: usize = 0;
    while (i < s.len and i < at) {
        if (s[i] == 0x1b) {
            const end = modelEscapeEnd(s, i);
            if (at < end) return true;
            i = end;
        } else i += 1;
    }
    return false;
}

test "prop: ANSI codes, control bytes and ESC[201~ in a prompt never false-positive PromptTruncated" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x7c_0004);
    const r = prng.random();
    var plain: Bytes = .empty;
    defer plain.deinit(a);
    var typed: Bytes = .empty;
    defer typed.deinit(a);
    var sent: Bytes = .empty;
    defer sent.deinit(a);
    var kept: Bytes = .empty;
    defer kept.deinit(a);

    var flagged: usize = 0;
    var trial: usize = 0;
    while (trial < 3000) : (trial += 1) {
        const non_ws = 65 + r.uintLessThan(usize, if (trial % 3 == 0) 8 else 1200);
        try genPrompt(a, &plain, r, non_ws);
        try decorate(a, &typed, r, plain.items, 1 + r.uintLessThan(usize, 12));

        // Decorations add no payload: the typed prompt and the plain text agree.
        try testing.expectEqual(non_ws, modelPayload(typed.items));
        try testing.expectEqual(non_ws, driver.promptPayloadLen(typed.items, false));
        // Claude reports the text with decorations stripped, kept, or half-kept.
        try testing.expect(!driver.isPromptTruncated(typed.items, plain.items));
        try testing.expect(!driver.isPromptTruncated(typed.items, typed.items));
        try testing.expect(!driver.isPromptTruncated(plain.items, typed.items));
        try modelDelivered(a, &kept, typed.items);
        try testing.expect(!driver.isPromptTruncated(typed.items, kept.items));

        // A genuine loss is still caught through the decorations.
        const lost = 1 + r.uintLessThan(usize, plain.items.len);
        const head = plain.items[0 .. plain.items.len - lost];
        const dropped = non_ws - modelNonSpace(head);
        try testing.expectEqual(dropped > 0, driver.isPromptTruncated(typed.items, head));
        flagged += @intFromBool(dropped > 0);

        // Embedded end-of-paste markers: the chunker cuts each to ESC[201 and
        // the input parser swallows what follows as the rest of that CSI.
        const markers = 1 + r.uintLessThan(usize, 4);
        typed.clearRetainingCapacity();
        try typed.appendSlice(a, plain.items);
        var m: usize = 0;
        while (m < markers) : (m += 1) {
            var at = r.uintAtMost(usize, typed.items.len);
            while (at > 0 and at < typed.items.len and (typed.items[at] & 0xC0) == 0x80) at -= 1;
            try typed.insertSlice(a, at, paste_fragments[r.uintLessThan(usize, 7)]);
        }
        try modelNeutralize(a, typed.items, &sent);
        try modelDelivered(a, &kept, sent.items);
        try testing.expect(!driver.isPromptTruncated(typed.items, kept.items));
        try testing.expect(!driver.isPromptTruncated(typed.items, sent.items));
        try testing.expect(!driver.isPromptTruncated(typed.items, typed.items));
        try modelDelivered(a, &kept, typed.items);
        try testing.expect(!driver.isPromptTruncated(typed.items, kept.items));
        try testing.expectEqual(try modelTruncated(typed.items, plain.items), driver.isPromptTruncated(typed.items, plain.items));
    }
    try testing.expect(flagged > 2500);
}

// ===========================================================================
// 3. shouldStripChildEnv / buildChildEnvFromMap
// ===========================================================================

const auth_vars = [_][]const u8{
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE",
};
const more_kept_vars = [_][]const u8{
    "ANTHROPIC_API_KEY",                 "ANTHROPIC_BASE_URL",            "AWS_PROFILE",
    "AWS_REGION",                        "PATH",                          "HOME",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS",     "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "ANTHROPIC_VERTEX_PROJECT_ID",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
};
const exact_markers = [_][]const u8{
    "CLAUDECODE",
    "AI_AGENT",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SSE_PORT",
};
const marker_prefixes = [_][]const u8{
    "CLAUDE_CODE_SESSION_",
    "CLAUDE_CODE_PARENT_",
    "CLAUDE_CODE_SUBAGENT_",
};
const persistence_env = "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE";

fn modelStrip(name: []const u8) bool {
    for (exact_markers) |m| if (std.mem.eql(u8, name, m)) return true;
    for (marker_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn isAuthVar(name: []const u8) bool {
    for (auth_vars) |v| if (std.mem.eql(u8, name, v)) return true;
    return false;
}

fn checkStripName(name: []const u8) !void {
    const got = driver.shouldStripChildEnv(name);
    try testing.expectEqual(modelStrip(name), got);
    if (isAuthVar(name)) try testing.expect(!got);
}

test "prop: shouldStripChildEnv strips exactly the nesting markers" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0xe0_0001);
    const r = prng.random();
    var name: Bytes = .empty;
    defer name.deinit(a);

    for (auth_vars) |v| try testing.expect(!driver.shouldStripChildEnv(v));
    for (more_kept_vars) |v| try testing.expect(!driver.shouldStripChildEnv(v));
    for (exact_markers) |m| try testing.expect(driver.shouldStripChildEnv(m));
    for (marker_prefixes) |p| try testing.expect(driver.shouldStripChildEnv(p));
    try testing.expect(driver.shouldStripChildEnv("CLAUDE_CODE_SESSION_ID"));

    const suffix_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcxyz-. ";
    var trial: usize = 0;
    while (trial < 4000) : (trial += 1) {
        // Prefix markers with any suffix are always stripped.
        name.clearRetainingCapacity();
        try name.appendSlice(a, marker_prefixes[trial % marker_prefixes.len]);
        var n = r.uintLessThan(usize, 24);
        while (n > 0) : (n -= 1) {
            const c = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else suffix_alphabet[r.uintLessThan(usize, suffix_alphabet.len)];
            try name.append(a, c);
        }
        try testing.expect(driver.shouldStripChildEnv(name.items));

        // One-edit mutants of known names follow the model exactly: matching is
        // case-sensitive, exact for the exact markers, and never a substring match.
        const pools = [_][]const []const u8{ &auth_vars, &exact_markers, &marker_prefixes, &more_kept_vars };
        const pool = pools[r.uintLessThan(usize, pools.len)];
        name.clearRetainingCapacity();
        try name.appendSlice(a, pool[r.uintLessThan(usize, pool.len)]);
        switch (r.uintLessThan(u8, 6)) {
            0 => try name.append(a, suffix_alphabet[r.uintLessThan(usize, suffix_alphabet.len)]),
            1 => try name.insert(a, 0, suffix_alphabet[r.uintLessThan(usize, suffix_alphabet.len)]),
            2 => _ = name.pop(),
            3 => {
                const i = r.uintLessThan(usize, name.items.len);
                name.items[i] = std.ascii.toLower(name.items[i]);
            },
            4 => _ = name.orderedRemove(r.uintLessThan(usize, name.items.len)),
            else => {},
        }
        try checkStripName(name.items);

        // Auth/provider vars survive under any casing-preserving lookup.
        try testing.expect(!driver.shouldStripChildEnv(auth_vars[trial % auth_vars.len]));
    }
}

fn fuzzStripName(_: void, input: []const u8) anyerror!void {
    try checkStripName(input);
    // Any name glued behind a marker prefix is stripped; glued behind an auth
    // var name it is judged on its own text.
    var buf: [256]u8 = undefined;
    const tail = input[0..@min(input.len, 200)];
    for (marker_prefixes) |p| {
        const joined = try std.fmt.bufPrint(&buf, "{s}{s}", .{ p, tail });
        try testing.expect(driver.shouldStripChildEnv(joined));
    }
}

test "fuzz: shouldStripChildEnv" {
    try testing.fuzz({}, fuzzStripName, .{ .corpus = &.{
        "",
        "CLAUDECODE",
        "claudecode",
        "CLAUDECODE ",
        "CLAUDECODE\x00",
        "AI_AGENT",
        "AI_AGENT_NAME",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_ENTRYPOINTS",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_SESSION_",
        "CLAUDE_CODE_SESSION",
        "CLAUDE_CODE_PARENT_PID",
        "CLAUDE_CODE_SUBAGENT_DEPTH",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE",
        "XCLAUDE_CODE_SESSION_ID",
        "TERM",
        "CLAUDE_P_FIFO",
    } });
}

/// Full contract of `buildChildEnvFromMap` for one input map.
fn checkChildEnv(scratch: std.mem.Allocator, map: *const std.process.EnvMap, fifo: []const u8) !void {
    const a = testing.allocator; // the code under test is always leak-checked
    var list = try driver.buildChildEnvFromMap(a, map, fifo);
    defer driver.freeChildEnv(a, &list);

    var seen = std.StringHashMap([]const u8).init(scratch);
    defer seen.deinit();
    for (list.items) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.EntryWithoutEquals;
        const name = entry[0..eq];
        const gop = try seen.getOrPut(name);
        try testing.expect(!gop.found_existing); // zero duplicate names
        gop.value_ptr.* = entry[eq + 1 ..];
        try testing.expect(!modelStrip(name)); // no nesting marker leaks
    }

    try testing.expect(seen.get("CLAUDE_P_FIFO") == null);
    try testing.expectEqualStrings("xterm-256color", seen.get("TERM").?);
    try testing.expectEqualStrings(map.get(persistence_env) orelse "1", seen.get(persistence_env).?);

    var kept: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const injected = std.mem.eql(u8, name, "CLAUDE_P_FIFO") or std.mem.eql(u8, name, "TERM");
        if (modelStrip(name)) {
            try testing.expect(seen.get(name) == null);
        } else if (!injected) {
            kept += 1;
            try testing.expectEqualStrings(e.value_ptr.*, seen.get(name).?);
        }
        if (isAuthVar(name)) try testing.expectEqualStrings(e.value_ptr.*, seen.get(name).?);
    }
    const injected_persistence: usize = @intFromBool(map.get(persistence_env) == null);
    try testing.expectEqual(kept + 1 + injected_persistence, list.items.len);
}

fn childEnvAllocProbe(allocator: std.mem.Allocator, map: *const std.process.EnvMap, fifo: []const u8) !void {
    var list = try driver.buildChildEnvFromMap(allocator, map, fifo);
    driver.freeChildEnv(allocator, &list);
}

fn genEnvName(a: std.mem.Allocator, out: *Bytes, r: Random) !void {
    out.clearRetainingCapacity();
    const special = [_][]const u8{ "TERM", "CLAUDE_P_FIFO", "TERMINFO", "CLAUDE_P_FIFO2", "term", "CLAUDE_CODE_SESSION", "CLAUDE_CODE_PARENT", "AI_AGENTS", "XAI_AGENT" };
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abc";
    switch (r.uintLessThan(u8, 7)) {
        0 => try out.appendSlice(a, auth_vars[r.uintLessThan(usize, auth_vars.len)]),
        1 => try out.appendSlice(a, exact_markers[r.uintLessThan(usize, exact_markers.len)]),
        2 => {
            try out.appendSlice(a, marker_prefixes[r.uintLessThan(usize, marker_prefixes.len)]);
            var n = r.uintLessThan(usize, 10);
            while (n > 0) : (n -= 1) try out.append(a, alphabet[r.uintLessThan(usize, alphabet.len)]);
        },
        3 => try out.appendSlice(a, special[r.uintLessThan(usize, special.len)]),
        4 => try out.appendSlice(a, more_kept_vars[r.uintLessThan(usize, more_kept_vars.len)]),
        else => {
            var n = 1 + r.uintLessThan(usize, 16);
            while (n > 0) : (n -= 1) try out.append(a, alphabet[r.uintLessThan(usize, alphabet.len)]);
        },
    }
}

fn genEnvValue(a: std.mem.Allocator, out: *Bytes, r: Random) !void {
    out.clearRetainingCapacity();
    var n = r.uintLessThan(usize, 40);
    while (n > 0) : (n -= 1) {
        // Values may hold `=`, spaces, newlines and non-UTF-8 bytes; never NUL.
        const c: u8 = switch (r.uintLessThan(u8, 8)) {
            0 => '=',
            1 => r.intRangeAtMost(u8, 1, 255),
            else => r.intRangeAtMost(u8, 0x20, 0x7E),
        };
        try out.append(a, c);
    }
}

fn genEnvMap(a: std.mem.Allocator, map: *std.process.EnvMap, r: Random, max_entries: usize) !void {
    var name: Bytes = .empty;
    defer name.deinit(a);
    var value: Bytes = .empty;
    defer value.deinit(a);
    var n = r.uintAtMost(usize, max_entries);
    while (n > 0) : (n -= 1) {
        try genEnvName(a, &name, r);
        try genEnvValue(a, &value, r);
        try map.put(name.items, value.items);
    }
    // Auth/provider vars ride along with whatever else is in the environment.
    for (auth_vars) |v| {
        if (r.boolean()) {
            try genEnvValue(a, &value, r);
            try map.put(v, value.items);
        }
    }
}

test "prop: buildChildEnvFromMap filters, injects and preserves over 2000 random environments" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0xe0_0002);
    const r = prng.random();
    var fifo: Bytes = .empty;
    defer fifo.deinit(a);

    // Input maps live on a reused arena; only the driver's output is on the
    // leak-checking allocator.
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        _ = arena_state.reset(.retain_capacity);
        var map = std.process.EnvMap.init(arena);
        try genEnvMap(arena, &map, r, 12);
        try genEnvValue(a, &fifo, r);
        checkChildEnv(arena, &map, fifo.items) catch |err| {
            std.debug.print("child env property failed: trial={d} entries={d}\n", .{ trial, map.count() });
            return err;
        };
    }
}

test "prop: buildChildEnvFromMap never leaks under allocation failure" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0xe0_0003);
    const r = prng.random();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var trial: usize = 0;
    while (trial < 100) : (trial += 1) {
        _ = arena_state.reset(.retain_capacity);
        var map = std.process.EnvMap.init(arena);
        try genEnvMap(arena, &map, r, 6);
        try testing.checkAllAllocationFailures(a, childEnvAllocProbe, .{ &map, @as([]const u8, "/tmp/claude-p-1-ab/events.fifo") });
    }
    var empty = std.process.EnvMap.init(a);
    defer empty.deinit();
    try testing.checkAllAllocationFailures(a, childEnvAllocProbe, .{ &empty, @as([]const u8, "") });
}

/// Input is `NAME=VALUE` lines; the first line is the FIFO path.
fn fuzzChildEnv(_: void, input: []const u8) anyerror!void {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    var map = std.process.EnvMap.init(arena_state.allocator());
    var lines = std.mem.splitScalar(u8, input, '\n');
    const fifo = lines.next() orelse "";
    var entries: usize = 0;
    while (lines.next()) |line| {
        if (entries == 48) break;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse line.len;
        const value = if (eq < line.len) line[eq + 1 ..] else "";
        // `EnvMap.put` asserts WTF-8 keys; such names cannot reach the driver.
        if (!std.unicode.wtf8ValidateSlice(line[0..eq])) continue;
        try map.put(line[0..eq], value);
        entries += 1;
    }
    try checkChildEnv(arena_state.allocator(), &map, fifo);
    if (entries <= 8) {
        try testing.checkAllAllocationFailures(a, childEnvAllocProbe, .{ &map, fifo });
    }
}

test "fuzz: buildChildEnvFromMap" {
    try testing.fuzz({}, fuzzChildEnv, .{ .corpus = &.{
        "",
        "/tmp/f",
        "/tmp/f\nPATH=/bin\nHOME=/root",
        "/tmp/f\nTERM=dumb\nCLAUDE_P_FIFO=/evil\nCLAUDECODE=1\nAI_AGENT=x",
        "/tmp/f\nCLAUDE_CODE_FORCE_SESSION_PERSISTENCE=0",
        "/tmp/f\nCLAUDE_CODE_FORCE_SESSION_PERSISTENCE=",
        "/tmp/f\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01=abc==\nCLAUDE_CODE_USE_BEDROCK=1\nCLAUDE_CODE_USE_VERTEX=1\nCLAUDE_CODE_USE_FOUNDRY=1\nCLAUDE_CONFIG_DIR=/c",
        "/tmp/f\nCLAUDE_CODE_SESSION_ID=a\nCLAUDE_CODE_SESSION_X=b\nCLAUDE_CODE_PARENT_PID=1\nCLAUDE_CODE_SUBAGENT_DEPTH=2\nCLAUDE_CODE_ENTRYPOINT=cli\nCLAUDE_CODE_SSE_PORT=1\nCLAUDE_CODE_CHILD_SESSION=1",
        "a=b=c\nA=1\nA=2\na=3\n=empty\nNOEQ\nterm=x\nTERMX=y",
        "\xff\xfe\n\xff=\x01\nTERM\nCLAUDE_P_FIFO",
    } });
}

// ===========================================================================
// 4. shellQuoteArgv / buildArgv
// ===========================================================================

/// Independent POSIX sh word splitter for the subset `shellQuoteArgv` may
/// emit: single-quoted spans, backslash escapes outside quotes, and unquoted
/// spaces as separators. Anything else outside quotes is rejected so an
/// unquoted metacharacter can never pass as a round trip.
fn posixUnquote(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var cur: Bytes = .empty;
    var in_token = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '\'') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return error.UnterminatedQuote;
            try cur.appendSlice(arena, line[i + 1 .. close]);
            in_token = true;
            i = close + 1;
        } else if (c == '\\') {
            if (i + 1 >= line.len) return error.TrailingBackslash;
            try cur.append(arena, line[i + 1]);
            in_token = true;
            i += 2;
        } else if (c == ' ') {
            if (in_token) {
                try tokens.append(arena, try cur.toOwnedSlice(arena));
                in_token = false;
            }
            i += 1;
        } else {
            return error.UnquotedByte;
        }
    }
    if (in_token) try tokens.append(arena, try cur.toOwnedSlice(arena));
    return tokens.toOwnedSlice(arena);
}

fn checkShellQuote(argv: []const []const u8) !void {
    const a = testing.allocator;
    const quoted = try driver.shellQuoteArgv(a, argv);
    defer a.free(quoted);

    var stack = std.heap.stackFallback(4096, a);
    var arena_state = std.heap.ArenaAllocator.init(stack.get());
    defer arena_state.deinit();
    const tokens = try posixUnquote(arena_state.allocator(), quoted);
    try testing.expectEqual(argv.len, tokens.len);
    for (argv, tokens) |want, got| try testing.expectEqualSlices(u8, want, got);

    // Exact size: 2 quotes per arg, 3 extra bytes per embedded quote, 1 space between args.
    var want_len: usize = if (argv.len == 0) 0 else argv.len - 1;
    for (argv) |arg| want_len += arg.len + 2 + 3 * std.mem.count(u8, arg, "'");
    try testing.expectEqual(want_len, quoted.len);
}

fn shellQuoteAllocProbe(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const quoted = try driver.shellQuoteArgv(allocator, argv);
    allocator.free(quoted);
}

const nasty_words = [_][]const u8{
    "",      "'",                "''",          "'\\''",
    "\\",    "\\'",              "$(rm -rf /)", "`id`",
    "a b",   " ",                "\n",          "\t",
    "\"",    "$HOME",            "${IFS}",      ";",
    "&&",    "|",                "*",           "~",
    "!",     "#",                "--flag=it's", "-n",
    "\\n",   "'; echo pwned; '", "'$(echo x)'", "\r\n",
    "a'b'c", "'''''",            "\\\\''\\\\",  "é中😀",
};

fn genShellWord(a: std.mem.Allocator, r: Random, printable_only: bool) ![]u8 {
    var out: Bytes = .empty;
    errdefer out.deinit(a);
    const meta = "'\"\\ $()`\n\t;&|*?~!#{}[]<>=-";
    var parts = r.uintLessThan(usize, 5);
    while (parts > 0) : (parts -= 1) {
        switch (r.uintLessThan(u8, 5)) {
            0 => try out.appendSlice(a, nasty_words[r.uintLessThan(usize, nasty_words.len)]),
            1 => try out.append(a, meta[r.uintLessThan(usize, meta.len)]),
            2 => try out.append(a, '\''),
            3 => try out.append(a, r.intRangeAtMost(u8, 0x20, 0x7E)),
            else => if (printable_only)
                try out.append(a, r.intRangeAtMost(u8, 'a', 'z'))
            else
                try out.append(a, r.int(u8)),
        }
    }
    return out.toOwnedSlice(a);
}

test "prop: shellQuoteArgv round-trips through POSIX unquoting for 4000 random argvs" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0x5e_0001);
    const r = prng.random();

    try checkShellQuote(&.{});
    try checkShellQuote(&nasty_words);
    for (nasty_words) |w| try checkShellQuote(&.{w});

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var trial: usize = 0;
    while (trial < 4000) : (trial += 1) {
        _ = arena_state.reset(.retain_capacity);
        const argv = try arena.alloc([]const u8, r.uintLessThan(usize, 8));
        for (argv) |*slot| slot.* = try genShellWord(arena, r, false);
        try checkShellQuote(argv);
        if (trial % 40 == 0) try testing.checkAllAllocationFailures(a, shellQuoteAllocProbe, .{@as([]const []const u8, argv)});
    }
}

test "prop: shellQuoteArgv output is re-read byte-for-byte by the real /bin/sh" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = Random.DefaultPrng.init(0x5e_0002);
    const r = prng.random();

    // NUL cannot cross exec, and the comparison is byte-exact, so words are
    // printable ASCII plus tab/newline: every shell metacharacter is included.
    const argv = try arena.alloc([]const u8, 300);
    for (argv, 0..) |*slot, i| {
        if (i < nasty_words.len and std.unicode.utf8ValidateSlice(nasty_words[i]) and
            std.mem.indexOfAny(u8, nasty_words[i], "é中😀") == null)
        {
            slot.* = nasty_words[i];
        } else {
            slot.* = try genShellWord(arena, r, true);
        }
    }
    const quoted = try driver.shellQuoteArgv(arena, argv);
    const script = try std.fmt.allocPrint(arena, "printf '%s\\0' {s}", .{quoted});
    const res = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "/bin/sh", "-c", script },
        .max_output_bytes = 1 << 20,
    }) catch return error.SkipZigTest; // no POSIX shell on this host
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, res.term);
    try testing.expectEqualStrings("", res.stderr);

    var it = std.mem.splitScalar(u8, res.stdout, 0);
    for (argv) |want| try testing.expectEqualSlices(u8, want, it.next().?);
    try testing.expectEqualStrings("", it.next().?); // trailing NUL
    try testing.expect(it.next() == null);
}

/// Input is NUL-separated argv words.
fn fuzzShellQuote(_: void, input: []const u8) anyerror!void {
    var words: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, input, 0);
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    try checkShellQuote(words[0..n]);
    try checkShellQuote(&.{input});
}

test "fuzz: shellQuoteArgv POSIX round trip" {
    try testing.fuzz({}, fuzzShellQuote, .{ .corpus = &.{
        "",
        "\x00",
        "'",
        "''\x00'\\''\x00\\",
        "claude\x00--settings\x00{\"hooks\":{\"Stop\":[{\"command\":\"sh '/tmp/a b/hook.sh'\"}]}}",
        "$(rm -rf /)\x00`id`\x00${IFS}\x00;\x00&&\x00|",
        "a b\x00\n\x00\t\x00 \x00",
        "it's\x00'; echo pwned; '\x00\\'\x00'\\",
        "\xff'\xfe\x00\x1b[201~",
    } });
}

// --- buildArgv -------------------------------------------------------------

/// Independent statement of the documented flag order.
fn modelArgv(arena: std.mem.Allocator, binary: []const u8, settings: []const u8, o: driver.Options) ![][]const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    try v.appendSlice(arena, &.{ binary, "--settings", settings });
    if (o.model) |s| try v.appendSlice(arena, &.{ "--model", s });
    if (o.max_turns) |n| try v.appendSlice(arena, &.{ "--max-turns", try std.fmt.allocPrint(arena, "{d}", .{n}) });
    if (o.allowed_tools) |s| try v.appendSlice(arena, &.{ "--allowedTools", s });
    if (o.skip_permissions) try v.append(arena, "--dangerously-skip-permissions");
    if (o.resume_session) |s| try v.appendSlice(arena, &.{ "--resume", s });
    if (o.cont) try v.append(arena, "--continue");
    if (o.session_id) |s| try v.appendSlice(arena, &.{ "--session-id", s });
    if (o.verbose) try v.append(arena, "--verbose");
    if (o.system_prompt) |s| try v.appendSlice(arena, &.{ "--system-prompt", s });
    if (o.append_system_prompt) |s| try v.appendSlice(arena, &.{ "--append-system-prompt", s });
    if (o.permission_mode) |s| try v.appendSlice(arena, &.{ "--permission-mode", s });
    if (o.disallowed_tools) |s| try v.appendSlice(arena, &.{ "--disallowedTools", s });
    if (o.fallback_model) |s| try v.appendSlice(arena, &.{ "--fallback-model", s });
    if (o.setting_sources) |s| try v.appendSlice(arena, &.{ "--setting-sources", s });
    for (o.add_dirs) |d| try v.appendSlice(arena, &.{ "--add-dir", d });
    for (o.mcp_configs) |c| try v.appendSlice(arena, &.{ "--mcp-config", c });
    try v.appendSlice(arena, o.extra_args);
    return v.toOwnedSlice(arena);
}

fn argvAllocProbe(allocator: std.mem.Allocator, binary: []const u8, settings: []const u8, opts: driver.Options) !void {
    var argv = try driver.buildArgv(allocator, binary, settings, opts);
    argv.deinit(allocator);
}

fn checkArgv(arena: std.mem.Allocator, binary: []const u8, settings: []const u8, opts: driver.Options, sweep: bool) !void {
    const a = testing.allocator;
    const want = try modelArgv(arena, binary, settings, opts);
    {
        var argv = try driver.buildArgv(a, binary, settings, opts);
        defer argv.deinit(a);
        try testing.expectEqual(want.len, argv.items.len);
        for (want, argv.items) |w, g| try testing.expectEqualSlices(u8, w, g);
        // The prompt is typed into the PTY, never passed on the command line.
        try testing.expect(argv.items.ptr != want.ptr);
        try testing.expectEqual(opts.max_turns != null, argv.max_turns_text != null);
        // The argv survives shell quoting unchanged.
        try checkShellQuote(argv.items);
    }
    if (sweep) try testing.checkAllAllocationFailures(a, argvAllocProbe, .{ binary, settings, opts });
}

/// Draws strings on demand from either a PRNG or a fuzz input.
const WordSource = union(enum) {
    random: struct { r: Random, arena: std.mem.Allocator },
    input: std.mem.SplitIterator(u8, .scalar),

    fn word(self: *WordSource) ![]const u8 {
        switch (self.*) {
            .random => |s| return genShellWord(s.arena, s.r, false),
            .input => |*it| return it.next() orelse "",
        }
    }

    fn opt(self: *WordSource, on: bool) !?[]const u8 {
        return if (on) try self.word() else null;
    }

    fn list(self: *WordSource, arena: std.mem.Allocator, n: usize) ![]const []const u8 {
        const out = try arena.alloc([]const u8, n);
        for (out) |*slot| slot.* = try self.word();
        return out;
    }
};

fn optionsFromBits(arena: std.mem.Allocator, bits: u32, max_turns: u32, src: *WordSource) !driver.Options {
    const bit = struct {
        fn at(b: u32, comptime i: u5) bool {
            return (b >> i) & 1 == 1;
        }
    }.at;
    return .{
        .prompt = try src.word(),
        .model = try src.opt(bit(bits, 0)),
        .max_turns = if (bit(bits, 1)) max_turns else null,
        .allowed_tools = try src.opt(bit(bits, 2)),
        .skip_permissions = bit(bits, 3),
        .resume_session = try src.opt(bit(bits, 4)),
        .cont = bit(bits, 5),
        .session_id = try src.opt(bit(bits, 6)),
        .verbose = bit(bits, 7),
        .system_prompt = try src.opt(bit(bits, 8)),
        .append_system_prompt = try src.opt(bit(bits, 9)),
        .permission_mode = try src.opt(bit(bits, 10)),
        .disallowed_tools = try src.opt(bit(bits, 11)),
        .fallback_model = try src.opt(bit(bits, 12)),
        .setting_sources = try src.opt(bit(bits, 13)),
        .add_dirs = try src.list(arena, (bits >> 14) & 3),
        .mcp_configs = try src.list(arena, (bits >> 16) & 3),
        .extra_args = try src.list(arena, (bits >> 18) & 7),
        // Fields that must not influence argv.
        .cwd = try src.opt(bit(bits, 21)),
        .extra_settings_json = try src.opt(bit(bits, 22)),
        .claude_path = try src.opt(bit(bits, 23)),
        .debug = bit(bits, 24),
    };
}

test "prop: buildArgv matches the flag model and never leaks over 1500 random option subsets" {
    const a = testing.allocator;
    var prng = Random.DefaultPrng.init(0xa9_0001);
    const r = prng.random();
    const turn_edges = [_]u32{ 0, 1, 9, 10, 4294967295 };

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var trial: usize = 0;
    while (trial < 1500) : (trial += 1) {
        _ = arena_state.reset(.retain_capacity);
        var src: WordSource = .{ .random = .{ .r = r, .arena = arena } };
        // Trials 0 and 1 pin the empty and the full option set.
        const bits: u32 = switch (trial) {
            0 => 0,
            1 => 0xffff_ffff,
            else => r.int(u32),
        };
        const max_turns = if (r.boolean()) turn_edges[r.uintLessThan(usize, turn_edges.len)] else r.int(u32);
        const opts = try optionsFromBits(arena, bits, max_turns, &src);
        const binary = try src.word();
        const settings = try src.word();
        // Every trial is leak-checked; every third also sweeps each allocation failure.
        checkArgv(arena, binary, settings, opts, trial % 3 < 2 and trial < 2 or trial % 3 == 0) catch |err| {
            std.debug.print("buildArgv property failed: trial={d} bits=0x{x} max_turns={d}\n", .{ trial, bits, max_turns });
            return err;
        };
    }
}

/// Input: 4 bytes option bitmask, 4 bytes max_turns, then NUL-separated words.
fn fuzzBuildArgv(_: void, input: []const u8) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var head: [8]u8 = @splat(0);
    const n = @min(input.len, head.len);
    @memcpy(head[0..n], input[0..n]);
    const bits = std.mem.readInt(u32, head[0..4], .little);
    const max_turns = std.mem.readInt(u32, head[4..8], .little);
    var src: WordSource = .{ .input = std.mem.splitScalar(u8, input[n..], 0) };
    const opts = try optionsFromBits(arena, bits, max_turns, &src);
    const binary = try src.word();
    const settings = try src.word();
    try checkArgv(arena, binary, settings, opts, true);
}

test "fuzz: buildArgv" {
    try testing.fuzz({}, fuzzBuildArgv, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xffprompt\x00opus\x00Bash,Read\x00sess\x00id\x00sys\x00app\x00plan\x00Write\x00sonnet\x00user\x00/a\x00/b\x00/c\x00m1\x00m2\x00m3\x00--x\x00y",
        "\x02\x00\x00\x00\x00\x00\x00\x00p",
        "\x02\x00\x00\x00\x0a\x00\x00\x00p\x00claude\x00{}",
        "\x30\x00\x1c\x00\x01\x00\x00\x00p\x00sid\x00--resume\x00-c\x00it's\x00claude\x00{\"hooks\":{}}",
        "\x00\xc0\x03\x00\x00\x00\x00\x00p\x00--model\x00--add-dir\x00--mcp-config\x00'\x00\\",
    } });
}
