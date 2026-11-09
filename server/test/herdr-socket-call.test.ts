import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer, type Socket } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test, type TestContext } from 'node:test';

import {
  FrameSplitter,
  HerdrSocketError,
  herdrSocketCall,
  socketTarget,
} from '../src/agent/herdr-socket.ts';

async function serve(t: TestContext, accept: (socket: Socket) => void) {
  const id = `ct-herdr-test-${randomUUID()}`;
  const endpoint = process.platform === 'win32' ? id : path.join(tmpdir(), `${id}.sock`);
  const clients = new Set<Socket>();
  const server = createServer((socket) => {
    clients.add(socket);
    socket.once('close', () => clients.delete(socket));
    socket.on('error', () => {});
    accept(socket);
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(socketTarget(endpoint), resolve);
  });
  t.after(async () => {
    for (const client of clients) client.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  return endpoint;
}

test('UTF-8 frame decoding preserves every byte boundary of Chinese and emoji', () => {
  const expected = { id: 'ct1', result: { text: '空格 中文🙂𠮷\r\n' } };
  const encoded = Buffer.from(`${JSON.stringify(expected)}\n`);
  for (let boundary = 1; boundary < encoded.length; boundary++) {
    const splitter = new FrameSplitter();
    assert.deepEqual(splitter.push(encoded.subarray(0, boundary)), []);
    assert.deepEqual(splitter.push(encoded.subarray(boundary)), [expected]);
  }
  const splitter = new FrameSplitter();
  splitter.push(Buffer.from([0xe4]));
  splitter.reset();
  assert.deepEqual(splitter.push(encoded), [expected], 'a reconnect discards incomplete UTF-8');
});

test('short socket request preserves terminal bytes and waits for its own reply', async (t) => {
  const text = '  中文🙂\t\r\n\x7f\x1b[A\x03\x00  ';
  const requests: unknown[] = [];
  let connections = 0;
  const endpoint = await serve(t, (socket) => {
    connections++;
    const splitter = new FrameSplitter();
    socket.on('data', (data: Buffer) => {
      for (const request of splitter.push(data)) {
        requests.push(request);
        socket.write(`${JSON.stringify({ event: 'pane_updated', data: {} })}\n`);
        socket.write(`${JSON.stringify({ id: 'unrelated', error: { code: 'wrong', message: 'wrong reply' } })}\n`);
        socket.end(`${JSON.stringify({ id: 'ct1', result: { type: 'ok' } })}\n`);
      }
    });
  });
  assert.deepEqual(await herdrSocketCall(endpoint, 'pane.send_text', { pane_id: 'wJ:p2', text }), {
    id: 'ct1', result: { type: 'ok' },
  });
  assert.deepEqual(requests, [{ id: 'ct1', method: 'pane.send_text', params: { pane_id: 'wJ:p2', text } }]);
  assert.equal(connections, 1);
});

test('remote input error codes and Unicode diagnostics survive transport', async (t) => {
  for (const code of ['pane_not_found', 'pane_send_failed']) {
    const endpoint = await serve(t, (socket) => {
      socket.once('data', () => socket.end(`${JSON.stringify({
        id: 'ct1', error: { code, message: '面板已关闭🙂' },
      })}\n`));
    });
    await assert.rejects(herdrSocketCall(endpoint, 'pane.send_text', { pane_id: 'wJ:p2', text: 'x' }),
      (error: unknown) => error instanceof HerdrSocketError && error.code === code && error.message === '面板已关闭🙂');
  }
});

test('EOF before reply fails immediately and never resends terminal input', async (t) => {
  let requests = 0;
  const endpoint = await serve(t, (socket) => {
    socket.once('data', () => { requests++; socket.end(); });
  });
  await assert.rejects(herdrSocketCall(endpoint, 'pane.send_text', { text: '\r' }, 10_000),
    (error: unknown) => error instanceof HerdrSocketError && error.code === 'connection_closed');
  assert.equal(requests, 1);
});

test('a lost acknowledgment times out after one input attempt', async (t) => {
  let connections = 0;
  let requests = 0;
  const endpoint = await serve(t, (socket) => {
    connections++;
    const splitter = new FrameSplitter();
    socket.on('data', (data: Buffer) => { requests += splitter.push(data).length; });
  });
  await assert.rejects(herdrSocketCall(endpoint, 'pane.send_text', { text: 'do not repeat\r' }, 100),
    (error: unknown) => error instanceof HerdrSocketError && error.code === 'timeout');
  assert.equal(connections, 1);
  assert.equal(requests, 1);
});
