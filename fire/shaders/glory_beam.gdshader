// The god-beam: a soft column of light continuing upward from the flame
// top toward the sky. Reshapes a unit cylinder; brightest when looking
// through its center (fresnel-weighted), with slow vertical streaking.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float beam_base = 22.0;
uniform float beam_height = 45.0;
uniform float beam_radius = 1.9;
uniform float emission_energy = 1.8;
uniform vec3 col_inner : source_color = vec3(1.0, 0.92, 0.7);
uniform vec3 col_outer : source_color = vec3(1.0, 0.6, 0.2);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_h;
varying vec2 v_dir;

void vertex() {
	float h = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec2 dir = normalize(VERTEX.xz + vec2(1e-5));
	float radius = beam_radius * mix(1.0, 0.75, h);
	VERTEX = vec3(dir.x * radius, beam_base + h * beam_height, dir.y * radius);
	v_h = h;
	v_dir = dir;
}

void fragment() {
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(ndv, 2.2);
	float streaks = fbm3(vec3(v_dir * 1.2, v_h * 6.0 - TIME * 0.6));
	float fade = smoothstep(0.0, 0.12, v_h) * (1.0 - smoothstep(0.5, 1.0, v_h));

	vec3 col = mix(col_outer, col_inner, core);
	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * (0.7 + 0.5 * streaks) * fade * core * flicker;
	ALPHA = clamp(fade * core, 0.0, 1.0);
}
