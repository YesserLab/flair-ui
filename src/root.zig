//! flair-ui: a 2D vector graphics library backed by Vulkan.
//!
//! ## Quick Start
//!
//! ```zig
//! const flair = @import("flair-ui");
//! const std = @import("std");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Off-screen surface
//!     var surface = try flair.Surface.init(allocator, 800, 600);
//!     defer surface.deinit();
//!
//!     surface.clear(flair.Color.white);
//!     try surface.drawCircle(.{ .x = 400, .y = 300 }, 100, .{
//!         .style = .fill,
//!         .paint = .{ .solid = flair.Color.red },
//!     });
//!     try surface.savePng("output.png");
//! }
//! ```

// ---------------------------------------------------------------------------
// Re-export the public surface of the library
// ---------------------------------------------------------------------------

/// 2D point / vector
pub const Vec2 = @import("color.zig").Vec2;

/// RGBA color with f32 components in [0, 1]
pub const Color = @import("color.zig").Color;

/// A position + color pair used in gradients
pub const ColorStop = @import("color.zig").ColorStop;

/// A linear or radial gradient
pub const Gradient = @import("color.zig").Gradient;

/// How a shape is painted: solid color or gradient
pub const Paint = @import("color.zig").Paint;

/// Options for a draw call: style (fill/stroke) + paint
pub const DrawOptions = @import("color.zig").DrawOptions;

/// `.fill` or `.stroke` (with configurable width)
pub const DrawStyle = @import("color.zig").DrawStyle;

/// Stroke parameters
pub const StrokeOptions = @import("color.zig").StrokeOptions;

/// A 2D rectangle (position + size)
pub const Rect = @import("color.zig").Rect;

/// Per-corner radii for a rounded rectangle
pub const CornerRadii = @import("color.zig").CornerRadii;

/// Input events (keyboard, mouse, resize, close)
pub const Event = @import("input.zig").Event;
pub const Key = @import("input.zig").Key;
pub const Modifiers = @import("input.zig").Modifiers;
pub const MouseButton = @import("input.zig").MouseButton;
pub const KeyEvent = @import("input.zig").KeyEvent;
pub const MouseButtonEvent = @import("input.zig").MouseButtonEvent;
pub const MouseMoveEvent = @import("input.zig").MouseMoveEvent;
pub const ScrollEvent = @import("input.zig").ScrollEvent;

/// The primary drawing primitive: an offscreen Vulkan render target
pub const Surface = @import("surface.zig").Surface;

/// Platform-agnostic windowing interface
pub const Window = @import("window.zig").Window;

// ---------------------------------------------------------------------------
// Convenience constructors
// ---------------------------------------------------------------------------

/// Initialize a surface. Equivalent to `Surface.init(allocator, width, height)`.
pub fn createSurface(allocator: @import("std").mem.Allocator, width: u32, height: u32) !Surface {
    return Surface.init(allocator, width, height);
}

/// Initialize a window. Equivalent to `Window.init(allocator, width, height, title)`.
pub fn createWindow(
    allocator: @import("std").mem.Allocator,
    width: u32,
    height: u32,
    title: []const u8,
) !Window {
    return Window.init(allocator, width, height, title);
}

/// Release the global Vulkan renderer. Call this when the application exits.
pub fn deinit() void {
    @import("renderer.zig").release();
}
