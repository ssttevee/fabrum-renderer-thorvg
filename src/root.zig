//! ThorVG renderer for fabrum.
//!
//! A `fabrum.layout` renderer for `.pixels` surfaces: it rasterizes render
//! commands (rectangles, rounded or not, borders, text, pictures, clipping)
//! with ThorVG's software engine, into premultiplied RGBA or BGRA pixels,
//! at any scale (device pixels per point). It doesn't draw `gray8`
//! surfaces (`error.UnsupportedFormat`): use the z2d renderer for
//! grayscale displays.
//!
//! ```zig
//! var renderer: Renderer = try .init(gpa);
//! defer renderer.deinit();
//! try renderer.loadFont("Go", @embedFile("Go-Regular.ttf"));
//! try fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, try rt.damage());
//! ```
//!
//! **fabrum is the app's.** This package doesn't depend on fabrum (except
//! for its own tests): the app gives its module the `fabrum` it uses, with
//! `renderer_module.addImport("fabrum", fabrum_module)`. Otherwise an app
//! that passes options to fabrum (`.platform = .none`) and a renderer that
//! asked for fabrum without them would get two fabrum modules in one
//! program.
//!
//! Text needs a font: ThorVG reads TrueType fonts, given with `loadFont`.
//! The first one loaded is used for text without a `font_family`.
const std = @import("std");
const fabrum = @import("fabrum");
pub const tvg = @import("thorvg");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const LayoutContent = fabrum.layout.Content;
const Surface = fabrum.layout.Surface;

pub const content = @import("content.zig");

gpa: std.mem.Allocator,
canvas: *tvg.SoftwareCanvas,
text_context: content.Text.Context,
/// Scenes for the clips in force while building a region's scene.
clip_stack: std.ArrayList(*tvg.Scene) = .empty,
/// A null-terminated copy of each line of text.
text_buf: std.ArrayList(u8) = .empty,

const Renderer = @This();

/// The text this renderer measures and draws, for `fabrum.app.Config.Text`.
pub const Text = content.Text;

/// The surfaces it draws into.
pub const surfaces: []const Surface.Kind = &.{.pixels};

/// Starts ThorVG's software engine (counted, so several renderers can
/// share it), and makes a canvas.
pub fn init(gpa: std.mem.Allocator) !Renderer {
    try tvg.Engines.sw.init(0);
    errdefer tvg.Engines.sw.deinit();
    const canvas = try tvg.SoftwareCanvas.init();
    errdefer canvas.deinit();
    return .{
        .gpa = gpa,
        .canvas = canvas,
        .text_context = try content.Text.Context.init(gpa),
    };
}

pub fn deinit(self: *Renderer) void {
    self.canvas.deinit();
    self.clip_stack.deinit(self.gpa);
    self.text_buf.deinit(self.gpa);
    self.text_context.deinit();
    tvg.Engines.sw.deinit();
    self.* = undefined;
}

/// Loads a TrueType font from `data`, which must outlive the renderer, as
/// `name`, for text whose `font_family` is `name`. The first font loaded
/// is also the one for text without a family.
pub fn loadFont(self: *Renderer, name: [:0]const u8, data: []const u8) !void {
    try tvg.loadFontData(name, data, "ttf", false);
    const fonts = self.text_context.fonts();
    if (fonts.default == null) fonts.default = name;
}

/// Draws `commands` into `surface`, which must be `.pixels`. With
/// `damage`, only those regions are cleared and redrawn, from every command
/// that touches them; without, the whole surface is.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: Surface, damage: ?[]const Rect) !void {
    const pixels = switch (surface) {
        .pixels => |p| p,
        else => return error.UnsupportedSurface,
    };
    if (pixels.format == .gray8) return error.UnsupportedFormat;
    if (pixels.stride % 4 != 0 or @intFromPtr(pixels.data.ptr) % 4 != 0) return error.UnalignedPixels;
    const size = pixels.pointSize();
    const whole: [1]Rect = .{.init(0, 0, size.x, size.y)};
    for (damage orelse &whole) |region| try self.renderRegion(commands, pixels, region);
}

