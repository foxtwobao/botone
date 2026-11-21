// Replays the committed retry-policy fixture (generated from packages/core retry-policy.ts).
import { describe, expect, it } from '@ohos/hypium';
import { fixtureRetry } from './fixtures.generated';
import {
  isRetryableError,
  jitterMs,
  MAX_RETRY_AFTER_MS,
  parseRetryAfter,
  RECONNECT_SPREAD_MS,
  reconnectDelayMs,
  retryDelayMs,
} from '../../../main/ets/net/retry';
import { RpcError } from '../../../main/ets/net/errors';
import { boolField, numberField, recordOf, stringField } from './test-utils';

function errorFromSpec(spec: Object | undefined): RpcError | null {
  if (spec === undefined || spec === null) {
    return null;
  }
  if (typeof spec === 'string') {
    return new RpcError(spec as string);
  }
  const record = spec as Record<string, Object>;
  const text = stringField(record, 'text');
  const status = record['status'] !== undefined ? numberField(record, 'status') : 0;
  const asked = record['retryAfterMs'];
  const retryAfterMs = typeof asked === 'number' ? asked as number : -1;
  return new RpcError(text, status, '', retryAfterMs);
}

export default function retryTest() {
  describe('RetryFixture', () => {
    const fixture = recordOf(fixtureRetry);
    const constants = fixture['constants'] as Record<string, Object>;

    it('constants_match_core', 0, () => {
      expect(MAX_RETRY_AFTER_MS).assertEqual(numberField(constants, 'maxRetryAfterMs'));
      expect(RECONNECT_SPREAD_MS).assertEqual(numberField(constants, 'reconnectSpreadMs'));
    });

    it('isRetryable_matches_core', 0, () => {
      for (const item of fixture['isRetryable'] as Object[]) {
        const entry = item as Record<string, Object>;
        const actual = isRetryableError(errorFromSpec(entry['error']));
        expect(actual).assertEqual(boolField(entry, 'expected'));
      }
    });

    it('parseRetryAfter_matches_core', 0, () => {
      for (const item of fixture['parseRetryAfter'] as Object[]) {
        const entry = item as Record<string, Object>;
        const raw = entry['value'];
        const value = typeof raw === 'string' ? raw as string : null;
        const actual = parseRetryAfter(value, numberField(entry, 'now')) ?? null;
        const expected = entry['expected'] === null ? null : numberField(entry, 'expected');
        expect(actual).assertEqual(expected);
      }
    });

    it('jitter_matches_core', 0, () => {
      for (const item of fixture['jitter'] as Object[]) {
        const entry = item as Record<string, Object>;
        const actual = jitterMs(numberField(entry, 'ms'), numberField(entry, 'random'));
        expect(actual).assertEqual(numberField(entry, 'expected'));
      }
    });

    it('retryDelay_matches_core', 0, () => {
      for (const item of fixture['retryDelay'] as Object[]) {
        const entry = item as Record<string, Object>;
        const actual = retryDelayMs(errorFromSpec(entry['error']), numberField(entry, 'backoffMs'),
          numberField(entry, 'random'));
        expect(actual).assertEqual(numberField(entry, 'expected'));
      }
    });

    it('reconnectDelay_matches_core', 0, () => {
      for (const item of fixture['reconnectDelay'] as Object[]) {
        const entry = item as Record<string, Object>;
        const actual = reconnectDelayMs(errorFromSpec(entry['error']), numberField(entry, 'random'));
        expect(actual).assertEqual(numberField(entry, 'expected'));
      }
    });
  });
}
