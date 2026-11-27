//! Property-based & fuzz tests for `hook/settings.zig`.
const std = @import("std");
const claude_p = @import("claude_p");
const settings = claude_p.hook.settings;

test "prop: shellSingleQuote always starts and ends with single quotes" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5e77_0001);
    const rng = prng.random();
    for (0..128) |_| {
        const len = rng.intRangeAtMost(usize, 0, 64);
        const buf = try t.allocator.alloc(u8, len);
        defer t.allocator.free(buf);
        rng.bytes(buf);
        const q = try settings.shellSingleQuote(t.allocator, buf);
        defer t.allocator.free(q);
        try t.expect(q.len >= 2 and q[0] == '\'' and q[q.len - 1] == '\'');
    }
}

test "prop: jsonNestingDepth never exceeds input length" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5e77_0002);
    const rng = prng.random();
    const alphabet = "{}[]\"\\abc123,: ";
    for (0..128) |_| {
        const len = rng.intRangeAtMost(usize, 0, 96);
        const buf = try t.allocator.alloc(u8, len);
        defer t.allocator.free(buf);
        for (buf) |*b| b.* = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
        try t.expect(settings.jsonNestingDepth(buf) <= len);
    }
}

test "fuzz: validateExtraSettings never panics on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn check(_: void, input: []const u8) !void {
            if (input.len == 0) return;
            settings.validateExtraSettings(std.testing.allocator, .{
                .extra_settings_json = input,
            }) catch {};
        }
    }.check, .{ .corpus = &.{
        "{}",
        "{\"disableAllHooks\":true}",
        "{\"a\":[1,2,3]}",
        "not json",
    } });
}
