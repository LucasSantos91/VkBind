const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const panic = std.debug.panic;
const slice_tools = @import("slice_tools");
const enumFromName = slice_tools.enums.fromName;

fn ShortMap(comptime Key: type, comptime Value: type, comptime Eql: type) type {
    return struct {
        const KeyValuePair = struct {
            key: Key,
            value: Value,
        };
        kv: []KeyValuePair = &.{},
        eql: Eql,

        pub fn add(self: *@This(), kv: KeyValuePair, allocator: Allocator) Allocator.Error!void {
            self.kv = try slice_tools.allocated.concat(KeyValuePair, self.kv, &.{kv}, allocator);
        }
        pub fn get(self: @This(), key: Key) ?*Value {
            for (self.kv) |*this| {
                if (self.eql.eql(key, this.key)) {
                    return &this.value;
                }
            }
            return null;
        }
        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.kv);
        }
    };
}

const XmlNode = struct {
    const Eql = struct {
        pub fn eql(_: @This(), lhs: []const u8, rhs: []const u8) bool {
            return std.mem.eql(u8, lhs, rhs);
        }
    };
    const Attr = ShortMap([]const u8, []const u8, Eql);
    const NodeOrText = union(enum) {
        node: XmlNode,
        text: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            switch (self) {
                .node => |x| x.deinit(allocator),
                .text => |t| allocator.free(t),
            }
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self) {
                .node => |x| try writer.print("{f}\n", .{x}),
                .text => |t| try writer.print("{s}\n", .{t}),
            }
        }
    };

    tag: []const u8,
    attr: Attr,
    children: []NodeOrText,

    pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
        try writer.print("<{s} ", .{self.tag});
        for (self.attr.kv) |a| {
            try writer.print("{s}=\"{s}\" ", .{ a.key, a.value });
        }
        if (self.children.len == 0) {
            try writer.writeAll("/>\n");
        } else {
            try writer.writeAll(">\n");
            for (self.children) |c| {
                try writer.print("{f}", .{c});
            }
            try writer.print("</{s}>\n", .{self.tag});
        }
    }
    fn deinitAttr(attr: Attr, allocator: Allocator) void {
        for (attr.kv) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        attr.deinit(allocator);
    }
    fn allocToDelimiters(reader: *Reader, allocator: Allocator, delimiters: []const u8) error{ OutOfMemory, ReadFailed }![]const u8 {
        var w: Writer.Allocating = .init(allocator);
        errdefer w.deinit();
        const writer = &w.writer;
        while (true) {
            const slice = reader.peekGreedy(1) catch |e| switch (e) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => break,
            };
            if (std.mem.findAny(u8, slice, delimiters)) |i| {
                writer.writeAll(slice[0..i]) catch return error.OutOfMemory;
                reader.toss(i);
                break;
            } else {
                writer.writeAll(slice) catch return error.OutOfMemory;
                reader.toss(slice.len);
            }
        }
        return try w.toOwnedSlice();
    }
    fn allocToDelimiter(reader: *Reader, allocator: Allocator, delimiter: u8) error{ OutOfMemory, ReadFailed }![]const u8 {
        var w: Writer.Allocating = .init(allocator);
        _ = reader.streamDelimiter(&w.writer, delimiter) catch |e| switch (e) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => {},
        };
        return try w.toOwnedSlice();
    }
    fn discardValues(reader: *Reader, values_to_discard: []const u8) error{ReadFailed}!void {
        while (true) {
            const slice = reader.peekGreedy(1) catch |e| switch (e) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return,
            };
            if (std.mem.findNone(u8, slice, values_to_discard)) |i| {
                reader.toss(i);
                return;
            } else {
                reader.tossBuffered();
            }
        }
    }
    fn discardWhitespace(reader: *Reader) error{ReadFailed}!void {
        try discardValues(reader, &std.ascii.whitespace);
    }
    fn parseTag(reader: *Reader, allocator: Allocator) error{ OutOfMemory, ReadFailed }![]const u8 {
        return allocToDelimiters(reader, allocator, std.ascii.whitespace ++ "/>");
    }
    fn parseAttrs(reader: *Reader, allocator: Allocator) (Reader.Error || Allocator.Error)!struct { Attr, bool } {
        var result: Attr = .{ .eql = .{} };
        errdefer deinitAttr(result, allocator);
        while (true) {
            try discardWhitespace(reader);
            const b = try reader.peekByte();
            switch (b) {
                '/' => {
                    reader.toss(1);
                    try reader.discardAll(1);
                    return .{ result, true };
                },
                '>' => {
                    reader.toss(1);
                    return .{ result, false };
                },
                else => {},
            }
            const key = try allocToDelimiter(reader, allocator, '=');
            reader.toss(1);
            _ = try reader.discardDelimiterInclusive('"');
            const value = try allocToDelimiter(reader, allocator, '"');
            reader.toss(1);
            try result.add(.{ .key = key, .value = value }, allocator);
        }
    }
    fn parseChildren(reader: *Reader, allocator: Allocator) (Reader.Error || Allocator.Error)![]NodeOrText {
        var n: std.ArrayList(NodeOrText) = .empty;
        errdefer {
            for (n.items) |e| e.deinit(allocator);
            n.deinit(allocator);
        }
        while (true) {
            try discardWhitespace(reader);
            const b = reader.peekByte() catch |e| switch (e) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => break,
            };
            sw: switch (b) {
                '<' => {
                    reader.toss(1);
                    switch (try reader.peekByte()) {
                        '/' => {
                            reader.toss(1);
                            _ = try reader.discardDelimiterInclusive('>');
                            break;
                        },
                        else => {
                            try n.append(allocator, .{ .node = try .parse(reader, allocator) });
                        },
                    }
                },
                else => {
                    const text = try allocToDelimiter(reader, allocator, '<');
                    try n.append(allocator, .{ .text = text });
                    continue :sw '<';
                },
            }
        }
        return try n.toOwnedSlice(allocator);
    }

    pub fn parse(reader: *Reader, allocator: Allocator) (Reader.Error || Allocator.Error)!@This() {
        var result: @This() = undefined;
        result.tag = try parseTag(reader, allocator);
        errdefer allocator.free(result.tag);
        result.attr, const self_closed = try parseAttrs(reader, allocator);
        errdefer deinitAttr(result.attr, allocator);
        result.children = if (self_closed)
            &.{}
        else
            try parseChildren(reader, allocator);
        return result;
    }
    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.tag);
        deinitAttr(self.attr, allocator);
        for (self.children) |n| {
            n.deinit(allocator);
        }
        allocator.free(self.children);
    }
};

