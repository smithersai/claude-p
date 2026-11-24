const std = @import("std");
const testing = std.testing;
const respond = @import("claude_p").terminal.respondToDecQueries;
const terminal = @import("claude_p").terminal;
const DecDecoder = terminal.DecDecoder;
const Bytes = std.ArrayList(u8);

const Query = struct { request: []const u8, reply: []const u8 };
const queries = [_]Query{
    .{ .request = "\x1b[c", .reply = "\x1b[?1;2c" },
    .{ .request = "\x1b[0c", .reply = "\x1b[?1;2c" },
    .{ .request = "\x1b[>c", .reply = "\x1b[>0;0;0c" },
    .{ .request = "\x1b[>0c", .reply = "\x1b[>0;0;0c" },
    .{ .request = "\x1b[6n", .reply = "\x1b[1;1R" },
    .{ .request = "\x1b[>q", .reply = "\x1bP>|claude-p\x1b\\" },
    .{ .request = "\x1b[>0q", .reply = "\x1bP>|claude-p\x1b\\" },
    .{ .request = "\x1b[18t", .reply = "\x1b[8;40;120t" },
};

// Each documented request contains exactly one ESC. Look for whole literals
// at every ESC independently of the production CSI scanner.
fn expectExactReplies(input: []const u8, output: []const u8) !void {
    var replies = output;
    var escapes = std.mem.splitScalar(u8, input, 0x1b);
    _ = escapes.next(); // bytes before the first ESC
    while (escapes.next()) |after_escape| {
        for (queries) |query| {
            if (!std.mem.startsWith(u8, after_escape, query.request[1..])) continue;
            const token_len = @min(replies.len, query.reply.len);
            try testing.expectEqualSlices(u8, query.reply, replies[0..token_len]);
            replies = replies[token_len..];
            break;
        }
    }
    try testing.expectEqualSlices(u8, "", replies);
}

fn fuzzOne(_: void, input: []const u8) !void {
    var output: Bytes = .empty;
    defer output.deinit(testing.allocator);
    try respond(testing.allocator, input, &output);
    try expectExactReplies(input, output.items);
}

const all_requests = "\x1b[c\x1b[0c\x1b[>c\x1b[>0c\x1b[6n\x1b[>q\x1b[>0q\x1b[18t";

test "terminal fuzz emits exactly the reply tokens requested by arbitrary bytes" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "\x00\xff\x80\x9b6n",
        "\x1b",
        "\x1b[",
        "\x1b[>",
        "\x1b[?",
        "\x1bP",
        "\x1b]0;title\x07",
        "\x1bP>|claude-p\x1b\\",
        all_requests,
        "\x1b[\x1b[c",
        "\x1b[?1;2c",
        "\x1b[>0;0;0c",
        "\x1b[>9q",
        "\x1b[>6n\x1b[>18t",
        "\x1b[18\x00t\x1b[!\xff\x1b[>0",
        "\x1b[" ++ "0;" ** 256 ++ "!c" ++ all_requests,
        all_requests ** 16 ++ "\x1b[18",
    } });
}

const fragments = [_][]const u8{
    "\x1b",         "\x1b[",            "\x1b[>",   "\x1b[?",    "\x1bP",     "\x1b]",   "\x1b\\",
    "\x1b[1c",      "\x1b[>1q",         "\x1b[?6n", "\x1b[018t", "\x1b[>18t", "\x1b[!c", "\x1b[?1;2c",
    "\x1b[>0;0;0c", "\x1b]0;title\x07", "18t",      "[c",        "0q",        "6n",      "\x00",
    "\xff\x80",     "\x1b[\x1b[>q",
};

fn appendMixed(input: *Bytes, random: std.Random) !void {
    const count = random.uintLessThan(usize, 32);
    for (0..count) |_| {
        const query = queries[random.uintLessThan(usize, queries.len)].request;
        switch (random.uintLessThan(u8, 5)) {
            0, 1 => try input.appendSlice(testing.allocator, query),
            2 => try input.appendSlice(testing.allocator, fragments[random.uintLessThan(usize, fragments.len)]),
            3 => try input.appendSlice(testing.allocator, query[0..random.uintLessThan(usize, query.len)]),
            4 => random.bytes(try input.addManyAsSlice(testing.allocator, random.uintLessThan(usize, 65))),
            else => unreachable,
        }
    }
}

