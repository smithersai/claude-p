//! Per-turn transcript cursor, pending Stop confirmation, and chunked paste state.
const std = @import("std");
const zmux = @import("zmux");
const driver_mod = @import("../driver.zig");
const emit_mod = @import("../emit.zig");
const hook_mod = @import("../hook.zig");
const stream_mod = @import("../stream.zig");
const transcript_mod = @import("../transcript.zig");
const protocol = @import("protocol.zig");

fn monotonicNs() i64 {
    return @intCast(driver_mod.monotonicNs());
}

/// Read the byte range `[start_pos..end_pos)` from a file via `pread`.
/// Caller owns the returned slice.
pub fn readFileRange(allocator: std.mem.Allocator, file: std.fs.File, start_pos: u64, end_pos: u64) ![]u8 {
    const len = std.math.cast(usize, end_pos -| start_pos) orelse return error.OutOfMemory;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const done = try file.preadAll(buf, start_pos);
    std.debug.assert(done <= len);
    return if (done == len) buf else try allocator.realloc(buf, done);
}

/// Tracks the active transcript file, inode, turn offset, and live stream tailer.
pub const TurnTranscript = struct {
    path: ?[]u8 = null,
    tailer: ?stream_mod.Tailer = null,
    inode: ?std.fs.File.INode = null,
    start: ?u64 = null,
    size: u64 = 0,
    initial_resume: bool,
    first_turn: bool = true,
    allow_zero_offset: bool = false,
    searched_size: ?u64 = null,
    minimum_prompt_offset: u64 = 0,

    pub fn reset(self: *TurnTranscript) void {
        if (self.tailer) |*t| t.deinit();
        self.tailer = null;
        self.inode = null;
        self.allow_zero_offset = false;
        self.start = null;
        self.size = 0;
        self.searched_size = null;
        self.minimum_prompt_offset = 0;
        std.debug.assert(self.tailer == null and self.size == 0);
    }

    pub fn deinit(self: *TurnTranscript, allocator: std.mem.Allocator) void {
        self.reset();
        if (self.path) |p| allocator.free(p);
    }

    pub fn observePath(self: *TurnTranscript, allocator: std.mem.Allocator, payload: []const u8) !void {
        const path = try driver_mod.extractSafeTranscriptPath(allocator, payload) orelse return;
        std.debug.assert(path.len > 0 and path[0] == '/');
        if (self.path) |old| {
            if (std.mem.eql(u8, old, path)) {
                allocator.free(path);
                return;
            }
            allocator.free(old);
        }
        self.reset();
        self.path = path;
    }

    pub fn begin(self: *TurnTranscript, allocator: std.mem.Allocator, after_interrupt: bool) void {
        const fresh = self.first_turn and !self.initial_resume and !after_interrupt;
        self.first_turn = false;
        self.reset();
        const path = self.path orelse return;
        var t = stream_mod.Tailer.open(allocator, path) catch |err| {
            self.allow_zero_offset = err == error.FileNotFound and fresh;
            return;
        };
        const stat = t.file.stat() catch {
            t.deinit();
            return;
        };
        self.inode = stat.inode;
        self.size = stat.size;
        self.initial_resume = false;
        if (after_interrupt) {
            self.minimum_prompt_offset = stat.size;
            t.deinit();
            return;
        }
        self.start = stat.size;
        t.pos = stat.size;
        self.tailer = t;
    }

    pub fn refresh(self: *TurnTranscript, allocator: std.mem.Allocator, prompt: []const u8, recover: bool) void {
        const path = self.path orelse return;
        const file = transcript_mod.openTranscriptRegularFile(path) catch |err| {
            if (err != error.FileNotFound or self.inode != null) self.reset();
            return;
        };
        defer file.close();
        const stat = file.stat() catch return;
        if ((self.inode != null and self.inode != stat.inode) or stat.size < self.size or
            (self.tailer != null and stat.size < self.tailer.?.pos)) self.reset();
        self.size = stat.size;
        self.inode = stat.inode;
        if (self.tailer != null or !recover or self.searched_size == stat.size) return;
        self.searched_size = stat.size;
        const offset = driver_mod.findPromptTurnOffset(allocator, path, prompt) orelse
            if (self.allow_zero_offset) @as(u64, 0) else return;
        if (offset < self.minimum_prompt_offset) return;
        var t = stream_mod.Tailer.open(allocator, path) catch return;
        const opened = t.file.stat() catch {
            t.deinit();
            return;
        };
        if (opened.inode != stat.inode or opened.size < stat.size) {
            t.deinit();
            return;
        }
        std.debug.assert(offset <= opened.size);
        self.start = offset;
        self.initial_resume = false;
        t.pos = offset;
        self.tailer = t;
    }
};

