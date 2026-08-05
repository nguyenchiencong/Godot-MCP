extends Node
## Runtime shader handler for MCP shader tools (Phase B).
##
## This script runs inside the GAME (not the editor), like mcp_input_handler.gd,
## and answers requests about ShaderMaterials in the live scene. It registers an
## EngineDebugger message capture named "mcp_shader" and handles three actions:
##   mcp_shader:list_materials  -> [request_id, node_path, material_slot]
##   mcp_shader:get_uniforms    -> [request_id, node_path, material_slot]
##   mcp_shader:set_uniform     -> [request_id, node_path, uniform_name, value, material_slot, allow_shared]
##
## Every reply is sent with EngineDebugger.send_message("mcp_shader:result",
## [request_id, payload]) where payload is a Dictionary of fully serializable
## primitives only (no Vector3/Color/Transform3D/Texture2D/RID Variants):
## vectors become arrays, colors become {r,g,b,a}, transforms become a 16-float
## column-major array, textures/materials become their res:// path.

const CAPTURE_NAME := "mcp_shader"

# Matches a single uniform declaration, e.g.
#   uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.25, 1.0);
#   uniform float weights[3] = { 0.1, 0.2, 0.3 };
# The "rest" group runs up to the terminating ';' and is parsed separately for
# the optional '= default' and ': hint' parts (either order).
const UNIFORM_REGEX_SOURCE := "\\buniform\\b\\s+(?P<type>[a-zA-Z_][a-zA-Z0-9_]*)\\s+(?P<name>[a-zA-Z_][a-zA-Z0-9_]*)(?P<array>\\[\\s*\\d*\\s*\\])?(?P<rest>[\\s\\S]*?);"

var _uniform_regex := RegEx.new()

func _init() -> void:
	_uniform_regex.compile(UNIFORM_REGEX_SOURCE)

func _ready() -> void:
	# Only register in a running game, never in the editor.
	if Engine.is_editor_hint():
		return

	if not EngineDebugger.is_active():
		print("[MCP Shader Runtime] Debugger not active, shader runtime unavailable")
		return

	EngineDebugger.register_message_capture(CAPTURE_NAME, _on_capture)
	print("[MCP Shader Runtime] Shader runtime ready")


func _on_capture(message: String, data: Array) -> bool:
	var action := message.substr(CAPTURE_NAME.length() + 1) if message.begins_with(CAPTURE_NAME + ":") else message

	match action:
		"list_materials":
			return _handle_list_materials(data)
		"get_uniforms":
			return _handle_get_uniforms(data)
		"set_uniform":
			return _handle_set_uniform(data)

	return false


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _handle_list_materials(data: Array) -> bool:
	if data.size() < 1:
		return false

	var request_id := int(data[0])
	var node_path := str(data[1]) if data.size() > 1 else ""
	var material_slot := str(data[2]) if data.size() > 2 else ""

	var start_node := _find_node(node_path)
	if start_node == null:
		_send_error(request_id, "Node not found in running game: %s" % node_path)
		return true

	# Collect every (slot, material) pair in the subtree, then build the
	# sharing map keyed by material instance so users lists cover every node
	# using the same material instance regardless of slot.
	var pairs := _collect_material_pairs(start_node)
	var sharing_map := {}  # instance_id -> { users: [node_path, ...] }
	var entries := []

	for pair in pairs:
		var material: Material = pair["material"]
		if not material is ShaderMaterial:
			continue
		var slot_name := str(pair["slot"])
		if not material_slot.is_empty() and slot_name != material_slot:
			continue

		var material_path := material.resource_path if not material.resource_path.is_empty() else "local"
		var shader_path := ""
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		if shader:
			shader_path = shader.resource_path

		var instance_id := material.get_instance_id()
		if not sharing_map.has(instance_id):
			sharing_map[instance_id] = { "users": [] }
		var users: Array = sharing_map[instance_id]["users"]
		var user_path := str(pair["node_path"])
		if not users.has(user_path):
			users.append(user_path)

		entries.append({
			"node_path": str(pair["node_path"]),
			"material_path": material_path,
			"shader_path": shader_path,
			"slot": slot_name,
			"_instance_id": instance_id
		})

	for entry in entries:
		var share: Dictionary = sharing_map[entry["_instance_id"]]
		var users: Array = share["users"]
		entry["sharing"] = {
			"users_count": users.size(),
			"users": users
		}
		entry.erase("_instance_id")

	_send_result(request_id, {
		"success": true,
		"materials": entries,
		"count": entries.size()
	})
	return true


