
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.config);

pub const LoadError = error{
    UnknownSection,
    UnknownKey,
};

pub fn load(comptime T: type, allocator: Allocator, io: Io) !T {
    const content = try Io.Dir.readFileAlloc(.cwd(), io, "app.yaml", allocator, .unlimited);
    defer allocator.free(content);
    log.info("config: loaded {d} bytes from app.yaml", .{content.len});

    var result: T = .{};
    try parseYaml(T, allocator, content, &result);
    return result;
}

fn parseYaml(comptime T: type, allocator: Allocator, content: []const u8, result: *T) !void {
    var current_section: ?[]const u8 = null;
    var line_no: u32 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const is_indented = raw_line.len > 0 and (raw_line[0] == ' ' or raw_line[0] == '\t');

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const raw_val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const val = if (raw_val.len >= 2 and raw_val[0] == '"' and raw_val[raw_val.len - 1] == '"')
            raw_val[1 .. raw_val.len - 1]
        else
            raw_val;

        if (!is_indented) {
            if (val.len == 0) {
                if (!isKnownSection(T, key)) {
                    log.debug("config line {d}: unknown section '{s}'", .{ line_no, key });
                    return error.UnknownSection;
                }
                current_section = key;
                continue;
            }
            current_section = null;
            continue;
        }

        const section = current_section orelse continue;
        try setField(T, allocator, result, section, key, val, line_no);
    }
}

fn isKnownSection(comptime T: type, name: []const u8) bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn setField(
    comptime T: type,
    allocator: Allocator,
    result: *T,
    section: []const u8,
    key: []const u8,
    val: []const u8,
    line_no: u32
) !void {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields) |field| {
        const FieldType = field.type;
        const SectionType = UnwrapOptional(FieldType);
        const section_info = @typeInfo(SectionType);

        if (comptime section_info != .@"struct") continue;

        if (std.mem.eql(u8, field.name, section)) {
            if (@typeInfo(FieldType) == .optional) {
                if (@field(result, field.name) == null) {
                    @field(result, field.name) = .{};
                }
            }

            const section_fields = section_info.@"struct".fields;
            inline for (section_fields) |sfield| {
                if (std.mem.eql(u8, sfield.name, key)) {
                    if (@typeInfo(FieldType) == .optional) {
                        const target = &@field(@field(result, field.name).?, sfield.name);
                        try assignValue(@TypeOf(target.*), allocator, target, val);
                    } else {
                        const target = &@field(@field(result, field.name), sfield.name);
                        try assignValue(@TypeOf(target.*), allocator, target, val);
                    }
                    return;
                }
            }
            log.debug("config line {d}: unknown key '{s}' in section '{s}'", .{ line_no, key, section });
            return error.UnknownKey;
        }
    }
}

fn UnwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

fn assignValue(comptime T: type, allocator: Allocator, target: *T, val: []const u8) !void {
    if (T == []const u8 or T == ?[]const u8) {
        target.* = try allocator.dupe(u8, val);
    } else if (T == u16 or T == u32 or T == u64 or T == usize or T == i32 or T == i64) {
        target.* = std.fmt.parseInt(T, val, 10) catch return;
    } else if (T == bool) {
        target.* = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    } else if (T == f64) {
        target.* = std.fmt.parseFloat(f64, val) catch return;
    }
}


const testing = std.testing;

const TestConfig = struct {
    server: ServerSection = .{},
    oauth: ?OAuthSection = null,

    const ServerSection = struct {
        port: u16 = 8000,
        static_dir: []const u8 = "public",
    };

    const OAuthSection = struct {
        client_id: []const u8 = "",
        client_secret: []const u8 = "",
    };
};

test "Config: parse basic sections + keys" {
    const yaml =
        \\server:
        \\  port: 9000
        \\  static_dir: assets
        \\oauth:
        \\  client_id: "abc123"
        \\  client_secret: secret456
    ;

    var result: TestConfig = .{};
    try parseYaml(TestConfig, testing.allocator, yaml, &result);

    try testing.expectEqual(@as(u16, 9000), result.server.port);
    try testing.expectEqualStrings("assets", result.server.static_dir);
    try testing.expectEqualStrings("abc123", result.oauth.?.client_id);
    try testing.expectEqualStrings("secret456", result.oauth.?.client_secret);

    testing.allocator.free(result.server.static_dir);
    testing.allocator.free(result.oauth.?.client_id);
    testing.allocator.free(result.oauth.?.client_secret);
}

test "Config: unknown section produces error" {
    var result: TestConfig = .{};
    const yaml = "bogus:\n  key: val\n";
    try testing.expectError(error.UnknownSection, parseYaml(TestConfig, testing.allocator, yaml, &result));
}

test "Config: unknown key in known section produces error" {
    var result: TestConfig = .{};
    const yaml = "server:\n  bogus_key: val\n";
    try testing.expectError(error.UnknownKey, parseYaml(TestConfig, testing.allocator, yaml, &result));
}

test "Config: optional section left null when absent" {
    var result: TestConfig = .{};
    const yaml = "server:\n  port: 3000\n";
    try parseYaml(TestConfig, testing.allocator, yaml, &result);
    try testing.expectEqual(@as(u16, 3000), result.server.port);
    try testing.expect(result.oauth == null);
}

test "Config: comments and blank lines ignored" {
    var result: TestConfig = .{};
    const yaml =
        \\# This is a comment
        \\
        \\server:
        \\  # Another comment
        \\  port: 7777
    ;
    try parseYaml(TestConfig, testing.allocator, yaml, &result);
    try testing.expectEqual(@as(u16, 7777), result.server.port);
}
