// File: /server/src/tools/capture_tools.ts
import { z } from 'zod';
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
}

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
    }),
    execute: async ({ scene_path, width, height, transparent, output_path }: CaptureSceneParams): Promise<MCPToolResult> => {
      const godot = getGodotConnection();

      const params: Record<string, unknown> = {};
      if (scene_path !== undefined) params.scene_path = scene_path;
      if (width !== undefined) params.width = width;
      if (height !== undefined) params.height = height;
      if (transparent !== undefined) params.transparent = transparent;
      if (output_path !== undefined) params.output_path = output_path;

      try {
        const result = await godot.sendCommand<CommandResult>('capture_scene', params);

        if (!result.image_base64) {
          throw new Error('Capture response did not include an image (image_base64 missing)');
        }

        const filePath = result.file_path ?? result.absolute_path ?? 'a temporary file';
        const text = `Scene captured and saved to ${filePath} (${result.width ?? '?'}x${result.height ?? '?'}).`;

        return {
          content: [
            { type: 'image', data: result.image_base64, mimeType: 'image/png' },
            { type: 'text', text },
          ],
        };
      } catch (error) {
        throw new Error(`Failed to capture scene: ${(error as Error).message}`);
      }
    },
  },
];
