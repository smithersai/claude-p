//! CLI argument parser. Mirrors a useful subset of `claude -p`'s surface
//! and forwards unknown flags through to the child `claude` invocation.
const std = @import("std");
const hook_mod = @import("hook.zig");

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
    /// `--extra-hook` value is not `<Event>=<cmd>` with both sides non-empty.
    BadExtraHook,
    OutOfMemory,
};

/// Parsed CLI options for both one-shot and persistent daemon invocations.
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
    /// True when argv carried `--output-format`. Daemon mode always speaks
    /// stream-json, so an explicit `text`/`json` there is rejected.
    output_format_explicit: bool = false,
    model: ?[]const u8 = null,
    /// Never set by `parse`: `--max-turns` is rejected (print-mode-only).
    /// Kept so library callers and `driver.Options` keep their shape.
    max_turns: ?u32 = null,
    /// Never set by `parse`: `--allowedTools` rules are repeatable and
    /// variadic, so each one is forwarded through `passthrough` as an
    /// `--allowedTools <rule>` pair.
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
    /// Daemon mode only: kill the session if the transcript JSONL stops
    /// growing for this many seconds while busy. 0 disables. Default 600s.
    transcript_idle_timeout_seconds: u32 = 600,
    debug: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    // Explicit support for high-value claude flags (better ergonomics than
    // passthrough; some interact with claude semantics in subtle ways).
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    /// Never set by `parse`; see `allowed_tools`.
    disallowed_tools: ?[]const u8 = null,
    /// Never set by `parse`: `--fallback-model` is rejected (print-mode-only).
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    /// `--add-dir` may be repeated; we collect each value here in order.
    add_dirs: std.ArrayList([]const u8) = .{},
    /// `--mcp-config` may be repeated.
    mcp_configs: std.ArrayList([]const u8) = .{},
    /// `--extra-hook <Event>=<cmd>` may be repeated. Strings borrow from argv.
    extra_hooks: std.ArrayList(hook_mod.ExtraHook) = .{},
    /// `--setting-json <json>`: a JSON object merged into the generated
    /// `--settings` JSON (validated by the hook module).
    extra_settings_json: ?[]const u8 = null,

    /// Arguments forwarded to `claude`: flags we don't recognize (verbatim),
    /// `-n`/`--name` with its value, and one `--allowedTools <rule>` or
    /// `--disallowedTools <rule>` pair per tool rule.
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
///
/// `--bare` and `--safe-mode` are listed for completeness, but `parse`
/// rejects them before this table is consulted.
pub const known_boolean_long_flags = [_][]const u8{
    "--allow-dangerously-skip-permissions",
    "--ax-screen-reader",
    "--background",
    "--bare",
    "--bg",
    "--brief",
    "--chrome",
    "--no-chrome",
    "--dangerously-skip-permissions",
    "--desktop",
    "--disable-slash-commands",
    "--exclude-dynamic-system-prompt-sections",
    "--fork-session",
    "--ide",
    "--include-hook-events",
    "--mcp-debug",
    "--restricted",
    "--safe-mode",
    "--strict-mcp-config",
    "--tmux",
};

fn isKnownBoolean(flag: []const u8) bool {
    for (known_boolean_long_flags) |b| if (std.mem.eql(u8, b, flag)) return true;
    return false;
}

/// Flags `parse` refuses, in the bare form and in every `<flag>=<value>`
/// form (commander accepts both spellings, so both must be refused):
///   * `-p` / `--print`: claude-p emulates print mode; forwarding it would
///     fight the PTY driver.
///   * `--settings`: claude-p injects its own `--settings` carrying the
///     SessionStart/Stop hooks; a user copy would clobber them.
///   * `--bare` / `--safe-mode`: Claude Code 2.1.330 skips `--settings`
///     hooks under them, so the SessionStart/Stop relay would never fire.
///   * `--no-session-persistence`: stops claude writing the transcript JSONL
///     that claude-p reads the result from.
///   * `--input-format`, `--json-schema`, `--max-budget-usd`: print-mode-only
///     in claude; the interactive session ignores them, so forwarding would
///     silently drop the requested behavior.
///   * `--max-turns`, `--fallback-model`, `--include-partial-messages`,
///     `--forward-subagent-text`, `--replay-user-messages`,
///     `--verbose-thinking`: also print-mode-only. claude-p neither enforces
///     a turn cap or model fallback nor emits partial, subagent, replayed, or
///     thinking stream events, so accepting them would promise behavior that
///     never happens.
pub const rejected_flags = [_][]const u8{
    "-p",
    "--print",
    "--settings",
    "--bare",
    "--safe-mode",
    "--no-session-persistence",
    "--input-format",
    "--json-schema",
    "--max-budget-usd",
    "--max-turns",
    "--fallback-model",
    "--include-partial-messages",
    "--forward-subagent-text",
    "--replay-user-messages",
    "--verbose-thinking",
};

