// A1: the selected Space is claimed in memory, persisted on disk, and encloses every read,
// write, stream and cache entry it was pinned under. Driven against the fixture server, whose
// spaces/list answers per x-rakazo-space-id (space-fake, space-second, and the deleted
// space-stale). All tokens and ids are fake probes.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { AppState, app } from '../../../main/ets/app/app-state';
import { queryCache } from '../../../main/ets/query/query-cache';
import { SaveController } from '../../../main/ets/query/save-controller';
import type { SaveSend } from '../../../main/ets/query/save-controller';
import { cachedArtifactPath, clearArtifactCache } from '../../../main/ets/net/artifact-cache';
import type { ArtifactRef } from '../../../main/ets/net/artifact-cache';
import {
  clearSessionToken,
  currentSpaceSelectionGeneration,
  saveSessionToken,
  selectedSpaceId,
  setSelectedSpace,
} from '../../../main/ets/net/session';
import {
  clearSelectedSpace,
  loadSelectedSpace,
  saveSelectedSpace,
} from '../../../main/ets/net/space-selection';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { activeRosterStream, holdRoster } from '../../../main/ets/realtime/roster';
import { foreground } from '../../../main/ets/realtime/foreground';
import { rosterStore } from '../../../main/ets/stores/roster-store';
import { archivedStore } from '../../../main/ets/stores/archived-store';
import { settingsStore } from '../../../main/ets/stores/settings-store';
import { spaceStore } from '../../../main/ets/stores/space-store';
import type { InboxRow } from '../../../main/ets/stores/roster-projection';

const BASE = 'http://10.0.2.2:8787';
const EMPTY: Record<string, Object> = {};

function context(): Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
}

async function fixture(path: string, body: string): Promise<void> {
  const response = await postJson(`${BASE}/${path}`, {}, body, 8000, 65536);
  expect(response.status).assertEqual(200);
}

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

async function requestLog(): Promise<Record<string, Object>[]> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  return body !== null ? body['requests'] as Record<string, Object>[] : [];
}

/** Requests to one procedure, optionally only those carrying one Space's header. */
async function requestCount(path: string, space: string): Promise<number> {
  let count = 0;
  for (const record of await requestLog()) {
    if (record['path'] === path && (space === '' || record['space'] === space)) {
      count += 1;
    }
  }
  return count;
}

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (condition()) {
      return;
    }
    await pause(25);
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function waitForRequests(path: string, space: string, atLeast: number): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if ((await requestCount(path, space)) >= atLeast) {
      return;
    }
    await pause(25);
  }
  throw new Error(`timed out waiting for ${path} in ${space}`);
}

function hasRow(rows: InboxRow[], id: string): boolean {
  for (const row of rows) {
    if (row.id === id) {
      return true;
    }
  }
  return false;
}

function botInput(id: string): Record<string, Object> {
  const input: Record<string, Object> = {};
  input['kind'] = 'bot';
  input['id'] = id;
  return input;
}

