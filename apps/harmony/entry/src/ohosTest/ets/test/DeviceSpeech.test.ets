// M7 review round 4: the device synthesizer while its engine is being created. Creation takes a
// moment on the device, and a stop, a release (the app leaving the foreground) or a newer speech
// can land in it: the engine that arrives after any of them is shut down and never speaks.
import { describe, expect, it } from '@ohos/hypium';
import type { textToSpeech } from '@kit.CoreSpeechKit';
import { DeviceSpeech } from '../../../main/ets/voice/device-speech';
import type { EngineVoice, SpeechEngine } from '../../../main/ets/voice/device-speech';

/** Lets the microtask chain behind a call finish before the next assertion. */
const settle = (): Promise<void> => new Promise<void>((resolve: () => void): void => {
  setTimeout(resolve, 10);
});

/** Up to two seconds for `condition`. */
async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (condition()) {
      return;
    }
    await settle();
  }
  throw new Error(`timed out waiting for ${label}`);
}

/** The one voice every scripted engine is created for. */
const VOICE: EngineVoice = { language: 'en-US', person: 0 };

/** A scripted engine: what the synthesizer asked of it, in order. */
class FakeEngine implements SpeechEngine {
  calls: string[] = [];
  listener: textToSpeech.SpeakListener | null = null;

  setListener = (listener: textToSpeech.SpeakListener): void => {
    this.calls.push('listener');
    this.listener = listener;
  };

  speak = (text: string, _params: textToSpeech.SpeakParams): void => {
    this.calls.push(`speak ${text}`);
  };

  stop = (): void => {
    this.calls.push('stop');
  };

  pause = (): void => {
    this.calls.push('pause');
  };

  resume = (): void => {
    this.calls.push('resume');
  };

  shutdown = (): void => {
    this.calls.push('shutdown');
  };
}

/** A synthesizer whose engine creations answer only when the test hands an engine over. */
class HeldCreations {
  speech: DeviceSpeech = new DeviceSpeech();
  private asks: Array<(engine: SpeechEngine) => void> = [];

  constructor() {
    const asks = this.asks;
    this.speech.setEngineFactory((): Promise<SpeechEngine> => {
      return new Promise<SpeechEngine>((give: (engine: SpeechEngine) => void): void => {
        asks.push(give);
      });
    });
  }

  /** How many engines the synthesizer has asked for so far. */
  askedFor(): number {
    return this.asks.length;
  }

  /** Waits until the synthesizer has asked for `count` engines. */
  asked(count: number): Promise<void> {
    return waitFor((): boolean => this.asks.length >= count, `${count} engine creation(s)`);
  }

  /** Answers the oldest creation with `engine`. */
  create(engine: SpeechEngine): void {
    const give = this.asks.shift();
    give?.(engine);
  }
}

export default function deviceSpeechTest(): void {
  describe('DeviceSpeechLifecycle', () => {
    it('a_stop_while_the_engine_is_being_created_shuts_the_late_engine_down', 0, async () => {
      const run = new HeldCreations();
      const speaking = run.speech.speak('Hello there.', VOICE, run.speech.ticket());
      await run.asked(1);
      // Stop: the playback bar clears while the engine is still being created.
      run.speech.stop();
      const late = new FakeEngine();
      run.create(late);
      await settle();
      await settle();
      // The engine that arrived after the stop was shut down at once: it took no listener and
      // said nothing.
      expect(late.calls).assertDeepEquals(['shutdown']);
      await speaking;
    });

    it('a_release_while_the_engine_is_being_created_shuts_the_late_engine_down', 0, async () => {
      const run = new HeldCreations();
      const speaking = run.speech.speak('Hello there.', VOICE, run.speech.ticket());
      await run.asked(1);
      // The app left the foreground: its engines are released while this one is being created.
      run.speech.release();
      const late = new FakeEngine();
      run.create(late);
      await settle();
      await settle();
      // Nothing starts speaking once the app is gone: the late engine is shut down, not used.
      expect(late.calls).assertDeepEquals(['shutdown']);
      await speaking;
    });

    it('a_stop_that_lands_before_the_engine_is_asked_for_leaves_the_speech_without_one', 0, async () => {
      const run = new HeldCreations();
      // The ticket is taken before the speech's own last wait (the voice listing), and the stop
      // lands inside it.
      const ticket = run.speech.ticket();
      run.speech.stop();
      let spoken = false;
      void run.speech.speak('Hello there.', VOICE, ticket).then((): void => {
        spoken = true;
      });
      await settle();
      await settle();
      const creations = run.askedFor();
      // An engine that was asked for anyway is handed one, so nothing is left waiting.
      run.create(new FakeEngine());
      await settle();
      // No engine was asked for, and the utterance counts as stopped.
      expect(creations).assertEqual(0);
      expect(spoken).assertTrue();
    });

    it('a_replaced_speechs_late_engine_is_shut_down_and_the_new_speech_alone_speaks', 0, async () => {
      const run = new HeldCreations();
      const first = run.speech.speak('First.', VOICE, run.speech.ticket());
      await run.asked(1);
      // A newer speech replaces the first while its engine is being created, and asks for one too.
      run.speech.stop();
      const second = run.speech.speak('Second.', VOICE, run.speech.ticket());
      await run.asked(2);
      const stale = new FakeEngine();
      const live = new FakeEngine();
      // The first speech's engine arrives first, then the new speech's.
      run.create(stale);
      await settle();
      await settle();
      // The engine of the speech that was replaced is shut down: it took no listener and said
      // nothing.
      expect(stale.calls).assertDeepEquals(['shutdown']);
      await first;
      run.create(live);
      await settle();
      await settle();
      expect(live.calls).assertDeepEquals(['listener', 'speak Second.']);
      run.speech.release();
      await second;
    });
  });
}
