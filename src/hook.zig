//! Generates the Stop/SessionStart hook plumbing for a `claude` invocation:
//! a per-run temp dir, a FIFO the parent reads, a tiny shell script that
//! relays the hook payload to the FIFO, and the inline `--settings` JSON
//! that tells `claude` to call it.
//!
//! Lifetime: caller owns the HookHarness and must `deinit` it; the temp
//! directory and FIFO are removed there.
const std = @import("std");

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

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

    pub fn deinit(self: *HookHarness) void {
        // Best-effort cleanup.
        std.fs.cwd().deleteFile(self.fifo_path) catch {};
        std.fs.cwd().deleteFile(self.script_path) catch {};
        std.fs.cwd().deleteDir(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
        self.allocator.free(self.fifo_path);
        self.allocator.free(self.script_path);
        self.allocator.free(self.settings_json);
    }
};

/// A caller-supplied hook merged into the generated settings (`--extra-hook`).
/// `event` is a Claude hook event name (e.g. "PostToolUse"); `command` is the
/// shell command to run. Strings are borrowed (typically from argv).
pub const ExtraHook = struct {
    event: []const u8,
    command: []const u8,
};

/// Parse a `<Event>=<command>` spec into an ExtraHook. The split is on the
/// *first* `=`, so the command may itself contain `=`. A missing `=`, an empty
/// event, or an empty command is a hard error (no silent drop — SPEC §2.8).
pub fn parseExtraHook(spec: []const u8) error{InvalidExtraHook}!ExtraHook {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidExtraHook;
    const event = spec[0..eq];
    const command = spec[eq + 1 ..];
    if (event.len == 0 or command.len == 0) return error.InvalidExtraHook;
    return .{ .event = event, .command = command };
}

const script_body =
    \\#!/bin/sh
    \\# Relay a Claude Code hook event to claude-p's FIFO.
    \\#   $1 = event name (e.g. "Stop", "SessionStart")
    \\# stdin = the hook's JSON payload (single line, no embedded newlines).
    \\set -eu
    \\event="$1"
    \\fifo="${CLAUDE_P_FIFO:?missing CLAUDE_P_FIFO}"
    \\# Read the JSON payload and emit one line: "<event>\t<payload>"
    \\payload="$(cat)"
    \\printf '%s\t%s\n' "$event" "$payload" >> "$fifo"
    \\exit 0
    \\
;

fn tmpRoot() []const u8 {
    return std.posix.getenv("TMPDIR") orelse "/tmp";
}

/// Build a harness — creates tmp dir, FIFO, script, and settings JSON.
/// `extra_hooks` are merged into the generated settings (SPEC §2.8); pass
/// `&.{}` for none. `extra_settings_json` (SPEC §2.9) is an optional JSON
/// object whose top-level keys are merged in; pass `null` for none.
pub fn create(
    allocator: std.mem.Allocator,
    extra_hooks: []const ExtraHook,
    extra_settings_json: ?[]const u8,
) !HookHarness {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    const rand_suffix: u32 = rng.random().int(u32);
    const pid: i32 = @intCast(std.posix.system.getpid());

    const tmp_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/claude-p-{d}-{x}",
        .{ tmpRoot(), pid, rand_suffix },
    );
    errdefer allocator.free(tmp_dir);

    try std.fs.cwd().makePath(tmp_dir);

    const fifo_path = try std.fmt.allocPrint(allocator, "{s}/events.fifo", .{tmp_dir});
    errdefer allocator.free(fifo_path);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/hook.sh", .{tmp_dir});
    errdefer allocator.free(script_path);

    // mkfifo via libc.
    const c_fifo_path = try allocator.dupeZ(u8, fifo_path);
    defer allocator.free(c_fifo_path);
    if (mkfifo(c_fifo_path.ptr, 0o600) != 0) {
        return error.MkfifoFailed;
    }

    // Write the relay script.
    var script_file = try std.fs.cwd().createFile(script_path, .{ .mode = 0o700 });
    defer script_file.close();
    try script_file.writeAll(script_body);

    const settings_json = try buildSettingsJson(allocator, script_path, extra_hooks, extra_settings_json);
    errdefer allocator.free(settings_json);

    return HookHarness{
        .allocator = allocator,
        .tmp_dir = tmp_dir,
        .fifo_path = fifo_path,
        .script_path = script_path,
        .settings_json = settings_json,
    };
}

