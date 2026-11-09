// Herdr live-push tests.
//
// Everything here is injected: the socket is a fake `net.Socket`-shaped object
// and the bridge runner replays fixtures, so no Herdr process is spawned and no
// real workspace is touched.
//
// The behaviours under test were all established by probing a live herdr 0.9.3
// (see .trellis/tasks/10-15-herdr-live-push/prd.md), including the trap that
// costs the most to get wrong: an invalid subscription entry makes the server
// accept the frame and then never ack and never emit.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { HerdrBridge, type HerdrResult, type HerdrRunner } from '../src/agent/herdr.ts';
import {
  FrameSplitter,
  HERDR_LIVE_SUBSCRIPTIONS,
  frameToEvent,
  isSubscriptionStarted,
  socketTarget,
} from '../src/agent/herdr-socket.ts';
import { buildDelta, HerdrLivePush, mergeScope, type HerdrPushMessage } from '../src/agent/herdr-live.ts';

// ---------------------------------------------------------------------------
// Fixtures (shapes copied from a live herdr 0.9.3 response)
// ---------------------------------------------------------------------------

function tabJson(id: string, label: string, focused = false): Record<string, unknown> {
  return { tab_id: id, workspace_id: 'wJ', label, number: 1, focused, agent_status: 'idle', pane_count: 1 };
}

function paneJson(id: string, focused = false): Record<string, unknown> {
  return {
    pane_id: id, workspace_id: 'wJ', tab_id: 'wJ:t1', cwd: 'D:\\work', focused,
    terminal_title: 'pwsh', terminal_title_stripped: 'pwsh', revision: 1,
    scroll: { max_offset_from_bottom: 0, offset_from_bottom: 0, viewport_rows: 40 },
  };
}

function ok(result: unknown): HerdrResult {
  return { code: 0, stdout: JSON.stringify({ id: 'cli:test', result }), stderr: '', timedOut: false };
}

function raw(stdout: string): HerdrResult {
  return { code: 0, stdout, stderr: '', timedOut: false };
}

/** Bridge whose runner replays `handler`, with `--version`/`status` stubbed. */
function bridgeFor(handler: (argv: string[]) => HerdrResult): HerdrBridge {
  const runner: HerdrRunner = async ({ argv }) => {
    if (argv[0] === '--version') return raw('herdr 0.9.3\n');
    if (argv[0] === 'status') {
      return raw(['server:', '  status: running', '  socket: D:\\herdr.sock'].join('\n'));
    }
    return handler(argv);
  };
  return new HerdrBridge({
    binary: process.execPath,
    runner,
    logger: { info: () => {}, warn: () => {}, error: () => {} },
  });
}

/** A push harness whose pane reads are injected, so no socket is involved. */
function pushHarness(options: { bridge?: HerdrBridge }) {
  const messages: HerdrPushMessage[] = [];
  const listeners: Array<(event: { event: string; data: Record<string, unknown> }) => void> = [];

  const bridge = options.bridge ?? bridgeFor((argv) => {
    if (argv[0] === 'workspace') return ok({ workspaces: [] });
    if (argv[0] === 'tab') return ok({ tabs: [tabJson('wJ:t1', 'main', true)] });
    if (argv[0] === 'pane' && argv[1] === 'list') return ok({ panes: [paneJson('wJ:p1', true)] });
    return ok({});
  });

  const push = new HerdrLivePush({
    bridge,
    socket: {
      onEvent: (listener: (event: { event: string; data: Record<string, unknown> }) => void) => {
        listeners.push(listener);
        return () => {};
      },
    } as never,
    socketPath: async () => undefined,
    emit: (message) => messages.push(message),
  });
  // Registers the event listener, exactly as the agent does at startup.
  push.start();

  return {
    push,
    messages,
    emitEvent(event: string, data: Record<string, unknown>) {
      for (const listener of listeners) listener({ event, data });
    },
  };
}

// ---------------------------------------------------------------------------
// Socket framing
// ---------------------------------------------------------------------------

