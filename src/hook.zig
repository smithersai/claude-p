//! Generates startup, prompt, permission, and terminal hook plumbing
//! for a `claude` invocation: a per-run temp dir, a FIFO the parent reads, a
//! tiny shell script that relays the hook payload to the FIFO, and the inline
//! `--settings` JSON that tells `claude` to call it.
//!
//! The temp dir is created exclusively with mode 0700 under an absolute
//! temp root, and its name carries 64 bits from the OS CSPRNG. The relay
//! script embeds the FIFO path and a per-run nonce, and writes
//! `<nonce>\t<event>\t<payload>` lines, so it needs no `CLAUDE_P_FIFO` in the
//! environment and `parseLineWithNonce` can reject lines it did not write.
//!
//! Lifetime: caller owns the HookHarness and must `deinit` it; the temp
//! directory and FIFO are removed there.
const std = @import("std");

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

/// Settings JSON builder, shell quoting, and extra-settings validation.
pub const settings = @import("hook/settings.zig");
/// Additional user-configured hook command bound to a Claude Code hook event.
pub const ExtraHook = settings.ExtraHook;
/// Options controlling extra hooks and extra `--settings` JSON merged into a harness.
pub const CreateOptions = settings.CreateOptions;
/// Maximum container nesting depth accepted in `extra_settings_json`.
pub const max_extra_settings_depth = settings.max_extra_settings_depth;
/// Validate `opts` without creating files on disk.
pub const validateExtraSettings = settings.validateExtraSettings;
/// Build the inline `--settings` JSON string wiring relay and extra hooks.
pub const buildSettingsJson = settings.buildSettingsJson;

const shellSingleQuote = settings.shellSingleQuote;
const relay_events = settings.relay_events;

/// Ephemeral temp directory, FIFO, relay script, nonce, and settings JSON for one session.
pub const HookHarness = struct {
    allocator: std.mem.Allocator,
    /// `$TMPDIR/claude-p-<pid>-<rand>/`
    tmp_dir: []u8,
    /// Path to the FIFO we read; the hook script writes to it.
    fifo_path: []u8,
    /// Path to the relay shell script.
    script_path: []u8,
    /// Inline JSON suitable for `--settings <this>`.
    settings_json: []u8,
    /// Per-run nonce (16 lowercase hex characters) the relay script puts in
    /// front of every line. Pass it to `parseLineWithNonce`.
    nonce: [nonce_len]u8,

    /// Remove temporary FIFO, relay script, and directory, then free owned buffers.
    pub fn deinit(self: *HookHarness) void {
        // Best-effort cleanup; files may already have been unlinked on partial failure.
        cleanupPath(std.fs.cwd().deleteFile(self.fifo_path));
        cleanupPath(std.fs.cwd().deleteFile(self.script_path));
        cleanupPath(std.fs.cwd().deleteDir(self.tmp_dir));
        self.allocator.free(self.tmp_dir);
        self.allocator.free(self.fifo_path);
        self.allocator.free(self.script_path);
        self.allocator.free(self.settings_json);
    }
};

fn cleanupPath(res: anyerror!void) void {
    res catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

/// Length of the per-run relay nonce: 64 random bits as lowercase hex.
pub const nonce_len = 16;

/// How many random directory names `createWithOptions` tries before giving up.
const max_tmp_dir_attempts = 16;

/// Render the relay script. The FIFO path and nonce are embedded as
/// single-quoted shell words. Only the harness FIFO receives events.
pub fn buildScript(
    allocator: std.mem.Allocator,
    fifo_path: []const u8,
    nonce: []const u8,
) error{OutOfMemory}![]u8 {
    std.debug.assert(relay_events.len > 0);
    const quoted_fifo = try shellSingleQuote(allocator, fifo_path);
    defer allocator.free(quoted_fifo);
    const quoted_nonce = try shellSingleQuote(allocator, nonce);
    defer allocator.free(quoted_nonce);
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\# Relay a Claude Code hook event to claude-p's FIFO.
        \\#   $1 = event name (e.g. "Stop", "SessionStart", "UserPromptSubmit")
        \\# stdin = the hook's JSON payload (single line, no embedded newlines).
        \\set -eu
        \\event="$1"
        \\fifo={s}
        \\nonce={s}
        \\[ -p "$fifo" ] || exit 1
        \\# Read the JSON payload and emit one line: "<nonce>\t<event>\t<payload>"
        \\payload="$(cat)"
        \\printf '%s\t%s\t%s\n' "$nonce" "$event" "$payload" >> "$fifo"
        \\exit 0
        \\
    , .{ quoted_fifo, quoted_nonce });
}

