// On-device dictation session (M7): a port of mobile's lib/voice/dictation.ts for the composer,
// mirroring the web store's endpoint mode: the recognizer reports words, and only a quiet gap
// measured here ends a turn. The recognizer's own `isFinal` / `end` is a breath or an OS limit
// (here: the engine's one-session audio cap), never the caller finishing a sentence. Its end of
// speech together with its final words is stronger, so that shortens the gap.
// The recognizer and the clock are injected, so the state machine replays under hypium without
// hardware; the layer-2 voice fixture is generated from the real mobile module. Not ported: the
// call audio-session option and the iOS locale query (no calls here, no iOS).
//
// One addition of this port: a recognizer may offer a finish that keeps its own last words
// (SpeechRecognizer.finish). A caller's finish then ends the turn when those words and the
// recognizer's end are in, instead of aborting the segment out from under them. Without it the
// turn ends as mobile's does, with what was reported so far.

import { supportedSpeechTag } from './speech-locale';
import type { StopSignal } from './stop-signal';

/** Quiet gap that ends an utterance. A natural breath is well under it, a finished turn well over. */
export const ENDPOINT_SILENCE_MS = 1_200;
/**
 * Quiet gap once the recognizer has reported the end of speech and finalised the words. It
 * reports that only after a pause of its own, so the caller has been quiet for longer than this.
 */
export const END_OF_SPEECH_GRACE_MS = 500;
const RESTART_MIN_MS = 250;
const RESTART_MAX_MS = 2_000;
/** Restarts in a row that hear nothing: the recognizer is wedged, stop churning the mic. */
const MAX_DEAD_RESTARTS = 5;
export const QUIET_RESTART_MS = 15_000;
/**
 * How long a caller's finish waits for the recognizer's end. The engine settles its last words
 * in milliseconds; an engine that neither completes nor refuses is wedged, and the caller's
 * send must not hang on it. Well under the composer's pause limit, its only caller's, and well
 * over a settled engine.
 */
export const FINISH_GRACE_MS = 2_000;
/** Errors that mean this turn cannot recover; the rest are routine and `end` restarts. */
const FATAL_ERRORS: Set<string> = new Set<string>([
  'not-allowed', 'service-not-allowed', 'audio-capture', 'language-not-supported', 'bad-grammar',
]);
/** Recoverable errors that mean a failure if the last empty attempt still has one. */
const TRANSIENT_ERRORS: Set<string> = new Set<string>(['client', 'busy', 'network', 'unknown', 'too-many-requests']);

/** idle: nothing was said; failed: the recognizer broke. */
export type DictationGiveUp = 'idle' | 'failed';

export interface DictationResult {
  isFinal: boolean;
  transcript: string;
}

export interface DictationError {
  error: string;
}

/** The events a running recognizer reports. */
export interface RecognizerEvents {
  result: (event: DictationResult) => void;
  end: () => void;
  error: (event: DictationError) => void;
  speechStart: () => void;
  speechEnd: () => void;
  /** The microphone's loudness from 0 (silence) to 1, a few times a second. */
  level: (value: number) => void;
}

export interface RecognizerStartOptions {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  /** Whether the caller follows the microphone's loudness. */
  level: boolean;
}

/** The slice of a speech recognizer the session needs, so tests can drive the events. */
export interface SpeechRecognizer {
  /** Prepares the engine; resolves once start() can be called. */
  load: () => Promise<void>;
  start: (options: RecognizerStartOptions) => void;
  abort: () => void;
  /** Ends the running session keeping what it heard: its last words arrive through `result`,
   *  then `end`. A recognizer without it is aborted by a caller's finish, as always. */
  finish?: () => void;
  isRecognitionAvailable: () => boolean;
  /** Asks for the microphone when it is not allowed yet; true when dictation may listen. */
  requestPermissions: () => Promise<boolean>;
  /** Routes the recognizer's events to these handlers until the returned function runs. */
  listen: (events: RecognizerEvents) => () => void;
}

