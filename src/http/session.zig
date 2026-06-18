
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const utils = @import("utils");
const Request = @import("request.zig").Request;
const metrics_mod = @import("../metrics.zig");
const Metrics = metrics_mod.Metrics;
const Label = metrics_mod.Label;

const log = std.log.scoped(.session);

const labels_empty: []const Label = &.{};
const labels_expire: []const Label = &.{.{ .name = "reason", .value = "expired" }};
const labels_evict: []const Label = &.{.{ .name = "reason", .value = "evicted" }};
const labels_destroy: []const Label = &.{.{ .name = "reason", .value = "destroyed" }};

pub const Config = struct {
    max_entries: u32 = 100_000,
    default_ttl_ms: i64 = 7 * 24 * 60 * 60 * 1000,
    prune_interval_ms: u64 = 5 * 60 * 1000,
    metrics: Metrics = .{},
    require_secure: bool = false,
};

pub fn SessionStore(comptime AppData: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            expires_at: i64,
            last_access_seq: u64 = 0,
            data: AppData,
        };

        allocator: Allocator,
        io: Io,
        entries: std.StringHashMapUnmanaged(Entry),
        mutex: Io.Mutex,
        max_entries: u32,
        default_ttl_ms: i64,
        prune_interval_ms: u64,
        metrics: Metrics,
        prune_group: Io.Group,
        stopping: std.atomic.Value(bool),
        access_seq: u64,

        pub fn init(allocator: Allocator, io: Io, config: Config) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .entries = .empty,
                .mutex = Io.Mutex.init,
                .max_entries = config.max_entries,
                .default_ttl_ms = config.default_ttl_ms,
                .prune_interval_ms = config.prune_interval_ms,
                .metrics = config.metrics,
                .prune_group = .init,
                .stopping = std.atomic.Value(bool).init(false),
                .access_seq = 0,
            };
        }

        pub fn start(self: *Self) void {
            if (self.prune_interval_ms == 0) return;
            self.prune_group.async(self.io, pruneLoop, .{self});
        }

        pub fn deinit(self: *Self) void {
            self.stopping.store(true, .release);
            self.prune_group.cancel(self.io);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.data.deinit(self.allocator);
            }
            self.entries.deinit(self.allocator);
        }

        pub fn create(self: *Self, io: Io, data: AppData) ![]const u8 {
            var raw: [32]u8 = undefined;
            io.random(&raw);
            const hex = std.fmt.bytesToHex(raw, .lower);
            const token_caller = try self.allocator.dupe(u8, &hex);
            errdefer self.allocator.free(token_caller);
            const token_internal = try self.allocator.dupe(u8, token_caller);
            errdefer self.allocator.free(token_internal);

            const now = nowMs(io);
            const duped = try data.dupe(self.allocator);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            try self.makeRoomLocked(now);

            self.access_seq += 1;
            try self.entries.put(self.allocator, token_internal, .{
                .expires_at = now + self.default_ttl_ms,
                .last_access_seq = self.access_seq,
                .data = duped,
            });
            self.metrics.counter("session_created_total", 1, labels_empty);
            self.metrics.gauge("session_active", @intCast(self.entries.count()), labels_empty);
            return token_caller;
        }

        pub fn get(self: *Self, io: Io, token: []const u8) !?AppData {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const entry = self.timingSafeLookup(token) orelse return null;
            const now = nowMs(io);
            if (now > entry.value_ptr.expires_at) {
                const key = entry.key_ptr.*;
                var e = entry.value_ptr.*;
                _ = self.entries.remove(token);
                self.allocator.free(key);
                e.data.deinit(self.allocator);
                self.metrics.counter("session_destroyed_total", 1, labels_expire);
                return null;
            }
            self.access_seq += 1;
            entry.value_ptr.last_access_seq = self.access_seq;
            return entry.value_ptr.data;
        }

        pub fn destroy(self: *Self, _: Io, token: []const u8) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const removed = self.entries.fetchRemove(token) orelse return;
            self.allocator.free(removed.key);
            var e = removed.value;
            e.data.deinit(self.allocator);
            self.metrics.counter("session_destroyed_total", 1, labels_destroy);
        }

        pub fn rotate(self: *Self, io: Io, old_token: []const u8) ![]const u8 {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const removed = self.entries.fetchRemove(old_token) orelse return error.SessionNotFound;
            self.allocator.free(removed.key);

            var raw: [32]u8 = undefined;
            io.random(&raw);
            const hex = std.fmt.bytesToHex(raw, .lower);
            const token_internal = self.allocator.dupe(u8, &hex) catch {
                var e = removed.value;
                e.data.deinit(self.allocator);
                return error.OutOfMemory;
            };
            const token_caller = self.allocator.dupe(u8, token_internal) catch {
                var e = removed.value;
                e.data.deinit(self.allocator);
                return error.OutOfMemory;
            };

            self.access_seq += 1;
            var new_entry = removed.value;
            new_entry.last_access_seq = self.access_seq;
            try self.entries.put(self.allocator, token_internal, new_entry);
            return token_caller;
        }

        fn timingSafeEql(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            var diff: u8 = 0;
            for (a, b) |ca, cb| diff |= ca ^ cb;
            return diff == 0;
        }

        fn timingSafeLookup(self: *Self, needle: []const u8) ?std.StringHashMapUnmanaged(Entry).Entry {
            var found: ?std.StringHashMapUnmanaged(Entry).Entry = null;
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (timingSafeEql(entry.key_ptr.*, needle)) {
                    found = .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
                }
            }
            return found;
        }

        fn makeRoomLocked(self: *Self, now: i64) !void {
            if (self.entries.count() < self.max_entries) return;
            self.sweepExpiredLocked(now);
            if (self.entries.count() < self.max_entries) return;

            var lru_key: ?[]const u8 = null;
            var lru_seq: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.last_access_seq < lru_seq) {
                    lru_seq = entry.value_ptr.last_access_seq;
                    lru_key = entry.key_ptr.*;
                }
            }
            if (lru_key) |key| {
                if (self.entries.fetchRemove(key)) |removed| {
                    self.allocator.free(removed.key);
                    var e = removed.value;
                    e.data.deinit(self.allocator);
                    self.metrics.counter("session_destroyed_total", 1, labels_evict);
                }
            }
            if (self.entries.count() >= self.max_entries) return error.SessionStoreFull;
        }

        fn sweepExpiredLocked(self: *Self, now: i64) void {
            var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
            defer to_remove.deinit(self.allocator);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.expires_at < now) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch break;
                }
            }
            for (to_remove.items) |key| {
                if (self.entries.fetchRemove(key)) |removed| {
                    self.allocator.free(removed.key);
                    var e = removed.value;
                    e.data.deinit(self.allocator);
                }
            }
        }

        fn pruneLoop(self: *Self) Io.Cancelable!void {
            while (!self.stopping.load(.acquire)) {
                self.io.sleep(
                    Io.Duration.fromMilliseconds(@intCast(self.prune_interval_ms)),
                    .awake,
                ) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                };
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.sweepExpiredLocked(nowMs(self.io));
            }
        }
    };
}

