const std = @import("std");
const driver = @import("claude_p").driver;
const testing = std.testing;

test "a zero-capacity strip destination accepts printable input" {
    var out: [0]u8 = .{};
    try testing.expectEqualStrings("", driver.stripCsiInto(&out, "x"));
}

test "a main UI footer supersedes an affirmative repaint after navigation" {
    const full = "Trust this folder?\n❯ No, exit\n  Yes, I trust this folder\n";
    const fresh = "❯ Yes, I trust this folder\n? for shortcuts";
    try testing.expectEqual(driver.DialogKind.none, driver.classifyDialog(full ++ fresh));
    const decision = driver.decideDialog(.trust, .move_down, full ++ fresh, fresh, fresh.len, 20);
    try testing.expect(decision.action == .none or decision.action == .settled);
}

test "a numbered path suffix does not label an unnumbered trust option" {
    const screen = "Trust this folder?\n/tmp/repo9.\n  Yes, I trust this folder\n❯ No, exit";
    const parsed = driver.analyzeDialog(.trust, screen);
    try testing.expectEqual(@as(?u8, null), parsed.affirmative_digit);
    try testing.expectEqualDeep(driver.DialogAction.move_up, driver.chooseDialogAction(.trust, parsed, .none));
}

const ansi = [_][]const u8{ "\x1b[0m", "\x1b[38;5;153m", "\x1b[?25l", "\x1b[4G", "\x1b[2K", "\x1b[1C" };
const escapes = [_][]const u8{
    "\x1b",             "\x1b[",           "\x1b[38;5;",       "\x1b[ !",                "\x1b[?25h",      "\x1b[0m",
    "\x1b]0;title\x07", "\x1b]unfinished", "\x1b]title\x1b\\", "\x1bPpayload\x07\x1b\\", "\x1bXabc\x1b\\", "\x1b^abc\x1b\\",
    "\x1b_abc\x1b\\",   "\x1bP\x1b",       "\x1b\xff",         "\x1b\x1b[",              "\x00\xff",       "❯",
    "a\r\nb",
};

fn checkStrip(_: void, raw: []const u8) !void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (raw.len == 0) return;
    const allocator = testing.allocator;
    const clean = try driver.stripCsi(allocator, raw);
    defer allocator.free(clean);
    try testing.expect(clean.len <= raw.len);
    try testing.expect(std.mem.indexOfScalar(u8, clean, 0x1b) == null);

    const twice = try driver.stripCsi(allocator, clean);
    defer allocator.free(twice);
    try testing.expectEqualSlices(u8, clean, twice);

    const full = try allocator.alloc(u8, raw.len);
    defer allocator.free(full);
    try testing.expectEqualSlices(u8, clean, driver.stripCsiInto(full, raw));

    var guarded: [8192 + 2]u8 = undefined;
    for ([_]usize{ 0, 1, 7, 64, 8192 }) |cap| {
        guarded[0] = 0xab;
        guarded[cap + 1] = 0xcd;
        const got = driver.stripCsiInto(guarded[1..][0..cap], raw);
        try testing.expect(got.len <= @min(cap, raw.len));
        try testing.expectEqualSlices(u8, clean[0..@min(cap, clean.len)], got);
        try testing.expectEqual(@as(u8, 0xab), guarded[0]);
        try testing.expectEqual(@as(u8, 0xcd), guarded[cap + 1]);
    }
}

const escapes_fuzz_corpus = [_][]const u8{
    "\x1b[38;5;",       "\x1b[ !",         "\x1b[?25h",        "\x1b[0m",
    "\x1b]0;title\x07", "\x1b]unfinished", "\x1b]title\x1b\\", "\x1bPpayload\x07\x1b\\",
    "\x1bXabc\x1b\\",   "\x1b^abc\x1b\\",  "\x1b_abc\x1b\\",   "\x1bP\x1b\\",
    "\x1b\xff\x1b[",    "\x00\xff❯a",    "a\r\nb",
};

