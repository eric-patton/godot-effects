extends Node3D
## Moses / Red Sea split — interactive prototype.
##
## Builds the whole scene procedurally (seabed + beaches, the single deformed sea surface,
## the dry corridor floor, fish, lighting, splash) and lets YOU walk it:
##   WASD move · mouse look · wheel zoom · Shift sprint · E part/close the sea · R auto demo · Esc free cursor
##
## You start up on the shoreline; press E to part the sea, then walk down into the exposed
## seabed corridor between the towering walls of water. The whole split is one normalized
## value (`part` 0->1) that the water shader turns into the trough + walls, so OPEN and CLOSE
## are guaranteed symmetric. All the hard rendering lives in res://red_sea/shaders/red_sea_water.gdshader.

signal lightning_strike    # fired at the START of each strike envelope (game SFX: thunder)
signal sea_slammed         # fired the moment the closing walls meet (game SFX: water crash)

# ---- Layout -------------------------------------------------------------------------
# NOTE: the MESH SIZES for Seabed/Water are authored in scenes/red_sea.tscn (so the editor
# can show the terrain for placing decorations). At runtime _build_* below REBUILDS those meshes from
# these constants and overwrites them, so the code is the source of truth in-game. If you change a
# size here, mirror it in red_sea.tscn so the editor preview keeps matching what you get at Play.
const SEA_HALF_X := 240.0    # sea extent on x — VERY wide open sea so the sides fade into fog, not a far bank
const SEA_HALF_Z := 130.0    # sea extent on z — long crossing (beaches at the z-ends; people cross along z)
const SEA_LEVEL := 6.0       # world-Y of the calm water surface
const CORRIDOR_HALF := 5.5   # half-width of the flat dry trough (corridor)
const WALL_WIDTH := 8.0      # horizontal span of the steep INNER cliff face  (baked from tuning_values.txt 2026-06-05)
const WALL_FALLOFF := 2.0    # span of the gentle OUTER slope, crest back down to open sea
const CREST_RISE := 6.6      # how far the wall crest towers ABOVE the open sea
const TROUGH_BOTTOM := -2.5  # the corridor water sinks to here, below the opaque seabed floor

# ---- Seabed basin (mirrors shaders/seabed.gdshader so we can walk on it) -------------
# Beaches/banks are pushed FAR out so there's a vast expanse of open sea before land rises, and the
# seabed plane (SEABED_HALF) extends well past the play area so its edge is lost in the fog horizon.
const BEACH_START := 95.0    # |z| where the sand starts rising
const BEACH_END := 128.0     # |z| where it reaches full beach height
const BEACH_HEIGHT := 14.0
const SIDE_START := 300.0    # |x| where the side banks start rising — pushed FAR out (deep in fog) so the
const SIDE_END := 420.0      #   open sea reads as endless to the sides instead of a "swimming pool" bank
const SIDE_HEIGHT := 16.0
const SEABED_HALF := 520.0   # half-size of the (square) seabed/land plane — well past the far banks + fog

# ---- Player / camera ----------------------------------------------------------------
const START_Z := -112.0      # spawn up on the near shoreline (terrain ~7, just above water)
const MOVE_SPEED := 7.0
const SPRINT_MULT := 1.9
const FOOT_OFFSET := 0.04
const MOUSE_SENS := 0.005
const CAM_PIVOT_Y := 1.6

# ---- Cinematic timing (used by the auto demo + the E toggle durations) --------------
@export var open_time := 3.0
@export var hold_time := 4.0
@export var close_time := 1.4
@export var rest_time := 2.5

# ---- Water look (forwarded to the shader; tweak live in the inspector) --------------
@export var density := 1.5          # baked from tuning_values.txt (2026-06-05)
@export var shallow_color := Color(0.18, 0.62, 0.62)
@export var deep_color := Color(0.01, 0.07, 0.16)
@export var refraction := 0.052     # baked from tuning_values.txt (2026-06-05)

# At Play, every child of the scene's "Decorations" node is dropped onto the terrain surface (its Y
# is snapped to _terrain_height at its x/z). Turn this off to keep the Y you placed by hand; or add a
# specific decoration to the "no_snap" group to exempt just that one (e.g. a bird, a floating prop).
@export var snap_decorations := true

var _water_shader := load("res://red_sea/shaders/red_sea_water.gdshader")
var _seabed_shader := load("res://red_sea/shaders/seabed.gdshader")

var _sea: MeshInstance3D
var _sea_mat: ShaderMaterial
var _ocean: OceanFFT
var _seabed_mat: ShaderMaterial   # the big basin ground (sand <-> sea-floor); also the corridor floor
var _camera: Camera3D
var _splash: GPUParticles3D
var _drown_rect: ColorRect
var _sun: DirectionalLight3D
var _env: Environment
var _sky_mat: ShaderMaterial              # custom starry sky (night_sky.gdshader); re-tinted for the mood
var _sky_zenith := Color(0.32, 0.50, 0.82)
var _sky_horizon := Color(0.78, 0.82, 0.85)
var _ground_tint := Color(0.70, 0.66, 0.55)

# ---- Weather / mood (clear NOON  <->  stormy NIGHT) ---------------------------------
# One scalar `_storm_t` (0=day, 1=night) blends EVERY mood property between the two presets
# below; `_apply_mood(storm)` writes the BASE look to the Environment, the sun/moon light, the
# starry-sky shader AND the unlit water uniforms in one place. Lightning is a SEPARATE additive
# overlay (`_apply_flash`) that snapshots the live look, adds a sheet-flash on top, then restores
# the snapshot — so a strike never permanently rewrites (or "resets") the base. No bolt is drawn.
const STORM_FADE := 1.6                    # seconds for the N-key day<->night cross-fade
# DAY preset (MUST match the baseline written in _build_environment / _build_sun).
# Mood presets (DAY/DUSK/NIGHT_STORM/DAWN) live in scripts/game/mood_presets.gd — one source of
# truth for every look value. The sandbox N-toggle blends DAY<->NIGHT_STORM; the game's
# MoodController tweens between arbitrary presets via apply_mood_values().
const Moods := preload("res://red_sea/mood_presets.gd")
# Lightning flash colors (cold, slightly blue-white).
const FLASH_SKY := Color(0.85, 0.90, 1.05)
const FLASH_SUN_COLOR := Color(0.92, 0.96, 1.10)
# Rain.
const RAIN_TOP := 24.0                     # emit slab this far ABOVE the player; streaks fall past the cam
const RAIN_AREA := 34.0                    # half-extent of the emit slab in x/z — a WIDE curtain around you
										   # (~68 m). Far streaks thin out, but the FIXED_Y billboard keeps
										   # them camera-facing so they still read; amount is raised to match.
const SPLASH_AREA := 15.0                   # half-extent (x) of each splash strip around the player's feet —
										   # WIDE so the impacts don't read as a small square on the ground.
const SPLASH_STRIPS := 13                   # the splash field is many thin Z-STRIPS, each locked to its OWN
const SPLASH_STRIP_STEP := 2.4              # terrain height — a cheap stair-step that HUGS sloped ground (the
										   # spawn beach) instead of one flat sheet floating at its edges, and
										   # together they span ~±16 m in z. Exact on the flat corridor. (True
										   # per-pixel conform would need heightfield particle-collision + a
										   # sub-emitter, heavier + unverifiable here; the stair-step is close.)
# ---- Pillar of fire (Yahweh's presence: a flickering light that leads the Hebrews; movable for the game) ----
const PILLAR_HEIGHT := 32.0           # tall, towering column (opaque core + ragged additive flame shell)
const PILLAR_WIDTH := 3.2
const PILLAR_LIGHT_ENERGY := 10.0     # base OmniLight energy (floods the corridor); flicker rides on top
const PILLAR_LIGHT_RANGE := 42.0      # reaches across the corridor + lights the nearby herd
const PILLAR_GLIDE := 10.0            # m/s the pillar glides toward its programmatic target
const PILLAR_NUDGE := 8.0             # m/s manual arrow-key nudge of the target (a demo of its movability)
const PILLAR_BASE_FOLLOW := 4.0      # rate the base eases to ground/waterline height (smooths the parting drop)

var _rain: GPUParticles3D
var _rain_splashes: Array = []             # the splash field: thin Z-strips, each terrain-locked (stair-step)
var _collision_markers: Node3D             # two translucent planes showing the player-confinement lane
var _pillar: Node3D                        # PILLAR OF FIRE root — move THIS to lead/guard (game layer)
var _pillar_fx: Node3D                      # the instanced godot-effects fire package (rides under _pillar)
var _pillar_light: OmniLight3D             # the flickering dynamic light (the whole point)
var _pillar_fire_mat: ShaderMaterial       # the particle-flame draw material (held time + intensity flicker)
var _pillar_fire: GPUParticles3D           # the swirling flame-particle cloud (the tornado body)
var _pillar_embers: GPUParticles3D         # the embers flecking off the whirl (frozen with the waves on P)
var _pillar_base: GPUParticles3D           # wide flaming base bloom at the foot of the column
var _pillar_shell: MeshInstance3D          # outer additive flame shell (ragged tongues — the silhouette)
var _pillar_shell_mat: ShaderMaterial      # the flame-shell material (held time + intensity flicker)
var _pillar_core: MeshInstance3D           # opaque white-hot heart (blocks the background -> no see-through)
var _pillar_core_mat: ShaderMaterial       # the core material (held time + intensity flicker)
var _pillar_crown: GPUParticles3D          # dark smoky crown billowing above the flame tips
var _pillar_light_hi: OmniLight3D          # second glow high up the column
var _pillar_target := Vector3.ZERO         # world point the pillar glides toward (set by the move API)
var _pillar_pos := Vector3.ZERO            # the pillar's GROUND anchor (glide/base-follow output);
										   # the node renders at _pillar_pos + (0, pillar_y_offset, 0)
var _storm_t := 0.0                        # current mood (0 day, 1 night)
var _storm_target := 0.0
var _weather_dirty := false                # force one _apply_mood (e.g. right after a toggle)
var _was_applying := false                 # so we get ONE final _apply_mood when a fade/flash ends
# Lightning state
var _strike_timer := 0.0
var _flashing := false
var _flash_level := 0.0
var _flash_clock := 0.0
var _flash_pulses: Array = []              # [{t, amp}] mini multi-flicker envelope per strike
var _flash_base: Dictionary = {}           # live look snapshot taken at strike-start, restored when it
										   # ends -> a flash is purely ADDITIVE and never permanently
										   # rewrites the sun/sky (so it can't clobber panel-tuned values)

var _moses: Node3D                       # the PLAYER (root: planted; visuals under its MeshRoot)
var _moses_mesh: Node3D                  # the wobble target
var _moses_phase := 0.0                  # walk-wobble phase
var _moses_anim_speed := 0.0             # smoothed ground speed feeding the wobble (no on/off pop)
var _walkers: Array = []                 # trailing herd
var _fish: Array = []                    # [{node, x, y, z0, span, speed, phase, bob}]
var _mist: Array = []                    # crest spray emitters (one per wall)

