extends Node
## Runtime shader handler for MCP shader tools (Phase B).
##
## This script runs inside the GAME (not the editor), like mcp_input_handler.gd,
## and answers requests about ShaderMaterials in the live scene. It registers an
## EngineDebugger message capture named "mcp_shader" and handles these actions:
##   mcp_shader:list_materials    -> [request_id, node_path, material_slot]
##   mcp_shader:get_uniforms      -> [request_id, node_path, material_slot]
##   mcp_shader:set_uniform       -> [request_id, node_path, uniform_name, value, material_slot, allow_shared, shader_path]
##   mcp_shader:debug_snapshot    -> [request_id, node_path, material_slot]
##   mcp_shader:hot_reload        -> [request_id, shader_path, node_path, material_slot, content]
##   mcp_shader:capture           -> [request_id, output_path, return_base64, allow_large, node_path]
##   mcp_shader:debug_overlay     -> [request_id, mode, viewport_index]
##   mcp_shader:debug_visualize   -> [request_id, node_path, mode, expression, material_slot]
##   mcp_shader:reset_uniforms    -> [request_id, node_path, material_slot]
##   mcp_shader:reload_from_disk  -> [request_id, shader_path, node_path, material_slot]
##   mcp_shader:measure_frame_time -> [request_id, enable, viewport_index]
##
## Every reply is sent with EngineDebugger.send_message("mcp_shader:result",
## [request_id, payload]) where payload is a Dictionary of fully serializable
## primitives only (no Vector3/Color/Transform3D/Texture2D/RID Variants):
## vectors become {x,y,...} dicts, colors become {r,g,b,a}, transforms become
## float arrays (6 for Transform2D, 9 for Basis, 16 column-major for
## Transform3D), textures become {path,width,height,format} metadata, and
## materials/shaders become their res:// path.

const CAPTURE_NAME := "mcp_shader"

# Matches a single uniform declaration, e.g.
#   uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.25, 1.0);
#   uniform float weights[3] = { 0.1, 0.2, 0.3 };
# The "rest" group runs up to the terminating ';' and is parsed separately for
# the optional '= default' and ': hint' parts (either order).
const UNIFORM_REGEX_SOURCE := "\\buniform\\b\\s+(?P<type>[a-zA-Z_][a-zA-Z0-9_]*)\\s+(?P<name>[a-zA-Z_][a-zA-Z0-9_]*)(?P<array>\\[\\s*\\d*\\s*\\])?(?P<rest>[\\s\\S]*?);"
const SHADER_TYPE_REGEX_SOURCE := "shader_type\\s+([a-zA-Z_][a-zA-Z0-9_]*)"
const RENDER_MODE_REGEX_SOURCE := "render_mode\\s+([^;]+)"

# Capture defaults, mirroring the editor-side capture_scene command.
const CAPTURE_DIR := "user://mcp_captures"
const MAX_CAPTURE_PIXELS := 4000000

# Frames to wait after a hot reload before draining the shader error buffer:
# the renderer recompiles lazily on the next frame that uses the shader.
const RELOAD_ERROR_WAIT_FRAMES := 3

# Frames to wait after enabling render-time measurement before reading it:
# the first frames after enabling report 0.0.
const MEASURE_SETTLE_FRAMES := 3

# Visualization modes accepted by the debug_visualize action.
const VISUALIZE_MODES := ["uv", "normals", "screen_pos", "world_pos", "custom", "off"]

# Debug-draw overlay modes accepted by the debug_overlay action. Overdraw is
# intentionally excluded: it is inert on the Compatibility renderer.
const DEBUG_OVERLAY_MODES := ["wireframe", "normal", "off"]

var _uniform_regex := RegEx.new()
var _shader_type_regex := RegEx.new()
var _render_mode_regex := RegEx.new()

# Active shader_debug_visualize injections, keyed by node_path:
# { shader: Shader, code: String (original code), material_slot: String, mode: String }
var _visualize_registry := {}

# Per-viewport render-time measurement state (there is no RenderingServer
# getter for the measure flag, so the last requested state is tracked here).
var _measure_state := {}

func _init() -> void:
	_uniform_regex.compile(UNIFORM_REGEX_SOURCE)
	_shader_type_regex.compile(SHADER_TYPE_REGEX_SOURCE)
	_render_mode_regex.compile(RENDER_MODE_REGEX_SOURCE)

func _ready() -> void:
	# Only register in a running game, never in the editor.
	if Engine.is_editor_hint():
		return

	if not EngineDebugger.is_active():
		print("[MCP Shader Runtime] Debugger not active, shader runtime unavailable")
		return

	# Mirror the editor plugin (mcp_server.gd): install a shader compile-error
	# logger in the game process so hot reload can report live compile errors.
	_install_shader_error_logger()

	EngineDebugger.register_message_capture(CAPTURE_NAME, _on_capture)
	print("[MCP Shader Runtime] Shader runtime ready")


# Installs the MCPShaderErrorLogger into the game process. The same class the
# editor uses, exposed through Engine metadata; shader compile errors emitted
# by the renderer are captured for marker/drain correlation.
func _install_shader_error_logger() -> void:
	if Engine.has_meta("MCPShaderErrorLogger"):
		return
	var logger_script := load("res://addons/godot_mcp/mcp_shader_error_logger.gd")
	if logger_script == null:
		return
	var logger = logger_script.new()
	if logger == null:
		return
	OS.add_logger(logger)
	Engine.set_meta("MCPShaderErrorLogger", logger)


