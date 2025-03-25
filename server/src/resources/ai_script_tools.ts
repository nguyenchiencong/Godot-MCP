import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool } from '../utils/types.js';

/**
 * Tool for generating GDScript with AI assistance using MCP
 */
export const aiScriptTemplateTool: MCPTool = {
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
      // Using the MCP command that's already defined in the Godot plugin
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
};

/**
 * Tool for node transform operations
 */
export const updateNodeTransformTool: MCPTool = {
  name: 'update_node_transform',
  description: 'Update position, rotation, or scale of a node',
  parameters: z.object({
    node_path: z.string()
      .describe('Path to the node to update (e.g. "/root/MainScene/Player")'),
    position: z.tuple([z.number(), z.number()]).optional()
      .describe('New position as [x, y]'),
    rotation: z.number().optional()
      .describe('New rotation in radians'),
    scale: z.tuple([z.number(), z.number()]).optional()
      .describe('New scale as [x, y]'),
  }),
  
  execute: async ({ node_path, position, rotation, scale }): Promise<string> => {
    const godot = getGodotConnection();
    
    try {
      const result = await godot.sendCommand('update_node_transform', {
        node_path,
        position,
        rotation,
        scale
      });
      
      let changeDescription = [];
      if (position) changeDescription.push(`position to (${position[0]}, ${position[1]})`);
      if (rotation !== undefined) changeDescription.push(`rotation to ${rotation.toFixed(2)} rad`);
      if (scale) changeDescription.push(`scale to (${scale[0]}, ${scale[1]})`);
      
      return `Updated ${changeDescription.join(', ')} for node at ${node_path}`;
    } catch (error) {
      throw new Error(`Failed to update node transform: ${(error as Error).message}`);
    }
  },
};