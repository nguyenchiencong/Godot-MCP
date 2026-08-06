@tool
class_name MCPShaderCommands
extends MCPBaseCommandProcessor

# Shader authoring commands: create/edit/get .gdshader files plus a fallback
# tool that reads captured shader compile errors.
#
# Compile diagnostics come from the engine itself: the plugin installs a
# custom Logger (MCPShaderErrorLogger) that captures Logger.ERROR_TYPE_SHADER
# entries into a thread-safe buffer. After writing a file, this processor
# forces the editor to reload and recompile the shader (ResourceLoader load
# with CACHE_MODE_REPLACE plus Shader.get_rid(), which triggers the lazy
# compile inside RenderingServer), then reads entries from a marker recorded
# before the write and path-filters attributed diagnostics.

const SHADER_TYPE_REGEX_SOURCE := "shader_type\\s+([a-zA-Z_][a-zA-Z0-9_]*)"

# Minimal valid templates per shader type, used when create_shader is called
# without explicit content.
const SHADER_TEMPLATES := {
	"canvas_item": "shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR = vec4(1.0, 1.0, 1.0, 1.0);\n}\n",
	"spatial": "shader_type spatial;\n\nvoid fragment() {\n\tALBEDO = vec3(1.0, 1.0, 1.0);\n}\n",
	"particles": "shader_type particles;\n\nvoid process() {\n\t// Particle process body.\n}\n",
	"sky": "shader_type sky;\n\nvoid sky() {\n\tCOLOR = vec3(0.5, 0.6, 0.7);\n}\n",
	"fog": "shader_type fog;\n\nvoid fog() {\n\t// Fog body.\n}\n",
}

const VALID_SHADER_TYPES := ["canvas_item", "spatial", "particles", "sky", "fog"]

# Frames to wait after a forced recompile before draining the error buffer.
# Parse errors are synchronous, but driver-level compile errors can surface a
# frame or two later, so a short wait keeps diagnostics complete.
const RECOMPILE_WAIT_FRAMES := 2

# Runtime (running-game) shader tools. The game replies over the debugger
# message capture "mcp_shader" (owned by MCPRuntimeDebuggerBridge); requests
# are correlated by id and polled with the bridge's timeout convention
# (DEFAULT_TIMEOUT_MS is 800).
const DEFAULT_RUNTIME_TIMEOUT_MS := 800
const MAX_RUNTIME_TIMEOUT_MS := 60000
const MAX_COMPILE_ERROR_WAIT_MS := 10000

# Fixed internal poll timeouts for runtime tools without a user wait knob:
# snapshot is a read-only walk, hot reload applies code then waits a few
# frames for compile feedback, capture waits one frame plus PNG encode.
const SNAPSHOT_TIMEOUT_MS := 3000
const HOT_RELOAD_TIMEOUT_MS := 5000
const CAPTURE_DEFAULT_TIMEOUT_MS := 3000

# Debug-draw overlay modes accepted by shader_debug_overlay; the game side
# validates them again before applying.
const DEBUG_OVERLAY_MODES := ["wireframe", "normal", "off"]

var _shader_type_regex := RegEx.new()
var _diagnostic_collection_active := false

func _init() -> void:
	_shader_type_regex.compile(SHADER_TYPE_REGEX_SOURCE)

func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"create_shader":
			await _create_shader(client_id, params, command_id)
			return true
		"edit_shader":
			await _edit_shader(client_id, params, command_id)
			return true
		"get_shader":
			_get_shader(client_id, params, command_id)
			return true
		"shader_get_compile_errors":
			await _get_compile_errors(client_id, params, command_id)
			return true
		"shader_list_materials":
			await _shader_list_materials(client_id, params, command_id)
			return true
		"shader_get_uniforms":
			await _shader_get_uniforms(client_id, params, command_id)
			return true
		"shader_set_uniform":
			await _shader_set_uniform(client_id, params, command_id)
			return true
		"shader_debug_snapshot":
			await _shader_debug_snapshot(client_id, params, command_id)
			return true
		"shader_hot_reload":
			await _shader_hot_reload(client_id, params, command_id)
			return true
		"shader_debug_overlay":
			await _shader_debug_overlay(client_id, params, command_id)
			return true
		"capture_running_game":
			await _capture_running_game(client_id, params, command_id)
			return true
	return false  # Command not handled

