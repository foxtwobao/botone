// The consent gate at the REAL transport boundary (design §4.3.3 ⇩v3, the M1 consent-dispatch
// pattern): the real rpc + gate against the fixture server, whose request log is the transport
// record. The scripted scenarios mirror the TS fixture's cases (contract/fixtures/consent.json,
// generated from the real mobile rpc); the session-generation cases inject real session events.
// Invariant asserted everywhere: a refused/stale scenario NEVER dispatches the original request,
// and no non-gated request body ever carries the private text.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { rpc } from '../../../main/ets/net/rpc';
import { RpcError } from '../../../main/ets/net/errors';
import { setConsentPrompt } from '../../../main/ets/net/consent';
import type { AiRecipient } from '../../../main/ets/net/consent';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { getJson, postJson, parseJsonObject } from '../../../main/ets/net/http';
import { app } from '../../../main/ets/app/app-state';

const BASE = 'http://10.0.2.2:8787';
const OTHER = 'http://10.0.2.2:8788';
const PRIVATE_TEXT = 'private content';

interface PromptCall {
  key: string;
  name: string;
  use: string;
  detail: string;
  privacyUrl?: string;
}

async function resetServer(): Promise<void> {
  await postJson(`${BASE}/__reset`, {}, '{}', 8000, 64 * 1024);
}

/** The /rpc request paths in arrival order (the transport log). */
async function transportPaths(): Promise<string[]> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  const paths: string[] = [];
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      const record = item as Record<string, Object>;
      const path = record['path'];
      if (typeof path === 'string' && (path as string).startsWith('/rpc/')) {
        paths.push(path as string);
      }
    }
  }
  return paths;
}

/** No non-gated request body carries the private text (the privacy invariant). */
async function assertPrivateTextContained(gatedPath: string): Promise<void> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  if (body === null) {
    return;
  }
  for (const item of body['requests'] as Object[]) {
    const record = item as Record<string, Object>;
    const path = typeof record['path'] === 'string' ? record['path'] as string : '';
    const rawBody = typeof record['body'] === 'string' ? record['body'] as string : '';
    if (path !== gatedPath) {
      expect(rawBody.includes(PRIVATE_TEXT)).assertFalse();
    }
  }
}

function sendBody(): Record<string, Object> {
  const body: Record<string, Object> = {};
  body['botId'] = 'bot-1';
  body['text'] = PRIVATE_TEXT;
  body['clientNonce'] = 'nonce-1';
  return body;
}

function answerBody(): Record<string, Object> {
  const body: Record<string, Object> = {};
  body['botId'] = 'bot-1';
  body['runId'] = 'run-1';
  body['messageId'] = 'msg-1';
  body['answer'] = 'allow';
  return body;
}

/** Script the consent answers the server gives, in request order. */
async function scriptConsent(responses: Object[]): Promise<void> {
  const input: Record<string, Object> = {};
  input['responses'] = responses;
  await postJson(`${BASE}/__consentScript`, {}, JSON.stringify(input), 8000, 64 * 1024);
}

function statusResponse(recipients: Object[], privacyUrl?: string): Record<string, Object> {
  const json: Record<string, Object> = {};
  json['scope'] = 'fake-consent-scope';
  json['version'] = '2026-11-12';
  json['recipients'] = recipients;
  if (privacyUrl !== undefined) {
    json['privacyUrl'] = privacyUrl;
  }
  const body: Record<string, Object> = {};
  body['json'] = json;
  const response: Record<string, Object> = {};
  response['body'] = body;
  return response;
}

function recipient(key: string, use: string, allowed: boolean): Record<string, Object> {
  const row: Record<string, Object> = {};
  row['key'] = key;
  row['name'] = `Provider ${key}`;
  row['use'] = use;
  row['detail'] = '';
  row['allowed'] = allowed;
  return row;
}

function okResponse(): Record<string, Object> {
  const json: Record<string, Object> = {};
  json['ok'] = true;
  const body: Record<string, Object> = {};
  body['json'] = json;
  const response: Record<string, Object> = {};
  response['body'] = body;
  return response;
}

/** Install a prompt that records calls and answers from the queue; returns the record. */
function installPrompt(answers: boolean[], duringPrompt?: () => Promise<void>): PromptCall[] {
  const calls: PromptCall[] = [];
  let index = 0;
  setConsentPrompt(async (r: AiRecipient, privacyUrl: string | undefined): Promise<boolean> => {
    const call: PromptCall = { key: r.key, name: r.name, use: r.use, detail: r.detail };
    if (privacyUrl !== undefined) {
      call.privacyUrl = privacyUrl;
    }
    calls.push(call);
    if (duringPrompt !== undefined) {
      await duringPrompt();
    }
    const answer = answers[index] === true;
    index += 1;
    return answer;
  });
  return calls;
}

