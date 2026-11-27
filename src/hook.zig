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

/// Additional user-configured hook command bound to a Claude Code hook event.
pub const ExtraHook = struct {
    event: []const u8,
    command: []const u8,
};

/// Options controlling extra hooks and extra `--settings` JSON merged into a harness.
pub const CreateOptions = struct {
    /// Appended after the relay hook for the same event, or added under a new
    /// event key. Relay hooks always remain first and authoritative.
    extra_hooks: []const ExtraHook = &.{},
    /// Optional JSON object whose top-level keys (other than `"hooks"`) are
    /// merged into the generated `--settings` object. Nesting deeper than
    /// `max_extra_settings_depth` is rejected, and so is
    /// `"disableAllHooks": true`, which would switch off the relay hooks and
    /// leave the run waiting for events that never arrive.
    extra_settings_json: ?[]const u8 = null,
};

/// Maximum container nesting depth accepted in `extra_settings_json`, counting
/// the top-level object as depth 1. `std.json.Stringify` tracks at most 256
/// levels and indexes out of bounds beyond that, so deeper documents are
/// rejected with `error.InvalidExtraSettings` instead of crashing.
pub const max_extra_settings_depth: usize = 128;

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

const relay_events = [_][]const u8{
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "StopFailure",
    "PermissionRequest",
};

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

/// Quote `text` as one POSIX shell word, whatever bytes it holds.
fn shellSingleQuote(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const escaped = try std.mem.replaceOwned(u8, allocator, text, "'", "'\\''");
    defer allocator.free(escaped);
    const quoted = try std.fmt.allocPrint(allocator, "'{s}'", .{escaped});
    std.debug.assert(quoted.len >= 2 and quoted[0] == '\'' and quoted[quoted.len - 1] == '\'');
    return quoted;
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

fn needsShellQuoting(path: []const u8) bool {
    if (path.len == 0) return true;
    for (path) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-';
        if (!safe) return true;
    }
    return false;
}

fn formatRelayCommand(allocator: std.mem.Allocator, script_path: []const u8, event: []const u8) ![]u8 {
    std.debug.assert(event.len > 0);
    if (!needsShellQuoting(script_path)) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ script_path, event });
    }
    const quoted = try shellSingleQuote(allocator, script_path);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ quoted, event });
}

/// Check `opts` without building anything: `error.InvalidExtraSettings` for an
/// empty or non-UTF-8 extra hook, for `extra_settings_json` that is not a JSON
/// object, nests past `max_extra_settings_depth`, or sets
/// `"disableAllHooks": true`.
pub fn validateExtraSettings(allocator: std.mem.Allocator, opts: CreateOptions) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try parseExtraSettings(arena.allocator(), opts);
}

/// Validate `opts` and return the parsed `extra_settings_json` object, if any.
/// Everything is allocated from `scratch`, which must be an arena.
fn parseExtraSettings(scratch: std.mem.Allocator, opts: CreateOptions) !?std.json.ObjectMap {
    // Reject empty event names or commands up front before doing any work.
    // Invalid UTF-8 is rejected too: JSON cannot carry it, and the serializer
    // would emit the raw bytes and hand `claude` an unparseable `--settings`.
    for (opts.extra_hooks) |eh| {
        if (eh.event.len == 0 or eh.command.len == 0) return error.InvalidExtraSettings;
        if (!std.unicode.utf8ValidateSlice(eh.event)) return error.InvalidExtraSettings;
        if (!std.unicode.utf8ValidateSlice(eh.command)) return error.InvalidExtraSettings;
    }

    // Numbers stay unparsed so they are re-emitted verbatim.
    const raw = opts.extra_settings_json orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{
        .duplicate_field_behavior = .use_last,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidExtraSettings,
    };
    if (parsed != .object) return error.InvalidExtraSettings;
    if (jsonNestingDepth(raw) > max_extra_settings_depth) return error.InvalidExtraSettings;
    // `disableAllHooks: true` would silence the relay hooks this harness
    // depends on. `false` is harmless and passes through.
    if (parsed.object.get("disableAllHooks")) |v| {
        if (v == .bool and v.bool) return error.InvalidExtraSettings;
    }
    return parsed.object;
}