test "fuzz stripping arbitrary raw PTY bytes into bounded buffers" {
    try testing.fuzz({}, checkStrip, .{ .corpus = &escapes_fuzz_corpus });
}

test "strip properties across 3000 mixed binary and truncated control streams" {
    var prng = std.Random.DefaultPrng.init(0xc51_05c_dc5);
    const r = prng.random();
    var buf: [384]u8 = undefined;
    for (0..3000) |i| {
        const raw = buf[0..r.uintAtMost(usize, buf.len)];
        r.bytes(raw);
        if (i % 2 == 0) {
            var pos: usize = 0;
            while (pos < raw.len) {
                const token = escapes[r.uintLessThan(usize, escapes.len)];
                const n = @min(token.len, raw.len - pos);
                @memcpy(raw[pos..][0..n], token[0..n]);
                pos += n;
                pos += @min(r.uintLessThan(usize, 6), raw.len - pos);
            }
        }
        try checkStrip({}, raw);
    }
    try checkStrip({}, "x" ** 8193);
}

fn allocatingStrip(allocator: std.mem.Allocator) !void {
    const clean = try driver.stripCsi(allocator, "a\x1b[?25hb\x1b]title\x07c\x1bPfoo\x1b\\d\x1b[38;5;");
    defer allocator.free(clean);
    try testing.expectEqualStrings("abcd", clean);
}

test "stripCsi preserves text around control sequences under allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, allocatingStrip, .{});
}

const actions = [_]driver.DialogAction{ .none, .move_up, .move_down, .{ .digit = '2' }, .confirm, .settled };
const kinds = [_]driver.DialogKind{ .trust, .bypass_permissions, .dev_channels };
const retry: i64 = driver.dialog_retry_ms;

fn checkDialogBytes(_: void, input: []const u8) !void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    // The handler keeps the most recent raw bytes and independently strips the
    // bytes received since the last key, even if that boundary splits an ESC.
    const raw = input[input.len -| driver.recent_capacity..];
    var buf: [driver.recent_capacity]u8 = undefined;
    var fresh_buf: [driver.recent_capacity]u8 = undefined;
    const full = driver.stripCsiInto(&buf, raw);
    const kind = driver.classifyDialog(full);
    const analysis = driver.analyzeDialog(kind, full);
    const initial = driver.decideDialog(.none, .none, full, "", 0, 0);
    try testing.expectEqual(kind, initial.kind);
    try testing.expectEqualDeep(driver.chooseDialogAction(kind, analysis, .none), initial.action);
    try testing.expectEqual(analysis.selection == .affirmative, initial.action == .confirm);

    const cut = if (raw.len == 0) 0 else raw[0] % (raw.len + 1);
    const fresh = driver.stripCsiInto(&fresh_buf, raw[cut..]);
    for (actions) |last| {
        const chosen = driver.chooseDialogAction(kind, analysis, last);
        try testing.expectEqual(analysis.selection == .affirmative, chosen == .confirm);
        const decision = driver.decideDialog(kind, last, full, fresh, raw.len - cut, retry);
        if (decision.action == .confirm and last != .none and cut < raw.len) {
            try testing.expectEqual(driver.DialogSelection.affirmative, driver.analyzeDialog(decision.kind, fresh).selection);
        }
    }
}

test "fuzz classification and decisions on arbitrary PTY screens and partial repaints" {
    try testing.fuzz({}, checkDialogBytes, .{ .corpus = &.{
        "\x00\xff\xe2\x9d",                                           "❯ Yes",                                                      "\x1b]trust folder\x07\x1bP❯ Yes, I trust\x1b\\",
        "folder trust\r\n❯\x1b[4GNo,\nexit\r\nYes, I trust",        "folder trust ❯ Yes, proceed\r❯ No, exit",                  "bypass permissions\n❯ 2. Yes, I accept",
        "loading development channels\n❯ 1. I am using\r\n2. Exit", "Trust folder\n❯ No, exit\n❯ Yes, I trust\n? FORSHORTCUTS", "1" ** 80 ++ ". Yes, I trust this folder\n❯ 9 . No, exit\x1b[38;",
    } });
}

