//! End-to-end driver: spawn `claude` under a zmux NativeSession, drive the UI
//! with our prompt, wait for the Stop hook, and return a Result.
const std = @import("std");
const zmux = @import("zmux");

const args_mod = @import("args.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const hook_mod = @import("hook.zig");
const terminal_mod = @import("terminal.zig");
const stream_mod = @import("stream.zig");

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
    /// Explicit support for high-value claude flags. These are forwarded to
    /// the child as the corresponding `claude` flag.
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,
    add_dirs: []const []const u8 = &.{},
    mcp_configs: []const []const u8 = &.{},
    /// Extra hooks merged into the generated `--settings` JSON after the
    /// relay hooks.
    extra_hooks: []const hook_mod.ExtraHook = &.{},
    /// JSON object whose top-level keys (except `hooks`) are merged into the
    /// generated `--settings` JSON.
    extra_settings_json: ?[]const u8 = null,
    verbose: bool = false,
    /// Wall-clock budget for the whole run. `0` disables the timeout.
    timeout_ms: u64 = 300_000,
    /// While awaiting Stop, timeout when both transcript and PTY are idle.
    /// Null or zero disables the progress watchdog.
    transcript_idle_timeout_ms: ?u64 = null,
    /// Override `claude` binary path (testing).
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
    /// When set and `output_format` is `.stream_json`, the driver tails the
    /// session transcript and writes each JSONL line to this writer as it
    /// is flushed by the child `claude`. After Stop, the driver writes the
    /// final `result` envelope and flushes. Result.streamed is set to true
    /// so callers can avoid re-emitting via Result.write.
    stream_writer: ?*std.Io.Writer = null,
    retain_replay: bool = true,
};

/// Outcome of a completed single-shot run, owning its parsed `Summary`.
pub const Result = struct {
    summary: transcript_mod.Summary,
    duration_ms: u64,
    /// True if `run()` already streamed stream-json output to the caller's
    /// `stream_writer`. `Result.write` is a no-op for `.stream_json` in that
    /// case to avoid double-emit.
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
    /// claude never acknowledged the typed prompt after all re-injections.
    PromptNotAccepted,
    /// claude received a truncated copy of our typed prompt.
    PromptTruncated,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
    /// `extra_settings_json` is invalid/non-object, or an extra hook is empty.
    InvalidExtraSettings,
    /// `requestInterrupt` was called (SIGINT / SIGTERM / SIGHUP). `run`
    /// unwinds through its `defer`s, so the PTY and temp dir are gone.
    Interrupted,
    /// `opts.cwd` does not name a directory this process can open.
    InvalidCwd,
    /// claude showed a bypass-permissions or development-channels dialog that
    /// the caller's flags did not ask for. The driver never confirms it.
    UnexpectedStartupDialog,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Signal cancellation & monotonic clock
// ---------------------------------------------------------------------------

/// Set by `requestInterrupt`; polled by `run` and by every settle wait.
pub var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Remember signals for overlapping runs even after one run consumes the flag.
var interrupt_generation = std.atomic.Value(u32).init(0);
threadlocal var active_generation: ?u32 = null;

/// RAII guard capturing the current interrupt generation for a single session.
pub const InterruptScope = struct {
    previous: ?u32,

    pub fn enter() InterruptScope {
        const previous = active_generation;
        active_generation = interrupt_generation.load(.seq_cst);
        return .{ .previous = previous };
    }

    pub fn exit(self: InterruptScope) void {
        active_generation = self.previous;
    }
};

/// Ask every in-flight run to stop using only lock-free signal-safe atomics.
pub fn requestInterrupt() void {
    _ = interrupt_generation.fetchAdd(1, .seq_cst);
    interrupted.store(true, .seq_cst);
}

/// Reset the global interrupt flag after an interrupted session unwinds.
pub fn clearInterrupt() void {
    interrupted.store(false, .seq_cst);
}

/// Return true if a global interrupt was requested since this scope began.
pub fn isInterrupted() bool {
    const gen_changed = active_generation != null and
        active_generation.? != interrupt_generation.load(.seq_cst);
    return interrupted.load(.seq_cst) or gen_changed;
}

var clock_once = std.once(initClock);
var clock_wall_base_ns: i128 = 0;
var clock_mono_base_ns: i128 = 0;

fn rawMonotonicNs() ?i128 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn initClock() void {
    clock_wall_base_ns = std.time.nanoTimestamp();
    clock_mono_base_ns = rawMonotonicNs() orelse 0;
}

/// Nanoseconds on a clock that never steps: the wall-clock time sampled once
/// at first use, advanced by `CLOCK_MONOTONIC`. NTP or manual clock changes
/// cannot move it, so deadlines, watchdogs, and durations built on it never
/// misfire or go negative. The epoch anchor keeps values near
/// `std.time.nanoTimestamp()` so they fit `i64` and stay comparable with
/// callers that have not switched clocks yet.
pub fn monotonicNs() i128 {
    clock_once.call();
    const mono = rawMonotonicNs() orelse return std.time.nanoTimestamp();
    return clock_wall_base_ns + (mono - clock_mono_base_ns);
}

// ---------------------------------------------------------------------------
// Pre-spawn validation: working directory & claude binary
// ---------------------------------------------------------------------------

/// Check that `cwd`, when set, names a directory this process can open.
/// zmux would otherwise fork and fail the `chdir` inside the child.
pub fn validateCwd(cwd: ?[]const u8) RunError!void {
    const path = cwd orelse return;
    const resolved = try resolveCwd(std.heap.page_allocator, path);
    std.heap.page_allocator.free(resolved);
}

fn resolveCwd(allocator: std.mem.Allocator, path: []const u8) RunError![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidCwd;
    const resolved = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCwd,
    };
    errdefer allocator.free(resolved);
    var dir = std.fs.cwd().openDir(resolved, .{}) catch return error.InvalidCwd;
    dir.close();
    std.posix.access(resolved, std.posix.X_OK) catch return error.InvalidCwd;
    return resolved;
}

/// Error set returned when locating the `claude` binary fails.
pub const ResolveError = error{
    /// No executable regular file at the override path or on `PATH`.
    ClaudeNotFound,
} || std.mem.Allocator.Error;

fn isExecutableFile(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    const st = std.fs.cwd().statFile(path) catch return false;
    if (st.kind != .file) return false;
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

/// Resolve the `claude` executable before spawning. An `override` containing
/// `/` is checked as a path; a bare name (default `claude`) is searched on
/// `path_env` the way a shell would. Returns the owned, resolved path.
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

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ResolveError![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ClaudeNotFound,
    };
}

/// `resolveClaudeBinaryIn` against this process's `PATH`.
pub fn resolveClaudeBinary(allocator: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    const path_env: ?[]u8 = std.process.getEnvVarOwned(allocator, "PATH") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (path_env) |p| allocator.free(p);
    return resolveClaudeBinaryIn(allocator, override, path_env);
}

/// The command line handed to zmux's `/bin/sh -l -c`: `exec` plus the quoted
/// argv, so the shell replaces itself with `claude` and no extra shell PID
/// sits between the PTY and the child.
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
        return std.mem.concat(allocator, u8, &.{ "cd -- ", escaped, " || exit 126; exec ", quoted });
    }
    return std.mem.concat(allocator, u8, &.{ "exec ", quoted });
}

/// Owned argv container returned by `buildArgv`. Entries borrow from the
/// caller's `binary`, `settings_json`, and `opts`, except the formatted
/// `--max-turns` string, which `Argv` owns and `deinit` frees with zero leaks.
pub const Argv = struct {
    items: [][]const u8,
    max_turns_text: ?[]u8,

    pub fn deinit(self: *Argv, allocator: std.mem.Allocator) void {
        if (self.max_turns_text) |t| allocator.free(t);
        allocator.free(self.items);
        self.* = undefined;
    }
};

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

    try argv.append(allocator, binary);
    try argv.append(allocator, "--settings");
    try argv.append(allocator, settings_json);
    if (opts.model) |m| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, m);
    }
    if (opts.max_turns) |n| {
        try argv.append(allocator, "--max-turns");
        max_turns_text = try std.fmt.allocPrint(allocator, "{d}", .{n});
        try argv.append(allocator, max_turns_text.?);
    }
    if (opts.allowed_tools) |t| {
        try argv.append(allocator, "--allowedTools");
        try argv.append(allocator, t);
    }
    if (opts.skip_permissions) {
        try argv.append(allocator, "--dangerously-skip-permissions");
    }
    if (opts.resume_session) |id| {
        try argv.append(allocator, "--resume");
        try argv.append(allocator, id);
    }
    if (opts.cont) try argv.append(allocator, "--continue");
    if (opts.session_id) |id| {
        try argv.append(allocator, "--session-id");
        try argv.append(allocator, id);
    }
    if (opts.verbose) try argv.append(allocator, "--verbose");

    if (opts.system_prompt) |s| {
        try argv.append(allocator, "--system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.append_system_prompt) |s| {
        try argv.append(allocator, "--append-system-prompt");
        try argv.append(allocator, s);
    }
    if (opts.permission_mode) |s| {
        try argv.append(allocator, "--permission-mode");
        try argv.append(allocator, s);
    }
    if (opts.disallowed_tools) |s| {
        try argv.append(allocator, "--disallowedTools");
        try argv.append(allocator, s);
    }
    if (opts.fallback_model) |s| {
        try argv.append(allocator, "--fallback-model");
        try argv.append(allocator, s);
    }
    if (opts.setting_sources) |s| {
        try argv.append(allocator, "--setting-sources");
        try argv.append(allocator, s);
    }
    for (opts.add_dirs) |d| {
        try argv.append(allocator, "--add-dir");
        try argv.append(allocator, d);
    }
    for (opts.mcp_configs) |c| {
        try argv.append(allocator, "--mcp-config");
        try argv.append(allocator, c);
    }

    for (opts.extra_args) |a| try argv.append(allocator, a);
    return .{
        .items = try argv.toOwnedSlice(allocator),
        .max_turns_text = max_turns_text,
    };
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
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

// ---------------------------------------------------------------------------
// Timing & watchdog constants
// ---------------------------------------------------------------------------

/// How long the PTY output stream must be quiet before we believe Ink has
/// finished its initial render and is ready to accept keystrokes.
pub const ink_quiescence_ms: u64 = 80;

/// Upper bound on how long we'll wait for quiescence.
pub const ink_max_wait_ms: u64 = 2000;

/// How long to wait between sending the prompt bytes and sending Enter.
/// Ink's bracketed-paste heuristic merges back-to-back writes; without a
/// gap, `\r` lands in the input buffer instead of triggering submit.
pub const ink_enter_debounce_ms: u64 = 120;

/// How long the PTY must be silent before we believe a pre-SessionStart
/// modal dialog is fully rendered and ready to accept a keystroke.
pub const dialog_quiescence_ms: u64 = 80;

/// Extra settle delay after the first quiet window following SessionStart on
/// fresh sessions so secondary Ink chrome (status bar, MCP notices) finishes
/// painting before we inject keystrokes.
pub const prompt_settle_ms: u64 = 100;

/// Quiet window required before typing into a `--resume` / `--continue`
/// session while the restored conversation finishes painting in Ink.
pub const resume_quiescence_ms: u64 = 400;

/// Upper bound on the resume settle wait.
pub const resume_max_wait_ms: u64 = 6000;

/// Grace window after child exit while awaiting Stop so an in-flight `Stop`
/// hook payload can finish flushing through the FIFO before failing fast.
pub const post_exit_fifo_grace_ms: u64 = 250;

/// After typing the prompt we expect claude to acknowledge it — either the
/// UserPromptSubmit hook fires or the transcript grows past the offset
/// recorded before typing. If neither happens within this window, Ink dropped
/// our keystrokes and we re-inject.
pub const prompt_accept_timeout_ms: u64 = 4000;

/// Total prompt injection attempts (initial paste + re-injections) before
/// failing fast with `RunError.PromptNotAccepted`.
pub const max_prompt_injections: u32 = 4;

/// Action chosen by the prompt-acknowledgement watchdog on each tick.
pub const WatchdogAction = enum { wait, reinject, give_up };

/// Prompt-acceptance watchdog decision. Pure so policy is unit-testable
/// without a live PTY.
pub fn promptWatchdogAction(accepted: bool, injections: u32, since_typed_ms: i64) WatchdogAction {
    if (accepted) return .wait;
    if (since_typed_ms <= @as(i64, @intCast(prompt_accept_timeout_ms))) return .wait;
    if (injections >= max_prompt_injections) return .give_up;
    return .reinject;
}

// ---------------------------------------------------------------------------
// Prompt integrity & resume helpers
// ---------------------------------------------------------------------------

/// Prompts at or below this many non-whitespace bytes skip truncation checks.
pub const prompt_truncation_min_len: usize = 64;

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\r' or b == '\t';
}

/// Byte source for `promptPayloadLen`: `text` as written, or as `PasteChunker`
/// sends it (every `~` that would complete `ESC[201~` dropped).
const PromptBytes = struct {
    text: []const u8,
    neutralize: bool,
    pos: usize = 0,
    end_match: usize = 0,

    fn next(self: *PromptBytes) ?u8 {
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            self.pos += 1;
            if (!self.neutralize) return b;
            if (self.end_match == paste_end.len - 1 and b == paste_end[paste_end.len - 1]) continue;
            if (b == paste_end[self.end_match]) {
                self.end_match += 1;
            } else {
                self.end_match = if (b == paste_end[0]) 1 else 0;
            }
            return b;
        }
        return null;
    }
};

/// Count the bytes of `text` that a terminal input parser must deliver as
/// text: everything except escape sequences (CSI / OSC / DCS / two-byte
/// escapes, same grammar as `stripCsiInto`), control bytes (`< 0x20`, `0x7f`),
/// and spaces. With `neutralize`, count the stream `PasteChunker` sends.
pub fn promptPayloadLen(text: []const u8, neutralize: bool) usize {
    var src: PromptBytes = .{ .text = text, .neutralize = neutralize };
    var n: usize = 0;
    while (src.next()) |b| {
        if (b != 0x1b) {
            if (b > 0x20 and b != 0x7f) n += 1;
            continue;
        }
        const kind = src.next() orelse break;
        switch (kind) {
            '[' => {
                var c = src.next();
                while (c != null and c.? >= 0x30 and c.? <= 0x3f) c = src.next();
                while (c != null and c.? >= 0x20 and c.? <= 0x2f) c = src.next();
                // `c` is the final byte (or end of input); it is consumed.
            },
            ']', 'P', 'X', '^', '_' => {
                // String body runs to ST (`ESC \`); OSC also ends at BEL.
                var c = src.next();
                while (c) |byte| {
                    if (kind == ']' and byte == 0x07) break;
                    if (byte == 0x1b) {
                        c = src.next();
                        if (c != null and c.? == '\\') break;
                        continue;
                    }
                    c = src.next();
                }
            },
            else => {},
        }
    }
    return n;
}

fn afterDigits(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return if (i > 0) s[i..] else null;
}

fn isPastePlaceholder(text: []const u8) bool {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "[Image #")) {
        return std.mem.eql(u8, afterDigits(s["[Image #".len..]) orelse return false, "]");
    }
    if (std.mem.startsWith(u8, s, "<pasted_content ") and std.mem.endsWith(u8, s, "</pasted_content>")) return true;
    if (!std.mem.startsWith(u8, s, "[Pasted text #")) return false;
    const count = afterDigits(s["[Pasted text #".len..]) orelse return false;
    if (!std.mem.startsWith(u8, count, " +")) return false;
    return std.mem.eql(u8, afterDigits(count[2..]) orelse return false, " lines]");
}

/// Detect whether Claude received a truncated copy of our typed prompt (e.g.
/// from a PTY buffer overflow).
///
/// Both sides are reduced to `promptPayloadLen` first, so whitespace, CRLF,
/// control bytes, and ANSI sequences never count. The expected side takes the
/// smaller of the prompt as written and the prompt as `PasteChunker` sends it:
/// neutralizing an embedded `ESC[201~` to `ESC[201` lets the input parser
/// swallow the bytes that follow as the rest of that CSI, and those bytes are
/// not a truncation. Claude's unexpanded paste placeholders (`[Pasted text
/// #...]` / `<pasted_content...`) are never truncated.
pub fn isPromptTruncated(expected: []const u8, received: []const u8) bool {
    if (expected.len <= prompt_truncation_min_len) return false;
    const floor = @min(promptPayloadLen(expected, false), promptPayloadLen(expected, true));
    if (floor <= prompt_truncation_min_len) return false;
    if (isPastePlaceholder(received)) return false;
    return promptPayloadLen(received, false) < floor;
}

/// True when the final text parsed from the transcript agrees with the
/// `last_assistant_message` field from the Stop hook payload. When no Stop
/// message is present, any parsed text agrees.
pub fn finalTextMatchesStop(final_text: []const u8, stop_last: ?[]const u8) bool {
    const want = stop_last orelse return true;
    const w = std.mem.trim(u8, want, " \t\r\n");
    if (w.len == 0) return true;
    return std.mem.eql(u8, std.mem.trim(u8, final_text, " \t\r\n"), w);
}

