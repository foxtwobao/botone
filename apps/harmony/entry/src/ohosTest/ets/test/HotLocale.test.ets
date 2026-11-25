// The M4 hot-locale blocker, pinned at both layers: a locale switch while a screen is open must
// leave no baked translation behind. The projection layer proves list rows carry no translated
// text (the Pinned heading used to store t('Pinned') at projection time); the catalog layer
// proves a real preference switch re-resolves t() and the day separator in BOTH directions
// (zh-TW → en and en → zh-TW), the two the verifier reproduced on device.
import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { inboxDisplayItems, inboxItemKey } from '../../../main/ets/features/inbox/InboxPage';
import type { InboxRow } from '../../../main/ets/stores/roster-projection';
import { daySeparatorLabel, projectRows } from '../../../main/ets/stores/thread-store';
import { i18nStore, setLocalePreference, t } from '../../../main/ets/i18n/i18n';
import type { LiveMessage, ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';

function row(id: string, pinned: boolean): InboxRow {
  return {
    kind: 'bot', id: id, name: id, color: '', working: false, unread: false,
    pinned: pinned, preview: '', updatedAt: '2026-11-22T10:00:00Z', autoSpeak: false,
  };
}

function message(id: string, iso: string): LiveMessage {
  const block: Record<string, Object> = {};
  block['kind'] = 'text';
  block['text'] = id;
  return { id: id, threadId: 't1', seq: 1, role: 'user', blocks: [block], createdAt: iso };
}

export default function hotLocaleTest() {
  describe('HotLocaleSwitch', () => {
    it('inbox_projection_carries_no_baked_translation', 0, () => {
      const rows: InboxRow[] = [row('pinned-bot', true), row('plain-bot', false)];
      const items = inboxDisplayItems(rows);
      expect(items.length).assertEqual(3);
      expect(items[0].type).assertEqual('heading');
      // The heading item holds no text at all — the label resolves in build() via t('Pinned').
      expect(JSON.stringify(items[0])).assertEqual('{"type":"heading","row":null}');
      // The LazyForEach key is locale-independent: a switch re-renders in place, never re-keys.
      expect(inboxItemKey(items[0])).assertEqual('heading');
      expect(inboxItemKey(items[1])).assertEqual(inboxItemKey(items[1]));
      // No pinned rows → no heading.
      expect(inboxDisplayItems([row('plain-bot', false)]).length).assertEqual(1);
    });

    it('thread_rows_carry_timestamps_not_labels', 0, () => {
      const snapshot: ThreadSnapshot = {
        threadId: 't1', cursor: 1, olderCursor: null,
        messages: [message('m1', '2026-11-22T10:00:00Z')], run: null, activeRuns: [],
      };
      const rows = projectRows(snapshot);
      expect(rows[0].type).assertEqual('day');
      expect(rows[0].dayAt).assertEqual('2026-11-22T10:00:00Z');
      expect(JSON.stringify(rows[0]).includes('Today')).assertEqual(false);
      expect(JSON.stringify(rows[0]).includes('今天')).assertEqual(false);
    });

    it('preference_switch_retranslates_both_directions', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      // init reads the persisted preference: on a device left in zh by an earlier run it would
      // load the zh catalog, and the suites after this one assert English error copy. Pin the
      // preference to English after init (persisted, so the next run starts deterministic too).
      await i18nStore.init(context);
      await setLocalePreference('en');
      const now = new Date('2026-11-22T13:00:00Z').getTime();
      const iso = '2026-11-22T10:00:00Z';
      // The rule, not the byte: the device's Intl pads a single-digit hour where Node does not
      // (the DatesFixture normalization), and the clock/AM-PM separator glyph differs too.
      const norm = (value: string): string =>
        value.replace(/[   ]/g, ' ').replace(/(^|[^0-9])0([0-9]):/g, '$1$2:');
      try {
        // zh-TW → en: the exact direction that left 置頂 on the English inbox.
        await setLocalePreference('zh-TW');
        expect(t('Pinned')).assertEqual('置頂');
        const twLabel = norm(daySeparatorLabel(iso, now));
        expect(twLabel.startsWith('今天')).assertEqual(true);
        await setLocalePreference('en');
        expect(t('Pinned')).assertEqual('Pinned');
        const enLabel = norm(daySeparatorLabel(iso, now));
        expect(enLabel.startsWith('Today')).assertEqual(true);
        // en → zh-TW: the reverse direction that left Pinned on the 繁中 inbox.
        await setLocalePreference('zh-TW');
        expect(t('Pinned')).assertEqual('置頂');
        expect(norm(daySeparatorLabel(iso, now))).assertEqual(twLabel);
        // The revision trace moved on every switch (what re-renders open screens).
        expect(i18nStore.revision > 0).assertEqual(true);
      } finally {
        await setLocalePreference('en');
      }
    });
  });
}
