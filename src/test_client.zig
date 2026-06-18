
const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Request = @import("http/request.zig").Request;
const Response = @import("http/response.zig").Response;
const Method = @import("http/method.zig").Method;
const Status = @import("http/status.zig").Status;

pub const TestResponse = struct {
    status: u16,
    body: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TestResponse) void {
        self.arena.deinit();
    }

    pub fn bodyAsInt(self: *const TestResponse, comptime T: type) !T {
        return std.fmt.parseInt(T, self.body, 10);
    }
};

pub const RequestOptions = struct {
    method: Method = .get,
    path: []const u8,
    body: []const u8 = "",
    headers: []const [2][]const u8 = &.{},
};

pub const TestClient = struct {
    allocator: Allocator,
    app: *App,

    pub fn init(allocator: Allocator, app: *App) TestClient {
        return .{ .allocator = allocator, .app = app };
    }

    pub fn get(self: *TestClient, path: []const u8) !TestResponse {
        return self.request(.{ .method = .get, .path = path });
    }

    pub fn post(self: *TestClient, path: []const u8, body: []const u8) !TestResponse {
        return self.request(.{
            .method = .post,
            .path = path,
            .body = body,
        });
    }

    pub fn request(self: *TestClient, opts: RequestOptions) !TestResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var req = try Request.init(a);
        req.method = opts.method;
        req.path = opts.path;
        req.body = opts.body;
        for (opts.headers) |h| {
            try req.headers.append(a, .{ .name = h[0], .value = h[1] });
        }

        var res = Response.init(a);

        try self.app.dispatchTest(a, &req, &res);

        
        const body_copy = try a.dupe(u8, res.body.items);

        return .{
            .status = @intFromEnum(res.status),
            .body = body_copy,
            .arena = arena,
        };
    }
};


const testing = std.testing;

fn pingHandler(
    _: ?*anyopaque,
    _: Allocator,
    _: *const Request,
    res: *Response
) anyerror!void {
    try res.write("pong");
}

test "TestClient: GET against a registered route returns the handler body" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    _ = io;

    var app = try App.init(testing.allocator, .{
        .port = 0,
        .static_dir = "",
    });
    defer app.deinit();

    try app.get("/ping", &pingHandler, null);

    var client = TestClient.init(testing.allocator, &app);
    var resp = try client.get("/ping");
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("pong", resp.body);
}

test "TestClient: missing route returns 404" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    _ = threaded.io();

    var app = try App.init(testing.allocator, .{
        .port = 0,
        .static_dir = "",
    });
    defer app.deinit();

    var client = TestClient.init(testing.allocator, &app);
    var resp = try client.get("/nowhere");
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 404), resp.status);
}

test "TestClient: healthz returns {\"status\":\"ok\"}" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    _ = threaded.io();

    var app = try App.init(testing.allocator, .{
        .port = 0,
        .static_dir = "",
    });
    defer app.deinit();
    try app.healthz("/healthz");

    var client = TestClient.init(testing.allocator, &app);
    var resp = try client.get("/healthz");
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}