func _on_capture(message: String, data: Array) -> bool:
	var action := message.substr(CAPTURE_NAME.length() + 1) if message.begins_with(CAPTURE_NAME + ":") else message

	match action:
		"list_materials":
			return _handle_list_materials(data)
		"get_uniforms":
			return _handle_get_uniforms(data)
		"set_uniform":
			return _handle_set_uniform(data)
		"debug_snapshot":
			return _handle_debug_snapshot(data)
		"hot_reload":
			# Async handler: fire it and mark the message consumed. The reply is
			# sent when the coroutine finishes, and the editor polls for it.
			_handle_hot_reload(data)
			return true
		"capture":
			# Async handler: waits for the next rendered frame before replying.
			_handle_capture(data)
			return true
		"debug_overlay":
			return _handle_shader_debug_overlay(data)
		"debug_visualize":
			# Async handler: waits a few frames for compile feedback.
			_handle_shader_debug_visualize(data)
			return true
		"reset_uniforms":
			return _handle_shader_reset_uniforms(data)
		"reload_from_disk":
			# Async handler: waits a few frames for compile feedback.
			_handle_shader_reload_from_disk(data)
			return true
		"measure_frame_time":
			# Async handler: waits a few frames after enabling measurement.
			_handle_shader_measure_frame_time(data)
			return true

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
	var shader_path := str(data[6]) if data.size() > 6 else ""

	if uniform_name.is_empty():
		_send_error(request_id, "uniform_name is required")
		return true
	if shader_path.is_empty() and node_path.is_empty():
		_send_error(request_id, "Provide node_path or shader_path to locate the material")
		return true
	if not shader_path.is_empty() and not node_path.is_empty():
		_send_error(request_id, "Provide either node_path or shader_path, not both")
		return true

	# Shader-wide scope: apply the uniform to every material using the shader.
	# Materials shared by more than one node are skipped (recorded in
	# "skipped") unless allow_shared is set; a shared material never fails
	# the whole call.
	if not shader_path.is_empty():
		return _handle_set_uniform_shader_wide(request_id, shader_path, uniform_name, raw_value, material_slot, allow_shared)

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

	var converted := _coerce_uniform_value(
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


# Shader-wide variant of set_uniform (shader_path scope): applies the uniform
# to every material in the running game whose shader matches shader_path.
# Shared materials are skipped (with a recorded reason) unless allow_shared;
# skipping never fails the whole call.
func _handle_set_uniform_shader_wide(request_id: int, shader_path: String, uniform_name: String, raw_value: Variant, material_slot: String, allow_shared: bool) -> bool:
	var found := _find_shader_materials(shader_path, "", material_slot)
	if not found["ok"]:
		_send_error(request_id, found["error"])
		return true

	var materials: Array = found["materials"]
	if materials.is_empty():
		_send_error(request_id, "No materials in the running game use shader at %s" % shader_path)
		return true

	# All matched materials share the same .gdshader file, so validate and
	# coerce the value against the first shader's declaration.
	var shader: Shader = materials[0]["shader"]
	var uniform_def := _find_uniform_declaration(shader.code, uniform_name)
	if uniform_def.is_empty():
		var names := _declared_uniform_names(shader.code)
		var known := ""
		if not names.is_empty():
			known = " Known uniforms: %s" % ", ".join(names)
		_send_error(request_id, "Unknown uniform '%s' on shader %s.%s" % [uniform_name, shader.resource_path, known])
		return true

	var converted := _coerce_uniform_value(
		uniform_def["_type_token"],
		uniform_def["_hint_text"],
		uniform_def["_is_array"],
		int(uniform_def.get("array_size", -1)),
		raw_value
	)
	if not converted["ok"]:
		_send_error(request_id, converted["error"])
		return true

	var affected := []
	var skipped := []
	for entry in materials:
		var material: ShaderMaterial = entry["material"]
		var sharing := _find_material_sharing(material)
		if sharing["users_count"] > 1 and not allow_shared:
			skipped.append({
				"node_path": entry["node_path"],
				"reason": "shared by %d nodes; set allow_shared=true to modify" % sharing["users_count"]
			})
			continue
		material.set_shader_parameter(uniform_name, converted["value"])
		affected.append({
			"node_path": entry["node_path"],
			"material_path": entry["material_path"]
		})

	_send_result(request_id, {
		"success": true,
		"uniform_name": uniform_name,
		"value": _serialize_value(converted["value"]),
		"affected": affected,
		"skipped": skipped,
		"count": affected.size()
	})
	return true


func _handle_debug_snapshot(data: Array) -> bool:
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

	var code := shader.code
	var uniforms := _parse_shader_uniforms(code)
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
		"shader_path": shader.resource_path if not shader.resource_path.is_empty() else "local",
		"shader_type": _shader_type_of(code),
		"render_modes": _render_modes_of(code),
		"code": code,
		"uniforms": uniforms,
		"sharing": _find_material_sharing(material)
	})
	return true


func _handle_hot_reload(data: Array) -> bool:
	if data.size() < 5:
		return false

	var request_id := int(data[0])
	var shader_path := str(data[1])
	var node_path := str(data[2])
	var material_slot := str(data[3]) if data.size() > 3 else "material"
	var content := str(data[4]) if data.size() > 4 else ""

	if content.strip_edges().is_empty():
		_send_error(request_id, "content is required")
		return true
	if shader_path.is_empty() and node_path.is_empty():
		_send_error(request_id, "Provide shader_path or node_path")
		return true

	var found := _find_shader_materials(shader_path, node_path, material_slot)
	if not found["ok"]:
		_send_error(request_id, found["error"])
		return true

	var materials: Array = found["materials"]
	if materials.is_empty():
		var target := shader_path if not shader_path.is_empty() else node_path
		_send_error(request_id, "No materials in the running game use shader at %s" % target)
		return true

	# Apply the new code to every distinct Shader instance among the matched
	# materials. Setting Shader.code recompiles lazily on next use, so all
	# materials sharing an instance switch to the new code immediately.
	var seen_shaders := {}
	var previous_code := ""
	for entry in materials:
		var shader: Shader = entry["shader"]
		if shader == null:
			continue
		var shader_id := shader.get_instance_id()
		if seen_shaders.has(shader_id):
			continue
		seen_shaders[shader_id] = true
		if previous_code.is_empty():
			previous_code = shader.code
		shader.code = content

	# Re-apply existing parameter values through the shared coercion helper so
	# values keep working when the new code changes a uniform's type. Failed
	# coercion (e.g. a scalar that no longer fits a vector) keeps the shader
	# default; the reload itself still succeeded.
	var uniforms := _parse_shader_uniforms(content)
	for entry in materials:
		var material: ShaderMaterial = entry["material"]
		for uniform_entry in uniforms:
			var name := str(uniform_entry["name"])
			var raw_value = material.get_shader_parameter(name)
			# A runtime-created texture without a res:// path cannot be re-derived
			# from its serialized form; leave the material's own value in place.
			if raw_value is Texture2D or raw_value is Texture3D or raw_value is TextureLayered:
				if raw_value.resource_path.is_empty():
					continue
			var converted := _coerce_uniform_value(
				str(uniform_entry["_type_token"]),
				str(uniform_entry["_hint_text"]),
				bool(uniform_entry["_is_array"]),
				int(uniform_entry.get("array_size", -1)),
				raw_value
			)
			if converted["ok"]:
				material.set_shader_parameter(name, converted["value"])

	# Give the renderer a few frames to lazily compile the new code, then drain
	# any shader compile errors the game-side logger captured in that window.
	var logger = _get_shader_logger()
	var marker: int = logger.record_marker() if logger != null else -1
	for _i in range(RELOAD_ERROR_WAIT_FRAMES):
		await get_tree().process_frame
	var compile_errors := []
	if logger != null:
		compile_errors = _entries_to_diagnostics(logger.drain_since(marker), found["shader_path"])

	var affected := []
	for entry in materials:
		affected.append({
			"node_path": entry["node_path"],
			"slot": entry["slot"],
			"material_path": entry["material_path"]
		})

	_send_result(request_id, {
		"success": true,
		"shader_path": found["shader_path"],
		"affected_materials": affected,
		"previous_code": previous_code,
		"compile_errors": compile_errors
	})
	return true


