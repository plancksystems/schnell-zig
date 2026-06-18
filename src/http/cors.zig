
const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Middleware = @import("middleware.zig").Middleware;

pub const CorsMiddleware = struct {
    config: Config,

    pub const Config = struct {
        allow_origin: []const u8 = "*",
        allow_origins: []const []const u8 = &.{},
        allow_methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS",
        allow_headers: []const u8 = "Content-Type, Authorization, HX-Request, HX-Target, HX-Trigger",
        max_age: []const u8 = "86400",
        allow_credentials: bool = false,
    };

    pub fn init(config: Config) CorsMiddleware {
        if (config.allow_credentials) {
            if (std.mem.eql(u8, config.allow_origin, "*") and config.allow_origins.len == 0) {
                @panic("CORS: allow_credentials=true is incompatible with allow_origin=\"*\". Use an explicit allow_origins list.");
            }
            for (config.allow_origins) |origin| {
                if (std.mem.eql(u8, origin, "*")) {
                    @panic("CORS: allow_credentials=true is incompatible with allow_origins containing \"*\". List exact origins.");
                }
            }
        }
        return .{ .config = config };
    }

    pub fn execute(self: *CorsMiddleware, _: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        const origin_header = req.getHeader("Origin") orelse req.getHeader("origin");
        const origin_resolved: ?[]const u8 = blk: {
            if (self.config.allow_origins.len > 0) {
                const client_origin = origin_header orelse break :blk null;
                for (self.config.allow_origins) |allowed| {
                    if (std.mem.eql(u8, allowed, "*")) break :blk "*";
                    if (std.mem.eql(u8, allowed, client_origin)) break :blk client_origin;
                }
                break :blk null;
            }
            break :blk self.config.allow_origin;
        };

        if (origin_resolved) |value| {
            try res.setHeader("Access-Control-Allow-Origin", value);
        }
        if (self.config.allow_origins.len > 0) {
            try res.setHeader("Vary", "Origin");
        }
        try res.setHeader("Access-Control-Allow-Methods", self.config.allow_methods);
        try res.setHeader("Access-Control-Allow-Headers", self.config.allow_headers);
        if (self.config.allow_credentials)
            try res.setHeader("Access-Control-Allow-Credentials", "true");

        if (req.method == .options) {
            try res.setHeader("Access-Control-Max-Age", self.config.max_age);
            res.status = .no_content;
            return .stop;
        }
        return .next;
    }

    pub fn middleware(self: *CorsMiddleware) Middleware {
        return Middleware.from(CorsMiddleware, self);
    }
};
