extends Node3D
## Dresses the wilderness night camp around the pillar: scattered rocks,
## low dune mounds on the horizon, and a loose arc of tents keeping a
## reverent distance. Deterministic seed so the composition is stable.

@export var rock_material: Material
@export var ground_material: Material

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	_scatter_rocks(rng)
	_raise_dunes(rng)
	_pitch_tents(rng)

func _scatter_rocks(rng: RandomNumberGenerator) -> void:
	for i in 24:
		var box := BoxMesh.new()
		var s := rng.randf_range(0.3, 1.3)
		box.size = Vector3(s, s * rng.randf_range(0.4, 0.8), s * rng.randf_range(0.6, 1.2))
		var m := MeshInstance3D.new()
		m.mesh = box
		m.material_override = rock_material
		var ang := rng.randf_range(0.0, TAU)
		var r := rng.randf_range(7.0, 30.0)
		m.position = Vector3(sin(ang) * r, box.size.y * 0.3, cos(ang) * r)
		m.rotation = Vector3(
				rng.randf_range(-0.3, 0.3),
				rng.randf_range(0.0, TAU),
				rng.randf_range(-0.3, 0.3))
		add_child(m)

func _raise_dunes(rng: RandomNumberGenerator) -> void:
	for i in 7:
		var sph := SphereMesh.new()
		sph.radius = rng.randf_range(14.0, 26.0)
		sph.height = sph.radius * rng.randf_range(0.18, 0.3)
		var m := MeshInstance3D.new()
		m.mesh = sph
		m.material_override = ground_material
		var ang := rng.randf_range(0.0, TAU)
		var r := rng.randf_range(48.0, 95.0)
		m.position = Vector3(sin(ang) * r, 0.0, cos(ang) * r)
		m.rotation.y = rng.randf_range(0.0, TAU)
		add_child(m)

func _pitch_tents(rng: RandomNumberGenerator) -> void:
	var arc_center := PI * 0.8
	for i in 9:
		var prism := PrismMesh.new()
		prism.size = Vector3(
				rng.randf_range(3.0, 5.0),
				rng.randf_range(2.0, 2.9),
				rng.randf_range(3.4, 5.2))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.28, 0.2, 0.15).lerp(Color(0.4, 0.27, 0.17), rng.randf())
		mat.roughness = 1.0
		var m := MeshInstance3D.new()
		m.mesh = prism
		m.material_override = mat
		var ang := arc_center + rng.randf_range(-1.3, 1.3)
		var r := rng.randf_range(30.0, 52.0)
		m.position = Vector3(sin(ang) * r, prism.size.y * 0.5 - 0.05, cos(ang) * r)
		m.rotation.y = ang + rng.randf_range(-0.4, 0.4)
		add_child(m)
