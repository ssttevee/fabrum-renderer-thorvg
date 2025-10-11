const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fabrum_dep = b.dependency("fabrum", .{
        .target = target,
        .optimize = optimize,
    });

    const thorvg_dep = b.dependency("thorvg", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("fabrum-renderer-thorvg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "fabrum",
                .module = fabrum_dep.module("fabrum"),
            },
            .{
                .name = "thorvg",
                .module = thorvg_dep.module("thorvg"),
            },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