# Split state
var _part_value := 0.0                   # raw 0..1 (smoothstepped in _apply_split)
var _part_target := 0.0
var _part_tween: Tween
const SLAM_SFX_LEAD := 0.5               # the crash AUDIO leads the visual slam (rising front)
var _slam_sfx_tween: Tween               # pending sea_slammed emission; killed if the close is
										 # cancelled or superseded

# Camera orbit state
var _cam_yaw := PI                        # PI -> camera behind a +z-facing player
var _cam_pitch := 0.26                     # low-ish, so the walls of water tower over you
var _cam_dist := 8.0
var _looking := false                      # true only while RMB held (look); frees cursor for the panel
var _tuning: TuningPanel

# Frame-step debug: P freezes the wave sim, ] / [ advance one wave-frame at a time so the glitch
# frame can be parked on-screen and screenshotted. The rest of the world holds while stepping.
const STEP_DT := 1.0 / 60.0
var _step_paused := false
var _step_count := 0
var _step_label: Label

var _elapsed := 0.0
var _shake := 0.0
var _anim_time := 0.0   # shader scroll clock; held while frame-step-frozen so a paused frame is fully static

# ---- Game layer (scripts/game/) — this file stays the WORLD; the director drives it through
#      these flags + the public accessors near the pillar API. F1 opens the old sandbox suite. ----
var game_mode := false           # no game layer in the effects pack: always the sandbox boot
var debug_enabled := false       # F1 in game mode: sandbox keys + help text + tuning panel
var player_control := true       # false while a cutscene owns Moses (WASD ignored)
var camera_override := false     # true while a cutscene owns the camera (orbit cam skipped)
var mouselook := false           # captured always-on mouselook (gameplay phases; M2)
var lightning_override := false  # director's lightning gate (game mode ignores _storm_t's own gate)
var pillar_y_offset := 0.0       # PillarAnimator's vertical channel, composed onto the glide (M4)
var _help_label: Label


func _ready() -> void:
	_build_environment()
	_build_seabed()
	_build_water()
	_build_ocean_fft()
	# Fish removed for now (user call: they serve no purpose in the game). _build_fish() /
	# _swim_fish() stay dormant — re-add the call here if they ever earn their keep.
	_build_moses()
	_build_splash()
	_build_wall_mist()
	_build_rain()
	_build_rain_splash()
	_build_pillar_of_fire()
	_build_collision_markers()
	_build_camera()
	_build_drown_overlay()
	_build_hud()
	_build_tuning()
	_setup_decorations()
	_apply_split(0.0)
	_start_at_night()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # free by default; hold RMB to look around


func _start_at_night() -> void:
	# Night is the FIRST-CLASS look for this scene, so we open straight into the stormy night (rain +
	# lightning), not noon. `N` still toggles back to day. Runs AFTER _build_tuning so it wins over the
	# panel's day-baseline defaults; the mood is written once here, then the panel owns the steady state.
	_storm_t = 1.0
	_storm_target = 1.0
	_apply_mood(1.0)
	_sync_mood_sliders(1.0)                        # panel sliders must SHOW night, or the first drag jumps
	_set_rain(true)
	_strike_timer = randf_range(2.5, 6.0)         # first lightning a few seconds in


# Push the mood-driven sun/fog values into the tuning-panel sliders so the panel always REFLECTS the
# live state (the mood writes the light/env directly; without this the SUN/FOG sliders would sit at their
# day defaults while the scene is night, and the first nudge would snap the look back to day).
func _sync_mood_sliders(s: float) -> void:
	_sync_mood_slider_values(Moods.blend(Moods.DAY, Moods.NIGHT_STORM, clampf(s, 0.0, 1.0)))


func _sync_mood_slider_values(m: Dictionary) -> void:
	if not _tuning:
		return
	_tuning.sync_slider("light_energy", m["sun_energy"])
	_tuning.sync_slider("light_volumetric_fog_energy", m["sun_beam"])
	_tuning.sync_slider("sun_pitch", m["sun_pitch"])
	_tuning.sync_slider("sun_yaw", m["sun_yaw"])
	_tuning.sync_slider("volumetric_fog_density", m["vfog_density"])
	_tuning.sync_slider("fog_density", m["fog_density"])


func _setup_decorations() -> void:
	# Drop everything the user parked under the scene's "Decorations" node onto the terrain surface,
	# so they only have to get x/z right in the editor (Y is snapped to the same height field the
	# player walks on). See the `snap_decorations` export for opting out.
	var deco := get_node_or_null("Decorations")
	if deco == null or not snap_decorations:
		return
	for child in deco.get_children():
		if child is Node3D and not child.is_in_group("no_snap"):
			var c := child as Node3D
			c.position = Vector3(c.position.x, _terrain_height(c.position.x, c.position.z), c.position.z)


# =====================================================================================
#  Terrain — analytic height field (the seabed/walls are GPU-displaced, so collision
#  meshes wouldn't match; we sample the SAME math on the CPU to plant feet on it).
# =====================================================================================

func _seabed_height(x: float, z: float) -> float:
	# Mirrors seabed.gdshader's basin (minus the tiny dune noise, for a smooth walk).
	var bz := smoothstep(BEACH_START, BEACH_END, absf(z)) * BEACH_HEIGHT
	var bx := smoothstep(SIDE_START, SIDE_END, absf(x)) * SIDE_HEIGHT
	return bz + bx


func _terrain_height(x: float, z: float) -> float:
	# Feet ride the seabed everywhere now (the corridor is just the basin floor, exposed once the
	# trough sinks below it) — there's no longer a separate raised dry-floor plane to stand on.
	return _seabed_height(x, z)


func _inv_smoothstep(s: float) -> float:
	s = clampf(s, 0.0, 1.0)
	return 0.5 - sin(asin(1.0 - 2.0 * s) / 3.0)


func _wall_face_x_for_y(target_y: float) -> float:
	# Invert the INNER cliff face: surface = mix(TROUGH_BOTTOM, crest, smoothstep(w0,w1,x)).
	var crest := SEA_LEVEL + CREST_RISE
	var f := clampf((target_y - TROUGH_BOTTOM) / (crest - TROUGH_BOTTOM), 0.02, 0.98)
	return CORRIDOR_HALF + _inv_smoothstep(f) * WALL_WIDTH


func _part_eff() -> float:
	# The shader drives geometry off smoothstep(0,1,part) (see _apply_split), so the CPU
	# wall mirrors below must use the SAME curve to line up with what's drawn.
	return smoothstep(0.0, 1.0, _part_value)


func _wall_surface_height(x: float, z: float) -> float:
	# Top of the towering water wall (mirrors trough_profile in red_sea_water.gdshader). Used as a
	# SOLID for the camera boom so it can't push back THROUGH a wall. Returns a deep value outside the
	# wall band / when closed / under the high beach, so the open corridor + open sea + shore never act
	# as a ceiling on the camera.
	var pe := _part_eff()
	if pe < 0.01:
		return -1.0e9
	var ax := absf(x)
	var w0 := CORRIDOR_HALF
	var w2 := CORRIDOR_HALF + WALL_WIDTH + WALL_FALLOFF
	if ax < w0 or ax > w2:
		return -1.0e9
	if smoothstep(BEACH_START - 6.0, BEACH_END, absf(z)) > 0.5:
		return -1.0e9                          # walls sit below the raised beach here
	var crest := SEA_LEVEL + CREST_RISE
	var w1 := CORRIDOR_HALF + WALL_WIDTH
	var surf: float
	if ax < w1:
		surf = lerp(TROUGH_BOTTOM, crest, smoothstep(w0, w1, ax))   # steep inner cliff
	else:
		surf = lerp(crest, SEA_LEVEL, smoothstep(w1, w2, ax))       # gentle outer slope back to sea
	return lerp(SEA_LEVEL, surf, pe)


func _shore_z() -> float:
	# |z| where the beach has risen to the waterline (terrain == SEA_LEVEL) — the edge of the dry shore.
	var frac: float = clampf((SEA_LEVEL - 0.3) / BEACH_HEIGHT, 0.0, 1.0)
	return BEACH_START + _inv_smoothstep(frac) * (BEACH_END - BEACH_START)


func _is_walkable(x: float, z: float) -> bool:
	# The single source of truth for where a person may stand. You can be on DRY LAND (the seabed has
	# risen to/above the waterline — beaches, shore, banks) OR in the DRAINED CORRIDOR once the sea is
	# parted. Everything below the waterline that isn't the open corridor is WATER → off-limits. This
	# replaces the old part-gated wall clamp: it now works whether the walls are up or not (you can't
	# wade into the un-parted sea), and it inherently blocks flanking (the side water is never walkable).
	if _seabed_height(x, z) >= SEA_LEVEL - 0.3:
		return true                            # dry raised ground
	if _part_eff() < 0.45:
		return false                           # sea closed -> the whole sunken basin is water
	return absf(x) <= CORRIDOR_HALF - 0.6      # parted -> only the drained corridor lane is dry


func _nearest_walkable(x: float, z: float) -> Vector2:
	# Project a point onto the nearest walkable spot (for the herd, which can't "slide" like the player):
	# pull it into the corridor lane, or back out to the dry shore — whichever lands somewhere dry.
	if _is_walkable(x, z):
		return Vector2(x, z)
	var cx: float = clampf(x, -(CORRIDOR_HALF - 0.6), CORRIDOR_HALF - 0.6)
	if _is_walkable(cx, z):
		return Vector2(cx, z)                  # nearest corridor lane (parted)
	var sgn: float = signf(z) if z != 0.0 else -1.0
	var zb: float = sgn * maxf(absf(z), _shore_z())
	if _is_walkable(x, zb):
		return Vector2(x, zb)                  # back onto the dry shore on this side
	if _is_walkable(cx, zb):
		return Vector2(cx, zb)
	return Vector2(cx, zb)


# =====================================================================================
#  Build
# =====================================================================================

func _make_noise(freq: float, seamless: bool, as_normal: bool,
		ntype := FastNoiseLite.TYPE_SIMPLEX_SMOOTH) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = ntype
	n.frequency = freq
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = seamless
	tex.as_normal_map = as_normal
	tex.noise = n
	return tex


