// Outbound connection from the agent to the relay: hello/auth, message
// routing into AgentCore, pairing codes, heartbeat watchdog and reconnect.

import { randomInt } from 'node:crypto';
import { WebSocket } from 'ws';

import { sha256Hex } from '../shared/crypto.ts';
import { type Logger, silentLogger } from '../shared/log.ts';
import {
  MAX_FRAME_BYTES,
  PAIR_CODE_ALPHABET,
  PAIR_CODE_LENGTH,
  PROTOCOL_VERSION,
  type AgentMessage,
  type ClientMessage,
} from '../shared/protocol.ts';
import type { AgentCore } from './core.ts';

export type RelayLinkOptions = {
  url: string;
  agentId: string;
  secret: string;
  relayKey?: string;
  name: string;
  core: AgentCore;
  logger?: Logger;
  onOnline?: () => void;
  onOffline?: (reason: string) => void;
  onPaired?: () => void;
  /** Relay pings every 30 s; treat the link as dead after this much silence. */
  watchdogMs?: number;
};

export type PairCode = { code: string; display: string; expiresAt: number };

export function generatePairCode(): string {
  let code = '';
  for (let i = 0; i < PAIR_CODE_LENGTH; i++) code += PAIR_CODE_ALPHABET[randomInt(PAIR_CODE_ALPHABET.length)];
  return code;
}

export function formatPairCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

export class RelayLink {
  private readonly opts: RelayLinkOptions;
  private readonly log: Logger;
  private ws: WebSocket | null = null;
  private online = false;
  private stopped = false;
  private attempt = 0;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private watchdog: NodeJS.Timeout | null = null;
  private pairWaiters: Array<{ resolve(c: PairCode): void; reject(e: Error): void }> = [];

  constructor(opts: RelayLinkOptions) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
    opts.core.setEmitter((msg, to) => this.emit(msg, to));
  }

  get isOnline(): boolean {
    return this.online;
  }

  start(): void {
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.watchdog) clearTimeout(this.watchdog);
    this.ws?.close(1000, 'agent shutting down');
    this.ws = null;
  }

  /** Register a fresh one-time pairing code with the relay. */
  requestPairCode(ttlMs = 10 * 60_000): Promise<PairCode> {
    if (!this.online || !this.ws) return Promise.reject(new Error('not connected to relay'));
    const code = generatePairCode();
    this.ws.send(JSON.stringify({ t: 'pair_code', code, ttlMs }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('relay did not confirm the pairing code')), 10_000);
      this.pairWaiters.push({
        resolve: (c) => (clearTimeout(timer), resolve(c)),
        reject: (e) => (clearTimeout(timer), reject(e)),
      });
    });
  }

  private emit(msg: AgentMessage, to?: string): void {
    if (!this.online || this.ws?.readyState !== WebSocket.OPEN) return; // clients resync on reconnect
    const frame = JSON.stringify(to ? { t: 'msg', to, data: msg } : { t: 'msg', data: msg });
    if (frame.length > MAX_FRAME_BYTES) {
      this.log.warn('dropping oversized frame', { kind: msg.kind, bytes: frame.length });
      if ('id' in msg && to) this.emit({ kind: 'error', id: msg.id, message: 'response too large' }, to);
      return;
    }
    this.ws.send(frame);
  }

  private connect(): void {
    if (this.stopped) return;
    const ws = new WebSocket(this.opts.url, { maxPayload: MAX_FRAME_BYTES, handshakeTimeout: 15_000 });
    this.ws = ws;

    ws.on('open', () => {
      ws.send(
        JSON.stringify({
          t: 'hello',
          role: 'agent',
          agentId: this.opts.agentId,
          secretHash: sha256Hex(this.opts.secret),
          relayKey: this.opts.relayKey,
          name: this.opts.name,
          v: PROTOCOL_VERSION,
        }),
      );
      this.armWatchdog();
    });
    ws.on('ping', () => this.armWatchdog());
    ws.on('message', (raw) => {
      this.armWatchdog();
      let frame: any;
      try {
        frame = JSON.parse(raw.toString());
      } catch {
        return;
      }
      this.onFrame(frame);
    });
    ws.on('error', (err) => this.log.warn('relay socket error', { err: err.message }));
    ws.on('close', (code, reason) => {
      if (this.ws !== ws) return;
      this.ws = null;
      const wasOnline = this.online;
      this.online = false;
      if (this.watchdog) clearTimeout(this.watchdog);
      for (const w of this.pairWaiters.splice(0)) w.reject(new Error('disconnected'));
      const why = reason.toString() || String(code);
      if (wasOnline) this.opts.onOffline?.(why);
      if (code === 4000) {
        this.log.error('another agent with the same identity connected; not reconnecting');
        this.stopped = true;
        return;
      }
      this.scheduleReconnect(why);
    });
  }

  private onFrame(frame: any): void {
    switch (frame.t) {
      case 'hello_ok':
        this.online = true;
        this.attempt = 0;
        this.log.info('connected to relay', { url: this.opts.url });
        this.opts.onOnline?.();
        return;
      case 'error':
        this.log.error('relay error', { code: frame.code, message: frame.message });
        if (frame.code === 'bad_request') for (const w of this.pairWaiters.splice(0)) w.reject(new Error(frame.message));
        return;
      case 'client_joined':
        this.log.info('client connected', { clientId: frame.clientId });
        return;
      case 'client_left':
        this.opts.core.clientLeft(frame.clientId);
        this.log.info('client disconnected', { clientId: frame.clientId });
        return;
      case 'msg':
        if (typeof frame.clientId === 'string' && frame.data && typeof frame.data === 'object') {
          void this.opts.core.handle(frame.clientId, frame.data as ClientMessage);
        }
        return;
      case 'pair_code_ok': {
        const w = this.pairWaiters.shift();
        w?.resolve({ code: frame.code, display: formatPairCode(frame.code), expiresAt: frame.expiresAt });
        return;
      }
      case 'pair_request':
        this.ws?.send(JSON.stringify({ t: 'pair_response', pairId: frame.pairId, secret: this.opts.secret }));
        this.log.info('paired a new device');
        this.opts.onPaired?.();
        return;
    }
  }

  private armWatchdog(): void {
    if (this.watchdog) clearTimeout(this.watchdog);
    this.watchdog = setTimeout(() => {
      this.log.warn('relay went silent, reconnecting');
      this.ws?.terminate();
    }, this.opts.watchdogMs ?? 75_000);
  }

  private scheduleReconnect(reason: string): void {
    if (this.stopped) return;
    const delay = Math.min(30_000, 1000 * 2 ** this.attempt) * (0.75 + Math.random() * 0.5);
    this.attempt = Math.min(this.attempt + 1, 6);
    this.log.warn('relay disconnected, retrying', { reason, inMs: Math.round(delay) });
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }
}
