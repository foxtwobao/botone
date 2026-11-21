// Simplified pending sign-out (design §5.3), keeping mobile's safety semantics: the revocation
// record is written BEFORE the local session clears, so a process that dies mid-sign-out still
// revokes later; delivery retries in connectivity windows until the server answers; success or
// 401 completes a record; 30 days retire undeliverable ones. A server switch's record stays
// provisional until the switch commits, so a rolled-back switch never revokes its own session.
// Single session, so mobile's multi-account queue and reconcile races shrink to one pass.
import { assetGetString, assetPutString } from './asset-store';
import { postJson, RPC_TIMEOUT_MS } from './http';
import { parseServerHeaders } from './server-headers';

const PENDING_SIGN_OUT_KEY = 'rakazo.pending_sign_out';
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const FLUSH_SPACING_MS = 60_000;
const LIMIT = 100;

export interface PendingSignOut {
  apiBase: string;
  token: string;
  headers: Record<string, string>;
  recordedAt: number;
  provisional: boolean;
}

/** The context a flush needs; passed in so this module never imports the server store. */
export interface SignOutContext {
  apiBase: string;
  activeToken: string;
}

let writes: Promise<void> = Promise.resolve();
let lastFlushAt = 0;
let flushing: Promise<void> | null = null;
const delivering: Map<string, Promise<void>> = new Map();

function enqueue<T>(task: () => Promise<T>): Promise<T> {
  const next = writes.then(task, task);
  writes = next.then((): void => undefined, (): void => undefined);
  return next;
}

function sameRecord(left: PendingSignOut, right: PendingSignOut): boolean {
  return left.apiBase === right.apiBase && left.token === right.token;
}

function liveRecords(records: PendingSignOut[], now: number): PendingSignOut[] {
  return records.filter((record): boolean => now - record.recordedAt < MAX_AGE_MS);
}

function decodeRecords(stored: string | null): PendingSignOut[] | null {
  if (stored === null) {
    return [];
  }
  let value: Object;
  try {
    value = JSON.parse(stored);
  } catch (err) {
    // A list this app cannot read counts as empty; the next write replaces it.
    return [];
  }
  if (!Array.isArray(value)) {
    return [];
  }
  const records: PendingSignOut[] = [];
  for (const item of value as Object[]) {
    if (item === null || typeof item !== 'object') {
      continue;
    }
    const record = item as Record<string, Object>;
    const apiBase = record['apiBase'];
    const token = record['token'];
    const recordedAt = record['recordedAt'];
    if (typeof apiBase !== 'string' || !(apiBase as string)) {
      continue;
    }
    if (typeof token !== 'string' || !(token as string)) {
      continue;
    }
    if (typeof recordedAt !== 'number' || !Number.isFinite(recordedAt as number)) {
      continue;
    }
    const entry: PendingSignOut = {
      apiBase: apiBase as string,
      token: token as string,
      headers: parseServerHeaders(record['headers'] ?? null) ?? {},
      recordedAt: recordedAt as number,
      provisional: record['provisional'] === true,
    };
    records.push(entry);
  }
  return records;
}

async function readRecords(): Promise<PendingSignOut[] | null> {
  let stored: string | null = null;
  try {
    stored = await assetGetString(PENDING_SIGN_OUT_KEY);
  } catch (err) {
    // Unreadable: the retry stays for a later window; nothing is written over it.
    return null;
  }
  return decodeRecords(stored);
}

async function writeRecords(records: PendingSignOut[]): Promise<boolean> {
  try {
    await assetPutString(PENDING_SIGN_OUT_KEY, JSON.stringify(records));
    return true;
  } catch (err) {
    return false;
  }
}

/** Records a revocation to deliver later. False when the store could not be read or written. */
export function savePendingSignOut(record: PendingSignOut): Promise<boolean> {
  return enqueue(async (): Promise<boolean> => {
    const current = await readRecords();
    if (current === null) {
      return false;
    }
    const kept = liveRecords(current, Date.now()).filter((existing): boolean => !sameRecord(existing, record));
    const next: PendingSignOut[] = [record];
    for (const entry of kept) {
      next.push(entry);
    }
    if (!(await writeRecords(next.slice(0, LIMIT)))) {
      return false;
    }
    // A fresh record gets its first retry at once.
    lastFlushAt = 0;
    return true;
  });
}

export function removePendingSignOut(record: PendingSignOut): Promise<void> {
  return enqueue(async (): Promise<void> => {
    const current = await readRecords();
    if (current === null) {
      return;
    }
    const kept = current.filter((existing): boolean =>
      !sameRecord(existing, record) || existing.recordedAt !== record.recordedAt
      || existing.provisional !== record.provisional);
    if (kept.length !== current.length) {
      await writeRecords(kept);
    }
  });
}

