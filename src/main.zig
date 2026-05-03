const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const slice_tools = @import("slice_tools");

fn panicUnexpectedEnd() noreturn {
    @panic("Unexpected end of stream");
}
fn panicReadFailed() noreturn {
    @panic("Failed to read from input");
}
pub fn panicRead(e: Reader.Error) noreturn {
    switch (e) {
        Reader.Error.EndOfStream => panicUnexpectedEnd(),
        Reader.Error.ReadFailed => panicReadFailed(),
    }
}
pub fn panicTakeDel(e: error{ StreamTooLong, ReadFailed }) noreturn {
    switch (e) {
        error.StreamTooLong => @panic("Insufficient buffer for reading"),
        error.ReadFailed => panicReadFailed(),
    }
}
pub fn panicPeekDel(e: Reader.DelimiterError) noreturn {
    switch (e) {
        Reader.DelimiterError.StreamTooLong, Reader.DelimiterError.ReadFailed => panicTakeDel(@errorCast(e)),
        Reader.DelimiterError.EndOfStream => panicUnexpectedEnd(),
    }
}
pub fn panicWrite() noreturn {
    @panic("Failed to write to stdout");
}
pub fn panicOOM() noreturn {
    @panic("OOM");
}

const XmlIterator = struct {
    reader: *Reader,

    pub fn discardElement(self: @This()) void {
        var level: usize = 1;
        while (true) {
            if (!self.goToTag()) return;
            const b = self.reader.takeByte() catch |e| panicRead(e);
            if (b == '/') {
                _ = self.reader.discardDelimiterInclusive('>') catch |e| panicRead(e);
                level -= 1;
                if (level == 0) return;
            } else {
                while (true) {
                    const c = self.reader.takeByte() catch |e| panicRead(e);
                    switch (c) {
                        '/' => {
                            const d = self.reader.takeByte() catch |e| panicRead(e);
                            if (d == '>') break;
                        },
                        '>' => {
                            level += 1;
                            break;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    pub fn goToTag(self: @This()) bool {
        _ = self.reader.discardDelimiterInclusive('<') catch |e| switch (e) {
            Reader.Error.EndOfStream => return false,
            Reader.Error.ReadFailed => panicReadFailed(),
        };
        return true;
    }
    pub fn closeTag(self: @This()) ClosingTag {
        while (true) {
            const b = self.reader.takeByte() catch |e| panicRead(e);
            switch (b) {
                '/' => {
                    const c = self.reader.takeByte() catch |e| panicRead(e);
                    switch (c) {
                        '>' => return .@"/>",
                        else => {},
                    }
                },
                '>' => return .@">",
                else => {},
            }
        }
    }
    /// Closes the tag without returning the ClosingTag
    pub fn closeTagRegardless(self: @This()) void {
        _ = self.reader.discardDelimiterInclusive('>') catch |e| panicRead(e);
    }
    pub fn getTagText(self: @This()) []const u8 {
        var text: []const u8 = undefined;
        text.len = 1;
        while (true) {
            text = self.reader.peek(text.len) catch |e| panicRead(e);
            const last_index = text.len - 1;
            const ret_val = text[0..last_index];
            switch (text[last_index]) {
                '>' => {
                    self.reader.toss(last_index);
                    return ret_val;
                },
                ' ' => {
                    self.reader.toss(text.len);
                    return ret_val;
                },
                else => {
                    text.len += 1;
                },
            }
        }
    }
    pub fn seekTags(self: @This(), comptime TagsEnum: type) ?TagsEnum {
        while (true) {
            if (!self.goToTag()) return null;
            const text = self.getTagText();
            if (slice_tools.enums.fromName(TagsEnum, text)) |tag| return tag;
        }
    }
    const ClosingTag = enum {
        @">",
        @"/>",
    };
    pub fn goToAttrKey(self: @This()) union(enum) {
        sucess,
        close: ClosingTag,
    } {
        while (true) {
            const b = self.reader.peekByte() catch |e| panicRead(e);
            switch (b) {
                ' ' => {
                    self.reader.toss(1);
                },
                '>' => {
                    self.reader.toss(1);
                    return .{ .close = .@">" };
                },
                '/' => {
                    self.reader.discardAll(2) catch |e| panicRead(e);
                    return .{ .close = .@"/>" };
                },
                else => {
                    return .sucess;
                },
            }
        }
    }
    pub fn getAttrKey(self: @This()) union(enum) {
        success: []const u8,
        close: ClosingTag,
    } {
        switch (self.goToAttrKey()) {
            .sucess => {
                return .{ .success = self.reader.takeDelimiter('=') catch |e|
                    panicTakeDel(e) orelse
                    panicUnexpectedEnd() };
            },
            .close => |c| return .{ .close = c }
        }
    }
    pub fn discardAttrValue(self: @This()) void {
        for (0..2) |_| {
            _ = self.reader.discardDelimiterInclusive('"') catch |e| panicRead(e);
        }
    }
    pub fn getAttrValue(self: @This()) []const u8 {
        _ = self.reader.discardDelimiterInclusive('"') catch |e| panicRead(e);
        return self.reader.takeDelimiter('"') catch |e| panicTakeDel(e) orelse panicUnexpectedEnd();
    }

    pub fn nextAttr(self: @This(), comptime KeysOfInterest: type) union(enum) {
        const Success = struct {
            key: KeysOfInterest,
            value: []const u8,
        };
        success: Success,
        close: ClosingTag,
    } {
        while (true) {
            switch (self.getAttrKey()) {
                .success => |key| {
                    const e = slice_tools.enums.fromName(KeysOfInterest, key) orelse {
                        self.discardAttrValue();
                        continue;
                    };
                    return .{ .success = .{ .key = e, .value = self.getAttrValue() } };
                },
                .close => |c| return .{ .close = c },
            }
        }
    }
    pub fn getNextBetweenTags(self: @This()) []const u8 {
        if (!self.goToTag()) panicUnexpectedEnd();
        if (self.closeTag() != .@">") panicUnexpectedEnd();
        return self.reader.takeDelimiter('<') catch |e| panicTakeDel(e) orelse panicUnexpectedEnd();
    }

    pub fn seekTagAndClose(self: @This(), comptime Tags: type) Tags {
        const t = self.seekTags(Tags) orelse @panic("Failed to find expected tags");
        self.closeTagRegardless();
        return t;
    }
};

fn writeAlias(new_name: []const u8, alias: []const u8, writer: *Writer) void {
    writer.print("pub const {s} = {s};", .{ new_name, alias }) catch panicWrite();
}

/// Assumes file pointer is right after `name=somename`
fn handleAlias(iterator: XmlIterator, writer: *Writer, name: []const u8) void {
    const n = stripVkPrefix(name);
    writer.print("pub const {s} = ", .{n}) catch panicWrite();
    switch (iterator.nextAttr(enum { alias })) {
        .close => std.debug.panic("Expected alias for flag: {s}", .{n}),
        .success => |s| {
            const trimmed = stripVkPrefix(s.value);
            writer.print("{s};", .{trimmed}) catch panicWrite();
        },
    }
    if (iterator.closeTag() != .@"/>") @panic("Expected alias to end in '/>' when parsing flags");
}

const FlagBits = enum {
    VkFlags,
    VkFlags64,
};

const Flags = std.StringHashMapUnmanaged(FlagBits);
fn addToFlags(flags: *Flags, name: []const u8, bits: FlagBits) void {
    const gp = flags.getOrPut(allocator, dupe(name)) catch panicOOM();
    if (gp.found_existing) std.debug.panic("Duplicate flag: {s}", .{gp.key_ptr.*});
    gp.value_ptr.* = bits;
}
fn parseFlag(flags: *Flags, iterator: XmlIterator, writer: *Writer) void {
    switch (iterator.nextAttr(enum { name })) {
        .success => |kv| switch (kv.key) {
            .name => handleAlias(iterator, writer, kv.value),
        },
        .close => |c| {
            if (c != .@">") @panic("Expected '>' but got '/>' when parsing flags");
            const bits_text = iterator.getNextBetweenTags();
            const bits = slice_tools.enums.fromName(FlagBits, bits_text) orelse std.debug.panic("Unknown flags type: {s}", .{bits_text});
            const name = iterator.getNextBetweenTags();
            addToFlags(flags, name, bits);
            iterator.discardElement();
        },
    }
}

const Categories = enum {
    bitmask,
    @"struct",
    @"union",
    handle,
    @"enum",
    funcpointer,
};
fn parseStructOrUnion(iterator: XmlIterator, is_struct: bool, writer: *Writer) void {
    _ = writer; // autofix
    _ = iterator;
    _ = is_struct;
}

pub fn handleClose(c: XmlIterator.ClosingTag, iterator: XmlIterator) void {
    switch (c) {
        .@">" => {
            iterator.discardElement();
        },
        .@"/>" => {},
    }
}

var allocator: Allocator = undefined;
fn dupe(str: []const u8) []const u8 {
    return allocator.dupe(u8, str) catch panicOOM();
}
fn freeDupe(str: []const u8) void {
    allocator.free(str);
}
fn stripVkPrefix(str: []const u8) []const u8 {
    return slice_tools.safeSubslice(str, 2, .unlimited) catch
        std.debug.panic("Tried to strip vk prefix but name is too short: {s}", .{str});
}
fn stripPfnPrefix(str: []const u8) []const u8 {
    return slice_tools.safeSubslice(str, "PFN_vk".len, .unlimited) catch
        std.debug.panic("Tried to strip PFN_vk prefix but name is too short: {s}", .{str});
}
const PrefixKind = enum {
    vk,
    Vk,
    PFN_vk,
};
fn stripPrefix(name: []const u8) struct { PrefixKind, []const u8 } {
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.vk))) return .{ .vk, name[2..] };
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.Vk))) return .{ .Vk, name[2..] };
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.PFN_vk))) return .{ .Vk, name[@tagName(PrefixKind.PFN_vk).len..] };
    std.debug.panic("Name has no prefix: {s}", .{name});
}

