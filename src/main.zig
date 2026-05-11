const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const panic = std.debug.panic;
const slice_tools = @import("slice_tools");
const enumFromName = slice_tools.enums.fromName;

pub fn find(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.find(u8, haystack, needle);
}
pub fn findScalar(haystack: []const u8, scalar: u8) ?usize {
    return std.mem.findScalar(u8, haystack, scalar);
}
pub fn sliceTo(text: []u8, end: u8) ?[]u8 {
    const i = findScalar(text, end) orelse return null;
    return text[0..i];
}
pub fn findAny(text: []const u8, values: []const u8) ?usize {
    return std.mem.findAny(u8, text, values);
}
pub fn findNone(text: []const u8, values: []const u8) ?usize {
    return std.mem.findNone(u8, text, values);
}

const panics = struct {
    fn unexpectedEnd() noreturn {
        @panic("Unexpected end of stream");
    }
    fn readFailed() noreturn {
        @panic("Failed to read from input");
    }
    pub fn reader(e: Reader.Error) noreturn {
        switch (e) {
            Reader.Error.EndOfStream => unexpectedEnd(),
            Reader.Error.ReadFailed => readFailed(),
        }
    }
    pub fn takeDelimiter(e: error{ StreamTooLong, ReadFailed }) noreturn {
        switch (e) {
            error.StreamTooLong => @panic("Insufficient buffer for reading"),
            error.ReadFailed => readFailed(),
        }
    }
    pub fn delimiter(e: Reader.DelimiterError) noreturn {
        switch (e) {
            Reader.DelimiterError.StreamTooLong, Reader.DelimiterError.ReadFailed => takeDelimiter(@errorCast(e)),
            Reader.DelimiterError.EndOfStream => unexpectedEnd(),
        }
    }
    pub fn write() noreturn {
        @panic("Failed to write to stdout");
    }
    pub fn oom() noreturn {
        @panic("OOM");
    }
};
const ReaderWrap = struct {
    reader: *Reader,

    pub fn takeByte(self: @This()) u8 {
        return self.reader.takeByte() catch |e| panics.reader(e);
    }
    pub fn peekByte(self: @This()) u8 {
        return self.reader.peekByte() catch |e| panics.reader(e);
    }
    pub fn peekDelimiterInclusive(self: @This(), delimiter: u8) []u8 {
        return self.reader.peekDelimiterInclusive(delimiter) catch |e| panics.delimiter(e);
    }
    pub fn peekDelimiterExclusive(self: @This(), delimiter: u8) []u8 {
        return self.reader.peekDelimiterExclusive(delimiter) catch |e| panics.delimiter(e);
    }
    pub fn discardDelimiterInclusive(self: @This(), delimiter: u8) void {
        _ = self.reader.discardDelimiterInclusive(delimiter) catch |e| panics.reader(e);
    }
    pub fn peek(self: @This(), len: usize) []u8 {
        self.reader.peek(len) catch |e| panics.reader(e);
    }
    pub fn toss(self: @This(), len: usize) void {
        self.reader.toss(len);
    }
    pub fn tossBuffered(self: @This(), len: usize) void {
        self.reader.tossBuffered(len);
    }
    pub fn takeDelimiter(self: @This(), delimiter: u8) []u8 {
        return self.reader.takeDelimiter(delimiter) catch |e| panics.delimiter(e) orelse panics.unexpectedEnd();
    }
    pub fn takeDelimiterExclusive(self: @This(), delimiter: u8) []u8 {
        return self.reader.takeDelimiterExclusive(delimiter) catch |e| panics.delimiter(e) orelse panics.unexpectedEnd();
    }
    pub fn peekGreedy(self: @This(), n: usize) []u8 {
        return self.reader.peekGreedy(n) catch |e| panics.reader(e);
    }
    pub fn discardAll(self: @This(), n: usize) void {
        self.reader.discardAll(n) catch |e| panics.reader(e);
    }
};

const WriterWrapper = struct {
    writer: *Writer,

    pub fn writeByte(self: @This(), byte: u8) void {
        self.writer.writeByte(byte) catch panics.write();
    }
    pub fn writeAll(self: @This(), text: []const u8) void {
        self.writer.writeAll(text) catch panics.write();
    }
    pub fn print(self: @This(), comptime format: []const u8, args: anytype) void {
        self.writer.print(format, args) catch panics.write();
    }
    pub fn flush(self: @This()) void {
        self.writer.flush() catch panics.write();
    }
};

const XmlIterator = struct {
    reader: ReaderWrap,

    pub fn goToTag(self: @This()) void {
        self.reader.discardDelimiterInclusive('<');
    }
    pub fn closeTag(self: @This()) void {
        self.reader.discardDelimiterInclusive('>');
    }
    pub fn getTagText(self: @This()) []const u8 {
        var len: usize = 1;
        while (true) {
            const text = self.reader.peekGreedy(len);
            if (findAny(text, " >")) |i| {
                self.reader.toss(i);
                return text[0..i];
            }
            len += 1;
        }
    }
    pub fn seekTags(self: @This(), comptime TagsEnum: type) TagsEnum {
        while (true) {
            self.goToTag();
            const text = self.getTagText();
            if (enumFromName(TagsEnum, text)) |tag| return tag;
        }
    }

    pub fn goToAttrKey(self: @This()) bool {
        while (true) {
            const text = self.reader.peekGreedy(1);
            const not_space_index = findNone(text, " ") orelse {
                self.reader.reader.tossBuffered();
                continue;
            };
            switch (text[not_space_index]) {
                '>' => {
                    self.reader.toss(not_space_index + 1);
                    return false;
                },
                '/' => {
                    self.reader.toss(not_space_index + 1);
                    return false;
                },
                else => {
                    self.reader.toss(not_space_index);
                    return true;
                },
            }
        }
    }
    pub fn getAttrKey(self: @This()) ?[]u8 {
        if (!self.goToAttrKey()) return null;
        return self.reader.takeDelimiter('=');
    }
    pub fn discardAttrValue(self: @This()) void {
        for (0..2) |_| {
            _ = self.reader.discardDelimiterInclusive('"');
        }
    }
    pub fn getAttrValue(self: @This()) []u8 {
        _ = self.reader.discardDelimiterInclusive('"');
        return self.reader.takeDelimiter('"');
    }

    pub fn nextAttr(self: @This(), comptime KeysOfInterest: type) ?struct { key: KeysOfInterest, value: []u8 } {
        while (self.getAttrKey()) |text| {
            if (enumFromName(KeysOfInterest, text)) |key| {
                return .{ .key = key, .value = self.getAttrValue() };
            } else {
                self.discardAttrValue();
            }
        }
        return null;
    }
    pub fn getNextBetweenTags(self: @This()) []u8 {
        self.goToTag();
        self.closeTag();
        return self.reader.takeDelimiter('<');
    }

    pub fn seekTagAndClose(self: @This(), comptime Tags: type) Tags {
        const t = self.seekTags(Tags);
        self.closeTag();
        return t;
    }
};

