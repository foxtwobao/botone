// M3 vertical-spike integration against the fixture server with the REAL ThreadStream, rpc and
// send-receipt path: open → scripted history, send → receipt queued run → user echo over the
// stream, injected progress deltas → run end, a cut stream reconnects without gaps or duplicate
// bubbles, and the request log proves reads happen only on open/disconnect/settle (NO polling).
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { ThreadStream } from '../../../main/ets/realtime/thread-stream';
import { rpc } from '../../../main/ets/net/rpc';
import { RpcError, isServerUnreachable } from '../../../main/ets/net/errors';
import { getJson, postJson, parseJsonObject } from '../../../main/ets/net/http';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { applyThreadSendReceipt } from '../../../main/ets/thread/thread-snapshot';
import type { ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';
import { decodeSendOutput, newClientNonce, sendReceipt } from '../../../main/ets/thread/thread-send';
import { app } from '../../../main/ets/app/app-state';
import { setConsentPrompt } from '../../../main/ets/net/consent';
import type { AiRecipient } from '../../../main/ets/net/consent';

const BASE = 'http://10.0.2.2:8787';

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 25);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

async function inject(type: string, runId: string, payload: Record<string, Object>): Promise<number> {
  const input: Record<string, Object> = {};
  input['botId'] = 'bot-1';
  input['type'] = type;
  if (runId) {
    input['runId'] = runId;
  }
  input['payload'] = payload;
  const response = await postJson(`${BASE}/__threadEvent`, {}, JSON.stringify(input), 8000, 64 * 1024);
  const body = parseJsonObject(response.body);
  const seq = body !== null ? body['seq'] : 0;
  return typeof seq === 'number' ? seq as number : 0;
}

async function cutStream(): Promise<void> {
  const input: Record<string, Object> = {};
  input['botId'] = 'bot-1';
  await postJson(`${BASE}/__threadCut`, {}, JSON.stringify(input), 8000, 64 * 1024);
}

async function requestCount(path: string): Promise<number> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  let count = 0;
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      const record = item as Record<string, Object>;
      if (record['path'] === path) {
        count += 1;
      }
    }
  }
  return count;
}

async function resetServer(): Promise<void> {
  await postJson(`${BASE}/__reset`, {}, '{}', 8000, 64 * 1024);
}

function liveText(snapshot: ThreadSnapshot | null): string {
  if (snapshot === null) {
    return '';
  }
  let text = '';
  for (const message of snapshot.messages) {
    if (message.id.startsWith('progress:')) {
      for (const block of message.blocks) {
        if (block['kind'] === 'progress' || block['kind'] === 'text') {
          text += typeof block['text'] === 'string' ? block['text'] as string : '';
        }
      }
    }
  }
  return text;
}

function messageTexts(snapshot: ThreadSnapshot | null): string[] {
  const texts: string[] = [];
  if (snapshot === null) {
    return texts;
  }
  for (const message of snapshot.messages) {
    if (message.id.startsWith('progress:')) {
      continue;
    }
    for (const block of message.blocks) {
      if (block['kind'] === 'text' && typeof block['text'] === 'string') {
        texts.push(block['text'] as string);
      }
    }
  }
  return texts;
}