test "terminal exact replies and NUL-separated concatenation on 4096 adversarial streams" {
    const seed = 0xdec_18_2026;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var input: Bytes = .empty;
    var joined: Bytes = .empty;
    var separate: Bytes = .empty;
    defer input.deinit(testing.allocator);
    defer joined.deinit(testing.allocator);
    defer separate.deinit(testing.allocator);

    for (0..4096) |trial| {
        errdefer std.debug.print("terminal seed=0x{x}, trial={d}\n", .{ seed, trial });
        input.clearRetainingCapacity();
        separate.clearRetainingCapacity();
        joined.clearRetainingCapacity();

        try appendMixed(&input, random);
        if (trial % 512 == 0) {
            random.bytes(try input.addManyAsSlice(testing.allocator, 128 * 1024));
            try input.appendSlice(testing.allocator, all_requests);
        }
        const split = input.items.len;
        // No request contains NUL, so no query can straddle this boundary.
        try input.append(testing.allocator, 0);
        try appendMixed(&input, random);
        if (trial % 2 == 0) {
            const query = queries[random.uintLessThan(usize, queries.len)].request;
            try input.appendSlice(testing.allocator, query[0..random.intRangeLessThan(usize, 1, query.len)]);
        }

        try respond(testing.allocator, input.items, &joined);
        try expectExactReplies(input.items, joined.items);
        try respond(testing.allocator, input.items[0..split], &separate);
        try respond(testing.allocator, input.items[split + 1 ..], &separate);
        try testing.expectEqualSlices(u8, joined.items, separate.items);
    }
}

fn denseAllocationFailures(allocator: std.mem.Allocator) !void {
    const input = (all_requests ++ "\xff\x00\x1b[?1;2c\x1b[") ** 128;
    var output: Bytes = .empty;
    defer output.deinit(allocator);
    try respond(allocator, input, &output);
    try expectExactReplies(input, output.items);
}

test "terminal propagates every allocation failure while accumulating dense replies" {
    try testing.checkAllAllocationFailures(testing.allocator, denseAllocationFailures, .{});
}

// ---------------------------------------------------------------------------
// DecDecoder: queries split across PTY reads, and window-size dimensions
// ---------------------------------------------------------------------------

/// Feed `input` cut at `cuts` (ascending offsets) into one decoder.
fn feedSplit(decoder: *DecDecoder, input: []const u8, cuts: []const usize, out: *Bytes) !void {
    var start: usize = 0;
    for (cuts) |cut| {
        try decoder.feed(testing.allocator, input[start..cut], out);
        start = cut;
    }
    try decoder.feed(testing.allocator, input[start..], out);
}

fn expectSplitParity(input: []const u8, cuts: []const usize) !void {
    var whole: Bytes = .empty;
    defer whole.deinit(testing.allocator);
    var split: Bytes = .empty;
    defer split.deinit(testing.allocator);
    try respond(testing.allocator, input, &whole);
    var decoder: DecDecoder = .{};
    try feedSplit(&decoder, input, cuts, &split);
    errdefer std.debug.print("input={any} cuts={any}\n", .{ input, cuts });
    try testing.expectEqualSlices(u8, whole.items, split.items);
}

test "decoder answers every supported query split at every byte offset" {
    for (queries) |query| {
        // Two feeds, cut at every offset including both ends.
        for (0..query.request.len + 1) |cut| {
            var out: Bytes = .empty;
            defer out.deinit(testing.allocator);
            var decoder: DecDecoder = .{};
            try feedSplit(&decoder, query.request, &.{cut}, &out);
            try testing.expectEqualSlices(u8, query.reply, out.items);
            try testing.expectEqual(@as(usize, 0), decoder.carry_len);
            try expectSplitParity(query.request, &.{cut});
        }
        // One byte per feed; the reply appears with the final byte, not before.
        var out: Bytes = .empty;
        defer out.deinit(testing.allocator);
        var decoder: DecDecoder = .{};
        for (query.request, 0..) |byte, i| {
            try testing.expectEqual(@as(usize, 0), out.items.len);
            try testing.expectEqual(i, decoder.carry_len);
            try decoder.feed(testing.allocator, &.{byte}, &out);
        }
        try testing.expectEqualSlices(u8, query.reply, out.items);
    }
}

test "decoder matches unsplit output for every 1- and 2-cut split of mixed streams" {
    const streams = [_][]const u8{
        all_requests,
        "hi\x1b[cthere\x1b[>cyo\x1b[18t!",
        "\x1b\x1b[\x1b[6n\x1b[>\x1b[>0q\x1b[1c\x1b[?6n\x1b[018t\x1b[!c\x1b[0!c",
        "\x1b]0;title\x07\x1b[6n\x1bP>|claude-p\x1b\\\x1b[c\x1b",
        "\x1b[" ++ "0;" ** 20 ++ "c\x1b[c\x1b[" ++ "1" ** 29 ++ "c\x1b[" ++ "1" ** 30 ++ "c\x1b[" ++ "1" ** 31 ++ "c\x1b[6n",
        "\x1b[18\x00t\x1b[!\xff\x1b[>0\x1b[18",
    };
    for (streams) |stream| {
        try expectSplitParity(stream, &.{});
        for (0..stream.len + 1) |first| {
            try expectSplitParity(stream, &.{first});
            for (first..stream.len + 1) |second| {
                try expectSplitParity(stream, &.{ first, second });
            }
        }
        // One byte at a time.
        var whole: Bytes = .empty;
        defer whole.deinit(testing.allocator);
        var streamed: Bytes = .empty;
        defer streamed.deinit(testing.allocator);
        try respond(testing.allocator, stream, &whole);
        var decoder: DecDecoder = .{};
        for (stream) |byte| try decoder.feed(testing.allocator, &.{byte}, &streamed);
        try testing.expectEqualSlices(u8, whole.items, streamed.items);
    }
}

