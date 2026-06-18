
const std = @import("std");
const mem = std.mem;
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Status = @import("status.zig").Status;

pub const HandlerFn = *const fn (std.mem.Allocator, *const Request, *Response, ?*anyopaque) anyerror!void;

pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    routes: std.ArrayList(Route),

    catch_all: ?HandlerFn = null,
    not_found_handler: ?HandlerFn = null,
    ctx: ?*anyopaque = null,

    pub fn init() Router {
        return .{
            .routes = .empty,
        };
    }

    pub fn setContext(self: *Router, ctx: *anyopaque) void {
        self.ctx = ctx;
    }

    pub fn get(self: *Router, allocator: mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{ .method = .get, .path = path, .handler = handler });
    }

    
    pub fn post(self: *Router, allocator: mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{ .method = .post, .path = path, .handler = handler });
    }

    pub fn put(self: *Router, allocator: mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{ .method = .put, .path = path, .handler = handler });
    }

    pub fn delete(self: *Router, allocator: mem.Allocator, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{ .method = .delete, .path = path, .handler = handler });
    }

    pub fn addRoute(self: *Router, allocator: mem.Allocator, method: Method, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(allocator, .{ .method = method, .path = path, .handler = handler });
    }

    pub fn handle(self: *Router, allocator: mem.Allocator, req: *const Request, res: *Response) !void {
        for (self.routes.items) |route| {
            if (route.method == req.method and matchPath(route.path, req.path)) {
                return route.handler(allocator, req, res, self.ctx);
            }
        }

        if (self.catch_all) |handler| {
            return handler(allocator, req, res, self.ctx);
        }

        if (self.not_found_handler) |handler| {
            return handler(allocator, req, res, self.ctx);
        }

        res.status = .not_found;
        try res.write("Not Found");
    }

    pub fn deinit(self: *Router, allocator: mem.Allocator) void {
        self.routes.deinit(allocator);
    }
};

fn matchPath(pattern: []const u8, path: []const u8) bool {
    if (pattern.len >= 2 and mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return mem.startsWith(u8, path, prefix) or mem.eql(u8, path, pattern[0 .. pattern.len - 2]);
    }
    return mem.eql(u8, pattern, path);
}


test "matchPath - exact match" {
    try std.testing.expect(matchPath("/items", "/items"));
    try std.testing.expect(!matchPath("/items", "/items/"));
    try std.testing.expect(!matchPath("/items/", "/items"));
}

test "matchPath - wildcard" {
    try std.testing.expect(matchPath("/api/*", "/api/users"));
    try std.testing.expect(matchPath("/api/*", "/api/users/123"));
    try std.testing.expect(matchPath("/api/*", "/api/"));
    try std.testing.expect(matchPath("/api/*", "/api"));
    try std.testing.expect(!matchPath("/api/*", "/other/stuff"));
}

test "matchPath - empty path" {
    try std.testing.expect(matchPath("/", "/"));
    try std.testing.expect(!matchPath("/", "/items"));
    try std.testing.expect(!matchPath("/items", "/"));
}

test "matchPath - double slashes" {
    try std.testing.expect(!matchPath("/items", "//items"));
    try std.testing.expect(matchPath("//items", "//items"));
}

test "router - not found response" {
    const alloc = std.testing.allocator;
    var router = Router.init();
    defer router.deinit(alloc);

    var req = try Request.init(alloc);
    defer req.deinit();
    req.method = .get;
    req.path = "/nonexistent";

    var res = Response.init(alloc);
    defer res.deinit();

    try router.handle(alloc, &req, &res);
    
    try std.testing.expectEqual(Status.not_found, res.status);
}
