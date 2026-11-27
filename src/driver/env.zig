//! Driver options, result types, pre-spawn path/binary validation, argv builder,
//! shell quoting, and child environment filtering.
const std = @import("std");
const args_mod = @import("../args.zig");
const emit_mod = @import("../emit.zig");
const hook_mod = @import("../hook.zig");
const transcript_mod = @import("../transcript.zig");

/// Configuration options for a single-shot PTY Claude Code session run.
pub const Options = struct {
    prompt: []const u8,
    output_format: args_mod.OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    add_dirs: []const []const u8 = &.{},
    mcp_configs: []const []const u8 = &.{},
    extra_hooks: []const hook_mod.ExtraHook = &.{},
    extra_settings_json: ?[]const u8 = null,
    verbose: bool = false,
    timeout_ms: u64 = 300_000,
    transcript_idle_timeout_ms: ?u64 = null,
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
    stream_writer: ?*std.Io.Writer = null,
    retain_replay: bool = true,
};

/// Outcome of a completed single-shot run, owning its parsed `Summary`.
pub const Result = struct {
    summary: transcript_mod.Summary,
    duration_ms: u64,
    streamed: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
    }

    pub fn write(
        self: *const Result,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        fmt: args_mod.OutputFormat,
    ) !void {
        if (self.streamed and fmt == .stream_json) return;
        try emit_mod.emit(allocator, writer, fmt, .{
            .summary = &self.summary,
            .duration_ms = self.duration_ms,
        });
    }

    pub fn exitCode(self: *const Result) u8 {
        return if (self.summary.is_error) 1 else 0;
    }
};

/// Error set returned by single-shot PTY session orchestration.
pub const RunError = error{
    WriteFailed,
    PermissionPromptBlocked,
    InvalidOptions,
    SessionStartTimeout,
    StopTimeout,
    TranscriptStalled,
    PromptNotAccepted,
    PromptTruncated,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
    InvalidExtraSettings,
    Interrupted,
    InvalidCwd,
    UnexpectedStartupDialog,
} || std.mem.Allocator.Error;

/// Error set returned when locating the `claude` binary fails.
pub const ResolveError = error{
    ClaudeNotFound,
} || std.mem.Allocator.Error;

/// Single parsed flag name/value pair yielded by `ExtraFlags`.
pub const ExtraFlag = struct { name: []const u8, value: ?[]const u8 };

/// Iterator over forwarded `extra_args` honoring `--`, `=`, and value-taking flags.
pub const ExtraFlags = struct {
    args: []const []const u8,

    const required_value_flags = [_][]const u8{
        "--permission-mode",                    "--model",                                 "--agent",
        "--agents",                             "--system-prompt",                         "--append-system-prompt",
        "--system-prompt-file",                 "--append-system-prompt-file",             "--setting-sources",
        "--session-id",                         "--effort",                                "--permission-prompt-tool",
        "--output-format",                      "--debug-file",                            "--name",
        "-n",                                   "--autocompact",                           "--environment",
        "--permission-prompts",                 "--plugin-dir",                            "--plugin-url",
        "--add-dir",                            "--allowedTools",                          "--allowed-tools",
        "--disallowedTools",                    "--disallowed-tools",                      "--mcp-config",
        "--tools",                              "--file",                                  "--betas",
        "--channels",                           "--max-turns",                             "--fallback-model",
        "--settings",                           "--input-format",                          "--json-schema",
        "--max-budget-usd",                     "--from-pr",                               "--system-prompt-snapshot",
        "--remote-control-session-name-prefix", "--dangerously-load-development-channels",
    };

    pub fn next(self: *ExtraFlags) ?ExtraFlag {
        while (self.args.len != 0) {
            const token = self.args[0];
            self.args = self.args[1..];
            if (std.mem.eql(u8, token, "--")) {
                self.args = &.{};
                return null;
            }
            if (!std.mem.startsWith(u8, token, "-")) continue;
            if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
                if (std.mem.startsWith(u8, token, "--") or std.mem.eql(u8, token[0..eq], "-p"))
                    return .{ .name = token[0..eq], .value = token[eq + 1 ..] };
            }
            for (required_value_flags) |flag| {
                if (std.mem.eql(u8, token, flag) and self.args.len > 0 and !std.mem.eql(u8, self.args[0], "--")) {
                    const value = self.args[0];
                    self.args = self.args[1..];
                    return .{ .name = token, .value = value };
                }
            }
            return .{ .name = token, .value = null };
        }
        return null;
    }
};

