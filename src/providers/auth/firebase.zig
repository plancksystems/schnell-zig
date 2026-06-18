
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const schnell = @import("schnell");
const Client = schnell.Client;
const provider = @import("provider.zig");
const AuthProvider = provider.AuthProvider;
const AuthResponse = provider.AuthResponse;

pub const FirebaseConfig = struct {
    api_key: []const u8,
    project_id: []const u8,
};

pub const FirebaseAuthProvider = struct {
    config: FirebaseConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: FirebaseConfig) FirebaseAuthProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn authProvider(self: *FirebaseAuthProvider) AuthProvider {
        return AuthProvider.from(FirebaseAuthProvider, self);
    }

    pub fn getAuthorizationUrl(_: *FirebaseAuthProvider, _: Allocator, _: []const u8) ![]const u8 {
        return error.UnsupportedOperation;
    }

    pub fn exchangeCode(_: *FirebaseAuthProvider, _: Allocator, _: Io, _: []const u8) !AuthResponse {
        return error.UnsupportedOperation;
    }

    pub fn validateToken(self: *FirebaseAuthProvider, allocator: Allocator, io: Io, token: []const u8) !AuthResponse {
        const url = try std.fmt.allocPrint(allocator,
            "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key={s}",
            .{self.config.api_key},
        );
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator, "{{\"idToken\":\"{s}\"}}", .{token});
        defer allocator.free(body);
        var resp = try Client.request(allocator, io, .{
            .method = "POST", .url = url,
            .headers = &.{.{ "Content-Type", "application/json" }},
            .body = body,
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const users = parsed.value.object.get("users") orelse return error.InvalidResponse;
        if (users.array.items.len == 0) return error.InvalidResponse;
        const user = users.array.items[0].object;
        return AuthResponse{
            .uid = if (user.get("localId")) |s| try allocator.dupe(u8, s.string) else "",
            .email = if (user.get("email")) |e| try allocator.dupe(u8, e.string) else null,
            .display_name = if (user.get("displayName")) |n| try allocator.dupe(u8, n.string) else null,
            .token = try allocator.dupe(u8, token),
            .refresh_token = null,
            .expires_at = Io.Clock.real.now(io).toMilliseconds() + 3600_000,
            .provider = "firebase",
            .raw_claims = try allocator.dupe(u8, resp.body),
        };
    }

    pub fn refreshToken(self: *FirebaseAuthProvider, allocator: Allocator, io: Io, refresh_tok: []const u8) !AuthResponse {
        const url = try std.fmt.allocPrint(allocator,
            "https://securetoken.googleapis.com/v1/token?key={s}",
            .{self.config.api_key},
        );
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator,
            "grant_type=refresh_token&refresh_token={s}", .{refresh_tok},
        );
        defer allocator.free(body);
        var resp = try Client.request(allocator, io, .{
            .method = "POST", .url = url,
            .headers = &.{.{ "Content-Type", "application/x-www-form-urlencoded" }},
            .body = body,
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const access_token = try allocator.dupe(u8, (obj.get("id_token") orelse return error.InvalidResponse).string);
        const refresh_token_val = if (obj.get("refresh_token")) |rt| try allocator.dupe(u8, rt.string) else null;
        const expires_in_str = if (obj.get("expires_in")) |ei| ei.string else "3600";
        const expires_in = std.fmt.parseInt(i64, expires_in_str, 10) catch 3600;
        const uid = if (obj.get("user_id")) |u| try allocator.dupe(u8, u.string) else "";
        const now_ms = Io.Clock.real.now(io).toMilliseconds();
        return AuthResponse{
            .uid = uid, .email = null, .display_name = null,
            .token = access_token, .refresh_token = refresh_token_val,
            .expires_at = now_ms + (expires_in * 1000),
            .provider = "firebase",
            .raw_claims = try allocator.dupe(u8, resp.body),
        };
    }
};
