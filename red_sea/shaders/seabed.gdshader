shader_type spatial;
// Opaque seabed / shore. Being OPAQUE is mandatory: it must appear in the water's
// hint_depth_texture / hint_screen_texture so the water can refract + absorb it and so
// the depth-difference foam has something to key against.
//
// Builds a shallow basin in the vertex stage: deep in the middle, rising ABOVE the water
// line into beaches near the z-ends (where the Israelites enter/leave) and gentle banks on
// the x-sides — plus low dunes. Where the rising sand nears the water surface, the water
// shader's depth-difference test paints shoreline foam for free.
//
// GROUND TEXTURING: PBR "sand" (dry, above the waterline) is blended to PBR "sea-floor" (wet,
// below it) by submersion. The SAME shader drives the corridor dry-floor too, with basin_enable=0
// so it stays flat — that keeps the corridor ground and the surrounding seabed visually unified and
// lets ONE set of LIVE-TUNING "GROUND" sliders control both.

uniform vec3  sand_color : source_color = vec3(1.0, 1.0, 1.0);   // tint over the SAND texture
uniform vec3  wet_color  : source_color = vec3(1.0, 1.0, 1.0);   // tint over the SEA-FLOOR texture
uniform float sea_level   = 6.0;
uniform sampler2D dune_tex : repeat_enable;

// NOTE: red_sea.gd pushes these from its constants at runtime (so the CPU height field matches);
// these defaults are just the current arena values for editor/standalone preview.
uniform float beach_start = 95.0;   // |z| where the sand starts rising
uniform float beach_end   = 128.0;  // |z| where it reaches full beach height
uniform float beach_height = 14.0;
uniform float side_start  = 300.0;  // |x| where the side banks start rising (pushed FAR out = open sea)
uniform float side_end    = 420.0;
uniform float side_height = 16.0;
uniform float dune_amp    = 0.7;
uniform float dune_scale  = 0.02;
uniform float basin_enable = 1.0;   // 1 = full basin (seabed); 0 = flat (the corridor dry floor)

// ---- PBR ground textures: dry SAND (above water) blended to wet SEA-FLOOR (below) ----------
uniform sampler2D sand_albedo  : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D sand_normal  : hint_normal,  repeat_enable, filter_linear_mipmap;
uniform sampler2D sand_rough   : repeat_enable, filter_linear_mipmap;   // smoothness map (we invert)
uniform sampler2D floor_albedo : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D floor_normal : hint_normal,  repeat_enable, filter_linear_mipmap;
uniform sampler2D floor_rough  : repeat_enable, filter_linear_mipmap;
uniform float sand_uv_scale  = 0.25;   // texture repeats per world unit (bigger = smaller features)
uniform float floor_uv_scale = 0.20;
uniform float ground_normal_strength : hint_range(0.0, 3.0) = 1.0;
uniform float ground_roughness : hint_range(0.0, 2.0) = 1.0;
uniform float wet_darken : hint_range(0.0, 1.0) = 0.6;   // how much to crush brightness where wet

// Wet sand: low roughness + sheen below the waterline reads as "wet" (dielectric, NOT metallic).
uniform sampler2D wetness_map : repeat_enable, filter_linear_mipmap;
uniform float wet_front = 6.0;   // waterline; = sea_level for the open seabed

// Animated caustics on the submerged sand (light -> added to EMISSION, faded out at the line).
uniform sampler2D caustic_tex : repeat_enable, filter_linear_mipmap;
uniform float caustic_scale    = 0.12;
uniform float caustic_strength = 0.5;
uniform vec2  caustic_scroll_a = vec2( 0.015, 0.009);
uniform vec2  caustic_scroll_b = vec2(-0.011, 0.014);
uniform vec3  caustic_tint : source_color = vec3(0.60, 0.95, 0.90);

varying float v_world_y;
varying vec2  v_world_xz;

void vertex() {
    // Seabed node sits at the origin with identity basis, so VERTEX.xz == world xz.
    vec3 p = VERTEX;
    float bz = smoothstep(beach_start, beach_end, abs(p.z)) * beach_height;
    float bx = smoothstep(side_start,  side_end,  abs(p.x)) * side_height;
    float dune = (textureLod(dune_tex, p.xz * dune_scale, 0.0).r - 0.5) * 2.0 * dune_amp;
    p.y += (bz + bx + dune) * basin_enable;   // basin_enable=0 -> stays flat (corridor dry floor)
    VERTEX.y = p.y;
    v_world_y  = p.y;
    v_world_xz = p.xz;
}

void fragment() {
    vec2 uv_s = v_world_xz * sand_uv_scale;
    vec2 uv_f = v_world_xz * floor_uv_scale;

    // submerged: below the waterline -> sea-floor texture; above -> sand. wet/damp: darken + sheen.
    float submerged = 1.0 - smoothstep(sea_level - 0.4, sea_level + 0.5, v_world_y);
    float wet  = 1.0 - smoothstep(wet_front - 1.2, wet_front + 0.4, v_world_y);
    float damp = 1.0 - smoothstep(wet_front + 0.4, wet_front + 2.5, v_world_y);
    float pool = texture(wetness_map, v_world_xz * 0.05).r;
    float w = clamp(wet + damp * 0.35 + wet * pool * 0.5, 0.0, 1.0);

    // ---- Albedo: sand <-> sea-floor, crushed where wet -----------------------------------
    vec3 a_sand  = texture(sand_albedo,  uv_s).rgb * sand_color;
    vec3 a_floor = texture(floor_albedo, uv_f).rgb * wet_color;
    ALBEDO = mix(a_sand, a_floor, submerged) * mix(1.0, wet_darken, w);

    // ---- Normal (tangent-space normal maps; PlaneMesh provides tangents) ------------------
    NORMAL_MAP = mix(texture(sand_normal, uv_s).rgb, texture(floor_normal, uv_f).rgb, submerged);
    NORMAL_MAP_DEPTH = ground_normal_strength;

    // ---- Roughness (smoothness maps, inverted) + wet sheen --------------------------------
    float r_sand  = 1.0 - texture(sand_rough,  uv_s).r;
    float r_floor = 1.0 - texture(floor_rough, uv_f).r;
    float rough = mix(r_sand, r_floor, submerged) * ground_roughness;
    ROUGHNESS = clamp(mix(rough, rough * 0.35, w), 0.0, 1.0);   // wet -> smoother/shinier
    SPECULAR  = mix(0.2, 0.7, w);                               // dielectric sheen, never METALLIC
    METALLIC  = 0.0;

    // ---- Caustics on the submerged sand ---------------------------------------------------
    float submersion = smoothstep(sea_level - 0.3, sea_level - 1.6, v_world_y); // 0 at line -> 1 deep
    vec2  cuv = v_world_xz * caustic_scale;
    float ca = texture(caustic_tex, cuv       + TIME * caustic_scroll_a).r;
    float cb = texture(caustic_tex, cuv * 1.7 + TIME * caustic_scroll_b).r;
    float caustic = pow(min(ca, cb), 2.0);             // min() of two layers -> shimmering filaments
    EMISSION = caustic_tint * (caustic * caustic_strength * submersion);
}
