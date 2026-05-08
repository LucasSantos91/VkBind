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
    pub fn peekDelimiterInclusive(self: @This(), delimiter: u8) u8 {
        return self.reader.peekDelimiterInclusive(delimiter) catch |e| panics.delimiter(e);
    }
    pub fn peekDelimiterExclusive(self: @This(), delimiter: u8) u8 {
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
        while (true) {
            const text = self.reader.peekGreedy(1);
            if (findAny(text, " >")) |i| {
                self.reader.toss(i);
                return text[0..i];
            }
            self.reader.reader.tossBuffered();
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

        bits: Bits,
        comment: []u8,
        entries: []Entry,
        aggregates: []Enum.Entry,
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
        aliases: []Entry = &.{},
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
        comment: []u8 = &.{},
        members: []ZigVar = &.{},
        aliases: [][]u8 = &.{},
    };

    const VarType = union(enum) {
        const Primitive = enum {
            void,
            u8,
            u16,
            u32,
            u64,
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
    };

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
                after_type = after_type[i..];
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
    };

    const CVar = struct {
        const Amount = union(enum) {
            array: []u8,
            bitfield: []u8,
            single,
        };
        type: CType,
        name: []u8,
        amount: Amount,

        pub fn parse(it: XmlIterator, allocator: Allocator) @This() {
            var result: @This() = .{
                .type = .parse(it, allocator),
                .name = undefined,
                .amount = undefined,
            };
            it.closeTag();
            result.name = allocator.dupe(u8, it.reader.takeDelimiter('<')) catch panics.oom();
            it.closeTag();
            var amount = it.reader.takeDelimiter('<');
            const i = findAny(amount, ":[") orelse {
                result.amount = .single;
                return result;
            };
            const char = amount[i];
            amount = amount[i + 1 ..];
            switch (char) {
                ':' => {
                    const end = findScalar(amount, '<') orelse panic("Failed to find bitfield end for {s}", .{result.name});
                    result.amount = .{ .bitfield = allocator.dupe(u8, amount[0..end]) catch panics.oom() };
                },
                '[' => {
                    if (findScalar(amount, '<')) |j| {
                        amount = amount[j..];
                        var k = findScalar(amount, '>') orelse @panic("Unclosed tag");
                        amount = amount[k..];
                        k = findScalar(amount, '<') orelse panic("Failed to find amount end for {s}", .{result.name});
                        result.amount = .{ .array = allocator.dupe(u8, amount[0..k]) catch panics.oom() };
                    } else {
                        const end = findScalar(amount, ']') orelse @panic("Unclose array");
                        result.amount = .{ .array = allocator.dupe(u8, amount[0..end]) catch panics.oom() };
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
            optional: bool,
            size: Size,
            kind: CType.Kind,
        };

        ptrs: slice_tools.BoundedArray(Ptr, 2) = .{},
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
    };
    const Funcpointer = struct {
        ret_type: CType,
        params: []CVar,
    };

    bitmasks: std.StringHashMapUnmanaged(Bitmask) = .empty,
    enums: std.StringHashMapUnmanaged(Enum) = .empty,
    funcpointers: std.StringHashMapUnmanaged(Funcpointer) = .empty,
    dispatchable_handles: std.StringHashMapUnmanaged(DispatchableHandle) = .empty,
    non_dispatchable_handles: std.StringHashMapUnmanaged(NonDispatchableHandle) = .empty,
    structs: std.StringHashMapUnmanaged(StructOrUnion) = .empty,
    unions: std.StringHashMapUnmanaged(StructOrUnion) = .empty,

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

    registry: Registry,
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
                switch (enumFromName(enum { handle, @"struct", @"union", funcpointer }, kv.value) orelse continue) {
                    .handle => self.parseHandle(),
                    .@"struct", .@"union" => |e| self.parseStructOrUnion(e == .@"struct"),
                    .funcpointer => self.parseFuncpointer(),
                }
                return;
            }
        };
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
        _ = is_struct; // autofix
        _ = self;
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
    fn parseEnums(self: *@This()) void {
        _ = self;
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
    const registry = parser.registry;
    //writer.writeAll(@embedFile("preamble.zig")) catch panics.write();
    {
        writer.writeAll("Dispatchable handles\n");
        var it = registry.dispatchable_handles.iterator();
        while (it.next()) |kv| {
            writer.print("{s}\n", .{kv.key_ptr.*});
        }
    }
    writer.writeAll("---------------------------\n");
    {
        writer.writeAll("Non dispatchable handles\n");
        var it = registry.non_dispatchable_handles.iterator();
        while (it.next()) |kv| {
            writer.print("{s}\n", .{kv.key_ptr.*});
        }
    }
    writer.writeAll("---------------------------\n");
    {
        writer.writeAll("Funcpointers\n");
        var it = registry.funcpointers.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const a = kv.value_ptr.*;
            writer.print("{s}: ", .{name});
            for (a.params) |p| {
                writer.print("{s}: {any}, ", .{ p.name, p.type.base_type });
            }
            writer.writeByte('\n');
        }
    }
}