/// True when this invocation restores an earlier conversation, either via
/// explicit options or via pass-through `extra_args` (`--resume`, `-r`,
/// `--continue`, `-c`, `--fork-session`, `--from-pr`, `--teleport`, and the
/// `--flag=value` spellings).
pub fn isResumeRun(opts: Options) bool {
    if (opts.resume_session != null or opts.cont) return true;
    const exact = [_][]const u8{ "--resume", "-r", "--continue", "-c", "--fork-session", "--from-pr", "--teleport" };
    var flags: ExtraFlags = .{ .args = opts.extra_args };
    while (flags.next()) |arg| {
        for (exact) |flag| if (std.mem.eql(u8, arg.name, flag)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Child environment filtering
// ---------------------------------------------------------------------------

const persistence_env = "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE";

/// Return true ONLY for nested-session / parent-agent markers that must not
/// leak into a child `claude` process.
///
/// Crucially, this does NOT blanket-strip `CLAUDE_CODE_*`, so caller auth and
/// backend configuration (`CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`,
/// `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`,
/// `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE`, `CLAUDE_CONFIG_DIR`, etc.) are
/// preserved intact.
pub fn shouldStripChildEnv(name: []const u8) bool {
    const exact = [_][]const u8{
        "CLAUDECODE",
        "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
    };
    for (exact) |marker| {
        if (std.mem.eql(u8, name, marker)) return true;
    }
    const prefixes = [_][]const u8{
        "CLAUDE_CODE_SESSION_",
        "CLAUDE_CODE_PARENT_",
        "CLAUDE_CODE_SUBAGENT_",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// Build the filtered child environment from the current process environment:
/// strips nested-session markers via `shouldStripChildEnv`, drops inherited
/// `CLAUDE_P_FIFO` and `TERM`, injects
/// `TERM=xterm-256color`, and injects `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`
/// unless already set. Caller frees with `freeChildEnv`.
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

    _ = fifo_path; // retained for callers of the original API
    try appendEnv(allocator, &list, "TERM", "xterm-256color");
    if (!saw_persistence) {
        try appendEnv(allocator, &list, persistence_env, "1");
    }
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

// ---------------------------------------------------------------------------
// Chunked bracketed paste (macOS TTYHOG = 1024 safety)
// ---------------------------------------------------------------------------

/// DECSET 2004 bracketed-paste start escape sequence.
pub const paste_start = "\x1b[200~";
/// DECSET 2004 bracketed-paste end escape sequence.
pub const paste_end = "\x1b[201~";

/// Max bytes per PTY write chunk (half of macOS's 1024-byte `TTYHOG` kernel
/// PTY input queue limit so long prompts are never silently truncated).
pub const paste_chunk_bytes: usize = 512;

/// Pause between consecutive chunks so the child drains each write cleanly.
pub const paste_chunk_gap_ms: u64 = 8;

/// Splits prompt text into PTY-safe chunks: at most `paste_chunk_bytes` each,
/// never splitting a multi-byte UTF-8 codepoint across chunks, and neutralizing
/// any embedded `\x1b[201~` end-of-paste marker so untrusted prompt text cannot
/// break out of bracketed paste mode early.
pub const PasteChunker = struct {
    text: []const u8,
    pos: usize = 0,
    /// Number of leading bytes of `paste_end` that the emitted stream ends with.
    end_match: usize = 0,

    pub fn next(self: *PasteChunker, buf: *[paste_chunk_bytes]u8) ?[]const u8 {
        var n: usize = 0;
        while (self.pos < self.text.len) {
            const b = self.text[self.pos];
            if (n == buf.len) break;
            if (b >= 0xC0) {
                const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (n > 0 and n + seq_len > buf.len) break;
            }
            if (self.end_match == paste_end.len - 1 and b == paste_end[paste_end.len - 1]) {
                self.pos += 1; // drop final '~' of embedded ESC[201~
                continue;
            }
            if (b == paste_end[self.end_match]) {
                self.end_match += 1;
            } else {
                self.end_match = if (b == paste_end[0]) 1 else 0;
            }
            buf[n] = b;
            n += 1;
            self.pos += 1;
        }
        if (n == 0) return null;
        return buf[0..n];
    }
};

/// Write `text` to `sink` wrapped in bracketed-paste escapes with inter-chunk gaps.
pub fn writeBracketedPasteTo(sink: anytype, text: []const u8, gap_ns: u64) !void {
    return writePasteUntil(sink, text, gap_ns, std.math.maxInt(i128));
}

fn checkDeadline(deadline_ns: i128) RunError!void {
    if (isInterrupted()) return error.Interrupted;
    if (monotonicNs() >= deadline_ns) return error.StopTimeout;
}

fn pauseUntil(duration_ns: u64, deadline_ns: i128) RunError!void {
    const end = @min(deadline_ns, monotonicNs() + duration_ns);
    while (true) {
        try checkDeadline(deadline_ns);
        const remaining = end - monotonicNs();
        if (remaining <= 0) return;
        std.Thread.sleep(@intCast(@min(remaining, 8 * std.time.ns_per_ms)));
    }
}

fn writePasteUntil(sink: anytype, text: []const u8, gap_ns: u64, deadline_ns: i128) !void {
    try checkDeadline(deadline_ns);
    try sink.writeInput(paste_start);
    var chunker: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    while (chunker.next(&buf)) |chunk| {
        try sink.writeInput(chunk);
        try pauseUntil(gap_ns, deadline_ns);
    }
    try sink.writeInput(paste_end);
}

/// Paste `text` to `sink`, wait `enter_debounce_ns`, and send `\r` to submit.
pub fn typePromptTo(sink: anytype, text: []const u8, gap_ns: u64, enter_debounce_ns: u64) !void {
    return typePromptUntil(sink, text, gap_ns, enter_debounce_ns, std.math.maxInt(i128));
}

fn typePromptUntil(sink: anytype, text: []const u8, gap_ns: u64, enter_debounce_ns: u64, deadline_ns: i128) !void {
    try writePasteUntil(sink, text, gap_ns, deadline_ns);
    try pauseUntil(enter_debounce_ns, deadline_ns);
    try sink.writeInput("\r");
}

fn sendPrompt(session: *zmux.NativeSession, opts: Options, trace_start: i128, deadline_ns: i128) RunError!void {
    typePromptUntil(session, opts.prompt, paste_chunk_gap_ms * std.time.ns_per_ms, ink_enter_debounce_ms * std.time.ns_per_ms, deadline_ns) catch |err| switch (err) {
        error.Interrupted => return error.Interrupted,
        error.StopTimeout => return error.StopTimeout,
        // Child exit may race a final hook. Drain the FIFO before classifying it.
        else => traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(err)}),
    };
}

/// Send `text` as one DECSET 2004 bracketed paste (`\x1b[200~` ... `\x1b[201~`)
/// in UTF-8-safe `<= 512`-byte chunks spaced 8 ms apart.
pub fn writeBracketedPaste(session: *zmux.NativeSession, text: []const u8) !void {
    try writeBracketedPasteTo(session, text, paste_chunk_gap_ms * std.time.ns_per_ms);
}

/// Paste `text`, pause `ink_enter_debounce_ms` so Ink treats `\r` as submit
/// rather than part of the paste burst, then send `\r`.
pub fn typePrompt(session: *zmux.NativeSession, text: []const u8) !void {
    try typePromptTo(
        session,
        text,
        paste_chunk_gap_ms * std.time.ns_per_ms,
        ink_enter_debounce_ms * std.time.ns_per_ms,
    );
}

// ---------------------------------------------------------------------------
// Pre-SessionStart startup dialog state machine (Claude Code 2.1.330 verified)
// ---------------------------------------------------------------------------

/// Recognised interactive startup dialogs shown by Claude Code before `SessionStart`.
pub const DialogKind = enum { none, trust, bypass_permissions, dev_channels };

/// Which option the dialog's `❯` cursor currently highlights.
pub const DialogSelection = enum { affirmative, negative, unknown };

/// Parsed cursor position and option layout of a startup dialog frame.
pub const DialogAnalysis = struct {
    selection: DialogSelection = .unknown,
    /// Digit labeling the affirmative option when options are numbered (e.g.
    /// `'2'` for `"2. Yes, I accept"`). `null` on Claude 2.1.330's unnumbered
    /// workspace-trust dialog.
    affirmative_digit: ?u8 = null,
    /// True when the affirmative option appears after the cursor line in the
    /// rendered frame (e.g. Claude 2.1.330 lists `"No, exit"` above `"Yes"`).
    affirmative_below: bool = false,
};

/// Next keystroke or state transition emitted by the startup-dialog state machine.
pub const DialogAction = union(enum) {
    /// Send nothing.
    none,
    /// Press Enter. Chosen ONLY when the cursor is verified on the affirmative
    /// option.
    confirm,
    move_up,
    move_down,
    digit: u8,
    /// Stop tracking the current dialog; only newly painted output can trigger
    /// a subsequent dialog.
    settled,
};

/// Pair of detected startup dialog kind and the action to take for it.
pub const DialogDecision = struct {
    kind: DialogKind = .none,
    action: DialogAction = .none,
};

/// State for `maybeHandleStartupDialogs`; lives on `SharedState`.
pub const DialogState = struct {
    kind: DialogKind = .none,
    last: DialogAction = .none,
    last_key_ns: i64 = 0,
    /// `SharedState.bytes_seen` at the moment `last` was sent. Output past this
    /// mark is the repaint caused by that key.
    bytes_at_key: u64 = 0,
    keys_sent: u32 = 0,
    /// Set when a dialog needed a key that `dialogConfirmAllowed` forbids.
    /// No key is sent for it, now or later; `run` fails with
    /// `RunError.UnexpectedStartupDialog`.
    refused: DialogKind = .none,
};

const ExtraFlag = struct { name: []const u8, value: ?[]const u8 };

const ExtraFlags = struct {
    args: []const []const u8,

    fn next(self: *ExtraFlags) ?ExtraFlag {
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
            const required = [_][]const u8{
                "--permission-mode",    "--model",                     "--agent",           "--agents",                                "--system-prompt",          "--append-system-prompt",
                "--system-prompt-file", "--append-system-prompt-file", "--setting-sources", "--session-id",                            "--effort",                 "--permission-prompt-tool",
                "--output-format",      "--debug-file",                "--name",            "-n",                                      "--autocompact",            "--environment",
                "--permission-prompts", "--plugin-dir",                "--plugin-url",      "--remote-control-session-name-prefix",    "--system-prompt-snapshot", "--add-dir",
                "--allowedTools",       "--allowed-tools",             "--disallowedTools", "--disallowed-tools",                      "--mcp-config",             "--tools",
                "--file",               "--betas",                     "--channels",        "--dangerously-load-development-channels", "--max-turns",              "--fallback-model",
                "--settings",           "--input-format",              "--json-schema",     "--max-budget-usd",                        "--from-pr",
            };
            for (required) |flag| {
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

/// Return true when `opts` explicitly authorizes auto-confirming `kind`.
pub fn dialogConfirmAllowed(opts: Options, kind: DialogKind) bool {
    var mode = opts.permission_mode;
    var skip = opts.skip_permissions;
    var channels = false;
    var flags: ExtraFlags = .{ .args = opts.extra_args };
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

/// How long to wait for Ink to repaint after a dialog key before retrying a
/// dropped keystroke. Long enough that a slow repaint on a wrapping 2-option
/// menu is not double-toggled.
pub const dialog_retry_ms: u64 = 1500;

/// Hard cap on dialog keystrokes per session.
pub const max_dialog_keys: u32 = 16;

const cursor_glyph = "\xe2\x9d\xaf"; // UTF-8 '❯'

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

/// Match `needle` (whitespace-free) at the start of `hay`, skipping whitespace
/// in `hay`. Ink pads words with cursor moves that strip to zero spaces on a
/// first paint (`"Yes,Itrust"`) and spaces on repaints (`"Yes, I trust"`).
fn looseMatch(hay: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    for (needle) |c| {
        while (i < hay.len and isSpace(hay[i])) : (i += 1) {}
        if (i >= hay.len or hay[i] != c) return null;
        i += 1;
    }
    return i;
}

fn looseStartsWithAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (looseMatch(hay, n) != null) return true;
    }
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
    if (best.* == .none or pos >= best_pos.*) {
        best.* = kind;
        best_pos.* = pos;
    }
}

/// Identify the active startup dialog in CSI-stripped terminal output.
/// Uses latest-marker-wins so a newly painted dialog overrides stale earlier
/// text, and returns `.none` if Claude's main prompt footer painted after it.
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
    if (lastMainUiMarkerPos(stripped)) |ui_pos| {
        if (ui_pos > best_pos) return .none;
    }
    return best;
}

/// Read the cursor selection and option layout of `kind` from CSI-stripped
/// output. The last `❯` wins so a buffer holding an initial paint plus later
/// repaints reports the current cursor position.
pub fn analyzeDialog(kind: DialogKind, stripped: []const u8) DialogAnalysis {
    var out: DialogAnalysis = .{};
    if (kind == .none) return out;
    const m = dialogMarkers(kind);

    // Detect `<single-digit>. <affirmative>` anywhere; last paint wins.
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
    var rest = stripped[at + cursor_glyph.len ..];
    out.affirmative_below = looseContainsAny(rest, m.affirmative);

    // Skip an optional option number right after the pointer ("❯ 2. Yes").
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
    // A path ending in e.g. "9." can precede an unnumbered "Yes" row.
    // A recognized, unnumbered cursor row identifies the current menu layout.
    if (out.selection != .unknown and !cursor_numbered) out.affirmative_digit = null;
    return out;
}

/// Choose the safe keystroke for `kind` given its parsed selection state.
/// NEVER sends Enter unless the `❯` cursor is verified on the affirmative
/// option (Claude Code 2.1.330 lists and preselects `"No, exit"` first with no
/// option numbers, ignores digits, and wraps arrows).
pub fn chooseDialogAction(kind: DialogKind, analysis: DialogAnalysis, last: DialogAction) DialogAction {
    if (kind == .none) return .none;
    switch (analysis.selection) {
        .affirmative => return .confirm,
        .unknown => return .none,
        .negative => {
            // Numbered options (e.g. bypass-permissions "2. Yes, I accept"):
            // jump directly via the digit. If a digit was already sent and the
            // cursor did not move, fall back to arrow navigation.
            if (analysis.affirmative_digit) |d| {
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
            // Old dialog text still sits in `full`; only newly painted bytes
            // can trigger a subsequent dialog.
            const kind = classifyDialog(fresh);
            if (kind != .none) {
                return .{ .kind = kind, .action = chooseDialogAction(kind, analyzeDialog(kind, fresh), .none) };
            }
            // Enter produced zero repaint bytes: Ink dropped it. Safe to retry.
            if (last == .confirm and fresh_bytes == 0 and timed_out) {
                return .{ .kind = tracked, .action = .confirm };
            }
            return .{ .kind = tracked, .action = .none };
        },
        .move_up, .move_down, .digit => {
            const fresh_kind = classifyDialog(fresh);
            // A single read can contain both the final option repaint and the
            // prompt footer. The cursor in that repaint is already stale.
            if (fresh_kind == .none and lastMainUiMarkerPos(fresh) != null) {
                return .{ .kind = .none, .action = .settled };
            }
            const kind = if (fresh_kind != .none) fresh_kind else tracked;
            const analysis = analyzeDialog(kind, fresh);
            if (analysis.selection != .unknown) {
                return .{ .kind = kind, .action = chooseDialogAction(kind, analysis, last) };
            }
            if (!timed_out) return .{ .kind = kind, .action = .none };
            // No repaint at all: Ink dropped the keystroke; resend it.
            if (fresh_bytes == 0) return .{ .kind = kind, .action = last };
            // Output painted that is no longer this dialog (e.g., a digit
            // confirmed outright and the main UI rendered). Stop poking.
            return .{ .kind = .none, .action = .settled };
        },
    }
}

fn dialogKeyBytes(action: DialogAction, digit_buf: *[1]u8) []const u8 {
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

/// Pre-SessionStart startup dialog handler (workspace trust, bypass-permissions,
/// dev-channels). Uses zero-heap stack-allocated CSI stripping, waits for PTY
/// quiescence, verifies every cursor move on repaint before confirming with
/// `\r`, and retries dropped keystrokes safely.
pub fn maybeHandleStartupDialogs(
    opts: Options,
    trace_start: i128,
    shared: *SharedState,
    session: *zmux.NativeSession,
) void {
    const st = &shared.dialog;
    if (st.refused != .none) return;
    if (st.keys_sent >= max_dialog_keys) return;

    const now_ns: i64 = @intCast(monotonicNs());
    const last_out: i64 = shared.last_output_ns.load(.seq_cst);
    const quiescence_ns: i64 = @intCast(dialog_quiescence_ms * std.time.ns_per_ms);
    if (last_out == 0 or now_ns - last_out <= quiescence_ns) return;

    // Copy recent PTY output onto the stack under a minimal lock, then strip
    // CSI escapes into stack buffers with zero heap allocation.
    var raw_buf: [recent_capacity]u8 = undefined;
    var raw_len: usize = 0;
    var total: u64 = 0;
    {
        shared.recent_mutex.lock();
        defer shared.recent_mutex.unlock();
        total = shared.bytes_seen.load(.seq_cst);
        const recent = shared.recent.items;
        raw_len = @min(recent.len, raw_buf.len);
        @memcpy(raw_buf[0..raw_len], recent[recent.len - raw_len ..]);
    }
    if (raw_len == 0) return;

    const fresh_bytes: u64 = total -| st.bytes_at_key;
    const fresh_len: usize = @intCast(@min(fresh_bytes, @as(u64, raw_len)));

    var full_buf: [recent_capacity]u8 = undefined;
    var fresh_buf: [recent_capacity]u8 = undefined;
    const full = stripCsiInto(&full_buf, raw_buf[0..raw_len]);
    const fresh = stripCsiInto(&fresh_buf, raw_buf[raw_len - fresh_len .. raw_len]);

    const since_key_ms: i64 = @divTrunc(now_ns - st.last_key_ns, std.time.ns_per_ms);
    const decision = decideDialog(st.kind, st.last, full, fresh, fresh_bytes, since_key_ms);
    switch (decision.action) {
        .none => return,
        .settled => {
            traceFmt(opts, trace_start, "{s} dialog no longer on screen; done with it", .{@tagName(st.kind)});
            st.kind = .none;
            st.last = .settled;
            st.bytes_at_key = total;
            return;
        },
        .confirm, .move_up, .move_down, .digit => {},
    }

    // Never touch a dialog the caller did not ask for: not Enter, and not the
    // navigation keys that would line Enter up.
    if (!dialogConfirmAllowed(opts, decision.kind)) {
        traceFmt(opts, trace_start, "{s} dialog was not requested by the caller; refusing to answer it", .{@tagName(decision.kind)});
        st.kind = decision.kind;
        st.refused = decision.kind;
        return;
    }

    var digit_buf: [1]u8 = undefined;
    const keys = dialogKeyBytes(decision.action, &digit_buf);
    traceFmt(opts, trace_start, "{s} dialog: sending {s} (key {d}/{d})", .{
        @tagName(decision.kind),
        @tagName(decision.action),
        st.keys_sent + 1,
        max_dialog_keys,
    });
    session.writeInput(keys) catch |err| {
        traceFmt(opts, trace_start, "dialog key write failed: {s}", .{@errorName(err)});
    };
    st.kind = decision.kind;
    st.last = decision.action;
    st.last_key_ns = @intCast(monotonicNs());
    st.bytes_at_key = total;
    st.keys_sent += 1;
    if (decision.action == .confirm) switch (decision.kind) {
        .trust => shared.trust_dismissed = true,
        .bypass_permissions => shared.bypass_perms_accepted = true,
        .dev_channels => shared.dev_channels_confirmed = true,
        .none => {},
    };
}

// ---------------------------------------------------------------------------
// PTY DEC responder pumping & quiescence waits
// ---------------------------------------------------------------------------

/// Drain queued DEC-query responses from the reader thread to the PTY without
/// heap allocation. Every wait loop calls this so Ink never stalls waiting for
/// cursor-position or color-query replies.
pub fn flushPendingToPty(shared: *SharedState, session: *zmux.NativeSession) void {
    var buf: [512]u8 = undefined;
    while (true) {
        shared.write_mutex.lock();
        const n = @min(buf.len, shared.pending_to_pty.items.len);
        if (n > 0) {
            @memcpy(buf[0..n], shared.pending_to_pty.items[0..n]);
            shared.pending_to_pty.replaceRangeAssumeCapacity(0, n, &.{});
        }
        shared.write_mutex.unlock();
        if (n == 0) return;
        session.writeInput(buf[0..n]) catch |err| switch (err) {
            else => return,
        };
    }
}

fn sleepPumpingDec(shared: *SharedState, session: ?*zmux.NativeSession, duration_ms: u64) void {
    const end_ns = @min(shared.deadline_ns, monotonicNs() + @as(i128, duration_ms) * std.time.ns_per_ms);
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        if (isInterrupted()) return;
        const rem_ns = end_ns - monotonicNs();
        if (rem_ns <= 0) return;
        const step_ns: u64 = @intCast(@min(rem_ns, @as(i128, 15 * std.time.ns_per_ms)));
        std.Thread.sleep(step_ns);
    }
}

fn waitForOutputQuiet(
    opts: Options,
    trace_start: i128,
    shared: *SharedState,
    session: ?*zmux.NativeSession,
    quiet_ms: u64,
    max_ms: u64,
) bool {
    const quiescence_ns: i64 = @intCast(quiet_ms * std.time.ns_per_ms);
    const max_ns: i64 = @intCast(max_ms * std.time.ns_per_ms);
    const wait_started: i64 = @intCast(monotonicNs());
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        if (isInterrupted() or monotonicNs() >= shared.deadline_ns) return false;
        const now: i64 = @intCast(monotonicNs());
        if (now - wait_started > max_ns) {
            traceFmt(opts, trace_start, "Ink readiness wait hit max ({d}ms) — typing anyway", .{max_ms});
            return false;
        }
        const last: i64 = shared.last_output_ns.load(.seq_cst);
        if (last != 0 and now - last > quiescence_ns) {
            const since_ms: i64 = @divTrunc(now - last, std.time.ns_per_ms);
            const waited_ms: i64 = @divTrunc(now - wait_started, std.time.ns_per_ms);
            traceFmt(opts, trace_start, "Ink quiescent (output silent for {d}ms, waited {d}ms total)", .{ since_ms, waited_ms });
            return true;
        }
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
}

/// Block until the child PTY has been quiet for at least `ink_quiescence_ms`,
/// up to a cap of `ink_max_wait_ms`.
pub fn waitForInkQuiescent(opts: Options, trace_start: i128, shared: *SharedState) void {
    _ = waitForOutputQuiet(opts, trace_start, shared, null, ink_quiescence_ms, ink_max_wait_ms);
}

fn settleBeforePrompt(opts: Options, trace_start: i128, shared: *SharedState, session: *zmux.NativeSession) void {
    if (isResumeRun(opts)) {
        _ = waitForOutputQuiet(opts, trace_start, shared, session, resume_quiescence_ms, resume_max_wait_ms);
        return;
    }
    _ = waitForOutputQuiet(opts, trace_start, shared, session, ink_quiescence_ms, ink_max_wait_ms);
    sleepPumpingDec(shared, session, prompt_settle_ms);
    _ = waitForOutputQuiet(opts, trace_start, shared, session, ink_quiescence_ms, ink_max_wait_ms / 2);
}

/// Take `transcript_path` from a hook payload. A path with an embedded NUL
/// cannot name a file and would truncate at the syscall boundary, so it is
/// dropped as if the hook had sent none.
pub fn validateTranscriptPath(path: []const u8) bool {
    return transcript_mod.validateTranscriptPath(path);
}

/// Extract and validate `transcript_path` from a hook JSON payload.
pub fn extractSafeTranscriptPath(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    const path = (try hook_mod.extractTranscriptPath(allocator, payload_json)) orelse return null;
    if (!validateTranscriptPath(path)) {
        allocator.free(path);
        return null;
    }
    return path;
}

/// The only text `--debug` prints for a hook line: the event name and the
/// payload size. Payloads carry the user's prompt and the assistant's reply
/// and are never logged.
pub fn formatHookTrace(buf: []u8, event: hook_mod.HookEvent, payload_len: usize) []const u8 {
    return std.fmt.bufPrint(buf, "hook: {s} payload_bytes={d}", .{ @tagName(event), payload_len }) catch "hook: (trace overflow)";
}

/// Maximum non-blank lines included in a failure screen diagnostic excerpt.
pub const failure_screen_max_lines: usize = 15;
/// Maximum byte length of a failure screen diagnostic excerpt.
pub const failure_screen_max_bytes: usize = 1024;

/// Render the tail of raw PTY output for a failure diagnostic: escape
/// sequences and control bytes stripped, blank lines and trailing spaces dropped, at most
/// `failure_screen_max_lines` lines and `failure_screen_max_bytes` bytes,
/// never starting inside a UTF-8 sequence. Returns a slice of `out`.
pub fn formatFailureScreen(out: *[failure_screen_max_bytes]u8, raw: []const u8) []const u8 {
    var stripped_buf: [recent_capacity]u8 = undefined;
    const tail = raw[raw.len -| recent_capacity..];
    const stripped = stripCsiInto(&stripped_buf, tail);

    // Compact in place: one '\n' per non-blank line, no other control bytes.
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
            } else {
                n = line_start;
            }
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
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// Write a formatted failure diagnostic and optional PTY tail to stderr.
pub fn reportFailure(shared: ?*SharedState, debug_screen: bool, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var stderr = std.fs.File.stderr().writerStreaming(&buf);
    writeFailure(&stderr.interface, shared, debug_screen, fmt, args) catch return;
    stderr.interface.flush() catch |err| switch (err) {
        else => {},
    };
}

fn writeFailure(writer: *std.Io.Writer, shared: ?*SharedState, debug_screen: bool, comptime fmt: []const u8, args: anytype) !void {
    try writer.print("claude-p: " ++ fmt, args);
    const sh = shared orelse return writer.writeByte('\n');
    try writer.print(" (PTY bytes={d})\n", .{sh.bytes_seen.load(.seq_cst)});
    if (!debug_screen) return;
    var out: [failure_screen_max_bytes]u8 = undefined;
    const screen = blk: {
        sh.recent_mutex.lock();
        defer sh.recent_mutex.unlock();
        const recent = if (sh.startup_done.load(.seq_cst)) sh.post_start[0..sh.post_start_len] else sh.recent.items;
        break :blk formatFailureScreen(&out, recent);
    };
    if (screen.len > 0) try writer.print("claude-p: recent claude output:\n{s}\n", .{screen});
}

fn transcriptSize(path: ?[]const u8) ?u64 {
    const file = transcript_mod.openTranscriptRegularFile(path orelse return null) catch return null;
    defer file.close();
    return (file.stat() catch return null).size;
}

/// Return true when `hooks` contains an extra hook registered for `event`.
pub fn hasExtraHook(hooks: []const hook_mod.ExtraHook, event: []const u8) bool {
    for (hooks) |hook| if (std.mem.eql(u8, hook.event, event)) return true;
    return false;
}

/// Return the stop-confirmation grace window in nanoseconds given configured extra hooks.
pub fn stopConfirmationNs(hooks: []const hook_mod.ExtraHook) i128 {
    const ms: i128 = if (hasExtraHook(hooks, "Stop")) 2000 else 150;
    return ms * std.time.ns_per_ms;
}

/// Return true when failure screen capture is enabled by `--debug` or `CLAUDE_P_DEBUG_SCREEN=1`.
pub fn debugScreenEnabled(debug: bool) bool {
    return debug or std.mem.eql(u8, std.posix.getenv("CLAUDE_P_DEBUG_SCREEN") orelse "", "1");
}

/// Classification of a post-Stop transcript record during blocking-Stop detection.
pub const StopSummaryStatus = enum { none, confirmed, continued };

fn normalizedPromptEqual(a: []const u8, b: []const u8) bool {
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (left.next()) |token| if (!std.mem.eql(u8, token, right.next() orelse return false)) return false;
    return right.next() == null;
}

fn userPromptMatches(allocator: std.mem.Allocator, obj: std.json.ObjectMap, prompt: []const u8) !bool {
    const message = obj.get("message") orelse return false;
    if (message != .object) return false;
    const content = message.object.get("content") orelse return false;
    if (content == .string) return normalizedPromptEqual(content.string, prompt);
    if (content != .array) return false;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const part = block.object.get("text") orelse continue;
        if (part == .string) try joined.appendSlice(allocator, part.string);
    }
    return normalizedPromptEqual(joined.items, prompt);
}

/// Return true when a JSONL transcript line indicates a blocking Stop hook continued the turn.
pub fn isContinuationRecord(
    allocator: std.mem.Allocator,
    line: []const u8,
    stop_last: ?[]const u8,
    current_prompt: ?[]const u8,
) !bool {
    return try stopRecordStatus(allocator, line, stop_last, current_prompt) == .continued;
}

fn stopRecordStatus(allocator: std.mem.Allocator, line: []const u8, stop_last: ?[]const u8, current_prompt: ?[]const u8) !StopSummaryStatus {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    defer record.deinit();
    if (record.value != .object) return .none;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return .none;
    if (ty != .string) return .none;
    if (std.mem.eql(u8, ty.string, "user")) {
        if (current_prompt) |prompt| if (try userPromptMatches(allocator, obj, prompt)) return .none;
        return .continued;
    }
    if (std.mem.eql(u8, ty.string, "tool_use")) return .continued;
    if (std.mem.eql(u8, ty.string, "system")) {
        const sub = obj.get("subtype") orelse return .none;
        if (sub != .string or !std.mem.eql(u8, sub.string, "stop_hook_summary")) return .none;
        const pc = obj.get("preventedContinuation") orelse return .confirmed;
        if (pc != .bool) return .none;
        return if (pc.bool) .continued else .confirmed;
    }
    if (!std.mem.eql(u8, ty.string, "assistant")) return .none;

    const message = obj.get("message") orelse return .none;
    if (message != .object) return .none;
    const content = message.object.get("content") orelse return .none;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(allocator);
    const text = switch (content) {
        .string => content.string,
        .array => |blocks| blk: {
            for (blocks.items) |block| {
                if (block != .object) continue;
                const kind = block.object.get("type") orelse continue;
                if (kind != .string) continue;
                if (std.mem.eql(u8, kind.string, "tool_use")) return .continued;
                if (!std.mem.eql(u8, kind.string, "text")) continue;
                const part = block.object.get("text") orelse continue;
                if (part == .string) try joined.appendSlice(allocator, part.string);
            }
            break :blk joined.items;
        },
        else => return .none,
    };

    const trimmed_text = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed_text.len == 0) return .none;
    const expected = stop_last orelse return .none;
    const trimmed_stop = std.mem.trim(u8, expected, " \t\r\n");
    if (trimmed_stop.len == 0) return .none;
    // The current turn's own final assistant message often flushes to disk
    // asynchronously 20–100 ms after the Stop hook fires; do not mistake it
    // for a blocking-Stop continuation.
    if (std.mem.eql(u8, trimmed_text, trimmed_stop) or std.mem.indexOf(u8, trimmed_stop, trimmed_text) != null) {
        return .none;
    }
    return .continued;
}

/// Only consume complete records. A partial line can finish on the next poll.
pub fn scanStopRecords(allocator: std.mem.Allocator, file: std.fs.File, pos: *u64, size: u64, stop_last: ?[]const u8, prompt: []const u8) !StopSummaryStatus {
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    try reader.seekTo(pos.*);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    while (reader.logicalPos() < size) {
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try reader.interface.discardDelimiterInclusive('\n');
                pos.* = reader.logicalPos();
                continue;
            },
            else => return err,
        };
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1);
        pos.* = reader.logicalPos();
        const status = try stopRecordStatus(allocator, line.written(), stop_last, prompt);
        if (status != .none) return status;
    }
    return .none;
}

