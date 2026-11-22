// Replays the committed dates fixture: the localized dates must match the REAL references under
// each shipped UI locale — mobile's formatThreadTime for inbox rows (today clock / weekday / short
// date) and core's formatTimeSeparator for thread day separators (label or weekday + clock, older
// a short date with the year only when it differs).
import { describe, expect, it } from '@ohos/hypium';
import { fixtureDates } from './fixtures.generated';
import { formatRowTime, formatThreadSeparator } from '../../../main/ets/i18n/dates';
import { i18nStore } from '../../../main/ets/i18n/i18n';
import { recordOf, stringField } from './test-utils';

export default function datesTest() {
  describe('DatesFixture', () => {
    it('dates_match_the_references', 0, () => {
      const fixture = recordOf(fixtureDates);
      const previous = i18nStore.locale;
      let checked = 0;
      // Node's Intl and the device's Intl differ in two cosmetic bytes the RULE doesn't own: the
      // separator between clock and AM/PM (U+202F narrow no-break vs U+0020) and a padded leading
      // zero on a single-digit hour ("09:30" vs "9:30"). The fixture pins the rules; the replay
      // normalizes those two glyphs on both sides.
      const norm = (value: string): string =>
        value.replace(/[\u00a0\u202f ]/g, ' ').replace(/(^|[^0-9])0([0-9]):/g, '$1$2:');
      try {
        for (const item of fixture['cases'] as Object[]) {
          const entry = item as Record<string, Object>;
          const locale = stringField(entry, 'locale');
          // The formatters read the active UI locale; the fixture pins one per case.
          i18nStore.locale = locale;
          const iso = stringField(entry, 'iso');
          const now = new Date(stringField(entry, 'now')).getTime();
          const kind = stringField(entry, 'kind');
          let actual: string;
          if (kind === 'separator') {
            // The localized labels ride with the case: the test env loads no catalog, and the
            // app passes its own t('Today')/t('Yesterday') here.
            const today = stringField(entry, 'today');
            const yesterday = stringField(entry, 'yesterday');
            actual = formatThreadSeparator(iso, now, today, yesterday);
          } else {
            actual = formatRowTime(iso, now);
          }
          const expected = stringField(entry, 'expected');
          if (norm(actual) !== norm(expected)) {
            throw new Error(`[${locale}] ${kind} ${iso}\nexpected ${expected}\nactual   ${actual}`);
          }
          checked += 1;
        }
      } finally {
        i18nStore.locale = previous;
      }
      expect(checked).assertEqual(45);
    });
  });
}
