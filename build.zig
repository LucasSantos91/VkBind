const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const registry = b.option(std.Build.LazyPath, "registry", "Path to vk.xml");
    const video = b.option(std.Build.LazyPath, "video", "Path to video.xml");
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
        .name = "VkBind",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| for (args) |a| run.addArg(a);
    const run_step = b.step("run", "runs the program");
    run_step.dependOn(&run.step);

    if (registry) |reg| {
        run.addArg("-registry");
        run.addFileArg(reg);
        if (video) |vid| {
            run.addArg("-registry");
            run.addFileArg(vid);
        }
        const output_file = run.captureStdOut(.{});
        const module = b.addModule("VkBind", .{
            .root_source_file = output_file,
        });
        _ = module;
    }
}
