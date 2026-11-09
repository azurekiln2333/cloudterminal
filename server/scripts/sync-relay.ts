// Relay-core copy sync (repo split, design §3).
//
// This repo keeps a copy of the relay core so the PC agent can run the LAN
// entry in-process without the public relay server. The relay server repo is
// the source of truth for these files; the copy here must stay identical to it.
//
//   npm run sync-relay -- <relay-server-repo>           copy + rewrite manifest
//   npm run sync-relay -- <relay-server-repo> --check   compare only, exit 1
//
// Never edit the copy in place: change the file in the relay server repo, then
// run this script here. `test/relay-core-sync.test.ts` fails when the copy and
// `relay-core.json` disagree.

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);

/** Files that exist in both repos, with identical contents. */
export const RELAY_CORE_FILES: readonly string[] = [
  'src/relay/relay.ts',
  'src/shared/relay-protocol.ts',
  'src/shared/protocol-account.ts',
  'src/shared/crypto.ts',
  'src/shared/log.ts',
];

export const DEFAULT_SOURCE = 'https://github.com/azurekiln2333/cloudterminal-relay-server';

/** This `server/` directory: the script lives in `server/scripts/`. */
export const SERVER_DIR = path.resolve(import.meta.dirname, '..');

export const MANIFEST_PATH = path.join(SERVER_DIR, 'relay-core.json');

export type RelayCoreManifest = {
  /** Where the copy came from. */
  source: string;
  /** Commit of the relay server repo the copy was taken from. */
  commit: string;
  /** Path → sha256 of the LF-normalized contents. */
  files: Record<string, string>;
};

/**
 * Hash file contents with CRLF folded to LF first, so a Windows clone and a
 * Linux checkout of the same commit produce the same hash.
 */
export function hashContents(text: string): string {
  return createHash('sha256').update(text.replace(/\r\n/g, '\n')).digest('hex');
}

export async function hashFile(file: string): Promise<string> {
  return hashContents(await readFile(file, 'utf8'));
}

/** Hash every relay-core file below `root`. Throws when one is missing. */
export async function hashAll(root: string): Promise<Record<string, string>> {
  const hashes: Record<string, string> = {};
  for (const file of RELAY_CORE_FILES) hashes[file] = await hashFile(path.join(root, file));
  return hashes;
}

export async function readManifest(file = MANIFEST_PATH): Promise<RelayCoreManifest> {
  return JSON.parse(await readFile(file, 'utf8')) as RelayCoreManifest;
}

/** Differences between two hash maps, as human-readable lines. */
export function diffHashes(expected: Record<string, string>, actual: Record<string, string>): string[] {
  const problems: string[] = [];
  for (const file of RELAY_CORE_FILES) {
    if (!(file in expected)) problems.push(`${file}: not listed in relay-core.json`);
    else if (!(file in actual)) problems.push(`${file}: missing`);
    else if (expected[file] !== actual[file]) problems.push(`${file}: ${actual[file]} != ${expected[file]}`);
  }
  for (const file of Object.keys(expected)) {
    if (!RELAY_CORE_FILES.includes(file)) problems.push(`${file}: listed in relay-core.json but not a copy file`);
  }
  return problems;
}

export const SYNC_HINT =
  'The relay core copy must match the relay server repo.\n' +
  'Fix it in the relay server repo first, then run:\n' +
  '  npm run sync-relay -- <path-to-cloudterminal-relay-server>';

async function headCommit(dir: string): Promise<string> {
  const { stdout } = await run('git', ['-C', dir, 'rev-parse', 'HEAD']);
  return stdout.trim();
}

async function main(argv: string[]): Promise<number> {
  const check = argv.includes('--check');
  const dirArg = argv.find((arg) => !arg.startsWith('--'));
  if (!dirArg) {
    console.error('usage: node scripts/sync-relay.ts <relay-server-repo> [--check]');
    return 2;
  }
  const source = path.resolve(dirArg);

  let sourceHashes: Record<string, string>;
  try {
    sourceHashes = await hashAll(source);
  } catch (err) {
    console.error(`cannot read the relay server repo at ${source}: ${(err as Error).message}`);
    return 2;
  }

  if (check) {
    const manifest = await readManifest();
    let localHashes: Record<string, string>;
    try {
      localHashes = await hashAll(SERVER_DIR);
    } catch (err) {
      // A file that is listed but absent locally is a drift too, not a crash.
      console.error(`cannot read the local relay core copy: ${(err as Error).message}\n${SYNC_HINT}`);
      return 1;
    }
    const problems = [
      ...new Set([...diffHashes(manifest.files, localHashes), ...diffHashes(manifest.files, sourceHashes)]),
    ];
    if (problems.length > 0) {
      console.error(['relay core is out of sync:', ...problems.map((line) => `  ${line}`), SYNC_HINT].join('\n'));
      return 1;
    }
    console.log(`relay core is in sync with ${manifest.source}@${manifest.commit.slice(0, 12)}`);
    return 0;
  }

  for (const file of RELAY_CORE_FILES) {
    const target = path.join(SERVER_DIR, file);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.join(source, file), target);
  }

  const commit = await headCommit(source);
  const manifest: RelayCoreManifest = { source: DEFAULT_SOURCE, commit, files: await hashAll(SERVER_DIR) };
  await writeFile(MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  console.log(`copied ${RELAY_CORE_FILES.length} files from ${DEFAULT_SOURCE}@${commit.slice(0, 12)}`);
  console.log(`wrote ${path.relative(process.cwd(), MANIFEST_PATH)}`);
  return 0;
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === import.meta.filename) {
  process.exit(await main(process.argv.slice(2)));
}