fn buildSettingsJson(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    extra_hooks: []const ExtraHook,
    extra_settings_json: ?[]const u8,
) ![]u8 {
    // Parse + validate caller-supplied settings (SPEC §2.9) BEFORE allocating
    // the output writer, so an invalid value errors without leaking the writer.
    var parsed_settings: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_settings) |*p| p.deinit();
    if (extra_settings_json) |raw| {
        parsed_settings = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        if (parsed_settings.?.value != .object) return error.InvalidSettingJson;
    }

    // Two hooks — SessionStart (so we know the UI is ready) and Stop (turn
    // finished). The relay script reads stdin and appends a line to the FIFO.
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;
    var js = std.json.Stringify{ .writer = w, .options = .{} };
    try js.beginObject();

    // Merge the validated top-level settings keys. A `hooks` key is skipped —
    // our relay hooks are authoritative.
    if (parsed_settings) |p| {
        var it = p.value.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) continue;
            try js.objectField(entry.key_ptr.*);
            try js.write(entry.value_ptr.*);
        }
    }

    try js.objectField("hooks");
    try js.beginObject();
    // Relay events first; extra hooks for these are appended to the same array.
    try writeEventArray(allocator, &js, "SessionStart", script_path, extra_hooks);
    try writeEventArray(allocator, &js, "Stop", script_path, extra_hooks);

    // Then any novel events from extra_hooks, in first-seen order, written once.
    for (extra_hooks, 0..) |h, idx| {
        if (std.mem.eql(u8, h.event, "SessionStart") or std.mem.eql(u8, h.event, "Stop")) continue;
        if (eventSeenBefore(extra_hooks, idx)) continue;
        try writeEventArray(allocator, &js, h.event, null, extra_hooks);
    }

    try js.endObject();
    try js.endObject();
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

/// True if `extra_hooks[before].event` already appears at an earlier index.
fn eventSeenBefore(extra_hooks: []const ExtraHook, before: usize) bool {
    var j: usize = 0;
    while (j < before) : (j += 1) {
        if (std.mem.eql(u8, extra_hooks[j].event, extra_hooks[before].event)) return true;
    }
    return false;
}

/// Write one event's matcher-group array. If `script_path` is non-null, the
/// relay group (`<script> <event>`) is written first; then every extra hook
/// whose `.event` matches is appended in order.
fn writeEventArray(
    allocator: std.mem.Allocator,
    js: *std.json.Stringify,
    event: []const u8,
    script_path: ?[]const u8,
    extra_hooks: []const ExtraHook,
) !void {
    try js.objectField(event);
    try js.beginArray();
    if (script_path) |sp| {
        const cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ sp, event });
        defer allocator.free(cmd);
        try writeMatcherGroup(js, cmd);
    }
    for (extra_hooks) |h| {
        if (std.mem.eql(u8, h.event, event)) try writeMatcherGroup(js, h.command);
    }
    try js.endArray();
}

/// Write a single `{"matcher":"*","hooks":[{"type":"command","command":<cmd>}]}`
/// group into the current array context.
fn writeMatcherGroup(js: *std.json.Stringify, command: []const u8) !void {
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

pub const HookEvent = enum {
    session_start,
    stop,
    unknown,

    pub fn fromString(s: []const u8) HookEvent {
        if (std.mem.eql(u8, s, "SessionStart")) return .session_start;
        if (std.mem.eql(u8, s, "Stop")) return .stop;
        return .unknown;
    }
};

pub const HookLine = struct {
    event: HookEvent,
    payload: []const u8, // borrowed from the input buffer
};

/// Parse a single hook-line of the form "<event>\t<json>" emitted by the
/// relay script. Trailing newline is tolerated.
pub fn parseLine(raw: []const u8) ?HookLine {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return .{
        .event = HookEvent.fromString(line[0..tab]),
        .payload = line[tab + 1 ..],
    };
}

/// Pull `transcript_path` out of a Stop-hook payload JSON.
/// Returned slice is heap-allocated.
pub fn extractTranscriptPath(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "transcript_path");
}

/// Pull `last_assistant_message` out of a Stop-hook payload — recent Claude
/// Code versions include this string in the payload directly, which lets us
/// short-circuit transcript parsing entirely for the text format.
pub fn extractLastAssistantMessage(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "last_assistant_message");
}

/// Pull `session_id` out of a Stop/SessionStart hook payload.
pub fn extractSessionId(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    return try extractStringField(allocator, payload_json, "session_id");
}

fn extractStringField(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    field: []const u8,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(field) orelse return null;
    if (v != .string) return null;
    return try allocator.dupe(u8, v.string);
}

// -------- tests --------

const testing = std.testing;

test "settings json: well-formed, contains both events" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", &.{}, null);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expect(hooks.get("SessionStart") != null);
    try testing.expect(hooks.get("Stop") != null);

    // Each event maps to an array of matcher entries.
    const session_start = hooks.get("SessionStart").?.array;
    try testing.expect(session_start.items.len >= 1);
    const first = session_start.items[0].object;
    try testing.expectEqualStrings("*", first.get("matcher").?.string);

    const command = first.get("hooks").?.array.items[0].object;
    try testing.expectEqualStrings("command", command.get("type").?.string);
    try testing.expect(std.mem.indexOf(u8, command.get("command").?.string, "/tmp/hook.sh") != null);
    try testing.expect(std.mem.endsWith(u8, command.get("command").?.string, " SessionStart"));
}