/// The absolute directory that holds per-run harness directories: `$TMPDIR`,
/// or `/tmp` when it is unset or empty. Caller frees.
fn tmpRoot(allocator: std.mem.Allocator) ![]u8 {
    return resolveTmpRoot(allocator, std.posix.getenv("TMPDIR"));
}

/// Resolve a `TMPDIR` value to an absolute path. Unset or empty means `/tmp`.
/// A relative value is resolved against the current directory now, so hook
/// paths keep working after the child `chdir`s elsewhere. Caller frees.
pub fn resolveTmpRoot(allocator: std.mem.Allocator, tmpdir: ?[]const u8) ![]u8 {
    const value = tmpdir orelse "";
    if (value.len == 0) return allocator.dupe(u8, "/tmp");
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    return std.fs.cwd().realpathAlloc(allocator, value);
}

fn cryptoSuffix() u64 {
    return std.crypto.random.int(u64);
}

/// Create `<root>/claude-p-<pid>-<suffix>` with mode 0700 and return its path.
/// `mkdir` fails on an existing name, so a directory, file, or symlink planted
/// at a guessed path is never adopted; a taken name is retried with a fresh
/// suffix up to `max_tmp_dir_attempts` times. Caller frees.
fn makeExclusiveTmpDir(
    allocator: std.mem.Allocator,
    root: []const u8,
    pid: i32,
    nextSuffix: *const fn () u64,
) ![]u8 {
    std.debug.assert(root.len > 0 and max_tmp_dir_attempts > 0);
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        std.debug.assert(attempt <= max_tmp_dir_attempts);
        const tmp_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/claude-p-{d}-{x:0>16}",
            .{ root, pid, nextSuffix() },
        );
        errdefer allocator.free(tmp_dir);
        std.posix.mkdir(tmp_dir, 0o700) catch |err| {
            if (err == error.PathAlreadyExists and attempt < max_tmp_dir_attempts) {
                allocator.free(tmp_dir);
                continue;
            }
            return err;
        };
        return tmp_dir;
    }
}

/// Build a harness with default options — creates tmp dir, FIFO, script, and
/// settings JSON.
pub fn create(allocator: std.mem.Allocator) !HookHarness {
    return createWithOptions(allocator, .{});
}

/// Build a harness whose settings JSON also merges `opts.extra_hooks` and
/// `opts.extra_settings_json`. Validates all options before touching the
/// filesystem so invalid settings or empty extra hooks never leave temp files
/// behind.
pub fn createWithOptions(allocator: std.mem.Allocator, opts: CreateOptions) !HookHarness {
    // Validate BEFORE creating any files on disk.
    try validateExtraSettings(allocator, opts);

    const root = try tmpRoot(allocator);
    defer allocator.free(root);

    var nonce_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    std.debug.assert(nonce.len == nonce_len and isNonceShaped(&nonce));

    const pid: i32 = @intCast(std.posix.system.getpid());
    const tmp_dir = try makeExclusiveTmpDir(allocator, root, pid, cryptoSuffix);
    errdefer allocator.free(tmp_dir);
    errdefer cleanupPath(std.fs.cwd().deleteDir(tmp_dir));

    const fifo_path = try std.fmt.allocPrint(allocator, "{s}/events.fifo", .{tmp_dir});
    errdefer allocator.free(fifo_path);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/hook.sh", .{tmp_dir});
    errdefer allocator.free(script_path);

    const settings_json = try buildSettingsJson(allocator, script_path, opts);
    errdefer allocator.free(settings_json);

    const script = try buildScript(allocator, fifo_path, &nonce);
    defer allocator.free(script);

    // mkfifo via libc.
    const c_fifo_path = try allocator.dupeZ(u8, fifo_path);
    defer allocator.free(c_fifo_path);
    if (mkfifo(c_fifo_path.ptr, 0o600) != 0) {
        return error.MkfifoFailed;
    }
    errdefer cleanupPath(std.fs.cwd().deleteFile(fifo_path));

    // Write the relay script. Exclusive creation never follows or truncates
    // something already at the path.
    var script_file = try std.fs.cwd().createFile(script_path, .{ .exclusive = true, .mode = 0o700 });
    errdefer cleanupPath(std.fs.cwd().deleteFile(script_path));
    {
        defer script_file.close();
        try script_file.writeAll(script);
    }

    return HookHarness{
        .allocator = allocator,
        .tmp_dir = tmp_dir,
        .fifo_path = fifo_path,
        .script_path = script_path,
        .settings_json = settings_json,
        .nonce = nonce,
    };
}

