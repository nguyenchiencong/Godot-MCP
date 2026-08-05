shader_type canvas_item;
// Runtime test shader for the MCP shader tools (Phase B).
// Deliberately exercises many uniform kinds: scalars, vectors, colors,
// samplers, hint_range, source_color and uniform arrays.

uniform float speed : hint_range(0.0, 10.0, 0.5) = 2.0;
uniform int steps : hint_range(1, 64) = 4;
uniform bool glow = true;
uniform vec2 offset = vec2(0.5, 0.5);
uniform vec3 scale_3d = vec3(1.0, 1.0, 1.0);
uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.25, 1.0);
uniform sampler2D albedo_tex : filter_linear, repeat_enable;
uniform float weights[3];
uniform vec2 anchors[2];

void fragment() {
	COLOR = tint;
	COLOR.a *= clamp(speed * 0.1, 0.0, 1.0);
}
