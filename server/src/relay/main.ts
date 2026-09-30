// Relay server entrypoint.
//
//   PORT=8787 HOST=0.0.0.0 RELAY_KEY=... node src/relay/main.ts
//
// Put it behind a TLS terminator (Caddy / Nginx) for internet use and set
// RELAY_TRUST_PROXY=1 so per-IP rate limiting sees the real client address.

import { consoleLogger } from '../shared/log.ts';
import { createRelay } from './relay.ts';

const log = consoleLogger('relay');
const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? '0.0.0.0';
const relayKey = process.env.RELAY_KEY || undefined;

const relay = createRelay({ relayKey, logger: log });
await relay.listen(port, host);
log.info('listening', { url: `ws://${host}:${port}/ws`, relayKey: relayKey ? 'required' : 'off' });
if (!relayKey) log.warn('RELAY_KEY not set: any agent may register on this relay');

const shutdown = () => {
  log.info('shutting down');
  void relay.close().then(() => process.exit(0));
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
