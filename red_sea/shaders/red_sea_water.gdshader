shader_type spatial;
// =====================================================================================
//  RED SEA — SINGLE deformed water surface (Godot 4.6, Forward+).
//
//  ONE heavily-subdivided plane is displaced in the vertex stage into a continuous
//  cross-section: flat open sea -> curves DOWN into a dry trough (the corridor) -> rises
//  into towering WALLS of water -> settles back to the open sea. One surface => NO seams.
//  Driven by `part` (0 = flat sea, 1 = fully parted).
//
//  WAVES come from the GodotOceanWaves FFT sim (addons/ocean_waves, MIT). Its compute
//  cascades publish global-uniform `displacements` / `normals` textures; we sample them for
//  realistic displacement + slope + whitecap foam, tapered to ~0 in the dry corridor and on
//  the steep cliff faces so the walls stay coherent.
//
//  Hard Godot rule respected: only OPAQUE geometry (seabed, floor, fish) appears in the
//  screen/depth textures, so the water refracts + depth-absorbs those.
// =====================================================================================

// depth_draw_always: the water is ONE transparent mesh, and transparent surfaces don't write depth by
// default, so the distant open sea (behind a wall) paints OVER the nearer wall — choppy backdrop bleeds
// through. Writing depth in the transparent pass lets the walls occlude the sea behind them. This is
// NOT depth_prepass_alpha (which would pollute the hint_depth_texture the absorption reads, zeroing the
// column); depth is written AFTER that texture is captured, so refraction/absorption are unaffected.
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_texture  : hint_depth_texture,  repeat_disable, filter_nearest;
uniform sampler2D foam_tex  : repeat_enable, filter_linear_mipmap;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;

// ---- FFT ocean (global uniforms set by scripts/ocean_fft.gd) --------------------------
global uniform sampler2DArray displacements;          // .xyz world displacement per cascade
global uniform sampler2DArray normals : hint_normal;  // .xy slope, .a whitecap foam per cascade
global uniform uint num_cascades;
uniform vec4 map_scales[8];                           // per cascade: (uv.x, uv.y, disp_scale, normal_scale)
uniform float fft_amplitude      : hint_range(0.0, 3.0) = 1.0;
uniform float fft_normal_strength : hint_range(0.0, 3.0) = 1.0;
// Scales ONLY the horizontal (choppy) part of the FFT displacement. At high amplitude the
// horizontal push folds the surface over itself into sharp shards (the "shattered" glitch);
// pulling this below 1 keeps wave HEIGHT but stops the fold. 1.0 = raw FFT choppiness.
uniform float choppiness : hint_range(0.0, 1.0) = 1.0;
// Weights the FINER cascades (1+) in the VERTEX displacement only. The coarse mesh can't draw the
// fine FFT detail, so it aliases into flat shards (the "shattered" glitch). Pulling this down keeps
// the big swell as geometry while the fine detail lives in the per-pixel normal (no aliasing).
uniform float disp_fine : hint_range(0.0, 1.0) = 1.0;

uniform vec3  shallow_color : source_color = vec3(0.18, 0.62, 0.62);
uniform vec3  deep_color    : source_color = vec3(0.01, 0.07, 0.16);
uniform vec4  foam_color    : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3  sky_zenith    : source_color = vec3(0.32, 0.50, 0.82);
uniform vec3  sky_horizon   : source_color = vec3(0.78, 0.82, 0.85);
uniform vec3  ground_tint   : source_color = vec3(0.70, 0.66, 0.55);
uniform vec3  sun_dir       = vec3(0.3, -0.8, 0.5);
uniform vec3  sun_color     : source_color = vec3(1.2, 1.1, 0.95);
uniform float sun_shininess : hint_range(50.0, 4000.0) = 900.0;
uniform float density       : hint_range(0.0, 3.0) = 0.35;
uniform float refraction    : hint_range(0.0, 0.2) = 0.045;
uniform float fresnel_strength : hint_range(0.0, 1.0) = 0.5;

