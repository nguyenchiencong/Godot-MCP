@tool
class_name EditorUtils
extends RefCounted

# There is unfortunately no plan to add an easier way
# https://github.com/godotengine/godot-proposals/issues/9798
static func find_scene_tree_editor_tree(editor_interface, scene_root_name: String) -> Tree:
	if not editor_interface or not editor_interface.has_method("get_base_control"):
		return null

	var base_control = editor_interface.get_base_control()
	if not is_instance_valid(base_control):
		return null

	var trees: Array = base_control.find_children("", "Tree", true, false)
	var fallback_tree: Tree = null
	var scene_tree: Tree = null

	for tree in trees:
		if not (tree is Tree):
			continue

		if fallback_tree == null:
			fallback_tree = tree

		var path = String(tree.get_path())
		if scene_tree == null and path.find("SceneTreeEditor") != -1:
			scene_tree = tree

		if scene_root_name.is_empty():
			continue

		var root: TreeItem = tree.get_root()
		if root and _tree_has_scene_root(root, scene_root_name):
			return tree

	return scene_tree if scene_tree else fallback_tree

static func collect_scene_tree_warning_entries(tree: Tree, scene_root_name: String) -> Dictionary:
	var result := {
		"warnings": [],
		"items_scanned": 0,
		"buttons_scanned": 0,
		"tree_path": String(tree.get_path()) if tree.is_inside_tree() else ""
	}

	if not is_instance_valid(tree):
		return result

	var root: TreeItem = tree.get_root()
	if root:
		_collect_scene_tree_warning_entries_for_item(tree, root, result, scene_root_name)

	return result

static func _tree_has_scene_root(root: TreeItem, scene_root_name: String) -> bool:
	var items: Array = [root]
	while items.size() > 0:
		var item = items.pop_front()
		if not is_instance_valid(item):
			continue

		var item_name = String(item.get_text(0))
		var item_path = String(item.get_metadata(0))
		if item_name == scene_root_name or item_path == scene_root_name or item_path.begins_with(scene_root_name + "/"):
			return true

		var child_item = item.get_first_child()
		while child_item:
			items.append(child_item)
			child_item = child_item.get_next()

	return false

static func _collect_scene_tree_warning_entries_for_item(tree: Tree, item: TreeItem, result: Dictionary, scene_root_name: String) -> void:
	if not is_instance_valid(item):
		return

	result["items_scanned"] = int(result.get("items_scanned", 0)) + 1

	var button_count := int(item.get_button_count(0))
	for button_index in range(button_count):
		result["buttons_scanned"] = int(result.get("buttons_scanned", 0)) + 1

		if int(item.get_button_id(0, button_index)) != 5:
			continue

		var rect := tree.get_item_area_rect(item, 0, button_index)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue

		var warning_text := String(tree.get_tooltip(rect.position + (rect.size * 0.5))).strip_edges()
		if warning_text.is_empty():
			continue

		var item_name := String(item.get_text(0))
		var item_path := _normalize_scene_tree_path(item.get_metadata(0), scene_root_name)
		if item_path.is_empty():
			item_path = item_name

		var warnings: Array = result.get("warnings", [])
		var existing_index := -1
		for i in range(warnings.size()):
			var warning_entry = warnings[i]
			if typeof(warning_entry) == TYPE_DICTIONARY and warning_entry.get("path", "") == item_path:
				existing_index = i
				break

		if existing_index >= 0:
			var existing_entry = warnings[existing_index]
			var existing_warning = String(existing_entry.get("warning", ""))
			if existing_warning.is_empty():
				existing_entry["warning"] = warning_text
			else:
				existing_entry["warning"] = existing_warning + "\n\n" + warning_text
			warnings[existing_index] = existing_entry
		else:
			warnings.append({
				"name": item_name,
				"path": item_path,
				"warning": warning_text
			})

		result["warnings"] = warnings

	var child := item.get_first_child()
	while child:
		_collect_scene_tree_warning_entries_for_item(tree, child, result, scene_root_name)
		child = child.get_next()

static func _normalize_scene_tree_path(metadata_value, scene_root_name: String) -> String:
	var metadata := String(metadata_value)
	if metadata.is_empty() or scene_root_name.is_empty():
		return metadata

	var marker := scene_root_name + "/"
	var idx := metadata.rfind(marker)
	if idx != -1:
		return metadata.substr(idx)

	return metadata
