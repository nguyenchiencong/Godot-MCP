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
  node_path?: string;
  shader_path?: string;
  uniform_name: string;
  value: unknown;
  material_slot?: string;
  allow_shared?: boolean;
  wait_ms?: number;
}

interface ShaderDebugSnapshotParams {
  node_path: string;
  material_slot?: string;
}

interface ShaderHotReloadParams {
  shader_path?: string;
  node_path?: string;
  material_slot?: string;
  content: string;
}

interface ShaderDebugOverlayParams {
  mode: 'wireframe' | 'normal' | 'off';
  viewport_index?: number;
  wait_ms?: number;
}

interface ShaderDebugVisualizeParams {
  node_path: string;
  mode: 'uv' | 'normals' | 'screen_pos' | 'world_pos' | 'custom' | 'off';
  expression?: string;
  material_slot?: string;
  wait_ms?: number;
}

interface ShaderGetWarningsParams {
  script_path?: string;
  wait_ms?: number;
}

interface ShaderProjectHealthParams {
  wait_ms?: number;
}

interface ShaderResetUniformsParams {
  node_path: string;
  material_slot?: string;
  wait_ms?: number;
}

interface ShaderReloadFromDiskParams {
  shader_path?: string;
  node_path?: string;
  material_slot?: string;
  wait_ms?: number;
}

