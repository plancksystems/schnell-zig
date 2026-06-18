
const std = @import("std");
const mem = std.mem;
const Status = @import("status.zig").Status;
const Cookie = @import("cookie.zig").Cookie;
const Request = @import("request.zig").Request;

pub const Response = struct {
    allocator: mem.Allocator,
    status: Status = .ok,
    headers: std.ArrayList(Header),
    body: std.ArrayList(u8),
    streaming_handler: ?*const fn (?*anyopaque, mem.Allocator, *const Request, *std.Io.Writer) anyerror!void = null,
    streaming_ctx: ?*anyopaque = null,

    const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .headers = .empty,
            .body = .empty,
        };
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (containsCrlf(name) or containsCrlf(value)) return error.HeaderInjection;

        for (self.headers.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                h.value = value;
                return;
            }
        }
        try self.headers.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn setCookie(self: *Response, cookie: Cookie) !void {
        var buf: [1024]u8 = undefined;
        const cookie_str = try formatSetCookie(&buf, cookie);
        const owned = try self.allocator.dupe(u8, cookie_str);
        try self.appendHeader("Set-Cookie", owned);
    }

    pub fn appendHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (containsCrlf(name) or containsCrlf(value)) return error.HeaderInjection;
        try self.headers.append(self.allocator, .{ .name = name, .value = value });
    }

    fn containsCrlf(s: []const u8) bool {
        return mem.indexOfScalar(u8, s, '\r') != null or
            mem.indexOfScalar(u8, s, '\n') != null;
    }

    pub fn html(self: *Response, data: []const u8) !void {
        try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.body.appendSlice(self.allocator, data);
    }

    pub fn json(self: *Response, data: []const u8) !void {
        try self.setHeader("Content-Type", "application/json");
        try self.body.appendSlice(self.allocator, data);
    }

    pub fn write(self: *Response, data: []const u8) !void {
        try self.body.appendSlice(self.allocator, data);
    }

    pub fn toBytes(self: *Response, buf: []u8) ![]const u8 {
        var pos: usize = 0;

        const status_line = try std.fmt.bufPrint(buf[pos..], "HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(self.status), self.status.toString(),
        });
        pos += status_line.len;

        const cl = try std.fmt.bufPrint(buf[pos..], "Content-Length: {d}\r\n", .{self.body.items.len});
        pos += cl.len;

        for (self.headers.items) |h| {
            const header = try std.fmt.bufPrint(buf[pos..], "{s}: {s}\r\n", .{ h.name, h.value });
            pos += header.len;
        }

        if (pos + 2 > buf.len) return error.NoSpaceLeft;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        if (pos + self.body.items.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..self.body.items.len], self.body.items);
        pos += self.body.items.len;

        return buf[0..pos];
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }

    fn formatSetCookie(buf: []u8, cookie: Cookie) ![]const u8 {
        var pos: usize = 0;

        {
            const w = try std.fmt.bufPrint(buf[pos..], "{s}={s}", .{ cookie.name, cookie.value });
            pos += w.len;
        }

        if (cookie.path) |p| {
            const w = try std.fmt.bufPrint(buf[pos..], "; Path={s}", .{p});
            pos += w.len;
        }
        if (cookie.domain) |d| {
            const w = try std.fmt.bufPrint(buf[pos..], "; Domain={s}", .{d});
            pos += w.len;
        }
        if (cookie.max_age) |age| {
            const w = try std.fmt.bufPrint(buf[pos..], "; Max-Age={d}", .{age});
            pos += w.len;
        }
        if (cookie.secure) {
            const sec = "; Secure";
            @memcpy(buf[pos..][0..sec.len], sec);
            pos += sec.len;
        }
        if (cookie.http_only) {
            const ho = "; HttpOnly";
            @memcpy(buf[pos..][0..ho.len], ho);
            pos += ho.len;
        }

        if (cookie.same_site) |ss| {
            const s = switch (ss) {
                .Strict => "Strict",
                .Lax => "Lax",
                .None => "None",
            };
            const w = try std.fmt.bufPrint(buf[pos..], "; SameSite={s}", .{s});
            pos += w.len;
        }

        return buf[0..pos];
    }
};
