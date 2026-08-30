extends Camera3D
## Orbit camera for inspecting the effect. Auto-rotates slowly; drag with
## the left/right mouse button to orbit, scroll to zoom, Space to toggle
## auto-rotation.

@export var target := Vector3(0.0, 12.0, 0.0)
@export var distance := 48.0
@export var auto_speed := 0.06

var _yaw := 0.6
var _pitch := 0.2
var _auto := true

func _ready() -> void:
	_update_transform()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance = clampf(distance * 0.92, 8.0, 90.0)
				_update_transform()
			MOUSE_BUTTON_WHEEL_DOWN:
				distance = clampf(distance * 1.08, 8.0, 90.0)
				_update_transform()
	elif event is InputEventMouseMotion and event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT):
		_auto = false
		_yaw -= event.relative.x * 0.005
		_pitch = clampf(_pitch + event.relative.y * 0.004, 0.02, 1.2)
		_update_transform()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_auto = not _auto

func _process(delta: float) -> void:
	if _auto:
		_yaw += auto_speed * delta
		_update_transform()

func _update_transform() -> void:
	var offset := Vector3(
			sin(_yaw) * cos(_pitch),
			sin(_pitch),
			cos(_yaw) * cos(_pitch)) * distance
	position = target + offset
	look_at(target)
