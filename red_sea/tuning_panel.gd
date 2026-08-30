extends CanvasLayer
class_name TuningPanel
## Live in-window tuning panel. Drag sliders to tweak the water / wall / wave look in real
## time; click "Save these values" to append the current set (timestamped) to
## res://tuning_values.txt so we can bake the sweet spots back into the defaults.

const SAVE_PATH := "res://tuning_values.txt"

var _sea_mat: ShaderMaterial
var _ocean: OceanFFT
var _env: Environment            # for the FOG sliders
var _sun: DirectionalLight3D     # for the SUN sliders
var _ground_mats: Array = []     # seabed + corridor-floor materials, for the GROUND sliders
var _root: PanelContainer
var _status: Label
var _rows: Dictionary = {}   # key -> { "e": spec, "slider": HSlider, "label": Label }


# Each entry is either a SECTION header ({"header": "TITLE"}) or a slider:
#   k     = param key
#   t     = "shader" (set on the sea material) | "fft" (set on every wave cascade, re-runs the
#           spectrum) | "env" (set on the WorldEnvironment's Environment) | "sun" (set on the
#           DirectionalLight3D; sun_pitch/sun_yaw also re-derive the water shader's sun_dir)
#   label, min, max, step, v=starting value  (v MUST match the scene's actual default)
func _spec() -> Array:
	return [
		{"header": "WAVES"},
		{"k": "fft_amplitude",       "t": "shader", "label": "Wave height (FFT amp)",  "min": 0.0,   "max": 1.6,    "step": 0.01,  "v": 1.20},
		{"k": "wind_speed",          "t": "fft",    "label": "Wind speed (chop)",      "min": 2.0,   "max": 28.0,   "step": 0.5,   "v": 20.0},
		{"k": "whitecap",            "t": "fft",    "label": "Whitecap thr (lo=foamy)","min": 0.2,   "max": 1.3,    "step": 0.01,  "v": 0.61},
		{"k": "fft_normal_strength", "t": "shader", "label": "Wave normal strength",   "min": 0.0,   "max": 4.0,    "step": 0.01,  "v": 2.50},
		{"k": "choppiness",          "t": "shader", "label": "Choppiness (horizontal)", "min": 0.0,  "max": 1.0,    "step": 0.01,  "v": 1.00},
		{"k": "disp_fine",           "t": "shader", "label": "Geom detail (hi=facets)", "min": 0.0,  "max": 1.0,    "step": 0.01,  "v": 0.00},
		{"header": "WATER"},
		{"k": "foam_amount",         "t": "shader", "label": "Foam amount",            "min": 0.0,   "max": 2.0,    "step": 0.01,  "v": 0.91},
		{"k": "density",             "t": "shader", "label": "Water density (opacity)","min": 0.05,  "max": 2.5,    "step": 0.01,  "v": 1.50},
		{"k": "refraction",          "t": "shader", "label": "Refraction",             "min": 0.0,   "max": 0.15,   "step": 0.001, "v": 0.052},
		{"k": "fresnel_strength",    "t": "shader", "label": "Fresnel (sky reflect)",  "min": 0.0,   "max": 1.0,    "step": 0.01,  "v": 0.61},
		{"k": "sun_shininess",       "t": "shader", "label": "Sun glint tightness",    "min": 50.0,  "max": 3000.0, "step": 10.0,  "v": 100.0},
		{"header": "WALLS"},
		{"k": "crest_rise",          "t": "shader", "label": "Wall height (crest)",    "min": 1.0,   "max": 12.0,   "step": 0.1,   "v": 6.6},
		{"k": "wall_width",          "t": "shader", "label": "Wall steepness (width)", "min": 1.5,   "max": 12.0,   "step": 0.1,   "v": 8.0},
		{"k": "wall_falloff",        "t": "shader", "label": "Wall outer falloff",     "min": 1.0,   "max": 12.0,   "step": 0.1,   "v": 2.0},
		{"k": "wall_streak_amount",  "t": "shader", "label": "Wall streaks (sheeting)","min": 0.0,   "max": 3.0,    "step": 0.01,  "v": 0.55},
		{"k": "wall_flow_speed",     "t": "shader", "label": "Wall flow speed",        "min": 0.0,   "max": 4.0,    "step": 0.01,  "v": 3.0},
		{"k": "crest_foam_amount",   "t": "shader", "label": "Crest foam crown",       "min": 0.0,   "max": 2.0,    "step": 0.01,  "v": 0.8},
		{"k": "wall_wave_amp",       "t": "shader", "label": "Wall wave heave(0=off)", "min": 0.0,   "max": 2.0,    "step": 0.01,  "v": 0.8},
		{"k": "wall_wave_scale",     "t": "shader", "label": "Wall wave size(lo=big)", "min": 0.2,  "max": 2.0,    "step": 0.01,  "v": 1.0},
		{"k": "wall_wave_normal",    "t": "shader", "label": "Wall wave surface",      "min": 0.0,   "max": 3.0,    "step": 0.01,  "v": 1.0},
		{"k": "wall_wave_foam",      "t": "shader", "label": "Wall wave whitecaps",    "min": 0.0,   "max": 2.0,    "step": 0.01,  "v": 1.0},
		{"k": "detail_strength",     "t": "shader", "label": "Sea micro-detail",       "min": 0.0,   "max": 4.0,    "step": 0.01,  "v": 1.0},
		{"k": "detail_scale",        "t": "shader", "label": "Sea micro-detail scale", "min": 0.005, "max": 0.6,    "step": 0.005, "v": 0.02},
		{"k": "triplanar_sharpness", "t": "shader", "label": "Triplanar blend sharp",  "min": 1.0,   "max": 12.0,   "step": 0.1,   "v": 8.0},
		{"header": "GROUND"},
		{"k": "sand_uv_scale",          "t": "seabed", "label": "Sand UV scale",        "min": 0.02, "max": 2.0, "step": 0.01, "v": 0.25},
		{"k": "floor_uv_scale",         "t": "seabed", "label": "Sea-floor UV scale",   "min": 0.02, "max": 2.0, "step": 0.01, "v": 0.20},
		{"k": "ground_normal_strength", "t": "seabed", "label": "Ground normal depth",  "min": 0.0,  "max": 3.0, "step": 0.05, "v": 1.0},
		{"k": "ground_roughness",       "t": "seabed", "label": "Ground roughness",     "min": 0.0,  "max": 2.0, "step": 0.05, "v": 1.0},
		{"k": "wet_darken",             "t": "seabed", "label": "Wet darken",           "min": 0.0,  "max": 1.0, "step": 0.01, "v": 0.6},
		{"k": "caustic_strength",       "t": "seabed", "label": "Caustic strength",     "min": 0.0,  "max": 2.0, "step": 0.05, "v": 0.5},
		{"k": "dune_amp",               "t": "seabed", "label": "Dune height",          "min": 0.0,  "max": 3.0, "step": 0.05, "v": 0.7},
		{"header": "FOG"},
		{"k": "volumetric_fog_density",        "t": "env", "label": "Volumetric density (beams)", "min": 0.0,  "max": 0.10, "step": 0.001, "v": 0.02},
		{"k": "volumetric_fog_anisotropy",     "t": "env", "label": "Volumetric scatter dir",     "min": -0.9, "max": 0.95, "step": 0.01,  "v": 0.70},
		{"k": "volumetric_fog_length",         "t": "env", "label": "Volumetric reach (m)",       "min": 10.0, "max": 200.0,"step": 1.0,   "v": 80.0},
		{"k": "volumetric_fog_ambient_inject", "t": "env", "label": "Volumetric ambient inject",  "min": 0.0,  "max": 3.0,  "step": 0.05,  "v": 0.40},
		{"k": "fog_density",                   "t": "env", "label": "Haze density (horizon)",     "min": 0.0,  "max": 0.05, "step": 0.0005,"v": 0.014},
		{"k": "fog_aerial_perspective",        "t": "env", "label": "Aerial perspective",         "min": 0.0,  "max": 1.0,  "step": 0.01,  "v": 0.55},
		{"k": "fog_sun_scatter",               "t": "env", "label": "Haze sun scatter",           "min": 0.0,  "max": 1.0,  "step": 0.01,  "v": 0.20},
		{"header": "SUN"},
		{"k": "light_energy",                "t": "sun", "label": "Sun brightness",       "min": 0.0,   "max": 4.0, "step": 0.05, "v": 1.20},
		{"k": "light_volumetric_fog_energy", "t": "sun", "label": "Sun beam energy",      "min": 0.0,   "max": 8.0, "step": 0.1,  "v": 3.00},
		{"k": "sun_pitch",                   "t": "sun", "label": "Sun pitch (-90=noon)", "min": -90.0, "max": -2.0,"step": 1.0,  "v": -90.0},
		{"k": "sun_yaw",                     "t": "sun", "label": "Sun yaw (compass)",    "min": -180.0,"max": 180.0,"step": 1.0, "v": 0.0},
		{"k": "light_angular_distance",      "t": "sun", "label": "Sun disc size",        "min": 0.0,   "max": 3.0, "step": 0.05, "v": 0.25},
	]


