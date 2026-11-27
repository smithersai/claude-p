//! Pre-SessionStart startup dialog state machine (workspace trust,
//! bypass-permissions, development channels) and CSI/OSC/DCS escape stripping.
const std = @import("std");
const env_mod = @import("env.zig");

/// Recognised interactive startup dialogs shown by Claude Code before `SessionStart`.
pub const DialogKind = enum { none, trust, bypass_permissions, dev_channels };

/// Which option the dialog's `❯` cursor currently highlights.
pub const DialogSelection = enum { affirmative, negative, unknown };

/// Parsed cursor position and option layout of a startup dialog frame.
pub const DialogAnalysis = struct {
    selection: DialogSelection = .unknown,
    affirmative_digit: ?u8 = null,
    affirmative_below: bool = false,
};

/// Next keystroke or state transition emitted by the startup-dialog state machine.
pub const DialogAction = union(enum) {
    none,
    confirm,
    move_up,
    move_down,
    digit: u8,
    settled,
};

/// Pair of detected startup dialog kind and the action to take for it.
pub const DialogDecision = struct {
    kind: DialogKind = .none,
    action: DialogAction = .none,
};

/// Mutable dialog tracker state embedded in `SharedState`.
pub const DialogState = struct {
    kind: DialogKind = .none,
    last: DialogAction = .none,
    last_key_ns: i64 = 0,
    bytes_at_key: u64 = 0,
    keys_sent: u32 = 0,
    refused: DialogKind = .none,
};

/// Wait window before retrying a dropped dialog keystroke.
pub const dialog_retry_ms: u64 = 1500;
/// Hard cap on dialog keystrokes per session.
pub const max_dialog_keys: u32 = 16;

const cursor_glyph = "\xe2\x9d\xaf";

/// Return true when `opts` explicitly authorizes auto-confirming `kind`.
pub fn dialogConfirmAllowed(opts: env_mod.Options, kind: DialogKind) bool {
    var mode = opts.permission_mode;
    var skip = opts.skip_permissions;
    var channels = false;
    var flags: env_mod.ExtraFlags = .{ .args = opts.extra_args };
    while (flags.next()) |arg| {
        if (std.mem.eql(u8, arg.name, "--permission-mode")) mode = arg.value;
        if (std.mem.eql(u8, arg.name, "--dangerously-skip-permissions") and arg.value == null) skip = true;
        if (std.mem.eql(u8, arg.name, "--dangerously-load-development-channels")) channels = true;
    }
    return switch (kind) {
        .none, .trust => true,
        .dev_channels => channels,
        .bypass_permissions => skip or std.mem.eql(u8, mode orelse "", "bypassPermissions"),
    };
}

const DialogMarkers = struct {
    affirmative: []const []const u8,
    negative: []const []const u8,
};

fn dialogMarkers(kind: DialogKind) DialogMarkers {
    return switch (kind) {
        .trust => .{ .affirmative = &.{ "Yes,Itrust", "Yes,proceed" }, .negative = &.{"No,exit"} },
        .bypass_permissions => .{ .affirmative = &.{"Yes,Iaccept"}, .negative = &.{"No,exit"} },
        .dev_channels => .{ .affirmative = &.{"Iamusing"}, .negative = &.{"Exit"} },
        .none => .{ .affirmative = &.{}, .negative = &.{} },
    };
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\r' or b == '\t';
}

fn looseMatch(hay: []const u8, needle: []const u8) ?usize {
    std.debug.assert(needle.len > 0);
    var i: usize = 0;
    for (needle) |c| {
        while (i < hay.len and isSpace(hay[i])) : (i += 1) {}
        if (i >= hay.len or hay[i] != c) return null;
        i += 1;
    }
    return i;
}

fn looseStartsWithAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (looseMatch(hay, n) != null) return true;
    return false;
}

