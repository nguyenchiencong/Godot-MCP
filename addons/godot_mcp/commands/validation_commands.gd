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
# The subprocess runs on a dedicated worker thread (a plain Thread, not
# WorkerThreadPool: a hung child can only leak its own thread, whereas a hung
# WorkerThreadPool task would permanently consume one of the shared pool
# slots and cannot be abandoned). The editor main thread awaits the thread's
# non-blocking is_alive() liveness check on process frames instead of
# blocking, so diagnostics commands are coroutines and the command handler
# awaits this processor. A pathological child can leave that command
# coroutine pending, but the editor main thread stays responsive; this is
# safer than abandoning a live Thread object.

# Engine-metadata key for the shared subprocess diagnostics cache. GDScript
# has no static class variables, so the cache lives process-wide in Engine
# metadata (same pattern as the regex cache).
const SUBPROCESS_CACHE_META_KEY := "GodotMCPDiagnosticsSubprocessCache"

# Cache of headless-subprocess diagnostic results keyed by
# "path|content_digest". A hit avoids both the in-process parse (GDScript
# reload) and re-spawning a headless Godot process for identical known-broken
# content. Only known-invalid diagnostics are ever stored, so a hit always
# means the script is invalid. Shared process-wide across explicit and auto
# diagnostics. Cache reads and writes stay on the main thread, so no locking
# needed.
var _subprocess_cache: Dictionary
var _active_parser_threads: Array[Thread] = []

func _init() -> void:
	# Reuse the shared process-wide cache when it already exists, otherwise
	# create it and publish it in Engine metadata for other instances.
	if Engine.has_meta(SUBPROCESS_CACHE_META_KEY):
		_subprocess_cache = Engine.get_meta(SUBPROCESS_CACHE_META_KEY)
	else:
		_subprocess_cache = {}
		Engine.set_meta(SUBPROCESS_CACHE_META_KEY, _subprocess_cache)


func _exit_tree() -> void:
	# A suspended diagnostics coroutine may never receive another process_frame
	# during plugin teardown. Join every successfully started worker here so no
	# Thread reaches destruction while still owning native thread resources.
	for worker in _active_parser_threads.duplicate():
		_reap_parser_thread(worker)
	_active_parser_threads.clear()


func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"get_script_diagnostics":
			await _get_script_diagnostics(client_id, params, command_id)
			return true
		"validate_scene":
			_validate_scene(client_id, params, command_id)
			return true
	return false  # Command not handled


