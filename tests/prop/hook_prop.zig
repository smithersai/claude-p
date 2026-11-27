//! Property-based and fuzz tests for `src/hook.zig`.
//!
//! Covers `parseLine`, `HookEvent.fromString`, the four payload extractors,
//! `buildSettingsJson`, and `createWithOptions`. Every PRNG property prints its
//! seed and trial number on failure so a failing case replays exactly.
const std = @import("std");
const hook = @import("claude_p").hook;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Buf = std.ArrayList(u8);

const relay_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest" };
const field_names = [_][]const u8{ "transcript_path", "last_assistant_message", "session_id", "prompt" };
const Extractor = *const fn (Allocator, []const u8) anyerror!?[]u8;

fn exTranscript(a: Allocator, p: []const u8) anyerror!?[]u8 {
    return hook.extractTranscriptPath(a, p);
}
fn exLast(a: Allocator, p: []const u8) anyerror!?[]u8 {
    return hook.extractLastAssistantMessage(a, p);
}
fn exSession(a: Allocator, p: []const u8) anyerror!?[]u8 {
    return hook.extractSessionId(a, p);
}
fn exPrompt(a: Allocator, p: []const u8) anyerror!?[]u8 {
    return hook.extractPrompt(a, p);
}
const extractors = [_]Extractor{ exTranscript, exLast, exSession, exPrompt };

fn reportTrial(name: []const u8, seed: u64, trial: usize) void {
    std.debug.print("\n[hook_prop] {s}: FAILED seed=0x{x} trial={d}\n", .{ name, seed, trial });
}

// ---------------------------------------------------------------------------
// Allocators
// ---------------------------------------------------------------------------

/// Exact per-trial leak detector over a fixed buffer.
///
/// `std.testing.allocator` costs about 1 ms per `std.json` parse in Debug
/// builds, which would put the high-iteration properties far over budget. This
/// allocator counts live allocations and bytes, so `expectClean` after every
/// trial pins a leak to the trial that caused it. `pick` still routes a
/// sampled subset of trials through `std.testing.allocator` for its
/// double-free and use-after-free checks.
const LeakCheck = struct {
    buf: []u8,
    fba: std.heap.FixedBufferAllocator,
    live_count: usize = 0,
    live_bytes: usize = 0,

    const sample_every = 100;

    fn init() !LeakCheck {
        const buf = try std.heap.page_allocator.alloc(u8, 8 << 20);
        return .{ .buf = buf, .fba = std.heap.FixedBufferAllocator.init(buf) };
    }
    fn deinit(self: *LeakCheck) void {
        std.heap.page_allocator.free(self.buf);
    }
    fn allocator(self: *LeakCheck) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    /// The allocator for `trial`: usually this one, periodically `testing.allocator`.
    fn pick(self: *LeakCheck, trial: usize) Allocator {
        return if (trial % sample_every == sample_every - 1) testing.allocator else self.allocator();
    }
    /// Fails if the code under test still holds memory; recycles the buffer.
    fn expectClean(self: *LeakCheck) !void {
        if (self.live_count != 0 or self.live_bytes != 0) {
            std.debug.print("leak: {d} allocations, {d} bytes still live\n", .{ self.live_count, self.live_bytes });
            return error.TestLeak;
        }
        self.fba.reset();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *LeakCheck = @ptrCast(@alignCast(ctx));
        const ptr = self.fba.allocator().rawAlloc(len, alignment, ra) orelse return null;
        self.live_count += 1;
        self.live_bytes += len;
        return ptr;
    }
    fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *LeakCheck = @ptrCast(@alignCast(ctx));
        if (!self.fba.allocator().rawResize(mem, alignment, new_len, ra)) return false;
        self.live_bytes = self.live_bytes - mem.len + new_len;
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *LeakCheck = @ptrCast(@alignCast(ctx));
        const ptr = self.fba.allocator().rawRemap(mem, alignment, new_len, ra) orelse return null;
        self.live_bytes = self.live_bytes - mem.len + new_len;
        return ptr;
    }
    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *LeakCheck = @ptrCast(@alignCast(ctx));
        self.fba.allocator().rawFree(mem, alignment, ra);
        self.live_count -= 1;
        self.live_bytes -= mem.len;
    }
};

test "LeakCheck reports a leaked allocation" {
    var lc = try LeakCheck.init();
    defer lc.deinit();
    const a = lc.allocator();
    const kept = try a.alloc(u8, 7);
    const freed = try a.alloc(u8, 9);
    a.free(freed);
    try testing.expectEqual(@as(usize, 1), lc.live_count);
    try testing.expectEqual(@as(usize, 7), lc.live_bytes);
    a.free(kept);
    try lc.expectClean();
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

const metas = "\"\\'/$`|;&<>(){}[]:,*?~#!= ";

fn genCodepoint(r: Random, allow_nul: bool) u21 {
    while (true) {
        const cp: u21 = switch (r.uintLessThan(u8, 12)) {
            0...3 => r.intRangeAtMost(u21, 0x20, 0x7e),
            4 => metas[r.uintLessThan(usize, metas.len)],
            5 => if (r.boolean()) r.intRangeAtMost(u21, 0x00, 0x1f) else 0x7f,
            6 => ([_]u21{ '\n', '\r', '\t' })[r.uintLessThan(usize, 3)],
            7 => r.intRangeAtMost(u21, 0x80, 0x7ff),
            8 => blk: {
                const c = r.intRangeAtMost(u21, 0x800, 0xffff);
                break :blk if (c >= 0xd800 and c <= 0xdfff) 0xfffd else c;
            },
            9 => r.intRangeAtMost(u21, 0x10000, 0x10ffff),
            10 => ([_]u21{ 0x1F600, 0x1F469, 0x200D, 0xFE0F, 0x1F4A9, 0x1F680, 0x1F1FA, 0x1F1F8 })[r.uintLessThan(usize, 8)],
            else => ([_]u21{ 0x2028, 0x2029, 0xFEFF, 0xFFFD, 0xFFFF, 0xD7FF, 0xE000, 0x10FFFF, 0x7f, 0x80 })[r.uintLessThan(usize, 10)],
        };
        if (cp == 0 and !allow_nul) continue;
        return cp;
    }
}

fn appendCp(a: Allocator, out: *Buf, cp: u21) !void {
    var b: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &b);
    try out.appendSlice(a, b[0..n]);
}

/// Random valid UTF-8 of 0..max_cps codepoints.
fn genUtf8(a: Allocator, r: Random, max_cps: usize, allow_nul: bool) ![]u8 {
    var out: Buf = .empty;
    const n = r.uintAtMost(usize, max_cps);
    for (0..n) |_| try appendCp(a, &out, genCodepoint(r, allow_nul));
    return out.toOwnedSlice(a);
}

fn genBytes(a: Allocator, r: Random, max_len: usize) ![]u8 {
    const out = try a.alloc(u8, r.uintAtMost(usize, max_len));
    for (out) |*b| {
        b.* = switch (r.uintLessThan(u8, 8)) {
            0 => '\t',
            1 => '\n',
            2 => '\r',
            3 => 0,
            4 => r.intRangeAtMost(u8, 0x80, 0xff),
            else => r.int(u8),
        };
    }
    return out;
}

fn writeHex4(a: Allocator, r: Random, out: *Buf, unit: u16) !void {
    var b: [6]u8 = undefined;
    const s = if (r.boolean())
        std.fmt.bufPrint(&b, "\\u{x:0>4}", .{unit}) catch unreachable
    else
        std.fmt.bufPrint(&b, "\\u{X:0>4}", .{unit}) catch unreachable;
    try out.appendSlice(a, s);
}

fn writeUnicodeEscape(a: Allocator, r: Random, out: *Buf, cp: u21) !void {
    if (cp <= 0xffff) return writeHex4(a, r, out, @intCast(cp));
    const v = cp - 0x10000;
    try writeHex4(a, r, out, @intCast(0xd800 + (v >> 10)));
    try writeHex4(a, r, out, @intCast(0xdc00 + (v & 0x3ff)));
}

/// Hand-rolled JSON string encoder, independent of `std.json.Stringify`, that
/// randomly picks among every legal encoding of each codepoint.
fn writeJsonString(a: Allocator, r: Random, out: *Buf, s: []const u8) !void {
    try out.append(a, '"');
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const short: ?u8 = switch (cp) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            0x08 => 'b',
            0x0c => 'f',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            else => null,
        };
        const must_escape = cp < 0x20 or cp == '"' or cp == '\\';
        if (must_escape or r.uintLessThan(u8, 6) == 0) {
            if (short != null and r.boolean()) {
                try out.append(a, '\\');
                try out.append(a, short.?);
            } else {
                try writeUnicodeEscape(a, r, out, cp);
            }
        } else {
            try appendCp(a, out, cp);
        }
    }
    try out.append(a, '"');
}

fn ws(a: Allocator, r: Random, out: *Buf) !void {
    if (r.uintLessThan(u8, 3) != 0) return;
    for (0..r.uintAtMost(usize, 2)) |_| try out.append(a, " \n\t\r"[r.uintLessThan(usize, 4)]);
}

const number_pool = [_][]const u8{
    "0",                              "-0",          "1",       "-1",      "42",     "1e400",   "-1E-400",
    "0.1234567890123456789",          "1.5E+10",     "1E+2",    "0e0",     "0.0",    "-0.0e-0", "9007199254740993",
    "123456789012345678901234567890", "-2147483649", "3.14159", "1e-9999", "1.0e00",
};

fn genNumberLiteral(a: Allocator, r: Random, out: *Buf) !void {
    if (r.boolean()) try out.append(a, '-');
    if (r.uintLessThan(u8, 5) == 0) {
        try out.append(a, '0');
    } else {
        try out.append(a, r.intRangeAtMost(u8, '1', '9'));
        for (0..r.uintAtMost(usize, 30)) |_| try out.append(a, r.intRangeAtMost(u8, '0', '9'));
    }
    if (r.boolean()) {
        try out.append(a, '.');
        for (0..r.intRangeAtMost(usize, 1, 25)) |_| try out.append(a, r.intRangeAtMost(u8, '0', '9'));
    }
    if (r.uintLessThan(u8, 3) == 0) {
        try out.append(a, if (r.boolean()) 'e' else 'E');
        switch (r.uintLessThan(u8, 3)) {
            0 => try out.append(a, '+'),
            1 => try out.append(a, '-'),
            else => {},
        }
        for (0..r.intRangeAtMost(usize, 1, 4)) |_| try out.append(a, r.intRangeAtMost(u8, '0', '9'));
    }
}

const key_pool = [_][]const u8{
    "env",    "model", "permissions", "includeCoAuthoredBy", "cleanupPeriodDays", "",      "a",
    "Stop",   "hook",  "Hooks",       "hooks ",              "matcher",           "type",  "command",
    "prompt", "x y",   "__proto__",   "SessionStart",        "session_id",        "ho\"k", "k\\",
};

fn genKey(a: Allocator, r: Random, out: *Buf, allow_hooks: bool) !void {
    switch (r.uintLessThan(u8, 10)) {
        0 => if (allow_hooks) {
            // "hooks", plain or disguised through escapes.
            const forms = [_][]const u8{ "\"hooks\"", "\"\\u0068ooks\"", "\"h\\u006fo\\u006Bs\"", "\"\\u0068\\u006f\\u006f\\u006b\\u0073\"" };
            try out.appendSlice(a, forms[r.uintLessThan(usize, forms.len)]);
        } else try writeJsonString(a, r, out, key_pool[r.uintLessThan(usize, key_pool.len)]),
        1, 2 => try writeJsonString(a, r, out, try genUtf8(a, r, 6, true)),
        else => try writeJsonString(a, r, out, key_pool[r.uintLessThan(usize, key_pool.len)]),
    }
}

