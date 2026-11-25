// The client-build handshake (design §1.3): every RPC names this build so a server can refuse
// builds older than its minimum (426 → the update prompt). Kind "harmony" is its own entry in the
// contract's CLIENT_KINDS, gated by the server's harmony= minimum; the id is generated at build
// time by scripts/gen-client-build.ts.
import { CLIENT_BUILD_ID } from './client-build.generated';

export function clientBuildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  headers['x-rakazo-client-build'] = `harmony/${CLIENT_BUILD_ID}`;
  return headers;
}
