//! ThorVG renderer for fabrum.
//!
//! This renderer builds a ThorVG scene from layout commands.
//! It supports rectangles, borders, text, and scissor-based clipping.

const std = @import("std");
const fabrum = @import("fabrum");
pub const tvg = @import("thorvg");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const BorderWidths = fabrum.layout.BorderWidths;
const LayoutContent = fabrum.layout.Content;

pub const content = @import("content.zig");

scene: *tvg.Scene,
clip_stack: std.ArrayListUnmanaged(*tvg.Scene),
allocator: std.mem.Allocator,
text_context: content.Text.Context,
text_buf: []u8 = &.{},

const Renderer = @This();

pub fn init(allocator: std.mem.Allocator) !Renderer {
    const scene = try tvg.Scene.init();
    errdefer scene.deinit();

    return .{
        .scene = scene,
        .clip_stack = .empty,
        .allocator = allocator,
        .text_context = try content.Text.Context.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    for (self.clip_stack.items) |clip_scene| {
        clip_scene.deinit();
    }
    self.clip_stack.deinit(self.allocator);
    self.scene.deinit();
    self.text_context.deinit();
    self.* = undefined;
}

pub fn render(self: *Renderer, it: *RenderCommand.Iterator) !void {
    self.scene.clear(true);

    while (it.next()) |cmd| {
        switch (cmd.data) {
            .scissor_start => {
                const clip_scene = tvg.Scene.init() catch continue;
                self.getActiveScene().push(clip_scene.asPaint());
                try self.clip_stack.append(self.allocator, clip_scene);
            },
            .scissor_end => {
                if (self.clip_stack.items.len > 0) {
                    _ = self.clip_stack.pop();
                }
            },
            .rectangle => |r| {
                try self.renderRectangle(cmd.bbox, r.corner_radius, r.color);
            },
            .border => |b| {
                try self.renderBorder(cmd.bbox, b);
            },
            .content => |c| {
                try self.renderContent(cmd.bbox, c);
            },
        }
    }
}

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.layout.text.Style) content.Text {
    return .initContext(s, style, self.text_context);
}

pub fn picture(self: *const Renderer, p: *tvg.Picture, style: content.Picture.Style) content.Picture {
    _ = self;
    return .{ .picture = p, .style = style };
}

fn getActiveScene(self: *Renderer) *tvg.Scene {
    if (self.clip_stack.items.len > 0) {
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }
    return self.scene;
}

fn renderRectangle(self: *Renderer, bbox: Rect, corner_radius: CornerRadius, color: Color) !void {
    const shape = tvg.Shape.init() catch return;
    const cr = corner_radius.fitted(bbox.w, bbox.h);

    if (isAllZero(cr)) {
        _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, 0, 0);
    } else if (uniformCorner(cr)) {
        _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, cr.top_left, cr.top_left);
    } else {
        try appendRoundedRect(shape, bbox, cr);
    }

    _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));

    self.getActiveScene().push(shape.asPaint());
}

fn renderBorder(self: *Renderer, bbox: Rect, b: RenderCommand.Data.Border) !void {
    const bw = b.widths;
    const color = b.color;

    if (bw.left == 0 and bw.right == 0 and bw.top == 0 and bw.bottom == 0) return;

    if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
        const shape = tvg.Shape.init() catch return;
        const cr = b.corner_radius.fitted(bbox.w, bbox.h);

        if (isAllZero(cr)) {
            _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, 0, 0);
        } else if (uniformCorner(cr)) {
            _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, cr.top_left, cr.top_left);
        } else {
            try appendRoundedRect(shape, bbox, cr);
        }

        shape.setStrokeWidth(bw.left);
        shape.setStrokeColor(tvg.Color.init(color.r, color.g, color.b, color.a));
        shape.setFillColor(tvg.Color.init(0, 0, 0, 0));

        self.getActiveScene().push(shape.asPaint());
    } else {
        if (bw.top > 0) {
            const shape = tvg.Shape.init() catch return;
            shape.appendRect(bbox.x, bbox.y, bbox.w, bw.top, 0, 0);
            _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
            self.getActiveScene().push(shape.asPaint());
        }

        if (bw.bottom > 0) {
            const shape = tvg.Shape.init() catch return;
            shape.appendRect(bbox.x, bbox.y + bbox.h - bw.bottom, bbox.w, bw.bottom, 0, 0);
            _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
            self.getActiveScene().push(shape.asPaint());
        }

        if (bw.left > 0) {
            const shape = tvg.Shape.init() catch return;
            shape.appendRect(bbox.x, bbox.y, bw.left, bbox.h, 0, 0);
            _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
            self.getActiveScene().push(shape.asPaint());
        }

        if (bw.right > 0) {
            const shape = tvg.Shape.init() catch return;
            shape.appendRect(bbox.x + bbox.w - bw.right, bbox.y, bw.right, bbox.h, 0, 0);
            _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
            self.getActiveScene().push(shape.asPaint());
        }
    }
}