async function expectBlocked(run: () => Promise<Object>, message: string): Promise<void> {
  let failed: RpcError | null = null;
  try {
    await run();
  } catch (err) {
    failed = err as RpcError;
  }
  expect(failed !== null).assertTrue();
  expect(failed!.message).assertEqual(message);
}

const REQUIRED = 'Review AI data sharing in Account settings before continuing.';
const STALE = 'Something went wrong. Try again.';
const UPDATE_SERVER = 'Update your server to use AI data sharing in this mobile version.';

export default function consentGateTest() {
  describe('ConsentGateTransport', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    beforeEach(async () => {
      // A previous case may have switched servers; every case starts pinned to BASE.
      await switchServer(BASE, {});
      await resetServer();
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
    });

    afterEach(async () => {
      setConsentPrompt(null);
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('all_allowed_dispatches_without_a_prompt', 0, async () => {
      await scriptConsent([statusResponse([recipient('model-key', 'model', true), recipient('memory-key', 'memory', true)])]);
      const calls = installPrompt([]);
      await rpc('threads/send', sendBody());
      expect(calls.length).assertEqual(0);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status,/rpc/threads/send');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('allow_saves_then_dispatches_with_the_deployment_privacy_url', 0, async () => {
      await scriptConsent([
        statusResponse([recipient('model-key', 'model', false)], 'https://example.com/privacy'),
        statusResponse([recipient('model-key', 'model', true)]),
      ]);
      const calls = installPrompt([true]);
      await rpc('threads/send', sendBody());
      expect(calls.length).assertEqual(1);
      expect(calls[0].key).assertEqual('model-key');
      expect(calls[0].privacyUrl).assertEqual('https://example.com/privacy');
      expect((await transportPaths()).join(','))
        .assertEqual('/rpc/aiConsent/status,/rpc/aiConsent/allow,/rpc/threads/send');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('answer_goes_through_the_same_gate', 0, async () => {
      await scriptConsent([
        statusResponse([recipient('model-key', 'model', false)]),
        statusResponse([recipient('model-key', 'model', true)]),
      ]);
      const calls = installPrompt([true]);
      await rpc('threads/answer', answerBody());
      expect(calls.length).assertEqual(1);
      expect((await transportPaths()).join(','))
        .assertEqual('/rpc/aiConsent/status,/rpc/aiConsent/allow,/rpc/threads/answer');
    });

    it('second_recipient_refused_after_the_first_allow', 0, async () => {
      await scriptConsent([
        statusResponse([recipient('model-key', 'model', false), recipient('memory-key', 'memory', false)]),
        statusResponse([recipient('model-key', 'model', true)]),
      ]);
      const calls = installPrompt([true, false]);
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), REQUIRED);
      expect(calls.length).assertEqual(2);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status,/rpc/aiConsent/allow');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('refusal_blocks_the_dispatch', 0, async () => {
      await scriptConsent([statusResponse([recipient('model-key', 'model', false)])]);
      installPrompt([false]);
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), REQUIRED);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('failed_status_query_blocks_the_dispatch', 0, async () => {
      const fail: Record<string, Object> = {};
      fail['fail'] = true;
      await scriptConsent([fail]);
      installPrompt([]);
      let caught: RpcError | null = null;
      try {
        await rpc('threads/send', sendBody());
      } catch (err) {
        caught = err as RpcError;
      }
      expect(caught !== null).assertTrue();
      // A dropped connection can be retried once by the transport before it surfaces; the
      // invariant is that every attempt is a status query and the send never dispatches.
      const paths = await transportPaths();
      expect(paths.every((p: string): boolean => p === '/rpc/aiConsent/status')).assertTrue();
      expect(paths.length >= 1 && paths.length <= 2).assertTrue();
      await assertPrivateTextContained('/rpc/threads/send');
      expect(caught!.message).assertEqual('Could not reach the server');
    });

    it('status_404_asks_for_a_server_update', 0, async () => {
      const notFound: Record<string, Object> = {};
      notFound['status'] = 404;
      await scriptConsent([notFound]);
      installPrompt([]);
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), UPDATE_SERVER);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status');
    });

    it('failed_allow_save_blocks_the_dispatch', 0, async () => {
      const fault: Record<string, Object> = {};
      fault['status'] = 500;
      await scriptConsent([statusResponse([recipient('model-key', 'model', false)]), fault]);
      installPrompt([true]);
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), 'Server fault');
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status,/rpc/aiConsent/allow');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('concurrent_sends_share_one_prompt_and_each_dispatch_once', 0, async () => {
      await scriptConsent([
        statusResponse([recipient('model-key', 'model', false)]),
        statusResponse([recipient('model-key', 'model', false)]),
        statusResponse([recipient('model-key', 'model', true)]),
      ]);
      const calls = installPrompt([true]);
      await Promise.all([rpc('threads/send', sendBody()), rpc('threads/send', sendBody())]);
      expect(calls.length).assertEqual(1);
      const paths = await transportPaths();
      expect(paths.filter((p: string): boolean => p === '/rpc/aiConsent/status').length).assertEqual(2);
      expect(paths.filter((p: string): boolean => p === '/rpc/aiConsent/allow').length).assertEqual(1);
      expect(paths.filter((p: string): boolean => p === '/rpc/threads/send').length).assertEqual(2);
    });

    it('concurrent_refusal_grants_and_dispatches_nothing', 0, async () => {
      await scriptConsent([
        statusResponse([recipient('model-key', 'model', false)]),
        statusResponse([recipient('model-key', 'model', false)]),
      ]);
      const calls = installPrompt([false]);
      const results = await Promise.allSettled([rpc('threads/send', sendBody()), rpc('threads/send', sendBody())]);
      expect(results.every((r): boolean => r.status === 'rejected')).assertTrue();
      // The asks may or may not overlap on the device's scheduling; the security invariant is
      // that neither dispatches nor grants anything (the strict one-prompt coalescing is pinned
      // by the concurrent-allow case and the TS fixture).
      expect(calls.length >= 1 && calls.length <= 2).assertTrue();
      const paths = await transportPaths();
      expect(paths.filter((p: string): boolean => p === '/rpc/aiConsent/allow').length).assertEqual(0);
      expect(paths.filter((p: string): boolean => p === '/rpc/threads/send').length).assertEqual(0);
    });

    it('sign_in_during_the_prompt_blocks_allow_and_dispatch', 0, async () => {
      await scriptConsent([statusResponse([recipient('model-key', 'model', false)])]);
      installPrompt([true], async (): Promise<void> => {
        await saveSessionToken('fake-token-2');
      });
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), STALE);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('server_switch_during_the_prompt_keeps_requests_on_the_old_server', 0, async () => {
      await scriptConsent([statusResponse([recipient('model-key', 'model', false)])]);
      installPrompt([true], async (): Promise<void> => {
        const switched = await switchServer(OTHER, {});
        expect(switched.ok).assertTrue();
      });
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), STALE);
      const paths = await transportPaths();
      expect(paths.join(',')).assertEqual('/rpc/aiConsent/status');
      // Every dispatched request stayed on the pinned old server (the log is the old server's).
      await assertPrivateTextContained('/rpc/threads/send');
      // Restore for the next case.
      await switchServer(BASE, {});
    });

    it('sign_in_before_the_allow_response_blocks_the_dispatch', 0, async () => {
      // The allow request is dispatched, then the session changes before its answer is consumed:
      // the outer re-check refuses the original send (mobile api.ts:730). The fake allow answer
      // is delayed so the session event lands while it is in flight.
      const delayed: Record<string, Object> = {};
      delayed['body'] = statusResponse([recipient('model-key', 'model', true)])['body'];
      delayed['delayMs'] = 400;
      await scriptConsent([statusResponse([recipient('model-key', 'model', false)]), delayed]);
      installPrompt([true], async (): Promise<void> => {
        // The prompt resolves; the allow fetch is now in flight. Bump the generation mid-flight.
        setTimeout((): void => {
          void saveSessionToken('fake-token-2');
        }, 100);
      });
      await expectBlocked((): Promise<Object> => rpc('threads/send', sendBody()), STALE);
      expect((await transportPaths()).join(',')).assertEqual('/rpc/aiConsent/status,/rpc/aiConsent/allow');
      await assertPrivateTextContained('/rpc/threads/send');
    });

    it('ungated_procedures_never_query_consent', 0, async () => {
      installPrompt([]);
      const stop: Record<string, Object> = {};
      stop['botId'] = 'bot-1';
      await rpc('threads/stop', stop);
      const paths = await transportPaths();
      expect(paths.join(',')).assertEqual('/rpc/threads/stop');
    });
  });
}