/** Marks a switch's record deliverable once the switch has committed. */
export function promotePendingSignOut(record: PendingSignOut): Promise<void> {
  return enqueue(async (): Promise<void> => {
    const current = await readRecords();
    if (current === null) {
      return;
    }
    let promoted = false;
    const kept: PendingSignOut[] = [];
    for (const existing of current) {
      if (existing.provisional && sameRecord(existing, record)) {
        const committed: PendingSignOut = {
          apiBase: existing.apiBase,
          token: existing.token,
          headers: existing.headers,
          recordedAt: existing.recordedAt,
          provisional: false,
        };
        kept.push(committed);
        promoted = true;
      } else {
        kept.push(existing);
      }
    }
    if (promoted) {
      await writeRecords(kept);
    }
  });
}

/**
 * Sends a revocation to its own server with the record's own headers (after a switch the
 * configured headers belong to the new server). Success or 401 completes it; everything else
 * retries. Redirects are refused by the transport, so only the endpoint itself confirms.
 */
async function deliver(record: PendingSignOut): Promise<boolean> {
  const headers: Record<string, string> = {};
  for (const key of Object.keys(record.headers)) {
    headers[key] = record.headers[key];
  }
  headers['content-type'] = 'application/json';
  headers['origin'] = 'rakazo://';
  headers['authorization'] = `Bearer ${record.token}`;
  try {
    const response = await postJson(`${record.apiBase}/api/auth/sign-out`, headers, '{}',
      RPC_TIMEOUT_MS, 64 * 1024);
    return (response.status >= 200 && response.status < 300) || response.status === 401;
  } catch (err) {
    return false;
  }
}

/** One attempt per session at a time; a persisted record is delivered only while still stored. */
export function deliverSignOutRecord(record: PendingSignOut, persisted: boolean): Promise<void> {
  const key = `${record.apiBase}\n${record.token}`;
  const inFlight = delivering.get(key);
  if (inFlight !== undefined) {
    return inFlight;
  }
  const delivery = (async (): Promise<void> => {
    try {
      const current = persisted ? await readRecords() : null;
      // An unreadable store falls back to the captured record, as does one that could not persist.
      const target = current !== null
        ? liveRecords(current, Date.now()).find((candidate): boolean =>
          sameRecord(candidate, record) && !candidate.provisional)
        : record;
      if (target !== undefined && (await deliver(target))) {
        await removePendingSignOut(target);
      }
    } catch (err) {
      // Delivery problems never surface; the record waits for the next pass.
    } finally {
      delivering.delete(key);
    }
  })();
  delivering.set(key, delivery);
  return delivery;
}

/**
 * Resolves provisional records a dying switch left behind: one whose token is the active
 * session on the current server belongs to a switch that never completed and stays; every
 * other is promoted for delivery. Then delivers the live non-provisional records.
 */
async function pass(context: SignOutContext): Promise<void> {
  lastFlushAt = Date.now();
  const current = await enqueue(async (): Promise<PendingSignOut[] | null> => {
    const records = await readRecords();
    if (records === null) {
      return null;
    }
    const now = Date.now();
    const live = liveRecords(records, now);
    const resolved: PendingSignOut[] = [];
    let changed = live.length !== records.length;
    for (const record of live) {
      if (record.provisional) {
        const stillActive = record.apiBase === context.apiBase && record.token === context.activeToken;
        if (stillActive) {
          resolved.push(record);
          continue;
        }
        const committed: PendingSignOut = {
          apiBase: record.apiBase,
          token: record.token,
          headers: record.headers,
          recordedAt: record.recordedAt,
          provisional: false,
        };
        resolved.push(committed);
        changed = true;
      } else {
        resolved.push(record);
      }
    }
    if (changed) {
      await writeRecords(resolved);
    }
    return resolved;
  });
  if (current === null) {
    return;
  }
  for (const record of current) {
    if (!record.provisional) {
      await deliverSignOutRecord(record, true);
    }
  }
}

/**
 * Retries undelivered revocations in connectivity windows (every answered request), spaced so
 * a dead old server is not hit per request. force reads at launch regardless of spacing.
 */
export function flushPendingSignOut(context: SignOutContext, force: boolean = false): Promise<void> {
  if (!force && Date.now() - lastFlushAt < FLUSH_SPACING_MS) {
    return Promise.resolve();
  }
  if (flushing === null) {
    flushing = pass(context).then((): void => {
      flushing = null;
    }, (): void => {
      flushing = null;
    });
  }
  return flushing;
}
