
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Client = @import("../../client.zig").Client;
const jwks = @import("jwks.zig");
const provider = @import("provider.zig");
const AuthProvider = provider.AuthProvider;
const AuthResponse = provider.AuthResponse;

pub const GoogleConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scopes: []const u8 = "openid profile email",
};

pub const GoogleAuthProvider = struct {
    config: GoogleConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: GoogleConfig) GoogleAuthProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn authProvider(self: *GoogleAuthProvider) AuthProvider {
        return AuthProvider.from(GoogleAuthProvider, self);
    }

    pub fn getAuthorizationUrl(self: *GoogleAuthProvider, allocator: Allocator, state: []const u8) ![]const u8 {
        const cfg = self.config;
        const enc_redirect = try urlEncode(allocator, cfg.redirect_uri);
        defer allocator.free(enc_redirect);
        const enc_scopes = try urlEncode(allocator, cfg.scopes);
        defer allocator.free(enc_scopes);
        return std.fmt.allocPrint(
            allocator,
            "https://accounts.google.com/o/oauth2/v2/auth?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&state={s}&access_type=offline",
            .{ cfg.client_id, enc_redirect, enc_scopes, state },
        );
    }

    pub fn exchangeCode(self: *GoogleAuthProvider, allocator: Allocator, io: Io, code: []const u8) !AuthResponse {
        const cfg = self.config;
        const body = try std.fmt.allocPrint(
            allocator,
            "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}&grant_type=authorization_code",
            .{ code, cfg.client_id, cfg.client_secret, cfg.redirect_uri },
        );
        defer allocator.free(body);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://oauth2.googleapis.com/token",
            .headers = &.{.{ "Content-Type", "application/x-www-form-urlencoded" }},
            .body = body,
        });
        defer resp.deinit();

        return parseTokenResponse(allocator, io, resp.body);
    }

    pub fn validateToken(_: *GoogleAuthProvider, allocator: Allocator, io: Io, token: []const u8) !AuthResponse {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://oauth2.googleapis.com/tokeninfo?access_token={s}",
            .{token},
        );
        defer allocator.free(url);

        var resp = try Client.request(allocator, io, .{ .url = url });
        defer resp.deinit();

        return parseTokenInfo(allocator, io, resp.body, token);
    }

    pub fn refreshToken(self: *GoogleAuthProvider, allocator: Allocator, io: Io, refresh_tok: []const u8) !AuthResponse {
        const cfg = self.config;
        const body = try std.fmt.allocPrint(
            allocator,
            "refresh_token={s}&client_id={s}&client_secret={s}&grant_type=refresh_token",
            .{ refresh_tok, cfg.client_id, cfg.client_secret },
        );
        defer allocator.free(body);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://oauth2.googleapis.com/token",
            .headers = &.{.{ "Content-Type", "application/x-www-form-urlencoded" }},
            .body = body,
        });
        defer resp.deinit();

        return parseTokenResponse(allocator, io, resp.body);
    }

    
    fn parseTokenResponse(allocator: Allocator, io: Io, body: []const u8) !AuthResponse {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        const access_token = try allocator.dupe(u8, (obj.get("access_token") orelse return error.InvalidResponse).string);
        const refresh_token_val = if (obj.get("refresh_token")) |rt| try allocator.dupe(u8, rt.string) else null;
        const expires_in = if (obj.get("expires_in")) |ei| ei.integer else 3600;
        const id_token_str = if (obj.get("id_token")) |it| it.string else null;

        var uid: []const u8 = "";
        var email: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var raw_claims: []const u8 = body;

        if (id_token_str) |jwt| {
            const claims = decodeJwtPayload(allocator, jwt) catch body;
            raw_claims = claims;
            var claims_parsed = std.json.parseFromSlice(std.json.Value, allocator, claims, .{}) catch null;
            if (claims_parsed) |*cp| {
                defer cp.deinit();
                const co = cp.value.object;
                if (co.get("sub")) |s| uid = try allocator.dupe(u8, s.string);
                if (co.get("email")) |e| email = try allocator.dupe(u8, e.string);
                if (co.get("name")) |n| display_name = try allocator.dupe(u8, n.string);
            }
        }

        const now_ms = Io.Clock.real.now(io).toMilliseconds();
        return AuthResponse{
            .uid = uid,
            .email = email,
            .display_name = display_name,
            .token = access_token,
            .refresh_token = refresh_token_val,
            .expires_at = now_ms + (expires_in * 1000),
            .provider = "google",
            .raw_claims = try allocator.dupe(u8, raw_claims),
        };
    }

    fn parseTokenInfo(allocator: Allocator, io: Io, body: []const u8, token: []const u8) !AuthResponse {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        const uid = if (obj.get("sub")) |s| try allocator.dupe(u8, s.string) else "";
        const email = if (obj.get("email")) |e| try allocator.dupe(u8, e.string) else null;
        const expires_in = if (obj.get("expires_in")) |ei| std.fmt.parseInt(i64, ei.string, 10) catch 3600 else 3600;
        const now_ms = Io.Clock.real.now(io).toMilliseconds();

        return AuthResponse{
            .uid = uid,
            .email = email,
            .display_name = null,
            .token = try allocator.dupe(u8, token),
            .refresh_token = null,
            .expires_at = now_ms + (expires_in * 1000),
            .provider = "google",
            .raw_claims = try allocator.dupe(u8, body),
        };
    }

    fn decodeJwtPayload(allocator: Allocator, jwt: []const u8) ![]const u8 {
        var parts = std.mem.splitScalar(u8, jwt, '.');
        _ = parts.next();
        const payload_b64 = parts.next() orelse return error.InvalidJwt;
        return jwks.decodeBase64Url(allocator, payload_b64);
    }
};

fn urlEncode(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        const safe = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return try out.toOwnedSlice(allocator);
}
