// Shared pairing URI codec. The same payload is rendered as a QR code by the
// Windows client and parsed by the phone. It carries the relay address plus the
// one-time pairing code and NEVER a long-lived secret.
//
// Mirrored by apps/cloudterminal_windows/lib/models/pairing_uri.dart; both sides
// have tests so a rename on one side breaks the build.

export type PairPayload = {
  relayUrl: string;
  code: string;
  version: number;
};

const SCHEME = 'cloudterminal';
const HOST = 'pair';

/** Encode the payload. Field order is stable so tests can assert the string. */
export function encodePairUri(payload: PairPayload): string {
  const params = new URLSearchParams({
    relay: payload.relayUrl,
    code: normalizePairCode(payload.code),
    v: String(payload.version ?? 1),
  });
  return `${SCHEME}://${HOST}?${params.toString()}`;
}

/** Strip everything but the code alphabet and upper-case it. */
export function normalizePairCode(code: string): string {
  return code.toUpperCase().replace(/[^0-9A-Z]/g, '');
}

function isRelayUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (url.protocol === 'ws:' || url.protocol === 'wss:') && url.hostname.length > 0;
  } catch {
    return false;
  }
}

/** Parse a scanned/pasted payload; returns an actionable Chinese error. */
export function decodePairUri(text: string): { ok: true; value: PairPayload } | { ok: false; error: string } {
  const trimmed = text.trim();
  if (!trimmed) return { ok: false, error: '二维码内容为空' };
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { ok: false, error: '无法识别的二维码内容' };
  }
  if (url.protocol !== `${SCHEME}:` || url.hostname !== HOST) {
    return { ok: false, error: '这不是 CloudTerminal 的配对二维码' };
  }
  const relay = url.searchParams.get('relay') ?? '';
  const code = normalizePairCode(url.searchParams.get('code') ?? '');
  if (!relay || !isRelayUrl(relay)) return { ok: false, error: '二维码里的中继地址无效' };
  if (code.length !== 8) return { ok: false, error: '二维码里的配对码无效' };
  const version = Number.parseInt(url.searchParams.get('v') ?? '1', 10) || 1;
  return { ok: true, value: { relayUrl: relay, code, version } };
}