/// Provisional Stop hook awaiting confirmation against late continuation records.
pub const PendingStop = struct {
    payload: []u8,
    deadline: i128,
    inode: ?std.fs.File.INode,
    scan_pos: u64,

    pub fn status(
        self: *PendingStop,
        allocator: std.mem.Allocator,
        transcript: *TurnTranscript,
        prompt: []const u8,
    ) !driver_mod.StopSummaryStatus {
        if (self.inode != transcript.inode or self.scan_pos > transcript.size) {
            self.scan_pos = transcript.start orelse transcript.size;
            self.inode = transcript.inode;
        }
        if (transcript.size <= self.scan_pos) return .none;
        const file = transcript_mod.openTranscriptRegularFile(transcript.path orelse return .none) catch return .none;
        defer file.close();
        if ((file.stat() catch return .none).inode != self.inode) return .none;
        const last = try hook_mod.extractLastAssistantMessage(allocator, self.payload);
        defer if (last) |text| allocator.free(text);
        return driver_mod.scanStopRecords(allocator, file, &self.scan_pos, transcript.size, last, prompt) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => .none,
            };
    }
};

/// Non-blocking state machine that paces bracketed-paste writes between loop ticks.
pub const PendingPaste = struct {
    chunker: driver_mod.PasteChunker,
    stage: enum { chunks, enter_debounce } = .chunks,
    next_at_ns: i128 = 0,
    is_reinject: bool,

    pub fn init(text: []const u8, is_reinject: bool) PendingPaste {
        return .{ .chunker = .{ .text = text }, .is_reinject = is_reinject };
    }

    pub fn advance(self: *PendingPaste, sink: anytype) !bool {
        const now: i128 = monotonicNs();
        if (now < self.next_at_ns) return false;
        switch (self.stage) {
            .chunks => {
                if (self.chunker.pos == 0) try sink.writeInput(driver_mod.paste_start);
                var buf: [driver_mod.paste_chunk_bytes]u8 = undefined;
                if (self.chunker.next(&buf)) |chunk| {
                    std.debug.assert(chunk.len > 0 and chunk.len <= buf.len);
                    try sink.writeInput(chunk);
                    self.next_at_ns = now + driver_mod.paste_chunk_gap_ms * std.time.ns_per_ms;
                } else {
                    try sink.writeInput(driver_mod.paste_end);
                    self.stage = .enter_debounce;
                    self.next_at_ns = now + driver_mod.ink_enter_debounce_ms * std.time.ns_per_ms;
                }
                return false;
            },
            .enter_debounce => {
                try sink.writeInput("\r");
                return true;
            },
        }
    }

    pub fn cancel(self: PendingPaste, sink: anytype) !void {
        if (self.stage == .chunks and self.chunker.pos != 0) try sink.writeInput(driver_mod.paste_end);
        try sink.writeInput("\x15");
    }
};

/// Free and clear any pending provisional Stop hook.
pub fn clearStop(allocator: std.mem.Allocator, pending: *?PendingStop) void {
    if (pending.*) |stop| allocator.free(stop.payload);
    pending.* = null;
    std.debug.assert(pending.* == null);
}

/// Pump new JSONL transcript lines to `writer`, retrying transient read failures.
pub fn pumpTranscript(tailer: *stream_mod.Tailer, writer: *std.Io.Writer) !usize {
    std.debug.assert(@intFromPtr(writer) != 0);
    const lines = tailer.pump(writer) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return e,
        else => 0,
    };
    if (lines > 0) try writer.flush();
    return lines;
}

