
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SessionBackend(comptime AppData: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        createFn: *const fn (ptr: *anyopaque, token: []const u8, data: AppData) anyerror!void,
        getFn: *const fn (ptr: *anyopaque, token: []const u8) anyerror!?AppData,
        destroyFn: *const fn (ptr: *anyopaque, token: []const u8) anyerror!void,
        rotateFn: ?*const fn (ptr: *anyopaque, old_token: []const u8) anyerror![]const u8 = null,

        pub fn create(self: Self, token: []const u8, data: AppData) !void {
            return self.createFn(self.ptr, token, data);
        }

        pub fn get(self: Self, token: []const u8) !?AppData {
            return self.getFn(self.ptr, token);
        }

        pub fn destroy(self: Self, token: []const u8) !void {
            return self.destroyFn(self.ptr, token);
        }

        pub fn rotate(self: Self, old_token: []const u8) ![]const u8 {
            if (self.rotateFn) |f| return f(self.ptr, old_token);
            return error.RotateNotSupported;
        }

        pub fn from(comptime T: type, ptr: *T) Self {
            const has_rotate = @hasDecl(T, "rotate");
            return .{
                .ptr = @ptrCast(ptr),
                .createFn = struct {
                    fn f(p: *anyopaque, token: []const u8, data: AppData) anyerror!void {
                        const self_t: *T = @ptrCast(@alignCast(p));
                        return self_t.create(token, data);
                    }
                }.f,
                .getFn = struct {
                    fn f(p: *anyopaque, token: []const u8) anyerror!?AppData {
                        const self_t: *T = @ptrCast(@alignCast(p));
                        return self_t.get(token);
                    }
                }.f,
                .destroyFn = struct {
                    fn f(p: *anyopaque, token: []const u8) anyerror!void {
                        const self_t: *T = @ptrCast(@alignCast(p));
                        return self_t.destroy(token);
                    }
                }.f,
                .rotateFn = if (has_rotate) struct {
                    fn f(p: *anyopaque, old_token: []const u8) anyerror![]const u8 {
                        const self_t: *T = @ptrCast(@alignCast(p));
                        return self_t.rotate(old_token);
                    }
                }.f else null,
            };
        }
    };
}
