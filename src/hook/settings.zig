//! Settings JSON builder, shell quoting, and extra-settings depth/safety validation
//! for Claude Code `--settings` hook harnesses.
const std = @import("std");

/// Additional user-configured hook command bound to a Claude Code hook event.
pub const ExtraHook = struct {
    event: []const u8,
    command: []const u8,
};

/// Options controlling extra hooks and extra `--settings` JSON merged into a harness.
pub const CreateOptions = struct {
    extra_hooks: []const ExtraHook = &.{},
    extra_settings_json: ?[]const u8 = null,
};

/// Maximum container nesting depth accepted in `extra_settings_json`.
pub const max_extra_settings_depth: usize = 128;

/// Built-in Claude Code hook events wired to the relay script.
pub const relay_events = [_][]const u8{
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "StopFailure",
    "PermissionRequest",
};

/// Quote `text` as one POSIX shell word, whatever bytes it holds.
pub fn shellSingleQuote(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const escaped = try std.mem.replaceOwned(u8, allocator, text, "'", "'\\''");
    defer allocator.free(escaped);
    const quoted = try std.fmt.allocPrint(allocator, "'{s}'", .{escaped});
    std.debug.assert(quoted.len >= 2 and quoted[0] == '\'' and quoted[quoted.len - 1] == '\'');
    return quoted;
}

/// Return true when `path` contains characters that require POSIX shell quoting.
pub fn needsShellQuoting(path: []const u8) bool {
    if (path.len == 0) return true;
    for (path) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-';
        if (!safe) return true;
    }
    return false;
}

/// Format the relay shell command invoking `script_path` for `event`.
pub fn formatRelayCommand(allocator: std.mem.Allocator, script_path: []const u8, event: []const u8) ![]u8 {
    std.debug.assert(event.len > 0);
    if (!needsShellQuoting(script_path)) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ script_path, event });
    }
    const quoted = try shellSingleQuote(allocator, script_path);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ quoted, event });
}

/// Validate `opts` without creating files on disk.
pub fn validateExtraSettings(allocator: std.mem.Allocator, opts: CreateOptions) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try parseExtraSettings(arena.allocator(), opts);
}

fn parseExtraSettings(scratch: std.mem.Allocator, opts: CreateOptions) !?std.json.ObjectMap {
    for (opts.extra_hooks) |eh| {
        if (eh.event.len == 0 or eh.command.len == 0) return error.InvalidExtraSettings;
        if (!std.unicode.utf8ValidateSlice(eh.event)) return error.InvalidExtraSettings;
        if (!std.unicode.utf8ValidateSlice(eh.command)) return error.InvalidExtraSettings;
    }
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
    const extra_obj = try parseExtraSettings(scratch, opts);

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
pub fn jsonNestingDepth(valid_json: []const u8) usize {
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
    std.debug.assert(max_depth >= depth);
    return max_depth;
}

fn writeSettingsJson(
    writer: *std.Io.Writer,
    extra_obj: ?std.json.ObjectMap,
    events: *const std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),
) std.Io.Writer.Error!void {
    std.debug.assert(@intFromPtr(writer) != 0);
    var js = std.json.Stringify{ .writer = writer, .options = .{} };
    try js.beginObject();
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
        for (entry.value_ptr.items) |cmd| try writeMatcherEntry(&js, cmd);
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

// -------- tests --------
const testing = std.testing;

test "buildSettingsJson: well-formed and contains all 5 relay events" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{});
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const hooks = parsed.value.object.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 5), hooks.count());
}

test "buildSettingsJson: quotes script paths with spaces or apostrophes" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/it's dir/hook.sh", .{});
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const entry = parsed.value.object.get("hooks").?.object.get("Stop").?.array.items[0].object;
    const cmd = entry.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("'/tmp/it'\\''s dir/hook.sh' Stop", cmd);
}

test "buildSettingsJson: appends extra hooks after relay hooks" {
    const extra = [_]ExtraHook{.{ .event = "Stop", .command = "echo after" }};
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{ .extra_hooks = &extra });
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("hooks").?.object.get("Stop").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
}

test "buildSettingsJson: groups custom event hooks under unique key" {
    const extra = [_]ExtraHook{
        .{ .event = "PreToolUse", .command = "echo 1" },
        .{ .event = "PreToolUse", .command = "echo 2" },
    };
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{ .extra_hooks = &extra });
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("hooks").?.object.get("PreToolUse").?.array.items.len);
}

test "buildSettingsJson: merges extra top-level keys and ignores caller hooks key" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{
        .extra_settings_json = "{\"model\":\"sonnet\",\"hooks\":{\"Stop\":[]},\"n\":1234567890123456789012345}",
    });
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "1234567890123456789012345") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sonnet", parsed.value.object.get("model").?.string);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("hooks").?.object.get("Stop").?.array.items.len);
}

test "validateExtraSettings: rejects disableAllHooks true" {
    try testing.expectError(
        error.InvalidExtraSettings,
        validateExtraSettings(testing.allocator, .{ .extra_settings_json = "{\"disableAllHooks\":true}" }),
    );
}

test "validateExtraSettings: accepts disableAllHooks false and non-boolean values" {
    try validateExtraSettings(testing.allocator, .{ .extra_settings_json = "{\"disableAllHooks\":false}" });
    try validateExtraSettings(testing.allocator, .{ .extra_settings_json = "{\"disableAllHooks\":null}" });
    try validateExtraSettings(testing.allocator, .{ .extra_settings_json = "{\"disableAllHooks\":\"true\"}" });
}

