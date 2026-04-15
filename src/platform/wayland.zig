//! Wayland platform backend for flair-ui windows.
//!
//! Uses libwayland-client and xdg-shell to create a Wayland surface,
//! then creates a VkSurfaceKHR from it for Vulkan presentation.
//!
//! Input is handled via wl_seat → wl_keyboard + wl_pointer.

const std = @import("std");
const input = @import("../input.zig");
const Event = input.Event;
const Key = input.Key;
const Modifiers = input.Modifiers;
const MouseButton = input.MouseButton;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const WindowVTable = window_mod.WindowVTable;
const surface_mod = @import("../surface.zig");
const Surface = surface_mod.Surface;
const color_mod = @import("../color.zig");
const vk_mod = @import("../vulkan.zig");
const vk = vk_mod.vk;
const c_vk = vk_mod.c;
const renderer_mod = @import("../renderer.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
});

// Maximum events buffered between polls
const MAX_EVENTS = 256;
// Maximum swapchain images
const MAX_SWAPCHAIN_IMAGES = 8;

// ---------------------------------------------------------------------------
// WaylandWindow
// ---------------------------------------------------------------------------

pub const WaylandWindow = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    should_close: bool = false,

    // Wayland core objects
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    wl_surface: ?*c.wl_surface = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,

    // Input state
    events: [MAX_EVENTS]Event = undefined,
    event_head: usize = 0,
    event_tail: usize = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mods: Modifiers = .{},

    // Vulkan surface and swapchain
    vk_surface: c_vk.VkSurfaceKHR = null,
    swapchain: c_vk.VkSwapchainKHR = null,
    swapchain_images: [MAX_SWAPCHAIN_IMAGES]c_vk.VkImage = [_]c_vk.VkImage{null} ** MAX_SWAPCHAIN_IMAGES,
    swapchain_image_count: u32 = 0,
    swapchain_format: c_vk.VkFormat = c_vk.VK_FORMAT_B8G8R8A8_UNORM,

    // Per-frame sync objects
    image_available: c_vk.VkSemaphore = null,
    render_finished: c_vk.VkSemaphore = null,
    in_flight: c_vk.VkFence = null,

    // Command buffer for window rendering
    cmd: c_vk.VkCommandBuffer = null,

    // Title (owned)
    title: [:0]u8 = undefined,

    renderer: *renderer_mod.Renderer = undefined,

    // ---------------------------------------------------------------------------
    // VTable
    // ---------------------------------------------------------------------------

    const vtable = WindowVTable{
        .deinit = vtDeinit,
        .pollEvent = vtPollEvent,
        .shouldClose = vtShouldClose,
        .presentSurface = vtPresentSurface,
        .getWidth = vtGetWidth,
        .getHeight = vtGetHeight,
        .setTitle = vtSetTitle,
    };

    fn vtDeinit(impl: *anyopaque) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        if (self.renderer.device != null) _ = vk.DeviceWaitIdle.?(self.renderer.device);
        self.destroySwapchain();
        if (self.in_flight != null) vk.DestroyFence.?(self.renderer.device, self.in_flight, null);
        if (self.render_finished != null) vk.DestroySemaphore.?(self.renderer.device, self.render_finished, null);
        if (self.image_available != null) vk.DestroySemaphore.?(self.renderer.device, self.image_available, null);
        if (self.vk_surface != null) vk.DestroySurfaceKHR.?(self.renderer.instance, self.vk_surface, null);
        if (self.pointer != null) _ = c.wl_pointer_destroy(self.pointer);
        if (self.keyboard != null) _ = c.wl_keyboard_destroy(self.keyboard);
        if (self.xdg_toplevel != null) c.xdg_toplevel_destroy(self.xdg_toplevel);
        if (self.xdg_surface != null) c.xdg_surface_destroy(self.xdg_surface);
        if (self.wl_surface != null) c.wl_surface_destroy(self.wl_surface);
        if (self.xdg_wm_base != null) c.xdg_wm_base_destroy(self.xdg_wm_base);
        if (self.compositor != null) c.wl_compositor_destroy(self.compositor);
        if (self.seat != null) c.wl_seat_destroy(self.seat);
        if (self.display != null) _ = c.wl_display_disconnect(self.display);
        self.allocator.free(self.title);
        self.allocator.destroy(self);
    }

    fn vtPollEvent(impl: *anyopaque) ?Event {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        // Dispatch pending Wayland events (non-blocking)
        _ = c.wl_display_dispatch_pending(self.display);
        _ = c.wl_display_flush(self.display);
        return self.dequeueEvent();
    }

    fn vtShouldClose(impl: *anyopaque) bool {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        return self.should_close;
    }

    fn vtPresentSurface(impl: *anyopaque, surf_image: usize, sw: u32, sh: u32) anyerror!void {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        return self.presentFrame(@ptrFromInt(surf_image), sw, sh);
    }

    fn vtGetWidth(impl: *anyopaque) u32 {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        return self.width;
    }

    fn vtGetHeight(impl: *anyopaque) u32 {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        return self.height;
    }

    fn vtSetTitle(impl: *anyopaque, title: []const u8) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(impl));
        if (self.xdg_toplevel != null) {
            const z_title = self.allocator.dupeZ(u8, title) catch return;
            defer self.allocator.free(z_title);
            c.xdg_toplevel_set_title(self.xdg_toplevel, z_title.ptr);
            _ = c.wl_display_flush(self.display);
        }
    }

    // ---------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------

    pub fn initWindow(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        title: []const u8,
    ) !Window {
        const self = try allocator.create(WaylandWindow);
        errdefer allocator.destroy(self);

        self.* = WaylandWindow{
            .allocator = allocator,
            .width = width,
            .height = height,
            .title = try allocator.dupeZ(u8, title),
        };

        // Connect to Wayland display and create the wl_surface
        try self.connectDisplay();

        // Acquire/init the Vulkan renderer (creates instance, device, etc.)
        self.renderer = try renderer_mod.acquire(allocator);

        // Create the Vulkan surface from the Wayland surface
        try self.createVkSurface();

        try self.createSwapchain();
        try self.createSyncObjects();
        try self.allocateCommandBuffer();

        // Create the offscreen surface used for drawing
        const surf = try Surface.init(allocator, width, height);

        return Window{
            .impl = self,
            .vtable = &vtable,
            .surface = surf,
        };
    }

    // ---------------------------------------------------------------------------
    // Wayland connection
    // ---------------------------------------------------------------------------

    fn connectDisplay(self: *WaylandWindow) !void {
        self.display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;

        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandRegistryFailed;

        const registry_listener = c.wl_registry_listener{
            .global = registryGlobal,
            .global_remove = registryGlobalRemove,
        };
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(self.display);

        if (self.compositor == null) return error.NoWaylandCompositor;
        if (self.xdg_wm_base == null) return error.NoXdgWmBase;

        // Create surface
        self.wl_surface = c.wl_compositor_create_surface(self.compositor) orelse return error.NoWlSurface;

        // Set up xdg_wm_base ping/pong
        const wm_base_listener = c.xdg_wm_base_listener{
            .ping = xdgWmBasePing,
        };
        _ = c.xdg_wm_base_add_listener(self.xdg_wm_base, &wm_base_listener, self);

        // Create xdg_surface and xdg_toplevel
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.xdg_wm_base, self.wl_surface) orelse
            return error.NoXdgSurface;

        const xdg_surface_listener = c.xdg_surface_listener{
            .configure = xdgSurfaceConfigure,
        };
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);

        self.xdg_toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse
            return error.NoXdgToplevel;

        const xdg_toplevel_listener = c.xdg_toplevel_listener{
            .configure = xdgToplevelConfigure,
            .close = xdgToplevelClose,
        };
        _ = c.xdg_toplevel_add_listener(self.xdg_toplevel, &xdg_toplevel_listener, self);

        c.xdg_toplevel_set_title(self.xdg_toplevel, self.title.ptr);
        c.wl_surface_commit(self.wl_surface);
        _ = c.wl_display_roundtrip(self.display);
    }

    // ---------------------------------------------------------------------------
    // Vulkan surface creation (VkSurfaceKHR from wl_surface)
    // ---------------------------------------------------------------------------

    fn createVkSurface(self: *WaylandWindow) !void {
        const create_info = c_vk.VkWaylandSurfaceCreateInfoKHR{
            .sType = c_vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .display = self.display,
            .surface = self.wl_surface,
        };
        try vk_mod.check(vk.CreateWaylandSurfaceKHR.?(
            self.renderer.instance,
            &create_info,
            null,
            &self.vk_surface,
        ));
    }

    // ---------------------------------------------------------------------------
    // Swapchain
    // ---------------------------------------------------------------------------

    fn createSwapchain(self: *WaylandWindow) !void {
        const dev = self.renderer.device;
        const phys = self.renderer.physical_device;

        // Query surface capabilities
        var caps: c_vk.VkSurfaceCapabilitiesKHR = undefined;
        try vk_mod.check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR.?(phys, self.vk_surface, &caps));

        // Select format
        var format_count: u32 = 0;
        try vk_mod.check(vk.GetPhysicalDeviceSurfaceFormatsKHR.?(phys, self.vk_surface, &format_count, null));
        const formats = try self.allocator.alloc(c_vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try vk_mod.check(vk.GetPhysicalDeviceSurfaceFormatsKHR.?(phys, self.vk_surface, &format_count, formats.ptr));

        // Prefer BGRA8 SRGB
        var chosen_format = formats[0];
        for (formats) |fmt| {
            if (fmt.format == c_vk.VK_FORMAT_B8G8R8A8_SRGB and
                fmt.colorSpace == c_vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                chosen_format = fmt;
                break;
            }
        }
        self.swapchain_format = chosen_format.format;

        // Extent
        var extent = caps.currentExtent;
        if (extent.width == 0xFFFFFFFF) {
            extent.width = self.width;
            extent.height = self.height;
        }
        self.width = extent.width;
        self.height = extent.height;

        var image_count: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
            image_count = caps.maxImageCount;
        }
        if (image_count > MAX_SWAPCHAIN_IMAGES) image_count = MAX_SWAPCHAIN_IMAGES;

        const sc_info = c_vk.VkSwapchainCreateInfoKHR{
            .sType = c_vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.vk_surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c_vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c_vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = c_vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c_vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = c_vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c_vk.VK_TRUE,
            .oldSwapchain = null,
        };
        try vk_mod.check(vk.CreateSwapchainKHR.?(dev, &sc_info, null, &self.swapchain));

        // Get swapchain images (no views/framebuffers needed for the blit approach)
        var actual_count: u32 = 0;
        try vk_mod.check(vk.GetSwapchainImagesKHR.?(dev, self.swapchain, &actual_count, null));
        if (actual_count > MAX_SWAPCHAIN_IMAGES) actual_count = MAX_SWAPCHAIN_IMAGES;
        self.swapchain_image_count = actual_count;
        try vk_mod.check(vk.GetSwapchainImagesKHR.?(dev, self.swapchain, &actual_count, &self.swapchain_images[0]));
    }

    fn destroySwapchain(self: *WaylandWindow) void {
        if (self.swapchain != null) vk.DestroySwapchainKHR.?(self.renderer.device, self.swapchain, null);
        self.swapchain = null;
        self.swapchain_image_count = 0;
    }

    // ---------------------------------------------------------------------------
    // Sync objects
    // ---------------------------------------------------------------------------

    fn createSyncObjects(self: *WaylandWindow) !void {
        const dev = self.renderer.device;
        const sem_info = c_vk.VkSemaphoreCreateInfo{
            .sType = c_vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        try vk_mod.check(vk.CreateSemaphore.?(dev, &sem_info, null, &self.image_available));
        try vk_mod.check(vk.CreateSemaphore.?(dev, &sem_info, null, &self.render_finished));

        const fence_info = c_vk.VkFenceCreateInfo{
            .sType = c_vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c_vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try vk_mod.check(vk.CreateFence.?(dev, &fence_info, null, &self.in_flight));
    }

    fn allocateCommandBuffer(self: *WaylandWindow) !void {
        const alloc_info = c_vk.VkCommandBufferAllocateInfo{
            .sType = c_vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.renderer.command_pool,
            .level = c_vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try vk_mod.check(vk.AllocateCommandBuffers.?(
            self.renderer.device,
            &alloc_info,
            &self.cmd,
        ));
    }

    // ---------------------------------------------------------------------------
    // Present frame
    // ---------------------------------------------------------------------------

    fn presentFrame(self: *WaylandWindow, src_image: c_vk.VkImage, src_width: u32, src_height: u32) !void {
        const dev = self.renderer.device;

        // Wait for previous frame
        try vk_mod.check(vk.WaitForFences.?(dev, 1, &self.in_flight, c_vk.VK_TRUE, std.math.maxInt(u64)));
        try vk_mod.check(vk.ResetFences.?(dev, 1, &self.in_flight));

        // Acquire next image
        var image_index: u32 = 0;
        const acquire_result = vk.AcquireNextImageKHR.?(
            dev,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            null,
            &image_index,
        );
        if (acquire_result == c_vk.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        }
        try vk_mod.check(acquire_result);

        // Flush the surface draw calls to the offscreen image, then blit to swapchain
        try self.blitSurfaceToSwapchain(src_image, src_width, src_height, image_index);

        // Present
        const wait_stages = [_]c_vk.VkPipelineStageFlags{c_vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = c_vk.VkSubmitInfo{
            .sType = c_vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stages[0],
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished,
        };
        try vk_mod.check(vk.QueueSubmit.?(self.renderer.graphics_queue, 1, &submit_info, self.in_flight));

        const present_info = c_vk.VkPresentInfoKHR{
            .sType = c_vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const present_result = vk.QueuePresentKHR.?(self.renderer.graphics_queue, &present_info);
        if (present_result == c_vk.VK_ERROR_OUT_OF_DATE_KHR or present_result == c_vk.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain();
        } else {
            try vk_mod.check(present_result);
        }

        // Dispatch Wayland events
        _ = c.wl_display_dispatch_pending(self.display);
        _ = c.wl_display_flush(self.display);
    }

    fn blitSurfaceToSwapchain(
        self: *WaylandWindow,
        src_image: c_vk.VkImage,
        src_width: u32,
        src_height: u32,
        image_index: u32,
    ) !void {
        try vk_mod.check(vk.ResetCommandBuffer.?(self.cmd, 0));

        const begin_info = c_vk.VkCommandBufferBeginInfo{
            .sType = c_vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c_vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk_mod.check(vk.BeginCommandBuffer.?(self.cmd, &begin_info));

        // Transition swapchain image to TRANSFER_DST_OPTIMAL
        const barrier_to_dst = c_vk.VkImageMemoryBarrier{
            .sType = c_vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = c_vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = c_vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c_vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = c_vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c_vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swapchain_images[image_index],
            .subresourceRange = .{
                .aspectMask = c_vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.CmdPipelineBarrier.?(
            self.cmd,
            c_vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c_vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, null, 0, null, 1, &barrier_to_dst,
        );

        // Blit offscreen surface image to swapchain image
        const src_offsets = [2]c_vk.VkOffset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = @intCast(src_width), .y = @intCast(src_height), .z = 1 },
        };
        const dst_offsets = [2]c_vk.VkOffset3D{
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = @intCast(self.width), .y = @intCast(self.height), .z = 1 },
        };
        const blit_region = c_vk.VkImageBlit{
            .srcSubresource = .{
                .aspectMask = c_vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcOffsets = src_offsets,
            .dstSubresource = .{
                .aspectMask = c_vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .dstOffsets = dst_offsets,
        };
        vk.CmdBlitImage.?(
            self.cmd,
            src_image,
            c_vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.swapchain_images[image_index],
            c_vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &blit_region,
            c_vk.VK_FILTER_LINEAR,
        );

        // Transition swapchain image to PRESENT_SRC_KHR
        const barrier_to_present = c_vk.VkImageMemoryBarrier{
            .sType = c_vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c_vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = c_vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = c_vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = c_vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c_vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swapchain_images[image_index],
            .subresourceRange = .{
                .aspectMask = c_vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.CmdPipelineBarrier.?(
            self.cmd,
            c_vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c_vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0, 0, null, 0, null, 1, &barrier_to_present,
        );

        try vk_mod.check(vk.EndCommandBuffer.?(self.cmd));
    }
    fn recreateSwapchain(self: *WaylandWindow) !void {
        _ = vk.DeviceWaitIdle.?(self.renderer.device);
        self.destroySwapchain();
        try self.createSwapchain();
    }

    // ---------------------------------------------------------------------------
    // Event queue
    // ---------------------------------------------------------------------------

    fn enqueueEvent(self: *WaylandWindow, event: Event) void {
        const next = (self.event_tail + 1) % MAX_EVENTS;
        if (next == self.event_head) return; // queue full, drop event
        self.events[self.event_tail] = event;
        self.event_tail = next;
    }

    fn dequeueEvent(self: *WaylandWindow) ?Event {
        if (self.event_head == self.event_tail) return null;
        const ev = self.events[self.event_head];
        self.event_head = (self.event_head + 1) % MAX_EVENTS;
        return ev;
    }

    // ---------------------------------------------------------------------------
    // Wayland registry callbacks
    // ---------------------------------------------------------------------------

    fn registryGlobal(
        data: ?*anyopaque,
        registry: ?*c.wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        const iface = std.mem.sliceTo(interface, 0);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_compositor_interface,
                @min(version, 4),
            ));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.xdg_wm_base = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.xdg_wm_base_interface,
                @min(version, 2),
            ));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_seat_interface,
                @min(version, 4),
            ));
            const seat_listener = c.wl_seat_listener{
                .capabilities = seatCapabilities,
                .name = seatName,
            };
            _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
        }
    }

    fn registryGlobalRemove(
        _: ?*anyopaque,
        _: ?*c.wl_registry,
        _: u32,
    ) callconv(.C) void {}

    // ---------------------------------------------------------------------------
    // xdg_wm_base ping
    // ---------------------------------------------------------------------------

    fn xdgWmBasePing(
        _: ?*anyopaque,
        wm_base: ?*c.xdg_wm_base,
        serial: u32,
    ) callconv(.C) void {
        c.xdg_wm_base_pong(wm_base, serial);
    }

    // ---------------------------------------------------------------------------
    // xdg_surface configure
    // ---------------------------------------------------------------------------

    fn xdgSurfaceConfigure(
        _: ?*anyopaque,
        xdg_surface: ?*c.xdg_surface,
        serial: u32,
    ) callconv(.C) void {
        c.xdg_surface_ack_configure(xdg_surface, serial);
    }

    // ---------------------------------------------------------------------------
    // xdg_toplevel configure / close
    // ---------------------------------------------------------------------------

    fn xdgToplevelConfigure(
        data: ?*anyopaque,
        _: ?*c.xdg_toplevel,
        new_width: i32,
        new_height: i32,
        _: ?*c.wl_array,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        if (new_width > 0 and new_height > 0) {
            self.width = @intCast(new_width);
            self.height = @intCast(new_height);
            self.enqueueEvent(.{ .resize = .{
                .width = self.width,
                .height = self.height,
            } });
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        self.should_close = true;
        self.enqueueEvent(.close);
    }

    // ---------------------------------------------------------------------------
    // wl_seat
    // ---------------------------------------------------------------------------

    fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));

        if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            const listener = c.wl_keyboard_listener{
                .keymap = keyboardKeymap,
                .enter = keyboardEnter,
                .leave = keyboardLeave,
                .key = keyboardKey,
                .modifiers = keyboardModifiers,
                .repeat_info = keyboardRepeatInfo,
            };
            _ = c.wl_keyboard_add_listener(self.keyboard, &listener, self);
        }

        if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            const listener = c.wl_pointer_listener{
                .enter = pointerEnter,
                .leave = pointerLeave,
                .motion = pointerMotion,
                .button = pointerButton,
                .axis = pointerAxis,
                .frame = pointerFrame,
                .axis_source = pointerAxisSource,
                .axis_stop = pointerAxisStop,
                .axis_discrete = pointerAxisDiscrete,
            };
            _ = c.wl_pointer_add_listener(self.pointer, &listener, self);
        }
    }

    fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.C) void {}

    // ---------------------------------------------------------------------------
    // Keyboard listeners
    // ---------------------------------------------------------------------------

    fn keyboardKeymap(
        _: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: u32,
        _: i32,
        _: u32,
    ) callconv(.C) void {}

    fn keyboardEnter(
        _: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: u32,
        _: ?*c.wl_surface,
        _: ?*c.wl_array,
    ) callconv(.C) void {}

    fn keyboardLeave(
        _: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: u32,
        _: ?*c.wl_surface,
    ) callconv(.C) void {}

    fn keyboardKey(
        data: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: u32,
        _: u32,
        scancode: u32,
        state: u32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        const key = input.keyFromLinux(scancode);
        const ev_key = input.KeyEvent{
            .key = key,
            .scancode = scancode,
            .mods = self.mods,
        };
        if (state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
            self.enqueueEvent(.{ .key_press = ev_key });
        } else {
            self.enqueueEvent(.{ .key_release = ev_key });
        }
    }

    fn keyboardModifiers(
        data: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: u32,
        mods_depressed: u32,
        _: u32,
        _: u32,
        _: u32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        // xkb modifier indices: Shift=1, Ctrl=4, Alt=8, Super=64
        self.mods = .{
            .shift = (mods_depressed & 0x01) != 0,
            .ctrl = (mods_depressed & 0x04) != 0,
            .alt = (mods_depressed & 0x08) != 0,
            .super = (mods_depressed & 0x40) != 0,
        };
    }

    fn keyboardRepeatInfo(
        _: ?*anyopaque,
        _: ?*c.wl_keyboard,
        _: i32,
        _: i32,
    ) callconv(.C) void {}

    // ---------------------------------------------------------------------------
    // Pointer listeners
    // ---------------------------------------------------------------------------

    fn pointerEnter(
        data: ?*anyopaque,
        _: ?*c.wl_pointer,
        _: u32,
        _: ?*c.wl_surface,
        x_fixed: i32,
        y_fixed: i32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        self.mouse_x = @as(f32, @floatFromInt(x_fixed)) / 256.0;
        self.mouse_y = @as(f32, @floatFromInt(y_fixed)) / 256.0;
        self.enqueueEvent(.{ .mouse_enter = .{ .x = self.mouse_x, .y = self.mouse_y } });
    }

    fn pointerLeave(
        data: ?*anyopaque,
        _: ?*c.wl_pointer,
        _: u32,
        _: ?*c.wl_surface,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        self.enqueueEvent(.{ .mouse_leave = .{ .x = self.mouse_x, .y = self.mouse_y } });
    }

    fn pointerMotion(
        data: ?*anyopaque,
        _: ?*c.wl_pointer,
        _: u32,
        x_fixed: i32,
        y_fixed: i32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        // Wayland uses wl_fixed_t: 1 unit = 1/256 pixel
        self.mouse_x = @as(f32, @floatFromInt(x_fixed)) / 256.0;
        self.mouse_y = @as(f32, @floatFromInt(y_fixed)) / 256.0;
        self.enqueueEvent(.{ .mouse_move = .{ .x = self.mouse_x, .y = self.mouse_y } });
    }

    fn pointerButton(
        data: ?*anyopaque,
        _: ?*c.wl_pointer,
        _: u32,
        _: u32,
        linux_button: u32,
        state: u32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        // Linux button codes: BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112
        const btn: MouseButton = switch (linux_button) {
            0x110 => .left,
            0x111 => .right,
            0x112 => .middle,
            0x113 => .button4,
            0x114 => .button5,
            else => return,
        };
        const ev = input.MouseButtonEvent{
            .button = btn,
            .x = self.mouse_x,
            .y = self.mouse_y,
            .mods = self.mods,
        };
        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            self.enqueueEvent(.{ .mouse_button_press = ev });
        } else {
            self.enqueueEvent(.{ .mouse_button_release = ev });
        }
    }

    fn pointerAxis(
        data: ?*anyopaque,
        _: ?*c.wl_pointer,
        _: u32,
        axis: u32,
        value_fixed: i32,
    ) callconv(.C) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
        const val = @as(f32, @floatFromInt(value_fixed)) / 256.0;
        const scroll = switch (axis) {
            c.WL_POINTER_AXIS_VERTICAL_SCROLL => input.ScrollEvent{ .dx = 0, .dy = val },
            c.WL_POINTER_AXIS_HORIZONTAL_SCROLL => input.ScrollEvent{ .dx = val, .dy = 0 },
            else => return,
        };
        self.enqueueEvent(.{ .mouse_scroll = scroll });
    }

    fn pointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.C) void {}
    fn pointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.C) void {}
    fn pointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.C) void {}
    fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.C) void {}
};
