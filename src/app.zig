const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Server = @import("server.zig").Server;
const Request = @import("./http/request.zig").Request;
const Response = @import("./http/response.zig").Response;
const router_mod = @import("./http/router.zig");
const Router = router_mod.Router;
const Method = @import("./http/method.zig").Method;
const Status = @import("./http/status.zig").Status;
const middleware_mod = @import("./http/middleware.zig");
const Middleware = middleware_mod.Middleware;
const MatchedRoute = middleware_mod.MatchedRoute;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Providers = @import("providers/root.zig").Providers;

pub threadlocal var current_io: ?Io = null;

pub const HandlerFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    req: *const Request,
    res: *Response,
) anyerror!void;

pub const StreamingHandlerFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    req: *const Request,
    req_writer: *std.Io.Writer,
) anyerror!void;

const RouteEntry = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    ctx: ?*anyopaque,
};

const StreamingRouteEntry = struct {
    method: Method,
    path: []const u8,
    handler: StreamingHandlerFn,
    ctx: ?*anyopaque,
};

pub const App = struct {
    allocator: Allocator,
    server: Server,
    middlewares: std.ArrayList(Middleware),
    routes: std.ArrayList(RouteEntry),
    streaming_routes: std.ArrayList(StreamingRouteEntry),
    response_hook: ?*const fn (*const Request, *Response) void,
    json_errors: bool = false,
    providers: ?*Providers = null,

    pub fn init(allocator: Allocator, config: Server.Config, yaml_text: []const u8) !App {
        return .{
            .allocator = allocator,
            .server = try Server.init(allocator, config),
            .middlewares = .empty,
            .routes = .empty,
            .streaming_routes = .empty,
            .response_hook = null,
            .providers = try Providers.init(allocator, yaml_text),
        };
    }

    pub fn deinit(self: *App) void {
        self.routes.deinit(self.allocator);
        self.streaming_routes.deinit(self.allocator);
        if (self.providers) |providers| {
            providers.deinit(self.allocator);
        }
        self.middlewares.deinit(self.allocator);
        self.server.deinit();
    }

    pub fn use(self: *App, mw: Middleware) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    pub fn route(self: *App, method: Method, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        try self.routes.append(self.allocator, .{
            .method = method,
            .path = path,
            .handler = handler,
            .ctx = ctx,
        });
    }

    pub fn get(self: *App, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.get, path, handler, ctx);
    }

    pub fn post(self: *App, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.post, path, handler, ctx);
    }

    pub fn put(self: *App, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.put, path, handler, ctx);
    }

    pub fn delete(self: *App, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.delete, path, handler, ctx);
    }

    pub fn patch(self: *App, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.patch, path, handler, ctx);
    }

    pub fn routeStreaming(self: *App, method: Method, path: []const u8, handler: StreamingHandlerFn, ctx: ?*anyopaque) !void {
        try self.streaming_routes.append(self.allocator, .{
            .method = method,
            .path = path,
            .handler = handler,
            .ctx = ctx,
        });
    }

    pub fn onResponse(self: *App, hook: *const fn (*const Request, *Response) void) void {
        self.response_hook = hook;
    }

    pub fn setStaticDir(self: *App, dir: []const u8) void {
        self.server.static_dir = dir;
    }

    pub fn dispatchTest(self: *App, allocator: Allocator, req: *const Request, res: *Response) !void {
        return handleRequest(allocator, req, res, @ptrCast(self));
    }

    pub fn healthz(self: *App, path: []const u8) !void {
        try self.route(.get, path, healthzHandler, null);
    }

    pub fn readyz(self: *App, path: []const u8) !void {
        try self.route(.get, path, readyzHandler, null);
    }

    pub fn metricsEndpoint(self: *App, path: []const u8) !void {
        try self.route(.get, path, metricsHandler, @ptrCast(&self.server));
    }

    pub fn run(self: *App, io: Io) !void {
        self.server.router.setContext(@ptrCast(self));
        self.server.router.catch_all = handleRequest;
        try self.server.listen(io);
    }

    pub fn stop(self: *App, io: Io) void {
        self.server.stop(io);
    }

    fn handleRequest(allocator: Allocator, req: *const Request, res: *Response, ctx: ?*anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx orelse return error.NoContext));

        var matched_route: ?MatchedRoute = null;
        defer {
            for (self.middlewares.items) |mw| {
                mw.after(allocator, req, res, if (matched_route) |*m| m else null) catch {};
            }
        }

        current_io = req.io;
        defer current_io = null;

        for (self.middlewares.items) |mw| {
            if (mw.execute(allocator, req, res) catch {
                res.status = .internal_server_error;
                try res.write("Internal Server Error");
                return;
            } == .stop) return;
        }

        for (self.streaming_routes.items) |entry| {
            if (entry.method == req.method and pathMatches(entry.path, req.path)) {
                matched_route = .{
                    .method = entry.method,
                    .pattern = entry.path,
                };
                extractPathParams(allocator, entry.path, req.path, req) catch {};
                res.streaming_handler = entry.handler;
                res.streaming_ctx = entry.ctx;
                return;
            }
        }

        for (self.routes.items) |entry| {
            if (entry.method == req.method and pathMatches(entry.path, req.path)) {
                matched_route = .{
                    .method = entry.method,
                    .pattern = entry.path,
                };
                extractPathParams(allocator, entry.path, req.path, req) catch {};
                entry.handler(entry.ctx, allocator, req, res) catch |err| {
                    res.status = mapErrorToStatus(err);
                    try res.write(errorBody(err));
                };
                if (self.response_hook) |hook| hook(req, res);
                return;
            }
        }

        res.status = .not_found;
        try res.write("Not Found");
        if (self.response_hook) |hook| hook(req, res);
    }
};

