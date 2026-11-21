// Replays the committed ICU fixture: every en/zh-CN plural message at four counts plus the
// interpolation set, expected values evaluated by @lingui/core over the real catalogs.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureIcu } from './fixtures.generated';
import { formatIcu } from '../../../main/ets/i18n/icu';
import { recordOf, stringField } from './test-utils';

export default function icuTest() {
  describe('IcuFixture', () => {
    const fixture = recordOf(fixtureIcu);

    it('evaluation_matches_lingui', 0, () => {
      let checked = 0;
      for (const item of fixture['cases'] as Object[]) {
        const entry = item as Record<string, Object>;
        const message = stringField(entry, 'message');
        const locale = stringField(entry, 'locale');
        const values: Record<string, Object> = {};
        const rawValues = entry['values'] as Record<string, Object>;
        for (const key of Object.keys(rawValues)) {
          values[key] = rawValues[key];
        }
        const actual = formatIcu(message, values, locale);
        const expected = stringField(entry, 'expected');
        if (actual !== expected) {
          throw new Error(`[${locale}] ${stringField(entry, 'msgid')}\nexpected ${expected}\nactual   ${actual}`);
        }
        checked += 1;
      }
      expect(checked > 100).assertTrue();
    });
  });
}
