// M7 hypium: the hosted voice transport against the offline fixture server — the voice consent
// gate first blocking a speech, the consent allow that opens it, voice/prepare's utterances,
// /api/voice/speak's bytes (a WAV clip), the voice-account failure copy, /api/voice/transcribe's
// text, and the device-voice default over a voice/status that says nothing is connected. Every
// key, provider and voice on the server is a fake probe.
//
// Review round 4: a hosted dictation that is cancelled, or ended by the app leaving the
// foreground, while its transcription is still waiting on the consent or on the server.
import { describe, expect, it, beforeAll, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { RequestCancellation } from '../../../main/ets/net/request-cancellation';
import { loadVoiceStatus, prepareSpeech, renderSpeech, transcribeRecording } from '../../../main/ets/voice/hosted-voice';
import { AiConsentBlocked, ensureVoiceConsent } from '../../../main/ets/net/consent';
import { rpc, captureContext } from '../../../main/ets/net/rpc';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { decodeVoiceCredential, decodeVoiceStatus } from '../../../main/ets/contract/decode-voice';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import { setSpeechRecognizer } from '../../../main/ets/voice/dictation';
import { setClipRecorder } from '../../../main/ets/voice/voice-clip';
import { setVoiceMicrophoneGrant } from '../../../main/ets/voice/install';
import type { VoiceRecording } from '../../../main/ets/voice/hosted-voice';
import type { StopSignal } from '../../../main/ets/voice/stop-signal';
import { ComposerDictation, setDictationTranscriber, stopAllComposerDictation } from '../../../main/ets/features/chat/composer-dictation';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';

const BASE = 'http://10.0.2.2:8787';
/** The fixture deployment's own consent constants, as its status answer carries them. */
const CONSENT_SCOPE = 'fake-consent-scope';
const CONSENT_VERSION = '2026-11-12';
const VOICE_KEY = 'voice-key';

async function reset(): Promise<void> {
  await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
  await getJson(`${BASE}/__voiceReset`, {}, 8000, 64 * 1024);
  await saveSessionToken('fake-token');
}

/** Saves the voice recipient's Allow, as the app's own gate would after a prompt. */
async function allowVoice(): Promise<void> {
  const body: Record<string, Object> = {};
  body['scope'] = CONSENT_SCOPE;
  body['version'] = CONSENT_VERSION;
  body['keys'] = [VOICE_KEY];
  await rpc('aiConsent/allow', body);
}

/** The scripted recorder a hosted dictation records through: it stops on either signal and
 *  answers the fixture's clip, as the microphone's own recording would. */
function scriptClip(log: string[]): Promise<void> {
  let recording: (() => void) | null = null;
  const at = new Promise<void>((resolve: () => void): void => {
    recording = resolve;
  });
  setClipRecorder((cancel: StopSignal, until: StopSignal, _onLevel: (level: number) => void,
    _language: string): Promise<VoiceRecording | null> => {
    log.push('record');
    if (recording !== null) {
      recording();
    }
    return new Promise<VoiceRecording | null>((resolve: (value: VoiceRecording | null) => void): void => {
      cancel.onCancel((): void => {
        log.push('cancel');
        resolve(null);
      });
      until.onCancel((): void => {
        log.push('until');
        const clip: VoiceRecording = { audio: recordedWav(), language: 'en-US' };
        resolve(clip);
      });
    });
  });
  return at;
}

/** A self-hosted connection is the provider that transcribes; the device voice is off. */
async function hostProviderDictation(): Promise<void> {
  const connect: Record<string, Object> = {};
  connect['provider'] = 'openai-compatible';
  connect['baseUrl'] = 'http://selfhost.example';
  await rpc('voice/connect', connect);
  deviceVoicePort.setDeviceVoiceStore({
    get: async (_key: string): Promise<string | null> => '0',
    put: async (_key: string, _value: string): Promise<void> => undefined,
  });
  setSpeechRecognizer(null);
  setVoiceMicrophoneGrant((): Promise<boolean> => Promise.resolve(true));
}

/** The fixture's silent WAV clip, as the app would record one for a hosted dictation. */
function recordedWav(): Uint8Array {
  const frames = 1_000;
  const out = new Uint8Array(44 + frames * 2);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string): void => {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  };
  ascii(0, 'RIFF');
  view.setUint32(4, out.byteLength - 8, true);
  ascii(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, frames * 2, true);
  return out;
}