// ---- Trough / split ------------------------------------------------------------------
uniform float sea_level     = 6.0;
uniform float corridor_half = 5.5;     // half-width of the dry corridor (flat trough bottom)
uniform float wall_width    = 4.0;     // horizontal span of the steep INNER cliff face
uniform float wall_falloff  = 6.0;     // span of the gentle OUTER slope, crest back to open sea
uniform float trough_bottom = -2.5;    // corridor water sinks to here (under the opaque floor)
uniform float crest_rise    = 5.0;     // how far the wall crest towers ABOVE the open sea
uniform float part          = 0.0;     // 0 = flat sea, 1 = fully parted

// ---- Foam ----------------------------------------------------------------------------
uniform float foam_depth   = 1.2;
uniform float foam_line    = 0.18;
uniform float foam_tiling  = 0.6;
uniform float foam_scroll  = 0.04;
uniform float foam_distort = 0.05;
uniform float foam_cutoff  : hint_range(0.0, 1.0) = 0.30;
uniform float foam_amount  : hint_range(0.0, 2.0) = 0.8;

// ---- Triplanar wall-face detail ------------------------------------------------------
// A flat plane bent into steep walls STRETCHES its surface detail. We re-apply detail by
// TRIPLANAR projection (3 axis-aligned planes blended by the geometric normal), so vertical
// AND curved faces look right at ANY angle with no smear. The vertical-bearing planes scroll
// downward, so the same detail also reads as water sheeting DOWN the walls.
uniform sampler2D detail_normal : hint_normal, repeat_enable, filter_linear_mipmap;
uniform float triplanar_sharpness : hint_range(1.0, 8.0) = 4.0;
uniform float detail_scale        : hint_range(0.005, 0.6) = 0.04;
uniform float detail_strength     : hint_range(0.0, 4.0) = 2.2;
uniform float wall_streak_amount  : hint_range(0.0, 2.0) = 1.0;
uniform float wall_flow_speed     : hint_range(0.0, 3.0) = 0.6;
uniform float wall_streak_freq    : hint_range(0.1, 2.0) = 0.8;
uniform float crest_foam_amount   : hint_range(0.0, 2.0) = 1.0;

// ---- Wall WAVES --------------------------------------------------------------------------
// The walls use the SEA's OWN FFT, reparameterized onto the vertical plane by (world z, world y) —
// real metres on BOTH axes, so the pattern is at the same scale as the open sea, varies UP the face,
// and is organic for free. This SIDESTEPS the reason the FFT was banned from the walls: that ban came
// from sampling by ground (x,z), where a steep wall's tiny Δx = big Δy stretched it into vertical
// stripes. Sampling by (z,y) has no such stretch. Geometry HEAVE = the FFT big swell (movement, Y-only
// so no overhang/slosh); surface NORMAL = the FFT slope per-pixel (fine detail, no mesh aliasing);
// FOAM = the FFT's own whitecap field (coherent breaking-crest foam, same as the sea — not speckle).
uniform float wall_wave_amp    : hint_range(0.0, 2.0) = 0.8;  // geometry heave from the FFT swell (0 = off)
uniform float wall_wave_scale  : hint_range(0.2, 2.0) = 1.0;  // FFT size on the wall (1 = match sea; lo = bigger)
uniform float wall_wave_normal : hint_range(0.0, 3.0) = 1.0;  // surface wave-normal strength
uniform float wall_wave_foam   : hint_range(0.0, 2.0) = 1.0;  // FFT whitecaps on the wall

// Animation clock — normally tracks TIME, but DRIVEN FROM GDScript so it can be FROZEN with the
// wave sim (the frame-step debug holds it). Lets a paused frame be COMPLETELY static, which
// isolates wave-GEOMETRY changes (compute) from shader SCROLL (foam/detail) when hunting glitches.
uniform float anim_time = 0.0;

varying vec3  v_world_pos;
varying vec2  v_grid_xz;        // flat (pre-displacement) world xz, for sampling the FFT maps
varying vec3  v_trough_normal;  // geometric cross-section normal (cliff/floor), constant along z
varying float v_depth_below;    // sea_level - y, for the opacity gradient + foam
varying float v_taper;          // wave strength here (0 corridor/cliff, 1 open sea), part-aware

