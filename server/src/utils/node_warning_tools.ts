import {
  NodeWarningEntry,
  NodeWarningStats,
  NodeWarningsCommandResult,
} from './types.js';

function formatNodeWarnings(
  scenePath: string,
  rootNodeName: string,
  rootNodeType: string,
  warnings: NodeWarningEntry[],
  debug: boolean,
  stats?: NodeWarningStats,
): string {
  const lines: string[] = [
    `Scene: ${scenePath}`,
    `Root Node: ${rootNodeName} (${rootNodeType})`,
    `Nodes with warnings: ${warnings.length}`,
  ];

  if (debug) {
    if (stats?.treePath) {
      lines.push(`Scene Tree Dock: ${stats.treePath}`);
    }
    if (typeof stats?.itemsScanned === 'number') {
      lines.push(`Tree rows scanned: ${stats.itemsScanned}`);
    }
    if (typeof stats?.buttonsScanned === 'number') {
      lines.push(`Tree buttons scanned: ${stats.buttonsScanned}`);
    }
  }

  lines.push('');

  if (warnings.length === 0) {
    lines.push('No node warnings found.');
    return lines.join('\n');
  }

  warnings.forEach((entry, index) => {
    if (index > 0) {
      lines.push('');
    }

    lines.push(`${entry.path}:`);
    const warningLines = String(entry.warning ?? '').split('\n');
    warningLines.forEach((line) => {
      lines.push(`  ${line}`);
    });
  });

  return lines.join('\n');
}

function normalizeNodeWarningResult(
  result: NodeWarningsCommandResult,
): {
  scenePath: string;
  rootNodeName: string;
  rootNodeType: string;
  warnings: NodeWarningEntry[];
  stats: NodeWarningStats;
} {
  const warnings = Array.isArray(result.warnings)
    ? (result.warnings as NodeWarningEntry[])
    : [];
  const scenePath =
    typeof result.scene_path === 'string' && result.scene_path.length > 0
      ? result.scene_path
      : 'Current Scene';
  const rootNodeName =
    typeof result.root_node_name === 'string' && result.root_node_name.length > 0
      ? result.root_node_name
      : 'Root';
  const rootNodeType =
    typeof result.root_node_type === 'string' && result.root_node_type.length > 0
      ? result.root_node_type
      : 'Node';

  return {
    scenePath,
    rootNodeName,
    rootNodeType,
    warnings,
    stats: {
      treePath:
        typeof result.tree_path === 'string' ? result.tree_path : undefined,
      itemsScanned:
        typeof result.items_scanned === 'number'
          ? result.items_scanned
          : undefined,
      buttonsScanned:
        typeof result.buttons_scanned === 'number'
          ? result.buttons_scanned
          : undefined,
    },
  };
}

export function formatNodeWarningsResult(
  result: NodeWarningsCommandResult,
  debug: boolean,
): string {
  const normalized = normalizeNodeWarningResult(result);
  return formatNodeWarnings(
    normalized.scenePath,
    normalized.rootNodeName,
    normalized.rootNodeType,
    normalized.warnings,
    debug,
    normalized.stats,
  );
}