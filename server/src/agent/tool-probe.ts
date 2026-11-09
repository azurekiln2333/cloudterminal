// Discover which tools are installed on this machine and what they can do.
//
// This never pretends a missing tool is usable: a failed lookup yields
// `installed: false` with an actionable Chinese reason. It also never starts a
// daemon as a side effect; `daemonRunning` is only a lookup of existing state.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

import { resolveHerdrBinary } from './herdr.ts';

export type ToolKind = 'herdr' | 'codex' | 'claude';

export type ToolProbeResult = {
  kind: ToolKind;
  installed: boolean;
  version?: string;
  executable?: string;
  daemonRunning: boolean;
  loggedIn?: boolean;
  reason?: string;
};

type RunResult = { code: number; stdout: string; stderr: string; timedOut: boolean };

function run(executable: string, argv: string[], timeoutMs = 8000): Promise<RunResult> {
  return new Promise((resolve) => {
    // On Windows a `.cmd`/`.bat` shim cannot be spawned directly with
    // shell:false (Node 24 refuses), and enabling `shell` on a variable path
    // would be an injection risk. cmd.exe with an argv array keeps the path and
    // every argument in its own slot, so nothing is re-parsed as a shell word.
    const isBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(executable);
    const spawnCommand = isBatch ? process.env.ComSpec || 'cmd.exe' : executable;
    const spawnArgs = isBatch ? ['/d', '/s', '/c', executable, ...argv] : argv;
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(spawnCommand, spawnArgs, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (err) {
      resolve({ code: -1, stdout: '', stderr: err instanceof Error ? err.message : String(err), timedOut: false });
      return;
    }
    const out: string[] = [];
    const err: string[] = [];
    let settled = false;
    const timer = setTimeout(() => {
      child.kill();
      finish(-1, true);
    }, timeoutMs);
    const finish = (code: number, timedOut: boolean): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, stdout: out.join('').trim(), stderr: err.join('').trim(), timedOut });
    };
    child.stdout?.on('data', (d: Buffer) => out.push(d.toString('utf8')));
    child.stderr?.on('data', (d: Buffer) => err.push(d.toString('utf8')));
    child.on('error', (e) => {
      err.push(e.message);
      finish(-1, false);
    });
    child.on('close', (code) => finish(code ?? -1, false));
  });
}

/** Find an executable on PATH or in common install locations. */
function locate(name: string): string | undefined {
  const candidates =
    process.platform === 'win32'
      ? [
          path.join(homedir(), '.local', 'bin', `${name}.exe`),
          path.join(process.env.APPDATA ?? '', 'npm', `${name}.cmd`),
          path.join(process.env.APPDATA ?? '', 'npm', `${name}.exe`),
        ]
      : [`/usr/local/bin/${name}`, `/opt/homebrew/bin/${name}`, path.join(homedir(), '.local', 'bin', name)];
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  // Fall back to the bare name; spawn resolves it through PATH.
  return name;
}

async function probeHerdr(herdrPath?: string): Promise<ToolProbeResult> {
  const binary = (await resolveHerdrBinary(herdrPath)) ?? undefined;
  if (!binary || (binary !== 'herdr' && binary !== 'herdr.exe' && !existsSync(binary))) {
    return {
      kind: 'herdr',
      installed: false,
      daemonRunning: false,
      reason: '未安装 Herdr。安装后重启助手即可看到工作区。',
    };
  }
  const version = await run(binary, ['--version']);
  if (version.code !== 0) {
    return {
      kind: 'herdr',
      installed: false,
      executable: binary,
      daemonRunning: false,
      reason: '找到了 Herdr 但无法运行。',
    };
  }
  const match = /^herdr\s+(\S+)\s*$/im.exec(version.stdout);
  const status = await run(binary, ['status'], 6000);
  const running = /status:\s*running/i.test(status.stdout);
  return {
    kind: 'herdr',
    installed: true,
    version: match?.[1],
    executable: binary,
    daemonRunning: running,
    reason: running ? undefined : 'Herdr 服务未运行；打开一次 Herdr 或运行 herdr server。',
  };
}

async function probeCodex(): Promise<ToolProbeResult> {
  const binary = locate('codex');
  const version = await run(binary ?? 'codex', ['--version']);
  if (version.code !== 0 || !version.stdout) {
    return {
      kind: 'codex',
      installed: false,
      daemonRunning: false,
      reason: '未安装 Codex CLI。安装后重新检测即可绑定。',
    };
  }
  // `daemon version` prints JSON and starts nothing.
  const daemon = await run(binary ?? 'codex', ['app-server', 'daemon', 'version'], 8000);
  const daemonRunning = daemon.code === 0 && /"running"|"version"/i.test(daemon.stdout);
  return {
    kind: 'codex',
    installed: true,
    version: version.stdout.replace(/^codex-cli\s+/, '').trim(),
    executable: binary,
    daemonRunning,
    reason: daemonRunning ? undefined : 'Codex CLI 可用；app-server 守护进程未运行（绑定时会按需启动）。',
  };
}

async function probeClaude(): Promise<ToolProbeResult> {
  const binary = locate('claude');
  const version = await run(binary ?? 'claude', ['--version']);
  if (version.code !== 0 || !version.stdout) {
    return {
      kind: 'claude',
      installed: false,
      daemonRunning: false,
      reason: '未安装 Claude Code。安装并登录后重新检测。',
    };
  }
  const agents = await run(binary ?? 'claude', ['agents', '--json', '--all'], 10_000);
  const background = /\[[^\]]*\]/.test(agents.stdout) ? agents.stdout.trim() : '';
  const backgroundCount = background && background !== '[]' ? 'has' : 'none';
  return {
    kind: 'claude',
    installed: true,
    version: version.stdout.trim(),
    executable: binary,
    daemonRunning: backgroundCount === 'has',
    loggedIn: true,
  };
}

export async function probeTools(options: { herdrPath?: string } = {}): Promise<ToolProbeResult[]> {
  const results = await Promise.all([probeHerdr(options.herdrPath), probeCodex(), probeClaude()]);
  return results;
}
