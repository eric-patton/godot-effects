shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

// ---- palette ----
uniform vec3 shallow_color : source_color = vec3(0.30, 0.78, 0.88);
uniform vec3 deep_color : source_color = vec3(0.05, 0.34, 0.62);
uniform vec3 foam_color : source_color = vec3(0.93, 0.98, 1.0);
uniform vec3 sky_tint : source_color = vec3(0.60, 0.80, 0.96);
uniform float absorption = 0.26;
uniform float max_depth = 8.0;
uniform float fresnel_power = 4.0;
uniform float ripple_strength = 0.05;
uniform float ripple_scale = 1.4;
uniform float edge_foam_dist = 0.7;
uniform float surface_detail = 1.0;
uniform float time_scale = 1.0;
uniform bool is_ice = false;

// ---- reflection / refraction ----
uniform int reflection_mode = 1;   // 0 off, 1 SSR, 2 planar
uniform int ssr_steps = 24;
uniform float ssr_step = 0.35;
uniform float ssr_thickness = 0.7;
uniform float reflection_strength = 0.9;
uniform float refraction_strength = 0.05;
uniform sampler2D reflection_tex;  // planar (mode 2)
uniform mat4 reflection_vp;        // planar (mode 2)

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

// class tags (match WaterClass)
const int C_CALM = 0;
const int C_RIVER = 1;
const int C_WATERFALL = 2;
const int C_LIP = 3;
const int C_PLUNGE = 4;
const int C_SHORE = 5;
const int C_RAPIDS = 6;

varying vec3 v_world;
varying vec4 v_data; // RG=flow dir(0..1), B=class/8, A=reserved

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_data = COLOR;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }

vec3 calm_normal(vec2 p, float t) {
    float s = ripple_scale;
    float rx = sin(p.x * s + t) + sin((p.x * 0.7 + p.y * 1.3) * s - t * 1.2);
    float rz = cos(p.y * s * 1.1 - t * 0.9) + sin((p.x * 1.1 - p.y * 0.6) * s + t * 0.8);
    float amp = ripple_strength * surface_detail;
    return normalize(vec3(rx * amp, 1.0, rz * amp));
}

vec3 flow_normal(vec2 p, vec2 flow, float t) {
    vec2 dir = normalize(flow + vec2(0.0001, 0.0));
    float spd = 1.2 + length(flow) * 2.5;
    vec2 fp = p - dir * t * spd;
    float s = ripple_scale * 1.3;
    // ripples stretched across flow, travelling along it
    float along = sin(dot(fp, dir) * s * 1.6 - t * 3.0);
    float across = sin(dot(fp, vec2(-dir.y, dir.x)) * s * 3.0 + t);
    float amp = ripple_strength * surface_detail * 1.6;
    vec3 n = vec3(0.0, 1.0, 0.0);
    n.x += (along * dir.x + across * -dir.y) * amp;
    n.z += (along * dir.y + across * dir.x) * amp;
    return normalize(n);
}

vec3 waterfall_normal(vec3 wp, float t) {
    float cols = sin(wp.x * 6.0 + wp.z * 6.0) * 0.5;
    float fall = sin(wp.y * 4.0 - t * 9.0) * 0.4;
    float amp = ripple_strength * surface_detail;
    return normalize(vec3(cols * amp * 2.0, 1.0, fall * amp));
}

float eye_depth(vec2 uv, mat4 inv_proj) {
    float d = texture(depth_tex, uv).x;
    vec3 ndc = vec3(uv * 2.0 - 1.0, d);
    vec4 v = inv_proj * vec4(ndc, 1.0);
    return v.z / v.w; // negative in front
}

vec3 ssr_march(vec3 vpos, vec3 vdir, mat4 proj, mat4 inv_proj, out bool hit) {
    hit = false;
    vec3 p = vpos;
    float st = ssr_step;
    for (int i = 0; i < 128; i++) {
        if (i >= ssr_steps) break;
        p += vdir * st;
        if (p.z > -0.01) break;
        vec4 cp = proj * vec4(p, 1.0);
        if (cp.w <= 0.0) break;
        vec2 uv = (cp.xy / cp.w) * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;
        float scene_z = eye_depth(uv, inv_proj);
        float diff = scene_z - p.z;
        if (diff > 0.0 && diff < ssr_thickness) { hit = true; return texture(screen_tex, uv).rgb; }
        st *= 1.06;
    }
    return vec3(0.0);
}