export default function threadRealtimeTest() {
  describe('ThreadRealtimeAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    beforeEach(async () => {
      await resetServer();
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      // The consent gate's own suite covers the refusal semantics; this suite's sends allow.
      setConsentPrompt(async (_r: AiRecipient, _url: string | undefined): Promise<boolean> => true);
    });

    afterEach(async () => {
      setConsentPrompt(null);
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('open_loads_the_scripted_history_and_run_state', 0, async () => {
      let latest: ThreadSnapshot | null = null;
      const stream = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      void stream.follow(input);
      await waitFor((): boolean => latest !== null && stream.connected, 'open snapshot');
      expect(latest!.threadId).assertEqual('thread-bot-1');
      expect(latest!.cursor).assertEqual(6);
      expect(messageTexts(latest)).assertDeepEquals(['hello', 'Hi there.']);
      expect(latest!.run).assertNull();
      stream.stop();
    });

    it('send_receipt_then_echo_then_progress_then_run_end', 0, async () => {
      let latest: ThreadSnapshot | null = null;
      const stream = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      void stream.follow(input);
      await waitFor((): boolean => latest !== null && stream.connected, 'open');

      // The send: the receipt shows the queued run before any event arrives.
      const body: Record<string, Object> = {};
      body['botId'] = 'bot-1';
      body['text'] = 'spike message';
      body['clientNonce'] = newClientNonce();
      const sendStarted = Date.now();
      const output = decodeSendOutput(await rpc('threads/send', body));
      const sendMs = Date.now() - sendStarted;
      expect(output !== null).assertTrue();
      const withReceipt = applyThreadSendReceipt(stream.current(), sendReceipt('bot-1', output!),
        stream.terminalRunIds, new Date().toISOString());
      expect(withReceipt !== stream.current()).assertTrue();
      stream.commit(withReceipt);
      expect(stream.current()!.run !== null).assertTrue();
      expect(stream.current()!.run!.status).assertEqual('queued');

      // The user echo and run.started arrive over the open stream.
      await waitFor((): boolean => messageTexts(stream.current()).includes('spike message'), 'user echo');
      await waitFor((): boolean => stream.current()!.run !== null
        && stream.current()!.run!.status === 'running', 'run started');
      expect(stream.current()!.run!.id).assertEqual(output!.runId);

      // Progress deltas stream into one live bubble, then the durable answer replaces it.
      const delta1: Record<string, Object> = {};
      delta1['delta'] = 'Streaming';
      await inject('thread.progress', output!.runId, delta1);
      const delta2: Record<string, Object> = {};
      delta2['delta'] = ' answer.';
      await inject('thread.progress', output!.runId, delta2);
      await waitFor((): boolean => liveText(stream.current()) === 'Streaming answer.', 'progress accumulated');
      const created: Record<string, Object> = {};
      created['messageId'] = 'spike-answer';
      created['seq'] = 9;
      created['role'] = 'bot';
      const block: Record<string, Object> = {};
      block['kind'] = 'text';
      block['text'] = 'Streaming answer.';
      created['blocks'] = [block];
      await inject('thread.message.created', output!.runId, created);
      await waitFor((): boolean => messageTexts(stream.current()).includes('Streaming answer.'), 'durable answer');
      expect(liveText(stream.current())).assertEqual('');
      await inject('run.completed', output!.runId, {});
      await waitFor((): boolean => stream.current()!.run === null, 'run ended');
      // No duplicate bubbles: the answer appears exactly once.
      expect(messageTexts(stream.current()).filter((t: string): boolean => t === 'Streaming answer.').length)
        .assertEqual(1);
      // The send answered in one round trip, not after a stall.
      expect(sendMs < 4000).assertTrue();
      stream.stop();
    });

    it('cut_stream_reconnects_from_the_cursor_without_gaps', 0, async () => {
      let latest: ThreadSnapshot | null = null;
      const stream = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      void stream.follow(input);
      await waitFor((): boolean => latest !== null && stream.connected, 'open');
      const cursorBefore = stream.cursor;

      // Another device's activity lands while the stream is cut; the reconnect must catch up.
      await cutStream();
      const delta: Record<string, Object> = {};
      delta['delta'] = 'missed while cut';
      const injectedSeq = await inject('thread.progress', 'run-cut', delta);
      await waitFor((): boolean => stream.connected && stream.cursor >= injectedSeq, 'reconnected and caught up');
      expect(stream.cursor >= cursorBefore).assertTrue();
      expect(liveText(stream.current())).assertEqual('missed while cut');
      // The durable history is still there exactly once (no duplicate bubbles after reconnect).
      expect(messageTexts(stream.current()).filter((t: string): boolean => t === 'hello').length).assertEqual(1);
      stream.stop();
    });

    it('offline_open_keeps_the_error_and_a_retry_recovers', 0, async () => {
      const errors: RpcError[] = [];
      let latest: ThreadSnapshot | null = null;
      const stream = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
        onError: (error: RpcError): void => {
          errors.push(error);
        },
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      const on: Record<string, Object> = {};
      on['on'] = true;
      await postJson(`${BASE}/__offline`, {}, JSON.stringify(on), 8000, 64 * 1024);
      try {
        // The open read cannot reach the server: the loop surfaces the error and stops —
        // no polling retry. The screen shows the error with a Retry entry (the store owns it).
        await stream.follow(input);
        expect(errors.length).assertEqual(1);
        expect(isServerUnreachable(errors[0])).assertTrue();
        expect(latest).assertNull();
        expect(stream.connected).assertFalse();
      } finally {
        const off: Record<string, Object> = {};
        off['on'] = false;
        await postJson(`${BASE}/__offline`, {}, JSON.stringify(off), 8000, 64 * 1024);
        stream.stop();
      }
      // The user's Retry: a fresh stream opens normally once the server answers again.
      const retry = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
      });
      void retry.follow(input);
      await waitFor((): boolean => latest !== null && retry.connected, 'retry open');
      expect(retry.current()!.messages.length > 0).assertTrue();
      retry.stop();
    });

    it('stop_then_send_receipt_cannot_revive_a_terminal_run', 0, async () => {
      const stream = new ThreadStream({
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      void stream.follow(input);
      await waitFor((): boolean => stream.connected, 'open');
      const body: Record<string, Object> = {};
      body['botId'] = 'bot-1';
      body['text'] = 'will stop';
      body['clientNonce'] = newClientNonce();
      const output = decodeSendOutput(await rpc('threads/send', body));
      await waitFor((): boolean => stream.current()!.run !== null
        && stream.current()!.run!.id === output!.runId, 'run live');
      const stopBody: Record<string, Object> = {};
      stopBody['botId'] = 'bot-1';
      await rpc('threads/stop', stopBody);
      await waitFor((): boolean => stream.current()!.run === null, 'cancelled');
      expect(stream.terminalRunIds.has(output!.runId)).assertTrue();
      // A late receipt for the stopped run must not show it queued again.
      const late = applyThreadSendReceipt(stream.current(), sendReceipt('bot-1', output!),
        stream.terminalRunIds, new Date().toISOString());
      expect(late).assertEqual(stream.current());
      stream.stop();
    });
    it('reads_happen_only_on_open_disconnect_and_settle_never_on_a_timer', 0, async () => {
      const stream = new ThreadStream({
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      void stream.follow(input);
      await waitFor((): boolean => stream.connected, 'open');
      const getsAfterOpen = await requestCount('/rpc/threads/get');
      expect(getsAfterOpen).assertEqual(1);
      // Idle with the stream open: no timed re-read.
      await pause(1200);
      expect(await requestCount('/rpc/threads/get')).assertEqual(1);
      // A run-settle event triggers exactly one coalesced refresh.
      await inject('run.completed', 'run-settle', {});
      await waitFor((): boolean => true, 'settle');
      await pause(300);
      expect(await requestCount('/rpc/threads/get')).assertEqual(2);
      await pause(800);
      expect(await requestCount('/rpc/threads/get')).assertEqual(2);
      stream.stop();
    });

  });
}