const Api = enum {
    vulkan,
    vulkansc,

    pub fn match(current: @This(), other: ?[]const u8) bool {
        var o = other orelse return true;
        while (true) {
            const comma = std.mem.find(u8, o, ",");
            const this = if (comma) |i| o[0..i] else o;
            const a = slice_tools.enums.fromName(@This(), this) orelse std.debug.panic("Unknown api: {s}", .{this});
            if (current == a) return true;
            if (comma) |i| {
                o = o[i..];
            } else return false;
        }
    }
};
fn parseTypes(it: XmlIterator, flags: *Flags, writer: *Writer, api: Api) void {
    while (it.seekTags(enum { type, @"/types" })) |tag| switch (tag) {
        .type => while (true) attr_sw: switch (it.nextAttr(enum { api, category, name })) {
            .success => |kv| switch (kv.key) {
                .name => {
                    // If we hit name before category, this is enum. We'll handle them later, so skip it
                    it.closeTagRegardless();
                    break;
                },
                .api => {
                    if (api.match(kv.value)) continue;
                    continue :attr_sw .{ .close = it.closeTag() };
                },
                .category => {
                    const category = slice_tools.enums.fromName(Categories, kv.value) orelse {
                        continue :attr_sw .{ .close = it.closeTag() };
                    };
                    switch (category) {
                        .bitmask => parseFlag(flags, it, writer),
                        .@"struct", .@"union" => |k| parseStructOrUnion(it, k == .@"struct", writer),
                        .handle => parseHandle(it, writer),
                        .@"enum" => {
                            // If category="enum" is hit before name=, it means this is an alias
                            switch (it.nextAttr(enum { name })) {
                                .success => |kv2| handleAlias(it, writer, kv2.value),
                                .close => @panic("Unexpected closing tag when handling enum alias"),
                            }
                        },
                        .funcpointer => parseFuncPointer(it, writer),
                    }
                    break;
                },
            },
            .close => |c| {
                handleClose(c, it);
                break;
            },
        },
        .@"/types" => return,
    };
    panicUnexpectedEnd();
}
fn parseHandle(iterator: XmlIterator, writer: *Writer) void {
    switch (iterator.nextAttr(enum { name })) {
        .success => |kv| switch (kv.key) {
            .name => handleAlias(iterator, writer, kv.value),
        },
        .close => |c| {
            if (c != .@">") @panic("Expected '>' but got '/>' when parsing handle");
            const kind_text = iterator.getNextBetweenTags();
            const kind = slice_tools.enums.fromName(enum { VK_DEFINE_NON_DISPATCHABLE_HANDLE, VK_DEFINE_HANDLE }, kind_text) orelse
                std.debug.panic("Unknown handle kind: {s}", .{kind_text});
            const name = iterator.getNextBetweenTags();
            writer.print(
                "pub const {s}=enum({s}){{null_handle,_}};",
                .{
                    stripVkPrefix(name),
                    switch (kind) {
                        .VK_DEFINE_NON_DISPATCHABLE_HANDLE => "u64",
                        .VK_DEFINE_HANDLE => "usize",
                    },
                },
            ) catch panicWrite();
            iterator.discardElement();
        },
    }
}

