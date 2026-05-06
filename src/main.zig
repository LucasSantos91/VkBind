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
        var text: []u8 = undefined;
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
        success: []u8,
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
    pub fn getAttrValue(self: @This()) []u8 {
        _ = self.reader.discardDelimiterInclusive('"') catch |e| panicRead(e);
        return self.reader.takeDelimiter('"') catch |e| panicTakeDel(e) orelse panicUnexpectedEnd();
    }

    pub fn nextAttr(self: @This(), comptime KeysOfInterest: type) union(enum) {
        const Success = struct {
            key: KeysOfInterest,
            value: []u8,
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
    pub fn getNextBetweenTags(self: @This()) []u8 {
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

    pub fn toZig(self: @This()) []const u8 {
        return switch (self) {
            .VkFlags => "u32",
            .VkFlags64 => "u64",
        };
    }
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
            addToFlags(flags, stripVkPrefix(name), bits);
            iterator.discardElement();
        },
    }
}

fn writeToLower(writer: *Writer, text: []const u8) void {
    for (text) |c| writer.writeByte(std.ascii.toLower(c)) catch panicWrite();
}
fn trimComment(comment: []const u8) []const u8 {
    const start_of_comment = std.mem.findNone(u8, comment, "/ ") orelse
        // Empty comment?
        return &.{};
    return comment[start_of_comment..];
}
fn printComment(comment: []const u8, writer: *Writer) void {
    const c = trimComment(comment);
    if (c.len != 0) {
        writer.print("\n/// {s}\n", .{c}) catch panicWrite();
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
fn parseStructOrUnion(iterator: XmlIterator, is_struct: bool, writer: *Writer, api: Api) void {
    const name_attr = (iterator.nextAttr(enum { name }));
    if (name_attr == .close) @panic("Nameless struct");
    const name = dupe(stripVkPrefix(name_attr.success.value));
    var alias: []const u8 = &.{};

    while (true) {
        switch (iterator.nextAttr(enum { alias, comment })) {
            .success => |kv| switch (kv.key) {
                .alias => {
                    alias = dupe(stripVkPrefix(kv.value));
                },
                .comment => {
                    printComment(kv.value, writer);
                }
            },
            .close => {
                break;
            },
        }
    }
    if (alias.len != 0) {
        writer.print("pub const {s}={s};", .{ name, alias }) catch panicWrite();
        freeDupe(alias);
        freeDupe(name);
        return;
    }

    writer.print("pub const {s}=extern {s}{{", .{ name, if (is_struct) "struct" else "union" }) catch panicWrite();
    freeDupe(name);
    var in_packed_member = false;
    var packed_count: usize = 0;
    member_loop: while (iterator.seekTags(enum { member, @"/type" })) |t| switch (t) {
        .@"/type" => break,
        .member => {
            var optional: bool = false;
            var len: ZigType.Size = .single;
            while (true) {
                switch (iterator.nextAttr(enum { api, values, optional, len, comment })) {
                    .success => |kv| switch (kv.key) {
                        .api => {
                            if (!api.match(kv.value)) {
                                _ = iterator.seekTagAndClose(enum { @"/member" });
                                continue :member_loop;
                            }
                        },
                        .values => {
                            writer.writeAll("sType: StructureType=.") catch panicWrite();
                            const trimmed = slice_tools.safeSubslice(kv.value, "VK_STRUCTURE_TYPE_".len, .unlimited) catch
                                std.debug.panic("Structure type has name too short: {s}", .{kv.value});
                            writeToLower(writer, trimmed);
                            writer.writeByte(',') catch panicWrite();
                            _ = iterator.seekTagAndClose(enum { @"/member" });
                            continue :member_loop;
                        },
                        .optional => {
                            optional = true;
                        },
                        .len => {
                            len = if (std.mem.eql(u8, kv.value, "null-terminated"))
                                .null_terminated
                            else
                                .many;
                        },
                        .comment => {
                            printComment(kv.value, writer);
                        },
                    },
                    .close => |c| {
                        if (c == .@"/>") std.debug.panic("Unexpected end to type: {s}", .{name});
                        break;
                    },
                }
            }
            const c_member = CVar.parse(iterator);
            defer c_member.deinit();
            var zig_type: ZigType = .{
                .base_type = c_member.type.base_type,
                .ptrs = .{ .len = c_member.type.ptrs.len },
                .amount = c_member.amount,
            };
            while (true) {
                switch (iterator.seekTagAndClose(enum { @"/member", comment })) {
                    .comment => {
                        const comment = iterator.reader.takeDelimiter('<') catch |e|
                            panicPeekDel(e) orelse
                            panicUnexpectedEnd();
                        printComment(comment, writer);
                        iterator.closeTagRegardless();
                    },
                    .@"/member" => break,
                }
            }

            switch (zig_type.ptrs.len) {
                0 => {},
                1 => {
                    zig_type.ptrs.buffer[0] = .{
                        .optional = optional,
                        .size = len,
                        .kind = c_member.type.ptrs.buffer[0],
                    };
                },
                2 => {
                    zig_type.ptrs.buffer[0] = .{
                        .optional = false,
                        .size = .single,
                        .kind = .mutable,
                    };
                    zig_type.ptrs.buffer[1] = .{
                        .optional = optional,
                        .size = len,
                        .kind = c_member.type.ptrs.buffer[1],
                    };
                },
                else => unreachable,
            }
            if (zig_type.amount == .bitfield) {
                if (!in_packed_member) {
                    in_packed_member = true;
                    writer.print("p{}:packed struct{{", .{packed_count}) catch panicWrite();
                    packed_count += 1;
                }
            } else {
                if (in_packed_member) {
                    in_packed_member = false;
                    writer.writeAll("},") catch panicWrite();
                }
            }

            // TODO: render bitfields properly
            writer.print("{s}:{f}", .{ c_member.name, zig_type }) catch panicWrite();
            if (is_struct and optional and !in_packed_member) {
                const default_value = if (zig_type.ptrs.len != 0)
                    "null"
                else switch (zig_type.base_type) {
                    .primitive => "0",
                    .non_primitive => ".{}"
                };
                writer.print("={s}", .{default_value}) catch panicWrite();
            }
            writer.writeByte(',') catch panicWrite();
        }
    } else std.debug.panic("Unexpected end while parsing type: {s}", .{name});
    if (in_packed_member) {
        in_packed_member = false;
        writer.writeAll("},") catch panicWrite();
    }
    writer.writeAll("};") catch panicWrite();
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
fn dupe(str: anytype) @TypeOf(str) {
    return allocator.dupe(u8, str) catch panicOOM();
}
fn freeDupe(str: []const u8) void {
    allocator.free(str);
}
fn stripLen(str: []const u8, len: usize) []const u8 {
    return slice_tools.safeSubslice(str, len, .unlimited) catch
        std.debug.panic("Tried to strip {} chars, but name is too short: {s}", .{ len, str });
}
fn stripVkPrefix(str: anytype) @TypeOf(str) {
    return slice_tools.safeSubslice(str, 2, .unlimited) catch
        std.debug.panic("Tried to strip vk prefix but name is too short: {s}", .{str});
}
fn stripPfnPrefix(str: []const u8) []const u8 {
    return slice_tools.safeSubslice(str, "PFN_vk".len, .unlimited) catch
        std.debug.panic("Tried to strip PFN_vk prefix but name is too short: {s}", .{str});
}
fn stripVK_Prefix(str: []const u8) []const u8 {
    return slice_tools.safeSubslice(str, "VK_".len, .unlimited) catch
        std.debug.panic("Tried to strip VK_ prefix but name is too short: {s}", .{str});
}
fn stripVK_PrefixIfNecessary(str: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, str, "VK_"))
        str["VK_".len..]
    else
        str;
}
const PrefixKind = enum {
    none,
    vk,
    Vk,
    PFN_vk,
};
fn stripPrefix(name: []const u8) struct { PrefixKind, []const u8 } {
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.vk))) return .{ .vk, name[2..] };
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.Vk))) return .{ .Vk, name[2..] };
    if (std.mem.startsWith(u8, name, @tagName(PrefixKind.PFN_vk))) return .{ .Vk, name[@tagName(PrefixKind.PFN_vk).len..] };
    return .{ .none, name };
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
                        .@"struct", .@"union" => |k| parseStructOrUnion(it, k == .@"struct", writer, api),
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
fn writeConstant(it: XmlIterator, writer: *Writer) void {
    const t = switch (it.nextAttr(enum { type })) {
        .close => @panic("Typeless constant"),
        .success => |kv| kv.value,
    };
    const primitive = Primitive.parse(t) orelse std.debug.panic("Unknown type of constant: {s}", .{t});
    const value = switch (it.nextAttr(enum { value })) {
        .close => @panic("Constant without a value"),
        .success => |kv| kv.value,
    };
    const trimmed = std.mem.trim(u8, value, " ");
    const is_negation = std.mem.startsWith(u8, trimmed, "(~");
    const number = std.mem.trim(u8, trimmed, " ()~uUlLfF");
    const duped_number = dupe(number);
    defer freeDupe(duped_number);

    const name = switch (it.nextAttr(enum { name })) {
        .close => @panic("Nameless constant"),
        .success => |kv| kv.value,
    };
    const duped_name = dupe(stripVK_Prefix(name));
    defer freeDupe(duped_name);

    switch (it.nextAttr(enum { comment })) {
        .success => |kv| {
            printComment(kv.value, writer);
            it.closeTagRegardless();
        },
        .close => |c| if (c != .@"/>") std.debug.panic("Enum {s} has content", .{duped_name}),
    }
    writer.print("pub const {s}:{t}=", .{ duped_name, primitive }) catch panicWrite();
    if (is_negation) {
        writer.print("~@as({t},{s});", .{ primitive, duped_number }) catch panicWrite();
    } else {
        writer.print("{s};", .{duped_number}) catch panicWrite();
    }
}