export interface DictationTimers {
  set: (callback: () => void, ms: number) => number;
  clear: (id: number) => void;
}

export interface DictationListenOptions {
  onInterim?: (text: string) => void;
  onFinal: (text: string) => void;
  onGiveUp?: (reason: DictationGiveUp) => void;
  /** The microphone's loudness from 0 (silence) to 1, a few times a second. */
  onLevel?: (level: number) => void;
  /** Cancelling it ends the session without delivering what it heard. */
  signal?: StopSignal;
  lang?: string;
  /** A gap the caller chose: from the start on, only the silence timer ends a quiet session. */
  endpointMs?: number;
}

interface Session {
  recognizer: SpeechRecognizer;
  lang: string;
  /** Stops routing the recognizer's events; null until they are routed. */
  off: (() => void) | null;
  onInterim?: (text: string) => void;
  onFinal: (text: string) => void;
  onGiveUp?: (reason: DictationGiveUp) => void;
  onLevel?: (level: number) => void;
  /** Quiet gap that ends the utterance. */
  endpointMs: number;
  /** The caller asked for the words: the recognizer's end delivers them rather than restarting. */
  finishing: boolean;
  /** The caller chose the gap, so the silence timer alone ends a quiet session. */
  ownEndpoint: boolean;
  /** The words last reported, so a repeated result is not mistaken for new speech. */
  reported: string;
  /** Text from earlier recognizer sessions of the same utterance. */
  carried: string;
  /** Text of the recognizer session running now. */
  heard: string;
  /** The recognizer reported the end of speech, and has not heard the caller start again. */
  speechEnded: boolean;
  /** The recognizer finalised its words, and has not heard new ones since. */
  finalized: boolean;
  /** Timer ids; -1 while none is armed. */
  silence: number;
  /** The shorter gap that runs once the recognizer reports both of the above. */
  grace: number;
  /** The caller's finish, waiting for the recognizer's end. */
  finishingTimer: number;
  restart: number;
  quiet: number;
  backoff: number;
  deadRestarts: number;
  /** Reset on each native start: only the last attempt classifies empty exhaustion. */
  transientError: boolean;
}

let injected: SpeechRecognizer | null = null;

/** The recognizer every session uses; the app installs the device engine's adapter at start. */
export function setSpeechRecognizer(recognizer: SpeechRecognizer | null): void {
  injected = recognizer;
}

const clock: DictationTimers = {
  set: (callback: () => void, ms: number): number => setTimeout(callback, ms),
  clear: (id: number): void => {
    clearTimeout(id);
  },
};
let timers: DictationTimers = clock;

/** Test seam: a scripted clock lets a replay fire the session's timers in order. */
export function setDictationTimers(next: DictationTimers | null): void {
  timers = next ?? clock;
}

function arm(id: number, callback: () => void, ms: number): number {
  if (id >= 0) {
    timers.clear(id);
  }
  return timers.set(callback, ms);
}

function disarm(id: number): void {
  if (id >= 0) {
    timers.clear(id);
  }
}

/** A session older than this one can never deliver a final. */
let token = 0;
let active: Session | null = null;

/** True when the device can recognise speech itself and the caller allowed it. */
export async function available(): Promise<boolean> {
  try {
    const recognizer = injected;
    if (recognizer === null) {
      return false;
    }
    await recognizer.load();
    if (!recognizer.isRecognitionAvailable()) {
      return false;
    }
    return await recognizer.requestPermissions();
  } catch (err) {
    return false;
  }
}

export function stop(): void {
  const session = active;
  active = null;
  token += 1;
  if (session === null) {
    return;
  }
  disarm(session.silence);
  disarm(session.grace);
  disarm(session.finishingTimer);
  disarm(session.restart);
  disarm(session.quiet);
  session.off?.();
  try {
    session.recognizer.abort();
  } catch (err) {
    // already stopped
  }
}

