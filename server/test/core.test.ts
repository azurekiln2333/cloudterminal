import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';

import { AgentCore } from '../src/agent/core.ts';
import type { AgentMessage, ClientMessage } from '../src/shared/protocol.ts';
import { fakeQueryFn, sdk, tick, type FakeQuery } from './fake-query.ts';

let root: string;
let core: AgentCore;
let queries: FakeQuery[];
let sent: Array<{ msg: AgentMessage; to?: string }>;

before(async () => {
  root = await mkdtemp(path.join(tmpdir(), 'ct-core-'));
  await mkdir(path.join(root, 'proj', 'src'), { recursive: true });
  await mkdir(path.join(root, 'proj', '.git'));
  await mkdir(path.join(root, 'proj', 'node_modules'));
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

beforeEach(() => {
  const fake = fakeQueryFn();
  queries = fake.queries;
  sent = [];
  core = new AgentCore({
    queryFn: fake.fn,
    roots: [root],
    defaultCwd: root,
    history: {
      list: async () => [{ sessionId: 'old-1', summary: 'Fix bug', cwd: root, lastModified: 1 }],
      messages: async () => [
        { type: 'user', message: { content: 'fix the bug' } },
        sdk.text('Fixed.'),
      ],
    },
  });
  core.setEmitter((msg, to) => sent.push({ msg, to }));
});

async function req(clientId: string, msg: ClientMessage): Promise<AgentMessage> {
  const id = String(Math.random());
  await core.handle(clientId, { ...msg, id });
  const reply = sent.find((s) => 'id' in s.msg && s.msg.id === id);
  assert.ok(reply, 'no reply for ' + msg.type);
  assert.equal(reply.to, clientId);
  return reply.msg;
}

function ofKind<K extends AgentMessage['kind']>(kind: K, to?: string) {
  return sent.filter((s) => s.msg.kind === kind && (to === undefined || s.to === to)).map((s) => s.msg as Extract<AgentMessage, { kind: K }>);
}

async function createSession(prompt?: string) {
  const reply = await req('c1', { type: 'create_session', cwd: path.join(root, 'proj'), prompt });
  assert.equal(reply.kind, 'session_created');
  return reply.session;
}

describe('AgentCore', () => {
  it('answers info', async () => {
    const info = await req('c1', { type: 'info' });
    assert.equal(info.kind, 'info');
    assert.equal(info.defaultCwd, root);
    assert.equal(info.allowBypass, false);
  });

  it('runs a full turn: prompt, stream, permission, result', async () => {
    const s = await createSession('run the tests');
    const q = queries[0]!;
    await q.waitForInput(1);
    assert.equal(q.received[0]?.message.content, 'run the tests');
    assert.equal(s.status, 'running');
    assert.equal(s.title, 'run the tests');

    const sub = await req('c1', { type: 'subscribe', sessionId: s.id, afterSeq: 0 });
    assert.equal(sub.kind, 'events');
    assert.deepEqual(sub.events.map((e) => e.kind), ['user']);

    q.emit(sdk.init());
    q.emit(sdk.delta('Runn'));
    q.emit(sdk.text('Running tests'));
    q.emit(sdk.toolUse('t1', 'Bash', { command: 'npm test' }));
    await tick();

    const decision = q.ask('Bash', { command: 'npm test' }, { title: 'Claude wants to run npm test', suggestions: [{ type: 'addRules' }] });
    await tick();
    const request = ofKind('event', 'c1').map((e) => e.event).find((e) => e.kind === 'permission_request');
    assert.ok(request?.kind === 'permission_request');
    assert.equal(request.title, 'Claude wants to run npm test');
    assert.equal(request.canAlwaysAllow, true);
    assert.equal(ofKind('session').at(-1)?.session.status, 'waiting');

    await req('c1', { type: 'permission', sessionId: s.id, requestId: request.requestId, decision: 'allow_always' });
    assert.deepEqual(await decision, {
      behavior: 'allow',
      updatedInput: { command: 'npm test' },
      updatedPermissions: [{ type: 'addRules' }],
    });

    q.emit(sdk.toolResult('t1', '3 passing'));
    q.emit(sdk.result(0.25));
    await tick();

    assert.deepEqual(ofKind('delta', 'c1').map((d) => d.text), ['Runn']);
    const kinds = ofKind('event', 'c1').map((e) => e.event.kind);
    assert.deepEqual(kinds, ['system', 'assistant', 'tool_use', 'permission_request', 'permission_resolved', 'tool_result', 'result']);
    const last = ofKind('session').at(-1)!.session;
    assert.equal(last.status, 'idle');
    assert.equal(last.costUsd, 0.25);
    assert.equal(last.claudeSessionId, 'claude-1');

    // Follow-up message goes into the same query.
    await req('c1', { type: 'send', sessionId: s.id, text: 'thanks' });
    await q.waitForInput(2);
    assert.equal(q.received[1]?.message.content, 'thanks');
  });

  it('replays only missing events on resubscribe and resets on unknown seq', async () => {
    const s = await createSession('hi');
    const q = queries[0]!;
    q.emit(sdk.text('a'));
    q.emit(sdk.text('b'));
    await tick();
    const partial = await req('c2', { type: 'subscribe', sessionId: s.id, afterSeq: 2 });
    assert.ok(partial.kind === 'events');
    assert.equal(partial.reset, false);
    assert.deepEqual(partial.events.map((e) => e.seq), [3]);

    const stale = await req('c2', { type: 'subscribe', sessionId: s.id, afterSeq: 99 });
    assert.ok(stale.kind === 'events');
    assert.equal(stale.reset, true);
    assert.equal(stale.events.length, 3);
  });

  it('only streams events to subscribed clients', async () => {
    const s = await createSession('hi');
    await req('c1', { type: 'subscribe', sessionId: s.id });
    queries[0]!.emit(sdk.text('a'));
    await tick();
    assert.equal(ofKind('event', 'c1').length, 1);
    assert.equal(ofKind('event', 'c2').length, 0);
    core.clientLeft('c1');
    queries[0]!.emit(sdk.text('b'));
    await tick();
    assert.equal(ofKind('event', 'c1').length, 1);
  });

  it('answers AskUserQuestion with answers in updatedInput', async () => {
    const s = await createSession('q');
    const q = queries[0]!;
    await req('c1', { type: 'subscribe', sessionId: s.id });
    const input = { questions: [{ question: 'Which?', header: 'H', options: [{ label: 'A', description: '' }, { label: 'B', description: '' }] }] };
    const decision = q.ask('AskUserQuestion', input);
    await tick();
    const request = ofKind('event', 'c1').map((e) => e.event).find((e) => e.kind === 'permission_request');
    assert.ok(request?.kind === 'permission_request');
    assert.equal(request.questions?.[0]?.question, 'Which?');
    assert.equal(request.canAlwaysAllow, false);
    await req('c1', { type: 'permission', sessionId: s.id, requestId: request.requestId, decision: 'allow', answers: { 'Which?': 'B' } });
    assert.deepEqual(await decision, { behavior: 'allow', updatedInput: { ...input, answers: { 'Which?': 'B' } } });
  });

  it('denies with a message and rejects stale permission answers', async () => {
    const s = await createSession('x');
    const q = queries[0]!;
    await req('c1', { type: 'subscribe', sessionId: s.id });
    const decision = q.ask('Write', { file_path: '/etc/hosts' });
    await tick();
    const request = ofKind('event', 'c1').map((e) => e.event).find((e) => e.kind === 'permission_request');
    assert.ok(request?.kind === 'permission_request');
    await req('c1', { type: 'permission', sessionId: s.id, requestId: request.requestId, decision: 'deny', message: 'no' });
    assert.deepEqual(await decision, { behavior: 'deny', message: 'no' });
    const again = await req('c1', { type: 'permission', sessionId: s.id, requestId: request.requestId, decision: 'allow' });
    assert.equal(again.kind, 'error');
  });

  it('interrupt denies pending permissions and calls the SDK', async () => {
    const s = await createSession('x');
    const q = queries[0]!;
    const decision = q.ask('Bash', { command: 'rm -rf build' });
    await tick();
    await req('c1', { type: 'interrupt', sessionId: s.id });
    assert.equal(q.interrupts, 1);
    assert.equal((await decision).behavior, 'deny');
    assert.equal(ofKind('session').at(-1)?.session.status, 'idle');
  });

  it('switches permission mode and refuses bypass unless allowed', async () => {
    const s = await createSession();
    await req('c1', { type: 'set_mode', sessionId: s.id, mode: 'acceptEdits' });
    assert.deepEqual(queries[0]!.modes, ['acceptEdits']);
    const denied = await req('c1', { type: 'set_mode', sessionId: s.id, mode: 'bypassPermissions' });
    assert.equal(denied.kind, 'error');
    const created = await req('c1', { type: 'create_session', cwd: root, mode: 'bypassPermissions' });
    assert.equal(created.kind, 'error');
  });

  it('confines paths to the configured roots', async () => {
    const outside = await req('c1', { type: 'create_session', cwd: path.dirname(root) });
    assert.equal(outside.kind, 'error');
    const sneaky = await req('c1', { type: 'list_dir', path: path.join(root, '..') });
    assert.equal(sneaky.kind, 'error');
  });

  it('lists directories without hidden and dependency folders', async () => {
    const top = await req('c1', { type: 'list_dir' });
    assert.ok(top.kind === 'dir');
    assert.equal(top.parent, null);
    assert.deepEqual(top.entries.map((e) => e.path), [path.resolve(root)]);

    const proj = await req('c1', { type: 'list_dir', path: path.join(root, 'proj') });
    assert.ok(proj.kind === 'dir');
    assert.deepEqual(proj.entries.map((e) => e.name), ['src']);
    assert.equal(proj.parent, path.resolve(root));

    const rootDir = await req('c1', { type: 'list_dir', path: root });
    assert.ok(rootDir.kind === 'dir');
    assert.equal(rootDir.parent, '');
  });

  it('resumes with transcript history', async () => {
    const reply = await req('c1', { type: 'create_session', cwd: root, resume: 'old-1' });
    assert.ok(reply.kind === 'session_created');
    assert.equal(queries[0]!.options.resume, 'old-1');
    assert.equal(reply.session.title, 'fix the bug');
    const sub = await req('c1', { type: 'subscribe', sessionId: reply.session.id });
    assert.ok(sub.kind === 'events');
    assert.deepEqual(sub.events.map((e) => e.kind), ['user', 'assistant', 'system']);
  });

  it('marks a session closed when the CLI exits and removes it on close_session', async () => {
    const s = await createSession('x');
    queries[0]!.end();
    await tick();
    await tick();
    assert.equal(ofKind('session').at(-1)?.session.status, 'closed');
    await req('c1', { type: 'close_session', sessionId: s.id });
    const list = await req('c1', { type: 'list_sessions' });
    assert.ok(list.kind === 'sessions');
    assert.equal(list.sessions.length, 0);
  });

  it('reports errors for unknown sessions and request types', async () => {
    assert.equal((await req('c1', { type: 'send', sessionId: 'nope', text: 'x' })).kind, 'error');
    assert.equal((await req('c1', { type: 'bogus' } as unknown as ClientMessage)).kind, 'error');
  });
});