func _build_environment() -> void:
	# Reuse a WorldEnvironment authored in the scene if present, else make one (code is authoritative).
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null:
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		add_child(we)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://red_sea/shaders/night_sky.gdshader")
	sky_mat.set_shader_parameter("zenith_color", Moods.DAY["sky_zenith"])
	sky_mat.set_shader_parameter("horizon_color", Moods.DAY["sky_horizon"])
	sky_mat.set_shader_parameter("ground_color", Moods.DAY["sky_ground"])
	sky_mat.set_shader_parameter("night", 0.0)
	# Night is the first-class look, so make the sky a showcase: a bright, rich star field + Milky Way and
	# a prominent soft moon. (All fade in with `night`; harmless at day where night=0.)
	sky_mat.set_shader_parameter("star_brightness", 2.0)
	sky_mat.set_shader_parameter("milkyway_brightness", 0.8)
	sky_mat.set_shader_parameter("moon_radius", 0.055)
	sky_mat.set_shader_parameter("moon_glow", 0.95)
	sky.sky_material = sky_mat
	env.sky = sky
	_sky_mat = sky_mat
	_sky_zenith = Moods.DAY["sky_zenith"]
	_sky_horizon = Moods.DAY["sky_horizon"]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.3
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.05    # gentle filmic contrast — reads a touch more cinematic on day AND night

	# Volumetric god-rays down the corridor (density is exponential -> keep it LOW).
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.02
	env.volumetric_fog_albedo = Color(0.85, 0.92, 1.0)
	env.volumetric_fog_anisotropy = 0.7               # forward-scatter -> beams bloom toward camera
	env.volumetric_fog_length = 80.0                  # longer reach down the now-longer corridor
	env.volumetric_fog_ambient_inject = 0.4
	env.volumetric_fog_emission = Color(0.05, 0.08, 0.12)
	env.volumetric_fog_detail_spread = 3.0
	# Classic aerial-perspective haze — denser now so the FAR land/sea edges of the bigger arena
	# dissolve into a horizon instead of showing a hard mesh edge. Tunable live (FOG sliders).
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.014
	env.fog_light_color = Color(0.78, 0.82, 0.85)
	env.fog_aerial_perspective = 0.55   # blends the distant terrain toward the sky -> reads as a hazy horizon
	env.fog_sun_scatter = 0.2

	we.environment = env
	_env = env

	# Reuse a Sun authored in the scene if present, else make one.
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "Sun"
		add_child(sun)
	sun.rotation_degrees = Vector3(-90.0, 0.0, 0.0)    # NOON: straight down -> no azimuth, so the
													   # lighting is identical whichever way the camera faces
													   # (now adjustable live via the SUN sliders)
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.2
	sun.light_angular_distance = 0.25                  # small, sharp disc (less blobby bloom)
	sun.light_volumetric_fog_energy = 3.0              # THE 'beams pop' dial (low density + high here)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0        # reaches further across the bigger arena
	_sun = sun


# Ground material (seabed.gdshader): ONE basin mesh covers everything — beaches, banks, AND the
# corridor floor (exposed once the trough sinks below it) — so the GROUND sliders drive it all.
# PBR "sand" (above water) blends to "sea-floor" (below). basin_enable 1 = full beach/bank/dune
# displacement; 0 = flat (kept for reuse, no longer instanced now the separate dry floor is gone).
# Ground PBR maps are generated at runtime rather than shipped. The original build used a
# purchased photo-scanned sand and sea-floor set, which cannot be redistributed, so the maps
# below are FastNoiseLite instead and the colour comes from the sand_color / wet_color tints.
# Swap in your own textures here if you want photographic ground.
const SAND_TINT  := Color(0.78, 0.62, 0.42)   # warm dry sand
const FLOOR_TINT := Color(0.42, 0.44, 0.40)   # damp grey-green seabed

func _make_ground_mat(basin_enable: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _seabed_shader
	m.set_shader_parameter("sea_level", SEA_LEVEL)
	m.set_shader_parameter("wet_front", SEA_LEVEL)
	m.set_shader_parameter("basin_enable", basin_enable)
	# Basin shape pushed from the constants so the GPU matches the CPU _seabed_height we walk on.
	m.set_shader_parameter("beach_start", BEACH_START)
	m.set_shader_parameter("beach_end", BEACH_END)
	m.set_shader_parameter("beach_height", BEACH_HEIGHT)
	m.set_shader_parameter("side_start", SIDE_START)
	m.set_shader_parameter("side_end", SIDE_END)
	m.set_shader_parameter("side_height", SIDE_HEIGHT)
	m.set_shader_parameter("dune_tex", _make_noise(0.6, true, false))
	m.set_shader_parameter("wetness_map", _make_noise(0.5, true, false))
	m.set_shader_parameter("caustic_tex", _make_noise(0.7, true, false, FastNoiseLite.TYPE_CELLULAR))
	# PBR ground maps, generated. Fine grain for the albedo/roughness break-up, a coarser
	# field for the normal so the surface reads as dune ripple rather than sandpaper.
	m.set_shader_parameter("sand_albedo",  _make_noise(3.5, true, false))
	m.set_shader_parameter("sand_normal",  _make_noise(1.4, true, true))
	m.set_shader_parameter("sand_rough",   _make_noise(2.2, true, false))
	m.set_shader_parameter("floor_albedo", _make_noise(2.8, true, false))
	m.set_shader_parameter("floor_normal", _make_noise(1.1, true, true))
	m.set_shader_parameter("floor_rough",  _make_noise(1.8, true, false))
	# The generated albedo is greyscale, so the tints carry the colour.
	m.set_shader_parameter("sand_color", SAND_TINT)
	m.set_shader_parameter("wet_color",  FLOOR_TINT)
	# Starting GROUND-slider values (the tuning panel re-applies these; keep its `v`s in sync).
	m.set_shader_parameter("sand_uv_scale", 0.25)
	m.set_shader_parameter("floor_uv_scale", 0.20)
	m.set_shader_parameter("ground_normal_strength", 1.0)
	m.set_shader_parameter("ground_roughness", 1.0)
	m.set_shader_parameter("wet_darken", 0.6)
	m.set_shader_parameter("caustic_strength", 0.5)
	m.set_shader_parameter("dune_amp", 0.7)
	return m


func _build_seabed() -> void:
	# Reuse the Seabed authored in the scene (for editor preview), else create it. Then REBUILD its
	# mesh + material from the constants so the GPU basin matches the CPU _seabed_height we walk on.
	var mi := get_node_or_null("Seabed") as MeshInstance3D
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Seabed"
		add_child(mi)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(SEABED_HALF * 2.0, SEABED_HALF * 2.0)
	mesh.subdivide_width = 240
	mesh.subdivide_depth = 240
	mi.mesh = mesh
	_seabed_mat = _make_ground_mat(1.0)
	mi.material_override = _seabed_mat
	mi.position = Vector3.ZERO


func _make_sea_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _water_shader
	m.set_shader_parameter("foam_tex", _make_noise(0.08, true, false))
	m.set_shader_parameter("noise_tex", _make_noise(0.04, true, false))
	m.set_shader_parameter("detail_normal", _make_noise(0.09, true, true))   # triplanar wall detail
	m.set_shader_parameter("density", density)
	m.set_shader_parameter("shallow_color", shallow_color)
	m.set_shader_parameter("deep_color", deep_color)
	m.set_shader_parameter("refraction", refraction)
	m.set_shader_parameter("fft_amplitude", 1.2)        # master wave-height dial for this scene
	m.set_shader_parameter("fft_normal_strength", 2.5)
	m.set_shader_parameter("choppiness", 1.0)           # horizontal choppiness (1.0 = full; wasn't the glitch)
	m.set_shader_parameter("disp_fine", 0.0)            # THE fix: keep fine FFT cascades OUT of the vertex
														# displacement (coarse mesh can't draw them -> facets);
														# they still shade via the fragment normal
	# ---- Baked-in tuned look (saved 2026-06-05 via the live panel -> tuning_values.txt). The
	#      panel re-applies these on build, but setting them here keeps the material correct even
	#      with the panel hidden/removed (and documents the chosen sweet spot). ----
	m.set_shader_parameter("foam_amount", 0.91)
	m.set_shader_parameter("fresnel_strength", 0.61)
	m.set_shader_parameter("sun_shininess", 100.0)
	m.set_shader_parameter("wall_streak_amount", 0.55)   # was 2.0 — heavy streaks read as foam STATIC
	m.set_shader_parameter("wall_flow_speed", 3.0)
	m.set_shader_parameter("crest_foam_amount", 0.8)
	m.set_shader_parameter("wall_wave_amp", 0.8)         # geometry heave from the SEA's FFT swell
	m.set_shader_parameter("wall_wave_scale", 1.0)       # 1.0 = wall waves match the open-sea size
	m.set_shader_parameter("wall_wave_normal", 1.0)      # FFT wave-normal detail on the wall surface
	m.set_shader_parameter("wall_wave_foam", 1.0)        # FFT whitecaps, same field as the open sea
	m.set_shader_parameter("detail_strength", 1.0)   # sea micro-noise only now (walls use the FFT normal)
	m.set_shader_parameter("detail_scale", 0.02)
	m.set_shader_parameter("triplanar_sharpness", 8.0)
	m.set_shader_parameter("sea_level", SEA_LEVEL)
	m.set_shader_parameter("corridor_half", CORRIDOR_HALF)
	m.set_shader_parameter("wall_width", WALL_WIDTH)
	m.set_shader_parameter("wall_falloff", WALL_FALLOFF)
	m.set_shader_parameter("crest_rise", CREST_RISE)
	m.set_shader_parameter("trough_bottom", TROUGH_BOTTOM)
	m.set_shader_parameter("part", 0.0)
	m.set_shader_parameter("sky_zenith", _sky_zenith)
	m.set_shader_parameter("sky_horizon", _sky_horizon)
	m.set_shader_parameter("ground_tint", _ground_tint)
	if _sun:
		m.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)   # light travel dir
		m.set_shader_parameter("sun_color", _sun.light_color * _sun.light_energy)
	# Draw the water FIRST among transparents (priority is the PRIMARY transparent sort key,
	# ahead of distance). Tall fx meshes — the pillar's god-beam / glory cloud — have AABB
	# centres that sort FARTHER than this huge plane, so by distance they drew BEFORE the
	# water, escaped its depth_draw_always depth, and bled over walls standing in front of
	# them. Drawn first, the water's depth occludes every later transparent per-pixel.
	m.render_priority = -1
	return m


func _build_water() -> void:
	# ONE heavily-subdivided plane; the vertex shader deforms it into the trough + walls. Reuse the
	# scene's "Water" node (it carries a flat preview material for the editor); swap in the real
	# shader material + a denser mesh at runtime.
	_sea_mat = _make_sea_mat()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(SEA_HALF_X * 2.0, SEA_HALF_Z * 2.0)
	mesh.subdivide_width = 900     # dense across the (now much) WIDER X so the cliff curve stays smooth
	mesh.subdivide_depth = 340
	_sea = get_node_or_null("Water") as MeshInstance3D
	if _sea == null:
		_sea = MeshInstance3D.new()
		_sea.name = "Water"
		add_child(_sea)
	_sea.mesh = mesh
	_sea.material_override = _sea_mat
	_sea.position = Vector3.ZERO   # the shader places the surface at world-Y itself


func _build_ocean_fft() -> void:
	# Drive the GodotOceanWaves FFT sim; it publishes displacement/normal/foam as global
	# uniforms our water shader samples. Needs a real RenderingDevice (skipped in headless).
	if RenderingServer.get_rendering_device() == null:
		return
	# Tuned SMALL: this is an intimate set-piece (corridor ~11m, sea_level 6), not an open
	# ocean. Wind/displacement are low so waves read as ~0.2-0.5m, and whitecap is high (less foam).
	var c0 := WaveCascadeParameters.new()       # big swell
	c0.tile_length = Vector2(64.0, 64.0)
	c0.displacement_scale = 0.5
	c0.normal_scale = 1.0
	c0.wind_speed = 20.0
	c0.wind_direction = 15.0
	c0.fetch_length = 250.0
	c0.swell = 0.7
	c0.whitecap = 0.61
	c0.foam_amount = 2.5
	var c1 := WaveCascadeParameters.new()       # medium chop
	c1.tile_length = Vector2(24.0, 24.0)
	c1.displacement_scale = 0.28
	c1.normal_scale = 0.9
	c1.wind_speed = 20.0
	c1.wind_direction = 15.0
	c1.fetch_length = 250.0
	c1.swell = 0.7
	c1.whitecap = 0.61
	c1.foam_amount = 2.5
	var c2 := WaveCascadeParameters.new()       # fine detail
	c2.tile_length = Vector2(9.0, 9.0)
	c2.displacement_scale = 0.14
	c2.normal_scale = 0.7
	c2.wind_speed = 20.0
	c2.wind_direction = 15.0
	c2.fetch_length = 250.0
	c2.swell = 0.7
	c2.whitecap = 0.61
	c2.foam_amount = 3.0
	var cascades: Array[WaveCascadeParameters] = [c0, c1, c2]
	_ocean = OceanFFT.new()
	_ocean.map_size = 256
	add_child(_ocean)
	_ocean.setup(_sea_mat, cascades)