fn isRejectedFlag(flag: []const u8) bool {
    const name = std.mem.sliceTo(flag, '=');
    if (name.len > 2 and name[0] == '-' and name[1] != '-' and std.mem.indexOfScalar(u8, name[1..], 'p') != null) return true;
    return matchFlag(flag, rejected_flags) != null;
}

/// Parse `<Event>=<cmd>`. Splits on the first `=` so commands may contain `=`.
fn parseExtraHook(value: []const u8) ParseError!hook_mod.ExtraHook {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return ParseError.BadExtraHook;
    const event = value[0..eq];
    const command = value[eq + 1 ..];
    if (event.len == 0 or command.len == 0) return ParseError.BadExtraHook;
    return .{ .event = event, .command = command };
}

fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch ParseError.BadInteger;
}

const help_text =
    \\Usage: claude-p [OPTIONS] [PROMPT]
    \\       claude-p daemon [OPTIONS]
    \\
    \\Default mode: one-shot. Emulates `claude -p` by driving the interactive
    \\`claude` binary inside an in-process zmux PTY and capturing the final
    \\assistant message via a Stop hook.
    \\
    \\Prompt sources: PROMPT, --input-file <path> (not both), or piped stdin.
    \\With PROMPT and piped stdin, the prompt sent is `<stdin>\n\n<PROMPT>`.
    \\Without PROMPT or --input-file, stdin must be piped (a TTY is an error).
    \\
    \\Daemon mode (prepend `daemon` as the first arg): long-lived multi-turn
    \\wrapper. Reads `{"type":"user","message":{"role":"user","content":"..."}}`
    \\JSONL frames from stdin. Per turn it writes to stdout
    \\session-transcript JSONL events plus a claude -p-shaped result envelope
    \\(event lines use Claude Code transcript schema, not full native
    \\claude -p stream-json wire parity).
    \\Daemon mode rejects PROMPT and --input-file. Its output is always
    \\stream-json, so it also rejects --output-format text and json.
    \\
    \\Options (every <value> option also accepts --option=<value>):
    \\  --output-format <fmt>           text | json | stream-json (default: text).
    \\                                  stream-json needs --verbose and emits
    \\                                  session-transcript JSONL events plus a
    \\                                  claude -p-shaped result envelope
    \\  --model <name>                  Forwarded to `claude --model`
    \\  --allowedTools <rule>...        Permission-rule allow list (repeatable,
    \\                                  variadic; alias --allowed-tools;
    \\                                  --allowedTools=<rule> takes one)
    \\  --disallowedTools <rule>...     Permission-rule deny list (repeatable,
    \\                                  variadic; alias --disallowed-tools)
    \\  --permission-mode <mode>        acceptEdits|auto|bypassPermissions|manual|default|dontAsk|plan
    \\  --dangerously-skip-permissions  Bypass permission prompts
    \\  --system-prompt <text>          Override the default system prompt
    \\  --append-system-prompt <text>   Append to the default system prompt
    \\  --add-dir <dir>...              Additional allowed directories (repeatable,
    \\                                  variadic; use --add-dir=<dir> for a dir
    \\                                  starting with `-`)
    \\                                  A variadic flag takes every following
    \\                                  token up to the next flag or `--`: put
    \\                                  PROMPT first or after `--`
    \\  --mcp-config <cfg>...           MCP server config files / JSON (repeatable,
    \\                                  variadic; --mcp-config=<cfg> takes one)
    \\  --setting-sources <sources>     Comma-separated: user,project,local
    \\  --resume, -r <id>               Resume a session
    \\  --continue, -c                  Continue the most recent session
    \\  --session-id <uuid>             Use a specific session UUID
    \\  --name, -n <name>               Session display name; forwarded to `claude`
    \\  --cwd <path>                    Working directory for `claude`
    \\  --input-file <path>             Read prompt from a file
    \\  --verbose                       Verbose output
    \\  --timeout <seconds>             One-shot: wall-time cap for the whole run.
    \\                                  Daemon: cap on the initial SessionStart
    \\                                  wait only. 0 disables. (default: 300)
    \\  --idle-timeout <seconds>        Daemon-mode idle progress watchdog:
    \\                                  kill if no PTY output for this long
    \\                                  while busy. 0 disables. (default: 180)
    \\  --transcript-idle-timeout <seconds>
    \\                                  Daemon: abort if the transcript stops growing.
    \\                                  One-shot: abort if transcript and PTY activity stop
    \\                                  for this long while busy. 0 disables.
    \\                                  (default: 600)
    \\  --extra-hook <Event>=<cmd>      Add a hook command to the generated
    \\                                  settings (repeatable)
    \\  --setting-json <json>           JSON object merged into the generated
    \\                                  settings (`hooks` key excluded)
    \\  --debug                         Wrapper debug logs to stderr
    \\  --                              End of options; remaining tokens go to PROMPT
    \\  -h, --help                      Print this help
    \\  -v, --version                   Print version
    \\
    \\Unrecognized flags are forwarded verbatim to `claude`. The wrapper rejects,
    \\including their `<flag>=<value>` forms:
    \\  `-p`/`--print`                  claude-p emulates print mode itself
    \\  `--settings`                    claude-p injects its own to register the
    \\                                  Stop hook; use --extra-hook/--setting-json
    \\  `--bare`/`--safe-mode`          Claude Code skips `--settings` hooks
    \\  `--no-session-persistence`      claude-p reads the session transcript
    \\  `--input-format`, `--json-schema`, `--max-budget-usd`
    \\                                  print-mode-only; the interactive session
    \\                                  would silently ignore them
    \\  `--max-turns`, `--fallback-model`, `--include-partial-messages`,
    \\  `--forward-subagent-text`, `--replay-user-messages`, `--verbose-thinking`
    \\                                  print-mode-only; claude-p does not enforce
    \\                                  or emit them
    \\
