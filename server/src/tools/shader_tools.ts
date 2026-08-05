import { z } from 'zod';
import { getGodotConnection } from '../utils/godot_connection.js';
import { MCPTool, CommandResult } from '../utils/types.js';

/**
 * Type definitions for shader tool parameters
 */
interface CreateShaderParams {
  script_path: string;
  shader_type?: string;
  content?: string;
}

interface EditShaderParams {
  script_path: string;
  content: string;
}

interface GetShaderParams {
  script_path: string;
}

interface ShaderCompileErrorsParams {
  script_path?: string;
  wait_ms?: number;
}

interface ShaderListMaterialsParams {
  node_path?: string;
  material_slot?: string;
  wait_ms?: number;
}

interface ShaderGetUniformsParams {
  node_path: string;
  material_slot?: string;
  wait_ms?: number;
}

interface ShaderSetUniformParams {
  node_path: string;
  uniform_name: string;
  value: unknown;
  material_slot?: string;
  allow_shared?: boolean;
  wait_ms?: number;
}

/**
 * Renders the `diagnostics` field returned by create_shader/edit_shader/
 * shader_get_compile_errors into a concise one- or multi-line summary.
 * Returns an empty string when diagnostics are absent.
 */
function formatShaderDiagnostics(diagnostics: any): string {
  if (!diagnostics || diagnostics.length === 0) {
    return 'Diagnostics: no shader compile errors.';
  }
  let summary = `Diagnostics: ${diagnostics.length} issue(s):`;
  for (const entry of diagnostics) {
    const severity = entry.severity ?? 'error';
    const location = entry.line > 0 ? `line ${entry.line}` : 'unknown location';
    summary += `\n  [${severity} at ${location}] ${entry.message}`;
  }
  return summary;
}

/**
 * Definition for shader tools - operations that create, edit and inspect
 * .gdshader files, with compile diagnostics captured from the engine.
 */
