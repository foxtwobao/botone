// Servers the device has used before (≤5, most recent first), ported from
// apps/mobile/lib/api/saved-servers.ts. Entries carry the custom headers they were configured
// with, so they live in asset storage. A damaged entry is dropped, never switched to without
// the headers it needs; the default server is never listed.
import { assetGetString, assetPutString, assetRemoveString } from './asset-store';
import { defaultApiBase, normalizeApiBase } from './endpoint';
import { parseJsonObject } from './http';
import { parseServerHeaders } from './server-headers';

const SAVED_SERVERS_KEY = 'rakazo.saved_servers';
export const MAX_SAVED_SERVERS = 5;

export interface SavedServer {
  apiBase: string;
  headers: Record<string, string>;
}

let saved: SavedServer[] = [];
/** False until the stored list has been read, and while it could not be: unread ≠ empty. */
let readable = false;
let writes: Promise<void> = Promise.resolve();

export function savedServers(): SavedServer[] {
  return saved;
}

function parseSavedServers(stored: string | null): SavedServer[] {
  if (stored === null) {
    return [];
  }
  let value: Object;
  try {
    value = JSON.parse(stored);
  } catch (err) {
    return [];
  }
  if (!Array.isArray(value)) {
    return [];
  }
  const entries: SavedServer[] = [];
  for (const item of value as Object[]) {
    if (item === null || typeof item !== 'object') {
      continue;
    }
    const record = item as Record<string, Object>;
    const apiBase = record['apiBase'];
    if (typeof apiBase !== 'string') {
      continue;
    }
    const base = apiBase as string;
    const normalized = normalizeApiBase(base);
    const headers = parseServerHeaders(record['headers'] ?? null);
    if (!normalized.ok || normalized.url !== base || headers === null) {
      continue;
    }
    if (base === defaultApiBase() || entries.some((entry): boolean => entry.apiBase === base)) {
      continue;
    }
    const entry: SavedServer = { apiBase: base, headers: headers };
    entries.push(entry);
  }
  return entries.slice(0, MAX_SAVED_SERVERS);
}

async function readSavedServers(): Promise<void> {
  let stored: string | null = null;
  try {
    stored = await assetGetString(SAVED_SERVERS_KEY);
    readable = true;
  } catch (err) {
    readable = false;
  }
  saved = parseSavedServers(stored);
}

async function persist(next: SavedServer[]): Promise<boolean> {
  try {
    if (next.length === 0) {
      await assetRemoveString(SAVED_SERVERS_KEY);
    } else {
      await assetPutString(SAVED_SERVERS_KEY, JSON.stringify(next));
    }
    return true;
  } catch (err) {
    return false;
  }
}

function enqueue<T>(task: () => Promise<T>): Promise<T> {
  const next = writes.then(task, task);
  writes = next.then((): void => undefined, (): void => undefined);
  return next;
}

export function loadSavedServers(): Promise<void> {
  return enqueue(readSavedServers);
}

function change(update: (current: SavedServer[]) => SavedServer[]): Promise<boolean> {
  return enqueue(async (): Promise<boolean> => {
    if (!readable) {
      await readSavedServers();
    }
    if (!readable) {
      return false;
    }
    const next = update(saved);
    if (!(await persist(next))) {
      return false;
    }
    saved = next;
    return true;
  });
}

/**
 * Remembers a server at the top of the list. keepHeaders is for a server being left: a server
 * already listed keeps the headers it was saved with.
 */
export function recordSavedServer(apiBase: string, headers: Record<string, string>,
  keepHeaders: boolean = false): Promise<boolean> {
  if (apiBase === defaultApiBase()) {
    return Promise.resolve(false);
  }
  return change((current: SavedServer[]): SavedServer[] => {
    const existing = keepHeaders ? current.find((entry): boolean => entry.apiBase === apiBase) : undefined;
    const fresh: SavedServer = { apiBase: apiBase, headers: headers };
    const head: SavedServer = existing ?? fresh;
    const rest = current.filter((entry): boolean => entry.apiBase !== apiBase);
    const next: SavedServer[] = [head];
    for (const entry of rest) {
      next.push(entry);
    }
    return next.slice(0, MAX_SAVED_SERVERS);
  });
}

/** Forgets one server and the headers kept for it. */
export function removeSavedServer(apiBase: string): Promise<boolean> {
  return change((current: SavedServer[]): SavedServer[] =>
    current.filter((entry): boolean => entry.apiBase !== apiBase));
}
