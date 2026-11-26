// One hosted clip's playback (M7): the AVPlayer behind SpeechEngines.playClip, the pattern the
// attachment audio player set. The clip lands in the app's cache, plays from its file descriptor,
// and both the file and the player go when the clip ends or is stopped; the session holds the
// player's pause, resume and stop while it plays, and lets go of it the moment the clip ends,
// so nothing of the speech outlives it.
//
// The kit's player answers a control from a state that cannot take it with a rejected promise,
// and Pause, Resume and Stop are all offered while the first clip is still loading. So the
// player's state is followed here and a control reaches it only from a state that takes it; the
// answer of each one is handled, never left to reject on its own. A pause asked for while the
// clip loads is the session's to keep: the clip then does not start.
import type { common } from '@kit.AbilityKit';
import type { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../i18n/i18n';
import type { HostedPlayer, HostedSession } from './speech';

/** How long a clip may take to start; one that cannot fails by then. */
const CLIP_START_MS = 3_000;
/** The states the kit's player takes a play in, and the ones it takes a stop in. */
const PLAYS_FROM: string[] = ['prepared', 'paused', 'completed'];
const STOPS_FROM: string[] = ['prepared', 'playing', 'paused', 'completed'];

/** What a clip's bytes are, as the player's cache file is named by it. */
interface ClipType {
  mimeType: string;
  extension: string;
}

/** Hosted voices send MP3; a server that renders speech itself (macOS) sends WAV. */
export function speechClipType(bytes: Uint8Array): ClipType {
  let head = '';
  for (let index = 0; index < 12; index += 1) {
    head += String.fromCharCode(bytes[index] ?? 0);
  }
  if (head.startsWith('RIFF') && head.substring(8, 12) === 'WAVE') {
    const wav: ClipType = { mimeType: 'audio/wav', extension: 'wav' };
    return wav;
  }
  const mp3: ClipType = { mimeType: 'audio/mpeg', extension: 'mp3' };
  return mp3;
}

/** The calls one clip makes on its player; the kit's AVPlayer satisfies them behind a wrapper, so
 *  tests can fake it. */
export interface ClipPlayer {
  onState: (callback: (state: string) => void) => void;
  onError: (callback: () => void) => void;
  load: (fd: number) => void;
  prepare: () => Promise<void>;
  play: () => Promise<void>;
  pause: () => Promise<void>;
  stop: () => Promise<void>;
  release: () => Promise<void>;
}

/** The kit's own player, behind the calls a clip makes. A player that cannot be created cannot
 *  play anything. */
async function createClipPlayer(): Promise<ClipPlayer> {
  let player: media.AVPlayer;
  try {
    const api = await import('@ohos.multimedia.media');
    player = await api.default.createAVPlayer();
  } catch (err) {
    const failure: Error = new Error(t('Could not play that clip.'));
    throw failure;
  }
  const created: ClipPlayer = {
    onState: (callback: (state: string) => void): void => {
      player.on('stateChange', (state: string): void => {
        callback(state);
      });
    },
    onError: (callback: () => void): void => {
      player.on('error', (): void => {
        callback();
      });
    },
    load: (fd: number): void => {
      player.fdSrc = { fd: fd };
    },
    prepare: (): Promise<void> => player.prepare(),
    play: (): Promise<void> => player.play(),
    pause: (): Promise<void> => player.pause(),
    stop: (): Promise<void> => player.stop(),
    release: (): Promise<void> => player.release(),
  };
  return created;
}

let playerFactory: () => Promise<ClipPlayer> = createClipPlayer;

/** A test hands a scripted player factory in; null restores the kit's own. */
export function setClipPlayerFactory(next: (() => Promise<ClipPlayer>) | null): void {
  playerFactory = next ?? createClipPlayer;
}

/** One control of the player. The kit answers a refusal with a rejected promise rather than a
 *  throw, so both ways reach `refused`: the answer is never left to reject on its own. */
function attempt(control: () => Promise<void>, refused: () => void): void {
  try {
    control().then((): void => undefined, (): void => refused());
  } catch (err) {
    refused();
  }
}

/** A control nothing waits for was refused. */
function noteRefused(): void {
  hilog.warn(0, 'Voice', 'The clip player refused a control');
}

/**
 * Plays one rendered clip for its speech's session and resolves when it ended or was stopped.
 * The player is released and the cache file deleted on every path out.
 */
export async function playClip(bytes: Uint8Array, session: HostedSession,
  context: common.Context): Promise<void> {
  if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
    throw new Error(t('Could not play that clip.'));
  }
  const kind = speechClipType(bytes);
  const path = `${context.cacheDir}/rakazo-voice-${Date.now()}.${kind.extension}`;
  let opened: fs.File | null = null;
  try {
    opened = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
  } catch (err) {
    // No file to write the clip to: nothing can play.
  }
  if (opened === null) {
    const failure: Error = new Error(t('Could not play that clip.'));
    throw failure;
  }
  const file: fs.File = opened;
  try {
    fs.writeSync(file.fd, bytes.buffer);
  } catch (err) {
    throw new Error(t('Could not play that clip.'));
  } finally {
    try {
      await fs.close(file);
    } catch (err) {
      // The write or the close failing is the same: nothing can play.
    }
  }
  try {
    return await playFrom(path, session);
  } finally {
    try {
      fs.unlinkSync(path);
    } catch (err) {
      // A leftover cache file is harmless.
    }
  }
}