fn stripPrefixAndLowerCaps(text: []const u8, prefix: []const u8) []const u8 {
    const stripped = stripEnumPrefix(text, prefix);
    return std.ascii.allocLowerString(allocator, stripped) catch panicOOM();
}
fn stripPrefixAndLowerCapsWithoutBitSuffix(text: []const u8, prefix: []const u8, has_suffix: bool) []const u8 {
    var trimmed = stripEnumPrefix(text, prefix);
    if (has_suffix) blk: {
        const under = std.mem.find(u8, trimmed, "_") orelse break :blk;
        trimmed = trimmed[under + 1 ..];
    }
    const bits = "_BIT";
    const bits_index = std.mem.findLast(u8, trimmed, bits) orelse trimmed.len;
    const first_part = trimmed[0..bits_index];
    const second_part = trimmed[@min(trimmed.len, bits_index + bits.len)..];
    const ret = allocator.alloc(u8, first_part.len + second_part.len) catch panicOOM();
    _ = std.ascii.lowerString(ret, first_part);
    _ = std.ascii.lowerString(ret[first_part.len..], second_part);
    return ret;
}

const Enum = struct {
    const Entry = struct {
        name: []const u8,
        value: []const u8,
        comment: []const u8,
        pub fn deinit(self: @This()) void {
            freeDupe(self.name);
            freeDupe(self.value);
            freeDupe(self.comment);
        }
    };
    const Entries = std.ArrayList(Entry);
    const Aliases = std.ArrayList(Entry);

    name: []const u8,
    comment: []const u8,
    entries: Entries = .empty,
    aliases: Aliases = .empty,

    pub fn deinit(self: *@This()) void {
        freeDupe(self.name);
        freeDupe(self.comment);
        for (self.entries.items) |i| i.deinit();
        self.entries.deinit(allocator);
        for (self.aliases.items) |i| i.deinit();
        self.aliases.deinit(allocator);
        self.* = undefined;
    }
};
const Enums = std.ArrayList(Enum);

