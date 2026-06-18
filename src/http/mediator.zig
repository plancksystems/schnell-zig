const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const RequestHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque) anyerror![]const u8,
    };

    pub fn handle(self: RequestHandler, allocator: Allocator, request: *anyopaque) ![]const u8 {
        return self.vtable.handle(self.ptr, allocator, request);
    }

    pub fn from(comptime T: type, comptime R: type, ptr: *T) RequestHandler {
        comptime validateHandler(T, R);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, req: *anyopaque) anyerror![]const u8 {
                const self: *T = @ptrCast(@alignCast(p));
                const request: *R = @ptrCast(@alignCast(req));
                return self.handle(alloc, request);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .handle = gen.call } };
    }
};

pub const PipelineBehavior = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const NextFn = *const fn (ctx: *anyopaque, allocator: Allocator, request: *anyopaque) anyerror![]const u8;

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque, ctx: *anyopaque, next: NextFn) anyerror![]const u8,
    };

    pub fn handle(self: PipelineBehavior, allocator: Allocator, request: *anyopaque, ctx: *anyopaque, next: NextFn) ![]const u8 {
        return self.vtable.handle(self.ptr, allocator, request, ctx, next);
    }

    pub fn from(comptime T: type, ptr: *T) PipelineBehavior {
        comptime validateBehavior(T);
        const gen = struct {
            fn call(
                p: *anyopaque,
                alloc: Allocator,
                req: *anyopaque,
                ctx: *anyopaque,
                next: NextFn
            ) anyerror![]const u8 {
                const self: *T = @ptrCast(@alignCast(p));
                return self.handle(alloc, req, ctx, next);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .handle = gen.call } };
    }
};

pub const PreProcessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque) anyerror!void,
    };

    pub fn process(self: PreProcessor, allocator: Allocator, request: *anyopaque) !void {
        return self.vtable.process(self.ptr, allocator, request);
    }

    pub fn from(comptime T: type, comptime R: type, ptr: *T) PreProcessor {
        comptime validatePreProcessor(T, R);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, req: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(p));
                const request: *R = @ptrCast(@alignCast(req));
                return self.process(alloc, request);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .process = gen.call } };
    }
};

pub const PostProcessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        process: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque, response: []const u8) anyerror![]const u8,
    };

    pub fn process(self: PostProcessor, allocator: Allocator, request: *anyopaque, response: []const u8) ![]const u8 {
        return self.vtable.process(self.ptr, allocator, request, response);
    }

    pub fn from(comptime T: type, comptime R: type, ptr: *T) PostProcessor {
        comptime validatePostProcessor(T, R);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, req: *anyopaque, resp: []const u8) anyerror![]const u8 {
                const self: *T = @ptrCast(@alignCast(p));
                const request: *R = @ptrCast(@alignCast(req));
                return self.process(alloc, request, resp);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .process = gen.call } };
    }
};

pub const ExceptionHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque, err: anyerror) anyerror!?[]const u8,
    };

    pub fn handle(self: ExceptionHandler, allocator: Allocator, request: *anyopaque, err: anyerror) !?[]const u8 {
        return self.vtable.handle(self.ptr, allocator, request, err);
    }

    pub fn from(comptime T: type, comptime R: type, ptr: *T) ExceptionHandler {
        comptime validateExceptionHandler(T, R);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, req: *anyopaque, err: anyerror) anyerror!?[]const u8 {
                const self: *T = @ptrCast(@alignCast(p));
                const request: *R = @ptrCast(@alignCast(req));
                return self.handle(alloc, request, err);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .handle = gen.call } };
    }
};

pub const ExceptionAction = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, allocator: Allocator, request: *anyopaque, err: anyerror) void,
    };

    pub fn execute(self: ExceptionAction, allocator: Allocator, request: *anyopaque, err: anyerror) void {
        return self.vtable.execute(self.ptr, allocator, request, err);
    }

    pub fn from(comptime T: type, comptime R: type, ptr: *T) ExceptionAction {
        comptime validateExceptionAction(T, R);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, req: *anyopaque, err: anyerror) void {
                const self: *T = @ptrCast(@alignCast(p));
                const request: *R = @ptrCast(@alignCast(req));
                self.execute(alloc, request, err);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .execute = gen.call } };
    }
};

