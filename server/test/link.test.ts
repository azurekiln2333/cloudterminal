import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';

import { loadConfig } from '../src/agent/config.ts';
import { AgentCore } from '../src/agent/core.ts';
import { formatPairCode, generatePairCode, RelayLink } from '../src/agent/link.ts';
import type { Relay } from '../src/relay/relay.ts';
import { PAIR_CODE_ALPHABET } from '../src/shared/protocol.ts';
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
