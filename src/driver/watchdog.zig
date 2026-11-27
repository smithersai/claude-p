//! Signal cancellation, monotonic clock, timing constants, prompt-acceptance
//! watchdog, prompt truncation detection, and post-Stop transcript scanning.
const std = @import("std");
const hook_mod = @import("../hook.zig");
const transcript_mod = @import("../transcript.zig");

const paste_end = "\x1b[201~";

/// Set by `requestInterrupt`; polled by `run` and by every settle wait.
pub var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var interrupt_generation = std.atomic.Value(u32).init(0);
threadlocal var active_generation: ?u32 = null;

/// RAII guard capturing the current interrupt generation for a single session.
pub const InterruptScope = struct {
    previous: ?u32,

    pub fn enter() InterruptScope {
        const previous = active_generation;
        active_generation = interrupt_generation.load(.seq_cst);
        return .{ .previous = previous };
    }

    pub fn exit(self: InterruptScope) void {
        active_generation = self.previous;
    }
};

/// Ask every in-flight run to stop using only lock-free signal-safe atomics.
pub fn requestInterrupt() void {
    _ = interrupt_generation.fetchAdd(1, .seq_cst);
    interrupted.store(true, .seq_cst);
}

/// Reset the global interrupt flag after an interrupted session unwinds.
pub fn clearInterrupt() void {
    interrupted.store(false, .seq_cst);
}

/// Return true if a global interrupt was requested since this scope began.
pub fn isInterrupted() bool {
    const gen_changed = active_generation != null and
        active_generation.? != interrupt_generation.load(.seq_cst);
    return interrupted.load(.seq_cst) or gen_changed;
}

var clock_once = std.once(initClock);
var clock_wall_base_ns: i128 = 0;
var clock_mono_base_ns: i128 = 0;

fn rawMonotonicNs() ?i128 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn initClock() void {
    clock_wall_base_ns = std.time.nanoTimestamp();
    clock_mono_base_ns = rawMonotonicNs() orelse 0;
}

/// Nanoseconds on a monotonic clock anchored near wall-clock time.
pub fn monotonicNs() i128 {
    clock_once.call();
    const mono = rawMonotonicNs() orelse return std.time.nanoTimestamp();
    return clock_wall_base_ns + (mono - clock_mono_base_ns);
}

/// How long PTY output must be quiet before typing on fresh sessions.
pub const ink_quiescence_ms: u64 = 80;
/// Upper bound on how long we wait for initial Ink quiescence.
pub const ink_max_wait_ms: u64 = 2000;
/// Delay between pasting prompt bytes and sending Enter.
pub const ink_enter_debounce_ms: u64 = 120;
/// Quiet duration before interacting with a pre-SessionStart modal dialog.
pub const dialog_quiescence_ms: u64 = 80;
/// Extra settle delay after first quiescence following SessionStart.
pub const prompt_settle_ms: u64 = 100;
/// Quiet window before typing into a resumed conversation.
pub const resume_quiescence_ms: u64 = 400;
/// Upper bound on resume settle wait.
pub const resume_max_wait_ms: u64 = 6000;
/// Grace window after child exit while awaiting an in-flight Stop hook.
pub const post_exit_fifo_grace_ms: u64 = 250;
/// Wait window for prompt acknowledgement before re-injecting.
pub const prompt_accept_timeout_ms: u64 = 4000;
/// Maximum prompt injection attempts before failing with `PromptNotAccepted`.
pub const max_prompt_injections: u32 = 4;
/// Prompts at or below this many non-whitespace bytes skip truncation checks.
pub const prompt_truncation_min_len: usize = 64;

/// Action chosen by the prompt-acknowledgement watchdog on each tick.
pub const WatchdogAction = enum { wait, reinject, give_up };

/// Prompt-acceptance watchdog decision.
pub fn promptWatchdogAction(accepted: bool, injections: u32, since_typed_ms: i64) WatchdogAction {
    std.debug.assert(max_prompt_injections > 0);
    if (accepted) return .wait;
    if (since_typed_ms <= @as(i64, @intCast(prompt_accept_timeout_ms))) return .wait;
    if (injections >= max_prompt_injections) return .give_up;
    return .reinject;
}

