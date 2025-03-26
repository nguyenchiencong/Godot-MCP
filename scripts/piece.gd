extends RigidBody2D

const GRID_SIZE = 32

func _ready():
	# Make sure physics don't affect the piece
	gravity_scale = 0
	lock_rotation = true

func _input(event):
	if event.is_action_pressed("ui_right"):
		position.x += GRID_SIZE
		print("Moving right")
	elif event.is_action_pressed("ui_left"):
		position.x -= GRID_SIZE
		print("Moving left")
	elif event.is_action_pressed("ui_down"):
		position.y += GRID_SIZE
		print("Moving down")
	elif event.is_action_pressed("ui_up"):
		position.y = 600  # Hard drop
		print("Hard drop")
