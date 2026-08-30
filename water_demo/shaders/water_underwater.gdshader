shader_type canvas_item;

// Full-screen underwater overlay: blue fog/tint, caustics shimmer, vignette.
uniform float submerge = 0.0;
uniform bool caustics_on = true;
uniform vec3 tint : source_color = vec3(0.10, 0.40, 0.62);

uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;

void fragment() {
    vec3 col = texture(screen, SCREEN_UV).rgb;

    // tint toward water colour
    vec3 under = mix(col, col * tint * 2.2, 0.6);

    // animated caustics shimmer
    if (caustics_on) {
        vec2 uv = SCREEN_UV;
        float c = sin((uv.x + TIME * 0.06) * 38.0) * sin((uv.y + TIME * 0.05) * 34.0)
                + sin((uv.x - uv.y + TIME * 0.08) * 26.0);
        under += vec3(0.06, 0.09, 0.10) * max(c, 0.0);
    }

    // depth vignette
    float v = distance(SCREEN_UV, vec2(0.5));
    under *= 1.0 - v * 0.55;

    COLOR = vec4(mix(col, under, submerge), 1.0);
}
