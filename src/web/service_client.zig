
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

extern fn host_call_service(
    svc_ptr: [*]const u8,    svc_len:    u32,
    path_ptr: [*]const u8,   path_len:   u32,
    method_ptr: [*]const u8, method_len: u32,
    body_ptr: [*]const u8,   body_len:   u32,
    hdr_ptr: [*]const u8,    hdr_len:    u32,
    out_ptr: [*]u8,          out_cap:    u32
) i32;

pub const Error = error{
    UnknownUpstream,
    ResponseTooLarge,
    Timeout,
    CircuitOpen,
    BulkheadFull,
    TransportError,
    RecursionDepthExceeded,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub fn call(
    service: []const u8,
    path: []const u8,
    method: []const u8,
    body: []const u8,
    out_buf: []u8
) Error!Response {
    return callWithHeaders(service, path, method, body, "", out_buf);
}

pub fn callWithHeaders(
    service: []const u8,
    path: []const u8,
    method: []const u8,
    body: []const u8,
    headers: []const u8,
    out_buf: []u8
) Error!Response {
    if (comptime !is_wasm) {
        _ = .{ service, path, method, body, headers, out_buf };
        return error.UnknownUpstream;
    }
    const rc = host_call_service(
        service.ptr,
        @intCast(service.len),
        path.ptr,
        @intCast(path.len),
        method.ptr,
        @intCast(method.len),
        body.ptr,
        @intCast(body.len),
        headers.ptr,
        @intCast(headers.len),
        out_buf.ptr,
        @intCast(out_buf.len),
    );

    if (rc >= 0) {
        const n: usize = @intCast(rc);
        if (n < 4) return error.TransportError;
        const status_u32 = std.mem.readInt(u32, out_buf[0..4], .little);
        return .{
            .status = @intCast(status_u32),
            .body = out_buf[4..n],
        };
    }

    return switch (rc) {
        -1 => error.UnknownUpstream,
        -2 => error.ResponseTooLarge,
        -3 => error.Timeout,
        -4 => error.CircuitOpen,
        -5 => error.BulkheadFull,
        -6 => error.TransportError,
        -7 => error.RecursionDepthExceeded,
        else => error.TransportError,
    };
}