fn stripEnumPrefix(new_entry: []const u8, prefix: []const u8) []const u8 {
    if (new_entry.len <= prefix.len) return new_entry;
    if (!std.mem.startsWith(u8, new_entry, "VK_")) std.debug.panic("Enum {s} does not start with VK_", .{new_entry});
    var entry_ptr = new_entry.ptr + "VK_".len;
    const entry_limit = new_entry.ptr + new_entry.len;
    var prefix_ptr = prefix.ptr;
    const prefix_limit = prefix.ptr + prefix.len;
    while (prefix_ptr != prefix_limit) {
        const e = entry_ptr[0];
        entry_ptr += 1;
        if (e == '_') continue;
        const p = prefix_ptr[0];
        prefix_ptr += 1;
        if (std.ascii.toLower(e) != std.ascii.toLower(p)) {
            entry_ptr -= 1;
            break;
        }
    } else {
        entry_ptr += 1; //Remove the `_` after the name
    }

    if (@intFromPtr(entry_ptr) > @intFromPtr(entry_limit)) std.debug.panic("Something went wrong when parsing entry {s} of flag {s}", .{ new_entry, prefix });
    return slice_tools.sliceBetween(entry_ptr, entry_limit);
}

fn parseEnum(it: XmlIterator, api: Api, new_enum: *Enum, prefix: []const u8) void {
    enum_loop: while (it.seekTags(enum { @"enum", @"/enums" })) |t| switch (t) {
        .@"enum" => {
            var new_entry: Enum.Entry = .{
                .comment = &.{},
                .name = &.{},
                .value = &.{},
            };
            var is_alias = false;
            while (true) switch (it.nextAttr(enum { value, api, name, alias, comment })) {
                .close => break,
                .success => |kv| switch (kv.key) {
                    .api => {
                        if (!api.match(kv.value)) continue :enum_loop;
                    },
                    .value => {
                        new_entry.value = dupe(kv.value);
                    },
                    .name => {
                        new_entry.name = stripPrefixAndLowerCaps(kv.value, prefix);
                    },
                    .alias => {
                        is_alias = true;
                        new_entry.value = stripPrefixAndLowerCaps(kv.value, prefix);
                        for (new_enum.entries.items) |e| if (std.mem.eql(u8, e.name, new_entry.value)) {
                            freeDupe(new_entry.value);
                            continue :enum_loop;
                        };
                    },
                    .comment => {
                        new_entry.comment = dupe(trimComment(kv.value));
                    },
                }
            };
            if (is_alias) {
                new_enum.aliases.append(allocator, new_entry) catch panicOOM();
            } else {
                new_enum.entries.append(allocator, new_entry) catch panicOOM();
            }
        },
        .@"/enums" => return,
    } else @panic("Unclosed enum");
}
const Bitmask = struct {
    const Entry = struct {
        name: []const u8,
        bitpos: u8,
        comment: []const u8,
        pub fn deinit(self: @This()) void {
            freeDupe(self.name);
            freeDupe(self.comment);
        }
    };
    const Entries = std.ArrayList(Entry);
    const Aliases = std.ArrayList(Enum.Entry);
    const Aggregates = std.ArrayList(Enum.Entry);

    name: []const u8,
    comment: []const u8,
    entries: Entries = .empty,
    aliases: Aliases = .empty,
    aggregates: Aggregates = .empty,

    pub fn deinit(self: *@This()) void {
        freeDupe(self.name);
        freeDupe(self.comment);
        for (self.entries.items) |i| i.deinit();
        self.entries.deinit(allocator);
        for (self.aliases.items) |i| i.deinit();
        self.aliases.deinit(allocator);
        for (self.aggregates.items) |i| {
            i.deinit();
        }
        self.aggregates.deinit(allocator);
        self.* = undefined;
    }
};
const Bitmasks = std.ArrayList(Bitmask);
fn parseBitmask(it: XmlIterator, api: Api, new_bitmask: *Bitmask, prefix: []const u8, has_suffix: bool) void {
    enum_loop: while (it.seekTags(enum { @"enum", @"/enums" })) |t| switch (t) {
        .@"enum" => {
            var new_entry: Bitmask.Entry = .{
                .comment = &.{},
                .name = &.{},
                .bitpos = 0,
            };
            var value: []const u8 = &.{};
            var is_alias = false;
            var is_aggregate = false;
            while (true) switch (it.nextAttr(enum { value, bitpos, api, name, comment, alias })) {
                .close => break,
                .success => |kv| switch (kv.key) {
                    .api => {
                        if (!api.match(kv.value)) continue :enum_loop;
                    },
                    .bitpos => {
                        new_entry.bitpos = std.fmt.parseInt(u8, kv.value, 10) catch
                            std.debug.panic("Failed to parse bitpos: {s}", .{kv.value});
                    },
                    .name => {
                        new_entry.name = stripPrefixAndLowerCapsWithoutBitSuffix(kv.value, prefix, has_suffix);
                    },
                    .value => {
                        is_aggregate = true;
                        value = if (std.mem.startsWith(u8, kv.value, "VK_"))
                            stripPrefixAndLowerCapsWithoutBitSuffix(kv.value, prefix, has_suffix)
                        else
                            dupe(kv.value);
                    },
                    .alias => {
                        is_alias = true;
                        value = stripPrefixAndLowerCapsWithoutBitSuffix(kv.value, prefix, has_suffix);
                        for (new_bitmask.entries.items) |e| if (std.mem.eql(u8, e.name, value)) {
                            freeDupe(value);
                            continue :enum_loop;
                        };
                    },
                    .comment => {
                        new_entry.comment = dupe(trimComment(kv.value));
                    },
                }
            };
            const enum_entry: Enum.Entry = .{
                .name = new_entry.name,
                .value = value,
                .comment = new_entry.comment,
            };
            if (is_alias) {
                new_bitmask.aliases.append(allocator, enum_entry) catch panicOOM();
            } else if (is_aggregate) {
                new_bitmask.aggregates.append(allocator, enum_entry) catch panicOOM();
            } else {
                new_bitmask.entries.append(allocator, new_entry) catch panicOOM();
            }
        },
        .@"/enums" => return,
    } else @panic("Unclosed enum");
}

