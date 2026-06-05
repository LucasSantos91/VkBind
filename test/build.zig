const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vk_docs = b.dependency("VkDocs", .{});
    const vk_bind = b.dependency("VkBind", .{
        .registry = vk_docs.path("xml/vk.xml"),
        .video = vk_docs.path("xml/video.xml"),
    });
    const glfw_zig = b.dependency("glfw-zig", .{
        .target = target,
        .optimize = optimize,
    });
    const compile_shaders = b.addSystemCommand(&.{ "slangc", "-target", "spirv", "-profile", "glsl_330", "-o" });
    const shaders = compile_shaders.addOutputFileArg("shaders.spirv");
    compile_shaders.addFileArg(b.path("src/shaders.slang"));
    const shaders_module = b.createModule(.{
        .root_source_file = shaders,
    });

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "VkBind", .module = vk_bind.module("VkBind") },
                .{ .name = "glfw-zig", .module = glfw_zig.module("glfw-zig") },
                .{ .name = "shaders", .module = shaders_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "runs the program");
    run_step.dependOn(&run.step);
    run_step.dependOn(b.getInstallStep());
}
