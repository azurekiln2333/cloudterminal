import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AgentCore } from '../src/agent/core.ts';
import { nativePty, type PtyHandle } from '../src/agent/pty.ts';
import { TerminalSession, TERMINAL_REPLAY_BYTES } from '../src/agent/terminal-session.ts';
import type { SessionListener } from '../src/agent/session.ts';
import { MAX_FRAME_BYTES, type AgentMessage, type ClientMessage, type SessionEvent } from '../src/shared/protocol.ts';

class FakePty implements PtyHandle {
  input: string[] = [];
  sizes: number[][] = [];
  kills = 0;
  output = (_data: string) => {};
  exit = (_event: { exitCode: number }) => {};
  write(data: string) { this.input.push(data); }
  resize(cols: number, rows: number) { this.sizes.push([cols, rows]); }
  kill() { this.kills++; this.exit({ exitCode: 0 }); }
  onData(callback: (data: string) => void) { this.output = callback; return { dispose() {} }; }
  onExit(callback: (event: { exitCode: number }) => void) { this.exit = callback; return { dispose() {} }; }
}
const silent: SessionListener = { onEvent() {}, onState() {}, onDelta() {} };

test('PTY preserves raw input, resize, local mirroring and lifecycle', async () => {
  const pty = new FakePty();
  const s = new TerminalSession(() => pty, { cwd: process.cwd() }, silent);
  const chunks: string[] = [];
  const detach = s.attach((data) => chunks.push(data));
  s.write(' \r\x03\t中文 ');
  await s.interrupt();
  assert.deepEqual(pty.input, [' \r\x03\t中文 ', '\x03']);
  s.resize(120, 40);
  assert.deepEqual(pty.sizes, [[120, 40]]);
  assert.throws(() => s.resize(0, 24));
  assert.throws(() => s.resize(80.5, 24));
  assert.throws(() => s.write('a'.repeat(65537)));
  pty.output('\x1b[31mred\x1b[0m');
  detach();
  pty.output('remote only');
  assert.deepEqual(chunks, ['\x1b[31mred\x1b[0m']);
  assert.equal(s.eventsAfter(1).events.length, 1);
  assert.equal(s.eventsAfter(99).reset, true);
  s.close(); s.close();
  assert.equal(pty.kills, 1);
  assert.equal(s.info().status, 'closed');
  assert.throws(() => s.write('x'));
});

test('PTY chunks huge output losslessly and bounds JSON replay, including ANSI gaps', () => {
  const pty = new FakePty();
  const streamed: SessionEvent[] = [];
  const s = new TerminalSession(() => pty, { cwd: '.' }, { ...silent, onEvent: (_, e) => streamed.push(e) });
  const data = '\x00中😀\x1b[31mx\x1b[0m'.repeat(40000);
  pty.output(data);
  assert.equal(streamed.map((e) => e.kind === 'terminal_output' ? e.data : '').join(''), data);
  const replay = s.eventsAfter(0);
  assert.equal(replay.reset, true);
  assert.ok(Buffer.byteLength(JSON.stringify({ t: 'msg', data: { kind: 'events', ...replay } })) < MAX_FRAME_BYTES);
  assert.ok(replay.events.reduce((sum, e) => sum + (e.kind === 'terminal_output' ? Buffer.byteLength(e.data) : 0), 0) <= TERMINAL_REPLAY_BYTES);
  pty.output('\x1b]0;'+ 'x'.repeat(TERMINAL_REPLAY_BYTES * 2));
  pty.output('still an OSC\x07');
  pty.output('safe');
  const reset = s.eventsAfter(0);
  assert.equal(reset.reset, true);
  assert.deepEqual(reset.events.map((e) => e.kind === 'terminal_output' ? e.data : ''), ['safe']);
  s.close();
});