// Fully-parted cross-section target height as a function of world x (no waves).
//   |x| < w0       -> flat dry corridor floor (sunk under the opaque floor, hidden)
//   w0 < |x| < w1  -> steep INNER cliff face, rising trough_bottom -> towering crest
//   w1 < |x| < w2  -> gentle OUTER slope, crest settling back down to the open sea
//   |x| > w2       -> flat open sea.  One continuous single-valued height field.
float trough_profile(float x) {
    float ax    = abs(x);
    float crest = sea_level + crest_rise;
    float w0    = corridor_half;
    float w1    = corridor_half + wall_width;
    float w2    = w1 + wall_falloff;
    if (ax < w0) return trough_bottom;
    if (ax < w1) return mix(trough_bottom, crest, smoothstep(w0, w1, ax));
    return mix(crest, sea_level, smoothstep(w1, w2, ax));
}

// Base surface height (no waves): flat sea lerped toward the parted cross-section by `part`.
float trough_base(float x) {
    return mix(sea_level, trough_profile(x), part);
}

// Wave strength: the FFT is a FLAT-water field and smears on anything raised/tilted, so it belongs
// ONLY on the open sea BEYOND the walls. Zero it across the WHOLE wall span (inner face + crest +
// outer slope, |x| <= w2) and ramp it in just past the outer foot — so no FFT ever lands on a
// visible wall surface. When flat (part=0) the whole sea is flat water, so waves cover everything.
float wave_taper(float x) {
    float w2   = corridor_half + wall_width + wall_falloff;
    // Generous CALM BUFFER past the outer foot: water hugging the walls stays flat, and the choppy
    // FFT only lives far out where fog/distance hide it — so no wave sliver ever pokes up past a wall.
    float open = smoothstep(w2 + 6.0, w2 + 16.0, abs(x));
    return mix(1.0, open, part);
}

// FFT world displacement (sum the cascades).
vec3 fft_disp(vec2 w) {
    vec3 d = vec3(0.0);
    for (uint i = 0u; i < num_cascades; i++) {
        vec4 s = map_scales[i];
        // c0 full; each finer cascade falls off (it undersamples the coarse mesh -> facets). Guard
        // i==0 so we never hit pow(0,0) (undefined on some GPUs).
        float wgt = (i == 0u) ? 1.0 : pow(disp_fine, float(i));
        d += texture(displacements, vec3(w * s.xy, float(i))).xyz * (s.z * wgt);
    }
    return d;
}

// FFT slope (.xy) + accumulated whitecap foam (.z).
vec3 fft_grad_foam(vec2 w) {
    vec3 g = vec3(0.0);
    for (uint i = 0u; i < num_cascades; i++) {
        vec4 s = map_scales[i];
        vec4 n = texture(normals, vec3(w * s.xy, float(i)));
        g += vec3(n.xy * s.w, n.a);
    }
    return g;
}

// ---- Triplanar helpers: consistent detail at ANY surface angle (no stretch) -----------
vec3 tri_weights(vec3 n) {
    vec3 w = pow(abs(n), vec3(triplanar_sharpness));
    return w / max(w.x + w.y + w.z, 1e-4);
}

// One triplanar octave of the detail normal-map in WORLD space. The two vertical-bearing planes
// (x-facing via zy, z-facing via xy) scroll their world-Y by `scroll` -> detail flows down.
vec3 tri_detail_octave(vec3 p, vec3 w, float scale, float scroll) {
    vec3 nx = texture(detail_normal, p.zy * scale + vec2(0.0, scroll)).xyz * 2.0 - 1.0;
    vec3 ny = texture(detail_normal, p.xz * scale).xyz * 2.0 - 1.0;
    vec3 nz = texture(detail_normal, p.xy * scale + vec2(0.0, scroll)).xyz * 2.0 - 1.0;
    vec3 px = vec3(0.0,  nx.y, nx.x);   // x-facing plane perturbs world (y,z)
    vec3 py = vec3(ny.x, 0.0,  ny.y);   // up-facing plane perturbs world (x,z)
    vec3 pz = vec3(nz.x, nz.y, 0.0);    // z-facing plane perturbs world (x,y)
    return px * w.x + py * w.y + pz * w.z;
}

