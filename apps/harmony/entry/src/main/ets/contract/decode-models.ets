// M9 model-connection decoders (design §4): a saved connection (models/credentials, connect)
// and the models a compatible server lists (probeOpenAiCompatible). One field at a time with
// runtime guards; a decoder answers null when a consumed field is missing or mistyped, the rest
// of the row is ignored (forward compatible). The layer-1 snapshots pin these views to the real
// contract schemas (model-credentials, model-credential, model-probe-output).
import { asRecord, decodeRows, readBoolean, readString } from './decode';

/** A saved connection; never carries the key. */
export interface ModelCredentialView {
  id: string;
  provider: string;
  label: string;
  hasKey: boolean;
  /** The model the connection runs; absent for a compatible connection that names none yet. */
  modelId: string | null;
  /** A compatible server's address. */
  baseUrl: string | null;
}

/** An optional text: absent or null reads as none (null); a value of another type fails the row. */
function readOptionalText(record: Record<string, Object>, key: string): string | null | undefined {
  const value = record[key];
  if (value === undefined || value === null) {
    return null;
  }
  return typeof value === 'string' ? value as string : undefined;
}

export function decodeModelCredential(json: Object | null): ModelCredentialView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const id = readString(record, 'id');
  const provider = readString(record, 'provider');
  const label = readString(record, 'label');
  const hasKey = readBoolean(record, 'hasKey');
  const modelId = readOptionalText(record, 'modelId');
  const baseUrl = readOptionalText(record, 'baseUrl');
  if (id === null || !id || provider === null || !provider || label === null || hasKey === null
    || modelId === undefined || baseUrl === undefined) {
    return null;
  }
  const result: ModelCredentialView = {
    id: id, provider: provider, label: label, hasKey: hasKey, modelId: modelId, baseUrl: baseUrl,
  };
  return result;
}

/** A connection list: a non-array fails; a row that cannot decode is dropped, not fatal. */
export function decodeModelCredentials(json: Object | null): ModelCredentialView[] | null {
  return decodeRows(json, decodeModelCredential);
}

/** probeOpenAiCompatible output: the model ids the server lists. A non-array fails; a non-string
 *  entry is dropped like a bad row, and a repeated id keeps its first place (a list key, not a
 *  count). */
export function decodeProbeModels(json: Object | null): string[] | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const raw = record['models'];
  if (!Array.isArray(raw)) {
    return null;
  }
  const models: string[] = [];
  for (const item of raw as Object[]) {
    if (typeof item === 'string' && models.indexOf(item as string) < 0) {
      models.push(item as string);
    }
  }
  return models;
}