// SaveController contract (design §6.3, the useSave port): single-flight, context pinned at the
// tap and refused once the scope moves on, stale reads invalidated on success, pending/error owned
// by the controller. Writes go to the fixture server; the scope-refusal case never reaches it.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { SaveController } from '../../../main/ets/data/save-controller';
import type { SaveSend } from '../../../main/ets/data/save-controller';
import { queryCache } from '../../../main/ets/data/query-cache';
import { rpc } from '../../../main/ets/net/rpc';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { decodeBotList } from '../../../main/ets/contract/decode';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { getJson } from '../../../main/ets/net/http';
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

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function botInput(id: string): Record<string, Object> {
  const input: Record<string, Object> = {};
  input['kind'] = 'bot';
  input['id'] = id;
  return input;
}

export default function saveControllerTest() {
  describe('SaveControllerContract', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    beforeEach(async () => {
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      queryCache.clear();
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
      queryCache.clear();
    });

    it('single_flight_ignores_a_second_tap', 0, async () => {
      let calls = 0;
      let resolveSave: () => void = (): void => {};
      const controller = new SaveController({
        save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
          calls += 1;
          await new Promise<void>((resolve: () => void): void => {
            resolveSave = resolve;
          });
        },
      });
      controller.run(botInput('bot-1'));
      controller.run(botInput('bot-1'));
      expect(calls).assertEqual(1);
      expect(controller.pending).assertTrue();
      resolveSave();
      await waitFor((): boolean => !controller.pending, 'save to finish');
      expect(calls).assertEqual(1);
      expect(controller.error).assertEqual('');
    });

    it('success_invalidates_the_declared_stale_reads', 0, async () => {
      await queryCache.read('spaces/list', EMPTY, async (context: RpcContext): Promise<Object> => rpc('spaces/list', EMPTY, { context: context }));
      await queryCache.read('bots/listArchived', EMPTY, async (context: RpcContext): Promise<Object> => rpc('bots/listArchived', EMPTY, { context: context }));
      expect(queryCache.peek('spaces/list', EMPTY) !== null).assertTrue();
      const controller = new SaveController({
        save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
          const body: Record<string, Object> = {};
          body['botId'] = 'bot-1';
          await send('bots/archive', body);
        },
        stale: ['spaces/list', 'bots/listArchived'],
      });
      controller.run(botInput('bot-1'));
      await waitFor((): boolean => !controller.pending, 'archive to finish');
      expect(controller.error).assertEqual('');
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
      expect(queryCache.peek('bots/listArchived', EMPTY)).assertNull();
      // The server really archived it.
      const archived = decodeBotList(await rpc('bots/listArchived', EMPTY));
      expect(archived!.some((bot): boolean => bot.id === 'bot-1')).assertTrue();
    });

    it('write_is_refused_once_the_session_moves_on', 0, async () => {
      const controller = new SaveController({
        save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
          await pause(60);
          const body: Record<string, Object> = {};
          body['botId'] = 'bot-1';
          await send('bots/archive', body);
        },
      });
      controller.run(botInput('bot-1'));
      // The session changes while the save is in flight: the pinned write must not dispatch.
      await saveSessionToken('new-token');
      await waitFor((): boolean => !controller.pending, 'refused save to finish');
      expect(controller.error.length > 0).assertTrue();
      // Restore the fixture session to verify the write never reached the server.
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      const archived = decodeBotList(await rpc('bots/listArchived', EMPTY));
      expect(archived!.some((bot): boolean => bot.id === 'bot-1')).assertFalse();
    });

    it('failure_is_owned_by_the_controller', 0, async () => {
      const controller = new SaveController({
        save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
          const body: Record<string, Object> = {};
          body['botId'] = 'no-such-bot';
          await send('bots/archive', body);
        },
      });
      controller.run(botInput('no-such-bot'));
      await waitFor((): boolean => !controller.pending, 'failed save to finish');
      expect(controller.error.length > 0).assertTrue();
      controller.reset();
      expect(controller.error).assertEqual('');
    });
  });
}
