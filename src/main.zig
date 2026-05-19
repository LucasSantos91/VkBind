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
        pub fn getNode(self: @This()) XmlNode {
            return switch (self) {
                .node => |n| n,
                .text => @panic("Expected node"),
            };
        }
        pub fn getText(self: @This()) []const u8 {
            return switch (self) {
                .node => @panic("Expected text"),
                .text => |t| t,
            };
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

    pub const ChildrenIterator = struct {
        children: []const NodeOrText,

        pub fn NodeAndTag(comptime Filter: type) type {
            return struct { tag: Filter, node: XmlNode };
        }
        pub fn NodeAndTagOrText(comptime Filter: type) type {
            return union(enum) {
                node: NodeAndTag(Filter),
                text: []const u8,
            };
        }
        pub fn nextNodeOrText(self: *@This(), comptime Filter: type) ?NodeAndTagOrText(Filter) {
            while (true) {
                if (self.children.len == 0) return null;
                const this = self.children[0];
                self.children = self.children[1..];
                switch (this) {
                    .text => |t| {
                        return .{ .text = t };
                    },
                    .node => |n| {
                        const tag = enumFromName(Filter, n.tag) orelse continue;
                        return .{ .node = .{ .tag = tag, .node = n } };
                    },
                }
            }
        }

        pub fn nextNodeFilter(self: *@This(), comptime Filter: type) ?NodeAndTag(Filter) {
            while (true) {
                const n = self.nextNodeOrText(Filter) orelse return null;
                if (n == .node) return n.node;
            }
        }
        pub fn nextNode(self: *@This(), comptime tag: []const u8) ?XmlNode {
            const E = @Enum(u0, .exhaustive, &.{tag}, &.{0});
            const n = self.nextNodeFilter(E) orelse return null;
            return n.node;
        }
        pub fn nextText(self: *@This()) ?[]const u8 {
            while (true) {
                const n = self.nextNodeOrText(enum {}) orelse return null;
                return n.text;
            }
        }
    };
    pub fn childrenIterator(self: @This()) ChildrenIterator {
        return .{ .children = self.children };
    }

    pub fn getChildNodeFilter(self: @This(), comptime Filter: type) ?ChildrenIterator.NodeAndTag(Filter) {
        var it = self.childrenIterator();
        return it.nextNodeFilter(Filter);
    }
    pub fn getChildNode(self: @This(), comptime tag: []const u8) ?XmlNode {
        var it = self.childrenIterator();
        return it.nextNode(tag);
    }
    pub fn getChildText(self: @This()) ?[]const u8 {
        var it = self.childrenIterator();
        return it.nextText();
    }
};

