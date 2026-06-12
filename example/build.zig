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
    const compile_shaders = b.addSystemCommand(&.{
        "slangc",     "-target", "spirv", "-profile", "glsl_330",
        "-Wno-50011",
        switch (optimize) {
            .Debug, .ReleaseSafe => "-O0",
            .ReleaseSmall => "-O2",
            .ReleaseFast => "-O3",
        },

        switch (optimize) {
            .Debug, .ReleaseSafe => "-g3",
            .ReleaseSmall, .ReleaseFast => "-g0",
        },
        "-fp-mode",   "fast",    "-o",
    });

    const shaders = compile_shaders.addOutputFileArg("shaders.spv");
    switch (optimize) {
        .Debug, .ReleaseSafe => {},
        .ReleaseSmall, .ReleaseFast => compile_shaders.addArg("-obfuscate"),
    }

    compile_shaders.addFileArg(b.path("src/shaders.slang"));
    const shaders_module = b.createModule(.{
        .root_source_file = shaders,
    });
    const vk_bind_module = vk_bind.module("VkBind");
    const install_vk_bind = b.addInstallFile(vk_bind_module.root_source_file.?, "VkBind.zig");
    b.getInstallStep().dependOn(&install_vk_bind.step);

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "VkBind", .module = vk_bind_module },
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
