// Wrapper header for Vulkan C bindings.
// VK_NO_PROTOTYPES is passed via -D flag from build.zig (translate-c step),
// so function pointers are used instead of direct prototypes.
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_wayland.h>
