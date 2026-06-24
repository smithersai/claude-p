//! CLI argument parser. Mirrors a useful subset of `claude -p`'s surface
//! and forwards unknown flags through to the child `claude` invocation.
const std = @import("std");
const hook = @import("hook.zig");

pub const ExtraHook = hook.ExtraHook;

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

pub const ParseError = error{
    BadOutputFormat,
    MissingValue,
    UnknownFlag,
    UnsupportedFlag,
    StreamJsonRequiresVerbose,
    BadInteger,
    BadFloat,
    InvalidExtraHook,
    InvalidSettingJson,
    OutOfMemory,
};

pub const Options = struct {
    /// Heap-allocated; owns its strings.
    prompt: ?[]const u8 = null,
    /// Path to a file whose contents become the prompt (mutually exclusive with prompt).
    input_file: ?[]const u8 = null,
    /// Long-lived multi-turn mode (triggered by first positional `daemon`).
    /// In this mode the wrapper reads `{"type":"user",...}` JSONL frames from
    /// stdin instead of taking a prompt up front, and emits a `result`
    /// envelope after each turn's Stop hook.
    is_daemon: bool = false,
    output_format: OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    dangerously_skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    verbose: bool = false,
    timeout_seconds: u32 = 300,
    /// Daemon mode only: kill the session if no PTY output for this many
    /// seconds while busy. 0 disables. Default 180s.
    idle_timeout_seconds: u32 = 180,
    debug: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    // Explicit support for high-value claude flags (better ergonomics than
    // passthrough; some interact with claude semantics in subtle ways).
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    /// `--add-dir` may be repeated; we collect each value here in order.
    add_dirs: std.ArrayList([]const u8) = .{},
    /// `--mcp-config` may be repeated.
    mcp_configs: std.ArrayList([]const u8) = .{},
    /// `--extra-hook <Event>=<cmd>` may be repeated; parsed into {event,command}.
    extra_hooks: std.ArrayList(ExtraHook) = .{},
    /// `--setting-json <json>`: a JSON object whose top-level keys are merged
    /// into the generated settings (SPEC §2.9). Last occurrence wins.
    setting_json: ?[]const u8 = null,

    /// Arguments we don't recognize: passed through verbatim to `claude`.
    passthrough: std.ArrayList([]const u8) = .{},

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        // Strings come from the original argv slice (caller-owned), so we
        // only need to free the lists themselves.
        self.passthrough.deinit(allocator);
        self.add_dirs.deinit(allocator);
        self.mcp_configs.deinit(allocator);
        self.extra_hooks.deinit(allocator);
    }
};

/// Long flags that `claude` accepts but take NO value. The greedy passthrough
/// fallback below must NOT consume the next argv token for these — otherwise
/// `claude-p --bare "hello"` swallows "hello" as a flag value.
const known_boolean_long_flags = [_][]const u8{
    "--bare",
    "--brief",
    "--chrome",
    "--no-chrome",
    "--allow-dangerously-skip-permissions",
    "--dangerously-skip-permissions",
    "--disable-slash-commands",
    "--exclude-dynamic-system-prompt-sections",
    "--fork-session",
    "--ide",
    "--include-hook-events",
    "--include-partial-messages",
    "--mcp-debug",
    "--no-session-persistence",
    "--replay-user-messages",
    "--strict-mcp-config",
    "--tmux",
};

fn isKnownBoolean(flag: []const u8) bool {
    for (known_boolean_long_flags) |b| if (std.mem.eql(u8, b, flag)) return true;
    return false;
}

