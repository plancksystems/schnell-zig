
const std = @import("std");
const Allocator = std.mem.Allocator;
const schnell = @import("schnell");
const Request = schnell.Request;
const Response = schnell.Response;
const Middleware = schnell.Middleware;
const jwt = @import("jwt.zig");
const sys = @import("sys.zig");
const web_log = @import("log.zig");

pub const JwtAuthMiddleware = struct {
    secret: []const u8,
    skip_paths: []const []const u8,
    now_unix_s: *const fn () i64 = defaultNow,

    fn defaultNow() i64 {
        return sys.nowUnixSeconds();
    }

    pub fn init(secret: []const u8, skip_paths: []const []const u8) JwtAuthMiddleware {
        return .{ .secret = secret, .skip_paths = skip_paths };
    }

    pub fn execute(self: *JwtAuthMiddleware, allocator: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        for (self.skip_paths) |p| {
            if (std.mem.eql(u8, req.path, p)) return .next;
            if (p.len > 0 and p[p.len - 1] == '*' and std.mem.startsWith(u8, req.path, p[0 .. p.len - 1])) {
                return .next;
            }
        }

        var token: []const u8 = "";
        if (req.getHeader("Authorization") orelse req.getHeader("authorization")) |hdr| {
            if (hdr.len >= 7 and std.ascii.eqlIgnoreCase(hdr[0..7], "bearer ")) {
                token = std.mem.trim(u8, hdr[7..], " \t");
            }
        }
        if (token.len == 0) {
            if (req.getCookie("pizzaqsr_jwt")) |c| token = c;
        }
        if (token.len == 0) {
            return self.reject(allocator, res, "missing credentials");
        }

        const claims = jwt.verify(allocator, self.secret, token, self.now_unix_s()) catch |err| {
            web_log.logFmt(.warn, "auth: token rejected ({s}) for {s} {s}", .{ @errorName(err), req.method.toString(), req.path });
            const msg: []const u8 = switch (err) {
                error.Expired => "token expired",
                error.BadSignature => "invalid signature",
                error.UnsupportedAlgorithm, error.BadHeader => "unsupported token format",
                error.InvalidFormat, error.MalformedJson => "malformed token",
                error.OutOfMemory => "internal error",
            };
            return self.reject(allocator, res, msg);
        };

        try req.setLocal("user_id", claims.sub);
        try req.setLocal("email", claims.email);
        try req.setLocal("display_name", claims.name);
        return .next;
    }

    fn reject(_: *JwtAuthMiddleware, allocator: Allocator, res: *Response, message: []const u8) !Middleware.Action {
        res.status = .unauthorized;
        try res.setHeader("WWW-Authenticate", "Bearer realm=\"planck\"");
        try res.setHeader("Content-Type", "application/json");
        const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        try res.write(body);
        return .stop;
    }

    pub fn middleware(self: *JwtAuthMiddleware) Middleware {
        return Middleware.from(JwtAuthMiddleware, self);
    }
};
