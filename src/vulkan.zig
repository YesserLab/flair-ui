//! Vulkan helpers: instance, physical device, logical device, memory, utilities.
//!
//! This module wraps the C Vulkan API and provides ergonomic Zig wrappers for
//! the most common operations.  The C bindings are generated at build time via
//! `b.addTranslateC` (the Zig 0.16 replacement for the deprecated @cImport).

const std = @import("std");
const builtin = @import("builtin");

/// C bindings generated from src/c_headers/vulkan.h by `zig translate-c`.
pub const c = @import("vulkan_c");

// Re-export commonly used Vulkan types for convenience
pub const VkResult = c.VkResult;
pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;
pub const VkQueue = c.VkQueue;
pub const VkCommandPool = c.VkCommandPool;
pub const VkCommandBuffer = c.VkCommandBuffer;
pub const VkRenderPass = c.VkRenderPass;
pub const VkFramebuffer = c.VkFramebuffer;
pub const VkPipeline = c.VkPipeline;
pub const VkPipelineLayout = c.VkPipelineLayout;
pub const VkDescriptorSetLayout = c.VkDescriptorSetLayout;
pub const VkDescriptorPool = c.VkDescriptorPool;
pub const VkDescriptorSet = c.VkDescriptorSet;
pub const VkBuffer = c.VkBuffer;
pub const VkDeviceMemory = c.VkDeviceMemory;
pub const VkImage = c.VkImage;
pub const VkImageView = c.VkImageView;
pub const VkSampler = c.VkSampler;
pub const VkSemaphore = c.VkSemaphore;
pub const VkFence = c.VkFence;
pub const VkSurfaceKHR = c.VkSurfaceKHR;
pub const VkSwapchainKHR = c.VkSwapchainKHR;
pub const VkShaderModule = c.VkShaderModule;

// ---------------------------------------------------------------------------
// Function pointer loader (we use vkGetInstanceProcAddr / vkGetDeviceProcAddr)
// ---------------------------------------------------------------------------

/// Loaded global Vulkan function pointers.
pub var vk: VkFunctions = undefined;
var vk_loaded = false;

