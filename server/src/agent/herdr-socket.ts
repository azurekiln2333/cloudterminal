// Herdr server-socket client.
//
// The CLI is request/response only: it has no event command, so anything that
// wants to *react* to a desktop change has to poll it. The server socket is the
// only surface that produces edges, and it is fast — measured in situ on herdr
// 0.9.3 (protocol 22, Windows, named pipe):
//
//   endpoint : `herdr status --json` → server.socket (a path). On Windows the
//              path is also exposed as the pipe `\\.\pipe\<path>`.
//   framing  : newline-delimited JSON, `{id, method, params}` →
//              `{id, result}` | `{id, error}`. Event frames carry no `id`.
//   subscribe: `events.subscribe` replies `{result:{type:'subscription_started'}}`
//              and then emits `{event, data}` frames. **The ack only happens
//              when every subscription entry is valid**: one unknown type makes
//              the server accept the frame and then stay silent forever. So
//              "no ack" is treated as a failure, never as "quiet".
//   names    : subscription types are dotted (`tab.created`); the delivered
//              event name is underscored (`tab_created`).
//   reads    : `pane.read` answers and then closes that connection, so reads use
//              their own short-lived connection and never the event one.
//
// This module owns transport only: connection, framing, ack detection,
// re-subscription and dispatch. What to do with an event lives in herdr-live.ts.

import { connect, type Socket } from 'node:net';
import { StringDecoder } from 'node:string_decoder';

import { type Logger, silentLogger } from '../shared/log.ts';

/** One frame from the server. `id` is absent on unsolicited event frames. */
export type HerdrSocketFrame = {
  id?: string;
  result?: unknown;
  error?: { code?: string; message?: string };
  /** Event frames: `event` names the kind (`tab_created`) and `data` carries it. */
  event?: string;
  data?: unknown;
};

/** Keeps Herdr's error code available to the bridge without parsing prose. */
export class HerdrSocketError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = 'HerdrSocketError';
    this.code = code;
  }
}

export type HerdrSocketEvent = {
  /** Underscore form, exactly as delivered (e.g. `tab_created`). */
  event: string;
  data: Record<string, unknown>;
};

export type HerdrSocketOptions = {
  /** Resolves the socket path, usually from `herdr status --json`. */
  socketPath: () => Promise<string | undefined>;
  logger?: Logger;
  /** Reconnect backoff cap. */
  maxBackoffMs?: number;
  /** How long to wait for the `subscription_started` ack. */
  subscribeTimeoutMs?: number;
};

/**
 * The connect target for a socket path.
 *
 * Windows exposes the socket both as a file and as a named pipe; `net.connect`
 * only accepts the pipe form. POSIX uses the path directly. Split out as a pure
 * function so both branches are testable without a real server.
 */
export function socketTarget(socketPath: string, platform: NodeJS.Platform = process.platform): string {
  if (platform === 'win32') return `\\\\.\\pipe\\${socketPath}`;
  return socketPath;
}

/**
 * Splits a byte stream into complete newline-delimited JSON frames.
 *
 * Kept separate from the socket so the partial-line and many-lines-per-chunk
 * cases are unit-tested directly rather than through timing.
 */
export class FrameSplitter {
  private buffer = '';
  private decoder = new StringDecoder('utf8');

  /** Feed a chunk and return every complete frame it completed. */
  push(chunk: string | Buffer): HerdrSocketFrame[] {
    this.buffer += typeof chunk === 'string' ? chunk : this.decoder.write(chunk);
    const frames: HerdrSocketFrame[] = [];
    let index = this.buffer.indexOf('\n');
    while (index >= 0) {
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      const parsed = parseFrame(line);
      if (parsed) frames.push(parsed);
      index = this.buffer.indexOf('\n');
    }
    return frames;
  }

  reset(): void {
    this.buffer = '';
    this.decoder = new StringDecoder('utf8');
  }
}

