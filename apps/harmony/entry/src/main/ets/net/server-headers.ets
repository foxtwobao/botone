// Custom per-server headers (an access proxy's credentials, say), ported from
// packages/contracts/src/clients/server-headers.ts + models/model-headers.ts validation and
// apps/mobile/lib/api/server-headers.ts storage. Validated before storage and again on read;
// a damaged value sends nothing rather than something unexpected. They may hold credentials,
// so they live in asset storage, never preferences.
import { assetGetString, assetPutString, assetRemoveString } from './asset-store';
import { parseJsonObject } from './http';

const SERVER_HEADERS_KEY = 'rakazo.server_headers';

const RESERVED_HEADERS: string[] = [
  'authorization', 'proxy-authorization', 'cookie', 'host', 'content-length', 'content-type',
  'transfer-encoding', 'connection', 'keep-alive', 'upgrade', 'te', 'trailer', 'expect',
];
const SERVER_RESERVED_HEADERS: string[] = [
  'origin', 'referer', 'cookie2', 'set-cookie', 'via', 'forwarded',
  'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto',
];

function allowedHeaderName(name: string): boolean {
  const lower = name.trim().toLowerCase();
  return !RESERVED_HEADERS.includes(lower) && !lower.startsWith('proxy-') && !lower.startsWith('sec-')
    && !SERVER_RESERVED_HEADERS.includes(lower) && !lower.startsWith('x-rakazo-');
}

/** Null for anything unusable, so a damaged saved value never reaches a request. */
export function parseServerHeaders(input: Object | null): Record<string, string> | null {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    return null;
  }
  const record = input as Record<string, Object>;
  const names = Object.keys(record);
  if (names.length > 8) {
    return null;
  }
  const seen: Set<string> = new Set();
  const headers: Record<string, string> = {};
  for (const name of names) {
    const value = record[name];
    if (typeof value !== 'string') {
      return null;
    }
    const text = value as string;
    if (name.length < 1 || name.length > 256 || !/^[\t ]*[!#$%&'*+.^_`|~0-9A-Za-z-]+[\t ]*$/.test(name)) {
      return null;
    }
    if (!allowedHeaderName(name)) {
      return null;
    }
    if (text.length < 1 || text.length > 1024 || !/^[\x20-\x7e]*$/.test(text)) {
      return null;
    }
    const trimmed = name.trim();
    const lower = trimmed.toLowerCase();
    if (seen.has(lower)) {
      return null;
    }
    seen.add(lower);
    headers[trimmed] = text;
  }
  return headers;
}

interface StoredHeaders {
  apiBase: string;
  headers: Record<string, string>;
}

let saved: StoredHeaders | null = null;

/** Headers configured for this server; none for any other origin. */
export function serverHeaders(apiBase: string): Record<string, string> {
  const empty: Record<string, string> = {};
  return saved !== null && saved.apiBase === apiBase ? saved.headers : empty;
}

export async function loadServerHeaders(apiBase: string): Promise<void> {
  saved = null;
  let stored: string | null = null;
  try {
    stored = await assetGetString(SERVER_HEADERS_KEY);
  } catch (err) {
    return;
  }
  if (stored === null) {
    return;
  }
  const value = parseJsonObject(stored);
  if (value === null || value['apiBase'] !== apiBase) {
    return;
  }
  const headers = parseServerHeaders(value['headers'] ?? null);
  if (headers !== null) {
    const entry: StoredHeaders = { apiBase: apiBase, headers: headers };
    saved = entry;
  }
}

/** Replaces the headers for apiBase; an empty set removes them. False when validation or write fails. */
export async function saveServerHeaders(apiBase: string, headers: Record<string, string>): Promise<boolean> {
  const parsed = parseServerHeaders(headers);
  if (parsed === null) {
    return false;
  }
  try {
    if (Object.keys(parsed).length === 0) {
      await assetRemoveString(SERVER_HEADERS_KEY);
      saved = null;
    } else {
      const entry: StoredHeaders = { apiBase: apiBase, headers: parsed };
      await assetPutString(SERVER_HEADERS_KEY, JSON.stringify(entry));
      saved = entry;
    }
    return true;
  } catch (err) {
    return false;
  }
}