pub const NotificationHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, allocator: Allocator, notification: *anyopaque) anyerror!void,
    };

    pub fn handle(self: NotificationHandler, allocator: Allocator, notification: *anyopaque) !void {
        return self.vtable.handle(self.ptr, allocator, notification);
    }

    pub fn from(comptime T: type, comptime N: type, ptr: *T) NotificationHandler {
        comptime validateNotificationHandler(T, N);
        const gen = struct {
            fn call(p: *anyopaque, alloc: Allocator, notif: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(p));
                const notification: *N = @ptrCast(@alignCast(notif));
                return self.handle(alloc, notification);
            }
        };
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{ .handle = gen.call } };
    }
};

fn validateHandler(comptime T: type, comptime R: type) void {
    _ = R;
    if (!@hasDecl(T, "handle")) {
        @compileError(@typeName(T) ++ " must declare `pub fn handle(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *R) ![]const u8`");
    }
}

fn validateBehavior(comptime T: type) void {
    if (!@hasDecl(T, "handle")) {
        @compileError(@typeName(T) ++ " must declare `pub fn handle(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *anyopaque, ctx: *anyopaque, next: NextFn) ![]const u8`");
    }
}

fn validatePreProcessor(comptime T: type, comptime R: type) void {
    _ = R;
    if (!@hasDecl(T, "process")) {
        @compileError(@typeName(T) ++ " must declare `pub fn process(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *R) !void`");
    }
}

fn validatePostProcessor(comptime T: type, comptime R: type) void {
    _ = R;
    if (!@hasDecl(T, "process")) {
        @compileError(@typeName(T) ++ " must declare `pub fn process(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *R, response: []const u8) ![]const u8`");
    }
}

fn validateExceptionHandler(comptime T: type, comptime R: type) void {
    _ = R;
    if (!@hasDecl(T, "handle")) {
        @compileError(@typeName(T) ++ " must declare `pub fn handle(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *R, err: anyerror) !?[]const u8`");
    }
}

fn validateExceptionAction(comptime T: type, comptime R: type) void {
    _ = R;
    if (!@hasDecl(T, "execute")) {
        @compileError(@typeName(T) ++ " must declare `pub fn execute(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, request: *R, err: anyerror) void`");
    }
}

fn validateNotificationHandler(comptime T: type, comptime N: type) void {
    _ = N;
    if (!@hasDecl(T, "handle")) {
        @compileError(@typeName(T) ++ " must declare `pub fn handle(self: *" ++ @typeName(T) ++
            ", allocator: Allocator, notification: *N) !void`");
    }
}

const PipelineRunner = struct {
    global_behaviors: []const PipelineBehavior,
    key_behaviors: []const PipelineBehavior,
    handler: RequestHandler,
    index: usize,

    fn run(self: *PipelineRunner, allocator: Allocator, request: *anyopaque) ![]const u8 {
        self.index = 0;
        return next(@ptrCast(self), allocator, request);
    }

    fn next(ctx: *anyopaque, allocator: Allocator, request: *anyopaque) anyerror![]const u8 {
        const self: *PipelineRunner = @ptrCast(@alignCast(ctx));
        const idx = self.index;
        const global_len = self.global_behaviors.len;
        const total = global_len + self.key_behaviors.len;

        if (idx < total) {
            self.index = idx + 1;
            const behavior = if (idx < global_len)
                self.global_behaviors[idx]
            else
                self.key_behaviors[idx - global_len];
            return behavior.handle(allocator, request, ctx, next);
        }

        return self.handler.handle(allocator, request);
    }
};

fn SliceMap(comptime T: type) type {
    return struct {
        map: std.StringArrayHashMapUnmanaged(std.ArrayList(T)),
        allocator: Allocator,

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{
                .map = .{},
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            for (self.map.values()) |*list| {
                list.deinit(self.allocator);
            }
            for (self.map.keys()) |key| {
                self.allocator.free(key);
            }
            self.map.deinit(self.allocator);
        }

        fn append(self: *Self, key: []const u8, item: T) !void {
            const result = try self.map.getOrPut(self.allocator, key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
                result.value_ptr.* = .empty;
            }
            try result.value_ptr.append(self.allocator, item);
        }

        fn get(self: *const Self, key: []const u8) ?[]const T {
            const list = self.map.get(key) orelse return null;
            return list.items;
        }
    };
}

