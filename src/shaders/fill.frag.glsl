#version 450
#extension GL_ARB_separate_shader_objects : enable

// ---------------------------------------------------------------------------
// Input from vertex shader
// ---------------------------------------------------------------------------
layout(location = 0) in vec2 frag_gradient_coord;
layout(location = 1) in vec4 frag_color;

// ---------------------------------------------------------------------------
// Paint uniform buffer
// ---------------------------------------------------------------------------
struct ColorStop {
    float position;
    float _pad0;
    float _pad1;
    float _pad2;
    vec4  color;
};

#define MAX_STOPS 16

layout(set = 0, binding = 0) uniform PaintData {
    int   gradient_type;    // 0 = solid, 1 = linear, 2 = radial
    int   num_stops;
    int   _pad0;
    int   _pad1;
    vec2  gradient_p0;      // linear: start point; radial: center (in pixel coords)
    vec2  gradient_p1;      // linear: end point
    float gradient_radius;  // radial only
    float _pad2;
    float _pad3;
    float _pad4;
    ColorStop stops[MAX_STOPS];
} paint;

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------
layout(location = 0) out vec4 out_color;

// ---------------------------------------------------------------------------
// Gradient sampling
// ---------------------------------------------------------------------------
vec4 sampleStops(float t) {
    t = clamp(t, 0.0, 1.0);
    if (paint.num_stops <= 0) return frag_color;
    if (paint.num_stops == 1) return paint.stops[0].color;

    // Find bracketing stops
    int i = 0;
    for (i = 0; i < paint.num_stops - 1; i++) {
        if (t <= paint.stops[i + 1].position) break;
    }
    if (i >= paint.num_stops - 1) return paint.stops[paint.num_stops - 1].color;

    float a_pos = paint.stops[i].position;
    float b_pos = paint.stops[i + 1].position;
    float range = b_pos - a_pos;
    if (range < 1e-6) return paint.stops[i].color;

    float local_t = (t - a_pos) / range;
    return mix(paint.stops[i].color, paint.stops[i + 1].color, local_t);
}

void main() {
    if (paint.gradient_type == 0) {
        // Solid color — use the per-vertex color
        out_color = frag_color;
    } else if (paint.gradient_type == 1) {
        // Linear gradient — gradient_coord.x is already the normalized t
        out_color = sampleStops(frag_gradient_coord.x);
    } else {
        // Radial gradient — gradient_coord.x is the normalized distance
        out_color = sampleStops(frag_gradient_coord.x);
    }
}
