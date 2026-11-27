// M7 review round 2: the dictation lifecycles the state-machine replay alone does not cover —
// the composer controller's send semantics (a send during recording finishes the session and
// keeps its words; a send while still preparing drops the setup), backgrounding ending every
// open session, the device recognizer closing its microphone when listening ends while a
// rotating segment keeps it, late callbacks from an old engine segment leaving the running one
// alone, and the meter reading S16LE samples as signed. The recognizer behind the composer is
// injected as the dictation replay does; the recognizer's own engine and microphone are scripted
// hardware through setHardware.
//
// Review round 3 (the recognizer's asynchronous lifecycle): on the device path a send waits for
// the engine's own final words instead of cancelling the segment out from under them, a
// segment's callbacks stop counting once a later one left (between two segments as well), a
// microphone is released whatever its stop did, and one opened for a segment that ended
// meanwhile is released rather than adopted by the next. The composer runs over the real
// recognizer on scripted hardware here, so its send is followed through the engine's own finish.
//
// Review round 4: a microphone let go of with its segment may still deliver frames it had queued,
// and none of them may reach the segment that runs after it.
import { afterEach, describe, expect, it } from '@ohos/hypium';
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import { FINISH_GRACE_MS } from '../../../main/ets/voice/dictation';
import * as dictationPort from '../../../main/ets/voice/dictation';
import type { DictationError, DictationResult, RecognizerEvents } from '../../../main/ets/voice/dictation';
import { DeviceRecognizer, recognitionLanguage } from '../../../main/ets/voice/device-recognizer';
import type { RecognizerEngine } from '../../../main/ets/voice/device-recognizer';
import type { CaptureMic } from '../../../main/ets/voice/microphone';
import { pcmLevel } from '../../../main/ets/voice/voice-clip';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import { ComposerDictation, stopAllComposerDictation } from '../../../main/ets/features/chat/composer-dictation';

/** Lets the microtask chain behind a call finish before the next assertion. */
const settle = (): Promise<void> => new Promise<void>((resolve: () => void): void => {
  setTimeout(resolve, 10);
});

/** Up to five seconds for `condition`, as the other device suites wait. */
async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 25);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

/** The recognizer the composer's device path listens through, scripted. */
class ScriptedRecognizer implements dictationPort.SpeechRecognizer {
  calls: string[] = [];
  hears: RecognizerEvents | null = null;
  /** Resolved once listen is installed; the test waits on it to know the session is live. */
  waitListen: (() => void) | null = null;

  load = (): Promise<void> => Promise.resolve();

  start = (_options: dictationPort.RecognizerStartOptions): void => {
    this.calls.push('start');
  };

  abort = (): void => {
    this.calls.push('abort');
  };

  isRecognitionAvailable = (): boolean => true;

  requestPermissions = (): Promise<boolean> => Promise.resolve(true);

  listen = (events: RecognizerEvents): (() => void) => {
    this.hears = events;
    this.calls.push('listen');
    if (this.waitListen !== null) {
      this.waitListen();
      this.waitListen = null;
    }
    return (): void => {
      if (this.hears === events) {
        this.hears = null;
      }
      this.calls.push('off');
    };
  };

  hear(text: string, isFinal: boolean): void {
    const event: DictationResult = { isFinal: isFinal, transcript: text };
    this.hears?.result(event);
  }
}

/** The device voice's choice, as a scripted store answers it. */
function deviceVoice(on: string): void {
  deviceVoicePort.setDeviceVoiceStore({
    get: async (_key: string): Promise<string | null> => on,
    put: async (_key: string, _value: string): Promise<void> => undefined,
  });
}

/** A controller over the device path, with the device voice on and a scripted recognizer. */
function deviceController(on: string, fake: ScriptedRecognizer, words: string[]): Promise<ComposerDictation> {
  deviceVoice(on);
  dictationPort.setSpeechRecognizer(fake);
  const controller = new ComposerDictation(
    (_message: string, _openVoice: boolean): void => undefined,
    (text: string, _final: boolean): void => {
      words.push(text);
    },
  );
  return new Promise<ComposerDictation>((resolve: (value: ComposerDictation) => void): void => {
    fake.waitListen = (): void => {
      resolve(controller);
    };
    controller.toggle();
  });
}

