// S4 spike: @ohos.security.asset add/query/remove round trip — the store that will hold
// session tokens and saved servers. Uses a fake probe secret, never real credentials.
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { describe, expect, it } from '@ohos/hypium';

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function fromBytes(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

export default function assetSmoke() {
  describe('AssetSmoke', () => {
    it('add_query_remove_round_trip', 0, async () => {
      // A fresh alias per run keeps the spike repeatable after an interrupted earlier run.
      const alias = toBytes(`m0-spike-${Date.now()}`);
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, alias);
      attrs.set(asset.Tag.SECRET, toBytes('probe-secret-value'));
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attrs);

      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, alias);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const found = await asset.query(query);
      expect(found.length).assertEqual(1);
      const stored = found[0].get(asset.Tag.SECRET) as Uint8Array;
      expect(fromBytes(stored)).assertEqual('probe-secret-value');

      // remove() rejects query-only tags such as RETURN_TYPE; it takes the alias alone.
      const removal: asset.AssetMap = new Map();
      removal.set(asset.Tag.ALIAS, alias);
      await asset.remove(removal);
      let notFound = false;
      try {
        await asset.query(query);
      } catch (err) {
        notFound = true;
      }
      expect(notFound).assertTrue();
    });
  });
}
