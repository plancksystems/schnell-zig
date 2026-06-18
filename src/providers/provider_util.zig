
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn verifyHmacSha256(secret: []const u8, message_parts: []const []const u8, sig_hex: []const u8) bool {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var hm = HmacSha256.init(secret);
    for (message_parts) |part| hm.update(part);
    hm.final(&mac);

    var expected_hex: [HmacSha256.mac_length * 2]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (mac, 0..) |byte, i| {
        expected_hex[i * 2] = hex_chars[byte >> 4];
        expected_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    if (sig_hex.len != expected_hex.len) return false;
    return std.crypto.timing_safe.eql([expected_hex.len]u8, expected_hex, sig_hex[0..expected_hex.len].*);
}

pub fn basicAuth(allocator: Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const creds = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, pass });
    defer allocator.free(creds);
    const encoded_len = std.base64.standard.Encoder.calcSize(creds.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, creds);
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

pub fn extractJsonField(body: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle_len = name.len + 4;
    if (needle_len > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + name.len], name);
    needle_buf[1 + name.len] = '"';
    needle_buf[2 + name.len] = ':';
    needle_buf[3 + name.len] = '"';
    const needle = needle_buf[0..needle_len];

    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = start + needle_len;
    const end = std.mem.indexOfScalar(u8, body[val_start..], '"') orelse return null;
    return body[val_start..][0..end];
}
