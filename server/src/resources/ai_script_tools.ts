import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool } from '../utils/types.js';

/**
 * Tool for generating GDScript with AI assistance
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
    // This function would ideally connect to an LLM API
    // For now, we'll use a template approach as a placeholder
    
    // Generate a template based on the description and node_type
    let scriptContent = generateScriptTemplate(description, node_type);
    
    // If requested, create the file in Godot
    if (create_file && file_path) {
      const godot = getGodotConnection();
      
      try {
        await godot.sendCommand('create_script', {
          script_path: file_path,
          content: scriptContent
        });
        
        return `Generated script based on "${description}" and saved to ${file_path}:\n\n\`\`\`gdscript\n${scriptContent}\n\`\`\``;
      } catch (error) {
        throw new Error(`Failed to create script file: ${(error as Error).message}`);
      }
    }
    
    return `Generated script based on "${description}":\n\n\`\`\`gdscript\n${scriptContent}\n\`\`\``;
  },
};

/**
 * Simple template generator function (placeholder for LLM integration)
 */
function generateScriptTemplate(description: string, nodeType: string): string {
  const className = nodeType.replace(/[^a-zA-Z0-9_]/g, '');
  
  // Sanitize description for comments
  const safeDescription = description.replace(/[#]/, '');
  
  // Create a basic template
  return `# ${safeDescription}
extends ${nodeType}

# Signals

# Export variables

# Private variables

func _ready():
	# Initialize the ${nodeType}
	pass

func _process(delta):
	# Process logic for ${safeDescription}
	pass

# Custom methods

`;
}

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
    const updates: Record<string, any> = {};
    
    if (position) {
      updates.position = { x: position[0], y: position[1] };
    }
    
    if (rotation !== undefined) {
      updates.rotation = rotation;
    }
    
    if (scale) {
      updates.scale = { x: scale[0], y: scale[1] };
    }
    
    try {
      await godot.sendCommand('update_node_property', {
        node_path,
        property: '_transform',
        value: updates
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