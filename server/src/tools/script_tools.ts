import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool, CommandResult } from '../utils/types.js';

/**
 * Type definitions for script tool parameters
 */
interface CreateScriptParams {
  script_path: string;
  content: string;
  node_path?: string;
  diagnostics?: boolean;
}

interface EditScriptParams {
  script_path: string;
  content: string;
  diagnostics?: boolean;
}

interface GetScriptParams {
  script_path?: string;
  node_path?: string;
}

/**
 * Renders the `diagnostics` field returned by create_script/edit_script into
 * a concise one- or multi-line summary. Returns an empty string when
 * diagnostics were not requested or are absent from the result.
 */
function formatDiagnostics(diagnostics: any): string {
  if (!diagnostics) {
    return '';
  }
  if (typeof diagnostics.error === 'string' && diagnostics.error.length > 0) {
    return `Diagnostics unavailable: ${diagnostics.error}`;
  }
  if (diagnostics.valid) {
    return 'Diagnostics: valid (0 errors).';
  }
  const errorCount = diagnostics.error_count ?? (diagnostics.errors?.length ?? 0);
  let summary = `Diagnostics: ${errorCount} error(s):`;
  for (const error of diagnostics.errors ?? []) {
    const location = error.line > 0 ? `line ${error.line}` : 'unknown location';
    summary += `\n  [${location}] ${error.message}`;
  }
  return summary;
}

/**
 * Definition for script tools - operations that manipulate GDScript files
 */
export const scriptTools: MCPTool[] = [
  {
    name: 'create_script',
    description: 'Create a new GDScript file in the project',
    parameters: z.object({
      script_path: z.string()
        .describe('Path where the script will be saved (e.g. "res://scripts/player.gd")'),
      content: z.string()
        .describe('Content of the script'),
      node_path: z.string().optional()
        .describe('Path to a node to attach the script to (optional)'),
      diagnostics: z.boolean().optional()
        .describe('Run GDScript diagnostics after writing (default true); set false to skip the headless parse fallback for faster writes.'),
    }),
    execute: async ({ script_path, content, node_path, diagnostics }: CreateScriptParams): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const params: Record<string, any> = {
          script_path,
          content,
        };
        if (node_path !== undefined) {
          params.node_path = node_path;
        }
        if (diagnostics !== undefined) {
          params.diagnostics = diagnostics;
        }
        const result = await godot.sendCommand<CommandResult>('create_script', params);
        
        const attachMessage = node_path 
          ? ` and attached to node at ${node_path}` 
          : '';
        
        let output = `Created script at ${result.script_path}${attachMessage}`;
        const diagnosticsSummary = formatDiagnostics(result.diagnostics);
        if (diagnosticsSummary) {
          output += `\n${diagnosticsSummary}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to create script: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'edit_script',
    description: 'Edit an existing GDScript file',
    parameters: z.object({
      script_path: z.string()
        .describe('Path to the script file to edit (e.g. "res://scripts/player.gd")'),
      content: z.string()
        .describe('New content of the script'),
      diagnostics: z.boolean().optional()
        .describe('Run GDScript diagnostics after writing (default true); set false to skip the headless parse fallback for faster writes.'),
    }),
    execute: async ({ script_path, content, diagnostics }: EditScriptParams): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const params: Record<string, any> = {
          script_path,
          content,
        };
        if (diagnostics !== undefined) {
          params.diagnostics = diagnostics;
        }
        const result = await godot.sendCommand<CommandResult>('edit_script', params);
        
        let output = `Updated script at ${result.script_path}`;
        const diagnosticsSummary = formatDiagnostics(result.diagnostics);
        if (diagnosticsSummary) {
          output += `\n${diagnosticsSummary}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to edit script: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'get_script',
    description: 'Get the content of a GDScript file',
    parameters: z.object({
      script_path: z.string().optional()
        .describe('Path to the script file (e.g. "res://scripts/player.gd")'),
      node_path: z.string().optional()
        .describe('Path to a node with a script attached'),
    }).refine(data => data.script_path !== undefined || data.node_path !== undefined, {
      message: "Either script_path or node_path must be provided",
    }),
    execute: async ({ script_path, node_path }: GetScriptParams): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const result = await godot.sendCommand<CommandResult>('get_script', {
          script_path,
          node_path,
        });
        
        return `Script at ${result.script_path}:\n\n\`\`\`gdscript\n${result.content}\n\`\`\``;
      } catch (error) {
        throw new Error(`Failed to get script: ${(error as Error).message}`);
      }
    },
  },
];
