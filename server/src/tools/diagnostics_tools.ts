import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool, CommandResult } from '../utils/types.js';

/**
 * Type definitions for diagnostics tool parameters
 */
interface GetScriptDiagnosticsParams {
  script_path: string;
}

interface ValidateSceneParams {
  scene_path: string;
  check_instantiate?: boolean;
}

/**
 * A single script parse error reported by Godot.
 */
interface ScriptDiagnosticError {
  line: number;
  column: number;
  message: string;
}

/**
 * A single scene validation issue reported by Godot.
 */
interface SceneValidationIssue {
  severity: string;
  category: string;
  message: string;
  node_path?: string;
}

/**
 * Definition for diagnostics tools - script parsing feedback and scene
 * structural validation so agents do not work blind.
 */
export const diagnosticsTools: MCPTool[] = [
  {
    name: 'get_script_diagnostics',
    description: 'Parse a GDScript file and return compile/parse errors with line numbers. Use after creating or editing a script to immediately see what is broken.',
    parameters: z.object({
      script_path: z.string()
        .describe('Path to the GDScript file to diagnose (e.g. "res://scripts/player.gd")'),
    }),
    execute: async ({ script_path }: GetScriptDiagnosticsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('get_script_diagnostics', {
          script_path,
        });

        if (!result.exists) {
          return `Script ${result.script_path} does not exist.`;
        }

        const errors = (result.errors ?? []) as ScriptDiagnosticError[];
        if (errors.length === 0) {
          return `Script ${result.script_path} is valid (0 errors).`;
        }

        let output = `Script ${result.script_path} has ${errors.length} error(s):\n`;
        for (const error of errors) {
          const location = error.line > 0 ? `line ${error.line}` : 'unknown location';
          output += `  [${location}] ${error.message}\n`;
        }
        return output.trimEnd();
      } catch (error) {
        throw new Error(`Failed to get script diagnostics: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'validate_scene',
    description: 'Load a .tscn scene and check its structural health: loadability, instantiation, duplicate node names, missing external resources, and cyclic scene dependencies. Use after creating or editing a scene.',
    parameters: z.object({
      scene_path: z.string()
        .describe('Path to the scene file to validate (e.g. "res://scenes/main.tscn")'),
      check_instantiate: z.boolean().optional()
        .describe('Whether to run PackedScene.instantiate() as part of validation (default true); set false to skip the instantiation check for faster structural/dependency-only validation.'),
    }),
    execute: async ({ scene_path, check_instantiate }: ValidateSceneParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {
          scene_path,
        };
        if (check_instantiate !== undefined) {
          params.check_instantiate = check_instantiate;
        }
        const result = await godot.sendCommand<CommandResult>('validate_scene', params);

        const issues = (result.issues ?? []) as SceneValidationIssue[];
        if (issues.length === 0) {
          return `Scene ${result.scene_path} is valid (0 issues).`;
        }

        let output = `Scene ${result.scene_path} has ${issues.length} issue(s) (valid: ${result.valid}):\n`;
        for (const issue of issues) {
          const location = issue.node_path ? ` at ${issue.node_path}` : '';
          output += `  [${issue.severity}] ${issue.category}: ${issue.message}${location}\n`;
        }
        return output.trimEnd();
      } catch (error) {
        throw new Error(`Failed to validate scene: ${(error as Error).message}`);
      }
    },
  },
];