func _build_fish() -> void:
	# Opaque fish hugging each cliff face at a consistent shallow depth, so they read THROUGH
	# the wall from the corridor and stay submerged whether the sea is flat or parted.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	_spawn_fish(1.0, rng)
	_spawn_fish(-1.0, rng)


func _spawn_fish(side: float, rng: RandomNumberGenerator) -> void:
	var palette := [
		Color(0.95, 0.55, 0.2), Color(0.9, 0.8, 0.25),
		Color(0.6, 0.75, 0.95), Color(0.85, 0.35, 0.35), Color(0.7, 0.7, 0.75)
	]
	for i in range(16):
		var target_y := rng.randf_range(1.8, 3.6)            # mid-wall: clearly submerged, water-tinted
		var face_x := _wall_face_x_for_y(target_y)
		var x := (face_x + rng.randf_range(0.7, 1.5)) * side  # a bit behind the face so the water colors them
		var y := target_y - 0.3
		var z := rng.randf_range(-(SEA_HALF_Z - 40.0), SEA_HALF_Z - 40.0)   # spread along the long corridor

		var fish := MeshInstance3D.new()
		var body := SphereMesh.new()
		body.radius = 0.34
		body.height = 1.5
		fish.mesh = body
		fish.scale = Vector3(0.42, 0.5, 1.4)   # slimmer + longer -> fish silhouette, not an egg
		var mat := StandardMaterial3D.new()
		var c: Color = palette[i % palette.size()]
		mat.albedo_color = c          # no emission: they should sit IN the water, not glow like beads
		mat.roughness = 0.65
		mat.rim_enabled = true
		mat.rim = 0.2
		fish.material_override = mat
		fish.position = Vector3(x, y, z)
		add_child(fish)
		_fish.append({
			"node": fish, "x": x, "y": y, "z0": z,
			"span": rng.randf_range(5.0, 13.0),
			"speed": rng.randf_range(0.25, 0.6),
			"phase": rng.randf_range(0.0, TAU),
			"bob": rng.randf_range(0.15, 0.4),
		})


func _build_moses() -> void:
	# Blocky Moses (the PLAYER) + a trailing herd, matching the game's voxel style.
	_moses = _make_blocky_person(Color("5b7fb4"), Color("caa472"), true)
	_moses.name = "Moses"
	_moses.position = Vector3(0.0, _terrain_height(0.0, START_Z) + FOOT_OFFSET, START_Z)
	add_child(_moses)
	_moses_mesh = _moses.get_node("MeshRoot")
	if game_mode:
		return   # the PersonSystem (game layer) populates the crossing instead of the demo herd
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var robes := [Color("8a6d3b"), Color("6b8f5a"), Color("9a5b4b"), Color("7a7a86"), Color("b08a4f")]
	for i in range(9):
		var f := _make_blocky_person(robes[i % robes.size()], Color("caa472"), false)
		# Flank Moses (sides + a little fore/aft) so a low corridor camera stays clear of them.
		var sx := 1.0 if i % 2 == 0 else -1.0
		var off := Vector3(sx * rng.randf_range(1.8, 4.8), 0.0, rng.randf_range(-3.0, 3.0))
		var pz: float = START_Z + off.z
		var w := _nearest_walkable(off.x, pz)   # don't spawn a follower in the (closed) shallows
		f.position = Vector3(w.x, _terrain_height(w.x, w.y) + FOOT_OFFSET, w.y)
		add_child(f)
		_walkers.append({"node": f, "mesh": f.get_node("MeshRoot"), "off": off,
			"phase": rng.randf_range(0.0, TAU), "speed": rng.randf_range(0.85, 1.25)})


func _make_blocky_person(robe: Color, skin: Color, is_moses: bool) -> Node3D:
	# The ROOT is the logical body: its Y is hard-snapped to the terrain so the feet stay planted.
	# All visuals hang off a "MeshRoot" child — the ONLY thing the walk wobble animates (the old
	# whole-root bob lifted the feet and read as floating). Faces +z; movement re-aims the root.
	var root := Node3D.new()
	var mesh := Node3D.new()
	mesh.name = "MeshRoot"
	root.add_child(mesh)
	mesh.add_child(_box(Vector3(0.7, 1.0, 0.5), Vector3(0.0, 0.6, 0.0), robe))     # torso
	mesh.add_child(_box(Vector3(0.45, 0.45, 0.45), Vector3(0.0, 1.32, 0.0), skin)) # head
	if is_moses:
		# Staff hangs from a hand-height pivot so the game layer can raise/lower it in cutscenes.
		var pivot := Node3D.new()
		pivot.name = "StaffPivot"
		pivot.position = Vector3(0.42, 1.0, -0.2)
		mesh.add_child(pivot)
		pivot.add_child(_box(Vector3(0.08, 1.7, 0.08), Vector3(0.0, -0.15, 0.0), Color("8a5a2b")))
	return root


# Walk wobble (ported from the sibling C# game's Locomotion.cs): a speed-scaled hop + side sway
# applied to the MESH child only — feet/ground snap live on the root and never leave the terrain.
# Returns the advanced phase (callers keep it per-character).
func _tick_wobble(mesh: Node3D, phase: float, speed: float, delta: float) -> float:
	var norm := minf(speed / 6.0, 1.2)
	phase += delta * (5.0 + norm * 7.0)
	mesh.position.y = absf(sin(phase)) * 0.12 * norm
	mesh.rotation.z = cos(phase) * 0.07 * norm
	return phase


func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.9
	mi.material_override = mat
	mi.position = pos
	return mi


func _build_splash() -> void:
	var p := GPUParticles3D.new()
	p.name = "Splash"
	p.amount = 1500     # spans the longer corridor
	p.lifetime = 1.4
	p.one_shot = true
	p.explosiveness = 0.85
	p.emitting = false
	p.position = Vector3(0.0, SEA_LEVEL, 0.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.5, 0.5, SEA_HALF_Z)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 35.0
	pm.initial_velocity_min = 8.0
	pm.initial_velocity_max = 16.0
	pm.gravity = Vector3(0, -18.0, 0)
	pm.scale_min = 0.2
	pm.scale_max = 0.7
	pm.color = Color(0.95, 0.98, 1.0)
	p.process_material = pm
	var dm := DrawPasses_quad()
	p.draw_pass_1 = dm
	_splash = p
	add_child(p)


func DrawPasses_quad() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.98, 1.0)
	m.emission_enabled = true
	m.emission = Color(0.8, 0.9, 1.0) * 0.5
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	q.material = m
	return q


func _build_wall_mist() -> void:
	# Fine spray drifting off the top of each wall of water (emits only while parted).
	var tex := _soft_dot()
	var crest_x := CORRIDOR_HALF + WALL_WIDTH
	var crest_y := SEA_LEVEL + CREST_RISE
	for sx in [1.0, -1.0]:
		var p := GPUParticles3D.new()
		p.name = "WallMist"
		p.amount = 520     # spans the longer wall
		p.lifetime = 2.4
		p.preprocess = 1.5
		p.emitting = false
		p.position = Vector3(sx * crest_x, crest_y - 0.6, 0.0)
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.7, 0.5, SEA_HALF_Z)
		pm.direction = Vector3(sx, 1.3, 0.0).normalized()   # up + outward, away from the corridor
		pm.spread = 35.0
		pm.initial_velocity_min = 1.0
		pm.initial_velocity_max = 4.0
		pm.gravity = Vector3(0.0, -4.5, 0.0)
		pm.scale_min = 0.6
		pm.scale_max = 1.9
		pm.color = Color(0.92, 0.96, 1.0, 0.5)
		p.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(1.0, 1.0)
		var qm := StandardMaterial3D.new()
		qm.albedo_texture = tex
		qm.albedo_color = Color(0.95, 0.98, 1.0, 0.5)
		qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		q.material = qm
		p.draw_pass_1 = q
		add_child(p)
		_mist.append(p)


func _soft_dot() -> ImageTexture:
	# A soft round alpha sprite so the spray reads as mist, not squares.
	var s := 48
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := (s - 1) * 0.5
	for y in s:
		for x in s:
			var d := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


func _flame_mask() -> ImageTexture:
	# A GRAYSCALE round/teardrop mask for the fire particles: the falloff lives in the RGB (red) channel
	# (the fire shader reads .r), so each billboard is shaped into a soft blob instead of a hard square.
	# Slightly taller-than-round + a bit higher centre -> a flame-ish lobe; the noise erosion does the rest.
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := (s - 1) * 0.5
	for y in s:
		for x in s:
			var dx := (float(x) - c) / c
			var dy := (float(y) - c) / c * 0.82          # squash y -> taller lobe
			var d := Vector2(dx, dy + 0.12).length()     # nudge centre down a touch
			var v := clampf(1.0 - d, 0.0, 1.0)
			v = smoothstep(0.0, 0.85, v)                 # soft, generous core
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return ImageTexture.create_from_image(img)


func _rain_streak() -> ImageTexture:
	# A soft, tapered vertical streak: feathered SIDES (so it isn't a hard-edged bar), fading ENDS, and a
	# touch brighter toward the falling (bottom) end — so a drop reads as a translucent smear of light, not
	# a solid white rectangle. White alpha-shape only; the cool tint + master opacity come from pm.color.
	var w := 16
	var h := 96
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx := (w - 1) * 0.5
	for y in h:
		var v := float(y) / float(h - 1)                                 # 0 top -> 1 bottom
		var ends := smoothstep(0.0, 0.22, v) * (1.0 - smoothstep(0.80, 1.0, v))
		var head := lerpf(0.5, 1.0, v)                                   # brighter toward the leading end
		for x in w:
			var side := clampf(1.0 - absf(float(x) - cx) / cx, 0.0, 1.0)
			side = side * side                                           # feathered sides
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, side * ends * head))
	return ImageTexture.create_from_image(img)


func _set_wall_mist(on: bool) -> void:
	for m in _mist:
		if m.emitting != on:
			m.emitting = on