const help_text =
    \\Usage: claude-p [OPTIONS] [PROMPT]
    \\       claude-p daemon [OPTIONS]
    \\
    \\Default mode: one-shot. Emulates `claude -p` by driving the interactive
    \\`claude` binary inside an in-process zmux PTY and capturing the final
    \\assistant message via a Stop hook.
    \\
    \\Daemon mode (prepend `daemon` as the first arg): long-lived multi-turn
    \\wrapper. Reads `{"type":"user","message":{"role":"user","content":"..."}}`
    \\JSONL frames from stdin and emits transcript JSONL + one `result`
    \\envelope per turn to stdout — wire-compatible with
    \\`claude -p --input-format stream-json --output-format stream-json
    \\--verbose`.
    \\
    \\Options:
    \\  --output-format <fmt>           text | json | stream-json (default: text)
    \\  --model <name>                  Forwarded to `claude --model`
    \\  --fallback-model <name>         Forwarded to `claude --fallback-model`
    \\  --max-turns <N>                 Abort after N assistant turns
    \\  --allowedTools <list>           Permission-rule allow list
    \\  --disallowedTools <list>        Permission-rule deny list
    \\  --permission-mode <mode>        acceptEdits|auto|bypassPermissions|default|dontAsk|plan
    \\  --dangerously-skip-permissions  Bypass permission prompts
    \\  --system-prompt <text>          Override the default system prompt
    \\  --append-system-prompt <text>   Append to the default system prompt
    \\  --add-dir <dir>...              Additional allowed directories (repeatable, variadic)
    \\  --mcp-config <cfg>...           MCP server config files / JSON (repeatable, variadic)
    \\  --setting-sources <sources>     Comma-separated: user,project,local
    \\  --resume <id>                   Resume a session
    \\  --continue, -c                  Continue the most recent session
    \\  --session-id <uuid>             Use a specific session UUID
    \\  --cwd <path>                    Working directory for `claude`
    \\  --input-file <path>             Read prompt from a file
    \\  --verbose                       Verbose output
    \\  --timeout <seconds>             Wrapper wall-time cap (default: 300)
    \\  --idle-timeout <seconds>        Daemon-mode idle progress watchdog:
    \\                                  kill if no PTY output for this long
    \\                                  while busy. 0 disables. (default: 180)
    \\  --extra-hook <Event>=<cmd>      Merge an extra Claude hook into the
    \\                                  generated settings (repeatable). e.g.
    \\                                  --extra-hook PostToolUse=/path/track.sh
    \\  --setting-json <json>           Merge a JSON object's top-level keys into
    \\                                  the generated settings. e.g.
    \\                                  --setting-json '{"showThinkingSummaries":true}'
    \\  --debug                         Wrapper debug logs to stderr
    \\  --                              End of options; remaining tokens go to PROMPT
    \\  -h, --help                      Print this help
    \\  -v, --version                   Print version
    \\
    \\Unrecognized flags are forwarded verbatim to `claude`. The wrapper rejects
    \\`-p`/`--print` (we emulate it) and user-supplied `--settings` (we inject
    \\our own to register the Stop hook).
    \\
;

pub fn helpText() []const u8 {
    return help_text;
}

