// Speech playback (M7): a port of mobile's lib/voice/voice.ts, the read-aloud state machine. One
// playback at a time (a newer Play or Stop owns the outcome), one control that Pause / Resume /
// Stop always reach, and a queue that speaks one item at a time so Stop cuts whatever is playing
// now. Each speech goes to the device's own voice when that is on, else to the server's voice:
// consent, then one prepare for the text, then each utterance rendered one clip ahead and played.
// The engines are injected (the device synthesizer, the server's voice, the clip player), so the
// state machine replays under hypium without hardware; the layer-2 voice fixture is generated from
// the real mobile module. Not ported: the call audio modes, the speech owner and queueSpeech (they
// serve calls) and the HTML audio path.

import { toUtterances } from './speech-text';
/** The server, session and Space a speech is pinned to; net/rpc's own shape. */
export interface SpeechContext {
  apiBase: string;
  generation: number;
  headers: Record<string, string>;
}

/** Who is speaking, for the playback bar. */
export interface PlaybackSpeaker {
  name: string;
  color: string;
}

export interface SpeechOptions {
  voiceId?: string;
  botId?: string;
  messageId?: string;
  speaker?: PlaybackSpeaker;
  scope?: string;
  /** The server, session and Space this speech was pinned to when its queue began. */
  requestContext?: SpeechContext;
}

export interface SpeechQueueItem extends SpeechOptions {
  text: string;
}

/** idle | playing | paused */
export interface VoicePlaybackState {
  status: string;
  botId?: string;
  /** The thread message this clip was spoken from, when playback started from one. */
  messageId?: string;
  canPause: boolean;
  speaker?: PlaybackSpeaker;
}

interface VoiceControl {
  pause: () => void;
  resume: () => void;
  stop: () => void;
}

/** The player of one hosted clip, as the session pauses, resumes and stops it. */
export interface HostedPlayer {
  pause: () => void;
  resume: () => void;
  stopNow: () => void;
}

const IDLE_PLAYBACK: VoicePlaybackState = { status: 'idle', canPause: false };

/** The engines one speech runs on. */
export interface SpeechEngines {
  /** Pins the server, session and Space a speech runs on. */
  captureContext: () => Promise<SpeechContext>;
  /** Whether the device's own voice is on. */
  deviceVoiceEnabled: () => Promise<boolean>;
  /** The voice a bot speaks with on the device; undefined leaves the engine's default. */
  deviceVoiceFor: (botId: string) => Promise<string | undefined>;
  /** True when the device engine can hold what it says and go on. */
  deviceCanPause: () => boolean;
  /** Stops whatever the device engine is saying. */
  stopDevice: () => void;
  pauseDevice: () => void;
  resumeDevice: () => void;
  /** Says one utterance with the device engine; resolves when it ended or was stopped. */
  speakOnDevice: (utterance: string, voice: string | undefined) => Promise<void>;
  /** Asks for the server's consent and voice: the utterances to render, null when no voice is set up. */
  prepare: (text: string, options: SpeechOptions, context: SpeechContext) => Promise<string[] | null>;
  /** Renders one utterance to audio. */
  render: (utterance: string, options: SpeechOptions, context: SpeechContext) => Promise<Uint8Array>;
  /** Plays one clip; resolves when it ended or was stopped. The session receives its player. */
  playClip: (bytes: Uint8Array, session: HostedSession) => Promise<void>;
}

let engines: SpeechEngines | null = null;
/** The app installs the real engines at start; a replay installs scripted ones. */
export function setSpeechEngines(next: SpeechEngines | null): void {
  engines = next;
}

let playback: VoicePlaybackState = IDLE_PLAYBACK;
let activeControl: VoiceControl | null = null;
const playbackListeners: Set<() => void> = new Set<() => void>();

// The speaker is remembered per bot rather than threaded through every state change below:
// pause, resume and the device-voice path all rebuild the state.
interface AnnouncedSpeaker {
  botId: string;
  speaker: PlaybackSpeaker;
}

let announcedSpeaker: AnnouncedSpeaker | null = null;

function setPlayback(next: VoicePlaybackState, control: VoiceControl | null): void {
  const speaker = next.botId && announcedSpeaker !== null && announcedSpeaker.botId === next.botId
    ? announcedSpeaker.speaker
    : null;
  if (speaker === null) {
    playback = next;
  } else {
    const withSpeaker: VoicePlaybackState = {
      status: next.status, botId: next.botId, messageId: next.messageId, canPause: next.canPause,
      speaker: speaker,
    };
    playback = withSpeaker;
  }
  activeControl = control;
  for (const listener of playbackListeners) {
    listener();
  }
}

