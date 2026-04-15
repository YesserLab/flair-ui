//! Renderer — Vulkan pipeline management and draw command submission.
//!
//! The Renderer is a global singleton that manages:
//!   - Vulkan instance, physical device, logical device
//!   - Graphics command pool and queue
//!   - Shared render pass and graphics pipeline
//!
//! Surfaces and Windows reference the global Renderer.

const std = @import("std");
const vk_mod = @import("vulkan.zig");
const vk = vk_mod.vk;
const c = vk_mod.c;
const shapes = @import("shapes.zig");
const color_mod = @import("color.zig");
const Paint = color_mod.Paint;

// ---------------------------------------------------------------------------
// Paint UBO layout (must match fill.frag.glsl)
// ---------------------------------------------------------------------------

pub const MAX_COLOR_STOPS: usize = 16;

pub const GpuColorStop = extern struct {
    position: f32,
    _pad0: [3]f32 = .{ 0, 0, 0 },
    color: [4]f32,
};

pub const GpuPaintData = extern struct {
    gradient_type: i32, // 0 = solid, 1 = linear, 2 = radial
    num_stops: i32,
    _pad: [2]i32 = .{ 0, 0 },
    gradient_p0: [2]f32, // linear: start, radial: center
    gradient_p1: [2]f32, // linear: end (unused for radial)
    gradient_radius: f32, // radial only
    _pad2: [3]f32 = .{ 0, 0, 0 },
    stops: [MAX_COLOR_STOPS]GpuColorStop,
};

// ---------------------------------------------------------------------------
// Push constants layout (must match fill.vert.glsl)
// ---------------------------------------------------------------------------

pub const PushConstants = extern struct {
    /// Orthographic projection matrix (column-major 4×4).
    proj: [16]f32,
};

