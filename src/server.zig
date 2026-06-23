const std = @import("std");
const builtin = @import("builtin");

const mem = std.mem;
const Io = std.Io;
const net = Io.net;
const Allocator = mem.Allocator;

const Request = @import("./http/request.zig").Request;
const Response = @import("./http/response.zig").Response;
const router_mod = @import("./http/router.zig");
const Router = router_mod.Router;
const Mime = @import("./http/mime.zig").Mime;
const Status = @import("./http/status.zig").Status;
const StaticContentStore = @import("./http/static_content.zig").StaticContentStore;
const Now = @import("utils").Now;
const tls = @import("tls");
const metrics_mod = @import("./metrics.zig");

const log = std.log.scoped(.http);

pub const RawHandlerFn = *const fn (allocator: Allocator, raw_request: []const u8, ctx: ?*anyopaque) anyerror![]const u8;

pub const Server = struct {
    allocator: Allocator,
    router: Router,
    address: net.IpAddress,
    active_connections: std.atomic.Value(u32),
    shutdown_requested: std.atomic.Value(bool),
    max_connections: u32,
    max_header_size: u32,
    max_body_size: u32,
    response_buffer_size: u32,
    idle_timeout_ms: u32,
    max_requests_per_connection: u32,
    drain_timeout_ms: u32,
    listener: ?*net.Server,
    static_dir: ?[]const u8,
    static_store: ?*StaticContentStore = null,
    tls_auth: ?*tls.config.CertKeyPair,
    tls_auth_owned: bool,
    tls_cert_file: []const u8,
    tls_key_file: []const u8,
    raw_handler: ?RawHandlerFn,
    raw_ctx: ?*anyopaque,
    on_request_complete: ?*const fn (method: []const u8, status: u16, elapsed_us: u64, ctx: ?*anyopaque) void,
    metrics_ctx: ?*anyopaque,
    metrics: metrics_mod.Metrics,
    pub const Config = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 3000,
        max_connections: u32 = 10_000,
        max_header_size: u32 = 8192,
        max_body_size: u32 = 1_048_576,
        response_buffer_size: u32 = 65536,
        idle_timeout_ms: u32 = 30_000,
        max_requests_per_connection: u32 = 10_000,
        static_dir: ?[]const u8 = null,
        drain_timeout_ms: u32 = 5_000,
        // TLS is presence-based: enabled when both cert and key paths are set.
        // (Avoids a bool field, which YAML config loaders can't default when absent.)
        tls_cert_file: []const u8 = "",
        tls_key_file: []const u8 = "",
    };

    pub fn init(allocator: Allocator, config: Config) !Server {
        return initWithRouter(allocator, config, Router.init());
    }

    pub fn initWithRouter(allocator: Allocator, config: Config, router: Router) !Server {
        const host = if (config.host.len > 0) config.host else "0.0.0.0";
        const address = try net.IpAddress.parseIp4(host, config.port);

        return .{
            .allocator = allocator,
            .router = router,
            .address = address,
            .active_connections = std.atomic.Value(u32).init(0),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .max_connections = config.max_connections,
            .max_header_size = config.max_header_size,
            .max_body_size = config.max_body_size,
            .response_buffer_size = config.response_buffer_size,
            .idle_timeout_ms = config.idle_timeout_ms,
            .max_requests_per_connection = config.max_requests_per_connection,
            .drain_timeout_ms = config.drain_timeout_ms,
            .listener = null,
            .static_dir = config.static_dir,
            .tls_auth = null,
            .tls_auth_owned = false,
            .tls_cert_file = config.tls_cert_file,
            .tls_key_file = config.tls_key_file,
            .raw_handler = null,
            .raw_ctx = null,
            .on_request_complete = null,
            .metrics_ctx = null,
            .metrics = .{},
        };
    }

    pub fn setTlsAuth(self: *Server, auth: *tls.config.CertKeyPair) void {
        self.tls_auth = auth;
    }

    pub fn setRawHandler(self: *Server, handler: RawHandlerFn, ctx: ?*anyopaque) void {
        self.raw_handler = handler;
        self.raw_ctx = ctx;
    }

    pub fn setRequestMetricsCallback(self: *Server, callback: *const fn ([]const u8, u16, u64, ?*anyopaque) void, ctx: ?*anyopaque) void {
        self.on_request_complete = callback;
        self.metrics_ctx = ctx;
    }

    pub fn listen(self: *Server, thr_io: Io) !void {
        if (self.tls_auth == null and self.tls_cert_file.len > 0 and self.tls_key_file.len > 0) {
            const auth = try self.allocator.create(tls.config.CertKeyPair);
            auth.* = tls.config.CertKeyPair.fromFilePathAbsolute(
                self.allocator,
                thr_io,
                self.tls_cert_file,
                self.tls_key_file,
            ) catch |err| {
                log.err("Failed to load TLS certificate/key ({s}, {s}): {}", .{ self.tls_cert_file, self.tls_key_file, err });
                self.allocator.destroy(auth);
                return err;
            };
            self.tls_auth = auth;
            self.tls_auth_owned = true;
        }

        if (self.static_dir) |dir| {
            const store = try self.allocator.create(StaticContentStore);
            store.* = try StaticContentStore.init(self.allocator, dir);
            if (store.loadDirectory(thr_io)) |n| {
                self.static_store = store;
                log.info("static: pre-loaded {d} file(s) from {s}", .{ n, dir });
            } else |err| {
                store.deinit();
                self.allocator.destroy(store);
                if (err == error.FileNotFound) {
                    log.warn("static: directory '{s}' not found, static serving disabled", .{dir});
                    self.static_dir = null;
                } else {
                    log.err("static: failed to load {s}: {}", .{ dir, err });
                    return err;
                }
            }
        }

        var listening = try self.address.listen(thr_io, .{ .reuse_address = true });
        self.listener = &listening;
        defer {
            self.listener = null;
            if (!self.shutdown_requested.load(.acquire)) {
                listening.deinit(thr_io);
            }
        }

        const port = self.address.getPort();
        log.info("Listening on :{d}{s}", .{ port, if (self.tls_auth != null) " (TLS)" else "" });

        var group: Io.Group = .init;

        while (!self.shutdown_requested.load(.acquire)) {
            const connection = listening.accept(thr_io) catch |err| {
                if (self.shutdown_requested.load(.acquire)) break;
                log.err("Accept error: {}", .{err});
                continue;
            };

            const prev = self.active_connections.fetchAdd(1, .acq_rel);
            if (prev >= self.max_connections) {
                _ = self.active_connections.fetchSub(1, .release);
                log.warn("Connection limit reached: {d}/{d}", .{ prev, self.max_connections });
                connection.close(thr_io);
                continue;
            }

            group.async(thr_io, handleConnection, .{ self, thr_io, connection });
        }

        const drain_ms: i64 = @intCast(self.drain_timeout_ms);
        if (drain_ms > 0) {
            log.info("draining {d}ms for in-flight handlers to finish…", .{drain_ms});
            thr_io.sleep(Io.Duration.fromMilliseconds(drain_ms), .awake) catch {};
        }
        group.cancel(thr_io);
        log.info("Server shutdown complete", .{});
    }

    pub fn stop(self: *Server, thr_io: Io) void {
        self.shutdown_requested.store(true, .release);

        if (self.listener) |l| {
            l.socket.close(thr_io);
        }
    }

    fn setTcpNoDelay(fd: std.posix.fd_t) void {
        if (comptime builtin.os.tag != .windows) {
            const value: c_int = 1;
            const opt: [*]const u8 = @ptrCast(&value);
            _ = std.posix.system.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, opt, @sizeOf(c_int));
        }
    }

    fn setTcpKeepAlive(fd: std.posix.fd_t) void {
        if (comptime builtin.os.tag != .windows) {
            const value: c_int = 1;
            const opt: [*]const u8 = @ptrCast(&value);
            _ = std.posix.system.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.KEEPALIVE, opt, @sizeOf(c_int));
        }
    }

    fn handleConnection(self: *Server, thr_io: Io, connection: net.Stream) Io.Cancelable!void {
        defer {
            connection.close(thr_io);
            const remaining = self.active_connections.fetchSub(1, .release) - 1;
            const labels_empty: []const metrics_mod.Label = &.{};
            self.metrics.gauge("http_active_connections", @intCast(remaining), labels_empty);
        }
        {
            const current = self.active_connections.load(.acquire);
            const labels_empty: []const metrics_mod.Label = &.{};
            self.metrics.gauge("http_active_connections", @intCast(current), labels_empty);
        }

        setTcpNoDelay(connection.socket.handle);
        setTcpKeepAlive(connection.socket.handle);

        if (self.tls_auth) |auth| {
            const rng_impl: std.Random.IoSource = .{ .io = thr_io };
            var tls_conn = tls.serverFromStream(thr_io, connection, .{
                .auth = auth,
                .now = Io.Clock.real.now(thr_io),
                .rng = rng_impl.interface(),
            }) catch |err| {
                log.err("TLS handshake failed: {}", .{err});
                return;
            };
            defer tls_conn.close() catch {};

            var tls_read_buf: [tls.input_buffer_len]u8 = undefined;
            var tls_write_buf: [tls.output_buffer_len]u8 = undefined;
            var tls_reader = tls_conn.reader(&tls_read_buf);
            var tls_writer = tls_conn.writer(&tls_write_buf);

            if (self.raw_handler != null) {
                self.runRequestLoopRaw(&tls_reader.interface, &tls_writer.interface, thr_io);
            } else {
                self.runRequestLoop(&tls_reader.interface, &tls_writer.interface, thr_io, connection);
            }
        } else {
            var read_buf: [4096]u8 = undefined;
            var reader = connection.reader(thr_io, &read_buf);
            var sock_write_buf: [4096]u8 = undefined;
            var writer = connection.writer(thr_io, &sock_write_buf);

            if (self.raw_handler != null) {
                self.runRequestLoopRaw(&reader.interface, &writer.interface, thr_io);
            } else {
                self.runRequestLoop(&reader.interface, &writer.interface, thr_io, connection);
            }
        }
    }

    fn runRequestLoop(self: *Server, reader: anytype, writer: anytype, thr_io: Io, connection: net.Stream) void {
        var request_count: u32 = 0;

        log.debug("runRequestLoop: entering (max_req_per_conn={d})", .{self.max_requests_per_connection});

        while (!self.shutdown_requested.load(.acquire)) {
            request_count += 1;
            if (request_count > self.max_requests_per_connection) {
                log.warn("runRequestLoop: request_count {d} exceeded max_requests_per_connection {d}, closing", .{ request_count, self.max_requests_per_connection });
                return;
            }

            const now: Now = .{ .io = thr_io };
            const start_ms = now.toMilliSeconds();

            var header_buf: [8192]u8 = undefined;
            var header_len: usize = 0;
            var header_end: ?usize = null;

            while (header_end == null) {
                if (header_len >= @min(header_buf.len, self.max_header_size)) {
                    log.warn("runRequestLoop: header_len {d} exceeded max, sending 413", .{header_len});
                    sendError(thr_io, connection, .entity_too_large, "Headers too large");
                    return;
                }

                const b = reader.peekByte() catch |err| {
                    if (err == error.EndOfStream) {
                        log.debug("runRequestLoop: peekByte EOS at req#{d}, header_len={d}", .{ request_count, header_len });
                    } else {
                        log.warn("runRequestLoop: peekByte failed at req#{d}, header_len={d}: {}", .{ request_count, header_len, err });
                    }
                    return;
                };
                reader.seek += 1;
                header_buf[header_len] = b;
                header_len += 1;

                if (b == '\n' and header_len >= 4 and
                    header_buf[header_len - 4] == '\r' and
                    header_buf[header_len - 3] == '\n' and
                    header_buf[header_len - 2] == '\r')
                {
                    header_end = header_len;
                }
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var req = Request.init(alloc) catch {
                log.warn("runRequestLoop: req.init failed at req#{d}", .{request_count});
                sendError(thr_io, connection, .internal_server_error, "Internal Server Error");
                return;
            };
            req.io = thr_io;
            req.parse(header_buf[0..header_end.?]) catch |err| {
                log.warn("runRequestLoop: req.parse failed at req#{d} (header_len={d}): {}", .{ request_count, header_end.?, err });
                sendError(thr_io, connection, .bad_request, "Bad Request");
                return;
            };

            const body_len = validateFraming(header_buf[0..header_end.?]) catch |err| {
                log.warn("runRequestLoop: rejected request framing for {s} {s}: {}", .{ req.method.toString(), req.path, err });
                sendError(thr_io, connection, .bad_request, "Bad Request");
                return;
            };

            log.debug("runRequestLoop: {s} {s} req#{d} body_len={d} keep_alive={}", .{
                req.method.toString(), req.path, request_count, body_len, req.keep_alive,
            });

            if (body_len > 0) {
                if (body_len > self.max_body_size) {
                    log.warn("runRequestLoop: body_len {d} > max_body_size {d} for {s} {s}, sending 413", .{ body_len, self.max_body_size, req.method.toString(), req.path });
                    sendError(thr_io, connection, .entity_too_large, "Body too large");
                    return;
                }
                const body_buf = alloc.alloc(u8, body_len) catch |err| {
                    log.warn("runRequestLoop: body buf alloc({d}) failed for {s} {s}: {}", .{ body_len, req.method.toString(), req.path, err });
                    return;
                };

                const extra = header_len - header_end.?;
                if (extra > 0) {
                    const to_copy = @min(extra, body_len);
                    @memcpy(body_buf[0..to_copy], header_buf[header_end.?..][0..to_copy]);
                    if (to_copy < body_len) {
                        reader.readSliceAll(body_buf[to_copy..]) catch |err| {
                            log.warn("runRequestLoop: body read (after header-buf carryover {d}/{d}) failed for {s} {s}: {}", .{ to_copy, body_len, req.method.toString(), req.path, err });
                            return;
                        };
                    }
                } else {
                    reader.readSliceAll(body_buf) catch |err| {
                        log.warn("runRequestLoop: body read ({d} bytes) failed for {s} {s}: {}", .{ body_len, req.method.toString(), req.path, err });
                        return;
                    };
                }
                req.body = body_buf;
            }

            var res = Response.init(alloc);
            self.router.handle(alloc, &req, &res) catch |err| {
                log.err("Handler error on {s}: {}", .{ req.path, err });
                res.status = .internal_server_error;
                res.write("Internal Server Error") catch {};
            };

            if (res.streaming_handler) |sh| {
                sh(res.streaming_ctx, alloc, &req, writer) catch |err| {
                    log.err("Streaming handler error on {s}: {}", .{ req.path, err });
                };

                return;
            }

            if (res.status == .not_found and self.static_dir != null and req.method == .get) {
                self.serveStatic(thr_io, alloc, &req, &res);
            }

            if (!req.keep_alive or request_count >= self.max_requests_per_connection) {
                res.setHeader("Connection", "close") catch {};
            }

            const write_buf = alloc.alloc(u8, self.response_buffer_size) catch {
                sendError(thr_io, connection, .internal_server_error, "Response buffer alloc failed");
                return;
            };
            if (res.toBytes(write_buf)) |response_bytes| {
                writer.writeAll(response_bytes) catch |err| {
                    log.warn(
                        "response writeAll failed for {s} {s}: {} (status={d}, body_len={d}, bytes_len={d})",
                        .{
                            req.method.toString(), req.path,
                            err,                   @intFromEnum(res.status),
                            res.body.items.len,    response_bytes.len,
                        },
                    );
                    return;
                };
            } else |err| {
                log.warn(
                    "res.toBytes failed for {s} {s}: {} (write_buf={d}, body_len={d}); falling back to streamResponse",
                    .{
                        req.method.toString(), req.path,
                        err,                   write_buf.len,
                        res.body.items.len,
                    },
                );
                streamResponse(writer, &res) catch |se| {
                    log.warn(
                        "streamResponse failed for {s} {s}: {} (status={d}, body_len={d})",
                        .{
                            req.method.toString(), req.path,
                            se,                    @intFromEnum(res.status),
                            res.body.items.len,
                        },
                    );
                    return;
                };
            }

            writer.flush() catch |err| {
                log.warn(
                    "writer.flush failed for {s} {s}: {} (status={d}, body_len={d})",
                    .{
                        req.method.toString(), req.path,
                        err,                   @intFromEnum(res.status),
                        res.body.items.len,
                    },
                );
                return;
            };

            const elapsed_ms = now.toMilliSeconds() - start_ms;
            log.info(
                "method={s} path={s} status={d} elapsed_ms={d} request_id={s}",
                .{
                    req.method.toString(),
                    req.path,
                    @intFromEnum(res.status),
                    @as(u64, @intCast(@max(0, elapsed_ms))),
                    req.request_id,
                },
            );

            if (self.on_request_complete) |cb| {
                const elapsed_us: u64 = @intCast(@max(0, elapsed_ms) * 1_000);
                cb(req.method.toString(), @intFromEnum(res.status), elapsed_us, self.metrics_ctx);
            }

            if (!req.keep_alive) return;
        }
    }

    fn runRequestLoopRaw(self: *Server, reader: anytype, writer: anytype, thr_io: Io) void {
        const handler = self.raw_handler orelse return;
        var request_count: u32 = 0;

        while (!self.shutdown_requested.load(.acquire)) {
            request_count += 1;
            if (request_count > self.max_requests_per_connection) return;

            var header_buf: [8192]u8 = undefined;
            var header_len: usize = 0;
            var header_end: ?usize = null;

            while (header_end == null) {
                if (header_len >= @min(header_buf.len, self.max_header_size)) return;

                const b = reader.peekByte() catch return;
                reader.seek += 1;
                header_buf[header_len] = b;
                header_len += 1;

                if (b == '\n' and header_len >= 4 and
                    header_buf[header_len - 4] == '\r' and
                    header_buf[header_len - 3] == '\n' and
                    header_buf[header_len - 2] == '\r')
                {
                    header_end = header_len;
                }
            }

            const body_len = validateFraming(header_buf[0..header_end.?]) catch {
                writer.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                writer.flush() catch {};
                return;
            };
            if (body_len > self.max_body_size) return;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const total_len = header_end.? + body_len;
            const raw_request = alloc.alloc(u8, total_len) catch return;
            @memcpy(raw_request[0..header_end.?], header_buf[0..header_end.?]);

            const extra = header_len - header_end.?;
            if (body_len > 0) {
                if (extra > 0) {
                    const to_copy = @min(extra, body_len);
                    @memcpy(raw_request[header_end.?..][0..to_copy], header_buf[header_end.?..][0..to_copy]);
                    if (to_copy < body_len) {
                        reader.readSliceAll(raw_request[header_end.? + to_copy ..]) catch return;
                    }
                } else {
                    reader.readSliceAll(raw_request[header_end.?..]) catch return;
                }
            }

            if (self.static_store != null) {
                if (scanPath(header_buf[0..header_end.?])) |path| {
                    const is_get = mem.startsWith(u8, header_buf[0..header_end.?], "GET ");
                    if (is_get) {
                        if (self.static_store.?.get(path) != null) {
                            var req = Request.init(alloc) catch return;
                            req.path = path;
                            req.method = .get;
                            var res = Response.init(alloc);
                            self.serveStatic(thr_io, alloc, &req, &res);
                            if (res.status == .ok) {
                                const write_buf = alloc.alloc(u8, self.response_buffer_size) catch return;
                                if (res.toBytes(write_buf)) |resp_bytes| {
                                    writer.writeAll(resp_bytes) catch return;
                                    writer.flush() catch return;
                                    continue;
                                } else |_| {
                                    streamResponse(writer, &res) catch return;
                                    writer.flush() catch return;
                                    continue;
                                }
                            }
                        }
                    }
                }
            }

            const raw_response = handler(alloc, raw_request, self.raw_ctx) catch {
                if (self.static_dir != null) {
                    if (scanPath(header_buf[0..header_end.?])) |path| {
                        var req = Request.init(alloc) catch return;
                        req.path = path;
                        req.method = .get;
                        var res = Response.init(alloc);
                        self.serveStatic(thr_io, alloc, &req, &res);
                        if (res.status == .ok) {
                            const write_buf = alloc.alloc(u8, self.response_buffer_size) catch return;
                            const resp_bytes = res.toBytes(write_buf) catch return;
                            writer.writeAll(resp_bytes) catch return;
                            writer.flush() catch return;
                            continue;
                        }
                    }
                }
                return;
            };

            writer.writeAll(raw_response) catch return;
            writer.flush() catch return;

            if (mem.indexOf(u8, raw_response[0..@min(raw_response.len, 512)], "Connection: close") != null) return;
        }
    }

    // Request-smuggling defenses (H12): the server reads the body strictly by
    // Content-Length, so any length ambiguity is rejected. Returns the single
    // declared body length (0 if none). Parsing line-by-line also fixes the old
    // substring scan that matched "Content-Length:" inside other header names.
    const FramingError = error{
        BadHeader,
        TransferEncodingUnsupported,
        DuplicateContentLength,
        BadContentLength,
    };

    fn validateFraming(headers: []const u8) FramingError!usize {
        var lines = mem.splitSequence(u8, headers, "\r\n");
        _ = lines.next(); // request line
        var cl_seen = false;
        var cl_value: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) break; // end of header block
            // obsolete line folding (leading SP/HTAB) is a smuggling vector
            if (line[0] == ' ' or line[0] == '\t') return error.BadHeader;
            const colon = mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
            const name = line[0..colon];
            if (name.len == 0) return error.BadHeader;
            // whitespace before the colon is disallowed (RFC 7230 §3.2.4)
            const last = name[name.len - 1];
            if (last == ' ' or last == '\t') return error.BadHeader;
            const value = mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                return error.TransferEncodingUnsupported;
            }
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (cl_seen) return error.DuplicateContentLength;
                cl_seen = true;
                cl_value = std.fmt.parseInt(usize, value, 10) catch return error.BadContentLength;
            }
        }
        return cl_value;
    }

    fn scanPath(headers: []const u8) ?[]const u8 {
        const sp1 = mem.indexOfScalar(u8, headers, ' ') orelse return null;
        const rest = headers[sp1 + 1 ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '?' and rest[end] != '\r') : (end += 1) {}
        if (end == 0) return null;
        return rest[0..end];
    }

    fn serveStatic(self: *Server, thr_io: Io, alloc: Allocator, req: *const Request, res: *Response) void {
        _ = thr_io;
        const store = self.static_store orelse return;

        if (mem.indexOf(u8, req.path, "..") != null) return;
        if (std.ascii.indexOfIgnoreCase(req.path, "%2e%2e") != null) return;

        const file = store.get(req.path) orelse return;

        if (req.getHeader("If-None-Match")) |inm| {
            if (mem.eql(u8, inm, file.etag)) {
                res.status = .not_modified;
                res.body.items.len = 0;
                res.headers.items.len = 0;
                res.setHeader("ETag", file.etag) catch return;
                return;
            }
        }

        const content_type = if (file.mime) |m| m.toHttpString() else "application/octet-stream";

        res.status = .ok;
        res.body.items.len = 0;
        res.headers.items.len = 0;
        res.setHeader("Content-Type", content_type) catch return;
        res.setHeader("ETag", file.etag) catch return;
        res.setHeader("Cache-Control", "public, max-age=60") catch return;
        res.body.appendSlice(alloc, file.data) catch return;
    }

    fn streamResponse(w: anytype, res: *Response) !void {
        var status_buf: [64]u8 = undefined;
        const status_line = try std.fmt.bufPrint(&status_buf, "HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(res.status), res.status.toString(),
        });
        try w.writeAll(status_line);

        var cl_buf: [32]u8 = undefined;
        const cl = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}\r\n", .{res.body.items.len});
        try w.writeAll(cl);

        for (res.headers.items) |h| {
            try w.writeAll(h.name);
            try w.writeAll(": ");
            try w.writeAll(h.value);
            try w.writeAll("\r\n");
        }
        try w.writeAll("\r\n");
        try w.flush();

        var remaining = res.body.items;
        while (remaining.len > 0) {
            const chunk_size = @min(remaining.len, 4096);
            try w.writeAll(remaining[0..chunk_size]);
            try w.flush();
            remaining = remaining[chunk_size..];
        }
    }

    fn sendError(thr_io: Io, connection: net.Stream, status: Status, body: []const u8) void {
        var buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            @intFromEnum(status),
            status.toString(),
            body.len,
            body,
        }) catch return;

        var write_buf: [1024]u8 = undefined;
        var err_writer = connection.writer(thr_io, &write_buf);
        err_writer.interface.writeAll(response) catch return;
        err_writer.interface.flush() catch return;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit(self.allocator);
        if (self.static_store) |store| {
            store.deinit();
            self.allocator.destroy(store);
        }
        if (self.tls_auth_owned) {
            if (self.tls_auth) |auth| {
                auth.deinit(self.allocator);
                self.allocator.destroy(auth);
            }
        }
    }
};