func _build_rain() -> void:
	# A wide curtain of falling streaks that FOLLOWS the player (the slab re-centers on Moses each
	# frame in world space, so rain is always around you). Hidden until storm mode (N) turns it on.
	var p := GPUParticles3D.new()
	p.name = "Rain"
	p.amount = 7000                    # raised with RAIN_AREA so the wider curtain doesn't read as sparse
	p.lifetime = 1.5
	p.preprocess = 1.5                 # start mid-storm, not with an empty sky
	p.local_coords = false             # streaks fall through WORLD space while the emitter slab moves
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_DISABLED   # orientation is the material billboard's job
	p.emitting = false
	p.visible = false
	p.position = Vector3(0.0, RAIN_TOP, 0.0)
	# CRITICAL: with local_coords = false the emitter rides ~RAIN_TOP above the player, so the default
	# 8 m visibility AABB sits high above the camera's view and the WHOLE system gets frustum-culled
	# (the rain just never appears). Give it a box big enough to span the full fall volume so it's
	# always considered on-screen. (AABB is position = near corner, then size.)
	p.visibility_aabb = AABB(
		Vector3(-RAIN_AREA - 5.0, -72.0, -RAIN_AREA - 5.0),
		Vector3((RAIN_AREA + 5.0) * 2.0, 80.0, (RAIN_AREA + 5.0) * 2.0))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(RAIN_AREA, 1.5, RAIN_AREA)
	pm.direction = Vector3(0.18, -1.0, 0.05)    # a little wind slant so it isn't dead-vertical
	pm.spread = 3.0
	pm.gravity = Vector3(0.0, -28.0, 0.0)
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 24.0
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	# The per-particle COLOR carries the cool BLUE tint AND the master opacity (kept translucent so streaks
	# read as wet light, not solid bars); the soft streak TEXTURE shapes the alpha, the white albedo just
	# lets pm.color through. (Two alphas multiply, so keep albedo at a=1.)
	pm.color = Color(0.62, 0.76, 1.0, 0.55)
	p.process_material = pm
	# A thin TALL quad carrying the soft streak TEXTURE. **BILLBOARD_FIXED_Y** is the key: the streak stays
	# VERTICAL (world Y) but yaws to face the camera, i.e. a cylindrical billboard. That gives BOTH things
	# rain needs: it's visible from every horizontal angle (so it no longer vanishes when you face the sea),
	# AND looking DOWN the rain it foreshortens — the upright quad is seen edge-on from above, so it shrinks
	# to a short dash instead of a rigid bar. Width a touch thicker than the old hard bar so the feathered
	# texture body has room to read.
	var q := QuadMesh.new()
	q.size = Vector2(0.1, 1.2)
	var qm := StandardMaterial3D.new()
	# UNSHADED so the streaks stay a constant cool colour against the near-black night (NOT dimmed by the
	# 0.34-energy moonlight); the soft texture's alpha + the translucent pm.color do the rest.
	qm.albedo_texture = _rain_streak()
	qm.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	qm.billboard_keep_scale = true
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	q.material = qm
	p.draw_pass_1 = q
	add_child(p)
	_rain = p


func _build_rain_splash() -> void:
	# Fakes rain IMPACTS: tiny droplet bursts popping UP off the ground around the player's feet. There's
	# no collidable mesh (the seabed is GPU vertex-displaced), so instead of ONE flat slab (which floats /
	# buries at its edges on sloped ground) we build several thin Z-STRIPS. Each strip rides at its OWN
	# _terrain_height sample each frame (see _update_weather), so the field STAIR-STEPS down a slope and
	# hugs the ground; on the flat corridor all strips sit at the same height (exact).
	_rain_splashes.clear()
	var per := int(3900.0 / float(SPLASH_STRIPS))        # ~3900 splashes spread across the wide field
	var strip_half: float = SPLASH_STRIP_STEP * 0.6      # slight overlap between adjacent strips
	var soft := _soft_dot()
	for i in range(SPLASH_STRIPS):
		var p := GPUParticles3D.new()
		p.name = "RainSplash%d" % i
		p.amount = per
		p.lifetime = 0.5
		p.local_coords = false             # splashes stay put in the world as the emitter slab follows you
		p.emitting = false
		p.visible = false
		p.visibility_aabb = AABB(
			Vector3(-SPLASH_AREA - 3.0, -2.0, -strip_half - 2.0),
			Vector3((SPLASH_AREA + 3.0) * 2.0, 8.0, (strip_half + 2.0) * 2.0))
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(SPLASH_AREA, 0.02, strip_half)   # wide in x, THIN in z (one step)
		pm.direction = Vector3(0.0, 1.0, 0.0)       # pop straight up...
		pm.spread = 60.0                            # ...flaring into a little crown
		pm.gravity = Vector3(0.0, -10.0, 0.0)       # and fall right back -> a quick blip
		pm.initial_velocity_min = 1.1
		pm.initial_velocity_max = 2.6
		pm.scale_min = 0.5
		pm.scale_max = 1.0
		pm.color = Color(0.86, 0.92, 1.0, 0.85)
		p.process_material = pm
		# Small round droplets (soft dot sprite, camera-facing) — symmetric, so a plain billboard is fine.
		var q := QuadMesh.new()
		q.size = Vector2(0.08, 0.08)
		var qm := StandardMaterial3D.new()
		qm.albedo_texture = soft
		qm.albedo_color = Color(0.9, 0.95, 1.0, 0.85)
		qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		q.material = qm
		p.draw_pass_1 = q
		add_child(p)
		_rain_splashes.append(p)


func _set_rain(on: bool) -> void:
	if _rain:
		_rain.visible = true
		_rain.emitting = on
	for s in _rain_splashes:
		s.visible = true
		s.emitting = on


func _build_collision_markers() -> void:
	# Two translucent vertical planes at the player/herd confinement boundary (x = +/-CORRIDOR_HALF),
	# running the FULL corridor length, so it's easy to SEE the no-go / water edge when placing scenery.
	# Authored in red_sea.tscn so they're visible in the EDITOR (where you place props); rebuilt here from
	# the constants so they always match the corridor lane in _is_walkable. HIDDEN at runtime — `C` shows it.
	var root := get_node_or_null("CollisionMarkers") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "CollisionMarkers"
		add_child(root)
	for c in root.get_children():
		root.remove_child(c)                            # detach NOW (queue_free is deferred) so the fresh
		c.queue_free()                                  # children below can reuse the same names cleanly
	var mesh := QuadMesh.new()
	mesh.size = Vector2(SEA_HALF_Z * 2.0, 18.0)         # spans Z (length) x Y (height ~ -3..15)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.9, 1.0, 0.16)      # translucent cyan "no-go" marker
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED        # visible from both sides
	for sx in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		mi.name = "CollisionWall%s" % ("R" if sx > 0.0 else "L")
		mi.mesh = mesh
		mi.material_override = mat
		mi.rotation = Vector3(0.0, PI / 2.0, 0.0)       # face +/-X so the quad's width runs along Z
		mi.position = Vector3(sx * CORRIDOR_HALF, 6.0, 0.0)
		root.add_child(mi)
	root.visible = false                                # editor shows them; in-game start hidden (C toggles)
	_collision_markers = root


# =====================================================================================
#  Pillar of fire — Yahweh's presence. A stylized flickering FLAME that is also a real
#  dynamic LIGHT, built under one node so the whole thing moves as a unit (the game layer
#  repositions it via set_pillar_target()/warp_pillar_to() to lead the Hebrews or interpose
#  between them and the Egyptians). Flame = a swirling CLOUD of stylized fire particles
#  (Minionsart/GDQuest alpha-erosion, pillar_fire.gdshader); embers = sparks flecking off it;
#  one flickering OmniLight3D (+ fog glow). It WHIRLS because the cloud is spun by a strong
#  tangential acceleration -> a fire-tornado.
# =====================================================================================

func _build_pillar_of_fire() -> void:
	var root := Node3D.new()
	root.name = "PillarOfFire"
	add_child(root)
	_pillar = root

	# PILLAR OF FIRE — Yahweh's "Shekinah glory": a procedural-fbm flame column (outer shell + hot core),
	# licking tongues, embers, slow rising glory-motes, a god-BEAM of light reaching toward the sky, and a
	# swirling glory-CLOUD shroud — plus its own flicker-driven flood-lights. Self-contained EMISSION-additive
	# package adapted from godot-effects (res://fire/pillar_of_fire.tscn), instanced UNDER our movable root so
	# the whole glory glides/rides with the pillar; the package's script drives its flicker + lights. (_build
	# keeps only the root + placement; movement/base-follow still live in _update_pillar. The old hand-built
	# layers + lights are retired — the now-null _pillar_light/_pillar_fire/etc. simply skip their code there.)
	var fx := load("res://fire/pillar_of_fire.tscn").instantiate() as Node3D
	root.add_child(fx)
	_pillar_fx = fx
	fx.scale = Vector3(1.3, 1.3, 1.3)                     # BIGGER: ~39 m flame + a higher god-beam

	# Opaque white-hot HEART inside the package's additive flame. Additive blending can never
	# OCCLUDE — without a depth-writing core the sea walls / foam read straight through the
	# column (the old hand-built pillar needed the exact same trick). Child of the fx root so
	# it rides the package's visibility and the animator's squash/stretch for free; tapered
	# like the flame so it never silhouettes outside the tongues.
	var core := MeshInstance3D.new()
	core.name = "OpaqueCore"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.8        # generous: the core must back MOST of the visual column width,
	cm.bottom_radius = 1.35    # or bright foam walls read through the additive edges; it glows
	cm.height = 27.0           # flame-coloured, so slight peeking just looks like flame body
	cm.radial_segments = 24
	var core_mat := StandardMaterial3D.new()
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.albedo_color = Color(1.0, 0.62, 0.22)
	core_mat.emission_enabled = true
	core_mat.emission = Color(1.0, 0.56, 0.2)
	core_mat.emission_energy_multiplier = 2.6             # glows like the inner flame; orange, so
	core_mat.disable_receive_shadows = true               # no teal-water green-bloom risk
	cm.material = core_mat
	core.mesh = cm
	core.position = Vector3(0.0, 13.5, 0.0)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.add_child(core)

	# Default: blaze on the sea AHEAD of the group, centreline, leading them toward the crossing. Over the
	# un-parted sea the base is floored to the waterline (_pillar_base_y) so it stands ON the water, not
	# sunk under it; once parted + led inward it descends to the drained corridor floor with the herd.
	var px := 0.0
	var pz := START_Z + 8.0
	_pillar_target = Vector3(px, _pillar_base_y(px, pz), pz)
	_pillar_pos = _pillar_target
	root.global_position = _pillar_pos


