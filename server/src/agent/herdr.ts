// Herdr bridge: talks to the locally installed `herdr` CLI (0.9.x) over its
// socket API and maps its JSON contract onto the CloudTerminal wire protocol.
//
// Design notes live in .trellis/tasks/10-12-herdr-mobile/design.md and the
// probed capability dump in .../research/herdr-cli-0.9.3.md.
//
// Two rules matter here:
//   1. CLI commands handle structural control. Interactive terminal input uses
//      the short-lived socket API to preserve control bytes without per-key
//      process spawns; `pane read` / `agent read` print raw screen text.
//   2. Mobile-controlled strings never reach a shell. Every invocation is an
//      argv array with shell disabled, and ids/keys/kinds are validated first.

import { spawn } from 'node:child_process';
import { access, readdir } from 'node:fs/promises';
import { constants, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

import { type Logger, silentLogger } from '../shared/log.ts';
import { herdrSocketCall, HerdrSocketError } from './herdr-socket.ts';
import type {
  HerdrAction,
  HerdrAgent,
  HerdrAgentStatus,
  HerdrAvailability,
  HerdrLayout,
  HerdrPane,
  HerdrReadSource,
  HerdrTab,
  HerdrWorkspace,
} from '../shared/protocol.ts';

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

export type HerdrResult = {
  /** Exit code; -1 when the process was killed by the timeout. */
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
};

export type HerdrRunOptions = {
  argv: string[];
  timeoutMs: number;
  /** Regex the command must produce, else it is rejected before execution. */
  cwd?: string;
};

export type HerdrRunner = (options: HerdrRunOptions) => Promise<HerdrResult>;

/** Real runner: argv array, no shell, capped output, hard timeout + kill. */
export function nativeHerdrRunner(binary: string): HerdrRunner {
  return ({ argv, timeoutMs, cwd }) =>
    new Promise<HerdrResult>((resolve) => {
      let child: ReturnType<typeof spawn>;
      try {
        child = spawn(binary, argv, {
          shell: false,
          windowsHide: true,
          cwd,
          stdio: ['ignore', 'pipe', 'pipe'],
        });
      } catch (err) {
        resolve({ code: -1, stdout: '', stderr: err instanceof Error ? err.message : String(err), timedOut: false });
        return;
      }

      const out: string[] = [];
      const err: string[] = [];
      let bytes = 0;
      let timedOut = false;
      let settled = false;

      const finish = (code: number): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ code, stdout: out.join(''), stderr: err.join(''), timedOut });
      };

      const cap = MAX_STDOUT_BYTES;
      const collect = (chunks: string[]) => (data: Buffer) => {
        if (bytes >= cap) return;
        bytes += data.length;
        chunks.push(data.toString('utf8'));
      };

      const timer = setTimeout(() => {
        timedOut = true;
        child.kill();
        // Windows child processes may need a second signal to release the pipe.
        setTimeout(() => child.kill('SIGKILL'), 500).unref?.();
      }, timeoutMs);

      child.stdout?.on('data', collect(out));
      child.stderr?.on('data', collect(err));
      child.on('error', (e) => {
        err.push(e.message);
        finish(-1);
      });
      child.on('close', (code) => finish(code ?? -1));
    });
}

const MAX_STDOUT_BYTES = 2 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Binary resolution
// ---------------------------------------------------------------------------

const BINARY_NAME = process.platform === 'win32' ? 'herdr.exe' : 'herdr';

/** Known install locations, probed once per process. */
let cachedProbe: string | null | undefined;

export async function resolveHerdrBinary(explicit?: string): Promise<string | undefined> {
  if (explicit) {
    const resolved = path.resolve(explicit);
    return existsSync(resolved) ? resolved : undefined;
  }
  const env = process.env.CLOUDTERMINAL_HERDR_PATH;
  if (env) {
    const resolved = path.resolve(env);
    return existsSync(resolved) ? resolved : undefined;
  }
  if (cachedProbe !== undefined) return cachedProbe ?? undefined;
  cachedProbe = (await probeKnownLocations()) ?? null;
  return cachedProbe ?? undefined;
}

/** Test seam: forget the cached discovery result. */
export function resetHerdrBinaryCache(): void {
  cachedProbe = undefined;
}

async function probeKnownLocations(): Promise<string | undefined> {
  const candidates: string[] = [];
  if (process.platform === 'win32') {
    for (const base of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA]) {
      if (!base) continue;
      try {
        for (const entry of await readdir(base, { withFileTypes: true })) {
          if (entry.isDirectory() && entry.name.startsWith('herdr-')) {
            candidates.push(path.join(base, entry.name, BINARY_NAME));
          }
        }
      } catch {
        // Directory missing or unreadable is not an error; keep probing.
      }
    }
  } else {
    candidates.push(
      '/usr/local/bin/herdr',
      '/usr/bin/herdr',
      '/opt/homebrew/bin/herdr',
      path.join(homedir(), '.local', 'bin', 'herdr'),
      path.join(homedir(), '.cargo', 'bin', 'herdr'),
    );
  }
  for (const candidate of candidates) {
    if (await isExecutable(candidate)) return candidate;
  }
  // Fall back to a PATH lookup by name; spawn resolves it at call time.
  return BINARY_NAME;
}

