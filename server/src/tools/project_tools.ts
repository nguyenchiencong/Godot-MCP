import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool, CommandResult } from '../utils/types.js';

interface RunSpecificSceneParams {
  scene_path: string;
}

interface GenerateProjectGuidanceParams {
  include_agents_md?: boolean;
  force?: boolean;
}

/**
 * Tools for running and stopping the project or specific scenes from the editor.
 */
export const projectTools: MCPTool[] = [
  {
    name: 'run_project',
    description: 'Run the project using the configured main scene',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('run_project');
        const scenePath = result?.scene_path ?? ProjectRunMessages.unknownScene;
        return `Running project using main scene: ${scenePath}`;
      } catch (error) {
        throw new Error(`Failed to run project: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'stop_running_project',
    description: 'Stop any scene currently running in the editor',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('stop_running_project');
        const status = result?.status ?? 'unknown';
        if (status === 'idle') {
          return 'Editor is not currently running a scene.';
        }
        return 'Stopped the running scene.';
      } catch (error) {
        throw new Error(`Failed to stop running project: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'run_current_scene',
    description: 'Run the scene currently open in the editor',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('run_current_scene');
        const scenePath = result?.scene_path ?? ProjectRunMessages.unknownScene;
        return `Running current scene: ${scenePath}`;
      } catch (error) {
        throw new Error(`Failed to run current scene: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'run_specific_scene',
    description: 'Run a specific scene by providing its resource path',
    parameters: z.object({
      scene_path: z.string()
        .describe('Absolute resource path to the scene (e.g. "res://scenes/main.tscn")'),
    }),
    execute: async ({ scene_path }: RunSpecificSceneParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('run_specific_scene', { scene_path });
        const scenePath = result?.scene_path ?? scene_path;
        return `Running scene: ${scenePath}`;
      } catch (error) {
        throw new Error(`Failed to run scene "${scene_path}": ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'generate_project_guidance',
    description: 'Scan the Godot project and write markdown guidance files (a project guide and optionally AGENTS.md) that AI agents can read instead of guessing at the project structure',
    parameters: z.object({
      include_agents_md: z.boolean().optional()
        .describe('Also write or update res://AGENTS.md at the project root with the project guide (default: false)'),
      force: z.boolean().optional()
        .describe('When true, replace an existing res://AGENTS.md entirely. When false and AGENTS.md already exists, the guide section is appended instead of clobbering it (default: false)'),
    }),
    execute: async (params: GenerateProjectGuidanceParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const commandParams: Record<string, unknown> = {};
        if (params.include_agents_md !== undefined) {
          commandParams.include_agents_md = params.include_agents_md;
        }
        if (params.force !== undefined) {
          commandParams.force = params.force;
        }

        const result = await godot.sendCommand<CommandResult>('generate_project_guidance', commandParams);
        return formatGuidanceSummary(result);
      } catch (error) {
        throw new Error(`Failed to generate project guidance: ${(error as Error).message}`);
      }
    },
  },
];

const ProjectRunMessages = {
  unknownScene: 'unknown scene',
} as const;

function formatGuidanceSummary(result: CommandResult): string {
  const writtenPaths: string[] = Array.isArray(result?.written_paths) ? (result.written_paths as string[]) : [];
  const sceneCount = Number(result?.scene_count ?? 0);
  const autoloadCount = Number(result?.autoload_count ?? 0);
  const inputActionCount = Number(result?.input_action_count ?? 0);
  const guidePath = String(result?.guide_path ?? 'unknown path');
  const agentsMdPath = result?.agents_md_path ? String(result.agents_md_path) : '';
  const action = String(result?.action ?? 'unknown');

  const summary: string[] = [
    `Generated project guidance at ${guidePath}.`,
    `Project facts: ${sceneCount} scenes, ${autoloadCount} autoloads, ${inputActionCount} custom input actions.`,
  ];

  if (writtenPaths.length > 0) {
    summary.push('Written files:');
    writtenPaths.forEach((path) => summary.push(`- ${path}`));
  }

  if (agentsMdPath) {
    if (action === 'appended') {
      summary.push(`AGENTS.md already existed; the project guide section was appended to ${agentsMdPath} (not replaced).`);
    } else if (action === 'replaced') {
      summary.push(`AGENTS.md was replaced entirely with the generated guidance at ${agentsMdPath}.`);
    } else if (action === 'created') {
      summary.push(`Created AGENTS.md at ${agentsMdPath}.`);
    } else if (action === 'skipped') {
      summary.push(`AGENTS.md was not modified (include_agents_md was not requested).`);
    }
  }

  return summary.join('\n');
}
