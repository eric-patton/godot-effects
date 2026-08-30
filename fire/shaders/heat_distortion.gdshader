// Heat shimmer in the hot air column above the flames. Reshapes a unit
// cylinder into a shell and refracts whatever is behind it (sky, stars,
// monoliths) with scrolling noise.
//
// Note: hint_screen_texture only contains the opaque pass, so this shell
// sits ABOVE the flame body — over the fire itself it would paint opaque
// background on top of the (transparent) flames and erase them.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, fog_disabled;

#include "res://fire/shaders/fire_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float shell_base = 30.0;
uniform float shell_height = 12.0;
uniform float shell_radius = 2.4;
uniform float strength = 0.02;
uniform float speed = 2.4;

varying float v_h;
varying vec2 v_dir;

void vertex() {
	float h = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec2 dir = normalize(VERTEX.xz + vec2(1e-5));
	float radius = shell_radius * mix(1.0, 0.55, h);
	VERTEX = vec3(dir.x * radius, shell_base + h * shell_height, dir.y * radius);
	v_h = h;
	v_dir = dir;
}

void fragment() {
	float n1 = fbm3(vec3(v_dir * 2.0, v_h * 5.0 - TIME * speed));
	float n2 = fbm3(vec3(v_dir * 2.0 + 4.3, v_h * 5.0 - TIME * speed * 1.13));

	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float mask = smoothstep(0.25, 0.7, ndv);
	mask *= smoothstep(0.0, 0.2, v_h) * (1.0 - smoothstep(0.7, 1.0, v_h));

	vec2 off = (vec2(n1, n2) - 0.5) * strength * mask;
	ALBEDO = texture(screen_tex, SCREEN_UV + off).rgb;
	// Only show where the offset actually bends something — the screen
	// texture is pre-fog, so an opaque shell would paint a dark band.
	float dmag = abs(n1 - 0.5) + abs(n2 - 0.5);
	ALPHA = mask * smoothstep(0.05, 0.35, dmag) * 0.55;
}
