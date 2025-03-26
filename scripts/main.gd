extends Node2D

const GRID_SIZE = 32

func _process(_delta):
	var piece = $TestPiece
	
	# Basic movement
	if Input.is_action_pressed("ui_right"):
		piece.position.x += GRID_SIZE
	if Input.is_action_pressed("ui_left"):
		piece.position.x -= GRID_SIZE
	if Input.is_action_pressed("ui_down"):
		piece.position.y += GRID_SIZE
	if Input.is_action_pressed("ui_up"):
		piece.position.y -= GRID_SIZE
		
	# Keep in bounds
	piece.position.x = clamp(piece.position.x, 0, 288)  # 320 - 32
	piece.position.y = clamp(piece.position.y, 0, 608)  # 640 - 32
	
	# Debug info
	if Input.is_action_just_pressed("ui_right"):
		print("Right pressed")
	if Input.is_action_just_pressed("ui_left"):
		print("Left pressed")