/** The scripted engine the device recognizer runs on. */
class FakeEngine implements RecognizerEngine {
  calls: string[] = [];
  sessionIds: string[] = [];
  /** For each frame written, the byte values it holds: a frame must hold its own microphone's. */
  tones: number[][] = [];
  listener: speechRecognizer.RecognitionListener | null = null;
  /** Called when a segment starts listening; a test waits on it to know the engine is live. */
  onStarted: ((sessionId: string) => void) | null = null;
  /** While set, finishing a segment throws, as the kit documents it may. The device engine
   *  reports a refusal as an error callback instead; a case scripts that by hand. */
  refusesFinish: boolean = false;

  setListener = (listener: speechRecognizer.RecognitionListener): void => {
    this.listener = listener;
  };

  startListening = (params: speechRecognizer.StartParams): void => {
    this.sessionIds.push(params.sessionId);
    this.calls.push(`start ${params.sessionId}`);
    this.onStarted?.(params.sessionId);
  };

  writeAudio = (sessionId: string, audio: Uint8Array): void => {
    this.calls.push(`write ${sessionId}`);
    const tones: number[] = [];
    for (let index = 0; index < audio.byteLength; index += 1) {
      const tone = audio[index] ?? -1;
      if (!tones.includes(tone)) {
        tones.push(tone);
      }
    }
    this.tones.push(tones);
  };

  finish = (sessionId: string): void => {
    this.calls.push(`finish ${sessionId}`);
    if (this.refusesFinish) {
      throw new Error('Finish recognition failed');
    }
  };

  cancel = (sessionId: string): void => {
    this.calls.push(`cancel ${sessionId}`);
  };

  shutdown = (): void => {
    this.calls.push('shutdown');
  };

  listLanguages = (_params: speechRecognizer.LanguageQuery): Promise<Array<string>> =>
    Promise.resolve([recognitionLanguage()]);
}

/** The scripted microphone the device recognizer records from. */
class FakeMic implements CaptureMic {
  calls: string[] = [];
  opens = 0;
  frames: ((buffer: ArrayBuffer) => void) | null = null;
  /** While set, stop rejects, as a capturer that is not running answers. */
  stopFails: boolean = false;
  /** While set, start resolves only when the test calls `letStart`. */
  holdsStart: boolean = false;
  letStart: (() => void) | null = null;

  onFrames = (frames: (buffer: ArrayBuffer) => void): void => {
    this.frames = frames;
  };

  start = (): Promise<void> => {
    if (!this.holdsStart) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      this.letStart = resolve;
    });
  };

  stop = (): Promise<void> => {
    this.calls.push('stop');
    return this.stopFails ? Promise.reject(new Error('The capturer is not running')) : Promise.resolve();
  };

  release = (): Promise<void> => {
    this.calls.push('release');
    return Promise.resolve();
  };
}

/** The recognizer's events, logged as they arrive. */
function recordEvents(log: string[]): RecognizerEvents {
  return {
    result: (event: DictationResult): void => {
      log.push(`result ${event.isFinal} ${event.transcript}`);
    },
    end: (): void => {
      log.push('end');
    },
    error: (event: DictationError): void => {
      log.push(`error ${event.error}`);
    },
    speechStart: (): void => {
      log.push('speech-start');
    },
    speechEnd: (): void => {
      log.push('speech-end');
    },
    level: (value: number): void => {
      log.push(`level ${value}`);
    },
  };
}

/** A microphone buffer that holds one byte value throughout. */
function filled(tone: number, size: number): ArrayBuffer {
  const bytes = new Uint8Array(size);
  bytes.fill(tone);
  return bytes.buffer as ArrayBuffer;
}