fn resizeDiscarding(buffer: *[]u8, new_len: usize) void {
    if (buffer.len < new_len) {
        allocator.free(buffer.*);
        buffer.* = allocator.alloc(u8, new_len) catch panicOOM();
    }
}

fn parseEnums(it: XmlIterator, writer: *Writer, api: Api, enums: *Enums, bitmasks: *Bitmasks) void {
    const name = switch (it.nextAttr(enum { name })) {
        .close => @panic("Nameless enum"),
        .success => |kv| dupe(stripVkPrefix(kv.value)),
    };

    const enum_type = switch (it.nextAttr(enum { type })) {
        .close => @panic("Typeless enum"),
        .success => |kv| slice_tools.enums.fromName(enum { constants, @"enum", bitmask }, kv.value) orelse
            std.debug.panic("unknown enum type: {s}", .{kv.value})
    };

    const comment = switch (it.nextAttr(enum { comment })) {
        .success => |kv| blk: {
            const c = dupe(trimComment(kv.value));
            it.closeTagRegardless();
            break :blk c;
        },
        .close => &.{},
    };
    const no_author = stripAuthorTag(name);

    switch (enum_type) {
        .constants => while (it.seekTags(enum { @"enum", @"/enums" })) |t| switch (t) {
            .@"enum" => writeConstant(it, writer),
            .@"/enums" => {
                it.closeTagRegardless();
                break;
            },
        } else std.debug.panic("Unclosed enum: {s}", .{name}),
        .@"enum" => {
            const new = enums.addOne(allocator) catch panicOOM();
            new.* = .{
                .name = name,
                .comment = comment,
            };
            parseEnum(it, api, new, no_author);
        },
        .bitmask => {
            const new = bitmasks.addOne(allocator) catch panicOOM();
            new.* = .{
                .name = name,
                .comment = comment,
            };
            const common = "FlagBits";
            const prefix_len = std.mem.find(u8, no_author, common) orelse std.debug.panic("Bitmask without FlagBits in name: {s}", .{name});
            const without_bits = no_author[0..prefix_len];
            const suffix = no_author[prefix_len + common.len ..];
            parseBitmask(it, api, new, without_bits, suffix.len != 0);
        },
    }
}

