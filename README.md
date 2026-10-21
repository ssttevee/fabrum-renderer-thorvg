# fabrum-renderer-thorvg

A renderer for [fabrum](https://github.com/ssttevee/fabrum) built on
[ThorVG](https://github.com/thorvg/thorvg), a small vector graphics library.

**What it does:** fabrum describes your UI as a list of drawing commands,
such as "fill this rectangle" or "draw this text here". This package turns
those commands into pixels in a memory buffer that you own. You can then
send the pixels wherever you like: a remote desktop session, a game's
frame, an embedded display, or a PNG in a test.

**When you'd use it:** on fabrum's `none` platform. That's the platform for
places with no window system, where your own program runs the main loop and
handles the screen. You don't need it on macOS or Linux desktops, where
fabrum already draws with the system's Quartz or Cairo.

**Why this one:** it can draw **pictures** (SVG, TVG and Lottie files) as
well as rectangles and text. The trade-off is that it compiles ThorVG's C++
source as part of your build, so the first build takes a while. There's
nothing to install, though: ThorVG is built from source through
[zig-thorvg-bindings](https://github.com/ssttevee/zig-thorvg-bindings). If
you don't need pictures, or you need grayscale for an e-ink screen, the
pure-Zig [fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d)
is simpler.

## At a glance

| | |
|---|---|
| Draws | Rectangles (with rounded corners), borders, text, pictures, and clipping |
| Pictures | SVG, TVG and Lottie, scaled to fit their box in one of four ways |
| Pixel formats | RGBA or BGRA (premultiplied). Not grayscale. |
| Fonts | TrueType fonts that you load |
| Redraws | Only the parts of the screen that changed |
| Depends on | zig-thorvg-bindings (ThorVG 0.15.15), and the fabrum your app already uses |
| Zig version | 0.17.0 |

## Add it to your app

Fetch fabrum and the renderer:

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-renderer-thorvg#trunk
```

In `build.zig`, give the renderer **your** fabrum module:

```zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_thorvg", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-thorvg");
renderer.addImport("fabrum", fabrum);

exe.root_module.addImport("fabrum", fabrum);
exe.root_module.addImport("fabrum-renderer-thorvg", renderer);
```

**Why `addImport`?** The renderer needs fabrum's types, but it deliberately
doesn't fetch fabrum itself. If it did, Zig would build a second, separate
copy of fabrum without your build options (such as `.platform = .none`). A
program can't contain two copies of fabrum; the build fails with "file
exists in modules 'fabrum' and 'fabrum0'". Handing the renderer your module
means everything shares one fabrum.

[`test/consumer`](test/consumer) is a small app set up exactly like this,
if you want a working example to copy.

## Draw a frame

On the `none` platform, your program is the **host**. It owns the main
loop, passes input to fabrum, and draws each frame. The full contract is
documented in `fabrum.app.platform.none`. The drawing part looks like this:

```zig
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-thorvg");

// 1. Make a renderer and give it at least one font.
var renderer: Renderer = try .init(gpa);
defer renderer.deinit();
try renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));

// 2. Make the runtime. It measures text with the renderer's fonts, so the
//    layout matches what actually gets drawn.
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = io, .text_context = renderer.text_context });
defer rt.deinit();

// 3. Allocate the pixels once, and keep them between frames.
var buffer: [800 * 600 * 4]u8 align(4) = undefined;

