@tool
class_name MCPValidationCommands
extends MCPBaseCommandProcessor

# Command processor for script diagnostics and scene validation.
#
# Godot 4.5 does not expose a public API for retrieving parse diagnostics
# (no Script.get_script_error_count / get_script_errors / errors property).
# Verified empirically against 4.5.1: the only signals are the return value of
# Script.reload() (ERR_PARSE_ERROR) and the "SCRIPT ERROR: Parse Error: ..."
# lines printed to stderr by the engine.
#
# Strategy used here:
#   1. Fast path: parse the file content in-process with a fresh GDScript
#      resource. If reload() returns OK the script is valid and no further
#      work is needed.
#   2. Message path: when the in-process parse fails, run a headless child
#      Godot process with --check-only against the script and capture its
#      stderr via OS.execute(read_stderr = true). The captured
#      "SCRIPT ERROR: Parse Error: <message>" blocks (with their
#      "at: ... (path:line)" location lines) give real error messages and
#      line numbers that are not available in-process.
#
# This processor is synchronous: process_command never awaits, matching the
# command handler's expectations for non-debugger processors.

func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"get_script_diagnostics":
			_get_script_diagnostics(client_id, params, command_id)
			return true
		"validate_scene":
			_validate_scene(client_id, params, command_id)
			return true
	return false  # Command not handled


