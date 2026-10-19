const std = @import("std");
const tvg = @import("thorvg");
const fabrum = @import("fabrum");

const Vec2 = fabrum.Vec2;

/// The height of a font's ascender plus descender, as a fraction of its
/// size: what ThorVG's text sits in, from the top of the ascender. ThorVG's
/// C API doesn't give fonts' metrics; this is close for most UI fonts
/// (Go's is 1.14, Inter's 1.21).
pub const font_height = 1.15;

/// ThorVG takes font sizes in points at 96 dots per inch; fabrum's are in
/// points of the surface, one pixel each at scale 1. Sizes given to ThorVG
/// are multiplied by this.
pub const size_scale = 72.0 / 96.0;

/// The fonts text is drawn in, shared by measuring and drawing.
pub const Fonts = struct {
    /// The font for text without a `font_family`: the first loaded.
    default: ?[:0]const u8 = null,
};

/// Text measured as ThorVG draws it: as wide as its glyphs reach from the
/// origin, and as tall as its lines.
pub const Text = fabrum.layout.text.Content(
    struct {
        inner: fabrum.layout.text.CachedContext(Measurer),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .inner = try .init(allocator, try .init(allocator)) };
        }

        pub fn measureText(self: @This(), text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
            return self.inner.measureText(text, style);
        }

        /// The fonts loaded so far.
        pub fn fonts(self: @This()) *Fonts {
            return &self.inner.inner.state.fonts;
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    },
);

const Measurer = struct {
    allocator: std.mem.Allocator,
    text: *tvg.Text,
    state: *State,

    pub const State = struct {
        buf: std.ArrayList(u8) = .empty,
        fonts: Fonts = .{},
    };

    pub fn init(allocator: std.mem.Allocator) !Measurer {
        const text = try tvg.Text.init();
        errdefer text.deinit();
        const state = try allocator.create(State);
        state.* = .{};
        return .{ .allocator = allocator, .text = text, .state = state };
    }

    pub fn measureText(self: Measurer, text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
        const height = style.font_size * style.line_height;
        if (text.len == 0) return .init(0, height);
        const font = style.font_family orelse self.state.fonts.default orelse return error.MeasureFailed;
        const buf = &self.state.buf;
        buf.clearRetainingCapacity();
        buf.appendSlice(self.allocator, text) catch return error.MeasureFailed;
        buf.append(self.allocator, 0) catch return error.MeasureFailed;

        self.text.setText(buf.items[0..text.len :0]);
        self.text.setFont(font.ptr, style.font_size * size_scale, null) catch return error.MeasureFailed;
        const bounds = self.text.asPaint().getBounds(false);
        // from the origin, so lines start where they are drawn
        return .init(@max(bounds.x + bounds.w, 0), height);
    }

    pub fn deinit(self: *Measurer) void {
        self.text.deinit();
        self.state.buf.deinit(self.allocator);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }
};

pub const Picture = @import("content/picture.zig");

test {
    _ = Picture;
}
