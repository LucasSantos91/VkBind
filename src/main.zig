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
fn stripVkPrefix(str: []const u8) []const u8 {
    return slice_tools.safeSubslice(str, 2, .unlimited) catch
        std.debug.panic("Tried to strip vk prefix but name is too short: {s}", .{str});
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
fn parseEnums(it: XmlIterator) void {
    _ = it;
}
fn parseCommands(it: XmlIterator) void {
    _ = it;
}
fn parseExtensions(it: XmlIterator) void {
    _ = it;
}

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
    while (it.seekTags(enum { types, enums, commands, extensions })) |tag| switch (tag) {
        .types => parseTypes(it, &flags, writer, api),
        .enums => parseEnums(it),
        .commands => parseCommands(it),
        .extensions => parseExtensions(it),
    };

    var f = flags.iterator();
    while (f.next()) |g| {
        std.debug.print("{s} : {t}\n", .{ g.key_ptr.*, g.value_ptr.* });
    }
}