/** The fixture's voice state: what its voice routes were asked, and what each request carried. */
async function voiceState(): Promise<Record<string, Object> | null> {
  const response = await getJson(`${BASE}/__voiceState`, {}, 8000, 256 * 1024);
  return parseJsonObject(response.body);
}

/** Whether the fixture's voice routes were asked for `path` yet. */
async function askedFor(path: string): Promise<boolean> {
  const state = await voiceState();
  return state !== null && (state['requests'] as Object[]).includes(path);
}

/** How many consent reads have reached the fixture so far. */
async function consentReadsReached(): Promise<number> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  let count = 0;
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      if ((item as Record<string, Object>)['path'] === '/rpc/aiConsent/status') {
        count += 1;
      }
    }
  }
  return count;
}

/** Up to three seconds for `condition`. */
async function waitFor(condition: () => Promise<boolean>, label: string): Promise<void> {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (await condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 10);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

/** The fixture's answer to a consent read that finds the voice use allowed. */
function allowedStatus(): Record<string, Object> {
  const recipient: Record<string, Object> = {};
  recipient['key'] = VOICE_KEY;
  recipient['name'] = 'Fake Voice Provider';
  recipient['use'] = 'voice';
  recipient['detail'] = '';
  recipient['allowed'] = true;
  const json: Record<string, Object> = {};
  json['scope'] = CONSENT_SCOPE;
  json['version'] = CONSENT_VERSION;
  json['recipients'] = [recipient];
  const body: Record<string, Object> = {};
  body['json'] = json;
  return body;
}

/** Scripts the fixture's voice routes; null leaves a setting as it is. */
async function scriptVoice(script: Record<string, Object>): Promise<void> {
  await postJson(`${BASE}/__voiceScript`, {}, JSON.stringify(script), 8000, 64 * 1024);
}

/** Waits `ms` on the device's own clock. */
function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/** A transcription on the real transport: how it ended, `pending` until it settles. */
interface Transcription {
  outcome: string;
}

/** Starts a transcription of the fixture's clip behind `cancellation`, without waiting for it. */
function transcribing(context: RpcContext, cancellation: RequestCancellation): Transcription {
  const run: Transcription = { outcome: 'pending' };
  void transcribeRecording({ audio: recordedWav(), language: 'en-US' }, context, cancellation).then(
    (text: string): void => {
      run.outcome = `text ${text}`;
    },
    (err: Object): void => {
      run.outcome = `error ${(err as Error).message}`;
    },
  );
  return run;
}

/** A controller over the hosted path, resolved once its scripted microphone records. */
async function recordingController(words: string[]): Promise<ComposerDictation> {
  await hostProviderDictation();
  const clip: string[] = [];
  const recordingAt = scriptClip(clip);
  const controller = new ComposerDictation(
    (_message: string, _openVoice: boolean): void => undefined,
    (text: string, _final: boolean): void => {
      words.push(text);
    },
  );
  controller.toggle();
  await recordingAt;
  return controller;
}

function head(bytes: Uint8Array, count: number): string {
  let out = '';
  for (let index = 0; index < count; index += 1) {
    out += String.fromCharCode(bytes[index] ?? 0);
  }
  return out;
}

export default function voiceHostedTest() {
  describe('VoiceHostedAgainstFixtureServer', () => {
    beforeAll(async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
      await reset();
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
      stopAllComposerDictation();
      setDictationTranscriber(null);
      setSpeechRecognizer(null);
      setVoiceMicrophoneGrant(null);
      setClipRecorder(null);
      deviceVoicePort.setDeviceVoiceStore(null);
    });

    it('the voice consent blocks a speech until the voice use is allowed', 0, async () => {
      await reset();
      const context = await captureContext();
      let blocked = false;
      try {
        await prepareSpeech('Hello there.', {}, context);
      } catch (err) {
        blocked = err instanceof AiConsentBlocked;
      }
      expect(blocked).assertTrue();
      await allowVoice();
      await ensureVoiceConsent(context);
      // Once the use is allowed, the gate itself answers nothing: it does not throw.
      expect(true).assertTrue();
    });

    it('prepare and speak run on the connected voice', 0, async () => {
      await reset();
      await allowVoice();
      const connect: Record<string, Object> = {};
      connect['provider'] = 'fake-voice';
      connect['apiKey'] = 'fake-key';
      const credential = decodeVoiceCredential(await rpc('voice/connect', connect));
      expect(credential !== null).assertTrue();
      const context = await captureContext();
      const utterances = await prepareSpeech('Hello there. How are you today?', {}, context);
      expect(utterances !== null && utterances.length).assertEqual(2);
      expect(utterances![0]).assertEqual('Hello there.');
      const clip = await renderSpeech('Hello there.', {}, context);
      // The clip is the server's own silent WAV: a RIFF header and its data size.
      expect(head(clip, 12)).assertContain('RIFF');
      expect(head(clip, 12)).assertContain('WAVE');
      expect(clip.byteLength).assertEqual(24_044);
    });

    it('a voice account failure carries its own copy', 0, async () => {
      await reset();
      await allowVoice();
      const connect: Record<string, Object> = {};
      connect['provider'] = 'fake-voice';
      connect['apiKey'] = 'fake-key';
      await rpc('voice/connect', connect);
      const script: Record<string, Object> = {};
      script['speeches'] = 0;
      await postJson(`${BASE}/__voiceScript`, {}, JSON.stringify(script), 8000, 64 * 1024);
      const context = await captureContext();
      let message = '';
      try {
        await renderSpeech('Hello there.', {}, context);
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).assertEqual('Your voice provider is out of credit.');
    });

    it('a recorded clip transcribes through the voice use', 0, async () => {
      await reset();
      await allowVoice();
      const context = await captureContext();
      const text = await transcribeRecording(
        { audio: recordedWav(), language: 'en-US' }, context);
      expect(text).assertEqual('Fake dictated words');
    });

    it('the device voice is the default while nothing is connected', 0, async () => {
      await reset();
      await allowVoice();
      // A scripted store: the choice the module would keep in its preferences file.
      const saved: string[] = [];
      deviceVoicePort.setDeviceVoiceStore({
        get: async (_key: string): Promise<string | null> => saved.length > 0 ? saved[0] : null,
        put: async (_key: string, value: string): Promise<void> => {
          saved.push(value);
        },
      });
      deviceVoicePort.setVoiceStatusReader(async (): Promise<boolean> => (await loadVoiceStatus()).ready);
      try {
        expect(await deviceVoicePort.loadDeviceVoiceEnabled()).assertTrue();
        // The worked-out default is kept: the next read answers without the server.
        expect(await deviceVoicePort.loadDeviceVoiceEnabled()).assertTrue();
        expect(saved[0]).assertEqual('1');
      } finally {
        deviceVoicePort.setDeviceVoiceStore(null);
        deviceVoicePort.setVoiceStatusReader(null);
      }
      // And once a voice is connected, a fresh default picks the hosted one.
      const connect: Record<string, Object> = {};
      connect['provider'] = 'fake-voice';
      connect['apiKey'] = 'fake-key';
      await rpc('voice/connect', connect);
      const status = decodeVoiceStatus(await rpc('voice/status', {}));
      expect(status !== null && status.ready).assertTrue();
    });

    it('a send during a hosted recording keeps and transcribes its words', 0, async () => {
      await reset();
      await allowVoice();
      await hostProviderDictation();
      const clip: string[] = [];
      const recordingAt: Promise<void> = scriptClip(clip);
      const words: string[] = [];
      const controller = new ComposerDictation(
        (_message: string, _openVoice: boolean): void => undefined,
        (text: string, _final: boolean): void => {
          words.push(text);
        },
      );
      controller.toggle();
      await recordingAt;
      expect(controller.status).assertEqual('listening');
      let sent = false;
      let sentSignal: (() => void) | null = null;
      const sentAt = new Promise<void>((resolve: () => void): void => {
        sentSignal = resolve;
      });
      controller.finish((): void => {
        sent = true;
        if (sentSignal !== null) {
          sentSignal();
        }
      });
      await sentAt;
      // The recording was stopped to keep its words, not cancelled with them; the words
      // transcribed through the voice use and the send ran once they landed.
      expect(clip).assertDeepEquals(['record', 'until']);
      expect(sent).assertTrue();
      expect(words).assertDeepEquals(['Fake dictated words']);
      expect(controller.status).assertEqual('idle');
    });

    it('backgrounding cancels a hosted recording', 0, async () => {
      await reset();
      await allowVoice();
      await hostProviderDictation();
      const clip: string[] = [];
      const recordingAt: Promise<void> = scriptClip(clip);
      const words: string[] = [];
      const controller = new ComposerDictation(
        (_message: string, _openVoice: boolean): void => undefined,
        (text: string, _final: boolean): void => {
          words.push(text);
        },
      );
      controller.toggle();
      await recordingAt;
      stopAllComposerDictation();
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 10);
      });
      // The recording was dropped with the session: its own cancel, no transcription, no words.
      expect(clip).assertDeepEquals(['record', 'cancel']);
      expect(words).assertDeepEquals([]);
      expect(controller.status).assertEqual('idle');
    });

    it('a_cancel_while_the_transcriptions_consent_is_pending_gives_it_up_at_once', 0, async () => {
      await reset();
      await allowVoice();
      const reads = await consentReadsReached();
      // The next consent read is held by the server for a second.
      const delayed: Record<string, Object> = allowedStatus();
      delayed['delayResponse'] = true;
      const script: Record<string, Object> = {};
      script['responses'] = [delayed];
      await postJson(`${BASE}/__consentScript`, {}, JSON.stringify(script), 8000, 64 * 1024);
      const cancellation = new RequestCancellation();
      const run = transcribing(await captureContext(), cancellation);
      await waitFor(async (): Promise<boolean> => (await consentReadsReached()) > reads,
        'the consent read of the transcription');
      // Cancel while that consent read is in flight.
      cancellation.cancel();
      await pause(300);
      // The read was given up at once, well inside the second the server holds it...
      expect(run.outcome === 'pending').assertFalse();
      await pause(1_500);
      // ...and the recording never left for the transcription once the held answer came.
      expect(await askedFor('/api/voice/transcribe')).assertFalse();
    });

    it('a_cancel_while_the_transcription_is_in_flight_gives_it_up_at_once', 0, async () => {
      await reset();
      await allowVoice();
      // The server holds its next transcription answer until the suite releases it.
      const hold: Record<string, Object> = {};
      hold['holdTranscribe'] = true;
      await scriptVoice(hold);
      const cancellation = new RequestCancellation();
      const run = transcribing(await captureContext(), cancellation);
      await waitFor((): Promise<boolean> => askedFor('/api/voice/transcribe'), 'the transcription request');
      // Cancel while the server still owes the transcription its answer.
      cancellation.cancel();
      await pause(300);
      // The request was given up at once, not left to wait the answer or the timeout out.
      expect(run.outcome === 'pending').assertFalse();
      // Whatever the case found, the held answer is released so that nothing waits for it.
      const release: Record<string, Object> = {};
      release['releaseTranscribe'] = true;
      await scriptVoice(release);
    });

    it('backgrounding_while_the_transcription_is_in_flight_cancels_its_request', 0, async () => {
      await reset();
      await allowVoice();
      // A transcription that answers only once its request is cancelled.
      let opened = 0;
      let cancelled = false;
      setDictationTranscriber((_clip: VoiceRecording, _context: RpcContext,
        cancellation: RequestCancellation): Promise<string> => {
        opened += 1;
        return new Promise<string>((_resolve: (text: string) => void, reject: (error: Error) => void): void => {
          cancellation.listen((): void => {
            cancelled = true;
            // As the real transport answers a cancelled request: a failure the session ignores.
            reject(new Error('Could not transcribe that.'));
          });
        });
      });
      const words: string[] = [];
      const controller = await recordingController(words);
      controller.toggle();
      await waitFor(async (): Promise<boolean> => opened === 1, 'the transcription request');
      // The app leaves the foreground while the server still owes the transcription its answer.
      stopAllComposerDictation();
      expect(controller.status).assertEqual('idle');
      // The session's cancel reached the request it was waiting on...
      expect(cancelled).assertTrue();
      // ...and nothing of the cancelled turn reached the draft.
      expect(words).assertDeepEquals([]);
    });
  });
}
