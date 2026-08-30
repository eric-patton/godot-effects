// Tiny glowing embers carried up by the fire. Soft HDR dots that twinkle
// and fade out over their lifetime.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float emission_energy = 8.0;
uniform vec3 col_hot : source_color = vec3(1.0, 0.85, 0.45);
uniform vec3 col_cool : source_color = vec3(1.0, 0.25, 0.03);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_life;
varying float v_seed;

void vertex() {
	v_life = INSTANCE_CUSTOM.y;
	v_seed = hash13(vec3(float(INSTANCE_ID) * 0.731 + 0.07, 3.3, 5.1));

	float s = smoothstep(0.0, 0.08, v_life) * (1.0 - smoothstep(0.65, 1.0, v_life));
	VERTEX.xy *= s;

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
	vec2 c = (UV - 0.5) * 2.0;
	float d2 = dot(c, c);
	float m = exp(-d2 * 6.0);

	float tw = 0.6 + 0.4 * sin(TIME * (14.0 + v_seed * 9.0) + v_seed * 50.0);
	vec3 col = mix(col_cool, col_hot, v_seed * 0.7 + 0.3 - v_life * 0.5);

	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * m * tw * flicker;
	ALPHA = clamp(m * (1.0 - v_life * 0.5), 0.0, 1.0);
}
