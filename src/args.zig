//! CLI argument parser. Mirrors a useful subset of `claude -p`'s surface
//! and forwards unknown flags through to the child `claude` invocation.
const std = @import("std");
const hook_mod = @import("hook.zig");

/// CLI flag tables, value-flag matcher, error/output enums, and embedded help text.
pub const flags = @import("args/flags.zig");
/// Supported stdout rendering modes (`text`, `json`, `stream-json`).
pub const OutputFormat = flags.OutputFormat;
/// Error set returned when parsing command-line arguments fails.
pub const ParseError = flags.ParseError;
/// Long flags that `claude` accepts with NO value.
pub const known_boolean_long_flags = flags.known_boolean_long_flags;
/// Flags `parse` refuses (bare or `<flag>=<value>`).
pub const rejected_flags = flags.rejected_flags;
/// Return the static `--help` usage text for `claude-p`.
pub const helpText = flags.helpText;

const isKnownBoolean = flags.isKnownBoolean;
const isRejectedFlag = flags.isRejectedFlag;
const parseExtraHook = flags.parseExtraHook;
const parseU32 = flags.parseU32;
const ValueFlag = flags.ValueFlag;
const value_flag_table = flags.value_flag_table;
const FlagMatch = flags.FlagMatch;
const matchFlag = flags.matchFlag;

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
        self.passthrough.deinit(allocator);
        self.add_dirs.deinit(allocator);
        self.mcp_configs.deinit(allocator);
        self.extra_hooks.deinit(allocator);
    }
};

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

fn applyBoolFlag(opts: *Options, a: []const u8) bool {
    std.debug.assert(@intFromPtr(opts) != 0);
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
    } else {
        return false;
    }
    return true;
}

fn parseKnownFlag(
    allocator: std.mem.Allocator,
    opts: *Options,
    argv: []const []const u8,
    idx: *usize,
    diag: *ParseDiag,
) ParseError!bool {
    std.debug.assert(idx.* < argv.len);
    const a = argv[idx.*];
    if (applyBoolFlag(opts, a)) return true;
    if (matchFlag(a, value_flag_table)) |m| {
        const v = m.inline_value orelse blk: {
            idx.* += 1;
            if (idx.* >= argv.len) return fail(diag, a, ParseError.MissingValue);
            break :blk argv[idx.*];
        };
        applyValue(allocator, opts, value_flag_table[m.index].flag, v) catch |err| {
            if (err != ParseError.OutOfMemory) diag.offending = v;
            return err;
        };
        return true;
    }
    if (matchFlag(a, variadic_flags)) |m| {
        const out = if (m.index == 0) &opts.add_dirs else &opts.mcp_configs;
        if (m.inline_value) |v| {
            try out.append(allocator, v);
        } else {
            idx.* = consumeVariadicInto(allocator, argv, idx.*, out, null) catch |err| {
                if (err != ParseError.OutOfMemory) diag.offending = a;
                return err;
            };
        }
        return true;
    }
    if (matchFlag(a, tool_rule_flags)) |m| {
        const canonical = tool_rule_flags[m.index].canonical;
        if (m.inline_value) |v| {
            try opts.passthrough.append(allocator, canonical);
            try opts.passthrough.append(allocator, v);
        } else {
            idx.* = consumeVariadicInto(allocator, argv, idx.*, &opts.passthrough, canonical) catch |err| {
                if (err != ParseError.OutOfMemory) diag.offending = a;
                return err;
            };
        }
        return true;
    }
    return false;
}

fn parsePassthroughOrPositional(
    allocator: std.mem.Allocator,
    opts: *Options,
    argv: []const []const u8,
    idx: *usize,
    diag: *ParseDiag,
) ParseError!void {
    std.debug.assert(idx.* < argv.len);
    const a = argv[idx.*];
    if (isRejectedFlag(a)) return fail(diag, a, ParseError.UnsupportedFlag);
    if (isForwardedValueFlag(a)) {
        if (idx.* + 1 >= argv.len) return fail(diag, a, ParseError.MissingValue);
        try opts.passthrough.append(allocator, a);
        idx.* += 1;
        try opts.passthrough.append(allocator, argv[idx.*]);
        return;
    }
    if (std.mem.startsWith(u8, a, "--")) {
        try opts.passthrough.append(allocator, a);
        const has_inline_value = std.mem.indexOfScalar(u8, a, '=') != null;
        if (!has_inline_value and !isKnownBoolean(a)) {
            if (idx.* + 1 < argv.len and !std.mem.startsWith(u8, argv[idx.* + 1], "-")) {
                idx.* += 1;
                try opts.passthrough.append(allocator, argv[idx.*]);
            }
        }
        return;
    }
    if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
        try opts.passthrough.append(allocator, a);
    } else if (opts.prompt == null) {
        opts.prompt = a;
    } else {
        return ParseError.UnknownFlag;
    }
}

fn validateParsed(opts: *const Options, diag: *ParseDiag) ParseError!void {
    std.debug.assert(@intFromPtr(opts) != 0);
    if (opts.is_daemon and (opts.prompt != null or opts.input_file != null)) {
        if (opts.input_file != null) return fail(diag, "--input-file", ParseError.UnknownFlag);
        return ParseError.UnknownFlag;
    }
    if (opts.is_daemon and opts.output_format_explicit and opts.output_format != .stream_json) {
        return fail(diag, "--output-format", ParseError.UnsupportedFlag);
    }
    if (!opts.show_help and !opts.show_version and !opts.is_daemon) {
        if (opts.output_format == .stream_json and !opts.verbose) {
            return fail(diag, "stream-json", ParseError.StreamJsonRequiresVerbose);
        }
    }
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

    var argv: []const []const u8 = argv_in;
    if (argv_in.len > 0 and std.mem.eql(u8, argv_in[0], "daemon")) {
        opts.is_daemon = true;
        argv = argv_in[1..];
    }

    var seen_separator = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        std.debug.assert(i < argv.len);
        const a = argv[i];
        if (seen_separator) {
            if (opts.prompt == null) {
                opts.prompt = a;
                continue;
            }
            return ParseError.UnknownFlag;
        }
        if (std.mem.eql(u8, a, "--")) {
            seen_separator = true;
            continue;
        }
        if (try parseKnownFlag(allocator, &opts, argv, &i, diag)) continue;
        try parsePassthroughOrPositional(allocator, &opts, argv, &i, diag);
    }

    try validateParsed(&opts, diag);
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
    std.debug.assert(start < argv.len);
    var i = start + 1;
    if (i >= argv.len or std.mem.startsWith(u8, argv[i], "-")) return ParseError.MissingValue;
    while (true) {
        std.debug.assert(i < argv.len);
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
