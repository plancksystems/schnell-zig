
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const provider = @import("provider.zig");
const NotificationProvider = provider.NotificationProvider;
const Notification = provider.Notification;
const SendResult = provider.SendResult;

const log = std.log.scoped(.apns);

pub const ApnsEnvironment = enum {
    production,
    sandbox,

    pub fn baseUrl(self: ApnsEnvironment) []const u8 {
        return switch (self) {
            .production => "https://api.push.apple.com",
            .sandbox => "https://api.sandbox.push.apple.com",
        };
    }
};

pub const ApnsConfig = struct {
    key_id: []const u8,
    team_id: []const u8,
    bundle_id: []const u8,
    private_key_path: []const u8 = "",
    environment: ApnsEnvironment = .sandbox,
};

pub const ApnsProvider = struct {
    config: ApnsConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: ApnsConfig) ApnsProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn notificationProvider(self: *ApnsProvider) NotificationProvider {
        return NotificationProvider.from(ApnsProvider, self);
    }

    pub fn send(_: *ApnsProvider, _: Allocator, _: Io, _: Notification) !SendResult {
        log.err("apns: HTTP/2 not supported by schnell.Client; APNs requires HTTP/2", .{});
        return error.Http2NotSupported;
    }
};