interface ShaderMeasureFrameTimeParams {
  enable?: boolean;
  viewport_index?: number;
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
    description: 'Set a shader uniform in the RUNNING game. Locate the target with node_path (single material) or shader_path (shader-wide: applies to every material using that .gdshader; materials shared by more than one node are skipped unless allow_shared=true and reported in skipped[]). Serialized value forms: number, bool, vectors as {x,y,...} or [x,y,...] (vec2/vec3/vec4), colors as {r,g,b,a} or [r,g,b,a], a res:// string (or {path,...} metadata dict) for textures, a 6-number array for mat2 (Transform2D), a 9-number array for mat3 (Basis), a 16-number column-major array for mat4 (Transform3D), and arrays of these for array uniforms (exact declared length required). Refuses shared materials unless allow_shared=true and rejects unknown uniforms. Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      node_path: z.string().optional()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SharedSpriteA"); alternative to shader_path'),
      shader_path: z.string().optional()
        .describe('res:// path of the shader (e.g. "res://shaders/outline.gdshader"); when present, the uniform is applied to every material using that shader in the running game'),
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
    }).refine(
      ({ node_path, shader_path }) => node_path !== undefined || shader_path !== undefined,
      { message: 'Provide node_path or shader_path to locate the material', path: ['node_path'] },
    ),
    execute: async ({ node_path, shader_path, uniform_name, value, material_slot, allow_shared, wait_ms }: ShaderSetUniformParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {
          uniform_name,
          value,
        };
        if (node_path !== undefined) {
          params.node_path = node_path;
        }
        if (shader_path !== undefined) {
          params.shader_path = shader_path;
        }
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

        // Shader-wide scope (shader_path): the game replies with affected/skipped lists.
        if (Array.isArray(result.affected)) {
          let output = `Set uniform '${result.uniform_name}' via shader ${result.shader_path ?? shader_path ?? '(unknown)'}`;
          output += `\nvalue: ${JSON.stringify(result.value ?? null)}`;
          const affected: any[] = result.affected ?? [];
          output += `\naffected (${affected.length}):`;
          for (const entry of affected) {
            output += `\n- ${entry.node_path} (${entry.material_path ?? 'local'})`;
          }
          const skipped: any[] = result.skipped ?? [];
          output += `\nskipped (${skipped.length}):`;
          if (skipped.length === 0) {
            output += ' none';
          }
          for (const entry of skipped) {
            output += `\n- ${entry.node_path} (${entry.reason ?? 'skipped'})`;
          }
          output += `\ncount: ${result.count ?? affected.length}`;
          return output;
        }

        // Per-node scope: the game replied with the single-material result.
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

  {
    name: 'shader_debug_snapshot',
    description: 'Capture a full read-only snapshot of a ShaderMaterial in the RUNNING game: shader resource path (or "local"), shader source code, shader type and render modes, every declared uniform with its live value and parseable default, and material sharing info. Does not modify anything. Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      node_path: z.string()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SoloSprite")'),
      material_slot: z.string().optional()
        .describe('Material slot to read (default "material"; also "material_override", "surface_0", ...)'),
    }),
    execute: async ({ node_path, material_slot }: ShaderDebugSnapshotParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { node_path };
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        const result = await godot.sendCommand<CommandResult>('shader_debug_snapshot', params);

        const shaderPath = result.shader_path || '(unknown)';
        const shaderType = result.shader_type ? ` (type: ${result.shader_type})` : '';
        let output = `Shader: ${shaderPath}${shaderType} on ${result.node_path} (slot: ${result.slot})`;

        const renderModes: string[] = result.render_modes ?? [];
        if (renderModes.length > 0) {
          output += `\nrender_mode: ${renderModes.join(', ')}`;
        }

        if (result.code) {
          output += `\n\n\`\`\`gdshader\n${result.code}\n\`\`\``;
        }

        const uniforms: any[] = result.uniforms ?? [];
        if (uniforms.length === 0) {
          output += '\nNo uniforms declared in shader source.';
        } else {
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
        }

        const sharing = result.sharing ?? {};
        const users: string[] = sharing.users ?? [];
        output += `\nsharing: ${sharing.users_count ?? users.length} user(s)`;
        if (users.length > 0) {
          output += ` (${users.join(', ')})`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to get shader debug snapshot: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_hot_reload',
    description: 'Live-reload a shader in the RUNNING game: applies the new shader source to every material using the shader, then best-effort syncs the new code to the .gdshader file on disk (a file-write failure is reported via file_written/file_write_error and does NOT fail the live apply). Locate the shader with shader_path (res://) or node_path (+ material_slot). The reply includes previous_code (the full code before the change) and compile_errors from the shader error logger; to revert, call this tool again with content=previous_code — there is no separate revert tool. Requires the game to be running from the editor with the debugger attached',
    parameters: z.object({
      shader_path: z.string().optional()
        .describe('res:// path of the shader to reload (e.g. "res://shaders/outline.gdshader"); every material using it in the running game is updated'),
      node_path: z.string().optional()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SoloSprite") to locate the shader from its material; alternative to shader_path'),
      material_slot: z.string().optional()
        .describe('Material slot to use with node_path (default "material")'),
      content: z.string()
        .describe('New shader source code (full file content, including the shader_type line)'),
    }).refine(
      ({ shader_path, node_path }) => shader_path !== undefined || node_path !== undefined,
      { message: 'Provide shader_path or node_path to locate the shader', path: ['shader_path'] },
    ),
    execute: async ({ shader_path, node_path, material_slot, content }: ShaderHotReloadParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { content };
        if (shader_path !== undefined) {
          params.shader_path = shader_path;
        }
        if (node_path !== undefined) {
          params.node_path = node_path;
        }
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        const result = await godot.sendCommand<CommandResult>('shader_hot_reload', params);

        const shaderPath = result.shader_path || '(unknown)';
        let output = `Hot-reloaded shader ${shaderPath}`;

        const affected: any[] = result.affected_materials ?? [];
        output += `\naffected materials (${affected.length}):`;
        for (const entry of affected) {
          output += `\n- ${entry.node_path} (slot: ${entry.slot}, material: ${entry.material_path ?? 'local'})`;
        }

        output += `\nfile_written: ${result.file_written === true}`;
        if (result.file_write_error) {
          output += `\nfile_write_error: ${result.file_write_error}`;
        }

        const compileErrors: any[] = result.compile_errors ?? [];
        if (compileErrors.length === 0) {
          output += '\ncompile_errors: none';
        } else {
          output += `\ncompile_errors (${compileErrors.length}):`;
          for (const entry of compileErrors) {
            const location = entry.line > 0 ? `line ${entry.line}` : 'unknown location';
            output += `\n  [${entry.severity ?? 'error'} at ${location}] ${entry.message}`;
          }
        }

        if (result.previous_code) {
          output += `\n\nprevious_code (rollback: call shader_hot_reload again with content=previous_code):\n\`\`\`gdshader\n${result.previous_code}\n\`\`\``;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to hot reload shader: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_debug_overlay',
    description: 'Toggle a Viewport debug-draw mode in the RUNNING game for visual shader debugging. Modes: "wireframe" (supported on all renderers; on gl_compatibility wireframes are only generated for meshes loaded after the call, reported as wireframe_generated), "normal" (NORMAL_BUFFER, requires the Forward+ renderer), "off" (reset to the default). Unsupported mode/renderer combinations return a clean error. Requires the game to be running from the editor with the debugger attached (F5)',
    parameters: z.object({
      mode: z.enum(['wireframe', 'normal', 'off'])
        .describe('Debug-draw mode to apply: "wireframe", "normal" (Forward+ only), or "off" to reset'),
      viewport_index: z.number().int().min(0).optional()
        .describe('Viewport to apply the mode to: 0 = root viewport (default); a positive index selects the Nth Viewport child of the root'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ mode, viewport_index, wait_ms }: ShaderDebugOverlayParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { mode };
        if (viewport_index !== undefined) {
          params.viewport_index = viewport_index;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_debug_overlay', params);

        let output = `Debug overlay mode '${result.mode}' applied (renderer: ${result.renderer ?? 'unknown'}, viewport: ${result.viewport_index ?? 0})`;
        if (result.caveat) {
          output += `\ncaveat: ${result.caveat}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to set shader debug overlay: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_debug_visualize',
    description: 'Temporarily inject visualization code into a material\'s shader in the RUNNING game (never writes files; the original code is restored by mode=off, or automatically on compile failure with the errors reported). Modes: "uv", "normals", "screen_pos", "world_pos", "custom" (expression required), or "off" to restore. Only canvas_item and spatial shaders are supported. Requires the game to be running from the editor with the debugger attached (F5)',
    parameters: z.object({
      node_path: z.string()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SoloSprite")'),
      mode: z.enum(['uv', 'normals', 'screen_pos', 'world_pos', 'custom', 'off'])
        .describe('Visualization to inject: "uv", "normals", "screen_pos", "world_pos", "custom" (expression required), or "off" to restore the original code'),
      expression: z.string().optional()
        .describe('Shader expression assigned to the output (COLOR for canvas_item, ALBEDO for spatial); required when mode=custom'),
      material_slot: z.string().optional()
        .describe('Material slot to visualize (default "material")'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }).refine(
      ({ mode, expression }) => mode !== 'custom' || (expression !== undefined && expression.trim().length > 0),
      { message: 'expression is required when mode=custom', path: ['expression'] },
    ),
    execute: async ({ node_path, mode, expression, material_slot, wait_ms }: ShaderDebugVisualizeParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { node_path, mode };
        if (expression !== undefined) {
          params.expression = expression;
        }
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_debug_visualize', params);

        let output = `Visualization mode '${result.mode}' applied to ${node_path}`;
        if (result.shader_type) {
          output += ` (shader_type: ${result.shader_type})`;
        }
        if (result.injected) {
          output += `\ninjected: ${result.injected}`;
        }
        const compileErrors: any[] = result.compile_errors ?? [];
        if (compileErrors.length === 0) {
          output += '\ncompile_errors: none';
        } else {
          output += `\ncompile_errors (${compileErrors.length}):`;
          for (const entry of compileErrors) {
            const location = entry.line > 0 ? `line ${entry.line}` : 'unknown location';
            output += `\n  [${entry.severity ?? 'error'} at ${location}] ${entry.message}`;
          }
        }
        if (result.rolled_back === true) {
          output += '\nrolled_back: true (compile failure; original code restored)';
        } else if (result.mode === 'off') {
          output += `\nrestored: ${result.restored === true}`;
          if (result.previous_mode) {
            output += ` (previous mode: ${result.previous_mode})`;
          }
        } else {
          output += '\nrestore: call shader_debug_visualize with mode=off to restore';
        }
        if (result.renderer) {
          output += `\nrenderer: ${result.renderer}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to visualize shader: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_get_warnings',
    description: 'Report shader warnings for a .gdshader file (or just the warnings_enabled state when script_path is omitted): unused uniforms/varyings/consts/structs/functions and unused locals, detected by a static scanner mirroring the engine UNUSED_* warning family, plus compile errors from a forced recompile. Side effect: enables the debug/shader_language/warnings/* ProjectSettings toggles (persisted only when a value actually changes). Editor-side: the game does not need to be running',
    parameters: z.object({
      script_path: z.string().optional()
        .describe('Path to the shader file to scan (e.g. "res://shaders/outline.gdshader"); when omitted, only the warnings_enabled state is reported'),
      wait_ms: z.number().int().min(0).max(10000).optional()
        .describe('Milliseconds to wait before scanning (default 0)'),
    }),
    execute: async ({ script_path, wait_ms }: ShaderGetWarningsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (script_path !== undefined) {
          params.script_path = script_path;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_get_warnings', params);

        let output = script_path !== undefined
          ? `Shader warnings for ${script_path}:\n`
          : 'Shader warnings (project scan):\n';
        output += `warnings_enabled: ${result.warnings_enabled === true}`;

        const warnings: any[] = result.warnings ?? [];
        output += `\nwarnings (${warnings.length}):`;
        if (warnings.length === 0) {
          output += ' none';
        }
        for (const warning of warnings) {
          const location = warning.line > 0 ? `line ${warning.line}` : 'unknown location';
          output += `\n  [${location}] ${warning.message}`;
        }

        const errors: any[] = result.errors ?? [];
        output += `\nerrors (${errors.length}):`;
        if (errors.length === 0) {
          output += ' none';
        }
        for (const error of errors) {
          const location = error.line > 0 ? `line ${error.line}` : 'unknown location';
          output += `\n  [${location}] ${error.message}`;
        }

        output += `\ntotal: ${result.total ?? warnings.length}`;
        return output;
      } catch (error) {
        throw new Error(`Failed to get shader warnings: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_project_health',
    description: 'Scan every .gdshader under res:// and report per-file compile errors and static warnings (unused declarations, same scanner as shader_get_warnings). Side effect: enables the debug/shader_language/warnings/* ProjectSettings toggles. Editor-side: the game does not need to be running',
    parameters: z.object({
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Milliseconds to wait for the renderer to settle before scanning (default 5000)'),
    }),
    execute: async ({ wait_ms }: ShaderProjectHealthParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_project_health', params);

        const totalFiles = result.total_files ?? 0;
        let output = `Shader project health scan (${totalFiles} file(s)):`;
        output += `\nfiles_with_errors: ${result.files_with_errors ?? 0}`;
        output += `\nfiles_with_warnings: ${result.files_with_warnings ?? 0}`;
        output += `\nenabled_warnings: ${result.enabled_warnings === true}`;

        const results: any[] = result.results ?? [];
        output += `\nresults (${results.length}):`;
        for (const entry of results) {
          output += `\n- ${entry.path}: ${(entry.errors ?? []).length} error(s), ${(entry.warnings ?? []).length} warning(s)`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to scan shader project health: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_reset_uniforms',
    description: 'Reset every shader parameter of a ShaderMaterial in the RUNNING game to its declared default (defaults parsed from the shader source; a null default clears the override so the engine default applies). Requires the game to be running from the editor with the debugger attached (F5)',
    parameters: z.object({
      node_path: z.string()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SoloSprite")'),
      material_slot: z.string().optional()
        .describe('Material slot to reset (default "material")'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ node_path, material_slot, wait_ms }: ShaderResetUniformsParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = { node_path };
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_reset_uniforms', params);

        const reset: any[] = result.reset ?? [];
        let output = `Reset ${reset.length} uniform(s) on ${result.node_path ?? node_path} (slot: ${result.slot ?? material_slot ?? 'material'})`;
        for (const entry of reset) {
          output += `\n- ${entry.name} = ${JSON.stringify(entry.value ?? null)}`;
        }
        output += `\ncount: ${result.count ?? reset.length}`;
        return output;
      } catch (error) {
        throw new Error(`Failed to reset shader uniforms: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_reload_from_disk',
    description: 'Reload a shader in the RUNNING game from its .gdshader file on disk and apply it live to every material using the shader (same lookup as shader_hot_reload; a standalone res:// .gdshader file is required). When the live code already equals the disk content, the reply reports unchanged=true and nothing is reapplied. previous_code is the rollback path: re-call shader_hot_reload with content=previous_code. Requires the game to be running from the editor with the debugger attached (F5)',
    parameters: z.object({
      shader_path: z.string().optional()
        .describe('res:// path of the shader to reload (e.g. "res://shaders/outline.gdshader"); every material using it in the running game is updated'),
      node_path: z.string().optional()
        .describe('Node path in the running game (e.g. "/root/TestMainScene/ShaderVisuals/SoloSprite") to locate the shader from its material; alternative to shader_path'),
      material_slot: z.string().optional()
        .describe('Material slot to use with node_path (default "material")'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }).refine(
      ({ shader_path, node_path }) => shader_path !== undefined || node_path !== undefined,
      { message: 'Provide shader_path or node_path to locate the shader', path: ['shader_path'] },
    ),
    execute: async ({ shader_path, node_path, material_slot, wait_ms }: ShaderReloadFromDiskParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (shader_path !== undefined) {
          params.shader_path = shader_path;
        }
        if (node_path !== undefined) {
          params.node_path = node_path;
        }
        if (material_slot !== undefined) {
          params.material_slot = material_slot;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_reload_from_disk', params);

        const shaderPath = result.shader_path || shader_path || '(unknown)';
        let output = `Reloaded shader ${shaderPath} from disk`;
        output += `\nfile_read: ${result.file_read === true}`;
        if (result.file_error) {
          output += `\nfile_error: ${result.file_error}`;
        }
        output += `\nunchanged: ${result.unchanged === true}`;

        const affected: any[] = result.affected_materials ?? [];
        output += `\naffected materials (${affected.length}):`;
        for (const entry of affected) {
          output += `\n- ${entry.node_path} (slot: ${entry.slot}, material: ${entry.material_path ?? 'local'})`;
        }

        const compileErrors: any[] = result.compile_errors ?? [];
        if (compileErrors.length === 0) {
          output += '\ncompile_errors: none';
        } else {
          output += `\ncompile_errors (${compileErrors.length}):`;
          for (const entry of compileErrors) {
            const location = entry.line > 0 ? `line ${entry.line}` : 'unknown location';
            output += `\n  [${entry.severity ?? 'error'} at ${location}] ${entry.message}`;
          }
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to reload shader from disk: ${(error as Error).message}`);
      }
    },
  },

  {
    name: 'shader_measure_frame_time',
    description: 'Read (and optionally toggle) the RUNNING game\'s viewport render-time measurement in milliseconds: gpu_ms and cpu_ms for the selected viewport. enable omitted reads without changing state; enable=true enables measurement then waits a few frames for it to settle (the first frames after enabling report 0.0); enable=false disables. Measurement is per-viewport, not per-shader: compare shaders by toggling a change and measuring again. Requires the game to be running from the editor with the debugger attached (F5)',
    parameters: z.object({
      enable: z.boolean().optional()
        .describe('True to enable measurement (waits a few frames to settle), false to disable; omitted reads without changing state'),
      viewport_index: z.number().int().min(0).optional()
        .describe('Viewport to measure: 0 = root viewport (default); a positive index selects the Nth Viewport child of the root'),
      wait_ms: z.number().int().min(0).max(60000).optional()
        .describe('Max milliseconds to wait for the game reply (default 800)'),
    }),
    execute: async ({ enable, viewport_index, wait_ms }: ShaderMeasureFrameTimeParams): Promise<string> => {
      const godot = getGodotConnection();

      try {
        const params: Record<string, any> = {};
        if (enable !== undefined) {
          params.enable = enable;
        }
        if (viewport_index !== undefined) {
          params.viewport_index = viewport_index;
        }
        if (wait_ms !== undefined) {
          params.wait_ms = wait_ms;
        }
        const result = await godot.sendCommand<CommandResult>('shader_measure_frame_time', params);

        let output = `Render-time measurement (viewport ${result.viewport_index ?? 0}, renderer: ${result.renderer ?? 'unknown'}):`;
        output += `\ngpu_ms: ${result.gpu_ms ?? 0}`;
        output += `\ncpu_ms: ${result.cpu_ms ?? 0}`;
        output += `\nenabled: ${result.enabled === true}`;
        if (result.note) {
          output += `\nnote: ${result.note}`;
        }
        return output;
      } catch (error) {
        throw new Error(`Failed to measure frame time: ${(error as Error).message}`);
      }
    },
  },
];
