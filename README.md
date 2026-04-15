# flair-ui

A complete 2D vector graphics library written in [Zig](https://ziglang.org), backed **exclusively by Vulkan**.

## Features

- **Surface** — offscreen RGBA render target backed by a Vulkan image
- **All major 2D shapes**: line, polyline/path, quadratic & cubic Bézier curves, circle, circular arc, oval/ellipse, elliptical arc, rectangle with independent per-corner radii
- **Fill and stroke** for every shape
- **Paint system**: solid color or linear/radial gradient
- **PNG export** — save any surface to disk using a pure-Zig PNG encoder
- **Platform-agnostic Window** abstraction (vtable pattern) with keyboard and mouse input
- **Wayland backend** — presents surfaces to the screen via `VK_KHR_wayland_surface`

---

## Requirements

| Dependency | Version |
|---|---|
| Zig | 0.13.0 or later |
| Vulkan SDK / `libvulkan` | 1.0+ |
| `libwayland-client` | any |
| `wayland-protocols` | for xdg-shell |
| `glslangValidator` | for shader compilation |

On Ubuntu/Debian:
```sh
sudo apt install libvulkan-dev libwayland-dev wayland-protocols glslang-tools
```

---

## Building

```sh
zig build
```

This will:
1. Compile GLSL shaders (`src/shaders/fill.vert.glsl`, `fill.frag.glsl`) to SPIR-V
2. Build the static library `libflair-ui.a`
3. Build the example executables

Run examples:
```sh
zig build run-basic    # draws all shapes to basic_shapes.png
zig build run-window   # opens a Wayland window with mouse/keyboard input
```

---

## Quick Start

### Offscreen surface → PNG

```zig
const flair = @import("flair-ui");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer flair.deinit();

    // Create an 800×600 offscreen surface
    var surface = try flair.Surface.init(allocator, 800, 600);
    defer surface.deinit();

    // Clear the surface to white
    surface.clear(flair.Color.white);

    // Draw a filled red circle
    try surface.drawCircle(.{ .x = 400, .y = 300 }, 100, .{
        .style = .fill,
        .paint = .{ .solid = flair.Color.red },
    });

    // Draw a stroked rectangle with rounded corners and a gradient
    try surface.drawRect(
        .{ .x = 50, .y = 50, .width = 200, .height = 150 },
        .{ .top_left = 10, .top_right = 10, .bottom_left = 0, .bottom_right = 0 },
        .{
            .style = .{ .stroke = .{ .line_width = 3.0 } },
            .paint = .{
                .gradient = flair.Gradient.linear(
                    .{ .x = 50, .y = 50 },
                    .{ .x = 250, .y = 200 },
                    &.{
                        .{ .position = 0.0, .color = flair.Color.blue },
                        .{ .position = 1.0, .color = flair.Color.green },
                    },
                ),
            },
        },
    );

    // Draw a cubic Bézier curve
    try surface.drawCubicBezier(
        .{ .x = 100, .y = 500 },
        .{ .x = 200, .y = 400 },
        .{ .x = 300, .y = 600 },
        .{ .x = 400, .y = 500 },
        .{
            .style = .{ .stroke = .{ .line_width = 2.0 } },
            .paint = .{ .solid = flair.Color.black },
        },
    );

    // Save to PNG
    try surface.savePng("output.png");
}
```

### Window with event handling

```zig
const flair = @import("flair-ui");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer flair.deinit();

    var window = try flair.Window.init(allocator, 800, 600, "Flair App");
    defer window.deinit();

    while (!window.shouldClose()) {
        // Poll events
        while (window.pollEvent()) |event| {
            switch (event) {
                .key_press => |ke| {
                    if (ke.key == .escape) return;
                },
                .mouse_move => |mm| {
                    _ = mm; // use mm.x, mm.y
                },
                .close => return,
                else => {},
            }
        }

        // Draw to the window's surface
        const surf = window.getSurface();
        surf.clear(flair.Color.white);
        try surf.drawCircle(.{ .x = 400, .y = 300 }, 50, .{
            .style = .fill,
            .paint = .{ .solid = flair.Color.red },
        });

        // Present
        try window.present();
    }
}
```

---

## Architecture

```
flair-ui/
├── build.zig                  # Build: shaders, library, examples
├── build.zig.zon              # Package manifest
├── src/
│   ├── root.zig               # Public API re-exports
│   ├── color.zig              # Vec2, Color, Gradient, Paint, DrawOptions
│   ├── input.zig              # Event, Key, MouseButton, Modifiers
│   ├── shapes.zig             # CPU tessellation for all shape types
│   ├── image.zig              # Pure-Zig PNG encoder
│   ├── vulkan.zig             # Vulkan loader + helpers (Buffer, one-shot cmd)
│   ├── renderer.zig           # Vulkan pipeline, descriptor sets, global state
│   ├── surface.zig            # Surface (offscreen Vulkan framebuffer)
│   ├── window.zig             # Platform-agnostic Window vtable
│   ├── platform/
│   │   ├── wayland.zig        # Wayland backend (wl_display, xdg-shell, wl_seat)
│   │   └── generated/         # Auto-generated xdg-shell C headers
│   └── shaders/
│       ├── fill.vert.glsl     # Vertex shader (position, gradient coord, color)
│       └── fill.frag.glsl     # Fragment shader (solid + gradient sampling)
└── examples/
    ├── basic_shapes.zig       # All shape types → PNG
    └── window_events.zig      # Window + mouse/keyboard
```

### Shape Tessellation

All shapes are tessellated into triangles on the CPU:

| Shape | Method |
|---|---|
| Line | Quad (2 triangles) perpendicular to direction |
| Path | Line-segment quads, joined |
| Quadratic/Cubic Bézier | De Casteljau recursive flattening → path |
| Circle / Arc | Regular polygon fan or ring segments |
| Oval / Oval Arc | Ellipse segments |
| Rectangle | 2 triangles; rounded corners add arc segments |

### Gradient Rendering

- Each vertex carries a `gradient_coord` computed during tessellation
- The fragment shader samples the gradient's color stops at `gradient_coord.x`
- Push constants carry the 4×4 orthographic projection matrix
- A uniform buffer (`PaintData`) carries gradient type + up to 16 color stops

### Platform Abstraction

`Window` uses a vtable pattern:

```zig
pub const WindowVTable = struct {
    deinit:         *const fn(*anyopaque) void,
    pollEvent:      *const fn(*anyopaque) ?Event,
    shouldClose:    *const fn(*anyopaque) bool,
    presentSurface: *const fn(*anyopaque, usize, u32, u32) anyerror!void,
    getWidth:       *const fn(*anyopaque) u32,
    getHeight:      *const fn(*anyopaque) u32,
    setTitle:       *const fn(*anyopaque, []const u8) void,
};
```

Adding a new platform (macOS, Windows) requires implementing the vtable functions in a new file under `src/platform/`.

---

## API Reference

### `flair.Color`

```zig
// Named constants
Color.white, Color.black, Color.red, Color.green, Color.blue
Color.yellow, Color.cyan, Color.magenta, Color.gray, Color.orange
Color.transparent

// Construction
Color.rgb(r, g, b)           // f32 components
Color.rgba(r, g, b, a)
Color.fromRgba8(r, g, b, a)  // u8 components (0–255)
```

### `flair.Gradient`

```zig
Gradient.linear(start: Vec2, end: Vec2, stops: []const ColorStop)
Gradient.radial(center: Vec2, radius: f32, stops: []const ColorStop)
```

### `flair.DrawOptions`

```zig
DrawOptions{
    .style = .fill,
    // or:
    .style = .{ .stroke = .{ .line_width = 2.5 } },
    .paint = .{ .solid = Color.red },
    // or:
    .paint = .{ .gradient = Gradient.linear(...) },
}
```

### `flair.Surface`

```zig
// Creation / destruction
Surface.init(allocator, width, height) !Surface
surface.deinit()

// Clear
surface.clear(color: Color)

// Drawing
surface.drawLine(a, b, opts) !void
surface.drawPath(points, closed, opts) !void
surface.drawQuadraticBezier(p0, p1, p2, opts) !void
surface.drawCubicBezier(p0, p1, p2, p3, opts) !void
surface.drawCircle(center, radius, opts) !void
surface.drawCircularArc(center, radius, start_angle, end_angle, opts) !void
surface.drawOval(center, rx, ry, opts) !void
surface.drawOvalArc(center, rx, ry, start_angle, end_angle, opts) !void
surface.drawRect(rect, radii, opts) !void

// Export
surface.flush() !void       // render pending draw calls
surface.savePng(path) !void // flush + write PNG
surface.readPixels() ![]u8  // flush + return RGBA pixels (caller frees)
```

### `flair.Window`

```zig
// Creation / destruction
Window.init(allocator, width, height, title) !Window
window.deinit()

// Per-frame
window.pollEvent() ?Event
window.shouldClose() bool
window.getSurface() *Surface
window.present() !void       // flush surface + blit to screen

// Properties
window.getWidth() u32
window.getHeight() u32
window.setTitle(title) void
```

### `flair.Event`

```zig
.key_press        => KeyEvent    { .key, .scancode, .mods }
.key_release      => KeyEvent
.key_repeat       => KeyEvent
.mouse_button_press   => MouseButtonEvent { .button, .x, .y, .mods }
.mouse_button_release => MouseButtonEvent
.mouse_move       => MouseMoveEvent { .x, .y }
.mouse_scroll     => ScrollEvent    { .dx, .dy }
.mouse_enter      => MouseMoveEvent
.mouse_leave      => MouseMoveEvent
.resize           => ResizeEvent    { .width, .height }
.close
```

---

## License

MIT

