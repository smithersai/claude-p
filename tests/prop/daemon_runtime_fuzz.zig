//! Deep coverage-guided fuzz targets and stateful model checkers for the
//! previously unfuzzed daemon surfaces:
//!   - `daemon.readFileRange` (including truncated-file short-pread & OOM)
//!   - `daemon.elapsedMs` (signed i128 extremes & u64 saturation)
//!   - `daemon.ptyTraceInterval` (`CLAUDE_P_PTY_TRACE` total env parser)
//!   - `daemon.stopBelongsToTurn`, `emitSystemInit`, `emitPong`, `toDriverOptions`
//!   - Full stateful daemon turn / interrupt / stale-Stop / watchdog / EOF FSM
const std = @import("std");
const claude_p = @import("claude_p");

const testing = std.testing;
const daemon = claude_p.daemon;
const hook = claude_p.hook;

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
// 1. daemon.readFileRange — truncated file / short-pread / OOM / boundaries
// ============================================================================

fn fuzzReadFileRange(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var cur: Cursor = .{ .data = input };
    const start_raw = cur.int(u16);
    const end_raw = cur.int(u16);
    const content = cur.rest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "turn.jsonl", .data = content });
    const file = try tmp.dir.openFile("turn.jsonl", .{});
    defer file.close();

    const start_pos: u64 = if (content.len == 0) start_raw % 32 else start_raw % (content.len + 32);
    const end_pos: u64 = if (content.len == 0) end_raw % 32 else end_raw % (content.len + 64);

    const got = try daemon.readFileRange(testing.allocator, file, start_pos, end_pos);
    defer testing.allocator.free(got);

    if (end_pos <= start_pos or start_pos >= content.len) {
        try testing.expectEqual(@as(usize, 0), got.len);
    } else {
        const s: usize = @intCast(start_pos);
        const e: usize = @intCast(@min(end_pos, content.len));
        try testing.expectEqualStrings(content[s..e], got);
    }
}

test "fuzz: daemon.readFileRange handles arbitrary bounds and short pread without allocator corruption" {
    try testing.fuzz({}, fuzzReadFileRange, .{
        .corpus = &.{
            "\x00\x00\x05\x00hello",
            "\x00\x00\x20\x00short", // end_pos > file length (concurrent truncation)
            "\x0a\x00\x02\x00hello world",
            "\x10\x00\x20\x00tiny",
            "\x00\x00\x00\x00",
        },
    });
}

test "prop: daemon.readFileRange clamps past EOF and leaks nothing on OOM" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "data.jsonl", .data = "0123456789abcdef" });
    const file = try tmp.dir.openFile("data.jsonl", .{});
    defer file.close();

    const Ctx = struct {
        fn call(alloc: std.mem.Allocator, f: std.fs.File) !void {
            const slice = try daemon.readFileRange(alloc, f, 2, 100);
            defer alloc.free(slice);
            try testing.expectEqualStrings("23456789abcdef", slice);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.call, .{file});

    var rng = std.Random.DefaultPrng.init(0xda3a0001);
    const r = rng.random();
    for (0..400) |_| {
        const s = r.intRangeAtMost(u64, 0, 32);
        const e = r.intRangeAtMost(u64, 0, 64);
        const got = try daemon.readFileRange(testing.allocator, file, s, e);
        defer testing.allocator.free(got);
        if (e <= s or s >= 16) {
            try testing.expectEqual(@as(usize, 0), got.len);
        } else {
            try testing.expectEqualStrings("0123456789abcdef"[@intCast(s)..@intCast(@min(e, 16))], got);
        }
    }
}

// ============================================================================
// 2. daemon.elapsedMs — i128 clock extremes & u64 saturation
// ============================================================================

fn fuzzElapsedMs(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var cur: Cursor = .{ .data = input };
    const start_ns = cur.int(i128);
    const now_ns = cur.int(i128);

    const ms = daemon.elapsedMs(start_ns, now_ns);
    if (now_ns <= start_ns) {
        try testing.expectEqual(@as(u64, 0), ms);
    } else {
        // Exact unsigned distance in nanoseconds: u128 can hold max(i128) - min(i128)!
        const diff_ns: u128 = @as(u128, @bitCast(now_ns)) -% @as(u128, @bitCast(start_ns));
        const want_u128 = diff_ns / @as(u128, std.time.ns_per_ms);
        const want: u64 = if (want_u128 > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(want_u128);
        try testing.expectEqual(want, ms);
    }
}

test "fuzz: daemon.elapsedMs total over all i128 clock extremes" {
    var extreme_min_max: [32]u8 = undefined;
    std.mem.writeInt(i128, extreme_min_max[0..16], std.math.minInt(i128), .little);
    std.mem.writeInt(i128, extreme_min_max[16..32], std.math.maxInt(i128), .little);

    var extreme_huge_pos: [32]u8 = undefined;
    std.mem.writeInt(i128, extreme_huge_pos[0..16], 0, .little);
    std.mem.writeInt(i128, extreme_huge_pos[16..32], std.math.maxInt(i128), .little);

    try testing.fuzz({}, fuzzElapsedMs, .{
        .corpus = &.{
            &extreme_min_max,
            &extreme_huge_pos,
            &([_]u8{0} ** 32),
        },
    });
}

// ============================================================================
// 3. daemon.ptyTraceInterval — CLAUDE_P_PTY_TRACE env parsing
// ============================================================================

fn expectPtyTrace(debug: bool, input: ?[]const u8) !void {
    const got = daemon.ptyTraceInterval(debug, input);
    const default: ?i128 = if (debug) 60 * std.time.ns_per_s else null;
    // Reference oracle: off/false/no or 0 disable, a positive u32 sets the
    // interval in seconds, anything else keeps the debug-dependent default.
    const want: ?i128 = blk: {
        const raw = input orelse break :blk default;
        const v = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false") or
            std.ascii.eqlIgnoreCase(v, "no")) break :blk null;
        const secs = std.fmt.parseInt(u32, v, 10) catch break :blk default;
        break :blk if (secs == 0) null else @as(i128, secs) * std.time.ns_per_s;
    };
    try testing.expectEqual(want, got);
    if (got) |ns| try testing.expect(ns >= std.time.ns_per_s);
}

