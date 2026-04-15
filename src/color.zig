//! Color, Gradient, Paint — the paint system for flair-ui.
//!
//! Colors are RGBA with f32 components in the range [0.0, 1.0].

const std = @import("std");

// ---------------------------------------------------------------------------
// Vec2 — a 2D point / vector used throughout the library
// ---------------------------------------------------------------------------

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn length(v: Vec2) f32 {
        return @sqrt(v.x * v.x + v.y * v.y);
    }

    pub fn normalize(v: Vec2) Vec2 {
        const len = v.length();
        if (len < 1e-10) return .{ .x = 0, .y = 0 };
        return .{ .x = v.x / len, .y = v.y / len };
    }

    pub fn perp(v: Vec2) Vec2 {
        return .{ .x = -v.y, .y = v.x };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
};

// ---------------------------------------------------------------------------
// Color
// ---------------------------------------------------------------------------

/// An RGBA color with f32 components in [0.0, 1.0].
pub const Color = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    a: f32 = 1.0,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    /// Convert from 0–255 RGBA integer components.
    pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Convert to 0–255 RGBA integer components.
    pub fn toRgba8(self: Color) [4]u8 {
        return .{
            @as(u8, @intFromFloat(std.math.clamp(self.r * 255.0, 0.0, 255.0))),
            @as(u8, @intFromFloat(std.math.clamp(self.g * 255.0, 0.0, 255.0))),
            @as(u8, @intFromFloat(std.math.clamp(self.b * 255.0, 0.0, 255.0))),
            @as(u8, @intFromFloat(std.math.clamp(self.a * 255.0, 0.0, 255.0))),
        };
    }

    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const s = 1.0 - t;
        return .{
            .r = a.r * s + b.r * t,
            .g = a.g * s + b.g * t,
            .b = a.b * s + b.b * t,
            .a = a.a * s + b.a * t,
        };
    }

    // Named colors
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    pub const yellow = Color{ .r = 1, .g = 1, .b = 0, .a = 1 };
    pub const cyan = Color{ .r = 0, .g = 1, .b = 1, .a = 1 };
    pub const magenta = Color{ .r = 1, .g = 0, .b = 1, .a = 1 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 };
    pub const dark_gray = Color{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1 };
    pub const light_gray = Color{ .r = 0.75, .g = 0.75, .b = 0.75, .a = 1 };
    pub const orange = Color{ .r = 1, .g = 0.5, .b = 0, .a = 1 };
    pub const purple = Color{ .r = 0.5, .g = 0, .b = 0.5, .a = 1 };
};

// ---------------------------------------------------------------------------
// ColorStop — a position + color for gradients
// ---------------------------------------------------------------------------

pub const ColorStop = struct {
    /// Position in [0.0, 1.0] along the gradient.
    position: f32,
    color: Color,
};

// ---------------------------------------------------------------------------
// Gradient types
// ---------------------------------------------------------------------------

pub const LinearGradient = struct {
    start: Vec2,
    end: Vec2,
    stops: []const ColorStop,
};

pub const RadialGradient = struct {
    center: Vec2,
    radius: f32,
    stops: []const ColorStop,
};

pub const GradientKind = union(enum) {
    linear: LinearGradient,
    radial: RadialGradient,
};

/// A gradient: linear or radial, with color stops.
pub const Gradient = struct {
    kind: GradientKind,

    pub fn linear(start: Vec2, end: Vec2, stops: []const ColorStop) Gradient {
        return .{ .kind = .{ .linear = .{ .start = start, .end = end, .stops = stops } } };
    }

    pub fn radial(center: Vec2, radius: f32, stops: []const ColorStop) Gradient {
        return .{ .kind = .{ .radial = .{ .center = center, .radius = radius, .stops = stops } } };
    }

    /// Sample the gradient at position t ∈ [0.0, 1.0].
    pub fn sample(self: Gradient, t: f32) Color {
        const stops = switch (self.kind) {
            .linear => |g| g.stops,
            .radial => |g| g.stops,
        };
        if (stops.len == 0) return Color.black;
        if (stops.len == 1) return stops[0].color;

        const tc = std.math.clamp(t, 0.0, 1.0);

        // Find the two stops bracketing t
        var i: usize = 0;
        while (i + 1 < stops.len and stops[i + 1].position <= tc) : (i += 1) {}

        if (i + 1 >= stops.len) return stops[stops.len - 1].color;
        if (tc <= stops[0].position) return stops[0].color;

        const a = stops[i];
        const b = stops[i + 1];
        const range = b.position - a.position;
        if (range < 1e-10) return a.color;
        const local_t = (tc - a.position) / range;
        return Color.lerp(a.color, b.color, local_t);
    }
};

// ---------------------------------------------------------------------------
// Paint — solid or gradient
// ---------------------------------------------------------------------------

pub const Paint = union(enum) {
    solid: Color,
    gradient: Gradient,

    /// Sample the paint to get a color at gradient coordinate t.
    pub fn sampleAt(self: Paint, t: f32) Color {
        return switch (self) {
            .solid => |c| c,
            .gradient => |g| g.sample(t),
        };
    }
};

// ---------------------------------------------------------------------------
// DrawStyle
// ---------------------------------------------------------------------------

pub const StrokeOptions = struct {
    /// Width of the stroke in surface pixels.
    line_width: f32 = 1.0,
};

pub const DrawStyle = union(enum) {
    fill: void,
    stroke: StrokeOptions,
};

/// Options passed to every draw call.
pub const DrawOptions = struct {
    style: DrawStyle = .fill,
    paint: Paint = .{ .solid = Color.black },
};

// ---------------------------------------------------------------------------
// Rectangle & corner radii
// ---------------------------------------------------------------------------

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Independent corner radii for a rounded rectangle.
pub const CornerRadii = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub const zero = CornerRadii{};

    pub fn uniform(r: f32) CornerRadii {
        return .{ .top_left = r, .top_right = r, .bottom_left = r, .bottom_right = r };
    }
};
