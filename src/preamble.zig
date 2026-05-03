const std = @import("std");
const builtin = @import("builtin");
pub const vulkan_api: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86)
    .winapi
else if (builtin.abi == .android and (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()) and std.Target.arm.featureSetHas(builtin.cpu.features, .has_v7) and builtin.cpu.arch.ptrBitWidth() == 32)
    .arm_aapcs_vfp
else
    .c;

pub const Bool32 = enum(u32) {
    false,
    true,
};
pub const VkRemoteAddressNV = *anyopaque;
