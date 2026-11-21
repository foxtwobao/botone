// QueryCache semantics (design §5): three-layer scope key, paint-first peek, late-response
// rejection, invalidation and session clear. Driven with a fake transport (no network) so the
// scope guards are tested deterministically; only the session/server stores touch device storage.
import { describe, expect, it, beforeAll, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { queryCache, currentScope } from '../../../main/ets/query/query-cache';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import {
  clearSessionToken,
  currentSessionGeneration,
  saveSessionToken,
  setSelectedSpace,
} from '../../../main/ets/net/session';
import { app } from '../../../main/ets/app/app-state';

const BASE = 'http://10.0.2.2:8787';
const EMPTY: Record<string, Object> = {};

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 20);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

function value(text: string): Object {
  const record: Record<string, Object> = {};
  record['marker'] = text;
  return record;
}

export default function queryCacheTest() {
  describe('QueryCacheScope', () => {
    beforeAll(async () => {
      // The instrumented process also bootstraps the global app; detach its session listener so
      // the suites own the session without the app loading the account or holding a stream.
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    afterEach(async () => {
      queryCache.clear();
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('peek_is_null_before_any_read', 0, () => {
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
    });

    it('read_caches_and_peek_paints_first', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      const answer = await queryCache.read('spaces/list', EMPTY,
        async (context: RpcContext): Promise<Object> => value('first'));
      expect(answer !== null).assertTrue();
      const cached = queryCache.peek('spaces/list', EMPTY);
      expect(cached !== null).assertTrue();
      expect((cached as Record<string, Object>)['marker']).assertEqual('first');
    });

    it('scope_key_tracks_server_session_and_space', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      const before = currentScope();
      expect(before.includes('server:')).assertTrue();
      expect(before.includes('session:')).assertTrue();
      expect(before.includes('space:space-fake')).assertTrue();
      const generation = currentSessionGeneration();
      await saveSessionToken('another-token');
      expect(currentSessionGeneration() > generation).assertTrue();
      expect(currentScope() !== before).assertTrue();
    });

    it('peek_refuses_a_cached_answer_from_another_space', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      await queryCache.read('spaces/list', EMPTY, async (context: RpcContext): Promise<Object> => value('s1'));
      expect(queryCache.peek('spaces/list', EMPTY) !== null).assertTrue();
      setSelectedSpace('space-other');
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
      // Back in the original scope, the cached answer paints again.
      setSelectedSpace('space-fake');
      expect(queryCache.peek('spaces/list', EMPTY) !== null).assertTrue();
    });

    it('late_response_after_session_change_is_refused', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      let resolveFetch: (answer: Object) => void = (): void => {};
      let fetchStarted = false;
      const pending = new Promise<Object>((resolve: (answer: Object) => void): void => {
        resolveFetch = resolve;
      });
      const read = queryCache.read('spaces/list', EMPTY,
        (context: RpcContext): Promise<Object> => {
          fetchStarted = true;
          return pending;
        });
      // Wait until the context is pinned and the fetch is in flight, THEN move the session on.
      await waitFor((): boolean => fetchStarted, 'fetch to start');
      await saveSessionToken('new-token');
      resolveFetch(value('stale'));
      const answer = await read;
      expect(answer).assertNull();
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
    });

    it('invalidate_forgets_one_procedure_only', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      await queryCache.read('spaces/list', EMPTY, async (context: RpcContext): Promise<Object> => value('a'));
      await queryCache.read('bots/listArchived', EMPTY, async (context: RpcContext): Promise<Object> => value('b'));
      queryCache.invalidate('spaces/list');
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
      expect(queryCache.peek('bots/listArchived', EMPTY) !== null).assertTrue();
    });

    it('clear_forgets_every_read', 0, async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      await queryCache.read('spaces/list', EMPTY, async (context: RpcContext): Promise<Object> => value('a'));
      queryCache.clear();
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
    });
  });
}
