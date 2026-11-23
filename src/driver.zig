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
    timeout_ms: u64 = 300_000,
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
};

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

pub const RunError = error{
    SessionStartTimeout,
    StopTimeout,
    /// claude never acknowledged the typed prompt after all re-injections.
    PromptNotAccepted,
    /// claude received a truncated copy of our typed prompt.
    PromptTruncated,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
    /// `extra_settings_json` is invalid/non-object, or an extra hook is empty.
    InvalidExtraSettings,
} || std.mem.Allocator.Error;

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

fn countNonSpace(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (!isSpace(b)) n += 1;
    }
    return n;
}

/// Detect whether Claude received a truncated copy of our typed prompt (e.g.
/// from a PTY buffer overflow). Normalizes whitespace/CRLF and treats Claude's
/// unexpanded paste placeholders (`[Pasted text #...]` / `<pasted_content...`)
/// as NOT truncated so legitimate long bracketed pastes never false-positive.
pub fn isPromptTruncated(expected: []const u8, received: []const u8) bool {
    const exp_non_ws = countNonSpace(expected);
    if (expected.len <= prompt_truncation_min_len or exp_non_ws <= prompt_truncation_min_len) {
        return false;
    }
    if (std.mem.indexOf(u8, received, "[Pasted text #") != null) return false;
    if (std.mem.indexOf(u8, received, "<pasted_content") != null) return false;
    return countNonSpace(received) < exp_non_ws;
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
/// explicit options or via pass-through `extra_args`.
pub fn isResumeRun(opts: Options) bool {
    if (opts.resume_session != null or opts.cont) return true;
    for (opts.extra_args) |a| {
        if (std.mem.eql(u8, a, "--resume") or
            std.mem.eql(u8, a, "-r") or
            std.mem.eql(u8, a, "--continue") or
            std.mem.eql(u8, a, "-c") or
            std.mem.startsWith(u8, a, "--resume="))
        {
            return true;
        }
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
/// `CLAUDE_P_FIFO` & `TERM`, injects `CLAUDE_P_FIFO=<fifo_path>` and
/// `TERM=xterm-256color`, and injects `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`
/// unless already set. Caller frees with `freeChildEnv`.
pub fn buildChildEnv(allocator: std.mem.Allocator, fifo_path: []const u8) !std.ArrayList([]u8) {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    return buildChildEnvFromMap(allocator, &env_map, fifo_path);
}

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

    try appendEnv(allocator, &list, "CLAUDE_P_FIFO", fifo_path);
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

pub fn freeChildEnv(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| allocator.free(entry);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Chunked bracketed paste (macOS TTYHOG = 1024 safety)
// ---------------------------------------------------------------------------

pub const paste_start = "\x1b[200~";
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

pub fn writeBracketedPasteTo(sink: anytype, text: []const u8, gap_ns: u64) !void {
    try sink.writeInput(paste_start);
    var chunker: PasteChunker = .{ .text = text };
    var buf: [paste_chunk_bytes]u8 = undefined;
    while (chunker.next(&buf)) |chunk| {
        try sink.writeInput(chunk);
        if (gap_ns > 0) std.Thread.sleep(gap_ns);
    }
    try sink.writeInput(paste_end);
}

pub fn typePromptTo(sink: anytype, text: []const u8, gap_ns: u64, enter_debounce_ns: u64) !void {
    try writeBracketedPasteTo(sink, text, gap_ns);
    if (enter_debounce_ns > 0) std.Thread.sleep(enter_debounce_ns);
    try sink.writeInput("\r");
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

pub const DialogKind = enum { none, trust, bypass_permissions, dev_channels };

/// Which option the dialog's `❯` cursor currently highlights.
pub const DialogSelection = enum { affirmative, negative, unknown };

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
};

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
    while (j < rest.len and isSpace(rest[j])) : (j += 1) {}
    if (j < rest.len and rest[j] >= '1' and rest[j] <= '9') {
        if (looseMatch(rest[j + 1 ..], ".")) |dot| {
            rest = rest[j + 1 + dot ..];
        }
    }
    if (looseStartsWithAny(rest, m.affirmative)) {
        out.selection = .affirmative;
    } else if (looseStartsWithAny(rest, m.negative)) {
        out.selection = .negative;
    }
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
    if (st.keys_sent >= max_dialog_keys) return;

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
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

    var digit_buf: [1]u8 = undefined;
    const keys = dialogKeyBytes(decision.action, &digit_buf);
    traceFmt(opts, trace_start, "{s} dialog: sending {s} (key {d}/{d})", .{
        @tagName(decision.kind),
        @tagName(decision.action),
        st.keys_sent + 1,
        max_dialog_keys,
    });
    session.writeInput(keys) catch {};
    st.kind = decision.kind;
    st.last = decision.action;
    st.last_key_ns = @intCast(std.time.nanoTimestamp());
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
        session.writeInput(buf[0..n]) catch {};
    }
}

fn sleepPumpingDec(shared: *SharedState, session: ?*zmux.NativeSession, duration_ms: u64) void {
    const end_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(duration_ms)) * std.time.ns_per_ms;
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        const rem_ns = end_ns - std.time.nanoTimestamp();
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
    const wait_started: i64 = @intCast(std.time.nanoTimestamp());
    while (true) {
        if (session) |s| flushPendingToPty(shared, s);
        const now: i64 = @intCast(std.time.nanoTimestamp());
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

fn transcriptSize(path: ?[]const u8) u64 {
    const p = path orelse return 0;
    const st = std.fs.cwd().statFile(p) catch return 0;
    return st.size;
}

fn trace(opts: Options, start: i128, label: []const u8) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] {s}\n", .{ elapsed_ms, label });
}

fn traceFmt(opts: Options, start: i128, comptime fmt: []const u8, args: anytype) void {
    if (!opts.debug) return;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed_ms: i64 = @intCast(@divTrunc(now - start, std.time.ns_per_ms));
    std.debug.print("[claude-p +{d}ms] ", .{elapsed_ms});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

// ---------------------------------------------------------------------------
// Thread-shared state & zmux callback
// ---------------------------------------------------------------------------

pub const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    // Bytes the DEC responder wants written back to the PTY. Mutex-guarded.
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Timestamp (ns since arbitrary epoch — std.time.nanoTimestamp, truncated
    /// to i64 so atomics work on all targets including x86_64-linux-musl).
    last_output_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Rolling buffer of recently-seen output for startup dialog detection.
    recent_mutex: std.Thread.Mutex = .{},
    recent: std.ArrayList(u8) = .{},
    trust_dismissed: bool = false,
    bypass_perms_accepted: bool = false,
    dev_channels_confirmed: bool = false,
    dialog: DialogState = .{},
};

pub const recent_capacity: usize = 8192;

pub fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            // Run the DEC-query responder; queue responses for the main loop.
            var resp: std.ArrayList(u8) = .{};
            defer resp.deinit(std.heap.page_allocator);
            terminal_mod.respondToDecQueries(std.heap.page_allocator, po.data, &resp) catch {};
            if (resp.items.len > 0) {
                shared.write_mutex.lock();
                shared.pending_to_pty.appendSlice(std.heap.page_allocator, resp.items) catch {};
                shared.write_mutex.unlock();
            }
            // Update the rolling recent-output buffer AND bytes_seen under the
            // same mutex so `maybeHandleStartupDialogs` always reads a
            // consistent `(bytes_seen, recent)` snapshot.
            shared.recent_mutex.lock();
            shared.recent.appendSlice(std.heap.page_allocator, po.data) catch {};
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
            shared.last_output_ns.store(@intCast(std.time.nanoTimestamp()), .seq_cst);
            shared.recent_mutex.unlock();
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

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;

    const trace_start: i128 = std.time.nanoTimestamp();
    trace(opts, trace_start, "run() entered");

    var harness = hook_mod.createWithOptions(allocator, .{
        .extra_hooks = opts.extra_hooks,
        .extra_settings_json = opts.extra_settings_json,
    }) catch |e| switch (e) {
        error.InvalidExtraSettings => return RunError.InvalidExtraSettings,
        else => return e,
    };
    defer harness.deinit();
    trace(opts, trace_start, "hook harness ready (FIFO + relay script + --settings)");

    const claude_bin = opts.claude_path orelse "claude";

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer argv.deinit(allocator);

    const shell_cmd = try shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    var env_list = try buildChildEnv(allocator, harness.fifo_path);
    defer freeChildEnv(allocator, &env_list);

    // Open the FIFO for reading BEFORE spawning so the child's hook never
    // blocks trying to open the write side.
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined, // set after create
        .debug = opts.debug,
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
        .cwd = opts.cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return RunError.SpawnFailed;
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
    var pre_prompt_transcript_offset: u64 = 0;
    var exited_seen_ns: ?i128 = null;

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var stop_payload_owned: ?[]u8 = null;
    defer if (stop_payload_owned) |p| allocator.free(p);

    const streaming = opts.output_format == .stream_json and opts.stream_writer != null;
    var tailer: ?stream_mod.Tailer = null;
    defer if (tailer) |*t| t.deinit();
    var tailer_open_attempts: u32 = 0;

    while (true) {
        const now: i128 = std.time.nanoTimestamp();
        const elapsed_ms: u64 = @intCast(@divTrunc(now - start_ns, std.time.ns_per_ms));
        if (elapsed_ms > opts.timeout_ms) {
            if (state == .waiting_for_ready) return RunError.SessionStartTimeout;
            return RunError.StopTimeout;
        }

        // Flush any DEC-responder bytes back to the PTY.
        flushPendingToPty(&shared, session);

        // Drain ALL available FIFO bytes before checking dialogs, watchdog, or
        // child-exit so an in-flight Stop or UserPromptSubmit is never missed.
        while (stop_payload_owned == null) {
            const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => break,
            };
            if (fifo_n == 0) break;
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, fifo_buf.items, '\n') orelse break;
                const line = fifo_buf.items[0..nl];
                if (hook_mod.parseLine(line)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s} payload={s}\n", .{ @tagName(ev.event), ev.payload });
                    switch (ev.event) {
                        .session_start => {
                            trace(opts, trace_start, "SessionStart hook fired (Ink is up)");
                            if (transcript_path == null) {
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    transcript_path = p;
                                    traceFmt(opts, trace_start, "transcript_path from SessionStart: {s}", .{p});
                                }
                            }
                            if (state == .waiting_for_ready) {
                                settleBeforePrompt(opts, trace_start, &shared, session);
                                pre_prompt_transcript_offset = transcriptSize(transcript_path);
                                traceFmt(opts, trace_start, "typing prompt ({d} bytes; transcript offset {d})", .{ opts.prompt.len, pre_prompt_transcript_offset });
                                typePrompt(session, opts.prompt) catch |e| {
                                    traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(e)});
                                };
                                // Start acceptance timer AFTER typePrompt finishes so large
                                // chunked pastes never eat into prompt_accept_timeout_ms.
                                prompt_typed_ns = std.time.nanoTimestamp();
                                prompt_injections = 1;
                                trace(opts, trace_start, "prompt + Enter sent; confirming acceptance");
                                state = .awaiting_stop;
                            }
                        },
                        .user_prompt_submit => {
                            if (state == .awaiting_stop) {
                                if (transcript_path == null) {
                                    transcript_path = try hook_mod.extractTranscriptPath(allocator, ev.payload);
                                }
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
                        .stop => {
                            if (state == .awaiting_stop and stop_payload_owned == null) {
                                trace(opts, trace_start, "Stop hook fired (assistant turn finished)");
                                prompt_accepted = true;
                                if (try hook_mod.extractTranscriptPath(allocator, ev.payload)) |p| {
                                    if (transcript_path) |old| {
                                        if (std.mem.eql(u8, old, p)) {
                                            allocator.free(p);
                                        } else {
                                            traceFmt(opts, trace_start, "transcript moved to {s}; resetting offset to 0", .{p});
                                            allocator.free(old);
                                            transcript_path = p;
                                            pre_prompt_transcript_offset = 0;
                                            if (tailer) |*t| t.deinit();
                                            tailer = null;
                                        }
                                    } else {
                                        transcript_path = p;
                                    }
                                }
                                stop_payload_owned = try allocator.dupe(u8, ev.payload);
                            }
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
                if (stop_payload_owned != null) break;
            }
        }

        if (stop_payload_owned != null) break;

        // Fail fast if child exited early (after draining any final FIFO events).
        // Check both `shared.exited` (from `.session_exited` event) and
        // `session.state() == .terminated` (zmux can mark the session terminated
        // on PTY EOF without firing `.session_exited`).
        if (shared.exited.load(.seq_cst) or session.state() == .terminated) {
            if (state == .waiting_for_ready) {
                return RunError.SpawnFailed;
            }
            const first_exited = exited_seen_ns orelse blk: {
                exited_seen_ns = now;
                break :blk now;
            };
            const since_exit_ms: u64 = @intCast(@max(0, @divTrunc(now - first_exited, std.time.ns_per_ms)));
            if (since_exit_ms >= post_exit_fifo_grace_ms) {
                traceFmt(opts, trace_start, "child exited without Stop (prompt_accepted={any}) — failing fast", .{prompt_accepted});
                return if (prompt_accepted) RunError.TranscriptUnavailable else RunError.PromptNotAccepted;
            }
        }

        // Pre-SessionStart modal dialogs (workspace trust, bypass-permissions,
        // development channels).
        if (state == .waiting_for_ready) {
            maybeHandleStartupDialogs(opts, trace_start, &shared, session);
        }

        // Prompt-acceptance watchdog.
        if (state == .awaiting_stop and exited_seen_ns == null) {
            if (!prompt_accepted and transcriptSize(transcript_path) > pre_prompt_transcript_offset) {
                trace(opts, trace_start, "transcript grew past pre-prompt offset (prompt accepted)");
                prompt_accepted = true;
            }
            const since_typed_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp() - prompt_typed_ns, std.time.ns_per_ms));
            switch (promptWatchdogAction(prompt_accepted, prompt_injections, since_typed_ms)) {
                .wait => {},
                .reinject => {
                    traceFmt(opts, trace_start, "prompt unacknowledged after {d}ms — re-injecting (attempt {d}/{d})", .{
                        since_typed_ms,
                        prompt_injections + 1,
                        max_prompt_injections,
                    });
                    session.writeInput("\x15") catch {}; // Ctrl-U: clear residual input
                    sleepPumpingDec(&shared, session, ink_enter_debounce_ms);
                    _ = waitForOutputQuiet(opts, trace_start, &shared, session, ink_quiescence_ms, ink_max_wait_ms);
                    typePrompt(session, opts.prompt) catch |e| {
                        traceFmt(opts, trace_start, "prompt write failed: {s}", .{@errorName(e)});
                    };
                    prompt_injections += 1;
                    prompt_typed_ns = std.time.nanoTimestamp();
                },
                .give_up => {
                    traceFmt(opts, trace_start, "prompt not accepted after {d} injection(s) — aborting", .{prompt_injections});
                    return RunError.PromptNotAccepted;
                },
            }
        }

        // Open the live streaming tailer once `pre_prompt_transcript_offset` is known.
        if (streaming and tailer == null and state == .awaiting_stop) {
            if (transcript_path) |p| {
                tailer_open_attempts += 1;
                if (stream_mod.Tailer.open(allocator, p)) |t_const| {
                    var t = t_const;
                    t.pos = pre_prompt_transcript_offset;
                    tailer = t;
                    traceFmt(opts, trace_start, "transcript opened for tailing @ {d} after {d} attempt(s): {s}", .{
                        pre_prompt_transcript_offset,
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

        // Pump any newly flushed transcript lines to `stream_writer`.
        if (streaming and tailer != null and opts.stream_writer != null) {
            const n = tailer.?.pump(opts.stream_writer.?) catch 0;
            if (n > 0) {
                opts.stream_writer.?.flush() catch {};
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

    // Final pump — Claude often flushes the last assistant message a few ms
    // after the Stop hook fires.
    if (streaming and opts.stream_writer != null) {
        trace(opts, trace_start, "draining post-Stop transcript flush window (20 × 20ms)");
        if (tailer == null) {
            if (transcript_path) |p| {
                if (stream_mod.Tailer.open(allocator, p)) |t_const| {
                    var t = t_const;
                    t.pos = pre_prompt_transcript_offset;
                    tailer = t;
                } else |_| {}
            }
        }
        if (tailer != null) {
            var attempt: u32 = 0;
            var post_stop_lines: usize = 0;
            while (attempt < 20) : (attempt += 1) {
                const n = tailer.?.pump(opts.stream_writer.?) catch 0;
                post_stop_lines += n;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
            opts.stream_writer.?.flush() catch {};
            traceFmt(opts, trace_start, "post-Stop drain streamed {d} more line(s)", .{post_stop_lines});
        }
    }

    const stop_last: ?[]u8 = if (stop_payload_owned) |payload|
        try hook_mod.extractLastAssistantMessage(allocator, payload)
    else
        null;
    defer if (stop_last) |s| allocator.free(s);

    // Parse ONLY bytes appended after `pre_prompt_transcript_offset` so
    // `--resume` / `--continue` never returns a prior turn's answer. Retry up
    // to 20 × 50ms while Claude flushes the trailing line, plus extra retries
    // when the parsed text disagrees with Stop's `last_assistant_message`.
    var summary = blk: {
        var candidate: ?transcript_mod.Summary = null;
        errdefer if (candidate) |*c| c.deinit(allocator);
        if (transcript_path) |tp| {
            var attempt: u32 = 0;
            var mismatches: u32 = 0;
            while (attempt < 20 or (candidate != null and mismatches < 10)) : (attempt += 1) {
                if (attempt >= 30) break;
                var maybe = transcript_mod.parseFileFromOffset(allocator, tp, pre_prompt_transcript_offset) catch |e| switch (e) {
                    error.NoAssistantMessage, error.FileNotFound => null,
                    else => return e,
                };
                if (maybe) |*valid| {
                    if (valid.final_text.len > 0 or valid.is_error) {
                        if (candidate) |*c| c.deinit(allocator);
                        candidate = valid.*;
                        if (valid.is_error or finalTextMatchesStop(valid.final_text, stop_last)) {
                            const done = candidate.?;
                            candidate = null;
                            break :blk done;
                        }
                        mismatches += 1;
                    } else {
                        valid.deinit(allocator);
                    }
                }
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        if (candidate) |c| {
            candidate = null;
            break :blk c;
        }
        if (stop_payload_owned) |payload| {
            if (stop_last) |text| {
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

    // Tear down the child immediately — we already have the answer.
    session.terminate();

    const total_ns: i128 = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(total_ns, std.time.ns_per_ms));

    var streamed = false;
    if (streaming) {
        if (opts.stream_writer) |w| {
            try emit_mod.emitJson(allocator, w, .{
                .summary = &summary,
                .duration_ms = duration_ms,
            });
            w.flush() catch {};
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
/// `out.len` must be >= `bytes.len` (stripping never grows the input).
pub fn stripCsiInto(out: []u8, bytes: []const u8) []u8 {
    std.debug.assert(out.len >= bytes.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
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

test "buildChildEnvFromMap: filters nested markers, preserves auth/backend vars, injects FIFO + TERM + persistence" {
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
    try testing.expectEqualStrings("/tmp/x/events.fifo", testEnvValue(env.items, "CLAUDE_P_FIFO").?);
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
        \\down=$(printf '\033[B')
        \\enter=$(printf '\r')
        \\printf 'Quick safety check: Is this a project you trust?\r\nreview this folder first.\r\n❯ No, exit\r\n  Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 3)" = "$down" ]
        \\printf '\r  No, exit\r\n❯ Yes, I trust this folder\r\n'
        \\[ "$(read_bytes 1)" = "$enter" ]
        \\printf '\033[2J\033[HReady ? for shortcuts'
        \\file="$PWD/session.jsonl"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"previous turn"}]}}' > "$file"
        \\printf 'SessionStart\t{"transcript_path":"%s"}\n' "$file" > "$CLAUDE_P_FIFO"
        \\{ printf '\033[200~'; cat prompt; printf '\033[201~\r'; } > expected
        \\read_bytes "$(wc -c < expected | tr -d ' ')" | cmp - expected
        \\{ printf 'UserPromptSubmit\t'; cat submit.json; printf '\n'; } > "$CLAUDE_P_FIFO"
        \\printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"current turn"}]}}' >> "$file"
        \\printf 'Stop\t{"transcript_path":"%s","last_assistant_message":"current turn"}\n' "$file" > "$CLAUDE_P_FIFO"
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
        \\printf 'Ready\r\n'
        \\printf 'SessionStart\t{"transcript_path":"%s/none.jsonl"}\n' "$PWD" > "$CLAUDE_P_FIFO"
        \\printf 'UserPromptSubmit\t{"prompt":"hello"}\n' > "$CLAUDE_P_FIFO"
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