/// `uniq` suffixes every object key with its index so no object repeats a key
/// (the extractors parse with the default duplicate-key policy, which rejects
/// the whole document).
fn genValue(a: Allocator, r: Random, out: *Buf, depth: usize, uniq: bool) Allocator.Error!void {
    const pick = r.uintLessThan(u8, if (depth == 0) 6 else 10);
    switch (pick) {
        0 => try out.appendSlice(a, "null"),
        1 => try out.appendSlice(a, if (r.boolean()) "true" else "false"),
        2 => try out.appendSlice(a, number_pool[r.uintLessThan(usize, number_pool.len)]),
        3 => genNumberLiteral(a, r, out) catch return error.OutOfMemory,
        4, 5 => writeJsonString(a, r, out, genUtf8(a, r, 12, true) catch return error.OutOfMemory) catch return error.OutOfMemory,
        6, 7 => {
            try out.append(a, '[');
            const n = r.uintAtMost(usize, 3);
            for (0..n) |i| {
                if (i != 0) try out.append(a, ',');
                try ws(a, r, out);
                try genValue(a, r, out, depth - 1, uniq);
                try ws(a, r, out);
            }
            if (n == 0) try ws(a, r, out);
            try out.append(a, ']');
        },
        else => try genObject(a, r, out, depth - 1, uniq),
    }
}

fn genObject(a: Allocator, r: Random, out: *Buf, depth: usize, uniq: bool) Allocator.Error!void {
    try out.append(a, '{');
    const n = r.uintAtMost(usize, 3);
    for (0..n) |i| {
        if (i != 0) try out.append(a, ',');
        try ws(a, r, out);
        if (uniq) {
            var kb: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{s}#{d}", .{ field_names[r.uintLessThan(usize, 4)], i }) catch unreachable;
            writeJsonString(a, r, out, k) catch return error.OutOfMemory;
        } else genKey(a, r, out, true) catch return error.OutOfMemory;
        try ws(a, r, out);
        try out.append(a, ':');
        try ws(a, r, out);
        try genValue(a, r, out, depth, uniq);
        try ws(a, r, out);
    }
    if (n == 0) try ws(a, r, out);
    try out.append(a, '}');
}

/// Marker that only ever appears inside generated top-level `"hooks"` values.
const evil_marker = "EVIL_MARKER_7f3a";

const evil_hooks_values = [_][]const u8{
    "{}",
    "\"" ++ evil_marker ++ "\"",
    "null",
    "[]",
    "0",
    "{\"Stop\":[]}",
    "{\"SessionStart\":null,\"UserPromptSubmit\":\"" ++ evil_marker ++ "\",\"Stop\":[]}",
    "{\"Stop\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"" ++ evil_marker ++ "\"}]}],\"Evil\":[]}",
    "{\"SessionStart\":[{\"matcher\":\"" ++ evil_marker ++ "\",\"hooks\":[]}],\"" ++ evil_marker ++ "\":[]}",
    "[{\"Stop\":\"" ++ evil_marker ++ "\"}]",
    "{\"hooks\":{\"hooks\":\"" ++ evil_marker ++ "\"}}",
};

/// A random valid JSON object for `extra_settings_json`, frequently carrying
/// one or more adversarial top-level `"hooks"` members.
fn genSettingsObject(a: Allocator, r: Random) ![]u8 {
    var out: Buf = .empty;
    try ws(a, r, &out);
    try out.append(a, '{');
    const n = r.uintAtMost(usize, 7);
    for (0..n) |i| {
        if (i != 0) try out.append(a, ',');
        try ws(a, r, &out);
        const is_hooks = r.uintLessThan(u8, 3) == 0;
        if (is_hooks) {
            // "hooks", plain or disguised through escapes.
            const forms = [_][]const u8{ "\"hooks\"", "\"\\u0068ooks\"", "\"hook\\u0073\"", "\"\\u0068\\u006f\\u006F\\u006b\\u0073\"" };
            try out.appendSlice(a, forms[r.uintLessThan(usize, forms.len)]);
        } else {
            try genKey(a, r, &out, false);
        }
        try ws(a, r, &out);
        try out.append(a, ':');
        try ws(a, r, &out);
        if (is_hooks) {
            try out.appendSlice(a, evil_hooks_values[r.uintLessThan(usize, evil_hooks_values.len)]);
        } else {
            try genValue(a, r, &out, 4, false);
        }
        try ws(a, r, &out);
    }
    if (n == 0) try ws(a, r, &out);
    try out.append(a, '}');
    try ws(a, r, &out);
    return out.toOwnedSlice(a);
}

const malformed_settings = [_][]const u8{
    "",                           " ",                     "\n\t",             "{{",                       "}",
    "[]",                         "[{}]",                  "null",             "true",                     "false",
    "42",                         "-0.5e3",                "\"str\"",          "\"{}\"",                   "{} trailing",
    "{}{}",                       "{},",                   "{\"a\":1,}",       "{'a':1}",                  "{a:1}",
    "{\"a\":01}",                 "{\"a\":NaN}",           "{\"a\":Infinity}", "{\"a\":+1}",               "{\"a\":.5}",
    "{\"a\":1.}",                 "{\"a\"}",               "{\"a\":}",         "{\"a\" 1}",                "{\"a\":1 \"b\":2}",
    "{\"a\":\"\x01\"}",           "{\"a\":\"\n\"}",        "{\"a\":\"\\x\"}",  "{\"a\":\"\\u12\"}",        "{\"a\":\"\\ud800\"}",
    "{\"a\":\"\\udc00\\ud800\"}", "{\"a\":\"\xff\"}",      "{\"a\":\"\xc3\"}", "{\"a\":\"\xed\xa0\x80\"}", "{\"\xff\":1}",
    "\xef\xbb\xbf{}",             "{}\x00",                "\x00{}",           "// c\n{}",                 "{/* c */}",
    "{\"hooks\":{}",              "{\"hooks\":\"evil\"}}", "[\"hooks\"]",      "\"hooks\"",                "{\"a\":[1,2}",
    "{\"a\":{\"b\":[}}",          "{\"a\":tru}",           "{\"a\":nul}",      "{\"a\":\"unterminated}",   "{\"a\":1}}",
    "{{}}",                       "{[]}",                  "{null:1}",         "{1:1}",                    "{\"a\":1;\"b\":2}",
    "{\"a\":0x10}",               "{\"a\":1e}",            "{\"a\":--1}",      "{\"a\":\"\\\"}",           "{\"a\":'b'}",
};

fn genMalformedSettings(a: Allocator, r: Random) ![]const u8 {
    switch (r.uintLessThan(u8, 8)) {
        0, 1 => return malformed_settings[r.uintLessThan(usize, malformed_settings.len)],
        2, 3 => {
            // Strict prefix of a valid object: always unterminated.
            const valid = std.mem.trim(u8, try genSettingsObject(a, r), " \n\t\r");
            return valid[0..r.uintLessThan(usize, valid.len)];
        },
        4 => {
            // Valid JSON, but the top level is not an object.
            var out: Buf = .empty;
            switch (r.uintLessThan(u8, 3)) {
                0 => {
                    try out.append(a, '[');
                    try out.appendSlice(a, try genSettingsObject(a, r));
                    try out.append(a, ']');
                },
                1 => try writeJsonString(a, r, &out, try genUtf8(a, r, 10, true)),
                else => try out.appendSlice(a, number_pool[r.uintLessThan(usize, number_pool.len)]),
            }
            return out.toOwnedSlice(a);
        },
        5 => {
            // Valid object followed by garbage.
            const tails = [_][]const u8{ "x", "{}", ",", "]", "}", "\x00", "null", "\"", "\xff" };
            return std.mem.concat(a, u8, &.{ try genSettingsObject(a, r), tails[r.uintLessThan(usize, tails.len)] });
        },
        6 => {
            // Invalid UTF-8 inside a string value.
            const bad = [_][]const u8{ "\xff", "\xc3", "\xe2\x82", "\xf0\x9f\x98", "\xed\xa0\x80", "\xc0\x80", "\xf8\x88\x80\x80\x80" };
            return std.mem.concat(a, u8, &.{ "{\"k\":\"ab", bad[r.uintLessThan(usize, bad.len)], "cd\"}" });
        },
        else => {
            // Nested deeper than the library accepts.
            const depth = hook.max_extra_settings_depth + 1 + r.uintAtMost(usize, 600);
            return deepDoc(a, depth, r.boolean());
        },
    }
}

/// `{"a":[[…]]}` or `{"a":{"a":{…}}}` with exactly `depth` nested containers.
fn deepDoc(a: Allocator, depth: usize, arrays: bool) ![]u8 {
    var out: Buf = .empty;
    try out.appendSlice(a, "{\"a\":");
    for (1..depth) |_| try out.appendSlice(a, if (arrays) "[" else "{\"a\":");
    try out.append(a, '1');
    for (1..depth) |_| try out.append(a, if (arrays) ']' else '}');
    try out.append(a, '}');
    return out.toOwnedSlice(a);
}

const event_pool = [_][]const u8{
    "SessionStart",  "UserPromptSubmit", "Stop",           "Stop",    "PreToolUse", "PostToolUse", "Notification",
    "SubagentStop",  "PreCompact",       "hooks",          "stop",    "Stop ",      " Stop",       "STOP",
    "SessionStart2", "Stop\x00",         "é勾\u{1F600}", "a\"b\\c", "__proto__",  "matcher",     "*",
};

const command_pool = [_][]const u8{
    "echo hi",
    "echo \"hi\" | tee /tmp/x",
    "$(rm -rf /)",
    "`id`",
    "'; exit 1; '",
    "a\nb",
    "\\",
    "\"",
    "\"}]}],\"Stop\":[{\"matcher\":\"evil\"",
    "/tmp/hook.sh Stop",
    "x && y || z; w &",
    "cat <<'EOF'\nhi\nEOF",
    "printf '%s\\t%s\\n' \"$1\" \"$(cat)\" >> \"$fifo\"",
    "\u{1F600} \u{2028} é",
    "\x00",
    "\t",
    " ",
};

fn genExtraHooks(a: Allocator, r: Random, max: usize) ![]hook.ExtraHook {
    const n = r.uintAtMost(usize, max);
    const out = try a.alloc(hook.ExtraHook, n);
    var custom: ?[]const u8 = null;
    for (out) |*eh| {
        const event: []const u8 = switch (r.uintLessThan(u8, 10)) {
            0...2 => relay_events[r.uintLessThan(usize, relay_events.len)],
            3...6 => event_pool[r.uintLessThan(usize, event_pool.len)],
            // Repeat an earlier custom event so duplicates are common.
            7, 8 => custom orelse event_pool[r.uintLessThan(usize, event_pool.len)],
            else => blk: {
                const s = try genUtf8(a, r, 8, true);
                break :blk if (s.len == 0) "E" else s;
            },
        };
        custom = event;
        const command: []const u8 = if (r.boolean())
            command_pool[r.uintLessThan(usize, command_pool.len)]
        else blk: {
            const s = try genUtf8(a, r, 24, true);
            break :blk if (s.len == 0) "c" else s;
        };
        eh.* = .{ .event = event, .command = command };
    }
    return out;
}

const path_pool = [_][]const u8{
    "/tmp/hook.sh",
    "/tmp/claude-p-1-a/hook.sh",
    "/tmp/will's dir/hook.sh",
    "/tmp/with space/hook.sh",
    "/tmp/'''/hook.sh",
    "'",
    "''",
    "/tmp/$HOME/`id`/$(id)/hook.sh",
    "/tmp/a\"b\\c/hook.sh",
    "/tmp/new\nline/hook.sh",
    "/tmp/é勾\u{1F600}/hook.sh",
    "/tmp/a;b|c&d>e<f/hook.sh",
    "",
    "-rf",
    "~/hook.sh",
    "/tmp/tab\there/hook.sh",
    "/tmp/*?[x]/hook.sh",
    "/tmp/#!/hook.sh",
    "/tmp/a\\'b/hook.sh",
    "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T//claude-p-99-deadbeef/hook.sh",
};