fn pollTurnSummary(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    transcript: *TurnTranscript,
    prompt: []const u8,
    stop_last: ?[]const u8,
    failed: bool,
) !?transcript_mod.Summary {
    var summary: ?transcript_mod.Summary = null;
    errdefer if (summary) |*c| c.deinit(allocator);
    var parsed_pos: ?u64 = null;
    for (0..30) |attempt| {
        const inode = transcript.inode;
        const start = transcript.start;
        transcript.refresh(allocator, prompt, true);
        if (inode != transcript.inode or start != transcript.start or
            (parsed_pos != null and transcript.size < parsed_pos.?))
        {
            if (summary) |*c| c.deinit(allocator);
            summary = null;
            parsed_pos = null;
        }
        const t = if (transcript.tailer) |*t| t else {
            if (transcript.path == null or attempt + 1 == 30) break;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            continue;
        };
        _ = try pumpTranscript(t, writer);
        const ready = parsed_pos != t.pos and t.pos > transcript.start.? and
            t.pos - transcript.start.? <= 64 * 1024 * 1024;
        if (ready) {
            parsed_pos = t.pos;
            const bytes = readFileRange(allocator, t.file, transcript.start.?, t.pos) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break,
            };
            defer allocator.free(bytes);
            const parse_opts: transcript_mod.ParseOptions = .{
                .keep_replay = false,
                .stop_text = if (failed) null else stop_last,
            };
            if (transcript_mod.parseWithOptions(allocator, bytes, parse_opts)) |parsed| {
                if (summary) |*c| c.deinit(allocator);
                summary = parsed;
                const done = failed or ((parsed.final_text.len > 0 or parsed.is_error) and
                    driver_mod.finalTextMatchesStop(parsed.final_text, stop_last));
                if (done) break;
            } else |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            }
        }
        if (attempt + 1 < 30) std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return summary;
}

fn emitFallbackStopLast(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    stop_payload: []const u8,
    last: []u8,
    session_id: []const u8,
    duration: u64,
) !bool {
    std.debug.assert(@intFromPtr(writer) != 0);
    if (std.mem.trim(u8, last, " \t\r\n").len == 0) return false;
    const sid = try hook_mod.extractSessionId(allocator, stop_payload);
    defer if (sid) |id| allocator.free(id);
    const fallback: transcript_mod.Summary = .{
        .session_id = @constCast(sid orelse session_id),
        .final_text = last,
        .num_turns = 1,
        .is_error = false,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = &.{},
    };
    try emit_mod.emitJson(allocator, writer, .{ .summary = &fallback, .duration_ms = duration });
    try writer.flush();
    return true;
}

/// Drain the transcript tail, resolve final summary or fallback, and emit one result line.
pub fn emitTurnResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    transcript: *TurnTranscript,
    prompt: []const u8,
    stop_payload: []const u8,
    failed: bool,
    turn_start_ns: i128,
    session_id: []const u8,
) !void {
    std.debug.assert(@intFromPtr(writer) != 0);
    const stop_last = try hook_mod.extractLastAssistantMessage(allocator, stop_payload);
    defer if (stop_last) |last| allocator.free(last);
    var summary = try pollTurnSummary(allocator, writer, transcript, prompt, stop_last, failed);
    defer if (summary) |*c| c.deinit(allocator);
    if (transcript.tailer) |*t| try t.flushPartial(writer);
    const duration = protocol.elapsedMs(turn_start_ns, monotonicNs());
    if (failed) {
        if (summary) |*s| {
            if (try hook_mod.extractErrorMessageAlloc(allocator, stop_payload)) |message| {
                if (std.mem.trim(u8, message, " \t\r\n").len > 0) {
                    allocator.free(s.final_text);
                    s.final_text = message;
                } else allocator.free(message);
            }
            s.is_error = true;
            if (s.subtype) |old| allocator.free(old);
            s.subtype = null;
        } else {
            summary = try driver_mod.synthesizeStopFailureSummary(allocator, stop_payload);
        }
    } else if (summary) |*s| {
        try driver_mod.preferStopText(allocator, s, stop_last);
    } else if (stop_last) |last| {
        if (try emitFallbackStopLast(allocator, writer, stop_payload, last, session_id, duration)) return;
    }
    if (summary) |*s| {
        if (s.final_text.len > 0 or s.is_error) {
            if (s.session_id.len == 0) s.session_id = try allocator.dupe(u8, session_id);
            try emit_mod.emitJson(allocator, writer, .{
                .summary = s,
                .duration_ms = duration,
                .error_reason = if (failed) "stop_failure" else null,
            });
            return writer.flush();
        }
    }
    try protocol.writeError(allocator, writer, "result_unavailable", session_id, duration);
}

