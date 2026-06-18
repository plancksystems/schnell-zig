
const std = @import("std");

pub fn inject(comptime S: type, services: *S, target: anytype) !void {
    const info = @typeInfo(@TypeOf(target));
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("inject: target must be a single-item pointer");
    }
    const Target = info.pointer.child;
    if (@typeInfo(Target) != .@"struct") {
        @compileError("inject: target must point to a struct");
    }

    inline for (std.meta.fields(Target)) |field| {
        const FieldChild = pointerChild(field.type) orelse continue;
        var found = false;
        inline for (std.meta.fields(S)) |svc_field| {
            if (FieldChild == svc_field.type) {
                @field(target, field.name) = &@field(services, svc_field.name);
                found = true;
            }
            if (svc_field.type == field.type) {
                @field(target, field.name) = @field(services, svc_field.name);
                found = true;
            }
        }
        if (!found) return error.UnresolvedDependency;
    }
}

fn pointerChild(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) p.child else null,
        else => null,
    };
}