fn matchesPrompt(allocator: std.mem.Allocator, line: []const u8, prompt: []const u8) !bool {
    const record = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer record.deinit();
    if (record.value != .object) return false;
    const obj = record.value.object;
    const ty = obj.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "user") and try userPromptMatches(allocator, obj, prompt);
}

fn scanForPrompt(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) !?u64 {
    const file = try transcript_mod.openTranscriptRegularFile(path);
    defer file.close();
    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    var last: ?u64 = null;
    while (true) {
        const offset = reader.logicalPos();
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            },
            else => return err,
        };
        if (try matchesPrompt(allocator, line.written(), prompt)) last = offset;
        if (reader.interface.bufferedLen() == 0) break;
        reader.interface.toss(1); // LF
    }
    return last;
}

/// Return the byte offset of the last user record matching `prompt` in `path`, if found.
pub fn findPromptTurnOffset(allocator: std.mem.Allocator, path: []const u8, prompt: []const u8) ?u64 {
    return scanForPrompt(allocator, path, prompt) catch null;
}

fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const now: i128 = monotonicNs();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = monotonicNs();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

// ---------------------------------------------------------------------------
// Thread-shared state & zmux callback
// ---------------------------------------------------------------------------

/// Thread-shared PTY telemetry, DEC reply queue, and startup-dialog state.
pub const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    debug_screen: bool = false,
    deadline_ns: i128 = std.math.maxInt(i128),
    post_start: [2048]u8 = undefined,
    post_start_len: usize = 0,
    // Bytes the DEC responder wants written back to the PTY. Mutex-guarded.
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// `monotonicNs()` of the last PTY chunk, truncated to i64 so atomics work
    /// on all targets including x86_64-linux-musl.
    last_output_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Rolling buffer of recently-seen output for startup dialog detection.
    // Frozen once `startup_done` is set.
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    /// Freeze the startup dialog buffer. Debug diagnostics then keep only the latest 2 KiB.
    startup_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Streaming DEC-query decoder (answers queries split across PTY reads)
    /// touched only by the reader thread.
    dec: terminal_mod.DecDecoder = .{},
    trust_dismissed: bool = false,
    bypass_perms_accepted: bool = false,
    dev_channels_confirmed: bool = false,
    dialog: DialogState = .{},
};

