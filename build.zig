const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bson_dep = b.dependency("bson", .{});
    const bson_mod = b.createModule(.{
        .root_source_file = bson_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_dep = b.dependency("utils", .{});
    const utils_mod = b.createModule(.{
        .root_source_file = utils_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls_dep = b.dependency("tls", .{});
    const tls_mod = b.createModule(.{
        .root_source_file = tls_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const proto_dep = b.dependency("proto", .{});
    const proto_mod = b.createModule(.{
        .root_source_file = proto_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    proto_mod.addImport("utils", utils_mod);

    const yaml_dep = b.dependency("yaml", .{});
    const yaml_mod = b.createModule(.{
        .root_source_file = yaml_dep.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const plank_dep = b.dependency("planck_zig_client", .{});
    const planck_zig_client_mod = b.createModule(.{
        .root_source_file = plank_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    planck_zig_client_mod.addImport("bson", bson_mod);
    planck_zig_client_mod.addImport("utils", utils_mod);
    planck_zig_client_mod.addImport("tls", tls_mod);
    planck_zig_client_mod.addImport("proto", proto_mod);

    const schnell_mod = b.addModule("schnell", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    schnell_mod.addImport("utils", utils_mod);
    schnell_mod.addImport("tls", tls_mod);
    schnell_mod.addImport("proto", proto_mod);
    schnell_mod.addImport("bson", bson_mod);
    schnell_mod.addImport("planck_zig_client", planck_zig_client_mod);
    schnell_mod.addImport("yaml", yaml_mod);

    const web_mod = b.addModule("web", .{
        .root_source_file = b.path("src/web/root.zig"),
        .target = target,
    });
    web_mod.addImport("bson", bson_mod);
    web_mod.addImport("schnell", schnell_mod);

    const providers_mod = b.addModule("providers", .{
        .root_source_file = b.path("src/providers/root.zig"),
        .target = target,
    });
    providers_mod.addImport("bson", bson_mod);
    providers_mod.addImport("schnell", schnell_mod);
    providers_mod.addImport("utils", utils_mod);
    providers_mod.addImport("tls", tls_mod);
    providers_mod.addImport("proto", proto_mod);
    providers_mod.addImport("planck_zig_client", planck_zig_client_mod);
    providers_mod.addImport("yaml", yaml_mod);

    const schnell_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schnell_tests_mod.addImport("utils", utils_mod);
    schnell_tests_mod.addImport("tls", tls_mod);
    schnell_tests_mod.addImport("proto", proto_mod);
    schnell_tests_mod.addImport("bson", bson_mod);
    schnell_tests_mod.addImport("planck_zig_client", planck_zig_client_mod);
    schnell_tests_mod.addImport("yaml", yaml_mod);
    const schnell_tests = b.addTest(.{ .root_module = schnell_tests_mod });

    const request_parser_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/web/request_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    request_parser_tests_mod.addImport("schnell", schnell_mod);
    const request_parser_tests = b.addTest(.{ .root_module = request_parser_tests_mod });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(schnell_tests).step);
    test_step.dependOn(&b.addRunArtifact(request_parser_tests).step);
}
