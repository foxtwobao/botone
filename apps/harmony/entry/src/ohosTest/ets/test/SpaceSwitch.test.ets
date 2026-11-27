// A2: the Space switch against the fixture server. The switch claims the Space in memory (every
// store resets, the roster stream reopens under the new header), persists it, and proves it with
// one spaces/list read; a Space the server refuses falls back through the existing 401 recovery,
// and an unreachable server keeps the chosen Space until a retry. All tokens and ids are fakes.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { app } from '../../../main/ets/app/app-state';
import { queryCache } from '../../../main/ets/query/query-cache';
import { clearSessionToken, saveSessionToken, selectedSpaceId, setSelectedSpace } from '../../../main/ets/net/session';
import { clearSelectedSpace, loadSelectedSpace } from '../../../main/ets/net/space-selection';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { activeRosterStream, holdRoster } from '../../../main/ets/realtime/roster';
import { foreground } from '../../../main/ets/realtime/foreground';
import { rosterStore } from '../../../main/ets/stores/roster-store';
import { archivedStore } from '../../../main/ets/stores/archived-store';
import { settingsStore } from '../../../main/ets/stores/settings-store';
import { spaceStore } from '../../../main/ets/stores/space-store';
import { SpaceSwitchController } from '../../../main/ets/features/spaces/space-switch-controller';
import type { InboxRow } from '../../../main/ets/stores/roster-projection';

const BASE = 'http://10.0.2.2:8787';

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
  for (let attempt = 0; attempt < 600; attempt += 1) {
    if (condition()) {
      return;
    }
    await pause(25);
  }
  throw new Error(`timed out waiting for ${label}`);
}

function hasRow(rows: InboxRow[], id: string): boolean {
  for (const row of rows) {
    if (row.id === id) {
      return true;
    }
  }
  return false;
}

export default function spaceSwitchTest() {
  describe('SpaceSwitchAgainstFixtureServer', () => {
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

    it('a_switch_reads_paints_and_persists_the_chosen_space', 0, async () => {
      const release = holdRoster();
      try {
        await waitFor((): boolean => hasRow(rosterStore.rows, 'bot-1'), 'first Space painted');
        const switcher = new SpaceSwitchController();
        expect(await switcher.switchTo('space-second')).assertTrue();
        expect(switcher.state.phase).assertEqual('done');
        // The proof read carried the new Space's header, the name follows it, the roster rows
        // are the new Space's, and the choice is on disk.
        expect(await requestCount('/rpc/spaces/list', 'space-second') >= 1).assertTrue();
        expect(spaceStore.currentName).assertEqual('Second Space');
        expect(await loadSelectedSpace()).assertEqual('space-second');
        await waitFor((): boolean => hasRow(rosterStore.rows, 'bot-s1'), 'second Space painted');
        expect(hasRow(rosterStore.rows, 'bot-1')).assertFalse();
        // And back again: a second switch from a done switch is a new one.
        expect(await switcher.switchTo('space-fake')).assertTrue();
        expect(spaceStore.currentName).assertEqual('Ada’s Space');
        await waitFor((): boolean => hasRow(rosterStore.rows, 'bot-1'), 'first Space repainted');
        expect(await loadSelectedSpace()).assertEqual('space-fake');
      } finally {
        release();
      }
    });

    it('a_deleted_target_falls_back_to_the_default_space', 0, async () => {
      await rosterStore.load();
      const switcher = new SpaceSwitchController();
      expect(await switcher.switchTo('space-stale')).assertFalse();
      // The 401 recovery cleared the selection and its stored copy; the account read that
      // follows lands on the server's default Space.
      expect(switcher.state.phase).assertEqual('idle');
      expect(await loadSelectedSpace()).assertEqual('');
      await waitFor((): boolean => selectedSpaceId() === 'space-fake'
        && spaceStore.currentName === 'Ada’s Space', 'default Space recovered');
      expect(spaceStore.spaces.length).assertEqual(2);
    });

    it('an_unreachable_switch_keeps_the_space_until_the_retry_succeeds', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        expect(rosterStore.error).assertEqual('');
        await fixture('__offline', '{"on":true}');
        const switcher = new SpaceSwitchController();
        expect(await switcher.switchTo('space-second')).assertFalse();
        // The Space stays chosen: only the proof read is missing.
        expect(switcher.state.phase).assertEqual('failed');
        expect(switcher.state.kept).assertEqual('space-second');
        expect(selectedSpaceId()).assertEqual('space-second');
        expect(switcher.error.length > 0).assertTrue();
        // The roster re-read the stream's reopen triggered could not reach the server either.
        await waitFor((): boolean => rosterStore.offline, 'offline ribbon state');
        await fixture('__offline', '{"on":false}');
        // The emulator's HTTP client wedges the request that follows a connection the server
        // destroyed, so the retry waits for one clean read before it runs.
        let reachable = false;
        for (let attempt = 0; attempt < 20 && !reachable; attempt++) {
          await rosterStore.load();
          reachable = rosterStore.error === '';
          if (!reachable) {
            await pause(700);
          }
        }
        expect(reachable).assertTrue();
        expect(await switcher.retry()).assertTrue();
        expect(switcher.error).assertEqual('');
        expect(spaceStore.currentName).assertEqual('Second Space');
        await waitFor((): boolean => hasRow(rosterStore.rows, 'bot-s1'), 'second Space painted');
      } finally {
        release();
      }
    });
  });
}