fn looseContainsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        var i: usize = 0;
        while (i < hay.len) : (i += 1) {
            if (hay[i] == n[0] and looseMatch(hay[i..], n) != null) return true;
        }
    }
    return false;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = haystack.len - needle.len;
    while (true) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

fn lastMainUiMarkerPos(stripped: []const u8) ?usize {
    const a = lastIndexOfIgnoreCase(stripped, "for shortcuts");
    const b = lastIndexOfIgnoreCase(stripped, "forshortcuts");
    if (a != null and b != null) return @max(a.?, b.?);
    return a orelse b;
}

fn considerDialog(best: *DialogKind, best_pos: *usize, kind: DialogKind, pos: usize) void {
    std.debug.assert(kind != .none);
    if (best.* == .none or pos >= best_pos.*) {
        best.* = kind;
        best_pos.* = pos;
    }
}

/// Identify the active startup dialog in CSI-stripped terminal output.
pub fn classifyDialog(stripped: []const u8) DialogKind {
    var best: DialogKind = .none;
    var best_pos: usize = 0;
    if (lastIndexOfIgnoreCase(stripped, "trust")) |trust_pos| {
        if (lastIndexOfIgnoreCase(stripped, "folder")) |folder_pos| {
            considerDialog(&best, &best_pos, .trust, @max(trust_pos, folder_pos));
        }
    }
    if (lastIndexOfIgnoreCase(stripped, "bypass")) |bp_pos| {
        if (lastIndexOfIgnoreCase(stripped, "permissions")) |perm_pos| {
            if (lastIndexOfIgnoreCase(stripped, "accept")) |acc_pos| {
                considerDialog(&best, &best_pos, .bypass_permissions, @max(bp_pos, @max(perm_pos, acc_pos)));
            }
        }
    }
    if (lastIndexOfIgnoreCase(stripped, "loading")) |load_pos| {
        if (lastIndexOfIgnoreCase(stripped, "development")) |dev_pos| {
            if (lastIndexOfIgnoreCase(stripped, "channels")) |ch_pos| {
                considerDialog(&best, &best_pos, .dev_channels, @max(load_pos, @max(dev_pos, ch_pos)));
            }
        }
    }
    if (best == .none) return .none;
    if (lastMainUiMarkerPos(stripped)) |ui_pos| if (ui_pos > best_pos) return .none;
    return best;
}

/// Read the cursor selection and option layout of `kind` from CSI-stripped output.
pub fn analyzeDialog(kind: DialogKind, stripped: []const u8) DialogAnalysis {
    var out: DialogAnalysis = .{};
    if (kind == .none) return out;
    const m = dialogMarkers(kind);
    var i: usize = 0;
    while (i < stripped.len) : (i += 1) {
        const c = stripped[i];
        if (c < '1' or c > '9') continue;
        if (i > 0 and std.ascii.isDigit(stripped[i - 1])) continue;
        const after_dot = looseMatch(stripped[i + 1 ..], ".") orelse continue;
        if (looseStartsWithAny(stripped[i + 1 + after_dot ..], m.affirmative)) {
            out.affirmative_digit = c;
        }
    }
    const at = std.mem.lastIndexOf(u8, stripped, cursor_glyph) orelse return out;
    std.debug.assert(at + cursor_glyph.len <= stripped.len);
    var rest = stripped[at + cursor_glyph.len ..];
    out.affirmative_below = looseContainsAny(rest, m.affirmative);

    var j: usize = 0;
    var cursor_numbered = false;
    while (j < rest.len and isSpace(rest[j])) : (j += 1) {}
    if (j < rest.len and rest[j] >= '1' and rest[j] <= '9') {
        if (looseMatch(rest[j + 1 ..], ".")) |dot| {
            rest = rest[j + 1 + dot ..];
            cursor_numbered = true;
        }
    }
    if (looseStartsWithAny(rest, m.affirmative)) {
        out.selection = .affirmative;
    } else if (looseStartsWithAny(rest, m.negative)) {
        out.selection = .negative;
    }
    if (out.selection != .unknown and !cursor_numbered) out.affirmative_digit = null;
    return out;
}