func _get_script_diagnostics(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path: String = params.get("script_path", "")
	if script_path.is_empty():
		return _send_error(client_id, "Script path cannot be empty", command_id)

	var result := diagnose_script(script_path)
	_send_success(client_id, result, command_id)


func _validate_scene(client_id: int, params: Dictionary, command_id: String) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		return _send_error(client_id, "Scene path cannot be empty", command_id)

	var result := validate_scene(scene_path)
	_send_success(client_id, result, command_id)


# Parses a GDScript file and returns its compile/parse diagnostics.
# Result shape:
#   {
#     "script_path": String,   # normalized res:// path
#     "exists": bool,
#     "valid": bool,           # true when the script parses without errors
#     "error_count": int,
#     "errors": [ {"line": int, "column": int, "message": String} ]
#   }
# Warnings are intentionally omitted: Godot 4.5 exposes no warning API and
# --check-only does not print warnings either.
func diagnose_script(script_path: String) -> Dictionary:
	var normalized := _normalize_script_path(script_path)
	if normalized.is_empty():
		return _build_diagnostics_result(normalized, false, false, [
			{"line": 0, "column": 0, "message": "Script path cannot be empty"}
		])

	if normalized.ends_with(".cs"):
		return _build_diagnostics_result(normalized, true, false, [
			{"line": 0, "column": 0, "message": "Diagnostics are only supported for GDScript (.gd) files"}
		])

	if not FileAccess.file_exists(normalized):
		return _build_diagnostics_result(normalized, false, false, [
			{"line": 0, "column": 0, "message": "Script file not found: %s" % normalized}
		])

	var file := FileAccess.open(normalized, FileAccess.READ)
	if file == null:
		return _build_diagnostics_result(normalized, true, false, [
			{"line": 0, "column": 0, "message": "Failed to open script file for reading: %s" % normalized}
		])
	var content := file.get_as_text()
	file = null  # Close the file

	var script := GDScript.new()
	script.source_code = content

	# Suppress the engine's own parse-error output while reloading so broken
	# scripts do not spam the editor output panel on every diagnostics run.
	var was_printing_errors := Engine.is_printing_error_messages()
	Engine.set_print_error_messages(false)
	var reload_error: int = script.reload()
	Engine.set_print_error_messages(was_printing_errors)

	if reload_error == OK:
		return _build_diagnostics_result(normalized, true, true, [])

	# The in-process parse failed. Spawn a headless child parser to recover
	# the actual error messages and line numbers.
	var errors := _run_parser_subprocess(normalized)
	if errors.is_empty():
		errors = [{
			"line": 0,
			"column": 0,
			"message": "Script failed to parse (error code %d)" % reload_error
		}]
	return _build_diagnostics_result(normalized, true, false, errors)


# Loads a .tscn file and checks its structural health.
# Result shape:
#   {
#     "scene_path": String,   # normalized res:// path
#     "valid": bool,          # true when there are no error-severity issues
#     "issue_count": int,
#     "issues": [ {"severity": "error"|"warning", "category": String,
#                  "message": String, "node_path": String (optional)} ]
#   }
# Categories: "load", "instantiate", "duplicate_name", "missing_resource",
# "cyclic_dependency".
func validate_scene(scene_path: String) -> Dictionary:
	var normalized := scene_path.strip_edges()
	if normalized.is_empty():
		return _build_scene_result(normalized, false, [{
			"severity": "error",
			"category": "load",
			"message": "Scene path cannot be empty"
		}])

	if not normalized.begins_with("res://"):
		normalized = "res://" + normalized

	if not FileAccess.file_exists(normalized):
		return _build_scene_result(normalized, false, [{
			"severity": "error",
			"category": "load",
			"message": "Scene file not found: %s" % normalized
		}])

	var issues: Array = []

	# Load with a fresh cache read so the file on disk is validated, not a
	# previously cached version of it.
	var packed_scene = ResourceLoader.load(normalized, "", ResourceLoader.CACHE_MODE_IGNORE)
	if packed_scene == null:
		issues.append({
			"severity": "error",
			"category": "load",
			"message": "Failed to load scene: %s" % normalized
		})
		return _build_scene_result(normalized, false, issues)

	if not packed_scene is PackedScene:
		issues.append({
			"severity": "error",
			"category": "load",
			"message": "Resource is not a PackedScene: %s" % normalized
		})
		return _build_scene_result(normalized, false, issues)

	var scene_instance = packed_scene.instantiate()
	if scene_instance == null:
		issues.append({
			"severity": "error",
			"category": "instantiate",
			"message": "Failed to instantiate scene: %s" % normalized
		})
	else:
		# Note: instantiate() may silently drop duplicate-named siblings
		# depending on resource cache state, so duplicate detection runs on
		# the scene state (which always preserves every node) instead of on
		# the instantiated tree.
		scene_instance.queue_free()

	var scene_state: SceneState = packed_scene.get_state()
	_check_duplicate_names(scene_state, issues)
	_check_missing_scripts(scene_state, issues)
	_check_missing_resources(normalized, issues)
	_check_cyclic_dependencies(normalized, issues)

	return _build_scene_result(normalized, _has_no_errors(issues), issues)


func _normalize_script_path(script_path: String) -> String:
	var normalized := script_path.strip_edges()
	if normalized.is_empty():
		return normalized
	if not normalized.begins_with("res://"):
		normalized = "res://" + normalized
	if not normalized.ends_with(".gd") and not normalized.ends_with(".cs"):
		normalized += ".gd"
	return normalized


func _build_diagnostics_result(script_path: String, exists: bool, valid: bool, errors: Array) -> Dictionary:
	return {
		"script_path": script_path,
		"exists": exists,
		"valid": valid,
		"error_count": errors.size(),
		"errors": errors
	}


func _build_scene_result(scene_path: String, valid: bool, issues: Array) -> Dictionary:
	return {
		"scene_path": scene_path,
		"valid": valid,
		"issue_count": issues.size(),
		"issues": issues
	}


func _has_no_errors(issues: Array) -> bool:
	for issue in issues:
		if issue.get("severity", "") == "error":
			return false
	return true


# Runs a headless child Godot process with --check-only against the given
# script and extracts the "SCRIPT ERROR: Parse Error: ..." blocks (message +
# line number) from the captured output. Returns an Array of
# {line, column, message} dictionaries. Column is not reported by the engine,
# so it is always 0. Returns an empty Array when the child reports success.
func _run_parser_subprocess(script_path: String) -> Array:
	var executable := OS.get_executable_path()
	var project_dir := ProjectSettings.globalize_path("res://")

	var output: Array[String] = []
	var exit_code := OS.execute(executable, PackedStringArray([
		"--headless",
		"--path", project_dir,
		"--check-only",
		"--script", script_path,
	]), output, true)

	if exit_code == 0:
		# The clean child process parsed the script successfully, which means
		# the in-process failure came from stale editor state.
		return []

	var message_regex := RegEx.new()
	message_regex.compile("^SCRIPT ERROR: Parse Error: (.*)$")
	var location_regex := RegEx.new()
	location_regex.compile("^\\s*at:\\s+\\S+\\s+\\((.+?):(\\d+)\\)$")

	# OS.execute appends the whole captured output as a single string with
	# embedded newlines, so split it into lines (and strip Windows carriage
	# returns) before matching.
	var lines: Array = []
	for chunk in output:
		for raw_line in String(chunk).split("\n"):
			lines.append(raw_line.trim_suffix("\r"))

	var errors: Array = []
	for i in lines.size():
		var message_match := message_regex.search(lines[i])
		if message_match == null:
			continue
		var error_entry := {
			"line": 0,
			"column": 0,
			"message": message_match.get_string(1).strip_edges()
		}
		# The location line ("at: ... (res://path.gd:LINE)") directly follows
		# the message line; scan a few lines forward to find it.
		for j in range(i + 1, mini(i + 4, lines.size())):
			var location_match := location_regex.search(lines[j])
			if location_match != null:
				error_entry["line"] = int(location_match.get_string(2))
				break
		errors.append(error_entry)

	return errors


# Reports duplicate node names within the same parent. Godot 4 allows them,
# so these are warnings: get_node() only resolves the first match. Detection
# runs on the packed scene state because instantiate() may silently drop
# duplicate-named siblings depending on resource cache state.
func _check_duplicate_names(state: SceneState, issues: Array) -> void:
	var names_by_parent := {}
	for i in state.get_node_count():
		var node_path := str(state.get_node_path(i))
		if node_path == ".":
			continue  # The root node has no parent.
		var separator := node_path.rfind("/")
		var parent_path := node_path.substr(0, separator) if separator != -1 else "."
		var node_name := String(state.get_node_name(i))
		if not names_by_parent.has(parent_path):
			names_by_parent[parent_path] = {}
		var siblings: Dictionary = names_by_parent[parent_path]
		if node_name in siblings:
			issues.append({
				"severity": "warning",
				"category": "duplicate_name",
				"message": "Duplicate node name '%s' under parent '%s'" % [node_name, parent_path],
				"node_path": parent_path
			})
		else:
			siblings[node_name] = true


# Reports nodes whose packed scene state declares a script property that
# resolved to nothing (the referenced script file no longer exists). Missing
# scripts inside instanced sub-scenes are not visible in the parent state and
# are covered by the dependency scan instead.
func _check_missing_scripts(state: SceneState, issues: Array) -> void:
	for i in state.get_node_count():
		var node_path := str(state.get_node_path(i))
		for j in state.get_node_property_count(i):
			var property_name := String(state.get_node_property_name(i, j))
			if property_name != "script":
				continue
			var value = state.get_node_property_value(i, j)
			if value == null or value is MissingResource:
				issues.append({
					"severity": "error",
					"category": "missing_resource",
					"message": "Node has a missing script (the referenced script file could not be loaded)",
					"node_path": node_path
				})
			break


# Reports external resources referenced by the scene that no longer exist on
# disk. Note: get_dependencies() returns an empty array for scenes whose
# scripts fail to parse, which is handled gracefully. Dependency entries may
# be uid-prefixed (a uid:// reference glued to the path with "::::", or a bare
# uid:// reference); those forms are resolved before the existence check.
func _check_missing_resources(scene_path: String, issues: Array) -> void:
	var dependencies := ResourceLoader.get_dependencies(scene_path)
	for dependency in dependencies:
		if not _resource_exists(dependency):
			issues.append({
				"severity": "error",
				"category": "missing_resource",
				"message": "Missing external resource: %s" % dependency
			})


# Resolves a single dependency entry from ResourceLoader.get_dependencies()
# into a form that can be checked for existence. Strips a uid:// prefix glued
# to the real path with "::::", checks res:// and user:// paths directly,
# resolves bare uid:// references through the UID database, and returns true
# for any other form (cannot be verified, so valid scenes are never
# false-positived).
func _resource_exists(dependency: String) -> bool:
	var cleaned := dependency
	var separator := cleaned.rfind("::::")
	if separator != -1:
		cleaned = cleaned.substr(separator + 4)
	if cleaned.begins_with("res://") or cleaned.begins_with("user://"):
		return FileAccess.file_exists(cleaned)
	if cleaned.begins_with("uid://"):
		var id := ResourceUID.text_to_id(cleaned)
		return ResourceUID.has_id(id)
	return true


# Detects cyclic scene instantiation by walking ResourceLoader.get_dependencies
# depth-first with a visited set and a recursion stack. Godot 4.5's text scene
# parser rejects cycles (the referencing edge is dropped with a parse error),
# so a cycle is a genuine structural error.
func _check_cyclic_dependencies(scene_path: String, issues: Array) -> void:
	var visited := {}
	var stack: Array = []
	_check_cycle_from(scene_path, visited, stack, issues)


func _check_cycle_from(path: String, visited: Dictionary, stack: Array, issues: Array) -> void:
	if path in stack:
		var cycle_start := stack.find(path)
		var cycle := stack.slice(cycle_start)
		cycle.append(path)
		issues.append({
			"severity": "error",
			"category": "cyclic_dependency",
			"message": "Cyclic scene dependency detected: %s" % " -> ".join(cycle)
		})
		return

	if path in visited:
		return

	visited[path] = true
	stack.append(path)

	var dependencies := ResourceLoader.get_dependencies(path)
	for dependency in dependencies:
		var clean := str(dependency)
		var sep := clean.rfind("::::")
		if sep != -1:
			clean = clean.substr(sep + 4)
		if clean.ends_with(".tscn"):
			_check_cycle_from(clean, visited, stack, issues)

	stack.pop_back()