/// Build the inline `--settings` JSON string wiring relay and extra hooks.
pub fn buildSettingsJson(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    opts: CreateOptions,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Validate up front so invalid input returns error.InvalidExtraSettings
    // cleanly.
    const extra_obj = try parseExtraSettings(scratch, opts);

    // Group relay and extra hooks by unique event key in first-seen order.
    // Relay hooks are inserted first so they always stay authoritative at index 0.
    var events: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .{};
    for (relay_events) |ev| {
        const cmd = try formatRelayCommand(scratch, script_path, ev);
        var cmds: std.ArrayList([]const u8) = .{};
        try cmds.append(scratch, cmd);
        try events.put(scratch, ev, cmds);
    }
    std.debug.assert(events.count() == relay_events.len);
    for (opts.extra_hooks) |eh| {
        const gop = try events.getOrPut(scratch, eh.event);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(scratch, eh.command);
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeSettingsJson(&aw.writer, extra_obj, &events) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    return try aw.toOwnedSlice();
}

/// Maximum container nesting depth of a syntactically valid JSON document.
/// A scalar is depth 0; `{}` and `[]` are depth 1.
fn jsonNestingDepth(valid_json: []const u8) usize {
    var depth: usize = 0;
    var max_depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < valid_json.len) : (i += 1) {
        const c = valid_json[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                max_depth = @max(max_depth, depth);
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return max_depth;
}

fn writeSettingsJson(
    writer: *std.Io.Writer,
    extra_obj: ?std.json.ObjectMap,
    events: *const std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),
) std.Io.Writer.Error!void {
    var js = std.json.Stringify{ .writer = writer, .options = .{} };
    try js.beginObject();

    // Merge caller's top-level keys except `"hooks"`, which we own.
    if (extra_obj) |obj| {
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) continue;
            try js.objectField(entry.key_ptr.*);
            try js.write(entry.value_ptr.*);
        }
    }

    try js.objectField("hooks");
    try js.beginObject();
    var ev_it = events.iterator();
    while (ev_it.next()) |entry| {
        try js.objectField(entry.key_ptr.*);
        try js.beginArray();
        for (entry.value_ptr.items) |cmd| {
            try writeMatcherEntry(&js, cmd);
        }
        try js.endArray();
    }
    try js.endObject();
    try js.endObject();
}

fn writeMatcherEntry(js: *std.json.Stringify, command: []const u8) !void {
    std.debug.assert(command.len > 0);
    try js.beginObject();
    try js.objectField("matcher");
    try js.write("*");
    try js.objectField("hooks");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("command");
    try js.objectField("command");
    try js.write(command);
    try js.endObject();
    try js.endArray();
    try js.endObject();
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

fn testCommandAt(hooks: std.json.ObjectMap, event: []const u8, idx: usize) []const u8 {
    const entry = hooks.get(event).?.array.items[idx].object;
    return entry.get("hooks").?.array.items[0].object.get("command").?.string;
}

test "settings json: well-formed, contains all relay events" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 5), hooks.count());
    inline for (.{ "SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest" }) |ev| {
        const arr = hooks.get(ev).?.array;
        try testing.expectEqual(@as(usize, 1), arr.items.len);
        const first = arr.items[0].object;
        try testing.expectEqualStrings("*", first.get("matcher").?.string);
        const command = first.get("hooks").?.array.items[0].object;
        try testing.expectEqualStrings("command", command.get("type").?.string);
        try testing.expectEqualStrings("/tmp/hook.sh " ++ ev, command.get("command").?.string);
    }
}

test "settings json: shell-quotes script paths containing spaces or apostrophes" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/will's dir/hook.sh", .{});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expectEqualStrings("'/tmp/will'\\''s dir/hook.sh' Stop", testCommandAt(hooks, "Stop", 0));
}

