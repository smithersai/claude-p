//! Signal cancellation, monotonic clock, timing constants, prompt-acceptance
//! watchdog, prompt truncation detection, and post-Stop transcript scanning.
const std = @import("std");
const hook_mod = @import("../hook.zig");

/// Post-Stop transcript scanning, prompt-turn offset matching, and StopFailure synthesis.
pub const stop_scan = @import("stop_scan.zig");
/// True when `final_text` agrees with a non-empty Stop `last_assistant_message`.
pub const finalTextMatchesStop = stop_scan.finalTextMatchesStop;
/// Validate a transcript file path using `transcript.validateTranscriptPath`.
pub const validateTranscriptPath = stop_scan.validateTranscriptPath;
/// Extract and validate `transcript_path` from a hook JSON payload.
pub const extractSafeTranscriptPath = stop_scan.extractSafeTranscriptPath;
/// Return the current regular-file byte size of `path`, or null if unavailable.
pub const transcriptSize = stop_scan.transcriptSize;
/// Classification of a post-Stop transcript record during blocking-Stop detection.
pub const StopSummaryStatus = stop_scan.StopSummaryStatus;
/// Return true when a JSONL transcript line indicates a blocking Stop hook continued the turn.
pub const isContinuationRecord = stop_scan.isContinuationRecord;
/// Only consume complete records from `file` up to `size`, advancing `pos`.
pub const scanStopRecords = stop_scan.scanStopRecords;
/// Return the byte offset of the last user record matching `prompt` in `path`, if found.
pub const findPromptTurnOffset = stop_scan.findPromptTurnOffset;
/// Fallback message emitted when a `StopFailure` hook carries no error text.
pub const stop_failure_default_text = stop_scan.stop_failure_default_text;
/// Build the error `Summary` for a `StopFailure` hook.
pub const synthesizeStopFailureSummary = stop_scan.synthesizeStopFailureSummary;
/// Replace `summary.final_text` with Stop's authoritative text when the transcript disagrees.
pub const preferStopText = stop_scan.preferStopText;

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
    const gen_changed = active_generation != null and active_generation.? != interrupt_generation.load(.seq_cst);
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

test "InterruptScope: nested scopes restore outer generation" {
    const outer = InterruptScope.enter();
    defer outer.exit();
    defer clearInterrupt();
    {
        const inner = InterruptScope.enter();
        defer inner.exit();
        try testing.expect(!isInterrupted());
    }
    try testing.expect(!isInterrupted());
}

test "requestInterrupt and clearInterrupt toggle global flag" {
    clearInterrupt();
    try testing.expect(!isInterrupted());
    requestInterrupt();
    try testing.expect(isInterrupted());
    clearInterrupt();
    try testing.expect(!isInterrupted());
}

test "monotonicNs: never goes backwards" {
    const a = monotonicNs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b >= a);
}

test "timing constants are strictly positive" {
    try testing.expect(ink_quiescence_ms > 0 and ink_max_wait_ms > ink_quiescence_ms);
    try testing.expect(resume_quiescence_ms > 0 and resume_max_wait_ms > resume_quiescence_ms);
    try testing.expect(post_exit_fifo_grace_ms > 0 and max_prompt_injections > 0);
}

test "promptWatchdogAction: waits when accepted" {
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, 4, 99999));
}

test "promptWatchdogAction: waits at exact accept timeout boundary" {
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, prompt_accept_timeout_ms));
}

test "promptWatchdogAction: reinjects once past timeout below cap" {
    try testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, 1, prompt_accept_timeout_ms + 1));
}

test "promptWatchdogAction: gives up at max_prompt_injections" {
    try testing.expectEqual(
        WatchdogAction.give_up,
        promptWatchdogAction(false, max_prompt_injections, prompt_accept_timeout_ms + 1),
    );
}

test "promptPayloadLen: strips spaces and control chars" {
    try testing.expectEqual(@as(usize, 5), promptPayloadLen(" \t\r\nhello\x07", false));
}

test "promptPayloadLen: strips CSI and OSC escape sequences" {
    try testing.expectEqual(@as(usize, 5), promptPayloadLen("\x1b[31mhello\x1b[0m\x1b]0;title\x07", false));
}

test "promptPayloadLen: neutralizes bracketed-paste end marker when requested" {
    const with_end = "ab\x1b[201~cd";
    try testing.expect(promptPayloadLen(with_end, true) <= promptPayloadLen(with_end, false));
}

test "isPromptTruncated: ignores short prompts" {
    try testing.expect(!isPromptTruncated("short", "s"));
}

test "isPromptTruncated: accepts exact long match" {
    const long = "a" ** 100;
    try testing.expect(!isPromptTruncated(long, long));
}

test "isPromptTruncated: flags truncated long prompt" {
    try testing.expect(isPromptTruncated("a" ** 100, "a" ** 50));
}

test "isPromptTruncated: ignores Claude paste and image placeholders" {
    const long = "a" ** 100;
    try testing.expect(!isPromptTruncated(long, "[Pasted text #1 +10 lines]"));
    try testing.expect(!isPromptTruncated(long, "[Image #2]"));
    try testing.expect(!isPromptTruncated(long, "<pasted_content id=\"1\">x</pasted_content>"));
}

test "isPromptTruncated: neutralized ESC[201~ is not flagged as truncation" {
    const long = "a" ** 70 ++ "\x1b[201~" ++ "b" ** 10;
    try testing.expect(!isPromptTruncated(long, "a" ** 70 ++ "\x1b[201" ++ "b" ** 10));
}

test "hasExtraHook: matches exact event names" {
    const hooks = [_]hook_mod.ExtraHook{.{ .event = "Stop", .command = "true" }};
    try testing.expect(hasExtraHook(&hooks, "Stop"));
    try testing.expect(!hasExtraHook(&hooks, "PermissionRequest"));
}

test "stopConfirmationNs: extends grace window when extra Stop hook is configured" {
    const none = [_]hook_mod.ExtraHook{};
    const with_stop = [_]hook_mod.ExtraHook{.{ .event = "Stop", .command = "echo ok" }};
    try testing.expectEqual(@as(i128, 150 * std.time.ns_per_ms), stopConfirmationNs(&none));
    try testing.expectEqual(@as(i128, 2000 * std.time.ns_per_ms), stopConfirmationNs(&with_stop));
}

test "debugScreenEnabled: honors debug flag" {
    try testing.expect(debugScreenEnabled(true));
}
