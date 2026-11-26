// M7 review round 4: the hosted clip's player, scripted as the kit's state machine takes controls.
// Pause, Resume and Stop are all offered while the first clip of a speech is still loading, and
// the kit's player answers a control from a state that cannot take it with a rejected promise. So
// none of them may reach the player from such a state: a pause asked for while the clip loads is
// kept by the session, and the clip then does not start.
import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import type { common } from '@kit.AbilityKit';
import * as speechPort from '../../../main/ets/voice/speech';
import type { SpeechContext, SpeechEngines, SpeechOptions } from '../../../main/ets/voice/speech';
import { playClip, setClipPlayerFactory } from '../../../main/ets/voice/clip-player';
import type { ClipPlayer } from '../../../main/ets/voice/clip-player';

/** The states the kit's player takes a play in, and the ones it takes a stop in. */
const PLAYS_FROM: string[] = ['prepared', 'paused', 'completed'];
const STOPS_FROM: string[] = ['prepared', 'playing', 'paused', 'completed'];

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

/** A clip's bytes as the player names its cache file by: a WAV header with no frames. */
function wavHeader(): Uint8Array {
  const out = new Uint8Array(44);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string): void => {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  };
  ascii(0, 'RIFF');
  view.setUint32(4, 36, true);
  ascii(8, 'WAVEfmt ');
  return out;
}

/** The kit's player, as its state machine takes controls: one asked from a state that cannot take
 *  it is answered with a rejected promise, as the kit answers it. */
class ScriptedClipPlayer implements ClipPlayer {
  /** Every control, named with the state the player was in when it was asked for. */
  calls: string[] = [];
  state: string = 'idle';
  /** While set, the clip's loading stays unfinished until the test calls `loadDone`. */
  holdsLoad: boolean = false;
  loadDone: (() => void) | null = null;
  private onStateChange: ((state: string) => void) | null = null;
  private onErrorHeard: (() => void) | null = null;

  onState = (callback: (state: string) => void): void => {
    this.onStateChange = callback;
  };

  onError = (callback: () => void): void => {
    this.onErrorHeard = callback;
  };

  load = (_fd: number): void => {
    this.calls.push(`load@${this.state}`);
    this.move('initialized');
  };

  prepare = (): Promise<void> => {
    this.calls.push(`prepare@${this.state}`);
    if (this.state !== 'initialized') {
      return this.refused('prepare');
    }
    if (this.holdsLoad) {
      return new Promise<void>((resolve: () => void): void => {
        this.loadDone = (): void => {
          this.move('prepared');
          resolve();
        };
      });
    }
    this.move('prepared');
    return Promise.resolve();
  };

  play = (): Promise<void> => this.take('play', PLAYS_FROM, 'playing');

  pause = (): Promise<void> => this.take('pause', ['playing'], 'paused');

  stop = (): Promise<void> => this.take('stop', STOPS_FROM, 'stopped');

  release = (): Promise<void> => {
    this.calls.push('release');
    this.state = 'released';
    return Promise.resolve();
  };

  private refused(name: string): Promise<void> {
    return Promise.reject(new Error(`The player cannot ${name} in ${this.state}`));
  }

  private take(name: string, from: string[], to: string): Promise<void> {
    this.calls.push(`${name}@${this.state}`);
    if (!from.includes(this.state)) {
      return this.refused(name);
    }
    this.move(to);
    return Promise.resolve();
  }

  private move(state: string): void {
    this.state = state;
    this.onStateChange?.(state);
  }
}

/** Where the engines hand out the rendering of the clip: the test releases it when it chooses. */
interface RenderHold {
  render: (() => void) | null;
}