export const shaderTools: MCPTool[] = [
  {
    name: 'create_shader',
    description: 'Create a new .gdshader file in the project; returns compile diagnostics from the editor recompile',
    parameters: z.object({
      script_path: z.string()
        .describe('Path where the shader will be saved (e.g. "res://shaders/outline.gdshader")'),
      shader_type: z.enum(['canvas_item', 'spatial', 'particles', 'sky', 'fog']).optional()
        .describe('Shader type used to generate a template when content is not provided'),
      content: z.string().optional()
        .describe('Full shader source; when absent, a template is generated from shader_type'),
    }).refine(
      ({ shader_type, content }) => shader_type !== undefined || content !== undefined,
      { message: 'Provide shader_type or explicit content', path: ['shader_type'] },
    ),
    execute: async ({ script_path, shader_type, content }: CreateShaderParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {
          script_path,
        };
        if (shader_type !== undefined) {
          params.shader_type = shader_type;
        }
        if (content !== undefined) {
          params.content = content;
        }
        const result = await godot.sendCommand<CommandResult>('create_shader', params);

        let output = `Created shader at ${result.path}`;
        const diagnosticsSummary = formatShaderDiagnostics(result.diagnostics);
        if (diagnosticsSummary) {
          output += `\n${diagnosticsSummary}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to create shader: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'edit_shader',
    description: 'Edit an existing .gdshader file; returns compile diagnostics from the editor recompile',
    parameters: z.object({
      script_path: z.string()
        .describe('Path to the shader file to edit (e.g. "res://shaders/outline.gdshader")'),
      content: z.string()
        .describe('New content of the shader'),
    }),
    execute: async ({ script_path, content }: EditShaderParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('edit_shader', {
          script_path,
          content,
        });

        let output = `Updated shader at ${result.path}`;
        const diagnosticsSummary = formatShaderDiagnostics(result.diagnostics);
        if (diagnosticsSummary) {
          output += `\n${diagnosticsSummary}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to edit shader: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'get_shader',
    description: 'Get the content of a .gdshader file',
    parameters: z.object({
      script_path: z.string()
        .describe('Path to the shader file (e.g. "res://shaders/outline.gdshader")'),
    }),
    execute: async ({ script_path }: GetShaderParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const result = await godot.sendCommand<CommandResult>('get_shader', {
          script_path,
        });

        return `Shader at ${result.path}:\n\n\`\`\`gdshader\n${result.content}\n\`\`\``;
      } catch (error) {
        throw new Error(`Failed to get shader: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_get_compile_errors',
    description: 'Return shader compile errors captured by the editor; use after a write when you want to re-check the last compile',
    parameters: z.object({
      script_path: z.string().optional()
        .describe('Only return errors for this shader file (e.g. "res://shaders/outline.gdshader")'),
      wait_ms: z.number().int().min(0).max(10000).optional()
        .describe('Milliseconds to wait before reading the captured error buffer (default 0)'),
    }),
    execute: async ({ script_path, wait_ms }: ShaderCompileErrorsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (script_path !== undefined) {
          params.script_path = script_path;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_get_compile_errors', params);

        const diagnosticsSummary = formatShaderDiagnostics(result.diagnostics);
        if (diagnosticsSummary) {
          return diagnosticsSummary;
        }
        return 'No shader compile errors captured.';
      } catch (error) {
        throw new Error(`Failed to get shader compile errors: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_list_materials',
    description: 'List ShaderMaterials used by nodes in the RUNNING game (not the editor scene). Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      node_path: z.string().optional()
        .describe('Subtree root in the running game (e.g. "/root/TestMainScene/ShaderVisuals"); defaults to the scene root'),
      material_slot: z.string().optional()
        .describe('Only report this material slot (e.g. "material", "material_override", "surface_0"); defaults to all slots'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ node_path, material_slot, wait_ms }: ShaderListMaterialsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (node_path !== undefined) {
          params.node_path = node_path;
        }
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_list_materials', params);

        const materials: any[] = result.materials ?? [];
        if (materials.length === 0) {
          return 'No ShaderMaterials found in the walked subtree.';
        }
        let output = `Found ${materials.length} ShaderMaterial(s):`;
        for (const m of materials) {
          output += `\n- ${m.node_path}`;
          output += `\n  slot: ${m.slot}`;
          output += `\n  material: ${m.material_path}`;
          if (m.shader_path) {
            output += `\n  shader: ${m.shader_path}`;
          }
          const sharing = m.sharing ?? {};
          const users: string[] = sharing.users ?? [];
          output += `\n  sharing: ${sharing.users_count ?? users.length} user(s)`;
          if (users.length > 0) {
            output += ` (${users.join(', ')})`;
          }
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to list shader materials: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_get_uniforms',
    description: 'Read the shader uniforms of a ShaderMaterial in the RUNNING game: live values plus type/hint/default metadata parsed from the shader source. Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      node_path: z.string()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SharedSpriteA")'),
      material_slot: z.string().optional()
        .describe('Material slot to read (default "material"; also "material_override", "surface_0", ...)'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ node_path, material_slot, wait_ms }: ShaderGetUniformsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { node_path };
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_get_uniforms', params);

        const uniforms: any[] = result.uniforms ?? [];
        let output = `Shader: ${result.shader_path || '(unknown)'} on ${result.node_path} (slot: ${result.slot})`;
        if (uniforms.length === 0) {
          output += '\nNo uniforms declared in shader source.';
          return output;
        }
        output += `\nUniforms (${uniforms.length}):`;
        for (const u of uniforms) {
          let line = `- ${u.name} (${u.type})`;
          if (u.array) {
            line += `[${u.array_size ?? ''}]`;
          }
          line += ` value=${JSON.stringify(u.value ?? null)}`;
          if (u.default !== null && u.default !== undefined) {
            line += ` default=${JSON.stringify(u.default)}`;
          }
          if (u.hint) {
            line += ` hint=${JSON.stringify(u.hint)}`;
          }
          output += `\n${line}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to get shader uniforms: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_set_uniform',
    description: 'Set a shader uniform on a ShaderMaterial in the RUNNING game. Serialized value forms: number, bool, [x,y], [x,y,z], [x,y,z,w], {r,g,b,a} or [r,g,b,a] for colors, a res:// string for textures, and a 16-number column-major array for transforms. Refuses shared materials unless allow_shared=true. Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      node_path: z.string()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SharedSpriteA")'),
      uniform_name: z.string()
        .describe('Name of the uniform to set (must be declared in the shader source)'),
      value: z.any()
        .refine((value) => value !== undefined, 'value is required')
        .describe('Serialized value: number, bool, [x,y]/[x,y,z]/[x,y,z,w], {r,g,b,a} or [r,g,b,a] (color), res:// string (texture), 16-number array (transform), or an array of these for array uniforms'),
      material_slot: z.string().optional()
        .describe('Material slot to modify (default "material")'),
      allow_shared: z.boolean().optional()
        .describe('Allow modifying a material shared by more than one node (default false)'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ node_path, uniform_name, value, material_slot, allow_shared, wait_ms }: ShaderSetUniformParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {
          node_path,
          uniform_name,
          value,
        };
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (allow_shared !== undefined) {
          params.allow_shared = allow_shared;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_set_uniform', params);

        let output = `Set uniform '${result.uniform_name}' on ${result.node_path} (slot: ${result.slot})`;
        output += `\nprevious: ${JSON.stringify(result.previous_value ?? null)}`;
        output += `\nnew: ${JSON.stringify(result.new_value ?? null)}`;
        const sharing = result.sharing ?? {};
        const users: string[] = sharing.users ?? [];
        output += `\nsharing: ${sharing.users_count ?? users.length} user(s)`;
        if (users.length > 0) {
          output += ` (${users.join(', ')})`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to set shader uniform: ${(error as Error).message}`);
      }
    },
  },
];
