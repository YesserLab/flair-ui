//! basic_shapes.zig — Example: draw all shape types to a surface and save as PNG.

const std = @import("std");
const flair = @import("flair-ui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer flair.deinit();

    // -------------------------------------------------------------------
    // Create an 800×600 offscreen surface
    // -------------------------------------------------------------------
    var surface = try flair.Surface.init(allocator, 800, 600);
    defer surface.deinit();

    // Clear to white
    surface.clear(flair.Color.white);

    // -------------------------------------------------------------------
    // Line
    // -------------------------------------------------------------------
    try surface.drawLine(
        .{ .x = 50, .y = 50 },
        .{ .x = 200, .y = 50 },
        .{
            .style = .{ .stroke = .{ .line_width = 3.0 } },
            .paint = .{ .solid = flair.Color.black },
        },
    );

    // -------------------------------------------------------------------
    // Path (open polyline)
    // -------------------------------------------------------------------
    const path_pts = [_]flair.Vec2{
        .{ .x = 50, .y = 100 },
        .{ .x = 100, .y = 80 },
        .{ .x = 150, .y = 120 },
        .{ .x = 200, .y = 90 },
        .{ .x = 250, .y = 110 },
    };
    try surface.drawPath(&path_pts, false, .{
        .style = .{ .stroke = .{ .line_width = 2.0 } },
        .paint = .{ .solid = flair.Color.blue },
    });

    // -------------------------------------------------------------------
    // Quadratic Bézier
    // -------------------------------------------------------------------
    try surface.drawQuadraticBezier(
        .{ .x = 50, .y = 200 },
        .{ .x = 150, .y = 140 },
        .{ .x = 250, .y = 200 },
        .{
            .style = .{ .stroke = .{ .line_width = 2.0 } },
            .paint = .{ .solid = flair.Color.green },
        },
    );

    // -------------------------------------------------------------------
    // Cubic Bézier
    // -------------------------------------------------------------------
    try surface.drawCubicBezier(
        .{ .x = 50, .y = 260 },
        .{ .x = 100, .y = 220 },
        .{ .x = 200, .y = 300 },
        .{ .x = 250, .y = 260 },
        .{
            .style = .{ .stroke = .{ .line_width = 2.5 } },
            .paint = .{ .solid = flair.Color.purple },
        },
    );

    // -------------------------------------------------------------------
    // Filled circle
    // -------------------------------------------------------------------
    try surface.drawCircle(
        .{ .x = 350, .y = 100 },
        60,
        .{
            .style = .fill,
            .paint = .{ .solid = flair.Color.red },
        },
    );

    // -------------------------------------------------------------------
    // Stroked circle
    // -------------------------------------------------------------------
    try surface.drawCircle(
        .{ .x = 500, .y = 100 },
        60,
        .{
            .style = .{ .stroke = .{ .line_width = 4.0 } },
            .paint = .{ .solid = flair.Color.orange },
        },
    );

    // -------------------------------------------------------------------
    // Circular arc
    // -------------------------------------------------------------------
    try surface.drawCircularArc(
        .{ .x = 350, .y = 250 },
        50,
        0.0,
        std.math.pi,
        .{
            .style = .{ .stroke = .{ .line_width = 3.0 } },
            .paint = .{ .solid = flair.Color.cyan },
        },
    );

    // -------------------------------------------------------------------
    // Oval (ellipse)
    // -------------------------------------------------------------------
    try surface.drawOval(
        .{ .x = 500, .y = 250 },
        80,
        40,
        .{
            .style = .fill,
            .paint = .{
                .gradient = flair.Gradient.linear(
                    .{ .x = 420, .y = 250 },
                    .{ .x = 580, .y = 250 },
                    &.{
                        .{ .position = 0.0, .color = flair.Color.blue },
                        .{ .position = 1.0, .color = flair.Color.cyan },
                    },
                ),
            },
        },
    );

    // -------------------------------------------------------------------
    // Oval arc
    // -------------------------------------------------------------------
    try surface.drawOvalArc(
        .{ .x = 350, .y = 380 },
        70,
        35,
        std.math.pi * 0.25,
        std.math.pi * 1.75,
        .{
            .style = .{ .stroke = .{ .line_width = 2.0 } },
            .paint = .{ .solid = flair.Color.magenta },
        },
    );

    // -------------------------------------------------------------------
    // Plain rectangle
    // -------------------------------------------------------------------
    try surface.drawRect(
        .{ .x = 50, .y = 320, .width = 200, .height = 100 },
        flair.CornerRadii.zero,
        .{
            .style = .fill,
            .paint = .{ .solid = flair.Color.yellow },
        },
    );

    // -------------------------------------------------------------------
    // Rounded rectangle with independent corner radii
    // -------------------------------------------------------------------
    try surface.drawRect(
        .{ .x = 50, .y = 450, .width = 200, .height = 120 },
        .{ .top_left = 20, .top_right = 5, .bottom_left = 5, .bottom_right = 20 },
        .{
            .style = .{ .stroke = .{ .line_width = 3.0 } },
            .paint = .{
                .gradient = flair.Gradient.radial(
                    .{ .x = 150, .y = 510 },
                    100,
                    &.{
                        .{ .position = 0.0, .color = flair.Color.white },
                        .{ .position = 1.0, .color = flair.Color.blue },
                    },
                ),
            },
        },
    );

    // -------------------------------------------------------------------
    // Pill-shaped rectangle (fully rounded)
    // -------------------------------------------------------------------
    try surface.drawRect(
        .{ .x = 500, .y = 340, .width = 200, .height = 60 },
        flair.CornerRadii.uniform(30),
        .{
            .style = .fill,
            .paint = .{ .solid = flair.Color.fromRgba8(100, 200, 100, 255) },
        },
    );

    // -------------------------------------------------------------------
    // Save to PNG
    // -------------------------------------------------------------------
    const output_path = "basic_shapes.png";
    try surface.savePng(output_path);
    std.debug.print("Saved to {s}\n", .{output_path});
}
