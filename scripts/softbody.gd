extends Node

class_name SoftBodyHelper

# Structure to hold bone data
class SoftBodyBone:
	var rest_position: Vector2
	var current_position: Vector2
	var velocity: Vector2
	var mass: float
	var connections: Array[int]
	
	func _init(pos: Vector2, m: float = 1.0):
		rest_position = pos
		current_position = pos
		velocity = Vector2.ZERO
		mass = m
		connections = []

# Structure to hold spring data
class SoftBodySpring:
	var bone1_idx: int
	var bone2_idx: int
	var rest_length: float
	var stiffness: float
	var damping: float
	
	func _init(b1: int, b2: int, stiff: float, damp: float, bones: Array[SoftBodyBone]):
		bone1_idx = b1
		bone2_idx = b2
		rest_length = bones[b1].rest_position.distance_to(bones[b2].rest_position)
		stiffness = stiff
		damping = damp

# Physics parameters
var bones: Array[SoftBodyBone] = []
var springs: Array[SoftBodySpring] = []
var gravity: Vector2 = Vector2(0, 980)
var gravity_enabled: bool = true
var damping: float = 0.02
var stiffness: float = 0.1
var simulation_active: bool = true

# Reference to the polygon to deform
var target_polygon: Polygon2D

func initialize_from_polygon(polygon: Polygon2D, mass: float = 1.0):
	target_polygon = polygon
	bones.clear()
	springs.clear()
	
	# Create bones at each vertex
	for point in polygon.polygon:
		var bone = SoftBodyBone.new(point, mass)
		bones.append(bone)
	
	# Create springs between adjacent vertices
	for i in range(bones.size()):
		var next_i = (i + 1) % bones.size()
		bones[i].connections.append(next_i)
		bones[next_i].connections.append(i)
		
		var spring = SoftBodySpring.new(i, next_i, stiffness, damping, bones)
		springs.append(spring)
	
	# Create cross springs for stability (connecting every other vertex)
	for i in range(bones.size()):
		for j in range(i + 2, bones.size()):
			if j != (i + 1) % bones.size() and j != (i - 1 + bones.size()) % bones.size():
				var spring = SoftBodySpring.new(i, j, stiffness * 0.5, damping, bones)
				springs.append(spring)
				bones[i].connections.append(j)
				bones[j].connections.append(i)

func apply_force(force: Vector2):
	for bone in bones:
		bone.velocity += force / bone.mass

func apply_force_at_point(force: Vector2, point_idx: int):
	bones[point_idx].velocity += force / bones[point_idx].mass

func update_physics(delta: float, parent_transform: Transform2D):
	if not simulation_active:
		return
		
	# Apply global forces (gravity)
	if gravity_enabled:
		for bone in bones:
			bone.velocity += gravity * delta
	
	# Apply spring forces
	for spring in springs:
		var bone1 = bones[spring.bone1_idx]
		var bone2 = bones[spring.bone2_idx]
		
		var delta_pos = bone2.current_position - bone1.current_position
		var delta_vel = bone2.velocity - bone1.velocity
		var current_length = delta_pos.length()
		
		if current_length == 0:
			continue
			
		var direction = delta_pos / current_length
		
		# Spring force (proportional to displacement from rest length)
		var spring_force = direction * (current_length - spring.rest_length) * spring.stiffness
		
		# Damping force (proportional to relative velocity)
		var damping_force = delta_vel * spring.damping
		
		# Apply forces
		var total_force = spring_force + damping_force
		bone1.velocity += total_force / bone1.mass
		bone2.velocity -= total_force / bone2.mass
	
	# Update positions
	for bone in bones:
		# Apply damping
		bone.velocity *= (1.0 - damping)
		
		# Update position
		bone.current_position += bone.velocity * delta
	
	# Update the polygon vertices
	var updated_polygon = PackedVector2Array()
	for bone in bones:
		# Convert from local bone space to parent space
		updated_polygon.append(bone.current_position)
	
	# Update the target polygon
	target_polygon.polygon = updated_polygon

func reset_to_rest_positions():
	for i in range(bones.size()):
		bones[i].current_position = bones[i].rest_position
		bones[i].velocity = Vector2.ZERO