pub const Mediator = struct {
    handlers: std.StringArrayHashMapUnmanaged(RequestHandler),
    handlers_keys: std.ArrayList([]u8),

    behaviors: SliceMap(PipelineBehavior),
    pre_processors: SliceMap(PreProcessor),
    post_processors: SliceMap(PostProcessor),
    exception_handlers: SliceMap(ExceptionHandler),
    exception_actions: SliceMap(ExceptionAction),

    subscribers: SliceMap(NotificationHandler),

    global_behaviors: std.ArrayList(PipelineBehavior),

    allocator: Allocator,

    pub fn init(allocator: Allocator) Mediator {
        return .{
            .handlers = .{},
            .handlers_keys = .empty,
            .behaviors = SliceMap(PipelineBehavior).init(allocator),
            .pre_processors = SliceMap(PreProcessor).init(allocator),
            .post_processors = SliceMap(PostProcessor).init(allocator),
            .exception_handlers = SliceMap(ExceptionHandler).init(allocator),
            .exception_actions = SliceMap(ExceptionAction).init(allocator),
            .subscribers = SliceMap(NotificationHandler).init(allocator),
            .global_behaviors = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mediator) void {
        for (self.handlers_keys.items) |key| self.allocator.free(key);
        self.handlers_keys.deinit(self.allocator);
        self.handlers.deinit(self.allocator);

        self.behaviors.deinit();
        self.pre_processors.deinit();
        self.post_processors.deinit();
        self.exception_handlers.deinit();
        self.exception_actions.deinit();
        self.subscribers.deinit();
        self.global_behaviors.deinit(self.allocator);
    }

    pub fn register(self: *Mediator, key: []const u8, handler: RequestHandler) !void {
        const result = try self.handlers.getOrPut(self.allocator, key);
        if (!result.found_existing) {
            const owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned);
            try self.handlers_keys.append(self.allocator, owned);
            result.key_ptr.* = owned;
        }
        result.value_ptr.* = handler;
    }

    pub fn addGlobalBehavior(self: *Mediator, behavior: PipelineBehavior) !void {
        try self.global_behaviors.append(self.allocator, behavior);
    }

    pub fn addBehavior(self: *Mediator, key: []const u8, behavior: PipelineBehavior) !void {
        try self.behaviors.append(key, behavior);
    }

    pub fn addPreProcessor(self: *Mediator, key: []const u8, processor: PreProcessor) !void {
        try self.pre_processors.append(key, processor);
    }

    pub fn addPostProcessor(self: *Mediator, key: []const u8, processor: PostProcessor) !void {
        try self.post_processors.append(key, processor);
    }

    pub fn addExceptionHandler(self: *Mediator, key: []const u8, handler: ExceptionHandler) !void {
        try self.exception_handlers.append(key, handler);
    }

    pub fn addExceptionAction(self: *Mediator, key: []const u8, action: ExceptionAction) !void {
        try self.exception_actions.append(key, action);
    }

    pub fn subscribe(self: *Mediator, key: []const u8, handler: NotificationHandler) !void {
        try self.subscribers.append(key, handler);
    }

    pub fn send(self: *Mediator, allocator: Allocator, key: []const u8, request: *anyopaque) ![]const u8 {
        const handler = self.handlers.get(key) orelse return error.HandlerNotFound;

        if (self.pre_processors.get(key)) |pps| {
            for (pps) |pp| try pp.process(allocator, request);
        }

        const pipeline_result = blk: {
            var runner = PipelineRunner{
                .global_behaviors = self.global_behaviors.items,
                .key_behaviors = self.behaviors.get(key) orelse &.{},
                .handler = handler,
                .index = 0,
            };
            break :blk runner.run(allocator, request);
        } catch |err| {
            if (self.exception_handlers.get(key)) |ehs| {
                for (ehs) |eh| {
                    if (try eh.handle(allocator, request, err)) |fallback| return fallback;
                }
            }
            if (self.exception_actions.get(key)) |eas| {
                for (eas) |ea| ea.execute(allocator, request, err);
            }
            return err;
        };

        var node = pipeline_result;
        if (self.post_processors.get(key)) |pps| {
            for (pps) |pp| node = try pp.process(allocator, request, node);
        }
        return node;
    }

    pub fn publish(self: *Mediator, allocator: Allocator, key: []const u8, notification: *anyopaque) !void {
        const subs = self.subscribers.get(key) orelse return;
        var first_err: ?anyerror = null;
        for (subs) |sub| {
            sub.handle(allocator, notification) catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        if (first_err) |err| return err;
    }

    pub fn has(self: *const Mediator, key: []const u8) bool {
        return self.handlers.contains(key);
    }
};


const TestRequest = struct { value: i32 };

fn textNode(s: []const u8) []const u8 {
    return s;
}

test "send dispatches to registered handler" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, req: *TestRequest) ![]const u8 {
            return textNode(if (req.value == 42) "ok" else "fail");
        }
    };
    var h = Handler{};
    try m.register("GET /test", RequestHandler.from(Handler, TestRequest, &h));

    var req = TestRequest{ .value = 42 };
    const node = try m.send(testing.allocator, "GET /test", @ptrCast(&req));
    try testing.expectEqualStrings("ok", node);
}

