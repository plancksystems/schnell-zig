
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const planck = @import("planck");
const metrics_mod = @import("../metrics.zig");
const Metrics = metrics_mod.Metrics;
const Label = metrics_mod.Label;

const log = std.log.scoped(.systemdb_metrics);

const Sample = struct {
    name: []const u8,
    value: f64,
    timestamp_ms: i64,
};

pub const SystemDbMetricsSink = struct {
    allocator: Allocator,
    io: Io,
    client: *planck.Client,
    store_name: []const u8,
    flush_interval_ms: u64,
    buffer: std.ArrayList(Sample),
    mutex: Io.Mutex,
    flush_group: Io.Group,
    stopping: std.atomic.Value(bool),

    pub const Config = struct {
        store_name: []const u8 = "_metrics",
        flush_interval_ms: u64 = 10_000,
    };

    pub fn init(allocator: Allocator, io: Io, client: *planck.Client, config: Config) SystemDbMetricsSink {
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .store_name = config.store_name,
            .flush_interval_ms = config.flush_interval_ms,
            .buffer = .empty,
            .mutex = Io.Mutex.init,
            .flush_group = .init,
            .stopping = std.atomic.Value(bool).init(false),
        };
    }

    
    pub fn start(self: *SystemDbMetricsSink) void {
        if (self.flush_interval_ms == 0) return;
        self.flush_group.async(self.io, flushLoop, .{self});
        log.info("systemdb metrics sink started (flush every {d}ms)", .{self.flush_interval_ms});
    }

    pub fn deinit(self: *SystemDbMetricsSink) void {
        self.stopping.store(true, .release);
        self.flush_group.cancel(self.io);
        self.buffer.deinit(self.allocator);
    }

    pub fn interface(self: *SystemDbMetricsSink) Metrics {
        return .{
            .ptr = @ptrCast(self),
            .counterFn = counterAdapter,
            .gaugeFn = gaugeAdapter,
            .histogramFn = histogramAdapter,
        };
    }

    fn counterAdapter(ptr: ?*anyopaque, name: []const u8, n: u64, _: []const Label) void {
        const self: *SystemDbMetricsSink = @ptrCast(@alignCast(ptr.?));
        self.record(name, @floatFromInt(n));
    }

    fn gaugeAdapter(ptr: ?*anyopaque, name: []const u8, value: i64, _: []const Label) void {
        const self: *SystemDbMetricsSink = @ptrCast(@alignCast(ptr.?));
        self.record(name, @floatFromInt(value));
    }

    fn histogramAdapter(ptr: ?*anyopaque, name: []const u8, value: f64, _: []const Label) void {
        const self: *SystemDbMetricsSink = @ptrCast(@alignCast(ptr.?));
        self.record(name, value);
    }

    fn record(self: *SystemDbMetricsSink, name: []const u8, value: f64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = Io.Clock.now(.real, self.io).toMilliseconds();
        self.buffer.append(self.allocator, .{
            .name = name,
            .value = value,
            .timestamp_ms = now,
        }) catch {};
    }

    fn flushLoop(self: *SystemDbMetricsSink) Io.Cancelable!void {
        while (!self.stopping.load(.acquire)) {
            self.io.sleep(
                Io.Duration.fromMilliseconds(@intCast(self.flush_interval_ms)),
                .awake,
            ) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            self.flushOnce() catch |err| {
                log.warn("systemdb metrics flush failed: {}", .{err});
            };
        }
    }

    fn flushOnce(self: *SystemDbMetricsSink) !void {
        
        var to_flush: std.ArrayList(Sample) = .empty;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            to_flush = self.buffer;
            self.buffer = .empty;
        }
        defer to_flush.deinit(self.allocator);

        if (to_flush.items.len == 0) return;

        
        for (to_flush.items) |sample| {
            const MetricDoc = struct {
                name: []const u8,
                value: f64,
                timestamp_ms: i64,
            };
            const doc: MetricDoc = .{
                .name = sample.name,
                .value = sample.value,
                .timestamp_ms = sample.timestamp_ms,
            };
            var q = planck.Query.initWithAllocator(self.client, self.allocator);
            defer q.deinit();
            var resp = try (try q.store(self.store_name).create(doc)).run();
            defer resp.deinit();
        }

        log.info("systemdb metrics: flushed {d} samples", .{to_flush.items.len});
    }
};
