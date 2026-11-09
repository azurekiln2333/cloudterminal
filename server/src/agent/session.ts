import { randomUUID } from 'node:crypto';

import type {
  EventBody,
  PermissionDecision,
  PermissionModeName,
  SessionEvent,
  SessionInfo,
  SessionStatus,
} from '../shared/protocol.ts';
import { AsyncQueue } from './queue.ts';
import { clampInput, normalize, parseQuestions, truncate } from './normalize.ts';

// ---------------------------------------------------------------------------
// The slice of the Agent SDK this module depends on. Keeping it structural
// lets tests drive a Session with a scripted fake instead of the real CLI.
// ---------------------------------------------------------------------------

export type SdkUserMessage = {
  type: 'user';
  message: { role: 'user'; content: string };
  parent_tool_use_id: null;
  session_id: string;
};

export type PermissionResultLike =
  | { behavior: 'allow'; updatedInput?: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: 'deny'; message: string; interrupt?: boolean };

export type CanUseToolLike = (
  toolName: string,
  input: Record<string, unknown>,
  options: {
    signal: AbortSignal;
    suggestions?: unknown[];
    title?: string;
    description?: string;
    displayName?: string;
    decisionReason?: string;
    suppressAlwaysAllowRule?: boolean;
    toolUseID: string;
  },
) => Promise<PermissionResultLike>;

export type QueryOptionsLike = {
  cwd: string;
  permissionMode: PermissionModeName;
  allowDangerouslySkipPermissions?: boolean;
  model?: string;
  resume?: string;
  includePartialMessages: boolean;
  canUseTool: CanUseToolLike;
  pathToClaudeCodeExecutable?: string;
  stderr?: (data: string) => void;
};

export type QueryHandle = AsyncIterable<unknown> & {
  interrupt(): Promise<unknown>;
  setPermissionMode(mode: PermissionModeName): Promise<void>;
  close(): void | Promise<void>;
};

export type QueryFn = (params: { prompt: AsyncIterable<SdkUserMessage>; options: QueryOptionsLike }) => QueryHandle;

// ---------------------------------------------------------------------------

export const MAX_EVENTS = 2000;

export interface ManagedSession {
  readonly id: string;
  readonly updatedAt: number;
  readonly status: SessionStatus;
  info(): SessionInfo;
  eventsAfter(afterSeq: number): { events: SessionEvent[]; reset: boolean };
  interrupt(): Promise<void>;
  close(): void | Promise<void>;
}

export type SessionListener = {
  onEvent(session: ManagedSession, event: SessionEvent): void;
  onDelta(session: ManagedSession, text: string): void;
  onState(session: ManagedSession): void;
};

export type SessionOptions = {
  cwd: string;
  mode: PermissionModeName;
  model?: string;
  resume?: string;
  allowBypass: boolean;
  claudePath?: string;
  /** Events replayed from a resumed transcript. */
  history?: EventBody[];
  title?: string;
};

type Pending = {
  toolName: string;
  input: Record<string, unknown>;
  suggestions?: unknown[];
  isQuestion: boolean;
  resolve(result: PermissionResultLike): void;
};

export class Session {
  readonly id = randomUUID();
  readonly cwd: string;
  readonly createdAt = Date.now();
  title: string;
  mode: PermissionModeName;
  model?: string;
  claudeSessionId?: string;
  costUsd = 0;
  updatedAt = Date.now();

  private readonly listener: SessionListener;
  private readonly input = new AsyncQueue<SdkUserMessage>();
  private readonly handle: QueryHandle;
  private readonly pending = new Map<string, Pending>();
  private events: SessionEvent[] = [];
  private seq = 0;
  private turnActive = false;
  private failed = false;
  private closed = false;

  constructor(queryFn: QueryFn, opts: SessionOptions, listener: SessionListener) {
    this.cwd = opts.cwd;
    this.mode = opts.mode;
    this.model = opts.model;
    this.claudeSessionId = opts.resume;
    this.title = opts.title ?? '';
    this.listener = listener;
    for (const body of opts.history ?? []) this.record(body, false);

    this.handle = queryFn({
      prompt: this.input,
      options: {
        cwd: opts.cwd,
        permissionMode: opts.mode,
        // The SDK only allows switching into bypass mode later if the
        // session was launched with this flag.
        allowDangerouslySkipPermissions: opts.allowBypass || undefined,
        model: opts.model,
        resume: opts.resume,
        includePartialMessages: true,
        canUseTool: (tool, input, o) => this.canUseTool(tool, input, o),
        pathToClaudeCodeExecutable: opts.claudePath,
      },
    });
    void this.pump();
  }

  get status(): SessionStatus {
    if (this.closed) return 'closed';
    if (this.failed) return 'error';
    if (this.pending.size > 0) return 'waiting';
    if (this.turnActive) return 'running';
    return 'idle';
  }

  get lastSeq(): number {
    return this.seq;
  }

  info(): SessionInfo {
    return {
      id: this.id,
      title: this.title || '新会话',
      cwd: this.cwd,
      status: this.status,
      mode: this.mode,
      model: this.model,
      claudeSessionId: this.claudeSessionId,
      createdAt: this.createdAt,
      updatedAt: this.updatedAt,
      costUsd: this.costUsd,
      pending: this.pending.size,
      lastSeq: this.seq,
    };
  }

  /**
   * Events after `afterSeq`. `reset` is true when the caller's view can't be
   * extended (events were trimmed, or the seq belongs to another run) and it
   * must replace what it has.
   */
  eventsAfter(afterSeq: number): { events: SessionEvent[]; reset: boolean } {
    const first = this.events[0]?.seq ?? this.seq + 1;
    if (afterSeq > this.seq || afterSeq < first - 1) {
      return { events: [...this.events], reset: true };
    }
    return { events: this.events.filter((e) => e.seq > afterSeq), reset: false };
  }