test "parseExtraHook: valid Event=command" {
    const h = try parseExtraHook("PostToolUse=/path/tracker.sh --flag");
    try testing.expectEqualStrings("PostToolUse", h.event);
    try testing.expectEqualStrings("/path/tracker.sh --flag", h.command);
}

test "parseExtraHook: command may contain '='" {
    const h = try parseExtraHook("PostToolUse=FOO=bar tracker.sh");
    try testing.expectEqualStrings("PostToolUse", h.event);
    try testing.expectEqualStrings("FOO=bar tracker.sh", h.command);
}

test "parseExtraHook: missing '=' / empty side errors" {
    try testing.expectError(error.InvalidExtraHook, parseExtraHook("PostToolUse"));
    try testing.expectError(error.InvalidExtraHook, parseExtraHook("=cmd"));
    try testing.expectError(error.InvalidExtraHook, parseExtraHook("Event="));
}

test "settings json: extra hook adds a new event key" {
    const extra = [_]ExtraHook{.{ .event = "PostToolUse", .command = "/x/track.sh" }};
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", &extra, null);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const hooks = parsed.value.object.get("hooks").?.object;
    // Relay events still present.
    try testing.expect(hooks.get("SessionStart") != null);
    try testing.expect(hooks.get("Stop") != null);
    // New event present with the user command.
    const ptu = hooks.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), ptu.items.len);
    const cmd = ptu.items[0].object.get("hooks").?.array.items[0].object;
    try testing.expectEqualStrings("/x/track.sh", cmd.get("command").?.string);
    try testing.expectEqualStrings("*", ptu.items[0].object.get("matcher").?.string);
}

test "settings json: extra hook for Stop appends to relay group (both run)" {
    const extra = [_]ExtraHook{.{ .event = "Stop", .command = "/x/also.sh" }};
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", &extra, null);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const stop = parsed.value.object.get("hooks").?.object.get("Stop").?.array;
    // Two matcher groups: the relay + the user's appended hook.
    try testing.expectEqual(@as(usize, 2), stop.items.len);
    const relay_cmd = stop.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expect(std.mem.endsWith(u8, relay_cmd, " Stop"));
    const user_cmd = stop.items[1].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("/x/also.sh", user_cmd);
}

test "settings json: multiple extra hooks for same new event accumulate" {
    const extra = [_]ExtraHook{
        .{ .event = "PostToolUse", .command = "/a.sh" },
        .{ .event = "PostToolUse", .command = "/b.sh" },
    };
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", &extra, null);
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const ptu = parsed.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 2), ptu.items.len);
}

test "settings json: merges extra top-level settings keys (--setting-json)" {
    const json = try buildSettingsJson(
        testing.allocator,
        "/tmp/hook.sh",
        &.{},
        "{\"showThinkingSummaries\":true,\"foo\":42}",
    );
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Merged keys present.
    try testing.expect(obj.get("showThinkingSummaries").?.bool);
    try testing.expectEqual(@as(i64, 42), obj.get("foo").?.integer);
    // Relay hooks still present and authoritative.
    try testing.expect(obj.get("hooks").?.object.get("SessionStart") != null);
    try testing.expect(obj.get("hooks").?.object.get("Stop") != null);
}

test "settings json: extra-settings 'hooks' key is ignored (relay wins)" {
    const json = try buildSettingsJson(
        testing.allocator,
        "/tmp/hook.sh",
        &.{},
        "{\"hooks\":{\"Evil\":[]},\"x\":1}",
    );
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const hooks = parsed.value.object.get("hooks").?.object;
    // Our relay hooks, not the caller's bogus "Evil" event.
    try testing.expect(hooks.get("SessionStart") != null);
    try testing.expect(hooks.get("Evil") == null);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("x").?.integer);
}

test "settings json: non-object --setting-json is a hard error" {
    try testing.expectError(
        error.InvalidSettingJson,
        buildSettingsJson(testing.allocator, "/tmp/hook.sh", &.{}, "[1,2,3]"),
    );
}

test "parseLine: well-formed" {
    const ln = parseLine("Stop\t{\"transcript_path\":\"/tmp/x.jsonl\"}\n").?;
    try testing.expectEqual(HookEvent.stop, ln.event);
    try testing.expectEqualStrings("{\"transcript_path\":\"/tmp/x.jsonl\"}", ln.payload);
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

test "create + deinit round-trip on tmp" {
    var h = try create(testing.allocator, &.{}, null);
    defer h.deinit();
    // FIFO and script exist.
    const sf = try std.fs.cwd().openFile(h.script_path, .{});
    sf.close();
    // FIFO should exist (open in nonblock mode succeeds for FIFOs).
    const path_z = try testing.allocator.dupeZ(u8, h.fifo_path);
    defer testing.allocator.free(path_z);
    const fd = try std.posix.openZ(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    std.posix.close(fd);
}
