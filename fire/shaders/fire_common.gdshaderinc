// Shared procedural-noise helpers for the pillar-of-fire shaders.

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(
			mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
			mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
			u.z);
}

// 5-octave fbm for fragment detail.
float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 5; k++) {
		v += a * vnoise3(p);
		p = p * 2.07 + vec3(11.3, 7.1, 5.9);
		a *= 0.52;
	}
	return v;
}

// Cheaper 3-octave fbm for vertex displacement.
float fbm3_3(vec3 p) {
	float v = 0.0;
	float a = 0.55;
	for (int k = 0; k < 3; k++) {
		v += a * vnoise3(p);
		p = p * 2.13 + vec3(7.7, 3.1, 9.2);
		a *= 0.5;
	}
	return v;
}

// Blackbody-ish fire gradient: dark -> red -> orange -> gold -> white.
vec3 fire_ramp(float t, vec3 c_dark, vec3 c_red, vec3 c_orange, vec3 c_gold, vec3 c_white) {
	vec3 c = mix(c_dark, c_red, smoothstep(0.0, 0.30, t));
	c = mix(c, c_orange, smoothstep(0.25, 0.55, t));
	c = mix(c, c_gold, smoothstep(0.50, 0.78, t));
	c = mix(c, c_white, smoothstep(0.74, 1.0, t));
	return c;
}