fn genScriptPath(a: Allocator, r: Random) ![]const u8 {
    return switch (r.uintLessThan(u8, 3)) {
        0 => path_pool[r.uintLessThan(usize, path_pool.len)],
        1 => blk: {
            // Safe-charset path: must stay unquoted.
            const safe = "abcXYZ019/._-";
            const out = try a.alloc(u8, r.intRangeAtMost(usize, 1, 30));
            for (out) |*c| c.* = safe[r.uintLessThan(usize, safe.len)];
            break :blk out;
        },
        else => try genUtf8(a, r, 30, false),
    };
}

// ---------------------------------------------------------------------------
// Oracles
// ---------------------------------------------------------------------------

/// Minimal POSIX `sh` word splitter for the subset the relay command may use:
/// bare safe characters, single-quoted spans, and backslash escapes. Anything
/// else unquoted (expansions, operators, globs, newlines) is an injection.
fn shellWords(a: Allocator, cmd: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: Buf = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        switch (c) {
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, cmd, i + 1, '\'') orelse return error.UnterminatedQuote;
                try cur.appendSlice(a, cmd[i + 1 .. end]);
                in_word = true;
                i = end;
            },
            '\\' => {
                if (i + 1 >= cmd.len or cmd[i + 1] == '\n') return error.UnsafeShell;
                try cur.append(a, cmd[i + 1]);
                in_word = true;
                i += 1;
            },
            ' ' => if (in_word) {
                try words.append(a, try cur.toOwnedSlice(a));
                in_word = false;
            },
            else => {
                const safe = std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-';
                if (!safe) return error.UnsafeShell;
                try cur.append(a, c);
                in_word = true;
            },
        }
    }
    if (in_word) try words.append(a, try cur.toOwnedSlice(a));
    return words.toOwnedSlice(a);
}

fn valuesEqual(x: std.json.Value, y: std.json.Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    switch (x) {
        .null => return true,
        .bool => |b| return b == y.bool,
        .integer => |n| return n == y.integer,
        .float => |f| return f == y.float,
        .number_string => |s| return std.mem.eql(u8, s, y.number_string),
        .string => |s| return std.mem.eql(u8, s, y.string),
        .array => |arr| {
            if (arr.items.len != y.array.items.len) return false;
            for (arr.items, y.array.items) |p, q| if (!valuesEqual(p, q)) return false;
            return true;
        },
        .object => |obj| {
            if (obj.count() != y.object.count()) return false;
            for (obj.keys(), obj.values(), y.object.keys(), y.object.values()) |k1, v1, k2, v2| {
                if (!std.mem.eql(u8, k1, k2)) return false;
                if (!valuesEqual(v1, v2)) return false;
            }
            return true;
        },
    }
}

/// Container nesting depth of JSON text, counting brackets outside strings.
fn textDepth(json: []const u8) usize {
    var depth: usize = 0;
    var max: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                max = @max(max, depth);
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return max;
}

fn expectMatcherEntry(entry: std.json.Value, command: []const u8) !void {
    try testing.expect(entry == .object);
    try testing.expectEqual(@as(usize, 2), entry.object.count());
    try testing.expectEqualStrings("matcher", entry.object.keys()[0]);
    try testing.expectEqualStrings("*", entry.object.values()[0].string);
    try testing.expectEqualStrings("hooks", entry.object.keys()[1]);
    const inner = entry.object.values()[1].array.items;
    try testing.expectEqual(@as(usize, 1), inner.len);
    try testing.expectEqual(@as(usize, 2), inner[0].object.count());
    try testing.expectEqualStrings("type", inner[0].object.keys()[0]);
    try testing.expectEqualStrings("command", inner[0].object.values()[0].string);
    try testing.expectEqualStrings("command", inner[0].object.keys()[1]);
    try testing.expectEqualStrings(command, inner[0].object.values()[1].string);
}

/// The full contract of a successful `buildSettingsJson` result.
/// `a` must be an arena; nothing allocated here is freed individually.
fn checkSettings(
    a: Allocator,
    json: []const u8,
    script_path: []const u8,
    extra_hooks: []const hook.ExtraHook,
    extra_settings_json: ?[]const u8,
) !void {
    // Inline `--settings` value: one line of valid UTF-8, no raw control bytes.
    try testing.expect(std.unicode.utf8ValidateSlice(json));
    for (json) |c| try testing.expect(c >= 0x20);

    // Valid JSON with zero duplicate keys at any depth.
    const root_v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    try testing.expect(root_v == .object);
    const root = root_v.object;

    // Top level: caller keys (minus "hooks") verbatim and in order, then "hooks".
    var idx: usize = 0;
    if (extra_settings_json) |raw| {
        const extra = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{
            .duplicate_field_behavior = .use_last,
            .parse_numbers = false,
        });
        for (extra.object.keys(), extra.object.values()) |k, v| {
            if (std.mem.eql(u8, k, "hooks")) continue;
            try testing.expect(idx < root.count());
            try testing.expectEqualStrings(k, root.keys()[idx]);
            try testing.expect(valuesEqual(v, root.values()[idx]));
            idx += 1;
        }
    }
    try testing.expectEqual(idx + 1, root.count());
    try testing.expectEqualStrings("hooks", root.keys()[idx]);
    try testing.expect(root.values()[idx] == .object);
    const hooks = root.values()[idx].object;

    // Expected event model: relay events first, then customs in first-seen order.
    const Group = struct { event: []const u8, cmds: std.ArrayList([]const u8) };
    var groups: std.ArrayList(Group) = .empty;
    for (relay_events) |ev| try groups.append(a, .{ .event = ev, .cmds = .empty });
    for (extra_hooks) |eh| {
        const g: *Group = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.event, eh.event)) break g;
        } else blk: {
            try groups.append(a, .{ .event = eh.event, .cmds = .empty });
            break :blk &groups.items[groups.items.len - 1];
        };
        try g.cmds.append(a, eh.command);
    }

    try testing.expectEqual(groups.items.len, hooks.count());
    for (groups.items, 0..) |g, gi| {
        try testing.expectEqualStrings(g.event, hooks.keys()[gi]);
        try testing.expect(hooks.values()[gi] == .array);
        const entries = hooks.values()[gi].array.items;
        const is_relay = gi < relay_events.len;
        try testing.expectEqual(g.cmds.items.len + @intFromBool(is_relay), entries.len);

        var off: usize = 0;
        if (is_relay) {
            // Relay hook is authoritative at index 0 and names exactly our script.
            const cmd = entries[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
            try expectMatcherEntry(entries[0], cmd);
            const words = try shellWords(a, cmd);
            try testing.expectEqual(@as(usize, 2), words.len);
            try testing.expectEqualStrings(script_path, words[0]);
            try testing.expectEqualStrings(g.event, words[1]);
            off = 1;
        }
        // Extra hooks follow, verbatim and in caller order.
        for (g.cmds.items, 0..) |cmd, ci| try expectMatcherEntry(entries[off + ci], cmd);
    }
}

/// Count this process's harness directories under the temp root.
fn countOwnTmpDirs() !usize {
    const root = std.posix.getenv("TMPDIR") orelse "/tmp";
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "claude-p-{d}-", .{std.posix.system.getpid()});
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (std.mem.startsWith(u8, e.name, prefix)) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// 1. parseLine / HookEvent.fromString
// ---------------------------------------------------------------------------

fn expectedEvent(s: []const u8) hook.HookEvent {
    if (std.mem.eql(u8, s, "SessionStart")) return .session_start;
    if (std.mem.eql(u8, s, "UserPromptSubmit")) return .user_prompt_submit;
    if (std.mem.eql(u8, s, "Stop")) return .stop;
    if (std.mem.eql(u8, s, "PermissionRequest")) return .permission_request;
    if (std.mem.eql(u8, s, "StopFailure")) return .stop_failure;
    return .unknown;
}

/// Structural contract of `parseLine` for any byte string.
fn checkParseLine(raw: []const u8) !void {
    // Exactly one line terminator is tolerated: "\r\n", "\n", or a bare "\r".
    const trimmed = if (std.mem.endsWith(u8, raw, "\r\n"))
        raw[0 .. raw.len - 2]
    else if (std.mem.endsWith(u8, raw, "\n") or std.mem.endsWith(u8, raw, "\r"))
        raw[0 .. raw.len - 1]
    else
        raw;

    const got = hook.parseLine(raw);
    const first_tab = std.mem.indexOfScalar(u8, trimmed, '\t');
    try testing.expectEqual(first_tab == null, got == null);
    const line = got orelse return;

    // A leading relay nonce (16 lowercase hex characters) is skipped when an
    // `<event>\t<payload>` pair follows it; otherwise the line is plain.
    var body = trimmed;
    if (isNonceShaped(trimmed[0..first_tab.?])) {
        const rest = trimmed[first_tab.? + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '\t') != null) body = rest;
    }
    const t = std.mem.indexOfScalar(u8, body, '\t').?;

    // Payload is the exact borrowed slice after the event's tab.
    try testing.expectEqual(body.len - t - 1, line.payload.len);
    try testing.expectEqual(@intFromPtr(body.ptr) + t + 1, @intFromPtr(line.payload.ptr));
    try testing.expectEqualSlices(u8, body[t + 1 ..], line.payload);
    try testing.expectEqual(expectedEvent(body[0..t]), line.event);
    try testing.expectEqual(hook.HookEvent.fromString(body[0..t]), line.event);
    // The event part never contains a tab; later tabs stay in the payload.
    try testing.expect(std.mem.indexOfScalar(u8, body[0..t], '\t') == null);

    // With the right nonce, parseLineWithNonce agrees; with any other it refuses.
    if (body.ptr != trimmed.ptr) {
        const nonce = trimmed[0..hook.nonce_len];
        const strict = hook.parseLineWithNonce(raw, nonce) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(line.event, strict.event);
        try testing.expectEqual(@intFromPtr(line.payload.ptr), @intFromPtr(strict.payload.ptr));
        try testing.expectEqual(line.payload.len, strict.payload.len);
    }
    try testing.expect(hook.parseLineWithNonce(raw, "zzzzzzzzzzzzzzzz") == null);
    try testing.expect(hook.parseLineWithNonce(raw, "") == null);
}

fn isNonceShaped(field: []const u8) bool {
    if (field.len != hook.nonce_len) return false;
    for (field) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn fuzzParseLine(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    try checkParseLine(input);
    _ = hook.HookEvent.fromString(input);
    try testing.expectEqual(expectedEvent(input), hook.HookEvent.fromString(input));
}

test "fuzz: parseLine never panics and keeps its structural invariant" {
    try testing.fuzz({}, fuzzParseLine, .{ .corpus = &.{
        "\t\t\t\t",
        "\n\n\n\n",
        "\r\r\r\r",
        "\r\n\r\n",
        "\n\r\n\r",
        "\t\n\t\n",
        "\t\r\n\t",
        "Stop",
        "Stop\t",
        "Stop\t{}",
        "Stop\t{}\n",
        "Stop\t{}\r\n",
        "Stop\t{}\r",
        "Stop\t{}\n\n",
        "Stop\t{}\r\r\n",
        "Stop\t{}\n\r",
        "Stop\r\n\t{}",
        "\tStop",
        "SessionStart\t{\"session_id\":\"a\",\"transcript_path\":\"/x.jsonl\"}\n",
        "UserPromptSubmit\t{\"prompt\":\"a\\tb\"}\n",
        "UserPromptSubmit\t{\"prompt\":\"a\tb\tc\"}\n",
        "Stop \t{}",
        "stop\t{}",
        "Stop\x00\t{}",
        "\x00\t\x00\n",
        "\xff\xfe\t\xc3\x28\r\n",
        "PreFooBar\t{}",
        "nope-no-tab",
        "no tab but newline\n",
        "Stop\\t{}",
        "Stop\t" ++ "x" ** 4096 ++ "\n",
        "StopFailure\t{\"error\":\"rate_limit\"}\n",
        "0123456789abcdef\tStop\t{}\n",
        "0123456789abcdef\tStop\t{\"a\":\"b\tc\"}\r\n",
        "0123456789abcdef\tStop",
        "0123456789abcdef\t",
        "0123456789abcdef\t\t",
        "0123456789abcdef\t0123456789abcdef\tStop\t{}",
        "0123456789ABCDEF\tStop\t{}",
        "0123456789abcde\tStop\t{}",
        "0123456789abcdef0\tStop\t{}",
    } });
}

test "prop: parseLine structural invariant over arbitrary bytes (3,000 trials)" {
    const seed: u64 = 0x9a11_e001;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..3000) |trial| {
        _ = arena.reset(.retain_capacity);
        const raw = try genBytes(arena.allocator(), r, 64);
        checkParseLine(raw) catch |e| {
            reportTrial("parseLine bytes", seed, trial);
            std.debug.print("raw={any}\n", .{raw});
            return e;
        };
    }
}