const PromptBytes = struct {
    text: []const u8,
    neutralize: bool,
    pos: usize = 0,
    end_match: usize = 0,

    fn next(self: *PromptBytes) ?u8 {
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            self.pos += 1;
            if (!self.neutralize) return b;
            if (self.end_match == paste_end.len - 1 and b == paste_end[paste_end.len - 1]) continue;
            if (b == paste_end[self.end_match]) {
                self.end_match += 1;
            } else {
                self.end_match = if (b == paste_end[0]) 1 else 0;
            }
            return b;
        }
        return null;
    }
};

/// Count deliverable printable non-space bytes in `text`, stripping ANSI escapes.
pub fn promptPayloadLen(text: []const u8, neutralize: bool) usize {
    var src: PromptBytes = .{ .text = text, .neutralize = neutralize };
    var n: usize = 0;
    while (src.next()) |b| {
        if (b != 0x1b) {
            if (b > 0x20 and b != 0x7f) n += 1;
            continue;
        }
        const kind = src.next() orelse break;
        switch (kind) {
            '[' => {
                var c = src.next();
                while (c != null and c.? >= 0x30 and c.? <= 0x3f) c = src.next();
                while (c != null and c.? >= 0x20 and c.? <= 0x2f) c = src.next();
            },
            ']', 'P', 'X', '^', '_' => {
                var c = src.next();
                while (c) |byte| {
                    if (kind == ']' and byte == 0x07) break;
                    if (byte == 0x1b) {
                        c = src.next();
                        if (c != null and c.? == '\\') break;
                        continue;
                    }
                    c = src.next();
                }
            },
            else => {},
        }
    }
    std.debug.assert(n <= text.len);
    return n;
}

fn afterDigits(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return if (i > 0) s[i..] else null;
}

fn isPastePlaceholder(text: []const u8) bool {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "[Image #")) {
        return std.mem.eql(u8, afterDigits(s["[Image #".len..]) orelse return false, "]");
    }
    if (std.mem.startsWith(u8, s, "<pasted_content ") and std.mem.endsWith(u8, s, "</pasted_content>")) return true;
    if (!std.mem.startsWith(u8, s, "[Pasted text #")) return false;
    const count = afterDigits(s["[Pasted text #".len..]) orelse return false;
    if (!std.mem.startsWith(u8, count, " +")) return false;
    return std.mem.eql(u8, afterDigits(count[2..]) orelse return false, " lines]");
}

/// Detect whether Claude received a truncated copy of our typed prompt.
pub fn isPromptTruncated(expected: []const u8, received: []const u8) bool {
    std.debug.assert(prompt_truncation_min_len > 0);
    if (expected.len <= prompt_truncation_min_len) return false;
    const floor = @min(promptPayloadLen(expected, false), promptPayloadLen(expected, true));
    if (floor <= prompt_truncation_min_len) return false;
    if (isPastePlaceholder(received)) return false;
    return promptPayloadLen(received, false) < floor;
}

/// True when `final_text` agrees with a non-empty Stop `last_assistant_message`.
pub fn finalTextMatchesStop(final_text: []const u8, stop_last: ?[]const u8) bool {
    const want = stop_last orelse return true;
    const w = std.mem.trim(u8, want, " \t\r\n");
    if (w.len == 0) return true;
    return std.mem.eql(u8, std.mem.trim(u8, final_text, " \t\r\n"), w);
}

/// Validate a transcript file path using `transcript.validateTranscriptPath`.
pub fn validateTranscriptPath(path: []const u8) bool {
    return transcript_mod.validateTranscriptPath(path);
}

/// Extract and validate `transcript_path` from a hook JSON payload.
pub fn extractSafeTranscriptPath(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    const path = (try hook_mod.extractTranscriptPath(allocator, payload_json)) orelse return null;
    if (!validateTranscriptPath(path)) {
        allocator.free(path);
        return null;
    }
    std.debug.assert(path.len > 0 and path[0] == '/');
    return path;
}