/** Ends the running session now and delivers what it heard. */
export function finishListening(): void {
  const session = active;
  if (session === null) {
    return;
  }
  if (session.recognizer.finish === undefined) {
    finish(session, 'idle');
    return;
  }
  // The recognizer's own last words come with its end: the turn ends once they are in. An
  // engine that never reports that end is wedged; the turn then ends with what was heard.
  session.finishing = true;
  session.finishingTimer = arm(session.finishingTimer, (): void => {
    finish(session, 'idle');
  }, FINISH_GRACE_MS);
  session.recognizer.finish();
}

/**
 * Opens the microphone until a quiet gap ends the utterance, or `signal` cancels it. A caller's
 * own `endpointMs` also counts from the start, so a mic that never hears anything closes too.
 */
export async function listen(opts: DictationListenOptions): Promise<void> {
  // A cancelled request can arrive after a newer session started; it must not stop that one.
  if (opts.signal?.isStopped() === true) {
    return;
  }
  stop();
  const mine = token;
  const recognizer = injected;
  if (recognizer === null) {
    throw new Error('No speech recognizer');
  }
  await recognizer.load();
  // A recognizer that lists the tags it starts would be asked here; this platform's does not say.
  const lang = supportedSpeechTag(opts.lang || 'en-US', []);
  // A stop that landed while the recognizer was loading ends this request.
  if (token !== mine || opts.signal?.isStopped() === true) {
    return;
  }
  const session: Session = {
    recognizer: recognizer,
    lang: lang,
    off: null,
    onInterim: opts.onInterim,
    onFinal: opts.onFinal,
    onGiveUp: opts.onGiveUp,
    onLevel: opts.onLevel,
    endpointMs: opts.endpointMs ?? ENDPOINT_SILENCE_MS,
    ownEndpoint: opts.endpointMs !== undefined,
    finishing: false,
    reported: '',
    carried: '',
    heard: '',
    speechEnded: false,
    finalized: false,
    silence: -1,
    grace: -1,
    finishingTimer: -1,
    restart: -1,
    quiet: -1,
    backoff: RESTART_MIN_MS,
    deadRestarts: 0,
    transientError: false,
  };
  active = session;
  opts.signal?.onCancel((): void => {
    if (active === session) {
      stop();
    }
  });
  session.off = recognizer.listen({
    result: (event: DictationResult): void => {
      onResult(session, event);
    },
    end: (): void => {
      onEnd(session);
    },
    error: (event: DictationError): void => {
      onError(session, event);
    },
    speechStart: (): void => {
      if (active === session) {
        cancelGrace(session);
      }
    },
    speechEnd: (): void => {
      if (active !== session) {
        return;
      }
      session.speechEnded = true;
      armGrace(session);
    },
    level: (value: number): void => {
      if (active === session) {
        session.onLevel?.(value);
      }
    },
  });
  try {
    start(session);
  } catch (err) {
    giveUp(session, 'failed');
    return;
  }
  if (session.ownEndpoint) {
    armSilence(session);
  }
}

/** Ends the utterance once nothing new is heard for the session's quiet gap. */
function armSilence(session: Session): void {
  session.silence = arm(session.silence, (): void => {
    finish(session, 'idle');
  }, session.endpointMs);
}

/**
 * Ends the turn after the shorter gap once the recognizer has reported both the end of speech
 * and its final words. The full gap keeps running underneath, so cancelling this falls back to
 * it. A caller's own pause limit is never shortened.
 */
function armGrace(session: Session): void {
  if (session.ownEndpoint || !session.speechEnded || !session.finalized) {
    return;
  }
  if (!join(session.carried, session.heard)) {
    return;
  }
  session.grace = arm(session.grace, (): void => {
    finish(session, 'idle');
  }, END_OF_SPEECH_GRACE_MS);
}

/** The caller may still be talking, so only the full gap can end the turn. */
function cancelGrace(session: Session): void {
  session.speechEnded = false;
  session.finalized = false;
  disarm(session.grace);
  session.grace = -1;
}

function start(session: Session): void {
  if (active !== session) {
    return;
  }
  session.transientError = false;
  session.recognizer.start({
    lang: session.lang,
    interimResults: true,
    continuous: true,
    level: session.onLevel !== undefined,
  });
  watchQuiet(session);
}

