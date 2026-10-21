# fabrum-renderer-thorvg

A renderer for [fabrum](https://github.com/ssttevee/fabrum)'s render commands
on [ThorVG](https://github.com/thorvg/thorvg)'s software engine, through
[zig-thorvg-bindings](https://github.com/ssttevee/zig-thorvg-bindings) (which
builds ThorVG from source with
[zig-thorvg](https://github.com/ssttevee/zig-thorvg): no system library). It
rasterizes a frame's `RenderCommand`s into a buffer of pixels you own, so a
program on fabrum's `none` platform (no window and no toolkit: your own code
hosts the runtime) can show a fabrum interface wherever there is a
framebuffer. Unlike the pure-Zig
[fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d) it
draws pictures (SVG, TVG, Lottie), at the cost of compiling ThorVG's C++.

| | |
|---|---|
| Module | `fabrum-renderer-thorvg` (package `fabrum_renderer_thorvg`) |
| Draws into | `.pixels` surfaces: `rgba8_premultiplied`, `bgra8_premultiplied` |
| Does not draw into | `gray8` (`error.UnsupportedFormat`): use the z2d renderer for grayscale panels |
| Draws | rectangles (per-corner radii), borders (inside their box), text, pictures, scissor clips |
| Text | TrueType, through ThorVG's text and TTF loader |
| Pictures | `content.Picture` around a `thorvg.Picture`, with a fit mode |
| Damage | redraws only the regions fabrum reports changed |
| Scale | any number of device pixels per point |
| Depends on | zig-thorvg-bindings (ThorVG 0.15.15, software engine; SVG, TVG, Lottie and TTF loaders by default); fabrum is given by the app (see below) |
| Zig | 0.17.0 |

## Adding it to an app

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-renderer-thorvg#trunk
```

**fabrum is the app's.** The renderer does not fetch fabrum itself: the app
gives the renderer's module the `fabrum` it uses, built with its own options
(`.platform = .none`). Zig makes one instance of a package per set of options,
so a renderer that asked for fabrum on its own would put a second `fabrum`
module in the program, and the build would fail with "file exists in modules
'fabrum' and 'fabrum0'". In `build.zig`:

```zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_thorvg", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-thorvg");
renderer.addImport("fabrum", fabrum);

exe.root_module.addImport("fabrum", fabrum);
exe.root_module.addImport("fabrum-renderer-thorvg", renderer);
```

`test/consumer` is exactly this: a package of its own that depends on this
one and on fabrum the way an app does. Then, in the host (the app's own code
that drives the runtime; see `fabrum.app.platform.none` for the contract):

```zig
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-thorvg");

var renderer: Renderer = try .init(gpa);
defer renderer.deinit();
try renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));

// the runtime measures text with the renderer's fonts
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = io, .text_context = renderer.text_context });
defer rt.deinit();

// allocate once and keep the pixels between frames
var buffer: [800 * 600 * 4]u8 align(4) = undefined;

