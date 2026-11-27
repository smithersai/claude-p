//! Privacy-safe `--debug` trace formatting and bounded failure screen rendering.
const std = @import("std");
const hook_mod = @import("../hook.zig");
const dialog_mod = @import("dialog.zig");

/// Maximum bytes retained in the rolling startup-dialog PTY buffer.
pub const recent_capacity: usize = 8192;
/// Maximum non-blank lines included in a failure screen diagnostic.
pub const failure_screen_max_lines: usize = 15;
/// Maximum byte length of a failure screen diagnostic.
pub const failure_screen_max_bytes: usize = 1024;

/// Format a privacy-safe `--debug` trace line for a hook event (name and size only).
pub fn formatHookTrace(buf: []u8, event: hook_mod.HookEvent, payload_len: usize) []const u8 {
    std.debug.assert(buf.len > 0);
    return std.fmt.bufPrint(buf, "hook: {s} payload_bytes={d}", .{
        @tagName(event),
        payload_len,
    }) catch "hook: (trace overflow)";
}

/// Render the tail of raw PTY output for a failure diagnostic, bounded by lines and bytes.
pub fn formatFailureScreen(out: *[failure_screen_max_bytes]u8, raw: []const u8) []const u8 {
    std.debug.assert(out.len == failure_screen_max_bytes);
    var stripped_buf: [recent_capacity]u8 = undefined;
    const tail = raw[raw.len -| recent_capacity..];
    const stripped = dialog_mod.stripCsiInto(&stripped_buf, tail);
    var n: usize = 0;
    var line_start: usize = 0;
    var line_has_text = false;
    for (stripped) |b| {
        if (b == '\n' or b == '\r') {
            if (line_has_text) {
                while (stripped_buf[n - 1] == ' ') n -= 1;
                stripped_buf[n] = '\n';
                n += 1;
                line_start = n;
                line_has_text = false;
            } else n = line_start;
            continue;
        }
        if (b < 0x20 or b == 0x7f) continue;
        if (b != ' ') line_has_text = true;
        stripped_buf[n] = b;
        n += 1;
    }
    if (!line_has_text) n = line_start;
    var text: []const u8 = std.mem.trimRight(u8, stripped_buf[0..n], " \n");
    var lines: usize = 1;
    var i: usize = text.len;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] != '\n') continue;
        if (lines == failure_screen_max_lines) {
            text = text[i..];
            break;
        }
        lines += 1;
    }
    if (text.len > out.len) {
        text = text[text.len - out.len ..];
        while (text.len > 0 and (text[0] & 0xC0) == 0x80) text = text[1..];
    }
    std.debug.assert(text.len <= out.len);
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

// -------- tests --------
const testing = std.testing;

test "formatHookTrace: stop event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: stop payload_bytes=42", formatHookTrace(&buf, .stop, 42));
}

test "formatHookTrace: session_start event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: session_start payload_bytes=0", formatHookTrace(&buf, .session_start, 0));
}

test "formatHookTrace: user_prompt_submit event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: user_prompt_submit payload_bytes=9", formatHookTrace(&buf, .user_prompt_submit, 9));
}

test "formatHookTrace: stop_failure event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: stop_failure payload_bytes=7", formatHookTrace(&buf, .stop_failure, 7));
}

test "formatHookTrace: permission_request event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: permission_request payload_bytes=1", formatHookTrace(&buf, .permission_request, 1));
}

test "formatHookTrace: unknown event" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("hook: unknown payload_bytes=3", formatHookTrace(&buf, .unknown, 3));
}

test "formatHookTrace: returns overflow marker on tiny buffer" {
    var tiny: [8]u8 = undefined;
    try testing.expectEqualStrings("hook: (trace overflow)", formatHookTrace(&tiny, .user_prompt_submit, 100));
}

test "formatFailureScreen: empty input returns empty" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("", formatFailureScreen(&out, ""));
}

test "formatFailureScreen: whitespace-only input returns empty" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("", formatFailureScreen(&out, "  \n\r\n   "));
}

test "formatFailureScreen: strips ANSI color escapes" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("error\nline two", formatFailureScreen(&out, "\x1b[31merror\x1b[0m   \n\n  \r\nline two\n"));
}

test "formatFailureScreen: strips OSC title sequence" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("ready", formatFailureScreen(&out, "\x1b]0;title\x07ready\n"));
}

test "formatFailureScreen: strips control chars below 0x20 and DEL" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("ab", formatFailureScreen(&out, "a\x01\x07\x7fb"));
}

test "formatFailureScreen: trims trailing spaces per line" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("a\nb", formatFailureScreen(&out, "a   \nb  \n"));
}

test "formatFailureScreen: drops blank intermediate lines" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("first\nsecond", formatFailureScreen(&out, "first\n\n   \r\nsecond\n"));
}

test "formatFailureScreen: keeps at most failure_screen_max_lines lines" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    const raw = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n";
    const s = formatFailureScreen(&out, raw);
    try testing.expectEqual(@as(usize, failure_screen_max_lines - 1), std.mem.count(u8, s, "\n"));
    try testing.expect(std.mem.startsWith(u8, s, "3\n"));
    try testing.expect(std.mem.endsWith(u8, s, "\n17"));
}

test "formatFailureScreen: bounds long ASCII line to failure_screen_max_bytes" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    const s = formatFailureScreen(&out, "x" ** 2000);
    try testing.expectEqual(failure_screen_max_bytes, s.len);
}

test "formatFailureScreen: preserves UTF-8 lead byte when truncating" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    const s = formatFailureScreen(&out, "é" ** 700);
    try testing.expect(s.len <= failure_screen_max_bytes);
    try testing.expect((s[0] & 0xC0) != 0x80);
    try testing.expect(std.unicode.utf8ValidateSlice(s));
}

test "formatFailureScreen: handles input exceeding recent_capacity" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    const s = formatFailureScreen(&out, "a" ** (recent_capacity + 500) ++ "\ntail\n");
    try testing.expect(std.mem.endsWith(u8, s, "\ntail"));
}

test "formatFailureScreen: handles CR-only progress lines" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("step1\nstep2", formatFailureScreen(&out, "step1\rstep2\r"));
}

test "constants have expected bounds" {
    try testing.expectEqual(@as(usize, 8192), recent_capacity);
    try testing.expectEqual(@as(usize, 15), failure_screen_max_lines);
    try testing.expectEqual(@as(usize, 1024), failure_screen_max_bytes);
}
