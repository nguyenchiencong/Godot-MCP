extends CharacterBody2D

var speed = 300.0
var rotation_speed = 2.0
var softbody: SoftBodyHelper

func _ready():
	# Initialize the Tetris piece as an L-shape with vertex colors
	var polygon = $Polygon
	polygon.polygon = [
		Vector2(0, 0),
		Vector2(0, -30),
		Vector2(30, -30),
		Vector2(30, 0),
		Vector2(60, 0),
		Vector2(60, 30),
		Vector2(0, 30)
	]
	
	# Set vertex colors (blue)
	var colors = []
	for i in range(polygon.polygon.size()):
		colors.append(Color(0.2, 0.2, 1.0))
	polygon.vertex_colors = colors
	
	# Set up collision shape to match the polygon
	var collision_shape = ConvexPolygonShape2D.new()
	collision_shape.points = polygon.polygon
	$Collision.shape = collision_shape
	
	# Initialize softbody physics
	softbody = SoftBodyHelper.new()
	add_child(softbody)
	softbody.initialize_from_polygon(polygon)
	# Reduce gravity for better control
	softbody.gravity = Vector2(0, 200)

func _physics_process(delta):
	# Handle input
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	velocity = input_dir * speed
	
	# Rotation
	if Input.is_action_pressed("ui_select"):
		rotate(rotation_speed * delta)
		# Apply rotational force to softbody
		var rotation_force = Vector2(cos(rotation), sin(rotation)) * 50
		softbody.apply_force(rotation_force)
	elif Input.is_action_pressed("ui_cancel"):
		rotate(-rotation_speed * delta)
		# Apply counter-rotational force
		var rotation_force = Vector2(cos(rotation), sin(rotation)) * -50
		softbody.apply_force(rotation_force)
	
	# Apply movement force to softbody
	if input_dir.length() > 0:
		softbody.apply_force(input_dir * 500)
	
	# Update softbody physics
	softbody.update_physics(delta, global_transform)
	
	# Update collision shape to match deformed polygon
	if softbody.target_polygon:
		var collision_shape = ConvexPolygonShape2D.new()
		collision_shape.points = softbody.target_polygon.polygon
		$Collision.shape = collision_shape
	
	move_and_slide()

func _input(event):
	# Handle quick rotation by 90 degrees
	if event.is_action_pressed("ui_page_up"):
		rotation_degrees += 90
		# Reset softbody to rest after rotation
		if softbody:
			softbody.reset_to_rest_positions()
	elif event.is_action_pressed("ui_page_down"):
		rotation_degrees -= 90
		# Reset softbody to rest after rotation
		if softbody:
			softbody.reset_to_rest_positions()
			
	# Add collision response
	if event is InputEventMouseButton and event.pressed:
		var local_pos = to_local(event.position)
		# Find closest vertex and apply force
		var closest_idx = 0
		var closest_dist = INF
		for i in range(softbody.bones.size()):
			var dist = local_pos.distance_to(softbody.bones[i].current_position)
			if dist < closest_dist:
				closest_dist = dist
				closest_idx = i
		
		# Apply force toward mouse click
		var force_dir = (local_pos - softbody.bones[closest_idx].current_position).normalized()
		softbody.apply_force_at_point(force_dir * 5000, closest_idx)