// TWO octaves — a coarse swell + finer chop — so the steep walls get wave-like RELIEF instead of a
// glassy ramp. (`detail_scale` is low ~0.04 here = ~metre-scale features; one octave at the old high
// scale was ~cm features that mipped straight to flat, which is why the walls read as smooth sheets.)
vec3 tri_detail_normal(vec3 p, vec3 w, float scale, float scroll) {
    return tri_detail_octave(p, w, scale,       scroll)
         + tri_detail_octave(p, w, scale * 2.6, scroll * 1.6) * 0.35;
}

// Triplanar streak scalar from the VERTICAL planes only (so streaks live on faces, not flat
// water), scrolling downward -> water sheeting down any vertical/curved face, any facing.
float tri_streak(vec3 p, vec3 w, float scale, float scroll) {
    float fx = texture(noise_tex, p.zy * scale + vec2(0.0, scroll)).r;
    float fz = texture(noise_tex, p.xy * scale + vec2(0.0, scroll)).r;
    return fx * w.x + fz * w.z;
}

// Confine + fade the wall waves to the wall span (corridor edge .. outer foot), gated by `part`.
float wall_wave_zone(float gx) {
    float ax = abs(gx);
    float w0 = corridor_half;
    float w2 = corridor_half + wall_width + wall_falloff;
    return smoothstep(w0, w0 + 1.5, ax) * (1.0 - smoothstep(w2 - 1.5, w2, ax)) * part;
}
// Sample the sea's FFT on the wall, parameterized by (world z, world y) — real metres on BOTH axes,
// so the pattern matches the open sea's SCALE and varies up the face (no vertical-stretch stripes).
// Geometry uses .y of the displacement (disp_fine=0 -> smooth big swell only, no shard aliasing).
vec3 wall_fft_disp(float z, float y) {
    return fft_disp(vec2(z, y) * wall_wave_scale);
}
// Surface wave NORMAL perturbation (in the wall's z-y tangent plane) + the FFT whitecap FOAM (.w).
vec4 wall_fft_nf(float z, float y) {
    vec3 gf = fft_grad_foam(vec2(z, y) * wall_wave_scale);
    return vec4(0.0, -gf.y, -gf.x, gf.z);   // tilt (y,z) by the slope; .w = Jacobian foam
}

void vertex() {
    vec2  grid  = vec2(VERTEX.x, VERTEX.z);          // sea node at identity -> grid == world xz
    // The FFT is confined to the open sea beyond the walls by wave_taper (purely position-based on the
    // UNDISPLACED grid x), so nothing lands on a visible wall surface to smear. v_taper carries it into
    // the fragment so the FFT slope + whitecap foam fade off the walls too.
    float taper = wave_taper(grid.x);
    vec3  disp  = fft_disp(grid) * (taper * fft_amplitude);
    // Horizontal "choppy" slosh slides a vertex's rendered x off its grid x, so a sea vertex can creep
    // toward a wall and stretch a triangle across the taper boundary (thin slivers up the wall). Hold
    // the horizontal part OUT past an extra margin so the wall-adjacent waves are purely vertical.
    float w2_chop   = corridor_half + wall_width + wall_falloff;
    float chop_keep = mix(1.0, smoothstep(w2_chop + 10.0, w2_chop + 18.0, abs(grid.x)), part);
    disp.xz *= choppiness * chop_keep;   // tame horizontal choppiness so steep waves don't FOLD into shards
    // Safety net: reject non-finite / absurd displacement so a bad texel just sits flat.
    if (any(notEqual(disp, disp)) || any(greaterThan(abs(disp), vec3(15.0)))) disp = vec3(0.0);
    float base  = trough_base(grid.x);               // large-scale trough (stable, undisplaced x)
    // Wall HEAVE from the sea's own FFT, sampled by (z, base height) — real metres, so the wall waves
    // are the SAME SIZE as the open sea and MOVE with the sim. disp_fine=0 keeps fft_disp the smooth
    // big swell only (no shard aliasing on the coarse wall mesh); fine FFT detail rides the per-pixel
    // normal in the fragment. Y-only -> single-valued height field, no horizontal slosh.
    float ww    = wall_fft_disp(grid.y, base).y * wall_wave_amp * wall_wave_zone(grid.x);
    float h     = base + disp.y + ww;

    VERTEX.x = grid.x + disp.x;                       // horizontal choppiness rides on top
    VERTEX.y = h;
    VERTEX.z = grid.y + disp.z;

    v_world_pos   = vec3(VERTEX.x, h, VERTEX.z);
    v_grid_xz     = grid;
    v_depth_below = sea_level - h;
    v_taper       = taper;

    // Geometric cross-section normal (z-invariant trough); the FFT wave normal is added per-pixel.
    float e  = 0.4;
    float sl = (trough_base(grid.x + e) - trough_base(grid.x - e)) / (2.0 * e);
    v_trough_normal = normalize(vec3(-sl, 1.0, 0.0));
    NORMAL = v_trough_normal;                         // refined in fragment()
}

