// The connection form's decisions (M9), ported from core's model-connection-form.ts, plus the
// two small rules the compatible form needs (contracts' openAiCompatibleConnectReady) and the key
// mask a failed connect shows. This client connects a provider by key only: no routing ids,
// protocol picker, custom headers or effort picker, so those inputs stay absent (the server treats
// absent as its default). Pure — no device, no network — so the vitest port test loads this file
// as TypeScript and replays it against core.
import type { ModelCatalogEntryView } from '../../contract/decode';
import type { ModelCredentialRef } from './model-providers';
import { OPENAI_COMPATIBLE_PROVIDER_ID } from './model-providers';

/** Mobile MODEL_CONNECT_TIMEOUT_MS: connecting checks the key with the provider, which is slow. */
export const MODEL_CONNECT_TIMEOUT_MS = 60_000;

/** What the connection form holds. thinkingLevel and enabled-model ticks are not offered here. */
export interface ConnectionFormDraft {
  enabledModelIds: string[];
  baseUrl: string;
  modelId: string;
  apiKey: string;
}

/** The `models/connect` input this form sends; absent optional fields are not sent at all. */
export interface ModelConnectInput {
  provider: string;
  apiKey?: string;
  baseUrl?: string;
  modelId?: string;
  label: string;
  /** null adds another connection for the provider; omitted would update its newest one. */
  credentialId: string | null;
  makeDefault: boolean;
  scope: string;
  enabledModelIds?: string[];
}

export interface ModelConnectRequest {
  /** incomplete | ready */
  status: string;
  input?: ModelConnectInput;
  /** A catalog provider's save without a new key: gateway ids only. */
  savingWithoutKey?: boolean;
  /** The model the saved connection runs. */
  activeModelId?: string;
}

export interface ConnectRequestInputs {
  form: ConnectionFormDraft;
  selected: ModelCatalogEntryView;
  credential: ModelCredentialRef | null;
  credentialId: string | null;
  /** False keeps the current main model; the account scope is where it lands. */
  makeDefault: boolean;
  scope: string;
}

/**
 * The `models/connect` input for the form (core modelConnectRequest). A compatible connection
 * needs a URL and a model; a catalog provider needs a key of at least 8 characters, or an
 * existing connection to save onto.
 */
export function modelConnectRequest(inputs: ConnectRequestInputs): ModelConnectRequest {
  const form = inputs.form;
  const selected = inputs.selected;
  const credential = inputs.credential;
  const credentialId = inputs.credentialId;
  const makeDefault = inputs.makeDefault;
  const scope = inputs.scope;
  const compatible = selected.provider === OPENAI_COMPATIBLE_PROVIDER_ID;
  const baseUrl = form.baseUrl.trim();
  const modelId = form.modelId.trim();
  const newKey = form.apiKey.trim();
  const savingWithoutKey = !compatible && !newKey;
  const activeModelId = compatible ? modelId : selected.id;
  if (compatible) {
    if (!baseUrl || !modelId) {
      return incompleteRequest();
    }
  } else if (savingWithoutKey) {
    if (credential === null) {
      return incompleteRequest();
    }
  } else if (newKey.length < 8) {
    return incompleteRequest();
  }
  const label = selected.providerName !== null ? selected.providerName : selected.provider;
  const ready: ModelConnectRequest = {
    status: 'ready',
    savingWithoutKey: savingWithoutKey,
    activeModelId: activeModelId,
  };
  const connectInput: ModelConnectInput = {
    provider: selected.provider,
    label: label,
    credentialId: credentialId,
    makeDefault: makeDefault,
    scope: scope,
  };
  if (newKey) {
    connectInput.apiKey = newKey;
  }
  if (compatible) {
    const enabled: string[] = [];
    for (const id of form.enabledModelIds) {
      if (id !== modelId) {
        enabled.push(id);
      }
    }
    connectInput.baseUrl = baseUrl;
    connectInput.modelId = modelId;
    connectInput.enabledModelIds = enabled;
  } else {
    connectInput.modelId = selected.id;
  }
  ready.input = connectInput;
  return ready;
}

function incompleteRequest(): ModelConnectRequest {
  const result: ModelConnectRequest = { status: 'incomplete' };
  return result;
}

/** contracts openAiCompatibleConnectReady: URL and model id, plus a key when the endpoint needs one. */
export function openAiCompatibleConnectReady(baseUrl: string, modelId: string, apiKey: string,
  keyRequired: boolean): boolean {
  return Boolean(baseUrl.trim() && modelId.trim() && (!keyRequired || apiKey.trim()));
}

/**
 * A failed connect's text with the key it carried hidden: the server's refusal can echo the key,
 * and the screen never shows it back. Both encodings a message commonly carries are masked: the
 * key as typed and its JSON-escaped form (an error body stringified into the text, where a `"` or
 * `\` in the key reads as `\"`). A key under 4 characters is not masked: it is too short to be
 * one, and a substring that short would damage ordinary words (the server masks its own copy).
 * Shortcut: case folding assumes an ASCII key; a non-ASCII fold could shift positions.
 */
export function hideKnownKey(text: string, apiKey: string): string {
  const key = apiKey.trim();
  if (key.length < 4) {
    return text;
  }
  let result = hideForm(text, key);
  const escaped = JSON.stringify(key).slice(1, -1);
  if (escaped !== key) {
    result = hideForm(result, escaped);
  }
  return result;
}

/** One form of the key, every occurrence replaced, case folded. */
function hideForm(text: string, form: string): string {
  const foldedForm = form.toLowerCase();
  const foldedText = text.toLowerCase();
  let result = '';
  let index = 0;
  for (;;) {
    const at = foldedText.indexOf(foldedForm, index);
    if (at < 0) {
      result += text.slice(index);
      return result;
    }
    result += `${text.slice(index, at)}•••`;
    index = at + foldedForm.length;
  }
}