test('core advertises terminal, validates requests, rejects Claude operations and preserves sessions on disconnect', async () => {
  const pty = new FakePty();
  const core = new AgentCore({ queryFn: () => { throw new Error('AI must not run'); }, ptyFactory: () => pty,
    roots: [process.cwd()], defaultCwd: process.cwd(), maxSessions: 1 });
  let response: AgentMessage | undefined;
  const events: AgentMessage[] = [];
  core.setEmitter((m) => { if ('id' in m && m.id === 'test') response = m; events.push(m); });
  const req = async (m: ClientMessage) => { response = undefined; await core.handle('phone', { ...m, id: 'test' }); return response!; };
  const info = await req({ type: 'info' });
  assert.ok(info.kind === 'info' && info.capabilities?.includes('terminal'));
  assert.equal((await req({ type: 'create_terminal', cwd: process.cwd(), cols: -1 })).kind, 'error');
  const created = await req({ type: 'create_terminal', cwd: process.cwd() });
  assert.equal(created.kind, 'session_created');
  const id = created.session.id;
  assert.equal(created.session.kind, 'terminal');
  assert.equal((await req({ type: 'create_terminal', cwd: process.cwd() })).kind, 'error');
  assert.equal((await req({ type: 'send', sessionId: id, text: 'AI' })).kind, 'error');
  assert.equal((await req({ type: 'set_mode', sessionId: id, mode: 'default' })).kind, 'error');
  assert.equal((await req({ type: 'subscribe', sessionId: id, afterSeq: -1 })).kind, 'error');
  pty.output('not subscribed');
  assert.equal(events.filter((e) => e.kind === 'event').length, 0);
  await req({ type: 'subscribe', sessionId: id });
  pty.output('one');
  core.clientLeft('phone');
  pty.output('two');
  assert.equal(events.filter((e) => e.kind === 'event').length, 1);
  const replay = await req({ type: 'subscribe', sessionId: id, afterSeq: 2 });
  assert.ok(replay.kind === 'events' && replay.events[0]?.kind === 'terminal_output');
  assert.equal(replay.events[0].data, 'two');
  assert.equal((await req({ type: 'terminal_input', sessionId: id, data: ' \r' })).kind, 'ack');
  assert.equal((await req({ type: 'terminal_resize', sessionId: id, cols: 100, rows: 30 })).kind, 'ack');
  assert.deepEqual(pty.input, [' \r']);
  await core.handle('second-phone', { type: 'subscribe', sessionId: id });
  await req({ type: 'close_session', sessionId: id });
  assert.ok(events.some((e) => e.kind === 'session' && e.session.id === id && e.session.status === 'closed'));
  assert.equal(pty.kills, 1);
});

test('closing a real terminal kills its running child process', { timeout: 15000 }, async () => {
  let output = '';
  let childPid = 0;
  let resolveReady!: () => void;
  const ready = new Promise<void>((resolve) => { resolveReady = resolve; });
  const session = new TerminalSession(nativePty, { cwd: process.cwd() }, {
    ...silent,
    onEvent: (_, e) => {
      if (e.kind !== 'terminal_output') return;
      output += e.data;
      const match = output.match(/CT_CHILD_(\d+)/);
      if (match) { childPid = Number(match[1]); resolveReady(); }
    },
  });
  try {
    session.write(`"${process.execPath}" -e "console.log('CT_CHILD_'+process.pid);setInterval(()=>{},1000)"\r`);
    await ready;
    process.kill(childPid, 0);
    await session.close();
    const deadline = Date.now() + 3000;
    let alive = true;
    while (alive && Date.now() < deadline) {
      try { process.kill(childPid, 0); } catch { alive = false; }
      if (alive) await new Promise((resolve) => setTimeout(resolve, 30));
    }
    assert.equal(alive, false, 'terminal child survived close');
  } finally { await session.close(); }
});

test('real native PTY runs shell commands without AI and exits', { timeout: 15000 }, async () => {
  let output = '';
  let resolveOutput!: () => void;
  let resolveExit!: () => void;
  const gotOutput = new Promise<void>((resolve) => { resolveOutput = resolve; });
  const exited = new Promise<void>((resolve) => { resolveExit = resolve; });
  const session = new TerminalSession(nativePty, { cwd: process.cwd(), cols: 100, rows: 30 }, {
    ...silent,
    onEvent: (_, event) => { if (event.kind === 'terminal_output') { output += event.data; if (output.includes('CT_REAL_OK')) resolveOutput(); } },
    onState: (s) => { if (s.status === 'closed') resolveExit(); },
  });
  try {
    // Split token in the command so terminal echo alone cannot satisfy assertion.
    if (process.platform !== 'win32') session.write("printf 'CT_REAL_%s\\n' OK\r");
    if (process.platform === 'win32') {
      session.write('set CT_TEST_VALUE=OK\r');
      session.write('echo CT_REAL_%CT_TEST_VALUE%\r');
    }
    await gotOutput;
    session.resize(90, 25);
    session.write('exit\r');
    await exited;
    assert.equal(session.status, 'closed');
  } finally { session.close(); }
});
