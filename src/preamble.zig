const std = @import("std");

fn FlagsMixin(comptime Flags: type, comptime FlagBits: type) type {
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
fn FlagBitsMixin(comptime Flags: type, comptime FlagBits: type) type {
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
        .@"enum" => |i| {
            if (i.mode == .nonexhaustive) return @enumFromInt(0);
            if (i.field_values.len == 0) return undefined;
            for (i.field_values) |v| {
                if (v == 0) return @enumFromInt(0);
            }
            return undefined;
        },
        else => std.mem.zeroes(T),
    };
}

inline fn maybeUnused(_: anytype) void {}
fn isDispatchableHandle_(comptime T: type) bool {
    const result = comptime blk: {
        const info = @typeInfo(T);
        if (info != .@"enum") break :blk false;
        break :blk info.@"enum".tag_type == usize;
    };
    return result;
}
fn LockedEnum(comptime T: type, comptime value: T) type {
    return enum(@typeInfo(T).@"enum".tag_type) {
        locked = @intFromEnum(value),

        pub fn unlock(self: @This()) T {
            return @enumFromInt(@intFromEnum(self));
        }
    };
}

fn LockedInt(comptime T: type, comptime value: T) type {
    return enum(T) {
        locked = value,

        pub fn unlock(self: @This()) T {
            return @intFromEnum(self);
        }
    };
}
inline fn justFreakingCastTheThing(value: anytype, comptime Target: type) Target {
    const V = @TypeOf(value);
    comptime std.debug.assert(@sizeOf(V) == @sizeOf(Target) and @alignOf(V) == @alignOf(Target));
    const ptr = &value;
    const casted: *const Target = @ptrCast(ptr);
    return casted.*;
}
fn isExtensibleStruct_(comptime T: type) bool {
    const result = comptime blk: {
        const i = @typeInfo(T);
        if (i != .@"struct") break :blk false;
        const n = i.@"struct".field_names;
        if (n.len < 2) break :blk false;
        if (!std.mem.eql(u8, n[0], "sType")) break :blk false;
        if (!std.mem.eql(u8, n[1], "pNext")) break :blk false;
        break :blk true;
    };
    return result;
}
fn StructChain_(comptime Base: type, comptime extension_types: []const type) type {
    comptime {
        if (!isExtensibleStruct_(Base)) @compileError(std.fmt.comptimePrint("{} is not an extensible struct", .{Base}));
        for (extension_types, 0..) |T, index| {
            if (!isExtensibleStruct_(T)) @compileError(std.fmt.comptimePrint("{} is not an extensible struct", .{T}));
            if (std.mem.findScalar(type, T.structextends, Base) == null)
                @compileError(std.fmt.comptimePrint("{} does not extend {}", .{ T, Base }));
            if (!T.allowduplicate and
                (T == Base or std.mem.findScalar(type, extension_types[index + 1 ..], T) != null))
            {
                @compileError(std.fmt.comptimePrint("{} does not allow duplicates in a pNext chain", .{T}));
            }
        }
    }
    return struct {
        const Extensions = @Tuple(extension_types);
        base: Base = undefined,
        extensions: Extensions = undefined,

        pub fn init(self: *@This(), base: Base, extensions: Extensions) void {
            self.* = .{
                .base = base,
                .extensions = extensions,
            };
            self.initChain();
        }

        /// Sets up the pNext chain
        pub fn initChain(self: *@This()) void {
            self.base.sType = .locked;
            if (comptime extension_types.len == 0) {
                self.base.pNext = null;
                return;
            }
            self.base.pNext = &self.extensions[0];
            self.extensions[0].sType = .locked;
            inline for (0..self.extensions.len - 1, 1..) |lhs_index, rhs_index| {
                const lhs = &self.extensions[lhs_index];
                const rhs = &self.extensions[rhs_index];
                lhs.pNext = rhs;
                rhs.sType = .locked;
            }
            self.extensions[self.extensions.len - 1].pNext = null;
        }

        pub fn get(self: *@This(), comptime Field: type, comptime index: usize) *Field {
            return @constCast(self.getC(Field, index));
        }
        pub fn getC(self: *@This(), comptime Field: type, comptime index: usize) *const Field {
            if (comptime Field == Base and index == 0) return self.getBaseC();
            const extension_index = comptime blk: {
                var i = index;
                if (Field == Base) i -= 1;
                for (extension_types, 0..) |T, final_index| {
                    if (Field == T) {
                        if (i == 0) break :blk final_index;
                        i -= 1;
                    }
                }
                const text = std.fmt.comptimePrint("There is no type {} with index {}", .{ Field, index });
                @compileError(text);
            };
            return &self.extensions[extension_index];
        }
        pub fn getBase(self: *@This()) *Base {
            return &self.base;
        }
        pub fn getBaseC(self: *const @This()) *const Base {
            return &self.base;
        }
    };
}

const struct_init = struct {
    pub fn onlySType(comptime T: type) T {
        var result: T = undefined;
        if (comptime std.meta.fieldIndex("sType", T)) |i| if (i == 0) {
            result.sType = .locked;
        };
        return result;
    }
    pub fn sTypeAndPNext(comptime T: type) T {
        var result: T = undefined;
        if (comptime std.meta.fieldIndex("sType", T)) |i| if (i == 0) {
            result.sType = .locked;
            result.pNext = null;
        };
        return result;
    }
    pub fn zeroes(comptime T: type) T {
        var result = std.mem.zeroes(T);
        if (comptime std.meta.fieldIndex("sType", T)) |i| if (i == 0) {
            result.sType = .locked;
            result.pNext = null;
        };
        return result;
    }
};