# Captures the game's current rendered frame. The root viewport texture is read
# after the next RenderingServer.frame_post_draw signal instead of calling
# force_draw() on the live viewport (which risks stalling the render thread).
# This accepts up to one frame of latency: a uniform set in the same turn may
# still show the pre-change frame.
func _handle_capture(data: Array) -> bool:
	if data.size() < 1:
		return false

	var request_id := int(data[0])
	var output_path := str(data[1]) if data.size() > 1 else ""
	var return_base64 := bool(data[2]) if data.size() > 2 else false
	var allow_large := bool(data[3]) if data.size() > 3 else false
	var node_path := str(data[4]) if data.size() > 4 else ""

	await RenderingServer.frame_post_draw

	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		_send_error(request_id, "Failed to read the rendered frame from the root viewport")
		return true

	var original_width := img.get_width()
	var original_height := img.get_height()
	var cropped := false

	# Optional node_path crop: restrict the capture to the node's on-screen
	# region. Only 2D nodes (CanvasItem/Control) are supported in v1.
	if not node_path.is_empty():
		var crop := _resolve_node_crop_rect(node_path, Vector2(original_width, original_height))
		if not crop["ok"]:
			_send_error(request_id, crop["error"])
			return true
		var crop_rect: Rect2i = crop["rect"]
		crop_rect = crop_rect.intersection(Rect2i(0, 0, original_width, original_height))
		if crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
			_send_error(request_id, "Node %s is off-screen or has empty bounds within the viewport" % node_path)
			return true
		img = img.get_region(crop_rect)
		cropped = true

	# The 4MP cap applies to the final capture size (the cropped size when a
	# node_path crop is active).
	if img.get_width() * img.get_height() > MAX_CAPTURE_PIXELS and not allow_large:
		_send_error(request_id, "Capture size %dx%d exceeds the 4MP default limit; set allow_large=true to override" % [img.get_width(), img.get_height()])
		return true

	var bytes := img.save_png_to_buffer()
	if bytes.is_empty():
		_send_error(request_id, "Failed to encode PNG image")
		return true

	var save_path := _resolve_capture_path(output_path)
	if not _write_png_bytes(bytes, save_path):
		_send_error(request_id, "Failed to write PNG file: %s" % save_path)
		return true

	var result := {
		"success": true,
		"file_path": save_path,
		"absolute_path": ProjectSettings.globalize_path(save_path),
		"width": img.get_width(),
		"height": img.get_height(),
		"original_width": original_width,
		"original_height": original_height,
		"cropped": cropped
	}
	if return_base64:
		result["image_base64"] = Marshalls.raw_to_base64(bytes)

	_send_result(request_id, result)
	return true


# Computes the on-screen pixel rect of a node in viewport coordinates, for
# capture cropping. CanvasItems use get_global_transform_with_canvas() applied
# to the node's local bounds (get_rect() when available, else a 1x1 point);
# Controls use get_global_rect(). Returns { ok, rect: Rect2i, error }.
func _resolve_node_crop_rect(node_path: String, viewport_size: Vector2) -> Dictionary:
	var node := _find_node(node_path)
	if node == null:
		return { "ok": false, "error": "Node not found in running game: %s" % node_path }

	if node is Node3D and not node is CanvasItem:
		return { "ok": false, "error": "node_path cropping is only supported for 2D nodes (CanvasItem/Control) in v1; %s is a %s" % [node_path, node.get_class()] }

	var global_rect := Rect2()
	if node is Control:
		global_rect = (node as Control).get_global_rect()
	elif node is CanvasItem:
		var item := node as CanvasItem
		var local_rect := Rect2(Vector2.ZERO, Vector2.ONE)
		if node.has_method("get_rect"):
			var node_rect: Variant = node.call("get_rect")
			if node_rect is Rect2:
				local_rect = node_rect
		global_rect = item.get_global_transform_with_canvas() * local_rect
	else:
		return { "ok": false, "error": "node_path cropping is only supported for 2D nodes (CanvasItem/Control) in v1; %s is a %s" % [node_path, node.get_class()] }

	var clipped := global_rect.intersection(Rect2(Vector2.ZERO, viewport_size))
	if clipped.size.x <= 0.0 or clipped.size.y <= 0.0:
		return { "ok": false, "error": "Node %s is off-screen or has empty bounds within the viewport" % node_path }

	return {
		"ok": true,
		"rect": Rect2i(
			floori(clipped.position.x),
			floori(clipped.position.y),
			maxi(1, ceili(clipped.size.x)),
			maxi(1, ceili(clipped.size.y))
		)
	}


