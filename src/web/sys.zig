
const std = @import("std");
const builtin = @import("builtin");
const schnell = @import("schnell");

const is_wasm = builtin.target.cpu.arch == .wasm32;

extern fn host_now_unix_s() i64;
extern fn host_random_bytes(ptr: [*]u8, len: u32) void;

pub fn nowUnixSeconds() i64 {
    if (comptime is_wasm) {
        return host_now_unix_s();
    } else {
        const io = schnell.currentIo() orelse @panic("web.sys.nowUnixSeconds: no current Io — call from inside an Io context");
        return std.Io.Clock.now(.real, io).toSeconds();
    }
}

pub fn nowUnixMilliSeconds() i64 {
    if (comptime is_wasm) {
        return host_now_unix_s();
    } else {
        const io = schnell.currentIo() orelse @panic("web.sys.nowUnixSeconds: no current Io — call from inside an Io context");
        return std.Io.Clock.now(.real, io).toMilliseconds();
    }
}

pub fn randomBytes(buf: []u8) void {
    if (comptime is_wasm) {
        host_random_bytes(buf.ptr, @intCast(buf.len));
    } else {
        const io = schnell.currentIo() orelse @panic("web.sys.randomBytes: no current Io — call from inside an Io context");
        std.Io.random(io, buf);
    }
}
