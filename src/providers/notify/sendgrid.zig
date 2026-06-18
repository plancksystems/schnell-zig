
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const schnell = @import("schnell");
const Client = schnell.Client;
const provider = @import("provider.zig");
const NotificationProvider = provider.NotificationProvider;
const Notification = provider.Notification;
const SendResult = provider.SendResult;

pub const SendGridConfig = struct {
    api_key: []const u8,
    default_from: []const u8 = "noreply@example.com",
};

pub const SendGridProvider = struct {
    config: SendGridConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SendGridConfig) SendGridProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn notificationProvider(self: *SendGridProvider) NotificationProvider {
        return NotificationProvider.from(SendGridProvider, self);
    }

    pub fn send(self: *SendGridProvider, allocator: Allocator, io: Io, notification: Notification) !SendResult {
        const from = notification.from orelse self.config.default_from;

        const body = try std.fmt.allocPrint(allocator,
            \\{{"personalizations":[{{"to":[{{"email":"{s}"}}]}}],"from":{{"email":"{s}"}},"subject":"{s}","content":[{{"type":"text/plain","value":"{s}"}}]}}
        , .{ notification.to, from, notification.title, notification.body });
        defer allocator.free(body);

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.api_key});
        defer allocator.free(auth_header);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://api.sendgrid.com/v3/mail/send",
            .headers = &.{
                .{ "Content-Type", "application/json" },
                .{ "Authorization", auth_header },
            },
            .body = body,
        });
        defer resp.deinit();

        const accepted = resp.status >= 200 and resp.status < 300;
        return SendResult{
            .message_id = if (resp.header("X-Message-Id")) |mid|
                try allocator.dupe(u8, mid)
            else
                try allocator.dupe(u8, ""),
            .accepted = accepted,
            .error_message = if (!accepted) try allocator.dupe(u8, resp.body) else null,
            .raw_response = try allocator.dupe(u8, resp.body),
        };
    }
};