/** Parses one line; returns undefined for blank or non-JSON lines. */
export function parseFrame(line: string): HerdrSocketFrame | undefined {
  const text = line.trim();
  if (!text) return undefined;
  try {
    const value = JSON.parse(text) as unknown;
    return value && typeof value === 'object' ? (value as HerdrSocketFrame) : undefined;
  } catch {
    return undefined;
  }
}

/** Turns an event frame into a typed event, or undefined for a reply frame. */
export function frameToEvent(frame: HerdrSocketFrame): HerdrSocketEvent | undefined {
  if (typeof frame.event !== 'string' || !frame.event) return undefined;
  const data = frame.data && typeof frame.data === 'object' ? (frame.data as Record<string, unknown>) : {};
  return { event: frame.event, data };
}

/** True when [frame] is the reply that confirms a subscription. */
export function isSubscriptionStarted(frame: HerdrSocketFrame): boolean {
  const result = frame.result;
  return Boolean(result && typeof result === 'object' && (result as { type?: unknown }).type === 'subscription_started');
}

/**
 * A long-lived connection to the Herdr server socket, used for events.
 *
 * Lifecycle: `start()` connects, subscribes and waits for the ack, retrying
 * with capped exponential backoff until `close()`. Every reconnect
 * re-subscribes, because the server keeps no subscription across a connection.
 * A failure here is never user-visible: the feature stays silent and the app's
 * fallback refresh carries on.
 */
export class HerdrSocketClient {
  private readonly opts: HerdrSocketOptions;
  private readonly log: Logger;
  private socket?: Socket;
  private splitter = new FrameSplitter();
  private closed = false;
  private attempt = 0;
  private reconnect?: NodeJS.Timeout;
  private subscribed = false;
  private pending = new Map<string, { resolve: (frame: HerdrSocketFrame) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private nextId = 0;
  private listeners = new Set<(event: HerdrSocketEvent) => void>();
  /** Remembered from start() so a reconnect re-issues the same subscription. */
  private subscriptions: readonly string[] = [];

  constructor(opts: HerdrSocketOptions) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
  }