const CommaIterator = struct {
    text: []const u8,

    pub fn next(self: *@This()) ?[]const u8 {
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
    const Api = enum {
        vulkan,
        vulkansc,

        pub fn eqlRaw(self: @This(), name: []const u8) bool {
            return std.mem.eql(u8, @tagName(self), name);
        }

        pub fn contains(self: @This(), names: []const u8) bool {
            var comma_it: CommaIterator = .{ .text = names };
            while (comma_it.next()) |name| {
                if (self.eqlRaw(name)) return true;
            }
            return false;
        }
    };
    const Field = struct {
        name: []const u8,
        comment: []const u8,
    };
    const Struct = struct {
        members: []const Field,
        s_type: ?[]const u8,
    };
    const Union = struct {
        members: []const Field,
    };
    const Handle = struct {
        dispatchable: bool,
    };
    const Enum = struct {};
    const Bitmask = struct {};
    const Basetype = struct {};
    const Foreign = struct {};
    const Funcpointer = struct {};

    const Type = union(enum) {
        @"struct": Struct,
        @"union": Union,
        handle: Handle,
        @"enum": Enum,
        bitmask: Bitmask,
        basetype: Basetype,
        foreign: Foreign,
        alias: Alias,
        funcpointer: Funcpointer,
    };
    const Alias = struct {
        canonical: []const u8,
    };
    const TypeCommon = struct {
        type: Type,
        comment: ?[]const u8 = null,
    };

    const VkTypes = std.StringHashMapUnmanaged(TypeCommon);

    api: Api,
    allocator: Allocator,
    authors: []const []const u8 = &.{},
    types: VkTypes = .{},

    fn parseAuthorTags(self: *@This(), xml: XmlNode) void {
        if (self.authors.len != 0) @panic("Duplicate tags section");
        var list: std.ArrayList([]const u8) = .empty;
        for (xml.children) |child| {
            const node = self.getNode(child) orelse continue;
            const name = node.attr.get("name") orelse @panic("Nameless author");
            list.append(self.allocator, name.*) catch @panic("oom");
        }
        self.authors = list.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseForeign(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Nameless foreign type");
        const gp = self.types.getOrPut(self.allocator, name.*) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate foreign type: {s}", .{name.*});
        gp.value_ptr.* = .{
            .type = .{ .foreign = .{} },
        };
    }
    fn matchApiText(self: *const @This(), api: []const u8) bool {
        return self.api.contains(api);
    }
    fn matchApi(self: *const @This(), xml: XmlNode) bool {
        const api = xml.attr.get("api") orelse return true;
        return self.matchApiText(api.*);
    }
    fn getNode(self: *const @This(), node_or_text: XmlNode.NodeOrText) ?XmlNode {
        if (node_or_text == .text) return null;
        const node = node_or_text.node;
        if (!self.matchApi(node)) return null;
        return node;
    }
    fn addType(self: *@This(), name: []const u8) *TypeCommon {
        const gp = self.types.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate type name: {s}", .{name});
        return gp.value_ptr;
    }
    fn forceGetChild(xml: XmlNode, comptime tag: []const u8) XmlNode {
        return xml.getChildNode(tag) orelse @panic("Expected child with tag: " ++ tag);
    }
    fn getTextInChild(xml: XmlNode, comptime tag: []const u8) []const u8 {
        const c = forceGetChild(xml, tag);
        return c.getChildText() orelse @panic("Expected text in child node");
    }

    fn parseBitmask(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseEnum(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseStruct(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseUnion(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseHandle(self: *@This(), xml: XmlNode) void {
        const kind = getTextInChild(xml, "type");
        const is_dispatchable = kind.len == "VK_DEFINE_HANDLE".len;
        const name = getTextInChild(xml, "name");
        const new = self.addType(name);
        new.* = .{ .type = .{ .handle = .{ .dispatchable = is_dispatchable } } };
    }
    fn parseFuncpointer(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseBasetype(self: *@This(), xml: XmlNode) void {
        const name = blk: for (xml.children) |n| {
            const node = self.getNode(n) orelse continue;
            if (std.mem.eql(u8, node.tag, "name")) {
                if (node.children.len != 1 and node.children[0] != .text) @panic("Failed to parse basetype name");
                break :blk node.children[0].text;
            }
        } else @panic("Failed to find basetype name");
        const gp = self.types.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate basetype type: {s}", .{name});
        gp.value_ptr.* = .{
            .type = .{ .basetype = .{} },
            .comment = null,
        };
    }
    fn getComment(xml: XmlNode) ?[]const u8 {
        const comment_ptr = xml.attr.get("comment");
        return if (comment_ptr) |c| c.* else null;
    }
    fn parseAlias(self: *@This(), alias: []const u8, xml: XmlNode) void {
        const name_ = xml.attr.get("name") orelse panic("Missing name for alias: {s}", .{alias});
        const name = name_.*;
        const gp = self.types.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate name: {s}", .{name});
        const v = gp.value_ptr;
        v.* = .{
            .type = .{
                .alias = .{
                    .canonical = alias,
                },
            },
            .comment = getComment(xml),
        };
    }
    fn parseTypes(self: *@This(), xml: XmlNode) void {
        for (xml.children) |child| {
            const node = self.getNode(child) orelse continue;
            if (!std.mem.eql(u8, node.tag, "type")) continue;
            if (node.attr.get("alias")) |alias| {
                self.parseAlias(alias.*, node);
                continue;
            }
            if (node.attr.get("category")) |category| {
                const c = enumFromName(enum { tags, bitmask, @"enum", @"struct", @"union", handle, basetype, funcpointer }, category.*) orelse continue;
                switch (c) {
                    .bitmask => self.parseBitmask(node),
                    .@"enum" => self.parseEnum(node),
                    .@"struct" => self.parseStruct(node),
                    .@"union" => self.parseUnion(node),
                    .handle => self.parseHandle(node),
                    .basetype => self.parseBasetype(node),
                    .tags => self.parseAuthorTags(node),
                    .funcpointer => self.parseFuncpointer(node),
                }
            } else {
                self.parseForeign(node);
            }
        }
    }

    pub fn parse(api: Api, xml: XmlNode, allocator: Allocator) @This() {
        var self: @This() = .{ .api = api, .allocator = allocator };
        if (!std.mem.eql(u8, xml.tag, "registry")) @panic("Missing registry");

        for (xml.children) |child| {
            const node = self.getNode(child) orelse continue;
            const tag = enumFromName(enum { types, enums, commands, feature, extensions, tags }, node.tag) orelse continue;
            switch (tag) {
                .types => self.parseTypes(node),
                .enums => self.parseEnums(node),
                .commands => self.parseCommands(node),
                .feature => self.parseFeature(node),
                .extensions => self.parseExtensions(node),
                .tags => self.parseAuthorTags(node),
            }
        }

        return self;
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

const render = struct {
    const Primitives = enum {
        void,
        char,
        float,
        double,
        int8_t,
        uint8_t,
        int16_t,
        uint16_t,
        uint32_t,
        uint64_t,
        int32_t,
        int64_t,
        size_t,
        int,

        pub fn toZig(self: @This()) []const u8 {
            return switch (self) {
                .void => "void",
                .char => "u8",
                .float => "f32",
                .double => "f64",
                .int8_t => "i8",
                .uint8_t => "u8",
                .int16_t => "i16",
                .uint16_t => "u16",
                .uint32_t => "u32",
                .uint64_t => "u64",
                .int32_t => "i32",
                .int64_t => "i64",
                .size_t => "usize",
                .int => "c_int",
            };
        }
    };
    fn stripPrefix(name: []const u8, prefix: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, name, prefix)) panic("Expected {s} to start with prefix {s}", .{ name, prefix });
        return name[prefix.len..];
    }
    fn printComment(comment_: ?[]const u8, writer: *Writer) Writer.Error!void {
        if (comment_ == null) return;
        const prefix = "// ";
        var text = comment_.?;
        if (std.mem.startsWith(u8, text, prefix)) {
            text = text[prefix.len..];
        }
        try writer.print("\n/// {s}\n", .{text});
    }
    fn printBitmask(name: []const u8, e: Registry.Bitmask, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printEnum(name: []const u8, e: Registry.Enum, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printStruct(name: []const u8, e: Registry.Struct, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printUnion(name: []const u8, e: Registry.Union, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printHandle(name: []const u8, e: Registry.Handle, writer: *Writer) Writer.Error!void {
        try writer.print("pub const {s}=enum({s}){{null_handle,_}};", .{
            stripPrefix(name, "Vk"),
            if (e.dispatchable) "usize" else "u64",
        });
    }
    fn printBasetype(name: []const u8, e: Registry.Basetype, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printForeign(name: []const u8, e: Registry.Foreign, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printFuncpointer(name: []const u8, e: Registry.Funcpointer, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printAlias(name: []const u8, e: Registry.Alias, writer: *Writer) Writer.Error!void {
        const prefix = "Vk";
        const n = stripPrefix(name, prefix);
        const c = stripPrefix(e.canonical, prefix);
        try writer.print("pub const {s}={s};", .{ n, c });
    }
    pub fn render(registry: Registry, writer: *Writer) Writer.Error!void {
        try writer.print("{s}\n", .{@embedFile("preamble.zig")});
        var it = registry.types.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            try printComment(v.comment, writer);
            switch (v.type) {
                .bitmask => |e| try printBitmask(name, e, writer),
                .@"enum" => |e| try printEnum(name, e, writer),
                .@"struct" => |e| try printStruct(name, e, writer),
                .@"union" => |e| try printUnion(name, e, writer),
                .handle => |e| try printHandle(name, e, writer),
                .basetype => |e| try printBasetype(name, e, writer),
                .funcpointer => |e| try printFuncpointer(name, e, writer),
                .foreign => |e| try printForeign(name, e, writer),
                .alias => |e| try printAlias(name, e, writer),
            }
        }
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

    var api: Registry.Api = .vulkan;

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
                    api = slice_tools.enums.fromName(Registry.Api, a) orelse std.debug.panic("Unknown api: {s}", .{a});
                },
            }
        }
    }

    const registry = Registry.parse(api, xml, allocator);
    try render.render(registry, writer);

    try writer.flush();
}
