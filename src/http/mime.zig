
const std = @import("std");

pub const Mime = enum {
    text_plain,
    text_html,
    text_css,
    text_javascript,
    text_csv,
    application_json,
    application_octet_stream,
    application_javascript,
    image_jpeg,
    image_png,
    image_gif,
    image_svg_xml,
    image_webp,
    font_woff2,

    
    pub fn fromExtension(ext: []const u8) ?Mime {
        if (ext.len == 0) return null;
        var buf: [16]u8 = undefined;
        const len = @min(ext.len, buf.len);
        for (ext[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const e = buf[0..len];

        if (std.mem.eql(u8, e, "html") or std.mem.eql(u8, e, "htm")) return .text_html;
        if (std.mem.eql(u8, e, "css")) return .text_css;
        if (std.mem.eql(u8, e, "js")) return .application_javascript;
        if (std.mem.eql(u8, e, "json")) return .application_json;
        if (std.mem.eql(u8, e, "txt")) return .text_plain;
        if (std.mem.eql(u8, e, "csv")) return .text_csv;
        if (std.mem.eql(u8, e, "png")) return .image_png;
        if (std.mem.eql(u8, e, "jpg") or std.mem.eql(u8, e, "jpeg")) return .image_jpeg;
        if (std.mem.eql(u8, e, "gif")) return .image_gif;
        if (std.mem.eql(u8, e, "svg")) return .image_svg_xml;
        if (std.mem.eql(u8, e, "webp")) return .image_webp;
        if (std.mem.eql(u8, e, "woff2")) return .font_woff2;
        return null;
    }

    
    pub fn toHttpString(self: Mime) []const u8 {
        return switch (self) {
            .text_plain => "text/plain",
            .text_html => "text/html; charset=utf-8",
            .text_css => "text/css",
            .text_javascript => "text/javascript",
            .text_csv => "text/csv",
            .application_json => "application/json",
            .application_octet_stream => "application/octet-stream",
            .application_javascript => "application/javascript",
            .image_jpeg => "image/jpeg",
            .image_png => "image/png",
            .image_gif => "image/gif",
            .image_svg_xml => "image/svg+xml",
            .image_webp => "image/webp",
            .font_woff2 => "font/woff2",
        };
    }
};
