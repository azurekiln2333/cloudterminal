import assert from 'node:assert/strict';
import { afterEach, describe, it } from 'node:test';

import { sha256Hex } from '../src/shared/crypto.ts';
import type { Relay } from '../src/relay/relay.ts';
import { startRelay, TestSocket } from './helpers.ts';

const AGENT_ID = 'agent-0001';
const SECRET = 'correct horse battery staple';

let relay: Relay | undefined;
const sockets: TestSocket[] = [];

async function open(url: string): Promise<TestSocket> {
  const s = await TestSocket.open(url);
  sockets.push(s);
  return s;
}

async function agent(url: string, extra: Record<string, unknown> = {}): Promise<TestSocket> {
  const s = await open(url);
  s.send({ t: 'hello', role: 'agent', agentId: AGENT_ID, secretHash: sha256Hex(SECRET), name: 'pc', ...extra });
  return s;
}

async function client(url: string, secret = SECRET): Promise<TestSocket> {
  const s = await open(url);
  s.send({ t: 'hello', role: 'client', agentId: AGENT_ID, secret });
  return s;
}

afterEach(async () => {
  for (const s of sockets.splice(0)) s.close();
  await relay?.close();
  relay = undefined;
});

describe('relay', () => {
  it('routes messages both ways and stamps clientId', async () => {
    const r = await startRelay();
    relay = r.relay;
    const a = await agent(r.url);
    await a.next((f) => f.t === 'hello_ok');

    const c = await client(r.url);
    const ok = await c.next((f) => f.t === 'hello_ok');
    assert.equal(ok.online, true);
    assert.equal(ok.name, 'pc');
    const joined = await a.next((f) => f.t === 'client_joined');
    assert.equal(joined.clientId, ok.clientId);

    c.send({ t: 'msg', data: { type: 'info', id: '1' } });
    const toAgent = await a.next((f) => f.t === 'msg');
    assert.deepEqual(toAgent, { t: 'msg', clientId: ok.clientId, data: { type: 'info', id: '1' } });

    a.send({ t: 'msg', data: { kind: 'ack', id: '1' } });
    assert.deepEqual(await c.next((f) => f.t === 'msg'), { t: 'msg', data: { kind: 'ack', id: '1' } });
  });

  it('delivers targeted messages to one client and broadcasts the rest', async () => {
    const r = await startRelay();
    relay = r.relay;
    const a = await agent(r.url);
    await a.next((f) => f.t === 'hello_ok');
    const c1 = await client(r.url);
    const id1 = (await c1.next((f) => f.t === 'hello_ok')).clientId;
    const c2 = await client(r.url);
    await c2.next((f) => f.t === 'hello_ok');

    a.send({ t: 'msg', to: id1, data: { kind: 'ack', id: 'only-1' } });
    assert.equal((await c1.next((f) => f.t === 'msg')).data.id, 'only-1');
    assert.ok(await c2.none((f) => f.t === 'msg'));

    a.send({ t: 'msg', data: { kind: 'ack', id: 'all' } });
    assert.equal((await c1.next((f) => f.t === 'msg')).data.id, 'all');
    assert.equal((await c2.next((f) => f.t === 'msg')).data.id, 'all');
  });

  it('rejects a wrong secret and rate limits repeated failures', async () => {
    const r = await startRelay({ maxAuthFailures: 2 });
    relay = r.relay;
    const a = await agent(r.url);
    await a.next((f) => f.t === 'hello_ok');

    for (let i = 0; i < 2; i++) {
      const bad = await client(r.url, 'wrong');
      assert.equal((await bad.next()).code, 'unauthorized');
      await bad.closed;
    }
    const limited = await client(r.url, SECRET);
    assert.equal((await limited.next()).code, 'rate_limited');
  });

  it('reports agent_offline for an unknown agent without counting a failure', async () => {
    const r = await startRelay({ maxAuthFailures: 1 });
    relay = r.relay;
    for (let i = 0; i < 3; i++) {
      const c = await client(r.url);
      assert.equal((await c.next()).code, 'agent_offline');
      await c.closed;
    }
  });

  it('keeps clients across agent reconnects and signals presence', async () => {
    const r = await startRelay();
    relay = r.relay;
    const a1 = await agent(r.url);
    await a1.next((f) => f.t === 'hello_ok');
    const c = await client(r.url);
    await c.next((f) => f.t === 'hello_ok');

    a1.close();
    assert.equal((await c.next((f) => f.t === 'presence')).online, false);

    c.send({ t: 'msg', data: { type: 'info' } });
    assert.equal((await c.next((f) => f.t === 'error')).code, 'agent_offline');

    const a2 = await agent(r.url);
    await a2.next((f) => f.t === 'hello_ok');
    assert.equal((await c.next((f) => f.t === 'presence')).online, true);
    await a2.next((f) => f.t === 'client_joined');
  });

  it('replaces an older agent connection with the same credentials', async () => {
    const r = await startRelay();
    relay = r.relay;
    const a1 = await agent(r.url);
    await a1.next((f) => f.t === 'hello_ok');
    const a2 = await agent(r.url);
    await a2.next((f) => f.t === 'hello_ok');
    assert.equal((await a1.closed).code, 4000);
    assert.equal(relay.stats().online, 1);
  });

  it('refuses an agentId claimed with a different secret', async () => {
    const r = await startRelay();
    relay = r.relay;
    const a1 = await agent(r.url);
    await a1.next((f) => f.t === 'hello_ok');
    const imposter = await agent(r.url, { secretHash: sha256Hex('other') });
    assert.equal((await imposter.next()).code, 'agent_conflict');
  });

  it('requires the relay key when configured', async () => {
    const r = await startRelay({ relayKey: 'k3y' });
    relay = r.relay;
    const bad = await agent(r.url);
    assert.equal((await bad.next()).code, 'unauthorized');
    const good = await agent(r.url, { relayKey: 'k3y' });
    assert.equal((await good.next()).t, 'hello_ok');
  });

  it('closes sockets that never say hello', async () => {
    const r = await startRelay({ helloTimeoutMs: 50 });
    relay = r.relay;
    const s = await open(r.url);
    assert.equal((await s.next()).code, 'timeout');
    await s.closed;
  });

  it('rejects malformed hello frames', async () => {
    const r = await startRelay();
    relay = r.relay;
    const s = await open(r.url);
    s.send({ t: 'hello', role: 'agent', agentId: AGENT_ID, secretHash: 'not-hex' });
    assert.equal((await s.next()).code, 'bad_request');
  });
});