async function playFrom(path: string, session: HostedSession): Promise<void> {
  const player = await playerFactory();
  let resolve: () => void = (): void => undefined;
  const held: Promise<void> = new Promise<void>((settle: () => void): void => {
    resolve = settle;
  });
  let settled = false;
  let started = false;
  let heardPlaying = false;
  /** The player's state as it last reported it; idle until the clip is loaded. */
  let state = 'idle';
  /** What the clip ended with; null means it played or was stopped by the caller. */
  let failure: Error | null = null;
  const finish = (error: Error | null): void => {
    if (settled) {
      return;
    }
    settled = true;
    failure = error;
    session.setPlayer(null);
    resolve();
  };
  const fail = (): void => {
    finish(new Error(t('Could not play that clip.')));
  };
  // A clip that never starts fails by then, so a stalled player cannot hold the speech forever.
  const timer = setTimeout((): void => {
    if (!started) {
      fail();
    }
  }, CLIP_START_MS);
  let opened: fs.File | null = null;
  try {
    try {
      opened = fs.openSync(path, fs.OpenMode.READ_ONLY);
    } catch (err) {
      // Reopening the clip that was just written failed: nothing can play it.
    }
    if (opened === null) {
      const failure: Error = new Error(t('Could not play that clip.'));
      throw failure;
    }
    const source: fs.File = opened;
    player.onState((next: string): void => {
      state = next;
      if (settled) {
        return;
      }
      if (next === 'initialized') {
        // The clip waits on this answer: refused, it can never play.
        attempt((): Promise<void> => player.prepare(), fail);
      } else if (next === 'prepared') {
        started = true;
        // A pause asked for while the clip loaded holds it here, until a resume.
        if (!session.isStopped && !session.isPaused) {
          attempt((): Promise<void> => player.play(), fail);
        }
      } else if (next === 'playing') {
        heardPlaying = true;
      } else if (next === 'completed' || next === 'stopped') {
        finish(null);
      } else if (next === 'released' || next === 'idle') {
        finish(heardPlaying ? null : new Error(t('Could not play that clip.')));
      }
    });
    player.onError((): void => {
      fail();
    });
    const handle: HostedPlayer = {
      pause: (): void => {
        // The player takes a pause only while it plays. One asked for before that is the
        // session's to keep, and the clip then does not start.
        if (state === 'playing') {
          attempt((): Promise<void> => player.pause(), noteRefused);
        }
      },
      resume: (): void => {
        if (PLAYS_FROM.includes(state)) {
          attempt((): Promise<void> => player.play(), fail);
        }
      },
      stopNow: (): void => {
        finish(null);
        // A player still loading its clip has nothing to stop: the release below ends it.
        if (STOPS_FROM.includes(state)) {
          attempt((): Promise<void> => player.stop(), noteRefused);
        }
      },
    };
    session.setPlayer(handle);
    if (session.isStopped) {
      finish(null);
      await held;
    } else {
      player.load(source.fd);
      await held;
    }
    if (failure !== null) {
      const error: Error = failure;
      throw error;
    }
  } finally {
    clearTimeout(timer);
    session.setPlayer(null);
    if (opened !== null) {
      try {
        await fs.close(opened);
      } catch (err) {
        // The file is deleted right after this anyway.
      }
    }
    try {
      await player.release();
    } catch (err) {
      // A failed release leaves the player to the system's own lifetime.
    }
  }
}
