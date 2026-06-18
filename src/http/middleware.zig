
const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Method = @import("method.zig").Method;

pub const MatchedRoute = struct {
    method: Method,
    pattern: []const u8,
};

pub const Middleware = struct {
    ptr: *anyopaque,
    executeFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        request: *const Request,
        response: *Response,
    ) anyerror!Action,

    afterFn: ?*const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        request: *const Request,
        response: *Response,
        matched: ?*const MatchedRoute,
    ) anyerror!void = null,

    pub const Action = enum { next, stop };

    pub fn execute(self: Middleware, allocator: Allocator, req: *const Request, res: *Response) !Action {
        return self.executeFn(self.ptr, allocator, req, res);
    }

    pub fn after(
        self: Middleware,
        allocator: Allocator,
        req: *const Request,
        res: *Response,
        matched: ?*const MatchedRoute
    ) !void {
        if (self.afterFn) |f| try f(self.ptr, allocator, req, res, matched);
    }

    pub fn from(comptime T: type, ptr: *T) Middleware {
        const has_after = @hasDecl(T, "after");
        return .{
            .ptr = @ptrCast(ptr),
            .executeFn = struct {
                fn exec(p: *anyopaque, alloc: Allocator, req: *const Request, res: *Response) anyerror!Action {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.execute(alloc, req, res);
                }
            }.exec,
            .afterFn = if (has_after) struct {
                fn afterAdapter(
                    p: *anyopaque,
                    alloc: Allocator,
                    req: *const Request,
                    res: *Response,
                    matched: ?*const MatchedRoute
                ) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.after(alloc, req, res, matched);
                }
            }.afterAdapter else null,
        };
    }
};
