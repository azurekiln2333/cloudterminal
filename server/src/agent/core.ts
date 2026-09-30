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
  type HistoryItem,
  type PermissionModeName,
} from '../shared/protocol.ts';
import { type Logger, silentLogger } from '../shared/log.ts';
import { normalize } from './normalize.ts';
import { Session, type QueryFn, type SessionListener } from './session.ts';

export type HistoryLoader = {
  list(cwd?: string): Promise<HistoryItem[]>;
  /** Raw SDK messages of a stored transcript. */
  messages(claudeSessionId: string, cwd?: string): Promise<unknown[]>;
};

export type AgentCoreOptions = {
  queryFn: QueryFn;
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
  private readonly sessions = new Map<string, Session>();
  private readonly subs = new Map<string, Set<string>>();
  private readonly dirtySessions = new Set<Session>();
  private flushScheduled = false;
  private emit: Emit = () => {};

  constructor(opts: AgentCoreOptions) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
    this.roots = opts.roots.map((r) => path.resolve(r));
  }

  setEmitter(emit: Emit): void {
    this.emit = emit;
  }

  clientLeft(clientId: string): void {
    this.subs.delete(clientId);
  }

  closeAll(): void {
    for (const s of this.sessions.values()) s.close();
  }

  async handle(clientId: string, msg: ClientMessage): Promise<void> {
    const id = msg.id;
    try {
      const reply = await this.dispatch(clientId, msg);
      this.emit(reply ?? { kind: 'ack', id }, clientId);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.log.warn('request failed', { type: msg.type, message });
      this.emit({ kind: 'error', id, message }, clientId);
    }
  }

  // -------------------------------------------------------------------------

  private async dispatch(clientId: string, msg: ClientMessage): Promise<AgentMessage | void> {
    const id = msg.id;
    switch (msg.type) {
      case 'info':
        return {
          kind: 'info',
          id,
          host: hostname(),
          platform: process.platform,
          defaultCwd: this.opts.defaultCwd,
          roots: this.roots,
          allowBypass: this.opts.allowBypass === true,
          version: PROTOCOL_VERSION,
        };

      case 'list_sessions':
        return { kind: 'sessions', id, sessions: this.sortedSessions().map((s) => s.info()) };

      case 'list_history': {
        const cwd = msg.cwd ? this.checkPath(msg.cwd) : undefined;
        const items = this.opts.history ? await this.opts.history.list(cwd) : [];
        return { kind: 'history', id, items };
      }

      case 'list_dir':
        return { kind: 'dir', id, ...(await this.listDir(msg.path)) };

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
        const s = this.session(msg.sessionId);
        let set = this.subs.get(clientId);
        if (!set) this.subs.set(clientId, (set = new Set()));
        set.add(s.id);
        const { events, reset } = s.eventsAfter(msg.afterSeq ?? 0);
        this.emit({ kind: 'session', session: s.info() }, clientId);
        return { kind: 'events', id, sessionId: s.id, events, reset };
      }

      case 'unsubscribe':
        this.subs.get(clientId)?.delete(msg.sessionId);
        return;

      case 'send':
        this.session(msg.sessionId).send(msg.text);
        return;

      case 'interrupt':
        await this.session(msg.sessionId).interrupt();
        return;

      case 'permission':
        this.session(msg.sessionId).respondPermission(msg.requestId, msg.decision, {
          message: msg.message,
          answers: msg.answers,
        });
        return;

      case 'set_mode':
        await this.session(msg.sessionId).setMode(this.checkMode(msg.mode));
        return;

      case 'close_session': {
        const s = this.session(msg.sessionId);
        s.close();
        this.sessions.delete(s.id);
        for (const set of this.subs.values()) set.delete(s.id);
        return;
      }

      default:
        throw new Error(`unknown request type: ${(msg as { type?: unknown }).type}`);
    }
  }

  private readonly listener: SessionListener = {
    onEvent: (s, event) => {
      for (const [clientId, set] of this.subs) {
        if (set.has(s.id)) this.emit({ kind: 'event', sessionId: s.id, event }, clientId);
      }
    },
    onDelta: (s, text) => {
      for (const [clientId, set] of this.subs) {
        if (set.has(s.id)) this.emit({ kind: 'delta', sessionId: s.id, text }, clientId);
      }
    },
    onState: (s) => this.markDirty(s),
  };

  /** Coalesce state broadcasts: many touches in one tick → one message. */
  private markDirty(s: Session): void {
    this.dirtySessions.add(s);
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    queueMicrotask(() => {
      this.flushScheduled = false;
      const batch = [...this.dirtySessions];
      this.dirtySessions.clear();
      for (const d of batch) {
        if (this.sessions.get(d.id) === d) this.emit({ kind: 'session', session: d.info() });
      }
    });
  }

  private sortedSessions(): Session[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  /** Keep at most 20 finished sessions around for viewing. */
  private pruneClosed(): void {
    const closed = this.sortedSessions().filter((s) => s.status === 'closed');
    for (const s of closed.slice(20)) this.sessions.delete(s.id);
  }

  private session(id: string): Session {
    const s = this.sessions.get(id);
    if (!s) throw new Error('会话不存在或已被关闭');
    return s;
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