# Applies a Viewport debug-draw mode in the running game for visual shader
# debugging: "wireframe", "normal" (NORMAL_BUFFER, Forward+ only), or "off"
# (reset to the default). Unsupported mode/renderer combinations return a
# clean error instead of crashing; renderer caveats are reported in the reply.
func _handle_shader_debug_overlay(data: Array) -> bool:
	if data.size() < 2:
		return false

	var request_id := int(data[0])
	var mode := str(data[1])
	var viewport_index := int(data[2]) if data.size() > 2 else 0

	if not DEBUG_OVERLAY_MODES.has(mode):
		_send_error(request_id, "Unknown mode '%s'; expected one of: %s" % [mode, ", ".join(DEBUG_OVERLAY_MODES)])
		return true

	var resolved := _resolve_debug_overlay_viewport(viewport_index)
	if not resolved["ok"]:
		_send_error(request_id, resolved["error"])
		return true

	var renderer := str(RenderingServer.get_current_rendering_method())

	var debug_draw := RenderingServer.VIEWPORT_DEBUG_DRAW_DISABLED
	var caveat := ""
	match mode:
		"wireframe":
			debug_draw = RenderingServer.VIEWPORT_DEBUG_DRAW_WIREFRAME
			if renderer == "gl_compatibility":
				# Compatibility only generates wireframes when explicitly enabled,
				# and only for meshes loaded after the call. Set the flag anyway
				# and report the limitation in the reply.
				RenderingServer.set_debug_generate_wireframes(true)
				caveat = "Wireframe generation enabled for gl_compatibility, but it only affects meshes loaded after this call; already-loaded meshes may not display wireframes"
		"normal":
			if renderer != "forward_plus":
				_send_error(request_id, "Mode 'normal' (NORMAL_BUFFER) requires the Forward+ renderer; the running game uses '%s'" % renderer)
				return true
			debug_draw = RenderingServer.VIEWPORT_DEBUG_DRAW_NORMAL_BUFFER
		"off":
			debug_draw = RenderingServer.VIEWPORT_DEBUG_DRAW_DISABLED
		_:
			_send_error(request_id, "Mode '%s' is not supported by the debug overlay" % mode)
			return true

	RenderingServer.viewport_set_debug_draw(resolved["viewport"].get_viewport_rid(), debug_draw)

	var payload := {
		"success": true,
		"mode": mode,
		"renderer": renderer,
		"viewport_index": viewport_index
	}
	if not caveat.is_empty():
		payload["wireframe_generated"] = true
		payload["caveat"] = caveat

	_send_result(request_id, payload)
	return true


# ---------------------------------------------------------------------------
# Phase D runtime handlers
# ---------------------------------------------------------------------------

# Temporarily injects visualization code into the RUNNING game's shader for
# one material (node_path). Never writes files: the modified code lives only
# in the live Shader resource and is restored exactly by mode=off (registry
# stores the original Shader + code + slot). If the injected variant fails to
# compile, the original code is restored and the compile errors reported.
func _handle_shader_debug_visualize(data: Array) -> bool:
	if data.size() < 3:
		return false

	var request_id := int(data[0])
	var node_path := str(data[1])
	var mode := str(data[2])
	var expression := str(data[3]) if data.size() > 3 else ""
	var material_slot := str(data[4]) if data.size() > 4 else "material"

	if not VISUALIZE_MODES.has(mode):
		_send_error(request_id, "Unknown mode '%s'; expected one of: %s" % [mode, ", ".join(VISUALIZE_MODES)])
		return true
	if mode == "custom" and expression.strip_edges().is_empty():
		_send_error(request_id, "expression is required when mode=custom")
		return true

	if mode == "off":
		return _restore_visualization(request_id, node_path)

	var resolved := _resolve_material(node_path, material_slot)
	if not resolved["ok"]:
		_send_error(request_id, resolved["error"])
		return true

	var material: ShaderMaterial = resolved["material"]
	var shader := material.shader
	if shader == null:
		_send_error(request_id, "Material on %s has no shader" % resolved["node_path"])
		return true

	var shader_type := _shader_type_of(shader.code)
	if shader_type != "canvas_item" and shader_type != "spatial":
		_send_error(request_id, "shader_debug_visualize supports only canvas_item and spatial shaders; found '%s'" % shader_type)
		return true

	var injected := _build_visualization_code(shader.code, shader_type, mode, expression)
	if not injected["ok"]:
		_send_error(request_id, injected["error"])
		return true

	# Register before applying so mode=off can restore exactly even when the
	# injected variant fails to compile. The FIRST recorded code is kept across
	# mode switches: changing uv->normals without an intermediate mode=off must
	# still restore the genuine original baseline, not the prior injection.
	var original_code := shader.code
	var is_first := not _visualize_registry.has(node_path)
	var previous_mode := ""
	if is_first:
		_visualize_registry[node_path] = {
			"shader": shader,
			"code": original_code,
			"material_slot": material_slot,
			"mode": mode
		}
	else:
		var existing: Dictionary = _visualize_registry[node_path]
		previous_mode = str(existing.get("mode", mode))
		existing["mode"] = mode
	shader.code = injected["code"]

	# Give the renderer a few frames to lazily compile the injected code, then
	# drain any compile errors the game-side logger captured in that window.
	var logger = _get_shader_logger()
	var marker: int = logger.record_marker() if logger != null else -1
	for _i in range(RELOAD_ERROR_WAIT_FRAMES):
		await get_tree().process_frame
	var compile_errors := []
	if logger != null:
		compile_errors = _entries_to_diagnostics(logger.drain_since(marker), shader.resource_path)

	var rolled_back := false
	if not compile_errors.is_empty():
		# Restore the code that was live before this injection. When this was
		# the first (or only) active visualization, drop the registry entry;
		# otherwise keep the original baseline and revert the recorded mode so
		# a later mode=off still restores the genuine original.
		shader.code = original_code
		if is_first:
			_visualize_registry.erase(node_path)
		else:
			_visualize_registry[node_path]["mode"] = previous_mode
		rolled_back = true

	_send_result(request_id, {
		"success": true,
		"mode": mode,
		"shader_type": shader_type,
		"injected": injected["snippet"],
		"original_code": original_code,
		"compile_errors": compile_errors,
		"rolled_back": rolled_back,
		"restore_note": "call shader_debug_visualize with mode=off to restore",
		"renderer": str(RenderingServer.get_current_rendering_method())
	})
	return true


# Restores the original shader code for a node with an active visualization.
# Replies with restored=false when nothing is registered for the node.
func _restore_visualization(request_id: int, node_path: String) -> bool:
	if not _visualize_registry.has(node_path):
		_send_result(request_id, {
			"success": true,
			"mode": "off",
			"restored": false,
			"note": "Nothing to restore for %s: no active visualization registered" % node_path
		})
		return true

	var entry: Dictionary = _visualize_registry[node_path]
	var shader: Shader = entry["shader"]
	shader.code = entry["code"]
	_visualize_registry.erase(node_path)

	_send_result(request_id, {
		"success": true,
		"mode": "off",
		"restored": true,
		"previous_mode": entry["mode"],
		"shader_type": _shader_type_of(entry["code"]),
		"renderer": str(RenderingServer.get_current_rendering_method())
	})
	return true


