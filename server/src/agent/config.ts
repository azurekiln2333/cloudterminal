import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

import { randomToken } from '../shared/crypto.ts';

export type AgentConfig = {
  agentId: string;
  /** Pairing secret. Anyone holding it can drive Claude on this machine. */
  secret: string;
  relayUrl?: string;
  relayKey?: string;
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
  await writeFile(file, JSON.stringify(config, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 });
  // writeFile's mode only applies on create; tighten existing files too.
  await chmod(file, 0o600).catch(() => {});
}
