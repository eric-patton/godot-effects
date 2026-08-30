// Additive glow disc under the pillar: hot coals breakup + radial light
// pool that pulses with the same flicker as the lights.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float emission_energy = 1.5;
uniform vec3 col_pool : source_color = vec3(1.0, 0.38, 0.05);
uniform vec3 col_coals : source_color = vec3(1.0, 0.72, 0.2);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

void fragment() {
	vec2 c = UV - 0.5;
	float d = clamp(length(c) * 2.0, 0.0, 1.0);
	float fall = pow(1.0 - d, 1.7);

	float n = fbm3(vec3(UV * 7.0, TIME * 0.8));
	float coals = smoothstep(0.45, 0.85, n) * smoothstep(0.6, 0.15, d);

	vec3 col = col_pool * fall * 1.2 + col_coals * coals * 2.0;
	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * flicker;
	ALPHA = clamp(fall * 1.2 + coals, 0.0, 1.0);
}
