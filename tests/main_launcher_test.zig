//! Process-group SIGINT launcher test running the compiled `claude-p` binary via `bin/claude-p.js`.
const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

fn countHarnessDirs(dir: std.fs.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "claude-p-")) n += 1;
    }
    return n;
}

const GroupKiller = struct {
    pgid: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        for (0..300) |_| {
            if (self.done.load(.seq_cst)) return;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        std.posix.kill(-self.pgid, std.posix.SIG.KILL) catch {};
    }
};

test "launcher: SIGINT to the process group unwinds claude-p, exits 130, and leaves no temp dir" {
    const platform = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return error.SkipZigTest,
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return error.SkipZigTest,
    };
    const bin_path = std.posix.getenv("CLAUDE_P_BIN") orelse return error.SkipZigTest;
    const a = testing.allocator;

    const launcher = std.fs.cwd().readFileAlloc(a, "bin/claude-p.js", 1 << 20) catch return error.SkipZigTest;
    defer a.free(launcher);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var prebuilt_buf: [64]u8 = undefined;
    const prebuilt = try std.fmt.bufPrint(&prebuilt_buf, "pkg/prebuilt/{s}-{s}", .{ platform, arch });
    try tmp.dir.makePath("pkg/bin");
    try tmp.dir.makePath(prebuilt);
    try tmp.dir.makePath("fakebin");
    try tmp.dir.makePath("tmpdir");
    try tmp.dir.writeFile(.{ .sub_path = "pkg/bin/claude-p.js", .data = launcher });
    {
        var d = try tmp.dir.openDir(prebuilt, .{});
        defer d.close();
        try d.symLink(bin_path, "claude-p", .{});
    }
    {
        const f = try tmp.dir.createFile("fakebin/claude", .{ .mode = 0o700 });
        defer f.close();
        var script_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(
            &script_buf,
            "#!/bin/sh\necho $$ > '{s}/claude.pid'\nprintf 'Booting\\r\\n'\nsleep 60\n",
            .{root},
        ));
    }

    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    const tmpdir_path = try std.fs.path.join(a, &.{ root, "tmpdir" });
    defer a.free(tmpdir_path);
    const path_value = try std.fmt.allocPrint(a, "{s}/fakebin:{s}", .{ root, env.get("PATH") orelse "/usr/bin:/bin" });
    defer a.free(path_value);
    try env.put("TMPDIR", tmpdir_path);
    try env.put("PATH", path_value);
    env.remove("ZIG_PROGRESS");

    const launcher_path = try std.fs.path.join(a, &.{ root, "pkg", "bin", "claude-p.js" });
    defer a.free(launcher_path);
    var child = std.process.Child.init(&.{ "node", launcher_path }, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.env_map = &env;
    child.cwd = root;
    child.pgid = 0;
    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    var killer: GroupKiller = .{ .pgid = child.id };
    const killer_thread = try std.Thread.spawn(.{}, GroupKiller.run, .{&killer});
    var reaped = false;
    defer {
        if (!reaped) {
            std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
        }
        killer.done.store(true, .seq_cst);
        killer_thread.join();
    }

    try child.stdin.?.writeAll("hello\n");
    child.stdin.?.close();
    child.stdin = null;

    var tmpdir = try tmp.dir.openDir("tmpdir", .{ .iterate = true });
    defer tmpdir.close();

    var running = false;
    for (0..600) |_| {
        const pid_ready = if (tmp.dir.statFile("claude.pid")) |st| st.size > 1 else |_| false;
        if (pid_ready and try countHarnessDirs(tmpdir) == 1) {
            running = true;
            break;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    try testing.expect(running);
    std.Thread.sleep(150 * std.time.ns_per_ms);

    try std.posix.kill(-child.id, std.posix.SIG.INT);

    const err_text = try child.stderr.?.readToEndAlloc(a, 1 << 20);
    defer a.free(err_text);
    const term = try child.wait();
    reaped = true;
    errdefer std.debug.print("launcher test: term={any}; stderr:\n{s}\n", .{ term, err_text });

    try testing.expectEqual(std.process.Child.Term{ .Exited = 130 }, term);
    try testing.expectEqual(@as(usize, 0), try countHarnessDirs(tmpdir));

    const pid_text = try tmp.dir.readFileAlloc(a, "claude.pid", 32);
    defer a.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n"), 10);
    var gone = false;
    for (0..150) |_| {
        std.posix.kill(pid, 0) catch {
            gone = true;
            break;
        };
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try testing.expect(gone);
}
