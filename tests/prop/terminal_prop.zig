const std = @import("std");
const testing = std.testing;
const respond = @import("claude_p").terminal.respondToDecQueries;
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
        "",
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
