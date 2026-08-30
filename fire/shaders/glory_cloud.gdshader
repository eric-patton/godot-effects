// The glory cloud: a slowly swirling luminous shroud around the upper
// column, bulging into a crown near the flame top — fire and cloud as one.
// Reshapes a unit cylinder with a bulge profile + noise undulation.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float cloud_base = 13.0;
uniform float cloud_height = 26.0;
uniform float cloud_radius = 4.0;
uniform float swirl_speed = 0.1;
uniform float rise_speed = 0.18;
uniform float noise_freq = 1.4;
uniform float noise_v = 2.2;
uniform float emission_energy = 0.45;
uniform vec3 col_lit : source_color = vec3(1.0, 0.62, 0.22);
uniform vec3 col_hot : source_color = vec3(1.0, 0.85, 0.55);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_h;
varying vec2 v_dir;

void vertex() {
	float h = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec2 dir = normalize(VERTEX.xz + vec2(1e-5));
	// Collar profile: widest just above the flame top.
	float prof = 0.55 + 0.45 * exp(-pow((h - 0.62) * 2.6, 2.0));
	float n = fbm3_3(vec3(dir * 1.1, h * 1.8 - TIME * 0.25));
	float radius = cloud_radius * prof * (1.0 + (n - 0.5) * 0.5);
	VERTEX = vec3(dir.x * radius, cloud_base + h * cloud_height, dir.y * radius);
	v_h = h;
	v_dir = dir;
}

void fragment() {
	// Swirl: rotate the sampling direction over time and height.
	float ang = TIME * swirl_speed * TAU + v_h * 2.5;
	mat2 rot = mat2(vec2(cos(ang), -sin(ang)), vec2(sin(ang), cos(ang)));
	vec2 sd = rot * v_dir;

	float n = fbm3(vec3(sd * noise_freq, v_h * noise_v - TIME * rise_speed));
	float n2 = fbm3(vec3(sd * noise_freq * 2.3 + 5.0, v_h * noise_v * 2.0 - TIME * rise_speed * 1.7));
	float dens = smoothstep(0.5, 0.85, n * 0.75 + n2 * 0.35);

	float fade = smoothstep(0.0, 0.2, v_h) * (1.0 - smoothstep(0.65, 1.0, v_h));
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = smoothstep(0.05, 0.5, ndv);

	vec3 col = mix(col_lit, col_hot, dens * 0.6);
	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * dens * fade * rim * flicker;
	ALPHA = clamp(dens * fade * rim * 0.55, 0.0, 1.0);
}