  /** Registers an event sink. Returns an unregister function. */
  onEvent(listener: (event: HerdrSocketEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** True once `subscription_started` has been received on the live socket. */
  get isSubscribed(): boolean {
    return this.subscribed;
  }

  /**
   * Connect, subscribe, and keep reconnecting.
   *
   * Never throws: a missing socket path or a refused connection is logged and
   * retried. The caller has no useful recovery action, and throwing would turn
   * an optional enhancement into a startup failure.
   */
  async start(subscriptions: readonly string[]): Promise<void> {
    if (this.closed) return;
    this.subscriptions = subscriptions;
    try {
      const path = await this.opts.socketPath();
      if (!path) {
        this.subscribed = false;
        // Nothing to retry against until a binary/socket appears; the caller
        // re-invokes start() when availability changes.
        this.log.info('herdr socket unavailable; live push disabled', {});
        return;
      }
      await this.open(path);
      await this.subscribeNow(subscriptions);
      this.subscribed = true;
      this.attempt = 0;
      this.log.info('herdr socket subscribed', { subscriptions: subscriptions.length });
    } catch (err) {
      // Includes the "accepted but never acked" case, which is the signature of
      // an invalid subscription entry.
      this.subscribed = false;
      this.log.warn('herdr socket unavailable', { error: describe(err) });
      this.teardown();
      this.scheduleReconnect();
    }
  }

  /** Stops reconnecting and closes the socket. Idempotent. */
  async close(): Promise<void> {
    this.closed = true;
    this.subscribed = false;
    this.teardown();
  }

  // -- internals -----------------------------------------------------------

  private id(): string {
    this.nextId += 1;
    // Never empty: the server rejects a frame whose `id` is missing.
    return `ct${this.nextId}`;
  }

  private async open(path: string): Promise<void> {
    const target = socketTarget(path);
    await new Promise<void>((resolve, reject) => {
      const socket = connect(target);
      socket.once('error', (err: Error) => {
        socket.removeAllListeners();
        reject(err);
      });
      socket.once('connect', () => {
        this.splitter.reset();
        this.socket = socket;
        socket.on('data', (data: Buffer) => this.onData(data));
        socket.on('error', (err: Error) => this.onDrop(err));
        socket.on('close', () => this.onDrop(new Error('herdr socket closed')));
        resolve();
      });
    });
  }

  /**
   * Writes the subscription and waits for `subscription_started`.
   *
   * A missing ack is the poison case: the server silently ignores an invalid
   * subscription type, so treating silence as success would leave the feature
   * permanently dead while looking healthy.
   */
  private async subscribeNow(subscriptions: readonly string[]): Promise<void> {
    if (!subscriptions.length) return;
    const id = this.id();
    const ack = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('herdr socket subscribe was not acknowledged'));
      }, this.opts.subscribeTimeoutMs ?? 3000);
      timer.unref?.();
      this.pending.set(id, {
        // Only `subscription_started` counts. Any other reply means the server
        // rejected or ignored the subscription, which must not look like success.
        resolve: (incoming) => {
          if (isSubscriptionStarted(incoming)) resolve();
          else reject(new Error(`herdr socket subscribe rejected: ${JSON.stringify(incoming.result ?? incoming.error)}`));
        },
        reject,
        timer,
      });
    });
    await this.write(frame(id, 'events.subscribe', { subscriptions: subscriptions.map((type) => ({ type })) }));
    await ack;
  }

  private onData(chunk: Buffer): void {
    for (const incoming of this.splitter.push(chunk)) {
      if (incoming.id) {
        this.settle(incoming);
        continue;
      }
      const event = frameToEvent(incoming);
      if (!event) continue;
      for (const listener of this.listeners) {
        try {
          listener(event);
        } catch (err) {
          // A misbehaving listener must not kill the connection.
          this.log.warn('herdr socket listener failed', { event: event.event, error: describe(err) });
        }
      }
    }
  }

  private settle(incoming: HerdrSocketFrame): void {
    const entry = this.pending.get(incoming.id!);
    if (!entry) return;
    clearTimeout(entry.timer);
    this.pending.delete(incoming.id!);
    if (incoming.error) entry.reject(new HerdrSocketError(incoming.error.message ?? incoming.error.code ?? 'herdr socket error', incoming.error.code));
    else entry.resolve(incoming);
  }

  private onDrop(error: Error): void {
    if (this.closed) return;
    this.subscribed = false;
    this.teardown();
    this.log.warn('herdr socket dropped', { error: describe(error) });
    this.scheduleReconnect();
  }

  /**
   * Reconnects with capped exponential backoff and jitter, re-subscribing.
   *
   * The server keeps no subscription across a reconnect, so every successful
   * reconnect must re-issue `events.subscribe` or the stream goes permanently
   * silent while the socket still looks open.
   */
  private scheduleReconnect(): void {
    if (this.closed || this.reconnect) return;
    const max = this.opts.maxBackoffMs ?? 30_000;
    const base = Math.min(max, 500 * 2 ** this.attempt);
    const delay = Math.round(base * (0.75 + Math.random() * 0.5));
    this.attempt = Math.min(this.attempt + 1, 6);
    const timer = setTimeout(() => {
      this.reconnect = undefined;
      void this.start(this.subscriptions);
    }, delay);
    timer.unref?.();
    this.reconnect = timer;
  }

  private teardown(): void {
    if (this.reconnect) {
      clearTimeout(this.reconnect);
      this.reconnect = undefined;
    }
    this.failPending(new Error('herdr socket closed'));
    const socket = this.socket;
    this.socket = undefined;
    if (socket) {
      socket.removeAllListeners();
      socket.on('error', () => {});
      socket.end();
      socket.destroy();
    }
  }

  private failPending(error: Error): void {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    this.pending.clear();
  }

  private write(raw: string): Promise<void> {
    const socket = this.socket;
    if (!socket || socket.destroyed) return Promise.reject(new Error('herdr socket is not connected'));
    return new Promise<void>((resolve, reject) => {
      socket.write(raw, (err) => (err ? reject(err) : resolve()));
    });
  }
}

