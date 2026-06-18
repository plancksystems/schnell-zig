
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const schnell = @import("schnell");
const Client = schnell.Client;
const provider = @import("provider.zig");
const AuthProvider = provider.AuthProvider;
const AuthResponse = provider.AuthResponse;

pub const AzureConfig = struct {
    tenant_id: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scopes: []const u8 = "openid profile email",
};

pub const AzureAuthProvider = struct {
    config: AzureConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: AzureConfig) AzureAuthProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn authProvider(self: *AzureAuthProvider) AuthProvider {
        return AuthProvider.from(AzureAuthProvider, self);
    }

    pub fn getAuthorizationUrl(self: *AzureAuthProvider, allocator: Allocator, state: []const u8) ![]const u8 {
        const cfg = self.config;
        return std.fmt.allocPrint(allocator,
            "https://login.microsoftonline.com/{s}/oauth2/v2.0/authorize?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&state={s}",
            .{ cfg.tenant_id, cfg.client_id, cfg.redirect_uri, cfg.scopes, state },
        );
    }

    pub fn exchangeCode(self: *AzureAuthProvider, allocator: Allocator, io: Io, code: []const u8) !AuthResponse {
        const cfg = self.config;
        const url = try std.fmt.allocPrint(allocator, "https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{cfg.tenant_id});
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator,
            "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}&grant_type=authorization_code&scope={s}",
            .{ code, cfg.client_id, cfg.client_secret, cfg.redirect_uri, cfg.scopes },
        );
        defer allocator.free(body);
        var resp = try Client.request(allocator, io, .{
            .method = "POST", .url = url,
            .headers = &.{.{ "Content-Type", "application/x-www-form-urlencoded" }},
            .body = body,
        });
        defer resp.deinit();
        return parseTokenResponse(allocator, io, resp.body);
    }

    pub fn validateToken(_: *AzureAuthProvider, allocator: Allocator, io: Io, token: []const u8) !AuthResponse {
        const auth_hdr = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer allocator.free(auth_hdr);
        var resp = try Client.request(allocator, io, .{
            .url = "https://graph.microsoft.com/v1.0/me",
            .headers = &.{.{ "Authorization", auth_hdr }},
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        return AuthResponse{
            .uid = if (obj.get("id")) |s| try allocator.dupe(u8, s.string) else "",
            .email = if (obj.get("mail")) |e| try allocator.dupe(u8, e.string) else null,
            .display_name = if (obj.get("displayName")) |n| try allocator.dupe(u8, n.string) else null,
            .token = try allocator.dupe(u8, token),
            .refresh_token = null,
            .expires_at = Io.Clock.real.now(io).toMilliseconds() + 3600_000,
            .provider = "azure_entraid",
            .raw_claims = try allocator.dupe(u8, resp.body),
        };
    }

    pub fn refreshToken(self: *AzureAuthProvider, allocator: Allocator, io: Io, refresh_tok: []const u8) !AuthResponse {
        const cfg = self.config;
        const url = try std.fmt.allocPrint(allocator, "https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{cfg.tenant_id});
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator,
            "refresh_token={s}&client_id={s}&client_secret={s}&grant_type=refresh_token&scope={s}",
            .{ refresh_tok, cfg.client_id, cfg.client_secret, cfg.scopes },
        );
        defer allocator.free(body);
        var resp = try Client.request(allocator, io, .{
            .method = "POST", .url = url,
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
        const uid = if (obj.get("oid")) |s| try allocator.dupe(u8, s.string) else "";
        const email = if (obj.get("preferred_username")) |e| try allocator.dupe(u8, e.string) else null;
        const display_name = if (obj.get("name")) |n| try allocator.dupe(u8, n.string) else null;
        const now_ms = Io.Clock.real.now(io).toMilliseconds();
        return AuthResponse{
            .uid = uid, .email = email, .display_name = display_name,
            .token = access_token, .refresh_token = refresh_token_val,
            .expires_at = now_ms + (expires_in * 1000),
            .provider = "azure_entraid",
            .raw_claims = try allocator.dupe(u8, body),
        };
    }
};
