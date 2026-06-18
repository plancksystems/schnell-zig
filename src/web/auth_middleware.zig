
const std = @import("std");
const Allocator = std.mem.Allocator;
const schnell = @import("schnell");
const Request = schnell.Request;
const Response = schnell.Response;
const Middleware = schnell.Middleware;
const TokenStore = @import("token_store.zig").TokenStore;

pub const TokenAuthMiddleware = struct {
    token_store: *TokenStore,
    skip_paths: []const []const u8,
    bind_token_to_ip: bool = false,
    host_request_fn: ?*const fn ([*]const u8, u32, [*]u8, u32) u32 = null,
    fallback_buf: []u8 = &.{},

    pub fn init(
        token_store: *TokenStore,
        skip_paths: []const []const u8
    ) TokenAuthMiddleware {
        return .{
            .token_store = token_store,
            .skip_paths = skip_paths,
        };
    }

    pub fn execute(self: *TokenAuthMiddleware, allocator: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        for (self.skip_paths) |path| {
            if (std.mem.eql(u8, req.path, path)) return .next;
            if (path.len > 0 and path[path.len - 1] == '*') {
                if (std.mem.startsWith(u8, req.path, path[0 .. path.len - 1])) return .next;
            }
        }

        const auth_header = req.getHeader("Authorization") orelse
            req.getHeader("authorization") orelse {
            return self.reject(allocator, res, "Missing Authorization header");
        };

        if (auth_header.len < 7 or !std.ascii.eqlIgnoreCase(auth_header[0..7], "bearer ")) {
            return self.reject(allocator, res, "Invalid Authorization format");
        }

        const token = std.mem.trim(u8, auth_header[7..], " \t");
        const client_ip = req.getHeader("X-Forwarded-For") orelse
            req.getHeader("X-Real-IP");

        if (self.token_store.validate(token, client_ip, self.bind_token_to_ip)) |entry| {
            try res.setHeader("X-Auth-Uid", entry.uid);
            try res.setHeader("X-Auth-Role", entry.role);
            return .next;
        }

        if (self.host_request_fn) |host_request| {
            if (self.tryDbFallback(allocator, host_request, token, client_ip)) |entry| {
                try res.setHeader("X-Auth-Uid", entry.uid);
                try res.setHeader("X-Auth-Role", entry.role);
                return .next;
            }
        }

        return self.reject(allocator, res, "Invalid or expired token");
    }

    fn tryDbFallback(
        self: *TokenAuthMiddleware,
        allocator: Allocator,
        host_request: *const fn ([*]const u8, u32, [*]u8, u32) u32,
        token: []const u8,
        client_ip: ?[]const u8
    ) ?TokenStore.TokenEntry {
        _ = client_ip;
        const query = std.fmt.allocPrint(
            allocator,
            "system.tokens\x00{{\"token\":{{\"$eq\":\"{s}\"}}}}",
            .{token},
        ) catch return null;
        defer allocator.free(query);

        var buf: [4096]u8 = undefined;
        const len = host_request(query.ptr, @intCast(query.len), &buf, buf.len);
        if (len == 0) return null;

        const response_data = buf[0..len];
        self.token_store.save(response_data);

        return self.token_store.validate(token, null, false);
    }

    fn reject(_: *TokenAuthMiddleware, allocator: Allocator, res: *Response, message: []const u8) !Middleware.Action {
        res.status = .unauthorized;
        const hdr = try std.fmt.allocPrint(allocator, "Bearer realm=\"planck\"", .{});
        try res.setHeader("WWW-Authenticate", hdr);
        try res.setHeader("Content-Type", "application/json");
        const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        try res.write(body);
        return .stop;
    }

    pub fn middleware(self: *TokenAuthMiddleware) Middleware {
        return Middleware.from(TokenAuthMiddleware, self);
    }
};