/// Maximum bytes retained in the rolling startup-dialog PTY output buffer.
pub const recent_capacity: usize = 8192;

/// Fixed scratch capacity for `decRepliesInto` convenience replies.
pub const dec_reply_capacity = 256;

/// Fixed-buffer convenience for callers that only need a prefix of the replies.
/// The PTY callback uses its growable queue for lossless handling of arbitrary bursts.
pub fn decRepliesInto(shared: *SharedState, reply_buf: *[dec_reply_capacity]u8, data: []const u8) []const u8 {
    var backing = std.heap.FixedBufferAllocator.init(reply_buf);
    var replies = std.ArrayList(u8).initCapacity(backing.allocator(), reply_buf.len) catch return &.{};
    shared.dec.feed(backing.allocator(), data, &replies) catch |err| switch (err) {
        else => {},
    };
    return replies.items;
}

/// zmux EventSink callback invoked on the reader thread; never writes back to the PTY directly.
pub fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            // Feed the entire chunk into the growable reply queue, preserving
            // decoder state across callbacks and arbitrary query bursts.
            shared.write_mutex.lock();
            shared.dec.feed(std.heap.page_allocator, po.data, &shared.pending_to_pty) catch |err| switch (err) {
                else => {},
            };
            shared.write_mutex.unlock();
            const now_ns: i64 = @intCast(monotonicNs());
            if (shared.startup_done.load(.seq_cst)) {
                if (shared.debug_screen or shared.debug) {
                    shared.recent_mutex.lock();
                    defer shared.recent_mutex.unlock();
                    const added = @min(po.data.len, shared.post_start.len);
                    const kept = @min(shared.post_start_len, shared.post_start.len - added);
                    std.mem.copyForwards(u8, shared.post_start[0..kept], shared.post_start[shared.post_start_len - kept .. shared.post_start_len]);
                    @memcpy(shared.post_start[kept..][0..added], po.data[po.data.len - added ..]);
                    shared.post_start_len = kept + added;
                }
                _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
                shared.last_output_ns.store(now_ns, .seq_cst);
            } else {
                // Update the rolling recent-output buffer AND bytes_seen under
                // the same mutex so `maybeHandleStartupDialogs` always reads a
                // consistent `(bytes_seen, recent)` snapshot.
                shared.recent_mutex.lock();
                defer shared.recent_mutex.unlock();
                shared.recent.appendSlice(std.heap.page_allocator, po.data) catch |err| switch (err) {
                    else => {},
                };
                if (shared.recent.items.len > recent_capacity) {
                    const drop = shared.recent.items.len - recent_capacity;
                    std.mem.copyForwards(
                        u8,
                        shared.recent.items[0..recent_capacity],
                        shared.recent.items[drop..],
                    );
                    shared.recent.shrinkRetainingCapacity(recent_capacity);
                }
                _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
                shared.last_output_ns.store(now_ns, .seq_cst);
            }
            if (shared.debug) std.debug.print("zmux pane_output: {d} bytes\n", .{po.data.len});
        },
        .session_exited => |se| {
            shared.exited.store(true, .seq_cst);
            if (shared.debug) std.debug.print("zmux session_exited: code={?d} signal={?d}\n", .{ se.exit_code, se.signal });
        },
        .pane_activity, .pane_bell, .foreground_changed => {},
    }
}

// ---------------------------------------------------------------------------
// Main driver loop
// ---------------------------------------------------------------------------

const stop_failure_default_text = "claude reported StopFailure before finishing the turn";

/// Build the error `Summary` for a `StopFailure` hook: `is_error = true` (exit
/// code 1), the hook's error text when it carries one, and its `session_id`.
pub fn synthesizeStopFailureSummary(allocator: std.mem.Allocator, payload: []const u8) !transcript_mod.Summary {
    var message = try hook_mod.extractErrorMessageAlloc(allocator, payload);
    errdefer if (message) |m| allocator.free(m);
    if (message) |m| {
        if (std.mem.trim(u8, m, " \t\r\n").len == 0) {
            allocator.free(m);
            message = null;
        }
    }
    if (message == null) message = try allocator.dupe(u8, stop_failure_default_text);

    const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
    errdefer allocator.free(sid);
    const replay = try allocator.dupe(u8, "");
    const final_text = message.?;
    message = null;
    return .{
        .final_text = final_text,
        .session_id = sid,
        .is_error = true,
        .num_turns = 1,
        .total_cost_usd = 0.0,
        .duration_api_ms = 0,
        .usage = .{},
        .jsonl_replay = replay,
    };
}

/// When the transcript text still disagrees with Stop's non-empty
/// `last_assistant_message` after every retry, the transcript is stale: Stop
/// describes the turn that just ended. Replace `final_text` with Stop's text.
pub fn preferStopText(
    allocator: std.mem.Allocator,
    summary: *transcript_mod.Summary,
    stop_last: ?[]const u8,
) std.mem.Allocator.Error!void {
    if (finalTextMatchesStop(summary.final_text, stop_last)) return;
    const fresh = try allocator.dupe(u8, stop_last.?);
    allocator.free(summary.final_text);
    summary.final_text = fresh;
    summary.is_error = false;
    if (summary.subtype) |old| allocator.free(old);
    summary.subtype = null;
    if (summary.permission_denials) |old| allocator.free(old);
    summary.permission_denials = null;
    summary.usage = .{};
    summary.num_turns = 1;
    summary.total_cost_usd = 0;
    summary.duration_api_ms = 0;
}

/// Pump new transcript lines to the caller's writer and flush them. A failed
/// write (closed stdout) and OOM propagate so `run` tears the session down;
/// read errors on a file claude is still appending to are retried next tick.
pub fn pumpStream(tailer: *stream_mod.Tailer, writer: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!usize {
    const n = tailer.pump(writer) catch |e| switch (e) {
        error.WriteFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    if (n > 0) try writer.flush();
    return n;
}

/// Execute a single-shot Claude Code PTY session with interrupt scoping and full cleanup.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!Result {
    const scope = InterruptScope.enter();
    defer scope.exit();
    return runSession(allocator, opts) catch |err| {
        if (err == error.Interrupted) clearInterrupt();
        return err;
    };
}

fn runSession(caller_allocator: std.mem.Allocator, opts: Options) RunError!Result {
    try validateOptions(opts);
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;
    if (isInterrupted()) return RunError.Interrupted;
    const cwd = if (opts.cwd) |dir| try resolveCwd(caller_allocator, dir) else null;
    defer if (cwd) |dir| caller_allocator.free(dir);
    const debug_screen = debugScreenEnabled(opts.debug);

    // zmux's reader thread allocates from the allocator the session is created
    // with while this thread keeps allocating too. Route both through one lock
    // so a caller's single-threaded allocator is never raced. Memory returned
    // in `Result` is still freed with the caller's allocator: the wrapper
    // forwards every call unchanged.
    var tsa: std.heap.ThreadSafeAllocator = .{ .child_allocator = caller_allocator };
    const allocator = tsa.allocator();

    const trace_start: i128 = monotonicNs();
    const deadline_ns = if (opts.timeout_ms == 0) std.math.maxInt(i128) else trace_start + @as(i128, opts.timeout_ms) * std.time.ns_per_ms;
    trace(opts, trace_start, "run() entered");

    var harness = hook_mod.createWithOptions(allocator, .{
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
    }) catch |e| switch (e) {
        error.InvalidExtraSettings => return RunError.InvalidExtraSettings,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer harness.deinit();
    trace(opts, trace_start, "hook harness ready (FIFO + relay script + --settings)");

    const claude_bin = resolveClaudeBinary(allocator, opts.claude_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reportFailure(null, debug_screen, "claude executable not found: `{s}` is not an executable file{s}", .{
                opts.claude_path orelse "claude",
                if (opts.claude_path == null) " on PATH" else "",
            });
            return RunError.SpawnFailed;
        },
    };
    defer allocator.free(claude_bin);
    traceFmt(opts, trace_start, "claude binary: {s}", .{claude_bin});

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer argv.deinit(allocator);

    const shell_cmd = try buildShellCommandInDir(allocator, argv.items, cwd);
    defer allocator.free(shell_cmd);

    var env_list = buildChildEnv(allocator, harness.fifo_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer freeChildEnv(allocator, &env_list);

    // Open the FIFO for reading BEFORE spawning so the child's hook never
    // blocks trying to open the write side. CLOEXEC keeps the read end out of
    // the child and everything it spawns.
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined, // set after create
        .debug = opts.debug,
        .debug_screen = debug_screen,
        .deadline_ns = deadline_ns,
        .dec = .{ .rows = opts.rows, .cols = opts.cols },
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
        shared.recent_mutex.lock();
        shared.recent.deinit(std.heap.page_allocator);
        shared.recent_mutex.unlock();
    }

    const sink: zmux.native.EventSink = .{
        .context = @ptrCast(&shared),
        .emit = onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch |e| {
        reportFailure(null, debug_screen, "could not start claude under a PTY: {s}", .{@errorName(e)});
        return RunError.SpawnFailed;
    };
    shared.session = session;
    defer session.destroy();
    trace(opts, trace_start, "zmux session spawned; child claude PID up, Ink booting");

    const start_ns: i128 = trace_start;
    var state: enum { waiting_for_ready, awaiting_stop } = .waiting_for_ready;
    var first_emit_logged = false;
    var total_lines_streamed: usize = 0;

    // Prompt-acceptance tracking & `--resume` / `--continue` offset isolation.
    var prompt_typed_ns: i128 = 0;
    var prompt_injections: u32 = 0;
    var prompt_accepted = false;
    var last_progress_ns: i128 = 0;
    var last_transcript_size: u64 = 0;
    var pre_prompt_transcript_offset: ?u64 = null;
    const resumed = isResumeRun(opts);
    var exited_seen_ns: ?i128 = null;

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var stop_payload_owned: ?[]u8 = null;
    defer if (stop_payload_owned) |p| allocator.free(p);
    var stop_failed = false;
    var confirm_until: i128 = 0;
    var provisional_size: u64 = 0;
    var stop_last: ?[]u8 = null;
    defer if (stop_last) |answer| allocator.free(answer);

    const streaming = opts.output_format == .stream_json and opts.stream_writer != null;
    var tailer: ?stream_mod.Tailer = null;
    defer if (tailer) |*t| t.deinit();
    var tailer_open_attempts: u32 = 0;

    while (true) {
        // A signal handler asked us to stop: unwind through the defers above
        // so the PTY session is destroyed and the temp dir is removed.
        if (isInterrupted()) {
            trace(opts, trace_start, "interrupted; tearing down");
            return RunError.Interrupted;
        }

        // Flush any DEC-responder bytes back to the PTY.
        flushPendingToPty(&shared, session);

        // Drain ALL available FIFO bytes before checking dialogs, watchdog, or
        // child-exit so an in-flight Stop or UserPromptSubmit is never missed.
        while (!stop_failed) {
            const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => break,
            };
            if (fifo_n == 0) break;
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, fifo_buf.items, '\n') orelse break;
                const line = fifo_buf.items[0..nl];
                // With a per-run nonce, lines from any other writer are dropped.
                const maybe_ev = hook_mod.parseLineWithNonce(line, &harness.nonce);
                if (maybe_ev) |ev| {
                    if (opts.debug) {
                        // Event name and size only; see `formatHookTrace`.
                        var trace_buf: [96]u8 = undefined;
                        std.debug.print("{s}\n", .{formatHookTrace(&trace_buf, ev.event, ev.payload.len)});
                    }
                    if (state == .awaiting_stop and (ev.event == .user_prompt_submit or ev.event == .stop or ev.event == .stop_failure)) {
                        if (try extractSafeTranscriptPath(allocator, ev.payload)) |path| {
                            if (transcript_path != null and std.mem.eql(u8, transcript_path.?, path)) {
                                allocator.free(path);
                            } else {
                                if (transcript_path) |old| allocator.free(old);
                                transcript_path = path;
                                pre_prompt_transcript_offset = null;
                                if (tailer) |*t| t.deinit();
                                tailer = null;
                            }
                        }
                        // On resume the current user record may appear after UserPromptSubmit.
                        // Delay recovery until Stop to avoid streaming an earlier identical prompt.
                        if (pre_prompt_transcript_offset == null and (!resumed or ev.event != .user_prompt_submit)) {
                            if (transcript_path) |path| {
                                pre_prompt_transcript_offset = findPromptTurnOffset(allocator, path, opts.prompt);
                                if (!resumed and pre_prompt_transcript_offset == null) pre_prompt_transcript_offset = 0;
                            }
                        }
                    }
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired (Ink is up)");
                            shared.startup_done.store(true, .seq_cst);
                            if (transcript_path == null) {
                                if (try extractSafeTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path from SessionStart: {s}", .{p});
                                }
                            }
                            if (state == .waiting_for_ready) {
                                settleBeforePrompt(opts, trace_start, &shared, session);
                                if (isInterrupted()) return RunError.Interrupted;
                                pre_prompt_transcript_offset = transcriptSize(transcript_path);
                                traceFmt(opts, trace_start, "typing prompt ({d} bytes; transcript offset {?d})", .{ opts.prompt.len, pre_prompt_transcript_offset });
                                try sendPrompt(session, opts, trace_start, deadline_ns);
                                // Start acceptance timer AFTER typePrompt finishes so large
                                // chunked pastes never eat into prompt_accept_timeout_ms.
                                prompt_typed_ns = monotonicNs();
                                last_progress_ns = prompt_typed_ns;
                                last_transcript_size = pre_prompt_transcript_offset orelse 0;
                                prompt_injections = 1;
                                trace(opts, trace_start, "prompt + Enter sent; confirming acceptance");
                                state = .awaiting_stop;
                            }
                        },
                        .user_prompt_submit => {
                            if (state == .awaiting_stop) {
                                if (try hook_mod.extractPrompt(allocator, ev.payload)) |received| {
                                    defer allocator.free(received);
                                    if (isPromptTruncated(opts.prompt, received)) {
                                        traceFmt(
                                            opts,
                                            trace_start,
                                            "prompt truncated: typed {d} bytes, claude received {d} — aborting",
                                            .{ opts.prompt.len, received.len },
                                        );
                                        return RunError.PromptTruncated;
                                    }
                                }
                                trace(opts, trace_start, "UserPromptSubmit hook fired (prompt accepted)");
                                prompt_accepted = true;
                            }
                        },
                        .permission_request => if (state == .awaiting_stop and !hasExtraHook(opts.extra_hooks, "PermissionRequest")) {
                            const tool = hook_mod.extractPermissionTool(allocator, ev.payload);
                            defer if (tool) |name| allocator.free(name);
                            reportFailure(&shared, debug_screen, "awaiting Stop: permission prompt blocked ({s})", .{tool orelse "unknown tool"});
                            return error.PermissionPromptBlocked;
                        },
                        .stop, .stop_failure => if (state == .awaiting_stop) {
                            prompt_accepted = true;
                            const replacement = try allocator.dupe(u8, ev.payload);
                            if (stop_payload_owned) |old| allocator.free(old);
                            stop_payload_owned = replacement;
                            if (stop_last) |old| allocator.free(old);
                            stop_last = null;
                            stop_last = try hook_mod.extractLastAssistantMessage(allocator, ev.payload);
                            stop_failed = ev.event == .stop_failure;
                            provisional_size = transcriptSize(transcript_path) orelse 0;
                            confirm_until = @min(deadline_ns, monotonicNs() + stopConfirmationNs(opts.extra_hooks));
                            traceFmt(opts, trace_start, "terminal hook received (stop_hook_active={any})", .{hook_mod.parseStopHookActive(allocator, ev.payload)});
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
                if (stop_failed) break;
            }
        }

        if (stop_failed) break;
        if (stop_payload_owned) |payload| {
            const status: StopSummaryStatus = scan: {
                const file = transcript_mod.openTranscriptRegularFile(transcript_path orelse break :scan .none) catch break :scan .none;
                defer file.close();
                const size = (file.stat() catch break :scan .none).size;
                if (size <= provisional_size) break :scan .none;
                break :scan scanStopRecords(allocator, file, &provisional_size, size, stop_last, opts.prompt) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => .none,
                };
            };
            if (status == .continued) {
                trace(opts, trace_start, "assistant continued after provisional Stop");
                allocator.free(payload);
                stop_payload_owned = null;
            } else if (status == .confirmed or monotonicNs() >= confirm_until) break;
        }
        const now: i128 = monotonicNs();
        const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now - start_ns, std.time.ns_per_ms)));
        // `timeout_ms == 0` means no wall-clock timeout.
        if (now >= deadline_ns and stop_payload_owned == null) {
            if (state == .waiting_for_ready) {
                reportFailure(&shared, debug_screen, "timed out after {d} ms waiting for claude to start", .{elapsed_ms});
                return RunError.SessionStartTimeout;
            }
            reportFailure(&shared, debug_screen, "timed out after {d} ms waiting for claude to finish the turn", .{elapsed_ms});
            return RunError.StopTimeout;
        }

        // Fail fast if child exited early (after draining any final FIFO events).
        // Check both `shared.exited` (from `.session_exited` event) and
        // `session.state() == .terminated` (zmux can mark the session terminated
        // on PTY EOF without firing `.session_exited`).
        if (stop_payload_owned == null and (shared.exited.load(.seq_cst) or session.state() == .terminated)) {
            if (state == .waiting_for_ready) {
                reportFailure(&shared, debug_screen, "claude exited before it finished starting", .{});
                return RunError.SpawnFailed;
            }
            const first_exited = exited_seen_ns orelse blk: {
                exited_seen_ns = now;
                break :blk now;
            };
            const since_exit_ms: u64 = @intCast(@max(0, @divTrunc(now - first_exited, std.time.ns_per_ms)));
            if (since_exit_ms >= post_exit_fifo_grace_ms) {
                traceFmt(opts, trace_start, "child exited without Stop (prompt_accepted={any}) — failing fast", .{prompt_accepted});
                if (prompt_accepted) return RunError.TranscriptUnavailable;
                reportFailure(&shared, debug_screen, "claude exited before it accepted the prompt", .{});
                return RunError.PromptNotAccepted;
            }
        }

        // Pre-SessionStart modal dialogs (workspace trust, bypass-permissions,
        // development channels).
        if (state == .waiting_for_ready) {
            maybeHandleStartupDialogs(opts, trace_start, &shared, session);
            if (shared.dialog.refused != .none) {
                reportFailure(&shared, debug_screen, "claude asked to confirm a {s} dialog that this run did not request; refusing to answer it. " ++
                    "Pass --dangerously-skip-permissions, --permission-mode bypassPermissions, or " ++
                    "--dangerously-load-development-channels to approve it explicitly", .{@tagName(shared.dialog.refused)});
                return RunError.UnexpectedStartupDialog;
            }
        }

        if (opts.transcript_idle_timeout_ms) |idle_ms| {
            if (idle_ms != 0 and state == .awaiting_stop and stop_payload_owned == null and exited_seen_ns == null) {
                const size = transcriptSize(transcript_path) orelse 0;
                if (size > last_transcript_size) last_progress_ns = now;
                last_transcript_size = size;
                const last_activity = @max(last_progress_ns, shared.last_output_ns.load(.seq_cst));
                if (now - last_activity >= @as(i128, idle_ms) * std.time.ns_per_ms) return error.TranscriptStalled;
            }
        }

        // Prompt-acceptance watchdog.
        if (state == .awaiting_stop and exited_seen_ns == null) {
            if (!prompt_accepted and (pre_prompt_transcript_offset != null or !resumed) and (transcriptSize(transcript_path) orelse 0) > (pre_prompt_transcript_offset orelse 0)) {
                trace(opts, trace_start, "transcript grew past pre-prompt offset (prompt accepted)");
                prompt_accepted = true;
            }
            const since_typed_ms: i64 = @intCast(@divTrunc(monotonicNs() - prompt_typed_ns, std.time.ns_per_ms));
            switch (promptWatchdogAction(prompt_accepted, prompt_injections, since_typed_ms)) {
                .wait => {},
                .reinject => {
                    traceFmt(opts, trace_start, "prompt unacknowledged after {d}ms — re-injecting (attempt {d}/{d})", .{
                        since_typed_ms,
                        prompt_injections + 1,
                        max_prompt_injections,
                    });
                    session.writeInput("\x15") catch |err| {
                        traceFmt(opts, trace_start, "Ctrl-U before re-inject failed: {s}", .{@errorName(err)});
                    }; // Ctrl-U: clear residual input
                    sleepPumpingDec(&shared, session, ink_enter_debounce_ms);
                    _ = waitForOutputQuiet(opts, trace_start, &shared, session, ink_quiescence_ms, ink_max_wait_ms);
                    if (isInterrupted()) return RunError.Interrupted;
                    try sendPrompt(session, opts, trace_start, deadline_ns);
                    prompt_injections += 1;
                    prompt_typed_ns = monotonicNs();
                },
                .give_up => {
                    traceFmt(opts, trace_start, "prompt not accepted after {d} injection(s) — aborting", .{prompt_injections});
                    reportFailure(&shared, debug_screen, "claude did not accept the prompt after {d} attempts", .{prompt_injections});
                    return RunError.PromptNotAccepted;
                },
            }
        }

        // Open the live streaming tailer once `pre_prompt_transcript_offset` is known.
        if (streaming and tailer == null and state == .awaiting_stop and (pre_prompt_transcript_offset != null or !resumed)) {
            if (transcript_path) |p| {
                tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(allocator, p)) |t_const| {
                    var t = t_const;
                    t.pos = pre_prompt_transcript_offset orelse 0;
                    tailer = t;
                    traceFmt(opts, trace_start, "transcript opened for tailing @ {d} after {d} attempt(s): {s}", .{
                        t.pos,
                        tailer_open_attempts,
                        p,
                    });
                } else |e| switch (e) {
                    error.FileNotFound => {
                        if (tailer_open_attempts == 1) {
                            traceFmt(opts, trace_start, "transcript not yet on disk; retrying (path={s})", .{p});
                        }
                    },
                    else => {
                        traceFmt(opts, trace_start, "transcript open failed: {s}", .{@errorName(e)});
                    },
                }
            }
        }

        // Pump any newly flushed transcript lines to `stream_writer`. A failed
        // write returns, which destroys the session through the defers.
        if (streaming and tailer != null) {
            const n = try pumpStream(&tailer.?, opts.stream_writer.?);
            if (n > 0) {
                total_lines_streamed += n;
                if (!first_emit_logged) {
                    traceFmt(opts, trace_start, "first transcript line streamed ({d} line(s) in first flush)", .{n});
                    first_emit_logged = true;
                } else {
                    traceFmt(opts, trace_start, "streamed {d} more line(s) (total={d})", .{ n, total_lines_streamed });
                }
            }
        }

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Pump and parse the same bounded turn until its terminal record agrees
    // with Stop. Finishing both here avoids a second fixed stream-drain delay.
    const keep_replay = opts.retain_replay and opts.stream_writer == null;
    var summary = blk: {
        if (transcript_path) |path| if (pre_prompt_transcript_offset) |offset| {
            for (0..20) |attempt| {
                if (isInterrupted()) return error.Interrupted;
                if (streaming and tailer == null) {
                    if (stream_mod.Tailer.open(allocator, path)) |t| {
                        tailer = t;
                        tailer.?.pos = offset;
                    } else |_| {}
                }
                if (tailer) |*t| total_lines_streamed += try pumpStream(t, opts.stream_writer.?);
                if (transcript_mod.parseFileFromOffsetWithOptions(allocator, path, offset, .{ .keep_replay = keep_replay, .stop_text = if (stop_failed) null else stop_last })) |candidate| {
                    var parsed = candidate;
                    if (stop_failed) {
                        errdefer parsed.deinit(allocator);
                        if (try hook_mod.extractErrorMessageAlloc(allocator, stop_payload_owned.?)) |message| {
                            if (std.mem.trim(u8, message, " \t\r\n").len > 0) {
                                allocator.free(parsed.final_text);
                                parsed.final_text = message;
                            } else allocator.free(message);
                        }
                        parsed.is_error = true;
                        if (parsed.subtype) |sub| if (std.mem.eql(u8, sub, "success")) {
                            allocator.free(sub);
                            parsed.subtype = null;
                        };
                        break :blk parsed;
                    }
                    if ((parsed.final_text.len > 0 or parsed.is_error) and finalTextMatchesStop(parsed.final_text, stop_last)) break :blk parsed;
                    if ((attempt == 19 or monotonicNs() >= deadline_ns) and !finalTextMatchesStop(parsed.final_text, stop_last)) {
                        errdefer parsed.deinit(allocator);
                        try preferStopText(allocator, &parsed, stop_last);
                        break :blk parsed;
                    }
                    parsed.deinit(allocator);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.FileNotFound, error.NoAssistantMessage => {},
                    else => break,
                }
                if (stop_failed or attempt == 19 or monotonicNs() >= deadline_ns) break;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
        };
        if (stop_failed) break :blk try synthesizeStopFailureSummary(allocator, stop_payload_owned.?);
        if (stop_payload_owned) |payload| {
            if (stop_last) |text| {
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) return RunError.TranscriptUnavailable;
                const final_text = try allocator.dupe(u8, text);
                errdefer allocator.free(final_text);
                const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
                errdefer allocator.free(sid);
                break :blk transcript_mod.Summary{
                    .final_text = final_text,
                    .session_id = sid,
                    .is_error = false,
                    .num_turns = 1,
                    .total_cost_usd = 0.0,
                    .duration_api_ms = 0,
                    .usage = .{},
                    .jsonl_replay = try allocator.dupe(u8, ""),
                };
            }
        }
        return RunError.TranscriptUnavailable;
    };
    errdefer summary.deinit(allocator);

    if (tailer) |*t| {
        _ = try pumpStream(t, opts.stream_writer.?);
        t.flushPartial(opts.stream_writer.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WriteFailed,
        };
    }

    // Tear down the child immediately — we already have the answer.
    session.terminate();

    const total_ns: i128 = monotonicNs() - start_ns;
    const duration_ms: u64 = @intCast(@max(0, @divTrunc(total_ns, std.time.ns_per_ms)));

    var streamed = false;
    if (streaming) {
        if (opts.stream_writer) |w| {
            try emit_mod.emitJson(allocator, w, .{
                .summary = &summary,
                .duration_ms = duration_ms,
            });
            try w.flush();
            streamed = true;
            trace(opts, trace_start, "result envelope emitted; stream done");
        }
    }

    traceFmt(opts, trace_start, "run() returning (total_lines_streamed={d}, duration={d}ms)", .{ total_lines_streamed, duration_ms });
    return Result{
        .summary = summary,
        .duration_ms = duration_ms,
        .streamed = streamed,
    };
}

