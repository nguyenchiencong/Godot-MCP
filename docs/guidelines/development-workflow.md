# Development Workflow

Standard flow for a change in this project.

1. **Branch** off `main`.
2. **Implement** in the relevant layer:
   - Godot commands: editor-side processor in `addons/godot_mcp/commands/*.gd`
     (register in `command_handler.gd`); game-side autoload if runtime state
     is needed.
   - Server tools: definition in `server/src/tools/*.ts`, import and spread in
     `server/src/index.ts`.
3. **Build:** `cd server && npm run build` (zero TS errors required).
4. **Test:** run the affected `--category`; run the full suite before merge.
   Use `--skip-runtime` when no game is attached.
5. **Docs:** keep `docs/command-reference.md`, `docs/tool-prompt-guide.md`,
   `CHANGELOG.md`, and `README.md` in sync with shipped behavior. Record
   significant decisions as an ADR under `docs/adr/`.
6. **Verify:** `git diff --check` clean; Godot editor error panel clean (ignore
   the known `test_debugger.gd:14` unused-parameter warning).
7. **Commit** with a clear message; open a PR against `main`.
