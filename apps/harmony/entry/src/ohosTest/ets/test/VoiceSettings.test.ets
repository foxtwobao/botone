// M7 review round 4: the Voice settings store against the offline fixture server. An edited
// speech model reaches the server, and the sample speaks with the copy of the settings the page
// reads. Every provider, key, model and voice on the server is a fake probe.
import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import type { common } from '@kit.AbilityKit';
import { getJson, parseJsonObject } from '../../../main/ets/net/http';
import { rpc, captureContext } from '../../../main/ets/net/rpc';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { VoiceSettingsStore } from '../../../main/ets/stores/voice-settings-store';
import { prepareSpeech } from '../../../main/ets/voice/hosted-voice';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import * as speechPort from '../../../main/ets/voice/speech';
import type { SpeechContext, SpeechEngines, SpeechOptions } from '../../../main/ets/voice/speech';

const BASE = 'http://10.0.2.2:8787';
const CONSENT_SCOPE = 'fake-consent-scope';
const CONSENT_VERSION = '2026-11-12';

/** The fixture's voice routes, in arrival order: what was asked and what each request carried. */
interface VoiceRequests {
  paths: string[];
  inputs: Record<string, Object>[];
}

async function reset(): Promise<void> {
  await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
  await saveSessionToken('fake-token');
}

/** Saves the voice recipient's Allow, as the app's own gate would after a prompt. */
async function allowVoice(): Promise<void> {
  const body: Record<string, Object> = {};
  body['scope'] = CONSENT_SCOPE;
  body['version'] = CONSENT_VERSION;
  body['keys'] = ['voice-key'];
  await rpc('aiConsent/allow', body);
}

async function voiceRequests(): Promise<VoiceRequests> {
  const response = await getJson(`${BASE}/__voiceState`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  const paths: string[] = [];
  const inputs: Record<string, Object>[] = [];
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      paths.push(item as string);
    }
    for (const item of body['inputs'] as Object[]) {
      inputs.push(item as Record<string, Object>);
    }
  }
  const requests: VoiceRequests = { paths: paths, inputs: inputs };
  return requests;
}

/** What the first request to `path` carried. */
function carried(requests: VoiceRequests, path: string): Record<string, Object> {
  const at = requests.paths.indexOf(path);
  expect(at).assertLarger(-1);
  return at < 0 ? {} : requests.inputs[at] ?? {};
}

/** The bodies of the consent reads the fixture was asked, in arrival order. */
async function consentReads(): Promise<string[]> {
  const response = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  const reads: string[] = [];
  if (body !== null) {
    for (const item of body['requests'] as Object[]) {
      const record = item as Record<string, Object>;
      if (record['path'] === '/rpc/aiConsent/status') {
        reads.push(record['body'] as string);
      }
    }
  }
  return reads;
}

export default function voiceSettingsTest(): void {
  describe('VoiceSettingsAgainstFixtureServer', () => {
    let context: common.Context | null = null;

    beforeAll(async (): Promise<void> => {
      context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    afterEach(async (): Promise<void> => {
      speechPort.stopVoicePlayback();
      speechPort.noteSessionChanged();
      speechPort.setSpeechEngines(null);
      deviceVoicePort.setDeviceVoiceStore(null);
      await clearSessionToken();
      await setSelectedSpace('');
    });

    it('an_edited_speech_model_is_saved', 0, async () => {
      await reset();
      await allowVoice();
      const connect: Record<string, Object> = {};
      connect['provider'] = 'fake-voice';
      connect['apiKey'] = 'fake-key';
      connect['speechModel'] = 'model-one';
      await rpc('voice/connect', connect);
      const store = new VoiceSettingsStore();
      await store.load();
      expect(store.credential?.speechModel).assertEqual('model-one');
      // The field is edited, then submitted with the form's own value, as the page submits it.
      store.edit('speechModel', 'model-two');
      await store.saveSpeechModel(store.speechModel);
      expect(store.error).assertEqual('');
      // The save went out, and the server now holds the edited value.
      expect((await voiceRequests()).paths.includes('/rpc/voice/setSpeechModel')).assertTrue();
      const saved = parseJsonObject((await getJson(`${BASE}/__voiceState`, {}, 8000, 64 * 1024)).body);
      expect(saved !== null ? saved['speechModel'] : '').assertEqual('model-two');
      // The page shows what was saved.
      expect(store.credential?.speechModel).assertEqual('model-two');
      expect(store.speechModel).assertEqual('model-two');
    });

    it('the_sample_names_the_same_copy_of_the_settings_as_the_page_reads', 0, async () => {
      await reset();
      await allowVoice();
      const connect: Record<string, Object> = {};
      connect['provider'] = 'fake-voice';
      connect['apiKey'] = 'fake-key';
      await rpc('voice/connect', connect);
      // The page is open inside a Space: the copy it shows is whichever applies there.
      await setSelectedSpace('space-1');
      // The device's own voice is off, so the sample asks the server for its speech; the clip
      // itself is not played here.
      deviceVoicePort.setDeviceVoiceStore({
        get: async (_key: string): Promise<string | null> => '0',
        put: async (_key: string, _value: string): Promise<void> => undefined,
      });
      const engines: SpeechEngines = {
        captureContext: (): Promise<RpcContext> => captureContext(),
        deviceVoiceEnabled: (): Promise<boolean> => deviceVoicePort.loadDeviceVoiceEnabled(),
        deviceVoiceFor: (_botId: string): Promise<string | undefined> => Promise.resolve(undefined),
        deviceCanPause: (): boolean => false,
        stopDevice: (): void => undefined,
        pauseDevice: (): void => undefined,
        resumeDevice: (): void => undefined,
        speakOnDevice: (_utterance: string, _voice: string | undefined): Promise<void> => {
          return Promise.reject(new Error('The device voice is off in this speech'));
        },
        prepare: prepareSpeech,
        render: async (): Promise<Uint8Array> => new Uint8Array(0),
        playClip: async (): Promise<void> => undefined,
      };
      speechPort.setSpeechEngines(engines);
      const store = new VoiceSettingsStore();
      await store.load();
      await store.testVoice();
      expect(store.error).assertEqual('');
      // The page's own reads name no scope, and neither does the sample: not the speech it
      // asks the server to prepare...
      const requests = await voiceRequests();
      expect(carried(requests, '/rpc/voice/status')['scope']).assertUndefined();
      expect(carried(requests, '/rpc/voice/prepare')['scope']).assertUndefined();
      // ...nor the consent it asks for on the way.
      const reads = await consentReads();
      expect(reads[reads.length - 1]).assertEqual('{"json":{"uses":["voice"]}}');
    });
  });
}
