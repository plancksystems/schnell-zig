
const std = @import("std");

pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

pub const Metrics = struct {
    ptr: ?*anyopaque = null,
    counterFn: *const fn (ptr: ?*anyopaque, name: []const u8, n: u64, labels: []const Label) void = noopCounter,
    gaugeFn: *const fn (ptr: ?*anyopaque, name: []const u8, value: i64, labels: []const Label) void = noopGauge,
    histogramFn: *const fn (ptr: ?*anyopaque, name: []const u8, value: f64, labels: []const Label) void = noopHistogram,

    pub fn counter(self: Metrics, name: []const u8, n: u64, labels: []const Label) void {
        self.counterFn(self.ptr, name, n, labels);
    }

    pub fn gauge(self: Metrics, name: []const u8, value: i64, labels: []const Label) void {
        self.gaugeFn(self.ptr, name, value, labels);
    }

    pub fn histogram(self: Metrics, name: []const u8, value: f64, labels: []const Label) void {
        self.histogramFn(self.ptr, name, value, labels);
    }

    pub fn noop() Metrics {
        return .{};
    }
};

fn noopCounter(_: ?*anyopaque, _: []const u8, _: u64, _: []const Label) void {}
fn noopGauge(_: ?*anyopaque, _: []const u8, _: i64, _: []const Label) void {}
fn noopHistogram(_: ?*anyopaque, _: []const u8, _: f64, _: []const Label) void {}

pub const RecordingSink = struct {
    pub const Op = union(enum) {
        counter: struct { name: []const u8, n: u64, labels: []const Label },
        gauge: struct { name: []const u8, value: i64, labels: []const Label },
        histogram: struct { name: []const u8, value: f64, labels: []const Label },
    };

    allocator: std.mem.Allocator,
    ops: std.ArrayList(Op) = .empty,

    pub fn init(allocator: std.mem.Allocator) RecordingSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecordingSink) void {
        self.ops.deinit(self.allocator);
    }

    pub fn interface(self: *RecordingSink) Metrics {
        return .{
            .ptr = @ptrCast(self),
            .counterFn = counterAdapter,
            .gaugeFn = gaugeAdapter,
            .histogramFn = histogramAdapter,
        };
    }

    fn counterAdapter(ptr: ?*anyopaque, name: []const u8, n: u64, labels: []const Label) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        self.ops.append(self.allocator, .{ .counter = .{ .name = name, .n = n, .labels = labels } }) catch {};
    }

    fn gaugeAdapter(ptr: ?*anyopaque, name: []const u8, value: i64, labels: []const Label) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        self.ops.append(self.allocator, .{ .gauge = .{ .name = name, .value = value, .labels = labels } }) catch {};
    }

    fn histogramAdapter(ptr: ?*anyopaque, name: []const u8, value: f64, labels: []const Label) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        self.ops.append(self.allocator, .{ .histogram = .{ .name = name, .value = value, .labels = labels } }) catch {};
    }
};


test "Metrics: default noop is callable and discards" {
    const m: Metrics = .{};
    m.counter("x", 1, &.{});
    m.gauge("x", 1, &.{});
    m.histogram("x", 1.0, &.{});
}

test "RecordingSink: captures counter, gauge, histogram ops" {
    var sink = RecordingSink.init(std.testing.allocator);
    defer sink.deinit();
    const m = sink.interface();

    const labels = [_]Label{.{ .name = "topic", .value = "orders" }};
    m.counter("sse_events_published_total", 1, &labels);
    m.gauge("sse_subscribers", 2, &labels);
    m.histogram("sse_publish_latency_ms", 1.25, &labels);

    try std.testing.expectEqual(@as(usize, 3), sink.ops.items.len);
    switch (sink.ops.items[0]) {
        .counter => |c| {
            try std.testing.expectEqualStrings("sse_events_published_total", c.name);
            try std.testing.expectEqual(@as(u64, 1), c.n);
        },
        else => unreachable,
    }
    switch (sink.ops.items[1]) {
        .gauge => |g| {
            try std.testing.expectEqual(@as(i64, 2), g.value);
        },
        else => unreachable,
    }
    switch (sink.ops.items[2]) {
        .histogram => |h| {
            try std.testing.expectEqual(@as(f64, 1.25), h.value);
        },
        else => unreachable,
    }
}