pub const VkFunctions = struct {
    // Global
    GetInstanceProcAddr: c.PFN_vkGetInstanceProcAddr,
    CreateInstance: c.PFN_vkCreateInstance,
    EnumerateInstanceExtensionProperties: c.PFN_vkEnumerateInstanceExtensionProperties,
    EnumerateInstanceLayerProperties: c.PFN_vkEnumerateInstanceLayerProperties,

    // Instance
    DestroyInstance: c.PFN_vkDestroyInstance,
    EnumeratePhysicalDevices: c.PFN_vkEnumeratePhysicalDevices,
    GetPhysicalDeviceProperties: c.PFN_vkGetPhysicalDeviceProperties,
    GetPhysicalDeviceFeatures: c.PFN_vkGetPhysicalDeviceFeatures,
    GetPhysicalDeviceQueueFamilyProperties: c.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    GetPhysicalDeviceMemoryProperties: c.PFN_vkGetPhysicalDeviceMemoryProperties,
    GetPhysicalDeviceFormatProperties: c.PFN_vkGetPhysicalDeviceFormatProperties,
    CreateDevice: c.PFN_vkCreateDevice,
    DestroySurfaceKHR: c.PFN_vkDestroySurfaceKHR,
    GetPhysicalDeviceSurfaceSupportKHR: c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    GetPhysicalDeviceSurfaceCapabilitiesKHR: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    GetPhysicalDeviceSurfaceFormatsKHR: c.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
    GetPhysicalDeviceSurfacePresentModesKHR: c.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR,
    CreateWaylandSurfaceKHR: c.PFN_vkCreateWaylandSurfaceKHR,

    // Device
    DestroyDevice: c.PFN_vkDestroyDevice,
    GetDeviceQueue: c.PFN_vkGetDeviceQueue,
    DeviceWaitIdle: c.PFN_vkDeviceWaitIdle,
    CreateCommandPool: c.PFN_vkCreateCommandPool,
    DestroyCommandPool: c.PFN_vkDestroyCommandPool,
    AllocateCommandBuffers: c.PFN_vkAllocateCommandBuffers,
    FreeCommandBuffers: c.PFN_vkFreeCommandBuffers,
    BeginCommandBuffer: c.PFN_vkBeginCommandBuffer,
    EndCommandBuffer: c.PFN_vkEndCommandBuffer,
    ResetCommandBuffer: c.PFN_vkResetCommandBuffer,
    QueueSubmit: c.PFN_vkQueueSubmit,
    QueueWaitIdle: c.PFN_vkQueueWaitIdle,
    QueuePresentKHR: c.PFN_vkQueuePresentKHR,
    CreateRenderPass: c.PFN_vkCreateRenderPass,
    DestroyRenderPass: c.PFN_vkDestroyRenderPass,
    CreateFramebuffer: c.PFN_vkCreateFramebuffer,
    DestroyFramebuffer: c.PFN_vkDestroyFramebuffer,
    CreateImageView: c.PFN_vkCreateImageView,
    DestroyImageView: c.PFN_vkDestroyImageView,
    CreateImage: c.PFN_vkCreateImage,
    DestroyImage: c.PFN_vkDestroyImage,
    GetImageMemoryRequirements: c.PFN_vkGetImageMemoryRequirements,
    BindImageMemory: c.PFN_vkBindImageMemory,
    AllocateMemory: c.PFN_vkAllocateMemory,
    FreeMemory: c.PFN_vkFreeMemory,
    MapMemory: c.PFN_vkMapMemory,
    UnmapMemory: c.PFN_vkUnmapMemory,
    CreateBuffer: c.PFN_vkCreateBuffer,
    DestroyBuffer: c.PFN_vkDestroyBuffer,
    GetBufferMemoryRequirements: c.PFN_vkGetBufferMemoryRequirements,
    BindBufferMemory: c.PFN_vkBindBufferMemory,
    CreateShaderModule: c.PFN_vkCreateShaderModule,
    DestroyShaderModule: c.PFN_vkDestroyShaderModule,
    CreateGraphicsPipelines: c.PFN_vkCreateGraphicsPipelines,
    DestroyPipeline: c.PFN_vkDestroyPipeline,
    CreatePipelineLayout: c.PFN_vkCreatePipelineLayout,
    DestroyPipelineLayout: c.PFN_vkDestroyPipelineLayout,
    CreateDescriptorSetLayout: c.PFN_vkCreateDescriptorSetLayout,
    DestroyDescriptorSetLayout: c.PFN_vkDestroyDescriptorSetLayout,
    CreateDescriptorPool: c.PFN_vkCreateDescriptorPool,
    DestroyDescriptorPool: c.PFN_vkDestroyDescriptorPool,
    AllocateDescriptorSets: c.PFN_vkAllocateDescriptorSets,
    UpdateDescriptorSets: c.PFN_vkUpdateDescriptorSets,
    CreateSemaphore: c.PFN_vkCreateSemaphore,
    DestroySemaphore: c.PFN_vkDestroySemaphore,
    CreateFence: c.PFN_vkCreateFence,
    DestroyFence: c.PFN_vkDestroyFence,
    WaitForFences: c.PFN_vkWaitForFences,
    ResetFences: c.PFN_vkResetFences,
    CmdBeginRenderPass: c.PFN_vkCmdBeginRenderPass,
    CmdEndRenderPass: c.PFN_vkCmdEndRenderPass,
    CmdBindPipeline: c.PFN_vkCmdBindPipeline,
    CmdBindVertexBuffers: c.PFN_vkCmdBindVertexBuffers,
    CmdDraw: c.PFN_vkCmdDraw,
    CmdSetViewport: c.PFN_vkCmdSetViewport,
    CmdSetScissor: c.PFN_vkCmdSetScissor,
    CmdPushConstants: c.PFN_vkCmdPushConstants,
    CmdBindDescriptorSets: c.PFN_vkCmdBindDescriptorSets,
    CmdCopyImageToBuffer: c.PFN_vkCmdCopyImageToBuffer,
    CmdPipelineBarrier: c.PFN_vkCmdPipelineBarrier,
    CmdBlitImage: c.PFN_vkCmdBlitImage,
    CreateSwapchainKHR: c.PFN_vkCreateSwapchainKHR,
    DestroySwapchainKHR: c.PFN_vkDestroySwapchainKHR,
    GetSwapchainImagesKHR: c.PFN_vkGetSwapchainImagesKHR,
    AcquireNextImageKHR: c.PFN_vkAcquireNextImageKHR,
    FlushMappedMemoryRanges: c.PFN_vkFlushMappedMemoryRanges,
    InvalidateMappedMemoryRanges: c.PFN_vkInvalidateMappedMemoryRanges,
};

