
const std = @import("std");
const mem = std.mem;
const Method = @import("method.zig").Method;
const url = @import("url.zig");
const multipart = @import("multipart.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    allocator: mem.Allocator,
    method: Method = .get,
    path: []const u8 = "/",
    headers: std.ArrayList(Header),
    cookies: std.StringHashMap([]const u8),
    query_string: ?[]const u8 = null,
    body: []const u8 = "",
    keep_alive: bool = true,
    io: ?std.Io = null,
    request_id: []const u8 = "",
    locals: *std.StringHashMap([]const u8),

    pub fn deinit(self: *Request) void {
        self.headers.deinit(self.allocator);
        self.cookies.deinit();
        self.locals.deinit();
        self.allocator.destroy(self.locals);
    }

    pub fn init(allocator: mem.Allocator) !Request {
        const locals = try allocator.create(std.StringHashMap([]const u8));
        locals.* = std.StringHashMap([]const u8).init(allocator);
        return .{
            .allocator = allocator,
            .headers = .empty,
            .cookies = std.StringHashMap([]const u8).init(allocator),
            .locals = locals,
        };
    }

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn getCookie(self: *const Request, name: []const u8) ?[]const u8 {
        return self.cookies.get(name);
    }

    pub fn setLocal(self: *const Request, key: []const u8, value: []const u8) !void {
        try self.locals.put(key, value);
    }

    pub fn getLocal(self: *const Request, key: []const u8) ?[]const u8 {
        return self.locals.get(key);
    }

    pub fn parse(self: *Request, buf: []const u8) !void {
        var lines = mem.splitSequence(u8, buf, "\r\n");

        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = mem.splitScalar(u8, request_line, ' ');

        const method_str = parts.next() orelse return error.InvalidRequest;
        self.method = try Method.fromString(method_str);

        const raw_path = parts.next() orelse return error.InvalidRequest;
        if (mem.indexOfScalar(u8, raw_path, '?')) |qmark| {
            self.path = raw_path[0..qmark];
            self.query_string = raw_path[qmark + 1 ..];
        } else {
            self.path = raw_path;
        }

        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = mem.trim(u8, line[colon + 1 ..], " ");
            try self.headers.append(self.allocator, .{ .name = name, .value = value });
        }

        if (self.getHeader("Cookie")) |cookie_header| {
            try self.parseCookies(cookie_header);
        }

        if (self.getHeader("connection")) |conn| {
            self.keep_alive = !std.ascii.eqlIgnoreCase(conn, "close");
        } else if (self.getHeader("Connection")) |conn| {
            self.keep_alive = !std.ascii.eqlIgnoreCase(conn, "close");
        }
    }

    fn parseCookies(self: *Request, header: []const u8) !void {
        var pairs = mem.splitScalar(u8, header, ';');
        while (pairs.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            const name = mem.trim(u8, pair[0..eq], " ");
            const value = mem.trim(u8, pair[eq + 1 ..], " ");

            if (name.len == 0) continue;

            const name_dup = try self.allocator.dupe(u8, name);
            const value_dup = try self.allocator.dupe(u8, value);

            try self.cookies.put(name_dup, value_dup);
        }
    }

    pub fn contentLength(self: *const Request) !?usize {
        const cl = self.getHeader("Content-Length") orelse
            self.getHeader("content-length") orelse return null;
        return std.fmt.parseInt(usize, cl, 10) catch return error.MalformedContentLength;
    }

    pub fn getQuery(self: *const Request, name: []const u8) ?[]const u8 {
        const qs = self.query_string orelse return null;
        var pairs = mem.splitScalar(u8, qs, '&');
        while (pairs.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }

    pub fn getParams(self: *const Request, comptime T: type) T {
        var result: T = .{};
        const qs = self.query_string orelse return result;
        if (qs.len == 0) return result;

        var pairs = mem.splitScalar(u8, qs, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_pos = mem.indexOfScalar(u8, pair, '=');
            const key = if (eq_pos) |pos| pair[0..pos] else pair;
            const value = if (eq_pos) |pos| pair[pos + 1 ..] else "";

            inline for (std.meta.fields(T)) |field| {
                if (mem.eql(u8, field.name, key)) {
                    @field(result, field.name) = coerceField(field.type, value);
                }
            }
        }
        return result;
    }

    pub fn getBody(self: *const Request, allocator: mem.Allocator, comptime T: type) !T {
        if (self.body.len == 0) return error.EmptyBody;
        if (isJson(self.body)) {
            const parsed = try std.json.parseFromSlice(T, allocator, self.body, .{});
            return parsed.value;
        }
        return parseFormBody(T, self.body);
    }

    pub fn getMultipartField(self: *const Request, name: []const u8) ?multipart.Part {
        const ct = self.getHeader("Content-Type") orelse return null;
        var parser = multipart.MultipartParser.init(ct, self.body) orelse return null;
        var iter = parser.iterator();
        while (iter.next()) |part| {
            if (mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    pub fn getFormParam(self: *const Request, name: []const u8) ?[]const u8 {
        if (self.getMultipartField(name)) |part| return part.data;
        if (self.body.len == 0) return null;
        var pairs = mem.splitScalar(u8, self.body, '&');
        while (pairs.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (mem.eql(u8, pair[0..eq], name)) return url.decode(pair[eq + 1 ..]);
        }
        return null;
    }
};


fn isJson(body: []const u8) bool {
    for (body) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        return c == '{' or c == '[';
    }
    return false;
}

fn coerceField(comptime T: type, value: []const u8) T {
    const info = @typeInfo(T);
    if (T == []const u8 or T == []u8) return value;
    if (info == .optional) {
        if (value.len == 0) return null;
        return coerceField(info.optional.child, value);
    }
    if (info == .float) return std.fmt.parseFloat(T, value) catch 0;
    if (info == .int) return std.fmt.parseInt(T, value, 10) catch 0;
    if (info == .bool) {
        return mem.eql(u8, value, "true") or
            mem.eql(u8, value, "on") or
            mem.eql(u8, value, "1");
    }
    return undefined;
}

fn parseFormBody(comptime T: type, body: []const u8) T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        if (field.default_value_ptr) |ptr| {
            const default: *const field.type = @ptrCast(@alignCast(ptr));
            @field(result, field.name) = default.*;
        } else {
            @field(result, field.name) = switch (@typeInfo(field.type)) {
                .pointer => "",
                .float => 0,
                .int => 0,
                .bool => false,
                .optional => null,
                else => undefined,
            };
        }
    }
    if (body.len == 0) return result;

    var pairs = mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const eq_pos = mem.indexOfScalar(u8, pair, '=');
        const key = if (eq_pos) |pos| pair[0..pos] else pair;
        const raw_value = if (eq_pos) |pos| pair[pos + 1 ..] else "";
        const value = url.decode(raw_value);

        inline for (std.meta.fields(T)) |field| {
            if (mem.eql(u8, field.name, key)) {
                @field(result, field.name) = coerceField(field.type, value);
            }
        }
    }
    return result;
}