// Render fresh draws independently of the parser. Soft wraps can split any
// option word, and Ink can move the cursor instead of printing a space.
fn writeLabel(w: *std.Io.Writer, r: std.Random, label: []const u8) !void {
    for (label) |b| {
        if (r.uintLessThan(u8, 12) == 0) try w.writeAll("\r\n");
        if (r.uintLessThan(u8, 6) == 0) try w.writeAll(ansi[r.uintLessThan(usize, ansi.len)]);
        if (b == ' ' and r.boolean()) {
            try w.writeAll("\x1b[1C");
        } else {
            try w.writeByte(b);
        }
    }
}

fn paintDialog(w: *std.Io.Writer, r: std.Random, kind: driver.DialogKind, yes: bool, yes_first: bool, header: bool) !void {
    try w.writeAll("\x1b[1G\x1b[0J");
    if (header) switch (kind) {
        .trust => {
            try w.writeAll("Quick safety check: Do you trust this folder?\r\n/tmp/");
            const path_chars = "abcXYZ09 .-_/";
            if (r.boolean()) try w.writeAll("café/");
            for (0..r.uintAtMost(usize, 45)) |_| try w.writeByte(path_chars[r.uintLessThan(usize, path_chars.len)]);
            try w.writeAll("\r\n");
        },
        .bypass_permissions => try w.writeAll("WARNING: Bypass Permissions mode\r\nDo you accept?\r\n"),
        .dev_channels => try w.writeAll("Loading development channels\r\n"),
        .none => unreachable,
    };
    for ([_]bool{ yes_first, !yes_first }, 0..) |affirmative, i| {
        try w.writeAll(ansi[r.uintLessThan(usize, ansi.len)]);
        try w.writeAll(if (yes == affirmative) "❯ " else "  ");
        if (kind != .trust) try w.print("{d}. ", .{i + 1});
        const label: []const u8 = if (affirmative) switch (kind) {
            .trust => "Yes, I trust this folder",
            .bypass_permissions => "Yes, I accept",
            .dev_channels => "I am using this for local development",
            .none => unreachable,
        } else if (kind == .dev_channels) "Exit" else "No, exit";
        try writeLabel(w, r, label);
        try w.writeAll("\x1b[0m\r\n");
    }
}

const footers = [_][]const u8{ "\r\n❯ \r\n? for shortcuts", "\r\n? FOR\x1b[4GSHORTCUTS", "\r\n? FoR ShOrTcUtS" };

test "wrapped negative trust selections require navigation and footer dismissal suppresses keys" {
    var prng = std.Random.DefaultPrng.init(0x21_0330);
    const r = prng.random();
    var screen: [4096]u8 = undefined;
    var stripped: [screen.len]u8 = undefined;
    for (0..1500) |_| {
        var w = std.Io.Writer.fixed(&screen);
        const yes_first = r.boolean();
        try paintDialog(&w, r, .trust, true, yes_first, true);
        const cursor_redraw = w.end;
        try paintDialog(&w, r, .trust, false, yes_first, true);
        const full = driver.stripCsiInto(&stripped, w.buffered());
        var tail: [screen.len]u8 = undefined;
        const fresh = driver.stripCsiInto(&tail, w.buffered()[cursor_redraw..]);
        try testing.expectEqual(driver.DialogKind.trust, driver.classifyDialog(full));
        const parsed = driver.analyzeDialog(.trust, full);
        errdefer std.debug.print("negative trust screen {f}\n", .{std.zig.fmtString(full)});
        try testing.expectEqual(driver.DialogSelection.negative, parsed.selection);
        const expected: driver.DialogAction = if (yes_first) .move_up else .move_down;
        for (actions) |last| {
            try testing.expectEqualDeep(expected, driver.chooseDialogAction(.trust, parsed, last));
            try testing.expectEqualDeep(expected, driver.decideDialog(.trust, last, full, fresh, w.end - cursor_redraw, retry).action);
        }

        const dismissed = kinds[r.uintLessThan(usize, kinds.len)];
        const start = w.end;
        try paintDialog(&w, r, dismissed, true, r.boolean(), true);
        try w.writeAll(footers[r.uintLessThan(usize, footers.len)]);
        const history = driver.stripCsiInto(&stripped, w.buffered());
        const repaint = driver.stripCsiInto(&tail, w.buffered()[start..]);
        try testing.expectEqual(driver.DialogKind.none, driver.classifyDialog(history));
        for (actions) |last| {
            const d = driver.decideDialog(dismissed, last, history, repaint, w.end - start, retry);
            try testing.expect(d.action == .none or d.action == .settled);
        }
    }
}