function watchQuiet(session: Session): void {
  session.quiet = arm(session.quiet, (): void => {
    if (active !== session) {
      return;
    }
    try {
      session.recognizer.abort();
    } catch (err) {
      giveUp(session, 'failed');
    }
  }, QUIET_RESTART_MS);
}

function onResult(session: Session, event: DictationResult): void {
  if (active !== session) {
    return;
  }
  const heard = event.transcript ?? '';
  session.backoff = RESTART_MIN_MS;
  session.deadRestarts = 0;
  if (heard.trim()) {
    watchQuiet(session);
  }
  // A recognizer may report a phrase once and start over, or grow one transcript: folding a
  // final into the carried text and clearing the live one covers both. Words after a final open
  // a new phrase: the caller kept talking. Words between the end of speech and the final are the
  // recognizer catching up on the same phrase.
  if (heard.trim() && session.finalized) {
    cancelGrace(session);
  }
  if (event.isFinal) {
    session.carried = join(session.carried, heard);
    session.heard = '';
    session.finalized = true;
  } else {
    session.heard = heard;
  }
  const text = join(session.carried, session.heard);
  if (!text) {
    return;
  }
  // With the caller's own pause limit, only new words count as being heard.
  if (session.ownEndpoint && text === session.reported) {
    return;
  }
  session.reported = text;
  session.onInterim?.(text);
  // Any result means the caller was just heard, so the quiet gap restarts here, including a
  // phrase the recognizer finalises after repeating it, whose boundary is a breath.
  armSilence(session);
  armGrace(session);
}

function onEnd(session: Session): void {
  if (active !== session) {
    return;
  }
  if (session.finishing) {
    // The end the caller's finish was waiting for: deliver rather than restart.
    finish(session, 'idle');
    return;
  }
  disarm(session.finishingTimer);
  session.finishingTimer = -1;
  disarm(session.quiet);
  session.quiet = -1;
  // Until the restart the recognizer cannot hear the caller start again.
  cancelGrace(session);
  // A session ends on its own: on a pause, an interruption, a cap or a failure, which says
  // nothing about whether the caller finished. Pick the microphone straight back up.
  session.carried = join(session.carried, session.heard);
  session.heard = '';
  session.deadRestarts += 1;
  if (session.deadRestarts > MAX_DEAD_RESTARTS) {
    const failed = session.transientError && !session.carried;
    // A recognizer that keeps failing gives up; one that just ended quietly during a pause keeps
    // restarting when the caller's own silence timer decides when the pause is over.
    if (failed || !session.ownEndpoint) {
      giveUp(session, failed ? 'failed' : 'idle');
      return;
    }
  }
  disarm(session.restart);
  const delay = session.backoff;
  session.backoff = Math.min(RESTART_MAX_MS, session.backoff * 2);
  session.restart = timers.set((): void => {
    if (active !== session) {
      return;
    }
    try {
      start(session);
    } catch (err) {
      giveUp(session, 'failed');
    }
  }, delay);
}

function onError(session: Session, event: DictationError): void {
  if (active !== session) {
    return;
  }
  if (!event?.error) {
    return;
  }
  if (TRANSIENT_ERRORS.has(event.error)) {
    session.transientError = true;
  }
  // A fatal error is one the turn cannot recover from.
  if (FATAL_ERRORS.has(event.error)) {
    giveUp(session, 'failed');
  }
}

function giveUp(session: Session, reason: DictationGiveUp): void {
  if (active !== session) {
    return;
  }
  finish(session, reason);
}

function finish(session: Session, reason?: DictationGiveUp): void {
  if (active !== session) {
    return;
  }
  const text = join(session.carried, session.heard).trim();
  const onFinal = session.onFinal;
  stop();
  if (text) {
    onFinal(text);
  } else if (reason !== undefined) {
    session.onGiveUp?.(reason);
  }
}

function join(left: string, right: string): string {
  return `${left} ${right}`.replace(/\s+/g, ' ').trim();
}