// ---------------------------------------------------------------------------
// CSI / OSC / DCS stripping (heap & zero-heap stack variants)
// ---------------------------------------------------------------------------

/// Strip CSI / OSC / DCS escape sequences into caller-owned buffer `out`.
/// Return the prefix of the stripped bytes that fits in `out`.
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
                if (i < bytes.len) i += 1; // final byte
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
            else => {
                i += 2;
            },
        }
    }
    return out[0..n];
}

/// Strip CSI / OSC / DCS escape sequences, returning a newly allocated slice.
pub fn stripCsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len);
    errdefer allocator.free(out);
    const n = stripCsiInto(out, bytes).len;
    return try allocator.realloc(out, n);
}

// -------- tests --------

const testing = std.testing;

test "buildArgv: minimal" {
    var argv = try buildArgv(testing.allocator, "/bin/claude", "{}", .{
        .prompt = "hi",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("/bin/claude", argv.items[0]);
    try testing.expectEqualStrings("--settings", argv.items[1]);
    try testing.expectEqualStrings("{}", argv.items[2]);
}

test "buildArgv: max-turns owned and allocation-failure safe" {
    const Ctx = struct {
        fn build(allocator: std.mem.Allocator) !void {
            var argv = try buildArgv(allocator, "claude", "{}", .{
                .prompt = "x",
                .max_turns = std.math.maxInt(u32),
                .model = "opus",
                .add_dirs = &.{ "/a", "/b" },
            });
            defer argv.deinit(allocator);
            var val: ?[]const u8 = null;
            for (argv.items, 0..) |a, idx| {
                if (std.mem.eql(u8, a, "--max-turns")) val = argv.items[idx + 1];
            }
            try testing.expectEqualStrings("4294967295", val.?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.build, .{});
}

test "buildArgv: with model + verbose" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .model = "opus",
        .verbose = true,
    });
    defer argv.deinit(testing.allocator);
    var saw_model = false;
    var saw_verbose = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--model")) saw_model = true;
        if (std.mem.eql(u8, a, "--verbose")) saw_verbose = true;
    }
    try testing.expect(saw_model);
    try testing.expect(saw_verbose);
}

test "buildArgv: dangerously-skip-permissions" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .skip_permissions = true,
    });
    defer argv.deinit(testing.allocator);
    var saw = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) saw = true;
    }
    try testing.expect(saw);
}

test "buildArgv: passthrough extra args" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .extra_args = &.{ "--include-hook-events", "--bare" },
    });
    defer argv.deinit(testing.allocator);
    var saw_hook = false;
    var saw_bare = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--include-hook-events")) saw_hook = true;
        if (std.mem.eql(u8, a, "--bare")) saw_bare = true;
    }
    try testing.expect(saw_hook);
    try testing.expect(saw_bare);
}

test "buildArgv: system-prompt + permission-mode + add-dirs + mcp-configs" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .system_prompt = "Be terse",
        .permission_mode = "acceptEdits",
        .disallowed_tools = "Bash(rm *)",
        .add_dirs = &.{ "/a", "/b" },
        .mcp_configs = &.{"server.json"},
    });
    defer argv.deinit(testing.allocator);

    var add_count: u32 = 0;
    var mcp_count: u32 = 0;
    var saw_sysp = false;
    var saw_pm = false;
    var saw_dt = false;
    for (argv.items, 0..) |a, idx| {
        if (std.mem.eql(u8, a, "--system-prompt") and std.mem.eql(u8, argv.items[idx + 1], "Be terse")) saw_sysp = true;
        if (std.mem.eql(u8, a, "--permission-mode") and std.mem.eql(u8, argv.items[idx + 1], "acceptEdits")) saw_pm = true;
        if (std.mem.eql(u8, a, "--disallowedTools") and std.mem.eql(u8, argv.items[idx + 1], "Bash(rm *)")) saw_dt = true;
        if (std.mem.eql(u8, a, "--add-dir")) add_count += 1;
        if (std.mem.eql(u8, a, "--mcp-config")) mcp_count += 1;
    }
    try testing.expect(saw_sysp and saw_pm and saw_dt);
    try testing.expectEqual(@as(u32, 2), add_count);
    try testing.expectEqual(@as(u32, 1), mcp_count);
}

test "shellQuoteArgv: simple, single-quote, and json" {
    const q1 = try shellQuoteArgv(testing.allocator, &.{ "echo", "hi" });
    defer testing.allocator.free(q1);
    try testing.expectEqualStrings("'echo' 'hi'", q1);

    const q2 = try shellQuoteArgv(testing.allocator, &.{"can't"});
    defer testing.allocator.free(q2);
    try testing.expectEqualStrings("'can'\\''t'", q2);

    const q3 = try shellQuoteArgv(testing.allocator, &.{ "claude", "--settings", "{\"hooks\":{}}" });
    defer testing.allocator.free(q3);
    try testing.expect(std.mem.indexOf(u8, q3, "{\"hooks\":{}}") != null);
}

test "run: empty prompt and invalid extra settings rejected before spawning" {
    try testing.expectError(RunError.NoPromptSupplied, run(testing.allocator, .{ .prompt = "" }));
    try testing.expectError(RunError.InvalidExtraSettings, run(testing.allocator, .{
        .prompt = "hi",
        .claude_path = "/nonexistent/claude",
        .extra_settings_json = "[1,2]",
    }));
}

test "promptWatchdogAction: waits, re-injects, and gives up cleanly" {
    const t: i64 = @intCast(prompt_accept_timeout_ms);
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, 1, 999_999));
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(true, max_prompt_injections, 999_999));
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, -1));
    try testing.expectEqual(WatchdogAction.wait, promptWatchdogAction(false, 1, t));
    try testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, 1, t + 1));
    try testing.expectEqual(WatchdogAction.reinject, promptWatchdogAction(false, max_prompt_injections - 1, t + 1));
    try testing.expectEqual(WatchdogAction.give_up, promptWatchdogAction(false, max_prompt_injections, t + 1));
}

test "isPromptTruncated: detects long truncation without false positives on CRLF or paste placeholders" {
    try testing.expect(!isPromptTruncated("hello world", "hello"));
    try testing.expect(!isPromptTruncated("a" ** 64, "a"));

    const long = "x" ** 2000;
    try testing.expect(isPromptTruncated(long, long[0..1024]));
    try testing.expect(isPromptTruncated("a" ** 65, "a" ** 64));
    try testing.expect(!isPromptTruncated(long, long));

    const typed = "  " ++ ("word " ** 30) ++ "\r\nlast line\r\n\n";
    const got = ("word " ** 30) ++ "\nlast line";
    try testing.expect(!isPromptTruncated(typed, got));

    // Legitimate long bracketed paste placeholders must NEVER trigger PromptTruncated.
    try testing.expect(!isPromptTruncated("y" ** 5000, "[Pasted text #1 +80 lines]"));
    try testing.expect(!isPromptTruncated("y" ** 5000, "<pasted_content id=\"1\">summary</pasted_content>"));
}

