// Sidecar entrypoint for the Flutter Windows connection assistant.
//
// It runs the SAME agent core + relay link as `main.ts` (no rewrite of the
// handshake, pairing or reconnect logic), but instead of a terminal UI it
// serves a small loopback-only JSON-line protocol over a local socket. The
// Flutter app connects to that socket; it never talks to the relay itself.
//
//   node src/agent/main.ts --sidecar
//
// On stdout it prints exactly one line first, `{"type":"listening","port":N}`,
// then stays quiet on stdout. All state flows over the local socket.

import { createServer, type Server, type Socket } from 'node:net';
import { hostname } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { createRelay } from '../relay/relay.ts';
import { randomToken } from '../shared/crypto.ts';
import { consoleLogger, type Logger } from '../shared/log.ts';
import { type AgentMessage, type ClientMessage } from '../shared/protocol.ts';
import { loadConfig, saveConfig, configPath } from './config.ts';
import { loadBootstrap } from './bootstrap.ts';
import { relayAddress } from './setup.ts';
import { AgentCore } from './core.ts';
import { CodexBridge } from './codex.ts';
import { HerdrBridge } from './herdr.ts';
import { RelayLink } from './link.ts';
import { sdkHistory, sdkQueryFn } from './sdk.ts';
import { nativePty } from './pty.ts';
import { probeTools, type ToolProbeResult } from './tool-probe.ts';
import { createToolStreams, type ToolStreams } from './tool-streams.ts';

const { values } = parseArgs({
  options: {
    sidecar: { type: 'boolean' },
    relay: { type: 'string' },
    'relay-key': { type: 'string' },
    'local-relay': { type: 'boolean' },
    port: { type: 'string' },
    'public-url': { type: 'string' },
    root: { type: 'string', multiple: true },
    cwd: { type: 'string' },
    name: { type: 'string' },
    'claude-path': { type: 'string' },
    'herdr-path': { type: 'string' },
    'no-herdr': { type: 'boolean' },
    'reset-pairing': { type: 'boolean' },
  },
});

const log: Logger = consoleLogger('sidecar');

let config = await loadConfig(configPath(), { reset: values['reset-pairing'] });
const preferences = { ...config };
if (values.relay !== undefined) preferences.relayUrl = relayAddress(values.relay);
if (values['relay-key'] !== undefined) preferences.relayKey = values['relay-key'];
if (values.root?.length) preferences.roots = values.root.map((r) => path.resolve(r));
if (values.cwd) preferences.defaultCwd = path.resolve(values.cwd);
if (values.port !== undefined) preferences.localPort = Number(values.port);
if (values['herdr-path'] !== undefined) preferences.herdrPath = path.resolve(values['herdr-path']);
if (values['no-herdr']) preferences.herdrPath = undefined;
if (JSON.stringify(preferences) !== JSON.stringify(config)) await saveConfig(preferences);
config = preferences;

const useLocalRelay = values['local-relay'] || (values.relay === undefined && process.env.CLOUDTERMINAL_RELAY === undefined && config.connectionMode === 'local');

// Lowest-priority relay source: the shipped bootstrap config. It never
// overrides an explicit flag, env var or saved agent.json.
const bootstrap = await loadBootstrap(process.cwd());
let relayUrl = useLocalRelay
  ? undefined
  : values.relay ?? process.env.CLOUDTERMINAL_RELAY ?? config.relayUrl ?? bootstrap.value.relayUrl;
if (relayUrl !== undefined) relayUrl = relayAddress(relayUrl);
const relayRegistrationKey =
  values['relay-key'] ?? process.env.CLOUDTERMINAL_RELAY_KEY ?? config.relayKey ?? bootstrap.value.relayKey;
let publicUrl = values['public-url'];
let localRelay: ReturnType<typeof createRelay> | undefined;
const localRelayKey = randomToken(24);

if (useLocalRelay) {
  const relayPort = config.localPort ?? 8787;
  localRelay = createRelay({ logger: log, relayKey: localRelayKey });
  await localRelay.listen(relayPort, '0.0.0.0');
  relayUrl = `ws://127.0.0.1:${relayPort}/ws`;
  publicUrl ??= relayUrl;
}

