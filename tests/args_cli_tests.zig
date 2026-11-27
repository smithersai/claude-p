//! Extended CLI flag, variadic, daemon, and help-text regression tests for `args.zig`.
const std = @import("std");
const claude_p = @import("claude_p");

const args = claude_p.args;
const testing = std.testing;
const Options = args.Options;
const OutputFormat = args.OutputFormat;
const ParseError = args.ParseError;
const ParseDiag = args.ParseDiag;
const parse = args.parse;
const parseWithDiag = args.parseWithDiag;
const helpText = args.helpText;

fn expectPassthrough(opts: *const Options, want: []const []const u8) !void {
    try testing.expectEqual(want.len, opts.passthrough.items.len);
    for (want, opts.passthrough.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "parse: repeated tool-rule flags keep every rule" {
    var opts = try parse(testing.allocator, &.{
        "hi", "--disallowedTools", "Bash", "--disallowedTools", "Edit", "--allowedTools", "Read",
    });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try expectPassthrough(&opts, &.{
        "--disallowedTools", "Bash", "--disallowedTools", "Edit", "--allowedTools", "Read",
    });
    try testing.expectEqual(@as(?[]const u8, null), opts.allowed_tools);
    try testing.expectEqual(@as(?[]const u8, null), opts.disallowed_tools);
}

test "parse: variadic tool rules stop at --, and the prompt follows it" {
    var opts = try parse(testing.allocator, &.{ "--disallowedTools", "Bash", "Edit", "--", "do thing" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("do thing", opts.prompt.?);
    try expectPassthrough(&opts, &.{ "--disallowedTools", "Bash", "--disallowedTools", "Edit" });
}

test "parse: tool-rule aliases, = form, and one value holding spaces" {
    var opts = try parse(testing.allocator, &.{
        "--allowed-tools=Bash(git *)", "--disallowed-tools", "Bash Edit", "--verbose",
        "--allowedTools=-weird",       "hi",
    });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expect(opts.verbose);
    try expectPassthrough(&opts, &.{
        "--allowedTools",    "Bash(git *)",
        "--disallowedTools", "Bash Edit",
        "--allowedTools",    "-weird",
    });
}

test "parse: tool rules follow the --add-dir variadic rule" {
    var a = try parse(testing.allocator, &.{ "--disallowedTools", "Bash", "--disallowedTools", "Edit", "hello" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), a.prompt);
    try expectPassthrough(&a, &.{
        "--disallowedTools", "Bash", "--disallowedTools", "Edit", "--disallowedTools", "hello",
    });

    var b = try parse(testing.allocator, &.{ "--disallowedTools", "Bash" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), b.prompt);
    try expectPassthrough(&b, &.{ "--disallowedTools", "Bash" });

    var d = try parse(testing.allocator, &.{ "daemon", "--allowedTools", "Read", "Grep", "--disallowed-tools=Bash" });
    defer d.deinit(testing.allocator);
    try testing.expect(d.is_daemon);
    try expectPassthrough(&d, &.{ "--allowedTools", "Read", "--allowedTools", "Grep", "--disallowedTools", "Bash" });

    for ([_][]const u8{ "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools" }) |f| {
        try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{f}));
        try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{ f, "--", "hi" }));
        try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{ f, "--verbose" }));
    }
}

test "parse: -n/--name forwards its value and never takes the prompt" {
    var a = try parse(testing.allocator, &.{ "-n", "sample-session", "--", "hello" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", a.prompt.?);
    try expectPassthrough(&a, &.{ "-n", "sample-session" });

    var b = try parse(testing.allocator, &.{ "-n", "sample-session", "hello" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", b.prompt.?);
    try expectPassthrough(&b, &.{ "-n", "sample-session" });

    var c = try parse(testing.allocator, &.{ "-n", "sample-session" });
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), c.prompt);
    try expectPassthrough(&c, &.{ "-n", "sample-session" });

    var d = try parse(testing.allocator, &.{ "--name", "-odd", "hello" });
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", d.prompt.?);
    try expectPassthrough(&d, &.{ "--name", "-odd" });

    var e = try parse(testing.allocator, &.{ "daemon", "--name=x y", "-n", "s" });
    defer e.deinit(testing.allocator);
    try expectPassthrough(&e, &.{ "--name=x y", "-n", "s" });

    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"-n"}));
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{ "hello", "--name" }));
}