func _handle_get_uniforms(data: Array) -> bool:
	if data.size() < 2:
		return false

	var request_id := int(data[0])
	var node_path := str(data[1])
	var material_slot := str(data[2]) if data.size() > 2 else "material"

	var resolved := _resolve_material(node_path, material_slot)
	if not resolved["ok"]:
		_send_error(request_id, resolved["error"])
		return true

	var material: ShaderMaterial = resolved["material"]
	var shader := material.shader
	if shader == null:
		_send_error(request_id, "Material on %s has no shader" % resolved["node_path"])
		return true

	var uniforms := _parse_shader_uniforms(shader.code)
	for uniform_entry in uniforms:
		uniform_entry["value"] = _serialize_value(material.get_shader_parameter(uniform_entry["name"]))
		# Internal parse metadata is not part of the wire format.
		uniform_entry.erase("_type_token")
		uniform_entry.erase("_hint_text")
		uniform_entry.erase("_is_array")

	_send_result(request_id, {
		"success": true,
		"node_path": resolved["node_path"],
		"slot": resolved["slot"],
		"shader_path": shader.resource_path,
		"uniforms": uniforms,
		"count": uniforms.size()
	})
	return true


func _handle_set_uniform(data: Array) -> bool:
	if data.size() < 4:
		return false

	var request_id := int(data[0])
	var node_path := str(data[1])
	var uniform_name := str(data[2])
	var raw_value = data[3]
	var material_slot := str(data[4]) if data.size() > 4 else "material"
	var allow_shared := bool(data[5]) if data.size() > 5 else false

	if uniform_name.is_empty():
		_send_error(request_id, "uniform_name is required")
		return true

	var resolved := _resolve_material(node_path, material_slot)
	if not resolved["ok"]:
		_send_error(request_id, resolved["error"])
		return true

	var material: ShaderMaterial = resolved["material"]
	var shader := material.shader
	if shader == null:
		_send_error(request_id, "Material on %s has no shader" % resolved["node_path"])
		return true

	var uniform_def := _find_uniform_declaration(shader.code, uniform_name)
	if uniform_def.is_empty():
		var names := _declared_uniform_names(shader.code)
		var known := ""
		if not names.is_empty():
			known = " Known uniforms: %s" % ", ".join(names)
		_send_error(request_id, "Unknown uniform '%s' on shader %s.%s" % [uniform_name, shader.resource_path, known])
		return true

	var converted := _convert_uniform_value(
		uniform_def["_type_token"],
		uniform_def["_hint_text"],
		uniform_def["_is_array"],
		int(uniform_def.get("array_size", -1)),
		raw_value
	)
	if not converted["ok"]:
		_send_error(request_id, converted["error"])
		return true

	var sharing := _find_material_sharing(material)
	if sharing["users_count"] > 1 and not allow_shared:
		var users_text := ", ".join(sharing["users"])
		_send_error(request_id, "Material on %s is shared by %d nodes (%s). Set allow_shared=true to modify it anyway, or duplicate the material first." % [
			resolved["node_path"], sharing["users_count"], users_text
		])
		return true

	var previous_value = _serialize_value(material.get_shader_parameter(uniform_name))
	material.set_shader_parameter(uniform_name, converted["value"])
	var new_value = _serialize_value(material.get_shader_parameter(uniform_name))

	_send_result(request_id, {
		"success": true,
		"node_path": resolved["node_path"],
		"slot": resolved["slot"],
		"uniform_name": uniform_name,
		"previous_value": previous_value,
		"new_value": new_value,
		"sharing": sharing
	})
	return true


# ---------------------------------------------------------------------------
# Material / node resolution
# ---------------------------------------------------------------------------

# Returns { ok: bool, material: ShaderMaterial, node_path: String, slot: String, error: String }
func _resolve_material(node_path: String, material_slot: String) -> Dictionary:
	var node := _find_node(node_path)
	if node == null:
		return { "ok": false, "error": "Node not found in running game: %s" % node_path }

	var slot_name := material_slot
	if slot_name.is_empty():
		slot_name = "material"

	var slots := _collect_node_material_slots(node)
	for pair in slots:
		if str(pair[0]) == slot_name:
			var material: Material = pair[1]
			if not material is ShaderMaterial:
				return { "ok": false, "error": "Slot '%s' on %s is not a ShaderMaterial (found %s)" % [slot_name, _node_path_string(node), material.get_class()] }
			return { "ok": true, "material": material, "node_path": _node_path_string(node), "slot": slot_name }

	var available := []
	for pair in slots:
		available.append(str(pair[0]))
	var hint := "available slots: %s" % ", ".join(available) if not available.is_empty() else "node has no material slots"
	return { "ok": false, "error": "No material in slot '%s' on %s (%s)" % [slot_name, _node_path_string(node), hint] }


