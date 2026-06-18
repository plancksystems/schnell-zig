
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const schnell = @import("schnell");
const Client = schnell.Client;

pub const JwksCache = struct {
    const Self = @This();

    pub const JwkEntry = struct {
        kid: []const u8,
        key_data: []const u8,
        alg: []const u8,
    };

    keys: std.StringHashMapUnmanaged(JwkEntry),
    allocator: Allocator,
    jwks_url: []const u8,
    last_fetched_ms: i64 = 0,
    ttl_ms: i64 = 86_400_000,

    pub fn init(allocator: Allocator, jwks_url: []const u8) JwksCache {
        return .{
            .keys = .{},
            .allocator = allocator,
            .jwks_url = jwks_url,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.kid);
            self.allocator.free(entry.value_ptr.key_data);
            self.allocator.free(entry.value_ptr.alg);
        }
        self.keys.deinit(self.allocator);
    }

    pub fn refreshIfNeeded(self: *Self, io: Io) !void {
        const now = std.time.milliTimestamp();
        if (now - self.last_fetched_ms < self.ttl_ms) return;
        try self.fetch(io);
    }

    pub fn fetch(self: *Self, io: Io) !void {
        var resp = try Client.request(self.allocator, io, .{
            .url = self.jwks_url,
            .timeout_ms = 10_000,
        });
        defer resp.deinit();

        if (resp.status != 200) return error.JwksFetchFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{});
        defer parsed.deinit();

        const keys_array = (parsed.value.object.get("keys") orelse return error.InvalidJwks).array;

        var old_it = self.keys.iterator();
        while (old_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.kid);
            self.allocator.free(entry.value_ptr.key_data);
            self.allocator.free(entry.value_ptr.alg);
        }
        self.keys.clearRetainingCapacity();

        for (keys_array.items) |key_val| {
            const key_obj = key_val.object;
            const kid = (key_obj.get("kid") orelse continue).string;
            const alg = if (key_obj.get("alg")) |a| a.string else "RS256";

            const n = if (key_obj.get("n")) |nv| nv.string else "";
            const e = if (key_obj.get("e")) |ev| ev.string else "";
            const key_data = try std.fmt.allocPrint(
                self.allocator,
                "{{\"n\":\"{s}\",\"e\":\"{s}\"}}",
                .{ n, e },
            );

            const kid_dupe = try self.allocator.dupe(u8, kid);
            const alg_dupe = try self.allocator.dupe(u8, alg);

            try self.keys.put(self.allocator, kid_dupe, .{
                .kid = kid_dupe,
                .key_data = key_data,
                .alg = alg_dupe,
            });
        }

        self.last_fetched_ms = std.time.milliTimestamp();
    }

    pub fn getKey(self: *const Self, kid: []const u8) ?JwkEntry {
        return self.keys.get(kid);
    }

    pub fn validateJwt(self: *const Self, allocator: Allocator, jwt: []const u8, expected_iss: ?[]const u8, expected_aud: ?[]const u8) !bool {
        var parts = std.mem.splitScalar(u8, jwt, '.');
        const header_b64 = parts.next() orelse return false;
        const payload_b64 = parts.next() orelse return false;
        _ = parts.next() orelse return false;
        const header_json = try decodeBase64Url(allocator, header_b64);
        defer allocator.free(header_json);

        var header_parsed = try std.json.parseFromSlice(std.json.Value, allocator, header_json, .{});
        defer header_parsed.deinit();

        const kid = (header_parsed.value.object.get("kid") orelse return false).string;

        if (self.getKey(kid) == null) return false;

        const payload_json = try decodeBase64Url(allocator, payload_b64);
        defer allocator.free(payload_json);

        var payload_parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
        defer payload_parsed.deinit();
        const claims = payload_parsed.value.object;

        if (claims.get("exp")) |exp| {
            const exp_ts = exp.integer;
            const now_s = @divTrunc(std.time.milliTimestamp(), 1000);
            if (now_s > exp_ts) return false;
        }

        if (expected_iss) |iss| {
            if (claims.get("iss")) |token_iss| {
                if (!std.mem.eql(u8, token_iss.string, iss)) return false;
            } else return false;
        }

        if (expected_aud) |aud| {
            if (claims.get("aud")) |token_aud| {
                if (!std.mem.eql(u8, token_aud.string, aud)) return false;
            } else return false;
        }

        return true;
    }
};

pub const ProviderJwksUrls = struct {
    pub const google = "https://www.googleapis.com/oauth2/v3/certs";
    pub const firebase = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";
    pub fn azure(allocator: Allocator, tenant_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "https://login.microsoftonline.com/{s}/discovery/v2.0/keys",
            .{tenant_id},
        );
    }
};

pub fn decodeBase64Url(allocator: Allocator, input: []const u8) ![]const u8 {
    const padded_len = (input.len + 3) / 4 * 4;
    const padded = try allocator.alloc(u8, padded_len);
    defer allocator.free(padded);
    @memcpy(padded[0..input.len], input);
    for (padded[0..input.len]) |*c| {
        if (c.* == '-') c.* = '+';
        if (c.* == '_') c.* = '/';
    }
    @memset(padded[input.len..], '=');

    const decoded = try allocator.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(padded) catch return error.InvalidBase64);
    std.base64.standard.Decoder.decode(decoded, padded) catch return error.InvalidBase64;
    return decoded;
}

pub const JwksError = error{
    JwksFetchFailed,
    InvalidJwks,
    InvalidBase64,
    InvalidResponse,
    OutOfMemory,
};
