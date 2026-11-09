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

/** Exchange a short pairing code for the agent's credentials. */
export type PairHello = {
  t: 'hello';
  role: 'pair';
  code: string;
  v?: number;
};

export type Hello = AgentHello | ClientHello | PairHello;

/** Pairing codes: 8 chars from an alphabet without look-alikes (0/O, 1/I/L). */
export const PAIR_CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
export const PAIR_CODE_LENGTH = 8;

export function normalizePairCode(code: string): string {
  return code.toUpperCase().replace(/[^0-9A-Z]/g, '');
}

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
  /** agent → relay: register a one-time pairing code. */
  | { t: 'pair_code'; code: string; ttlMs: number }
  | { t: 'pair_code_ok'; code: string; expiresAt: number }
  /** relay → agent: someone presented the code; reply with pair_response. */
  | { t: 'pair_request'; pairId: string }
  | { t: 'pair_response'; pairId: string; secret: string }
  /** relay → pairing socket, then closed. */
  | { t: 'paired'; agentId: string; secret: string; name?: string }
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
  kind?: 'claude' | 'terminal';
  cols?: number;
  rows?: number;
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
  | { kind: 'terminal_output'; data: string }
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

// ---------------------------------------------------------------------------
// Herdr (local terminal workspace manager) — additive since PROTOCOL_VERSION 1.
// The desktop agent bridges these onto the installed `herdr` CLI. See
// .trellis/tasks/10-12-herdr-mobile/design.md.
// ---------------------------------------------------------------------------

export type HerdrAgentStatus = 'idle' | 'working' | 'blocked' | 'done' | 'unknown';
export type HerdrReadSource = 'visible' | 'recent' | 'recent-unwrapped' | 'detection';

export type HerdrAvailability = {
  available: boolean;
  installed: boolean;
  version?: string;
  protocol?: number;
  socket?: string;
  serverRunning: boolean;
  canControl: boolean;
  /** Actionable Chinese message when `canControl` is false. */
  reason?: string;
};

export type HerdrWorkspace = {
  workspaceId: string;
  label: string;
  number: number;
  focused: boolean;
  agentStatus: HerdrAgentStatus;
  paneCount: number;
  tabCount: number;
  activeTabId?: string;
};

export type HerdrTab = {
  tabId: string;
  workspaceId: string;
  label: string;
  number: number;
  focused: boolean;
  agentStatus: HerdrAgentStatus;
  paneCount: number;
};

export type HerdrPane = {
  paneId: string;
  workspaceId: string;
  tabId: string;
  cwd: string;
  focused: boolean;
  terminalTitle: string;
  agent?: string;
  agentStatus?: HerdrAgentStatus;
  name?: string;
  interactiveReady?: boolean;
  scroll?: { offsetFromBottom: number; maxOffsetFromBottom: number; viewportRows: number };
};

export type HerdrAgent = {
  /** Name when the agent was named, otherwise the hosting pane id. */
  target: string;
  paneId: string;
  workspaceId: string;
  tabId: string;
  cwd: string;
  agentKind: string;
  status: HerdrAgentStatus;
  focused: boolean;
  terminalTitle: string;
  name?: string;
  interactiveReady?: boolean;
  completionSeq?: number;
  stateChangeSeq?: number;
};

export type HerdrLayout = {
  workspaceId: string;
  tabId: string;
  zoomed: boolean;
  focusedPaneId?: string;
  area: { x: number; y: number; width: number; height: number };
  panes: { paneId: string; focused: boolean; rect: { x: number; y: number; width: number; height: number } }[];
  splits: { id: string; direction: string; ratio: number }[];
};

/**
 * Lifecycle controls. Deliberately excludes interactive attach/takeover and
 * `--machine`/`--remote` forwarding (out of scope, documented on the phone).
 */
export type HerdrAction =
  | { kind: 'workspace_create'; label?: string; cwd?: string; focus?: boolean }
  | { kind: 'workspace_rename'; workspaceId: string; label: string }
  | { kind: 'workspace_focus'; workspaceId: string }
  | { kind: 'workspace_close'; workspaceId: string; group?: boolean }
  | { kind: 'tab_create'; workspaceId: string; label?: string; cwd?: string; focus?: boolean }
  | { kind: 'tab_rename'; tabId: string; label: string }
  | { kind: 'tab_focus'; tabId: string }
  | { kind: 'tab_close'; tabId: string }
  | { kind: 'pane_split'; paneId: string; direction: 'right' | 'down'; ratio?: number; cwd?: string; focus?: boolean }
  | { kind: 'pane_focus'; paneId: string }
  | { kind: 'pane_zoom'; paneId?: string; mode: 'toggle' | 'on' | 'off' }
  | { kind: 'pane_rename'; paneId: string; label?: string }
  | { kind: 'pane_close'; paneId: string }
  | { kind: 'pane_resize'; paneId: string; direction: 'left' | 'right' | 'up' | 'down'; amount?: number }
  | {
      kind: 'pane_move';
      paneId: string;
      to: 'new_tab' | 'new_workspace' | 'tab';
      tabId?: string;
      split?: 'right' | 'down';
      label?: string;
    }
  | { kind: 'agent_start'; name: string; agentKind: string; paneId: string; args?: string[] }
  | { kind: 'agent_rename'; target: string; name?: string }
  | { kind: 'agent_focus'; target: string };