fn nowMs(io: Io) i64 {
    const now: utils.Now = .{ .io = io };
    return now.toMilliSeconds();
}

pub fn readSessionCookie(req: *const Request, cookie_name: []const u8) ?[]const u8 {
    const cookie_header = req.getHeader("Cookie") orelse req.getHeader("cookie") orelse return null;
    var it = std.mem.splitSequence(u8, cookie_header, "; ");
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, entry[0..eq], " \t"), cookie_name)) {
            return entry[eq + 1 ..];
        }
    }
    return null;
}

pub fn readSessionCookieSecure(req: *const Request, cookie_name: []const u8, require_secure: bool) ?[]const u8 {
    if (require_secure) {
        const proto = req.getHeader("X-Forwarded-Proto") orelse
            req.getHeader("x-forwarded-proto") orelse "http";
        if (!std.mem.eql(u8, proto, "https") and !std.mem.eql(u8, proto, "on")) {
            return null;
        }
    }
    return readSessionCookie(req, cookie_name);
}


const testing = std.testing;

const TestAppData = struct {
    user_id: u64,
    role: []const u8,

    pub fn dupe(self: TestAppData, allocator: Allocator) !TestAppData {
        return .{
            .user_id = self.user_id,
            .role = try allocator.dupe(u8, self.role),
        };
    }

    pub fn deinit(self: *TestAppData, allocator: Allocator) void {
        if (self.role.len > 0) allocator.free(self.role);
    }
};

const TestStore = SessionStore(TestAppData);

fn sampleData() TestAppData {
    return .{ .user_id = 42, .role = "customer" };
}

test "SessionStore: create + get s" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var store = TestStore.init(testing.allocator, io, .{ .prune_interval_ms = 0 });
    defer store.deinit();

    const token = try store.create(io, sampleData());
    defer testing.allocator.free(token);
    const got = try store.get(io, token);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 42), got.?.user_id);
    try testing.expectEqualStrings("customer", got.?.role);
}

test "SessionStore: destroy removes session" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var store = TestStore.init(testing.allocator, io, .{ .prune_interval_ms = 0 });
    defer store.deinit();

    const token = try store.create(io, sampleData());
    defer testing.allocator.free(token);
    try store.destroy(io, token);
    try testing.expect((try store.get(io, token)) == null);
}

test "SessionStore: rotate issues new token" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var store = TestStore.init(testing.allocator, io, .{ .prune_interval_ms = 0 });
    defer store.deinit();

    const old = try store.create(io, sampleData());
    defer testing.allocator.free(old);
    const new = try store.rotate(io, old);
    defer testing.allocator.free(new);
    try testing.expect((try store.get(io, old)) == null);
    try testing.expect((try store.get(io, new)) != null);
}

test "SessionStore: LRU eviction" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var store = TestStore.init(testing.allocator, io, .{ .max_entries = 2, .prune_interval_ms = 0 });
    defer store.deinit();

    const t1 = try store.create(io, sampleData());
    defer testing.allocator.free(t1);
    const t2 = try store.create(io, sampleData());
    defer testing.allocator.free(t2);
    _ = try store.get(io, t2);
    const t3 = try store.create(io, sampleData());
    defer testing.allocator.free(t3);
    try testing.expect((try store.get(io, t1)) == null);
    try testing.expect((try store.get(io, t2)) != null);
    try testing.expect((try store.get(io, t3)) != null);
}
