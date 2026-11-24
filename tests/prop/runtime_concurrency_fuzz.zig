//! Runtime, concurrency, and end-to-end PTY/FIFO fuzz tests for `driver.zig`:
//!   - `std.testing.fuzz`: `driver.promptWatchdogAction`, `finalTextMatchesStop`, `isResumeRun`
//!   - Multi-threaded concurrency hammer on `driver.onZmuxEvent` + `SharedState`
//!     (rolling 8192-byte ring cap, exact `bytes_seen`, `pending_to_pty` DEC reply grammar,
//!     concurrent `stripCsiInto` + dialog FSM reads under real OS threads)
//!   - Real in-process zmux PTY + FIFO randomized end-to-end fuzzing of `driver.run`
//!     across multi-KB UTF-8 prompts, embedded `\x1b[201~`, and Claude 2.1 dialogs.
const std = @import("std");
const claude_p = @import("claude_p");
const zmux = @import("zmux");

const testing = std.testing;
const driver = claude_p.driver;

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

    fn bytes(self: *Cursor, max_len: usize) []const u8 {
        if (self.rem() == 0 or max_len == 0) return "";
        const want = @min(@as(usize, self.byte()), @min(max_len, self.rem()));
        const out = self.data[self.pos .. self.pos + want];
        self.pos += want;
        return out;
    }

    fn rest(self: *Cursor) []const u8 {
        const out = self.data[self.pos..];
        self.pos = self.data.len;
        return out;
    }
};

// ============================================================================
// 1. Coverage-guided fuzz: promptWatchdogAction, finalTextMatchesStop, isResumeRun
// ============================================================================

fn fuzzDriverHelpers(_: void, input: []const u8) anyerror!void {
    var cur: Cursor = .{ .data = input };
    const accepted = (cur.byte() & 1) != 0;
    const injections = cur.int(u32);
    const since_ms = cur.int(i64);

    // promptWatchdogAction exact contract
    const act = driver.promptWatchdogAction(accepted, injections, since_ms);
    if (accepted or since_ms <= @as(i64, @intCast(driver.prompt_accept_timeout_ms))) {
        try testing.expectEqual(driver.WatchdogAction.wait, act);
    } else if (injections >= driver.max_prompt_injections) {
        try testing.expectEqual(driver.WatchdogAction.give_up, act);
    } else {
        try testing.expectEqual(driver.WatchdogAction.reinject, act);
    }

    // finalTextMatchesStop reflexivity, whitespace-trimming, null/blank wildcard
    const a = cur.bytes(128);
    const b = cur.rest();
    try testing.expect(driver.finalTextMatchesStop(a, null));
    try testing.expect(driver.finalTextMatchesStop(a, ""));
    try testing.expect(driver.finalTextMatchesStop(a, " \t\r\n "));
    try testing.expect(driver.finalTextMatchesStop(a, a));
    const ta = std.mem.trim(u8, a, " \t\r\n");
    const tb = std.mem.trim(u8, b, " \t\r\n");
    try testing.expectEqual(tb.len == 0 or std.mem.eql(u8, ta, tb), driver.finalTextMatchesStop(a, b));

    // isResumeRun exact token model
    const extra = [_][]const u8{a};
    const is_res = driver.isResumeRun(.{ .prompt = "x", .extra_args = &extra });
    const want_res = std.mem.eql(u8, a, "--resume") or
        std.mem.eql(u8, a, "-r") or
        std.mem.eql(u8, a, "--continue") or
        std.mem.eql(u8, a, "-c") or
        std.mem.startsWith(u8, a, "--resume=");
    try testing.expectEqual(want_res, is_res);
    try testing.expect(driver.isResumeRun(.{ .prompt = "x", .cont = true }));
    try testing.expect(driver.isResumeRun(.{ .prompt = "x", .resume_session = a }));

    // Interaction invariant: PasteChunker's neutralized output must NEVER
    // trigger isPromptTruncated when delivered intact!
    var chunker: driver.PasteChunker = .{ .text = input };
    var cbuf: [driver.paste_chunk_bytes]u8 = undefined;
    var sent: std.ArrayList(u8) = .{};
    defer sent.deinit(testing.allocator);
    while (chunker.next(&cbuf)) |ch| try sent.appendSlice(testing.allocator, ch);
    try testing.expect(!driver.isPromptTruncated(input, sent.items));
}

test "fuzz: driver promptWatchdogAction, finalTextMatchesStop, and isResumeRun" {
    try testing.fuzz({}, fuzzDriverHelpers, .{
        .corpus = &.{
            "\x00\x04\x00\x00\x00\xff\x7f\x00\x00\x00\x00\x00\x00\x08--resumehello",
            "\x00\x01\x00\x00\x00\xa1\x0f\x00\x00\x00\x00\x00\x00\x0b--resume=id  hello\n",
            "\x01\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x80\x02-c",
        },
    });
}

