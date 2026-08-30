// Billboarded flame tongues spawned by GPUParticles3D around the column.
// Each particle is a procedural teardrop eroded by fbm over its lifetime
// (INSTANCE_CUSTOM.y, requires anim_speed = 1 in the process material).
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float emission_energy = 3.0;
uniform vec3 col_dark : source_color = vec3(0.25, 0.01, 0.0);
uniform vec3 col_red : source_color = vec3(0.85, 0.10, 0.01);
uniform vec3 col_orange : source_color = vec3(1.0, 0.38, 0.02);
uniform vec3 col_gold : source_color = vec3(1.0, 0.75, 0.18);
uniform vec3 col_white : source_color = vec3(1.0, 0.97, 0.82);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_life;
varying float v_seed;

void vertex() {
	v_life = INSTANCE_CUSTOM.y;
	v_seed = hash13(vec3(float(INSTANCE_ID) * 0.1731 + 0.137, 7.7, 1.3));

	// Grow in fast, shrink out as the tongue dies.
	float s = smoothstep(0.0, 0.18, v_life) * (1.0 - 0.55 * smoothstep(0.35, 1.0, v_life));
	VERTEX.xy *= s;

	// Billboard facing the camera, keeping the particle's scale.
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
	// Teardrop mask: wide round base low on the quad, tapering tip above.
	vec2 c = UV - vec2(0.5, 0.62);
	c.x *= mix(1.5, 3.2, 1.0 - UV.y);
	float d = length(c);
	float blob = 1.0 - smoothstep(0.08, 0.46, d);

	float n = fbm3(vec3(UV * 3.0 + v_seed * 17.0, UV.y * 1.5 - TIME * 1.8 + v_seed * 9.0));
	float shape = blob * (0.35 + 1.1 * n);

	float erode = mix(0.3, 0.85, v_life);
	float a = smoothstep(erode, erode + 0.22, shape);
	a *= 1.0 - smoothstep(0.85, 1.0, v_life);

	float heat = shape * (1.55 - 0.9 * v_life);
	vec3 col = fire_ramp(clamp(heat, 0.0, 1.0), col_dark, col_red, col_orange, col_gold, col_white);
	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * flicker;
	ALPHA = clamp(a, 0.0, 1.0);
}