# Returns an Array of { slot: String, material: Material, node_path: String }
# for every (slot, material) pair in the subtree rooted at start_node.
func _collect_material_pairs(start_node: Node) -> Array:
	var pairs := []
	var stack := [start_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var node_path := _node_path_string(node)
		for slot_material in _collect_node_material_slots(node):
			pairs.append({
				"slot": slot_material[0],
				"material": slot_material[1],
				"node_path": node_path
			})
		for child in node.get_children():
			stack.append(child)
	return pairs


# Returns an Array of [slot_name: String, material: Material] pairs for one node,
# covering the common material carriers: CanvasItem.material, geometry
# material_override, and Mesh materials (whole-mesh and per-surface).
func _collect_node_material_slots(node: Node) -> Array:
	var slots := []
	if "material" in node:
		var material = node.get("material")
		if material is Material:
			slots.append(["material", material])
	if "material_override" in node:
		var material = node.get("material_override")
		if material is Material:
			slots.append(["material_override", material])
	if "mesh" in node:
		var mesh_variant = node.get("mesh")
		if mesh_variant is Mesh:
			var mesh := mesh_variant as Mesh
			if "material" in mesh:
				var mesh_material = mesh.get("material")
				if mesh_material is Material:
					slots.append(["mesh", mesh_material])
			var surface_count := mesh.get_surface_count()
			for i in surface_count:
				var surface_material = mesh.surface_get_material(i)
				if surface_material is Material:
					slots.append(["surface_%d" % i, surface_material])
	return slots


# Returns { users_count: int, users: [node_path, ...] } for every node in the
# scene (rooted at the current scene, else the tree root) that references the
# same material instance.
func _find_material_sharing(material: Material) -> Dictionary:
	var target_id := material.get_instance_id()
	var users := []
	var root := _get_scene_root()
	var stack := [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for pair in _collect_node_material_slots(node):
			if pair[1].get_instance_id() == target_id:
				users.append(_node_path_string(node))
				break  # One entry per node.
		for child in node.get_children():
			stack.append(child)
	return { "users_count": users.size(), "users": users }


func _find_node(node_path: String) -> Node:
	if node_path.is_empty():
		return _get_scene_root()

	var root := get_tree().root
	var node := root.get_node_or_null(node_path)
	if node:
		return node

	# Accept paths with the /root/ prefix stripped as well.
	var trimmed := node_path
	while trimmed.begins_with("/root/"):
		trimmed = trimmed.substr(6)
	if trimmed != node_path:
		node = root.get_node_or_null(trimmed)
		if node:
			return node

	var scene_root := _get_scene_root()
	if scene_root and scene_root != root:
		node = scene_root.get_node_or_null(trimmed)
		if node:
			return node
	return null


func _get_scene_root() -> Node:
	var current := get_tree().current_scene
	if current:
		return current
	return get_tree().root


func _node_path_string(node: Node) -> String:
	return str(node.get_path())


# ---------------------------------------------------------------------------
# Shader source parsing (uniform metadata)
# ---------------------------------------------------------------------------

# Parses every uniform declaration in shader source. Each entry contains the
# wire fields (name/type/value/default/hint, plus array markers) and internal
# parse fields (_type_token/_hint_text/_is_array) used by set_uniform.
func _parse_shader_uniforms(source: String) -> Array:
	var clean := _strip_shader_comments(source)
	var uniforms := []
	var pos := 0

	while true:
		var result := _uniform_regex.search(clean, pos)
		if result == null:
			break
		pos = result.get_end()

		var type_token := result.get_string("type")
		var name := result.get_string("name")
		var array_text := result.get_string("array").strip_edges()
		var is_array := not array_text.is_empty()
		var array_size := -1
		if is_array:
			var inner := array_text.substr(1, array_text.length() - 2).strip_edges()
			if not inner.is_empty():
				array_size = int(inner)

		var parts := _extract_default_and_hint(result.get_string("rest"))

		var entry := {
			"name": name,
			"type": _uniform_type_name(type_token, parts["hint_text"]),
			"value": null,
			"default": null,
			"hint": _parse_hint(parts["hint_text"]),
			"_type_token": type_token,
			"_hint_text": parts["hint_text"],
			"_is_array": is_array
		}
		if is_array:
			entry["array"] = true
			entry["array_size"] = array_size
		if not parts["default_text"].is_empty():
			entry["default"] = _parse_literal(parts["default_text"], type_token, is_array)
		uniforms.append(entry)

	return uniforms


func _find_uniform_declaration(source: String, uniform_name: String) -> Dictionary:
	for uniform_entry in _parse_shader_uniforms(source):
		if str(uniform_entry["name"]) == uniform_name:
			return uniform_entry
	return {}


func _declared_uniform_names(source: String) -> Array:
	var names := []
	for uniform_entry in _parse_shader_uniforms(source):
		names.append(str(uniform_entry["name"]))
	return names


# Removes line and block comments so they never match as uniform declarations.
func _strip_shader_comments(source: String) -> String:
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


# Splits the tail of a uniform declaration into the optional '= default' and
# ': hint' parts. Godot allows either order (": hint = default" or
# "= default : hint"), so both positions are handled.
func _extract_default_and_hint(rest: String) -> Dictionary:
	var text := rest.strip_edges()
	var eq_index := text.find("=")
	var colon_index := text.find(":")
	var default_text := ""
	var hint_text := ""

	if eq_index != -1 and colon_index != -1:
		if colon_index < eq_index:
			hint_text = text.substr(colon_index + 1, eq_index - colon_index - 1)
			default_text = text.substr(eq_index + 1)
		else:
			default_text = text.substr(eq_index + 1, colon_index - eq_index - 1)
			hint_text = text.substr(colon_index + 1)
	elif eq_index != -1:
		default_text = text.substr(eq_index + 1)
	elif colon_index != -1:
		hint_text = text.substr(colon_index + 1)

	return {
		"default_text": default_text.strip_edges(),
		"hint_text": hint_text.strip_edges()
	}


func _uniform_type_name(type_token: String, hint_text: String) -> String:
	match type_token:
		"float":
			return "float"
		"int":
			return "int"
		"bool":
			return "bool"
		"vec2":
			return "vec2"
		"vec3":
			return "vec3"
		"vec4":
			return "color" if _hint_contains(hint_text, "source_color") else "vec4"
		"sampler2D":
			return "sampler2D"
		"sampler3D":
			return "sampler3D"
		"samplerCube":
			return "samplerCube"
		"mat2":
			return "mat2"
		"mat3":
			return "mat3"
		"mat4":
			return "transform"
	return type_token


func _hint_contains(hint_text: String, token: String) -> bool:
	return hint_text.find(token) != -1


# Structured hint where parseable (hint_range -> {type: "range", min, max, step}),
# otherwise the raw hint text.
func _parse_hint(hint_text: String) -> Variant:
	var text := hint_text.strip_edges()
	if text.is_empty():
		return ""
	if text == "source_color":
		return "source_color"

	var range_prefix := "hint_range("
	if text.begins_with(range_prefix) and text.ends_with(")"):
		var inner := text.substr(range_prefix.length(), text.length() - range_prefix.length() - 1)
		var parts := inner.split(",")
		if parts.size() >= 2:
			var result := { "type": "range" }
			result["min"] = parts[0].strip_edges().to_float()
			result["max"] = parts[1].strip_edges().to_float()
			if parts.size() >= 3:
				result["step"] = parts[2].strip_edges().to_float()
			return result

	return text


# Parses a uniform default literal into serialized form. Arrays use {...}
# syntax; vectors parse as vecN(...) with their components.
func _parse_literal(text: String, type_token: String, is_array: bool) -> Variant:
	var trimmed := text.strip_edges()
	if is_array or trimmed.begins_with("{"):
		var inner := trimmed
		if trimmed.begins_with("{") and trimmed.ends_with("}"):
			inner = trimmed.substr(1, trimmed.length() - 2)
		var parts := _split_top_level(inner, ",")
		var out := []
		for part in parts:
			out.append(_parse_scalar_literal(part.strip_edges(), type_token))
		return out
	return _parse_scalar_literal(trimmed, type_token)


func _parse_scalar_literal(text: String, type_token: String) -> Variant:
	if text == "true":
		return true
	if text == "false":
		return false
	match type_token:
		"int":
			return int(text)
		"float":
			return text.to_float()
		"vec2":
			return _parse_vec_literal(text, 2)
		"vec3":
			return _parse_vec_literal(text, 3)
		"vec4":
			return _parse_vec_literal(text, 4)
	return text


func _parse_vec_literal(text: String, expected_count: int) -> Array:
	var open := text.find("(")
	if open == -1:
		return []
	var inner := text.substr(open + 1)
	if inner.ends_with(")"):
		inner = inner.substr(0, inner.length() - 1)
	var parts := _split_top_level(inner, ",")
	var out := []
	for part in parts:
		var part_text := str(part).strip_edges()
		if part_text == "true":
			out.append(true)
		elif part_text == "false":
			out.append(false)
		else:
			out.append(part_text.to_float())
	# vecN(single_value) splats the value across all components.
	if out.size() == 1 and expected_count > 1:
		var value = out[0]
		out = []
		for i in expected_count:
			out.append(value)
	return out


# Splits on a separator character, ignoring separators inside () {} [] groups.
func _split_top_level(text: String, sep: String) -> Array:
	var parts := []
	var depth := 0
	var current := ""
	for i in text.length():
		var c := text[i]
		if c == "(" or c == "{" or c == "[":
			depth += 1
		elif c == ")" or c == "}" or c == "]":
			depth -= 1
		if c == sep and depth == 0:
			parts.append(current)
			current = ""
		else:
			current += c
	parts.append(current)
	return parts


# ---------------------------------------------------------------------------
# Value conversion (set_uniform) and serialization (replies)
# ---------------------------------------------------------------------------

# Converts a serialized value (number/bool/[x,y,z,w]/{r,g,b,a}/res:// string/
# 16-number array) into the proper Variant for the declared uniform type.
func _convert_uniform_value(type_token: String, hint_text: String, is_array: bool, array_size: int, value: Variant) -> Dictionary:
	if is_array:
		if typeof(value) != TYPE_ARRAY:
			return { "ok": false, "error": "Uniform is an array; provide an array of values" }
		if array_size >= 0 and value.size() != array_size:
			return { "ok": false, "error": "Expected exactly %d array values, received %d" % [array_size, value.size()] }
		var out := []
		for item in value:
			var converted := _convert_scalar_uniform_value(type_token, hint_text, item)
			if not converted["ok"]:
				return converted
			out.append(converted["value"])
		return { "ok": true, "value": out }
	return _convert_scalar_uniform_value(type_token, hint_text, value)


func _convert_scalar_uniform_value(type_token: String, hint_text: String, value: Variant) -> Dictionary:
	match type_token:
		"float":
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				return { "ok": true, "value": float(value) }
			return _value_type_error(type_token, value)
		"int":
			if typeof(value) == TYPE_INT:
				return { "ok": true, "value": value }
			if typeof(value) == TYPE_FLOAT and float(value) == floor(float(value)):
				return { "ok": true, "value": int(value) }
			return _value_type_error(type_token, value)
		"bool":
			if typeof(value) == TYPE_BOOL:
				return { "ok": true, "value": value }
			return _value_type_error(type_token, value)
		"vec2":
			return _convert_vec(value, 2, ["x", "y"])
		"vec3":
			return _convert_vec(value, 3, ["x", "y", "z"])
		"vec4":
			if _hint_contains(hint_text, "source_color"):
				return _convert_color(value)
			return _convert_vec(value, 4, ["x", "y", "z", "w"])
		"sampler2D", "sampler3D", "samplerCube":
			return _convert_texture(type_token, value)
		"transform", "mat4":
			return _convert_transform(value)
	return { "ok": false, "error": "Unsupported uniform type: %s" % type_token }


func _convert_vec(value: Variant, count: int, keys: Array) -> Dictionary:
	var numbers := _as_number_array(value, count, keys)
	if numbers.is_empty():
		return { "ok": false, "error": "Expected %d numbers (array or %s dict) for this uniform" % [count, _keys_hint(keys)] }
	match count:
		2:
			return { "ok": true, "value": Vector2(numbers[0], numbers[1]) }
		3:
			return { "ok": true, "value": Vector3(numbers[0], numbers[1], numbers[2]) }
		4:
			return { "ok": true, "value": Vector4(numbers[0], numbers[1], numbers[2], numbers[3]) }
	return { "ok": false, "error": "Unsupported vector size %d" % count }


func _convert_color(value: Variant) -> Dictionary:
	var numbers := _as_number_array(value, 4, ["r", "g", "b", "a"])
	if numbers.is_empty():
		return { "ok": false, "error": "Expected {r,g,b,a} or [r,g,b,a] for a color uniform" }
	return { "ok": true, "value": Color(numbers[0], numbers[1], numbers[2], numbers[3]) }


func _convert_texture(type_token: String, value: Variant) -> Dictionary:
	if value == null:
		return { "ok": true, "value": null }
	if typeof(value) != TYPE_STRING:
		return _value_type_error(type_token, value)
	var path := str(value).strip_edges().replace("\\", "/")
	if path.is_empty():
		return { "ok": true, "value": null }
	if not path.begins_with("res://") or path.split("/").has(".."):
		return { "ok": false, "error": "Texture path must stay inside res:// and cannot contain '..' segments: %s" % path }
	var texture := ResourceLoader.load(path)
	if texture == null:
		return { "ok": false, "error": "Failed to load texture: %s" % path }
	if not (texture is Texture2D or texture is Texture3D or texture is TextureLayered):
		return { "ok": false, "error": "Resource is not a texture: %s" % path }
	return { "ok": true, "value": texture }


func _convert_transform(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY or value.size() != 16:
		return { "ok": false, "error": "Expected a 16-number array for a transform uniform (column-major basis columns + origin)" }
	var nums := []
	for i in 16:
		var item = value[i]
		if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
			return { "ok": false, "error": "Transform values must be numbers" }
		nums.append(float(item))
	var basis := Basis(
		Vector3(nums[0], nums[1], nums[2]),
		Vector3(nums[4], nums[5], nums[6]),
		Vector3(nums[8], nums[9], nums[10])
	)
	var origin := Vector3(nums[12], nums[13], nums[14])
	return { "ok": true, "value": Transform3D(basis, origin) }


# Extracts exactly `count` numbers from an array (positional) or a dict (by key).
func _as_number_array(value: Variant, count: int, keys: Array) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		if value.size() != count:
			return []
		for i in count:
			var item = value[i]
			if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
				return []
			out.append(float(item))
	elif typeof(value) == TYPE_DICTIONARY:
		for key in keys:
			if not value.has(key):
				return []
			var item = value[key]
			if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
				return []
			out.append(float(item))
	return out


func _keys_hint(keys: Array) -> String:
	return "{%s}" % ",".join(keys)


func _value_type_error(type_token: String, value: Variant) -> Dictionary:
	return { "ok": false, "error": "Value %s is not valid for uniform type '%s'" % [str(value), type_token] }


# Serializes any Variant into primitives-only form safe for EngineDebugger
# round trips. Vectors become arrays, colors become {r,g,b,a}, transforms a
# 16-float column-major array, and resources their res:// path.
func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return [value.x, value.y]
		TYPE_VECTOR3:
			return [value.x, value.y, value.z]
		TYPE_VECTOR4:
			return [value.x, value.y, value.z, value.w]
		TYPE_COLOR:
			return { "r": value.r, "g": value.g, "b": value.b, "a": value.a }
		TYPE_TRANSFORM3D:
			return _serialize_transform(value)
		TYPE_ARRAY:
			var out := []
			for item in value:
				out.append(_serialize_value(item))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[key] = _serialize_value(value[key])
			return out
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var out := []
			for item in value:
				out.append(_serialize_value(item))
			return out
		TYPE_OBJECT:
			if value is Texture2D or value is Texture3D or value is TextureLayered:
				return value.resource_path
			if value is Material:
				return value.resource_path if not value.resource_path.is_empty() else "local"
			if value is Shader:
				return value.resource_path
			return ""
		TYPE_RID:
			return 0
	return str(value)


# Column-major 16-float form matching GLSL mat4 layout: three basis columns
# (x, y, z) each with a zero w, then origin with a 1.0 w.
func _serialize_transform(transform: Transform3D) -> Array:
	return [
		transform.basis.x.x, transform.basis.x.y, transform.basis.x.z, 0.0,
		transform.basis.y.x, transform.basis.y.y, transform.basis.y.z, 0.0,
		transform.basis.z.x, transform.basis.z.y, transform.basis.z.z, 0.0,
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0
	]


# ---------------------------------------------------------------------------
# Replies
# ---------------------------------------------------------------------------

func _send_result(request_id: int, payload: Dictionary) -> void:
	payload["request_id"] = request_id
	EngineDebugger.send_message("%s:result" % CAPTURE_NAME, [request_id, payload])


func _send_error(request_id: int, message: String) -> void:
	_send_result(request_id, { "success": false, "error": message })
