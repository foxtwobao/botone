// One recorded turn for the hosted dictation (M7): mobile's recordClip on the AudioCapturer. The
// microphone answers 16 kHz mono S16LE PCM, kept in memory and wrapped in a WAV (a 44-byte header
// the server's transcriber reads); the level is reported a few times a second. The recording ends
// when its `until` signal stops it (a stop tap, which keeps the words), when the session's
// `cancel` ends it (which drops them), or when it reaches its cap: the cap keeps the clip inside
// the server's transcription limit, and reaching it keeps the words like a stop tap does. The
// microphone sits behind a seam a test can fake, as the recognizer's does.
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../i18n/i18n';
import type { VoiceRecording } from './hosted-voice';
import type { StopSignal } from './stop-signal';
import type { CaptureMic } from './microphone';
import { openCaptureMicrophone, releaseMicrophone, stopMicrophone } from './microphone';
import { MAX_TRANSCRIBE_BYTES } from './transcribe-limit.generated';
import { CLIP_BYTES_PER_MS, dictationCapMs, WAV_HEADER_BYTES } from './clip-limit';

/** A dictated clip's cap: the longest recording whose WAV stays inside the server's limit. */
export const MAX_DICTATION_MS = dictationCapMs(MAX_TRANSCRIBE_BYTES);
/** The same cap in bytes of PCM: the microphone's buffers do not wait for the timer. */
const MAX_CLIP_BYTES = MAX_DICTATION_MS * CLIP_BYTES_PER_MS;
/** A level at or under this is silence (mobile SILENT_LEVEL_DB). */
const SILENT_LEVEL_DB = -50;
/** How often a level is reported: the microphone hands over buffers far faster than the UI needs. */
export const LEVEL_INTERVAL_MS = 100;

/** The WAV header the server's transcriber reads, in front of the PCM it wraps. */
function wavBytes(pcm: Uint8Array): Uint8Array {
  const out = new Uint8Array(pcm.byteLength + WAV_HEADER_BYTES);
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
  out.set(pcm, WAV_HEADER_BYTES);
  return out;
}

/** The loudness of one PCM frame from 0 (silence) to 1, on mobile's metering scale. */
export function pcmLevel(frame: Uint8Array): number {
  let squares = 0;
  const samples = Math.floor(frame.byteLength / 2);
  for (let index = 0; index + 1 < frame.byteLength; index += 2) {
    // S16LE samples are signed: reading the pair unsigned turns every negative half-wave into a
    // huge positive value, so the meter jumps at what the ear hears as silence.
    const raw = (frame[index] ?? 0) + ((frame[index + 1] ?? 0) << 8);
    const value = raw >= 0x8000 ? raw - 0x10000 : raw;
    squares += value * value;
  }
  const rms = Math.sqrt(squares / Math.max(1, samples));
  const db = 20 * Math.log10(Math.max(1, rms) / 32_768);
  return Math.min(1, Math.max(0, (db - SILENT_LEVEL_DB) / -SILENT_LEVEL_DB));
}

/** Wraps a level callback so it fires at most a few times a second. */
export function paceLevel(onLevel: (level: number) => void): (level: number) => void {
  let last = 0;
  return (level: number): void => {
    const now = Date.now();
    if (now - last >= LEVEL_INTERVAL_MS) {
      last = now;
      onLevel(level);
    }
  };
}

type ClipRecorder = (cancel: StopSignal, until: StopSignal, onLevel: (level: number) => void,
  language: string) => Promise<VoiceRecording | null>;
let recorder: ClipRecorder = captureClip;

/** A test hands a scripted recorder in; null restores the microphone's own. */
export function setClipRecorder(next: ClipRecorder | null): void {
  recorder = next ?? captureClip;
}

/** Opens the microphone a recording takes its frames from; null where the device has none. */
type MicrophoneOpener = () => Promise<CaptureMic | null>;
let microphone: MicrophoneOpener = openCaptureMicrophone;

/** A test hands a scripted microphone in; null restores the device's own. */
export function setClipMicrophone(next: MicrophoneOpener | null): void {
  microphone = next ?? openCaptureMicrophone;
}

/**
 * Records until `until` stops it (its audio is kept) or `cancel` ends the session (its audio is
 * dropped). The level reaches `onLevel` a few times a second while the microphone is open, and
 * the clip says the locale it was recorded for. Nothing is recorded without the microphone
 * permission, which the caller asks for first.
 */
export async function recordClip(cancel: StopSignal, until: StopSignal,
  onLevel: (level: number) => void, language: string): Promise<VoiceRecording | null> {
  return recorder(cancel, until, onLevel, language);
}

async function captureClip(cancel: StopSignal, until: StopSignal,
  onLevel: (level: number) => void, language: string): Promise<VoiceRecording | null> {
  if (cancel.isStopped()) {
    return null;
  }
  let opened: CaptureMic | null = null;
  try {
    opened = await microphone();
  } catch (err) {
    // A microphone that cannot open reads as its permission: nothing else can be recorded.
    hilog.warn(0, 'Voice', 'Could not open the microphone');
  }
  if (opened === null) {
    throw new Error(t('Allow microphone access to dictate.'));
  }
  // Cancelled while the microphone was being opened: it is released, never started, so no
  // recording begins after the session that asked for it ended.
  if (cancel.isStopped()) {
    await releaseMicrophone(opened);
    return null;
  }
  const captured = opened;
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  // The meter repaints a few times a second, not once per microphone buffer.
  const meter: (level: number) => void = paceLevel(onLevel);
  let done = false;
  let endRecording: () => void = (): void => undefined;
  try {
    captured.onFrames((buffer: ArrayBuffer): void => {
      const frame = new Uint8Array(buffer);
      if (bytes + frame.byteLength > MAX_CLIP_BYTES) {
        // The cap, as the buffers reach it: one more would take the clip past the server's limit.
        endRecording();
        return;
      }
      chunks.push(frame);
      bytes += frame.byteLength;
      meter(pcmLevel(frame));
    });
  } catch (err) {
    // A listener that cannot register: nothing is recorded without it.
    throw new Error(t('Allow microphone access to dictate.'));
  }
  let cleanup: () => void = (): void => undefined;
  const ended = new Promise<void>((resolve: () => void): void => {
    const offCancel = cancel.onCancel(resolve);
    const offUntil = until.onCancel(resolve);
    // Reaching the cap ends the recording itself, keeping its words.
    endRecording = (): void => {
      done = true;
      resolve();
    };
    const timer = setTimeout((): void => {
      endRecording();
    }, MAX_DICTATION_MS);
    cleanup = (): void => {
      clearTimeout(timer);
      offCancel();
      offUntil();
    };
  });
  try {
    await captured.start();
    await ended;
  } finally {
    cleanup();
    await stopMicrophone(captured);
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
