// One recorded turn for the hosted dictation (M7): mobile's recordClip on the AudioCapturer. The
// microphone answers 16 kHz mono S16LE PCM, kept in memory and wrapped in a WAV (a 44-byte header
// the server's transcriber reads); the level is reported each buffer the mic hands over, and the
// recording ends when its `until` signal stops it (a stop tap, which keeps the words) or its cap
// is reached — the cap keeps a dictated clip inside the server's transcription size limit.
import type { audio } from '@kit.AudioKit';
import { t } from '../i18n/i18n';
import type { VoiceRecording } from './hosted-voice';
import type { StopSignal } from './stop-signal';

/** A dictated clip's cap (mobile MAX_DICTATION_MS). */
export const MAX_DICTATION_MS = 5 * 60_000;
/** A level at or under this is silence (mobile SILENT_LEVEL_DB). */
const SILENT_LEVEL_DB = -50;

/** The WAV header the server's transcriber reads, in front of the PCM it wraps. */
function wavBytes(pcm: Uint8Array): Uint8Array {
  const out = new Uint8Array(pcm.byteLength + 44);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string): void => {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  };
  ascii(0, 'RIFF');
  view.setUint32(4, out.byteLength - 8, true);
  ascii(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, pcm.byteLength, true);
  out.set(pcm, 44);
  return out;
}

/** The loudness of one PCM frame from 0 (silence) to 1, on mobile's metering scale. */
export function pcmLevel(frame: Uint8Array): number {
  let squares = 0;
  const samples = Math.floor(frame.byteLength / 2);
  for (let index = 0; index + 1 < frame.byteLength; index += 2) {
    const value = (frame[index] ?? 0) + ((frame[index + 1] ?? 0) << 8);
    squares += value * value;
  }
  const rms = Math.sqrt(squares / Math.max(1, samples));
  const db = 20 * Math.log10(Math.max(1, rms) / 32_768);
  return Math.min(1, Math.max(0, (db - SILENT_LEVEL_DB) / -SILENT_LEVEL_DB));
}

/**
 * Records until `until` stops it (its audio is kept) or `cancel` ends the session (its audio is
 * dropped). The level reaches `onLevel` a few times a second while the microphone is open, and
 * the clip says the locale it was recorded for. Nothing is recorded without the microphone
 * permission, which the caller asks for first.
 */
export async function recordClip(cancel: StopSignal, until: StopSignal,
  onLevel: (level: number) => void, language: string): Promise<VoiceRecording | null> {
  if (cancel.isStopped()) {
    return null;
  }
  if (!canIUse('SystemCapability.Multimedia.Audio.Core')) {
    throw new Error(t('Allow microphone access to dictate.'));
  }
  const api = await import('@ohos.multimedia.audio');
  const streamInfo: audio.AudioStreamInfo = {
    samplingRate: api.default.AudioSamplingRate.SAMPLE_RATE_16000,
    channels: api.default.AudioChannel.CHANNEL_1,
    sampleFormat: api.default.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
    encodingType: api.default.AudioEncodingType.ENCODING_TYPE_RAW,
  };
  const capturerInfo: audio.AudioCapturerInfo = {
    source: api.default.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
    capturerFlags: 0,
  };
  let capturer: audio.AudioCapturer;
  try {
    capturer = await api.default.createAudioCapturer({ streamInfo: streamInfo, capturerInfo: capturerInfo });
  } catch (err) {
    // A microphone that cannot open reads as its permission: nothing else can be recorded.
    throw new Error(t('Allow microphone access to dictate.'));
  }
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    capturer.on('readData', (buffer: ArrayBuffer): void => {
      const frame = new Uint8Array(buffer);
      chunks.push(frame);
      bytes += frame.byteLength;
      onLevel(pcmLevel(frame));
    });
  } catch (err) {
    // A listener that cannot register: nothing is recorded without it.
    throw new Error(t('Allow microphone access to dictate.'));
  }
  let done = false;
  let cleanup: () => void = (): void => undefined;
  const ended = new Promise<void>((resolve: () => void): void => {
    const offCancel = cancel.onCancel(resolve);
    const offUntil = until.onCancel(resolve);
    // The cap ends the recording itself: a dictated message stays inside the server's limit.
    const timer = setTimeout((): void => {
      done = true;
      resolve();
    }, MAX_DICTATION_MS);
    cleanup = (): void => {
      clearTimeout(timer);
      offCancel();
      offUntil();
    };
  });
  try {
    await capturer.start();
    await ended;
  } finally {
    cleanup();
    try {
      await capturer.stop();
    } catch (err) {
      // The capturer is released below either way.
    }
    try {
      capturer.off('readData');
    } catch (err) {
      // The listener is gone with the capturer either way.
    }
    try {
      await capturer.release();
    } catch (err) {
      // Same: the capturer is not reused.
    }
  }
  if (!done && cancel.isStopped()) {
    return null;
  }
  const pcm = new Uint8Array(bytes);
  let at = 0;
  for (const chunk of chunks) {
    pcm.set(chunk, at);
    at += chunk.byteLength;
  }
  return { audio: wavBytes(pcm), language: language };
}