test "settings json: extra hooks append after relay and group custom events under unique keys" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{
        .extra_hooks = &.{
            .{ .event = "Stop", .command = "notify-first" },
            .{ .event = "PreToolUse", .command = "audit-a" },
            .{ .event = "Stop", .command = "notify-second" },
            .{ .event = "PreToolUse", .command = "audit-b" },
        },
    });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 6), hooks.count());

    try testing.expectEqual(@as(usize, 3), hooks.get("Stop").?.array.items.len);
    try testing.expectEqualStrings("/tmp/hook.sh Stop", testCommandAt(hooks, "Stop", 0));
    try testing.expectEqualStrings("notify-first", testCommandAt(hooks, "Stop", 1));
    try testing.expectEqualStrings("notify-second", testCommandAt(hooks, "Stop", 2));

    try testing.expectEqual(@as(usize, 2), hooks.get("PreToolUse").?.array.items.len);
    try testing.expectEqualStrings("audit-a", testCommandAt(hooks, "PreToolUse", 0));
    try testing.expectEqualStrings("audit-b", testCommandAt(hooks, "PreToolUse", 1));

    try testing.expectEqual(@as(usize, 1), hooks.get("SessionStart").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), hooks.get("UserPromptSubmit").?.array.items.len);
}

test "settings json: merges extra_settings_json top-level keys, preserves numbers, and ignores hooks" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{
        .extra_settings_json =
        \\{"env":{"FOO":"bar"},"includeCoAuthoredBy":false,"precision":0.1234567890123456789,"hooks":{"Stop":[],"Evil":[]}}
        ,
    });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("bar", root.get("env").?.object.get("FOO").?.string);
    try testing.expectEqual(false, root.get("includeCoAuthoredBy").?.bool);
    try testing.expectEqualStrings("0.1234567890123456789", root.get("precision").?.number_string);

    const hooks = root.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 5), hooks.count());
    try testing.expect(hooks.get("Evil") == null);
    try testing.expectEqualStrings("/tmp/hook.sh Stop", testCommandAt(hooks, "Stop", 0));
}

test "settings json: rejects malformed extra_settings_json and empty extra_hooks before touching disk" {
    for ([_][]const u8{ "", "{", "[]", "null", "\"str\"", "42", "{} trailing" }) |bad| {
        try testing.expectError(
            error.InvalidExtraSettings,
            createWithOptions(testing.allocator, .{ .extra_settings_json = bad }),
        );
    }
    try testing.expectError(
        error.InvalidExtraSettings,
        createWithOptions(testing.allocator, .{
            .extra_hooks = &.{.{ .event = "", .command = "echo hi" }},
        }),
    );
    try testing.expectError(
        error.InvalidExtraSettings,
        createWithOptions(testing.allocator, .{
            .extra_hooks = &.{.{ .event = "Stop", .command = "" }},
        }),
    );
}

test "settings json: rejects extra_settings_json nested past max_extra_settings_depth" {
    const a = testing.allocator;
    const build = struct {
        fn doc(allocator: std.mem.Allocator, depth: usize) ![]u8 {
            // {"a":[[...]]} has `depth` containers including the top-level object.
            const inner = depth - 1;
            const buf = try allocator.alloc(u8, 5 + 2 * inner + 1 + 1);
            @memcpy(buf[0..5], "{\"a\":");
            @memset(buf[5 .. 5 + inner], '[');
            @memset(buf[5 + inner .. 5 + 2 * inner], ']');
            buf[5 + 2 * inner] = '}';
            buf[5 + 2 * inner + 1] = ' ';
            return buf;
        }
    };

    const ok_doc = try build.doc(a, max_extra_settings_depth);
    defer a.free(ok_doc);
    const ok = try buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = ok_doc });
    defer a.free(ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, ok, .{});
    parsed.deinit();

    // Depth 257 used to index past std.json.Stringify's 256-level nesting stack.
    for ([_]usize{ max_extra_settings_depth + 1, 257, 5000 }) |depth| {
        const deep = try build.doc(a, depth);
        defer a.free(deep);
        try testing.expectError(
            error.InvalidExtraSettings,
            buildSettingsJson(a, "/tmp/hook.sh", .{ .extra_settings_json = deep }),
        );
    }

    // Brackets inside strings do not count toward depth.
    const brackets_in_string = try buildSettingsJson(a, "/tmp/hook.sh", .{
        .extra_settings_json = "{\"a\":\"" ++ "[" ** 400 ++ "\\\"{{\"}",
    });
    a.free(brackets_in_string);
}

