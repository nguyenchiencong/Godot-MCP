extends CharacterBody3D

const SPEED = 5.0
const JUMP_VELOCITY = 4.5

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _physics_process(delta):
    # Add the gravity.
    if not is_on_floor():
        velocity.y -= gravity * delta

    # Handle movement.
    var input_dir = Vector3()
    input_dir.x = Input.get_axis("ui_left", "ui_right")
    input_dir.z = Input.get_axis("ui_up", "ui_down")
    input_dir = input_dir.normalized()
    
    if input_dir:
        velocity.x = input_dir.x * SPEED
        velocity.z = input_dir.z * SPEED
    else:
        velocity.x = move_toward(velocity.x, 0, SPEED)
        velocity.z = move_toward(velocity.z, 0, SPEED)

    move_and_slide()