test "send returns HandlerNotFound for unregistered key" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    var req = TestRequest{ .value = 0 };
    try testing.expectError(error.HandlerNotFound, m.send(testing.allocator, "GET /missing", @ptrCast(&req)));
}

test "re-registering same key replaces handler" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const H1 = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("first");
        }
    };
    const H2 = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("second");
        }
    };
    var h1 = H1{};
    var h2 = H2{};
    try m.register("GET /x", RequestHandler.from(H1, TestRequest, &h1));
    try m.register("GET /x", RequestHandler.from(H2, TestRequest, &h2));

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /x", @ptrCast(&req));
    try testing.expectEqualStrings("second", node);
}

test "key does not need to outlive register call" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("ok");
        }
    };
    var h = Handler{};

    {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "GET /items", .{}) catch unreachable;
        try m.register(key, RequestHandler.from(Handler, TestRequest, &h));
    }

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /items", @ptrCast(&req));
    try testing.expectEqualStrings("ok", node);
}

test "pipeline behavior wraps handler (reentrant next)" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("handler");
        }
    };
    const Wrapper = struct {
        called: bool = false,
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            self.called = true;
            return next(ctx, alloc, req);
        }
    };

    var h = Handler{};
    var w = Wrapper{};
    try m.register("GET /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addBehavior("GET /t", PipelineBehavior.from(Wrapper, &w));

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /t", @ptrCast(&req));
    try testing.expect(w.called);
    try testing.expectEqualStrings("handler", node);
}

test "nested mediator.send from inside a behavior is safe" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Inner = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("inner");
        }
    };
    var inner_h = Inner{};
    try m.register("GET /inner", RequestHandler.from(Inner, TestRequest, &inner_h));

    const Outer = struct {
        med: *Mediator,
        pub fn handle(self: *@This(), alloc: Allocator, _: *TestRequest) ![]const u8 {
            var req2 = TestRequest{ .value = 0 };
            return self.med.send(alloc, "GET /inner", @ptrCast(&req2));
        }
    };
    var outer_h = Outer{ .med = &m };
    try m.register("GET /outer", RequestHandler.from(Outer, TestRequest, &outer_h));

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /outer", @ptrCast(&req));
    try testing.expectEqualStrings("inner", node);
}

test "global behavior runs for all keys" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("ok");
        }
    };
    const Counter = struct {
        count: usize = 0,
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            self.count += 1;
            return next(ctx, alloc, req);
        }
    };

    var h1 = Handler{};
    var h2 = Handler{};
    var counter = Counter{};
    try m.register("GET /a", RequestHandler.from(Handler, TestRequest, &h1));
    try m.register("GET /b", RequestHandler.from(Handler, TestRequest, &h2));
    try m.addGlobalBehavior(PipelineBehavior.from(Counter, &counter));

    var req = TestRequest{ .value = 0 };
    _ = try m.send(testing.allocator, "GET /a", @ptrCast(&req));
    _ = try m.send(testing.allocator, "GET /b", @ptrCast(&req));
    try testing.expectEqual(@as(usize, 2), counter.count);
}

