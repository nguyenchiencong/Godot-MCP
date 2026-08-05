@tool
class_name MCPCaptureCommands
extends MCPBaseCommandProcessor

## Command processor for capturing scene screenshots.
## Renders a scene into an off-screen SubViewport, saves a PNG file, and
## returns the image as base64 so the MCP server can deliver visual
## feedback to vision-capable AI models. With return_base64=false (default)
## the base64 payload is omitted entirely and the caller reads the PNG from
## absolute_path instead, avoiding a multi-MB JSON round-trip.

const DEFAULT_WIDTH := 1280
const DEFAULT_HEIGHT := 720
const DEFAULT_CAPTURE_DIR := "user://mcp_captures"
const MAX_DIMENSION := 8192


func process_command(client_id: int, command_type: String, params: Dictionary, command_id: String) -> bool:
	match command_type:
		"capture_scene":
			await _handle_capture_scene(client_id, params, command_id)
			return true
	return false


func _handle_capture_scene(client_id: int, params: Dictionary, command_id: String) -> void:
	var scene_path := str(params.get("scene_path", ""))
	var width := int(params.get("width", DEFAULT_WIDTH))
	var height := int(params.get("height", DEFAULT_HEIGHT))
	var transparent := bool(params.get("transparent", false))
	var output_path := str(params.get("output_path", ""))
	var return_base64 := bool(params.get("return_base64", false))
	var allow_large := bool(params.get("allow_large", false))

	if width <= 0 or height <= 0:
		_send_error(client_id, "Width and height must be positive integers", command_id)
		return

	width = mini(width, MAX_DIMENSION)
	height = mini(height, MAX_DIMENSION)

	# Guard against accidental huge captures; 4 megapixels is the default cap.
	if width * height > 4000000 and not allow_large:
		_send_error(client_id, "Capture size %dx%d exceeds the 4MP default limit; set allow_large=true to override" % [width, height], command_id)
		return

	# Resolve which scene to capture
	if scene_path.is_empty():
		scene_path = _get_open_scene_path()
		if scene_path.is_empty():
			_send_error(client_id, "No scene file open", command_id)
			return
	elif not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# Load the packed scene
	var packed_scene: PackedScene = load(scene_path)
	if packed_scene == null:
		_send_error(client_id, "Failed to load scene: %s" % scene_path, command_id)
		return

	# Create the off-screen viewport
	var viewport := SubViewport.new()
	viewport.name = "MCPScreenshotViewport"
	viewport.size = Vector2i(width, height)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = transparent
	add_child(viewport)

	# Instantiate the scene inside the viewport
	var instance := packed_scene.instantiate()
	if instance == null:
		viewport.queue_free()
		_send_error(client_id, "Failed to instantiate scene: %s" % scene_path, command_id)
		return
	viewport.add_child(instance)

	# 2D scenes have no environment of their own, so clear the viewport once
	# so the default background is consistent instead of reusing old pixels
	if not transparent and (instance is Node2D or instance is Control):
		viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE

	# Wait for the viewport to produce a rendered frame. A forced draw is used
	# instead of awaiting RenderingServer.frame_post_draw alone: the editor does
	# not emit that signal when it is not actively drawing (minimized window,
	# low processor usage mode), which would hang the command forever.
	var img: Image = null
	for attempt in 12:
		RenderingServer.force_draw()
		await get_tree().process_frame
		img = _read_viewport_image(viewport)
		if img != null and not img.is_empty():
			break

	instance.queue_free()
	viewport.queue_free()

	if img == null or img.is_empty():
		_send_error(client_id, "Failed to read rendered image from viewport", command_id)
		return

	# Save the PNG next to the base64 payload
	var save_path := _resolve_save_path(output_path)
	var bytes := img.save_png_to_buffer()
	if bytes.is_empty():
		_send_error(client_id, "Failed to encode PNG image", command_id)
		return
	if not _write_png_bytes(bytes, save_path):
		_send_error(client_id, "Failed to write PNG file: %s" % save_path, command_id)
		return

	var result := {
		"file_path": _to_project_path(save_path),
		"absolute_path": ProjectSettings.globalize_path(save_path),
		"width": width,
		"height": height
	}
	if return_base64:
		result["image_base64"] = Marshalls.raw_to_base64(bytes)

	_send_success(client_id, result, command_id)


# Returns the res:// path of the scene currently open in the editor,
# or an empty string when there is no open scene file.
func _get_open_scene_path() -> String:
	if not Engine.has_meta("GodotMCPPlugin"):
		return ""
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var editor_interface = plugin.get_editor_interface()
	var edited_scene_root = editor_interface.get_edited_scene_root()
	if edited_scene_root == null:
		return ""
	return edited_scene_root.scene_file_path


func _read_viewport_image(viewport: SubViewport) -> Image:
	var texture := viewport.get_texture()
	if texture == null:
		return null
	return texture.get_image()


func _resolve_save_path(output_path: String) -> String:
	if output_path.is_empty():
		var timestamp := int(Time.get_unix_time_from_system())
		return "%s/capture_%d.png" % [DEFAULT_CAPTURE_DIR, timestamp]
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
	return true


# Expresses a saved path in res:// form when it lives inside the project,
# keeps res:// and user:// paths as-is, and leaves other absolute paths unchanged.
func _to_project_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	var project_dir := ProjectSettings.globalize_path("res://")
	if path.begins_with(project_dir):
		return "res://" + path.substr(project_dir.length())
	return path
