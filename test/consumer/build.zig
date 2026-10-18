//! An app as apps use the ThorVG renderer: fabrum built with an option of
//! its own (`.platform = .none`), and the renderer given that fabrum.
//! Zig makes one instance of a package per set of options as passed, so if
//! the renderer asked for fabrum itself, this program would hold two fabrum
//! modules and fail with "file exists in modules 'fabrum' and 'fabrum0'".
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
    const renderer = b.dependency("fabrum_renderer_thorvg", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-thorvg");
    renderer.addImport("fabrum", fabrum);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum },
            .{ .name = "fabrum-renderer-thorvg", .module = renderer },
        },
    }) });
    b.step("test", "Run the app's test").dependOn(&b.addRunArtifact(tests).step);
}
