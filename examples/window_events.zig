//! window_events.zig — Example: open a window, draw shapes, handle mouse/keyboard events.

const std = @import("std");
const flair = @import("flair-ui");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer flair.deinit();

    // -------------------------------------------------------------------
    // Create a window
    // -------------------------------------------------------------------
    var window = try flair.Window.init(allocator, 800, 600, "Flair Demo");
    defer window.deinit();

    var circle_x: f32 = 400.0;
    var circle_y: f32 = 300.0;
    var bg_color = flair.Color.white;

    std.debug.print("Window opened. Press Escape to quit.\n", .{});
    std.debug.print("Move the mouse to move the circle. Click to change background.\n", .{});

    // -------------------------------------------------------------------
    // Main loop
    // -------------------------------------------------------------------
    while (!window.shouldClose()) {
        // ----------------------------------------------------------------
        // Poll events
        // ----------------------------------------------------------------
        while (window.pollEvent()) |event| {
            switch (event) {
                .key_press => |ke| {
                    std.debug.print("Key pressed: {} (scancode {})\n", .{ ke.key, ke.scancode });
                    if (ke.key == .escape) {
                        return; // Exit on Escape
                    }
                },
                .key_release => |ke| {
                    std.debug.print("Key released: {}\n", .{ke.key});
                },
                .mouse_button_press => |mb| {
                    std.debug.print("Mouse button {} at ({d:.1}, {d:.1})\n", .{
                        mb.button, mb.x, mb.y,
                    });
                    // Change background color on click
                    bg_color = switch (mb.button) {
                        .left => flair.Color.light_gray,
                        .right => flair.Color.fromRgba8(220, 240, 255, 255),
                        else => flair.Color.white,
                    };
                },
                .mouse_button_release => |mb| {
                    std.debug.print("Mouse button {} released\n", .{mb.button});
                },
                .mouse_move => |mm| {
                    circle_x = mm.x;
                    circle_y = mm.y;
                },
                .mouse_scroll => |sc| {
                    std.debug.print("Scroll: dx={d:.2} dy={d:.2}\n", .{ sc.dx, sc.dy });
                },
                .mouse_enter => |mm| {
                    std.debug.print("Mouse entered at ({d:.1}, {d:.1})\n", .{ mm.x, mm.y });
                },
                .mouse_leave => {
                    std.debug.print("Mouse left\n", .{});
                },
                .resize => |r| {
                    std.debug.print("Resized to {}×{}\n", .{ r.width, r.height });
                },
                .close => {
                    std.debug.print("Close requested\n", .{});
                    return;
                },
            }
        }

        // ----------------------------------------------------------------
        // Draw frame
        // ----------------------------------------------------------------
        const surf = window.getSurface();
        surf.clear(bg_color);

        // Background grid
        var gx: f32 = 0;
        while (gx < @as(f32, @floatFromInt(surf.width))) : (gx += 80) {
            try surf.drawLine(
                .{ .x = gx, .y = 0 },
                .{ .x = gx, .y = @floatFromInt(surf.height) },
                .{
                    .style = .{ .stroke = .{ .line_width = 0.5 } },
                    .paint = .{ .solid = flair.Color.light_gray },
                },
            );
        }
        var gy: f32 = 0;
        while (gy < @as(f32, @floatFromInt(surf.height))) : (gy += 80) {
            try surf.drawLine(
                .{ .x = 0, .y = gy },
                .{ .x = @floatFromInt(surf.width), .y = gy },
                .{
                    .style = .{ .stroke = .{ .line_width = 0.5 } },
                    .paint = .{ .solid = flair.Color.light_gray },
                },
            );
        }

        // Filled circle that follows the mouse
        try surf.drawCircle(
            .{ .x = circle_x, .y = circle_y },
            40,
            .{
                .style = .fill,
                .paint = .{
                    .gradient = flair.Gradient.radial(
                        .{ .x = circle_x, .y = circle_y },
                        40,
                        &.{
                            .{ .position = 0.0, .color = flair.Color.white },
                            .{ .position = 0.5, .color = flair.Color.red },
                            .{ .position = 1.0, .color = flair.Color.fromRgba8(150, 0, 0, 255) },
                        },
                    ),
                },
            },
        );

        // Stroked circle (ring around the mouse)
        try surf.drawCircle(
            .{ .x = circle_x, .y = circle_y },
            45,
            .{
                .style = .{ .stroke = .{ .line_width = 2.0 } },
                .paint = .{ .solid = flair.Color.black },
            },
        );

        // Rounded rectangle in the corner
        try surf.drawRect(
            .{ .x = 20, .y = 20, .width = 180, .height = 60 },
            flair.CornerRadii.uniform(12),
            .{
                .style = .fill,
                .paint = .{ .solid = flair.Color.fromRgba8(0, 0, 0, 128) },
            },
        );

        // "Flair Demo" label as a bezier path
        try surf.drawCubicBezier(
            .{ .x = 30, .y = 55 },
            .{ .x = 80, .y = 35 },
            .{ .x = 130, .y = 75 },
            .{ .x = 190, .y = 55 },
            .{
                .style = .{ .stroke = .{ .line_width = 2.0 } },
                .paint = .{ .solid = flair.Color.white },
            },
        );

        // Present the frame
        try window.present();
    }
}
