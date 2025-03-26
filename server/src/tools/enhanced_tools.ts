// File: /server/src/tools/enhanced_tools.ts
import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool } from '../utils/types.js';

/**
 * Enhanced tools for more complex operations in Godot
 */
export const enhancedTools: MCPTool[] = [
  {
    name: 'get_full_scene_tree',
    description: 'Get the complete scene tree hierarchy of the current scene',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const result = await godot.sendCommand('get_full_scene_tree', {});
        
        if (!result || Object.keys(result).length === 0) {
          return 'No scene is currently open or the scene is empty.';
        }
        
        // Format the scene tree
        const formatNode = (node: any, depth = 0): string => {
          const indent = ' '.repeat(depth * 2);
          let output = `${indent}${node.name} (${node.type})`;
          
          if (node.children && node.children.length > 0) {
            output += '\n';
            output += node.children.map((child: any) => formatNode(child, depth + 1)).join('\n');
          }
          
          return output;
        };
        
        return `Scene Tree:\n${formatNode(result)}`;
      } catch (error) {
        throw new Error(`Failed to get scene tree: ${(error as Error).message}`);
      }
    },
  },
  
  {
    name: 'get_debug_output',
    description: 'Get the debug output from the Godot editor',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const result = await godot.sendCommand('get_debug_output', {});
        
        if (!result.output || result.output.length === 0) {
          return 'No debug output available.';
        }
        
        return `Debug Output:\n${result.output}`;
      } catch (error) {
        throw new Error(`Failed to get debug output: ${(error as Error).message}`);
      }
    },
  },
  
  {
    name: 'get_current_scene_structure',
    description: 'Get detailed information about the current scene structure',
    parameters: z.object({}),
    execute: async (): Promise<string> => {
      const godot = getGodotConnection();
      
      try {
        const result = await godot.sendCommand('get_current_scene_structure', {});
        
        if (!result.path) {
          return 'No scene is currently open.';
        }
        
        return `Current Scene: ${result.path}\nRoot Node: ${result.root_node_name} (${result.root_node_type})`;
      } catch (error) {
        throw new Error(`Failed to get scene structure: ${(error as Error).message}`);
      }
    },
  },
];