/// Clears and redraws one region (in points) of `pixels`: ThorVG targets
/// just those pixels, and draws everything scaled and moved by the
/// region's origin.
fn renderRegion(self: *Renderer, commands: []const RenderCommand, pixels: Surface.Pixels, region: Rect) !void {
    const s = pixels.scale;
    const w: f32 = @floatFromInt(pixels.width);
    const h: f32 = @floatFromInt(pixels.height);
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(region.x * s), 0, w));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(region.y * s), 0, h));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil((region.x + region.w) * s), 0, w));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil((region.y + region.h) * s), 0, h));
    if (x1 <= x0 or y1 <= y0) return;

    const stride = pixels.stride / 4;
    const words: [*]u32 = @ptrCast(@alignCast(pixels.data.ptr));
    const colorspace: tvg.Colorspace = switch (pixels.format) {
        // ThorVG names channels from the most significant byte of a
        // little-endian word: ABGR is the bytes R, G, B, A
        .rgba8_premultiplied => .abgr8888,
        .bgra8_premultiplied => .argb8888,
        .gray8 => unreachable, // refused by `render`
    };
    // through the C API: the binding wants the whole of the last row, which
    // a region short of the right edge doesn't have
    const result = tvg.c.tvg_swcanvas_set_target(@ptrCast(self.canvas), words + @as(usize, y0) * stride + x0, stride, x1 - x0, y1 - y0, @backingInt(colorspace));
    if (result != tvg.c.TVG_RESULT_SUCCESS) return error.SetTargetFailed;

    const scene = try tvg.Scene.init();
    // pushed to the canvas, which then owns it
    var pushed = false;
    errdefer if (!pushed) scene.deinit();
    // the area in points, for what touches it; the transform scales
    // points to pixels and moves the area's origin to the target's
    const area: Rect = .init(@as(f32, @floatFromInt(x0)) / s, @as(f32, @floatFromInt(y0)) / s, @as(f32, @floatFromInt(x1 - x0)) / s, @as(f32, @floatFromInt(y1 - y0)) / s);
    try self.build(scene, commands, area);
    scene.asPaint().setTransform(&.{ .e11 = s, .e12 = 0, .e13 = -@as(f32, @floatFromInt(x0)), .e21 = 0, .e22 = s, .e23 = -@as(f32, @floatFromInt(y0)), .e31 = 0, .e32 = 0, .e33 = 1 });

    const canvas = self.canvas.asCanvas();
    try canvas.push(scene.asPaint());
    pushed = true;
    // ThorVG clears the target before it draws
    canvas.draw();
    _ = canvas.sync();
    canvas.clear(true);
}

/// Adds the commands that touch `area` to `root`.
fn build(self: *Renderer, root: *tvg.Scene, commands: []const RenderCommand, area: Rect) !void {
    self.clip_stack.clearRetainingCapacity();
    defer self.clip_stack.clearRetainingCapacity();
    // how many of the clips in force were left out, as they miss the area
    var skipped: usize = 0;
    for (commands) |cmd| {
        const scene = if (self.clip_stack.items.len > 0) self.clip_stack.getLast() else root;
        switch (cmd.data) {
            .scissor_start => |s| {
                if (skipped > 0 or !overlaps(cmd.bbox, area)) {
                    skipped += 1;
                    continue;
                }
                const clipped = try tvg.Scene.init();
                scene.push(clipped.asPaint());
                const clip = try tvg.Shape.init();
                const huge = 1e6;
                clip.appendRect(
                    if (s.horizontal) cmd.bbox.x else -huge,
                    if (s.vertical) cmd.bbox.y else -huge,
                    if (s.horizontal) cmd.bbox.w else 2 * huge,
                    if (s.vertical) cmd.bbox.h else 2 * huge,
                    0,
                    0,
                );
                try clipped.asPaint().setClip(clip.asPaint());
                try self.clip_stack.append(self.gpa, clipped);
            },
            .scissor_end => {
                if (skipped > 0) {
                    skipped -= 1;
                } else {
                    _ = self.clip_stack.pop();
                }
            },
            .rectangle => |r| if (skipped == 0 and overlaps(cmd.bbox, area)) try renderRectangle(scene, cmd.bbox, r.corner_radius, r.color),
            .border => |b| if (skipped == 0 and overlaps(cmd.bbox, area)) try renderBorder(scene, cmd.bbox, b),
            .content => |c| if (skipped == 0 and overlaps(cmd.bbox, area)) try self.renderContent(scene, cmd.bbox, c),
        }
    }
}

