// File: /server/src/tools/capture_tools.ts
import { z } from 'zod';
import { readFile } from 'node:fs/promises';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool, MCPToolResult, CommandResult } from '../utils/types.js';

/**
 * Capture tools provide visual feedback to AI models.
 * They render a Godot scene into an off-screen viewport, save the PNG,
 * and return the image as an MCP image content block.
 */

interface CaptureSceneParams {
  scene_path?: string;
  width?: number;
  height?: number;
  transparent?: boolean;
  output_path?: string;
  return_base64?: boolean;
  allow_large?: boolean;
}

interface CaptureRunningGameParams {
  output_path?: string;
  return_base64?: boolean;
  allow_large?: boolean;
  wait_ms?: number;
}

/** Safety cap on capture area (width x height); mirrors the GDScript-side guard. */
const MAX_CAPTURE_PIXELS = 4000000;

/**
 * Definition for the scene capture tool.
 */
export const captureTools: MCPTool[] = [
  {
    name: 'capture_scene',
    description: 'Render a Godot scene into an off-screen viewport and return the resulting PNG image so the AI can see the current visual state of the scene. Use this before and after edits to verify how changes look.',
    parameters: z.object({
      scene_path: z.string().optional()
        .describe('res:// path of the scene to capture (e.g. "res://scenes/main.tscn"). If omitted, the scene currently open in the editor is used.'),
      width: z.number().int().min(1).max(8192).optional()
        .describe('Capture width in pixels (default: 1280).'),
      height: z.number().int().min(1).max(8192).optional()
        .describe('Capture height in pixels (default: 720).'),
      transparent: z.boolean().optional()
        .describe('Whether the background should be transparent (default: false).'),
      output_path: z.string().optional()
        .describe('Absolute or res:// path where the PNG should also be saved. Defaults to a file under user://mcp_captures.'),
      return_base64: z.boolean().optional()
        .describe('Whether the response should include the PNG as base64 in addition to writing it to disk (default: false; the PNG is read from disk instead).'),
      allow_large: z.boolean().optional()
        .describe('Allow captures larger than 4,000,000 pixels (width x height). Defaults to false to protect memory.'),
    }),
    execute: async ({ scene_path, width, height, transparent, output_path, return_base64, allow_large }: CaptureSceneParams): Promise<MCPToolResult> => {
      const godot = getGodotConnection();

      // Client-side mirror of the GDScript guard: refuse huge captures unless explicitly allowed.
      if (width !== undefined && height !== undefined && width * height > MAX_CAPTURE_PIXELS && allow_large !== true) {
        throw new Error(`Capture size ${width}x${height} (${width * height} pixels) exceeds the ${MAX_CAPTURE_PIXELS} pixel limit. Set allow_large: true to permit larger captures.`);
      }

      const params: Record<string, unknown> = {};
      if (scene_path !== undefined) params.scene_path = scene_path;
      if (width !== undefined) params.width = width;
      if (height !== undefined) params.height = height;
      if (transparent !== undefined) params.transparent = transparent;
      if (output_path !== undefined) params.output_path = output_path;
      if (return_base64 !== undefined) params.return_base64 = return_base64;
      if (allow_large !== undefined) params.allow_large = allow_large;

      try {
        const result = await godot.sendCommand<CommandResult>('capture_scene', params);

        let imageData: string;
        if (result.image_base64) {
          // Backward compatible: GDScript returned the PNG as base64 directly.
          imageData = result.image_base64;
        } else {
          // New default: read the PNG file that Godot wrote to disk.
          const absolutePath = result.absolute_path;
          if (!absolutePath) {
            throw new Error('Capture response did not include an image (image_base64 missing) and no absolute_path was returned');
          }
          try {
            const buf = await readFile(absolutePath);
            imageData = buf.toString('base64');
          } catch (readError) {
            throw new Error(`Failed to read captured PNG at ${absolutePath}: ${(readError as Error).message}`);
          }
        }

        const filePath = result.file_path ?? result.absolute_path ?? 'a temporary file';
        const text = `Scene captured and saved to ${filePath} (${result.width ?? '?'}x${result.height ?? '?'}).`;

        return {
          content: [
            { type: 'image', data: imageData, mimeType: 'image/png' },
            { type: 'text', text },
          ],
        };
      } catch (error) {
        throw new Error(`Failed to capture scene: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'capture_running_game',
    description: 'Capture the current rendered frame of the RUNNING game\'s root viewport (game must be running from the editor with the debugger attached). The PNG is saved under user://mcp_captures (or output_path) and returned as an image block so the AI can see the live game. Accepts up to one frame of latency: a change made in the same turn may still show the pre-change frame',
    parameters: z.object({
      output_path: z.string().optional()
        .describe('Absolute or user:// path where the PNG should also be saved. Defaults to a file under user://mcp_captures.'),
      return_base64: z.boolean().optional()
        .describe('Whether the response should include the PNG as base64 in addition to writing it to disk (default: false; the PNG is read from disk instead).'),
      allow_large: z.boolean().optional()
        .describe('Allow captures larger than 4,000,000 pixels. Defaults to false to protect memory.'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 3000).'),
    }),
    execute: async ({ output_path, return_base64, allow_large, wait_ms }: CaptureRunningGameParams): Promise<MCPToolResult> => {
      const godot = getGodotConnection();

      const params: Record<string, unknown> = {};
      if (output_path !== undefined) params.output_path = output_path;
      if (return_base64 !== undefined) params.return_base64 = return_base64;
      if (allow_large !== undefined) params.allow_large = allow_large;
      if (wait_ms !== undefined) params.wait_ms = wait_ms;

      try {
        const result = await godot.sendCommand<CommandResult>('capture_running_game', params);

        let imageData: string;
        if (result.image_base64) {
          // Backward compatible: GDScript returned the PNG as base64 directly.
          imageData = result.image_base64;
        } else {
          // Default: read the PNG file that the game wrote to disk (the game
          // and the editor share the project's user:// data directory).
          const absolutePath = result.absolute_path;
          if (!absolutePath) {
            throw new Error('Capture response did not include an image (image_base64 missing) and no absolute_path was returned');
          }
          try {
            const buf = await readFile(absolutePath);
            imageData = buf.toString('base64');
          } catch (readError) {
            throw new Error(`Failed to read captured PNG at ${absolutePath}: ${(readError as Error).message}`);
          }
        }

        const filePath = result.file_path ?? result.absolute_path ?? 'a temporary file';
        const text = `Running game frame captured and saved to ${filePath} (${result.width ?? '?'}x${result.height ?? '?'}).`;

        return {
          content: [
            { type: 'image', data: imageData, mimeType: 'image/png' },
            { type: 'text', text },
          ],
        };
      } catch (error) {
        throw new Error(`Failed to capture running game: ${(error as Error).message}`);
      }
    },
  },
];
