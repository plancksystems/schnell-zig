
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{ OutOfMemory, Empty };

        buf: []T,
        len: usize,
        pos: usize = 0,
        read_pos: usize = 0,
        allocator: Allocator,

        pub fn init(allocator: Allocator, cap: usize) !Self {
            return Self{
                .buf = try allocator.alloc(T, cap),
                .len = cap,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
            self.buf = &[_]T{};
            self.len = 0;
            self.pos = 0;
            self.read_pos = 0;
        }

        pub fn write(self: *Self, item: T) !void {
            if (self.isFull()) return error.OutOfMemory;
            self.buf[self.pos] = item;
            self.pos = (self.pos + 1) % self.len;
        }

        pub fn writeMany(self: *Self, items: []const T) !void {
            for (items) |item| try self.write(item);
        }

        pub fn read(self: *Self) !T {
            if (self.isEmpty()) return error.Empty;
            const item = self.buf[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.len;
            return item;
        }

        pub fn peek(self: *const Self) !T {
            if (self.isEmpty()) return error.Empty;
            return self.buf[self.read_pos];
        }

        pub fn readN(self: *Self, n: usize) ![]T {
            if (self.count() < n) return error.Empty;
            var result = try self.allocator.alloc(T, n);
            for (0..n) |i| result[i] = try self.read();
            return result;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.pos == self.read_pos;
        }

        pub fn isFull(self: *const Self) bool {
            return (self.pos + 1) % self.len == self.read_pos;
        }

        pub fn count(self: *const Self) usize {
            return if (self.pos >= self.read_pos)
                self.pos - self.read_pos
            else
                self.len - self.read_pos + self.pos;
        }

        pub fn available(self: *const Self) usize {
            return self.len - self.count() - 1;
        }

        pub fn capacity(self: *const Self) usize {
            return self.len;
        }

        pub fn reset(self: *Self) void {
            self.pos = 0;
            self.read_pos = 0;
        }

        pub fn slice(self: *Self) []T {
            if (self.isEmpty()) return &[_]T{};
            if (self.pos > self.read_pos) return self.buf[self.read_pos..self.pos];
            return self.buf[self.read_pos..self.len];
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            const n = self.count();
            if (n == 0) return &[_]T{};
            var result = try self.allocator.alloc(T, n);
            for (0..n) |i| result[i] = try self.read();
            return result;
        }
    };
}

pub const Buffer = struct {
    pub const Error = error{ OutOfMemory, EndOfStream };

    buf: []u8,
    len: usize,
    pos: usize = 0,
    read_pos: usize = 0,
    allocator: Allocator,

    pub const Writer = struct {
        context: *Buffer,

        pub fn writeInt(self: Writer, comptime T: type, value: T, endian: std.builtin.Endian) !void {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, endian);
            _ = try self.context.write(&bytes);
        }

        pub fn writeAll(self: Writer, bytes: []const u8) !void {
            _ = try self.context.write(bytes);
        }

        pub fn writeString(self: Writer, str: []const u8) !void {
            try self.writeInt(u32, @intCast(str.len), .little);
            _ = try self.context.write(str);
        }

        pub fn writeEscaped(self: Writer, s: []const u8) !void {
            for (s) |c| switch (c) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                '"' => try self.writeAll("&quot;"),
                '\'' => try self.writeAll("&#39;"),
                else => _ = try self.context.write(&.{c}),
            };
        }

        pub fn writeIntText(self: Writer, value: anytype) !void {
            var buf: [32]u8 = undefined;
            const len = std.fmt.formatIntBuf(&buf, value, 10, .lower, .{});
            try self.writeAll(buf[0..len]);
        }

        pub fn writeFloatText(self: Writer, value: anytype) !void {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
            try self.writeAll(s);
        }

        pub fn writeValue(self: Writer, value: anytype) !void {
            const T = @TypeOf(value);
            const info = @typeInfo(T);
            if (T == []const u8 or T == []u8) {
                try self.writeEscaped(value);
            } else if (info == .optional) {
                if (value) |v| try self.writeValue(v);
            } else if (info == .int or info == .comptime_int) {
                try self.writeIntText(value);
            } else if (info == .float or info == .comptime_float) {
                try self.writeFloatText(value);
            } else if (info == .bool) {
                try self.writeAll(if (value) "true" else "false");
            } else {
                try self.writeAll("[unsupported]");
            }
        }
    };

    pub const Reader = struct {
        context: *Buffer,

        pub fn readInt(self: Reader, comptime T: type, endian: std.builtin.Endian) !T {
            var bytes: [@sizeOf(T)]u8 = undefined;
            try self.readAll(&bytes);
            return std.mem.readInt(T, &bytes, endian);
        }

        pub fn readAll(self: Reader, out: []u8) !void {
            var index: usize = 0;
            while (index < out.len) {
                const n = try self.context.read(out[index..]);
                if (n == 0) return error.EndOfStream;
                index += n;
            }
        }
    };

    pub fn init(allocator: Allocator, size: usize) !Buffer {
        return Buffer{
            .buf = try allocator.alloc(u8, size),
            .len = size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.buf);
        self.buf = &[_]u8{};
        self.len = 0;
        self.pos = 0;
        self.read_pos = 0;
    }

    pub fn writer(self: *Buffer) Writer {
        return .{ .context = self };
    }

    pub fn reader(self: *Buffer) Reader {
        return .{ .context = self };
    }

    pub fn write(self: *Buffer, bytes: []const u8) !usize {
        if (self.pos + bytes.len > self.len) return error.OutOfMemory;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        return bytes.len;
    }

    pub fn read(self: *Buffer, out: []u8) !usize {
        const available = self.pos - self.read_pos;
        if (available == 0) return 0;
        const n = @min(out.len, available);
        @memcpy(out[0..n], self.buf[self.read_pos..][0..n]);
        self.read_pos += n;
        return n;
    }

    pub fn reset(self: *Buffer) void {
        self.pos = 0;
        self.read_pos = 0;
    }

    pub fn capacity(self: *const Buffer) usize {
        return self.len;
    }

    pub fn used(self: *const Buffer) usize {
        return self.pos;
    }

    pub fn slice(self: *const Buffer) []u8 {
        return self.buf[0..self.pos];
    }
};


