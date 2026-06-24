//! Public Zig library API for `claude-p`.
//!
//! Re-read SPEC.md for the architectural overview. The high-level API is
//! `run(allocator, opts)` which spawns `claude` under a libghostty-managed
//! PTY, feeds it the prompt, waits for the Stop hook, and returns a Result
//! containing the assistant's final message plus telemetry.
const std = @import("std");

pub const args = @import("args.zig");
pub const transcript = @import("transcript.zig");
pub const emit = @import("emit.zig");
pub const hook = @import("hook.zig");
pub const terminal = @import("terminal.zig");
pub const driver = @import("driver.zig");
pub const stream = @import("stream.zig");
pub const daemon = @import("daemon.zig");

pub const Options = driver.Options;
pub const Result = driver.Result;
pub const Usage = transcript.Usage;
pub const OutputFormat = args.OutputFormat;

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 2 };

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result {
    return driver.run(allocator, opts);
}

test {
    // Pull in tests from every submodule.
    std.testing.refAllDecls(@This());
}
