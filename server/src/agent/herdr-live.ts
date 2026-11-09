// Turns Herdr socket events into push messages for paired phones.
//
// Two very different jobs live here, because Herdr exposes two very different
// kinds of signal (all measured in situ on 0.9.3; see the task design):
//
//   1. Structure — `tab_created`, `pane_closed`, `workspace_updated`, … are a
//      true edge-trigger (~41 ms) and the event payload already carries the
//      object. So the phone is patched directly, with no follow-up read.
//
//   2. Content — there is **no content-change edge**. `pane.updated` never fires
//      for output, `pane.output_matched` only fires on a match, and
//      `pane.output_changed` is not a subscription type at all. Content is
//      therefore read from the socket on a short tick (default 150 ms) for the
//      one selected pane. The tick reads over the socket, not by spawning the
//      CLI, so it costs a round trip rather than a process.
//
// Reads are coalesced per pane: while a read is in flight, further ticks only
// mark it dirty, and the read re-runs immediately when it completes. That
// bounds concurrency to one read per pane and makes the last state always win.
// Nothing here adds a debounce delay.

import { type Logger, silentLogger } from '../shared/log.ts';
import type { HerdrAgent, HerdrPane, HerdrTab, HerdrWorkspace } from '../shared/protocol.ts';
import type { HerdrBridge } from './herdr.ts';import { herdrSocketCall, type HerdrSocketClient, type HerdrSocketEvent } from './herdr-socket.ts';

/** What the agent pushes to clients. Mirrors the protocol message shapes. */
export type HerdrPushMessage =
  | {
      kind: 'herdr_structure';
      workspaceId?: string;
      workspaces?: HerdrWorkspace[];
      agents?: HerdrAgent[];
      tabs?: HerdrTab[];
      panes?: HerdrPane[];
    }
  | {
      kind: 'herdr_pane_output';
      paneId: string;
      revision: number;
      /** `ansi` for the snapshot stream; `text` only if the server ignored it. */
      format: string;
      reset: boolean;
      prefix: number;
      chunk: string;
    };

export type HerdrLivePushOptions = {
  bridge: HerdrBridge;
  socket: HerdrSocketClient;
  /** Resolves the socket path for content reads. */
  socketPath: () => Promise<string | undefined>;
  /**
   * Performs one pane read. Defaults to a socket `pane.read`.
   *
   * Injectable so the read contract (source, format, stale-read rejection) can be
   * asserted deterministically, without a network in the test.
   */
  readPane?: (paneId: string) => Promise<PaneReadResult | undefined>;
  /** Called for every message that should go out. */
  emit: (message: HerdrPushMessage) => void;
  logger?: Logger;
  /** Content read tick. Low by design: this is the latency floor. */
  contentIntervalMs?: number;
  /** Lines fetched per content read. */
  readLines?: number;
};

/** One pane read, as the live push consumes it. */
export type PaneReadResult = {
  text: string;
  revision: number;
  /** Wire format; `ansi` normally. */
  format: string;
};

/**
 * Params for the production pane read.
 *
 * Exported so the contract is asserted directly instead of through a socket:
 * `visible` is load-bearing (history sources make Herdr scroll the desktop pane),
 * and `format: ansi` with `strip_ansi: false` is what preserves the layout.
 */
export function paneReadParams(paneId: string, lines: number): Record<string, unknown> {
  return {
    pane_id: paneId,
    source: 'visible',
    format: 'ansi',
    strip_ansi: false,
    lines,
  };
}

/** The production reader: one short-lived socket connection per read. */
export async function readPaneVisible(
  socketPath: string,
  paneId: string,
  lines: number,
): Promise<PaneReadResult | undefined> {
  const reply = await herdrSocketCall(socketPath, 'pane.read', paneReadParams(paneId, lines));
  const read = (reply.result as {
    read?: { text?: unknown; revision?: unknown; format?: unknown };
  } | undefined)?.read;
  if (typeof read?.text !== 'string') return undefined;
  return {
    text: read.text,
    revision: typeof read.revision === 'number' ? read.revision : -1,
    format: typeof read.format === 'string' ? read.format : 'ansi',
  };
}

type PaneContentState = {
  /** Last text handed to clients; the prefix for the next delta. */
  last: string;
  /** Last revision the desktop reported. */
  revision: number;
  /** A read is in flight. */
  reading: boolean;
  /** A tick arrived while reading, so read again the moment it finishes. */
  dirty: boolean;
};

/**
 * One selection lifetime.
 *
 * A read is only allowed to publish if the state object it started against is
 * still the current one. Comparing pane ids is not enough: an A → B → A switch
 * would let the *first* A read land on the *new* A state, because both are
 * named A. Comparing the state identity catches every re-selection, including
 * one that returns to the same pane.
 */
type PaneSelection = {
  paneId: string;
  generation: number;
  state: PaneContentState;
};

