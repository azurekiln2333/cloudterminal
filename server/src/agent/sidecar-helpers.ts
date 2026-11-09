// Pure helpers for the sidecar so its framing and summaries are testable in
// isolation from sockets, relays and real tools.

import type { ToolKind, ToolProbeResult } from './tool-probe.ts';

const LABELS: Record<ToolKind, string> = {
  herdr: 'Herdr',
  codex: 'Codex',
  claude: 'Claude Code',
};

export function toolKindLabel(kind: ToolKind): string {
  return LABELS[kind] ?? kind;
}

export function summarizeTools(tools: readonly ToolProbeResult[]): string {
  return tools
    .map((tool) => `${tool.kind}=${tool.installed ? '可用' : '未安装'}`)
    .join(' ');
}

/**
 * Incremental newline-delimited JSON decoder. Returns the frames completed by
 * this chunk; a partial trailing line is buffered for the next call. A
 * non-JSON line is skipped (the sidecar never emits one, but the client must not
 * throw if diagnostics leak into the stream).
 */
export function createLineDecoder(): (chunk: string) => Array<Record<string, unknown>> {
  let buffer = '';
  return (chunk: string) => {
    buffer += chunk;
    const frames: Array<Record<string, unknown>> = [];
    let index = buffer.indexOf('\n');
    while (index >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (line) {
        try {
          const decoded = JSON.parse(line) as unknown;
          if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) {
            frames.push(decoded as Record<string, unknown>);
          }
        } catch {
          // Skip a malformed line rather than dropping the whole connection.
        }
      }
      index = buffer.indexOf('\n');
    }
    return frames;
  };
}
