extends Node2D

const GRID_SIZE = 32
const BOARD_WIDTH = 10
const BOARD_HEIGHT = 20

func _ready():
	create_game_boundaries()
	spawn_new_piece()

func create_game_boundaries():
	# Create walls and floor
	var walls = StaticBody2D.new()
	walls.name = "Boundaries"
	add_child(walls)
	
	# Left wall
	var left_wall = CollisionShape2D.new()
	var left_shape = RectangleShape2D.new()
	left_shape.extents = Vector2(10, GRID_SIZE * BOARD_HEIGHT)
	left_wall.position = Vector2(-10, GRID_SIZE * BOARD_HEIGHT / 2)
	left_wall.shape = left_shape
	walls.add_child(left_wall)
	
	# Right wall
	var right_wall = CollisionShape2D.new()
	var right_shape = RectangleShape2D.new()
	right_shape.extents = Vector2(10, GRID_SIZE * BOARD_HEIGHT)
	right_wall.position = Vector2(GRID_SIZE * BOARD_WIDTH + 10, GRID_SIZE * BOARD_HEIGHT / 2)
	right_wall.shape = right_shape
	walls.add_child(right_wall)
	
	# Floor
	var floor = CollisionShape2D.new()
	var floor_shape = RectangleShape2D.new()
	floor_shape.extents = Vector2(GRID_SIZE * BOARD_WIDTH / 2 + 10, 10)
	floor.position = Vector2(GRID_SIZE * BOARD_WIDTH / 2, GRID_SIZE * BOARD_HEIGHT + 10)
	floor.shape = floor_shape
	walls.add_child(floor)

func spawn_new_piece():
	var piece = create_soft_tetromino()
	piece.position = Vector2(GRID_SIZE * BOARD_WIDTH / 2, GRID_SIZE * 2)
	add_child(piece)

func create_soft_tetromino():
	var shapes = [
		[[1,1],
		 [1,1]], # Square
		[[1,1,1,1]], # Line
		[[1,1,1],
		 [0,1,0]], # T
		[[1,1,0],
		 [0,1,1]], # S
	]
	
	var selected_shape = shapes[randi() % shapes.size()]
	var tetromino = Node2D.new()
	tetromino.name = "SoftTetromino"
	
	var blocks = []
	var joints = []
	
	# Create soft body blocks
	for y in range(len(selected_shape)):
		for x in range(len(selected_shape[y])):
			if selected_shape[y][x] == 1:
				var block = create_soft_block(Vector2(x * GRID_SIZE, y * GRID_SIZE))
				blocks.append(block)
				tetromino.add_child(block)
	
	# Create soft body joints between blocks
	for i in range(blocks.size()):
		for j in range(i + 1, blocks.size()):
			var distance = blocks[i].position.distance_to(blocks[j].position)
			if distance <= GRID_SIZE * 1.5:
				create_joint(blocks[i], blocks[j], tetromino)
	
	return tetromino

func create_soft_block(pos: Vector2) -> RigidBody2D:
	var block = RigidBody2D.new()
	block.position = pos
	block.mass = 1.0
	block.gravity_scale = 1.0
	block.linear_damp = 0.5
	block.angular_damp = 1.0
	
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.extents = Vector2(GRID_SIZE/2 - 1, GRID_SIZE/2 - 1)
	collision.shape = shape
	block.add_child(collision)
	
	var visual = ColorRect.new()
	visual.size = Vector2(GRID_SIZE - 2, GRID_SIZE - 2)
	visual.position = Vector2(-GRID_SIZE/2 + 1, -GRID_SIZE/2 + 1)
	visual.color = Color(randf(), randf(), randf())
	block.add_child(visual)
	
	return block

func create_joint(block1: RigidBody2D, block2: RigidBody2D, parent: Node2D):
	var joint = DampedSpringJoint2D.new()
	joint.node_a = block1.get_path()
	joint.node_b = block2.get_path()
	joint.length = block1.position.distance_to(block2.position)
	joint.rest_length = joint.length
	joint.stiffness = 64
	joint.damping = 1.0
	parent.add_child(joint)

func _input(event):
	if event.is_action_pressed("ui_accept"):
		spawn_new_piece()
	elif event.is_action_pressed("ui_left"):
		move_current_piece(Vector2.LEFT * GRID_SIZE)
	elif event.is_action_pressed("ui_right"):
		move_current_piece(Vector2.RIGHT * GRID_SIZE)
	elif event.is_action_pressed("ui_down"):
		apply_soft_force(Vector2.DOWN * 500)

func move_current_piece(offset: Vector2):
	var current = get_current_piece()
	if current:
		for block in current.get_children():
			if block is RigidBody2D:
				block.position += offset

func apply_soft_force(force: Vector2):
	var current = get_current_piece()
	if current:
		for block in current.get_children():
			if block is RigidBody2D:
				block.apply_central_impulse(force)

func get_current_piece() -> Node2D:
	return get_node_or_null("SoftTetromino")