test "isPromptTruncated: ANSI codes, control bytes, and embedded ESC[201~ never look like truncation" {
    const body = "word " ** 40;

    // Claude receives the text with the SGR sequences and control bytes gone.
    const colored = "\x1b[1;31m" ++ body ++ "\x1b[0m\x00\x07\x7f tail";
    try testing.expect(!isPromptTruncated(colored, body ++ " tail"));
    // ...or with the sequences kept verbatim.
    try testing.expect(!isPromptTruncated(colored, colored));
    // ...or with only the ESC byte dropped.
    try testing.expect(!isPromptTruncated(colored, "[1;31m" ++ body ++ "[0m tail"));

    // PasteChunker sends ESC[201~ as ESC[201; the input parser then reads
    // "ESC[201" plus the following "12 h" as one CSI and drops it.
    const marked = body ++ paste_end ++ "12 hello" ++ body;
    try testing.expect(!isPromptTruncated(marked, body ++ "ello" ++ body));
    try testing.expect(!isPromptTruncated(marked, body ++ "[20112 hello" ++ body));
    try testing.expect(!isPromptTruncated(marked, marked));
    try testing.expectEqual(promptPayloadLen(body, false) * 2 + 4, promptPayloadLen(marked, true));
    try testing.expectEqual(promptPayloadLen(body, false) * 2 + 7, promptPayloadLen(marked, false));

    // A real loss is still caught on prompts that carry escape sequences.
    try testing.expect(isPromptTruncated(colored, body[0 .. body.len / 2]));
    try testing.expect(isPromptTruncated(marked, body));

    // OSC and DCS string bodies are not prompt text.
    try testing.expectEqual(@as(usize, 2), promptPayloadLen("a\x1b]0;title\x07b", false));
    try testing.expectEqual(@as(usize, 2), promptPayloadLen("a\x1bPq\x07zz\x1b\\b", false));
    try testing.expectEqual(@as(usize, 1), promptPayloadLen("a\x1b", false));
}

test "finalTextMatchesStop and isResumeRun" {
    try testing.expect(finalTextMatchesStop("anything", null));
    try testing.expect(finalTextMatchesStop("anything", ""));
    try testing.expect(finalTextMatchesStop("new answer\n", "new answer"));
    try testing.expect(!finalTextMatchesStop("old answer", "new answer"));

    try testing.expect(!isResumeRun(.{ .prompt = "x" }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .resume_session = "abc" }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .cont = true }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .extra_args = &.{ "--verbose", "-c" } }));
    try testing.expect(isResumeRun(.{ .prompt = "x", .extra_args = &.{"--resume=abc"} }));
    try testing.expect(!isResumeRun(.{ .prompt = "x", .extra_args = &.{"--chrome"} }));
    for ([_][]const u8{ "-r", "--continue=abc", "--fork-session", "--from-pr", "--from-pr=12", "--teleport", "--teleport=abc" }) |flag| {
        try testing.expect(isResumeRun(.{ .prompt = "x", .extra_args = &.{ "--verbose", flag } }));
    }
    for ([_][]const u8{ "--continued", "--teleporter", "--from-prs", "-rc", "--fork" }) |flag| {
        try testing.expect(!isResumeRun(.{ .prompt = "x", .extra_args = &.{flag} }));
    }
}

test "shouldStripChildEnv: strips nested-session markers while preserving auth and backend config" {
    const stripped = [_][]const u8{
        "CLAUDECODE",
        "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_SESSION_TOKEN",
        "CLAUDE_CODE_PARENT_PID",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    };
    for (stripped) |name| {
        try testing.expect(shouldStripChildEnv(name));
    }

    const preserved = [_][]const u8{
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE",
        "CLAUDE_CONFIG_DIR",
        "ANTHROPIC_API_KEY",
        "PATH",
        "HOME",
        "CLAUDECODE_X",
        "",
    };
    for (preserved) |name| {
        try testing.expect(!shouldStripChildEnv(name));
    }
}

fn testEnvValue(list: []const []u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var count: u32 = 0;
    for (list) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=').?;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            found = entry[eq + 1 ..];
            count += 1;
        }
    }
    std.debug.assert(count <= 1);
    return found;
}

test "buildChildEnvFromMap: filters nested markers, preserves auth/backend vars, drops the FIFO and sets TERM + persistence" {
    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    try map.put("PATH", "/usr/bin");
    try map.put("CLAUDECODE", "1");
    try map.put("AI_AGENT", "claude-code");
    try map.put("CLAUDE_CODE_ENTRYPOINT", "cli");
    try map.put("CLAUDE_CODE_SSE_PORT", "1234");
    try map.put("CLAUDE_CODE_SESSION_ID", "old-sess");
    try map.put("CLAUDE_CODE_PARENT_SESSION", "parent");
    try map.put("CLAUDE_CODE_SUBAGENT_ID", "sub");
    try map.put("CLAUDE_CODE_OAUTH_TOKEN", "oauth-secret");
    try map.put("CLAUDE_CODE_USE_BEDROCK", "1");
    try map.put("CLAUDE_CODE_USE_VERTEX", "1");
    try map.put("CLAUDE_CODE_USE_FOUNDRY", "1");
    try map.put("CLAUDE_CONFIG_DIR", "/cfg");
    try map.put("CLAUDE_P_FIFO", "/stale/fifo");
    try map.put("TERM", "dumb");

    var env = try buildChildEnvFromMap(testing.allocator, &map, "/tmp/x/events.fifo");
    defer freeChildEnv(testing.allocator, &env);

    try testing.expectEqualStrings("/usr/bin", testEnvValue(env.items, "PATH").?);
    try testing.expectEqualStrings("oauth-secret", testEnvValue(env.items, "CLAUDE_CODE_OAUTH_TOKEN").?);
    try testing.expectEqualStrings("1", testEnvValue(env.items, "CLAUDE_CODE_USE_BEDROCK").?);
    try testing.expectEqualStrings("1", testEnvValue(env.items, "CLAUDE_CODE_USE_VERTEX").?);
    try testing.expectEqualStrings("1", testEnvValue(env.items, "CLAUDE_CODE_USE_FOUNDRY").?);
    try testing.expectEqualStrings("/cfg", testEnvValue(env.items, "CLAUDE_CONFIG_DIR").?);
    try testing.expect(testEnvValue(env.items, "CLAUDE_P_FIFO") == null);
    try testing.expectEqualStrings("xterm-256color", testEnvValue(env.items, "TERM").?);
    try testing.expectEqualStrings("1", testEnvValue(env.items, persistence_env).?);

    try testing.expect(testEnvValue(env.items, "CLAUDECODE") == null);
    try testing.expect(testEnvValue(env.items, "AI_AGENT") == null);
    try testing.expect(testEnvValue(env.items, "CLAUDE_CODE_ENTRYPOINT") == null);
    try testing.expect(testEnvValue(env.items, "CLAUDE_CODE_SSE_PORT") == null);
    try testing.expect(testEnvValue(env.items, "CLAUDE_CODE_SESSION_ID") == null);
    try testing.expect(testEnvValue(env.items, "CLAUDE_CODE_PARENT_SESSION") == null);
    try testing.expect(testEnvValue(env.items, "CLAUDE_CODE_SUBAGENT_ID") == null);

    // Existing persistence value is preserved without duplicating.
    try map.put(persistence_env, "0");
    var env2 = try buildChildEnvFromMap(testing.allocator, &map, "/tmp/y/events.fifo");
    defer freeChildEnv(testing.allocator, &env2);
    try testing.expectEqualStrings("0", testEnvValue(env2.items, persistence_env).?);
}

test "buildChildEnvFromMap: allocation failures leak nothing" {
    const Ctx = struct {
        fn build(allocator: std.mem.Allocator, map: *const std.process.EnvMap) !void {
            var env = try buildChildEnvFromMap(allocator, map, "/f");
            freeChildEnv(allocator, &env);
        }
    };
    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    try map.put("PATH", "/usr/bin");
    try map.put("CLAUDE_CODE_OAUTH_TOKEN", "tok");
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.build, .{&map});
}

const FakePty = struct {
    bytes: std.ArrayList(u8) = .{},
    write_lens: std.ArrayList(usize) = .{},

    fn writeInput(self: *FakePty, data: []const u8) !void {
        try self.bytes.appendSlice(testing.allocator, data);
        try self.write_lens.append(testing.allocator, data.len);
    }

    fn deinit(self: *FakePty) void {
        self.bytes.deinit(testing.allocator);
        self.write_lens.deinit(testing.allocator);
    }
};

test "PasteChunker: <=512-byte chunks, UTF-8 safe, and sanitizes embedded ESC[201~" {
    // UTF-8 boundary test: 510 ASCII + 3-byte '❯' + 4-byte emoji + 600 ASCII.
    const utf8_text = ("a" ** 510) ++ "\xe2\x9d\xaf" ++ "\xf0\x9f\x98\x80" ++ ("b" ** 600);
    var chunker: PasteChunker = .{ .text = utf8_text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    var joined: std.ArrayList(u8) = .{};
    defer joined.deinit(testing.allocator);
    var first_len: usize = 0;
    while (chunker.next(&buf)) |chunk| {
        if (first_len == 0) first_len = chunk.len;
        try testing.expect(chunk.len <= paste_chunk_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try joined.appendSlice(testing.allocator, chunk);
    }
    try testing.expectEqual(@as(usize, 510), first_len);
    try testing.expectEqualStrings(utf8_text, joined.items);

    // Embedded ESC[201~ neutralization (including straddling a chunk boundary).
    const straddle = ("a" ** 509) ++ paste_end ++ "tail";
    var sc: PasteChunker = .{ .text = straddle };
    var sj: std.ArrayList(u8) = .{};
    defer sj.deinit(testing.allocator);
    while (sc.next(&buf)) |chunk| try sj.appendSlice(testing.allocator, chunk);
    try testing.expectEqualStrings(("a" ** 509) ++ "\x1b[201tail", sj.items);
    try testing.expect(std.mem.indexOf(u8, sj.items, paste_end) == null);
}

test "writeBracketedPasteTo + typePromptTo: framing, chunking, and separate Enter" {
    var pty: FakePty = .{};
    defer pty.deinit();
    const text = "line one\nline two\n" ++ ("z" ** 1500);
    try typePromptTo(&pty, text, 0, 0);

    try testing.expect(std.mem.startsWith(u8, pty.bytes.items, paste_start));
    try testing.expect(std.mem.endsWith(u8, pty.bytes.items, paste_end ++ "\r"));
    try testing.expectEqualStrings(text, pty.bytes.items[paste_start.len .. pty.bytes.items.len - paste_end.len - 1]);
    try testing.expectEqualSlices(usize, &.{ 6, 512, 512, 494, 6, 1 }, pty.write_lens.items);
}

// Live PTY captures from Claude Code 2.1.330 in an untrusted directory:
// "No, exit" is listed FIRST and preselected; NO option numbers exist.
const trust_2_1_first_paint =
    "\x1b[2GQuick\x1b[8Gsafety\x1b[15Gcheck:\x1b[22GIs\x1b[25Gthis\x1b[30Ga\x1b[32Gproject\x1b[40Gyou\x1b[44Gcreated\x1b[52Gor\x1b[55Gone\x1b[59Gyou\x1b[63Gtrust?\r\r\n" ++
    "\x1b[2Greview\x1b[68Gwhat's\x1b[75Gin\x1b[78Gthis\x1b[83Gfolder\x1b[90Gfirst.\r\r\n\r\r\n" ++
    "\x1b[2G\x1b[38;5;153m\xe2\x9d\xaf\x1b[4GNo,\x1b[8Gexit\x1b[39m\r\r\n" ++
    "\x1b[4GYes,\x1b[9GI\x1b[11Gtrust\x1b[17Gthis\x1b[22Gfolder\r\r\n\r\r\n" ++
    "\x1b[2G\x1b[38;5;246mEnter\x1b[8Gto\x1b[11Gconfirm\x1b[19G\xc2\xb7\x1b[21GEsc\x1b[25Gto\x1b[28Gcancel\x1b[39m\r\r\n\x1b[1C\x1b[4A";
const trust_2_1_repaint_yes =
    "\x1b[1D\x1b[4B\r\x1b[1C\x1b[4A \x1b[4GNo, exit\r\x1b[1C\x1b[1B\x1b[38;5;153m\xe2\x9d\xaf\x1b[4GYes, I trust this folder\x1b[39m\r\r\n\r\n\r\n\x1b[1C\x1b[3A";
const trust_2_1_repaint_no =
    "\x1b[1D\x1b[3B\r\x1b[1C\x1b[4A\x1b[38;5;153m\xe2\x9d\xaf\x1b[4GNo, exit\x1b[1C\x1b[1B\x1b[39m \x1b[4GYes, I trust this folder\r\r\n\r\n\r\n\x1b[1C\x1b[4A";

const trust_legacy = "Doyoutrustthefilesinthisfolder?\n\xe2\x9d\xaf1.Yes,proceed\n2.No,exit\nEntertoconfirm";
const bypass_dialog = "WARNING:ClaudeCoderunninginBypassPermissionsmode\nByproceeding,youacceptallresponsibility\n\xe2\x9d\xaf1.No,exit\n2.Yes,Iaccept\nEntertoconfirm";
const bypass_repaint_yes = " 1. No, exit\n\xe2\x9d\xaf 2. Yes, I accept";
const dev_channels_dialog = "WARNING:Loadingdevelopmentchannels\n\xe2\x9d\xaf1.Iamusingthisforlocaldevelopment\n2.Exit\nEntertoconfirm\xc2\xb7Esctocancel";

test "startup dialogs: Claude Code 2.1.330 trust dialog uses arrow nav + repaint verification, never digit 1 or blind Enter" {
    var first_buf: [1024]u8 = undefined;
    var yes_buf: [1024]u8 = undefined;
    var no_buf: [1024]u8 = undefined;
    const first = stripCsiInto(&first_buf, trust_2_1_first_paint);
    const yes = stripCsiInto(&yes_buf, trust_2_1_repaint_yes);
    const no = stripCsiInto(&no_buf, trust_2_1_repaint_no);

    // 1. First paint: No, exit preselected, unnumbered -> move_down, never confirm or digit.
    const a1 = analyzeDialog(.trust, first);
    try testing.expectEqual(DialogSelection.negative, a1.selection);
    try testing.expectEqual(@as(?u8, null), a1.affirmative_digit);
    try testing.expect(a1.affirmative_below);
    const d1 = decideDialog(.none, .none, first, "", 0, 0);
    try testing.expectEqual(DialogKind.trust, d1.kind);
    try testing.expectEqual(DialogAction.move_down, d1.action);

    // 2. Dropped arrow retries after dialog_retry_ms; waits before that.
    const retry: i64 = @intCast(dialog_retry_ms);
    try testing.expectEqual(DialogAction.none, decideDialog(.trust, .move_down, first, "", 0, retry - 1).action);
    try testing.expectEqual(DialogAction.move_down, decideDialog(.trust, .move_down, first, "", 0, retry).action);

    // 3. Arrow wrapped back to No -> moves again, never confirms No.
    try testing.expectEqual(DialogAction.move_down, decideDialog(.trust, .move_down, no, no, no.len, 100).action);

    // 4. Repaint verified cursor on Yes -> confirm with Enter.
    const d3 = decideDialog(.trust, .move_down, first, yes, trust_2_1_repaint_yes.len, 200);
    try testing.expectEqual(DialogKind.trust, d3.kind);
    try testing.expectEqual(DialogAction.confirm, d3.action);

    // 5. After Enter repaints main UI, old text in `full` never re-triggers.
    try testing.expectEqual(DialogAction.none, decideDialog(.trust, .confirm, first, "Welcome ? for shortcuts", 23, 5000).action);
}

test "startup dialogs: bypass-permissions (digit 2 + verify + Enter), dev-channels, and latest-dialog-wins" {
    const d1 = decideDialog(.none, .none, bypass_dialog, "", 0, 0);
    try testing.expectEqual(DialogKind.bypass_permissions, d1.kind);
    try testing.expectEqual(DialogAction{ .digit = '2' }, d1.action);

    // Repaint shows cursor on 2. Yes, I accept -> Enter.
    const d2 = decideDialog(.bypass_permissions, .{ .digit = '2' }, bypass_dialog, bypass_repaint_yes, bypass_repaint_yes.len, 100);
    try testing.expectEqual(DialogAction.confirm, d2.action);

    // If digit was ignored and cursor stayed on No -> fall back to arrow.
    try testing.expectEqual(
        DialogAction.move_down,
        chooseDialogAction(.bypass_permissions, .{ .selection = .negative, .affirmative_digit = '2', .affirmative_below = true }, .{ .digit = '2' }),
    );

    // If digit confirmed outright and main UI painted -> settled.
    const main_ui = "\xe2\x9d\xaf Try \"write a test\"";
    const d3 = decideDialog(.bypass_permissions, .{ .digit = '2' }, bypass_dialog, main_ui, main_ui.len, @intCast(dialog_retry_ms));
    try testing.expectEqual(DialogAction.settled, d3.action);

    // Dev-channels & legacy trust with cursor already on affirmative -> confirm.
    try testing.expectEqual(DialogAction.confirm, decideDialog(.none, .none, dev_channels_dialog, "", 0, 0).action);
    try testing.expectEqual(DialogAction.confirm, decideDialog(.none, .none, trust_legacy, "", 0, 0).action);

    // Main UI footer suppresses stale dialog markers.
    try testing.expectEqual(DialogKind.none, classifyDialog(bypass_dialog ++ "\n? for shortcuts\n"));
}

test "stripCsiInto matches stripCsi" {
    const raw = "\x1b[1mDo\x1b[1Cyou\x1b]0;title\x07 trust\x1b[0m";
    var buf: [64]u8 = undefined;
    const stack_res = stripCsiInto(&buf, raw);
    const heap_res = try stripCsi(testing.allocator, raw);
    defer testing.allocator.free(heap_res);
    try testing.expectEqualStrings("Doyou trust", stack_res);
    try testing.expectEqualStrings(stack_res, heap_res);
}

test "run: handles 2.1.330 trust dialog, chunked bracketed paste, and resumed transcript isolation end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\
    ++ fixture_relay ++
        \\down=$(printf '\033[B')
        \\enter=$(printf '\r')
        \\printf 'Quick safety check: Is this a project you trust?\r\nreview this folder first.\r\n❯ No, exit\r\n  Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 3)" = "$down" ]
        \\printf '\r  No, exit\r\n❯ Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"previous turn"}]}}' > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\{ printf '\033[200~'; cat prompt; printf '\033[201~\r'; } > expected
        \\read_bytes "$(wc -c < expected | tr -d ' ')" | cmp - expected
        \\hook UserPromptSubmit < submit.json
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"current turn"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"current turn"}' "$file" | hook Stop
        \\
    ;
    {
        const f = try tmp.dir.createFile("mock-claude", .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(fixture);
    }
    const prompt = ("a" ** 511 ++ "🌿\n") ** 6;
    try tmp.dir.writeFile(.{ .sub_path = "prompt", .data = prompt });
    const submit = try std.json.Stringify.valueAlloc(testing.allocator, .{ .prompt = prompt }, .{});
    defer testing.allocator.free(submit);
    try tmp.dir.writeFile(.{ .sub_path = "submit.json", .data = submit });

    const program = try tmp.dir.realpathAlloc(testing.allocator, "mock-claude");
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = prompt,
        .cont = true,
        .timeout_ms = 15_000,
        .output_format = .stream_json,
        .stream_writer = &output.writer,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("current turn", result.summary.final_text);
    try testing.expectEqual(@as(u32, 1), result.summary.num_turns);
    try testing.expect(std.mem.indexOf(u8, output.written(), "current turn") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "previous turn") == null);
}

