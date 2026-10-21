const std = @import("std");
const fabrum = @import("fabrum");
const thorvg = @import("thorvg");

const LayoutContent = fabrum.layout.Content;
const Vec2 = fabrum.Vec2;

/// The loaded picture, borrowed for as long as this content is used.
picture: *thorvg.Picture,
style: Style = .{},
content: LayoutContent = .{
    .vtable = vtable,
},

const Picture = @This();

pub const FitMode = enum {
    contain,
    cover,
    crop,
    stretch,
};

/// The fit mode controls measurement. Drawing currently scales uniformly
/// from the laid-out box's top left, ignoring `alignment`; `stretch` only
/// stretches the measured size. Clip the container to crop a `cover` image.
pub const Style = struct {
    fit_mode: FitMode = .contain,
    alignment: fabrum.layout.Alignment = .center,
};

const vtable = &LayoutContent.VTable{
    .measure = measureFn,
    .debug_name = "Picture",
};

pub fn isPictureContent(content: *const LayoutContent) bool {
    return content.vtable == vtable;
}

pub fn asPictureContent(content: *const LayoutContent) ?*const Picture {
    if (!isPictureContent(content)) {
        return null;
    }

    return @fieldParentPtr("content", content);
}

fn measureFn(content: *const LayoutContent, constraints: fabrum.layout.Constraints) LayoutContent.MeasureError!Vec2 {
    const self: *const Picture = @fieldParentPtr("content", content);
    const bounds = self.picture.asPaint().getBounds(false);
    const max_width = constraints.max_width orelse std.math.floatMax(f32);
    const max_height = constraints.max_height orelse std.math.floatMax(f32);

    const aspect_ratio = bounds.w / bounds.h;
    const constraint_ratio = max_width / max_height;

    // whether the width is the limiting factor: a wider picture fits its
    // width inside the box, and its height over it
    const by_width = switch (self.style.fit_mode) {
        .contain => aspect_ratio > constraint_ratio,
        .cover => aspect_ratio <= constraint_ratio,
        .crop => return .init(@min(bounds.w, max_width), @min(bounds.h, max_height)),
        .stretch => return .init(max_width, max_height),
    };
    return if (by_width) .init(max_width, max_width / aspect_ratio) else .init(max_height * aspect_ratio, max_height);
}

test "a picture measures to its fit mode within the constraints" {
    try thorvg.Engines.sw.init(0);
    defer thorvg.Engines.sw.deinit();
    const picture = try thorvg.Picture.init();
    defer picture.deinit();
    // four by two, so twice as wide as tall
    picture.loadData("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"2\"><rect width=\"4\" height=\"2\"/></svg>", "svg", true) catch |err| switch (err) {
        error.NotSupported => return error.SkipZigTest, // no SVG loader in this build
        else => return err,
    };
    var content: Picture = .{ .picture = picture };
    const box: fabrum.layout.Constraints = .{ .max_width = 8, .max_height = 8 };
    for ([_]struct { FitMode, Vec2 }{
        .{ .contain, .init(8, 4) },
        .{ .cover, .init(16, 8) },
        .{ .crop, .init(4, 2) },
        .{ .stretch, .init(8, 8) },
    }) |case| {
        content.style.fit_mode = case[0];
        try std.testing.expectEqual(case[1], try content.content.measure(box));
    }
}