const CommaIterator = struct {
    text: []u8,

    pub fn next(self: *@This()) ?[]u8 {
        const comma = std.mem.find(u8, self.text, ",");
        const this = if (comma) |i| self.text[0..i] else self.text;
        if (this.len == 0) return null;
        self.text = self.text[this.len..];
        return this;
    }
};

const Registry = struct {
    const Bitmask = struct {
        const Entry = struct {
            name: []u8,
            bitpos: u8,
            comment: []u8,
            aliases: [][]u8,
        };
        const Bits = enum {
            @"32",
            @"64",

            pub fn toZig(self: @This()) []const u8 {
                return switch (self) {
                    .@"32" => "u32",
                    .@"64" => "u64",
                };
            }
            pub fn parse(vk_flags: []const u8) @This() {
                const e = enumFromName(enum { VkFlags, VkFlags64 }, vk_flags) orelse panic("Unknown bitwidth: {s}", .{vk_flags});
                return switch (e) {
                    .VkFlags => .@"32",
                    .VkFlags64 => .@"64",
                };
            }
        };

        bits: Bits = .@"32",
        comment: []u8 = &.{},
        entries: []Entry = &.{},
        aggregates: []Enum.Entry = &.{},
        aliases: [][]u8 = &.{},
    };

    const Enum = struct {
        const Entry = struct {
            name: []u8 = &.{},
            value: []u8 = &.{},
            comment: []u8 = &.{},
            aliases: [][]u8 = &.{},
        };

        comment: []u8 = &.{},
        entries: []Entry = &.{},
        aliases: [][]u8 = &.{},
    };

    const Command = struct {
        return_value: ZigType,
        params: []ZigVar = &.{},
        success_codes: []u8 = &.{},
        error_codes: []u8 = &.{},
        aliases: [][]u8 = &.{},
    };
    const DispatchableHandle = struct {
        commands: []Command = &.{},
        aliases: [][]u8 = &.{},
    };
    const NonDispatchableHandle = struct {
        aliases: [][]u8 = &.{},
    };
    const StructOrUnion = struct {
        const Member = struct {
            member: ZigVar,
            comment: []u8,
        };
        comment: []u8 = &.{},
        members: []Member = &.{},
        aliases: [][]u8 = &.{},
        s_type: []u8 = &.{},
    };

    const VarType = union(enum) {
        const Primitive = enum {
            void,
            u8,
            u16,
            u32,
            u64,
            c_int,
            i32,
            i64,
            f32,
            f64,
            usize,

            const CPrimitive = enum {
                void,
                char,
                uint8_t,
                uint16_t,
                uint32_t,
                uint64_t,
                int,
                int32_t,
                int64_t,
                float,
                double,
                size_t,
            };

            pub fn parse(text: []const u8) ?@This() {
                const e = slice_tools.enums.fromName(CPrimitive, text) orelse return null;
                return switch (e) {
                    .void => .void,
                    .char, .uint8_t => .u8,
                    .uint16_t => .u16,
                    .uint32_t => .u32,
                    .uint64_t => .u64,
                    .int => .c_int,
                    .int32_t => .i32,
                    .int64_t => .i64,
                    .float => .f32,
                    .double => .f64,
                    .size_t => .usize,
                };
            }
        };

        primitive: Primitive,
        non_primitive: []const u8,

        pub fn parse(text: []const u8, allocator: Allocator) @This() {
            return if (Primitive.parse(text)) |p|
                .{ .primitive = p }
            else
                .{ .non_primitive = allocator.dupe(u8, text) catch panics.oom() };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self) {
                .primitive => |a| {
                    try writer.print("{t}", .{a});
                },
                .non_primitive => |a| {
                    try writeTypeWithoutPrefix(writer, a);
                }
            }
        }
    };

    fn writeWithoutVkPrefix(writer: *Writer, text: []const u8) Writer.Error!bool {
        if (std.mem.startsWith(u8, text, "Vk")) {
            try writer.writeAll(text[2..]);
            return true;
        }
        return false;
    }
    fn writeWithoutPfnPrefix(writer: *Writer, text: []const u8) Writer.Error!bool {
        if (std.mem.startsWith(u8, text, "PFN_vk")) {
            try writer.print("Pfn{s}", .{text["PFN_vk".len..]});
            return true;
        }
        return false;
    }
    fn writeTypeWithoutPrefix(writer: *Writer, text: []const u8) Writer.Error!void {
        if (try writeWithoutVkPrefix(writer, text)) return;
        if (try writeWithoutPfnPrefix(writer, text)) return;
        try writer.writeAll(text);
    }
    fn writeWithoutVK_PrefixAndLower(writer: *Writer, text: []const u8) Writer.Error!bool {
        if (std.mem.startsWith(u8, text, "VK_")) {
            try writeLower(text["VK_".len..], writer);
            return true;
        }
        return false;
    }
    fn writeWithoutVK_PrefixAndLowerOrPanic(writer: *Writer, text: []const u8) Writer.Error!void {
        if (!(try writeWithoutVK_PrefixAndLower(writer, text))) panic("Failed to remove VK_ prefix from: {s}", .{text});
    }
    const CType = struct {
        const Kind = enum {
            @"const",
            mutable,
        };
        const max_ptr_layer = 2;

        ptrs: slice_tools.BoundedArray(Kind, max_ptr_layer) = .{},
        base_type: VarType,

        pub fn parse(it: XmlIterator, allocator: Allocator) @This() {
            var result: @This() = .{
                .base_type = undefined,
            };
            const b = it.reader.takeDelimiter('<');
            if (find(b, "const")) |_| {
                result.ptrs.appendAssumeCapacity(.@"const");
            }
            it.closeTag();
            const t = it.reader.takeDelimiter('<');
            result.base_type = .parse(t, allocator);
            it.closeTag();
            var after_type = it.reader.takeDelimiter('<');
            if (findScalar(after_type, '*')) |i| {
                if (result.ptrs.len == 0) result.ptrs.appendAssumeCapacity(.mutable);
                after_type = after_type[i + 1 ..];
            }
            if (findAny(after_type, "*c")) |i| {
                switch (after_type[i]) {
                    '*' => result.ptrs.appendAssumeCapacity(.mutable),
                    'c' => {
                        // Must be const, but we'll just trust it
                        assert(std.mem.startsWith(u8, after_type[i..], "const"));
                        result.ptrs.appendAssumeCapacity(.@"const");
                    },
                    else => unreachable,
                }
            }
            return result;
        }

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            for (self.ptrs.constSlice()) |p| {
                try writer.writeAll(switch (p) {
                    .@"const" => "[*c]const",
                    .mutable => "[*c]",
                });
            }
            if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive == .void) {
                try writer.writeAll(" anyopaque");
            } else {
                try writer.print(" {f}", .{self.base_type});
            }
        }
    };

    const CVar = struct {
        const Amount = union(enum) {
            const Array = struct {
                is_literal: bool,
                data: []u8,
            };
            array: Array,
            bitfield: []u8,
            single,
        };
        type: CType,
        name: []u8,
        amount: Amount,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:", .{self.name});
            switch (self.amount) {
                .single => {
                    for (self.type.ptrs.constSlice()) |p| {
                        try writer.writeAll(switch (p) {
                            .@"const" => "[*c]const",
                            .mutable => "[*c]",
                        });
                    }
                    if (self.type.ptrs.len != 0 and self.type.base_type == .primitive and self.type.base_type.primitive == .void) {
                        try writer.writeAll(" anyopaque");
                    } else {
                        try writer.print(" {f}", .{self.type.base_type});
                    }
                },
                .bitfield => |b| {
                    try writer.print("u{s}", .{b});
                },
                .array => |ar| {
                    try writer.print("[{s}]{f}", .{ ar.data, self.type });
                }
            }
        }

        pub fn parse(it: XmlIterator, allocator: Allocator) @This() {
            var result: @This() = .{
                .type = .parse(it, allocator),
                .name = undefined,
                .amount = undefined,
            };
            it.closeTag();
            result.name = allocator.dupe(u8, it.reader.takeDelimiter('<')) catch panics.oom();
            it.closeTag();
            const amount = it.reader.peekDelimiterExclusive('<');
            const i = findAny(amount, ":[") orelse {
                it.reader.toss(amount.len);
                result.amount = .single;
                return result;
            };
            switch (amount[i]) {
                ':' => {
                    result.amount = .{ .bitfield = allocator.dupe(u8, amount[i + 1 ..]) catch panics.oom() };
                    it.reader.toss(amount.len + 1);
                },
                '[' => {
                    result.amount = .{ .array = undefined };
                    const am = &result.amount.array;
                    it.reader.toss(i + 1);
                    var inside_brackets = it.reader.takeDelimiter(']');
                    if (findScalar(inside_brackets, '<')) |j| {
                        inside_brackets = inside_brackets[j + 1 ..];
                        var k = findScalar(inside_brackets, '>') orelse @panic("Unclosed tag");
                        inside_brackets = inside_brackets[k + 1 ..];
                        k = findScalar(inside_brackets, '<') orelse panic("Failed to find amount end for {s}", .{result.name});
                        am.* = .{
                            .is_literal = false,
                            .data = allocator.dupe(u8, inside_brackets[0..k]) catch panics.oom(),
                        };
                    } else {
                        am.* = .{
                            .is_literal = true,
                            .data = allocator.dupe(u8, inside_brackets) catch panics.oom(),
                        };
                    }
                },
                else => unreachable,
            }
            return result;
        }
    };

    const ZigType = struct {
        const Size = enum {
            single,
            many,
            null_terminated,
        };
        const Ptr = struct {
            optional: bool = false,
            size: Size = .single,
            kind: CType.Kind = .mutable,

            pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
                const optional_text = if (self.optional)
                    "?"
                else
                    "";
                const ptr_text = switch (self.size) {
                    .single => "*",
                    .many => "[*]",
                    .null_terminated => "[*:0]",
                };
                const kind_text = switch (self.kind) {
                    .@"const" => "const",
                    .mutable => "",
                };
                try writer.print("{s}{s}{s}", .{ optional_text, ptr_text, kind_text });
            }
        };
        const Ptrs = slice_tools.BoundedArray(Ptr, 2);

        ptrs: Ptrs = .{},
        base_type: VarType,
        amount: CVar.Amount,

        pub fn fromCType(c_type: CType) @This() {
            var ret: @This() = .{
                .ptrs = .{ .len = c_type.ptrs.len },
                .amount = c_type.amount,
                .base_type = c_type.base_type,
            };
            for (ret.ptrs.slice(), c_type.ptrs.constSlice()) |*dst, src| {
                dst.* = .{
                    .optional = false,
                    .size = .single,
                    .kind = src,
                };
            }
            return ret;
        }

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            if (self.amount == .bitfield) {
                try writer.print("u{s}", .{self.amount.bitfield});
                return;
            }
            for (self.ptrs.constSlice()) |p| {
                try writer.print("{f} ", .{p});
            }
            switch (self.amount) {
                .single => {},
                .array => |ar| {
                    try writer.writeByte('[');
                    if (ar.is_literal) {
                        try writer.writeAll(ar.data);
                    } else {
                        try writeWithoutVK_PrefixAndLowerOrPanic(writer, ar.data);
                    }
                    try writer.writeByte(']');
                },
                .bitfield => unreachable,
            }
            if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive == .void) {
                try writer.writeAll("anyopaque");
            } else {
                try writer.print("{f}", .{self.base_type});
            }
        }
    };
    const ZigVar = struct {
        name: []u8,
        type: ZigType,

        pub fn fromCVar(c_var: CVar) @This() {
            return .{
                .name = c_var.name,
                .type = .fromCType(c_var.type),
            };
        }

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:{f}", .{ self.name, self.type });
        }
    };
    const Funcpointer = struct {
        ret_type: CType,
        params: []CVar,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll("*const fn(");
            for (self.params) |p| {
                try writer.print("{f},", .{p});
            }
            try writer.print(")callconv(vulkan_api) {f};", .{self.ret_type});
        }
    };
    const Constant = struct {
        comment: []u8,
        primitive: VarType.Primitive,
        value: []u8,
    };

    bitmasks: std.StringHashMapUnmanaged(Bitmask) = .empty,
    enums: std.StringHashMapUnmanaged(Enum) = .empty,
    funcpointers: std.StringHashMapUnmanaged(Funcpointer) = .empty,
    dispatchable_handles: std.StringHashMapUnmanaged(DispatchableHandle) = .empty,
    non_dispatchable_handles: std.StringHashMapUnmanaged(NonDispatchableHandle) = .empty,
    structs: std.StringHashMapUnmanaged(StructOrUnion) = .empty,
    unions: std.StringHashMapUnmanaged(StructOrUnion) = .empty,
    constants: std.StringHashMapUnmanaged(Constant) = .empty,

    fn add(comptime T: type, hashmap: *std.StringHashMapUnmanaged(T), name: []u8, element: T, allocator: Allocator) void {
        const r = hashmap.getOrPut(allocator, name) catch panics.oom();
        if (r.found_existing) panic("Duplicate entry: {s}", .{name});
        r.value_ptr.* = element;
    }
    pub fn addBitmask(self: *@This(), name: []u8, bitmask: Bitmask, allocator: Allocator) void {
        add(Bitmask, &self.bitmasks, name, bitmask, allocator);
    }
    pub fn addEnum(self: *@This(), name: []u8, new_enum: Enum, allocator: Allocator) void {
        add(Enum, &self.enums, name, new_enum, allocator);
    }
    pub fn addFuncpointer(self: *@This(), name: []u8, funcpointer: Funcpointer, allocator: Allocator) void {
        add(Funcpointer, &self.funcpointers, name, funcpointer, allocator);
    }
    pub fn addDispatchableHandle(self: *@This(), name: []u8, allocator: Allocator) void {
        add(DispatchableHandle, &self.dispatchable_handles, name, .{}, allocator);
    }
    pub fn addNonDispatchableHandle(self: *@This(), name: []u8, allocator: Allocator) void {
        add(NonDispatchableHandle, &self.non_dispatchable_handles, name, .{}, allocator);
    }
    pub fn addStruct(self: *@This(), name: []u8, new_struct: StructOrUnion, allocator: Allocator) void {
        add(StructOrUnion, &self.structs, name, new_struct, allocator);
    }
    pub fn addUnion(self: *@This(), name: []u8, new_union: StructOrUnion, allocator: Allocator) void {
        add(StructOrUnion, &self.unions, name, new_union, allocator);
    }
    pub fn addConstant(self: *@This(), name: []u8, constant: Constant, allocator: Allocator) void {
        add(Constant, &self.constants, name, constant, allocator);
    }
    pub fn printFuncpointers(self: *const @This(), writer: *Writer) Writer.Error!void {
        var it = self.funcpointers.iterator();
        while (it.next()) |elem| {
            try writer.writeAll("pub const ");
            const w = try writeWithoutPfnPrefix(writer, elem.key_ptr.*);
            if (!w) panic("Funcpointer doesn't start with PFN_vk: {s}", .{elem.key_ptr.*});
            try writer.print("={f}", .{elem.value_ptr.*});
        }
    }
    fn writeWithoutVkPrefixOrPanic(writer: *Writer, text: []const u8) Writer.Error!void {
        if (!(try writeWithoutVkPrefix(writer, text))) panic("Type doesn't start with Vk: {s}", .{text});
    }
    fn printHandleCommon(writer: *Writer, name: []const u8, aliases: []const []const u8, enum_backing_int: []const u8) Writer.Error!void {
        try writer.writeAll("pub const ");
        try writeWithoutVkPrefixOrPanic(writer, name);
        try writer.print("=enum({s}){{null_handle, _}};", .{enum_backing_int});
        for (aliases) |alias| {
            try writer.writeAll("pub const ");
            try writeWithoutVkPrefixOrPanic(writer, alias);
            try writer.print("={s};", .{
                name[2..], // We already know it starts with Vk
            });
        }
    }
    fn printNonDispatchableHandles(self: *const @This(), writer: *Writer) Writer.Error!void {
        var it = self.non_dispatchable_handles.iterator();
        while (it.next()) |elem| {
            try printHandleCommon(writer, elem.key_ptr.*, elem.value_ptr.aliases, "u64");
        }
    }
    fn printDispatchableHandles(self: *const @This(), writer: *Writer) Writer.Error!void {
        var it = self.dispatchable_handles.iterator();
        while (it.next()) |elem| {
            try printHandleCommon(writer, elem.key_ptr.*, elem.value_ptr.aliases, "usize");
        }
    }
    fn printComment(writer: *Writer, comment: []const u8) Writer.Error!void {
        var c = if (std.mem.startsWith(u8, comment, "//")) comment[2..] else comment;
        c = std.mem.trim(u8, c, " ");
        if (c.len != 0) {
            try writer.print("\n/// {s}\n", .{c});
        }
    }

    fn printStructsAndUnionsCommon(writer: *Writer, name: []const u8, elem: *StructOrUnion, is_struct: bool) Writer.Error!void {
        try printComment(writer, elem.comment);
        try writer.writeAll("pub const ");
        try writeWithoutVkPrefixOrPanic(writer, name);
        try writer.print("=extern {s}{{", .{if (is_struct) "struct" else "union"});
        var members = elem.members;
        if (elem.s_type.len != 0) {
            const trimmed = slice_tools.safeSubslice(elem.s_type, "VK_STRUCTURE_TYPE_".len, .unlimited) catch
                panic("sType doesn't start with expected prefix: {s}", .{elem.s_type});
            _ = std.ascii.lowerString(trimmed, trimmed);
            try writer.print("sType: StructureType=.{s},\n", .{trimmed});
            members = members[1..];
        }
        for (members) |member| {
            try printComment(writer, member.comment);
            try writer.print("{f}", .{member.member});
            if (is_struct and member.member.type.ptrs.buffer[0].optional) {
                try writer.writeByte('=');
                const null_value = if (member.member.type.ptrs.len != 0)
                    "null"
                else
                    "@bitCast(0)";
                try writer.writeAll(null_value);
            }
            try writer.writeByte(',');
        }
        try writer.writeAll("};\n");
        for (elem.aliases) |alias| {
            try writer.writeAll("pub const ");
            try writeWithoutVkPrefixOrPanic(writer, alias);
            try writer.print("={s};", .{name["VK".len..]});
        }
    }
    fn printStructsAndUnions(self: *const @This(), writer: *Writer) Writer.Error!void {
        {
            var it = self.structs.iterator();
            while (it.next()) |elem| {
                try printStructsAndUnionsCommon(writer, elem.key_ptr.*, elem.value_ptr, true);
            }
        }
        {
            var it = self.unions.iterator();
            while (it.next()) |elem| {
                try printStructsAndUnionsCommon(writer, elem.key_ptr.*, elem.value_ptr, false);
            }
        }
    }
    fn countAuthorLen(text: []const u8) usize {
        const last = text.ptr + text.len;
        var ptr = last;
        while (ptr != text.ptr) {
            ptr -= 1;
            if (std.ascii.isLower(ptr[0])) {
                ptr += 1;
                break;
            }
        }
        return last - ptr;
    }
    fn stripAuthor(text: []u8) []u8 {
        const author_len = countAuthorLen(text);
        return text[0 .. text.len - author_len];
    }
    fn getEnumPrefixLen(enum_name: []const u8, entry_name: []const u8) usize {
        const author_len = countAuthorLen(enum_name);
        if (entry_name.len <= enum_name.len - author_len) panic("Entry {s} doesn't start with prefix for enum {s}", .{ entry_name, enum_name });
        var name_ptr = enum_name.ptr;
        for (entry_name) |c| {
            if (c == '_') {
                name_ptr += 1;
                continue;
            }
            name_ptr += 1;
            if (std.ascii.toLower(c) != std.ascii.toLower(name_ptr[0])) {
                break;
            }
        }
        const len = name_ptr - enum_name.ptr;
        return len;
    }

    fn printEnums(self: *const @This(), writer: *Writer) Writer.Error!void {
        var it = self.enums.iterator();
        while (it.next()) |entry| {
            try printComment(writer, entry.value_ptr.comment);
            try writer.writeAll("pub const ");
            const name = entry.key_ptr.*;
            if (!(try writeWithoutVkPrefix(writer, name))) panic("Enum name doesn't start with Vk prefix: {s}", .{name});
            try writer.writeAll("=enum(c_int){");
            if (entry.value_ptr.entries.len != 0) {
                const prefix_len = getEnumPrefixLen(name, entry.value_ptr.entries[0].name);
                for (entry.value_ptr.entries) |e| {
                    try printComment(writer, e.comment);
                    const trimmed = slice_tools.safeSubslice(e.name, prefix_len, .unlimited) catch
                        panic("Failed to remove prefix for enum entry {s}", .{e.name});
                    _ = std.ascii.lowerString(trimmed, trimmed);
                    try writer.print("{s}={s},", .{ trimmed, e.value });
                }
                const prefix = entry.value_ptr.entries[0].name[0..prefix_len];
                for (entry.value_ptr.entries) |e| {
                    const canon = e.name[prefix_len..];
                    for (e.aliases) |alias| {
                        if (std.mem.startsWith(u8, alias, prefix)) {
                            const trimmed = alias[prefix_len..];
                            _ = std.ascii.lowerString(trimmed, trimmed);
                            try writer.print("pub const {s}={s};", .{ trimmed, canon });
                        } else {
                            try writer.writeAll("pub const ");
                            if (!(try writeWithoutVkPrefix(writer, alias))) panic("Alias doesn't start with expected prefix or Vk: {s}", .{alias});
                            try writer.print("={s};", .{canon});
                        }
                    }
                }
            }
            try writer.writeAll("};");
        }
    }

    fn printBitmasks(self: *const @This(), writer: *Writer) Writer.Error!void {
        _ = self; // autofix
        _ = writer; // autofix
    }
    fn writeLower(text: []const u8, writer: *Writer) Writer.Error!void {
        for (text) |c|
            try writer.writeByte(std.ascii.toLower(c));
    }
    fn printConstants(self: *@This(), writer: *Writer) Writer.Error!void {
        const overrides: []const []const u8 = &.{ "VK_TRUE", "VK_FALSE" };
        for (overrides) |o| {
            _ = self.constants.remove(o);
        }
        var it = self.constants.iterator();
        while (it.next()) |entry| {
            try printComment(writer, entry.value_ptr.comment);
            try writer.writeAll("pub const ");
            try writeWithoutVK_PrefixAndLowerOrPanic(writer, entry.key_ptr.*);
            var negate = false;
            var value = entry.value_ptr.value;
            if (findScalar(value, '~')) |i| {
                value = value[i + 1 ..];
                negate = true;
            }
            if (findNone(value, "0123456789.")) |i| {
                value = value[0..i];
            }
            try writer.print(":{t}=", .{entry.value_ptr.primitive});
            if (negate) {
                try writer.print("~@as({t}, {s});", .{ entry.value_ptr.primitive, value });
            } else {
                try writer.print("{s};", .{value});
            }
        }
    }
    pub fn format(self: *@This(), writer: *Writer) Writer.Error!void {
        try self.printFuncpointers(writer);
        try self.printNonDispatchableHandles(writer);
        try self.printDispatchableHandles(writer);
        try self.printStructsAndUnions(writer);
        try self.printEnums(writer);
        try self.printBitmasks(writer);
        try self.printConstants(writer);
    }
};

