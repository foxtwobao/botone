// The device-voice choice (M7): a port of mobile's lib/voice/device-voice.ts. Until someone picks
// a voice, the device's own is used unless a hosted voice is already set up, so earlier installs
// keep the provider they connected; the first answer is kept, so later replies do not wait on the
// server to decide. A choice still being saved is what a read sees, never a default written over
// it. The store and the server read are injected (the app's preferences file and the voice status
// RPC); the layer-2 voice fixture is generated from the real mobile module.
export const DEVICE_VOICE_KEY = 'rakazo.device-voice';

/** A small key/value store for voice choices: the app's preferences file. */
export interface VoiceChoiceStore {
  get: (key: string) => Promise<string | null>;
  put: (key: string, value: string) => Promise<void>;
}

let store: VoiceChoiceStore | null = null;
let statusReady: (() => Promise<boolean>) | null = null;

/** The app installs its preferences file and the voice status read at start. */
export function setDeviceVoiceStore(next: VoiceChoiceStore | null): void {
  store = next;
}

export function setVoiceStatusReader(read: (() => Promise<boolean>) | null): void {
  statusReady = read;
}

/** Counts explicit choices, so a default worked out meanwhile never overwrites one. */
let choices = 0;
let lastWrite: Promise<void> = Promise.resolve();
let choiceSaving: Promise<void> | undefined;
const choiceListeners: Set<() => void> = new Set<() => void>();

function write(on: boolean): Promise<void> {
  const next = lastWrite.then(async (): Promise<void> => {
    if (store !== null) {
      await store.put(DEVICE_VOICE_KEY, on ? '1' : '0');
    }
  });
  lastWrite = next.then((): void => undefined, (): void => undefined);
  return next;
}

export async function loadDeviceVoiceEnabled(): Promise<boolean> {
  // A choice still being written must be what this read sees, not a default written over it.
  if (choiceSaving !== undefined) {
    await choiceSaving;
  }
  const seen = choices;
  let stored: string | null = null;
  if (store !== null) {
    stored = await store.get(DEVICE_VOICE_KEY);
  }
  if (stored) {
    return stored === '1';
  }
  let ready = false;
  try {
    ready = statusReady !== null ? await statusReady() : false;
  } catch (err) {
    return true;
  }
  if (choices !== seen) {
    return loadDeviceVoiceEnabled();
  }
  try {
    await write(!ready);
  } catch (err) {
    // A default that cannot be saved is worked out again next time.
  }
  return !ready;
}

export async function saveDeviceVoiceEnabled(on: boolean): Promise<void> {
  choices += 1;
  const saved = write(on);
  const settled = lastWrite;
  choiceSaving = settled;
  void settled.then((): void => {
    if (choiceSaving === settled) {
      choiceSaving = undefined;
    }
  });
  for (const listener of choiceListeners) {
    try {
      listener();
    } catch (err) {
      // One listener that fails must not keep the others from hearing the choice.
    }
  }
  return saved;
}

export function subscribeDeviceVoiceChoice(listener: () => void): () => void {
  choiceListeners.add(listener);
  return (): void => {
    choiceListeners.delete(listener);
  };
}
