// The desktop daemon's proxy is a byte tunnel to a WebSocket, NOT JSONL.
// Only `app-server proxy` is launched here; it never starts another app-server.
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { access, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { Duplex } from 'node:stream';
import type { Socket } from 'node:net';
import WebSocket from 'ws';

export type RpcFrame = { id?: string | number; method?: string; params?: unknown; result?: unknown; error?: { code: number; message: string } };
export interface CodexRpc {
  readonly canControl: boolean;
  connect(): Promise<void>;
  request(method: string, params: unknown): Promise<unknown>;
  respond(id: string | number, result: unknown): void;
  reject(id: string | number, message: string): void;
  onFrame: (frame: RpcFrame) => void;
  onDisconnect: () => void;
  close(): void;
}

export type ProxyOptions = { executable?: string; codexHome?: string; timeoutMs?: number };

async function executable(home: string): Promise<string> {
  const releases = path.join(home, 'packages', 'app-server-daemon', 'releases');
  const names = await readdir(releases).catch(() => [] as string[]);
  names.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
  for (const name of names) {
    const candidate = path.join(releases, name, 'bin', process.platform === 'win32' ? 'codex.exe' : 'codex');
    if (await access(candidate).then(() => true, () => false)) return candidate;
  }
  return process.platform === 'win32' ? 'codex.exe' : 'codex';
}

export class DesktopCodexRpc implements CodexRpc {
  canControl = false;
  onFrame: (frame: RpcFrame) => void = () => {};
  onDisconnect: () => void = () => {};
  private readonly opts: ProxyOptions;
  private socket?: WebSocket;
  private child?: ChildProcessWithoutNullStreams;
  private connecting?: Promise<void>;
  private ready = false;
  private serial = 0;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }>();

  constructor(opts: ProxyOptions = {}) { this.opts = opts; }

  async connect(): Promise<void> {
    if (this.ready) return;
    this.connecting ??= this.open().finally(() => { this.connecting = undefined; });
    return this.connecting;
  }

  private async open(): Promise<void> {
    const home = this.opts.codexHome ?? process.env.CODEX_HOME ?? path.join(homedir(), '.codex');
    const sock = path.join(home, 'app-server-control', 'app-server-control.sock');
    await access(sock).catch(() => { throw new Error('Codex Desktop daemon 未运行，请先打开或更新桌面应用'); });
    const bin = this.opts.executable ?? process.env.CLOUDTERMINAL_CODEX_PATH ?? await executable(home);
    const child = spawn(bin, ['app-server', 'proxy', '--sock', sock], { windowsHide: true, stdio: 'pipe' });
    this.child = child;
    // Consume diagnostics without leaking transcript/auth material into logs.
    child.stderr.resume();
    const stream = Duplex.from({ readable: child.stdout, writable: child.stdin });
    const socket = new WebSocket('ws://localhost/', {
      createConnection: () => stream as Socket,
      handshakeTimeout: this.opts.timeoutMs ?? 8000,
      maxPayload: 32 * 1024 * 1024,
    });
    this.socket = socket;
    const failed = () => this.disconnected(socket);
    child.on('error', failed);
    child.on('exit', failed);
    socket.on('close', failed);
    socket.on('error', failed);
    stream.on('error', failed);
    socket.on('message', (bytes) => {
      try {
        const frame = JSON.parse(bytes.toString()) as RpcFrame;
        if (!frame || typeof frame !== 'object') return;
        if (frame.method) { this.onFrame(frame); return; }
        const waiting = typeof frame.id === 'number' ? this.pending.get(frame.id) : undefined;
        if (!waiting) return;
        clearTimeout(waiting.timer);
        this.pending.delete(frame.id as number);
        if (frame.error) waiting.reject(new Error(`Codex: ${frame.error.message}`));
        else waiting.resolve(frame.result);
      } catch { /* Ignore non-JSON diagnostics; never treat them as instructions. */ }
    });
    try {
      await new Promise<void>((resolve, reject) => {
        socket.once('open', resolve);
        socket.once('error', () => reject(new Error('无法连接 Codex Desktop 本地代理')));
        socket.once('close', () => reject(new Error('Codex Desktop 本地代理已断开')));
        child.once('error', () => reject(new Error('找不到 Codex 本地代理；可设置 CLOUDTERMINAL_CODEX_PATH')));
      });
      const initialized = await this.call('initialize', { clientInfo: { name: 'cloudterminal', version: '0.1.0' }, capabilities: { experimentalApi: true, requestAttestation: false } });
      const userAgent = initialized && typeof initialized === 'object' ? (initialized as { userAgent?: unknown }).userAgent : undefined;
      const version = typeof userAgent === 'string' ? /\/(\d+)\.(\d+)\.(\d+)(?:\s|$)/.exec(userAgent) : null;
      // The required project/direct-input contract was validated against 0.160.
      // Unknown/older daemons remain read-only rather than assuming control.
      this.canControl = !!version && (Number(version[1]) > 0 || Number(version[2]) >= 160);
      socket.send(JSON.stringify({ method: 'initialized', params: {} }));
      this.ready = true;
    } catch (err) {
      this.close();
      throw err;
    }
  }

  async request(method: string, params: unknown): Promise<unknown> {
    await this.connect();
    return this.call(method, params);
  }

  private call(method: string, params: unknown): Promise<unknown> {
    const socket = this.socket;
    if (socket?.readyState !== WebSocket.OPEN) return Promise.reject(new Error('Codex Desktop 连接已断开'));
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex 请求超时（${method}）；请刷新后确认状态，勿重复提交`));
      }, this.opts.timeoutMs ?? 8000);
      this.pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }), (err) => {
        if (!err) return;
        clearTimeout(timer); this.pending.delete(id); reject(err);
      });
    });
  }

  respond(id: string | number, result: unknown): void { this.reply({ id, result }); }
  reject(id: string | number, message: string): void { this.reply({ id, error: { code: -32601, message } }); }
  private reply(frame: RpcFrame): void {
    if (this.socket?.readyState !== WebSocket.OPEN) throw new Error('Codex Desktop 连接已断开，请刷新');
    this.socket.send(JSON.stringify(frame));
  }

  private disconnected(socket: WebSocket): void {
    if (this.socket !== socket) return;
    this.close();
  }

  close(): void {
    const socket = this.socket;
    this.socket = undefined;
    this.ready = false;
    this.canControl = false;
    socket?.terminate();
    this.child?.kill();
    this.child = undefined;
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer); entry.reject(new Error('Codex Desktop 连接已断开，请刷新确认状态'));
    }
    this.pending.clear();
    this.onDisconnect();
  }
}
