const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match this filter");
    const test_filters: []const []const u8 = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};

    const zmux_dep = b.dependency("zmux", .{
        .target = target,
        .optimize = optimize,
    });
    const zmux_mod = zmux_dep.module("zmux");

    const claude_p = b.addModule("claude_p", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    claude_p.addImport("zmux", zmux_mod);
    // zmux's PTY code needs these; attach them to the exported module so
    // external Zig consumers link them without rediscovering the list.
    if (target.result.os.tag == .linux) claude_p.linkSystemLibrary("util", .{});
    if (target.result.os.tag == .macos) claude_p.linkSystemLibrary("proc", .{});

    const exe = b.addExecutable(.{
        .name = "claude-p",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "claude_p", .module = claude_p },
                .{ .name = "zmux", .module = zmux_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // ------------------------------------------------------------------
    // run
    // ------------------------------------------------------------------
    const run_step = b.step("run", "Run claude-p");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = claude_p, .filters = test_filters });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ------------------------------------------------------------------
    // Property-based & fuzz tests (corpus replay in `zig build test-prop`,
    // coverage-guided fuzzing via `zig build test-prop --fuzz`).
    // ------------------------------------------------------------------
    const prop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/prop_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "claude_p", .module = claude_p },
                .{ .name = "zmux", .module = zmux_mod },
            },
        }),
        .filters = test_filters,
        // Zig 0.15.2 SanCov PC-guard instrumentation (`--fuzz`) requires the
        // LLVM backend; x86_64-linux Debug defaults to self-hosted without it.
        .use_llvm = true,
    });
    const run_prop_tests = b.addRunArtifact(prop_tests);
    const prop_step = b.step("test-prop", "Run property-based and fuzz tests (pass --fuzz for live coverage-guided fuzzing)");
    prop_step.dependOn(&run_prop_tests.step);
    test_step.dependOn(&run_prop_tests.step);

    // ------------------------------------------------------------------
    // Real-claude integration tests (no mocks). Gated on CLAUDE_P_E2E=1.
    // ------------------------------------------------------------------
    const integ_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "claude_p", .module = claude_p },
            },
        }),
        .filters = test_filters,
    });
    const run_integ_tests = b.addRunArtifact(integ_tests);
    run_integ_tests.has_side_effects = true;
    // The nested-env and daemon tests spawn the installed CLI binary.
    run_integ_tests.step.dependOn(b.getInstallStep());
    run_integ_tests.setEnvironmentVariable("CLAUDE_P_BIN", b.getInstallPath(.bin, exe.out_filename));
    const integ_step = b.step("test-integration", "Run integration tests against the real `claude` binary (set CLAUDE_P_E2E=1)");
    integ_step.dependOn(&run_integ_tests.step);
}
