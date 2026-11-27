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
import { ThreadStore } from '../../../main/ets/stores/thread-store';

const BASE = 'http://10.0.2.2:8787';
const ME_USER = 'user-fake';

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

    it('seeded_history_pages_backwards_and_a_settle_refresh_keeps_them', 0, async () => {
      // A 10k-message thread: the open returns the server-shaped recent page (100 messages,
      // olderCursor at its floor); loadOlder prepends page after page; a run-settle refresh
      // must NOT drop the loaded history (mobile thread-sync's preserveHistory).
      const seed: Record<string, Object> = {};
      seed['botId'] = 'bot-1';
      seed['count'] = 10_000;
      await postJson(`${BASE}/__threadSeed`, {}, JSON.stringify(seed), 8000, 64 * 1024);
      const store = new ThreadStore();
      store.open('bot-1', '', ME_USER);
      await waitFor((): boolean => store.snapshot !== null && store.snapshot!.messages.length === 100,
        'recent page');
      expect(store.olderCursor).assertEqual(9901);
      expect(store.snapshot!.cursor).assertEqual(10_000);
      await store.loadOlder();
      await waitFor((): boolean => store.snapshot!.messages.length === 200, 'first older page');
      expect(store.olderCursor).assertEqual(9801);
      await store.loadOlder();
      await waitFor((): boolean => store.snapshot!.messages.length === 300, 'second older page');
      // The pages are contiguous and ordered: history 9701 … history 10000, each exactly once.
      const texts = messageTexts(store.snapshot);
      expect(texts.length).assertEqual(300);
      expect(texts[0]).assertEqual('history 9701');
      expect(texts[299]).assertEqual('history 10000');
      expect(new Set(texts).size).assertEqual(300);
      // A run starts and settles live: the coalesced refresh reconciles the run but keeps
      // every loaded page (the bug this pins: a refresh used to reset to the recent 100).
      const runPayload: Record<string, Object> = {};
      runPayload['trigger'] = 'user';
      await inject('run.started', 'run-seed', runPayload);
      await waitFor((): boolean => store.working(), 'run working');
      await inject('run.completed', 'run-seed', {});
      await waitFor((): boolean => !store.working() && store.snapshot!.messages.length === 300,
        'settle refresh keeps history');
      await pause(400);
      expect(store.snapshot!.messages.length).assertEqual(300);
      expect(messageTexts(store.snapshot)[0]).assertEqual('history 9701');
      expect(store.olderCursor).assertEqual(9701);
      store.close();
    });

    it('history_window_caps_loaded_pages_and_jump_returns_to_latest', 0, async () => {
      // Design §9 R4: memory must not grow linearly with history. The window caps loaded history
      // at 1,000 durable messages, keeping the old end (the reading position) and evicting the
      // newest side; "Jump to latest" re-reads the recent page without a reopen (the live cursor
      // and stream survive).
      const seed: Record<string, Object> = {};
      seed['botId'] = 'bot-1';
      seed['count'] = 10_000;
      await postJson(`${BASE}/__threadSeed`, {}, JSON.stringify(seed), 8000, 64 * 1024);
      const store = new ThreadStore();
      store.open('bot-1', '', ME_USER);
      await waitFor((): boolean => store.snapshot !== null && store.snapshot!.messages.length === 100,
        'recent page');
      expect(store.awayFromLatest).assertEqual(false);
      // Nine older pages fill the window exactly: 1,000 messages, nothing evicted yet.
      for (let page = 0; page < 9; page += 1) {
        await store.loadOlder();
      }
      await waitFor((): boolean => store.snapshot!.messages.length === 1000, 'window full');
      expect(messageTexts(store.snapshot)[0]).assertEqual('history 9001');
      expect(store.awayFromLatest).assertEqual(false);
      expect(store.olderCursor).assertEqual(9001);
      // The tenth page: the window keeps the OLD end (the reading position) and evicts the
      // newest 100 — it slides, it never grows, and the freshly loaded page survives.
      await store.loadOlder();
      await waitFor((): boolean => store.snapshot!.messages.length === 1000
        && messageTexts(store.snapshot)[0] === 'history 8901', 'window slides');
      const texts = messageTexts(store.snapshot);
      expect(texts[999]).assertEqual('history 9900');
      expect(store.olderCursor).assertEqual(8901);
      expect(store.awayFromLatest).assertEqual(true);
      // A settle refresh keeps the window (preserveHistory inside the cap), never re-inflates it.
      const runPayload: Record<string, Object> = {};
      runPayload['trigger'] = 'user';
      await inject('run.started', 'run-window', runPayload);
      await waitFor((): boolean => store.working(), 'run working');
      await inject('run.completed', 'run-window', {});
      await waitFor((): boolean => !store.working(), 'run settled');
      await pause(400);
      expect(store.snapshot!.messages.length).assertEqual(1000);
      expect(messageTexts(store.snapshot)[0]).assertEqual('history 8901');
      // Jump to latest: one threads/get re-reads the recent page without a reopen — the stream
      // survives (a reopen would re-subscribe AND re-get with a new open read first).
      const getsBefore = await requestCount('/rpc/threads/get');
      const subscribesBefore = await requestCount('/rpc/threads/subscribe');
      store.jumpToLatest();
      await waitFor((): boolean => store.snapshot!.messages.length === 100
        && messageTexts(store.snapshot)[99] === 'history 10000', 'back at latest');
      expect(await requestCount('/rpc/threads/get')).assertEqual(getsBefore + 1);
      expect(await requestCount('/rpc/threads/subscribe')).assertEqual(subscribesBefore);
      expect(store.awayFromLatest).assertEqual(false);
      expect(store.olderCursor).assertEqual(9901);
      store.close();
    });

    // Same-cursor refresh: the server snapshot has no progress row, but its cursor does not pass the live one.
    // The next case is the ahead-cursor refresh, where the snapshot itself moves the transcript.
    it('jump_to_latest_keeps_live_progress_and_the_existing_subscription_at_equal_cursor', 0, async () => {
      const seed: Record<string, Object> = {};
      seed['botId'] = 'bot-1';
      seed['count'] = 1_100;
      await postJson(`${BASE}/__threadSeed`, {}, JSON.stringify(seed), 8000, 64 * 1024);
      const store = new ThreadStore();
      store.open('bot-1', '', ME_USER);
      try {
        await waitFor((): boolean => store.snapshot !== null && store.snapshot!.messages.length === 100,
          'recent page');
        for (let page = 0; page < 10; page += 1) {
          await store.loadOlder();
        }
        expect(store.awayFromLatest).assertEqual(true);

        const runId = 'jump-progress-run';
        const prefix = 'verify progress before jump';
        const suffix = ' plus progress after jump';
        await inject('run.started', runId, {});
        const progress: Record<string, Object> = {};
        progress['delta'] = prefix;
        await inject('thread.progress', runId, progress);
        await waitFor((): boolean => liveText(store.snapshot) === prefix, 'live progress before jump');
        expect(store.working()).assertEqual(true);
        expect(messageTexts(store.snapshot).includes('history 1100')).assertEqual(false);

        const getsBefore = await requestCount('/rpc/threads/get');
        const subscribesBefore = await requestCount('/rpc/threads/subscribe');
        store.jumpToLatest();
        await waitFor((): boolean => messageTexts(store.snapshot).includes('history 1100'),
          'jump refresh restores the latest durable page');
        expect(store.awayFromLatest).assertEqual(false);
        expect(store.working()).assertEqual(true); // ThreadPage shows Stop while working.
        expect(await requestCount('/rpc/threads/get')).assertEqual(getsBefore + 1);
        expect(await requestCount('/rpc/threads/subscribe')).assertEqual(subscribesBefore);
        expect(liveText(store.snapshot)).assertEqual(prefix);

        const delta: Record<string, Object> = {};
        delta['delta'] = suffix;
        await inject('thread.progress', runId, delta);
        await waitFor((): boolean => liveText(store.snapshot).includes(suffix), 'next progress delta');
        expect(liveText(store.snapshot)).assertEqual(prefix + suffix);
        expect(store.rows.filter((row): boolean => row.message?.id.startsWith('progress:') === true).length)
          .assertEqual(1);
        expect(store.working()).assertEqual(true);
        expect(await requestCount('/rpc/threads/subscribe')).assertEqual(subscribesBefore);
      } finally {
        store.close();
      }
    });

    it('jump_to_latest_keeps_live_progress_when_the_server_snapshot_is_ahead', 0, async () => {
      const seed: Record<string, Object> = {};
      seed['botId'] = 'bot-1';
      seed['count'] = 1_100;
      await postJson(`${BASE}/__threadSeed`, {}, JSON.stringify(seed), 8000, 64 * 1024);
      const store = new ThreadStore();
      store.open('bot-1', '', ME_USER);
      try {
        await waitFor((): boolean => store.snapshot !== null && store.snapshot!.messages.length === 100,
          'recent page');
        for (let page = 0; page < 10; page += 1) {
          await store.loadOlder();
        }
        expect(store.awayFromLatest).assertEqual(true);

        const runId = 'ahead-progress-run';
        const prefix = 'verify progress before jump';
        const suffix = ' plus progress after jump';
        await inject('run.started', runId, {});
        const progress: Record<string, Object> = {};
        progress['delta'] = prefix;
        await inject('thread.progress', runId, progress);
        await waitFor((): boolean => liveText(store.snapshot) === prefix, 'live progress before jump');

        const hidden: Record<string, Object> = {};
        hidden['botId'] = 'bot-1';
        hidden['type'] = 'thread.message.created';
        const payload: Record<string, Object> = {};
        payload['messageId'] = 'ahead-durable-message';
        payload['seq'] = 1_101;
        payload['role'] = 'user';
        const block: Record<string, Object> = {};
        block['kind'] = 'text';
        block['text'] = 'message from another device';
        payload['blocks'] = [block];
        hidden['payload'] = payload;
        await postJson(`${BASE}/__threadEvent`, {}, JSON.stringify(hidden), 8000, 64 * 1024);

        const getsBefore = await requestCount('/rpc/threads/get');
        const subscribesBefore = await requestCount('/rpc/threads/subscribe');
        store.jumpToLatest();
        await waitFor((): boolean => messageTexts(store.snapshot).includes('message from another device'),
          'jump refresh merges the newer server snapshot');
        expect(store.awayFromLatest).assertEqual(false);
        expect(store.working()).assertEqual(true);
        expect(await requestCount('/rpc/threads/get')).assertEqual(getsBefore + 1);
        expect(await requestCount('/rpc/threads/subscribe')).assertEqual(subscribesBefore);
        expect(liveText(store.snapshot)).assertEqual(prefix);

        const delta: Record<string, Object> = {};
        delta['delta'] = suffix;
        await inject('thread.progress', runId, delta);
        await waitFor((): boolean => liveText(store.snapshot).includes(suffix), 'next progress delta');
        expect(liveText(store.snapshot)).assertEqual(prefix + suffix);
        expect(store.rows.filter((row): boolean => row.message?.id.startsWith('progress:') === true).length)
          .assertEqual(1);
        expect(store.working()).assertEqual(true);
        expect(await requestCount('/rpc/threads/subscribe')).assertEqual(subscribesBefore);
      } finally {
        store.close();
      }
    });
    it('a_live_message_arriving_during_a_page_read_survives_the_prepend', 0, async () => {
      const seed: Record<string, Object> = {};
      seed['botId'] = 'bot-1';
      seed['count'] = 300;
      await postJson(`${BASE}/__threadSeed`, {}, JSON.stringify(seed), 8000, 64 * 1024);
      const store = new ThreadStore();
      store.open('bot-1', '', ME_USER);
      await waitFor((): boolean => store.snapshot !== null && store.snapshot!.messages.length === 100,
        'recent page');
      // Start the page read, then land a live message before the read's commit paints.
      const loading = store.loadOlder();
      const payload: Record<string, Object> = {};
      payload['messageId'] = 'live-during-page';
      payload['seq'] = 301;
      payload['role'] = 'bot';
      const blocks: Object[] = [];
      const block: Record<string, Object> = {};
      block['kind'] = 'text';
      block['text'] = 'live while paging';
      blocks.push(block);
      payload['blocks'] = blocks;
      await inject('thread.message.created', '', payload);
      await loading;
      await waitFor((): boolean => messageTexts(store.snapshot).includes('live while paging'),
        'live message kept');
      const texts = messageTexts(store.snapshot);
      expect(texts.filter((t: string): boolean => t === 'live while paging').length).assertEqual(1);
      expect(texts.length).assertEqual(201);
      expect(texts[0]).assertEqual('history 101');
      store.close();
    });

  });
}