;

/// Return the static `--help` usage text for `claude-p`.
pub fn helpText() []const u8 {
    return help_text;
}

/// Every wrapper-owned flag that takes exactly one value. Each accepts both
/// `<name> <value>` (the next token, consumed unconditionally, as commander
/// does for required option values) and `<name>=<value>`.
const ValueFlag = enum {
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

const value_flag_table = [_]struct { name: []const u8, flag: ValueFlag }{
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

const FlagMatch = struct {
    /// Index into the flag's table.
    index: usize,
    /// Set for the `<name>=<value>` spelling.
    inline_value: ?[]const u8,
};

/// Match `a` against `names` as `<name>` or `<name>=<value>`.
fn matchFlag(a: []const u8, names: anytype) ?FlagMatch {
    for (names, 0..) |n, idx| {
        const name: []const u8 = if (@TypeOf(n) == []const u8) n else n.name;
        if (std.mem.eql(u8, a, name)) return .{ .index = idx, .inline_value = null };
        if (a.len > name.len and std.mem.startsWith(u8, a, name) and a[name.len] == '=')
            return .{ .index = idx, .inline_value = a[name.len + 1 ..] };
    }
    return null;
}

const variadic_flags = [_][]const u8{ "--add-dir", "--mcp-config" };

/// Spelling `parse` forwards for every allow rule, whichever alias was used.
pub const allowed_tools_flag: []const u8 = "--allowedTools";
/// Spelling `parse` forwards for every deny rule, whichever alias was used.
pub const disallowed_tools_flag: []const u8 = "--disallowedTools";

/// Tool-rule flags: variadic and repeatable like `--add-dir`. Every rule is
/// forwarded as its own `<canonical> <rule>` pair in `passthrough`, so
/// repeats accumulate and a variadic run never reaches claude's own variadic
/// parser as one ambiguous list.
const tool_rule_flags = [_]struct { name: []const u8, canonical: []const u8 }{
    .{ .name = "--allowedTools", .canonical = allowed_tools_flag },
    .{ .name = "--allowed-tools", .canonical = allowed_tools_flag },
    .{ .name = "--disallowedTools", .canonical = disallowed_tools_flag },
    .{ .name = "--disallowed-tools", .canonical = disallowed_tools_flag },
};

/// Flags claude-p does not interpret but that take exactly one value in
/// `claude`. The value is consumed unconditionally (commander's rule for a
/// required option value) and forwarded with the flag, so it is never
/// mistaken for PROMPT. `--name=<v>` and `-n<v>` are single tokens and
/// forward verbatim through the generic branches.
///
/// Upstream's other short options need no entry: `-c`, `-h`, `-v`, `-r`
/// are handled above, `-p` is rejected, and `-d [filter]` / `-w [name]`
/// take an optional value, so a following token stays positional.
pub const forwarded_value_flags = [_][]const u8{ "-n", "--name" };

fn isForwardedValueFlag(a: []const u8) bool {
    for (forwarded_value_flags) |f| if (std.mem.eql(u8, a, f)) return true;
    return false;
}

fn applyValue(allocator: std.mem.Allocator, opts: *Options, flag: ValueFlag, v: []const u8) ParseError!void {
    switch (flag) {
        .output_format => {
            opts.output_format = OutputFormat.fromString(v) orelse return ParseError.BadOutputFormat;
            opts.output_format_explicit = true;
        },
        .model => opts.model = v,
        .permission_mode => opts.permission_mode = v,
        .system_prompt => opts.system_prompt = v,
        .append_system_prompt => opts.append_system_prompt = v,
        .setting_sources => opts.setting_sources = v,
        .resume_session => opts.resume_session = v,
        .session_id => opts.session_id = v,
        .cwd => opts.cwd = v,
        .input_file => opts.input_file = v,
        .timeout => opts.timeout_seconds = try parseU32(v),
        .idle_timeout => opts.idle_timeout_seconds = try parseU32(v),
        .transcript_idle_timeout => opts.transcript_idle_timeout_seconds = try parseU32(v),
        .extra_hook => try opts.extra_hooks.append(allocator, try parseExtraHook(v)),
        .setting_json => opts.extra_settings_json = v,
    }
}

/// Where a failed parse stopped, for error messages.
pub const ParseDiag = struct {
    /// The argv token the error is about: the bad value for `BadInteger`,
    /// `BadOutputFormat`, and `BadExtraHook`; the flag for `MissingValue`
    /// and flag errors. Surplus positional arguments are private and omitted.
    offending: ?[]const u8 = null,
};

fn fail(diag: *ParseDiag, token: []const u8, err: ParseError) ParseError {
    diag.offending = switch (err) {
        ParseError.UnsupportedFlag, ParseError.UnknownFlag => std.mem.sliceTo(token, '='),
        else => token,
    };
    return err;
}

/// Parse argv (already stripped of argv[0]).
pub fn parse(allocator: std.mem.Allocator, argv_in: []const []const u8) ParseError!Options {
    return parseWithDiag(allocator, argv_in, null);
}

/// `parse`, also recording the offending token in `diag_out` on error.
pub fn parseWithDiag(
    allocator: std.mem.Allocator,
    argv_in: []const []const u8,
    diag_out: ?*ParseDiag,
) ParseError!Options {
    var scratch: ParseDiag = .{};
    const diag = diag_out orelse &scratch;
    diag.* = .{};

    var opts: Options = .{};
    errdefer opts.deinit(allocator);

    // Subcommand: if the first token is `daemon`, drop into long-lived
    // multi-turn mode. The daemon takes its prompts from stdin frames, so a
    // positional prompt or `--input-file` is rejected after the loop.
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
        } else if (std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c")) {
            opts.cont = true;
        } else if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) {
            opts.dangerously_skip_permissions = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--debug")) {
            opts.debug = true;
        } else if (matchFlag(a, value_flag_table)) |m| {
            const v = m.inline_value orelse blk: {
                i += 1;
                if (i >= argv.len) return fail(diag, a, ParseError.MissingValue);
                break :blk argv[i];
            };
            applyValue(allocator, &opts, value_flag_table[m.index].flag, v) catch |err| {
                if (err != ParseError.OutOfMemory) diag.offending = v;
                return err;
            };
        } else if (matchFlag(a, variadic_flags)) |m| {
            const out = if (m.index == 0) &opts.add_dirs else &opts.mcp_configs;
            if (m.inline_value) |v| {
                // commander: `--add-dir=<v>` takes exactly one value and
                // does not open a variadic run.
                try out.append(allocator, v);
            } else {
                i = consumeVariadicInto(allocator, argv, i, out, null) catch |err| {
                    if (err != ParseError.OutOfMemory) diag.offending = a;
                    return err;
                };
            }
        } else if (matchFlag(a, tool_rule_flags)) |m| {
            const canonical = tool_rule_flags[m.index].canonical;
            if (m.inline_value) |v| {
                try opts.passthrough.append(allocator, canonical);
                try opts.passthrough.append(allocator, v);
            } else {
                i = consumeVariadicInto(allocator, argv, i, &opts.passthrough, canonical) catch |err| {
                    if (err != ParseError.OutOfMemory) diag.offending = a;
                    return err;
                };
            }
        } else if (isRejectedFlag(a)) {
            // See `isRejectedFlag`. Reject loudly rather than forward a flag
            // that disables or fights the hook-based completion signal.
            return fail(diag, a, ParseError.UnsupportedFlag);
        } else if (isForwardedValueFlag(a)) {
            // See `forwarded_value_flags`: the value is never the prompt.
            if (i + 1 >= argv.len) return fail(diag, a, ParseError.MissingValue);
            try opts.passthrough.append(allocator, a);
            i += 1;
            try opts.passthrough.append(allocator, argv[i]);
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Unknown long option: forward verbatim. A `--flag=value` token
            // carries its own value, and known boolean flags take none; in
            // both cases the next token stays where it is (it may be the
            // prompt). Anything else greedily takes one following non-dash
            // token (works for `--flag value` shaped flags).
            try opts.passthrough.append(allocator, a);
            const has_inline_value = std.mem.indexOfScalar(u8, a, '=') != null;
            if (!has_inline_value and !isKnownBoolean(a)) {
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
            // A second positional: we accept exactly one prompt.
            return ParseError.UnknownFlag;
        }
    }

    if (opts.is_daemon and (opts.prompt != null or opts.input_file != null)) {
        // Daemon prompts arrive as stdin frames; silently ignoring an
        // up-front prompt would drop the user's input.
        if (opts.input_file != null) return fail(diag, "--input-file", ParseError.UnknownFlag);
        return ParseError.UnknownFlag;
    }
    if (opts.is_daemon and opts.output_format_explicit and opts.output_format != .stream_json) {
        // The daemon always writes stream-json; accepting `text`/`json`
        // would silently hand the caller a format it did not ask for.
        return fail(diag, "--output-format", ParseError.UnsupportedFlag);
    }

    // Match Claude's print-mode combination rule. Claude errors with
    // "When using --print, --output-format=stream-json requires --verbose".
    // We always emulate --print, so the same rule applies. --help/--version
    // short-circuit before any work, so leave them alone. Daemon mode is
    // exempt: its output is always stream-json.
    if (!opts.show_help and !opts.show_version and !opts.is_daemon) {
        if (opts.output_format == .stream_json and !opts.verbose) {
            return fail(diag, "stream-json", ParseError.StreamJsonRequiresVerbose);
        }
    }

    return opts;
}

