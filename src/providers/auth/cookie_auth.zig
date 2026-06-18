
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const root = @import("../../root.zig");
const Request = root.Request;
const Response = root.Response;
const Middleware = root.Middleware;
const Client = root.Client;

const log = std.log.scoped(.cookie_auth);

pub const FieldMapping = struct {
    json_field: []const u8,
    local_key: []const u8,
};

pub const Config = struct {
    cookie_name: []const u8,

    session_lookup_url: []const u8,

    field_mappings: []const FieldMapping = &.{
        .{ .json_field = "user_id", .local_key = "user_id" },
    },

    skip_paths: []const []const u8 = &.{},

    cache_ttl_ms: i64 = 60_000,

    cache_max_entries: usize = 4096,
};

const CacheEntry = struct {
    fields: []FieldValue,
    expires_at_ms: i64,
};

const FieldValue = struct {
    local_key: []const u8,
    value: []u8,
};

pub const CookieAuthMiddleware = struct {
    config: Config,
    io: Io,
    cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    cache_allocator: Allocator,
    cache_mu: Io.Mutex = .init,

    pub fn init(allocator: Allocator, config: Config, io: Io) CookieAuthMiddleware {
        return .{ .config = config, .io = io, .cache_allocator = allocator };
    }

    pub fn deinit(self: *CookieAuthMiddleware) void {
        self.cache_mu.lockUncancelable(self.io);
        defer self.cache_mu.unlock(self.io);
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            self.cache_allocator.free(kv.key_ptr.*);
            self.freeEntry(kv.value_ptr.*);
        }
        self.cache.deinit(self.cache_allocator);
    }

    pub fn middleware(self: *CookieAuthMiddleware) Middleware {
        return Middleware.from(CookieAuthMiddleware, self);
    }

    pub fn execute(
        self: *CookieAuthMiddleware,
        allocator: Allocator,
        req: *const Request,
        _: *Response
    ) !Middleware.Action {
        for (self.config.skip_paths) |p| {
            if (matchesSkip(req.path, p)) return .next;
        }

        const token = req.getCookie(self.config.cookie_name) orelse return .next;
        if (token.len == 0) return .next;

        if (self.config.cache_ttl_ms > 0) {
            if (self.cacheGet(allocator, token, req)) {
                return .next;
            }
        }

        const lookup_url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ self.config.session_lookup_url, token },
        );
        defer allocator.free(lookup_url);

        var resp = Client.request(allocator, req.io orelse self.io, .{
            .method = "GET",
            .url = lookup_url,
        }) catch |err| {
            log.warn("session lookup failed for path={s}: {s}", .{ req.path, @errorName(err) });
            return .next;
        };
        defer resp.deinit();

        if (resp.status != 200) return .next;

        var inserted_values: usize = 0;
        for (self.config.field_mappings) |mapping| {
            if (try extractJsonField(allocator, resp.body, mapping.json_field)) |value| {
                try req.setLocal(mapping.local_key, value);
                inserted_values += 1;
            }
        }
        if (inserted_values > 0 and self.config.cache_ttl_ms > 0) {
            self.cachePut(token, req) catch |err| {
                log.warn("session cache insert failed: {s}", .{@errorName(err)});
            };
        }
        return .next;
    }

    fn cacheGet(
        self: *CookieAuthMiddleware,
        req_allocator: Allocator,
        token: []const u8,
        req: *const Request
    ) bool {
        self.cache_mu.lockUncancelable(self.io);
        defer self.cache_mu.unlock(self.io);
        const entry = self.cache.getPtr(token) orelse return false;
        const now = Io.Clock.now(.real, self.io).toMilliseconds();
        if (now >= entry.expires_at_ms) return false;
        for (entry.fields) |fv| {
            const v = req_allocator.dupe(u8, fv.value) catch return false;
            req.setLocal(fv.local_key, v) catch return false;
        }
        return true;
    }

    fn cachePut(
        self: *CookieAuthMiddleware,
        token: []const u8,
        req: *const Request
    ) !void {
        self.cache_mu.lockUncancelable(self.io);
        defer self.cache_mu.unlock(self.io);

        if (self.cache.count() >= self.config.cache_max_entries) {
            var it = self.cache.iterator();
            if (it.next()) |kv| {
                const evicted_key = kv.key_ptr.*;
                const evicted_val = kv.value_ptr.*;
                _ = self.cache.remove(evicted_key);
                self.cache_allocator.free(evicted_key);
                self.freeEntry(evicted_val);
            }
        }

        const key_copy = try self.cache_allocator.dupe(u8, token);
        errdefer self.cache_allocator.free(key_copy);

        var fields_buf: std.ArrayList(FieldValue) = .empty;
        errdefer {
            for (fields_buf.items) |fv| self.cache_allocator.free(fv.value);
            fields_buf.deinit(self.cache_allocator);
        }
        for (self.config.field_mappings) |m| {
            const v = req.getLocal(m.local_key) orelse continue;
            const v_copy = try self.cache_allocator.dupe(u8, v);
            try fields_buf.append(self.cache_allocator, .{
                .local_key = m.local_key,
                .value = v_copy,
            });
        }
        const owned = try fields_buf.toOwnedSlice(self.cache_allocator);
        const entry: CacheEntry = .{
            .fields = owned,
            .expires_at_ms = Io.Clock.now(.real, self.io).toMilliseconds() + self.config.cache_ttl_ms,
        };

        if (self.cache.fetchRemove(token)) |old| {
            self.cache_allocator.free(old.key);
            self.freeEntry(old.value);
        }
        try self.cache.put(self.cache_allocator, key_copy, entry);
    }

    fn freeEntry(self: *CookieAuthMiddleware, entry: CacheEntry) void {
        for (entry.fields) |fv| self.cache_allocator.free(fv.value);
        self.cache_allocator.free(entry.fields);
    }
};