// ---------------------------------------------------------------------------
// Global renderer state
// ---------------------------------------------------------------------------

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    graphics_family: u32 = 0,
    mem_props: c.VkPhysicalDeviceMemoryProperties = undefined,

    command_pool: c.VkCommandPool = null,

    // Offscreen render pass (color-only, no depth)
    offscreen_render_pass: c.VkRenderPass = null,

    // Pipeline shared for both offscreen and window
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    // Descriptor set layout for the paint UBO
    desc_set_layout: c.VkDescriptorSetLayout = null,
    desc_pool: c.VkDescriptorPool = null,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        try vk_mod.load();

        var r = Renderer{ .allocator = allocator };
        try r.createInstance();
        try r.selectPhysicalDevice();
        try r.createDevice();
        try r.createCommandPool();
        try r.createOffscreenRenderPass();
        try r.createDescriptorSetLayout();
        try r.createDescriptorPool();
        try r.createPipeline();
        return r;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device == null) return;
        _ = vk.DeviceWaitIdle.?(self.device);
        if (self.pipeline != null) vk.DestroyPipeline.?(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) vk.DestroyPipelineLayout.?(self.device, self.pipeline_layout, null);
        if (self.desc_pool != null) vk.DestroyDescriptorPool.?(self.device, self.desc_pool, null);
        if (self.desc_set_layout != null) vk.DestroyDescriptorSetLayout.?(self.device, self.desc_set_layout, null);
        if (self.offscreen_render_pass != null) vk.DestroyRenderPass.?(self.device, self.offscreen_render_pass, null);
        if (self.command_pool != null) vk.DestroyCommandPool.?(self.device, self.command_pool, null);
        if (self.device != null) vk.DestroyDevice.?(self.device, null);
        if (self.instance != null) vk.DestroyInstance.?(self.instance, null);
    }

    // -----------------------------------------------------------------------
    // Instance
    // -----------------------------------------------------------------------

    fn createInstance(self: *Renderer) !void {
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "flair-ui",
            .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "flair-ui",
            .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = c.VK_API_VERSION_1_0,
        };

        const extensions = [_][*:0]const u8{
            c.VK_KHR_SURFACE_EXTENSION_NAME,
            c.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        };

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&extensions[0]),
        };

        try vk_mod.check(vk.CreateInstance.?(&create_info, null, &self.instance));
        vk_mod.loadInstance(self.instance);
    }

    // -----------------------------------------------------------------------
    // Physical device
    // -----------------------------------------------------------------------

    fn selectPhysicalDevice(self: *Renderer) !void {
        var count: u32 = 0;
        try vk_mod.check(vk.EnumeratePhysicalDevices.?(self.instance, &count, null));
        if (count == 0) return error.NoVulkanDevice;

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try vk_mod.check(vk.EnumeratePhysicalDevices.?(self.instance, &count, devices.ptr));

        // Prefer discrete GPU
        var best: c.VkPhysicalDevice = null;
        for (devices) |dev| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            vk.GetPhysicalDeviceProperties.?(dev, &props);
            if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                best = dev;
                break;
            }
            if (best == null) best = dev;
        }
        self.physical_device = best;
        vk.GetPhysicalDeviceMemoryProperties.?(self.physical_device, &self.mem_props);
    }

    // -----------------------------------------------------------------------
    // Logical device
    // -----------------------------------------------------------------------

    fn createDevice(self: *Renderer) !void {
        // Find graphics queue family
        var family_count: u32 = 0;
        vk.GetPhysicalDeviceQueueFamilyProperties.?(self.physical_device, &family_count, null);
        const families = try self.allocator.alloc(c.VkQueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        vk.GetPhysicalDeviceQueueFamilyProperties.?(self.physical_device, &family_count, families.ptr);

        var found = false;
        for (families, 0..) |fam, i| {
            if (fam.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                self.graphics_family = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) return error.NoGraphicsQueue;

        const queue_priority: f32 = 1.0;
        const queue_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_extensions = [_][*:0]const u8{
            c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        };

        const device_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions[0]),
            .pEnabledFeatures = null,
        };

        try vk_mod.check(vk.CreateDevice.?(self.physical_device, &device_info, null, &self.device));
        vk_mod.loadDevice(self.instance, self.device);
        vk.GetDeviceQueue.?(self.device, self.graphics_family, 0, &self.graphics_queue);
    }

    // -----------------------------------------------------------------------
    // Command pool
    // -----------------------------------------------------------------------

    fn createCommandPool(self: *Renderer) !void {
        const info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };
        try vk_mod.check(vk.CreateCommandPool.?(self.device, &info, null, &self.command_pool));
    }

    // -----------------------------------------------------------------------
    // Offscreen render pass
    // -----------------------------------------------------------------------

    fn createOffscreenRenderPass(self: *Renderer) !void {
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };

        const color_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const rp_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        try vk_mod.check(vk.CreateRenderPass.?(self.device, &rp_info, null, &self.offscreen_render_pass));
    }

    // -----------------------------------------------------------------------
    // Descriptor set layout
    // -----------------------------------------------------------------------

    fn createDescriptorSetLayout(self: *Renderer) !void {
        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };

        const layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = &binding,
        };

        try vk_mod.check(vk.CreateDescriptorSetLayout.?(self.device, &layout_info, null, &self.desc_set_layout));
    }

    fn createDescriptorPool(self: *Renderer) !void {
        const pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 256,
        };

        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 256,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };

        try vk_mod.check(vk.CreateDescriptorPool.?(self.device, &pool_info, null, &self.desc_pool));
    }

    // -----------------------------------------------------------------------
    // Graphics pipeline
    // -----------------------------------------------------------------------

    fn createPipeline(self: *Renderer) !void {
        // Load compiled SPIR-V shaders (embedded at compile time)
        const vert_spv = @embedFile("shaders/fill.vert.spv");
        const frag_spv = @embedFile("shaders/fill.frag.spv");

        const vert_module = try self.createShaderModule(vert_spv);
        defer vk.DestroyShaderModule.?(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(frag_spv);
        defer vk.DestroyShaderModule.?(self.device, frag_module, null);

        // Shader stages
        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        // Vertex input: Vertex struct layout
        // binding 0: per-vertex data
        const vertex_binding = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(shapes.Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        const vertex_attribs = [_]c.VkVertexInputAttributeDescription{
            // location 0: position (vec2)
            .{
                .location = 0,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(shapes.Vertex, "position"),
            },
            // location 1: gradient_coord (vec2)
            .{
                .location = 1,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(shapes.Vertex, "gradient_coord"),
            },
            // location 2: color (vec4)
            .{
                .location = 2,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32A32_SFLOAT,
                .offset = @offsetOf(shapes.Vertex, "color"),
            },
        };

        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &vertex_binding,
            .vertexAttributeDescriptionCount = vertex_attribs.len,
            .pVertexAttributeDescriptions = &vertex_attribs[0],
        };

        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };

        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // dynamic
            .scissorCount = 1,
            .pScissors = null, // dynamic
        };

        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };

        // Blending: standard alpha blending
        const blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = c.VK_TRUE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };

        const blend_state = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        // Dynamic state: viewport and scissor
        const dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        const dynamic_state = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states[0],
        };

        // Pipeline layout: push constants (projection) + descriptor set (paint UBO)
        const push_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };

        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.desc_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        };
        try vk_mod.check(vk.CreatePipelineLayout.?(self.device, &layout_info, null, &self.pipeline_layout));

        // Create pipeline (using offscreen render pass for compatibility)
        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages[0],
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &blend_state,
            .pDynamicState = &dynamic_state,
            .layout = self.pipeline_layout,
            .renderPass = self.offscreen_render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        try vk_mod.check(vk.CreateGraphicsPipelines.?(self.device, null, 1, &pipeline_info, null, &self.pipeline));
    }

    fn createShaderModule(self: *Renderer, spv: []const u8) !c.VkShaderModule {
        const info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spv.len,
            .pCode = @ptrCast(@alignCast(spv.ptr)),
        };
        var module: c.VkShaderModule = undefined;
        try vk_mod.check(vk.CreateShaderModule.?(self.device, &info, null, &module));
        return module;
    }

    // -----------------------------------------------------------------------
    // Paint descriptor set management
    // -----------------------------------------------------------------------

    /// Allocate and populate a descriptor set for the given paint.
    pub fn allocatePaintDescriptorSet(
        self: *Renderer,
        paint: Paint,
        paint_buf: *vk_mod.Buffer,
    ) !c.VkDescriptorSet {
        // Allocate descriptor set
        var desc_set: c.VkDescriptorSet = undefined;
        const alloc_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.desc_set_layout,
        };
        try vk_mod.check(vk.AllocateDescriptorSets.?(self.device, &alloc_info, &desc_set));

        // Fill UBO
        const gpu_paint = buildGpuPaintData(paint);
        try paint_buf.upload(std.mem.asBytes(&gpu_paint));

        // Update descriptor set
        const buf_info = c.VkDescriptorBufferInfo{
            .buffer = paint_buf.buffer,
            .offset = 0,
            .range = @sizeOf(GpuPaintData),
        };
        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = desc_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buf_info,
            .pTexelBufferView = null,
        };
        vk.UpdateDescriptorSets.?(self.device, 1, &write, 0, null);

        return desc_set;
    }
};