const roots = (config.roots?.length ? config.roots : [process.cwd()]).map((r) => path.resolve(r));
const defaultCwd = path.resolve(config.defaultCwd ?? process.cwd());

const core = new AgentCore({
  codex: new CodexBridge(),
  herdr: values['no-herdr'] ? undefined : new HerdrBridge({ binary: values['herdr-path'] ?? config.herdrPath, logger: log }),
  ptyFactory: nativePty,
  queryFn: sdkQueryFn((line) => log.warn('claude stderr', { line: line.trimEnd() })),
  roots,
  defaultCwd,
  claudePath: values['claude-path'] ?? process.env.CLOUDTERMINAL_CLAUDE_PATH,
  history: sdkHistory,
  logger: log,
});

type Client = {
  socket: Socket;
  buffer: string;
};

const clients = new Set<Client>();
let retries = 0;
let lastError: string | undefined;
let seq = 0;
let tools: ToolProbeResult[] = [];
let pairCode: { display: string; uri: string; expiresAt: number } | undefined;

const streams: ToolStreams = createToolStreams({
  emit: (event) => broadcast({ type: 'stream_event', seq: ++seq, ...event }),
  logger: log,
  roots,
  defaultCwd,
});

function buildPairUri(display: string, expiresAt: number): string {
  const relay = publicUrl ?? relayUrl ?? '';
  const params = new URLSearchParams({ relay, code: display.replace('-', ''), v: '1' });
  return `cloudterminal://pair?${params.toString()}`;
}

function snapshot(): Record<string, unknown> {
  return {
    type: 'snapshot',
    seq: ++seq,
    relayOnline: link.isOnline,
    relayUrl: publicUrl ?? relayUrl,
    retries,
    lastError,
    pairedClients: 0,
    tools,
    bindings: streams.bindings(),
  };
}

function broadcast(frame: Record<string, unknown>): void {
  const line = `${JSON.stringify(frame)}\n`;
  for (const client of clients) {
    if (!client.socket.destroyed) client.socket.write(line);
  }
}

async function refreshTools(): Promise<void> {
  tools = await probeTools({ herdrPath: config.herdrPath });
  broadcast(snapshot());
}

async function refreshPairCode(): Promise<void> {
  if (!link.isOnline) return;
  const code = await link.requestPairCode().catch((err: unknown) => {
    lastError = err instanceof Error ? err.message : String(err);
    return undefined;
  });
  if (!code) {
    broadcast(snapshot());
    return;
  }
  pairCode = { display: code.display, uri: buildPairUri(code.display, code.expiresAt), expiresAt: code.expiresAt };
  broadcast({ type: 'pair_code', seq: ++seq, ...pairCode });
}

const link = new RelayLink({
  url: relayUrl ?? '',
  agentId: config.agentId,
  secret: config.secret,
  relayKey: localRelay ? localRelayKey : relayRegistrationKey,
  name: values.name ?? hostname(),
  core,
  logger: log,
  onOnline: () => {
    retries = 0;
    lastError = undefined;
    void refreshTools();
    void refreshPairCode();
    broadcast(snapshot());
  },
  onOffline: (reason) => {
    retries += 1;
    lastError = reason;
    broadcast(snapshot());
  },
  onPaired: () => broadcast(snapshot()),
});
if (relayUrl) link.start();

const server: Server = createServer((socket) => {
  const client: Client = { socket, buffer: '' };
  clients.add(client);
  client.socket.write(`${JSON.stringify(snapshot())}\n`);
  if (pairCode) client.socket.write(`${JSON.stringify({ type: 'pair_code', ...pairCode })}\n`);

  socket.setEncoding('utf8');
  socket.on('data', (chunk: string) => {
    client.buffer += chunk;
    let index = client.buffer.indexOf('\n');
    while (index >= 0) {
      const line = client.buffer.slice(0, index);
      client.buffer = client.buffer.slice(index + 1);
      handle(line, client);
      index = client.buffer.indexOf('\n');
    }
  });
  socket.on('close', () => clients.delete(client));
  socket.on('error', () => clients.delete(client));
});

