// The main flame column. Meant for a unit cylinder (radius 1, height 1,
// no caps) — the shader reshapes it: tapered profile, noise-displaced
// silhouette, whole-column sway, and alpha erosion that tears the top
// into licking tongues. Used twice (outer shell + hot inner core).
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform float height = 30.0;
uniform float base_radius = 2.6;
uniform float taper : hint_range(0.1, 1.0) = 0.62;
uniform float base_flare = 0.12;
uniform float disp_base : hint_range(0.0, 1.0) = 0.16;
uniform float disp_top : hint_range(0.0, 1.0) = 0.55;
uniform float sway_amount = 1.7;
uniform float twist = 2.0;
uniform float rise_speed = 1.1;
uniform float vert_noise_freq = 1.6;
uniform float vert_noise_v = 2.4;
uniform float detail_freq = 2.2;
uniform float detail_v = 3.0;
uniform float scroll = 1.4;
uniform float warp_amount = 1.15;
uniform float erosion_start : hint_range(0.0, 1.0) = 0.45;
uniform float erosion_max : hint_range(0.0, 1.0) = 0.5;
uniform float edge_soft = 0.18;
uniform float emission_energy = 3.2;
uniform float core_boost = 0.0;
uniform vec3 col_dark : source_color = vec3(0.25, 0.01, 0.0);
uniform vec3 col_red : source_color = vec3(0.85, 0.10, 0.01);
uniform vec3 col_orange : source_color = vec3(1.0, 0.38, 0.02);
uniform vec3 col_gold : source_color = vec3(1.0, 0.75, 0.18);
uniform vec3 col_white : source_color = vec3(1.0, 0.97, 0.82);
instance uniform float flicker : hint_range(0.0, 3.0) = 1.0;

varying float v_h;
varying vec2 v_dir;
varying float v_disp;

void vertex() {
	float h = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec2 dir = normalize(VERTEX.xz + vec2(1e-5));

	// Swirl the noise domain so displacement spirals upward.
	float ang = twist * h + TIME * 0.25;
	mat2 rot = mat2(vec2(cos(ang), -sin(ang)), vec2(sin(ang), cos(ang)));
	vec2 ndir = rot * dir;
	float n = fbm3_3(vec3(ndir * vert_noise_freq, h * vert_noise_v - TIME * rise_speed));
	v_disp = n;

	float prof = mix(1.0, taper, smoothstep(0.0, 0.85, h));
	prof += base_flare * exp(-h * 7.0);
	float damp = mix(disp_base, disp_top, h);
	float radius = max(base_radius * prof * (1.0 + (n - 0.5) * 2.0 * damp), 0.02);

	// Whole-column lashing; quadratic in height so the base stays planted.
	vec2 sway = vec2(
			vnoise3(vec3(0.0, 3.7, TIME * 0.32)) - 0.5,
			vnoise3(vec3(9.1, 0.0, TIME * 0.32)) - 0.5)
			* (2.0 * sway_amount) * h * h;

	VERTEX = vec3(dir.x * radius + sway.x, h * height, dir.y * radius + sway.y);
	v_h = h;
	v_dir = dir;
}

void fragment() {
	// Sample noise on the unit circle (seamless around the column).
	vec3 p = vec3(v_dir * detail_freq, v_h * detail_v - TIME * scroll);
	float q = fbm3(p + vec3(0.0, 0.0, 1.7));
	float n = fbm3(p + warp_amount * vec3(q, q * 0.7, q));

	float heat = n * (1.35 - 0.65 * v_h) + core_boost * (1.0 - 0.5 * v_h);

	// Erosion rises with height: solid base, ragged licking top.
	float er = mix(-0.15, erosion_max, smoothstep(erosion_start, 1.0, v_h));
	float a = smoothstep(er, er + edge_soft, n);

	// Noisy grazing-angle erosion so the silhouette never reads as a clean rim.
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	a *= smoothstep(0.0, 0.45, ndv + (n - 0.5) * 0.6);

	a *= smoothstep(0.0, 0.06, v_h);
	a *= 1.0 - smoothstep(0.92, 1.0, v_h);

	vec3 col = fire_ramp(clamp(heat, 0.0, 1.0), col_dark, col_red, col_orange, col_gold, col_white);
	ALBEDO = vec3(0.0);
	EMISSION = col * emission_energy * flicker;
	ALPHA = clamp(a, 0.0, 1.0);
}
