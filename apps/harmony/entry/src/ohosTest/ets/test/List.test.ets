import assetSmoke from './AssetSmoke.test';
import sseSmoke from './SseSmoke.test';
import retryTest from './Retry.test';
import endpointTest from './Endpoint.test';
import sseParserTest from './SseParser.test';
import icuTest from './Icu.test';
import decodeTest from './Decode.test';
import sessionTest from './Session.test';
import netTest from './Net.test';
import sseTransportTest from './SseTransport.test';
import realBackendSmoke from './RealBackendSmoke.test';

export default function testsuite() {
  // Pure-logic fixture replays: no network, no device state.
  retryTest();
  endpointTest();
  sseParserTest();
  icuTest();
  decodeTest();
  // Device storage and transport: need the fixture server (scripts/spike-sse-server.mjs,
  // ports 8787 and 8788) reachable at 10.0.2.2.
  assetSmoke();
  sessionTest();
  netTest();
  sseTransportTest();
  sseSmoke();
  // Opt-in real-backend smoke; skips loudly without -s realBase.
  realBackendSmoke();
}
