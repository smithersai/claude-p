//! Generates the SessionStart/UserPromptSubmit/Stop hook plumbing for a
//! `claude` invocation: a per-run temp dir, a FIFO the parent reads, a tiny
//! shell script that relays the hook payload to the FIFO, and the inline
//! `--settings` JSON that tells `claude` to call it.
//!
//! Lifetime: caller owns the HookHarness and must `deinit` it; the temp
//! directory and FIFO are removed there.
const std = @import("std");

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

pub const ExtraHook = struct {
    event: []const u8,
    command: []const u8,
};

pub const CreateOptions = struct {
    /// Appended after the relay hook for the same event, or added under a new
    /// event key. Relay hooks always remain first and authoritative.
    extra_hooks: []const ExtraHook = &.{},
    /// Optional JSON object whose top-level keys (other than `"hooks"`) are
    /// merged into the generated `--settings` object.
    extra_settings_json: ?[]const u8 = null,
};

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
    \\#   $1 = event name (e.g. "Stop", "SessionStart", "UserPromptSubmit")
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

const relay_events = [_][]const u8{
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
};

fn tmpRoot() []const u8 {
    return std.posix.getenv("TMPDIR") orelse "/tmp";
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

    const fifo_path = try std.fmt.allocPrint(allocator, "{s}/events.fifo", .{tmp_dir});
    errdefer allocator.free(fifo_path);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/hook.sh", .{tmp_dir});
    errdefer allocator.free(script_path);

    // Build and validate settings JSON BEFORE creating any files on disk.
    const settings_json = try buildSettingsJson(allocator, script_path, opts);
    errdefer allocator.free(settings_json);

    try std.fs.cwd().makePath(tmp_dir);
    errdefer std.fs.cwd().deleteDir(tmp_dir) catch {};

    // mkfifo via libc.
    const c_fifo_path = try allocator.dupeZ(u8, fifo_path);
    defer allocator.free(c_fifo_path);
    if (mkfifo(c_fifo_path.ptr, 0o600) != 0) {
        return error.MkfifoFailed;
    }
    errdefer std.fs.cwd().deleteFile(fifo_path) catch {};

    // Write the relay script.
    {
        var script_file = try std.fs.cwd().createFile(script_path, .{ .mode = 0o700 });
        defer script_file.close();
        try script_file.writeAll(script_body);
    }
    errdefer std.fs.cwd().deleteFile(script_path) catch {};

    return HookHarness{
        .allocator = allocator,
        .tmp_dir = tmp_dir,
        .fifo_path = fifo_path,
        .script_path = script_path,
        .settings_json = settings_json,
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
    if (!needsShellQuoting(script_path)) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ script_path, event });
    }
    const escaped = try std.mem.replaceOwned(u8, allocator, script_path, "'", "'\\''");
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "'{s}' {s}", .{ escaped, event });
}

fn buildSettingsJson(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    opts: CreateOptions,
) ![]u8 {
    // Reject empty event names or commands up front before doing any work.
    for (opts.extra_hooks) |eh| {
        if (eh.event.len == 0 or eh.command.len == 0) return error.InvalidExtraSettings;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Parse extra_settings_json up front (preserving number precision verbatim)
    // so invalid input returns error.InvalidExtraSettings cleanly.
    const extra_obj: ?std.json.ObjectMap = if (opts.extra_settings_json) |raw| blk: {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{
            .duplicate_field_behavior = .use_last,
            .parse_numbers = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidExtraSettings,
        };
        if (parsed != .object) return error.InvalidExtraSettings;
        break :blk parsed.object;
    } else null;

    // Group relay and extra hooks by unique event key in first-seen order.
    // Relay hooks are inserted first so they always stay authoritative at index 0.
    var events: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .{};
    for (relay_events) |ev| {
        const cmd = try formatRelayCommand(scratch, script_path, ev);
        var cmds: std.ArrayList([]const u8) = .{};
        try cmds.append(scratch, cmd);
        try events.put(scratch, ev, cmds);
    }
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

fn extractStringField(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    field: []const u8,
) !?[]u8 {
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

test "settings json: well-formed, contains all three relay events" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 3), hooks.count());
    inline for (.{ "SessionStart", "UserPromptSubmit", "Stop" }) |ev| {
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
    try testing.expectEqual(@as(usize, 4), hooks.count());

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
    try testing.expectEqual(@as(usize, 3), hooks.count());
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