/// Reject options or forwarded flags that are unsupported in PTY print mode.
pub fn validateOptions(opts: Options) RunError!void {
    if (opts.max_turns != null or opts.fallback_model != null) return error.InvalidOptions;
    var flags: ExtraFlags = .{ .args = opts.extra_args };
    const extra_rejected = [_][]const u8{
        "--max-turns",
        "--fallback-model",
        "--include-partial-messages",
        "--forward-subagent-text",
        "--replay-user-messages",
    };
    while (flags.next()) |arg| {
        for (args_mod.rejected_flags ++ extra_rejected) |flag| {
            if (std.mem.eql(u8, flag, arg.name)) return error.InvalidOptions;
        }
    }
}

/// True when this invocation restores an earlier conversation.
pub fn isResumeRun(opts: Options) bool {
    if (opts.resume_session != null or opts.cont) return true;
    const exact = [_][]const u8{
        "--resume",
        "-r",
        "--continue",
        "-c",
        "--fork-session",
        "--from-pr",
        "--teleport",
    };
    var flags: ExtraFlags = .{ .args = opts.extra_args };
    while (flags.next()) |arg| {
        for (exact) |flag| if (std.mem.eql(u8, arg.name, flag)) return true;
    }
    return false;
}

/// Check that `cwd`, when set, names an accessible directory.
pub fn validateCwd(cwd: ?[]const u8) RunError!void {
    const path = cwd orelse return;
    const resolved = try resolveCwd(std.heap.page_allocator, path);
    std.debug.assert(resolved.len > 0);
    std.heap.page_allocator.free(resolved);
}

/// Resolve `path` to a real accessible directory path; caller owns the slice.
pub fn resolveCwd(allocator: std.mem.Allocator, path: []const u8) RunError![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCwd;
    const resolved = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCwd,
    };
    errdefer allocator.free(resolved);
    var dir = std.fs.cwd().openDir(resolved, .{}) catch return error.InvalidCwd;
    dir.close();
    std.posix.access(resolved, std.posix.X_OK) catch return error.InvalidCwd;
    std.debug.assert(resolved.len > 0 and resolved[0] == '/');
    return resolved;
}

fn isExecutableFile(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    const st = std.fs.cwd().statFile(path) catch return false;
    if (st.kind != .file) return false;
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ResolveError![]u8 {
    std.debug.assert(path.len > 0);
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ClaudeNotFound,
    };
}

/// Resolve the `claude` executable using an explicit override or `path_env`.
pub fn resolveClaudeBinaryIn(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    path_env: ?[]const u8,
) ResolveError![]u8 {
    const name = override orelse "claude";
    if (name.len == 0) return ResolveError.ClaudeNotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (!isExecutableFile(name)) return ResolveError.ClaudeNotFound;
        return absolutePath(allocator, name);
    }
    var it = std.mem.splitScalar(u8, path_env orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(allocator, &.{ if (dir.len == 0) "." else dir, name });
        defer allocator.free(candidate);
        if (isExecutableFile(candidate)) return absolutePath(allocator, candidate) catch |err| switch (err) {
            error.ClaudeNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return ResolveError.ClaudeNotFound;
}

/// Resolve the `claude` executable against this process's `PATH`.
pub fn resolveClaudeBinary(allocator: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    const path_env: ?[]u8 = std.process.getEnvVarOwned(allocator, "PATH") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (path_env) |p| allocator.free(p);
    return resolveClaudeBinaryIn(allocator, override, path_env);
}

/// Build the `/bin/sh -l -c` `exec` command line from `argv`.
pub fn buildShellCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return buildShellCommandInDir(allocator, argv, null);
}