function frame(id: string, method: string, params: Record<string, unknown>): string {
  return `${JSON.stringify({ id, method, params })}\n`;
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Opens a short-lived connection, runs one request, closes.
 *
 * Used for reads and raw terminal input. Herdr processes one initial request per
 * connection; an event subscription cannot accept later requests. A failed or
 * timed-out input may already have arrived, so this helper never retries it.
 */
export async function herdrSocketCall(
  socketPath: string,
  method: string,
  params: Record<string, unknown>,
  timeoutMs = 4000,
  platform: NodeJS.Platform = process.platform,
): Promise<HerdrSocketFrame> {
  return new Promise<HerdrSocketFrame>((resolve, reject) => {
    const socket = connect(socketTarget(socketPath, platform));
    const splitter = new FrameSplitter();
    let settled = false;
    const finish = (value: HerdrSocketFrame | Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.removeAllListeners();
      socket.on('error', () => {});
      socket.end();
      socket.destroy();
      if (value instanceof Error) reject(value);
      else resolve(value);
    };
    const timer = setTimeout(() => finish(new HerdrSocketError(`herdr socket ${method} timed out`, 'timeout')), timeoutMs);
    timer.unref?.();
    socket.once('error', (err: Error) => finish(err));
    const closed = () => finish(new HerdrSocketError(`herdr socket closed before ${method} replied`, 'connection_closed'));
    socket.once('end', closed);
    socket.once('close', closed);
    socket.once('connect', () => {
      socket.write(frame('ct1', method, params));
    });
    socket.on('data', (data: Buffer) => {
      for (const incoming of splitter.push(data)) {
        if (incoming.id !== 'ct1') continue;
        if (incoming.error) finish(new HerdrSocketError(incoming.error.message ?? incoming.error.code ?? 'herdr socket error', incoming.error.code));
        else finish(incoming);
      }
    });
  });
}

/**
 * Subscriptions the live push needs.
 *
 * Every entry must be a member of the server's `Subscription` union. One unknown
 * type makes `events.subscribe` silently never ack and never emit, so this list
 * is asserted in tests and deliberately excludes the non-existent
 * `pane.output_changed`.
 */
export const HERDR_LIVE_SUBSCRIPTIONS: readonly string[] = [
  // Structure edges: these carry the object, so the phone patches its caches
  // without any follow-up read. This is what makes the tab/pane rows live.
  'workspace.updated',
  'workspace.focused',
  'workspace.closed',
  'workspace.renamed',
  'tab.created',
  'tab.closed',
  'tab.focused',
  'tab.renamed',
  'tab.moved',
  'pane.created',
  'pane.closed',
  'pane.focused',
  'pane.moved',
  'pane.exited',
  'pane.updated',
  // Deliberately NOT subscribed here:
  //   pane.agent_status_changed, pane.scroll_changed, pane.output_matched
  // Each of those requires a `pane_id` (some also `source`/`match`) *inside the
  // subscription entry*, and a subscription entry that is missing a required
  // field makes the server reject the whole `events.subscribe` — which takes the
  // entire stream down with it (no ack, no events). Verified per type against
  // herdr 0.9.3: every entry above acks on its own, these three do not.
  //
  // Losing them is acceptable: agent status rides on `pane.updated` and the
  // structure pushes, and the app's fallback refresh is the correctness net.
  // Subscribing them per selected pane would also have to be redone on every
  // pane switch, which is exactly the kind of state the event stream is meant to
  // avoid holding.
];
