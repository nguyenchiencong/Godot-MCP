shader_type canvas_item;

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float glow_power : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec2 centered_uv = (UV - 0.5) * 2.0;
	float dist = length(centered_uv);
	float glow = 1.0 - smoothstep(0.0, 1.0, dist);
	
	vec4 color = base_color;
	color.rgb *= (1.0 + glow * glow_power);
	
	COLOR = color;
}