fn fuzzPtyTrace(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    try expectPtyTrace(false, input);
    try expectPtyTrace(true, input);
    try expectPtyTrace(false, null);
    try expectPtyTrace(true, null);
}

test "fuzz: daemon.ptyTraceInterval total over arbitrary env values" {
    try testing.fuzz({}, fuzzPtyTrace, .{
        .corpus = &.{
            "   \t\r\n ",
            "00",
            " 0",
            "off",
            "OFF",
            "False",
            "NO",
            "01",
            "60",
            "4294967295",
            "4294967296",
            "-1",
            " 15\n",
            "on",
            "garbage",
        },
    });
}

// ============================================================================
// 4. daemon.emitSystemInit, emitPong, toDriverOptions, stopBelongsToTurn
// ============================================================================

fn fuzzDaemonEmitters(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    // 1. emitSystemInit always emits a single NDJSON line that round-trips exact UTF-8 session_id.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try daemon.emitSystemInit(&aw.writer, input);
    const line = aw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);

    if (std.unicode.utf8ValidateSlice(input)) {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{
            .duplicate_field_behavior = .@"error",
        });
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqualStrings("system", obj.get("type").?.string);
        try testing.expectEqualStrings("init", obj.get("subtype").?.string);
        try testing.expectEqualStrings(input, obj.get("session_id").?.string);
    }

    // 2. emitPong always emits valid single-line JSON with integer ts.
    var pw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer pw.deinit();
    try daemon.emitPong(&pw.writer);
    const pong = pw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, pong, "\n"));
    var parsed_pong = try std.json.parseFromSlice(std.json.Value, testing.allocator, pong, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed_pong.deinit();
    try testing.expectEqualStrings("pong", parsed_pong.value.object.get("type").?.string);
    try testing.expect(parsed_pong.value.object.get("ts").? == .integer);

    // 3. toDriverOptions preserves all fields faithfully and forces stream_json + null max_turns.
    const hooks = [_]hook.ExtraHook{.{ .event = "Stop", .command = input }};
    const drv = daemon.toDriverOptions(.{
        .model = input,
        .resume_session = input,
        .extra_hooks = &hooks,
        .extra_settings_json = input,
        .session_start_timeout_ms = input.len,
        .verbose = (input.len & 1) != 0,
    });
    try testing.expectEqual(claude_p.OutputFormat.stream_json, drv.output_format);
    try testing.expectEqual(@as(?u32, null), drv.max_turns);
    try testing.expectEqualStrings("", drv.prompt);
    try testing.expectEqualStrings(input, drv.model.?);
    try testing.expectEqualStrings(input, drv.resume_session.?);
    try testing.expectEqual(@as(u64, input.len), drv.timeout_ms);
}

test "fuzz: daemon.emitSystemInit, emitPong, and toDriverOptions" {
    try testing.fuzz({}, fuzzDaemonEmitters, .{
        .corpus = &.{
            "sid-123",
            "quote\"\\\n\r\t\x01\x1f",
            "utf8-🌿-❯",
            "\xff\xfe",
        },
    });
}

// ============================================================================
// 5. Stateful daemon turn / interrupt / stale-Stop / watchdog / EOF model
// ============================================================================

