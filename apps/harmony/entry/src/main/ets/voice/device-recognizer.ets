// The device's own recognizer (M7): the CoreSpeechKit speech recognizer and the AudioCapturer
// behind dictation's SpeechRecognizer. One engine answers every session while the app is in
// front; its language is the recognition locale (the device's language, the app's when the
// speaker's is not a speech locale), and it is available only when the engine itself lists that
// language. The microphone answers 16 kHz mono S16LE PCM, handed over in the 1280-byte frames
// the engine takes; the engine's own 60-second cap reads as a session that ended, which the
// state machine restarts as it does every natural end — and that restart keeps the microphone.
// Listening ending for real stops and releases the microphone, so no capture outlives the
// dictation that asked for it.
//
// One segment (one engine session) is in one of five states; the table with every entry's rule
// is in docs/m7-notes.md:
//   opening    the engine listens; the segment's microphone is still being opened
//   recording  the microphone feeds the engine
//   finishing  the engine was asked to finish or cancel the segment; its last words and its
//              end are awaited
//   closing    the engine ended the segment; the state machine still owes a restart or a stop
//   idle       nothing is left to count
// Whatever arrives is checked against the segment it belongs to before it acts: an engine
// callback by the session it names, an opening microphone by the segment that asked for it, a
// microphone's frames by the microphone that is still the live one. So a late callback from an
// older segment, a microphone opened for one that ended meanwhile, or a frame an old microphone
// still delivers after it was let go of, cannot touch the one running now, and a segment's end is
// reported once.
// Nothing loads until the first listen, behind the capability check, and both the engine and the
// microphone are released when the app leaves the foreground. Tests hand a scripted engine and
// microphone in through setHardware.
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import type { audio } from '@kit.AudioKit';
import { i18n } from '@kit.LocalizationKit';
import type { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { recognitionLocaleTag } from './speech-locale';
import { currentLocale } from '../i18n/i18n';
import { paceLevel, pcmLevel } from './voice-clip';
import type { DictationError, DictationResult, RecognizerEvents, RecognizerStartOptions } from './dictation';
import type { SpeechRecognizer } from './dictation';
import { openCaptureMicrophone, releaseMicrophone, requestMicrophone, stopMicrophone } from './microphone';
import type { CaptureMic } from './microphone';

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

/** The frame the engine takes: 640 or 1280 bytes of 16 kHz mono S16LE PCM. */
const FRAME_BYTES = 1_280;
/** The engine accepts at most 60,000 ms of audio per session. */
const SESSION_AUDIO_MS = 60_000;
/** The engine's answer to a finish it will not do: no last words and no completion follow it. */
const FINISH_REFUSED = 1002200004;

/** The recognition locale the composer dictates in: the device's language, the app's when the
 *  speaker's is not a speech locale. */
export function recognitionLanguage(): string {
  return recognitionLocaleTag(currentLocale(), i18n.System.getSystemLanguage());
}

/** One segment: the engine's session id, and how much audio it was fed. */
interface LiveSession {
  sessionId: string;
  fed: number;
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
  /** The microphone whose frames count: the one opened for the running segment, which a later
   *  segment rotating onto the same microphone keeps. A microphone let go of may still deliver
   *  what it has queued, and none of that may reach the segment that runs after it. */
  private capture: CaptureMic | null = null;
  private events: RecognizerEvents | null = null;
  /** The running segment (opening or recording): the engine is listening to it. */
  private session: LiveSession | null = null;
  /** The segment that left last. While none runs, a callback counts only when it names this
   *  one, and the next segment replaces it. */
  private closed: LiveSession | null = null;
  /** The engine still owes the end of the closed segment: it was asked to finish or cancel it,
   *  and reports its last words and its completion after. */
  private awaiting: boolean = false;
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
      // The recognizer answers as a device without the engine would.
      hilog.warn(0, 'Voice', 'Could not prepare the recognizer');
      this.available = false;
    }
  }

  private async createEngine(language: string): Promise<RecognizerEngine | null> {
    const api = await import('@hms.ai.speechRecognizer');
    try {
      return await api.default.createEngine({ language: language, online: 1 });
    } catch (err) {
      // A failed engine creation is no engine at all: the caller reads no availability.
      hilog.warn(0, 'Voice', 'Could not create the recognizer engine');
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
    this.reset();
    this.carry = [];
    try {
      engine.startListening({
        sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16_000, soundChannel: 1, sampleBit: 16 },
      });
    } catch (err) {
      // The engine did not start listening: no end will come from it for this segment.
      this.session = null;
      this.closed = session;
      this.carry = [];
      const failure: DictationError = { error: 'unknown' };
      this.events?.error(failure);
      return;
    }
    void this.openMicrophone(session);
  }

  /** Ends the running segment keeping what it heard: the engine is asked to finish, and its last
   *  words arrive through the events before its end does. Nothing running leaves nothing to wait
   *  for: the end is reported at once. */
  finish(): void {
    const session = this.session;
    if (session !== null) {
      this.closeSession(session);
      return;
    }
    if (!this.awaiting) {
      this.events?.end();
    }
  }

  /** Drops the segment: the one the engine still owes, running or being finished, is cancelled,
   *  and the microphone goes with it. A segment the engine already ended is left alone, so a
   *  finish that delivered its words is never cancelled behind them. */
  abort(): void {
    this.handOver();
    const owed = this.awaiting ? this.closed : null;
    if (owed !== null) {
      try {
        this.engine?.cancel(owed.sessionId);
      } catch (err) {
        hilog.warn(0, 'Voice', 'Could not cancel the recognition');
      }
    }
    // Listening ended here, not rotating into the next segment: the microphone goes with it.
    this.closeMicrophone();
  }

  /** Stops and releases the microphone; the next listen opens one of its own. */
  private closeMicrophone(): void {
    const mic = this.mic;
    this.mic = null;
    // From here nothing a microphone delivers counts: not the one let go of now, nor one still
    // being opened for the segment that just ended (it is stopped once it answers).
    this.capture = null;
    if (mic !== null) {
      void stopMicrophone(mic);
    }
  }

  listen(events: RecognizerEvents): () => void {
    this.events = events;
    this.levelOut = paceLevel((value: number): void => {
      this.events?.level(value);
    });
    return (): void => {
      this.abort();
      this.reset();
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
    this.reset();
    try {
      engine?.shutdown();
    } catch (err) {
      hilog.warn(0, 'Voice', 'Could not shut down the recognizer');
    }
  }

  /** A callback belongs to the segment it names: the one running, else the one that left last.
   *  Anything else was over before anything now. */
  private isCurrent(sessionId: string): boolean {
    const current = this.session ?? this.closed;
    return current !== null && current.sessionId === sessionId;
  }

  /** A segment is running, or the engine still owes one its end. */
  private endPending(): boolean {
    return this.session !== null || this.awaiting;
  }

  /** Nothing from before counts any more. */
  private reset(): void {
    this.closed = null;
    this.awaiting = false;
  }

  /** Stops writing to the running segment and leaves its end to the engine: no frame is written
   *  to it after this, and its own callbacks still count until it reports done. */
  private handOver(): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    this.session = null;
    this.closed = session;
    this.carry = [];
    this.awaiting = true;
  }

  /** The engine is done with a segment: nothing runs until the state machine starts the next one
   *  or stops, and this segment's end is not reported again. */
  private engineEnded(): void {
    if (this.session !== null) {
      this.closed = this.session;
      this.session = null;
      this.carry = [];
    }
    this.awaiting = false;
    this.events?.end();
  }

  /** Asks the engine to finish the segment and keep its words: they arrive through the listener,
   *  then its end. */
  private closeSession(session: LiveSession): void {
    this.handOver();
    try {
      this.engine?.finish(session.sessionId);
    } catch (err) {
      // The engine threw instead of answering: no last words and no end are coming from it.
      hilog.warn(0, 'Voice', 'Could not finish the recognition');
      this.engineEnded();
    }
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
        // A segment's last words may follow the error that ended it: they still count as long as
        // no later segment replaced it.
        if (!this.isCurrent(sessionId)) {
          return;
        }
        if (this.events !== null) {
          const event: DictationResult = { isFinal: result.isFinal, transcript: result.result };
          this.events.result(event);
        }
      },
      onComplete: (sessionId: string, _eventMessage: string): void => {
        // A completion that follows the error that already ended the segment is no second end.
        if (this.isCurrent(sessionId) && this.endPending()) {
          this.engineEnded();
        }
      },
      onError: (sessionId: string, errorCode: number, _errorMessage: string): void => {
        // An error for a segment that already ended, as a late write into one the engine capped,
        // says nothing new.
        if (!this.isCurrent(sessionId) || !this.endPending()) {
          return;
        }
        // The engine's own codes are internal service trouble, which a restart may clear.
        const event: DictationError = { error: errorCode === 1002200006 ? 'busy' : 'unknown' };
        this.events?.error(event);
        // A segment the engine was asked to finish or to cancel reports its last words and its
        // completion after such an error: they are waited for. Only a finish it refuses ends
        // without them.
        if (!this.awaiting || errorCode === FINISH_REFUSED) {
          this.engineEnded();
        }
      },
    };
  }

  /** Opens the microphone for `session`. Every wait is followed by the question whether that
   *  segment still runs: one that ended meanwhile takes no microphone, and the microphone opened
   *  for it is released rather than left open beside the next segment's. */
  private async openMicrophone(session: LiveSession): Promise<void> {
    if (this.mic !== null || this.session !== session) {
      return;
    }
    const factory = this.micFactory;
    let mic: CaptureMic | null = null;
    try {
      mic = factory !== null ? await factory() : await openCaptureMicrophone();
    } catch (err) {
      hilog.warn(0, 'Voice', 'Could not open the microphone');
    }
    const opened = mic;
    if (opened === null) {
      this.failCapture(session);
      return;
    }
    if (this.session !== session) {
      // Ended while the microphone was being created: it was never started.
      void releaseMicrophone(opened);
      return;
    }
    try {
      this.capture = opened;
      opened.onFrames((buffer: ArrayBuffer): void => {
        this.heard(opened, buffer);
      });
      await opened.start();
    } catch (err) {
      this.dropCapture(opened);
      hilog.warn(0, 'Voice', 'Could not start the microphone');
      void releaseMicrophone(opened);
      this.failCapture(session);
      return;
    }
    if (this.session !== session) {
      // The segment ended while the microphone was starting.
      this.dropCapture(opened);
      void stopMicrophone(opened);
      return;
    }
    this.mic = opened;
  }

  /** A microphone that will record for no one: its frames stop counting at once. */
  private dropCapture(mic: CaptureMic): void {
    if (this.capture === mic) {
      this.capture = null;
    }
  }

  /** The microphone cannot record, so the listening session ends on it: reported while the
   *  segment it was opened for still runs. */
  private failCapture(session: LiveSession): void {
    if (this.session === session) {
      const failure: DictationError = { error: 'audio-capture' };
      this.events?.error(failure);
    }
  }

  /** One microphone buffer: level out, frames to the engine in. Only the microphone whose frames
   *  count reaches the segment running now: what a microphone let go of still delivers is
   *  dropped, so none of it lands in the segment that came after it. */
  private heard(mic: CaptureMic, buffer: ArrayBuffer): void {
    if (this.capture !== mic) {
      return;
    }
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
      // The engine ends a segment itself at its 60 s cap; one that refuses the frame instead
      // (1002200003) is finished here, and that end restarts it.
      if (session.fed >= SESSION_AUDIO_MS * 32 - FRAME_BYTES) {
        this.closeSession(session);
      }
      // A dropped frame only shortens the turn's tail.
    }
  }
}

export const deviceRecognizer: DeviceRecognizer = new DeviceRecognizer();
