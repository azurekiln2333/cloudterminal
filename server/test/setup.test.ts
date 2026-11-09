import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { loadConfig, saveConfig } from '../src/agent/config.ts';
import { relayAddress, setupConfig } from '../src/agent/setup.ts';
import { registrationKey } from '../src/relay/key.ts';

test('setup persists connection, directories, terminal preference and identity', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'ct-setup-'));
  try {
    const file = path.join(dir, 'agent.json');
    const initial = await loadConfig(file);
    // New order: port -> relay address -> key -> cwd -> shared terminal.
    const answers = ['8787', 'https://relay.example.com', 'private-key', dir, 'n'];
    let hidden = false;
    const configured = await setupConfig(initial, async (_label, secret) => { if (secret) hidden = true; return answers.shift()!; });
    assert.equal(hidden, true);
    await saveConfig(configured, file);
    const loaded = await loadConfig(file);
    assert.deepEqual(loaded, configured);
    assert.equal(loaded.agentId, initial.agentId);
    assert.equal(loaded.secret, initial.secret);
    assert.equal(loaded.relayUrl, 'wss://relay.example.com/ws');
    assert.deepEqual(loaded.roots, [dir]);
    assert.equal(loaded.terminal, false);
    // Re-running with a blank address drops the public entry but keeps LAN.
    const local = ['9000', '', dir, ''];
    const revised = await setupConfig(loaded, async () => local.shift()!);
    assert.equal(revised.relayUrl, undefined);
    assert.equal(revised.relayKey, undefined);
    assert.equal(revised.localPort, 9000);
    assert.equal(revised.terminal, true);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('setup validates addresses and never carries key to a different relay', async () => {
  assert.equal(relayAddress('192.168.1.8:8787'), 'ws://192.168.1.8:8787/ws');
  assert.equal(relayAddress('relay.example.com'), 'wss://relay.example.com/ws');
  assert.equal(relayAddress('localhost:8787'), 'ws://localhost:8787/ws');
  assert.equal(relayAddress('[::1]:8787'), 'ws://[::1]:8787/ws');
  assert.equal(relayAddress('localhost.example.com'), 'wss://localhost.example.com/ws');
  assert.equal(relayAddress('192.168.relay.example.com'), 'wss://192.168.relay.example.com/ws');
  assert.throws(() => relayAddress('https://name:secret@example.com'));
  assert.throws(() => relayAddress('file:///tmp/example'));
  assert.throws(() => relayAddress('https://example.com/wrong'));
  assert.throws(() => relayAddress('  '), /中继地址不能为空/);
  // A key must not follow the user to a different relay.
  const answers = ['8787', 'other.example.com', '', process.cwd(), ''];
  const result = await setupConfig({ agentId: 'a', secret: 's', relayUrl: 'wss://old.example.com/ws', relayKey: 'old-key' }, async () => answers.shift()!);
  assert.equal(result.relayKey, undefined);
});

test('config reset preserves preferences and malformed configuration never replaces identity', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'ct-config-'));
  try {
    const file = path.join(dir, 'agent.json');
    const initial = await loadConfig(file);
    const configured = { ...initial, connectionMode: 'local' as const, localPort: 9876, terminal: false, roots: [dir], defaultCwd: dir };
    await saveConfig(configured, file);
    const reset = await loadConfig(file, { reset: true });
    assert.notEqual(reset.agentId, initial.agentId);
    assert.notEqual(reset.secret, initial.secret);
    assert.deepEqual({ ...reset, agentId: initial.agentId, secret: initial.secret }, configured);
    for (const malformed of ['{', 'null', '[]', JSON.stringify({ ...configured, terminal: 'false' }), JSON.stringify({ ...configured, roots: [] }), JSON.stringify({ ...configured, localPort: 65536 })]) {
      await writeFile(file, malformed);
      await assert.rejects(loadConfig(file));
      assert.equal(await readFile(file, 'utf8'), malformed);
    }
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('relay key generation persists, respects explicit override and rejects empty file', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'ct-key-'));
  try {
    const file = path.join(dir, 'relay-key');
    const key = await registrationKey({ RELAY_KEY_FILE: file });
    assert.ok(key && key.length >= 32);
    assert.equal(await registrationKey({ RELAY_KEY_FILE: file }), key);
    assert.equal(await registrationKey({ RELAY_KEY_FILE: file, RELAY_KEY: 'override' }), 'override');
    assert.equal((await readFile(file, 'utf8')).trim(), key);
    assert.equal(await registrationKey({}), undefined);
    await assert.rejects(registrationKey({ RELAY_KEY: '', RELAY_KEY_FILE: file }), /RELAY_KEY must not be empty/);
    await assert.rejects(registrationKey({ RELAY_KEY: ' ' }), /RELAY_KEY must not be empty/);
    await assert.rejects(registrationKey({ RELAY_KEY_FILE: '' }), /RELAY_KEY_FILE must not be empty/);
    const concurrent = path.join(dir, 'concurrent');
    const keys = await Promise.all(Array.from({ length: 5 }, () => registrationKey({ RELAY_KEY_FILE: concurrent })));
    assert.equal(new Set(keys).size, 1);
    const empty = path.join(dir, 'empty');
    await writeFile(empty, '');
    await assert.rejects(registrationKey({ RELAY_KEY_FILE: empty }), /empty/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
