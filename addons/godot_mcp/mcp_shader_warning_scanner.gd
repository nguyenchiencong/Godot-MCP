@tool
class_name MCPShaderWarningScanner
extends RefCounted

# Static shader-warning detector used by shader_get_warnings and
# shader_project_health (Phase D).
#
# Why a static scanner: investigation of Godot 4.5.1 showed that shader
# WARNINGS never reach the Logger. ShaderLanguage only collects warnings when
# enable_warning_checking() is set, and the only caller in the engine is the
# shader text editor (editor/shader/text_shader_editor.cpp); the renderer's
# compile path (ShaderCompiler) never enables warning checking, and
# _err_print_error(ERR_HANDLER_SHADER) is invoked for errors only. Empirically
# verified against a live 4.5.1 editor: a shader full of unused declarations
# produced zero MCPShaderErrorLogger entries, while a parse-error shader
# produced exactly one (severity "error").
#
# This scanner mirrors the engine's UNUSED_* warning family
# (ShaderWarning in servers/rendering/shader_warnings.cpp) so the MCP tools
# can report them anyway:
#   - UNUSED_UNIFORM / UNUSED_VARYING / UNUSED_FUNCTION / UNUSED_STRUCT /
#     UNUSED_CONSTANT: a global declaration whose name never appears again
#     in the source.
#   - UNUSED_LOCAL_VARIABLE: a local declaration whose name never appears
#     again inside its enclosing function body.
#   - FORMATTING_ERROR: empty statements (";;" or a lone ";").
# Each check is gated on the matching ProjectSettings flag
# (debug/shader_language/warnings/<name>, default true in 4.5 debug builds).
# FLOAT_COMPARISON, DEVICE_LIMIT_EXCEEDED and MAGIC_POSITION_WRITE are not
# detected here (they need type/device knowledge); the shader text editor
# remains the source of truth for those.
#
# The scanner is intentionally conservative: it only reports clear-cut cases,
# so a missed warning is preferable to a false positive. Comments are
# stripped before analysis; brace depth tracks function bodies so locals are
# scoped to their own function.

const WARNING_SETTING_PREFIX := "debug/shader_language/warnings/"
const WARNINGS_ENABLE_SETTING := "debug/shader_language/warnings/enable"

# Entry point functions are invoked by the engine, so the engine never warns
# about them; mirror that here.
const ENTRY_POINT_FUNCTIONS := ["vertex", "fragment", "light", "process", "sky", "fog", "start", "stop"]

# Shader language type tokens that can start a declaration or function
# signature. Group 1 captures the declared identifier.
const TYPE_PREFIX_SOURCE := "(?:void|float|int|bool|vec[234]|ivec[234]|bvec[234]|mat[234]|sampler2D|sampler3D|samplerCube)"

const UNIFORM_REGEX_SOURCE := "^\\s*uniform\\s+" + TYPE_PREFIX_SOURCE + "\\s+([A-Za-z_][A-Za-z0-9_]*)"
const VARYING_REGEX_SOURCE := "^\\s*varying\\s+" + TYPE_PREFIX_SOURCE + "\\s+([A-Za-z_][A-Za-z0-9_]*)"
const CONST_REGEX_SOURCE := "^\\s*const\\s+" + TYPE_PREFIX_SOURCE + "\\s+([A-Za-z_][A-Za-z0-9_]*)"
const STRUCT_REGEX_SOURCE := "^\\s*struct\\s+([A-Za-z_][A-Za-z0-9_]*)"
const FUNCTION_REGEX_SOURCE := "^\\s*" + TYPE_PREFIX_SOURCE + "\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\("
const LOCAL_REGEX_SOURCE := "^\\s*" + TYPE_PREFIX_SOURCE + "\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:=|;|,|\\()"

var _uniform_regex := RegEx.new()
var _varying_regex := RegEx.new()
var _const_regex := RegEx.new()
var _struct_regex := RegEx.new()
var _function_regex := RegEx.new()
var _local_regex := RegEx.new()

func _init() -> void:
	_uniform_regex.compile(UNIFORM_REGEX_SOURCE)
	_varying_regex.compile(VARYING_REGEX_SOURCE)
	_const_regex.compile(CONST_REGEX_SOURCE)
	_struct_regex.compile(STRUCT_REGEX_SOURCE)
	_function_regex.compile(FUNCTION_REGEX_SOURCE)
	_local_regex.compile(LOCAL_REGEX_SOURCE)

# Scans shader source and returns an Array of warning diagnostics, each
# { line, message, severity: "warning", file }. Empty when no warnings are
# detected or when warning checking is disabled in ProjectSettings.
func scan(source: String, file_path: String) -> Array:
	if not _warnings_enabled():
		return []

	var lines := _strip_comments(source).split("\n")
	var depths := _line_depths(lines)

	var warnings := []
	var functions := []  # { name, body_start, body_end } for local scoping

	# Global declarations: only lines whose brace depth at line start is 0.
	for i in lines.size():
		if depths[i] != 0:
			continue
		_scan_global_line(lines, i, functions, warnings, file_path)

	# Local variables: declared inside a function body, scoped to that body.
	for i in lines.size():
		if depths[i] < 1:
			continue
		var found := _local_regex.search(lines[i])
		if found == null:
			continue
		var name := found.get_string(1)
		var enclosing := _enclosing_function(functions, i)
		if enclosing.is_empty():
			continue
		var body := lines.slice(enclosing["body_start"], enclosing["body_end"])
		if _usage_count_in_lines(body, name) <= 1:
			warnings.append({
				"line": i + 1,
				"message": "The local variable '%s' is declared but never used." % name,
				"severity": "warning",
				"file": file_path
			})

	# Formatting errors: empty statements anywhere (no depth restriction).
	for i in lines.size():
		var trimmed: String = lines[i].strip_edges()
		if trimmed == ";" or trimmed.contains(";;"):
			warnings.append({
				"line": i + 1,
				"message": "Empty statement. Remove ';' to fix this warning.",
				"severity": "warning",
				"file": file_path
			})

	return warnings