func _update_pillar(delta: float) -> void:
	if not _pillar:
		return
	# ---- Flicker: layered sines (cheap, deterministic) drive the light energy/colour + a tiny positional
	#      dance, and the SAME envelope feeds the shader so the flame body breathes in sync with the cast
	#      light. Range kept lively but never strobing. ----
	var t := _elapsed
	var flick: float = 0.62 + 0.21 * sin(t * 11.0) + 0.11 * sin(t * 17.3 + 1.7) + 0.06 * sin(t * 29.0 + 4.1)
	flick = clampf(flick, 0.2, 1.05)
	if _pillar_light:
		_pillar_light.light_energy = PILLAR_LIGHT_ENERGY * (0.65 + 0.5 * flick)
		_pillar_light.light_color = Color(1.0, lerpf(0.5, 0.68, flick), lerpf(0.16, 0.34, flick))
		_pillar_light.position = Vector3(
			sin(t * 7.3) * 0.16,
			4.0 + sin(t * 5.1) * 0.12,                                   # low pool, decoupled from the taller column
			cos(t * 6.7) * 0.16)
	if _pillar_light_hi:                                                 # the high glow up the column, a touch dimmer
		_pillar_light_hi.light_energy = PILLAR_LIGHT_ENERGY * 0.55 * (0.6 + 0.55 * flick)
		_pillar_light_hi.light_color = Color(1.0, lerpf(0.42, 0.6, flick), lerpf(0.12, 0.28, flick))
		_pillar_light_hi.position = Vector3(
			sin(t * 4.7) * 0.5,
			PILLAR_HEIGHT * 0.6 + sin(t * 3.9) * 0.4,
			cos(t * 5.3) * 0.5)
	if _pillar_fire_mat:
		_pillar_fire_mat.set_shader_parameter("time", _anim_time)        # held during the wave frame-step (P)
		_pillar_fire_mat.set_shader_parameter("intensity", 1.55 * (0.85 + 0.25 * flick))   # glow breathes too
	if _pillar_core_mat:                                                 # opaque heart breathes in sync
		_pillar_core_mat.set_shader_parameter("time", _anim_time)
		_pillar_core_mat.set_shader_parameter("intensity", 1.5 * (0.85 + 0.25 * flick))
	if _pillar_shell_mat:                                               # additive flame shell breathes too
		_pillar_shell_mat.set_shader_parameter("time", _anim_time)
		_pillar_shell_mat.set_shader_parameter("intensity", 1.35 * (0.82 + 0.32 * flick))

	# ---- Movement: arrow keys nudge the target (a quick way to SEE it's a movable light); the game layer
	#      will instead call set_pillar_target()/warp_pillar_to(). The pillar GLIDES toward the target on the
	#      XZ plane (horizontal speed is exactly PILLAR_GLIDE, slope-independent), then snaps its base to the
	#      ground/waterline via _pillar_base_y so it never sinks under the un-parted sea. ----
	var nudge := debug_enabled or not game_mode   # arrow-key demo nudge is sandbox-only
	var ax := (1.0 if nudge and Input.is_key_pressed(KEY_RIGHT) else 0.0) \
		- (1.0 if nudge and Input.is_key_pressed(KEY_LEFT) else 0.0)
	var az := (1.0 if nudge and Input.is_key_pressed(KEY_UP) else 0.0) \
		- (1.0 if nudge and Input.is_key_pressed(KEY_DOWN) else 0.0)
	if ax != 0.0 or az != 0.0:
		_pillar_target.x = clampf(_pillar_target.x + ax * PILLAR_NUDGE * delta, -SEA_HALF_X + 2.0, SEA_HALF_X - 2.0)
		_pillar_target.z = clampf(_pillar_target.z + az * PILLAR_NUDGE * delta, -SEA_HALF_Z + 2.0, SEA_HALF_Z - 2.0)
	var cur := _pillar_pos
	var flat_target := Vector3(_pillar_target.x, cur.y, _pillar_target.z)   # glide horizontally...
	var nxt := cur.move_toward(flat_target, PILLAR_GLIDE * delta)
	# ...then EASE the base toward the ground/waterline. _pillar_base_y is a STEP (it jumps at the moment the
	# sea parts past the walkable threshold, and across the corridor edge), so easing the Y instead of hard-
	# setting it turns that one-frame ~3 m pop into a smooth descent into the drained corridor.
	nxt.y = lerpf(cur.y, _pillar_base_y(nxt.x, nxt.z), clampf(delta * PILLAR_BASE_FOLLOW, 0.0, 1.0))
	# The glide/base-follow owns the GROUND anchor; the PillarAnimator's descend/ascend rides on a
	# separate vertical offset so the two never fight.
	_pillar_pos = nxt
	_pillar.global_position = _pillar_pos + Vector3(0.0, pillar_y_offset, 0.0)


# ---- Pillar-of-fire movement API (for the game layer: lead the Hebrews, interpose vs the Egyptians) ----
func _pillar_base_y(x: float, z: float) -> float:
	# Where the flame's base sits at (x, z): the ground it's standing on, but floored to the WATERLINE while
	# it's over un-parted sea (so the fire rides ON the closed sea instead of sinking under it). Once the sea
	# is parted, the corridor is walkable -> it drops to the drained floor with the herd it's leading.
	var t := _terrain_height(x, z)
	return t if _is_walkable(x, z) else maxf(t, SEA_LEVEL)


func set_pillar_target(x: float, z: float) -> void:
	# Glide the pillar of fire to world (x, z); its base follows the ground/waterline. Call repeatedly to lead a path.
	_pillar_target = Vector3(x, _pillar_base_y(x, z), z)


func warp_pillar_to(x: float, z: float) -> void:
	# Instantly place the pillar at world (x, z) (no glide).
	_pillar_target = Vector3(x, _pillar_base_y(x, z), z)
	_pillar_pos = _pillar_target
	if _pillar:
		_pillar.global_position = _pillar_pos + Vector3(0.0, pillar_y_offset, 0.0)


func pillar_position() -> Vector3:
	# The GROUND anchor (descend/ascend offset excluded) — what game logic should measure against.
	return _pillar_pos if _pillar else Vector3.ZERO


func is_frozen() -> bool:
	# The P frame-step freeze — game-layer systems early-out so a paused frame stays fully static.
	return _step_paused


func add_trauma(amount: float) -> void:
	# Camera shake (decays in _process); maxf so overlapping hits don't cancel a bigger shake.
	_shake = maxf(_shake, amount)


# =====================================================================================
#  Weather / mood — clear NOON <-> stormy NIGHT, with rain + sheet-lightning flashes.
# =====================================================================================

func _toggle_storm() -> void:
	_storm_target = 0.0 if _storm_target > 0.5 else 1.0
	_weather_dirty = true
	_set_rain(_storm_target > 0.5)
	if _storm_target > 0.5:                 # arm the first strike a few seconds in
		_strike_timer = randf_range(2.0, 5.0)
	else:
		_end_flash()                        # toggling back to day mid-strike: cancel + restore the base


func _update_weather(delta: float) -> void:
	# Cross-fade the mood scalar toward its target.
	var fading := absf(_storm_t - _storm_target) > 0.0005
	if fading:
		_storm_t = move_toward(_storm_t, _storm_target, delta / STORM_FADE)

	# Lightning only in the storm (and not while fading). Game mode: the director/MoodController
	# owns the gate (lightning_override); sandbox: derived from the storm scalar as before.
	var lightning_on := (lightning_override if game_mode else _storm_t > 0.85) and not fading
	if lightning_on:
		_update_lightning(delta)
	elif _flashing or _flash_level > 0.0001 or not _flash_base.is_empty():
		_end_flash()                       # left the storm window mid-strike -> cancel + restore base

	# Keep the rain curtain centered on the player (world-space fall, moving emitter), and ride the splash
	# slab at the player's foot height so impacts pop off the floor they're standing on.
	if _rain and _moses:
		_rain.global_position = _moses.position + Vector3(-2.0, RAIN_TOP, 0.0)
	if _moses and not _rain_splashes.is_empty():
		var fx := _moses.position.x
		var fz := _moses.position.z
		var n := _rain_splashes.size()
		for i in range(n):
			# Stair-step the strips along z, each locked to ITS OWN terrain height so the field hugs slopes.
			var sz: float = fz + (float(i) - float(n - 1) * 0.5) * SPLASH_STRIP_STEP
			_rain_splashes[i].global_position = Vector3(fx, _terrain_height(fx, sz) + 0.05, sz)

	# BASE look: only written while the mood is actually changing (a fade or a fresh toggle), so the
	# FOG/SUN tuning sliders keep full ownership of the steady state. `_was_applying` guarantees ONE
	# final settling write when a fade ends.
	var base_applying := fading or _weather_dirty
	if base_applying or _was_applying:
		_apply_mood(_storm_t)
		_sync_mood_sliders(_storm_t)        # keep the SUN/FOG sliders tracking the fade live
	_was_applying = base_applying
	_weather_dirty = false

	# FLASH overlay: applied ON TOP of (and restored back to) the live base, so a strike is purely
	# additive and never permanently rewrites the sun/sky — this is what stops lightning from
	# "resetting" a panel-tuned sun brightness. Runs after the base write so it layers correctly.
	if _flashing or _flash_level > 0.0001 or not _flash_base.is_empty():
		_apply_flash(_flash_level)


func _update_lightning(delta: float) -> void:
	if not _flashing:
		_strike_timer -= delta
		if _strike_timer > 0.0:
			return
		# Fire a strike: a short multi-flicker envelope (lightning rarely flashes just once).
		_flashing = true
		lightning_strike.emit()
		_flash_clock = 0.0
		_flash_pulses = [{"t": 0.0, "amp": 1.0}]
		var t := 0.0
		for _i in range(randi_range(1, 2)):
			t += randf_range(0.06, 0.17)
			_flash_pulses.append({"t": t, "amp": randf_range(0.45, 0.9)})
		_strike_timer = randf_range(5.0, 13.0)   # next strike
		return
	# Envelope: each pulse spikes then decays fast; the flash level is their max.
	_flash_clock += delta
	var lvl := 0.0
	var last_t := 0.0
	for p in _flash_pulses:
		last_t = maxf(last_t, p.t)
		if _flash_clock >= p.t:
			lvl = maxf(lvl, p.amp * exp(-(_flash_clock - p.t) * 7.5))
	_flash_level = lvl
	if _flash_clock > last_t + 0.9 and lvl < 0.01:
		_flashing = false
		_flash_level = 0.0


# Back-compat scalar path (sandbox N-toggle / storm fade): blend DAY -> NIGHT_STORM by `storm`.
func _apply_mood(storm: float) -> void:
	apply_mood_values(Moods.blend(Moods.DAY, Moods.NIGHT_STORM, clampf(storm, 0.0, 1.0)))


