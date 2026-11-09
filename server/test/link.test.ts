import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';

import { loadConfig } from '../src/agent/config.ts';
import { AgentCore } from '../src/agent/core.ts';
import { formatPairCode, generatePairCode, RelayLink } from '../src/agent/link.ts';
import type { Relay } from '../src/relay/relay.ts';
import { PAIR_CODE_ALPHABET, type AgentMessage } from '../src/shared/protocol.ts';
import { fakeQueryFn, sdk, type FakeQuery } from './fake-query.ts';
import { startRelay, TestSocket } from './helpers.ts';

let dir: string;
let relay: Relay;
let url: string;
let link: RelayLink;
let queries: FakeQuery[];

before(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'ct-link-'));
  ({ relay, url } = await startRelay());
  const fake = fakeQueryFn();
  queries = fake.queries;
  const core = new AgentCore({ queryFn: fake.fn, roots: [dir], defaultCwd: dir });
  const online = new Promise<void>((resolve) => {
    link = new RelayLink({ url, agentId: 'agent-link-1', secret: 's3cret-value', name: 'box', core, onOnline: resolve });
  });
  link.start();
  await online;
});

after(async () => {
  link.stop();
  await relay.close();
  await rm(dir, { recursive: true, force: true });
});

describe('RelayLink end to end', () => {
  it('pairs a phone with a one-time code', async () => {
    const code = await link.requestPairCode();
    assert.match(code.display, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const p = await TestSocket.open(url);
    p.send({ t: 'hello', role: 'pair', code: code.display.toLowerCase() });
    assert.deepEqual(await p.next(), { t: 'paired', agentId: 'agent-link-1', secret: 's3cret-value', name: 'box' });
  });

  it('drives a session from a client through the relay', async () => {
    const c = await TestSocket.open(url);
    c.send({ t: 'hello', role: 'client', agentId: 'agent-link-1', secret: 's3cret-value' });
    assert.equal((await c.next((f) => f.t === 'hello_ok')).online, true);

    c.send({ t: 'msg', data: { id: '1', type: 'create_session', cwd: dir, prompt: 'hello' } });
    const created = await c.next((f) => f.t === 'msg' && f.data.id === '1');
    assert.equal(created.data.kind, 'session_created');
    const sessionId = created.data.session.id;

    c.send({ t: 'msg', data: { id: '2', type: 'subscribe', sessionId } });
    const backlog = await c.next((f) => f.t === 'msg' && f.data.id === '2');
    assert.deepEqual(backlog.data.events.map((e: any) => e.kind), ['user']);

    const q = queries[0]!;
    const decision = q.ask('Bash', { command: 'ls' });
    const req = await c.next((f) => f.t === 'msg' && f.data.kind === 'event' && f.data.event.kind === 'permission_request');
    c.send({ t: 'msg', data: { id: '3', type: 'permission', sessionId, requestId: req.data.event.requestId, decision: 'allow' } });
    assert.equal((await decision).behavior, 'allow');

    q.emit(sdk.result(0.02));
    const result = await c.next((f) => f.t === 'msg' && f.data.kind === 'event' && f.data.event.kind === 'result');
    assert.equal(result.data.event.costUsd, 0.02);
    c.close();
  });
});

describe('pairing codes', () => {
  it('uses only unambiguous characters', () => {
    for (let i = 0; i < 50; i++) {
      const code = generatePairCode();
      assert.equal(code.length, 8);
      assert.ok([...code].every((ch) => PAIR_CODE_ALPHABET.includes(ch)));
    }
    assert.equal(formatPairCode('ABCD2345'), 'ABCD-2345');
  });
});

describe('agent config', () => {
  it('creates an identity once and keeps it', async () => {
    const file = path.join(dir, 'cfg', 'agent.json');
    const a = await loadConfig(file);
    const b = await loadConfig(file);
    assert.equal(a.agentId, b.agentId);
    assert.equal(a.secret, b.secret);
    assert.ok(a.secret.length >= 40);
    const c = await loadConfig(file, { reset: true });
    assert.notEqual(c.secret, a.secret);
    assert.equal(JSON.parse(await readFile(file, 'utf8')).secret, c.secret);
    if (process.platform !== 'win32') assert.equal((await stat(file)).mode & 0o777, 0o600);
  });
});

describe('dual ingress', () => {
  it('attaches one agent to two relays at once without evicting either', async () => {
    // The LAN relay runs in-process while the public one is a separate server;
    // both must accept the same agentId and both must stay online, because a
    // phone on the LAN and a phone outside use different entries.
    const lan = await startRelay();
    const wan = await startRelay();
    const fake = fakeQueryFn();
    const core = new AgentCore({ queryFn: fake.fn, roots: [dir], defaultCwd: dir });
    const seen: AgentMessage[] = [];
    core.addEmitter((msg) => seen.push(msg));

    const online = new Set<string>();
    const links = [
      new RelayLink({ url: lan.url, agentId: 'dual-agent-01', secret: 's3cret-value', name: 'box', core, onOnline: () => online.add('lan') }),
      new RelayLink({ url: wan.url, agentId: 'dual-agent-01', secret: 's3cret-value', name: 'box', core, onOnline: () => online.add('wan') }),
    ];
    try {
      for (const l of links) l.start();
      const deadline = Date.now() + 8000;
      while (online.size < 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 25));
      assert.deepEqual([...online].sort(), ['lan', 'wan'], 'an entry was evicted or never connected');

      // Both links still own the outbound stream: a core-initiated message
      // reaches each relay, which is what a single-slot emitter would break.
      await core.handle('probe', { type: 'list_sessions', id: 'dual-a' });
      assert.ok(seen.some((m) => 'id' in m && m.id === 'dual-a'));

      // Each relay independently knows the agent is online for clients.
      const probe = await TestSocket.open(wan.url);
      probe.send({ t: 'hello', role: 'client', agentId: 'dual-agent-01', secret: 's3cret-value' });
      const hello = await probe.next((f) => f.t === 'hello_ok');
      assert.equal(hello.online, true, 'the public relay lost the agent');
      probe.ws.close();
    } finally {
      for (const l of links) l.stop();
      await lan.relay.close();
      await wan.relay.close();
    }
  });

  it('detaches its emitter on stop so a closed link stops receiving', async () => {
    const solo = await startRelay();
    const fake = fakeQueryFn();
    const core = new AgentCore({ queryFn: fake.fn, roots: [dir], defaultCwd: dir });
    const seen: AgentMessage[] = [];
    core.addEmitter((msg) => seen.push(msg));
    let onlineResolve: () => void = () => {};
    const online = new Promise<void>((resolve) => { onlineResolve = resolve; });
    const l = new RelayLink({ url: solo.url, agentId: 'dual-agent-02', secret: 's3cret-value', name: 'box', core, onOnline: onlineResolve });
    try {
      l.start();
      await online;
      l.stop();
      const before = seen.length;
      await core.handle('c1', { type: 'list_sessions', id: 'detached-1' });
      assert.equal(seen.length, before + 1, 'the surviving emitter must still receive');
    } finally {
      l.stop();
      await solo.relay.close();
    }
  });
});
