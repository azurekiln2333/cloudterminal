import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { nativePty } from '../src/agent/pty.ts';
import { startRelay } from './helpers.ts';
import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

test('real first-run wizard hides key and saved configuration starts again without prompts', { timeout: 25000 }, async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'ct-wizard-'));
  const key = 'CT_HIDDEN_REGISTRATION_TEST';
  const { relay, url } = await startRelay({ relayKey: key });
  // The default port may be occupied by a running agent, so the wizard is
  // driven with a free one.
  const port = await freePort();
  const old = process.env.CLOUDTERMINAL_HOME;
  process.env.CLOUDTERMINAL_HOME = home;
  const pty = nativePty({ cwd: process.cwd(), cols: 160, rows: 40 });
  if (old === undefined) delete process.env.CLOUDTERMINAL_HOME; else process.env.CLOUDTERMINAL_HOME = old;
  let output = '';
  const launch = process.platform === 'win32' ? '..\\start.cmd' : `"${process.execPath}" src/agent/main.ts`;
  pty.onData((chunk) => { output += chunk; });
  const waitFor = async (text: string) => {
    const deadline = Date.now() + 8000;
    while (!output.includes(text) && Date.now() < deadline) await delay(25);
    assert.ok(output.includes(text), `missing ${text}: ${output.slice(-1600)}`);
  };
  try {
    pty.write(launch + '\r');
    await waitFor('本机端口'); pty.write(`${port}\r`);
    await waitFor('中继地址'); pty.write(url + '\r');
    await waitFor('注册密钥'); pty.write(key + '\r');
    await waitFor('工作目录'); pty.write(home + '\r');
    await waitFor('[Y/n]'); pty.write('n\r');
    await waitFor('手机配对');
    assert.equal(output.includes(key), false, 'secret was echoed');
    const saved = JSON.parse(await readFile(path.join(home, 'agent.json'), 'utf8'));
    assert.equal(saved.relayKey, key);
    assert.equal(saved.defaultCwd, home);
    assert.equal(saved.terminal, false);
    pty.write('\x03');
    await delay(350);
    output = '';
    pty.write(launch + '\r');
    await waitFor('手机配对');
    assert.equal(output.includes('本机端口'), false);
    pty.write('\x03');
    await delay(250);
  } finally {
    await pty.kill();
    await relay.close();
    await rm(home, { recursive: true, force: true });
  }
});
