
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");

pub const StateStore = struct {
    entries: std.StringHashMapUnmanaged(i64),
    allocator: Allocator,
    ttl_ms: i64 = 300_000,

    pub fn init(allocator: Allocator) StateStore {
        return .{ .entries = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn generate(self: *StateStore, io: Io) ![]const u8 {
        var buf: [32]u8 = undefined;
        io.random(&buf);
        const hex = std.fmt.bytesToHex(buf, .lower);
        const state = try self.allocator.dupe(u8, &hex);
        const now_inst: utils.Now = .{ .io = io };
        const now = now_inst.toMilliSeconds();
        try self.entries.put(self.allocator, state, now + self.ttl_ms);

        self.purgeExpired(now);
        return state;
    }

    pub fn validateAndConsume(self: *StateStore, io: Io, state: []const u8) bool {
        const entry = self.entries.fetchRemove(state) orelse return false;
        const now_inst: utils.Now = .{ .io = io };
        const now = now_inst.toMilliSeconds();
        self.allocator.free(entry.key);
        return now <= entry.value;
    }

    fn purgeExpired(self: *StateStore, now: i64) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.*) {
                const key = entry.key_ptr.*;
                self.entries.removeByPtr(entry.key_ptr);
                self.allocator.free(key);
            }
        }
    }
};