test "prop: parseLine recovers event and payload from constructed lines (3,000 trials)" {
    const seed: u64 = 0x9a11_e002;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = [_][]const u8{ "", "\n", "\r\n", "\r" };
    const near = [_][]const u8{ "", "stop", "STOP", "Stop ", " Stop", "Stop\x00", "Sto", "Stopp", "SessionStar", "sessionstart", "UserPromptSubmit\r", "Session Start", "é" };

    for (0..3000) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("parseLine constructed", seed, trial);

        // Event: any bytes without a tab.
        const event: []const u8 = switch (r.uintLessThan(u8, 4)) {
            0 => relay_events[r.uintLessThan(usize, relay_events.len)],
            1 => near[r.uintLessThan(usize, near.len)],
            else => blk: {
                const e = try genBytes(a, r, 12);
                for (e) |*c| {
                    if (c.* == '\t') c.* = ' ';
                }
                break :blk e;
            },
        };
        // Payload: any bytes (tabs, NULs, invalid UTF-8) not ending in a line
        // terminator, so the appended terminator is the only thing stripped.
        var payload = try genBytes(a, r, 48);
        if (payload.len > 0 and (payload[payload.len - 1] == '\n' or payload[payload.len - 1] == '\r'))
            payload[payload.len - 1] = '}';
        const term = terms[r.uintLessThan(usize, terms.len)];
        // An event ending in "\r" or "\n" is only distinguishable when a tab follows; it always does here.
        const raw = try std.mem.concat(a, u8, &.{ event, "\t", payload, term });

        const line = hook.parseLine(raw) orelse return error.TestUnexpectedNull;
        try testing.expectEqualSlices(u8, payload, line.payload);
        try testing.expectEqual(expectedEvent(event), line.event);
        try checkParseLine(raw);

        // Without any tab the line is rejected, whatever the terminator.
        const no_tab = try a.dupe(u8, raw);
        for (no_tab) |*c| {
            if (c.* == '\t') c.* = ' ';
        }
        try testing.expect(hook.parseLine(no_tab) == null);
    }
}

test "prop: HookEvent.fromString matches exactly four names (3,000 trials)" {
    const seed: u64 = 0x9a11_e003;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    try testing.expectEqual(hook.HookEvent.session_start, hook.HookEvent.fromString("SessionStart"));
    try testing.expectEqual(hook.HookEvent.user_prompt_submit, hook.HookEvent.fromString("UserPromptSubmit"));
    try testing.expectEqual(hook.HookEvent.stop, hook.HookEvent.fromString("Stop"));
    try testing.expectEqual(hook.HookEvent.stop_failure, hook.HookEvent.fromString("StopFailure"));

    var buf: [40]u8 = undefined;
    for (0..3000) |trial| {
        errdefer reportTrial("fromString", seed, trial);
        // Mutate a real name by one edit; any edit must yield .unknown.
        const base = relay_events[r.uintLessThan(usize, relay_events.len)];
        var len = base.len;
        @memcpy(buf[0..len], base);
        switch (r.uintLessThan(u8, 4)) {
            0 => { // flip one byte
                const i = r.uintLessThan(usize, len);
                buf[i] ^= @as(u8, 1) << r.int(u3);
            },
            1 => { // delete one byte
                const i = r.uintLessThan(usize, len);
                std.mem.copyForwards(u8, buf[i .. len - 1], buf[i + 1 .. len]);
                len -= 1;
            },
            2 => { // insert one byte
                const i = r.uintAtMost(usize, len);
                std.mem.copyBackwards(u8, buf[i + 1 .. len + 1], buf[i..len]);
                buf[i] = r.int(u8);
                len += 1;
            },
            else => { // random bytes
                len = r.uintAtMost(usize, buf.len);
                r.bytes(buf[0..len]);
            },
        }
        const s = buf[0..len];
        try testing.expectEqual(expectedEvent(s), hook.HookEvent.fromString(s));
        const is_name = for (relay_events) |ev| {
            if (std.mem.eql(u8, ev, s)) break true;
        } else false;
        try testing.expectEqual(is_name, hook.HookEvent.fromString(s) != .unknown);
    }
}

// ---------------------------------------------------------------------------
// 2. Field extractors
// ---------------------------------------------------------------------------

fn fuzzExtractors(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    const a = testing.allocator;
    var results: [4]?[]u8 = .{ null, null, null, null };
    defer for (results) |res| if (res) |s| a.free(s);
    for (extractors, 0..) |ex, i| {
        results[i] = try ex(a, input);
        if (results[i]) |s| {
            // An extracted value is an owned, writable, valid UTF-8 string
            // taken from a JSON object.
            try testing.expect(std.unicode.utf8ValidateSlice(s));
            try testing.expect(std.mem.indexOfScalar(u8, input, '{') != null);
            @memset(s, 0xaa);
        }
    }
    // The same bytes relayed as a hook line extract identically.
    if (std.mem.indexOfAny(u8, input, "\r\n") == null) {
        const raw = try std.mem.concat(a, u8, &.{ "Stop\t", input, "\n" });
        defer a.free(raw);
        const line = hook.parseLine(raw).?;
        try testing.expectEqualSlices(u8, input, line.payload);
        const i = input.len % extractors.len;
        const again = try extractors[i](a, line.payload);
        defer if (again) |s| a.free(s);
        try testing.expectEqual(results[i] == null, again == null);
        if (again) |s| try testing.expectEqual(results[i].?.len, s.len);
    }
}

test "fuzz: extractors never crash or leak on arbitrary payloads" {
    try testing.fuzz({}, fuzzExtractors, .{ .corpus = &.{
        "{  }",
        "[  ]",
        "null",
        "not-json",
        "{   ",
        "{\"prompt\":",
        "{\"prompt\":\"hi\"}",
        "{\"prompt\":\"hi\"} trailing",
        "{\"prompt\":42}",
        "{\"prompt\":null}",
        "{\"prompt\":[\"hi\"]}",
        "{\"prompt\":{\"prompt\":\"nested\"}}",
        "{\"prompt\":\"a\",\"prompt\":\"b\"}",
        "{\"\\u0070rompt\":\"escaped key\"}",
        "{\"Prompt\":\"x\",\"prompt \":\"y\"}",
        "[{\"prompt\":\"in array\"}]",
        "{\"session_id\":\"abc-123\",\"transcript_path\":\"/a/b.jsonl\",\"last_assistant_message\":\"OK\",\"prompt\":\"hi\"}",
        "{\"transcript_path\":\"/a/b c/\\u00e9\\ud83d\\ude00.jsonl\"}",
        "{\"last_assistant_message\":\"line1\\nline2\\t\\\"q\\\"\\\\\\/\\b\\f\\r\\u0000\"}",
        "{\"session_id\":\"\\ud800\"}",
        "{\"session_id\":\"\\udc00\\ud800\"}",
        "{\"session_id\":\"\\ud83d\"}",
        "{\"session_id\":\"\\uZZZZ\"}",
        "{\"session_id\":\"\xff\xfe\"}",
        "{\"session_id\":\"\xed\xa0\x80\"}",
        "{\"session_id\":\"\x00\"}",
        "{\"session_id\":\"a\nb\"}",
        "{\"prompt\":1e999999,\"session_id\":\"s\"}",
        "{\"prompt\":-0,\"n\":123456789012345678901234567890123456789012345678901234567890}",
        "{\"n\":0.000000000000000000000000000000000000000000000000000001e-400,\"prompt\":\"p\"}",
        "\xef\xbb\xbf{\"prompt\":\"bom\"}",
        " \n\t{ \"prompt\" : \"ws\" } \r\n",
        "{\"prompt\":\"\xf0\x9f\x98\x80\xe2\x80\xa8\"}",
        "[" ** 2000 ++ "]" ** 2000,
        "{\"a\":" ** 500 ++ "{\"prompt\":\"deep\"}" ++ "}" ** 500,
        "{\"prompt\":\"" ++ "A" ** 5000 ++ "\"}",
        "{\"prompt\":\"" ++ "\\u0041" ** 500 ++ "\"}",
        "[" ** 5000,
        "{\"prompt\":\"unterminated",
        "{\"prompt\":\"x\"}\x00",
        "{'prompt':'single'}",
        "{\"prompt\":\"x\",}",
        "true",
        "\"prompt\"",
        "0000",
    } });
}

test "prop: extractors round-trip any UTF-8 string byte-for-byte (3,000 trials)" {
    const seed: u64 = 0x9a11_e010;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lc = try LeakCheck.init();
    defer lc.deinit();

    const escaped_keys = [_][]const u8{
        "\"\\u0074ranscript_path\"", "\"last\\u005Fassistant_message\"", "\"session\\u005fid\"", "\"\\u0070\\u0072ompt\"",
    };
    const decoy_keys = [_][]const u8{
        "Prompt", "prompt ", " prompt", "prompt\x00", "session_id2", "sessionId", "transcript-path", "last_assistant_messages", "", "cwd", "hook_event_name",
    };

    for (0..3000) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("extractor round-trip", seed, trial);

        // Each member is a pre-rendered `"key":value` fragment.
        var members: std.ArrayList([]const u8) = .empty;
        var expected: [4]?[]const u8 = .{ null, null, null, null };

        for (field_names, 0..) |name, fi| {
            var m: Buf = .empty;
            const kind = r.uintLessThan(u8, 10);
            if (kind >= 9) continue; // absent
            if (r.uintLessThan(u8, 4) == 0) {
                try m.appendSlice(a, escaped_keys[fi]);
            } else {
                try m.append(a, '"');
                try m.appendSlice(a, name);
                try m.append(a, '"');
            }
            try ws(a, r, &m);
            try m.append(a, ':');
            try ws(a, r, &m);
            if (kind < 7) {
                const s = try genUtf8(a, r, 40, true);
                expected[fi] = s;
                if (r.boolean()) {
                    try writeJsonString(a, r, &m, s);
                } else {
                    // Second, independent encoder: std.json.Stringify.
                    try m.appendSlice(a, try std.json.Stringify.valueAlloc(a, s, .{
                        .escape_unicode = r.boolean(),
                    }));
                }
            } else {
                // Present but not a string: must extract as null, even when a
                // same-named string hides one level down.
                const non_strings = [_][]const u8{ "null", "true", "0", "1e999", "[]", "{}", "[\"x\"]" };
                if (r.boolean()) {
                    try m.appendSlice(a, non_strings[r.uintLessThan(usize, non_strings.len)]);
                } else {
                    try m.appendSlice(a, "{\"");
                    try m.appendSlice(a, name);
                    try m.appendSlice(a, "\":\"nested\"}");
                }
            }
            try members.append(a, try m.toOwnedSlice(a));
        }
        // Decoys: near-miss keys and arbitrary nested values.
        for (0..r.uintAtMost(usize, 4)) |_| {
            var m: Buf = .empty;
            const k = decoy_keys[r.uintLessThan(usize, decoy_keys.len)];
            try m.appendSlice(a, try std.json.Stringify.valueAlloc(a, k, .{}));
            try m.append(a, ':');
            try genValue(a, r, &m, 3, true);
            try members.append(a, try m.toOwnedSlice(a));
        }
        // Drop duplicate decoy keys (keep the first occurrence).
        var uniq: std.ArrayList([]const u8) = .empty;
        outer: for (members.items) |mem| {
            const key_end = std.mem.indexOfScalarPos(u8, mem, 1, '"').?;
            for (uniq.items) |prev| {
                if (std.mem.startsWith(u8, prev, mem[0 .. key_end + 1])) continue :outer;
            }
            try uniq.append(a, mem);
        }
        r.shuffle([]const u8, uniq.items);

        var payload: Buf = .empty;
        try ws(a, r, &payload);
        try payload.append(a, '{');
        for (uniq.items, 0..) |mem, i| {
            if (i != 0) try payload.append(a, ',');
            try ws(a, r, &payload);
            try payload.appendSlice(a, mem);
            try ws(a, r, &payload);
        }
        try payload.append(a, '}');
        try ws(a, r, &payload);

        const ta = lc.pick(trial);
        for (extractors, 0..) |ex, fi| {
            const got = try ex(ta, payload.items);
            defer if (got) |s| ta.free(s);
            if (expected[fi]) |want| {
                if (got == null) {
                    std.debug.print("payload={s}\n", .{payload.items});
                    return error.TestExpectedString;
                }
                testing.expectEqualSlices(u8, want, got.?) catch |e| {
                    std.debug.print("field={s} payload={s}\n", .{ field_names[fi], payload.items });
                    return e;
                };
            } else if (got != null) {
                std.debug.print("field={s} payload={s}\n", .{ field_names[fi], payload.items });
                return error.TestExpectedNull;
            }
        }

        // Wrapped in an array, a string, or truncated, nothing extracts.
        if (trial % 8 == 0) {
            const wrapped = try std.mem.concat(a, u8, &.{ "[", payload.items, "]" });
            const trimmed = std.mem.trim(u8, payload.items, " \n\t\r");
            const cut = trimmed[0..r.uintLessThan(usize, trimmed.len)];
            for (extractors) |ex| {
                try testing.expect(try ex(ta, wrapped) == null);
                try testing.expect(try ex(ta, cut) == null);
            }
        }
        try lc.expectClean();
    }
}