  send(text: string): void {
    if (this.closed) throw new Error('session is closed');
    const trimmed = text.trim();
    if (!trimmed) throw new Error('message is empty');
    if (!this.title) this.title = trimmed.replace(/\s+/g, ' ').slice(0, 60);
    this.record({ kind: 'user', text: truncate(trimmed) });
    this.input.push({
      type: 'user',
      message: { role: 'user', content: trimmed },
      parent_tool_use_id: null,
      session_id: this.claudeSessionId ?? '',
    });
    this.turnActive = true;
    this.failed = false;
    this.touch();
  }

  respondPermission(
    requestId: string,
    decision: PermissionDecision,
    extra: { message?: string; answers?: Record<string, string> } = {},
  ): void {
    const p = this.pending.get(requestId);
    if (!p) throw new Error('permission request is no longer pending');
    this.pending.delete(requestId);

    let result: PermissionResultLike;
    if (decision === 'deny') {
      result = { behavior: 'deny', message: extra.message?.trim() || 'The user denied this action from the remote console.' };
    } else if (p.isQuestion) {
      result = { behavior: 'allow', updatedInput: { ...p.input, answers: extra.answers ?? {} } };
    } else {
      result = { behavior: 'allow', updatedInput: p.input };
      if (decision === 'allow_always' && p.suggestions?.length) result.updatedPermissions = p.suggestions;
    }
    p.resolve(result);
    this.record({ kind: 'permission_resolved', requestId, decision });
    this.touch();
  }

  async setMode(mode: PermissionModeName): Promise<void> {
    await this.handle.setPermissionMode(mode);
    this.mode = mode;
    this.touch();
  }

  async interrupt(): Promise<void> {
    this.denyAllPending('Interrupted from the remote console.');
    await this.handle.interrupt();
    this.turnActive = false;
    this.touch();
  }

  close(): void {
    if (this.closed) return;
    this.denyAllPending('Session closed.');
    this.closed = true;
    this.input.end();
    try {
      this.handle.close();
    } catch {
      // already gone
    }
    this.touch();
  }

  // -------------------------------------------------------------------------

  private async canUseTool(
    toolName: string,
    input: Record<string, unknown>,
    o: Parameters<CanUseToolLike>[2],
  ): Promise<PermissionResultLike> {
    const requestId = randomUUID();
    const questions = toolName === 'AskUserQuestion' ? parseQuestions(input) : undefined;
    const result = new Promise<PermissionResultLike>((resolve) => {
      this.pending.set(requestId, {
        toolName,
        input,
        suggestions: o.suggestions,
        isQuestion: questions !== undefined,
        resolve,
      });
    });
    o.signal.addEventListener(
      'abort',
      () => {
        const p = this.pending.get(requestId);
        if (!p) return;
        this.pending.delete(requestId);
        p.resolve({ behavior: 'deny', message: 'Aborted.' });
        this.record({ kind: 'permission_resolved', requestId, decision: 'deny' });
        this.touch();
      },
      { once: true },
    );

    this.record({
      kind: 'permission_request',
      requestId,
      toolName,
      title: o.title || defaultTitle(toolName, o.displayName),
      description: o.description || o.decisionReason || undefined,
      input: clampInput(input),
      canAlwaysAllow: !questions && !o.suppressAlwaysAllowRule && (o.suggestions?.length ?? 0) > 0,
      questions,
    });
    this.touch();
    return result;
  }

  private denyAllPending(message: string): void {
    for (const [requestId, p] of [...this.pending]) {
      this.pending.delete(requestId);
      p.resolve({ behavior: 'deny', message });
      this.record({ kind: 'permission_resolved', requestId, decision: 'deny' });
    }
  }

  private async pump(): Promise<void> {
    try {
      for await (const msg of this.handle) {
        const n = normalize(msg);
        if (n.init) {
          this.claudeSessionId = n.init.claudeSessionId || this.claudeSessionId;
          if (n.init.model) this.model = n.init.model;
        }
        if (n.mode) this.mode = n.mode as PermissionModeName;
        if (n.delta) this.listener.onDelta(this, n.delta);
        for (const e of n.events) this.record(e);
        if (n.result) {
          this.costUsd = n.result.costUsd || this.costUsd;
          this.turnActive = false;
        }
        if (n.init || n.mode || n.events.length || n.result) this.touch();
      }
    } catch (err) {
      if (!this.closed) {
        this.failed = true;
        this.record({ kind: 'error', text: `Claude 进程出错：${(err as Error).message ?? String(err)}` });
      }
    } finally {
      this.turnActive = false;
      if (!this.closed) {
        this.closed = true;
        this.denyAllPending('Session ended.');
        this.record({ kind: 'system', text: '会话已结束' });
      }
      this.touch();
    }
  }

  private record(body: EventBody, notify = true): void {
    const event = { ...body, seq: ++this.seq, ts: Date.now() } as SessionEvent;
    this.events.push(event);
    if (this.events.length > MAX_EVENTS) this.events = this.events.slice(-MAX_EVENTS);
    if (notify) this.listener.onEvent(this, event);
  }

  private touch(): void {
    this.updatedAt = Date.now();
    this.listener.onState(this);
  }
}

function defaultTitle(toolName: string, displayName?: string): string {
  if (toolName === 'AskUserQuestion') return 'Claude 有问题想问你';
  if (toolName === 'ExitPlanMode') return 'Claude 已完成计划，是否开始执行？';
  return `Claude 想要使用 ${displayName || toolName}`;
}
