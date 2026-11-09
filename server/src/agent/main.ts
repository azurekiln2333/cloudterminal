// PC agent entrypoint.
//
//   node src/agent/main.ts --relay wss://relay.example.com/ws
//   node src/agent/main.ts --local-relay            (relay in-process, LAN / tunnel)
//
// Run `node src/agent/main.ts --help` for all options.

import { networkInterfaces, hostname, homedir } from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { parseArgs } from 'node:util';

import { createRelay } from '../relay/relay.ts';
import { randomToken } from '../shared/crypto.ts';
import { consoleLogger, type Logger } from '../shared/log.ts';
import { loadConfig, saveConfig, configPath } from './config.ts';
import { setupConfig, terminalPrompt, relayAddress, closeSetupInput } from './setup.ts';
import { AgentCore } from './core.ts';
import { CodexBridge } from './codex.ts';
import { HerdrBridge } from './herdr.ts';
import { HerdrSocketClient, HERDR_LIVE_SUBSCRIPTIONS } from './herdr-socket.ts';
import { HerdrLivePush } from './herdr-live.ts';
import { RelayLink } from './link.ts';
import { sdkHistory, sdkQueryFn } from './sdk.ts';

import { nativePty } from './pty.ts';
import { attachLocalTerminal } from './local-terminal.ts';
import type { TerminalSession } from './terminal-session.ts';

const HELP = `CloudTerminal agent — drive desktop terminals and Claude Code on this PC from your phone.

Options:
  --setup             Configure connection and startup preferences interactively.
  --no-terminal       Start without local terminal control.
  --relay <url>        Relay WebSocket URL (wss://host/ws). Saved for next time.
  --relay-key <key>    Relay registration key, if the relay requires one.
  --local-relay        (default) Run the relay inside this process for LAN use.
  --no-local-relay     Do not run the LAN relay; requires --relay.
  --port <n>           Port for the LAN relay (default 8787).
  --public-url <url>   URL phones should use, shown in the pairing banner.
  --root <dir>         Directory sessions may use (repeatable, default: home).
  --cwd <dir>          Default working directory offered to the phone.
  --terminal          Start and locally control a shared shell (Ctrl-] detaches).
  --name <name>        Name shown on the phone (default: hostname).
  --allow-bypass       Allow the phone to pick bypassPermissions mode.
  --claude-path <p>    Path to the claude executable (default: SDK bundled).
  --herdr-path <p>     Path to the herdr executable (default: auto-detected).
  --no-herdr           Do not connect to the local Herdr workspace manager.
  --reset-pairing      Generate a new identity; all paired phones must re-pair.
  -h, --help           Show this help.

Press Enter while running to print a new one-time pairing code.`;

const { values } = parseArgs({
  options: {
    setup: { type: 'boolean' },
    'no-terminal': { type: 'boolean' },
    relay: { type: 'string' },
    'relay-key': { type: 'string' },
    'local-relay': { type: 'boolean' },
    'no-local-relay': { type: 'boolean' },
    port: { type: 'string' },
    'public-url': { type: 'string' },
    root: { type: 'string', multiple: true },
    cwd: { type: 'string' },
    name: { type: 'string' },
    terminal: { type: 'boolean' },
    'allow-bypass': { type: 'boolean' },
    'claude-path': { type: 'string' },
    'herdr-path': { type: 'string' },
    'no-herdr': { type: 'boolean' },
    'reset-pairing': { type: 'boolean' },
    sidecar: { type: 'boolean' },
    help: { type: 'boolean', short: 'h' },
  },
});

if (values.sidecar) {
  // The Windows assistant runs the sidecar, which shares this process's
  // config and relay link but speaks a local JSON protocol instead of a TUI.
  await import('./sidecar.ts');
  // sidecar.ts never returns; keep the process alive on its servers.
  await new Promise<never>(() => {});
}

if (values.help) {
  console.log(HELP);
  process.exit(0);
}

