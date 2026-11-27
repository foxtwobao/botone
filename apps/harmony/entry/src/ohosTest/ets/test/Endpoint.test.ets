// Replays the committed endpoint fixture (generated from mobile endpoint.ts + contracts
// network-host.ts): URL normalization, the http-private-network rule, and host classification.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureEndpoint } from './fixtures.generated';
import { isPrivateNetworkHost, normalizeApiBase } from '../../../main/ets/net/endpoint';
import { boolField, recordOf, stringField } from './test-utils';

export default function endpointTest() {
  describe('EndpointFixture', () => {
    const fixture = recordOf(fixtureEndpoint);

    it('normalize_matches_mobile', 0, () => {
      for (const item of fixture['normalize'] as Object[]) {
        const entry = item as Record<string, Object>;
        const input = stringField(entry, 'input');
        const result = normalizeApiBase(input);
        const expectedOk = boolField(entry, 'ok');
        if (result.ok !== expectedOk) {
          throw new Error(`normalize("${input}"): expected ok=${expectedOk}, got ok=${result.ok} url=${result.url} error=${result.error}`);
        }
        if (result.ok) {
          expect(result.url).assertEqual(stringField(entry, 'url'));
        } else {
          expect(result.error).assertEqual(stringField(entry, 'error'));
        }
      }
    });

    it('private_host_classification_matches_contracts', 0, () => {
      for (const item of fixture['privateHost'] as Object[]) {
        const entry = item as Record<string, Object>;
        const host = stringField(entry, 'host');
        expect(isPrivateNetworkHost(host)).assertEqual(boolField(entry, 'expected'));
      }
    });
  });
}