async function isExecutable(file: string): Promise<boolean> {
  try {
    await access(file, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Status parsing
// ---------------------------------------------------------------------------

export type HerdrStatus = {
  clientVersion?: string;
  clientProtocol?: number;
  serverStatus?: string;
  serverVersion?: string;
  socket?: string;
};

/**
 * `herdr status` prints indented `key: value` text, not JSON:
 *
 *   client:
 *     version: 0.9.3
 *     protocol: 22
 *   server:
 *     status: running
 *     socket: D:\AppData\Roaming\herdr\herdr.sock
 */
export function parseHerdrStatus(text: string): HerdrStatus {
  const result: HerdrStatus = {};
  let section = '';
  for (const rawLine of text.split(/\r?\n/)) {
    if (!rawLine.trim()) continue;
    const indented = /^\s/.test(rawLine);
    const match = /^\s*([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/.exec(rawLine);
    if (!match) continue;
    const key = match[1]!.toLowerCase();
    const value = match[2]!.trim();
    if (!indented && value === '') {
      section = key;
      continue;
    }
    if (section === 'client') {
      if (key === 'version') result.clientVersion = value;
      else if (key === 'protocol') result.clientProtocol = Number.parseInt(value, 10) || undefined;
    } else if (section === 'server') {
      if (key === 'status') result.serverStatus = value;
      else if (key === 'version') result.serverVersion = value;
      else if (key === 'socket') result.socket = value;
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const WORKSPACE_ID = /^w[0-9A-Za-z]{1,8}$/;
// Suffixes are base-36, not decimal: herdr hands out `p5`, `pS`, `pB`, `pC` and
// `t1`, `tA`. A digits-only pattern rejected real panes, which surfaced as
// `herdr_invalid_argument: 无效的面板 ID："wJ:pS"` on every watch/focus.
const TAB_ID = /^w[0-9A-Za-z]{1,8}:t[0-9A-Za-z]{1,4}$/;
const PANE_ID = /^w[0-9A-Za-z]{1,8}:p[0-9A-Za-z]{1,4}$/;
const AGENT_NAME = /^[a-z][a-z0-9_-]{0,31}$/;
const MAX_LABEL = 120;
const MAX_TEXT = 64 * 1024;

/**
 * Herdr's own agent kind list (`herdr agent` prints it). Kept as data so an
 * unknown kind is rejected before the CLI ever runs.
 */
export const HERDR_AGENT_KINDS: readonly string[] = [
  'pi', 'claude', 'codex', 'gemini', 'cursor', 'devin', 'agy', 'cline', 'omp',
  'mastracode', 'opencode', 'copilot', 'kimi', 'kiro', 'droid', 'amp', 'grok',
  'hermes', 'kilo', 'qodercli', 'qwen', 'letta', 'maki', 'muse',
];

/**
 * Logical keys accepted for `agent send-keys` / `pane send-keys`. Deliberately
 * excludes anything that can erase or shut down the session irrecoverably.
 */
export const HERDR_KEYS: readonly string[] = [
  'enter', 'esc', 'tab', 'backspace', 'space', 'up', 'down', 'left', 'right',
  'home', 'end', 'pageup', 'pagedown',
  'ctrl+a', 'ctrl+c', 'ctrl+d', 'ctrl+l', 'ctrl+r', 'ctrl+u', 'ctrl+z',
  'shift+tab',
];

const READ_SOURCES: readonly HerdrReadSource[] = ['visible', 'recent', 'recent-unwrapped', 'detection'];
const DIRECTIONS = ['left', 'right', 'up', 'down'] as const;

const AGENT_STATUSES: readonly HerdrAgentStatus[] = ['idle', 'working', 'blocked', 'done', 'unknown'];

/** Thrown for client-supplied values that must not reach the CLI. */
export class HerdrArgumentError extends Error {}

function fail(message: string): never {
  throw new HerdrArgumentError(message);
}

export function requireWorkspaceId(value: unknown): string {
  if (typeof value !== 'string' || !WORKSPACE_ID.test(value)) fail(`无效的工作区 ID：${describe(value)}`);
  return value as string;
}

export function requireTabId(value: unknown): string {
  if (typeof value !== 'string' || !TAB_ID.test(value)) fail(`无效的标签页 ID：${describe(value)}`);
  return value as string;
}

export function requirePaneId(value: unknown): string {
  if (typeof value !== 'string' || !PANE_ID.test(value)) fail(`无效的面板 ID：${describe(value)}`);
  return value as string;
}

/**
 * Agent targets are either a pane id hosting an agent or a unique live agent
 * name. Nothing else is a legal target, matching Herdr's own rule. A bare kind
 * label (`pi`, `codex`, ...) is explicitly rejected: Herdr does not accept it
 * and it would silently target whichever agent happens to match.
 */
export function requireAgentTarget(value: unknown): string {
  if (typeof value !== 'string') fail(`无效的 agent 目标：${describe(value)}`);
  const target = value as string;
  if (PANE_ID.test(target)) return target;
  if (HERDR_AGENT_KINDS.includes(target)) {
    fail(`agent 目标不能是类型名（${describe(value)}），请用 agent 名称或面板 ID`);
  }
  if (AGENT_NAME.test(target)) return target;
  fail(`无效的 agent 目标：${describe(value)}`);
}

export function requireAgentName(value: unknown): string {
  if (typeof value !== 'string' || !AGENT_NAME.test(value)) {
    fail(`agent 名称只能是小写字母、数字、下划线和连字符（须以字母开头，最长 32 位）：${describe(value)}`);
  }
  return value as string;
}

export function requireAgentKind(value: unknown): string {
  if (typeof value !== 'string' || !HERDR_AGENT_KINDS.includes(value)) {
    fail(`不支持的 agent 类型：${describe(value)}`);
  }
  return value as string;
}

export function requireLabel(value: unknown, field = '标签'): string {
  if (typeof value !== 'string') fail(`${field}必须是文本`);
  const label = value.trim();
  if (!label) fail(`${field}不能为空`);
  if (label.length > MAX_LABEL) fail(`${field}过长（最多 ${MAX_LABEL} 个字符）`);
  // Control characters would break Herdr's own single-line labels.
  if (/[\u0000-\u001f\u007f]/.test(label)) fail(`${field}不能包含控制字符`);
  return label;
}

export function requireText(value: unknown, field = '内容'): string {
  if (typeof value !== 'string') fail(`${field}必须是文本`);
  if (!value) fail(`${field}不能为空`);
  if (value.length > MAX_TEXT) fail(`${field}过长（最多 ${MAX_TEXT} 个字符）`);
  // Only NUL is stripped: everything else is legitimate terminal input.
  return value.replace(/\u0000/g, '');
}

/** Raw terminal bytes are not prompt text: even NUL is a meaningful key. */
function requireTerminalInput(value: unknown): string {
  if (typeof value !== 'string') fail('输入内容必须是文本');
  if (!value) fail('输入内容不能为空');
  if (value.length > MAX_TEXT) fail(`输入内容过长（最多 ${MAX_TEXT} 个字符）`);
  return value;
}

export function requireDirection(value: unknown): 'left' | 'right' | 'up' | 'down' {
  if (typeof value !== 'string' || !DIRECTIONS.includes(value as never)) {
    fail(`无效的方向：${describe(value)}（可选 left/right/up/down）`);
  }
  return value as 'left' | 'right' | 'up' | 'down';
}

export function requireReadSource(value: unknown): HerdrReadSource {
  if (value === undefined || value === null) return 'visible';
  if (typeof value !== 'string' || !READ_SOURCES.includes(value as HerdrReadSource)) {
    fail(`无效的读取来源：${describe(value)}（可选 ${READ_SOURCES.join('/')}）`);
  }
  return value as HerdrReadSource;
}

export function requireLines(value: unknown, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 5000) {
    fail(`行数必须是 1–5000 的整数：${describe(value)}`);
  }
  return value;
}

export function requireRatio(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0.05 || value > 0.95) {
    fail(`比例必须在 0.05–0.95 之间：${describe(value)}`);
  }
  return value;
}

export function requireAmount(value: unknown, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0 || value > 1) {
    fail(`调整幅度必须在 0–1 之间：${describe(value)}`);
  }
  return value;
}

export function requireKeys(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0) fail('至少需要一个按键');
  if (value.length > 50) fail('一次最多发送 50 个按键');
  return value.map((key) => {
    if (typeof key !== 'string' || !HERDR_KEYS.includes(key)) {
      fail(`不支持的按键：${describe(key)}`);
    }
    return key as string;
  });
}

export function requireRepeat(value: unknown): number {
  if (value === undefined || value === null) return 1;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 50) {
    fail(`重复次数必须是 1–50 的整数：${describe(value)}`);
  }
  return value;
}

export function requireTimeout(value: unknown, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1000 || value > 600_000) {
    fail(`超时必须是 1000–600000 毫秒之间的整数：${describe(value)}`);
  }
  return value;
}

export function requireAgentStatuses(value: unknown): HerdrAgentStatus[] {
  if (value === undefined || value === null) return ['idle', 'done', 'blocked'];
  if (!Array.isArray(value) || value.length === 0) fail('等待状态不能为空');
  return value.map((status) => {
    if (typeof status !== 'string' || !AGENT_STATUSES.includes(status as HerdrAgentStatus)) {
      fail(`无效的等待状态：${describe(status)}`);
    }
    return status as HerdrAgentStatus;
  });
}

/** Never echo arbitrary client text back verbatim into an error message. */
function describe(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value.length > 60 ? `${value.slice(0, 60)}…` : value);
  return String(value);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type HerdrErrorCode =
  | 'herdr_unavailable'
  | 'herdr_invalid_argument'
  | 'herdr_failed';

/** Stable prefixes so the app can branch without parsing prose. */
export class HerdrError extends Error {
  readonly code: HerdrErrorCode;
  readonly herdrCode?: string;

  constructor(code: HerdrErrorCode, message: string, herdrCode?: string) {
    super(message);
    this.name = 'HerdrError';
    this.code = code;
    this.herdrCode = herdrCode;
  }

  /** `code:message` — the wire form the app matches on. */
  wire(): string {
    return this.herdrCode && this.herdrCode !== this.code
      ? `${this.code}:${this.herdrCode}:${this.message}`
      : `${this.code}:${this.message}`;
  }
}

/**
 * Map a Herdr failure onto an actionable Chinese message. `agent_blocked`,
 * `agent_not_ready` and `agent_prompt_stalled` all mean "do not blindly retry",
 * so they keep the raw code for the UI to reason about.
 */
export function describeHerdrFailure(code: string | undefined, message: string): string {
  switch (code) {
    case 'pane_not_found':
      return `面板不存在或已关闭（${message}）`;
    case 'pane_send_failed':
      return `无法向面板写入，请检查当前面板状态和终端内容以确认输入是否已送达；不会自动重发（${message}）`;
    case 'connection_closed':
      return `输入连接已断开，无法确认本次输入是否送达，请先检查当前面板和终端内容；不会自动重发（${message}）`;
    case 'agent_not_found':
      return `找不到该 agent，可能已退出或改名（${message}）`;
    case 'agent_not_ready':
      return `agent 还没准备好接收输入，请稍候再试（${message}）`;
    case 'agent_blocked':
      return `agent 正在等待确认或提问，请先在电脑上处理（${message}）`;
    case 'agent_prompt_stalled':
      return `提示已发送但未观察到 agent 开始工作，请到电脑上确认，不要重复发送（${message}）`;
    case 'timeout':
      return `等待超时（${message}）`;
    default:
      return message || 'Herdr 返回了未知错误';
  }
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

export type HerdrBridgeOptions = {
  /** Explicit binary path (CLI flag / saved config). */
  binary?: string;
  runner?: HerdrRunner;
  /** Short-lived raw input request, injected by tests. Never an event socket. */
  socketCall?: typeof herdrSocketCall;
  logger?: Logger;
  /** Availability cache window. */
  availabilityTtlMs?: number;
  commandTimeoutMs?: number;
};

type Json = Record<string, unknown>;

export class HerdrBridge {
  private readonly opts: HerdrBridgeOptions;
  private readonly log: Logger;
  private binary: string | undefined;
  private runner: HerdrRunner | undefined;
  private resolved = false;
  private availabilityCache: { at: number; value: HerdrAvailability } | undefined;
  private availabilityProbe: Promise<HerdrAvailability> | undefined;

  constructor(opts: HerdrBridgeOptions = {}) {
    this.opts = opts;
    this.log = opts.logger ?? silentLogger;
    this.binary = opts.binary;
    this.runner = opts.runner;
  }

  // -- availability --------------------------------------------------------

  async availability(force = false): Promise<HerdrAvailability> {
    const ttl = this.opts.availabilityTtlMs ?? 10_000;
    const cached = this.availabilityCache;
    if (!force && cached && Date.now() - cached.at < ttl) return cached.value;
    // A burst of terminal keys shares discovery instead of spawning two CLI
    // processes for every event before the first probe completes.
    if (this.availabilityProbe) return this.availabilityProbe;
    const pending = this.probe().then((value) => {
      this.availabilityCache = { at: Date.now(), value };
      return value;
    });
    this.availabilityProbe = pending;
    try {
      return await pending;
    } finally {
      this.availabilityProbe = undefined;
    }
  }

  private async probe(): Promise<HerdrAvailability> {
    const binary = await this.ensureBinary();
    if (!binary) {
      return {
        available: false,
        installed: false,
        serverRunning: false,
        canControl: false,
        reason: '这台电脑没有安装 Herdr。安装后重启 agent 即可用手机管理 Herdr 工作区。',
      };
    }
    const version = await this.text(['--version'], 10_000);
    if (version.code !== 0) {
      return {
        available: false,
        installed: true,
        serverRunning: false,
        canControl: false,
        reason: `找到了 Herdr 但无法运行：${firstLine(version.stderr) || `退出码 ${version.code}`}`,
      };
    }
    const versionMatch = /^herdr\s+(\S+)\s*$/im.exec(version.stdout);
    const parsed = versionMatch ? versionMatch[1]! : undefined;

    const status = await this.text(['status'], 10_000);
    const info = parseHerdrStatus(status.stdout);
    const running = (info.serverStatus ?? '').toLowerCase() === 'running';

    if (!parsed) {
      return {
        available: false,
        installed: true,
        serverRunning: running,
        canControl: false,
        reason: 'Herdr 已安装但无法确认版本，请升级到 0.9 以上。',
      };
    }
    if (!running) {
      return {
        available: false,
        installed: true,
        version: parsed,
        protocol: info.clientProtocol,
        socket: info.socket,
        serverRunning: false,
        canControl: false,
        reason: 'Herdr 服务未运行。请在电脑上打开一次 Herdr 或运行 herdr server，然后重试。',
      };
    }
    return {
      available: true,
      installed: true,
      version: parsed,
      protocol: info.clientProtocol,
      socket: info.socket,
      serverRunning: true,
      canControl: true,
    };
  }

  private async ensureBinary(): Promise<string | undefined> {
    if (!this.resolved) {
      this.binary = await resolveHerdrBinary(this.opts.binary);
      this.resolved = true;
      this.log.info('herdr binary resolved', { found: Boolean(this.binary), path: this.binary });
    }
    return this.binary;
  }

  private get runnerFor(): HerdrRunner {
    if (this.runner) return this.runner;
    const binary = this.binary;
    if (!binary) throw new HerdrError('herdr_unavailable', 'Herdr 未安装');
    return (this.runner = nativeHerdrRunner(binary));
  }

  // -- low level -----------------------------------------------------------

  /**
   * Run a Herdr command and parse its JSON envelope.
   *
   * [allowEmpty] is for **void mutations** — commands that legitimately print
   * nothing on success (`pane send-keys`, `agent send-keys`). They exit 0 with an
   * empty stdout, so requiring an envelope made a successful write look like
   * "Herdr 没有返回内容": the app then withheld Enter and never cleared the input
   * box. Only commands known to be void may pass it, so a listing or a read that
   * returns nothing still fails loudly rather than being read as success.
   * A non-zero exit is an error either way.
   */
  private async json(argv: string[], timeoutMs?: number, allowEmpty = false): Promise<Json> {
    const result = await this.invoke(argv, timeoutMs);
    const text = (result.stdout ?? '').trim();
    if (!text) {
      if (allowEmpty && result.code === 0) return {};
      throw new HerdrError('herdr_failed', 'Herdr 没有返回内容', undefined);
    }
    let parsed: Json;
    try {
      parsed = JSON.parse(text) as Json;
    } catch {
      throw new HerdrError('herdr_failed', `Herdr 返回了无法解析的内容：${firstLine(text)}`);
    }
    const error = parsed.error as { code?: string; message?: string } | undefined;
    if (error) {
      const herdrCode = typeof error.code === 'string' ? error.code : undefined;
      throw new HerdrError('herdr_failed', describeHerdrFailure(herdrCode, error.message ?? ''), herdrCode);
    }
    const result_ = parsed.result;
    if (!result_ || typeof result_ !== 'object') {
      throw new HerdrError('herdr_failed', 'Herdr 返回的内容缺少 result 字段');
    }
    return result_ as Json;
  }

  /** Run a Herdr command and return raw stdout (for `* read`). */
  private async text(argv: string[], timeoutMs?: number): Promise<HerdrResult> {
    return this.invoke(argv, timeoutMs);
  }

  private async invoke(argv: string[], timeoutMs?: number): Promise<HerdrResult> {
    const binary = await this.ensureBinary();
    if (!binary) {
      throw new HerdrError('herdr_unavailable', '这台电脑没有安装 Herdr。');
    }
    const timeout = timeoutMs ?? this.opts.commandTimeoutMs ?? 30_000;
    const result = await this.runnerFor({ argv, timeoutMs: timeout });
    if (result.timedOut) {
      throw new HerdrError('herdr_failed', describeHerdrFailure('timeout', `herdr ${argv.join(' ')}`), 'timeout');
    }
    if (result.code !== 0 && !(result.stdout ?? '').trim()) {
      // Usage errors print to stderr with no JSON envelope.
      throw new HerdrError('herdr_failed', firstLine(result.stderr ?? '') || `herdr 退出码 ${result.code}`);
    }
    return result;
  }

  // -- reads ---------------------------------------------------------------

  async version(): Promise<string | undefined> {
    return (await this.availability()).version;
  }

  async workspaces(): Promise<HerdrWorkspace[]> {
    const result = await this.json(['workspace', 'list']);
    return asArray(result.workspaces).map(mapWorkspace);
  }

  /**
   * Path of the Herdr server socket, or undefined when it is not running.
   *
   * Re-resolved per call (cached by `availability`'s own TTL) rather than latched
   * once, so a Herdr restart that moves the socket is picked up without an agent
   * restart.
   */
  async socketPath(): Promise<string | undefined> {
    const info = await this.availability();
    return info.available ? info.socket : undefined;
  }

  async tabs(workspaceId: unknown): Promise<HerdrTab[]> {
    const ws = requireWorkspaceId(workspaceId);
    const result = await this.json(['tab', 'list', '--workspace', ws]);
    return asArray(result.tabs).map(mapTab);
  }

  async panes(workspaceId: unknown): Promise<HerdrPane[]> {
    const ws = requireWorkspaceId(workspaceId);
    const result = await this.json(['pane', 'list', '--workspace', ws]);
    return asArray(result.panes).map(mapPane);
  }

  async agents(): Promise<HerdrAgent[]> {
    const result = await this.json(['agent', 'list']);
    return asArray(result.agents).map(mapAgent);
  }

  async agent(target: unknown): Promise<HerdrAgent> {
    const t = requireAgentTarget(target);
    const result = await this.json(['agent', 'get', t]);
    const raw = result.agent;
    if (!raw || typeof raw !== 'object') throw new HerdrError('herdr_failed', 'Herdr 未返回 agent 信息');
    return mapAgent(raw as Json);
  }

  async layout(paneId: unknown): Promise<HerdrLayout> {
    const id = requirePaneId(paneId);
    const result = await this.json(['pane', 'layout', '--pane', id]);
    const raw = result.layout;
    if (!raw || typeof raw !== 'object') throw new HerdrError('herdr_failed', 'Herdr 未返回布局信息');
    return mapLayout(raw as Json);
  }

  /** `* read` prints raw screen text, not JSON. */
  async read(paneId: unknown, source?: unknown, lines?: unknown): Promise<{
    paneId: string;
    source: HerdrReadSource;
    text: string;
  }> {
    const id = requirePaneId(paneId);
    const src = requireReadSource(source);
    const count = requireLines(lines, 200);
    const result = await this.text(['pane', 'read', id, '--source', src, '--lines', String(count)]);
    if (result.timedOut) throw new HerdrError('herdr_failed', describeHerdrFailure('timeout', id), 'timeout');
    // `pane read` prints raw text on success, but an error still comes back as
    // a JSON envelope. Detect it so a failed read is never shown as output.
    const raw = result.stdout ?? '';
    const error = parseErrorEnvelope(raw);
    if (error) {
      throw new HerdrError('herdr_failed', describeHerdrFailure(error.code, error.message), error.code);
    }
    if (result.code !== 0 && !raw.trim()) {
      throw new HerdrError('herdr_failed', firstLine(result.stderr ?? '') || `herdr 退出码 ${result.code}`);
    }
    return { paneId: id, source: src, text: raw };
  }

  // -- input ---------------------------------------------------------------

  /**
   * Submit a task to an agent. Herdr sends text plus encoded Enter as one
   * ordered submission and rejects an agent sitting at a dialog *before*
   * writing anything. Never retried here: a stalled result is reported.
   */
  async prompt(target: unknown, text: unknown, options: { wait?: boolean; timeoutMs?: number } = {}): Promise<string> {
    const t = requireAgentTarget(target);
    const body = requireText(text, '提示内容');
    const argv = ['agent', 'prompt', t, body];
    let timeout = this.opts.commandTimeoutMs ?? 30_000;
    if (options.wait) {
      argv.push('--wait');
      const budget = requireTimeout(options.timeoutMs, 120_000);
      argv.push('--timeout', String(budget));
      timeout = budget + 10_000;
    } else if (options.timeoutMs !== undefined) {
      const budget = requireTimeout(options.timeoutMs, 120_000);
      argv.push('--timeout', String(budget));
      timeout = budget + 10_000;
    }
    const result = await this.json(argv, timeout);
    return summarise(result.agent ?? result, `已向 ${t} 发送提示`);
  }

  async sendText(paneId: unknown, text: unknown, paste: unknown = false): Promise<string> {
    const id = requirePaneId(paneId);
    const body = requireTerminalInput(text);
    if (typeof paste !== 'boolean') fail('粘贴标记必须是布尔值');
    const info = await this.availability();
    if (!info.available) {
      throw new HerdrError('herdr_unavailable', info.reason ?? 'Herdr 服务不可用，请在电脑上打开 Herdr 后重试。');
    }
    if (!info.socket) {
      throw new HerdrError('herdr_unavailable', 'Herdr 未提供输入连接地址，请在电脑上重启 Herdr 后重试。');
    }
    try {
      // Herdr applies the target pane's bracketed-paste mode only to explicit
      // clipboard pastes. Ordinary keys retain raw control-byte semantics.
      const reply = await (this.opts.socketCall ?? herdrSocketCall)(
        info.socket,
        paste ? 'pane.send_input' : 'pane.send_text',
        { pane_id: id, text: body },
        this.opts.commandTimeoutMs ?? 4000,
      );
      const result = reply.result;
      if (!result || typeof result !== 'object' || (result as Json).type !== 'ok') {
        throw new HerdrError('herdr_failed', 'Herdr 未确认输入已送达，请先检查终端内容，不要重复发送。');
      }
    } catch (error) {
      if (error instanceof HerdrError) throw error;
      const code = error instanceof HerdrSocketError ? error.code : undefined;
      const message = error instanceof Error ? error.message : String(error);
      // No retry or CLI fallback: a timeout/closed connection can happen after
      // Herdr already wrote the bytes, so resending could execute input twice.
      throw new HerdrError('herdr_failed', describeHerdrFailure(code, message), code);
    }
    return `已向 ${id} 写入文本`;
  }

  /**
   * Sends logical keys to a pane **or** a named agent.
   *
   * The two are different CLI verbs and are not interchangeable: `agent
   * send-keys` needs an agent, so a plain shell pane (which hosts none) could
   * never receive Enter, Backspace or an arrow key — the exact failure where keys
   * silently did nothing in a shell. A pane id therefore goes through `pane
   * send-keys`, while a live agent *name* keeps using `agent send-keys` so the
   * existing agent-targeted behaviour is unchanged.
   *
   * The branch is on the validated shape of the target, not on a guess: a pane id
   * matches Herdr's `w…:p…` form, anything else is an agent name.
   */
  async sendKeys(target: unknown, keys: unknown, repeat?: unknown): Promise<string> {
    const t = requireAgentTarget(target);
    const list = requireKeys(keys);
    const count = requireRepeat(repeat);
    const repeated = Array.from({ length: count }, () => list).flat();
    const isPaneId = PANE_ID.test(t);
    const argv = isPaneId
      ? ['pane', 'send-keys', t, ...repeated]
      : ['agent', 'send-keys', t, ...repeated];
    // Void on success for both verbs: no envelope, exit 0.
    await this.json(argv, undefined, true);
    return `已向 ${t} 发送按键 ${list.join(' ')}${count > 1 ? ` ×${count}` : ''}`;
  }

  async run(paneId: unknown, command: unknown): Promise<string> {
    const id = requirePaneId(paneId);
    // The command is one argv element: Herdr owns the shell, we never build one.
    const body = requireText(command, '命令');
    const result = await this.json(['pane', 'run', id, body], 180_000);
    return summarise(result, `已在 ${id} 执行命令`);
  }

  async wait(target: unknown, until?: unknown, timeoutMs?: unknown): Promise<string> {
    const t = requireAgentTarget(target);
    const budget = requireTimeout(timeoutMs, 120_000);
    const argv = ['agent', 'wait', t];
    if (until !== undefined) {
      for (const status of requireAgentStatuses(until)) argv.push('--until', status);
    }
    argv.push('--timeout', String(budget));
    const result = await this.json(argv, budget + 10_000);
    return summarise(result, `${t} 已达到等待状态`);
  }

  // -- lifecycle -----------------------------------------------------------

  async act(action: HerdrAction): Promise<{ summary: string; data?: unknown }> {
    const argv = this.argvForAction(action);
    const mutating = !NON_MUTATING.has(action.kind);
    const result = await this.json(argv, mutating ? 60_000 : 30_000);
    return { summary: summarise(result, ACTION_SUMMARY[action.kind] ?? '操作完成'), data: result };
  }

  private argvForAction(action: HerdrAction): string[] {
    switch (action.kind) {
      case 'workspace_create': {
        const argv = ['workspace', 'create'];
        if (action.cwd !== undefined) argv.push('--cwd', requireText(action.cwd, '目录'));
        if (action.label !== undefined) argv.push('--label', requireLabel(action.label, '工作区名称'));
        argv.push(action.focus === false ? '--no-focus' : '--focus');
        return argv;
      }
      case 'workspace_rename':
        return ['workspace', 'rename', requireWorkspaceId(action.workspaceId), requireLabel(action.label, '工作区名称')];
      case 'workspace_focus':
        return ['workspace', 'focus', requireWorkspaceId(action.workspaceId)];
      case 'workspace_close': {
        const argv = ['workspace', 'close', requireWorkspaceId(action.workspaceId)];
        if (action.group) argv.push('--group');
        return argv;
      }
      case 'tab_create': {
        const argv = ['tab', 'create', '--workspace', requireWorkspaceId(action.workspaceId)];
        if (action.cwd !== undefined) argv.push('--cwd', requireText(action.cwd, '目录'));
        if (action.label !== undefined) argv.push('--label', requireLabel(action.label, '标签页名称'));
        argv.push(action.focus === false ? '--no-focus' : '--focus');
        return argv;
      }
      case 'tab_rename':
        return ['tab', 'rename', requireTabId(action.tabId), requireLabel(action.label, '标签页名称')];
      case 'tab_focus':
        return ['tab', 'focus', requireTabId(action.tabId)];
      case 'tab_close':
        return ['tab', 'close', requireTabId(action.tabId)];
      case 'pane_split': {
        const argv = ['pane', 'split', requirePaneId(action.paneId), '--direction', requireDirection(action.direction)];
        const ratio = requireRatio(action.ratio);
        if (ratio !== undefined) argv.push('--ratio', String(ratio));
        if (action.cwd !== undefined) argv.push('--cwd', requireText(action.cwd, '目录'));
        argv.push(action.focus === false ? '--no-focus' : '--focus');
        return argv;
      }
      case 'pane_focus':
        // `pane focus` only moves the focus by direction — it has no by-id form,
        // so it cannot implement "go to this pane". `pane zoom <id> --off` is the
        // only primitive that targets a pane by id, and because it is pinned to
        // `--off` it never toggles zoom: focus moves, layout is untouched.
        return ['pane', 'zoom', requirePaneId(action.paneId), '--off'];
      case 'pane_zoom': {
        if (action.paneId === undefined) throw new HerdrArgumentError('缩放面板必须指定面板 ID');
        // `pane zoom` is positional; the mode flag is separate.
        const argv = ['pane', 'zoom', requirePaneId(action.paneId)];
        argv.push(action.mode === 'on' ? '--on' : action.mode === 'off' ? '--off' : '--toggle');
        return argv;
      }
      case 'pane_rename': {
        const argv = ['pane', 'rename', requirePaneId(action.paneId)];
        argv.push(action.label === undefined ? '--clear' : requireLabel(action.label, '面板名称'));
        return argv;
      }
      case 'pane_close':
        return ['pane', 'close', requirePaneId(action.paneId)];
      case 'pane_resize':
        return [
          'pane', 'resize',
          '--direction', requireDirection(action.direction),
          '--amount', String(requireAmount(action.amount, 0.1)),
          '--pane', requirePaneId(action.paneId),
        ];
      case 'pane_move': {
        const argv = ['pane', 'move', requirePaneId(action.paneId)];
        if (action.to === 'new_tab') {
          argv.push('--new-tab');
        } else if (action.to === 'new_workspace') {
          argv.push('--new-workspace');
        } else if (action.to === 'tab') {
          argv.push('--tab', requireTabId(action.tabId), '--split', requireDirection(action.split ?? 'right') === 'down' ? 'down' : 'right');
        } else {
          throw new HerdrArgumentError(`不支持的移动目标：${String(action.to)}`);
        }
        if (action.label !== undefined) argv.push('--label', requireLabel(action.label, '名称'));
        return argv;
      }
      case 'agent_start': {
        const name = requireAgentName(action.name);
        const kind = requireAgentKind(action.agentKind);
        const pane = requirePaneId(action.paneId);
        const argv = ['agent', 'start', name, '--kind', kind, '--pane', pane];
        if (action.args?.length) argv.push('--', ...action.args.map((a) => requireText(a, '参数')));
        return argv;
      }
      case 'agent_rename': {
        const argv = ['agent', 'rename', requireAgentTarget(action.target)];
        argv.push(action.name === undefined ? '--clear' : requireAgentName(action.name));
        return argv;
      }
      case 'agent_focus':
        return ['agent', 'focus', requireAgentTarget(action.target)];
      default: {
        const exhaustive: never = action;
        throw new HerdrArgumentError(`未知操作：${JSON.stringify(exhaustive)}`);
      }
    }
  }
}

const NON_MUTATING = new Set<HerdrAction['kind']>(['workspace_focus', 'tab_focus', 'pane_focus', 'agent_focus']);

const ACTION_SUMMARY: Partial<Record<HerdrAction['kind'], string>> = {
  workspace_create: '已创建工作区',
  workspace_rename: '已重命名工作区',
  workspace_focus: '已切换到工作区',
  workspace_close: '已关闭工作区',
  tab_create: '已创建标签页',
  tab_rename: '已重命名标签页',
  tab_focus: '已切换到标签页',
  tab_close: '已关闭标签页',
  pane_split: '已拆分面板',
  pane_focus: '已聚焦面板',
  pane_zoom: '已切换面板缩放',
  pane_rename: '已重命名面板',
  pane_close: '已关闭面板',
  pane_resize: '已调整面板大小',
  pane_move: '已移动面板',
  agent_start: '已启动 agent',
  agent_rename: '已重命名 agent',
  agent_focus: '已聚焦 agent',
};

// ---------------------------------------------------------------------------
// Mapping: Herdr JSON → typed values
// ---------------------------------------------------------------------------

function asArray(value: unknown): Json[] {
  return Array.isArray(value) ? value.filter((v): v is Json => Boolean(v) && typeof v === 'object') : [];
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function bool(value: unknown): boolean {
  return value === true;
}

/** Unknown statuses degrade to `unknown` so a newer Herdr never throws. */
export function parseAgentStatus(value: unknown): HerdrAgentStatus {
  return AGENT_STATUSES.includes(value as HerdrAgentStatus) ? (value as HerdrAgentStatus) : 'unknown';
}

function scrollOf(value: unknown) {
  if (!value || typeof value !== 'object') return undefined;
  const raw = value as Json;
  return {
    offsetFromBottom: num(raw.offset_from_bottom),
    maxOffsetFromBottom: num(raw.max_offset_from_bottom),
    viewportRows: num(raw.viewport_rows),
  };
}

function mapWorkspace(raw: Json): HerdrWorkspace {
  const activeTabId = str(raw.active_tab_id);
  return {
    workspaceId: str(raw.workspace_id),
    label: str(raw.label),
    number: num(raw.number),
    focused: bool(raw.focused),
    agentStatus: parseAgentStatus(raw.agent_status),
    paneCount: num(raw.pane_count),
    tabCount: num(raw.tab_count),
    ...(activeTabId ? { activeTabId } : {}),
  };
}

function mapTab(raw: Json): HerdrTab {
  return {
    tabId: str(raw.tab_id),
    workspaceId: str(raw.workspace_id),
    label: str(raw.label),
    number: num(raw.number),
    focused: bool(raw.focused),
    agentStatus: parseAgentStatus(raw.agent_status),
    paneCount: num(raw.pane_count),
  };
}

function mapPane(raw: Json): HerdrPane {
  const paneId = str(raw.pane_id);
  const agent = str(raw.agent);
  const name = str(raw.name);
  const title = str(raw.terminal_title_stripped) || str(raw.terminal_title);
  const scroll = scrollOf(raw.scroll);
  return {
    paneId,
    workspaceId: str(raw.workspace_id),
    tabId: str(raw.tab_id),
    cwd: str(raw.cwd),
    focused: bool(raw.focused),
    terminalTitle: title,
    ...(agent ? { agent } : {}),
    ...(agent ? { agentStatus: parseAgentStatus(raw.agent_status) } : {}),
    ...(name ? { name } : {}),
    ...(raw.interactive_ready === true ? { interactiveReady: true } : {}),
    ...(scroll ? { scroll } : {}),
  };
}

function mapAgent(raw: Json): HerdrAgent {
  const paneId = str(raw.pane_id);
  const name = str(raw.name);
  const title = str(raw.terminal_title_stripped) || str(raw.terminal_title);
  const completionSeq = num(raw.completion_seq);
  const stateChangeSeq = num(raw.state_change_seq);
  return {
    // A named agent is addressed by name; otherwise the panes id is the target.
    target: name || paneId,
    paneId,
    workspaceId: str(raw.workspace_id),
    tabId: str(raw.tab_id),
    cwd: str(raw.cwd),
    agentKind: str(raw.agent),
    status: parseAgentStatus(raw.agent_status),
    focused: bool(raw.focused),
    terminalTitle: title,
    ...(name ? { name } : {}),
    ...(raw.interactive_ready === true ? { interactiveReady: true } : {}),
    ...(completionSeq ? { completionSeq } : {}),
    ...(stateChangeSeq ? { stateChangeSeq } : {}),
  };
}

function mapLayout(raw: Json): HerdrLayout {
  const area = (raw.area ?? {}) as Json;
  const focused = str(raw.focused_pane_id);
  return {
    workspaceId: str(raw.workspace_id),
    tabId: str(raw.tab_id),
    zoomed: bool(raw.zoomed),
    ...(focused ? { focusedPaneId: focused } : {}),
    area: { x: num(area.x), y: num(area.y), width: num(area.width), height: num(area.height) },
    panes: asArray(raw.panes).map((pane) => ({
      paneId: str(pane.pane_id),
      focused: bool(pane.focused),
      rect: rectOf(pane.rect),
    })),
    splits: asArray(raw.splits).map((split) => ({
      id: str(split.id),
      direction: str(split.direction),
      ratio: num(split.ratio),
    })),
  };
}

function rectOf(value: unknown): { x: number; y: number; width: number; height: number } {
  const raw = (value ?? {}) as Json;
  return { x: num(raw.x), y: num(raw.y), width: num(raw.width), height: num(raw.height) };
}

/** Pull a short, human-readable line out of a Herdr result object. */
function summarise(raw: unknown, fallback: string): string {
  if (!raw || typeof raw !== 'object') return fallback;
  const record = raw as Json;
  for (const key of ['pane_id', 'tab_id', 'workspace_id', 'name', 'agent', 'label']) {
    const value = record[key];
    if (typeof value === 'string' && value) return `${fallback}（${value}）`;
  }
  const pane = record.pane as Json | undefined;
  if (pane && typeof pane === 'object' && typeof pane.pane_id === 'string') return `${fallback}（${pane.pane_id}）`;
  const workspace = record.workspace as Json | undefined;
  if (workspace && typeof workspace === 'object' && typeof workspace.workspace_id === 'string') {
    return `${fallback}（${workspace.workspace_id}）`;
  }
  const tab = record.tab as Json | undefined;
  if (tab && typeof tab === 'object' && typeof tab.tab_id === 'string') return `${fallback}（${tab.tab_id}）`;
  return fallback;
}

function firstLine(text: string): string {
  const line = text.split(/\r?\n/).find((l) => l.trim());
  return line ? line.trim().slice(0, 200) : '';
}

/**
 * Parse a leading `{"error":{...}}` envelope from a `* read` result.
 * Returns undefined when the text is ordinary screen output.
 */
function parseErrorEnvelope(text: string): { code?: string; message: string } | undefined {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.includes('"error"')) return undefined;
  try {
    const parsed = JSON.parse(trimmed) as { error?: { code?: unknown; message?: unknown } };
    const error = parsed.error;
    if (!error || typeof error !== 'object') return undefined;
    return {
      code: typeof error.code === 'string' ? error.code : undefined,
      message: typeof error.message === 'string' ? error.message : '',
    };
  } catch {
    return undefined;
  }
}