let attached = false;
const baseLog = consoleLogger('agent');
const log: Logger = {
  info: (message, fields) => { if (!attached) baseLog.info(message, fields); },
  warn: (message, fields) => { if (!attached) baseLog.warn(message, fields); },
  error: (message, fields) => { if (!attached) baseLog.error(message, fields); },
};
let config = await loadConfig(configPath(), { reset: values['reset-pairing'] });
if (values.setup || (!config.connectionMode && !config.relayUrl && values.relay === undefined && !values['local-relay'] && process.env.CLOUDTERMINAL_RELAY === undefined)) {
  try {
    config = await setupConfig(config, terminalPrompt);
    await saveConfig(config);
    console.log('设置已保存，下次直接运行启动脚本即可。');
  } catch (err) { closeSetupInput(); console.error(err instanceof Error ? err.message : String(err)); process.exit(1); }
  closeSetupInput();
}
const preferences = { ...config };
if (values['local-relay']) preferences.connectionMode = 'local';
else if (values.relay !== undefined) preferences.connectionMode = 'remote';
if (values.relay !== undefined) {
  preferences.relayUrl = relayAddress(values.relay);
  if (preferences.relayUrl !== config.relayUrl) preferences.relayKey = undefined;
}
if (values['relay-key'] !== undefined) {
  const temporaryRelay = !values['local-relay'] && values.relay === undefined && process.env.CLOUDTERMINAL_RELAY !== undefined
    ? relayAddress(process.env.CLOUDTERMINAL_RELAY) : undefined;
  // A key supplied for a temporary environment target must not replace the
  // credential belonging to a different saved server.
  if (!temporaryRelay || (preferences.relayUrl && temporaryRelay === relayAddress(preferences.relayUrl))) preferences.relayKey = values['relay-key'];
}
if (values.root?.length) preferences.roots = values.root.map((r) => path.resolve(r));
if (values.cwd) preferences.defaultCwd = path.resolve(values.cwd);
if (values.terminal !== undefined) preferences.terminal = values.terminal;
if (values['no-terminal']) preferences.terminal = false;
if (values.port !== undefined) preferences.localPort = Number(values.port);
if (values['herdr-path'] !== undefined) preferences.herdrPath = path.resolve(values['herdr-path']);
if (values['no-herdr']) preferences.herdrPath = undefined;
if (preferences.localPort !== undefined && (!Number.isInteger(preferences.localPort) || preferences.localPort < 1 || preferences.localPort > 65535)) throw new Error('端口必须为 1–65535');
if (JSON.stringify(preferences) !== JSON.stringify(config)) await saveConfig(preferences);
config = preferences;
values.terminal = config.terminal;
if (values.terminal && (!process.stdin.isTTY || !process.stdout.isTTY)) {
  console.error('共享终端需要交互式桌面终端；后台运行可加 --no-terminal');
  process.exit(1);
}
const useLocalRelay = !values['no-local-relay'];
// Precedence: explicit flag, then environment, then saved config. A malformed
// value from the environment is ignored (it is often a leftover shell export),
// but a malformed --relay is the user's current intent and must be rejected.
const envRelay = process.env.CLOUDTERMINAL_RELAY;
let remoteRelayUrl: string | undefined;
if (values.relay !== undefined) remoteRelayUrl = relayAddress(values.relay);
else if (envRelay) {
  try { remoteRelayUrl = relayAddress(envRelay); }
  catch { log.warn('ignoring malformed CLOUDTERMINAL_RELAY', { value: envRelay }); }
} else if (config.relayUrl) remoteRelayUrl = relayAddress(config.relayUrl);
// An environment URL is temporary and must not forward a saved key to a
// different server. Explicit CLI/environment keys still take precedence.
const savedRelayKey = remoteRelayUrl && config.relayUrl && remoteRelayUrl === relayAddress(config.relayUrl) ? config.relayKey : undefined;
const relayRegistrationKey = values['relay-key'] ?? process.env.CLOUDTERMINAL_RELAY_KEY ?? savedRelayKey;
let localRelay: ReturnType<typeof createRelay> | undefined;
let localRelayUrl: string | undefined;
let lanRelayUrl: string | undefined;

// Only this process may register on its own relay; phones still need the
// pairing secret. Without a key, anything on the LAN could park agents here.
const localRelayKey = randomToken(24);

// The LAN entry is always on: it is the zero-configuration path and works
// without any server. A configured relay URL adds the public entry on top
// instead of replacing it.
if (useLocalRelay) {
  const port = config.localPort ?? 8787;
  localRelay = createRelay({ logger: log, relayKey: localRelayKey });
  try {
    await localRelay.listen(port, '0.0.0.0');
  } catch (err) {
    // Fail loudly: silently picking another port would invalidate the address
    // already saved on paired phones.
    console.error(
      `局域网入口无法监听端口 ${port}：${err instanceof Error ? err.message : String(err)}\n` +
        `该端口可能已被占用。换一个端口：start.cmd --port <端口>，或加 --no-local-relay 只用中继。`,
    );
    process.exit(1);
  }
  localRelayUrl = `ws://127.0.0.1:${port}/ws`;
  lanRelayUrl = `ws://${lanAddress() ?? 'localhost'}:${port}/ws`;
}

if (!useLocalRelay && !remoteRelayUrl) {
  console.error('已禁用局域网入口，但又没有中继地址。请加 --relay wss://你的服务器/ws，或去掉 --no-local-relay。\n\n' + HELP);
  process.exit(1);
}

