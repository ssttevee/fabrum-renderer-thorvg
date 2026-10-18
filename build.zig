const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const thorvg_dep = b.dependency("thorvg", .{
        .target = target,
        .optimize = optimize,
    });

    // The renderer. It imports `fabrum`, which the app gives it, so that the
    // renderer and the app share one fabrum whatever options the app passes:
    //
    //     renderer_module.addImport("fabrum", fabrum_module);
    const mod = b.addModule("fabrum-renderer-thorvg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thorvg", .module = thorvg_dep.module("thorvg") },
        },
    });

    const test_step = b.step("test", "Run tests");

    // This package's own tests bring their own fabrum, lazily, so that apps
    // depending on the renderer never fetch or build it.
    if (!b.isRoot()) return;
    const fabrum_dep = b.lazyDependency("fabrum", .{
        .target = target,
        .optimize = optimize,
        .platform = .none,
    }) orelse return;
    mod.addImport("fabrum", fabrum_dep.module("fabrum"));

    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const render_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/render_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_dep.module("fabrum") },
            .{ .name = "fabrum-renderer-thorvg", .module = mod },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(render_tests).step);

    // An app as apps use the renderer: it passes `.platform = .none` to
    // fabrum and gives the renderer its fabrum. Built as its own package,
    // with its own build, as an app would be.
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "--summary", "none" });
    consumer.setCwd(b.path("test/consumer"));
    consumer.setName("test the consumer app");
    test_step.dependOn(&consumer.step);
}