export function getVoicePlaybackState(): VoicePlaybackState {
  return playback;
}

export function subscribeVoicePlayback(listener: () => void): () => void {
  playbackListeners.add(listener);
  return (): void => {
    playbackListeners.delete(listener);
  };
}

export function pauseVoicePlayback(): void {
  activeControl?.pause();
}

export function resumeVoicePlayback(): void {
  activeControl?.resume();
}

export function stopVoicePlayback(): void {
  // Bump even when nothing is audible yet: the next queued message may already be preparing,
  // with no player for Stop to reach.
  playbackEpoch += 1;
  speechQueue = [];
  activeControl?.stop();
}

/** A sign-out, account switch or server switch: the rest of the queue belongs to the session
 *  that started it, and the next session must neither hear it nor see its speaker. */
export function noteSessionChanged(): void {
  stopVoicePlayback();
  announcedSpeaker = null;
}

// Queued playback runs one item at a time, so a single Stop always reaches whatever is
// actually playing right now.
let speechQueue: SpeechQueueItem[] = [];
/** Invalidates in-flight speaks. Stop and a new speak or queue each bump it. */
let playbackEpoch = 0;

function isCurrentSpeech(epoch: number): boolean {
  return epoch === playbackEpoch;
}

function beginSpeech(): number {
  playbackEpoch += 1;
  speechQueue = [];
  // Replacing activeControl leaves the previous player running.
  activeControl?.stop();
  return playbackEpoch;
}

function releasePlayback(epoch: number, stillOwner: boolean, keepForQueue: boolean): void {
  if (!stillOwner || !isCurrentSpeech(epoch)) {
    return;
  }
  // The next queued message is about to prepare. Idle here hides the bar for that gap.
  if (keepForQueue && speechQueue.length > 0) {
    return;
  }
  setPlayback(IDLE_PLAYBACK, null);
}

function withoutEngine(): Error {
  return new Error('No speech engines');
}

/**
 * Speaks each item in order; stops early if stopVoicePlayback() clears the queue. Resolves to
 * whether the first item was spoken, so a caller can tell the user when no voice is set up.
 */
export async function speakQueue(items: SpeechQueueItem[]): Promise<boolean> {
  const engine = engines;
  if (engine === null) {
    throw withoutEngine();
  }
  const epoch = beginSpeech();
  // One context for the whole queue, taken before anything plays: a queued reply must never
  // capture the server or account of a later session.
  let requestContext: SpeechContext | undefined;
  try {
    requestContext = await engine.captureContext();
  } catch (error) {
    // The session or server changed while capturing; that change already stopped this queue, so
    // this is not a "no voice is set up" outcome.
    if (!isCurrentSpeech(epoch)) {
      return true;
    }
    throw error as Error;
  }
  if (!isCurrentSpeech(epoch)) {
    return true;
  }
  const queued: SpeechQueueItem[] = [];
  for (const item of items) {
    queued.push(item.requestContext !== undefined ? item : withContext(item, requestContext));
  }
  speechQueue = queued;
  try {
    return await advanceSpeechQueue(epoch);
  } catch (error) {
    // The session change (or a newer Play or Stop) that ended this queue can leave its request
    // failing late; the next session's screen must not hear about that. Playback that still owns
    // the epoch keeps reporting its errors.
    if (!isCurrentSpeech(epoch)) {
      return true;
    }
    throw error as Error;
  }
}

/** A queue item as the queue speaks it: the same speech, pinned to the queue's context. */
function withContext(item: SpeechQueueItem, context: SpeechContext | undefined): SpeechQueueItem {
  const queued: SpeechQueueItem = { text: item.text };
  if (context !== undefined) {
    queued.requestContext = context;
  }
  if (item.voiceId !== undefined) {
    queued.voiceId = item.voiceId;
  }
  if (item.botId !== undefined) {
    queued.botId = item.botId;
  }
  if (item.messageId !== undefined) {
    queued.messageId = item.messageId;
  }
  if (item.speaker !== undefined) {
    queued.speaker = item.speaker;
  }
  if (item.scope !== undefined) {
    queued.scope = item.scope;
  }
  return queued;
}

async function advanceSpeechQueue(epoch: number): Promise<boolean> {
  // A newer Play or Stop owns the outcome. False would look like "no voice".
  if (!isCurrentSpeech(epoch)) {
    return true;
  }
  const next = speechQueue.length > 0 ? speechQueue.shift() : undefined;
  if (next === undefined) {
    return false;
  }
  const spoken = await speakPrepared(next.text, next, epoch);
  if (!isCurrentSpeech(epoch)) {
    return true;
  }
  if (spoken && speechQueue.length > 0) {
    await advanceSpeechQueue(epoch);
  }
  return spoken;
}

