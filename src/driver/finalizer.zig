//! Provisional Stop confirmation and final transcript/Stop summary resolution.
const std = @import("std");
const hook_mod = @import("../hook.zig");
const stream_mod = @import("../stream.zig");
const transcript_mod = @import("../transcript.zig");
const env = @import("env.zig");
const watchdog = @import("watchdog.zig");
const runtime = @import("runtime.zig");

const Options = env.Options;
const RunError = env.RunError;

/// Mutable Stop-hook and transcript tracking state resolved at turn completion.
pub const FinalizerState = struct {
    allocator: std.mem.Allocator,
    opts: Options = .{ .prompt = "hi" },
    deadline_ns: i128 = std.math.maxInt(i128),
    streaming: bool = false,
    transcript_path: ?[]u8 = null,
    pre_prompt_transcript_offset: ?u64 = null,
    stop_payload_owned: ?[]u8 = null,
    stop_failed: bool = false,
    confirm_until: i128 = 0,
    provisional_size: u64 = 0,
    stop_last: ?[]u8 = null,
    tailer: ?stream_mod.Tailer = null,
    total_lines_streamed: usize = 0,

    /// Free all owned paths, Stop payloads, and any open transcript tailer.
    pub fn deinit(self: *FinalizerState) void {
        if (self.transcript_path) |p| self.allocator.free(p);
        if (self.stop_payload_owned) |p| self.allocator.free(p);
        if (self.stop_last) |a| self.allocator.free(a);
        if (self.tailer) |*t| t.deinit();
    }

    /// Record a `Stop` or `StopFailure` hook payload and compute its confirmation deadline.
    pub fn recordStop(self: *FinalizerState, is_failure: bool, payload: []const u8) RunError!void {
        std.debug.assert(self.opts.prompt.len > 0);
        const replacement = try self.allocator.dupe(u8, payload);
        if (self.stop_payload_owned) |old| self.allocator.free(old);
        self.stop_payload_owned = replacement;
        if (self.stop_last) |old| self.allocator.free(old);
        self.stop_last = null;
        self.stop_last = try hook_mod.extractLastAssistantMessage(self.allocator, payload);
        self.stop_failed = is_failure;
        self.provisional_size = watchdog.transcriptSize(self.transcript_path) orelse 0;
        self.confirm_until = @min(
            self.deadline_ns,
            watchdog.monotonicNs() + watchdog.stopConfirmationNs(self.opts.extra_hooks),
        );
    }

    /// Confirm or cancel a provisional `Stop` hook using transcript records and grace window.
    pub fn checkProvisionalStop(self: *FinalizerState) RunError!bool {
        const payload = self.stop_payload_owned orelse return false;
        const status: watchdog.StopSummaryStatus = scan: {
            const path = self.transcript_path orelse break :scan .none;
            const file = transcript_mod.openTranscriptRegularFile(path) catch break :scan .none;
            defer file.close();
            const size = (file.stat() catch break :scan .none).size;
            if (size <= self.provisional_size) break :scan .none;
            break :scan watchdog.scanStopRecords(
                self.allocator,
                file,
                &self.provisional_size,
                size,
                self.stop_last,
                self.opts.prompt,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => .none,
            };
        };
        if (status == .continued) {
            self.allocator.free(payload);
            self.stop_payload_owned = null;
            return false;
        }
        return status == .confirmed or watchdog.monotonicNs() >= self.confirm_until;
    }

    /// Decide whether a parsed transcript summary can be accepted for this turn.
    pub fn acceptParsedSummary(
        self: *FinalizerState,
        parsed: *transcript_mod.Summary,
        attempt: usize,
    ) RunError!bool {
        std.debug.assert(attempt < 20);
        if (self.stop_failed) {
            if (try hook_mod.extractErrorMessageAlloc(self.allocator, self.stop_payload_owned.?)) |msg| {
                if (std.mem.trim(u8, msg, " \t\r\n").len > 0) {
                    self.allocator.free(parsed.final_text);
                    parsed.final_text = msg;
                } else self.allocator.free(msg);
            }
            parsed.is_error = true;
            if (parsed.subtype) |sub| if (std.mem.eql(u8, sub, "success")) {
                self.allocator.free(sub);
                parsed.subtype = null;
            };
            return true;
        }
        const matches = watchdog.finalTextMatchesStop(parsed.final_text, self.stop_last);
        if ((parsed.final_text.len > 0 or parsed.is_error) and matches) return true;
        if ((attempt == 19 or watchdog.monotonicNs() >= self.deadline_ns) and !matches) {
            try watchdog.preferStopText(self.allocator, parsed, self.stop_last);
            return true;
        }
        return false;
    }

    /// Build a minimal `Summary` directly from the authoritative `Stop` hook payload.
    pub fn fallbackStopSummary(self: *FinalizerState) RunError!transcript_mod.Summary {
        std.debug.assert(!self.stop_failed);
        const payload = self.stop_payload_owned orelse return RunError.TranscriptUnavailable;
        const text = self.stop_last orelse return RunError.TranscriptUnavailable;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return RunError.TranscriptUnavailable;
        const final_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(final_text);
        const sid = (try hook_mod.extractSessionId(self.allocator, payload)) orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(sid);
        return .{
            .final_text = final_text,
            .session_id = sid,
            .is_error = false,
            .num_turns = 1,
            .total_cost_usd = 0.0,
            .duration_api_ms = 0,
            .usage = .{},
            .jsonl_replay = try self.allocator.dupe(u8, ""),
        };
    }

    /// Parse the final turn summary from the transcript with Stop-payload fallbacks.
    pub fn resolveFinalSummary(self: *FinalizerState) RunError!transcript_mod.Summary {
        std.debug.assert(self.stop_failed or self.stop_payload_owned != null);
        const keep_replay = self.opts.retain_replay and self.opts.stream_writer == null;
        if (self.transcript_path) |path| if (self.pre_prompt_transcript_offset) |offset| {
            for (0..20) |attempt| {
                if (watchdog.isInterrupted()) return error.Interrupted;
                if (self.streaming and self.tailer == null) {
                    if (stream_mod.Tailer.open(self.allocator, path)) |t| {
                        self.tailer = t;
                        self.tailer.?.pos = offset;
                    } else |_| {}
                }
                if (self.tailer) |*t| {
                    self.total_lines_streamed += try runtime.pumpStream(t, self.opts.stream_writer.?);
                }
                const parse_opts: transcript_mod.ParseOptions = .{
                    .keep_replay = keep_replay,
                    .stop_text = if (self.stop_failed) null else self.stop_last,
                };
                if (transcript_mod.parseFileFromOffsetWithOptions(self.allocator, path, offset, parse_opts)) |cand| {
                    var parsed = cand;
                    if (try self.acceptParsedSummary(&parsed, attempt)) return parsed;
                    parsed.deinit(self.allocator);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.FileNotFound, error.NoAssistantMessage => {},
                    else => break,
                }
                if (self.stop_failed or attempt == 19 or watchdog.monotonicNs() >= self.deadline_ns) break;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
        };
        if (self.stop_failed) {
            return try watchdog.synthesizeStopFailureSummary(self.allocator, self.stop_payload_owned.?);
        }
        return self.fallbackStopSummary();
    }
};

// -------- tests --------
const testing = std.testing;

test "FinalizerState: deinit frees owned buffers cleanly" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    f.transcript_path = try testing.allocator.dupe(u8, "/tmp/x.jsonl");
    f.stop_payload_owned = try testing.allocator.dupe(u8, "{}");
    f.stop_last = try testing.allocator.dupe(u8, "done");
    f.deinit();
}

