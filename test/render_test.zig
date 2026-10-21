//! The ThorVG renderer drawing into pixels: colors, premultiplied alpha,
//! byte order, clipping, borders inside their box, text, and redrawing
//! only what changed.
const std = @import("std");
const testing = std.testing;

const fabrum = @import("fabrum");
const layout = fabrum.layout;
const Rect = fabrum.Rect;
const Color = fabrum.Color;
const Renderer = @import("fabrum-renderer-thorvg");

const font = @embedFile("fonts/Go-Regular.ttf");

const size = 64;

const Canvas = struct {
    buffer: [size * size * 4]u8 align(4) = undefined,

    fn pixels(self: *Canvas, format: layout.PixelFormat) layout.Surface.Pixels {
        return .packed_(&self.buffer, size, size, format);
    }

    fn at(self: *const Canvas, x: usize, y: usize) [4]u8 {
        return self.buffer[(y * size + x) * 4 ..][0..4].*;
    }
};

fn rectangle(x: f32, y: f32, w: f32, h: f32, color: Color, radius: f32) layout.RenderCommand {
    return .{ .bbox = .init(x, y, w, h), .data = .{ .rectangle = .{ .color = color, .corner_radius = .uniform(radius) } } };
}

test "it is a renderer for pixels, not Core Graphics" {
    comptime layout.checkRenderer(Renderer);
    try testing.expect(layout.accepts(Renderer, .pixels));
    try testing.expect(!layout.accepts(Renderer, .cg_context));
}

test "colors are premultiplied, in RGBA or BGRA order, over a cleared surface" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    var canvas: Canvas = .{};
    @memset(&canvas.buffer, 0x55);
    const commands = [_]layout.RenderCommand{rectangle(8, 8, 16, 16, .rgba(255, 128, 0, 128), 0)};

    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.rgba8_premultiplied), null);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &canvas.at(2, 2));
    const inside = canvas.at(16, 16);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(inside[0])), 1);
    try testing.expectApproxEqAbs(@as(f32, 64), @as(f32, @floatFromInt(inside[1])), 1);
    try testing.expectEqual(0, inside[2]);
    try testing.expectEqual(128, inside[3]);

    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.bgra8_premultiplied), null);
    const swapped = canvas.at(16, 16);
    try testing.expectEqual(0, swapped[0]);
    try testing.expectEqual(inside[0], swapped[2]);
    try testing.expectEqual(128, swapped[3]);
}

test "scissors clip, and borders stay inside their box" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    var canvas: Canvas = .{};
    const commands = [_]layout.RenderCommand{
        .{ .bbox = .init(0, 0, 20, 64), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = false } } },
        rectangle(10, 10, 40, 10, .black, 0),
        .{ .data = .scissor_end },
        .{ .bbox = .init(30, 30, 20, 20), .data = .{ .border = .{ .color = .black, .widths = .outside(3), .corner_radius = .uniform(4) } } },
    };
    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.rgba8_premultiplied), null);
    try testing.expectEqual(255, canvas.at(15, 15)[3]);
    // clipped away
    try testing.expectEqual(0, canvas.at(25, 15)[3]);
    // the border: inside its edge, not outside it, and not in the middle
    try testing.expectEqual(255, canvas.at(40, 31)[3]);
    try testing.expectEqual(0, canvas.at(40, 29)[3]);
    try testing.expectEqual(0, canvas.at(40, 40)[3]);
}

test "text is drawn in the loaded font, inside its box" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    try renderer.loadFont("Go", font);
    var text = renderer.text("Hi", .{ .font_size = 20, .color = .black });
    const box_size = try text.content.measure(.{});
    try testing.expect(box_size.x > 10 and box_size.x < 30);
    try testing.expectEqual(24, box_size.y);

    var canvas: Canvas = .{};
    const commands = [_]layout.RenderCommand{.{ .bbox = .init(10, 10, box_size.x, box_size.y), .data = .{ .content = &text.content } }};
    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.rgba8_premultiplied), null);
    var inside: usize = 0;
    for (0..size) |y| for (0..size) |x| {
        if (canvas.at(x, y)[3] == 0) continue;
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        // nothing beyond the box and the damage margin
        try testing.expect(fx >= 10 - 2 and fx < 10 + box_size.x + 2 and fy >= 10 - 2 and fy < 10 + box_size.y + 2);
        inside += 1;
    };
    try testing.expect(inside > 30);
}

