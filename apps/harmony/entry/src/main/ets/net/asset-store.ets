// Key-grade secret storage over @ohos.security.asset (design §5.3): tokens, saved servers and
// their custom headers live here, never in preferences. DEVICE_FIRST_UNLOCKED matches the M0
// smoke. add is not idempotent (24000003 = already exists), so a put adds then updates.
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const NOT_FOUND = 24000002;
const ALREADY_EXISTS = 24000003;

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function fromBytes(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

function aliasMap(alias: string): asset.AssetMap {
  const map: asset.AssetMap = new Map();
  map.set(asset.Tag.ALIAS, toBytes(alias));
  return map;
}

/** The stored string, or null when the alias does not exist. Other failures throw. */
export async function assetGetString(alias: string): Promise<string | null> {
  const query = aliasMap(alias);
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const found = await asset.query(query);
    if (found.length === 0) {
      return null;
    }
    const secret = found[0].get(asset.Tag.SECRET);
    return secret === undefined ? null : fromBytes(secret as Uint8Array);
  } catch (err) {
    if ((err as BusinessError).code === NOT_FOUND) {
      return null;
    }
    throw err as Error;
  }
}

export async function assetPutString(alias: string, value: string): Promise<void> {
  const attrs = aliasMap(alias);
  attrs.set(asset.Tag.SECRET, toBytes(value));
  attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  try {
    await asset.add(attrs);
  } catch (err) {
    if ((err as BusinessError).code !== ALREADY_EXISTS) {
      throw err as Error;
    }
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.SECRET, toBytes(value));
    await asset.update(aliasMap(alias), attributes);
  }
}

/** Removes the alias; an absent alias is already removed. */
export async function assetRemoveString(alias: string): Promise<void> {
  try {
    await asset.remove(aliasMap(alias));
  } catch (err) {
    if ((err as BusinessError).code !== NOT_FOUND) {
      throw err as Error;
    }
  }
}