const testing = std.testing;

test "validateFraming - clean request returns content length" {
    const h = "POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 42\r\n\r\n";
    try testing.expectEqual(@as(usize, 42), try Server.validateFraming(h));
}

test "validateFraming - no body returns zero" {
    const h = "GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    try testing.expectEqual(@as(usize, 0), try Server.validateFraming(h));
}

test "validateFraming - duplicate Content-Length rejected" {
    const h = "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n";
    try testing.expectError(error.DuplicateContentLength, Server.validateFraming(h));
}

test "validateFraming - Transfer-Encoding rejected" {
    const h = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    try testing.expectError(error.TransferEncodingUnsupported, Server.validateFraming(h));
}

test "validateFraming - Content-Length plus Transfer-Encoding rejected" {
    const h = "POST /x HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n";
    try testing.expectError(error.TransferEncodingUnsupported, Server.validateFraming(h));
}

test "validateFraming - whitespace before colon rejected" {
    const h = "POST /x HTTP/1.1\r\nContent-Length : 5\r\n\r\n";
    try testing.expectError(error.BadHeader, Server.validateFraming(h));
}

test "validateFraming - obsolete line folding rejected" {
    const h = "POST /x HTTP/1.1\r\nX-Test: a\r\n folded\r\n\r\n";
    try testing.expectError(error.BadHeader, Server.validateFraming(h));
}

test "validateFraming - non-numeric Content-Length rejected" {
    const h = "POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n";
    try testing.expectError(error.BadContentLength, Server.validateFraming(h));
}

test "validateFraming - similarly-named header is not mistaken for Content-Length" {
    const h = "GET / HTTP/1.1\r\nX-My-Content-Length: 999\r\n\r\n";
    try testing.expectEqual(@as(usize, 0), try Server.validateFraming(h));
}