# Write ONE mood (a preset or any blend of presets) to the scene. This is the BASE look only (no
# lightning) — the flash is a separate captured/restored additive overlay (_apply_flash) so it can
# never permanently rewrite these. Writes the Environment, the sun/moon light, the starry-sky shader
# AND the unlit water uniforms (the water is EMISSION-only: it follows light/sky purely through
# sun_*/sky_*). Keys: see scripts/game/mood_presets.gd.
func apply_mood_values(m: Dictionary) -> void:
	# --- Sky (the BG_SKY background + what the water reflects); `sky_night` fades the stars in ---
	var zenith: Color = m["sky_zenith"]
	var horizon: Color = m["sky_horizon"]
	var ground: Color = m["ground_tint"]
	if _sky_mat:
		_sky_mat.set_shader_parameter("zenith_color", zenith)
		_sky_mat.set_shader_parameter("horizon_color", horizon)
		_sky_mat.set_shader_parameter("ground_color", m["sky_ground"])
		_sky_mat.set_shader_parameter("night", m["sky_night"])

	# --- Sun / moon (lit opaque geometry + shadows + god-rays) ---
	if _sun:
		_sun.rotation_degrees = Vector3(m["sun_pitch"], m["sun_yaw"], 0.0)
		var lcol: Color = m["sun_color"]
		var lenergy: float = m["sun_energy"]
		_sun.light_color = lcol
		_sun.light_energy = lenergy
		_sun.light_volumetric_fog_energy = m["sun_beam"]
		# Feed the unlit water: direction + (color*energy), so its glint/fresnel/form track the moon.
		if _sea_mat:
			_sea_mat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)
			_sea_mat.set_shader_parameter("sun_color", lcol * lenergy)

	# --- Environment (ambient, glow/bloom, both fog systems) ---
	if _env:
		_env.ambient_light_energy = m["ambient"]
		_env.glow_intensity = m["glow"]
		_env.glow_hdr_threshold = m["glow_thresh"]
		_env.volumetric_fog_density = m["vfog_density"]
		_env.volumetric_fog_albedo = m["vfog_albedo"]
		_env.volumetric_fog_emission = m["vfog_emission"]
		_env.volumetric_fog_ambient_inject = m["vfog_inject"]
		_env.fog_density = m["fog_density"]
		_env.fog_light_color = m["fog_light"]

	# Keep the water's stored sky tints current too (used if the material is rebuilt).
	_sky_zenith = zenith
	_sky_horizon = horizon
	_ground_tint = ground
	if _sea_mat:
		_sea_mat.set_shader_parameter("sky_zenith", zenith)
		_sea_mat.set_shader_parameter("sky_horizon", horizon)
		_sea_mat.set_shader_parameter("ground_tint", ground)


func cancel_flash() -> void:
	# Public for the game layer: a mood transition must never tween UNDER a flash snapshot
	# (the strike would restore stale values over the new look when it decays).
	_end_flash()


# ---- Lightning flash: a captured-then-restored ADDITIVE overlay ----------------------------------
# At the first frame of a strike we snapshot the live look (which may be a panel-tuned night, not just
# the preset); each frame we add the flash on top of that snapshot; when the strike fully decays we
# write the snapshot back verbatim. Net effect: a flash brightens everything briefly and then leaves
# the scene EXACTLY as it found it — so it can never reset the sun's (or any) tuned brightness.
func _capture_flash_base() -> void:
	_flash_base = {}
	if _sun:
		_flash_base["sun_color"] = _sun.light_color
		_flash_base["sun_energy"] = _sun.light_energy
		_flash_base["sun_beam"] = _sun.light_volumetric_fog_energy
	if _env:
		_flash_base["ambient"] = _env.ambient_light_energy
		_flash_base["glow"] = _env.glow_intensity
		_flash_base["vfog_albedo"] = _env.volumetric_fog_albedo
		_flash_base["fog_light"] = _env.fog_light_color
	if _sky_mat:
		_flash_base["zenith"] = _sky_mat.get_shader_parameter("zenith_color")
		_flash_base["horizon"] = _sky_mat.get_shader_parameter("horizon_color")
	if _sea_mat:
		_flash_base["sea_sun"] = _sea_mat.get_shader_parameter("sun_color")


func _restore_flash_base() -> void:
	if _flash_base.is_empty():
		return
	var b := _flash_base
	if _sun and b.has("sun_color"):
		_sun.light_color = b["sun_color"]
		_sun.light_energy = b["sun_energy"]
		_sun.light_volumetric_fog_energy = b["sun_beam"]
	if _env and b.has("ambient"):
		_env.ambient_light_energy = b["ambient"]
		_env.glow_intensity = b["glow"]
		_env.volumetric_fog_albedo = b["vfog_albedo"]
		_env.fog_light_color = b["fog_light"]
	if _sky_mat and b.has("zenith"):
		_sky_mat.set_shader_parameter("zenith_color", b["zenith"])
		_sky_mat.set_shader_parameter("horizon_color", b["horizon"])
	if _sea_mat and b.has("sea_sun"):
		_sea_mat.set_shader_parameter("sun_color", b["sea_sun"])


func _end_flash() -> void:
	_flashing = false
	_flash_level = 0.0
	_flash_pulses = []
	_restore_flash_base()
	_flash_base = {}


func _apply_flash(flash: float) -> void:
	var f := clampf(flash, 0.0, 1.0)
	if _flash_base.is_empty():
		_capture_flash_base()              # snapshot the live base on the strike's first frame
	var b := _flash_base
	# Sun pops cold-white and brighter, on top of whatever the base sun was.
	if _sun and b.has("sun_color"):
		_sun.light_color = (b["sun_color"] as Color).lerp(FLASH_SUN_COLOR, f)
		_sun.light_energy = float(b["sun_energy"]) + f * 3.4
		_sun.light_volumetric_fog_energy = float(b["sun_beam"]) + f * 4.0
	# Ambient / glow bloom; fog catches the flash.
	if _env and b.has("ambient"):
		_env.ambient_light_energy = float(b["ambient"]) + f * 1.6
		_env.glow_intensity = float(b["glow"]) + f * 0.5
		_env.volumetric_fog_albedo = (b["vfog_albedo"] as Color).lerp(Color(1, 1, 1), f * 0.6)
		_env.fog_light_color = (b["fog_light"] as Color).lerp(FLASH_SKY, f * 0.7)
	# Sky washes toward the cold flash white (briefly drowning the stars, as a real lightning sheet does).
	if _sky_mat and b.has("zenith"):
		_sky_mat.set_shader_parameter("zenith_color", (b["zenith"] as Color).lerp(FLASH_SKY, f * 0.85))
		_sky_mat.set_shader_parameter("horizon_color", (b["horizon"] as Color).lerp(FLASH_SKY, f * 0.90))
	# Unlit water tracks the sun pop.
	if _sea_mat and _sun:
		_sea_mat.set_shader_parameter("sun_color", _sun.light_color * _sun.light_energy)

	# Strike fully decayed: put the snapshot back verbatim and clear it.
	if not _flashing and f <= 0.0001:
		_restore_flash_base()
		_flash_base = {}


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.fov = 62.0
	_camera.far = 800.0      # bigger arena — see the distant sea/land before the fog hides the edge
	add_child(_camera)
	_camera.current = true
	_update_orbit_camera(0.0)                            # snap in behind Moses


func _update_orbit_camera(shake_amp: float) -> void:
	if not _moses:
		return
	var pivot: Vector3 = _moses.position + Vector3(0.0, CAM_PIVOT_Y, 0.0)
	# dir points pivot -> camera (behind + above, by yaw/pitch)
	var cp := cos(_cam_pitch)
	var dir := Vector3(sin(_cam_yaw) * cp, sin(_cam_pitch), cos(_cam_yaw) * cp)
	# March the boom out from the pivot; pull the camera IN if the seabed/dune OR a towering water
	# wall would block it, so Moses never hides behind a hill and the cam can't shove back through a
	# wall (the cam keeps full reach on the flat corridor where nothing blocks).
	var dist := _cam_dist
	var steps := 14
	for i in range(1, steps + 1):
		var f := _cam_dist * float(i) / float(steps)
		var p := pivot + dir * f
		var blocker := maxf(_terrain_height(p.x, p.z), _wall_surface_height(p.x, p.z))
		if p.y < blocker + 0.5:
			dist = _cam_dist * float(i - 1) / float(steps)
			break
	dist = maxf(dist, 1.8)
	var cam_pos: Vector3 = pivot + dir * dist
	if shake_amp > 0.0:
		cam_pos += Vector3(randf_range(-shake_amp, shake_amp),
			randf_range(-shake_amp, shake_amp), randf_range(-shake_amp, shake_amp))
	_camera.position = cam_pos
	_camera.look_at(pivot, Vector3.UP)


func _build_drown_overlay() -> void:
	var cl := CanvasLayer.new()
	var rect := ColorRect.new()
	rect.color = Color(0.05, 0.18, 0.28, 0.0)   # alpha pulsed at the slam
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(rect)
	_drown_rect = rect
	add_child(cl)


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	var label := Label.new()
	label.text = "WASD  move      hold RMB  look      wheel  zoom      Shift  sprint      F1  debug on / off\nE  part / close the sea      N  day / night  (storm: rain + lightning)      R  auto demo      C  collision area      H  hide panel      P  freeze waves ( ] / [ step )\n↑ ↓ ← →  move the pillar of fire      GAME:  1-4  mood presets      5/6  mood fades      7/8  pillar down / up      9  dialog test      0  jump to the chase"
	label.position = Vector2(18, 14)
	var ls := LabelSettings.new()
	ls.font_color = Color(1, 1, 1)
	ls.outline_color = Color(0, 0, 0, 0.85)
	ls.outline_size = 5
	ls.font_size = 16
	label.label_settings = ls
	label.visible = not game_mode               # game mode: debug help only while F1 is on
	_help_label = label
	cl.add_child(label)

	_step_label = Label.new()
	_step_label.position = Vector2(18, 96)
	var ss := LabelSettings.new()
	ss.font_color = Color(1.0, 0.85, 0.3)
	ss.outline_color = Color(0, 0, 0, 0.9)
	ss.outline_size = 5
	ss.font_size = 18
	_step_label.label_settings = ss
	_step_label.visible = false
	cl.add_child(_step_label)
	add_child(cl)


func _build_tuning() -> void:
	_tuning = TuningPanel.new()
	add_child(_tuning)
	_tuning.setup(_sea_mat, _ocean, _env, _sun, [_seabed_mat])
	if game_mode:
		_tuning.set_shown(false)                # F1 brings the panel (and the rest of the suite) back


# =====================================================================================
#  Input
# =====================================================================================