/// Consume a variadic flag's value list (mirrors commander.js variadic
/// semantics: take every following non-flag token, until the next flag or
/// end of argv). Returns the new value of `i`. Errors with `MissingValue`
/// when no value follows or the next token starts with `-` (including
/// `--`): a dash-led first value is almost always a forgotten argument, and
/// swallowing `--` would turn the prompt after it into a directory. Use
/// `--add-dir=<path>` for a path that really starts with `-`.
///
/// With `pair_flag` set, each value is appended as `<pair_flag> <value>`.
fn consumeVariadicInto(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    start: usize,
    out: *std.ArrayList([]const u8),
    pair_flag: ?[]const u8,
) ParseError!usize {
    var i = start + 1;
    if (i >= argv.len or std.mem.startsWith(u8, argv[i], "-")) return ParseError.MissingValue;
    while (true) {
        if (pair_flag) |f| try out.append(allocator, f);
        try out.append(allocator, argv[i]);
        if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "-")) return i;
        i += 1;
    }
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

test "parse: bad integer" {
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--timeout", "seven" }));
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
    // unknown long flag was actually a boolean (e.g. --brief "hi").
    var opts = try parse(testing.allocator, &.{ "--brief", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
    try testing.expectEqualStrings("--brief", opts.passthrough.items[0]);
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

fn expectPassthrough(opts: *const Options, want: []const []const u8) !void {
    try testing.expectEqual(want.len, opts.passthrough.items.len);
    for (want, opts.passthrough.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "parse: repeated tool-rule flags keep every rule" {
    // Regression (H12): a scalar field kept only the last rule.
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

test "parse: variadic tool rules stop at `--`, and the prompt follows it" {
    // Regression (H12): `Edit` was taken as the prompt and `--` then failed.
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
    // `--flag=<rule>` takes exactly one rule, so `hi` stays the prompt.
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expect(opts.verbose);
    try expectPassthrough(&opts, &.{
        "--allowedTools",    "Bash(git *)",
        "--disallowedTools", "Bash Edit",
        "--allowedTools",    "-weird",
    });
}

test "parse: tool rules follow the --add-dir variadic rule" {
    // Without `--`, a trailing token is one more rule, as in claude itself.
    var a = try parse(testing.allocator, &.{ "--disallowedTools", "Bash", "--disallowedTools", "Edit", "hello" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), a.prompt);
    try expectPassthrough(&a, &.{
        "--disallowedTools", "Bash", "--disallowedTools", "Edit", "--disallowedTools", "hello",
    });

    // No prompt at all: it arrives on piped stdin.
    var b = try parse(testing.allocator, &.{ "--disallowedTools", "Bash" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), b.prompt);
    try expectPassthrough(&b, &.{ "--disallowedTools", "Bash" });

    // Daemon mode forwards rules the same way.
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
    // Regression (M34): `-n` was forwarded alone and its value became PROMPT.
    var a = try parse(testing.allocator, &.{ "-n", "sample-session", "--", "hello" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", a.prompt.?);
    try expectPassthrough(&a, &.{ "-n", "sample-session" });

    var b = try parse(testing.allocator, &.{ "-n", "sample-session", "hello" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", b.prompt.?);
    try expectPassthrough(&b, &.{ "-n", "sample-session" });

    // No prompt: it arrives on piped stdin.
    var c = try parse(testing.allocator, &.{ "-n", "sample-session" });
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), c.prompt);
    try expectPassthrough(&c, &.{ "-n", "sample-session" });

    // The value is consumed unconditionally, dash-led or not.
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
    // H11/M5: claude-p never enforced these, so accepting them lied.
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
        try testing.expect(!isKnownBoolean(n));
    }
}

test "parse: daemon mode rejects --output-format text and json" {
    // M20: the daemon always writes stream-json.
    const bad = [_][]const []const u8{
        &.{ "daemon", "--output-format", "json" },
        &.{ "daemon", "--output-format=text" },
        &.{ "daemon", "--output-format", "stream-json", "--output-format", "json" },
    };
    for (bad) |argv| try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, argv));

    var a = try parse(testing.allocator, &.{ "daemon", "--output-format", "stream-json" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(OutputFormat.stream_json, a.output_format);
    // The last one wins, as in one-shot mode.
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
    // Success clears a stale diagnostic.
    var diag: ParseDiag = .{ .offending = "stale" };
    var ok = try parseWithDiag(testing.allocator, &.{"hi"}, &diag);
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), diag.offending);
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

test "parse: rejects --print (claude print mode is unavailable here)" {
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "-p", "hi" }));
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "--print", "hi" }));
}

