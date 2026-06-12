Vulkan bindings generator, inspired by [vulkan-zig](https://github.com/Snektron/vulkan-zig).

To use it in your project, add it to your dependencies and pass the paths to `vk.xml` and `video.xml`,
which can be obtained from [Vulkan-Docs](https://github.com/khronosGroup/Vulkan-Docs).

Standard code is:

```zig
// build.zig
pub fn build(b: *std.Build) void {
    const vk_docs = b.dependency("VkDocs", .{});
    const vk_bind = b.dependency("VkBind", .{
        .registry = vk_docs.path("xml/vk.xml"),
        .video = vk_docs.path("xml/video.xml"),
    });
    const module = vk_bind.module("VkBind");
```

If you're on Windows, there's no need to link with an import library, as the module takes care of it.