fn parseFuncPointer(it: XmlIterator, writer: *Writer) void {
    _ = it.seekTagAndClose(enum { proto });
    const ret_type_and_name: CVar = .parse(it);
    defer ret_type_and_name.deinit();
    // The return type was duped, so it will live through peeks

    writer.print("pub const Pfn{s} = *const fn(", .{stripPfnPrefix(ret_type_and_name.name)}) catch panicWrite();
    _ = it.seekTagAndClose(enum { @"/proto" });
    while (true) {
        const t = it.seekTagAndClose(enum { param, @"/type" });
        switch (t) {
            .param => {
                const param: CVar = .parse(it);
                defer param.deinit();

                writer.print("{f},", .{param}) catch panicWrite();
            },
            .@"/type" => break,
        }
    }
    writer.print(")callconv(vk_callconv){f};", .{ret_type_and_name.type}) catch panicWrite();
}
fn parseEnums(it: XmlIterator) void {
    _ = it;
}
fn parseCommands(it: XmlIterator) void {
    _ = it;
}
fn parseExtensions(it: XmlIterator) void {
    _ = it;
}

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
        uint_16t,
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
            .uint_16t => .u16,
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
const VarType = union(enum) {
    primitive: Primitive,
    non_primitive: []const u8,

    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        switch (self.*) {
            .primitive => |p| writer.print("{t}", .{p}) catch panicWrite(),
            .non_primitive => |n| {
                const kind, const stripped = stripPrefix(n);
                switch (kind) {
                    .vk => std.debug.panic("Type starts with `vk`: {s}", .{n}),
                    .Vk => writer.writeAll(stripped) catch panicWrite(),
                    .PFN_vk => writer.print("Pfn{s}", .{stripped}) catch panicWrite(),
                }
            }
        }
    }

    pub fn parse(text: []const u8) @This() {
        return if (Primitive.parse(text)) |p|
            .{ .primitive = p }
        else
            .{ .non_primitive = dupe(text) };
    }
    pub fn deinit(self: @This()) void {
        switch (self) {
            .primitive => {},
            .non_primitive => |n| freeDupe(n),
        }
    }
};