test "a lossy PTY dismisses trust, bypass, and channel dialogs within the session key budget" {
    var prng = std.Random.DefaultPrng.init(0xd1a106);
    const r = prng.random();
    for (0..1000) |trial| {
        var raw: [driver.recent_capacity]u8 = undefined;
        var buf: [raw.len]u8 = undefined;
        var fresh_buf: [raw.len]u8 = undefined;
        var w = std.Io.Writer.fixed(&raw);
        var stage: usize = 0;
        var yes = false;
        var yes_first = r.boolean();
        const saturate = trial % 64 == 0;
        var ignore_digit_once = saturate or r.boolean();
        try paintDialog(&w, r, .trust, yes, yes_first, true);

        var tracked: driver.DialogKind = .none;
        var last: driver.DialogAction = .none;
        var bytes_at_key: usize = 0;
        var since: i64 = 0;
        var sent: u32 = 0;
        // Six delivered keys suffice with all three dialogs starting negative.
        // Reserve one more for a numbered menu that ignores a digit and redraws.
        const spare_keys = driver.max_dialog_keys - 7;
        var drops_left = if (saturate) spare_keys else r.uintAtMost(u32, spare_keys);
        while (true) {
            const full = driver.stripCsiInto(&buf, w.buffered());
            const new_bytes = w.buffered()[bytes_at_key..];
            const fresh = driver.stripCsiInto(&fresh_buf, new_bytes);
            const d = driver.decideDialog(tracked, last, full, fresh, new_bytes.len, since);
            if (stage == kinds.len) {
                try testing.expectEqual(driver.DialogKind.none, driver.classifyDialog(full));
                try testing.expect(d.action == .none or d.action == .settled);
                if (saturate) try testing.expectEqual(driver.max_dialog_keys, sent);
                break;
            }

            try testing.expectEqual(kinds[stage], d.kind);
            if (new_bytes.len == 0) try testing.expectEqualDeep(last, d.action);
            // Validate even keys that the simulated PTY will drop.
            switch (d.action) {
                .confirm => try testing.expect(yes),
                .move_up => try testing.expect(!yes and yes_first),
                .move_down => try testing.expect(!yes and !yes_first),
                .digit => |digit| {
                    try testing.expect(!yes and d.kind != .trust);
                    try testing.expectEqual(@as(u8, if (yes_first) '1' else '2'), digit);
                },
                .none, .settled => return error.DialogStalled,
            }
            sent += 1;
            try testing.expect(sent <= driver.max_dialog_keys);
            tracked = d.kind;
            last = d.action;
            bytes_at_key = w.end;

            if (drops_left > 0 and (trial % 8 == 0 or r.boolean())) {
                drops_left -= 1;
                // No repaint. Poll before the deadline, then at or beyond it.
                const early = if (r.boolean()) retry - 1 else r.intRangeLessThan(i64, 0, retry);
                try testing.expectEqualDeep(driver.DialogAction.none, driver.decideDialog(tracked, last, full, "", 0, early).action);
                since = if (r.boolean()) retry else retry + r.uintLessThan(u16, 300);
                continue;
            }

            since = r.intRangeLessThan(i64, 0, retry);
            if (last == .confirm) {
                stage += 1;
                if (stage == kinds.len) {
                    try w.writeAll(footers[r.uintLessThan(usize, footers.len)]);
                    continue;
                }
                yes = !saturate and r.boolean();
                yes_first = r.boolean();
                try paintDialog(&w, r, kinds[stage], yes, yes_first, true);
            } else {
                if (last == .digit and ignore_digit_once) {
                    ignore_digit_once = false;
                } else {
                    yes = true;
                }
                try paintDialog(&w, r, kinds[stage], yes, yes_first, r.boolean());
            }
        }
    }
}

