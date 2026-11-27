//! Public Zig library API for `claude-p`.
//!
//! Re-read SPEC.md for the architectural overview. The high-level API is
//! `run(allocator, opts)` which spawns `claude` under a zmux-managed
//! PTY, feeds it the prompt, waits for the Stop hook, and returns a Result
//! containing the assistant's final message plus telemetry.
const std = @import("std");

/// CLI argument parser and option definitions.
pub const args = @import("args.zig");
/// JSONL transcript parser and usage summary types.
pub const transcript = @import("transcript.zig");
/// Stdout result formatters for text, json, and stream-json modes.
pub const emit = @import("emit.zig");
/// Ephemeral hook harness generator and event parser.
pub const hook = @import("hook.zig");
/// Streaming DEC and XTerm terminal query responder.
pub const terminal = @import("terminal.zig");
/// Single-shot PTY session driver for interactive Claude Code.
pub const driver = @import("driver.zig");
/// Incremental JSONL transcript tailer for live streaming output.
pub const stream = @import("stream.zig");
/// Persistent multi-turn JSON-line daemon over a warm PTY session.
pub const daemon = @import("daemon.zig");
/// Bounded non-blocking stdin reader, prompt composition, and timeout helpers.
pub const stdin = @import("stdin.zig");

/// Error set returned by single-shot PTY session execution.
pub const RunError = driver.RunError;
/// Configuration options for a single-shot PTY session run.
pub const Options = driver.Options;
/// Final assistant output and telemetry returned by `run`.
pub const Result = driver.Result;
/// Aggregated token usage counters from a parsed transcript.
pub const Usage = transcript.Usage;
/// Supported stdout formatting modes (`text`, `json`, `stream_json`).
pub const OutputFormat = args.OutputFormat;

/// Semantic version kept in lockstep with `package.json` and `build.zig.zon`.
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 3 };

/// Spawn `claude` under a PTY, submit `opts.prompt`, and return its parsed result.
pub fn run(allocator: std.mem.Allocator, opts: Options) RunError!Result {
    std.debug.assert(version.minor <= 99 and opts.timeout_ms <= std.math.maxInt(u64));
    return driver.run(allocator, opts);
}

test {
    // Pull in tests from every submodule.
    std.testing.refAllDecls(@This());
}
