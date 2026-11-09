// Distribution config for the Windows client.
//
// A packaged client may ship a `bootstrap.json` with the relay address (and,
// for a private distribution, a registration key). It is the lowest-priority
// source: an explicit CLI flag or a saved `agent.json` always wins, so a user
// can always override or clear what the package shipped.
//
// The registration key here only controls who may register an agent on the
// relay; it is NEVER a substitute for the phone's one-time pairing code and is
// never written to logs.

import { readFile } from 'node:fs/promises';
import path from 'node:path';

import { relayAddress } from './setup.ts';

export type Bootstrap = {
  relayUrl?: string;
  relayKey?: string;
  invite?: string;
};

export type BootstrapResult = {
  value: Bootstrap;
  /** Absolute path that was read, when one was found. */
  source?: string;
  /** Actionable reason when the file existed but was unusable. */
  error?: string;
};

/**
 * Load `bootstrap.json`. Search order:
 *   1. `$CLOUDTERMINAL_BOOTSTRAP` (explicit file)
 *   2. `<baseDir>/bootstrap.json`
 *   3. `<baseDir>/cloudterminal.bootstrap.json`
 * A missing file is not an error; a malformed one is reported, never thrown.
 */
export async function loadBootstrap(baseDir: string): Promise<BootstrapResult> {
  const explicit = process.env.CLOUDTERMINAL_BOOTSTRAP;
  const candidates = explicit
    ? [path.resolve(explicit)]
    : [path.join(baseDir, 'bootstrap.json'), path.join(baseDir, 'cloudterminal.bootstrap.json')];

  for (const file of candidates) {
    let raw: string;
    try {
      raw = await readFile(file, 'utf8');
    } catch {
      continue; // Not present is fine.
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return { value: {}, source: file, error: `分发包配置无法解析：${file}` };
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { value: {}, source: file, error: '分发包配置格式无效' };
    }
    const record = parsed as Record<string, unknown>;
    const value: Bootstrap = {};
    if (typeof record.relayUrl === 'string' && record.relayUrl.trim()) {
      try {
        value.relayUrl = relayAddress(record.relayUrl);
      } catch {
        return { value: {}, source: file, error: `分发配置里的中继地址无效：${record.relayUrl}` };
      }
    }
    if (typeof record.relayKey === 'string' && record.relayKey.trim()) value.relayKey = record.relayKey;
    if (typeof record.invite === 'string' && record.invite.trim()) value.invite = record.invite;
    return { value, source: file };
  }

  return { value: {} };
}