const timeout: i64 = driver.prompt_accept_timeout_ms;
const max_attempts = driver.max_prompt_injections;

fn checkWatchdog(attempt: u32, age: i64) !void {
    try testing.expectEqual(driver.WatchdogAction.wait, driver.promptWatchdogAction(true, attempt, age));
    const expected: driver.WatchdogAction = if (age <= timeout) .wait else if (attempt >= max_attempts) .give_up else .reinject;
    try testing.expectEqual(expected, driver.promptWatchdogAction(false, attempt, age));
}

fn urgency(a: driver.WatchdogAction) u8 {
    return switch (a) {
        .wait => 0,
        .reinject => 1,
        .give_up => 2,
    };
}

test "watchdog is bounded and monotonic at timeout, retry limits, and integer extremes" {
    for ([_]u32{ 0, 1, max_attempts - 1, max_attempts, max_attempts + 1, std.math.maxInt(u32) }) |attempt| {
        for ([_]i64{ std.math.minInt(i64), -1, 0, 1, timeout - 1, timeout, timeout + 1, std.math.maxInt(i64) }) |age| {
            try checkWatchdog(attempt, age);
        }
    }
    var prng = std.Random.DefaultPrng.init(0x4000_0004);
    const r = prng.random();
    for (0..3000) |_| {
        const a = r.int(u32);
        const b = r.uintAtMost(u32, max_attempts + 2);
        const x = r.int(i64);
        const y = r.intRangeAtMost(i64, timeout - 2, timeout + 2);
        for ([_]u32{ a, b }) |attempt| {
            try checkWatchdog(attempt, x);
            try checkWatchdog(attempt, y);
            const early = driver.promptWatchdogAction(false, attempt, @min(x, y));
            const late = driver.promptWatchdogAction(false, attempt, @max(x, y));
            try testing.expect(urgency(early) <= urgency(late));
        }
        for ([_]i64{ x, y }) |age| {
            const fewer = driver.promptWatchdogAction(false, @min(a, b), age);
            const more = driver.promptWatchdogAction(false, @max(a, b), age);
            try testing.expect(urgency(fewer) <= urgency(more));
        }
    }
}

fn padAnswer(w: *std.Io.Writer, r: std.Random, core: []const u8) !void {
    const spaces = " \t\r\n";
    for (0..r.uintAtMost(usize, 12)) |_| try w.writeByte(spaces[r.uintLessThan(usize, spaces.len)]);
    try w.writeAll(core);
    for (0..r.uintAtMost(usize, 12)) |_| try w.writeByte(spaces[r.uintLessThan(usize, spaces.len)]);
}

test "Stop text ignores edge whitespace and preserves interior bytes" {
    var prng = std.Random.DefaultPrng.init(0xf1a1_5709);
    const r = prng.random();
    for (0..2000) |_| {
        var body: [96]u8 = undefined;
        const core = body[0..r.intRangeAtMost(usize, 4, body.len)];
        r.bytes(core);
        core[0] = 'a';
        core[core.len - 1] = 'z';
        const pos = r.intRangeAtMost(usize, 1, core.len - 3);
        @memcpy(core[pos..][0..2], "\r\n");

        var final_buf: [128]u8 = undefined;
        var stop_buf: [128]u8 = undefined;
        var final = std.Io.Writer.fixed(&final_buf);
        var stop = std.Io.Writer.fixed(&stop_buf);
        try padAnswer(&final, r, core);
        try padAnswer(&stop, r, core);
        try testing.expect(driver.finalTextMatchesStop(final.buffered(), null));
        try testing.expect(driver.finalTextMatchesStop(final.buffered(), stop.buffered()));
        stop.end = 0;
        try padAnswer(&stop, r, "");
        try testing.expect(driver.finalTextMatchesStop(final.buffered(), stop.buffered()));
        stop.end = 0;
        core[pos] = ' ';
        try padAnswer(&stop, r, core);
        try testing.expect(!driver.finalTextMatchesStop(final.buffered(), stop.buffered()));
    }
}

