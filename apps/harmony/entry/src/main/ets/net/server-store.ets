// ServerStore (design §5.3): the current address is a non-secret preference; switching is a
// serialized transaction — record the old session's revocation (provisional) → clear the
// session → probe the new address → commit, rolling back to the old address on any failure.
// A rolled-back switch's record is settled so it never revokes the session still in use.
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { defaultApiBase, normalizeApiBase, probeApiBase } from './endpoint';
import type { EndpointResult } from './endpoint';
import {
  clearSessionToken,
  currentSessionGeneration,
  saveSessionToken,
  setSelectedSpace,
  snapshotSessionToken,
} from './session';
import { loadServerHeaders, saveServerHeaders, serverHeaders } from './server-headers';
import { loadSavedServers, recordSavedServer } from './saved-servers';
import { flushPendingSignOut, promotePendingSignOut, removePendingSignOut, savePendingSignOut } from './sign-out';
import type { PendingSignOut, SignOutContext } from './sign-out';

const PREFS_NAME = 'rakazo.server';
const API_BASE_KEY = 'rakazo.api_base';

let store: preferences.Preferences | null = null;
let cachedApiBase = '';
const settled: EndpointResult = { ok: true, url: '', error: '' };
let changeQueue: Promise<EndpointResult> = Promise.resolve(settled);

export async function initServerStore(context: common.Context): Promise<void> {
  store = await preferences.getPreferences(context, PREFS_NAME);
  const stored = await store.get(API_BASE_KEY, '');
  cachedApiBase = typeof stored === 'string' ? stored as string : '';
  await loadServerHeaders(currentApiBase());
  await loadSavedServers();
}

export function currentApiBase(): string {
  if (cachedApiBase) {
    const parsed = normalizeApiBase(cachedApiBase);
    if (parsed.ok) {
      return parsed.url;
    }
  }
  return defaultApiBase();
}

function failure(error: string): EndpointResult {
  const result: EndpointResult = { ok: false, url: '', error: error };
  return result;
}

/** Restores the old session and headers after a failed switch; settles the revocation record. */
async function rollBack(previous: string, previousHeaders: Record<string, string>,
  previousToken: string, record: PendingSignOut | null): Promise<void> {
  if (previousToken) {
    try {
      await saveSessionToken(previousToken);
    } catch (err) {
      // The restore failed too; the record stays for a later pass to resolve.
    }
  }
  await saveServerHeaders(previous, previousHeaders);
  if (record !== null) {
    const snapshot = await snapshotSessionToken();
    // Only a restore that stored the session removes its record; otherwise a later flush
    // promotes it unless that token is the active session again.
    if (snapshot.ok && snapshot.value === record.token) {
      await removePendingSignOut(record);
    }
  }
}

async function changeServer(input: string, headers: Record<string, string>): Promise<EndpointResult> {
  const parsed = normalizeApiBase(input);
  if (!parsed.ok) {
    return parsed;
  }
  const previous = currentApiBase();
  const switching = parsed.url !== previous;
  const previousHeaders = serverHeaders(previous);
  let previousToken = '';
  let record: PendingSignOut | null = null;
  if (switching) {
    const generation = currentSessionGeneration();
    const snapshot = await snapshotSessionToken();
    if (!snapshot.ok) {
      return failure('Could not save the previous server session');
    }
    previousToken = snapshot.value;
    if (previousToken) {
      const revocation: PendingSignOut = {
        apiBase: previous,
        token: previousToken,
        headers: previousHeaders,
        recordedAt: Date.now(),
        provisional: true,
      };
      if (!(await savePendingSignOut(revocation))) {
        return failure('Could not save the previous server session');
      }
      record = revocation;
    }
    // A sign-in during the read owns the session now; the switch stops before clearing anything.
    if (generation !== currentSessionGeneration()) {
      return failure('Could not save the previous server session');
    }
    if (!(await clearSessionToken())) {
      await rollBack(previous, previousHeaders, previousToken, record);
      return failure('Could not clear the previous server session');
    }
    setSelectedSpace('');
  }
  if (!(await saveServerHeaders(parsed.url, headers))) {
    if (switching) {
      await rollBack(previous, previousHeaders, previousToken, record);
    }
    return failure('Could not save the server URL');
  }
  const probed = await probeApiBase(parsed.url, headers);
  if (!probed.ok) {
    if (switching) {
      await rollBack(previous, previousHeaders, previousToken, record);
    } else {
      await saveServerHeaders(previous, previousHeaders);
    }
    return probed;
  }
  if (store === null) {
    if (switching) {
      await rollBack(previous, previousHeaders, previousToken, record);
    }
    return failure('Could not save the server URL');
  }
  try {
    await store.put(API_BASE_KEY, parsed.url);
    await store.flush();
  } catch (err) {
    if (switching) {
      await rollBack(previous, previousHeaders, previousToken, record);
    }
    return failure('Could not save the server URL');
  }
  cachedApiBase = parsed.url;
  if (record !== null) {
    await promotePendingSignOut(record);
    // The probe just answered: a connectivity window to deliver the old session's revocation.
    const signOutContext: SignOutContext = { apiBase: parsed.url, activeToken: '' };
    void flushPendingSignOut(signOutContext);
  }
  if (switching) {
    await recordSavedServer(previous, previousHeaders, true);
  }
  await recordSavedServer(parsed.url, headers);
  return parsed;
}

/** Switches (or re-saves) the server, one transaction at a time. */
export function switchServer(input: string, headers: Record<string, string> = {}): Promise<EndpointResult> {
  const result = changeQueue.then((): Promise<EndpointResult> => changeServer(input, headers),
    (): Promise<EndpointResult> => changeServer(input, headers));
  changeQueue = result.then((): EndpointResult => ({ ok: true, url: '', error: '' }),
    (): EndpointResult => ({ ok: true, url: '', error: '' }));
  return result;
}