test "parse - basic GET request" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET /items HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(Method.get, req.method);
    try std.testing.expectEqualStrings("/items", req.path);
    try std.testing.expectEqualStrings("localhost", req.getHeader("Host").?);
}

test "parse - query string" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET /search?q=hello&page=2 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("q=hello&page=2", req.query_string.?);
    try std.testing.expectEqualStrings("hello", req.getQuery("q").?);
    try std.testing.expectEqualStrings("2", req.getQuery("page").?);
    try std.testing.expect(req.getQuery("missing") == null);
}

test "contentLength - valid" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("POST /data HTTP/1.1\r\nContent-Length: 42\r\n\r\n");
    const cl = try req.contentLength();
    try std.testing.expectEqual(@as(usize, 42), cl.?);
}

test "contentLength - missing header returns null" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET / HTTP/1.1\r\n\r\n");
    const cl = try req.contentLength();
    try std.testing.expect(cl == null);
}

test "contentLength - malformed returns error" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n");
    try std.testing.expectError(error.MalformedContentLength, req.contentLength());
}

test "parse - keep-alive default" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(req.keep_alive);
}

test "parse - connection close" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    try std.testing.expect(!req.keep_alive);
}

test "getHeader - case insensitive" {
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET / HTTP/1.1\r\nContent-Type: text/html\r\n\r\n");
    try std.testing.expectEqualStrings("text/html", req.getHeader("content-type").?);
    try std.testing.expectEqualStrings("text/html", req.getHeader("CONTENT-TYPE").?);
}

test "getParams - typed deserialization from query string" {
    const Params = struct {
        name: ?[]const u8 = null,
        page: ?[]const u8 = null,
        missing: ?[]const u8 = null,
    };
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET /items?name=Widget&page=2 HTTP/1.1\r\n\r\n");
    const params = req.getParams(Params);
    try std.testing.expectEqualStrings("Widget", params.name.?);
    try std.testing.expectEqualStrings("2", params.page.?);
    try std.testing.expect(params.missing == null);
}

test "getParams - numeric and bool coercion" {
    const Params = struct {
        limit: i32 = 0,
        active: bool = false,
        ratio: f64 = 0,
    };
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET /items?limit=25&active=true&ratio=3.14 HTTP/1.1\r\n\r\n");
    const params = req.getParams(Params);
    try std.testing.expectEqual(@as(i32, 25), params.limit);
    try std.testing.expect(params.active);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), params.ratio, 0.001);
}

test "getParams - empty query string" {
    const Params = struct { name: ?[]const u8 = null };
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("GET /items HTTP/1.1\r\n\r\n");
    const params = req.getParams(Params);
    try std.testing.expect(params.name == null);
}

test "getBody - form encoded" {
    const Body = struct {
        name: []const u8 = "",
        price: f64 = 0,
        active: bool = false,
    };
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("POST /items HTTP/1.1\r\nContent-Length: 30\r\n\r\n");
    var body_buf: [64]u8 = undefined;
    const body_bytes = "name=Widget&price=9.99&active=true";
    @memcpy(body_buf[0..body_bytes.len], body_bytes);
    req.body = body_buf[0..body_bytes.len];
    const body = try req.getBody(alloc, Body);
    try std.testing.expectEqualStrings("Widget", body.name);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), body.price, 0.001);
    try std.testing.expect(body.active);
}

test "getBody - JSON" {
    const Body = struct {
        name: []const u8,
        price: f64,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req = try Request.init(alloc);
    try req.parse("POST /items HTTP/1.1\r\n\r\n");
    req.body = "{\"name\":\"Widget\",\"price\":9.99}";
    const body = try req.getBody(alloc, Body);
    try std.testing.expectEqualStrings("Widget", body.name);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), body.price, 0.001);
}

test "getBody - empty body returns error" {
    const Body = struct { name: []const u8 = "" };
    const alloc = std.testing.allocator;
    var req = try Request.init(alloc);
    defer req.deinit();
    try req.parse("POST /items HTTP/1.1\r\n\r\n");
    try std.testing.expectError(error.EmptyBody, req.getBody(alloc, Body));
}