func _unhandled_input(event: InputEvent) -> void:
	# F1 flips the whole sandbox/debug suite in game mode (keys below, help text, tuning panel).
	if game_mode and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F1:
		_set_debug_enabled(not debug_enabled)
		return
	var debug_keys := debug_enabled or not game_mode
	if event is InputEventMouseMotion \
			and (_looking or (mouselook and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)):
		_cam_yaw -= event.relative.x * MOUSE_SENS
		_cam_pitch = clampf(_cam_pitch + event.relative.y * MOUSE_SENS, -0.35, 1.35)
	elif event is InputEventMouseButton and debug_keys:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_looking(event.pressed)            # hold RMB to look; cursor stays free for the panel
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = clampf(_cam_dist - 0.6, 2.0, 20.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = clampf(_cam_dist + 0.6, 2.0, 20.0)
	elif event is InputEventKey and event.pressed and debug_keys:
		# Step keys auto-repeat (hold to advance); everything else ignores key echo.
		if event.keycode == KEY_BRACKETRIGHT and _step_paused:
			_do_step(1)
		elif event.keycode == KEY_BRACKETLEFT and _step_paused:
			_do_step(-1)
		elif not event.echo:
			match event.keycode:
				KEY_P:
					_toggle_step_pause()
				KEY_E:
					_toggle_split()
				KEY_R:
					_replay_auto()
				KEY_N:
					_toggle_storm()
				KEY_C:
					if _collision_markers:
						_collision_markers.visible = not _collision_markers.visible
				KEY_H:
					# Hide the whole debug surface, panel and help text together, so the demo
					# can be screenshotted without chrome.
					if _tuning:
						_tuning.toggle()
					if _help_label:
						_help_label.visible = not _help_label.visible
				KEY_F5:
					if _tuning:
						_tuning.save_values()
				KEY_F9:
					if _tuning:
						_tuning.load_values()
				KEY_ESCAPE:
					_set_looking(false)


# F1 sandbox gate: the demo's debug surface stays fully available, just opt-in during the game.
func _set_debug_enabled(on: bool) -> void:
	debug_enabled = on
	if _help_label:
		_help_label.visible = on or not game_mode
	if _tuning:
		_tuning.set_shown(on or not game_mode)
	if _collision_markers and not on:
		_collision_markers.visible = false
	if on:
		_set_looking(false)                       # free the cursor for the panel
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouselook else Input.MOUSE_MODE_VISIBLE


# ---- Frame-step debug ----------------------------------------------------------------
func _toggle_step_pause() -> void:
	_step_paused = not _step_paused
	if _ocean:
		_ocean.frozen = _step_paused
	var pspeed: float = 0.0 if _step_paused else 1.0                 # freeze the flame + embers with the waves
	if _pillar_fire:
		_pillar_fire.speed_scale = pspeed
	if _pillar_embers:
		_pillar_embers.speed_scale = pspeed
	if _pillar_base:
		_pillar_base.speed_scale = pspeed
	if _pillar_crown:
		_pillar_crown.speed_scale = pspeed
	if _step_paused:
		_step_count = 0
	_update_step_label()


func _do_step(dir: int) -> void:
	if not _step_paused or not _ocean:
		return
	_step_count += dir
	_ocean.step(float(dir) * STEP_DT)
	_update_step_label()


func _update_step_label() -> void:
	if not _step_label:
		return
	_step_label.visible = _step_paused
	if _step_paused:
		var t := _ocean.current_time() if _ocean else 0.0
		_step_label.text = "WAVES FROZEN  ·  step %d  ·  wave t = %.3f s\n]  forward     [  back     P  resume" % [_step_count, t]


func _set_looking(on: bool) -> void:
	_looking = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


# =====================================================================================
#  Split driver — one normalized value in [0,1] maps to the whole deformation.
# =====================================================================================

func _apply_split(t: float) -> void:
	var s: float = smoothstep(0.0, 1.0, t)
	_sea_mat.set_shader_parameter("part", s)   # foam_amount is owned by the tuning panel now


func _set_part(v: float) -> void:
	_part_value = v
	_apply_split(v)
	_set_wall_mist(v > 0.55)   # spray off the crests once the walls are up


# Game-layer accessors: drive the parting explicitly (the cutscenes own pacing).
func part_sea(duration: float) -> void:
	if _part_tween and _part_tween.is_running():
		_part_tween.kill()
	_kill_slam_sfx()                         # an opening cancels any pending crash
	_part_target = 1.0
	_part_tween = create_tween()
	_part_tween.tween_method(_set_part, _part_value, 1.0, duration)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func close_sea(duration: float) -> void:
	# Already fully closed and not mid-change -> nothing to do. (The ending's CONVERGENT
	# close_sea(0.05) used to re-run the slam — splash, shake and the crash SFX firing
	# again under the scripture overlay.)
	if _part_value < 0.005 and not (_part_tween and _part_tween.is_running()):
		return
	if _part_tween and _part_tween.is_running():
		_part_tween.kill()
	_part_target = 0.0
	_part_tween = create_tween()
	_part_tween.tween_method(_set_part, _part_value, 0.0, duration)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_part_tween.tween_callback(_on_slam)
	_schedule_slam_sfx(duration)


## Emit sea_slammed SLAM_SFX_LEAD before the walls actually meet, so the crash's rising
## front peaks on the visual impact instead of starting at it.
func _schedule_slam_sfx(seconds_to_impact: float) -> void:
	_kill_slam_sfx()
	_slam_sfx_tween = create_tween()
	_slam_sfx_tween.tween_interval(maxf(seconds_to_impact - SLAM_SFX_LEAD, 0.01))
	_slam_sfx_tween.tween_callback(sea_slammed.emit)


func _kill_slam_sfx() -> void:
	if _slam_sfx_tween and _slam_sfx_tween.is_running():
		_slam_sfx_tween.kill()
	_slam_sfx_tween = null


func _toggle_split() -> void:
	var opening := _part_value < 0.5
	_part_target = 1.0 if opening else 0.0
	if _part_tween and _part_tween.is_running():
		_part_tween.kill()
	_part_tween = create_tween()
	if opening:
		_kill_slam_sfx()
		_part_tween.tween_method(_set_part, _part_value, 1.0, open_time)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_part_tween.tween_method(_set_part, _part_value, 0.0, close_time)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_part_tween.tween_callback(_on_slam)
		_schedule_slam_sfx(close_time)


func _replay_auto() -> void:
	# OPEN -> hold -> CLOSE (slam). Leaves you free to watch from anywhere.
	if _part_tween and _part_tween.is_running():
		_part_tween.kill()
	_part_target = 0.0
	_part_tween = create_tween()
	_part_tween.tween_method(_set_part, _part_value, 1.0, open_time)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_part_tween.tween_interval(hold_time)
	_part_tween.tween_method(_set_part, 1.0, 0.0, close_time)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_part_tween.tween_callback(_on_slam)
	_schedule_slam_sfx(open_time + hold_time + close_time)


func _on_slam() -> void:
	# The walls have just met: violent froth + spray + a wash of water over the lens + shake.
	# (The crash SFX is NOT fired here — _schedule_slam_sfx leads the impact by SLAM_SFX_LEAD.)
	_splash.restart()
	_splash.emitting = true
	_shake = 0.6
	var t := create_tween()
	t.tween_property(_drown_rect, "color:a", 0.55, 0.25)
	t.tween_property(_drown_rect, "color:a", 0.0, 1.2)


# =====================================================================================
#  Per-frame: player movement, herd, fish, camera.
# =====================================================================================

func _process(delta: float) -> void:
	if _step_paused:
		if not camera_override:
			_update_orbit_camera(0.0)   # frozen: only let the camera orbit so you can inspect/step
		return
	_elapsed += delta
	_anim_time += delta
	if _sea_mat:
		_sea_mat.set_shader_parameter("anim_time", _anim_time)   # held while frozen (this path skipped)
	var moved := _move_player(delta) if player_control else false
	_move_herd(delta, moved)
	_swim_fish()
	_update_weather(delta)
	_update_pillar(delta)

	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 1.2)
	if not camera_override:
		_update_orbit_camera(_shake * _shake)


func _move_player(delta: float) -> bool:
	if not _moses:
		return false
	var wparam := (1.0 if Input.is_key_pressed(KEY_W) else 0.0) - (1.0 if Input.is_key_pressed(KEY_S) else 0.0)
	var dparam := (1.0 if Input.is_key_pressed(KEY_D) else 0.0) - (1.0 if Input.is_key_pressed(KEY_A) else 0.0)

	# Camera-relative ground movement: forward = the way the camera looks (horizontal).
	var horiz_to_cam := Vector3(sin(_cam_yaw), 0.0, cos(_cam_yaw))   # player -> camera
	var forward := -horiz_to_cam.normalized()
	# Screen-right = up x forward (for forward +z that's -x: Godot's camera basis.x flips
	# against the look direction). The previous (forward.z, -forward.x) was the camera's LEFT,
	# which made A/D feel backwards.
	var right := Vector3(-forward.z, 0.0, forward.x)
	var dir := forward * wparam + right * dparam

	var moving := dir.length() > 0.01
	var prev_x := _moses.position.x
	var prev_z := _moses.position.z
	if moving:
		dir = dir.normalized()
		var speed := MOVE_SPEED * (SPRINT_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		var cx := _moses.position.x
		var cz := _moses.position.z
		var nx: float = clampf(cx + dir.x * speed * delta, -SEA_HALF_X + 2.0, SEA_HALF_X - 2.0)
		var nz: float = clampf(cz + dir.z * speed * delta, -SEA_HALF_Z + 2.0, SEA_HALF_Z - 2.0)
		# Move only onto WALKABLE ground (dry land or the drained corridor); otherwise slide along the
		# water's edge by trying each axis alone. If we're already standing in water (e.g. the sea closed
		# over us), let the move through so the player can always walk back out.
		if not _is_walkable(cx, cz) or _is_walkable(nx, nz):
			cx = nx
			cz = nz
		elif _is_walkable(nx, cz):
			cx = nx
		elif _is_walkable(cx, nz):
			cz = nz
		_moses.position.x = cx
		_moses.position.z = cz
		_moses.rotation.y = lerp_angle(_moses.rotation.y, atan2(dir.x, dir.z), 0.2)

	# Feet PLANTED: exact terrain snap on the root; all bob lives on the MeshRoot wobble below.
	_moses.position.y = _terrain_height(_moses.position.x, _moses.position.z) + FOOT_OFFSET
	# Wobble from the ACTUAL ground speed (slides along the water's edge animate slower), smoothed
	# so stop/start doesn't pop the mesh.
	var gspeed := Vector2(_moses.position.x - prev_x, _moses.position.z - prev_z).length() / maxf(delta, 1e-5)
	_moses_anim_speed = lerpf(_moses_anim_speed, gspeed, minf(delta * 10.0, 1.0))
	if _moses_mesh:
		_moses_phase = _tick_wobble(_moses_mesh, _moses_phase, _moses_anim_speed, delta)
	return moving


func _move_herd(delta: float, _leader_moving: bool) -> void:
	for wkr in _walkers:
		var n: Node3D = wkr["node"]
		# Trail the player; the offset is rotated behind whichever way Moses faces.
		var off: Vector3 = wkr["off"]
		var rotated := off.rotated(Vector3.UP, _moses.rotation.y)
		var target := _moses.position + rotated
		var tw := _nearest_walkable(target.x, target.z)   # keep the target on dry land / in the corridor
		var px := n.position.x
		var pz := n.position.z
		# Chase on x/z ONLY; Y is hard-snapped to the terrain (no Y-lerp -> no hovering on slopes).
		var cx := lerpf(px, tw.x, 0.05)
		var cz := lerpf(pz, tw.y, 0.05)
		var nw := _nearest_walkable(cx, cz)               # never let a follower drift into water
		n.position = Vector3(nw.x, _terrain_height(nw.x, nw.y) + FOOT_OFFSET, nw.y)
		n.rotation.y = lerp_angle(n.rotation.y, _moses.rotation.y, 0.05)
		# Wobble from actual ground speed, on the follower's MeshRoot (feet stay planted).
		var gspeed := Vector2(n.position.x - px, n.position.z - pz).length() / maxf(delta, 1e-5)
		wkr["phase"] = _tick_wobble(wkr["mesh"], wkr["phase"], gspeed * wkr["speed"], delta)


func _swim_fish() -> void:
	# Fish patrol along the corridor (z), with a gentle vertical bob; heading flips with velocity.
	for f in _fish:
		var node: Node3D = f["node"]
		var w: float = _elapsed * f["speed"] + f["phase"]
		var z: float = f["z0"] + sin(w) * f["span"]
		var y: float = f["y"] + sin(w * 2.3) * f["bob"]
		node.position = Vector3(f["x"], y, z)
		node.rotation.y = 0.0 if cos(w) >= 0.0 else PI