export class HerdrLivePush {
  private readonly opts: HerdrLivePushOptions;
  private readonly log: Logger;
  private readonly content = new Map<string, PaneContentState>();
  private selected: string | undefined;
  /** Monotonic selection counter; a stale read is rejected by generation. */
  private generation = 0;
  private tick?: NodeJS.Timeout;
  private ticking = false;
  private closed = false;
  private structureTimer?: NodeJS.Timeout;
  private pendingStructure?: string;
  private unlisten?: () => void;

  constructor(opts: HerdrLivePushOptions) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
  }

  /** Starts listening to socket events and, if a pane is selected, reading it. */
  start(): void {
    this.unlisten = this.opts.socket.onEvent((event) => this.onEvent(event));
  }

  /**
   * Selects the pane whose output is streamed, or clears it.
   *
   * Validated by the caller (the wire rule lives in herdr.ts). Switching panes
   * drops the previous pane's buffered text so a delta is never computed across
   * two different screens.
   */
  selectPane(paneId: string | undefined): void {
    if (this.selected === paneId) return;
    // Every selection change (including A → B → A returning to the same id)
    // starts a new generation, so in-flight reads for the previous selection can
    // be recognised as stale no matter which pane they were for.
    this.generation += 1;
    const previous = this.selected;
    this.selected = paneId;
    if (previous) this.content.delete(previous);
    if (!paneId) {
      this.stopTicking();
      return;
    }
    this.content.delete(paneId);
    this.startTicking();
    // Read at once rather than waiting a full interval for the first frame.
    void this.readSelected();
  }

  /** The pane currently streamed, if any. */
  get selectedPane(): string | undefined {
    return this.selected;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.stopTicking();
    if (this.structureTimer) {
      clearTimeout(this.structureTimer);
      this.structureTimer = undefined;
    }
    this.unlisten?.();
    this.unlisten = undefined;
  }

  // -- events --------------------------------------------------------------

  private onEvent(event: HerdrSocketEvent): void {
    if (this.closed) return;
    switch (event.event) {
      // Structure: distinguish which listing the payload affects.
      case 'workspace_created':
      case 'workspace_updated':
      case 'workspace_closed':
      case 'workspace_renamed':
      case 'workspace_focused':
      case 'workspace_moved':
        this.scheduleStructure('workspaces');
        return;
      case 'tab_created':
      case 'tab_closed':
      case 'tab_renamed':
      case 'tab_moved':
      case 'tab_focused': {
        const workspaceId = workspaceOf(event.data, 'tab');
        this.scheduleStructure(workspaceId ? `tabs:${workspaceId}` : 'workspaces');
        return;
      }
      case 'pane_created':
      case 'pane_closed':
      case 'pane_moved':
      case 'pane_focused':
      case 'pane_exited':
      case 'pane_updated': {
        const workspaceId = workspaceOf(event.data, 'pane');
        this.scheduleStructure(workspaceId ? `panes:${workspaceId}` : 'workspaces');
        return;
      }
      case 'pane_agent_status_changed':
        this.scheduleStructure('agents');
        return;
      default:
        // Unknown/new event kinds are ignored rather than guessed at.
        return;
    }
  }

  /**
   * Coalesces a burst of structure events into one listing read.
   *
   * A single desktop action (a split) emits several events — the same scope is
   * fetched once. Scheduled with a zero-delay timer, not a debounce: it only
   * collapses events already in the same task/microtask flush, adding no
   * perceptible delay.
   */
  private scheduleStructure(scope: string): void {
    this.pendingStructure = mergeScope(this.pendingStructure, scope);
    if (this.structureTimer) return;
    this.structureTimer = setTimeout(() => {
      this.structureTimer = undefined;
      const pending = this.pendingStructure;
      this.pendingStructure = undefined;
      if (pending) void this.emitStructure(pending);
    }, 0);
    this.structureTimer.unref?.();
  }

  private async emitStructure(scope: string): Promise<void> {
    try {
      const parts = scope.split('|');
      const wantsWorkspaces = parts.includes('workspaces');
      const wantsAgents = parts.includes('agents');
      const workspaceIds = new Set<string>();
      for (const part of parts) {
        const [, id] = part.split(':');
        if (id) workspaceIds.add(id);
      }

      // One message per scope kind, merging what can be merged. A burst from a
      // single desktop action therefore arrives as at most two pushes.
      if (wantsWorkspaces || (!wantsAgents && workspaceIds.size === 0)) {
        this.opts.emit({ kind: 'herdr_structure', workspaces: await this.opts.bridge.workspaces() });
        return;
      }
      if (wantsAgents && workspaceIds.size === 0) {
        this.opts.emit({ kind: 'herdr_structure', agents: await this.opts.bridge.agents() });
        return;
      }

      const wantsTabs = parts.some((p) => p.startsWith('tabs:'));
      const wantsPanes = parts.some((p) => p.startsWith('panes:'));
      for (const workspaceId of workspaceIds) {
        const [tabs, panes] = await Promise.all([
          wantsTabs ? this.opts.bridge.tabs(workspaceId) : undefined,
          wantsPanes ? this.opts.bridge.panes(workspaceId) : undefined,
        ]);
        this.opts.emit({
          kind: 'herdr_structure',
          workspaceId,
          ...(tabs ? { tabs } : {}),
          ...(panes ? { panes } : {}),
        });
      }
      if (wantsAgents) {
        this.opts.emit({ kind: 'herdr_structure', agents: await this.opts.bridge.agents() });
      }
      // A tab/pane change also moves the per-workspace counts that the sidebar
      // and the workspace tile render, so refresh the list with it.
      this.opts.emit({ kind: 'herdr_structure', workspaces: await this.opts.bridge.workspaces() });
    } catch (err) {
      // A structure read failing (pane vanished mid-flight) must not kill the
      // stream; the next event or the app's fallback refresh corrects it.
      this.log.warn('herdr structure push failed', { scope, error: describe(err) });
    }
  }

  // -- content -------------------------------------------------------------

  private startTicking(): void {
    if (this.tick || this.closed) return;
    const interval = this.opts.contentIntervalMs ?? 150;
    this.tick = setInterval(() => {
      if (!this.closed) void this.readSelected();
    }, interval);
    this.tick.unref?.();
  }

  private stopTicking(): void {
    if (!this.tick) return;
    clearInterval(this.tick);
    this.tick = undefined;
  }

  /**
   * Reads the selected pane once, coalescing with an in-flight read.
   *
   * Called by every tick and by the pane selection itself. If a read is already
   * running, the tick only marks it dirty: the running read re-runs the moment
   * it finishes, so the newest screen is always the one pushed and the desktop is
   * never hit with overlapping reads.
   */
  private async readSelected(): Promise<void> {
    const paneId = this.selected;
    if (!paneId || this.closed) return;
    const state = this.content.get(paneId) ?? { last: '', revision: -1, reading: false, dirty: false };
    this.content.set(paneId, state);
    if (state.reading) {
      state.dirty = true;
      return;
    }
    state.reading = true;
    const generation = this.generation;
    try {
      const path = await this.opts.socketPath();
      if (!path) return;
      const read = await (this.opts.readPane
        ? this.opts.readPane(paneId)
        : readPaneVisible(path, paneId, this.opts.readLines ?? 200));
      if (!read) return;
      const { text, revision, format } = read;
      // A stale read must not publish: this fires when the pane was switched
      // while the read was in flight (A → B → A included), where `selected` alone
      // cannot tell the two A selections apart.
      if (this.generation !== generation || this.content.get(paneId) !== state) return;
      this.pushContent(paneId, state, text, revision, format);
    } catch (err) {
      // A transient read failure (pane closed, server busy) is not fatal.
      this.log.warn('herdr pane read failed', { paneId, error: describe(err) });
    } finally {
      state.reading = false;
      // Only the still-current selection continues; a switch must not revive the
      // old one with a stale read.
      if (state.dirty && this.generation === generation && this.content.get(paneId) === state && !this.closed) {
        state.dirty = false;
        void this.readSelected();
      }
    }
  }

  /** Emits the smallest message that turns [previous] into [text]. */
  private pushContent(
    paneId: string,
    state: PaneContentState,
    text: string,
    revision: number,
    format: string,
  ): void {
    const delta = buildDelta(state.last, text);
    if (!delta) {
      // Identical screen: stay silent. This is what keeps a 150 ms tick from
      // being a 6.7 msg/s stream of duplicates.
      state.revision = revision;
      return;
    }
    this.opts.emit({ kind: 'herdr_pane_output', paneId, revision, format, ...delta });
    state.last = text;
    state.revision = revision;
  }
}

