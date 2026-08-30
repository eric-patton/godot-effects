extends Node
class_name OceanFFT
## Headless driver for the GodotOceanWaves FFT sim (vendored under addons/ocean_waves, MIT —
## (c) 2024 Ethan Truong). It runs the compute cascades each frame and publishes their
## displacement + normal(+foam) maps as the GLOBAL shader uniforms `displacements` / `normals`
## / `num_cascades`, plus per-material `map_scales`. Our water shader (red_sea_water.gdshader)
## samples those instead of the old summed-sine waves. We DON'T use their mesh/material/spray.

@export var map_size := 256          # FFT resolution per cascade (128/256/512/1024)

var _gen: WaveGenerator
var _params: Array[WaveCascadeParameters] = []
var _disp_a := Texture2DArrayRD.new()
var _norm_a := Texture2DArrayRD.new()
var _disp_b := Texture2DArrayRD.new()
var _norm_b := Texture2DArrayRD.new()
var _write_idx := 0   # output set the compute writes THIS frame; renderer samples the OTHER (stable)
var _material: ShaderMaterial


## Build `cascades` (1..8 WaveCascadeParameters), init the GPU pipeline, and bind the outputs
## as globals + map_scales on `material`.
func setup(material: ShaderMaterial, cascades: Array[WaveCascadeParameters]) -> void:
	_material = material
	_params = cascades
	for p in _params:
		p.spectrum_seed = Vector2i(randi_range(-10000, 10000), randi_range(-10000, 10000))
		p.should_generate_spectrum = true

	_gen = WaveGenerator.new()
	_gen.map_size = map_size
	add_child(_gen)
	_gen.init_gpu(maxi(2, _params.size()))

	_disp_a.texture_rd_rid = _gen.descriptors[&"displacement_map"].rid
	_norm_a.texture_rd_rid = _gen.descriptors[&"normal_map"].rid
	_disp_b.texture_rd_rid = _gen.descriptors[&"displacement_map_b"].rid
	_norm_b.texture_rd_rid = _gen.descriptors[&"normal_map_b"].rid
	# Prime BOTH output buffers at t=0 so the renderer always samples a COMPLETE texture (never one
	# being written this frame) — the double-buffer that kills the compute-vs-render shear glitch.
	_gen.output_index = 1
	_gen.update(0.0, _params)
	_gen.output_index = 0
	_gen.update(0.0, _params)
	_write_idx = 1                       # frame 0 writes B; renderer samples the primed A
	# Bind buffer A BEFORE num_cascades, so the shader never loops over an unbound sampler.
	_bind_global(0)
	_update_scales()
	RenderingServer.global_shader_parameter_set(&"num_cascades", _params.size())


## Point the global `displacements`/`normals` samplers at output set A (idx 0) or B (idx 1).
func _bind_global(idx: int) -> void:
	RenderingServer.global_shader_parameter_set(&"displacements", _disp_b if idx == 1 else _disp_a)
	RenderingServer.global_shader_parameter_set(&"normals", _norm_b if idx == 1 else _norm_a)


## Set a property (e.g. "wind_speed", "whitecap") on EVERY cascade. The WaveCascadeParameters
## setters flag should_generate_spectrum, so the next update() re-runs the spectrum. Used by
## the live tuning panel.
func set_cascade_prop(prop: StringName, value: float) -> void:
	for p in _params:
		p.set(prop, value)
	_update_scales()


func _update_scales() -> void:
	var scales: PackedVector4Array
	scales.resize(_params.size())
	for i in _params.size():
		var p := _params[i]
		var uv := Vector2.ONE / p.tile_length
		scales[i] = Vector4(uv.x, uv.y, p.displacement_scale, p.normal_scale)
	if _material:
		_material.set_shader_parameter(&"map_scales", scales)


var frozen := false   # frame-step debug: when true, _process holds and step() advances manually


func _process(delta: float) -> void:
	if not _gen or frozen:
		return
	var read_idx := 1 - _write_idx       # buffer completed LAST frame (renderer samples this one)
	_bind_global(read_idx)
	_gen.output_index = _write_idx        # compute writes the OTHER set this frame
	_gen.update(delta, _params)
	_write_idx = read_idx                  # next frame, write into the set we just displayed


## Frame-step: advance every cascade's time by `dt` (may be negative to step back — displacement is
## a pure function of time, so it's reproducible), refresh the delta-dependent foam rates, and run
## the compute ONCE for that exact time. Returns the new wave time.
func step(dt: float) -> float:
	if _params.is_empty():
		return 0.0
	var adt := absf(dt)
	for p in _params:
		p.time = maxf(0.0, p.time + dt)
		p.foam_grow_rate = adt * p.foam_amount * 7.5
		p.foam_decay_rate = adt * maxf(0.5, 10.0 - p.foam_amount) * 1.15
	if _gen:
		var read_idx := 1 - _write_idx
		_bind_global(read_idx)
		_gen.output_index = _write_idx
		_gen.render_at(_params)
		_write_idx = read_idx
	return _params[0].time


func current_time() -> float:
	return _params[0].time if not _params.is_empty() else 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_disp_a.texture_rd_rid = RID()
		_norm_a.texture_rd_rid = RID()
		_disp_b.texture_rd_rid = RID()
		_norm_b.texture_rd_rid = RID()
