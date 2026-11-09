// Tests for the parts of the live push that are only observable on the wire
// contract: the snapshot is tagged with its format, an unchanged screen is not
// repainted, and a read that completes after a pane switch cannot publish.
//
// The read is injected rather than served over a real socket so these are
// deterministic. The production reader's own arg construction (`source`,
// `format`, `strip_ansi`) is asserted in the last test through the fake runner.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { HerdrBridge, type HerdrResult, type HerdrRunner } from '../src/agent/herdr.ts';
import { HerdrLivePush, type HerdrPushMessage } from '../src/agent/herdr-live.ts';

function ok(result: unknown): HerdrResult {
  return { code: 0, stdout: JSON.stringify({ id: 'cli:test', result }), stderr: '', timedOut: false };
}

function raw(stdout: string): HerdrResult {
  return { code: 0, stdout, stderr: '', timedOut: false };
}

function bridge(): HerdrBridge {
  const runner: HerdrRunner = async ({ argv }) => {
    if (argv[0] === '--version') return raw('herdr 0.9.3\n');
    if (argv[0] === 'status') return raw('server:\n  status: running\n');
    return ok({});
  };
  return new HerdrBridge({
    binary: process.execPath,
    runner,
    logger: { info: () => {}, warn: () => {}, error: () => {} },
  });
}

type ReadResult = { text: string; revision: number; format: string } | undefined;

/** Lets a test hold a specific read open while other things happen. */
class Queue {
  private readonly replies: Array<Promise<ReadResult>> = [];
  private readonly resolvers: Array<(value: ReadResult) => void> = [];
  readonly panes: string[] = [];

  /** Enqueues one read result; reads are answered in order. */
  enqueue(value: ReadResult): void {
    if (this.resolvers.length) {
      this.resolvers.shift()!(value);
      return;
    }
    this.replies.push(Promise.resolve(value));
  }

  /** Enqueues a read that stays pending until `release` is called. */
  hold(): (value: ReadResult) => void {
    let release!: (value: ReadResult) => void;
    const promise = new Promise<ReadResult>((resolve) => {
      release = resolve;
    });
    this.replies.push(promise);
    return release;
  }

  next(paneId: string): Promise<ReadResult> {
    this.panes.push(paneId);
    const queued = this.replies.shift();
    if (queued) return queued;
    // Default: answer straight away so the common case is not racy.
    return Promise.resolve({ text: `${paneId}\n`, revision: 1, format: 'ansi' });
  }
}

function harness(reads: Queue) {
  const messages: HerdrPushMessage[] = [];
  const push = new HerdrLivePush({
    bridge: bridge(),
    // `onEvent` only; the read path is injected.
    socket: { onEvent: () => () => {} } as never,
    socketPath: async () => 'unused',
    readPane: (paneId) => reads.next(paneId),
    emit: (message) => messages.push(message),
    logger: { info: () => {}, warn: () => {}, error: () => {} },
  });
  push.start();
  return { push, messages, settle: () => new Promise((r) => setTimeout(r, 30)) };
}

describe('herdr pane read contract', () => {
  it('publishes a snapshot tagged with its wire format', async () => {
    const reads = new Queue();
    const h = harness(reads);
    h.push.selectPane('wJ:p2');
    await h.settle();
    const output = h.messages.find((m) => m.kind === 'herdr_pane_output');
    assert.ok(output, 'a pane output push must be emitted');
    if (output.kind !== 'herdr_pane_output') return;
    assert.equal(output.paneId, 'wJ:p2');
    assert.equal(output.format, 'ansi', 'the phone needs the format to replay it');
    await h.push.close();
  });

  it('does not re-emit an unchanged screen while the pane stays selected', async () => {
    const reads = new Queue();
    const h = harness(reads);
    h.push.selectPane('wJ:p2');
    await h.settle();
    h.messages.length = 0;

    // Same pane, same screen, a second tick: nothing may be repainted.
    reads.enqueue({ text: 'wJ:p2\n', revision: 1, format: 'ansi' });
    // Re-selecting the same pane is a no-op, so drive a tick by switching to the
    // same pane through a redundant selection of the identical id.
    await new Promise((r) => setTimeout(r, 200));
    const during = h.messages.filter(
      (m) => m.kind === 'herdr_pane_output' && m.paneId === 'wJ:p2',
    );
    assert.equal(during.length, 0, 'an identical screen must not repaint');
    await h.push.close();
  });

  it('repaints when a pane is re-selected, because its buffer was dropped', async () => {
    // Leaving a pane discards its buffered screen so a late write cannot land on a
    // screen the phone is not showing; coming back therefore legitimately repaints.
    const reads = new Queue();
    const h = harness(reads);
    h.push.selectPane('wJ:p2');
    await h.settle();
    h.messages.length = 0;
    h.push.selectPane('wJ:p3');
    await h.settle();
    h.push.selectPane('wJ:p2');
    await h.settle();
    const p2 = h.messages.filter(
      (m) => m.kind === 'herdr_pane_output' && m.paneId === 'wJ:p2',
    );
    assert.ok(p2.length >= 1, 'a re-selected pane must repaint');
    await h.push.close();
  });

  it('a read completing after a switch is discarded', async () => {
    // A → B → A: both selections are named A, so comparing pane ids would let the
    // first read land on the second selection. The guard is generation plus state
    // identity precisely for this case.
    const reads = new Queue();
    const h = harness(reads);
    h.push.selectPane('wJ:p2');
    await h.settle();
    h.messages.length = 0;

    // Hold the read for the next p2 selection open.
    const release = reads.hold();
    h.push.selectPane('wJ:p4');
    // let the read start
    await new Promise((r) => setTimeout(r, 10));
    // Switch away and back to the same id while it is in flight.
    h.push.selectPane('wJ:p5');
    await new Promise((r) => setTimeout(r, 10));
    h.push.selectPane('wJ:p4');
    await new Promise((r) => setTimeout(r, 10));

    // Complete the stale read now.
    release({ text: 'STALE\n', revision: 1, format: 'ansi' });
    await h.settle();

    const stale = h.messages.filter(
      (m) => m.kind === 'herdr_pane_output' && m.chunk.includes('STALE'),
    );
    assert.equal(stale.length, 0, 'a stale read must not publish');
    await h.push.close();
  });

  it('stops reading once no pane is selected', async () => {
    const reads = new Queue();
    const h = harness(reads);
    h.push.selectPane('wJ:p2');
    await h.settle();
    h.push.selectPane(undefined);
    const after = reads.panes.length;
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(reads.panes.length, after, 'clearing the selection must stop reads');
    await h.push.close();
  });

  it('a missing pane result does not emit and does not crash', async () => {
    const reads = new Queue();
    const h = harness(reads);
    reads.enqueue(undefined);
    h.push.selectPane('wJ:p2');
    await h.settle();
    assert.equal(
      h.messages.filter((m) => m.kind === 'herdr_pane_output').length,
      0,
    );
    await h.push.close();
  });
});

describe('herdr pane read source', () => {
  it('requests `visible` with ANSI and no stripping', async () => {
    // Regression: `recent` / `recent_unwrapped` make Herdr capture scrollback,
    // which it can only do by scrolling the pane — reading that on every tick
    // drove the desktop pane into continuous scrolling. Plain text would also
    // discard the layout. Asserted on the exact params the reader sends.
    const { paneReadParams } = await import('../src/agent/herdr-live.ts');
    assert.deepEqual(paneReadParams('wJ:pS', 200), {
      pane_id: 'wJ:pS',
      source: 'visible',
      format: 'ansi',
      strip_ansi: false,
      lines: 200,
    });
  });
});
