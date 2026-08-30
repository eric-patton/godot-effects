extends Node3D
## Drives the fire's flicker: light energy/color/position wander with
## layered noise, plus occasional majestic surges. The same flicker value
## is pushed into every flame shader (instance uniform) so the whole
## effect breathes in sync.

@export var main_energy := 13.0
@export var high_energy := 4.5
@export var flicker_strength := 0.16
@export var swell_strength := 0.24
@export var surge_strength := 0.45
@export var color_low := Color(1.0, 0.45, 0.13)
@export var color_high := Color(1.0, 0.66, 0.28)

@onready var _main: OmniLight3D = $FireLight
@onready var _high: OmniLight3D = $FireLightHigh

var _t := 0.0
var _noise := FastNoiseLite.new()
var _main_origin: Vector3
var _flame_nodes: Array[GeometryInstance3D] = []

func _ready() -> void:
	_t = randf() * 100.0
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_main_origin = _main.position
	for path in ["FlameOuter", "FlameCore", "FlameTongues", "Embers",
			"BaseGlow", "GloryBeam", "GloryCloud", "GloryMotes"]:
		var node := get_node_or_null(NodePath(path))
		if node is GeometryInstance3D:
			_flame_nodes.append(node)

func _process(delta: float) -> void:
	_t += delta
	var fast := _noise.get_noise_1d(_t * 9.0)
	var slow := _noise.get_noise_1d(_t * 1.7 + 500.0)
	var surge := surge_strength * smoothstep(0.55, 0.95, slow)
	var f := clampf(1.0 + flicker_strength * fast + swell_strength * slow + surge, 0.45, 2.0)

	_main.light_energy = main_energy * f
	_high.light_energy = high_energy * (0.7 + 0.3 * f)
	_main.light_color = color_low.lerp(color_high, 0.5 + 0.5 * slow)

	var jx := _noise.get_noise_1d(_t * 3.1 + 50.0)
	var jy := _noise.get_noise_1d(_t * 4.3 + 250.0)
	var jz := _noise.get_noise_1d(_t * 2.7 + 150.0)
	_main.position = _main_origin + Vector3(jx * 0.5, jy * 0.8, jz * 0.5)

	for g in _flame_nodes:
		g.set_instance_shader_parameter("flicker", f)