const CType = struct {
    const Kind = enum {
        @"const",
        mutable,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            writer.writeAll("[*c]") catch panicWrite();
            if (self == .@"const") writer.writeAll("const") catch panicWrite();
        }
    };

    ptrs: slice_tools.BoundedArray(Kind, 2) = .{},
    base_type: VarType,

    pub fn deinit(self: *const @This()) void {
        self.base_type.deinit();
    }
    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        if (self.base_type == .primitive and self.base_type.primitive == .void and self.ptrs.len != 0) {
            for (self.ptrs.buffer[0..self.ptrs.len -| 1]) |p| {
                writer.print("{f} ", .{p}) catch panicWrite();
            }
            writer.print("?*{s} anyopaque", .{if (self.ptrs.buffer[0] == .@"const") "const" else ""}) catch panicWrite();
        } else {
            for (self.ptrs.constSlice()) |p| {
                writer.print("{f} ", .{p}) catch panicWrite();
            }
            writer.print("{f}", .{self.base_type}) catch panicWrite();
        }
    }

    fn parse(it: XmlIterator) @This() {
        const text = it.reader.takeDelimiterExclusive('<') catch |e| panicPeekDel(e);
        var result: CType = .{ .base_type = undefined };
        const trimmed_text = std.mem.trim(u8, text, " ");
        const is_const = std.mem.eql(u8, trimmed_text, "const");
        if (is_const) {
            result.ptrs.buffer[0] = .@"const";
            result.ptrs.len = 1;
        }
        const c_type = it.getNextBetweenTags();
        result.base_type = .parse(c_type);
        it.closeTagRegardless();
        const rest_of_type = it.reader.takeDelimiterExclusive('<') catch |e| panicPeekDel(e);
        const trimmed_type = std.mem.trim(u8, rest_of_type, " ");
        if (trimmed_type.len == 0) {
            if (is_const) @panic("Expected pointer");
            return result;
        }
        if (!is_const) result.ptrs.appendAssumeCapacity(.mutable);
        const rest_of_type_expression = slice_tools.enums.fromName(enum { @"*", @"**", @"* const*" }, trimmed_type) orelse
            std.debug.panic("Unknown pointer type: {s}", .{trimmed_text});
        switch (rest_of_type_expression) {
            .@"*" => {},
            .@"**" => {
                result.ptrs.buffer[1] = .mutable;
                result.ptrs.len = 2;
            },
            .@"* const*" => {
                result.ptrs.buffer[1] = .@"const";
                result.ptrs.len = 2;
            },
        }

        return result;
    }
};

