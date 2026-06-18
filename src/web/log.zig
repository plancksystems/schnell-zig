
const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

extern fn host_log(level: i32, ptr: [*]const u8, len: u32) void;

fn nativeLog(level: Level, msg: []const u8) void {
    const prefix = switch (level) {
        .debug => "[DEBUG]",
        .info => "[INFO]",
        .warn => "[WARN]",
        .err => "[ERROR]",
    };
    std.debug.print("{s} {s}\n", .{ prefix, msg });
}

fn writeLog(level: Level, msg: []const u8) void {
    if (builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64) {
        host_log(@intFromEnum(level), msg.ptr, @intCast(msg.len));
    } else {
        nativeLog(level, msg);
    }
}

pub fn log(level: Level, msg: []const u8) void {
    writeLog(level, msg);
}

pub fn logFmt(level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    writeLog(level, msg);
}

pub fn debug(msg: []const u8) void {
    writeLog(.debug, msg);
}

pub fn info(msg: []const u8) void {
    writeLog(.info, msg);
}

pub fn warn(msg: []const u8) void {
    writeLog(.warn, msg);
}

pub fn err(msg: []const u8) void {
    writeLog(.err, msg);
}