test "prop: single-line payloads survive the hook-line framing (1,000 trials)" {
    const seed: u64 = 0x9a11_e011;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = [_][]const u8{ "", "\n", "\r\n" };
    var lc = try LeakCheck.init();
    defer lc.deinit();

    for (0..1000) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("line framing", seed, trial);
        const fi = r.uintLessThan(usize, 4);
        const want = try genUtf8(a, r, 60, true);
        // Stringify escapes every control byte, so the payload is one line;
        // raw tabs cannot occur either, yet escaped "\t" still round-trips.
        const payload = try std.fmt.allocPrint(a, "{{\"hook_event_name\":\"x\",\"{s}\":{s}}}", .{
            field_names[fi], try std.json.Stringify.valueAlloc(a, want, .{}),
        });
        const ev = relay_events[r.uintLessThan(usize, relay_events.len)];
        const raw = try std.mem.concat(a, u8, &.{ ev, "\t", payload, terms[r.uintLessThan(usize, terms.len)] });
        const line = hook.parseLine(raw) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(expectedEvent(ev), line.event);
        const ta = lc.pick(trial);
        {
            const got = (try extractors[fi](ta, line.payload)) orelse return error.TestExpectedString;
            defer ta.free(got);
            try testing.expectEqualSlices(u8, want, got);
        }
        try lc.expectClean();
    }
}

test "oom: extractors return OutOfMemory cleanly and never swallow it" {
    const Ctx = struct {
        fn run(allocator: Allocator, payload: []const u8) !void {
            for (extractors) |ex| {
                const got = ex(allocator, payload) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return e,
                };
                if (got) |s| allocator.free(s);
            }
        }
    };
    const payloads = [_][]const u8{
        "{\"session_id\":\"abc\",\"transcript_path\":\"/a/b.jsonl\",\"last_assistant_message\":\"line\\n\\u00e9\\ud83d\\ude00\",\"prompt\":\"hi there\"}",
        "{\"prompt\":{\"prompt\":[1,2,{\"a\":\"b\"}]},\"session_id\":12345678901234567890123}",
        "{\"prompt\":\"dup\",\"prompt\":\"dup2\"}",
        "{\"prompt\":\"truncated",
        "[[[[{\"prompt\":\"x\"}]]]]",
        "not json at all",
        "{\"a\":" ** 40 ++ "\"x\"" ++ "}" ** 40,
    };
    for (payloads) |p| try testing.checkAllAllocationFailures(testing.allocator, Ctx.run, .{p});
}

// ---------------------------------------------------------------------------
// 3. buildSettingsJson / createWithOptions
// ---------------------------------------------------------------------------

test "prop: buildSettingsJson keeps relay hooks authoritative under random options (2,000 trials)" {
    const seed: u64 = 0x9a11_e020;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lc = try LeakCheck.init();
    defer lc.deinit();
    var saw_evil: usize = 0;
    var saw_collision: usize = 0;
    for (0..2000) |trial| {
        _ = arena.reset(.retain_capacity);
        const ta = lc.pick(trial);
        const script_path = try genScriptPath(a, r);
        const extra_hooks = try genExtraHooks(a, r, 12);
        const extra: ?[]const u8 = if (r.uintLessThan(u8, 5) == 0) null else try genSettingsObject(a, r);

        const json = hook.buildSettingsJson(ta, script_path, .{
            .extra_hooks = extra_hooks,
            .extra_settings_json = extra,
        }) catch |e| {
            reportTrial("buildSettingsJson", seed, trial);
            std.debug.print("path={s}\nextra={?s}\n", .{ script_path, extra });
            return e;
        };
        var json_live = true;
        defer if (json_live) ta.free(json);

        checkSettings(a, json, script_path, extra_hooks, extra) catch |e| {
            reportTrial("buildSettingsJson", seed, trial);
            std.debug.print("path={s}\nextra={?s}\njson={s}\n", .{ script_path, extra, json });
            return e;
        };
        // Nothing from a caller-supplied top-level "hooks" value survives.
        if (extra) |raw| {
            if (std.mem.indexOf(u8, raw, evil_marker) != null) saw_evil += 1;
        }
        if (std.mem.indexOf(u8, json, evil_marker) != null) {
            reportTrial("buildSettingsJson evil marker", seed, trial);
            std.debug.print("extra={?s}\njson={s}\n", .{ extra, json });
            return error.TestCallerHooksLeaked;
        }
        for (extra_hooks) |eh| {
            if (expectedEvent(eh.event) != .unknown) {
                saw_collision += 1;
                break;
            }
        }
        // Deterministic: same inputs, same bytes.
        if (trial % 16 == 0) {
            const again = try hook.buildSettingsJson(ta, script_path, .{
                .extra_hooks = extra_hooks,
                .extra_settings_json = extra,
            });
            defer ta.free(again);
            try testing.expectEqualSlices(u8, json, again);
        }
        // The result is the only allocation that outlives the call.
        ta.free(json);
        json_live = false;
        lc.expectClean() catch |e| {
            reportTrial("buildSettingsJson leak", seed, trial);
            return e;
        };
    }
    // Guard the generator: the adversarial cases must actually occur.
    try testing.expect(saw_evil > 200);
    try testing.expect(saw_collision > 500);
}

test "prop: buildSettingsJson emits numeric literals and key order verbatim (1,500 trials)" {
    const seed: u64 = 0x9a11_e021;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (0..1500) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("numeric verbatim", seed, trial);
        var in: Buf = .empty;
        var want: Buf = .empty;
        try in.append(a, '{');
        try want.append(a, '{');
        const n = r.intRangeAtMost(usize, 1, 6);
        const hooks_at = r.uintAtMost(usize, n * 2);
        for (0..n) |i| {
            var lit: Buf = .empty;
            if (r.boolean())
                try lit.appendSlice(a, number_pool[r.uintLessThan(usize, number_pool.len)])
            else
                try genNumberLiteral(a, r, &lit);
            const member = try std.fmt.allocPrint(a, "\"k{d}\":{s}", .{ i, lit.items });
            if (i != 0) try in.append(a, ',');
            if (i == hooks_at) try in.appendSlice(a, "\"hooks\":\"evil\",");
            try ws(a, r, &in);
            try in.appendSlice(a, member);
            try ws(a, r, &in);
            try want.appendSlice(a, member);
            try want.append(a, ',');
        }
        try in.append(a, '}');
        try want.appendSlice(a, "\"hooks\":{\"SessionStart\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"/h.sh SessionStart\"}]}],");

        const json = try hook.buildSettingsJson(a, "/h.sh", .{ .extra_settings_json = in.items });
        if (!std.mem.startsWith(u8, json, want.items)) {
            std.debug.print("in={s}\nwant prefix={s}\ngot={s}\n", .{ in.items, want.items, json });
            return error.TestNotVerbatim;
        }
    }
}

test "prop: relay command shell-quoting matches /bin/sh word splitting" {
    const seed: u64 = 0x9a11_e022;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every pool path plus random ones, expanded by one real shell process.
    // Each relay command becomes `set -- <command>` and the shell reports the
    // resulting argument count and arguments, NUL-terminated.
    var script: Buf = .empty;
    var want: Buf = .empty;
    for (0..path_pool.len + 40) |trial| {
        const path = if (trial < path_pool.len) path_pool[trial] else try genUtf8(a, r, 30, false);
        const json = try hook.buildSettingsJson(a, path, .{});
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        for (relay_events) |ev| {
            const cmd = root.object.get("hooks").?.object.get(ev).?.array.items[0]
                .object.get("hooks").?.array.items[0].object.get("command").?.string;
            try script.appendSlice(a, "set -- ");
            try script.appendSlice(a, cmd);
            try script.appendSlice(a, "\nprintf '%s|%s|%s\\0' \"$#\" \"$2\" \"$1\"\n");
            try want.appendSlice(a, "2|");
            try want.appendSlice(a, ev);
            try want.append(a, '|');
            try want.appendSlice(a, path);
            try want.append(a, 0);
        }
    }
    const res = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "/bin/sh", "-c", script.items },
        .max_output_bytes = 1 << 20,
    });
    errdefer reportTrial("real sh", seed, 0);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expectEqual(@as(u8, 0), res.term.Exited);
    try testing.expectEqualSlices(u8, want.items, res.stdout);
}

test "prop: invalid options always return InvalidExtraSettings and touch no disk (1,500 trials)" {
    const seed: u64 = 0x9a11_e023;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lc = try LeakCheck.init();
    defer lc.deinit();
    const before = try countOwnTmpDirs();
    for (0..1500) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("invalid options", seed, trial);
        const ta = lc.pick(trial);

        var extra_hooks = try genExtraHooks(a, r, 12);
        var extra: ?[]const u8 = if (r.boolean()) try genSettingsObject(a, r) else null;

        // Break exactly one thing (sometimes two).
        const mode = r.uintLessThan(u8, 4);
        if (mode == 0 or mode == 3) {
            if (extra_hooks.len == 0) extra_hooks = try a.alloc(hook.ExtraHook, 1);
            const i = r.uintLessThan(usize, extra_hooks.len);
            const bad_utf8 = [_][]const u8{ "\xff", "ok\xc3", "\xed\xa0\x80", "a\xf0\x9f\x98", "\x80" };
            extra_hooks[i] = switch (r.uintLessThan(u8, 5)) {
                0 => .{ .event = "", .command = "echo hi" },
                1 => .{ .event = "Stop", .command = "" },
                2 => .{ .event = "", .command = "" },
                3 => .{ .event = bad_utf8[r.uintLessThan(usize, bad_utf8.len)], .command = "echo hi" },
                else => .{ .event = "Stop", .command = bad_utf8[r.uintLessThan(usize, bad_utf8.len)] },
            };
        }
        if (mode != 0) extra = try genMalformedSettings(a, r);

        const opts: hook.CreateOptions = .{ .extra_hooks = extra_hooks, .extra_settings_json = extra };
        if (hook.createWithOptions(ta, opts)) |h| {
            var hh = h;
            hh.deinit();
            std.debug.print("accepted extra={?s}\n", .{extra});
            return error.TestExpectedInvalidExtraSettings;
        } else |e| {
            if (e != error.InvalidExtraSettings) std.debug.print("extra={?s}\n", .{extra});
            try testing.expectEqual(error.InvalidExtraSettings, e);
        }
        try testing.expectError(error.InvalidExtraSettings, hook.buildSettingsJson(ta, "/tmp/hook.sh", opts));
        try lc.expectClean();
    }
    try testing.expectEqual(before, try countOwnTmpDirs());
}