test "parse: rejects user --settings (conflicts with our hook injection)" {
    try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "--settings", "{}" }));
}

test "parse: rejects the =value spellings of -p, --print, and --settings" {
    // Regression: `--settings={}` fell through to the unknown-long-flag
    // branch and was forwarded to claude, clobbering the injected hooks.
    const bad = [_][]const []const u8{
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
    // After `--` they are a prompt, and lookalikes still forward.
    var a = try parse(testing.allocator, &.{ "--", "--settings={}" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("--settings={}", a.prompt.?);
    var b = try parse(testing.allocator, &.{ "--settingsx=1", "--printer" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), b.passthrough.items.len);
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

test "parse: Claude Code 2.1.330 boolean flags do not consume the prompt" {
    const flags = [_][]const u8{
        "--ax-screen-reader",
        "--bg",
        "--background",
        "--desktop",
        "--restricted",
    };
    for (flags) |flag| {
        var opts = try parse(testing.allocator, &.{ flag, "the prompt" });
        defer opts.deinit(testing.allocator);
        try testing.expectEqualStrings("the prompt", opts.prompt.?);
        try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
        try testing.expectEqualStrings(flag, opts.passthrough.items[0]);
    }
}

test "parse: rejects --bare and --safe-mode (they suppress --settings hooks)" {
    const bad = [_][]const []const u8{
        &.{ "--bare", "hi" },
        &.{ "hi", "--bare" },
        &.{"--bare=true"},
        &.{ "--safe-mode", "hi" },
        &.{"--safe-mode=1"},
        &.{ "daemon", "--bare" },
        &.{ "daemon", "--safe-mode" },
    };
    for (bad) |argv| {
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, argv));
    }
}

test "parse: lookalike flags are not mistaken for --bare/--safe-mode" {
    var opts = try parse(testing.allocator, &.{ "--bareword", "x", "hi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", opts.prompt.?);
    try testing.expectEqual(@as(usize, 2), opts.passthrough.items.len);
}

test "parse: --transcript-idle-timeout defaults to 600" {
    var opts = try parse(testing.allocator, &.{"hi"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 600), opts.transcript_idle_timeout_seconds);
}

test "parse: --transcript-idle-timeout space and = forms, including 0" {
    var a = try parse(testing.allocator, &.{ "--transcript-idle-timeout", "45", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 45), a.transcript_idle_timeout_seconds);
    try testing.expectEqualStrings("hi", a.prompt.?);

    var b = try parse(testing.allocator, &.{ "--transcript-idle-timeout=0", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), b.transcript_idle_timeout_seconds);

    var c = try parse(testing.allocator, &.{ "daemon", "--transcript-idle-timeout", "0" });
    defer c.deinit(testing.allocator);
    try testing.expect(c.is_daemon);
    try testing.expectEqual(@as(u32, 0), c.transcript_idle_timeout_seconds);
}

test "parse: --transcript-idle-timeout rejects bad and missing values" {
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--transcript-idle-timeout", "ten" }));
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{ "--transcript-idle-timeout", "-1" }));
    try testing.expectError(ParseError.BadInteger, parse(testing.allocator, &.{"--transcript-idle-timeout="}));
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--transcript-idle-timeout"}));
}

test "parse: --extra-hook is repeatable and splits on the first =" {
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
    try testing.expectEqual(@as(usize, 0), opts.passthrough.items.len);
}

test "parse: malformed --extra-hook values are rejected" {
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "PreToolUse" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "=echo hi" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{ "--extra-hook", "Stop=" }));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{"--extra-hook=Stop"}));
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{"--extra-hook=="}));
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--extra-hook"}));
    // A valid hook followed by a malformed one must not leak the first.
    try testing.expectError(ParseError.BadExtraHook, parse(testing.allocator, &.{
        "--extra-hook", "Stop=echo ok", "--extra-hook", "nope",
    }));
}

