// One hosted clip's playback (M7): the AVPlayer behind SpeechEngines.playClip, the pattern the
// attachment audio player set. The clip lands in the app's cache, plays from its file descriptor,
// and both the file and the player go when the clip ends or is stopped; the session holds the
// player's pause, resume and stop while it plays, and lets go of it the moment the clip ends,
// so nothing of the speech outlives it.
import type { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { t } from '../i18n/i18n';
import type { HostedPlayer, HostedSession } from './speech';/** How long a clip may take to start; one that cannot fails by then. */
const CLIP_START_MS = 3_000;

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
  const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
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
  const api = await import('@ohos.multimedia.media');
  const player = await api.default.createAVPlayer();
  let resolve: () => void = (): void => undefined;
  const held: Promise<void> = new Promise<void>((settle: () => void): void => {
    resolve = settle;
  });
  let settled = false;
  let started = false;
  let heardPlaying = false;
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
  // A clip that never starts fails by then, so a stalled player cannot hold the speech forever.
  const timer = setTimeout((): void => {
    if (!started) {
      finish(new Error(t('Could not play that clip.')));
    }
  }, CLIP_START_MS);
  const source: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    player.on('stateChange', (state: string): void => {
      if (settled) {
        return;
      }
      if (state === 'initialized') {
        void player.prepare();
      } else if (state === 'prepared') {
        started = true;
        if (!session.isStopped && !session.isPaused) {
          void player.play();
        }
      } else if (state === 'playing') {
        heardPlaying = true;
      } else if (state === 'completed' || state === 'stopped') {
        finish(null);
      } else if (state === 'released' || state === 'idle') {
        finish(heardPlaying ? null : new Error(t('Could not play that clip.')));
      }
    });
    player.on('error', (): void => {
      finish(new Error(t('Could not play that clip.')));
    });
    const handle: HostedPlayer = {
      pause: (): void => {
        try {
          player.pause();
        } catch (err) {
          // Pausing is best effort; the bar still shows the state.
        }
      },
      resume: (): void => {
        try {
          player.play();
        } catch (err) {
          finish(new Error(t('Could not play that clip.')));
        }
      },
      stopNow: (): void => {
        finish(null);
        try {
          player.stop();
        } catch (err) {
          // Stopped from a state the player refuses: the clip is over for the session.
        }
      },
    };
    session.setPlayer(handle);
    if (session.isStopped) {
      finish(null);
      await held;
    } else {
      player.fdSrc = { fd: source.fd };
      await held;
    }
    if (failure !== null) {
      const error: Error = failure;
      throw error;
    }
  } finally {
    clearTimeout(timer);
    session.setPlayer(null);
    try {
      await fs.close(source);
    } catch (err) {
      // The file is deleted right after this anyway.
    }
    try {
      await player.release();
    } catch (err) {
      // A failed release leaves the player to the system's own lifetime.
    }
  }
}