export async function speakText(text: string, options: SpeechOptions = {}): Promise<boolean> {
  const item: SpeechQueueItem = withContext({ text: text }, undefined);
  if (options.voiceId !== undefined) {
    item.voiceId = options.voiceId;
  }
  if (options.botId !== undefined) {
    item.botId = options.botId;
  }
  if (options.messageId !== undefined) {
    item.messageId = options.messageId;
  }
  if (options.speaker !== undefined) {
    item.speaker = options.speaker;
  }
  if (options.scope !== undefined) {
    item.scope = options.scope;
  }
  if (options.requestContext !== undefined) {
    item.requestContext = options.requestContext;
  }
  return speakPrepared(text, item, beginSpeech());
}

interface RenderedClip {
  audio: Uint8Array | null;
  error: Error | null;
}

/** Renders one utterance; a failure rides as a value so an abandoned prefetch never rejects unhandled. */
function renderClip(engine: SpeechEngines, utterance: string, options: SpeechOptions,
  context: SpeechContext): Promise<RenderedClip> {
  return engine.render(utterance, options, context).then((audio: Uint8Array): RenderedClip => {
    const clip: RenderedClip = { audio: audio, error: null };
    return clip;
  }, (error: Error): RenderedClip => {
    const clip: RenderedClip = { audio: null, error: error };
    return clip;
  });
}

async function speakPrepared(text: string, opts: SpeechQueueItem, epoch: number): Promise<boolean> {
  if (!isCurrentSpeech(epoch)) {
    return false;
  }
  const engine = engines;
  if (engine === null) {
    throw withoutEngine();
  }
  announcedSpeaker = opts.botId && opts.speaker ? { botId: opts.botId, speaker: opts.speaker } : null;
  // Stop has to work before a player exists. Pause stays hidden until one does.
  const prepareControl: VoiceControl = {
    pause: (): void => {},
    resume: (): void => {},
    stop: (): void => {
      setPlayback(IDLE_PLAYBACK, null);
    },
  };
  const preparing: VoicePlaybackState = {
    status: 'playing', botId: opts.botId, messageId: opts.messageId, canPause: false,
  };
  setPlayback(preparing, prepareControl);
  try {
    // A read failure must not be treated as "off": that would send reply text through hosted voice
    // after the user opted for on-device only.
    let useDeviceVoice = false;
    try {
      useDeviceVoice = await engine.deviceVoiceEnabled();
    } catch (err) {
      useDeviceVoice = true;
    }
    if (!isCurrentSpeech(epoch)) {
      return false;
    }
    if (useDeviceVoice) {
      const spoken = await speakOnDevice(text, opts, epoch);
      if (!isCurrentSpeech(epoch)) {
        return false;
      }
      if (!spoken && playback.status !== 'idle') {
        setPlayback(IDLE_PLAYBACK, null);
      }
      return spoken;
    }
    const requestContext = opts.requestContext ?? (await engine.captureContext());
    if (!isCurrentSpeech(epoch)) {
      return false;
    }
    const utterances = await engine.prepare(text, opts, requestContext);
    if (!isCurrentSpeech(epoch)) {
      return false;
    }
    if (utterances === null) {
      if (playback.status !== 'idle') {
        setPlayback(IDLE_PLAYBACK, null);
      }
      return false;
    }
    const generation = startHostedSpeechSession();
    // The prepare control only owns the bar; stopping it would hide Stop.
    if (activeControl !== prepareControl) {
      activeControl?.stop();
    }
    if (!isCurrentSpeech(epoch)) {
      return false;
    }
    const session = new HostedSession(generation);
    const control: VoiceControl = {
      pause: (): void => {
        session.pause();
        setPlayback({ status: 'paused', botId: opts.botId, messageId: opts.messageId, canPause: true }, control);
      },
      resume: (): void => {
        session.resume();
        setPlayback({ status: 'playing', botId: opts.botId, messageId: opts.messageId, canPause: true }, control);
      },
      stop: (): void => {
        session.stop();
        setPlayback(IDLE_PLAYBACK, null);
      },
    };
    setPlayback({ status: 'playing', botId: opts.botId, messageId: opts.messageId, canPause: true }, control);
    let finished = false;
    try {
      // Render one clip ahead.
      let next: Promise<RenderedClip> | null = utterances.length > 0
        ? renderClip(engine, utterances[0] ?? '', opts, requestContext)
        : null;
      for (let index = 0; index < utterances.length; index += 1) {
        if (session.isStopped || !isCurrentSpeech(epoch)) {
          break;
        }
        const current = next;
        next = index + 1 < utterances.length
          ? renderClip(engine, utterances[index + 1] ?? '', opts, requestContext)
          : null;
        if (current === null) {
          break;
        }
        const rendered = await current;
        if (rendered.error !== null) {
          throw rendered.error;
        }
        if (session.isStopped || !isCurrentSpeech(epoch)) {
          break;
        }
        await engine.playClip(rendered.audio ?? new Uint8Array(0), session);
      }
      finished = !session.isStopped && isCurrentSpeech(epoch);
    } finally {
      releasePlayback(epoch, isCurrentHostedSpeechSession(generation), finished);
    }
    return true;
  } finally {
    // A thrown or abandoned prepare must not leave the bar up. A newer Play has already replaced
    // this control.
    if (isCurrentSpeech(epoch) && activeControl === prepareControl) {
      setPlayback(IDLE_PLAYBACK, null);
    }
  }
}

