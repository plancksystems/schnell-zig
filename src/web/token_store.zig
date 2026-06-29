const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("bson");
const sys = @import("sys.zig");

pub const TokenStore = struct {
    const Self = @This();

    pub const TokenEntry = struct {
        uid: []const u8,
        role: []const u8,
        expires_at: i64,
        client_ip: ?[]const u8,
        lru_index: usize = 0,
    };

    tokens: std.StringHashMap(TokenEntry),
    access_order: std.ArrayList([]const u8),
    max_size: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, max_size: u32) TokenStore {
        return .{
            .tokens = .{},
            .access_order = .{},
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeEntry(entry.value_ptr.*);
        }
        self.tokens.deinit(self.allocator);
        self.access_order.deinit(self.allocator);
    }

    pub fn save(self: *Self, token_bson: []const u8) void {
        var decoder = bson.Decoder.init(self.allocator, token_bson);
        const doc = decoder.decode(TokenBson) catch return;

        if (self.tokens.count() >= self.max_size) {
            self.evictLru();
        }

        if (self.tokens.getPtr(doc.token)) |existing| {
            self.freeEntry(existing.*);
            existing.* = TokenEntry{
                .uid = self.allocator.dupe(u8, doc.uid) catch return,
                .role = self.allocator.dupe(u8, doc.role) catch return,
                .expires_at = doc.expires_at,
                .client_ip = if (doc.client_ip.len > 0) self.allocator.dupe(u8, doc.client_ip) catch null else null,
            };
            self.moveToBack(doc.token);
            return;
        }

        const token_key = self.allocator.dupe(u8, doc.token) catch return;
        const entry = TokenEntry{
            .uid = self.allocator.dupe(u8, doc.uid) catch return,
            .role = self.allocator.dupe(u8, doc.role) catch return,
            .expires_at = doc.expires_at,
            .client_ip = if (doc.client_ip.len > 0) self.allocator.dupe(u8, doc.client_ip) catch null else null,
        };
        self.tokens.put(token_key, entry) catch return;
        self.access_order.append(self.allocator, token_key) catch return;
    }

    pub fn revoke(self: *Self, token_bson: []const u8) void {
        var decoder = bson.Decoder.init(self.allocator, token_bson);
        const doc = decoder.decode(TokenBson) catch return;
        self.removeToken(doc.token);
    }

    pub fn validate(self: *Self, bearer_token: []const u8, client_ip: ?[]const u8, bind_ip: bool) ?TokenEntry {
        const entry = self.tokens.get(bearer_token) orelse return null;

        const now = sys.nowUnixMilliSeconds();
        if (now > entry.expires_at) {
            self.removeToken(bearer_token);
            return null;
        }

        if (bind_ip) {
            if (entry.client_ip) |stored_ip| {
                if (client_ip) |req_ip| {
                    if (!std.mem.eql(u8, stored_ip, req_ip)) return null;
                }
            }
        }

        self.moveToBack(bearer_token);
        return entry;
    }

    pub fn purgeExpired(self: *Self) void {
        const now = sys.nowUnixMilliSeconds();
        var to_remove: std.ArrayList([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.expires_at) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |token| {
            self.removeToken(token);
        }
    }

    pub fn count(self: *const Self) u32 {
        return @intCast(self.tokens.count());
    }

    fn evictLru(self: *Self) void {
        if (self.access_order.items.len == 0) return;
        const lru_key = self.access_order.orderedRemove(0);
        if (self.tokens.fetchRemove(lru_key)) |kv| {
            self.freeEntry(kv.value);
            self.allocator.free(kv.key);
        }
    }

    fn removeToken(self: *Self, token: []const u8) void {
        if (self.tokens.fetchRemove(token)) |kv| {
            self.freeEntry(kv.value);
            for (self.access_order.items, 0..) |key, i| {
                if (std.mem.eql(u8, key, token)) {
                    _ = self.access_order.orderedRemove(i);
                    break;
                }
            }
            self.allocator.free(kv.key);
        }
    }

    fn moveToBack(self: *Self, token: []const u8) void {
        for (self.access_order.items, 0..) |key, i| {
            if (std.mem.eql(u8, key, token)) {
                _ = self.access_order.orderedRemove(i);
                self.access_order.append(self.allocator, token) catch {};
                break;
            }
        }
    }

    fn freeEntry(self: *Self, entry: TokenEntry) void {
        self.allocator.free(entry.uid);
        self.allocator.free(entry.role);
        if (entry.client_ip) |ip| self.allocator.free(ip);
    }
};