/// Choose the safe keystroke for `kind` given its parsed selection state.
pub fn chooseDialogAction(kind: DialogKind, analysis: DialogAnalysis, last: DialogAction) DialogAction {
    if (kind == .none) return .none;
    switch (analysis.selection) {
        .affirmative => return .confirm,
        .unknown => return .none,
        .negative => {
            if (analysis.affirmative_digit) |d| {
                std.debug.assert(d >= '1' and d <= '9');
                if (last != .digit) return .{ .digit = d };
            }
            return if (analysis.affirmative_below) .move_down else .move_up;
        },
    }
}

/// One step of the startup-dialog state machine (pure).
pub fn decideDialog(
    tracked: DialogKind,
    last: DialogAction,
    full: []const u8,
    fresh: []const u8,
    fresh_bytes: u64,
    since_key_ms: i64,
) DialogDecision {
    const timed_out = since_key_ms >= @as(i64, @intCast(dialog_retry_ms));
    switch (last) {
        .none => {
            const kind = classifyDialog(full);
            return .{ .kind = kind, .action = chooseDialogAction(kind, analyzeDialog(kind, full), .none) };
        },
        .confirm, .settled => {
            const kind = classifyDialog(fresh);
            if (kind != .none) {
                return .{ .kind = kind, .action = chooseDialogAction(kind, analyzeDialog(kind, fresh), .none) };
            }
            if (last == .confirm and fresh_bytes == 0 and timed_out) {
                return .{ .kind = tracked, .action = .confirm };
            }
            return .{ .kind = tracked, .action = .none };
        },
        .move_up, .move_down, .digit => {
            const fresh_kind = classifyDialog(fresh);
            if (fresh_kind == .none and lastMainUiMarkerPos(fresh) != null) {
                return .{ .kind = .none, .action = .settled };
            }
            const kind = if (fresh_kind != .none) fresh_kind else tracked;
            const analysis = analyzeDialog(kind, fresh);
            if (analysis.selection != .unknown) {
                return .{ .kind = kind, .action = chooseDialogAction(kind, analysis, last) };
            }
            if (!timed_out) return .{ .kind = kind, .action = .none };
            if (fresh_bytes == 0) return .{ .kind = kind, .action = last };
            return .{ .kind = .none, .action = .settled };
        },
    }
}

/// Translate a `DialogAction` into raw PTY keystroke bytes.
pub fn dialogKeyBytes(action: DialogAction, digit_buf: *[1]u8) []const u8 {
    return switch (action) {
        .confirm => "\r",
        .move_up => "\x1b[A",
        .move_down => "\x1b[B",
        .digit => |d| blk: {
            digit_buf[0] = d;
            break :blk digit_buf[0..1];
        },
        .none, .settled => "",
    };
}

/// Strip CSI / OSC / DCS escape sequences into caller-owned buffer `out`.
pub fn stripCsiInto(out: []u8, bytes: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and n < out.len) {
        const b = bytes[i];
        if (b != 0x1b) {
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= bytes.len) break;
        const next = bytes[i + 1];
        switch (next) {
            '[' => {
                i += 2;
                while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
                if (i < bytes.len) i += 1;
            },
            ']' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            'P', 'X', '^', '_' => {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            else => i += 2,
        }
    }
    std.debug.assert(n <= out.len);
    return out[0..n];
}

/// Strip CSI / OSC / DCS escape sequences, returning a newly allocated slice.
pub fn stripCsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len);
    errdefer allocator.free(out);
    const n = stripCsiInto(out, bytes).len;
    std.debug.assert(n <= bytes.len);
    return try allocator.realloc(out, n);
}

// -------- tests --------
const testing = std.testing;