function handle(line: string, client: Client): void {
  const text = line.trim();
  if (!text) return;
  let message: Record<string, unknown>;
  try {
    message = JSON.parse(text) as Record<string, unknown>;
  } catch {
    client.socket.write(`${JSON.stringify({ type: 'error', message: '无效的请求' })}\n`);
    return;
  }
  void dispatchSidecar(message, client);
}

async function dispatchSidecar(message: Record<string, unknown>, client: Client): Promise<void> {
  const reply = (frame: Record<string, unknown>) =>
    client.socket.write(`${JSON.stringify({ ...frame, seq: ++seq })}\n`);
  try {
    switch (message.type) {
      case 'pair_code':
        await refreshPairCode();
        break;
      case 'reset_pairing':
        // Regenerate identity; every paired phone must re-pair.
        await core.closeAll();
        link.stop();
        await saveConfig({ ...config, agentId: `a_${randomToken(12)}`, secret: randomToken(32) });
        reply({ type: 'error', message: '已重置身份，请重启助手以使用新身份。' });
        break;
      case 'tool_probe':
        await refreshTools();
        break;
      case 'tool_bind':
        await streams.bind(String(message.id ?? ''));
        broadcast(snapshot());
        break;
      case 'tool_start_managed': {
        const kind = String(message.kind ?? 'claude');
        if (kind !== 'claude') {
          reply({ type: 'error', message: '当前只支持启动 Claude 托管会话。' });
          break;
        }
        const id = await streams.startManagedClaude(
          typeof message.prompt === 'string' ? message.prompt : undefined,
        );
        broadcast(snapshot());
        reply({ type: 'managed_started', id });
        break;
      }
      case 'tool_unbind':
        await streams.unbind(String(message.id ?? ''));
        broadcast(snapshot());
        break;
      case 'tool_input':
        await streams.input(String(message.id ?? ''), String(message.text ?? ''));
        break;
      case 'tool_poll_interval':
        await streams.setPollInterval(String(message.id ?? ''), Number(message.intervalMs ?? 1000));
        broadcast(snapshot());
        break;
      case 'set_relay': {
        const clear = message.clear === true;
        const url = typeof message.url === 'string' ? message.url.trim() : '';
        const key = typeof message.key === 'string' ? message.key.trim() : undefined;
        if (clear) {
          await saveConfig({ ...config, relayUrl: undefined, relayKey: undefined, connectionMode: undefined });
          reply({ type: 'error', message: '已清除中继地址，请重启助手以切换为局域网模式。' });
          break;
        }
        try {
          const resolved = relayAddress(url);
          config = { ...config, relayUrl: resolved, relayKey: key || (url ? undefined : config.relayKey) };
          await saveConfig(config);
          reply({ type: 'error', message: '中继地址已保存，请重启助手以连接新的中继。' });
        } catch (err) {
          reply({ type: 'error', message: err instanceof Error ? err.message : '中继地址无效' });
        }
        break;
      }
      default:
        reply({ type: 'error', message: `未知请求：${String(message.type)}` });
    }
  } catch (err) {
    reply({ type: 'error', message: err instanceof Error ? err.message : String(err) });
  }
}

await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
const port = typeof address === 'object' && address ? address.port : 0;
process.stdout.write(`${JSON.stringify({ type: 'listening', port })}\n`);
if (relayUrl) log.info('sidecar listening', { port, relay: publicUrl ?? relayUrl });
else log.warn('sidecar started without a relay; set one in the app');

// The agent still reads its own messages; ignore inbound core messages the
// sidecar does not surface yet.
core.setEmitter((_msg: AgentMessage, _to?: string) => {});

let stopping = false;
async function shutdown(): Promise<void> {
  if (stopping) return;
  stopping = true;
  await streams.close();
  await core.closeAll();
  link.stop();
  await localRelay?.close();
  server.close();
  process.exit(0);
}
process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());

// Bridge the relay link's core messages so a future feature can surface them.
export type { ClientMessage };