/// Return the current regular-file byte size of `path`, or null if unavailable.
pub fn transcriptSize(path: ?[]const u8) ?u64 {
    const file = transcript_mod.openTranscriptRegularFile(path orelse return null) catch return null;
    defer file.close();
    return (file.stat() catch return null).size;
}

/// Return true when `hooks` contains an extra hook registered for `event`.
pub fn hasExtraHook(hooks: []const hook_mod.ExtraHook, event: []const u8) bool {
    std.debug.assert(event.len > 0);
    for (hooks) |hook| if (std.mem.eql(u8, hook.event, event)) return true;
    return false;
}

/// Return the stop-confirmation grace window in nanoseconds given configured extra hooks.
pub fn stopConfirmationNs(hooks: []const hook_mod.ExtraHook) i128 {
    const ms: i128 = if (hasExtraHook(hooks, "Stop")) 2000 else 150;
    std.debug.assert(ms > 0);
    return ms * std.time.ns_per_ms;
}

/// Return true when failure screen capture is enabled by `--debug` or `CLAUDE_P_DEBUG_SCREEN=1`.
pub fn debugScreenEnabled(debug: bool) bool {
    return debug or std.mem.eql(u8, std.posix.getenv("CLAUDE_P_DEBUG_SCREEN") orelse "", "1");
}

/// Classification of a post-Stop transcript record during blocking-Stop detection.
pub const StopSummaryStatus = enum { none, confirmed, continued };

fn normalizedPromptEqual(a: []const u8, b: []const u8) bool {
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (left.next()) |token| if (!std.mem.eql(u8, token, right.next() orelse return false)) return false;
    return right.next() == null;
}

fn userPromptMatches(allocator: std.mem.Allocator, obj: std.json.ObjectMap, prompt: []const u8) !bool {
    const message = obj.get("message") orelse return false;
    if (message != .object) return false;
    const content = message.object.get("content") orelse return false;
    if (content == .string) return normalizedPromptEqual(content.string, prompt);
    if (content != .array) return false;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const part = block.object.get("text") orelse continue;
        if (part == .string) try joined.appendSlice(allocator, part.string);
    }
    return normalizedPromptEqual(joined.items, prompt);
}

/// Return true when a JSONL transcript line indicates a blocking Stop hook continued the turn.
pub fn isContinuationRecord(
    allocator: std.mem.Allocator,
    line: []const u8,
    stop_last: ?[]const u8,
    current_prompt: ?[]const u8,
) !bool {
    return try stopRecordStatus(allocator, line, stop_last, current_prompt) == .continued;
}

fn stopRecordStatus(
    allocator: std.mem.Allocator,
    line: []const u8,
    stop_last: ?[]const u8,
    current_prompt: ?[]const u8,
) !StopSummaryStatus {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    defer record.deinit();
    if (record.value != .object) return .none;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return .none;
    if (ty != .string) return .none;
    if (std.mem.eql(u8, ty.string, "user")) {
        if (current_prompt) |prompt| if (try userPromptMatches(allocator, obj, prompt)) return .none;
        return .continued;
    }
    if (std.mem.eql(u8, ty.string, "tool_use")) return .continued;
    if (std.mem.eql(u8, ty.string, "system")) {
        const sub = obj.get("subtype") orelse return .none;
        if (sub != .string or !std.mem.eql(u8, sub.string, "stop_hook_summary")) return .none;
        const pc = obj.get("preventedContinuation") orelse return .confirmed;
        if (pc != .bool) return .none;
        return if (pc.bool) .continued else .confirmed;
    }
    if (!std.mem.eql(u8, ty.string, "assistant")) return .none;
    return classifyAssistantContinuation(allocator, obj, stop_last);
}