test "redrawing only the damage gives the same pixels as redrawing everything" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    try renderer.loadFont("Go", font);
    var damage: layout.Damage = .{};
    defer damage.deinit(testing.allocator);
    var partial: Canvas = .{};
    var full: Canvas = .{};

    var hello = renderer.text("hello", .{ .font_size = 12, .color = .white });
    var bye = renderer.text("bye", .{ .font_size = 12, .color = .white });
    const frames = [_][]const layout.RenderCommand{
        &.{ rectangle(0, 0, 64, 64, .rgb(30, 30, 30), 0), rectangle(4, 4, 30, 20, .rgb(200, 0, 0), 6), .{ .bbox = .init(6, 30, 40, 15), .data = .{ .content = &hello.content } } },
        // a hover: one rounded fill changes color
        &.{ rectangle(0, 0, 64, 64, .rgb(30, 30, 30), 0), rectangle(4, 4, 30, 20, .rgb(230, 60, 60), 6), .{ .bbox = .init(6, 30, 40, 15), .data = .{ .content = &hello.content } } },
        // new text, and a box moving
        &.{ rectangle(0, 0, 64, 64, .rgb(30, 30, 30), 0), rectangle(14, 4, 30, 20, .rgb(230, 60, 60), 6), .{ .bbox = .init(6, 30, 40, 15), .data = .{ .content = &bye.content } } },
    };
    for (frames, 0..) |commands, i| {
        const regions = try damage.update(testing.allocator, commands, .init(size, size));
        try layout.draw(&renderer, commands, .pixels, partial.pixels(.rgba8_premultiplied), if (i == 0) null else regions);
        try layout.draw(&renderer, commands, .pixels, full.pixels(.rgba8_premultiplied), null);
        if (!std.mem.eql(u8, &full.buffer, &partial.buffer)) {
            for (0..size) |y| for (0..size) |x| {
                if (!std.mem.eql(u8, &full.at(x, y), &partial.at(x, y))) std.debug.print("frame {d} ({d},{d}): full {any} partial {any}; regions {any}\n", .{ i, x, y, full.at(x, y), partial.at(x, y), regions });
            };
            return error.TestDamageMissed;
        }
    }
}

test "at scale 2 a point is two pixels, and gray8 is refused" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    var big: [size * size * 4 * 4]u8 align(4) = @splat(0);
    const commands = [_]layout.RenderCommand{rectangle(8, 8, 16, 16, .black, 0)};
    const pixels: layout.Surface.Pixels = .packedScaled(&big, size * 2, size * 2, .rgba8_premultiplied, 2);
    try layout.draw(&renderer, &commands, .pixels, pixels, null);
    try testing.expectEqual(255, big[(20 * size * 2 + 20) * 4 + 3]);
    try testing.expectEqual(255, big[(46 * size * 2 + 46) * 4 + 3]);
    try testing.expectEqual(0, big[(50 * size * 2 + 50) * 4 + 3]);
    // damage in points
    @memset(&big, 7);
    try layout.draw(&renderer, &commands, .pixels, pixels, &.{.init(0, 0, 12, 12)});
    try testing.expectEqual(255, big[(20 * size * 2 + 20) * 4 + 3]);
    try testing.expectEqual(7, big[(30 * size * 2 + 30) * 4 + 3]);

    var gray: [size * size]u8 align(4) = @splat(0);
    try testing.expectError(error.UnsupportedFormat, layout.draw(&renderer, &commands, .pixels, .packed_(&gray, size, size, .gray8), null));
}