// 4. Each frame: run the UI, then draw only what changed into your pixels.
const commands = try rt.frame(Root, props, viewport, now);
try fabrum.layout.draw(&renderer, commands, .pixels, .packed_(&buffer, 800, 600, .rgba8_premultiplied), try rt.damage());
```

A few rules for the pixel buffer:

- **Keep the same buffer between frames.** `rt.damage()` returns the
  regions that changed since the last frame. fabrum calls these the
  **damage**. The renderer redraws only those regions and leaves every
  other pixel alone. That makes redraws fast, but only if the buffer still
  holds the previous frame. The first frame must draw the whole surface.
- **Align it to 4 bytes.** ThorVG writes whole 32-bit pixels, so the
  buffer must be 4-byte aligned and each row's length in bytes (the
  **stride**) a multiple of 4. Otherwise you get `error.UnalignedPixels`.
- **Describe the buffer's shape.** Use `Surface.Pixels.packed_` for a
  buffer whose rows sit back to back, or `packedScaled` to also give a scale
  (see [Scale](#scale)). If your framebuffer pads the end of each row, fill
  in the struct's `data`, `width`, `height`, `stride`, `format` and `scale`
  fields yourself.

`init` starts ThorVG's software rendering engine and creates one canvas.
`deinit` releases both. The engine is reference counted, so several
renderers can share it. The underlying bindings are available as
`Renderer.tvg` if you want to use ThorVG directly.

## Show a picture

Load a `thorvg.Picture` with the bindings (`Picture.load` for a file, or
`loadData` for bytes in memory), wrap it in a `content.Picture` with a
`Style`, and pass its `fabrum.layout.Content` to layout:

```zig
var picture: Renderer.content.Picture = .{ .picture = p, .style = style };
// use &picture.content as the layout content of a box
```

Keep both the ThorVG picture and the `content.Picture` alive for as long as
the layout uses them.

The style's `fit_mode` decides how the picture fills its box:

| `fit_mode` | What happens |
|---|---|
| `contain` (default) | Scaled evenly until it just fits inside the box. The whole picture shows, possibly with empty space around it. |
| `cover` | Scaled evenly until it fills the box. The edges may be cut off. |
| `crop` | Kept at its original size. Whatever doesn't fit is cut off. |
| `stretch` | Width and height are scaled separately to fill the box exactly. The picture may look squashed. |

`alignment` (default `center`) places the picture inside its box, and so
also decides which edges get cut off. Every mode clips to the box.

The fit mode also affects how big the picture asks to be during layout. With
`cover`, it can ask for more space than its parent offers, so put it inside
a box that clips if that matters.

## How it works

### Drawing commands

| Command | What the renderer does |
|---|---|
| `rectangle` | Fills a rectangle. Each corner can have its own radius. |
| `border` | Fills the ring between the box's edge and an inner edge set in by the border widths, drawn as one shape with a hole. A border always stays *inside* its box, so it never overlaps its neighbours. |
| `content` | Draws text and pictures. |
| `scissor_start` / `scissor_end` | Clips everything in between to a box: horizontally, vertically, or both. The clipped content goes into a ThorVG child scene with the clip applied. |

### Text and fonts

Load fonts with `loadFont(name, data)`, which hands a TrueType font to
ThorVG. Both the name and the data must stay alive as long as the renderer
does. ThorVG keeps one font list for the whole process, so if several
renderers share font data, it must outlive all of them. The first font you
load is the default, and text whose style sets `font_family` uses the font
loaded under that name.

`Renderer.Text` is the text type you give to `app.Runtime`. It measures
text with ThorVG's own text bounds, so lines wrap exactly where they're
drawn. fabrum decides a box's width first, then wraps its text to fit.

ThorVG's C API is missing a couple of things the renderer needs, so
`content.zig` fills them in with two constants:

- `size_scale` (72/96): ThorVG takes font sizes in points at 96 DPI, so
  fabrum's sizes are converted.
- `font_height` (1.15): the C API doesn't report a font's line height, so
  this is an estimate that works for common fonts. Go measures 1.14 and
  Inter 1.21.

Limitations:

- `font_weight` doesn't select a bold face for you. Load the bold font
  under its own family name, and use that name.
- Letter spacing is ignored.
- Scripts that need complex shaping, such as Arabic or Devanagari, aren't
  shaped, and there's no fallback between fonts.

### Redrawing only what changed

For each damaged region, the renderer collects the commands that touch it,
plus a small margin for smoothed edges and letters that stick out of their
box. It draws them into a scratch image the size of the whole surface,
through a viewport limited to the region, then copies just that region into
your buffer. Pixels outside the regions are never written.

Why a full-size scratch image instead of a small one? Moving the drawing
into a smaller image changes how ThorVG rounds curves, and that can change
the smoothed pixels along an edge. Keeping the same coordinates as a full
redraw means a partial redraw always matches it exactly. The cost is memory:
the scratch image takes 4 bytes per pixel of the surface, however small the
damage is.

Without a damage list, the whole surface is redrawn.

### Pixel formats

ThorVG names channels starting from the most significant byte of a
little-endian 32-bit word, so the names look reversed:

| fabrum format | ThorVG name |
|---|---|
| `rgba8_premultiplied` | `ABGR8888` |
| `bgra8_premultiplied` | `ARGB8888` |
| `gray8` | Not supported (`error.UnsupportedFormat`). Use the z2d renderer for grayscale. |

"Premultiplied" means each color channel has already been multiplied by
the pixel's opacity (its alpha). It's the usual format for blending images
quickly.

### Scale

Commands and damage are measured in **points**, fabrum's
resolution-independent unit. `Pixels.scale` says how many device pixels
make up one point, and every coordinate, radius, border width and font size
is multiplied by it when drawn. On a 2× screen, text and pictures are drawn
at twice the size at full sharpness.

### Errors

| Error | Cause |
|---|---|
| `error.MeasureFailed` | Text was measured with no font loaded, or with a `font_family` that isn't loaded. Load fonts before the first frame. |
| `error.NoFontLoaded` | Text was drawn before any `loadFont`. |
| `error.UnalignedPixels` | The buffer isn't 4-byte aligned, or its stride isn't a multiple of 4. |
| `error.UnsupportedFormat` | The surface is `gray8`. |
| `error.UnsupportedSurface` | The surface isn't `.pixels`. |

## Tests

```sh
zig build test
```

This runs three sets of tests:

- **The module's own tests**, including `content/picture.zig`'s check that a picture measures to
  the right size in each fit mode. That check is skipped if ThorVG was built
  without its SVG loader.
- **`test/render_test.zig`** runs the renderer through fabrum's standard
  renderer checks (`layout.checkRenderer`), and also checks that:
  - colors come out right in both RGBA and BGRA order;
  - clipping works, including nested clips on one axis, and borders stay
    inside their box;
  - text is drawn in the loaded font, inside its box;
  - redrawing only the damaged regions gives exactly the same pixels as a
    full redraw, including curves at several positions and scales;
  - drawing works at 2× scale, and `gray8` is refused;
  - every picture fit mode, with all nine alignments, in wide and tall
    boxes, is drawn where it should be and clipped to its box.
- **`test/consumer`**, a separate app on the `none` platform that draws a
  progress bar with ThorVG, sharing its fabrum with the renderer. It's built
  and tested as its own package.

The tests bring their own fabrum, but fetch it only when you build this
package directly. Apps that depend on the renderer never download it. The
test sources, fonts and consumer app ship with the package, so
`zig build test` also works on a copy in Zig's package cache.

The first build compiles ThorVG's C++, which takes a while. Later builds
are cached.

## Who uses it

- [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen)'s
  `kitchen-none` can draw with it instead of z2d:
  `zig build run-none -Drenderer=thorvg -- --overlay`. Its grayscale e-ink
  mode needs z2d.
