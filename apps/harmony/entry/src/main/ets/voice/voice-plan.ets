// The voice plan (M7): a port of mobile's lib/calls/voice-call-entry.ts, the part that chooses
// where speech goes before anything listens or speaks. The device's own voice is used when it is
// on and the recognizer can run; otherwise the server's voice provider, when one is set up;
// otherwise nothing, and the caller is sent to the voice settings. A device-voice read failure
// counts as on, like mobile: a local-only reply must never take the hosted path by accident.
// Pure (every read is injected); pinned by the layer-2 voice fixture.
export interface VoiceStatusView {
  ready: boolean;
  transcribe: boolean;
}

export interface VoicePlanDeps {
  loadDeviceVoiceEnabled: () => Promise<boolean>;
  dictationAvailable: () => Promise<boolean>;
  loadVoiceStatus: () => Promise<VoiceStatusView>;
}

interface DevicePlan {
  kind: string;
  transcribe: boolean;
}

interface ProviderPlan {
  kind: string;
  transcribe: boolean;
}

/** `settings` when no voice is set up, `dictation` when there is none that can hear. */
interface MissingPlan {
  kind: string;
}

export type VoiceCallPlan = DevicePlan | ProviderPlan | MissingPlan;

/** Chooses the listening and speaking path; `purpose` is "dictation" for the composer. */
export async function resolveVoiceCallPlan(deps: VoicePlanDeps, purpose: string = 'call'): Promise<VoiceCallPlan> {
  let deviceVoiceEnabled = false;
  try {
    deviceVoiceEnabled = await deps.loadDeviceVoiceEnabled();
  } catch (err) {
    deviceVoiceEnabled = true;
  }
  let deviceDictationAvailable = false;
  if (deviceVoiceEnabled) {
    deviceDictationAvailable = await deps.dictationAvailable();
  }
  if (deviceVoiceEnabled && deviceDictationAvailable) {
    const plan: DevicePlan = { kind: 'device', transcribe: false };
    return plan;
  }
  const status = await deps.loadVoiceStatus();
  if (!status.ready && !(purpose === 'dictation' && status.transcribe)) {
    const missing: MissingPlan = { kind: deviceVoiceEnabled ? 'dictation' : 'settings' };
    return missing;
  }
  if (!status.transcribe) {
    const canDictate = deviceVoiceEnabled
      ? deviceDictationAvailable
      : await deps.dictationAvailable();
    if (!canDictate) {
      const missing: MissingPlan = { kind: 'dictation' };
      return missing;
    }
  }
  const plan: ProviderPlan = { kind: 'provider', transcribe: status.transcribe };
  return plan;
}
