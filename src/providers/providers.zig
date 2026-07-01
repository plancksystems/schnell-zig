const std = @import("std");
const auth = @import("auth/root.zig");
const pay = @import("pay/root.zig");
const notify = @import("notify/root.zig");
const Yaml = @import("yaml").Yaml;

pub const Providers = struct {
    google_oauth: ?auth.GoogleConfig = null,
    azure_oauth: ?auth.AzureConfig = null,
    firebase: ?auth.FirebaseConfig = null,
    cookie: ?auth.CookieAuthConfig = null,
    stripe: ?pay.StripeConfig = null,
    razorpay: ?pay.RazorpayConfig = null,
    sendgrid: ?notify.SendGridConfig = null,
    fcm: ?notify.FcmConfig = null,
    smtp: ?notify.SmtpConfig = null,
    twilio: ?notify.TwilioConfig = null,

    pub fn init(allocator: std.mem.Allocator, yaml_text: []const u8) !*Providers {
        if (yaml_text.len == 0) {
            const self = try allocator.create(Providers);
            self.* = .{};
            return self;
        }

        var y = Yaml{ .source = yaml_text };
        try y.load(allocator);
        defer y.deinit(allocator);

        const self = try allocator.create(Providers);
        errdefer allocator.destroy(self);
        self.* = try y.parse(allocator, Providers);
        return self;
    }

    pub fn deinit(self: *Providers, allocator: std.mem.Allocator) void {
        defer allocator.destroy(self);
        if (self.google_oauth) |google| {
            allocator.free(google.client_id);
            allocator.free(google.client_secret);
            allocator.free(google.redirect_uri);
            allocator.free(google.scopes);
        }
        if (self.azure_oauth) |azure| {
            allocator.free(azure.client_id);
            allocator.free(azure.client_secret);
            allocator.free(azure.redirect_uri);
            allocator.free(azure.scopes);
        }
        if (self.firebase) |firebase| {
            allocator.free(firebase.api_key);
            allocator.free(firebase.project_id);
        }
        if (self.cookie) |cookie| {
            allocator.free(cookie.cookie_name);
            allocator.free(cookie.session_lookup_url);
            allocator.free(cookie.field_mappings);
            allocator.free(cookie.skip_paths);
        }
        if (self.stripe) |stripe| {
            allocator.free(stripe.secret_key);
            allocator.free(stripe.webhook_secret);
            allocator.free(stripe.publishable_key);
        }
        if (self.razorpay) |razorpay| {
            allocator.free(razorpay.key_id);
            allocator.free(razorpay.key_secret);
            if (razorpay.webhook_secret) |wh| {
                allocator.free(wh);
            }
        }
        if (self.sendgrid) |sendgrid| {
            allocator.free(sendgrid.api_key);
            allocator.free(sendgrid.default_from);
        }
        if (self.fcm) |fcm| {
            allocator.free(fcm.access_token);
            allocator.free(fcm.project_id);
        }
        if (self.smtp) |smtp| {
            allocator.free(smtp.host);
            allocator.free(smtp.default_from);
            allocator.free(smtp.username);
            allocator.free(smtp.password);
        }
        if (self.twilio) |twilio| {
            allocator.free(twilio.account_sid);
            allocator.free(twilio.auth_token);
            allocator.free(twilio.from_number);
        }
    }
};
