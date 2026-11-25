// Replays the committed layer-2 markdown fixture: every document through the ArkTS md4c port and
// its tree compared as one JSON string against the wasm build of the same parser (484 cases:
// hand corpus, every named entity, seeded fuzz documents).
import { describe, expect, it } from '@ohos/hypium';
import { fixtureMarkdown } from './fixtures.generated';
import { recordOf, stringField } from './test-utils';
import { mdCompact, parseMarkdown } from '../../../main/ets/thread/markdown-lite';

export default function markdownFixtureTest() {
  describe('MarkdownFixture', () => {
    const fixture = recordOf(fixtureMarkdown);
    const cases = fixture['cases'] as Object[];

    it('trees_match_the_reference_parser', 0, () => {
      let checked = 0;
      for (const item of cases) {
        const entry = item as Record<string, Object>;
        const name = stringField(entry, 'name');
        const markdown = stringField(entry, 'markdown');
        const tree = entry['tree'];
        const expected = JSON.stringify(tree);
        const actual = mdCompact(parseMarkdown(markdown));
        if (actual !== expected) {
          throw new Error(`[${name}] ${JSON.stringify(markdown).slice(0, 120)}\nexpected ${expected.slice(0, 400)}\nactual   ${actual.slice(0, 400)}`);
        }
        checked += 1;
      }
      expect(checked).assertEqual(cases.length);
      expect(checked > 400).assertTrue();
    });
  });
}