const CommaIterator = struct {
    text: []u8,

    pub fn next(self: *@This()) ?[]u8 {
        if (self.text.len == 0) return null;
        if (std.mem.find(u8, self.text, ",")) |comma| {
            const ret = self.text[0..comma];
            self.text = self.text[comma + 1 ..];
            return ret;
        } else {
            const ret = self.text;
            self.text = &.{};
            return ret;
        }
    }
};

pub const Registry = struct {
    const VkTypeName = struct {
        data: []const u8,

        pub fn parse(name: []const u8) @This() {
            if (name.len <= 2) panic("Name doesn't start with Vk: {s}", .{name});
            return .{ .data = name[2..] };
        }
    };
    const AuthorTag = struct {
        tag: []const u8,
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.tag);
        }
        pub fn parse(name: []const u8) @This() {
            return .{ .tag = name };
        }
    };
    const Authors = struct {
        authors: []const AuthorTag = &.{},
    };
    const ZigVar = struct {};
    const Comment = struct {};
    const Field = struct {
        member: ZigVar,
        comment: Comment,
    };
    const Struct = struct {
        name: VkTypeName,
        members: []const Field,
        s_type: ?[]const u8,
    };
    const Union = struct {
        name: VkTypeName,
        members: []const Field,
    };

    authors: Authors = .{},

    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        for (self.authors.authors) |a| {
            try writer.print("{f}\n", .{a});
        }
    }
};

