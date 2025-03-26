extends Node2D

const GRID_SIZE = 30
const BOARD_WIDTH = 10
const BOARD_HEIGHT = 20

var current_piece = null
var pieces = []

func _ready():
	setup_game_board()
	spawn_new_piece()

func setup_game_board():
	# Create boundary walls
	create_wall(Vector2(-GRID_SIZE, 0), Vector2(GRID_SIZE, BOARD_HEIGHT * GRID_SIZE)) # Left wall
	create_wall(Vector2(BOARD_WIDTH * GRID_SIZE, 0), Vector2(GRID_SIZE, BOARD_HEIGHT * GRID_SIZE)) # Right wall
	create_wall(Vector2(0, BOARD_HEIGHT * GRID_SIZE), Vector2(BOARD_WIDTH * GRID_SIZE, GRID_SIZE)) # Bottom wall

func create_wall(pos: Vector2, size: Vector2):
	var wall = StaticBody2D.new()
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.extents = size / 2
	collision.shape = shape
	wall.add_child(collision)
	wall.position = pos + size / 2
	add_child(wall)

func spawn_new_piece():
	var piece = create_tetris_piece()
	piece.position = Vector2(BOARD_WIDTH * GRID_SIZE / 2, GRID_SIZE * 2)
	add_child(piece)
	current_piece = piece

func create_tetris_piece() -> RigidBody2D:
	var piece = RigidBody2D.new()
	piece.mass = 1.0
	piece.gravity_scale = 0.5
	
	# Create soft body blocks
	var blocks = create_soft_body_blocks()
	for block in blocks:
		piece.add_child(block)
	
	return piece

func create_soft_body_blocks() -> Array:
	var blocks = []
	var shape = [
		Vector2(0, 0),
		Vector2(1, 0),
		Vector2(0, 1),
		Vector2(1, 1)
	]
	
	for pos in shape:
		var block = create_soft_body_block(pos * GRID_SIZE)
		blocks.append(block)
	
	# Connect blocks with joints
	for i in range(blocks.size()):
		for j in range(i + 1, blocks.size()):
			create_joint(blocks[i], blocks[j])
	
	return blocks

func create_soft_body_block(pos: Vector2) -> RigidBody2D:
	var block = RigidBody2D.new()
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.extents = Vector2(GRID_SIZE / 2, GRID_SIZE / 2)
	collision.shape = shape
	
	var visual = ColorRect.new()
	visual.color = Color(0.2, 0.8, 0.2)
	visual.size = Vector2(GRID_SIZE, GRID_SIZE)
	visual.position = -Vector2(GRID_SIZE / 2, GRID_SIZE / 2)
	
	block.add_child(collision)
	block.add_child(visual)
	block.position = pos
	
	return block

func create_joint(block1: RigidBody2D, block2: RigidBody2D):
	var joint = DampedSpringJoint2D.new()
	joint.length = block1.position.distance_to(block2.position)
	joint.rest_length = joint.length
	joint.stiffness = 64
	joint.damping = 1.0
	joint.node_a = block1.get_path()
	joint.node_b = block2.get_path()
	add_child(joint)

func _process(delta):
	if Input.is_action_just_pressed("ui_left"):
		move_piece(Vector2(-GRID_SIZE, 0))
	elif Input.is_action_just_pressed("ui_right"):
		move_piece(Vector2(GRID_SIZE, 0))
	elif Input.is_action_just_pressed("ui_down"):
		move_piece(Vector2(0, GRID_SIZE))
	elif Input.is_action_just_pressed("ui_up"):
		rotate_piece()

func move_piece(offset: Vector2):
	if current_piece:
		current_piece.position += offset

func rotate_piece():
	if current_piece:
		current_piece.rotation_degrees += 90
