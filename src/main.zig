const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const slice_tools = @import("slice_tools");

pub fn defaultPanic() noreturn {
    @panic("Oops, something went wrong");
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
            const b = self.reader.takeByte() catch defaultPanic();
            if (b == '/') {
                _ = self.reader.discardDelimiterInclusive('>') catch defaultPanic();
                level -= 1;
                if (level == 0) return;
            } else {
                while (true) {
                    const c = self.reader.takeByte() catch defaultPanic();
                    switch (c) {
                        '/' => {
                            const d = self.reader.takeByte() catch defaultPanic();
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
            Reader.Error.ReadFailed => defaultPanic(),
        };
        return true;
    }
    pub fn closeTag(self: @This()) ClosingTag {
        while (true) {
            const b = self.reader.takeByte() catch defaultPanic();
            switch (b) {
                '/' => {
                    const c = self.reader.takeByte() catch defaultPanic();
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
    pub fn getTagText(self: @This()) []const u8 {
        var text: []const u8 = undefined;
        text.len = 1;
        while (true) {
            text = self.reader.peek(text.len) catch defaultPanic();
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
            const b = self.reader.peekByte() catch defaultPanic();
            switch (b) {
                ' ' => {
                    self.reader.toss(1);
                },
                '>' => {
                    self.reader.toss(1);
                    return .{ .close = .@">" };
                },
                '/' => {
                    self.reader.discardAll(2) catch defaultPanic();
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
                return .{ .success = self.reader.takeDelimiter('=') catch defaultPanic() orelse defaultPanic() };
            },
            .close => |c| return .{ .close = c }
        }
    }
    pub fn discardAttrValue(self: @This()) void {
        for (0..2) |_| {
            _ = self.reader.discardDelimiterInclusive('"') catch defaultPanic();
        }
    }
    pub fn getAttrValue(self: @This()) []const u8 {
        _ = self.reader.discardDelimiterInclusive('"') catch defaultPanic();
        return self.reader.takeDelimiter('"') catch defaultPanic() orelse defaultPanic();
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
        if (!self.goToTag()) defaultPanic();
        if (self.closeTag() != .@">") defaultPanic();
        return self.reader.takeDelimiter('<') catch defaultPanic() orelse defaultPanic();
    }
};

fn writeAlias(new_name: []const u8, alias: []const u8, writer: *Writer) void {
    writer.print("pub const {s} = {s};", .{ new_name, alias }) catch defaultPanic();
}

const Flag = struct {
    const Bits = enum {
        VkFlags,
        VkFlags64,
    };
    name: []const u8,
    bits: Bits,
};
const Flags = std.ArrayList(Flag);
fn parseFlag(flags: *Flags, iterator: XmlIterator, writer: *Writer) void {
    const Attr = enum {
        name,
        alias,
    };
    var name_buffer: slice_tools.BoundedArray(u8, 256) = .{};
    while (true) {
        switch (iterator.nextAttr(Attr)) {
            .success => |kv| switch (kv.key) {
                .name => {
                    name_buffer.appendSlice(kv.value) catch @panic("Name too long");
                },
                .alias => {
                    writeAlias(name_buffer.constSlice(), kv.value, writer);
                    if (iterator.closeTag() != .@"/>") defaultPanic();
                    return;
                },
            },
            .close => |c| {
                if (c != .@">") defaultPanic();
                const bits = iterator.getNextBetweenTags();
                const new = flags.addOne(allocator) catch panicOOM();
                new.name = dupe(name_buffer.constSlice());
                new.bits = slice_tools.enums.fromName(Flag.Bits, bits) orelse std.debug.panic("Unknown flags type: {s}", .{bits});
                return;
            },
        }
    }
}

const Categories = enum {
    bitmask,
    @"struct",
    @"union",
};
fn parseStructOrUnion(iterator: XmlIterator, category: Categories, writer: *Writer) void {
    _ = writer; // autofix
    _ = iterator;
    _ = category;
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
pub fn main(init: std.process.Init) void {
    allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch @panic("Failed to write to stdout");

    const Api = enum {
        vulkan,
        vulkansc,

        pub fn match(current: @This(), other: ?[]const u8) bool {
            var o = other orelse return true;
            while (true) {
                const comma = std.mem.find(u8, o, ",");
                const this = if (comma) |i| o[0..i] else o;
                const a = slice_tools.enums.fromName(@This(), this) orelse @panic("Unknown api");
                if (current == a) return true;
                if (comma) |i| {
                    o = o[i..];
                } else return false;
            }
        }
    };
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
    //writer.writeAll(@embedFile("preamble.zig")) catch panicWriteFailed();

    const it: XmlIterator = .{ .reader = &stdin_reader.interface };
    // Skip the <?...?>
    if (!it.goToTag()) @panic("Malformed xml");

    const Tags = enum {
        type,
    };
    var flags: std.ArrayList(Flag) = .empty;
    while (it.seekTags(Tags)) |tag| {
        switch (tag) {
            .type => {
                const Attr = enum {
                    api,
                    category,
                };
                while (true) {
                    attr_sw: switch (it.nextAttr(Attr)) {
                        .success => |kv| switch (kv.key) {
                            .api => {
                                if (api.match(kv.value)) continue;
                                continue :attr_sw .{ .close = it.closeTag() };
                            },
                            .category => {
                                const category = slice_tools.enums.fromName(Categories, kv.value) orelse {
                                    continue :attr_sw .{ .close = it.closeTag() };
                                };
                                switch (category) {
                                    .bitmask => parseFlag(&flags, it, writer),
                                    .@"struct", .@"union" => |k| parseStructOrUnion(it, k, writer),
                                }
                            },
                        },
                        .close => |c| {
                            handleClose(c, it);
                            break;
                        },
                    }
                }
            },
        }
    }
}
