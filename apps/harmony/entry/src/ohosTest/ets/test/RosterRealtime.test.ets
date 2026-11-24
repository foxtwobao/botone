// M2 integration against the fixture server with the REAL RosterStore/ArchivedStore and roster
// stream: the request log proves reads happen only on a signal or foreground (NO polling), the
// archive/restore closed loop refreshes both lists, foreground catches up, and a restart re-reads
// from the persisted session. The fixture server logs every /rpc request and injects signals.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { rosterStore } from '../../../main/ets/stores/roster-store';
import { archivedStore } from '../../../main/ets/stores/archived-store';
import { holdRoster } from '../../../main/ets/realtime/roster';
import { foreground } from '../../../main/ets/realtime/foreground';
import { queryCache } from '../../../main/ets/query/query-cache';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { getJson, postJson, parseJsonObject } from '../../../main/ets/net/http';
import type { InboxRow } from '../../../main/ets/stores/roster-projection';
import { app } from '../../../main/ets/app/app-state';

const BASE = 'http://10.0.2.2:8787';

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 25);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

async function spacesListCount(): Promise<number> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  let count = 0;
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      const record = item as Record<string, Object>;
      if (record['path'] === '/rpc/spaces/list') {
        count += 1;
      }
    }
  }
  return count;
}

async function mutate(botId: string, preview: string): Promise<void> {
  const input: Record<string, Object> = {};
  input['botId'] = botId;
  input['preview'] = preview;
  await postJson(`${BASE}/__mutate`, {}, JSON.stringify(input), 8000, 64 * 1024);
}

async function signal(type: string): Promise<void> {
  const input: Record<string, Object> = {};
  input['type'] = type;
  await postJson(`${BASE}/__signal`, {}, JSON.stringify(input), 8000, 64 * 1024);
}

function rowOf(rows: InboxRow[], id: string): InboxRow | null {
  for (const row of rows) {
    if (row.id === id) {
      return row;
    }
  }
  return null;
}

function target(kind: string, id: string): Record<string, Object> {
  const input: Record<string, Object> = {};
  input['kind'] = kind;
  input['id'] = id;
  return input;
}

