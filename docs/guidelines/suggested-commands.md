# Suggested Commands

## TypeScript server
- **Build:** `cd server && npm run build`
- **Start:** `cd server && npm run start`
- **Dev (auto-rebuild):** `cd server && npm run dev`

## Tests
- **Full suite:** `cd server && node tests/tools.test.js`
- **Single category:** `node tests/tools.test.js --category=<cat>`
  (categories: `node`, `script`, `shader`, `scene`, `project`, `editor`,
  `asset`, `debugger`, `input`, `enhanced`)
- **Skip running-game tests:** add `--skip-runtime`
- Runtime tests (debugger, input, shader runtime) require a game launched from
  the editor with the debugger attached (F5).

## Godot editor
- **Binary:** `D:\Godot\GodotEngine\godot.exe`
- **Open project:** `godot.exe --path <project> --editor`
- **Renderer:** GL Compatibility
- After plugin/autoload changes, restart the editor to apply them.