const publicUrl = values['public-url'] ?? lanRelayUrl ?? remoteRelayUrl;

const roots = (config.roots?.length ? config.roots : [homedir()]).map((r) => path.resolve(r));
const defaultCwd = path.resolve(config.defaultCwd ?? process.cwd());

// Live push: structure events go straight from the socket to the phone, and the
// selected pane's content is read over the same socket on a short tick. Both are
// optional — if the socket is unavailable the agent behaves exactly as before and
// the phone falls back to its own refresh.
const herdrBridge = values['no-herdr']
  ? undefined
  : new HerdrBridge({ binary: values['herdr-path'] ?? config.herdrPath, logger: log });
const herdrSocket = herdrBridge ? new HerdrSocketClient({ socketPath: () => resolveHerdrSocket(), logger: log }) : undefined;
const herdrLive = herdrBridge && herdrSocket
  ? new HerdrLivePush({
      bridge: herdrBridge,
      socket: herdrSocket,
      socketPath: () => resolveHerdrSocket(),
      emit: (message) => fanoutHerdr(message),
      logger: log,
    })
  : undefined;

/**
 * The socket path Herdr is listening on, or undefined when it is not running.
 *
 * Read from `herdr status --json` so a moved/renamed socket is followed without
 * a config change.
 */
async function resolveHerdrSocket(): Promise<string | undefined> {
  return herdrBridge ? await herdrBridge.socketPath() : undefined;
}

/**
 * Emits a Herdr push into every connected relay link.
 *
 * A forwarder rather than a direct `core.fanout` reference because `core` is
 * constructed below; the first push cannot happen before it exists.
 */
function fanoutHerdr(message: Parameters<AgentCore['fanout']>[0]): void {
  core.fanout(message);
}

const core = new AgentCore({
  codex: new CodexBridge(),
  herdr: herdrBridge,
  herdrLive,
  ptyFactory: nativePty,
  queryFn: sdkQueryFn((line) => log.warn('claude stderr', { line: line.trimEnd() })),
  roots,
  defaultCwd,
  allowBypass: values['allow-bypass'] === true,
  claudePath: values['claude-path'] ?? process.env.CLOUDTERMINAL_CLAUDE_PATH,
  history: sdkHistory,
  logger: log,
});

// Started after `core` exists (the push emits through it). A subscription attempt
// against a missing socket is harmless: the client logs and backs off, and a socket
// that appears later is picked up by its own reconnect loop.
if (herdrLive && herdrSocket) {
  herdrLive.start();
  void herdrSocket.start(HERDR_LIVE_SUBSCRIPTIONS);
}

// One link per entry. The LAN link is the primary: its pairing codes are the
// ones shown in the banner, because it is always available and is what a phone
// on the same network uses.
const links: RelayLink[] = [];
let firstOnline = true;
// The link that actually came online is the one that can mint a pairing code;
// picking links[0] blindly would fail when the other entry wins the race.
let activeLink: RelayLink | undefined;
const anyOnline = (link: RelayLink) => {
  activeLink ??= link;
  if (!firstOnline) return;
  firstOnline = false;
  void printPairing().then(() => startLocalTerminal());
};
const onPaired = () => { if (!attached) console.log('\n✓ 手机已配对。按回车可生成新的配对码。\n'); };

if (localRelayUrl) {
  const local = new RelayLink({
    url: localRelayUrl,
    agentId: config.agentId,
    secret: config.secret,
    relayKey: localRelayKey,
    name: values.name ?? hostname(),
    core,
    logger: log,
    onOnline: () => anyOnline(local),
    onPaired,
  });
  links.push(local);
}

if (remoteRelayUrl) {
  const remote = new RelayLink({
    url: remoteRelayUrl,
    agentId: config.agentId,
    secret: config.secret,
    relayKey: relayRegistrationKey,
    name: values.name ?? hostname(),
    core,
    logger: log,
    onOnline: () => anyOnline(remote),
    onPaired,
  });
  links.push(remote);
}

for (const l of links) l.start();

// Probe once at startup so the operator log states whether Herdr is usable.
void core.herdrAvailability().then((a) => {
  if (!a) return;
  if (a.available) log.info('herdr available', { version: a.version, protocol: a.protocol });
  else log.info('herdr unavailable', { installed: a.installed, reason: a.reason });
});

