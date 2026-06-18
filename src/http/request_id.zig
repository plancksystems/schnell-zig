
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Middleware = @import("middleware.zig").Middleware;
const MatchedRoute = @import("middleware.zig").MatchedRoute;

const log = std.log.scoped(.request_id);

pub const RequestIdMiddleware = struct {
    io: Io,
    header_name: []const u8 = "X-Request-Id",

    pub fn init(io: Io) RequestIdMiddleware {
        return .{ .io = io };
    }

    pub fn execute(self: *RequestIdMiddleware, allocator: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        const existing = req.getHeader(self.header_name) orelse req.getHeader("x-request-id");
        
        const mut_req: *Request = @constCast(req);
        if (existing) |value| {
            mut_req.request_id = value;
        } else {
            var raw: [16]u8 = undefined;
            self.io.random(&raw);
            const hex = std.fmt.bytesToHex(raw, .lower);
            const hex_copy = try allocator.dupe(u8, &hex);
            mut_req.request_id = hex_copy;
        }
        try res.setHeader(self.header_name, mut_req.request_id);
        return .next;
    }

    pub fn middleware(self: *RequestIdMiddleware) Middleware {
        return Middleware.from(RequestIdMiddleware, self);
    }
};


const testing = std.testing;

test "RequestIdMiddleware: echoes incoming X-Request-Id" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var req = try Request.init(a);
    try req.headers.append(a, .{ .name = "X-Request-Id", .value = "abc-123" });
    var res = Response.init(a);

    var mw = RequestIdMiddleware.init(io);
    const action = try mw.execute(a, &req, &res);
    try testing.expectEqual(Middleware.Action.next, action);
    try testing.expectEqualStrings("abc-123", req.request_id);
}

test "RequestIdMiddleware: generates an id when header missing" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var req = try Request.init(a);
    var res = Response.init(a);

    var mw = RequestIdMiddleware.init(io);
    _ = try mw.execute(a, &req, &res);
    try testing.expect(req.request_id.len > 0);
}
