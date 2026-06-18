
const std = @import("std");

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

pub const MultipartParser = struct {
    boundary: []const u8,
    body: []const u8,

    pub fn init(content_type: []const u8, body: []const u8) ?MultipartParser {
        if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return null;

        const boundary = extractBoundary(content_type) orelse return null;
        return .{ .boundary = boundary, .body = body };
    }

    pub fn iterator(self: *const MultipartParser) PartIterator {
        return .{ .boundary = self.boundary, .body = self.body, .pos = 0 };
    }

    fn extractBoundary(content_type: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + 9 <= content_type.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(content_type[i..][0..9], "boundary=")) {
                var boundary = content_type[i + 9 ..];
                if (boundary.len >= 2 and boundary[0] == '"') {
                    if (std.mem.indexOfScalar(u8, boundary[1..], '"')) |end| {
                        boundary = boundary[1..][0..end];
                    }
                }
                boundary = std.mem.trim(u8, boundary, " \t\r\n");
                return if (boundary.len > 0) boundary else null;
            }
        }
        return null;
    }
};

pub const PartIterator = struct {
    boundary: []const u8,
    body: []const u8,
    pos: usize,

    pub fn next(self: *PartIterator) ?Part {
        while (self.pos < self.body.len) {
            const marker_start = std.mem.indexOf(u8, self.body[self.pos..], "--") orelse return null;
            const abs_start = self.pos + marker_start;

            const after_dashes = abs_start + 2;
            if (after_dashes + self.boundary.len > self.body.len) return null;

            if (!std.mem.eql(u8, self.body[after_dashes..][0..self.boundary.len], self.boundary)) {
                self.pos = after_dashes;
                continue;
            }

            const after_boundary = after_dashes + self.boundary.len;
            if (after_boundary + 2 <= self.body.len and
                self.body[after_boundary] == '-' and self.body[after_boundary + 1] == '-')
            {
                return null;
            }

            var part_start = after_boundary;
            if (part_start < self.body.len and self.body[part_start] == '\r') part_start += 1;
            if (part_start < self.body.len and self.body[part_start] == '\n') part_start += 1;

            const next_boundary_search = std.mem.indexOf(u8, self.body[part_start..], "--") orelse {
                self.pos = self.body.len;
                return null;
            };

            var search_pos = part_start;
            const part_end = while (search_pos < self.body.len) {
                const idx = std.mem.indexOf(u8, self.body[search_pos..], "--") orelse break null;
                const abs_idx = search_pos + idx;
                const check = abs_idx + 2;
                if (check + self.boundary.len <= self.body.len and
                    std.mem.eql(u8, self.body[check..][0..self.boundary.len], self.boundary))
                {
                    var end = abs_idx;
                    if (end > 0 and self.body[end - 1] == '\n') end -= 1;
                    if (end > 0 and self.body[end - 1] == '\r') end -= 1;
                    break end;
                }
                search_pos = abs_idx + 2;
            } else null;

            _ = next_boundary_search;

            if (part_end == null) {
                self.pos = self.body.len;
                return null;
            }

            const part_data = self.body[part_start..part_end.?];
            self.pos = part_end.?;

            return parsePart(part_data);
        }
        return null;
    }

    fn parsePart(raw: []const u8) ?Part {
        const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse {
            const sep2 = std.mem.indexOf(u8, raw, "\n\n") orelse return null;
            return parsePartWithSep(raw, sep2, sep2 + 2);
        };
        return parsePartWithSep(raw, sep, sep + 4);
    }

    fn parsePartWithSep(raw: []const u8, header_end: usize, data_start: usize) ?Part {
        const headers = raw[0..header_end];
        const data = if (data_start < raw.len) raw[data_start..] else "";

        var name: []const u8 = "";
        var filename: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;

        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:")) {
                const val = std.mem.trim(u8, line["content-disposition:".len..], " ");
                name = extractParam(val, "name") orelse "";
                filename = extractParam(val, "filename");
            } else if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                content_type = std.mem.trim(u8, line["content-type:".len..], " ");
            }
        }

        if (name.len == 0 and filename == null) return null;

        return .{
            .name = name,
            .filename = filename,
            .content_type = content_type,
            .data = data,
        };
    }

    fn extractParam(header: []const u8, param_name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + param_name.len + 1 < header.len) : (i += 1) {
            if (!std.mem.eql(u8, header[i..][0..param_name.len], param_name)) continue;
            const after_name = i + param_name.len;
            if (header[after_name] != '=') continue;

            const val_start = after_name + 1;
            if (val_start >= header.len) return null;

            if (header[val_start] == '"') {
                const end = std.mem.indexOfScalar(u8, header[val_start + 1 ..], '"') orelse return null;
                return header[val_start + 1 ..][0..end];
            } else {
                const end = std.mem.indexOfAny(u8, header[val_start..], "; \t") orelse header.len - val_start;
                return header[val_start..][0..end];
            }
        }
        return null;
    }
};


test "parse multipart with file upload" {
    const content_type = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const body =
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"action\"\r\n" ++
        "\r\n" ++
        "deploy-binary\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"binary\"; filename=\"app.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "\x00asm\x01\x02\x03\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n";

    var parser = MultipartParser.init(content_type, body) orelse unreachable;
    var iter = parser.iterator();

    const p1 = iter.next() orelse unreachable;
    try std.testing.expectEqualStrings("action", p1.name);
    try std.testing.expectEqualStrings("deploy-binary", p1.data);
    try std.testing.expect(p1.filename == null);

    const p2 = iter.next() orelse unreachable;
    try std.testing.expectEqualStrings("binary", p2.name);
    try std.testing.expectEqualStrings("app.bin", p2.filename.?);
    try std.testing.expectEqualStrings("application/octet-stream", p2.content_type.?);
    try std.testing.expectEqualStrings("\x00asm\x01\x02\x03", p2.data);

    try std.testing.expect(iter.next() == null);
}

test "extract boundary from content type" {
    const p1 = MultipartParser.init("multipart/form-data; boundary=abc123", "");
    try std.testing.expect(p1 != null);
    try std.testing.expectEqualStrings("abc123", p1.?.boundary);

    const p2 = MultipartParser.init("multipart/form-data; boundary=\"quoted-boundary\"", "");
    try std.testing.expect(p2 != null);
    try std.testing.expectEqualStrings("quoted-boundary", p2.?.boundary);

    const p3 = MultipartParser.init("application/json", "");
    try std.testing.expect(p3 == null);
}