const Parser = struct {
    const Api = enum {
        vulkan,
        vulkansc,

        pub fn match(current: @This(), other: ?[]u8) bool {
            var it: CommaIterator = .{ .text = other orelse return true };
            while (it.next()) |api| {
                const a = slice_tools.enums.fromName(@This(), api) orelse std.debug.panic("Unknown api: {s}", .{api});
                if (current == a) return true;
            }
            return false;
        }
    };
    const DispatchableHandle = struct {
        commands: []Registry.Command,
    };

    registry: Registry = .{},
    xml_iterator: XmlIterator,
    allocator: Allocator,
    api: Api,

    fn dupe(self: *const @This(), str: []const u8) []u8 {
        return self.allocator.dupe(u8, str) catch panics.oom();
    }
    fn freeDupe(self: *const @This(), str: []const u8) void {
        self.allocator.free(str);
    }
    pub fn init(reader: *Reader, allocator: Allocator, api: Api) @This() {
        return .{
            .allocator = allocator,
            .xml_iterator = .{ .reader = .{ .reader = reader } },
            .api = api,
            .registry = .{},
        };
    }

    pub fn parse(self: *@This()) void {
        _ = self.xml_iterator.seekTags(enum { registry });
        while (true) switch (self.xml_iterator.seekTags(enum { types, enums, commands, extensions, @"/registry" })) {
            .types => self.parseTypes(),
            .enums => self.parseEnums(),
            .commands => self.parseCommands(),
            .extensions => self.parseExtensions(),
            .@"/registry" => return,
        };
    }
    fn parseTypes(self: *@This()) void {
        while (true) switch (self.xml_iterator.seekTags(enum { type, @"/types" })) {
            .type => self.parseType(),
            .@"/types" => return,
        };
    }
    fn parseType(self: *@This()) void {
        while (self.xml_iterator.nextAttr(enum { api, category })) |kv| switch (kv.key) {
            .api => {
                if (!self.api.match(kv.value)) return;
            },
            .category => {
                switch (enumFromName(enum { handle, @"struct", @"union", funcpointer, @"enum" }, kv.value) orelse continue) {
                    .handle => self.parseHandle(),
                    .@"struct", .@"union" => |e| self.parseStructOrUnion(e == .@"struct"),
                    .funcpointer => self.parseFuncpointer(),
                    .@"enum" => self.parseTypeEnum(),
                }
                return;
            }
        };
    }
    fn parseTypeEnum(self: *@This()) void {
        var name: []u8 = &.{};
        var alias: []u8 = &.{};
        while (self.xml_iterator.nextAttr(enum { name, alias })) |kv| switch (kv.key) {
            .name => {
                name = self.dupe(kv.value);
            },
            .alias => {
                alias = self.dupe(kv.value);
            },
        };

        if (name.len == 0 or alias.len == 0) {
            self.freeDupe(name);
            self.freeDupe(alias);
            return;
        }
        const aliases = if (find(name, "FlagBits") != null) blk: {
            const gp = self.registry.bitmasks.getOrPut(self.allocator, name) catch panics.oom();
            if (!gp.found_existing) {
                gp.value_ptr.* = .{};
            }
            break :blk &gp.value_ptr.aliases;
        } else blk: {
            const gp = self.registry.enums.getOrPut(self.allocator, name) catch panics.oom();
            if (!gp.found_existing) {
                gp.value_ptr.* = .{};
            }
            break :blk &gp.value_ptr.aliases;
        };
        aliases.* = slice_tools.allocated.concat([]u8, aliases.*, &.{alias}, self.allocator) catch panics.oom();
    }
    fn parseHandle(self: *@This()) void {
        if (self.xml_iterator.nextAttr(enum { name })) |kv| {
            // This is an alias
            const name = self.dupe(kv.value);
            const alias = self.xml_iterator.nextAttr(enum { alias }) orelse panic("Missing alias for handle {s}", .{name});
            if (self.registry.dispatchable_handles.getPtr(alias.value)) |entry| {
                entry.aliases = slice_tools.allocated.concat([]u8, entry.aliases, &.{name}, self.allocator) catch panics.oom();
            } else if (self.registry.non_dispatchable_handles.getPtr(alias.value)) |entry| {
                entry.aliases = slice_tools.allocated.concat([]u8, entry.aliases, &.{name}, self.allocator) catch panics.oom();
            } else panic("Failed to find handle: {s}", .{alias.value});
            return;
        }
        const kind_text = self.xml_iterator.getNextBetweenTags();
        const kind = enumFromName(enum { VK_DEFINE_NON_DISPATCHABLE_HANDLE, VK_DEFINE_HANDLE }, kind_text) orelse
            panic("Failed to classify handle: {s}", .{kind_text});
        const name = self.xml_iterator.getNextBetweenTags();
        switch (kind) {
            .VK_DEFINE_NON_DISPATCHABLE_HANDLE => {
                self.registry.addNonDispatchableHandle(self.dupe(name), self.allocator);
            },
            .VK_DEFINE_HANDLE => {
                self.registry.addDispatchableHandle(self.dupe(name), self.allocator);
            },
        }
    }
    fn parseStructOrUnion(self: *@This(), is_struct: bool) void {
        const name = self.dupe(self.xml_iterator.nextAttr(enum { name }).?.value);
        const registry = if (is_struct)
            &self.registry.structs
        else
            &self.registry.unions;
        var comment: []u8 = &.{};
        if (self.xml_iterator.nextAttr(enum { alias, comment })) |kv| switch (kv.key) {
            .alias => {
                const gp = registry.getOrPut(self.allocator, kv.value) catch panics.oom();
                if (!gp.found_existing) {
                    gp.key_ptr.* = self.dupe(kv.value);
                    gp.value_ptr.* = .{};
                }
                gp.value_ptr.aliases = slice_tools.allocated.concat([]u8, gp.value_ptr.aliases, &.{name}, self.allocator) catch panics.oom();
                return;
            },
            .comment => {
                comment = self.dupe(kv.value);
            },
        };
        const gp = registry.getOrPut(self.allocator, name) catch panics.oom();
        const new = gp.value_ptr;
        if (!gp.found_existing) {
            new.* = .{};
        }
        new.comment = comment;
        var members: std.ArrayList(Registry.StructOrUnion.Member) = .empty;
        member_loop: while (true) switch (self.xml_iterator.seekTags(enum { member, @"/type" })) {
            .member => {
                // In some cases we read the `ptrs.buffer` elements even if `ptrs.len` == 0.
                // To avoid undefined behavior, every member needs to have this set these elements.
                var ptrs: Registry.ZigType.Ptrs = .{
                    .len = 0,
                    .buffer = @splat(.{}),
                };

                while (self.xml_iterator.nextAttr(enum { api, values, optional, len, deprecated })) |kv| switch (kv.key) {
                    .api => {
                        if (!self.api.match(kv.value)) continue :member_loop;
                    },
                    .values => {
                        members.append(self.allocator, .{
                            .comment = &.{},
                            .member = .{ .name = self.dupe("sType"), .type = .{
                                .base_type = .{ .non_primitive = self.dupe("VkStructureType") },
                                .ptrs = .{ .len = 0 },
                                .amount = .single,
                            } },
                        }) catch panics.oom();
                        new.s_type = self.dupe(kv.value);
                        _ = self.xml_iterator.seekTagAndClose(enum { @"/member" });
                        continue :member_loop;
                    },
                    .optional => {
                        var comma_it: CommaIterator = .{ .text = kv.value };
                        ptrs.len = 0;
                        while (comma_it.next()) |l| {
                            ptrs.buffer[ptrs.len].optional = std.mem.eql(u8, l, "true");
                            ptrs.len +|= 1;
                        }
                    },
                    .len => {
                        var comma_it: CommaIterator = .{ .text = kv.value };
                        ptrs.len = 0;
                        while (comma_it.next()) |l| {
                            const ptr = &ptrs.buffer[ptrs.len];
                            if (enumFromName(enum { @"null-terminated", @"1" }, l)) |t| switch (t) {
                                .@"null-terminated" => {
                                    ptr.size = .null_terminated;
                                },
                                .@"1" => {
                                    ptr.size = .single;
                                },
                            } else {
                                ptr.size = .many;
                                ptr.optional = true;
                                const member = blk: {
                                    for (members.items) |*m| {
                                        if (std.mem.eql(u8, m.member.name, l)) {
                                            break :blk m;
                                        }
                                    }
                                    continue;
                                };
                                ptr.optional = member.member.type.ptrs.buffer[0].optional;
                            }
                            ptrs.len +|= 1;
                        }
                    },
                    .deprecated => {
                        ptrs.buffer[0].optional = true;
                    },
                };

                const c_var: Registry.CVar = .parse(self.xml_iterator, self.allocator);
                const c_ptrs = &c_var.type.ptrs;
                var new_member: Registry.StructOrUnion.Member = .{
                    .member = .{ .name = c_var.name, .type = .{
                        .amount = c_var.amount,
                        .base_type = c_var.type.base_type,
                        .ptrs = ptrs,
                    } },
                    .comment = switch (self.xml_iterator.seekTagAndClose(enum { @"/member", comment })) {
                        .@"/member" => &.{},
                        .comment => self.dupe(self.xml_iterator.reader.takeDelimiter('<')),
                    },
                };
                const p = &new_member.member.type.ptrs;
                p.len = c_ptrs.len;
                for (p.slice(), c_ptrs.constSlice()) |*dst, src| {
                    dst.kind = src;
                }
                members.append(self.allocator, new_member) catch panics.oom();
            },
            .@"/type" => {
                new.members = members.toOwnedSlice(self.allocator) catch panics.oom();
                return;
            },
        };
    }
    fn parseFuncpointer(self: *@This()) void {
        _ = self.xml_iterator.seekTags(enum { proto });
        var new: Registry.Funcpointer = undefined;
        const c_var: Registry.CVar = .parse(self.xml_iterator, self.allocator);
        new.ret_type = c_var.type;
        var params: std.ArrayList(Registry.CVar) = .empty;
        while (true) switch (self.xml_iterator.seekTagAndClose(enum { param, @"/type" })) {
            .param => {
                params.append(self.allocator, .parse(self.xml_iterator, self.allocator)) catch panics.oom();
            },
            .@"/type" => {
                new.params = params.toOwnedSlice(self.allocator) catch panics.oom();
                self.registry.addFuncpointer(c_var.name, new, self.allocator);
                return;
            },
        };
    }
    fn parseEnum(self: *@This(), new_enum: *Registry.Enum) void {
        while (true) switch (self.xml_iterator.seekTags(enum { @"enum", @"/enums" })) {
            .@"enum" => {
                self.parseEnumEntry(new_enum);
            },
            .@"/enums" => return,
        };
    }
    fn parseEnumEntry(self: *@This(), new_enum: *Registry.Enum) void {
        _ = self; // autofix
        _ = new_enum; // autofix
    }
    fn parseBitmask(self: *@This(), new_bitmask: *Registry.Bitmask) void {
        while (true) switch (self.xml_iterator.seekTags(enum { @"enum", @"/enums" })) {
            .@"enum" => {
                self.parseBitmaskEntry(new_bitmask);
            },
            .@"/enums" => return,
        };
    }
    fn parseBitmaskEntry(self: *@This(), new_bitmask: *Registry.Bitmask) void {
        _ = self; // autofix
        _ = new_bitmask; // autofix
    }
    fn parseConstants(self: *@This()) void {
        while (true) switch (self.xml_iterator.seekTags(enum { @"enum", @"/enums" })) {
            .@"/enums" => return,
            .@"enum" => {
                var comment: []u8 = &.{};
                var primitive: Registry.VarType.Primitive = .u32;
                var name: []u8 = &.{};
                var value: []u8 = &.{};
                while (self.xml_iterator.nextAttr(enum { type, name, comment, value })) |kv| switch (kv.key) {
                    .type => {
                        primitive = Registry.VarType.Primitive.parse(kv.value) orelse @panic("Unknown primitive type for constant");
                    },
                    .name => {
                        name = self.dupe(kv.value);
                    },
                    .comment => {
                        comment = self.dupe(kv.value);
                    },
                    .value => {
                        value = self.dupe(kv.value);
                    },
                };
                self.registry.addConstant(
                    name,
                    .{
                        .primitive = primitive,
                        .comment = comment,
                        .value = value,
                    },
                    self.allocator,
                );
            },
        };
    }
    fn parseEnums(self: *@This()) void {
        var name: []u8 = &.{};
        const Kind = enum { @"enum", bitmask, constants };
        var kind: Kind = .@"enum";
        var comment: []u8 = &.{};
        var bits: Registry.Bitmask.Bits = .@"32";
        while (self.xml_iterator.nextAttr(enum { name, type, comment, bitwidth })) |kv| switch (kv.key) {
            .name => {
                name = self.dupe(kv.value);
            },
            .type => {
                kind = enumFromName(Kind, kv.value) orelse panic("Unknown enum type {s}", .{name});
            },
            .comment => {
                comment = self.dupe(kv.value);
            },
            .bitwidth => {
                bits = enumFromName(Registry.Bitmask.Bits, kv.value) orelse panic("Unknown bitwidth: {s}", .{kv.value});
            },
        };
        switch (kind) {
            .@"enum" => {
                const gp = self.registry.enums.getOrPut(self.allocator, name) catch panics.oom();
                if (!gp.found_existing) {
                    gp.value_ptr.* = .{
                        .comment = comment,
                    };
                }
                self.parseEnum(gp.value_ptr);
            },
            .bitmask => {
                const gp = self.registry.bitmasks.getOrPut(self.allocator, name) catch panics.oom();
                if (!gp.found_existing) {
                    gp.value_ptr.* = .{
                        .comment = comment,
                        .bits = bits,
                    };
                }
                self.parseBitmask(gp.value_ptr);
            },
            .constants => {
                self.freeDupe(name);
                self.freeDupe(comment);
                self.parseConstants();
            },
        }
    }
    fn parseCommands(self: *@This()) void {
        _ = self;
    }
    fn parseExtensions(self: *@This()) void {
        _ = self;
    }
};

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer: WriterWrapper = .{ .writer = &stdout_writer.interface };
    defer writer.flush();

    var api: Parser.Api = .vulkan;

    {
        var it = init.minimal.args.iterateAllocator(allocator) catch panics.oom();
        _ = it.next(); // program name
        while (it.next()) |o| {
            const Options = enum {
                @"-api",
            };
            const op = slice_tools.enums.fromName(Options, o) orelse std.debug.panic("Unknown option: {s}", .{o});
            switch (op) {
                .@"-api" => {
                    const a = it.next() orelse @panic("Missing api type");
                    api = slice_tools.enums.fromName(Parser.Api, a) orelse std.debug.panic("Unknown api: {s}", .{a});
                },
            }
        }
    }

    var parser: Parser = .init(&stdin_reader.interface, allocator, api);
    parser.parse();
    writer.print("{s}\n{f}", .{ @embedFile("preamble.zig"), &parser.registry });
}
