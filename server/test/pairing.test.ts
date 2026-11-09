// Pairing URI codec: the Windows client renders it as a QR code and the phone
// parses it. Covered here and by the Dart mirror so a rename breaks the build.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { decodePairUri, encodePairUri, normalizePairCode } from '../src/shared/pairing.ts';

describe('pairing URI', () => {
  it('round-trips relay, code and version', () => {
    const uri = encodePairUri({ relayUrl: 'wss://relay.example.com/ws', code: 'abcd2345', version: 1 });
    const decoded = decodePairUri(uri);
    assert.equal(decoded.ok, true);
    if (decoded.ok) {
      assert.equal(decoded.value.relayUrl, 'wss://relay.example.com/ws');
      assert.equal(decoded.value.code, 'ABCD2345');
      assert.equal(decoded.value.version, 1);
    }
  });

  it('normalizes dashed and lowercase codes', () => {
    assert.equal(normalizePairCode('abcd-2345'), 'ABCD2345');
    const decoded = decodePairUri('cloudterminal://pair?relay=ws%3A%2F%2F192.168.1.5%3A8787%2Fws&code=abcd-2345');
    assert.equal(decoded.ok, true);
    if (decoded.ok) assert.equal(decoded.value.code, 'ABCD2345');
  });

  it('rejects a foreign scheme or missing fields', () => {
    assert.equal(decodePairUri('https://example.com/?code=ABCD2345').ok, false);
    assert.equal(decodePairUri('cloudterminal://pair?code=ABCD2345').ok, false);
    assert.equal(decodePairUri('cloudterminal://pair?relay=not-a-url&code=ABCD2345').ok, false);
    assert.equal(decodePairUri('').ok, false);
  });

  it('accepts only ws/wss relay URLs', () => {
    assert.equal(decodePairUri('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD2345').ok, true);
    assert.equal(decodePairUri('cloudterminal://pair?relay=http%3A%2F%2Fr%2Fws&code=ABCD2345').ok, false);
  });

  it('rejects a code that is not 8 characters', () => {
    assert.equal(decodePairUri('cloudterminal://pair?relay=ws%3A%2F%2Fr%2Fws&code=ABC').ok, false);
  });
});
