import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { applyPiModelCompatibility } from "../runtime/pi/models/pi-model-compat.js";

/** A gateway supplies model IDs without provider IDs. Require every exact match to agree. */
export function reasoningModelIds(entries: Iterable<{ id: string; reasoning: boolean }>) {
  const byId = new Map<string, boolean>();
  for (const { id, reasoning } of entries) {
    byId.set(id, reasoning && byId.get(id) !== false);
  }
  return new Set([...byId].filter(([, supported]) => supported).map(([id]) => id));
}

let catalog: Set<string> | undefined;

export function modelAccountReasoningIds(enabledIds: readonly string[]) {
  catalog ??= reasoningModelIds(
    applyPiModelCompatibility(builtinModels())
      .getProviders()
      .flatMap((provider) => provider.getModels()),
  );
  return enabledIds.filter(catalog.has, catalog);
}
