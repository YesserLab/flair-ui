#version 450
#extension GL_ARB_separate_shader_objects : enable

// ---------------------------------------------------------------------------
// Input: per-vertex attributes
// ---------------------------------------------------------------------------
layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_gradient_coord;
layout(location = 2) in vec4 in_color;

// ---------------------------------------------------------------------------
// Push constants: orthographic projection matrix
// ---------------------------------------------------------------------------
layout(push_constant) uniform PushConstants {
    mat4 proj;
} pc;

// ---------------------------------------------------------------------------
// Output to fragment shader
// ---------------------------------------------------------------------------
layout(location = 0) out vec2 frag_gradient_coord;
layout(location = 1) out vec4 frag_color;

void main() {
    gl_Position = pc.proj * vec4(in_position, 0.0, 1.0);
    frag_gradient_coord = in_gradient_coord;
    frag_color = in_color;
}
