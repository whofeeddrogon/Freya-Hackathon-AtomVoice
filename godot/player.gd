extends CharacterBody3D

@export var walk_speed := 5.0
@export var sprint_speed := 8.0
@export var acceleration := 16.5
@export var mouse_sens := 0.0022
@export var jump_velocity := 4.5

@onready var pivot: Node3D = $Pivot
@onready var camera: Camera3D = $Pivot/SpringArm/Camera3D
@onready var anim_tree: AnimationTree = $AnimationTree

var gravity := ProjectSettings.get_setting("physics/3d/default_gravity") as float

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	anim_tree.active = true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sens)
		pivot.rotate_x(-event.relative.y * mouse_sens)
		pivot.rotation.x = clamp(pivot.rotation.x, deg_to_rad(-60), deg_to_rad(60))
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("space") and is_on_floor():
		velocity.y = jump_velocity

	var input_vec := Input.get_vector("a", "d", "w", "s")
	var dir := (transform.basis * Vector3(input_vec.x, 0, input_vec.y)).normalized()

	var target_speed := walk_speed
	if Input.is_action_pressed("shift"):
		target_speed = sprint_speed

	var target_vel := dir * target_speed

	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)

	move_and_slide()
	
	_update_locomotion(delta)

func _update_locomotion(delta: float) -> void:
	# Dünya hızını al (XZ)
	var v := velocity
	v.y = 0.0
	var local := global_transform.basis.inverse() * v
	var x := 0.0
	var y := 0.0
	if v.length() > 0.01:
		var max_speed := sprint_speed # ya da walk_speed, tasarımına göre
		x = clamp(local.x / max_speed, -1.0, 1.0)
		y = clamp((-local.z) / max_speed, -1.0, 1.0)

	anim_tree.set("parameters/blend_position", Vector2(x, y))
