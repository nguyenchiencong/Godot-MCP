---
name: godot-shader-debugging
description: Debug shaders live in a running Godot game through the godot-mcp CLI: snapshot shader state, tweak uniforms, capture rendered frames, hot-reload shader source with rollback, and toggle debug-draw overlays. Use when a shader compiles but renders wrong or looks wrong, debugging shaders in a running game, tweaking uniforms live, hot-reloading shader code, or capturing game frames.
---

# Godot Shader Debugging

## Critical rule

All runtime shader tools require the game running from the editor with the debugger attached: start with `run_project` or `run_specific_scene` (F5), never `run_current_scene` (F6). Without a debug session the tools report "No active runtime session".

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
2. Tweak a uniform: `shader_set_uniform`.
3. Capture the rendered frame to see the result: `capture_running_game`. The frame is read after `frame_post_draw` and is at most one frame old; a uniform set in the same turn may still show the pre-change frame.
4. When the shader source itself is wrong, hot reload it: `shader_hot_reload` applies the new code to every material using the shader, then best-effort syncs the `.gdshader` file.
5. Roll back a bad reload by re-calling `shader_hot_reload` with `--content` set to the reply's `previous_code`; there is no separate revert tool.
6. Toggle `shader_debug_overlay` for wireframe or normal geometry visualization; `off` resets.

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
- `shader_set_uniform --node-path <path> --uniform-name <name> --value <value> [--material-slot <slot>] [--allow-shared true] [--wait-ms <ms>]`: set a uniform live. Accepts numbers, bools, strings, vectors (exact-length array or `{x,y,...}` dict), colors, Transform2D (6 floats), Basis (9), Transform3D (16), textures (res:// string only, other forms rejected), and arrays of these (must match the declared length exactly). Refuses materials shared by more than one node unless `--allow-shared true`; unknown uniforms are rejected.
- `capture_running_game [--output-path <path>] [--return-base64 true] [--allow-large true] [--wait-ms <ms>]`: capture the root viewport's current rendered frame as PNG (default saved under `user://mcp_captures`). The frame is at most one frame old. Captures above 4,000,000 pixels are refused unless `--allow-large true`; `--wait-ms` defaults to 3000.
- `shader_hot_reload --content <source> [--shader-path <path> | --node-path <path>] [--material-slot <slot>]`: apply new source live to every material in the running game using the shader, then best-effort sync the `.gdshader` file. The reply includes `affected_materials` (node and material paths), `previous_code` (rollback content), `file_written`/`file_write_error` (a failed write never fails the live apply), and `compile_errors`.
- `shader_debug_overlay --mode wireframe|normal|off [--viewport-index <n>] [--wait-ms <ms>]`: toggle Viewport debug-draw. `normal` requires Forward+ (clean error otherwise); `wireframe` works on all renderers but on gl_compatibility only affects meshes loaded after the call (a caveat is returned); `off` resets. `--viewport-index` defaults to 0 (root viewport), `--wait-ms` to 800.

Related discovery tools: `shader_list_materials` (list ShaderMaterials under a node) and `shader_get_uniforms` (read live uniform values); full parameters in `docs/command-reference.md`.

## Related skills

- [godot-scripting](../godot-scripting/SKILL.md): shader authoring (create/edit/get shader files, `shader_get_compile_errors`, template-from-type behavior, compile diagnostics).
- [godot-debugging](../godot-debugging/SKILL.md): general runtime debugging (breakpoints, stepping, stack traces, error triage).
