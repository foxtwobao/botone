// SessionStore (design §5.3), the mobile session.ts defense in simplified form: the token lives
// in asset storage; every save/clear bumps a generation so a late response can tell it no longer
// owns the session; a failed wipe keeps the bearer invalid in memory, and the pending sign-out
// record (written before the clear) covers a restart that still finds the old token.
import { assetGetString, assetPutString, assetRemoveString } from './asset-store';

const SESSION_KEY = 'rakazo.session_token';

export interface TokenSnapshot {
  ok: boolean;
  value: string;
}

let generation = 0;
let invalidated = false;
let writes: Promise<void> = Promise.resolve();
const listeners: Set<() => void> = new Set();
const spaceListeners: Set<() => void> = new Set();

// Phase 1 is single-Space: every read/write uses me.spaceId (design Q5). The cache lives with
// the session because a sign-out or server switch must drop it, and it is never persisted —
// the first me read after launch re-establishes it.
let cachedSpaceId = '';

export function selectedSpaceId(): string {
  return cachedSpaceId;
}

export function setSelectedSpace(id: string): void {
  if (cachedSpaceId === id) {
    return;
  }
  cachedSpaceId = id;
  for (const listener of spaceListeners) {
    listener();
  }
}

/** The roster stream reopens when the selected Space changes, as it does on a session change. */
export function subscribeSpaceSelection(listener: () => void): () => void {
  spaceListeners.add(listener);
  return (): void => {
    spaceListeners.delete(listener);
  };
}

export function currentSessionGeneration(): number {
  return generation;
}

export function subscribeSession(listener: () => void): () => void {
  listeners.add(listener);
  return (): void => {
    listeners.delete(listener);
  };
}

function publish(): void {
  for (const listener of listeners) {
    listener();
  }
}

function enqueue(task: () => Promise<void>): Promise<void> {
  const next = writes.then(task, task);
  writes = next.then((): void => undefined, (): void => undefined);
  return next;
}

/** The active token; "" when there is none or the store cannot be read (mobile parity). */
export async function loadSessionToken(): Promise<string> {
  const snapshot = await snapshotSessionToken();
  return snapshot.ok ? snapshot.value : '';
}

/** Snapshots the token without treating an unreadable store as an empty session. */
export async function snapshotSessionToken(): Promise<TokenSnapshot> {
  if (invalidated) {
    const empty: TokenSnapshot = { ok: true, value: '' };
    return empty;
  }
  try {
    const value = await assetGetString(SESSION_KEY);
    const snapshot: TokenSnapshot = { ok: true, value: value ?? '' };
    return snapshot;
  } catch (err) {
    const unreadable: TokenSnapshot = { ok: false, value: '' };
    return unreadable;
  }
}

/** Saves the token and bumps the generation. A failed write leaves no session in memory. */
export async function saveSessionToken(token: string): Promise<void> {
  generation += 1;
  invalidated = true;
  cachedSpaceId = '';
  const saved = enqueue(async (): Promise<void> => {
    await assetPutString(SESSION_KEY, token);
  });
  try {
    await saved;
  } catch (err) {
    publish();
    throw err as Error;
  }
  invalidated = false;
  publish();
}

/**
 * Clears the session and bumps the generation. Returns false only when the store could not be
 * wiped; the in-memory gate still refuses the old bearer, and the revocation record covers it.
 */
export async function clearSessionToken(): Promise<boolean> {
  generation += 1;
  invalidated = true;
  cachedSpaceId = '';
  let cleared = false;
  await enqueue(async (): Promise<void> => {
    try {
      await assetRemoveString(SESSION_KEY);
      cleared = true;
    } catch (err) {
      // A failed wipe keeps the bearer invalid in memory; a restart's record revokes it.
    }
  });
  publish();
  return cleared;
}
