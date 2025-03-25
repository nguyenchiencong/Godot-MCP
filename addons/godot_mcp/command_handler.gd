@tool
class_name MCPCommandHandler
extends Node

var _websocket_server
var _command_processors = []

func _ready():
	print("Command handler initializing...")
	await get_tree().process_frame
	_websocket_server = get_parent()
	print("WebSocket server reference set: ", _websocket_server)
	
	# Initialize command processors
	_initialize_command_processors()
	
	print("Command handler initialized and ready to process commands")

func _initialize_command_processors():
	# Create and add all required command processors
	var node_commands = MCPNodeCommands.new()
	var script_commands = MCPScriptCommands.new()
	var scene_commands = MCPSceneCommands.new() 
	var project_commands = MCPProjectCommands.new()
	var editor_commands = MCPEditorCommands.new()
	var editor_script_commands = MCPEditorScriptCommands.new()
	
	# Ensure the optional command classes are loaded before trying to instantiate them
	var script_resource_commands = null
	if ClassDB.class_exists("MCPScriptResourceCommands") or ResourceLoader.exists("res://addons/godot_mcp/mcp_script_resource_commands.gd"):
		script_resource_commands = MCPScriptResourceCommands.new()
	else:
		push_error("MCPScriptResourceCommands class not found")
	
	# Try to instantiate other custom classes 
	var enhanced_commands = null
	if ClassDB.class_exists("MCPEnhancedCommands"):
		enhanced_commands = MCPEnhancedCommands.new()
	else:
		push_error("MCPEnhancedCommands class not found")
		
	var asset_commands = null
	if ClassDB.class_exists("MCPAssetCommands"):
		asset_commands = MCPAssetCommands.new()
	else:
		push_error("MCPAssetCommands class not found")
	
	# Set server reference for all processors
	node_commands._websocket_server = _websocket_server
	script_commands._websocket_server = _websocket_server
	scene_commands._websocket_server = _websocket_server
	project_commands._websocket_server = _websocket_server
	editor_commands._websocket_server = _websocket_server
	editor_script_commands._websocket_server = _websocket_server
	
	# Add them to our processor list
	_command_processors.append(node_commands)
	_command_processors.append(script_commands)
	_command_processors.append(scene_commands)
	_command_processors.append(project_commands)
	_command_processors.append(editor_commands)
	_command_processors.append(editor_script_commands)
	
	# Set server reference and add optional processors if available
	if script_resource_commands:
		script_resource_commands._websocket_server = _websocket_server
		_command_processors.append(script_resource_commands)
		add_child(script_resource_commands)
	
	if enhanced_commands:
		enhanced_commands._websocket_server = _websocket_server
		_command_processors.append(enhanced_commands)
		add_child(enhanced_commands)
		
	if asset_commands:
		asset_commands._websocket_server = _websocket_server
		_command_processors.append(asset_commands)
		add_child(asset_commands)
	
	# Add required processors as children for proper lifecycle management
	add_child(node_commands)
	add_child(script_commands)
	add_child(scene_commands)
	add_child(project_commands)
	add_child(editor_commands)
	add_child(editor_script_commands)
	
	print("Command processors initialized:")
	print("- Node Commands")
	print("- Script Commands")
	print("- Scene Commands")
	print("- Project Commands") 
	print("- Editor Commands")
	print("- Editor Script Commands")
	
	if script_resource_commands:
		print("- Script Resource Commands")
	if enhanced_commands:
		print("- Enhanced Commands")
	if asset_commands:
		print("- Asset Commands")

func _handle_command(client_id: int, command: Dictionary) -> void:
	var command_type = command.get("type", "")
	var params = command.get("params", {})
	var command_id = command.get("commandId", "")
	
	print("Processing command: %s" % command_type)
	
	# Try each processor until one handles the command
	for processor in _command_processors:
		if processor.process_command(client_id, command_type, params, command_id):
			print("Command %s handled by %s" % [command_type, processor.get_class()])
			return
	
	# If no processor handled the command, send an error
	_send_error(client_id, "Unknown command: %s" % command_type, command_id)

func _send_error(client_id: int, message: String, command_id: String) -> void:
	var response = {
		"status": "error",
		"message": message
	}
	
	if not command_id.is_empty():
		response["commandId"] = command_id
	
	_websocket_server.send_response(client_id, response)
	print("Error: %s" % message)