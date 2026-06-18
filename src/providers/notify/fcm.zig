
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const schnell = @import("schnell");
const Client = schnell.Client;
const util = @import("../provider_util.zig");
const provider = @import("provider.zig");
const NotificationProvider = provider.NotificationProvider;
const Notification = provider.Notification;
const SendResult = provider.SendResult;

pub const FcmConfig = struct {
    project_id: []const u8,
    access_token: []const u8,
};

pub const FcmProvider = struct {
    config: FcmConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: FcmConfig) FcmProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn notificationProvider(self: *FcmProvider) NotificationProvider {
        return NotificationProvider.from(FcmProvider, self);
    }

    pub fn send(self: *FcmProvider, allocator: Allocator, io: Io, notification: Notification) !SendResult {
        
        const data_field = if (notification.data) |d|
            try std.fmt.allocPrint(allocator, ",\"data\":{s}", .{d})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(data_field);

        const priority_str: []const u8 = switch (notification.priority) {
            .high => "HIGH",
            .normal => "NORMAL",
        };

        const body = try std.fmt.allocPrint(allocator,
            \\{{"message":{{"token":"{s}","notification":{{"title":"{s}","body":"{s}"}},"android":{{"priority":"{s}"}}{s}}}}}
        , .{ notification.to, notification.title, notification.body, priority_str, data_field });
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator,
            "https://fcm.googleapis.com/v1/projects/{s}/messages:send",
            .{self.config.project_id},
        );
        defer allocator.free(url);

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.access_token});
        defer allocator.free(auth_header);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = url,
            .headers = &.{
                .{ "Content-Type", "application/json" },
                .{ "Authorization", auth_header },
            },
            .body = body,
        });
        defer resp.deinit();

        const accepted = resp.status >= 200 and resp.status < 300;

        var message_id: []const u8 = "";
        if (accepted) {
            if (util.extractJsonField(resp.body, "name")) |name| {
                message_id = try allocator.dupe(u8, name);
            }
        }

        return SendResult{
            .message_id = if (message_id.len > 0) message_id else try allocator.dupe(u8, ""),
            .accepted = accepted,
            .error_message = if (!accepted) try allocator.dupe(u8, resp.body) else null,
            .raw_response = try allocator.dupe(u8, resp.body),
        };
    }
};
