# Godot MCP Command Reference

Quick reference for all available tools. Use `godot-mcp --help <tool>` for detailed help.

## Node Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_node` | Create a node | `--parent-path`, `--node-type`, `--node-name` |
| `delete_node` | Delete a node | `--node-path` |
| `update_node_property` | Set a property | `--node-path`, `--property`, `--value` |
| `get_node_properties` | Get all properties | `--node-path` |
| `list_nodes` | List child nodes | `--parent-path` |
| `update_node_transform` | Set position/rotation/scale | `--node-path`, `--position`, `--rotation`, `--scale` |

## Script Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_script` | Create a GDScript | `--script-path`, `--content`, `--node-path` (optional) |
| `edit_script` | Edit a script | `--script-path`, `--content` |
| `get_script` | Get script content | `--script-path` or `--node-path` |
| `get_script_diagnostics` | Parse a GDScript file and return compile/parse errors | `--script-path` |

## Scene Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_scene` | Create a new scene | `--path`, `--root-node-type` |
| `delete_scene` | Delete a scene file | `--path` |
| `save_scene` | Save current scene | `--path` (optional) |
| `open_scene` | Open a scene | `--path` |
| `get_current_scene` | Get current scene info | (none) |
| `create_resource` | Create a resource | `--resource-type`, `--resource-path`, `--properties` |
| `capture_scene` | Render a scene into an off-screen viewport and return the PNG image | `--scene-path` (optional), `--width`, `--height`, `--transparent`, `--output-path` |
| `validate_scene` | Check a scene's structural health | `--scene-path` |

## Project Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_project_info` | Get project info | (none) |
| `run_project` | Run with F5 (debug) | (none) |
| `run_current_scene` | Run with F6 | (none) |
| `run_specific_scene` | Run a specific scene | `--scene-path` |
| `stop_running_project` | Stop running project | (none) |
| `reload_project` | Restart Godot editor | `--save` (default: true) |
| `reload_scene` | Reload scene from disk | `--scene-path` (optional) |
| `rescan_filesystem` | Rescan for file changes | (none) |
| `generate_project_guidance` | Scan the project and write AI guidance files | `--include-agents-md`, `--force` |

## Asset Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `list_assets_by_type` | List assets | `--type` (scripts/scenes/images/audio/fonts/models/shaders/resources/all) |
| `list_project_files` | List files by extension | `--extensions` |

## Debugger Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `debugger_set_breakpoint` | Set a breakpoint | `--script-path`, `--line` |
| `debugger_remove_breakpoint` | Remove a breakpoint | `--script-path`, `--line` |
| `debugger_get_breakpoints` | List all breakpoints | (none) |
| `debugger_clear_all_breakpoints` | Clear all breakpoints | (none) |
| `debugger_pause_execution` | Pause execution | (none) |
| `debugger_resume_execution` | Resume execution | (none) |
| `debugger_step_over` | Step over | (none) |
| `debugger_step_into` | Step into | (none) |
| `debugger_get_call_stack` | Get call stack | `--session-id` (optional) |
| `debugger_get_current_state` | Get debugger state | (none) |
| `debugger_enable_events` | Subscribe to events | (none) |
| `debugger_disable_events` | Unsubscribe from events | (none) |

## Input Simulation Tools

Requires a running game (F5).

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_input_actions` | List available actions | (none) |
| `simulate_action_press` | Press and hold action | `--action`, `--strength` |
| `simulate_action_release` | Release action | `--action` |
| `simulate_action_tap` | Tap action briefly | `--action`, `--duration-ms` |
| `simulate_mouse_click` | Click at position | `--x`, `--y`, `--button`, `--double-click` |
| `simulate_mouse_move` | Move mouse | `--x`, `--y` |
| `simulate_drag` | Drag operation | `--start-x`, `--start-y`, `--end-x`, `--end-y`, `--duration-ms` |
| `simulate_key_press` | Press keyboard key | `--key`, `--duration-ms`, `--modifiers` |
| `simulate_input_sequence` | Complex input sequence | `--sequence` (JSON array) |

## Enhanced Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_editor_scene_structure` | Editor scene tree | `--include-properties`, `--include-scripts`, `--max-depth` |
| `get_runtime_scene_structure` | Runtime scene tree | `--include-properties`, `--max-depth`, `--timeout-ms` |
| `evaluate_runtime` | Evaluate expression in game | `--expression`, `--context-path`, `--timeout-ms` |
| `execute_editor_script` | Run GDScript in editor | `--code` |

