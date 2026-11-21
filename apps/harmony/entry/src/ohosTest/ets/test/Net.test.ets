// RPC/auth/server-switch behavior against the offline fixture server (scripts/spike-sse-server.mjs
// on the host, two instances: 8787 and 8788). Covers the 401 branches, 426, retry-after,
// timeout, response cap, token extraction order, sign-out, and switch commit/rollback.
import { describe, expect, it, beforeAll, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { rpc, setUpdateHandler } from '../../../main/ets/net/rpc';
import type { RpcOptions } from '../../../main/ets/net/rpc';
import { RpcError } from '../../../main/ets/net/errors';
import { decodeMe } from '../../../main/ets/contract/decode';
import {
  clearSessionToken,
  loadSessionToken,
  saveSessionToken,
  selectedSpaceId,
  setSelectedSpace,
} from '../../../main/ets/net/session';
import { authCapabilities, signIn, signInWithCode, sendSignInCode, signOut, tokenFromAuthResponse } from '../../../main/ets/net/auth';
import { currentApiBase, initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { serverHeaders } from '../../../main/ets/net/server-headers';
import { probeApiBase } from '../../../main/ets/net/endpoint';
import { getJson, parseJsonObject } from '../../../main/ets/net/http';

const BASE = 'http://10.0.2.2:8787';
const BASE2 = 'http://10.0.2.2:8788';

async function rpcErrorOf(proc: string, options?: RpcOptions): Promise<RpcError> {
  try {
    await rpc(proc, {}, options);
  } catch (err) {
    if (err instanceof RpcError) {
      return err as RpcError;
    }
    throw err as Error;
  }
  throw new Error(`${proc} unexpectedly succeeded`);
}

async function signOutCount(base: string, token: string): Promise<number> {
  const response = await getJson(`${base}/__state`, {}, 8000, 64 * 1024);
  const body = parseJsonObject(response.body);
  let n = 0;
  if (body !== null) {
    for (const item of body['signOuts'] as Object[]) {
      if (item === token) {
        n += 1;
      }
    }
  }
  return n;
}

/** Delivery is fire-and-forget; wait for it to land with a deadline instead of a fixed sleep. */
async function waitForSignOut(base: string, token: string, expected: number): Promise<void> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if ((await signOutCount(base, token)) >= expected) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 100);
    });
  }
  throw new Error(`sign-out for ${token} did not land on ${base}`);
}

async function saveToken(token: string): Promise<void> {
  await saveSessionToken(token);
}