// Only the public entry needs TLS; a LAN entry legitimately uses ws://.
if (remoteRelayUrl && remoteRelayUrl.startsWith('ws://') && !/^ws:\/\/(127\.|localhost|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(remoteRelayUrl)) {
  log.warn('relay URL is not encrypted (ws://); use wss:// behind TLS for internet access');
}
if (!defaultCwdAllowed()) log.warn('default cwd is outside --root; the phone will need to pick a directory', { defaultCwd });

async function printPairing(): Promise<void> {
  // The LAN entry is always present, so its code is the one to show; the
  // public entry is listed for reference (a phone outdoors needs that URL).
  const primary = activeLink ?? links[0];
  if (!primary) return;
  try {
    const code = await primary.requestPairCode();
    const mins = Math.round((code.expiresAt - Date.now()) / 60_000);
    const entries: string[] = [];
    if (lanRelayUrl) entries.push(`│ 局域网：    ${lanRelayUrl}`);
    if (remoteRelayUrl) entries.push(`│ 外网：      ${remoteRelayUrl}`);
    if (!entries.length) entries.push(`│ 服务器地址：${publicUrl}`);
    console.log(
      [
        '',
        '┌──────────────────── 手机配对 ────────────────────',
        ...entries,
        `│ 配对码：    ${code.display}   （${mins} 分钟内有效，仅可使用一次）`,
        '│',
        `│ 也可手动填写：设备 ID ${config.agentId}`,
        `│              密钥见 ${configPath()}`,
        '└──────────────────────────────────────────────────',
        '',
      ].join('\n'),
    );
  } catch (err) {
    log.warn('could not create pairing code', { err: (err as Error).message });
  }
}

function defaultCwdAllowed(): boolean {
  return roots.some((r) => {
    const rel = path.relative(r, defaultCwd);
    return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
  });
}

function lanAddress(): string | undefined {
  for (const list of Object.values(networkInterfaces())) {
    for (const a of list ?? []) {
      if (a.family === 'IPv4' && !a.internal) return a.address;
    }
  }
  return undefined;
}

let localSession: TerminalSession | undefined;
let detachLocal: (() => void) | undefined;
let pairingInput: ReturnType<typeof createInterface> | undefined;
let stopDetachedInput: (() => void) | undefined;
function readPairingInput(): void {
  if (!process.stdin.isTTY) return;
  if (values.terminal) {
    let line = '';
    const input = process.stdin;
    if (!input.isRaw) input.setRawMode(true);
    input.setEncoding('utf8');
    const data = (chunk: string) => {
      for (const char of chunk) {
        if (char === '\x03') { shutdown(); return; }
        if (char === '\r' || char === '\n') {
          process.stdout.write('\r\n');
          const command = line.trim(); line = '';
          if (command === 'attach' && localSession?.status !== 'closed') {
            queueMicrotask(attachTerminal);
            return;
          }
          void printPairing();
        } else if (char === '\x7f' || char === '\b') {
          if (line.length) { line = line.slice(0, -1); process.stdout.write('\b \b'); }
        } else if (char >= ' ') { line += char; process.stdout.write(char); }
      }
    };
    input.on('data', data);
    input.resume();
    stopDetachedInput = () => { input.removeListener('data', data); };
    return;
  }
  pairingInput = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  pairingInput.on('SIGINT', () => shutdown());
  pairingInput.on('line', (line) => {
    if (line.trim() === 'attach' && localSession?.status !== 'closed' && localSession) attachTerminal();
    else void printPairing();
  });
}
function attachTerminal(): void {
  if (!localSession || attached) return;
  pairingInput?.close();
  stopDetachedInput?.();
  stopDetachedInput = undefined;
  if (process.stdin.isTTY && !process.stdin.isRaw) process.stdin.setRawMode(true);
  attached = true;
  detachLocal = attachLocalTerminal(localSession, () => {
    attached = false;
    console.log('\r\n已离开本地终端控制，手机仍可连接。输入 attach 回车重新控制；回车生成配对码；Ctrl-C 退出。');
    if (!shuttingDown) readPairingInput();
  });
}
async function startLocalTerminal(): Promise<void> {
  if (!values.terminal) return;
  try {
    console.log('共享终端即将启动，Ctrl-] 离开本地控制。配对码可在离开后重新生成。');
    localSession = await core.createTerminal(defaultCwd, Math.max(2, Math.min(500, process.stdout.columns || 80)), Math.max(1, Math.min(300, process.stdout.rows || 24)));
    attachTerminal();
  } catch (err) {
    log.error('could not start local terminal', { error: String(err) });
    readPairingInput();
  }
}
if (!values.terminal) readPairingInput();

let shuttingDown = false;
const shutdown = () => {
  if (shuttingDown) return;
  shuttingDown = true;
  detachLocal?.();
  stopDetachedInput?.();
  pairingInput?.close();
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
  log.info('shutting down');
  void core.closeAll().catch((err) => log.warn('terminal cleanup failed', { error: String(err) })).then(async () => {
    await herdrLive?.close().catch(() => {});
    await herdrSocket?.close().catch(() => {});
    for (const l of links) l.stop();
    await localRelay?.close();
    process.exit(0);
  });
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