func _get_script_diagnostics(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path: String = params.get("script_path", "")
	if script_path.is_empty():
		return _send_error(client_id, "Script path cannot be empty", command_id)

	var result := await diagnose_script(script_path)
	_send_success(client_id, result, command_id)


func _validate_scene(client_id: int, params: Dictionary, command_id: String) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		return _send_error(client_id, "Scene path cannot be empty", command_id)

	var check_instantiate: bool = params.get("check_instantiate", true)
	var result := validate_scene(scene_path, check_instantiate)
	_send_success(client_id, result, command_id)


# Parses a GDScript file and returns its compile/parse diagnostics.
# Coroutine: callers must await it. The fast paths (empty path, .cs file,
# missing file, cache hit, valid parse) never reach an await and therefore
# still resolve synchronously; only the broken-script subprocess path
# suspends while the worker thread runs.
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

	# Check the shared cache before any parsing work: diagnostics for
	# identical known-broken content are reused without re-running the
	# in-process parse or the headless subprocess. The cache only stores
	# known-invalid diagnostics, so a hit means the script is invalid.
	var cache_key := "%s|%s" % [normalized, content.md5_text()]
	if _subprocess_cache.has(cache_key):
		return _build_diagnostics_result(normalized, true, false, _subprocess_cache[cache_key])

	var script := GDScript.new()
	script.source_code = content

	# Suppress the engine's own parse-error output while reloading so broken
	# scripts do not spam the editor output panel on every diagnostics run.
	var was_printing_errors := Engine.is_printing_error_messages()
	Engine.set_print_error_messages(false)
	var reload_error: int = script.reload()
	Engine.set_print_error_messages(was_printing_errors)

	if reload_error == OK:
		# Valid results are not cached; the cache only stores known-invalid
		# diagnostics.
		return _build_diagnostics_result(normalized, true, true, [])

	# The in-process parse failed. Spawn a headless child parser on a worker
	# thread to recover the actual error messages and line numbers. The cache
	# was already checked above, so there is no second lookup here.
	var errors: Array = await _run_parser_subprocess_async(normalized)
	if errors.is_empty():
		errors = [{
			"line": 0,
			"column": 0,
			"message": "Script failed to parse (error code %d)" % reload_error
		}]
	# Cache the final (non-empty) errors array. Bound the cache: broken edits
	# produce unique keys (path|content_digest) without bound across a long
	# session, so once it reaches 64 entries drop everything. A cached file
	# that gets evicted simply re-runs the subprocess once on its next
	# diagnostic, which keeps the common unchanged-file case fast without
	# unbounded growth.
	if _subprocess_cache.size() >= 64:
		_subprocess_cache.clear()
	_subprocess_cache[cache_key] = errors
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
# check_instantiate=false skips the packed_scene.instantiate() tree-build check
# (callers that only care about load/dependency health can opt out).
func validate_scene(scene_path: String, check_instantiate: bool = true) -> Dictionary:
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

	if check_instantiate:
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

	# The root dependency list is computed once and shared by both checks.
	var dependencies := ResourceLoader.get_dependencies(normalized)
	var scene_state: SceneState = packed_scene.get_state()
	_check_duplicate_names(scene_state, issues)
	_check_missing_scripts(scene_state, issues)
	_check_missing_resources(dependencies, issues)
	_check_cyclic_dependencies(normalized, dependencies, issues)

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


# Starts a worker thread that runs the headless child parser (OS.execute +
# stderr parsing, data-only) and waits for it without blocking the main
# thread. Returns the parsed errors Array (empty when the child reported
# success or when the thread failed to start; the caller maps both to the
# generic parse-error entry). The main thread never reads the holder while
# the worker writes it: it polls Thread's thread-safe is_alive() and only
# reads holder["errors"] after the thread has finished.
func _run_parser_subprocess_async(script_path: String) -> Array:
	var holder := {"errors": []}
	var project_dir := ProjectSettings.globalize_path("res://")
	var worker := Thread.new()
	var start_error := worker.start(_run_parser_subprocess_worker.bind(script_path, project_dir, holder))
	if start_error != OK:
		return []
	_active_parser_threads.append(worker)

	while worker.is_alive():
		# If teardown detached this processor before _exit_tree could reap the
		# worker, take the safe synchronous path rather than awaiting a signal
		# from a tree this node no longer belongs to.
		if not is_inside_tree():
			_reap_parser_thread(worker)
			break
		await get_tree().process_frame

	# Normal completion owns the join only while the worker remains tracked.
	# _exit_tree may already have joined and removed it while this coroutine
	# was suspended, in which case the holder is complete and can be read.
	_reap_parser_thread(worker)
	return holder.get("errors", [])


func _reap_parser_thread(worker: Thread) -> void:
	if not _active_parser_threads.has(worker):
		return
	if worker.is_started():
		worker.wait_to_finish()
	_active_parser_threads.erase(worker)


# Runs entirely on the worker thread. Data-only operations only: no scene
# tree access, no Engine metadata, no signals, no await. The regexes are
# compiled locally so the worker shares no mutable state with the main
# thread. Runs a headless child Godot process with --check-only against the
# given script and extracts the "SCRIPT ERROR: Parse Error: ..." blocks
# (message + line number) from the captured output. Returns an Array of
# {line, column, message} dictionaries. Column is not reported by the engine,
# so it is always 0. An empty Array means the child reported success.
static func _run_parser_subprocess_worker(script_path: String, project_dir: String, holder: Dictionary) -> void:
	var error_regex := RegEx.new()
	error_regex.compile("^SCRIPT ERROR: Parse Error: (.*)$")
	var location_regex := RegEx.new()
	location_regex.compile("^\\s*at:\\s+\\S+\\s+\\((.+?):(\\d+)\\)$")

	var executable := OS.get_executable_path()
	var output: Array[String] = []
	var exit_code := OS.execute(executable, PackedStringArray([
		"--headless",
		"--path", project_dir,
		"--check-only",
		"--script", script_path,
	]), output, true)

	var errors: Array = []
	# The clean child process parsed the script successfully, which means
	# the in-process failure came from stale editor state.
	if exit_code != 0:
		# OS.execute appends the whole captured output as a single string with
		# embedded newlines, so split it into lines (and strip Windows carriage
		# returns) before matching.
		var lines: Array = []
		for chunk in output:
			for raw_line in String(chunk).split("\n"):
				lines.append(raw_line.trim_suffix("\r"))

		for i in lines.size():
			var message_match := error_regex.search(lines[i])
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

	# Order matters: the errors array is fully written before the thread
	# finishes; the main thread only reads the holder after is_alive()
	# reports the thread has finished, so the writes are visible.
	holder["errors"] = errors


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
func _check_missing_resources(dependencies: Array, issues: Array) -> void:
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
func _check_cyclic_dependencies(scene_path: String, dependencies: Array, issues: Array) -> void:
	var visited := {}
	var stack: Array = [scene_path]
	visited[scene_path] = true
	for dependency in dependencies:
		var clean := str(dependency)
		var sep := clean.rfind("::::")
		if sep != -1:
			clean = clean.substr(sep + 4)
		if clean.ends_with(".tscn"):
			_check_cycle_from(clean, visited, stack, issues)
	stack.pop_back()


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