test "prop: nesting depth boundary is exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const limit = hook.max_extra_settings_depth;
    for ([_]bool{ true, false }) |arrays| {
        for ([_]usize{ 1, 2, limit - 1, limit }) |d| {
            const doc = try deepDoc(a, d, arrays);
            try testing.expectEqual(d, textDepth(doc));
            const json = try hook.buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = doc });
            try checkSettings(a, json, "/tmp/hook.sh", &.{}, doc);
        }
        for ([_]usize{ limit + 1, 255, 256, 257, 258, 1000, 4000 }) |d| {
            const doc = try deepDoc(a, d, arrays);
            try testing.expectError(error.InvalidExtraSettings, hook.buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = doc }));
        }
    }
    // Depth hidden under the discarded "hooks" key is rejected by the same rule.
    const under_hooks = try std.mem.concat(a, u8, &.{ "{\"hooks\":", try deepDoc(a, limit, true), "}" });
    try testing.expectError(error.InvalidExtraSettings, hook.buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = under_hooks }));
    // Brackets inside strings and keys are not nesting.
    const in_strings = "{\"" ++ "[" ** 300 ++ "\":\"" ++ "{" ** 300 ++ "\\\"[[\\\\\"}";
    const json = try hook.buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = in_strings });
    try checkSettings(a, json, "/tmp/hook.sh", &.{}, in_strings);
}

test "prop: createWithOptions builds a working harness and cleans up (64 trials)" {
    const seed: u64 = 0x9a11_e024;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";

    var lc = try LeakCheck.init();
    defer lc.deinit();
    const before = try countOwnTmpDirs();
    // Disk-bound (mkdir, mkfifo, write, stat, unlink per trial), so fewer trials
    // than the pure buildSettingsJson properties above.
    for (0..64) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("createWithOptions", seed, trial);
        const ta = if (trial % 10 == 9) testing.allocator else lc.allocator();
        const extra_hooks = try genExtraHooks(a, r, 12);
        const extra: ?[]const u8 = if (r.boolean()) try genSettingsObject(a, r) else null;

        var h = try hook.createWithOptions(ta, .{ .extra_hooks = extra_hooks, .extra_settings_json = extra });
        var live = true;
        defer if (live) h.deinit();

        // Everything lives under $TMPDIR/claude-p-<pid>-<rand>/, never ~/.claude.
        try testing.expect(std.fs.path.isAbsolute(h.tmp_dir));
        try testing.expect(std.mem.startsWith(u8, h.tmp_dir, tmp_root));
        // The directory is private and its name ends in 64 random bits.
        const dir_stat = try std.fs.cwd().statFile(h.tmp_dir);
        try testing.expectEqual(std.fs.File.Kind.directory, dir_stat.kind);
        try testing.expectEqual(@as(std.fs.File.Mode, 0o700), dir_stat.mode & 0o777);
        try testing.expect(isNonceShaped(h.tmp_dir[h.tmp_dir.len - 16 ..]));
        try testing.expectEqual(@as(u8, '-'), h.tmp_dir[h.tmp_dir.len - 17]);
        // The script embeds this run's FIFO path and nonce.
        try testing.expect(isNonceShaped(&h.nonce));
        try testing.expectEqualSlices(
            u8,
            try hook.buildScript(a, h.fifo_path, &h.nonce),
            try std.fs.cwd().readFileAlloc(a, h.script_path, 1 << 16),
        );
        try testing.expect(std.mem.indexOf(u8, h.tmp_dir, "/.claude") == null);
        try testing.expect(std.mem.startsWith(u8, h.fifo_path, h.tmp_dir));
        try testing.expect(std.mem.endsWith(u8, h.fifo_path, "/events.fifo"));
        try testing.expect(std.mem.startsWith(u8, h.script_path, h.tmp_dir));
        try testing.expect(std.mem.endsWith(u8, h.script_path, "/hook.sh"));
        if (trial % 32 == 0) try testing.expectEqual(before + 1, try countOwnTmpDirs());

        const fifo_stat = try std.fs.cwd().statFile(h.fifo_path);
        try testing.expectEqual(std.fs.File.Kind.named_pipe, fifo_stat.kind);
        try testing.expectEqual(@as(std.fs.File.Mode, 0o600), fifo_stat.mode & 0o777);
        const script_stat = try std.fs.cwd().statFile(h.script_path);
        try testing.expectEqual(std.fs.File.Kind.file, script_stat.kind);
        try testing.expectEqual(@as(std.fs.File.Mode, 0o700), script_stat.mode & 0o777);

        try checkSettings(a, h.settings_json, h.script_path, extra_hooks, extra);

        const tmp_dir = try a.dupe(u8, h.tmp_dir);
        h.deinit();
        live = false;
        try testing.expectError(error.FileNotFound, std.fs.cwd().access(tmp_dir, .{}));
        try lc.expectClean();
    }
    try testing.expectEqual(before, try countOwnTmpDirs());
}

test "prop: payloads relayed through the real hook.sh round-trip end to end" {
    const seed: u64 = 0x9a11_e025;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var h = try hook.createWithOptions(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "Stop", .command = "exit 1" }},
        .extra_settings_json = "{\"hooks\":{\"Stop\":[]}}",
    });
    defer h.deinit();

    // Open the FIFO before any writer exists, as the driver does.
    const fifo_z = try a.dupeZ(u8, h.fifo_path);
    const fd = try std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    defer std.posix.close(fd);

    // The script carries its own FIFO path: no CLAUDE_P_FIFO in the child env.
    var env = try std.process.getEnvMap(a);
    env.remove("CLAUDE_P_FIFO");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, h.settings_json, .{});

    // One shell process runs the exact relay command string for each event
    // several times, feeding each payload on stdin through a here-document.
    // Each hook.sh exec costs ~150 ms on macOS, so run one per relay event.
    const trials = relay_events.len;
    var script: Buf = .empty;
    var events: [trials][]const u8 = undefined;
    var fields: [trials]usize = undefined;
    var wants: [trials][]const u8 = undefined;
    var payloads: [trials][]const u8 = undefined;
    for (0..trials) |i| {
        events[i] = relay_events[i % relay_events.len];
        fields[i] = r.uintLessThan(usize, 4);
        // The payload is JSON, so NUL and newlines arrive escaped on one line.
        wants[i] = try genUtf8(a, r, 60, true);
        payloads[i] = try std.fmt.allocPrint(a, "{{\"hook_event_name\":\"{s}\",\"{s}\":{s}}}", .{
            events[i], field_names[fields[i]], try std.json.Stringify.valueAlloc(a, wants[i], .{}),
        });
        const cmd = root.object.get("hooks").?.object.get(events[i]).?.array.items[0]
            .object.get("hooks").?.array.items[0].object.get("command").?.string;
        try script.appendSlice(a, cmd);
        try script.appendSlice(a, " <<'CLAUDE_P_PROP_EOF'\n");
        try script.appendSlice(a, payloads[i]);
        try script.appendSlice(a, "\nCLAUDE_P_PROP_EOF\n");
    }
    const res = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "/bin/sh", "-c", script.items },
        .env_map = &env,
    });
    errdefer reportTrial("hook.sh relay", seed, 0);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expectEqual(@as(u8, 0), res.term.Exited);

    var buf: [1 << 16]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return e,
        };
        if (n == 0) break;
        len += n;
    }
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    for (0..trials) |i| {
        const raw = lines.next() orelse return error.TestMissingHookLine;
        // Every line starts with this run's nonce; another run's is refused.
        try testing.expect(std.mem.startsWith(u8, raw, &h.nonce));
        try testing.expectEqual(@as(u8, '\t'), raw[hook.nonce_len]);
        var wrong = h.nonce;
        wrong[i % wrong.len] = if (wrong[i % wrong.len] == '0') '1' else '0';
        try testing.expect(hook.parseLineWithNonce(raw, &wrong) == null);
        const line = hook.parseLineWithNonce(raw, &h.nonce) orelse return error.TestUnexpectedNull;
        // The nonce-blind parser sees the same event and payload.
        const legacy = hook.parseLine(raw) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(line.event, legacy.event);
        try testing.expectEqualSlices(u8, line.payload, legacy.payload);
        try testing.expectEqual(expectedEvent(events[i]), line.event);
        try testing.expectEqualSlices(u8, payloads[i], line.payload);
        const got = (try extractors[fields[i]](testing.allocator, line.payload)) orelse return error.TestExpectedString;
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, wants[i], got);
    }
    try testing.expectEqualStrings("", lines.rest());
}

fn settingsShouldBeAccepted(a: Allocator, raw: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{
        .duplicate_field_behavior = .use_last,
        .parse_numbers = false,
    }) catch return false;
    if (v != .object or textDepth(raw) > hook.max_extra_settings_depth) return false;
    if (v.object.get("disableAllHooks")) |d| {
        if (d == .bool and d.bool) return false;
    }
    return true;
}

fn fuzzSettingsJson(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "/tmp/it's a dir/hook.sh";
    const hooks_: []const hook.ExtraHook = &.{
        .{ .event = "Stop", .command = "echo \"$(date)\" | tee -a /tmp/log" },
        .{ .event = "PreToolUse", .command = "audit" },
    };
    const want_ok = settingsShouldBeAccepted(a, input);
    if (hook.buildSettingsJson(testing.allocator, path, .{ .extra_hooks = hooks_, .extra_settings_json = input })) |json| {
        defer testing.allocator.free(json);
        try testing.expect(want_ok);
        try checkSettings(a, json, path, hooks_, input);
    } else |e| {
        try testing.expectEqual(error.InvalidExtraSettings, e);
        try testing.expect(!want_ok);
    }
}

test "fuzz: buildSettingsJson with arbitrary extra_settings_json bytes" {
    try testing.fuzz({}, fuzzSettingsJson, .{ .corpus = &.{
        " { } ",
        "null",
        "[  ]",
        "{} trailing",
        "{\"a\":1,}",
        "{\"a\":NaN}",
        "{\"a\":\"\\ud800\"}",
        "\xef\xbb\xbf{}",
        "{}\x00\x00",
        "{\"a\":[1,2}",
        "{\"env\":{\"FOO\":\"bar\"},\"includeCoAuthoredBy\":false,\"precision\":0.1234567890123456789}",
        "{\"hooks\":{}}",
        "{\"disableAllHooks\":true}",
        "{\"disableAllHooks\":false}",
        "{\"disableAllHooks\":true,\"disableAllHooks\":false}",
        "{\"disableAllHooks\":false,\"disable\\u0041llHooks\":true}",
        "{\"env\":{\"disableAllHooks\":true}}",
        "{\"hooks\":\"evil\"}",
        "{\"hooks\":{\"Stop\":[],\"Evil\":[]},\"model\":\"opus\"}",
        "{\"\\u0068ooks\":{\"Stop\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"evil\"}]}]}}",
        "{\"hooks\":1,\"a\":2,\"hooks\":{\"Stop\":[]},\"a\":3}",
        "{\"a\":1,\"a\":2,\"a\":{\"a\":1,\"a\":2}}",
        "{\"Hooks\":{},\"hooks \":{},\"HOOKS\":[]}",
        "{\"\":\"\",\"\\u0000\":\"\\u0000\"}",
        "{\"n\":[0,-0,1e400,-1E-400,123456789012345678901234567890,1.0e00]}",
        "{\"s\":\"\\ud83d\\ude00\\u2028\\\"\\\\\\/\\b\\f\\n\\r\\t\"}",
        "{\"s\":\"\xf0\x9f\x98\x80\xe2\x80\xa8\x7f\"}",
        "{\"a\":" ++ "[" ** 126 ++ "]" ** 126 ++ "}",
        "{\"a\":" ++ "[" ** 127 ++ "]" ** 127 ++ "}",
        "{\"a\":" ++ "[" ** 128 ++ "]" ** 128 ++ "}",
        "{\"a\":" ++ "[" ** 255 ++ "]" ** 255 ++ "}",
        "{\"a\":" ++ "[" ** 256 ++ "]" ** 256 ++ "}",
        "{\"a\":" ++ "{\"b\":" ** 300 ++ "1" ++ "}" ** 300 ++ "}",
        "{\"a\":\"" ++ "[{" ** 200 ++ "\"}",
        "{\"hooks\":" ++ "[" ** 300 ++ "]" ** 300 ++ "}",
        "{\"permissions\":{\"allow\":[\"Bash(ls:*)\"],\"deny\":[]},\"env\":{\"A\":\"1\"}}",
    } });
}

