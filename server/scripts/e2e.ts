// Real end-to-end smoke test: starts the agent with --local-relay (real Agent
// SDK, real `claude`), pairs with the one-time code printed in its banner,
// runs a prompt that needs a Bash permission, approves it from "the phone"
// and waits for the result. Uses a few cents of Claude usage.
//
//   npm run e2e
//   npm run e2e -- --prompt "..." --port 8799

import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { WebSocket } from 'ws';

const { values } = parseArgs({
  options: {
    port: { type: 'string', default: '8799' },
    prompt: {
      type: 'string',
      default: 'Run the shell command `node --version` with your shell tool, then tell me the version in one short sentence.',
    },
    timeout: { type: 'string', default: '180' },
  },
});

const home = await mkdtemp(path.join(tmpdir(), 'ct-e2e-home-'));
const work = await mkdtemp(path.join(tmpdir(), 'ct-e2e-work-'));
await writeFile(path.join(work, 'README.md'), '# e2e\n');
const url = `ws://127.0.0.1:${values.port}/ws`;

const agent = spawn(
  process.execPath,
  [path.join(import.meta.dirname, '../src/agent/main.ts'), '--local-relay', '--port', values.port!, '--root', work, '--cwd', work, '--name', 'e2e'],
  { env: { ...process.env, CLOUDTERMINAL_HOME: home }, stdio: ['ignore', 'pipe', 'pipe'] },
);

let failed = false;
const deadline = setTimeout(() => finish('timed out'), Number(values.timeout) * 1000);

function finish(error?: string): void {
  clearTimeout(deadline);
  if (error) {
    failed = true;
    console.error(`\n✗ E2E FAILED: ${error}`);
  } else {
    console.log('\n✓ E2E PASSED');
  }
  agent.kill();
  void Promise.all([rm(home, { recursive: true, force: true }), rm(work, { recursive: true, force: true })]).finally(() =>
    process.exit(failed ? 1 : 0),
  );
}

agent.stderr.on('data', (d) => process.stderr.write(`[agent] ${d}`));
const code = await new Promise<string>((resolve) => {
  let buf = '';
  agent.stdout.on('data', (d: Buffer) => {
    const text = d.toString();
    process.stdout.write(text.replace(/^/gm, '[agent] '));
    buf += text;
    const m = /配对码：\s+([A-Z0-9]{4}-[A-Z0-9]{4})/.exec(buf);
    if (m) resolve(m[1]!);
  });
});
console.log(`\n→ pairing with code ${code}`);

function once(ws: WebSocket, pred: (f: any) => boolean): Promise<any> {
  return new Promise((resolve) => {
    const h = (raw: Buffer) => {
      const f = JSON.parse(raw.toString());
      if (pred(f)) {
        ws.off('message', h);
        resolve(f);
      }
    };
    ws.on('message', h);
  });
}

// 1. Pair
const pairWs = new WebSocket(url);
await new Promise((r) => pairWs.once('open', r));
pairWs.send(JSON.stringify({ t: 'hello', role: 'pair', code }));
const paired = await once(pairWs, () => true);
if (paired.t !== 'paired') finish('pairing failed: ' + JSON.stringify(paired));
console.log(`→ paired with agent ${paired.agentId} (${paired.name})`);

// 2. Connect as client
const ws = new WebSocket(url);
await new Promise((r) => ws.once('open', r));
ws.send(JSON.stringify({ t: 'hello', role: 'client', agentId: paired.agentId, secret: paired.secret }));
await once(ws, (f) => f.t === 'hello_ok');
const send = (data: unknown) => ws.send(JSON.stringify({ t: 'msg', data }));

send({ id: 'info', type: 'info' });
const info = await once(ws, (f) => f.data?.id === 'info');
console.log(`→ agent info: ${info.data.host} ${info.data.platform} cwd=${info.data.defaultCwd}`);

send({ id: 'create', type: 'create_session', cwd: work, prompt: values.prompt, mode: 'default' });
const created = await once(ws, (f) => f.data?.id === 'create');
if (created.data.kind !== 'session_created') finish('create failed: ' + JSON.stringify(created.data));
const sessionId = created.data.session.id;
send({ id: 'sub', type: 'subscribe', sessionId });

let sawPermission = false;
let sawToolResult = false;
let deltas = 0;
ws.on('message', (raw) => {
  const f = JSON.parse(raw.toString());
  const d = f.data;
  if (!d) return;
  if (d.kind === 'delta') {
    deltas++;
    return;
  }
  const events = d.kind === 'events' ? d.events : d.kind === 'event' ? [d.event] : [];
  for (const e of events) {
    console.log(`  #${e.seq} ${e.kind}: ${JSON.stringify(e).slice(0, 160)}`);
    if (e.kind === 'permission_request') {
      sawPermission = true;
      console.log(`→ approving "${e.title}" from the phone`);
      send({ id: 'perm', type: 'permission', sessionId, requestId: e.requestId, decision: 'allow' });
    }
    if (e.kind === 'tool_result') sawToolResult = true;
    if (e.kind === 'result') {
      console.log(`→ result: ${e.text} (cost $${e.costUsd.toFixed(4)}, ${deltas} streamed deltas)`);
      if (e.isError) return finish('result was an error');
      if (!sawPermission) return finish('no permission request was routed to the phone');
      if (!sawToolResult) return finish('no tool result seen');
      finish();
    }
    if (e.kind === 'error') finish(e.text);
  }
  if (d.kind === 'error') finish(d.message);
});
