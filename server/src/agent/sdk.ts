// Adapters from the real Agent SDK to the structural types AgentCore uses.

import { getSessionMessages, listSessions, query } from '@anthropic-ai/claude-agent-sdk';

import type { HistoryLoader } from './core.ts';
import type { QueryFn, QueryHandle } from './session.ts';

export function sdkQueryFn(onStderr?: (line: string) => void): QueryFn {
  return ({ prompt, options }) =>
    query({
      // Our message/permission shapes are structural subsets of the SDK's.
      prompt: prompt as unknown as Parameters<typeof query>[0]['prompt'],
      options: {
        ...options,
        canUseTool: options.canUseTool as unknown as NonNullable<Parameters<typeof query>[0]['options']>['canUseTool'],
        stderr: onStderr,
      },
    }) as unknown as QueryHandle;
}

export const sdkHistory: HistoryLoader = {
  async list(cwd) {
    const sessions = await listSessions({ dir: cwd, limit: 30 });
    return sessions.map((s) => ({
      sessionId: s.sessionId,
      summary: s.customTitle || s.summary || s.firstPrompt || s.sessionId,
      cwd: s.cwd,
      lastModified: s.lastModified,
    }));
  },
  async messages(claudeSessionId, cwd) {
    return getSessionMessages(claudeSessionId, { dir: cwd });
  },
};
