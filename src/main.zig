const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const panic = std.debug.panic;
const enumFromName = std.meta.stringToEnum;
const concat = std.mem.concat;

fn ShortMap(comptime Key: type, comptime Value: type, comptime Eql: type) type {
    return struct {
        const KeyValuePair = struct {
            key: Key,
            value: Value,
        };
        kv: []KeyValuePair = &.{},
        eql: Eql,

        pub fn add(self: *@This(), kv: KeyValuePair, allocator: Allocator) Allocator.Error!void {
            self.kv = try concat(allocator, KeyValuePair, &.{ self.kv, &.{kv} });
        }
        pub fn get(self: @This(), key: Key) ?Value {
            for (self.kv) |*this| {
                if (self.eql.eql(key, this.key)) {
                    return this.value;
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
            try writer.print("\n", .{self.tag});
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
                '/', '?' => {
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
                        '!' => {
                            reader.toss(1);
                            _ = try reader.discardDelimiterInclusive('>');
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
    const Struct = struct {
        members: []const ZigVar,
        s_type: ?[]const u8,
    };
    const Union = struct {
        members: []const ZigVar,
    };
    const Handle = struct {
        dispatchable: bool,
    };
    const Enum = struct {
        const Alias = struct {
            name: []const u8,
            canonical: []const u8,
            comment: ?[]const u8,
            providers: Providers,
        };
        const Value = struct {
            name: []const u8,
            value: []const u8,
            comment: ?[]const u8,
            providers: Providers,
            extension_value: bool,
        };
        values: []const Value,
        aliases: []const @This().Alias,
    };
    const Flags = struct {
        const Bitwidth = enum {
            @"32",
            @"64",

            pub fn bitSize(self: @This()) u8 {
                return switch (self) {
                    .@"32" => 32,
                    .@"64" => 64,
                };
            }
        };
        bitwidth: Bitwidth = .@"32",
        bit_flags: ?[]const u8 = null,
    };
    const FlagBits = struct {
        const Bitpos = u8;
        const Bit = struct {
            bitpos: Bitpos,
            name: []const u8,
            comment: ?[]const u8,
            providers: Providers,
            extension_bit: bool,
        };
        const Aggregate = struct {
            name: []const u8,
            comment: ?[]const u8,
            value: []const u8,
            providers: Providers,
        };
        const BitAlias = struct {
            canonical: []const u8,
            name: []const u8,
            comment: ?[]const u8,
            providers: Providers,
        };
        bitwidth: Flags.Bitwidth = .@"32",
        bits: []const Bit = &.{},
        aggregates: []const Aggregate = &.{},
        bit_aliases: []const BitAlias = &.{},
    };
    const Basetype = struct {};
    const Foreign = struct {};
    const CBaseType = struct {
        pub const max_ptr = 2;
        const PtrKind = enum {
            @"const",
            mutable,
        };
        ptrs: [max_ptr]PtrKind = undefined,
        ptrs_len: u2 = 0,
        name: []const u8,
    };
    const CType = struct {
        const ArrayAmount =
            union(enum) {
                literal: []const u8,
                constant: []const u8,
            };
        pub const Amount = union(enum) {
            single,
            array: ArrayAmount,
            bitfield: u8,
        };

        base: CBaseType,
        amount: Amount,
    };
    const CVar = struct {
        type: CType,
        name: []const u8,
        comment: ?[]const u8,

        pub fn parse(xml: XmlNode) @This() {
            var result: @This() = .{
                .type = .{
                    .amount = .single,
                    .base = .{
                        .name = undefined,
                    },
                },
                .name = undefined,
                .comment = null,
            };
            const ptrs_len = &result.type.base.ptrs_len;
            const ptrs = &result.type.base.ptrs;

            var it = xml.childrenIterator();
            const type_node = switch (it.nextNodeOrText(enum { type }) orelse @panic("Failed to find variable type")) {
                .text => |t| blk: {
                    if (std.mem.find(u8, t, "const ")) |_| {
                        ptrs.*[0] = .@"const";
                        ptrs_len.* = 1;
                    }
                    break :blk it.nextNode("type") orelse @panic("Failed to find variable type");
                },
                .node => |n| n.node,
            };
            result.type.base.name = type_node.getChildText() orelse @panic("Expected type name");

            const name_node = switch (it.nextNodeOrText(enum { name }) orelse @panic("Failed to find variable name")) {
                .text => |t| blk: {
                    var text = t;
                    if (std.mem.findScalar(u8, text, '*')) |i| {
                        if (ptrs_len.* == 0) {
                            ptrs.*[0] = .mutable;
                            ptrs_len.* = 1;
                        }
                        text = text[i + 1 ..];
                    }
                    if (std.mem.findAny(u8, text, "*c")) |i| {
                        const c = text[i];
                        ptrs.*[ptrs_len.*] = (if (c == '*') .mutable else .@"const");
                        ptrs_len.* += 1;
                    }
                    break :blk it.nextNode("name") orelse @panic("Failed to find variable name");
                },
                .node => |n| n.node,
            };
            result.name = name_node.getChildText() orelse @panic("Expected variable name");
            if (it.nextText()) |text_| blk: {
                var text = text_;
                const i = std.mem.findAny(u8, text, ":[") orelse break :blk;
                const c = text[i];
                text = text[i + 1 ..];
                switch (c) {
                    ':' => {
                        text = std.mem.trim(u8, text, " ");
                        result.type.amount = .{ .bitfield = std.fmt.parseInt(u8, text, 10) catch panic("Failed to parse bitfield width: {s}", .{text}) };
                    },
                    '[' => {
                        if (std.mem.findScalar(u8, text, ']')) |j| {
                            result.type.amount = .{ .array = .{ .literal = text[0..j] } };
                        } else {
                            const enum_node = it.nextNode("enum") orelse @panic("Failed to find array amount enumeration");
                            const n = enum_node.getChildText() orelse @panic("Expected constant name in array amount");
                            result.type.amount = .{ .array = .{ .constant = n } };
                        }
                    },
                    else => unreachable,
                }
            }
            const comment_node = xml.getChildNode("comment") orelse return result;
            result.comment = comment_node.getChildText();
            return result;
        }
    };

    const ZigVar = struct {
        const Len = union(enum) {
            @"1",
            @"null-terminated",
            expression: []const u8,

            pub fn parse(text: []const u8) @This() {
                return if (enumFromName(enum { @"1", @"null-terminated" }, text)) |e| switch (e) {
                    .@"1" => .@"1",
                    .@"null-terminated" => .@"null-terminated",
                } else .{ .expression = text };
            }
        };
        const Ptr = struct {
            optional: bool,
            len: Len,
        };

        c_var: CVar,
        extra: [CBaseType.max_ptr]Ptr,

        pub fn parse(xml: XmlNode) @This() {
            var result: @This() = .{
                .c_var = .parse(xml),
                .extra = @splat(.{ .optional = false, .len = .@"1" }),
            };
            if (xml.attr.get("optional")) |opt| {
                var it: CommaIterator = .{ .text = opt };
                for (&result.extra) |*e| {
                    if (it.next()) |text| {
                        e.optional = std.mem.eql(u8, text, "true");
                    } else break;
                }
            }
            if (xml.attr.get("altlen") orelse xml.attr.get("len")) |len| {
                var it: CommaIterator = .{ .text = len };
                for (&result.extra) |*e| {
                    if (it.next()) |text| {
                        e.len = .parse(text);
                    } else break;
                }
            }
            if (xml.attr.get("deprecated")) |_| {
                result.extra[0].optional = true;
            }
            return result;
        }
    };

    const Funcpointer = struct {
        ret: CBaseType,
        params: []const ZigVar,
    };
    const Command = struct {
        ret: CBaseType,
        params: []const ZigVar,
        success_codes: []const u8,
        error_codes: []const u8,
        providers: Providers = .{},
    };
    const VkVersionName = struct {
        number: []const u8 = &.{},
        pub fn parse(number: []const u8) @This() {
            return .{ .number = number };
        }
    };
    const ExtensionName = struct {
        name: []const u8 = &.{},
        pub fn parse(name: []const u8) @This() {
            return .{ .name = name };
        }
    };
    const Extension = struct {
        name: ExtensionName,
        kind: Kind,
        promoted: ?[]const u8,
        depends: ?[]const u8,

        pub const Kind = enum {
            device,
            instance,

            pub fn parse(text: []const u8) @This() {
                return enumFromName(@This(), text) orelse panic("Unknown extension type: {s}", .{text});
            }
        };
    };
    const VkVersion = struct {
        name: VkVersionName,
    };
    const Providers = struct {
        version: ?VkVersionName = null,
        extensions: []const ExtensionName = &.{},

        pub fn addFeature(self: *@This(), version: VkVersionName) void {
            self.version = version;
        }
        pub fn addExtension(self: *@This(), extension: ExtensionName, allocator: Allocator) void {
            self.extensions = concat(allocator, ExtensionName, &.{ @constCast(self.extensions), &.{extension} }) catch @panic("oom");
        }
        pub const Provider = union(enum) {
            version: VkVersionName,
            extension: ExtensionName,

            pub fn toProviders(self: @This(), allocator: Allocator) Providers {
                return switch (self) {
                    .version => |f| .{ .version = f },
                    .extension => |e| {
                        const a = allocator.alloc(ExtensionName, 1) catch @panic("oom");
                        a[0] = e;
                        return .{ .extensions = a };
                    },
                };
            }
            pub fn parseVersion(version: VkVersionName) @This() {
                return .{ .version = version };
            }
            pub fn parseExtension(ext: ExtensionName) @This() {
                return .{ .extension = ext };
            }
        };
        pub fn add(self: *@This(), provider: Provider, allocator: Allocator) void {
            switch (provider) {
                .version => |f| self.addFeature(f),
                .extension => |e| self.addExtension(e, allocator),
            }
        }
    };

    const Type = union(enum) {
        @"struct": Struct,
        @"union": Union,
        handle: Handle,
        @"enum": Enum,
        flags: Flags,
        flag_bits: FlagBits,
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
        providers: Providers = .{},
    };

    const VkTypes = std.StringHashMapUnmanaged(TypeCommon);
    const Commands = std.StringHashMapUnmanaged(Command);
    const Constant = struct {
        value: []const u8,
        type: []const u8,
        comment: ?[]const u8,
        providers: Providers = .{},
    };
    const Constants = std.StringHashMapUnmanaged(Constant);

    api: Api,
    allocator: Allocator,
    authors: []const []const u8 = &.{},
    types: VkTypes = .{},
    constants: Constants = .{},
    commands: Commands = .{},
    versions: []const VkVersion = &.{},
    extensions: []const Extension = &.{},

    fn parseAuthorTags(self: *@This(), xml: XmlNode) void {
        if (self.authors.len != 0) @panic("Duplicate tags section");
        var list: std.ArrayList([]const u8) = .{
            .items = @constCast(self.authors),
            .capacity = self.authors.len,
        };
        for (xml.children) |child| {
            const node = if (child == .node) child.node else continue;
            const name = node.attr.get("name") orelse @panic("Nameless author");
            list.append(self.allocator, name) catch @panic("oom");
        }
        self.authors = list.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseForeign(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    pub fn resolveAlias(self: *const @This(), name: []const u8) TypeCommon {
        var t = self.types.get(name) orelse panic("Failed to find name {s}", .{name});
        while (t.type == .alias) {
            t = self.types.get(t.type.alias.canonical) orelse panic("Failed to find name {s}", .{t.type.alias.canonical});
        }
        return t;
    }
    fn matchApiText(self: *const @This(), api: []const u8) bool {
        return self.api.contains(api);
    }
    fn matchApi(self: *const @This(), xml: XmlNode) bool {
        const api = xml.attr.get("api") orelse return true;
        return self.matchApiText(api);
    }
    fn addType(self: *@This(), name: []const u8) *TypeCommon {
        const gp = self.types.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate type name: {s}", .{name});
        return gp.value_ptr;
    }
    fn addCommand(self: *@This(), name: []const u8) *Command {
        const gp = self.commands.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate command: {s}", .{name});
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
        const kind = getTextInChild(xml, "type");
        const bitwidth: Flags.Bitwidth = if (kind.len == "VkFlags".len) .@"32" else .@"64";
        const name = getTextInChild(xml, "name");
        const new = self.addType(name);
        new.* = .{ .type = .{ .flags = .{
            .bitwidth = bitwidth,
            .bit_flags = switch (bitwidth) {
                .@"32" => if (xml.attr.get("requires")) |r| r else null,
                .@"64" => if (xml.attr.get("bitvalues")) |r| r else null,
            },
        } } };
    }
    fn parseEnum(self: *@This(), xml: XmlNode) void {
        _ = self;
        _ = xml;
    }
    fn parseStruct(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Failed to find struct's name");
        if (xml.children.len == 0) panic("Struct {s} is empty", .{name});
        const new = self.addType(name);
        new.* = .{
            .comment = getComment(xml),
            .type = .{ .@"struct" = .{
                .s_type = null,
                .members = undefined,
            } },
        };
        const s = &new.type.@"struct";
        if (xml.children[0].getNode().attr.get("values")) |s_type| {
            s.s_type = s_type;
        }
        var members: std.ArrayList(ZigVar) = .empty;
        for (xml.children) |c| {
            if (c == .text or !std.mem.eql(u8, c.node.tag, "member")) continue;
            const n = c.node;
            if (!self.matchApi(n)) continue;
            const new_member = members.addOne(self.allocator) catch @panic("oom");
            new_member.* = .parse(n);
        }
        s.members = members.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseUnion(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Failed to find struct's name");
        const new = self.addType(name);
        new.* = .{
            .comment = getComment(xml),
            .type = .{ .@"union" = .{
                .members = undefined,
            } },
        };
        const s = &new.type.@"union";
        var members: std.ArrayList(ZigVar) = .empty;
        for (xml.children) |c| {
            if (c == .text or !std.mem.eql(u8, c.node.tag, "member")) continue;
            const n = c.node;
            if (!self.matchApi(n)) continue;
            const new_member = members.addOne(self.allocator) catch @panic("oom");
            new_member.* = .parse(n);
        }
        s.members = members.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseHandle(self: *@This(), xml: XmlNode) void {
        const kind = getTextInChild(xml, "type");
        const is_dispatchable = kind.len == "VK_DEFINE_HANDLE".len;
        const name = getTextInChild(xml, "name");
        const new = self.addType(name);
        new.* = .{ .type = .{ .handle = .{ .dispatchable = is_dispatchable } } };
    }
    fn parseFuncpointer(self: *@This(), xml: XmlNode) void {
        var it = xml.childrenIterator();
        const proto = it.nextNode("proto") orelse @panic("Funcpointer missing prototype");
        const ret_and_name: CVar = .parse(proto);
        var params: std.ArrayList(ZigVar) = .empty;
        while (it.nextNode("param")) |param| {
            const new = params.addOne(self.allocator) catch @panic("oom");
            new.* = .{
                .c_var = .parse(param),
                .extra = @splat(.{ .optional = true, .len = .@"1" }),
            };
            if (new.c_var.type.base.ptrs_len != 0) {
                //OVERRIDE

                if (enumFromName(enum { char }, new.c_var.type.base.name)) |e| switch (e) {
                    .char => {
                        new.extra[0].len = .@"null-terminated";
                    },
                };
            }
        }
        const fptr = self.addType(ret_and_name.name);
        fptr.* = .{
            .comment = getComment(xml),
            .type = .{ .funcpointer = .{
                .params = params.toOwnedSlice(self.allocator) catch @panic("oom"),
                .ret = ret_and_name.type.base,
            } },
        };
    }
    fn parseBasetype(self: *@This(), xml: XmlNode) void {
        const name = blk: for (xml.children) |n| {
            const node = if (n == .node) n.node else continue;
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
        return xml.attr.get("comment");
    }
    fn parseAlias(self: *@This(), alias: []const u8, xml: XmlNode) void {
        const name = xml.attr.get("name") orelse panic("Missing name for alias: {s}", .{alias});
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
            const node = if (child == .node) child.node else continue;
            if (!std.mem.eql(u8, node.tag, "type")) continue;
            if (!self.matchApi(node)) continue;
            if (node.attr.get("alias")) |alias| {
                self.parseAlias(alias, node);
                continue;
            }
            if (node.attr.get("category")) |category| {
                const c = enumFromName(enum { bitmask, @"enum", @"struct", @"union", handle, basetype, funcpointer }, category) orelse continue;
                switch (c) {
                    .bitmask => self.parseBitmask(node),
                    .@"enum" => self.parseEnum(node),
                    .@"struct" => self.parseStruct(node),
                    .@"union" => self.parseUnion(node),
                    .handle => self.parseHandle(node),
                    .basetype => self.parseBasetype(node),
                    .funcpointer => self.parseFuncpointer(node),
                }
            } else {
                self.parseForeign(node);
            }
        }
    }

    pub fn init(api: Api, allocator: Allocator) @This() {
        return .{ .api = api, .allocator = allocator };
    }
    pub fn finishParse(self: *@This()) void {
        self.sortBits();
    }
    pub fn parse(self: *@This(), xml: []const XmlNode.NodeOrText) void {
        for (xml) |registry_node| {
            if (registry_node == .text) continue;
            if (!std.mem.eql(u8, registry_node.node.tag, "registry")) continue;
            for (registry_node.node.children) |child| {
                const node = if (child == .node) child.node else continue;
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
        }
    }

    fn sortBits(self: *@This()) void {
        var it = self.types.iterator();
        while (it.next()) |e| if (e.value_ptr.type == .flag_bits) {
            const f = &e.value_ptr.type.flag_bits;
            const B = FlagBits.Bit;
            const lessThan = struct {
                pub fn lessThan(_: void, lhs: B, rhs: B) bool {
                    return lhs.bitpos < rhs.bitpos;
                }
            }.lessThan;
            std.sort.pdq(B, @constCast(f.bits), {}, lessThan);
        };
    }

    fn parseEnums(self: *@This(), xml: XmlNode) void {
        const t = xml.attr.get("type") orelse @panic("Enum missing kind");
        const kind = enumFromName(enum { constants, @"enum", bitmask }, t) orelse @panic("Unknown missing kind");
        switch (kind) {
            .constants => self.parseConstants(xml),
            .@"enum" => self.parseEnumBits(xml),
            .bitmask => self.parseFlagBits(xml),
        }
    }
    fn parseConstants(self: *@This(), xml: XmlNode) void {
        var it = xml.childrenIterator();
        while (it.nextNode("enum")) |node| {
            const type_text = node.attr.get("type") orelse {
                // Must be an extension name or version, just ignore
                continue;
            };
            const name = node.attr.get("name") orelse @panic("Nameless constant");
            const gp = self.constants.getOrPut(self.allocator, name) catch @panic("oom");
            if (gp.found_existing) panic("Duplicate constant: {s}", .{name});
            gp.value_ptr.* = .{
                .value = node.attr.get("value") orelse @panic("Valueless constant"),
                .type = type_text,
                .comment = getComment(node),
            };
        }
    }
    fn parseEnumBits(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Missing enum name");
        const new = self.addType(name);
        new.* = .{
            .comment = getComment(xml),
            .type = .{ .@"enum" = .{
                .values = undefined,
                .aliases = undefined,
            } },
        };
        var values: std.ArrayList(Enum.Value) = .empty;
        var aliases: std.ArrayList(Enum.Alias) = .empty;
        var it = xml.childrenIterator();
        while (it.nextNode("enum")) |node| {
            if (!self.matchApi(node)) continue;
            const entry_name = node.attr.get("name") orelse @panic("Missing enum entry name");
            if (node.attr.get("alias")) |alias| {
                const new_alias = aliases.addOne(self.allocator) catch @panic("oom");
                new_alias.* = .{
                    .canonical = alias,
                    .name = entry_name,
                    .comment = getComment(node),
                    .providers = .{},
                };
            } else {
                const new_value = values.addOne(self.allocator) catch @panic("oom");
                new_value.* = .{
                    .name = entry_name,
                    .value = (node.attr.get("value") orelse panic("Missing value for enum {s}", .{name})),
                    .comment = getComment(node),
                    .providers = .{},
                    .extension_value = false,
                };
            }
        }
        new.type.@"enum".values = values.toOwnedSlice(self.allocator) catch @panic("oom");
        new.type.@"enum".aliases = aliases.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseFlagBits(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Missing bitmask name");
        const new = self.addType(name);
        new.* = .{
            .comment = getComment(xml),
            .type = .{ .flag_bits = .{
                .bits = undefined,
                .bit_aliases = undefined,
                .aggregates = undefined,
            } },
        };
        const flag_bits = &new.type.flag_bits;
        if (xml.attr.get("bitwidth")) |bitwidth| {
            flag_bits.bitwidth = enumFromName(Flags.Bitwidth, bitwidth) orelse panic("Unknown bitwidth: {s}", .{bitwidth});
        }
        var aggregates: std.ArrayList(FlagBits.Aggregate) = .empty;
        var aliases: std.ArrayList(FlagBits.BitAlias) = .empty;
        var bits: std.ArrayList(FlagBits.Bit) = .empty;
        var it = xml.childrenIterator();
        while (it.nextNode("enum")) |node| {
            if (!self.matchApi(node)) continue;
            const entry_name = node.attr.get("name") orelse @panic("Missing enum entry name");
            if (node.attr.get("alias")) |alias| {
                const new_alias = aliases.addOne(self.allocator) catch @panic("oom");
                new_alias.* = .{
                    .canonical = alias,
                    .name = entry_name,
                    .comment = getComment(node),
                    .providers = .{},
                };
            } else if (node.attr.get("value")) |value| {
                const new_value = aggregates.addOne(self.allocator) catch @panic("oom");
                new_value.* = .{
                    .name = entry_name,
                    .value = value,
                    .comment = getComment(node),
                    .providers = .{},
                };
            } else if (node.attr.get("bitpos")) |bitpos| {
                const new_bit = bits.addOne(self.allocator) catch @panic("oom");
                new_bit.* = .{
                    .name = entry_name,
                    .bitpos = std.fmt.parseInt(FlagBits.Bitpos, bitpos, 10) catch panic("Failed to parse bitpos: {s}", .{bitpos}),
                    .comment = getComment(node),
                    .providers = .{},
                    .extension_bit = false,
                };
            }
        }
        flag_bits.aggregates = aggregates.toOwnedSlice(self.allocator) catch @panic("oom");
        flag_bits.bits = bits.toOwnedSlice(self.allocator) catch @panic("oom");
        flag_bits.bit_aliases = aliases.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseCommands(self: *@This(), xml: XmlNode) void {
        var it = xml.childrenIterator();
        while (it.nextNode("command")) |node| {
            if (!self.matchApi(node)) continue;
            if (node.attr.get("alias")) |alias| {
                const canon = self.commands.getPtr(alias) orelse panic("Failed to find command for alias: {s}", .{alias});
                const name = node.attr.get("name") orelse panic("Nameless alias: {s}", .{alias});
                const new = self.addCommand(name);
                new.* = canon.*;
                continue;
            }
            self.parseCommand(node);
        }
    }
    fn parseCommand(self: *@This(), xml: XmlNode) void {
        const proto = blk: {
            var it = xml.childrenIterator();
            while (it.nextNode("proto")) |node| {
                if (self.matchApi(node)) break :blk node;
            }
            @panic("Missing command prototype");
        };

        const ret_and_name: CVar = .parse(proto);
        const new = self.addCommand(ret_and_name.name);
        new.* = .{
            .error_codes = if (xml.attr.get("errorcodes")) |e| e else &.{},
            .success_codes = if (xml.attr.get("successcodes")) |e| e else &.{},
            .ret = ret_and_name.type.base,
            .params = undefined,
        };
        var params: std.ArrayList(ZigVar) = .empty;
        var it = xml.childrenIterator();
        while (it.nextNode("param")) |node| {
            if (!self.matchApi(node)) continue;
            params.append(self.allocator, .parse(node)) catch @panic("oom");
        }
        new.params = params.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseFeature(self: *@This(), xml: XmlNode) void {
        const number = xml.attr.get("number") orelse @panic("Missing feature number");
        const version: VkVersionName = .parse(number);
        const apitype = xml.attr.get("apitype");
        if (apitype == null or !std.mem.eql(u8, apitype.?, "internal")) {
            const new: VkVersion = .{
                .name = version,
            };
            self.versions = concat(self.allocator, VkVersion, &.{ @constCast(self.versions), &.{new} }) catch @panic("oom");
        }
        self.parseVkRequires(xml, .parseVersion(version), null);
    }
    fn parseVkRequires(self: *@This(), xml: XmlNode, provider: Providers.Provider, ext_number: ?[]const u8) void {
        var require_it = xml.childrenIterator();
        while (require_it.nextNode("require")) |require_node| {
            self.parseVkRequire(require_node, provider, ext_number);
        }
    }
    fn parseVideoRequires(self: *@This(), xml: XmlNode) void {
        var require_it = xml.childrenIterator();
        while (require_it.nextNode("require")) |require_node| {
            self.parseConstants(require_node);
        }
    }
    fn parseVkRequire(self: *@This(), xml: XmlNode, provider: Providers.Provider, ext_number: ?[]const u8) void {
        for (xml.children) |child| {
            if (child == .text) continue;
            const node = child.node;
            switch (enumFromName(enum { type, command, @"enum" }, node.tag) orelse continue) {
                .@"enum" => {
                    self.parseEnumExtension(node, ext_number, provider);
                },
                .command => {
                    const com_name = node.attr.get("name") orelse continue;
                    const c = self.commands.getPtr(com_name) orelse continue;
                    c.providers.add(provider, self.allocator);
                },
                .type => {
                    const type_name = node.attr.get("name") orelse continue;
                    const t = self.types.getPtr(type_name) orelse continue;
                    t.providers.add(provider, self.allocator);

                    if (t.type == .alias) {
                        const canon = self.types.getPtr(t.type.alias.canonical) orelse panic("Failed to find canonical type: {s}", .{t.type.alias.canonical});
                        canon.providers.add(provider, self.allocator);
                    }
                },
            }
        }
    }

    fn parseExtensions(self: *@This(), xml: XmlNode) void {
        var extension_it = xml.childrenIterator();
        var extensions: std.ArrayList(Extension) = .{
            .items = @constCast(self.extensions),
            .capacity = self.extensions.len,
        };
        while (extension_it.nextNode("extension")) |node| {
            if (node.attr.get("type")) |type_text| {
                if (node.attr.get("supported")) |supported| {
                    if (std.mem.eql(u8, supported, "disabled")) continue;
                }
                const number = node.attr.get("number") orelse @panic("Missing extension number");
                const ext_name = node.attr.get("name") orelse @panic("Missing extension name");
                const new = extensions.addOne(self.allocator) catch @panic("oom");
                new.* = .{
                    .name = .parse(ext_name),
                    .kind = .parse(type_text),
                    .promoted = node.attr.get("promotedto"),
                    .depends = node.attr.get("depends"),
                };
                self.parseVkRequires(node, .parseExtension(new.name), number);
            } else {
                self.parseVideoRequires(node);
            }
        }

        self.extensions = extensions.toOwnedSlice(self.allocator) catch @panic("oom");
    }

    fn parseEnumExtension(self: *@This(), xml: XmlNode, extension_number: ?[]const u8, provider: Providers.Provider) void {
        const name = xml.attr.get("name") orelse @panic("Missing enum extension name");
        const extends = xml.attr.get("extends") orelse {
            const constant = self.constants.getPtr(name) orelse {
                // Must be a extension version or name constant, just ignore
                return;
            };
            constant.providers.add(provider, self.allocator);
            return;
        };
        const enum_type = self.types.getPtr(extends) orelse panic("Type not found: {s}", .{extends});
        const comment = getComment(xml);
        switch (enum_type.type) {
            .@"enum" => |*en| {
                if (xml.attr.get("alias")) |alias| {
                    blk: for (en.aliases) |*a| {
                        if (std.mem.eql(u8, a.name, name)) {
                            @constCast(a).providers.add(provider, self.allocator);
                            break :blk;
                        }
                    } else {
                        const new_alias: Enum.Alias = .{
                            .name = name,
                            .canonical = alias,
                            .comment = comment,
                            .providers = provider.toProviders(self.allocator),
                        };
                        en.aliases = concat(self.allocator, Enum.Alias, &.{ @constCast(en.aliases), &.{new_alias} }) catch @panic("oom");
                    }
                    return;
                }
                for (en.values) |*a| {
                    if (std.mem.eql(u8, a.name, name)) {
                        @constCast(a).providers.add(provider, self.allocator);
                        return;
                    }
                }
                const value: []const u8 = if (xml.attr.get("offset")) |offset| blk: {
                    const extnum = if (xml.attr.get("extnumber")) |x| x else extension_number orelse panic("Missing extnumber for enum: {s}", .{name});
                    const is_neg = xml.attr.get("dir") != null;
                    var temp: Writer.Allocating = .init(self.allocator);
                    temp.writer.print("{s}(1000000000+({s}-1)*1000+{s})", .{ if (is_neg) "-" else "", extnum, offset }) catch @panic("oom");
                    break :blk temp.toOwnedSlice() catch @panic("oom");
                } else if (xml.attr.get("value")) |value|
                    value
                else
                    @panic("Enum extension doesn't have offset or value");
                const new: Enum.Value = .{
                    .name = name,
                    .value = value,
                    .comment = comment,
                    .providers = provider.toProviders(self.allocator),
                    .extension_value = true,
                };
                en.values = concat(self.allocator, Enum.Value, &.{ @constCast(en.values), &.{new} }) catch @panic("oom");
            },
            .flag_bits => |*b| {
                if (xml.attr.get("alias")) |alias| {
                    blk: for (b.bit_aliases) |*a| {
                        if (std.mem.eql(u8, a.name, name)) {
                            @constCast(a).providers.add(provider, self.allocator);
                            break :blk;
                        }
                    } else {
                        const new_alias: FlagBits.BitAlias = .{
                            .name = name,
                            .canonical = alias,
                            .comment = comment,
                            .providers = provider.toProviders(self.allocator),
                        };
                        b.bit_aliases = concat(self.allocator, FlagBits.BitAlias, &.{ @constCast(b.bit_aliases), &.{new_alias} }) catch @panic("oom");
                    }
                    inner: for (b.bits) |*a| {
                        if (std.mem.eql(u8, a.name, alias)) {
                            @constCast(a).providers.add(provider, self.allocator);
                            break :inner;
                        }
                    }
                    return;
                }
                if (xml.attr.get("bitpos")) |bitpos_text| {
                    const bitpos = std.fmt.parseInt(FlagBits.Bitpos, bitpos_text, 10) catch panic("Failed to parse bitpos for enum extension: {s}", .{name});
                    for (b.bits) |*a| {
                        if (a.bitpos == bitpos) {
                            @constCast(a).providers.add(provider, self.allocator);
                            return;
                        }
                    }
                    const new_bit: FlagBits.Bit = .{
                        .bitpos = bitpos,
                        .name = name,
                        .comment = comment,
                        .providers = provider.toProviders(self.allocator),
                        .extension_bit = true,
                    };

                    b.bits = concat(self.allocator, FlagBits.Bit, &.{ @constCast(b.bits), &.{new_bit} }) catch @panic("oom");
                } else if (xml.attr.get("value")) |value_text| {
                    for (b.aggregates) |*a| {
                        if (std.mem.eql(u8, a.name, name)) {
                            @constCast(a).providers.add(provider, self.allocator);
                            return;
                        }
                    }
                    const agg: FlagBits.Aggregate = .{
                        .name = name,
                        .comment = comment,
                        .value = value_text,
                        .providers = provider.toProviders(self.allocator),
                    };
                    b.aggregates = concat(self.allocator, FlagBits.Aggregate, &.{ @constCast(b.aggregates), &.{agg} }) catch @panic("oom");
                } else panic("Missing value of bitpos for enum: {s}", .{name});
            },
            else => |t| panic("Unexpected type for enum extension: {t}", .{t}),
        }
    }
};

const render = struct {
    const no_version = "99";
    const Primitives = enum {
        void,
        char,
        float,
        double,
        int8_t,
        uint8_t,
        int16_t,
        uint16_t,
        int32_t,
        uint32_t,
        int64_t,
        uint64_t,
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
                .int32_t => "i32",
                .uint32_t => "u32",
                .int64_t => "i64",
                .uint64_t => "u64",
                .size_t => "usize",
                .int => "c_int",
            };
        }
        pub fn bitSize(self: @This()) usize {
            return switch (self) {
                .void => 0,
                .char => 8,
                .float => 32,
                .double => 64,
                .int8_t => 8,
                .uint8_t => 8,
                .int16_t => 16,
                .uint16_t => 16,
                .uint32_t => 32,
                .uint64_t => 64,
                .int32_t => 32,
                .int64_t => 64,
                .size_t => @bitSizeOf(usize),
                .int => @bitSizeOf(c_int),
            };
        }
    };
    fn stripPrefix(name: []const u8, prefix: []const u8) []const u8 {
        return tryStripPrefix(name, prefix) orelse panic("Expected {s} to start with prefix {s}", .{ name, prefix });
    }
    fn tryStripPrefix(name: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        return name[prefix.len..];
    }
    const Mixins = struct {
        mixins: []const []const u8,
        mixin_kind: []const u8,
        flags_name: TypeName,
        flag_bits_name: TypeName,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            for (self.mixins) |m| {
                try writer.print(
                    \\pub const {[mixin]s}={[mixin_kind]s}Mixin({[flags]f},{[flag_bits]f}).{[mixin]s};
                , .{
                    .mixin = m,
                    .mixin_kind = self.mixin_kind,
                    .flags = self.flags_name,
                    .flag_bits = self.flag_bits_name,
                });
            }
        }
    };
    const Comment = struct {
        text: ?[]const u8,

        pub fn parse(text: ?[]const u8) @This() {
            const t = text orelse return .{ .text = null };
            return .{ .text = tryStripPrefix(t, "// ") orelse t };
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            if (self.text) |t| {
                try writer.print("\n/// {s}\n", .{t});
            }
        }
    };
    const Provider = struct {
        p: Registry.Providers = .{},

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const p = self.p;
            if (p.version == null and p.extensions.len == 0) return;
            try writer.writeAll(
                \\
                \\/// Provided by 
            );
            if (p.version) |version| {
                try writer.print("Vulkan {s}", .{version.number});
                if (p.extensions.len != 0) {
                    try writer.writeAll(", ");
                }
            }
            for (p.extensions[0..p.extensions.len -| 1]) |e| {
                try writer.print("{s}, ", .{e.name});
            }
            if (p.extensions.len != 0) {
                try writer.writeAll(p.extensions[p.extensions.len - 1].name);
            }
            try writer.writeByte('\n');
        }
    };
    const TypeName = struct {
        name: []const u8,

        pub fn parse(name: []const u8) @This() {
            return .{ .name = tryStripPrefix(name, "Vk") orelse
                stripPrefix(name, "StdVideo") };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    const EnumName = struct {
        name: []const u8,

        pub fn parse(entry_name: []const u8, enum_name: TypeName) @This() {
            return .{
                .name = stripEnumName(entry_name, enum_name),
            };
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return std.mem.eql(u8, lhs.name, rhs.name);
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("@\"{s}\"", .{self.name});
        }
    };
    const BitName = struct {
        enum_name: EnumName,

        pub fn parse(entry_name: []const u8, enum_name: TypeName) @This() {
            return .{
                .enum_name = .parse(entry_name, enum_name),
            };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const bit_suffix = "_BIT";
            const n = self.enum_name.name;
            const first: []const u8, const second: []const u8 = if (std.mem.findLast(u8, n, bit_suffix)) |i|
                .{ n[0..i], n[i + bit_suffix.len ..] }
            else
                .{ n, &.{} };
            try writer.print("@\"{s}{s}\"", .{ first, second });
        }
    };
    fn printFlags(registry: *const Registry, name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const mixins_funcs: []const []const u8 = &.{ "toInt", "fromInt", "merge", "intersection", "negation", "difference", "toBit", "fromBit", "set", "unset" };

        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.flags;
        const flags_name: TypeName = .parse(name);
        const Bits = struct {
            b: Registry.FlagBits,
            flags_name: TypeName,

            const Reserved = struct {
                diff: u8,
                bitpos: u8,

                pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                    if (self.diff > 1) {
                        try w.print(
                            \\_reserved_{}: LockedInt(u{}, 0) = .@"0",
                        , .{ self.bitpos, self.diff - 1 });
                    }
                }
            };

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const flag_bits = self.b;
                var last_bitpos: u8 = undefined;
                if (flag_bits.bits.len != 0) {
                    const first = flag_bits.bits[0];
                    if (first.bitpos != 0) {
                        try w.print(
                            \\_reserved_leading: LockedInt(u{[bits]}, 0) = .@"0",
                        , .{ .bits = first.bitpos });
                    }

                    last_bitpos = flag_bits.bits[0].bitpos;
                }
                for (flag_bits.bits) |b| {
                    const bit_comment: Comment = .parse(b.comment);
                    const bit_provider: Provider = .{ .p = if (b.extension_bit) b.providers else .{} };
                    const bit_name: BitName = .parse(b.name, self.flags_name);
                    const diff = b.bitpos - last_bitpos;
                    const reserved: Reserved = .{ .diff = diff, .bitpos = b.bitpos };
                    try w.print(
                        \\{[comment]f}
                        \\{[provider]f}
                        \\{[reserved]f}
                        \\{[bit_name]f}: bool = false,
                    , .{
                        .comment = bit_comment,
                        .provider = bit_provider,
                        .bit_name = bit_name,
                        .reserved = reserved,
                    });
                    last_bitpos = b.bitpos;
                }
                var remaining = flag_bits.bitwidth.bitSize();
                if (flag_bits.bits.len != 0) {
                    remaining = remaining - flag_bits.bits[flag_bits.bits.len - 1].bitpos - 1;
                }
                if (remaining != 0) {
                    try w.print(
                        \\_reserved_trailing: LockedInt(u{[bits]}, 0) = .@"0",
                    , .{ .bits = remaining });
                }
                for (flag_bits.aggregates) |agg| {
                    const bit_comment: Comment = .parse(agg.comment);
                    const bit_provider: Provider = .{ .p = agg.providers };
                    const bit_name: BitName = .parse(agg.name, self.flags_name);
                    try w.print(
                        \\{[comment]f}
                        \\{[provider]f}
                        \\pub const {[bit_name]f}: @This() = @bitCast({[value]s});
                    , .{
                        .comment = bit_comment,
                        .provider = bit_provider,
                        .bit_name = bit_name,
                        .value = agg.value,
                    });
                }
            }
        };
        var mixins: Mixins = .{
            .mixins = mixins_funcs,
            .mixin_kind = "Flags",
            .flags_name = flags_name,
            .flag_bits_name = .{ .name = "undefined" },
        };
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f} = packed struct(u{[bitwidth]t}){{
            \\
        , .{
            .comment = comment,
            .provider = provider,
            .name = flags_name,
            .bitwidth = e.bitwidth,
        });
        if (e.bit_flags) |flag_bits_name| {
            const flag_bits_ = registry.resolveAlias(flag_bits_name);
            if (flag_bits_.type != .flag_bits) panic("Expected {s} to be FlagBits", .{flag_bits_name});
            const flag_bits = flag_bits_.type.flag_bits;
            const bits: Bits = .{
                .b = flag_bits,
                .flags_name = flags_name,
            };
            const flag_bits_type_name: TypeName = .parse(flag_bits_name);
            mixins.flag_bits_name = flag_bits_type_name;
            try writer.print(
                \\{[bits]f}
                \\{[mixins]f}
                \\}};
            , .{
                .bits = bits,
                .mixins = mixins,
            });
            if (flag_bits.bits.len != 0) {
                try printFlagBitsFromFlags(flag_bits_type_name, flag_bits_, writer, flags_name);
            }
        } else {
            try writer.print(
                \\_reserved_trailing: LockedInt(u{[bits]}, 0) = .@"0",
                \\{[mixins]f}
                \\}};
            , .{
                .mixins = mixins,
                .bits = e.bitwidth.bitSize(),
            });
        }
    }
    fn printFlagBitsFromFlags(flag_bits_name: TypeName, e_c: Registry.TypeCommon, writer: *Writer, flags_name: TypeName) Writer.Error!void {
        const mixin_funcs: []const []const u8 = &.{ "toFlags", "fromFlags", "toInt", "fromInt" };

        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const mixins: Mixins = .{
            .mixins = mixin_funcs,
            .mixin_kind = "FlagBits",
            .flags_name = flags_name,
            .flag_bits_name = flag_bits_name,
        };
        const e = e_c.type.flag_bits;
        const Bits = struct {
            bits: Registry.FlagBits,
            enum_name: TypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.bits.bits) |b| {
                    const name: BitName = .parse(b.name, self.enum_name);
                    const c: Comment = .parse(b.comment);
                    const p: Provider = .{ .p = if (b.extension_bit) b.providers else .{} };
                    try w.print(
                        \\
                        \\{[comment]f}
                        \\{[provider]f}
                        \\{[name]f}=1<<{[bitpos]},
                        \\
                    , .{
                        .comment = c,
                        .provider = p,
                        .name = name,
                        .bitpos = b.bitpos,
                    });
                }
            }
        };
        const bits: Bits = .{
            .bits = e,
            .enum_name = flag_bits_name,
        };

        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f} = enum(u{[bitwidth]t}){{
            \\{[bits]f}
            \\{[mixins]f}
            \\}};
        , .{
            .comment = comment,
            .provider = provider,
            .name = flag_bits_name,
            .bitwidth = e.bitwidth,
            .mixins = mixins,
            .bits = bits,
        });
    }
    fn printFlagBits(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        if (e_c.type.flag_bits.bits.len != 0) return;
        try printFlagBitsFromFlags(.parse(name), e_c, writer, .{ .name = "undefined" });
    }
    fn extractAuthor(name: []const u8) []const u8 {
        var i = name.len;
        while (i != 0) {
            i -= 1;
            const n = name[i];
            if (!std.ascii.isUpper(n)) {
                i += 1;
                break;
            }
        }
        return name[i..];
    }
    fn extractVersion(name: []const u8) []const u8 {
        var i = name.len;
        while (i != 0) {
            i -= 1;
            const n = name[i];
            if (n < '0' or n > '9') {
                i += 1;
                break;
            }
        }
        return name[i..];
    }
    fn stripEnumName(entry_name: []const u8, enum_name: TypeName) []const u8 {
        const stripped_entry_name_: ConstantName = .parse(entry_name);
        var stripped_entry_name = stripped_entry_name_.name;
        if (entry_name.len <= enum_name.name.len) return stripped_entry_name;
        var local_enum_name = enum_name.name;
        outer: while (true) {
            const under = std.mem.findScalar(u8, stripped_entry_name, '_') orelse break;
            if (under > local_enum_name.len) break;
            const entry_segment = stripped_entry_name[0..under];
            for (entry_segment, local_enum_name[0..under]) |entry, name| {
                if (std.ascii.toUpper(name) != entry) {
                    const author = extractAuthor(local_enum_name);
                    local_enum_name = local_enum_name[0 .. local_enum_name.len - author.len];
                    if (std.mem.eql(u8, entry_segment, extractVersion(local_enum_name))) {
                        stripped_entry_name = stripped_entry_name[under + 1 ..];
                    }
                    break :outer;
                }
            }
            stripped_entry_name = stripped_entry_name[under + 1 ..];
            local_enum_name = local_enum_name[under..];
        }

        return stripped_entry_name;
    }
    fn stripBitSuffix(name: []const u8) []const u8 {
        if (std.mem.findLast(u8, name, "_BIT")) |i| {
            return name[0..i];
        }
        return name;
    }
    fn stripEnumNameAndBitSuffix(entry_name: []const u8, enum_name: TypeName) []const u8 {
        const n = stripEnumName(entry_name, enum_name);
        return stripBitSuffix(n);
    }
    fn printEnum(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const Aliases = struct {
            aliases: []const Registry.Enum.Alias,
            enum_name: TypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.aliases) |a| {
                    const alias_name: EnumName = .parse(a.name, self.enum_name);
                    const canonical_name: EnumName = .parse(a.canonical, self.enum_name);
                    if (alias_name.eql(canonical_name)) continue; // SRGB_NONLINEAR_KHR
                    const c: Comment = .parse(a.comment);
                    const p: Provider = .{ .p = a.providers };
                    try w.print(
                        \\{[comment]f}
                        \\{[provider]f}
                        \\pub const {[alias_name]f} = @This().{[canonical_name]f};
                    , .{
                        .comment = c,
                        .provider = p,
                        .alias_name = alias_name,
                        .canonical_name = canonical_name,
                    });
                }
            }
        };
        const Values = struct {
            values: []const Registry.Enum.Value,
            enum_name: TypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.values) |v| {
                    const c: Comment = .parse(v.comment);
                    const p: Provider = .{ .p = v.providers };
                    const n: EnumName = .parse(v.name, self.enum_name);

                    try w.print(
                        \\{[comment]f}
                        \\{[provider]f}
                        \\{[name]f} = {[value]s},
                    , .{
                        .comment = c,
                        .provider = p,
                        .name = n,
                        .value = v.value,
                    });
                }
            }
        };

        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.@"enum";
        const enum_name: TypeName = .parse(name);
        const values: Values = .{ .values = e.values, .enum_name = enum_name };
        const aliases: Aliases = .{ .aliases = e.aliases, .enum_name = enum_name };
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f}=enum(i32){{
            \\{[values]f}
            \\{[aliases]f}
            \\}};
        , .{
            .name = enum_name,
            .comment = comment,
            .provider = provider,
            .values = values,
            .aliases = aliases,
        });
    }
    fn printStruct(name: []const u8, e_c: Registry.TypeCommon, registry: *const Registry, writer: *Writer) Writer.Error!void {
        const Members = struct {
            e: Registry.Struct,
            r: *const Registry,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const e = self.e;
                var members = e.members;
                if (e.s_type) |s_type| {
                    try w.print("sType: LockedEnum(StructureType, .{[name]s}) =.{[name]s},", .{ .name = stripPrefix(s_type, "VK_STRUCTURE_TYPE_") });
                    members = members[1..];
                }

                var in_bitfield = false;
                var bit_field_index: usize = 0;
                var remaining_bitfield_bits: usize = undefined;
                for (members) |m| {
                    const v: ZigVar = .parse(m);
                    if (m.c_var.type.amount == .bitfield) {
                        if (!in_bitfield) {
                            const type_name = m.c_var.type.base.name;
                            if (enumFromName(Primitives, type_name)) |primitive| {
                                remaining_bitfield_bits = primitive.bitSize();
                            } else {
                                const t = self.r.types.get(type_name) orelse panic("Unknown bit size of bitfield type: {s}", .{type_name});
                                remaining_bitfield_bits = switch (t.type) {
                                    .flag_bits => |f| f.bitwidth.bitSize(),
                                    .flags => |f| f.bitwidth.bitSize(),
                                    .@"enum" => 32,
                                    else => panic("Unknown bit size of bitfield type: {s}", .{type_name}),
                                };
                            }
                            try w.print("p{}:packed struct(u{}){{", .{ bit_field_index, remaining_bitfield_bits });
                            bit_field_index += 1;
                            in_bitfield = true;
                        }
                        try w.print("{f}", .{v});
                        remaining_bitfield_bits = std.math.sub(usize, remaining_bitfield_bits, m.c_var.type.amount.bitfield) catch @panic("Bits overflow packed member bitwidth");
                        if (remaining_bitfield_bits == 0) {
                            try w.writeAll(",}");
                            in_bitfield = false;
                        }
                    } else {
                        if (in_bitfield) {
                            try w.print(
                                \\_reserved: LockedInt(u{[bits]},0) = .@"0",
                                \\}},
                            , .{ .bits = remaining_bitfield_bits });
                            remaining_bitfield_bits = undefined;
                            in_bitfield = false;
                        }
                        try w.print("{f} = nullValue({f})", .{ v, v.v });
                    }

                    try w.writeByte(',');
                }

                if (in_bitfield) {
                    try w.print(
                        \\_reserved: LockedInt(u{[bits]},0) = .@"0",
                        \\}},
                    , .{ .bits = remaining_bitfield_bits });
                }
            }
        };
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.@"struct";
        const members: Members = .{ .e = e, .r = registry };
        const struct_name: TypeName = .parse(name);
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[struct_name]f}=extern struct{{
            \\{[members]f}
            \\}};
        , .{
            .comment = comment,
            .provider = provider,
            .struct_name = struct_name,
            .members = members,
        });
    }
    const ZigVar = struct {
        v: ZigType,

        pub fn parse(zig_var: Registry.ZigVar) @This() {
            return .{ .v = .parse(zig_var) };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const ptr_len = self.v.v.c_var.type.base.ptrs_len;
            if (self.v.v.c_var.type.amount == .array and self.v.v.extra[0].len == .@"null-terminated") {
                try writer.writeAll("\n/// Null-terminated\n");
            }
            for (self.v.v.extra[0..ptr_len]) |extra| {
                switch (extra.len) {
                    .expression => |e| {
                        try writer.print("\n/// Length given by {s}\n", .{e});
                        break;
                    },
                    .@"null-terminated", .@"1" => {},
                }
            }
            const comment: Comment = .parse(self.v.v.c_var.comment);
            try writer.print(
                \\{[comment]f}
                \\@"{[name]s}": {[type]f}
            , .{
                .name = self.v.v.c_var.name,
                .comment = comment,
                .type = self.v,
            });
        }
    };

    const ZigType = struct {
        const max_ptr = Registry.CBaseType.max_ptr;
        v: Registry.ZigVar,

        pub fn parse(zig_var: Registry.ZigVar) @This() {
            return .{
                .v = zig_var,
            };
        }

        pub fn format(self: @This(), w: *Writer) Writer.Error!void {
            if (self.v.c_var.type.amount == .bitfield) {
                try w.print("u{}", .{self.v.c_var.type.amount.bitfield});
                return;
            }
            const ptr_len = self.v.c_var.type.base.ptrs_len;
            const base_type = self.v.c_var.type.base;
            const is_anyopaque = base_type.ptrs_len != 0 and std.mem.eql(u8, base_type.name, "void");

            for (self.v.extra[0..ptr_len], base_type.ptrs[0..ptr_len]) |extra, ptr| {
                if (extra.optional) {
                    try w.writeByte('?');
                }
                if (is_anyopaque) {
                    try w.writeByte('*');
                } else switch (extra.len) {
                    .expression => {
                        try w.writeAll("[*]");
                    },
                    .@"null-terminated" => {
                        try w.writeAll("[*:0]");
                    },
                    .@"1" => {
                        try w.writeByte('*');
                    },
                }
                if (ptr == .@"const") {
                    try w.writeAll("const ");
                }
            }

            if (self.v.c_var.type.amount == .array) {
                try w.writeByte('[');
                switch (self.v.c_var.type.amount.array) {
                    .literal => |l| {
                        // video.xml doesn't put the proper tags in array sizes, so
                        // it ends up in this branch
                        try w.writeAll(tryStripPrefix(l, "VK_") orelse
                            tryStripPrefix(l, "STD_VIDEO_") orelse l);
                    },
                    .constant => |c| try writeConstant(c, w),
                }
                try w.writeByte(']');
            }

            //OVERRIDE: Overriding API versions from u32 to our own ApiVersion
            if (enumFromName(enum { apiVersion, pApiVersion }, self.v.c_var.name)) |_| {
                try w.writeAll("ApiVersion");
            } else if (self.v.c_var.type.base.ptrs_len != 0 and std.mem.eql(u8, self.v.c_var.type.base.name, "void")) {
                try w.writeAll("anyopaque");
            } else {
                const n: GenericTypeName = .parse(self.v.c_var.type.base.name);
                try w.print("{f}", .{n});
            }
        }
    };
    fn writeConstant(name: []const u8, writer: *Writer) Writer.Error!void {
        const constant: ConstantName = .parse(name);
        try writer.print("{f}", .{constant});
    }
    fn printUnion(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const Members = struct {
            e: Registry.Union,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.e.members) |m| {
                    const v: ZigVar = .parse(m);
                    try w.print("{f},", .{v});
                }
            }
        };
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.@"union";
        const n: TypeName = .parse(name);
        const members: Members = .{ .e = e };
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f}=extern union{{
            \\{[members]f}
            \\}};
        , .{
            .comment = comment,
            .provider = provider,
            .name = n,
            .members = members,
        });
    }
    fn printHandle(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.handle;
        const n: TypeName = .parse(name);
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f}=enum({[t]s}){{null_handle,_}};
        , .{
            .comment = comment,
            .provider = provider,
            .name = n,
            .t = if (e.dispatchable) "usize" else "u64",
        });
    }
    fn printBasetype(name: []const u8, e: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    fn printForeign(name: []const u8, e: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        _ = name;
        _ = e;
        _ = writer;
    }
    const GenericTypeName = struct {
        name: []const u8,
        kind: Kind,

        const Kind = enum {
            vk,
            pfn,
            std_video,
            primitive,
            none,
        };

        pub fn parse(name: []const u8) @This() {
            return if (tryStripPrefix(name, "StdVideo")) |n| .{
                .name = n,
                .kind = .vk,
            } else if (tryStripPrefix(name, "PFN_vk")) |n| .{
                .name = n,
                .kind = .pfn,
            } else if (tryStripPrefix(name, "Vk")) |n| .{
                .name = n,
                .kind = .vk,
            } else if (enumFromName(Primitives, name)) |n| .{
                .name = n.toZig(),
                .kind = .primitive,
            } else .{ .name = name, .kind = .none };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            if (self.kind == .pfn) {
                try writer.writeAll("Pfn");
            }
            try writer.writeAll(self.name);
        }
    };

    const CBaseType = struct {
        v: Registry.CBaseType,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const base_type = self.v;
            const is_anyopaque = base_type.ptrs_len != 0 and std.mem.eql(u8, base_type.name, "void");
            var ptr_text: []const u8 = "[*c]";
            if (is_anyopaque) {
                try writer.writeByte('?');
                ptr_text = "*";
            }

            for (base_type.ptrs[0..base_type.ptrs_len]) |k| {
                try writer.writeAll(ptr_text);
                switch (k) {
                    .@"const" => try writer.writeAll("const "),
                    .mutable => {},
                }
            }
            if (is_anyopaque) {
                try writer.writeAll("anyopaque");
                return;
            }

            const name: GenericTypeName = .parse(base_type.name);
            try writer.print("{f}", .{name});
        }
    };
    const CType = struct {
        v: Registry.CType,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const c_type = self.v;
            if (c_type.amount == .bitfield) {
                try writer.print("u{}", .{c_type.amount.bitfield});
                return;
            }
            const base: CBaseType = .{ .v = c_type.base };
            try writer.print("{f}", .{base});
            if (c_type.amount == .array) {
                const ar = c_type.amount.array;
                switch (ar) {
                    .literal => |l| try writer.writeAll(l),
                    .constant => |c| try writeConstant(c, writer),
                }
            }
        }
    };
    const CVar = struct {
        v: Registry.CVar,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const c_var = self.v;
            const comment: Comment = .parse(c_var.comment);
            const c_type: CType = .{ .v = c_var.type };
            try writer.print(
                \\{[comment]f}
                \\{[name]s}: {[c_type]f}
            , .{
                .comment = comment,
                .name = c_var.name,
                .c_type = c_type,
            });
        }
    };

    const FuncpointerName = struct {
        name: []const u8,

        pub fn parse(name: []const u8) @This() {
            return .{ .name = stripPrefix(name, "PFN_vk") };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("Pfn{s}", .{self.name});
        }
    };
    const CParams = struct {
        params: []const Registry.CVar,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            for (self.params) |p| {
                const v: CVar = .{ .v = p };
                try writer.print("{f},", .{v});
            }
        }
    };
    const Params = struct {
        params: []const Registry.ZigVar,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            for (self.params) |p| {
                const v: ZigVar = .parse(p);
                try writer.print("{f},", .{v});
            }
        }
    };
    fn printFuncpointer(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.funcpointer;
        const n: FuncpointerName = .parse(name);
        const params: Params = .{ .params = e.params };
        const ret: CBaseType = .{ .v = e.ret };
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f} = ?*const fn(
            \\{[params]f}
            \\) callconv(vulkan_api) {[ret]f};
        , .{
            .comment = comment,
            .provider = provider,
            .name = n,
            .params = params,
            .ret = ret,
        });
    }
    fn printAlias(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.alias;
        const a_name: TypeName = .parse(name);
        const c_name: TypeName = .parse(e.canonical);
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[a_name]f} = {[c_name]f};
        , .{
            .comment = comment,
            .provider = provider,
            .a_name = a_name,
            .c_name = c_name,
        });
    }
    fn printConstants(constants: Registry.Constants, writer: *Writer) Writer.Error!void {
        var it = constants.iterator();
        while (it.next()) |entry| {
            const c_name = entry.key_ptr.*;
            const c = entry.value_ptr.*;
            // OVERRIDE: true and false have been subsumed into Bool32
            if (enumFromName(enum { VK_TRUE, VK_FALSE }, c_name)) |_| continue;

            const comment: Comment = .parse(c.comment);
            const provider: Provider = .{ .p = c.providers };
            const name: ConstantName = .parse(c_name);
            const zig_type: Primitives = enumFromName(Primitives, c.type) orelse panic("Unknown primitive type: {s}", .{c.type});
            var value = c.value;
            const num_characters = "0123456789.";

            const negate = if (std.mem.startsWith(u8, c.value, "0x"))
                false
            else if (std.mem.findScalar(u8, c.value, '~')) |i| blk: {
                value = value[i + 1 ..];
                const end = std.mem.findNone(u8, value, num_characters) orelse c.value.len;
                value = value[0..end];
                break :blk true;
            } else blk: {
                const end = std.mem.findNone(u8, c.value, num_characters) orelse value.len;
                value = value[0..end];
                break :blk false;
            };

            try writer.print(
                \\{[comment]f}
                \\{[provider]f}
                \\pub const {[name]f}: {[primitive]s} = {[maybe_negate]s}@as({[primitive]s}, {[value]s});
            ,
                .{
                    .name = name,
                    .primitive = zig_type.toZig(),
                    .maybe_negate = if (negate) "~" else "",
                    .value = value,
                    .provider = provider,
                    .comment = comment,
                },
            );
        }
    }
    fn overrideTypes(registry: *const Registry) void {
        // OVERRIDE
        const ptr = registry.types.getPtr("VkPresentInfoKHR") orelse return;
        switch (ptr.type) {
            .@"struct" => |*s| {
                if (s.members.len == 0) @panic("PresentInfoKHR has no members");
                // This shouldn't go wrong
                const last = @constCast(&s.members[s.members.len - 1]);
                last.c_var.type.base.name = "Command.QueuePresentKHRResult";
            },
            else => @panic("Expected PresentInfoKHR to be a struct"),
        }
    }
    fn printTypes(registry: *const Registry, writer: *Writer) Writer.Error!void {
        var it = registry.types.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            switch (v.type) {
                .flags => try printFlags(registry, name, v, writer),
                .flag_bits => try printFlagBits(name, v, writer),
                .@"enum" => try printEnum(name, v, writer),
                .@"struct" => try printStruct(name, v, registry, writer),
                .@"union" => try printUnion(name, v, writer),
                .handle => try printHandle(name, v, writer),
                .basetype => try printBasetype(name, v, writer),
                .funcpointer => try printFuncpointer(name, v, writer),
                .foreign => try printForeign(name, v, writer),
                .alias => try printAlias(name, v, writer),
            }
        }
    }
    fn printVulkanApiAndBaseTypes(writer: *Writer) Writer.Error!void {
        try writer.print(
            \\const builtin = @import("builtin");
            \\pub const vulkan_api: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86)
            \\    .winapi
            \\else if (builtin.abi == .android and (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()) and std.Target.arm.featureSetHas(builtin.cpu.features, .has_v7) and builtin.cpu.arch.ptrBitWidth() == 32)
            \\    .arm_aapcs_vfp
            \\else
            \\    .c;
            \\  {s}
            \\
        , .{@embedFile("basetypes.zig")});
    }
    pub fn render(registry: *const Registry, writer: *Writer) Writer.Error!void {
        overrideTypes(registry);

        try writer.print(
            \\{s}
            \\pub const raw = struct{{
            \\
        , .{@embedFile("preamble.zig")});
        try printVulkanApiAndBaseTypes(writer);
        try printConstants(registry.constants, writer);
        try printTypes(registry, writer);
        try printCommands(registry, writer);
        try printExtensions(registry, writer);
        try writer.writeAll("};");
        try printVulkanContext(registry, writer);
    }
    fn renderDll(registry: *const Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(@embedFile("preamble.zig"));
        try printVulkanApiAndBaseTypes(writer);
        try printConstants(registry.constants, writer);
        try printTypes(registry, writer);
        var it = registry.commands.iterator();
        while (it.next()) |entry| {
            const DllParams = struct {
                params: []const Registry.ZigVar,

                pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                    for (self.params) |p| {
                        const v: ZigType = .parse(p);
                        try w.print("_: {f},", .{v});
                    }
                }
            };
            const c = entry.value_ptr.*;
            const params: DllParams = .{ .params = c.params };
            const ret: CBaseType = .{ .v = c.ret };
            try writer.print(
                \\pub export fn {[name]s}({[params]f}) callconv(vulkan_api) {[ret]f}{{return undefined;}}
                \\
            , .{ .params = params, .ret = ret, .name = entry.key_ptr.* });
        }
    }
    fn isGlobalCommand(command: Registry.Command, registry: *const Registry) bool {
        if (command.params.len == 0) return true;
        const first = command.params[0];
        const first_type = registry.types.get(first.c_var.type.base.name) orelse return true;
        if (first_type.type != .handle) return true;
        if (!first_type.type.handle.dispatchable) return true;
        return false;
    }
    fn isDispatchableHandle(t: Registry.TypeCommon) bool {
        if (t.type != .handle) return false;
        return t.type.handle.dispatchable;
    }
    fn isDispatchableHandleByTypeName(name: []const u8, registry: *const Registry) bool {
        const t = registry.types.get(name) orelse return false;
        return isDispatchableHandle(t);
    }
    fn isExemptFromCreateCommand(name: []const u8) bool {
        //OVERRIDE: These functions will not be treated as create commands, even though they meet the other criter
        return enumFromName(enum { QueueSignalReleaseImageOHOS }, name) != null;
    }

    fn printVulkanContextCommand(command_name: []const u8, command: Registry.Command, loader: []const u8, writer: *Writer) Writer.Error!void {
        const has_success_codes = command.success_codes.len != 0;
        const only_success_code = std.mem.eql(u8, command.success_codes, "VK_SUCCESS");
        const has_error_codes = blk: {
            var it: CommaIterator = .{ .text = command.error_codes };
            while (it.next()) |code| {
                if (!shouldErrorBeSkipped(code)) break :blk true;
            }
            break :blk false;
        };
        const name: CommandFunctionName = .parseFromText(command_name);
        const is_create_command = blk: {
            if (has_success_codes and !only_success_code) break :blk false;
            if (!((std.mem.eql(u8, command.ret.name, "void") or
                std.mem.eql(u8, command.ret.name, "VkResult")))) break :blk false;
            if (command.params.len == 0) break :blk false;
            const last = command.params[command.params.len - 1];
            if (last.c_var.type.base.ptrs_len == 0) break :blk false;
            if (last.c_var.type.base.ptrs[0] != .mutable) break :blk false;
            if (last.extra[0].optional) break :blk false;
            if (last.extra[0].len != .@"1") break :blk false;
            const n = name.name.name;
            break :blk !isExemptFromCreateCommand(n);
        };

        const ResultDecl = struct {
            enabled: bool,
            success_codes: []const u8,
            name: CommandTypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                if (!self.enabled) return;
                try w.print(
                    \\ pub const {f}Result = enum(@typeInfo(Result).@"enum".tag_type){{
                , .{self.name});
                var it: CommaIterator = .{ .text = self.success_codes };
                while (it.next()) |code| {
                    const n: ConstantName = .parse(code);
                    try w.print("{[name]f} = @intFromEnum(Result.{[name]f}),", .{ .name = n });
                }
                try w.writeAll("};");
            }
        };
        const ErrorName = struct {
            name: []const u8,
            pub fn parse(name_: []const u8) @This() {
                const n = stripPrefix(name_, "VK_");
                return .{ .name = tryStripPrefix(n, "ERROR_") orelse n };
            }
            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                try w.writeAll(self.name);
            }
        };
        const ErrorDecl = struct {
            enabled: bool,
            error_codes: []const u8,
            name: CommandTypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                if (!self.enabled) return;
                try w.print(
                    \\ pub const {f}Error = error{{
                , .{self.name});
                var it: CommaIterator = .{ .text = self.error_codes };
                while (it.next()) |code| {
                    if (shouldErrorBeSkipped(code)) continue;
                    const n: ErrorName = .parse(code);
                    try w.print("{f},", .{n});
                }
                try w.writeAll("};");
            }
        };

        const VCParams = struct {
            params: []const Registry.ZigVar,

            fn isPAllocator(v: Registry.ZigVar) bool {
                const b = v.c_var.type.base;
                if (b.ptrs_len != 1) return false;
                return std.mem.eql(u8, b.name, "VkAllocationCallbacks");
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.params) |p| {
                    if (isPAllocator(p)) continue;
                    const z: ZigVar = .parse(p);
                    try w.print("{f},", .{z});
                }
            }
        };
        const ErrorRet = struct {
            name: ?CommandTypeName,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const n = self.name orelse return;
                try w.print("{f}Error!", .{n});
            }
        };
        const Ret = union(enum) {
            zig_type: ZigType,
            base: CBaseType,
            name: CommandTypeName,

            pub const void_ret: @This() = .{ .base = .{ .v = .{ .name = "void" } } };
            pub fn parseZigVar(zig_var: Registry.ZigVar) @This() {
                return .{ .zig_type = .parse(zig_var) };
            }
            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                switch (self) {
                    .zig_type => |z| try w.print("{f}", .{z}),
                    .base => |b| try w.print("{f}", .{b}),
                    .name => |n| try w.print("{f}Result", .{n}),
                }
            }
        };
        const ParamNames = struct {
            params: []const Registry.ZigVar,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.params) |p| {
                    if (VCParams.isPAllocator(p)) {
                        try w.writeAll("getAllocator()");
                    } else {
                        try w.print(
                            \\@"{s}"
                        , .{p.c_var.name});
                    }
                    try w.writeByte(',');
                }
            }
        };
        const SwitchProngs = struct {
            enabled: bool,
            success_codes: ?[]const u8,
            error_codes: []const u8,
            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                if (!self.enabled) return;
                try w.writeAll("){");
                if (self.success_codes) |codes| {
                    var it: CommaIterator = .{ .text = codes };
                    while (it.next()) |code| {
                        const n: ConstantName = .parse(code);
                        try w.print(".{[name]f} => .{[name]f},", .{ .name = n });
                    }
                } else {
                    try w.writeAll(".SUCCESS => temp,");
                }
                var it: CommaIterator = .{ .text = self.error_codes };
                while (it.next()) |code| {
                    if (shouldErrorBeSkipped(code)) continue;
                    const res: ConstantName = .parse(code);
                    const n: ErrorName = .parse(code);
                    try w.print(".{[res]f} => error.{[name]f},", .{ .res = res, .name = n });
                }
                try w.writeByte('}');
            }
        };
        const MaybeTempRef = struct {
            name: ?[]const u8,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const n = self.name orelse return;
                try w.print("const {s} = &temp;", .{n});
            }
        };
        var last_param: Registry.ZigVar = undefined;
        if (is_create_command) {
            last_param = command.params[command.params.len - 1];
        }
        const result_decl: ResultDecl = .{
            .enabled = has_success_codes and !only_success_code,
            .success_codes = command.success_codes,
            .name = name.name,
        };
        const error_decl: ErrorDecl = .{
            .enabled = has_error_codes,
            .error_codes = command.error_codes,
            .name = name.name,
        };
        const provider: Provider = .{ .p = command.providers };
        const params: VCParams = .{
            .params = if (is_create_command)
                command.params[0 .. command.params.len - 1]
            else
                command.params,
        };
        const error_ret: ErrorRet = .{ .name = if (has_error_codes) name.name else null };
        const ret: Ret =
            if (is_create_command) blk: {
                last_param.c_var.type.base.ptrs_len -= 1;
                break :blk .parseZigVar(last_param);
            } else if (has_success_codes) blk: {
                break :blk if (only_success_code)
                    Ret.void_ret
                else
                    .{ .name = name.name };
            } else .{ .base = .{ .v = command.ret } };
        const param_names: ParamNames = .{ .params = command.params };
        const switch_prongs: SwitchProngs = .{
            .enabled = has_success_codes,
            .success_codes = if (only_success_code) null else command.success_codes,
            .error_codes = command.error_codes,
        };
        const maybe_temp_ref: MaybeTempRef = .{
            .name = if (is_create_command) last_param.c_var.name else null,
        };
        try writer.print(
            \\{[result_decl]f}
            \\{[error_decl]f}
            \\{[provider]f}
            \\pub fn {[name]f}(
            \\{[params]f}
            \\) {[error_ret]f}{[ret]f} {{
            \\assertDependencies(.{[name]f});
            \\var temp: {[ret]f} = undefined;
            \\maybeUnused(&temp);
            \\{[maybe_temp_ref]f}
            \\return {[maybe_switch]s}{[loader]s}.{[name]f}(
            \\  {[param_names]f}
            \\){[switch_prongs]f};
            \\}}
        , .{
            .result_decl = result_decl,
            .error_decl = error_decl,
            .provider = provider,
            .name = name,
            .params = params,
            .error_ret = error_ret,
            .ret = ret,
            .maybe_temp_ref = maybe_temp_ref,
            .maybe_switch = if (has_success_codes) "switch(" else "",
            .loader = loader,
            .param_names = param_names,
            .switch_prongs = switch_prongs,
        });
    }
    fn referenceRawBasetypes(writer: *Writer) Writer.Error!void {
        const basetypes: []const []const u8 = &.{
            "vulkan_api",
            "Bool32",
            "ApiVersion",
            "DeviceSize",
            "DeviceAddress",
            "SampleMask",
            "RemoteAddressNV",
            "Display",
            "VisualID",
            "Window",
            "RROutput",
            "wl_display",
            "wl_surface",
            "HINSTANCE",
            "HWND",
            "HMONITOR",
            "HANDLE",
            "SECURITY_ATTRIBUTES",
            "DWORD",
            "LPCWSTR",
            "xcb_connection_t",
            "xcb_visualid_t",
            "xcb_window_t",
            "zx_handle_t",
            "_screen_context",
            "_screen_window",
            "_screen_buffer",
            "IDirectFB",
            "IDirectFBSurface",
            "NvSciSyncAttrList",
            "NvSciSyncObj",
            "NvSciSyncFence",
            "NvSciBufAttrList",
            "NvSciBufObj",
            "GgpStreamDescriptor",
            "GgpFrameToken",
            "StdVideoVP9Profile",
            "StdVideoVP9Level",
            "ANativeWindow",
            "AHardwareBuffer",
            "CAMetalLayer",
            "MTLDevice_id",
            "MTLCommandQueue_id",
            "MTLBuffer_id",
            "MTLTexture_id",
            "MTLSharedEvent_id",
            "IOSurfaceRef",
            "OHNativeWindow",
            "OHBufferHandle",
            "OH_NativeBuffer",
            "ubm_device",
            "ubm_surface",
        };
        for (basetypes) |b| {
            try writer.print("pub const {[name]s} = raw.{[name]s};", .{ .name = b });
        }
    }
    fn printVulkanContext(registry: *const Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\pub const VulkanContextConfig = struct{
            \\  pub const Globals = enum{
            \\      load_time,
            \\      run_time,
            \\  };
            \\  pub const AllocatorConfig = union(enum){
            \\      compile_time: ?*const raw.AllocationCallbacks,
            \\      run_time,
            \\  };
            \\ globals: Globals = .load_time,
            \\ commands: []const raw.Command,
            \\ apiVersion: raw.ApiVersion = .{ .minor = 0 },
            \\ extensions: []const raw.Extension = &.{},
            \\ allocator: AllocatorConfig = .{ .compile_time = null },
            \\};
            \\pub fn VulkanContext(comptime config_: VulkanContextConfig) type{
            \\  return struct{
            \\      pub const config = config_;
            \\      pub const Extension = raw.Extension;
            \\      comptime{ 
            \\          if(Extension.missingDependenciesFor(config.extensions, config.apiVersion)) |e|{
            \\              const text = std.fmt.comptimePrint(
            \\                  \\Missing dependencies for extension: {t}
            \\                  \\Required:
            \\                  \\{s}
            \\                  \\Provided:
            \\                  \\{f}
            \\                  \\
            \\          ,.{e, e.getDependenciesText(), provided_extensions});
            \\              @compileError(text);
            \\          }
            \\      }
            \\      pub const extensions = Extension.getFilteredVkNames(config.extensions);
            \\      pub const loaded_commands = blk:{
            \\          var res: [config.commands.len]Command = undefined;
            \\          for(&res, config.commands) |*d, s| d.* = @enumFromInt(@intFromEnum(s));
            \\          break :blk res;
            \\      };
            \\      var runtime_allocator: switch(config.allocator){
            \\          .compile_time => void,
            \\          .run_time =>?*const AllocationCallbacks,
            \\      } = undefined;
            \\      pub fn initAllocator(pAllocator: ?*const AllocationCallbacks) void{
            \\          runtime_allocator = pAllocator;
            \\      }
            \\      pub fn getAllocator()?*const AllocationCallbacks{
            \\          return switch(comptime config.allocator){
            \\              .compile_time => |a| @ptrCast(a),
            \\              .run_time => runtime_allocator,
            \\          };
            \\      }
            \\      pub const ThisLoader = Loader(switch(config.globals){
            \\          .load_time => blk:{ 
            \\              const filtered = Command.filter(&loaded_commands);
            \\              break :blk filtered.instance ++ filtered.device;
            \\          },
            \\          .run_time => &loaded_commands,
            \\      });
            \\      pub var loader: ThisLoader = undefined;
            \\      
            \\      pub fn initGlobalCommands(load_function: anytype) void{
            \\          switch(comptime config.globals){
            \\              .load_time => {},
            \\              .run_time => loader.initGlobalCommands(load_function),
            \\          }
            \\      }
            \\      pub fn getSpecializedGetInstanceProcAddr(instance: Instance) ?*const fn(Instance, [*:0]const u8) callconv(vulkan_api) PfnVoidFunction{
            \\          return @ptrCast(extern_commands.getInstanceProcAddr(instance,Command.getInstanceProcAddr.getVkName()));
            \\      }
            \\      pub fn initInstanceCommands(load_function: anytype, instance: Instance) void{
            \\          loader.initInstanceCommands(load_function, instance);
            \\      }
            \\      pub fn initDeviceCommands(load_function: anytype, device: Device) void{
            \\          loader.initDeviceCommands(load_function, device);
            \\      }
            \\      pub fn initDeviceCommandsFromGetInstanceProcAddr(get_instance_proc_addr: anytype, instance: Instance, device: Device) void {
            \\          const com: Command = .getDeviceProcAddr;
            \\          const raw_get_device_proc_addr: com.GetPtrType() = @ptrCast(get_instance_proc_addr(instance, com.getVkName()));
            \\          const get_device_proc_addr: com.GetPtrType() = @ptrCast(raw_get_device_proc_addr.?(device, com.getVkName()));
            \\          loader.initDeviceCommands(get_device_proc_addr.?, justFreakingCastTheThing(device, Device));
            \\      }
            \\              const provided_extensions: CommandDependencyRequirements = .{
            \\                  .version = config.apiVersion,
            \\                  .extensions = config.extensions,
            \\              };
            \\      fn assertDependencies(comptime cmd: Command) void{
            \\          comptime{
            \\              const requirements = cmd.requirements();
            \\              if(!provided_extensions.satisfies(requirements)){
            \\              const text = std.fmt.comptimePrint(
            \\                  \\
            \\                  \\Requirements not met for command: {t}
            \\                  \\Required:
            \\                  \\{f}
            \\                  \\
            \\                  \\Provided:
            \\                  \\{f}
            \\                  \\
            \\                  , .{cmd, requirements, provided_extensions});
            \\                  
            \\                  @compileError(text);
            \\              }
            \\          }
            \\      }
        );
        {
            var it = registry.constants.iterator();
            while (it.next()) |c| {
                const n: ConstantName = .parse(c.key_ptr.*);
                try writer.print("pub const {[name]f} = raw.{[name]f};", .{ .name = n });
            }
        }
        try referenceRawBasetypes(writer);
        {
            var it = registry.types.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const v = entry.value_ptr.*;
                switch (v.type) {
                    .flags => try printFlags(registry, name, v, writer),
                    .flag_bits => try printFlagBits(name, v, writer),
                    .@"enum" => try printEnum(name, v, writer),
                    .@"struct" => try printStruct(name, v, registry, writer),
                    .@"union" => try printUnion(name, v, writer),
                    .handle => |h| {
                        if (!h.dispatchable) try printHandle(name, v, writer);
                    },
                    .basetype => try printBasetype(name, v, writer),
                    .funcpointer => try printFuncpointer(name, v, writer),
                    .foreign => try printForeign(name, v, writer),
                    .alias => try printAlias(name, v, writer),
                }
            }
        }

        try writer.writeAll("pub const globals = struct{");
        var it = registry.commands.iterator();
        while (it.next()) |entry| {
            if (!isGlobalCommand(entry.value_ptr.*, registry)) continue;
            const global_loader =
                \\switch(comptime config.globals){
                \\  .load_time => extern_commands,
                \\  .run_time => loader,
                \\}
            ;
            try printVulkanContextCommand(
                entry.key_ptr.*,
                entry.value_ptr.*,
                global_loader,
                writer,
            );
        }
        try writer.writeAll("};");

        var types_it = registry.types.iterator();
        while (types_it.next()) |t| {
            if (!isDispatchableHandle(t.value_ptr.*)) continue;
            const name: TypeName = .parse(t.key_ptr.*);
            try writer.print(
                \\pub const {[name]f} = enum(usize){{
                \\_,
                \\
            , .{ .name = name });
            it = registry.commands.iterator();
            while (it.next()) |command_entry| {
                const command = command_entry.value_ptr.*;
                if (command.params.len == 0) continue;
                const first = command.params[0];
                if (!std.mem.eql(u8, t.key_ptr.*, first.c_var.type.base.name)) continue;
                try printVulkanContextCommand(
                    command_entry.key_ptr.*,
                    command,
                    "loader",
                    writer,
                );
            }
            try writer.writeAll("};");
        }

        try printCommands(registry, writer);
        try writer.writeAll("};}");
    }

    fn printExtensions(registry: *const Registry, writer: *Writer) Writer.Error!void {
        const ExtensionList = struct {
            list: []const Registry.Extension,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.list) |e| {
                    const n: ExtensionName = .parse(e.name);
                    const promoted_preamble: []const u8 = if (e.promoted) |_| "/// Promoted to" else "";
                    const promoted: []const u8 = if (e.promoted) |p| p else "";
                    try w.print(
                        \\
                        \\{[promoted_preamble]s}{[promoted]s}
                        \\{[dependencies_preamble]s}{[dependencies]s}
                        \\/// {[kind]t} extension
                        \\{[name]f},
                        \\
                    , .{
                        .name = n,
                        .promoted_preamble = promoted_preamble,
                        .promoted = promoted,
                        .dependencies_preamble = if (e.depends) |_| "/// Depends on " else "",
                        .dependencies = if (e.depends) |d| d else "",
                        .kind = e.kind,
                    });
                }
            }
        };
        const ExtensionTypes = struct {
            list: []const Registry.Extension,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.list) |e| {
                    const n: ExtensionName = .parse(e.name);
                    try w.print(
                        \\.{[name]f} => .{[kind]t},
                    , .{
                        .name = n,
                        .kind = e.kind,
                    });
                }
            }
        };
        const ExtensionDependencies = struct {
            list: []const Registry.Extension,

            const Depends = struct {
                depends: ?[]const u8,

                pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                    if (self.depends) |dep| {
                        try printDependencies(dep, w);
                    } else {
                        try w.writeAll("true");
                    }
                }
            };

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.list) |e| {
                    const n: ExtensionName = .parse(e.name);
                    const dependencies: Depends = .{ .depends = e.depends };
                    try w.print(
                        \\.{[name]f} => {[dependencies]f},
                    , .{
                        .name = n,
                        .dependencies = dependencies,
                    });
                }
            }
        };
        const ExtensionDependenciesText = struct {
            list: []const Registry.Extension,

            const Depends = struct {
                depends: ?[]const u8,

                pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                    if (self.depends) |dep| {
                        try printDependencies(dep, w);
                    } else {
                        try w.writeAll("None");
                    }
                }
            };

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.list) |e| {
                    const n: ExtensionName = .parse(e.name);
                    const dependencies: Depends = .{ .depends = e.depends };
                    try w.print(
                        \\.{[name]f} => "{[dependencies]f}",
                    , .{
                        .name = n,
                        .dependencies = dependencies,
                    });
                }
            }
        };
        const extension_list: ExtensionList = .{ .list = registry.extensions };
        const extension_types: ExtensionTypes = .{ .list = registry.extensions };
        const extension_dependencies: ExtensionDependencies = .{ .list = registry.extensions };
        const extension_dependencies_text: ExtensionDependenciesText = .{ .list = registry.extensions };
        const conv_funcs =
            \\pub fn getVkName(comptime self: @This()) [*:0]const u8{
            \\  const result = comptime "VK_" ++ @tagName(self);
            \\  return result;
            \\}
            \\pub fn getVkNames(comptime extensions: []const @This()) []const [*:0]const u8{
            \\  const result = comptime blk: {
            \\      var result: [extensions.len][*:0]const u8 = undefined;
            \\      for(&result, extensions) |*r, e| r.* = e.getVkName();
            \\      break :blk result;
            \\  };
            \\  return &result;
            \\}
            \\pub fn filter(comptime extensions: []const @This(), comptime @"type": Type) []const @This(){
            \\  var result: [extensions.len]@This() = undefined;
            \\  var count = 0;
            \\  for(extensions) |e| if(e.getType() == @"type") {
            \\      result[count] = e;
            \\      count += 1;
            \\  };
            \\  const final = result[0..count].*;
            \\  return &final;
            \\}
            \\
            \\/// Returns the first extension found for which there are missing dependencies.
            \\/// If all dependencies are satified, returns `null`
            \\pub fn missingDependenciesFor(ext: []const @This(), apiVersion: ApiVersion) ?@This(){
            \\  const bitmask:Bitmask = .initMany(ext);
            \\  for(ext) |e| if(!e.isSatisfied(apiVersion, bitmask)) return e;
            \\  return null;
            \\}
            \\/// Whether `self` is contained in `extensions`
            \\pub fn containedIn(self:@This(),extensions:[]const @This())bool{
            \\  for(extensions)|e| if(e == self) return true;
            \\  return false;
            \\}
            \\pub const Names = struct{ device: []const [*:0]const u8, instance: []const [*:0] const u8};
            \\pub fn getFilteredVkNames(comptime ext: []const @This()) Names{
            \\  return .{ .device = getVkNames(filter(ext, .device)), .instance = getVkNames(filter(ext,.instance)),};
            \\}
        ;
        try writer.print(
            \\pub const Extension = enum{{
            \\{[extension_list]f}
            \\  pub const Type = enum{{device, instance}};
            \\  pub fn getType(self: @This()) Type{{
            \\      return switch(self){{
            \\{[extension_types]f}
            \\}};
            \\}}
            \\const Bitmask = std.enums.EnumSet(@This());
            \\fn isSatisfied(self: @This(), apiVersion: ApiVersion, bitmask: Bitmask) bool{{
            \\  maybeUnused(.{{apiVersion, bitmask}});
            \\  return switch(self) {{
            \\  {[extension_dependencies]f}
            \\  }};
            \\}}
            \\fn getDependenciesText(self: @This()) []const u8{{
            \\  return switch(self) {{
            \\  {[dependencies_text]f}
            \\  }};
            \\}}
            \\{[conv_funcs]s}
            \\}};
        , .{
            .extension_list = extension_list,
            .extension_types = extension_types,
            .extension_dependencies = extension_dependencies,
            .dependencies_text = extension_dependencies_text,
            .conv_funcs = conv_funcs,
        });
    }
    fn printDependencies(dependencies: []const u8, writer: *Writer) Writer.Error!void {
        var d = dependencies;
        while (d.len != 0) {
            sw: switch (d[0]) {
                '(', ')' => |l| {
                    try writer.writeByte(l);
                    continue :sw ' ';
                },
                '+' => {
                    try writer.writeAll(" and ");
                    continue :sw ' ';
                },
                ',' => {
                    try writer.writeAll(" or ");
                    continue :sw ' ';
                },
                ' ' => {
                    d = d[1..];
                },
                else => {
                    const end = std.mem.findAny(u8, d, "()+, ") orelse d.len;
                    const word = d[0..end];
                    if (std.mem.startsWith(u8, word, "VK_VERSION_")) {
                        const last = std.mem.findScalarLast(u8, word, '_') orelse panic("Missing last `_` for: {s}", .{word});
                        try writer.print("apiVersion.ge(.{{.minor={s}}})", .{word[last + 1 ..]});
                    } else {
                        try writer.print("bitmask.contains(.{s})", .{stripPrefix(word, "VK_")});
                    }
                    d = d[end..];
                },
            }
        }
    }

    fn shouldErrorBeSkipped(name: []const u8) bool {
        // OVERRIDE: Skipping undefined behavior errors
        if (enumFromName(enum { VK_ERROR_UNKNOWN, VK_ERROR_VALIDATION_FAILED }, name)) |_| return true;
        return false;
    }

    pub fn printCommands(registry: *const Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\
            \\/// Any of these is sufficient to satisfy command requirements
            \\pub const CommandDependencyRequirements = struct{
            \\  version: ApiVersion,
            \\  extensions: []const Extension,
            \\  pub fn satisfies(self: @This(), requirements: @This()) bool{
            \\      if(self.version.ge(requirements.version)) return true;
            \\      for(requirements.extensions) |e| if(e.containedIn(self.extensions)) return true;
            \\      return false;
            \\  }
            \\  pub fn format(self: @This(), writer: *std.Io.Writer) !void{
            \\      try writer.writeAll("version: ");
            \\      if(self.version.minor == 
        ++ no_version ++
            \\){
            \\          try writer.writeAll("No version");
            \\      } else {
            \\          try writer.print("version: {}.{}", .{self.version.major, self.version.minor});
            \\      }
            \\      try writer.writeAll(
            \\          \\
            \\          \\extensions:
            \\          \\
            \\      );
            \\      if(self.extensions.len == 0){
            \\          try writer.writeAll("None");
            \\      }else for(Extension.getVkNames(self.extensions)) |name|{
            \\          try writer.print("{s}\n", .{name});
            \\      }
            \\  }
            \\};
        );
        try printExternFunctions(registry, writer);
        try printCommandGroup(registry, writer);
    }

    const CommandTypeName = struct {
        name: []const u8,
        pub fn parse(name: []const u8) @This() {
            return .{ .name = stripPrefix(name, "vk") };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    const CommandFunctionName = struct {
        name: CommandTypeName,

        pub fn parse(name: CommandTypeName) @This() {
            if (name.name.len == 0) @panic("Empty command name");
            return .{ .name = name };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{c}{s}", .{ std.ascii.toLower(self.name.name[0]), self.name.name[1..] });
        }
        pub fn parseFromText(name: []const u8) @This() {
            return .parse(.parse(name));
        }
    };
    const ConstantName = struct {
        name: []const u8,

        pub fn parse(name: []const u8) @This() {
            return .{ .name = tryStripPrefix(name, "VK_") orelse stripPrefix(name, "STD_VIDEO_") };
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    const ExtensionName = struct {
        name: []const u8,
        pub fn parse(name: Registry.ExtensionName) @This() {
            return .{ .name = stripPrefix(name.name, "VK_") };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    fn printExternFunctions(registry: *const Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\
            \\/// Provides commands as load-time loaded functions.
            \\pub const extern_commands = struct{
        );
        var it = registry.commands.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const command = entry.value_ptr.*;
            const provider: Provider = .{ .p = command.providers };
            const command_name: CommandFunctionName = .parseFromText(name);
            const params: Params = .{ .params = command.params };
            try writer.print(
                \\extern "vulkan-1" fn {[raw_name]s}(
                \\{[params]f}
                \\) callconv(vulkan_api) Command.{[name]f}.GetReturnType();
                \\{[provider]f}
                \\pub const {[name]f} = {[raw_name]s};
            , .{
                .provider = provider,
                .name = command_name,
                .raw_name = name,
                .params = params,
            });
        }
        try writer.writeAll("};");
    }
    pub fn printCommandGroup(registry: *const Registry, writer: *Writer) Writer.Error!void {
        const CommandReturnType = union(enum) {
            codes: CommandTypeName,
            base: CBaseType,

            pub fn parse(command_name: CommandTypeName, command: Registry.Command) @This() {
                return if (command.success_codes.len != 0)
                    .{ .codes = command_name }
                else
                    .{ .base = .{ .v = command.ret } };
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                switch (self) {
                    .base => |b| try w.print("{f}", .{b}),
                    .codes => |codes| try w.print("{f}Result", .{codes}),
                }
            }
        };

        const CommandReturnTypeDeclaration = union(enum) {
            empty,
            codes: Codes,

            const Codes = struct {
                error_codes: []const u8,
                success_codes: []const u8,
                command_name: CommandTypeName,
            };

            pub fn parse(command_name: CommandTypeName, command: Registry.Command) @This() {
                return if (command.success_codes.len != 0)
                    .{ .codes = .{
                        .command_name = command_name,
                        .error_codes = command.error_codes,
                        .success_codes = command.success_codes,
                    } }
                else
                    .empty;
            }
            fn printCode(name: []const u8, w: *Writer) Writer.Error!void {
                const n: ConstantName = .parse(name);
                try w.print(
                    \\{[name]f} = @intFromEnum(Result.{[name]f}),
                , .{ .name = n });
            }
            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                switch (self) {
                    .empty => {},
                    .codes => |codes| {
                        try w.print(
                            \\pub const {f}Result = enum(@typeInfo(Result).@"enum".tag_type){{
                        , .{codes.command_name});
                        var it: CommaIterator = .{ .text = codes.success_codes };
                        while (it.next()) |c| {
                            try printCode(c, w);
                        }

                        it = .{ .text = codes.error_codes };
                        while (it.next()) |c| {
                            if (shouldErrorBeSkipped(c)) continue;
                            try printCode(c, w);
                        }
                        try w.writeAll("};");
                    }
                }
            }
        };

        const it = registry.commands.iterator();
        const Iterator = @TypeOf(it);
        const CommandList = struct {
            commands: Iterator,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                var i = self.commands;
                while (i.next()) |entry| {
                    const command = entry.value_ptr.*;
                    const command_name = entry.key_ptr.*;
                    const provider: Provider = .{ .p = command.providers };
                    const name: CommandFunctionName = .parseFromText(command_name);
                    try w.print(
                        \\{[provider]f}
                        \\{[name]f},
                    , .{ .name = name, .provider = provider });
                }
            }
        };
        const CommandSignatureType = struct {
            command_name: CommandTypeName,
            ret_declaration: CommandReturnTypeDeclaration,
            ret: CommandReturnType,
            params: Params,
            provider: Provider,

            pub fn parse(name: []const u8, command: Registry.Command) @This() {
                const command_name: CommandTypeName = .parse(name);
                const ret_declaration: CommandReturnTypeDeclaration = .parse(command_name, command);
                const ret: CommandReturnType = .parse(command_name, command);
                const params: Params = .{ .params = command.params };
                return .{
                    .command_name = command_name,
                    .ret_declaration = ret_declaration,
                    .ret = ret,
                    .params = params,
                    .provider = .{ .p = command.providers },
                };
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                try w.print(
                    \\{[ret_declaration]f}
                    \\{[provider]f}
                    \\pub const {[command_name]f} = fn(
                    \\{[params]f}
                    \\) callconv(vulkan_api) {[ret]f};
                , self);
            }
        };

        const CommandSignatureTypeGroup = struct {
            commands: Iterator,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                var i = self.commands;
                while (i.next()) |entry| {
                    const command = entry.value_ptr.*;
                    const command_name = entry.key_ptr.*;
                    const s: CommandSignatureType = .parse(command_name, command);
                    try w.print("{f}", .{s});
                }
            }
        };
        const Requirement = struct {
            name: CommandFunctionName,
            version: []const u8,
            extensions: ExtensionList,

            const ExtensionList = struct {
                extensions: []const Registry.ExtensionName,

                pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                    for (self.extensions) |e| {
                        const n: ExtensionName = .parse(e);
                        try w.print(".{f},", .{n});
                    }
                }
            };

            pub fn parse(command_name: CommandFunctionName, providers: Registry.Providers) @This() {
                return .{
                    .name = command_name,
                    .version = if (providers.version) |v|
                        stripPrefix(v.number, "1.")
                    else
                        no_version,
                    .extensions = .{ .extensions = providers.extensions },
                };
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                try w.print(
                    \\.{[name]f} => .{{ 
                    \\  .version = .{{ .minor = {[version]s} }},
                    \\  .extensions = &.{{ {[extensions]f} }},
                    \\}},
                , .{
                    .name = self.name,
                    .version = self.version,
                    .extensions = self.extensions,
                });
            }
        };
        const Requirements = struct {
            commands: Iterator,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                try w.writeAll(
                    \\pub fn requirements(self: @This()) CommandDependencyRequirements{
                    \\    return switch(self) {
                );
                var i = self.commands;
                while (i.next()) |entry| {
                    const command = entry.value_ptr.*;
                    const command_name = entry.key_ptr.*;
                    const req: Requirement = .parse(.parseFromText(command_name), command.providers);
                    try w.print("{f}", .{req});
                }

                try w.writeAll(
                    \\  };
                    \\}
                );
            }
        };
        const ParamNames = struct {
            params: Params,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.params.params) |v| {
                    try w.print(
                        \\@"{s}",
                    , .{v.c_var.name});
                }
            }
        };
        const LoaderCommandReturnType = struct {
            base: CommandReturnType,

            pub fn parse(command_name: CommandTypeName, command: Registry.Command) @This() {
                return .{ .base = .parse(command_name, command) };
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                switch (self.base) {
                    .base => |b| try w.print("{f}", .{b}),
                    .codes => |codes| try w.print("Command.{f}Result", .{codes}),
                }
            }
        };
        const CommandLoaderDeclaration = struct {
            command_name: CommandFunctionName,
            ret: LoaderCommandReturnType,
            params: Params,
            provider: Provider,

            pub fn parse(name: []const u8, command: Registry.Command) @This() {
                const command_name: CommandFunctionName = .parseFromText(name);
                const ret: LoaderCommandReturnType = .parse(command_name.name, command);
                const params: Params = .{ .params = command.params };
                return .{
                    .command_name = command_name,
                    .ret = ret,
                    .params = params,
                    .provider = .{ .p = command.providers },
                };
            }

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const param_names: ParamNames = .{ .params = self.params };
                try w.print(
                    \\{[provider]f}
                    \\pub fn {[command_name]f}(
                    \\  self: *const @This(),
                    \\  {[params]f}
                    \\) {[ret]f}{{
                    \\return self.ptrs.{[command_name]f}.?(
                    \\{[param_names]f}
                    \\);
                    \\}}
                , .{
                    .provider = self.provider,
                    .command_name = self.command_name,
                    .params = self.params,
                    .ret = self.ret,
                    .param_names = param_names,
                });
            }
        };

        const CommandLoaderDeclarationGroup = struct {
            commands: Iterator,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                var i = self.commands;
                while (i.next()) |entry| {
                    const command = entry.value_ptr.*;
                    const command_name = entry.key_ptr.*;
                    const s: CommandLoaderDeclaration = .parse(command_name, command);
                    try w.print("{f}", .{s});
                }
            }
        };

        const signature_group: CommandSignatureTypeGroup = .{ .commands = it };
        const command_list: CommandList = .{ .commands = it };
        const requirements: Requirements = .{ .commands = it };
        const declaration_group: CommandLoaderDeclarationGroup = .{ .commands = it };
        const conv_functions =
            \\pub fn GetType(comptime self: @This()) type{
            \\const t = @tagName(self);
            \\const c: [1]u8 = .{std.ascii.toUpper(t[0])};
            \\return @field(@This(), c ++ t[1..]);
            \\}
            \\pub fn GetPtrType(comptime self: @This()) type{
            \\return ?*const self.GetType();
            \\}
            \\pub fn GetReturnType(comptime self: @This()) type{
            \\return @typeInfo(self.GetType()).@"fn".return_type.?;
            \\}
            \\pub fn GetParamType(comptime self: @This(), comptime param_index: usize) type{
            \\return @typeInfo(self.GetType()).@"fn".params[param_index].type.?;
            \\}
            \\pub fn getVkName(comptime self: @This()) [*:0]const u8{
            \\  const result = comptime blk:{
            \\      const t = @tagName(self);
            \\      const c: [1]u8 = .{std.ascii.toUpper(t[0])};
            \\      break :blk "vk" ++ c ++ t[1..];
            \\  };
            \\  return result;
            \\}
            \\pub fn getVkNames(comptime funcs: []const @This()) []const [*:0]const u8{
            \\  const result = comptime blk: {
            \\      var result: [funcs.len][*:0]const u8 = undefined;
            \\      for (funcs, &result) |f, *r| r.* = f.getVkName();
            \\      break :blk result;
            \\  };
            \\  return &result;
            \\}
            \\pub fn isSatisfied(command: @This(), provided: CommandDependencyRequirements) bool{
            \\    return provided.satifies(command.requirements());
            \\}
            \\pub const LoaderType = enum{ global, instance, device };
            \\pub fn loaderType(self: @This()) LoaderType{
            \\    const Type = self.GetType();
            \\    const info = @typeInfo(Type).@"fn";
            \\    if(info.param_types.len == 0) return .global;
            \\    const first = info.param_types[0].?;
            \\    if(!isDispatchableHandle(first)) return .global;
            \\    if(first == Instance or first == PhysicalDevice) return .instance;
            \\    return .device;
            \\}
            \\pub const Filtered = struct {
            \\    global: []const Command,
            \\    instance: []const Command,
            \\    device: []const Command,
            \\};
            \\pub fn filter(comptime funcs: []const Command) Filtered {
            \\    var result: Filtered = .{
            \\        .global = &.{},
            \\        .instance = &.{},
            \\        .device = &.{},
            \\    };
            \\    for (funcs) |f| switch (f.loaderType()) {
            \\        .global => {
            \\            result.global = result.global ++ [1]Command{f};
            \\        },
            \\        .instance => {
            \\            result.instance = result.instance ++ [1]Command{f};
            \\        },
            \\        .device => {
            \\            result.device = result.device ++ [1]Command{f};
            \\        },
            \\    };
            \\    return result;
            \\}
            \\/// Generates an extern struct where each field has the name of the 
            \\/// corresponding `Command`, in the same order as provided, with the
            \\/// type as an optional pointer to the corresponding command.
            \\pub fn AsPointers(comptime funcs: []const Command) type {
            \\    var types: [funcs.len]type = undefined;
            \\    var names: [funcs.len][]const u8 = undefined;
            \\    const attr: [funcs.len]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
            \\    for (funcs, &types, &names) |f, *t, *n| {
            \\        t.* = f.GetPtrType();
            \\        n.* = @tagName(f);
            \\    }
            \\    return @Struct(.@"extern", null, &names, &types, &attr);
            \\}
        ;
        const loader_preamble =
            \\pub fn Loader(commands: []const Command) type{
            \\return struct{
            \\      pub const filtered_commands = Command.filter(commands);
            \\      const global_count = filtered_commands.global.len;
            \\      const instance_count = filtered_commands.instance.len;
            \\      const device_count = filtered_commands.device.len;
            \\      pub const Ptrs = Command.AsPointers(filtered_commands.global ++ filtered_commands.instance ++ filtered_commands.device);
            \\      ptrs: Ptrs,
            \\
            \\      fn getNames(comptime start: usize, comptime len: usize) [len][*:0]const u8 {
            \\          const names =  comptime blk:{
            \\              var names: [len][*:0]const u8 = undefined;
            \\              for (&names, commands[start..][0..len]) |*n, c| {
            \\                  const tag_name = @tagName(c);
            \\                  const char: [1]u8 = .{std.ascii.toUpper(tag_name[0])};
            \\                  n.* = "vk" ++ char ++ tag_name[1..];
            \\              }
            \\              break :blk names;
            \\          };
            \\          return names;
            \\      }
            \\      fn getPtrs(self: *@This(), comptime start: usize, comptime len: usize) *[len]PfnVoidFunction{
            \\          const ptrs: *[commands.len]PfnVoidFunction = @ptrCast(&self.ptrs);
            \\          return ptrs.*[start..][0..len];
            \\      }
            \\      fn FirstParam(comptime L: type) type{
            \\          return sw: switch(@typeInfo(L)){
            \\              .@"fn" => |f| f.param_types[0].?,
            \\              .pointer => |p| continue :sw @typeInfo(p.child),
            \\              else => @compileError("loader function is incompatible"),
            \\          };
            \\      }
            \\      pub fn initGlobalCommands(self: *@This(), load_function: anytype) void{
            \\          const ptrs = self.getPtrs(0, global_count);
            \\          const names = comptime getNames(0, global_count);
            \\          const Param = FirstParam(@TypeOf(load_function));
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = load_function(justFreakingCastTheThing(Instance.null_handle, Param), name);
            \\          }
            \\      }
            \\      pub fn initInstanceCommands(self: *@This(), load_function: anytype, instance: Instance) void{
            \\          const ptrs = self.getPtrs(global_count, instance_count);
            \\          const names = comptime getNames(global_count, instance_count);
            \\          const Param = FirstParam(@TypeOf(load_function));
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = load_function(justFreakingCastTheThing(instance, Param), name);
            \\          }
            \\      }
            \\      pub fn initDeviceCommands(self: *@This(), load_function: anytype, device: Device) void{
            \\          const ptrs = self.getPtrs(global_count + instance_count, device_count);
            \\          const names = getNames(global_count + instance_count, device_count);
            \\          const Param = FirstParam(@TypeOf(load_function));
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = load_function(justFreakingCastTheThing(device, Param), name);
            \\          }
            \\      }
        ;

        try writer.print(
            \\pub const Command = enum{{
            \\{[command_list]f}
            \\pub const all_commands = std.enums.values(@This());
            \\{[command_signatures]f}
            \\{[conv_functions]s}
            \\{[requirements]f}
            \\}};
            \\{[loader_preamble]s}
            \\{[declaration_group]f}
            \\}};
            \\}}
        , .{
            .command_list = command_list,
            .command_signatures = signature_group,
            .conv_functions = conv_functions,
            .requirements = requirements,
            .loader_preamble = loader_preamble,
            .declaration_group = declaration_group,
        });
    }
};

