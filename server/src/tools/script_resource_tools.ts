// File: /server/src/tools/script_resource_tools.ts
import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool } from '../utils/types.js';

/**
 * Tools for script resources in Godot
 */
export const scriptResourceTools: MCPTool[] = [
  {
    name: 'ai_generate_script',
    description: 'Generate a GDScript template based on a natural language description',
    parameters: z.object({
      description: z.string()
        .describe('Description of what the script should do (e.g. "A player controller for a 2D platformer")'),
      node_type: z.string().optional()
        .describe('The type of node this script is for (e.g. "CharacterBody2D", "Node2D")'),
      create_file: z.boolean().optional()
        .describe('Whether to create a new script file with the generated content'),
      file_path: z.string().optional()
        .describe('Path where to save the script (only used if create_file is true)'),
    }),
    
    execute: async ({ description, node_type = "Node", create_file = false, file_path = "" }): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const result = await godot.sendCommand('ai_generate_script', {
          description,
          node_type,
          create_file,
          file_path
        });
        
        if (create_file && file_path && result.success) {
          return `Generated script based on "${description}" and saved to ${file_path}:\n\n\`\`\`gdscript\n${result.content}\n\`\`\``;
        }
        
        return `Generated script based on "${description}":\n\n\`\`\`gdscript\n${result.content}\n\`\`\``;
      } catch (error) {
        throw new Error(`Failed to generate script: ${(error as Error).message}`);
      }
    },
  },
];