test "decoder matches unsplit output under random chunking of 2048 adversarial streams" {
    const seed = 0xdec_15_2026;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var input: Bytes = .empty;
    var whole: Bytes = .empty;
    var chunked: Bytes = .empty;
    defer input.deinit(testing.allocator);
    defer whole.deinit(testing.allocator);
    defer chunked.deinit(testing.allocator);

    for (0..2048) |trial| {
        errdefer std.debug.print("decoder seed=0x{x}, trial={d}\n", .{ seed, trial });
        input.clearRetainingCapacity();
        whole.clearRetainingCapacity();
        chunked.clearRetainingCapacity();
        try appendMixed(&input, random);
        try appendMixed(&input, random);

        try respond(testing.allocator, input.items, &whole);
        try expectExactReplies(input.items, whole.items);

        var decoder: DecDecoder = .{};
        var pos: usize = 0;
        const max_chunk: usize = if (trial % 4 == 0) 1 else 1 + random.uintLessThan(usize, 9);
        while (pos < input.items.len) {
            const len = @min(input.items.len - pos, random.uintAtMost(usize, max_chunk));
            try decoder.feed(testing.allocator, input.items[pos .. pos + len], &chunked);
            try testing.expect(decoder.carry_len <= decoder.carry.len);
            pos += len;
        }
        try testing.expectEqualSlices(u8, whole.items, chunked.items);
    }
}

test "window-size reply carries the configured rows and cols" {
    var prng = std.Random.DefaultPrng.init(0xdec_16_2026);
    const random = prng.random();
    var out: Bytes = .empty;
    defer out.deinit(testing.allocator);
    var want_buf: [32]u8 = undefined;
    const request = "\x1b[18t";

    const edge = [_][2]u16{ .{ 40, 120 }, .{ 0, 0 }, .{ 1, 1 }, .{ 24, 80 }, .{ 65535, 65535 }, .{ 120, 40 } };
    for (0..512) |trial| {
        const rows: u16 = if (trial < edge.len) edge[trial][0] else random.int(u16);
        const cols: u16 = if (trial < edge.len) edge[trial][1] else random.int(u16);
        const want = try std.fmt.bufPrint(&want_buf, "\x1b[8;{d};{d}t", .{ rows, cols });

        out.clearRetainingCapacity();
        try terminal.respondToDecQueriesSized(testing.allocator, request, rows, cols, &out);
        try testing.expectEqualSlices(u8, want, out.items);

        // Same reply when the query arrives split, at every offset.
        for (0..request.len + 1) |cut| {
            out.clearRetainingCapacity();
            var decoder: DecDecoder = .{ .rows = rows, .cols = cols };
            try feedSplit(&decoder, request, &.{cut}, &out);
            try testing.expectEqualSlices(u8, want, out.items);
        }

        // The other replies do not depend on the dimensions.
        out.clearRetainingCapacity();
        try terminal.respondToDecQueriesSized(testing.allocator, all_requests[0 .. all_requests.len - request.len], rows, cols, &out);
        try expectExactReplies(all_requests[0 .. all_requests.len - request.len], out.items);
    }

    // Defaults stay 40x120.
    out.clearRetainingCapacity();
    try respond(testing.allocator, request, &out);
    try testing.expectEqualSlices(u8, "\x1b[8;40;120t", out.items);
    const fresh: DecDecoder = .{};
    try testing.expectEqual(@as(u16, 40), fresh.rows);
    try testing.expectEqual(@as(u16, 120), fresh.cols);
}

fn decoderAllocationFailures(allocator: std.mem.Allocator) !void {
    const input = (all_requests ++ "\xff\x00\x1b[?1;2c\x1b[") ** 32;
    var output: Bytes = .empty;
    defer output.deinit(allocator);
    var decoder: DecDecoder = .{ .rows = 50, .cols = 132 };
    var pos: usize = 0;
    while (pos < input.len) : (pos += 3) {
        try decoder.feed(allocator, input[pos..@min(pos + 3, input.len)], &output);
    }
}

test "decoder propagates every allocation failure while streaming" {
    try testing.checkAllAllocationFailures(testing.allocator, decoderAllocationFailures, .{});
}

test "PTY callback preserves every DEC reply in a burst larger than 256 bytes" {
    const driver = @import("claude_p").driver;
    const burst = ("\x1b[>q\x1b[c" ** 80);
    const expected = ("\x1bP>|claude-p\x1b\\\x1b[?1;2c" ** 80);
    for ([_]usize{ burst.len, 13, 1 }) |chunk_size| {
        var shared: driver.SharedState = .{ .session = undefined, .debug = false };
        defer shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.startup_done.store(true, .seq_cst);
        var pos: usize = 0;
        while (pos < burst.len) {
            const end = @min(pos + chunk_size, burst.len);
            driver.onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = burst[pos..end] } });
            pos = end;
        }
        try testing.expectEqualStrings(expected, shared.pending_to_pty.items);
    }
}