/// Parse argv (already stripped of argv[0]).
pub fn parse(allocator: std.mem.Allocator, argv_in: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    errdefer opts.deinit(allocator);

    // Subcommand: if the first positional token is `daemon`, drop into
    // long-lived multi-turn mode. All other flags are parsed normally;
    // prompt-related flags (positional / --input-file) are ignored by the
    // daemon entry point in main.zig.
    var argv: []const []const u8 = argv_in;
    if (argv_in.len > 0 and std.mem.eql(u8, argv_in[0], "daemon")) {
        opts.is_daemon = true;
        argv = argv_in[1..];
    }

    var seen_separator = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        // After `--`, every remaining token is positional. Claude itself
        // honors this; we mirror it so users can disambiguate prompts that
        // could otherwise be eaten by a preceding variadic flag.
        if (seen_separator) {
            if (opts.prompt == null) {
                opts.prompt = a;
                continue;
            } else {
                return ParseError.UnknownFlag;
            }
        }
        if (std.mem.eql(u8, a, "--")) {
            seen_separator = true;
            continue;
        }

        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, a, "--output-format")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.output_format = OutputFormat.fromString(argv[i]) orelse return ParseError.BadOutputFormat;
        } else if (std.mem.startsWith(u8, a, "--output-format=")) {
            opts.output_format = OutputFormat.fromString(a["--output-format=".len..]) orelse return ParseError.BadOutputFormat;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.model = argv[i];
        } else if (std.mem.startsWith(u8, a, "--model=")) {
            opts.model = a["--model=".len..];
        } else if (std.mem.eql(u8, a, "--max-turns")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.max_turns = std.fmt.parseInt(u32, argv[i], 10) catch return ParseError.BadInteger;
        } else if (std.mem.eql(u8, a, "--allowedTools") or std.mem.eql(u8, a, "--allowed-tools")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.allowed_tools = argv[i];
        } else if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) {
            opts.dangerously_skip_permissions = true;
        } else if (std.mem.eql(u8, a, "--resume")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.resume_session = argv[i];
        } else if (std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c")) {
            opts.cont = true;
        } else if (std.mem.eql(u8, a, "--session-id")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.session_id = argv[i];
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.cwd = argv[i];
        } else if (std.mem.eql(u8, a, "--input-file")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.input_file = argv[i];
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--debug")) {
            opts.debug = true;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.timeout_seconds = std.fmt.parseInt(u32, argv[i], 10) catch return ParseError.BadInteger;
        } else if (std.mem.eql(u8, a, "--idle-timeout")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.idle_timeout_seconds = std.fmt.parseInt(u32, argv[i], 10) catch return ParseError.BadInteger;
        } else if (std.mem.eql(u8, a, "--system-prompt")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.system_prompt = argv[i];
        } else if (std.mem.startsWith(u8, a, "--system-prompt=")) {
            opts.system_prompt = a["--system-prompt=".len..];
        } else if (std.mem.eql(u8, a, "--append-system-prompt")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.append_system_prompt = argv[i];
        } else if (std.mem.eql(u8, a, "--permission-mode")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.permission_mode = argv[i];
        } else if (std.mem.eql(u8, a, "--disallowedTools") or std.mem.eql(u8, a, "--disallowed-tools")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.disallowed_tools = argv[i];
        } else if (std.mem.eql(u8, a, "--fallback-model")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.fallback_model = argv[i];
        } else if (std.mem.eql(u8, a, "--setting-sources")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            opts.setting_sources = argv[i];
        } else if (std.mem.eql(u8, a, "--add-dir")) {
            i = try consumeVariadicInto(allocator, argv, i, &opts.add_dirs);
        } else if (std.mem.eql(u8, a, "--mcp-config")) {
            i = try consumeVariadicInto(allocator, argv, i, &opts.mcp_configs);
        } else if (std.mem.eql(u8, a, "--extra-hook")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            const h = hook.parseExtraHook(argv[i]) catch return ParseError.InvalidExtraHook;
            try opts.extra_hooks.append(allocator, h);
        } else if (std.mem.eql(u8, a, "--setting-json")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            // Validate up front: must be a JSON object (no silent drop).
            var probe = std.json.parseFromSlice(std.json.Value, allocator, argv[i], .{}) catch
                return ParseError.InvalidSettingJson;
            defer probe.deinit();
            if (probe.value != .object) return ParseError.InvalidSettingJson;
            opts.setting_json = argv[i];
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--print")) {
            // claude's print mode is what we *emulate*. Passing it through
            // would either no-op or fight with our hooks. Reject loudly.
            return ParseError.UnsupportedFlag;
        } else if (std.mem.eql(u8, a, "--settings")) {
            // We inject our own --settings with the SessionStart/Stop hooks.
            // Accepting a user --settings would clobber that and break the
            // completion signal.
            return ParseError.UnsupportedFlag;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Unknown long option — forward verbatim. For known boolean
            // flags, do NOT absorb the following arg (otherwise we steal
            // the user's prompt). For everything else, fall back to the
            // greedy rule (works for `--flag value` shaped flags).
            try opts.passthrough.append(allocator, a);
            if (!isKnownBoolean(a)) {
                if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                    i += 1;
                    try opts.passthrough.append(allocator, argv[i]);
                }
            }
        } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
            // Short flag — forward.
            try opts.passthrough.append(allocator, a);
        } else if (opts.prompt == null) {
            opts.prompt = a;
        } else {
            // Subsequent positionals: concat lazily by appending the second
            // (we expect only one positional).
            return ParseError.UnknownFlag;
        }
    }

    // Cross-flag validation. Mirror real claude's combination rules so
    // claude-p stays a true drop-in: claude itself errors with
    // "When using --print, --output-format=stream-json requires --verbose".
    // We always emulate --print, so the same rule applies. --help/--version
    // short-circuit before any work, so leave them alone. Daemon mode is
    // exempt — it sets stream-json internally and does not surface the flag
    // to the user.
    if (!opts.show_help and !opts.show_version and !opts.is_daemon) {
        if (opts.output_format == .stream_json and !opts.verbose) {
            return ParseError.StreamJsonRequiresVerbose;
        }
    }

    return opts;
}

/// Consume a variadic flag's value list (mirrors commander.js variadic
/// semantics: take every following non-flag token, until the next flag or
/// end of argv). Returns the new value of `i`. Errors if no value follows.
fn consumeVariadicInto(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    start: usize,
    out: *std.ArrayList([]const u8),
) ParseError!usize {
    var i = start + 1;
    if (i >= argv.len) return ParseError.MissingValue;
    try out.append(allocator, argv[i]);
    while (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
        i += 1;
        try out.append(allocator, argv[i]);
    }
    return i;
}