fn classifyAssistantContinuation(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    stop_last: ?[]const u8,
) !StopSummaryStatus {
    const message = obj.get("message") orelse return .none;
    if (message != .object) return .none;
    const content = message.object.get("content") orelse return .none;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    const text = switch (content) {
        .string => content.string,
        .array => |blocks| blk: {
            for (blocks.items) |block| {
                if (block != .object) continue;
                const kind = block.object.get("type") orelse continue;
                if (kind != .string) continue;
                if (std.mem.eql(u8, kind.string, "tool_use")) return .continued;
                if (!std.mem.eql(u8, kind.string, "text")) continue;
                const part = block.object.get("text") orelse continue;
                if (part == .string) try joined.appendSlice(allocator, part.string);
            }
            break :blk joined.items;
        },
        else => return .none,
    };
    const trimmed_text = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed_text.len == 0) return .none;
    const expected = stop_last orelse return .none;
    const trimmed_stop = std.mem.trim(u8, expected, " \t\r\n");
    if (trimmed_stop.len == 0) return .none;
    if (std.mem.eql(u8, trimmed_text, trimmed_stop) or std.mem.indexOf(u8, trimmed_stop, trimmed_text) != null) {
        return .none;
    }
    return .continued;
}

/// Only consume complete records from `file` up to `size`, advancing `pos`.
pub fn scanStopRecords(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    pos: *u64,
    size: u64,
    stop_last: ?[]const u8,
    prompt: []const u8,
) !StopSummaryStatus {
    std.debug.assert(pos.* <= size);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    try reader.seekTo(pos.*);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    while (reader.logicalPos() < size) {
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', limit) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try reader.interface.discardDelimiterInclusive('\n');
                pos.* = reader.logicalPos();
                continue;
            },
            else => return err,
        };
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1);
        pos.* = reader.logicalPos();
        const status = try stopRecordStatus(allocator, line.written(), stop_last, prompt);
        if (status != .none) return status;
    }
    return .none;
}

fn matchesPrompt(allocator: std.mem.Allocator, line: []const u8, prompt: []const u8) !bool {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer record.deinit();
    if (record.value != .object) return false;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "user") and try userPromptMatches(allocator, obj, prompt);
}

fn scanForPrompt(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) !?u64 {
    const file = try transcript_mod.openTranscriptRegularFile(path);
    defer file.close();
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    var last: ?u64 = null;
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    while (true) {
        const offset = reader.logicalPos();
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', limit) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            },
            else => return err,
        };
        if (try matchesPrompt(allocator, line.written(), prompt)) last = offset;
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1);
    }
    return last;
}

/// Return the byte offset of the last user record matching `prompt` in `path`, if found.
pub fn findPromptTurnOffset(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) ?u64 {
    return scanForPrompt(allocator, path, prompt) catch null;
}

/// Fallback message emitted when a `StopFailure` hook carries no error text.
pub const stop_failure_default_text = "claude reported StopFailure before finishing the turn";

/// Build the error `Summary` for a `StopFailure` hook.
pub fn synthesizeStopFailureSummary(allocator: std.mem.Allocator, payload: []const u8) !transcript_mod.Summary {
    var message = try hook_mod.extractErrorMessageAlloc(allocator, payload);
    errdefer if (message) |m| allocator.free(m);
    if (message) |m| {
        if (std.mem.trim(u8, m, " \t\r\n").len == 0) {
            allocator.free(m);
            message = null;
        }
    }
    if (message == null) message = try allocator.dupe(u8, stop_failure_default_text);
    const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
    errdefer allocator.free(sid);
    const replay = try allocator.dupe(u8, "");
    const final_text = message.?;
    message = null;
    std.debug.assert(final_text.len > 0);
    return .{
        .final_text = final_text,
        .session_id = sid,
        .is_error = true,
        .num_turns = 1,
        .total_cost_usd = 0.0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = replay,
    };
}

/// Replace `summary.final_text` with Stop's authoritative text when the transcript disagrees.
pub fn preferStopText(
    allocator: std.mem.Allocator,
    summary: *transcript_mod.Summary,
    stop_last: ?[]const u8,
) std.mem.Allocator.Error!void {
    if (finalTextMatchesStop(summary.final_text, stop_last)) return;
    std.debug.assert(stop_last != null);
    const fresh = try allocator.dupe(u8, stop_last.?);
    allocator.free(summary.final_text);
    summary.final_text = fresh;
    summary.is_error = false;
    if (summary.subtype) |old| allocator.free(old);
    summary.subtype = null;
    if (summary.permission_denials) |old| allocator.free(old);
    summary.permission_denials = null;
    summary.usage = .{};
    summary.num_turns = 1;
    summary.total_cost_usd = 0;
    summary.duration_api_ms = 0;
}