## Editor Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_debug_output` | Get Output panel | (none) |
| `clear_debug_output` | Clear Output panel | (none) |
| `get_editor_errors` | Get Errors tab | (none) |
| `clear_editor_errors` | Clear Errors tab | (none) |
| `get_node_warnings` | Inspect current scene tree for configuration warnings | `--debug` |
| `get_stack_trace_panel` | Get stack trace | `--session-id` |
| `get_stack_frames_panel` | Get stack frames | `--session-id`, `--refresh` |
| `stream_debug_output` | Start/stop log stream | `--action` (start/stop) |

## MCP Resources

Read-only endpoints for MCP clients:

```
godot://script/{path}              # Script content
godot://script/{path}/metadata     # Script metadata
godot://scene/current              # Current scene structure
godot://scene/tree                 # Scene tree only
godot://assets/{type}              # Assets by type
godot://debug/log                  # Debug output
godot://debugger/state             # Debugger state
godot://debugger/breakpoints       # All breakpoints
godot://debugger/call-stack/{id}   # Call stack
godot://debugger/session/{id}      # Session info
```

## CLI Examples

```bash
# Node operations
godot-mcp create_node --parent-path "." --node-type "Sprite2D" --node-name "Player"
godot-mcp update_node_property --node-path "./Player" --property "position" --value "[100,200]"

# Script operations
godot-mcp get_script --script-path "res://scripts/player.gd"
godot-mcp get_script_diagnostics --script-path "res://scripts/player.gd"

# Scene operations
godot-mcp open_scene --path "res://scenes/main.tscn"
godot-mcp get_editor_scene_structure --include-properties true
godot-mcp capture_scene --scene-path "res://scenes/main.tscn" --width 1280 --height 720
godot-mcp validate_scene --scene-path "res://scenes/main.tscn"

# Debugging
godot-mcp run_project
godot-mcp debugger_set_breakpoint --script-path "res://player.gd" --line 42
godot-mcp debugger_get_current_state

# Reload operations
godot-mcp rescan_filesystem
godot-mcp reload_scene
godot-mcp reload_scene --scene-path "res://scenes/main.tscn"
godot-mcp reload_project --save true

# Project guidance
godot-mcp generate_project_guidance --include-agents-md true

# Input simulation
godot-mcp get_input_actions
godot-mcp simulate_action_tap --action "ui_accept"
godot-mcp simulate_mouse_click --x 400 --y 300
```

## Input Sequence Format

```json
{
  "sequence": [
    { "type": "press", "action": "ui_right" },
    { "type": "wait", "duration_ms": 500 },
    { "type": "tap", "action": "jump", "duration_ms": 100 },
    { "type": "release", "action": "ui_right" },
    { "type": "click", "x": 100, "y": 200, "button": "left" }
  ]
}
```

Sequence step types: `press`, `release`, `tap`, `wait`, `click`

## Response Formats

### capture_scene

Returns the captured PNG as an MCP image content block plus a text summary ("Scene captured and saved to ..."). The underlying command result:

```json
{
  "file_path": "user://mcp_captures/capture_1750000000.png",
  "absolute_path": "C:/Users/you/AppData/Roaming/Godot/app_userdata/YourProject/capture_1750000000.png",
  "width": 1280,
  "height": 720,
  "image_base64": "..."
}
```

Defaults: width 1280, height 720, transparent background off, output directory `user://mcp_captures/`. Without `--scene-path`, the scene currently open in the editor is captured.

### get_script_diagnostics

```json
{
  "script_path": "res://scripts/player.gd",
  "exists": true,
  "valid": false,
  "error_count": 1,
  "errors": [
    { "line": 12, "column": 0, "message": "..." }
  ]
}
```

`valid` is true when the script parses without errors. `create_script` and `edit_script` responses also include this `diagnostics` field for GDScript files.

### validate_scene

```json
{
  "scene_path": "res://scenes/main.tscn",
  "valid": true,
  "issue_count": 0,
  "issues": []
}
```

Issues use `{ severity, category, message, node_path? }` with categories `load`, `instantiate`, `duplicate_name`, `missing_resource`, and `cyclic_dependency`.

### generate_project_guidance

```json
{
  "written_paths": ["res://addons/godot_mcp/ai/project_guide.md"],
  "scene_count": 3,
  "autoload_count": 1,
  "input_action_count": 5,
  "guide_path": "res://addons/godot_mcp/ai/project_guide.md",
  "agents_md_path": "res://AGENTS.md",
  "action": "created"
}
```

Writes `res://addons/godot_mcp/ai/project_guide.md` and, when `--include-agents-md` is passed, writes or updates `res://AGENTS.md`. `action` is `created`, `appended`, `replaced`, or `skipped`; an existing `AGENTS.md` is never overwritten unless `--force` is passed.
