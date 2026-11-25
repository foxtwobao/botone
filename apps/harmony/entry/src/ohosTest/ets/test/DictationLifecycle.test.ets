// M7 review round 2: the dictation lifecycles the state-machine replay alone does not cover —
// the composer controller's send semantics (a send during recording finishes the session and
// keeps its words; a send while still preparing drops the setup), backgrounding ending every
// open session, the device recognizer closing its microphone when listening ends while a
// rotating segment keeps it, late callbacks from an old engine segment leaving the running one
// alone, and the meter reading S16LE samples as signed. The recognizer behind the composer is
// injected as the dictation replay does; the recognizer's own engine and microphone are scripted
// hardware through setHardware.
import { afterEach, describe, expect, it } from '@ohos/hypium';
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import * as dictationPort from '../../../main/ets/voice/dictation';
import type { DictationError, DictationResult, RecognizerEvents } from '../../../main/ets/voice/dictation';
import { DeviceRecognizer, recognitionLanguage } from '../../../main/ets/voice/device-recognizer';
import type { CaptureMic, RecognizerEngine } from '../../../main/ets/voice/device-recognizer';
import { pcmLevel } from '../../../main/ets/voice/voice-clip';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import { ComposerDictation, stopAllComposerDictation } from '../../../main/ets/features/chat/composer-dictation';

/** Lets the microtask chain behind a call finish before the next assertion. */
const settle = (): Promise<void> => new Promise<void>((resolve: () => void): void => {
  setTimeout(resolve, 10);
});

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

/** A controller over the device path, with the device voice on and a scripted recognizer. */
function deviceController(on: string, fake: ScriptedRecognizer, words: string[]): Promise<ComposerDictation> {
  deviceVoicePort.setDeviceVoiceStore({
    get: async (_key: string): Promise<string | null> => on,
    put: async (_key: string, _value: string): Promise<void> => undefined,
  });
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
  listener: speechRecognizer.RecognitionListener | null = null;

  setListener = (listener: speechRecognizer.RecognitionListener): void => {
    this.listener = listener;
  };

  startListening = (params: speechRecognizer.StartParams): void => {
    this.sessionIds.push(params.sessionId);
    this.calls.push(`start ${params.sessionId}`);
  };

  writeAudio = (sessionId: string, _audio: Uint8Array): void => {
    this.calls.push(`write ${sessionId}`);
  };

  finish = (sessionId: string): void => {
    this.calls.push(`finish ${sessionId}`);
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

  onFrames = (frames: (buffer: ArrayBuffer) => void): void => {
    this.frames = frames;
  };

  start = (): Promise<void> => Promise.resolve();

  stop = (): Promise<void> => {
    this.calls.push('stop');
    return Promise.resolve();
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

/** One scripted-hardware run: the recognizer, its engine, its microphone, the event log. */
class ScriptedRun {
  recognizer: DeviceRecognizer = new DeviceRecognizer();
  engine: FakeEngine = new FakeEngine();
  mic: FakeMic = new FakeMic();
  events: string[] = [];
  off: (() => void) | null = null;

  async begin(): Promise<void> {
    const engine = this.engine;
    const mic = this.mic;
    this.recognizer.setHardware(
      (): Promise<RecognizerEngine | null> => Promise.resolve(engine),
      (): Promise<CaptureMic | null> => {
        mic.opens += 1;
        return Promise.resolve(mic);
      },
    );
    await this.recognizer.load();
    expect(this.recognizer.isRecognitionAvailable()).assertTrue();
    this.off = this.recognizer.listen(recordEvents(this.events));
    this.startAgain();
    await settle();
  }

  startAgain(): void {
    this.recognizer.start({
      lang: recognitionLanguage(), interimResults: true, continuous: true, level: false,
    });
  }
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
      deviceVoicePort.setDeviceVoiceStore({
        get: async (_key: string): Promise<string | null> => '1',
        put: async (_key: string, _value: string): Promise<void> => undefined,
      });
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