/// Build the `/bin/sh -l -c` command string, optionally changing into `cwd` before `exec`.
pub fn buildShellCommandInDir(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) ![]u8 {
    const quoted = try shellQuoteArgv(allocator, argv);
    defer allocator.free(quoted);
    if (cwd) |dir| {
        const path = try resolveCwd(allocator, dir);
        defer allocator.free(path);
        const escaped = try shellQuoteArgv(allocator, &.{path});
        defer allocator.free(escaped);
        const cmd = try std.mem.concat(allocator, u8, &.{ "cd -- ", escaped, " || exit 126; exec ", quoted });
        std.debug.assert(cmd.len >= quoted.len);
        return cmd;
    }
    const cmd = try std.mem.concat(allocator, u8, &.{ "exec ", quoted });
    std.debug.assert(cmd.len == 5 + quoted.len);
    return cmd;
}

/// Owned argv container returned by `buildArgv`.
pub const Argv = struct {
    items: [][]const u8,
    max_turns_text: ?[]u8,

    pub fn deinit(self: *Argv, allocator: std.mem.Allocator) void {
        if (self.max_turns_text) |t| allocator.free(t);
        allocator.free(self.items);
        self.* = undefined;
    }
};

fn appendOptPair(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    flag: []const u8,
    val: ?[]const u8,
) !void {
    std.debug.assert(flag.len > 0);
    if (val) |v| {
        try argv.append(allocator, flag);
        try argv.append(allocator, v);
    }
}

/// Build the argv for the child `claude` invocation.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    binary: []const u8,
    settings_json: []const u8,
    opts: Options,
) !Argv {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    var max_turns_text: ?[]u8 = null;
    errdefer if (max_turns_text) |t| allocator.free(t);

    try argv.appendSlice(allocator, &.{ binary, "--settings", settings_json });
    std.debug.assert(argv.items.len == 3 and std.mem.eql(u8, argv.items[1], "--settings"));
    try appendOptPair(allocator, &argv, "--model", opts.model);
    if (opts.max_turns) |n| {
        max_turns_text = try std.fmt.allocPrint(allocator, "{d}", .{n});
        try argv.appendSlice(allocator, &.{ "--max-turns", max_turns_text.? });
    }
    try appendOptPair(allocator, &argv, "--allowedTools", opts.allowed_tools);
    if (opts.skip_permissions) try argv.append(allocator, "--dangerously-skip-permissions");
    try appendOptPair(allocator, &argv, "--resume", opts.resume_session);
    if (opts.cont) try argv.append(allocator, "--continue");
    try appendOptPair(allocator, &argv, "--session-id", opts.session_id);
    if (opts.verbose) try argv.append(allocator, "--verbose");
    try appendOptPair(allocator, &argv, "--system-prompt", opts.system_prompt);
    try appendOptPair(allocator, &argv, "--append-system-prompt", opts.append_system_prompt);
    try appendOptPair(allocator, &argv, "--permission-mode", opts.permission_mode);
    try appendOptPair(allocator, &argv, "--disallowedTools", opts.disallowed_tools);
    try appendOptPair(allocator, &argv, "--fallback-model", opts.fallback_model);
    try appendOptPair(allocator, &argv, "--setting-sources", opts.setting_sources);
    for (opts.add_dirs) |d| try argv.appendSlice(allocator, &.{ "--add-dir", d });
    for (opts.mcp_configs) |c| try argv.appendSlice(allocator, &.{ "--mcp-config", c });
    for (opts.extra_args) |a| try argv.append(allocator, a);
    std.debug.assert(argv.items.len >= 3);
    return .{ .items = try argv.toOwnedSlice(allocator), .max_turns_text = max_turns_text };
}

