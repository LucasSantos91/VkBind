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
    const command_group_name = "Command";
    const loader_name = "Loader";
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
        p: Registry.Providers,

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
            return .{ .name = stripPrefix(name, "Vk") };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    const EnumName = struct {
        name: []const u8,

        pub fn parse(entry_name: []const u8, enum_name: TypeName) @This() {
            return .{ .name = stripEnumNameAndBitSuffix(entry_name, enum_name) };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("@\"{s}\"", .{self.name});
        }
    };
    fn printFlags(registry: Registry, name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
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
                        try w.print("_reserved_{}:u{} = 0,", .{ self.bitpos, self.diff - 1 });
                    }
                }
            };

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const flag_bits = self.b;
                var last_bitpos = if (flag_bits.bits.len != 0) flag_bits.bits[0].bitpos else undefined;
                for (flag_bits.bits) |b| {
                    const bit_comment: Comment = .parse(b.comment);
                    const bit_provider: Provider = .{ .p = b.providers };
                    const bit_name: EnumName = .parse(b.name, self.flags_name);
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
                for (flag_bits.aggregates) |agg| {
                    const bit_comment: Comment = .parse(agg.comment);
                    const bit_provider: Provider = .{ .p = agg.providers };
                    const bit_name: EnumName = .parse(agg.name, self.flags_name);
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
                \\{[mixins]f}
                \\}};
            , .{
                .mixins = mixins,
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
                    const name: EnumName = .parse(b.name, self.enum_name);
                    const c: Comment = .parse(b.comment);
                    const p: Provider = .{ .p = b.providers };
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
        var stripped_entry_name = stripPrefix(entry_name, "VK_");
        if (entry_name.len <= enum_name.name.len) return stripped_entry_name;
        var local_enum_name = enum_name.name;
        outer: while (true) {
            const under = std.mem.findScalar(u8, stripped_entry_name, '_') orelse break;
            if (under > local_enum_name.len) break;
            const entry_segment = stripped_entry_name[0..under];
            for (entry_segment, local_enum_name[0..under]) |entry, name| {
                if (std.ascii.toUpper(name) != entry) {
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
                    const c: Comment = .parse(a.comment);
                    const p: Provider = .{ .p = a.providers };
                    const alias_name: EnumName = .parse(a.name, self.enum_name);
                    const canonical_name: EnumName = .parse(a.canonical, self.enum_name);
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
            \\pub const {[name]f}=enum(c_int){{
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
    fn printStruct(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const Members = struct {
            e: Registry.Struct,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                const e = self.e;
                var members = e.members;
                if (e.s_type) |s_type| {
                    try w.print("sType: StructureType=.{s},", .{stripPrefix(s_type, "VK_STRUCTURE_TYPE_")});
                    members = members[1..];
                }

                var in_bitfield = false;
                var bit_field_index: usize = 0;
                for (members) |m| {
                    if (m.c_var.type.amount == .bitfield) {
                        if (!in_bitfield) {
                            try w.print("p{}:packed struct{{", .{bit_field_index});
                            bit_field_index += 1;
                            in_bitfield = true;
                        }
                    } else {
                        if (in_bitfield) {
                            try w.writeAll("},");
                            in_bitfield = false;
                        }
                    }

                    const v: ZigVar = .parse(m, members);
                    try w.print("{f}", .{v});
                    if (v.v.v.extra[0].optional) {
                        try w.print("= nullValue({f})", .{v.v});
                    }
                    try w.writeByte(',');
                }

                if (in_bitfield) {
                    try w.writeAll("},");
                }
            }
        };
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.@"struct";
        const members: Members = .{ .e = e };
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

        pub fn parse(zig_var: Registry.ZigVar, others: []const Registry.ZigVar) @This() {
            return .{ .v = .parse(zig_var, others) };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const ptr_len = self.v.v.c_var.type.base.ptrs.len;
            if (self.v.v.c_var.type.amount == .array and self.v.len_kind[0] == .@"null-terminated") {
                try writer.writeAll("\n/// Null-terminated\n");
            }
            for (self.v.len_kind[0..ptr_len], self.v.v.extra[0..ptr_len]) |b, extra| {
                switch (b) {
                    .other_member, .expression => {
                        try writer.print("\n/// Length given by {s}\n", .{extra.len});
                        break;
                    },
                    .@"null-terminated", .single => {},
                }
            }
            const comment: Comment = .parse(self.v.v.c_var.comment);
            try writer.print(
                \\{[comment]f}
                \\{[name]s}: {[type]f}
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
        len_kind: [max_ptr]LenKind,

        const LenKind = enum { single, @"null-terminated", expression, other_member };

        pub fn parse(zig_var: Registry.ZigVar, others: []const Registry.ZigVar) @This() {
            var result: @This() = .{
                .v = zig_var,
                .len_kind = undefined,
            };
            for (&result.v.extra, &result.len_kind) |*extra, *len_kind| {
                if (extra.len.len == 0) {
                    len_kind.* = .single;
                } else {
                    if (enumFromName(enum { @"null-terminated", @"1" }, extra.len)) |l| switch (l) {
                        .@"null-terminated" => {
                            len_kind.* = .@"null-terminated";
                        },
                        .@"1" => {
                            len_kind.* = .single;
                        },
                    } else {
                        len_kind.* = .expression;
                        extra.optional = true;

                        for (others) |o| {
                            if (!std.mem.eql(u8, o.c_var.name, extra.len)) continue;
                            len_kind.* = .other_member;
                            extra.optional = false;
                            for (o.extra) |e| if (e.optional) {
                                extra.optional = true;
                                break;
                            };
                            break;
                        }
                    }
                }
            }
            return result;
        }

        pub fn format(self: @This(), w: *Writer) Writer.Error!void {
            if (self.v.c_var.type.amount == .bitfield) {
                try w.print("u{s}", .{self.v.c_var.type.amount.bitfield});
                return;
            }
            const ptr_len = self.v.c_var.type.base.ptrs.len;

            for (self.v.extra[0..ptr_len], self.v.c_var.type.base.ptrs.buffer[0..ptr_len], self.len_kind[0..ptr_len]) |extra, ptr, kind| {
                if (extra.optional) {
                    try w.writeByte('?');
                }
                switch (kind) {
                    .other_member, .expression => {
                        try w.writeAll("[*]");
                    },
                    .@"null-terminated" => {
                        try w.writeAll("[*:0]");
                    },
                    .single => {
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
                    .literal => |l| try w.writeAll(l),
                    .constant => |c| try writeConstant(c, w),
                }
                try w.writeByte(']');
            }

            //OVERRIDE: Overriding API versions from u32 to our own ApiVersion
            if (enumFromName(enum { apiVersion, pApiVersion }, self.v.c_var.name)) |_| {
                try w.writeAll("ApiVersion");
            } else if (self.v.c_var.type.base.ptrs.len != 0 and std.mem.eql(u8, self.v.c_var.type.base.name, "void")) {
                try w.writeAll("anyopaque");
            } else {
                const n: GenericTypeName = .parse(self.v.c_var.type.base.name);
                try w.print("{f}", .{n});
            }
        }
    };
    fn writeConstant(name: []const u8, writer: *Writer) Writer.Error!void {
        if (name.len <= 3) panic("Malformed constant name: {s}", .{name});
        try writer.writeAll(name[3..]);
    }
    fn printUnion(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const Members = struct {
            e: Registry.Union,

            pub fn format(self: @This(), w: *Writer) Writer.Error!void {
                for (self.e.members) |m| {
                    const v: ZigVar = .parse(m, self.e.members);
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
            primitive,
            none,
        };

        pub fn parse(name: []const u8) @This() {
            return if (tryStripPrefix(name, "PFN_vk")) |n| .{
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

            const name: GenericTypeName = .parse(base_type.name);
            try writer.print("{f}", .{name});
        }
    };
    const CType = struct {
        v: Registry.CType,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const c_type = self.v;
            if (c_type.amount == .bitfield) {
                try writer.print("u{s}", .{c_type.amount.bitfield});
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
                const v: ZigVar = .parse(p, self.params);
                try writer.print("{f},", .{v});
            }
        }
    };
    fn printFuncpointer(name: []const u8, e_c: Registry.TypeCommon, writer: *Writer) Writer.Error!void {
        const comment: Comment = .parse(e_c.comment);
        const provider: Provider = .{ .p = e_c.providers };
        const e = e_c.type.funcpointer;
        const n: FuncpointerName = .parse(name);
        const params: CParams = .{ .params = e.params };
        const ret: CBaseType = .{ .v = e.ret };
        try writer.print(
            \\{[comment]f}
            \\{[provider]f}
            \\pub const {[name]f} = *const fn(
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
    pub fn render(registry: Registry, writer: *Writer) Writer.Error!void {
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

        try printCommands(registry, writer);
        try printExtensions(registry, writer);
        //try printVulkanContext(registry, writer);
    }
    fn isGlobalCommand(command: Registry.Command, registry: Registry) bool {
        if (command.params.len == 0) return true;
        const first = command.params[0];
        const first_type = registry.types.get(first.c_var.type.base.name) orelse @panic("Missing type for first parameter");
        if (first_type.type != .handle) return true;
        if (!first_type.type.handle.dispatchable) return true;
        return false;
    }
    fn printVulkanContext(registry: Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\pub const VulkanContextConfig = struct{
            \\pub const Globals = union(enum){
            \\load_time,
            \\run_time: []const GlobalFunctions,
            \\};
            \\pub const AllocatorConfig = union(enum){
            \\compile_time: ?*const AllocationCallbacks,
            \\run_time,
            \\};
            \\ globals: Globals = .load_time,
            \\ instance: []const InstanceFunctions,
            \\ device: []const DeviceFunctions,
            \\ apiVersion: ApiVersion = .{ .minor = 0 },
            \\ extensions: []const Extension = &.{},
            \\ allocator: AllocatorConfig,
            \\};
            \\pub fn VulkanContext(comptime config: VulkanContextConfig) type{
            \\return struct{
            \\comptime{ if(Extension.missingDependenciesFor(config.extensions, config.apiVersion)) |e|
            \\@panic("Missing dependencies for extension " ++ e.name.name);
            \\}
            \\var runtime_allocator: switch(config.allocator){
            \\.compile_time => void,
            \\.run_time =>?*const AllocationCallbacks,
            \\} = undefined;
            \\pub fn initAllocator(pAllocator: ?*const AllocationCallbacks) void{
            \\runtime_allocator = pAllocator;
            \\}
            \\pub fn getAllocator()?*const AllocationCallbacks{
            \\ return switch(comptime config.allocator){
            \\.comptime_time => |a| a,
            \\.run_time => runtime_allocator,
            \\};
            \\}
            \\var globals: switch(config.globals){
            \\.load_time => void,
            \\.run_time => |f| GlobalFunctions(f),
            \\} = undefined;
            \\pub fn initGlobalLoader(loader: anytype) void{
            \\switch(comptime config.globals){
            \\.load_time => {},
            \\.run_time => globals.init(loader),
            \\}}
            \\var instance_loader: InstanceLoader(config.instance) = undefined;
            \\var device_loader: DeviceLoader(config.device) = undefined;
            \\pub fn initInstanceLoader(load_function: anytype, instance: Instance) void{
            \\instance_loader.init(load_function, instance);
            \\}
            \\pub fn initDeviceLoader(load_function: anytype, device: Device) void{
            \\device_loader.init(load_function, device);
            \\}
            \\const provided_extensions: CommandDependencyRequirements = .{
            \\        .version = config.apiVersion,
            \\        .extensions = config.extensions,
            \\};
            \\fn assertDependencies(comptime cmd: anytype) void{
            \\   comptime{
            \\  if(!provided_extensions.satisfy(cmd.requirements())){
            \\   @compileError("Requirements not met for command: " ++ @tagName(cmd));
            \\}
            \\}
            \\}
        );
        const helper = struct {
            fn isAllocator(zig_var: Registry.ZigVar) bool {
                return std.mem.eql(u8, zig_var.c_var.name, "pAllocator");
            }
            const CodeStatus = struct {
                has_success_codes: bool,
                success_only: bool,
                has_error_codes: bool,
                has_only_ignored_error_codes: bool,
                is_create: bool,

                pub fn parse(command: Registry.Command, command_name: []const u8) @This() {
                    var result: @This() = undefined;
                    if (command.success_codes.len == 0) {
                        result.has_success_codes = false;
                        result.success_only = true;
                    } else {
                        result.has_success_codes = true;
                        result.success_only = std.mem.eql(u8, command.success_codes, "VK_SUCCESS");
                    }
                    if (command.error_codes.len == 0) {
                        result.has_error_codes = false;
                        result.has_only_ignored_error_codes = true;
                    } else {
                        result.has_error_codes = true;
                        var count_error_codes: usize = 0;
                        var skip: usize = 0;
                        var it: CommaIterator = .{ .text = command.error_codes };
                        while (it.next()) |e| {
                            count_error_codes += 1;
                            if (shouldErrorBeSkipped(e)) skip += 1;
                        }
                        result.has_only_ignored_error_codes = count_error_codes == skip;
                    }
                    if (command.params.len == 0 or !result.success_only) {
                        result.is_create = false;
                    } else blk: {
                        const last = command.params[command.params.len - 1];
                        const ptrs = last.c_var.type.base.ptrs;
                        if (ptrs.len == 0 or ptrs.buffer[0] == .@"const" or (last.extra[0].len.len != 0 and !std.mem.eql(u8, last.extra[0].len, "1"))) {
                            result.is_create = false;
                            break :blk;
                        }
                        const stripped = stripPrefix(command_name, "vk");
                        result.is_create = (std.mem.startsWith(u8, stripped, "Create") or
                            std.mem.startsWith(u8, stripped, "Enumerate"));
                    }
                    return result;
                }
            };
            pub fn printCommand(command: Registry.Command, r: Registry, command_name: []const u8, group: []const u8, w: *Writer, code_status: CodeStatus) Writer.Error!void {
                const type_name = stripPrefix(command_name, "vk");
                if (code_status.has_success_codes and !code_status.success_only) {
                    try w.print(
                        \\pub const {s}Result = enum(@typeInfo(Result).@"enum".tag_type){{
                        \\pub fn toResult(self: @This()) Result{{return @enumFromInt(@intFromEnum(self));}}
                    , .{type_name});
                    var it: CommaIterator = .{ .text = command.success_codes };
                    while (it.next()) |code| {
                        try w.print("{[name]s}=@intFromEnum(Result.{[name]s}),", .{ .name = stripPrefix(code, "VK_") });
                    }
                    try w.writeAll("};");
                }
                if (code_status.has_error_codes and !code_status.has_only_ignored_error_codes) {
                    try w.print("pub const {s}Error = error{{", .{type_name});
                    var it: CommaIterator = .{ .text = command.error_codes };
                    while (it.next()) |code| {
                        if (shouldErrorBeSkipped(code)) continue;
                        try w.print("{s},", .{tryStripPrefix(code, "VK_ERROR_") orelse stripPrefix(code, "VK_")});
                    }
                    try w.writeAll("};");
                }

                try printProvider(command.providers, w);
                try w.writeAll("pub fn ");
                try printCommandName(command_name, w);
                try w.writeByte('(');
                for (command.params[0 .. command.params.len - if (code_status.is_create) @as(u1, 1) else @as(u1, 0)]) |p| {
                    if (isAllocator(p)) continue;
                    const zig_var: ZigVar = .parse(p, command.params);
                    try w.print("{f}", .{zig_var});
                    if (isDispatchable(p, r)) {
                        try w.writeAll("Wrapper");
                    }
                    try w.writeByte(',');
                }
                try w.writeByte(')');
                if (code_status.has_success_codes) {
                    if (code_status.success_only) {
                        if (code_status.is_create) {
                            var last = command.params[command.params.len - 1];
                            last.c_var.type.base.ptrs.len = 0;
                            last.c_var.comment = null;
                            const zig_var: ZigVar = .parse(last, command.params);
                            try w.print("{f}", .{zig_var});
                            if (isDispatchable(last, r)) {
                                try w.writeAll("Wrapper");
                            }
                        } else {
                            try w.writeAll("void");
                        }
                    } else {
                        try w.print("{s}Result", .{type_name});
                    }
                } else {
                    const ret: CBaseType = .{ .v = command.ret };
                    try w.print("{f}", .{ret});
                }
                if (code_status.has_error_codes and !code_status.has_only_ignored_error_codes) {
                    try w.print("!{s}Error", .{type_name});
                }
                try w.print("{{comptime assertDependencies({s}Functions.", .{group});
                try printCommandName(command_name, w);
                try w.writeAll(");");
            }
            pub fn isDispatchable(zig_var: Registry.ZigVar, r: Registry) bool {
                const t: Registry.TypeCommon = r.types.get(zig_var.c_var.type.base.name) orelse return false;
                if (t.type != .handle) return false;
                return t.type.handle.dispatchable;
            }
            fn printParams(command: Registry.Command, r: Registry, w: *Writer) Writer.Error!void {
                for (command.params) |p| {
                    if (isAllocator(p)) {
                        try w.writeAll("getAllocator(),");
                    } else {
                        const is_dispatchable = isDispatchable(p, r);
                        const is_ptr = p.c_var.type.base.ptrs.len != 0;
                        if (is_dispatchable) {
                            if (is_ptr) {
                                try w.writeAll("@ptrCast(");
                            } else {
                                try w.writeAll("@bitCast(");
                            }
                        }
                        try w.print("@\"{s}\"", .{p.c_var.name});
                        if (is_dispatchable) {
                            try w.writeByte(')');
                        }
                        try w.writeByte(',');
                    }
                }
            }
            fn printFunctionBody(
                command: Registry.Command,
                command_name: []const u8,
                loader_name_: []const u8,
                w: *Writer,
                code_status: CodeStatus,
                r: Registry,
            ) Writer.Error!void {
                if (code_status.is_create) {
                    const src = command.params[command.params.len - 1];
                    var last = src;
                    last.c_var.type.base.ptrs.len -= 1;
                    last.c_var.comment = null;
                    try w.writeAll("var temp:");
                    const zig_var: ZigVar = .parse(last, command.params);
                    try w.print("{f}", .{zig_var});
                    try w.writeAll("=undefined;");
                    try w.print("const {s}=&temp;", .{src.c_var.name});
                }
                try w.print("return {s} {s}.", .{ if (code_status.has_success_codes) "switch(" else "", loader_name_ });
                try printCommandName(command_name, w);
                try w.writeAll(".?(");
                try printParams(command, r, w);
                try w.writeByte(')');
                if (code_status.has_success_codes) {
                    try w.writeAll("){");
                    var it: CommaIterator = .{ .text = command.success_codes };
                    while (it.next()) |code| {
                        const stripped = stripPrefix(code, "VK_");
                        try w.print(".{s}=>", .{stripped});
                        if (code_status.success_only) {
                            if (code_status.is_create) {
                                try w.writeAll("temp,");
                            } else {
                                try w.writeAll("{},");
                            }
                        } else {
                            try w.print(".{s},", .{stripped});
                        }
                    }
                    it = .{ .text = command.error_codes };
                    while (it.next()) |code| {
                        if (shouldErrorBeSkipped(code)) continue;
                        const stripped = stripPrefix(code, "VK_");
                        try w.print(".{[name]s} => error.{[name]s},", .{ .name = stripped });
                    }
                    try w.writeByte('}');
                }
                try w.writeAll(";}");
            }
        };

        var command_it = registry.commands.iterator();
        while (command_it.next()) |command_entry| {
            const command_name = command_entry.key_ptr.*;
            const command = command_entry.value_ptr.*;
            if (isGlobalCommand(command, registry)) {
                const code_status: helper.CodeStatus = .parse(command, command_name);
                try helper.printCommand(command, registry, command_name, "Global", writer, code_status);
                try writer.writeAll(
                    \\const f = switch(comptime config.globals){
                    \\.load_time=>extern_global_functions,
                    \\.run_time => globals,
                    \\};
                );

                try helper.printFunctionBody(
                    command,
                    command_name,
                    "f",
                    writer,
                    code_status,
                    registry,
                );
            }
        }

        const instance_handle = registry.types.getPtr("VkInstance") orelse @panic("Failed to find VkInstance");
        var types_it = registry.types.iterator();
        while (types_it.next()) |registry_type| {
            if (registry_type.value_ptr.type != .handle) continue;
            if (!registry_type.value_ptr.type.handle.dispatchable) continue;
            try writer.print("pub const {[name]s}Wrapper = struct{{handle:{[name]s},", .{ .name = stripPrefix(registry_type.key_ptr.*, "Vk") });
            command_it = registry.commands.iterator();
            while (command_it.next()) |c_entry| {
                const command_name = c_entry.key_ptr.*;
                const command = c_entry.value_ptr.*;
                if (command.params.len == 0) continue;
                const first = command.params[0].c_var.type.base.name;
                const handle = registry.types.getPtr(first) orelse continue;
                if (handle != registry_type.value_ptr) continue;
                const is_instance = handle == instance_handle;
                const group = if (is_instance) "Instance" else "Device";
                const code_status: helper.CodeStatus = .parse(command, command_name);
                try helper.printCommand(command, registry, command_name, group, writer, code_status);
                try helper.printFunctionBody(
                    command,
                    command_name,
                    if (is_instance) "instance_loader" else "device_loader",
                    writer,
                    code_status,
                    registry,
                );
            }

            try writer.writeAll("};");
        }
        try writer.writeAll("};}");
    }

    fn printExtensions(registry: Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll("pub const Extension = enum{pub const Type = enum{device, instance};");
        for (registry.extensions) |e| {
            try printExtension(e, writer);
        }
        try writer.writeAll("pub fn getType(self: @This()) Type{return switch(self){");
        for (registry.extensions) |e| {
            try writer.print(".{s}=>.{t},", .{ stripPrefix(e.name.name, "VK_"), e.kind });
        }
        try writer.writeAll("};}");

        try writer.writeAll(
            \\fn isSatisfied(self: @This(), apiVersion: ApiVersion, bitmask: Bitmask) bool{
            \\maybeUnused(.{apiVersion, bitmask});
            \\return switch(self){
        );
        for (registry.extensions) |e| {
            try writer.print(".{s}=>", .{stripPrefix(e.name.name, "VK_")});
            if (e.depends) |d| {
                try printDependencies(d, writer);
            } else {
                try writer.writeAll("true");
            }
            try writer.writeByte(',');
        }
        try writer.writeAll("};}");

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
            \\pub fn filter(comptime extensions: []const @This(), comptime @"type": Type) []const @This(){
            \\var result: [extensions.len]@This() = undefined;
            \\var count = 0;
            \\for(extensions) |e| if(e.getType() == @"type") {
            \\result[count] = e;
            \\count += 1;
            \\};
            \\const final = result[0..count].*;
            \\return &final;
            \\}
            \\const Bitmask = std.enums.EnumSet(@This());
            \\/// Returns the first extension found for which there are missing dependencies.
            \\/// If all dependencies are satified, returns `null`
            \\pub fn missingDependenciesFor(ext: []const @This(), apiVersion: ApiVersion) ?@This(){
            \\const bitmask = .initMany(ext);
            \\for(ext) |e| if(!e.isSatisfied(apiVersion, bitmask)) return e;
            \\return true;
            \\}
            \\/// Whether `self` is contained in `extensions`
            \\pub fn containedIn(self:@This(),extensions:[]const @This())bool{
            \\for(extensions)|e| if(e == self) return true;
            \\return false;
            \\}
            \\pub const Names = struct{ device: []const []const u8, instance: []const [] const u8};
            \\pub fn getFilteredVkNames(comptime ext: []const @This()) Names{
            \\return .{ .device = getVkNames(filter(ext, .device)), .instance = getVkNames(filter(ext,.instance)),};
            \\}
            \\};
        );
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
                        try writer.print("bitmask.isSet(.{s})", .{stripPrefix(word, "VK_")});
                    }
                    d = d[end..];
                },
            }
        }
    }
    fn printExtension(e: Registry.Extension, writer: *Writer) Writer.Error!void {
        try writer.print("\n/// {t} extension\n", .{e.kind});
        if (e.promoted) |p| {
            try writer.print("\n/// Promoted to {s}\n", .{p});
        }
        if (e.depends) |d| {
            try writer.print("\n/// depends on {s}\n", .{d});
        }
        try writer.print("{s},", .{stripPrefix(e.name.name, "VK_")});
    }
    fn shouldErrorBeSkipped(name: []const u8) bool {
        // OVERRIDE: Skipping undefined behavior errors
        if (enumFromName(enum { VK_ERROR_UNKNOWN, VK_ERROR_VALIDATION_FAILED }, name)) |_| return true;
        return false;
    }

    fn printResultEntry(name: []const u8, writer: *Writer) Writer.Error!void {
        if (shouldErrorBeSkipped(name)) return;
        try writer.print("{[name]s}=@intFromEnum(Result.{[name]s}),", .{ .name = stripPrefix(name, "VK_") });
    }
    fn printCommandName(name: []const u8, writer: *Writer) Writer.Error!void {
        const stripped = stripPrefix(name, "vk");
        if (stripped.len == 0) @panic("Empty command name");
        try writer.writeByte(std.ascii.toLower(stripped[0]));
        try writer.writeAll(stripped[1..]);
    }
    pub fn printCommands(registry: Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\
            \\/// Any of these is sufficient to satisfy command requirements
            \\pub const CommandDependencyRequirements = struct{
            \\version: ApiVersion,
            \\extensions: []const Extension,
            \\pub fn satifies(self: @This(), requirements: @This()) bool{
            \\if(self.version.gt(requirements.version)) return true;
            \\for(requirements.extensions) |e| if(e.containedIn(self.extensions)) return true;
            \\return false;
            \\}
            \\};
        );
        try printExternGlobalFunctions(registry, writer);
        try printCommandGroup(registry, writer);
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
            return .{ .name = stripPrefix(name, "VK_") };
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.name);
        }
    };
    const CommandReturnType = union(enum) {
        codes: CommandTypeName,
        base: CBaseType,

        pub fn parse(command_name: CommandTypeName, command: Registry.Command) @This() {
            return if (command.success_codes.len != 0)
                .{ .codes = command_name }
            else
                .{ .base = .{ .v = command.ret } };
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self) {
                .base => |b| try writer.print("{f}", .{b}),
                .codes => |codes| try writer.print("{f}Result", .{codes}),
            }
        }
    };

    pub const CommandReturnTypeDeclaration = union(enum) {
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
        fn printCode(name: []const u8, writer: *Writer) Writer.Error!void {
            const n: ConstantName = .parse(name);
            try writer.print(
                \\{[name]f} = @intFromEnum(Result.{[name]f}),
            , .{ .name = n });
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self) {
                .empty => {},
                .codes => |codes| {
                    try writer.print(
                        \\pub const {f}Result = enum(@typeInfo(Result).@"enum".tag_type){{
                    , .{codes.command_name});
                    var it: CommaIterator = .{ .text = codes.success_codes };
                    while (it.next()) |c| {
                        try printCode(c, writer);
                    }

                    it = .{ .text = codes.error_codes };
                    while (it.next()) |c| {
                        try printCode(c, writer);
                    }
                    try writer.writeAll("};");
                }
            }
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
    fn printExternGlobalFunctions(registry: Registry, writer: *Writer) Writer.Error!void {
        try writer.writeAll(
            \\
            \\/// Provides global commands as load-time loaded functions.
            \\pub const extern_global_commands = struct{
        );
        var it = registry.commands.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const command = entry.value_ptr.*;
            if (!isGlobalCommand(command, registry)) continue;
            const provider: Provider = .{ .p = command.providers };
            const command_name: CommandFunctionName = .parseFromText(name);
            const params: Params = .{ .params = command.params };
            try writer.print(
                \\{[provider]f}
                \\extern "vulkan-1" fn {[raw_name]s}(
                \\{[params]f}
                \\) callconv(vulkan_api) {[command_group]s}.{[name]f}.getReturnType();
                \\pub const {[name]f} = {[raw_name]s};
            , .{
                .provider = provider,
                .name = command_name,
                .raw_name = name,
                .params = params,
                .command_group = command_group_name,
            });
        }
        try writer.writeAll("};");
    }
    pub fn printCommandGroup(registry: Registry, writer: *Writer) Writer.Error!void {
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
                        "99",
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
                    try w.print("{s},", .{v.c_var.name});
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
                    .codes => |codes| try w.print(command_group_name ++ ".{f}Result", .{codes}),
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
                    \\  loader: *const @This(),
                    \\  {[params]f}
                    \\) {[ret]f}{{
                    \\return loader.ptrs.{[command_name]f}.?(
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
            \\pub fn isSatisfied(command: @This(), provided: CommandDependencyRequirements) bool{
            \\    return provided.satifies(command.requirements());
            \\}
            \\pub const LoaderType = enum{ global, instance, device };
            \\pub fn loaderType(self: @This()) LoaderType{
            \\    const Type = self.getType();
            \\    const info = @typeInfo(Type).@"fn";
            \\    if(info.params.len == 0) return .global;
            \\    const first = info.params[0];
            \\    if(!isDispatchableHandle(first.type)) return .global;
            \\    if(first.type.? == Instance) return .instance;
            \\    return .device;
            \\}
        ;
        const loader_preamble =
            \\pub fn 
        ++ loader_name ++
            \\(commands: [] 
        ++ command_group_name ++
            \\) type{
            \\const filtered = filterCommands(commands);
            \\return struct{
            \\      pub const global_count = filtered.global.len;
            \\      pub const instance_count = filtered.instance.len;
            \\      pub const device_count = filtered.device.len;
            \\      pub const Ptrs = MakePtrGroup(filtered.global ++ filtered.instance ++ filtered.device);
            \\      ptrs: Ptrs,
            \\
            \\      fn getNames(comptime start: usize, comptime len: usize) [len][]const u8{
            \\          var names: [len][]const u8 = undefined;
            \\          for(&names, commands[start..][0..len]) |*n, c|{
            \\              n.* = c.getVkName();
            \\          }
            \\          return names;
            \\      }
            \\      fn getPtrs(self: *@This(), comptime start: usize, comptime len: usize) [len]PfnVoidFunction{
            \\          const ptrs: *[commands.len]PfnVoidFunction = @ptrCast(self.ptrs);
            \\          return ptrs.*[start..][0..len];
            \\      }
            \\      pub fn initGlobalCommands(self: *@This(), loader: anytype) void{
            \\          const ptrs = self.getPtrs(0, global_count);
            \\          const names = getNames(0, global_count);
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = loader(.null_handle, name);
            \\          }
            \\      }
            \\      pub fn initInstanceCommands(self: *@This(), loader: anytype, instance: Instance) void{
            \\          const ptrs = self.getPtrs(global_count, instance_count);
            \\          const names = getNames(global_count, instance_count);
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = loader(instance, name);
            \\          }
            \\      }
            \\      pub fn initDeviceCommands(self: *@This(), loader: anytype, device: Device) void{
            \\          const ptrs = self.getPtrs(global_count + instance_count, device_count);
            \\          const names = getNames(global_count + instance_count, device_count);
            \\          for(ptrs, names) |*p, name|{
            \\              p.* = loader(device, name);
            \\          }
            \\      }
        ;

        try writer.print(
            \\pub const {[command_group_name]s}=enum{{
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
            .command_group_name = command_group_name,
            .command_list = command_list,
            .command_signatures = signature_group,
            .conv_functions = conv_functions,
            .requirements = requirements,
            .loader_preamble = loader_preamble,
            .declaration_group = declaration_group,
        });
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
        try render.render(registry, &writer.writer);
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