func setup(sea_mat: ShaderMaterial, ocean: OceanFFT, env: Environment = null, sun: DirectionalLight3D = null, ground_mats: Array = []) -> void:
	_sea_mat = sea_mat
	_ocean = ocean
	_env = env
	_sun = sun
	_ground_mats = ground_mats
	_build_ui()


func toggle() -> void:
	_root.visible = not _root.visible


func set_shown(on: bool) -> void:
	if _root:
		_root.visible = on


func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.anchor_left = 1.0
	_root.anchor_top = 0.0
	_root.anchor_right = 1.0
	_root.anchor_bottom = 0.0
	_root.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_root.grow_vertical = Control.GROW_DIRECTION_END    # grow DOWN from a fixed top -> deterministic layout
	_root.offset_left = -372.0
	_root.offset_right = -10.0
	_root.offset_top = 48.0
	_root.offset_bottom = 48.0
	add_child(_root)

	# Title (fixed) + a SCROLLING list of rows (there are a lot now) + buttons (fixed at the bottom).
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 3)
	_root.add_child(outer)

	var title := Label.new()
	title.text = "LIVE TUNING   (H hides)"
	title.add_theme_font_size_override("font_size", 13)
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 560)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.focus_mode = Control.FOCUS_NONE   # mouse-only: don't let it grab the ARROW keys (those move the pillar)
	outer.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	for e in _spec():
		if e.has("header"):
			var h := Label.new()
			h.text = "—  %s  —" % e.header
			h.add_theme_font_size_override("font_size", 12)
			h.add_theme_color_override("font_color", Color(0.62, 0.85, 1.0))
			vbox.add_child(h)
			continue
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.custom_minimum_size = Vector2(206, 0)
		lbl.add_theme_font_size_override("font_size", 12)
		var s := HSlider.new()
		s.min_value = e.min
		s.max_value = e.max
		s.step = e.step
		s.value = e.v
		s.custom_minimum_size = Vector2(110, 0)
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.focus_mode = Control.FOCUS_NONE   # mouse-drag only: a focused slider would steal LEFT/RIGHT from the pillar
		row.add_child(lbl)
		row.add_child(s)
		vbox.add_child(row)
		_rows[e.k] = {"e": e, "slider": s, "label": lbl}
		var key: String = e.k
		s.value_changed.connect(func(v): _on_change(key, v))
		_apply(e, e.v)
		_update_label(e.k, e.v)

	var save_btn := Button.new()
	save_btn.text = "Save these values  (or press F5)"
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.pressed.connect(save_values)
	outer.add_child(save_btn)

	var load_btn := Button.new()
	load_btn.text = "Load last saved  (or press F9)"
	load_btn.focus_mode = Control.FOCUS_NONE
	load_btn.pressed.connect(load_values)
	outer.add_child(load_btn)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.text = "saves to res://tuning_values.txt"
	outer.add_child(_status)


