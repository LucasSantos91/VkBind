const std = @import("std");
const vk_bind = @import("VkBind");
const vk = vk_bind.VulkanContext(.{
    .commands = &.{.createInstance},
    .extensions = &.{},
});

const Context = struct {
    instance: vk.Instance,

    pub fn init() !@This() {
        var self: @This() = undefined;
        const info: vk.InstanceCreateInfo = .{
            .enabledExtensionCount = vk.extensions.device.len,
            .ppEnabledExtensionNames = vk.extensions.device.ptr,
            .ppEnabledLayerNames = undefined,
        };
        self.instance = try vk.createInstance(&info);
        return self;
    }
};

pub fn main() !void {
    const context: Context = try Context.init();
    _ = context;
}
