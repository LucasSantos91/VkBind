const std = @import("std");
const vk_bind = @import("VkBind");
const debug_commands: []const vk_bind.raw.Command = &.{ .destroyInstance, .destroyDevice, .destroyCommandPool };
const vk = vk_bind.VulkanContext(.{
    .commands = [_]vk_bind.raw.Command{
        .createInstance,
        .createDevice,
        .getPhysicalDeviceFeatures,
        .enumeratePhysicalDevices,
        .getPhysicalDeviceQueueFamilyProperties,
        .createCommandPool,
    } ++ debug_commands,
    .extensions = &.{},
});
const builtin = @import("builtin");
const is_safe = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

const Context = struct {
    fn panic(err: anyerror, motive: []const u8) noreturn {
        std.debug.panic(
            \\Panic in Vulkan.
            \\{s}
            \\Error code: {t},
        , .{ motive, err });
    }
    const Temp = struct {
        instance: vk.Instance,
        command_pool: vk.CommandPool,
    };

    temp: if (is_safe) Temp else void,
    device: vk.Device,

    pub fn init() @This() {
        var self: @This() = undefined;
        const instance_create_info: vk.InstanceCreateInfo = .{
            .enabledExtensionCount = vk.extensions.device.len,
            .ppEnabledExtensionNames = vk.extensions.device.ptr,
        };
        const instance = vk.globals.createInstance(&instance_create_info) catch |e| panic(e, "Failed to create instance");
        const inst_proc_addr = vk.getSpecializedGetInstanceProcAddr(instance).?;
        vk.initInstanceCommands(inst_proc_addr, instance);
        const phys_device, const family_index = selectPhysicalDeviceAndQueueFamily(instance);

        const queue_create_info: [1]vk.DeviceQueueCreateInfo = .{vk.DeviceQueueCreateInfo{
            .queueFamilyIndex = family_index,
            .queueCount = 1,
            .pQueuePriorities = &.{1.0},
        }};
        const features: vk.PhysicalDeviceFeatures = .{};
        const device_create_info: vk.DeviceCreateInfo = .{
            .enabledExtensionCount = vk.extensions.device.len,
            .ppEnabledExtensionNames = vk.extensions.device.ptr,
            .queueCreateInfoCount = queue_create_info.len,
            .pQueueCreateInfos = &queue_create_info,
            .pEnabledFeatures = &features,
        };
        self.device = phys_device.createDevice(&device_create_info) catch |e| panic(e, "Failed to create device");
        vk.initDeviceCommandsFromGetInstanceProcAddr(inst_proc_addr, instance, self.device);

        const command_pool = self.device.createCommandPool(&.{
            .queueFamilyIndex = family_index,
            .flags = .{ .RESET_COMMAND_BUFFER = true },
        }) catch |e| panic(e, "Failed to create command pool");

        if (comptime is_safe) {
            self.temp = .{
                .instance = instance,
                .command_pool = command_pool,
            };
        }
        return self;
    }
    pub fn deinit(self: *@This()) void {
        if (comptime is_safe) self.device.destroyCommandPool(self.temp.command_pool);
        self.device.destroyDevice();
        if (comptime is_safe) self.temp.instance.destroyInstance();

        self.* = undefined;
    }
    pub fn run(self: *@This()) !void {
        _ = self;
    }
    fn selectPhysicalDeviceAndQueueFamily(instance: vk.Instance) struct { vk.PhysicalDevice, u4 } {
        var physical_devices: [16]vk.PhysicalDevice = undefined;
        var count: u32 = physical_devices.len;
        _ = instance.enumeratePhysicalDevices(&count, &physical_devices) catch |e| panic(e, "Failed to enumerate physical devices");
        for (physical_devices[0..count]) |p| {
            var props: [16]vk.QueueFamilyProperties = undefined;
            var len: u32 = props.len;
            p.getPhysicalDeviceQueueFamilyProperties(&len, &props);
            for (props[0..len], 0..) |prop, index| {
                if (prop.queueFlags.GRAPHICS) {
                    return .{ p, @intCast(index) };
                }
            }
        } else {
            @panic("Failed to find adequate physical device");
        }
    }
};

pub fn main() void {
    var context: Context = .init();
    defer context.deinit();
    try context.run();
}