test "FinalizerState: recordStop stores Stop text and deadline" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    defer f.deinit();
    try f.recordStop(false, "{\"last_assistant_message\":\"ok\"}");
    try testing.expect(!f.stop_failed);
    try testing.expectEqualStrings("ok", f.stop_last.?);
    try testing.expect(f.confirm_until > 0);
}

test "FinalizerState: recordStop marks stop_failed on StopFailure" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    defer f.deinit();
    try f.recordStop(true, "{\"error\":\"boom\"}");
    try testing.expect(f.stop_failed);
    try testing.expect(f.stop_payload_owned != null);
}

test "FinalizerState: recordStop replaces previous payload without leaking" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    defer f.deinit();
    try f.recordStop(false, "{\"last_assistant_message\":\"first\"}");
    try f.recordStop(false, "{\"last_assistant_message\":\"second\"}");
    try testing.expectEqualStrings("second", f.stop_last.?);
}

test "FinalizerState: checkProvisionalStop returns false without Stop payload" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    defer f.deinit();
    try testing.expect(!try f.checkProvisionalStop());
}

test "FinalizerState: checkProvisionalStop confirms once deadline passes" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
    };
    defer f.deinit();
    try testing.expect(try f.checkProvisionalStop());
}

test "FinalizerState: checkProvisionalStop waits before confirm_until" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
        .confirm_until = std.math.maxInt(i128),
    };
    defer f.deinit();
    try testing.expect(!try f.checkProvisionalStop());
}

test "FinalizerState: checkProvisionalStop cancels on tool_use continuation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"}]}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = line });
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .transcript_path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl"),
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
        .confirm_until = std.math.maxInt(i128),
    };
    defer f.deinit();
    try testing.expect(!try f.checkProvisionalStop());
    try testing.expect(f.stop_payload_owned == null);
}

test "FinalizerState: checkProvisionalStop confirms immediately on stop_hook_summary false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":false}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = line });
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .transcript_path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl"),
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
        .confirm_until = std.math.maxInt(i128),
    };
    defer f.deinit();
    try testing.expect(try f.checkProvisionalStop());
}

test "FinalizerState: fallbackStopSummary succeeds on valid Stop payload" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{\"session_id\":\"s-1\"}"),
        .stop_last = try testing.allocator.dupe(u8, "hello"),
    };
    defer f.deinit();
    var sum = try f.fallbackStopSummary();
    defer sum.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", sum.final_text);
    try testing.expectEqualStrings("s-1", sum.session_id);
}