func _on_change(key: String, v: float) -> void:
	_apply(_rows[key]["e"], v)
	_update_label(key, v)


func _apply(e: Dictionary, v: float) -> void:
	if e.t == "shader":
		if _sea_mat:
			_sea_mat.set_shader_parameter(e.k, v)
	elif e.t == "fft":
		if _ocean:
			_ocean.set_cascade_prop(e.k, v)
	elif e.t == "env":
		if _env:
			_env.set(e.k, v)
	elif e.t == "sun":
		_apply_sun(e.k, v)
	elif e.t == "seabed":
		for m in _ground_mats:
			if m:
				m.set_shader_parameter(e.k, v)


# Sun sliders drive the real DirectionalLight3D (shadows, lit opaque geometry, the volumetric beams).
# pitch/yaw are written into rotation; everything else is a plain light property. After ANY change we
# re-derive the water shader's sun_dir / sun_color, since the water is UNLIT (EMISSION) and only reacts
# to the sun through those uniforms — so the glint, fresnel and wall shading follow the sun live.
func _apply_sun(k: String, v: float) -> void:
	if not _sun:
		return
	if k == "sun_pitch":
		var r := _sun.rotation_degrees
		r.x = v
		_sun.rotation_degrees = r
	elif k == "sun_yaw":
		var r := _sun.rotation_degrees
		r.y = v
		_sun.rotation_degrees = r
	else:
		_sun.set(k, v)
	if _sea_mat:
		_sea_mat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)   # light travel dir
		_sea_mat.set_shader_parameter("sun_color", _sun.light_color * _sun.light_energy)


