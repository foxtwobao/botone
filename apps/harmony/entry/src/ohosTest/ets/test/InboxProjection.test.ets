// Layer-2 replay: the inbox projection must agree value-for-value with the fixture generated from
// the REAL core helpers (groupBotsForSidebar / chatSnoozed / isRunWorking). Pure logic, no network.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureInbox } from './fixtures.generated';
import { recordOf, arrayOf, stringField, boolField, numberField } from './test-utils';
import { chatSnoozed, isRunWorking, projectInbox } from '../../../main/ets/stores/roster-projection';
import type { BotView, GroupView } from '../../../main/ets/contract/decode';

function botsOf(json: string): BotView[] {
  const rows: BotView[] = [];
  for (const item of arrayOf(json)) {
    const r = item as Record<string, Object>;
    const snoozed = r['snoozedUntil'];
    const bot: BotView = {
      id: stringField(r, 'id'), name: stringField(r, 'name'), color: stringField(r, 'color'),
      pinned: boolField(r, 'pinned'), unread: boolField(r, 'unread'), preview: stringField(r, 'preview'),
      status: stringField(r, 'status'), updatedAt: stringField(r, 'updatedAt'),
      snoozedUntil: typeof snoozed === 'string' ? snoozed as string : null,
    };
    rows.push(bot);
  }
  return rows;
}

function groupsOf(json: string): GroupView[] {
  const rows: GroupView[] = [];
  for (const item of arrayOf(json)) {
    const r = item as Record<string, Object>;
    const snoozed = r['snoozedUntil'];
    const group: GroupView = {
      id: stringField(r, 'id'), name: stringField(r, 'name'), pinned: boolField(r, 'pinned'),
      unread: boolField(r, 'unread'), preview: stringField(r, 'preview'), updatedAt: stringField(r, 'updatedAt'),
      snoozedUntil: typeof snoozed === 'string' ? snoozed as string : null,
    };
    rows.push(group);
  }
  return rows;
}

export default function inboxProjectionTest() {
  describe('InboxProjectionFixture', () => {
    const fixture = recordOf(fixtureInbox);

    it('working_matches_core_isRunWorking', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['working']))) {
        const r = item as Record<string, Object>;
        expect(isRunWorking(stringField(r, 'status'))).assertEqual(boolField(r, 'expected'));
      }
    });

    it('snoozed_matches_core_chatSnoozed', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['snoozed']))) {
        const r = item as Record<string, Object>;
        const snoozed = r['snoozedUntil'];
        const value = typeof snoozed === 'string' ? snoozed as string : null;
        expect(chatSnoozed(value, numberField(r, 'now'))).assertEqual(boolField(r, 'expected'));
      }
    });

    it('projection_order_and_working_match_core', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['cases']))) {
        const c = item as Record<string, Object>;
        const bots = botsOf(JSON.stringify(c['bots']));
        const groups = groupsOf(JSON.stringify(c['groups']));
        const rows = projectInbox(bots, groups, numberField(c, 'now'));
        const expected = arrayOf(JSON.stringify(c['expected']));
        expect(rows.length).assertEqual(expected.length);
        for (let i = 0; i < expected.length; i += 1) {
          const e = expected[i] as Record<string, Object>;
          expect(rows[i].kind).assertEqual(stringField(e, 'kind'));
          expect(rows[i].id).assertEqual(stringField(e, 'id'));
          expect(rows[i].working).assertEqual(boolField(e, 'working'));
        }
      }
    });
  });
}
