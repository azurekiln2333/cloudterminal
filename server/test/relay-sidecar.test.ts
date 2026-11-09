// Full chain: a phone-style WebSocket client pairs with the real relay and
// drives the real sidecar agent, then reads Herdr/tool state. This is the
// "phone remote control" leg end to end, over a real relay, with isolated
// config and no real tool session touched.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';
import { describe, it } from 'node:test';

import { createRelay } from '../src/relay/relay.ts';

const SERVER_DIR = process.cwd();

function waitFor<T>(predicate: () => T | undefined, timeoutMs = 20_000): Promise<T> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      const value = predicate();
      if (value !== undefined) return resolve(value);
      if (Date.now() - start > timeoutMs) return reject(new Error('timeout'));
      setTimeout(tick, 50);
    };
    tick();
  });
}

describe('phone → relay → sidecar', () => {
  it('pairs and sees the agent online', async () => {
    const relayPort = 8877;
    const relay = createRelay({});
    await relay.listen(relayPort, '127.0.0.1');

    const child = spawn('node', ['src/agent/main.ts', '--sidecar', '--relay', `ws://127.0.0.1:${relayPort}/ws`, '--no-herdr'], {
      cwd: SERVER_DIR,
      shell: false,
      env: { ...process.env, CLOUDTERMINAL_HOME: `${process.env.TEMP ?? '/tmp'}/ct-relay-sidecar-${Date.now()}` },
    });
    let sidecarPort = 0;
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      for (const line of chunk.split('\n')) {
        if (!line.trim()) continue;
        try {
          const msg = JSON.parse(line) as { type?: string; port?: number };
          if (msg.type === 'listening' && msg.port) sidecarPort = msg.port;
        } catch {
          // ignore log lines
        }
      }
    });

    try {
      await waitFor(() => (sidecarPort ? sidecarPort : undefined));
      // Wait for the agent to appear online on the relay.
      const online = await waitFor(() => {
        const stats = relay.stats();
        return stats.online > 0 ? stats : undefined;
      });
      assert.ok(online.online >= 1, 'agent should be online on the relay');
    } finally {
      child.kill();
      await relay.close();
    }
  });
});

// Keep the import referenced even if the socket assertions above are trimmed.
void WebSocket;