fn openFile(cwd: Io.Dir, io: Io, path: []const u8, options: Io.Dir.OpenFileOptions) Io.File {
    if (cwd.openFile(io, path, options)) |file|
        return file
    else |e| switch (e) {
        error.FileNotFound => if (std.Io.Dir.openFileAbsolute(io, path, options)) |file|
            return file
        else |er| switch (er) {
            error.FileNotFound => panic("File not found: {s}", .{path}),
            else => |err| panic("Error opening file: {s}. Error: {}", .{ path, err }),
        },
        else => |er| {
            panic("Error opening file: {s}. Error: {}", .{ path, er });
        },
    }
}
fn parseFile(registry: *Registry, reader: *Reader, allocator: Allocator) void {
    const xml = XmlNode.parseChildren(reader, allocator) catch |e| switch (e) {
        error.OutOfMemory => @panic("oom"),
        error.ReadFailed => @panic("Failed to parse inputs"),
        error.EndOfStream => @panic("File ended unexpectedly"),
    };
    registry.parse(xml);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var api: Registry.Api = .vulkan;
    var registry_file: [2]Io.File = undefined;
    var registry_file_count: u2 = 0;
    var output: ?Io.File = null;
    var dll: ?Io.File = null;
    var debug = false;

    const usage =
        \\Usage:
        \\-api:         vulkan or vulkansc
        \\-registry:    Path to registry file. Can be used between 0 and 2 times. Use for vk.xml and/or video.xml,
        \\              order doesn't matter. Both xml files can also be concatenated into a single file.
        \\              If this flag is not provided, registry is obtained from stdin.
        \\-out:         Path to output file. If this flag is not provided, output is sent to stdout.
        \\-dll:         (optional) Path to output dummy DLL. Useful for creating an import library without 
        \\              requiring the Vulkan SDK.
        \\-debug:       Output unformatted code. Useful for debugging.    
    ;
    const cwd = std.Io.Dir.cwd();

    {
        var it = init.minimal.args.iterateAllocator(allocator) catch @panic("oom");
        _ = it.skip(); // program name
        while (it.next()) |o| {
            const Options = enum {
                @"-api",
                @"-registry",
                @"-out",
                @"-dll",
                @"-debug",
            };
            const op = enumFromName(Options, o) orelse std.debug.panic(
                \\Unknown option: {s}
            ++ usage, .{o});
            switch (op) {
                .@"-api" => {
                    const a = it.next() orelse @panic("Missing api type");
                    api = enumFromName(Registry.Api, a) orelse std.debug.panic("Unknown api: {s}", .{a});
                },
                .@"-registry" => {
                    const path = it.next() orelse @panic("Missing argument for -registry");
                    if (registry_file_count == 2) @panic("Too many -registry flags");
                    registry_file[registry_file_count] = openFile(cwd, io, path, .{ .allow_directory = false });
                    registry_file_count += 1;
                },
                .@"-out" => {
                    const path = it.next() orelse @panic("Missing argument for -out");
                    output = cwd.createFile(io, path, .{}) catch @panic("Failed to create output file");
                },
                .@"-dll" => {
                    const path = it.next() orelse @panic("Missing argument for -dll");
                    dll = cwd.createFile(io, path, .{}) catch @panic("Failed to create dll output file");
                },
                .@"-debug" => {
                    debug = true;
                },
            }
        }
    }

    var registry: Registry = .init(api, allocator);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    if (registry_file.len == 0) {
        const stdin = std.Io.File.stdin();
        var reader = stdin.reader(init.io, &read_buffer);
        parseFile(&registry, &reader.interface, allocator);
    } else {
        for (registry_file[0..registry_file_count]) |file| {
            var reader = file.reader(io, &read_buffer);
            parseFile(&registry, &reader.interface, allocator);
        }
    }
    registry.finishParse();

    if (dll) |file| {
        var w = file.writer(io, &write_buffer);
        defer w.flush() catch @panic("Failed to write DLL file");
        render.renderDll(&registry, &w.interface) catch @panic("Failed to write DLL file");
    }

    var temp_writer: Writer.Allocating = .init(allocator);
    render.render(&registry, &temp_writer.writer) catch @panic("Failed to write output file");
    const source = temp_writer.toOwnedSliceSentinel(0) catch @panic("oom");

    const out_file = if (output) |out|
        out
    else
        std.Io.File.stdout();
    var writer = out_file.writer(io, &write_buffer);

    if (debug) {
        writer.interface.writeAll(source) catch @panic("Failed to write to output file");
    } else {
        const ast = std.zig.Ast.parse(allocator, source, .zig) catch @panic("oom");
        ast.render(allocator, &writer.interface, .{}) catch |e| panic("Failed to write to output file. Error: {}", .{e});
    }
    writer.flush() catch |e| panic("Failed to write to output file. Error: {}", .{e});
}
