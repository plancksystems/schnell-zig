
const std = @import("std");

pub const Method = enum(u4) {
    get,
    head,
    post,
    put,
    delete,
    options,
    patch,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .options => "OPTIONS",
            .patch => "PATCH",
        };
    }

    pub fn fromString(s: []const u8) !Method {
        if (std.ascii.eqlIgnoreCase(s, "GET")) return .get;
        if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .head;
        if (std.ascii.eqlIgnoreCase(s, "POST")) return .post;
        if (std.ascii.eqlIgnoreCase(s, "PUT")) return .put;
        if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .delete;
        if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .options;
        if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .patch;
        return error.InvalidMethod;
    }
};