/// Byte-driven decoder: turns fuzz input into a script path, extra hooks, and
/// (optionally) a settings object, without restricting the bytes of any string.
const Smith = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(s: *Smith) u8 {
        if (s.pos >= s.data.len) return 0;
        defer s.pos += 1;
        return s.data[s.pos];
    }
    fn bytes(s: *Smith, max: usize) []const u8 {
        const n = @min(@min(@as(usize, s.byte()), max), s.data.len - @min(s.pos, s.data.len));
        defer s.pos += n;
        return s.data[s.pos..][0..n];
    }
};

fn fuzzSettingsStructured(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Smith = .{ .data = input };

    const raw_path = s.bytes(48);
    // The script path is produced by claude-p itself; model it as NUL-free UTF-8.
    if (!std.unicode.utf8ValidateSlice(raw_path) or std.mem.indexOfScalar(u8, raw_path, 0) != null) return;
    const n_hooks = s.byte() % 13;
    const hooks_ = try a.alloc(hook.ExtraHook, n_hooks);
    var hooks_valid = true;
    for (hooks_) |*eh| {
        const event: []const u8 = switch (s.byte() % 6) {
            0 => "SessionStart",
            1 => "UserPromptSubmit",
            2 => "Stop",
            3 => "PreToolUse",
            else => s.bytes(16),
        };
        eh.* = .{ .event = event, .command = s.bytes(40) };
        if (eh.event.len == 0 or eh.command.len == 0) hooks_valid = false;
        if (!std.unicode.utf8ValidateSlice(eh.event) or !std.unicode.utf8ValidateSlice(eh.command)) hooks_valid = false;
    }
    const extra: ?[]const u8 = if (s.byte() & 1 == 0) null else s.data[@min(s.pos, s.data.len)..];
    const want_ok = hooks_valid and (extra == null or settingsShouldBeAccepted(a, extra.?));

    if (hook.buildSettingsJson(testing.allocator, raw_path, .{ .extra_hooks = hooks_, .extra_settings_json = extra })) |json| {
        defer testing.allocator.free(json);
        try testing.expect(want_ok);
        try checkSettings(a, json, raw_path, hooks_, extra);
    } else |e| {
        try testing.expectEqual(error.InvalidExtraSettings, e);
        try testing.expect(!want_ok);
    }
}

test "fuzz: buildSettingsJson with byte-decoded path, hooks, and settings" {
    try testing.fuzz({}, fuzzSettingsStructured, .{ .corpus = &.{
        "\x00\x00\x00\x00",
        "\x0c/tmp/hook.sh\x00\x00",
        "\x0c/tmp/hook.sh\x02\x02\x07echo hi\x05\x04Evnt\x03a|b\x01{\"model\":\"opus\"}",
        "\x0c/tmp/it's sh\x03\x00\x04$(x)\x01\x02`y`\x02\x06'; x '\x01{\"hooks\":\"evil\",\"a\":[1,2]}",
        "\x05/a b/\x01\x02\x00\x00",
        "\x05/a b/\x01\x05\x00\x01c\x00",
        "\x05/a b/\x01\x05\x02\xff\xfe\x01c\x00",
        "\x05/a b/\x01\x02\x02c\xc3\x00",
        "\x02''\x0c\x02\x01a\x02\x01b\x02\x01c\x02\x01d\x02\x01e\x02\x01f\x02\x01g\x02\x01h\x02\x01i\x02\x01j\x02\x01k\x02\x01l\x01{}",
        "\x04\xf0\x9f\x98\x80\x02\x05\x04\xe5\x8b\xbe\x21\x06\"}]}],\x05\x05hooks\x01x\x01{\"hooks\":{\"Stop\":[]}}",
        "\x01-\x01\x03\x01\"\x01[]",
        "\x01-\x01\x03\x01\\\x01{\"a\":1} x",
        "\x03a\nb\x00\x01{\"a\":" ++ "[" ** 130 ++ "]" ** 130 ++ "}",
    } });
}

test "oom: buildSettingsJson and createWithOptions fail cleanly at every allocation" {
    const Ctx = struct {
        fn build(allocator: Allocator, path: []const u8, opts: hook.CreateOptions) !void {
            const json = hook.buildSettingsJson(allocator, path, opts) catch |e| switch (e) {
                // A swallowed OOM surfacing as InvalidExtraSettings is reported
                // by checkAllAllocationFailures as SwallowedOutOfMemoryError.
                error.InvalidExtraSettings => return,
                else => return e,
            };
            allocator.free(json);
        }
        fn create(allocator: Allocator, opts: hook.CreateOptions) !void {
            var h = hook.createWithOptions(allocator, opts) catch |e| switch (e) {
                error.InvalidExtraSettings => return,
                else => return e,
            };
            h.deinit();
        }
    };

    const rich: hook.CreateOptions = .{
        .extra_hooks = &.{
            .{ .event = "Stop", .command = "echo \"done\" | tee /tmp/x" },
            .{ .event = "Notification", .command = "$(id)" },
            .{ .event = "Stop", .command = "second" },
            .{ .event = "Notification", .command = "é\u{1F600}" },
            .{ .event = "SessionStart", .command = "'; exit 1; '" },
        },
        .extra_settings_json = "{\"env\":{\"A\":\"1\",\"B\":[1,2.50,{\"c\":null}]},\"hooks\":{\"Stop\":\"evil\"},\"model\":\"opus\",\"n\":1e400,\"s\":\"\\ud83d\\ude00\\n\",\"env\":{\"dup\":true}}",
    };
    const cases = [_]hook.CreateOptions{
        .{},
        rich,
        .{ .extra_settings_json = "{}" },
        .{ .extra_settings_json = "{\"hooks\":{}}" },
        .{ .extra_settings_json = "{\"a\":[1,2" },
        .{ .extra_settings_json = "[\"not\",\"an\",\"object\"]" },
        .{ .extra_settings_json = "{\"a\":\"\\ud800\"}" },
        .{ .extra_settings_json = "{\"a\":" ++ "[" ** 200 ++ "]" ** 200 ++ "}" },
        .{ .extra_hooks = &.{.{ .event = "", .command = "x" }}, .extra_settings_json = "{\"a\":1}" },
        .{ .extra_hooks = &.{.{ .event = "Stop", .command = "\xff" }} },
    };
    for (cases) |opts| {
        for ([_][]const u8{ "/tmp/hook.sh", "/tmp/will's dir/h'k.sh" }) |path| {
            try testing.checkAllAllocationFailures(testing.allocator, Ctx.build, .{ path, opts });
        }
    }

    // Generated option sets, so the OOM sweep is not limited to hand-picked shapes.
    var prng = Random.DefaultPrng.init(0x9a11_e030);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..12) |_| {
        const opts: hook.CreateOptions = .{
            .extra_hooks = try genExtraHooks(a, r, 6),
            .extra_settings_json = if (r.boolean()) try genSettingsObject(a, r) else try genMalformedSettings(a, r),
        };
        if (opts.extra_settings_json.?.len > 400) continue;
        try testing.checkAllAllocationFailures(testing.allocator, Ctx.build, .{ try genScriptPath(a, r), opts });
    }

    // createWithOptions: a failed allocation at any point leaves no directory behind.
    const before = try countOwnTmpDirs();
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.create, .{@as(hook.CreateOptions, .{})});
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.create, .{rich});
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.create, .{cases[4]});
    try testing.expectEqual(before, try countOwnTmpDirs());
}

// ---------------------------------------------------------------------------
// Round 1 fixes: nonce relay, StopFailure, disableAllHooks, TMPDIR handling
// ---------------------------------------------------------------------------

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Set or unset TMPDIR for this process; `restore` puts the old value back.
const TmpdirOverride = struct {
    saved: ?[:0]u8,

    fn set(value: ?[:0]const u8) !TmpdirOverride {
        const saved: ?[:0]u8 = if (std.posix.getenv("TMPDIR")) |old| try testing.allocator.dupeZ(u8, old) else null;
        if (value) |v| {
            try testing.expectEqual(@as(c_int, 0), setenv("TMPDIR", v.ptr, 1));
        } else {
            try testing.expectEqual(@as(c_int, 0), unsetenv("TMPDIR"));
        }
        return .{ .saved = saved };
    }

    fn restore(self: TmpdirOverride) void {
        if (self.saved) |old| {
            _ = setenv("TMPDIR", old.ptr, 1);
            testing.allocator.free(old);
        } else {
            _ = unsetenv("TMPDIR");
        }
    }
};

fn drainFifo(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return e,
        };
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

test "prop: parseLineWithNonce accepts the exact nonce and nothing else (3,000 trials)" {
    const seed: u64 = 0x9a11_e040;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = [_][]const u8{ "", "\n", "\r\n", "\r" };

    for (0..3000) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("parseLineWithNonce", seed, trial);

        var nonce: [hook.nonce_len]u8 = undefined;
        _ = try std.fmt.bufPrint(&nonce, "{x:0>16}", .{r.int(u64)});
        const event: []const u8 = if (r.boolean()) relay_events[r.uintLessThan(usize, relay_events.len)] else blk: {
            const e = try genBytes(a, r, 12);
            for (e) |*c| {
                if (c.* == '\t') c.* = ' ';
            }
            break :blk e;
        };
        var payload = try genBytes(a, r, 48);
        if (payload.len > 0 and (payload[payload.len - 1] == '\n' or payload[payload.len - 1] == '\r'))
            payload[payload.len - 1] = '}';
        const term = terms[r.uintLessThan(usize, terms.len)];
        const plain = try std.mem.concat(a, u8, &.{ event, "\t", payload, term });
        const raw = try std.mem.concat(a, u8, &.{ &nonce, "\t", plain });

        const line = hook.parseLineWithNonce(raw, &nonce) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(expectedEvent(event), line.event);
        try testing.expectEqualSlices(u8, payload, line.payload);
        try checkParseLine(raw);

        // Any single-character change to the expected nonce is refused.
        var wrong = nonce;
        const i = r.uintLessThan(usize, wrong.len);
        wrong[i] = if (wrong[i] == 'f') '0' else wrong[i] + 1;
        try testing.expect(hook.parseLineWithNonce(raw, &wrong) == null);
        // So are a truncated or extended expectation and the plain legacy line.
        try testing.expect(hook.parseLineWithNonce(raw, nonce[0 .. nonce.len - 1]) == null);
        try testing.expect(hook.parseLineWithNonce(raw, try std.mem.concat(a, u8, &.{ &nonce, "0" })) == null);
        if (!isNonceShaped(event)) try testing.expect(hook.parseLineWithNonce(plain, &nonce) == null);
        // The legacy line still parses with the nonce-blind parser.
        const legacy = hook.parseLine(plain) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(expectedEvent(event), legacy.event);
    }
}

