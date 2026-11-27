//! Aggregator for shell-fixture and extended CLI regression tests (runs under `zig build test`).
const std = @import("std");

test {
    _ = @import("daemon_fixtures.zig");
    _ = @import("driver_fixtures.zig");
    _ = @import("args_cli_tests.zig");
    _ = @import("main_launcher_test.zig");
    _ = @import("module_fixtures.zig");
    std.testing.refAllDecls(@This());
}