void fragment() {
    float t = TIME * time_scale;
    vec2 flow = v_data.rg * 2.0 - 1.0;
    int cls = int(round(v_data.b * 8.0));
    bool ice = is_ice || v_data.a > 0.5; // per-cell frozen flag in COLOR.a

    // --- surface normal per class ---
    vec3 wn;
    if (ice) wn = vec3(0.0, 1.0, 0.0);
    else if (cls == C_WATERFALL || cls == C_LIP) wn = waterfall_normal(v_world, t);
    else if (cls == C_RIVER || cls == C_RAPIDS) wn = flow_normal(v_world.xz, flow, t);
    else wn = calm_normal(v_world.xz, t);
    vec3 nv = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
    NORMAL = nv;

    // --- thickness ---
    float scene_eye = -eye_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
    float surf_eye = -VERTEX.z;
    float thickness = max(0.0, scene_eye - surf_eye);
    float t_absorb = 1.0 - exp(-absorption * thickness);

    // --- refraction ---
    vec2 refr_uv = SCREEN_UV + nv.xy * refraction_strength * surface_detail;
    if (-eye_depth(refr_uv, INV_PROJECTION_MATRIX) < surf_eye) refr_uv = SCREEN_UV;
    vec3 bottom = texture(screen_tex, refr_uv).rgb;
    vec3 through = mix(bottom * mix(vec3(1.0), shallow_color, 0.4), deep_color, t_absorb);

    // --- reflection ---
    vec3 view_dir = normalize(VERTEX);
    vec3 refl = reflect(view_dir, nv);
    vec3 refl_world = normalize((INV_VIEW_MATRIX * vec4(refl, 0.0)).xyz);
    float up = clamp(refl_world.y, 0.0, 1.0);
    vec3 skycol = mix(sky_tint * 1.1, sky_tint * 0.65 + vec3(0.0, 0.0, 0.18), up);
    vec3 reflection = skycol;
    if (reflection_mode == 1) {
        bool hit = false;
        vec3 ssr = ssr_march(VERTEX, refl, PROJECTION_MATRIX, INV_PROJECTION_MATRIX, hit);
        if (hit) reflection = mix(skycol, ssr, 0.95);
    } else if (reflection_mode == 2) {
        vec4 rc = reflection_vp * vec4(v_world, 1.0);
        if (rc.w > 0.0) {
            vec2 ruv = (rc.xy / rc.w) * 0.5 + 0.5;
            ruv += nv.xy * refraction_strength;
            if (ruv.x > 0.0 && ruv.x < 1.0 && ruv.y > 0.0 && ruv.y < 1.0)
                reflection = texture(reflection_tex, vec2(ruv.x, 1.0 - ruv.y)).rgb;
        }
    }

    float fres = pow(1.0 - clamp(dot(nv, normalize(-view_dir)), 0.0, 1.0), fresnel_power);
    fres = clamp(fres * reflection_strength, 0.0, 1.0);
    vec3 col = mix(through, reflection, fres);

    // --- whitewater: waterfalls, plunge pools, rapids aerate toward foam ---
    float white = 0.0;
    if (cls == C_WATERFALL) {
        // downward-scrolling streaks
        float streak = sin(v_world.y * 3.0 - t * 7.0 + (v_world.x + v_world.z) * 5.0) * 0.5 + 0.5;
        float bands = smoothstep(0.3, 1.0, sin(v_world.x * 7.0 + v_world.z * 7.0) * 0.5 + 0.5);
        white = mix(0.35, 0.85, streak) * mix(0.6, 1.0, bands);
    } else if (cls == C_PLUNGE) {
        float churn = hash(floor(v_world.xz * 2.0) + floor(vec2(t * 6.0)));
        white = 0.55 + 0.35 * sin(t * 8.0 + churn * 6.28);
    } else if (cls == C_RAPIDS) {
        float chop = sin(dot(v_world.xz, flow) * 4.0 - t * 6.0) * 0.5 + 0.5;
        white = 0.25 + 0.4 * chop;
    } else if (cls == C_LIP) {
        white = 0.2;
    }
    col = mix(col, foam_color, clamp(white, 0.0, 1.0));

    // --- shoreline edge foam ---
    float foam = 1.0 - smoothstep(0.0, edge_foam_dist, thickness);
    if (!ice) col = mix(col, foam_color, foam * 0.85);

    if (ice) {
        // matte frosty ice: contrasts with the glossy water, faint crystal cracks
        float crack = step(0.72, sin(v_world.x * 2.6) * sin(v_world.z * 2.6) * 0.5 + 0.5);
        col = mix(vec3(0.80, 0.90, 0.97), vec3(0.95, 0.99, 1.0), crack);
    }

    ALBEDO = col;
    ALPHA = 1.0;
    ROUGHNESS = ice ? 0.6 : (white > 0.3 ? 0.4 : 0.06);
    METALLIC = 0.0;
    SPECULAR = 0.5;
}