// ---------------------------------------------------------------------------
// Global singleton renderer
// ---------------------------------------------------------------------------

var g_renderer: ?Renderer = null;
var g_renderer_init = false;
var g_allocator: std.mem.Allocator = undefined;

/// Get or initialize the global Renderer instance.
pub fn acquire(allocator: std.mem.Allocator) !*Renderer {
    if (!g_renderer_init) {
        g_allocator = allocator;
        g_renderer = try Renderer.init(allocator);
        g_renderer_init = true;
    }
    return &g_renderer.?;
}

/// Release the global Renderer. Call this when the application exits.
pub fn release() void {
    if (g_renderer_init) {
        g_renderer.?.deinit();
        g_renderer = null;
        g_renderer_init = false;
    }
}

// ---------------------------------------------------------------------------
// Helper: build GPU paint data from a Paint value
// ---------------------------------------------------------------------------

fn buildGpuPaintData(paint: Paint) GpuPaintData {
    var data = GpuPaintData{
        .gradient_type = 0,
        .num_stops = 0,
        .gradient_p0 = .{ 0, 0 },
        .gradient_p1 = .{ 0, 0 },
        .gradient_radius = 0,
        .stops = undefined,
    };
    // Zero-init stops
    for (&data.stops) |*s| {
        s.* = .{ .position = 0, .color = .{ 0, 0, 0, 1 } };
    }

    switch (paint) {
        .solid => |col| {
            data.gradient_type = 0;
            data.num_stops = 1;
            data.stops[0] = .{ .position = 0, .color = .{ col.r, col.g, col.b, col.a } };
        },
        .gradient => |g| {
            switch (g.kind) {
                .linear => |lg| {
                    data.gradient_type = 1;
                    data.gradient_p0 = .{ lg.start.x, lg.start.y };
                    data.gradient_p1 = .{ lg.end.x, lg.end.y };
                    const n = @min(lg.stops.len, MAX_COLOR_STOPS);
                    data.num_stops = @intCast(n);
                    for (0..n) |i| {
                        const s = lg.stops[i];
                        data.stops[i] = .{
                            .position = s.position,
                            .color = .{ s.color.r, s.color.g, s.color.b, s.color.a },
                        };
                    }
                },
                .radial => |rg| {
                    data.gradient_type = 2;
                    data.gradient_p0 = .{ rg.center.x, rg.center.y };
                    data.gradient_radius = rg.radius;
                    const n = @min(rg.stops.len, MAX_COLOR_STOPS);
                    data.num_stops = @intCast(n);
                    for (0..n) |i| {
                        const s = rg.stops[i];
                        data.stops[i] = .{
                            .position = s.position,
                            .color = .{ s.color.r, s.color.g, s.color.b, s.color.a },
                        };
                    }
                },
            }
        },
    }

    return data;
}
