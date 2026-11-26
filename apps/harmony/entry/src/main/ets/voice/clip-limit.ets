// The hosted dictation's recording cap (M7): computed from the server's own limit on the audio it
// transcribes, never a length of its own. Pure: the port test runs it against the server's real
// constant, and hypium against the one the build generates from it.

/** One millisecond of the recording: 16 kHz mono S16LE PCM. */
export const CLIP_BYTES_PER_MS = 32;
/** The WAV header the server's transcriber reads, in front of the PCM it wraps. */
export const WAV_HEADER_BYTES = 44;

/** A dictated clip's cap for a server that transcribes at most `transcribeLimit` bytes of audio:
 *  the longest whole millisecond whose WAV, header included, stays inside the limit. */
export function dictationCapMs(transcribeLimit: number): number {
  return Math.floor((transcribeLimit - WAV_HEADER_BYTES) / CLIP_BYTES_PER_MS);
}
