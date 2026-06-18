
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
    writer: *std.Io.Writer,
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

pub const ProxyFieldMapping = struct {
    local_key: []const u8,
    upstream_name: []const u8,
};

pub const ProxyOptions = struct {
    target_path: ?[]const u8 = null,

    strip_prefix: bool = false,

    forward_locals_as_query: []const ProxyFieldMapping = &.{},

    forward_locals_as_form_body: []const ProxyFieldMapping = &.{},

    forward_locals_as_header: []const ProxyFieldMapping = &.{},
};

const ProxyConfig = struct {
    io: Io,
    target_base: []const u8,
    static_prefix: []const u8,
    target_path: ?[]const u8 = null,
    strip_prefix: bool = false,
    forward_locals_as_query: []const ProxyFieldMapping = &.{},
    forward_locals_as_form_body: []const ProxyFieldMapping = &.{},
    forward_locals_as_header: []const ProxyFieldMapping = &.{},
};

pub const App = struct {
    allocator: Allocator,
    server: Server,
    middlewares: std.ArrayList(Middleware),
    routes: std.ArrayList(RouteEntry),
    streaming_routes: std.ArrayList(StreamingRouteEntry),
    proxy_configs: std.ArrayList(*ProxyConfig),
    response_hook: ?*const fn (*const Request, *Response) void,
    json_errors: bool = false,

    pub fn init(allocator: Allocator, config: Server.Config) !App {
        return .{
            .allocator = allocator,
            .server = try Server.init(allocator, config),
            .middlewares = .empty,
            .routes = .empty,
            .streaming_routes = .empty,
            .proxy_configs = .empty,
            .response_hook = null,
        };
    }

    pub fn deinit(self: *App) void {
        self.routes.deinit(self.allocator);
        self.streaming_routes.deinit(self.allocator);
        for (self.proxy_configs.items) |cfg| {
            self.allocator.free(cfg.static_prefix);
            self.allocator.destroy(cfg);
        }
        self.proxy_configs.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
        self.server.deinit();
    }

    pub fn use(self: *App, mw: Middleware) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    pub fn route(
        self: *App,
        method: Method,
        path: []const u8,
        handler: HandlerFn,
        ctx: ?*anyopaque
    ) !void {
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

    pub fn routeStreaming(
        self: *App,
        method: Method,
        path: []const u8,
        handler: StreamingHandlerFn,
        ctx: ?*anyopaque
    ) !void {
        try self.streaming_routes.append(self.allocator, .{
            .method = method,
            .path = path,
            .handler = handler,
            .ctx = ctx,
        });
    }

    pub fn proxy(
        self: *App,
        io: Io,
        method: Method,
        pattern: []const u8,
        target_base: []const u8
    ) !void {
        return self.proxyOpts(io, method, pattern, target_base, .{ .strip_prefix = true });
    }

    pub fn proxyOpts(
        self: *App,
        io: Io,
        method: Method,
        pattern: []const u8,
        target_base: []const u8,
        opts: ProxyOptions
    ) !void {
        const prefix = try self.allocator.dupe(u8, staticPrefix(pattern));

        const cfg = try self.allocator.create(ProxyConfig);
        cfg.* = .{
            .io = io,
            .target_base = target_base,
            .static_prefix = prefix,
            .target_path = opts.target_path,
            .strip_prefix = opts.strip_prefix,
            .forward_locals_as_query = opts.forward_locals_as_query,
            .forward_locals_as_form_body = opts.forward_locals_as_form_body,
            .forward_locals_as_header = opts.forward_locals_as_header,
        };
        try self.proxy_configs.append(self.allocator, cfg);

        try self.route(method, pattern, proxyHandle, @ptrCast(cfg));
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

fn proxyHandle(
    ctx: ?*anyopaque,
    allocator: Allocator,
    req: *const Request,
    res: *Response
) !void {
    const cfg: *ProxyConfig = @ptrCast(@alignCast(ctx orelse return error.NoContext));

    const upstream_path: []const u8 = if (cfg.target_path) |tp|
        tp
    else if (cfg.strip_prefix and std.mem.startsWith(u8, req.path, cfg.static_prefix))
        req.path[cfg.static_prefix.len..]
    else
        req.path;

    const url = try buildUpstreamUrl(allocator, cfg, req, upstream_path);
    defer allocator.free(url);

    var hdr_buf: std.ArrayList([2][]const u8) = .empty;
    defer hdr_buf.deinit(allocator);
    if (req.getHeader("Content-Type")) |v| try hdr_buf.append(allocator, .{ "Content-Type", v });
    if (req.getHeader("Accept")) |v| try hdr_buf.append(allocator, .{ "Accept", v });
    for (cfg.forward_locals_as_header) |m| {
        if (req.getLocal(m.local_key)) |v| {
            try hdr_buf.append(allocator, .{ m.upstream_name, v });
        }
    }

    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| allocator.free(b);
    const body: ?[]const u8 = blk: {
        if (cfg.forward_locals_as_form_body.len == 0) {
            break :blk if (req.body.len > 0) req.body else null;
        }
        const method = req.method;
        const mutates = method == .post or method == .put or method == .patch;
        if (!mutates) {
            break :blk if (req.body.len > 0) req.body else null;
        }
        const ct = req.getHeader("Content-Type") orelse "";
        if (!std.mem.startsWith(u8, ct, "application/x-www-form-urlencoded")) {
            break :blk if (req.body.len > 0) req.body else null;
        }
        body_owned = try appendLocalsToFormBody(allocator, req.body, req, cfg.forward_locals_as_form_body);
        break :blk body_owned;
    };

    const method_str = req.method.toString();
    const handler_io = req.io orelse cfg.io;
    var upstream = Client.request(allocator, handler_io, .{
        .method = method_str,
        .url = url,
        .headers = hdr_buf.items,
        .body = body,
    }) catch |err| {
        std.log.err("proxy {s} {s}: upstream connect failed: {}", .{ method_str, url, err });
        res.status = .bad_gateway;
        try res.write("Bad Gateway");
        return;
    };
    defer upstream.deinit();

    res.status = @enumFromInt(upstream.status);
    if (upstream.header("Content-Type")) |ct| try res.setHeader("Content-Type", ct);
    for (upstream.headers) |h| {
        if (std.mem.startsWith(u8, h.name, "X-") or std.ascii.startsWithIgnoreCase(h.name, "HX-")) {
            try res.setHeader(h.name, h.value);
        }
    }
    try res.write(upstream.body);
}

fn buildUpstreamUrl(
    allocator: Allocator,
    cfg: *const ProxyConfig,
    req: *const Request,
    upstream_path: []const u8
) ![]const u8 {
    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, cfg.target_base);
    try url.appendSlice(allocator, upstream_path);

    var has_query = false;
    if (req.query_string) |qs| {
        if (qs.len > 0) {
            try url.append(allocator, '?');
            try url.appendSlice(allocator, qs);
            has_query = true;
        }
    }
    for (cfg.forward_locals_as_query) |m| {
        const value = req.getLocal(m.local_key) orelse continue;
        try url.append(allocator, if (has_query) '&' else '?');
        try url.appendSlice(allocator, m.upstream_name);
        try url.append(allocator, '=');
        try url.appendSlice(allocator, value);
        has_query = true;
    }
    return try url.toOwnedSlice(allocator);
}

fn appendLocalsToFormBody(
    allocator: Allocator,
    existing: []const u8,
    req: *const Request,
    mappings: []const ProxyFieldMapping
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, existing);
    var has_field = existing.len > 0;
    for (mappings) |m| {
        const value = req.getLocal(m.local_key) orelse continue;
        if (has_field) try out.append(allocator, '&');
        try out.appendSlice(allocator, m.upstream_name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, value);
        has_field = true;
    }
    return try out.toOwnedSlice(allocator);
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
