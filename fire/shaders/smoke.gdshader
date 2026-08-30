// Dark smoke billows above the pillar. Alpha-blended and shaded so the
// scene's lights touch it; the underside is tinted by fake fire glow that
// fades as each puff rises and cools.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled,
		diffuse_lambert_wrap;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float opacity : hint_range(0.0, 1.0) = 0.28;
uniform vec3 smoke_color : source_color = vec3(0.13, 0.11, 0.10);
uniform vec3 glow_color : source_color = vec3(1.0, 0.42, 0.08);
uniform float glow_energy = 1.2;
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_life;
varying float v_seed;

void vertex() {
	v_life = INSTANCE_CUSTOM.y;
	v_seed = hash13(vec3(float(INSTANCE_ID) * 0.291 + 0.41, 9.1, 2.7));

	// Puffs expand as they rise.
	VERTEX.xy *= mix(0.55, 1.9, v_life);

	mat4 mv = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	mv = mv * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = mv;
}

void fragment() {
	vec2 c = UV - 0.5;
	float d = length(c) * 2.0;
	float n = fbm3(vec3(UV * 2.4 + v_seed * 31.0, TIME * 0.22 + v_seed * 13.0));

	float m = 1.0 - smoothstep(0.2, 0.95, d);
	float a = m * smoothstep(0.42, 0.88, n * (1.2 - 0.4 * d));
	a *= smoothstep(0.0, 0.22, v_life) * (1.0 - smoothstep(0.5, 0.95, v_life));

	ALBEDO = smoke_color * (0.7 + 0.6 * n);
	ROUGHNESS = 1.0;

	// UV.y = 1 is the bottom of the quad: light it like fire from below.
	float under = pow(clamp(UV.y, 0.0, 1.0), 1.6);
	float cool = pow(1.0 - v_life, 1.5);
	EMISSION = glow_color * glow_energy * flicker * under * cool * m;

	ALPHA = clamp(a * opacity, 0.0, 1.0);
}