/// Hook lifecycle events relayed from Claude Code over the harness FIFO.
pub const HookEvent = enum {
    session_start,
    user_prompt_submit,
    stop,
    /// The turn ended on an API error instead of a normal `Stop`.
    stop_failure,
    permission_request,
    unknown,

    pub fn fromString(s: []const u8) HookEvent {
        if (std.mem.eql(u8, s, "SessionStart")) return .session_start;
        if (std.mem.eql(u8, s, "UserPromptSubmit")) return .user_prompt_submit;
        if (std.mem.eql(u8, s, "Stop")) return .stop;
        if (std.mem.eql(u8, s, "StopFailure")) return .stop_failure;
        if (std.mem.eql(u8, s, "PermissionRequest")) return .permission_request;
        return .unknown;
    }
};

/// Parsed FIFO event record pairing a `HookEvent` with its borrowed JSON payload.
pub const HookLine = struct {
    event: HookEvent,
    payload: []const u8, // borrowed from the input buffer
};

/// Parse a single hook line. Trailing newline is tolerated.
///
/// Accepts the plain form `<event>\t<json>` and the form the relay script
/// writes, `<nonce>\t<event>\t<json>`, where `<nonce>` is `nonce_len`
/// lowercase hex characters. The nonce is skipped, NOT checked: use
/// `parseLineWithNonce` to reject lines from other writers.
pub fn parseLine(raw: []const u8) ?HookLine {
    const line = trimLineEnd(raw);
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    if (isNonceShaped(line[0..tab])) {
        if (splitEventPayload(line[tab + 1 ..])) |inner| return inner;
    }
    return splitEventPayload(line);
}

/// Parse a relay line of the form `<nonce>\t<event>\t<json>` and return it
/// only when `<nonce>` equals `expected_nonce` (`HookHarness.nonce`). Lines
/// without the nonce, with another nonce, or with no event field return null,
/// as does an empty `expected_nonce`. Trailing newline is tolerated.
pub fn parseLineWithNonce(raw: []const u8, expected_nonce: []const u8) ?HookLine {
    if (expected_nonce.len == 0) return null;
    const line = trimLineEnd(raw);
    if (line.len <= expected_nonce.len or line[expected_nonce.len] != '\t') return null;
    if (!std.mem.eql(u8, line[0..expected_nonce.len], expected_nonce)) return null;
    return splitEventPayload(line[expected_nonce.len + 1 ..]);
}

fn trimLineEnd(raw: []const u8) []const u8 {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    std.debug.assert(line.len <= raw.len);
    return line;
}

fn splitEventPayload(line: []const u8) ?HookLine {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    std.debug.assert(tab < line.len);
    return .{
        .event = HookEvent.fromString(line[0..tab]),
        .payload = line[tab + 1 ..],
    };
}

fn isNonceShaped(field: []const u8) bool {
    if (field.len != nonce_len) return false;
    for (field) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Pull `transcript_path` out of a Stop/SessionStart hook payload JSON.
/// Returned slice is heap-allocated.
pub fn extractTranscriptPath(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "transcript_path");
}

/// Pull `last_assistant_message` out of a Stop-hook payload — recent Claude
/// Code versions include this string in the payload directly, which lets us
/// verify or fall back when transcript flushing races Stop.
pub fn extractLastAssistantMessage(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "last_assistant_message");
}

/// Pull `session_id` out of a Stop/SessionStart hook payload.
pub fn extractSessionId(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "session_id");
}

/// Pull `prompt` out of a UserPromptSubmit hook payload JSON.
/// Returned slice is heap-allocated.
pub fn extractPrompt(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "prompt");
}

/// Return true when a Stop payload reports `stop_hook_active: true`.
pub fn parseStopHookActive(allocator: std.mem.Allocator, payload_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const flag = parsed.value.object.get("stop_hook_active") orelse return false;
    return flag == .bool and flag.bool;
}

/// Extract the requested tool name (or fallback message) from a `PermissionRequest` payload.
pub fn extractPermissionTool(allocator: std.mem.Allocator, payload_json: []const u8) ?[]u8 {
    if (extractStringField(allocator, payload_json, "tool_name") catch null) |name| {
        if (name.len > 0) return name;
        allocator.free(name);
    }
    return extractStringField(allocator, payload_json, "message") catch null;
}

/// Extract a best-effort error message from a `StopFailure` payload, returning null on error.
pub fn extractErrorMessage(allocator: std.mem.Allocator, payload_json: []const u8) ?[]u8 {
    return extractErrorMessageAlloc(allocator, payload_json) catch null;
}