test "prop: extractErrorMessage selects the highest-priority available description (2,000 trials)" {
    const seed: u64 = 0x9a11_e041;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{ "last_assistant_message", "error_details", "error", "message", "reason" };
    var lc = try LeakCheck.init();
    defer lc.deinit();

    for (0..2000) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("extractErrorMessage", seed, trial);

        // Each field is absent, a string, an object with a string message,
        // or a value that carries no text. Emit them in random key order.
        var want: ?[]const u8 = null;
        var members: [names.len][]const u8 = undefined;
        for (names, 0..) |name, i| {
            var m: Buf = .empty;
            const text = try genUtf8(a, r, 24, true);
            const kind = r.uintLessThan(u8, 6);
            if (kind != 0) {
                try writeJsonString(a, r, &m, name);
                try m.append(a, ':');
            }
            switch (kind) {
                0 => {},
                1, 2 => {
                    try writeJsonString(a, r, &m, text);
                    if (want == null) want = text;
                },
                3 => {
                    try m.appendSlice(a, "{\"type\":\"api_error\",\"message\":");
                    try writeJsonString(a, r, &m, text);
                    try m.append(a, '}');
                    if (want == null) want = text;
                },
                4 => try m.appendSlice(a, ([_][]const u8{ "null", "42", "true", "[\"x\"]", "{}", "{\"message\":7}" })[r.uintLessThan(usize, 6)]),
                else => try m.appendSlice(a, "{\"detail\":\"not a message\"}"),
            }
            members[i] = m.items;
        }
        r.shuffle([]const u8, &members);
        var doc: Buf = .empty;
        try doc.appendSlice(a, "{\"hook_event_name\":\"StopFailure\"");
        for (members) |m| {
            if (m.len == 0) continue;
            try doc.append(a, ',');
            try doc.appendSlice(a, m);
        }
        try doc.append(a, '}');

        const ta = lc.pick(trial);
        {
            const got = hook.extractErrorMessage(ta, doc.items);
            defer if (got) |g| ta.free(g);
            errdefer std.debug.print("doc={s}\n", .{doc.items});
            if (want) |w| {
                try testing.expectEqualSlices(u8, w, got orelse return error.TestExpectedString);
            } else {
                try testing.expect(got == null);
            }
        }
        // Arbitrary bytes never crash and never leak.
        if (hook.extractErrorMessage(ta, try genBytes(a, r, 48))) |g| ta.free(g);
        try lc.expectClean();
    }
}

test "prop: disableAllHooks true is rejected wherever the last top-level value is true (1,500 trials)" {
    const seed: u64 = 0x9a11_e042;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key_forms = [_][]const u8{ "\"disableAllHooks\"", "\"\\u0064isableAllHooks\"", "\"disableAllHook\\u0073\"" };
    const harmless = [_][]const u8{ "false", "null", "\"true\"", "1", "[true]", "{\"disableAllHooks\":true}" };

    const before = try countOwnTmpDirs();
    for (0..1500) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("disableAllHooks", seed, trial);

        // Splice members into a valid object. Duplicate keys resolve to the
        // last one, so only the final disableAllHooks member decides.
        const base = std.mem.trim(u8, try genSettingsObject(a, r), " \n\t\r");
        var doc: Buf = .empty;
        try doc.appendSlice(a, base[0 .. base.len - 1]);
        var has_members = std.mem.trim(u8, base[1 .. base.len - 1], " \n\t\r").len != 0;
        var last_true = false;
        for (0..1 + r.uintLessThan(usize, 3)) |_| {
            if (has_members) try doc.append(a, ',');
            has_members = true;
            try ws(a, r, &doc);
            try doc.appendSlice(a, key_forms[r.uintLessThan(usize, key_forms.len)]);
            try ws(a, r, &doc);
            try doc.append(a, ':');
            try ws(a, r, &doc);
            last_true = r.boolean();
            try doc.appendSlice(a, if (last_true) "true" else harmless[r.uintLessThan(usize, harmless.len)]);
            try ws(a, r, &doc);
        }
        try doc.append(a, '}');

        errdefer std.debug.print("doc={s}\n", .{doc.items});
        const opts: hook.CreateOptions = .{ .extra_settings_json = doc.items };
        try testing.expectEqual(!last_true, settingsShouldBeAccepted(a, doc.items));
        if (last_true) {
            try testing.expectError(error.InvalidExtraSettings, hook.validateExtraSettings(a, opts));
            try testing.expectError(error.InvalidExtraSettings, hook.buildSettingsJson(a, "/tmp/hook.sh", opts));
            try testing.expectError(error.InvalidExtraSettings, hook.createWithOptions(a, opts));
        } else {
            try hook.validateExtraSettings(a, opts);
            const json = try hook.buildSettingsJson(a, "/tmp/hook.sh", opts);
            try checkSettings(a, json, "/tmp/hook.sh", &.{}, doc.items);
        }
    }
    // Rejection happens before any directory is made.
    try testing.expectEqual(before, try countOwnTmpDirs());
}

test "prop: validateExtraSettings agrees with buildSettingsJson (1,500 trials)" {
    const seed: u64 = 0x9a11_e043;
    var prng = Random.DefaultPrng.init(seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lc = try LeakCheck.init();
    defer lc.deinit();

    for (0..1500) |trial| {
        _ = arena.reset(.retain_capacity);
        errdefer reportTrial("validateExtraSettings", seed, trial);
        const opts: hook.CreateOptions = .{
            .extra_hooks = try genExtraHooks(a, r, 6),
            .extra_settings_json = switch (r.uintLessThan(u8, 3)) {
                0 => null,
                1 => try genSettingsObject(a, r),
                else => try genMalformedSettings(a, r),
            },
        };
        const ta = lc.pick(trial);
        const built_ok = if (hook.buildSettingsJson(ta, "/tmp/hook.sh", opts)) |json| blk: {
            ta.free(json);
            break :blk true;
        } else |e| blk: {
            try testing.expectEqual(error.InvalidExtraSettings, e);
            break :blk false;
        };
        if (hook.validateExtraSettings(ta, opts)) |_| {
            try testing.expect(built_ok);
        } else |e| {
            try testing.expectEqual(error.InvalidExtraSettings, e);
            try testing.expect(!built_ok);
        }
        try lc.expectClean();
    }
}

test "resolveTmpRoot: absolute for every input, /tmp when unset or empty" {
    const a = testing.allocator;
    for ([_]?[]const u8{ null, "" }) |unset| {
        const root = try hook.resolveTmpRoot(a, unset);
        defer a.free(root);
        try testing.expectEqualStrings("/tmp", root);
    }
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    defer a.free(cwd);
    for ([_][]const u8{ ".", "./", "./." }) |rel| {
        const root = try hook.resolveTmpRoot(a, rel);
        defer a.free(root);
        try testing.expectEqualStrings(cwd, root);
    }
    for ([_][]const u8{ "/tmp", "/tmp/", "/private/var/folders/x y/T/", "/" }) |abs| {
        const root = try hook.resolveTmpRoot(a, abs);
        defer a.free(root);
        try testing.expectEqualStrings(abs, root);
    }
    try testing.expectError(error.FileNotFound, hook.resolveTmpRoot(a, "claude-p-no-such-dir/x"));
}

test "createWithOptions: unset or empty TMPDIR falls back to /tmp" {
    for ([_]?[:0]const u8{ null, "" }) |value| {
        const override = try TmpdirOverride.set(value);
        defer override.restore();
        var h = try hook.create(testing.allocator);
        defer h.deinit();
        try testing.expect(std.mem.startsWith(u8, h.tmp_dir, "/tmp/claude-p-"));
        const st = try std.fs.cwd().statFile(h.tmp_dir);
        try testing.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);
    }
}

test "createWithOptions: relative TMPDIR yields absolute paths that survive a child chdir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs_root = try tmp.dir.realpathAlloc(a, ".");
    const rel_root = try a.dupeZ(u8, ".zig-cache/tmp/" ++ tmp.sub_path);
    try testing.expect(!std.fs.path.isAbsolute(rel_root));

    const override = try TmpdirOverride.set(rel_root);
    defer override.restore();

    var h = try hook.create(testing.allocator);
    defer h.deinit();
    for ([_][]const u8{ h.tmp_dir, h.fifo_path, h.script_path }) |path| {
        try testing.expect(std.fs.path.isAbsolute(path));
        try testing.expect(std.mem.startsWith(u8, path, abs_root));
    }
    const st = try std.fs.cwd().statFile(h.tmp_dir);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);

    // Run the relay command from another directory with no CLAUDE_P_FIFO.
    const fd = try std.posix.openZ(try a.dupeZ(u8, h.fifo_path), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    defer std.posix.close(fd);
    var env = try std.process.getEnvMap(a);
    env.remove("CLAUDE_P_FIFO");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, h.settings_json, .{});
    const cmd = root.object.get("hooks").?.object.get("StopFailure").?.array.items[0]
        .object.get("hooks").?.array.items[0].object.get("command").?.string;
    const payload = "{\"error\":\"rate_limit\"}";
    const res = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "/bin/sh", "-c", try std.mem.concat(a, u8, &.{ "printf '%s' '", payload, "' | ", cmd }) },
        .env_map = &env,
        .cwd = "/",
    });
    try testing.expectEqualStrings("", res.stderr);
    try testing.expectEqual(@as(u8, 0), res.term.Exited);

    var buf: [4096]u8 = undefined;
    const got = try drainFifo(fd, &buf);
    const line = hook.parseLineWithNonce(got, &h.nonce) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(hook.HookEvent.stop_failure, line.event);
    try testing.expectEqualStrings(payload, line.payload);
    const message = (hook.extractErrorMessage(a, line.payload)) orelse return error.TestExpectedString;
    try testing.expectEqualStrings("rate_limit", message);
}

test "hook.sh: ignores CLAUDE_P_FIFO when the embedded FIFO is gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const script_path = try std.fs.path.join(a, &.{ dir, "it's hook.sh" });
    const sink = try std.fs.path.join(a, &.{ dir, "sink" });
    const nonce = "00112233aabbccdd";
    try tmp.dir.writeFile(.{
        .sub_path = "it's hook.sh",
        .data = try hook.buildScript(a, try std.fs.path.join(a, &.{ dir, "gone's.fifo" }), nonce),
    });

    var env = try std.process.getEnvMap(a);
    env.remove("CLAUDE_P_FIFO");
    const argv = [_][]const u8{ "/bin/sh", script_path, "Stop" };

    // No embedded FIFO and no CLAUDE_P_FIFO: fail loudly, write nothing.
    const missing = try std.process.Child.run(.{ .allocator = a, .argv = &argv, .env_map = &env });
    try testing.expect(missing.term.Exited != 0);
    try testing.expectError(error.FileNotFound, tmp.dir.access("sink", .{}));

    try env.put("CLAUDE_P_FIFO", sink);
    const res = try std.process.Child.run(.{ .allocator = a, .argv = &argv, .env_map = &env });
    try testing.expect(res.term.Exited != 0);
    try testing.expectError(error.FileNotFound, tmp.dir.access("sink", .{}));
}

test "createWithOptions: harness directories never collide and nonces never repeat (48 harnesses)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seen_dirs = std.StringHashMap(void).init(a);
    var seen_nonces = std.StringHashMap(void).init(a);
    var live: std.ArrayList(hook.HookHarness) = .empty;
    defer {
        for (live.items) |*h| h.deinit();
        live.deinit(a);
    }
    const before = try countOwnTmpDirs();
    for (0..48) |_| {
        try live.append(a, try hook.create(testing.allocator));
        const h = &live.items[live.items.len - 1];
        try testing.expect(!(try seen_dirs.fetchPut(try a.dupe(u8, h.tmp_dir), {}) != null));
        try testing.expect(!(try seen_nonces.fetchPut(try a.dupe(u8, &h.nonce), {}) != null));
        // The nonce is not the directory suffix.
        try testing.expect(!std.mem.endsWith(u8, h.tmp_dir, &h.nonce));
    }
    try testing.expectEqual(before + 48, try countOwnTmpDirs());
}