pub const Parser = struct {
    const Api = enum {
        vulkan,
        vulkansc,

        pub fn eqlRaw(self: @This(), name: []const u8) bool {
            return std.mem.eql(u8, @tagName(self), name);
        }
    };
    api: Api,
    allocator: Allocator,
    authors: Registry.Authors = .{},

    fn parseAuthorTags(self: *@This(), xml: XmlNode) void {
        var list: std.ArrayList(Registry.AuthorTag) = .{
            .items = @constCast(self.authors.authors),
            .capacity = self.authors.authors.len,
        };
        for (xml.children) |c| {
            if (c == .text) continue;
            const n = c.node;
            const name = n.attr.get("name") orelse @panic("Nameless author");
            list.append(self.allocator, .parse(name.*)) catch @panic("oom");
        }
        self.authors = .{ .authors = list.toOwnedSlice(self.allocator) catch @panic("oom") };
    }
    fn parseAuthors(self: *@This(), xml: XmlNode) void {
        for (xml.children) |child| {
            if (child == .text) continue;
            const node = child.node;
            const tag = enumFromName(enum { tags }, node.tag) orelse continue;
            switch (tag) {
                .tags => self.parseAuthorTags(node),
            }
        }
    }
    fn parseTypes(self: *@This(), xml: XmlNode) void {
        _ = self; // autofix
        _ = xml; // autofix {
    }
    fn parseAllTypes(self: *@This(), xml: XmlNode) void {
        for (xml.children) |child| {
            if (child == .text) continue;
            const node = child.node;
            const tag = enumFromName(enum { types, enums, commands }, node.tag) orelse continue;
            switch (tag) {
                .types => self.parseTypes(node),
                .enums => self.parseEnums(node),
                .commands => self.parseCommands(node),
            }
        }
    }
    pub fn parse(api: Api, xml: XmlNode, allocator: Allocator) Registry {
        var self: @This() = .{ .api = api, .allocator = allocator };
        if (!std.mem.eql(u8, xml.tag, "registry")) @panic("Missing registry");
        self.parseAuthors(xml);
        self.parseAllTypes(xml);

        for (xml.children) |child| {
            if (child == .text) continue;
            const node = child.node;
            const tag = enumFromName(enum { feature, extensions }, node.tag) orelse continue;
            switch (tag) {
                .feature => self.parseFeature(node),
                .extensions => self.parseExtensions(node),
            }
        }

        return self.toRegistry();
    }

    fn toRegistry(self: *@This()) Registry {
        return .{ .authors = self.authors };
    }

    fn parseEnums(self: *@This(), xml: XmlNode) void {
        _ = self; // autofix
        _ = xml; // autofix
    }
    fn parseCommands(self: *@This(), xml: XmlNode) void {
        _ = self; // autofix
        _ = xml; // autofix
    }
    fn parseFeature(self: *@This(), xml: XmlNode) void {
        _ = self; // autofix
        _ = xml; // autofix
    }
    fn parseExtensions(self: *@This(), xml: XmlNode) void {
        _ = self; // autofix
        _ = xml; // autofix
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);
    const reader = &stdin_reader.interface;

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    _ = try reader.discardDelimiterInclusive('>');
    _ = try reader.discardDelimiterInclusive('<');
    const xml: XmlNode = try .parse(reader, allocator);
    defer xml.deinit(allocator);

    var api: Parser.Api = .vulkan;

    {
        var it = init.minimal.args.iterateAllocator(allocator) catch @panic("oom");
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

    const registry = Parser.parse(api, xml, allocator);
    try writer.print("{f}", .{registry});

    try writer.flush();
}
