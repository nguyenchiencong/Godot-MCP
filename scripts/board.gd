extends Node2D

# Board dimensions
const ROWS = 20
const COLS = 10
const CELL_SIZE = 30

# Board state (0 = empty, 1+ = occupied with piece index)
var grid = []
var settled_pieces = []

# Visual elements
var grid_lines = []
var cell_polygons = []

func _ready():
	# Initialize grid
	grid.resize(ROWS)
	for row in range(ROWS):
		grid[row] = []
		grid[row].resize(COLS)
		for col in range(COLS):
			grid[row][col] = 0
	
	# Position the board
	position = Vector2(100, 50)
	
	# Draw grid lines
	draw_grid()
	
	# Initialize polygon containers for settled pieces
	cell_polygons.resize(ROWS * COLS)

func draw_grid():
	# Create grid lines
	var grid_container = Node2D.new()
	grid_container.name = "GridLines"
	add_child(grid_container)
	
	for i in range(ROWS + 1):
		var line = Line2D.new()
		line.points = [Vector2(0, i * CELL_SIZE), Vector2(COLS * CELL_SIZE, i * CELL_SIZE)]
		line.width = 1.0
		line.default_color = Color(0.5, 0.5, 0.5, 0.5)
		grid_container.add_child(line)
	
	for j in range(COLS + 1):
		var line = Line2D.new()
		line.points = [Vector2(j * CELL_SIZE, 0), Vector2(j * CELL_SIZE, ROWS * CELL_SIZE)]
		line.width = 1.0
		line.default_color = Color(0.5, 0.5, 0.5, 0.5)
		grid_container.add_child(line)
	
	# Add a background
	var background = Polygon2D.new()
	background.polygon = [
		Vector2(0, 0),
		Vector2(COLS * CELL_SIZE, 0),
		Vector2(COLS * CELL_SIZE, ROWS * CELL_SIZE),
		Vector2(0, ROWS * CELL_SIZE)
	]
	background.color = Color(0.1, 0.1, 0.1, 0.7)
	grid_container.add_child(background)
	background.z_index = -1

func is_valid_position(piece_polygons, piece_position, piece_rotation):
	# Convert piece coordinates to grid coordinates and check if valid
	var rotated_polygons = []
	
	for polygon in piece_polygons:
		var rotated_polygon = []
		for point in polygon:
			# Apply rotation and translation
			var rotated_point = point.rotated(piece_rotation)
			var world_point = rotated_point + piece_position
			
			# Convert to grid coordinates
			var grid_x = int((world_point.x - position.x) / CELL_SIZE)
			var grid_y = int((world_point.y - position.y) / CELL_SIZE)
			
			# Check bounds
			if grid_x < 0 or grid_x >= COLS or grid_y < 0 or grid_y >= ROWS:
				return false
			
			# Check if cell is occupied
			if grid[grid_y][grid_x] != 0:
				return false
				
			rotated_polygon.append(Vector2(grid_x, grid_y))
		
		rotated_polygons.append(rotated_polygon)
	
	return true

func add_piece_to_grid(piece):
	# Extract piece data
	var polygons = piece.get_node("Polygon").polygon
	var colors = piece.get_node("Polygon").vertex_colors
	var piece_position = piece.global_position
	var piece_rotation = piece.rotation
	
	# Create a copy of the piece as a settled piece
	var settled_piece = Node2D.new()
	settled_piece.name = "SettledPiece" + str(settled_pieces.size())
	settled_piece.position = piece_position - position
	settled_piece.rotation = piece_rotation
	
	var settled_polygon = Polygon2D.new()
	settled_polygon.polygon = polygons
	settled_polygon.vertex_colors = colors
	settled_piece.add_child(settled_polygon)
	
	# Add to settled pieces array and to the scene
	settled_pieces.append(settled_piece)
	add_child(settled_piece)
	
	# Add softbody physics to the settled piece
	var softbody = SoftBodyHelper.new()
	settled_piece.add_child(softbody)
	softbody.initialize_from_polygon(settled_polygon)
	softbody.gravity = Vector2(0, 100)  # Reduced gravity
	
	# Update grid state
	for polygon_point in polygons:
		var grid_point = settled_piece.to_local(polygon_point + piece_position)
		var grid_x = int(grid_point.x / CELL_SIZE)
		var grid_y = int(grid_point.y / CELL_SIZE)
		
		if grid_x >= 0 and grid_x < COLS and grid_y >= 0 and grid_y < ROWS:
			grid[grid_y][grid_x] = settled_pieces.size()
	
	# Check for completed rows
	check_completed_rows()

func check_completed_rows():
	var rows_to_clear = []
	
	# Check each row
	for row in range(ROWS):
		var is_complete = true
		for col in range(COLS):
			if grid[row][col] == 0:
				is_complete = false
				break
		
		if is_complete:
			rows_to_clear.append(row)
	
	# Clear completed rows (from bottom to top)
	rows_to_clear.sort()
	rows_to_clear.reverse()
	
	for row in rows_to_clear:
		clear_row(row)

func clear_row(row):
	# Mark the row for clearing
	for col in range(COLS):
		grid[row][col] = 0
	
	# Apply "clear" forces to all pieces in this row
	for piece in settled_pieces:
		var softbody = piece.get_child(1)  # Assuming softbody is the second child
		if softbody is SoftBodyHelper:
			for i in range(softbody.bones.size()):
				var bone_pos = piece.position + softbody.bones[i].current_position
				var grid_y = int(bone_pos.y / CELL_SIZE)
				
				if grid_y == row:
					# Apply explosive force
					var force = Vector2(randf_range(-1, 1), randf_range(-1, 0)).normalized() * 1000
					softbody.apply_force_at_point(force, i)
	
	# Shift rows down (in a real game)
	for r in range(row - 1, -1, -1):
		for c in range(COLS):
			grid[r + 1][c] = grid[r][c]
	
	# Clear top row
	for c in range(COLS):
		grid[0][c] = 0

func _process(delta):
	# Update all settled pieces' physics
	for piece in settled_pieces:
		var softbody = piece.get_child(1)
		if softbody is SoftBodyHelper:
			softbody.update_physics(delta, piece.global_transform)