test "global behaviors run before key behaviors" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    var order = std.ArrayList(u8).empty;
    defer order.deinit(testing.allocator);

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("ok");
        }
    };
    const GlobalB = struct {
        o: *std.ArrayList(u8),
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            try self.o.append(testing.allocator, 'G');
            return next(ctx, alloc, req);
        }
    };
    const KeyB = struct {
        o: *std.ArrayList(u8),
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            try self.o.append(testing.allocator, 'K');
            return next(ctx, alloc, req);
        }
    };

    var h = Handler{};
    var gb = GlobalB{ .o = &order };
    var kb = KeyB{ .o = &order };
    try m.register("GET /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addGlobalBehavior(PipelineBehavior.from(GlobalB, &gb));
    try m.addBehavior("GET /t", PipelineBehavior.from(KeyB, &kb));

    var req = TestRequest{ .value = 0 };
    _ = try m.send(testing.allocator, "GET /t", @ptrCast(&req));
    try testing.expectEqualStrings("GK", order.items);
}

test "pre-processor mutates request before handler" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, req: *TestRequest) ![]const u8 {
            return textNode(if (req.value == 99) "mutated" else "original");
        }
    };
    const Mutator = struct {
        pub fn process(_: *@This(), _: Allocator, req: *TestRequest) !void {
            req.value = 99;
        }
    };

    var h = Handler{};
    var mut = Mutator{};
    try m.register("POST /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addPreProcessor("POST /t", PreProcessor.from(Mutator, TestRequest, &mut));

    var req = TestRequest{ .value = 1 };
    const node = try m.send(testing.allocator, "POST /t", @ptrCast(&req));
    try testing.expectEqualStrings("mutated", node);
}

test "pre-processor short-circuits before handler runs" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("should not reach");
        }
    };
    const Rejector = struct {
        pub fn process(_: *@This(), _: Allocator, _: *TestRequest) !void {
            return error.ValidationFailed;
        }
    };

    var h = Handler{};
    var r = Rejector{};
    try m.register("POST /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addPreProcessor("POST /t", PreProcessor.from(Rejector, TestRequest, &r));

    var req = TestRequest{ .value = 0 };
    try testing.expectError(error.ValidationFailed, m.send(testing.allocator, "POST /t", @ptrCast(&req)));
}

test "post-processor transforms response" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("original");
        }
    };
    const Xform = struct {
        pub fn process(_: *@This(), _: Allocator, _: *TestRequest, _: []const u8) ![]const u8 {
            return textNode("transformed");
        }
    };

    var h = Handler{};
    var x = Xform{};
    try m.register("GET /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addPostProcessor("GET /t", PostProcessor.from(Xform, TestRequest, &x));

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /t", @ptrCast(&req));
    try testing.expectEqualStrings("transformed", node);
}

test "exception handler provides fallback" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const FailH = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return error.NotFound;
        }
    };
    const Fallback = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest, _: anyerror) !?[]const u8 {
            return textNode("fallback");
        }
    };

    var h = FailH{};
    var fb = Fallback{};
    try m.register("GET /t", RequestHandler.from(FailH, TestRequest, &h));
    try m.addExceptionHandler("GET /t", ExceptionHandler.from(Fallback, TestRequest, &fb));

    var req = TestRequest{ .value = 0 };
    const node = try m.send(testing.allocator, "GET /t", @ptrCast(&req));
    try testing.expectEqualStrings("fallback", node);
}

test "exception handler returning null propagates error" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const FailH = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return error.NotFound;
        }
    };
    const PassThru = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest, _: anyerror) !?[]const u8 {
            return null;
        }
    };

    var h = FailH{};
    var pt = PassThru{};
    try m.register("GET /t", RequestHandler.from(FailH, TestRequest, &h));
    try m.addExceptionHandler("GET /t", ExceptionHandler.from(PassThru, TestRequest, &pt));

    var req = TestRequest{ .value = 0 };
    try testing.expectError(error.NotFound, m.send(testing.allocator, "GET /t", @ptrCast(&req)));
}

test "exception action observes error without swallowing it" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const FailH = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return error.Unexpected;
        }
    };
    const ErrLog = struct {
        logged: bool = false,
        pub fn execute(self: *@This(), _: Allocator, _: *TestRequest, _: anyerror) void {
            self.logged = true;
        }
    };

    var h = FailH{};
    var log = ErrLog{};
    try m.register("GET /t", RequestHandler.from(FailH, TestRequest, &h));
    try m.addExceptionAction("GET /t", ExceptionAction.from(ErrLog, TestRequest, &log));

    var req = TestRequest{ .value = 0 };
    try testing.expectError(error.Unexpected, m.send(testing.allocator, "GET /t", @ptrCast(&req)));
    try testing.expect(log.logged);
}

