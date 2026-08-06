---
name: godot-shader-debugging
description: Debug shaders live in a running Godot game through the godot-mcp CLI: snapshot shader state, tweak and reset uniforms, visualize UV/normals/positions, capture rendered frames, hot-reload shader source with rollback, measure frame times, and check shader warnings and project health. Use when a shader compiles but renders wrong or looks wrong, debugging shaders in a running game, tweaking uniforms live, visualizing what a shader sees, hot-reloading shader code, or capturing game frames.
---

# Godot Shader Debugging

## Critical rule

All runtime shader tools require the game running from the editor with the debugger attached: start with `run_project` or `run_specific_scene` (F5), never `run_current_scene` (F6). Without a debug session the tools report "No active runtime session". The editor-side diagnostics (`shader_get_warnings`, `shader_project_health`) do not need a running game.

## Quick start

```bash
godot-mcp run_project
godot-mcp shader_debug_snapshot --node-path "/root/TestMainScene/ShaderVisuals/SoloSprite"
godot-mcp shader_set_uniform --node-path "/root/TestMainScene/ShaderVisuals/SoloSprite" --uniform-name "speed" --value 3.5
godot-mcp capture_running_game
godot-mcp shader_hot_reload --shader-path "res://test_runtime_material.gdshader" --content "<new source>"
```

## Workflows

### The shader debugging loop

1. Snapshot the material to see the code, type, render modes, and every uniform with its live value, default, and hint: `shader_debug_snapshot`.
2. Tweak a uniform: `shader_set_uniform` (per-node, or shader-wide with `--shader-path`).
3. Visualize what the shader sees: `shader_debug_visualize --mode uv` (also `normals`, `screen_pos`, `world_pos`, or `custom` with `--expression`) injects a temporary visualization into the live shader only, never writing files; finish with `--mode off` to restore the original code.
4. Capture the rendered frame to see the result: `capture_running_game`. The frame is read after `frame_post_draw` and is at most one frame old; a uniform set in the same turn may still show the pre-change frame. Pass `--node-path` to crop to a 2D node's on-screen region.
5. When the shader source itself is wrong, hot reload it: `shader_hot_reload` applies the new code to every material using the shader, then best-effort syncs the `.gdshader` file. `shader_reload_from_disk` runs the opposite direction: it pushes the current file content from disk into the running game (disk is the source of truth).
6. Roll back a bad reload by re-calling `shader_hot_reload` with `--content` set to the reply's `previous_code`; there is no separate revert tool.
7. Toggle `shader_debug_overlay` for wireframe or normal geometry visualization; `off` resets.

### Worked example: shader renders black

1. Run the game and snapshot the material:

   ```bash
   godot-mcp run_project
   godot-mcp shader_debug_snapshot --node-path "/root/TestMainScene/ShaderVisuals/SoloSprite"
   ```

   Inspect the uniforms: `speed` may be 0.0, or the source may sample a texture that is never assigned.

2. Set the suspect uniform to a known-good value:

   ```bash
   godot-mcp shader_set_uniform --node-path "/root/TestMainScene/ShaderVisuals/SoloSprite" --uniform-name "speed" --value 3.5
   ```

3. Capture the frame to check:

   ```bash
   godot-mcp capture_running_game
   ```

   If the sprite is still black, the source itself is wrong.

4. Fix the source and hot reload it (applies to every material using the shader, then syncs the file):

   ```bash
   godot-mcp shader_hot_reload --shader-path "res://test_runtime_material.gdshader" --content "shader_type canvas_item; void fragment() { COLOR = vec4(1.0, 0.5, 0.25, 1.0); }"
   ```

5. Verify with a snapshot and a capture; if the change made things worse, roll back using the reply's `previous_code`:

   ```bash
   godot-mcp shader_hot_reload --shader-path "res://test_runtime_material.gdshader" --content "<previous_code from the last reply>"
   ```

## Tool semantics

