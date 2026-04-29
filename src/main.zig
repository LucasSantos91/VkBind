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
fn findPropertyImpl(text: []const u8, property: []const u8) ?[]const u8 {
    const i = findPast(text, property) orelse return null;
    const t = text[i..];
    const j = std.mem.find(u8, t, "\"") orelse @panic("Unclosed string");
    return t[0..j];
}
fn findProperty(text: []const u8, comptime property: []const u8) ?[]const u8 {
    return findPropertyImpl(text, property ++ "=\"");
}
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var text = blk: {
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

    var flags_text = blk: {
        const i = findPast(text, "<comment>Bitmask types</comment>") orelse @panic("Failed to find flags");
        text = text[i..];
        const final_index = findPast(text, "<comment>Types which can be void pointers or class pointers, selected at compile time</comment>") orelse @panic("Failed to find handles");
        const f = text[0..final_index];
        text = text[final_index..];
        break :blk f;
    };

    const Flag = struct {
        const Bits = enum { @"32", @"64" };
        name: []const u8,
        bits: Bits,
        bits_enum: ?[]const u8,
    };
    var flags: std.ArrayList(Flag) = .empty;
    while (findPast(flags_text, "<type ")) |i| {
        flags_text = flags_text[i..];
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
            const bits_start = findPast(flags_text, "<type>VkFlags") orelse @panic("Failed to find flag type");
            flags_text = flags_text[bits_start..];
            new.bits = if (flags_text[0] == '6')
                .@"64"
            else
                .@"32";
            const name_start = findPast(flags_text, "<name>") orelse @panic("Failed to find flag name");
            flags_text = flags_text[name_start..];
            const name_end = std.mem.find(u8, flags_text, "<") orelse @panic("Unclosed tag");
            new.name = flags_text[0..name_end];
            flags_text = flags_text[name_end..];
        }
    }

    for (flags.items) |f| {
        std.debug.print("Flag: {s} - {t} - {?s}\n", .{ f.name, f.bits, f.bits_enum });
    }
}
