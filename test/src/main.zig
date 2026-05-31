const std = @import("std");
const vk_bind = @import("VkBind");
const debug_commands: []const vk_bind.raw.Command = &.{ .destroyInstance, .destroyDevice };
const vk = vk_bind.VulkanContext(.{
    .commands = [_]vk_bind.raw.Command{
        .createInstance,
        .getInstanceProcAddr,
        .createDevice,
        .getPhysicalDeviceFeatures,
        .enumeratePhysicalDevices,
        .getPhysicalDeviceQueueFamilyProperties,
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

        pub fn deinit(self: *@This()) void {
            self.instance.destroyInstance();
            self.* = undefined;
        }
    };

    temp: if (is_safe) Temp else void,
    device: vk.Device,

    pub fn init() @This() {
        var self: @This() = undefined;
        const instance_create_info: vk.InstanceCreateInfo = .{
            .enabledExtensionCount = vk.extensions.device.len,
            .ppEnabledExtensionNames = vk.extensions.device.ptr,
            .ppEnabledLayerNames = undefined,
        };
        const instance = vk.createInstance(&instance_create_info) catch |e| panic(e, "Failed to create instance");
        {
            const get_inst_proc_raw = vk_bind.raw.extern_commands.getInstanceProcAddr(@enumFromInt(@intFromEnum(instance)), vk.Command.getInstanceProcAddr.getVkName()) orelse @panic("Failed to find getInstanceProcAddress");
            const get_inst_proc: vk.Command.getInstanceProcAddr.getPtrType() = @ptrCast(get_inst_proc_raw);
            vk.initInstanceCommands(get_inst_proc.?, instance);
        }
        const phys_device, const family_index = selectPhysicalDevice(instance);

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

        {
            const com: vk.Command = .getDeviceProcAddr;
            const name = com.getVkName();
            const first: com.getPtrType() = @ptrCast(instance.getInstanceProcAddr(name));
            const load: com.getPtrType() = @ptrCast(first.?(@enumFromInt(@intFromEnum(self.device)), name));
            vk.initDeviceCommands(load.?, self.device);
        }

        if (comptime is_safe) {
            self.temp = .{
                .instance = instance,
            };
        }
        return self;
    }
    pub fn deinit(self: *@This()) void {
        self.device.destroyDevice();
        if (comptime is_safe) {
            self.temp.deinit();
        }
        self.* = undefined;
    }
    pub fn run(self: *@This()) !void {
        _ = self;
    }
    fn selectPhysicalDevice(instance: vk.Instance) struct { vk.PhysicalDevice, u4 } {
        var physical_devices: [16]vk.PhysicalDevice = undefined;
        var count: u32 = physical_devices.len;
        _ = instance.enumeratePhysicalDevices(&count, &physical_devices) catch @panic("Failed to enumerate physical devices");
        for (physical_devices[0..count]) |p| {
            var props: [16]vk.QueueFamilyProperties = undefined;
            var len: u32 = props.len;
            p.getPhysicalDeviceQueueFamilyProperties(&len, &props);
            for (props[0..len], 0..) |prop, index| {
                if (prop.queueFlags.GRAPHICS_BIT) {
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
    try context.run();
    context.deinit();
}
