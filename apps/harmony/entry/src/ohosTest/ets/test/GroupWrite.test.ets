// M8 group writes against the fixture server with the REAL RpcClient and RosterStore: creation
// lands in spaces/list with its members, a stale membership baseline answers the server's
// precondition refusal (the exact status and message the group screen recognizes), and a rename
// round-trips. The fixture server and every id here are fake probes.
import { afterEach, beforeAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { app } from '../../../main/ets/app/app-state';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { rpc } from '../../../main/ets/net/rpc';
import { RpcError } from '../../../main/ets/net/errors';
import { getJson } from '../../../main/ets/net/http';
import { queryCache } from '../../../main/ets/query/query-cache';
import { rosterStore } from '../../../main/ets/stores/roster-store';
import { decodeGroupWithMembers } from '../../../main/ets/contract/decode-groups';
import { isGroupChangedError } from '../../../main/ets/features/groups/group-rules';
import type { GroupView } from '../../../main/ets/contract/decode';

const BASE = 'http://10.0.2.2:8787';

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
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

function groupOf(groups: GroupView[], id: string): GroupView | null {
  for (const group of groups) {
    if (group.id === id) {
      return group;
    }
  }
  return null;
}

function botIdsOf(group: GroupView): string[] {
  const ids: string[] = [];
  for (const member of group.members) {
    ids.push(member.botId);
  }
  return ids;
}

export default function groupWriteTest() {
  describe('GroupWriteAgainstFixtureServer', () => {
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
      rosterStore.reset();
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
      queryCache.clear();
      rosterStore.reset();
    });

    it('create_lands_in_spaces_list_with_its_members', 0, async () => {
      const botIds: string[] = ['bot-1', 'bot-2'];
      const body: Record<string, Object> = {};
      body['name'] = 'New Team';
      body['botIds'] = botIds;
      const created = decodeGroupWithMembers(await rpc('groups/create', body));
      expect(created !== null).assertTrue();
      expect(created!.name).assertEqual('New Team');
      expect(created!.members.length).assertEqual(2);

      await rosterStore.load();
      await waitFor((): boolean => groupOf(rosterStore.groups, created!.id) !== null,
        'created group in the roster');
      const listed = groupOf(rosterStore.groups, created!.id)!;
      expect(botIdsOf(listed).join(',')).assertEqual('bot-1,bot-2');
    });

    it('a_stale_membership_baseline_answers_the_precondition_refusal', 0, async () => {
      // group-1 seeded with bot-1 and bot-2; a baseline naming only bot-1 is what another
      // device's change leaves behind.
      const botIds: string[] = ['bot-1', 'bot-2'];
      const expected: string[] = ['bot-1'];
      const body: Record<string, Object> = {};
      body['groupId'] = 'group-1';
      body['botIds'] = botIds;
      body['expectedBotIds'] = expected;
      let error: RpcError | null = null;
      try {
        await rpc('groups/update', body);
      } catch (err) {
        error = err instanceof RpcError ? err as RpcError : null;
      }
      expect(error !== null).assertTrue();
      expect(error!.status).assertEqual(404);
      expect(error!.message).assertEqual('Group members changed. Refresh and try again.');
      expect(isGroupChangedError(error)).assertTrue();
    });

    it('rename_updates_the_group', 0, async () => {
      const body: Record<string, Object> = {};
      body['groupId'] = 'group-1';
      body['name'] = 'Renamed Team';
      const updated = decodeGroupWithMembers(await rpc('groups/update', body));
      expect(updated !== null).assertTrue();
      expect(updated!.name).assertEqual('Renamed Team');
      await rosterStore.load();
      await waitFor((): boolean => groupOf(rosterStore.groups, 'group-1') !== null,
        'renamed group in the roster');
      expect(groupOf(rosterStore.groups, 'group-1')!.name).assertEqual('Renamed Team');
    });
  });
}