// The relay core under `src/` is a copy of the relay server repo (design §3).
//
// Nothing here should ever be edited in place: the relay server repo owns
// `relay.ts`, `relay-protocol.ts`, `protocol-account.ts`, `crypto.ts` and
// `log.ts`, and `relay-core.json` records the commit and hashes it was taken
// from. This test fails when the copy drifts from that record.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  RELAY_CORE_FILES,
  SERVER_DIR,
  SYNC_HINT,
  diffHashes,
  hashAll,
  readManifest,
} from '../scripts/sync-relay.ts';

test('the relay core copy matches relay-core.json', async () => {
  const manifest = await readManifest();

  assert.match(manifest.source, /^https:\/\/github\.com\//, `relay-core.json: unexpected source ${manifest.source}`);
  assert.match(manifest.commit, /^[0-9a-f]{40}$/, `relay-core.json: unexpected commit ${manifest.commit}`);

  // A file added to one repo but forgotten here would otherwise never be checked.
  assert.deepEqual(
    Object.keys(manifest.files).sort(),
    [...RELAY_CORE_FILES].sort(),
    `relay-core.json: file list mismatch. ${SYNC_HINT}`,
  );

  const problems = diffHashes(manifest.files, await hashAll(SERVER_DIR));
  assert.deepEqual(problems, [], `relay core copy is out of sync:\n${problems.join('\n')}\n${SYNC_HINT}`);
});
