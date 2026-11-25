// The composer's dictation controller and its mic-level row (M7): a port of mobile's
// lib/composer/composer-dictation.ts, minus the call paths this app has none of. Tap to dictate
// into the message box, tap again to stop. It takes the same plan a call would: the phone's own
// recognizer when the device voice is on, otherwise the connected voice provider transcribes a
// recording. The controller reports its failures to the composer's notice row; the words land in
// the draft through the page's own merge rule (DraftDictation). The mic-level row is the bar's
// live part, so it is a component of its own.
import { t } from '../../i18n/i18n';
import { captureContext } from '../../net/rpc';
import type { RpcContext } from '../../net/rpc';
import { RpcError, errorText } from '../../net/errors';
import { AiConsentBlocked } from '../../net/consent';
import { currentSessionGeneration } from '../../net/session';
import { loadDeviceVoiceEnabled } from '../../voice/device-voice';
import { available as dictationAvailable, finishListening, listen, stop as stopDictation } from '../../voice/dictation';
import { recordClip } from '../../voice/voice-clip';
import { loadVoiceStatus, transcribeRecording } from '../../voice/hosted-voice';
import { ensureVoiceConsent } from '../../net/consent';
import { recognitionLanguage } from '../../voice/device-recognizer';
import { requestVoiceMicrophone } from '../../voice/install';
import type { VoiceRecording } from '../../voice/hosted-voice';
import { StopSignal } from '../../voice/stop-signal';
import { resolveVoiceCallPlan } from '../../voice/voice-plan';
import { appearance } from '../../uikit/theme';

/** A pause long enough to think in; one this long, or a mic that never hears anything, ends it. */
const DICTATION_PAUSE_MS = 30_000;

/** What the controller reports to the composer's notice row, and what it leaves the screen to. */
export type DictationNotice = (message: string, openVoice: boolean) => void;

interface DictationSession {
  cancel: StopSignal;
  /** Stops listening and keeps the words, then runs the work waiting for them. */
  finish: () => void;
  /** The words are in and the recording is being transcribed. */
  transcribing: boolean;
  /** Runs once the words are in, when the session ends without a cancel or a failure. */
  afterWords?: () => void;
}

/** failure copy for an error of any shape: the server's own words, else `fallback`. */
function failureText(err: Object, fallback: string): string {
  if (err instanceof RpcError) {
    return errorText(err as RpcError, fallback);
  }
  if (err instanceof Error) {
    return (err as Error).message.trim() || fallback;
  }
  return fallback;
}

@ObservedV2
export class ComposerDictation {
  /** idle | listening | transcribing */
  @Trace status: string = 'idle';
  /** The microphone's recent loudness, newest last, as the level row paints it. */
  @Trace levels: number[] = [];
  private session: DictationSession | null = null;
  private notice: DictationNotice;
  private onWords: (text: string, final: boolean) => void;

  constructor(notice: DictationNotice, onWords: (text: string, final: boolean) => void) {
    this.notice = notice;
    this.onWords = onWords;
  }

  /** The microphone's loudness from 0 to 1 while the mic is open. */
  onLevel(level: number): void {
    this.levels = [...this.levels.slice(-11), level];
  }

  private end(mine: DictationSession): boolean {
    if (this.session !== mine) {
      return false;
    }
    this.session = null;
    this.status = 'idle';
    return true;
  }

  private markTranscribing(mine: DictationSession): void {
    mine.transcribing = true;
    this.status = 'transcribing';
    this.levels = [];
  }

  cancel(): void {
    const mine = this.session;
    if (mine === null) {
      return;
    }
    mine.cancel.cancel();
    this.end(mine);
  }

  /** Stops listening and keeps the words, then runs `then` once they are in. */
  finish(then: () => void): void {
    const mine = this.session;
    if (mine === null) {
      return;
    }
    if (mine.transcribing) {
      mine.afterWords = then;
      return;
    }
    // Before the mic opens there are no words to wait for: drop the setup and go on.
    mine.cancel.cancel();
    this.end(mine);
    then();
  }

  toggle(): void {
    if (this.session !== null) {
      this.session.finish();
      return;
    }
    const mine: DictationSession = {
      cancel: new StopSignal(),
      finish: (): void => {
        this.cancel();
      },
      transcribing: false,
    };
    this.session = mine;
    this.status = 'listening';
    this.levels = [];
    void this.start(mine).catch((err: Object): void => {
      mine.cancel.cancel();
      if (!this.end(mine) || err instanceof AiConsentBlocked) {
        return;
      }
      this.notice(failureText(err, t('Could not dictate')), false);
    });
  }