/**
 * The smallest message that turns [previous] into [next], or undefined when they
 * are equal.
 *
 * A screen that only grew (command output) is the hot path and becomes a prefix
 * plus a suffix. Anything else is a repaint or a jump, and is sent whole: a
 * general diff would cost more than the screen it saves, and a wrong splice is
 * far worse than a full frame.
 */
export function buildDelta(
  previous: string,
  next: string,
): { reset: boolean; prefix: number; chunk: string } | undefined {
  if (previous === next) return undefined;
  if (previous.length > 0 && next.startsWith(previous)) {
    return { reset: false, prefix: previous.length, chunk: next.slice(previous.length) };
  }
  return { reset: true, prefix: 0, chunk: next };
}

/** Reads `data.tab.workspace_id` / `data.pane.workspace_id` out of an event. */
function workspaceOf(data: Record<string, unknown>, key: 'tab' | 'pane'): string | undefined {
  const nested = data[key];
  if (nested && typeof nested === 'object') {
    const id = (nested as { workspace_id?: unknown }).workspace_id;
    if (typeof id === 'string' && id) return id;
  }
  const direct = data.workspace_id;
  return typeof direct === 'string' && direct ? direct : undefined;
}

/**
 * Merges a new change scope into the one already pending.
 *
 * `workspaces` wins over a narrower scope (it subsumes both), and two different
 * workspaces keep both so neither is dropped.
 */
export function mergeScope(current: string | undefined, next: string): string {
  if (!current) return next;
  if (current === next) return current;
  if (current === 'workspaces' || next === 'workspaces') return 'workspaces';
  return `${current}|${next}`;
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