export default function rosterRealtimeTest() {
  describe('RosterRealtimeAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
      rosterStore.start();
      archivedStore.start();
    });

    beforeEach(async () => {
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      queryCache.clear();
      rosterStore.reset();
      archivedStore.reset();
      foreground.set(true);
    });

    afterEach(async () => {
      foreground.set(true);
      await clearSessionToken();
      setSelectedSpace('');
      queryCache.clear();
      rosterStore.reset();
      archivedStore.reset();
    });

    it('reads_only_on_signal_never_on_a_timer', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded && rosterStore.rows.length > 0, 'initial roster');
        // Let the opening roster signal's catch-up read settle, then baseline the request log.
        await pause(400);
        const baseline = await spacesListCount();
        expect(baseline >= 1).assertTrue();

        // Another device changes a preview WITHOUT a signal: the client must not notice.
        await mutate('bot-2', 'Changed elsewhere');
        await pause(1500);
        expect(await spacesListCount()).assertEqual(baseline);
        expect(rowOf(rosterStore.rows, 'bot-2')!.preview).assertEqual('Hi there');

        // A roster signal drives exactly one re-read carrying the change.
        await signal('roster');
        await waitFor((): boolean => rowOf(rosterStore.rows, 'bot-2')!.preview === 'Changed elsewhere',
          'signal-driven refresh');
        expect(await spacesListCount()).assertEqual(baseline + 1);
      } finally {
        release();
      }
    });

    it('space_change_signal_alone_does_not_poll_the_roster', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded, 'initial roster');
        await pause(400);
        const baseline = await spacesListCount();
        // A runs signal is for run readers, not the inbox roster: no spaces/list re-read.
        await signal('runs');
        await pause(800);
        expect(await spacesListCount()).assertEqual(baseline);
        // The roster signal is what the inbox reads on.
        await signal('roster');
        let after = baseline;
        for (let attempt = 0; attempt < 100 && after <= baseline; attempt += 1) {
          await pause(25);
          after = await spacesListCount();
        }
        expect(after > baseline).assertTrue();
      } finally {
        release();
      }
    });

    it('archive_then_restore_closed_loop_refreshes_both_lists', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rowOf(rosterStore.rows, 'bot-1') !== null, 'bot-1 active');
        await archivedStore.load();
        await waitFor((): boolean => archivedStore.loaded, 'archived loaded');
        expect(rowOf(archivedStore.rows, 'bot-1')).assertNull();

        rosterStore.archive.run(target('bot', 'bot-1'));
        await waitFor((): boolean => !rosterStore.archive.pending, 'archive to finish');
        expect(rosterStore.archive.error).assertEqual('');
        await waitFor((): boolean => rowOf(rosterStore.rows, 'bot-1') === null, 'bot-1 leaves inbox');
        await archivedStore.load();
        await waitFor((): boolean => rowOf(archivedStore.rows, 'bot-1') !== null, 'bot-1 archived');

        archivedStore.restore.run(target('bot', 'bot-1'));
        await waitFor((): boolean => !archivedStore.restore.pending, 'restore to finish');
        expect(archivedStore.restore.error).assertEqual('');
        await waitFor((): boolean => rowOf(rosterStore.rows, 'bot-1') !== null, 'bot-1 back in inbox');
        await waitFor((): boolean => rowOf(archivedStore.rows, 'bot-1') === null, 'bot-1 leaves archived');
      } finally {
        release();
      }
    });

    it('group_archive_restore_closed_loop', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rowOf(rosterStore.rows, 'group-1') !== null, 'group-1 active');
        rosterStore.archive.run(target('group', 'group-1'));
        await waitFor((): boolean => !rosterStore.archive.pending, 'group archive');
        expect(rosterStore.archive.error).assertEqual('');
        await waitFor((): boolean => rowOf(rosterStore.rows, 'group-1') === null, 'group-1 leaves inbox');
        archivedStore.restore.run(target('group', 'group-1'));
        await waitFor((): boolean => !archivedStore.restore.pending, 'group restore');
        expect(archivedStore.restore.error).assertEqual('');
        await waitFor((): boolean => rowOf(rosterStore.rows, 'group-1') !== null, 'group-1 back');
      } finally {
        release();
      }
    });

    it('foreground_return_catches_up_on_missed_changes', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded, 'initial roster');
        await pause(300);
        // Go to background, change data elsewhere, come back: the foreground re-read catches up.
        foreground.set(false);
        await mutate('bot-2', 'While away');
        await pause(300);
        expect(rowOf(rosterStore.rows, 'bot-2')!.preview).assertEqual('Hi there');
        foreground.set(true);
        await waitFor((): boolean => rowOf(rosterStore.rows, 'bot-2')!.preview === 'While away',
          'foreground catch-up');
      } finally {
        release();
      }
    });

    it('restart_re_reads_from_the_persisted_session', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded, 'initial roster');
        // Simulate a process restart: in-memory cache and painted rows are gone, the asset token
        // survives. A fresh load repopulates from the server without re-authenticating.
        queryCache.clear();
        rosterStore.reset();
        expect(rosterStore.rows.length).assertEqual(0);
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded && rosterStore.rows.length > 0, 'restart roster');
        expect(rowOf(rosterStore.rows, 'bot-1') !== null).assertTrue();
      } finally {
        release();
      }
    });

    it('offline_read_keeps_the_last_rows_painted', 0, async () => {
      const release = holdRoster();
      try {
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.loaded && rosterStore.rows.length > 0, 'initial roster');
        const painted = rosterStore.rows.length;
        // The server drops read connections: the rows stay painted under an offline banner.
        const on: Record<string, Object> = {};
        on['on'] = true;
        await postJson(`${BASE}/__offline`, {}, JSON.stringify(on), 8000, 64 * 1024);
        await rosterStore.load();
        await waitFor((): boolean => rosterStore.offline, 'offline banner');
        expect(rosterStore.rows.length).assertEqual(painted);
        expect(rosterStore.error.length > 0).assertTrue();
        // Recovery: the next read clears the banner and refreshes.
        const off: Record<string, Object> = {};
        off['on'] = false;
        await postJson(`${BASE}/__offline`, {}, JSON.stringify(off), 8000, 64 * 1024);
        await rosterStore.load();
        await waitFor((): boolean => !rosterStore.offline && rosterStore.loaded, 'recovery');
      } finally {
        release();
      }
    });
  });
}