test "parse: rejects unenforced print-only flags" {
    const names = [_][]const u8{
        "--max-turns",             "--fallback-model",       "--include-partial-messages",
        "--forward-subagent-text", "--replay-user-messages", "--verbose-thinking",
    };
    for (names) |n| {
        var buf: [64]u8 = undefined;
        const eq = try std.fmt.bufPrint(&buf, "{s}=1", .{n});
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ n, "3", "hi" }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "hi", eq }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "daemon", n }));
    }
}

test "parse: daemon mode rejects --output-format text and json" {
    const bad = [_][]const []const u8{
        &.{ "daemon", "--output-format", "json" },
        &.{ "daemon", "--output-format=text" },
        &.{ "daemon", "--output-format", "stream-json", "--output-format", "json" },
    };
    for (bad) |argv| try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, argv));

    var a = try parse(testing.allocator, &.{ "daemon", "--output-format", "stream-json" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.stream_json, a.output_format);
    var b = try parse(testing.allocator, &.{ "daemon", "--output-format=json", "--output-format=stream-json" });
    defer b.deinit(testing.allocator);
    try testing.expect(b.output_format_explicit);
    var c = try parse(testing.allocator, &.{"daemon"});
    defer c.deinit(testing.allocator);
    try testing.expect(!c.output_format_explicit);
}

test "parseWithDiag: records the offending token for every error" {
    const Case = struct { argv: []const []const u8, err: ParseError, near: ?[]const u8 };
    const cases = [_]Case{
        .{ .argv = &.{ "--timeout", "abc" }, .err = ParseError.BadInteger, .near = "abc" },
        .{ .argv = &.{"--idle-timeout=-1"}, .err = ParseError.BadInteger, .near = "-1" },
        .{ .argv = &.{ "--output-format", "yaml" }, .err = ParseError.BadOutputFormat, .near = "yaml" },
        .{ .argv = &.{ "hi", "--model" }, .err = ParseError.MissingValue, .near = "--model" },
        .{ .argv = &.{ "--add-dir", "--", "hi" }, .err = ParseError.MissingValue, .near = "--add-dir" },
        .{ .argv = &.{"--allowed-tools"}, .err = ParseError.MissingValue, .near = "--allowed-tools" },
        .{ .argv = &.{"-n"}, .err = ParseError.MissingValue, .near = "-n" },
        .{ .argv = &.{ "hi", "--max-turns=3" }, .err = ParseError.UnsupportedFlag, .near = "--max-turns" },
        .{ .argv = &.{ "-pc", "hello" }, .err = ParseError.UnsupportedFlag, .near = "-pc" },
        .{ .argv = &.{ "-cp", "hello" }, .err = ParseError.UnsupportedFlag, .near = "-cp" },
        .{ .argv = &.{ "--", "hello", "--setting-json=secret" }, .err = ParseError.UnknownFlag, .near = null },
        .{ .argv = &.{ "-p", "hi" }, .err = ParseError.UnsupportedFlag, .near = "-p" },
        .{ .argv = &.{ "daemon", "--output-format=json" }, .err = ParseError.UnsupportedFlag, .near = "--output-format" },
        .{ .argv = &.{ "one", "two" }, .err = ParseError.UnknownFlag, .near = null },
        .{ .argv = &.{ "--", "one", "two" }, .err = ParseError.UnknownFlag, .near = null },
        .{ .argv = &.{ "daemon", "hello" }, .err = ParseError.UnknownFlag, .near = null },
        .{ .argv = &.{ "daemon", "--input-file=/p" }, .err = ParseError.UnknownFlag, .near = "--input-file" },
        .{ .argv = &.{ "--extra-hook", "nope" }, .err = ParseError.BadExtraHook, .near = "nope" },
        .{ .argv = &.{ "--output-format", "stream-json", "hi" }, .err = ParseError.StreamJsonRequiresVerbose, .near = "stream-json" },
    };
    for (cases) |c| {
        var diag: ParseDiag = .{ .offending = "stale" };
        try testing.expectError(c.err, parseWithDiag(testing.allocator, c.argv, &diag));
        if (c.near) |name| try testing.expectEqualStrings(name, diag.offending.?) else try testing.expect(diag.offending == null);
    }
    var diag: ParseDiag = .{ .offending = "stale" };
    var ok = try parseWithDiag(testing.allocator, &.{"hi"}, &diag);
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), diag.offending);
}