fn matchesSkip(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[pattern.len - 1] == '*') {
        return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, path, pattern);
}

fn extractJsonField(allocator: Allocator, body: []const u8, field: []const u8) !?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field});
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;

    var i = idx + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len) return null;

    if (body[i] == '"') {
        i += 1;
        const start = i;
        while (i < body.len and body[i] != '"') : (i += 1) {}
        return try allocator.dupe(u8, body[start..i]);
    }
    const start = i;
    while (i < body.len and body[i] != ',' and body[i] != '}' and body[i] != ' ') : (i += 1) {}
    if (i == start) return null;
    return try allocator.dupe(u8, body[start..i]);
}

test "extractJsonField - string field" {
    const body = "{\"user_id\":\"abc-123\",\"role\":\"admin\"}";
    const got = try extractJsonField(std.testing.allocator, body, "user_id");
    defer if (got) |g| std.testing.allocator.free(g);
    try std.testing.expectEqualStrings("abc-123", got.?);
}

test "extractJsonField - numeric field" {
    const body = "{\"user_id\":42,\"role\":\"admin\"}";
    const got = try extractJsonField(std.testing.allocator, body, "user_id");
    defer if (got) |g| std.testing.allocator.free(g);
    try std.testing.expectEqualStrings("42", got.?);
}

test "extractJsonField - missing field returns null" {
    const body = "{\"role\":\"admin\"}";
    const got = try extractJsonField(std.testing.allocator, body, "user_id");
    try std.testing.expect(got == null);
}

test "matchesSkip - exact path" {
    try std.testing.expect(matchesSkip("/favicon.ico", "/favicon.ico"));
    try std.testing.expect(!matchesSkip("/anything", "/favicon.ico"));
}

test "matchesSkip - wildcard suffix" {
    try std.testing.expect(matchesSkip("/static/app.css", "/static/*"));
    try std.testing.expect(matchesSkip("/static/", "/static/*"));
    try std.testing.expect(!matchesSkip("/api/foo", "/static/*"));
}
