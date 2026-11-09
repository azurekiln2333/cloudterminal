import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer, type AddressInfo } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { nativePty } from '../src/agent/pty.ts';
import { TestSocket } from './helpers.ts';

test('desktop terminal shares local and remote control, detaches and restores input', { timeout: 30000 }, async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'ct-desktop-'));
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  const oldHome = process.env.CLOUDTERMINAL_HOME;
  process.env.CLOUDTERMINAL_HOME = home;
  const terminal = nativePty({ cwd: process.cwd(), cols: 100, rows: 30 });
  if (oldHome === undefined) delete process.env.CLOUDTERMINAL_HOME;
  else process.env.CLOUDTERMINAL_HOME = oldHome;
  let output = '';
  terminal.onData((data) => { output += data; });
  let phone: TestSocket | undefined;
  async function waitFor(predicate: () => boolean, reason: string) {
    const until = Date.now() + 12000;
    while (!predicate() && Date.now() < until) await delay(30);
    assert.ok(predicate(), `${reason}: ${output.slice(-3000)}`);
  }
  try {
    terminal.write(`"${process.execPath}" src/agent/main.ts --local-relay --port ${port} --terminal --root "${home}" --cwd "${home}"\r`);
    await waitFor(() => output.includes(process.platform === 'win32' ? `${home}>` : '共享终端即将启动'), 'local attachment');
    const config = JSON.parse(await readFile(path.join(home, 'agent.json'), 'utf8'));
    phone = await TestSocket.open(`ws://127.0.0.1:${port}/ws`);
    phone.send({ t: 'hello', role: 'client', agentId: config.agentId, secret: config.secret });
    await phone.next((f) => f.t === 'hello_ok');
    phone.send({ t: 'msg', data: { type: 'list_sessions', id: 'list' } });
    const list = await phone.next((f) => f.data?.id === 'list');
    assert.equal(list.data.sessions.length, 1);
    const id = list.data.sessions[0].id;
    assert.equal(list.data.sessions[0].kind, 'terminal');
    phone.send({ t: 'msg', data: { type: 'subscribe', sessionId: id, id: 'sub' } });
    await phone.next((f) => f.data?.id === 'sub');
    const command = process.platform === 'win32' ? 'set CT_DESKTOP_VALUE=LOCAL\r' : 'CT_DESKTOP_VALUE=LOCAL\r';
    terminal.write(command);
    terminal.write(process.platform === 'win32' ? 'echo CT_%CT_DESKTOP_VALUE%_OK\r' : 'echo CT_${CT_DESKTOP_VALUE}_OK\r');
    let remoteOutput = '';
    while (!remoteOutput.includes('CT_LOCAL_OK')) {
      const f = await phone.next((f) => f.data?.kind === 'event', 5000);
      remoteOutput += f.data.event.data ?? '';
    }
    await waitFor(() => output.includes('CT_LOCAL_OK'), 'local output');
    terminal.write('\x1d');
    await waitFor(() => output.includes('输入 attach'), 'detach');
    phone.send({ t: 'msg', data: { type: 'terminal_input', sessionId: id, data: 'echo CT_REMOTE_OK\r', id: 'input' } });
    assert.equal((await phone.next((f) => f.data?.id === 'input')).data.kind, 'ack');
    terminal.write('attach\r');
    await waitFor(() => output.includes('CT_REMOTE_OK'), 'reattach replay');
    terminal.write('\x1d');
    await delay(150);
    terminal.write('\x03');
    await Promise.race([
      phone.closed,
      delay(5000).then(() => { throw new Error('agent did not shut down after detached Ctrl-C'); }),
    ]);
  } finally {
    phone?.close();
    await terminal.kill();
    await delay(1200);
    await rm(home, { recursive: true, force: true });
  }
});
