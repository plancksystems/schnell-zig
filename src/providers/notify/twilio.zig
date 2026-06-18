
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

pub const TwilioConfig = struct {
    account_sid: []const u8,
    auth_token: []const u8,
    from_number: []const u8,
};

pub const TwilioProvider = struct {
    config: TwilioConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: TwilioConfig) TwilioProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn notificationProvider(self: *TwilioProvider) NotificationProvider {
        return NotificationProvider.from(TwilioProvider, self);
    }

    pub fn send(self: *TwilioProvider, allocator: Allocator, io: Io, notification: Notification) !SendResult {
        const from = notification.from orelse self.config.from_number;

        const body = try std.fmt.allocPrint(allocator,
            "To={s}&From={s}&Body={s}",
            .{ notification.to, from, notification.body },
        );
        defer allocator.free(body);

        const auth_header = try util.basicAuth(allocator, self.config.account_sid, self.config.auth_token);
        defer allocator.free(auth_header);

        const url = try std.fmt.allocPrint(allocator,
            "https://api.twilio.com/2010-04-01/Accounts/{s}/Messages.json",
            .{self.config.account_sid},
        );
        defer allocator.free(url);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = url,
            .headers = &.{
                .{ "Content-Type", "application/x-www-form-urlencoded" },
                .{ "Authorization", auth_header },
            },
            .body = body,
        });
        defer resp.deinit();

        const accepted = resp.status >= 200 and resp.status < 300;

        var message_id: []const u8 = "";
        if (accepted) {
            if (util.extractJsonField(resp.body, "sid")) |sid| {
                message_id = try allocator.dupe(u8, sid);
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
