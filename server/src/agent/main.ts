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
import { consoleLogger } from '../shared/log.ts';
import { loadConfig, saveConfig, configPath } from './config.ts';
import { AgentCore } from './core.ts';
import { RelayLink } from './link.ts';
import { sdkHistory, sdkQueryFn } from './sdk.ts';

const HELP = `CloudTerminal agent — drive Claude Code on this PC from your phone.

Options:
  --relay <url>        Relay WebSocket URL (wss://host/ws). Saved for next time.
  --relay-key <key>    Relay registration key, if the relay requires one.
  --local-relay        Run the relay inside this process (LAN / tunnel use).
  --port <n>           Port for --local-relay (default 8787).
  --public-url <url>   URL phones should use, shown in the pairing banner.
  --root <dir>         Directory sessions may use (repeatable, default: home).
  --cwd <dir>          Default working directory offered to the phone.
  --name <name>        Name shown on the phone (default: hostname).
  --allow-bypass       Allow the phone to pick bypassPermissions mode.
  --claude-path <p>    Path to the claude executable (default: SDK bundled).
  --reset-pairing      Generate a new identity; all paired phones must re-pair.
  -h, --help           Show this help.

Press Enter while running to print a new one-time pairing code.`;

const { values } = parseArgs({
  options: {
    relay: { type: 'string' },
    'relay-key': { type: 'string' },
    'local-relay': { type: 'boolean' },
    port: { type: 'string' },
    'public-url': { type: 'string' },
    root: { type: 'string', multiple: true },
    cwd: { type: 'string' },
    name: { type: 'string' },
    'allow-bypass': { type: 'boolean' },
    'claude-path': { type: 'string' },
    'reset-pairing': { type: 'boolean' },
    help: { type: 'boolean', short: 'h' },
  },
});

if (values.help) {
  console.log(HELP);
  process.exit(0);
}

const log = consoleLogger('agent');
const config = await loadConfig(configPath(), { reset: values['reset-pairing'] });

let relayUrl = values.relay ?? process.env.CLOUDTERMINAL_RELAY ?? config.relayUrl;
let publicUrl = values['public-url'];
let localRelay: ReturnType<typeof createRelay> | undefined;

if (values['local-relay']) {
  const port = Number(values.port ?? 8787);
  localRelay = createRelay({ logger: consoleLogger('relay') });
  await localRelay.listen(port, '0.0.0.0');
  relayUrl = `ws://127.0.0.1:${port}/ws`;
  publicUrl ??= `ws://${lanAddress() ?? 'localhost'}:${port}/ws`;
} else if (!relayUrl) {
  console.error('需要指定中继服务器：--relay wss://你的服务器/ws，或使用 --local-relay。\n\n' + HELP);
  process.exit(1);
} else {
  const relayKey = values['relay-key'] ?? process.env.CLOUDTERMINAL_RELAY_KEY ?? config.relayKey;
  if (relayUrl !== config.relayUrl || relayKey !== config.relayKey) {
    await saveConfig({ ...config, relayUrl, relayKey });
  }
  config.relayKey = relayKey;
}
publicUrl ??= relayUrl;

const roots = (values.root?.length ? values.root : [homedir()]).map((r) => path.resolve(r));
const defaultCwd = path.resolve(values.cwd ?? process.cwd());

const core = new AgentCore({
  queryFn: sdkQueryFn((line) => log.warn('claude stderr', { line: line.trimEnd() })),
  roots,
  defaultCwd,
  allowBypass: values['allow-bypass'] === true,
  claudePath: values['claude-path'] ?? process.env.CLOUDTERMINAL_CLAUDE_PATH,
  history: sdkHistory,
  logger: log,
});

const link = new RelayLink({
  url: relayUrl,
  agentId: config.agentId,
  secret: config.secret,
  relayKey: localRelay ? undefined : config.relayKey,
  name: values.name ?? hostname(),
  core,
  logger: log,
  onOnline: () => {
    if (firstOnline) {
      firstOnline = false;
      void printPairing();
    }
  },
  onPaired: () => console.log('\n✓ 手机已配对。按回车可生成新的配对码。\n'),
});

let firstOnline = true;
link.start();

if (publicUrl.startsWith('ws://') && !/^ws:\/\/(127\.|localhost|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(publicUrl)) {
  log.warn('relay URL is not encrypted (ws://); use wss:// behind TLS for internet access');
}
if (!defaultCwdAllowed()) log.warn('default cwd is outside --root; the phone will need to pick a directory', { defaultCwd });

async function printPairing(): Promise<void> {
  try {
    const code = await link.requestPairCode();
    const mins = Math.round((code.expiresAt - Date.now()) / 60_000);
    console.log(
      [
        '',
        '┌──────────────────── 手机配对 ────────────────────',
        `│ 服务器地址：${publicUrl}`,
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

if (process.stdin.isTTY) {
  const rl = createInterface({ input: process.stdin });
  rl.on('line', () => void printPairing());
}

let shuttingDown = false;
const shutdown = () => {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info('shutting down');
  core.closeAll();
  link.stop();
  void (localRelay?.close() ?? Promise.resolve()).then(() => process.exit(0));
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