/** One scripted-hardware run: the recognizer, its engine, its microphone, the event log. */
class ScriptedRun {
  recognizer: DeviceRecognizer;
  engine: FakeEngine = new FakeEngine();
  mic: FakeMic = new FakeMic();
  events: string[] = [];
  off: (() => void) | null = null;
  /** Set before prepare: the microphone answers only when the test hands one over. */
  late: boolean = false;
  /** The recognizer's open microphone requests, oldest first, while `late` is set. */
  asks: Array<(mic: CaptureMic | null) => void> = [];

  constructor(recognizer: DeviceRecognizer = new DeviceRecognizer()) {
    this.recognizer = recognizer;
  }

  /** The engine is ready; nothing listens yet. */
  async prepare(): Promise<void> {
    const engine = this.engine;
    const mic = this.mic;
    const asks = this.asks;
    const late = this.late;
    this.recognizer.setHardware(
      (): Promise<RecognizerEngine | null> => Promise.resolve(engine),
      (): Promise<CaptureMic | null> => {
        mic.opens += 1;
        if (late) {
          return new Promise<CaptureMic | null>((give: (next: CaptureMic | null) => void): void => {
            asks.push(give);
          });
        }
        return Promise.resolve(mic);
      },
    );
    await this.recognizer.load();
    expect(this.recognizer.isRecognitionAvailable()).assertTrue();
  }

  async begin(): Promise<void> {
    await this.prepare();
    this.listen();
    this.startAgain();
    await settle();
  }

  listen(): void {
    this.off = this.recognizer.listen(recordEvents(this.events));
  }

  startAgain(): void {
    this.recognizer.start({
      lang: recognitionLanguage(), interimResults: true, continuous: true, level: false,
    });
  }

  /** Answers the oldest microphone request with `mic`. */
  async handOver(mic: CaptureMic): Promise<void> {
    const give = this.asks.shift();
    if (give !== undefined) {
      give(mic);
    }
    await settle();
  }
}

/** The device recognizer with the microphone question answered, as a grant would. */
class GrantedRecognizer extends DeviceRecognizer {
  requestPermissions(): Promise<boolean> {
    return Promise.resolve(true);
  }
}

/** A controller over the real device recognizer on scripted hardware, resolved once the engine
 *  listens for it and its microphone is open. */
function hardwareController(run: ScriptedRun, words: string[]): Promise<ComposerDictation> {
  deviceVoice('1');
  dictationPort.setSpeechRecognizer(run.recognizer);
  const controller = new ComposerDictation(
    (_message: string, _openVoice: boolean): void => undefined,
    (text: string, _final: boolean): void => {
      words.push(text);
    },
  );
  const started = new Promise<void>((resolve: () => void): void => {
    run.engine.onStarted = (): void => {
      run.engine.onStarted = null;
      resolve();
    };
  });
  controller.toggle();
  return started.then(async (): Promise<ComposerDictation> => {
    await settle();
    return controller;
  });
}