// -------- tests --------
const testing = std.testing;

test "readFileRange: returns exact owned bytes on short reads and EOF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t", .data = "abc" });
    const file = try tmp.dir.openFile("t", .{});
    defer file.close();
    const s1 = try readFileRange(testing.allocator, file, 1, 300);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("bc", s1);
    const s2 = try readFileRange(testing.allocator, file, 3, 300);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("", s2);
}

test "readFileRange: start past end returns empty slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t", .data = "hello" });
    const file = try tmp.dir.openFile("t", .{});
    defer file.close();
    const s = try readFileRange(testing.allocator, file, 5, 2);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}

test "readFileRange: reads middle window accurately" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t", .data = "0123456789" });
    const file = try tmp.dir.openFile("t", .{});
    defer file.close();
    const s = try readFileRange(testing.allocator, file, 2, 7);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("23456", s);
}

test "TurnTranscript: observePath stores valid path and deduplicates repeats" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/tmp/a.jsonl\"}");
    try testing.expectEqualStrings("/tmp/a.jsonl", tr.path.?);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/tmp/a.jsonl\"}");
    try testing.expectEqualStrings("/tmp/a.jsonl", tr.path.?);
}

test "TurnTranscript: observePath rejects relative or traversal path" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"../bad.jsonl\"}");
    try testing.expect(tr.path == null);
}

test "TurnTranscript: observePath switches path and resets cursor" {
    var tr: TurnTranscript = .{ .initial_resume = false, .size = 99, .start = 10 };
    defer tr.deinit(testing.allocator);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/tmp/one.jsonl\"}");
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/tmp/two.jsonl\"}");
    try testing.expectEqualStrings("/tmp/two.jsonl", tr.path.?);
    try testing.expectEqual(@as(?u64, null), tr.start);
    try testing.expectEqual(@as(u64, 0), tr.size);
}

test "TurnTranscript: begin on missing fresh file enables allow_zero_offset" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/nonexistent/claude-p-turn.jsonl\"}");
    tr.begin(testing.allocator, false);
    try testing.expect(tr.allow_zero_offset);
    try testing.expect(tr.tailer == null);
}

test "TurnTranscript: begin on missing resumed file keeps allow_zero_offset false" {
    var tr: TurnTranscript = .{ .initial_resume = true };
    defer tr.deinit(testing.allocator);
    try tr.observePath(testing.allocator, "{\"transcript_path\":\"/nonexistent/claude-p-res.jsonl\"}");
    tr.begin(testing.allocator, false);
    try testing.expect(!tr.allow_zero_offset);
}

test "TurnTranscript: begin opens existing file at EOF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"a\":1}\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var tr: TurnTranscript = .{ .initial_resume = false, .path = try testing.allocator.dupe(u8, path) };
    defer tr.deinit(testing.allocator);
    tr.begin(testing.allocator, false);
    try testing.expectEqual(@as(?u64, 8), tr.start);
    try testing.expect(tr.tailer != null);
    try testing.expectEqual(@as(u64, 8), tr.tailer.?.pos);
}

test "TurnTranscript: begin after_interrupt records minimum_prompt_offset without tailer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"old\":1}\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var tr: TurnTranscript = .{ .initial_resume = false, .path = try testing.allocator.dupe(u8, path) };
    defer tr.deinit(testing.allocator);
    tr.begin(testing.allocator, true);
    try testing.expect(tr.tailer == null);
    try testing.expectEqual(@as(u64, 10), tr.minimum_prompt_offset);
}

test "TurnTranscript: refresh detects truncation and recovers matched prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rec = "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = rec ++ rec });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var tr: TurnTranscript = .{ .initial_resume = false, .path = try testing.allocator.dupe(u8, path) };
    defer tr.deinit(testing.allocator);
    tr.begin(testing.allocator, false);
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = rec });
    tr.refresh(testing.allocator, "hi", true);
    try testing.expect(tr.tailer != null);
    try testing.expectEqual(@as(?u64, 0), tr.start);
}