test "parse: --add-dir aggregates across repeats" {
    var opts = try parse(testing.allocator, &.{ "hi", "--add-dir", "/a", "--add-dir", "/b" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.add_dirs.items.len);
    try testing.expectEqualStrings("/a", opts.add_dirs.items[0]);
    try testing.expectEqualStrings("/b", opts.add_dirs.items[1]);
}

test "parse: rejects --print and --settings including =value spellings" {
    const bad = [_][]const []const u8{
        &.{ "-p", "hi" },
        &.{ "--print", "hi" },
        &.{ "--settings", "{}" },
        &.{"--settings={}"},
        &.{ "--settings=/tmp/s.json", "hi" },
        &.{ "hi", "--print=true" },
        &.{"--print="},
        &.{ "-p=1", "hi" },
        &.{ "daemon", "--settings={}" },
        &.{ "daemon", "--print=1" },
    };
    for (bad) |argv| {
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, argv));
    }
    var a = try parse(testing.allocator, &.{ "--", "--settings={}" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("--settings={}", a.prompt.?);
    var b = try parse(testing.allocator, &.{ "--settingsx=1", "--printer" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), b.passthrough.items.len);
}

test "parse: stream-json requires --verbose except with --help" {
    try testing.expectError(
        ParseError.StreamJsonRequiresVerbose,
        parse(testing.allocator, &.{ "--output-format", "stream-json", "hi" }),
    );
    try testing.expectError(
        ParseError.StreamJsonRequiresVerbose,
        parse(testing.allocator, &.{ "--output-format=stream-json", "hi" }),
    );
    var ok = try parse(testing.allocator, &.{ "--output-format", "stream-json", "--verbose", "hi" });
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.stream_json, ok.output_format);
    var help = try parse(testing.allocator, &.{ "--output-format", "stream-json", "--help" });
    defer help.deinit(testing.allocator);
    try testing.expect(help.show_help);
}

test "parse: Claude Code 2.1.330 boolean flags do not consume the prompt" {
    const flags = [_][]const u8{ "--ax-screen-reader", "--bg", "--background", "--desktop", "--restricted" };
    for (flags) |flag| {
        var opts = try parse(testing.allocator, &.{ flag, "the prompt" });
        defer opts.deinit(testing.allocator);
        try testing.expectEqualStrings("the prompt", opts.prompt.?);
        try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
        try testing.expectEqualStrings(flag, opts.passthrough.items[0]);
    }
}

test "parse: rejects --bare and --safe-mode while allowing lookalikes" {
    const bad = [_][]const []const u8{
        &.{ "--bare", "hi" },          &.{ "hi", "--bare" }, &.{"--bare=true"},
        &.{ "--safe-mode", "hi" },     &.{"--safe-mode=1"},  &.{ "daemon", "--bare" },
        &.{ "daemon", "--safe-mode" },
    };
    for (bad) |argv| {
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, argv));
    }
    var opts = try parse(testing.allocator, &.{ "--bareword", "x", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.passthrough.items.len);
}

test "parse: --transcript-idle-timeout defaults, space/= forms, and errors" {
    var def = try parse(testing.allocator, &.{"hi"});
    defer def.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 600), def.transcript_idle_timeout_seconds);

    var a = try parse(testing.allocator, &.{ "--transcript-idle-timeout", "45", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 45), a.transcript_idle_timeout_seconds);

    var b = try parse(testing.allocator, &.{ "--transcript-idle-timeout=0", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), b.transcript_idle_timeout_seconds);

    var c = try parse(testing.allocator, &.{ "daemon", "--transcript-idle-timeout", "0" });
    defer c.deinit(testing.allocator);
    try testing.expect(c.is_daemon);
    try testing.expectEqual(@as(u32, 0), c.transcript_idle_timeout_seconds);

    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--transcript-idle-timeout", "ten" }));
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--transcript-idle-timeout", "-1" }));
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{"--transcript-idle-timeout="}));
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--transcript-idle-timeout"}));
}

