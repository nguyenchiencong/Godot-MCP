extends Node

func _ready():
	print("Scene checker running")
	
	var scene = get_tree().current_scene
	if scene:
		print("Current scene: ", scene.name)
		
		# Check Game node
		var game_node = scene.get_node_or_null("Game")
		if game_node:
			print("Game node exists")
			print("Game node visible: ", game_node.visible)
			
			# Check Player node
			var player_node = game_node.get_node_or_null("Player")
			if player_node:
				print("Player node exists")
				print("Player node visible: ", player_node.visible)
				print("Player node position: ", player_node.position)
				
				# Check Polygon
				var polygon = player_node.get_node_or_null("Polygon")
				if polygon:
					print("Polygon exists")
					print("Polygon visible: ", polygon.visible)
				else:
					print("Polygon not found")
			else:
				print("Player node not found")
		else:
			print("Game node not found")
	else:
		print("No current scene")
