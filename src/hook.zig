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
pub fn create(allocator: std.mem.Allocator) !HookHarness {
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

    const settings_json = try buildSettingsJson(allocator, script_path);
    errdefer allocator.free(settings_json);

    return HookHarness{
        .allocator = allocator,
        .tmp_dir = tmp_dir,
        .fifo_path = fifo_path,
        .script_path = script_path,
        .settings_json = settings_json,
    };
}

fn buildSettingsJson(allocator: std.mem.Allocator, script_path: []const u8) ![]u8 {
    // Three hooks — SessionStart (UI is ready), UserPromptSubmit (claude
    // actually accepted our typed prompt), and Stop (turn finished). The relay
    // script reads stdin and appends a line to the FIFO.
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;
    var js = std.json.Stringify{ .writer = w, .options = .{} };
    try js.beginObject();
    try js.objectField("hooks");
    try js.beginObject();
    try writeEvent(&js, "SessionStart", script_path);
    try writeEvent(&js, "UserPromptSubmit", script_path);
    try writeEvent(&js, "Stop", script_path);
    try js.endObject();
    try js.endObject();
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

fn writeEvent(js: *std.json.Stringify, event: []const u8, script_path: []const u8) !void {
    try js.objectField(event);
    try js.beginArray();
    try js.beginObject();
    try js.objectField("matcher");
    try js.write("*");
    try js.objectField("hooks");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("command");
    try js.objectField("command");
    // The relay script takes the event name as $1.
    const cmd = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s} {s}",
        .{ script_path, event },
    );
    defer std.heap.page_allocator.free(cmd);
    try js.write(cmd);
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endArray();
}

pub const HookEvent = enum {
    session_start,
    user_prompt_submit,
    stop,
    unknown,

    pub fn fromString(s: []const u8) HookEvent {
        if (std.mem.eql(u8, s, "SessionStart")) return .session_start;
        if (std.mem.eql(u8, s, "UserPromptSubmit")) return .user_prompt_submit;
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
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh");
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expect(hooks.get("SessionStart") != null);
    try testing.expect(hooks.get("UserPromptSubmit") != null);
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
    var h = try create(testing.allocator);
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
