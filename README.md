# schnell - Zig Web Assembly Application Framework.

Built for the kind of apps where you want a JSON API or a hypermedia-driven backend without pulling in a framework that owns your control flow.

You write `pub fn main()`, build an `App`, register routes and middleware, and call `run`. Handlers are plain functions that take a request and a response. Nothing surprising.

It also ships a cookie-based sessions backed by planck/db, a test client for handler-level tests, and provider helpers for OAuth, Stripe, and notification fan-out, so most things you need to ship a small-to-mid-sized app are in the same crate. SSE and change-stream fan-out live in [ssehub](https://github.com/plancksystems/ssehub), a separate crate built on the same primitives.

## Install

`build.zig.zon`:

```zig
.dependencies = .{
    .schnell = .{
        .url = "https://github.com/plancksystems/schnell-zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

`build.zig`:

```zig
const schnell_dep = b.dependency("schnell", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("schnell", schnell_dep.module("schnell"));
```

schnell depends on `bson`, `tls`, `proto`, `utils`, and `planck-zig-client` from the same org. Those are pinned in `build.zig.zon`; you don't add them yourself unless you also use them directly.

Minimum Zig: 0.16.0.

## Hello world

```zig
const std = @import("std");
const schnell = @import("schnell");

fn home(_: ?*anyopaque, _: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) !void {
    try res.html("<h1>hello</h1>");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    var app = try schnell.App.init(allocator, .{
        .host = "127.0.0.1",
        .port = 3000,
    });
    defer app.deinit();

    try app.get("/", home, null);

    try app.run(io);
}
```

That's a complete program. `App.init` takes a `Server.Config` (host, port, body and header limits, idle timeout, optional `static_dir`). `app.get`/`post`/`put`/`delete`/`patch` register routes. `app.run(io)` blocks; call `app.stop(io)` from another fiber to drain.

## Handlers

A handler is:

```zig
fn (ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const Request, res: *Response) !void
```

The `ctx_ptr` is whatever you passed to `app.get(...)`. Cast it back inside the handler:

```zig
const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
```

That pointer is your shared application state. Database client, config, sessions, whatever. The framework doesn't care what's in it.

The allocator is a per-request arena. Everything you allocate during the handler is freed when the response is sent. Don't keep pointers from it.

### Request

```zig
req.method                  // .get / .post / ...
req.path                    // "/users/123"
req.getHeader("X-Foo")      // ?[]const u8
req.getQuery("page")        // ?[]const u8 from the URL query string
req.getCookie("session")    // ?[]const u8
req.getLocal("user_id")     // ?[]const u8, set by middleware
req.setLocal("foo", "bar")
req.body                    // []const u8, raw
req.getBody(allocator, T)   // parses JSON body into T (or form-urlencoded)
```

URL params from path patterns (`/users/:id`) come through `req.getLocal("id")`.

### Response

```zig
res.status = .ok                 // default
res.html(body)                   // text/html
res.json(body)                   // application/json
res.write(body)                  // raw bytes, no content-type
res.setHeader(name, value)
res.setCookie(.{ .name = "...", .value = "...", .path = "/" })
```

For streaming responses (SSE, long polls, downloads), use `routeStreaming` instead of `route`. The handler signature changes: you get a `*std.Io.Writer` instead of a `*Response` and write directly to the socket.

## Middleware

Middleware sees every request before routing. Wrap whatever cross-cutting concern you need: CORS, request id, rate limit, auth, logging.

```zig
var cors = schnell.CorsMiddleware.init(.{
    .allow_origin = "*",
    .allow_methods = "GET, POST, PUT, DELETE, OPTIONS",
    .allow_headers = "Content-Type, Authorization",
});
try app.use(cors.middleware());
```

Built-ins:

- `CorsMiddleware` for cross-origin
- `RequestIdMiddleware` adds an `X-Request-Id` header for log correlation
- `RateLimitMiddleware` with a token-bucket `RateLimiter`
- `CsrfMiddleware` for double-submit cookie CSRF protection
- `JwtAuthMiddleware` (lives in `schnell.web`, separate import for WASM-friendly builds)

Writing your own is straightforward. Define a struct with `execute(self, allocator, req, res) !Middleware.Action` and a `middleware(self) Middleware` wrapper. Return `.stop` to short-circuit, `.next` to continue.

## Routing

Plain string paths or path patterns with `:param` segments. The router is a trie, so order of registration doesn't matter for collisions. Conflicts (two handlers for the same method+path) surface as build-time errors via `register`.

```zig
try app.get("/", home, &ctx);
try app.get("/users", listUsers, &ctx);
try app.get("/users/:id", getUser, &ctx);
try app.post("/users", createUser, &ctx);
try app.delete("/users/:id", deleteUser, &ctx);
```

Each handler gets the `ctx` pointer you passed at registration. Pass `null` if a route doesn't need any shared state.

## Streaming responses

For SSE, long polls, and large downloads, register a handler with `routeStreaming`. You get a `*std.Io.Writer` instead of a `*Response` and write the body to the socket directly.

```zig
try app.routeStreaming(.get, "/logs/tail", tailLogs, &ctx);

fn tailLogs(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: *const schnell.Request,
    w: *std.Io.Writer,
) !void {
    try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n");
    // ... write `data: ...\n\n` frames as events arrive
}
```

If what you actually want is broadcasting a server-side change stream (planck/db's `Watch` RPC, or any other source) out to many browser EventSources with bounded queues, replay rings, and topic-based fan-out, that lives in [ssehub](https://github.com/plancksystems/ssehub) now. It's a separate crate that builds on schnell for the HTTP side and adds the bus, subscriber, and watcher pieces on top.

## Sessions

`SessionStore` is generic over your per-session payload type. You hand it an allocator, an `Io`, and a `Config` with cookie name, secure flag, and TTL. It gives you create/get/destroy/rotate by token.

```zig
const AppData = struct { user_id: []const u8, role: []const u8 };

var sessions = schnell.SessionStore(AppData).init(allocator, io, .{
    .cookie_name = "sid",
    .cookie_secure = true,
    .ttl_seconds = 7 * 24 * 60 * 60,
});
sessions.start();
defer sessions.deinit();

// inside a handler
if (schnell.readSessionCookie(req, "sid")) |token| {
    if (try sessions.get(io, token)) |data| {
        try req.setLocal("user_id", data.user_id);
    }
}
```

## Providers

Optional helper modules for things that recur in real apps. Each one is a thin layer over the underlying API, not a full SDK.

- `schnell.auth.google`: OAuth code/token exchange and userinfo fetch.
- `schnell.pay.stripe`: PaymentIntent create/confirm and webhook signature verification.
- `schnell.notify`: email and SMS adapters with a common interface.

You import them only if you use them. The source under `src/providers/` is the reference: each module is short enough to read end-to-end.

Among all the providers that we have implemented only schnell.auth.google and schnell.pay.stripe are tested.

## Client

For outbound HTTP from your handlers (e.g. cross-service calls), use `schnell.Client`:

```zig
var resp = try schnell.Client.request(allocator, io, .{
    .method = .post,
    .url = "http://items-service:3001/items",
    .body = json_body,
    .headers = &.{ .{ "Content-Type", "application/json" } },
    .timeout_ms = 5000,
});
defer resp.deinit();
```

For WASM services running under planck/db, use `web.callService` instead, which routes through the host's upstream pool with circuit breakers.

## Templates

The `planctl` CLI scaffolds four starter projects, all of which use schnell. Pick one based on what kind of frontend you want (SPA or hypermedia) and how you want to split the backend (single binary or microservices).

```sh
planctl new my_app --type spa --arch mono
planctl new my_app --type spa --arch micro
planctl new my_app --type hda --arch mono
planctl new my_app --type hda --arch micro
```

The four samples in [plancksystems/samples](https://github.com/plancksystems/samples) are the reference implementations:

- `notes_spa_mono` is `--type spa --arch mono`
- `notes_spa_micro` is `--type spa --arch micro`
- `pizzaqsr-hda-mono` is `--type hda --arch mono`
- `pizzaqsr-hda-micro` is `--type hda --arch micro`

## When to pick what

|         | mono                                  | micro                                                  |
| ------- | ------------------------------------- | ------------------------------------------------------ |
| **SPA** | JSON API, Vue 3 SPA, one process      | JSON API per service, Vue 3 SPA, shell + services      |
| **HDA** | HTML fragments, datastar, one process | HTML fragments per service, datastar, shell + services |

Start with mono unless you already know you need micro. Splitting later is cheaper than collapsing.

For the difference between SPA and hypermedia in this stack, the short version: SPA is what you reach for when the frontend has its own state machine (client-side routing, optimistic updates, offline). HDA is what you reach for when the page is the state, the browser is the renderer, and the server is the source of truth. Both have their place; this stack supports either without forcing you into one.

## License

MIT, see [LICENSE](./LICENSE).
