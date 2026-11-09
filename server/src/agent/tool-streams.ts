// Managed tool sessions and read-only streams for the Windows assistant.
//
// Two modes, kept honest in the wire shape:
//   * managed  -> a real event stream (Codex app-server JSON-RPC, Claude
//                 `--output-format stream-json`).
//   * read-only -> a one-shot history or a screen poll (`claude logs`,
//                 Herdr `pane read`).
//
// The enum on each binding tells the UI which one it is; nothing here upgrades a
// poll to a "stream". No user session is ever killed, restarted or duplicated:
// bindings only observe, and only processes we started ourselves are stopped.

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

import type { Logger } from '../shared/log.ts';
import { HerdrBridge } from './herdr.ts';
import { probeTools } from './tool-probe.ts';

export type StreamOrigin = 'managed-stream' | 'daemon-history' | 'pane-poll';

export type BindingView = {
  kind: 'herdr' | 'codex' | 'claude';
  id: string;
  title: string;
  subtitle?: string;
  origin: StreamOrigin;
  pollIntervalMs?: number;
  canAcceptInput: boolean;
  cwd?: string;
  status?: string;
};

export type StreamEventPayload = {
  kind: 'herdr' | 'codex' | 'claude';
  sessionId: string;
  eventKind: string;
  text: string;
  done?: boolean;
};

export type ToolStreams = {
  bindings(): BindingView[];
  bind(id: string): Promise<void>;
  unbind(id: string): Promise<void>;
  input(id: string, text: string): Promise<void>;
  setPollInterval(id: string, milliseconds: number): Promise<void>;
  /** Start a new managed Claude stream (真流). Never touches user sessions. */
  startManagedClaude(prompt?: string): Promise<string>;
  close(): Promise<void>;
};

export type ToolStreamsOptions = {
  emit: (event: StreamEventPayload) => void;
  logger: Logger;
  roots: string[];
  defaultCwd: string;
  /** Test seam: override how a managed process is spawned. */
  spawnFn?: typeof spawn;
  /** Test seam: override tool discovery. */
  probeFn?: typeof probeTools;
};

const MANAGED_PREFIX = 'managed:';

