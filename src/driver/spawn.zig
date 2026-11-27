//! Executable PATH resolution, cwd validation, shell quoting, and child env filtering.
const std = @import("std");

/// Error set returned when locating the `claude` binary fails.
pub const ResolveError = error{
    ClaudeNotFound,
    OutOfMemory,
};

/// Check that `cwd`, when set, names an accessible directory.
pub fn validateCwd(cwd: ?[]const u8) error{ InvalidCwd, OutOfMemory }!void {
    const dir = cwd orelse return;
    const resolved = try resolveCwd(std.heap.page_allocator, dir);
    std.heap.page_allocator.free(resolved);
}

/// Resolve `dir` to an absolute canonical directory path with search permission.
pub fn resolveCwd(allocator: std.mem.Allocator, dir: []const u8) error{ InvalidCwd, OutOfMemory }![]u8 {
    if (dir.len == 0 or std.mem.indexOfScalar(u8, dir, 0) != null) return error.InvalidCwd;
    const resolved = std.fs.cwd().realpathAlloc(allocator, dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCwd,
    };
    errdefer allocator.free(resolved);
    const st = std.fs.cwd().statFile(resolved) catch return error.InvalidCwd;
    if (st.kind != .directory) return error.InvalidCwd;
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

const persistence_env = "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE";

/// Return true ONLY for nested-session markers that must not leak into child `claude`.
pub fn shouldStripChildEnv(name: []const u8) bool {
    const exact = [_][]const u8{
        "CLAUDECODE",                "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT",    "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
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

test "shellQuoteArgv: escapes single quotes and preserves JSON" {
    const out = try shellQuoteArgv(testing.allocator, &.{ "claude", "it's", "{\"a\":1}" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("'claude' 'it'\\''s' '{\"a\":1}'", out);
}

test "shellQuoteArgv: empty slice yields empty string" {
    const out = try shellQuoteArgv(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
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

test "validateCwd: accepts null and real directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    try validateCwd(null);
    try validateCwd(dir);
}

test "validateCwd: rejects file, empty, NUL, and missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "x" });
    const file = try tmp.dir.realpathAlloc(testing.allocator, "f");
    defer testing.allocator.free(file);
    try testing.expectError(error.InvalidCwd, validateCwd(file));
    try testing.expectError(error.InvalidCwd, validateCwd(""));
    try testing.expectError(error.InvalidCwd, validateCwd("/tmp/bad\x00path"));
    try testing.expectError(error.InvalidCwd, validateCwd("/nonexistent/dir"));
}

test "resolveCwd: returns canonical absolute path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = try resolveCwd(testing.allocator, ".");
    defer testing.allocator.free(got);
    try testing.expect(std.fs.path.isAbsolute(got));
}

test "resolveClaudeBinaryIn: locates executable on PATH" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile("claude", .{ .mode = 0o700 })).close();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const found = try resolveClaudeBinaryIn(testing.allocator, null, dir);
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "/claude"));
}

test "resolveClaudeBinaryIn: rejects non-executable and empty override" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile("noexec", .{ .mode = 0o600 })).close();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const bad = try std.fs.path.join(testing.allocator, &.{ dir, "noexec" });
    defer testing.allocator.free(bad);
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, bad, dir));
    try testing.expectError(ResolveError.ClaudeNotFound, resolveClaudeBinaryIn(testing.allocator, "", dir));
}

test "resolveClaudeBinaryIn: explicit absolute executable bypasses PATH" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile("custom", .{ .mode = 0o700 })).close();
    const exe = try tmp.dir.realpathAlloc(testing.allocator, "custom");
    defer testing.allocator.free(exe);
    const got = try resolveClaudeBinaryIn(testing.allocator, exe, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(exe, got);
}

test "shouldStripChildEnv: strips exact nested markers" {
    try testing.expect(shouldStripChildEnv("CLAUDECODE"));
    try testing.expect(shouldStripChildEnv("AI_AGENT"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_ENTRYPOINT"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_SSE_PORT"));
}

test "shouldStripChildEnv: strips session, parent, and subagent prefixes" {
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_SESSION_FOO"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_PARENT_PID"));
    try testing.expect(shouldStripChildEnv("CLAUDE_CODE_SUBAGENT_ID"));
}

test "shouldStripChildEnv: preserves auth, config, and backend vars" {
    try testing.expect(!shouldStripChildEnv("CLAUDE_CODE_OAUTH_TOKEN"));
    try testing.expect(!shouldStripChildEnv("CLAUDE_CONFIG_DIR"));
    try testing.expect(!shouldStripChildEnv("CLAUDE_CODE_USE_BEDROCK"));
    try testing.expect(!shouldStripChildEnv("PATH"));
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
    var hits: u32 = 0;
    for (list.items) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry, "CLAUDECODE="));
        try testing.expect(!std.mem.startsWith(u8, entry, "CLAUDE_P_FIFO="));
        if (std.mem.eql(u8, entry, "TERM=xterm-256color")) hits += 1;
        if (std.mem.eql(u8, entry, "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1")) hits += 1;
        if (std.mem.eql(u8, entry, "CLAUDE_CODE_OAUTH_TOKEN=tok")) hits += 1;
    }
    try testing.expectEqual(@as(u32, 3), hits);
}

test "buildChildEnvFromMap: preserves caller persistence without duplicating" {
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

test "buildChildEnvFromMap: empty map still injects TERM and persistence" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    var list = try buildChildEnvFromMap(testing.allocator, &env, "");
    defer freeChildEnv(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
}

test "buildChildEnvFromMap: allocation failures leak nothing" {
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp");
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, m: *const std.process.EnvMap) !void {
            var list = try buildChildEnvFromMap(alloc, m, "/tmp/f");
            freeChildEnv(alloc, &list);
        }
    }.run, .{&env});
}

test "buildChildEnv: succeeds against process environment" {
    var list = try buildChildEnv(testing.allocator, "");
    defer freeChildEnv(testing.allocator, &list);
    try testing.expect(list.items.len >= 2);
}

test "isExecutableFile: rejects paths with embedded NUL" {
    try testing.expect(!isExecutableFile("/bin/sh\x00"));
}

test "resolveClaudeBinary: resolves /bin/sh override" {
    const sh = try resolveClaudeBinary(testing.allocator, "/bin/sh");
    defer testing.allocator.free(sh);
    try testing.expect(std.fs.path.isAbsolute(sh));
}
