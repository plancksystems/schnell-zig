
const std = @import("std");

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

const hex_chars = "0123456789ABCDEF";

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

 pub fn decode(encoded: []const u8) []const u8 {
    const buf = @as([*]u8, @ptrFromInt(@intFromPtr(encoded.ptr)));
    var i: usize = 0;
    var j: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = hexVal(encoded[i + 1]);
            const lo = hexVal(encoded[i + 2]);
            if (hi != null and lo != null) {
                buf[j] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                j += 1;
                i += 3;
                continue;
            }
        }
        if (encoded[i] == '+') {
            buf[j] = ' ';
        } else {
            buf[j] = encoded[i];
        }
        j += 1;
        i += 1;
    }
    return buf[0..j];
}
 
pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, encoded.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = hexVal(encoded[i + 1]);
            const lo = hexVal(encoded[i + 2]);
            if (hi != null and lo != null) {
                const byte: u8 = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                try out.append(allocator, byte);
                i += 3;
                continue;
            }
        }
        if (encoded[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, encoded[i]);
        }
        i += 1;
    }
    
    return out.toOwnedSlice(allocator);
}

pub const EncodeMode = enum {
    form,
    path,
};

pub fn encode(allocator: std.mem.Allocator, raw: []const u8, mode: EncodeMode) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len * 3);
    errdefer out.deinit(allocator);

    for (raw) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else if (c == ' ') {
            switch (mode) {
                .form => try out.append(allocator, '+'),
                .path => try out.appendSlice(allocator, "%20"),
            }
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex_chars[c >> 4]);
            try out.append(allocator, hex_chars[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn encodeBuf(raw: []const u8, mode: EncodeMode, buf: []u8) ![]const u8 {
    var j: usize = 0;
    for (raw) |c| {
        if (isUnreserved(c)) {
            if (j >= buf.len) return error.NoSpaceLeft;
            buf[j] = c;
            j += 1;
        } else if (c == ' ') {
            switch (mode) {
                .form => {
                    if (j >= buf.len) return error.NoSpaceLeft;
                    buf[j] = '+';
                    j += 1;
                },
                .path => {
                    if (j + 3 > buf.len) return error.NoSpaceLeft;
                    buf[j] = '%';
                    buf[j + 1] = '2';
                    buf[j + 2] = '0';
                    j += 3;
                },
            }
        } else {
            if (j + 3 > buf.len) return error.NoSpaceLeft;
            buf[j] = '%';
            buf[j + 1] = hex_chars[c >> 4];
            buf[j + 2] = hex_chars[c & 0x0F];
            j += 3;
        }
    }
    return buf[0..j];
}

fn isQuerySafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '_', '.', '~' => true,  
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,  
        ':', '@', '/', '?' => true,  
        else => false,
    };
}

pub fn encodeComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);

    for (raw) |c| {
        if (isQuerySafe(c)) {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.appendSlice(allocator, "%20");
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex_chars[c >> 4]);
            try out.append(allocator, hex_chars[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}


fn decodeCopy(input: []const u8, buf: []u8) []const u8 {
    @memcpy(buf[0..input.len], input);
    return decode(buf[0..input.len]);
}

test "decode - basic percent encoding" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("hello%20world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "decode - plus as space" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("hello+world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "decode - mixed" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("caf%C3%A9+%26+cr%C3%A8me", &buf);
    try std.testing.expectEqualStrings("caf\xC3\xA9 & cr\xC3\xA8me", result);
}

test "decode - invalid percent sequence preserved" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("100%guaranteed", &buf);
    try std.testing.expectEqualStrings("100%guaranteed", result);
}

test "decode - trailing percent" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("test%", &buf);
    try std.testing.expectEqualStrings("test%", result);
}

test "decode - all printable specials" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("%21%40%23%24%25%5E%26%2A%28%29", &buf);
    try std.testing.expectEqualStrings("!@#$%^&*()", result);
}

test "decode - lowercase hex" {
    var buf: [64]u8 = undefined;
    const result = decodeCopy("%2f%3a%3b", &buf);
    try std.testing.expectEqualStrings("/:;", result);
}

test "encode - form mode" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "hello world & café", .form);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello+world+%26+caf%C3%A9", result);
}

test "encode - path mode" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "hello world", .path);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello%20world", result);
}

test "encode - unreserved pass through" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "ABCxyz019-_.~", .path);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ABCxyz019-_.~", result);
}

test "encode - special characters" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "a=1&b=2", .form);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a%3D1%26b%3D2", result);
}

test "roundtrip - encode then decode" {
    const allocator = std.testing.allocator;
    const original = "héllo wörld! @#$%^&*()";
    const encoded = try encode(allocator, original, .path);
    defer allocator.free(encoded);
    const decoded = try decodeAlloc(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "encodeBuf - fits" {
    var buf: [64]u8 = undefined;
    const result = try encodeBuf("hello world", .form, &buf);
    try std.testing.expectEqualStrings("hello+world", result);
}

test "encodeBuf - too small" {
    var buf: [3]u8 = undefined;
    const result = encodeBuf("hello world", .path, &buf);
    try std.testing.expectError(error.NoSpaceLeft, result);
}
