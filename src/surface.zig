//! Surface — the central drawing primitive.
//!
//! A Surface is an offscreen Vulkan render target backed by a VkImage.
//! All drawing operations target a Surface, which can then be:
//!   - Saved to disk as a PNG image (`savePng`).
//!   - Presented to a window via a Window (see window.zig).

const std = @import("std");
const vk_mod = @import("vulkan.zig");
const vk = vk_mod.vk;
const c = vk_mod.c;
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const shapes = @import("shapes.zig");
const color_mod = @import("color.zig");
const Color = color_mod.Color;
const Vec2 = color_mod.Vec2;
const Rect = color_mod.Rect;
const CornerRadii = color_mod.CornerRadii;
const DrawOptions = color_mod.DrawOptions;
const DrawStyle = color_mod.DrawStyle;
const Paint = color_mod.Paint;
const Gradient = color_mod.Gradient;
const image = @import("image.zig");

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------

pub const Surface = struct {
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    width: u32,
    height: u32,

    // Vulkan resources
    image: c.VkImage = null,
    image_mem: c.VkDeviceMemory = null,
    image_view: c.VkImageView = null,
    framebuffer: c.VkFramebuffer = null,

    // Readback staging buffer (host-visible, used for PNG export)
    staging_buf: vk_mod.Buffer = .{},

    // Command buffer for this surface
    cmd: c.VkCommandBuffer = null,

    // Accumulated vertex data for the current frame
    tess: shapes.Tessellator,

    // Per-draw paint buffer and descriptor set lists
    paint_bufs: std.ArrayList(vk_mod.Buffer),
    desc_sets: std.ArrayList(c.VkDescriptorSet),

    // Clear color for this frame
    clear_color: Color = Color.white,

    /// Create an offscreen surface of the given size.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Surface {
        const r = try renderer_mod.acquire(allocator);
        var s = Surface{
            .allocator = allocator,
            .renderer = r,
            .width = width,
            .height = height,
            .tess = shapes.Tessellator.init(allocator),
            .paint_bufs = std.ArrayList(vk_mod.Buffer).init(allocator),
            .desc_sets = std.ArrayList(c.VkDescriptorSet).init(allocator),
        };
        try s.createVulkanResources();
        try s.allocateCommandBuffer();
        return s;
    }

    pub fn deinit(self: *Surface) void {
        _ = vk.DeviceWaitIdle.?(self.renderer.device);
        self.freePaintResources();
        self.paint_bufs.deinit();
        self.desc_sets.deinit();
        self.tess.deinit();
        self.staging_buf.deinit();
        if (self.framebuffer != null) vk.DestroyFramebuffer.?(self.renderer.device, self.framebuffer, null);
        if (self.image_view != null) vk.DestroyImageView.?(self.renderer.device, self.image_view, null);
        if (self.image != null) vk.DestroyImage.?(self.renderer.device, self.image, null);
        if (self.image_mem != null) vk.FreeMemory.?(self.renderer.device, self.image_mem, null);
    }

    // -----------------------------------------------------------------------
    // Clear
    // -----------------------------------------------------------------------

    /// Set the background clear color. Called before drawing to set up the
    /// color that will be used when `present()` or `flush()` is called.
    pub fn clear(self: *Surface, col: Color) void {
        self.clear_color = col;
    }

    // -----------------------------------------------------------------------
    // Drawing primitives
    // -----------------------------------------------------------------------

    /// Draw a line from `a` to `b`.
    pub fn drawLine(self: *Surface, a: Vec2, b: Vec2, opts: DrawOptions) !void {
        try self.tess.addLine(a, b, opts);
    }

    /// Draw a path (polyline) through the given points.
    pub fn drawPath(self: *Surface, points: []const Vec2, closed: bool, opts: DrawOptions) !void {
        try self.tess.addPath(points, closed, opts);
    }

    /// Draw a quadratic Bézier curve.
    pub fn drawQuadraticBezier(self: *Surface, p0: Vec2, p1: Vec2, p2: Vec2, opts: DrawOptions) !void {
        try self.tess.addQuadraticBezier(p0, p1, p2, opts);
    }

    /// Draw a cubic Bézier curve.
    pub fn drawCubicBezier(self: *Surface, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, opts: DrawOptions) !void {
        try self.tess.addCubicBezier(p0, p1, p2, p3, opts);
    }

    /// Draw a circle.
    pub fn drawCircle(self: *Surface, center: Vec2, radius: f32, opts: DrawOptions) !void {
        try self.tess.addCircle(center, radius, opts);
    }

    /// Draw a circular arc.
    pub fn drawCircularArc(
        self: *Surface,
        center: Vec2,
        radius: f32,
        start_angle: f32,
        end_angle: f32,
        opts: DrawOptions,
    ) !void {
        try self.tess.addCircularArc(center, radius, start_angle, end_angle, opts);
    }

    /// Draw an oval (ellipse).
    pub fn drawOval(self: *Surface, center: Vec2, rx: f32, ry: f32, opts: DrawOptions) !void {
        try self.tess.addEllipse(center, rx, ry, opts);
    }

    /// Draw an elliptical arc.
    pub fn drawOvalArc(
        self: *Surface,
        center: Vec2,
        rx: f32,
        ry: f32,
        start_angle: f32,
        end_angle: f32,
        opts: DrawOptions,
    ) !void {
        try self.tess.addEllipticalArc(center, rx, ry, start_angle, end_angle, opts);
    }

    /// Draw a rectangle with optional per-corner radii.
    pub fn drawRect(self: *Surface, rect: Rect, radii: CornerRadii, opts: DrawOptions) !void {
        try self.tess.addRect(rect, radii, opts);
    }

    // -----------------------------------------------------------------------
    // Flush: record and submit the draw commands
    // -----------------------------------------------------------------------

    /// Render all accumulated draw calls to the surface image.
    /// This must be called before `readPixels` or `savePng`.
    pub fn flush(self: *Surface) !void {
        const dev = self.renderer.device;
        const vertices = self.tess.vertices.items;

        // Upload vertices to a staging + device buffer
        if (vertices.len == 0) {
            // Still do a clear pass
            try self.recordClearOnly();
            return;
        }

        const vtx_size = vertices.len * @sizeOf(shapes.Vertex);
        var vtx_buf = try vk_mod.Buffer.init(
            dev,
            self.renderer.mem_props,
            vtx_size,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        defer vtx_buf.deinit();
        try vtx_buf.upload(std.mem.sliceAsBytes(vertices));

        // Allocate a paint UBO buffer (one per flush — used for the current draw)
        // For simplicity, we use a single solid-white paint for the whole flush;
        // per-draw paint is encoded per-vertex via the color field.
        var paint_buf = try vk_mod.Buffer.init(
            dev,
            self.renderer.mem_props,
            @sizeOf(renderer_mod.GpuPaintData),
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        // We pass .solid white — the actual color comes from vertex attributes
        const desc_set = try self.renderer.allocatePaintDescriptorSet(
            .{ .solid = Color.white },
            &paint_buf,
        );
        try self.paint_bufs.append(paint_buf);
        try self.desc_sets.append(desc_set);

        // Record command buffer
        try self.recordDrawCommands(vtx_buf.buffer, @intCast(vertices.len), desc_set);

        // Submit
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        try vk_mod.check(vk.QueueSubmit.?(self.renderer.graphics_queue, 1, &submit_info, null));
        try vk_mod.check(vk.QueueWaitIdle.?(self.renderer.graphics_queue));

        // Reset tessellator for next frame
        self.tess.reset();
        self.freePaintResources();
    }

    // -----------------------------------------------------------------------
    // PNG export
    // -----------------------------------------------------------------------

    /// Save the surface to a PNG file at `path`. Calls `flush()` first.
    pub fn savePng(self: *Surface, path: []const u8) !void {
        try self.flush();
        try self.transitionImageForReadback();

        const pixel_count = @as(usize, self.width) * self.height * 4;
        if (self.staging_buf.size < pixel_count) {
            self.staging_buf.deinit();
            self.staging_buf = try vk_mod.Buffer.init(
                self.renderer.device,
                self.renderer.mem_props,
                pixel_count,
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }

        // Copy image to staging buffer
        try self.copyImageToBuffer();

        // Read back pixels
        var mapped: ?*anyopaque = null;
        try vk_mod.check(vk.MapMemory.?(
            self.renderer.device,
            self.staging_buf.memory,
            0,
            pixel_count,
            0,
            &mapped,
        ));
        const pixels: []const u8 = @as([*]const u8, @ptrCast(mapped.?))[0..pixel_count];

        // Encode PNG
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try image.writePng(file.writer(), self.width, self.height, pixels);

        vk.UnmapMemory.?(self.renderer.device, self.staging_buf.memory);

        // Transition back for rendering
        try self.transitionImageForRendering();
    }

    /// Return the raw RGBA pixels of the surface. Calls `flush()` first.
    /// Caller must free the returned slice.
    pub fn readPixels(self: *Surface) ![]u8 {
        try self.flush();
        try self.transitionImageForReadback();

        const pixel_count = @as(usize, self.width) * self.height * 4;
        if (self.staging_buf.size < pixel_count) {
            self.staging_buf.deinit();
            self.staging_buf = try vk_mod.Buffer.init(
                self.renderer.device,
                self.renderer.mem_props,
                pixel_count,
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }

        try self.copyImageToBuffer();

        var mapped: ?*anyopaque = null;
        try vk_mod.check(vk.MapMemory.?(
            self.renderer.device,
            self.staging_buf.memory,
            0,
            pixel_count,
            0,
            &mapped,
        ));
        const pixels = try self.allocator.dupe(u8, @as([*]const u8, @ptrCast(mapped.?))[0..pixel_count]);
        vk.UnmapMemory.?(self.renderer.device, self.staging_buf.memory);

        try self.transitionImageForRendering();
        return pixels;
    }

    // -----------------------------------------------------------------------
    // Vulkan resource creation
    // -----------------------------------------------------------------------

    fn createVulkanResources(self: *Surface) !void {
        const dev = self.renderer.device;

        // Create color image
        const image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vk_mod.check(vk.CreateImage.?(dev, &image_info, null, &self.image));

        // Allocate device memory
        var mem_reqs: c.VkMemoryRequirements = undefined;
        vk.GetImageMemoryRequirements.?(dev, self.image, &mem_reqs);

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = try vk_mod.findMemoryType(
                self.renderer.mem_props,
                mem_reqs.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ),
        };
        try vk_mod.check(vk.AllocateMemory.?(dev, &alloc_info, null, &self.image_mem));
        try vk_mod.check(vk.BindImageMemory.?(dev, self.image, self.image_mem, 0));

        // Image view
        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        try vk_mod.check(vk.CreateImageView.?(dev, &view_info, null, &self.image_view));

        // Framebuffer
        const fb_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = self.renderer.offscreen_render_pass,
            .attachmentCount = 1,
            .pAttachments = &self.image_view,
            .width = self.width,
            .height = self.height,
            .layers = 1,
        };
        try vk_mod.check(vk.CreateFramebuffer.?(dev, &fb_info, null, &self.framebuffer));
    }

    fn allocateCommandBuffer(self: *Surface) !void {
        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.renderer.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try vk_mod.check(vk.AllocateCommandBuffers.?(
            self.renderer.device,
            &alloc_info,
            &self.cmd,
        ));
    }

    // -----------------------------------------------------------------------
    // Command recording
    // -----------------------------------------------------------------------

    fn recordClearOnly(self: *Surface) !void {
        try vk_mod.check(vk.ResetCommandBuffer.?(self.cmd, 0));

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk_mod.check(vk.BeginCommandBuffer.?(self.cmd, &begin_info));

        const clear_val = c.VkClearValue{
            .color = .{
                .float32 = .{
                    self.clear_color.r,
                    self.clear_color.g,
                    self.clear_color.b,
                    self.clear_color.a,
                },
            },
        };
        const rp_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.renderer.offscreen_render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } },
            .clearValueCount = 1,
            .pClearValues = &clear_val,
        };
        vk.CmdBeginRenderPass.?(self.cmd, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);
        vk.CmdEndRenderPass.?(self.cmd);

        try vk_mod.check(vk.EndCommandBuffer.?(self.cmd));

        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        try vk_mod.check(vk.QueueSubmit.?(self.renderer.graphics_queue, 1, &submit_info, null));
        try vk_mod.check(vk.QueueWaitIdle.?(self.renderer.graphics_queue));
    }

    fn recordDrawCommands(
        self: *Surface,
        vtx_buf: c.VkBuffer,
        vertex_count: u32,
        desc_set: c.VkDescriptorSet,
    ) !void {
        try vk_mod.check(vk.ResetCommandBuffer.?(self.cmd, 0));

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk_mod.check(vk.BeginCommandBuffer.?(self.cmd, &begin_info));

        // Orthographic projection: map (0,0)–(W,H) to NDC (-1,1)–(1,-1)
        const proj = orthoProjection(
            @floatFromInt(self.width),
            @floatFromInt(self.height),
        );

        const clear_val = c.VkClearValue{
            .color = .{
                .float32 = .{
                    self.clear_color.r,
                    self.clear_color.g,
                    self.clear_color.b,
                    self.clear_color.a,
                },
            },
        };
        const rp_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.renderer.offscreen_render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = self.width, .height = self.height },
            },
            .clearValueCount = 1,
            .pClearValues = &clear_val,
        };
        vk.CmdBeginRenderPass.?(self.cmd, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

        // Viewport and scissor
        const viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.CmdSetViewport.?(self.cmd, 0, 1, &viewport);

        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = self.width, .height = self.height },
        };
        vk.CmdSetScissor.?(self.cmd, 0, 1, &scissor);

        // Bind pipeline
        vk.CmdBindPipeline.?(self.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.renderer.pipeline);

        // Push constants
        const pc = renderer_mod.PushConstants{ .proj = proj };
        vk.CmdPushConstants.?(
            self.cmd,
            self.renderer.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(renderer_mod.PushConstants),
            &pc,
        );

        // Bind descriptor set (paint UBO)
        vk.CmdBindDescriptorSets.?(
            self.cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.renderer.pipeline_layout,
            0,
            1,
            &desc_set,
            0,
            null,
        );

        // Bind vertex buffer and draw
        const offset: c.VkDeviceSize = 0;
        vk.CmdBindVertexBuffers.?(self.cmd, 0, 1, &vtx_buf, &offset);
        vk.CmdDraw.?(self.cmd, vertex_count, 1, 0, 0);

        vk.CmdEndRenderPass.?(self.cmd);
        try vk_mod.check(vk.EndCommandBuffer.?(self.cmd));
    }

    // -----------------------------------------------------------------------
    // Readback helpers
    // -----------------------------------------------------------------------

    fn transitionImageForReadback(self: *Surface) !void {
        const cmd = try vk_mod.beginOneShot(
            self.renderer.device,
            self.renderer.command_pool,
        );

        const barrier = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.CmdPipelineBarrier.?(
            cmd,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier,
        );

        try vk_mod.submitOneShot(
            self.renderer.device,
            self.renderer.command_pool,
            self.renderer.graphics_queue,
            cmd,
        );
    }

    fn transitionImageForRendering(self: *Surface) !void {
        // No-op: the render pass handles layout transitions for the next frame.
        _ = self;
    }

    fn copyImageToBuffer(self: *Surface) !void {
        const cmd = try vk_mod.beginOneShot(
            self.renderer.device,
            self.renderer.command_pool,
        );

        const region = c.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        vk.CmdCopyImageToBuffer.?(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.staging_buf.buffer,
            1,
            &region,
        );

        try vk_mod.submitOneShot(
            self.renderer.device,
            self.renderer.command_pool,
            self.renderer.graphics_queue,
            cmd,
        );
    }

    fn freePaintResources(self: *Surface) void {
        // The descriptor pool was created with VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        // so we can free individual descriptor sets back to the pool.
        // For simplicity, we just let them accumulate until we destroy the pool.
        // The renderer owns the pool and will clean it up on deinit.
        self.desc_sets.clearRetainingCapacity();

        // Free paint UBO buffers
        for (self.paint_bufs.items) |*pb| {
            pb.deinit();
        }
        self.paint_bufs.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Orthographic projection
// ---------------------------------------------------------------------------

/// Build a column-major 4×4 orthographic projection matrix mapping
/// (0,0)–(width,height) to NDC (-1,1)–(1,-1) with Y pointing down.
fn orthoProjection(width: f32, height: f32) [16]f32 {
    const r: f32 = width;
    const t: f32 = height;
    // Column-major:
    // [ 2/r,   0,   0,  0 ]
    // [   0, 2/t,   0,  0 ]   (note: flipped Y for screen space)
    // [   0,   0,  -1,  0 ]
    // [-1,   -1,   0,  1 ]
    return .{
        2.0 / r,  0.0,       0.0, 0.0,
        0.0,      2.0 / t,   0.0, 0.0,
        0.0,      0.0,      -1.0, 0.0,
       -1.0,     -1.0,       0.0, 1.0,
    };
}