/// Extract the first present error text field from a `StopFailure` payload, propagating OOM.
pub fn extractErrorMessageAlloc(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    const fields = [_][]const u8{
        "last_assistant_message",
        "error_details",
        "error",
        "message",
        "reason",
    };
    return extractFirstMessage(allocator, payload_json, &fields);
}

fn extractFirstMessage(allocator: std.mem.Allocator, payload_json: []const u8, fields: []const []const u8) !?[]u8 {
    std.debug.assert(fields.len > 0);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    for (fields) |field| {
        const v = parsed.value.object.get(field) orelse continue;
        switch (v) {
            .string => |text| return try allocator.dupe(u8, text),
            .object => |obj| if (obj.get("message")) |inner| {
                if (inner == .string) return try allocator.dupe(u8, inner.string);
            },
            else => {},
        }
    }
    return null;
}

fn extractStringField(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    field: []const u8,
) !?[]u8 {
    std.debug.assert(field.len > 0);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(field) orelse return null;
    if (v != .string) return null;
    return try allocator.dupe(u8, v.string);
}

// -------- tests --------

const testing = std.testing;

test "parseLine: well-formed" {
    const ln = parseLine("Stop\t{\"transcript_path\":\"/tmp/x.jsonl\"}\n").?;
    try testing.expectEqual(HookEvent.stop, ln.event);
    try testing.expectEqualStrings("{\"transcript_path\":\"/tmp/x.jsonl\"}", ln.payload);

    const ups = parseLine("UserPromptSubmit\t{\"prompt\":\"hi\"}\r\n").?;
    try testing.expectEqual(HookEvent.user_prompt_submit, ups.event);
    try testing.expectEqualStrings("{\"prompt\":\"hi\"}", ups.payload);
}

test "parseLine: unknown event tagged" {
    const ln = parseLine("PreFooBar\t{}").?;
    try testing.expectEqual(HookEvent.unknown, ln.event);
}

test "parseLine: malformed returns null" {
    try testing.expectEqual(@as(?HookLine, null), parseLine("nope-no-tab"));
}

test "extractTranscriptPath" {
    const path = (try extractTranscriptPath(testing.allocator, "{\"transcript_path\":\"/a/b.jsonl\",\"session_id\":\"x\"}")).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/a/b.jsonl", path);
}

test "extractLastAssistantMessage" {
    const m = (try extractLastAssistantMessage(testing.allocator, "{\"last_assistant_message\":\"OK\",\"session_id\":\"x\"}")).?;
    defer testing.allocator.free(m);
    try testing.expectEqualStrings("OK", m);
}

test "extractSessionId" {
    const s = (try extractSessionId(testing.allocator, "{\"session_id\":\"abc-123\"}")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("abc-123", s);
}

test "extractPrompt" {
    const p = (try extractPrompt(testing.allocator, "{\"prompt\":\"line1\\nline2\",\"session_id\":\"x\"}")).?;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("line1\nline2", p);
    for ([_][]const u8{ "{}", "{\"prompt\":42}", "[]", "not-json" }) |bad| {
        try testing.expectEqual(@as(?[]u8, null), try extractPrompt(testing.allocator, bad));
    }
}

test "create + deinit round-trip on tmp" {
    var h = try create(testing.allocator);
    defer h.deinit();
    const sf = try std.fs.cwd().openFile(h.script_path, .{});
    sf.close();
    const path_z = try testing.allocator.dupeZ(u8, h.fifo_path);
    defer testing.allocator.free(path_z);
    const fd = try std.posix.openZ(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    std.posix.close(fd);
}

test "createWithOptions: round-trip with extra_hooks and extra_settings_json" {
    var h = try createWithOptions(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "PostToolUse", .command = "echo done" }},
        .extra_settings_json = "{\"cleanupPeriodDays\":7}",
    });
    defer h.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.settings_json, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("cleanupPeriodDays").?.integer);
    const hooks = parsed.value.object.get("hooks").?.object;
    const post_cmd = hooks.get("PostToolUse").?.array.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    const stop_cmd = hooks.get("Stop").?.array.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("echo done", post_cmd);
    try testing.expect(std.mem.indexOf(u8, stop_cmd, h.script_path) != null);
}

test "settings json: rejects disableAllHooks true" {
    try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(testing.allocator, .{
        .extra_settings_json = "{\"disableAllHooks\":true}",
    }));
    try validateExtraSettings(testing.allocator, .{ .extra_settings_json = "{\"disableAllHooks\":false}" });
}

