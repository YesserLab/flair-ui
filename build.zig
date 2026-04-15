const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Translate C headers to Zig modules (replaces @cImport, deprecated in 0.16)
    // ---------------------------------------------------------------------------

    // Vulkan bindings: VK_NO_PROTOTYPES is set so we load function pointers manually.
    const translate_vulkan = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/vulkan.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_vulkan.defineCMacro("VK_NO_PROTOTYPES", "1");
    const vulkan_c_mod = translate_vulkan.createModule();

    // Wayland + xdg-shell bindings.
    const translate_wayland = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/wayland.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_wayland.addIncludePath(b.path("src/platform/generated"));
    translate_wayland.addIncludePath(b.path("src/platform"));
    const wayland_c_mod = translate_wayland.createModule();

    // ---------------------------------------------------------------------------
    // Compile GLSL shaders to SPIR-V
    // ---------------------------------------------------------------------------
    const compile_vert = b.addSystemCommand(&.{
        "glslangValidator",
        "--target-env", "vulkan1.0",
        "-V",
        "-o",
        "src/shaders/fill.vert.spv",
        "src/shaders/fill.vert.glsl",
    });

    const compile_frag = b.addSystemCommand(&.{
        "glslangValidator",
        "--target-env", "vulkan1.0",
        "-V",
        "-o",
        "src/shaders/fill.frag.spv",
        "src/shaders/fill.frag.glsl",
    });

    // ---------------------------------------------------------------------------
    // Library
    // ---------------------------------------------------------------------------
    const lib = b.addStaticLibrary(.{
        .name = "flair-ui",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("vulkan_c", vulkan_c_mod);
    lib.root_module.addImport("wayland_c", wayland_c_mod);

    lib.step.dependOn(&compile_vert.step);
    lib.step.dependOn(&compile_frag.step);

    // Include generated Wayland protocol C sources
    lib.addCSourceFiles(.{
        .files = &.{"src/platform/generated/xdg-shell-protocol.c"},
        .flags = &.{"-std=c99"},
    });
    lib.addIncludePath(b.path("src/platform/generated"));
    lib.addIncludePath(b.path("src/platform"));
    lib.linkSystemLibrary("vulkan");
    lib.linkSystemLibrary("wayland-client");
    lib.linkLibC();

    b.installArtifact(lib);

    // ---------------------------------------------------------------------------
    // Example: basic_shapes
    // ---------------------------------------------------------------------------
    const basic_shapes_exe = b.addExecutable(.{
        .name = "basic_shapes",
        .root_source_file = b.path("examples/basic_shapes.zig"),
        .target = target,
        .optimize = optimize,
    });
    basic_shapes_exe.root_module.addImport("flair-ui", &lib.root_module);
    basic_shapes_exe.addCSourceFiles(.{
        .files = &.{"src/platform/generated/xdg-shell-protocol.c"},
        .flags = &.{"-std=c99"},
    });
    basic_shapes_exe.addIncludePath(b.path("src/platform/generated"));
    basic_shapes_exe.addIncludePath(b.path("src/platform"));
    basic_shapes_exe.linkSystemLibrary("vulkan");
    basic_shapes_exe.linkSystemLibrary("wayland-client");
    basic_shapes_exe.linkLibC();
    basic_shapes_exe.step.dependOn(&compile_vert.step);
    basic_shapes_exe.step.dependOn(&compile_frag.step);
    b.installArtifact(basic_shapes_exe);

    // ---------------------------------------------------------------------------
    // Example: window_events
    // ---------------------------------------------------------------------------
    const window_events_exe = b.addExecutable(.{
        .name = "window_events",
        .root_source_file = b.path("examples/window_events.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_events_exe.root_module.addImport("flair-ui", &lib.root_module);
    window_events_exe.addCSourceFiles(.{
        .files = &.{"src/platform/generated/xdg-shell-protocol.c"},
        .flags = &.{"-std=c99"},
    });
    window_events_exe.addIncludePath(b.path("src/platform/generated"));
    window_events_exe.addIncludePath(b.path("src/platform"));
    window_events_exe.linkSystemLibrary("vulkan");
    window_events_exe.linkSystemLibrary("wayland-client");
    window_events_exe.linkLibC();
    window_events_exe.step.dependOn(&compile_vert.step);
    window_events_exe.step.dependOn(&compile_frag.step);
    b.installArtifact(window_events_exe);

    // ---------------------------------------------------------------------------
    // Run steps
    // ---------------------------------------------------------------------------
    const run_basic = b.addRunArtifact(basic_shapes_exe);
    run_basic.step.dependOn(b.getInstallStep());
    const run_basic_step = b.step("run-basic", "Run the basic_shapes example");
    run_basic_step.dependOn(&run_basic.step);

    const run_window = b.addRunArtifact(window_events_exe);
    run_window.step.dependOn(b.getInstallStep());
    const run_window_step = b.step("run-window", "Run the window_events example");
    run_window_step.dependOn(&run_window.step);
}