test "run: fails fast if child exits early without Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture =
        \\#!/bin/sh
        \\set -eu
        \\
    ++ fixture_relay ++
        \\printf 'Ready\r\n'
        \\printf '{"transcript_path":"%s/none.jsonl"}' "$PWD" | hook SessionStart
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\exit 1
        \\
    ;
    {
        const f = try tmp.dir.createFile("crash-claude", .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(fixture);
    }
    const program = try tmp.dir.realpathAlloc(testing.allocator, "crash-claude");
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const t0 = std.time.milliTimestamp();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ms = std.time.milliTimestamp() - t0;
    try testing.expectError(RunError.TranscriptUnavailable, err);
    // Must fail fast (well under the 30s timeout).
    try testing.expect(elapsed_ms < 5_000);
}

// -------- Round 1 review fixes --------

fn writeFixture(dir: std.fs.Dir, name: []const u8, body: []const u8) ![]u8 {
    {
        const f = try dir.createFile(name, .{ .mode = 0o700 });
        defer f.close();
        try f.writeAll(body);
    }
    return dir.realpathAlloc(testing.allocator, name);
}

/// Count `claude-p-<pid>-*` harness directories left under the temp root.
fn leftoverHarnessDirs() !usize {
    const root = std.posix.getenv("TMPDIR") orelse "/tmp";
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "claude-p-{d}-", .{std.c.getpid()});
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) n += 1;
    }
    return n;
}

test "monotonicNs: never goes backwards and tracks real time" {
    const a = monotonicNs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b - a >= 2 * std.time.ns_per_ms);
    try testing.expect(b - a < 5 * std.time.ns_per_s);
    var prev = b;
    for (0..1000) |_| {
        const now = monotonicNs();
        try testing.expect(now >= prev);
        prev = now;
    }
    // Fits the i64 atomics in SharedState.
    _ = @as(i64, @intCast(prev));
}

test "validateCwd: accepts directories, rejects files, missing paths, and NUL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain", .data = "x" });
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const file_path = try tmp.dir.realpathAlloc(testing.allocator, "plain");
    defer testing.allocator.free(file_path);

    try validateCwd(null);
    try validateCwd(dir_path);
    try testing.expectError(RunError.InvalidCwd, validateCwd(file_path));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/nonexistent/claude-p/cwd"));
    try testing.expectError(RunError.InvalidCwd, validateCwd(""));
    try testing.expectError(RunError.InvalidCwd, validateCwd("/tmp\x00/x"));

    // run() refuses before it creates a harness or spawns anything.
    const before = try leftoverHarnessDirs();
    try testing.expectError(RunError.InvalidCwd, run(testing.allocator, .{
        .prompt = "hi",
        .cwd = "/nonexistent/claude-p/cwd",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "resolveClaudeBinaryIn: PATH search, explicit override, and non-executables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("bin/claude-dir");
    try tmp.dir.makePath("shadow/claude"); // a directory named claude is skipped
    try tmp.dir.writeFile(.{ .sub_path = "bin/not-exec", .data = "x" });
    const exe = try writeFixture(tmp.dir, "bin/claude", "#!/bin/sh\n");
    defer testing.allocator.free(exe);
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const path_env = try std.fmt.allocPrint(testing.allocator, "{s}/missing:{s}/empty:{s}/shadow:{s}/bin:/usr/bin", .{ root, root, root, root });
    defer testing.allocator.free(path_env);

    const found = try resolveClaudeBinaryIn(testing.allocator, null, path_env);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(exe, found);

    const by_path = try resolveClaudeBinaryIn(testing.allocator, exe, "");
    defer testing.allocator.free(by_path);
    try testing.expectEqualStrings(exe, by_path);

    const sh = try resolveClaudeBinaryIn(testing.allocator, "sh", "/nonexistent:/bin");
    defer testing.allocator.free(sh);
    const resolved_sh = try std.fs.cwd().realpathAlloc(testing.allocator, "/bin/sh");
    defer testing.allocator.free(resolved_sh);
    try testing.expectEqualStrings(resolved_sh, sh);

    const empty_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty", .{root});
    defer testing.allocator.free(empty_path);
    const not_exec = try std.fmt.allocPrint(testing.allocator, "{s}/bin/not-exec", .{root});
    defer testing.allocator.free(not_exec);
    const a_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin/claude-dir", .{root});
    defer testing.allocator.free(a_dir);
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, null, empty_path));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, not_exec, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, a_dir, path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "/nonexistent/claude", path_env));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "not-exec", path_env));

    const Ctx = struct {
        fn resolve(allocator: std.mem.Allocator, env: []const u8, want: []const u8) !void {
            const got = try resolveClaudeBinaryIn(allocator, null, env);
            defer allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.resolve, .{ path_env, exe });
}

test "run: a missing claude binary fails before spawning and leaves no temp dir" {
    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.SpawnFailed, run(testing.allocator, .{
        .prompt = "hi",
        .claude_path = "/nonexistent/claude",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 2 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "buildShellCommand: exec-prefixes the quoted argv" {
    const cmd = try buildShellCommand(testing.allocator, &.{ "/opt/my bin/claude", "--model", "it's" });
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exec '/opt/my bin/claude' '--model' 'it'\\''s'", cmd);
}

test "formatHookTrace: prints the event name and payload size, never the payload" {
    const secret = "{\"prompt\":\"my password is hunter2\",\"last_assistant_message\":\"TOP-SECRET-REPLY\"}";
    var buf: [96]u8 = undefined;
    const line = formatHookTrace(&buf, .user_prompt_submit, secret.len);
    try testing.expectEqualStrings("hook: user_prompt_submit payload_bytes=79", line);
    try testing.expect(std.mem.indexOf(u8, line, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, line, "SECRET") == null);
    // The signature takes a length, so no caller can hand it payload bytes.
    const params = @typeInfo(@TypeOf(formatHookTrace)).@"fn".params;
    try testing.expectEqual(@as(usize, 3), params.len);
    try testing.expect(params[2].type.? == usize);
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("hook: (trace overflow)", formatHookTrace(&tiny, .stop, 1));
}

test "formatFailureScreen: strips escapes, drops blank lines, keeps the last 15 lines within 1024 bytes" {
    var out: [failure_screen_max_bytes]u8 = undefined;
    try testing.expectEqualStrings("", formatFailureScreen(&out, ""));
    try testing.expectEqualStrings("", formatFailureScreen(&out, "\r\n \x1b[2J\r\n"));
    try testing.expectEqualStrings(
        "sh: claude: command not found\nbye",
        formatFailureScreen(&out, "\x1b[31msh: claude:\x07 command not found\x1b[0m\r\r\n\r\n   \r\nbye\r\n"),
    );

    var many: std.ArrayList(u8) = .{};
    defer many.deinit(testing.allocator);
    for (0..40) |i| try many.writer(testing.allocator).print("\x1b[1mline {d}\x1b[0m\r\n\r\n", .{i});
    const tail = formatFailureScreen(&out, many.items);
    try testing.expect(std.mem.startsWith(u8, tail, "line 25\n"));
    try testing.expect(std.mem.endsWith(u8, tail, "\nline 39"));
    try testing.expectEqual(@as(usize, 14), std.mem.count(u8, tail, "\n"));

    // One very long line: bounded to 1024 bytes on a UTF-8 boundary.
    const wide = "\xe2\x9d\xaf" ** 2000;
    const cut = formatFailureScreen(&out, wide);
    try testing.expect(cut.len <= failure_screen_max_bytes);
    try testing.expect(cut.len > failure_screen_max_bytes - 4);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "extractSafeTranscriptPath: drops paths with an embedded NUL" {
    const ok = (try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a.jsonl\"}")).?;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("/tmp/a.jsonl", ok);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"/tmp/a\\u0000/../../etc/passwd\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{\"transcript_path\":\"\"}")) == null);
    try testing.expect((try extractSafeTranscriptPath(testing.allocator, "{}")) == null);
}

test "dialogConfirmAllowed: ordinary runs never approve bypass-permissions or dev-channels dialogs" {
    const plain: Options = .{ .prompt = "x" };
    try testing.expect(dialogConfirmAllowed(plain, .trust));
    try testing.expect(dialogConfirmAllowed(plain, .none));
    try testing.expect(!dialogConfirmAllowed(plain, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(plain, .dev_channels));

    // Flags that do not ask for bypass do not unlock it.
    const near: Options = .{
        .prompt = "--dangerously-skip-permissions",
        .permission_mode = "acceptEdits",
        .extra_args = &.{ "--permission-mode", "plan", "--permission-mode=acceptEdits", "bypassPermissions", "--dangerously-skip-permissions-x", "--allow-dangerously-skip-permissions" },
    };
    try testing.expect(!dialogConfirmAllowed(near, .bypass_permissions));
    try testing.expect(!dialogConfirmAllowed(near, .dev_channels));

    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .permission_mode = "bypassPermissions" }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-skip-permissions"} }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{ "--permission-mode", "bypassPermissions" } }, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--permission-mode=bypassPermissions"} }, .bypass_permissions));
    // Bypass intent does not approve development channels, and vice versa.
    try testing.expect(!dialogConfirmAllowed(.{ .prompt = "x", .skip_permissions = true }, .dev_channels));
    const dev: Options = .{ .prompt = "x", .extra_args = &.{ "--dangerously-load-development-channels", "server:x" } };
    try testing.expect(dialogConfirmAllowed(dev, .dev_channels));
    try testing.expect(!dialogConfirmAllowed(dev, .bypass_permissions));
    try testing.expect(dialogConfirmAllowed(.{ .prompt = "x", .extra_args = &.{"--dangerously-load-development-channels=server:x"} }, .dev_channels));
}

test "run: refuses an unrequested bypass-permissions dialog without sending a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Any key the driver sends lands in `keys`; the fixture then exits.
    const program = try writeFixture(tmp.dir, "bypass-claude",
        \\#!/bin/sh
        \\stty raw -echo
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\dd bs=1 count=1 > keys 2>/dev/null
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    const before = try leftoverHarnessDirs();
    const t0 = monotonicNs();
    try testing.expectError(RunError.UnexpectedStartupDialog, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - t0 < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
    const keys = tmp.dir.readFileAlloc(testing.allocator, "keys", 16) catch |e| switch (e) {
        error.FileNotFound => try testing.allocator.dupe(u8, ""),
        else => return e,
    };
    defer testing.allocator.free(keys);
    try testing.expectEqualStrings("", keys);
}

test "run: approves a requested bypass dialog, runs with timeout 0 under exec, and prefers Stop text over a stale transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "bypass-ok-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\echo "$PPID" > ppid
        \\read_bytes() { dd bs=1 count="$1" 2>/dev/null; }
        \\# Events go through the real relay script, exactly as claude sends them.
        \\
    ++ fixture_relay ++
        \\enter=$(printf '\r')
        \\printf 'WARNING: Claude Code running in Bypass Permissions mode\r\nBy proceeding, you accept all responsibility\r\n❯ 1. No, exit\r\n  2. Yes, I accept\r\nEnter to confirm\r\n'
        \\[ "$(read_bytes 1)" = "2" ]
        \\printf '\r  1. No, exit\r\n❯ 2. Yes, I accept\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\: > "$file"
        \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
        \\read_bytes 18 > /dev/null
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"stale text"}]}}' >> "$file"
        \\printf '{"transcript_path":"%s","last_assistant_message":"fresh text"}' "$file" | hook Stop
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;

    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .skip_permissions = true,
        .timeout_ms = 0, // no wall-clock timeout
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("fresh text", result.summary.final_text);
    try testing.expect(!result.summary.is_error);

    // `exec` made the fixture the PTY child itself: its parent is this process.
    const ppid_text = try tmp.dir.readFileAlloc(testing.allocator, "ppid", 32);
    defer testing.allocator.free(ppid_text);
    const ppid = try std.fmt.parseInt(i64, std.mem.trim(u8, ppid_text, " \r\n"), 10);
    try testing.expectEqual(@as(i64, std.c.getpid()), ppid);
}

test "preferStopText: replaces stale text, keeps agreeing text and clears stale error metadata" {
    const a = testing.allocator;
    const make = struct {
        fn summary(text: []const u8, is_error: bool) !transcript_mod.Summary {
            return .{
                .final_text = try testing.allocator.dupe(u8, text),
                .session_id = try testing.allocator.dupe(u8, "s"),
                .is_error = is_error,
                .num_turns = 1,
                .total_cost_usd = 0,
                .duration_api_ms = 0,
                .usage = .{},
                .jsonl_replay = try testing.allocator.dupe(u8, ""),
            };
        }
    }.summary;

    var stale = try make("old answer", false);
    defer stale.deinit(a);
    try preferStopText(a, &stale, "new answer");
    try testing.expectEqualStrings("new answer", stale.final_text);

    var same = try make("answer\n", false);
    defer same.deinit(a);
    try preferStopText(a, &same, " answer");
    try testing.expectEqualStrings("answer\n", same.final_text);

    var no_stop = try make("answer", false);
    defer no_stop.deinit(a);
    try preferStopText(a, &no_stop, null);
    try preferStopText(a, &no_stop, " \n");
    try testing.expectEqualStrings("answer", no_stop.final_text);

    var failed = try make("API Error: 529", true);
    defer failed.deinit(a);
    try preferStopText(a, &failed, "something else");
    try testing.expectEqualStrings("something else", failed.final_text);
    try testing.expect(!failed.is_error);

    // Allocation failure leaves the summary intact.
    var keep = try make("old", false);
    defer keep.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, preferStopText(failing.allocator(), &keep, "new"));
    try testing.expectEqualStrings("old", keep.final_text);
}

test "synthesizeStopFailureSummary: error summary with exit code 1" {
    const Ctx = struct {
        fn check(allocator: std.mem.Allocator, payload: []const u8, want_text: []const u8, want_sid: []const u8) !void {
            var result: Result = .{
                .summary = try synthesizeStopFailureSummary(allocator, payload),
                .duration_ms = 1,
            };
            defer result.deinit(allocator);
            try testing.expect(result.summary.is_error);
            try testing.expectEqual(@as(u8, 1), result.exitCode());
            try testing.expectEqualStrings(want_text, result.summary.final_text);
            try testing.expectEqualStrings(want_sid, result.summary.session_id);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{
        "{\"session_id\":\"abc\",\"last_assistant_message\":\"API Error: overloaded\"}",
        "API Error: overloaded",
        "abc",
    });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{ "{\"last_assistant_message\":\"  \"}", stop_failure_default_text, "" });
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.check, .{ "not json", stop_failure_default_text, "" });
}