/// Join argv into a single shell-safe command line (single-quoting each arg).
pub fn shellQuoteArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    for (argv, 0..) |a, idx| {
        if (idx > 0) try buf.append(allocator, ' ');
        try shellQuoteOne(allocator, &buf, a);
    }
    return try buf.toOwnedSlice(allocator);
}

fn shellQuoteOne(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const before = out.items.len;
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    std.debug.assert(out.items.len >= before + 2);
}

const persistence_env = "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE";

/// Return true ONLY for nested-session markers that must not leak into child `claude`.
pub fn shouldStripChildEnv(name: []const u8) bool {
    const exact = [_][]const u8{
        "CLAUDECODE",
        "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
    };
    for (exact) |marker| if (std.mem.eql(u8, name, marker)) return true;
    const prefixes = [_][]const u8{
        "CLAUDE_CODE_SESSION_",
        "CLAUDE_CODE_PARENT_",
        "CLAUDE_CODE_SUBAGENT_",
    };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

/// Build the filtered child environment from the current process environment.
pub fn buildChildEnv(allocator: std.mem.Allocator, fifo_path: []const u8) !std.ArrayList([]u8) {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    return buildChildEnvFromMap(allocator, &env_map, fifo_path);
}

/// Construct the sanitized child environment list from `env_map`.
pub fn buildChildEnvFromMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.EnvMap,
    fifo_path: []const u8,
) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .{};
    errdefer freeChildEnv(allocator, &list);
    var saw_persistence = false;
    var it = env_map.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (shouldStripChildEnv(name)) continue;
        if (std.mem.eql(u8, name, "CLAUDE_P_FIFO") or std.mem.eql(u8, name, "TERM")) continue;
        if (std.mem.eql(u8, name, persistence_env)) saw_persistence = true;
        try appendEnv(allocator, &list, name, e.value_ptr.*);
    }
    _ = fifo_path;
    try appendEnv(allocator, &list, "TERM", "xterm-256color");
    if (!saw_persistence) try appendEnv(allocator, &list, persistence_env, "1");
    std.debug.assert(list.items.len >= 1);
    return list;
}

fn appendEnv(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), name: []const u8, value: []const u8) !void {
    const entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ name, value });
    errdefer allocator.free(entry);
    try list.append(allocator, entry);
}

/// Free all owned `KEY=VALUE` entries in a child environment list.
pub fn freeChildEnv(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| allocator.free(entry);
    list.deinit(allocator);
}

// -------- tests --------
const testing = std.testing;

test "buildArgv: minimal includes binary and --settings" {
    var argv = try buildArgv(testing.allocator, "/bin/claude", "{}", .{ .prompt = "hi" });
    defer argv.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), argv.items.len);
    try testing.expectEqualStrings("/bin/claude", argv.items[0]);
    try testing.expectEqualStrings("--settings", argv.items[1]);
    try testing.expectEqualStrings("{}", argv.items[2]);
}

test "buildArgv: max-turns owned and allocation-failure safe" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var argv = try buildArgv(alloc, "/bin/claude", "{}", .{ .prompt = "hi", .max_turns = 7 });
            defer argv.deinit(alloc);
            try testing.expectEqualStrings("7", argv.items[4]);
        }
    }.run, .{});
}

test "buildArgv: model and verbose flags" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{ .prompt = "hi", .model = "sonnet", .verbose = true });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--model", argv.items[3]);
    try testing.expectEqualStrings("sonnet", argv.items[4]);
    try testing.expectEqualStrings("--verbose", argv.items[5]);
}

test "buildArgv: dangerously-skip-permissions and continue" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .skip_permissions = true,
        .cont = true,
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--dangerously-skip-permissions", argv.items[3]);
    try testing.expectEqualStrings("--continue", argv.items[4]);
}

