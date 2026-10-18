const std = @import("std");
const fabrum = @import("fabrum");
const thorvg = @import("thorvg");

const LayoutContent = fabrum.layout.Content;
const Vec2 = fabrum.Vec2;

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

    return switch (self.style.fit_mode) {
        .contain => blk: {
            if (aspect_ratio > constraint_ratio) {
                // Width is the limiting factor
                const width = max_width;
                const height = width / aspect_ratio;
                break :blk .init(width, height);
            } else {
                // Height is the limiting factor
                const height = max_height;
                const width = height * aspect_ratio;
                break :blk .init(width, height);
            }
        },
        .cover => blk: {
            if (aspect_ratio > constraint_ratio) {
                // Height is the limiting factor
                const height = max_height;
                const width = height * aspect_ratio;
                break :blk .init(width, height);
            } else {
                // Width is the limiting factor
                const width = max_width;
                const height = width / aspect_ratio;
                break :blk .init(width, height);
            }
        },
        .crop => .init(@min(bounds.w, max_width), @min(bounds.h, max_height)),
        .stretch => .init(max_width, max_height),
    };
}
