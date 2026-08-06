@tool
class_name MCPShaderErrorLogger
extends Logger

# Captures shader compile errors emitted by the engine (Logger.ERROR_TYPE_SHADER)
# into a thread-safe buffer so MCP shader commands can correlate compile
# results with their own writes.
#
# Severity note (investigated on Godot 4.5.1): shader WARNINGS never reach
# this logger. ShaderLanguage only collects warnings when
# enable_warning_checking() is enabled, and the only caller in the engine is
# the shader text editor (editor/shader/text_shader_editor.cpp); the
# renderer's compile path never enables warning checking, and
# _err_print_error(ERR_HANDLER_SHADER) is invoked for errors only. Verified
# empirically: with all debug/shader_language/warnings/* settings on, a
# shader full of unused declarations produces zero entries here. shader
# warnings are therefore reported by the static MCPShaderWarningScanner
# (mcp_shader_warning_scanner.gd) instead; every entry in this buffer is a
# genuine compile error with severity "error".
#
# The engine invokes _log_error() from arbitrary threads (renderer worker
# threads included), possibly concurrently, so every access to the buffer is
# guarded by a Mutex. Never call print()/push_error() inside _log_error():
# the engine blocks recursive logging, so those calls would be lost anyway.
#
# Request correlation: call record_marker() before triggering a write or
# recompile, then drain_since(marker) to read only the errors produced after
# that point. Unrelated shader compiles that happen in the editor in the same
# window are excluded by the marker, not by path filtering.

const MAX_CAPTURED_ERRORS := 512

var _mutex := Mutex.new()
var _captured_errors: Array = []
var _next_index := 0

# Engine callback for all errors/warnings. Filtered to shader errors only and
# stored without any logging so the callback stays safe on worker threads.
func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	editor_notify: bool,
	error_type: int,
	script_backtraces: Array
) -> void:
	if error_type != Logger.ERROR_TYPE_SHADER:
		return

	var message := rationale
	if message.is_empty():
		message = code

	# Assign the sequence index while holding the same mutex used by markers.
	# Otherwise concurrent logger callbacks could reuse an index, or an error
	# could be assigned before record_marker() but appended after it.
	_mutex.lock()
	var entry := {
		"index": _next_index,
		"file": file,
		"line": line,
		"message": message,
		"severity": "error",
	}
	_captured_errors.append(entry)
	_next_index += 1
	if _captured_errors.size() > MAX_CAPTURED_ERRORS:
		_captured_errors.pop_front()
	_mutex.unlock()

# Returns the index of the next error that will be captured. Record the marker
# before triggering a recompile, then pass it to drain_since() to read only the
# errors produced by that recompile.
func record_marker() -> int:
	_mutex.lock()
	var marker := _next_index
	_mutex.unlock()
	return marker

# Returns captured shader errors with index >= marker, oldest first. When the
# buffer has overflowed and dropped entries, the oldest available entries are
# returned instead (marker semantics degrade to "everything captured").
# Entries are deep-duplicated so callers cannot mutate the captured buffer.
func drain_since(marker: int) -> Array:
	_mutex.lock()
	var result: Array = []
	for entry in _captured_errors:
		if int(entry["index"]) >= marker:
			result.append(entry.duplicate(true))
	_mutex.unlock()
	return result

# Total number of shader errors captured since install (including dropped ones).
func get_captured_count() -> int:
	_mutex.lock()
	var count := _next_index
	_mutex.unlock()
	return count

# Clears the buffer and resets the index sequence.
func clear() -> void:
	_mutex.lock()
	_captured_errors.clear()
	_next_index = 0
	_mutex.unlock()
