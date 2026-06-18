
const std = @import("std");
const Allocator = std.mem.Allocator;
const url = @import("schnell").Url;

pub const Route = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
};

pub fn ParseResult(comptime ParamsType: ?type, comptime BodyType: ?type) type {
    return struct {
        route: Route,
        params: if (ParamsType) |P| P else void,
        body: if (BodyType) |B| B else void,
    };
}

pub fn parse(
    allocator: Allocator,
    raw: []const u8,
    comptime ParamsType: ?type,
    comptime BodyType: ?type
) !ParseResult(ParamsType, BodyType) {
    const newline_pos = std.mem.indexOfScalar(u8, raw, '\n');
    const request_line = if (newline_pos) |pos| raw[0..pos] else raw;
    const body_bytes = if (newline_pos) |pos| raw[pos + 1 ..] else "";

    const space_pos = std.mem.indexOfScalar(u8, request_line, ' ') orelse
        return error.MalformedRequest;
    const method = request_line[0..space_pos];
    const path_with_query = request_line[space_pos + 1 ..];

    const question_pos = std.mem.indexOfScalar(u8, path_with_query, '?');
    const path = if (question_pos) |pos| path_with_query[0..pos] else path_with_query;
    const query_string = if (question_pos) |pos| path_with_query[pos + 1 ..] else "";

    const route = Route{
        .method = method,
        .path = path,
        .query = query_string,
        .body = body_bytes,
    };

    const params = if (ParamsType) |P| parseQueryParams(P, query_string) else {};

    const body = if (BodyType) |B| blk: {
        if (body_bytes.len == 0) return error.EmptyBody;
        if (isJson(body_bytes)) {
            break :blk try parseJsonBody(B, allocator, body_bytes);
        } else {
            break :blk try parseFormBody(B, allocator, body_bytes);
        }
    } else {};

    return .{
        .route = route,
        .params = params,
        .body = body,
    };
}

pub fn extractPathParams(comptime P: type, pattern: []const u8, path: []const u8, params: *P) void {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pat_seg = pat_it.next() orelse break;
        const path_seg = path_it.next() orelse break;

        if (pat_seg.len > 0 and pat_seg[0] == ':') {
            const param_name = pat_seg[1..];
            inline for (std.meta.fields(P)) |field| {
                if (std.mem.eql(u8, field.name, param_name)) {
                    @field(params, field.name) = path_seg;
                }
            }
        }
    }
}

fn parsePairs(
    input: []const u8,
    ctx: anytype,
    comptime onPair: fn (@TypeOf(ctx), key: []const u8, raw_value: []const u8) anyerror!void,
) !void {
    if (input.len == 0) return;

    var pairs_iter = std.mem.splitScalar(u8, input, '&');
    while (pairs_iter.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_pos = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq_pos) |pos| pair[0..pos] else pair;
        const raw_value = if (eq_pos) |pos| pair[pos + 1 ..] else "";

        try onPair(ctx, key, raw_value);
    }
}

fn parseQueryParams(comptime P: type, query: []const u8) P {
    var result: P = .{};

    const Ctx = struct {
        result: *P,
        fn onPair(ctx: @This(), key: []const u8, value: []const u8) anyerror!void {
            inline for (std.meta.fields(P)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    @field(ctx.result, field.name) = value;
                }
            }
        }
    };

    parsePairs(query, Ctx{ .result = &result }, Ctx.onPair) catch unreachable;

    return result;
}

fn isJson(body: []const u8) bool {
    for (body) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        return c == '{' or c == '[';
    }
    return false;
}

fn parseJsonBody(comptime B: type, allocator: Allocator, body: []const u8) !B {
    const parsed = try std.json.parseFromSlice(B, allocator, body, .{});
    return parsed.value;
}

fn parseFormBody(comptime B: type, allocator: Allocator, body: []const u8) !B {
    var result: B = undefined;
    inline for (std.meta.fields(B)) |field| {
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

    const Ctx = struct {
        result: *B,
        allocator: Allocator,
        fn onPair(ctx: @This(), key: []const u8, raw_value: []const u8) anyerror!void {
            const value = try url.decodeAlloc(ctx.allocator, raw_value);
            inline for (std.meta.fields(B)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    @field(ctx.result, field.name) = coerceField(field.type, value);
                }
            }
        }
    };

    try parsePairs(body, Ctx{ .result = &result, .allocator = allocator }, Ctx.onPair);

    return result;
}

fn coerceField(comptime T: type, value: []const u8) T {
    const info = @typeInfo(T);

    if (T == []const u8 or T == []u8) return value;

    if (info == .optional) {
        if (value.len == 0) return null;
        return coerceField(info.optional.child, value);
    }

    if (info == .float) {
        return std.fmt.parseFloat(T, value) catch 0;
    }

    if (info == .int) {
        return std.fmt.parseInt(T, value, 10) catch 0;
    }

    if (info == .bool) {
        return std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "on") or
            std.mem.eql(u8, value, "1");
    }

    return undefined;
}


