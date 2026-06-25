const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    if (target.result.os.tag == .linux) exe.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) exe.linkSystemLibrary("proc");

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
    // spike-interrupt — Phase 0 throwaway experiment (interrupt-frame spec).
    // `zig build spike-interrupt -- esc|double-esc|ctrl-c`
    // ------------------------------------------------------------------
    const spike = b.addExecutable(.{
        .name = "spike-interrupt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_interrupt.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "claude_p", .module = claude_p },
                .{ .name = "zmux", .module = zmux_mod },
            },
        }),
    });
    if (target.result.os.tag == .linux) spike.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) spike.linkSystemLibrary("proc");
    const spike_run = b.addRunArtifact(spike);
    if (b.args) |args| spike_run.addArgs(args);
    const spike_step = b.step("spike-interrupt", "Run the interrupt-frame Phase 0 spike (esc|double-esc|ctrl-c)");
    spike_step.dependOn(&spike_run.step);

    // ------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = claude_p });
    if (target.result.os.tag == .linux) mod_tests.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) mod_tests.linkSystemLibrary("proc");
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    if (target.result.os.tag == .linux) exe_tests.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) exe_tests.linkSystemLibrary("proc");
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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
    });
    if (target.result.os.tag == .linux) integ_tests.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) integ_tests.linkSystemLibrary("proc");
    const run_integ_tests = b.addRunArtifact(integ_tests);
    run_integ_tests.has_side_effects = true;
    // Daemon-mode integration tests spawn the built `claude-p` binary as a
    // subprocess (it reads/writes the real stdin/stdout). Hand it the path and
    // make sure the binary is built first.
    run_integ_tests.setEnvironmentVariable("CLAUDE_P_BIN", b.getInstallPath(.bin, "claude-p"));
    run_integ_tests.step.dependOn(b.getInstallStep());
    const integ_step = b.step("test-integration", "Run integration tests against the real `claude` binary (set CLAUDE_P_E2E=1)");
    integ_step.dependOn(&run_integ_tests.step);
}
