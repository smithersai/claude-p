//! CLI flag tables, value-flag matcher, error/output enums, and embedded help text.
const std = @import("std");
const hook_mod = @import("../hook.zig");

/// Supported stdout rendering modes (`text`, `json`, `stream-json`).
pub const OutputFormat = enum {
    text,
    json,
    stream_json,

    pub fn fromString(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "stream-json")) return .stream_json;
        return null;
    }
};

/// Error set returned when parsing command-line arguments fails.
pub const ParseError = error{
    BadOutputFormat,
    MissingValue,
    UnknownFlag,
    UnsupportedFlag,
    StreamJsonRequiresVerbose,
    BadInteger,
    BadFloat,
    BadExtraHook,
    OutOfMemory,
};

/// Long flags that `claude` accepts with NO value (prevents greedy passthrough swallowing PROMPT).
pub const known_boolean_long_flags = [_][]const u8{
    "--allow-dangerously-skip-permissions", "--ax-screen-reader",       "--background",
    "--bare",                               "--bg",                     "--brief",
    "--chrome",                             "--no-chrome",              "--dangerously-skip-permissions",
    "--desktop",                            "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections",
    "--fork-session",                       "--ide",                    "--include-hook-events",
    "--mcp-debug",                          "--restricted",             "--safe-mode",
    "--strict-mcp-config",                  "--tmux",
};

/// Return true if `flag` is a known boolean-only Claude Code long flag.
pub fn isKnownBoolean(flag: []const u8) bool {
    for (known_boolean_long_flags) |b| if (std.mem.eql(u8, b, flag)) return true;
    return false;
}

/// Flags `parse` refuses (bare or `<flag>=<value>`) because they break hook injection or are print-only.
pub const rejected_flags = [_][]const u8{
    "-p",                      "--print",                "--settings",
    "--bare",                  "--safe-mode",            "--no-session-persistence",
    "--input-format",          "--json-schema",          "--max-budget-usd",
    "--max-turns",             "--fallback-model",       "--include-partial-messages",
    "--forward-subagent-text", "--replay-user-messages", "--verbose-thinking",
};

/// Return true if `flag` (or its `<name>=<value>` form or bundled `-p`) is rejected.
pub fn isRejectedFlag(flag: []const u8) bool {
    const name = std.mem.sliceTo(flag, '=');
    const short_p = name.len > 2 and name[0] == '-' and name[1] != '-' and
        std.mem.indexOfScalar(u8, name[1..], 'p') != null;
    if (short_p) return true;
    return matchFlag(flag, rejected_flags) != null;
}

/// Parse `<Event>=<cmd>`. Splits on the first `=` so commands may contain `=`.
pub fn parseExtraHook(value: []const u8) ParseError!hook_mod.ExtraHook {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return ParseError.BadExtraHook;
    const event = value[0..eq];
    const command = value[eq + 1 ..];
    if (event.len == 0 or command.len == 0) return ParseError.BadExtraHook;
    std.debug.assert(event.len > 0 and command.len > 0);
    return .{ .event = event, .command = command };
}

/// Parse a base-10 `u32`, mapping any format error to `ParseError.BadInteger`.
pub fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch ParseError.BadInteger;
}

const help_text = @embedFile("../args_help.txt");

/// Return the static `--help` usage text for `claude-p`.
pub fn helpText() []const u8 {
    std.debug.assert(help_text.len > 0);
    return help_text;
}

/// Wrapper-owned flags that take exactly one value (`<name> <val>` or `<name>=<val>`).
pub const ValueFlag = enum {
    output_format,
    model,
    permission_mode,
    system_prompt,
    append_system_prompt,
    setting_sources,
    resume_session,
    session_id,
    cwd,
    input_file,
    timeout,
    idle_timeout,
    transcript_idle_timeout,
    extra_hook,
    setting_json,
};

/// Table mapping CLI flag spellings to `ValueFlag`.
pub const value_flag_table = [_]struct { name: []const u8, flag: ValueFlag }{
    .{ .name = "--output-format", .flag = .output_format },
    .{ .name = "--model", .flag = .model },
    .{ .name = "--permission-mode", .flag = .permission_mode },
    .{ .name = "--system-prompt", .flag = .system_prompt },
    .{ .name = "--append-system-prompt", .flag = .append_system_prompt },
    .{ .name = "--setting-sources", .flag = .setting_sources },
    .{ .name = "--resume", .flag = .resume_session },
    .{ .name = "-r", .flag = .resume_session },
    .{ .name = "--session-id", .flag = .session_id },
    .{ .name = "--cwd", .flag = .cwd },
    .{ .name = "--input-file", .flag = .input_file },
    .{ .name = "--timeout", .flag = .timeout },
    .{ .name = "--idle-timeout", .flag = .idle_timeout },
    .{ .name = "--transcript-idle-timeout", .flag = .transcript_idle_timeout },
    .{ .name = "--extra-hook", .flag = .extra_hook },
    .{ .name = "--setting-json", .flag = .setting_json },
};

/// Match result identifying a table entry and optional `=value` suffix.
pub const FlagMatch = struct {
    /// Index into the flag's table.
    index: usize,
    /// Set for the `<name>=<value>` spelling.
    inline_value: ?[]const u8,
};

/// Match `a` against `names` as `<name>` or `<name>=<value>`.
pub fn matchFlag(a: []const u8, names: anytype) ?FlagMatch {
    std.debug.assert(names.len > 0);
    for (names, 0..) |n, idx| {
        const name: []const u8 = if (@TypeOf(n) == []const u8) n else n.name;
        if (std.mem.eql(u8, a, name)) return .{ .index = idx, .inline_value = null };
        if (a.len > name.len and std.mem.startsWith(u8, a, name) and a[name.len] == '=')
            return .{ .index = idx, .inline_value = a[name.len + 1 ..] };
    }
    return null;
}

