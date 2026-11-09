import { randomUUID } from 'node:crypto';
import type { SessionEvent, SessionInfo, SessionStatus } from '../shared/protocol.ts';
import type { ManagedSession, SessionListener } from './session.ts';
import type { PtyFactory, PtyHandle } from './pty.ts';

// JSON escaping can expand each control byte sixfold. This plus bounded event
// count keeps a complete replay comfortably below the relay's 4 MiB limit.
export const TERMINAL_REPLAY_BYTES = 256 * 1024;
export const TERMINAL_INPUT_BYTES = 64 * 1024;
export function checkGeometry(cols: number, rows: number): void {
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols < 2 || cols > 500 || rows < 1 || rows > 300) {
    throw new Error('终端尺寸无效（列 2–500，行 1–300）');
  }
}

export class TerminalSession implements ManagedSession {
  readonly id = randomUUID();
  readonly createdAt = Date.now();
  updatedAt = this.createdAt;
  readonly cwd: string;
  private cols: number;
  private rows: number;
  private closed = false;
  private closing?: Promise<void>;
  private seq = 0;
  private bytes = 0;
  private events: Array<{ event: SessionEvent; bytes: number; safe: boolean }> = [];
  private parser: 'ground' | 'esc' | 'csi' | 'string' | 'stringEsc' = 'ground';
  private readonly handle: PtyHandle;
  private readonly listener: SessionListener;
  private readonly local = new Set<(data: string) => void>();
  private disposables: Array<{ dispose(): void }> = [];

  constructor(factory: PtyFactory, opts: { cwd: string; cols?: number; rows?: number }, listener: SessionListener) {
    this.cwd = opts.cwd;
    this.cols = opts.cols ?? 80;
    this.rows = opts.rows ?? 24;
    checkGeometry(this.cols, this.rows);
    this.listener = listener;
    this.handle = factory({ cwd: this.cwd, cols: this.cols, rows: this.rows });
    this.disposables.push(this.handle.onData((data) => this.output(data)));
    this.disposables.push(this.handle.onExit(() => this.finish()));
  }
  get status(): SessionStatus { return this.closed ? 'closed' : 'running'; }
  info(): SessionInfo {
    return { id: this.id, kind: 'terminal', title: '终端', cwd: this.cwd, status: this.status,
      mode: 'default', cols: this.cols, rows: this.rows, createdAt: this.createdAt,
      updatedAt: this.updatedAt, costUsd: 0, pending: 0, lastSeq: this.seq };
  }
  eventsAfter(afterSeq: number): { events: SessionEvent[]; reset: boolean } {
    const first = this.events[0]?.event.seq ?? this.seq + 1;
    const reset = afterSeq > this.seq || afterSeq < first - 1;
    return { events: this.events.filter((e) => reset || e.event.seq > afterSeq).map((e) => e.event), reset };
  }
  write(data: string): void {
    if (this.closed) throw new Error('终端已结束');
    if (typeof data !== 'string' || Buffer.byteLength(data) > TERMINAL_INPUT_BYTES) throw new Error('终端输入过长或格式无效');
    this.handle.write(data);
  }
  resize(cols: number, rows: number): void {
    checkGeometry(cols, rows);
    if (this.closed) throw new Error('终端已结束');
    this.handle.resize(cols, rows);
    this.cols = cols; this.rows = rows;
    this.touch();
  }
  async interrupt(): Promise<void> { this.write('\x03'); }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    if (this.closed) return Promise.resolve();
    const killed = this.handle.kill();
    this.finish();
    return this.closing = Promise.resolve(killed);
  }
  /** Local attachment shares the exact stream with remote subscribers. */
  attach(callback: (data: string) => void): () => void {
    this.local.add(callback);
    for (const { event } of this.events) if (event.kind === 'terminal_output') callback(event.data);
    return () => { this.local.delete(callback); };
  }
  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    for (const d of this.disposables) d.dispose();
    this.disposables = [];
    this.local.clear();
    this.touch();
  }
  private touch(): void { this.updatedAt = Date.now(); this.listener.onState(this); }
  private output(data: string): void {
    if (this.closed) return;
    for (const callback of this.local) callback(data);
    // Split frames without deleting any bytes or splitting surrogate pairs.
    for (let offset = 0; offset < data.length;) {
      let end = Math.min(offset + 8192, data.length);
      const code = data.charCodeAt(end - 1);
      if (end < data.length && code >= 0xd800 && code <= 0xdbff) end--;
      const chunk = data.slice(offset, end);
      const safe = this.parser === 'ground';
      for (const char of chunk) this.scan(char);
      const event: SessionEvent = { kind: 'terminal_output', data: chunk, seq: ++this.seq, ts: Date.now() };
      const bytes = Buffer.byteLength(chunk);
      this.events.push({ event, bytes, safe }); this.bytes += bytes;
      while (this.bytes > TERMINAL_REPLAY_BYTES || this.events.length > 2000) this.bytes -= this.events.shift()!.bytes;
      // Never start a reset replay in the middle of an ANSI control sequence.
      while (this.events.length && !this.events[0]!.safe) this.bytes -= this.events.shift()!.bytes;
      this.listener.onEvent(this, event);
      offset = end;
    }
    this.touch();
  }
  private scan(char: string): void {
    if (this.parser === 'stringEsc') { this.parser = char === '\\' ? 'ground' : 'string'; return; }
    if (this.parser === 'string') {
      if (char === '\x07' || char === '\x9c') this.parser = 'ground';
      else if (char === '\x1b') this.parser = 'stringEsc';
      return;
    }
    if (char === '\x1b') { this.parser = 'esc'; return; }
    if (this.parser === 'esc') {
      if (char === '[') this.parser = 'csi';
      else if (']PX^_'.includes(char)) this.parser = 'string';
      else if (char >= '0' && char <= '~') this.parser = 'ground';
    } else if (this.parser === 'csi') {
      if (char >= '@' && char <= '~') this.parser = 'ground';
    } else if (char === '\x9b') this.parser = 'csi';
    else if ('\x90\x9d\x98\x9e\x9f'.includes(char)) this.parser = 'string';
  }
}