test "parse: --setting-json space and = forms" {
    var a = try parse(testing.allocator, &.{ "--setting-json", "{\"env\":{\"A\":\"1\"}}", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\"}}", a.extra_settings_json.?);
    try testing.expectEqualStrings("hi", a.prompt.?);

    var b = try parse(testing.allocator, &.{ "--setting-json={\"model\":\"x\"}", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"model\":\"x\"}", b.extra_settings_json.?);
    try testing.expectEqual(@as(usize, 0), b.passthrough.items.len);

    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"--setting-json"}));
}

test "parse: --permission-mode manual and default" {
    var a = try parse(testing.allocator, &.{ "--permission-mode", "manual", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("manual", a.permission_mode.?);
    try testing.expectEqualStrings("hi", a.prompt.?);

    var b = try parse(testing.allocator, &.{ "--permission-mode", "default", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("default", b.permission_mode.?);
}

test "helpText documents the 2.1.330 surface" {
    const h = helpText();
    const needles = [_][]const u8{
        "acceptEdits|auto|bypassPermissions|manual|default|dontAsk|plan",
        "--transcript-idle-timeout <seconds>",
        "(default: 600)",
        "--extra-hook <Event>=<cmd>",
        "--setting-json <json>",
        "`--bare`/`--safe-mode`",
    };
    for (needles) |n| try testing.expect(std.mem.indexOf(u8, h, n) != null);
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

test "parse: -r is a short alias for --resume" {
    var a = try parse(testing.allocator, &.{ "-r", "sid", "hi" });
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("sid", a.resume_session.?);
    try testing.expectEqualStrings("hi", a.prompt.?);
    var b = try parse(testing.allocator, &.{ "-r=sid", "hi" });
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("sid", b.resume_session.?);
    try testing.expectEqual(@as(usize, 0), b.passthrough.items.len);
    try testing.expectError(ParseError.MissingValue, parse(testing.allocator, &.{"-r"}));
}

test "parse: unknown --flag=value never absorbs the next token" {
    var opts = try parse(testing.allocator, &.{ "--foo=bar", "summarize this" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("summarize this", opts.prompt.?);
    try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
    try testing.expectEqualStrings("--foo=bar", opts.passthrough.items[0]);
}

test "parse: variadic flags refuse a dash-led first value; = form takes one" {
    const bad = [_][]const []const u8{
        &.{ "--add-dir", "--", "hi" },
        &.{ "--add-dir", "--verbose" },
        &.{ "--mcp-config", "-x" },
        &.{ "--mcp-config", "--", "hi" },
        &.{ "hi", "--add-dir", "-" },
    };
    for (bad) |argv| try testing.expectError(ParseError.MissingValue, parse(testing.allocator, argv));

    var opts = try parse(testing.allocator, &.{ "--add-dir=-weird", "--mcp-config=--cfg", "/a", "--add-dir=" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), opts.add_dirs.items.len);
    try testing.expectEqualStrings("-weird", opts.add_dirs.items[0]);
    try testing.expectEqualStrings("", opts.add_dirs.items[1]);
    try testing.expectEqual(@as(usize, 1), opts.mcp_configs.items.len);
    try testing.expectEqualStrings("--cfg", opts.mcp_configs.items[0]);
    // `--mcp-config=<v>` does not open a variadic run: `/a` is the prompt.
    try testing.expectEqualStrings("/a", opts.prompt.?);
}

test "parse: rejects print-only flags that the interactive session ignores" {
    const names = [_][]const u8{ "--no-session-persistence", "--input-format", "--json-schema", "--max-budget-usd" };
    for (names) |n| {
        var buf: [64]u8 = undefined;
        const eq = try std.fmt.bufPrint(&buf, "{s}=1", .{n});
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ n, "hi" }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "hi", eq }));
        try testing.expectError(ParseError.UnsupportedFlag, parse(testing.allocator, &.{ "daemon", n }));
        try testing.expect(!isKnownBoolean(n));
    }
}

test "parse: daemon mode rejects a positional prompt and --input-file" {
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "hello" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--", "hello" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--input-file", "/tmp/p" }));
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, &.{ "daemon", "--input-file=/tmp/p" }));
    var ok = try parse(testing.allocator, &.{ "daemon", "--model", "opus" });
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.is_daemon);
}

test "helpText documents rejected flags, -r, = forms, and timeout semantics" {
    const h = helpText();
    const needles = [_][]const u8{
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
    // H2: no claim of native stream-json wire parity, and no advertised
    // option row for a rejected flag.
    for ([_][]const u8{ "wire-compatible", "--max-turns <N>", "--fallback-model <name>" }) |absent| {
        try testing.expect(std.mem.indexOf(u8, h, absent) == null);
    }
    for (needles) |n| try testing.expect(std.mem.indexOf(u8, h, n) != null);
}
