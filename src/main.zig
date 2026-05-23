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
        };
        values: []const Value,
        aliases: []const @This().Alias,
    };
    const Flags = struct {
        const Bitwidth = enum { @"32", @"64" };
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
        const Ptrs = slice_tools.BoundedArray(PtrKind, max_ptr);
        ptrs: Ptrs = .empty,
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
            bitfield: []const u8,
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
                        .ptrs = .empty,
                    },
                },
                .name = undefined,
                .comment = null,
            };
            const ptrs = &result.type.base.ptrs;

            var it = xml.childrenIterator();
            const type_node = switch (it.nextNodeOrText(enum { type }) orelse @panic("Failed to find variable type")) {
                .text => |t| blk: {
                    if (std.mem.find(u8, t, "const ")) |_| {
                        result.type.base.ptrs.appendAssumeCapacity(.@"const");
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
                        if (ptrs.len == 0) {
                            ptrs.appendAssumeCapacity(.mutable);
                        }
                        text = text[i + 1 ..];
                    }
                    if (std.mem.findAny(u8, text, "*c")) |i| {
                        const c = text[i];
                        ptrs.appendAssumeCapacity(if (c == '*') .mutable else .@"const");
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
                        result.type.amount = .{ .bitfield = text };
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
        const Ptr = struct {
            optional: bool,
            len: []const u8,
        };

        c_var: CVar,
        extra: [CBaseType.max_ptr]Ptr,

        pub fn parse(xml: XmlNode) @This() {
            var result: @This() = .{
                .c_var = .parse(xml),
                .extra = @splat(.{ .optional = false, .len = &.{} }),
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
                        e.len = text;
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
        params: []const CVar,
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
            self.extensions = slice_tools.allocated.concat(ExtensionName, @constCast(self.extensions), &.{extension}, allocator) catch @panic("oom");
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
        name: []const u8,
        value: []const u8,
        type: []const u8,
        comment: ?[]const u8,
        providers: Providers = .{},
    };

    api: Api,
    allocator: Allocator,
    authors: []const []const u8 = &.{},
    types: VkTypes = .{},
    constants: []const Constant = &.{},
    commands: Commands = .{},
    versions: []const VkVersion = &.{},
    extensions: []const Extension = &.{},

    fn parseAuthorTags(self: *@This(), xml: XmlNode) void {
        if (self.authors.len != 0) @panic("Duplicate tags section");
        var list: std.ArrayList([]const u8) = .empty;
        for (xml.children) |child| {
            const node = if (child == .node) child.node else continue;
            const name = node.attr.get("name") orelse @panic("Nameless author");
            list.append(self.allocator, name) catch @panic("oom");
        }
        self.authors = list.toOwnedSlice(self.allocator) catch @panic("oom");
    }
    fn parseForeign(self: *@This(), xml: XmlNode) void {
        const name = xml.attr.get("name") orelse @panic("Nameless foreign type");
        const gp = self.types.getOrPut(self.allocator, name) catch @panic("oom");
        if (gp.found_existing) panic("Duplicate foreign type: {s}", .{name});
        gp.value_ptr.* = .{
            .type = .{ .foreign = .{} },
        };
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
        var params: std.ArrayList(CVar) = .empty;
        while (it.nextNode("param")) |param| {
            const new = params.addOne(self.allocator) catch @panic("oom");
            new.* = .parse(param);
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

    pub fn parse(api: Api, xml: XmlNode, allocator: Allocator) @This() {
        var self: @This() = .{ .api = api, .allocator = allocator };
        if (!std.mem.eql(u8, xml.tag, "registry")) @panic("Missing registry");

        for (xml.children) |child| {
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

        self.sortBits();

        return self;
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
        var constants: std.ArrayList(Constant) = .empty;
        constants.ensureTotalCapacity(self.allocator, xml.children.len) catch @panic("oom");
        var it = xml.childrenIterator();
        while (it.nextNode("enum")) |node| {
            if (!self.matchApi(node)) continue;
            const new = constants.addOneAssumeCapacity();
            new.* = .{
                .name = node.attr.get("name") orelse @panic("Nameless constant"),
                .value = node.attr.get("value") orelse @panic("Valueless constant"),
                .type = node.attr.get("type") orelse @panic("Typeless constant"),
                .comment = getComment(node),
            };
        }
        self.constants = constants.toOwnedSlice(self.allocator) catch @panic("oom");
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
            self.versions = slice_tools.allocated.concat(VkVersion, @constCast(self.versions), &.{new}, self.allocator) catch @panic("oom");
        }
        self.parseRequires(xml, .parseVersion(version), null);
    }
    fn parseRequires(self: *@This(), xml: XmlNode, provider: Providers.Provider, ext_number: ?[]const u8) void {
        var require_it = xml.childrenIterator();
        while (require_it.nextNode("require")) |require_node| {
            self.parseRequire(require_node, provider, ext_number);
        }
    }
    fn parseRequire(self: *@This(), xml: XmlNode, provider: Providers.Provider, ext_number: ?[]const u8) void {
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
                },
            }
        }
    }
    fn parseExtensions(self: *@This(), xml: XmlNode) void {
        var extension_it = xml.childrenIterator();
        var extensions: std.ArrayList(Extension) = .empty;
        while (extension_it.nextNode("extension")) |node| {
            if (node.attr.get("supported")) |supported| {
                if (std.mem.eql(u8, supported, "disabled")) continue;
            }
            const number = node.attr.get("number") orelse @panic("Missing extension number");
            const ext_name = node.attr.get("name") orelse @panic("Missing extension name");
            const new = extensions.addOne(self.allocator) catch @panic("oom");
            new.* = .{
                .name = .parse(ext_name),
                .kind = .parse(node.attr.get("type") orelse panic("Missing type for extension: {s}", .{ext_name})),
                .promoted = node.attr.get("promotedto"),
                .depends = node.attr.get("depends"),
            };
            self.parseRequires(node, .parseExtension(new.name), number);
        }
        self.extensions = extensions.toOwnedSlice(self.allocator) catch @panic("oom");
    }

    fn parseEnumExtension(self: *@This(), xml: XmlNode, extension_number: ?[]const u8, provider: Providers.Provider) void {
        const name = xml.attr.get("name") orelse @panic("Missing enum extension name");
        const extends = xml.attr.get("extends") orelse {
            // Must be a constant
            for (self.constants) |*c| {
                if (std.mem.eql(u8, c.name, name)) {
                    @constCast(c).providers.add(provider, self.allocator);
                    return;
                }
            }
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
                        en.aliases = slice_tools.allocated.concat(Enum.Alias, @constCast(en.aliases), &.{new_alias}, self.allocator) catch @panic("oom");
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
                };
                en.values = slice_tools.allocated.concat(Enum.Value, @constCast(en.values), &.{new}, self.allocator) catch @panic("oom");
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
                        b.bit_aliases = slice_tools.allocated.concat(FlagBits.BitAlias, @constCast(b.bit_aliases), &.{new_alias}, self.allocator) catch @panic("oom");
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
                    };

                    b.bits = slice_tools.allocated.concat(FlagBits.Bit, @constCast(b.bits), &.{new_bit}, self.allocator) catch @panic("oom");
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
                    b.aggregates = slice_tools.allocated.concat(FlagBits.Aggregate, @constCast(b.aggregates), &.{agg}, self.allocator) catch @panic("oom");
                } else panic("Missing value of bitpos for enum: {s}", .{name});
            },
            else => |t| panic("Unexpected type for enum extension: {t}", .{t}),
        }
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
        return tryStripPrefix(name, prefix) orelse panic("Expected {s} to start with prefix {s}", .{ name, prefix });
    }
    fn tryStripPrefix(name: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, name, prefix)) return null;
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
    fn printMixins(mixins: []const []const u8, flags: []const u8, flag_bits: []const u8, mixin_kind: []const u8, writer: *Writer) Writer.Error!void {
        for (mixins) |m| {
            try writer.print("pub const {[mixin]s}={[mixin_kind]s}Mixin({[flags]s},{[flag_bits]s}).{[mixin]s};", .{
                .mixin = m,
                .mixin_kind = mixin_kind,
                .flags = flags,
                .flag_bits = flag_bits,
            });
        }
    }
    fn printFlags(registry: Registry, name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const mixins: []const []const u8 = &.{ "toInt", "fromInt", "merge", "intersection", "negation", "difference", "toBit", "fromBit", "set", "unset" };

        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.flags;

        const stripped = stripPrefix(name, "Vk");
        try writer.print("pub const {s}=packed struct(u{t}){{", .{ stripped, e.bitwidth });
        if (e.bit_flags) |flag_bits_name| {
            const flag_bits_ = registry.resolveAlias(flag_bits_name);
            if (flag_bits_.type != .flag_bits) panic("Expected {s} to be FlagBits", .{flag_bits_name});
            const flag_bits = flag_bits_.type.flag_bits;
            var last_bitpos = if (flag_bits.bits.len != 0) flag_bits.bits[0].bitpos else undefined;
            for (flag_bits.bits) |b| {
                try printComment(b.comment, writer);
                try printProvider(b.providers, writer);
                const diff = b.bitpos - last_bitpos;
                if (diff > 1) {
                    try writer.print("_reserved_{}:u{} = 0,", .{ b.bitpos, diff - 1 });
                }
                try writer.print("@\"{s}\":bool=false,", .{stripEnumNameAndBitSuffix(b.name, stripped)});
                last_bitpos = b.bitpos;
            }
            for (flag_bits.aggregates) |agg| {
                try printComment(agg.comment, writer);
                try printProvider(agg.providers, writer);
                try writer.print("pub const @\"{s}\":@This() = @bitCast({s});", .{ stripEnumNameAndBitSuffix(agg.name, stripped), agg.value });
            }

            try printMixins(mixins, stripped, stripPrefix(flag_bits_name, "Vk"), "Flags", writer);

            try writer.writeAll("};");
            if (flag_bits.bits.len != 0) {
                try printFlagBitsFromFlags(flag_bits_name, flag_bits_, writer, stripped);
            }
        } else {
            try writer.writeAll("};");
        }
    }
    fn printFlagBitsFromFlags(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer, flags_name: []const u8) Writer.Error!void {
        const mixins: []const []const u8 = &.{ "toFlags", "fromFlags", "toInt", "fromInt" };

        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.flag_bits;

        const stripped_name = stripPrefix(name, "Vk");

        try writer.print("pub const {s}=enum(u{t}){{", .{ stripped_name, e.bitwidth });
        for (e.bits) |b| {
            try printComment(b.comment, writer);
            try printProvider(b.providers, writer);
            try writer.print("@\"{s}\"=1<<{},", .{ stripEnumNameAndBitSuffix(b.name, stripped_name), b.bitpos });
        }

        try printMixins(mixins, flags_name, stripped_name, "FlagBits", writer);
        try writer.writeAll("};");
    }
    fn printFlagBits(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        if (e_c.type.flag_bits.bits.len != 0) return;
        try printFlagBitsFromFlags(name, e_c, writer, "undefined");
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
    fn stripEnumName(entry_name: []const u8, enum_name: []const u8) []const u8 {
        var stripped = stripPrefix(entry_name, "VK_");
        if (entry_name.len <= enum_name.len) return stripped;
        var e_name = enum_name;
        outer: while (true) {
            const under = std.mem.findScalar(u8, stripped, '_') orelse break;
            if (under > e_name.len) break;
            const entry_segment = stripped[0..under];
            for (entry_segment, e_name[0..under]) |entry, name| {
                if (std.ascii.toUpper(name) != entry) {
                    if (std.mem.eql(u8, entry_segment, extractVersion(e_name))) {
                        stripped = stripped[under + 1 ..];
                    }
                    break :outer;
                }
            }
            stripped = stripped[under + 1 ..];
            e_name = e_name[under..];
        }

        return stripped;
    }
    fn stripBitSuffix(name: []const u8) []const u8 {
        if (std.mem.findLast(u8, name, "_BIT")) |i| {
            return name[0..i];
        }
        return name;
    }
    fn stripEnumNameAndBitSuffix(entry_name: []const u8, enum_name: []const u8) []const u8 {
        const n = stripEnumName(entry_name, enum_name);
        return stripBitSuffix(n);
    }
    fn printEnum(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.@"enum";
        const stripped_name = stripPrefix(name, "Vk");
        try writer.print("pub const {s}=enum(c_int){{", .{stripped_name});
        for (e.values) |v| {
            try printComment(v.comment, writer);
            try printProvider(v.providers, writer);
            try writer.print("@\"{s}\"={s},", .{ stripEnumName(v.name, stripped_name), v.value });
        }
        for (e.aliases) |a| {
            try printComment(a.comment, writer);
            try printProvider(a.providers, writer);
            try writer.print("pub const @\"{s}\"=@This().@\"{s}\";", .{ stripEnumName(a.name, stripped_name), stripEnumName(a.canonical, stripped_name) });
        }
        try writer.writeAll("};");
    }
    fn printStruct(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.@"struct";
        try writer.print("pub const {s}=extern struct{{", .{stripPrefix(name, "Vk")});
        var members = e.members;
        if (e.s_type) |s_type| {
            try writer.print("sType: StructureType=.{s},", .{stripPrefix(s_type, "VK_STRUCTURE_TYPE_")});
            members = members[1..];
        }
        var in_bitfield = false;
        var bit_field_index: usize = 0;
        for (members) |m| {
            if (m.c_var.type.amount == .bitfield) {
                if (!in_bitfield) {
                    try writer.print("p{}:packed struct{{", .{bit_field_index});
                    bit_field_index += 1;
                    in_bitfield = true;
                }
            } else {
                if (in_bitfield) {
                    try writer.writeAll("},");
                    in_bitfield = false;
                }
            }
            const l = m.extra[0].len;
            var optional = m.extra[0].optional;
            blk: {
                var comma_it: CommaIterator = .{ .text = l };
                const first = comma_it.next() orelse break :blk;
                if (!optional and enumFromName(enum { @"null-terminated", @"1" }, first) == null) {
                    for (members) |mem| {
                        if (!std.mem.eql(u8, mem.c_var.name, l)) continue;
                        for (mem.extra) |ex| {
                            if (ex.optional) {
                                optional = true;
                                break :blk;
                            }
                        }
                    }
                }
            }
            try printZigVar(m, members, writer);
            if (optional) {
                try writer.writeAll("=nullValue(");
                try printZigType(m, members, writer);
                try writer.writeByte(')');
            }
            try writer.writeByte(',');
        }
        if (in_bitfield) {
            try writer.writeAll("},");
        }
        try writer.writeAll("};");
    }
    fn printZigVar(zig_var: Registry.ZigVar, others: []const Registry.ZigVar, writer: *Writer) Writer.Error!void {
        blk: {
            const l = zig_var.extra[0].len;
            var comma_it: CommaIterator = .{ .text = l };
            const first = comma_it.next() orelse break :blk;
            if (enumFromName(enum { @"null-terminated", @"1" }, first)) |kind| {
                switch (kind) {
                    .@"null-terminated" => {
                        if (zig_var.c_var.type.amount == .array)
                            try writer.writeAll("\n/// Null-terminated\n");
                    },
                    .@"1" => {},
                }
            } else {
                try writer.print("\n/// length given by {s}\n", .{l});
            }
        }
        try printComment(zig_var.c_var.comment, writer);

        //OVERRIDE: Overriding API versions from u32 to our own ApiVersion
        if (enumFromName(enum { apiVersion, pApiVersion }, zig_var.c_var.name)) |n| {
            const text = switch (n) {
                .apiVersion => "apiVersion:ApiVersion",
                .pApiVersion => "pApiVersion:*ApiVersion",
            };
            try writer.writeAll(text);
        } else {
            try writer.print("@\"{s}\":", .{zig_var.c_var.name});
            try printZigType(zig_var, others, writer);
        }
    }
    fn printZigType(zig_var: Registry.ZigVar, others: []const Registry.ZigVar, writer: *Writer) Writer.Error!void {
        if (zig_var.c_var.type.amount == .bitfield) {
            try writer.print("u{s}", .{zig_var.c_var.type.amount.bitfield});
            return;
        }
        const ptrs = zig_var.c_var.type.base.ptrs.constSlice();
        for (ptrs, zig_var.extra[0..ptrs.len]) |kind, extra| {
            var optional = extra.optional;
            const p_text = if (extra.len.len == 0)
                "*"
            else if (enumFromName(enum { @"null-terminated", @"1" }, extra.len)) |l| switch (l) {
                .@"null-terminated" => "[*:0]",
                .@"1" => "*",
            } else blk: {
                if (!optional) outer: {
                    for (others) |o| {
                        if (!std.mem.eql(u8, o.c_var.name, extra.len)) continue;
                        optional = o.extra[0].optional;
                        break :outer;
                    } else optional = true;
                }
                break :blk "[*]";
            };
            if (optional) {
                try writer.writeByte('?');
            }
            try writer.writeAll(p_text);
            if (kind == .@"const") {
                try writer.writeAll("const ");
            }
        }
        if (zig_var.c_var.type.amount == .array) {
            try writer.writeByte('[');
            switch (zig_var.c_var.type.amount.array) {
                .literal => |l| try writer.writeAll(l),
                .constant => |c| try writeConstant(c, writer),
            }
            try writer.writeByte(']');
        }
        if (zig_var.c_var.type.base.ptrs.len != 0 and std.mem.eql(u8, zig_var.c_var.type.base.name, "void")) {
            try writer.writeAll("anyopaque");
        } else {
            try printGenericTypeName(zig_var.c_var.type.base.name, writer);
        }
    }
    fn writeConstant(name: []const u8, writer: *Writer) Writer.Error!void {
        if (name.len <= 3) panic("Malformed constant name: {s}", .{name});
        try writer.writeAll(name[3..]);
    }
    fn printUnion(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.@"union";
        try writer.print("pub const {s}=extern union{{", .{stripPrefix(name, "Vk")});
        for (e.members) |m| {
            try printZigVar(m, e.members, writer);
            try writer.writeByte(',');
        }
        try writer.writeAll("};");
    }
    fn printHandle(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.handle;
        try writer.print("pub const {s}=enum({s}){{null_handle,_}};", .{
            stripPrefix(name, "Vk"),
            if (e.dispatchable) "usize" else "u64",
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
    fn printGenericTypeName(name: []const u8, writer: *Writer) Writer.Error!void {
        if (tryStripPrefix(name, "PFN_vk")) |n| {
            try writer.print("Pfn{s}", .{n});
        } else if (tryStripPrefix(name, "Vk")) |n| {
            try writer.writeAll(n);
        } else if (enumFromName(Primitives, name)) |n| {
            try writer.writeAll(n.toZig());
        } else {
            try writer.writeAll(name);
        }
    }
    fn printCType(c_type: Registry.CType, writer: *Writer) Writer.Error!void {
        if (c_type.amount == .bitfield) {
            try writer.print("u{s}", .{c_type.amount.bitfield});
            return;
        }
        try printCBaseType(c_type.base, writer);
        if (c_type.amount == .array) {
            const ar = c_type.amount.array;
            switch (ar) {
                .literal => |l| try writer.writeAll(l),
                .constant => |c| try writeConstant(c, writer),
            }
        }
    }
    fn printCBaseType(base_type: Registry.CBaseType, writer: *Writer) Writer.Error!void {
        for (base_type.ptrs.constSlice()) |k| {
            try writer.writeAll("[*c]");
            switch (k) {
                .@"const" => try writer.writeAll("const "),
                .mutable => {},
            }
        }
        if (base_type.ptrs.len != 0 and std.mem.eql(u8, base_type.name, "void")) {
            try writer.writeAll("anyopaque");
            return;
        }

        try printGenericTypeName(base_type.name, writer);
    }

    fn printCVar(c_var: Registry.CVar, writer: *Writer) Writer.Error!void {
        try printComment(c_var.comment, writer);
        try writer.print("{s}:", .{c_var.name});
        try printCType(c_var.type, writer);
    }
    fn printFuncpointer(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.funcpointer;
        try writer.print("pub const Pfn{s}= *const fn(", .{stripPrefix(name, "PFN_vk")});
        for (e.params) |p| {
            try printCVar(p, writer);
            try writer.writeByte(',');
        }
        try writer.writeAll(")callconv(vulkan_api)");
        try printCBaseType(e.ret, writer);
        try writer.writeByte(';');
    }
    fn printAlias(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        try printComment(e_c.comment, writer);
        try printProvider(e_c.providers, writer);
        const e = e_c.type.alias;
        const prefix = "Vk";
        const n = stripPrefix(name, prefix);
        const c = stripPrefix(e.canonical, prefix);
        try writer.print("pub const {s}={s};", .{ n, c });
    }
    fn printConstants(constants: []const Registry.Constant, writer: *Writer) Writer.Error!void {
        for (constants) |c| {
            // OVERRIDE: true and false have been subsumed into Bool32
            if (enumFromName(enum { VK_TRUE, VK_FALSE }, c.name)) |_| continue;

            try printComment(c.comment, writer);
            try printProvider(c.providers, writer);
            try writer.writeAll("pub const ");
            try writeConstant(c.name, writer);
            const zig_type: Primitives = enumFromName(Primitives, c.type) orelse panic("Unknown primitive type: {s}", .{c.type});
            const zig_type_text = zig_type.toZig();
            try writer.print(":{s}=", .{zig_type_text});
            const nums_and_point = "0123456789.";
            if (std.mem.findScalar(u8, c.value, '~')) |i| {
                var t = c.value[i + 1 ..];
                const end = std.mem.findNone(u8, t, nums_and_point) orelse c.value.len;
                t = t[0..end];
                try writer.print("~@as({s},{s});", .{ zig_type_text, t });
            } else {
                const end = std.mem.findNone(u8, c.value, nums_and_point) orelse c.value.len;
                try writer.print("{s};", .{c.value[0..end]});
            }
        }
    }
    fn printProvider(p: Registry.Providers, writer: *Writer) Writer.Error!void {
        if (p.version == null and p.extensions.len == 0) return;
        try writer.writeAll("\n/// Provided by ");
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
    pub fn render(registry: Registry, writer: *Writer, allocator: Allocator) Writer.Error!void {
        try writer.print("{s}\n", .{@embedFile("preamble.zig")});
        try printConstants(registry.constants, writer);
        var it = registry.types.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            switch (v.type) {
                .flags => try printFlags(registry, name, v, writer),
                .flag_bits => try printFlagBits(name, v, writer),
                .@"enum" => try printEnum(name, v, writer),
                .@"struct" => try printStruct(name, v, writer),
                .@"union" => try printUnion(name, v, writer),
                .handle => try printHandle(name, v, writer),
                .basetype => try printBasetype(name, v, writer),
                .funcpointer => try printFuncpointer(name, v, writer),
                .foreign => try printForeign(name, v, writer),
                .alias => try printAlias(name, v, writer),
            }
        }

        try printCommands(registry, writer, allocator);
        try printExtensions(registry, writer);
    }

    fn printExtensions(registry: Registry, writer: *Writer) Writer.Error!void {
        try printExtensionKind(registry, writer, .instance);
        try printExtensionKind(registry, writer, .device);
    }

    fn printExtensionKind(registry: Registry, writer: *Writer, kind: Registry.Extension.Kind) Writer.Error!void {
        {
            const t = @tagName(kind);
            try writer.print("pub const {c}{s}Extension = enum{{", .{ std.ascii.toUpper(t[0]), t[1..] });
        }
        for (registry.extensions) |e| {
            if (e.kind != kind) continue;
            try printExtension(e, writer);
        }
        try writer.writeAll(
            \\pub fn getVkName(comptime self: @This()) []const u8{
            \\return "VK_" ++ @tagName(self);
            \\}
            \\pub fn getVkNames(comptime extensions: []const @This()) []const []const u8{   
            \\var result: [extensions.len][]const u8 = undefined;
            \\for(&result, extensions) |*r, e| r.* = e.getVkName();
            \\const final = result;
            \\return &final;
            \\}
            \\};
        );
    }

    fn printExtension(e: Registry.Extension, writer: *Writer) Writer.Error!void {
        if (e.promoted) |p| {
            try writer.print("\n/// Promoted to {s}\n", .{p});
        }
        if (e.depends) |d| {
            try writer.print("\n/// depends on {s}\n", .{d});
        }
        try writer.print("{s},", .{stripPrefix(e.name.name, "VK_")});
    }

    fn printResultEntry(name: []const u8, writer: *Writer) Writer.Error!void {
        if (enumFromName(enum { VK_ERROR_UNKNOWN, VK_ERROR_VALIDATION_FAILED }, name)) |_| return;
        try writer.print("{[name]s}=@intFromEnum(Result.{[name]s}),", .{ .name = stripPrefix(name, "VK_") });
    }
    fn printCommandName(name: []const u8, writer: *Writer) Writer.Error!void {
        const stripped = stripPrefix(name, "vk");
        if (stripped.len == 0) @panic("Empty command name");
        try writer.writeByte(std.ascii.toLower(stripped[0]));
        try writer.writeAll(stripped[1..]);
    }
    pub fn printCommands(registry: Registry, writer: *Writer, allocator: Allocator) Writer.Error!void {
        const GlobalCommands = enum {
            vkEnumerateInstanceVersion,
            vkEnumerateInstanceExtensionProperties,
            vkEnumerateInstanceLayerProperties,
            vkCreateInstance,
        };
        var base: std.ArrayList(CommandWithName) = .empty;
        var instance: std.ArrayList(CommandWithName) = .empty;
        var device: std.ArrayList(CommandWithName) = .empty;

        var it = registry.commands.iterator();
        while (it.next()) |c| {
            const new: CommandWithName = .{
                .name = c.key_ptr.*,
                .command = c.value_ptr.*,
            };
            if (enumFromName(GlobalCommands, c.key_ptr.*)) |_| {
                base.append(allocator, new) catch @panic("oom");
                continue;
            }
            if (new.command.params.len != 0 and std.mem.eql(u8, new.command.params[0].c_var.type.base.name, "VkInstance")) {
                instance.append(allocator, new) catch @panic("oom");
                continue;
            }
            device.append(allocator, new) catch @panic("oom");
        }

        try printExternGlobalFunctions(base.items, writer);
        try printCommandGroup(base.items, writer, .{
            .func_arg = "",
            .group = "Global",
            .load_param = ".null_handle",
        });
        try printCommandGroup(instance.items, writer, .{
            .func_arg = ", instance: Instance",
            .group = "Instance",
            .load_param = "instance",
        });
        try printCommandGroup(device.items, writer, .{
            .func_arg = ", device: Device",
            .group = "Device",
            .load_param = "device",
        });
    }
    const PrintData = struct {
        group: []const u8,
        func_arg: []const u8,
        load_param: []const u8,
    };
    const CommandWithName = struct {
        command: Registry.Command,
        name: []const u8,
    };
    fn printExternGlobalFunctions(commands: []const CommandWithName, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\
            \\/// Provides global functions as load-time loaded functions.
            \\pub const global_functions = struct{
        );
        for (commands) |c| {
            try printProvider(c.command.providers, writer);
            try writer.print("extern \"vulkan-1\" fn {s}(", .{c.name});
            for (c.command.params) |p| {
                try printZigVar(p, c.command.params, writer);
                try writer.writeByte(',');
            }
            try writer.writeAll(") callconv(vulkan_api)");
            if (c.command.success_codes.len != 0) {
                try writer.print("GlobalFunctions.{s}Result", .{stripPrefix(c.name, "vk")});
            } else {
                try printCBaseType(c.command.ret, writer);
            }
            try writer.writeAll(";pub const ");
            try printCommandName(c.name, writer);
            try writer.print("={s};", .{c.name});
        }
        try writer.writeAll("};");
    }
    pub fn printCommandGroup(commands: []const CommandWithName, writer: *Writer, print_data: PrintData) Writer.Error!void {
        const conv_funcs =
            \\pub fn getType(comptime self: @This()) type{
            \\const t = @tagName(self);
            \\return @field(@This(), std.ascii.toUpper(t[0]) ++ t[1..]);
            \\}
            \\pub fn getPtrType(comptime self: @This()) type{
            \\return ?*const self.getType();
            \\}
            \\pub fn getReturnType(comptime self: @This()) type{
            \\return @typeInfo(self.getType()).@"fn".return_type.?;
            \\}
            \\pub fn getVkName(comptime self: @This()) []const u8{
            \\return getFunctionVkName(self);
            \\}
            \\pub fn getVkNames(comptime funcs: []const @This()) []const []const u8{
            \\return getFunctionVkNames(@This(), funcs);
            \\}
            \\};
        ;
        {
            try writer.print("pub const {s}Functions=enum{{", .{print_data.group});
            for (commands) |c| {
                try printProvider(c.command.providers, writer);
                try printCommandName(c.name, writer);
                try writer.writeByte(',');
            }
            for (commands) |c| {
                try printCommandType(c.name, c.command, writer);
            }
            try writer.writeAll(conv_funcs);
            try writer.print(
                \\pub fn {[group]s}Loader(comptime functions: []const {[group]s}Functions)type{{
                \\return struct{{
                \\    const Ptrs = MakeLoader({[group]s}Functions, functions);
                \\    ptrs: Ptrs,
                \\    pub fn init(load_func: anytype{[func_arg]s}) @This(){{
                \\        var result: Ptrs = undefined;
                \\        const slice: *[functions.len]?PfnVoidFunction = @ptrCast(&result);
                \\        for(slice.*, getFunctionVkNames(functions)) |*ptr, name|{{
                \\            ptr.* = load_func({[load_param]s},name);
                \\        }}
                \\        return .{{ .ptrs = result }};
                \\    }}
            , print_data);
            for (commands) |c| {
                try printProvider(c.command.providers, writer);
                try writer.writeAll("pub fn ");
                try printCommandName(c.name, writer);
                try writer.writeAll("(loader: *const @This(),");
                for (c.command.params) |p| {
                    try printZigVar(p, c.command.params, writer);
                    try writer.writeByte(',');
                }
                try writer.writeByte(')');
                if (c.command.success_codes.len != 0) {
                    try writer.print("{s}Functions.{s}Result", .{ print_data.group, stripPrefix(c.name, "vk") });
                } else {
                    try printCBaseType(c.command.ret, writer);
                }
                try writer.writeAll("{return loader.ptrs.");
                try printCommandName(c.name, writer);
                try writer.writeAll(".?.*(");
                for (c.command.params) |p| {
                    try writer.print("@\"{s}\",", .{p.c_var.name});
                }
                try writer.writeAll(");}");
            }
            try writer.writeAll("};}");
        }
    }
    pub fn printCommandType(name: []const u8, c: Registry.Command, writer: *Writer) Writer.Error!void {
        const stripped = stripPrefix(name, "vk");
        if (c.success_codes.len != 0) {
            try writer.print("pub const {s}Result = enum(@typeInfo(Result).@\"enum\".tag_type){{", .{stripped});
            {
                var it: CommaIterator = .{ .text = c.success_codes };
                while (it.next()) |t| {
                    try printResultEntry(t, writer);
                }
            }
            {
                var it: CommaIterator = .{ .text = c.error_codes };
                while (it.next()) |t| {
                    try printResultEntry(t, writer);
                }
            }
            try writer.writeAll("pub fn toResult(self: @This())Result{return @enumFromInt(@intFromEnum(self));}};");
        }
        try writer.print("pub const {s} = fn(", .{stripped});
        for (c.params) |p| {
            try printZigVar(p, c.params, writer);
            try writer.writeByte(',');
        }
        try writer.writeAll(")callconv(vulkan_api)");
        if (c.success_codes.len != 0) {
            try writer.print("{s}Result", .{stripped});
        } else {
            try printCBaseType(c.ret, writer);
        }
        try writer.writeByte(';');
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);
    const reader = &stdin_reader.interface;

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

    const source = blk: {
        var writer: Writer.Allocating = .init(allocator);
        const registry = Registry.parse(api, xml, allocator);
        try render.render(registry, &writer.writer, allocator);
        break :blk try writer.toOwnedSliceSentinel(0);
    };

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    //const ast = try std.zig.Ast.parse(allocator, source, .zig);
    //try ast.render(allocator, writer, .{});
    try writer.writeAll(source);
    try writer.flush();
}