test "validateExtraSettings: rejects non-object JSON" {
    for ([_][]const u8{ "[]", "\"str\"", "42", "true", "{" }) |bad| {
        try testing.expectError(
            error.InvalidExtraSettings,
            validateExtraSettings(testing.allocator, .{ .extra_settings_json = bad }),
        );
    }
}

test "validateExtraSettings: rejects empty event or command" {
    try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "", .command = "echo hi" }},
    }));
    try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "Stop", .command = "" }},
    }));
}

test "validateExtraSettings: rejects invalid UTF-8 in extra hooks" {
    try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "\xff", .command = "echo hi" }},
    }));
    try testing.expectError(error.InvalidExtraSettings, validateExtraSettings(testing.allocator, .{
        .extra_hooks = &.{.{ .event = "Stop", .command = "\xff" }},
    }));
}

test "validateExtraSettings: enforces max_extra_settings_depth boundary" {
    var ok_buf: std.ArrayList(u8) = .{};
    defer ok_buf.deinit(testing.allocator);
    try ok_buf.appendSlice(testing.allocator, "{\"a\":");
    for (0..max_extra_settings_depth - 1) |_| try ok_buf.append(testing.allocator, '[');
    for (0..max_extra_settings_depth - 1) |_| try ok_buf.append(testing.allocator, ']');
    try ok_buf.append(testing.allocator, '}');
    try validateExtraSettings(testing.allocator, .{ .extra_settings_json = ok_buf.items });

    var deep_buf: std.ArrayList(u8) = .{};
    defer deep_buf.deinit(testing.allocator);
    try deep_buf.appendSlice(testing.allocator, "{\"a\":");
    for (0..max_extra_settings_depth) |_| try deep_buf.append(testing.allocator, '[');
    for (0..max_extra_settings_depth) |_| try deep_buf.append(testing.allocator, ']');
    try deep_buf.append(testing.allocator, '}');
    try testing.expectError(
        error.InvalidExtraSettings,
        validateExtraSettings(testing.allocator, .{ .extra_settings_json = deep_buf.items }),
    );
}

test "jsonNestingDepth: ignores brackets inside JSON strings" {
    try testing.expectEqual(@as(usize, 1), jsonNestingDepth("{\"s\":\"[[[{{{]]}}}\"}"));
    try testing.expectEqual(@as(usize, 1), jsonNestingDepth("{\"s\":\"\\\"[[[\\\"\"}"));
}

test "jsonNestingDepth: measures scalar, object, and nested arrays" {
    try testing.expectEqual(@as(usize, 0), jsonNestingDepth("123"));
    try testing.expectEqual(@as(usize, 1), jsonNestingDepth("{}"));
    try testing.expectEqual(@as(usize, 3), jsonNestingDepth("{\"a\":[{}]}"));
}

test "shellSingleQuote: wraps empty and plain strings" {
    const q1 = try shellSingleQuote(testing.allocator, "");
    defer testing.allocator.free(q1);
    try testing.expectEqualStrings("''", q1);
    const q2 = try shellSingleQuote(testing.allocator, "abc");
    defer testing.allocator.free(q2);
    try testing.expectEqualStrings("'abc'", q2);
}

test "shellSingleQuote: escapes multiple apostrophes" {
    const q = try shellSingleQuote(testing.allocator, "a'b'c");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'a'\\''b'\\''c'", q);
}

test "needsShellQuoting: safe vs unsafe path characters" {
    try testing.expect(!needsShellQuoting("/tmp/claude-p_1.0/hook.sh"));
    try testing.expect(needsShellQuoting(""));
    try testing.expect(needsShellQuoting("/tmp/a b/hook.sh"));
    try testing.expect(needsShellQuoting("/tmp/a$b/hook.sh"));
}

test "formatRelayCommand: unquoted for safe paths, quoted for unsafe" {
    const c1 = try formatRelayCommand(testing.allocator, "/tmp/hook.sh", "Stop");
    defer testing.allocator.free(c1);
    try testing.expectEqualStrings("/tmp/hook.sh Stop", c1);
    const c2 = try formatRelayCommand(testing.allocator, "/tmp/my hook.sh", "Stop");
    defer testing.allocator.free(c2);
    try testing.expectEqualStrings("'/tmp/my hook.sh' Stop", c2);
}

test "buildSettingsJson: allocation failures leak nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            const extra = [_]ExtraHook{.{ .event = "PreToolUse", .command = "echo ok" }};
            const out = try buildSettingsJson(alloc, "/tmp/hook.sh", .{
                .extra_hooks = &extra,
                .extra_settings_json = "{\"env\":{\"A\":\"1\"}}",
            });
            alloc.free(out);
        }
    }.check, .{});
}

test "buildSettingsJson: preserves duplicate keys using last value" {
    const json = try buildSettingsJson(testing.allocator, "/tmp/hook.sh", .{
        .extra_settings_json = "{\"k\":1,\"k\":2}",
    });
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("k").?.integer);
}

test "validateExtraSettings: allows null extra_settings_json with empty hooks" {
    try validateExtraSettings(testing.allocator, .{});
}
