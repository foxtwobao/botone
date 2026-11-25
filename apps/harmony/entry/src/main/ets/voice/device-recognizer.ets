// The device's own recognizer (M7): the CoreSpeechKit speech recognizer and the AudioCapturer
// behind dictation's SpeechRecognizer. One engine answers every session while the app is in
// front; its language is the recognition locale (the device's language, the app's when the
// speaker's is not a speech locale), and it is available only when the engine itself lists that
// language. The microphone answers 16 kHz mono S16LE PCM, handed over in the 1280-byte frames
// the engine takes; the engine's own 60-second cap reads as a session that ended, which the
// state machine restarts as it does every natural end — and that restart keeps the microphone,
// so a rotating segment never drops audio. Listening ending for real stops and releases the
// microphone, so no capture outlives the dictation that asked for it; callbacks name their
// session, so a late word from an old segment cannot touch the one now running. Nothing loads
// until the first listen, behind the capability check, and both the engine and the microphone
// are released when the app leaves the foreground. Tests hand a scripted engine and microphone
// in through setHardware.
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import type { audio } from '@kit.AudioKit';
import { i18n } from '@kit.LocalizationKit';
import type { common } from '@kit.AbilityKit';
import { recognitionLocaleTag } from './speech-locale';
import { currentLocale } from '../i18n/i18n';
import { paceLevel, pcmLevel } from './voice-clip';
import type { DictationError, DictationResult, RecognizerEvents, RecognizerStartOptions } from './dictation';
import type { SpeechRecognizer } from './dictation';
import { requestMicrophone } from './microphone';

/** The engine calls the recognizer makes; the HMS engine satisfies it, so tests can fake it. */
export interface RecognizerEngine {
  setListener: (listener: speechRecognizer.RecognitionListener) => void;
  startListening: (params: speechRecognizer.StartParams) => void;
  writeAudio: (sessionId: string, audio: Uint8Array) => void;
  finish: (sessionId: string) => void;
  cancel: (sessionId: string) => void;
  shutdown: () => void;
  listLanguages: (params: speechRecognizer.LanguageQuery) => Promise<Array<string>>;
}

/** The microphone the recognizer records from: the AudioCapturer behind a seam tests can fake. */
export interface CaptureMic {
  onFrames: (frames: (buffer: ArrayBuffer) => void) => void;
  start: () => Promise<void>;
  stop: () => Promise<void>;
  release: () => Promise<void>;
}

/** The frame the engine takes: 640 or 1280 bytes of 16 kHz mono S16LE PCM. */
const FRAME_BYTES = 1_280;
/** The engine accepts at most 60,000 ms of audio per session. */
const SESSION_AUDIO_MS = 60_000;

/** The recognition locale the composer dictates in: the device's language, the app's when the
 *  speaker's is not a speech locale. */
export function recognitionLanguage(): string {
  return recognitionLocaleTag(currentLocale(), i18n.System.getSystemLanguage());
}

/** One running session: the engine's id, and where the microphone's frames feed it. */
interface LiveSession {
  sessionId: string;
  fed: number;
}

/** The microphone's own AudioCapturer, behind the seam's shape. */
async function openCapturer(): Promise<CaptureMic | null> {
  if (!canIUse('SystemCapability.Multimedia.Audio.Core')) {
    return null;
  }
  const api = await import('@ohos.multimedia.audio');
  const streamInfo: audio.AudioStreamInfo = {
    samplingRate: api.default.AudioSamplingRate.SAMPLE_RATE_16000,
    channels: api.default.AudioChannel.CHANNEL_1,
    sampleFormat: api.default.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
    encodingType: api.default.AudioEncodingType.ENCODING_TYPE_RAW,
  };
  const capturerInfo: audio.AudioCapturerInfo = {
    source: api.default.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
    capturerFlags: 0,
  };
  const capturer = await api.default.createAudioCapturer({
    streamInfo: streamInfo, capturerInfo: capturerInfo,
  });
  const mic: CaptureMic = {
    onFrames: (frames: (buffer: ArrayBuffer) => void): void => {
      capturer.on('readData', frames);
    },
    start: async (): Promise<void> => {
      await capturer.start();
    },
    stop: async (): Promise<void> => {
      await capturer.stop();
    },
    release: async (): Promise<void> => {
      try {
        capturer.off('readData');
      } catch (err) {
        // The listener goes with the capturer either way.
      }
      await capturer.release();
    },
  };
  return mic;
}

