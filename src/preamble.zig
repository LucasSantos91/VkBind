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

pub fn FlagsMixin(comptime Flags: type, comptime FlagBits: type) type {
    return struct {
        const BaseType = @typeInfo(Flags).@"struct".backing_integer.?;

        pub fn merge(lhs: Flags, rhs: Flags) Flags {
            const l: BaseType = @bitCast(lhs);
            const r: BaseType = @bitCast(rhs);
            return l | r;
        }
        pub fn intersection(lhs: Flags, rhs: Flags) Flags {
            const l: BaseType = @bitCast(lhs);
            const r: BaseType = @bitCast(rhs);
            return l & r;
        }
        pub fn negation(self: Flags) Flags {
            const s: BaseType = @bitCast(self);
            return @bitCast(~s);
        }
        pub fn difference(lhs: Flags, rhs: Flags) Flags {
            const n = negation(rhs);
            return intersection(lhs, n);
        }
        pub fn toBit(self: Flags) FlagBits {
            const s: BaseType = @bitCast(self);
            return @enumFromInt(s);
        }
        pub fn fromBit(bit: FlagBits) Flags {
            return @bitCast(@intFromEnum(bit));
        }
        pub fn set(self: Flags, bit: FlagBits) Flags {
            return merge(self, fromBit(bit));
        }
        pub fn unset(self: Flags, bit: FlagBits) Flags {
            return difference(self, fromBit(bit));
        }
    };
}
pub fn FlagBitsMixin(comptime Flags: type, comptime FlagBits: type) type {
    return struct {
        const BaseType = @typeInfo(Flags).@"struct".backing_integer.?;
        pub fn toFlags(self: FlagBits) Flags {
            return @bitCast(@intFromEnum(self));
        }
        pub fn fromFlags(self: Flags) FlagBits {
            const b: BaseType = @bitCast(self);
            return @enumFromInt(b);
        }
    };
}
