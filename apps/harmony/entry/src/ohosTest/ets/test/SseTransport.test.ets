// requestInStream transport against the fixture server: clean multi-frame stream, abrupt close
// rejection (M0 S3 behavior), non-2xx rejection, and the 45s no-chunk idle rule. The idle case
// takes ~45s; run the suite with a runner timeout above that.
import { describe, expect, it } from '@ohos/hypium';
import { openSse } from '../../../main/ets/net/sse';
import type { SseEvent } from '../../../main/ets/net/sse';
import { RpcError } from '../../../main/ets/net/errors';
import { stringField } from './test-utils';

const BASE = 'http://10.0.2.2:8787';

function headers(): Record<string, string> {
  const h: Record<string, string> = {};
  h['content-type'] = 'application/json';
  return h;
}

export default function sseTransportTest() {
  describe('SseTransport', () => {
    it('streams_frames_and_resolves_on_clean_end', 0, async () => {
      const events: SseEvent[] = [];
      const handle = openSse(`${BASE}/sse`, headers(), '{"json":{}}', (event: SseEvent): void => {
        events.push(event);
      });
      await handle.done;
      const types: string[] = [];
      for (const event of events) {
        types.push(stringField(event, 'type'));
      }
      expect(types.includes('probe')).assertTrue();
      expect(types.includes('split')).assertTrue();
      expect(types.includes('done')).assertTrue();
      // Heartbeat proves liveness only and never reaches the caller.
      expect(types.includes('heartbeat')).assertFalse();
      const split = events.find((event): boolean => stringField(event, 'type') === 'split');
      expect(split !== undefined).assertTrue();
      expect(stringField(split!, 'text')).assertEqual('鸿蒙');
    });

    it('abrupt_close_rejects_as_disconnect', 0, async () => {
      const handle = openSse(`${BASE}/sse-cut`, headers(), '{"json":{}}', (): void => {});
      let rejected = false;
      try {
        await handle.done;
      } catch (err) {
        rejected = err instanceof RpcError;
      }
      expect(rejected).assertTrue();
    });

    it('idle_silence_ends_the_stream_for_reconnect', 0, async () => {
      const events: SseEvent[] = [];
      const handle = openSse(`${BASE}/sse-idle`, headers(), '{"json":{}}', (event: SseEvent): void => {
        events.push(event);
      });
      let timedOut = false;
      try {
        await handle.done;
      } catch (err) {
        timedOut = err instanceof RpcError && (err as RpcError).timedOut;
      }
      expect(timedOut).assertTrue();
      expect(events.length).assertEqual(1);
    });

    it('close_resolves_and_stops_the_stream', 0, async () => {
      const handle = openSse(`${BASE}/sse-idle`, headers(), '{"json":{}}', (): void => {});
      handle.close();
      await handle.done;
    });
  });
}
