
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("schnell");
const Buffer = @import("buffer.zig").Buffer;
const wasm_log = @import("log.zig");
pub const TokenStore = @import("token_store.zig").TokenStore;
pub const Providers = http.providers.Providers;
pub const Request = http.Request;
pub const Response = http.Response;
pub const Method = http.Method;
pub const Status = http.Status;
pub const Middleware = http.Middleware;
pub const CorsMiddleware = http.CorsMiddleware;

extern fn host_respond(html_ptr: [*]const u8, html_len: u32) void;


pub const Config = struct {
    render_buffer_size: usize = 32 * 1024 * 1024,
    response_buffer_size: usize = 32 * 1024 * 1024,
    expr_buffer_size: usize = 64 * 1024,
};

pub const HandlerFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    req: *const Request,
    res: *Response,
) anyerror!void;

const RouteEntry = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    ctx: ?*anyopaque,
};

pub const WasmApp = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    middlewares: std.ArrayList(Middleware),
    routes: std.ArrayList(RouteEntry),
    res_buf: *Buffer,
    resp_buf: []u8,
    expr_buf: []u8,
    expr_fba: std.heap.FixedBufferAllocator,
    response_hook: ?*const fn (*const Request, *Response, []u8) void,
    token_store: ?*TokenStore = null,
    providers: ?*Providers = null,

    pub fn init(allocator: Allocator, config: Config, yaml_text: []const u8) !WasmApp {
        const res_buf = try allocator.create(Buffer);
        res_buf.* = try Buffer.init(allocator, config.render_buffer_size);

        const resp_buf = try allocator.alloc(u8, config.response_buffer_size);
        const expr_buf = try allocator.alloc(u8, config.expr_buffer_size);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .middlewares = .empty,
            .routes = .empty,
            .res_buf = res_buf,
            .resp_buf = resp_buf,
            .expr_buf = expr_buf,
            .expr_fba = std.heap.FixedBufferAllocator.init(expr_buf),
            .response_hook = null,
            .providers = try Providers.init(allocator, yaml_text),
        };
    }

    pub fn deinit(self: *WasmApp) void {
        if (self.providers) |providers| {
            providers.deinit(self.allocator);
        }
        self.res_buf.deinit();
        self.allocator.destroy(self.res_buf);
        self.allocator.free(self.resp_buf);
        self.allocator.free(self.expr_buf);
        self.arena.deinit();
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *WasmApp, mw: Middleware) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    pub fn route(
        self: *WasmApp,
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

    pub fn get(self: *WasmApp, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.get, path, handler, ctx);
    }

    pub fn post(self: *WasmApp, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.post, path, handler, ctx);
    }

    pub fn put(self: *WasmApp, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.put, path, handler, ctx);
    }

    pub fn delete(self: *WasmApp, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.delete, path, handler, ctx);
    }

    pub fn patch(self: *WasmApp, path: []const u8, handler: HandlerFn, ctx: ?*anyopaque) !void {
        return self.route(.patch, path, handler, ctx);
    }

    pub fn onResponse(self: *WasmApp, hook: *const fn (*const Request, *Response, []u8) void) void {
        self.response_hook = hook;
    }

    pub fn process(self: *WasmApp, req_ptr: [*]const u8, req_len: u32) !void {
        defer {
            self.res_buf.reset();
            _ = self.arena.reset(.retain_capacity);
        }

        self.expr_fba.reset();
        const alloc = self.arena.allocator();

        const raw = req_ptr[0..req_len];

        var req = try Request.init(alloc);
        req.parse(raw) catch {
            var res = Response.init(alloc);
            res.status = .bad_request;
            res.write("Bad Request") catch {};
            self.sendResponse(&req, &res);
            return;
        };

        const body_len = req.contentLength() catch 0 orelse 0;
        if (body_len > 0) {
            if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |end| {
                const body_start = end + 4;
                if (body_start + body_len <= raw.len) {
                    req.body = raw[body_start..][0..body_len];
                }
            }
        }

        var res = Response.init(alloc);
        for (self.middlewares.items) |mw| {
            if (mw.execute(alloc, &req, &res) catch {
                res.status = .internal_server_error;
                res.write("Internal Server Error") catch {};
                self.sendResponse(&req, &res);
                return;
            } == .stop) {
                self.sendResponse(&req, &res);
                return;
            }
        }

        if (self.matchRoute(req.method, req.path)) |entry| {
            extractPathParams(alloc, entry.path, req.path, &req) catch {};
            entry.handler(entry.ctx, alloc, &req, &res) catch |err| {
                res.status = mapErrorToStatus(err);
                res.write(errorBody(err)) catch {};
            };
            self.sendResponse(&req, &res);
            return;
        }

        res.status = .not_found;
        res.write("Not Found") catch {};
        self.sendResponse(&req, &res);
    }

    fn matchRoute(self: *const WasmApp, method: Method, path: []const u8) ?RouteEntry {
        for (self.routes.items) |entry| {
            if (entry.method == method and pathMatches(entry.path, path)) {
                return entry;
            }
        }
        return null;
    }

    fn sendResponse(self: *WasmApp, req: *const Request, res: *Response) void {
        if (self.response_hook) |hook| {
            hook(req, res, self.resp_buf);
        } else {
            const bytes = res.toBytes(self.resp_buf) catch return;
            host_respond(bytes.ptr, @intCast(bytes.len));
        }
    }

    pub fn enableTokenStore(self: *WasmApp, max_cached_tokens: u32) !void {
        const ts = try self.allocator.create(TokenStore);
        ts.* = TokenStore.init(self.allocator, max_cached_tokens);
        self.token_store = ts;
    }

    pub fn getTokenStore(self: *WasmApp) ?*TokenStore {
        return self.token_store;
    }
};


var app_instance: ?*WasmApp = null;

pub fn setAppInstance(app: *WasmApp) void {
    app_instance = app;
}

export fn on_token_save(token_ptr: [*]const u8, token_len: u32) void {
    const app = app_instance orelse return;
    const ts = app.token_store orelse return;
    ts.save(token_ptr[0..token_len]);
}

export fn on_token_revoke(token_ptr: [*]const u8, token_len: u32) void {
    const app = app_instance orelse return;
    const ts = app.token_store orelse return;
    ts.revoke(token_ptr[0..token_len]);
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

fn extractPathParams(
    allocator: Allocator,
    pattern: []const u8,
    path: []const u8,
    req: *const Request
) !void {
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
test "WasmApp init with providers" {
    const allocator = std.testing.allocator;
    const yaml_text =
        \\google_oauth:
        \\  client_id: "test-id"
        \\  client_secret: "test-secret"
        \\  redirect_uri: "http://localhost"
        \\  scopes: "profile"
    ;
    var app = try WasmApp.init(allocator, .{}, yaml_text);
    defer app.deinit();

    try std.testing.expect(app.providers.google_oauth != null);
    try std.testing.expect(std.mem.eql(u8, app.providers.google_oauth.?.client_id, "test-id"));
}