test "publish fans out to all subscribers" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Event = struct { name: []const u8 };
    const Listener = struct {
        heard: bool = false,
        pub fn handle(self: *@This(), _: Allocator, _: *Event) !void {
            self.heard = true;
        }
    };

    var l1 = Listener{};
    var l2 = Listener{};
    try m.subscribe("evt", NotificationHandler.from(Listener, Event, &l1));
    try m.subscribe("evt", NotificationHandler.from(Listener, Event, &l2));

    var evt = Event{ .name = "test" };
    try m.publish(testing.allocator, "evt", @ptrCast(&evt));
    try testing.expect(l1.heard);
    try testing.expect(l2.heard);
}

test "publish runs all subscribers even if one errors" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Event = struct {};
    const FailL = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *Event) !void {
            return error.ListenerFailed;
        }
    };
    const OkL = struct {
        called: bool = false,
        pub fn handle(self: *@This(), _: Allocator, _: *Event) !void {
            self.called = true;
        }
    };

    var fl = FailL{};
    var ok = OkL{};
    try m.subscribe("evt", NotificationHandler.from(FailL, Event, &fl));
    try m.subscribe("evt", NotificationHandler.from(OkL, Event, &ok));

    var evt = Event{};
    try testing.expectError(error.ListenerFailed, m.publish(testing.allocator, "evt", @ptrCast(&evt)));
    try testing.expect(ok.called);
}

test "has returns correct presence" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    const Handler = struct {
        pub fn handle(_: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            return textNode("ok");
        }
    };
    var h = Handler{};
    try m.register("GET /x", RequestHandler.from(Handler, TestRequest, &h));
    try testing.expect(m.has("GET /x"));
    try testing.expect(!m.has("GET /y"));
}

test "full pipeline order: pre → global → key → handler → post" {
    var m = Mediator.init(testing.allocator);
    defer m.deinit();

    var order = std.ArrayList(u8).empty;
    defer order.deinit(testing.allocator);

    const Pre = struct {
        o: *std.ArrayList(u8),
        pub fn process(self: *@This(), _: Allocator, _: *TestRequest) !void {
            try self.o.append(testing.allocator, 'P');
        }
    };
    const Global = struct {
        o: *std.ArrayList(u8),
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            try self.o.append(testing.allocator, 'G');
            return next(ctx, alloc, req);
        }
    };
    const KeyB = struct {
        o: *std.ArrayList(u8),
        pub fn handle(self: *@This(), alloc: Allocator, req: *anyopaque, ctx: *anyopaque, next: PipelineBehavior.NextFn) ![]const u8 {
            try self.o.append(testing.allocator, 'B');
            return next(ctx, alloc, req);
        }
    };
    const Handler = struct {
        o: *std.ArrayList(u8),
        pub fn handle(self: *@This(), _: Allocator, _: *TestRequest) ![]const u8 {
            try self.o.append(testing.allocator, 'H');
            return textNode("result");
        }
    };
    const Post = struct {
        o: *std.ArrayList(u8),
        pub fn process(self: *@This(), _: Allocator, _: *TestRequest, resp: []const u8) ![]const u8 {
            try self.o.append(testing.allocator, 'O');
            return resp;
        }
    };

    var pre = Pre{ .o = &order };
    var gb = Global{ .o = &order };
    var kb = KeyB{ .o = &order };
    var h = Handler{ .o = &order };
    var post = Post{ .o = &order };

    try m.register("GET /t", RequestHandler.from(Handler, TestRequest, &h));
    try m.addPreProcessor("GET /t", PreProcessor.from(Pre, TestRequest, &pre));
    try m.addGlobalBehavior(PipelineBehavior.from(Global, &gb));
    try m.addBehavior("GET /t", PipelineBehavior.from(KeyB, &kb));
    try m.addPostProcessor("GET /t", PostProcessor.from(Post, TestRequest, &post));

    var req = TestRequest{ .value = 0 };
    _ = try m.send(testing.allocator, "GET /t", @ptrCast(&req));
    try testing.expectEqualStrings("PGBHO", order.items);
}
