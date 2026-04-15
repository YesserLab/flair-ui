//! Shape tessellation: converts drawing primitives into triangle vertex lists.
//!
//! All shapes are tessellated into triangles on the CPU. The resulting vertices
//! are uploaded to a Vulkan vertex buffer for rendering.

const std = @import("std");
const color = @import("color.zig");
const Vec2 = color.Vec2;
const Color = color.Color;
const Paint = color.Paint;
const DrawOptions = color.DrawOptions;
const DrawStyle = color.DrawStyle;
const Rect = color.Rect;
const CornerRadii = color.CornerRadii;

// ---------------------------------------------------------------------------
// Vertex format (matches the GLSL vertex shader input layout)
// ---------------------------------------------------------------------------

pub const Vertex = extern struct {
    /// 2D position in surface pixel coordinates.
    position: [2]f32,
    /// Gradient coordinate (0.0–1.0). Used by the fragment shader to sample gradients.
    gradient_coord: [2]f32,
    /// RGBA color. For solid paints, this is the fill color.
    /// For gradients, the fragment shader samples from the gradient using gradient_coord.
    color: [4]f32,
};

// ---------------------------------------------------------------------------
// Gradient coordinate helpers
// ---------------------------------------------------------------------------

/// Compute gradient_coord.x for a position along a linear gradient.
fn linearGradCoord(pos: Vec2, g_start: Vec2, g_end: Vec2) f32 {
    const dir = Vec2.sub(g_end, g_start);
    const len_sq = dir.x * dir.x + dir.y * dir.y;
    if (len_sq < 1e-10) return 0.0;
    const dp = Vec2.sub(pos, g_start);
    return std.math.clamp(Vec2.dot(dp, dir) / len_sq, 0.0, 1.0);
}

/// Compute gradient_coord.x for a position in a radial gradient.
fn radialGradCoord(pos: Vec2, center: Vec2, radius: f32) f32 {
    if (radius < 1e-10) return 0.0;
    const d = Vec2.sub(pos, center);
    return std.math.clamp(@sqrt(d.x * d.x + d.y * d.y) / radius, 0.0, 1.0);
}

fn gradCoord(pos: Vec2, opts: DrawOptions) [2]f32 {
    return switch (opts.paint) {
        .solid => .{ 0.0, 0.0 },
        .gradient => |g| switch (g.kind) {
            .linear => |lg| .{ linearGradCoord(pos, lg.start, lg.end), 0.0 },
            .radial => |rg| .{ radialGradCoord(pos, rg.center, rg.radius), 0.0 },
        },
    };
}

fn solidColor(opts: DrawOptions) [4]f32 {
    return switch (opts.paint) {
        .solid => |c| .{ c.r, c.g, c.b, c.a },
        // For gradients we encode the color at t=0 as a fallback; the fragment
        // shader will actually sample from the gradient using gradient_coord.
        .gradient => |g| blk: {
            const c = g.sample(0.0);
            break :blk .{ c.r, c.g, c.b, c.a };
        },
    };
}

fn makeVertex(pos: Vec2, opts: DrawOptions) Vertex {
    return .{
        .position = .{ pos.x, pos.y },
        .gradient_coord = gradCoord(pos, opts),
        .color = solidColor(opts),
    };
}

// ---------------------------------------------------------------------------
// Tessellator — accumulates vertices and indices
// ---------------------------------------------------------------------------

