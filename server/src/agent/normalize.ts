// Turns raw Agent SDK messages into the small, stable event vocabulary the
// app renders. The SDK message union is large and grows between versions, so
// this reads fields defensively instead of switching on the full union type.

import type { EventBody, Question } from '../shared/protocol.ts';

export const MAX_TEXT = 8 * 1024;

export function truncate(text: string, max = MAX_TEXT): string {
  if (text.length <= max) return text;
  return text.slice(0, max) + `\n… (${text.length - max} more characters)`;
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown): string => (typeof v === 'string' ? v : '');

/** One-line human summary of a tool call, e.g. `npm test` or `src/a.ts`. */
export function summarizeTool(name: string, input: unknown): string {
  if (!isObj(input)) return '';
  const pick = (...keys: string[]) => {
    for (const k of keys) {
      const v = input[k];
      if (typeof v === 'string' && v) return v;
    }
    return '';
  };
  let s: string;
  switch (name) {
    case 'Bash':
      s = pick('description', 'command');
      if (input.description && input.command) s = `${input.description}: ${input.command}`;
      break;
    case 'Read':
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
      s = pick('file_path', 'notebook_path');
      break;
    case 'Glob':
    case 'Grep':
      s = pick('pattern');
      break;
    case 'WebFetch':
      s = pick('url');
      break;
    case 'WebSearch':
      s = pick('query');
      break;
    case 'Task':
    case 'Agent':
      s = pick('description', 'prompt');
      break;
    default:
      s = pick('description', 'command', 'file_path', 'path', 'url', 'query', 'pattern', 'prompt');
  }
  s = s.replace(/\s+/g, ' ').trim();
  return s.length > 160 ? s.slice(0, 157) + '…' : s;
}

function toolResultText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (!isObj(b)) return '';
        if (b.type === 'text') return str(b.text);
        if (b.type === 'image') return '[image]';
        return '';
      })
      .filter(Boolean)
      .join('\n');
  }
  return '';
}

/** Parse AskUserQuestion input into the protocol's question shape. */
export function parseQuestions(input: unknown): Question[] | undefined {
  if (!isObj(input) || !Array.isArray(input.questions)) return undefined;
  const out: Question[] = [];
  for (const q of input.questions) {
    if (!isObj(q) || typeof q.question !== 'string') continue;
    const options = Array.isArray(q.options)
      ? q.options.filter(isObj).map((o) => ({ label: str(o.label), description: str(o.description) || undefined }))
      : [];
    out.push({
      question: q.question,
      header: str(q.header) || undefined,
      multiSelect: q.multiSelect === true,
      options,
    });
  }
  return out.length ? out : undefined;
}

function contentBlocks(message: unknown): unknown[] {
  if (!isObj(message)) return [];
  const c = message.content;
  if (typeof c === 'string') return [{ type: 'text', text: c }];
  return Array.isArray(c) ? c : [];
}

export type NormalizeOptions = {
  /**
   * Include plain user text blocks. Off for live sessions (the agent records
   * what the phone sent itself), on when replaying a transcript.
   */
  includeUserText?: boolean;
};

export type Normalized = {
  events: EventBody[];
  /** Streaming text chunk (not stored). */
  delta?: string;
  init?: { claudeSessionId: string; model?: string; mode?: string; cwd?: string };
  result?: { costUsd: number };
  /** Permission mode reported by the CLI (e.g. after ExitPlanMode). */
  mode?: string;
};