func _create_shader(client_id: int, params: Dictionary, command_id: String) -> void:
	var shader_path := params.get("script_path", "")
	var shader_type := params.get("shader_type", "")
	var has_explicit_content := params.has("content")
	var content := str(params.get("content", ""))

	if shader_path.is_empty():
		return _send_error(client_id, "Shader path cannot be empty", command_id)

	shader_path = _normalize_shader_path(shader_path)
	if shader_path.is_empty():
		return _send_error(client_id, "Invalid shader path: '..' path segments are not allowed (paths must stay inside res://)", command_id)

	if FileAccess.file_exists(shader_path):
		return _send_error(client_id, "Shader file already exists: %s" % shader_path, command_id)

	if not has_explicit_content:
		if not SHADER_TEMPLATES.has(shader_type):
			return _send_error(client_id, "Unknown shader_type '%s'; expected one of: %s" % [shader_type, ", ".join(VALID_SHADER_TYPES)], command_id)
		content = SHADER_TEMPLATES[shader_type]

	var write_error := _write_shader_file(shader_path, content)
	if not write_error.is_empty():
		return _send_error(client_id, write_error, command_id)

	var diagnostics := await _collect_shader_diagnostics(shader_path)

	# When explicit content declares a different shader_type than requested,
	# the write still succeeds but the mismatch is surfaced as a warning.
	if not shader_type.is_empty():
		var declared_type := _declared_shader_type(content)
		if not declared_type.is_empty() and declared_type != shader_type:
			diagnostics.append({
				"line": 0,
				"message": "Declared shader_type '%s' differs from requested type '%s'" % [declared_type, shader_type],
				"severity": "warning"
			})

	_send_success(client_id, {
		"success": true,
		"path": shader_path,
		"diagnostics": diagnostics
	}, command_id)

func _edit_shader(client_id: int, params: Dictionary, command_id: String) -> void:
	var shader_path := params.get("script_path", "")
	var content := params.get("content", "")

	if shader_path.is_empty():
		return _send_error(client_id, "Shader path cannot be empty", command_id)

	shader_path = _normalize_shader_path(shader_path)
	if shader_path.is_empty():
		return _send_error(client_id, "Invalid shader path: '..' path segments are not allowed (paths must stay inside res://)", command_id)

	if not FileAccess.file_exists(shader_path):
		return _send_error(client_id, "Shader file not found: %s" % shader_path, command_id)

	# Warn when the edit changes the shader_type of the existing file: the
	# write still succeeds, but materials using it may need attention.
	var previous_type := _declared_shader_type(_read_shader_file(shader_path))
	var new_type := _declared_shader_type(content)

	var write_error := _write_shader_file(shader_path, content)
	if not write_error.is_empty():
		return _send_error(client_id, write_error, command_id)

	var diagnostics := await _collect_shader_diagnostics(shader_path)

	if not previous_type.is_empty() and not new_type.is_empty() and previous_type != new_type:
		diagnostics.append({
			"line": 0,
			"message": "shader_type changed from '%s' to '%s'" % [previous_type, new_type],
			"severity": "warning"
		})

	_send_success(client_id, {
		"success": true,
		"path": shader_path,
		"diagnostics": diagnostics
	}, command_id)

func _get_shader(client_id: int, params: Dictionary, command_id: String) -> void:
	var shader_path := params.get("script_path", "")

	if shader_path.is_empty():
		return _send_error(client_id, "Shader path cannot be empty", command_id)

	shader_path = _normalize_shader_path(shader_path)
	if shader_path.is_empty():
		return _send_error(client_id, "Invalid shader path: '..' path segments are not allowed (paths must stay inside res://)", command_id)

	if not FileAccess.file_exists(shader_path):
		return _send_error(client_id, "Shader file not found: %s" % shader_path, command_id)

	var content := _read_shader_file(shader_path)

	_send_success(client_id, {
		"success": true,
		"path": shader_path,
		"content": content
	}, command_id)