export default function dictationLifecycleTest(): void {
  describe('DictationLifecycle', () => {
    afterEach((): void => {
      stopAllComposerDictation();
      dictationPort.setSpeechRecognizer(null);
      dictationPort.stop();
      deviceVoicePort.setDeviceVoiceStore(null);
    });

    it('send_during_device_listening_finishes_and_keeps_the_words', 0, async () => {
      const fake = new ScriptedRecognizer();
      const words: string[] = [];
      const controller = await deviceController('1', fake, words);
      expect(controller.status).assertEqual('listening');
      fake.hear('你好世界', false);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // The send finished the session through its own finish instead of cancelling it, so the
      // words the microphone had already heard were delivered and the send ran after they
      // landed.
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好世界', '你好世界']);
    });

    it('cancel_during_device_listening_drops_the_words', 0, async () => {
      const fake = new ScriptedRecognizer();
      const words: string[] = [];
      const controller = await deviceController('1', fake, words);
      fake.hear('早安', false);
      controller.cancel();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['早安']);
      // Nothing the recognizer says after the cancel lands anywhere.
      fake.hear('晚安', true);
      await settle();
      expect(words).assertDeepEquals(['早安']);
      expect(fake.calls.includes('abort')).assertTrue();
    });

    it('send_while_still_preparing_drops_the_setup_and_sends_at_once', 0, async () => {
      const fake = new ScriptedRecognizer();
      const words: string[] = [];
      deviceVoice('1');
      dictationPort.setSpeechRecognizer(fake);
      const controller = new ComposerDictation(
        (_message: string, _openVoice: boolean): void => undefined,
        (text: string, _final: boolean): void => {
          words.push(text);
        },
      );
      controller.toggle();
      // The finish runs before the plan's awaits have turned, while the microphone is not open:
      // there are no words to keep, so the send runs at once.
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      await settle();
      // The late start found the session gone and never reached the recognizer.
      expect(fake.calls.includes('listen')).assertFalse();
      expect(fake.calls.includes('start')).assertFalse();
      expect(words).assertDeepEquals([]);
    });

    it('backgrounding_ends_every_open_session', 0, async () => {
      const fake = new ScriptedRecognizer();
      const words: string[] = [];
      const controller = await deviceController('1', fake, words);
      fake.hear('晚上好', false);
      stopAllComposerDictation();
      expect(controller.status).assertEqual('idle');
      // The recognizer was stopped with the session, and its later words reach no one.
      expect(fake.calls.includes('off')).assertTrue();
      fake.hear('再见', true);
      await settle();
      expect(words).assertDeepEquals(['晚上好']);
    });

    it('send_during_device_listening_waits_for_the_engine_final_then_sends', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      expect(words).assertDeepEquals(['你好']);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // The send asked the engine to finish the segment, keeping its words, and waits for them
      // instead of cancelling the segment and sending without its last words.
      expect(run.engine.calls.includes(`finish ${segment}`)).assertTrue();
      expect(run.engine.calls.includes(`cancel ${segment}`)).assertFalse();
      expect(sent).assertFalse();
      expect(controller.status).assertEqual('listening');
      // The engine's final words arrive late, then its end: only now do they land and the send run.
      const final: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: '你好世界' };
      run.engine.listener?.onResult(segment, final);
      expect(sent).assertFalse();
      run.engine.listener?.onComplete(segment, 'done');
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      // The final words reached the draft as the recognizer reported them, then with the delivery.
      expect(words).assertDeepEquals(['你好', '你好世界', '你好世界']);
      await settle();
      // Listening ended with the send: the microphone went with it.
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('send_between_two_segments_ends_at_once_without_cancelling', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      // The engine ended the segment on its own (its 60 s cap): the state machine owes a restart,
      // so no segment runs now.
      run.engine.listener?.onComplete(segment, 'done');
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // Nothing is left to wait for: the words heard were delivered and the send ran at once,
      // and the finished segment was not cancelled behind its back.
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好', '你好']);
      expect(run.engine.calls.includes(`cancel ${segment}`)).assertFalse();
      await settle();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('an_engine_error_during_the_finish_does_not_cut_off_the_final_words', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // The device's engine answers a finish with an error first, then the segment's last words,
      // then its completion. The error is no end: the words that follow it still land.
      run.engine.listener?.onError(segment, 1002200010, 'Write audio failed');
      expect(sent).assertFalse();
      expect(controller.status).assertEqual('listening');
      const final: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: '你好世界' };
      run.engine.listener?.onResult(segment, final);
      expect(sent).assertFalse();
      run.engine.listener?.onComplete(segment, 'done');
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好', '你好世界', '你好世界']);
      expect(run.engine.calls.includes(`cancel ${segment}`)).assertFalse();
    });

    it('a_finish_the_engine_refuses_still_sends', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      expect(run.engine.calls.includes(`finish ${segment}`)).assertTrue();
      // The engine answers a finish it will not do with its refusal and nothing else: no last
      // words and no completion follow, so the send does not wait for them.
      run.engine.listener?.onError(segment, 1002200004, 'Finish recognition failed.');
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好', '你好']);
      await settle();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('a_finish_the_engine_throws_on_still_sends', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      run.engine.refusesFinish = true;
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // Same for a finish the engine throws back: nothing answers it, so the send runs at once.
      expect(run.engine.calls.includes(`finish ${segment}`)).assertTrue();
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好', '你好']);
      await settle();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('a_finish_the_engine_never_answers_still_sends_what_was_heard', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      expect(run.engine.calls.includes(`finish ${segment}`)).assertTrue();
      // A wedged engine answers a finish with nothing at all: no last words, no refusal, no
      // completion. The send waits FINISH_GRACE_MS for them, then goes out with what was heard
      // instead of hanging on the silence limit.
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, FINISH_GRACE_MS / 2);
      });
      expect(sent).assertFalse();
      expect(controller.status).assertEqual('listening');
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, FINISH_GRACE_MS);
      });
      expect(sent).assertTrue();
      expect(controller.status).assertEqual('idle');
      expect(words).assertDeepEquals(['你好', '你好']);
      await settle();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('a_finish_the_engine_never_answers_cancels_the_segment_it_still_owes', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const controller = await hardwareController(run, []);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      const cancelled = (): boolean => run.engine.calls.includes(`cancel ${segment}`);
      controller.finish((): void => undefined);
      // While the turn waits for the engine, the segment is left to finish: it is not cancelled
      // out from under the words it may still report.
      expect(cancelled()).assertFalse();
      // Once the grace ends the turn, the engine is told to drop that segment, so the next
      // listen does not find it still inside the finish it never answered.
      await waitFor(cancelled, 'the cancelled segment');
    });

    it('leaving_while_the_engine_finishes_drops_the_late_words', 0, async () => {
      const run = new ScriptedRun(new GrantedRecognizer());
      await run.prepare();
      const words: string[] = [];
      const controller = await hardwareController(run, words);
      const segment = run.engine.sessionIds[0] ?? '';
      const interim: speechRecognizer.SpeechRecognitionResult = { isFinal: false, isLast: false, result: '你好' };
      run.engine.listener?.onResult(segment, interim);
      let sent = false;
      controller.finish((): void => {
        sent = true;
      });
      // The app leaves the foreground before the engine's final words arrive.
      stopAllComposerDictation();
      expect(controller.status).assertEqual('idle');
      const final: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: '你好世界' };
      run.engine.listener?.onResult(segment, final);
      run.engine.listener?.onComplete(segment, 'done');
      await settle();
      // The microphone went with the session, and the late words reached no one: nothing sends.
      expect(sent).assertFalse();
      expect(words).assertDeepEquals(['你好']);
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });
  });

  describe('DictationHardware', () => {
    it('listening_ending_stops_and_releases_the_microphone', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      run.mic.frames?.(new ArrayBuffer(1_280));
      // The frame reached the engine's session.
      expect(run.engine.calls.includes(`write ${first}`)).assertTrue();
      // Leaving the thread (the uninstall the dictation stop runs) ends the capture: the
      // engine session is cancelled and the microphone stops and is released.
      run.off?.();
      await settle();
      expect(run.engine.calls.includes(`cancel ${first}`)).assertTrue();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('a_rotating_segment_keeps_the_microphone_open', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      // The engine's own cap ends the segment; that end is a rotation, not the end of listening.
      run.engine.listener?.onComplete(first, 'done');
      expect(run.events).assertDeepEquals(['end']);
      run.startAgain();
      await settle();
      // The same microphone kept recording through the next segment.
      expect(run.mic.opens).assertEqual(1);
      expect(run.mic.calls).assertDeepEquals([]);
      const second = run.engine.sessionIds[1] ?? '';
      run.mic.frames?.(new ArrayBuffer(1_280));
      expect(run.engine.calls.includes(`write ${second}`)).assertTrue();
    });

    it('old_segment_callbacks_after_the_next_segment_starts_are_dropped', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      run.engine.listener?.onComplete(first, 'done');
      run.startAgain();
      await settle();
      const second = run.engine.sessionIds[1] ?? '';
      const before = run.events.length;
      const stale: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: 'stale' };
      run.engine.listener?.onResult(first, stale);
      run.engine.listener?.onComplete(first, 'late');
      run.engine.listener?.onError(first, 1, 'late');
      await settle();
      // None of the old segment's late callbacks reached the listener, and the old completion
      // did not clear the running session: the running segment still takes its frames.
      expect(run.events.length).assertEqual(before);
      run.mic.frames?.(new ArrayBuffer(1_280));
      expect(run.engine.calls.includes(`write ${second}`)).assertTrue();
      const fresh: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: 'fresh' };
      run.engine.listener?.onResult(second, fresh);
      expect(run.events.includes('result true fresh')).assertTrue();
    });

    it('an_older_segments_callbacks_are_dropped_between_two_segments', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      run.engine.listener?.onComplete(first, 'done');
      run.startAgain();
      await settle();
      const second = run.engine.sessionIds[1] ?? '';
      // The second segment ended as well: no segment runs until the state machine restarts.
      run.engine.listener?.onComplete(second, 'done');
      expect(run.events).assertDeepEquals(['end', 'end']);
      const stale: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: 'stale' };
      run.engine.listener?.onResult(first, stale);
      run.engine.listener?.onError(first, 1, 'late');
      run.engine.listener?.onComplete(first, 'late');
      // The first segment was over before the second one ran. Between two segments only the one
      // that left last counts, so the older one's late word, error and end reached no one.
      expect(run.events).assertDeepEquals(['end', 'end']);
    });

    it('the_end_a_cancelled_segment_still_reports_reaches_the_listener', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      // The state machine's quiet restart cancels the segment and waits for its end to restart.
      run.recognizer.abort();
      await settle();
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
      // The device's engine answers a cancel with an error and then the completion: one end, at
      // the completion, so the restart it triggers is not armed twice.
      run.engine.listener?.onError(first, 1002200010, 'cancelled');
      expect(run.events).assertDeepEquals(['error unknown']);
      run.engine.listener?.onComplete(first, 'cancelled');
      expect(run.events).assertDeepEquals(['error unknown', 'end']);
    });

    it('a_completed_segment_is_not_ended_twice', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      // The engine ends a segment itself at its 60 s cap and answers the next frame written
      // into it with an error. The segment is over: that is no second end.
      run.engine.listener?.onComplete(first, 'done');
      run.engine.listener?.onError(first, 1002200010, 'Write audio failed');
      run.engine.listener?.onComplete(first, 'again');
      expect(run.events).assertDeepEquals(['end']);
    });

    it('the_words_after_an_engine_error_still_reach_the_listener', 0, async () => {
      const run = new ScriptedRun();
      await run.begin();
      const first = run.engine.sessionIds[0] ?? '';
      // The engine reports an error first and the segment's last words after it, then completes.
      run.engine.listener?.onError(first, 1002200010, 'Write audio failed');
      const tail: speechRecognizer.SpeechRecognitionResult = { isFinal: true, isLast: true, result: 'tail' };
      run.engine.listener?.onResult(first, tail);
      run.engine.listener?.onComplete(first, 'done');
      // The error ended the segment and its completion did not end it again; the last words it
      // reported in between still reached the listener.
      expect(run.events).assertDeepEquals(['error unknown', 'end', 'result true tail']);
    });

    it('a_microphone_whose_stop_fails_is_still_released', 0, async () => {
      const run = new ScriptedRun();
      run.mic.stopFails = true;
      await run.begin();
      run.off?.();
      await settle();
      // The stop's failure is not the microphone's to keep: it is released all the same, so no
      // capture outlives the listening that asked for it.
      expect(run.mic.calls).assertDeepEquals(['stop', 'release']);
    });

    it('a_microphone_created_for_a_cancelled_segment_is_released_not_adopted', 0, async () => {
      const run = new ScriptedRun();
      run.late = true;
      await run.prepare();
      run.listen();
      run.startAgain();
      // Cancelled before its microphone arrives, then reopened at once: the next segment asks
      // for a microphone of its own.
      run.recognizer.abort();
      run.startAgain();
      const stale = new FakeMic();
      const live = new FakeMic();
      await run.handOver(stale);
      await run.handOver(live);
      await settle();
      // The microphone created for the cancelled segment was never started nor adopted by the
      // next one: released at once, so only the reopened segment's is open and feeds it.
      expect(stale.calls).assertDeepEquals(['release']);
      expect(stale.frames).assertNull();
      expect(live.calls).assertDeepEquals([]);
      const second = run.engine.sessionIds[1] ?? '';
      live.frames?.(new ArrayBuffer(1_280));
      expect(run.engine.calls.includes(`write ${second}`)).assertTrue();
    });

    it('a_microphone_that_started_for_a_cancelled_segment_is_stopped_and_released', 0, async () => {
      const run = new ScriptedRun();
      run.late = true;
      await run.prepare();
      run.listen();
      run.startAgain();
      const stale = new FakeMic();
      stale.holdsStart = true;
      await run.handOver(stale);
      // Cancelled while its microphone is still starting, then reopened at once.
      run.recognizer.abort();
      run.startAgain();
      const live = new FakeMic();
      await run.handOver(live);
      stale.letStart?.();
      await settle();
      await settle();
      // The microphone that finished starting for the cancelled segment did not become the next
      // segment's: it was stopped and released, and only the next segment's own stayed open.
      expect(stale.calls).assertDeepEquals(['stop', 'release']);
      expect(live.calls).assertDeepEquals([]);
      const second = run.engine.sessionIds[1] ?? '';
      live.frames?.(new ArrayBuffer(1_280));
      expect(run.engine.calls.includes(`write ${second}`)).assertTrue();
    });

    it('a_frame_the_old_microphone_delivers_after_its_cancel_reaches_no_segment', 0, async () => {
      const run = new ScriptedRun();
      run.late = true;
      await run.prepare();
      run.listen();
      run.startAgain();
      const old = new FakeMic();
      await run.handOver(old);
      old.frames?.(filled(0x11, 1_280));
      expect(run.engine.tones).assertDeepEquals([[0x11]]);
      // The first segment is cancelled and the next one starts at once, with a microphone of its own.
      run.recognizer.abort();
      run.startAgain();
      const live = new FakeMic();
      await run.handOver(live);
      const second = run.engine.sessionIds[1] ?? '';
      // The cancelled segment's microphone still hands over what it had queued while the next
      // segment runs: half a frame, then a whole one.
      old.frames?.(filled(0xAA, 640));
      old.frames?.(filled(0xAA, 1_280));
      // None of it was written into the next segment.
      expect(run.engine.calls.includes(`write ${second}`)).assertFalse();
      // The next segment's own microphone feeds it, and its first frame holds that microphone's
      // bytes alone: nothing of the old one sits in front of them.
      live.frames?.(filled(0x55, 1_280));
      expect(run.engine.tones).assertDeepEquals([[0x11], [0x55]]);
    });
  });

  describe('DictationLevel', () => {
    it('the_meter_reads_s16le_samples_signed', 0, () => {
      expect(pcmLevel(new Uint8Array(64))).assertEqual(0);
      // A negative half-wave and a positive one of the same size read the same loudness; read
      // unsigned, the negative one is a near-full-scale value instead.
      expect(pcmLevel(new Uint8Array([0x01, 0xFF]))).assertEqual(pcmLevel(new Uint8Array([0xFF, 0x00])));
      expect(pcmLevel(new Uint8Array([0x00, 0x80, 0xFF, 0x7F])) > 0.99).assertTrue();
    });
  });
}