test "settings json: rejects extra hooks that are not valid UTF-8" {
    for ([_]ExtraHook{
        .{ .event = "Stop\xff", .command = "echo hi" },
        .{ .event = "Stop", .command = "echo \xc3" },
        .{ .event = "Stop", .command = "\xed\xa0\x80" },
    }) |eh| {
        try testing.expectError(
            error.InvalidExtraSettings,
            createWithOptions(testing.allocator, .{ .extra_hooks = &.{eh} }),
        );
    }
}

test "settings json: allocation failures leak nothing" {
    const Ctx = struct {
        fn build(allocator: std.mem.Allocator) !void {
            const json = try buildSettingsJson(allocator, "/tmp/hook.sh", .{
                .extra_hooks = &.{
                    .{ .event = "Stop", .command = "echo done" },
                    .{ .event = "Notification", .command = "echo \"quoted\"" },
                },
                .extra_settings_json = "{\"model\":\"opus\"}",
            });
            allocator.free(json);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.build, .{});
}

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
    try testing.expectEqualStrings("echo done", testCommandAt(hooks, "PostToolUse", 0));
    try testing.expect(std.mem.indexOf(u8, testCommandAt(hooks, "Stop", 0), h.script_path) != null);
}

test "settings json: rejects disableAllHooks true and accepts every other value" {
    const a = testing.allocator;
    for ([_][]const u8{
        "{\"disableAllHooks\":true}",
        " { \"model\" : \"opus\" , \"disableAllHooks\" : true } ",
        "{\"disable\\u0041llHooks\":true}",
        "{\"disableAllHooks\":false,\"disableAllHooks\":true}",
    }) |bad| {
        const opts: CreateOptions = .{ .extra_settings_json = bad };
        try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(a, opts));
        try testing.expectError(error.InvalidExtraSettings, buildSettingsJson(a, "/tmp/hook.sh", opts));
        try testing.expectError(error.InvalidExtraSettings, createWithOptions(a, opts));
    }
    for ([_][]const u8{
        "{\"disableAllHooks\":false}",
        "{\"disableAllHooks\":true,\"disableAllHooks\":false}",
        "{\"disableAllHooks\":\"true\"}",
        "{\"disableAllHooks\":1}",
        "{\"env\":{\"disableAllHooks\":true}}",
        "{\"DisableAllHooks\":true}",
    }) |ok| {
        const opts: CreateOptions = .{ .extra_settings_json = ok };
        try validateExtraSettings(a, opts);
        const json = try buildSettingsJson(a, "/tmp/hook.sh", opts);
        a.free(json);
    }
}

test "HookEvent: StopFailure maps to stop_failure" {
    try testing.expectEqual(HookEvent.stop_failure, HookEvent.fromString("StopFailure"));
    try testing.expectEqual(HookEvent.unknown, HookEvent.fromString("stopfailure"));
    const ln = parseLine("StopFailure\t{\"error\":\"rate_limit\"}\n").?;
    try testing.expectEqual(HookEvent.stop_failure, ln.event);
}

test "extractErrorMessage: error, then message, then reason" {
    const a = testing.allocator;
    const cases = [_]struct { payload: []const u8, want: ?[]const u8 }{
        .{ .payload = "{\"error\":\"rate_limit\",\"message\":\"m\",\"reason\":\"r\"}", .want = "rate_limit" },
        .{ .payload = "{\"reason\":\"r\",\"message\":\"m\"}", .want = "m" },
        .{ .payload = "{\"reason\":\"overloaded\\nretry\"}", .want = "overloaded\nretry" },
        .{ .payload = "{\"error\":{\"type\":\"api\",\"message\":\"boom\"},\"reason\":\"r\"}", .want = "boom" },
        .{ .payload = "{\"error\":42,\"message\":null,\"reason\":\"r\"}", .want = "r" },
        .{ .payload = "{\"error\":{\"message\":7}}", .want = null },
        .{ .payload = "{\"error\":\"\"}", .want = "" },
        .{ .payload = "{}", .want = null },
        .{ .payload = "[]", .want = null },
        .{ .payload = "not-json", .want = null },
    };
    for (cases) |case| {
        const got = extractErrorMessage(a, case.payload);
        defer if (got) |g| a.free(g);
        if (case.want) |want| {
            try testing.expectEqualStrings(want, got orelse return error.TestExpectedString);
        } else {
            try testing.expectEqual(@as(?[]u8, null), got);
        }
    }
}

