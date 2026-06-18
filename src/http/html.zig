
const std = @import("std");

pub fn appendEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
}