/**
 * The adapter itself: engine and microphone owned together, events routed to whoever is
 * listening. The microphone opens while a listener is installed and closes when listening ends.
 */
export class DeviceRecognizer implements SpeechRecognizer {
  private context: common.UIAbilityContext | null = null;
  private engine: RecognizerEngine | null = null;
  private available: boolean = false;
  private mic: CaptureMic | null = null;
  private events: RecognizerEvents | null = null;
  private session: LiveSession | null = null;
  private carry: number[] = [];
  private followsLevel: boolean = false;
  private counter = 0;
  private loading: Promise<void> | null = null;
  private engineFactory: (() => Promise<RecognizerEngine | null>) | null = null;
  private micFactory: (() => Promise<CaptureMic | null>) | null = null;
  /** The level, paced to a few times a second whatever the microphone hands over. */
  private levelOut: (level: number) => void = (_level: number): void => undefined;

  /** The app hands its context over at start; a test hands a fake one in its place. */
  setContext(context: common.UIAbilityContext | null): void {
    this.context = context;
  }

  /** Tests hand scripted hardware in; null restores the device's own engine and microphone. */
  setHardware(engine: (() => Promise<RecognizerEngine | null>) | null,
    mic: (() => Promise<CaptureMic | null>) | null): void {
    this.engineFactory = engine;
    this.micFactory = mic;
  }

  /** Prepares the engine and its language; resolves once start() can be called. */
  async load(): Promise<void> {
    if (this.loading !== null) {
      return this.loading;
    }
    this.loading = this.prepare();
    return this.loading;
  }

  private async prepare(): Promise<void> {
    try {
      const factory = this.engineFactory;
      if (factory === null && !canIUse('SystemCapability.AI.SpeechRecognizer')) {
        this.available = false;
        return;
      }
      const language = recognitionLanguage();
      const engine = factory !== null ? await factory() : await this.createEngine(language);
      if (engine === null) {
        this.available = false;
        return;
      }
      engine.setListener(this.listener());
      this.engine = engine;
      const languages = await engine.listLanguages({ sessionId: 'rakazo-ask' });
      this.available = languages.includes(language);
    } catch (err) {
      this.available = false;
    }
  }

  private async createEngine(language: string): Promise<RecognizerEngine | null> {
    const api = await import('@hms.ai.speechRecognizer');
    try {
      return await api.default.createEngine({ language: language, online: 1 });
    } catch (err) {
      // A failed engine creation is no engine at all: the caller reads no availability.
      return null;
    }
  }

  isRecognitionAvailable(): boolean {
    return this.available;
  }

  /** Asks only when the microphone is not allowed yet. */
  requestPermissions(): Promise<boolean> {
    if (this.context === null) {
      return Promise.resolve(false);
    }
    return requestMicrophone(this.context);
  }

