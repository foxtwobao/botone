// The read-only model display match (design §4.3.4/Q6): the account's default model names a catalog
// entry by provider AND id; anything else falls back to the generic copy, never a raw id.
import { describe, expect, it } from '@ohos/hypium';
import { defaultModelEntry } from '../../../main/ets/stores/model-display';
import { decodeMe, decodeModelCatalog } from '../../../main/ets/contract/decode';
import type { MeView, ModelCatalogEntryView } from '../../../main/ets/contract/decode';

function me(provider: string | null, model: string | null): MeView {
  const json = `{"userId":"u1","email":"a@b.c","name":"A","spaceId":"s1","needsModel":false,`
    + `"defaultProvider":${provider === null ? 'null' : `"${provider}"`},`
    + `"defaultModel":${model === null ? 'null' : `"${model}"`}}`;
  return decodeMe(JSON.parse(json))!;
}

function catalog(): ModelCatalogEntryView[] {
  return decodeModelCatalog(JSON.parse(
    '[{"provider":"p1","id":"m1","label":"Fast Model","providerName":"Maker"},'
    + '{"provider":"p2","id":"m1","label":"Other Maker Same Id"},'
    + '{"provider":"p1","id":"m2","label":"Second Model"}]'))!;
}

export default function modelDisplayTest() {
  describe('ModelDisplay', () => {
    it('matches_on_provider_and_id_and_returns_the_server_label', 0, () => {
      const entry = defaultModelEntry(me('p1', 'm1'), catalog());
      expect(entry !== null).assertTrue();
      expect(entry!.label).assertEqual('Fast Model');
      // The same id under another provider is a different model.
      expect(defaultModelEntry(me('p2', 'm1'), catalog())!.label).assertEqual('Other Maker Same Id');
      expect(defaultModelEntry(me('p1', 'm2'), catalog())!.label).assertEqual('Second Model');
    });

    it('no_match_yields_null_so_the_caller_shows_generic_copy', 0, () => {
      // Unknown provider, unknown id, no default at all, and no account: all fall back.
      expect(defaultModelEntry(me('nope', 'm1'), catalog())).assertNull();
      expect(defaultModelEntry(me('p1', 'nope'), catalog())).assertNull();
      expect(defaultModelEntry(me(null, 'm1'), catalog())).assertNull();
      expect(defaultModelEntry(me('p1', null), catalog())).assertNull();
      expect(defaultModelEntry(me(null, null), catalog())).assertNull();
      expect(defaultModelEntry(null, catalog())).assertNull();
      // An empty catalog (older server, or the read has not landed) also falls back.
      expect(defaultModelEntry(me('p1', 'm1'), [])).assertNull();
    });
  });
}
