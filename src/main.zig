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
        _ = reader.discardDelimiterInclusive('<') catch |e| panics.reader(e);
    }
    pub fn getTagText(reader: *Reader) []const u8 {
        var len: usize = 1;
        while (true) {
            const text = reader.peekGreedy(len) catch |e| panics.reader(e);
            if (std.mem.findAny(u8, text, " >")) |i| {
                reader.toss(i);
                return text[0..i];
            }
            len += 1;
        }
    }
    pub fn seekTags(reader: *Reader, comptime TagsEnum: type) TagsEnum {
        while (true) {
            goToTag(reader);
            const text = getTagText(reader);
            if (enumFromName(TagsEnum, text)) |tag| return tag;
        }
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
        _ = reader.discardDelimiterInclusive('"') catch |e| panics.reader(e);
        return reader.takeDelimiter('"') catch |e| panics.takeDelimiter(e) orelse panics.unexpectedEnd();
    }

    pub fn nextAttr(reader: *Reader, comptime KeysOfInterest: type) ?KeysOfInterest {
        while (getAttrKey(reader)) |text| {
            if (enumFromName(KeysOfInterest, text)) |key| {
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
        authors: []const AuthorTag,
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
        /// Parses comment="..". Assumes we are at the '='
        fn parseQuotes(
            ctx: *const ParseContext,
        ) @This() {
            _ = ctx.reader.discardDelimiterInclusive('"') catch |e| switch (e) {
                Reader.Error.ReadFailed => panics.readFailed(),
                Reader.Error.EndOfStream => @panic("Failed to find beginning of comment"),
            };
            return parseCommon(ctx, '"');
        }

        /// Parses <comment>...</comment>. Assumes we are at the '<comment>'
        fn parseTags(ctx: *const ParseContext, allocator: Allocator) @This() {
            const ret = parseCommon(ctx, allocator, '<');
            expect(ctx.reader, "/comment>");
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
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
            const text = ctx.reader.takeDelimiter('<') catch |e| switch (e) {
                Reader.Error.ReadFailed => panics.readFailed(),
                Reader.Error.EndOfStream => @panic("Failed to find ending of primitive type"),
                Reader.Error.StreamTooLong => panics.streamTooLong(),
            };
            const ret = parseFromText(text);
            expect(ctx.reader, "/type>");
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
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{t}", .{self});
        }
    };

    pub const PrimitiveTypeName = struct {
        primitive: Primitive,

        pub fn parse(ctx: *const ParseContext) ?@This() {
            return .{
                .primitive = .parse(ctx) orelse return null,
            };
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{t}", .{self});
        }
    };
    pub const AuthorTag = struct {
        data: []const u8 = &.{},

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return std.mem.lessThan(u8, lhs.data, rhs.data);
        }
        pub fn sort(authors: []@This()) void {
            std.sort.pdq(@This(), authors, {}, lessThan);
        }
        pub fn contains(authors: []const @This(), needle: []const u8) bool {
            const Helper = struct {
                target: []const u8,

                pub fn compare(self: @This(), rhs: AuthorTag) std.math.Order {
                    return std.mem.order(self.target, rhs.target);
                }
            };
            const ret = std.sort.binarySearch(@This(), authors, Helper{ .target = needle }, Helper.compare);
            return ret != null;
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
    };
    pub const VulkanName = struct {
        root: []u8 = &.{},
        author: AuthorTag = .{},
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
        fn getAuthorIndex(name_without_version: []const u8, authors: []const AuthorTag) usize {
            for (authors) |author| {
                if (author.endsInAuthor(name_without_version)) {
                    return name_without_version.len - author.data.len;
                }
            }
            return name_without_version.len;
        }
        pub fn parseText(ctx: *const ParseContext, name: []u8, exclude_suffix: []const u8) @This() {
            const version_index = getVersionIndex(name);
            const version_text = name[version_index..];
            const version: NameVersion = .parseText(version_text);
            const without_version = name[0..version_index];
            const author_index = getAuthorIndex(without_version, ctx.authors);
            const author = without_version[author_index..];
            const root = without_version[0..author_index];
            if (!std.mem.endsWith(u8, root, exclude_suffix))
                panic("Name {s} doesn't end with suffix {s}", .{ name, exclude_suffix });
            return .{
                .root = ctx.allocator.dupe(u8, root[0 .. root.len - exclude_suffix.len]) catch panics.oom(),
                .author = .{ .data = ctx.allocator.dupe(u8, author) catch panics.oom() },
                .version = version,
            };
        }
        pub fn parse(ctx: *const ParseContext, exclude_suffix: []const u8, delimiter: u8) @This() {
            const peek = ctx.reader.takeDelimiter(delimiter) catch |e| switch (e) {
                error.ReadFailed => panics.readFailed(),
                error.StreamTooLong => panics.streamTooLong(),
            } orelse @panic("Unexpected end of stream while parsing name");
            return parseText(ctx, peek, exclude_suffix);
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}{f}{f}", .{
                self.root,
                self.author,
                self.version,
            });
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.version.eql(rhs.version) and
                lhs.author.eql(rhs.author) and
                std.mem.eql(u8, lhs.root, rhs.root);
        }
        pub fn eqlRaw(self: @This(), text: []const u8, authors: []const AuthorTag) bool {
            const version_index = getVersionIndex(text);
            const version_text = text[version_index..];
            const version: NameVersion = .parseText(version_text);
            if (!version.eql(self.version)) return false;
            const without_version = text[0..version_index];
            const author_index = getAuthorIndex(without_version, authors);
            const author: AuthorTag = .{ .data = without_version[author_index..] };
            if (!author.eql(self.author)) return false;
            const root = without_version[0..author_index];
            return std.mem.eql(u8, self.root, root);
        }
    };
    pub const FuncpointerTypeName = struct {
        name: VulkanName = .{},

        pub fn parse(ctx: *const ParseContext) ?@This() {
            if (!stripPrefix(ctx.reader, "PFN_vk")) return null;
            const ret: @This() = .{ .name = .parse(ctx, "") };
            expect(ctx.reader, "/type>");
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("Pfn{s}", .{self.name});
        }
    };
    pub const VkTypeName = struct {
        name: VulkanName = .{},

        pub fn parse(ctx: *const ParseContext, exclude_suffix: []const u8, delimiter: u8) ?@This() {
            if (!stripPrefix(ctx.reader, "Vk")) return null;
            const ret: @This() = .{ .name = .parse(ctx, exclude_suffix, delimiter) };
            return ret;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}", .{self.name});
        }
        pub fn eql(lhs: @This(), rhs: @This()) bool {
            return lhs.name.eql(rhs.name);
        }
        pub fn eqlRaw(self: @This(), authors: []const AuthorTag, text: []const u8) bool {
            if (!std.mem.startsWith(u8, text, "Vk")) return false;
            return self.name.eqlRaw(text[2..], authors);
        }
    };
    pub const GenericTypeName = union(enum) {
        funcptr: FuncpointerTypeName,
        primitive: PrimitiveTypeName,
        other: VkTypeName,

        pub fn parse(ctx: *const ParseContext) ?@This() {
            if (FuncpointerTypeName.parse(ctx)) |n| {
                return .{ .funcptr = n };
            }
            if (PrimitiveTypeName.parse(ctx)) |n| {
                return .{ .primitive = n };
            }
            if (VkTypeName.parse(ctx, "")) |n| {
                return .{ .other = n };
            }
            return null;
        }
        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            switch (self.data) {
                inline else => |n| try writer.print("{s}", .{n}),
            }
        }
    };
    pub const EnumEntryName = struct {
        const Prefix = struct {
            data: []const u8 = &.{},

            pub fn parse(ctx: *const ParseContext, root: VkTypeName) @This() {
                if (!stripPrefix(ctx.reader, "VK_")) @panic("Flag bit doesn't start with VK_");
                const root_name = root.name.root;
                var alloc_writer: Writer.Allocating = .init(ctx.allocator);
                const writer = &alloc_writer.writer;
                writer.writeAll("VK_") catch panics.oom();
                const possible_version = blk: while (true) {
                    const slice = ctx.reader.peekDelimiterExclusive('_') catch |e| switch (e) {
                        Reader.DelimiterError.ReadFailed => panics.readFailed(),
                        Reader.DelimiterError.StreamTooLong => panics.streamTooLong(),
                    } orelse @panic("unexpected end while parsing FlagBits prefix");
                    if (slice.len > root_name.len) break :blk slice;
                    for (root_name[0..slice.len], slice) |r, s| {
                        const r_cap = std.ascii.toUpper(r);
                        if (r_cap != s) break :blk slice;
                    }
                    root_name = root_name[slice.len..];
                    writer.writeAll(slice) catch panics.oom();
                    writer.writeByte('_') catch panics.oom();
                    ctx.reader.toss(slice.len + 1);
                };
                if (std.fmt.parseInt(u8, 10, possible_version)) |n| {
                    if (n == root_name.name.version) {
                        writer.writeAll(possible_version) catch panics.oom();
                        writer.writeByte('_') catch panics.oom();
                        ctx.reader.toss(possible_version.len + 1);
                    }
                }
                return .{ .data = alloc_writer.toOwnedSlice() catch panics.oom() };
            }

            pub fn discard(self: @This(), ctx: *const ParseContext) bool {
                return stripPrefix(ctx.reader, self.data);
            }
        };

        name: []u8 = &.{},

        pub fn parseFirst(ctx: *const ParseContext, enum_name: VkTypeName) struct { @This(), EnumEntryName.Prefix } {
            const prefix: Prefix = .parse(ctx, enum_name);
            const ret: @This() = .{ .name = allocToDelimiterAsLower(ctx.allocator, '"') };
            _ = std.ascii.lowerString(ret.data, ret.data);
            return .{ ret, prefix };
        }
        pub fn parse(ctx: *const ParseContext, prefix: Prefix) @This() {
            prefix.discard(ctx);
            return .{ .name = allocToDelimiterAsLower(ctx.allocator, '"') };
        }

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("@\"{s}\"", .{self.name});
        }
    };
    const Bitmask = struct {
        const BitmaskName = struct {
            name: VkTypeName = .{},

            pub fn parseFromFlagBits(ctx: *const ParseContext) @This() {
                return .{ .name = .parse(ctx, "FlagBits") };
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
            name: EnumEntryName,

            pub fn parseFirst(ctx: *const ParseContext, enum_name: VkTypeName) struct { @This(), EnumEntryName.Prefix } {
                if (!std.mem.endsWith(u8, enum_name.name.root, "FlagBits")) panic("Flag doesn't end with FlagBits: {f}", .{enum_name});
                var copy = enum_name;
                copy.name.root = copy.name.root[0 .. copy.name.root.len - "FlagBits".len];
                const name, const prefix = EnumEntryName.parseFirst(ctx, copy);
                const ret: @This() = .{ .name = name };
                return .{ ret, prefix };
            }
            pub fn parse(ctx: *const ParseContext, prefix: EnumEntryName.Prefix) @This() {
                const ret = EnumEntryName.parse(ctx, prefix);
                return .{ .name = ret };
            }
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}", .{self.name});
            }
        };

        const Entry = struct {
            const Bitpos = struct {
                bitpos: u8,

                pub fn parse(ctx: *const ParseContext) @This() {
                    _ = ctx.reader.discardDelimiterInclusive('"') catch |e| panics.reader(e);
                    const slice = ctx.reader.takeDelimiter('"') catch |e| switch (e) {
                        Reader.Error.ReadFailed => panics.readFailed(),
                        Reader.DelimiterError.StreamTooLong => panics.streamTooLong(),
                    } orelse
                        @panic("Failed to find bitpos delimiter");
                    const n = std.fmt.parseInt(u8, 10, slice) catch |e| switch (e) {
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
            aliases: []BitAlias,

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

            pub fn parse(vk_flags: []const u8) @This() {
                const e = enumFromName(enum { VkFlags, VkFlags64 }, vk_flags) orelse panic("Unknown bitwidth: {s}", .{vk_flags});
                return switch (e) {
                    .VkFlags => .@"32",
                    .VkFlags64 => .@"64",
                };
            }
            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("u{t}", .{self});
            }
        };

        prefix: EnumEntryName.Prefix = .{},
        name: BitmaskName = .{},
        bits: Bits = .@"32",
        comment: Comment = .{},
        entries: []Entry = &.{},
        aggregates: []Enum.Entry = &.{},
        aliases: []Alias = &.{},

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
            for (self.entries) |e| {
                for (e.aliases) |alias| {
                    try writer.print("{f}{f};", .{ alias, e.name });
                }
            }
            for (self.aliases) |e| {
                try writer.print("{f}", .{e});
            }
            try writer.print("}};{[comment]f}pub const {[flags_name]f}=packed({[bits]f}{{", .{
                .comment = self.comment,
                .flags_name = self.name.asFlags(),
                .bits = self.bits,
            });
            if (self.entries.len != 0) {
                try writer.print("{f}", .{self.entries[0].asFlags()});
                var last_bitpos = self.entries[0].bitpos.bitpos;
                for (self.entries[1..]) |e| {
                    const diff = e.bitpos.bitpos - last_bitpos;
                    if (diff > 1) {
                        try writer.print("_reserved{f}:bool=false,", .{e.bitpos});
                    }
                    last_bitpos = e.bitpos.bitpos;
                    try writer.print("{f}", .{e.asFlags()});
                }
            }

            for (self.entries) |e| {
                for (e.aliases) |alias| {
                    try writer.print("{f}pub const {f}:@This() = @bitCast(1<<{f});", .{ alias.comment, alias.alias, e.bitpos });
                }
            }
            for (self.aggregates) |e| {
                try writer.print("{f}pub const {f}:@This() = @bitCast({s});", .{ e.comment, e.name, e.value });
            }
            try writer.writeAll("};");
        }
    };

    const Alias = struct {
        alias: VkTypeName = .{},
        comment: Comment = .{},

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}pub const {f}=@This().", .{ self.comment, self.alias });
        }
    };

    const Enum = struct {
        const Entry = struct {
            name: EnumEntryName = .{},
            value: []u8 = &.{},
            comment: Comment = .{},
            aliases: []Alias = &.{},

            pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
                try writer.print("{f}{f}={s},", .{ self.comment, self.name, self.value });
            }
        };

        name: VkTypeName = .{},
        comment: Comment = .{},
        entries: []Entry = &.{},
        aliases: []Alias = &.{},

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{f}{f}=enum(c_int){{", .{ self.comment, self.name });
            for (self.entries) |e| {
                try writer.print("{f}", .{e});
            }
            for (self.entries) |e| {
                for (e.aliases) |alias| {
                    try writer.print("{f}{f};", .{ alias, e.name });
                }
            }
            try writer.writeAll("};");
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
        aliases: []Alias = &.{},

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
            const name = VkTypeName.parse(ctx, "", '<') orelse @panic("Handle doesn't start with Vk prefix");
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
        }
        pub fn addAlias(self: *@This(), ctx: *const ParseContext, alias: Alias) void {
            self.aliases = ctx.allocator.realloc(self.aliases, self.aliases.len + 1) catch panics.oom();
            self.aliases[self.aliases.len - 1] = alias;
        }
    };
    const StructOrUnion = struct {
        const Member = struct {
            member: ZigVar,
            comment: []u8,
        };
        comment: []u8 = &.{},
        members: []Member = &.{},
        aliases: [][]u8 = &.{},
        s_type: []u8 = &.{},
    };

    const VarType = union(enum) {
        primitive: Primitive,
        non_primitive: []const u8,

        pub fn parse(text: []const u8, allocator: Allocator) @This() {
            return if (Primitive.parse(text)) |p|
                .{ .primitive = p }
            else
                .{ .non_primitive = allocator.dupe(u8, text) catch panics.oom() };
        }
    };
    const CType = struct {
        const Kind = enum {
            @"const",
            mutable,
        };
        const max_ptr_layer = 2;

        ptrs: slice_tools.BoundedArray(Kind, max_ptr_layer) = .{},
        base_type: VarType,

        //pub fn parse(it: XmlIterator, allocator: Allocator) @This() {
        //    var result: @This() = .{
        //        .base_type = undefined,
        //    };
        //    const b = it.reader.takeDelimiter('<');
        //    if (find(b, "const")) |_| {
        //        result.ptrs.appendAssumeCapacity(.@"const");
        //    }
        //    it.closeTag();
        //    const t = it.reader.takeDelimiter('<');
        //    result.base_type = .parse(t, allocator);
        //    it.closeTag();
        //    var after_type = it.reader.takeDelimiter('<');
        //    if (findScalar(after_type, '*')) |i| {
        //        if (result.ptrs.len == 0) result.ptrs.appendAssumeCapacity(.mutable);
        //        after_type = after_type[i + 1 ..];
        //    }
        //    if (findAny(after_type, "*c")) |i| {
        //        switch (after_type[i]) {
        //            '*' => result.ptrs.appendAssumeCapacity(.mutable),
        //            'c' => {
        //                // Must be const, but we'll just trust it
        //                assert(std.mem.startsWith(u8, after_type[i..], "const"));
        //                result.ptrs.appendAssumeCapacity(.@"const");
        //            },
        //            else => unreachable,
        //        }
        //    }
        //    return result;
        //}

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            for (self.ptrs.constSlice()) |p| {
                try writer.writeAll(switch (p) {
                    .@"const" => "[*c]const",
                    .mutable => "[*c]",
                });
            }
            if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive == .void) {
                try writer.writeAll(" anyopaque");
            } else {
                try writer.print(" {f}", .{self.base_type});
            }
        }
    };

    const CVar = struct {
        const Amount = union(enum) {
            const Array = struct {
                is_literal: bool,
                data: []u8,
            };
            array: Array,
            bitfield: []u8,
            single,
        };
        type: CType,
        name: []u8,
        amount: Amount,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:", .{self.name});
            switch (self.amount) {
                .single => {
                    for (self.type.ptrs.constSlice()) |p| {
                        try writer.writeAll(switch (p) {
                            .@"const" => "[*c]const",
                            .mutable => "[*c]",
                        });
                    }
                    if (self.type.ptrs.len != 0 and self.type.base_type == .primitive and self.type.base_type.primitive == .void) {
                        try writer.writeAll(" anyopaque");
                    } else {
                        try writer.print(" {f}", .{self.type.base_type});
                    }
                },
                .bitfield => |b| {
                    try writer.print("u{s}", .{b});
                },
                .array => |ar| {
                    try writer.print("[{s}]{f}", .{ ar.data, self.type });
                }
            }
        }

        //pub fn parse(it: XmlIterator, allocator: Allocator) @This() {
        //    var result: @This() = .{
        //        .type = .parse(it, allocator),
        //        .name = undefined,
        //        .amount = undefined,
        //    };
        //    it.closeTag();
        //    result.name = allocator.dupe(u8, it.reader.takeDelimiter('<')) catch panics.oom();
        //    it.closeTag();
        //    const amount = it.reader.peekDelimiterExclusive('<');
        //    const i = findAny(amount, ":[") orelse {
        //        it.reader.toss(amount.len);
        //        result.amount = .single;
        //        return result;
        //    };
        //    switch (amount[i]) {
        //        ':' => {
        //            result.amount = .{ .bitfield = allocator.dupe(u8, amount[i + 1 ..]) catch panics.oom() };
        //            it.reader.toss(amount.len + 1);
        //        },
        //        '[' => {
        //            result.amount = .{ .array = undefined };
        //            const am = &result.amount.array;
        //            it.reader.toss(i + 1);
        //            var inside_brackets = it.reader.takeDelimiter(']');
        //            if (findScalar(inside_brackets, '<')) |j| {
        //                inside_brackets = inside_brackets[j + 1 ..];
        //                var k = findScalar(inside_brackets, '>') orelse @panic("Unclosed tag");
        //                inside_brackets = inside_brackets[k + 1 ..];
        //                k = findScalar(inside_brackets, '<') orelse panic("Failed to find amount end for {s}", .{result.name});
        //                am.* = .{
        //                    .is_literal = false,
        //                    .data = allocator.dupe(u8, inside_brackets[0..k]) catch panics.oom(),
        //                };
        //            } else {
        //                am.* = .{
        //                    .is_literal = true,
        //                    .data = allocator.dupe(u8, inside_brackets) catch panics.oom(),
        //                };
        //            }
        //        },
        //        else => unreachable,
        //    }
        //    return result;
        //}
    };

    const ZigType = struct {
        const Size = enum {
            single,
            many,
            null_terminated,
        };
        const Ptr = struct {
            optional: bool = false,
            size: Size = .single,
            kind: CType.Kind = .mutable,

            pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
                const optional_text = if (self.optional)
                    "?"
                else
                    "";
                const ptr_text = switch (self.size) {
                    .single => "*",
                    .many => "[*]",
                    .null_terminated => "[*:0]",
                };
                const kind_text = switch (self.kind) {
                    .@"const" => "const",
                    .mutable => "",
                };
                try writer.print("{s}{s}{s}", .{ optional_text, ptr_text, kind_text });
            }
        };
        const Ptrs = slice_tools.BoundedArray(Ptr, 2);

        ptrs: Ptrs = .{},
        base_type: VarType,
        amount: CVar.Amount,

        //pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
        //    if (self.amount == .bitfield) {
        //        try writer.print("u{s}", .{self.amount.bitfield});
        //        return;
        //    }
        //    for (self.ptrs.constSlice()) |p| {
        //        try writer.print("{f} ", .{p});
        //    }
        //    switch (self.amount) {
        //        .single => {},
        //        .array => |ar| {
        //            try writer.writeByte('[');
        //            if (ar.is_literal) {
        //                try writer.writeAll(ar.data);
        //            } else {
        //                try writeWithoutVK_PrefixAndLowerOrPanic(writer, ar.data);
        //            }
        //            try writer.writeByte(']');
        //        },
        //        .bitfield => unreachable,
        //    }
        //    if (self.ptrs.len != 0 and self.base_type == .primitive and self.base_type.primitive == .void) {
        //        try writer.writeAll("anyopaque");
        //    } else {
        //        try writer.print("{f}", .{self.base_type});
        //    }
        //}
    };
    const ZigVar = struct {
        name: []u8,
        type: ZigType,

        pub fn fromCVar(c_var: CVar) @This() {
            return .{
                .name = c_var.name,
                .type = .fromCType(c_var.type),
            };
        }

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.print("{s}:{f}", .{ self.name, self.type });
        }
    };
    const Funcpointer = struct {
        ret_type: CType,
        params: []CVar,

        pub fn format(self: *const @This(), writer: *Writer) Writer.Error!void {
            try writer.writeAll("*const fn(");
            for (self.params) |p| {
                try writer.print("{f},", .{p});
            }
            try writer.print(")callconv(vulkan_api) {f};", .{self.ret_type});
        }
    };
    const Constant = struct {
        comment: []u8,
        primitive: Primitive,
        value: []u8,
    };

    const Handles = struct {
        handles: []Handle = &.{},
        pub fn find(self: @This(), authors: []const AuthorTag, name: []const u8) ?usize {
            var p = self.handles.ptr + self.handles.len;
            while (p != self.handles.ptr) {
                p -= 1;
                if (p[0].name.eqlRaw(authors, name)) return p - self.handles.ptr;
            }
            return null;
        }
        pub fn get(self: @This(), authors: []const AuthorTag, name: []const u8) ?*Handle {
            const i = self.find(authors, name) orelse return null;
            return &self.handles[i];
        }
    };

    authors: []AuthorTag = &.{},
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
    }

    pub fn parse(reader: *Reader, allocator: Allocator, api: Api) @This() {
        var ctx: ParseContext = .{
            .allocator = allocator,
            .api = api,
            .authors = undefined,
            .reader = reader,
        };
        _ = xml.seekTags(ctx.reader, enum { registry });
        _ = xml.seekTags(ctx.reader, enum { tags });
        var result: @This() = .{};
        result.parseAuthors(&ctx);
        ctx.authors = result.authors;

        while (true) switch (xml.seekTags(ctx.reader, enum { types, enums, commands, extensions, @"/registry" })) {
            .types => result.parseTypes(&ctx),
            .enums => result.parseEnums(&ctx),
            .commands => result.parseCommands(&ctx),
            .extensions => result.parseExtensions(&ctx),
            .@"/registry" => return result,
        };
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
    pub fn parseTypes(self: *@This(), ctx: *const ParseContext) void {
        var handles: std.ArrayList(Handle) = .empty;
        type_loop: while (true) switch (xml.seekTags(ctx.reader, enum { type, @"/types" })) {
            .@"/types" => break,
            .type => while (xml.nextAttr(ctx.reader, enum { category, api })) |k| switch (k) {
                .api => {
                    if (!ctx.api.match(xml.getAttrValue(ctx.reader))) continue :type_loop;
                },
                .category => {
                    const cat = enumFromName(enum { handle }, xml.getAttrValue(ctx.reader)) orelse continue :type_loop;
                    switch (cat) {
                        .handle => {
                            if (xml.nextAttr(ctx.reader, enum { name })) |_| {
                                // It's an alias
                                _ = ctx.reader.discardDelimiterInclusive('"') catch |e| panics.reader(e);
                                const name = VkTypeName.parse(ctx, "", '"') orelse @panic("Failed to parse name");
                                _ = xml.nextAttr(ctx.reader, enum { alias }) orelse panic("Missing alias for {f}", .{name});
                                const alias = xml.getAttrValue(ctx.reader);
                                const h = Handles.get(.{ .handles = handles.items }, ctx.authors, alias) orelse panic("Failed to find handle: {s}", .{alias});

                                const comment: Comment = if (xml.nextAttr(ctx.reader, enum { comment })) |_|
                                    Comment.parseQuotes(ctx)
                                else
                                    .{};
                                h.addAlias(ctx, .{ .alias = name, .comment = comment });
                                continue :type_loop;
                            }

                            handles.append(ctx.allocator, .parse(ctx)) catch panics.oom();
                        },
                    }
                }
            }
        };
        self.handles = .{ .handles = handles.toOwnedSlice(ctx.allocator) catch panics.oom() };
    }

    pub fn parseEnums(self: *@This(), ctx: *const ParseContext) void {
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