/// Whether `a`, with the pixels anti-aliasing and overhanging glyphs touch
/// around it, shares any area with `b`.
fn overlaps(a: Rect, b: Rect) bool {
    const m = fabrum.layout.Damage.margin_default;
    return a.x - m < b.x + b.w and b.x < a.x + a.w + m and a.y - m < b.y + b.h and b.y < a.y + a.h + m;
}

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.layout.text.Style) content.Text {
    return .initContext(s, style, self.text_context);
}

pub fn picture(self: *const Renderer, p: *tvg.Picture, style: content.Picture.Style) content.Picture {
    _ = self;
    return .{ .picture = p, .style = style };
}

fn tvgColor(color: Color) tvg.Color {
    return .init(color.r, color.g, color.b, color.a);
}

fn renderRectangle(scene: *tvg.Scene, bbox: Rect, corner_radius: CornerRadius, color: Color) !void {
    const shape = try tvg.Shape.init();
    scene.push(shape.asPaint());
    appendRoundedRect(shape, bbox, corner_radius.fitted(bbox.w, bbox.h));
    shape.setFillColor(tvgColor(color));
}

/// Draws a border inside its box: the area between the box and the box
/// inset by the border's widths, so it never spills onto its neighbours.
fn renderBorder(scene: *tvg.Scene, bbox: Rect, b: RenderCommand.Data.Border) !void {
    const w = b.widths;
    if (w.isZero()) return;
    const shape = try tvg.Shape.init();
    scene.push(shape.asPaint());
    const outer = b.corner_radius.fitted(bbox.w, bbox.h);
    appendRoundedRect(shape, bbox, outer);
    // the inner edge, wound the other way, with radii shrunk by the widths
    const inner: Rect = .init(bbox.x + w.left, bbox.y + w.top, bbox.w - w.left - w.right, bbox.h - w.top - w.bottom);
    if (inner.w > 0 and inner.h > 0) {
        const radii: CornerRadius = .{
            .top_left = @max(outer.top_left - @max(w.left, w.top), 0),
            .top_right = @max(outer.top_right - @max(w.right, w.top), 0),
            .bottom_left = @max(outer.bottom_left - @max(w.left, w.bottom), 0),
            .bottom_right = @max(outer.bottom_right - @max(w.right, w.bottom), 0),
        };
        appendRoundedRectReversed(shape, inner, radii.fitted(inner.w, inner.h));
    }
    shape.setFillColor(tvgColor(b.color));
}

fn renderContent(self: *Renderer, scene: *tvg.Scene, bbox: Rect, c: *LayoutContent) !void {
    if (content.Text.asTextContent(c)) |text_content| return self.renderText(scene, bbox, text_content);
    if (content.Picture.asPictureContent(c)) |picture_content| return renderPicture(scene, bbox, picture_content);
}

