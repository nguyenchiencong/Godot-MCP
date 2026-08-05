#!/usr/bin/env node

/**
 * Permanent LIVE integration coverage for NON-BLOCKING ASYNC DIAGNOSTICS.
 *
 * The Godot-side `get_script_diagnostics` command for a BROKEN script takes
 * the slow path: the in-process parse fails, so a headless child Godot
 * process is spawned via OS.execute on a dedicated worker thread while the
 * command coroutine awaits process_frame liveness polls. This must NOT block
 * the editor main thread: while that worker runs, other commands (e.g.
 * `get_project_info`) must still be dispatched and answered promptly.
 *
 * This test proves that property end-to-end against a LIVE editor:
 *   - create a unique broken script (a unique path per run also defeats the
 *     Godot-side subprocess diagnostics cache),
 *   - fire `get_script_diagnostics` and ~10ms later `get_project_info`
 *     concurrently,
 *   - assert `get_project_info` completes STRICTLY before the diagnostics
 *     command (signal-driven command dispatch / editor main thread stayed
 *     responsive while the OS.execute worker ran). No brittle wall-clock
 *     maximum is used; the only hard bound is the connection's overall
 *     per-command timeout (20s).
 *
 * Requires:
 *   1. Godot editor running with the MCP plugin enabled
 *   2. WebSocket server on ws://127.0.0.1:9080
 *   3. `npm run build` beforehand (imports dist/utils/godot_connection.js)
 *
 *   node tests/async_diagnostics.test.js
 */

import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { GodotConnection } from '../dist/utils/godot_connection.js';

const MCP_URL = 'ws://127.0.0.1:9080';
// Overall per-command timeout: the only hard timing bound in this test.
const COMMAND_TIMEOUT_MS = 20000;
// Short retryDelay so the post-disconnect cleanup wait stays short and no
// reconnect timer can outlive the process (see cleanup in finally below).
const RETRY_DELAY_MS = 100;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Project root = parent of server/ (tests/ -> server/ -> project root).
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(__dirname, '..', '..');

// Unique name per run: the Godot-side diagnostics cache is keyed by
// "path|content_digest", so a fresh path always exercises the full
// in-process parse + OS.execute worker path instead of a cache hit.
const SCRIPT_NAME = `test_async_diagnostics_${Date.now()}.gd`;
const SCRIPT_FS_PATH = path.join(PROJECT_ROOT, SCRIPT_NAME);
const SCRIPT_UID_PATH = `${SCRIPT_FS_PATH}.uid`;
const SCRIPT_RES_PATH = `res://${SCRIPT_NAME}`;

// Deliberately broken GDScript: the in-process parse fails, forcing the
// headless OS.execute subprocess path that the non-blocking property tests.
const BROKEN_SCRIPT_CONTENT = 'extends Node\nfunc broken():\n\tvar value = \n';

/** Remove the script and its possible .uid sidecar (idempotent). */
function removeArtifacts() {
  for (const p of [SCRIPT_FS_PATH, SCRIPT_UID_PATH]) {
    try {
      fs.rmSync(p, { force: true });
    } catch {
      /* ignore */
    }
  }
}