test "HookEvent: StopFailure maps to stop_failure" {
    try testing.expectEqual(HookEvent.stop_failure, HookEvent.fromString("StopFailure"));
    try testing.expectEqual(HookEvent.unknown, HookEvent.fromString("stopfailure"));
    try testing.expectEqual(HookEvent.stop_failure, parseLine("StopFailure\t{\"error\":\"rate_limit\"}\n").?.event);
}

test "extractErrorMessage: prefers error, message, then reason" {
    const a = testing.allocator;
    const g1 = extractErrorMessage(a, "{\"error\":\"rate_limit\",\"message\":\"m\"}").?;
    defer a.free(g1);
    try testing.expectEqualStrings("rate_limit", g1);
    const g2 = extractErrorMessage(a, "{\"error\":{\"message\":\"boom\"}}").?;
    defer a.free(g2);
    try testing.expectEqualStrings("boom", g2);
    try testing.expectEqual(@as(?[]u8, null), extractErrorMessage(a, "{}"));
}

test "extractErrorMessage: allocation failures leak nothing" {
    const Ctx = struct {
        fn run(allocator: std.mem.Allocator) !void {
            if (try extractFirstMessage(allocator, "{\"error\":{\"message\":\"boom\"}}", &.{"error"})) |g| allocator.free(g);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.run, .{});
}

test "parseLineWithNonce: accepts expected nonce and rejects mismatch" {
    const nonce = "0123456789abcdef";
    const ln = parseLineWithNonce(nonce ++ "\tStop\t{\"a\":1}\n", nonce).?;
    try testing.expectEqual(HookEvent.stop, ln.event);
    try testing.expectEqualStrings("{\"a\":1}", ln.payload);
    try testing.expectEqual(@as(?HookLine, null), parseLineWithNonce("Stop\t{}", nonce));
    try testing.expectEqual(@as(?HookLine, null), parseLineWithNonce("0123456789abcdee\tStop\t{}", nonce));
}

test "parseLine: skips a relay nonce without checking it" {
    const ln = parseLine("0123456789abcdef\tUserPromptSubmit\t{\"prompt\":\"hi\"}\n").?;
    try testing.expectEqual(HookEvent.user_prompt_submit, ln.event);
    try testing.expectEqualStrings("{\"prompt\":\"hi\"}", ln.payload);
}

test "buildScript: embeds quoted FIFO path and nonce" {
    const script = try buildScript(testing.allocator, "/tmp/will's dir/events.fifo", "0123456789abcdef");
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "fifo='/tmp/will'\\''s dir/events.fifo'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "nonce='0123456789abcdef'") != null);
}

test "resolveTmpRoot: handles unset, absolute, and relative paths" {
    const a = testing.allocator;
    const def = try resolveTmpRoot(a, null);
    defer a.free(def);
    try testing.expectEqualStrings("/tmp", def);
    const abs = try resolveTmpRoot(a, "/var/tmp/x");
    defer a.free(abs);
    try testing.expectEqualStrings("/var/tmp/x", abs);
    try testing.expectError(error.FileNotFound, resolveTmpRoot(a, "no-such-dir-claude-p/nested"));
}

test "makeExclusiveTmpDir: 0700 and skips colliding names" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    try tmp.dir.makeDir("claude-p-7-0000000000000001");
    const S = struct {
        var idx: usize = 0;
        fn next() u64 {
            idx += 1;
            return idx;
        }
    };
    S.idx = 0;
    const made = try makeExclusiveTmpDir(a, root, 7, S.next);
    defer a.free(made);
    try testing.expect(std.mem.endsWith(u8, made, "/claude-p-7-0000000000000002"));
    const st = try std.fs.cwd().statFile(made);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);
}

test "create: sets distinct nonces and writes relay script" {
    var h = try create(testing.allocator);
    defer h.deinit();
    try testing.expect(isNonceShaped(&h.nonce));
    const got = try std.fs.cwd().readFileAlloc(testing.allocator, h.script_path, 1 << 16);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, &h.nonce) != null);
}

test "PermissionRequest tool and active Stop hook payloads" {
    const tool = extractPermissionTool(testing.allocator, "{\"tool_name\":\"Bash\"}").?;
    defer testing.allocator.free(tool);
    try testing.expectEqualStrings("Bash", tool);
    try testing.expect(parseStopHookActive(testing.allocator, "{\"stop_hook_active\":true}"));
    try testing.expect(!parseStopHookActive(testing.allocator, "{}"));
}