test "extractErrorMessage: allocation failures leak nothing" {
    const Ctx = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const got = try extractFirstMessage(allocator, "{\"error\":{\"message\":\"boom\"}}", &.{"error"});
            if (got) |g| allocator.free(g);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.run, .{});
}

test "parseLineWithNonce: accepts only lines carrying the expected nonce" {
    const nonce = "0123456789abcdef";
    const ln = parseLineWithNonce("0123456789abcdef\tStop\t{\"a\":1}\n", nonce).?;
    try testing.expectEqual(HookEvent.stop, ln.event);
    try testing.expectEqualStrings("{\"a\":1}", ln.payload);

    const crlf = parseLineWithNonce("0123456789abcdef\tStopFailure\t{}\r\n", nonce).?;
    try testing.expectEqual(HookEvent.stop_failure, crlf.event);

    for ([_][]const u8{
        "Stop\t{}", // legacy line, no nonce
        "0123456789abcdee\tStop\t{}", // another run's nonce
        "0123456789abcde\tStop\t{}", // short
        "0123456789abcdef0\tStop\t{}", // long
        "0123456789ABCDEF\tStop\t{}",
        "0123456789abcdef\tStop", // no payload field
        "0123456789abcdef\t",
        "0123456789abcdef",
        "\tStop\t{}",
        "",
    }) |bad| {
        try testing.expectEqual(@as(?HookLine, null), parseLineWithNonce(bad, nonce));
    }
    // An empty expected nonce authenticates nothing.
    try testing.expectEqual(@as(?HookLine, null), parseLineWithNonce("\tStop\t{}", ""));
}

test "parseLine: skips a relay nonce without checking it" {
    const ln = parseLine("0123456789abcdef\tUserPromptSubmit\t{\"prompt\":\"hi\"}\n").?;
    try testing.expectEqual(HookEvent.user_prompt_submit, ln.event);
    try testing.expectEqualStrings("{\"prompt\":\"hi\"}", ln.payload);

    // A nonce-shaped first field with nothing tab-separated behind it is a
    // plain `<event>\t<payload>` line.
    const plain = parseLine("0123456789abcdef\t{}").?;
    try testing.expectEqual(HookEvent.unknown, plain.event);
    try testing.expectEqualStrings("{}", plain.payload);
}

