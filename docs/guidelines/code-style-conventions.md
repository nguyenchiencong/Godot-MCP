# Code Style Conventions

Concise rules for this project. Apply consistently to new code.

## GDScript
- No emoji anywhere (code, comments, docs).
- No C-style conditional operator. Use the Python-style form
  `value_if_true if condition else value_if_false`; `cond ? a : b` is a parse error.
- Descriptive names; keep functions small and focused.
- Comment complex logic (non-obvious algorithmic steps, engine quirks).
- Prefer assertions and explicit early returns over deep nesting.
- Guard multi-threaded shared state with `Mutex` (e.g. logger buffers).
- Close/release resources explicitly (`file = null` after `FileAccess` use).

## TypeScript (server/src/)
- `try/catch` around tool `execute` bodies; rethrow with a clear message.
- Define parameter interfaces and `z.object` schemas for every tool.
- Keep tool formatters concise; surface errors as thrown `Error`.

## General
- Match existing patterns in the surrounding file; consistency beats preference.
- Do not create or update Todo lists for MCP commands.
