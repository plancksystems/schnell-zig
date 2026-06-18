
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const planck = @import("planck");
const bson = @import("bson");

const SessionBackend = @import("session_backend.zig").SessionBackend;

const log = std.log.scoped(.systemdb_session);

pub fn SystemDbSessionBackend(comptime AppData: type) type {
    return struct {
        const Self = @This();

        
        const SessionDoc = struct {
            token: []const u8,
            data: AppData,
        };

        allocator: Allocator,
        client: *planck.Client,
        store_name: []const u8,

        pub const Config = struct {
            store_name: []const u8 = "_sessions",
        };

        pub fn init(allocator: Allocator, client: *planck.Client, config: Config) Self {
            return .{
                .allocator = allocator,
                .client = client,
                .store_name = config.store_name,
            };
        }

        pub fn backend(self: *Self) SessionBackend(AppData) {
            return SessionBackend(AppData).from(Self, self);
        }

        pub fn create(self: *Self, token: []const u8, data: AppData) !void {
            const doc = SessionDoc{
                .token = token,
                .data = data,
            };
            var q = planck.Query.initWithAllocator(self.client, self.allocator);
            defer q.deinit();
            var resp = try (try q.store(self.store_name).create(doc)).run();
            defer resp.deinit();
            if (!resp.success) {
                log.err("systemdb session create failed", .{});
                return error.BackendWriteFailed;
            }
        }

        pub fn get(self: *Self, token: []const u8) !?AppData {
            var q = planck.Query.initWithAllocator(self.client, self.allocator);
            defer q.deinit();
            var resp = try q.store(self.store_name)
                .where("token", .eq, .{ .string = token })
                .limit(1)
                .run();
            defer resp.deinit();

            const docs = try resp.decode(self.allocator, SessionDoc);
            defer self.allocator.free(docs);
            if (docs.len == 0) return null;

            return docs[0].data;
        }

        pub fn destroy(self: *Self, token: []const u8) !void {
            var q = planck.Query.initWithAllocator(self.client, self.allocator);
            defer q.deinit();
            var resp = try q.store(self.store_name)
                .where("token", .eq, .{ .string = token })
                .delete()
                .run();
            defer resp.deinit();
        }
    };
}
