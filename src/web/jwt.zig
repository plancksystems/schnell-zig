
const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const Error = error{
    InvalidFormat,
    MalformedJson,
    BadSignature,
    Expired,
    UnsupportedAlgorithm,
    BadHeader,
    OutOfMemory,
};

pub const Claims = struct {
    sub: []const u8,
    email: []const u8,
    name: []const u8,
    iat: i64,
    exp: i64,

    pub fn deinit(self: *Claims, allocator: Allocator) void {
        if (self.sub.len > 0) allocator.free(self.sub);
        if (self.email.len > 0) allocator.free(self.email);
        if (self.name.len > 0) allocator.free(self.name);
    }
};

const Header = struct {
    alg: []const u8 = "HS256",
    typ: []const u8 = "JWT",
};

pub fn mint(allocator: Allocator, secret: []const u8, claims: Claims) Error![]u8 {
    const header_json = std.json.Stringify.valueAlloc(
        allocator,
        Header{},
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(header_json);

    const claims_json = std.json.Stringify.valueAlloc(
        allocator,
        claims,
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(claims_json);

    const header_b64 = try b64Encode(allocator, header_json);
    defer allocator.free(header_b64);
    const claims_b64 = try b64Encode(allocator, claims_json);
    defer allocator.free(claims_b64);

    const signing_input = std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, claims_b64 }) catch
        return error.OutOfMemory;
    defer allocator.free(signing_input);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signing_input, secret);

    const sig_b64 = try b64Encode(allocator, &mac);
    defer allocator.free(sig_b64);

    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, claims_b64, sig_b64 }) catch
        error.OutOfMemory;
}

pub fn verify(
    allocator: Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix_s: i64
) Error!Claims {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.InvalidFormat;
    const rest = token[first_dot + 1 ..];
    const second_dot_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidFormat;
    const header_b64 = token[0..first_dot];
    const claims_b64 = rest[0..second_dot_rel];
    const sig_b64 = rest[second_dot_rel + 1 ..];
    if (header_b64.len == 0 or claims_b64.len == 0 or sig_b64.len == 0) return error.InvalidFormat;

    const signing_input = std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, claims_b64 }) catch
        return error.OutOfMemory;
    defer allocator.free(signing_input);

    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, signing_input, secret);

    const actual_sig = try b64Decode(allocator, sig_b64);
    defer allocator.free(actual_sig);
    if (actual_sig.len != expected_mac.len) return error.BadSignature;

    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, actual_sig[0..HmacSha256.mac_length].*, expected_mac))
        return error.BadSignature;

    const header_json = try b64Decode(allocator, header_b64);
    defer allocator.free(header_json);
    var hdr_parsed = std.json.parseFromSlice(Header, allocator, header_json, .{ .ignore_unknown_fields = true }) catch
        return error.MalformedJson;
    defer hdr_parsed.deinit();
    if (!std.mem.eql(u8, hdr_parsed.value.alg, "HS256")) return error.UnsupportedAlgorithm;
    if (!std.mem.eql(u8, hdr_parsed.value.typ, "JWT")) return error.BadHeader;

    const claims_json = try b64Decode(allocator, claims_b64);
    defer allocator.free(claims_json);
    var cl_parsed = std.json.parseFromSlice(Claims, allocator, claims_json, .{ .ignore_unknown_fields = true }) catch
        return error.MalformedJson;
    defer cl_parsed.deinit();

    if (cl_parsed.value.exp <= now_unix_s) return error.Expired;

    const dup_sub = allocator.dupe(u8, cl_parsed.value.sub) catch return error.OutOfMemory;
    errdefer allocator.free(dup_sub);
    const dup_email = allocator.dupe(u8, cl_parsed.value.email) catch return error.OutOfMemory;
    errdefer allocator.free(dup_email);
    const dup_name = allocator.dupe(u8, cl_parsed.value.name) catch return error.OutOfMemory;

    return .{
        .sub = dup_sub,
        .email = dup_email,
        .name = dup_name,
        .iat = cl_parsed.value.iat,
        .exp = cl_parsed.value.exp,
    };
}


fn b64Encode(allocator: Allocator, bytes: []const u8) Error![]u8 {
    const out_len = b64.Encoder.calcSize(bytes.len);
    const out = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

fn b64Decode(allocator: Allocator, encoded: []const u8) Error![]u8 {
    const out_len = b64.Decoder.calcSizeForSlice(encoded) catch return error.MalformedJson;
    const out = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    b64.Decoder.decode(out, encoded) catch return error.MalformedJson;
    return out;
}


const testing = std.testing;

test "jwt: mint then verify s claims" {
    const allocator = testing.allocator;
    const secret = "supersecretkeythatisntreal";

    const claims_in = Claims{
        .sub = "user_42",
        .email = "alice@example.com",
        .name = "Alice",
        .iat = 1_700_000_000,
        .exp = 1_700_000_000 + 3600,
    };
    const token = try mint(allocator, secret, claims_in);
    defer allocator.free(token);

    var n_dots: usize = 0;
    for (token) |c| if (c == '.') {
        n_dots += 1;
    };
    try testing.expectEqual(@as(usize, 2), n_dots);

    var claims_out = try verify(allocator, secret, token, 1_700_000_500);
    defer claims_out.deinit(allocator);

    try testing.expectEqualStrings("user_42", claims_out.sub);
    try testing.expectEqualStrings("alice@example.com", claims_out.email);
    try testing.expectEqualStrings("Alice", claims_out.name);
    try testing.expectEqual(@as(i64, 1_700_000_000), claims_out.iat);
    try testing.expectEqual(@as(i64, 1_700_000_000 + 3600), claims_out.exp);
}

test "jwt: verify rejects wrong secret" {
    const allocator = testing.allocator;
    const token = try mint(allocator, "secret-A", Claims{
        .sub = "u",
        .email = "e",
        .name = "n",
        .iat = 0,
        .exp = 1_700_000_000,
    });
    defer allocator.free(token);

    try testing.expectError(error.BadSignature, verify(allocator, "secret-B", token, 0));
}

test "jwt: verify rejects expired token" {
    const allocator = testing.allocator;
    const secret = "k";
    const token = try mint(allocator, secret, Claims{
        .sub = "u",
        .email = "e",
        .name = "n",
        .iat = 1_700_000_000,
        .exp = 1_700_000_100,
    });
    defer allocator.free(token);

    try testing.expectError(error.Expired, verify(allocator, secret, token, 1_700_000_101));
}

test "jwt: verify rejects malformed token" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidFormat, verify(allocator, "k", "no-dots-here", 0));
    try testing.expectError(error.InvalidFormat, verify(allocator, "k", "only.one", 0));
    try testing.expectError(error.InvalidFormat, verify(allocator, "k", "...", 0));
}

test "jwt: verify rejects tampered claims" {
    const allocator = testing.allocator;
    const secret = "k";
    const token = try mint(allocator, secret, Claims{
        .sub = "user_42",
        .email = "e",
        .name = "n",
        .iat = 0,
        .exp = 1_700_000_000,
    });
    defer allocator.free(token);

    const tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    const first_dot = std.mem.indexOfScalar(u8, tampered, '.').?;
    tampered[first_dot + 1] = if (tampered[first_dot + 1] == 'a') 'b' else 'a';

    try testing.expectError(error.BadSignature, verify(allocator, secret, tampered, 0));
}