const TokenBson = struct {
    token: []const u8 = "",
    uid: []const u8 = "",
    role: []const u8 = "",
    expires_at: i64 = 0,
    client_ip: []const u8 = "",
};

const testing = std.testing;

test "TokenStore - init and deinit" {
    var store = TokenStore.init(testing.allocator, 100);
    defer store.deinit();
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "TokenStore - insert and validate via internal API" {
    var store = TokenStore.init(testing.allocator, 100);
    defer store.deinit();

    const token_key = try testing.allocator.dupe(u8, "bearer-token-123");
    const entry = TokenStore.TokenEntry{
        .uid = try testing.allocator.dupe(u8, "user1"),
        .role = try testing.allocator.dupe(u8, "admin"),
        .expires_at = sys.nowUnixMilliSeconds() + 60_000,
        .client_ip = null,
    };
    try store.tokens.put(testing.allocator, token_key, entry);
    try store.access_order.append(testing.allocator, token_key);

    try testing.expectEqual(@as(u32, 1), store.count());

    const result = store.validate("bearer-token-123", null, false);
    try testing.expect(result != null);
    try testing.expectEqualStrings("user1", result.?.uid);
    try testing.expectEqualStrings("admin", result.?.role);
}

test "TokenStore - validate rejects expired token" {
    var store = TokenStore.init(testing.allocator, 100);
    defer store.deinit();

    const token_key = try testing.allocator.dupe(u8, "expired-token");
    const entry = TokenStore.TokenEntry{
        .uid = try testing.allocator.dupe(u8, "user1"),
        .role = try testing.allocator.dupe(u8, "read_only"),
        .expires_at = sys.nowUnixMilliSeconds() - 1000,
        .client_ip = null,
    };
    try store.tokens.put(testing.allocator, token_key, entry);
    try store.access_order.append(testing.allocator, token_key);

    const result = store.validate("expired-token", null, false);
    try testing.expect(result == null);
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "TokenStore - validate nonexistent token returns null" {
    var store = TokenStore.init(testing.allocator, 100);
    defer store.deinit();

    const result = store.validate("does-not-exist", null, false);
    try testing.expect(result == null);
}

test "TokenStore - LRU eviction at capacity" {
    var store = TokenStore.init(testing.allocator, 2);
    defer store.deinit();

    const k1 = try testing.allocator.dupe(u8, "token-1");
    try store.tokens.put(testing.allocator, k1, .{
        .uid = try testing.allocator.dupe(u8, "u1"),
        .role = try testing.allocator.dupe(u8, "admin"),
        .expires_at = sys.nowUnixMilliSeconds() + 60_000,
        .client_ip = null,
    });
    try store.access_order.append(testing.allocator, k1);

    const k2 = try testing.allocator.dupe(u8, "token-2");
    try store.tokens.put(testing.allocator, k2, .{
        .uid = try testing.allocator.dupe(u8, "u2"),
        .role = try testing.allocator.dupe(u8, "read_write"),
        .expires_at = sys.nowUnixMilliSeconds() + 60_000,
        .client_ip = null,
    });
    try store.access_order.append(testing.allocator, k2);

    try testing.expectEqual(@as(u32, 2), store.count());

    store.evictLru();
    try testing.expectEqual(@as(u32, 1), store.count());

    try testing.expect(store.validate("token-1", null, false) == null);
    try testing.expect(store.validate("token-2", null, false) != null);
}

test "TokenStore - purgeExpired removes only expired tokens" {
    var store = TokenStore.init(testing.allocator, 100);
    defer store.deinit();

    const k1 = try testing.allocator.dupe(u8, "valid-token");
    try store.tokens.put(testing.allocator, k1, .{
        .uid = try testing.allocator.dupe(u8, "u1"),
        .role = try testing.allocator.dupe(u8, "admin"),
        .expires_at = sys.nowUnixMilliSeconds() + 60_000,
        .client_ip = null,
    });
    try store.access_order.append(testing.allocator, k1);

    const k2 = try testing.allocator.dupe(u8, "expired-token");
    try store.tokens.put(testing.allocator, k2, .{
        .uid = try testing.allocator.dupe(u8, "u2"),
        .role = try testing.allocator.dupe(u8, "read_only"),
        .expires_at = sys.nowUnixMilliSeconds() - 1000,
        .client_ip = null,
    });
    try store.access_order.append(testing.allocator, k2);

    try testing.expectEqual(@as(u32, 2), store.count());

    store.purgeExpired();

    try testing.expectEqual(@as(u32, 1), store.count());
    try testing.expect(store.validate("valid-token", null, false) != null);
}