  start(options: RecognizerStartOptions): void {
    const engine = this.engine;
    if (engine === null) {
      return;
    }
    const sessionId = `rakazo-${Date.now()}-${(this.counter += 1)}`;
    this.followsLevel = options.level;
    const session: LiveSession = { sessionId: sessionId, fed: 0 };
    this.session = session;
    this.carry = [];
    try {
      engine.startListening({
        sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16_000, soundChannel: 1, sampleBit: 16 },
      });
    } catch (err) {
      this.session = null;
      const failure: DictationError = { error: 'unknown' };
      this.events?.error(failure);
      return;
    }
    void this.openMicrophone();
  }

  abort(): void {
    const engine = this.engine;
    const session = this.session;
    this.session = null;
    this.carry = [];
    if (engine !== null && session !== null) {
      try {
        engine.cancel(session.sessionId);
      } catch (err) {
        // A session already over: nothing to cancel.
      }
    }
    // Listening ended here, not rotating into the next segment: the microphone goes with it.
    this.closeMicrophone();
  }

  /** Stops and releases the microphone; the next listen opens one of its own. */
  private closeMicrophone(): void {
    const mic = this.mic;
    this.mic = null;
    if (mic !== null) {
      void mic.stop().then((): Promise<void> => mic.release()).catch((): void => undefined);
    }
  }

  listen(events: RecognizerEvents): () => void {
    this.events = events;
    this.levelOut = paceLevel((value: number): void => {
      this.events?.level(value);
    });
    return (): void => {
      this.abort();
      this.events = null;
    };
  }

  /** Lets go of the engine and the microphone; the next listen creates both again. */
  async release(): Promise<void> {
    this.abort();
    const engine = this.engine;
    this.engine = null;
    this.available = false;
    this.loading = null;
    try {
      engine?.shutdown();
    } catch (err) {
      // A shutdown failure leaves the engine to the system's own lifetime.
    }
  }

  /** A callback belongs to the session it names: one from an older segment must not touch the
   *  running one. With none running, the just-finished segment's own end still counts. */
  private isCurrent(sessionId: string): boolean {
    const session = this.session;
    return session === null || session.sessionId === sessionId;
  }

  private listener(): speechRecognizer.RecognitionListener {
    return {
      onStart: (_sessionId: string, _eventMessage: string): void => {},
      onEvent: (sessionId: string, eventCode: number, _eventMessage: string): void => {
        if (!this.isCurrent(sessionId)) {
          return;
        }
        // 1 is the speech starting, 3 the speech ending.
        if (eventCode === 1) {
          this.events?.speechStart();
        } else if (eventCode === 3) {
          this.events?.speechEnd();
        }
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (!this.isCurrent(sessionId)) {
          return;
        }
        if (this.events !== null) {
          const event: DictationResult = { isFinal: result.isFinal, transcript: result.result };
          this.events.result(event);
        }
      },
      onComplete: (sessionId: string, _eventMessage: string): void => {
        if (!this.isCurrent(sessionId)) {
          return;
        }
        this.session = null;
        this.events?.end();
      },
      onError: (sessionId: string, errorCode: number, _errorMessage: string): void => {
        if (!this.isCurrent(sessionId)) {
          return;
        }
        // The engine's own codes are internal service trouble, which a restart may clear.
        const event: DictationError = { error: errorCode === 1002200006 ? 'busy' : 'unknown' };
        this.session = null;
        this.events?.error(event);
        this.events?.end();
      },
    };
  }

  private async openMicrophone(): Promise<void> {
    if (this.mic !== null || this.session === null) {
      return;
    }
    const factory = this.micFactory;
    let mic: CaptureMic | null = null;
    try {
      mic = factory !== null ? await factory() : await openCapturer();
    } catch (err) {
      mic = null;
    }
    if (mic === null) {
      const failure: DictationError = { error: 'audio-capture' };
      this.events?.error(failure);
      return;
    }
    const opened: CaptureMic = mic;
    try {
      opened.onFrames((buffer: ArrayBuffer): void => {
        this.heard(buffer);
      });
      await opened.start();
    } catch (err) {
      const failure: DictationError = { error: 'audio-capture' };
      this.events?.error(failure);
      void opened.release().catch((): void => undefined);
      return;
    }
    if (this.session === null) {
      // The session ended while the microphone was opening.
      void opened.stop().then((): Promise<void> => opened.release()).catch((): void => undefined);
      return;
    }
    this.mic = opened;
  }

  /** One microphone buffer: level out, frames to the engine in. */
  private heard(buffer: ArrayBuffer): void {
    const session = this.session;
    const bytes = new Uint8Array(buffer);
    if (this.followsLevel) {
      this.levelOut(pcmLevel(bytes));
    }
    if (session === null || this.engine === null) {
      return;
    }
    for (let index = 0; index < bytes.byteLength; index += 1) {
      this.carry.push(bytes[index] ?? 0);
    }
    while (this.carry.length >= FRAME_BYTES && this.session === session) {
      const frame = new Uint8Array(FRAME_BYTES);
      for (let index = 0; index < FRAME_BYTES; index += 1) {
        frame[index] = this.carry[index] ?? 0;
      }
      this.carry.splice(0, FRAME_BYTES);
      this.feed(session, frame);
    }
  }

  private feed(session: LiveSession, frame: Uint8Array): void {
    const engine = this.engine;
    if (engine === null || this.session !== session) {
      return;
    }
    try {
      engine.writeAudio(session.sessionId, frame);
      session.fed += frame.byteLength;
    } catch (err) {
      // The engine's audio cap (1002200003): finish the session, whose end restarts it.
      if (session.fed >= SESSION_AUDIO_MS * 32 - FRAME_BYTES) {
        this.closeSession(session);
      }
      // A dropped frame only shortens the turn's tail.
    }
  }

  private closeSession(session: LiveSession): void {
    const engine = this.engine;
    this.session = null;
    this.carry = [];
    try {
      engine?.finish(session.sessionId);
    } catch (err) {
      // Already complete: the engine's own end event ends the session for us.
    }
  }
}

export const deviceRecognizer: DeviceRecognizer = new DeviceRecognizer();
