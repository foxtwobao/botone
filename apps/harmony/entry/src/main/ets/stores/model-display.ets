// The read-only model display (design §4.3.4/Q6): match me.defaultProvider/defaultModel against
// the models/list catalog and show the SERVER's label. No match (or no default model) shows the
// translatable generic "Space default" msgid — never a raw id, never a fabricated label. This is
// the same catalogEntry match mobile's chat-model.ts uses (provider + id, provider required).
import type { MeView, ModelCatalogEntryView } from '../contract/decode';

/** The catalog entry the account's default model names, or null when there is no match. */
export function defaultModelEntry(me: MeView | null,
  catalog: ModelCatalogEntryView[]): ModelCatalogEntryView | null {
  if (me === null || me.defaultProvider === null || me.defaultModel === null) {
    return null;
  }
  const provider = me.defaultProvider;
  const modelId = me.defaultModel;
  for (const entry of catalog) {
    if (entry.provider === provider && entry.id === modelId) {
      return entry;
    }
  }
  return null;
}
