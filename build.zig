const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const registry = b.option(std.Build.LazyPath, "registry", "Path to vk.xml");
    const video = b.option(std.Build.LazyPath, "video", "Path to video.xml");
    const implib = b.option(bool, "implib", "(default true)(Windows only) Whether to link the VkBind module with a generated import library") orelse
        (target.result.os.tag == .windows);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "VkBind",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "runs the program");
    run_step.dependOn(&run.step);

    if (registry) |reg| {
        run.addArg("-registry");
        run.addFileArg(reg);
        if (video) |vid| {
            run.addArg("-registry");
            run.addFileArg(vid);
        }
        const output_file = run.captureStdOut(.{ .basename = "VkBind.zig" });
        const module = b.addModule("VkBind", .{
            .root_source_file = output_file,
        });
        if (implib) {
            run.addArg("-dll");
            const generated_dll = run.addOutputFileArg("dll.zig");
            const dummy_lib = b.addLibrary(.{
                .name = "vulkan-1",
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = generated_dll,
                    .target = target,
                }),
            });
            b.installArtifact(dummy_lib);
            const generated_implib = dummy_lib.getEmittedImplib();
            module.addLibraryPath(generated_implib.dirname());
            // Manual linkSystemLibrary because it has a useless restriction
            module.link_objects.append(b.allocator, .{
                .system_lib = .{
                    .name = "vulkan-1",
                    .needed = true,
                    .weak = true,
                    .preferred_link_mode = .dynamic,
                    .use_pkg_config = .yes,
                    .search_strategy = .paths_first,
                },
            }) catch @panic("OOM");
        }
    }
}
