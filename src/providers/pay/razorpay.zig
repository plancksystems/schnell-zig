
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const schnell = @import("schnell");
const Client = schnell.Client;
const util = @import("../provider_util.zig");
const provider = @import("provider.zig");
const PaymentProvider = provider.PaymentProvider;
const PaymentIntent = provider.PaymentIntent;
const PaymentStatus = provider.PaymentStatus;
const RefundResult = provider.RefundResult;
const WebhookEvent = provider.WebhookEvent;
const CreatePaymentOptions = provider.CreatePaymentOptions;

pub const RazorpayConfig = struct {
    key_id: []const u8,
    key_secret: []const u8,
    webhook_secret: ?[]const u8 = null,
};

pub const RazorpayProvider = struct {
    config: RazorpayConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: RazorpayConfig) RazorpayProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn paymentProvider(self: *RazorpayProvider) PaymentProvider {
        return PaymentProvider.from(RazorpayProvider, self);
    }

    pub fn createPaymentIntent(self: *RazorpayProvider, allocator: Allocator, io: Io, opts: CreatePaymentOptions) !PaymentIntent {
        const body = try std.fmt.allocPrint(allocator,
            "{{\"amount\":{d},\"currency\":\"{s}\",\"receipt\":\"{s}\"}}",
            .{ opts.amount, opts.currency.toString(), opts.receipt orelse "auto" },
        );
        defer allocator.free(body);
        const auth = try util.basicAuth(allocator, self.config.key_id, self.config.key_secret);
        defer allocator.free(auth);
        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://api.razorpay.com/v1/orders",
            .headers = &.{
                .{ "Content-Type", "application/json" },
                .{ "Authorization", auth },
            },
            .body = body,
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        return PaymentIntent{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .currency = try allocator.dupe(u8, if (obj.get("currency")) |c| c.string else "inr"),
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "created"),
            .provider = "razorpay",
            .raw_response = try allocator.dupe(u8, resp.body),
        };
    }

    pub fn verifyPayment(self: *RazorpayProvider, allocator: Allocator, io: Io, payment_id: []const u8) !PaymentStatus {
        const url = try std.fmt.allocPrint(allocator, "https://api.razorpay.com/v1/payments/{s}", .{payment_id});
        defer allocator.free(url);
        const auth = try util.basicAuth(allocator, self.config.key_id, self.config.key_secret);
        defer allocator.free(auth);
        var resp = try Client.request(allocator, io, .{
            .url = url,
            .headers = &.{.{ "Authorization", auth }},
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        return PaymentStatus{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "unknown"),
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .currency = try allocator.dupe(u8, if (obj.get("currency")) |c| c.string else "inr"),
            .transaction_id = if (obj.get("acquirer_data")) |ad| blk: {
                break :blk if (ad.object.get("rrn")) |rrn| try allocator.dupe(u8, rrn.string) else null;
            } else null,
            .provider = "razorpay",
            .raw_response = try allocator.dupe(u8, resp.body),
        };
    }

    pub fn refund(self: *RazorpayProvider, allocator: Allocator, io: Io, payment_id: []const u8, amount: ?i64) !RefundResult {
        const url = try std.fmt.allocPrint(allocator, "https://api.razorpay.com/v1/payments/{s}/refund", .{payment_id});
        defer allocator.free(url);
        const body = if (amount) |a|
            try std.fmt.allocPrint(allocator, "{{\"amount\":{d}}}", .{a})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(body);
        const auth = try util.basicAuth(allocator, self.config.key_id, self.config.key_secret);
        defer allocator.free(auth);
        var resp = try Client.request(allocator, io, .{
            .method = "POST", .url = url,
            .headers = &.{
                .{ "Content-Type", "application/json" },
                .{ "Authorization", auth },
            },
            .body = body,
        });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        return RefundResult{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .payment_id = try allocator.dupe(u8, payment_id),
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "pending"),
            .provider = "razorpay",
            .raw_response = try allocator.dupe(u8, resp.body),
        };
    }

    pub fn verifyWebhook(self: *RazorpayProvider, allocator: Allocator, payload: []const u8, signature: []const u8) !?WebhookEvent {
        const secret = self.config.webhook_secret orelse return null;

        if (!util.verifyHmacSha256(secret, &.{payload}, signature)) return null;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const event_type = (obj.get("event") orelse return null).string;
        const payment_entity = blk: {
            const pl = obj.get("payload") orelse break :blk null;
            const payment = pl.object.get("payment") orelse break :blk null;
            break :blk payment.object.get("entity");
        };
        const payment_id = if (payment_entity) |pe| (pe.object.get("id") orelse return null).string else return null;

        return WebhookEvent{
            .event_type = try allocator.dupe(u8, event_type),
            .payment_id = try allocator.dupe(u8, payment_id),
            .data = try allocator.dupe(u8, payload),
            .provider = "razorpay",
        };
    }
};