// -------- tests --------
const testing = std.testing;

test "InterruptScope: observes requestInterrupt even after clearInterrupt" {
    const scope = InterruptScope.enter();
    defer scope.exit();
    defer clearInterrupt();
    clearInterrupt();
    try testing.expect(!isInterrupted());
    requestInterrupt();
    clearInterrupt();
    try testing.expect(isInterrupted());
}

test "monotonicNs: never goes backwards" {
    const a = monotonicNs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b >= a);
}

test "promptWatchdogAction: waits when accepted or within timeout" {
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, 4, 99999));
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, prompt_accept_timeout_ms));
}

test "promptWatchdogAction: reinjects until cap then gives up" {
    try testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, 1, prompt_accept_timeout_ms + 1));
    try testing.expectEqual(WatchdogAction.give_up, promptWatchdogAction(false, max_prompt_injections, prompt_accept_timeout_ms + 1));
}

test "promptPayloadLen: strips spaces, control chars, and CSI/OSC escapes" {
    try testing.expectEqual(@as(usize, 5), promptPayloadLen(" \t\r\n\x1b[31mhello\x1b[0m\x1b]0;t\x07", false));
}

test "isPromptTruncated: ignores short prompts and exact matches" {
    try testing.expect(!isPromptTruncated("short", "s"));
    const long = "a" ** 100;
    try testing.expect(!isPromptTruncated(long, long));
}

test "isPromptTruncated: flags truncated long prompt" {
    const long = "a" ** 100;
    try testing.expect(isPromptTruncated(long, "a" ** 50));
}

test "isPromptTruncated: ignores Claude paste placeholders" {
    const long = "a" ** 100;
    try testing.expect(!isPromptTruncated(long, "[Pasted text #1 +10 lines]"));
    try testing.expect(!isPromptTruncated(long, "[Image #2]"));
    try testing.expect(!isPromptTruncated(long, "<pasted_content id=\"1\">x</pasted_content>"));
}

test "isPromptTruncated: neutralized ESC[201~ is not flagged as truncation" {
    const long = "a" ** 70 ++ "\x1b[201~" ++ "b" ** 10;
    try testing.expect(!isPromptTruncated(long, "a" ** 70 ++ "\x1b[201" ++ "b" ** 10));
}

test "finalTextMatchesStop: trims whitespace and accepts empty/null stop" {
    try testing.expect(finalTextMatchesStop("ok", null));
    try testing.expect(finalTextMatchesStop("ok", "   "));
    try testing.expect(finalTextMatchesStop("  ok\n", "ok"));
    try testing.expect(!finalTextMatchesStop("old", "new"));
}

test "extractSafeTranscriptPath: accepts absolute path and drops unsafe paths" {
    const ok = (try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/s.jsonl\"}")).?;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("/tmp/s.jsonl", ok);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"rel.jsonl\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a\\u0000b\"}")) == null);
}

test "hasExtraHook and stopConfirmationNs reflect Stop hook presence" {
    const none = [_]hook_mod.ExtraHook{};
    const with_stop = [_]hook_mod.ExtraHook{.{ .event = "Stop", .command = "echo ok" }};
    try testing.expect(!hasExtraHook(&none, "Stop"));
    try testing.expect(hasExtraHook(&with_stop, "Stop"));
    try testing.expectEqual(@as(i128, 150 * std.time.ns_per_ms), stopConfirmationNs(&none));
    try testing.expectEqual(@as(i128, 2000 * std.time.ns_per_ms), stopConfirmationNs(&with_stop));
}

