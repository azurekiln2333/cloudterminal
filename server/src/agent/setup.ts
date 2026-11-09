import { stat } from 'node:fs/promises';
import { isIP } from 'node:net';
import path from 'node:path';
import type { AgentConfig } from './config.ts';

export type SetupPrompt = (label: string, secret?: boolean) => Promise<string>;

export function relayAddress(value: string): string {
  const text = value.trim();
  if (!text) throw new Error('中继地址不能为空');
  const explicitScheme = text.includes('://');
  const url = new URL(explicitScheme ? text : `wss://${text}`);
  if (!explicitScheme) {
    const host = url.hostname;
    const local = host === 'localhost' || host === '[::1]' || (isIP(host) === 4 && /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host));
    if (local) url.protocol = 'ws:';
  }
  if (url.protocol === 'http:') url.protocol = 'ws:';
  if (url.protocol === 'https:') url.protocol = 'wss:';
  if (!['ws:', 'wss:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash || url.search) throw new Error('请输入有效的中继地址');
  if (url.pathname === '/') url.pathname = '/ws';
  if (url.pathname !== '/ws') throw new Error('中继路径必须为 /ws');
  return url.toString();
}

export async function setupConfig(current: AgentConfig, prompt: SetupPrompt): Promise<AgentConfig> {
  // The LAN entry is always on, so there is no mode question any more: the
  // user just picks a port, and optionally adds a relay URL for outside use.
  const next: AgentConfig = { ...current, connectionMode: 'local' };
  const portText = (await prompt(`本机端口（局域网始终开启）[${current.localPort ?? 8787}]：`)).trim();
  next.localPort = portText ? Number(portText) : current.localPort ?? 8787;
  if (!Number.isInteger(next.localPort) || next.localPort < 1 || next.localPort > 65535) throw new Error('端口必须为 1–65535');

  // Empty input means "LAN only": it must clear the saved relay rather than
  // silently keep it, otherwise there is no way back to a single entry point.
  const address = (await prompt(`中继地址（留空只用局域网，- 清除）${current.relayUrl ? ` [${current.relayUrl}]` : ''}：`)).trim();
  if (address === '-' || address === '') {
    next.relayUrl = undefined;
    next.relayKey = undefined;
  } else {
    next.relayUrl = relayAddress(address);
  }
  if (next.relayUrl) {
    const key = await prompt('注册密钥（输入隐藏；回车保留同一服务器的密钥，输入 - 清空）：', true);
    next.relayKey = key === '-' ? undefined : key || (next.relayUrl === current.relayUrl ? current.relayKey : undefined);
    next.connectionMode = 'remote';
  } else {
    next.relayKey = undefined;
  }

  const cwd = path.resolve((await prompt(`工作目录 [${current.defaultCwd ?? process.cwd()}]：`)).trim() || current.defaultCwd || process.cwd());
  if (!(await stat(cwd)).isDirectory()) throw new Error('工作目录不存在');
  next.defaultCwd = cwd;
  next.roots = [cwd];
  const terminal = (await prompt('启动电脑与手机共享终端？[Y/n]：')).trim().toLowerCase();
  if (!['', 'y', 'yes', 'n', 'no'].includes(terminal)) throw new Error('请输入 Y 或 N');
  next.terminal = !['n', 'no'].includes(terminal);
  return next;
}

// Keep raw mode throughout the wizard: toggling it between Windows TTY
// read callbacks can produce EPIPE. Restore once the wizard finishes.
let previousRaw: boolean | undefined;
export function closeSetupInput(): void {
  if (previousRaw === undefined) return;
  process.stdin.setRawMode(previousRaw);
  process.stdin.pause();
  previousRaw = undefined;
}
export const terminalPrompt: SetupPrompt = async (label, secret = false) => {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('首次设置需要交互式终端，请运行 start.cmd 或 --setup');
  const input = process.stdin;
  if (previousRaw === undefined) { previousRaw = input.isRaw ?? false; input.setRawMode(true); }
  input.setEncoding('utf8');
  process.stdout.write(label);
  return new Promise<string>((resolve, reject) => {
    let answer = '';
    const finish = (error?: Error) => {
      input.off('data', data); input.off('end', ended);
      process.stdout.write('\r\n');
      if (error) reject(error); else resolve(answer);
    };
    const ended = () => finish(new Error('设置已取消'));
    const data = (chunk: string) => {
      for (const char of chunk) {
        if (char === '\x03') { finish(new Error('设置已取消')); return; }
        if (char === '\r' || char === '\n') { finish(); return; }
        if (char === '\x7f' || char === '\b') {
          if (answer.length) { answer = answer.slice(0, -1); if (!secret) process.stdout.write('\b \b'); }
        } else if (char >= ' ') { answer += char; if (!secret) process.stdout.write(char); }
      }
    };
    input.on('data', data); input.once('end', ended); input.resume();
  });
};