// ============================================================================
// 2. Multi-threaded concurrency fuzz: onZmuxEvent + SharedState + Dialog FSM
// ============================================================================

fn expectValidDecReplyStream(bytes: []const u8) !void {
    const legal = [_][]const u8{
        "\x1b[?1;2c",
        "\x1b[>0;0;0c",
        "\x1b[1;1R",
        "\x1bP>|claude-p\x1b\\",
        "\x1b[8;40;120t",
    };
    var pos: usize = 0;
    while (pos < bytes.len) {
        var matched = false;
        for (legal) |tok| {
            if (std.mem.startsWith(u8, bytes[pos..], tok)) {
                pos += tok.len;
                matched = true;
                break;
            }
        }
        try testing.expect(matched);
    }
}

test "concurrency fuzz: onZmuxEvent + SharedState ring buffer, DEC replies, and dialog snapshots" {
    var shared: driver.SharedState = .{
        .session = undefined,
        .debug = false,
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
    }

    var done = std.atomic.Value(bool).init(false);
    var expected_bytes = std.atomic.Value(u64).init(0);

    const Producer = struct {
        fn run(sh: *driver.SharedState, done_flag: *std.atomic.Value(bool), total_out: *std.atomic.Value(u64)) void {
            var prng = std.Random.DefaultPrng.init(0xc0cc0001);
            const r = prng.random();
            var buf: [2048]u8 = undefined;
            var sum: u64 = 0;
            for (0..1500) |i| {
                const len: usize = switch (i % 4) {
                    0 => r.intRangeAtMost(usize, 1, 64),
                    1 => r.intRangeAtMost(usize, 65, 512),
                    2 => r.intRangeAtMost(usize, 513, 2048),
                    else => blk: {
                        const q = "\x1b[c\x1b[>c\x1b[6n\x1b[>q\x1b[18tQuick safety check trust folder \xe2\x9d\xaf No, exit\nYes, I trust";
                        @memcpy(buf[0..q.len], q);
                        break :blk q.len;
                    },
                };
                if (i % 4 != 3) r.bytes(buf[0..len]);
                driver.onZmuxEvent(@ptrCast(sh), .{ .pane_output = .{
                    .pane_id = "0",
                    .data = buf[0..len],
                } });
                sum += len;
            }
            total_out.store(sum, .seq_cst);
            done_flag.store(true, .seq_cst);
        }
    };

    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &shared, &done, &expected_bytes });

    var raw_buf: [driver.recent_capacity]u8 = undefined;
    var strip_buf: [driver.recent_capacity]u8 = undefined;
    var drained: std.ArrayList(u8) = .{};
    defer drained.deinit(testing.allocator);
    var prev_bytes: u64 = 0;

    while (!done.load(.seq_cst)) {
        shared.recent_mutex.lock();
        const cur_total = shared.bytes_seen.load(.seq_cst);
        const rec_len = shared.recent.items.len;
        try testing.expect(rec_len <= driver.recent_capacity);
        try testing.expect(cur_total >= prev_bytes);
        prev_bytes = cur_total;
        @memcpy(raw_buf[0..rec_len], shared.recent.items[0..rec_len]);
        shared.recent_mutex.unlock();

        const stripped = driver.stripCsiInto(&strip_buf, raw_buf[0..rec_len]);
        const kind = driver.classifyDialog(stripped);
        const analysis = driver.analyzeDialog(kind, stripped);
        const act = driver.chooseDialogAction(kind, analysis, .none);
        if (act == .confirm) try testing.expectEqual(driver.DialogSelection.affirmative, analysis.selection);

        shared.write_mutex.lock();
        if (shared.pending_to_pty.items.len > 0) {
            try drained.appendSlice(testing.allocator, shared.pending_to_pty.items);
            shared.pending_to_pty.clearRetainingCapacity();
        }
        shared.write_mutex.unlock();
    }

    thread.join();

    // Final drain after producer finishes.
    shared.write_mutex.lock();
    if (shared.pending_to_pty.items.len > 0) {
        try drained.appendSlice(testing.allocator, shared.pending_to_pty.items);
        shared.pending_to_pty.clearRetainingCapacity();
    }
    shared.write_mutex.unlock();

    try testing.expectEqual(expected_bytes.load(.seq_cst), shared.bytes_seen.load(.seq_cst));
    try testing.expect(shared.recent.items.len <= driver.recent_capacity);
    // Every single byte queued by the reader thread MUST be a valid DEC/XTerm reply token!
    try expectValidDecReplyStream(drained.items);
    try testing.expect(drained.items.len > 0);
}

// ============================================================================
// 3. End-to-end zmux PTY + FIFO randomized fuzzing of driver.run
// ============================================================================

