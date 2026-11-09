// Bootstrap config: the client's lowest-priority relay source. Tests must never
// read a real user file, so every case points CLOUDTERMINAL_BOOTSTRAP at a temp
// file it creates and removes.

import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, it } from 'node:test';

import { loadBootstrap } from '../src/agent/bootstrap.ts';

const dirs: string[] = [];

async function writeBootstrap(content: string): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), 'ct-bootstrap-'));
  dirs.push(dir);
  const file = path.join(dir, 'bootstrap.json');
  await writeFile(file, content, 'utf8');
  return file;
}

after(async () => {
  for (const dir of dirs) await rm(dir, { recursive: true, force: true });
  delete process.env.CLOUDTERMINAL_BOOTSTRAP;
});

describe('bootstrap config', () => {
  it('reads a valid relay URL and registration key', async () => {
    process.env.CLOUDTERMINAL_BOOTSTRAP = await writeBootstrap(
      JSON.stringify({ relayUrl: 'wss://relay.example.com/ws', relayKey: 'secret', invite: 'ABCD-2345' }),
    );
    const result = await loadBootstrap(process.cwd());
    assert.equal(result.value.relayUrl, 'wss://relay.example.com/ws');
    assert.equal(result.value.relayKey, 'secret');
    assert.equal(result.value.invite, 'ABCD-2345');
    assert.equal(result.error, undefined);
  });

  it('reports a malformed file instead of throwing', async () => {
    process.env.CLOUDTERMINAL_BOOTSTRAP = await writeBootstrap('{ not json');
    const result = await loadBootstrap(process.cwd());
    assert.match(result.error ?? '', /无法解析/);
    assert.equal(result.value.relayUrl, undefined);
  });

  it('reports an invalid relay URL without inventing one', async () => {
    process.env.CLOUDTERMINAL_BOOTSTRAP = await writeBootstrap(JSON.stringify({ relayUrl: 'not a url' }));
    const result = await loadBootstrap(process.cwd());
    assert.match(result.error ?? '', /中继地址无效/);
    assert.equal(result.value.relayUrl, undefined);
  });

  it('returns an empty value when no file exists', async () => {
    process.env.CLOUDTERMINAL_BOOTSTRAP = path.join(tmpdir(), 'ct-does-not-exist-12345.json');
    const result = await loadBootstrap(process.cwd());
    assert.deepEqual(result.value, {});
    assert.equal(result.error, undefined);
  });
});
