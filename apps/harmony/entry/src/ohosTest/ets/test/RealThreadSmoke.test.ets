// M3 vertical-spike real-backend smoke: a REAL self-hosted API, real sign-in, a real bot, the
// consent gate closed once via aiConsent/allow, then threads/send → receipt → live progress →
// run end over the REAL threads/subscribe stream, and a reconnect that catches up from the
// cursor. Opt-in: -s realBase/realEmail/realPassword (the throwaway account whose bot already
// has a working model and consent allowed). Without realBase the suite logs a loud skip.
// The run that counts is recorded in docs/m3-notes.md.
import { describe, expect, it, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { signIn } from '../../../main/ets/net/auth';
import { rpc } from '../../../main/ets/net/rpc';
import { decodeMe } from '../../../main/ets/contract/decode';
import { loadSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { ThreadStream } from '../../../main/ets/realtime/thread-stream';
import { applyThreadSendReceipt } from '../../../main/ets/thread/thread-snapshot';
import type { ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';
import { decodeSendOutput, newClientNonce, sendReceipt } from '../../../main/ets/thread/thread-send';
import { asRecord } from '../../../main/ets/contract/decode';

const DOMAIN = 0x0000;

function arg(name: string): string {
  const params = abilityDelegatorRegistry.getArguments().parameters;
  return params[name] ?? params[`-s ${name}`] ?? '';
}

function configured(): boolean {
  if (arg('realBase')) {
    return true;
  }
  hilog.warn(DOMAIN, 'M3', 'RealThreadSmoke SKIPPED: pass -s realBase/realEmail/realPassword to run it');
  return false;
}

async function waitFor(condition: () => boolean, label: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 100);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
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

export default function realThreadSmoke() {
  describe('RealThreadSmoke', () => {
    beforeAll(async () => {
      if (!configured()) {
        return;
      }
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      const switched = await switchServer(arg('realBase'), {});
      expect(switched.ok).assertTrue();
    });

    it('real_send_receipt_progress_stream_and_run_end', 0, async () => {
      if (!configured()) {
        return;
      }
      await signIn(arg('realEmail'), arg('realPassword'));
      expect((await loadSessionToken()).length > 0).assertTrue();
      const me = decodeMe(await rpc('me', {}));
      expect(me !== null).assertTrue();
      setSelectedSpace(me!.spaceId);
      hilog.info(DOMAIN, 'M3', 'real me: %{public}s', me!.email);

      // The first bot on the account is the spike bot (model connected, consent allowed).
      const bots = await rpc('bots/list', {});
      expect(Array.isArray(bots)).assertTrue();
      const first = asRecord((bots as Object[])[0]);
      expect(first !== null).assertTrue();
      const botId = first!['id'] as string;
      hilog.info(DOMAIN, 'M3', 'real bot: %{public}s', first!['name'] as string);

      let latest: ThreadSnapshot | null = null;
      let progressSeen = false;
      const stream = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
          if (snapshot !== null && liveText(snapshot).length > 0) {
            progressSeen = true;
          }
        },
      });
      const input: Record<string, Object> = {};
      input['botId'] = botId;
      void stream.follow(input);
      await waitFor((): boolean => latest !== null && stream.connected, 'open snapshot', 15_000);
      const messagesBefore = latest!.messages.length;
      hilog.info(DOMAIN, 'M3', 'real thread open: cursor=%{public}d messages=%{public}d',
        latest!.cursor, messagesBefore);

      const body: Record<string, Object> = {};
      body['botId'] = botId;
      body['text'] = 'Reply with exactly: spike ok';
      body['clientNonce'] = newClientNonce();
      const output = decodeSendOutput(await rpc('threads/send', body));
      expect(output !== null).assertTrue();
      hilog.info(DOMAIN, 'M3', 'real send receipt: run=%{public}s seq=%{public}d', output!.runId, output!.seq);

      // The receipt shows the queued run before the stream catches up.
      const withReceipt = applyThreadSendReceipt(stream.current(), sendReceipt(botId, output!),
        stream.terminalRunIds, new Date().toISOString());
      if (withReceipt !== stream.current()) {
        stream.commit(withReceipt);
        expect(stream.current()!.run !== null).assertTrue();
        hilog.info(DOMAIN, 'M3', 'real receipt queued run shown');
      }

      // The user echo arrives over the real stream.
      await waitFor((): boolean => stream.current()!.messages.length > messagesBefore, 'user echo', 15_000);
      // The run works: the live progress bubble must appear while it writes (the reducer's
      // projection — the visible-text preference is the UI layer's, not the stream's).
      await waitFor((): boolean => progressSeen, 'live progress bubble', 90_000);
      hilog.info(DOMAIN, 'M3', 'real progress streamed: yes');
      // The run ends (completed, failed or cancelled) and the live bubble is gone.
      await waitFor((): boolean => stream.current()!.run === null
        || stream.current()!.run!.status === 'failed', 'run end', 120_000);
      const ended = stream.current()!.run;
      hilog.info(DOMAIN, 'M3', 'real run end: %{public}s', ended === null ? 'completed' : `failed: ${ended.error}`);
      expect(liveText(stream.current())).assertEqual('');
      expect(ended === null || ended.status === 'failed').assertTrue();

      // Reconnect catch-up: stop, reopen from the carried cursor. A resume keeps the in-memory
      // snapshot and replays only events after the cursor — here none are pending, so the
      // transcript must stay exactly as it was (no gaps, no duplicates, no re-read).
      const cursor = stream.cursor;
      const transcript = stream.current()!.messages;
      stream.stop();
      const resumed = new ThreadStream({
        commit: (snapshot: ThreadSnapshot | null): void => {
          latest = snapshot;
        },
      });
      resumed.cursor = cursor;
      resumed.loaded = true;
      resumed.commit(stream.current());
      void resumed.follow(input);
      await waitFor((): boolean => resumed.connected, 'reconnect', 15_000);
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 500);
      });
      expect(resumed.cursor).assertEqual(cursor);
      expect(resumed.current()!.messages.length).assertEqual(transcript.length);
      hilog.info(DOMAIN, 'M3', 'real reconnect ok: cursor=%{public}d', resumed.cursor);
      resumed.stop();
      hilog.info(DOMAIN, 'M3', 'real thread smoke complete');
    });
  });
}
