import { chmod, mkdir, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import path from 'node:path';

import { randomToken } from '../shared/crypto.ts';

export type AgentConfig = {
  agentId: string;
  /** Pairing secret. Anyone holding it can drive terminals and Claude on this machine. */
  secret: string;
  relayUrl?: string;
  relayKey?: string;
  connectionMode?: 'local' | 'remote';
  roots?: string[];
  defaultCwd?: string;
  terminal?: boolean;
  localPort?: number;
  /** Explicit path to the local Herdr binary. */
  herdrPath?: string;
};

export function configDir(): string {
  return process.env.CLOUDTERMINAL_HOME || path.join(homedir(), '.cloudterminal');
}

export function configPath(): string {
  return path.join(configDir(), 'agent.json');
}

export async function loadConfig(file = configPath(), opts: { reset?: boolean } = {}): Promise<AgentConfig> {
  let existing: Partial<AgentConfig> = {};
  try {
    existing = JSON.parse(await readFile(file, 'utf8')) as Partial<AgentConfig>;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw new Error(`无法读取配置 ${file}: ${(err as Error).message}`);
  }
  if (!existing || typeof existing !== 'object' || Array.isArray(existing)) throw new Error('配置文件格式无效');
  if (existing.connectionMode !== undefined && !['local', 'remote'].includes(existing.connectionMode)) throw new Error('配置连接模式无效');
  if (existing.roots !== undefined && (!Array.isArray(existing.roots) || !existing.roots.length || existing.roots.some((r) => typeof r !== 'string' || !r.trim()))) throw new Error('配置目录范围无效');
  for (const key of ['agentId', 'secret', 'relayUrl', 'relayKey', 'defaultCwd', 'herdrPath'] as const) {
    if (existing[key] !== undefined && typeof existing[key] !== 'string') throw new Error(`配置字段 ${key} 无效`);
  }
  if (existing.terminal !== undefined && typeof existing.terminal !== 'boolean') throw new Error('配置终端选项无效');
  if (existing.localPort !== undefined && (!Number.isInteger(existing.localPort) || existing.localPort < 1 || existing.localPort > 65535)) throw new Error('配置端口无效');
  const fresh = opts.reset || !existing.agentId || !existing.secret;
  const config: AgentConfig = {
    ...existing,
    agentId: fresh ? `a_${randomToken(12)}` : existing.agentId!,
    secret: fresh ? randomToken(32) : existing.secret!,
  };
  if (fresh) await saveConfig(config, file);
  return config;
}

export async function saveConfig(config: AgentConfig, file = configPath()): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(config, null, 2) + '\n', { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await rename(temporary, file);
  } finally { await rm(temporary, { force: true }); }
  // writeFile's mode only applies on create; tighten existing files too.
  await chmod(file, 0o600).catch(() => {});
}