export default function spaceSelectionTest() {
  describe('SpaceSelectionAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      await initServerStore(context());
      await switchServer(BASE, {});
      rosterStore.start();
      archivedStore.start();
      settingsStore.start();
    });

    beforeEach(async () => {
      await fixture('__reset', '{}');
      await clearSelectedSpace();
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      queryCache.clear();
      rosterStore.reset();
      archivedStore.reset();
      settingsStore.reset();
      spaceStore.reset();
      foreground.set(true);
    });

    afterEach(async () => {
      activeRosterStream()?.stop();
      foreground.set(true);
      await clearSessionToken();
      setSelectedSpace('');
      await clearSelectedSpace();
      queryCache.clear();
    });

    it('a_space_change_resets_the_painted_stores_and_the_cache', 0, async () => {
      setSelectedSpace('space-fake');
      await rosterStore.load();
      await archivedStore.load();
      await settingsStore.load();
      await waitFor((): boolean => rosterStore.loaded && rosterStore.rows.length > 0, 'roster painted');
      expect(archivedStore.loaded).assertTrue();
      expect(settingsStore.loaded).assertTrue();
      // The roster read fills the Space screens from the same answer, without another request.
      expect(spaceStore.currentName).assertEqual('Ada’s Space');
      expect(spaceStore.spaces.length).assertEqual(2);
      expect(queryCache.peek('spaces/list', EMPTY) !== null).assertTrue();
      const before = (await requestLog()).length;
      setSelectedSpace('space-second');
      // The painted rows are gone at once; the cache keeps nothing from the other Space; and
      // the reset itself reads nothing (the stream's own catch-up read is not held here).
      expect(rosterStore.rows.length).assertEqual(0);
      expect(rosterStore.bots.length).assertEqual(0);
      expect(archivedStore.rows.length).assertEqual(0);
      expect(settingsStore.catalog.length).assertEqual(0);
      expect(queryCache.peek('spaces/list', EMPTY)).assertNull();
      await pause(300);
      expect((await requestLog()).length).assertEqual(before);
    });

    it('an_in_flight_spaces_list_from_the_old_space_never_paints', 0, async () => {
      setSelectedSpace('space-fake');
      await fixture('__holdSpacesList', '{}');
      const slow = rosterStore.load();
      await waitForRequests('/rpc/spaces/list', 'space-fake', 1);
      setSelectedSpace('space-second');
      await rosterStore.load();
      await waitFor((): boolean => hasRow(rosterStore.rows, 'bot-s1'), 'second Space painted');
      await fixture('__releaseSpacesList', '{}');
      await slow;
      await pause(300);
      // The old Space's late answer arrived, was refused by its scope, and painted nothing.
      expect(hasRow(rosterStore.rows, 'bot-s1')).assertTrue();
      expect(hasRow(rosterStore.rows, 'bot-1')).assertFalse();
    });

    it('the_signal_stream_reopens_in_the_new_space', 0, async () => {
      setSelectedSpace('space-fake');
      const release = holdRoster();
      try {
        await waitForRequests('/rpc/notifications/subscribe', 'space-fake', 1);
        setSelectedSpace('space-second');
        await waitForRequests('/rpc/notifications/subscribe', 'space-second', 1);
        const log = await requestLog();
        let last = '';
        for (const record of log) {
          if (record['path'] === '/rpc/notifications/subscribe') {
            last = record['space'] as string;
          }
        }
        expect(last).assertEqual('space-second');
      } finally {
        release();
        activeRosterStream()?.stop();
      }
    });

    it('a_write_pinned_to_the_old_space_is_refused', 0, async () => {
      setSelectedSpace('space-fake');
      const controller = new SaveController({
        save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
          await pause(60);
          const body: Record<string, Object> = {};
          body['botId'] = 'bot-1';
          await send('bots/archive', body);
        },
      });
      controller.run(botInput('bot-1'));
      setSelectedSpace('space-second');
      await waitFor((): boolean => !controller.pending, 'refused write');
      expect(controller.error.length > 0).assertTrue();
      // The pinned write never reached the server.
      expect(await requestCount('/rpc/bots/archive', '')).assertEqual(0);
    });

    it('an_artifact_download_across_a_space_change_is_refused', 0, async () => {
      setSelectedSpace('space-fake');
      clearArtifactCache(context());
      const ref: ArtifactRef = { artifactId: 'attachment-fake', botId: 'bot-1', groupId: '', mimeType: 'text/plain' };
      // The download pins its scope synchronously and yields before its context is captured;
      // the switch below lands inside that window.
      const pending = cachedArtifactPath(context(), ref);
      setSelectedSpace('space-second');
      let message = '';
      try {
        await pending;
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).assertEqual('ARTIFACT_SESSION_CHANGED');
    });

    it('the_selected_space_round_trips_through_storage', 0, async () => {
      await saveSelectedSpace('space-second');
      setSelectedSpace('');
      expect(await loadSelectedSpace()).assertEqual('space-second');
      await clearSelectedSpace();
      expect(await loadSelectedSpace()).assertEqual('');
    });

    it('a_reselection_still_bumps_the_selection_generation', 0, async () => {
      setSelectedSpace('space-fake');
      const before = currentSpaceSelectionGeneration();
      setSelectedSpace('space-fake');
      // The same id is a new claim: a late answer pinned before it can never pass as current.
      expect(currentSpaceSelectionGeneration() > before).assertTrue();
      expect(selectedSpaceId()).assertEqual('space-fake');
    });

    it('a_stale_stored_space_recovers_to_the_server_default', 0, async () => {
      // What bootstrap does with a Space deleted while this device was away: trust the disk,
      // then read the account. The first me read 401s, the recovery clears the selection and
      // the stored value, and the read lands on the server's default Space.
      await saveSelectedSpace('space-stale');
      setSelectedSpace(await loadSelectedSpace());
      const state = new AppState();
      await state.loadMe();
      expect(state.me !== null).assertTrue();
      expect(state.me!.spaceId).assertEqual('space-fake');
      expect(state.spaceName).assertEqual('Ada’s Space');
      expect(selectedSpaceId()).assertEqual('space-fake');
      expect(spaceStore.spaces.length).assertEqual(2);
      expect(await loadSelectedSpace()).assertEqual('');
    });
  });
}