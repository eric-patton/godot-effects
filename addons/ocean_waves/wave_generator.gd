@tool
class_name WaveGenerator extends Node
## Handles the compute pipeline for wave spectra generation/FFT.

const G := 9.81
const DEPTH := 20.0

var map_size : int
var context : RenderingContext
var pipelines : Dictionary
var descriptors : Dictionary

# Double-buffer: the compute writes output set `output_index` while the renderer samples the OTHER
# set (completed a full frame earlier). Avoids the compute-write vs scene-sample texture race on
# Godot 4.6 (which auto-barriers textures in uniform sets, but NOT a compute texture sampled via a
# global shader uniform) — the "sheared wave" glitch.
var output_index := 0
var _unpack_sets : Array = []   # [unpack_set_A, unpack_set_B]
var _fft_buffer_set

# Generator state per invocation of `update()`.
var pass_parameters : Array[WaveCascadeParameters]
var pass_num_cascades_remaining : int

func init_gpu(num_cascades : int) -> void:
	# --- DEVICE/SHADER CREATION ---
	if not context: context = RenderingContext.create(RenderingServer.get_rendering_device())
	var base := 'res://addons/ocean_waves/compute/'
	var spectrum_compute_shader := context.load_shader(base + 'spectrum_compute.glsl')
	var fft_butterfly_shader := context.load_shader(base + 'fft_butterfly.glsl')
	var spectrum_modulate_shader := context.load_shader(base + 'spectrum_modulate.glsl')
	var fft_compute_shader := context.load_shader(base + 'fft_compute.glsl')
	var transpose_shader := context.load_shader(base + 'transpose.glsl')
	var fft_unpack_shader := context.load_shader(base + 'fft_unpack.glsl')

	# --- DESCRIPTOR PREPARATION ---
	var dims := Vector2i(map_size, map_size)
	var num_fft_stages := int(log(map_size) / log(2))

	descriptors[&'spectrum'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, num_cascades)
	descriptors[&'butterfly_factors'] = context.create_storage_buffer(num_fft_stages*map_size * 4 * 4)         # Size: (#FFT stages * map size * sizeof(vec4))
	descriptors[&'fft_buffer'] = context.create_storage_buffer(num_cascades * map_size*map_size * 4*2 * 2 * 4) # Size: (map size^2 * 4 FFTs * 2 temp buffers (for Stockham FFT) * sizeof(vec2))
	var tex_usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	# TWO output sets (A/B) for double-buffering (see output_index above).
	descriptors[&'displacement_map']   = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, tex_usage, num_cascades)
	descriptors[&'normal_map']         = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, tex_usage, num_cascades)
	descriptors[&'displacement_map_b'] = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, tex_usage, num_cascades)
	descriptors[&'normal_map_b']       = context.create_texture(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, tex_usage, num_cascades)

	var spectrum_set := context.create_descriptor_set([descriptors[&'spectrum']], spectrum_compute_shader, 0)
	var fft_butterfly_set := context.create_descriptor_set([descriptors[&'butterfly_factors']], fft_butterfly_shader, 0)
	var fft_compute_set := context.create_descriptor_set([descriptors[&'butterfly_factors'], descriptors[&'fft_buffer']], fft_compute_shader, 0)
	var fft_buffer_set := context.create_descriptor_set([descriptors[&'fft_buffer']], spectrum_modulate_shader, 1)
	var unpack_set := context.create_descriptor_set([descriptors[&'displacement_map'], descriptors[&'normal_map']], fft_unpack_shader, 0)
	var unpack_set_b := context.create_descriptor_set([descriptors[&'displacement_map_b'], descriptors[&'normal_map_b']], fft_unpack_shader, 0)
	_unpack_sets = [unpack_set, unpack_set_b]
	_fft_buffer_set = fft_buffer_set

	# --- COMPUTE PIPELINE CREATION ---
	pipelines[&'spectrum_compute'] = context.create_pipeline([map_size/16, map_size/16, 1], [spectrum_set], spectrum_compute_shader)
	pipelines[&'spectrum_modulate'] = context.create_pipeline([map_size/16, map_size/16, 1], [spectrum_set, fft_buffer_set], spectrum_modulate_shader)
	pipelines[&'fft_butterfly'] = context.create_pipeline([map_size/2/64, num_fft_stages, 1], [fft_butterfly_set], fft_butterfly_shader)
	pipelines[&'fft_compute'] = context.create_pipeline([1, map_size, 4], [fft_compute_set], fft_compute_shader)
	pipelines[&'transpose'] = context.create_pipeline([map_size/32, map_size/32, 4], [fft_compute_set], transpose_shader)
	pipelines[&'fft_unpack'] = context.create_pipeline([map_size/16, map_size/16, 1], [unpack_set, fft_buffer_set], fft_unpack_shader)

	# We only need to generate butterfly factors once for each map_size.
	var compute_list := context.compute_list_begin()
	pipelines[&'fft_butterfly'].call(context, compute_list)
	context.compute_list_end()