test "classifyDialog: detects trust, bypass, dev_channels, and none" {
    try testing.expectEqual(DialogKind.none, classifyDialog("plain output"));
    try testing.expectEqual(DialogKind.trust, classifyDialog("Do you trust this folder?"));
    try testing.expectEqual(DialogKind.bypass_permissions, classifyDialog("Bypass Permissions mode: Yes, I accept"));
    try testing.expectEqual(DialogKind.dev_channels, classifyDialog("Loading development channels"));
}

test "classifyDialog: latest dialog wins and main UI footer clears it" {
    const both = "trust this folder ... Bypass Permissions accept";
    try testing.expectEqual(DialogKind.bypass_permissions, classifyDialog(both));
    const after_ui = "trust this folder ... ? for shortcuts";
    try testing.expectEqual(DialogKind.none, classifyDialog(after_ui));
}

test "analyzeDialog: unnumbered trust dialog with negative above affirmative" {
    const screen = "Do you trust this folder?\n❯ No, exit\nYes, I trust this folder";
    const a = analyzeDialog(.trust, screen);
    try testing.expectEqual(DialogSelection.negative, a.selection);
    try testing.expect(a.affirmative_below);
    try testing.expectEqual(@as(?u8, null), a.affirmative_digit);
}

test "analyzeDialog: unnumbered trust dialog with cursor on affirmative" {
    const screen = "Do you trust this folder?\nNo, exit\n❯ Yes, I trust this folder";
    const a = analyzeDialog(.trust, screen);
    try testing.expectEqual(DialogSelection.affirmative, a.selection);
}

test "analyzeDialog: numbered bypass-permissions detects digit 2" {
    const screen = "Bypass Permissions\n❯ 1. No, exit\n  2. Yes, I accept";
    const a = analyzeDialog(.bypass_permissions, screen);
    try testing.expectEqual(DialogSelection.negative, a.selection);
    try testing.expectEqual(@as(?u8, '2'), a.affirmative_digit);
}

test "analyzeDialog: ignores path digits preceding unnumbered cursor row" {
    const screen = "/tmp/dir9.\nDo you trust this folder?\n❯ No, exit\nYes, I trust";
    const a = analyzeDialog(.trust, screen);
    try testing.expectEqual(@as(?u8, null), a.affirmative_digit);
}

test "analyzeDialog: dev_channels affirmative vs negative" {
    const neg = "Loading development channels\n❯ 1. Exit\n2. I am using this for local dev";
    const a = analyzeDialog(.dev_channels, neg);
    try testing.expectEqual(DialogSelection.negative, a.selection);
    try testing.expectEqual(@as(?u8, '2'), a.affirmative_digit);
}

test "chooseDialogAction: never confirms unless cursor verified affirmative" {
    try testing.expectEqual(DialogAction.none, chooseDialogAction(.trust, .{}, .none));
    try testing.expectEqual(DialogAction.confirm, chooseDialogAction(.trust, .{ .selection = .affirmative }, .none));
    try testing.expectEqual(DialogAction.move_down, chooseDialogAction(.trust, .{
        .selection = .negative,
        .affirmative_below = true,
    }, .none));
    try testing.expectEqual(DialogAction.move_up, chooseDialogAction(.trust, .{
        .selection = .negative,
        .affirmative_below = false,
    }, .none));
}

test "chooseDialogAction: falls back to arrows if digit already sent" {
    const a: DialogAnalysis = .{ .selection = .negative, .affirmative_digit = '2', .affirmative_below = true };
    try testing.expectEqual(DialogAction{ .digit = '2' }, chooseDialogAction(.bypass_permissions, a, .none));
    try testing.expectEqual(DialogAction.move_down, chooseDialogAction(.bypass_permissions, a, .{ .digit = '2' }));
}

