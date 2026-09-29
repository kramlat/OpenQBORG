class_name OrbitCamera
extends Camera3D
## Editor camera: right-drag orbits, middle-drag (or Shift+right-drag) pans,
## wheel zooms. Always looks at `target` on the floor plane.

var target := Vector3(8, 0, 8)
var yaw := -0.6
var pitch := 0.95
var distance := 18.0


func _ready() -> void:
	fov = 50.0
	near = 0.05
	far = 2000.0
	_apply()


func frame_world(w: int, h: int) -> void:
	target = Vector3(w / 2.0, 0, h / 2.0)
	distance = maxf(w, h) * 1.15
	_apply()


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		var right: bool = (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0
		var middle: bool = (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0
		if middle or (right and event.shift_pressed):
			var scale := distance * 0.0018
			var r := global_basis.x
			var f := Vector3(-sin(yaw), 0, -cos(yaw))
			target += (-r * event.relative.x + f * event.relative.y) * scale
			_apply()
			return true
		if right:
			yaw -= event.relative.x * 0.006
			pitch = clampf(pitch + event.relative.y * 0.006, 0.08, 1.55)
			_apply()
			return true
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(1.5, distance * 0.9)
			_apply()
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(900.0, distance * 1.1)
			_apply()
			return true
	return false


func _apply() -> void:
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	position = target + offset
	look_at(target, Vector3.UP)