void fragment() {
    // Wall zone (keyed off the UNDISPLACED grid-x so it covers inner face + crest + outer slope).
    // Computed up here because the surface-normal, body, AND foam stages all key off it.
    float ax_w      = abs(v_grid_xz.x);
    float w2_w      = corridor_half + wall_width + wall_falloff;
    float in_wall   = smoothstep(corridor_half, corridor_half + 0.8, ax_w)
                    * (1.0 - smoothstep(w2_w - 0.8, w2_w, ax_w));
    float wall_zone = in_wall * smoothstep(0.10, 0.45, part);

    // ---- (1) Surface normal: FFT waves (flat sea) + TRIPLANAR detail (any angle) --------
    vec3  tw      = tri_weights(v_trough_normal);
    float vert    = clamp(1.0 - v_trough_normal.y, 0.0, 1.0);     // 0 flat -> 1 vertical
    vec3  gf      = fft_grad_foam(v_grid_xz);
    // Same safety net as the vertex displacement, for the slope/foam (a garbage texel here would
    // flash the surface normal / foam for a frame).
    if (any(notEqual(gf, gf)) || any(greaterThan(abs(gf), vec3(30.0)))) gf = vec3(0.0);
    vec2  g       = gf.xy * (v_taper * fft_normal_strength);
    vec3  wave_n  = normalize(vec3(-g.x, 1.0, -g.y));
    // taper->0 on the steep cliffs (where the trough normal must win), ->1 on the open sea.
    vec3  base_n  = normalize(mix(v_trough_normal, wave_n, v_taper));
    // Triplanar micro-detail fills in faces the FFT can't reach without stretch; weighted
    // strong on verticals, light on the flat sea (the FFT already carries detail there).
    // FADE the detail out at grazing angles + with distance — a normal-mapped detail on a near-
    // vertical wall ALIASES into white static when its features fall below a pixel (distant walls
    // receding to the horizon). Keep it crisp on the near, face-on wall; drop it where it sparkles.
    vec3  view_w  = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
    vec3  cam_w   = INV_VIEW_MATRIX[3].xyz;
    float graze   = abs(dot(base_n, view_w));                       // 1 face-on -> 0 grazing
    float frag_d  = length(v_world_pos - cam_w);
    float dfade   = smoothstep(0.05, 0.32, graze) * (1.0 - smoothstep(45.0, 130.0, frag_d));
    // NOISE detail: light on the open sea (the FFT already carries its detail), and ZERO on the walls
    // (the noise was the grainy "static"). The walls get the SEA's FFT wave normal instead, below.
    vec3  dpert   = tri_detail_normal(v_world_pos, tw, detail_scale, anim_time * wall_flow_speed)
                  * mix(0.25, 0.0, vert);
    // Wall surface = the sea's FFT slope, sampled by (z, y) -> coherent moving wave detail (.w = foam,
    // used in 5b). Faded with grazing/distance to avoid normal-map-style sparkle far down the corridor.
    vec4  wfn = vec4(0.0);
    if (wall_zone > 0.001) {
        wfn = wall_fft_nf(v_world_pos.z, v_world_pos.y);
        if (any(notEqual(wfn, wfn)) || any(greaterThan(abs(wfn), vec4(40.0)))) wfn = vec4(0.0);
    }
    vec3  world_n = normalize(base_n + dpert * detail_strength * dfade
                  + wfn.xyz * (wall_wave_normal * wall_zone * dfade));
    NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);   // gross wall swell rode in via VERTEX.y

    // ---- (2) Depth absorption to the opaque scene behind ------------------------------
    float raw = textureLod(depth_texture, SCREEN_UV, 0.0).r;
    bool  has_bg = raw < 1.0;
    vec4  upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
    vec3  scene_view = upos.xyz / upos.w;
    float thickness = has_bg ? max(-scene_view.z - (-VERTEX.z), 0.0) : 0.0;
    float absorb_depth = 1.0 - exp(-thickness * density);

    // ---- (3) Vertical gradient: deeper below sea level (the cliffs) = more opaque ------
    float crest_y = sea_level + crest_rise;
    float dn = clamp(v_depth_below / (sea_level - trough_bottom), 0.0, 1.0);
    float absorb = max(absorb_depth, 1.0 - exp(-density * max(v_depth_below, 0.0) * 1.3));
    float body   = max(absorb_depth, mix(0.12, 1.0, dn));

    // Parted walls are aerated, churning water — NOT glass. ABOVE sea level the depth gradient
    // collapses (dn=0 -> body=0.12) so the upper wall would go transparent and mirror the sky.
    // Anchor a solid DEEP body across the whole wall cross-section, keyed off the UNDISPLACED grid
    // x (view- and normal-independent) so it also covers the CREST and OUTER slope. A vert/normal
    // mask MISSES the crest — its normal points UP so vert->0 there — which is exactly the glassy
    // "fold" you saw on distant wall tops. Only ABOVE sea level, so the lower INNER face (the fish
    // band) stays see-through.
    float upper     = smoothstep(sea_level - 1.5, crest_y - 1.0, v_world_pos.y);   // wall_zone: see top
    float wall_body = wall_zone * upper;
    body   = max(body,   wall_body * 0.90);   // stays OPAQUE (you can't see through a wall of water)...
    absorb = max(absorb, wall_body * 0.55);   // ...but a LIGHTER hue so it reads like sea water, not navy-black
    vec3  water_col = mix(shallow_color, deep_color, max(max(absorb, dn), wall_body * 0.50));

    // ---- (4) Screen-space refraction --------------------------------------------------
    vec2 suv = clamp(SCREEN_UV + NORMAL.xy * refraction, vec2(0.001), vec2(0.999));
    vec3 behind = textureLod(screen_texture, suv, 0.0).rgb;

    // ---- (5) Foam: contact (cliff base + shoreline) + cliff lip + FFT whitecaps ---------
    float contact = 0.0;
    if (has_bg) {
        contact = 1.0 - smoothstep(0.0, foam_depth, thickness);
        contact = max(contact, 1.0 - smoothstep(0.0, foam_line, thickness));
    }
    // (Removed the old "cliff lip" foam: it keyed purely on HEIGHT (|depth_below| near 0) and was
    //  z-invariant, so it drew a straight horizontal WHITE LINE at the waterline down the full length
    //  of both walls. The walls now get organic whitecaps from the FFT foam, so it's not needed.)
    float foam_mask = clamp(contact, 0.0, 1.0);

    vec2 wuv  = v_world_pos.xz * foam_tiling;
    vec2 warp = (texture(noise_tex, wuv * 0.5 - anim_time * 0.02).rg * 2.0 - 1.0) * foam_distort;
    float fnoise = texture(foam_tex, wuv + anim_time * foam_scroll + warp).r;
    float foam = clamp(smoothstep(foam_cutoff, 1.0, fnoise) * foam_mask * (0.5 + foam_amount), 0.0, 1.0);
    // FFT whitecaps on the open sea / crests (the sim's own Jacobian foam).
    float fft_foam = smoothstep(0.2, 0.85, gf.z * v_taper);
    foam = clamp(max(foam, fft_foam * clamp(foam_amount, 0.3, 1.2)), 0.0, 1.0);

    // ---- (5b) Wall-face foam: TRIPLANAR sheeting streaks that flow down ANY vertical /
    //          curved face + a foaming crest crown. `vert`/`tw` come from (1). -----------
    float wall      = smoothstep(0.25, 0.65, vert) * smoothstep(0.10, 0.45, part);
    float down_fade = smoothstep(trough_bottom, crest_y, v_world_pos.y);     // stronger up high
    float sheet     = tri_streak(v_world_pos, tw, wall_streak_freq, anim_time * wall_flow_speed);
    float streaks   = smoothstep(0.5, 0.92, sheet) * wall * mix(0.35, 1.0, down_fade) * wall_streak_amount;
    // Crown uses the POSITION-based wall_zone (not vert) so foam actually covers the crest PEAK,
    // where the normal points up and vert->0 left a glassy bare lip.
    float crown     = smoothstep(crest_y - 2.4, crest_y - 0.3, v_world_pos.y) * wall_zone * crest_foam_amount;
    // Whitecaps from the SAME FFT field as the open sea (the sim's Jacobian foam, sampled on the wall's
    // z-y plane in 1) -> coherent breaking-crest foam that matches the sea, not uniform texture speckle.
    float wwfoam    = smoothstep(0.2, 0.85, wfn.w) * wall_zone * wall_wave_foam;
    foam = clamp(max(foam, max(max(streaks, crown), wwfoam)), 0.0, 1.0);

    // ---- (6) Fresnel sky gradient + HDR sun glint -------------------------------------
    vec3 refl_w = reflect(-view_w, world_n);   // view_w computed in (1)
    float upd = refl_w.y;
    vec3 sky_refl = (upd >= 0.0)
        ? mix(sky_horizon, sky_zenith, smoothstep(0.0, 0.45, upd))
        : mix(sky_horizon, ground_tint, smoothstep(0.0, -0.35, upd));
    float fres = pow(1.0 - clamp(dot(world_n, view_w), 0.0, 1.0), 5.0);
    fres = mix(0.02, 1.0, fres) * fresnel_strength;
    // Churning walls are diffuse foam, not mirrors. At grazing view (looking down the corridor)
    // the walls would otherwise reflect the near-white horizon sky -> the other half of the
    // sunward "smear". Kill the reflection on steep faces and wherever foam covers them; the flat
    // open sea (vert~0, foam~0) keeps its full glassy reflection.
    fres *= (1.0 - 0.85 * vert) * (1.0 - 0.55 * foam) * (1.0 - 0.85 * wall_zone);
    float sun_lobe = pow(max(dot(refl_w, -normalize(sun_dir)), 0.0), sun_shininess);
    // Glint belongs to the OPEN SEA only — on the walls the detailed normal makes it sparkle like
    // static, so gate it by v_taper (0 on walls, 1 on open sea).
    vec3  glint = sun_color * sun_lobe * (0.5 + 0.9 * length(g)) * 2.5 * v_taper;

    // ---- (7) Composite as UNLIT EMISSION ---------------------------------------------
    vec3 composite = mix(behind, water_col, body);
    composite = mix(composite, sky_refl, fres);
    // Sculpt the walls with the TRIPLANAR-perturbed normal: a soft sun-facing diffuse term so the
    // detail (detail_strength / detail_scale) reads as actual FORM instead of a flat slab — this
    // is what makes those sliders visibly do something. Only on the parted walls; sea unaffected.
    float ndl = clamp(dot(world_n, -normalize(sun_dir)) * 0.5 + 0.5, 0.0, 1.0);
    composite *= mix(1.0, mix(0.72, 1.34, ndl), wall_zone);   // lift the shadows so walls aren't near-black
    composite += glint;
    composite = mix(composite, foam_color.rgb, foam);
    EMISSION = composite;

    ALBEDO    = water_col * 0.04;
    // Walls are aerated, churning water — make them MATTE with almost no specular so the detailed
    // normal reads as soft chop instead of sparkly static (specular/fresnel on a detailed normal
    // aliases into white speckle at grazing angles). Open sea stays glossy/reflective. Foam is matte.
    ROUGHNESS = mix(mix(0.10, 0.82, wall_zone), 0.95, foam);
    METALLIC  = 0.0;
    SPECULAR  = mix(0.4, 0.03, wall_zone);
    ALPHA = clamp(max(0.9 * body, 0.32) + foam, 0.0, 1.0);
}