fn fuzzDaemonStateMachine(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var cur: Cursor = .{ .data = input };

    var state: daemon.State = .waiting_for_ready;
    var now_ns: i128 = 10_000_000 * std.time.ns_per_ms;
    var last_pty_ns: i64 = 0;
    var last_tr_ns: i64 = 0;
    var turn_start_pos: u64 = 0;
    var tailer_pos: u64 = 0;
    var after_interrupt = false;
    var prompt_acked = false;
    var interrupting = false;
    var interrupt_deadline_ns: i128 = 0;
    var queued: usize = 0;
    var stdin_eof = false;
    var turns_completed: usize = 0;
    var turns_interrupted: usize = 0;
    var prompts_dispatched: usize = 0;

    const idle_ms: u64 = 180_000;
    const tr_ms: u64 = 600_000;

    while (cur.rem() > 0) {
        const op = cur.byte() % 11;
        switch (op) {
            0 => { // SessionStart hook
                if (state == .waiting_for_ready) state = .idle;
            },
            1 => { // User prompt arrives on stdin (only before EOF)
                if (!stdin_eof) queued += 1;
            },
            2 => { // Dispatch queued prompt if idle (mirrors daemon main loop)
                if (state == .idle and queued > 0) {
                    queued -= 1;
                    if (after_interrupt) {
                        turn_start_pos = tailer_pos;
                    }
                    last_pty_ns = @intCast(now_ns);
                    last_tr_ns = @intCast(now_ns);
                    prompt_acked = false;
                    interrupting = false;
                    state = .busy;
                    prompts_dispatched += 1;
                }
            },
            3 => { // PTY spinner output: updates PTY clock ONLY, never transcript clock!
                last_pty_ns = @intCast(now_ns);
            },
            4 => { // Transcript grows: updates tailer_pos + transcript clock
                tailer_pos += 1 + @as(u64, cur.byte() % 64);
                last_tr_ns = @intCast(now_ns);
            },
            5 => { // UserPromptSubmit hook
                if (state == .busy) prompt_acked = true;
            },
            6 => { // Interrupt frame from hub
                if (state == .busy and !interrupting) {
                    interrupting = true;
                    interrupt_deadline_ns = now_ns + @as(i128, daemon.interrupt_window_ms) * std.time.ns_per_ms;
                }
            },
            7 => { // Advance clock by 500ms..120s
                const step_ms: i128 = @as(i128, 500) + @as(i128, cur.byte()) * 500;
                now_ns += step_ms * std.time.ns_per_ms;

                // INVARIANT 1: Watchdogs NEVER trip while not busy!
                if (state != .busy) {
                    try testing.expect(!daemon.idleTimedOut(state, last_pty_ns, now_ns, idle_ms));
                    try testing.expect(!daemon.transcriptStalled(state, last_tr_ns, now_ns, tr_ms));
                }

                // Check interrupt window expiry
                if (state == .busy and interrupting and now_ns >= interrupt_deadline_ns) {
                    interrupting = false;
                    after_interrupt = true;
                    turn_start_pos = tailer_pos;
                    state = .idle;
                    turns_interrupted += 1;
                }
            },
            8 => { // Stop hook arrives
                const advanced = tailer_pos > turn_start_pos;
                const ok = daemon.stopBelongsToTurn(state, prompt_acked);
                // INVARIANT 2: a Stop never ends a turn that is not busy.
                if (state != .busy) try testing.expect(!ok);
                if (state == .busy) {
                    if (ok) {
                        // INVARIANT 2b: only this turn's UserPromptSubmit ends it.
                        // Transcript growth alone may be residue from an
                        // interrupted turn, so it never makes a Stop belong.
                        try testing.expect(prompt_acked);
                        turn_start_pos = tailer_pos;
                        interrupting = false;
                        after_interrupt = false;
                        state = .idle;
                        turns_completed += 1;
                    } else {
                        // Must remain busy when rejecting stale Stop
                        try testing.expect(!prompt_acked);
                        _ = advanced;
                    }
                }
            },
            9 => { // Spinner wedge check: PTY alive while transcript silent > 600s MUST stall transcript ONLY
                if (state == .busy) {
                    const before_tr = last_tr_ns;
                    now_ns += 601_000 * std.time.ns_per_ms;
                    last_pty_ns = @intCast(now_ns); // spinner ticks!
                    try testing.expect(!daemon.idleTimedOut(state, last_pty_ns, now_ns, idle_ms));
                    if (before_tr != 0) {
                        try testing.expect(daemon.transcriptStalled(state, before_tr, now_ns, tr_ms));
                    }
                    // Reset transcript clock so simulation can keep exploring
                    last_tr_ns = @intCast(now_ns);
                }
            },
            else => { // Stdin EOF: daemon only exits once idle AND queue is empty!
                stdin_eof = true;
                if (state == .idle and queued == 0) {
                    // INVARIANT 3: every dispatched turn either completed or was interrupted!
                    try testing.expectEqual(prompts_dispatched, turns_completed + turns_interrupted);
                    return;
                }
            },
        }
    }
    // At any point while not busy, dispatched == completed + interrupted.
    if (state != .busy) {
        try testing.expectEqual(prompts_dispatched, turns_completed + turns_interrupted);
    }
}

test "fuzz: daemon turn, interrupt, stale-Stop, and watchdog state machine" {
    try testing.fuzz({}, fuzzDaemonStateMachine, .{
        .corpus = &.{
            "\x00\x01\x02\x06\x07\x10\x01\x02\x08\x05\x08\x0a",
            "\x00\x01\x02\x09\x08\x0a",
            "\x00\x01\x01\x02\x0a\x08\x02\x08\x0a",
            "\x00\x01\x02\x06\x08\x07\x10\x0a",
        },
    });
}