test "parse GET with query params" {
    const Params = struct {
        name: ?[]const u8 = null,
        limit: ?[]const u8 = null,
    };

    const raw = "GET /items?name=foo&limit=10\n";
    const result = try parse(std.testing.allocator, raw, Params, null);

    try std.testing.expectEqualStrings("GET", result.route.method);
    try std.testing.expectEqualStrings("/items", result.route.path);
    try std.testing.expectEqualStrings("name=foo&limit=10", result.route.query);
    try std.testing.expectEqualStrings("", result.route.body);
    try std.testing.expectEqualStrings("foo", result.params.name.?);
    try std.testing.expectEqualStrings("10", result.params.limit.?);
}

test "parse POST with JSON body" {
    const Body = struct {
        name: []const u8,
        price: f64,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "POST /items\n{\"name\":\"Widget\",\"price\":9.99}";
    const result = try parse(arena.allocator(), raw, null, Body);

    try std.testing.expectEqualStrings("POST", result.route.method);
    try std.testing.expectEqualStrings("/items", result.route.path);
    try std.testing.expectEqualStrings("", result.route.query);
    try std.testing.expectEqualStrings("Widget", result.body.name);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), result.body.price, 0.001);
}

test "parse POST with form-encoded body" {
    const Body = struct {
        name: []const u8,
        price: f64,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = "POST /items\nname=Widget&price=9.99";
    const result = try parse(allocator, raw, null, Body);

    try std.testing.expectEqualStrings("POST", result.route.method);
    try std.testing.expectEqualStrings("Widget", result.body.name);
    try std.testing.expectApproxEqAbs(@as(f64, 9.99), result.body.price, 0.001);
}

test "extractPathParams" {
    const Params = struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    var params = Params{};
    extractPathParams(Params, "/items/:id", "/items/abc123", &params);

    try std.testing.expectEqualStrings("abc123", params.id.?);
    try std.testing.expect(params.name == null);
}

test "extractPathParams multiple segments" {
    const Params = struct {
        org: ?[]const u8 = null,
        id: ?[]const u8 = null,
    };

    var params = Params{};
    extractPathParams(Params, "/orgs/:org/items/:id", "/orgs/acme/items/42", &params);

    try std.testing.expectEqualStrings("acme", params.org.?);
    try std.testing.expectEqualStrings("42", params.id.?);
}

test "parse GET with path param and no query" {
    const raw = "GET /items/abc123\n";
    const result = try parse(std.testing.allocator, raw, null, null);

    try std.testing.expectEqualStrings("GET", result.route.method);
    try std.testing.expectEqualStrings("/items/abc123", result.route.path);
    try std.testing.expectEqualStrings("", result.route.query);
    try std.testing.expectEqualStrings("", result.route.body);
}

test "parse DELETE" {
    const raw = "DELETE /items/abc123\n";
    const result = try parse(std.testing.allocator, raw, null, null);

    try std.testing.expectEqualStrings("DELETE", result.route.method);
    try std.testing.expectEqualStrings("/items/abc123", result.route.path);
}

test "parse with no newline" {
    const raw = "GET /health";
    const result = try parse(std.testing.allocator, raw, null, null);

    try std.testing.expectEqualStrings("GET", result.route.method);
    try std.testing.expectEqualStrings("/health", result.route.path);
    try std.testing.expectEqualStrings("", result.route.body);
}

test "parse query params with missing key" {
    const Params = struct {
        name: ?[]const u8 = null,
        missing: ?[]const u8 = null,
    };

    const raw = "GET /items?name=bar\n";
    const result = try parse(std.testing.allocator, raw, Params, null);

    try std.testing.expectEqualStrings("bar", result.params.name.?);
    try std.testing.expect(result.params.missing == null);
}

test "malformed request with no space" {
    const result = parse(std.testing.allocator, "GETITEMS", null, null);
    try std.testing.expectError(error.MalformedRequest, result);
}

test "form body with bool and int fields" {
    const Body = struct {
        active: bool,
        count: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "POST /update\nactive=true&count=42";
    const result = try parse(arena.allocator(), raw, null, Body);

    try std.testing.expect(result.body.active);
    try std.testing.expectEqual(@as(i32, 42), result.body.count);
}

test "isJson detection" {
    try std.testing.expect(isJson("{\"name\":\"foo\"}"));
    try std.testing.expect(isJson("[1,2,3]"));
    try std.testing.expect(isJson("  {\"a\":1}"));
    try std.testing.expect(!isJson("name=foo&bar=baz"));
    try std.testing.expect(!isJson("hello world"));
}