func _process(_delta: float) -> void:
	# DISABLED. Cascade updates are now driven entirely by update() (called once per frame by the
	# OceanFFT driver), which processes ALL cascades together at one shared time. The old code here
	# updated one cascade per frame for load balancing, but combined with update()'s catch-up branch
	# it left the cascades a frame out of sync and let the shared counter land on a bad value for a
	# single frame — a visible phase "glitch" that snaps back, once the waves are big/fast enough.
	pass

func _update(compute_list : int, cascade_index : int, parameters : Array[WaveCascadeParameters]) -> void:
	var params := parameters[cascade_index]
	## --- WAVE SPECTRA UPDATE ---
	if params.should_generate_spectrum:
		var alpha := JONSWAP_alpha(params.wind_speed, params.fetch_length*1e3)
		var omega := JONSWAP_peak_angular_frequency(params.wind_speed, params.fetch_length*1e3)
		pipelines[&'spectrum_compute'].call(context, compute_list, RenderingContext.create_push_constant([params.spectrum_seed.x, params.spectrum_seed.y, params.tile_length.x, params.tile_length.y, alpha, omega, params.wind_speed, deg_to_rad(params.wind_direction), DEPTH, params.swell, params.detail, params.spread, cascade_index]))
		params.should_generate_spectrum = false
		context.compute_list_add_barrier(compute_list)  # spectrum_compute -> modulate (reads spectrum)
	pipelines[&'spectrum_modulate'].call(context, compute_list, RenderingContext.create_push_constant([params.tile_length.x, params.tile_length.y, DEPTH, params.time, cascade_index]))

	## --- WAVE SPECTRA INVERSE FOURIER TRANSFORM ---
	var fft_push_constant := RenderingContext.create_push_constant([cascade_index])
	# Every pass below reads+writes the SAME fft_buffer, so each depends on the previous. The
	# original only had the one barrier before the 2nd FFT ("why is a barrier only needed here?!") —
	# the others were relying on implicit ordering that isn't guaranteed, which let a pass
	# occasionally read half-written data => a garbage texel => the 1-frame wave "explosion".
	# Barrier EVERY dependent step so the chain is fully serialized.
	# Note: We need not do a second transpose after computing FFT on rows since rotating the wave by
	#       PI/2 doesn't affect it visually.
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)  # 1st FFT -> transpose
	pipelines[&'transpose'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)  # transpose -> 2nd FFT
	pipelines[&'fft_compute'].call(context, compute_list, fft_push_constant)
	context.compute_list_add_barrier(compute_list)  # 2nd FFT -> unpack (reads fft_buffer)

	## --- DISPLACEMENT/NORMAL MAP UPDATE ---
	# Write into the active double-buffer set (the renderer samples the other one this frame).
	pipelines[&'fft_unpack'].call(context, compute_list, RenderingContext.create_push_constant([cascade_index, params.whitecap, params.foam_grow_rate, params.foam_decay_rate]), [_unpack_sets[output_index], _fft_buffer_set])

## Advance the wave simulation by `delta` and regenerate EVERY cascade this frame, all at the same
## monotonic time so the cascades stay in lockstep (the old load-balanced path updated one cascade
## via _process() and the rest via a catch-up branch, leaving them a frame out of sync — a visible
## phase "glitch" once the waves are big/fast). `delta` is clamped so a frame hitch can't lurch the
## whole field forward in one step.
func update(delta : float, parameters : Array[WaveCascadeParameters]) -> void:
	assert(parameters.size() != 0)
	if not context:
		init_gpu(maxi(2, len(parameters))) # FIXME: This is needed because my RenderContext API sucks...

	# Update each cascade's time-dependent parameters (clamped against frame hitches).
	var dt := minf(maxf(delta, 0.0), 1.0 / 30.0)
	for i in len(parameters):
		var params := parameters[i]
		params.time += dt
		# Note: The constants are used to normalize parameters between 0 and 10.
		params.foam_grow_rate = dt * params.foam_amount*7.5
		params.foam_decay_rate = dt * maxf(0.5, 10.0 - params.foam_amount)*1.15

	# Process ALL cascades in one compute list, at the SAME time -> deterministic and synced.
	var compute_list := context.compute_list_begin()
	for i in len(parameters):
		_update(compute_list, i, parameters)
	context.compute_list_end()

	pass_parameters = parameters
	pass_num_cascades_remaining = 0

## Run the compute for the cascades' CURRENT time WITHOUT advancing it (frame-step debug). The
## caller sets parameters[i].time explicitly first.
func render_at(parameters : Array[WaveCascadeParameters]) -> void:
	assert(parameters.size() != 0)
	if not context:
		init_gpu(maxi(2, len(parameters)))
		return
	var compute_list := context.compute_list_begin()
	for i in len(parameters):
		_update(compute_list, i, parameters)
	context.compute_list_end()

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if context: context.free()

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_alpha(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 0.076 * pow(wind_speed**2 / (fetch_length*G), 0.22)

# Source: https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum
static func JONSWAP_peak_angular_frequency(wind_speed:=20.0, fetch_length:=550e3) -> float:
	return 22.0 * pow(G*G / (wind_speed*fetch_length), 1.0/3.0)
