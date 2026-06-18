
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Currency = enum {
    INR,
    USD,
    EUR,
    GBP,

    pub fn toString(self: Currency) []const u8 {
        return switch (self) {
            .INR => "inr",
            .USD => "usd",
            .EUR => "eur",
            .GBP => "gbp",
        };
    }
};

pub const CreatePaymentOptions = struct {
    amount: i64,
    currency: Currency = .INR,
    description: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    customer_email: ?[]const u8 = null,
    receipt: ?[]const u8 = null,
};

pub const PaymentIntent = struct {
    id: []const u8,
    client_secret: ?[]const u8 = null,
    redirect_url: ?[]const u8 = null,
    amount: i64,
    currency: []const u8,
    status: []const u8,
    provider: []const u8,
    raw_response: []const u8,
};

pub const PaymentStatus = struct {
    id: []const u8,
    status: []const u8,
    amount: i64,
    currency: []const u8,
    transaction_id: ?[]const u8 = null,
    payment_method: ?[]const u8 = null,
    paid_at: ?i64 = null,
    provider: []const u8,
    raw_response: []const u8,
};

pub const RefundResult = struct {
    id: []const u8,
    payment_id: []const u8,
    amount: i64,
    status: []const u8,
    provider: []const u8,
    raw_response: []const u8,
};

pub const WebhookEvent = struct {
    event_type: []const u8,
    payment_id: []const u8,
    data: []const u8,
    provider: []const u8,
};

pub const PaymentProvider = struct {
    ptr: *anyopaque,

    createIntentFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        opts: CreatePaymentOptions,
    ) anyerror!PaymentIntent,

    verifyPaymentFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        payment_id: []const u8,
    ) anyerror!PaymentStatus,

    refundFn: ?*const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        io: Io,
        payment_id: []const u8,
        amount: ?i64,
    ) anyerror!RefundResult = null,

    verifyWebhookFn: ?*const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        payload: []const u8,
        signature: []const u8,
    ) anyerror!?WebhookEvent = null,

    pub fn createPaymentIntent(self: PaymentProvider, allocator: Allocator, io: Io, opts: CreatePaymentOptions) !PaymentIntent {
        return self.createIntentFn(self.ptr, allocator, io, opts);
    }

    pub fn verifyPayment(self: PaymentProvider, allocator: Allocator, io: Io, payment_id: []const u8) !PaymentStatus {
        return self.verifyPaymentFn(self.ptr, allocator, io, payment_id);
    }

    pub fn refund(self: PaymentProvider, allocator: Allocator, io: Io, payment_id: []const u8, amount: ?i64) !RefundResult {
        if (self.refundFn) |f| return f(self.ptr, allocator, io, payment_id, amount);
        return error.RefundNotSupported;
    }

    pub fn verifyWebhook(self: PaymentProvider, allocator: Allocator, payload: []const u8, signature: []const u8) !?WebhookEvent {
        if (self.verifyWebhookFn) |f| return f(self.ptr, allocator, payload, signature);
        return null;
    }

    pub fn from(comptime T: type, ptr: *T) PaymentProvider {
        const has_refund = @hasDecl(T, "refund");
        const has_webhook = @hasDecl(T, "verifyWebhook");
        return .{
            .ptr = @ptrCast(ptr),
            .createIntentFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, opts: CreatePaymentOptions) anyerror!PaymentIntent {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.createPaymentIntent(alloc, io, opts);
                }
            }.f,
            .verifyPaymentFn = struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, pid: []const u8) anyerror!PaymentStatus {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.verifyPayment(alloc, io, pid);
                }
            }.f,
            .refundFn = if (has_refund) struct {
                fn f(p: *anyopaque, alloc: Allocator, io: Io, pid: []const u8, amount: ?i64) anyerror!RefundResult {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.refund(alloc, io, pid, amount);
                }
            }.f else null,
            .verifyWebhookFn = if (has_webhook) struct {
                fn f(p: *anyopaque, alloc: Allocator, payload: []const u8, sig: []const u8) anyerror!?WebhookEvent {
                    const self: *T = @ptrCast(@alignCast(p));
                    return self.verifyWebhook(alloc, payload, sig);
                }
            }.f else null,
        };
    }
};