export function createToolStreams(options: ToolStreamsOptions): ToolStreams {
  const log = options.logger;
  const spawnFn = options.spawnFn ?? spawn;
  const probeFn = options.probeFn ?? probeTools;

  const connected = new Map<string, BindingView>();
  const pollers = new Map<string, NodeJS.Timeout>();
  const children = new Map<string, ChildProcessWithoutNullStreams>();
  const pollIntervals = new Map<string, number>();

  async function listReadOnly(): Promise<BindingView[]> {
    const views: BindingView[] = [];
    const tools = await probeFn();
    const probe = (kind: string) => tools.find((t) => t.kind === kind);

    // Herdr panes: screen reads, polled because the CLI has no change feed.
    if (probe('herdr')?.installed) {
      try {
        const herdr = new HerdrBridge({ logger: log });
        for (const workspace of await herdr.workspaces()) {
          const panes = await herdr.panes(workspace.workspaceId);
          for (const pane of panes) {
            views.push({
              kind: 'herdr',
              id: pane.paneId,
              title: pane.paneId,
              subtitle: `${workspace.label} · ${pane.terminalTitle || pane.agent || 'shell'}`,
              origin: 'pane-poll',
              pollIntervalMs: pollIntervals.get(pane.paneId) ?? 1000,
              canAcceptInput: false,
              cwd: pane.cwd,
              status: pane.agentStatus,
            });
          }
        }
      } catch (err) {
        log.warn('herdr listing failed', { error: err instanceof Error ? err.message : String(err) });
      }
    }

    // Codex threads are visible through the app-server history API. Listed
    // read-only here; a managed stream is created by starting a bound session.
    // (Enumerating threads needs the JSON-RPC client, which is out of scope for
    // this read-only listing, so nothing is fabricated when it is unavailable.)

    // Claude background sessions are a real, documented listing.
    if (probe('claude')?.installed) {
      const sessions = await probeFn(); // reuse for the executable path below
      const claude = sessions.find((t) => t.kind === 'claude');
      if (claude?.executable) {
        const listed = await listClaudeAgents(claude.executable);
        views.push(...listed);
      }
    }
    return views;
  }

  async function listClaudeAgents(executable: string): Promise<BindingView[]> {
    return await new Promise<BindingView[]>((resolve) => {
      let out = '';
      const child = spawnFn(executable, ['agents', '--json', '--all'], { shell: false, windowsHide: true });
      child.stdout?.on('data', (d: Buffer) => (out += d.toString('utf8')));
      child.on('error', () => resolve([]));
      child.on('close', () => {
        try {
          const parsed = JSON.parse(out) as unknown;
          if (!Array.isArray(parsed)) return resolve([]);
          resolve(
            parsed
              .filter((entry): entry is Record<string, unknown> => Boolean(entry) && typeof entry === 'object')
              .map((entry) => ({
                kind: 'claude' as const,
                id: String(entry.id ?? entry.session_id ?? ''),
                title: String(entry.name ?? entry.id ?? 'claude session'),
                subtitle: typeof entry.cwd === 'string' ? entry.cwd : undefined,
                origin: 'daemon-history' as const,
                canAcceptInput: false,
                cwd: typeof entry.cwd === 'string' ? entry.cwd : undefined,
                status: typeof entry.status === 'string' ? entry.status : undefined,
              }))
              .filter((v) => v.id.length > 0),
          );
        } catch {
          resolve([]);
        }
      });
    });
  }

  async function bind(id: string): Promise<void> {
    if (connected.has(id)) return;
    const all = await listReadOnly();
    const view = all.find((b) => b.id === id);
    if (!view) throw new Error(`找不到会话 ${id}`);
    connected.set(id, view);
    if (view.origin === 'pane-poll') {
      await startPolling(view);
    } else if (view.origin === 'daemon-history') {
      await readOnce(view);
    }
  }

  async function readOnce(view: BindingView): Promise<void> {
    if (view.kind === 'claude') {
      const tools = await probeFn();
      const claude = tools.find((t) => t.kind === 'claude');
      if (!claude?.executable) return;
      const text = await new Promise<string>((resolve) => {
        let out = '';
        const child = spawnFn(claude.executable!, ['logs', view.id], { shell: false, windowsHide: true });
        child.stdout?.on('data', (d: Buffer) => (out += d.toString('utf8')));
        child.on('error', () => resolve(''));
        child.on('close', () => resolve(out));
      });
      options.emit({
        kind: 'claude',
        sessionId: view.id,
        eventKind: 'snapshot',
        text: text.trim() || '（没有可显示的历史输出）',
      });
    }
  }

  async function startPolling(view: BindingView): Promise<void> {
    if (pollers.has(view.id)) return;
    const herdr = new HerdrBridge({ logger: log });
    const intervalMs = view.pollIntervalMs ?? 1000;
    const tick = async (): Promise<void> => {
      try {
        const output = await herdr.read(view.id, 'recent-unwrapped', 200);
        options.emit({
          kind: 'herdr',
          sessionId: view.id,
          eventKind: 'snapshot',
          text: output.text.trimEnd() || '（屏幕为空）',
        });
      } catch (err) {
        options.emit({
          kind: 'herdr',
          sessionId: view.id,
          eventKind: 'stderr',
          text: `读取失败：${err instanceof Error ? err.message : String(err)}`,
        });
      }
    };
    await tick();
    pollers.set(view.id, setInterval(() => void tick(), intervalMs));
    log.info('pane poll started', { pane: view.id, intervalMs });
  }

  async function unbind(id: string): Promise<void> {
    const timer = pollers.get(id);
    if (timer) {
      clearInterval(timer);
      pollers.delete(id);
    }
    const child = children.get(id);
    if (child) {
      // Only stop a process THIS module started; never a user session.
      child.kill();
      children.delete(id);
    }
    connected.delete(id);
  }

  async function input(id: string, text: string): Promise<void> {
    const view = connected.get(id);
    if (!view) throw new Error('该会话未绑定');
    if (!view.canAcceptInput) {
      throw new Error('该会话是只读来源，不能发送输入。');
    }
    const child = children.get(id);
    if (!child) throw new Error('该会话没有可写入的进程');
    child.stdin.write(`${text}\n`);
  }

  async function setPollInterval(id: string, milliseconds: number): Promise<void> {
    const value = Number.isFinite(milliseconds) ? Math.min(Math.max(milliseconds, 250), 10_000) : 1000;
    pollIntervals.set(id, value);
    const view = connected.get(id);
    if (view && view.origin === 'pane-poll') {
      const timer = pollers.get(id);
      if (timer) clearInterval(timer);
      pollers.delete(id);
      view.pollIntervalMs = value;
      await startPolling(view);
    }
  }

  async function close(): Promise<void> {
    for (const timer of pollers.values()) clearInterval(timer);
    pollers.clear();
    for (const child of children.values()) child.kill();
    children.clear();
    connected.clear();
  }

  /**
   * Start a NEW Claude Code session as a real event stream and stream its
   * NDJSON to the UI. This is a first-class managed stream: the binding's origin
   * is `managed-stream`, so the UI is allowed to call it live. It never attaches
   * to or restarts an existing user session.
   */
  async function startManagedClaude(prompt?: string): Promise<string> {
    const tools = await probeFn();
    const claude = tools.find((t) => t.kind === 'claude');
    if (!claude?.installed || !claude.executable) {
      throw new Error('未安装 Claude Code，无法启动托管会话。');
    }
    const id = `claude-managed-${Date.now().toString(36)}`;
    const argv = ['-p', '--output-format', 'stream-json', '--verbose'];
    const child = spawnFn(claude.executable, argv, {
      shell: false,
      windowsHide: true,
      cwd: options.defaultCwd,
    }) as ChildProcessWithoutNullStreams;

    // On Windows, `.cmd` shims cannot be spawned with shell:false; the Claude
    // install here is a native .exe so a direct spawn is correct. If a shim ever
    // appears, spawn throws and the error is surfaced rather than hidden.
    const binding: BindingView = {
      kind: 'claude',
      id,
      title: 'Claude Code（托管会话）',
      subtitle: prompt ?? '新的托管会话',
      origin: 'managed-stream',
      canAcceptInput: true,
      cwd: options.defaultCwd,
      status: 'starting',
    };
    connected.set(id, binding);
    children.set(id, child);

    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) emitClaudeEvent(id, line);
        index = buffer.indexOf('\n');
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => {
      options.emit({ kind: 'claude', sessionId: id, eventKind: 'stderr', text: chunk.toString() });
    });
    child.on('close', (code) => {
      options.emit({ kind: 'claude', sessionId: id, eventKind: 'exit', text: `进程结束（code ${code ?? '?'}）`, done: true });
      const current = connected.get(id);
      if (current) current.status = 'exited';
    });

    // The first prompt is written to stdin; `-p` reads it, unless a turn stream
    // is used. Keep it simple and honest: write the prompt as one line.
    if (prompt) child.stdin.write(`${prompt}\n`);
    child.stdin.end();

    log.info('managed claude stream started', { id });
    return id;
  }

  /** Map one Claude stream-json line to a UI event, tolerating unknown kinds. */
  function emitClaudeEvent(id: string, line: string): void {
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(line) as Record<string, unknown>;
    } catch {
      // Non-JSON diagnostics are surfaced verbatim rather than dropped.
      options.emit({ kind: 'claude', sessionId: id, eventKind: 'output', text: line });
      return;
    }
    const type = String(parsed.type ?? 'output');
    if (type === 'assistant') {
      const message = parsed.message as { content?: unknown } | undefined;
      const text = extractClaudeText(message?.content);
      if (text) options.emit({ kind: 'claude', sessionId: id, eventKind: 'assistant', text });
      return;
    }
    if (type === 'result') {
      const result = typeof parsed.result === 'string' ? parsed.result : '（本轮结束）';
      options.emit({ kind: 'claude', sessionId: id, eventKind: 'result', text: result, done: true });
      return;
    }
    if (type === 'system') {
      options.emit({ kind: 'claude', sessionId: id, eventKind: 'system', text: String(parsed.subtype ?? 'system') });
      return;
    }
    options.emit({ kind: 'claude', sessionId: id, eventKind: type, text: line });
  }

  function extractClaudeText(content: unknown): string {
    if (!Array.isArray(content)) return '';
    const parts: string[] = [];
    for (const block of content) {
      if (!block || typeof block !== 'object') continue;
      const record = block as Record<string, unknown>;
      if (record.type === 'text' && typeof record.text === 'string') parts.push(record.text);
      else if (record.type === 'tool_use') parts.push(`[工具] ${String(record.name ?? '')}`);
    }
    return parts.join('\n');
  }

  return {
    bindings: () => [...connected.values()].map((v) => ({ ...v })),
    bind,
    unbind,
    input,
    setPollInterval,
    startManagedClaude,
    close,
  };
}

export { MANAGED_PREFIX };
