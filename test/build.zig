const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vk_docs = b.dependency("VkDocs", .{});
    const vk_bind = b.dependency("VkBind", .{
        .registry = vk_docs.path("xml/vk.xml"),
        .video = vk_docs.path("xml/video.xml"),
    });
    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{.{ .name = "VkBind", .module = vk_bind.module("VkBind") }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "runs the program");
    run_step.dependOn(&run.step);
    run_step.dependOn(b.getInstallStep());
}
