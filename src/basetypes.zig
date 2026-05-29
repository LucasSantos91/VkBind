pub const Bool32 = enum(u32) {
    false,
    true,

    pub fn fromBool(b: bool) @This() {
        return switch (b) {
            false => .false,
            true => .true,
        };
    }
    pub fn toBool(self: @This()) bool {
        return switch (self) {
            .false => false,
            .true => true,
        };
    }
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
