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
    pub fn deinit(self: *@This()) void {
        self.instance.destroyInstance();
    }
    pub fn run(self: *@This()) !void {
        _ = self;
        const v = try vk.enumerateInstanceVersion();
        _ = v;
    }
};

pub fn main() !void {
    var context: Context = try Context.init();
    try context.run();
}
