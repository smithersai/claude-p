//! Property & fuzz tests for `driver/session.zig` (`SessionRunner` hook/summary transitions).
const std = @import("std");
const claude_p = @import("claude_p");

const driver = claude_p.driver;
const hook = claude_p.hook;
const session_mod = driver.session;
const testing = std.testing;

fn fuzzSessionHandleEvent(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    var shared: driver.SharedState = .{ .session = undefined, .debug = false };
    var runner = session_mod.SessionRunner.init(.{
        .allocator = testing.allocator,
        .opts = .{ .prompt = "hello world" },
        .shared = &shared,
    });
    defer runner.deinit();
    runner.state = .awaiting_stop;
    runner.prompt_injections = 1;

    const ev_kind: hook.HookEvent = switch (input[0] % 4) {
        0 => .user_prompt_submit,
        1 => .stop,
        2 => .stop_failure,
        else => .unknown,
    };
    const payload = input[1..];
    runner.handleHookEvent(.{ .event = ev_kind, .payload = payload }) catch |err| switch (err) {
        error.PromptTruncated, error.PermissionPromptBlocked => {},
        else => return err,
    };
}

test "fuzz: SessionRunner.handleHookEvent never crashes or leaks on arbitrary payloads" {
    try std.testing.fuzz({}, fuzzSessionHandleEvent, .{
        .corpus = &.{
            "\x00{\"prompt\":\"hello world\"}",
            "\x01{\"last_assistant_message\":\"done\"}",
            "\x02{\"error\":\"overloaded\"}",
            "\x03{}",
            "\x01not-json",
        },
    });
}
