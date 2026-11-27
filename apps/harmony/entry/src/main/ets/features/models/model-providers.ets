// Model provider rules (M9), ported from core's model-providers.ts: provider canonicalization,
// the model a provider row preselects, the provider rows the connect screen offers, and the
// markers the Models screen shows (the account default, the first connection). Pure — no device,
// no network — so the vitest port test loads this file as TypeScript and replays it.
import type { MeView, ModelCatalogEntryView } from '../../contract/decode';
import type { ModelCredentialView } from '../../contract/decode-models';

/** contracts OPENAI_COMPATIBLE_PROVIDER_ID: the provider whose servers people address themselves. */
export const OPENAI_COMPATIBLE_PROVIDER_ID = 'openai-compatible';

/** contracts canonicalPiProviderId: the Pi catalog's Azure rename. */
export function canonicalPiProviderId(provider: string): string {
  return provider === 'azure-openai-responses' ? 'azure' : provider;
}

/** The provider's name for people: the maker's own name when the catalog carries one. */
export function providerDisplayName(entry: ModelCatalogEntryView): string {
  return entry.providerName !== null ? entry.providerName : entry.provider;
}

/**
 * The model to preselect when a provider row is opened (core pickCatalogModelId): the preferred
 * id when this provider carries it, its basename when an aggregator prefixes ids with a vendor,
 * else the provider's recommended model, else its first entry.
 */
export function pickCatalogModelId(catalog: ModelCatalogEntryView[], provider: string,
  preferredId: string | null): string {
  const canonical = canonicalPiProviderId(provider);
  const entries: ModelCatalogEntryView[] = [];
  for (const entry of catalog) {
    if (canonicalPiProviderId(entry.provider) === canonical) {
      entries.push(entry);
    }
  }
  if (preferredId !== null && preferredId) {
    for (const entry of entries) {
      if (entry.id === preferredId) {
        return preferredId;
      }
    }
    // Aggregators prefix ids with the upstream vendor ("openai/gpt-6" on one, "gpt-6" on another).
    const slash = preferredId.lastIndexOf('/');
    const basename = slash >= 0 ? preferredId.slice(slash + 1) : preferredId;
    if (basename && basename !== preferredId) {
      for (const entry of entries) {
        if (entry.id === basename) {
          return entry.id;
        }
      }
    }
  }
  for (const entry of entries) {
    if (entry.recommended) {
      return entry.id;
    }
  }
  return entries.length > 0 ? entries[0].id : '';
}

export interface ModelDefaults {
  defaultProvider: string | null;
  defaultModel: string | null;
}

export interface ModelCredentialRef {
  modelId: string | null;
}

export interface FormModelInput {
  catalog: ModelCatalogEntryView[];
  provider: string;
  credential: ModelCredentialRef | null;
  defaults: ModelDefaults | null;
  current: string;
}

/**
 * The model a connection form opens on (core connectionFormModelId). An OpenAI-compatible
 * connection keeps its own model, so a new one starts empty. A catalog provider keeps the model
 * on screen while the catalog still lists it, else the connection's, else the account default's
 * when it belongs to this provider.
 */
export function connectionFormModelId(input: FormModelInput): string {
  const catalog = input.catalog;
  const provider = input.provider;
  const credential = input.credential;
  const defaults = input.defaults;
  const current = input.current;
  if (provider === OPENAI_COMPATIBLE_PROVIDER_ID) {
    return credential !== null && credential.modelId !== null ? credential.modelId : '';
  }
  for (const entry of catalog) {
    if (entry.provider === provider && entry.id === current) {
      return entry.id;
    }
  }
  const preferred = credential !== null && credential.modelId !== null ? credential.modelId
    : defaults !== null && provider === defaults.defaultProvider ? defaults.defaultModel : null;
  return pickCatalogModelId(catalog, provider, preferred);
}

/** One provider row the connect screen offers. */
export interface ProviderChoice {
  id: string;
  name: string;
}

/** The providers a key connection can be made to: an OAuth-only provider has no key path. */
export function connectableProviders(catalog: ModelCatalogEntryView[]): ProviderChoice[] {
  const choices: ProviderChoice[] = [];
  for (const entry of catalog) {
    if (entry.auth === 'oauth') {
      continue;
    }
    let known = false;
    for (const choice of choices) {
      if (choice.id === entry.provider) {
        known = true;
        break;
      }
    }
    if (!known) {
      const choice: ProviderChoice = { id: entry.provider, name: providerDisplayName(entry) };
      choices.push(choice);
    }
  }
  return choices;
}

/** The catalog label for a connection's model; '' when the catalog does not list it. */
export function modelLabelFor(catalog: ModelCatalogEntryView[], provider: string, modelId: string): string {
  for (const entry of catalog) {
    if (entry.provider === provider && entry.id === modelId) {
      return entry.label;
    }
  }
  return '';
}

/** Whether this connection runs the account's main model (ModelCredential.isDefault is not read). */
export function isDefaultConnection(defaults: ModelDefaults | null,
  credential: ModelCredentialView): boolean {
  return defaults !== null && defaults.defaultProvider !== null && defaults.defaultModel !== null
    && canonicalPiProviderId(defaults.defaultProvider) === canonicalPiProviderId(credential.provider)
    && defaults.defaultModel === credential.modelId;
}

/** Core isFirstModelConnection for the account scope: lead with connecting a model. */
export function firstModelConnection(me: MeView | null, credentials: ModelCredentialView[]): boolean {
  return me !== null && me.needsModel && credentials.length === 0;
}