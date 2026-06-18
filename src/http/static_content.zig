
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Mime = @import("mime.zig").Mime;

pub const StaticFile = struct {
    path: []const u8,
    data: []const u8,
    mime: ?Mime,
    etag: []const u8,
    embedded: bool = false,
};

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub const StaticContentStore = struct {
    allocator: Allocator,
    files: std.StringHashMapUnmanaged(StaticFile),
    static_dir: []const u8,

    pub fn init(allocator: Allocator, static_dir: []const u8) !StaticContentStore {
        return .{
            .allocator = allocator,
            .files = .empty,
            .static_dir = try allocator.dupe(u8, static_dir),
        };
    }

    pub fn deinit(self: *StaticContentStore) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (!entry.value_ptr.embedded) {
                self.allocator.free(entry.value_ptr.path);
                self.allocator.free(entry.value_ptr.data);
            }
            self.allocator.free(entry.value_ptr.etag);
        }
        self.files.deinit(self.allocator);
        if (self.static_dir.len > 0) self.allocator.free(self.static_dir);
    }

    
    pub fn loadDirectory(self: *StaticContentStore, io: Io) !usize {
        var cwd = Io.Dir.cwd();
        var target_dir = try cwd.openDir(io, self.static_dir, .{ .iterate = true });
        defer target_dir.close(io);

        var count: usize = 0;
        try self.walkDirectory(io, target_dir, "", &count);
        return count;
    }

    fn walkDirectory(self: *StaticContentStore, io: Io, dir: Io.Dir, rel_path: []const u8, count: *usize) !void {
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const entry_path = if (rel_path.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(self.allocator, &[_][]const u8{ rel_path, entry.name });
            defer self.allocator.free(entry_path);

            switch (entry.kind) {
                .file => {
                    try self.loadFile(io, entry_path);
                    count.* += 1;
                },
                .directory => {
                    const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.static_dir, entry_path });
                    defer self.allocator.free(full_path);

                    var cwd = Io.Dir.cwd();
                    var sub_dir = try cwd.openDir(io, full_path, .{ .iterate = true });
                    defer sub_dir.close(io);

                    try self.walkDirectory(io, sub_dir, entry_path, count);
                },
                else => {},  
            }
        }
    }

    fn loadFile(self: *StaticContentStore, io: Io, rel_path: []const u8) !void {
        const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.static_dir, rel_path });
        defer self.allocator.free(full_path);

        var cwd = Io.Dir.cwd();
        const file = try cwd.openFile(io, full_path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        const data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != size) {
            self.allocator.free(data);
            return error.IncompleteRead;
        }

        const ext = std.fs.path.extension(rel_path);
        const mime = if (ext.len > 1) Mime.fromExtension(ext[1..]) else null;

        const hash = fnv1a64(data);
        const etag = try std.fmt.allocPrint(self.allocator, "\"{x}\"", .{hash});
        errdefer self.allocator.free(etag);

        const normalized_key = try std.fmt.allocPrint(self.allocator, "/{s}", .{rel_path});
        errdefer self.allocator.free(normalized_key);

        const entry: StaticFile = .{
            .path = try self.allocator.dupe(u8, rel_path),
            .data = data,
            .mime = mime,
            .etag = etag,
        };
        try self.files.put(self.allocator, normalized_key, entry);
    }

    
    pub fn get(self: *const StaticContentStore, request_path: []const u8) ?StaticFile {
        const key = if (std.mem.eql(u8, request_path, "/")) "/index.html" else request_path;
        return self.files.get(key);
    }
};
