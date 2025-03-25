@tool
class_name MCPScriptResourceCommands
extends Node

var _websocket_server = null

func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"get_script":
			_handle_get_script(client_id, params, command_id)
			return true
		"edit_script":
			_handle_edit_script(client_id, params, command_id)
			return true
		"ai_generate_script":
			_handle_ai_generate_script(client_id, params, command_id)
			return true
	
	# Command not handled by this processor
	return false

# ---- Script Content Retrieval ----

func _handle_get_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var path = params.get("path", "")
	var node_path = params.get("node_path", "")
	
	# Handle based on which parameter is provided
	var script_path = ""
	var result = {}
	
	if not path.is_empty():
		# Direct script path provided
		result = _get_script_by_path(path)
	elif not node_path.is_empty():
		# Node path provided, get attached script
		result = _get_script_by_node(node_path)
	else:
		result = {
			"error": "Either script_path or node_path must be provided",
			"script_found": false
		}
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func _get_script_by_path(script_path: String) -> Dictionary:
	if not FileAccess.file_exists(script_path):
		return {
			"error": "Script file not found",
			"script_found": false
		}
	
	var file = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {
			"error": "Failed to open script file",
			"script_found": false
		}
	
	var content = file.get_as_text()
	return {
		"script_found": true,
		"script_path": script_path,
		"content": content
	}

func _get_script_by_node(node_path: String) -> Dictionary:
	var editor_interface = EditorInterface.new()
	var scene_root = editor_interface.get_edited_scene_root()
	
	if not scene_root:
		return {
			"error": "No scene open",
			"script_found": false
		}
	
	var node = scene_root.get_node_or_null(node_path)
	if not node:
		return {
			"error": "Node not found",
			"script_found": false
		}
	
	if not node.has_meta("_editor_description") or not node.get_script():
		return {
			"error": "Node has no script attached",
			"script_found": false
		}
	
	var script = node.get_script()
	var script_path = script.get_path()
	
	# Now get the content
	return _get_script_by_path(script_path)

# ---- Script Editing ----

func _handle_edit_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path = params.get("script_path", "")
	var content = params.get("content", "")
	
	var result = {}
	
	if script_path.is_empty():
		result = {
			"error": "Script path is required"
		}
	elif content.is_empty():
		result = {
			"error": "Content is required"
		}
	else:
		result = _edit_script_content(script_path, content)
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func _edit_script_content(script_path: String, content: String) -> Dictionary:
	var file = FileAccess.open(script_path, FileAccess.WRITE)
	if not file:
		return {
			"error": "Failed to open script file for writing"
		}
	
	file.store_string(content)
	
	# Open the script in the editor
	var editor_interface = EditorInterface.new()
	var script = load(script_path)
	if script:
		editor_interface.edit_resource(script)
	
	return {
		"success": true,
		"script_path": script_path
	}

# ---- AI Script Generation ----

func _handle_ai_generate_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var description = params.get("description", "")
	var node_type = params.get("node_type", "Node")
	var create_file = params.get("create_file", false)
	var file_path = params.get("file_path", "")
	
	var result = {}
	
	if description.is_empty():
		result = {
			"error": "Description is required"
		}
	else:
		var script_content = _generate_script_template(description, node_type)
		
		if create_file and not file_path.is_empty():
			# Create the file
			var file_result = _edit_script_content(file_path, script_content)
			
			if file_result.has("success"):
				result = {
					"success": true,
					"script_path": file_path,
					"content": script_content
				}
			else:
				result = file_result
		else:
			result = {
				"success": true,
				"content": script_content
			}
	
	var response = {
		"status": "success",
		"result": result
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)

func _generate_script_template(description: String, node_type: String) -> String:
	# Simple template generator (placeholder for a more sophisticated system)
	var class_name = node_type.replace("/", "_").replace(".", "_").replace(" ", "_")
	
	# Sanitize description for comments
	var safe_description = description.replace("#", "")
	
	# Create a basic template
	var template = "# " + safe_description + "\n"
	template += "extends " + node_type + "\n\n"
	template += "# Signals\n\n"
	template += "# Export variables\n\n"
	template += "# Private variables\n\n"
	template += "func _ready():\n"
	template += "\t# Initialize the " + node_type + "\n"
	template += "\tpass\n\n"
	template += "func _process(delta):\n"
	template += "\t# Process logic for " + safe_description + "\n"
	template += "\tpass\n\n"
	template += "# Custom methods\n\n"
	
	return template