# Scans one global-scope line for declarations of each category and appends
# warnings for names that are never used elsewhere in the source.
func _scan_global_line(lines: Array, line_index: int, functions: Array, warnings: Array, file_path: String) -> void:
	var line: String = lines[line_index]

	var checks := [
		{ "regex": _uniform_regex, "setting": "unused_uniform", "kind": "uniform" },
		{ "regex": _varying_regex, "setting": "unused_varying", "kind": "varying" },
		{ "regex": _const_regex, "setting": "unused_constant", "kind": "const" },
		{ "regex": _struct_regex, "setting": "unused_struct", "kind": "struct" },
	]
	for check in checks:
		var check_regex: RegEx = check["regex"]
		var found: RegExMatch = check_regex.search(line)
		if found == null:
			continue
		if not _warning_enabled(check["setting"]):
			continue
		var name: String = found.get_string(1)
		# The declaration itself contributes exactly one occurrence; any
		# further occurrence anywhere in the source means the name is used.
		if _usage_count_in_lines(lines, name) <= 1:
			warnings.append({
				"line": line_index + 1,
				"message": "The %s '%s' is declared but never used." % [check["kind"], name],
				"severity": "warning",
				"file": file_path
			})

	# Functions: recorded for local scoping, and warned about when never called.
	var func_match := _function_regex.search(line)
	if func_match == null:
		return
	var name := func_match.get_string(1)
	functions.append({
		"name": name,
		"body_start": line_index + 1,
		"body_end": _function_end_line(line_index, _depth_after_lines(lines, line_index))
	})
	if ENTRY_POINT_FUNCTIONS.has(name) or not _warning_enabled("unused_function"):
		return
	if _usage_count_in_lines(lines, name) <= 1:
		warnings.append({
			"line": line_index + 1,
			"message": "The function '%s' is declared but never used." % name,
			"severity": "warning",
			"file": file_path
		})


# Returns the index of the line that closes the function whose opening brace
# is on decl_line: the first line after it whose depth drops back to 0.
# depth_after[offset] is the brace depth after processing line decl_line+offset.
func _function_end_line(decl_line: int, depth_after: Array) -> int:
	for offset in range(1, depth_after.size()):
		if int(depth_after[offset]) == 0:
			return decl_line + offset
	return decl_line


# Computes the brace depth at the start of every line, and the depth after
# every line. A line whose start depth is 0 is at global scope.
func _line_depths(lines: Array) -> Array:
	var depths := []
	var depth := 0
	for line in lines:
		depths.append(depth)
		depth = _apply_brace_delta(depth, line)
	return depths


# Returns the depth AFTER each line, for lines starting at start_index.
func _depth_after_lines(lines: Array, start_index: int) -> Array:
	var depth_after := []
	var depth := 0
	for i in range(start_index, lines.size()):
		depth = _apply_brace_delta(depth, lines[i])
		depth_after.append(depth)
	return depth_after


func _apply_brace_delta(depth: int, line: String) -> int:
	var result := depth
	for i in line.length():
		var c := line[i]
		if c == "{":
			result += 1
		elif c == "}":
			result -= 1
			if result < 0:
				result = 0
	return result


# Returns the function dict whose [body_start, body_end] range contains the
# line index, or {} when the line is not inside any recorded function.
func _enclosing_function(functions: Array, line_index: int) -> Dictionary:
	var enclosing := {}
	for fn in functions:
		if line_index >= fn["body_start"] and line_index <= fn["body_end"]:
			enclosing = fn
	return enclosing


# Counts word-boundary occurrences of `name` in the given lines.
func _usage_count_in_lines(lines: Array, name: String) -> int:
	var count := 0
	var regex := RegEx.new()
	regex.compile("\\b" + name + "\\b")
	for line in lines:
		for occ in regex.search_all(line):
			count += 1
	return count


# True when shader warnings are enabled globally.
func _warnings_enabled() -> bool:
	return bool(ProjectSettings.get_setting(WARNINGS_ENABLE_SETTING, true))


# True when the specific warning category is enabled. Defaults to true,
# matching Godot 4.5 debug builds (the settings only exist in DEBUG_ENABLED
# builds, where they default to true).
func _warning_enabled(code_name: String) -> bool:
	return bool(ProjectSettings.get_setting(WARNING_SETTING_PREFIX + code_name, true))


# Removes line and block comments while preserving newlines so line numbers
# stay aligned with the original source.
func _strip_comments(source: String) -> String:
	var result := ""
	var i := 0
	while i < source.length():
		var c := source[i]
		if c == "/" and i + 1 < source.length():
			var next := source[i + 1]
			if next == "/":
				while i < source.length() and source[i] != "\n":
					i += 1
				continue
			elif next == "*":
				i += 2
				while i + 1 < source.length() and not (source[i] == "*" and source[i + 1] == "/"):
					i += 1
				i += 2
				continue
		result += c
		i += 1
	return result