fn writeEnums(writer: *Writer, enums: *Enums) void {
    for (enums.items) |*i| {
        printComment(i.comment, writer);
        writer.print("pub const {s}=enum(c_int){{", .{i.name}) catch panicWrite();
        for (i.entries.items) |e| {
            printComment(e.comment, writer);
            writer.print("@\"{s}\"={s},", .{ e.name, e.value }) catch panicWrite();
        }
        for (i.aliases.items) |e| {
            printComment(e.comment, writer);
            writer.print("pub const @\"{s}\" = @This().@\"{s}\";", .{ e.name, e.value }) catch panicWrite();
        }
        writer.writeAll("};") catch panicWrite();
        i.deinit();
    }
}
fn flagsNameFromFlagBits(buffer: *[]u8, name: []const u8) []u8 {
    const flagbits_text = "FlagBits";
    const flags_text = "Flags";
    const flagbits_index = std.mem.findLast(u8, name, flagbits_text) orelse
        std.debug.panic("Bitmask: {s} has no FlagBits in its name", .{name});
    resizeDiscarding(buffer, name.len);
    @memcpy(buffer.ptr, name[0..flagbits_index]);
    const flags_start = buffer.ptr + flagbits_index;
    @memcpy(flags_start, flags_text);
    const suffix_start = flags_start + flags_text.len;
    @memcpy(suffix_start, name[flagbits_index + flagbits_text.len ..]);
    return buffer.*[0 .. name.len - (flagbits_text.len - flags_text.len)];
}
fn flagBitsNameFromFlags(buffer: *[]u8, name: []const u8) []u8 {
    const flagbits_text = "FlagBits";
    const flags_text = "Flags";
    const increase = flagbits_text.len - flags_text.len;
    const flags_index = std.mem.findLast(u8, name, flags_text) orelse
        std.debug.panic("Bitmask: {s} has no Flags in its name", .{name});
    const final_size = name.len + increase;
    resizeDiscarding(buffer, final_size);
    @memcpy(buffer.ptr, name[0..flags_index]);
    const flags_start = buffer.ptr + flags_index;
    @memcpy(flags_start, flagbits_text);
    const suffix_start = flags_start + flagbits_text.len;
    @memcpy(suffix_start, name[flags_index + flags_text.len ..]);
    return buffer.*[0..final_size];
}
fn getAuthorTagLen(text: []const u8) usize {
    var last = text.ptr + text.len;
    var count: usize = 0;
    while (last != text.ptr) {
        last -= 1;
        if (std.ascii.isUpper(last[0])) {
            count += 1;
        } else return count;
    }
    return count;
}
fn stripAuthorTag(text: []const u8) []const u8 {
    const l = getAuthorTagLen(text);
    return text[0 .. text.len - l];
}

