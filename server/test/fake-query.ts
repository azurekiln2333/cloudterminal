import { AsyncQueue } from '../src/agent/queue.ts';
import type { QueryFn, QueryHandle, QueryOptionsLike, SdkUserMessage } from '../src/agent/session.ts';

/** Stand-in for the SDK's `query()`: tests push SDK messages by hand. */
export class FakeQuery implements QueryHandle {
  readonly out = new AsyncQueue<unknown>();
  readonly received: SdkUserMessage[] = [];
  readonly modes: string[] = [];
  interrupts = 0;
  closed = false;
  private readonly aborts: AbortController[] = [];
  private receivedWaiters: Array<() => void> = [];
  readonly options: QueryOptionsLike;

  constructor(prompt: AsyncIterable<SdkUserMessage>, options: QueryOptionsLike) {
    this.options = options;
    void (async () => {
      for await (const m of prompt) {
        this.received.push(m);
        for (const w of this.receivedWaiters.splice(0)) w();
      }
    })();
  }

  [Symbol.asyncIterator]() {
    return this.out[Symbol.asyncIterator]();
  }

  emit(msg: unknown): void {
    this.out.push(msg);
  }

  end(): void {
    this.out.end();
  }

  /** Simulate the CLI asking for permission. */
  ask(tool: string, input: Record<string, unknown>, extra: Record<string, unknown> = {}) {
    const ac = new AbortController();
    this.aborts.push(ac);
    return this.options.canUseTool(tool, input, { signal: ac.signal, toolUseID: 'tu_' + tool, ...extra });
  }

  async waitForInput(count: number): Promise<void> {
    while (this.received.length < count) await new Promise<void>((r) => this.receivedWaiters.push(r));
  }

  async interrupt() {
    this.interrupts++;
    for (const a of this.aborts) a.abort();
    return undefined;
  }

  async setPermissionMode(mode: string) {
    this.modes.push(mode);
  }

  close() {
    this.closed = true;
    this.out.end();
  }
}

export function fakeQueryFn(): { fn: QueryFn; queries: FakeQuery[] } {
  const queries: FakeQuery[] = [];
  const fn: QueryFn = ({ prompt, options }) => {
    const q = new FakeQuery(prompt, options);
    queries.push(q);
    return q;
  };
  return { fn, queries };
}

export const tick = () => new Promise((r) => setImmediate(r));

// Canned SDK messages ------------------------------------------------------

export const sdk = {
  init: (sessionId = 'claude-1') => ({
    type: 'system',
    subtype: 'init',
    session_id: sessionId,
    model: 'claude-test',
    cwd: '/tmp',
    permissionMode: 'default',
  }),
  text: (text: string) => ({ type: 'assistant', message: { content: [{ type: 'text', text }] }, parent_tool_use_id: null }),
  toolUse: (id: string, name: string, input: unknown) => ({
    type: 'assistant',
    message: { content: [{ type: 'tool_use', id, name, input }] },
    parent_tool_use_id: null,
  }),
  toolResult: (id: string, content: string, isError = false) => ({
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: id, content, is_error: isError }] },
    parent_tool_use_id: null,
  }),
  delta: (text: string) => ({
    type: 'stream_event',
    parent_tool_use_id: null,
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  }),
  result: (cost = 0.01) => ({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: 'done',
    total_cost_usd: cost,
    duration_ms: 1200,
    num_turns: 2,
  }),
};