test "RingBuffer - basic write and read" {
    var rb = try RingBuffer(u32).init(std.testing.allocator, 5);
    defer rb.deinit();

    try rb.write(1);
    try rb.write(2);
    try rb.write(3);
    try std.testing.expectEqual(@as(usize, 3), rb.count());
    try std.testing.expectEqual(@as(u32, 1), try rb.read());
    try std.testing.expectEqual(@as(u32, 2), try rb.read());
    try std.testing.expectEqual(@as(u32, 3), try rb.read());
    try std.testing.expect(rb.isEmpty());
}

test "RingBuffer - full and overflow" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 4);
    defer rb.deinit();

    try rb.write(1);
    try rb.write(2);
    try rb.write(3);
    try std.testing.expect(rb.isFull());
    try std.testing.expectError(error.OutOfMemory, rb.write(4));
}

test "RingBuffer - peek does not consume" {
    var rb = try RingBuffer(u32).init(std.testing.allocator, 4);
    defer rb.deinit();

    try rb.write(42);
    try std.testing.expectEqual(@as(u32, 42), try rb.peek());
    try std.testing.expectEqual(@as(u32, 42), try rb.peek());
    try std.testing.expectEqual(@as(usize, 1), rb.count());
}

test "RingBuffer - wrap around" {
    var rb = try RingBuffer(u32).init(std.testing.allocator, 4);
    defer rb.deinit();

    try rb.write(1);
    try rb.write(2);
    try rb.write(3);
    _ = try rb.read();
    _ = try rb.read();
    try rb.write(4);
    try rb.write(5);
    try std.testing.expectEqual(@as(u32, 3), try rb.read());
    try std.testing.expectEqual(@as(u32, 4), try rb.read());
    try std.testing.expectEqual(@as(u32, 5), try rb.read());
}

test "Buffer - basic write and read" {
    var buf = try Buffer.init(std.testing.allocator, 16);
    defer buf.deinit();

    _ = try buf.write("hello");
    try std.testing.expectEqual(@as(usize, 5), buf.used());
    try std.testing.expectEqualStrings("hello", buf.slice());

    var out: [5]u8 = undefined;
    const n = try buf.read(out[0..]);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "Buffer - reset clears positions" {
    var buf = try Buffer.init(std.testing.allocator, 8);
    defer buf.deinit();

    _ = try buf.write("abcd");
    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.used());
    _ = try buf.write("xy");
    try std.testing.expectEqualStrings("xy", buf.slice());
}

test "Buffer - overflow returns error" {
    var buf = try Buffer.init(std.testing.allocator, 4);
    defer buf.deinit();

    _ = try buf.write("abcd");
    try std.testing.expectError(error.OutOfMemory, buf.write("e"));
}

test "Buffer - Writer and Reader typed access" {
    var buf = try Buffer.init(std.testing.allocator, 32);
    defer buf.deinit();

    const w = buf.writer();
    try w.writeInt(u32, 0xDEADBEEF, .little);
    try w.writeAll("data");

    const r = buf.reader();
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readInt(u32, .little));
    var out: [4]u8 = undefined;
    try r.readAll(&out);
    try std.testing.expectEqualStrings("data", &out);
}

test "Buffer - writeString length prefix" {
    var buf = try Buffer.init(std.testing.allocator, 32);
    defer buf.deinit();

    const w = buf.writer();
    try w.writeString("hello");
    const s = buf.slice();
    try std.testing.expectEqual(@as(usize, 9), s.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, s[0..4], .little));
    try std.testing.expectEqualStrings("hello", s[4..9]);
}

test "Buffer - partial reads" {
    var buf = try Buffer.init(std.testing.allocator, 10);
    defer buf.deinit();

    _ = try buf.write("abcdef");
    var out: [3]u8 = undefined;
    _ = try buf.read(out[0..]);
    try std.testing.expectEqualStrings("abc", out[0..]);
    _ = try buf.read(out[0..]);
    try std.testing.expectEqualStrings("def", out[0..]);
    const n = try buf.read(out[0..]);
    try std.testing.expectEqual(@as(usize, 0), n);
}
