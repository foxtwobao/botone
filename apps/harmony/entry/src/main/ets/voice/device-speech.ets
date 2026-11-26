// The device's own voice (M7): the CoreSpeechKit synthesizer behind SpeechEngines.speakOnDevice.
// One engine serves the speeches while the app is in front, speaking in the bot's assigned device
// voice when one exists, else the voice the device lists for its language; it is shut down when
// the app leaves the foreground or the voice it speaks with changes, so nothing holds the
// pipeline (at most three engines may exist device-wide). Nothing loads until the first speech,
// behind the capability check. Voices that are not installed are never offered, and the kit's
// own voice download is never called: it opens a system ability that must be run by the user.
//
// Creating an engine takes a moment, and a stop, a release or a newer speech may land in it. Each
// speech therefore asks with a ticket taken before its last wait, and whatever was asked for
// before a stop or a release is no longer wanted: an engine that arrives late is shut down at
// once, and nothing starts speaking after the bar has cleared or the app has left the foreground.
import type { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { speechLocaleTag } from './speech-locale';
import { t } from '../i18n/i18n';

type VoiceInfo = textToSpeech.VoiceInfo;

/** What an engine is created for: its language and the voice it speaks with. */
export interface EngineVoice {
  language: string;
  person: number;
}

/** The engine calls the synthesizer makes; the HMS engine satisfies them, so tests can fake it. */
export interface SpeechEngine {
  setListener: (listener: textToSpeech.SpeakListener) => void;
  speak: (text: string, params: textToSpeech.SpeakParams) => void;
  stop: () => void;
  pause: () => void;
  resume: () => void;
  shutdown: () => void;
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
  private engine: SpeechEngine | null = null;
  /** The voice the current engine speaks with. */
  private engineVoice: EngineVoice | null = null;
  private pending: PendingUtterance | null = null;
  private counter = 0;
  /** Moved on by every stop and release: what was asked for under an earlier value is not wanted. */
  private epoch = 0;
  private engineFactory: (() => Promise<SpeechEngine>) | null = null;

  /** Tests hand a scripted engine factory in; null restores the device's own. */
  setEngineFactory(factory: (() => Promise<SpeechEngine>) | null): void {
    this.engineFactory = factory;
  }

  /** The ticket of a speech about to speak: take it before the speech's last wait, so a stop or a
   *  release that lands in that wait leaves it without a voice. */
  ticket(): number {
    return this.epoch;
  }

  /** Speaks once, creating the engine for `voice` when the current one is another voice's. Nothing
   *  is said once a stop or a release has moved past `ticket`; the utterance then counts as
   *  stopped. */
  async speak(text: string, voice: EngineVoice, ticket: number): Promise<void> {
    const engine = await this.ensure(voice, ticket);
    if (engine === null) {
      return;
    }
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
    this.epoch += 1;
    try {
      this.engine?.stop();
    } catch (err) {
      // Already stopped: the pending utterance settles through its own callbacks.
      hilog.warn(0, 'Voice', 'Could not stop the speech');
    }
  }

  pause(): void {
    try {
      this.engine?.pause();
    } catch (err) {
      // Pausing is best effort; the bar still shows the state.
      hilog.warn(0, 'Voice', 'Could not pause the speech');
    }
  }

  resume(): void {
    try {
      this.engine?.resume();
    } catch (err) {
      // Resuming is best effort; the bar still shows the state.
      hilog.warn(0, 'Voice', 'Could not resume the speech');
    }
  }

  /** True while the device's engine could hold what it is saying and go on. The capability is
   *  the platform's own, not this engine's lifetime: the control is built before the engine. */
  canPause(): boolean {
    return canIUse('SystemCapability.AI.TextToSpeech');
  }

  /** Lets go of the engine; the next speech creates a fresh one. */
  release(): void {
    this.epoch += 1;
    const engine = this.engine;
    this.engine = null;
    this.engineVoice = null;
    this.settle(null);
    try {
      engine?.shutdown();
    } catch (err) {
      // A shutdown failure leaves the engine to the system's own lifetime.
      hilog.warn(0, 'Voice', 'Could not shut down the speech engine');
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

  /** The one engine this class holds, created for `voice` when it is not that voice's already.
   *  Null when a stop or a release has moved past `ticket`, before or while it was created: the
   *  engine is then shut down rather than spoken on. */
  private async ensure(voice: EngineVoice, ticket: number): Promise<SpeechEngine | null> {
    if (ticket !== this.epoch) {
      return null;
    }
    if (this.engine !== null && this.engineVoice !== null
      && this.engineVoice.language === voice.language && this.engineVoice.person === voice.person) {
      return this.engine;
    }
    this.release();
    const creating = this.epoch;
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      throw new Error(t('Could not speak'));
    }
    try {
      const factory = this.engineFactory;
      const created = factory !== null ? await factory() : await this.createEngine(voice);
      if (creating !== this.epoch) {
        // Stopped, released or replaced while it was being created: too late to speak, and an
        // engine left open is one of the few the device allows.
        this.shutdown(created);
        return null;
      }
      this.engine = created;
      this.engineVoice = voice;
      return created;
    } catch (err) {
      // The voice is not on this device: the kit's own detail names ids and codes.
      throw new Error(t('Could not speak'));
    }
  }

  /** The kit's own engine for `voice`; a creation the kit refuses is thrown on, with its detail. */
  private async createEngine(voice: EngineVoice): Promise<SpeechEngine> {
    const api = await import('@hms.ai.textToSpeech');
    const params: textToSpeech.CreateEngineParams = {
      language: voice.language, person: voice.person, online: 1,
    };
    try {
      return await api.default.createEngine(params);
    } catch (err) {
      throw err as Error;
    }
  }

  private shutdown(engine: SpeechEngine): void {
    try {
      engine.shutdown();
    } catch (err) {
      // A shutdown failure leaves the engine to the system's own lifetime.
      hilog.warn(0, 'Voice', 'Could not shut down the speech engine');
    }
  }
}

export const deviceSpeech: DeviceSpeech = new DeviceSpeech();