func _update_label(key: String, v: float) -> void:
	var e: Dictionary = _rows[key]["e"]
	var fmt := "%.3f" if e.step < 0.01 else ("%.0f" if e.step >= 1.0 else "%.2f")
	_rows[key]["label"].text = "%s: %s" % [e.label, fmt % v]


## Move a slider (and its label) to a value that was set ELSEWHERE (e.g. red_sea.gd's day<->night mood
## cross-fade writes the sun/fog directly), WITHOUT re-applying — the live light/material is already at
## that value; this just keeps the panel honest so the next drag starts from the real value instead of
## snapping. No-op for keys the panel doesn't own.
func sync_slider(key: String, value: float) -> void:
	if not _rows.has(key):
		return
	var e: Dictionary = _rows[key]["e"]
	var v := clampf(value, e.min, e.max)
	_rows[key]["slider"].set_value_no_signal(v)
	_update_label(key, v)


func save_values() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true)
	var block := "[%s]\n" % stamp
	for e in _spec():
		if e.has("header"):
			continue
		var v: float = _rows[e.k]["slider"].value
		block += "  %-28s = %-10s  (%s)\n" % [e.k, String.num(v, 4), e.t]
	block += "----\n"

	# Write to the real OS path (res:// can be read-only at runtime); this lands the file
	# right in the project folder where we can reference it.
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	var existing := ""
	if FileAccess.file_exists(abs_path):
		existing = FileAccess.get_file_as_string(abs_path)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f:
		f.store_string(existing + block)
		f.close()
		_status.text = "Saved @ %s" % stamp
		print("\n[TUNING SAVED] ", abs_path, "\n", block)
	else:
		_status.text = "SAVE FAILED (see console)"
		push_error("TuningPanel could not write %s" % abs_path)


## Read tuning_values.txt and apply the MOST RECENT saved block to every slider + the material/FFT.
## Blocks are "[stamp]\n  key = val  (type)\n...\n----"; we take the last non-empty one and parse
## each "key = val" line, ignoring the trailing "(type)" annotation and any unknown keys.
func load_values() -> void:
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	if not FileAccess.file_exists(abs_path):
		_status.text = "no tuning_values.txt to load"
		return
	var text := FileAccess.get_file_as_string(abs_path)
	var last_block := ""
	for b in text.split("----", false):
		if b.strip_edges() != "":
			last_block = b
	if last_block.strip_edges() == "":
		_status.text = "tuning_values.txt is empty"
		return
	var stamp := ""
	var applied := 0
	for raw in last_block.split("\n"):
		var line := raw.strip_edges()
		if line == "":
			continue
		if line.begins_with("["):
			stamp = line.trim_prefix("[").trim_suffix("]")
			continue
		var eq := line.find("=")
		if eq == -1:
			continue
		var key := line.substr(0, eq).strip_edges()
		if not _rows.has(key):
			continue
		var rest := line.substr(eq + 1).strip_edges()
		var paren := rest.find("(")                       # strip the trailing "(shader)" / "(fft)" tag
		var vstr := (rest.substr(0, paren) if paren != -1 else rest).strip_edges()
		if not vstr.is_valid_float():
			continue
		var e: Dictionary = _rows[key]["e"]
		var v := clampf(float(vstr), e.min, e.max)
		_rows[key]["slider"].set_value_no_signal(v)        # update the UI without double-firing
		_apply(e, v)                                       # push to the material / FFT cascades
		_update_label(key, v)
		applied += 1
	_status.text = "Loaded %d values  (%s)" % [applied, stamp]
	print("[TUNING LOADED] %d values from block %s" % [applied, stamp])
