const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const slice_tools_dep = b.dependency("slice_tools", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "slice_tools", .module = slice_tools_dep.module("slice_tools") },
        },
    });
    const exe = b.addExecutable(.{
        .name = "vkbind",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_tests.step);
}
