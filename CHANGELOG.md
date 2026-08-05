# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added
- `capture_scene` tool/command that renders a Godot scene into an off-screen SubViewport and returns the PNG to the AI as an MCP image content block, giving vision-capable models direct visual feedback on the scene
- `get_script_diagnostics` tool/command to parse a GDScript file and return compile/parse errors with line numbers
- `validate_scene` tool/command to check a .tscn scene's structural health: loadability, instantiation, duplicate node names, missing scripts/resources, and cyclic dependencies
- `generate_project_guidance` tool/command that scans the project (autoloads, input actions, scenes, key scripts, settings) and writes `res://addons/godot_mcp/ai/project_guide.md`, optionally writing or appending `res://AGENTS.md` (an existing `AGENTS.md` is never overwritten unless `force` is set)
- `create_script` and `edit_script` responses now include a `diagnostics` field reporting parse errors for GDScript files
- `server/tests/async_diagnostics.test.js` regression test proving broken-script diagnostics run on a worker thread without blocking the editor (run via `npm run test:async-diagnostics`)

### Changed
- Per-command payload logging (send/receive) is now gated behind `GODOT_MCP_DEBUG=1`, removing stderr I/O on normal commands; lifecycle/error logs remain unconditional
- `capture_scene` reads the PNG from disk (written by Godot) instead of shipping base64 over the WebSocket by default; `return_base64: true` restores the old behavior, and `allow_large: true` lifts the 4MP capture limit
- `create_script`/`edit_script` headless diagnostics subprocess results are cached per script content (bounded to 64 entries) and can be skipped with `diagnostics: false` for faster writes
- `validate_scene` runs a single dependency scan shared by all checks and can skip `PackedScene.instantiate()` with `check_instantiate: false`
- Fixed a reconnect edge case where `disconnect()` during a pending reconnect timer would still trigger a reconnect
- Diagnostics headless parser runs on a dedicated worker thread so broken-script diagnostics no longer block editor frames
- Debug-output publishing resolves the Output-panel control once and recovers via `SceneTree` signals; the 0.5s poll never scans the editor control tree
- Four project directory walkers consolidated into one parameterized DFS scanner with preserved outputs

## 1.0.10 - 2026-08-05

### Added
- `get_node_warnings` tool/command to inspect configuration warnings ([!] badges) on nodes in the current scene tree

## 1.0.9 - 2025-12-19

### Changed
- Removed unused `websocket` dependency (eliminates deprecated `yaeti` install warning)

## 1.0.8 - 2025-12-19

### Changed
- **Dependency Upgrade**: Upgraded `zod` from 3.24.2 to 4.1.13
- Updated `create_resource` schema to use the Zod 4-required `z.record(keySchema, valueSchema)` form

### Fixed
- CLI now reports a stable, friendly error for missing required tool parameters (instead of relying on upstream validation wording)
- `install-addon` can now locate the bundled addon folder in both dev and published package layouts

## 1.0.7 - 2025-12-11

### Added
- `delete_scene` tool/command to delete scene files from the project, complementing the existing `create_scene` tool
- Support for "scripts" and "scenes" asset types in `list_assets_by_type` tool (previously only supported images, audio, fonts, models, shaders, resources)
- Comprehensive test suite in `server/tests/tools.test.js` covering all 54 MCP tools across 9 categories with automatic cleanup of generated test files

### Fixed
- `list_assets_by_type` now correctly filters by asset type instead of returning all project files when requesting scripts
- `list_assets_by_type` now returns helpful error message for unknown asset types with list of valid types
- `delete_scene` prevents deletion of currently open scenes with clear error message

### Changed
- Consolidated test suite: removed 7 redundant individual test files (call-stack.test.js, pause.test.js, resume.test.js, stack-frames-panel.test.js, stack-trace-panel.test.js, editor-errors.test.js, debugger.test.js) in favor of comprehensive `tools.test.js`
- Test suite now includes automatic cleanup of generated files (scripts, scenes, resources) with final cleanup pass

## 1.0.6 - 2025-12-11

### Changed
- **Dependency Upgrade**: Upgraded `fastmcp` from 1.20.4 to 3.25.4
  - Removed direct `@modelcontextprotocol/sdk` dependency (now managed by fastmcp internally)
  - Removed `overrides` block from package.json
  - Updated resource template files to use `as const` for argument names (TypeScript inference requirement in 3.x)
  - Core API (`FastMCP`, `addTool`, `addResource`, etc.) remains compatible

## 1.0.5 - 2025-12-09

### Fixed
- **Debugger Warning**: Fixed "Unknown message: mcp_input:result" warning in Godot editor by returning `true` from `_capture()` when messages are successfully handled in `mcp_runtime_debugger_bridge.gd`

## 1.0.4 - 2025-12-09

### Fixed
- **CLI Compatibility**: Pinned `@modelcontextprotocol/sdk` to 1.6.0 to fix "Server does not support completions" error when running CLI commands
- **npm Package**: README.md now displays correctly on the npm package page
- **Dependency Cleanup**: postpublish script properly cleans up copied files after npm publish

## 1.0.0 - 2025-12-06