# Builds the injected shader code for a visualization mode. Returns
# { ok, code, snippet, error }. Only canvas_item and spatial are supported;
# statements are appended to the existing fragment()/vertex() bodies (created
# when missing), and world_pos adds a global varying.
func _build_visualization_code(code: String, shader_type: String, mode: String, expression: String) -> Dictionary:
	var is_canvas := shader_type == "canvas_item"
	var out_name := "COLOR" if is_canvas else "ALBEDO"

	var fragment_statement := ""
	var snippet := ""
	match mode:
		"uv":
			fragment_statement = "%s = vec4(UV, 0.0, 1.0);" % out_name if is_canvas else "%s = vec3(UV, 0.0);" % out_name
			snippet = fragment_statement
		"normals":
			fragment_statement = "%s = vec4(NORMAL * 0.5 + 0.5, 1.0);" % out_name if is_canvas else "%s = NORMAL * 0.5 + 0.5;" % out_name
			snippet = fragment_statement
		"screen_pos":
			fragment_statement = "%s = vec4(fract(FRAGCOORD.xy * 0.01), 0.0, 1.0);" % out_name if is_canvas else "%s = vec3(fract(FRAGCOORD.xy * 0.01), 0.0);" % out_name
			snippet = fragment_statement
		"custom":
			fragment_statement = "%s = %s;" % [out_name, expression.strip_edges()]
			snippet = fragment_statement
		"world_pos":
			var varying := "varying vec3 mcp_world_pos;"
			# VERTEX is vec3 in spatial but vec2 in canvas_item, so the canvas
			# variant needs an explicit z component for the vec4 swizzle.
			var vertex_statement := "mcp_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;" if not is_canvas else "mcp_world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xyz;"
			fragment_statement = "%s = vec4(mcp_world_pos * 0.1, 1.0);" % out_name if is_canvas else "%s = mcp_world_pos * 0.1;" % out_name
			snippet = "%s\n%s\n%s" % [varying, vertex_statement, fragment_statement]

			# The varying must be declared at global scope BEFORE any function
			# that references it. Godot's shader language rejects forward
			# references to varyings (verified on 4.5: "Unknown identifier"
			# when a varying is appended after the functions that use it), so
			# it is inserted right after the shader_type/render_mode header.
			code = _insert_global_declaration(code, varying)

			var vertex_injected := _inject_statement_into_function(code, "vertex", vertex_statement)
			if not vertex_injected["ok"]:
				return { "ok": false, "error": vertex_injected["error"] }
			code = vertex_injected["code"]
		_:
			return { "ok": false, "error": "Mode '%s' is not supported by shader_debug_visualize" % mode }

	var fragment_injected := _inject_statement_into_function(code, "fragment", fragment_statement)
	if not fragment_injected["ok"]:
		return { "ok": false, "error": fragment_injected["error"] }

	return { "ok": true, "code": fragment_injected["code"], "snippet": snippet }


