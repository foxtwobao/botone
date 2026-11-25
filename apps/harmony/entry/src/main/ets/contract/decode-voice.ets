// M7 voice contract decoders (design §4): the fields of each voice view the app consumes, read
// one by one with runtime type guards. A decoder answers null when a consumed field is missing or
// mistyped; the rest of the row is ignored (forward compatible). The layer-1 snapshots pin these
// views to the real contract schemas (voice-*.json).
import { asRecord, readBoolean, readString } from './decode';

/** A voice connection the server offers (voice/catalog). */
export interface VoiceCatalogView {
  id: string;
  name: string;
  /** The connection can transcribe recordings. */
  transcribe: boolean;
  /** No key is needed to connect. */
  keyless?: boolean;
  /** The connection takes an optional speech model id. */
  speechModel?: boolean;
  /** The account's model connection can authenticate it, so its key is optional. */
  modelConnection?: boolean;
  /** A voice id can be typed: a model's voices may be missing from its listing. */
  freeformVoice?: boolean;
}

/** A saved connection (voice/credentials, connect, setSpeechModel). Never carries the key. */
export interface VoiceCredentialView {
  id: string;
  provider: string;
  hasKey: boolean;
  voiceId: string;
  speechModel: string;
  transcribe: boolean;
  /** A self-hosted server's address and model ids; empty for hosted connections. */
  endpoint: string;
  ttsModel: string;
  sttModel: string;
}

/** Which voice reads replies aloud, and whether it transcribes (voice/status, setVoice). */
export interface VoiceStatusView {
  configured: boolean;
  ready: boolean;
  transcribe: boolean;
  provider: string | null;
  voiceId: string;
}

/** One voice a connection offers (voice/voices). */
export interface VoiceInfoView {
  id: string;
  label: string;
}

/** voice/prepare: whether a voice is set up, and the utterances to render. */
export interface VoicePrepareView {
  ready: boolean;
  utterances: string[];
}

function readFlag(record: Record<string, Object>, key: string): boolean | undefined {
  const value = record[key];
  return typeof value === 'boolean' ? value as boolean : undefined;
}

function decodeList(json: Object | null, row: (item: Record<string, Object>) => Object | null): Object[] | null {
  if (!Array.isArray(json)) {
    return null;
  }
  const out: Object[] = [];
  for (const item of json as Object[]) {
    const record = asRecord(item);
    const decoded = record === null ? null : row(record);
    if (decoded === null) {
      return null;
    }
    out.push(decoded);
  }
  return out;
}

function decodeCredentialRow(record: Record<string, Object>): VoiceCredentialView | null {
  const id = readString(record, 'id');
  const provider = readString(record, 'provider');
  const hasKey = readBoolean(record, 'hasKey');
  const voiceId = readString(record, 'voiceId');
  const speechModel = readString(record, 'speechModel');
  const transcribe = readBoolean(record, 'transcribe');
  const endpoint = readString(record, 'endpoint');
  const ttsModel = readString(record, 'ttsModel');
  const sttModel = readString(record, 'sttModel');
  if (id === null || !id || provider === null || !provider || hasKey === null || voiceId === null
    || speechModel === null || transcribe === null || endpoint === null || ttsModel === null
    || sttModel === null) {
    return null;
  }
  const view: VoiceCredentialView = {
    id: id, provider: provider, hasKey: hasKey, voiceId: voiceId, speechModel: speechModel,
    transcribe: transcribe, endpoint: endpoint, ttsModel: ttsModel, sttModel: sttModel,
  };
  return view;
}

export function decodeVoiceCatalog(json: Object | null): VoiceCatalogView[] | null {
  const rows = decodeList(json, (item: Record<string, Object>): VoiceCatalogView | null => {
    const id = readString(item, 'id');
    const name = readString(item, 'name');
    const transcribe = readBoolean(item, 'transcribe');
    if (id === null || !id || name === null || transcribe === null) {
      return null;
    }
    const view: VoiceCatalogView = { id: id, name: name, transcribe: transcribe };
    const keyless = readFlag(item, 'keyless');
    if (keyless !== undefined) {
      view.keyless = keyless;
    }
    const speechModel = readFlag(item, 'speechModel');
    if (speechModel !== undefined) {
      view.speechModel = speechModel;
    }
    const modelConnection = readFlag(item, 'modelConnection');
    if (modelConnection !== undefined) {
      view.modelConnection = modelConnection;
    }
    const freeformVoice = readFlag(item, 'freeformVoice');
    if (freeformVoice !== undefined) {
      view.freeformVoice = freeformVoice;
    }
    return view;
  });
  return rows === null ? null : rows as VoiceCatalogView[];
}

export function decodeVoiceCredentials(json: Object | null): VoiceCredentialView[] | null {
  const rows = decodeList(json, (item: Record<string, Object>): VoiceCredentialView | null =>
    decodeCredentialRow(item));
  return rows === null ? null : rows as VoiceCredentialView[];
}

export function decodeVoiceCredential(json: Object | null): VoiceCredentialView | null {
  const record = asRecord(json);
  return record === null ? null : decodeCredentialRow(record);
}

export function decodeVoiceStatus(json: Object | null): VoiceStatusView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const configured = readBoolean(record, 'configured');
  const ready = readBoolean(record, 'ready');
  const transcribe = readBoolean(record, 'transcribe');
  const voiceId = readString(record, 'voiceId');
  const rawProvider = record['provider'];
  const provider = rawProvider === null ? null : typeof rawProvider === 'string' ? rawProvider as string : undefined;
  if (configured === null || ready === null || transcribe === null || voiceId === null || provider === undefined) {
    return null;
  }
  const view: VoiceStatusView = {
    configured: configured, ready: ready, transcribe: transcribe, provider: provider, voiceId: voiceId,
  };
  return view;
}

export function decodeVoiceVoices(json: Object | null): VoiceInfoView[] | null {
  const rows = decodeList(json, (item: Record<string, Object>): VoiceInfoView | null => {
    const id = readString(item, 'id');
    const label = readString(item, 'label');
    if (id === null || !id || label === null) {
      return null;
    }
    const view: VoiceInfoView = { id: id, label: label };
    return view;
  });
  return rows === null ? null : rows as VoiceInfoView[];
}

export function decodeVoicePrepare(json: Object | null): VoicePrepareView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const ready = readBoolean(record, 'ready');
  const raw = record['utterances'];
  if (ready === null || !Array.isArray(raw)) {
    return null;
  }
  const utterances: string[] = [];
  for (const item of raw as Object[]) {
    if (typeof item !== 'string') {
      return null;
    }
    utterances.push(item as string);
  }
  const view: VoicePrepareView = { ready: ready, utterances: utterances };
  return view;
}

/** The transcript of /api/voice/transcribe: {text}; a reply without text reads as no words. */
export function decodeTranscription(json: Object | null): string {
  const record = asRecord(json);
  const text = record === null ? null : readString(record, 'text');
  return text ?? '';
}
