@tool
class_name MCPScriptCommands
extends MCPBaseCommandProcessor

# Compiled once in _init() instead of on every metadata extraction call.
var _class_name_regex := RegEx.new()
var _extends_regex := RegEx.new()
var _method_regex := RegEx.new()
var _signal_regex := RegEx.new()

# Lazily-created validation processor instance, reused across diagnostics
# calls for the lifetime of this processor (editor session).
var _validation_commands = null

func _init() -> void:
	_class_name_regex.compile("class_name\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
	_extends_regex.compile("extends\\s+([a-zA-Z_][a-zA-Z0-9_]*)")
	_method_regex.compile("func\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(")
	_signal_regex.compile("signal\\s+([a-zA-Z_][a-zA-Z0-9_]*)")

func _exit_tree() -> void:
	# Free the lazily-created validation processor Node when this processor
	# leaves the tree, so no Node leak accumulates on shutdown. The shared
	# subprocess cache lives in Engine metadata and stays process-wide; only
	# the cached helper Node is freed. Session caching is preserved: the
	# instance is only recreated lazily on the next diagnostics call while
	# the editor session lives.
	if _validation_commands != null:
		_validation_commands.free()
		_validation_commands = null

func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"create_script":
			await _create_script(client_id, params, command_id)
			return true
		"edit_script":
			await _edit_script(client_id, params, command_id)
			return true
		"get_script":
			_get_script(client_id, params, command_id)
			return true
		"get_script_metadata":
			_get_script_metadata(client_id, params, command_id)
			return true
		"get_current_script":
			_get_current_script(client_id, params, command_id)
			return true
	return false  # Command not handled

# Add this function to help find script files
func _find_script_file(script_name: String) -> String:
	# First, normalize the path
	var script_path = script_name
	
	# Add extension if missing
	if not script_path.ends_with(".gd") and not script_path.ends_with(".cs"):
		script_path += ".gd"  # Default to GDScript
	
	# If path already contains res://, use it directly
	if script_path.begins_with("res://"):
		if FileAccess.file_exists(script_path):
			return script_path
	else:
		# Add res:// prefix if missing
		script_path = "res://" + script_path
		if FileAccess.file_exists(script_path):
			return script_path
	
	# If not found directly, try common script locations
	var file_name = script_path.get_file()
	var common_dirs = [
		"res://scripts/",
		"res://",
		"res://scenes/",
		"res://addons/"
	]
	
	for dir in common_dirs:
		var test_path = dir + file_name
		if FileAccess.file_exists(test_path):
			return test_path
	
	return ""  # Not found

func _create_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path = params.get("script_path", "")
	var content = params.get("content", "")
	var node_path = params.get("node_path", "")
	var diagnostics := bool(params.get("diagnostics", true))
	
	# Validation
	if script_path.is_empty():
		return _send_error(client_id, "Script path cannot be empty", command_id)
	
	# Make sure we have an absolute path
	if not script_path.begins_with("res://"):
		script_path = "res://" + script_path
	
	if not script_path.ends_with(".gd"):
		script_path += ".gd"
	
	# Get editor plugin and interfaces
	var plugin = Engine.get_meta("GodotMCPPlugin")
	if not plugin:
		return _send_error(client_id, "GodotMCPPlugin not found in Engine metadata", command_id)
	
	var editor_interface = plugin.get_editor_interface()
	var script_editor = editor_interface.get_script_editor()
	
	# Create the directory if it doesn't exist
	var dir = script_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err = DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return _send_error(client_id, "Failed to create directory: %s (Error code: %d)" % [dir, err], command_id)
	
	# Create the script file
	var file = FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return _send_error(client_id, "Failed to create script file: %s" % script_path, command_id)
	
	file.store_string(content)
	file = null  # Close the file
	
	# Refresh the filesystem
	editor_interface.get_resource_filesystem().scan()
	
	# Attach the script to a node if specified
	if not node_path.is_empty():
		var node = _get_editor_node(node_path)
		if not node:
			# Try enhanced node resolution
			node = _get_editor_node_enhanced(node_path)
			if not node:
				return _send_error(client_id, "Node not found: %s" % node_path, command_id)
		
		# Wait for script to be recognized in the filesystem
		await get_tree().create_timer(0.5).timeout
		
		var script = load(script_path)
		if not script:
			return _send_error(client_id, "Failed to load script: %s" % script_path, command_id)
		
		# Use undo/redo for script assignment
		var undo_redo = _get_undo_redo()
		if not undo_redo:
			# Fallback method if we can't get undo/redo
			node.set_script(script)
			_mark_scene_modified()
		else:
			# Use undo/redo for proper editor integration
			undo_redo.create_action("Assign Script")
			undo_redo.add_do_method(node, "set_script", script)
			undo_redo.add_undo_method(node, "set_script", node.get_script())
			undo_redo.commit_action()
		
		# Mark the scene as modified
		_mark_scene_modified()
	
	# Open the script in the editor
	var script_resource = load(script_path)
	if script_resource:
		editor_interface.edit_script(script_resource)
	
	var result := {
		"script_path": script_path,
		"node_path": node_path
	}
	if diagnostics and script_path.ends_with(".gd"):
		result["diagnostics"] = await _diagnose_script(script_path)
	
	_send_success(client_id, result, command_id)

func _edit_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path = params.get("script_path", "")
	var content = params.get("content", "")
	var diagnostics := bool(params.get("diagnostics", true))
	
	# Validation
	if script_path.is_empty():
		return _send_error(client_id, "Script path cannot be empty", command_id)
	
	if content.is_empty():
		return _send_error(client_id, "Content cannot be empty", command_id)
	
	# Make sure we have an absolute path
	if not script_path.begins_with("res://"):
		script_path = "res://" + script_path
	
	# Try to find the script if not found directly
	if not FileAccess.file_exists(script_path):
		var found_path = _find_script_file(script_path)
		if not found_path.is_empty():
			script_path = found_path
		else:
			return _send_error(client_id, "Script file not found: %s" % script_path, command_id)
	
	# Edit the script file
	var file = FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return _send_error(client_id, "Failed to open script file: %s" % script_path, command_id)
	
	file.store_string(content)
	file = null  # Close the file
	
	var result := {
		"script_path": script_path
	}
	if diagnostics and script_path.ends_with(".gd"):
		result["diagnostics"] = await _diagnose_script(script_path)
	
	_send_success(client_id, result, command_id)

func _get_script(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path = params.get("script_path", "")
	var node_path = params.get("node_path", "")
	
	# Validation - either script_path or node_path must be provided
	if script_path.is_empty() and node_path.is_empty():
		return _send_error(client_id, "Either script_path or node_path must be provided", command_id)
	
	# If node_path is provided, get the script from the node
	if not node_path.is_empty():
		var node = _get_editor_node(node_path)
		if not node:
			# Try enhanced node resolution
			node = _get_editor_node_enhanced(node_path)
			if not node:
				return _send_error(client_id, "Node not found: %s" % node_path, command_id)
		
		var script = node.get_script()
		if not script:
			return _send_error(client_id, "Node does not have a script: %s" % node_path, command_id)
		
		# Handle various script types safely
		if typeof(script) == TYPE_OBJECT and "resource_path" in script:
			script_path = script.resource_path
		elif typeof(script) == TYPE_STRING:
			script_path = script
		else:
			# Try to handle other script types gracefully
			print("Script type is not directly supported: ", typeof(script))
			if script.has_method("get_path"):
				script_path = script.get_path()
			elif script.has_method("get_source_code"):
				# Return the script content directly
				_send_success(client_id, {
					"script_path": node_path + " (embedded script)",
					"content": script.get_source_code()
				}, command_id)
				return
			else:
				return _send_error(client_id, "Cannot extract script path from node: %s" % node_path, command_id)
	
	# Try to find the script if it's not found directly
	if not FileAccess.file_exists(script_path):
		var found_path = _find_script_file(script_path)
		if not found_path.is_empty():
			script_path = found_path
		else:
			return _send_error(client_id, "Script file not found: %s" % script_path, command_id)
	
	# Read the script file
	var file = FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return _send_error(client_id, "Failed to open script file: %s" % script_path, command_id)
	
	var content = file.get_as_text()
	file = null  # Close the file
	
	_send_success(client_id, {
		"script_path": script_path,
		"content": content
	}, command_id)

func _get_script_metadata(client_id: int, params: Dictionary, command_id: String) -> void:
	var path = params.get("path", "")
	
	# Validation
	if path.is_empty():
		return _send_error(client_id, "Script path cannot be empty", command_id)
	
	if not path.begins_with("res://"):
		path = "res://" + path
	
	# Try to find the script if it's not found directly
	if not FileAccess.file_exists(path):
		var found_path = _find_script_file(path)
		if not found_path.is_empty():
			path = found_path
		else:
			return _send_error(client_id, "Script file not found: " + path, command_id)
	
	# Load the script
	var script = load(path)
	if not script:
		return _send_error(client_id, "Failed to load script: " + path, command_id)
	
	# Extract script metadata
	var metadata = {
		"path": path,
		"language": "gdscript" if path.ends_with(".gd") else "csharp" if path.ends_with(".cs") else "unknown"
	}
	
	# Attempt to get script class info
	var class_name_str = ""
	var extends_class = ""
	
	# Read the file to extract class_name and extends info
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var content = file.get_as_text()
		
		# Extract class_name
		var result = _class_name_regex.search(content)
		if result:
			class_name_str = result.get_string(1)
		
		# Extract extends
		result = _extends_regex.search(content)
		if result:
			extends_class = result.get_string(1)
		
		# Add to metadata
		metadata["class_name"] = class_name_str
		metadata["extends"] = extends_class
		
		# Try to extract methods and signals
		var methods = []
		var signals = []
		
		var method_matches = _method_regex.search_all(content)
		
		for match_result in method_matches:
			methods.append(match_result.get_string(1))
		
		var signal_matches = _signal_regex.search_all(content)
		
		for match_result in signal_matches:
			signals.append(match_result.get_string(1))
		
		metadata["methods"] = methods
		metadata["signals"] = signals
	
	_send_success(client_id, metadata, command_id)

# Runs script diagnostics after a successful write so the agent immediately
# sees parse errors. The validation processor is loaded by path instead of
# referencing its class_name directly: the global class cache only knows
# MCPValidationCommands after the editor rescans the filesystem, so a
# parse-time class reference would break this file in fresh checkouts or
# headless runs. Loading by path has no parse-time dependency.
#
# Coroutine: the subprocess-based diagnostics path awaits a worker thread,
# so callers must await this function.
func _diagnose_script(script_path: String) -> Dictionary:
	if _validation_commands == null:
		var validation_commands_script = load("res://addons/godot_mcp/commands/validation_commands.gd")
		if validation_commands_script == null:
			return {"error": "Failed to load validation commands module"}
		var validation_commands = validation_commands_script.new()
		if validation_commands == null or not validation_commands.has_method("diagnose_script"):
			if validation_commands:
				validation_commands.free()
			return {"error": "Validation commands module does not provide diagnose_script"}
		_validation_commands = validation_commands
		# The cached instance is a Node that is not part of the scene tree by
		# default, but its awaited diagnose_script coroutine needs get_tree()
		# for the worker wait loop. Add it under this processor, which is
		# itself in the editor tree; _exit_tree() keeps freeing it.
		add_child(_validation_commands)
	return await _validation_commands.diagnose_script(script_path)


func _get_current_script(client_id: int, params: Dictionary, command_id: String) -> void:
	# Get editor plugin and interfaces
	var plugin = Engine.get_meta("GodotMCPPlugin")
	if not plugin:
		return _send_error(client_id, "GodotMCPPlugin not found in Engine metadata", command_id)
	
	var editor_interface = plugin.get_editor_interface()
	var script_editor = editor_interface.get_script_editor()
	var current_script = script_editor.get_current_script()
	
	if not current_script:
		return _send_success(client_id, {
			"script_found": false,
			"message": "No script is currently being edited"
		}, command_id)
	
	var script_path = current_script.resource_path
	
	# Read the script content
	var file = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return _send_error(client_id, "Failed to open script file: %s" % script_path, command_id)
	
	var content = file.get_as_text()
	file = null  # Close the file
	
	_send_success(client_id, {
		"script_found": true,
		"script_path": script_path,
		"content": content
	}, command_id)
