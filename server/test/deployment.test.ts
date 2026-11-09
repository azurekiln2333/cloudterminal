import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer, type AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { WebSocketServer } from 'ws';
import { loadConfig, saveConfig } from '../src/agent/config.ts';

// Relay-process tests (registration key, show-key, bad PORT) moved to the relay
// server repo as `relay-startup.test.ts`; this file covers the PC agent only.

function childEnv(home: string, overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const env = { ...process.env };
  for (const key of ['CLOUDTERMINAL_RELAY', 'CLOUDTERMINAL_RELAY_KEY', 'RELAY_KEY', 'RELAY_KEY_FILE', 'RELAY_TRUST_PROXY']) delete env[key];
  return { ...env, CLOUDTERMINAL_HOME: home, ...overrides };
}

function launch(script: string, env: NodeJS.ProcessEnv, args: string[] = []) {
  const child = spawn(process.execPath, [script, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on('data', (chunk: Buffer) => { output += chunk.toString(); });
  return { child, output: () => output };
}

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill();
  await exited;
}

async function waitFor(predicate: () => boolean, output: () => string): Promise<void> {
  const until = Date.now() + 7000;
  while (!predicate() && Date.now() < until) await delay(25);
  assert.ok(predicate(), output());
}

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
  return port;
}

test('agent CLI and environment precedence never forwards a saved key to another relay', { timeout: 25000 }, async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'ct-precedence-'));
  const server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await once(server, 'listening');
  const url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}/ws`;
  const hellos: Array<{ relayKey?: string; agentId?: string }> = [];
  server.on('connection', (socket) => {
    socket.once('message', (frame) => { hellos.push(JSON.parse(frame.toString()) as (typeof hellos)[number]); });
  });
  const file = path.join(home, 'agent.json');
  const initial = await loadConfig(file);
  try {
    for (const scenario of [
      { savedUrl: 'ws://127.0.0.1:1/ws', env: { CLOUDTERMINAL_RELAY: url }, args: [], expected: undefined, savedKey: 'saved-key' },
      { savedUrl: url, env: { CLOUDTERMINAL_RELAY: url }, args: [], expected: 'saved-key', savedKey: 'saved-key' },
      { savedUrl: url, env: { CLOUDTERMINAL_RELAY_KEY: 'env-key' }, args: [], expected: 'env-key', savedKey: 'saved-key' },
      { savedUrl: 'ws://127.0.0.1:1/ws', env: { CLOUDTERMINAL_RELAY: url, CLOUDTERMINAL_RELAY_KEY: 'env-key' }, args: [], expected: 'env-key', savedKey: 'saved-key' },
      { savedUrl: url, env: { CLOUDTERMINAL_RELAY: 'invalid://ignored', CLOUDTERMINAL_RELAY_KEY: 'env-key' }, args: ['--relay', url, '--relay-key', 'cli-key'], expected: 'cli-key', savedKey: 'cli-key' },
      { savedUrl: 'ws://127.0.0.1:1/ws', env: { CLOUDTERMINAL_RELAY: url, CLOUDTERMINAL_RELAY_KEY: 'env-key' }, args: ['--relay-key', 'cli-key'], expected: 'cli-key', savedKey: 'saved-key' },
    ]) {
      const config = { ...initial, connectionMode: 'remote' as const, relayUrl: scenario.savedUrl, relayKey: 'saved-key', terminal: false };
      await saveConfig(config, file);
      hellos.length = 0;
      // The LAN entry is always on now, so every agent needs its own port or
      // they would fight over the default one.
      const proc = launch('src/agent/main.ts', childEnv(home, scenario.env), [...scenario.args, '--port', String(await freePort()), '--no-terminal']);
      try {
        await waitFor(() => hellos.length > 0, proc.output);
        assert.equal(hellos[0]?.relayKey, scenario.expected);
        assert.equal(hellos[0]?.agentId, initial.agentId);
        const saved = await loadConfig(file);
        assert.equal(saved.secret, initial.secret);
        assert.equal(saved.relayUrl, scenario.args.some((arg) => arg === '--relay') ? url : scenario.savedUrl);
        assert.equal(saved.relayKey, scenario.savedKey);
      } finally { await stop(proc.child); }
    }
  } finally {
    for (const socket of server.clients) socket.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(home, { recursive: true, force: true });
  }
});

test('explicit local mode ignores remote environment URL and empty remote URL fails clearly', { timeout: 15000 }, async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'ct-local-options-'));
  try {
    const local = launch('src/agent/main.ts', childEnv(home, { CLOUDTERMINAL_RELAY: 'invalid://ignored' }), ['--port', String(await freePort()), '--no-terminal']);
    try { await waitFor(() => local.output().includes('手机配对'), local.output); }
    finally { await stop(local.child); }
    // --no-local-relay with no relay at all must fail loudly.
    const invalid = launch('src/agent/main.ts', childEnv(home, { CLOUDTERMINAL_RELAY: '' }), ['--no-local-relay']);
    try {
      const [code] = await once(invalid.child, 'exit');
      assert.notEqual(code, 0);
      assert.match(invalid.output(), /已禁用局域网入口/);
      assert.doesNotMatch(invalid.output(), /连接方式/);
    } finally { await stop(invalid.child); }
  } finally { await rm(home, { recursive: true, force: true }); }
});
