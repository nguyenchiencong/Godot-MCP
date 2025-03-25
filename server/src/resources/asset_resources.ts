import { ResourceTemplate } from 'fastmcp';
import { getGodotConnection } from '../utils/godot_connection.js';
import { z } from 'zod';

/**
 * ResourceTemplate for retrieving asset lists by type
 */
export const assetListResource: ResourceTemplate = {
  uriTemplate: 'godot/assets/{type}',
  nameTemplate: 'Assets: {type}',
  mimeType: 'application/json',
  schema: z.object({ 
    type: z.enum(['images', 'audio', 'fonts', 'models', 'shaders', 'resources', 'all'])
      .describe('Type of assets to list')
  }),
  
  async load({ type }) {
    const godot = getGodotConnection();
    
    // Define file extensions for each asset type
    const extensionMap = {
      images: ['.png', '.jpg', '.jpeg', '.webp', '.svg', '.bmp', '.tga'],
      audio: ['.ogg', '.mp3', '.wav', '.opus'],
      fonts: ['.ttf', '.otf', '.fnt', '.font'],
      models: ['.glb', '.gltf', '.obj', '.fbx'],
      shaders: ['.gdshader', '.shader'],
      resources: ['.tres', '.res', '.theme', '.material'],
      all: [] // Will retrieve everything
    };
    
    try {
      // If type is 'all', we get all files without filtering
      const result = await godot.sendCommand('list_project_files', {
        extensions: extensionMap[type] || []
      });
      
      // Process results for better structure
      const files = result.files || [];
      
      // Group by folder structure for better navigation
      const organizedFiles = {};
      files.forEach(file => {
        const parts = file.split('/');
        let current = organizedFiles;
        
        // Skip the first "res://" part
        for (let i = 1; i < parts.length - 1; i++) {
          const part = parts[i];
          if (!current[part]) {
            current[part] = {};
          }
          current = current[part];
        }
        
        // For the leaf/filename
        const fileName = parts[parts.length - 1];
        current[fileName] = file;
      });
      
      return {
        text: JSON.stringify({
          assetType: type,
          extensions: extensionMap[type],
          count: files.length,
          files: files,
          organizedFiles: organizedFiles
        })
      };
    } catch (error) {
      console.error('Error fetching asset list:', error);
      throw error;
    }
  }
};