test "buildArgv: passthrough extra args appended in order" {
    const extra = [_][]const u8{ "--effort", "high" };
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{ .prompt = "hi", .extra_args = &extra });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--effort", argv.items[3]);
    try testing.expectEqualStrings("high", argv.items[4]);
}

test "buildArgv: add-dirs and mcp-configs repeat cleanly" {
    const dirs = [_][]const u8{ "/a", "/b" };
    const mcps = [_][]const u8{"m.json"};
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .add_dirs = &dirs,
        .mcp_configs = &mcps,
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--add-dir", argv.items[3]);
    try testing.expectEqualStrings("/a", argv.items[4]);
    try testing.expectEqualStrings("--add-dir", argv.items[5]);
    try testing.expectEqualStrings("/b", argv.items[6]);
    try testing.expectEqualStrings("--mcp-config", argv.items[7]);
    try testing.expectEqualStrings("m.json", argv.items[8]);
}

test "shellQuoteArgv: escapes single quotes and preserves JSON" {
    const out = try shellQuoteArgv(testing.allocator, &.{ "claude", "it's", "{\"a\":1}" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("'claude' 'it'\\''s' '{\"a\":1}'", out);
}

test "buildShellCommand: exec-prefixes quoted argv" {
    const out = try buildShellCommand(testing.allocator, &.{ "/bin/claude", "--verbose" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec '/bin/claude' '--verbose'", out);
}

test "buildShellCommandInDir: prefixes cd and exit 126" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const out = try buildShellCommandInDir(testing.allocator, &.{"/bin/claude"}, dir);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "cd -- '"));
    try testing.expect(std.mem.indexOf(u8, out, " || exit 126; exec '/bin/claude'") != null);
}

test "validateCwd: accepts directory and rejects file, missing, empty, NUL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "x" });
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const file = try tmp.dir.realpathAlloc(testing.allocator, "f");
    defer testing.allocator.free(file);
    try validateCwd(null);
    try validateCwd(dir);
    try testing.expectError(error.InvalidCwd, validateCwd(file));
    try testing.expectError(error.InvalidCwd, validateCwd(""));
    try testing.expectError(error.InvalidCwd, validateCwd("/tmp/bad\x00path"));
    try testing.expectError(error.InvalidCwd, validateCwd("/nonexistent/claude-p-dir"));
}

test "resolveClaudeBinaryIn: finds executable on PATH and rejects non-executable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("claude", .{ .mode = 0o700 });
    f.close();
    const nf = try tmp.dir.createFile("noexec", .{ .mode = 0o600 });
    nf.close();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const found = try resolveClaudeBinaryIn(testing.allocator, null, dir);
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "/claude"));
    const bad = try std.fs.path.join(testing.allocator, &.{ dir, "noexec" });
    defer testing.allocator.free(bad);
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, bad, dir));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "", dir));
}

test "shouldStripChildEnv: strips nested markers and preserves auth/backend vars" {
    try testing.expect(shouldStripChildEnv("CLAUDECODE"));
    try testing.expect(shouldStripChildEnv("AI_AGENT"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_SESSION_FOO"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_PARENT_PID"));
    try testing.expect(!shouldStripChildEnv("CLAUDE_CODE_OAUTH_TOKEN"));
    try testing.expect(!shouldStripChildEnv("CLAUDE_CONFIG_DIR"));
    try testing.expect(!shouldStripChildEnv("CLAUDE_CODE_USE_BEDROCK"));
}

test "buildChildEnvFromMap: sets TERM and persistence while filtering markers" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("CLAUDECODE", "1");
    try env.put("CLAUDE_P_FIFO", "/tmp/old");
    try env.put("TERM", "dumb");
    try env.put("CLAUDE_CODE_OAUTH_TOKEN", "tok");
    var list = try buildChildEnvFromMap(testing.allocator, &env, "/tmp/f");
    defer freeChildEnv(testing.allocator, &list);
    var saw_term = false;
    var saw_persist = false;
    var saw_tok = false;
    for (list.items) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry, "CLAUDECODE="));
        try testing.expect(!std.mem.startsWith(u8, entry, "CLAUDE_P_FIFO="));
        if (std.mem.eql(u8, entry, "TERM=xterm-256color")) saw_term = true;
        if (std.mem.eql(u8, entry, "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1")) saw_persist = true;
        if (std.mem.eql(u8, entry, "CLAUDE_CODE_OAUTH_TOKEN=tok")) saw_tok = true;
    }
    try testing.expect(saw_term and saw_persist and saw_tok);
}

