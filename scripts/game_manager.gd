extends Node2D

const GRID_SIZE = 30
const GRID_WIDTH = 10
const GRID_HEIGHT = 20

var current_piece = null
var next_piece = null
var game_over = false

func _ready():
	setup_game_area()
	spawn_new_piece()

func setup_game_area():
	# Create walls
	var left_wall = StaticBody2D.new()
	var left_wall_collision = CollisionShape2D.new()
	var left_wall_shape = RectangleShape2D.new()
	left_wall_shape.extents = Vector2(10, GRID_SIZE * GRID_HEIGHT / 2)
	left_wall_collision.shape = left_wall_shape
	left_wall.position = Vector2(0, GRID_SIZE * GRID_HEIGHT / 2)
	left_wall.add_child(left_wall_collision)
	add_child(left_wall)
	
	var right_wall = StaticBody2D.new()
	var right_wall_collision = CollisionShape2D.new()
	var right_wall_shape = RectangleShape2D.new()
	right_wall_shape.extents = Vector2(10, GRID_SIZE * GRID_HEIGHT / 2)
	right_wall_collision.shape = right_wall_shape
	right_wall.position = Vector2(GRID_SIZE * GRID_WIDTH, GRID_SIZE * GRID_HEIGHT / 2)
	right_wall.add_child(right_wall_collision)
	add_child(right_wall)
	
	var bottom_wall = StaticBody2D.new()
	var bottom_wall_collision = CollisionShape2D.new()
	var bottom_wall_shape = RectangleShape2D.new()
	bottom_wall_shape.extents = Vector2(GRID_SIZE * GRID_WIDTH / 2, 10)
	bottom_wall_collision.shape = bottom_wall_shape
	bottom_wall.position = Vector2(GRID_SIZE * GRID_WIDTH / 2, GRID_SIZE * GRID_HEIGHT)
	bottom_wall.add_child(bottom_wall_collision)
	add_child(bottom_wall)

func spawn_new_piece():
	if current_piece != null:
		return
		
	var piece = create_tetromino()
	piece.position = Vector2(GRID_SIZE * GRID_WIDTH / 2, GRID_SIZE)
	add_child(piece)
	current_piece = piece

func create_tetromino():
	var shapes = [
		[[1,1],
		 [1,1]], # Square
		[[1,1,1,1]], # Line
		[[1,1,1],
		 [0,1,0]], # T
	]
	
	var selected_shape = shapes[randi() % shapes.size()]
	var piece = Node2D.new()
	
	for y in range(len(selected_shape)):
		for x in range(len(selected_shape[y])):
			if selected_shape[y][x] == 1:
				var block = create_soft_block()
				block.position = Vector2(x * GRID_SIZE, y * GRID_SIZE)
				piece.add_child(block)
	
	return piece

func create_soft_block():
	var block = RigidBody2D.new()
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.extents = Vector2(GRID_SIZE/2 - 1, GRID_SIZE/2 - 1)
	collision.shape = shape
	
	var visual = ColorRect.new()
	visual.size = Vector2(GRID_SIZE - 2, GRID_SIZE - 2)
	visual.position = Vector2(-GRID_SIZE/2 + 1, -GRID_SIZE/2 + 1)
	visual.color = Color(randf(), randf(), randf())
	
	block.mass = 1.0
	block.gravity_scale = 1.0
	block.linear_damp = 0.5
	block.angular_damp = 0.5
	
	block.add_child(collision)
	block.add_child(visual)
	return block

func _physics_process(_delta):
	if Input.is_action_just_pressed("ui_left"):
		move_piece(Vector2(-GRID_SIZE, 0))
	elif Input.is_action_just_pressed("ui_right"):
		move_piece(Vector2(GRID_SIZE, 0))
	elif Input.is_action_just_pressed("ui_down"):
		move_piece(Vector2(0, GRID_SIZE))
	elif Input.is_action_just_pressed("ui_up"):
		rotate_piece()

func move_piece(offset):
	if current_piece != null:
		current_piece.position += offset

func rotate_piece():
	if current_piece != null:
		current_piece.rotation_degrees += 90
