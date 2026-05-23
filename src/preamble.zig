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
pub const ApiVersion = packed struct(u32) {
    patch: u11 = 0,
    minor: u10,
    major: u7 = 1,
    variant: u3 = 0,

    pub fn toInt(self: @This()) u32 {
        return @bitCast(self);
    }
    pub fn fromInt(i: u32) @This() {
        return @bitCast(i);
    }
    pub fn gt(lhs: @This(), rhs: @This()) bool {
        return lhs.toInt() > rhs.toInt();
    }
    pub fn ge(lhs: @This(), rhs: @This()) bool {
        return lhs.toInt() >= rhs.toInt();
    }
    pub fn eq(lhs: @This(), rhs: @This()) bool {
        return lhs.toInt() == rhs.toInt();
    }
    pub fn lt(lhs: @This(), rhs: @This()) bool {
        return lhs.toInt() < rhs.toInt();
    }
    pub fn le(lhs: @This(), rhs: @This()) bool {
        return lhs.toInt() <= rhs.toInt();
    }
    pub fn order(lhs: @This(), rhs: @This()) std.math.Order {
        return std.math.order(lhs.toInt(), rhs.toInt());
    }
};
pub const DeviceSize = u64;
pub const DeviceAddress = u64;
pub const SampleMask = u32;

pub const VkRemoteAddressNV = *anyopaque;
pub const Display = opaque {};
pub const VisualID = c_uint;
pub const Window = c_ulong;
pub const RROutput = c_ulong;
pub const wl_display = opaque {};
pub const wl_surface = opaque {};
pub const HINSTANCE = std.os.windows.HINSTANCE;
pub const HWND = std.os.windows.HWND;
pub const HMONITOR = *opaque {};
pub const HANDLE = std.os.windows.HANDLE;
pub const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
pub const DWORD = std.os.windows.DWORD;
pub const LPCWSTR = std.os.windows.LPCWSTR;
pub const xcb_connection_t = opaque {};
pub const xcb_visualid_t = u32;
pub const xcb_window_t = u32;
pub const zx_handle_t = u32;
pub const _screen_context = opaque {};
pub const _screen_window = opaque {};
pub const _screen_buffer = opaque {};
pub const IDirectFB = opaque {};
pub const IDirectFBSurface = opaque {};
pub const NvSciSyncAttrList = *opaque {};
pub const NvSciSyncObj = *opaque {};
pub const NvSciSyncFence = *opaque {};
pub const NvSciBufAttrList = *opaque {};
pub const NvSciBufObj = *opaque {};
pub const GgpStreamDescriptor = *opaque {};
pub const GgpFrameToken = *opaque {};
pub const StdVideoVP9Profile = u32;
pub const StdVideoVP9Level = u32;
pub const ANativeWindow = opaque {};
pub const AHardwareBuffer = opaque {};
pub const CAMetalLayer = opaque {};
pub const MTLDevice_id = opaque {};
pub const MTLCommandQueue_id = opaque {};
pub const MTLBuffer_id = opaque {};
pub const MTLTexture_id = opaque {};
pub const MTLSharedEvent_id = opaque {};
pub const IOSurfaceRef = opaque {};
pub const OHNativeWindow = opaque {};
pub const OHBufferHandle = opaque {};
pub const OH_NativeBuffer = opaque {};
pub const ubm_device = opaque {};
pub const ubm_surface = opaque {};

pub fn FlagsMixin(comptime Flags: type, comptime FlagBits: type) type {
    return struct {
        const BackingInt = @typeInfo(Flags).@"struct".backing_integer.?;
        pub fn toInt(self: Flags) BackingInt {
            return @bitCast(self);
        }
        pub fn fromInt(int: BackingInt) Flags {
            return @bitCast(int);
        }
        pub fn merge(lhs: Flags, rhs: Flags) Flags {
            return fromInt(toInt(lhs) | toInt(rhs));
        }
        pub fn intersection(lhs: Flags, rhs: Flags) Flags {
            return fromInt(toInt(lhs) & toInt(rhs));
        }
        pub fn negation(self: Flags) Flags {
            return fromInt(~toInt(self));
        }
        pub fn difference(lhs: Flags, rhs: Flags) Flags {
            const n = negation(rhs);
            return intersection(lhs, n);
        }
        pub fn toBit(self: Flags) FlagBits {
            return @enumFromInt(toInt(self));
        }
        pub fn fromBit(bit: FlagBits) Flags {
            return fromInt(@intFromEnum(bit));
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
        const BackingInt = @typeInfo(Flags).@"struct".backing_integer.?;
        pub fn toFlags(self: FlagBits) Flags {
            return @bitCast(@intFromEnum(self));
        }
        pub fn fromFlags(self: Flags) FlagBits {
            const b: BackingInt = @bitCast(self);
            return @enumFromInt(b);
        }
        pub fn toInt(self: FlagBits) BackingInt {
            return @intFromEnum(self);
        }
        pub fn fromInt(self: BackingInt) FlagBits {
            return @enumFromInt(self);
        }
    };
}

fn nullValue(comptime T: type) T {
    const info = @typeInfo(T);
    return switch (info) {
        .@"enum" => @enumFromInt(0),
        .pointer => null,
        .array => @splat(@bitCast(0)),
        else => @bitCast(0),
    };
}

pub fn getFunctionVkName(func: anytype) []const u8 {
    const t = @tagName(func);
    return "vk" ++ std.ascii.toUpper(t[0]) ++ t[1..];
}
fn MakeLoader(comptime Functions: type, comptime funcs: []const Functions) type {
    var types: [funcs.len]type = undefined;
    var names: [funcs.len][]const u8 = undefined;
    const attr: [funcs.len]std.builtin.Type.StructField.Attributes = @splat(.{});
    for (funcs, &types, &names) |f, *t, *n| {
        t.* = f.getPtrType();
        n.* = @tagName(f);
    }
    return @Struct(.@"extern", null, &names, &types, attr);
}
fn getFunctionVkNames(comptime Functions: type, comptime funcs: []const Functions) []const []const u8 {
    comptime {
        var result: [funcs.len][]const u8 = undefined;
        for (funcs, &result) |f, *r| {
            r.* = getFunctionVkName(f);
        }
        const final = result;
        return &final;
    }
}
