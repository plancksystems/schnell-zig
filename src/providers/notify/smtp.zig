
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const tls = @import("tls");

const provider = @import("provider.zig");
const NotificationProvider = provider.NotificationProvider;
const Notification = provider.Notification;
const SendResult = provider.SendResult;

const log = std.log.scoped(.smtp);

pub const SmtpConfig = struct {
    host: []const u8,
    port: u16 = 587,
    username: []const u8,
    password: []const u8,
    default_from: []const u8 = "noreply@example.com",
    direct_tls: bool = false,
};

pub const SmtpProvider = struct {
    config: SmtpConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SmtpConfig) SmtpProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn notificationProvider(self: *SmtpProvider) NotificationProvider {
        return NotificationProvider.from(SmtpProvider, self);
    }

    pub fn send(self: *SmtpProvider, allocator: Allocator, io: Io, notification: Notification) !SendResult {
        const from = notification.from orelse self.config.default_from;
        const cfg = self.config;

        const address = try resolveHost(io, cfg.host, cfg.port);
        var stream = try address.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);

        try expectReply(&reader.interface, "220");

        try sendLine(&writer.interface, allocator, "EHLO localhost");
        try expectReply(&reader.interface, "250");

        const auth_plain = try buildAuthPlain(allocator, cfg.username, cfg.password);
        defer allocator.free(auth_plain);
        const auth_cmd = try std.fmt.allocPrint(allocator, "AUTH PLAIN {s}", .{auth_plain});
        defer allocator.free(auth_cmd);
        try sendLine(&writer.interface, allocator, auth_cmd);
        try expectReply(&reader.interface, "235");

        const mail_from = try std.fmt.allocPrint(allocator, "MAIL FROM:<{s}>", .{from});
        defer allocator.free(mail_from);
        try sendLine(&writer.interface, allocator, mail_from);
        try expectReply(&reader.interface, "250");

        const rcpt_to = try std.fmt.allocPrint(allocator, "RCPT TO:<{s}>", .{notification.to});
        defer allocator.free(rcpt_to);
        try sendLine(&writer.interface, allocator, rcpt_to);
        try expectReply(&reader.interface, "250");

        try sendLine(&writer.interface, allocator, "DATA");
        try expectReply(&reader.interface, "354");

        const msg = try std.fmt.allocPrint(allocator,
            "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\n\r\n{s}\r\n.",
            .{ from, notification.to, notification.title, notification.body },
        );
        defer allocator.free(msg);
        try sendLine(&writer.interface, allocator, msg);
        try expectReply(&reader.interface, "250");

        try sendLine(&writer.interface, allocator, "QUIT");

        return SendResult{
            .message_id = try allocator.dupe(u8, ""),
            .accepted = true,
        };
    }

    fn sendLine(w: *std.Io.Writer, allocator: Allocator, line: []const u8) !void {
        _ = allocator;
        try w.writeAll(line);
        try w.writeAll("\r\n");
        try w.flush();
    }

    fn expectReply(r: *std.Io.Reader, expected_code: []const u8) !void {
        var line_buf: [512]u8 = undefined;
        const n = try r.readSliceShort(&line_buf);
        if (n < expected_code.len) return error.SmtpError;
        if (!std.mem.startsWith(u8, line_buf[0..n], expected_code)) {
            log.warn("smtp: expected {s}, got: {s}", .{ expected_code, line_buf[0..@min(n, 80)] });
            return error.SmtpError;
        }
    }

    fn buildAuthPlain(allocator: Allocator, username: []const u8, password: []const u8) ![]const u8 {
        const plain_len = 1 + username.len + 1 + password.len;
        const plain = try allocator.alloc(u8, plain_len);
        defer allocator.free(plain);
        plain[0] = 0;
        @memcpy(plain[1..][0..username.len], username);
        plain[1 + username.len] = 0;
        @memcpy(plain[2 + username.len ..][0..password.len], password);

        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(plain_len));
        _ = std.base64.standard.Encoder.encode(encoded, plain);
        return encoded;
    }

    fn resolveHost(io: Io, host: []const u8, port: u16) !net.IpAddress {
        if (net.IpAddress.parseIp4(host, port)) |addr| return addr else |_| {}
        const HostName = net.HostName;
        const hn = HostName.init(host) catch return error.InvalidHost;
        var backing: [16]HostName.LookupResult = undefined;
        var resolved: Io.Queue(HostName.LookupResult) = .init(&backing);
        var name_buf: [HostName.max_len]u8 = undefined;
        hn.lookup(io, &resolved, .{ .port = port, .canonical_name_buffer = &name_buf }) catch return error.HostResolutionFailed;
        while (resolved.getOne(io)) |result| {
            switch (result) {
                .address => |addr| return addr,
                .canonical_name => continue,
            }
        } else |err| switch (err) {
            error.Closed, error.Canceled => return error.HostResolutionFailed,
        }
        return error.HostResolutionFailed;
    }
};