test "e2e runtime fuzz: driver.run over real zmux PTY + FIFO with randomized UTF-8, TTYHOG, and ESC[201~ prompts" {
    const mock_script =
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\[ "$1" = --settings ]
        \\relay=$(python3 -c 'import json,shlex,sys; print(shlex.split(json.loads(sys.argv[1])["hooks"]["Stop"][0]["hooks"][0]["command"])[0])' "$2")
        \\printf '\033[c\033[>c\033[6n\033[>q\033[18t'
        \\printf '\033[?1;2c\033[>0;0;0c\033[1;1R\033P>|claude-p\033\\\033[8;40;120t' > dec_expected
        \\read_bytes "$(wc -c < dec_expected | tr -d ' ')" | cmp - dec_expected
        \\if [ -f "$PWD/with_dialog" ]; then
        \\  down=$(printf '\033[B')
        \\  enter=$(printf '\r')
        \\  printf 'Quick safety check: Is this a project you trust?\r\nreview this folder first.\r\n❯ No, exit\r\n  Yes, I trust this folder\r\n'
        \\  [ "$(read_bytes 3)" = "$down" ]
        \\  printf '\r  No, exit\r\n❯ Yes, I trust this folder\r\n'
        \\  [ "$(read_bytes 1)" = "$enter" ]
        \\fi
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\: > "$file"
        \\printf '{"transcript_path":"%s","session_id":"pty-fuzz"}' "$file" | "$relay" SessionStart
        \\{ printf '\033[200~'; cat expected_body; printf '\033[201~\r'; } > expected
        \\read_bytes "$(wc -c < expected | tr -d ' ')" | cmp - expected
        \\"$relay" UserPromptSubmit < submit.json
        \\cat reply.jsonl >> "$file"
        \\printf '{"transcript_path":"%s","session_id":"pty-fuzz","last_assistant_message":"ok"}' "$file" | "$relay" Stop
        \\
    ;

    var prng = std.Random.DefaultPrng.init(0x971f0001);
    const rng = prng.random();

    for (0..4) |round| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        {
            const f = try tmp.dir.createFile("mock-claude", .{ .mode = 0o700 });
            defer f.close();
            try f.writeAll(mock_script);
        }
        if ((round & 1) == 1) {
            try tmp.dir.writeFile(.{ .sub_path = "with_dialog", .data = "1" });
        }

        // Generate randomized prompts crossing 512B chunk & 1024B macOS TTYHOG boundaries,
        // with 4-byte UTF-8 emojis and embedded ESC[201~ breakout attempts!
        const target_len: usize = switch (round) {
            0 => 48,
            1 => 520,
            2 => 1300,
            else => 2600,
        };
        var prompt_buf: std.ArrayList(u8) = .{};
        defer prompt_buf.deinit(testing.allocator);
        while (prompt_buf.items.len < target_len) {
            switch (rng.intRangeAtMost(u8, 0, 5)) {
                0 => try prompt_buf.append(testing.allocator, rng.intRangeAtMost(u8, 'a', 'z')),
                1 => try prompt_buf.append(testing.allocator, rng.intRangeAtMost(u8, '0', '9')),
                2 => try prompt_buf.append(testing.allocator, ' '),
                3 => try prompt_buf.append(testing.allocator, '\n'),
                4 => try prompt_buf.appendSlice(testing.allocator, "\xf0\x9f\x8c\xbf"),
                else => try prompt_buf.appendSlice(testing.allocator, "\x1b[201~"),
            }
        }

        var chunker: driver.PasteChunker = .{ .text = prompt_buf.items };
        var cbuf: [driver.paste_chunk_bytes]u8 = undefined;
        var expected_body: std.ArrayList(u8) = .{};
        defer expected_body.deinit(testing.allocator);
        while (chunker.next(&cbuf)) |ch| try expected_body.appendSlice(testing.allocator, ch);
        try tmp.dir.writeFile(.{ .sub_path = "expected_body", .data = expected_body.items });

        const submit = try std.json.Stringify.valueAlloc(testing.allocator, .{ .prompt = expected_body.items }, .{});
        defer testing.allocator.free(submit);
        try tmp.dir.writeFile(.{ .sub_path = "submit.json", .data = submit });

        const reply = "{\"type\":\"assistant\",\"session_id\":\"pty-fuzz\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\n";
        try tmp.dir.writeFile(.{ .sub_path = "reply.jsonl", .data = reply });

        const program = try tmp.dir.realpathAlloc(testing.allocator, "mock-claude");
        defer testing.allocator.free(program);
        const cwd = std.fs.path.dirname(program).?;

        var result = try driver.run(testing.allocator, .{
            .claude_path = program,
            .cwd = cwd,
            .prompt = prompt_buf.items,
            .timeout_ms = 15_000,
        });
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings("ok", result.summary.final_text);
        try testing.expectEqualStrings("pty-fuzz", result.summary.session_id);
        try testing.expectEqual(@as(u64, 5), result.summary.usage.input_tokens);
    }
}