test "resume detection respects whole argv tokens and explicit options" {
    const decoys = [_][]const u8{ "", "--Resume", "--resume ", " --resume", "-cr", "--continues", "--continue ", "--resumed", "--fork", "--fork-sessions", "--from-prs", "--teleporter", "-teleport", "--no-teleport", "--no-resume", "--model=--resume", "-r=x", "-c\x00", "--resume-session" };
    var prng = std.Random.DefaultPrng.init(0xa269);
    const r = prng.random();
    for (0..2000) |_| {
        var argv: [20][]const u8 = undefined;
        const args = argv[0..r.intRangeAtMost(usize, 1, argv.len)];
        for (args) |*arg| arg.* = decoys[r.uintLessThan(usize, decoys.len)];
        var opts: driver.Options = .{ .prompt = "--continue", .extra_args = args, .session_id = "id" };
        try testing.expect(!driver.isResumeRun(opts));
        opts.cont = true;
        try testing.expect(driver.isResumeRun(opts));
        opts.cont = false;
        opts.resume_session = if (r.boolean()) "" else "some session";
        try testing.expect(driver.isResumeRun(opts));
        opts.resume_session = null;

        var value: [48]u8 = undefined;
        const prefix = "--resume=";
        @memcpy(value[0..prefix.len], prefix);
        r.bytes(value[prefix.len..]);
        const flags = [_][]const u8{
            "--resume",       "--continue",      "-r",          "-c",                                                     "--fork-session",
            "--from-pr",      "--teleport",      "--continue=", "--continue=abc",                                         "--fork-session=true",
            "--from-pr=1234", "--teleport=sess", "--resume=",   value[0..r.intRangeAtMost(usize, prefix.len, value.len)],
        };
        const i = r.uintLessThan(usize, args.len);
        for (flags) |flag| {
            args[i] = flag;
            try testing.expect(driver.isResumeRun(opts));
        }
    }
}

// ---------------------------------------------------------------------------
// Round 1 review fixes: caller-intent gating, failure screens, hook tracing
// ---------------------------------------------------------------------------