### Added
- **npm Package**: Published to npm as `godot-mcp-cli` for easy installation via `npm install -g godot-mcp-cli`
- **Cross-platform Addon Installation**: `godot-mcp install-addon <path>` command copies the Godot addon to any project

### Changed
- **Project Structure**: Addon source lives in `addons/godot_mcp/`, automatically copied to npm package on publish
- **Package Name**: `godot-mcp-cli` (binary remains `godot-mcp` for convenience)

## 2025-11-30

### Added
- **Project Reload Tools**: New tools for reloading the Godot project without manual intervention:
  - `reload_project` - Restart the Godot editor (with optional save before restart)
  - `reload_scene` - Reload current or specific scene from disk
  - `rescan_filesystem` - Rescan project filesystem for external file changes

## 2025-11-29

### Added
- **Input Simulation System**: New tools for AI agents to interact with running Godot games in real-time:
  - `simulate_action_press` / `simulate_action_release` / `simulate_action_tap` - Simulate input actions
  - `simulate_mouse_click` / `simulate_mouse_move` / `simulate_drag` - Mouse input simulation
  - `simulate_key_press` - Keyboard input with modifier key support
  - `simulate_input_sequence` - Execute complex input combos with precise timing
  - `get_input_actions` - Discover all available input actions in the project
- `MCPInputHandler` autoload automatically registered when plugin is enabled
- Runtime input handler (`mcp_input_handler.gd`) for receiving input commands via debugger bridge

## 2025-11-23

### Changed
- CLI is quieter by default, with `--verbose` enabling progress logs and server diagnostics.
- `--list-tools` now prints a colorized table; mixed-content results render with clearer bullets/tags.
- Simplified CLI invocation: drop the optional `mcp` namespace; use `godot-mcp <tool>` (e.g., `godot-mcp get_debug_output`).

### Added
- CLI tests for progress streaming, missing tool, invalid params, and JSON-flag arg handling using a new `progress_task` mock tool.
- `godot-mcp install-addon <path>` to install/update the `godot_mcp` addon into a Godot project’s `addons` folder.

## 2025-11-17

### Added
- `clear_editor_errors` tool/command to clear the Errors tab in the Godot editor debugger panel, complementing the existing `get_editor_errors` and `clear_debug_output` tools.
- Test file `server/tests/editor-errors.test.js` to verify `get_editor_errors` and `clear_editor_errors` functionality.
- Documentation updates for `clear_editor_errors` in command-reference.md, README.md, testing-guide.md, and tool-prompt-guide.md.

### Fixed
- Updated command handler to properly route all enhanced commands (including `get_editor_errors`, `clear_editor_errors`, `clear_debug_output`, etc.) to the enhanced commands processor.

## 2025-11-15

### Added
- Debugger bridge can now recognize additional stack capture messages (`stack`, `call_stack`, `callstack`, `stack_dump`) and even rebuild frame data directly from the editor Output log when Godot only prints `print_stack` output, giving `debugger_get_call_stack` a fallback path when stack dumps are missing.
- Introduced `server/tests/call-stack.test.js`, a focused Node script that connects to the MCP server and exercises `debugger_get_call_stack` end-to-end once the project is paused.
- Shared `server/tests/utils/test_logger.js` so every debugger-focused Node script gets consistent colored output, structured JSON dumps, and divider helpers.

### Fixed
- Normalized session identifiers across `debugger_get_call_stack` and `mcp_debugger_bridge.gd`, covering ints, floats, and string IDs, ensuring cached state stays in sync and removing the spurious `session_not_found` errors encountered when Godot reported non-integer IDs.
- Re-ordered the debugger integration test runner now that call stack coverage lives in its own script so cleanup happens earlier, event handling reuses the same connection, and the console output stays predictable run-to-run.
- `debugger_get_call_stack` now lets the bridge auto-pick any active session (or sequentially retry each one) instead of forcing `session_id = 1`, eliminating the empty responses that occurred when Godot reused different session identifiers.

## 2025-11-13

### Added
- `get_stack_trace_panel` tooling (Godot command, MCP tool, and docs) to capture the Stack Trace panel plus parsed frames and debugger context whenever execution pauses.
- `clear_debug_output` tool/command pair that wipes the editor Output panel, resets streaming subscribers, and reports diagnostics about how the clear was performed.
- `get_stack_frames_panel` tooling and a dedicated JS test to capture structured stack frames from the debugger bridge cache.
- Reworked `execute_editor_script` flow to capture parser/runtime errors, log tails, and timeouts for more actionable diagnostics.
- Documentation updates (README, command/tool guides, testing guide) covering the new stack trace capture and output clearing workflows.

## 2025-11-11

### Added
- New MCP project control tools: `run_project`, `stop_running_project`, `run_current_scene`, and `run_specific_scene`.
- Godot-side implementations for launching/stopping scenes plus server tooling (`project_tools.ts`) wired into the MCP entrypoint.
- `get_editor_errors` command/tool to capture the Errors tab directly from the editor bottom panel, plus server/docs updates.
- Documentation updates covering the new tooling in `README.md`, `docs/testing-guide.md`, `docs/tool-prompt-guide.md`, and `docs/command-reference.md`.

### Fixed
- Resolved a Godot VM crash caused by strict typing in `_get_editor_interface` within `project_commands.gd`.