# Fallback read tool: returns shader compile errors retained by the bounded
# logger buffer, optionally waiting wait_ms before reading and optionally
# filtering by script_path.
func _get_compile_errors(client_id: int, params: Dictionary, command_id: String) -> void:
	var script_path := str(params.get("script_path", ""))
	var wait_ms := clampi(int(params.get("wait_ms", 0)), 0, MAX_COMPILE_ERROR_WAIT_MS)

	if not script_path.is_empty():
		script_path = _normalize_shader_path(script_path)
		if script_path.is_empty():
			return _send_error(client_id, "Invalid shader path: '..' path segments are not allowed (paths must stay inside res://)", command_id)

	if wait_ms > 0:
		await get_tree().create_timer(float(wait_ms) / 1000.0).timeout

	var logger = _get_shader_logger()
	if logger == null:
		return _send_success(client_id, {
			"success": true,
			"diagnostics": []
		}, command_id)

	var entries = logger.drain_since(0)
	var diagnostics := _entries_to_diagnostics(entries, script_path)

	_send_success(client_id, {
		"success": true,
		"diagnostics": diagnostics
	}, command_id)

# Writes content to shader_path and returns the diagnostics produced by the
# editor's recompile of that file (empty when the shader compiled cleanly).
# Coroutine: waits a couple of frames for driver-level compile errors.
# Results are scoped to shader_path: entries attributed to a different file
# (editor rescan recompiling another shader in the same window) are excluded,
# while entries without a file (GL Compatibility quirk) still pass through.
func _collect_shader_diagnostics(shader_path: String) -> Array:
	var logger = _get_shader_logger()
	if logger == null:
		return []

	# Commands can overlap while this coroutine waits for rendering frames.
	# Serialize forced recompiles so a second edit cannot add unattributed
	# GL Compatibility errors inside the first edit's marker window.
	while _diagnostic_collection_active:
		if get_tree() == null:
			return []
		await get_tree().process_frame
	_diagnostic_collection_active = true

	var marker = logger.record_marker()

	# Force a fresh load from disk and a recompile. Empirically (spike, Godot
	# 4.5 GL Compatibility) EditorFileSystem.scan_single_file() does NOT
	# recompile shaders and raises a script error, while ResourceLoader.load
	# with CACHE_MODE_REPLACE plus Shader.get_rid() (which triggers the lazy
	# shader_create_from_code compile) logs parse errors synchronously through
	# the logger. The editor picks up the file change on its own rescan.
	_force_shader_recompile(shader_path)

	# Wait a couple of frames so driver-level compile errors (which can be
	# reported after the synchronous parse) reach the logger too.
	for _i in range(RECOMPILE_WAIT_FRAMES):
		await get_tree().process_frame

	var entries = logger.drain_since(marker)
	var diagnostics := _entries_to_diagnostics(entries, shader_path)
	_diagnostic_collection_active = false
	return diagnostics

func _entries_to_diagnostics(entries: Array, filter_path: String = "") -> Array:
	var normalized_filter := ""
	if not filter_path.is_empty():
		normalized_filter = _normalize_shader_path(filter_path)

	var diagnostics: Array = []
	for entry in entries:
		var entry_file: String = entry.get("file", "")
		# Errors captured under GL Compatibility carry an empty file field, so
		# a path filter only excludes entries attributed to a different file.
		if not normalized_filter.is_empty() and not entry_file.is_empty() and entry_file != normalized_filter:
			continue
		var diagnostic := {
			"line": int(entry.get("line", 0)),
			"message": entry.get("message", ""),
			"severity": entry.get("severity", "error")
		}
		# The same broken shader can be recompiled several times (forced reload
		# plus the editor's own rescan), so identical entries are collapsed.
		if not diagnostics.has(diagnostic):
			diagnostics.append(diagnostic)
	return diagnostics