test "isContinuationRecord: distinguishes matching user prompt vs new user prompt" {
    const same = "{\"type\":\"user\",\"message\":{\"content\":\"hello world\"}}";
    try testing.expect(!(try isContinuationRecord(testing.allocator, same, null, "hello   world")));
    try testing.expect(try isContinuationRecord(testing.allocator, same, null, "different"));
}

test "isContinuationRecord: recognizes tool_use and new assistant text" {
    try testing.expect(try isContinuationRecord(testing.allocator, "{\"type\":\"tool_use\"}", null, null));
    const same_asst = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}";
    try testing.expect(!(try isContinuationRecord(testing.allocator, same_asst, "done", null)));
    const next_asst = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}";
    try testing.expect(try isContinuationRecord(testing.allocator, next_asst, "done", null));
}

test "scanStopRecords: confirms stop_hook_summary with preventedContinuation false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":false}\n";
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = data });
    const f = try tmp.dir.openFile("s.jsonl", .{});
    defer f.close();
    var pos: u64 = 0;
    const st = try scanStopRecords(testing.allocator, f, &pos, data.len, null, "p");
    try testing.expectEqual(StopSummaryStatus.confirmed, st);
    try testing.expectEqual(@as(u64, data.len), pos);
}

test "scanStopRecords: detects continuation when preventedContinuation is true" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"preventedContinuation\":true}\n";
    try tmp.dir.writeFile(.{ .sub_path = "s.jsonl", .data = data });
    const f = try tmp.dir.openFile("s.jsonl", .{});
    defer f.close();
    var pos: u64 = 0;
    try testing.expectEqual(StopSummaryStatus.continued, try scanStopRecords(testing.allocator, f, &pos, data.len, null, "p"));
}

test "findPromptTurnOffset: returns byte offset of last matching user record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const l1 = "{\"type\":\"user\",\"message\":{\"content\":\"ping\"}}\n";
    const l2 = "{\"type\":\"assistant\",\"message\":{\"content\":\"pong\"}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = l1 ++ l2 ++ l1 });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, l1.len + l2.len), findPromptTurnOffset(testing.allocator, path, "ping"));
    try testing.expectEqual(@as(?u64, null), findPromptTurnOffset(testing.allocator, "relative.jsonl", "ping"));
}

test "synthesizeStopFailureSummary: extracts hook error or falls back to default" {
    var s1 = try synthesizeStopFailureSummary(testing.allocator, "{\"session_id\":\"s1\",\"error\":\"rate limit\"}");
    defer s1.deinit(testing.allocator);
    try testing.expect(s1.is_error);
    try testing.expectEqualStrings("rate limit", s1.final_text);
    try testing.expectEqualStrings("s1", s1.session_id);

    var s2 = try synthesizeStopFailureSummary(testing.allocator, "{}");
    defer s2.deinit(testing.allocator);
    try testing.expect(s2.is_error);
    try testing.expect(s2.final_text.len > 0);
}

test "preferStopText: replaces stale summary and clears stale error metadata" {
    var s: transcript_mod.Summary = .{
        .final_text = try testing.allocator.dupe(u8, "stale"),
        .session_id = try testing.allocator.dupe(u8, "s1"),
        .is_error = true,
        .subtype = try testing.allocator.dupe(u8, "error"),
        .num_turns = 3,
        .total_cost_usd = 1.5,
        .duration_api_ms = 99,
        .usage = .{ .input_tokens = 10 },
        .jsonl_replay = try testing.allocator.dupe(u8, ""),
    };
    defer s.deinit(testing.allocator);
    try preferStopText(testing.allocator, &s, "fresh");
    try testing.expectEqualStrings("fresh", s.final_text);
    try testing.expect(!s.is_error);
    try testing.expect(s.subtype == null);
    try testing.expectEqual(@as(u64, 0), s.usage.input_tokens);
}

test "transcriptSize: returns file size for regular file and null for missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.jsonl", .data = "12345" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, 5), transcriptSize(path));
    try testing.expectEqual(@as(?u64, null), transcriptSize(null));
    try testing.expectEqual(@as(?u64, null), transcriptSize("/nonexistent/claude-p-size.jsonl"));
}
