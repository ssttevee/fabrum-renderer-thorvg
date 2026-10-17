const std = @import("std");
const tvg = @import("thorvg");
const fabrum = @import("fabrum");

const Vec2 = fabrum.Vec2;

pub const Text = fabrum.TextContent(
    struct {
        inner: fabrum.TextContentCachedContext(struct {
            allocator: std.mem.Allocator,
            text: *tvg.Text,
            state: *State,

            pub const State = struct {
                buf: []u8,
            };

            pub fn init(allocator: std.mem.Allocator) !@This() {
                const text = try tvg.Text.init();
                errdefer text.deinit();

                const state = try allocator.create(State);
                errdefer allocator.destroy(state);

                state.buf = try allocator.alloc(u8, 1 << 10);

                return .{
                    .allocator = allocator,
                    .text = text,
                    .state = state,
                };
            }

            pub fn measureText(self: @This(), text: []const u8, style: fabrum.TextStyle) fabrum.LayoutContent.MeasureError!Vec2 {
                if (self.state.buf.len < text.len) {
                    self.state.buf = self.allocator.realloc(self.state.buf, self.state.buf.len + (1 << 10)) catch return error.MeasureFailed;
                }

                @memcpy(self.state.buf.ptr, text);
                self.state.buf[text.len] = 0;

                self.text.setText(self.state.buf[0..text.len :0]);
                self.text.setFont(if (style.font_family) |f| f.ptr else null, style.font_size, null) catch return error.MeasureFailed;

                const bounds = self.text.asPaint().getBounds(false);

                return .init(bounds.w, bounds.h);
            }

            pub fn deinit(self: *@This()) void {
                self.text.deinit();
                self.allocator.free(self.state.buf);
                self.allocator.destroy(self.state);
                self.* = undefined;
            }
        }),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .inner = try .init(allocator, try .init(allocator)),
            };
        }

        pub fn measureText(self: @This(), text: []const u8, style: fabrum.TextStyle) fabrum.LayoutContent.MeasureError!Vec2 {
            return self.inner.measureText(text, style);
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    },
);

pub const Picture = @import("content/picture.zig");
