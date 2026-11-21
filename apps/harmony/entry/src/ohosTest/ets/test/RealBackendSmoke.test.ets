// M1 DoD: the real-backend smoke (S3 formal close-out) — a real self-hosted API, real sign-in,
// real me/spaces reads, and a real notifications/subscribe SSE stream opened, fed, closed and
// reopened (reconnect catch-up). Opt-in: pass the server and a throwaway account through the
// runner arguments, e.g.
//   hdc shell aa test -b com.botone.app -m entry_test -s unittest OpenHarmonyTestRunner \
//     -s timeout 120000 -s realBase http://10.0.2.2:3100 -s realEmail smoke@example.com \
//     -s realPassword <fake-placeholder>
// Without realBase the suite logs a loud skip and asserts nothing: an offline run must not
// pretend this smoke happened. The run that counts is recorded in docs/m1-notes.md.
import { describe, expect, it, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { probeApiBase } from '../../../main/ets/net/endpoint';
import { signIn, signOut } from '../../../main/ets/net/auth';
import { rpc, captureContext } from '../../../main/ets/net/rpc';
import { decodeMe, decodeSpaceNavigation } from '../../../main/ets/contract/decode';
import { loadSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { subscribeRpcEvents } from '../../../main/ets/net/sse';
import type { SseEvent } from '../../../main/ets/net/sse';
import { stringField } from './test-utils';

const DOMAIN = 0x0000;

function arg(name: string): string {
  const params = abilityDelegatorRegistry.getArguments().parameters;
  // aa test stores the raw flag as the key ("-s realBase"), hypium also accepts the bare name.
  return params[name] ?? params[`-s ${name}`] ?? '';
}

function configured(): boolean {
  if (arg('realBase')) {
    return true;
  }
  hilog.warn(DOMAIN, 'M1', 'RealBackendSmoke SKIPPED: pass -s realBase/realEmail/realPassword to run it');
  return false;
}

async function waitForEvent(events: SseEvent[], type: string, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (events.some((event): boolean => stringField(event, 'type') === type)) {
      return true;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 100);
    });
  }
  return false;
}

export default function realBackendSmoke() {
  describe('RealBackendSmoke', () => {
    beforeAll(async () => {
      if (!configured()) {
        return;
      }
      // Earlier suites leave the store on the fixture server; point it at the real one first.
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      const switched = await switchServer(arg('realBase'), {});
      expect(switched.ok).assertTrue();
    });

    it('real_server_login_me_spaces_sse_and_signout', 0, async () => {
      if (!configured()) {
        return;
      }
      const base = arg('realBase');
      const email = arg('realEmail');
      const password = arg('realPassword');

      const probed = await probeApiBase(base, {});
      expect(probed.ok).assertTrue();
      hilog.info(DOMAIN, 'M1', 'real health ok: %{public}s', probed.url);

      await signIn(email, password);
      expect((await loadSessionToken()).length > 0).assertTrue();

      const me = decodeMe(await rpc('me', {}));
      expect(me !== null).assertTrue();
      hilog.info(DOMAIN, 'M1', 'real me: %{public}s', me!.email);
      setSelectedSpace(me!.spaceId);
      const spaces = decodeSpaceNavigation(await rpc('spaces/list', {}));
      expect(spaces !== null).assertTrue();
      hilog.info(DOMAIN, 'M1', 'real space: %{public}s', spaces!.currentName);

      // One real SSE stream: open, receive the opening roster signal, close, reopen and catch up.
      const context = await captureContext();
      const first: SseEvent[] = [];
      const input: Record<string, Object> = {};
      const stream1 = subscribeRpcEvents(context.apiBase, 'notifications/subscribe', input,
        context.headers, (event: SseEvent): void => {
          first.push(event);
        });
      expect(await waitForEvent(first, 'roster', 15_000)).assertTrue();
      hilog.info(DOMAIN, 'M1', 'real SSE first stream events=%{public}d', first.length);
      stream1.close();
      await stream1.done;

      const second: SseEvent[] = [];
      const stream2 = subscribeRpcEvents(context.apiBase, 'notifications/subscribe', input,
        context.headers, (event: SseEvent): void => {
          second.push(event);
        });
      expect(await waitForEvent(second, 'roster', 15_000)).assertTrue();
      hilog.info(DOMAIN, 'M1', 'real SSE reconnect events=%{public}d', second.length);
      stream2.close();
      await stream2.done;

      await signOut();
      expect(await loadSessionToken()).assertEqual('');
      hilog.info(DOMAIN, 'M1', 'real backend smoke complete');
    });
  });
}
