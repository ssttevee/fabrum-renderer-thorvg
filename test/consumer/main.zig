//! Runs a drawn widget on the `none` platform and draws it with ThorVG.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-thorvg");

const Root = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .padding = .all(10) } });
        defer ui.close();
        try app.widgets.progressBar(ui, "done", .{ .value = 1 });
    }
};

test "an app on the none platform draws with ThorVG, sharing its fabrum" {
    comptime std.debug.assert(app.platform.kind == .none);
    const gpa = std.testing.allocator;
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = std.testing.io, .text_context = renderer.text_context });
    defer rt.deinit();
    const commands = try rt.frame(Root, .{}, .init(100, 50), .zero);

    var buffer: [100 * 50 * 4]u8 align(4) = undefined;
    try fabrum.layout.draw(&renderer, commands, .pixels, .packed_(&buffer, 100, 50, .rgba8_premultiplied), try rt.damage());
    // the bar is drawn, filled with the accent color
    const bar = rt.context().getUnitById(app.testing.rootInstance(Root).element("done")).?.bbox;
    const x: usize = @intFromFloat(bar.x + bar.w / 2);
    const y: usize = @intFromFloat(bar.y + bar.h / 2);
    const accent = (app.native.Theme{}).accent;
    try std.testing.expectEqualSlices(u8, &.{ accent.r, accent.g, accent.b, 255 }, buffer[(y * 100 + x) * 4 ..][0..4]);
}
