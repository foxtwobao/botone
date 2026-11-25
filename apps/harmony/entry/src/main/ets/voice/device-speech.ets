// The device's own voice (M7): the CoreSpeechKit synthesizer behind SpeechEngines.speakOnDevice.
// One engine serves the speeches while the app is in front, speaking in the bot's assigned device
// voice when one exists, else the voice the device lists for its language; it is shut down when
// the app leaves the foreground or the voice it speaks with changes, so nothing holds the
// pipeline (at most three engines may exist device-wide). Nothing loads until the first speech,
// behind the capability check. Voices that are not installed are never offered, and the kit's
// own voice download is never called: it opens a system ability that must be run by the user.
import type { textToSpeech } from '@kit.CoreSpeechKit';
import { speechLocaleTag } from './speech-locale';
import { t } from '../i18n/i18n';

type Engine = textToSpeech.TextToSpeechEngine;
type VoiceInfo = textToSpeech.VoiceInfo;

/** What an engine is created for: its language and the voice it speaks with. */
export interface EngineVoice {
  language: string;
  person: number;
}

/** The identifier the bot-voice assignment knows a listed voice by: 'zh-CN-13'. */
export function voiceIdentifier(voice: VoiceInfo): string {
  return `${voice.language.replace('_', '-').toLowerCase()}-${voice.person}`;
}

function engineVoiceOf(voice: VoiceInfo): EngineVoice {
  const resolved: EngineVoice = { language: voice.language.replace('_', '-'), person: voice.person };
  return resolved;
}

/**
 * The voices installed on the device, as the kit lists them; the listing is a kit call of its
 * own, with no engine to create. A device with no speech lists nothing.
 */
export async function installedVoices(): Promise<VoiceInfo[]> {
  if (!canIUse('SystemCapability.AI.TextToSpeech')) {
    return [];
  }
  try {
    const api = await import('@hms.ai.textToSpeech');
    const voices = await api.default.listVoices({ requestId: 'rakazo-voices', online: 1 });
    return voices.filter((voice: VoiceInfo): boolean => voice.status === 'INSTALLED');
  } catch (err) {
    return [];
  }
}

/**
 * The engine voice a bot's identifier names, from the device's own list; when the identifier
 * names nothing, the device's language decides: the first voice it lists for it, else a bare
 * language tag whose engine answers with its own failure (which reads as "could not speak").
 */
export async function engineVoiceFor(identifier: string | undefined,
  deviceLanguage: string): Promise<EngineVoice> {
  const voices = await installedVoices();
  if (identifier !== undefined) {
    for (const voice of voices) {
      if (voiceIdentifier(voice) === identifier) {
        return engineVoiceOf(voice);
      }
    }
  }
  const language = deviceLanguage.toLowerCase();
  for (const voice of voices) {
    if (voice.language.replace('_', '-').toLowerCase().startsWith(language)) {
      return engineVoiceOf(voice);
    }
  }
  const bare: EngineVoice = { language: speechLocaleTag(deviceLanguage), person: 0 };
  return bare;
}

interface PendingUtterance {
  requestId: string;
  resolve: () => void;
  reject: (error: Error) => void;
}

/**
 * Says one utterance at a time and settles when it ended or was stopped. Stop works while a
 * synthesis is still being prepared; pause and resume only while it is being said.
 */
export class DeviceSpeech {
  private engine: Engine | null = null;
  /** The voice the current engine speaks with. */
  private engineVoice: EngineVoice | null = null;
  private pending: PendingUtterance | null = null;
  private counter = 0;

  /** Speaks once, creating the engine for `voice` when the current one is another voice's. */
  async speak(text: string, voice: EngineVoice): Promise<void> {
    const engine = await this.ensure(voice);
    const requestId = `rakazo-${Date.now()}-${(this.counter += 1)}`;
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      const pending: PendingUtterance = { requestId: requestId, resolve: resolve, reject: reject };
      this.pending = pending;
      engine.setListener(this.listener());
      engine.speak(text, { requestId: requestId });
    });
  }

  private listener(): textToSpeech.SpeakListener {
    return {
      onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {},
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        // Type 1 is the playback's end; type 0 only the synthesis's.
        if (response.type === 1) {
          this.settle(requestId);
        }
      },
      onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
        this.settle(requestId);
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        this.fail(requestId, errorMessage || `${errorCode}`);
      },
    };
  }

  stop(): void {
    try {
      this.engine?.stop();
    } catch (err) {
      // Already stopped: the pending utterance settles through its own callbacks.
    }
  }

  pause(): void {
    try {
      this.engine?.pause();
    } catch (err) {
      // Pausing is best effort; the bar still shows the state.
    }
  }

  resume(): void {
    try {
      this.engine?.resume();
    } catch (err) {
      // Resuming is best effort; the bar still shows the state.
    }
  }

  /** True while the device's engine could hold what it is saying and go on. The capability is
   *  the platform's own, not this engine's lifetime: the control is built before the engine. */
  canPause(): boolean {
    return canIUse('SystemCapability.AI.TextToSpeech');
  }

  /** Lets go of the engine; the next speech creates a fresh one. */
  release(): void {
    const engine = this.engine;
    this.engine = null;
    this.engineVoice = null;
    this.settle(null);
    try {
      engine?.shutdown();
    } catch (err) {
      // A shutdown failure leaves the engine to the system's own lifetime.
    }
  }

  private settle(requestId: string | null): void {
    const pending = this.pending;
    if (pending === null) {
      return;
    }
    if (requestId !== null && pending.requestId !== requestId) {
      return;
    }
    this.pending = null;
    pending.resolve();
  }

  private fail(requestId: string, message: string): void {
    const pending = this.pending;
    if (pending === null || pending.requestId !== requestId) {
      return;
    }
    this.pending = null;
    pending.reject(new Error(message));
  }

  /** The one engine this class holds, created for `voice` when it is not that voice's already. */
  private async ensure(voice: EngineVoice): Promise<Engine> {
    if (this.engine !== null && this.engineVoice !== null
      && this.engineVoice.language === voice.language && this.engineVoice.person === voice.person) {
      return this.engine;
    }
    this.release();
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      throw new Error(t('Could not speak'));
    }
    const api = await import('@hms.ai.textToSpeech');
    const params: textToSpeech.CreateEngineParams = {
      language: voice.language, person: voice.person, online: 1,
    };
    try {
      const engine = await api.default.createEngine(params);
      this.engine = engine;
      this.engineVoice = voice;
      return engine;
    } catch (err) {
      // The voice is not on this device: the kit's own detail names ids and codes.
      throw new Error(t('Could not speak'));
    }
  }
}

export const deviceSpeech: DeviceSpeech = new DeviceSpeech();
