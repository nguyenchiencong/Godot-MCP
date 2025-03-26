extends Node2D

# Tetris piece shapes with their corresponding vertex colors
enum PieceType { I, O, T, L, J, S, Z }

var piece_data = {
	PieceType.I: {
		"points": [
			Vector2(0, 0), Vector2(30, 0), Vector2(30, 120), Vector2(0, 120)
		],
		"color": Color(0, 1, 1)  # Cyan
	},
	PieceType.O: {
		"points": [
			Vector2(0, 0), Vector2(60, 0), Vector2(60, 60), Vector2(0, 60)
		],
		"color": Color(1, 1, 0)  # Yellow
	},
	PieceType.T: {
		"points": [
			Vector2(0, 0), Vector2(90, 0), Vector2(90, 30), Vector2(60, 30),
			Vector2(60, 60), Vector2(30, 60), Vector2(30, 30), Vector2(0, 30)
		],
		"color": Color(0.5, 0, 0.5)  # Purple
	},
	PieceType.L: {
		"points": [
			Vector2(0, 0), Vector2(30, 0), Vector2(30, -60), Vector2(60, -60),
			Vector2(60, 0), Vector2(90, 0), Vector2(90, 30), Vector2(0, 30)
		],
		"color": Color(1, 0.5, 0)  # Orange
	},
	PieceType.J: {
		"points": [
			Vector2(0, -60), Vector2(30, -60), Vector2(30, 0), Vector2(90, 0),
			Vector2(90, 30), Vector2(0, 30)
		],
		"color": Color(0, 0, 1)  # Blue
	},
	PieceType.S: {
		"points": [
			Vector2(30, 0), Vector2(90, 0), Vector2(90, 30), Vector2(60, 30),
			Vector2(60, 60), Vector2(0, 60), Vector2(0, 30), Vector2(30, 30)
		],
		"color": Color(0, 1, 0)  # Green
	},
	PieceType.Z: {
		"points": [
			Vector2(0, 0), Vector2(60, 0), Vector2(60, 30), Vector2(90, 30),
			Vector2(90, 60), Vector2(30, 60), Vector2(30, 30), Vector2(0, 30)
		],
		"color": Color(1, 0, 0)  # Red
	}
}

var current_piece

func _ready():
	# Set up the initial piece (in this case, the player object already in the scene)
	current_piece = $Player
	initialize_piece(PieceType.L)
	
func initialize_piece(piece_type):
	var data = piece_data[piece_type]
	var polygon = current_piece.get_node("Polygon")
	
	# Set polygon points
	polygon.polygon = data["points"]
	
	# Set vertex colors
	var colors = []
	for i in range(polygon.polygon.size()):
		colors.append(data["color"])
	polygon.vertex_colors = colors
	
	# Update collision shape
	var collision_shape = ConvexPolygonShape2D.new()
	collision_shape.points = polygon.polygon
	current_piece.get_node("Collision").shape = collision_shape
	
	# Reset position and rotation
	current_piece.position = Vector2(300, 100)
	current_piece.rotation = 0

func spawn_new_piece():
	# In a full implementation, this would create a new piece
	# For now, we'll just reset the current piece with a random type
	var piece_types = PieceType.values()
	var random_type = piece_types[randi() % piece_types.size()]
	initialize_piece(random_type)

func _input(event):
	if event.is_action_pressed("ui_home"):
		spawn_new_piece()
