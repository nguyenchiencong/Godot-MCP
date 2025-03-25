@tool
class_name MCPEnhancedCommands
extends Node

var _websocket_server = null

func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"get_full_scene_tree":
			_handle_get_full_scene_tree(client_id, params, command_id)
			return true
		"get_debug_output":
			_handle_get_debug_output(client_id, params, command_id)
			return true
		"update_node_transform":
			_handle_update_node_transform(client_id, params, command_id)
			return true
		# Existing list_project_files is likely already implemented elsewhere
		# If not, add it here as well
	
	# Command not handled by this processor
	return false

# Helper function to get EditorInterface
func _get_editor_interface():
	var plugin_instance = Engine.get_meta("GodotMCPPlugin") as EditorPlugin
	if plugin_instance:
		return plugin_instance.get_editor_interface()
	return null

# ---- Full Scene Tree Commands ----

func _handle_get_full_scene_tree(client_id: int, _params: Dictionary, command_id: String) -> void:
	var result = get_full_scene_tree()
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func get_full_scene_tree() -> Dictionary:
	var result = {}
	var editor_interface = _get_editor_interface()
	if editor_interface:
		var root = editor_interface.get_edited_scene_root()
		if root:
			result = _walk_node(root)
	return result

func _walk_node(node):
	var info = {
		"name": node.name,
		"type": node.get_class(),
		"path": node.get_path(),
		"properties": {},
		"children": []
	}
	
	# Get some common properties if they exist
	if node.has_method("get_property_list"):
		var props = node.get_property_list()
		for prop in props:
			# Filter to avoid too much data
			if prop.usage & PROPERTY_USAGE_EDITOR and not (prop.usage & PROPERTY_USAGE_CATEGORY):
				if prop.name in ["position", "rotation", "scale", "text", "visible"]:
					info["properties"][prop.name] = node.get(prop.name)
	
	# Recurse for children
	for child in node.get_children():
		info["children"].append(_walk_node(child))
	
	return info

# ---- Debug Output Commands ----

func _handle_get_debug_output(client_id: int, _params: Dictionary, command_id: String) -> void:
	var result = get_debug_output()
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func get_debug_output() -> Dictionary:
	var output = ""
	
	# For Godot 4.x
	if Engine.has_singleton("EditorDebuggerNode"):
		var debugger = Engine.get_singleton("EditorDebuggerNode")
		if debugger and debugger.has_method("get_log"):
			output = debugger.get_log()
	# For Godot 3.x fallback
	elif has_node("/root/EditorNode/DebuggerPanel"):
		var debugger = get_node("/root/EditorNode/DebuggerPanel")
		if debugger and debugger.has_method("get_output"):
			output = debugger.get_output()
	
	return {
		"output": output
	}

# ---- Node Transform Commands ----

func _handle_update_node_transform(client_id: int, params: Dictionary, command_id: String) -> void:
	var node_path = params.get("node_path", "")
	var position = params.get("position", null)
	var rotation = params.get("rotation", null)
	var scale = params.get("scale", null)
	
	var result = update_node_transform(node_path, position, rotation, scale)
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func update_node_transform(node_path: String, position, rotation, scale) -> Dictionary:
	var editor_interface = _get_editor_interface()
	
	if not editor_interface:
		return { "error": "Could not access EditorInterface" }
	
	var scene_root = editor_interface.get_edited_scene_root()
	
	if not scene_root:
		return { "error": "No scene open" }
	
	var node = scene_root.get_node_or_null(node_path)
	if not node:
		return { "error": "Node not found" }
	
	# Update all specified properties
	if position != null and node.has_method("set_position"):
		node.set_position(Vector2(position[0], position[1]))
	
	if rotation != null and node.has_method("set_rotation"):
		node.set_rotation(rotation)
	
	if scale != null and node.has_method("set_scale"):
		node.set_scale(Vector2(scale[0], scale[1]))
	
	return {
		"success": true,
		"node_path": node_path
	}