/// The loaded Vulkan shared library handle. Kept alive to prevent unloading.
var g_vulkan_lib: ?std.DynLib = null;

/// Load all Vulkan function pointers. Must be called before any Vulkan API use.
pub fn load() !void {
    if (vk_loaded) return;

    // Open libvulkan dynamically; keep the handle alive in g_vulkan_lib
    g_vulkan_lib = std.DynLib.open("libvulkan.so.1") catch
        try std.DynLib.open("libvulkan.so");

    const get_proc_addr = g_vulkan_lib.?.lookup(
        c.PFN_vkGetInstanceProcAddr,
        "vkGetInstanceProcAddr",
    ) orelse return error.VkGetInstanceProcAddrNotFound;

    vk.GetInstanceProcAddr = get_proc_addr;

    // Load pre-instance functions via null instance
    vk.CreateInstance = @ptrCast(get_proc_addr(null, "vkCreateInstance"));
    vk.EnumerateInstanceExtensionProperties = @ptrCast(get_proc_addr(null, "vkEnumerateInstanceExtensionProperties"));
    vk.EnumerateInstanceLayerProperties = @ptrCast(get_proc_addr(null, "vkEnumerateInstanceLayerProperties"));

    vk_loaded = true;
}

/// Load instance-level function pointers.
pub fn loadInstance(instance: VkInstance) void {
    const g = vk.GetInstanceProcAddr;
    vk.DestroyInstance = @ptrCast(g(instance, "vkDestroyInstance"));
    vk.EnumeratePhysicalDevices = @ptrCast(g(instance, "vkEnumeratePhysicalDevices"));
    vk.GetPhysicalDeviceProperties = @ptrCast(g(instance, "vkGetPhysicalDeviceProperties"));
    vk.GetPhysicalDeviceFeatures = @ptrCast(g(instance, "vkGetPhysicalDeviceFeatures"));
    vk.GetPhysicalDeviceQueueFamilyProperties = @ptrCast(g(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    vk.GetPhysicalDeviceMemoryProperties = @ptrCast(g(instance, "vkGetPhysicalDeviceMemoryProperties"));
    vk.GetPhysicalDeviceFormatProperties = @ptrCast(g(instance, "vkGetPhysicalDeviceFormatProperties"));
    vk.CreateDevice = @ptrCast(g(instance, "vkCreateDevice"));
    vk.DestroySurfaceKHR = @ptrCast(g(instance, "vkDestroySurfaceKHR"));
    vk.GetPhysicalDeviceSurfaceSupportKHR = @ptrCast(g(instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR = @ptrCast(g(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    vk.GetPhysicalDeviceSurfaceFormatsKHR = @ptrCast(g(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
    vk.GetPhysicalDeviceSurfacePresentModesKHR = @ptrCast(g(instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));
    vk.CreateWaylandSurfaceKHR = @ptrCast(g(instance, "vkCreateWaylandSurfaceKHR"));
}

/// Load device-level function pointers.
pub fn loadDevice(instance: VkInstance, device: VkDevice) void {
    const g = vk.GetInstanceProcAddr;
    // Use vkGetDeviceProcAddr for device-level functions
    const gd: c.PFN_vkGetDeviceProcAddr = @ptrCast(g(instance, "vkGetDeviceProcAddr"));

    // Load device-level functions
    vk.DestroyDevice = @ptrCast(gd.?(device, "vkDestroyDevice"));
    vk.GetDeviceQueue = @ptrCast(gd.?(device, "vkGetDeviceQueue"));
    vk.DeviceWaitIdle = @ptrCast(gd.?(device, "vkDeviceWaitIdle"));
    vk.CreateCommandPool = @ptrCast(gd.?(device, "vkCreateCommandPool"));
    vk.DestroyCommandPool = @ptrCast(gd.?(device, "vkDestroyCommandPool"));
    vk.AllocateCommandBuffers = @ptrCast(gd.?(device, "vkAllocateCommandBuffers"));
    vk.FreeCommandBuffers = @ptrCast(gd.?(device, "vkFreeCommandBuffers"));
    vk.BeginCommandBuffer = @ptrCast(gd.?(device, "vkBeginCommandBuffer"));
    vk.EndCommandBuffer = @ptrCast(gd.?(device, "vkEndCommandBuffer"));
    vk.ResetCommandBuffer = @ptrCast(gd.?(device, "vkResetCommandBuffer"));
    vk.QueueSubmit = @ptrCast(gd.?(device, "vkQueueSubmit"));
    vk.QueueWaitIdle = @ptrCast(gd.?(device, "vkQueueWaitIdle"));
    vk.QueuePresentKHR = @ptrCast(gd.?(device, "vkQueuePresentKHR"));
    vk.CreateRenderPass = @ptrCast(gd.?(device, "vkCreateRenderPass"));
    vk.DestroyRenderPass = @ptrCast(gd.?(device, "vkDestroyRenderPass"));
    vk.CreateFramebuffer = @ptrCast(gd.?(device, "vkCreateFramebuffer"));
    vk.DestroyFramebuffer = @ptrCast(gd.?(device, "vkDestroyFramebuffer"));
    vk.CreateImageView = @ptrCast(gd.?(device, "vkCreateImageView"));
    vk.DestroyImageView = @ptrCast(gd.?(device, "vkDestroyImageView"));
    vk.CreateImage = @ptrCast(gd.?(device, "vkCreateImage"));
    vk.DestroyImage = @ptrCast(gd.?(device, "vkDestroyImage"));
    vk.GetImageMemoryRequirements = @ptrCast(gd.?(device, "vkGetImageMemoryRequirements"));
    vk.BindImageMemory = @ptrCast(gd.?(device, "vkBindImageMemory"));
    vk.AllocateMemory = @ptrCast(gd.?(device, "vkAllocateMemory"));
    vk.FreeMemory = @ptrCast(gd.?(device, "vkFreeMemory"));
    vk.MapMemory = @ptrCast(gd.?(device, "vkMapMemory"));
    vk.UnmapMemory = @ptrCast(gd.?(device, "vkUnmapMemory"));
    vk.CreateBuffer = @ptrCast(gd.?(device, "vkCreateBuffer"));
    vk.DestroyBuffer = @ptrCast(gd.?(device, "vkDestroyBuffer"));
    vk.GetBufferMemoryRequirements = @ptrCast(gd.?(device, "vkGetBufferMemoryRequirements"));
    vk.BindBufferMemory = @ptrCast(gd.?(device, "vkBindBufferMemory"));
    vk.CreateShaderModule = @ptrCast(gd.?(device, "vkCreateShaderModule"));
    vk.DestroyShaderModule = @ptrCast(gd.?(device, "vkDestroyShaderModule"));
    vk.CreateGraphicsPipelines = @ptrCast(gd.?(device, "vkCreateGraphicsPipelines"));
    vk.DestroyPipeline = @ptrCast(gd.?(device, "vkDestroyPipeline"));
    vk.CreatePipelineLayout = @ptrCast(gd.?(device, "vkCreatePipelineLayout"));
    vk.DestroyPipelineLayout = @ptrCast(gd.?(device, "vkDestroyPipelineLayout"));
    vk.CreateDescriptorSetLayout = @ptrCast(gd.?(device, "vkCreateDescriptorSetLayout"));
    vk.DestroyDescriptorSetLayout = @ptrCast(gd.?(device, "vkDestroyDescriptorSetLayout"));
    vk.CreateDescriptorPool = @ptrCast(gd.?(device, "vkCreateDescriptorPool"));
    vk.DestroyDescriptorPool = @ptrCast(gd.?(device, "vkDestroyDescriptorPool"));
    vk.AllocateDescriptorSets = @ptrCast(gd.?(device, "vkAllocateDescriptorSets"));
    vk.UpdateDescriptorSets = @ptrCast(gd.?(device, "vkUpdateDescriptorSets"));
    vk.CreateSemaphore = @ptrCast(gd.?(device, "vkCreateSemaphore"));
    vk.DestroySemaphore = @ptrCast(gd.?(device, "vkDestroySemaphore"));
    vk.CreateFence = @ptrCast(gd.?(device, "vkCreateFence"));
    vk.DestroyFence = @ptrCast(gd.?(device, "vkDestroyFence"));
    vk.WaitForFences = @ptrCast(gd.?(device, "vkWaitForFences"));
    vk.ResetFences = @ptrCast(gd.?(device, "vkResetFences"));
    vk.CmdBeginRenderPass = @ptrCast(gd.?(device, "vkCmdBeginRenderPass"));
    vk.CmdEndRenderPass = @ptrCast(gd.?(device, "vkCmdEndRenderPass"));
    vk.CmdBindPipeline = @ptrCast(gd.?(device, "vkCmdBindPipeline"));
    vk.CmdBindVertexBuffers = @ptrCast(gd.?(device, "vkCmdBindVertexBuffers"));
    vk.CmdDraw = @ptrCast(gd.?(device, "vkCmdDraw"));
    vk.CmdSetViewport = @ptrCast(gd.?(device, "vkCmdSetViewport"));
    vk.CmdSetScissor = @ptrCast(gd.?(device, "vkCmdSetScissor"));
    vk.CmdPushConstants = @ptrCast(gd.?(device, "vkCmdPushConstants"));
    vk.CmdBindDescriptorSets = @ptrCast(gd.?(device, "vkCmdBindDescriptorSets"));
    vk.CmdCopyImageToBuffer = @ptrCast(gd.?(device, "vkCmdCopyImageToBuffer"));
    vk.CmdPipelineBarrier = @ptrCast(gd.?(device, "vkCmdPipelineBarrier"));
    vk.CmdBlitImage = @ptrCast(gd.?(device, "vkCmdBlitImage"));
    vk.CreateSwapchainKHR = @ptrCast(gd.?(device, "vkCreateSwapchainKHR"));
    vk.DestroySwapchainKHR = @ptrCast(gd.?(device, "vkDestroySwapchainKHR"));
    vk.GetSwapchainImagesKHR = @ptrCast(gd.?(device, "vkGetSwapchainImagesKHR"));
    vk.AcquireNextImageKHR = @ptrCast(gd.?(device, "vkAcquireNextImageKHR"));
    vk.FlushMappedMemoryRanges = @ptrCast(gd.?(device, "vkFlushMappedMemoryRanges"));
    vk.InvalidateMappedMemoryRanges = @ptrCast(gd.?(device, "vkInvalidateMappedMemoryRanges"));
}

// ---------------------------------------------------------------------------
// Utility: check VkResult
// ---------------------------------------------------------------------------

pub fn check(result: c.VkResult) !void {
    if (result == c.VK_SUCCESS) return;
    switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY => return error.VkOutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => return error.VkOutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => return error.VkInitializationFailed,
        c.VK_ERROR_DEVICE_LOST => return error.VkDeviceLost,
        c.VK_ERROR_MEMORY_MAP_FAILED => return error.VkMemoryMapFailed,
        c.VK_ERROR_LAYER_NOT_PRESENT => return error.VkLayerNotPresent,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => return error.VkExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => return error.VkFeatureNotPresent,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => return error.VkIncompatibleDriver,
        c.VK_ERROR_TOO_MANY_OBJECTS => return error.VkTooManyObjects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => return error.VkFormatNotSupported,
        c.VK_ERROR_SURFACE_LOST_KHR => return error.VkSurfaceLost,
        c.VK_ERROR_OUT_OF_DATE_KHR => return error.VkOutOfDate,
        c.VK_SUBOPTIMAL_KHR => return, // treat as success
        else => return error.VkUnknownError,
    }
}

// ---------------------------------------------------------------------------
// Memory type selection
// ---------------------------------------------------------------------------

pub fn findMemoryType(
    mem_props: c.VkPhysicalDeviceMemoryProperties,
    type_bits: u32,
    required_flags: c.VkMemoryPropertyFlags,
) !u32 {
    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        const has_bit = (type_bits & (@as(u32, 1) << @intCast(i))) != 0;
        const has_flags = (mem_props.memoryTypes[i].propertyFlags & required_flags) == required_flags;
        if (has_bit and has_flags) return i;
    }
    return error.NoSuitableMemoryType;
}

// ---------------------------------------------------------------------------
// Buffer creation helper
// ---------------------------------------------------------------------------

pub const Buffer = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    size: c.VkDeviceSize = 0,
    device: c.VkDevice = null,

    pub fn init(
        device: c.VkDevice,
        mem_props: c.VkPhysicalDeviceMemoryProperties,
        size: c.VkDeviceSize,
        usage: c.VkBufferUsageFlags,
        mem_flags: c.VkMemoryPropertyFlags,
    ) !Buffer {
        var buf = Buffer{ .size = size, .device = device };

        const create_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        try check(vk.CreateBuffer.?(device, &create_info, null, &buf.buffer));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        vk.GetBufferMemoryRequirements.?(device, buf.buffer, &mem_reqs);

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = try findMemoryType(mem_props, mem_reqs.memoryTypeBits, mem_flags),
        };
        try check(vk.AllocateMemory.?(device, &alloc_info, null, &buf.memory));
        try check(vk.BindBufferMemory.?(device, buf.buffer, buf.memory, 0));

        return buf;
    }

    pub fn deinit(self: *Buffer) void {
        if (self.buffer != null) vk.DestroyBuffer.?(self.device, self.buffer, null);
        if (self.memory != null) vk.FreeMemory.?(self.device, self.memory, null);
        self.* = .{};
    }

    /// Upload data to this (host-visible) buffer.
    pub fn upload(self: Buffer, data: []const u8) !void {
        var mapped: ?*anyopaque = null;
        try check(vk.MapMemory.?(self.device, self.memory, 0, self.size, 0, &mapped));
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..data.len], data);
        vk.UnmapMemory.?(self.device, self.memory);
    }
};

// ---------------------------------------------------------------------------
// Single-shot command buffer (for one-time submissions)
// ---------------------------------------------------------------------------

pub fn beginOneShot(device: c.VkDevice, pool: c.VkCommandPool) !c.VkCommandBuffer {
    var cmd: c.VkCommandBuffer = undefined;
    const alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    try check(vk.AllocateCommandBuffers.?(device, &alloc_info, &cmd));

    const begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try check(vk.BeginCommandBuffer.?(cmd, &begin_info));
    return cmd;
}

pub fn submitOneShot(device: c.VkDevice, pool: c.VkCommandPool, queue: c.VkQueue, cmd: c.VkCommandBuffer) !void {
    try check(vk.EndCommandBuffer.?(cmd));

    const submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try check(vk.QueueSubmit.?(queue, 1, &submit_info, null));
    try check(vk.QueueWaitIdle.?(queue));
    vk.FreeCommandBuffers.?(device, pool, 1, &cmd);
}
