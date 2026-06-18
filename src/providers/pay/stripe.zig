
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Client = @import("../../client.zig").Client;
const util = @import("../provider_util.zig");
const provider = @import("provider.zig");
const PaymentProvider = provider.PaymentProvider;
const PaymentIntent = provider.PaymentIntent;
const PaymentStatus = provider.PaymentStatus;
const RefundResult = provider.RefundResult;
const WebhookEvent = provider.WebhookEvent;
const CreatePaymentOptions = provider.CreatePaymentOptions;

pub const StripeConfig = struct {
    secret_key: []const u8,
    publishable_key: []const u8 = "",
    webhook_secret: ?[]const u8 = null,
};

pub const StripeProvider = struct {
    config: StripeConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: StripeConfig) StripeProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn paymentProvider(self: *StripeProvider) PaymentProvider {
        return PaymentProvider.from(StripeProvider, self);
    }

    pub fn createPaymentIntent(self: *StripeProvider, allocator: Allocator, io: Io, opts: CreatePaymentOptions) !PaymentIntent {
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(allocator);

        try body_buf.print(allocator, "amount={d}&currency={s}", .{ opts.amount, opts.currency.toString() });
        if (opts.description) |d| try body_buf.print(allocator, "&description={s}", .{d});
        if (opts.customer_email) |e| try body_buf.print(allocator, "&receipt_email={s}", .{e});
        if (opts.metadata) |m| {
            var pairs = std.mem.splitScalar(u8, m, '&');
            while (pairs.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                try body_buf.print(allocator, "&metadata[{s}]={s}", .{ pair[0..eq], pair[eq + 1 ..] });
            }
        }

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.secret_key});
        defer allocator.free(auth_header);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://api.stripe.com/v1/payment_intents",
            .headers = &.{
                .{ "Content-Type", "application/x-www-form-urlencoded" },
                .{ "Authorization", auth_header },
            },
            .body = body_buf.items,
        });
        defer resp.deinit();

        return parsePaymentIntent(allocator, resp.body);
    }

    pub fn verifyPayment(self: *StripeProvider, allocator: Allocator, io: Io, payment_id: []const u8) !PaymentStatus {
        const url = try std.fmt.allocPrint(allocator, "https://api.stripe.com/v1/payment_intents/{s}", .{payment_id});
        defer allocator.free(url);
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.secret_key});
        defer allocator.free(auth_header);

        var resp = try Client.request(allocator, io, .{
            .url = url,
            .headers = &.{.{ "Authorization", auth_header }},
        });
        defer resp.deinit();

        return parsePaymentStatus(allocator, resp.body);
    }

    pub fn refund(self: *StripeProvider, allocator: Allocator, io: Io, payment_id: []const u8, amount: ?i64) !RefundResult {
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(allocator);

        try body_buf.print(allocator, "payment_intent={s}", .{payment_id});
        if (amount) |a| try body_buf.print(allocator, "&amount={d}", .{a});

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.secret_key});
        defer allocator.free(auth_header);

        var resp = try Client.request(allocator, io, .{
            .method = "POST",
            .url = "https://api.stripe.com/v1/refunds",
            .headers = &.{
                .{ "Content-Type", "application/x-www-form-urlencoded" },
                .{ "Authorization", auth_header },
            },
            .body = body_buf.items,
        });
        defer resp.deinit();

        return parseRefund(allocator, resp.body, payment_id);
    }

    pub fn verifyWebhook(self: *StripeProvider, allocator: Allocator, payload: []const u8, signature: []const u8) !?WebhookEvent {
        const secret = self.config.webhook_secret orelse return null;
        if (!verifyStripeSignature(secret, payload, signature)) return null;
        return parseWebhookEvent(allocator, payload);
    }

    
    fn parsePaymentIntent(allocator: Allocator, body: []const u8) !PaymentIntent {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        return PaymentIntent{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .client_secret = if (obj.get("client_secret")) |cs| try allocator.dupe(u8, cs.string) else null,
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .currency = try allocator.dupe(u8, if (obj.get("currency")) |c| c.string else "usd"),
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "created"),
            .provider = "stripe",
            .raw_response = try allocator.dupe(u8, body),
        };
    }

    fn parsePaymentStatus(allocator: Allocator, body: []const u8) !PaymentStatus {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        return PaymentStatus{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "unknown"),
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .currency = try allocator.dupe(u8, if (obj.get("currency")) |c| c.string else "usd"),
            .transaction_id = if (obj.get("latest_charge")) |ch| try allocator.dupe(u8, ch.string) else null,
            .paid_at = if (obj.get("created")) |cr| cr.integer * 1000 else null,
            .provider = "stripe",
            .raw_response = try allocator.dupe(u8, body),
        };
    }

    fn parseRefund(allocator: Allocator, body: []const u8, payment_id: []const u8) !RefundResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        return RefundResult{
            .id = try allocator.dupe(u8, (obj.get("id") orelse return error.InvalidResponse).string),
            .payment_id = try allocator.dupe(u8, payment_id),
            .amount = if (obj.get("amount")) |a| a.integer else 0,
            .status = try allocator.dupe(u8, if (obj.get("status")) |s| s.string else "pending"),
            .provider = "stripe",
            .raw_response = try allocator.dupe(u8, body),
        };
    }

    fn parseWebhookEvent(allocator: Allocator, payload: []const u8) !?WebhookEvent {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        const event_type = (obj.get("type") orelse return null).string;
        const data_obj = (obj.get("data") orelse return null).object;
        const pi_obj = (data_obj.get("object") orelse return null).object;
        const payment_id = (pi_obj.get("id") orelse return null).string;

        return WebhookEvent{
            .event_type = try allocator.dupe(u8, event_type),
            .payment_id = try allocator.dupe(u8, payment_id),
            .data = try allocator.dupe(u8, payload),
            .provider = "stripe",
        };
    }

    pub fn verifyStripeSignature(secret: []const u8, payload: []const u8, header: []const u8) bool {
        var ts: ?[]const u8 = null;
        var parts = std.mem.splitScalar(u8, header, ',');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            if (std.mem.startsWith(u8, part, "t=")) {
                ts = part[2..];
                break;
            }
        }
        const timestamp = ts orelse return false;

        parts = std.mem.splitScalar(u8, header, ',');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            if (!std.mem.startsWith(u8, part, "v1=")) continue;
            const sig = part[3..];
            if (util.verifyHmacSha256(secret, &.{ timestamp, ".", payload }, sig)) {
                return true;
            }
        }
        return false;
    }
};