const CVar = struct {
    type: CType,
    name: []const u8,

    fn parse(it: XmlIterator) @This() {
        var result: CVar = undefined;
        result.type = .parse(it);
        result.name = it.getNextBetweenTags();
        return result;
    }
    fn deinit(self: *const @This()) void {
        self.type.deinit();
    }
    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        writer.print("{s}: {f}", .{ self.name, self.type }) catch panicWrite();
    }
};

const ZigVar = struct {
    const Size = enum {
        single,
        many,
    };
    const Ptr = struct {
        optional: bool,
        size: Size,
        kind: CType.Kind,
    };

    ptrs: slice_tools.BoundedArray(Ptr) = .empty,
    base_type: VarType,

    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        for (self.ptrs.constSlice()) |p| {
            writer.print("{f} ", .{p}) catch panicWrite();
        }
        switch (self.base_type) {
            .primitive => |p| writer.print("{s}", .{if (self.ptrs.len != 0 and p == .void) "anyopaque" else @tagName(p)}) catch panicWrite(),
            .non_primitive => |p| writer.print("{s}", .{p}) catch panicWrite(),
        }
    }
};

pub fn main(init: std.process.Init) void {
    allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch panicWrite();

    var api: Api = .vulkan;

    {
        var it = init.minimal.args.iterateAllocator(allocator) catch panicOOM();
        _ = it.next(); // program name
        while (it.next()) |o| {
            const Options = enum {
                @"-api",
            };
            const op = slice_tools.enums.fromName(Options, o) orelse std.debug.panic("Unknown option: {s}", .{o});
            switch (op) {
                .@"-api" => {
                    const a = it.next() orelse @panic("Missing api type");
                    api = slice_tools.enums.fromName(Api, a) orelse std.debug.panic("Unknown api: {s}", .{a});
                },
            }
        }
    }
    //writer.writeAll(@embedFile("preamble.zig")) catch panicWrite();

    const it: XmlIterator = .{ .reader = &stdin_reader.interface };
    // Skip the <?...?>
    if (!it.goToTag()) @panic("Malformed xml");
    if (it.seekTags(enum { registry })) |_| {
        _ = it.closeTag();
    } else @panic("Failed to find registry");

    var flags: Flags = .empty;
    while (it.seekTags(enum { types, enums, commands, extensions, @"/registry" })) |tag| switch (tag) {
        .types => parseTypes(it, &flags, writer, api),
        .enums => parseEnums(it),
        .commands => parseCommands(it),
        .extensions => parseExtensions(it),
        .@"/registry" => break,
    };

    var f = flags.iterator();
    while (f.next()) |g| {
        std.debug.print("{s} : {t}\n", .{ g.key_ptr.*, g.value_ptr.* });
    }
}
