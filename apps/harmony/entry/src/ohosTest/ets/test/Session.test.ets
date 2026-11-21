// Session + pending sign-out safety semantics on device (asset storage, fake server):
// token round trip and generation bumps; the revocation record delivers once and is removed;
// a failing delivery keeps the record for the next window; a provisional record is not
// delivered until promoted. All tokens are fake probes.
import { describe, expect, it, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  clearSessionToken,
  currentSessionGeneration,
  loadSessionToken,
  saveSessionToken,
} from '../../../main/ets/net/session';
import {
  deliverSignOutRecord,
  flushPendingSignOut,
  promotePendingSignOut,
  removePendingSignOut,
  savePendingSignOut,
} from '../../../main/ets/net/sign-out';
import type { PendingSignOut, SignOutContext } from '../../../main/ets/net/sign-out';
import { getJson, parseJsonObject } from '../../../main/ets/net/http';

const BASE = 'http://10.0.2.2:8787';
const DOMAIN = 0x0000;

function record(token: string, provisional: boolean): PendingSignOut {
  const headers: Record<string, string> = {};
  const entry: PendingSignOut = {
    apiBase: BASE,
    token: token,
    headers: headers,
    recordedAt: Date.now(),
    provisional: provisional,
  };
  return entry;
}

async function signOutLog(): Promise<string[]> {
  const response = await getJson(`${BASE}/__state`, {}, 8000, 64 * 1024);
  const body = parseJsonObject(response.body);
  const tokens: string[] = [];
  if (body !== null) {
    for (const item of body['signOuts'] as Object[]) {
      tokens.push(item as string);
    }
  }
  return tokens;
}

function count(tokens: string[], token: string): number {
  let n = 0;
  for (const t of tokens) {
    if (t === token) {
      n += 1;
    }
  }
  return n;
}

export default function sessionTest() {
  describe('SessionAndSignOut', () => {
    beforeAll(async () => {
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await clearSessionToken();
    });

    it('token_round_trip_and_generation', 0, async () => {
      const before = currentSessionGeneration();
      await saveSessionToken('probe-session-token');
      expect(await loadSessionToken()).assertEqual('probe-session-token');
      expect(currentSessionGeneration() > before).assertTrue();
      const cleared = await clearSessionToken();
      expect(cleared).assertTrue();
      expect(await loadSessionToken()).assertEqual('');
    });

    it('delivered_record_is_removed_and_not_resent', 0, async () => {
      const revocation = record('fake-token', false);
      expect(await savePendingSignOut(revocation)).assertTrue();
      await deliverSignOutRecord(revocation, true);
      const first = await signOutLog();
      expect(count(first, 'fake-token')).assertEqual(1);
      // The record is gone: a second pass must not send it again.
      await deliverSignOutRecord(revocation, true);
      const second = await signOutLog();
      expect(count(second, 'fake-token')).assertEqual(1);
    });

    it('failing_delivery_keeps_the_record_for_the_next_window', 0, async () => {
      const revocation = record('retry-token', false);
      expect(await savePendingSignOut(revocation)).assertTrue();
      await deliverSignOutRecord(revocation, true);
      const context: SignOutContext = { apiBase: BASE, activeToken: '' };
      await flushPendingSignOut(context, true);
      const log = await signOutLog();
      expect(count(log, 'retry-token') >= 2).assertTrue();
      await removePendingSignOut(revocation);
    });

    it('gone_session_401_completes_the_record', 0, async () => {
      const revocation = record('gone-token', false);
      expect(await savePendingSignOut(revocation)).assertTrue();
      await deliverSignOutRecord(revocation, true);
      await deliverSignOutRecord(revocation, true);
      const log = await signOutLog();
      expect(count(log, 'gone-token')).assertEqual(1);
    });

    it('provisional_record_waits_for_promotion', 0, async () => {
      const revocation = record('fake-token', true);
      expect(await savePendingSignOut(revocation)).assertTrue();
      const before = count(await signOutLog(), 'fake-token');
      await deliverSignOutRecord(revocation, true);
      expect(count(await signOutLog(), 'fake-token')).assertEqual(before);
      await promotePendingSignOut(revocation);
      const committed = record('fake-token', false);
      await deliverSignOutRecord(committed, true);
      expect(count(await signOutLog(), 'fake-token')).assertEqual(before + 1);
    });

    it('flush_reconciles_a_dead_switchs_provisional_record', 0, async () => {
      // A provisional record whose token is not the active session is promoted and delivered.
      const revocation = record('fake-token', true);
      expect(await savePendingSignOut(revocation)).assertTrue();
      const before = count(await signOutLog(), 'fake-token');
      const context: SignOutContext = { apiBase: BASE, activeToken: 'a-different-token' };
      await flushPendingSignOut(context, true);
      expect(count(await signOutLog(), 'fake-token')).assertEqual(before + 1);
      hilog.info(DOMAIN, 'M1', 'sign-out log: %{public}s', JSON.stringify(await signOutLog()));
    });
  });
}
