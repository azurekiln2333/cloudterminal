// Protocol handler: turns client requests into Session operations and fans
// session output back out to subscribed clients. Transport-agnostic; the
// relay link (or a test) feeds it messages and supplies `emit`.

import { readdir, stat } from 'node:fs/promises';
import { hostname } from 'node:os';
import path from 'node:path';

import {
  PERMISSION_MODES,
  PROTOCOL_VERSION,
  type AgentMessage,
  type ClientMessage,
  type DirEntry,
  type EventBody,
  type HerdrAvailability,
  type HistoryItem,
  type PermissionModeName,
} from '../shared/protocol.ts';import { type Logger, silentLogger } from '../shared/log.ts';
import { normalize } from './normalize.ts';
import { Session, type QueryFn, type SessionListener, type ManagedSession } from './session.ts';

import type { PtyFactory } from './pty.ts';
import { TerminalSession } from './terminal-session.ts';
import type { CodexBridge } from './codex.ts';
import { HerdrArgumentError, HerdrError, requirePaneId, type HerdrBridge } from './herdr.ts';
import type { HerdrLivePush } from './herdr-live.ts';

export type HistoryLoader = {
  list(cwd?: string): Promise<HistoryItem[]>;
  /** Raw SDK messages of a stored transcript. */
  messages(claudeSessionId: string, cwd?: string): Promise<unknown[]>;
};

export type AgentCoreOptions = {
  queryFn: QueryFn;
  ptyFactory?: PtyFactory;
  codex?: CodexBridge;
  /** Local Herdr workspace manager bridge; absent = feature unavailable. */
  herdr?: HerdrBridge;
  /**
   * Live Herdr push (structure events + pane content). Absent = the phone falls
   * back to its own refresh; every request/response path keeps working.
   */
  herdrLive?: HerdrLivePush;
  /** Directories sessions may run in (and below). */
  roots: string[];
  defaultCwd: string;
  allowBypass?: boolean;
  claudePath?: string;
  history?: HistoryLoader;
  maxSessions?: number;
  logger?: Logger;
};

/** `to` undefined = every connected client. */
export type Emit = (msg: AgentMessage, to?: string) => void;

const MAX_DIR_ENTRIES = 500;
const HIDDEN_DIRS = new Set(['node_modules', '$RECYCLE.BIN', 'System Volume Information']);

export class AgentCore {
  private readonly opts: AgentCoreOptions;
  private readonly log: Logger;
  private readonly roots: string[];
  private readonly sessions = new Map<string, ManagedSession>();
  private readonly subs = new Map<string, Set<string>>();
  /** Pane each client asked to stream; the newest request wins. */
  private readonly watchedPanes = new Map<string, string>();
  /** Monotonic request order per pane, so "latest" survives a client leaving. */
  private readonly watchOrder = new Map<string, number>();
  private watchSeq = 0;
  private readonly dirtySessions = new Set<ManagedSession>();
  private flushScheduled = false;
  /**
   * One emitter per connected relay link.
   *
   * The agent can be attached to several relays at once (in-process LAN relay
   * plus an optional public one), so a single slot would let the second link
   * silently steal the first link's outbound stream.
   */
  private readonly emitters = new Set<Emit>();