export type ClientRequest =
  | { type: 'herdr_info'; force?: boolean }
  | { type: 'herdr_workspaces' }
  | { type: 'herdr_tabs'; workspaceId: string }
  | { type: 'herdr_panes'; workspaceId: string }
  | { type: 'herdr_agents' }
  | { type: 'herdr_agent'; target: string }
  | { type: 'herdr_layout'; paneId: string }
  | { type: 'herdr_read'; paneId: string; source?: HerdrReadSource; lines?: number }
  | { type: 'herdr_prompt'; target: string; text: string; wait?: boolean; timeoutMs?: number }
  | { type: 'herdr_send_text'; paneId: string; text: string; paste?: boolean }
  | { type: 'herdr_send_keys'; target: string; keys: string[]; repeat?: number }
  | { type: 'herdr_run'; paneId: string; command: string }
  | { type: 'herdr_wait'; target: string; until?: HerdrAgentStatus[]; timeoutMs?: number }
  | { type: 'herdr_act'; action: HerdrAction }
  // Selects the pane whose live output is streamed to this client. Omit or null
  // to stop streaming content; structure pushes continue either way.
  | { type: 'herdr_watch'; paneId?: string | null }
  | { type: 'codex_projects'; cursor?: string }
  | { type: 'codex_threads'; projectId?: string; cursor?: string }
  | { type: 'codex_read'; threadId: string; cursor?: string }
  | { type: 'codex_resume'; threadId: string }
  | { type: 'codex_send'; threadId: string; text: string; turnId?: string }
  | { type: 'codex_interrupt'; threadId: string; turnId: string }
  | { type: 'codex_respond'; threadId: string; requestId: string; decision: 'accept' | 'decline' | 'cancel'; answers?: Record<string, string[]> }
  | { type: 'create_terminal'; cwd: string; cols?: number; rows?: number }
  | { type: 'terminal_input'; sessionId: string; data: string }
  | { type: 'terminal_resize'; sessionId: string; cols: number; rows: number }
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

export type CodexAvailability = { available: boolean; canControl: boolean; reason?: string };
export type CodexProject = { id: string; title: string; roots: string[] };
export type CodexThread = {
  id: string;
  projectId?: string;
  title: string;
  cwd: string;
  updatedAt: number;
  status: string;
  canAcceptDirectInput: boolean;
  canResume: boolean;
  activeTurnId?: string;
};
export type CodexItem = {
  id: string;
  kind: 'user' | 'assistant' | 'thinking' | 'tool' | 'system' | 'error' | 'unknown';
  text: string;
  toolName?: string;
};
export type CodexTurn = { id: string; status: string; items: CodexItem[] };
export type CodexPendingRequest = {
  requestId: string;
  kind: 'command' | 'fileChange' | 'userInput' | 'permissions' | 'unsupported';
  title: string;
  description?: string;
  canAccept: boolean;
  questions?: { id: string; question: string; header?: string; isSecret?: boolean; isOther?: boolean; options: QuestionOption[] }[];
};

export type AgentMessage =
  | { kind: 'herdr_info'; id?: string; availability: HerdrAvailability }
  | { kind: 'herdr_workspaces'; id?: string; workspaces: HerdrWorkspace[] }
  | { kind: 'herdr_tabs'; id?: string; workspaceId: string; tabs: HerdrTab[] }
  | { kind: 'herdr_panes'; id?: string; workspaceId: string; panes: HerdrPane[] }
  | { kind: 'herdr_agents'; id?: string; agents: HerdrAgent[] }
  | { kind: 'herdr_agent'; id?: string; agent: HerdrAgent }
  | { kind: 'herdr_layout'; id?: string; layout: HerdrLayout }
  | { kind: 'herdr_output'; id?: string; paneId: string; source: HerdrReadSource; text: string }
  | { kind: 'herdr_result'; id?: string; action: string; summary: string; data?: unknown }
  // -- pushes (no request id; unsolicited) ---------------------------------
  // Pane content. `reset` means "replace everything with chunk"; otherwise the
  // receiver keeps the first `prefix` characters it already has and appends.
  // `format` is `ansi` for the snapshot stream: chunk carries escape sequences
  // and must be replayed, not treated as plain text.
  | {
      kind: 'herdr_pane_output';
      paneId: string;
      revision: number;
      format: string;
      reset: boolean;
      prefix: number;
      chunk: string;
    }
  // A structure change. Only the parts that changed are present, so the phone
  // patches its caches instead of re-listing.
  | {
      kind: 'herdr_structure';
      workspaceId?: string;
      workspaces?: HerdrWorkspace[];
      agents?: HerdrAgent[];
      tabs?: HerdrTab[];
      panes?: HerdrPane[];
    }
  | { kind: 'codex_projects'; id?: string; projects: CodexProject[]; nextCursor?: string }
  | { kind: 'codex_threads'; id?: string; threads: CodexThread[]; nextCursor?: string }
  | { kind: 'codex_thread'; id?: string; thread: CodexThread; turns: CodexTurn[]; nextCursor?: string; pendingRequests?: CodexPendingRequest[] }
  | { kind: 'codex_changed'; threadId?: string }
  | { kind: 'codex_pending'; threadId: string; requests: CodexPendingRequest[] }
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
      capabilities?: string[];
      codex?: CodexAvailability;
      herdr?: HerdrAvailability;
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
