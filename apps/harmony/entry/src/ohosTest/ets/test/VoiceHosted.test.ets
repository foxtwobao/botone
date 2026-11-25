// M7 hypium: the hosted voice transport against the offline fixture server — the voice consent
// gate first blocking a speech, the consent allow that opens it, voice/prepare's utterances,
// /api/voice/speak's bytes (a WAV clip), the voice-account failure copy, /api/voice/transcribe's
// text, and the device-voice default over a voice/status that says nothing is connected. Every
// key, provider and voice on the server is a fake probe.
import { describe, expect, it, beforeAll, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { getJson, postJson } from '../../../main/ets/net/http';
import { loadVoiceStatus, prepareSpeech, renderSpeech, transcribeRecording } from '../../../main/ets/voice/hosted-voice';
import { AiConsentBlocked, ensureVoiceConsent } from '../../../main/ets/net/consent';
import { rpc, captureContext } from '../../../main/ets/net/rpc';
import { decodeVoiceCredential, decodeVoiceStatus } from '../../../main/ets/contract/decode-voice';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { initServerStore } from '../../../main/ets/net/server-store';

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
      await reset();
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
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
  });
}