test "bypass and dev-channel dialogs are approved only by the caller's own flags" {
    const decoys = [_][]const u8{
        "",                                       "--verbose",                              "bypassPermissions",
        "--permission-mode",                      "plan",                                   "acceptEdits",
        "--permission-mode=plan",                 "--permission-mode=bypasspermissions",    "--Permission-Mode=bypassPermissions",
        "--dangerously-skip-permission",          "--dangerously-skip-permissionsx",        "dangerously-skip-permissions",
        "--allow-dangerously-skip-permissions",   "--dangerously-load-development-channel", "--dangerously-load-development-channelsx",
        "--model=--dangerously-skip-permissions", "--continue",                             "--dangerously-skip-permissions ",
    };
    var prng = std.Random.DefaultPrng.init(0x64_0001);
    const r = prng.random();
    for (0..3000) |_| {
        var argv: [16][]const u8 = undefined;
        const args = argv[0..r.intRangeAtMost(usize, 1, argv.len)];
        for (args, 0..) |*arg, i| {
            arg.* = decoys[r.uintLessThan(usize, decoys.len)];
            // "--permission-mode bypassPermissions" as two tokens is real intent.
            if (i > 0 and std.mem.eql(u8, args[i - 1], "--permission-mode") and std.mem.eql(u8, arg.*, "bypassPermissions")) arg.* = "plan";
        }
        var opts: driver.Options = .{
            .prompt = "--dangerously-skip-permissions --dangerously-load-development-channels",
            .extra_args = args,
            .permission_mode = if (r.boolean()) null else "acceptEdits",
            .system_prompt = "bypassPermissions",
            .model = "--dangerously-skip-permissions",
        };
        // An ordinary run answers the trust dialog and nothing else.
        try testing.expect(driver.dialogConfirmAllowed(opts, .trust));
        try testing.expect(driver.dialogConfirmAllowed(opts, .none));
        try testing.expect(!driver.dialogConfirmAllowed(opts, .bypass_permissions));
        try testing.expect(!driver.dialogConfirmAllowed(opts, .dev_channels));

        // Explicit intent in the final flags.
        opts.extra_args = &.{};
        switch (r.uintLessThan(u8, 4)) {
            0 => opts.skip_permissions = true,
            1 => opts.permission_mode = "bypassPermissions",
            2 => opts.extra_args = &.{"--dangerously-skip-permissions"},
            else => opts.extra_args = &.{ "--permission-mode", "bypassPermissions" },
        }
        try testing.expect(driver.dialogConfirmAllowed(opts, .bypass_permissions));
        try testing.expect(!driver.dialogConfirmAllowed(opts, .dev_channels));

        // The dev-channels flag unlocks dev channels only.
        var dev: driver.Options = .{ .prompt = "x", .extra_args = &.{
            "--verbose",
            if (r.boolean()) "--dangerously-load-development-channels" else "--dangerously-load-development-channels=server:demo",
        } };
        try testing.expect(driver.dialogConfirmAllowed(dev, .dev_channels));
        try testing.expect(!driver.dialogConfirmAllowed(dev, .bypass_permissions));
        dev.extra_args = &.{};
        try testing.expect(!driver.dialogConfirmAllowed(dev, .dev_channels));
    }
}

