
const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("bson");

pub const FieldType = enum {
    string,
    int,
    int32,
    double,
    float,
    boolean,
    date,
    object_id,
    array,
    object,
    binary,
    decimal128,
    null_type,
    uuid,
    timestamp,
};

pub const FieldRule = struct {
    field_type: FieldType = .string,
    required: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    enum_values: ?[]const []const u8 = null,
};

pub const FieldError = struct {
    field: []const u8,
    message: []const u8,
};

pub const ValidationError = struct {
    errors: []const FieldError,
    allocator: Allocator,

    pub fn deinit(self: *ValidationError) void {
        self.allocator.free(self.errors);
    }

    pub fn format(self: ValidationError, allocator: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "Validation failed: ");
        for (self.errors, 0..) |err, i| {
            if (i > 0) try buf.appendSlice(allocator, "; ");
            try buf.appendSlice(allocator, err.field);
            try buf.appendSlice(allocator, ": ");
            try buf.appendSlice(allocator, err.message);
        }
        return try buf.toOwnedSlice(allocator);
    }
};

pub fn Schema(comptime fields: []const struct { []const u8, FieldRule }) type {
    return struct {
        const Self = @This();
        pub const field_defs = fields;

        pub fn validate(allocator: Allocator, value: anytype) !?ValidationError {
            const T = @TypeOf(value);
            const info = @typeInfo(T);

            if (info != .@"struct") {
                @compileError("Schema.validate expects a struct, got " ++ @typeName(T));
            }

            var errors: std.ArrayList(FieldError) = .empty;
            errdefer errors.deinit(allocator);

            inline for (fields) |entry| {
                const name = entry[0];
                const rule = entry[1];

                if (@hasField(T, name)) {
                    const field_value = @field(value, name);
                    try validateField(allocator, name, rule, field_value, &errors);
                } else if (rule.required) {
                    try errors.append(allocator, .{ .field = name, .message = "is required" });
                }
            }

            if (errors.items.len > 0) {
                return ValidationError{
                    .errors = try errors.toOwnedSlice(allocator),
                    .allocator = allocator,
                };
            }
            errors.deinit(allocator);
            return null;
        }

        pub fn validateAndEncode(allocator: Allocator, value: anytype) ![]const u8 {
            if (try validate(allocator, value)) |*verr| {
                var ve = verr.*;
                ve.deinit();
                return error.ValidationFailed;
            }

            var encoder = try bson.Encoder.initWithCapacity(allocator, 4096);
            defer encoder.deinit();
            return try encoder.encode(value);
        }
    };
}