/** The engines of a hosted speech with one clip, played by the app's own clip player. */
function hostedSpeech(context: common.Context, render: RenderHold): void {
  const engines: SpeechEngines = {
    captureContext: (): Promise<SpeechContext> => {
      const pinned: SpeechContext = { apiBase: 'https://api.example', generation: 1, headers: {} };
      return Promise.resolve(pinned);
    },
    deviceVoiceEnabled: (): Promise<boolean> => Promise.resolve(false),
    deviceVoiceFor: (_botId: string): Promise<string | undefined> => Promise.resolve(undefined),
    deviceCanPause: (): boolean => true,
    stopDevice: (): void => undefined,
    pauseDevice: (): void => undefined,
    resumeDevice: (): void => undefined,
    speakOnDevice: (_utterance: string, _voice: string | undefined): Promise<void> => {
      return Promise.reject(new Error('The device voice is off in this speech'));
    },
    prepare: (_text: string, _options: SpeechOptions, _request: SpeechContext): Promise<string[] | null> => {
      return Promise.resolve(['One clip.']);
    },
    render: (): Promise<Uint8Array> => {
      return new Promise<Uint8Array>((resolve: (clip: Uint8Array) => void): void => {
        render.render = (): void => {
          resolve(wavHeader());
        };
      });
    },
    playClip: (bytes: Uint8Array, session: speechPort.HostedSession): Promise<void> => {
      return playClip(bytes, session, context);
    },
  };
  speechPort.setSpeechEngines(engines);
}

export default function clipPlayerTest(): void {
  let context: common.Context | null = null;

  describe('ClipPlayerLifecycle', () => {
    beforeAll((): void => {
      context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
    });

    afterEach((): void => {
      speechPort.stopVoicePlayback();
      speechPort.noteSessionChanged();
      speechPort.setSpeechEngines(null);
      setClipPlayerFactory(null);
    });

    it('a_pause_asked_before_the_first_clip_loads_holds_the_clip_until_a_resume', 0, async () => {
      const player = new ScriptedClipPlayer();
      setClipPlayerFactory((): Promise<ClipPlayer> => Promise.resolve(player));
      const render: RenderHold = { render: null };
      hostedSpeech(context!, render);
      const speaking = speechPort.speakText('One clip.');
      await waitFor((): boolean => render.render !== null, 'the clip being rendered');
      // Pause: the bar offers it as soon as the speech prepares, before there is any player.
      speechPort.pauseVoicePlayback();
      expect(speechPort.getVoicePlaybackState().status).assertEqual('paused');
      render.render?.();
      await settle();
      await settle();
      // The pause reached no control the player could not take, and the clip, loaded into a
      // paused session, did not start.
      expect(player.calls).assertDeepEquals(['load@idle', 'prepare@initialized']);
      expect(speechPort.getVoicePlaybackState().status).assertEqual('paused');
      // Resume starts it, and a pause asked for while it plays does reach the player.
      speechPort.resumeVoicePlayback();
      await settle();
      expect(speechPort.getVoicePlaybackState().status).assertEqual('playing');
      speechPort.pauseVoicePlayback();
      await settle();
      expect(player.calls).assertDeepEquals(
        ['load@idle', 'prepare@initialized', 'play@prepared', 'pause@playing']);
      speechPort.stopVoicePlayback();
      await speaking;
      // Stop ends the clip from a paused player, which takes a stop, and the player is released.
      expect(speechPort.getVoicePlaybackState().status).assertEqual('idle');
      expect(player.calls).assertDeepEquals(
        ['load@idle', 'prepare@initialized', 'play@prepared', 'pause@playing', 'stop@paused', 'release']);
    });

    it('a_resume_or_a_stop_asked_while_the_clip_loads_reaches_no_control_the_player_refuses', 0, async () => {
      const player = new ScriptedClipPlayer();
      player.holdsLoad = true;
      setClipPlayerFactory((): Promise<ClipPlayer> => Promise.resolve(player));
      const render: RenderHold = { render: null };
      hostedSpeech(context!, render);
      const speaking = speechPort.speakText('One clip.');
      await waitFor((): boolean => render.render !== null, 'the clip being rendered');
      render.render?.();
      await waitFor((): boolean => player.calls.includes('prepare@initialized'), 'the clip loading');
      speechPort.pauseVoicePlayback();
      speechPort.resumeVoicePlayback();
      await settle();
      // The bar says the speech plays again, though its clip is still loading.
      expect(speechPort.getVoicePlaybackState().status).assertEqual('playing');
      speechPort.stopVoicePlayback();
      await speaking;
      expect(speechPort.getVoicePlaybackState().status).assertEqual('idle');
      // None of the three controls reached the player while it could take none of them.
      expect(player.calls).assertDeepEquals(['load@idle', 'prepare@initialized', 'release']);
    });
  });
}