test "FinalizerState: fallbackStopSummary defaults empty session_id when absent" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
        .stop_last = try testing.allocator.dupe(u8, "ok"),
    };
    defer f.deinit();
    var sum = try f.fallbackStopSummary();
    defer sum.deinit(testing.allocator);
    try testing.expectEqualStrings("", sum.session_id);
}

test "FinalizerState: fallbackStopSummary rejects missing payload" {
    var f: FinalizerState = .{ .allocator = testing.allocator };
    defer f.deinit();
    try testing.expectError(RunError.TranscriptUnavailable, f.fallbackStopSummary());
}

test "FinalizerState: fallbackStopSummary rejects missing or blank stop_last" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{}"),
    };
    defer f.deinit();
    try testing.expectError(RunError.TranscriptUnavailable, f.fallbackStopSummary());
    f.stop_last = try testing.allocator.dupe(u8, "  \n");
    try testing.expectError(RunError.TranscriptUnavailable, f.fallbackStopSummary());
}

test "FinalizerState: acceptParsedSummary accepts matching text on first attempt" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_last = try testing.allocator.dupe(u8, "answer"),
    };
    defer f.deinit();
    var parsed: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "answer"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .is_error = false,
        .num_turns = 1,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer parsed.deinit(testing.allocator);
    try testing.expect(try f.acceptParsedSummary(&parsed, 0));
}

test "FinalizerState: acceptParsedSummary defers stale text until attempt 19" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_last = try testing.allocator.dupe(u8, "fresh"),
    };
    defer f.deinit();
    var parsed: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "stale"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .is_error = false,
        .num_turns = 1,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer parsed.deinit(testing.allocator);
    try testing.expect(!try f.acceptParsedSummary(&parsed, 0));
    try testing.expect(try f.acceptParsedSummary(&parsed, 19));
    try testing.expectEqualStrings("fresh", parsed.final_text);
}

test "FinalizerState: acceptParsedSummary accepts immediately when deadline elapsed" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .deadline_ns = 0,
        .stop_last = try testing.allocator.dupe(u8, "deadline-text"),
    };
    defer f.deinit();
    var parsed: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "stale"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .is_error = false,
        .num_turns = 1,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer parsed.deinit(testing.allocator);
    try testing.expect(try f.acceptParsedSummary(&parsed, 0));
    try testing.expectEqualStrings("deadline-text", parsed.final_text);
}

test "FinalizerState: acceptParsedSummary overlays StopFailure error and clears success subtype" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_failed = true,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{\"error\":\"overloaded\"}"),
    };
    defer f.deinit();
    var parsed: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "old"),
        .session_id = try testing.allocator.dupe(u8, "s"),
        .is_error = false,
        .subtype = try testing.allocator.dupe(u8, "success"),
        .num_turns = 1,
        .total_cost_usd = 0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer parsed.deinit(testing.allocator);
    try testing.expect(try f.acceptParsedSummary(&parsed, 0));
    try testing.expect(parsed.is_error);
    try testing.expectEqualStrings("overloaded", parsed.final_text);
    try testing.expect(parsed.subtype == null);
}

test "FinalizerState: resolveFinalSummary synthesizes StopFailure without transcript" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .stop_failed = true,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{\"session_id\":\"s\",\"error\":\"rate limit\"}"),
    };
    defer f.deinit();
    var sum = try f.resolveFinalSummary();
    defer sum.deinit(testing.allocator);
    try testing.expect(sum.is_error);
    try testing.expectEqualStrings("rate limit", sum.final_text);
}

test "FinalizerState: resolveFinalSummary parses regular transcript file cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi!\"}]}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = line });
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .transcript_path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl"),
        .pre_prompt_transcript_offset = 0,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{\"last_assistant_message\":\"hi!\"}"),
        .stop_last = try testing.allocator.dupe(u8, "hi!"),
    };
    defer f.deinit();
    var sum = try f.resolveFinalSummary();
    defer sum.deinit(testing.allocator);
    try testing.expectEqualStrings("hi!", sum.final_text);
}

test "FinalizerState: resolveFinalSummary falls back to Stop text if transcript missing" {
    var f: FinalizerState = .{
        .allocator = testing.allocator,
        .transcript_path = try testing.allocator.dupe(u8, "/nonexistent/transcript.jsonl"),
        .pre_prompt_transcript_offset = 0,
        .deadline_ns = 0,
        .stop_payload_owned = try testing.allocator.dupe(u8, "{\"session_id\":\"s9\"}"),
        .stop_last = try testing.allocator.dupe(u8, "fallback"),
    };
    defer f.deinit();
    var sum = try f.resolveFinalSummary();
    defer sum.deinit(testing.allocator);
    try testing.expectEqualStrings("fallback", sum.final_text);
    try testing.expectEqualStrings("s9", sum.session_id);
}
