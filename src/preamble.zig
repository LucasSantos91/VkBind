const std = @import("std");

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

inline fn nullValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .pointer, .@"union" => undefined,
        else => std.mem.zeroes(T),
    };
}

inline fn maybeUnused(_: anytype) void {}
pub fn isDispatchableHandle(comptime T: type) bool {
    const result = comptime blk: {
        const info = @typeInfo(T);
        if (info != .@"enum") break :blk false;
        break :blk info.@"enum".tag_type == usize;
    };
    return result;
}
fn LockedEnum(comptime T: type, comptime value: T) type {
    return @Enum(@typeInfo(T).@"enum".tag_type, .exhaustive, &.{@tagName(value)}, &.{@intFromEnum(value)});
}

fn LockedInt(comptime T: type, comptime value: T) type {
    return @Enum(T, .exhaustive, &.{std.fmt.comptimePrint("{}", .{value})}, &.{value});
}
inline fn justFreakingCastTheThing(value: anytype, comptime Target: type) Target {
    const V = @TypeOf(value);
    comptime std.debug.assert(@sizeOf(V) == @sizeOf(Target) and @alignOf(V) == @alignOf(Target));
    const ptr = &value;
    const casted: *const Target = @ptrCast(ptr);
    return casted.*;
}