test "parse: --extra-hook repeatable, splits on first =, and rejects malformed" {
    var opts = try parse(testing.allocator, &.{
        "--extra-hook",                          "PreToolUse=echo pre",
        "--extra-hook=PostToolUse=env A=1 true", "hi",
    });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.extra_hooks.items.len);
    try testing.expectEqualStrings("PreToolUse", opts.extra_hooks.items[0].event);
    try testing.expectEqualStrings("echo pre", opts.extra_hooks.items[0].command);
    try testing.expectEqualStrings("PostToolUse", opts.extra_hooks.items[1].event);
    try testing.expectEqualStrings("env A=1 true", opts.extra_hooks.items[1].command);

    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "PreToolUse" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "=echo hi" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "Stop=" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{"--extra-hook=Stop"}));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{"--extra-hook=="}));
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--extra-hook"}));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{
        "--extra-hook", "Stop=echo ok", "--extra-hook", "nope",
    }));
}

test "parse: --setting-json and --permission-mode manual/default" {
    var a = try parse(testing.allocator, &.{ "--setting-json", "{\"env\":{\"A\":\"1\"}}", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\"}}", a.extra_settings_json.?);

    var b = try parse(testing.allocator, &.{ "--setting-json={\"model\":\"x\"}", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"model\":\"x\"}", b.extra_settings_json.?);
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--setting-json"}));

    var c = try parse(testing.allocator, &.{ "--permission-mode", "manual", "hi" });
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("manual", c.permission_mode.?);

    var d = try parse(testing.allocator, &.{ "--permission-mode", "default", "hi" });
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("default", d.permission_mode.?);
}

test "parse: every value flag accepts --flag value and --flag=value identically" {
    const Case = struct { flag: []const u8, value: []const u8 };
    const cases = [_]Case{
        .{ .flag = "--output-format", .value = "json" },
        .{ .flag = "--model", .value = "opus" },
        .{ .flag = "--permission-mode", .value = "plan" },
        .{ .flag = "--system-prompt", .value = "be terse" },
        .{ .flag = "--append-system-prompt", .value = "x=y" },
        .{ .flag = "--setting-sources", .value = "user" },
        .{ .flag = "--resume", .value = "abc" },
        .{ .flag = "-r", .value = "abc" },
        .{ .flag = "--session-id", .value = "u" },
        .{ .flag = "--cwd", .value = "/tmp" },
        .{ .flag = "--input-file", .value = "/tmp/p" },
        .{ .flag = "--timeout", .value = "0" },
        .{ .flag = "--idle-timeout", .value = "9" },
        .{ .flag = "--transcript-idle-timeout", .value = "8" },
        .{ .flag = "--extra-hook", .value = "Stop=echo a=b" },
        .{ .flag = "--setting-json", .value = "{}" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        const eq = try std.fmt.bufPrint(&buf, "{s}={s}", .{ c.flag, c.value });
        var a = try parse(testing.allocator, &.{ c.flag, c.value, "hi" });
        defer a.deinit(testing.allocator);
        var b = try parse(testing.allocator, &.{ eq, "hi" });
        defer b.deinit(testing.allocator);
        try testing.expectEqualStrings("hi", a.prompt.?);
        try testing.expectEqualStrings("hi", b.prompt.?);
        try testing.expectEqual(@as(usize, 0), a.passthrough.items.len);
        try testing.expectEqual(@as(usize, 0), b.passthrough.items.len);
        try testing.expectEqual(a.output_format, b.output_format);
        try testing.expectEqual(a.timeout_seconds, b.timeout_seconds);
        try testing.expectEqual(a.idle_timeout_seconds, b.idle_timeout_seconds);
        try testing.expectEqual(a.transcript_idle_timeout_seconds, b.transcript_idle_timeout_seconds);
        try testing.expectEqual(a.extra_hooks.items.len, b.extra_hooks.items.len);
        inline for (.{
            "model",           "permission_mode",     "system_prompt", "append_system_prompt",
            "setting_sources", "resume_session",      "session_id",    "cwd",
            "input_file",      "extra_settings_json",
        }) |field| {
            const x = @field(a, field);
            const y = @field(b, field);
            try testing.expectEqual(x == null, y == null);
            if (x) |xs| try testing.expectEqualStrings(xs, y.?);
        }
    }
}

test "parse: -r alias, unknown --flag=value, variadic dash guard, and daemon rejections" {
    var r1 = try parse(testing.allocator, &.{ "-r", "sid", "hi" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("sid", r1.resume_session.?);
    var r2 = try parse(testing.allocator, &.{ "-r=sid", "hi" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("sid", r2.resume_session.?);
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"-r"}));

    var unk = try parse(testing.allocator, &.{ "--foo=bar", "summarize this" });
    defer unk.deinit(testing.allocator);
    try testing.expectEqualStrings("summarize this", unk.prompt.?);
    try expectPassthrough(&unk, &.{"--foo=bar"});

    const bad_var = [_][]const []const u8{
        &.{ "--add-dir", "--", "hi" },
        &.{ "--add-dir", "--verbose" },
        &.{ "--mcp-config", "-x" },
        &.{ "--mcp-config", "--", "hi" },
        &.{ "hi", "--add-dir", "-" },
    };
    for (bad_var) |argv| try testing.expectError(ParseError.MissingValue, parse(testing.allocator, argv));

    var opts = try parse(testing.allocator, &.{ "--add-dir=-weird", "--mcp-config=--cfg", "/a", "--add-dir=" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), opts.add_dirs.items.len);
    try testing.expectEqualStrings("-weird", opts.add_dirs.items[0]);
    try testing.expectEqualStrings("", opts.add_dirs.items[1]);
    try testing.expectEqual(@as(usize, 1), opts.mcp_configs.items.len);
    try testing.expectEqualStrings("--cfg", opts.mcp_configs.items[0]);
    try testing.expectEqualStrings("/a", opts.prompt.?);

    const print_only = [_][]const u8{ "--no-session-persistence", "--input-format", "--json-schema", "--max-budget-usd" };
    for (print_only) |n| {
        var buf: [64]u8 = undefined;
        const eq = try std.fmt.bufPrint(&buf, "{s}=1", .{n});
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ n, "hi" }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "hi", eq }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "daemon", n }));
    }

    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "hello" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--", "hello" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--input-file", "/tmp/p" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--input-file=/tmp/p" }));
    var ok = try parse(testing.allocator, &.{ "daemon", "--model", "opus" });
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.is_daemon);
}