pub const Tessellator = struct {
    vertices: std.ArrayList(Vertex),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tessellator {
        return .{
            .vertices = std.ArrayList(Vertex).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tessellator) void {
        self.vertices.deinit();
    }

    pub fn reset(self: *Tessellator) void {
        self.vertices.clearRetainingCapacity();
    }

    fn addTri(self: *Tessellator, a: Vertex, b: Vertex, c: Vertex) !void {
        try self.vertices.appendSlice(&.{ a, b, c });
    }

    // -----------------------------------------------------------------------
    // Line
    // -----------------------------------------------------------------------

    /// Draw a line from `a` to `b` as a filled quad (two triangles).
    pub fn addLine(self: *Tessellator, a: Vec2, b: Vec2, opts: DrawOptions) !void {
        const width = switch (opts.style) {
            .fill => 1.0,
            .stroke => |s| s.line_width,
        };
        try self.addLineSegment(a, b, width, opts);
    }

    fn addLineSegment(self: *Tessellator, a: Vec2, b: Vec2, width: f32, opts: DrawOptions) !void {
        const dir = Vec2.normalize(Vec2.sub(b, a));
        const perp = Vec2.scale(Vec2.perp(dir), width * 0.5);

        const v0 = Vec2.sub(a, perp);
        const v1 = Vec2.add(a, perp);
        const v2 = Vec2.sub(b, perp);
        const v3 = Vec2.add(b, perp);

        try self.addTri(makeVertex(v0, opts), makeVertex(v1, opts), makeVertex(v2, opts));
        try self.addTri(makeVertex(v1, opts), makeVertex(v3, opts), makeVertex(v2, opts));
    }

    // -----------------------------------------------------------------------
    // Path (polyline)
    // -----------------------------------------------------------------------

    /// Draw a path (sequence of connected line segments).
    pub fn addPath(self: *Tessellator, points: []const Vec2, closed: bool, opts: DrawOptions) !void {
        if (points.len < 2) return;

        const width = switch (opts.style) {
            .fill => 1.0,
            .stroke => |s| s.line_width,
        };

        var i: usize = 0;
        while (i + 1 < points.len) : (i += 1) {
            try self.addLineSegment(points[i], points[i + 1], width, opts);
        }
        if (closed and points.len >= 2) {
            try self.addLineSegment(points[points.len - 1], points[0], width, opts);
        }
    }

    // -----------------------------------------------------------------------
    // Bézier curves
    // -----------------------------------------------------------------------

    /// Flatten a quadratic Bézier curve into line segments using De Casteljau,
    /// then tessellate as a path.
    pub fn addQuadraticBezier(
        self: *Tessellator,
        p0: Vec2,
        p1: Vec2,
        p2: Vec2,
        opts: DrawOptions,
    ) !void {
        var pts = std.ArrayList(Vec2).init(self.allocator);
        defer pts.deinit();
        try pts.append(p0);
        try flattenQuadratic(&pts, p0, p1, p2, 0);
        try pts.append(p2);
        try self.addPath(pts.items, false, opts);
    }

    /// Flatten a cubic Bézier curve into line segments using De Casteljau,
    /// then tessellate as a path.
    pub fn addCubicBezier(
        self: *Tessellator,
        p0: Vec2,
        p1: Vec2,
        p2: Vec2,
        p3: Vec2,
        opts: DrawOptions,
    ) !void {
        var pts = std.ArrayList(Vec2).init(self.allocator);
        defer pts.deinit();
        try pts.append(p0);
        try flattenCubic(&pts, p0, p1, p2, p3, 0);
        try pts.append(p3);
        try self.addPath(pts.items, false, opts);
    }

    // -----------------------------------------------------------------------
    // Circle
    // -----------------------------------------------------------------------

    pub fn addCircle(self: *Tessellator, center: Vec2, radius: f32, opts: DrawOptions) !void {
        try self.addEllipse(center, radius, radius, opts);
    }

    // -----------------------------------------------------------------------
    // Circular arc
    // -----------------------------------------------------------------------

    pub fn addCircularArc(
        self: *Tessellator,
        center: Vec2,
        radius: f32,
        start_angle: f32,
        end_angle: f32,
        opts: DrawOptions,
    ) !void {
        try self.addEllipticalArc(center, radius, radius, start_angle, end_angle, opts);
    }

    // -----------------------------------------------------------------------
    // Oval (Ellipse)
    // -----------------------------------------------------------------------

    pub fn addEllipse(
        self: *Tessellator,
        center: Vec2,
        rx: f32,
        ry: f32,
        opts: DrawOptions,
    ) !void {
        try self.addEllipticalArc(center, rx, ry, 0.0, std.math.tau, opts);
    }

    // -----------------------------------------------------------------------
    // Oval arc (Elliptical arc)
    // -----------------------------------------------------------------------

    pub fn addEllipticalArc(
        self: *Tessellator,
        center: Vec2,
        rx: f32,
        ry: f32,
        start_angle: f32,
        end_angle: f32,
        opts: DrawOptions,
    ) !void {
        const segments = computeArcSegments(rx, ry, start_angle, end_angle);

        switch (opts.style) {
            .fill => try self.ellipticalArcFill(center, rx, ry, start_angle, end_angle, segments, opts),
            .stroke => |s| try self.ellipticalArcStroke(center, rx, ry, start_angle, end_angle, segments, s.line_width, opts),
        }
    }

    fn ellipticalArcFill(
        self: *Tessellator,
        center: Vec2,
        rx: f32,
        ry: f32,
        start_angle: f32,
        end_angle: f32,
        segments: usize,
        opts: DrawOptions,
    ) !void {
        const vc = makeVertex(center, opts);
        const step = (end_angle - start_angle) / @as(f32, @floatFromInt(segments));

        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const a0 = start_angle + @as(f32, @floatFromInt(i)) * step;
            const a1 = a0 + step;
            const p0 = Vec2{
                .x = center.x + rx * @cos(a0),
                .y = center.y + ry * @sin(a0),
            };
            const p1 = Vec2{
                .x = center.x + rx * @cos(a1),
                .y = center.y + ry * @sin(a1),
            };
            try self.addTri(vc, makeVertex(p0, opts), makeVertex(p1, opts));
        }
    }

    fn ellipticalArcStroke(
        self: *Tessellator,
        center: Vec2,
        rx: f32,
        ry: f32,
        start_angle: f32,
        end_angle: f32,
        segments: usize,
        line_width: f32,
        opts: DrawOptions,
    ) !void {
        const step = (end_angle - start_angle) / @as(f32, @floatFromInt(segments));
        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const a0 = start_angle + @as(f32, @floatFromInt(i)) * step;
            const a1 = a0 + step;
            const p0 = Vec2{
                .x = center.x + rx * @cos(a0),
                .y = center.y + ry * @sin(a0),
            };
            const p1 = Vec2{
                .x = center.x + rx * @cos(a1),
                .y = center.y + ry * @sin(a1),
            };
            try self.addLineSegment(p0, p1, line_width, opts);
        }
    }

    // -----------------------------------------------------------------------
    // Rectangle
    // -----------------------------------------------------------------------

    pub fn addRect(
        self: *Tessellator,
        rect: Rect,
        radii: CornerRadii,
        opts: DrawOptions,
    ) !void {
        const has_radius =
            radii.top_left > 0 or radii.top_right > 0 or
            radii.bottom_left > 0 or radii.bottom_right > 0;

        if (has_radius) {
            try self.addRoundedRect(rect, radii, opts);
        } else {
            try self.addPlainRect(rect, opts);
        }
    }

    fn addPlainRect(self: *Tessellator, rect: Rect, opts: DrawOptions) !void {
        const tl = Vec2{ .x = rect.x, .y = rect.y };
        const tr = Vec2{ .x = rect.x + rect.width, .y = rect.y };
        const bl = Vec2{ .x = rect.x, .y = rect.y + rect.height };
        const br = Vec2{ .x = rect.x + rect.width, .y = rect.y + rect.height };

        switch (opts.style) {
            .fill => {
                try self.addTri(makeVertex(tl, opts), makeVertex(tr, opts), makeVertex(bl, opts));
                try self.addTri(makeVertex(tr, opts), makeVertex(br, opts), makeVertex(bl, opts));
            },
            .stroke => |s| {
                const corners = [_]Vec2{ tl, tr, br, bl };
                try self.addPath(&corners, true, DrawOptions{
                    .style = .{ .stroke = s },
                    .paint = opts.paint,
                });
            },
        }
    }

    fn addRoundedRect(self: *Tessellator, rect: Rect, radii: CornerRadii, opts: DrawOptions) !void {
        // Clamp corner radii to half the smaller dimension
        const max_r = @min(rect.width, rect.height) * 0.5;
        const tl = @min(radii.top_left, max_r);
        const tr = @min(radii.top_right, max_r);
        const bl = @min(radii.bottom_left, max_r);
        const br_r = @min(radii.bottom_right, max_r);

        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.width;
        const y1 = rect.y + rect.height;

        // Corner arc centers
        const c_tl = Vec2{ .x = x0 + tl, .y = y0 + tl };
        const c_tr = Vec2{ .x = x1 - tr, .y = y0 + tr };
        const c_bl = Vec2{ .x = x0 + bl, .y = y1 - bl };
        const c_br = Vec2{ .x = x1 - br_r, .y = y1 - br_r };

        // Build outline as a polyline
        const corner_segs: usize = 8; // segments per corner
        var pts = std.ArrayList(Vec2).init(self.allocator);
        defer pts.deinit();

        const pi = std.math.pi;

        // Top-left corner: π to 3π/2 (i.e., 180° to 270°)
        if (tl > 0) try appendArcPts(&pts, c_tl, tl, pi, pi * 1.5, corner_segs) else try pts.append(.{ .x = x0, .y = y0 });
        // Top-right corner: -π/2 to 0 (i.e., 270° to 360°)
        if (tr > 0) try appendArcPts(&pts, c_tr, tr, -pi * 0.5, 0.0, corner_segs) else try pts.append(.{ .x = x1, .y = y0 });
        // Bottom-right corner: 0 to π/2
        if (br_r > 0) try appendArcPts(&pts, c_br, br_r, 0.0, pi * 0.5, corner_segs) else try pts.append(.{ .x = x1, .y = y1 });
        // Bottom-left corner: π/2 to π
        if (bl > 0) try appendArcPts(&pts, c_bl, bl, pi * 0.5, pi, corner_segs) else try pts.append(.{ .x = x0, .y = y1 });

        switch (opts.style) {
            .fill => {
                // Fan triangulation from center
                const cx = rect.x + rect.width * 0.5;
                const cy = rect.y + rect.height * 0.5;
                const center_v = makeVertex(.{ .x = cx, .y = cy }, opts);
                var i: usize = 0;
                while (i < pts.items.len) : (i += 1) {
                    const p0 = pts.items[i];
                    const p1 = pts.items[(i + 1) % pts.items.len];
                    try self.addTri(center_v, makeVertex(p0, opts), makeVertex(p1, opts));
                }
            },
            .stroke => |s| {
                try self.addPath(pts.items, true, DrawOptions{
                    .style = .{ .stroke = s },
                    .paint = opts.paint,
                });
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn computeArcSegments(rx: f32, ry: f32, start_angle: f32, end_angle: f32) usize {
    const r = @max(rx, ry);
    const arc_len = r * @abs(end_angle - start_angle);
    const segs = @max(8, @as(usize, @intFromFloat(arc_len / 2.0)));
    return @min(segs, 512);
}

fn appendArcPts(
    pts: *std.ArrayList(Vec2),
    center: Vec2,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    segments: usize,
) !void {
    const step = (end_angle - start_angle) / @as(f32, @floatFromInt(segments));
    var i: usize = 0;
    while (i <= segments) : (i += 1) {
        const angle = start_angle + @as(f32, @floatFromInt(i)) * step;
        try pts.append(.{
            .x = center.x + radius * @cos(angle),
            .y = center.y + radius * @sin(angle),
        });
    }
}

const max_bezier_depth: u32 = 8;

fn flattenQuadratic(pts: *std.ArrayList(Vec2), p0: Vec2, p1: Vec2, p2: Vec2, depth: u32) !void {
    // Check flatness
    const mx = (p0.x + 2.0 * p1.x + p2.x) * 0.25;
    const my = (p0.y + 2.0 * p1.y + p2.y) * 0.25;
    const mid = Vec2{ .x = (p0.x + p2.x) * 0.5, .y = (p0.y + p2.y) * 0.5 };
    const dx = mx - mid.x;
    const dy = my - mid.y;
    const flatness_sq = dx * dx + dy * dy;

    if (depth >= max_bezier_depth or flatness_sq < 0.25) {
        try pts.append(Vec2{ .x = (p0.x + p2.x) * 0.5, .y = (p0.y + p2.y) * 0.5 });
        return;
    }

    // De Casteljau split
    const m01 = Vec2{ .x = (p0.x + p1.x) * 0.5, .y = (p0.y + p1.y) * 0.5 };
    const m12 = Vec2{ .x = (p1.x + p2.x) * 0.5, .y = (p1.y + p2.y) * 0.5 };
    const m012 = Vec2{ .x = (m01.x + m12.x) * 0.5, .y = (m01.y + m12.y) * 0.5 };

    try flattenQuadratic(pts, p0, m01, m012, depth + 1);
    try pts.append(m012);
    try flattenQuadratic(pts, m012, m12, p2, depth + 1);
}

fn flattenCubic(
    pts: *std.ArrayList(Vec2),
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    depth: u32,
) !void {
    // Check flatness using control-point deviation from the chord
    const dx1 = p1.x - p0.x;
    const dy1 = p1.y - p0.y;
    const dx2 = p2.x - p3.x;
    const dy2 = p2.y - p3.y;
    const flatness_sq = (dx1 * dx1 + dy1 * dy1) + (dx2 * dx2 + dy2 * dy2);

    if (depth >= max_bezier_depth or flatness_sq < 0.5) {
        try pts.append(Vec2{ .x = (p0.x + p3.x) * 0.5, .y = (p0.y + p3.y) * 0.5 });
        return;
    }

    // De Casteljau split
    const m01 = Vec2{ .x = (p0.x + p1.x) * 0.5, .y = (p0.y + p1.y) * 0.5 };
    const m12 = Vec2{ .x = (p1.x + p2.x) * 0.5, .y = (p1.y + p2.y) * 0.5 };
    const m23 = Vec2{ .x = (p2.x + p3.x) * 0.5, .y = (p2.y + p3.y) * 0.5 };
    const m012 = Vec2{ .x = (m01.x + m12.x) * 0.5, .y = (m01.y + m12.y) * 0.5 };
    const m123 = Vec2{ .x = (m12.x + m23.x) * 0.5, .y = (m12.y + m23.y) * 0.5 };
    const m0123 = Vec2{ .x = (m012.x + m123.x) * 0.5, .y = (m012.y + m123.y) * 0.5 };

    try flattenCubic(pts, p0, m01, m012, m0123, depth + 1);
    try pts.append(m0123);
    try flattenCubic(pts, m0123, m123, m23, p3, depth + 1);
}