// -------- tests --------
const testing = std.testing;

test "OutputFormat.fromString: parses text, json, stream-json" {
    try testing.expectEqual(OutputFormat.text, OutputFormat.fromString("text").?);
    try testing.expectEqual(OutputFormat.json, OutputFormat.fromString("json").?);
    try testing.expectEqual(OutputFormat.stream_json, OutputFormat.fromString("stream-json").?);
}

test "OutputFormat.fromString: rejects unknown formats" {
    try testing.expectEqual(@as(?OutputFormat, null), OutputFormat.fromString("yaml"));
    try testing.expectEqual(@as(?OutputFormat, null), OutputFormat.fromString(""));
}

test "isKnownBoolean: recognizes Claude Code boolean flags" {
    try testing.expect(isKnownBoolean("--brief"));
    try testing.expect(isKnownBoolean("--strict-mcp-config"));
    try testing.expect(isKnownBoolean("--restricted"));
}

test "isKnownBoolean: rejects value flags and unknown flags" {
    try testing.expect(!isKnownBoolean("--model"));
    try testing.expect(!isKnownBoolean("--max-turns"));
    try testing.expect(!isKnownBoolean("--unknown"));
}

test "isRejectedFlag: rejects -p, --print, --settings, --bare, --safe-mode" {
    try testing.expect(isRejectedFlag("-p"));
    try testing.expect(isRejectedFlag("--print"));
    try testing.expect(isRejectedFlag("--settings"));
    try testing.expect(isRejectedFlag("--bare"));
    try testing.expect(isRejectedFlag("--safe-mode"));
}

test "isRejectedFlag: rejects =value spellings and bundled short -p" {
    try testing.expect(isRejectedFlag("--settings={}"));
    try testing.expect(isRejectedFlag("--print=1"));
    try testing.expect(isRejectedFlag("-pc"));
    try testing.expect(isRejectedFlag("-cp"));
}

test "isRejectedFlag: allows lookalike flags" {
    try testing.expect(!isRejectedFlag("--printer"));
    try testing.expect(!isRejectedFlag("--settingsx=1"));
    try testing.expect(!isRejectedFlag("--bareword"));
}

test "isRejectedFlag: rejects unenforced print-only flags" {
    try testing.expect(isRejectedFlag("--max-turns"));
    try testing.expect(isRejectedFlag("--fallback-model=haiku"));
    try testing.expect(isRejectedFlag("--json-schema={}"));
}

test "parseExtraHook: splits on first = preserving = inside command" {
    const h = try parseExtraHook("PostToolUse=env A=1 true");
    try testing.expectEqualStrings("PostToolUse", h.event);
    try testing.expectEqualStrings("env A=1 true", h.command);
}

test "parseExtraHook: rejects missing =, empty event, or empty command" {
    try testing.expectError(ParseError.BadExtraHook, parseExtraHook("Stop"));
    try testing.expectError(ParseError.BadExtraHook, parseExtraHook("=echo hi"));
    try testing.expectError(ParseError.BadExtraHook, parseExtraHook("Stop="));
    try testing.expectError(ParseError.BadExtraHook, parseExtraHook("="));
}

test "parseU32: parses 0 and positive integers" {
    try testing.expectEqual(@as(u32, 0), try parseU32("0"));
    try testing.expectEqual(@as(u32, 300), try parseU32("300"));
}

test "parseU32: rejects negatives, non-digits, and empty" {
    try testing.expectError(ParseError.BadInteger, parseU32("-1"));
    try testing.expectError(ParseError.BadInteger, parseU32("abc"));
    try testing.expectError(ParseError.BadInteger, parseU32(""));
}

test "helpText: returns non-empty embedded usage guide" {
    const h = helpText();
    try testing.expect(h.len > 100);
    try testing.expect(std.mem.indexOf(u8, h, "--resume, -r") != null);
}

test "matchFlag: exact bare flag sets inline_value null" {
    const m = matchFlag("--model", value_flag_table).?;
    try testing.expectEqual(ValueFlag.model, value_flag_table[m.index].flag);
    try testing.expect(m.inline_value == null);
}

test "matchFlag: =value form captures inline suffix" {
    const m = matchFlag("--model=opus", value_flag_table).?;
    try testing.expectEqual(ValueFlag.model, value_flag_table[m.index].flag);
    try testing.expectEqualStrings("opus", m.inline_value.?);
}

test "matchFlag: empty inline value is valid empty slice" {
    const m = matchFlag("--cwd=", value_flag_table).?;
    try testing.expectEqual(ValueFlag.cwd, value_flag_table[m.index].flag);
    try testing.expectEqualStrings("", m.inline_value.?);
}

test "matchFlag: rejects prefix collisions without =" {
    try testing.expect(matchFlag("--modeling", value_flag_table) == null);
    try testing.expect(matchFlag("-rx", value_flag_table) == null);
}

test "matchFlag: handles short -r alias" {
    const m = matchFlag("-r=sid", value_flag_table).?;
    try testing.expectEqual(ValueFlag.resume_session, value_flag_table[m.index].flag);
    try testing.expectEqualStrings("sid", m.inline_value.?);
}

test "matchFlag: matches string slice tables too" {
    const m = matchFlag("--bare=true", rejected_flags).?;
    try testing.expectEqualStrings("true", m.inline_value.?);
}

test "value_flag_table covers all 15 ValueFlag variants" {
    try testing.expectEqual(@as(usize, 16), value_flag_table.len);
}
