import { z } from 'zod';

/**
 * A content block accepted by FastMCP 3.25.4 tool results.
 * Mirrors the literal-typed Content union that fastmcp's execute return
 * type accepts (TextContent | ImageContent).
 */
export type MCPContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mimeType: string };

/**
 * Return type of a tool execute function: either plain text or a FastMCP
 * content-block result (e.g. an image block plus a text summary).
 */
export type MCPToolResult = string | { content: MCPContentBlock[] };

/**
 * Interface for FastMCP tool definition
 */
export interface MCPTool<T = any> {
  name: string;
  description: string;
  parameters: z.ZodType<T>;
  execute: (args: T) => Promise<MCPToolResult>;
}

/**
 * Generic response from a Godot command
 */
export interface CommandResult {
  [key: string]: any;
}

/**
 * Parameters for the node warnings tool.
 */
export interface GetNodeWarningsParams {
  debug?: boolean;
}

/**
 * A warning entry extracted from the Godot scene tree.
 */
export interface NodeWarningEntry {
  name: string;
  path: string;
  warning: string;
}

/**
 * Optional traversal statistics returned alongside node warnings.
 */
export interface NodeWarningStats {
  treePath?: string;
  itemsScanned?: number;
  buttonsScanned?: number;
}

/**
 * Raw response payload for the node warnings command.
 */
export interface NodeWarningsCommandResult extends CommandResult {
  scene_path?: string;
  root_node_name?: string;
  root_node_type?: string;
  tree_path?: string;
  warnings?: unknown;
  warnings_count?: number;
  items_scanned?: number;
  buttons_scanned?: number;
}