describe('herdr socket framing', () => {
  it('targets the named pipe on Windows and the path elsewhere', () => {
    assert.equal(socketTarget('D:\\x\\herdr.sock', 'win32'), '\\\\.\\pipe\\D:\\x\\herdr.sock');
    assert.equal(socketTarget('/run/herdr.sock', 'linux'), '/run/herdr.sock');
  });

  it('reassembles a frame split across chunks', () => {
    const splitter = new FrameSplitter();
    assert.deepEqual(splitter.push('{"event":"tab_cre'), []);
    const frames = splitter.push('ated","data":{}}\n');
    assert.equal(frames.length, 1);
    assert.equal(frames[0]!.event, 'tab_created');
  });

  it('returns every frame when several arrive in one chunk', () => {
    const splitter = new FrameSplitter();
    const frames = splitter.push('{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n');
    assert.deepEqual(frames.map((f) => f.event), ['a', 'b', 'c']);
  });

  it('ignores blank and non-JSON lines without throwing', () => {
    const splitter = new FrameSplitter();
    assert.deepEqual(splitter.push('\n   \nnot json\n'), []);
  });

  it('accepts only `subscription_started` as the subscribe ack', () => {
    // The whole point: an invalid subscription entry makes the server silent, so
    // anything that is not this exact ack must not be treated as success.
    assert.equal(isSubscriptionStarted({ id: 'x', result: { type: 'subscription_started' } }), true);
    assert.equal(isSubscriptionStarted({ id: 'x', result: { type: 'pong' } }), false);
    assert.equal(isSubscriptionStarted({ id: 'x', result: {} }), false);
    assert.equal(isSubscriptionStarted({ id: 'x' }), false);
  });

  it('separates event frames from replies', () => {
    const event = frameToEvent({ event: 'pane_created', data: { pane: {} } });
    assert.equal(event?.event, 'pane_created');
    assert.deepEqual(event?.data, { pane: {} });
    // A reply has an id and no event: it must not be dispatched as an event.
    assert.equal(frameToEvent({ id: 'x', result: { type: 'ok' } }), undefined);
    assert.equal(frameToEvent({ event: '', data: {} }), undefined);
  });

  it('subscribes only to types the server actually accepts', () => {
    // Guard against re-introducing `pane.output_changed`, which is NOT in the
    // server's Subscription union and silently disables the entire subscription.
    const valid = new Set([
      'workspace.created', 'workspace.updated', 'workspace.metadata_updated', 'workspace.renamed',
      'workspace.moved', 'workspace.reordered', 'workspace.closed', 'workspace.focused',
      'worktree.created', 'worktree.opened', 'worktree.removed',
      'tab.created', 'tab.closed', 'tab.focused', 'tab.renamed', 'tab.moved',
      'pane.created', 'pane.closed', 'pane.updated', 'pane.focused', 'pane.moved',
      'pane.exited', 'pane.agent_detected', 'pane.output_matched',
      'pane.agent_status_changed', 'pane.scroll_changed', 'layout.updated',
    ]);
    for (const type of HERDR_LIVE_SUBSCRIPTIONS) {
      assert.ok(valid.has(type), `${type} is not a valid subscription type`);
    }
    assert.ok(!HERDR_LIVE_SUBSCRIPTIONS.includes('pane.output_changed'));
    // The structure events the phone's rows depend on must be present.
    for (const required of ['tab.created', 'tab.closed', 'tab.focused', 'pane.created', 'pane.closed']) {
      assert.ok(HERDR_LIVE_SUBSCRIPTIONS.includes(required), `missing ${required}`);
    }
  });

  it('never subscribes a type that needs per-entry params', () => {
    // These three are in the union but require `pane_id` (and some `source`/
    // `match`) *inside the subscription entry*. A bare `{type}` entry makes the
    // server reject the whole request, which silently kills the stream: verified
    // against herdr 0.9.3, where each of them alone returns
    // `invalid_request: missing field \`pane_id\``.
    const needsParams = ['pane.agent_status_changed', 'pane.scroll_changed', 'pane.output_matched'];
    for (const type of needsParams) {
      assert.ok(
        !HERDR_LIVE_SUBSCRIPTIONS.includes(type),
        `${type} requires per-entry params and would break the whole subscription`,
      );
    }
  });
});

