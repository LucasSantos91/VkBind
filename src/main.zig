const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const panic = std.debug.panic;
const slice_tools = @import("slice_tools");
const enumFromName = slice_tools.enums.fromName;

const panics = struct {
    fn unexpectedEnd() noreturn {
        @panic("Unexpected end of stream");
    }
    fn readFailed() noreturn {
        @panic("Failed to read from input");
    }
    fn streamTooLong() noreturn {
        @panic("Insufficient buffer for reading");
    }
    pub fn reader(e: Reader.Error) noreturn {
        switch (e) {
            Reader.Error.EndOfStream => unexpectedEnd(),
            Reader.Error.ReadFailed => readFailed(),
        }
    }
    pub fn takeDelimiter(e: error{ StreamTooLong, ReadFailed }) noreturn {
        switch (e) {
            error.StreamTooLong => streamTooLong(),
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

const xml = struct {
    pub fn goToTag(reader: *Reader) void {
        _ = reader.discardDelimiterInclusive('<') catch |e| panics.reader(e);
    }
    pub fn closeTag(reader: *Reader) void {
        _ = reader.discardDelimiterInclusive('>') catch |e| panics.reader(e);
    }
    pub fn getTagText(reader: *Reader) []const u8 {
        var len: usize = 0;
        while (true) {
            const text = reader.peekGreedy(len + 1) catch |e| panics.reader(e);
            if (std.mem.findAny(u8, text[len..], " >")) |i| {
                const n = len + i;
                reader.toss(n);
                return text[0..n];
            }
            len = text.len;
        }
    }
    pub fn seekTags(reader: *Reader, comptime TagsEnum: type) TagsEnum {
        while (true) {
            goToTag(reader);
            const text = getTagText(reader);
            if (enumFromName(TagsEnum, text)) |tag| return tag;
        }
    }
    pub fn seekTagsAndClose(reader: *Reader, comptime TagsEnum: type) TagsEnum {
        const ret = seekTags(reader, TagsEnum);
        closeTag(reader);
        return ret;
    }

    pub fn goToAttrKey(reader: *Reader) bool {
        while (true) {
            const text = reader.peekGreedy(1) catch |e| panics.reader(e);
            const not_space_index = std.mem.findNone(u8, text, " ") orelse {
                reader.tossBuffered();
                continue;
            };
            switch (text[not_space_index]) {
                '>' => {
                    reader.toss(not_space_index + 1);
                    return false;
                },
                '/' => {
                    reader.toss(not_space_index + 2);
                    return false;
                },
                else => {
                    reader.toss(not_space_index);
                    return true;
                },
            }
        }
    }
    pub fn getAttrKey(reader: *Reader) ?[]u8 {
        if (!goToAttrKey(reader)) return null;
        return reader.takeDelimiter('=') catch |e| panics.takeDelimiter(e);
    }
    pub fn discardAttrValue(reader: *Reader) void {
        for (0..2) |_| {
            _ = reader.discardDelimiterInclusive('"') catch |e| panics.reader(e);
        }
    }
    pub fn getAttrValue(reader: *Reader) []u8 {
        return reader.takeDelimiter('"') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
    }

    pub fn nextAttr(reader: *Reader, comptime KeysOfInterest: type) ?KeysOfInterest {
        while (getAttrKey(reader)) |text| {
            if (enumFromName(KeysOfInterest, text)) |key| {
                _ = reader.discardDelimiterInclusive('"') catch |e| panics.reader(e);
                return key;
            } else {
                discardAttrValue(reader);
            }
        }
        return null;
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
    fn expect(reader: *Reader, marker: []const u8) void {
        const found = reader.take(marker.len) catch |e|
            switch (e) {
                Reader.Error.EndOfStream => panic("Expected marker: {s}. found end-of-stream", .{marker}),
                Reader.Error.ReadFailed => panics.readFailed(),
            };
        if (!std.mem.eql(u8, found, marker)) {
            panic("Expected marker: {s}. found: {s}", .{ marker, found });
        }
    }
    fn stripPrefix(reader: *Reader, prefix: []const u8) bool {
        const peek = reader.peek(prefix.len) catch |e| switch (e) {
            Reader.Error.EndOfStream => return false,
            Reader.Error.ReadFailed => panics.readFailed(),
        };
        if (std.mem.eql(u8, peek, prefix)) {
            reader.toss(prefix.len);
            return true;
        }
        return false;
    }
    fn allocToDelimiter(reader: *Reader, allocator: Allocator, delimiter: u8) []u8 {
        var writer = Writer.Allocating.init(allocator);
        _ = reader.streamDelimiter(&writer.writer, delimiter) catch |e| switch (e) {
            Reader.StreamError.ReadFailed => panics.readFailed(),
            Reader.StreamError.WriteFailed => panics.oom(),
            Reader.StreamError.EndOfStream => panics.unexpectedEnd(),
        };
        reader.toss(1);
        return writer.toOwnedSlice() catch panics.oom();
    }
    fn allocToDelimiterAsLower(reader: *Reader, allocator: Allocator, delimiter: u8) []u8 {
        var alloc_writer = Writer.Allocating.init(allocator);
        const writer = &alloc_writer.writer;
        while (true) {
            const c = reader.takeByte() catch |e| panics.reader(e);
            if (c == delimiter) break;
            const c_lower = std.ascii.toLower(c);
            writer.writeByte(c_lower) catch panics.oom();
        }
        return alloc_writer.toOwnedSlice() catch panics.oom();
    }
    pub const Api = enum {
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
    const ParseContext = struct {
        allocator: Allocator,
        api: Api,
        authors: Authors,
        reader: *Reader,
    };
    pub const Comment = struct {
        data: []const u8 = &.{},

        fn parseCommon(ctx: *const ParseContext, delimiter: u8) @This() {
            _ = stripPrefix(ctx.reader, "// ");
            const ret: @This() = .{
                .data = allocToDelimiter(ctx.reader, ctx.allocator, delimiter),
            };
            return ret;
        }
        /// Parses comment="..". Assumes we are at the '="'
        fn parseQuotes(
            ctx: *const ParseContext,
        ) @This() {
            return parseCommon(ctx, '"');
        }

        /// Parses <comment>...</comment>. Assumes we are at the '<comment>'
        fn parseTags(ctx: *const ParseContext) @This() {
            const ret = parseCommon(ctx, '<');
            expect(ctx.reader, "/comment>");
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            if (self.data.len == 0) return;
            try writer.print("\n/// {s}\n", .{self.data});
        }
    };
    pub const Primitive = enum {
        void,
        u8,
        u16,
        u32,
        u64,
        c_int,
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
            int,
            int32_t,
            int64_t,
            float,
            double,
            size_t,
        };

        pub fn parse(ctx: *const ParseContext) ?@This() {
            const text = ctx.reader.peekDelimiterExclusive('<') catch |e| switch (e) {
                Reader.DelimiterError.ReadFailed => panics.readFailed(),
                Reader.DelimiterError.EndOfStream => @panic("Failed to find ending of primitive type"),
                Reader.DelimiterError.StreamTooLong => panics.streamTooLong(),
            };
            const ret = parseFromText(text) orelse return null;
            ctx.reader.toss(text.len + 1);
            return ret;
        }
        pub fn parseFromText(text: []const u8) ?@This() {
            const e = slice_tools.enums.fromName(CPrimitive, text) orelse return null;
            return switch (e) {
                .void => .void,
                .char, .uint8_t => .u8,
                .uint16_t => .u16,
                .uint32_t => .u32,
                .uint64_t => .u64,
                .int => .c_int,
                .int32_t => .i32,
                .int64_t => .i64,
                .float => .f32,
                .double => .f64,
                .size_t => .usize,
            };
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs == rhs;
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
            return std.mem.eql(u8, @tagName(lhs), rhs);
        }
    };

    pub const PrimitiveTypeName = struct {
        primitive: Primitive,

        pub fn parse(ctx: *const ParseContext) ?@This() {
            return .{
                .primitive = Primitive.parse(ctx) orelse return null,
            };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{t}", .{self.primitive});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.primitive == rhs.primitive;
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
            return lhs.primitive.eqlRaw(rhs);
        }
    };
    pub const AuthorTag = struct {
        data: []const u8 = &.{},

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return std.mem.lessThan(u8, lhs.data, rhs.data);
        }
        pub fn endsInAuthor(self: @This(), name: []const u8) bool {
            return std.mem.endsWith(u8, name, self.data);
        }
        pub fn parse(reader: *Reader, allocator: Allocator) @This() {
            _ = reader.discardDelimiterInclusive('"') catch |e| switch (e) {
                Reader.Error.EndOfStream => @panic("Failed to find author tag name"),
                Reader.Error.ReadFailed => panics.readFailed(),
            };
            return .{ .data = allocToDelimiter(reader, allocator, '"') };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll(self.data);
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return std.mem.eql(u8, lhs.data, rhs.data);
        }
    };
    pub const Authors = struct {
        authors: []AuthorTag,

        const MaybeAuthor = struct {
            ptr: ?*const AuthorTag = null,
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                if (self.ptr) |p| {
                    try writer.print("{f}", .{p.*});
                }
            }
            pub fn endsInAuthor(self: @This(), name: []const u8) bool {
                const ptr = self.ptr orelse return true;
                return ptr.endsInAuthor(name);
            }
            pub fn stripAuthor(self: @This(), name: []const u8) []const u8 {
                const ptr = self.ptr orelse return name;
                return slice_tools.decreaseLen(name, ptr.data.len);
            }
            pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
                if (lhs.ptr) |p| {
                    return std.mem.eql(u8, p.data, rhs);
                } else return rhs.len == 0;
            }
            pub fn eql(lhs: @This(), rhs: @This()) bool {
                return lhs.ptr == rhs.ptr;
            }
        };
        pub fn find(self: @This(), name: []const u8) MaybeAuthor {
            for (self.authors) |*a| {
                if (a.endsInAuthor(name)) return .{ .ptr = a };
            }
            return .{};
        }
        pub fn findExact(self: @This(), name: []const u8) MaybeAuthor {
            for (self.authors) |*a| {
                if (std.mem.eql(u8, a.data, name)) return .{ .ptr = a };
            }
            return .{};
        }
        pub fn parse(ctx: *const ParseContext) @This() {
            var authors: std.ArrayList(AuthorTag) = .empty;
            while (true) switch (xml.seekTags(ctx.reader, enum { tag, @"/tags" })) {
                .@"/tags" => break,
                .tag => {
                    const new = authors.addOne(ctx.allocator) catch panics.oom();
                    new.* = .parse(ctx.reader, ctx.allocator);
                },
            };
            const result: @This() = .{ .authors = authors.toOwnedSlice(ctx.allocator) catch panics.oom() };
            return result;
        }
    };
    pub const NameVersion = struct {
        data: u8 = 0,

        pub fn parseText(text: []const u8) @This() {
            if (text.len == 0) return .{ .data = 0 };
            const n = std.fmt.parseInt(u8, text, 10) catch |e| switch (e) {
                error.Overflow => panic("Version too big: {s}", .{text}),
                error.InvalidCharacter => panic("Invalid character in version: {s}", .{text}),
            };
            return .{ .data = n };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            if (self.data != 0) {
                try writer.print("{}", .{self.data});
            }
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.data == rhs.data;
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
            const n = std.fmt.parseInt(u8, rhs, 10) catch return false;
            return lhs.data == n;
        }
    };
    pub const VulkanName = struct {
        root: []const u8 = &.{},
        author: Authors.MaybeAuthor = .{},
        version: NameVersion = .{},

        fn getVersionIndex(name: []const u8) usize {
            var i = name.len;
            while (i != 0) {
                i -= 1;
                const c = name[i];
                if (c < '0' or c > '9') {
                    i += 1;
                    break;
                }
            }
            return i;
        }
        pub fn parseText(ctx: *const ParseContext, name: []u8) @This() {
            const author = ctx.authors.find(name);
            const without_author = author.stripAuthor(name);
            const version_index = getVersionIndex(without_author);
            const version_text = without_author[version_index..];
            const version: NameVersion = .parseText(version_text);
            const root = without_author[0..version_index];
            return .{
                .root = ctx.allocator.dupe(u8, root) catch panics.oom(),
                .author = author,
                .version = version,
            };
        }
        pub fn parse(ctx: *const ParseContext, delimiter: u8) @This() {
            const peek = ctx.reader.takeDelimiter(delimiter) catch |e| switch (e) {
                error.ReadFailed => panics.readFailed(),
                error.StreamTooLong => panics.streamTooLong(),
            } orelse @panic("Unexpected end of stream while parsing name");
            return parseText(ctx, peek);
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}{f}{f}", .{
                self.root,
                self.version,
                self.author,
            });
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.version.eql(rhs.version) and
                lhs.author.eql(rhs.author) and
                std.mem.eql(u8, lhs.root, rhs.root);
        }
        pub fn eqlRaw(self: @This(), text: []const u8, ctx: *const ParseContext) bool {
            const version_index = getVersionIndex(text);
            const version_text = text[version_index..];
            const version: NameVersion = .parseText(version_text);
            if (!version.eql(self.version)) return false;
            const without_version = text[0..version_index];
            const author = ctx.authors.find(without_version);
            if (!author.endsInAuthor(without_version)) return false;
            const root = author.stripAuthor(without_version);
            return std.mem.eql(u8, self.root, root);
        }
    };
    pub const FuncpointerTypeName = struct {
        name: VulkanName = .{},

        const prefix = "PFN_vk";
        pub fn parse(ctx: *const ParseContext) ?@This() {
            if (!stripPrefix(ctx.reader, prefix)) return null;
            const ret: @This() = .{ .name = .parse(ctx, '<') };
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("Pfn{f}", .{self.name});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.name.eql(rhs.name);
        }
        pub fn eqlRaw(lhs: @This(), ctx: *const ParseContext, rhs: []const u8) bool {
            if (!std.mem.startsWith(u8, rhs, prefix)) return false;
            return lhs.name.eqlRaw(rhs[prefix.len..], ctx);
        }
    };
    pub const VkTypeName = struct {
        name: VulkanName = .{},

        pub fn parse(ctx: *const ParseContext, delimiter: u8) ?@This() {
            if (!stripPrefix(ctx.reader, "Vk")) return null;
            const ret: @This() = .{ .name = .parse(ctx, delimiter) };
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}", .{self.name});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.name.eql(rhs.name);
        }
        pub fn eqlRaw(self: @This(), ctx: *const ParseContext, text: []const u8) bool {
            if (!std.mem.startsWith(u8, text, "Vk")) return false;
            return self.name.eqlRaw(text[2..], ctx);
        }
    };
    pub const ForeignName = struct {
        data: []const u8,

        pub fn parse(ctx: *const ParseContext) @This() {
            return .{ .data = allocToDelimiter(ctx.reader, ctx.allocator, '<') };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}", .{self.data});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.eqlRaw(rhs.data);
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
            return std.mem.eql(u8, lhs.data, rhs);
        }
    };
    pub const GenericTypeName = union(enum) {
        funcptr: FuncpointerTypeName,
        primitive: PrimitiveTypeName,
        vk_type: VkTypeName,
        foreign: ForeignName,

        pub fn parse(ctx: *const ParseContext) @This() {
            defer xml.closeTag(ctx.reader);

            if (FuncpointerTypeName.parse(ctx)) |n| {
                return .{ .funcptr = n };
            }
            if (PrimitiveTypeName.parse(ctx)) |n| {
                return .{ .primitive = n };
            }
            if (VkTypeName.parse(ctx, '<')) |n| {
                return .{ .vk_type = n };
            }
            return .{ .foreign = .parse(ctx) };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self) {
                inline else => |n| try writer.print("{f}", .{n}),
            }
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            if (lhs != rhs) return false;
            return switch (lhs) {
                .funcptr => lhs.funcptr.eql(rhs.funcpointer),
                .primitive => lhs.primitive.eql(rhs.primitive),
                .vk_type => lhs.vk_type.eql(rhs.vk_type),
                .foreign => lhs.foreign.eql(rhs.foreign),
            };
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8, ctx: *const ParseContext) bool {
            return switch (lhs) {
                .funcptr => lhs.funcptr.eqlRaw(ctx, rhs),
                .primitive => lhs.primitive.eqlRaw(rhs),
                .vk_type => lhs.vk_type.eqlRaw(ctx, rhs),
                .foreign => lhs.foreign.eqlRaw(rhs),
            };
        }
    };

    pub const ConstantName = struct {
        root: []const u8 = &.{},
        author: Authors.MaybeAuthor = .{},

        pub fn parse(ctx: *const ParseContext) @This() {
            if (!stripPrefix(ctx.reader, "VK_")) @panic("Constant doesn't start with VK_");
            return parseIgnoreVK_(ctx);
        }
        pub fn parseText(ctx: *const ParseContext, text: []const u8) @This() {
            if (!std.mem.startsWith(u8, text, "VK_")) panic("Constant name doesn't start with VK_: {s}", .{text});
            return parseTextIgnoreVK_(ctx, text["VK_".len..]);
        }
        pub fn parseIgnoreVK_(ctx: *const ParseContext) @This() {
            const raw = ctx.reader.takeDelimiter('"') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
            return parseTextIgnoreVK_(ctx, raw);
        }
        pub fn parseTextIgnoreVK_(ctx: *const ParseContext, raw_: []const u8) @This() {
            const author = ctx.authors.find(raw_);
            var raw = raw_;
            if (author.ptr) |a| {
                raw = slice_tools.decreaseLen(raw, a.data.len);
                if (raw.len != 0) raw = slice_tools.decreaseLen(raw, 1);
            }
            if (raw.len == 0) {
                // Because of VkVendorId
                const p = author.ptr orelse @panic("Empty constant name");
                return .{
                    .root = p.data,
                    .author = .{},
                };
            }
            const data = ctx.allocator.alloc(u8, raw.len) catch panics.oom();
            _ = std.ascii.lowerString(data, raw);
            return .{
                .root = data,
                .author = author,
            };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("@\"{s}\"", .{self.root});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.author == rhs.author and std.mem.eql(u8, lhs.root, rhs.root);
        }
        pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
            if (!std.mem.eql(u8, rhs, "VK_")) return false;
            if (!std.mem.startsWith(u8, rhs, lhs.root)) return false;
            var remaining = rhs[lhs.root.len..];
            if (remaining.len == 0) return true;
            remaining = remaining[1..];
            return lhs.author.eqlRaw(remaining);
        }
    };
    pub fn discardPrefix(ctx: *const ParseContext, root: VkTypeName) void {
        if (!stripPrefix(ctx.reader, "VK_")) @panic("Enum doesn't start with VK_");
        var root_name = root.name.root;
        const possible_version = blk: while (true) {
            const slice = ctx.reader.peekDelimiterExclusive('_') catch |e| panics.delimiter(e);
            if (slice.len > root_name.len) break :blk slice;
            for (root_name[0..slice.len], slice) |r, s| {
                const r_cap = std.ascii.toUpper(r);
                if (r_cap != s) break :blk slice;
            }
            root_name = root_name[slice.len..];
            ctx.reader.toss(slice.len + 1);
        };
        if (root.name.version.eqlRaw(possible_version)) {
            ctx.reader.toss(possible_version.len + 1);
        }
    }

    const Bitmask = struct {
        const BitmaskName = struct {
            name: VkTypeName = .{},

            pub fn fromVkTypeName(name: VkTypeName) ?@This() {
                const suffix = "FlagBits";
                if (!std.mem.endsWith(u8, name.name.root, suffix)) return null;
                var result: @This() = .{ .name = name };
                const root = &result.name.name.root;
                root.* = slice_tools.decreaseLen(root.*, suffix.len);
                return result;
            }
            pub fn eql(lhs: @This(), rhs: @This()) bool {
                return lhs.name.eql(rhs.name);
            }
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                const base = self.name.name;
                try writer.print("{s}FlagBits{f}{f}", .{ base.root, base.author, base.version });
            }
            pub fn asFlags(self: @This()) AsFlags {
                return .{ .name = self.name };
            }

            const AsFlags = struct {
                name: VkTypeName,
                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    const base = self.name.name;
                    try writer.print("{s}Flags{f}{f}", .{ base.root, base.author, base.version });
                }
            };
        };
        const BitName = struct {
            name: ConstantName = .{},

            const bit_suffix = "_BIT";
            fn parseRemaining(ctx: *const ParseContext) @This() {
                const text = ctx.reader.takeDelimiter('"') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
                const i = std.mem.findLast(u8, text, bit_suffix) orelse {
                    return .{ .name = .parseTextIgnoreVK_(ctx, text) };
                };
                const root = text[0..i];
                const author_text = text[i + bit_suffix.len ..];
                const output = ctx.allocator.alloc(u8, root.len) catch panics.oom();
                _ = std.ascii.lowerString(output, root);
                const result: @This() = .{ .name = .{
                    .root = output,
                    .author = if (author_text.len != 0) ctx.authors.findExact(author_text[1..]) else .{},
                } };
                return result;
            }
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}", .{self.name});
            }

            pub fn eql(lhs: @This(), rhs: @This()) bool {
                return lhs.name.eql(rhs.name);
            }
            pub fn eqlRaw(lhs: @This(), rhs: []const u8) bool {
                const i = std.mem.findLast(u8, rhs, bit_suffix) orelse return false;
                const root = rhs[0..i];
                const author_text = rhs[i + bit_suffix.len ..];
                if (!lhs.name.author.eqlRaw(author_text)) return false;
                return std.mem.eql(u8, lhs.name.root, root);
            }
        };

        const Entry = struct {
            const Bitpos = struct {
                bitpos: u8,

                pub fn parse(ctx: *const ParseContext) @This() {
                    const slice = ctx.reader.takeDelimiter('"') catch |e| switch (e) {
                        error.ReadFailed => panics.readFailed(),
                        error.StreamTooLong => panics.streamTooLong(),
                    } orelse
                        @panic("Failed to find bitpos delimiter");
                    const n = std.fmt.parseInt(u8, slice, 10) catch |e| switch (e) {
                        error.Overflow => @panic("Bitpos too big"),
                        error.InvalidCharacter => @panic("Invalid bitpos"),
                    };
                    return .{ .bitpos = n };
                }

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    try writer.print("{}", .{self.bitpos});
                }
            };
            const BitAlias = struct {
                alias: BitName,
                comment: Comment,

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    try writer.print("{f}pub const {f}=@This().", .{ self.comment, self.alias });
                }
            };

            name: BitName,
            bitpos: Bitpos,
            comment: Comment,

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}{f}=1<<{f},", .{ self.comment, self.name, self.bitpos });
            }

            pub const AsFlags = struct {
                entry: *const Entry,

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    try writer.print("{f}{f}:bool=false,", .{ self.entry.comment, self.entry.name });
                }
            };
            pub fn asFlags(self: *const @This()) AsFlags {
                return .{ .entry = self };
            }
        };
        const Bits = enum {
            @"32",
            @"64",

            pub fn parse(ctx: *const ParseContext) @This() {
                const text = ctx.reader.takeDelimiter('"') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
                return parseFromText(text);
            }
            pub fn parseFromText(vk_flags: []const u8) @This() {
                return enumFromName(@This(), vk_flags) orelse panic("Unknown bitwidth: {s}", .{vk_flags});
            }
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("u{t}", .{self});
            }
        };

        name: BitmaskName = .{},
        bits: Bits = .@"32",
        comment: Comment = .{},
        entries: []Entry = &.{},
        aggregates: []Enum.Entry = &.{},
        aliases: []BitmaskName = &.{},

        pub fn sortBits(self: *@This()) void {
            const lessThan = struct {
                pub fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                    return lhs.bitpos.bitpos < rhs.bitpos.bitpos;
                }
            }.lessThan;
            std.sort.pdq(Entry, self.entries, {}, lessThan);
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{[comment]f}pub const {[name]f}=enum({[bits]f}){{", .{
                .comment = self.comment,
                .name = self.name,
                .bits = self.bits,
            });
            for (self.entries) |e| {
                try writer.print("{f}", .{e});
            }
            try writer.writeAll("};");
            for (self.aliases) |alias| {
                try writer.print("pub const {f}={f};", .{ alias, self.name });
            }
            try writer.print("{[comment]f}pub const {[flags_name]f}=packed struct({[bits]f}){{", .{
                .comment = self.comment,
                .flags_name = self.name.asFlags(),
                .bits = self.bits,
            });
            if (self.entries.len != 0) {
                try writer.print("{f}", .{self.entries[0].asFlags()});
                var last_bitpos = self.entries[0].bitpos.bitpos;
                for (self.entries[1..]) |e| {
                    const diff = e.bitpos.bitpos - last_bitpos -| 1;
                    if (diff > 0) {
                        try writer.print("_reserved{f}:u{}=false,", .{ e.bitpos, diff });
                    }
                    last_bitpos = e.bitpos.bitpos;
                    try writer.print("{f}", .{e.asFlags()});
                }
            }
            for (self.aggregates) |e| {
                try writer.print("{f}pub const {f}:@This() = @bitCast({s});", .{ e.comment, e.name, e.value });
            }
            try writer.writeAll("};");
            for (self.aliases) |alias| {
                try writer.print("pub const {f}={f};", .{ alias.asFlags(), self.name.asFlags() });
            }
        }
        pub fn parseEntries(self: *@This(), ctx: *const ParseContext) void {
            var entries: std.ArrayList(Entry) = .empty;
            var aggregates: std.ArrayList(Enum.Entry) = .empty;
            while (true) switch (xml.seekTags(ctx.reader, enum { @"enum", @"/enums" })) {
                .@"enum" => self.parseEntry(ctx, &entries, &aggregates),

                .@"/enums" => break,
            };
            self.entries = entries.toOwnedSlice(ctx.allocator) catch panics.oom();
            self.aggregates = aggregates.toOwnedSlice(ctx.allocator) catch panics.oom();
        }
        pub fn parseEntry(self: *@This(), ctx: *const ParseContext, entries: *std.ArrayList(Entry), aggregates: *std.ArrayList(Enum.Entry)) void {
            const E = enum { value, bitpos, api };
            sw: switch (xml.nextAttr(ctx.reader, E) orelse return) {
                .api => {
                    if (!ctx.api.match(xml.getAttrValue(ctx.reader))) return;
                    const next = xml.nextAttr(ctx.reader, enum { value, bitpos }) orelse return;
                    const enum_trick: E = @enumFromInt(@intFromEnum(next));
                    continue :sw enum_trick;
                },
                .value => aggregates.append(ctx.allocator, self.parseAggregate(ctx)) catch panics.oom(),
                .bitpos => entries.append(ctx.allocator, self.parseBitpos(ctx)) catch panics.oom(),
            }
        }
        fn discardBitPrefix(self: *const @This(), ctx: *const ParseContext) void {
            _ = xml.nextAttr(ctx.reader, enum { name }) orelse @panic("Nameless bit");
            discardPrefix(ctx, self.name.name);
        }
        fn parseAggregate(self: *@This(), ctx: *const ParseContext) Enum.Entry {
            const v = xml.getAttrValue(ctx.reader);
            const value = ctx.allocator.dupe(u8, v) catch panics.oom();
            self.discardBitPrefix(ctx);
            const name: ConstantName = .parseIgnoreVK_(ctx);
            const comment: Comment = if (xml.nextAttr(ctx.reader, enum { comment })) |_|
                .parseQuotes(ctx)
            else
                .{};
            return .{
                .name = name,
                .value = value,
                .comment = comment,
            };
        }
        fn parseBitpos(self: *@This(), ctx: *const ParseContext) Entry {
            const bitpos: Entry.Bitpos = .parse(ctx);
            self.discardBitPrefix(ctx);
            const name: BitName = .parseRemaining(ctx);
            const comment: Comment = if (xml.nextAttr(ctx.reader, enum { comment })) |_|
                .parseQuotes(ctx)
            else
                .{};
            return .{
                .name = name,
                .bitpos = bitpos,
                .comment = comment,
            };
        }
    };

    const Enum = struct {
        const Entry = struct {
            name: ConstantName = .{},
            value: []u8 = &.{},
            comment: Comment = .{},

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}{f}={s},", .{ self.comment, self.name, self.value });
            }
        };

        name: VkTypeName = .{},
        comment: Comment = .{},
        entries: []Entry = &.{},
        aliases: []VkTypeName = &.{},

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}pub const {f}=enum(c_int){{", .{ self.comment, self.name });
            for (self.entries) |e| {
                try writer.print("{f}", .{e});
            }
            try writer.writeAll("};");
            for (self.aliases) |alias| {
                try writer.print("pub const {f}={f};", .{ alias, self.name });
            }
        }
        pub fn parseEntries(self: *@This(), ctx: *const ParseContext) void {
            var entries: std.ArrayList(Entry) = .empty;
            while (true) switch (xml.seekTags(ctx.reader, enum { @"enum", @"/enums" })) {
                .@"enum" => self.parseEntry(ctx, &entries),

                .@"/enums" => break,
            };
            self.entries = entries.toOwnedSlice(ctx.allocator) catch panics.oom();
        }
        pub fn parseEntry(self: *@This(), ctx: *const ParseContext, entries: *std.ArrayList(Entry)) void {
            const E = enum { value, api };
            sw: switch (xml.nextAttr(ctx.reader, E) orelse return) {
                .api => {
                    if (!ctx.api.match(xml.getAttrValue(ctx.reader))) return;
                    _ = xml.nextAttr(ctx.reader, enum { value }) orelse return;
                    continue :sw .value;
                },
                .value => entries.append(ctx.allocator, self.parseEnumValue(ctx)) catch panics.oom(),
            }
        }
        fn parseEnumValue(self: *@This(), ctx: *const ParseContext) Entry {
            const v = xml.getAttrValue(ctx.reader);
            const value = ctx.allocator.dupe(u8, v) catch panics.oom();
            _ = xml.nextAttr(ctx.reader, enum { name }) orelse @panic("Nameless enum entry");
            discardPrefix(ctx, self.name);
            const name: ConstantName = .parseIgnoreVK_(ctx);
            const comment: Comment = if (xml.nextAttr(ctx.reader, enum { comment })) |_|
                .parseQuotes(ctx)
            else
                .{};
            return .{
                .name = name,
                .value = value,
                .comment = comment,
            };
        }
    };

    const Command = struct {
        return_value: ZigType,
        params: []ZigVar = &.{},
        success_codes: []u8 = &.{},
        error_codes: []u8 = &.{},
        aliases: [][]u8 = &.{},
    };
    const Handle = struct {
        const Kind = enum {
            dispatchable,
            non_dispatchable,
        };
        name: VkTypeName,
        kind: Kind,
        aliases: []VkTypeName = &.{},

        pub fn parse(ctx: *const ParseContext) @This() {
            _ = ctx.reader.discardDelimiterInclusive('>') catch |e| panics.reader(e);
            const kind_len = ctx.reader.discardDelimiterInclusive('<') catch |e| panics.reader(e);
            const kind: Kind = switch (kind_len == "VK_DEFINE_HANDLE".len + 1) {
                true => .dispatchable,
                false => .non_dispatchable,
            };
            for (0..2) |_| {
                _ = ctx.reader.discardDelimiterInclusive('>') catch |e| panics.reader(e);
            }
            const name = VkTypeName.parse(ctx, '<') orelse @panic("Handle doesn't start with Vk prefix");
            return .{ .name = name, .kind = kind };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("pub const {f}=enum({s}){{null_handle, _}};", .{
                self.name,
                switch (self.kind) {
                    .dispatchable => "usize",
                    .non_dispatchable => "u64",
                },
            });
            for (self.aliases) |alias| {
                try writer.print("pub const {f}={f};", .{ alias, self.name });
            }
        }
        pub fn addAlias(self: *@This(), ctx: *const ParseContext, alias: VkTypeName) void {
            self.aliases = ctx.allocator.realloc(self.aliases, self.aliases.len + 1) catch panics.oom();
            self.aliases[self.aliases.len - 1] = alias;
        }
    };
    const StructOrUnion = struct {
        const Member = struct {
            member: ZigVar,
            comment: Comment = .{},

            pub fn parse(ctx: *const ParseContext, s_type: *ConstantName, members: []const Member) ?@This() {
                var result: @This() = .{ .member = .{
                    .name = &.{},
                    .type = .{
                        .c_type = undefined,
                    },
                } };
                while (xml.nextAttr(ctx.reader, enum { api, values, optional, len })) |t| switch (t) {
                    .api => {
                        if (!ctx.api.match(xml.getAttrValue(ctx.reader))) return null;
                    },
                    .values => {
                        discardPrefix(ctx, .{ .name = .{ .root = "StructureType" } });
                        s_type.* = .parseIgnoreVK_(ctx);
                    },
                    .optional => {
                        var it: CommaIterator = .{ .text = xml.getAttrValue(ctx.reader) };
                        var ptr: [*]ZigType.PtrExtra = &result.member.type.ptr_extra;
                        const limit = ptr + BaseCType.max_ptr_layer;
                        while (it.next()) |text| {
                            if (ptr == limit) @panic("Too many layers of pointers");
                            ptr[0].optional = std.mem.eql(u8, text, "true");
                            ptr += 1;
                        }
                    },
                    .len => {
                        var it: CommaIterator = .{ .text = xml.getAttrValue(ctx.reader) };
                        var ptr: [*]ZigType.PtrExtra = &result.member.type.ptr_extra;
                        const limit = ptr + BaseCType.max_ptr_layer;
                        while (it.next()) |text| {
                            if (ptr == limit) @panic("Too many layers of pointers");
                            if (enumFromName(enum { @"null-terminated", @"1" }, text)) |k| {
                                switch (k) {
                                    .@"null-terminated" => {
                                        ptr[0].size = .null_terminated;
                                    },
                                    .@"1" => {
                                        ptr[0].size = .single;
                                    },
                                }
                            } else {
                                ptr[0].size = .many;
                                ptr[0].optional = blk: {
                                    for (members) |m| {
                                        if (std.mem.eql(u8, m.member.name, text)) {
                                            break :blk m.member.type.ptr_extra[0].optional;
                                        }
                                    }
                                    break :blk true;
                                };
                            }
                        }
                        ptr += 1;
                    },
                };

                const c_var: CVar = .parse(ctx);
                result.member.type.c_type = c_var.type;
                result.member.name = c_var.name;

                switch (xml.seekTagsAndClose(ctx.reader, enum { comment, @"/member" })) {
                    .comment => {
                        result.comment = .parseTags(ctx);
                    },
                    .@"/member" => {},
                }
                return result;
            }
            fn formatAsStruct(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}{f}", .{ self.comment, self.member });
                const t = &self.member.type;
                if (t.ptr_extra[0].optional) {
                    try writer.print("=nullValue({f})", .{self.member.type});
                }
            }
            fn formatAsUnion(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}{f}", .{ self.comment, self.member });
            }
            pub const AsStruct = struct {
                member: *const Member,

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    try self.member.formatAsStruct(writer);
                }
            };
            pub const AsUnion = struct {
                member: *const Member,

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    try self.member.formatAsUnion(writer);
                }
            };
            pub fn asStruct(self: *const @This()) @This().AsStruct {
                return .{ .member = self };
            }
            pub fn asUnion(self: *const @This()) @This().AsUnion {
                return .{ .member = self };
            }
        };
        name: VkTypeName = .{},
        comment: Comment = .{},
        members: []Member = &.{},
        aliases: []VkTypeName = &.{},
        s_type: ConstantName = .{},

        pub fn parse(ctx: *const ParseContext, structs: *std.ArrayList(StructOrUnion)) void {
            _ = xml.nextAttr(ctx.reader, enum { name }) orelse @panic("Struct/Union without name");
            const name: VkTypeName = VkTypeName.parse(ctx, '"') orelse @panic("Struct/Union name doesn't start with Vk");
            var comment: Comment = .{};
            while (xml.nextAttr(ctx.reader, enum { alias, comment })) |t| switch (t) {
                .alias => {
                    const alias = xml.getAttrValue(ctx.reader);
                    for (structs.items) |*i| {
                        if (i.name.eqlRaw(ctx, alias)) {
                            i.aliases = slice_tools.allocated.concat(VkTypeName, i.aliases, &.{name}, ctx.allocator) catch panics.oom();
                            return;
                        }
                    }
                },
                .comment => {
                    comment = .parseQuotes(ctx);
                },
            };
            const new = structs.addOne(ctx.allocator) catch panics.oom();
            new.* = .{
                .name = name,
                .comment = comment,
                .members = undefined,
            };
            var members: std.ArrayList(Member) = .empty;
            while (true) switch (xml.seekTags(ctx.reader, enum { member, @"/type" })) {
                .member => {
                    members.append(ctx.allocator, Member.parse(ctx, &new.s_type, members.items) orelse continue) catch panics.oom();
                },
                .@"/type" => break,
            };
            new.members = members.toOwnedSlice(ctx.allocator) catch panics.oom();
        }

        fn formatStruct(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}pub const {f}=extern struct{{", .{ self.comment, self.name });
            var members = self.members;
            if (self.s_type.root.len != 0) {
                try writer.print("{f}=.{f},", .{ self.members[0].asStruct(), self.s_type });
                members = members[1..];
            }
            for (members) |m| {
                try writer.print("{f},", .{m.asStruct()});
            }
            try writer.writeAll("};");
            try self.printAliases(writer);
        }
        fn formatUnion(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}pub const {f}=extern union{{", .{ self.comment, self.name });
            for (self.members) |m| {
                try writer.print("{f},", .{m.asUnion()});
            }
            try writer.writeAll("};");
            try self.printAliases(writer);
        }
        pub const AsStruct = struct {
            self: *const StructOrUnion,
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try self.self.formatStruct(writer);
            }
        };
        pub fn asStruct(self: *const @This()) AsStruct {
            return .{ .self = self };
        }
        pub const AsUnion = struct {
            self: *const StructOrUnion,
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try self.self.formatUnion(writer);
            }
        };
        pub fn asUnion(self: *const @This()) AsUnion {
            return .{ .self = self };
        }
        pub fn printAliases(self: *const @This(), writer: *Writer) Writer.Error!void {
            for (self.aliases) |alias| {
                try writer.print("pub const {f}={f};", .{ alias, self.name });
            }
        }
    };

    const BaseCType = struct {
        const Kind = enum {
            @"const",
            mutable,

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                switch (self) {
                    .@"const" => try writer.writeAll("const "),
                    .mutable => {},
                }
            }
        };

        const max_ptr_layer = 2;

        ptrs: slice_tools.BoundedArray(Kind, max_ptr_layer) = .{},
        base_type: GenericTypeName = undefined,

        pub fn parse(ctx: *const ParseContext) @This() {
            var result: @This() = .{
                .base_type = undefined,
            };
            const b = ctx.reader.takeDelimiter('<') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
            if (std.mem.find(u8, b, "const")) |_| {
                result.ptrs.appendAssumeCapacity(.@"const");
            }
            xml.closeTag(ctx.reader);
            result.base_type = .parse(ctx);
            var after_type = ctx.reader.takeDelimiterExclusive('<') catch |e| panics.delimiter(e);
            if (std.mem.findScalar(u8, after_type, '*')) |i| {
                if (result.ptrs.len == 0) result.ptrs.appendAssumeCapacity(.mutable);
                after_type = after_type[i + 1 ..];
            }
            if (std.mem.findAny(u8, after_type, "*c")) |i| {
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

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            for (self.ptrs.constSlice()) |p| {
                try writer.print("[*c]{f}", .{p});
            }
            if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive.primitive == .void) {
                try writer.writeAll("anyopaque");
            } else {
                try writer.print("{f}", .{self.base_type});
            }
        }
    };

    const CType = struct {
        const Amount = union(enum) {
            const Literal = u16;
            const Array = union(enum) {
                literal: Literal,
                constant: ConstantName,

                pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                    switch (self) {
                        .literal => |l| try writer.print("[{}]", .{l}),
                        .constant => |c| try writer.print("[{f}]", .{c}),
                    }
                }
            };
            array: Array,
            bitfield: u8,
            single,

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                switch (self) {
                    .single => {},
                    .bitfield => |b| try writer.print("u{}", .{b}),
                    .array => |ar| try writer.print("{f}", .{ar}),
                }
            }
            pub fn parse(ctx: *const ParseContext) @This() {
                const amount = ctx.reader.peekDelimiterExclusive('<') catch |e| panics.delimiter(e);
                const i = std.mem.findAny(u8, amount, ":[") orelse {
                    ctx.reader.toss(amount.len);
                    return .single;
                };
                switch (amount[i]) {
                    ':' => {
                        const text = amount[i + 1 ..];
                        const ret: @This() = .{ .bitfield = std.fmt.parseInt(u8, text, 10) catch panic("Failed to parse bitfield width: {s}", .{text}) };
                        ctx.reader.toss(amount.len);
                        return ret;
                    },
                    '[' => {
                        ctx.reader.toss(i + 1);
                        var inside_brackets = ctx.reader.takeDelimiter(']') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
                        if (std.mem.findScalar(u8, inside_brackets, '>')) |j| {
                            inside_brackets = inside_brackets[j + 1 ..];
                            const k = std.mem.findScalar(u8, inside_brackets, '<') orelse @panic("Failed to find amount end");
                            return .{ .array = .{ .constant = .parseText(ctx, inside_brackets[0..k]) } };
                        } else return .{ .array = .{ .literal = std.fmt.parseInt(Literal, inside_brackets, 10) catch
                            panic("Failed to parse text as integer: {s}", .{inside_brackets}) } };
                    },
                    else => unreachable,
                }
            }
        };
        base: BaseCType = .{},
        amount: Amount = .single,

        pub fn parseBase(ctx: *const ParseContext) @This() {
            return .{ .base = .parse(ctx), .amount = undefined };
        }
        pub fn parseAmount(self: *@This(), ctx: *const ParseContext) void {
            self.amount = .parse(ctx);
        }

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            switch (self.amount) {
                .single, .array => try writer.print("{f}{f}", .{ self.base, self.amount }),
                .bitfield => |b| try writer.print("u{}", .{b}),
            }
        }
    };

    const CVar = struct {
        type: CType,
        name: []const u8,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:{f}", .{ self.name, self.type });
        }

        pub fn parse(ctx: *const ParseContext) @This() {
            var result: @This() = .{
                .type = .parseBase(ctx),
                .name = undefined,
            };
            _ = xml.seekTagsAndClose(ctx.reader, enum { name });
            result.name = allocToDelimiter(ctx.reader, ctx.allocator, '<');
            xml.closeTag(ctx.reader);
            result.type.parseAmount(ctx);
            return result;
        }
    };

    const ZigType = struct {
        const Size = enum {
            single,
            many,
            null_terminated,

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.writeAll(switch (self) {
                    .single => "*",
                    .many => "[*]",
                    .null_terminated => "[*:0]",
                });
            }
        };
        const PtrExtra = struct {
            optional: bool = false,
            size: Size = .single,
        };

        c_type: CType = .{},
        ptr_extra: [BaseCType.max_ptr_layer]PtrExtra = @splat(.{}),

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            if (self.c_type.amount == .bitfield) {
                try writer.print("{f}", .{self.c_type});
                return;
            }
            const ptrs = self.c_type.base.ptrs.constSlice();
            for (ptrs, self.ptr_extra[0..ptrs.len]) |kind, extra| {
                try writer.print("{s}{f}{f}", .{ if (extra.optional) "?" else "", extra.size, kind });
            }
            switch (self.c_type.amount) {
                .single => {},
                .array => |ar| {
                    try writer.print("{f}", .{ar});
                },
                .bitfield => unreachable,
            }
            const base = &self.c_type.base;
            if (base.ptrs.len != 0 and base.base_type == .primitive and base.base_type.primitive.primitive == .void) {
                try writer.writeAll("anyopaque");
            } else {
                try writer.print("{f}", .{base.base_type});
            }
        }
    };
    const ZigVar = struct {
        name: []const u8,
        type: ZigType = .{},

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:{f}", .{ self.name, self.type });
        }
    };
    const Funcpointer = struct {
        name: FuncpointerTypeName,
        ret_type: BaseCType,
        params: []CVar,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("pub const {f}=*const fn(", .{self.name});
            for (self.params) |p| {
                try writer.print("{f},", .{p});
            }
            try writer.print(")callconv(vulkan_api) {f};", .{self.ret_type});
        }
        pub fn parse(ctx: *const ParseContext) @This() {
            _ = xml.seekTagsAndClose(ctx.reader, enum { proto });
            var result: @This() = undefined;
            result.ret_type = .parse(ctx);
            _ = xml.seekTagsAndClose(ctx.reader, enum { name });
            result.name = FuncpointerTypeName.parse(ctx) orelse @panic("Failed to parse funcpointer name");
            var params: std.ArrayList(CVar) = .empty;
            while (true) switch (xml.seekTagsAndClose(ctx.reader, enum { param, @"/type" })) {
                .@"/type" => break,
                .param => params.append(ctx.allocator, .parse(ctx)) catch panics.oom(),
            };
            result.params = params.toOwnedSlice(ctx.allocator) catch panics.oom();
            return result;
        }
    };
    const Constant = struct {
        comment: []u8,
        primitive: Primitive,
        value: []u8,
    };

    const Handles = struct {
        handles: []Handle = &.{},
        pub fn find(self: @This(), ctx: *const ParseContext, name: []const u8) ?usize {
            var p = self.handles.ptr + self.handles.len;
            while (p != self.handles.ptr) {
                p -= 1;
                if (p[0].name.eqlRaw(ctx, name)) return p - self.handles.ptr;
            }
            return null;
        }
        pub fn get(self: @This(), ctx: *const ParseContext, name: []const u8) ?*Handle {
            const i = self.find(ctx, name) orelse return null;
            return &self.handles[i];
        }
    };

    authors: Authors,
    bitmasks: []Bitmask = &.{},
    enums: []Enum = &.{},
    funcpointers: []Funcpointer = &.{},
    handles: Handles = .{},
    structs: []StructOrUnion = &.{},
    unions: []StructOrUnion = &.{},
    constants: []Constant = &.{},

    pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        for (self.bitmasks) |e| {
            try writer.print("{f}", .{e});
        }
        for (self.enums) |e| {
            try writer.print("{f}", .{e});
        }
        for (self.handles.handles) |e| {
            try writer.print("{f}", .{e});
        }
        for (self.funcpointers) |e| {
            try writer.print("{f}", .{e});
        }
        for (self.structs) |e| {
            try writer.print("{f}", .{e.asStruct()});
        }
        for (self.unions) |e| {
            try writer.print("{f}", .{e.asUnion()});
        }
    }

    const TempAlias = struct {
        name: VkTypeName,
        alias: VkTypeName,
    };
    pub fn parse(reader: *Reader, allocator: Allocator, api: Api) @This() {
        var ctx: ParseContext = .{
            .allocator = allocator,
            .api = api,
            .authors = undefined,
            .reader = reader,
        };
        _ = xml.seekTags(ctx.reader, enum { registry });
        _ = xml.seekTags(ctx.reader, enum { tags });
        var result: @This() = .{
            .authors = .parse(&ctx),
        };
        ctx.authors = result.authors;

        var enum_aliases: std.ArrayList(TempAlias) = .empty;
        var enums: std.ArrayList(Enum) = .empty;
        var bitmasks: std.ArrayList(Bitmask) = .empty;
        while (true) switch (xml.seekTags(ctx.reader, enum { types, enums, commands, extensions, @"/registry" })) {
            .types => result.parseTypes(&ctx, &enum_aliases),
            .enums => result.parseEnums(&ctx, &enums, &bitmasks),
            .commands => result.parseCommands(&ctx),
            .extensions => result.parseExtensions(&ctx),
            .@"/registry" => break,
        };
        result.bitmasks = bitmasks.toOwnedSlice(ctx.allocator) catch panics.oom();
        result.enums = enums.toOwnedSlice(ctx.allocator) catch panics.oom();

        outer: for (enum_aliases.items) |alias| {
            for (result.enums) |*e| {
                if (e.name.eql(alias.alias)) {
                    e.aliases = slice_tools.allocated.concat(VkTypeName, e.aliases, &.{alias.name}, ctx.allocator) catch panics.oom();
                    continue :outer;
                }
            }
            const alias_as_bit_mask: Bitmask.BitmaskName = Bitmask.BitmaskName.fromVkTypeName(alias.alias) orelse continue :outer;
            for (result.bitmasks) |*e| {
                if (e.name.eql(alias_as_bit_mask)) {
                    const name_bitmask = Bitmask.BitmaskName.fromVkTypeName(alias.name) orelse panic("Expected bitmask name: {}", .{alias.name});
                    e.aliases = slice_tools.allocated.concat(Bitmask.BitmaskName, e.aliases, &.{name_bitmask}, ctx.allocator) catch panics.oom();
                    continue :outer;
                }
            }
        }

        return result;
    }

    pub fn parseAuthors(self: *@This(), ctx: *const ParseContext) void {
        var authors: std.ArrayList(AuthorTag) = .empty;
        while (true) switch (xml.seekTags(ctx.reader, enum { tag, @"/tags" })) {
            .@"/tags" => break,
            .tag => {
                const new = authors.addOne(ctx.allocator) catch panics.oom();
                new.* = .parse(ctx.reader, ctx.allocator);
            },
        };
        self.authors = authors.toOwnedSlice(ctx.allocator) catch panics.oom();
    }
    pub fn parseTypes(self: *@This(), ctx: *const ParseContext, enum_aliases: *std.ArrayList(TempAlias)) void {
        var handles: std.ArrayList(Handle) = .empty;
        var funcpointers: std.ArrayList(Funcpointer) = .empty;
        var structs: std.ArrayList(StructOrUnion) = .empty;
        var unions: std.ArrayList(StructOrUnion) = .empty;
        type_loop: while (true) switch (xml.seekTags(ctx.reader, enum { type, @"/types" })) {
            .@"/types" => break,
            .type => while (xml.nextAttr(ctx.reader, enum { category, api })) |k| switch (k) {
                .api => {
                    if (!ctx.api.match(xml.getAttrValue(ctx.reader))) continue :type_loop;
                },
                .category => {
                    const cat = enumFromName(enum { handle, @"enum", funcpointer, @"struct", @"union" }, xml.getAttrValue(ctx.reader)) orelse continue :type_loop;
                    switch (cat) {
                        .handle => {
                            if (xml.nextAttr(ctx.reader, enum { name })) |_| {
                                // It's an alias
                                const name = VkTypeName.parse(ctx, '"') orelse @panic("Failed to parse name");
                                _ = xml.nextAttr(ctx.reader, enum { alias }) orelse panic("Missing alias for {f}", .{name});
                                const alias = xml.getAttrValue(ctx.reader);
                                const h = Handles.get(.{ .handles = handles.items }, ctx, alias) orelse panic("Failed to find handle: {s}", .{alias});

                                h.addAlias(ctx, name);
                                continue :type_loop;
                            }

                            handles.append(ctx.allocator, .parse(ctx)) catch panics.oom();
                        },
                        .@"enum" => {
                            _ = xml.nextAttr(ctx.reader, enum { name }) orelse continue :type_loop;
                            const new = enum_aliases.addOne(ctx.allocator) catch panics.oom();
                            new.name = VkTypeName.parse(ctx, '"') orelse panic("Alias doesn't start with Vk: {f}", .{new.name});
                            _ = xml.nextAttr(ctx.reader, enum { alias }) orelse panic("Expected alias for {f}", .{new.name});
                            new.alias = VkTypeName.parse(ctx, '"') orelse panic("Alias doesn't start with Vk: {f}", .{new.name});
                        },
                        .funcpointer => funcpointers.append(ctx.allocator, .parse(ctx)) catch panics.oom(),
                        .@"struct" => {
                            StructOrUnion.parse(ctx, &structs);
                        },
                        .@"union" => {
                            StructOrUnion.parse(ctx, &unions);
                        },
                    }
                    continue :type_loop;
                }
            }
        };
        self.handles = .{ .handles = handles.toOwnedSlice(ctx.allocator) catch panics.oom() };
        self.funcpointers = funcpointers.toOwnedSlice(ctx.allocator) catch panics.oom();
        self.structs = structs.toOwnedSlice(ctx.allocator) catch panics.oom();
        self.unions = unions.toOwnedSlice(ctx.allocator) catch panics.oom();
    }

    pub fn parseEnums(self: *@This(), ctx: *const ParseContext, enums: *std.ArrayList(Enum), bitmasks: *std.ArrayList(Bitmask)) void {
        _ = xml.nextAttr(ctx.reader, enum { name }) orelse @panic("Nameless enum");
        const name: VkTypeName = VkTypeName.parse(ctx, '"') orelse {
            // Must be the constants
            self.parseConstants(ctx);
            return;
        };
        _ = xml.nextAttr(ctx.reader, enum { type }) orelse panic("Failed to find type for: {f}", .{name});
        const kind_text = xml.getAttrValue(ctx.reader);
        const kind = enumFromName(enum { bitmask, @"enum" }, kind_text) orelse panic("Unknown enum kind for {f}: {s}", .{ name, kind_text });

        var comment: Comment = .{};
        var bits: Bitmask.Bits = .@"32";
        while (xml.nextAttr(ctx.reader, enum { comment, bitwidth })) |t| {
            switch (t) {
                .comment => {
                    comment = .parseQuotes(ctx);
                },
                .bitwidth => {
                    bits = .parse(ctx);
                }
            }
        }

        switch (kind) {
            .bitmask => {
                const new = bitmasks.addOne(ctx.allocator) catch panics.oom();
                new.* = .{
                    .name = Bitmask.BitmaskName.fromVkTypeName(name) orelse panic("Expected name to contain FlagBits: {f}", .{name}),
                    .comment = comment,
                    .bits = bits,
                };
                new.parseEntries(ctx);
            },
            .@"enum" => {
                const new = enums.addOne(ctx.allocator) catch panics.oom();
                new.* = .{
                    .name = name,
                    .comment = comment,
                };
                new.parseEntries(ctx);
            },
        }
    }
    pub fn parseConstants(self: *@This(), ctx: *const ParseContext) void {
        _ = self;
        _ = ctx;
    }
    pub fn parseCommands(self: *@This(), ctx: *const ParseContext) void {
        _ = self;
        _ = ctx;
    }
    pub fn parseExtensions(self: *@This(), ctx: *const ParseContext) void {
        _ = self;
        _ = ctx;
    }
};

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(init.io, &stdin_buffer);
    const reader = &stdin_reader.interface;

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch panics.write();

    var api: Registry.Api = .vulkan;

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
                    api = slice_tools.enums.fromName(Registry.Api, a) orelse std.debug.panic("Unknown api: {s}", .{a});
                },
            }
        }
    }

    const registry: Registry = .parse(reader, allocator, api);
    writer.print("{s}\n{f}", .{ @embedFile("preamble.zig"), registry }) catch panics.write();
}
