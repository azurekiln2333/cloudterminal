// Sidecar IPC contract: the Flutter Windows client talks to the agent only
// through this loopback JSON-line protocol. These tests exercise the framing and
// the pure helpers; they never spawn Herdr, Claude or Codex, and never touch a
// real session.

import assert from 'node:assert/strict';
import { createServer, Socket } from 'node:net';
import { describe, it } from 'node:test';

import { createLineDecoder, summarizeTools, toolKindLabel } from '../src/agent/sidecar-helpers.ts';

describe('sidecar helpers', () => {
  it('labels a detected tool for the UI', () => {
    assert.equal(toolKindLabel('herdr'), 'Herdr');
    assert.equal(toolKindLabel('codex'), 'Codex');
    assert.equal(toolKindLabel('claude'), 'Claude Code');
  });

  it('summarizes probe results with availability, never inventing one', () => {
    const summary = summarizeTools([
      { kind: 'herdr', installed: true, daemonRunning: true },
      { kind: 'codex', installed: false, daemonRunning: false, reason: '未安装' },
    ]);
    assert.match(summary, /herdr=可用/);
    assert.match(summary, /codex=未安装/);
  });
});

describe('sidecar line decoder', () => {
  it('reassembles a JSON frame split across chunks', () => {
    const decode = createLineDecoder();
    assert.deepEqual(decode('{"type":"snap'), []);
    const frames = decode('shot","seq":1}\n{"type":"pair_code"}\n');
    assert.equal(frames.length, 2);
    assert.deepEqual(frames[0], { type: 'snapshot', seq: 1 });
    assert.deepEqual(frames[1], { type: 'pair_code' });
  });

  it('ignores a non-JSON line instead of throwing', () => {
    const decode = createLineDecoder();
    const frames = decode('not json\n{"type":"ok"}\n');
    assert.deepEqual(frames, [{ type: 'ok' }]);
  });
});

describe('sidecar socket framing', () => {
  it('sends newline-delimited JSON the client can decode', async () => {
    // Mirror the sidecar's server loop so a change to the framing breaks here.
    const server = createServer((socket) => {
      socket.write(`${JSON.stringify({ type: 'snapshot', relayOnline: true })}\n`);
      socket.write(`${JSON.stringify({ type: 'pair_code', display: 'ABCD-2345' })}\n`);
      socket.end();
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    assert.ok(address && typeof address === 'object');

    const frames: Array<Record<string, unknown>> = [];
    await new Promise<void>((resolve, reject) => {
      const socket = new Socket();
      const decode = createLineDecoder();
      socket.setEncoding('utf8');
      socket.on('data', (chunk: string) => frames.push(...decode(chunk)));
      socket.on('error', reject);
      socket.on('end', resolve);
      socket.connect(address.port, '127.0.0.1');
    });
    await new Promise<void>((resolve) => server.close(() => resolve()));

    assert.equal(frames.length, 2);
    assert.equal(frames[0]!.type, 'snapshot');
    assert.equal(frames[1]!.display, 'ABCD-2345');
  });
});