test "pictures fit and align on both axes, clipped to their box" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    const picture = try Renderer.tvg.Picture.init();
    defer picture.deinit();
    picture.loadData("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"4\"><path fill=\"red\" d=\"M0 0H4V4H0Z\"/><path fill=\"blue\" d=\"M4 0H8V4H4Z\"/></svg>", "svg", true) catch |err| switch (err) {
        error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    const original = picture.asPaint().getTransform();
    var canvas: Canvas = .{};
    for ([_]Renderer.content.Picture.FitMode{ .contain, .cover, .crop, .stretch }) |fit| {
        for ([_]layout.Gravity{ .start, .center, .end }) |ax| {
            for ([_]layout.Gravity{ .start, .center, .end }) |ay| {
                for ([_]Rect{ .init(16, 16, 16, 16), .init(16, 16, 4, 12) }) |box| {
                    var content = renderer.picture(picture, .{ .fit_mode = fit, .alignment = .{ .x = ax, .y = ay } });
                    const commands = [_]layout.RenderCommand{.{ .bbox = box, .data = .{ .content = &content.content } }};
                    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.rgba8_premultiplied), null);
                    const sx: f32 = switch (fit) {
                        .contain => @min(box.w / 8, box.h / 4),
                        .cover => @max(box.w / 8, box.h / 4),
                        .crop => 1,
                        .stretch => box.w / 8,
                    };
                    const sy = if (fit == .stretch) box.h / 4 else sx;
                    const x0 = box.x + (box.w - 8 * sx) * alignmentFraction(ax);
                    const y0 = box.y + (box.h - 4 * sy) * alignmentFraction(ay);
                    for (0..size) |y| for (0..size) |x| {
                        const px = @as(f32, @floatFromInt(x)) + 0.5;
                        const py = @as(f32, @floatFromInt(y)) + 0.5;
                        const inside = px >= box.x and px < box.x + box.w and py >= box.y and py < box.y + box.h and px >= x0 and px < x0 + 8 * sx and py >= y0 and py < y0 + 4 * sy;
                        const expected: [4]u8 = if (!inside) .{ 0, 0, 0, 0 } else if (px < x0 + 4 * sx) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
                        try testing.expectEqual(expected, canvas.at(x, y));
                    };
                }
            }
        }
    }
    try testing.expectEqual(original, picture.asPaint().getTransform());
}

fn alignmentFraction(gravity: layout.Gravity) f32 {
    return switch (gravity) {
        .start => 0,
        .center => 0.5,
        .end => 1,
    };
}

test "fractional curves keep identical antialiasing across damage origins" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    var full: Canvas = .{};
    var partial: Canvas = .{};
    const commands = [_]layout.RenderCommand{
        rectangle(0, 0, 64, 64, .white, 0),
        rectangle(18.3, 24.7, 22.6, 14.2, .rgba(123, 98, 42, 200), 6.3),
        rectangle(32.0 / 3.0, 47.0 / 3.0, 29.4, 30.6, .rgba(40, 80, 160, 128), 8.2),
    };
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var pixels = full.pixels(.rgba8_premultiplied);
        pixels.scale = scale;
        try layout.draw(&renderer, &commands, .pixels, pixels, null);
        for (1..25) |origin| {
            partial.buffer = full.buffer;
            pixels = partial.pixels(.rgba8_premultiplied);
            pixels.scale = scale;
            const offset = @as(f32, @floatFromInt(origin)) / scale;
            const edge = @as(f32, size) / scale;
            try layout.draw(&renderer, &commands, .pixels, pixels, &.{.init(offset, offset, edge - offset, edge - offset)});
            try testing.expectEqualSlices(u8, &full.buffer, &partial.buffer);
        }
    }
}

test "damage culls scissors only on their enabled axes, including nested clips" {
    var renderer: Renderer = try .init(testing.allocator);
    defer renderer.deinit();
    var canvas: Canvas = .{};
    const commands = [_]layout.RenderCommand{
        .{ .bbox = .init(10, 0, 20, 1), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = false } } },
        .{ .bbox = .init(0, 20, 1, 20), .data = .{ .scissor_start = .{ .horizontal = false, .vertical = true } } },
        rectangle(0, 0, 64, 64, .black, 0),
        .{ .data = .scissor_end },
        .{ .data = .scissor_end },
    };
    var full: Canvas = .{};
    try layout.draw(&renderer, &commands, .pixels, full.pixels(.rgba8_premultiplied), null);
    @memset(&canvas.buffer, 77);
    try layout.draw(&renderer, &commands, .pixels, canvas.pixels(.rgba8_premultiplied), &.{.init(8, 18, 24, 24)});
    for (18..42) |y| for (8..32) |x| try testing.expectEqual(full.at(x, y), canvas.at(x, y));
    try testing.expectEqual(255, canvas.at(15, 25)[3]);
    try testing.expectEqual([4]u8{ 77, 77, 77, 77 }, canvas.at(7, 25));
}