fn writeFlagBitsFunctions(writer: *Writer, flags_name: []const u8, flag_bits_name: []const u8) void {
    writer.print(
        \\ pub const toFlags=FlagBitsMixin({[flags_name]s}, {[flag_bits_name]s}).toFlags;
        \\ pub const fromFlags=FlagBitsMixin({[flags_name]s}, {[flag_bits_name]s}).fromFlags;
        \\ pub const toInt=FlagBitsMixin({[flags_name]s}, {[flag_bits_name]s}).toInt;
        \\ pub const fromInt=FlagBitsMixin({[flags_name]s}, {[flag_bits_name]s}).fromInt;
    , .{ .flags_name = flags_name, .flag_bits_name = flag_bits_name }) catch panicWrite();
}
fn writeFlagsFunctions(writer: *Writer, flags_name: []const u8, flag_bits_name: []const u8) void {
    writer.print(
        \\ pub const merge=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).merge;
        \\ pub const intersection=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).intersection;
        \\ pub const negation=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).negation;
        \\ pub const difference=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).difference;
        \\ pub const toBit=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).toBit;
        \\ pub const fromBit=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).fromBit;
        \\ pub const set=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).set;
        \\ pub const unset=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).unset;
        \\ pub const toInt=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).toInt;
        \\ pub const fromInt=FlagsMixin({[flags_name]s}, {[flag_bits_name]s}).fromInt;
    , .{ .flags_name = flags_name, .flag_bits_name = flag_bits_name }) catch panicWrite();
}
fn writeBitmasks(writer: *Writer, bitmasks: *Bitmasks, flags: *Flags) void {
    var buffer: []u8 = &.{};
    defer allocator.free(buffer);

    for (bitmasks.items) |*i| {
        printComment(i.comment, writer);
        const lessThan = struct {
            pub fn lessThan(_: void, lhs: Bitmask.Entry, rhs: Bitmask.Entry) bool {
                return lhs.bitpos < rhs.bitpos;
            }
        }.lessThan;
        std.sort.pdq(Bitmask.Entry, i.entries.items, {}, lessThan);

        const flags_name = flagsNameFromFlagBits(&buffer, i.name);
        const kv = flags.fetchRemove(flags_name) orelse std.debug.panic("FlagBits {s} has no corresponding Flags", .{i.name});
        freeDupe(kv.key);
        const bits = kv.value;
        writer.print("pub const {s}=enum({s}){{", .{ i.name, bits.toZig() }) catch panicWrite();
        for (i.entries.items) |e| {
            printComment(e.comment, writer);
            writer.print("@\"{s}\"=1<<{},", .{ e.name, e.bitpos }) catch panicWrite();
        }
        for (i.aliases.items) |e| {
            printComment(e.comment, writer);
            writer.print("pub const @\"{s}\" = @This().@\"{s}\";", .{ e.name, e.value }) catch panicWrite();
        }
        writeFlagBitsFunctions(writer, flags_name, i.name);
        writer.writeAll("};") catch panicWrite();

        writer.print("pub const {s}=packed struct({s}){{", .{ flags_name, bits.toZig() }) catch panicWrite();
        var prev_bit: u8 = undefined;
        const rest = if (i.entries.items.len != 0) blk: {
            const e = i.entries.items[0];
            printComment(e.comment, writer);
            writer.print("@\"{s}\":bool=false,", .{e.name}) catch panicWrite();
            prev_bit = e.bitpos;
            break :blk i.entries.items[1..];
        } else i.entries.items;
        for (rest) |e| {
            const bit_diff = e.bitpos - prev_bit -| 1;
            prev_bit = e.bitpos;
            if (bit_diff > 1) {
                writer.print("_reserved_{}: u{}=undefined,", .{ e.bitpos, bit_diff }) catch panicWrite();
            }
            printComment(e.comment, writer);
            writer.print("@\"{s}\":bool=false,", .{e.name}) catch panicWrite();
        }
        for (i.aggregates.items) |e| {
            printComment(e.comment, writer);
            writer.print("pub const @\"{s}\":@This()=@bitCast({s});", .{ e.name, e.value }) catch panicWrite();
        }
        for (i.aliases.items) |e| {
            printComment(e.comment, writer);
            writer.print("pub const @\"{s}\"=@This().{s};", .{ e.name, e.value }) catch panicWrite();
        }
        writeFlagsFunctions(writer, flags_name, i.name);
        writer.writeAll("};") catch panicWrite();
        i.deinit();
    }

    // Empty flags
    var flags_it = flags.iterator();
    while (flags_it.next()) |kv| {
        const flags_name = kv.key_ptr.*;
        const flag_bits_name = flagBitsNameFromFlags(&buffer, flags_name);
        const zig_type = kv.value_ptr.toZig();
        writer.print("pub const {s}=packed struct({s}){{", .{ flags_name, zig_type }) catch panicWrite();
        writeFlagsFunctions(writer, flags_name, flag_bits_name);
        writer.print("}};pub const {s}=enum({s}){{", .{ flag_bits_name, zig_type }) catch panicWrite();
        writeFlagBitsFunctions(writer, flags_name, flag_bits_name);
        writer.writeAll("};") catch panicWrite();
    }
}
const Command = struct {
    name: []u8,
    return_value: ZigType,
    params: []ZigVar,
    success_codes: []u8,
    error_codes: []u8,
    aliases: std.ArrayList([]u8),
};
const Commands = struct {
    const Alias = struct {
        new_name: []u8,
        alias: []u8,
    };
    base: std.ArrayList(Command) = .empty,
    instance: std.ArrayList(Command) = .empty,
    device: std.ArrayList(Command) = .empty,
    command: std.ArrayList(Command) = .empty,
};
fn parseCommands(it: XmlIterator, commands: *Commands, api: Api) void {
    var last: enum { base, instance, device, command } = .base;
    command_loop: while (it.seekTags(enum { command, @"/commands" })) |t_| switch (t_) {
        .command => {
            var successcodes: []u8 = undefined;
            var errorcodes: []u8 = undefined;
            while (true) switch (it.nextAttr(enum { api, successcodes, errorcodes, name })) {
                .success => |kv| switch (kv.key) {
                    .api => {
                        if (!api.match(kv.value)) continue :command_loop;
                    },
                    .successcodes => {
                        successcodes = dupe(kv.value);
                    },
                    .errorcodes => {
                        errorcodes = dupe(kv.value);
                    },
                    .name => {
                        // We assume aliases always directly follow what they are aliasing
                        const alias = dupe(stripVkPrefix(kv.value));
                        if (alias.len == 0) @panic("Empty alias");
                        alias[0] = std.ascii.toLower(alias[0]);
                        const list = switch (last) {
                            .base => &commands.base,
                            .instance => &commands.instance,
                            .device => &commands.device,
                            .command => &commands.command,
                        };
                        if (list.items.len == 0) std.debug.panic("Can't find what alias {s} refers to", .{alias});
                        const last_command = &list.items[0];
                        last_command.aliases.append(allocator, alias) catch panicOOM();
                        continue :command_loop;
                    },
                },
                .close => {
                    break;
                },
            };

            _ = it.seekTags(enum { proto }) orelse @panic("Command without prototype");
            const proto: CVar = .parse(it);
            var params: std.ArrayList(ZigVar) = .empty;
            while (it.seekTags(enum { param, @"/command", implicitexternsyncparams })) |t| switch (t) {
                .param => {
                    var optional = false;
                    var len: ZigType.Size = .single;
                    while (true) switch (it.nextAttr(enum { optional, len })) {
                        .close => break,
                        .success => |kv| switch (kv.key) {
                            .optional => {
                                optional = true;
                            },
                            .len => {
                                len = if (std.mem.eql(u8, kv.value, "null-terminated"))
                                    .null_terminated
                                else
                                    .many;
                            },
                        }
                    };
                    const cvar: CVar = .parse(it);
                    var zigvar: ZigVar = .{
                        .name = cvar.name,
                        .type = .{
                            .base_type = cvar.type.base_type,
                            .amount = cvar.amount,
                            .ptrs = .{
                                .len = cvar.type.ptrs.len,
                            },
                        },
                    };
                    switch (zigvar.type.ptrs.len) {
                        0 => {},
                        1 => {
                            zigvar.type.ptrs.buffer[0] = .{
                                .optional = optional,
                                .size = len,
                                .kind = cvar.type.ptrs.buffer[0],
                            };
                        },
                        2 => {
                            zigvar.type.ptrs.buffer[0] = .{
                                .optional = false,
                                .size = .single,
                                .kind = .mutable,
                            };
                            zigvar.type.ptrs.buffer[1] = .{
                                .optional = optional,
                                .size = len,
                                .kind = cvar.type.ptrs.buffer[1],
                            };
                        },
                        else => unreachable,
                    }
                    params.append(allocator, zigvar) catch panicOOM();
                },
                .implicitexternsyncparams => {
                    _ = it.seekTagAndClose(enum { @"/implicitexternsyncparams" });
                },
                .@"/command" => break,
            } else @panic("Unclosed command");
            const command: Command = .{
                .name = proto.name,
                .return_value = .{
                    .base_type = proto.type.base_type,
                    .amount = proto.amount,
                    .ptrs = .{
                        .len = proto.type.ptrs.len,
                    },
                },
                .params = params.toOwnedSlice(allocator) catch panicOOM(),
                .success_codes = successcodes,
                .error_codes = errorcodes,
                .aliases = .empty,
            };
            if (command.params.len != 0 and command.params[0].type.base_type == .non_primitive) blk: {
                const dispatch = slice_tools.enums.fromName(
                    enum { VkInstance, VkDevice, VkCommandBuffer },
                    command.params[0].type.base_type.non_primitive,
                ) orelse break :blk;
                const list = l: switch (dispatch) {
                    .VkInstance => {
                        last = .instance;
                        break :l &commands.instance;
                    },
                    .VkDevice => {
                        last = .device;
                        break :l &commands.device;
                    },
                    .VkCommandBuffer => {
                        last = .command;
                        break :l &commands.command;
                    },
                };
                list.append(allocator, command) catch panicOOM();
                continue :command_loop;
            }
            commands.base.append(allocator, command) catch panicOOM();
            last = .base;
        },
        .@"/commands" => return,
    };
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
                    .none, .Vk => writer.writeAll(stripped) catch panicWrite(),
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
    const max_ptr_layer = 2;

    ptrs: slice_tools.BoundedArray(Kind, max_ptr_layer) = .{},
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
        const is_const = std.mem.startsWith(u8, trimmed_text, "const");
        if (is_const) {
            result.ptrs.buffer[0] = .@"const";
            result.ptrs.len = 1;
        }
        const c_type = it.getNextBetweenTags();
        result.base_type = .parse(c_type);
        it.closeTagRegardless();
        if (is_const) {
            _ = it.reader.discardDelimiterInclusive('*') catch |e| panicRead(e);
        }
        while (true) {
            const b = it.reader.peekByte() catch |e| panicRead(e);
            sw: switch (b) {
                '<' => break,
                ' ' => {
                    it.reader.toss(1);
                },
                '*' => {
                    result.ptrs.appendAssumeCapacity(.mutable);
                    if (result.ptrs.len == CType.max_ptr_layer) {
                        _ = it.reader.discardDelimiterExclusive('<') catch panicReadFailed();
                        break;
                    }
                    continue :sw ' ';
                },
                'c' => {
                    result.ptrs.appendAssumeCapacity(.@"const");
                    _ = it.reader.discardDelimiterExclusive('<') catch panicReadFailed();
                    break;
                },
                else => {
                    std.debug.panic("Unexpected byte when parsing type: {c}", .{b});
                },
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

        fn initArray(text: []u8) @This() {
            return .{ .array = dupe(text) };
        }
        fn initBitfield(text: []u8) @This() {
            return .{ .bitfield = dupe(text) };
        }
        pub fn deinit(self: @This()) void {
            switch (self) {
                .array, .bitfield => |a| freeDupe(a),
                .single => {},
            }
        }
    };
    type: CType,
    name: []u8,
    amount: Amount,

    fn parse(it: XmlIterator) @This() {
        var result: CVar = undefined;
        result.type = .parse(it);
        result.name = dupe(it.getNextBetweenTags());
        it.closeTagRegardless();
        while (true) {
            const b = it.reader.peekByte() catch |e| panicRead(e);
            switch (b) {
                ' ' => it.reader.toss(1),
                '<' => {
                    result.amount = .single;
                    return result;
                },
                '[' => {
                    it.reader.toss(1);
                    var amount = it.reader.takeDelimiter(']') catch |e|
                        panicTakeDel(e) orelse
                        @panic("Missing ']' in array");
                    if (std.mem.findScalar(u8, amount, '>')) |enum_start| {
                        amount = slice_tools.safeSubslice(amount, enum_start + 1, .unlimited) catch @panic("Malformed array size");
                        const enum_end = std.mem.findScalar(u8, amount, '<') orelse @panic("Unclosed enum in array amount");
                        result.amount = .initArray(amount[0..enum_end]);
                    } else {
                        result.amount = .initArray(amount);
                    }
                    return result;
                },
                ':' => {
                    it.reader.toss(1);
                    const amount = it.reader.takeDelimiterExclusive('<') catch |e|
                        panicPeekDel(e);
                    result.amount = .initBitfield(amount);
                    return result;
                },
                else => std.debug.panic("Unexpected byte when parsing type: {c}", .{b}),
            }
        }

        return result;
    }
    fn deinit(self: *const @This()) void {
        freeDupe(self.name);
        self.type.deinit();
        self.amount.deinit();
    }
    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        switch (self.amount) {
            .array => |amount| writer.print("{s}:[{s}]{f}", .{
                self.name,
                stripVK_PrefixIfNecessary(amount),
                self.type,
            }) catch panicWrite(),
            .bitfield => |amount| {
                writer.print("{s}:u{s}", .{ self.name, amount }) catch panicWrite();
            },
            .single => writer.print("{s}:{f}", .{ self.name, self.type }) catch panicWrite(),
        }
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

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            writer.print(
                "{s}{s}{s}",
                .{
                    if (self.optional) "?" else "",
                    switch (self.size) {
                        .single => "*",
                        .many => "[*]",
                        .null_terminated => "[*:0]",
                    },
                    if (self.kind == .@"const") "const" else "",
                },
            ) catch panicWrite();
        }
    };

    ptrs: slice_tools.BoundedArray(Ptr, 2) = .{},
    base_type: VarType,
    amount: CVar.Amount,

    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        for (self.ptrs.constSlice()) |p| {
            writer.print("{f} ", .{p}) catch panicWrite();
        }
        if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive == .void) {
            const last_ptr = self.ptrs.buffer[self.ptrs.len - 1];
            writer.writeAll(if (last_ptr.size == .many) "u8" else "anyopaque") catch panicWrite();
        } else switch (self.amount) {
            .array => |amount| writer.print("[{s}]{f}", .{ stripVK_PrefixIfNecessary(amount), self.base_type }) catch panicWrite(),
            .bitfield => |amount| writer.print("u{s}", .{stripVK_PrefixIfNecessary(amount)}) catch panicWrite(),
            .single => writer.print("{f}", .{self.base_type}) catch panicWrite(),
        }
    }

    pub fn deinit(self: *@This()) void {
        self.base_type.deinit();
        self.amount.deinit();
    }
};
const ZigVar = struct {
    name: []const u8,
    type: ZigType,
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
    writer.writeAll(@embedFile("preamble.zig")) catch panicWrite();

    const it: XmlIterator = .{ .reader = &stdin_reader.interface };
    // Skip the <?...?>
    if (!it.goToTag()) @panic("Malformed xml");
    if (it.seekTags(enum { registry })) |_| {
        _ = it.closeTag();
    } else @panic("Failed to find registry");

    var flags: Flags = .empty;
    defer flags.deinit(allocator);
    var enums: Enums = .empty;
    defer enums.deinit(allocator);
    var bitmasks: Bitmasks = .empty;
    defer bitmasks.deinit(allocator);
    var commands: Commands = .{};
    while (it.seekTags(enum { types, enums, commands, extensions, @"/registry" })) |tag| switch (tag) {
        .types => parseTypes(it, &flags, writer, api),
        .enums => parseEnums(it, writer, api, &enums, &bitmasks),
        .commands => parseCommands(it, &commands, api),
        .extensions => parseExtensions(it),
        .@"/registry" => break,
    };

    writeEnums(writer, &enums);
    writeBitmasks(writer, &bitmasks, &flags);

    for (commands.base.items) |i| {
        std.debug.print("{s}\n", .{i.name});
    }
}
