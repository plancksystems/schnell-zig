
const std = @import("std");
const Request = @import("request.zig").Request;

const sensitive_headers = [_][]const u8{
    "authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
};

pub fn redactHeaderValue(name: []const u8, value: []const u8) []const u8 {
    for (sensitive_headers) |sensitive| {
        if (std.ascii.eqlIgnoreCase(name, sensitive)) {
            if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                if (std.mem.indexOf(u8, value, " ")) |_| {
                    return "Bearer ***";
                }
            }
            return "***";
        }
    }
    return value;
}

pub fn isSensitiveHeader(name: []const u8) bool {
    for (sensitive_headers) |sensitive| {
        if (std.ascii.eqlIgnoreCase(name, sensitive)) return true;
    }
    return false;
}

pub fn formatRedactedHeaders(allocator: std.mem.Allocator, req: *const Request) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (req.headers.items) |header| {
        const safe_value = redactHeaderValue(header.name, header.value);
        try buf.writer().print("{s}: {s}\n", .{ header.name, safe_value });
    }

    return buf.toOwnedSlice();
}


const testing = std.testing;

test "redactHeaderValue - Authorization bearer is redacted" {
    const result = redactHeaderValue("Authorization", "Bearer eyJhbGciOiJSUzI1NiJ9.payload.signature");
    try testing.expectEqualStrings("Bearer ***", result);
}

test "redactHeaderValue - Cookie is redacted" {
    const result = redactHeaderValue("Cookie", "session=abc123; token=xyz");
    try testing.expectEqualStrings("***", result);
}

test "redactHeaderValue - Set-Cookie is redacted" {
    const result = redactHeaderValue("set-cookie", "session=abc123; Path=/; HttpOnly");
    try testing.expectEqualStrings("***", result);
}

test "redactHeaderValue - X-Api-Key is redacted" {
    const result = redactHeaderValue("X-Api-Key", "sk-12345-secret");
    try testing.expectEqualStrings("***", result);
}

test "redactHeaderValue - case insensitive" {
    try testing.expectEqualStrings("Bearer ***", redactHeaderValue("authorization", "Bearer token123"));
    try testing.expectEqualStrings("***", redactHeaderValue("COOKIE", "data"));
}

test "redactHeaderValue - non-sensitive headers pass through" {
    try testing.expectEqualStrings("application/json", redactHeaderValue("Content-Type", "application/json"));
    try testing.expectEqualStrings("text/html", redactHeaderValue("Accept", "text/html"));
    try testing.expectEqualStrings("no-cache", redactHeaderValue("Cache-Control", "no-cache"));
}

test "isSensitiveHeader - detects sensitive headers" {
    try testing.expect(isSensitiveHeader("Authorization"));
    try testing.expect(isSensitiveHeader("cookie"));
    try testing.expect(isSensitiveHeader("Set-Cookie"));
    try testing.expect(isSensitiveHeader("X-Api-Key"));
}

test "isSensitiveHeader - non-sensitive returns false" {
    try testing.expect(!isSensitiveHeader("Content-Type"));
    try testing.expect(!isSensitiveHeader("Accept"));
    try testing.expect(!isSensitiveHeader("X-Request-Id"));
}