fn validateField(allocator: Allocator, name: []const u8, rule: FieldRule, value: anytype, errors: *std.ArrayList(FieldError)) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .optional) {
        if (value == null) {
            if (rule.required) {
                try errors.append(allocator, .{ .field = name, .message = "is required" });
            }
            return;
        }
        try validateField(allocator, name, rule, value.?, errors);
        return;
    }

    switch (rule.field_type) {
        .string => {
            if (!isStringType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'string'" });
                return;
            }
            if (comptime isStringType(T)) {
                const str: []const u8 = asSlice(value);
                if (rule.min_length) |ml| {
                    if (str.len < ml) {
                        try errors.append(allocator, .{ .field = name, .message = "too short" });
                    }
                }
                if (rule.max_length) |ml| {
                    if (str.len > ml) {
                        try errors.append(allocator, .{ .field = name, .message = "too long" });
                    }
                }
                if (rule.enum_values) |allowed| {
                    var found = false;
                    for (allowed) |ev| {
                        if (std.mem.eql(u8, str, ev)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try errors.append(allocator, .{ .field = name, .message = "not in allowed values" });
                    }
                }
            }
        },
        .int => {
            if (!isIntType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'int'" });
                return;
            }
            if (comptime isIntType(T)) {
                const num: f64 = @floatFromInt(value);
                if (rule.min) |m| {
                    if (num < m) try errors.append(allocator, .{ .field = name, .message = "below minimum" });
                }
                if (rule.max) |m| {
                    if (num > m) try errors.append(allocator, .{ .field = name, .message = "above maximum" });
                }
            }
        },
        .int32 => {
            if (!isIntType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'int32'" });
                return;
            }
            if (comptime isIntType(T)) {
                const num: f64 = @floatFromInt(value);
                if (num < -2147483648.0 or num > 2147483647.0) {
                    try errors.append(allocator, .{ .field = name, .message = "out of int32 range" });
                }
                if (rule.min) |m| {
                    if (num < m) try errors.append(allocator, .{ .field = name, .message = "below minimum" });
                }
                if (rule.max) |m| {
                    if (num > m) try errors.append(allocator, .{ .field = name, .message = "above maximum" });
                }
            }
        },
        .float, .double => {
            if (!isFloatType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'double'" });
                return;
            }
            if (comptime isFloatType(T)) {
                const num: f64 = @floatCast(value);
                if (rule.min) |m| {
                    if (num < m) try errors.append(allocator, .{ .field = name, .message = "below minimum" });
                }
                if (rule.max) |m| {
                    if (num > m) try errors.append(allocator, .{ .field = name, .message = "above maximum" });
                }
            }
        },
        .boolean => {
            if (T != bool) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'boolean'" });
            }
        },
        .date => {
            if (!isIntType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'date' (i64 ms timestamp)" });
                return;
            }
            if (comptime isIntType(T)) {
                const num: f64 = @floatFromInt(value);
                if (rule.min) |m| {
                    if (num < m) try errors.append(allocator, .{ .field = name, .message = "below minimum" });
                }
                if (rule.max) |m| {
                    if (num > m) try errors.append(allocator, .{ .field = name, .message = "above maximum" });
                }
            }
        },
        .object_id => {
            if (comptime isFixedArray(T, 12)) {
            } else if (comptime isStringType(T)) {
                const str: []const u8 = asSlice(value);
                if (str.len != 12) {
                    try errors.append(allocator, .{ .field = name, .message = "objectId must be 12 bytes" });
                }
            } else {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'object_id' ([12]u8)" });
            }
        },
        .decimal128 => {
            if (!comptime isFixedArray(T, 16)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'decimal128' ([16]u8)" });
            }
        },
        .uuid => {
            if (!comptime isFixedArray(T, 16)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'uuid' ([16]u8)" });
            }
        },
        .null_type => {
            try errors.append(allocator, .{ .field = name, .message = "expected null" });
        },
        .timestamp => {
            if (!isIntType(T)) {
                try errors.append(allocator, .{ .field = name, .message = "expected type 'timestamp' (u64)" });
            }
        },
        .array, .object, .binary => {},
    }
}

fn isStringType(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    const info = @typeInfo(T);
    if (info == .pointer) {
        if (info.pointer.size == .many or info.pointer.size == .slice) {
            return info.pointer.child == u8;
        }
        if (info.pointer.size == .one) {
            const child_info = @typeInfo(info.pointer.child);
            if (child_info == .array and child_info.array.child == u8) return true;
        }
    }
    return false;
}

fn isIntType(comptime T: type) bool {
    return @typeInfo(T) == .int or @typeInfo(T) == .comptime_int;
}

fn isFloatType(comptime T: type) bool {
    return @typeInfo(T) == .float or @typeInfo(T) == .comptime_float;
}

fn isFixedArray(comptime T: type, comptime expected_len: usize) bool {
    const info = @typeInfo(T);
    if (info == .array) {
        return info.array.child == u8 and info.array.len == expected_len;
    }
    return false;
}

fn asSlice(value: anytype) []const u8 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (T == []const u8 or T == []u8) return value;
    if (info == .pointer and info.pointer.size == .one) {
        return value;
    }
    return value;
}