export function normalize(msg: unknown, opts: NormalizeOptions = {}): Normalized {
  const out: Normalized = { events: [] };
  if (!isObj(msg)) return out;

  switch (msg.type) {
    case 'system':
      return normalizeSystem(msg, out);

    case 'assistant': {
      for (const b of contentBlocks(msg.message)) {
        if (!isObj(b)) continue;
        if (b.type === 'text' && str(b.text).trim()) {
          out.events.push({ kind: 'assistant', text: truncate(str(b.text)) });
        } else if (b.type === 'thinking' && str(b.thinking).trim()) {
          out.events.push({ kind: 'thinking', text: truncate(str(b.thinking)) });
        } else if (b.type === 'tool_use') {
          const name = str(b.name);
          out.events.push({
            kind: 'tool_use',
            toolUseId: str(b.id),
            name,
            summary: summarizeTool(name, b.input),
            input: clampInput(b.input),
          });
        }
      }
      if (typeof msg.error === 'string') {
        out.events.push({ kind: 'error', text: `API error: ${msg.error}` });
      }
      return out;
    }

    case 'user': {
      for (const b of contentBlocks(msg.message)) {
        if (!isObj(b)) continue;
        if (b.type === 'tool_result') {
          out.events.push({
            kind: 'tool_result',
            toolUseId: str(b.tool_use_id),
            content: truncate(toolResultText(b.content)),
            isError: b.is_error === true,
          });
        } else if (opts.includeUserText && b.type === 'text' && str(b.text).trim()) {
          out.events.push({ kind: 'user', text: truncate(str(b.text)) });
        }
      }
      return out;
    }

    case 'result': {
      const errors = Array.isArray(msg.errors) ? msg.errors.map(str).filter(Boolean) : [];
      const costUsd = typeof msg.total_cost_usd === 'number' ? msg.total_cost_usd : 0;
      out.events.push({
        kind: 'result',
        subtype: str(msg.subtype),
        isError: msg.is_error === true,
        text: truncate(str(msg.result) || errors.join('\n')),
        costUsd,
        durationMs: typeof msg.duration_ms === 'number' ? msg.duration_ms : 0,
        turns: typeof msg.num_turns === 'number' ? msg.num_turns : 0,
      });
      out.result = { costUsd };
      return out;
    }

    case 'stream_event': {
      // Only top-level text deltas; subagent streams would interleave.
      if (msg.parent_tool_use_id) return out;
      const ev = msg.event;
      if (isObj(ev) && ev.type === 'content_block_delta' && isObj(ev.delta) && ev.delta.type === 'text_delta') {
        const t = str(ev.delta.text);
        if (t) out.delta = t;
      }
      return out;
    }

    default:
      return out;
  }
}

function normalizeSystem(msg: Obj, out: Normalized): Normalized {
  switch (msg.subtype) {
    case 'init':
      out.init = {
        claudeSessionId: str(msg.session_id),
        model: str(msg.model) || undefined,
        mode: str(msg.permissionMode) || undefined,
        cwd: str(msg.cwd) || undefined,
      };
      out.events.push({ kind: 'system', text: `会话已启动 · ${str(msg.model) || 'claude'} · ${str(msg.cwd)}` });
      break;
    case 'status':
      if (str(msg.permissionMode)) out.mode = str(msg.permissionMode);
      if (msg.status === 'compacting') out.events.push({ kind: 'system', text: '正在压缩上下文…' });
      break;
    case 'compact_boundary':
      out.events.push({ kind: 'system', text: '上下文已压缩' });
      break;
    case 'api_retry':
      out.events.push({
        kind: 'system',
        text: `API 请求失败，${Math.round(Number(msg.retry_delay_ms ?? 0) / 1000)} 秒后重试（${String(msg.attempt ?? '?')}/${String(msg.max_retries ?? '?')}）`,
      });
      break;
    case 'informational':
      if (msg.level === 'warning' || msg.level === 'suggestion') {
        out.events.push({ kind: 'system', text: truncate(str(msg.content)) });
      }
      break;
    case 'notification':
      if (str(msg.text)) out.events.push({ kind: 'system', text: truncate(str(msg.text)) });
      break;
    case 'permission_denied':
      out.events.push({ kind: 'system', text: `已拒绝 ${str(msg.tool_name)}` });
      break;
  }
  return out;
}

/** Keep tool inputs small enough for the backlog (big Write payloads etc.). */
export function clampInput(input: unknown): unknown {
  if (!isObj(input)) return input;
  const out: Obj = {};
  for (const [k, v] of Object.entries(input)) {
    if (typeof v === 'string') out[k] = truncate(v, 4096);
    else if (Array.isArray(v) || isObj(v)) {
      const json = JSON.stringify(v);
      out[k] = json.length > 4096 ? truncate(json, 4096) : v;
    } else out[k] = v;
  }
  return out;
}
