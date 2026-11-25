// Voice composition (M7): the engines the speech module and the dictation run on, installed at
// app start. One file owns the wiring, so the state machines stay engine-free and replayable.
// The app leaving the foreground ends every microphone and speaker: the playback stops, the
// dictation session ends, and the device engines are released rather than held in the background.
import type { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { captureContext } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { subscribeSession, subscribeSpaceSelection } from '../net/session';
import { foreground } from '../realtime/foreground';
import {
  loadDeviceVoiceEnabled,
  setDeviceVoiceStore,
  setVoiceStatusReader,
} from './device-voice';
import { setSpeechEngines, stopVoicePlayback, noteSessionChanged } from './speech';
import type { HostedSession } from './speech';
import { stop as stopDictation, setSpeechRecognizer } from './dictation';
import { loadVoiceStatus, prepareSpeech, renderSpeech } from './hosted-voice';
import { voiceForBot } from './bot-voices-store';
import { deviceRecognizer } from './device-recognizer';
import { deviceSpeech, engineVoiceFor } from './device-speech';
import { playClip } from './clip-player';
import { requestMicrophone } from './microphone';
import { initVoicePrefs, voiceChoiceStore } from './voice-prefs';

let host: common.UIAbilityContext | null = null;
let installed = false;

/** The device's language prefix: the part voices and engines are chosen by. */
function deviceLanguage(): string {
  try {
    return i18n.System.getSystemLanguage().toLowerCase().split('-')[0] ?? '';
  } catch (err) {
    return '';
  }
}

/** The engine voice a bot's assigned device voice names, or the device's own when it has none. */
async function speakOnDevice(utterance: string, voice: string | undefined): Promise<void> {
  return deviceSpeech.speak(utterance, await engineVoiceFor(voice, deviceLanguage()));
}

async function playHostedClip(bytes: Uint8Array, session: HostedSession): Promise<void> {
  if (host === null) {
    throw new Error('No file context');
  }
  return playClip(bytes, session, host);
}

/** Asks for the microphone when it is not allowed yet, for a hosted dictation the plan did not
 *  ask for itself. True when dictation may record. */
export function requestVoiceMicrophone(): Promise<boolean> {
  if (host === null) {
    return Promise.resolve(false);
  }
  return requestMicrophone(host);
}

/** Installs the device and hosted engines behind the speech and dictation modules. */
export function installVoice(context: common.UIAbilityContext): void {
  if (installed) {
    return;
  }
  installed = true;
  host = context;
  deviceRecognizer.setContext(context);
  setSpeechRecognizer(deviceRecognizer);
  void initVoicePrefs(context).then((ok: boolean): void => {
    if (ok) {
      setDeviceVoiceStore(voiceChoiceStore);
    }
  });
  setVoiceStatusReader(async (): Promise<boolean> => (await loadVoiceStatus()).ready);
  setSpeechEngines({
    captureContext: (): Promise<RpcContext> => captureContext(),
    deviceVoiceEnabled: (): Promise<boolean> => loadDeviceVoiceEnabled(),
    deviceVoiceFor: (botId: string): Promise<string | undefined> => voiceForBot(botId),
    deviceCanPause: (): boolean => deviceSpeech.canPause(),
    stopDevice: (): void => deviceSpeech.stop(),
    pauseDevice: (): void => deviceSpeech.pause(),
    resumeDevice: (): void => deviceSpeech.resume(),
    speakOnDevice: speakOnDevice,
    prepare: prepareSpeech,
    render: renderSpeech,
    playClip: playHostedClip,
  });
  subscribeSession((): void => noteSessionChanged());
  subscribeSpaceSelection((): void => noteSessionChanged());
  foreground.subscribe((isForeground: boolean): void => {
    if (!isForeground) {
      stopVoicePlayback();
      deviceSpeech.release();
      stopDictation();
      void deviceRecognizer.release();
    }
  });
}