// -------- tests --------

const testing = std.testing;

test "parse: empty argv" {
    var opts = try parse(testing.allocator, &.{});
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), opts.prompt);
    try testing.expectEqual(OutputFormat.text, opts.output_format);
}

test "parse: positional prompt" {
    var opts = try parse(testing.allocator, &.{"hello world"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hello world", opts.prompt.?);
}

test "parse: --output-format json" {
    var opts = try parse(testing.allocator, &.{ "--output-format", "json", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.json, opts.output_format);
    try testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parse: --output-format=stream-json (with --verbose, which claude requires)" {
    var opts = try parse(testing.allocator, &.{ "--output-format=stream-json", "--verbose" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.stream_json, opts.output_format);
}

test "parse: bad output format" {
    try testing.expectError(ParseError.BadOutputFormat, parse(testing.allocator, &.{ "--output-format", "yaml" }));
}

test "parse: missing value after flag" {
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--model"}));
}

test "parse: --max-turns" {
    var opts = try parse(testing.allocator, &.{ "--max-turns", "7" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 7), opts.max_turns);
}

test "parse: bad integer" {
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--max-turns", "seven" }));
}

test "parse: --dangerously-skip-permissions" {
    var opts = try parse(testing.allocator, &.{"--dangerously-skip-permissions"});
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.dangerously_skip_permissions);
}

test "parse: --continue alias -c" {
    var opts1 = try parse(testing.allocator, &.{"--continue"});
    defer opts1.deinit(testing.allocator);
    try testing.expect(opts1.cont);
}

test "parse: unknown long flag is forwarded" {
    var opts = try parse(testing.allocator, &.{ "--frobnitz", "bar", "hello" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), opts.passthrough.items.len);
    try testing.expectEqualStrings("--frobnitz", opts.passthrough.items[0]);
    try testing.expectEqualStrings("bar", opts.passthrough.items[1]);
    try testing.expectEqualStrings("hello", opts.prompt.?);
}

test "parse: --help" {
    var opts = try parse(testing.allocator, &.{"--help"});
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.show_help);
}

test "parse: --version" {
    var opts = try parse(testing.allocator, &.{"-v"});
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.show_version);
}

test "parse: --timeout" {
    var opts = try parse(testing.allocator, &.{ "--timeout", "60", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 60), opts.timeout_seconds);
}

test "parse: --resume value" {
    var opts = try parse(testing.allocator, &.{ "--resume", "550e8400-e29b-41d4-a716-446655440000" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", opts.resume_session.?);
}

test "parse: --input-file" {
    var opts = try parse(testing.allocator, &.{ "--input-file", "/tmp/p.md" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/p.md", opts.input_file.?);
}

test "parse: known boolean passthrough flag does not consume next positional" {
    // Regression: greedy passthrough used to swallow the prompt when an
    // unknown long flag was actually a boolean (e.g. --bare "hi").
    var opts = try parse(testing.allocator, &.{ "--bare", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
    try testing.expectEqualStrings("--bare", opts.passthrough.items[0]);
}

test "parse: --strict-mcp-config is boolean" {
    var opts = try parse(testing.allocator, &.{ "--strict-mcp-config", "prompt-here" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("prompt-here", opts.prompt.?);
    try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
}

test "parse: --include-hook-events boolean before prompt" {
    var opts = try parse(testing.allocator, &.{ "--include-hook-events", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parse: variadic --add-dir consumes subsequent dir-shaped args" {
    // Matches claude's variadic semantics: --add-dir eats all subsequent
    // non-flag tokens. Put the prompt before --add-dir to avoid ambiguity.
    var opts = try parse(testing.allocator, &.{ "hello", "--add-dir", "/a", "/b", "/c" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", opts.prompt.?);
    try testing.expectEqual(@as(usize, 3), opts.add_dirs.items.len);
    try testing.expectEqualStrings("/a", opts.add_dirs.items[0]);
    try testing.expectEqualStrings("/b", opts.add_dirs.items[1]);
    try testing.expectEqualStrings("/c", opts.add_dirs.items[2]);
}

test "parse: -- separator forces remaining tokens into prompt slot" {
    // Variadic flags eat positionals greedily, matching claude. Use `--`
    // to terminate variadic absorption and unambiguously specify the prompt.
    var opts = try parse(testing.allocator, &.{ "--add-dir", "/a", "/b", "--", "what is this?" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("what is this?", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.add_dirs.items.len);
}

test "parse: --system-prompt is explicit" {
    var opts = try parse(testing.allocator, &.{ "--system-prompt", "You are helpful", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("You are helpful", opts.system_prompt.?);
    try testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parse: --append-system-prompt is explicit" {
    var opts = try parse(testing.allocator, &.{ "--append-system-prompt", "be terse", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("be terse", opts.append_system_prompt.?);
}

test "parse: --permission-mode is explicit" {
    var opts = try parse(testing.allocator, &.{ "--permission-mode", "acceptEdits", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("acceptEdits", opts.permission_mode.?);
}

test "parse: --disallowedTools is explicit" {
    var opts = try parse(testing.allocator, &.{ "--disallowedTools", "Bash Edit", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash Edit", opts.disallowed_tools.?);
}

test "parse: --add-dir aggregates across repeats" {
    // Put prompt first to avoid variadic absorption (mirrors real claude).
    var opts = try parse(testing.allocator, &.{ "hi", "--add-dir", "/a", "--add-dir", "/b" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.add_dirs.items.len);
    try testing.expectEqualStrings("/a", opts.add_dirs.items[0]);
    try testing.expectEqualStrings("/b", opts.add_dirs.items[1]);
}

test "parse: --fallback-model is explicit" {
    var opts = try parse(testing.allocator, &.{ "--fallback-model", "sonnet", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("sonnet", opts.fallback_model.?);
}

test "parse: rejects --print (claude print mode is unavailable here)" {
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "-p", "hi" }));
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "--print", "hi" }));
}

test "parse: rejects user --settings (conflicts with our hook injection)" {
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "--settings", "{}" }));
}

test "parse: --extra-hook accumulates parsed event/command (repeatable)" {
    var opts = try parse(testing.allocator, &.{
        "--extra-hook", "PostToolUse=/x/track.sh",
        "--extra-hook", "Stop=/x/also.sh",
        "hi",
    });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), opts.extra_hooks.items.len);
    try testing.expectEqualStrings("PostToolUse", opts.extra_hooks.items[0].event);
    try testing.expectEqualStrings("/x/track.sh", opts.extra_hooks.items[0].command);
    try testing.expectEqualStrings("Stop", opts.extra_hooks.items[1].event);
}

test "parse: --extra-hook with no value errors" {
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--extra-hook"}));
}

test "parse: --extra-hook malformed (no '=') errors" {
    try testing.expectError(ParseError.InvalidExtraHook, parse(testing.allocator, &.{ "--extra-hook", "PostToolUse" }));
}

test "parse: --setting-json accepts a JSON object" {
    var opts = try parse(testing.allocator, &.{ "--setting-json", "{\"showThinkingSummaries\":true}", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"showThinkingSummaries\":true}", opts.setting_json.?);
}

test "parse: --setting-json rejects non-object / invalid JSON" {
    try testing.expectError(ParseError.InvalidSettingJson, parse(testing.allocator, &.{ "--setting-json", "[1,2,3]" }));
    try testing.expectError(ParseError.InvalidSettingJson, parse(testing.allocator, &.{ "--setting-json", "not json" }));
}

test "parse: --setting-json with no value errors" {
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--setting-json"}));
}

test "parse: stream-json without --verbose is rejected (matches claude -p)" {
    // claude itself errors: "When using --print, --output-format=stream-json
    // requires --verbose". We emulate --print so the same rule applies.
    try testing.expectError(
        ParseError.StreamJsonRequiresVerbose,
        parse(testing.allocator, &.{ "--output-format", "stream-json", "hi" }),
    );
}

test "parse: stream-json with --verbose is accepted" {
    var opts = try parse(testing.allocator, &.{ "--output-format", "stream-json", "--verbose", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.stream_json, opts.output_format);
    try testing.expect(opts.verbose);
}

test "parse: --output-format=stream-json (eq form) also requires --verbose" {
    try testing.expectError(
        ParseError.StreamJsonRequiresVerbose,
        parse(testing.allocator, &.{ "--output-format=stream-json", "hi" }),
    );
}

test "parse: stream-json + --help skips the verbose check" {
    // --help short-circuits before the validation kicks in — otherwise
    // `claude-p --help --output-format stream-json` would error confusingly.
    var opts = try parse(testing.allocator, &.{ "--output-format", "stream-json", "--help" });
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.show_help);
}