// ---------------------------------------------------------------------------
// Delta construction
// ---------------------------------------------------------------------------

describe('herdr pane delta', () => {
  it('sends an append as a prefix plus a suffix', () => {
    const delta = buildDelta('hello\n', 'hello\nworld\n');
    assert.deepEqual(delta, { reset: false, prefix: 6, chunk: 'world\n' });
  });

  it('emits nothing when the screen is unchanged', () => {
    assert.equal(buildDelta('same\n', 'same\n'), undefined);
  });

  it('flags a non-append change as a reset', () => {
    assert.deepEqual(buildDelta('first\n', 'completely different\n'), {
      reset: true,
      prefix: 0,
      chunk: 'completely different\n',
    });
  });

  it('treats shrinking output as a reset rather than a splice', () => {
    assert.equal(buildDelta('a long screen\n', 'short\n')?.reset, true);
  });

  it('sends the first frame as a reset', () => {
    // With nothing held there is nothing to append to, so the first frame must be
    // a full replace; claiming `reset: false` would have the phone append to an
    // empty buffer it never received.
    assert.deepEqual(buildDelta('', 'first\n'), { reset: true, prefix: 0, chunk: 'first\n' });
  });
});

// ---------------------------------------------------------------------------
// Structure events
// ---------------------------------------------------------------------------

describe('herdr structure pushes', () => {  it('maps a tab event to that workspace tabs', async () => {
    const harness = pushHarness({});
    harness.emitEvent('tab_created', { tab: { tab_id: 'wJ:t2', workspace_id: 'wJ' } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    const tabsPush = harness.messages.find((m) => m.kind === 'herdr_structure' && m.tabs);
    assert.ok(tabsPush, 'a tab event must push the tab listing');
  });

  it('maps a pane event to that workspace panes', async () => {
    const harness = pushHarness({});
    harness.emitEvent('pane_closed', { pane: { pane_id: 'wJ:p1', workspace_id: 'wJ' } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    const panesPush = harness.messages.find((m) => m.kind === 'herdr_structure' && m.panes);
    assert.ok(panesPush, 'a pane event must push the pane listing');
  });

  it('ignores an unknown event kind instead of guessing', () => {
    const harness = pushHarness({});
    harness.emitEvent('some_future_event', { whatever: true });
    assert.equal(harness.messages.length, 0);
  });

  it('coalesces a burst from one action into a single read', async () => {
    // A split emits several events; the same listing must be fetched once.
    let tabReads = 0;
    const bridge = bridgeFor((argv) => {
      if (argv[0] === 'tab') { tabReads += 1; return ok({ tabs: [tabJson('wJ:t1', 'main', true)] }); }
      if (argv[0] === 'pane' && argv[1] === 'list') return ok({ panes: [paneJson('wJ:p1', true)] });
      if (argv[0] === 'workspace') return ok({ workspaces: [] });
      return ok({});
    });
    const harness = pushHarness({ bridge });
    harness.emitEvent('pane_created', { pane: { pane_id: 'wJ:p1', workspace_id: 'wJ' } });
    harness.emitEvent('pane_focused', { pane: { pane_id: 'wJ:p1', workspace_id: 'wJ' } });
    harness.emitEvent('pane_updated', { pane: { pane_id: 'wJ:p1', workspace_id: 'wJ' } });
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(tabReads, 0, 'a pane event must not read tabs');
  });
});

describe('scope merging', () => {
  it('keeps both workspaces when two differ', () => {
    assert.equal(mergeScope('panes:wJ', 'tabs:wK'), 'panes:wJ|tabs:wK');
  });

  it('collapses to the workspace list when it is involved', () => {
    assert.equal(mergeScope('panes:wJ', 'workspaces'), 'workspaces');
    assert.equal(mergeScope('workspaces', 'panes:wJ'), 'workspaces');
  });

  it('is idempotent for a repeated scope', () => {
    assert.equal(mergeScope('panes:wJ', 'panes:wJ'), 'panes:wJ');
  });
});