test "buildScript: embeds the quoted FIFO path and nonce" {
    const script = try buildScript(testing.allocator, "/tmp/will's dir/events.fifo", "0123456789abcdef");
    defer testing.allocator.free(script);
    try testing.expect(std.mem.startsWith(u8, script, "#!/bin/sh\n"));
    try testing.expect(std.mem.indexOf(u8, script, "\nfifo='/tmp/will'\\''s dir/events.fifo'\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\nnonce='0123456789abcdef'\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "CLAUDE_P_FIFO") == null);
}

test "resolveTmpRoot: unset or empty is /tmp, absolute is kept, relative becomes absolute" {
    const a = testing.allocator;
    inline for (.{ @as(?[]const u8, null), @as(?[]const u8, "") }) |unset| {
        const root = try resolveTmpRoot(a, unset);
        defer a.free(root);
        try testing.expectEqualStrings("/tmp", root);
    }
    {
        const root = try resolveTmpRoot(a, "/var/tmp/x y/");
        defer a.free(root);
        try testing.expectEqualStrings("/var/tmp/x y/", root);
    }
    {
        const cwd = try std.fs.cwd().realpathAlloc(a, ".");
        defer a.free(cwd);
        const root = try resolveTmpRoot(a, ".");
        defer a.free(root);
        try testing.expect(std.fs.path.isAbsolute(root));
        try testing.expectEqualStrings(cwd, root);
    }
    try testing.expectError(error.FileNotFound, resolveTmpRoot(a, "no-such-dir-claude-p/nested"));
}

var test_suffixes: []const u64 = &.{};
var test_suffix_calls: usize = 0;
fn testSuffix() u64 {
    defer test_suffix_calls += 1;
    return test_suffixes[@min(test_suffix_calls, test_suffixes.len - 1)];
}

test "makeExclusiveTmpDir: 0700, never adopts an existing path, gives up after 16 tries" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    // Names 1 and 2 are taken: a directory and a symlink to elsewhere.
    try tmp.dir.makeDir("claude-p-7-0000000000000001");
    try tmp.dir.makeDir("elsewhere");
    try tmp.dir.symLink("elsewhere", "claude-p-7-0000000000000002", .{});

    test_suffixes = &.{ 1, 2, 3 };
    test_suffix_calls = 0;
    const made = try makeExclusiveTmpDir(a, root, 7, testSuffix);
    defer a.free(made);
    try testing.expectEqual(@as(usize, 3), test_suffix_calls);
    try testing.expect(std.mem.endsWith(u8, made, "/claude-p-7-0000000000000003"));
    const st = try std.fs.cwd().statFile(made);
    try testing.expectEqual(std.fs.File.Kind.directory, st.kind);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);
    // Nothing was written through the symlink.
    var elsewhere = try tmp.dir.openDir("elsewhere", .{ .iterate = true });
    defer elsewhere.close();
    var it = elsewhere.iterate();
    try testing.expectEqual(@as(?std.fs.Dir.Entry, null), try it.next());

    test_suffixes = &.{1};
    test_suffix_calls = 0;
    try testing.expectError(error.PathAlreadyExists, makeExclusiveTmpDir(a, root, 7, testSuffix));
    try testing.expectEqual(@as(usize, max_tmp_dir_attempts), test_suffix_calls);
}

test "create: private directory, embedded script, distinct nonces" {
    var h = try create(testing.allocator);
    defer h.deinit();
    var other = try create(testing.allocator);
    defer other.deinit();

    try testing.expect(std.fs.path.isAbsolute(h.tmp_dir));
    const dir_stat = try std.fs.cwd().statFile(h.tmp_dir);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), dir_stat.mode & 0o777);
    const script_stat = try std.fs.cwd().statFile(h.script_path);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), script_stat.mode & 0o777);

    try testing.expect(isNonceShaped(&h.nonce));
    try testing.expect(isNonceShaped(&other.nonce));
    try testing.expect(!std.mem.eql(u8, &h.nonce, &other.nonce));
    try testing.expect(!std.mem.eql(u8, h.tmp_dir, other.tmp_dir));

    const want = try buildScript(testing.allocator, h.fifo_path, &h.nonce);
    defer testing.allocator.free(want);
    const got = try std.fs.cwd().readFileAlloc(testing.allocator, h.script_path, 1 << 16);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "PermissionRequest tool and active Stop hook payloads" {
    try testing.expectEqual(HookEvent.permission_request, HookEvent.fromString("PermissionRequest"));
    for ([_][]const u8{ "{\"tool_name\":\"Bash\",\"message\":\"fallback\"}", "{\"message\":\"Bash\"}" }) |payload| {
        const tool = extractPermissionTool(testing.allocator, payload).?;
        defer testing.allocator.free(tool);
        try testing.expectEqualStrings("Bash", tool);
    }
    try testing.expect(parseStopHookActive(testing.allocator, "{\"stop_hook_active\":true}"));
    for ([_][]const u8{ "{}", "{\"stop_hook_active\":false}", "{\"stop_hook_active\":\"true\"}", "malformed" }) |payload|
        try testing.expect(!parseStopHookActive(testing.allocator, payload));
}
