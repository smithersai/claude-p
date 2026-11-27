//! Driver options, result types, pre-spawn path/binary validation, argv builder,
//! shell quoting, and child environment filtering.
const std = @import("std");
const args_mod = @import("../args.zig");
const emit_mod = @import("../emit.zig");
const hook_mod = @import("../hook.zig");
const transcript_mod = @import("../transcript.zig");

/// Executable PATH resolution, cwd validation, shell quoting, and child env filtering.
pub const spawn = @import("spawn.zig");
/// Error set returned when locating the `claude` binary fails.
pub const ResolveError = spawn.ResolveError;
/// Check that `cwd`, when set, names an accessible directory.
pub const validateCwd = spawn.validateCwd;
/// Resolve `path` to a real accessible directory path; caller owns the slice.
pub const resolveCwd = spawn.resolveCwd;
/// Resolve the `claude` executable using an explicit override or `path_env`.
pub const resolveClaudeBinaryIn = spawn.resolveClaudeBinaryIn;
/// Resolve the `claude` executable against this process's `PATH`.
pub const resolveClaudeBinary = spawn.resolveClaudeBinary;
/// Build the `/bin/sh -l -c` `exec` command line from `argv`.
pub const buildShellCommand = spawn.buildShellCommand;
/// Build the `/bin/sh -l -c` command string, optionally changing into `cwd` before `exec`.
pub const buildShellCommandInDir = spawn.buildShellCommandInDir;
/// Join argv into a single shell-safe command line (single-quoting each arg).
pub const shellQuoteArgv = spawn.shellQuoteArgv;
/// Return true ONLY for nested-session markers that must not leak into child `claude`.
pub const shouldStripChildEnv = spawn.shouldStripChildEnv;
/// Build the filtered child environment from the current process environment.
pub const buildChildEnv = spawn.buildChildEnv;
/// Construct the sanitized child environment list from `env_map`.
pub const buildChildEnvFromMap = spawn.buildChildEnvFromMap;
/// Free all owned `KEY=VALUE` entries in a child environment list.
pub const freeChildEnv = spawn.freeChildEnv;

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
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{ .prompt = "hi", .skip_permissions = true, .cont = true });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--dangerously-skip-permissions", argv.items[3]);
    try testing.expectEqualStrings("--continue", argv.items[4]);
}

test "buildArgv: passthrough extra args appended in order" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{ .prompt = "hi", .extra_args = &.{ "--effort", "high" } });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--effort", argv.items[3]);
    try testing.expectEqualStrings("high", argv.items[4]);
}

test "buildArgv: add-dirs and mcp-configs repeat cleanly" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .add_dirs = &.{ "/a", "/b" },
        .mcp_configs = &.{"m.json"},
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--add-dir", argv.items[3]);
    try testing.expectEqualStrings("/b", argv.items[6]);
    try testing.expectEqualStrings("--mcp-config", argv.items[7]);
}

test "buildArgv: allowedTools, disallowedTools, and fallback_model" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .allowed_tools = "Read",
        .disallowed_tools = "Bash",
        .fallback_model = "haiku",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--allowedTools", argv.items[3]);
    try testing.expectEqualStrings("--disallowedTools", argv.items[5]);
    try testing.expectEqualStrings("--fallback-model", argv.items[7]);
}

test "buildArgv: resume_session and session_id pairs" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .resume_session = "r1",
        .session_id = "s1",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--resume", argv.items[3]);
    try testing.expectEqualStrings("--session-id", argv.items[5]);
}

test "buildArgv: system prompt, permission mode, and setting sources" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .system_prompt = "sys",
        .append_system_prompt = "app",
        .permission_mode = "plan",
        .setting_sources = "user",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("--system-prompt", argv.items[3]);
    try testing.expectEqualStrings("--append-system-prompt", argv.items[5]);
    try testing.expectEqualStrings("--permission-mode", argv.items[7]);
    try testing.expectEqualStrings("--setting-sources", argv.items[9]);
}

test "validateOptions: accepts clean default options" {
    try validateOptions(.{ .prompt = "hi" });
}

test "validateOptions: rejects max_turns and fallback_model" {
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .max_turns = 1 }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .fallback_model = "haiku" }));
}

test "validateOptions: rejects forwarded print-only flags" {
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .extra_args = &.{"--max-turns=2"} }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .extra_args = &.{"--bare"} }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "hi", .extra_args = &.{"--settings"} }));
}

test "validateOptions: allows blocked names as flag values or after --" {
    try validateOptions(.{ .prompt = "hi", .extra_args = &.{ "--system-prompt", "--bare" } });
    try validateOptions(.{ .prompt = "hi", .extra_args = &.{ "--", "--print" } });
}

test "isResumeRun: false on fresh run" {
    try testing.expect(!isResumeRun(.{ .prompt = "hi" }));
}

test "isResumeRun: true on cont or resume_session" {
    try testing.expect(isResumeRun(.{ .prompt = "hi", .cont = true }));
    try testing.expect(isResumeRun(.{ .prompt = "hi", .resume_session = "s1" }));
}

test "isResumeRun: detects forwarded resume flags and stops at --" {
    try testing.expect(isResumeRun(.{ .prompt = "hi", .extra_args = &.{"--fork-session"} }));
    try testing.expect(!isResumeRun(.{ .prompt = "hi", .extra_args = &.{ "--", "--resume" } }));
}

test "ExtraFlags: parses inline values, value-taking flags, and stops at --" {
    var it: ExtraFlags = .{ .args = &.{ "--model=opus", "--permission-mode", "plan", "--", "--resume" } };
    const f1 = it.next().?;
    try testing.expectEqualStrings("--model", f1.name);
    try testing.expectEqualStrings("opus", f1.value.?);
    const f2 = it.next().?;
    try testing.expectEqualStrings("--permission-mode", f2.name);
    try testing.expectEqualStrings("plan", f2.value.?);
    try testing.expect(it.next() == null);
}

test "ExtraFlags: yields null value for standalone boolean flags" {
    var it: ExtraFlags = .{ .args = &.{"--verbose"} };
    const f = it.next().?;
    try testing.expectEqualStrings("--verbose", f.name);
    try testing.expect(f.value == null);
}

test "ExtraFlags: empty args yields null immediately" {
    var it: ExtraFlags = .{ .args = &.{} };
    try testing.expect(it.next() == null);
}

test "Result.exitCode reflects summary.is_error" {
    const ok: Result = .{
        .summary = .{ .final_text = &.{}, .session_id = &.{}, .is_error = false, .total_cost_usd = 0, .jsonl_replay = &.{} },
        .duration_ms = 5,
    };
    var err_res = ok;
    err_res.summary.is_error = true;
    try testing.expectEqual(@as(u8, 0), ok.exitCode());
    try testing.expectEqual(@as(u8, 1), err_res.exitCode());
}

test "Result.write skips stream_json when already streamed" {
    const res: Result = .{
        .summary = .{ .final_text = @constCast("hi"), .session_id = &.{}, .is_error = false, .total_cost_usd = 0, .jsonl_replay = &.{} },
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
