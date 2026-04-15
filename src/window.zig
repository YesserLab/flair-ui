//! Platform-agnostic Window interface.
//!
//! The Window type uses a vtable pattern to allow different platform backends
//! (Wayland, macOS/Cocoa, Win32) to implement the same interface.
//!
//! Currently only the Wayland backend is implemented.

const std = @import("std");
const input = @import("input.zig");
const Event = input.Event;
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const color_mod = @import("color.zig");

// ---------------------------------------------------------------------------
// Window vtable — platform backends implement these function pointers
// ---------------------------------------------------------------------------

pub const WindowVTable = struct {
    deinit: *const fn (self: *anyopaque) void,
    pollEvent: *const fn (self: *anyopaque) ?Event,
    shouldClose: *const fn (self: *anyopaque) bool,
    /// present is called after the surface has been flushed.
    /// `surf_image` is the VkImage handle of the surface's offscreen image (as usize).
    presentSurface: *const fn (self: *anyopaque, surf_image: usize, sw: u32, sh: u32) anyerror!void,
    getWidth: *const fn (self: *anyopaque) u32,
    getHeight: *const fn (self: *anyopaque) u32,
    setTitle: *const fn (self: *anyopaque, title: []const u8) void,
};

// ---------------------------------------------------------------------------
// Window — the public-facing type
// ---------------------------------------------------------------------------

pub const Window = struct {
    impl: *anyopaque,
    vtable: *const WindowVTable,
    /// The surface associated with this window. Created when the window is initialized.
    surface: Surface,

    /// Create a new window with the specified size and title.
    /// Uses the Wayland backend on Linux.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, title: []const u8) !Window {
        // Platform selection: on Linux we always use Wayland for now.
        // Future: detect platform and dispatch to the right backend.
        const wayland = @import("platform/wayland.zig");
        return wayland.WaylandWindow.initWindow(allocator, width, height, title);
    }

    pub fn deinit(self: *Window) void {
        self.surface.deinit();
        self.vtable.deinit(self.impl);
    }

    /// Poll for the next pending event. Returns `null` when no more events.
    pub fn pollEvent(self: *Window) ?Event {
        return self.vtable.pollEvent(self.impl);
    }

    /// Returns `true` if the window has been requested to close.
    pub fn shouldClose(self: *Window) bool {
        return self.vtable.shouldClose(self.impl);
    }

    /// Present the window's surface to the screen.
    /// Calls `surface.flush()` then blits/presents to the screen.
    pub fn present(self: *Window) !void {
        try self.surface.flush();
        const img_handle: usize = @intFromPtr(self.surface.image);
        return self.vtable.presentSurface(
            self.impl,
            img_handle,
            self.surface.width,
            self.surface.height,
        );
    }

    /// Get the window's current width.
    pub fn getWidth(self: *Window) u32 {
        return self.vtable.getWidth(self.impl);
    }

    /// Get the window's current height.
    pub fn getHeight(self: *Window) u32 {
        return self.vtable.getHeight(self.impl);
    }

    /// Set the window title.
    pub fn setTitle(self: *Window, title: []const u8) void {
        self.vtable.setTitle(self.impl, title);
    }

    /// Access the window's drawing surface.
    pub fn getSurface(self: *Window) *Surface {
        return &self.surface;
    }
};