# Appends `statement` to the body of `function_name` (inserted before the
# closing brace). When the function does not exist, a new `void <name>()`
# function is appended to the source. Returns { ok, code, error }.
func _inject_statement_into_function(code: String, function_name: String, statement: String) -> Dictionary:
	var function_regex := RegEx.new()
	function_regex.compile("(?:^|\n)\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s+)?" + function_name + "\\s*\\(\\s*\\)\\s*\\{")
	var match := function_regex.search(code)
	if match == null:
		# No existing function: append a new one at the end of the file.
		var new_function := "\n\nvoid %s() {\n\t%s\n}\n" % [function_name, statement]
		return { "ok": true, "code": code + new_function }

	# Brace-match from the opening brace to find the closing one.
	var body_start := match.get_end() - 1
	var depth := 0
	var close_pos := -1
	for i in range(body_start, code.length()):
		var c := code[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				close_pos = i
				break
	if close_pos == -1:
		return { "ok": false, "error": "Failed to locate the closing brace of %s()" % function_name }

	var injected_code := code.substr(0, close_pos) + "\n\t" + statement + code.substr(close_pos)
	return { "ok": true, "code": injected_code }


# Inserts a global-scope declaration (e.g. a varying) right after the
# shader_type/render_mode header, before any function definition. Godot's
# shader language requires varyings to be declared before the functions that
# reference them, so the declaration cannot simply be appended at the end.
func _insert_global_declaration(code: String, declaration: String) -> String:
	var header_end := 0
	var shader_type_match := _shader_type_regex.search(code)
	if shader_type_match != null:
		header_end = shader_type_match.get_end()
	var render_mode_match := _render_mode_regex.search(code)
	if render_mode_match != null and render_mode_match.get_end() > header_end:
		header_end = render_mode_match.get_end()
	# Position at the end of the header line (after its newline) so the
	# declaration lands at the start of global scope, not mid-line.
	var line_end := code.find("\n", header_end)
	if line_end == -1:
		line_end = code.length()
	return code.substr(0, line_end) + "\n" + declaration + code.substr(line_end)


# Resets every shader parameter of the material to its declared default.
# Defaults come from Shader.get_shader_uniform_list() when the engine
# provides them (it does not in Godot 4.5: the entries are PropertyInfo
# dicts without default_value), falling back to the regex-parsed defaults;
# a null default clears the parameter override so the engine default applies.
func _handle_shader_reset_uniforms(data: Array) -> bool:
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

	var uniform_list: Array = shader.get_shader_uniform_list()
	var defaults_by_name := {}
	for uniform_entry in _parse_shader_uniforms(shader.code):
		defaults_by_name[str(uniform_entry["name"])] = uniform_entry["default"]

	var reset := []
	for entry in uniform_list:
		var name := str(entry.get("name", ""))
		if name.is_empty():
			continue
		var default_value: Variant = null
		if entry.has("default_value"):
			default_value = entry["default_value"]
		elif defaults_by_name.has(name):
			default_value = defaults_by_name[name]
		# No declared default (array/sampler without one): null clears the
		# override, which is exactly the shader's built-in default.
		material.set_shader_parameter(name, default_value)
		reset.append({ "name": name, "value": _serialize_value(default_value) })

	_send_result(request_id, {
		"success": true,
		"node_path": resolved["node_path"],
		"slot": resolved["slot"],
		"reset": reset,
		"count": reset.size()
	})
	return true


# Reloads a shader's code from its .gdshader file on disk and applies it live
# to every material using the shader (same lookup as shader_hot_reload). When
# the live code already equals the disk content, replies unchanged=true and
# skips the reapply. previous_code is the rollback path: re-call with the
# shader code set back to it via shader_hot_reload.
func _handle_shader_reload_from_disk(data: Array) -> bool:
	if data.size() < 4:
		return false

	var request_id := int(data[0])
	var shader_path := str(data[1])
	var node_path := str(data[2])
	var material_slot := str(data[3]) if data.size() > 3 else "material"

	if shader_path.is_empty() and node_path.is_empty():
		_send_error(request_id, "Provide shader_path or node_path")
		return true

	var found := _find_shader_materials(shader_path, node_path, material_slot)
	if not found["ok"]:
		_send_error(request_id, found["error"])
		return true

	var resolved_path := str(found["shader_path"])
	if resolved_path.is_empty() or resolved_path == "local" or not resolved_path.ends_with(".gdshader"):
		_send_error(request_id, "Shader is not a standalone .gdshader file (%s); reload from disk requires a res:// file" % resolved_path)
		return true

	var file := FileAccess.open(resolved_path, FileAccess.READ)
	if file == null:
		_send_error(request_id, "Failed to read shader file from disk: %s" % resolved_path)
		return true
	var disk_content := file.get_as_text()
	file = null  # Close the file

	var materials: Array = found["materials"]
	if materials.is_empty():
		_send_error(request_id, "No materials in the running game use shader at %s" % resolved_path)
		return true

	var previous_code := ""
	for entry in materials:
		var shader: Shader = entry["shader"]
		if shader != null:
			previous_code = shader.code
			break

	var affected := []
	for entry in materials:
		affected.append({
			"node_path": entry["node_path"],
			"slot": entry["slot"],
			"material_path": entry["material_path"]
		})

	if previous_code == disk_content:
		_send_result(request_id, {
			"success": true,
			"shader_path": resolved_path,
			"affected_materials": affected,
			"applied_code": disk_content,
			"previous_code": previous_code,
			"file_read": true,
			"file_error": "",
			"compile_errors": [],
			"unchanged": true
		})
		return true

	# Apply the disk content to every distinct Shader instance among the
	# matched materials (same semantics as hot reload).
	var seen_shaders := {}
	for entry in materials:
		var shader: Shader = entry["shader"]
		if shader == null:
			continue
		var shader_id := shader.get_instance_id()
		if seen_shaders.has(shader_id):
			continue
		seen_shaders[shader_id] = true
		shader.code = disk_content

	# Re-apply existing parameter values through the shared coercion helper so
	# values keep working when the disk content changed a uniform's type.
	var uniforms := _parse_shader_uniforms(disk_content)
	for entry in materials:
		var material: ShaderMaterial = entry["material"]
		for uniform_entry in uniforms:
			var name := str(uniform_entry["name"])
			var raw_value = material.get_shader_parameter(name)
			if raw_value is Texture2D or raw_value is Texture3D or raw_value is TextureLayered:
				if raw_value.resource_path.is_empty():
					continue
			var converted := _coerce_uniform_value(
				str(uniform_entry["_type_token"]),
				str(uniform_entry["_hint_text"]),
				bool(uniform_entry["_is_array"]),
				int(uniform_entry.get("array_size", -1)),
				raw_value
			)
			if converted["ok"]:
				material.set_shader_parameter(name, converted["value"])

	# Give the renderer a few frames to lazily compile the new code, then drain
	# any shader compile errors the game-side logger captured in that window.
	var logger = _get_shader_logger()
	var marker: int = logger.record_marker() if logger != null else -1
	for _i in range(RELOAD_ERROR_WAIT_FRAMES):
		await get_tree().process_frame
	var compile_errors := []
	if logger != null:
		compile_errors = _entries_to_diagnostics(logger.drain_since(marker), resolved_path)

	_send_result(request_id, {
		"success": true,
		"shader_path": resolved_path,
		"affected_materials": affected,
		"applied_code": disk_content,
		"previous_code": previous_code,
		"file_read": true,
		"file_error": "",
		"compile_errors": compile_errors,
		"unchanged": false
	})
	return true


# Reads (and optionally toggles) the viewport's render-time measurement.
# Units are milliseconds (verified empirically against the running game on
# Godot 4.5.1 Forward+). enable omitted -> read without changing state;
# enable=true -> enable then wait a few frames (first frames report 0.0);
# enable=false -> disable and read the last measured values.
func _handle_shader_measure_frame_time(data: Array) -> bool:
	if data.size() < 1:
		return false

	var request_id := int(data[0])
	var has_enable := data.size() > 1 and data[1] != null
	var enable := bool(data[1]) if has_enable else false
	var viewport_index := int(data[2]) if data.size() > 2 else 0

	var resolved := _resolve_debug_overlay_viewport(viewport_index)
	if not resolved["ok"]:
		_send_error(request_id, resolved["error"])
		return true

	var viewport: Viewport = resolved["viewport"]
	var rid := viewport.get_viewport_rid()

	if has_enable:
		RenderingServer.viewport_set_measure_render_time(rid, enable)
		_measure_state[rid] = enable

	if has_enable and enable:
		# The first frames after enabling report 0.0; let the measurement
		# settle before reading.
		for _i in range(MEASURE_SETTLE_FRAMES):
			await get_tree().process_frame

	var gpu_ms := float(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	var cpu_ms := float(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	var enabled := bool(_measure_state.get(rid, false))

	_send_result(request_id, {
		"success": true,
		"gpu_ms": gpu_ms,
		"cpu_ms": cpu_ms,
		"enabled": enabled,
		"viewport_index": viewport_index,
		"renderer": str(RenderingServer.get_current_rendering_method()),
		"note": "Measurement is per-viewport, not per-shader; to compare shaders, toggle the shader change and measure again"
	})
	return true


# Resolves the target Viewport for the debug overlay: index 0 (the default)
# is the root viewport; a positive index selects the Nth Viewport child of
# the root (1-based). Returns { ok, viewport, viewport_count, error }.
func _resolve_debug_overlay_viewport(viewport_index: int) -> Dictionary:
	var root_viewport := get_tree().root
	if viewport_index <= 0:
		return { "ok": true, "viewport": root_viewport, "viewport_count": 0 }

	var viewports := []
	for child in root_viewport.get_children():
		if child is Viewport:
			viewports.append(child)
	if viewport_index - 1 < viewports.size():
		return { "ok": true, "viewport": viewports[viewport_index - 1], "viewport_count": viewports.size() }

	return {
		"ok": false,
		"viewport_count": viewports.size(),
		"error": "Viewport index %d not found: the root viewport has %d Viewport child(ren)" % [viewport_index, viewports.size()]
	}


# Returns { ok, materials, shader_path, error } where materials is an Array of
# { node_path, slot, material_path, material, shader } entries for every
# ShaderMaterial in the scene whose shader matches the target.
# - node_path mode: the shader behind the material in that slot, matched by
#   instance id plus resource path (so separately-loaded copies of the same
#   .gdshader file are included). A local shader (no resource_path) matches
#   only its own instance, which in practice is the single material.
# - shader_path mode: every shader whose resource_path equals the given path.
func _find_shader_materials(shader_path: String, node_path: String, material_slot: String) -> Dictionary:
	var normalized_target := shader_path.strip_edges().replace("\\", "/")
	if not normalized_target.is_empty() and not normalized_target.begins_with("res://"):
		normalized_target = "res://" + normalized_target

	var target_instance_id := 0
	var target_path := ""
	if not node_path.is_empty():
		var resolved := _resolve_material(node_path, material_slot)
		if not resolved["ok"]:
			return { "ok": false, "error": resolved["error"] }
		var shader: Shader = resolved["material"].shader
		if shader == null:
			return { "ok": false, "error": "Material on %s has no shader" % resolved["node_path"] }
		target_instance_id = shader.get_instance_id()
		target_path = shader.resource_path

	var materials := []
	for pair in _collect_material_pairs(_get_scene_root()):
		var material: Material = pair["material"]
		if not material is ShaderMaterial:
			continue
		var shader := (material as ShaderMaterial).shader
		if shader == null:
			continue
		var matches := false
		if not node_path.is_empty():
			matches = shader.get_instance_id() == target_instance_id
			if not matches and not target_path.is_empty() and shader.resource_path == target_path:
				matches = true
		elif not normalized_target.is_empty():
			matches = shader.resource_path == normalized_target
		if not matches:
			continue
		materials.append({
			"node_path": str(pair["node_path"]),
			"slot": str(pair["slot"]),
			"material_path": material.resource_path if not material.resource_path.is_empty() else "local",
			"material": material,
			"shader": shader
		})

	var result_path := normalized_target if node_path.is_empty() else target_path
	if result_path.is_empty():
		result_path = "local"

	return {
		"ok": true,
		"materials": materials,
		"shader_path": result_path
	}


func _shader_type_of(code: String) -> String:
	var result := _shader_type_regex.search(code)
	if result == null:
		return ""
	return result.get_string(1)


func _render_modes_of(code: String) -> Array:
	var result := _render_mode_regex.search(code)
	if result == null:
		return []
	var modes := []
	for mode in result.get_string(1).split(","):
		var trimmed := mode.strip_edges()
		if not trimmed.is_empty():
			modes.append(trimmed)
	return modes


func _get_shader_logger():
	if Engine.has_meta("MCPShaderErrorLogger"):
		var logger = Engine.get_meta("MCPShaderErrorLogger")
		if logger and logger.has_method("record_marker") and logger.has_method("drain_since"):
			return logger
	return null


# Converts raw logger entries into { line, message, severity } diagnostics,
# excluding entries attributed to a different shader file when one is known
# (attribution is often empty under GL Compatibility, so those pass through).
func _entries_to_diagnostics(entries: Array, shader_path: String) -> Array:
	var diagnostics := []
	for entry in entries:
		var entry_file: String = entry.get("file", "")
		if shader_path != "local" and not shader_path.is_empty() and not entry_file.is_empty() and entry_file != shader_path:
			continue
		var diagnostic := {
			"line": int(entry.get("line", 0)),
			"message": entry.get("message", ""),
			"severity": entry.get("severity", "error")
		}
		if not diagnostics.has(diagnostic):
			diagnostics.append(diagnostic)
	return diagnostics


func _resolve_capture_path(output_path: String) -> String:
	if output_path.is_empty():
		var timestamp := int(Time.get_unix_time_from_system())
		return "%s/capture_%d.png" % [CAPTURE_DIR, timestamp]
	if output_path.to_lower().ends_with(".png"):
		return output_path
	return output_path + ".png"


func _write_png_bytes(bytes: PackedByteArray, path: String) -> bool:
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var absolute_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(absolute_dir):
			var err := DirAccess.make_dir_recursive_absolute(absolute_dir)
			if err != OK:
				return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file = null  # Close the file
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
# parse fields (_type_token/_hint_text/_is_array) used by set_uniform and
# hot reload.
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
			entry["default"] = _serialize_value(_parse_literal(parts["default_text"], type_token, parts["hint_text"], is_array))
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


# Parses a uniform default literal into a native Variant (Vector2/Color/...),
# then serialized canonically by the caller. Arrays use {...} syntax; vectors
# parse as vecN(...) with their components; source_color vec4s become Colors.
func _parse_literal(text: String, type_token: String, hint_text: String, is_array: bool) -> Variant:
	var trimmed := text.strip_edges()
	if is_array or trimmed.begins_with("{"):
		var inner := trimmed
		if trimmed.begins_with("{") and trimmed.ends_with("}"):
			inner = trimmed.substr(1, trimmed.length() - 2)
		var parts := _split_top_level(inner, ",")
		var out := []
		for part in parts:
			out.append(_parse_scalar_literal(part.strip_edges(), type_token, hint_text))
		return out
	return _parse_scalar_literal(trimmed, type_token, hint_text)


func _parse_scalar_literal(text: String, type_token: String, hint_text: String) -> Variant:
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
			if _hint_contains(hint_text, "source_color"):
				return _parse_color_literal(text)
			return _parse_vec_literal(text, 4)
	return text


func _parse_vec_literal(text: String, expected_count: int) -> Variant:
	var open := text.find("(")
	if open == -1:
		return null
	var inner := text.substr(open + 1)
	if inner.ends_with(")"):
		inner = inner.substr(0, inner.length() - 1)
	var parts := _split_top_level(inner, ",")
	var out := []
	for part in parts:
		var part_text := str(part).strip_edges()
		if part_text == "true":
			out.append(1.0)
		elif part_text == "false":
			out.append(0.0)
		else:
			out.append(part_text.to_float())
	# vecN(single_value) splats the value across all components.
	if out.size() == 1 and expected_count > 1:
		var value = out[0]
		out = []
		for i in expected_count:
			out.append(value)
	if out.size() != expected_count:
		return null
	match expected_count:
		2:
			return Vector2(out[0], out[1])
		3:
			return Vector3(out[0], out[1], out[2])
		4:
			return Vector4(out[0], out[1], out[2], out[3])
	return null


func _parse_color_literal(text: String) -> Variant:
	var parsed := _parse_vec_literal(text, 4)
	if parsed == null:
		return null
	return Color(parsed.x, parsed.y, parsed.z, parsed.w)


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
# Value coercion (set_uniform + hot reload) and serialization (replies)
# ---------------------------------------------------------------------------

# The single shared entry point for converting a serialized value into the
# proper Variant for a declared uniform type. Used by set_uniform (wire values)
# and by hot reload (live parameter values re-applied after a code change);
# native Variants (Vector3, Color, ...) are normalized to their wire shape
# first so both paths run through the same coercion rules.
func _coerce_uniform_value(type_token: String, hint_text: String, is_array: bool, array_size: int, value: Variant) -> Dictionary:
	var normalized := _serialize_value(value)
	if is_array:
		if typeof(normalized) != TYPE_ARRAY:
			return { "ok": false, "error": "Uniform is an array; provide an array of values" }
		if array_size >= 0 and normalized.size() != array_size:
			return { "ok": false, "error": "Expected exactly %d array values, received %d" % [array_size, normalized.size()] }
		var out := []
		for item in normalized:
			var converted := _convert_scalar_uniform_value(type_token, hint_text, item)
			if not converted["ok"]:
				return converted
			out.append(converted["value"])
		return { "ok": true, "value": out }
	return _convert_scalar_uniform_value(type_token, hint_text, normalized)


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
		"mat2":
			return _convert_transform2d(value)
		"mat3":
			return _convert_basis(value)
		"transform", "mat4":
			return _convert_transform(value)
		# Godot's shader language has no string uniforms today, but the helper
		# accepts the JSON string shape so callers stay type-safe if one appears.
		"String", "string":
			if typeof(value) == TYPE_STRING:
				return { "ok": true, "value": value }
			return _value_type_error(type_token, value)
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
	# Accepts both a res:// string and the {path, ...} metadata dict that
	# replies serialize textures as.
	var path := ""
	if typeof(value) == TYPE_DICTIONARY:
		if not value.has("path"):
			return _value_type_error(type_token, value)
		path = str(value["path"])
	elif typeof(value) == TYPE_STRING:
		path = str(value)
	else:
		return _value_type_error(type_token, value)
	path = path.strip_edges().replace("\\", "/")
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


# mat2 uniforms map to Transform2D; the serialized form is a 6-number
# column-major array: x axis, y axis, origin.
func _convert_transform2d(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY or value.size() != 6:
		return { "ok": false, "error": "Expected a 6-number array for a mat2 uniform (x axis, y axis, origin)" }
	var nums := []
	for i in 6:
		var item = value[i]
		if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
			return { "ok": false, "error": "Transform values must be numbers" }
		nums.append(float(item))
	return { "ok": true, "value": Transform2D(Vector2(nums[0], nums[1]), Vector2(nums[2], nums[3]), Vector2(nums[4], nums[5])) }


# mat3 uniforms map to Basis; the serialized form is a 9-number column-major
# array of the three basis columns.
func _convert_basis(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY or value.size() != 9:
		return { "ok": false, "error": "Expected a 9-number array for a mat3 uniform (basis columns)" }
	var nums := []
	for i in 9:
		var item = value[i]
		if typeof(item) != TYPE_INT and typeof(item) != TYPE_FLOAT:
			return { "ok": false, "error": "Transform values must be numbers" }
		nums.append(float(item))
	var basis := Basis(
		Vector3(nums[0], nums[1], nums[2]),
		Vector3(nums[3], nums[4], nums[5]),
		Vector3(nums[6], nums[7], nums[8])
	)
	return { "ok": true, "value": basis }


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
# round trips. Vectors become {x,y,...} dicts, colors {r,g,b,a}, transforms
# float arrays (6/9/16), textures {path,width,height,format} metadata, and
# other resources their res:// path.
func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return { "x": value.x, "y": value.y }
		TYPE_VECTOR3:
			return { "x": value.x, "y": value.y, "z": value.z }
		TYPE_VECTOR4:
			return { "x": value.x, "y": value.y, "z": value.z, "w": value.w }
		TYPE_COLOR:
			return { "r": value.r, "g": value.g, "b": value.b, "a": value.a }
		TYPE_TRANSFORM2D:
			return _serialize_transform2d(value)
		TYPE_BASIS:
			return _serialize_basis(value)
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
				return _serialize_texture(value)
			if value is Material:
				return value.resource_path if not value.resource_path.is_empty() else "local"
			if value is Shader:
				return value.resource_path
			return ""
		TYPE_RID:
			return 0
	return str(value)


# Textures serialize as { path, width, height, format } metadata; the dimension
# and format fields are included where the texture type reports them.
func _serialize_texture(texture) -> Dictionary:
	var result := { "path": texture.resource_path }
	if texture.has_method("get_width") and texture.has_method("get_height"):
		result["width"] = texture.get_width()
		result["height"] = texture.get_height()
	if texture.has_method("get_format"):
		result["format"] = texture.get_format()
	return result


# Column-major 16-float form matching GLSL mat4 layout: three basis columns
# (x, y, z) each with a zero w, then origin with a 1.0 w.
func _serialize_transform(transform: Transform3D) -> Array:
	return [
		transform.basis.x.x, transform.basis.x.y, transform.basis.x.z, 0.0,
		transform.basis.y.x, transform.basis.y.y, transform.basis.y.z, 0.0,
		transform.basis.z.x, transform.basis.z.y, transform.basis.z.z, 0.0,
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0
	]


# Column-major 6-float form matching GLSL mat2 layout: x axis, y axis, origin.
func _serialize_transform2d(transform: Transform2D) -> Array:
	return [
		transform.x.x, transform.x.y,
		transform.y.x, transform.y.y,
		transform.origin.x, transform.origin.y
	]


# Column-major 9-float form matching GLSL mat3 layout: three basis columns.
func _serialize_basis(basis: Basis) -> Array:
	return [
		basis.x.x, basis.x.y, basis.x.z,
		basis.y.x, basis.y.y, basis.y.z,
		basis.z.x, basis.z.y, basis.z.z
	]


# ---------------------------------------------------------------------------
# Replies
# ---------------------------------------------------------------------------

func _send_result(request_id: int, payload: Dictionary) -> void:
	payload["request_id"] = request_id
	EngineDebugger.send_message("%s:result" % CAPTURE_NAME, [request_id, payload])


func _send_error(request_id: int, message: String) -> void:
	_send_result(request_id, { "success": false, "error": message })