- `shader_debug_snapshot --node-path <path> [--material-slot <slot>]`: read-only. Returns the shader path (or "local"), type and render modes, full source, every uniform with live value, parseable default, and hint, plus sharing info. Polls internally with a short fixed timeout; no `--wait-ms`.
- `shader_set_uniform --node-path <path> --uniform-name <name> --value <value> [--material-slot <slot>] [--allow-shared true] [--wait-ms <ms>]`: set a uniform live. Accepts numbers, bools, strings, vectors (exact-length array or `{x,y,...}` dict), colors, Transform2D (6 floats), Basis (9), Transform3D (16), textures (res:// string or `{path,...}` dict), and arrays of these (must match the declared length exactly). Refuses materials shared by more than one node unless `--allow-shared true`; unknown uniforms are rejected.
- `capture_running_game [--output-path <path>] [--return-base64 true] [--allow-large true] [--wait-ms <ms>]`: capture the root viewport's current rendered frame as PNG (default saved under `user://mcp_captures`). The frame is at most one frame old. Captures above 4,000,000 pixels are refused unless `--allow-large true`; `--wait-ms` defaults to 3000.
- `shader_hot_reload --content <source> [--shader-path <path> | --node-path <path>] [--material-slot <slot>]`: apply new source live to every material in the running game using the shader, then best-effort sync the `.gdshader` file. The reply includes `affected_materials` (node and material paths), `previous_code` (rollback content), `file_written`/`file_write_error` (a failed write never fails the live apply), and `compile_errors`.
- `shader_debug_overlay --mode wireframe|normal|off [--viewport-index <n>] [--wait-ms <ms>]`: toggle Viewport debug-draw. `normal` requires Forward+ (clean error otherwise); `wireframe` works on all renderers but on gl_compatibility only affects meshes loaded after the call (a caveat is returned); `off` resets. `--viewport-index` defaults to 0 (root viewport), `--wait-ms` to 800.
- `shader_debug_visualize --node-path <path> --mode uv|normals|screen_pos|world_pos|custom|off [--expression <expr>] [--material-slot <slot>] [--wait-ms <ms>]`: injects visualization code into the live shader only (never writes files); `custom` requires `--expression` (assigned to COLOR for canvas_item, ALBEDO for spatial); `off` restores the exact original code; a compile failure rolls back automatically with `rolled_back` and `compile_errors`. Only canvas_item and spatial shaders.
- `shader_reset_uniforms --node-path <path> [--material-slot <slot>] [--wait-ms <ms>]`: reset every shader parameter to its declared default; the reply lists each restored value in `reset` plus `count`.
- `shader_reload_from_disk [--shader-path <path> | --node-path <path>] [--material-slot <slot>] [--wait-ms <ms>]`: the opposite of hot reload — push the current `.gdshader` file content from disk into the running game and apply it to every material using the shader (same lookup as `shader_hot_reload`); `unchanged` reports when the live code already equals the disk content, and `previous_code` is included for reference.
- `shader_measure_frame_time [--enable true|false] [--viewport-index <n>] [--wait-ms <ms>]`: read (and optionally toggle) the running game's per-viewport GPU/CPU render time in ms (`gpu_ms`/`cpu_ms`); `--enable` omitted reads without changing state; measurement is per-viewport (0 = root), not per-shader.
- `shader_set_uniform --shader-path <path> --uniform-name <name> --value <value> [--allow-shared true] [--wait-ms <ms>]`: shader-wide variant — applies the uniform to every material using that .gdshader; materials shared by more than one node are skipped unless `--allow-shared true`; the reply reports `affected`, `skipped` and `count`. The `--node-path` form above is unchanged.
- `capture_running_game --node-path <path>`: crop the capture to the node's on-screen region (2D CanvasItem/Control only; 3D nodes return a clean error); the reply gains `cropped`, `original_width` and `original_height`.
- `shader_get_warnings [--script-path <path>] [--wait-ms <ms>]` and `shader_project_health [--wait-ms <ms>]`: editor-side diagnostics, no running game needed — report unused-declaration warnings and compile errors (one file, or every .gdshader under res:// for health); the first call enables the `debug/shader_language/warnings/*` ProjectSettings toggles (persisted side effect).

Related discovery tools: `shader_list_materials` (list ShaderMaterials under a node), `shader_get_uniforms` (read live uniform values), and editor-side `shader_get_warnings`/`shader_project_health` (no game needed); full parameters in `docs/command-reference.md`.

## Related skills

- [godot-scripting](../godot-scripting/SKILL.md): shader authoring (create/edit/get shader files, `shader_get_compile_errors`, template-from-type behavior, compile diagnostics).
- [godot-debugging](../godot-debugging/SKILL.md): general runtime debugging (breakpoints, stepping, stack traces, error triage).