  private async start(mine: DictationSession): Promise<void> {
    const plan = await resolveVoiceCallPlan({
      loadDeviceVoiceEnabled: loadDeviceVoiceEnabled,
      dictationAvailable: dictationAvailable,
      loadVoiceStatus: loadVoiceStatus,
    }, 'dictation');
    if (this.session !== mine) {
      return;
    }
    if (plan.kind === 'settings') {
      this.end(mine);
      this.notice('', true);
      return;
    }
    if (plan.kind === 'dictation') {
      this.end(mine);
      this.notice(t('Allow speech recognition in Settings, or connect a voice provider that transcribes.'), true);
      return;
    }
    if (plan.kind === 'provider') {
      const requestContext: RpcContext = await captureContext();
      if (this.session !== mine) {
        return;
      }
      await ensureVoiceConsent(requestContext);
      if (this.session !== mine) {
        return;
      }
      // The plan only asks for the microphone through the device recognizer's availability; a
      // transcribing provider answers without it, so the recording asks for it itself.
      if (!(await requestVoiceMicrophone())) {
        this.end(mine);
        this.notice(t('Allow microphone access to dictate.'), false);
        return;
      }
      const stopped = new StopSignal();
      mine.finish = (): void => {
        stopped.cancel();
        this.markTranscribing(mine);
      };
      const clip = await recordClip(mine.cancel, stopped, (level: number): void => {
        this.reportLevel(mine, level);
      }, recognitionLanguage());
      if (this.session !== mine) {
        return;
      }
      // A sign-in to another account meanwhile must not send this audio with the old session.
      if (requestContext.generation !== currentSessionGeneration()) {
        this.end(mine);
        return;
      }
      this.markTranscribing(mine);
      // The recording is already stopped; a second tap must not throw it away. A stalled
      // request fails on its own and stays a failure, not a cancel.
      mine.finish = (): void => {};
      let text = '';
      if (clip !== null) {
        text = await this.transcribe(clip, requestContext);
      }
      if (!this.end(mine) || requestContext.generation !== currentSessionGeneration()) {
        return;
      }
      if (text.trim()) {
        this.onWords(text.trim(), true);
      }
      mine.afterWords?.();
      return;
    }
    // The device path: the recognizer reports the words live.
    mine.finish = (): void => {
      finishListening();
    };
    await listen({
      endpointMs: DICTATION_PAUSE_MS,
      signal: mine.cancel,
      onInterim: (text: string): void => {
        if (this.session === mine) {
          this.onWords(text, false);
        }
      },
      onLevel: (level: number): void => {
        this.reportLevel(mine, level);
      },
      onFinal: (text: string): void => {
        if (!this.end(mine)) {
          return;
        }
        this.onWords(text, false);
        mine.afterWords?.();
      },
      // Hearing nothing is not an error; a recognizer that broke is.
      onGiveUp: (reason: string): void => {
        if (!this.end(mine)) {
          return;
        }
        if (reason === 'failed') {
          this.notice(t('Could not dictate'), false);
        } else {
          mine.afterWords?.();
        }
      },
    });
  }

  private async transcribe(clip: VoiceRecording, requestContext: RpcContext): Promise<string> {
    try {
      return await transcribeRecording(clip, requestContext);
    } catch (err) {
      throw new Error(failureText(err as Object, t('Could not transcribe that.')));
    }
  }

  private reportLevel(mine: DictationSession, level: number): void {
    if (this.session === mine) {
      this.onLevel(level);
    }
  }
}

/** The mic's recent loudness as a row of bars; the slots not yet heard read as silence. */
@ComponentV2
export struct DictationLevels {
  @Param dictation: ComposerDictation | null = null;
  private slots: number = 12;

  build() {
    Row({ space: 3 }) {
      ForEach(this.bars(), (level: number): void => {
        Circle()
          .width(3)
          .height(level > 0 ? Math.max(3, level * 20) : 3)
          .fill(level > 0 ? appearance.tokens().foreground : appearance.tokens().faintForeground)
      }, (level: number, index: number): string => `bar-${index}-${level}`)
    }
    .height(20)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.End)
    .layoutWeight(1)
  }

  private bars(): number[] {
    const shown = this.dictation?.levels ?? [];
    const bars: number[] = [];
    for (let index = 0; index < this.slots; index += 1) {
      const at = index - (this.slots - shown.length);
      bars.push(at >= 0 ? shown[at] ?? 0 : 0);
    }
    return bars;
  }
}

/** Stops the running session, words and all: leaving the chat drops the microphone. */
export function stopComposerDictation(controller: ComposerDictation): void {
  controller.cancel();
  stopDictation();
}
