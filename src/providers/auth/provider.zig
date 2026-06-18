
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AuthResponse = struct {
    uid: []const u8,
    email: ?[]const u8,
    display_name: ?[]const u8,
    token: []const u8,
    refresh_token: ?[]const u8,
    expires_at: i64,
    provider: []const u8,
    raw_claims: []const u8,
};

pub const AuthProvider = struct {
    ptr: *anyopaque,

    getAuthorizationUrlFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        state: []const u8,
    ) anyerror![]const u8,

    exchangeCodeFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        code: []const u8,
    ) anyerror!AuthResponse,

    validateTokenFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        token: []const u8,
    ) anyerror!AuthResponse,

    refreshTokenFn: ?*const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        refresh_token: []const u8,
    ) anyerror!AuthResponse = null,

    pub fn getAuthorizationUrl(self: AuthProvider, allocator: Allocator, state: []const u8) ![]const u8 {
        return self.getAuthorizationUrlFn(self.ptr, allocator, state);
    }

    pub fn exchangeCode(self: AuthProvider, allocator: Allocator, io: Io, code: []const u8) !AuthResponse {
        return self.exchangeCodeFn(self.ptr, allocator, io, code);
    }

    pub fn validateToken(self: AuthProvider, allocator: Allocator, io: Io, token: []const u8) !AuthResponse {
        return self.validateTokenFn(self.ptr, allocator, io, token);
    }

    pub fn refreshToken(self: AuthProvider, allocator: Allocator, io: Io, refresh_tok: []const u8) !AuthResponse {
        if (self.refreshTokenFn) |f| return f(self.ptr, allocator, io, refresh_tok);
        return error.RefreshNotSupported;
    }

    pub fn from(comptime T: type, ptr: *T) AuthProvider {
        const has_refresh = @hasDecl(T, "refreshToken");
        return .{
            .ptr = @ptrCast(ptr),
            .getAuthorizationUrlFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, state: []const u8) anyerror![]const u8 {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.getAuthorizationUrl(alloc, state);
                }
            }.f,
            .exchangeCodeFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, code: []const u8) anyerror!AuthResponse {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.exchangeCode(alloc, io, code);
                }
            }.f,
            .validateTokenFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, token: []const u8) anyerror!AuthResponse {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.validateToken(alloc, io, token);
                }
            }.f,
            .refreshTokenFn = if (has_refresh) struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, refresh_tok: []const u8) anyerror!AuthResponse {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.refreshToken(alloc, io, refresh_tok);
                }
            }.f else null,
        };
    }
};
