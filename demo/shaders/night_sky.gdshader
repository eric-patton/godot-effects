// Procedural night sky: horizon-to-zenith gradient, twinkling stars,
// a faint milky-way band, and a small moon with halo.
shader_type sky;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform vec3 horizon_color : source_color = vec3(0.05, 0.075, 0.13);
uniform vec3 zenith_color : source_color = vec3(0.004, 0.007, 0.018);
uniform float star_density = 240.0;
uniform float star_threshold : hint_range(0.9, 1.0) = 0.985;
uniform vec3 moon_dir = vec3(0.45, 0.42, -0.79);
uniform vec3 moon_color : source_color = vec3(0.82, 0.88, 1.0);

void sky() {
	vec3 d = normalize(EYEDIR);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, zenith_color, pow(up, 0.45));

	// Stars: sparse bright cells, fading near the horizon.
	float h = hash13(floor(d * star_density));
	float star = smoothstep(star_threshold, 1.0, h);
	float tw = 0.7 + 0.3 * sin(TIME * 2.0 + h * 80.0);
	col += vec3(0.9, 0.95, 1.0) * star * tw * smoothstep(0.02, 0.25, up) * 0.8;

	// Faint milky-way band.
	vec3 band_n = normalize(vec3(0.5, 0.25, 0.83));
	float band = exp(-pow(dot(d, band_n) * 3.5, 2.0));
	float wisp = fbm3(d * 7.0);
	col += vec3(0.10, 0.12, 0.18) * band * wisp * smoothstep(0.0, 0.2, up);

	// Moon disc + halo.
	float md = dot(d, normalize(moon_dir));
	col += moon_color * smoothstep(0.9994, 0.9997, md) * 2.0;
	col += moon_color * pow(max(md, 0.0), 400.0) * 0.25;

	COLOR = col;
}