test "PendingStop: clearStop frees payload and nulls slot" {
    var ps: ?PendingStop = .{
        .payload = try testing.allocator.dupe(u8, "{}"),
        .deadline = 0,
        .inode = null,
        .scan_pos = 0,
    };
    clearStop(testing.allocator, &ps);
    try testing.expect(ps == null);
}

test "PendingStop: status returns none without path" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    var ps: PendingStop = .{
        .payload = try testing.allocator.dupe(u8, "{}"),
        .deadline = 0,
        .inode = null,
        .scan_pos = 0,
    };
    defer testing.allocator.free(ps.payload);
    try testing.expectEqual(driver_mod.StopSummaryStatus.none, try ps.status(testing.allocator, &tr, "hi"));
}

test "PendingStop: status confirms stop_hook_summary record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":false}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = line });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    var tr: TurnTranscript = .{ .initial_resume = false, .path = try testing.allocator.dupe(u8, path) };
    defer tr.deinit(testing.allocator);
    tr.refresh(testing.allocator, "p", false);
    var ps: PendingStop = .{
        .payload = try testing.allocator.dupe(u8, "{}"),
        .deadline = 0,
        .inode = tr.inode,
        .scan_pos = 0,
    };
    defer testing.allocator.free(ps.payload);
    try testing.expectEqual(driver_mod.StopSummaryStatus.confirmed, try ps.status(testing.allocator, &tr, "p"));
}

test "PendingPaste: advances through paste_start, chunk, paste_end, and CR" {
    const Sink = struct {
        buf: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.alloc, data);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.buf.deinit(testing.allocator);
    var paste = PendingPaste.init("hello", false);
    while (true) {
        paste.next_at_ns = 0;
        if (try paste.advance(&sink)) break;
    }
    try testing.expectEqualStrings(driver_mod.paste_start ++ "hello" ++ driver_mod.paste_end ++ "\r", sink.buf.items);
}

test "PendingPaste: cancel mid-paste closes bracketed paste before Ctrl-U" {
    const Sink = struct {
        buf: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.alloc, data);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.buf.deinit(testing.allocator);
    var paste = PendingPaste.init("a" ** 600, false);
    try testing.expect(!(try paste.advance(&sink)));
    try paste.cancel(&sink);
    try testing.expect(std.mem.endsWith(u8, sink.buf.items, driver_mod.paste_end ++ "\x15"));
}

test "PendingPaste: cancel before first byte sends only Ctrl-U" {
    const Sink = struct {
        buf: std.ArrayList(u8) = .{},
        alloc: std.mem.Allocator,
        pub fn writeInput(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.alloc, data);
        }
    };
    var sink: Sink = .{ .alloc = testing.allocator };
    defer sink.buf.deinit(testing.allocator);
    const paste = PendingPaste.init("abc", true);
    try paste.cancel(&sink);
    try testing.expectEqualStrings("\x15", sink.buf.items);
}

test "emitTurnResult: uses stop_last fallback when transcript unavailable" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const payload = "{\"session_id\":\"s1\",\"last_assistant_message\":\"done\"}";
    try emitTurnResult(testing.allocator, &aw.writer, &tr, "p", payload, false, 0, "s0");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"result\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"session_id\":\"s1\"") != null);
}

test "emitTurnResult: emits result_unavailable when both transcript and stop text are empty" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitTurnResult(testing.allocator, &aw.writer, &tr, "p", "{}", false, 0, "s0");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"error\":\"result_unavailable\"") != null);
}

test "emitTurnResult: synthesizes StopFailure summary when transcript missing" {
    var tr: TurnTranscript = .{ .initial_resume = false };
    defer tr.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const payload = "{\"session_id\":\"s9\",\"error\":\"quota exceeded\"}";
    try emitTurnResult(testing.allocator, &aw.writer, &tr, "p", payload, true, 0, "s0");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"error\":\"stop_failure\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"result\":\"quota exceeded\"") != null);
}
