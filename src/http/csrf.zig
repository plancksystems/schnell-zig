
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Middleware = @import("middleware.zig").Middleware;

const log = std.log.scoped(.csrf);

pub const CsrfMiddleware = struct {
    io: Io,
    header_name: []const u8 = "X-CSRF-Token",
    form_field: []const u8 = "_csrf",
    enforce: bool = true,

    pub fn init(io: Io) CsrfMiddleware {
        return .{ .io = io };
    }

    pub fn execute(self: *CsrfMiddleware, _: Allocator, req: *const Request, res: *Response) !Middleware.Action {
        if (req.method == .get or req.method == .head or req.method == .options) {
            self.emitTokenHeader(req, res) catch {};
            return .next;
        }

        const expected = req.getHeader("X-Session-CSRF") orelse {
            self.emitTokenHeader(req, res) catch {};
            return .next;
        };

        const client_token = req.getHeader(self.header_name) orelse
            getFormField(req.body, self.form_field) orelse {
            if (self.enforce) {
                log.warn("csrf: missing token on {s} {s}", .{ req.method.toString(), req.path });
                res.status = .forbidden;
                res.write("{\"error\":\"CSRF token missing\"}") catch {};
                return .stop;
            }
            log.warn("csrf: missing token (not enforced) on {s} {s}", .{ req.method.toString(), req.path });
            return .next;
        };

        if (!std.mem.eql(u8, expected, client_token)) {
            if (self.enforce) {
                log.warn("csrf: token mismatch on {s} {s}", .{ req.method.toString(), req.path });
                res.status = .forbidden;
                res.write("{\"error\":\"CSRF token mismatch\"}") catch {};
                return .stop;
            }
            log.warn("csrf: token mismatch (not enforced) on {s} {s}", .{ req.method.toString(), req.path });
        }

        self.emitTokenHeader(req, res) catch {};
        return .next;
    }

    fn emitTokenHeader(self: *CsrfMiddleware, req: *const Request, res: *Response) !void {
        if (req.getHeader("X-Session-CSRF")) |token| {
            try res.setHeader(self.header_name, token);
        }
    }

    pub fn middleware(self: *CsrfMiddleware) Middleware {
        return Middleware.from(CsrfMiddleware, self);
    }
};

fn getFormField(body: []const u8, name: []const u8) ?[]const u8 {
    if (body.len == 0) return null;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}