async function main() {
  const connection = new GodotConnection(MCP_URL, COMMAND_TIMEOUT_MS, 3, RETRY_DELAY_MS);
  try {
    // Create the unique broken script before connecting so that even a
    // failed connect still cleans it up in the finally block below.
    fs.writeFileSync(SCRIPT_FS_PATH, BROKEN_SCRIPT_CONTENT, 'utf8');
    console.log(`[async-diagnostics] created ${SCRIPT_RES_PATH}`);

    try {
      await connection.connect();
    } catch (error) {
      throw new Error(
        `Could not connect to the live Godot MCP server at ${MCP_URL} ` +
          `(is the editor running with the MCP plugin enabled?): ${error.message}`
      );
    }
    assert.ok(connection.isConnected(), 'should be connected to the live editor');
    console.log(`[async-diagnostics] connected to ${MCP_URL}`);

    // Start the slow diagnostics command and record its start time.
    const diagnosticsStart = performance.now();
    // Each promise timestamps itself at ACTUAL settlement: recording
    // completion times after awaiting one promise before the other would
    // skew the comparison (whichever we awaited first would always look
    // "earlier", regardless of real completion order).
    const diagnosticsPromise = connection
      .sendCommand('get_script_diagnostics', {
        script_path: SCRIPT_RES_PATH,
      })
      .then((result) => ({ result, completedAt: performance.now() }));

    // ~10ms later fire get_project_info while diagnostics is still running.
    await sleep(10);
    const infoStart = performance.now();
    const infoPromise = connection
      .sendCommand('get_project_info', {})
      .then((result) => ({ result, completedAt: performance.now() }));

    // Await both concurrently; each outcome carries the wall-clock time at
    // which ITS promise actually settled, so the comparison below reflects
    // real completion order (info settles whenever the editor answers it,
    // diagnostics potentially seconds later when the worker thread's
    // headless child finishes).
    const [diagnosticsOutcome, infoOutcome] = await Promise.all([
      diagnosticsPromise,
      infoPromise,
    ]);
    const diagnostics = diagnosticsOutcome.result;
    const info = infoOutcome.result;
    const diagnosticsTime = diagnosticsOutcome.completedAt;
    const infoTime = infoOutcome.completedAt;

    const infoElapsed = infoTime - infoStart;
    const diagnosticsElapsed = diagnosticsTime - diagnosticsStart;

    // --- Assertions -----------------------------------------------------
    // 1. The broken script must be reported as broken with >= 1 error.
    assert.ok(
      diagnostics && typeof diagnostics === 'object',
      'diagnostics result must be an object'
    );
    assert.ok(
      Number.isInteger(diagnostics.error_count) && diagnostics.error_count >= 1,
      `diagnostics error_count must be >= 1, got: ${JSON.stringify(diagnostics.error_count)}`
    );
    assert.ok(
      Array.isArray(diagnostics.errors) && diagnostics.errors.length >= 1,
      'diagnostics.errors must be a non-empty array'
    );

    // 2. Each reported error carries a line and a non-empty message.
    for (const error of diagnostics.errors) {
      assert.ok(
        Number.isInteger(error.line) && error.line >= 1,
        `diagnostics error must carry a line number >= 1, got: ${JSON.stringify(error)}`
      );
      assert.ok(
        typeof error.message === 'string' && error.message.length > 0,
        `diagnostics error must carry a non-empty message, got: ${JSON.stringify(error)}`
      );
    }

    // 3. get_project_info must be answered while the diagnostics worker is
    //    still running: project_name is present and the project-info
    //    COMPLETION TIME is STRICTLY less than the diagnostics completion
    //    time. If the editor main thread were blocked by OS.execute, both
    //    responses would arrive back-to-back at the subprocess finish and
    //    this strict inequality would fail.
    assert.ok(
      typeof info?.project_name === 'string' && info.project_name.length > 0,
      `get_project_info must include project_name, got: ${JSON.stringify(info)}`
    );
    assert.ok(
      infoTime < diagnosticsTime,
      `get_project_info must complete STRICTLY before get_script_diagnostics ` +
        `(info completed at ${infoTime.toFixed(1)}ms, diagnostics at ` +
        `${diagnosticsTime.toFixed(1)}ms)`
    );
    assert.ok(
      infoElapsed < diagnosticsElapsed,
      `get_project_info elapsed (${infoElapsed.toFixed(1)}ms) must be strictly ` +
        `less than diagnostics elapsed (${diagnosticsElapsed.toFixed(1)}ms)`
    );

    // --- Timing summary -------------------------------------------------
    console.log('\nAsync diagnostics timing summary:');
    console.log(`  broken script:            ${SCRIPT_RES_PATH}`);
    console.log(`  error_count:              ${diagnostics.error_count}`);
    console.log(`  first error:              line ${diagnostics.errors[0].line}: ${diagnostics.errors[0].message}`);
    console.log(`  project_name:             ${info.project_name}`);
    console.log(`  get_project_info:         ${infoElapsed.toFixed(1)} ms (completed at ${infoTime.toFixed(1)} ms)`);
    console.log(`  get_script_diagnostics:   ${diagnosticsElapsed.toFixed(1)} ms (completed at ${diagnosticsTime.toFixed(1)} ms)`);
    console.log(`  editor stayed responsive: ${infoTime.toFixed(1)} ms < ${diagnosticsTime.toFixed(1)} ms (strict)`);
    console.log('\nAsync diagnostics tests passed');
  } finally {
    // Remove the script + any .uid sidecar immediately, disconnect, wait
    // past the short retryDelay so no reconnect timer can fire, then remove
    // the sidecar again after a small delay to catch an editor-generated
    // late .uid file. No process.exit(): the process must terminate
    // naturally once the event loop drains.
    removeArtifacts();
    connection.disconnect();
    await sleep(RETRY_DELAY_MS * 3); // 300ms > retryDelay (100ms)
    await sleep(400); // small delay for a late editor-generated .uid
    removeArtifacts();
  }
}

main().catch((error) => {
  console.error(
    'Async diagnostics tests FAILED:',
    error && error.stack ? error.stack : error
  );
  process.exit(1);
});
