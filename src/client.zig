
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const tls = @import("tls");

const log = std.log.scoped(.client);

pub const ClientResponse = struct {
    status: u16,
    headers: []Header,
    body: []const u8,
    allocator: Allocator,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn header(self: *const ClientResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn deinit(self: *ClientResponse) void {
        if (self.headers.len > 0) self.allocator.free(self.headers);
        if (self.body.len > 0) self.allocator.free(self.body);
    }
};

pub const RequestOptions = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const [2][]const u8 = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    insecure: bool = false,
    request_id: ?[]const u8 = null,
};

pub const RetryOptions = struct {
    max_attempts: u32 = 3,
    initial_backoff_ms: u32 = 200,
    max_backoff_ms: u32 = 5_000,
    retry_on_5xx: bool = true,
    retry_on_429: bool = true,
    retry_on_network_error: bool = true,
};

pub const ParsedUrl = struct {
    is_https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

var system_ca_cache: ?tls.config.cert.Bundle = null;
var system_ca_cache_loaded_ms: i64 = 0;
var system_ca_cache_mutex: Io.Mutex = .init;
const system_ca_ttl_ms: i64 = 24 * 60 * 60 * 1000;

pub fn getSystemRootCa(io: Io) !tls.config.cert.Bundle {
    try system_ca_cache_mutex.lock(io);
    defer system_ca_cache_mutex.unlock(io);

    const now = Io.Clock.now(.real, io).toMilliseconds();
    if (system_ca_cache) |b| {
        if (now - system_ca_cache_loaded_ms < system_ca_ttl_ms) return b;
    }
    const bundle = try tls.config.cert.fromSystem(std.heap.smp_allocator, io);
    system_ca_cache = bundle;
    system_ca_cache_loaded_ms = now;
    return bundle;
}

pub fn resolveHost(io: Io, host: []const u8, port: u16) !net.IpAddress {
    if (net.IpAddress.parseIp4(host, port)) |addr| {
        return addr;
    } else |_| {}

    const HostName = net.HostName;
    const hn = HostName.init(host) catch return error.InvalidHost;

    var backing: [16]HostName.LookupResult = undefined;
    var resolved: Io.Queue(HostName.LookupResult) = .init(&backing);
    var name_buf: [HostName.max_len]u8 = undefined;

    log.debug("dns lookup start: {s}:{d}", .{ host, port });
    hn.lookup(io, &resolved, .{
        .port = port,
        .canonical_name_buffer = &name_buf,
    }) catch |err| {
        log.err("DNS lookup failed for {s}: {}", .{ host, err });
        return error.HostResolutionFailed;
    };

    while (resolved.getOne(io)) |result| {
        switch (result) {
            .address => |addr| {
                log.debug("dns resolved: {s} -> {f}", .{ host, addr });
                return addr;
            },
            .canonical_name => continue,
        }
    } else |err| switch (err) {
        error.Closed => {
            log.err("DNS lookup for {s}: no addresses returned", .{host});
            return error.HostResolutionFailed;
        },
        error.Canceled => return error.HostResolutionFailed,
    }
    return error.HostResolutionFailed;
}

pub fn parseUrl(url: []const u8) !ParsedUrl {
    var rest = url;
    var is_https = false;

    if (std.mem.startsWith(u8, rest, "https://")) {
        is_https = true;
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else {
        return error.InvalidUrl;
    }

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";

    var host: []const u8 = host_port;
    var port: u16 = if (is_https) 443 else 80;

    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        host = host_port[0..colon];
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidUrl;
    }

    return .{ .is_https = is_https, .host = host, .port = port, .path = path };
}

pub const Client = struct {
    pub fn get(allocator: Allocator, io: Io, url: []const u8) !ClientResponse {
        return request(allocator, io, .{ .url = url });
    }

    pub fn requestTimed(allocator: Allocator, io: Io, opts: RequestOptions) !ClientResponse {
        if (opts.timeout_ms == 0) return request(allocator, io, opts);

        var result_slot: ?ClientResponse = null;
        var error_slot: ?anyerror = null;

        const Outcome = union(enum) { request_done: void, timed_out: void };
        var sel_buf: [2]Outcome = undefined;
        var sel = Io.Select(Outcome).init(io, &sel_buf);

        sel.async(.request_done, requestToSlot, .{ &result_slot, &error_slot, allocator, io, opts });
        sel.async(.timed_out, sleepVoid, .{ io, opts.timeout_ms });

        const winner = sel.await() catch return error.Canceled;
        sel.cancelDiscard();

        return switch (winner) {
            .request_done => {
                if (error_slot) |e| return e;
                return result_slot orelse error.Timeout;
            },
            .timed_out => error.Timeout,
        };
    }

    fn requestToSlot(
        result: *?ClientResponse,
        err: *?anyerror,
        allocator: Allocator,
        io: Io,
        opts: RequestOptions
    ) void {
        const resp = request(allocator, io, opts) catch |e| {
            err.* = e;
            return;
        };
        result.* = resp;
    }

    fn sleepVoid(io: Io, timeout_ms: u32) void {
        io.sleep(Io.Duration.fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
    }

    pub fn request(allocator: Allocator, io: Io, opts: RequestOptions) !ClientResponse {
        const parsed = try parseUrl(opts.url);

        const address = try resolveHost(io, parsed.host, parsed.port);
        var stream = try address.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        });

        defer stream.close(io);

        if (parsed.is_https) {
            const root_ca = if (opts.insecure) tls.config.cert.Bundle.empty else try getSystemRootCa(io);
            const rng_impl: std.Random.IoSource = .{ .io = io };
            var tls_conn = try tls.clientFromStream(io, stream, .{
                .host = parsed.host,
                .rng = rng_impl.interface(),
                .now = Io.Clock.real.now(io),
                .root_ca = root_ca,
                .insecure_skip_verify = opts.insecure,
            });
            defer tls_conn.close() catch {};

            var tls_read_buf: [tls.input_buffer_len]u8 = undefined;
            var tls_write_buf: [tls.output_buffer_len]u8 = undefined;
            var reader = tls_conn.reader(&tls_read_buf);
            var writer = tls_conn.writer(&tls_write_buf);

            return doRequest(allocator, &reader.interface, &writer.interface, parsed, opts);
        } else {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var writer = stream.writer(io, &write_buf);

            return doRequest(allocator, &reader.interface, &writer.interface, parsed, opts);
        }
    }

    pub fn requestWithRetry(
        allocator: Allocator,
        io: Io,
        opts: RequestOptions,
        retry_opts: RetryOptions
    ) !ClientResponse {
        const start_ms = Io.Clock.now(.real, io).toMilliseconds();
        const deadline_ms = start_ms + @as(i64, opts.timeout_ms);
        var attempt: u32 = 0;
        var backoff_ms: u32 = retry_opts.initial_backoff_ms;

        while (attempt < retry_opts.max_attempts) : (attempt += 1) {
            const req_result = request(allocator, io, opts);
            if (req_result) |resp_const| {
                var resp = resp_const;
                const should_retry = (resp.status >= 500 and retry_opts.retry_on_5xx) or
                    (resp.status == 429 and retry_opts.retry_on_429);
                if (!should_retry) return resp;
                resp.deinit();
                if (attempt + 1 >= retry_opts.max_attempts) return error.UpstreamError;
            } else |err| {
                if (!retry_opts.retry_on_network_error) return err;
                if (attempt + 1 >= retry_opts.max_attempts) return err;
            }

            const now = Io.Clock.now(.real, io).toMilliseconds();
            if (now >= deadline_ms) return error.Timeout;
            const remaining: i64 = deadline_ms - now;
            const sleep_ms: u32 = @intCast(@min(@as(i64, backoff_ms), remaining));

            io.sleep(Io.Duration.fromMilliseconds(sleep_ms), .awake) catch return error.Canceled;
            backoff_ms = @min(backoff_ms * 2, retry_opts.max_backoff_ms);
        }
        return error.UpstreamError;
    }

    fn doRequest(
        allocator: Allocator,
        reader: anytype,
        writer: anytype,
        parsed: ParsedUrl,
        opts: RequestOptions
    ) !ClientResponse {
        var req_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const line = try std.fmt.bufPrint(req_buf[pos..], "{s} {s} HTTP/1.1\r\n", .{ opts.method, parsed.path });
        pos += line.len;

        const host_hdr = try std.fmt.bufPrint(req_buf[pos..], "Host: {s}\r\n", .{parsed.host});
        pos += host_hdr.len;

        if (opts.body) |body| {
            const cl = try std.fmt.bufPrint(req_buf[pos..], "Content-Length: {d}\r\n", .{body.len});
            pos += cl.len;
        }

        const conn_hdr = "Connection: close\r\n";
        @memcpy(req_buf[pos..][0..conn_hdr.len], conn_hdr);
        pos += conn_hdr.len;

        if (opts.request_id) |rid| {
            if (rid.len > 0) {
                const rid_hdr = try std.fmt.bufPrint(req_buf[pos..], "X-Request-Id: {s}\r\n", .{rid});
                pos += rid_hdr.len;
            }
        }

        for (opts.headers) |h| {
            const hdr = try std.fmt.bufPrint(req_buf[pos..], "{s}: {s}\r\n", .{ h[0], h[1] });
            pos += hdr.len;
        }

        req_buf[pos] = '\r';
        req_buf[pos + 1] = '\n';
        pos += 2;

        try writer.writeAll(req_buf[0..pos]);

        if (opts.body) |body| {
            try writer.writeAll(body);
        }
        try writer.flush();

        return readResponse(allocator, reader);
    }

    fn readResponse(allocator: Allocator, reader: anytype) !ClientResponse {
        var header_buf: [8192]u8 = undefined;
        var header_len: usize = 0;

        while (header_len < header_buf.len) {
            const b = reader.peekByte() catch return error.ConnectionClosed;
            reader.seek += 1;
            header_buf[header_len] = b;
            header_len += 1;

            if (b == '\n' and header_len >= 4 and
                header_buf[header_len - 4] == '\r' and
                header_buf[header_len - 3] == '\n' and
                header_buf[header_len - 2] == '\r')
            {
                break;
            }
        }

        const header_str = header_buf[0..header_len];
        const first_line_end = std.mem.indexOf(u8, header_str, "\r\n") orelse return error.InvalidResponse;
        const first_line = header_str[0..first_line_end];

        const sp1 = std.mem.indexOfScalar(u8, first_line, ' ') orelse return error.InvalidResponse;
        const rest = first_line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const status = std.fmt.parseInt(u16, rest[0..sp2], 10) catch return error.InvalidResponse;

        var headers = std.ArrayList(ClientResponse.Header).empty;
        var lines = std.mem.splitSequence(u8, header_str[first_line_end + 2 ..], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try headers.append(allocator, .{
                .name = line[0..colon],
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            });
        }

        var content_length: usize = 0;
        var chunked = false;
        for (headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, h.value, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding")) {
                if (std.ascii.indexOfIgnoreCase(h.value, "chunked") != null) chunked = true;
            }
        }

        var body: []const u8 = "";
        if (chunked) {
            body = try readChunkedBody(allocator, reader);
        } else if (content_length > 0) {
            const body_buf = try allocator.alloc(u8, content_length);
            reader.readSliceAll(body_buf) catch {
                allocator.free(body_buf);
                return error.ConnectionClosed;
            };
            body = body_buf;
        }

        return .{
            .status = status,
            .headers = try headers.toOwnedSlice(allocator),
            .body = body,
            .allocator = allocator,
        };
    }

    fn readChunkedBody(allocator: Allocator, reader: anytype) ![]const u8 {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(allocator);

        var line_buf: [64]u8 = undefined;
        while (true) {
            const line = readLine(reader, &line_buf) catch return error.ConnectionClosed;
            const semi = std.mem.indexOfScalar(u8, line, ';');
            const size_str = std.mem.trim(u8, if (semi) |s| line[0..s] else line, " \t\r");
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidResponse;

            if (chunk_size == 0) {
                while (true) {
                    const trailer = readLine(reader, &line_buf) catch break;
                    if (trailer.len == 0) break;
                }
                break;
            }

            try body.ensureUnusedCapacity(allocator, chunk_size);
            const start = body.items.len;
            body.items.len = start + chunk_size;
            reader.readSliceAll(body.items[start..]) catch return error.ConnectionClosed;

            var crlf: [2]u8 = undefined;
            reader.readSliceAll(&crlf) catch return error.ConnectionClosed;
        }
        return try body.toOwnedSlice(allocator);
    }

    fn readLine(reader: anytype, buf: []u8) ![]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const b = reader.peekByte() catch return error.ConnectionClosed;
            reader.seek += 1;
            if (b == '\n' and i > 0 and buf[i - 1] == '\r') return buf[0 .. i - 1];
            buf[i] = b;
            i += 1;
        }
        return error.LineTooLong;
    }
};