test "run: a StopFailure hook ends the run at once with an error result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "failing-claude",
        \\#!/bin/sh
        \\set -eu
        \\stty raw -echo
        \\
    ++ fixture_relay ++
        \\printf 'Ready ? for shortcuts'
        \\printf '{"session_id":"sess-1"}' | hook SessionStart
        \\dd bs=1 count=18 > /dev/null 2>&1
        \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
        \\printf '{"session_id":"sess-1","error":"API Error: overloaded"}' | hook StopFailure
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);

    const t0 = monotonicNs();
    var result = try run(testing.allocator, .{
        .claude_path = program,
        .cwd = std.fs.path.dirname(program).?,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(monotonicNs() - t0 < 10 * std.time.ns_per_s);
    try testing.expect(result.summary.is_error);
    try testing.expectEqual(@as(u8, 1), result.exitCode());
    try testing.expectEqualStrings("API Error: overloaded", result.summary.final_text);
    try testing.expectEqualStrings("sess-1", result.summary.session_id);
}

test "pumpStream: a failed stdout write propagates instead of being swallowed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.jsonl", .data = "{\"a\":1}\n{\"b\":2}\npartial" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "t.jsonl");
    defer testing.allocator.free(path);

    {
        var tailer = try stream_mod.Tailer.open(testing.allocator, path);
        defer tailer.deinit();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 2), try pumpStream(&tailer, &out.writer));
        try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", out.written());
        try testing.expectEqual(@as(usize, 0), try pumpStream(&tailer, &out.writer));
    }
    {
        var tailer = try stream_mod.Tailer.open(testing.allocator, path);
        defer tailer.deinit();
        var closed: std.Io.Writer = .failing;
        try testing.expectError(error.WriteFailed, pumpStream(&tailer, &closed));
    }
}

test "onZmuxEvent: stops copying into `recent` after startup and queues complete DEC replies" {
    var shared: SharedState = .{ .session = undefined, .debug = false };
    defer shared.pending_to_pty.deinit(std.heap.page_allocator);
    defer shared.recent.deinit(std.heap.page_allocator);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "hello\x1b[c" } });
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 8), shared.bytes_seen.load(.seq_cst));
    const first_ns = shared.last_output_ns.load(.seq_cst);
    try testing.expect(first_ns != 0);

    shared.startup_done.store(true, .seq_cst);
    std.Thread.sleep(std.time.ns_per_ms);
    // Holding recent_mutex proves the post-startup path never takes it.
    shared.recent_mutex.lock();
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "world\x1b[6n" } });
    shared.recent_mutex.unlock();
    try testing.expectEqualStrings("hello\x1b[c", shared.recent.items);
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R", shared.pending_to_pty.items);
    try testing.expectEqual(@as(u64, 17), shared.bytes_seen.load(.seq_cst));
    try testing.expect(shared.last_output_ns.load(.seq_cst) > first_ns);

    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "\x1b[c" ** 100 } });
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[1;1R" ++ "\x1b[?1;2c" ** 100, shared.pending_to_pty.items);
}

/// Wait until the fixture has written `dir/pid` (it is running), then interrupt.
fn interruptOnceRunning(dir: std.fs.Dir) void {
    for (0..1000) |_| {
        if (dir.statFile("pid")) |st| {
            if (st.size > 1) break;
        } else |_| {}
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.Thread.sleep(100 * std.time.ns_per_ms);
    requestInterrupt();
}

test "run: requestInterrupt returns Interrupted and cleans up the session and temp dir" {
    defer interrupted.store(false, .seq_cst);
    try testing.expect(!isInterrupted());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const program = try writeFixture(tmp.dir, "slow-claude",
        \\#!/bin/sh
        \\echo $$ > pid
        \\printf 'Booting\r\n'
        \\sleep 30
        \\
    );
    defer testing.allocator.free(program);
    const cwd = std.fs.path.dirname(program).?;
    const before = try leftoverHarnessDirs();

    // Mid-run: the signal arrives while run() waits for SessionStart.
    const thread = try std.Thread.spawn(.{}, interruptOnceRunning, .{tmp.dir});
    const t0 = monotonicNs();
    const err = run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
        .timeout_ms = 30_000,
    });
    const elapsed_ns = monotonicNs() - t0;
    thread.join();
    try testing.expectError(RunError.Interrupted, err);
    try testing.expect(elapsed_ns < 15 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());

    // The PTY child is gone once run() has unwound.
    const pid_text = try tmp.dir.readFileAlloc(testing.allocator, "pid", 32);
    defer testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n"), 10);
    var gone = false;
    for (0..100) |_| {
        std.posix.kill(pid, 0) catch {
            gone = true;
            break;
        };
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try testing.expect(gone);

    try testing.expect(!isInterrupted());
    requestInterrupt();
    // Already interrupted: run() returns before creating anything.
    try testing.expectError(RunError.Interrupted, run(testing.allocator, .{
        .claude_path = program,
        .cwd = cwd,
        .prompt = "hello",
    }));
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

const fixture_relay =
    \\relay=$(python3 -c 'import json,shlex,sys; print(shlex.split(json.loads(sys.argv[1])["hooks"]["Stop"][0]["hooks"][0]["command"])[0])' "$2")
    \\hook() { "$relay" "$1"; }
    \\
;

const fixture_shell =
    \\#!/bin/sh
    \\set -eu
    \\stty raw -echo
    \\[ "$1" = --settings ]
    \\
++ fixture_relay ++
    \\printf 'Ready'
    \\file="$PWD/session.jsonl"
    \\: > "$file"
    \\printf '{"transcript_path":"%s"}' "$file" | hook SessionStart
    \\dd bs=1 count=18 of=/dev/null 2>/dev/null
    \\printf '{"prompt":"hello"}' | hook UserPromptSubmit
    \\
;

test "run: PermissionRequest fails before Stop timeout and releases the hook harness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"tool_name":"Bash"}' | hook PermissionRequest
        \\sleep 30
    );
    defer testing.allocator.free(exe);
    const before = try leftoverHarnessDirs();
    const started = monotonicNs();
    try testing.expectError(error.PermissionPromptBlocked, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 30_000,
    }));
    try testing.expect(monotonicNs() - started < 5 * std.time.ns_per_s);
    try testing.expectEqual(before, try leftoverHarnessDirs());
}

test "run: configured permission and slow Stop hooks can complete the turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{}' | hook PermissionRequest
        \\printf '{"last_assistant_message":"draft"}' | hook Stop
        \\sleep 0.5
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":true}' >> "$file"
        \\sleep 1.65
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}],"usage":{"output_tokens":3}}}' >> "$file"
        \\printf '{"last_assistant_message":"final"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\# Waiting the full fallback after confirmation would consume this later failure.
        \\sleep 0.7
        \\printf '{"error":"late failure"}' | hook StopFailure
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .extra_hooks = &.{ .{ .event = "PermissionRequest", .command = "true" }, .{ .event = "Stop", .command = "sleep 0.5" } },
        .timeout_ms = 8000,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("final", result.summary.final_text);
    try testing.expectEqual(3, result.summary.usage.output_tokens);
}

test "run: continued assistant output supersedes provisional Stop until the second Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "0.03", "0.2" }) |delay| {
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
            \\printf '{"last_assistant_message":"draft"}' | hook Stop
            \\sleep 0.04
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}' >> "$file"
            \\
        ++ "sleep " ++ delay ++ "\n" ++
            \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"second answer"}],"usage":{"output_tokens":3}}}' >> "$file"
            \\printf '{"last_assistant_message":"second answer","stop_hook_active":true}' | hook Stop
        );
        defer testing.allocator.free(exe);
        var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("second answer", result.summary.final_text);
        try testing.expectEqual(3, result.summary.usage.output_tokens);
        var replay: std.Io.Writer.Allocating = .init(testing.allocator);
        defer replay.deinit();
        try result.write(testing.allocator, &replay.writer, .stream_json);
        try testing.expect(std.mem.indexOf(u8, replay.written(), "tool_use") != null);
    }
}

test "a post-Stop user record only continues a turn when it differs from the current prompt" {
    const line =
        \\{"type":"user","message":{"content":"hello\nworld"}}
    ;
    try testing.expect(!try isContinuationRecord(testing.allocator, line, "done", "hello world"));
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", "different prompt"));
    try testing.expect(try isContinuationRecord(testing.allocator, line, "done", null));
}

test "run: late-flushed current user and final assistant records preserve provisional Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock-late-flush", fixture_shell ++
        \\printf '{"last_assistant_message":"PONG"}' | hook Stop
        \\sleep 0.05
        \\printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"  hello  "}]}}' >> "$file"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"}],"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '%s\n' '{"type":"system","subtype":"stop_hook_summary","preventedContinuation":false}' >> "$file"
        \\exec sleep 5
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("PONG", result.summary.final_text);
    try testing.expectEqual(@as(u64, 5), result.summary.usage.output_tokens);
}

test "run: resumed transcript path change isolates a matched turn or uses Stop alone" {
    const new_path =
        \\file="$PWD/resumed.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"private history"}]}}' > "$file"
        \\
    ;
    const matched =
        \\printf '%s\n' '{"type":"user","message":{"content":"hello"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}],"usage":{"input_tokens":9}}}' >> "$file"
        \\
    ;
    const stop =
        \\printf '{"transcript_path":"%s","last_assistant_message":"answer"}' "$file" | hook Stop
    ;
    inline for (.{ true, false }) |has_match| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++ new_path ++ (if (has_match) matched else "") ++ stop);
        defer testing.allocator.free(exe);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var result = try run(testing.allocator, .{
            .prompt = "hello",
            .cont = true,
            .cwd = std.fs.path.dirname(exe),
            .claude_path = exe,
            .output_format = .stream_json,
            .stream_writer = &output.writer,
            .timeout_ms = 5000,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("answer", result.summary.final_text);
        try testing.expectEqual(@as(u64, if (has_match) 9 else 0), result.summary.usage.input_tokens);
        try testing.expect(std.mem.indexOf(u8, output.written(), "private history") == null);
    }
}

test "findPromptTurnOffset returns the last matching user entry and rejects unsafe paths" {
    const first = "{\"type\":\"user\",\"message\":{\"content\":\"some text\"}}\r\n{torn\n";
    const last =
        \\{"type":"user","message":{"content":[{"type":"text","text":"  some\r\ntext "}]}}
        \\{"type":"assistant","message":{"content":"some text"}}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.dir, "transcript", first ++ last);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(?u64, first.len), findPromptTurnOffset(testing.allocator, path, "some text"));
    try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, path, "different"));
    for ([_][]const u8{ "", "relative", "/a/../b", "/..", "/a\x00b" }) |invalid| {
        try testing.expect(!validateTranscriptPath(invalid));
        try testing.expectEqual(null, findPromptTurnOffset(testing.allocator, invalid, "some text"));
        try testing.expectError(error.InvalidTranscriptPath, transcript_mod.openTranscriptRegularFile(invalid));
    }
}

test "reportFailure includes screen content only with debug screen consent" {
    var shared: SharedState = .{ .session = undefined, .debug = false, .debug_screen = true };
    defer shared.recent.deinit(std.heap.page_allocator);
    onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "SENTINEL-startup-secret" } });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture = try tmp.dir.createFile("stderr", .{ .read = true });
    defer capture.close();
    {
        const previous = try std.posix.dup(std.posix.STDERR_FILENO);
        defer std.posix.close(previous);
        try std.posix.dup2(capture.handle, std.posix.STDERR_FILENO);
        defer std.posix.dup2(previous, std.posix.STDERR_FILENO) catch unreachable;
        reportFailure(&shared, false, "startup timeout", .{});
        shared.startup_done.store(true, .seq_cst);
        onZmuxEvent(@ptrCast(&shared), .{ .pane_output = .{ .pane_id = "p", .data = "x" ** 2200 ++ "recent-output" } });
        reportFailure(&shared, true, "stop timeout", .{});
    }
    try capture.seekTo(0);
    const logged = try capture.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(logged);
    try testing.expect(std.mem.indexOf(u8, logged, "startup timeout") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "SENTINEL") == null);
    try testing.expect(std.mem.indexOf(u8, logged, "recent-output") != null);
}

test "chunked paste observes interrupts and deadlines before the second chunk or Enter" {
    const Sink = struct {
        writes: usize = 0,
        interrupt: bool,
        pub fn writeInput(self: *@This(), _: []const u8) !void {
            self.writes += 1;
            if (self.interrupt and self.writes == 2) requestInterrupt();
        }
    };
    defer clearInterrupt();
    for ([_]bool{ false, true }) |cancel| {
        var sink: Sink = .{ .interrupt = cancel };
        const start = monotonicNs();
        const deadline = start + (if (cancel) @as(i128, 60 * std.time.ns_per_s) else 20 * std.time.ns_per_ms);
        try testing.expectError(if (cancel) error.Interrupted else error.StopTimeout, typePromptUntil(&sink, "x" ** (64 * 1024), std.time.ns_per_s, std.time.ns_per_s, deadline));
        try testing.expect(sink.writes <= 2);
        try testing.expect(monotonicNs() - start < std.time.ns_per_s);
    }
}

test "run validates unsupported library options before spawning" {
    const blocked = [_][]const u8{
        "--bare",                 "--safe-mode",    "--no-session-persistence", "--max-turns",                "--max-budget-usd",
        "--fallback-model",       "--input-format", "--json-schema",            "--include-partial-messages", "--forward-subagent-text",
        "--replay-user-messages", "-p",             "--print",                  "--settings",
    };
    inline for (blocked) |flag| {
        try testing.expectError(error.InvalidOptions, run(testing.allocator, .{ .prompt = "x", .extra_args = &.{flag} }));
        try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .extra_args = &.{flag ++ "=value"} }));
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--system-prompt", flag } });
        try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--", flag } });
    }
    try validateOptions(.{ .prompt = "x", .extra_args = &.{ "--from-pr", "--print" } });
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .max_turns = 1 }));
    try testing.expectError(error.InvalidOptions, validateOptions(.{ .prompt = "x", .fallback_model = "other" }));
}

test "run: blank Stop text without an assistant transcript is unavailable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '{"last_assistant_message":"  "}' | hook Stop
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptUnavailable, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
    }));
}

test "run: oversized transcript falls back to authoritative Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\dd if=/dev/zero of="$file" bs=1 count=1 seek=67108864 2>/dev/null
        \\printf '{"session_id":"s","last_assistant_message":"done"}' | hook Stop
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("done", result.summary.final_text);
    try testing.expectEqualStrings("s", result.summary.session_id);
    try testing.expectEqualStrings("", result.summary.jsonl_replay);
}

test "run: StopFailure preserves transcript usage and turns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":9}}}' '{"type":"assistant","message":{"usage":{"output_tokens":5}}}' >> "$file"
        \\printf '{"last_assistant_message":"quota reached","error":"generic"}' | hook StopFailure
    );
    defer testing.allocator.free(exe);
    var result = try run(testing.allocator, .{ .prompt = "hello", .claude_path = exe, .cwd = std.fs.path.dirname(exe), .timeout_ms = 10_000 });
    defer result.deinit(testing.allocator);
    try testing.expect(result.summary.is_error);
    try testing.expectEqualStrings("quota reached", result.summary.final_text);
    try testing.expectEqual(2, result.summary.num_turns);
    try testing.expectEqual(9, result.summary.usage.input_tokens);
    try testing.expectEqual(5, result.summary.usage.output_tokens);
}

test "shell refuses to exec after a previously validated cwd disappears" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("it's here");
    const cwd = try tmp.dir.realpathAlloc(testing.allocator, "it's here");
    defer testing.allocator.free(cwd);
    const command = try buildShellCommandInDir(testing.allocator, &.{ "/bin/echo", "unexpected" }, cwd);
    defer testing.allocator.free(command);
    try tmp.dir.deleteDir("it's here");
    const res = try std.process.Child.run(.{ .allocator = testing.allocator, .argv = &.{ "/bin/sh", "-c", command } });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(126, res.term.Exited);
    try testing.expectEqualStrings("", res.stdout);
}

test "run: transcript idle timeout waits for PTY progress and ends a silent turn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try writeFixture(tmp.dir, "mock", fixture_shell ++
        \\for i in 1 2 3 4 5 6; do printf .; sleep 0.05; done
        \\touch still-running
        \\sleep 5
    );
    defer testing.allocator.free(exe);
    try testing.expectError(error.TranscriptStalled, run(testing.allocator, .{
        .prompt = "hello",
        .claude_path = exe,
        .cwd = std.fs.path.dirname(exe),
        .timeout_ms = 5000,
        .transcript_idle_timeout_ms = 250,
    }));
    try tmp.dir.access("still-running", .{});
}