// per frame: run it, then draw only what changed into your pixels
const commands = try rt.frame(Root, props, viewport, now);
try fabrum.layout.draw(&renderer, commands, .pixels, .packed_(&buffer, 800, 600, .rgba8_premultiplied), try rt.damage());
```

The pixel buffer must be 4-byte aligned and its stride a multiple of 4
(`error.UnalignedPixels` otherwise), since ThorVG writes whole 32-bit
pixels. `Surface.Pixels.packed_` describes a tightly packed buffer;
`packedScaled` adds the scale (device pixels per point); for padded rows fill
in `data`, `width`, `height`, `stride`, `format` and `scale` directly. Keep
the buffer between frames: a damage redraw leaves all other pixels as they
were, and the first frame must draw the whole surface.

`init` starts ThorVG's software engine (reference counted, so several
renderers can share it) and makes one `SoftwareCanvas`; `deinit` releases
both. The bindings are re-exported as `Renderer.tvg` for anything else you
want from ThorVG.

## What it does

**Commands.** `rectangle` fills a rounded rectangle (corner radii fitted to
the box). `border` fills the ring between the box and the box inset by the
border widths, as one path with a reversed inner contour, so a border never
spills onto its neighbours. `content` draws text and pictures.
`scissor_start`/`scissor_end` put what they hold in a child scene clipped to
the scissor's box, horizontally and/or vertically.

**Text.** `loadFont(name, data)` hands a TrueType font to ThorVG's TTF loader
(the name and data must outlive the renderer; ThorVG's font registry is per
process, so shared font data must stay alive until all users finish). Text whose style names a `font_family` uses that font; the
first loaded is the default. `Renderer.Text` is the text content type for
`app.Runtime`, measuring with ThorVG's own text bounds. Two constants in
`content.zig` paper over the C API: `size_scale` (72/96, since ThorVG takes
font sizes in points at 96 dpi) and `font_height` (1.15, an estimate of
ascender plus descender over the size, since the C API exposes no font
metrics; Go's is 1.14, Inter's 1.21). `font_weight` and
`letter_spacing` are not applied; load a different face under its own
family name for a different weight. There is no complex-script shaping or
fallback between font families.

**Pictures.** `content.Picture` wraps a `*thorvg.Picture` you loaded (with
the bindings' `Picture.load` or `loadData`: SVG, TVG, Lottie) in a
`fabrum.layout.Content`, with a `Style` of `fit_mode` (`contain`, `cover`,
`crop`, `stretch`) and `alignment` (defaults: `contain`, `center`). Make one
with `var picture: Renderer.content.Picture = .{ .picture = p, .style = style };`
and pass `&picture.content` as layout content, keeping both objects alive
while they are used. The fit mode controls measurement; `cover` can measure
larger than the constraints, so give it a clipping container when needed.
Drawing uses the laid-out box: `contain` fits uniformly inside it, `cover`
fills it uniformly, `crop` retains the original size, and `stretch` scales
each axis independently. `alignment` positions the image inside the box
(and chooses which overflow is cropped). Every mode clips to the box.

**Damage.** For each region, the renderer builds the commands that touch it
(with a margin for anti-aliasing and overhanging glyphs), and draws through a
viewport into a reusable full-surface scratch target. Coordinates and the
scale transform stay identical to a full redraw: translating a smaller
target changes ThorVG's curve quantization and can change antialiased pixels.
Only the region is copied back to the host's buffer; pixels outside the
regions are never touched. ThorVG clears the whole scratch target each time,
so scratch storage costs four bytes per surface pixel even for small damage.
Without a damage list the whole surface is redrawn. Scissors cull only on
the axes they enable, including nested single-axis clips.

**Formats.** ThorVG names channels from the most significant byte of a
little-endian word, so `rgba8_premultiplied` is its `ABGR8888` and
`bgra8_premultiplied` its `ARGB8888`.

Load fonts before measuring text. Non-empty text with no loaded font (or
an unknown `font_family`) fails measurement with `error.MeasureFailed`.
`Renderer.Text` uses fabrum's width-before-height layout: its content defaults
to `Content.limit = .ancestors`, then wraps at the width layout assigns.

Errors: `error.UnsupportedSurface` for a surface other than `.pixels`,
`error.UnsupportedFormat` for `gray8`, `error.UnalignedPixels`,
`error.NoFontLoaded` when text is drawn before any `loadFont`.

## Tests

```sh
zig build test
```

The package tests and the consumer app:

- the module's own, including `content/picture.zig`'s check that a picture
  measures to each fit mode within its constraints (skipped if the ThorVG
  build has no SVG loader);
- `test/render_test.zig`: the renderer against fabrum's
  `layout.checkRenderer`, premultiplied colors in RGBA and BGRA order over a
  cleared surface, scissors and borders inside their box, text in the loaded
  font inside its box, redrawing only the damage giving the same pixels as a
  full redraw (including fractional curves at several damage origins and
  scales, and nested single-axis clips), scale 2, `gray8` refused, and pixel checks of all picture fit
  modes with all nine alignments in wide and tall boxes, clipped to the box;
- `test/consumer`, built and tested as its own package with its own
  `zig build test`: an app on the `none` platform draws a progress bar with
  ThorVG, sharing its fabrum with the renderer.

The package's own tests bring their own fabrum, a lazy dependency fetched
only when this package is built as the root, so apps that depend on the
renderer never fetch it. The first build compiles ThorVG (C++), which takes a
while; later builds are cached.

## Who uses it

- [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen)'s
  `kitchen-none` can draw with it (`zig build run-none -Drenderer=thorvg -- --overlay`;
  with the current renderer). Its `gray8` e-ink mode is unsupported.

The package manifest includes the test sources, fonts, and consumer build
files (excluding the consumer's generated caches), so a fetched copy can run
`zig build test` (including the consumer app where present).