export default function netTest() {
  describe('NetAgainstFixtureServer', () => {
    beforeAll(async () => {
      // preferences rejects the delegator's context itself; its application context works.
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await getJson(`${BASE2}/__reset`, {}, 8000, 64 * 1024);
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('rpc_me_decodes_with_bearer', 0, async () => {
      await saveToken('fake-token');
      const me = decodeMe(await rpc('me', {}));
      expect(me !== null).assertTrue();
      expect(me!.email).assertEqual('ada@example.com');
      expect(me!.spaceId).assertEqual('space-fake');
    });

    it('rpc_401_without_space_clears_the_session', 0, async () => {
      await saveToken('stale-token');
      const error = await rpcErrorOf('me');
      expect(error.status).assertEqual(401);
      expect(await loadSessionToken()).assertEqual('');
    });

    it('rpc_401_with_stale_space_probes_and_keeps_the_session', 0, async () => {
      await saveToken('fake-token');
      setSelectedSpace('space-stale');
      const error = await rpcErrorOf('me');
      expect(error.status).assertEqual(401);
      // The safe read succeeded without the Space header: selection cleared, session kept.
      expect(selectedSpaceId()).assertEqual('');
      expect(await loadSessionToken()).assertEqual('fake-token');
    });

    it('rpc_426_notifies_the_update_handler', 0, async () => {
      let notified = false;
      setUpdateHandler((): void => {
        notified = true;
      });
      const error = await rpcErrorOf('update426');
      expect(error.status).assertEqual(426);
      expect(notified).assertTrue();
    });

    it('rpc_500_carries_retry_after', 0, async () => {
      const error = await rpcErrorOf('error500');
      expect(error.status).assertEqual(500);
      expect(error.retryAfterMs).assertEqual(2000);
    });

    it('rpc_deadline_times_out', 0, async () => {
      const options: RpcOptions = { timeoutMs: 500 };
      const error = await rpcErrorOf('slow', options);
      expect(error.timedOut).assertTrue();
    });

    it('rpc_oversize_response_is_refused', 0, async () => {
      const error = await rpcErrorOf('big');
      expect(error.message.includes('bytes')).assertTrue();
    });

    it('rpc_non_json_success_is_refused', 0, async () => {
      const error = await rpcErrorOf('notjson');
      expect(error.status).assertEqual(200);
    });

    it('probe_health_branches', 0, async () => {
      const ok = await probeApiBase(BASE, {});
      expect(ok.ok).assertTrue();
      const badHeaders: Record<string, string> = {};
      badHeaders['x-test-health'] = 'bad';
      const bad = await probeApiBase(BASE, badHeaders);
      expect(bad.ok).assertFalse();
      expect(bad.error).assertEqual('That URL did not look like a Rakazo server');
      const down = await probeApiBase('http://10.0.2.2:9', {});
      expect(down.ok).assertFalse();
      expect(down.error).assertEqual('Could not reach that server');
      const publicHttp = await probeApiBase('http://example.com', {});
      expect(publicHttp.ok).assertFalse();
    });

    it('token_extraction_order_header_cookie_body', 0, () => {
      const headers: Record<string, string> = {};
      headers['set-auth-token'] = 'header-token';
      headers['set-cookie'] = 'better-auth.session_token=cookie-token; Path=/';
      const body: Record<string, Object> = {};
      body['token'] = 'body-token';
      expect(tokenFromAuthResponse(headers, body)).assertEqual('header-token');
      const noHeader: Record<string, string> = {};
      noHeader['set-cookie'] = 'other=1, better-auth.session_token=cookie-token; Path=/';
      expect(tokenFromAuthResponse(noHeader, body)).assertEqual('cookie-token');
      expect(tokenFromAuthResponse({}, body)).assertEqual('body-token');
      const sessionBody: Record<string, Object> = {};
      const session: Record<string, Object> = {};
      session['token'] = 'session-token';
      sessionBody['session'] = session;
      expect(tokenFromAuthResponse({}, sessionBody)).assertEqual('session-token');
      expect(tokenFromAuthResponse({}, null)).assertEqual('');
    });

    it('sign_in_saves_the_header_token', 0, async () => {
      await signIn('ada@example.com', 'good');
      expect(await loadSessionToken()).assertEqual('fake-token');
    });

    it('sign_in_failure_keeps_no_session_and_shows_server_copy', 0, async () => {
      let message = '';
      try {
        await signIn('ada@example.com', 'wrong');
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).assertEqual('Invalid email or password');
      expect(await loadSessionToken()).assertEqual('');
    });

    it('otp_sign_in_auto_registers', 0, async () => {
      await sendSignInCode('new@example.com');
      await signInWithCode('new@example.com', '123456', 'New User');
      expect(await loadSessionToken()).assertEqual('fake-token');
    });

    it('otp_wrong_code_maps_to_copy', 0, async () => {
      let message = '';
      try {
        await signInWithCode('new@example.com', '000000', null);
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).assertEqual('Invalid code');
    });

    it('capabilities_drive_the_sign_in_page', 0, async () => {
      const caps = await authCapabilities();
      expect(caps.passwordAuth).assertTrue();
      expect(caps.emailCode).assertTrue();
      expect(caps.resetUrl).assertEqual('https://example.com/reset');
    });

    it('sign_out_records_revokes_and_clears', 0, async () => {
      await signIn('ada@example.com', 'good');
      const before = await signOutCount(BASE, 'fake-token');
      await signOut();
      expect(await loadSessionToken()).assertEqual('');
      await waitForSignOut(BASE, 'fake-token', before + 1);
    });

    it('switch_to_unreachable_server_rolls_back', 0, async () => {
      await saveToken('fake-token');
      const result = await switchServer('http://10.0.2.2:9', {});
      expect(result.ok).assertFalse();
      expect(currentApiBase()).assertEqual(BASE);
      expect(await loadSessionToken()).assertEqual('fake-token');
    });

    it('switch_to_healthy_server_commits_and_revokes_the_old_session', 0, async () => {
      await saveToken('fake-token');
      const before = await signOutCount(BASE, 'fake-token');
      const result = await switchServer(BASE2, {});
      expect(result.ok).assertTrue();
      expect(currentApiBase()).assertEqual(BASE2);
      expect(await loadSessionToken()).assertEqual('');
      await waitForSignOut(BASE, 'fake-token', before + 1);
      // Back to the primary fixture server for the suites that follow.
      const back = await switchServer(BASE, {});
      expect(back.ok).assertTrue();
    });

    it('same_server_save_keeps_custom_headers', 0, async () => {
      const headers: Record<string, string> = {};
      headers['x-test-proxy'] = 'credential';
      const result = await switchServer(BASE, headers);
      expect(result.ok).assertTrue();
      expect(serverHeaders(BASE)['x-test-proxy']).assertEqual('credential');
      const reset = await switchServer(BASE, {});
      expect(reset.ok).assertTrue();
      expect(serverHeaders(BASE)['x-test-proxy']).assertUndefined();
    });
  });
}
