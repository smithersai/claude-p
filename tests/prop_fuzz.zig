//! Aggregator for property-based and fuzz tests across all `claude-p` modules.
//! Run deterministic properties + fuzz corpus replay:
//!   zig build test-prop
//! Run live coverage-guided fuzzing (Linux):
//!   zig build test-prop --fuzz
const std = @import("std");

test {
    _ = @import("prop/terminal_prop.zig");
    _ = @import("prop/driver_paste_env_prop.zig");
    _ = @import("prop/driver_dialog_watchdog_prop.zig");
    _ = @import("prop/hook_prop.zig");
    _ = @import("prop/transcript_stream_prop.zig");
    _ = @import("prop/args_prop.zig");
    _ = @import("prop/daemon_emit_prop.zig");
    std.testing.refAllDecls(@This());
}