fn checkFailureScreen(_: void, raw: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (raw.len == 0) return;
    var out: [driver.failure_screen_max_bytes]u8 = undefined;
    const screen = driver.formatFailureScreen(&out, raw);
    try testing.expect(screen.len <= driver.failure_screen_max_bytes);
    try testing.expect(std.mem.count(u8, screen, "\n") < driver.failure_screen_max_lines);
    // Printable text only: no escape, no control byte, no blank line, no
    // leading or trailing newline.
    for (screen) |b| try testing.expect(b == '\n' or (b >= 0x20 and b != 0x7f));
    try testing.expect(std.mem.indexOf(u8, screen, "\n\n") == null);
    if (screen.len > 0) {
        try testing.expect(screen[0] != '\n' and screen[screen.len - 1] != '\n');
        try testing.expect((screen[0] & 0xC0) != 0x80 or !std.unicode.utf8ValidateSlice(raw));
    }
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |line| {
        if (screen.len > 0) try testing.expect(std.mem.trim(u8, line, " ").len > 0);
    }
    // Deterministic.
    var again: [driver.failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings(screen, driver.formatFailureScreen(&again, raw));
}

test "fuzz failure screens stay bounded, printable, and free of blank lines" {
    try testing.fuzz({}, checkFailureScreen, .{ .corpus = &.{
        "\r\n\r\n",
        "\x1b[31msh: claude: command not found\x1b[0m\r\n",
        "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\nr\n",
        "\xe2\x9d\xaf No, exit\r\n  Yes, I trust this folder\r\n",
        "\x1b]0;title\x07text\x1b[",
        "\x1b[31m",
        "\xff\xfe\x80\x81",
    } });
}

test "failure screens over 3000 random PTY captures keep the last lines in order" {
    var prng = std.Random.DefaultPrng.init(0xf5_0001);
    const r = prng.random();
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    const noise = [_][]const u8{ "\x1b[1m", "\x1b[0m", "\x1b[2K", "\r", "\r\n", "\n\n", "\x07", "\x1b]0;t\x07", "   \r\n" };
    for (0..3000) |_| {
        raw.clearRetainingCapacity();
        const lines = r.uintLessThan(usize, 60);
        for (0..lines) |i| {
            try raw.appendSlice(testing.allocator, noise[r.uintLessThan(usize, noise.len)]);
            try raw.writer(testing.allocator).print("row{d}", .{i});
            try raw.appendSlice(testing.allocator, noise[r.uintLessThan(usize, noise.len)]);
            try raw.appendSlice(testing.allocator, "\r\n");
        }
        try checkFailureScreen({}, raw.items);
        var out: [driver.failure_screen_max_bytes]u8 = undefined;
        const screen = driver.formatFailureScreen(&out, raw.items);
        if (lines == 0) {
            try testing.expectEqualStrings("", screen);
            continue;
        }
        // The last row is always present and rows appear in increasing order.
        var last_buf: [16]u8 = undefined;
        const last = try std.fmt.bufPrint(&last_buf, "row{d}", .{lines - 1});
        try testing.expect(std.mem.endsWith(u8, screen, last));
        var it = std.mem.splitScalar(u8, screen, '\n');
        var prev: ?usize = null;
        var shown: usize = 0;
        while (it.next()) |line| {
            const n = try std.fmt.parseInt(usize, line[3..], 10);
            if (prev) |p| try testing.expectEqual(p + 1, n);
            prev = n;
            shown += 1;
        }
        try testing.expectEqual(@min(lines, driver.failure_screen_max_lines), shown);
    }
}

test "hook traces carry the event name and payload size and nothing else" {
    var prng = std.Random.DefaultPrng.init(0x11_0001);
    const r = prng.random();
    const events = std.enums.values(@typeInfo(@TypeOf(driver.formatHookTrace)).@"fn".params[1].type.?);
    for (0..2000) |_| {
        const event = events[r.uintLessThan(usize, events.len)];
        const len = r.int(usize);
        var buf: [96]u8 = undefined;
        const line = driver.formatHookTrace(&buf, event, len);
        var want_buf: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "hook: {s} payload_bytes={d}", .{ @tagName(event), len });
        try testing.expectEqualStrings(want, line);
        for (line) |b| try testing.expect(b >= 0x20 and b < 0x7f);
    }
}

test "the monotonic clock never steps backwards across threads" {
    const Worker = struct {
        fn run(ok: *std.atomic.Value(bool)) void {
            var prev = driver.monotonicNs();
            for (0..20_000) |_| {
                const now = driver.monotonicNs();
                if (now < prev) ok.store(false, .seq_cst);
                prev = now;
            }
        }
    };
    var ok = std.atomic.Value(bool).init(true);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&ok});
    for (threads) |t| t.join();
    try testing.expect(ok.load(.seq_cst));
    // Anchored to the wall clock at first use, so it fits i64 atomics.
    const now = driver.monotonicNs();
    try testing.expect(now > 0 and now < std.math.maxInt(i64));
}

test "dialog intent honors value boundaries, the end of options and the final permission mode" {
    const flags = [_]struct { name: []const u8, kind: driver.DialogKind }{
        .{ .name = "--dangerously-skip-permissions", .kind = .bypass_permissions },
        .{ .name = "--permission-mode=bypassPermissions", .kind = .bypass_permissions },
        .{ .name = "--dangerously-load-development-channels", .kind = .dev_channels },
    };
    for (flags) |f| {
        for ([_][]const u8{ "--system-prompt", "--model", "--append-system-prompt", "--" }) |prefix| {
            try testing.expect(!driver.dialogConfirmAllowed(.{ .prompt = "p", .extra_args = &.{ prefix, f.name } }, f.kind));
        }
    }
    try testing.expect(!driver.dialogConfirmAllowed(.{
        .prompt = "p",
        .permission_mode = "bypassPermissions",
        .extra_args = &.{ "--permission-mode=bypassPermissions", "--permission-mode", "default" },
    }, .bypass_permissions));
}
