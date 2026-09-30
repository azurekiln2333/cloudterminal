// Wire protocol shared by relay, agent and (mirrored in Dart) the app.
// See .trellis/tasks/10-01-remote-console/design.md for the full contract.

export const PROTOCOL_VERSION = 1;

/** Frames that are larger than this are dropped by the relay. */
export const MAX_FRAME_BYTES = 4 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Relay envelope
// ---------------------------------------------------------------------------

export type AgentHello = {
  t: 'hello';
  role: 'agent';
  agentId: string;
  /** sha256(secret) as lowercase hex. The relay never sees the secret. */
  secretHash: string;
  relayKey?: string;
  name?: string;
  v?: number;
};

export type ClientHello = {
  t: 'hello';
  role: 'client';
  agentId: string;
  secret: string;
  v?: number;
};

export type Hello = AgentHello | ClientHello;

export type RelayErrorCode =
  | 'bad_request'
  | 'unauthorized'
  | 'rate_limited'
  | 'agent_conflict'
  /** Non-fatal: a client message could not be delivered. */
  | 'agent_offline'
  | 'timeout';

export type RelayFrame =
  | { t: 'hello_ok'; clientId?: string; online?: boolean; name?: string }
  | { t: 'error'; code: RelayErrorCode; message: string }
  | { t: 'presence'; online: boolean; name?: string }
  | { t: 'client_joined'; clientId: string }
  | { t: 'client_left'; clientId: string }
  /** client → agent (relay stamps clientId) */
  | { t: 'msg'; clientId: string; data: ClientMessage }
  /** agent → client(s); `to` limits delivery to one client */
  | { t: 'msg'; data: AgentMessage; to?: string };

// ---------------------------------------------------------------------------
// Agent protocol (payload of `msg` frames)
// ---------------------------------------------------------------------------

export type PermissionModeName =
  | 'default'
  | 'acceptEdits'
  | 'bypassPermissions'
  | 'plan'
  | 'dontAsk'
  | 'auto';

export const PERMISSION_MODES: readonly PermissionModeName[] = [
  'default',
  'acceptEdits',
  'plan',
  'auto',
  'dontAsk',
  'bypassPermissions',
];

export type SessionStatus =
  | 'starting'
  | 'running'
  | 'waiting'
  | 'idle'
  | 'error'
  | 'closed';

export type SessionInfo = {
  id: string;
  title: string;
  cwd: string;
  status: SessionStatus;
  mode: PermissionModeName;
  model?: string;
  claudeSessionId?: string;
  createdAt: number;
  updatedAt: number;
  costUsd: number;
  pending: number;
  lastSeq: number;
};

export type QuestionOption = { label: string; description?: string };
export type Question = {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options: QuestionOption[];
};

export type EventBody =
  | { kind: 'user'; text: string }
  | { kind: 'assistant'; text: string }
  | { kind: 'thinking'; text: string }
  | {
      kind: 'tool_use';
      toolUseId: string;
      name: string;
      summary: string;
      input: unknown;
    }
  | { kind: 'tool_result'; toolUseId: string; content: string; isError: boolean }
  | {
      kind: 'permission_request';
      requestId: string;
      toolName: string;
      title: string;
      description?: string;
      input: unknown;
      canAlwaysAllow: boolean;
      questions?: Question[];
    }
  | {
      kind: 'permission_resolved';
      requestId: string;
      decision: PermissionDecision;
    }
  | {
      kind: 'result';
      subtype: string;
      isError: boolean;
      text: string;
      costUsd: number;
      durationMs: number;
      turns: number;
    }
  | { kind: 'system'; text: string }
  | { kind: 'error'; text: string };

export type SessionEvent = EventBody & { seq: number; ts: number };

export type PermissionDecision = 'allow' | 'allow_always' | 'deny';

export type ClientRequest =
  | { type: 'info' }
  | { type: 'list_sessions' }
  | { type: 'list_history'; cwd?: string }
  | { type: 'list_dir'; path?: string }
  | {
      type: 'create_session';
      cwd: string;
      prompt?: string;
      mode?: PermissionModeName;
      model?: string;
      resume?: string;
    }
  | { type: 'subscribe'; sessionId: string; afterSeq?: number }
  | { type: 'unsubscribe'; sessionId: string }
  | { type: 'send'; sessionId: string; text: string }
  | { type: 'interrupt'; sessionId: string }
  | {
      type: 'permission';
      sessionId: string;
      requestId: string;
      decision: PermissionDecision;
      message?: string;
      /** AskUserQuestion answers: question text → answer. */
      answers?: Record<string, string>;
    }
  | { type: 'set_mode'; sessionId: string; mode: PermissionModeName }
  | { type: 'close_session'; sessionId: string };

export type ClientMessage = ClientRequest & { id?: string };

export type DirEntry = { name: string; path: string };

export type HistoryItem = {
  sessionId: string;
  summary: string;
  cwd?: string;
  lastModified: number;
};

export type AgentMessage =
  | { kind: 'ack'; id?: string }
  | { kind: 'error'; id?: string; message: string }
  | {
      kind: 'info';
      id?: string;
      host: string;
      platform: string;
      defaultCwd: string;
      roots: string[];
      allowBypass: boolean;
      version: number;
    }
  | { kind: 'sessions'; id?: string; sessions: SessionInfo[] }
  | { kind: 'history'; id?: string; items: HistoryItem[] }
  | {
      kind: 'dir';
      id?: string;
      /** '' is the virtual listing of allowed roots. */
      path: string;
      /** null when there is nothing above (`path` is the root listing). */
      parent: string | null;
      entries: DirEntry[];
    }
  | { kind: 'session_created'; id?: string; session: SessionInfo }
  | { kind: 'session'; session: SessionInfo }
  | { kind: 'events'; id?: string; sessionId: string; events: SessionEvent[]; reset: boolean }
  | { kind: 'event'; sessionId: string; event: SessionEvent }
  | { kind: 'delta'; sessionId: string; text: string };