fn staticPrefix(pattern: []const u8) []const u8 {
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] != '/') {
            i += 1;
            continue;
        }
        if (i + 1 < pattern.len and (pattern[i + 1] == ':' or pattern[i + 1] == '*')) {
            return pattern[0..i];
        }
        i += 1;
    }
    return pattern;
}

fn pathMatches(pattern: []const u8, path: []const u8) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pat_seg = pat_it.next();
        const path_seg = path_it.next();
        if (pat_seg == null and path_seg == null) return true;
        if (pat_seg == null or path_seg == null) return false;
        if (pat_seg.?.len > 0 and pat_seg.?[0] == ':') continue;
        if (!std.mem.eql(u8, pat_seg.?, path_seg.?)) return false;
    }
}

fn extractPathParams(allocator: Allocator, pattern: []const u8, path: []const u8, req: *const Request) !void {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pat_seg = pat_it.next() orelse break;
        const path_seg = path_it.next() orelse break;
        if (pat_seg.len > 0 and pat_seg[0] == ':') {
            const param_name = pat_seg[1..];
            const key = try allocator.dupe(u8, param_name);
            const value = try allocator.dupe(u8, path_seg);
            try req.setLocal(key, value);
        }
    }
}

fn mapErrorToStatus(err: anyerror) Status {
    return switch (err) {
        error.HandlerNotFound => .not_found,
        error.NotFound => .not_found,
        error.ValidationFailed => .bad_request,
        error.InvalidRequest => .bad_request,
        error.EmptyBody => .bad_request,
        error.Forbidden => .forbidden,
        error.Unauthorized => .unauthorized,
        else => .internal_server_error,
    };
}

fn errorBody(err: anyerror) []const u8 {
    return switch (err) {
        error.HandlerNotFound => "Not Found",
        error.NotFound => "Not Found",
        error.ValidationFailed => "Validation Failed",
        error.InvalidRequest => "Bad Request",
        error.EmptyBody => "Empty Body",
        else => "Internal Server Error",
    };
}

fn healthzHandler(_: ?*anyopaque, _: Allocator, _: *const Request, res: *Response) anyerror!void {
    res.status = .ok;
    try res.setHeader("Content-Type", "application/json");
    try res.setHeader("Cache-Control", "no-store");
    try res.write("{\"status\":\"ok\"}");
}

fn readyzHandler(_: ?*anyopaque, _: Allocator, _: *const Request, res: *Response) anyerror!void {
    res.status = .ok;
    try res.setHeader("Content-Type", "application/json");
    try res.setHeader("Cache-Control", "no-store");
    try res.write("{\"status\":\"ok\"}");
}

fn metricsHandler(ctx: ?*anyopaque, allocator: Allocator, _: *const Request, res: *Response) anyerror!void {
    res.status = .ok;
    try res.setHeader("Content-Type", "application/json");
    try res.setHeader("Cache-Control", "no-store");
    if (ctx) |ptr| {
        const server: *Server = @ptrCast(@alignCast(ptr));
        const active = server.active_connections.load(.acquire);
        const body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"active_connections\":{d}}}", .{active});
        try res.write(body);
    } else {
        try res.write("{\"status\":\"ok\",\"active_connections\":0}");
    }
}
