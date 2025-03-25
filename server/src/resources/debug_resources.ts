import { Resource } from 'fastmcp';
import { getGodotConnection } from '../utils/godot_connection.js';

/**
 * Resource that provides access to Godot's debug output log
 */
export const debugOutputResource: Resource = {
  uri: 'godot/debug/log',
  name: 'Godot Debug Output',
  mimeType: 'text/plain',
  async load() {
    const godot = getGodotConnection();
    
    try {
      // Call a command on the Godot side to get debug output
      const result = await godot.sendCommand('get_debug_output');
      
      return {
        text: result.output || 'No debug output available.'
      };
    } catch (error) {
      console.error('Error fetching debug output:', error);
      throw error;
    }
  }
};