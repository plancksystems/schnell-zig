
const std = @import("std");

pub const SameSite = enum {
    Strict,
    Lax,
    None,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,

    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};