fn renderContent(self: *Renderer, bbox: Rect, c: *LayoutContent) !void {
    if (content.Text.asTextContent(c)) |text_content| {
        try self.renderText(bbox, text_content);
        return;
    }

    if (content.Picture.asPictureContent(c)) |picture_content| {
        try self.renderPicture(bbox, picture_content);
        return;
    }
}

fn renderText(self: *Renderer, bbox: Rect, text_content: *const content.Text) !void {
    var lines = text_content.linesWithSizes(bbox.w);
    var line_index: usize = 0;

    var y_pos: f32 = bbox.y;
    while (try lines.next()) |line| : (line_index += 1) {
        const text_obj = try tvg.Text.init();

        if (line.text.len >= self.text_buf.len) {
            self.text_buf = try self.allocator.realloc(self.text_buf, (std.math.divCeil(usize, line.text.len, 1024) catch unreachable) * 1024);
        }

        @memcpy(self.text_buf[0..line.text.len], line.text);
        self.text_buf[line.text.len] = 0;

        text_obj.setText(self.text_buf[0..line.text.len :0]);
        try text_obj.setFont(if (text_content.style.font_family) |f| f.ptr else null, text_content.style.font_size, null);
        text_obj.setFillColor(
            .init(
                text_content.style.color.r,
                text_content.style.color.g,
                text_content.style.color.b,
                text_content.style.color.a,
            ),
        );

        const paint = text_obj.asPaint();
        const bounds = paint.getBounds(false);
        paint.translate(
            bbox.x + switch (text_content.style.alignment) {
                .left => 0,
                .center => (bbox.w - line.size.x) / 2,
                .right => bbox.w - line.size.x,
            } - bounds.x,
            y_pos - bounds.y,
        );

        y_pos += line.size.y;

        self.getActiveScene().push(paint);
    }
}

fn renderPicture(self: *Renderer, bbox: Rect, picture_content: *const content.Picture) !void {
    const paint = picture_content.picture.asPaint().duplicate().?;
    const bounds = paint.getBounds(false);
    paint.translate(bbox.x, bbox.y);
    paint.scale(@min(bbox.w / bounds.w, bbox.h / bounds.h));
    self.getActiveScene().push(paint);
}

fn isAllZero(cr: CornerRadius) bool {
    return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
}

fn uniformCorner(cr: CornerRadius) bool {
    return cr.top_left == cr.top_right and cr.top_left == cr.bottom_left and cr.top_left == cr.bottom_right;
}

fn appendRoundedRect(shape: *tvg.Shape, bbox: Rect, cr: CornerRadius) !void {
    const x = bbox.x;
    const y = bbox.y;
    const w = bbox.w;
    const h = bbox.h;

    const tl = cr.top_left;
    const tr = cr.top_right;
    const br = cr.bottom_right;
    const bl = cr.bottom_left;

    _ = shape.moveTo(x + tl, y);
    _ = shape.lineTo(x + w - tr, y);

    if (tr > 0) {
        _ = shape.cubicTo(
            x + w - tr * 0.448,
            y,
            x + w,
            y + tr * 0.448,
            x + w,
            y + tr,
        );
    }

    _ = shape.lineTo(x + w, y + h - br);

    if (br > 0) {
        _ = shape.cubicTo(
            x + w,
            y + h - br * 0.448,
            x + w - br * 0.448,
            y + h,
            x + w - br,
            y + h,
        );
    }

    _ = shape.lineTo(x + bl, y + h);

    if (bl > 0) {
        _ = shape.cubicTo(
            x + bl * 0.448,
            y + h,
            x,
            y + h - bl * 0.448,
            x,
            y + h - bl,
        );
    }

    _ = shape.lineTo(x, y + tl);

    if (tl > 0) {
        _ = shape.cubicTo(
            x,
            y + tl * 0.448,
            x + tl * 0.448,
            y,
            x + tl,
            y,
        );
    }

    _ = shape.close();
}

test {
    std.testing.refAllDecls(@This());
}