test "buildChildEnvFromMap: preserves caller persistence value without duplicating" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE", "custom");
    var list = try buildChildEnvFromMap(testing.allocator, &env, "");
    defer freeChildEnv(testing.allocator, &list);
    var count: usize = 0;
    for (list.items) |e| {
        if (std.mem.startsWith(u8, e, "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "buildChildEnvFromMap: allocation failures leak nothing" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp");
    try env.put("PATH", "/usr/bin");
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, m: *const std.process.EnvMap) !void {
            var list = try buildChildEnvFromMap(alloc, m, "/tmp/f");
            freeChildEnv(alloc, &list);
        }
    }.run, .{&env});
}

test "validateOptions: rejects print-mode-only options and forwarded flags" {
    try validateOptions(.{ .prompt = "hi" });
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .max_turns = 1 }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .fallback_model = "haiku" }));
    const bad = [_][]const u8{"--max-turns=2"};
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .extra_args = &bad }));
}

test "isResumeRun: detects explicit and forwarded resume/continue flags" {
    try testing.expect(!isResumeRun(.{ .prompt = "hi" }));
    try testing.expect(isResumeRun(.{ .prompt = "hi", .cont = true }));
    try testing.expect(isResumeRun(.{ .prompt = "hi", .resume_session = "s1" }));
    const fork_args = [_][]const u8{"--fork-session"};
    try testing.expect(isResumeRun(.{ .prompt = "hi", .extra_args = &fork_args }));
    const after_sep = [_][]const u8{ "--", "--resume" };
    try testing.expect(!isResumeRun(.{ .prompt = "hi", .extra_args = &after_sep }));
}

test "ExtraFlags: parses inline values, value-taking flags, and stops at --" {
    const argv = [_][]const u8{ "--model=opus", "--permission-mode", "plan", "--", "--resume" };
    var it: ExtraFlags = .{ .args = &argv };
    const f1 = it.next().?;
    try testing.expectEqualStrings("--model", f1.name);
    try testing.expectEqualStrings("opus", f1.value.?);
    const f2 = it.next().?;
    try testing.expectEqualStrings("--permission-mode", f2.name);
    try testing.expectEqualStrings("plan", f2.value.?);
    try testing.expect(it.next() == null);
}

test "Result.exitCode reflects summary.is_error" {
    const ok: Result = .{
        .summary = .{
            .final_text = &.{},
            .session_id = &.{},
            .is_error = false,
            .num_turns = 1,
            .total_cost_usd = 0,
            .duration_api_ms = 0,
            .usage = .{},
            .jsonl_replay = &.{},
        },
        .duration_ms = 5,
    };
    var err_res = ok;
    err_res.summary.is_error = true;
    try testing.expectEqual(@as(u8, 0), ok.exitCode());
    try testing.expectEqual(@as(u8, 1), err_res.exitCode());
}

test "Result.write skips stream_json when already streamed" {
    const res: Result = .{
        .summary = .{
            .final_text = @constCast("hi"),
            .session_id = &.{},
            .is_error = false,
            .num_turns = 1,
            .total_cost_usd = 0,
            .duration_api_ms = 0,
            .usage = .{},
            .jsonl_replay = &.{},
        },
        .duration_ms = 1,
        .streamed = true,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try res.write(testing.allocator, &aw.writer, .stream_json);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
    try res.write(testing.allocator, &aw.writer, .text);
    try testing.expectEqualStrings("hi\n", aw.written());
}
