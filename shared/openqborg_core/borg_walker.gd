class_name BorgWalker
extends CharacterBody3D
## First-person walker with the original QBORG controls:
## Up/Down (or W/S) walk, Left/Right turn, A/D strafe, PgUp/PgDn look.

const RADIUS := 0.12
const TURN_SPEED := 1.4
const PITCH_SPEED := 0.9
const MAX_PITCH := PI / 5

## Tiles per second. Set from the level's SP value.
var walk_speed := 4.0
var yaw := 0.0
var pitch := 0.0
var camera: Camera3D


func _init() -> void:
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = 0.5
	shape.shape = cyl
	shape.position.y = 0.25
	add_child(shape)
	camera = Camera3D.new()
	# The original browser used a narrow 512/17 degree lens; keep that look.
	camera.fov = 30.0
	camera.near = 0.01
	camera.far = 64.0
	add_child(camera)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING


func place(pos: Vector2, eye_height: float, p_yaw: float) -> void:
	position = Vector3(pos.x, 0, pos.y)
	camera.position.y = maxf(eye_height, 0.05)
	yaw = p_yaw
	pitch = 0.0
	_apply_rotation()


func _physics_process(delta: float) -> void:
	yaw += (Input.get_action_strength("borg_turn_left") - Input.get_action_strength("borg_turn_right")) * TURN_SPEED * delta
	pitch = clampf(pitch + (Input.get_action_strength("borg_look_up") - Input.get_action_strength("borg_look_down")) \
			* PITCH_SPEED * delta, -MAX_PITCH, MAX_PITCH)
	_apply_rotation()
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var move := forward * (Input.get_action_strength("borg_forward") - Input.get_action_strength("borg_back")) \
			+ right * (Input.get_action_strength("borg_strafe_right") - Input.get_action_strength("borg_strafe_left"))
	velocity = move.limit_length(1.0) * walk_speed
	move_and_slide()


func _apply_rotation() -> void:
	camera.rotation = Vector3(pitch, yaw, 0)
