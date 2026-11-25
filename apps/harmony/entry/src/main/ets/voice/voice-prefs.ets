// Where the voice choices live on this device (M7): the app's preferences file "rakazo.voice".
// Mobile keeps the device-voice choice in its secure store under DEVICE_VOICE_KEY and the bots'
// voices in a document file of its own; both are plain preferences here (neither is a secret).
import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import type { VoiceChoiceStore } from './device-voice';

const PREFS_NAME = 'rakazo.voice';
/** The bots' assigned device voices, one JSON object of botId → voice identifier. */
export const BOT_VOICES_KEY = 'rakazo.bot-voices';

let store: preferences.Preferences | null = null;

/** True when the file opened; false leaves the choices in their defaults and nothing saved. */
export async function initVoicePrefs(context: common.Context): Promise<boolean> {
  try {
    store = await preferences.getPreferences(context, PREFS_NAME);
    return true;
  } catch (err) {
    store = null;
    return false;
  }
}

/** The device-voice choice's key/value store over the preferences file. */
export const voiceChoiceStore: VoiceChoiceStore = {
  async get(key: string): Promise<string | null> {
    if (store === null) {
      throw new Error('Voice preferences are unavailable');
    }
    const value = await store.get(key, '');
    return typeof value === 'string' && value ? value as string : null;
  },
  async put(key: string, value: string): Promise<void> {
    if (store === null) {
      throw new Error('Voice preferences are unavailable');
    }
    await store.put(key, value);
    await store.flush();
  },
};

/** The bots' assigned voices; an unreadable or empty file reads as none. */
export async function loadBotVoices(): Promise<Record<string, string> | null> {
  if (store === null) {
    return null;
  }
  const stored = await store.get(BOT_VOICES_KEY, '');
  if (typeof stored !== 'string' || !stored) {
    return null;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(stored);
  } catch (err) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, Object>;
  const assignments: Record<string, string> = {};
  for (const key of Object.keys(record)) {
    const value = record[key];
    if (typeof value === 'string' && value) {
      assignments[key] = value as string;
    }
  }
  return assignments;
}

/** Saves the bots' assigned voices; a failed save leaves what was last saved. */
export async function saveBotVoices(assignments: Record<string, string>): Promise<void> {
  if (store === null) {
    return;
  }
  await store.put(BOT_VOICES_KEY, JSON.stringify(assignments));
  await store.flush();
}
