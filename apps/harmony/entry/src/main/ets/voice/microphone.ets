// The microphone (M7): its permission, asked only when it is not allowed yet, as mobile asks it,
// so the plan's own answers come back without a prompt; and the capturer both dictation paths
// record from, behind one seam a test can fake. The reason the permission prompt shows is a
// resource string the module's permission entry names (module.json5), never copy in code.
import { abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import type { common, Permissions } from '@kit.AbilityKit';
import type { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MICROPHONE: string = 'ohos.permission.MICROPHONE';

/** True when the microphone is allowed already. */
export function microphoneGranted(): boolean {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION,
    );
    const manager = abilityAccessCtrl.createAtManager();
    return manager.checkAccessTokenSync(info.appInfo.accessTokenId, MICROPHONE as Permissions)
      === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (err) {
    return false;
  }
}

/** Asks for the microphone when it is not allowed yet; the answer is whether dictation may listen. */
export async function requestMicrophone(context: common.UIAbilityContext): Promise<boolean> {
  if (microphoneGranted()) {
    return true;
  }
  try {
    const wanted: Array<Permissions> = [MICROPHONE as Permissions];
    const answer = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, wanted);
    return answer.authResults.length > 0 && answer.authResults[0] === 0;
  } catch (err) {
    return false;
  }
}

/** The microphone dictation records from: the AudioCapturer behind a seam tests can fake. */
export interface CaptureMic {
  onFrames: (frames: (buffer: ArrayBuffer) => void) => void;
  start: () => Promise<void>;
  stop: () => Promise<void>;
  release: () => Promise<void>;
}

/** The microphone's own AudioCapturer, answering 16 kHz mono S16LE PCM; null where the device
 *  has none. */
export async function openCaptureMicrophone(): Promise<CaptureMic | null> {
  if (!canIUse('SystemCapability.Multimedia.Audio.Core')) {
    return null;
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
  const capturer = await api.default.createAudioCapturer({
    streamInfo: streamInfo, capturerInfo: capturerInfo,
  });
  const mic: CaptureMic = {
    onFrames: (frames: (buffer: ArrayBuffer) => void): void => {
      capturer.on('readData', frames);
    },
    start: async (): Promise<void> => {
      await capturer.start();
    },
    stop: async (): Promise<void> => {
      await capturer.stop();
    },
    release: async (): Promise<void> => {
      try {
        capturer.off('readData');
      } catch (err) {
        hilog.warn(0, 'Voice', 'Could not detach the microphone listener');
      }
      await capturer.release();
    },
  };
  return mic;
}

/** Releases a microphone that never recorded, or whose start failed. A failure is logged: the
 *  caller is done with this microphone either way. */
export async function releaseMicrophone(mic: CaptureMic): Promise<void> {
  try {
    await mic.release();
  } catch (err) {
    hilog.warn(0, 'Voice', 'Could not release the microphone');
  }
}

/** Lets go of a recording microphone: stopped, then released whatever the stop did. */
export async function stopMicrophone(mic: CaptureMic): Promise<void> {
  try {
    await mic.stop();
  } catch (err) {
    hilog.warn(0, 'Voice', 'Could not stop the microphone');
  }
  await releaseMicrophone(mic);
}