# Loads the shader resource fresh from disk and forces the lazy compile inside
# RenderingServer (Shader.get_rid() triggers shader_create_from_code). Parse
# errors are logged synchronously with Logger.ERROR_TYPE_SHADER.
func _force_shader_recompile(shader_path: String) -> bool:
	var shader := ResourceLoader.load(shader_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if shader == null:
		return false
	if not shader is Shader:
		return false
	shader.get_rid()
	return true

func _write_shader_file(shader_path: String, content: String) -> String:
	var dir := shader_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return "Failed to create directory: %s (Error code: %d)" % [dir, err]

	var file := FileAccess.open(shader_path, FileAccess.WRITE)
	if file == null:
		return "Failed to open shader file for writing: %s" % shader_path

	file.store_string(content)
	file = null  # Close the file
	return ""

func _read_shader_file(shader_path: String) -> String:
	var file := FileAccess.open(shader_path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file = null  # Close the file
	return content

func _declared_shader_type(content: String) -> String:
	var result := _shader_type_regex.search(content)
	if result == null:
		return ""
	return result.get_string(1)

func _normalize_shader_path(shader_path: String) -> String:
	var normalized := shader_path.strip_edges().replace("\\", "/")
	# Reject path traversal so writes (and reads) can never escape res://:
	# a ".." segment anywhere in the path is refused outright.
	if _has_parent_segment(normalized):
		return ""
	if normalized.begins_with("res://"):
		if normalized.ends_with(".gdshader"):
			return normalized
		return normalized + ".gdshader"
	if normalized.begins_with("/"):
		normalized = "res://" + normalized.substr(1)
	else:
		normalized = "res://" + normalized
	if not normalized.ends_with(".gdshader"):
		normalized += ".gdshader"
	return normalized

# True when the path contains a ".." segment (with either separator), which
# could climb out of res:// on write.
func _has_parent_segment(path: String) -> bool:
	var segments := path.replace("\\", "/").split("/")
	return segments.has("..")

func _get_shader_logger():
	if Engine.has_meta("MCPShaderErrorLogger"):
		var logger = Engine.get_meta("MCPShaderErrorLogger")
		if logger and logger.has_method("record_marker") and logger.has_method("drain_since"):
			return logger
	return null

# ---------------------------------------------------------------------------
# Runtime (running-game) shader tools
# ---------------------------------------------------------------------------

func _get_runtime_bridge() -> MCPRuntimeDebuggerBridge:
	if Engine.has_meta("MCPRuntimeDebuggerBridge"):
		return Engine.get_meta("MCPRuntimeDebuggerBridge") as MCPRuntimeDebuggerBridge
	return null

func _shader_list_materials(client_id: int, params: Dictionary, command_id: String) -> void:
	var node_path := str(params.get("node_path", ""))
	var material_slot := str(params.get("material_slot", ""))
	var wait_ms := clampi(int(params.get("wait_ms", DEFAULT_RUNTIME_TIMEOUT_MS)), 0, MAX_RUNTIME_TIMEOUT_MS)

	var result := await _send_shader_request("list_materials", [node_path, material_slot], wait_ms)
	_finish_shader_runtime_request(client_id, result, command_id)

func _shader_get_uniforms(client_id: int, params: Dictionary, command_id: String) -> void:
	var node_path := str(params.get("node_path", ""))
	var material_slot := str(params.get("material_slot", "material"))
	var wait_ms := clampi(int(params.get("wait_ms", DEFAULT_RUNTIME_TIMEOUT_MS)), 0, MAX_RUNTIME_TIMEOUT_MS)

	if node_path.is_empty():
		return _send_error(client_id, "node_path parameter is required", command_id)

	var result := await _send_shader_request("get_uniforms", [node_path, material_slot], wait_ms)
	_finish_shader_runtime_request(client_id, result, command_id)

func _shader_set_uniform(client_id: int, params: Dictionary, command_id: String) -> void:
	var node_path := str(params.get("node_path", ""))
	var uniform_name := str(params.get("uniform_name", ""))
	var value = params.get("value", null)
	var material_slot := str(params.get("material_slot", "material"))
	var allow_shared := bool(params.get("allow_shared", false))
	var wait_ms := clampi(int(params.get("wait_ms", DEFAULT_RUNTIME_TIMEOUT_MS)), 0, MAX_RUNTIME_TIMEOUT_MS)

	if node_path.is_empty():
		return _send_error(client_id, "node_path parameter is required", command_id)
	if uniform_name.is_empty():
		return _send_error(client_id, "uniform_name parameter is required", command_id)

	var result := await _send_shader_request("set_uniform", [node_path, uniform_name, value, material_slot, allow_shared], wait_ms)
	_finish_shader_runtime_request(client_id, result, command_id)


func _shader_debug_snapshot(client_id: int, params: Dictionary, command_id: String) -> void:
	var node_path := str(params.get("node_path", ""))
	var material_slot := str(params.get("material_slot", "material"))

	if node_path.is_empty():
		return _send_error(client_id, "node_path parameter is required", command_id)

	# Read-only snapshot; polls with a short fixed timeout (no user wait knob).
	var result := await _send_shader_request("debug_snapshot", [node_path, material_slot], SNAPSHOT_TIMEOUT_MS)
	_finish_shader_runtime_request(client_id, result, command_id)


func _shader_hot_reload(client_id: int, params: Dictionary, command_id: String) -> void:
	var shader_path := str(params.get("shader_path", ""))
	var node_path := str(params.get("node_path", ""))
	var material_slot := str(params.get("material_slot", "material"))
	var content := str(params.get("content", ""))

	if content.strip_edges().is_empty():
		return _send_error(client_id, "content parameter is required", command_id)
	if shader_path.is_empty() and node_path.is_empty():
		return _send_error(client_id, "Provide shader_path or node_path (with optional material_slot) to locate the shader", command_id)

	var normalized_path := ""
	if not shader_path.is_empty():
		normalized_path = _normalize_shader_path(shader_path)
		if normalized_path.is_empty():
			return _send_error(client_id, "Invalid shader path: '..' path segments are not allowed (paths must stay inside res://)", command_id)

	# The game applies the new code live to every material using the shader
	# and reports the affected materials plus the previous code (the rollback
	# path: re-call with content=previous_code).
	var result := await _send_shader_request("hot_reload", [normalized_path, node_path, material_slot, content], HOT_RELOAD_TIMEOUT_MS)
	if result.has("error"):
		return _send_error(client_id, str(result["error"]), command_id)
	if not bool(result.get("success", true)):
		return _send_error(client_id, str(result.get("error", "Shader hot reload failed in the running game")), command_id)

	var payload := result.duplicate(true)
	payload.erase("success")

	# Best-effort disk sync: a write failure must not fail the live apply, so
	# the file status is reported alongside the live result. Only standalone
	# .gdshader files are written (embedded "scene.tscn::Shader_x" resources
	# and local shaders have no file to sync).
	var resolved_path := str(payload.get("shader_path", ""))
	payload["file_written"] = false
	payload["file_write_error"] = ""
	if resolved_path.is_empty() or resolved_path == "local" or not resolved_path.ends_with(".gdshader"):
		payload["file_write_error"] = "shader is not a standalone .gdshader file; disk write skipped"
	else:
		var write_error := _write_shader_file(resolved_path, content)
		payload["file_written"] = write_error.is_empty()
		payload["file_write_error"] = write_error

	# Merge the game-side live-apply errors with the editor's own deterministic
	# recompile check of the written file (the existing shader error logger
	# mechanism with its marker/wait/drain cycle).
	var game_errors: Array = payload.get("compile_errors", [])
	if payload["file_written"]:
		var file_diagnostics: Array = await _collect_shader_diagnostics(resolved_path)
		payload["compile_errors"] = _merge_diagnostics(game_errors, file_diagnostics)
	else:
		payload["compile_errors"] = game_errors

	_send_success(client_id, payload, command_id)


func _shader_debug_overlay(client_id: int, params: Dictionary, command_id: String) -> void:
	var mode := str(params.get("mode", ""))
	var viewport_index := int(params.get("viewport_index", 0))
	var wait_ms := clampi(int(params.get("wait_ms", DEFAULT_RUNTIME_TIMEOUT_MS)), 0, MAX_RUNTIME_TIMEOUT_MS)

	if mode.is_empty():
		return _send_error(client_id, "mode parameter is required", command_id)
	if not DEBUG_OVERLAY_MODES.has(mode):
		return _send_error(client_id, "Unknown mode '%s'; expected one of: %s" % [mode, ", ".join(DEBUG_OVERLAY_MODES)], command_id)

	var result := await _send_shader_request("debug_overlay", [mode, viewport_index], wait_ms)
	_finish_shader_runtime_request(client_id, result, command_id)


func _capture_running_game(client_id: int, params: Dictionary, command_id: String) -> void:
	var output_path := str(params.get("output_path", ""))
	var return_base64 := bool(params.get("return_base64", false))
	var allow_large := bool(params.get("allow_large", false))
	var wait_ms := clampi(int(params.get("wait_ms", CAPTURE_DEFAULT_TIMEOUT_MS)), 0, MAX_RUNTIME_TIMEOUT_MS)

	var result := await _send_shader_request("capture", [output_path, return_base64, allow_large], wait_ms)
	_finish_shader_runtime_request(client_id, result, command_id)


# Merges two diagnostic lists, collapsing identical entries so the game-side
# live-apply errors and the editor-side file recompile errors are reported once.
func _merge_diagnostics(first: Array, second: Array) -> Array:
	var merged: Array = []
	for diagnostic in first:
		merged.append(diagnostic)
	for diagnostic in second:
		if not merged.has(diagnostic):
			merged.append(diagnostic)
	return merged

# Sends a shader request to the running game and polls for the correlated
# result until wait_ms elapses. Returns the game's result Dictionary or an
# { "error": ... } Dictionary on any failure.
func _send_shader_request(action: String, args: Array, wait_ms: int) -> Dictionary:
	var runtime_bridge := _get_runtime_bridge()
	if runtime_bridge == null:
		return { "error": "Runtime debugger bridge not available. Ensure the MCP plugin is enabled." }

	# Fail fast with a clear message when no game is attached to the debugger.
	var has_active_session := false
	var sessions := runtime_bridge.get_sessions()
	for i in range(sessions.size()):
		var session = sessions[i]
		if session and session.has_method("is_active") and session.is_active():
			has_active_session = true
			break
	if not has_active_session:
		return { "error": "No active runtime session. Run the game from the editor with the debugger attached (F5) and retry." }

	var sent := runtime_bridge.send_shader_request(action, args)
	if sent.has("error"):
		return sent

	var session_id := int(sent["session_id"])
	var request_id := int(sent["request_id"])

	var deadline := Time.get_ticks_msec() + wait_ms
	while Time.get_ticks_msec() < deadline:
		if runtime_bridge.has_shader_result(session_id, request_id):
			return runtime_bridge.take_shader_result(session_id, request_id)
		if get_tree():
			await get_tree().process_frame
		else:
			break

	# The request timed out: evict any pending entry so a late reply cannot
	# linger in the per-session result store.
	runtime_bridge.discard_shader_result(session_id, request_id)

	return { "error": "Shader runtime request '%s' timed out after %d ms. Ensure the game is running with the MCP shader runtime autoload." % [action, wait_ms] }

# Forwards a runtime result to the client, converting game-side failures
# (success=false / error=...) into the standard error response shape. The
# game payload already carries its own success/error markers; those are
# consumed for routing above, so the forwarded payload does not nest a second
# success key inside the result.
func _finish_shader_runtime_request(client_id: int, result: Dictionary, command_id: String) -> void:
	if result.has("error"):
		return _send_error(client_id, str(result["error"]), command_id)
	if not bool(result.get("success", true)):
		return _send_error(client_id, str(result.get("error", "Shader runtime request failed")), command_id)
	var payload := result.duplicate(true)
	payload.erase("success")
	_send_success(client_id, payload, command_id)