let deviceSpeechSession = 0;

function startDeviceSpeechSession(): number {
  deviceSpeechSession += 1;
  return deviceSpeechSession;
}

function isCurrentDeviceSpeechSession(session: number): boolean {
  return session === deviceSpeechSession;
}

async function speakOnDevice(text: string, opts: SpeechQueueItem, epoch: number): Promise<boolean> {
  const engine = engines;
  if (engine === null) {
    throw withoutEngine();
  }
  const utterances = toUtterances(text);
  if (utterances.length === 0) {
    return false;
  }
  if (!isCurrentSpeech(epoch)) {
    return false;
  }
  // Claim the session before anything awaits, so a newer call cannot start meanwhile and then
  // overlap this call's remaining chunks.
  const session = startDeviceSpeechSession();
  // Each bot keeps its own offline voice; without one the engine's default speaks.
  let voice: string | undefined = undefined;
  if (opts.botId) {
    try {
      voice = await engine.deviceVoiceFor(opts.botId);
    } catch (err) {
      voice = undefined;
    }
  }
  if (!isCurrentDeviceSpeechSession(session) || !isCurrentSpeech(epoch)) {
    return true;
  }
  engine.stopDevice();
  if (!isCurrentDeviceSpeechSession(session) || !isCurrentSpeech(epoch)) {
    return true;
  }
  const canPause = engine.deviceCanPause();
  const control: VoiceControl = {
    pause: (): void => {
      if (!canPause) {
        return;
      }
      engine.pauseDevice();
      setPlayback({ status: 'paused', botId: opts.botId, messageId: opts.messageId, canPause: canPause }, control);
    },
    resume: (): void => {
      if (!canPause) {
        return;
      }
      engine.resumeDevice();
      setPlayback({ status: 'playing', botId: opts.botId, messageId: opts.messageId, canPause: canPause }, control);
    },
    stop: (): void => {
      deviceSpeechSession += 1;
      engine.stopDevice();
      setPlayback(IDLE_PLAYBACK, null);
    },
  };
  setPlayback({ status: 'playing', botId: opts.botId, messageId: opts.messageId, canPause: canPause }, control);
  let finished = false;
  try {
    for (const utterance of utterances) {
      if (!isCurrentDeviceSpeechSession(session) || !isCurrentSpeech(epoch)) {
        return true;
      }
      await engine.speakOnDevice(utterance, voice);
    }
    finished = isCurrentDeviceSpeechSession(session) && isCurrentSpeech(epoch);
    return true;
  } finally {
    releasePlayback(epoch, isCurrentDeviceSpeechSession(session), finished);
  }
}

// Hosted playback shares one session across a speech's utterances, so Pause / Resume / Stop keep
// working across the gap between them.

let hostedSpeechSession = 0;

function startHostedSpeechSession(): number {
  hostedSpeechSession += 1;
  return hostedSpeechSession;
}

function isCurrentHostedSpeechSession(session: number): boolean {
  return session === hostedSpeechSession;
}

/** One hosted speech's pause, stop and player across its utterances. */
export class HostedSession {
  private paused: boolean = false;
  private stopped: boolean = false;
  private player: HostedPlayer | null = null;
  private readonly generation: number;

  constructor(generation: number) {
    this.generation = generation;
  }

  get isStopped(): boolean {
    return this.stopped || !isCurrentHostedSpeechSession(this.generation);
  }

  get isPaused(): boolean {
    return this.paused;
  }

  setPlayer(player: HostedPlayer | null): void {
    this.player = player;
    if (player !== null && this.paused) {
      player.pause();
    }
  }

  pause(): void {
    this.paused = true;
    this.player?.pause();
  }

  resume(): void {
    this.paused = false;
    this.player?.resume();
  }

  stop(): void {
    this.stopped = true;
    this.player?.stopNow();
  }
}
