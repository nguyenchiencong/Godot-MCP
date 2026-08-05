# ADR-001: Shader Tooling Architecture

Date: 2026-08-05
Status: Accepted

## Context

The MCP server had no shader support. We needed tools to author `.gdshader`
files with reliable compile feedback and to inspect/modify ShaderMaterials in a
running game. Two engine constraints drove the design:

1. **Compile errors are not returned by any API.** `Shader.set_code()` returns
   no result and `Shader.get_shader_uniform_list()` is unreliable for this
   purpose; the only reliable signal is the shader compile error the engine
   logs internally. Parsing the editor Output panel was considered but is
   brittle (unstructured text, mixed with unrelated output) and unavailable
   headless.

2. **Runtime shader inspection needs recursive scene walks** (collect every
   material slot across a subtree, detect material sharing across nodes). The
   existing game-side eval pipe (`Expression` over the debugger) cannot express
   a recursive walk in a single expression, and there is no reliable receiver
   for arbitrary eval on the game side beyond the one-off `mcp_eval` capture.

## Decision

- **Authoring compile diagnostics via a custom `Logger`.** Install
  `MCPShaderErrorLogger` through `OS.add_logger()`; it filters
  `Logger.ERROR_TYPE_SHADER` into a thread-safe, mutex-guarded buffer
  correlated by an atomic sequence marker (`record_marker`/`drain_since`).
  After a write, force a fresh load (`CACHE_MODE_REPLACE`) plus
  `Shader.get_rid()` (triggers the lazy compile), then drain new errors. Output
  parsing was rejected.

- **Runtime tools via a dedicated game-side capture protocol.** Add a
  `MCPShaderRuntime` autoload that registers the `EngineDebugger` capture
  `mcp_shader` and answers `list_materials`/`get_uniforms`/`set_uniform` with
  primitives-only payloads. The editor-side `MCPRuntimeDebuggerBridge` routes
  `mcp_shader:result` replies into a per-session, id-correlated, bounded result
  store (cap 64, 120 s age eviction). This is used instead of the eval pipe.

- **Phased scope.** Phase A = authoring tools; Phase B = runtime tools.
  Viewport capture for shaders was deferred: the existing `capture_scene` tool
  already gives visual verification.

- **Safety posture.** Runtime writes use strict value coercion (reject
  non-numeric scalars, wrong-length arrays/vectors/transforms, paths outside
  `res://`) and refuse shared materials unless `allow_shared=true`.

## Consequences

- A custom `Logger` instance is added/removed with the plugin lifecycle; it
  captures shader errors for the whole editor session and is GC-safe via
  `OS.remove_logger()` on shutdown.
- A new `MCPShaderRuntime` autoload is auto-registered by the plugin (like
  `MCPInputHandler`) and only active in a running game.
- Compile diagnostics depend on the engine logging errors, which is reliable
  but renderer-dependent (GL Compatibility surfaces some errors with an empty
  file field, handled by marker correlation + tolerant path filtering).
- Marker correlation serializes overlapping writes so concurrent edits cannot
  cross-contaminate diagnostic windows.