test "helpText documents the 2.1.330 surface and rejected flags accurately" {
    const h = helpText();
    const needles = [_][]const u8{
        "acceptEdits|auto|bypassPermissions|manual|default|dontAsk|plan",
        "--transcript-idle-timeout <seconds>",
        "(default: 600)",
        "--extra-hook <Event>=<cmd>",
        "--setting-json <json>",
        "`--bare`/`--safe-mode`",
        "--resume, -r <id>",
        "--option=<value>",
        "`--no-session-persistence`",
        "`--input-format`, `--json-schema`, `--max-budget-usd`",
        "0 disables. (default: 300)",
        "cap on the initial SessionStart",
        "Daemon mode rejects PROMPT and --input-file.",
        "`<stdin>\\n\\n<PROMPT>`",
        "rejects --output-format text and json",
        "session-transcript JSONL events plus a claude -p-shaped result envelope",
        "not full native",
        "--allowedTools <rule>...",
        "--name, -n <name>",
        "`--max-turns`, `--fallback-model`, `--include-partial-messages`",
    };
    for ([_][]const u8{ "wire-compatible", "--max-turns <N>", "--fallback-model <name>" }) |absent| {
        try testing.expect(std.mem.indexOf(u8, h, absent) == null);
    }
    for (needles) |n| try testing.expect(std.mem.indexOf(u8, h, n) != null);
}
