
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Middleware = @import("middleware.zig").Middleware;
const metrics_mod = @import("../metrics.zig");
const Metrics = metrics_mod.Metrics;
const Label = metrics_mod.Label;

const log = std.log.scoped(.rate_limit);

const labels_allowed: []const Label = &.{.{ .name = "outcome", .value = "allowed" }};
const labels_rejected: []const Label = &.{.{ .name = "outcome", .value = "rejected" }};

fn nowMs(io: Io) i64 {
    const now: utils.Now = .{ .io = io };
    return now.toMilliSeconds();
}

const TokenBucket = struct {
    tokens: f64,
    last_refill: i64,
    capacity: f64,
    refill_rate: f64,

    fn init(capacity: f64, refill_rate: f64, now: i64) TokenBucket {
        return .{
            .tokens = capacity,
            .last_refill = now,
            .capacity = capacity,
            .refill_rate = refill_rate,
        };
    }

    fn tryConsume(self: *TokenBucket, now: i64) bool {
        const elapsed: f64 = @floatFromInt(now - self.last_refill);
        self.tokens = @min(self.capacity, self.tokens + elapsed * self.refill_rate);
        self.last_refill = now;

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

pub const UnknownIpPolicy = enum {
    share_bucket,
    reject,
    allow,
};

pub const RateLimiter = struct {
    buckets: std.StringHashMapUnmanaged(TokenBucket),
    mutex: Io.Mutex,
    allocator: Allocator,
    io: Io,
    capacity: f64,
    refill_rate: f64,
    cleanup_interval_ms: i64,
    entry_timeout_ms: i64,
    last_cleanup: i64,
    unknown_policy: UnknownIpPolicy,
    metrics: Metrics,

    pub const Config = struct {
        requests_per_minute: u32 = 100,
        cleanup_interval_ms: i64 = 60_000,
        entry_timeout_ms: i64 = 300_000,
        unknown_policy: UnknownIpPolicy = .reject,
        metrics: Metrics = .{},
    };

    pub fn init(allocator: Allocator, io: Io, config: Config) RateLimiter {
        const rpm: f64 = @floatFromInt(config.requests_per_minute);
        return .{
            .buckets = .empty,
            .mutex = Io.Mutex.init,
            .allocator = allocator,
            .io = io,
            .capacity = rpm,
            .refill_rate = rpm / 60_000.0,
            .cleanup_interval_ms = config.cleanup_interval_ms,
            .entry_timeout_ms = config.entry_timeout_ms,
            .last_cleanup = 0,
            .unknown_policy = config.unknown_policy,
            .metrics = config.metrics,
        };
    }

    pub fn isAllowed(self: *RateLimiter, ip: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = nowMs(self.io);

        if (now - self.last_cleanup > self.cleanup_interval_ms) {
            self.cleanupLocked(now);
            self.last_cleanup = now;
        }

        const result = self.buckets.getOrPut(self.allocator, ip) catch {
            log.err("rate_limit: bucket alloc failed, allowing request", .{});
            return true;
        };
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, ip) catch {
                log.err("rate_limit: ip dupe failed, allowing request", .{});
                _ = self.buckets.remove(ip);
                return true;
            };
            result.value_ptr.* = TokenBucket.init(self.capacity, self.refill_rate, now);
        }
        const allowed = result.value_ptr.tryConsume(now);
        self.metrics.counter(
            "rate_limit_decisions_total",
            1,
            if (allowed) labels_allowed else labels_rejected,
        );
        return allowed;
    }

    fn cleanupLocked(self: *RateLimiter, now: i64) void {
        var it = self.buckets.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.last_refill > self.entry_timeout_ms) {
                self.allocator.free(entry.key_ptr.*);
                self.buckets.removeByPtr(entry.key_ptr);
            }
        }
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.buckets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.buckets.deinit(self.allocator);
    }
};

pub const RateLimitMiddleware = struct {
    limiter: *RateLimiter,

    pub fn init(limiter: *RateLimiter) RateLimitMiddleware {
        return .{ .limiter = limiter };
    }

    pub fn execute(self: *RateLimitMiddleware, _: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        const ip_opt = extractClientIp(req);
        const ip = ip_opt orelse switch (self.limiter.unknown_policy) {
            .allow => return .next,
            .reject => {
                res.status = .too_many_requests;
                try res.setHeader("Content-Type", "text/plain");
                try res.write("Client IP not identifiable");
                return .stop;
            },
            .share_bucket => "unknown",
        };

        if (!self.limiter.isAllowed(ip)) {
            res.status = .too_many_requests;
            try res.setHeader("Retry-After", "60");
            try res.setHeader("Content-Type", "text/plain");
            try res.write("Rate limit exceeded");
            return .stop;
        }
        return .next;
    }

    pub fn middleware(self: *RateLimitMiddleware) Middleware {
        return Middleware.from(RateLimitMiddleware, self);
    }
};

fn extractClientIp(req: *const Request) ?[]const u8 {
    if (req.getHeader("X-Forwarded-For")) |xff| {
        if (std.mem.indexOfScalar(u8, xff, ',')) |comma| {
            return std.mem.trim(u8, xff[0..comma], " ");
        }
        return std.mem.trim(u8, xff, " ");
    }
    if (req.getHeader("X-Real-IP")) |xrip| return xrip;
    return null;
}


const testing = std.testing;

test "RateLimiter: allows up to capacity then rejects" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var limiter = RateLimiter.init(testing.allocator, io, .{
        .requests_per_minute = 3,
    });
    defer limiter.deinit();

    try testing.expect(limiter.isAllowed("1.2.3.4"));
    try testing.expect(limiter.isAllowed("1.2.3.4"));
    try testing.expect(limiter.isAllowed("1.2.3.4"));
    try testing.expect(!limiter.isAllowed("1.2.3.4"));
}

test "RateLimiter: buckets are per-IP" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var limiter = RateLimiter.init(testing.allocator, io, .{
        .requests_per_minute = 1,
    });
    defer limiter.deinit();

    try testing.expect(limiter.isAllowed("1.2.3.4"));
    try testing.expect(!limiter.isAllowed("1.2.3.4"));
    try testing.expect(limiter.isAllowed("5.6.7.8"));
}

test "RateLimiter: metrics counter recorded per decision" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sink = metrics_mod.RecordingSink.init(testing.allocator);
    defer sink.deinit();

    var limiter = RateLimiter.init(testing.allocator, io, .{
        .requests_per_minute = 1,
        .metrics = sink.interface(),
    });
    defer limiter.deinit();

    _ = limiter.isAllowed("1.1.1.1");
    _ = limiter.isAllowed("1.1.1.1");

    var allowed: u64 = 0;
    var rejected: u64 = 0;
    for (sink.ops.items) |op| {
        switch (op) {
            .counter => |c| {
                if (!std.mem.eql(u8, c.name, "rate_limit_decisions_total")) continue;
                for (c.labels) |lbl| {
                    if (std.mem.eql(u8, lbl.name, "outcome")) {
                        if (std.mem.eql(u8, lbl.value, "allowed")) allowed += c.n;
                        if (std.mem.eql(u8, lbl.value, "rejected")) rejected += c.n;
                    }
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u64, 1), allowed);
    try testing.expectEqual(@as(u64, 1), rejected);
}
