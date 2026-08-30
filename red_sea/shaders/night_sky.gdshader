shader_type sky;
// Procedural sky for the Red Sea prototype. Reproduces the old ProceduralSkyMaterial gradient
// (zenith -> horizon -> ground) so the DAY look is unchanged, then layers a procedural STARFIELD,
// a soft MILKY WAY band and a MOON that all fade in with the `night` uniform (0 day -> 1 night).
//
// `night`, `zenith_color`, `horizon_color`, `ground_color` are driven from red_sea.gd's mood
// cross-fade (_apply_mood / _apply_flash) so the sky tracks the storm-night transition + lightning.
//
// disable_fog: the scene's exponential fog is DARK at night (fog_light ~ 0.10,0.13,0.20); letting it
// tint the sky would wash the stars out, so we keep the sky un-fogged (the hazy DISTANT-TERRAIN look
// comes from fog_aerial_perspective on the geometry, not from fogging the sky itself).
//
// No TIME is used on purpose: a static starfield means the radiance cubemap (sky-based ambient) only
// rebuilds when a uniform actually changes (during a fade/flash), not every frame.
render_mode disable_fog;

// ---- Gradient (matches the mood fade) -----------------------------------------------
uniform vec3  zenith_color  : source_color = vec3(0.32, 0.50, 0.82);
uniform vec3  horizon_color : source_color = vec3(0.78, 0.82, 0.85);
uniform vec3  ground_color  : source_color = vec3(0.70, 0.70, 0.66);
uniform float horizon_falloff : hint_range(0.2, 2.0) = 0.5;   // higher -> blue sky hugs the zenith more

// ---- Night extras (all scaled by `night`) -------------------------------------------
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform float star_brightness : hint_range(0.0, 4.0) = 1.5;
uniform vec3  star_warm : source_color = vec3(1.00, 0.92, 0.82);
uniform vec3  star_cool : source_color = vec3(0.78, 0.86, 1.00);
uniform float milkyway_brightness : hint_range(0.0, 2.0) = 0.55;
uniform vec3  milkyway_color : source_color = vec3(0.55, 0.62, 0.85);
uniform vec3  moon_color : source_color = vec3(0.86, 0.90, 1.00);
uniform float moon_radius : hint_range(0.0, 0.3) = 0.045;     // angular radius of the disc, in radians
uniform float moon_glow : hint_range(0.0, 2.0) = 0.55;

// ---- hashes / noise ------------------------------------------------------------------
vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash33(i + vec3(0.0, 0.0, 0.0)).x;
	float n100 = hash33(i + vec3(1.0, 0.0, 0.0)).x;
	float n010 = hash33(i + vec3(0.0, 1.0, 0.0)).x;
	float n110 = hash33(i + vec3(1.0, 1.0, 0.0)).x;
	float n001 = hash33(i + vec3(0.0, 0.0, 1.0)).x;
	float n101 = hash33(i + vec3(1.0, 0.0, 1.0)).x;
	float n011 = hash33(i + vec3(0.0, 1.0, 1.0)).x;
	float n111 = hash33(i + vec3(1.0, 1.0, 1.0)).x;
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += a * value_noise(p);
		p *= 2.02;
		a *= 0.5;
	}
	return s;
}

// One layer of stars: grid the view direction, drop one jittered point per cell (kept well inside the
// cell so single-cell sampling never clips it), draw a soft round core with hash-varied brightness/tint.
vec3 star_layer(vec3 dir, float density, float coverage, float seed, float core) {
	vec3 g = dir * density + seed;
	vec3 id = floor(g);
	vec3 f = fract(g) - 0.5;
	vec3 h = hash33(id + seed);
	float present = step(1.0 - coverage, h.x);
	vec3 center = (h - 0.5) * (1.0 - core * 2.0 - 0.1);
	float d = length(f - center);
	float spark = present * smoothstep(core, 0.0, d);
	spark *= 0.35 + 0.65 * h.y;                       // dimmer + brighter stars
	return mix(star_cool, star_warm, h.z) * spark;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = clamp(dir.y, -1.0, 1.0);

	// Base gradient: sky dome above the horizon, ground tint below it.
	vec3 col;
	if (up >= 0.0) {
		col = mix(horizon_color, zenith_color, pow(up, horizon_falloff));
	} else {
		col = mix(horizon_color, ground_color, pow(-up, 0.45));
	}

	// Stars / milky way / moon: night-only, sky-dome-only, and skipped in the radiance cubemap pass
	// (keeps them out of the ambient/reflection probe and off the per-frame cubemap cost).
	if (night > 0.001 && !AT_CUBEMAP_PASS) {
		float dome = smoothstep(-0.02, 0.18, up);     // fade out toward / below the horizon
		float n = night * dome;

		// Milky Way: a soft fbm band along a tilted great circle.
		vec3 axis = normalize(vec3(0.5, 0.45, 0.74));
		float band = abs(dot(dir, axis));
		float mw = smoothstep(0.55, 0.0, band);
		mw *= smoothstep(0.30, 0.95, fbm(dir * 6.0));
		col += milkyway_color * mw * milkyway_brightness * n;

		// Stars: a few layers for size variety; denser inside the milky-way band.
		vec3 stars = vec3(0.0);
		stars += star_layer(dir, 140.0, 0.10, 11.3, 0.05);
		stars += star_layer(dir, 260.0, 0.14, 47.1, 0.04) * 0.8;
		stars += star_layer(dir, 460.0, 0.20, 91.7, 0.03) * 0.5;
		stars *= 1.0 + 1.2 * mw;
		col += stars * star_brightness * n;

		// Moon: a soft disc + halo placed where the directional light comes from.
		if (LIGHT0_ENABLED) {
			vec3 moon_dir = normalize(-LIGHT0_DIRECTION);
			float ang = acos(clamp(dot(dir, moon_dir), -1.0, 1.0));
			float disc = smoothstep(moon_radius, moon_radius * 0.7, ang);
			float halo = exp(-ang * 14.0) * moon_glow;
			col = mix(col, moon_color, clamp(disc, 0.0, 1.0) * night);
			col += moon_color * halo * night;
		}
	}

	COLOR = col;
}
