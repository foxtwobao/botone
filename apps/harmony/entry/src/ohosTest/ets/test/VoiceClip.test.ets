// M7 review round 4: the hosted dictation's recording on a scripted microphone. A cancel that
// lands while the microphone is being opened starts no recording, and a recording that reaches
// its cap stops there and keeps its words, inside what the server transcribes.
import { afterEach, describe, expect, it } from '@ohos/hypium';
import { MAX_DICTATION_MS, recordClip, setClipMicrophone } from '../../../main/ets/voice/voice-clip';
import { CLIP_BYTES_PER_MS, WAV_HEADER_BYTES } from '../../../main/ets/voice/clip-limit';
import { MAX_TRANSCRIBE_BYTES } from '../../../main/ets/voice/transcribe-limit.generated';
import type { CaptureMic } from '../../../main/ets/voice/microphone';
import { StopSignal } from '../../../main/ets/voice/stop-signal';
import type { VoiceRecording } from '../../../main/ets/voice/hosted-voice';

/** Lets the microtask chain behind a call finish before the next step. */
const settle = (): Promise<void> => new Promise<void>((resolve: () => void): void => {
  setTimeout(resolve, 10);
});

/** A microphone buffer that holds one byte value throughout. */
function filled(tone: number, size: number): ArrayBuffer {
  const bytes = new Uint8Array(size);
  bytes.fill(tone);
  return bytes.buffer as ArrayBuffer;
}

/** The scripted microphone a recording takes its frames from. */
class FakeMic implements CaptureMic {
  calls: string[] = [];
  frames: ((buffer: ArrayBuffer) => void) | null = null;

  onFrames = (frames: (buffer: ArrayBuffer) => void): void => {
    this.calls.push('frames');
    this.frames = frames;
  };

  start = (): Promise<void> => {
    this.calls.push('start');
    return Promise.resolve();
  };

  stop = (): Promise<void> => {
    this.calls.push('stop');
    return Promise.resolve();
  };

  release = (): Promise<void> => {
    this.calls.push('release');
    return Promise.resolve();
  };
}

function noLevel(_level: number): void {}

export default function voiceClipTest(): void {
  describe('ClipRecording', () => {
    afterEach((): void => {
      setClipMicrophone(null);
    });

    it('a_cancel_while_the_microphone_is_being_opened_starts_no_recording', 0, async () => {
      const asks: Array<(mic: CaptureMic | null) => void> = [];
      setClipMicrophone((): Promise<CaptureMic | null> => {
        return new Promise<CaptureMic | null>((give: (mic: CaptureMic | null) => void): void => {
          asks.push(give);
        });
      });
      const cancel = new StopSignal();
      const until = new StopSignal();
      const recording = recordClip(cancel, until, noLevel, 'en-US');
      // The session is cancelled while its microphone is still being created, then it answers.
      cancel.cancel();
      const mic = new FakeMic();
      const give = asks.shift();
      give?.(mic);
      const clip = await recording;
      expect(clip).assertNull();
      // The microphone was released without ever taking a listener or starting: no recording
      // began after the session that asked for it had ended.
      expect(mic.calls).assertDeepEquals(['release']);
      expect(until.isStopped()).assertFalse();
    });

    it('a_recording_that_reaches_its_cap_stops_and_keeps_its_words', 0, async () => {
      const cap = MAX_DICTATION_MS * CLIP_BYTES_PER_MS;
      // The cap is the longest recording whose WAV, header included, the server still transcribes.
      expect(WAV_HEADER_BYTES + cap).assertLess(MAX_TRANSCRIBE_BYTES);
      const mic = new FakeMic();
      setClipMicrophone((): Promise<CaptureMic | null> => Promise.resolve(mic));
      const cancel = new StopSignal();
      const until = new StopSignal();
      const recording = recordClip(cancel, until, noLevel, 'en-US');
      let ended = false;
      void recording.then((): void => {
        ended = true;
      });
      await settle();
      expect(mic.calls).assertDeepEquals(['frames', 'start']);
      // The microphone hands over more than the cap, faster than any clock counts it.
      const buffer = filled(0x00, 65_536);
      for (let sent = 0; sent < cap + 2 * 65_536; sent += 65_536) {
        mic.frames?.(buffer);
      }
      await settle();
      const endedByCap = ended;
      // A recording that did not end by the cap is stopped here, so the case leaves nothing behind.
      until.cancel();
      const clip = await recording;
      // The cap ended the recording by itself, keeping its words: neither signal stopped it.
      expect(endedByCap).assertTrue();
      expect(clip !== null).assertTrue();
      const audio = (clip as VoiceRecording).audio;
      expect(audio.byteLength).assertLarger(WAV_HEADER_BYTES);
      expect(audio.byteLength).assertLess(MAX_TRANSCRIBE_BYTES);
      expect(cancel.isStopped()).assertFalse();
      expect(mic.calls).assertDeepEquals(['frames', 'start', 'stop', 'release']);
    });
  });
}