  constructor(opts: AgentCoreOptions) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
    this.roots = opts.roots.map((r) => path.resolve(r));
    opts.codex?.setEmitter((message) => this.fanout(message));
  }

  /**
   * Register an outbound sink and return a function that removes it again.
   *
   * Links must detach on stop, otherwise a closed socket keeps receiving
   * frames until the process exits.
   */
  addEmitter(emit: Emit): () => void {
    this.emitters.add(emit);
    return () => this.emitters.delete(emit);
  }

  /** Replaces every registered sink; kept for the single-link callers/tests. */
  setEmitter(emit: Emit): void {
    this.emitters.clear();
    this.emitters.add(emit);
  }

  /** Public so the live push (constructed outside) can emit into every link. */
  fanout(msg: AgentMessage, to?: string): void {
    for (const emit of this.emitters) emit(msg, to);
  }

  /** Startup/logging helper; undefined when Herdr is disabled. */
  async herdrAvailability(): Promise<HerdrAvailability | undefined> {
    return this.opts.herdr ? await this.opts.herdr.availability() : undefined;
  }

  clientLeft(clientId: string): void {
    this.subs.delete(clientId);
    this.watchedPanes.delete(clientId);
    this.refreshWatchedPane();
  }

  /**
   * Records which pane a client wants streamed, and reconciles the push target.
   *
   * Several phones can watch different panes, so the live push follows the
   * *most recently requested* pane: serving the union would multiply the desktop
   * read cost for no benefit, and the last tap is the user's actual intent.
   */
  private watchPane(clientId: string, paneId: string | undefined): void {
    if (paneId) {
      this.watchedPanes.set(clientId, paneId);
      this.watchSeq += 1;
      this.watchOrder.set(paneId, this.watchSeq);
    } else {
      this.watchedPanes.delete(clientId);
    }
    this.refreshWatchedPane();
  }

  private refreshWatchedPane(): void {
    if (!this.opts.herdrLive) return;
    let latest: { paneId: string; at: number } | undefined;
    for (const paneId of this.watchedPanes.values()) {
      const at = this.watchOrder.get(paneId) ?? 0;
      if (!latest || at >= latest.at) latest = { paneId, at };
    }
    this.opts.herdrLive.selectPane(latest?.paneId);
  }

  async closeAll(): Promise<void> {
    this.opts.codex?.close();
    await Promise.all([...this.sessions.values()].map((s) => s.close()));
  }

  async handle(clientId: string, msg: ClientMessage): Promise<void> {
    const id = msg.id;
    try {
      const reply = await this.dispatch(clientId, msg);
      this.fanout(reply ?? { kind: 'ack', id }, clientId);
    } catch (err) {
      const message = err instanceof HerdrError
        ? err.wire()
        : err instanceof HerdrArgumentError
          ? `herdr_invalid_argument:${err.message}`
          : err instanceof Error
            ? err.message
            : String(err);
      this.log.warn('request failed', { type: msg.type, message });
      this.fanout({ kind: 'error', id, message }, clientId);
    }
  }

  // -------------------------------------------------------------------------

  private async dispatch(clientId: string, msg: ClientMessage): Promise<AgentMessage | void> {
    const id = msg.id;
    switch (msg.type) {
      case 'info': {
        const codex = this.opts.codex ? await this.opts.codex.availability() : undefined;
        const herdr = this.opts.herdr ? await this.opts.herdr.availability() : undefined;
        return {
          kind: 'info',
          id,
          host: hostname(),
          platform: process.platform,
          defaultCwd: this.opts.defaultCwd,
          roots: this.roots,
          allowBypass: this.opts.allowBypass === true,
          version: PROTOCOL_VERSION,
          capabilities: [
            ...(this.opts.ptyFactory ? ['terminal'] : []),
            ...(codex?.available ? ['codex_history', ...(codex.canControl ? ['codex_control'] : [])] : []),
            ...(herdr?.available ? ['herdr', 'herdr_paste'] : []),
          ],
          codex,
          herdr,
        };
      }

      case 'herdr_info':
        return { kind: 'herdr_info', id, availability: await this.herdr().availability(msg.force === true) };
      case 'herdr_workspaces':
        return { kind: 'herdr_workspaces', id, workspaces: await this.herdr().workspaces() };
      case 'herdr_tabs':
        return { kind: 'herdr_tabs', id, workspaceId: msg.workspaceId, tabs: await this.herdr().tabs(msg.workspaceId) };
      case 'herdr_panes':
        return { kind: 'herdr_panes', id, workspaceId: msg.workspaceId, panes: await this.herdr().panes(msg.workspaceId) };
      case 'herdr_agents':
        return { kind: 'herdr_agents', id, agents: await this.herdr().agents() };
      case 'herdr_agent':
        return { kind: 'herdr_agent', id, agent: await this.herdr().agent(msg.target) };
      case 'herdr_layout':
        return { kind: 'herdr_layout', id, layout: await this.herdr().layout(msg.paneId) };
      case 'herdr_read': {
        const output = await this.herdr().read(msg.paneId, msg.source, msg.lines);
        return { kind: 'herdr_output', id, ...output };
      }
      case 'herdr_prompt': {
        const summary = await this.herdr().prompt(msg.target, msg.text, { wait: msg.wait, timeoutMs: msg.timeoutMs });
        return { kind: 'herdr_result', id, action: 'prompt', summary };
      }
      case 'herdr_send_text': {
        const summary = await this.herdr().sendText(msg.paneId, msg.text, msg.paste);
        return { kind: 'herdr_result', id, action: 'send_text', summary };
      }
      case 'herdr_send_keys': {
        const summary = await this.herdr().sendKeys(msg.target, msg.keys, msg.repeat);
        return { kind: 'herdr_result', id, action: 'send_keys', summary };
      }
      case 'herdr_run': {
        const summary = await this.herdr().run(msg.paneId, msg.command);
        return { kind: 'herdr_result', id, action: 'run', summary };
      }
      case 'herdr_wait': {
        const summary = await this.herdr().wait(msg.target, msg.until, msg.timeoutMs);
        return { kind: 'herdr_result', id, action: 'wait', summary };
      }
      case 'herdr_act': {
        const { summary, data } = await this.herdr().act(msg.action);
        return { kind: 'herdr_result', id, action: msg.action.kind, summary, data };
      }
      case 'herdr_watch': {
        // Validated here rather than in the bridge: this selects a *read* target,
        // and the pane id is the only mobile-supplied value it carries.
        const paneId = msg.paneId === undefined || msg.paneId === null ? undefined : requirePaneId(msg.paneId);
        this.watchPane(clientId, paneId);
        return { kind: 'ack', id };
      }

      case 'codex_projects':
        return { kind: 'codex_projects', id, ...await this.codex().projects(msg.cursor) };
      case 'codex_threads':
        return { kind: 'codex_threads', id, ...await this.codex().threads(msg.projectId, msg.cursor) };
      case 'codex_read':
        return { kind: 'codex_thread', id, ...await this.codex().read(msg.threadId, msg.cursor) };
      case 'codex_resume':
        return { kind: 'codex_thread', id, ...await this.codex().resume(msg.threadId) };
      case 'codex_send':
        await this.codex().send(msg.threadId, msg.text, msg.turnId);
        return;
      case 'codex_interrupt':
        await this.codex().interrupt(msg.threadId, msg.turnId);
        return;
      case 'codex_respond':
        await this.codex().respond(msg.threadId, msg.requestId, msg.decision, msg.answers);
        return;

      case 'list_sessions':
        return { kind: 'sessions', id, sessions: this.sortedSessions().map((s) => s.info()) };

      case 'list_history': {
        const cwd = msg.cwd ? this.checkPath(msg.cwd) : undefined;
        const items = this.opts.history ? await this.opts.history.list(cwd) : [];
        return { kind: 'history', id, items };
      }

      case 'list_dir':
        return { kind: 'dir', id, ...(await this.listDir(msg.path)) };

      case 'create_terminal': {
        const session = await this.createTerminal(msg.cwd, msg.cols, msg.rows);
        return { kind: 'session_created', id, session: session.info() };
      }
      case 'terminal_input':
        this.terminal(msg.sessionId).write(msg.data);
        return;
      case 'terminal_resize':
        this.terminal(msg.sessionId).resize(msg.cols, msg.rows);
        return;
      case 'create_session': {
        const cwd = this.checkPath(msg.cwd);
        const info = await stat(cwd).catch(() => null);
        if (!info?.isDirectory()) throw new Error(`目录不存在：${cwd}`);
        const mode = this.checkMode(msg.mode ?? 'default');
        const live = [...this.sessions.values()].filter((s) => s.status !== 'closed').length;
        if (live >= (this.opts.maxSessions ?? 8)) throw new Error('活动会话过多，请先关闭一些会话');

        let history: EventBody[] | undefined;
        let title: string | undefined;
        if (msg.resume) {
          const raw = this.opts.history ? await this.opts.history.messages(msg.resume, cwd) : [];
          history = raw.flatMap((m) => normalize(m, { includeUserText: true }).events);
          const firstUser = history.find((e) => e.kind === 'user');
          title = firstUser?.kind === 'user' ? firstUser.text.replace(/\s+/g, ' ').slice(0, 60) : undefined;
          history.push({ kind: 'system', text: '以上为历史记录，已恢复会话' });
        }

        const session = new Session(
          this.opts.queryFn,
          {
            cwd,
            mode,
            model: msg.model,
            resume: msg.resume,
            allowBypass: this.opts.allowBypass === true,
            claudePath: this.opts.claudePath,
            history,
            title,
          },
          this.listener,
        );
        this.sessions.set(session.id, session);
        this.pruneClosed();
        this.log.info('session created', { id: session.id, cwd, mode, resume: msg.resume });
        if (msg.prompt?.trim()) session.send(msg.prompt);
        this.markDirty(session);
        return { kind: 'session_created', id, session: session.info() };
      }

      case 'subscribe': {
        if (msg.afterSeq !== undefined && (!Number.isSafeInteger(msg.afterSeq) || msg.afterSeq < 0)) throw new Error('无效的回放序号');
        const s = this.session(msg.sessionId);
        let set = this.subs.get(clientId);
        if (!set) this.subs.set(clientId, (set = new Set()));
        set.add(s.id);
        const { events, reset } = s.eventsAfter(msg.afterSeq ?? 0);
        this.fanout({ kind: 'session', session: s.info() }, clientId);
        return { kind: 'events', id, sessionId: s.id, events, reset };
      }

      case 'unsubscribe':
        this.subs.get(clientId)?.delete(msg.sessionId);
        return;

      case 'send':
        this.claude(msg.sessionId).send(msg.text);
        return;

      case 'interrupt':
        await this.session(msg.sessionId).interrupt();
        return;

      case 'permission':
        this.claude(msg.sessionId).respondPermission(msg.requestId, msg.decision, {
          message: msg.message,
          answers: msg.answers,
        });
        return;

      case 'set_mode':
        await this.claude(msg.sessionId).setMode(this.checkMode(msg.mode));
        return;

      case 'close_session': {
        const s = this.session(msg.sessionId);
        await s.close();
        this.fanout({ kind: 'session', session: s.info() });
        this.sessions.delete(s.id);
        for (const set of this.subs.values()) set.delete(s.id);
        return;
      }

      default:
        throw new Error(`unknown request type: ${(msg as { type?: unknown }).type}`);
    }
  }

  private codex(): CodexBridge {
    if (!this.opts.codex) throw new Error('此电脑尚未启用 Codex Desktop 接入');
    return this.opts.codex;
  }

  private herdr(): HerdrBridge {
    if (!this.opts.herdr) {
      throw new HerdrError('herdr_unavailable', '这台电脑没有启用 Herdr 接入。请安装 Herdr 后重启 agent。');
    }
    return this.opts.herdr;
  }

  private readonly listener: SessionListener = {
    onEvent: (s, event) => {
      for (const [clientId, set] of this.subs) {
        if (set.has(s.id)) this.fanout({ kind: 'event', sessionId: s.id, event }, clientId);
      }
    },
    onDelta: (s, text) => {
      for (const [clientId, set] of this.subs) {
        if (set.has(s.id)) this.fanout({ kind: 'delta', sessionId: s.id, text }, clientId);
      }
    },
    onState: (s) => this.markDirty(s),
  };

  /** Coalesce state broadcasts: many touches in one tick → one message. */
  private markDirty(s: ManagedSession): void {
    this.dirtySessions.add(s);
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    queueMicrotask(() => {
      this.flushScheduled = false;
      const batch = [...this.dirtySessions];
      this.dirtySessions.clear();
      for (const d of batch) {
        if (this.sessions.get(d.id) === d) this.fanout({ kind: 'session', session: d.info() });
      }
    });
  }

  private sortedSessions(): ManagedSession[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  /** Keep at most 20 finished sessions around for viewing. */
  private pruneClosed(): void {
    const closed = this.sortedSessions().filter((s) => s.status === 'closed');
    for (const s of closed.slice(20)) this.sessions.delete(s.id);
  }

  private session(id: string): ManagedSession {
    const s = this.sessions.get(id);
    if (!s) throw new Error('会话不存在或已被关闭');
    return s;
  }

  async createTerminal(cwd: string, cols?: number, rows?: number): Promise<TerminalSession> {
    if (!this.opts.ptyFactory) throw new Error('本机暂不支持终端');
    const resolved = this.checkPath(cwd);
    const info = await stat(resolved).catch(() => null);
    if (!info?.isDirectory()) throw new Error(`目录不存在：${resolved}`);
    const live = [...this.sessions.values()].filter((s) => s.status !== 'closed').length;
    if (live >= (this.opts.maxSessions ?? 8)) throw new Error('活动会话过多，请先关闭一些会话');
    const session = new TerminalSession(this.opts.ptyFactory, { cwd: resolved, cols, rows }, this.listener);
    this.sessions.set(session.id, session);
    this.pruneClosed();
    this.markDirty(session);
    return session;
  }

  private terminal(id: string): TerminalSession {
    const session = this.session(id);
    if (!(session instanceof TerminalSession)) throw new Error('该会话不是终端');
    return session;
  }

  private claude(id: string): Session {
    const session = this.session(id);
    if (!(session instanceof Session)) throw new Error('终端不支持 Claude 会话操作');
    return session;
  }

  private checkMode(mode: string): PermissionModeName {
    if (!PERMISSION_MODES.includes(mode as PermissionModeName)) throw new Error(`未知的权限模式：${mode}`);
    if (mode === 'bypassPermissions' && !this.opts.allowBypass) {
      throw new Error('本机未开启 bypassPermissions（启动 agent 时加 --allow-bypass）');
    }
    return mode as PermissionModeName;
  }

  /** Resolve and confine a client-supplied path to the configured roots. */
  checkPath(p: string): string {
    if (typeof p !== 'string' || !p.trim()) throw new Error('路径为空');
    const resolved = path.resolve(p);
    if (!this.roots.some((r) => isWithin(resolved, r))) throw new Error(`路径不在允许的目录内：${resolved}`);
    return resolved;
  }

  private async listDir(p?: string): Promise<{ path: string; parent: string | null; entries: DirEntry[] }> {
    if (!p) {
      return { path: '', parent: null, entries: this.roots.map((r) => ({ name: r, path: r })) };
    }
    const dir = this.checkPath(p);
    const dirents = await readdir(dir, { withFileTypes: true });
    const entries = dirents
      .filter((d) => d.isDirectory() && !d.name.startsWith('.') && !HIDDEN_DIRS.has(d.name))
      .map((d) => d.name)
      .sort((a, b) => a.localeCompare(b))
      .slice(0, MAX_DIR_ENTRIES)
      .map((name) => ({ name, path: path.join(dir, name) }));
    const up = path.dirname(dir);
    const parent = this.roots.includes(dir) || up === dir || !this.roots.some((r) => isWithin(up, r)) ? '' : up;
    return { path: dir, parent, entries };
  }
}

function isWithin(child: string, root: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
