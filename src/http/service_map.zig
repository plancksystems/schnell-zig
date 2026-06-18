
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = @import("../client.zig").Client;

const log = std.log.scoped(.service_map);

pub const ServiceMapConfig = struct {
    url: []const u8,
    app: []const u8,
    host: []const u8 = "127.0.0.1",
};

pub const ServiceMap = struct {
    allocator: Allocator,
    ports: std.StringHashMap(u16),
    host: []const u8,

    pub fn init(allocator: Allocator, io: Io, config: ServiceMapConfig) !ServiceMap {
        var map = ServiceMap{
            .allocator = allocator,
            .ports = std.StringHashMap(u16).init(allocator),
            .host = config.host,
        };

        const api_url = try std.fmt.allocPrint(allocator, "{s}/api/apps", .{config.url});
        defer allocator.free(api_url);

        var resp = Client.request(allocator, io, .{
            .method = "GET",
            .url = api_url,
        }) catch |err| {
            log.err("service discovery failed: {s} - {}", .{ api_url, err });
            return err;
        };
        defer resp.deinit();

        if (resp.status != 200) {
            log.err("service discovery: {s} returned {d}", .{ api_url, resp.status });
            return error.ServiceDiscoveryFailed;
        }

        try parseServices(&map, resp.body, config.app);

        const count = map.ports.count();
        if (count == 0) {
            log.warn("service discovery: no services found for app '{s}'", .{config.app});
        } else {
            log.info("service discovery: found {d} services for app '{s}'", .{ count, config.app });
        }

        return map;
    }

    pub fn deinit(self: *ServiceMap) void {
        var it = self.ports.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ports.deinit();
    }

    pub fn baseAlloc(self: *const ServiceMap, allocator: Allocator, service_name: []const u8) ![]const u8 {
        const svc_port = self.ports.get(service_name) orelse {
            log.warn("service '{s}' not found in service map", .{service_name});
            return error.ServiceNotFound;
        };
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ self.host, svc_port });
    }

    pub fn urlAlloc(self: *const ServiceMap, allocator: Allocator, service_name: []const u8, path: []const u8) ![]const u8 {
        const svc_port = self.ports.get(service_name) orelse {
            log.warn("service '{s}' not found in service map", .{service_name});
            return error.ServiceNotFound;
        };
        return std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ self.host, svc_port, path });
    }

    pub fn port(self: *const ServiceMap, service_name: []const u8) u16 {
        return self.ports.get(service_name) orelse 0;
    }
};

fn parseServices(map: *ServiceMap, body: []const u8, app_name: []const u8) !void {
    
    const app_marker = try findAppSection(body, app_name) orelse return;

    const svc_start = std.mem.indexOf(u8, body[app_marker..], "\"services\":[") orelse return;
    const svc_array_start = app_marker + svc_start + "\"services\":[".len;

    var pos = svc_array_start;
    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == '\t' or body[pos] == ',')) pos += 1;
        if (pos >= body.len or body[pos] == ']') break;

        if (body[pos] != '{') break;
        const obj_start = pos;
        var depth: u32 = 1;
        pos += 1;
        while (pos < body.len and depth > 0) : (pos += 1) {
            if (body[pos] == '{') depth += 1;
            if (body[pos] == '}') depth -= 1;
        }
        const obj = body[obj_start..pos];

        const name = extractJsonString(obj, "name") orelse continue;
        const wasm_port = extractJsonInt(obj, "wasm_port") orelse continue;
        if (wasm_port == 0) continue;

        const duped_name = try map.allocator.dupe(u8, name);
        try map.ports.put(duped_name, @intCast(wasm_port));

        log.info("service discovery: {s} → port {d}", .{ name, wasm_port });
    }
}

fn findAppSection(body: []const u8, app_name: []const u8) !?usize {
    var search_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"name\":\"{s}\"", .{app_name}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;

    var i = idx;
    while (i > 0) : (i -= 1) {
        if (body[i] == '{') return i;
    }
    return null;
}

fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfScalarPos(u8, obj, val_start, '"') orelse return null;
    return obj[val_start..val_end];
}

fn extractJsonInt(obj: []const u8, key: []const u8) ?i32 {
    var key_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = start + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    var end = i;
    if (end < obj.len and obj[end] == '-') end += 1;
    while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i32, obj[i..end], 10) catch null;
}
