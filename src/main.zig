const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const panic = std.debug.panic;
const assert = std.debug.assert;
const slice_tools = @import("slice_tools");

fn panicReadingFailed() noreturn {
    @panic("Failed reading");
}
fn panicUnexpectedEndOfStream() noreturn {
    @panic("Unexpected end of stream");
}
fn panicOOM() noreturn {
    @panic("Out of memory");
}

fn findPast(haystack: []const u8, needle: []const u8) ?usize {
    const i = std.mem.find(u8, haystack, needle) orelse return null;
    return i + needle.len;
}
fn findPastAndAdvance(haystack: *[]const u8, needle: []const u8) bool {
    const i = findPast(haystack.*, needle) orelse return false;
    haystack.* = haystack.*[i..];
    return true;
}
fn findPropertyImpl(text: []const u8, property: []const u8) ?[]const u8 {
    const i = findPast(text, property) orelse return null;
    const t = text[i..];
    const j = std.mem.find(u8, t, "\"") orelse @panic("Unclosed string");
    return t[0..j];
}
fn findProperty(text: []const u8, comptime property: []const u8) ?[]const u8 {
    return findPropertyImpl(text, property ++ "=\"");
}
fn splitSection(text: *[]const u8, finish: []const u8) []const u8 {
    const j = findPast(text.*, finish) orelse @panic("Failed to find end of section");
    const result = text.*[0..j];
    text.* = text.*[j..];
    return result;
}
fn cToZig(text: []const u8) []const u8 {
    const Types = enum {
        void,
        char,
        uint8_t,
        uint16_t,
        uint32_t,
        int32_t,
        uint64_t,
        int64_t,
        size_t,
    };
    const t = slice_tools.enums.fromName(Types, text) orelse return text;
    return switch (t) {
        .void => "void",
        .char => "u8",
        .uint8_t => "u8",
        .uint16_t => "u16",
        .uint32_t => "u32",
        .int32_t => "i32",
        .uint64_t => "u64",
        .int64_t => "i64",
        .size_t => "usize",
    };
}
const TypeDescription = struct {
    const PtrKind = enum {
        no,
        mutable,
        @"const",

        pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .no => {},
                .mutable => try writer.writeAll("*"),
                .@"const" => try writer.writeAll("*const"),
            }
        }
    };
    ptr: [2]PtrKind = .{ .no, .no },
    name: []const u8,

    pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{f}{f} {s}", .{ self.ptr[0], self.ptr[1], self.name });
    }
};
fn parseType(text: *[]const u8) ?TypeDescription {
    var result: TypeDescription = .{ .name = undefined };
    if (!findPastAndAdvance(text, "<type>")) return null;
    const type_end = std.mem.find(u8, text.*, "</type>") orelse return null;
    result.name = text.*[0..type_end];
    text.* = text.*[type_end + "</type>".len ..];
    if (text.*[0] == '*') {
        text.* = text.*[1..];
        const const_str = "const ";
        const p = result.name.ptr - const_str.len - "<type>".len;
        const maybe_const = p[0..const_str.len];
        if (std.mem.eql(u8, maybe_const, const_str)) {
            result.ptr[0] = .@"const";
        } else {
            result.ptr[0] = .mutable;
        }
        const const_ptr_str = " const *";
        if (text.*[0] == '*') {
            text.* = text.*[1..];
            result.ptr[1] = .mutable;
        } else if (std.mem.eql(u8, text.*[0..const_ptr_str.len], const_ptr_str)) {
            text.* = text.*[const_ptr_str.len..];
            result.ptr[1] = .@"const";
        }
    }
    result.name = cToZig(result.name);
    return result;
}
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var text: []const u8 = blk: {
        const stdin = std.Io.File.stdin();
        var stdin_reader = stdin.reader(init.io, &.{});
        const reader = &stdin_reader.interface;
        break :blk reader.allocRemaining(allocator, .unlimited) catch panicOOM();
    };
    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch @panic("Failed to write to stdout");

    _ = splitSection(&text, "<comment>Bitmask types</comment>");

    var flags_text = splitSection(&text, "<comment>Types which can be void pointers or class pointers, selected at compile time</comment>");
    const Flag = struct {
        const Bits = enum { @"32", @"64" };
        name: []const u8,
        bits: Bits,
        bits_enum: ?[]const u8,
    };
    var flags: std.ArrayList(Flag) = .empty;
    while (findPastAndAdvance(&flags_text, "<type ")) {
        const j = std.mem.find(u8, flags_text, ">") orelse @panic("Unclosed tag");
        const tag = flags_text[0..j];
        flags_text = flags_text[j..];
        if (tag[tag.len - 1] == '/') {
            // It's an alias
            const name = findProperty(tag, "name") orelse @panic("Unnamed alias");
            const alias = findProperty(tag, "alias") orelse @panic("Failed to find alias");
            try writer.print("pub const {s} = {s};", .{ name, alias });
        } else {
            var new = flags.addOne(allocator) catch panicOOM();
            new.bits_enum = findProperty(tag, "requires") orelse findProperty(tag, "bitvalues");
            if (!findPastAndAdvance(&flags_text, "<type>VkFlags")) @panic("Failed to find flag type");
            new.bits = if (flags_text[0] == '6')
                .@"64"
            else
                .@"32";
            if (!findPastAndAdvance(&flags_text, "<name>")) @panic("Failed to find flag name");
            const name_end = std.mem.find(u8, flags_text, "<") orelse @panic("Unclosed tag");
            new.name = flags_text[0..name_end];
            flags_text = flags_text[name_end..];
        }
    }

    var handles_text = splitSection(&text, "<comment>Types generated from corresponding enums tags below</comment>");
    while (findPastAndAdvance(&handles_text, "<type ")) {
        if (!findPastAndAdvance(&handles_text, "<type>VK_DEFINE_")) @panic("Failed to find handle type");
        const non_dispatchable = handles_text[0] == 'N';
        if (!findPastAndAdvance(&handles_text, "<name>")) @panic("Failed to find handle name");
        const end = std.mem.find(u8, handles_text, "<") orelse @panic("Unclosed tag");
        const name = handles_text[0..end];
        handles_text = handles_text[end..];
        try writer.print("pub const {s} = enum({s}){{ null_handle, _ }};", .{ name, if (non_dispatchable) "u64" else "usize" });
    }

    var enums_text = splitSection(&text, "<type category=\"funcpointer\">");
    while (true) {
        const alias_start = std.mem.find(u8, enums_text, "alias=\"") orelse break;
        const t_1 = enums_text[alias_start + "alias=\"".len ..];
        const alias_end = std.mem.find(u8, t_1, "\"") orelse @panic("Unclosed string");
        const alias = t_1[0..alias_end];
        const name_start = std.mem.findLast(u8, enums_text[0..alias_start], "name=\"") orelse @panic("Failed to find alias name");
        const t_2 = enums_text[name_start + "name=\"".len ..];
        const name_end = std.mem.find(u8, t_2, "\"") orelse @panic("Unclosed string");
        const name = t_2[0..name_end];
        try writer.print("pub const {s} = {s};", .{ name, alias });
        enums_text = enums_text[alias_start + alias_end ..];
    }
    var funcpointers_text = splitSection(&text, "<comment>Struct types</comment>");
    while (true) {
        const return_type = parseType(&funcpointers_text) orelse @panic("Function prototype without return type");
        if (!findPastAndAdvance(&funcpointers_text, "<name>")) @panic("Function prototype without name");
        const name_index = std.mem.find(u8, funcpointers_text, "</name>") orelse @panic("Unclosed name tag");
        const func_name = funcpointers_text[0..name_index];
        funcpointers_text = funcpointers_text[name_index..];
        try writer.print("pub const {s} = *const fn(", .{func_name});
        const next_index = std.mem.find(u8, funcpointers_text, "<type category=\"funcpointer\"");
        var this = if (next_index) |i| funcpointers_text[0..i] else funcpointers_text;
        while (parseType(&this)) |param_type| {
            if (!findPastAndAdvance(&this, "<name>")) @panic("Function parameter without name");
            const param_name_index = std.mem.find(u8, this, "</name>") orelse @panic("Unclosed name tag");
            const param_name = this[0..param_name_index];
            this = this[param_name_index..];
            try writer.print("{s}: {f},", .{ param_name, param_type });
        }
        try writer.print(") callconv(vulkan_api) {f};", .{return_type});

        if (next_index) |i| {
            funcpointers_text = funcpointers_text[i..];
        } else {
            break;
        }
    }
}