fn renderText(self: *Renderer, scene: *tvg.Scene, bbox: Rect, text_content: *const content.Text) !void {
    const style = text_content.style;
    const font = style.font_family orelse self.text_context.fonts().default orelse return error.NoFontLoaded;
    var lines = text_content.linesWithSizes(bbox.w);
    var y = bbox.y;
    while (try lines.next()) |line| {
        defer y += line.size.y;
        if (line.text.len == 0) continue;
        self.text_buf.clearRetainingCapacity();
        try self.text_buf.appendSlice(self.gpa, line.text);
        try self.text_buf.append(self.gpa, 0);

        const t = try tvg.Text.init();
        const paint = t.asPaint();
        scene.push(paint);
        try t.setFont(font.ptr, style.font_size * content.size_scale, null);
        t.setText(self.text_buf.items[0..line.text.len :0]);
        t.setFillColor(tvgColor(style.color));
        paint.setOpacity(style.color.a);
        const x = bbox.x + switch (style.alignment) {
            .left => 0,
            .center => (bbox.w - line.size.x) / 2,
            .right => bbox.w - line.size.x,
        };
        // ThorVG puts the top of the font's ascender at the origin; center
        // the font's height in the line
        paint.translate(x, y + (line.size.y - style.font_size * content.font_height) / 2);
    }
}

fn renderPicture(scene: *tvg.Scene, bbox: Rect, picture_content: *const content.Picture) !void {
    const paint = picture_content.picture.asPaint().duplicate() orelse return error.OutOfMemory;
    scene.push(paint);
    const bounds = paint.getBounds(false);
    paint.translate(bbox.x, bbox.y);
    paint.scale(@min(bbox.w / bounds.w, bbox.h / bounds.h));
}

/// The distance of a cubic Bézier's control points from a quarter
/// circle's ends, as a fraction of its radius.
const kappa = 0.5523;

/// Appends a closed, clockwise rectangle with corner radii.
fn appendRoundedRect(shape: *tvg.Shape, r: Rect, cr: CornerRadius) void {
    const x = r.x;
    const y = r.y;
    const w = r.w;
    const h = r.h;
    const tl = cr.top_left;
    const tr = cr.top_right;
    const br = cr.bottom_right;
    const bl = cr.bottom_left;
    const k = 1 - kappa;

    shape.moveTo(x + tl, y);
    shape.lineTo(x + w - tr, y);
    if (tr > 0) shape.cubicTo(x + w - tr * k, y, x + w, y + tr * k, x + w, y + tr);
    shape.lineTo(x + w, y + h - br);
    if (br > 0) shape.cubicTo(x + w, y + h - br * k, x + w - br * k, y + h, x + w - br, y + h);
    shape.lineTo(x + bl, y + h);
    if (bl > 0) shape.cubicTo(x + bl * k, y + h, x, y + h - bl * k, x, y + h - bl);
    shape.lineTo(x, y + tl);
    if (tl > 0) shape.cubicTo(x, y + tl * k, x + tl * k, y, x + tl, y);
    shape.close();
}

/// `appendRoundedRect` wound counter-clockwise, for holes.
fn appendRoundedRectReversed(shape: *tvg.Shape, r: Rect, cr: CornerRadius) void {
    const x = r.x;
    const y = r.y;
    const w = r.w;
    const h = r.h;
    const tl = cr.top_left;
    const tr = cr.top_right;
    const br = cr.bottom_right;
    const bl = cr.bottom_left;
    const k = 1 - kappa;

    shape.moveTo(x + tl, y);
    if (tl > 0) shape.cubicTo(x + tl * k, y, x, y + tl * k, x, y + tl);
    shape.lineTo(x, y + h - bl);
    if (bl > 0) shape.cubicTo(x, y + h - bl * k, x + bl * k, y + h, x + bl, y + h);
    shape.lineTo(x + w - br, y + h);
    if (br > 0) shape.cubicTo(x + w - br * k, y + h, x + w, y + h - br * k, x + w, y + h - br);
    shape.lineTo(x + w, y + tr);
    if (tr > 0) shape.cubicTo(x + w, y + tr * k, x + w - tr * k, y, x + w - tr, y);
    shape.close();
}

test {
    std.testing.refAllDecls(@This());
}
