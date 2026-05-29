const std = @import("std");
const vk_bind = @import("VkBind");
const vk = vk_bind.VulkanContext(.{});

pub fn main() void {
    std.debug.print("Hi", .{});
}