test "decideDialog: initial trust screen requests move_down, repaint confirms" {
    const s1 = "trust this folder\n❯ No, exit\nYes, I trust";
    const d1 = decideDialog(.none, .none, s1, s1, s1.len, 0);
    try testing.expectEqual(DialogKind.trust, d1.kind);
    try testing.expectEqual(DialogAction.move_down, d1.action);
    const s2 = "No, exit\n❯ Yes, I trust";
    const d2 = decideDialog(.trust, .move_down, s1 ++ s2, s2, s2.len, 50);
    try testing.expectEqual(DialogAction.confirm, d2.action);
}

test "decideDialog: retries confirm after timeout when zero repaint bytes arrived" {
    const d = decideDialog(.trust, .confirm, "old", "", 0, dialog_retry_ms);
    try testing.expectEqual(DialogAction.confirm, d.action);
    const wait = decideDialog(.trust, .confirm, "old", "", 0, 100);
    try testing.expectEqual(DialogAction.none, wait.action);
}

test "decideDialog: settles when main UI footer arrives during move" {
    const d = decideDialog(.trust, .move_down, "old", "❯ Yes, I trust\n? for shortcuts", 30, 50);
    try testing.expectEqual(DialogAction.settled, d.action);
}

test "decideDialog: resends move when zero bytes arrive past retry timeout" {
    const d = decideDialog(.trust, .move_down, "old", "", 0, dialog_retry_ms);
    try testing.expectEqual(DialogAction.move_down, d.action);
}

test "decideDialog: settles when non-dialog bytes arrive past retry timeout" {
    const d = decideDialog(.trust, .move_down, "old", "some other ui", 13, dialog_retry_ms);
    try testing.expectEqual(DialogAction.settled, d.action);
}

test "dialogConfirmAllowed: trust always allowed, bypass/dev_channels require flags" {
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "p" }, .trust));
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "p" }, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "p" }, .dev_channels));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "p", .skip_permissions = true }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "p", .permission_mode = "bypassPermissions" }, .bypass_permissions));
    const ch = [_][]const u8{ "--dangerously-load-development-channels", "x" };
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "p", .extra_args = &ch }, .dev_channels));
}

test "dialogKeyBytes: maps every action to expected escape sequence" {
    var dbuf: [1]u8 = undefined;
    try testing.expectEqualStrings("\r", dialogKeyBytes(.confirm, &dbuf));
    try testing.expectEqualStrings("\x1b[A", dialogKeyBytes(.move_up, &dbuf));
    try testing.expectEqualStrings("\x1b[B", dialogKeyBytes(.move_down, &dbuf));
    try testing.expectEqualStrings("2", dialogKeyBytes(.{ .digit = '2' }, &dbuf));
    try testing.expectEqualStrings("", dialogKeyBytes(.none, &dbuf));
    try testing.expectEqualStrings("", dialogKeyBytes(.settled, &dbuf));
}

test "stripCsi: strips CSI, OSC (BEL and ST), DCS, and 2-byte escapes" {
    const raw = "\x1b[32mhi\x1b[0m\x1b]0;title\x07\x1b]2;t2\x1b\\\x1bP>|v\x1b\\\x1b=ok";
    const s = try stripCsi(testing.allocator, raw);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hiok", s);
}

test "stripCsiInto: matches stripCsi and bounds output to buffer length" {
    var small: [3]u8 = undefined;
    const truncated = stripCsiInto(&small, "\x1b[1mhello\x1b[0m");
    try testing.expectEqualStrings("hel", truncated);
}

test "stripCsiInto: trailing lone ESC terminates cleanly" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abc", stripCsiInto(&buf, "abc\x1b"));
}

test "classifyDialog: handles zero-space Ink first-paint markers" {
    const compact = "BypassPermissionsaccept";
    try testing.expectEqual(DialogKind.bypass_permissions, classifyDialog(compact));
    const ui_compact = "BypassPermissionsacceptforshortcuts";
    try testing.expectEqual(DialogKind.none, classifyDialog(ui_compact));
}
