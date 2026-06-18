
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Channel = enum {
    push,
    email,
    sms,

    pub fn toString(self: Channel) []const u8 {
        return switch (self) {
            .push => "push",
            .email => "email",
            .sms => "sms",
        };
    }
};

pub const Priority = enum { normal, high };

pub const Notification = struct {
    to: []const u8,
    title: []const u8,
    body: []const u8,
    data: ?[]const u8 = null,
    channel: Channel = .push,
    priority: Priority = .normal,
    from: ?[]const u8 = null,
};

pub const SendResult = struct {
    message_id: []const u8,
    accepted: bool,
    error_message: ?[]const u8 = null,
    raw_response: []const u8 = "",
};

pub const NotificationProvider = struct {
    ptr: *anyopaque,

    sendFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        notification: Notification,
    ) anyerror!SendResult,

    sendBatchFn: ?*const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        notifications: []const Notification,
    ) anyerror![]SendResult = null,

    pub fn send(self: NotificationProvider, allocator: Allocator, io: Io, notification: Notification) !SendResult {
        return self.sendFn(self.ptr, allocator, io, notification);
    }

    pub fn sendBatch(self: NotificationProvider, allocator: Allocator, io: Io, notifications: []const Notification) ![]SendResult {
        if (self.sendBatchFn) |f| return f(self.ptr, allocator, io, notifications);
        const results = try allocator.alloc(SendResult, notifications.len);
        for (notifications, 0..) |n, i| {
            results[i] = try self.send(allocator, io, n);
        }
        return results;
    }

    pub fn from(comptime T: type, ptr: *T) NotificationProvider {
        const has_batch = @hasDecl(T, "sendBatch");
        return .{
            .ptr = @ptrCast(ptr),
            .sendFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, n: Notification) anyerror!SendResult {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.send(alloc, io, n);
                }
            }.f,
            .sendBatchFn = if (has_batch) struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, ns: []const Notification) anyerror![]SendResult {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.sendBatch(alloc, io, ns);
                }
            }.f else null,
        };
    }
};
